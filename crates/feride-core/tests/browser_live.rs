//! Gerçek tarayıcıyla uçtan uca deneme (Chrome/Edge gerekir). Bilgisayarda pencere açtığı için yalnızca
//! `FERIDE_BROWSER_TEST=1` ile çalışır:  FERIDE_BROWSER_TEST=1 cargo test -p feride-core --test browser_live -- --nocapture

use feride_core::browser::safety::{self, ElementInfo, Verdict};
use feride_core::browser::BrowserManager;
use feride_core::config::BrowserSettings;
use feride_core::events::EventBus;
use feride_core::paths::Paths;
use serde_json::json;
use std::path::PathBuf;
use std::sync::Arc;

const INDEX: &str = r#"<!doctype html><html lang="tr"><head><meta charset="utf-8"><title>FerIDE Test Uçuşları</title>
<style>.btn{cursor:pointer;padding:4px} #hidden{display:none} .sr{position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0,0,0,0)}</style></head>
<body>
<h1>Uçuş ara</h1>
<form id="f" action="/results.html" method="get">
  <label for="from">Nereden</label> <input id="from" name="from" placeholder="Şehir">
  <label>Nereye <input id="to" name="to"></label>
  <label for="pw">Şifre</label> <input id="pw" type="password">
  <select id="cls" name="cls" aria-label="Kabin sınıfı"><option value="eco">Ekonomi</option><option value="bus">Business</option></select>
  <label><input type="checkbox" id="direct" name="direct"> Aktarmasız</label>
  <input type="date" id="date" name="date" aria-label="Gidiş tarihi">
  <button type="submit">Ara</button>
</form>
<div class="btn" id="card" onclick="document.getElementById('out').textContent='Kart seçildi'">İstanbul → Roma 2.450 TL</div>
<div id="out">-</div>
<button id="pay" onclick="document.getElementById('out').textContent = confirm('Ödemeyi onaylıyor musunuz?') ? 'Ödendi' : 'İptal'">Satın al</button>
<a href="/popup.html" target="_blank">Yeni sekmede aç</a>
<span class="sr">Ekran okuyucu metni</span>
<div id="hidden">Gizli metin</div>
<my-widget></my-widget>
<iframe src="/frame.html" style="width:300px;height:90px"></iframe>
<div contenteditable="true" aria-label="Mesaj" style="border:1px solid #999;min-height:30px"></div>
<script>
customElements.define('my-widget', class extends HTMLElement { constructor() { super(); const r = this.attachShadow({mode: 'open'});
  r.innerHTML = '<button id="sb">Gölge düğmesi</button><p>Gölge metni</p>';
  r.querySelector('#sb').onclick = () => { document.getElementById('out').textContent = 'Gölge tıklandı'; }; } });
document.getElementById('from').addEventListener('input', (e) => { document.getElementById('out').textContent = 'Yazılan: ' + e.target.value; });
</script></body></html>"#;

async fn serve(root: PathBuf) -> u16 {
    let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    tokio::spawn(async move {
        while let Ok((mut s, _)) = l.accept().await {
            let root = root.clone();
            tokio::spawn(async move {
                use tokio::io::{AsyncReadExt, AsyncWriteExt};
                let mut buf = vec![0u8; 8192];
                let n = s.read(&mut buf).await.unwrap_or(0);
                let req = String::from_utf8_lossy(&buf[..n]).to_string();
                let path = req.split_whitespace().nth(1).unwrap_or("/").split('?').next().unwrap_or("/").trim_start_matches('/').to_string();
                let file = root.join(if path.is_empty() { "index.html" } else { path.as_str() });
                let (status, body) = match std::fs::read(&file) {
                    Ok(b) => ("200 OK", b),
                    Err(_) => ("404 Not Found", b"yok".to_vec()),
                };
                let head = format!("HTTP/1.1 {status}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", body.len());
                let _ = s.write_all(head.as_bytes()).await;
                let _ = s.write_all(&body).await;
            });
        }
    });
    port
}

