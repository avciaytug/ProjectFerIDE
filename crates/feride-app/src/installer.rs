//! Kurulum sihirbazı ve kaldırıcı (`feride install`, `feride uninstall`).
//!
//! Sihirbaz, ana uygulamanınkinden ayrı hafif bir yerel sunucu açar (aynı jeton ve kaynak denetimi) ve arayüzü
//! `install.html` ile gösterir. Kullanıcı klasör seçip "Kur"a basana kadar diske hiçbir şey yazılmaz.

use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::{Query, State};
use axum::http::{header, HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use axum::Router;
use futures::{SinkExt, StreamExt};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::io::Write;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::{mpsc, Notify};

use feride_core::install::{self, InstallInfo, InstallOptions, Kind};

pub struct InstallArgs {
    pub dir: Option<PathBuf>,
    pub data: Option<PathBuf>,
    pub yes: bool,
    pub update: bool,
    pub no_shortcuts: bool,
    pub no_path: bool,
    pub no_launch: bool,
    pub print_url: bool,
}

pub struct UninstallArgs {
    pub yes: bool,
    pub purge: bool,
    pub wait_pid: Option<u32>,
    pub notify: bool,
}

/// Kurulum ve kaldırma günlüğü geçici klasöre yazılır (veri klasörü henüz seçilmemiş olabilir).
pub fn init_logging() -> tracing_appender::non_blocking::WorkerGuard {
    use tracing_subscriber::{fmt, prelude::*, EnvFilter};
    let file = tracing_appender::rolling::never(std::env::temp_dir(), "feride-kurulum.log");
    let (nb, guard) = tracing_appender::non_blocking(file);
    let _ = tracing_subscriber::registry()
        .with(EnvFilter::new("info"))
        .with(fmt::layer().with_writer(nb).with_ansi(false))
        .try_init();
    guard
}

/// Kurulmamış bir kopya mı açıldı? (indirilenler klasöründen çift tıklama gibi). Öyleyse sihirbaz gösterilir.
pub fn should_offer_install() -> bool {
    if std::env::var_os("FERIDE_HOME").is_some() || std::env::var_os("FERIDE_NO_INSTALLER").is_some() || cfg!(debug_assertions) {
        return false;
    }
    let Some(dir) = install::current_exe_dir() else { return false };
    let s = dir.to_string_lossy().to_lowercase().replace('\\', "/");
    if s.contains("/target/release") || s.contains("/target/debug") {
        return false; // geliştirme derlemesi
    }
    install::running_installed().is_none()
}

fn absolute(p: PathBuf) -> PathBuf {
    if p.is_absolute() {
        p
    } else {
        std::env::current_dir().map(|c| c.join(&p)).unwrap_or(p)
    }
}

fn current_exe() -> anyhow::Result<PathBuf> {
    let exe = std::env::current_exe()?;
    Ok(dunce::canonicalize(&exe).unwrap_or(exe))
}

/// Kurulan FerIDE'yi bu süreçten bağımsız başlatır.
pub fn launch(exe: &Path) {
    let mut c = std::process::Command::new(exe);
    if let Some(d) = exe.parent() {
        c.current_dir(d);
    }
    c.stdin(std::process::Stdio::null()).stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        c.creation_flags(0x0000_0008 | 0x0000_0200); // DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP
    }
    if let Err(e) = c.spawn() {
        tracing::error!("FerIDE başlatılamadı: {e}");
    }
}

fn print_report(rep: &install::InstallReport) {
    if let Some(i) = &rep.info {
        println!("FerIDE {} kuruldu.\n  Program: {}\n  Veri:    {}", i.version, i.install_dir.display(), i.data_dir.display());
    }
    for w in &rep.warnings {
        println!("  Uyarı: {w}");
    }
    let _ = std::io::stdout().flush();
}

