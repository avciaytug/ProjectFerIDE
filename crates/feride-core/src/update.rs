//! Uygulama içi güncelleme.
//!
//! FerIDE GitHub'daki sürümleri denetler, bu platformun paketini indirip SHA-256 ile doğrular, içindeki programı
//! çalıştırıp sürümünü sınar ve program klasöründeki `feride.exe`'nin yerine koyar. Windows çalışan bir programın
//! silinmesine izin vermez ama yeniden adlandırılmasına izin verir: çalışan süreç eski dosyadan (`feride.old.exe`)
//! çalışmaya devam eder, yeni sürüm FerIDE yeniden başlatılınca devreye girer. Linux ve macOS'ta da aynı yöntem
//! çalışır. Eski dosya bir sonraki açılışta silinir.
//!
//! Sürümler GitHub'ın listeleme sırasına göre değil sürüm numarasına göre karşılaştırılır (liste "beta.9"u
//! "beta.10"un önüne koyabiliyor). Yalnızca kurulu kopyalar güncellenir; geliştirme ve taşınabilir kopyalara
//! dokunulmaz.

use serde::{Deserialize, Serialize};
use std::cmp::Ordering;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::Duration;

use crate::events::EventBus;
use crate::install;
use crate::paths::Paths;

pub const REPO: &str = "avciaytug/ProjectFerIDE";
/// İlk denetim açılıştan bu kadar sonra yapılır (açılışı yavaşlatmasın).
pub const FIRST_CHECK: Duration = Duration::from_secs(60);
/// Sonraki denetimlerin aralığı.
pub const INTERVAL: Duration = Duration::from_secs(6 * 3600);

// ------------------------------------------------------------------ sürüm karşılaştırma

#[derive(Debug, Clone, PartialEq, Eq)]
enum Ident {
    Num(u64),
    Text(String),
}

/// Anlamsal sürüm (`5.4.0-beta.13`); önek `v` ve derleme eki (`+…`) yok sayılır.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Version {
    core: [u64; 3],
    pre: Vec<Ident>,
}

impl Version {
    pub fn parse(s: &str) -> Option<Version> {
        let s = s.trim().trim_start_matches(['v', 'V']);
        let s = s.split('+').next()?;
        let (core, pre) = match s.split_once('-') {
            Some((c, p)) => (c, Some(p)),
            None => (s, None),
        };
        let mut nums = core.split('.').map(|x| x.parse::<u64>().ok());
        let major = nums.next()??;
        let minor = nums.next().unwrap_or(Some(0))?;
        let patch = nums.next().unwrap_or(Some(0))?;
        if nums.next().is_some() {
            return None;
        }
        let pre = match pre {
            None => vec![],
            Some(p) if p.is_empty() || p.split('.').any(str::is_empty) => return None,
            Some(p) => p
                .split('.')
                .map(|x| match x.parse::<u64>() {
                    Ok(n) => Ident::Num(n),
                    Err(_) => Ident::Text(x.to_string()),
                })
                .collect(),
        };
        Some(Version { core: [major, minor, patch], pre })
    }
}

impl Ord for Version {
    fn cmp(&self, o: &Self) -> Ordering {
        self.core.cmp(&o.core).then_with(|| match (self.pre.is_empty(), o.pre.is_empty()) {
            (true, true) => Ordering::Equal,
            // 5.4.0 > 5.4.0-beta.13
            (true, false) => Ordering::Greater,
            (false, true) => Ordering::Less,
            (false, false) => {
                for (x, y) in self.pre.iter().zip(&o.pre) {
                    let c = match (x, y) {
                        (Ident::Num(a), Ident::Num(b)) => a.cmp(b),
                        (Ident::Num(_), Ident::Text(_)) => Ordering::Less,
                        (Ident::Text(_), Ident::Num(_)) => Ordering::Greater,
                        (Ident::Text(a), Ident::Text(b)) => a.cmp(b),
                    };
                    if c != Ordering::Equal {
                        return c;
                    }
                }
                self.pre.len().cmp(&o.pre.len())
            }
        })
    }
}

