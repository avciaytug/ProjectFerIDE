//! FerIDE'nin kontrol ettiği gerçek tarayıcı (Chrome / Edge / Brave / Chromium).
//!
//! Tarayıcı, FerIDE'ye ayrılmış bir profille (`<veri>/browser/profile`) normal bir pencere olarak açılır ve Chrome
//! DevTools Protocol ile yönetilir. Kullanıcı bu pencerede hesaplarına kendisi girer; oturumlar profilde kalır. Ajan
//! aynı tarayıcıyı `browser` aracıyla kullanır (bkz. `agent::browse`); arayüz canlı görüntüsünü gösterir ve
//! kullanıcının fare/klavye girdisini iletir. Otomasyon bayrağı (`--enable-automation`) kullanılmaz: tarayıcı
//! sıradan bir pencere gibi davranır, böylece hesap girişleri "güvenli olmayan tarayıcı" diye engellenmez.

pub mod cdp;
pub mod input;
pub mod safety;

use serde::Serialize;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::{Child, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::sync::watch;
use tokio_util::sync::CancellationToken;

use crate::config::BrowserSettings;
use crate::events::EventBus;
use crate::paths::Paths;
use cdp::Cdp;

/// Sayfada çalışan yardımcı betik (bkz. page.js).
const PAGE_JS: &str = include_str!("page.js");

// ----------------------------------------------------------------- kurulu tarayıcılar

#[derive(Clone, Debug, Serialize)]
pub struct Installed {
    pub kind: String,
    pub name: String,
    pub path: PathBuf,
}

const KINDS: &[(&str, &str)] = &[("chrome", "Google Chrome"), ("edge", "Microsoft Edge"), ("brave", "Brave"), ("chromium", "Chromium")];

fn candidates(kind: &str) -> Vec<PathBuf> {
    let mut v = vec![];
    #[cfg(windows)]
    {
        let rel: &[&str] = match kind {
            "chrome" => &["Google\\Chrome\\Application\\chrome.exe"],
            "edge" => &["Microsoft\\Edge\\Application\\msedge.exe"],
            "brave" => &["BraveSoftware\\Brave-Browser\\Application\\brave.exe"],
            "chromium" => &["Chromium\\Application\\chrome.exe"],
            _ => &[],
        };
        for root in ["ProgramFiles", "ProgramFiles(x86)", "LOCALAPPDATA"].iter().filter_map(|k| std::env::var_os(k)) {
            for r in rel {
                v.push(PathBuf::from(&root).join(r));
            }
        }
    }
    #[cfg(target_os = "macos")]
    {
        let app = match kind {
            "chrome" => "Google Chrome.app/Contents/MacOS/Google Chrome",
            "edge" => "Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
            "brave" => "Brave Browser.app/Contents/MacOS/Brave Browser",
            "chromium" => "Chromium.app/Contents/MacOS/Chromium",
            _ => "",
        };
        if !app.is_empty() {
            v.push(PathBuf::from("/Applications").join(app));
            v.push(crate::paths::home_dir().join("Applications").join(app));
        }
    }
    #[cfg(all(unix, not(target_os = "macos")))]
    {
        let names: &[&str] = match kind {
            "chrome" => &["google-chrome", "google-chrome-stable"],
            "edge" => &["microsoft-edge", "microsoft-edge-stable"],
            "brave" => &["brave-browser", "brave"],
            "chromium" => &["chromium", "chromium-browser"],
            _ => &[],
        };
        let path = std::env::var_os("PATH").unwrap_or_default();
        for n in names {
            if let Some(p) = crate::proc::which_in(n, &path) {
                v.push(p);
            }
        }
    }
    v
}

/// Bilgisayarda bulunan Chromium tabanlı tarayıcılar (tercih sırasıyla).
pub fn detect_all() -> Vec<Installed> {
    KINDS
        .iter()
        .filter_map(|(k, n)| candidates(k).into_iter().find(|p| p.is_file()).map(|p| Installed { kind: k.to_string(), name: n.to_string(), path: p }))
        .collect()
}

/// Ayarlara göre kullanılacak tarayıcı. Seçilen tarayıcı kaldırılmışsa bulunan ilk tarayıcı kullanılır.
pub fn find(s: &BrowserSettings) -> Option<Installed> {
    if s.kind == "custom" {
        if let Some(p) = s.path.as_ref().filter(|p| p.is_file()) {
            let name = p.file_stem().map(|n| n.to_string_lossy().to_string()).unwrap_or_else(|| "Tarayıcı".into());
            return Some(Installed { kind: "custom".into(), name, path: p.clone() });
        }
    }
    let all = detect_all();
    all.iter().find(|b| b.kind == s.kind).cloned().or_else(|| all.into_iter().next())
}

/// Ajan bu bilgisayarda tarayıcı kullanabilir mi?
pub fn available(s: &BrowserSettings) -> bool {
    s.enabled && find(s).is_some()
}

// ----------------------------------------------------------------- durum

#[derive(Clone, Debug, Serialize)]
pub struct TabInfo {
    pub id: String,
    pub title: String,
    pub url: String,
    pub active: bool,
}

#[derive(Clone, Debug, Serialize)]
pub struct Status {
    /// off | starting | ready | login (hesap giriş penceresi açık)
    pub state: String,
    pub name: String,
    pub error: Option<String>,
    pub tabs: Vec<TabInfo>,
    /// Ajanın o an yaptığı işlem.
    pub agent: Option<String>,
    /// Kullanıcı kontrolü aldı: ajan bekler.
    pub user_control: bool,
    pub viewing: bool,
    pub profile: PathBuf,
}

/// Bağlı bir sekme.
#[derive(Clone, Debug)]
pub struct Tab {
    pub target: String,
    pub session: String,
}

#[derive(Default)]
struct PageState {
    target: String,
    /// FerIDE betiğinin yalıtılmış dünyası (yeni belgede yeniden oluşturulur).
    world: Option<i64>,
    loading: bool,
}

#[derive(Default)]
struct Inner {
    cdp: Option<Arc<Cdp>>,
    child: Option<Child>,
    /// Hesap girişi için kontrolsüz açılan pencere (bkz. `open_login`).
    login: Option<Child>,
    /// Giriş penceresi için kapatılan tarayıcının son sayfası (yeniden açılınca dönülür).
    resume_url: Option<String>,
    name: String,
    state: String,
    error: Option<String>,
    active: Option<Tab>,
    /// hedef → oturum
    sessions: HashMap<String, String>,
    /// oturum → sayfa durumu
    pages: HashMap<String, PageState>,
    tabs: Vec<TabInfo>,
    /// Etkin sekmenin açtığı yeni sekme (bir sonraki işlemde ona geçilir).
    popup: Option<String>,
    /// Ajana bir sonraki çıktıda bildirilecek olaylar (uyarı pencereleri…).
    notes: Vec<String>,
    viewing: bool,
    agent: Option<String>,
    /// Kullanıcının az önce onayladığı işlemin açtığı onay penceresi kabul edilir.
    accept_dialogs_until: Option<Instant>,
    last_frame: Option<Instant>,
}

pub struct BrowserManager {
    paths: Paths,
    events: EventBus,
    inner: Mutex<Inner>,
    launch: tokio::sync::Mutex<()>,
    /// Ajanın tarayıcı işlemleri sırayla yapılır.
    pub op: tokio::sync::Mutex<()>,
    control: watch::Sender<bool>,
}

fn page_targets(v: &Value) -> Vec<TabInfo> {
    v["targetInfos"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter(|t| t["type"] == "page" && !t["url"].as_str().unwrap_or("").starts_with("devtools://"))
                .map(|t| TabInfo {
                    id: t["targetId"].as_str().unwrap_or("").to_string(),
                    title: t["title"].as_str().unwrap_or("").to_string(),
                    url: t["url"].as_str().unwrap_or("").to_string(),
                    active: false,
                })
                .collect()
        })
        .unwrap_or_default()
}