/// `feride install`
pub fn cli_install(a: InstallArgs) -> i32 {
    let src = match current_exe() {
        Ok(s) => s,
        Err(e) => {
            eprintln!("Program yolu okunamadı: {e}");
            return 1;
        }
    };
    let existing = install::find_existing();
    // Kuruluysa (betikten güncelleme) sormadan yerinde güncelle.
    if a.update {
        if let Some(info) = &existing {
            let opts = InstallOptions {
                install_dir: info.install_dir.clone(),
                data_dir: info.data_dir.clone(),
                desktop_shortcut: info.desktop_shortcut,
                menu_shortcut: info.menu_shortcut,
                add_path: info.add_path,
            };
            return match install::install(&src, &opts, true) {
                Ok(rep) => {
                    print_report(&rep);
                    if !a.no_launch {
                        launch(&rep.exe);
                    }
                    0
                }
                Err(e) => {
                    eprintln!("Güncelleme başarısız: {e}");
                    1
                }
            };
        }
    }
    if a.yes || a.dir.is_some() {
        let install_dir = a.dir.map(absolute).or_else(|| existing.as_ref().map(|i| i.install_dir.clone())).unwrap_or_else(install::default_install_dir);
        let data_dir = a.data.map(absolute).or_else(|| existing.as_ref().map(|i| i.data_dir.clone())).unwrap_or_else(install::default_data_dir);
        let opts = InstallOptions {
            install_dir,
            data_dir,
            desktop_shortcut: !a.no_shortcuts,
            menu_shortcut: !a.no_shortcuts,
            add_path: !a.no_path,
        };
        return match install::install(&src, &opts, true) {
            Ok(rep) => {
                print_report(&rep);
                if !a.no_launch {
                    launch(&rep.exe);
                }
                0
            }
            Err(e) => {
                eprintln!("Kurulum başarısız: {e}");
                1
            }
        };
    }
    run_wizard(a.no_launch, a.update, a.print_url)
}

// ------------------------------------------------------------------ sihirbaz

#[derive(Clone)]
struct Wiz {
    token: String,
    port: u16,
    quit: Arc<Notify>,
    launch: Arc<Mutex<Option<PathBuf>>>,
    /// Kurulum tamamlandı mı? (çıkış kodu: 0 kuruldu, 2 vazgeçildi)
    installed: Arc<AtomicBool>,
    no_launch: bool,
    update: bool,
}

/// Sihirbazın çıkış kodu: kurulduysa 0, kullanıcı vazgeçtiyse 2 (betikler buna göre mesaj verir).
fn wizard_exit_code(installed: &AtomicBool) -> i32 {
    if installed.load(Ordering::SeqCst) {
        0
    } else {
        2
    }
}

/// "Kurmadan, bu klasörden kullan" seçeneği için klasör. Geçici klasörden (kurulum betiği ya da zip'in içinden)
/// çalışıyorsa sunulmaz: o klasör kısa süre sonra silinir.
fn portable_dir() -> Option<PathBuf> {
    let dir = install::current_exe_dir()?;
    let tmp = std::env::temp_dir();
    (!install::is_inside(&dir, &tmp) && !install::same_path(&dir, &tmp)).then_some(dir)
}

fn launch_pending(l: &Mutex<Option<PathBuf>>) {
    if let Some(exe) = l.lock().unwrap().take() {
        launch(&exe);
    }
}

/// Kurulum sihirbazını açar (pencerede; açılamazsa tarayıcıda) ve kapanana kadar bekler.
pub fn run_wizard(no_launch: bool, update: bool, print_url: bool) -> i32 {
    let rt = match tokio::runtime::Builder::new_multi_thread().enable_all().build() {
        Ok(r) => r,
        Err(e) => {
            eprintln!("{e}");
            return 1;
        }
    };
    let quit = Arc::new(Notify::new());
    let launch_slot = Arc::new(Mutex::new(None::<PathBuf>));
    let installed = Arc::new(AtomicBool::new(false));
    let (url, origin) = match rt.block_on(start_server(no_launch, update, quit.clone(), launch_slot.clone(), installed.clone())) {
        Ok(x) => x,
        Err(e) => {
            eprintln!("Kurulum sihirbazı başlatılamadı: {e}");
            return 1;
        }
    };
    tracing::info!("kurulum sihirbazı: {origin}");
    if print_url {
        println!("FerIDE kurulum sihirbazı: {url}");
        let _ = std::io::stdout().flush();
        rt.block_on(quit.notified());
        launch_pending(&launch_slot);
        return wizard_exit_code(&installed);
    }
    #[cfg(feature = "desktop")]
    {
        let (slot, done) = (launch_slot.clone(), installed.clone());
        let webview_dir = std::env::temp_dir().join("feride-kurulum-webview");
        // Pencere kapanınca süreç sonlanır (bkz. desktop::run); kurulan FerIDE ondan önce başlatılır.
        if let Err(e) = crate::desktop::run(url.clone(), origin, webview_dir, crate::desktop::WindowSpec::installer(), quit.clone(), move || {
            launch_pending(&slot);
            std::process::exit(wizard_exit_code(&done));
        }) {
            tracing::warn!("sihirbaz penceresi açılamadı ({e}); tarayıcıda açılıyor");
        }
    }
    let _ = open::that_detached(&url);
    println!("Kurulum sihirbazı tarayıcıda açıldı: {url}");
    rt.block_on(quit.notified());
    launch_pending(&launch_slot);
    wizard_exit_code(&installed)
}

