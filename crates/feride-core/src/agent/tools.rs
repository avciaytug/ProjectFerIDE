//! Ajan araçları.

use regex::Regex;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::net::IpAddr;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use super::permissions::Risk;
use super::ToolCtx;
use crate::util::{truncate_end, truncate_middle};

pub struct ToolResult {
    pub content: String,
    pub ok: bool,
    /// Dış kaynaktan gelen içerik (web, belge, MCP): modele güvenilmeyen veri olarak verilir.
    pub untrusted: bool,
    /// Arayüze ek bilgi (fark, dosya yolu…).
    pub ui: Option<Value>,
}

impl ToolResult {
    pub fn ok(s: impl Into<String>) -> Self {
        Self { content: s.into(), ok: true, untrusted: false, ui: None }
    }
    pub fn err(s: impl Into<String>) -> Self {
        Self { content: format!("HATA: {}", s.into()), ok: false, untrusted: false, ui: None }
    }
    fn untrusted(mut self) -> Self {
        self.untrusted = true;
        self
    }
    fn with_ui(mut self, v: Value) -> Self {
        self.ui = Some(v);
        self
    }
}

/// İzin değerlendirmesi için araç çağrısının özeti.
pub struct Assessment {
    pub risk: Risk,
    pub command: Option<String>,
    pub targets: Vec<PathBuf>,
    pub private_network: bool,
    pub summary: String,
    /// Onay kartında gösterilecek fark (yazma araçları).
    pub preview: Option<String>,
}

fn s<'a>(a: &'a Value, k: &str) -> &'a str {
    a.get(k).and_then(|v| v.as_str()).unwrap_or("")
}

fn obj(props: Value, required: &[&str]) -> Value {
    json!({"type": "object", "properties": props, "required": required})
}

fn spec(name: &str, description: &str, params: Value) -> Value {
    json!({"type": "function", "function": {"name": name, "description": description, "parameters": params}})
}

/// Ajana sunulan araç tanımları. `explore`: yalnızca okuma araçları (alt ajan).
pub fn builtin_specs(explore: bool, can_spawn: bool, docs: bool) -> Vec<Value> {
    let mut v = vec![
        spec(
            "read_file",
            "Metin dosyasını satır numaralarıyla okur. Büyük dosyalarda offset/limit kullan. PDF/Office/görsel için read_document.",
            obj(json!({
                "path": {"type": "string", "description": "Dosya yolu (çalışma alanına göre veya mutlak)"},
                "offset": {"type": "integer", "description": "Başlangıç satırı (1'den)"},
                "limit": {"type": "integer", "description": "Okunacak satır sayısı (varsayılan 2000)"}
            }), &["path"]),
        ),
        spec(
            "list_directory",
            "Klasör içeriğini ağaç olarak listeler (node_modules, target, .git gibi ağır klasörler atlanır).",
            obj(json!({"path": {"type": "string"}, "depth": {"type": "integer", "description": "1-4, varsayılan 2"}}), &[]),
        ),
        spec(
            "glob",
            "Desene uyan dosyaları bulur (ör. **/*.rs, src/**/test_*.py). .gitignore'a uyar; en yeni değişen önce.",
            obj(json!({"pattern": {"type": "string"}, "path": {"type": "string", "description": "Arama kökü"}}), &["pattern"]),
        ),
        spec(
            "grep",
            "Dosya içeriklerinde düzenli ifade arar; dosya:satır: metin döndürür.",
            obj(json!({
                "pattern": {"type": "string", "description": "Düzenli ifade"},
                "path": {"type": "string"},
                "include": {"type": "string", "description": "Dosya deseni, ör. *.ts"},
                "case_insensitive": {"type": "boolean"},
                "max_results": {"type": "integer"}
            }), &["pattern"]),
        ),
        spec(
            "web_search",
            "İnternette arama yapar (DuckDuckGo). Başlık, adres ve özet döndürür.",
            obj(json!({"query": {"type": "string"}, "max_results": {"type": "integer"}}), &["query"]),
        ),
        spec(
            "fetch_url",
            "Web sayfasını indirip okunabilir metne çevirir.",
            obj(json!({"url": {"type": "string"}, "max_chars": {"type": "integer"}}), &["url"]),
        ),
        spec(
            "use_skill",
            "Bir skill'in talimatlarını yükler. Göreve uyan bir skill varsa işe başlamadan önce kullan.",
            obj(json!({"name": {"type": "string"}}), &["name"]),
        ),
        spec(
            "recall",
            "Kalıcı hafızada (önceki konuşmalardan öğrenilenler) arama yapar.",
            obj(json!({"query": {"type": "string"}}), &["query"]),
        ),
        spec(
            "process",
            "Arka planda başlatılan komutları yönetir: list, output (çıktıyı oku), kill.",
            obj(json!({"action": {"type": "string", "enum": ["list", "output", "kill"]}, "id": {"type": "string"}}), &["action"]),
        ),
    ];
    if docs {
        v.push(spec(
            "read_document",
            "PDF, Word, Excel, PowerPoint, görsel (OCR), ses (Whisper) ve AutoCAD (.dwg/.dxf) dosyalarını metne çevirir.",
            obj(json!({"path": {"type": "string"}}), &["path"]),
        ));
    }
    if explore {
        return v;
    }
    v.extend([
        spec(
            "write_file",
            "Dosya oluşturur veya tamamen yeniden yazar. Var olan dosyada küçük değişiklik için edit_file kullan.",
            obj(json!({"path": {"type": "string"}, "content": {"type": "string"}}), &["path", "content"]),
        ),
        spec(
            "edit_file",
            "Dosyada metin değiştirir. old_string dosyada AYNEN (boşluklar dahil) ve tek kez geçmeli; değilse daha fazla bağlam ekle ya da replace_all kullan. Önce read_file ile oku.",
            obj(json!({
                "path": {"type": "string"},
                "old_string": {"type": "string"},
                "new_string": {"type": "string"},
                "replace_all": {"type": "boolean"}
            }), &["path", "old_string", "new_string"]),
        ),
        spec(
            "run_command",
            "Kabukta komut çalıştırır ve çıktısını döndürür. Uzun süren işler (sunucu, izleme) için background=true.",
            obj(json!({
                "command": {"type": "string"},
                "cwd": {"type": "string", "description": "Çalışma klasörü (varsayılan: çalışma alanı)"},
                "timeout_secs": {"type": "integer"},
                "background": {"type": "boolean"}
            }), &["command"]),
        ),
        spec(
            "todo_write",
            "Çok adımlı işlerde yapılacaklar listesini yazar/günceller (kullanıcı arayüzde görür). Her seferinde listenin tamamını gönder.",
            obj(json!({"todos": {"type": "array", "items": {"type": "object", "properties": {
                "content": {"type": "string"},
                "status": {"type": "string", "enum": ["pending", "in_progress", "completed"]}
            }, "required": ["content", "status"]}}}), &["todos"]),
        ),
        spec(
            "remember",
            "Kullanıcı hakkında ya da proje hakkında kalıcı olarak hatırlanması gereken bir bilgiyi kaydeder.",
            obj(json!({
                "content": {"type": "string"},
                "kind": {"type": "string", "enum": ["fact", "preference", "project", "experience"]},
                "tags": {"type": "string"}
            }), &["content"]),
        ),
        spec(
            "save_skill",
            "Tekrar kullanılabilir bir çalışma yöntemini skill olarak kaydeder.",
            obj(json!({"name": {"type": "string"}, "description": {"type": "string"}, "content": {"type": "string"}}), &["name", "description", "content"]),
        ),
        spec(
            "open_in_system",
            "Dosya, klasör veya web adresini kullanıcının varsayılan uygulamasıyla açar.",
            obj(json!({"path": {"type": "string"}}), &["path"]),
        ),
    ]);
    if docs {
        v.push(spec(
            "edit_document",
            "Word, Excel/CSV, PowerPoint, PDF, AutoCAD (.dwg/.dxf), görsel ve ses dosyası oluşturur/düzenler/dönüştürür. \
             category + action + output_path ver; içerik alanları kategoriye göre değişir (title, paragraphs, sections, headers, rows, cells, slides, replacements, operations, input_path, input_paths, width, height, rotate, start_sec, end_sec).",
            json!({"type": "object", "properties": {
                "category": {"type": "string", "enum": ["docx", "xlsx", "pptx", "pdf", "cad", "image", "audio"]},
                "action": {"type": "string"},
                "input_path": {"type": "string"},
                "output_path": {"type": "string"}
            }, "required": ["category", "output_path"], "additionalProperties": true}),
        ));
    }
    if can_spawn {
        v.push(spec(
            "spawn_agent",
            "Bağımsız bir alt görevi ayrı bağlamda çalışan bir alt ajana verir; sonucunu özet olarak döndürür. \
             mode=explore: yalnızca okur/araştırır (geniş kod taraması için ideal). mode=general: dosya değiştirebilir.",
            obj(json!({"task": {"type": "string"}, "mode": {"type": "string", "enum": ["explore", "general"]}}), &["task"]),
        ));
    }
    v
}