impl PartialOrd for Version {
    fn partial_cmp(&self, o: &Self) -> Option<Ordering> {
        Some(self.cmp(o))
    }
}

/// `a` sürümü `b`'den yeni mi? Okunamayan sürümler yeni sayılmaz.
pub fn is_newer(a: &str, b: &str) -> bool {
    match (Version::parse(a), Version::parse(b)) {
        (Some(a), Some(b)) => a > b,
        _ => false,
    }
}

// ------------------------------------------------------------------ GitHub sürümleri

#[derive(Debug, Clone, Deserialize)]
pub struct GhAsset {
    pub name: String,
    pub browser_download_url: String,
    #[serde(default)]
    pub size: u64,
}

#[derive(Debug, Clone, Deserialize)]
pub struct GhRelease {
    pub tag_name: String,
    #[serde(default)]
    pub draft: bool,
    #[serde(default)]
    pub html_url: String,
    #[serde(default)]
    pub body: Option<String>,
    #[serde(default)]
    pub assets: Vec<GhAsset>,
}

/// Kurulabilecek bir sürüm.
#[derive(Debug, Clone, Serialize)]
pub struct Candidate {
    pub version: String,
    pub tag: String,
    pub asset_name: String,
    pub asset_url: String,
    pub sha_url: String,
    pub size: u64,
    pub page_url: String,
    pub notes: String,
}

/// Bu platformun paketi (`install.ps1` / `install.sh` ile aynı adlar). ARM64 Windows x64 paketini kullanır.
pub fn asset_name() -> Option<&'static str> {
    match (std::env::consts::OS, std::env::consts::ARCH) {
        ("windows", _) => Some("feride-windows-x64.zip"),
        ("linux", "x86_64") => Some("feride-linux-x64.tar.gz"),
        ("macos", "aarch64") => Some("feride-macos-arm64.tar.gz"),
        _ => None,
    }
}

/// Sürüm sayfası notunun bu sürüme ait kısmı: `scripts/release-notes.sh` önce genel kurulum talimatını, sonra
/// "## Bu sürümde: …" bölümünü yazar; uygulama içinde yalnızca ikincisi gösterilir.
fn version_notes(body: &str) -> String {
    let b = body.trim();
    match b.find("## Bu sürümde") {
        Some(i) => b[i..].trim().to_string(),
        None => b.to_string(),
    }
}

/// Taslak olmayan, bu platformun paketi ve sağlama toplamı bulunan en yüksek sürüm.
pub fn pick(releases: &[GhRelease], asset: &str) -> Option<Candidate> {
    let sha_name = format!("{asset}.sha256");
    releases
        .iter()
        .filter(|r| !r.draft)
        .filter_map(|r| {
            let v = Version::parse(&r.tag_name)?;
            let a = r.assets.iter().find(|a| a.name == asset)?;
            let sha = r.assets.iter().find(|x| x.name == sha_name)?;
            Some((
                v,
                Candidate {
                    version: r.tag_name.trim_start_matches(['v', 'V']).to_string(),
                    tag: r.tag_name.clone(),
                    asset_name: a.name.clone(),
                    asset_url: a.browser_download_url.clone(),
                    sha_url: sha.browser_download_url.clone(),
                    size: a.size,
                    page_url: r.html_url.clone(),
                    notes: version_notes(r.body.as_deref().unwrap_or_default()),
                },
            ))
        })
        .max_by(|a, b| a.0.cmp(&b.0))
        .map(|x| x.1)
}

/// Çalışan sürüm. `FERIDE_UPDATE_PRETEND_VERSION` testte daha eski bir sürümmüş gibi davranmak içindir.
pub fn current_version() -> String {
    std::env::var("FERIDE_UPDATE_PRETEND_VERSION").ok().filter(|v| Version::parse(v).is_some()).unwrap_or_else(|| crate::VERSION.to_string())
}

