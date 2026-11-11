//! FerIDE beta v5.4 — tek çalıştırılabilir dosya.
//!
//! `feride`               masaüstü uygulaması
//! `feride serve`         başsız sunucu (tarayıcıdan bağlanılır)
//! `feride doctor`        bağımlılık ve donanım tanısı
//! `feride setup [id…]`   eksik bağımlılıkları kurar

#![cfg_attr(all(windows, not(debug_assertions)), windows_subsystem = "windows")]

mod rpc;
mod server;
#[cfg(feature = "desktop")]
mod desktop;

use clap::{Parser, Subcommand};
use std::io::Write;
use std::sync::Arc;

use feride_core::paths::Paths;
use feride_core::Core;

#[derive(Parser)]
#[command(name = "feride", version = feride_core::VERSION, about = "FerIDE — yerel yapay zeka geliştirme ortamı")]
struct Cli {
    #[command(subcommand)]
    cmd: Option<Cmd>,
}

#[derive(Subcommand)]
enum Cmd {
    /// Başsız sunucu: arayüze tarayıcıdan bağlanılır.
    Serve {
        #[arg(long, default_value_t = 0)]
        port: u16,
        /// Dinlenecek adres. Varsayılan yalnızca bu bilgisayar (127.0.0.1).
        #[arg(long, default_value = "127.0.0.1")]
        listen: String,
        /// Adresi varsayılan tarayıcıda aç.
        #[arg(long)]
        open: bool,
    },
    /// Bağımlılık ve donanım durumunu yazdırır.
    Doctor,
    /// Eksik bağımlılıkları kurar (kimlik verilmezse yalnızca zorunlular).
    Setup { ids: Vec<String> },
}

fn attach_console() {
    #[cfg(windows)]
    unsafe {
        use windows_sys::Win32::System::Console::{AttachConsole, ATTACH_PARENT_PROCESS};
        AttachConsole(ATTACH_PARENT_PROCESS);
    }
}

fn init_logging(paths: &Paths, to_stderr: bool) -> tracing_appender::non_blocking::WorkerGuard {
    use tracing_subscriber::{fmt, prelude::*, EnvFilter};
    let file = tracing_appender::rolling::daily(paths.logs(), "feride.log");
    let (nb, guard) = tracing_appender::non_blocking(file);
    let filter = EnvFilter::try_from_env("FERIDE_LOG").unwrap_or_else(|_| EnvFilter::new("info,hyper=warn,reqwest=warn"));
    let reg = tracing_subscriber::registry().with(filter).with(fmt::layer().with_writer(nb).with_ansi(false));
    if to_stderr {
        reg.with(fmt::layer().with_writer(std::io::stderr)).init();
    } else {
        reg.init();
    }
    guard
}

/// Tek örnek kilidi: aynı anda iki FerIDE çekirdeği aynı verileri yazmasın.
fn instance_lock(paths: &Paths) -> Option<std::fs::File> {
    let f = std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(paths.run().join("instance.lock"))
        .ok()?;
    match f.try_lock() {
        Ok(()) => Some(f),
        Err(_) => None,
    }
}

fn instance_file(paths: &Paths) -> std::path::PathBuf {
    paths.run().join("instance.json")
}

fn write_instance(paths: &Paths, port: u16, token: &str) {
    let data = serde_json::json!({"port": port, "token": token, "pid": std::process::id()});
    let _ = feride_core::util::write_atomic(&instance_file(paths), data.to_string().as_bytes());
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(instance_file(paths), std::fs::Permissions::from_mode(0o600));
    }
}