pub fn resolve_path(ctx: &ToolCtx, raw: &str) -> PathBuf {
    let raw = raw.trim().trim_matches('"');
    let p = crate::paths::expand_tilde(raw, &ctx.core.paths.home);
    // Git Bash biçimi: /c/Users/... → C:\Users\...
    #[cfg(windows)]
    let p = {
        let st = p.to_string_lossy().to_string();
        let b = st.as_bytes();
        if b.len() >= 3 && b[0] == b'/' && b[1].is_ascii_alphabetic() && b[2] == b'/' {
            PathBuf::from(format!("{}:\\{}", (b[1] as char).to_ascii_uppercase(), st[3..].replace('/', "\\")))
        } else {
            p
        }
    };
    let abs = if p.is_absolute() { p } else { ctx.workspace.join(p) };
    crate::paths::normalize(&abs)
}

const DOC_EXTS: &[&str] = &[
    "pdf", "docx", "doc", "odt", "xlsx", "xls", "ods", "pptx", "ppt", "odp", "png", "jpg", "jpeg", "webp", "gif", "bmp", "tif", "tiff",
    "mp3", "wav", "flac", "ogg", "m4a", "aac", "opus", "dwg", "dxf",
];
const EXEC_EXTS: &[&str] = &["exe", "bat", "cmd", "ps1", "msi", "sh", "bash", "command", "app", "appimage", "run", "bin", "jar", "py", "vbs", "lnk", "scr", "desktop"];

fn ext_of(p: &Path) -> String {
    p.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default()
}

