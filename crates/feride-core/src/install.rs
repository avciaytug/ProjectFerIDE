//! Kurulum, güncelleme ve kaldırma.
//!
//! FerIDE iki yerde durur:
//! * **Program klasörü** (`feride.exe` / `feride`, `install.json`, belgeler): kullanıcı seçer.
//! * **Veri klasörü** (modeller, araçlar, ses paketi, sohbetler, ayarlar): kullanıcı seçer; varsayılan `~/.feride`.
//!
//! Program klasöründeki `install.json` veri klasörünü gösterir; FerIDE açılırken bunu okur (bkz. `Paths::detect`).
//! Kaldırırken yalnızca FerIDE'nin kendi dosyaları silinir; kullanıcının klasöre koyduğu başka dosyalara dokunulmaz.

use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::time::Duration;

use crate::paths::{home_dir, normalize};

pub const INSTALL_FILE: &str = "install.json";

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct InstallInfo {
    pub version: String,
    pub install_dir: PathBuf,
    pub data_dir: PathBuf,
    #[serde(default)]
    pub desktop_shortcut: bool,
    #[serde(default)]
    pub menu_shortcut: bool,
    #[serde(default)]
    pub add_path: bool,
    #[serde(default)]
    pub installed_at: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct InstallOptions {
    pub install_dir: PathBuf,
    pub data_dir: PathBuf,
    #[serde(default)]
    pub desktop_shortcut: bool,
    #[serde(default)]
    pub menu_shortcut: bool,
    #[serde(default)]
    pub add_path: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Program,
    Data,
}

pub fn exe_name() -> &'static str {
    if cfg!(windows) {
        "feride.exe"
    } else {
        "feride"
    }
}

/// Uygulama içi güncellemede kenara alınan eski program (çalışan süreç bu dosyadan devam eder).
pub fn old_exe_name() -> &'static str {
    if cfg!(windows) {
        "feride.old.exe"
    } else {
        "feride.old"
    }
}

/// Uygulama içi güncellemede indirilip sınanan, henüz yerine konmamış yeni program.
pub fn new_exe_name() -> &'static str {
    if cfg!(windows) {
        "feride.new.exe"
    } else {
        "feride.new"
    }
}

/// Güncellemeden kalan program dosyası mı (`feride.old*`, `feride.new*`)?
fn is_update_leftover(name: &str) -> bool {
    name.starts_with("feride.old") || name.starts_with("feride.new")
}

/// Program klasöründeki güncelleme artıklarını siler (kullanımdaysa sessizce bırakır).
pub fn cleanup_update_leftovers(dir: &Path) {
    let Ok(rd) = std::fs::read_dir(dir) else { return };
    for e in rd.flatten() {
        if e.path().is_file() && e.file_name().to_str().is_some_and(is_update_leftover) {
            let p = e.path();
            // Yeniden başlatan eski süreç birkaç an önce kapandı; dosya kısa süre kilitli kalabilir.
            for _ in 0..10 {
                if std::fs::remove_file(&p).is_ok() || !p.exists() {
                    break;
                }
                std::thread::sleep(Duration::from_millis(500));
            }
        }
    }
}

/// Uygulama içi güncellemeden sonra yeni sürümün ilk açılışında: eski program dosyaları silinir, `install.json`'daki
/// sürüm ve Windows "Uygulamalar" kaydındaki sürüm yenilenir. Kısayollar ve PATH aynı dosyayı gösterdiği için
/// değişmez.
pub fn after_update() {
    let Some(dir) = current_exe_dir() else { return };
    let Some(mut info) = info_in(&dir) else { return };
    if !same_path(&info.install_dir, &dir) {
        return;
    }
    cleanup_update_leftovers(&dir);
    if info.version == crate::VERSION {
        return;
    }
    tracing::info!("FerIDE {} → {} güncellendi; kurulum kaydı yenileniyor", info.version, crate::VERSION);
    info.version = crate::VERSION.to_string();
    if write_json(&dir.join(INSTALL_FILE), &info).is_err() {
        return;
    }
    // Kullanıcı genelindeki kayıtlara (işaret dosyası, Windows "Uygulamalar") yalnızca kayıtlı kurulum dokunur;
    // başka klasördeki ikinci bir kopya asıl kurulumun kaydını ele geçirmesin.
    if !read_info(&pointer_file()).is_some_and(|p| same_path(&p.install_dir, &dir)) {
        return;
    }
    let _ = write_json(&pointer_file(), &info);
    // Windows "Yüklü uygulamalar" kaydındaki sürüm (doğrudan Windows API'siyle).
    #[cfg(windows)]
    if let Err(e) = crate::winint::write_uninstall_entry(crate::winint::UNINSTALL_KEY, &info, &dir.join(exe_name()), false) {
        tracing::warn!("Windows kaldırma kaydı güncellenemedi: {e}");
    }
}

/// Çalışan programın bulunduğu klasör (Windows'ta `\\?\` öneki olmadan).
pub fn current_exe_dir() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    let exe = dunce::canonicalize(&exe).unwrap_or(exe);
    exe.parent().map(Path::to_path_buf)
}

fn env_dir(var: &str) -> Option<PathBuf> {
    std::env::var_os(var).map(PathBuf::from).filter(|p| p.is_absolute())
}

/// Varsayılan program klasörü (yönetici izni gerektirmez).
pub fn default_install_dir() -> PathBuf {
    let home = home_dir();
    if cfg!(windows) {
        env_dir("LOCALAPPDATA").unwrap_or_else(|| home.join("AppData").join("Local")).join("Programs").join("FerIDE")
    } else if cfg!(target_os = "macos") {
        home.join("Applications").join("FerIDE")
    } else {
        env_dir("XDG_DATA_HOME").unwrap_or_else(|| home.join(".local").join("share")).join("feride")
    }
}