/// Tarayıcının profil klasörüne yazdığı kontrol adresi.
fn read_port_file(profile: &Path) -> Option<String> {
    let t = std::fs::read_to_string(profile.join("DevToolsActivePort")).ok()?;
    let mut lines = t.lines();
    let port: u16 = lines.next()?.trim().parse().ok()?;
    let path = lines.next()?.trim().to_string();
    path.starts_with("/devtools/browser/").then(|| format!("ws://127.0.0.1:{port}{path}"))
}

fn product_name(ver: &Value) -> String {
    let ua = ver["userAgent"].as_str().unwrap_or("");
    if ua.contains("Edg/") {
        "Microsoft Edge".into()
    } else {
        "Chrome".into()
    }
}

/// Kullanıcının adres çubuğuna yazdığı metin: adres değilse Google'da aranır.
pub fn user_url(raw: &str) -> String {
    let t = raw.trim();
    if t.contains("://") || t.starts_with("about:") || t.starts_with("file:") {
        return t.to_string();
    }
    if !t.contains(' ') && (t.contains('.') || t.starts_with("localhost")) {
        let local = t.starts_with("localhost") || t.starts_with("127.") || t.starts_with("192.168.");
        return format!("{}://{t}", if local { "http" } else { "https" });
    }
    format!("https://www.google.com/search?q={}", url::form_urlencoded::byte_serialize(t.as_bytes()).collect::<String>())
}

impl BrowserManager {
    pub fn new(paths: Paths, events: EventBus) -> Self {
        let (control, _) = watch::channel(false);
        Self {
            paths,
            events,
            inner: Mutex::new(Inner { state: "off".into(), ..Default::default() }),
            launch: tokio::sync::Mutex::new(()),
            op: tokio::sync::Mutex::new(()),
            control,
        }
    }

    pub fn profile_dir(&self) -> PathBuf {
        self.paths.data.join("browser").join("profile")
    }

    pub fn status(&self) -> Status {
        let i = self.inner.lock().unwrap();
        let active = i.active.as_ref().map(|t| t.target.clone());
        Status {
            state: i.state.clone(),
            name: i.name.clone(),
            error: i.error.clone(),
            tabs: i.tabs.iter().map(|t| TabInfo { active: Some(&t.id) == active.as_ref(), ..t.clone() }).collect(),
            agent: i.agent.clone(),
            user_control: *self.control.borrow(),
            viewing: i.viewing,
            profile: self.profile_dir(),
        }
    }

    fn emit_status(&self) {
        self.events.emit_ser("browser.status", &self.status());
    }

    fn live(&self) -> Option<Arc<Cdp>> {
        self.inner.lock().unwrap().cdp.clone().filter(|c| !c.is_closed())
    }

    pub fn is_running(&self) -> bool {
        self.live().is_some()
    }

    /// FerIDE'nin başlattığı tarayıcı sürecinin kimliği (önceki oturumdan kalan tarayıcıya bağlanıldıysa yok).
    pub fn pid(&self) -> Option<u32> {
        self.inner.lock().unwrap().child.as_ref().map(|c| c.id())
    }