/// Çağrının riskini ve hedeflerini belirler (izin katmanı için).
pub fn assess(ctx: &ToolCtx, name: &str, a: &Value) -> Assessment {
    let mut asm = Assessment { risk: Risk::Read, command: None, targets: vec![], private_network: false, summary: String::new(), preview: None };
    match name {
        "read_file" | "read_document" => asm.summary = format!("Oku: {}", s(a, "path")),
        "list_directory" => asm.summary = format!("Listele: {}", if s(a, "path").is_empty() { "." } else { s(a, "path") }),
        "glob" => asm.summary = format!("Dosya ara: {}", s(a, "pattern")),
        "grep" => asm.summary = format!("İçerik ara: {}", s(a, "pattern")),
        "write_file" => {
            let p = resolve_path(ctx, s(a, "path"));
            let old = std::fs::read_to_string(&p).unwrap_or_default();
            asm.preview = Some(unified_diff(&old, s(a, "content"), &p));
            asm.summary = format!("{} {}", if p.exists() { "Yeniden yaz:" } else { "Oluştur:" }, p.display());
            asm.risk = Risk::Write;
            asm.targets.push(p);
        }
        "edit_file" => {
            let p = resolve_path(ctx, s(a, "path"));
            if let Ok(old) = std::fs::read_to_string(&p) {
                if let Ok((new, _)) = apply_edit(&old, s(a, "old_string"), s(a, "new_string"), a["replace_all"].as_bool().unwrap_or(false)) {
                    asm.preview = Some(unified_diff(&old, &new, &p));
                }
            }
            asm.summary = format!("Düzenle: {}", p.display());
            asm.risk = Risk::Write;
            asm.targets.push(p);
        }
        "edit_document" => {
            let p = resolve_path(ctx, s(a, "output_path"));
            asm.summary = format!("Belge oluştur/düzenle: {}", p.display());
            asm.risk = Risk::Write;
            asm.targets.push(p);
        }
        "save_skill" => {
            asm.summary = format!("Skill kaydet: {}", s(a, "name"));
            asm.risk = Risk::Write;
            asm.targets.push(ctx.core.paths.skills().join(s(a, "name")));
        }
        "run_command" => {
            let cmd = s(a, "command").to_string();
            asm.summary = format!("$ {}", truncate_end(&cmd, 300));
            asm.risk = Risk::Execute;
            asm.command = Some(cmd);
        }
        "process" => {
            asm.summary = format!("Arka plan işlemi: {} {}", s(a, "action"), s(a, "id"));
        }
        "web_search" => {
            asm.summary = format!("Web'de ara: {}", s(a, "query"));
            asm.risk = Risk::Network;
        }
        "fetch_url" => {
            let u = s(a, "url");
            asm.summary = format!("Sayfa oku: {u}");
            asm.risk = Risk::Network;
            asm.private_network = is_private_url(u);
        }
        "open_in_system" => {
            let raw = s(a, "path");
            if raw.starts_with("http://") || raw.starts_with("https://") {
                asm.summary = format!("Tarayıcıda aç: {raw}");
                asm.private_network = is_private_url(raw);
            } else {
                let p = resolve_path(ctx, raw);
                asm.summary = format!("Sistemde aç: {}", p.display());
                if EXEC_EXTS.contains(&ext_of(&p).as_str()) {
                    asm.risk = Risk::Execute;
                    asm.command = Some(p.display().to_string());
                }
            }
        }
        "spawn_agent" => asm.summary = format!("Alt ajan: {}", truncate_end(s(a, "task"), 160)),
        "todo_write" => asm.summary = "Yapılacaklar listesi".into(),
        "remember" => asm.summary = format!("Hatırla: {}", truncate_end(s(a, "content"), 120)),
        "recall" => asm.summary = format!("Hafızada ara: {}", s(a, "query")),
        "use_skill" => asm.summary = format!("Skill: {}", s(a, "name")),
        n if n.starts_with("mcp__") => {
            let ro = ctx.core.mcp.tools().iter().find(|t| t.full_name == n).map(|t| t.read_only).unwrap_or(false);
            asm.risk = if ro { Risk::Read } else { Risk::Execute };
            asm.summary = format!("MCP: {}", n.trim_start_matches("mcp__").replacen("__", " → ", 1));
            asm.command = None;
        }
        _ => asm.summary = name.to_string(),
    }
    asm
}

pub fn unified_diff(old: &str, new: &str, path: &Path) -> String {
    let d = similar::TextDiff::from_lines(old, new);
    let name = path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
    let text = d.unified_diff().context_radius(3).header(&format!("a/{name}"), &format!("b/{name}")).to_string();
    truncate_middle(&text, 12_000)
}

/// Metin değişikliği uygular. Windows satır sonları (CRLF) farkını tolere eder.
pub fn apply_edit(text: &str, old: &str, new: &str, replace_all: bool) -> Result<(String, usize), String> {
    if old.is_empty() {
        return Err("old_string boş olamaz (yeni dosya için write_file kullan).".into());
    }
    if old == new {
        return Err("old_string ile new_string aynı.".into());
    }
    let try_one = |o: &str, n: &str| -> Option<Result<(String, usize), String>> {
        let count = text.matches(o).count();
        if count == 0 {
            return None;
        }
        if count > 1 && !replace_all {
            return Some(Err(format!(
                "old_string dosyada {count} kez geçiyor. Benzersiz olması için çevresinden daha fazla satır ekle ya da replace_all=true kullan."
            )));
        }
        Some(Ok(if replace_all { (text.replace(o, n), count) } else { (text.replacen(o, n, 1), 1) }))
    };
    if let Some(r) = try_one(old, new) {
        return r;
    }
    if text.contains("\r\n") && !old.contains("\r\n") {
        let (o, n) = (old.replace('\n', "\r\n"), new.replace('\n', "\r\n"));
        if let Some(r) = try_one(&o, &n) {
            return r;
        }
    }
    // Satır sonu boşlukları farkı için ipucu.
    let trimmed: String = old.lines().map(|l| l.trim_end()).collect::<Vec<_>>().join("\n");
    let hint = if text.lines().map(|l| l.trim_end()).collect::<Vec<_>>().join("\n").contains(&trimmed) {
        " (satır sonlarındaki boşluklar farklı olabilir)"
    } else {
        ""
    };
    Err(format!("old_string dosyada bulunamadı{hint}. Dosyayı read_file ile yeniden oku ve metni aynen kopyala."))
}

pub fn is_private_url(u: &str) -> bool {
    let Ok(url) = url::Url::parse(u) else { return false };
    match url.host() {
        Some(url::Host::Domain(d)) => {
            let d = d.to_lowercase();
            d == "localhost" || d.ends_with(".localhost") || d.ends_with(".local") || d.ends_with(".internal") || !d.contains('.')
        }
        Some(url::Host::Ipv4(ip)) => is_private_ip(&IpAddr::V4(ip)),
        Some(url::Host::Ipv6(ip)) => is_private_ip(&IpAddr::V6(ip)),
        None => true,
    }
}

fn is_private_ip(ip: &IpAddr) -> bool {
    match ip {
        IpAddr::V4(v) => v.is_private() || v.is_loopback() || v.is_link_local() || v.is_unspecified() || v.octets()[0] == 100 && (64..128).contains(&v.octets()[1]),
        IpAddr::V6(v) => v.is_loopback() || v.is_unspecified() || (v.segments()[0] & 0xfe00) == 0xfc00 || (v.segments()[0] & 0xffc0) == 0xfe80,
    }
}

// ----------------------------------------------------------------- arka plan süreçleri

pub struct BgProc {
    pub command: String,
    pub output: Arc<Mutex<String>>,
    pub kill: crate::proc::KillHandle,
    pub exited: Arc<Mutex<Option<Option<i32>>>>,
    pub session: String,
}

#[derive(Default)]
pub struct Background {
    procs: Mutex<HashMap<String, BgProc>>,
}

impl Background {
    pub fn kill_all(&self) {
        for (_, p) in self.procs.lock().unwrap().drain() {
            p.kill.kill_tree();
        }
    }

