//! `browser` aracı: ajan, FerIDE'nin tarayıcısını (gerçek Chrome/Edge, ayrı profil) kullanır. Tarayıcının kendisi
//! `crate::browser`'da; burada araç tanımı, izin değerlendirmesi ve işlemlerin akışı var.
//!
//! Güvenlik: şifre/kart/kod alanlarına yazılmaz; geri dönüşü olmayabilecek işlemler her modda kullanıcıya sorulur
//! (bkz. `browser::safety`). Denetim, öğenin o anki hâline göre işlemden hemen önce yapılır.

use serde_json::{json, Value};
use std::sync::Arc;
use std::time::Duration;

use super::permissions::Risk;
use super::tools::{is_private_url, Assessment, ToolResult};
use super::{ApprovalAnswer, ToolCtx};
use crate::browser::cdp::Cdp;
use crate::browser::safety::{self, ElementInfo, Verdict};
use crate::browser::{BrowserManager, Tab};
use crate::config::BrowserSettings;
use crate::util::truncate_end;

/// Bir işlemden sonra modele gösterilen sayfa metni (karakter).
const AFTER_ACTION: usize = 5000;
/// `snapshot` ile okunan sayfa metni.
const SNAPSHOT: usize = 8000;
const STALE: &str = "Bu numaralı öğe artık sayfada yok (sayfa değişmiş). snapshot alıp güncel numarayı kullan.";

fn s<'a>(a: &'a Value, k: &str) -> &'a str {
    a.get(k).and_then(|v| v.as_str()).unwrap_or("")
}

pub fn spec() -> Value {
    json!({"type": "function", "function": {
        "name": "browser",
        "description": "Gerçek bir tarayıcıyı (Chrome/Edge, FerIDE'ye ayrılmış profil) kullanır: JavaScript'li siteler, kullanıcının o profilde \
giriş yaptığı hesaplar (Gmail, Takvim, Drive…), form doldurma, fiyat/rezervasyon karşılaştırma. Düz bir sayfayı okumak için fetch_url daha \
hızlıdır. Her işlem sayfanın kısa metnini ve [numaralı] öğelerini döndürür; öğelere ref ile başvur. Şifre, kart ve doğrulama kodu alanlarına \
yazamazsın: giriş, CAPTCHA, ödeme ve dosya yükleme için wait_for_user kullan.",
        "parameters": {"type": "object", "properties": {
            "action": {"type": "string",
                "enum": ["open", "snapshot", "find", "click", "type", "select", "press", "scroll", "back", "tabs", "switch_tab", "close_tab", "screenshot", "wait_for_user"],
                "description": "open: url aç (new_tab ile yeni sekmede) · snapshot: sayfayı oku (offset: devamı) · find: sayfada metin ara · \
click/type/select: ref'li öğe · press: tuş (Enter, Tab, Escape, ArrowDown…) · scroll: kaydır · back: geri · tabs/switch_tab/close_tab: sekmeler · \
screenshot: ekran görüntüsü · wait_for_user: kullanıcının bir işi yapmasını bekle"},
            "url": {"type": "string"},
            "new_tab": {"type": "boolean"},
            "ref": {"type": "integer", "description": "Öğe numarası ([12] → 12)"},
            "text": {"type": "string", "description": "type: yazılacak metin · find: aranacak metin"},
            "submit": {"type": "boolean", "description": "type: yazdıktan sonra Enter'a bas"},
            "value": {"type": "string", "description": "select: seçenek metni ya da değeri"},
            "key": {"type": "string"},
            "direction": {"type": "string", "enum": ["down", "up"]},
            "tab": {"type": "integer", "description": "Sekme numarası (tabs listesindeki)"},
            "offset": {"type": "integer", "description": "snapshot: kaçıncı karakterden devam edilecek"},
            "message": {"type": "string", "description": "wait_for_user: kullanıcıya ne yapması gerektiğini söyle"}
        }, "required": ["action"]}
    }})
}