/// Varsayılan veri klasörü (v5.3.8 ile aynı).
pub fn default_data_dir() -> PathBuf {
    home_dir().join(".feride")
}

/// Kurulumu bulmak için kullanıcıya özel sabit konumdaki işaret dosyası (güncellemeler için).
fn pointer_file() -> PathBuf {
    let home = home_dir();
    if cfg!(windows) {
        env_dir("LOCALAPPDATA").unwrap_or_else(|| home.join("AppData").join("Local")).join("FerIDE").join(INSTALL_FILE)
    } else if cfg!(target_os = "macos") {
        home.join("Library").join("Application Support").join("FerIDE").join(INSTALL_FILE)
    } else {
        env_dir("XDG_CONFIG_HOME").unwrap_or_else(|| home.join(".config")).join("feride").join(INSTALL_FILE)
    }
}

fn read_info(file: &Path) -> Option<InstallInfo> {
    serde_json::from_slice(&std::fs::read(file).ok()?).ok()
}

/// Bir program klasöründeki `install.json`.
pub fn info_in(dir: &Path) -> Option<InstallInfo> {
    read_info(&dir.join(INSTALL_FILE))
}

/// `install.json` olmadan, eski kurulum betiğinin varsayılan konumuna kurulmuş FerIDE.
fn legacy_info(dir: PathBuf) -> InstallInfo {
    InstallInfo {
        version: String::new(),
        install_dir: dir,
        data_dir: env_dir("FERIDE_HOME").unwrap_or_else(default_data_dir),
        desktop_shortcut: true,
        menu_shortcut: true,
        add_path: true,
        installed_at: String::new(),
    }
}

/// Bu bilgisayardaki kurulu FerIDE (güncelleme ve kaldırma için).
pub fn find_existing() -> Option<InstallInfo> {
    if let Some(i) = read_info(&pointer_file()) {
        if i.install_dir.join(exe_name()).is_file() {
            return Some(i);
        }
    }
    let d = default_install_dir();
    if d.join(exe_name()).is_file() {
        return Some(info_in(&d).unwrap_or_else(|| legacy_info(d)));
    }
    None
}

/// Çalışan program kurulu bir kopya mı? Eski betikle varsayılan konuma kurulmuşsa da kurulu sayılır.
pub fn running_installed() -> Option<InstallInfo> {
    let dir = current_exe_dir()?;
    if let Some(i) = info_in(&dir) {
        return Some(i);
    }
    same_path(&dir, &default_install_dir()).then(|| legacy_info(dir))
}

/// Veri klasörü: `FERIDE_HOME` > çalışan kopyanın `install.json`'ı > `~/.feride`.
pub fn resolve_data_dir() -> PathBuf {
    env_dir("FERIDE_HOME")
        .or_else(|| current_exe_dir().and_then(|d| info_in(&d)).map(|i| i.data_dir))
        .unwrap_or_else(default_data_dir)
}

/// Yolun gerçek hâli; yol (henüz) yoksa var olan en derin üst klasörü gerçek yoluna çevrilip kalanı eklenir.
/// Böylece macOS'ta /var ↔ /private/var, Windows'ta 8.3 kısa adlar (RUNNER~1) karşılaştırmayı bozmaz.
fn canonical_lenient(p: &Path) -> PathBuf {
    let mut rest = Vec::new();
    let mut cur = p;
    loop {
        if let Ok(c) = dunce::canonicalize(cur) {
            let mut out = c;
            for part in rest.iter().rev() {
                out.push(part);
            }
            return normalize(&out);
        }
        match (cur.parent(), cur.file_name()) {
            (Some(parent), Some(name)) => {
                rest.push(name.to_os_string());
                cur = parent;
            }
            _ => return normalize(p),
        }
    }
}

pub fn same_path(a: &Path, b: &Path) -> bool {
    let a = canonical_lenient(a);
    let b = canonical_lenient(b);
    if cfg!(windows) {
        let f = |p: &Path| p.to_string_lossy().replace('/', "\\").trim_end_matches('\\').to_lowercase();
        f(&a) == f(&b)
    } else {
        a == b
    }
}

/// `child`, `dir` klasörünün içinde mi (kendisi değil)? Windows'ta büyük/küçük harf ayrımı yapılmaz.
pub fn is_inside(child: &Path, dir: &Path) -> bool {
    let c = canonical_lenient(child);
    let d = canonical_lenient(dir);
    if cfg!(windows) {
        let f = |p: &Path| p.to_string_lossy().replace('/', "\\").trim_end_matches('\\').to_lowercase();
        let (c, d) = (f(&c), f(&d));
        c.len() > d.len() + 1 && c.starts_with(&d) && c.as_bytes()[d.len()] == b'\\'
    } else {
        c != d && c.starts_with(&d)
    }
}

/// Mevcut bir FerIDE veri klasörü mü?
pub fn looks_like_data(dir: &Path) -> bool {
    dir.join("config.toml").is_file() || dir.join("state.json").is_file() || (dir.join("models").is_dir() && dir.join("sessions").is_dir())
}