    pub fn list(&self) -> Vec<Value> {
        self.procs
            .lock()
            .unwrap()
            .iter()
            .map(|(id, p)| {
                json!({"id": id, "command": p.command, "running": p.exited.lock().unwrap().is_none(),
                       "exit_code": p.exited.lock().unwrap().flatten(), "session": p.session})
            })
            .collect()
    }

    pub fn kill(&self, id: &str) -> bool {
        if let Some(p) = self.procs.lock().unwrap().remove(id) {
            p.kill.kill_tree();
            return true;
        }
        false
    }
}

// ----------------------------------------------------------------- yürütme

pub async fn execute(ctx: &ToolCtx, name: &str, a: &Value) -> ToolResult {
    let r = match name {
        "read_file" => read_file(ctx, a),
        "list_directory" => list_directory(ctx, a),
        "glob" => glob_tool(ctx, a),
        "grep" => grep_tool(ctx, a),
        "write_file" => write_file(ctx, a),
        "edit_file" => edit_file(ctx, a),
        "run_command" => return run_command(ctx, a).await,
        "process" => process_tool(ctx, a),
        "web_search" => return web_search(ctx, a).await,
        "fetch_url" => return fetch_url(a).await,
        "todo_write" => todo_write(ctx, a),
        "use_skill" => use_skill(ctx, a),
        "save_skill" => crate::skills::save(&ctx.core.paths.skills(), s(a, "name"), s(a, "description"), s(a, "content"))
            .map(|d| ToolResult::ok(format!("Skill kaydedildi: {}", d.display())))
            .map_err(|e| e.to_string()),
        "remember" => match &ctx.core.memory {
            Some(m) => m
                .add(s(a, "kind"), s(a, "content"), s(a, "tags"))
                .map(|id| ToolResult::ok(format!("Hafızaya kaydedildi (#{id}).")))
                .map_err(|e| e.to_string()),
            None => Err("hafıza kullanılamıyor".into()),
        },
        "recall" => Ok(match &ctx.core.memory {
            Some(m) => {
                let r = m.search(s(a, "query"), 8);
                if r.is_empty() {
                    ToolResult::ok("Hafızada ilgili kayıt bulunamadı.")
                } else {
                    ToolResult::ok(r.iter().map(|m| format!("- [{}] {}", m.kind, m.content)).collect::<Vec<_>>().join("\n"))
                }
            }
            None => ToolResult::err("hafıza kullanılamıyor"),
        }),
        "open_in_system" => {
            let raw = s(a, "path");
            let target = if raw.starts_with("http://") || raw.starts_with("https://") {
                raw.to_string()
            } else {
                resolve_path(ctx, raw).to_string_lossy().to_string()
            };
            open::that_detached(&target).map(|_| ToolResult::ok(format!("Açıldı: {target}"))).map_err(|e| e.to_string())
        }
        "read_document" => return read_document(ctx, a).await,
        "edit_document" => return edit_document(ctx, a).await,
        "spawn_agent" => return super::run_subagent(ctx, s(a, "task"), s(a, "mode") != "general").await,
        n if n.starts_with("mcp__") => {
            return match ctx.core.mcp.call(n, a.clone()).await {
                Ok((text, is_err)) => {
                    let mut r = if is_err { ToolResult::err(text) } else { ToolResult::ok(text) };
                    r.untrusted = true;
                    r
                }
                Err(e) => ToolResult::err(e.to_string()),
            }
        }
        _ => Err(format!("Bilinmeyen araç: {name}. Yalnızca tanımlı araçları kullan.")),
    };
    r.unwrap_or_else(ToolResult::err)
}

fn read_file(ctx: &ToolCtx, a: &Value) -> Result<ToolResult, String> {
    let p = resolve_path(ctx, s(a, "path"));
    if p.is_dir() {
        return Err(format!("{} bir klasör; list_directory kullan.", p.display()));
    }
    let md = std::fs::metadata(&p).map_err(|e| format!("{}: {e}", p.display()))?;
    if DOC_EXTS.contains(&ext_of(&p).as_str()) {
        return Err(format!("{} bir belge/medya dosyası; read_document kullan.", p.display()));
    }
    if md.len() > 20 << 20 {
        return Err(format!("Dosya çok büyük ({}); grep ile ara.", crate::util::human_bytes(md.len())));
    }
    let bytes = std::fs::read(&p).map_err(|e| e.to_string())?;
    if crate::util::looks_binary(&bytes) {
        return Err("İkili dosya; metin olarak okunamaz.".into());
    }
    let text = String::from_utf8_lossy(&bytes);
    let offset = a["offset"].as_u64().unwrap_or(1).max(1) as usize;
    let limit = a["limit"].as_u64().unwrap_or(2000).clamp(1, 5000) as usize;
    let total = text.lines().count();
    let mut out = String::new();
    for (i, line) in text.lines().enumerate().skip(offset - 1).take(limit) {
        out.push_str(&format!("{:>6}\t{}\n", i + 1, truncate_end(line, 2000)));
        if out.len() > 120_000 {
            out.push_str("… (çıktı sınırı)\n");
            break;
        }
    }
    if total == 0 {
        out = "(boş dosya)".into();
    } else if offset - 1 + limit < total {
        out.push_str(&format!("\n[{total} satırın {offset}-{} arası gösterildi; devamı için offset kullan]", (offset - 1 + limit).min(total)));
    }
    Ok(ToolResult::ok(out))
}

fn list_directory(ctx: &ToolCtx, a: &Value) -> Result<ToolResult, String> {
    let raw = s(a, "path");
    let root = if raw.is_empty() { ctx.workspace.clone() } else { resolve_path(ctx, raw) };
    let depth = a["depth"].as_u64().unwrap_or(2).clamp(1, 4) as usize;
    let mut out = format!("{}\n", root.display());
    let mut count = 0;
    fn walk(dir: &Path, prefix: &str, depth: usize, max: usize, out: &mut String, count: &mut usize) {
        let Ok(entries) = crate::fsops::list_dir(dir) else { return };
        for e in entries {
            if *count >= 400 {
                out.push_str(&format!("{prefix}… (daha fazlası var)\n"));
                return;
            }
            *count += 1;
            if e.is_dir {
                out.push_str(&format!("{prefix}{}/\n", e.name));
                let heavy = ["node_modules", "target", ".git", "build", ".dart_tool", "__pycache__", ".venv", "dist"].contains(&e.name.as_str());
                if depth < max && !heavy {
                    walk(&e.path, &format!("{prefix}  "), depth + 1, max, out, count);
                }
            } else {
                out.push_str(&format!("{prefix}{} ({})\n", e.name, crate::util::human_bytes(e.size)));
            }
        }
    }
    if !root.is_dir() {
        return Err(format!("klasör bulunamadı: {}", root.display()));
    }
    walk(&root, "  ", 1, depth, &mut out, &mut count);
    Ok(ToolResult::ok(out))
}