/// Ajanın verdiği adres. Arama metni adres sayılmaz (web_search ya da arama adresi kullanılmalı).
fn agent_url(raw: &str) -> Result<String, String> {
    let t = raw.trim();
    if t.is_empty() {
        return Err("url gerekli".into());
    }
    if let Some(r) = safety::url_block(t) {
        return Err(r);
    }
    if t.contains("://") || t.starts_with("about:") {
        return Ok(t.to_string());
    }
    if t.contains(' ') || (!t.contains('.') && !t.starts_with("localhost")) {
        return Err("Geçerli bir adres değil. Arama için web_search kullan ya da https://www.google.com/search?q=… adresini aç.".into());
    }
    Ok(crate::browser::user_url(t))
}

fn ref_of(a: &Value) -> Result<i64, String> {
    let v = &a["ref"];
    v.as_i64()
        .or_else(|| v.as_f64().map(|f| f as i64))
        .or_else(|| v.as_str().and_then(|s| s.trim().trim_matches(|c| c == '[' || c == ']').trim().parse().ok()))
        .ok_or_else(|| "ref gerekli: sayfa çıktısındaki öğe numarası (ör. [12] için 12)".into())
}

fn show(r: i64, i: &ElementInfo) -> String {
    let name = truncate_end(i.name.trim(), 60);
    if name.is_empty() {
        format!("[{r}] {}", i.role)
    } else {
        format!("[{r}] {} \"{name}\"", i.role)
    }
}

/// Çağrının hedef öğesi (`ref`) ya da `ref` yoksa odaktaki öğe. Tarayıcı açık değilse ya da öğe bulunamazsa yok.
async fn peek(ctx: &ToolCtx, r: Option<i64>) -> Option<ElementInfo> {
    let mgr = &ctx.core.browser;
    if !mgr.is_running() {
        return None;
    }
    let st = ctx.core.settings().browser;
    tokio::time::timeout(Duration::from_secs(3), async {
        let (cdp, tab) = mgr.tab(&st).await.ok()?;
        match r {
            Some(r) => element(mgr, &cdp, &tab, r).await.ok(),
            None => mgr.call_page(&cdp, &tab, "active", json!([])).await.ok().and_then(|v| serde_json::from_value(v).ok()),
        }
    })
    .await
    .ok()
    .flatten()
}

/// İzin katmanı için çağrının özeti. Hassas işlemlerin (ödeme, gönderme…) kesin denetimi `execute` içinde, işlemden
/// hemen önce yapılır.
pub async fn assess(ctx: &ToolCtx, a: &Value) -> Assessment {
    let action = s(a, "action");
    let mut asm = Assessment { summary: format!("Tarayıcı: {action}"), ..Default::default() };
    match action {
        "open" => {
            let raw = s(a, "url");
            match agent_url(raw) {
                Ok(u) => {
                    asm.summary = format!("Tarayıcıda aç: {u}");
                    let local = u.starts_with("file:") || u.starts_with("about:");
                    asm.risk = if local { Risk::Read } else { Risk::Network };
                    asm.private_network = !local && is_private_url(&u);
                }
                Err(e) => {
                    asm.summary = format!("Tarayıcıda aç: {raw}");
                    asm.block = Some(e);
                }
            }
        }
        "back" => {
            asm.summary = "Tarayıcı: geri git".into();
            asm.risk = Risk::Network;
        }
        "snapshot" => asm.summary = "Tarayıcı: sayfayı oku".into(),
        "find" => asm.summary = format!("Tarayıcı: sayfada ara \"{}\"", truncate_end(s(a, "text"), 80)),
        "scroll" => asm.summary = format!("Tarayıcı: {} kaydır", if s(a, "direction") == "up" { "yukarı" } else { "aşağı" }),
        "tabs" => asm.summary = "Tarayıcı: sekmeler".into(),
        "switch_tab" => asm.summary = format!("Tarayıcı: {}. sekmeye geç", a["tab"]),
        "close_tab" => {
            asm.summary = "Tarayıcı: sekmeyi kapat".into();
            asm.risk = Risk::Interact;
        }
        "screenshot" => asm.summary = "Tarayıcı: ekran görüntüsü".into(),
        "wait_for_user" => asm.summary = format!("Kullanıcı bekleniyor: {}", truncate_end(s(a, "message"), 160)),
        "click" | "type" | "select" | "press" => {
            asm.risk = Risk::Interact;
            let r = ref_of(a).ok();
            let info = if action == "press" || r.is_some() { peek(ctx, if action == "press" { None } else { r }).await } else { None };
            let el = match (r, &info) {
                (Some(r), Some(i)) if action != "press" => show(r, i),
                (Some(r), _) => format!("[{r}]"),
                _ => "[?]".into(),
            };
            // Hassas işlemi araç, işlemden hemen önce ekran görüntüsüyle kendisi sorar: genel onay ikinci kez sorulmaz.
            // (Kesin denetim yine execute içinde, öğenin o anki hâline göre yapılır.)
            if let Some(i) = &info {
                let v = match action {
                    "click" => safety::click(i),
                    "type" => safety::typing(i, s(a, "text")),
                    "press" => safety::keypress(s(a, "key"), Some(i)),
                    _ => Verdict::Ok,
                };
                match v {
                    Verdict::Confirm(_) => asm.self_confirm = true,
                    Verdict::Block(m) => asm.block = Some(m),
                    Verdict::Ok => {}
                }
            }
            asm.summary = match action {
                "click" => format!("Tarayıcıda tıkla: {el}"),
                "type" => format!(
                    "Tarayıcıda yaz: {el} ← \"{}\"{}",
                    truncate_end(s(a, "text"), 80),
                    if a["submit"].as_bool() == Some(true) { " + Enter" } else { "" }
                ),
                "select" => format!("Tarayıcıda seç: {el} → \"{}\"", truncate_end(s(a, "value"), 60)),
                _ => format!("Tarayıcıda tuşa bas: {}", s(a, "key")),
            };
        }
        _ => {}
    }
    asm
}