/// Doğrudan kurulum/veri klasörü olarak kullanılması (ve kaldırırken silinmesi) tehlikeli klasörler.
pub fn is_dangerous(p: &Path) -> bool {
    let p = normalize(p);
    if !p.is_absolute() || p.parent().is_none() || p.components().count() <= 1 {
        return true; // sürücü kökü ya da göreli yol
    }
    let home = home_dir();
    let mut bad: Vec<PathBuf> = vec![home.clone()];
    for sub in ["Desktop", "Documents", "Downloads", "Masaüstü", "Belgeler", "İndirilenler", "Pictures", "Music", "Videos", ".local", ".config"] {
        bad.push(home.join(sub));
    }
    bad.push(home.join(".local").join("share"));
    if cfg!(windows) {
        for var in ["SystemRoot", "ProgramFiles", "ProgramFiles(x86)", "ProgramData", "LOCALAPPDATA", "APPDATA", "PUBLIC"] {
            if let Some(d) = env_dir(var) {
                bad.push(d);
            }
        }
        if let Some(l) = env_dir("LOCALAPPDATA") {
            bad.push(l.join("Programs"));
        }
        if let Some(parent) = home.parent() {
            bad.push(parent.to_path_buf()); // C:\Users
        }
    } else {
        for d in ["/usr", "/usr/local", "/bin", "/sbin", "/etc", "/var", "/opt", "/home", "/root", "/tmp", "/mnt", "/media", "/Applications", "/Users", "/System", "/Library"] {
            bad.push(PathBuf::from(d));
        }
        bad.push(home.join("Applications"));
        bad.push(home.join("Library"));
    }
    bad.iter().any(|b| same_path(b, &p))
}

fn dir_is_empty(p: &Path) -> bool {
    std::fs::read_dir(p).map(|mut d| d.next().is_none()).unwrap_or(true)
}

/// Kullanıcının seçtiği klasörü güvenli bir program/veri klasörüne çevirir: sürücü kökü, ev klasörü ya da dolu bir
/// klasör seçildiyse altına "FerIDE" / "FerIDE-Veri" eklenir (kurulum programlarının alışılmış davranışı).
pub fn normalize_choice(picked: &Path, kind: Kind) -> PathBuf {
    let name = picked.file_name().map(|n| n.to_string_lossy().to_lowercase()).unwrap_or_default();
    match kind {
        Kind::Program => {
            if name == "feride" || picked.join(exe_name()).is_file() || picked.join(INSTALL_FILE).is_file() {
                return picked.to_path_buf();
            }
        }
        Kind::Data => {
            if looks_like_data(picked) || [".feride", "feride-veri", "feride-data", "feride"].contains(&name.as_str()) {
                return picked.to_path_buf();
            }
        }
    }
    if is_dangerous(picked) || !dir_is_empty(picked) {
        picked.join(if kind == Kind::Program { "FerIDE" } else { "FerIDE-Veri" })
    } else {
        picked.to_path_buf()
    }
}

fn check_writable(dir: &Path) -> anyhow::Result<()> {
    std::fs::create_dir_all(dir).map_err(|e| anyhow::anyhow!("{} oluşturulamadı: {e}", dir.display()))?;
    let probe = dir.join(format!(".feride-yazma-{}", std::process::id()));
    std::fs::write(&probe, b"ok").map_err(|e| anyhow::anyhow!("{} klasörüne yazılamıyor: {e}", dir.display()))?;
    let _ = std::fs::remove_file(probe);
    Ok(())
}

pub fn validate(opts: &InstallOptions) -> anyhow::Result<()> {
    for (p, what) in [(&opts.install_dir, "Program klasörü"), (&opts.data_dir, "Veri klasörü")] {
        if !p.is_absolute() {
            anyhow::bail!("{what} tam bir yol olmalı: {}", p.display());
        }
        if is_dangerous(p) {
            anyhow::bail!("{what} olarak {} seçilemez (sürücü kökü, ev ya da sistem klasörü). İçinde bir klasör seçin.", p.display());
        }
    }
    Ok(())
}

/// Hedef programı çalıştıran diğer süreçleri kapatır (güncelleme ve kaldırma için). Kapatılan süreç sayısını döner.
/// Uygulama içi güncellemeden sonra henüz yeniden başlatılmamış eski sürüm (`feride.old.exe`) de kapatılır.
pub fn stop_instances(exe: &Path) -> usize {
    let dir = exe.parent().map(Path::to_path_buf);
    stop_matching(|e| {
        same_path(e, exe)
            || (dir.as_deref().is_some_and(|d| e.parent().is_some_and(|p| same_path(p, d)))
                && e.file_name().and_then(|n| n.to_str()).is_some_and(is_update_leftover))
    })
}

/// Programı `matches` koşulunu sağlayan süreçleri (bu süreç hariç) kapatır ve kapanmalarını bekler.
fn stop_matching(matches: impl Fn(&Path) -> bool) -> usize {
    use sysinfo::{ProcessRefreshKind, ProcessesToUpdate, System, UpdateKind};
    let me = std::process::id();
    let find = || {
        let mut sys = System::new();
        sys.refresh_processes_specifics(ProcessesToUpdate::All, true, ProcessRefreshKind::nothing().with_exe(UpdateKind::Always));
        sys
    };
    let sys = find();
    let mut n = 0;
    // Linux'ta sysinfo iş parçacıklarını da ayrı süreç olarak listeler (`thread_kind`). Bu sürecin kendi iş
    // parçacığı "aynı programı çalıştıran başka süreç" sanılıp öldürülürse SIGKILL bütün süreci kapatır; iş
    // parçacıkları atlanır, ana süreci kapatmak zaten hepsini kapatır.
    let target = |pid: &sysinfo::Pid, p: &sysinfo::Process| pid.as_u32() != me && p.thread_kind().is_none() && p.exe().is_some_and(&matches);
    for (pid, p) in sys.processes() {
        if target(pid, p) && p.kill() {
            n += 1;
        }
    }
    if n > 0 {
        for _ in 0..50 {
            std::thread::sleep(Duration::from_millis(100));
            let sys = find();
            if !sys.processes().iter().any(|(pid, p)| target(pid, p)) {
                break;
            }
        }
    }
    n
}