/// Kendini güncelleyebilen kurulu kopyanın program klasörü. Yanında kendisini gösteren `install.json` olmayan
/// kopyalar (geliştirme derlemesi, taşınabilir kullanım) güncellenmez.
pub fn install_dir() -> Result<PathBuf, String> {
    let dir = install::current_exe_dir().ok_or_else(|| "Program klasörü bulunamadı.".to_string())?;
    match install::info_in(&dir) {
        Some(i) if install::same_path(&i.install_dir, &dir) => Ok(dir),
        _ => Err("Bu FerIDE kurulmadan (taşınabilir ya da geliştirme kopyası olarak) çalışıyor; otomatik güncelleme \
                  yalnızca kurulu FerIDE'de çalışır. Güncellemek için kurulum komutunu yeniden çalıştırın."
            .to_string()),
    }
}

// ------------------------------------------------------------------ indirme ve değiştirme

fn retry<T>(mut f: impl FnMut() -> std::io::Result<T>) -> std::io::Result<T> {
    let mut last = None;
    for _ in 0..20 {
        match f() {
            Ok(v) => return Ok(v),
            Err(e) => last = Some(e),
        }
        // Virüs tarayıcısı yeni kopyalanan programı birkaç saniye kilitleyebilir.
        std::thread::sleep(Duration::from_millis(300));
    }
    Err(last.unwrap_or_else(|| std::io::Error::other("başarısız")))
}

/// Program klasöründe `feride.new(.exe)` hazırsa çalışan programın yerine koyar: mevcut `feride(.exe)` →
/// `feride.old(.exe)`, yeni dosya → `feride(.exe)`. İkinci adım başarısız olursa ilki geri alınır.
pub fn swap_in(dir: &Path) -> anyhow::Result<()> {
    let cur = dir.join(install::exe_name());
    let new = dir.join(install::new_exe_name());
    anyhow::ensure!(new.is_file(), "yeni program dosyası bulunamadı: {}", new.display());
    let mut old = dir.join(install::old_exe_name());
    if old.exists() && std::fs::remove_file(&old).is_err() {
        // Önceki güncellemeden kalan eski dosyayı hâlâ çalışan bir FerIDE kullanıyor: benzersiz bir adla kenara al.
        let stamp = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
        let ext = if cfg!(windows) { ".exe" } else { "" };
        old = dir.join(format!("feride.old-{stamp}{ext}"));
    }
    if cur.exists() {
        retry(|| std::fs::rename(&cur, &old)).map_err(|e| anyhow::anyhow!("çalışan program kenara alınamadı: {e}"))?;
    }
    if let Err(e) = retry(|| std::fs::rename(&new, &cur)) {
        let _ = std::fs::rename(&old, &cur);
        anyhow::bail!("yeni program yerine konamadı: {e}");
    }
    Ok(())
}

async fn download(http: &reqwest::Client, url: &str, dest: &Path, mut progress: impl FnMut(u64, u64)) -> anyhow::Result<()> {
    use futures::StreamExt;
    use tokio::io::AsyncWriteExt;
    let resp = http.get(url).send().await?.error_for_status()?;
    let total = resp.content_length().unwrap_or(0);
    let part = dest.with_extension("part");
    let mut f = tokio::fs::File::create(&part).await?;
    let mut done = 0u64;
    let mut stream = resp.bytes_stream();
    while let Some(chunk) = stream.next().await {
        let c = chunk?;
        f.write_all(&c).await?;
        done += c.len() as u64;
        progress(done, total);
    }
    f.flush().await?;
    drop(f);
    tokio::fs::rename(&part, dest).await?;
    Ok(())
}

// ------------------------------------------------------------------ güncelleyici