    /// Tarayıcı açık değilse açar (FerIDE'nin önceki oturumundan açık kalmışsa ona bağlanır).
    pub async fn ensure(self: &Arc<Self>, s: &BrowserSettings) -> Result<Arc<Cdp>, String> {
        if let Some(c) = self.live() {
            return Ok(c);
        }
        let _g = self.launch.lock().await;
        if let Some(c) = self.live() {
            return Ok(c);
        }
        if self.login_open() {
            return Err("Hesap giriş penceresi açık (aynı profili iki pencere birden kullanamaz). Kullanıcı girişini bitirip o tarayıcı \
                        penceresini kapatınca tarayıcı yeniden kullanılabilir; gerekirse wait_for_user ile bunu iste."
                .into());
        }
        let profile = self.profile_dir();
        std::fs::create_dir_all(&profile).map_err(|e| format!("tarayıcı profili oluşturulamadı: {e}"))?;
        if let Some(ws) = read_port_file(&profile) {
            if let Ok(c) = self.attach_browser(&ws, None, String::new()).await {
                return Ok(c);
            }
        }
        let _ = std::fs::remove_file(profile.join("DevToolsActivePort"));
        let Some(b) = find(s) else {
            return Err("Bu bilgisayarda Chrome, Edge, Brave ya da Chromium bulunamadı. Birini kurun ya da Ayarlar > Tarayıcı'dan \
                        tarayıcı programının yolunu girin."
                .into());
        };
        self.set_state("starting", None, &b.name);
        let mut cmd = std::process::Command::new(&b.path);
        cmd.arg(format!("--user-data-dir={}", profile.display()))
            .args([
                "--remote-debugging-port=0",
                "--no-first-run",
                "--no-default-browser-check",
                // Pencere küçültülse ya da arkada kalsa da sayfalar çizilmeye devam etsin (ajan ve canlı görüntü için).
                "--disable-backgrounding-occluded-windows",
                "--disable-renderer-backgrounding",
                "--disable-background-timer-throttling",
                "about:blank",
            ])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        let mut child = match cmd.spawn() {
            Ok(c) => c,
            Err(e) => {
                let msg = format!("{} başlatılamadı: {e}", b.name);
                self.set_state("off", Some(msg.clone()), &b.name);
                return Err(msg);
            }
        };
        let started = Instant::now();
        let ws = loop {
            if let Some(ws) = read_port_file(&profile) {
                break ws;
            }
            // Süreç hemen çıktıysa (profil zaten açık bir pencereye devredildi) port dosyası birkaç saniye içinde gelir.
            let exited = matches!(child.try_wait(), Ok(Some(_)));
            let waited = started.elapsed();
            if waited > Duration::from_secs(40) || (exited && waited > Duration::from_secs(5)) {
                if !exited {
                    let _ = child.kill();
                }
                let msg = format!(
                    "{} açıldı ama FerIDE ona bağlanamadı. FerIDE'nin tarayıcı profili başka bir pencerede açıksa onu kapatıp tekrar deneyin.",
                    b.name
                );
                self.set_state("off", Some(msg.clone()), &b.name);
                return Err(msg);
            }
            tokio::time::sleep(Duration::from_millis(150)).await;
        };
        match self.attach_browser(&ws, Some(child), b.name.clone()).await {
            Ok(c) => Ok(c),
            Err(e) => {
                self.set_state("off", Some(e.clone()), &b.name);
                Err(e)
            }
        }
    }

    fn set_state(&self, state: &str, error: Option<String>, name: &str) {
        {
            let mut i = self.inner.lock().unwrap();
            i.state = state.into();
            i.error = error;
            if !name.is_empty() {
                i.name = name.into();
            }
        }
        self.emit_status();
    }

    async fn attach_browser(self: &Arc<Self>, ws: &str, child: Option<Child>, name: String) -> Result<Arc<Cdp>, String> {
        let cdp = Cdp::connect(ws).await.map_err(|e| format!("tarayıcıya bağlanılamadı: {e}"))?;
        let ver = cdp.call(None, "Browser.getVersion", json!({})).await?;
        cdp.call(None, "Target.setDiscoverTargets", json!({"discover": true})).await?;
        let targets = cdp.call(None, "Target.getTargets", json!({})).await?;
        {
            let mut i = self.inner.lock().unwrap();
            i.cdp = Some(cdp.clone());
            if child.is_some() {
                i.child = child;
            }
            i.name = if name.is_empty() { product_name(&ver) } else { name };
            i.state = "ready".into();
            i.error = None;
            i.active = None;
            i.sessions.clear();
            i.pages.clear();
            i.popup = None;
            i.tabs = page_targets(&targets);
        }
        tokio::spawn(Arc::clone(self).events_loop(cdp.clone()));
        self.emit_status();
        Ok(cdp)
    }

    // ------------------------------------------------------------- olaylar

    async fn events_loop(self: Arc<Self>, cdp: Arc<Cdp>) {
        let mut rx = cdp.subscribe();
        loop {
            let ev = match rx.recv().await {
                Ok(e) => e,
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                Err(_) => break,
            };
            let current = self.inner.lock().unwrap().cdp.as_ref().is_some_and(|c| Arc::ptr_eq(c, &cdp));
            if !current {
                if ev.method == cdp::CLOSED {
                    break;
                }
                continue;
            }
            let sess = ev.session.as_deref();
            match ev.method.as_str() {
                cdp::CLOSED => {
                    self.on_closed(&cdp);
                    break;
                }
                "Target.targetCreated" | "Target.targetInfoChanged" => self.on_target(&ev.params["targetInfo"], ev.method == "Target.targetCreated"),
                "Target.targetDestroyed" => self.on_target_gone(ev.params["targetId"].as_str().unwrap_or("")),
                "Target.detachedFromTarget" => {
                    if let Some(s) = ev.params["sessionId"].as_str() {
                        self.on_detached(s);
                    }
                }
                "Page.frameNavigated" => {
                    if ev.params["frame"]["parentId"].as_str().is_none() {
                        if let Some(s) = sess {
                            self.with_page(s, |p| p.world = None);
                        }
                    }
                }
                "Page.frameStartedLoading" | "Page.frameStoppedLoading" => {
                    if let Some(s) = sess {
                        let fid = ev.params["frameId"].as_str().unwrap_or("").to_string();
                        let start = ev.method.ends_with("StartedLoading");
                        self.with_page(s, |p| {
                            if p.target == fid {
                                p.loading = start;
                            }
                        });
                    }
                }
                "Page.javascriptDialogOpening" => self.on_dialog(&cdp, sess, &ev.params),
                "Page.screencastFrame" => self.on_frame(&cdp, sess, &ev.params),
                _ => {}
            }
        }
    }

    fn with_page(&self, session: &str, f: impl FnOnce(&mut PageState)) {
        if let Some(p) = self.inner.lock().unwrap().pages.get_mut(session) {
            f(p);
        }
    }