/// Dosyayı kopyalar; Windows'ta virüs tarayıcısı ya da kapanmakta olan süreç dosyayı kısa süre kilitleyebilir.
fn copy_retry(from: &Path, to: &Path) -> anyhow::Result<()> {
    let mut last = None;
    for _ in 0..20 {
        match std::fs::copy(from, to) {
            Ok(_) => return Ok(()),
            Err(e) => last = Some(e),
        }
        std::thread::sleep(Duration::from_millis(300));
    }
    anyhow::bail!("{} kopyalanamadı: {}", to.display(), last.map(|e| e.to_string()).unwrap_or_default())
}

fn write_json(path: &Path, info: &InstallInfo) -> anyhow::Result<()> {
    if let Some(p) = path.parent() {
        std::fs::create_dir_all(p)?;
    }
    crate::util::write_atomic(path, serde_json::to_string_pretty(info)?.as_bytes())
}

#[derive(Debug, Default, Serialize)]
pub struct InstallReport {
    pub exe: PathBuf,
    pub info: Option<InstallInfo>,
    pub warnings: Vec<String>,
}

/// FerIDE'yi kurar ya da günceller: programı kopyalar, `install.json` yazar, kısayolları ve kaldırma kaydını oluşturur.
/// `system`: kullanıcı geneline dokunan işler (kurulum işaret dosyası, Windows "Uygulamalar" kaydı, kısayollar,
/// PATH). Testlerde kapatılır.
pub fn install(src_exe: &Path, opts: &InstallOptions, system: bool) -> anyhow::Result<InstallReport> {
    validate(opts)?;
    cleanup_removed_exes();
    check_writable(&opts.install_dir)?;
    check_writable(&opts.data_dir)?;
    let target = opts.install_dir.join(exe_name());
    if !same_path(src_exe, &target) {
        stop_instances(&target);
        copy_retry(src_exe, &target)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&target, std::fs::Permissions::from_mode(0o755));
        }
        if cfg!(target_os = "macos") {
            let _ = std::process::Command::new("xattr").args(["-d", "com.apple.quarantine"]).arg(&target).output();
        }
        if let Some(src_dir) = src_exe.parent() {
            for f in ["README.md", "CHANGELOG.md"] {
                if src_dir.join(f).is_file() {
                    let _ = std::fs::copy(src_dir.join(f), opts.install_dir.join(f));
                }
            }
        }
    }
    let info = InstallInfo {
        version: crate::VERSION.to_string(),
        install_dir: opts.install_dir.clone(),
        data_dir: opts.data_dir.clone(),
        desktop_shortcut: opts.desktop_shortcut,
        menu_shortcut: opts.menu_shortcut,
        add_path: opts.add_path,
        installed_at: crate::util::now_iso(),
    };
    write_json(&opts.install_dir.join(INSTALL_FILE), &info)?;
    let warnings = if system {
        let _ = write_json(&pointer_file(), &info);
        integrate(&info, &target, true)
    } else {
        vec![]
    };
    for w in &warnings {
        tracing::warn!("kurulum: {w}");
    }
    Ok(InstallReport { exe: target, info: Some(info), warnings })
}

/// Eski betikle kurulmuş FerIDE'yi (install.json yok) kayda geçirir: kaldırma kaydı ve install.json oluşur.
pub fn adopt_legacy(info: &InstallInfo) {
    let exe = info.install_dir.join(exe_name());
    let mut info = info.clone();
    info.version = crate::VERSION.to_string();
    info.installed_at = crate::util::now_iso();
    if write_json(&info.install_dir.join(INSTALL_FILE), &info).is_ok() {
        let _ = write_json(&pointer_file(), &info);
        // Kısayollar ve PATH eski betikte zaten oluşturuldu; yalnızca kaldırma kaydı eklenir.
        let only_register = InstallInfo { desktop_shortcut: false, menu_shortcut: false, add_path: false, ..info };
        let _ = integrate(&only_register, &exe, true);
    }
}

// ------------------------------------------------------------------ işletim sistemiyle bütünleşme

/// Kısayollar, PATH ve (Windows) kaldırma kaydı. Hatalar kurulumu durdurmaz; uyarı olarak döner.
fn integrate(info: &InstallInfo, exe: &Path, register: bool) -> Vec<String> {
    let mut warnings = vec![];
    if !(register || info.menu_shortcut || info.desktop_shortcut || info.add_path) {
        return warnings;
    }
    // Windows: kısayollar, PATH ve "Yüklü uygulamalar" kaydı doğrudan Windows API'siyle (PowerShell çalıştırılmaz).
    #[cfg(windows)]
    {
        use crate::winint;
        let desc = "FerIDE - yerel yapay zeka geliştirme ortamı";
        for (wanted, folder, what) in [
            (info.menu_shortcut, winint::start_menu_programs(), "Başlat menüsü"),
            (info.desktop_shortcut, winint::desktop(), "Masaüstü"),
        ] {
            if !wanted {
                continue;
            }
            let r = folder
                .ok_or_else(|| anyhow::anyhow!("klasör bulunamadı"))
                .and_then(|d| winint::create_shortcut(&d.join("FerIDE.lnk"), exe, &info.install_dir, desc));
            if let Err(e) = r {
                warnings.push(format!("{what} kısayolu oluşturulamadı: {e}"));
            }
        }
        if info.add_path {
            if let Err(e) = winint::user_path_add(&info.install_dir) {
                warnings.push(format!("PATH'e eklenemedi: {e}"));
            }
        }
        if register {
            if let Err(e) = winint::write_uninstall_entry(winint::UNINSTALL_KEY, info, exe, true) {
                warnings.push(format!("\"Yüklü uygulamalar\" kaydı oluşturulamadı: {e}"));
            }
        }
    }
    #[cfg(not(windows))]
    {
        let _ = register;
        if info.menu_shortcut || info.desktop_shortcut {
            if cfg!(target_os = "macos") {
                // macOS'ta uygulama paketi yok; komut satırı ve Spotlight için PATH bağlantısı yeterli.
            } else {
                let entry = desktop_entry(exe);
                if info.menu_shortcut {
                    let p = applications_dir().join("feride.desktop");
                    if let Err(e) = std::fs::create_dir_all(applications_dir()).and_then(|_| std::fs::write(&p, &entry)) {
                        warnings.push(format!("Uygulama menüsü kısayolu oluşturulamadı: {e}"));
                    }
                }
                if info.desktop_shortcut {
                    if let Some(d) = desktop_dir() {
                        let p = d.join("feride.desktop");
                        let r = std::fs::write(&p, &entry).and_then(|_| {
                            use std::os::unix::fs::PermissionsExt;
                            std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o755))
                        });
                        if let Err(e) = r {
                            warnings.push(format!("Masaüstü kısayolu oluşturulamadı: {e}"));
                        }
                    }
                }
            }
        }
        if info.add_path {
            let bin = home_dir().join(".local").join("bin");
            let link = bin.join("feride");
            let _ = std::fs::create_dir_all(&bin);
            let _ = std::fs::remove_file(&link);
            if let Err(e) = std::os::unix::fs::symlink(exe, &link) {
                warnings.push(format!("~/.local/bin/feride bağlantısı oluşturulamadı: {e}"));
            }
        }
    }
    warnings
}