/// Arayüze bildirilen güncelleme durumu.
#[derive(Clone, Debug, Default, Serialize)]
pub struct UpdateStatus {
    /// idle | checking | downloading | installing | ready | up_to_date | error | unsupported
    pub state: String,
    /// Çalışan sürüm.
    pub current: String,
    /// GitHub'daki en yeni sürüm (biliniyorsa).
    pub latest: Option<String>,
    /// Kurulup yeniden başlatmayı bekleyen sürüm.
    pub ready_version: Option<String>,
    pub done: u64,
    pub total: u64,
    pub message: Option<String>,
    pub page_url: Option<String>,
    pub notes: Option<String>,
    pub checked_at: Option<String>,
    /// Bu kopya kendini güncelleyebilir mi? Değilse `message` nedenini söyler.
    pub updatable: bool,
}

pub struct Updater {
    paths: Paths,
    events: EventBus,
    http: reqwest::Client,
    status: Mutex<UpdateStatus>,
    busy: tokio::sync::Mutex<()>,
}

impl Updater {
    pub fn new(paths: Paths, events: EventBus) -> Self {
        let http = reqwest::Client::builder()
            .user_agent(concat!("FerIDE/", env!("CARGO_PKG_VERSION")))
            .connect_timeout(Duration::from_secs(20))
            .build()
            .unwrap();
        let (updatable, message) = match (install_dir(), asset_name()) {
            (Ok(_), Some(_)) => (true, None),
            (Err(e), _) => (false, Some(e)),
            (Ok(_), None) => (false, Some("Bu işletim sistemi ve işlemci için hazır FerIDE paketi yayınlanmıyor.".to_string())),
        };
        let status = UpdateStatus {
            state: if updatable { "idle" } else { "unsupported" }.into(),
            current: current_version(),
            updatable,
            message,
            ..Default::default()
        };
        Self { paths, events, http, status: Mutex::new(status), busy: tokio::sync::Mutex::new(()) }
    }

    pub fn status(&self) -> UpdateStatus {
        self.status.lock().unwrap().clone()
    }

    fn set(&self, f: impl FnOnce(&mut UpdateStatus)) {
        let s = {
            let mut g = self.status.lock().unwrap();
            f(&mut g);
            g.clone()
        };
        self.events.emit_ser("update.status", &s);
    }

    /// GitHub'daki en yeni uygun sürüm (yalnızca denetler, kurmaz).
    pub async fn latest(&self) -> anyhow::Result<Option<Candidate>> {
        let asset = asset_name().ok_or_else(|| anyhow::anyhow!("Bu platform için hazır paket yok."))?;
        let releases: Vec<GhRelease> = self
            .http
            .get(format!("https://api.github.com/repos/{REPO}/releases?per_page=30"))
            .header("Accept", "application/vnd.github+json")
            .send()
            .await?
            .error_for_status()?
            .json()
            .await?;
        Ok(pick(&releases, asset))
    }