fn glob_tool(ctx: &ToolCtx, a: &Value) -> Result<ToolResult, String> {
    let raw = s(a, "path");
    let root = if raw.is_empty() { ctx.workspace.clone() } else { resolve_path(ctx, raw) };
    let pat = s(a, "pattern").replace('\\', "/");
    let pat = if pat.contains('/') || pat.starts_with("**") { pat } else { format!("**/{pat}") };
    let m = globset::GlobBuilder::new(&pat).literal_separator(true).build().map_err(|e| e.to_string())?.compile_matcher();
    let mut hits: Vec<(std::time::SystemTime, PathBuf)> = vec![];
    for e in ignore::WalkBuilder::new(&root).hidden(false).filter_entry(|e| e.file_name() != ".git").build().flatten() {
        let p = e.path();
        if !p.is_file() {
            continue;
        }
        let rel = p.strip_prefix(&root).unwrap_or(p);
        let rel_s = rel.to_string_lossy().replace('\\', "/");
        if m.is_match(&rel_s) || (pat.starts_with("**/") && m.is_match(format!("/{rel_s}"))) {
            hits.push((e.metadata().ok().and_then(|m| m.modified().ok()).unwrap_or(std::time::UNIX_EPOCH), p.to_path_buf()));
        }
        if hits.len() > 5000 {
            break;
        }
    }
    hits.sort_by_key(|h| std::cmp::Reverse(h.0));
    if hits.is_empty() {
        return Ok(ToolResult::ok("Eşleşen dosya yok."));
    }
    let n = hits.len();
    let mut out: Vec<String> = hits.into_iter().take(300).map(|(_, p)| p.display().to_string()).collect();
    if n > 300 {
        out.push(format!("… toplam {n} dosya (ilk 300)"));
    }
    Ok(ToolResult::ok(out.join("\n")))
}

fn grep_tool(ctx: &ToolCtx, a: &Value) -> Result<ToolResult, String> {
    let raw = s(a, "path");
    let root = if raw.is_empty() { ctx.workspace.clone() } else { resolve_path(ctx, raw) };
    let max = a["max_results"].as_u64().unwrap_or(200).clamp(1, 1000) as usize;
    let include = Some(s(a, "include")).filter(|x| !x.is_empty());
    if root.is_file() {
        let re = regex::RegexBuilder::new(s(a, "pattern"))
            .case_insensitive(a["case_insensitive"].as_bool().unwrap_or(false))
            .build()
            .map_err(|e| e.to_string())?;
        let text = std::fs::read_to_string(&root).map_err(|e| e.to_string())?;
        let out: Vec<String> = text
            .lines()
            .enumerate()
            .filter(|(_, l)| re.is_match(l))
            .take(max)
            .map(|(i, l)| format!("{}:{}: {}", root.display(), i + 1, truncate_end(l.trim(), 300)))
            .collect();
        return Ok(ToolResult::ok(if out.is_empty() { "Eşleşme yok.".into() } else { out.join("\n") }));
    }
    let hits = crate::fsops::search(&root, s(a, "pattern"), true, !a["case_insensitive"].as_bool().unwrap_or(false), include, max)
        .map_err(|e| format!("geçersiz düzenli ifade: {e}"))?;
    if hits.is_empty() {
        return Ok(ToolResult::ok("Eşleşme yok."));
    }
    Ok(ToolResult::ok(hits.iter().map(|h| format!("{}:{}: {}", h.path.display(), h.line, h.text)).collect::<Vec<_>>().join("\n")))
}

fn write_file(ctx: &ToolCtx, a: &Value) -> Result<ToolResult, String> {
    let p = resolve_path(ctx, s(a, "path"));
    let content = a["content"].as_str().ok_or("content gerekli")?;
    let old = std::fs::read_to_string(&p).unwrap_or_default();
    ctx.core.sessions.checkpoint_file(&ctx.session_id, ctx.turn, &p).map_err(|e| e.to_string())?;
    crate::util::write_atomic(&p, content.as_bytes()).map_err(|e| e.to_string())?;
    let diff = unified_diff(&old, content, &p);
    Ok(ToolResult::ok(format!("Yazıldı: {} ({} satır)", p.display(), content.lines().count()))
        .with_ui(json!({"path": p, "diff": diff})))
}

fn edit_file(ctx: &ToolCtx, a: &Value) -> Result<ToolResult, String> {
    let p = resolve_path(ctx, s(a, "path"));
    let text = std::fs::read_to_string(&p).map_err(|e| format!("{}: {e}", p.display()))?;
    let (new, n) = apply_edit(&text, s(a, "old_string"), s(a, "new_string"), a["replace_all"].as_bool().unwrap_or(false))?;
    ctx.core.sessions.checkpoint_file(&ctx.session_id, ctx.turn, &p).map_err(|e| e.to_string())?;
    crate::util::write_atomic(&p, new.as_bytes()).map_err(|e| e.to_string())?;
    let diff = unified_diff(&text, &new, &p);
    Ok(ToolResult::ok(format!("Düzenlendi: {} ({n} değişiklik)", p.display())).with_ui(json!({"path": p, "diff": diff})))
}

