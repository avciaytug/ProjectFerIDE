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
pub fn stop_instances(exe: &Path) -> usize {
    stop_matching(|e| same_path(e, exe))
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

/// Betiği `-EncodedCommand` ile çalıştıracak PowerShell komutu (yollar ortam değişkenleriyle geçer; tırnak sorunu olmaz).
#[cfg(windows)]
fn powershell_cmd(script: &str, env: &[(&str, String)]) -> std::process::Command {
    use base64::Engine;
    use std::os::windows::process::CommandExt;
    let utf16: Vec<u8> = script.encode_utf16().flat_map(|u| u.to_le_bytes()).collect();
    let encoded = base64::engine::general_purpose::STANDARD.encode(utf16);
    let mut cmd = std::process::Command::new("powershell.exe");
    cmd.args(["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand", &encoded]);
    for (k, v) in env {
        cmd.env(k, v);
    }
    cmd.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
    cmd
}

#[cfg(windows)]
fn powershell(script: &str, env: &[(&str, String)]) -> anyhow::Result<()> {
    let out = powershell_cmd(script, env).output()?;
    if !out.status.success() {
        anyhow::bail!("{}", String::from_utf8_lossy(&out.stderr).trim());
    }
    Ok(())
}

/// Kullanıcı PATH'i ham hâliyle okunur/yazılır: %DEĞİŞKEN% girdileri genişletilmez, değer türü (REG_EXPAND_SZ)
/// korunur, boş girdiler dahil başka hiçbir girdiye dokunulmaz. Yazdıktan sonra açık uygulamalara duyurulur.
#[cfg(windows)]
const WIN_PATH_FNS: &str = r#"
function Get-UserPath {
  $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
  $kind = [Microsoft.Win32.RegistryValueKind]::ExpandString
  $v = ''
  if ($k) {
    if ($k.GetValueNames() -contains 'Path') { $kind = $k.GetValueKind('Path'); $v = [string]$k.GetValue('Path', '', 'DoNotExpandEnvironmentNames') }
    $k.Close()
  }
  @{ Value = $v; Kind = $kind }
}
function Set-UserPath([string]$value, $kind) {
  $k = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')
  $k.SetValue('Path', $value, $kind); $k.Close()
  [Environment]::SetEnvironmentVariable('FERIDE_PATH_REFRESH', '1', 'User')
  [Environment]::SetEnvironmentVariable('FERIDE_PATH_REFRESH', $null, 'User')
}
function Test-OurDir([string]$entry) {
  $entry -and ([Environment]::ExpandEnvironmentVariables($entry).TrimEnd('\') -ieq $env:FI_DIR.TrimEnd('\'))
}
"#;

#[cfg(windows)]
const WIN_INTEGRATE: &str = r#"
$ErrorActionPreference = 'Stop'
$exe = $env:FI_EXE; $dir = $env:FI_DIR
$sh = New-Object -ComObject WScript.Shell
function Lnk([string]$path) {
  $l = $sh.CreateShortcut($path); $l.TargetPath = $exe; $l.WorkingDirectory = $dir
  $l.IconLocation = "$exe,0"; $l.Description = $env:FI_DESC; $l.Save()
}
if ($env:FI_MENU -eq '1') { Lnk (Join-Path ([Environment]::GetFolderPath('Programs')) 'FerIDE.lnk') }
if ($env:FI_DESKTOP -eq '1') { Lnk (Join-Path ([Environment]::GetFolderPath('Desktop')) 'FerIDE.lnk') }
if ($env:FI_PATH -eq '1') {
  $p = Get-UserPath
  if (-not (($p.Value -split ';') | Where-Object { Test-OurDir $_ })) {
    $new = if ($p.Value -and -not $p.Value.EndsWith(';')) { "$($p.Value);$dir" } else { "$($p.Value)$dir" }
    Set-UserPath $new $p.Kind
  }
}
if ($env:FI_REG -eq '1') {
  $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\FerIDE'
  New-Item -Path $k -Force | Out-Null
  $v = @{ DisplayName = 'FerIDE'; DisplayVersion = $env:FI_VER; Publisher = 'ProjectFerIDE'; DisplayIcon = "$exe,0";
          InstallLocation = $dir; UninstallString = "`"$exe`" uninstall"; QuietUninstallString = "`"$exe`" uninstall --yes";
          URLInfoAbout = 'https://github.com/avciaytug/ProjectFerIDE'; InstallDate = (Get-Date -Format 'yyyyMMdd') }
  foreach ($n in $v.Keys) { Set-ItemProperty -Path $k -Name $n -Value $v[$n] }
  foreach ($n in @('NoModify', 'NoRepair')) { New-ItemProperty -Path $k -Name $n -Value 1 -PropertyType DWord -Force | Out-Null }
  New-ItemProperty -Path $k -Name 'EstimatedSize' -Value ([int]$env:FI_SIZE_KB) -PropertyType DWord -Force | Out-Null
}
"#;

#[cfg(windows)]
const WIN_REMOVE: &str = r#"
$exe = $env:FI_EXE; $dir = $env:FI_DIR
$sh = New-Object -ComObject WScript.Shell
foreach ($p in @((Join-Path ([Environment]::GetFolderPath('Programs')) 'FerIDE.lnk'), (Join-Path ([Environment]::GetFolderPath('Desktop')) 'FerIDE.lnk'))) {
  if (Test-Path $p) { $t = $sh.CreateShortcut($p).TargetPath; if ($t -and ($t -ieq $exe)) { Remove-Item $p -Force } }
}
$p = Get-UserPath
if ($p.Value) {
  $parts = @($p.Value -split ';')
  $keep = @($parts | Where-Object { -not (Test-OurDir $_) })
  if ($keep.Count -ne $parts.Count) { Set-UserPath ($keep -join ';') $p.Kind }
}
$k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\FerIDE'
if (Test-Path $k) {
  $loc = (Get-ItemProperty $k).InstallLocation
  if (-not $loc -or ($loc.TrimEnd('\') -ieq $dir.TrimEnd('\'))) { Remove-Item $k -Recurse -Force }
}
"#;

/// Kısayollar, PATH ve (Windows) kaldırma kaydı. Hatalar kurulumu durdurmaz; uyarı olarak döner.
fn integrate(info: &InstallInfo, exe: &Path, register: bool) -> Vec<String> {
    let mut warnings = vec![];
    if !(register || info.menu_shortcut || info.desktop_shortcut || info.add_path) {
        return warnings;
    }
    #[cfg(windows)]
    {
        let size_kb = std::fs::metadata(exe).map(|m| m.len() / 1024).unwrap_or(0);
        let flag = |b: bool| if b { "1".to_string() } else { "0".to_string() };
        let env = [
            ("FI_EXE", exe.to_string_lossy().to_string()),
            ("FI_DIR", info.install_dir.to_string_lossy().to_string()),
            ("FI_VER", info.version.clone()),
            ("FI_DESC", "FerIDE - yerel yapay zeka geliştirme ortamı".to_string()),
            ("FI_MENU", flag(info.menu_shortcut)),
            ("FI_DESKTOP", flag(info.desktop_shortcut)),
            ("FI_PATH", flag(info.add_path)),
            ("FI_REG", flag(register)),
            ("FI_SIZE_KB", size_kb.to_string()),
        ];
        if let Err(e) = powershell(&format!("{WIN_PATH_FNS}\n{WIN_INTEGRATE}"), &env) {
            warnings.push(format!("Kısayollar/kayıt oluşturulamadı: {e}"));
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
        let env = [("FI_EXE", exe.to_string_lossy().to_string()), ("FI_DIR", info.install_dir.to_string_lossy().to_string())];
        if let Err(e) = powershell(&format!("{WIN_PATH_FNS}\n{WIN_REMOVE}"), &env) {
            warnings.push(format!("Kısayollar/kayıt kaldırılamadı: {e}"));
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
    /// Windows'ta çalışan program kendini silemez; çıkıştan sonra silinmesi için zamanlandı.
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

    // Program klasörü
    let running_here = std::env::current_exe().ok().is_some_and(|me| same_path(&me, &exe));
    if is_dangerous(&info.install_dir) {
        r.warnings.push(format!("{} korumalı bir klasör; yalnızca FerIDE dosyaları silindi.", info.install_dir.display()));
    }
    for f in PROGRAM_ENTRIES {
        let _ = std::fs::remove_file(info.install_dir.join(f));
    }
    if running_here && cfg!(windows) {
        r.self_delete_scheduled = schedule_self_delete(&exe, &info.install_dir);
    } else {
        let _ = std::fs::remove_file(&exe);
    }
    let _ = std::fs::remove_dir(&info.install_dir); // boşsa
    r.removed_program = !exe.exists() || r.self_delete_scheduled;
    if info.install_dir.exists() && !r.self_delete_scheduled {
        r.leftovers.extend(leftovers_of(&info.install_dir));
    }

    // Veri klasörü
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
    let pointer = pointer_file();
    if system && read_info(&pointer).is_some_and(|p| same_path(&p.install_dir, &info.install_dir)) {
        let _ = std::fs::remove_file(&pointer);
        if let Some(parent) = pointer.parent() {
            let _ = std::fs::remove_dir(parent);
        }
    }
    r
}

/// Kaldırıcı kapandıktan sonra programı ve (boşsa) klasörünü siler. Kaldırıcının son penceresi ne kadar açık
/// kalırsa kalsın süreç bitene kadar bekler.
#[cfg(windows)]
const WIN_SELF_DELETE: &str = r#"
$ErrorActionPreference = 'SilentlyContinue'
Wait-Process -Id ([int]$env:FI_PID) -Timeout 1800
for ($i = 0; $i -lt 40 -and (Test-Path -LiteralPath $env:FI_EXE); $i++) {
  Remove-Item -LiteralPath $env:FI_EXE -Force
  if (Test-Path -LiteralPath $env:FI_EXE) { Start-Sleep -Milliseconds 500 }
}
if ((Test-Path -LiteralPath $env:FI_DIR) -and -not (Get-ChildItem -LiteralPath $env:FI_DIR -Force | Select-Object -First 1)) {
  Remove-Item -LiteralPath $env:FI_DIR -Force
}
"#;

/// Windows: çalışan program kendini silemez. Bu süreç kapandıktan sonra programı ve boş klasörü silen bağımsız
/// bir süreç başlatır.
#[cfg(windows)]
fn schedule_self_delete(exe: &Path, dir: &Path) -> bool {
    use std::os::windows::process::CommandExt;
    let env = [
        ("FI_PID", std::process::id().to_string()),
        ("FI_EXE", exe.to_string_lossy().to_string()),
        ("FI_DIR", dir.to_string_lossy().to_string()),
    ];
    let spawn = |breakaway: bool| {
        let mut cmd = powershell_cmd(WIN_SELF_DELETE, &env);
        cmd.stdin(std::process::Stdio::null()).stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null());
        // CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP (+ CREATE_BREAKAWAY_FROM_JOB: başlatan iş nesnesi kapanınca ölmesin)
        cmd.creation_flags(0x0800_0000 | 0x0000_0200 | if breakaway { 0x0100_0000 } else { 0 });
        cmd.spawn()
    };
    // İş nesnesi ayrılmaya izin vermiyorsa CreateProcess reddeder; o zaman ayrılmadan başlatılır.
    spawn(true).or_else(|_| spawn(false)).is_ok()
}

#[cfg(not(windows))]
fn schedule_self_delete(_exe: &Path, _dir: &Path) -> bool {
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