/// Sayfa metninde `needle` öncesindeki [numara].
fn ref_for(text: &str, needle: &str) -> i64 {
    let re = regex::Regex::new(&format!(r"\[(\d+)\] {}", regex::escape(needle))).unwrap();
    re.captures(text).unwrap_or_else(|| panic!("bulunamadı: {needle}\n---\n{text}"))[1].parse().unwrap()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn live_browser() {
    if std::env::var("FERIDE_BROWSER_TEST").is_err() {
        eprintln!("FERIDE_BROWSER_TEST verilmedi; atlandı.");
        return;
    }
    let st = BrowserSettings::default();
    let Some(b) = feride_core::browser::find(&st) else {
        eprintln!("tarayıcı yok; atlandı.");
        return;
    };
    eprintln!("tarayıcı: {} ({})", b.name, b.path.display());
    let dir = tempfile::tempdir().unwrap();
    let site = dir.path().join("site");
    std::fs::create_dir_all(&site).unwrap();
    std::fs::write(site.join("index.html"), INDEX).unwrap();
    std::fs::write(site.join("results.html"), r#"<!doctype html><meta charset="utf-8"><title>Sonuçlar</title><h2>Sonuçlar</h2><p id="q"></p><script>document.getElementById('q').textContent = 'Arama: ' + location.search;</script>"#).unwrap();
    std::fs::write(site.join("popup.html"), r#"<!doctype html><meta charset="utf-8"><title>Açılan sekme</title><p>Burası yeni sekme</p>"#).unwrap();
    std::fs::write(site.join("frame.html"), r#"<!doctype html><meta charset="utf-8"><p>Çerçeve içeriği</p><button>Çerçeve düğmesi</button>"#).unwrap();
    let port = serve(site).await;
    let base = format!("http://127.0.0.1:{port}");

    let mgr = Arc::new(BrowserManager::new(Paths::with_data_dir(dir.path().join("data")), EventBus::new()));
    // Bir denetim patlasa bile tarayıcı açık kalmasın.
    struct Close(Arc<BrowserManager>);
    impl Drop for Close {
        fn drop(&mut self) {
            self.0.shutdown();
        }
    }
    let _close = Close(mgr.clone());
    let (cdp, tab) = mgr.tab(&st).await.expect("tarayıcı açılmalı");
    eprintln!("tarayıcı süreci: {:?}", mgr.pid());
    let res: Result<(), String> = async {
        let first = tab.target.clone();
        mgr.navigate(&cdp, &tab, &format!("{base}/index.html")).await?;
        // Kontrol edilen tarayıcı bunu sitelere dürüstçe bildirir (gizlenmez); hesap girişleri için ayrı, kontrolsüz
        // giriş penceresi var (BrowserManager::open_login).
        assert_eq!(mgr.eval(&cdp, &tab, "navigator.webdriver").await?, json!(true));

        let snap = mgr.call_page(&cdp, &tab, "snapshot", json!([{}])).await?;
        let text = snap["text"].as_str().unwrap().to_string();
        println!("--- sayfa ---\n{text}\n-------------");
        assert_eq!(snap["title"], "FerIDE Test Uçuşları");
        assert!(text.contains("# Uçuş ara"));
        for needle in [r#"textbox "Nereden""#, r#"textbox "Nereye""#, "(password)", r#"select "Kabin sınıfı" value="Ekonomi" options: Ekonomi | Business"#,
                       r#"checkbox "Aktarmasız""#, r#"date "Gidiş tarihi""#, r#"button "Ara""#, r#"clickable "İstanbul → Roma 2.450 TL""#,
                       r#"button "Satın al""#, r#"link "Yeni sekmede aç""#, r#"button "Gölge düğmesi""#, "Gölge metni", "Çerçeve içeriği",
                       r#"button "Çerçeve düğmesi""#, r#"textbox "Mesaj""#] {
            assert!(text.contains(needle), "sayfa görüntüsünde yok: {needle}");
        }
        assert!(!text.contains("Gizli metin") && !text.contains("Ekran okuyucu metni"), "gizli metinler görünmemeli");

        // Yazma: tıkla + seç + insertText; sayfanın input olayı çalışmalı.
        let from = ref_for(&text, r#"textbox "Nereden""#);
        let p = mgr.call_page(&cdp, &tab, "point", json!([from])).await?;
        mgr.mouse_click(&cdp, &tab, p["x"].as_f64().unwrap(), p["y"].as_f64().unwrap(), 1).await?;
        let prep = mgr.call_page(&cdp, &tab, "prepType", json!([from, false])).await?;
        assert_eq!(prep["ok"], true, "{prep}");
        mgr.insert_text(&cdp, &tab, "İstanbul").await?;
        assert_eq!(mgr.call_page(&cdp, &tab, "value", json!([from])).await?, "İstanbul");
        assert_eq!(mgr.eval(&cdp, &tab, "document.getElementById('out').textContent").await?, "Yazılan: İstanbul");
        // Üzerine yazma: önceki metin seçilip değiştirilir.
        mgr.call_page(&cdp, &tab, "prepType", json!([from, true])).await?;
        mgr.insert_text(&cdp, &tab, "Ankara").await?;
        assert_eq!(mgr.call_page(&cdp, &tab, "value", json!([from])).await?, "Ankara");

        // Şifre alanına yazılamaz.
        let pw = ref_for(&text, r#"textbox "Şifre" (password)"#);
        let info: ElementInfo = serde_json::from_value(mgr.call_page(&cdp, &tab, "info", json!([pw])).await?).unwrap();
        assert!(matches!(safety::typing(&info, "x"), Verdict::Block(_)));

        // Açılır liste, onay kutusu, tarih.
        let cls = ref_for(&text, r#"select "Kabin sınıfı""#);
        assert_eq!(mgr.call_page(&cdp, &tab, "select", json!([cls, "business"])).await?["ok"], true);
        assert_eq!(mgr.eval(&cdp, &tab, "document.getElementById('cls').value").await?, "bus");
        let direct = ref_for(&text, r#"checkbox "Aktarmasız""#);
        let p = mgr.call_page(&cdp, &tab, "point", json!([direct])).await?;
        mgr.mouse_click(&cdp, &tab, p["x"].as_f64().unwrap(), p["y"].as_f64().unwrap(), 1).await?;
        assert_eq!(mgr.eval(&cdp, &tab, "document.getElementById('direct').checked").await?, true);
        let date = ref_for(&text, r#"date "Gidiş tarihi""#);
        assert_eq!(mgr.call_page(&cdp, &tab, "prepType", json!([date, true])).await?["date"], true);
        mgr.call_page(&cdp, &tab, "setValue", json!([date, "2026-12-24"])).await?;
        assert_eq!(mgr.eval(&cdp, &tab, "document.getElementById('date').value").await?, "2026-12-24");

        // Betikle tıklanan kart ve gölge DOM içindeki düğme.
        for (needle, expect) in [(r#"clickable "İstanbul → Roma 2.450 TL""#, "Kart seçildi"), (r#"button "Gölge düğmesi""#, "Gölge tıklandı")] {
            let r = ref_for(&text, needle);
            let p = mgr.call_page(&cdp, &tab, "point", json!([r])).await?;
            assert!(p["err"].is_null(), "{needle}: {p}");
            mgr.mouse_click(&cdp, &tab, p["x"].as_f64().unwrap(), p["y"].as_f64().unwrap(), 1).await?;
            mgr.settle(&cdp, &tab).await;
            assert_eq!(mgr.eval(&cdp, &tab, "document.getElementById('out').textContent").await?, expect);
        }

        // "Satın al" hassas sayılır; açtığı onay penceresi önce iptal edilir, kullanıcı onayından sonra kabul edilir.
        let pay = ref_for(&text, r#"button "Satın al""#);
        let info: ElementInfo = serde_json::from_value(mgr.call_page(&cdp, &tab, "info", json!([pay])).await?).unwrap();
        assert!(matches!(safety::click(&info), Verdict::Confirm(_)));
        for (approved, expect) in [(false, "İptal"), (true, "Ödendi")] {
            if approved {
                mgr.accept_dialogs_for(std::time::Duration::from_secs(10));
            }
            let p = mgr.call_page(&cdp, &tab, "point", json!([pay])).await?;
            mgr.mouse_click(&cdp, &tab, p["x"].as_f64().unwrap(), p["y"].as_f64().unwrap(), 1).await?;
            mgr.settle(&cdp, &tab).await;
            assert_eq!(mgr.eval(&cdp, &tab, "document.getElementById('out').textContent").await?, expect);
            let notes = mgr.take_notes();
            assert!(notes.iter().any(|n| n.contains("Ödemeyi onaylıyor musunuz?")), "{notes:?}");
        }

        // Metin arama.
        let found = mgr.call_page(&cdp, &tab, "find", json!(["roma"])).await?;
        assert!(found["hits"][0].as_str().unwrap().contains("clickable"), "{found}");

        // Yeni sekme açan bağlantı.
        mgr.clear_popup();
        let link = ref_for(&text, r#"link "Yeni sekmede aç""#);
        let p = mgr.call_page(&cdp, &tab, "point", json!([link])).await?;
        mgr.mouse_click(&cdp, &tab, p["x"].as_f64().unwrap(), p["y"].as_f64().unwrap(), 1).await?;
        mgr.settle(&cdp, &tab).await;
        let mut popup = None;
        for _ in 0..20 {
            popup = mgr.take_popup();
            if popup.is_some() {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        }
        let popup = popup.expect("yeni sekme algılanmalı");
        let (c2, t2) = mgr.activate(&cdp, &popup).await?;
        mgr.settle(&c2, &t2).await;
        let s2 = mgr.call_page(&c2, &t2, "snapshot", json!([{}])).await?;
        assert_eq!(s2["title"], "Açılan sekme");
        assert_eq!(mgr.tabs().len(), 2);
        mgr.close_tab(&popup).await?;
        let (cdp, tab) = mgr.activate(&cdp, &first).await?;

        // Formu Enter ile gönder, sonra geri git.
        mgr.call_page(&cdp, &tab, "prepType", json!([from, true])).await?;
        mgr.insert_text(&cdp, &tab, "İzmir").await?;
        mgr.press(&cdp, &tab, "Enter").await?;
        mgr.settle(&cdp, &tab).await;
        let s3 = mgr.call_page(&cdp, &tab, "snapshot", json!([{}])).await?;
        assert_eq!(s3["title"], "Sonuçlar", "{s3}");
        assert!(s3["text"].as_str().unwrap().contains("from=%C4%B0zmir"), "{s3}");
        // Eski numaralar yeni belgede geçersiz.
        assert!(mgr.call_page(&cdp, &tab, "info", json!([from])).await?.is_null());
        assert!(mgr.history(&cdp, &tab, -1).await?);
        mgr.settle(&cdp, &tab).await;
        let s4 = mgr.call_page(&cdp, &tab, "snapshot", json!([{}])).await?;
        assert_eq!(s4["title"], "FerIDE Test Uçuşları");

        // Düzenlenebilir alan (ör. e-posta gövdesi).
        let msg = ref_for(s4["text"].as_str().unwrap(), r#"textbox "Mesaj""#);
        let p = mgr.call_page(&cdp, &tab, "point", json!([msg])).await?;
        mgr.mouse_click(&cdp, &tab, p["x"].as_f64().unwrap(), p["y"].as_f64().unwrap(), 1).await?;
        let prep = mgr.call_page(&cdp, &tab, "prepType", json!([msg, false])).await?;
        assert_eq!(prep["info"]["multiline"], true);
        mgr.insert_text(&cdp, &tab, "Merhaba").await?;
        assert_eq!(mgr.call_page(&cdp, &tab, "value", json!([msg])).await?, "Merhaba");

        let shot = mgr.screenshot(&cdp, &tab, 60).await?;
        assert!(shot.len() > 1000);
        Ok(())
    }
    .await;
    mgr.close().await;
    assert!(!mgr.is_running(), "tarayıcı kapanmalı");
    res.unwrap();
}