async fn run_command(ctx: &ToolCtx, a: &Value) -> ToolResult {
    let command = s(a, "command");
    if command.trim().is_empty() {
        return ToolResult::err("command boş");
    }
    let cwd = match s(a, "cwd") {
        "" => ctx.workspace.clone(),
        c => resolve_path(ctx, c),
    };
    if !cwd.is_dir() {
        return ToolResult::err(format!("çalışma klasörü yok: {}", cwd.display()));
    }
    let (prog, args) = ctx.shell.command_args(command);
    let mut cmd = crate::proc::command(&ctx.core.paths, &prog, &args);
    cmd.current_dir(&cwd).env("FERIDE_AGENT", "1").env("GIT_TERMINAL_PROMPT", "0").env("PYTHONIOENCODING", "utf-8");
    if cfg!(windows) {
        cmd.env("CHERE_INVOKING", "1");
    }
    if a["background"].as_bool().unwrap_or(false) {
        cmd.stdout(std::process::Stdio::piped()).stderr(std::process::Stdio::piped());
        let (mut child, kill) = match crate::proc::spawn(&mut cmd) {
            Ok(x) => x,
            Err(e) => return ToolResult::err(e.to_string()),
        };
        let id = uuid::Uuid::new_v4().simple().to_string()[..8].to_string();
        let output = Arc::new(Mutex::new(String::new()));
        let exited = Arc::new(Mutex::new(None));
        for stream in [child.stdout.take().map(|s| Box::new(s) as Box<dyn tokio::io::AsyncRead + Send + Unpin>), child.stderr.take().map(|s| Box::new(s) as Box<dyn tokio::io::AsyncRead + Send + Unpin>)]
            .into_iter()
            .flatten()
        {
            let out = output.clone();
            tokio::spawn(async move {
                use tokio::io::AsyncBufReadExt;
                let mut lines = tokio::io::BufReader::new(stream).lines();
                while let Ok(Some(l)) = lines.next_line().await {
                    let mut o = out.lock().unwrap();
                    o.push_str(&l);
                    o.push('\n');
                    if o.len() > 200_000 {
                        let cut = o.len() - 150_000;
                        let cut = (cut..o.len()).find(|i| o.is_char_boundary(*i)).unwrap_or(o.len());
                        o.drain(..cut);
                    }
                }
            });
        }
        let ex = exited.clone();
        tokio::spawn(async move {
            let st = child.wait().await.ok().and_then(|s| s.code());
            *ex.lock().unwrap() = Some(st);
        });
        ctx.core.background.procs.lock().unwrap().insert(
            id.clone(),
            BgProc { command: command.to_string(), output, kill, exited, session: ctx.session_id.clone() },
        );
        tokio::time::sleep(Duration::from_millis(1500)).await;
        let first = ctx.core.background.procs.lock().unwrap().get(&id).map(|p| p.output.lock().unwrap().clone()).unwrap_or_default();
        return ToolResult::ok(format!(
            "Arka planda başlatıldı (id: {id}). Çıktıyı process(action=output, id={id}) ile okuyabilirsin.\nİlk çıktı:\n{}",
            truncate_middle(&first, 3000)
        ));
    }
    let timeout = a["timeout_secs"].as_u64().unwrap_or(ctx.settings.agent.command_timeout_secs).clamp(5, 3600);
    let fut = crate::proc::run_capture(&mut cmd, Duration::from_secs(timeout));
    let res = tokio::select! {
        r = fut => r,
        _ = ctx.cancel.cancelled() => return ToolResult::err("İptal edildi."),
    };
    match res {
        Err(e) => ToolResult::err(format!("komut başlatılamadı ({}): {e}", ctx.shell.display_name())),
        Ok((code, out, err, timed_out)) => {
            let mut text = String::new();
            if !out.trim().is_empty() {
                text.push_str(out.trim_end());
            }
            if !err.trim().is_empty() {
                if !text.is_empty() {
                    text.push('\n');
                }
                text.push_str("[stderr]\n");
                text.push_str(err.trim_end());
            }
            let max = ctx.settings.agent.max_tool_output_chars;
            let mut text = truncate_middle(&text, max);
            if timed_out {
                text.push_str(&format!("\n[ZAMAN AŞIMI: {timeout} sn içinde bitmedi ve durduruldu. Uzun işler için background=true kullan.]"));
            }
            let code_txt = code.map(|c| c.to_string()).unwrap_or_else(|| "?".into());
            let ok = code == Some(0) && !timed_out;
            let body = format!("çıkış kodu: {code_txt}\n{}", if text.trim().is_empty() { "(çıktı yok)".into() } else { text });
            ToolResult { content: body, ok, untrusted: false, ui: Some(json!({"exit_code": code, "cwd": cwd})) }
        }
    }
}

fn process_tool(ctx: &ToolCtx, a: &Value) -> Result<ToolResult, String> {
    let bg = &ctx.core.background;
    match s(a, "action") {
        "list" => Ok(ToolResult::ok(serde_json::to_string_pretty(&bg.list()).unwrap_or_default())),
        "output" => {
            let g = bg.procs.lock().unwrap();
            let p = g.get(s(a, "id")).ok_or("böyle bir arka plan işlemi yok")?;
            let out = p.output.lock().unwrap().clone();
            let status = match *p.exited.lock().unwrap() {
                None => "çalışıyor".to_string(),
                Some(c) => format!("bitti (çıkış kodu {})", c.map(|c| c.to_string()).unwrap_or("?".into())),
            };
            Ok(ToolResult::ok(format!("durum: {status}\n{}", truncate_middle(&out, ctx.settings.agent.max_tool_output_chars))))
        }
        "kill" => Ok(if bg.kill(s(a, "id")) { ToolResult::ok("Durduruldu.") } else { ToolResult::err("böyle bir işlem yok") }),
        _ => Err("action: list | output | kill".into()),
    }
}