async fn start_server(
    no_launch: bool,
    update: bool,
    quit: Arc<Notify>,
    launch: Arc<Mutex<Option<PathBuf>>>,
    installed: Arc<AtomicBool>,
) -> anyhow::Result<(String, String)> {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
    let port = listener.local_addr()?.port();
    let token = feride_core::util::random_token();
    let st = Wiz { token: token.clone(), port, quit, launch, installed, no_launch, update };
    let app = Router::new().route("/ws", get(ws_handler)).fallback(get(crate::server::static_handler)).with_state(st);
    tokio::spawn(async move {
        if let Err(e) = axum::serve(listener, app.into_make_service_with_connect_info::<SocketAddr>()).await {
            tracing::error!("sihirbaz sunucusu durdu: {e}");
        }
    });
    let origin = format!("http://127.0.0.1:{port}");
    Ok((format!("{origin}/install.html#token={token}"), origin))
}

async fn ws_handler(ws: WebSocketUpgrade, State(st): State<Wiz>, Query(q): Query<HashMap<String, String>>, headers: HeaderMap) -> Response {
    if !q.get("token").is_some_and(|t| feride_core::util::ct_eq(t, &st.token)) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    if let Some(origin) = headers.get(header::ORIGIN).and_then(|o| o.to_str().ok()) {
        if origin != format!("http://127.0.0.1:{}", st.port) && origin != format!("http://localhost:{}", st.port) {
            return StatusCode::FORBIDDEN.into_response();
        }
    }
    ws.on_upgrade(move |socket| client(socket, st))
}

async fn client(socket: WebSocket, st: Wiz) {
    let (mut sink, mut stream) = socket.split();
    let (tx, mut rx) = mpsc::unbounded_channel::<String>();
    let writer = tokio::spawn(async move {
        while let Some(m) = rx.recv().await {
            if sink.send(Message::Text(m.into())).await.is_err() {
                break;
            }
        }
    });
    while let Some(Ok(msg)) = stream.next().await {
        let Message::Text(text) = msg else { continue };
        let Ok(req) = serde_json::from_str::<Value>(&text) else { continue };
        let id = req["id"].clone();
        let method = req["method"].as_str().unwrap_or("").to_string();
        let params = req.get("params").cloned().unwrap_or(json!({}));
        let (st2, tx2) = (st.clone(), tx.clone());
        tokio::spawn(async move {
            let out = match handle(&st2, &method, params).await {
                Ok(v) => json!({"id": id, "result": v}),
                Err(e) => json!({"id": id, "error": format!("{e}")}),
            };
            let _ = tx2.send(out.to_string());
        });
    }
    drop(tx);
    let _ = writer.await;
}

fn p_path(p: &Value, k: &str) -> anyhow::Result<PathBuf> {
    let s = p[k].as_str().map(str::trim).filter(|s| !s.is_empty()).ok_or_else(|| anyhow::anyhow!("{k} eksik"))?;
    let path = PathBuf::from(s);
    if !path.is_absolute() {
        anyhow::bail!("Tam bir klasör yolu yazın (ör. {}).", if cfg!(windows) { "D:\\FerIDE" } else { "/home/kullanici/FerIDE" });
    }
    Ok(path)
}