    /// Denetler; daha yeni bir sürüm varsa indirip kurar. Başka bir denetim sürüyorsa hemen döner.
    pub async fn run_once(&self) {
        let Ok(_guard) = self.busy.try_lock() else { return };
        let dir = match install_dir() {
            Ok(d) => d,
            Err(e) => {
                self.set(|s| {
                    s.state = "unsupported".into();
                    s.updatable = false;
                    s.message = Some(e);
                });
                return;
            }
        };
        if asset_name().is_none() {
            return;
        }
        self.set(|s| {
            s.state = "checking".into();
            s.message = None;
        });
        let cand = match self.latest().await {
            Ok(c) => c,
            Err(e) => {
                tracing::warn!("güncelleme denetlenemedi: {e}");
                self.set(|s| {
                    s.state = if s.ready_version.is_some() { "ready" } else { "error" }.into();
                    s.message = Some(format!("Güncelleme denetlenemedi: {e}"));
                    s.checked_at = Some(crate::util::now_iso());
                });
                return;
            }
        };
        // Kurulup yeniden başlatmayı bekleyen sürüm varsa onunla karşılaştır (aynı paketi yeniden indirme).
        let installed = self.status().ready_version.unwrap_or_else(current_version);
        match cand {
            Some(c) if is_newer(&c.version, &installed) => {
                self.set(|s| {
                    s.state = "downloading".into();
                    s.latest = Some(c.version.clone());
                    s.page_url = Some(c.page_url.clone());
                    s.notes = Some(c.notes.clone()).filter(|n| !n.is_empty());
                    s.done = 0;
                    s.total = c.size;
                    s.checked_at = Some(crate::util::now_iso());
                });
                match self.install(&dir, &c).await {
                    Ok(()) => {
                        tracing::info!("FerIDE {} kuruldu; yeniden başlatınca geçerli olacak", c.version);
                        self.set(|s| {
                            s.state = "ready".into();
                            s.ready_version = Some(c.version.clone());
                            s.message = None;
                        });
                    }
                    Err(e) => {
                        tracing::warn!("güncelleme kurulamadı: {e:#}");
                        self.set(|s| {
                            s.state = if s.ready_version.is_some() { "ready" } else { "error" }.into();
                            s.message = Some(format!("{} kurulamadı: {e:#}", c.version));
                        });
                    }
                }
            }
            c => self.set(|s| {
                s.state = if s.ready_version.is_some() { "ready" } else { "up_to_date" }.into();
                s.latest = c.as_ref().map(|c| c.version.clone());
                s.page_url = c.as_ref().map(|c| c.page_url.clone()).or(s.page_url.take());
                s.checked_at = Some(crate::util::now_iso());
            }),
        }
    }