fn main() {
    // Alt süreçlerde (llama-server, ses motorları) Windows hata pencereleri açılmasın; hata çıkış koduna dönüşür.
    feride_core::winsec::suppress_error_dialogs();
    let cli = Cli::parse();
    if cli.cmd.is_some() {
        attach_console();
    }
    let paths = Paths::detect();
    let _guard = init_logging(&paths, cli.cmd.is_some());
    std::panic::set_hook(Box::new(|info| {
        tracing::error!("beklenmedik hata: {info}");
        eprintln!("FerIDE beklenmedik bir hatayla karşılaştı: {info}");
    }));
    let rt = tokio::runtime::Builder::new_multi_thread().enable_all().thread_name("feride").build().expect("çalışma zamanı");

    match cli.cmd {
        Some(Cmd::Doctor) => rt.block_on(doctor(paths)),
        Some(Cmd::Setup { ids }) => rt.block_on(setup(paths, ids)),
        Some(Cmd::Serve { port, listen, open }) => {
            let Some(_lock) = instance_lock(&paths) else {
                eprintln!("FerIDE zaten çalışıyor.");
                std::process::exit(1);
            };
            if listen != "127.0.0.1" && listen != "localhost" {
                eprintln!("UYARI: FerIDE {listen} adresinde dinliyor; jetona sahip herkes bu bilgisayarda komut çalıştırabilir.");
            }
            rt.block_on(async move {
                let core = Core::new(paths.clone());
                core.start_background();
                let s = server::start(core.clone(), &listen, port, false).await.expect("sunucu başlatılamadı");
                write_instance(&paths, s.port, &s.token);
                let url = format!("http://127.0.0.1:{}/#token={}", s.port, s.token);
                println!("FerIDE {} hazır: {url}", feride_core::DISPLAY_VERSION);
                let _ = std::io::stdout().flush();
                if open {
                    let _ = open::that_detached(&url);
                }
                tokio::select! {
                    _ = tokio::signal::ctrl_c() => {}
                    _ = s.quit.notified() => {}
                }
                core.shutdown();
                let _ = std::fs::remove_file(instance_file(&paths));
            });
        }
        None => run_desktop(rt, paths),
    }
}

fn run_desktop(rt: tokio::runtime::Runtime, paths: Paths) {
    let lock = instance_lock(&paths);
    if lock.is_none() {
        // Zaten açık bir FerIDE var: ona yeni bir pencere aç.
        if let Ok(b) = std::fs::read(instance_file(&paths)) {
            if let Ok(v) = serde_json::from_slice::<serde_json::Value>(&b) {
                if let (Some(port), Some(token)) = (v["port"].as_u64(), v["token"].as_str()) {
                    let url = format!("http://127.0.0.1:{port}/#token={token}");
                    open_window_or_browser(&paths, url, format!("http://127.0.0.1:{port}"), Arc::new(tokio::sync::Notify::new()), || {});
                }
            }
        }
        return;
    }
    let core = rt.block_on(async {
        let core = Core::new(paths.clone());
        core.start_background();
        core
    });
    let started = rt.block_on(server::start(core.clone(), "127.0.0.1", 0, true)).expect("yerel sunucu başlatılamadı");
    write_instance(&paths, started.port, &started.token);
    let origin = format!("http://127.0.0.1:{}", started.port);
    let url = format!("{origin}/#token={}", started.token);
    tracing::info!("FerIDE {} başladı ({origin})", feride_core::DISPLAY_VERSION);

    let core_exit = core.clone();
    let quit = started.quit.clone();
    let inst = instance_file(&paths);
    // Pencere döngüsü süreci doğrudan sonlandırır; temizlik burada yapılır.
    let used_browser = open_window_or_browser(&paths, url, origin, quit.clone(), move || {
        core_exit.shutdown();
        let _ = std::fs::remove_file(&inst);
    });
    if used_browser {
        // Pencere açılamadı: tarayıcı modunda "Kapat"a basılana kadar çalış.
        rt.block_on(async {
            tokio::select! {
                _ = quit.notified() => {}
                _ = tokio::signal::ctrl_c() => {}
            }
        });
        core.shutdown();
    }
    let _ = std::fs::remove_file(instance_file(&paths));
    drop(lock);
    rt.shutdown_timeout(std::time::Duration::from_secs(2));
    std::process::exit(0);
}