fn label(action: &str, a: &Value) -> String {
    match action {
        "open" => format!("Açıyor: {}", truncate_end(s(a, "url"), 80)),
        "click" => format!("Tıklıyor: [{}]", a["ref"]),
        "type" => format!("Yazıyor: [{}]", a["ref"]),
        "select" => format!("Seçiyor: [{}]", a["ref"]),
        "press" => format!("Tuşa basıyor: {}", s(a, "key")),
        "scroll" => "Kaydırıyor".into(),
        "back" => "Geri gidiyor".into(),
        "screenshot" => "Ekran görüntüsü alıyor".into(),
        _ => "Sayfayı okuyor".into(),
    }
}

pub async fn execute(ctx: &ToolCtx, a: &Value) -> ToolResult {
    let settings = ctx.core.settings().browser;
    if !settings.enabled {
        return ToolResult::err("Tarayıcı kullanımı Ayarlar > Tarayıcı'dan kapatılmış.");
    }
    let mgr = ctx.core.browser.clone();
    let action = s(a, "action");
    if action == "wait_for_user" {
        return wait_for_user(ctx, &mgr, &settings, a).await;
    }
    let _op = mgr.op.lock().await;
    if mgr.user_has_control() {
        mgr.set_agent(Some("Kontrol sende; ajan bekliyor".into()));
        if !mgr.wait_released(&ctx.cancel).await {
            mgr.set_agent(None);
            return ToolResult::err("İptal edildi.");
        }
    }
    mgr.set_agent(Some(label(action, a)));
    let r = tokio::select! {
        r = run(ctx, &mgr, &settings, action, a) => r,
        _ = ctx.cancel.cancelled() => Err("İptal edildi.".into()),
    };
    mgr.set_agent(None);
    r.unwrap_or_else(ToolResult::err)
}