async fn web_search(ctx: &ToolCtx, a: &Value) -> ToolResult {
    let q = s(a, "query");
    let max = a["max_results"].as_u64().unwrap_or(8).clamp(1, 20) as usize;
    let client = reqwest::Client::builder()
        .user_agent("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130 Safari/537.36")
        .timeout(Duration::from_secs(20))
        .build()
        .unwrap();
    let res = client.post("https://html.duckduckgo.com/html/").form(&[("q", q), ("kl", "tr-tr")]).send().await;
    let html = match res {
        Ok(r) => r.text().await.unwrap_or_default(),
        Err(e) => return ToolResult::err(format!("arama yapılamadı: {e}")),
    };
    let results = parse_ddg(&html, max);
    if results.is_empty() {
        // Yedek: Python ddgs (belge paketi kuruluysa).
        let py = ctx.core.paths.pyenv_python();
        let script = ctx.core.paths.resources().join("python").join("search_engine.py");
        if py.is_file() && script.is_file() {
            let mut c = crate::proc::command(&ctx.core.paths, &py.to_string_lossy(), &[script.to_string_lossy().into(), q.to_string()]);
            if let Ok((Some(0), out, _, _)) = crate::proc::run_capture(&mut c, Duration::from_secs(40)).await {
                return ToolResult::ok(truncate_middle(&out, 12_000)).untrusted();
            }
        }
        return ToolResult::err("Sonuç alınamadı (arama motoru yanıt vermedi ya da engelledi).");
    }
    let text = results
        .iter()
        .enumerate()
        .map(|(i, (t, u, sn))| format!("{}. {t}\n   {u}\n   {sn}", i + 1))
        .collect::<Vec<_>>()
        .join("\n\n");
    ToolResult::ok(text).untrusted()
}