    /// Paketi indirir, doğrular, programı sınar ve çalışan programın yerine koyar.
    async fn install(&self, dir: &Path, c: &Candidate) -> anyhow::Result<()> {
        let work = self.paths.cache().join("update");
        let _ = tokio::fs::remove_dir_all(&work).await;
        tokio::fs::create_dir_all(&work).await?;
        let file = work.join(&c.asset_name);

        // 1. İndir (ilerleme en çok yüzde birlik adımlarla bildirilir).
        let mut last_pct = u64::MAX;
        download(&self.http, &c.asset_url, &file, |done, total| {
            let pct = if total > 0 { done * 100 / total } else { done >> 20 };
            if pct != last_pct {
                last_pct = pct;
                self.set(|s| {
                    s.done = done;
                    s.total = total.max(s.total);
                });
            }
        })
        .await?;

        // 2. SHA-256 doğrula.
        self.set(|s| s.state = "installing".into());
        let sums = self.http.get(&c.sha_url).send().await?.error_for_status()?.text().await?;
        let expected = sums.split_whitespace().next().unwrap_or_default().to_lowercase();
        let f = file.clone();
        let actual = tokio::task::spawn_blocking(move || crate::deps::sha256_file(&f)).await??;
        anyhow::ensure!(!expected.is_empty() && actual == expected, "indirilen paket doğrulanamadı (SHA-256 uyuşmuyor)");

        // 3. Programı çıkar ve program klasörüne `feride.new(.exe)` olarak koy.
        let unpacked = work.join("paket");
        let (f, u) = (file.clone(), unpacked.clone());
        tokio::task::spawn_blocking(move || crate::deps::extract_archive(&f, &u)).await??;
        let exe = crate::deps::find_file(&unpacked, install::exe_name())
            .ok_or_else(|| anyhow::anyhow!("pakette {} yok", install::exe_name()))?;
        let staged = dir.join(install::new_exe_name());
        let _ = std::fs::remove_file(&staged);
        let (from, to) = (exe.clone(), staged.clone());
        tokio::task::spawn_blocking(move || retry(|| std::fs::copy(&from, &to)))
            .await?
            .map_err(|e| anyhow::anyhow!("program klasörüne yazılamadı ({}): {e}", dir.display()))?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&staged, std::fs::Permissions::from_mode(0o755));
        }

        // 4. Yeni program bu bilgisayarda çalışıyor mu? (Bozuk paket, eksik çalışma zamanı, Windows Akıllı Uygulama
        //    Denetimi…) Çalışmıyorsa mevcut program olduğu gibi kalır.
        let mut cmd = crate::proc::command(&self.paths, &staged.to_string_lossy(), &["--version".to_string()]);
        let probe = crate::proc::run_capture(&mut cmd, Duration::from_secs(30)).await;
        let ok = matches!(&probe, Ok((Some(0), out, err, false)) if format!("{out}{err}").contains(&c.version));
        if !ok {
            let _ = std::fs::remove_file(&staged);
            let detail = match probe {
                Ok((code, out, err, timed_out)) => format!(
                    "çıkış {code:?}{}{}",
                    if timed_out { ", zaman aşımı" } else { "" },
                    crate::util::truncate_end(format!(" {out}{err}").trim_end(), 200)
                ),
                Err(e) => e.to_string(),
            };
            anyhow::bail!("yeni sürüm bu bilgisayarda çalıştırılamadı ({detail}); mevcut sürüm korunuyor");
        }

        // 5. Çalışan programın yerine koy.
        let d = dir.to_path_buf();
        tokio::task::spawn_blocking(move || swap_in(&d)).await??;
        let _ = tokio::fs::remove_dir_all(&work).await;
        Ok(())
    }

    /// Yeni sürümü bu süreç kapandıktan sonra açılacak biçimde başlatır (masaüstü ya da `serve`, aynı seçeneklerle).
    /// Çağıran ardından kapanmalıdır.
    pub fn spawn_restart(&self) -> anyhow::Result<()> {
        let dir = install_dir().map_err(anyhow::Error::msg)?;
        let exe = dir.join(install::exe_name());
        let mut args = vec!["--restart-after".to_string(), std::process::id().to_string()];
        let mut it = std::env::args().skip(1);
        while let Some(a) = it.next() {
            if a == "--restart-after" {
                it.next();
            } else if !a.starts_with("--restart-after=") {
                args.push(a);
            }
        }
        let mut c = std::process::Command::new(&exe);
        c.args(&args).stdin(std::process::Stdio::null()).stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null());
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            c.creation_flags(0x0000_0008 | 0x0000_0200); // DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP
        }
        c.spawn().map_err(|e| anyhow::anyhow!("{} başlatılamadı: {e}", exe.display()))?;
        Ok(())
    }
}