#[cfg(not(windows))]
fn applications_dir() -> PathBuf {
    env_dir("XDG_DATA_HOME").unwrap_or_else(|| home_dir().join(".local").join("share")).join("applications")
}

#[cfg(not(windows))]
fn desktop_dir() -> Option<PathBuf> {
    let out = std::process::Command::new("xdg-user-dir").arg("DESKTOP").output().ok();
    let d = out.map(|o| PathBuf::from(String::from_utf8_lossy(&o.stdout).trim())).filter(|p| p.is_dir() && *p != home_dir());
    d.or_else(|| Some(home_dir().join("Desktop")).filter(|p| p.is_dir()))
}

#[cfg(not(windows))]
fn desktop_entry(exe: &Path) -> String {
    format!(
        "[Desktop Entry]\nType=Application\nName=FerIDE\nComment=Yerel yapay zeka geliştirme ortamı\nExec=\"{exe}\"\n\
         Terminal=false\nCategories=Development;IDE;\nActions=Uninstall;\n\n[Desktop Action Uninstall]\n\
         Name=FerIDE'yi kaldır\nExec=\"{exe}\" uninstall\n",
        exe = exe.display()
    )
}

fn remove_integration(info: &InstallInfo, exe: &Path) -> Vec<String> {
    let mut warnings = vec![];
    #[cfg(windows)]
    {
        use crate::winint;
        // Yalnızca bu FerIDE'yi gösteren kısayollar silinir.
        for folder in [winint::start_menu_programs(), winint::desktop()].into_iter().flatten() {
            let lnk = folder.join("FerIDE.lnk");
            if lnk.is_file() && winint::shortcut_target(&lnk).is_some_and(|t| same_path(&t, exe)) {
                if let Err(e) = std::fs::remove_file(&lnk) {
                    warnings.push(format!("{} silinemedi: {e}", lnk.display()));
                }
            }
        }
        if let Err(e) = winint::user_path_remove(&info.install_dir) {
            warnings.push(format!("PATH'ten çıkarılamadı: {e}"));
        }
        if let Err(e) = winint::remove_uninstall_entry(winint::UNINSTALL_KEY, &info.install_dir) {
            warnings.push(format!("\"Yüklü uygulamalar\" kaydı silinemedi: {e}"));
        }
    }
    #[cfg(not(windows))]
    {
        let _ = info;
        let mentions = |p: &Path| std::fs::read_to_string(p).map(|t| t.contains(&*exe.to_string_lossy())).unwrap_or(false);
        for p in [Some(applications_dir().join("feride.desktop")), desktop_dir().map(|d| d.join("feride.desktop"))].into_iter().flatten() {
            if mentions(&p) {
                let _ = std::fs::remove_file(&p);
            }
        }
        let link = home_dir().join(".local").join("bin").join("feride");
        if std::fs::read_link(&link).is_ok_and(|t| same_path(&t, exe)) {
            let _ = std::fs::remove_file(&link);
        }
    }
    let _ = &mut warnings;
    warnings
}

// ------------------------------------------------------------------ kaldırma

/// Veri klasöründe FerIDE'nin oluşturduğu girdiler (kaldırırken yalnızca bunlar silinir).
const DATA_ENTRIES: &[&str] = &[
    "models", "bin", "tools", "pyenv", "voice", "sessions", "skills", "logs", "cache", "run", "trash", "resources", "aegis",
    // FerIDE'nin tarayıcı profili (oturum çerezleri)
    "browser",
    "config.toml", "config.toml.bozuk", "state.json", "secrets.bin", "mcp_config.json", "memory.db", "memory.db-wal",
    "memory.db-shm", "feride_knowledge.db",
    // Eski (5.3) FerIDE'den kalanlar
    "Chats", "checkpoints", "todos", "venv", "tmp",
];
/// Veri klasöründe program çalıştıran alt klasörler (llama-server, ses motorları, Git Bash, Node...).
const DATA_EXEC_DIRS: &[&str] = &["bin", "tools", "pyenv", "voice", "venv"];
const PROGRAM_ENTRIES: &[&str] = &[INSTALL_FILE, "README.md", "CHANGELOG.md"];