pub fn parse_ddg(html: &str, max: usize) -> Vec<(String, String, String)> {
    let a_re = Regex::new(r#"(?s)<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#).unwrap();
    let sn_re = Regex::new(r#"(?s)class="result__snippet"[^>]*>(.*?)</a>"#).unwrap();
    let tag = Regex::new(r"<[^>]+>").unwrap();
    let clean = |s: &str| html_unescape(&tag.replace_all(s, "")).trim().to_string();
    let snippets: Vec<String> = sn_re.captures_iter(html).map(|c| clean(&c[1])).collect();
    a_re.captures_iter(html)
        .enumerate()
        .filter_map(|(i, c)| {
            let mut href = html_unescape(&c[1]);
            if let Some(pos) = href.find("uddg=") {
                let enc = href[pos + 5..].split('&').next().unwrap_or("");
                href = url::form_urlencoded::parse(format!("x={enc}").as_bytes()).next().map(|(_, v)| v.to_string()).unwrap_or(href);
            }
            if href.starts_with("//") {
                href = format!("https:{href}");
            }
            if href.contains("duckduckgo.com/y.js") {
                return None; // reklam
            }
            Some((clean(&c[2]), href, snippets.get(i).cloned().unwrap_or_default()))
        })
        .take(max)
        .collect()
}

fn html_unescape(s: &str) -> String {
    s.replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"").replace("&#x27;", "'").replace("&#39;", "'").replace("&nbsp;", " ")
}

async fn fetch_url(a: &Value) -> ToolResult {
    let u = s(a, "url");
    let Ok(url) = url::Url::parse(u) else { return ToolResult::err("geçersiz adres") };
    if url.scheme() != "http" && url.scheme() != "https" {
        return ToolResult::err("yalnızca http/https adresleri okunabilir");
    }
    let start_private = is_private_url(u);
    let client = reqwest::Client::builder()
        .user_agent("Mozilla/5.0 (compatible; FerIDE/5.4)")
        .timeout(Duration::from_secs(30))
        .redirect(reqwest::redirect::Policy::custom(move |att| {
            if att.previous().len() > 5 {
                att.error("çok fazla yönlendirme")
            } else if !start_private && is_private_url(att.url().as_str()) {
                att.error("yerel ağa yönlendirme engellendi")
            } else {
                att.follow()
            }
        }))
        .build()
        .unwrap();
    let resp = match client.get(url.clone()).send().await {
        Ok(r) => r,
        Err(e) => return ToolResult::err(format!("sayfa alınamadı: {e}")),
    };
    let status = resp.status();
    let ctype = resp.headers().get("content-type").and_then(|v| v.to_str().ok()).unwrap_or("").to_lowercase();
    let mut body = Vec::new();
    let mut stream = resp.bytes_stream();
    use futures::StreamExt;
    while let Some(Ok(chunk)) = stream.next().await {
        body.extend_from_slice(&chunk);
        if body.len() > 5 << 20 {
            break;
        }
    }
    let max = a["max_chars"].as_u64().unwrap_or(20_000).clamp(1000, 100_000) as usize;
    let text = if ctype.contains("html") || body.starts_with(b"<!") || body.starts_with(b"<html") {
        html2text::from_read(&body[..], 110).unwrap_or_else(|_| String::from_utf8_lossy(&body).into_owned())
    } else if ctype.contains("json") || ctype.starts_with("text/") || ctype.contains("xml") {
        String::from_utf8_lossy(&body).into_owned()
    } else {
        return ToolResult::err(format!("metin olmayan içerik ({ctype}); dosyayı indirip read_document kullanın"));
    };
    ToolResult::ok(format!("HTTP {status} — {url}\n\n{}", truncate_middle(&text, max))).untrusted()
}

fn todo_write(ctx: &ToolCtx, a: &Value) -> Result<ToolResult, String> {
    let todos: Vec<crate::sessions::Todo> = serde_json::from_value(a["todos"].clone()).map_err(|e| format!("todos biçimi hatalı: {e}"))?;
    ctx.core.sessions.set_todos(&ctx.session_id, &todos).map_err(|e| e.to_string())?;
    ctx.core.events.emit("agent", json!({"session": ctx.session_id, "kind": "todos", "todos": todos}));
    let done = todos.iter().filter(|t| t.status == "completed").count();
    Ok(ToolResult::ok(format!("Liste güncellendi ({done}/{} tamamlandı).", todos.len())))
}

fn use_skill(ctx: &ToolCtx, a: &Value) -> Result<ToolResult, String> {
    let want = s(a, "name").trim().to_lowercase();
    let skills = ctx.core.skills();
    let sk = skills
        .iter()
        .find(|k| k.name.to_lowercase() == want)
        .or_else(|| skills.iter().find(|k| k.name.to_lowercase().contains(&want) || want.contains(&k.name.to_lowercase())))
        .ok_or_else(|| format!("Skill bulunamadı: {want}. Mevcutlar: {}", skills.iter().map(|k| k.name.as_str()).collect::<Vec<_>>().join(", ")))?;
    if !sk.enabled {
        return Err(format!("'{}' skill'i kullanıcı tarafından kapatılmış.", sk.name));
    }
    crate::skills::load(sk).map(ToolResult::ok).map_err(|e| e.to_string())
}

fn python_ready(ctx: &ToolCtx) -> Result<PathBuf, String> {
    let py = ctx.core.paths.pyenv_python();
    if !py.is_file() || !ctx.core.paths.pyenv().join(".feride-docs").exists() {
        return Err("Belge stüdyosu kurulu değil. Kullanıcıdan Ayarlar > Kurulum > \"Belge ve CAD stüdyosu\"nu kurmasını isteyin.".into());
    }
    Ok(py)
}

async fn read_document(ctx: &ToolCtx, a: &Value) -> ToolResult {
    let py = match python_ready(ctx) {
        Ok(p) => p,
        Err(e) => return ToolResult::err(e),
    };
    let p = resolve_path(ctx, s(a, "path"));
    if !p.is_file() {
        return ToolResult::err(format!("dosya yok: {}", p.display()));
    }
    let script = ctx.core.paths.resources().join("python").join("file_parser.py");
    let mut c = crate::proc::command(&ctx.core.paths, &py.to_string_lossy(), &[script.to_string_lossy().into(), p.to_string_lossy().into()]);
    c.env("PYTHONIOENCODING", "utf-8").env("FERIDE_ROOT", ctx.core.paths.voice());
    match crate::proc::run_capture(&mut c, Duration::from_secs(600)).await {
        Ok((_, out, err, _)) => match py_json(&out) {
            Some(j) if j["success"].as_bool() == Some(false) => {
                ToolResult::err(j["error"].as_str().unwrap_or("belge okunamadı").to_string())
            }
            Some(j) => {
                let content = j["content"].as_str().map(String::from).unwrap_or_else(|| j.to_string());
                let mut meta = j.clone();
                if let Some(o) = meta.as_object_mut() {
                    o.remove("content");
                }
                ToolResult::ok(format!(
                    "{}\n\n{}",
                    truncate_end(&meta.to_string(), 1500),
                    truncate_middle(&content, ctx.settings.agent.max_tool_output_chars.max(30_000))
                ))
                .untrusted()
            }
            None => ToolResult::err(truncate_middle(&format!("{out}\n{err}"), 4000)),
        },
        Err(e) => ToolResult::err(e.to_string()),
    }
}

/// Python betiğinin son JSON satırı.
fn py_json(out: &str) -> Option<Value> {
    out.lines().rev().find(|l| l.trim_start().starts_with('{')).and_then(|l| serde_json::from_str(l).ok())
}

async fn edit_document(ctx: &ToolCtx, a: &Value) -> ToolResult {
    let py = match python_ready(ctx) {
        Ok(p) => p,
        Err(e) => return ToolResult::err(e),
    };
    let mut spec = a.clone();
    for k in ["input_path", "output_path"] {
        if let Some(v) = a[k].as_str().filter(|v| !v.is_empty()) {
            spec[k] = json!(resolve_path(ctx, v));
        }
    }
    if let Some(list) = a["input_paths"].as_array() {
        spec["input_paths"] = json!(list.iter().filter_map(|v| v.as_str()).map(|v| resolve_path(ctx, v)).collect::<Vec<_>>());
    }
    let out_path = resolve_path(ctx, s(a, "output_path"));
    if let Err(e) = ctx.core.sessions.checkpoint_file(&ctx.session_id, ctx.turn, &out_path) {
        return ToolResult::err(e.to_string());
    }
    let script = ctx.core.paths.resources().join("python").join("file_studio.py");
    let tmp = ctx.core.paths.run().join(format!("spec-{}.json", uuid::Uuid::new_v4().simple()));
    if let Err(e) = std::fs::write(&tmp, spec.to_string()) {
        return ToolResult::err(e.to_string());
    }
    let mut c = crate::proc::command(
        &ctx.core.paths,
        &py.to_string_lossy(),
        &[script.to_string_lossy().into(), "--spec-file".into(), tmp.to_string_lossy().into()],
    );
    c.env("PYTHONIOENCODING", "utf-8");
    let r = crate::proc::run_capture(&mut c, Duration::from_secs(600)).await;
    let _ = std::fs::remove_file(&tmp);
    match r {
        Ok((_, out, err, _)) => match py_json(&out) {
            Some(j) if j["success"].as_bool() == Some(true) => {
                ToolResult::ok(truncate_middle(&j.to_string(), 8000)).with_ui(json!({"path": out_path}))
            }
            Some(j) => ToolResult::err(j["error"].as_str().unwrap_or("işlem başarısız").to_string()),
            None => ToolResult::err(truncate_middle(&format!("{out}\n{err}"), 4000)),
        },
        Err(e) => ToolResult::err(e.to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn edits() {
        let t = "a\nfn x() {}\nb\nfn x() {}\n";
        assert!(apply_edit(t, "fn x() {}", "fn y() {}", false).unwrap_err().contains("2 kez"));
        let (n, c) = apply_edit(t, "fn x() {}", "fn y() {}", true).unwrap();
        assert_eq!(c, 2);
        assert!(!n.contains("fn x"));
        let crlf = "satır1\r\nsatır2\r\n";
        let (n, _) = apply_edit(crlf, "satır1\nsatır2", "A\nB", false).unwrap();
        assert_eq!(n, "A\r\nB\r\n");
        assert!(apply_edit("x", "yok", "z", false).is_err());
    }

    #[test]
    fn private_urls() {
        for u in ["http://localhost:8080", "http://127.0.0.1/", "http://192.168.1.5", "http://10.0.0.1", "http://[::1]/", "http://router/", "http://169.254.169.254/latest"] {
            assert!(is_private_url(u), "{u}");
        }
        for u in ["https://example.com", "https://8.8.8.8/", "https://docs.rs/x"] {
            assert!(!is_private_url(u), "{u}");
        }
    }

    #[test]
    fn ddg_parse() {
        let html = r#"<div class="result"><a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fwww.rust-lang.org%2Ftr&amp;rut=x">Rust <b>Dili</b></a>
            <a class="result__snippet" href="x">Güvenilir &amp; hızlı</a></div>"#;
        let r = parse_ddg(html, 5);
        assert_eq!(r.len(), 1);
        assert_eq!(r[0].0, "Rust Dili");
        assert_eq!(r[0].1, "https://www.rust-lang.org/tr");
        assert_eq!(r[0].2, "Güvenilir & hızlı");
    }
}