    fn on_target(&self, t: &Value, created: bool) {
        if t["type"] != "page" {
            return;
        }
        let id = t["targetId"].as_str().unwrap_or("").to_string();
        let url = t["url"].as_str().unwrap_or("").to_string();
        if id.is_empty() || url.starts_with("devtools://") {
            return;
        }
        let title = t["title"].as_str().unwrap_or("").to_string();
        {
            let mut i = self.inner.lock().unwrap();
            if let Some(x) = i.tabs.iter_mut().find(|x| x.id == id) {
                x.title = title;
                x.url = url;
            } else {
                let opened_by_active = created && t["openerId"].as_str().is_some() && i.active.as_ref().map(|a| a.target.as_str()) == t["openerId"].as_str();
                i.tabs.push(TabInfo { id: id.clone(), title, url, active: false });
                if opened_by_active {
                    i.popup = Some(id);
                }
            }
        }
        self.emit_status();
    }

    fn on_target_gone(&self, id: &str) {
        {
            let mut i = self.inner.lock().unwrap();
            i.tabs.retain(|t| t.id != id);
            if let Some(s) = i.sessions.remove(id) {
                i.pages.remove(&s);
            }
            if i.active.as_ref().is_some_and(|t| t.target == id) {
                i.active = None;
            }
            if i.popup.as_deref() == Some(id) {
                i.popup = None;
            }
        }
        self.emit_status();
    }

    fn on_detached(&self, session: &str) {
        let mut i = self.inner.lock().unwrap();
        i.pages.remove(session);
        i.sessions.retain(|_, s| s != session);
        if i.active.as_ref().is_some_and(|t| t.session == session) {
            i.active = None;
        }
    }

    fn on_closed(&self, cdp: &Arc<Cdp>) {
        {
            let mut i = self.inner.lock().unwrap();
            if !i.cdp.as_ref().is_some_and(|c| Arc::ptr_eq(c, cdp)) {
                return;
            }
            i.cdp = None;
            i.state = if i.login.is_some() { "login" } else { "off" }.into();
            i.active = None;
            i.sessions.clear();
            i.pages.clear();
            i.tabs.clear();
            i.popup = None;
            i.agent = None;
            if let Some(c) = i.child.as_mut() {
                if matches!(c.try_wait(), Ok(Some(_))) {
                    i.child = None;
                }
            }
        }
        self.emit_status();
    }

    fn on_dialog(&self, cdp: &Arc<Cdp>, session: Option<&str>, p: &Value) {
        let kind = p["type"].as_str().unwrap_or("alert");
        let msg = crate::util::truncate_end(p["message"].as_str().unwrap_or("").trim(), 300);
        let approved = self.inner.lock().unwrap().accept_dialogs_until.is_some_and(|t| Instant::now() < t);
        let accept = matches!(kind, "alert" | "beforeunload") || approved;
        cdp.send(session, "Page.handleJavaScriptDialog", json!({"accept": accept}));
        let note = match kind {
            "alert" => format!("Sayfa bir uyarı penceresi gösterdi (kapatıldı): «{msg}»"),
            "beforeunload" => "Sayfa ayrılmadan önce onay istedi; sayfadan çıkıldı.".to_string(),
            _ if accept => format!("Sayfa onay istedi: «{msg}». Kullanıcı bu işlemi onayladığı için kabul edildi."),
            _ => format!("Sayfa onay istedi: «{msg}». İptal edildi; onaylamak gerekiyorsa kullanıcıya sor."),
        };
        self.inner.lock().unwrap().notes.push(note);
    }

    fn on_frame(&self, cdp: &Arc<Cdp>, session: Option<&str>, p: &Value) {
        let Some(sess) = session else { return };
        let frame_no = p["sessionId"].as_i64().unwrap_or(0);
        let (show, wait) = {
            let mut i = self.inner.lock().unwrap();
            let show = i.viewing && i.active.as_ref().is_some_and(|t| t.session == sess);
            let now = Instant::now();
            // En fazla ~10 kare/sn: kare onayı geciktirilerek tarayıcı yavaşlatılır.
            let wait = i.last_frame.map(|t| Duration::from_millis(100).saturating_sub(now.saturating_duration_since(t))).unwrap_or_default();
            i.last_frame = Some(now + wait);
            (show, wait)
        };
        if show {
            let m = &p["metadata"];
            self.events.emit("browser.frame", json!({"data": p["data"], "w": m["deviceWidth"], "h": m["deviceHeight"]}));
        }
        let cdp = cdp.clone();
        let s = sess.to_string();
        tokio::spawn(async move {
            if !wait.is_zero() {
                tokio::time::sleep(wait).await;
            }
            cdp.send(Some(&s), "Page.screencastFrameAck", json!({"sessionId": frame_no}));
        });
    }

    // ------------------------------------------------------------- sekmeler

    async fn attach(&self, cdp: &Cdp, target: &str) -> Result<String, String> {
        if let Some(s) = self.inner.lock().unwrap().sessions.get(target).cloned() {
            return Ok(s);
        }
        let r = cdp.call(None, "Target.attachToTarget", json!({"targetId": target, "flatten": true})).await?;
        let session = r["sessionId"].as_str().ok_or("sekmeye bağlanılamadı")?.to_string();
        {
            let mut i = self.inner.lock().unwrap();
            i.sessions.insert(target.to_string(), session.clone());
            i.pages.insert(session.clone(), PageState { target: target.to_string(), ..Default::default() });
        }
        cdp.call(Some(&session), "Page.enable", json!({})).await?;
        Ok(session)
    }