#[derive(Debug, Default, Serialize)]
pub struct UninstallReport {
    pub removed_program: bool,
    pub removed_data: bool,
    /// Silinmeyen (FerIDE'ye ait olmayan) dosyalar ya da silinemeyenler.
    pub leftovers: Vec<String>,
    pub warnings: Vec<String>,
    /// Windows'ta çalışan program kendini silemez; program klasöründen Geçici klasöre taşındı.
    pub self_delete_scheduled: bool,
}

fn remove_entry(p: &Path) -> std::io::Result<()> {
    if p.is_dir() && !p.is_symlink() {
        std::fs::remove_dir_all(p)
    } else {
        std::fs::remove_file(p)
    }
}

fn leftovers_of(dir: &Path) -> Vec<String> {
    std::fs::read_dir(dir).map(|d| d.flatten().map(|e| e.path().display().to_string()).collect()).unwrap_or_default()
}

/// FerIDE'yi kaldırır. `purge`: modeller, sohbetler, araçlar ve ayarlar da silinir. `system`: kısayollar, PATH,
/// kaldırma kaydı ve işaret dosyası da kaldırılır (testlerde kapatılır).
pub fn uninstall(info: &InstallInfo, purge: bool, system: bool) -> UninstallReport {
    let mut r = UninstallReport::default();
    let exe = info.install_dir.join(exe_name());
    stop_instances(&exe);
    if system {
        r.warnings.extend(remove_integration(info, &exe));
    }

    // Veri klasörü (program dosyasından önce: program dosyası kaybolduğunda kaldırma bitmiş olur).
    if purge {
        let d = &info.data_dir;
        if is_dangerous(d) || !looks_like_data(d) {
            r.warnings.push(format!("{} bir FerIDE veri klasörüne benzemiyor; silinmedi.", d.display()));
        } else {
            // Veri klasöründen çalışan motorlar dosyaları kilitler; silmeden önce kapatılır.
            let exec_dirs: Vec<PathBuf> = DATA_EXEC_DIRS.iter().map(|s| d.join(s)).filter(|p| p.is_dir()).collect();
            if !exec_dirs.is_empty() {
                stop_matching(|e| exec_dirs.iter().any(|x| is_inside(e, x)));
            }
            for e in DATA_ENTRIES {
                let p = d.join(e);
                if p.exists() {
                    // Kapanmakta olan süreçler (WebView, motorlar) dosyaları kısa süre kilitli tutabilir.
                    let mut res = remove_entry(&p);
                    for _ in 0..6 {
                        if res.is_ok() || !p.exists() {
                            break;
                        }
                        std::thread::sleep(Duration::from_millis(500));
                        res = remove_entry(&p);
                    }
                    if let Err(err) = res.and_then(|_| if p.exists() { Err(std::io::Error::other("hâlâ var")) } else { Ok(()) }) {
                        r.warnings.push(format!("{} silinemedi: {err}", p.display()));
                    }
                }
            }
            let _ = std::fs::remove_dir(d);
            r.removed_data = !d.exists();
            if d.exists() {
                r.leftovers.extend(leftovers_of(d));
            }
        }
    }

    // Program klasörü. Kaldırıcı, güncellemeden sonra henüz yeniden başlatılmamış eski dosyadan (`feride.old.exe`)
    // da çalışıyor olabilir.
    let me = std::env::current_exe().ok().map(|m| dunce::canonicalize(&m).unwrap_or(m));
    let running_here = me.as_ref().is_some_and(|me| me.parent().is_some_and(|p| same_path(p, &info.install_dir)));
    let self_file = me.clone().filter(|_| running_here).unwrap_or_else(|| exe.clone());
    if is_dangerous(&info.install_dir) {
        r.warnings.push(format!("{} korumalı bir klasör; yalnızca FerIDE dosyaları silindi.", info.install_dir.display()));
    }
    for f in PROGRAM_ENTRIES {
        let _ = std::fs::remove_file(info.install_dir.join(f));
    }
    if running_here && cfg!(windows) {
        if !same_path(&self_file, &exe) {
            let _ = std::fs::remove_file(&exe);
        }
        r.self_delete_scheduled = move_running_exe_away(&self_file);
        if !r.self_delete_scheduled {
            r.warnings.push(format!("{} FerIDE kapandıktan sonra elle silinebilir.", self_file.display()));
        }
    } else {
        let _ = std::fs::remove_file(&exe);
    }
    // Güncelleme artıkları (çalışan kaldırıcının kendisi zamanlanmış silmeyle gider).
    if let Ok(rd) = std::fs::read_dir(&info.install_dir) {
        for e in rd.flatten() {
            if e.file_name().to_str().is_some_and(is_update_leftover) && !same_path(&e.path(), &self_file) {
                let _ = std::fs::remove_file(e.path());
            }
        }
    }
    let _ = std::fs::remove_dir(&info.install_dir); // boşsa
    r.removed_program = !exe.exists() || r.self_delete_scheduled;
    if info.install_dir.exists() && !r.self_delete_scheduled {
        r.leftovers.extend(leftovers_of(&info.install_dir));
    }

    let pointer = pointer_file();
    if system && read_info(&pointer).is_some_and(|p| same_path(&p.install_dir, &info.install_dir)) {
        let _ = std::fs::remove_file(&pointer);
        if let Some(parent) = pointer.parent() {
            let _ = std::fs::remove_dir(parent);
        }
    }
    r
}

/// Kaldırıcının Geçici klasördeki kopyasının (ve oraya taşınan programın) adı: `feride-kaldirici-<zaman>.exe`.
const REMOVED_EXE_PREFIX: &str = "feride-kaldirici-";