/// `pid` süreci bitene kadar (en çok `max`) bekler.
pub fn wait_for_exit(pid: u32, max: Duration) {
    use sysinfo::{Pid, ProcessRefreshKind, ProcessesToUpdate, System};
    let pid = Pid::from_u32(pid);
    let mut sys = System::new();
    let start = std::time::Instant::now();
    while start.elapsed() < max {
        sys.refresh_processes_specifics(ProcessesToUpdate::Some(&[pid]), true, ProcessRefreshKind::nothing());
        if sys.process(pid).is_none() {
            return;
        }
        std::thread::sleep(Duration::from_millis(200));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_order() {
        let v = |s: &str| Version::parse(s).unwrap();
        assert!(v("5.4.0-beta.10") > v("5.4.0-beta.9"));
        assert!(v("v5.4.0-beta.13") > v("5.4.0-beta.12"));
        assert!(v("5.4.0") > v("5.4.0-beta.13"));
        assert!(v("5.5.0-beta.1") > v("5.4.0"));
        assert!(v("5.4.0-rc.1") > v("5.4.0-beta.20"));
        assert!(v("5.4.0-beta.1.2") > v("5.4.0-beta.1"));
        assert_eq!(v("v5.4.0-beta.13+abc"), v("5.4.0-beta.13"));
        assert_eq!(v("5.4"), v("5.4.0"));
        for bad in ["", "abc", "5.x", "5.4.0-", "5.4.0-beta..1", "1.2.3.4"] {
            assert!(Version::parse(bad).is_none(), "{bad}");
        }
        assert!(is_newer("5.4.0-beta.14", "5.4.0-beta.13"));
        assert!(!is_newer("5.4.0-beta.13", "5.4.0-beta.13"));
        assert!(!is_newer("bozuk", "5.4.0-beta.13"));
    }

    fn rel(tag: &str, draft: bool, assets: &[&str]) -> GhRelease {
        GhRelease {
            tag_name: tag.into(),
            draft,
            html_url: format!("https://example/{tag}"),
            body: Some(format!("  notlar {tag}  ")),
            assets: assets
                .iter()
                .map(|a| GhAsset { name: a.to_string(), browser_download_url: format!("https://dl/{tag}/{a}"), size: 7 })
                .collect(),
        }
    }

    #[test]
    fn picks_highest_with_asset() {
        let a = "feride-windows-x64.zip";
        let s = "feride-windows-x64.zip.sha256";
        // GitHub'ın gerçek sırası: beta.9, beta.10'un önünde.
        let list = vec![
            rel("v5.4.0-beta.9", false, &[a, s]),
            rel("v5.4.0-beta.99", true, &[a, s]),         // taslak
            rel("v5.4.0-beta.10", false, &[a, s]),
            rel("v5.4.0-beta.11", false, &[a]),           // sağlama toplamı yok
            rel("v5.4.0-beta.12", false, &["feride-linux-x64.tar.gz"]),
            rel("v5.3.8", false, &[]),
            rel("deps-whisper-v1.9.5", false, &[a, s]),   // sürüm değil
        ];
        let c = pick(&list, a).unwrap();
        assert_eq!(c.version, "5.4.0-beta.10");
        assert_eq!(c.tag, "v5.4.0-beta.10");
        assert_eq!(c.asset_url, "https://dl/v5.4.0-beta.10/feride-windows-x64.zip");
        assert_eq!(c.sha_url, "https://dl/v5.4.0-beta.10/feride-windows-x64.zip.sha256");
        assert_eq!(c.notes, "notlar v5.4.0-beta.10");
        assert!(pick(&list, "feride-macos-arm64.tar.gz").is_none());
    }

    #[test]
    fn notes_skip_install_instructions() {
        let body = "## Kurulum\n\nirm … | iex\n\n## Bu sürümde: beta v5.4 (5.4.0-beta.14) — Otomatik güncelleme\n\n- yeni\n";
        assert_eq!(version_notes(body), "## Bu sürümde: beta v5.4 (5.4.0-beta.14) — Otomatik güncelleme\n\n- yeni");
        assert_eq!(version_notes("  yalnızca not  "), "yalnızca not");
    }

    #[test]
    fn swap_keeps_old() {
        let d = std::env::temp_dir().join(format!("feride-swap-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        let cur = d.join(install::exe_name());
        let new = d.join(install::new_exe_name());
        let old = d.join(install::old_exe_name());
        // Yeni dosya yoksa hiçbir şeye dokunulmaz.
        std::fs::write(&cur, b"eski").unwrap();
        assert!(swap_in(&d).is_err());
        assert_eq!(std::fs::read(&cur).unwrap(), b"eski");
        // Normal değişim; önceki güncellemeden kalan eski dosya silinir.
        std::fs::write(&old, b"daha eski").unwrap();
        std::fs::write(&new, b"yeni").unwrap();
        swap_in(&d).unwrap();
        assert_eq!(std::fs::read(&cur).unwrap(), b"yeni");
        assert_eq!(std::fs::read(&old).unwrap(), b"eski");
        assert!(!new.exists());
        let _ = std::fs::remove_dir_all(&d);
    }
}