    /// Sekmeyi etkin yapar (gerçek pencerede de öne gelir).
    pub async fn activate(self: &Arc<Self>, cdp: &Arc<Cdp>, target: &str) -> Result<(Arc<Cdp>, Tab), String> {
        let session = self.attach(cdp, target).await?;
        let _ = cdp.call(None, "Target.activateTarget", json!({"targetId": target})).await;
        let tab = Tab { target: target.to_string(), session };
        let (old, viewing) = {
            let mut i = self.inner.lock().unwrap();
            let old = i.active.replace(tab.clone());
            (old, i.viewing)
        };
        if viewing && old.as_ref().map(|o| o.session != tab.session).unwrap_or(true) {
            if let Some(o) = old {
                let _ = cdp.call(Some(&o.session), "Page.stopScreencast", json!({})).await;
            }
            self.start_screencast(cdp, &tab).await;
        }
        self.emit_status();
        Ok((cdp.clone(), tab))
    }

    /// Etkin sekme; yoksa ilk sekme ya da yeni bir sekme. Tarayıcı kapalıysa açılır.
    pub async fn tab(self: &Arc<Self>, s: &BrowserSettings) -> Result<(Arc<Cdp>, Tab), String> {
        let cdp = self.ensure(s).await?;
        let current = self.inner.lock().unwrap().active.clone();
        if let Some(t) = current {
            return Ok((cdp, t));
        }
        // Tarayıcı yeni açıldıysa açılış sekmesi listede birkaç yüz ms sonra görünebilir: ikinci bir boş sekme açmadan önce bekle.
        let mut found = None;
        for _ in 0..10 {
            let targets = cdp.call(None, "Target.getTargets", json!({})).await?;
            if let Some(t) = page_targets(&targets).into_iter().next() {
                found = Some(t.id);
                break;
            }
            tokio::time::sleep(Duration::from_millis(200)).await;
        }
        let id = match found {
            Some(id) => id,
            None => cdp.call(None, "Target.createTarget", json!({"url": "about:blank"})).await?["targetId"].as_str().unwrap_or("").to_string(),
        };
        if id.is_empty() {
            return Err("tarayıcıda sekme açılamadı".into());
        }
        self.activate(&cdp, &id).await
    }

    pub async fn new_tab(self: &Arc<Self>, s: &BrowserSettings, url: &str) -> Result<(Arc<Cdp>, Tab), String> {
        let cdp = self.ensure(s).await?;
        let r = cdp.call(None, "Target.createTarget", json!({"url": "about:blank"})).await?;
        let id = r["targetId"].as_str().ok_or("yeni sekme açılamadı")?.to_string();
        let (cdp, tab) = self.activate(&cdp, &id).await?;
        if !url.is_empty() {
            self.navigate(&cdp, &tab, url).await?;
        }
        Ok((cdp, tab))
    }

    pub fn tabs(&self) -> Vec<TabInfo> {
        self.status().tabs
    }

    pub async fn close_tab(self: &Arc<Self>, id: &str) -> Result<(), String> {
        let cdp = self.live().ok_or("tarayıcı açık değil")?;
        let only = self.inner.lock().unwrap().tabs.len() <= 1;
        if only {
            // Son sekme kapanınca tarayıcı da kapanır; boş bir sekme bırak.
            cdp.call(None, "Target.createTarget", json!({"url": "about:blank"})).await?;
        }
        cdp.call(None, "Target.closeTarget", json!({"targetId": id})).await?;
        let mut i = self.inner.lock().unwrap();
        if i.active.as_ref().is_some_and(|t| t.target == id) {
            i.active = None;
        }
        Ok(())
    }

    /// Etkin sekmenin az önce açtığı yeni sekme (varsa) — bir kez döner.
    pub fn take_popup(&self) -> Option<String> {
        self.inner.lock().unwrap().popup.take()
    }

    pub fn clear_popup(&self) {
        self.inner.lock().unwrap().popup = None;
    }

    pub fn take_notes(&self) -> Vec<String> {
        std::mem::take(&mut self.inner.lock().unwrap().notes)
    }

    pub fn accept_dialogs_for(&self, d: Duration) {
        self.inner.lock().unwrap().accept_dialogs_until = Some(Instant::now() + d);
    }

    // ------------------------------------------------------------- sayfa

    async fn world(&self, cdp: &Cdp, tab: &Tab) -> Result<i64, String> {
        if let Some(w) = self.inner.lock().unwrap().pages.get(&tab.session).and_then(|p| p.world) {
            return Ok(w);
        }
        let r = cdp.call(Some(&tab.session), "Page.createIsolatedWorld", json!({"frameId": tab.target, "worldName": "feride"})).await?;
        let id = r["executionContextId"].as_i64().ok_or("sayfada betik ortamı oluşturulamadı")?;
        self.with_page(&tab.session, |p| p.world = Some(id));
        Ok(id)
    }

    /// Sayfada (FerIDE'nin yalıtılmış dünyasında) bir ifade çalıştırır ve sonucunu döndürür.
    pub async fn eval(&self, cdp: &Cdp, tab: &Tab, expr: &str) -> Result<Value, String> {
        let mut last = String::new();
        for _ in 0..4 {
            let ctx = match self.world(cdp, tab).await {
                Ok(c) => c,
                Err(e) => {
                    last = e;
                    tokio::time::sleep(Duration::from_millis(250)).await;
                    continue;
                }
            };
            let r = cdp
                .call(Some(&tab.session), "Runtime.evaluate", json!({"expression": expr, "contextId": ctx, "returnByValue": true, "awaitPromise": true}))
                .await;
            match r {
                Ok(v) => {
                    if let Some(ex) = v.get("exceptionDetails") {
                        let msg = ex["exception"]["description"].as_str().or_else(|| ex["text"].as_str()).unwrap_or("betik hatası");
                        return Err(format!("sayfa betiği hata verdi: {}", crate::util::truncate_end(msg, 300)));
                    }
                    return Ok(v["result"]["value"].clone());
                }
                Err(e) => {
                    // Sayfa yenilendi / başka belgeye geçildi: betik ortamını yeniden oluştur.
                    if e.contains("context") || e.contains("Cannot find") || e.contains("destroyed") {
                        self.with_page(&tab.session, |p| p.world = None);
                        last = e;
                        tokio::time::sleep(Duration::from_millis(200)).await;
                        continue;
                    }
                    return Err(e);
                }
            }
        }
        Err(last)
    }