async fn run(ctx: &ToolCtx, mgr: &Arc<BrowserManager>, st: &BrowserSettings, action: &str, a: &Value) -> Result<ToolResult, String> {
    match action {
        "open" => {
            let url = agent_url(s(a, "url"))?;
            let (cdp, tab) = if a["new_tab"].as_bool() == Some(true) {
                mgr.new_tab(st, &url).await?
            } else {
                let (c, t) = mgr.tab(st).await?;
                mgr.navigate(&c, &t, &url).await?;
                (c, t)
            };
            page(mgr, &cdp, &tab, 0, AFTER_ACTION, vec![]).await
        }
        "snapshot" => {
            let (cdp, tab) = mgr.tab(st).await?;
            page(mgr, &cdp, &tab, a["offset"].as_u64().unwrap_or(0) as usize, SNAPSHOT, vec![]).await
        }
        "find" => {
            let q = s(a, "text").trim();
            if q.is_empty() {
                return Err("find için text gerekli".into());
            }
            let (cdp, tab) = mgr.tab(st).await?;
            let r = mgr.call_page(&cdp, &tab, "find", json!([q])).await?;
            let hits = r["hits"].as_array().cloned().unwrap_or_default();
            let mut out = header(&r, mgr);
            if hits.is_empty() {
                out.push_str(&format!("\n\"{q}\" sayfada bulunamadı. Sayfa uzunsa scroll ile aşağı in ya da başka bir kelime dene."));
            } else {
                out.push_str(&format!("\n\"{q}\" geçen satırlar ({}):\n", hits.len()));
                for h in hits {
                    out.push_str(h.as_str().unwrap_or(""));
                    out.push('\n');
                }
            }
            Ok(untrusted(out))
        }
        "click" => click(ctx, mgr, st, a).await,
        "type" => type_text(ctx, mgr, st, a).await,
        "select" => select(mgr, st, a).await,
        "press" => press(ctx, mgr, st, a).await,
        "scroll" => {
            let (cdp, tab) = mgr.tab(st).await?;
            let dir = if s(a, "direction") == "up" { "up" } else { "down" };
            let res = mgr.call_page(&cdp, &tab, "scroll", json!([a["ref"].as_i64(), dir])).await?;
            let moved = res["moved"].as_i64().unwrap_or(0);
            mgr.settle(&cdp, &tab).await;
            let note = if moved == 0 {
                format!("Kaydırılamadı: {} (ya da bu alan kaydırılamıyor).", if dir == "up" { "sayfanın başındasın" } else { "sayfanın sonundasın" })
            } else {
                format!("{} px {} kaydırıldı.", moved.abs(), if dir == "up" { "yukarı" } else { "aşağı" })
            };
            page(mgr, &cdp, &tab, 0, AFTER_ACTION, vec![note]).await
        }
        "back" => {
            let (cdp, tab) = mgr.tab(st).await?;
            if !mgr.history(&cdp, &tab, -1).await? {
                return Err("Geri gidilecek sayfa yok.".into());
            }
            mgr.settle(&cdp, &tab).await;
            page(mgr, &cdp, &tab, 0, AFTER_ACTION, vec![]).await
        }
        "tabs" => {
            mgr.ensure(st).await?;
            Ok(untrusted(tabs_text(mgr)))
        }
        "switch_tab" => {
            let n = a["tab"].as_u64().ok_or("tab gerekli: tabs listesindeki sekme numarası")? as usize;
            let cdp = mgr.ensure(st).await?;
            let list = mgr.tabs();
            let Some(t) = n.checked_sub(1).and_then(|i| list.get(i)) else {
                return Err(format!("{n}. sekme yok.\n{}", tabs_text(mgr)));
            };
            let (cdp, tab) = mgr.activate(&cdp, &t.id).await?;
            page(mgr, &cdp, &tab, 0, AFTER_ACTION, vec![]).await
        }
        "close_tab" => {
            mgr.ensure(st).await?;
            let list = mgr.tabs();
            let id = match a["tab"].as_u64() {
                Some(n) => (n as usize).checked_sub(1).and_then(|i| list.get(i)).map(|t| t.id.clone()).ok_or_else(|| format!("{n}. sekme yok."))?,
                None => list.iter().find(|t| t.active).map(|t| t.id.clone()).ok_or("etkin sekme yok")?,
            };
            mgr.close_tab(&id).await?;
            Ok(untrusted(format!("Sekme kapatıldı.\n{}", tabs_text(mgr))))
        }
        "screenshot" => {
            let (cdp, tab) = mgr.tab(st).await?;
            let data = mgr.screenshot(&cdp, &tab, 70).await?;
            let url = format!("data:image/jpeg;base64,{data}");
            let local = ctx.llm().is_local();
            let mut r = if ctx.vision && local {
                let mut r = ToolResult::ok("Tarayıcının ekran görüntüsü ektedir.");
                r.images.push(url.clone());
                r
            } else if ctx.vision {
                ToolResult::ok("Ekran görüntüsü kullanıcıya gösterildi; bu bağlantıda görsel modele gönderilemiyor. Sayfayı snapshot ile oku.")
            } else {
                ToolResult::ok("Ekran görüntüsü kullanıcıya gösterildi, ama bu model görsel göremiyor (görsel adaptörü yok). Sayfayı snapshot ile oku.")
            };
            r.ui = Some(json!({"image": url}));
            Ok(r)
        }
        _ => Err("Bilinmeyen action. Geçerli olanlar: open, snapshot, find, click, type, select, press, scroll, back, tabs, switch_tab, \
                  close_tab, screenshot, wait_for_user"
            .into()),
    }
}