/// Geçici klasörde yeni bir kaldırıcı kopyası için yol. Kaldırıcı bu kopyadan çalışınca program klasöründeki dosya
/// serbest kalır ve doğrudan silinir (çalışan program kendi dosyasını silemez).
pub fn uninstaller_copy_path() -> PathBuf {
    let stamp = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis()).unwrap_or(0);
    std::env::temp_dir().join(format!("{REMOVED_EXE_PREFIX}{stamp}{}", if cfg!(windows) { ".exe" } else { "" }))
}

/// Windows yedek yolu (kaldırıcı Geçici klasörden başlatılamadıysa): çalışan program kendini silemez ama aynı sürücüde
/// yeniden adlandırılabilir; Geçici klasöre taşınır ve program klasörü boşalır. Geçici klasör başka bir sürücüdeyse
/// taşıma olmaz; dosya yerinde kalır ve kullanıcıya söylenir.
#[cfg(windows)]
fn move_running_exe_away(exe: &Path) -> bool {
    let dest = uninstaller_copy_path();
    for _ in 0..10 {
        if std::fs::rename(exe, &dest).is_ok() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(300));
    }
    false
}

/// Önceki kaldırmalardan Geçici klasörde kalan program dosyalarını siler (çalışmıyorlarsa).
fn cleanup_removed_exes() {
    let Ok(rd) = std::fs::read_dir(std::env::temp_dir()) else { return };
    for e in rd.flatten() {
        let name = e.file_name().to_string_lossy().to_string();
        if name.starts_with(REMOVED_EXE_PREFIX) && name.ends_with(".exe") {
            let _ = std::fs::remove_file(e.path());
        }
    }
}

#[cfg(not(windows))]
fn move_running_exe_away(_exe: &Path) -> bool {
    false
}

// ------------------------------------------------------------------ yardımcılar

/// Klasörün kapladığı alan (bayt); bağlantılar izlenmez.
pub fn dir_size(p: &Path) -> u64 {
    let mut total = 0;
    let mut stack = vec![p.to_path_buf()];
    while let Some(d) = stack.pop() {
        let Ok(rd) = std::fs::read_dir(&d) else { continue };
        for e in rd.flatten() {
            let Ok(ft) = e.file_type() else { continue };
            if ft.is_dir() {
                stack.push(e.path());
            } else if ft.is_file() {
                total += e.metadata().map(|m| m.len()).unwrap_or(0);
            }
        }
    }
    total
}