    /// page.js'teki bir işlevi çağırır: `__fr.<func>(args…)`.
    pub async fn call_page(&self, cdp: &Cdp, tab: &Tab, func: &str, args: Value) -> Result<Value, String> {
        let args = args.as_array().map(|a| a.iter().map(|v| v.to_string()).collect::<Vec<_>>().join(",")).unwrap_or_default();
        self.eval(cdp, tab, &format!("{PAGE_JS}\n;globalThis.__fr.{func}({args})")).await
    }

    fn loading(&self, session: &str) -> bool {
        self.inner.lock().unwrap().pages.get(session).is_some_and(|p| p.loading)
    }

    /// İşlemden sonra sayfanın oturmasını bekler: yükleme bitsin, belge hazır olsun, DOM bir süre değişmesin.
    pub async fn settle(&self, cdp: &Cdp, tab: &Tab) {
        tokio::time::sleep(Duration::from_millis(150)).await;
        let deadline = Instant::now() + Duration::from_secs(15);
        while self.loading(&tab.session) && Instant::now() < deadline {
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        let started = Instant::now();
        while Instant::now() < deadline {
            match self.eval(cdp, tab, "document.readyState").await {
                Ok(v) if v == "complete" => break,
                Ok(v) if v == "interactive" && started.elapsed() > Duration::from_secs(3) => break,
                Err(_) if started.elapsed() > Duration::from_secs(5) => break,
                _ => tokio::time::sleep(Duration::from_millis(150)).await,
            }
        }
        let _ = self.call_page(cdp, tab, "quiet", json!([350, 2500])).await;
    }

    pub async fn navigate(&self, cdp: &Cdp, tab: &Tab, url: &str) -> Result<(), String> {
        let r = cdp.call_timeout(Some(&tab.session), "Page.navigate", json!({"url": url}), Duration::from_secs(45)).await?;
        if let Some(e) = r["errorText"].as_str().filter(|e| !e.is_empty()) {
            return Err(format!("sayfa açılamadı ({e})"));
        }
        self.settle(cdp, tab).await;
        Ok(())
    }

    /// Geçmişte ileri/geri gider. Gidecek sayfa yoksa `false`.
    pub async fn history(&self, cdp: &Cdp, tab: &Tab, delta: i64) -> Result<bool, String> {
        let h = cdp.call(Some(&tab.session), "Page.getNavigationHistory", json!({})).await?;
        let cur = h["currentIndex"].as_i64().unwrap_or(0);
        let entries = h["entries"].as_array().cloned().unwrap_or_default();
        let idx = cur + delta;
        if idx < 0 || idx as usize >= entries.len() {
            return Ok(false);
        }
        let id = entries[idx as usize]["id"].as_i64().unwrap_or(0);
        cdp.call(Some(&tab.session), "Page.navigateToHistoryEntry", json!({"entryId": id})).await?;
        Ok(true)
    }

    pub async fn mouse_click(&self, cdp: &Cdp, tab: &Tab, x: f64, y: f64, clicks: i64) -> Result<(), String> {
        let s = Some(tab.session.as_str());
        cdp.call(s, "Input.dispatchMouseEvent", json!({"type": "mouseMoved", "x": x, "y": y, "button": "none"})).await?;
        cdp.call(s, "Input.dispatchMouseEvent", json!({"type": "mousePressed", "x": x, "y": y, "button": "left", "buttons": 1, "clickCount": clicks}))
            .await?;
        cdp.call(s, "Input.dispatchMouseEvent", json!({"type": "mouseReleased", "x": x, "y": y, "button": "left", "buttons": 0, "clickCount": clicks}))
            .await?;
        Ok(())
    }

    /// "Enter", "Control+a" gibi bir tuş birleşimine basar.
    pub async fn press(&self, cdp: &Cdp, tab: &Tab, spec: &str) -> Result<(), String> {
        let (mods, k) = input::parse_combo(spec)?;
        let (down, up) = input::key_events(mods, &k);
        cdp.call(Some(&tab.session), "Input.dispatchKeyEvent", down).await?;
        cdp.call(Some(&tab.session), "Input.dispatchKeyEvent", up).await?;
        Ok(())
    }

    pub async fn insert_text(&self, cdp: &Cdp, tab: &Tab, text: &str) -> Result<(), String> {
        cdp.call(Some(&tab.session), "Input.insertText", json!({"text": text})).await.map(|_| ())
    }

    /// Görünen alanın JPEG ekran görüntüsü (base64).
    pub async fn screenshot(&self, cdp: &Cdp, tab: &Tab, quality: i64) -> Result<String, String> {
        let r = cdp
            .call_timeout(Some(&tab.session), "Page.captureScreenshot", json!({"format": "jpeg", "quality": quality}), Duration::from_secs(20))
            .await?;
        r["data"].as_str().map(String::from).ok_or_else(|| "ekran görüntüsü alınamadı".into())
    }

    // ------------------------------------------------------------- arayüz

    async fn start_screencast(&self, cdp: &Cdp, tab: &Tab) {
        let _ = cdp
            .call(Some(&tab.session), "Page.startScreencast", json!({"format": "jpeg", "quality": 60, "maxWidth": 1600, "maxHeight": 1600}))
            .await;
        // Durağan sayfada akış kare göndermeyebilir: ilk kare ekran görüntüsünden.
        if let Ok(data) = self.screenshot(cdp, tab, 60).await {
            let vp = self.call_page(cdp, tab, "viewport", json!([])).await.unwrap_or_default();
            self.events.emit("browser.frame", json!({"data": data, "w": vp["w"], "h": vp["h"]}));
        }
    }

    /// Arayüzdeki Tarayıcı paneli açıldı/kapandı: canlı görüntü akışını başlat/durdur.
    pub async fn set_view(self: &Arc<Self>, on: bool) {
        let (cdp, tab) = {
            let mut i = self.inner.lock().unwrap();
            i.viewing = on;
            (i.cdp.clone(), i.active.clone())
        };
        if let (Some(cdp), Some(tab)) = (cdp, tab) {
            if on {
                self.start_screencast(&cdp, &tab).await;
            } else {
                let _ = cdp.call(Some(&tab.session), "Page.stopScreencast", json!({})).await;
            }
        }
        self.emit_status();
    }

    /// Paneldeki fare/klavye girdisini etkin sekmeye iletir.
    pub async fn user_input(self: &Arc<Self>, p: &Value) -> Result<(), String> {
        let (cdp, tab) = {
            let i = self.inner.lock().unwrap();
            (i.cdp.clone(), i.active.clone())
        };
        let (Some(cdp), Some(tab)) = (cdp, tab) else { return Ok(()) };
        let s = Some(tab.session.as_str());
        let x = p["x"].as_f64().unwrap_or(0.0);
        let y = p["y"].as_f64().unwrap_or(0.0);
        let mods = p["modifiers"].as_i64().unwrap_or(0);
        match p["type"].as_str().unwrap_or("") {
            t @ ("mousedown" | "mouseup" | "mousemove") => {
                let kind = match t {
                    "mousedown" => "mousePressed",
                    "mouseup" => "mouseReleased",
                    _ => "mouseMoved",
                };
                let button = p["button"].as_str().unwrap_or(if kind == "mouseMoved" { "none" } else { "left" });
                let ev = json!({"type": kind, "x": x, "y": y, "button": button, "buttons": p["buttons"].as_i64().unwrap_or(0),
                                "clickCount": p["clicks"].as_i64().unwrap_or(1), "modifiers": mods});
                if kind == "mouseMoved" {
                    cdp.send(s, "Input.dispatchMouseEvent", ev);
                } else {
                    cdp.call(s, "Input.dispatchMouseEvent", ev).await?;
                }
                if kind == "mouseReleased" {
                    // Tıklama yeni sekme açtıysa panel ona geçsin.
                    let me = Arc::clone(self);
                    let cdp = cdp.clone();
                    tokio::spawn(async move {
                        tokio::time::sleep(Duration::from_millis(600)).await;
                        if let Some(id) = me.take_popup() {
                            let _ = me.activate(&cdp, &id).await;
                        }
                    });
                }
            }
            "wheel" => cdp.send(
                s,
                "Input.dispatchMouseEvent",
                json!({"type": "mouseWheel", "x": x, "y": y, "deltaX": p["dx"].as_f64().unwrap_or(0.0), "deltaY": p["dy"].as_f64().unwrap_or(0.0), "modifiers": mods}),
            ),
            "text" => {
                cdp.call(s, "Input.insertText", json!({"text": p["text"].as_str().unwrap_or("")})).await?;
            }
            t @ ("keydown" | "keyup") => {
                let key = p["key"].as_str().unwrap_or("");
                let vk = p["keyCode"].as_i64().unwrap_or(0);
                let mut ev = json!({"type": if t == "keydown" { "rawKeyDown" } else { "keyUp" }, "key": key, "code": p["code"].as_str().unwrap_or(""),
                                    "windowsVirtualKeyCode": vk, "nativeVirtualKeyCode": vk, "modifiers": mods});
                if t == "keydown" {
                    if key == "Enter" && mods & (input::ALT | input::CTRL | input::META) == 0 {
                        ev["type"] = json!("keyDown");
                        ev["text"] = json!("\r");
                    }
                    if let Some(c) = input::editing_command(mods, key) {
                        ev["commands"] = json!([c]);
                    }
                }
                cdp.call(s, "Input.dispatchKeyEvent", ev).await?;
            }
            _ => {}
        }
        Ok(())
    }

    /// Kullanıcının adres çubuğundan açtığı sayfa.
    pub async fn user_open(self: &Arc<Self>, s: &BrowserSettings, raw: &str) -> Result<(), String> {
        let url = user_url(raw);
        let (cdp, tab) = self.tab(s).await?;
        let r = cdp.call_timeout(Some(&tab.session), "Page.navigate", json!({"url": url}), Duration::from_secs(45)).await?;
        match r["errorText"].as_str().filter(|e| !e.is_empty()) {
            Some(e) => Err(format!("sayfa açılamadı ({e})")),
            None => Ok(()),
        }
    }

    pub async fn user_nav(self: &Arc<Self>, s: &BrowserSettings, action: &str) -> Result<(), String> {
        let (cdp, tab) = self.tab(s).await?;
        match action {
            "back" => self.history(&cdp, &tab, -1).await.map(|_| ()),
            "forward" => self.history(&cdp, &tab, 1).await.map(|_| ()),
            "reload" => cdp.call(Some(&tab.session), "Page.reload", json!({})).await.map(|_| ()),
            _ => Err(format!("bilinmeyen işlem: {action}")),
        }
    }

    pub async fn user_switch(self: &Arc<Self>, s: &BrowserSettings, id: &str) -> Result<(), String> {
        let cdp = self.ensure(s).await?;
        self.activate(&cdp, id).await.map(|_| ())
    }

    /// Gerçek tarayıcı penceresini öne getirir (küçültülmüşse açar).
    pub async fn front(self: &Arc<Self>, s: &BrowserSettings) -> Result<(), String> {
        let (cdp, tab) = self.tab(s).await?;
        if let Ok(w) = cdp.call(None, "Browser.getWindowForTarget", json!({"targetId": tab.target})).await {
            if let Some(id) = w["windowId"].as_i64() {
                if w["bounds"]["windowState"] == "minimized" {
                    let _ = cdp.call(None, "Browser.setWindowBounds", json!({"windowId": id, "bounds": {"windowState": "normal"}})).await;
                }
            }
        }
        cdp.call(Some(&tab.session), "Page.bringToFront", json!({})).await.map(|_| ())
    }

    pub fn set_user_control(&self, on: bool) {
        self.control.send_replace(on);
        self.emit_status();
    }

    /// Kullanıcı kontrolü aldıysa bırakana kadar bekler. İptal edilirse `false`.
    pub async fn wait_released(&self, cancel: &CancellationToken) -> bool {
        let mut rx = self.control.subscribe();
        loop {
            if !*rx.borrow_and_update() {
                return true;
            }
            tokio::select! {
                r = rx.changed() => if r.is_err() { return true; },
                _ = cancel.cancelled() => return false,
            }
        }
    }

    pub fn user_has_control(&self) -> bool {
        *self.control.borrow()
    }

    /// Arayüzde gösterilecek ajan işlemi.
    pub fn set_agent(&self, what: Option<String>) {
        self.inner.lock().unwrap().agent = what;
        self.emit_status();
    }

    /// Tarayıcıyı kapatır (oturumlar profilde kalır).
    pub async fn close(&self) {
        let Some(cdp) = self.live() else { return };
        let _ = cdp.call_timeout(None, "Browser.close", json!({}), Duration::from_secs(5)).await;
        for _ in 0..30 {
            if cdp.is_closed() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
    }

    /// Giriş penceresi için kapatılan tarayıcının son sayfası (bir kez döner).
    pub fn take_resume_url(&self) -> Option<String> {
        self.inner.lock().unwrap().resume_url.take()
    }

    /// Hesap giriş penceresi açık mı?
    pub fn login_open(&self) -> bool {
        self.inner.lock().unwrap().login.as_mut().is_some_and(|c| matches!(c.try_wait(), Ok(None)))
    }

    /// Hesaplara giriş için tarayıcıyı FerIDE profiliyle **kontrolsüz**, sıradan bir pencere olarak açar.
    ///
    /// Kontrol edilen tarayıcı bunu sitelere bildirir (`navigator.webdriver`) ve FerIDE bunu gizlemez; Google gibi
    /// bazı siteler böyle bir tarayıcıda hesap girişine izin vermez. Kullanıcı bu pencerede kendisi girer (şifre, iki
    /// adımlı doğrulama) ve pencereyi kapatır; oturumlar profilde kalır, ajan sonra onları kullanır.
    pub async fn open_login(self: &Arc<Self>, s: &BrowserSettings, url: &str) -> Result<(), String> {
        let _g = self.launch.lock().await;
        if self.login_open() {
            return Err("Giriş penceresi zaten açık.".into());
        }
        let b = find(s).ok_or("Bu bilgisayarda Chrome, Edge, Brave ya da Chromium bulunamadı.")?;
        // Aynı profili iki tarayıcı kullanamaz: kontrol edilen tarayıcı açıksa kapat ve gerçekten çıkmasını bekle.
        if self.is_running() {
            let last = self.status().tabs.into_iter().find(|t| t.active).map(|t| t.url).filter(|u| u.starts_with("http"));
            self.inner.lock().unwrap().resume_url = last;
        }
        self.close().await;
        let child = self.inner.lock().unwrap().child.take();
        if let Some(mut ch) = child {
            for _ in 0..50 {
                if matches!(ch.try_wait(), Ok(Some(_))) {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
        } else {
            tokio::time::sleep(Duration::from_millis(800)).await;
        }
        let profile = self.profile_dir();
        std::fs::create_dir_all(&profile).map_err(|e| format!("tarayıcı profili oluşturulamadı: {e}"))?;
        let _ = std::fs::remove_file(profile.join("DevToolsActivePort"));
        let url = if url.trim().is_empty() { "https://accounts.google.com/".to_string() } else { user_url(url) };
        let child = std::process::Command::new(&b.path)
            .arg(format!("--user-data-dir={}", profile.display()))
            .args(["--no-first-run", "--no-default-browser-check", &url])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|e| format!("{} başlatılamadı: {e}", b.name))?;
        {
            let mut i = self.inner.lock().unwrap();
            i.login = Some(child);
            i.state = "login".into();
            i.error = None;
            i.name = b.name.clone();
        }
        self.emit_status();
        let me = Arc::clone(self);
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(Duration::from_millis(700)).await;
                let done = {
                    let mut i = me.inner.lock().unwrap();
                    match i.login.as_mut() {
                        Some(c) => !matches!(c.try_wait(), Ok(None)),
                        None => true,
                    }
                };
                if done {
                    {
                        let mut i = me.inner.lock().unwrap();
                        i.login = None;
                        if i.state == "login" {
                            i.state = "off".into();
                        }
                    }
                    me.emit_status();
                    break;
                }
            }
        });
        Ok(())
    }