fn untrusted(text: String) -> ToolResult {
    let mut r = ToolResult::ok(text);
    r.untrusted = true;
    r
}

async fn element(mgr: &BrowserManager, cdp: &Cdp, tab: &Tab, r: i64) -> Result<ElementInfo, String> {
    let v = mgr.call_page(cdp, tab, "info", json!([r])).await?;
    if v.is_null() {
        return Err(STALE.into());
    }
    serde_json::from_value(v).map_err(|e| e.to_string())
}

fn point_xy(p: &Value) -> Result<(f64, f64), String> {
    match p["err"].as_str() {
        None => Ok((p["x"].as_f64().unwrap_or(0.0), p["y"].as_f64().unwrap_or(0.0))),
        Some("gone") => Err(STALE.into()),
        Some("nobox") => Err("Öğe şu an görünmüyor (boyutu yok). Açılır bir menünün içindeyse önce menüyü aç, sonra snapshot al.".into()),
        Some("covered") => Err(format!(
            "Öğenin üstünde başka bir öğe var ({}). Önce onu kapat (ör. çerez bildirimi ya da açılır pencere) ya da snapshot alıp başka öğe seç.",
            p["by"].as_str().unwrap_or("?")
        )),
        Some(e) => Err(e.to_string()),
    }
}

/// Kullanıcının o anki onayını ister ("Tam otonom" modunda da). Kartta sayfanın ekran görüntüsü gösterilir.
async fn confirm(ctx: &ToolCtx, mgr: &BrowserManager, cdp: &Cdp, tab: &Tab, summary: &str, reason: &str) -> Result<(), String> {
    let shot = mgr.screenshot(cdp, tab, 50).await.ok().map(|b| format!("data:image/jpeg;base64,{b}"));
    mgr.set_agent(Some(format!("Onayın bekleniyor: {summary}")));
    let ans = super::approval(
        ctx,
        json!({"tool": "browser", "summary": summary, "reason": format!("Hassas işlem: {reason}"), "risk": Risk::Interact, "once": true, "image": shot}),
        Duration::from_secs(900),
    )
    .await;
    match ans {
        ApprovalAnswer::Allow | ApprovalAnswer::AllowSession => Ok(()),
        ApprovalAnswer::Deny(m) => Err(match m.filter(|t| !t.trim().is_empty()) {
            Some(t) => format!("Kullanıcı bu işlemi reddetti ve şunu söyledi: {t}"),
            None => "Kullanıcı bu işlemi reddetti. Yapma; başka bir yol dene ya da kullanıcıya ne yapmak istediğini sor.".into(),
        }),
    }
}

/// Etkin sekme az önce yeni bir sekme açtıysa ona geç.
async fn follow_popup(mgr: &Arc<BrowserManager>, cdp: &Arc<Cdp>, tab: &Tab, notes: &mut Vec<String>) -> (Arc<Cdp>, Tab) {
    if let Some(id) = mgr.take_popup() {
        if let Ok((c, t)) = mgr.activate(cdp, &id).await {
            mgr.settle(&c, &t).await;
            notes.push("İşlem yeni bir sekme açtı; o sekmeye geçildi (öncekine dönmek için tabs / switch_tab).".into());
            return (c, t);
        }
    }
    (cdp.clone(), tab.clone())
}

async fn click(ctx: &ToolCtx, mgr: &Arc<BrowserManager>, st: &BrowserSettings, a: &Value) -> Result<ToolResult, String> {
    let r = ref_of(a)?;
    let (cdp, tab) = mgr.tab(st).await?;
    let info = element(mgr, &cdp, &tab, r).await?;
    match safety::click(&info) {
        Verdict::Block(m) => return Err(m),
        Verdict::Confirm(reason) => {
            confirm(ctx, mgr, &cdp, &tab, &format!("Tıkla: {}", show(r, &info)), &reason).await?;
            mgr.accept_dialogs_for(Duration::from_secs(20));
        }
        Verdict::Ok => {}
    }
    let p = mgr.call_page(&cdp, &tab, "point", json!([r])).await?;
    let (x, y) = point_xy(&p)?;
    mgr.clear_popup();
    mgr.mouse_click(&cdp, &tab, x, y, 1).await?;
    mgr.settle(&cdp, &tab).await;
    let mut notes = vec![];
    let (cdp, tab) = follow_popup(mgr, &cdp, &tab, &mut notes).await;
    page(mgr, &cdp, &tab, 0, AFTER_ACTION, notes).await
}