async fn handle(st: &Wiz, method: &str, p: Value) -> anyhow::Result<Value> {
    Ok(match method {
        "installer.info" => {
            let existing = install::find_existing();
            let data_default = existing.as_ref().map(|i| i.data_dir.clone()).unwrap_or_else(install::default_data_dir);
            json!({
                "version": feride_core::VERSION,
                "display_version": feride_core::DISPLAY_VERSION,
                "os": std::env::consts::OS,
                "existing": existing,
                "update": st.update && existing.is_some(),
                "defaults": {
                    "program": existing.as_ref().map(|i| i.install_dir.clone()).unwrap_or_else(install::default_install_dir),
                    "data": data_default,
                },
                "self_dir": portable_dir(),
                "can_pick": cfg!(feature = "desktop"),
                "shortcuts": !cfg!(target_os = "macos"),
                "no_launch": st.no_launch,
            })
        }
        "installer.inspect" => {
            let program = p_path(&p, "program")?;
            let data = p_path(&p, "data")?;
            tokio::task::spawn_blocking(move || inspect(program, data)).await?
        }
        "installer.pick" => pick(&p).await?,
        "installer.install" => {
            let opts = InstallOptions {
                install_dir: p_path(&p, "program")?,
                data_dir: p_path(&p, "data")?,
                desktop_shortcut: p["desktop"].as_bool().unwrap_or(true),
                menu_shortcut: p["menu"].as_bool().unwrap_or(true),
                add_path: p["path"].as_bool().unwrap_or(true),
            };
            let src = current_exe()?;
            let rep = tokio::task::spawn_blocking(move || install::install(&src, &opts, true)).await??;
            st.installed.store(true, Ordering::SeqCst);
            if p["launch"].as_bool().unwrap_or(true) && !st.no_launch {
                *st.launch.lock().unwrap() = Some(rep.exe.clone());
            }
            serde_json::to_value(&rep)?
        }
        "installer.finish" => {
            if !p["launch"].as_bool().unwrap_or(true) {
                st.launch.lock().unwrap().take();
            }
            st.quit.notify_one();
            json!(true)
        }
        other => anyhow::bail!("bilinmeyen yöntem: {other}"),
    })
}

fn inspect(program: PathBuf, data: PathBuf) -> Value {
    let opts = InstallOptions { install_dir: program.clone(), data_dir: data.clone(), desktop_shortcut: false, menu_shortcut: false, add_path: false };
    let error = install::validate(&opts).err().map(|e| e.to_string());
    let space = |p: &Path| install::space_for(p).map(|(free, total)| json!({"free": free, "total": total}));
    let data_found = install::looks_like_data(&data);
    json!({
        "error": error,
        "program_space": space(&program),
        "data_space": space(&data),
        "program_installed": program.join(install::exe_name()).is_file(),
        "data_found": data_found,
        "data_size": if data_found { install::dir_size(&data) } else { 0 },
    })
}

#[cfg(feature = "desktop")]
async fn pick(p: &Value) -> anyhow::Result<Value> {
    let kind = if p["kind"].as_str() == Some("data") { Kind::Data } else { Kind::Program };
    let title = if kind == Kind::Data { "Veri klasörünü seçin (modeller, sohbetler, araçlar)" } else { "FerIDE'nin kurulacağı klasörü seçin" };
    let mut dlg = rfd::AsyncFileDialog::new().set_title(title);
    if let Some(cur) = p["current"].as_str() {
        let mut start = Some(PathBuf::from(cur));
        while let Some(s) = start.clone() {
            if s.is_dir() {
                dlg = dlg.set_directory(&s);
                break;
            }
            start = s.parent().map(Path::to_path_buf);
        }
    }
    Ok(match dlg.pick_folder().await {
        Some(f) => json!(install::normalize_choice(f.path(), kind)),
        None => Value::Null,
    })
}

#[cfg(not(feature = "desktop"))]
async fn pick(_p: &Value) -> anyhow::Result<Value> {
    Ok(Value::Null)
}

// ------------------------------------------------------------------ kaldırma

/// Ayarlar'dan kaldırma: bu süreç kapandıktan sonra kaldırmayı yapacak bağımsız bir süreç başlatır.
pub fn spawn_uninstaller(purge: bool) -> anyhow::Result<()> {
    let exe = current_exe()?;
    let mut c = std::process::Command::new(&exe);
    c.args(["uninstall", "--yes", "--notify", "--wait-pid", &std::process::id().to_string()]);
    if purge {
        c.arg("--purge");
    }
    c.stdin(std::process::Stdio::null()).stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        c.creation_flags(0x0000_0008 | 0x0000_0200); // DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP
    }
    c.spawn()?;
    Ok(())
}