    /// FerIDE kapanırken: tarayıcıyı düzgünce kapat (oturumlar kaydedilsin). Giriş penceresi kullanıcınındır, açık kalır.
    pub fn shutdown(&self) {
        let (cdp, child) = {
            let mut i = self.inner.lock().unwrap();
            (i.cdp.take(), i.child.take())
        };
        if let Some(c) = cdp {
            c.send(None, "Browser.close", json!({}));
        }
        if let Some(mut ch) = child {
            for _ in 0..20 {
                if matches!(ch.try_wait(), Ok(Some(_))) {
                    break;
                }
                std::thread::sleep(Duration::from_millis(100));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn address_bar() {
        assert_eq!(user_url("google.com"), "https://google.com");
        assert_eq!(user_url("localhost:3000"), "http://localhost:3000");
        assert_eq!(user_url("https://a.b/c"), "https://a.b/c");
        assert!(user_url("istanbul hava durumu").starts_with("https://www.google.com/search?q=istanbul+hava+durumu"));
    }

    #[test]
    fn port_file() {
        let d = tempfile::tempdir().unwrap();
        assert!(read_port_file(d.path()).is_none());
        std::fs::write(d.path().join("DevToolsActivePort"), "51234\n/devtools/browser/abc-123\n").unwrap();
        assert_eq!(read_port_file(d.path()).as_deref(), Some("ws://127.0.0.1:51234/devtools/browser/abc-123"));
    }
}