async fn type_text(ctx: &ToolCtx, mgr: &Arc<BrowserManager>, st: &BrowserSettings, a: &Value) -> Result<ToolResult, String> {
    let r = ref_of(a)?;
    let text = s(a, "text");
    let submit = a["submit"].as_bool() == Some(true);
    let (cdp, tab) = mgr.tab(st).await?;
    let info = element(mgr, &cdp, &tab, r).await?;
    if let Verdict::Block(m) = safety::typing(&info, text) {
        return Err(m);
    }
    // Tıklayarak odaklan (sitenin açılır öneri kutusu ya da kendi giriş alanı açılsın); tıklanamıyorsa doğrudan odakla.
    let p = mgr.call_page(&cdp, &tab, "point", json!([r])).await?;
    let clicked = match point_xy(&p) {
        Ok((x, y)) => {
            mgr.mouse_click(&cdp, &tab, x, y, 1).await?;
            true
        }
        Err(e) if p["err"] == "gone" => return Err(e),
        Err(_) => false,
    };
    tokio::time::sleep(Duration::from_millis(200)).await;
    let prep = mgr.call_page(&cdp, &tab, "prepType", json!([r, !clicked])).await?;
    match prep["err"].as_str() {
        Some("gone") => return Err(STALE.into()),
        Some(_) => return Err(format!("{} bir yazı alanı değil. Yazı alanını sayfa çıktısında bul (textbox / searchbox).", show(r, &info))),
        None => {}
    }
    let target: ElementInfo = serde_json::from_value(prep["info"].clone()).unwrap_or_default();
    // Tıklama odağı başka bir alana (ör. şifre alanına) taşımış olabilir: denetim gerçek hedefe göre de yapılır.
    let verdict = match safety::typing(&target, text) {
        Verdict::Ok => safety::typing(&info, text),
        v => v,
    };
    match verdict {
        Verdict::Block(m) => return Err(m),
        Verdict::Confirm(reason) => {
            confirm(ctx, mgr, &cdp, &tab, &format!("Yaz: {} ← \"{}\"", show(r, &target), truncate_end(text, 80)), &reason).await?;
        }
        Verdict::Ok => {}
    }
    let tref = prep["ref"].as_i64().unwrap_or(r);
    if prep["date"] == true {
        mgr.call_page(&cdp, &tab, "setValue", json!([tref, text])).await?;
    } else if text.is_empty() {
        mgr.press(&cdp, &tab, "Delete").await?;
    } else {
        mgr.insert_text(&cdp, &tab, text).await?;
    }
    let mut notes = vec![];
    if let Some(v) = mgr.call_page(&cdp, &tab, "value", json!([tref])).await.ok().and_then(|v| v.as_str().map(String::from)) {
        notes.push(format!("[{tref}] alanının değeri: \"{}\"", truncate_end(&v, 120)));
    }
    if submit {
        if let Verdict::Confirm(reason) = safety::keypress("Enter", Some(&target)) {
            confirm(ctx, mgr, &cdp, &tab, &format!("Enter'a bas: {}", show(tref, &target)), &reason).await?;
        }
        mgr.clear_popup();
        mgr.press(&cdp, &tab, "Enter").await?;
    }
    mgr.settle(&cdp, &tab).await;
    let (cdp, tab) = follow_popup(mgr, &cdp, &tab, &mut notes).await;
    page(mgr, &cdp, &tab, 0, AFTER_ACTION, notes).await
}