/// Pencereyi açar; açamazsa arayüzü tarayıcıda açar ve `true` döner.
#[allow(unused_variables)]
fn open_window_or_browser(
    paths: &Paths,
    url: String,
    origin: String,
    quit: Arc<tokio::sync::Notify>,
    on_exit: impl FnOnce() + 'static,
) -> bool {
    #[cfg(feature = "desktop")]
    {
        match desktop::run(url.clone(), origin, paths.cache().join("webview"), quit, on_exit) {
            Ok(()) => return false,
            Err(e) => tracing::error!("pencere açılamadı ({e}); arayüz tarayıcıda açılıyor"),
        }
    }
    let _ = open::that_detached(&url);
    true
}

async fn doctor(paths: Paths) {
    let core = Core::new(paths.clone());
    let s = core.settings();
    println!("FerIDE {} ({})", feride_core::DISPLAY_VERSION, feride_core::VERSION);
    println!("Veri klasörü: {}", paths.data.display());
    println!("Kabuk: {}", feride_core::shell::Shell::detect(&paths, &s.agent.shell).display_name());
    if let Some(sac) = feride_core::winsec::smart_app_control() {
        let label = match sac {
            0 => "kapalı",
            1 => "AÇIK — imzasız bileşenler engellenir",
            2 => "değerlendirme (engellemez)",
            _ => "bilinmiyor",
        };
        println!("Akıllı Uygulama Denetimi: {label}");
        if sac == 1 {
            println!("  {}", feride_core::winsec::SAC_HELP);
        }
    }
    println!("\nBağımlılıklar:");
    for d in core.deps.check(&s) {
        println!(
            "  [{}] {:<34} {}{}",
            if d.installed { "✓" } else if d.required { "✗" } else { " " },
            d.name,
            d.version.clone().unwrap_or_default(),
            if d.needs_admin && !d.installed { "  (yönetici gerekir)" } else { "" }
        );
    }
    let server = feride_core::deps::find_llama_server(&paths, &s);
    let hw = feride_core::hardware::probe(&paths, server.as_deref()).await;
    println!("\nDonanım: {}", hw.describe());
    println!("İşlemci: {}", hw.cpu_name);
    let models = feride_core::llama::scan_models(&core.llama.model_dirs(&s));
    println!("\nModeller ({}):", models.len());
    for m in models {
        println!(
            "  {:<60} {:>9}  {}",
            m.name,
            feride_core::util::human_bytes(m.size_bytes),
            if m.mmproj.is_some() { "görsel ✓" } else { "" }
        );
    }
    println!("\nMCP sunucuları:");
    for st in core.mcp.statuses() {
        println!("  {:<12} {:<9} {}", st.name, st.state, st.missing_runtime.unwrap_or_default());
    }
    println!("\nSkill: {}  •  Hafıza kaydı: {}", core.skills().len(), core.memory.as_ref().map(|m| m.count()).unwrap_or(0));
}

async fn setup(paths: Paths, ids: Vec<String>) {
    let core = Core::new(paths);
    let mut rx = core.events.subscribe();
    tokio::spawn(async move {
        while let Ok(ev) = rx.recv().await {
            if ev.topic == "setup.progress" {
                let d = ev.data;
                let (done, total) = (d["done"].as_u64().unwrap_or(0), d["total"].as_u64().unwrap_or(0));
                if let Some(pct) = (done * 100).checked_div(total) {
                    eprint!("\r  {} … %{pct}      ", d["message"].as_str().unwrap_or(""));
                } else {
                    eprintln!("  {}", d["message"].as_str().unwrap_or(""));
                }
            }
        }
    });
    let s = core.settings();
    for (id, r) in core.deps.install_missing(&s, &ids).await {
        match r {
            Ok(m) => println!("\n✓ {id}: {m}"),
            Err(e) => println!("\n✗ {id}: {e}"),
        }
    }
}