fn wait_for_exit(pid: u32) {
    use sysinfo::{Pid, ProcessRefreshKind, ProcessesToUpdate, System};
    let mut sys = System::new();
    for _ in 0..300 {
        sys.refresh_processes_specifics(ProcessesToUpdate::Some(&[Pid::from_u32(pid)]), true, ProcessRefreshKind::nothing());
        if sys.process(Pid::from_u32(pid)).is_none() {
            return;
        }
        std::thread::sleep(Duration::from_millis(200));
    }
}

#[cfg(feature = "desktop")]
fn gui_dialogs() -> bool {
    use std::io::IsTerminal;
    // Linux'ta terminalden çalıştırıldıysa soru terminalde sorulur.
    !(cfg!(target_os = "linux") && std::io::stdin().is_terminal())
}

fn ask_yes_no(title: &str, text: &str) -> bool {
    #[cfg(feature = "desktop")]
    if gui_dialogs() {
        return rfd::MessageDialog::new()
            .set_title(title)
            .set_description(text)
            .set_level(rfd::MessageLevel::Warning)
            .set_buttons(rfd::MessageButtons::YesNo)
            .show()
            == rfd::MessageDialogResult::Yes;
    }
    eprint!("{title}\n{text}\n[e/H] ");
    let _ = std::io::stderr().flush();
    let mut line = String::new();
    let _ = std::io::stdin().read_line(&mut line);
    matches!(line.trim().to_lowercase().as_str(), "e" | "evet" | "y" | "yes")
}

fn show_info(title: &str, text: &str) {
    #[cfg(feature = "desktop")]
    if gui_dialogs() {
        rfd::MessageDialog::new().set_title(title).set_description(text).set_level(rfd::MessageLevel::Info).show();
        return;
    }
    println!("{title}\n{text}");
}

/// `feride uninstall`
pub fn cli_uninstall(a: UninstallArgs) -> i32 {
    if let Some(pid) = a.wait_pid {
        wait_for_exit(pid);
    }
    let Some(info) = install::running_installed().or_else(install::find_existing) else {
        show_info("FerIDE kurulu değil", "Kaldırılacak bir FerIDE kurulumu bulunamadı. Kurmadan kullandıysanız klasörünü silmeniz yeterli.");
        return 1;
    };
    let purge = if a.yes {
        a.purge
    } else {
        if !ask_yes_no(
            "FerIDE kaldırılsın mı?",
            &format!(
                "FerIDE kapatılıp kaldırılacak.\n\nProgram klasörü:\n{}\n\nVeri klasörü (modeller, sohbetler):\n{}",
                info.install_dir.display(),
                info.data_dir.display()
            ),
        ) {
            return 0;
        }
        install::looks_like_data(&info.data_dir)
            && ask_yes_no(
                "Modeller ve veriler de silinsin mi?",
                &format!(
                    "{}\n{} yer kaplıyor: modeller, sohbetler, indirilen araçlar ve ayarlar.\n\nHayır derseniz yerinde kalır; FerIDE'yi yeniden kurduğunuzda kaldığınız yerden devam eder.",
                    info.data_dir.display(),
                    feride_core::util::human_bytes(install::dir_size(&info.data_dir))
                ),
            )
    };
    let r = install::uninstall(&info, purge, true);
    tracing::info!("kaldırma: {r:?}");
    let mut text = String::from("FerIDE kaldırıldı.");
    if purge && r.removed_data {
        text.push_str(&format!("\nVeri klasörü de silindi: {}", info.data_dir.display()));
    } else if !purge {
        text.push_str(&format!("\nModeller ve sohbetler yerinde duruyor: {}", info.data_dir.display()));
    }
    if !r.leftovers.is_empty() {
        text.push_str("\n\nFerIDE'ye ait olmadığı için silinmeyenler:\n");
        for l in r.leftovers.iter().take(8) {
            text.push_str(&format!("  {l}\n"));
        }
    }
    for w in &r.warnings {
        text.push_str(&format!("\nUyarı: {w}"));
    }
    if !a.yes || a.notify {
        show_info("FerIDE kaldırıldı", &text);
    } else {
        println!("{text}");
    }
    0
}

/// Ayarlar sayfası için kurulum bilgisi.
pub fn running_info() -> Option<InstallInfo> {
    install::running_installed()
}