async fn select(mgr: &Arc<BrowserManager>, st: &BrowserSettings, a: &Value) -> Result<ToolResult, String> {
    let r = ref_of(a)?;
    let v = s(a, "value");
    let (cdp, tab) = mgr.tab(st).await?;
    let info = element(mgr, &cdp, &tab, r).await?;
    let res = mgr.call_page(&cdp, &tab, "select", json!([r, v])).await?;
    match res["err"].as_str() {
        Some("gone") => Err(STALE.into()),
        Some("notselect") => Err(format!(
            "{} bir açılır liste (select) değil. Sitenin kendi açılır menüsünde önce öğeye, sonra seçeneğe tıkla.",
            show(r, &info)
        )),
        Some("nooption") => {
            let opts: Vec<String> = res["options"].as_array().map(|o| o.iter().filter_map(|x| x.as_str().map(String::from)).collect()).unwrap_or_default();
            Err(format!("\"{v}\" seçeneği yok. Seçenekler: {}", opts.join(" | ")))
        }
        _ => {
            mgr.settle(&cdp, &tab).await;
            page(mgr, &cdp, &tab, 0, AFTER_ACTION, vec![format!("Seçildi: \"{}\"", res["text"].as_str().unwrap_or(v))]).await
        }
    }
}

async fn press(ctx: &ToolCtx, mgr: &Arc<BrowserManager>, st: &BrowserSettings, a: &Value) -> Result<ToolResult, String> {
    let key = s(a, "key").trim();
    if key.is_empty() {
        return Err("key gerekli (ör. Enter, Tab, Escape, ArrowDown)".into());
    }
    crate::browser::input::parse_combo(key)?;
    let (cdp, tab) = mgr.tab(st).await?;
    let focused: Option<ElementInfo> = mgr.call_page(&cdp, &tab, "active", json!([])).await.ok().and_then(|v| serde_json::from_value(v).ok());
    if let Verdict::Confirm(reason) = safety::keypress(key, focused.as_ref()) {
        confirm(ctx, mgr, &cdp, &tab, &format!("Tuşa bas: {key}"), &reason).await?;
    }
    mgr.clear_popup();
    mgr.press(&cdp, &tab, key).await?;
    mgr.settle(&cdp, &tab).await;
    let mut notes = vec![];
    let (cdp, tab) = follow_popup(mgr, &cdp, &tab, &mut notes).await;
    page(mgr, &cdp, &tab, 0, AFTER_ACTION, notes).await
}

fn header(snap: &Value, mgr: &BrowserManager) -> String {
    let title = snap["title"].as_str().map(str::trim).filter(|t| !t.is_empty()).unwrap_or("(başlıksız)");
    let mut h = format!("Sayfa: {} — {}\n", truncate_end(title, 150), snap["url"].as_str().unwrap_or(""));
    let tabs = mgr.tabs();
    if tabs.len() > 1 {
        if let Some(i) = tabs.iter().position(|t| t.active) {
            h.push_str(&format!("Sekme {}/{}\n", i + 1, tabs.len()));
        }
    }
    h
}