/// Yolun bulunduğu sürücüdeki boş ve toplam alan (henüz var olmayan yol için en yakın mevcut üst klasöre bakılır).
pub fn space_for(p: &Path) -> Option<(u64, u64)> {
    let mut cur = Some(p);
    let existing = loop {
        let c = cur?;
        if c.exists() {
            break dunce::canonicalize(c).ok()?;
        }
        cur = c.parent();
    };
    let disks = sysinfo::Disks::new_with_refreshed_list();
    disks
        .list()
        .iter()
        .filter(|d| {
            if cfg!(windows) {
                existing.to_string_lossy().to_lowercase().starts_with(&d.mount_point().to_string_lossy().to_lowercase())
            } else {
                existing.starts_with(d.mount_point())
            }
        })
        .max_by_key(|d| d.mount_point().as_os_str().len())
        .map(|d| (d.available_space(), d.total_space()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("feride-install-test-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    /// Kaldırırken çalışan program dosyası Geçici klasöre taşınır (arka planda kendini silen bir süreç başlatılmaz);
    /// sonraki kurulum oradaki artıkları temizler.
    #[cfg(windows)]
    #[test]
    fn running_exe_moves_to_temp() {
        let dir = tmp("tasima");
        let exe = dir.join(exe_name());
        std::fs::write(&exe, b"MZ deneme").unwrap();
        assert!(move_running_exe_away(&exe));
        assert!(!exe.exists());
        let moved: Vec<PathBuf> = std::fs::read_dir(std::env::temp_dir())
            .unwrap()
            .flatten()
            .map(|e| e.path())
            .filter(|p| p.file_name().is_some_and(|n| n.to_string_lossy().starts_with(REMOVED_EXE_PREFIX)))
            .collect();
        assert!(moved.iter().any(|p| std::fs::read(p).is_ok_and(|b| b == b"MZ deneme")));
        cleanup_removed_exes();
        assert!(moved.iter().all(|p| !p.exists()));
        assert!(std::fs::remove_dir(&dir).is_ok(), "program klasörü boşalmalı");
    }

    /// Kaldırma kaydı PowerShell'siz yazılır. Gerçek kayda değil, test için açılan ayrı bir anahtara yazar ve siler.
    #[cfg(windows)]
    #[test]
    fn uninstall_entry_native() {
        use windows_sys::Win32::System::Registry::{RegDeleteTreeW, RegGetValueW, HKEY_CURRENT_USER, RRF_RT_REG_SZ};
        let wide = |s: &str| -> Vec<u16> { s.encode_utf16().chain(std::iter::once(0)).collect() };
        let key = format!(r"Software\FerIDE-test-uninstall-{}", std::process::id());
        let dir = tmp("reg");
        let exe = dir.join(exe_name());
        std::fs::write(&exe, vec![0u8; 4096]).unwrap();
        let info = InstallInfo {
            version: "5.4.0-beta.99".into(),
            install_dir: dir.clone(),
            data_dir: dir.clone(),
            desktop_shortcut: false,
            menu_shortcut: false,
            add_path: false,
            installed_at: String::new(),
        };
        crate::winint::write_uninstall_entry(&key, &info, &exe, true).unwrap();
        let read = |name: &str| -> String {
            let mut buf = [0u16; 512];
            let mut size = (buf.len() * 2) as u32;
            let (k, n) = (wide(&key), wide(name));
            // SAFETY: arabellek ve boyutu birlikte verilir; yalnızca okuma.
            let rc = unsafe {
                RegGetValueW(HKEY_CURRENT_USER, k.as_ptr(), n.as_ptr(), RRF_RT_REG_SZ, std::ptr::null_mut(), buf.as_mut_ptr().cast(), &mut size)
            };
            assert_eq!(rc, 0, "{name} okunamadı");
            String::from_utf16_lossy(&buf[..(size as usize / 2).saturating_sub(1)])
        };
        assert_eq!(read("DisplayVersion"), "5.4.0-beta.99");
        assert!(read("QuietUninstallString").ends_with("\" uninstall --yes"));
        // İkinci yazım (sonraki güncelleme) sürümü değiştirir.
        crate::winint::write_uninstall_entry(&key, &InstallInfo { version: "5.4.0-beta.100".into(), ..info }, &exe, false).unwrap();
        assert_eq!(read("DisplayVersion"), "5.4.0-beta.100");
        let k = wide(&key);
        // SAFETY: yalnızca bu testin oluşturduğu anahtar silinir.
        unsafe { RegDeleteTreeW(HKEY_CURRENT_USER, k.as_ptr()) };
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn dangerous_and_choice() {
        let home = home_dir();
        assert!(is_dangerous(&home));
        assert!(is_dangerous(Path::new(if cfg!(windows) { "C:\\" } else { "/" })));
        assert!(!is_dangerous(&home.join("FerIDE-test-x")));
        // Kök ya da ev klasörü seçilirse altına klasör eklenir.
        let root = PathBuf::from(if cfg!(windows) { "D:\\" } else { "/" });
        assert_eq!(normalize_choice(&root, Kind::Program), root.join("FerIDE"));
        assert_eq!(normalize_choice(&home, Kind::Data), home.join("FerIDE-Veri"));
        // Boş klasör olduğu gibi; dolu klasörün altına eklenir.
        let t = tmp("choice");
        let empty = t.join("bos");
        std::fs::create_dir_all(&empty).unwrap();
        assert_eq!(normalize_choice(&empty, Kind::Program), empty);
        std::fs::write(t.join("x.txt"), b"x").unwrap();
        assert_eq!(normalize_choice(&t, Kind::Data), t.join("FerIDE-Veri"));
        let _ = std::fs::remove_dir_all(&t);
    }

    #[test]
    fn inside_dir() {
        let t = tmp("inside");
        let bin = t.join("bin");
        std::fs::create_dir_all(bin.join("llama")).unwrap();
        assert!(is_inside(&bin.join("llama").join("llama-server.exe"), &bin));
        assert!(!is_inside(&bin, &bin));
        assert!(!is_inside(&t.join("bin2").join("x"), &bin)); // ön ek benzerliği yetmez
        assert!(!is_inside(&t, &bin));
        if cfg!(windows) {
            let upper = PathBuf::from(bin.to_string_lossy().to_uppercase());
            assert!(is_inside(&upper.join("x.exe"), &bin));
        }
        let _ = std::fs::remove_dir_all(&t);
    }

    #[test]
    fn install_update_uninstall_roundtrip() {
        let t = tmp("roundtrip");
        let src_dir = t.join("indirilen");
        std::fs::create_dir_all(&src_dir).unwrap();
        let src = src_dir.join(exe_name());
        std::fs::write(&src, b"sahte program").unwrap();
        std::fs::write(src_dir.join("README.md"), b"okubeni").unwrap();
        let opts = InstallOptions {
            install_dir: t.join("Program").join("FerIDE"),
            data_dir: t.join("Veri").join("FerIDE-Veri"),
            desktop_shortcut: false,
            menu_shortcut: false,
            add_path: false,
        };
        let rep = install(&src, &opts, false).unwrap();
        assert!(rep.exe.is_file());
        assert!(opts.install_dir.join("README.md").is_file());
        let info = info_in(&opts.install_dir).unwrap();
        assert_eq!(info.data_dir, opts.data_dir);
        // Güncelleme: aynı yere yeniden kurulum.
        std::fs::write(&src, b"yeni program").unwrap();
        install(&src, &opts, false).unwrap();
        assert_eq!(std::fs::read(&rep.exe).unwrap(), b"yeni program");
        // Veri klasörüne FerIDE verisi ve kullanıcıya ait bir dosya.
        std::fs::create_dir_all(opts.data_dir.join("models")).unwrap();
        std::fs::write(opts.data_dir.join("models").join("m.gguf"), b"model").unwrap();
        std::fs::write(opts.data_dir.join("config.toml"), b"theme='dark'").unwrap();
        std::fs::write(opts.data_dir.join("benim-notum.txt"), b"kullanici").unwrap();
        // Programı kaldır, verileri koru.
        let r = uninstall(&info, false, false);
        assert!(r.removed_program, "{r:?}");
        assert!(!opts.install_dir.exists());
        assert!(opts.data_dir.join("models").join("m.gguf").is_file());
        // Yeniden kur ve verilerle birlikte kaldır: kullanıcının dosyası kalmalı.
        install(&src, &opts, false).unwrap();
        let r = uninstall(&info_in(&opts.install_dir).unwrap(), true, false);
        assert!(!opts.data_dir.join("models").exists());
        assert!(!opts.data_dir.join("config.toml").exists());
        assert!(opts.data_dir.join("benim-notum.txt").is_file());
        assert!(!r.removed_data && r.leftovers.iter().any(|l| l.contains("benim-notum")));
        let _ = std::fs::remove_dir_all(&t);
    }

    #[test]
    fn refuses_dangerous_targets() {
        let opts = InstallOptions {
            install_dir: home_dir(),
            data_dir: home_dir().join(".feride"),
            desktop_shortcut: false,
            menu_shortcut: false,
            add_path: false,
        };
        assert!(validate(&opts).is_err());
    }
}