fn tabs_text(mgr: &BrowserManager) -> String {
    let t = mgr.tabs();
    if t.is_empty() {
        return "Açık sekme yok.".into();
    }
    t.iter()
        .enumerate()
        .map(|(i, x)| {
            let title = if x.title.trim().is_empty() { "(başlıksız)" } else { x.title.trim() };
            format!("{}. {}{} — {}", i + 1, if x.active { "(etkin) " } else { "" }, truncate_end(title, 100), x.url)
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// Sayfanın metin görüntüsü (+ notlar). Tamamı dış kaynaklı veri olarak işaretlenir.
async fn page(mgr: &BrowserManager, cdp: &Cdp, tab: &Tab, offset: usize, max: usize, mut notes: Vec<String>) -> Result<ToolResult, String> {
    let snap = mgr.call_page(cdp, tab, "snapshot", json!([{}])).await?;
    notes.extend(mgr.take_notes());
    let text = snap["text"].as_str().unwrap_or("");
    let total = text.chars().count();
    let offset = offset.min(total);
    let body: String = text.chars().skip(offset).take(max).collect();
    let shown = body.chars().count();
    let mut out = header(&snap, mgr);
    for n in &notes {
        out.push_str(&format!("Not: {n}\n"));
    }
    if snap["captcha"] == true {
        out.push_str("Not: Sayfada bir doğrulama (CAPTCHA) var. Ajan bunu çözemez: wait_for_user ile kullanıcıdan çözmesini iste.\n");
    }
    if let Some(f) = snap["focus"].as_i64() {
        out.push_str(&format!("Odak: [{f}]\n"));
    }
    out.push('\n');
    if total == 0 {
        out.push_str("(Sayfada okunabilir metin yok. Sayfa hâlâ yükleniyor olabilir: biraz sonra snapshot al ya da screenshot dene.)");
    } else {
        out.push_str(&body);
        if offset + shown < total {
            out.push_str(&format!(
                "\n\n[Sayfa metni {total} karakter; {offset}-{} arası gösterildi. Devamı: snapshot offset={}]",
                offset + shown,
                offset + shown
            ));
        }
    }
    let mut r = untrusted(out);
    r.ui = Some(json!({"url": snap["url"], "title": snap["title"]}));
    Ok(r)
}

/// Kullanıcının tarayıcıda bir işi yapmasını bekler (giriş, CAPTCHA, ödeme, dosya seçimi…).
async fn wait_for_user(ctx: &ToolCtx, mgr: &Arc<BrowserManager>, st: &BrowserSettings, a: &Value) -> ToolResult {
    let msg = s(a, "message").trim();
    let msg = if msg.is_empty() { "Tarayıcıda gereken işlemi yapıp Devam'a bas." } else { msg };
    let before = mgr.status().tabs.into_iter().find(|t| t.active).map(|t| t.url).filter(|u| u.starts_with("http"));
    if mgr.is_running() {
        let _ = mgr.front(st).await;
    }
    mgr.set_agent(Some(format!("Seni bekliyor: {}", truncate_end(msg, 120))));
    let ans = super::approval(
        ctx,
        json!({"tool": "browser", "summary": msg, "reason": "Ajan seni bekliyor", "risk": Risk::Read, "wait": true, "once": true}),
        Duration::from_secs(3600),
    )
    .await;
    mgr.set_agent(None);
    match ans {
        ApprovalAnswer::Allow | ApprovalAnswer::AllowSession => {
            let _op = mgr.op.lock().await;
            let res = async {
                let restarted = !mgr.is_running();
                let (cdp, tab) = mgr.tab(st).await?;
                let mut notes = vec!["Kullanıcı işini bitirdi ve devam et dedi.".to_string()];
                // Kullanıcı bu arada hesap giriş penceresini kullandıysa tarayıcı yeniden açılmıştır: kalınan sayfaya dön.
                if let Some(u) = mgr.take_resume_url().or(before).filter(|_| restarted) {
                    mgr.navigate(&cdp, &tab, &u).await?;
                    notes.push(format!("Tarayıcı bu arada kapanıp yeniden açıldı (ör. hesap girişi için); önceki sayfa yeniden açıldı: {u}"));
                }
                mgr.settle(&cdp, &tab).await;
                page(mgr, &cdp, &tab, 0, AFTER_ACTION, notes).await
            }
            .await;
            res.unwrap_or_else(|e| ToolResult::ok(format!("Kullanıcı devam et dedi. (Sayfa okunamadı: {e})")))
        }
        ApprovalAnswer::Deny(m) => ToolResult::ok(match m.filter(|t| !t.trim().is_empty()) {
            Some(t) => format!("Kullanıcı devam etmedi ve şunu söyledi: {t}"),
            None => "Kullanıcı bu adımı yapmadı (vazgeçti ya da yanıt vermedi). Ne yapmak istediğini kullanıcıya sor.".into(),
        }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn urls_and_refs() {
        assert_eq!(agent_url("google.com").unwrap(), "https://google.com");
        assert!(agent_url("istanbul otelleri").is_err());
        assert!(agent_url("chrome://settings").is_err());
        assert_eq!(agent_url("http://localhost:3000/a").unwrap(), "http://localhost:3000/a");
        assert_eq!(ref_of(&json!({"ref": 12})).unwrap(), 12);
        assert_eq!(ref_of(&json!({"ref": "[7]"})).unwrap(), 7);
        assert_eq!(ref_of(&json!({"ref": 3.0})).unwrap(), 3);
        assert!(ref_of(&json!({})).is_err());
    }

    #[test]
    fn spec_is_valid() {
        let s = spec();
        assert_eq!(s["function"]["name"], "browser");
        assert!(s["function"]["parameters"]["properties"]["action"]["enum"].as_array().unwrap().len() >= 14);
    }
}
