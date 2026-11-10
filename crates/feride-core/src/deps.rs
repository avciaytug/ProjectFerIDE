//! Bağımlılık tespiti ve kurulumu (ilk açılış sihirbazı + Ayarlar > Kurulum).
//!
//! Her şey kullanıcı klasörüne kurulur (`~/.feride/bin`, `~/.feride/tools`); yönetici
//! izni gerekmez. Yönetici gerektiren az sayıdaki iş (Windows: VC++ çalışma zamanı,
//! uzun dosya yolları; Linux: sistem paketleri) tek bir betikte toplanır ve TEK onayla
//! çalıştırılır. Sonuç `state.json`'a yazılır; aynı iş bir daha sorulmaz.

use serde::{Deserialize, Serialize};
use serde_json::json;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::Duration;

use crate::config::Settings;
use crate::events::EventBus;
use crate::paths::Paths;

/// Ses paketi sürümü (işaret dosyasına yazılır). Yeni model ya da bağımlılık eklenince artırılır.
pub const VOICE_PACK: &str = "voice-pack-3";

/// GPU konuşma tanıma: whisper.cpp sunucusu FerIDE'nin kendi CI'ında (Vulkan/Metal) derlenip bu ön sürüme yüklenir.
const WHISPER_GPU_RELEASE: &str = "https://github.com/avciaytug/ProjectFerIDE/releases/download/deps-whisper-v1.9.5";
/// ggerganov/whisper.cpp deposundaki ggml-large-v3-turbo-q8_0.bin dosyasının SHA-256 özeti (LFS).
const GGML_STT_SHA256: &str = "317eb69c11673c9de1e1f0d459b253999804ec71ac4c23c17ecf5fbe24e259a1";

#[derive(Clone, Debug, Serialize)]
pub struct DepStatus {
    pub id: String,
    pub name: String,
    pub description: String,
    pub required: bool,
    pub installed: bool,
    pub version: Option<String>,
    pub path: Option<String>,
    pub needs_admin: bool,
    pub size_hint: String,
    pub note: Option<String>,
    /// Bu platformda geçerli mi?
    pub applicable: bool,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct SetupState {
    pub first_run_done: bool,
    /// Yönetici betiğiyle tamamlanan işler (bir daha sorulmaz).
    pub admin_done: Vec<String>,
    pub admin_declined_at: Option<String>,
    pub llama_tag: Option<String>,
    pub llama_backend: Option<String>,
    pub resources_version: Option<String>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct Asset {
    pub name: String,
    pub browser_download_url: String,
    pub size: u64,
}

#[derive(Clone, Debug, Deserialize)]
pub struct Release {
    pub tag_name: String,
    #[serde(default)]
    pub assets: Vec<Asset>,
}

pub struct Deps {
    paths: Paths,
    events: EventBus,
    http: reqwest::Client,
    state: Mutex<SetupState>,
    busy: tokio::sync::Mutex<()>,
}

pub fn exe(name: &str) -> String {
    if cfg!(windows) {
        format!("{name}.exe")
    } else {
        name.to_string()
    }
}

/// Kullanılacak llama-server: ayarlardaki yol → FerIDE kurulumu → eski düz kurulum → PATH.
pub fn find_llama_server(paths: &Paths, settings: &Settings) -> Option<PathBuf> {
    if let Some(p) = settings.model.server_path.as_ref().filter(|p| p.is_file()) {
        return Some(p.clone());
    }
    let root = paths.llama_root();
    if let Ok(cur) = std::fs::read_to_string(root.join("current.txt")) {
        let p = root.join(cur.trim()).join(exe("llama-server"));
        if p.is_file() {
            return Some(p);
        }
    }
    let flat = root.join(exe("llama-server"));
    if flat.is_file() {
        return Some(flat);
    }
    let mut found: Vec<(std::time::SystemTime, PathBuf)> = vec![];
    for e in ignore::WalkBuilder::new(&root).max_depth(Some(5)).standard_filters(false).build().flatten() {
        if e.file_name().to_string_lossy() == exe("llama-server") {
            let t = e.metadata().ok().and_then(|m| m.modified().ok()).unwrap_or(std::time::UNIX_EPOCH);
            found.push((t, e.path().to_path_buf()));
        }
    }
    found.sort();
    if let Some((_, p)) = found.pop() {
        return Some(p);
    }
    let path_var = crate::proc::child_path(paths, &[]);
    crate::proc::which_in("llama-server", &path_var)
}

/// llama.cpp sürüm varlıklarından platforma uygun olanları seçer
/// (CUDA için Windows'ta ayrıca `cudart` paketi).
pub fn pick_llama_assets(assets: &[Asset], os: &str, arch: &str, backend: &str) -> Vec<Asset> {
    let arch_tag = if arch == "aarch64" { "arm64" } else { "x64" };
    let lower = |a: &Asset| a.name.to_lowercase();
    let main: Vec<&Asset> = assets
        .iter()
        .filter(|a| {
            let n = lower(a);
            n.starts_with("llama-") && n.contains("-bin-") && n.contains(arch_tag) && !n.contains("snapdragon") && !n.contains("adreno")
        })
        .collect();
    let pick = |pred: &dyn Fn(&str) -> bool| -> Option<Asset> {
        let mut c: Vec<&&Asset> = main.iter().filter(|a| pred(&lower(a))).collect();
        // Birden çok CUDA sürümü varsa en geniş uyumlu (en düşük) olanı seç.
        c.sort_by_key(|a| a.name.clone());
        c.first().map(|a| (**a).clone())
    };
    match os {
        "windows" => {
            let is_win = |n: &str| n.contains("-win-") && n.ends_with(".zip");
            let m = match backend {
                "cuda" => pick(&|n| is_win(n) && n.contains("cuda")),
                "cpu" => pick(&|n| is_win(n) && n.contains("-cpu-")),
                "hip" | "rocm" => pick(&|n| is_win(n) && (n.contains("rocm") || n.contains("hip"))),
                _ => pick(&|n| is_win(n) && n.contains("vulkan")),
            };
            let Some(m) = m else { return vec![] };
            let mut v = vec![m.clone()];
            if backend == "cuda" {
                // "…-win-cuda-12.4-x64.zip" → "cudart-llama-bin-win-cuda-12.4-x64.zip"
                let ver = m.name.split("cuda-").nth(1).and_then(|s| s.split('-').next()).unwrap_or("");
                if let Some(rt) = assets.iter().find(|a| {
                    let n = lower(a);
                    n.starts_with("cudart-") && n.contains("-win-") && n.contains(&format!("cuda-{ver}")) && n.contains(arch_tag)
                }) {
                    v.push(rt.clone());
                }
            }
            v
        }
        "macos" => pick(&|n| n.contains("-macos-")).into_iter().collect(),
        _ => {
            let is_lin = |n: &str| n.contains("-ubuntu-") && (n.ends_with(".tar.gz") || n.ends_with(".zip"));
            let m = match backend {
                "cuda" => pick(&|n| is_lin(n) && n.contains("cuda")),
                "hip" | "rocm" => pick(&|n| is_lin(n) && n.contains("rocm")),
                "cpu" => pick(&|n| {
                    is_lin(n) && !["vulkan", "cuda", "rocm", "sycl", "openvino", "zdnn", "s390x"].iter().any(|x| n.contains(x))
                }),
                _ => pick(&|n| is_lin(n) && n.contains("vulkan")),
            };
            m.into_iter().collect()
        }
    }
}

impl Deps {
    pub fn new(paths: Paths, events: EventBus) -> Self {
        let state = std::fs::read(paths.state_file())
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default();
        let http = reqwest::Client::builder()
            .user_agent(concat!("FerIDE/", env!("CARGO_PKG_VERSION")))
            .connect_timeout(Duration::from_secs(20))
            .build()
            .unwrap();
        Self { paths, events, http, state: Mutex::new(state), busy: tokio::sync::Mutex::new(()) }
    }

    pub fn state(&self) -> SetupState {
        self.state.lock().unwrap().clone()
    }

    pub fn update_state(&self, f: impl FnOnce(&mut SetupState)) {
        let mut s = self.state.lock().unwrap();
        f(&mut s);
        if let Ok(b) = serde_json::to_vec_pretty(&*s) {
            let _ = crate::util::write_atomic(&self.paths.state_file(), &b);
        }
    }

    fn progress(&self, id: &str, message: &str, done: u64, total: u64) {
        self.events.emit("setup.progress", json!({"id": id, "message": message, "done": done, "total": total}));
    }

    fn version_of(&self, program: &Path, arg: &str) -> Option<String> {
        let out = crate::proc::std_command(&self.paths, program).arg(arg).output().ok()?;
        let s = format!("{}{}", String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr));
        s.lines().find(|l| !l.trim().is_empty()).map(|l| crate::util::truncate_end(l.trim(), 80))
    }

    fn which(&self, name: &str) -> Option<PathBuf> {
        crate::proc::which_in(name, &crate::proc::child_path(&self.paths, &[]))
    }

    /// Tüm bağımlılıkların durumu.
    pub fn check(&self, settings: &Settings) -> Vec<DepStatus> {
        let win = cfg!(windows);
        let st = self.state();
        let mut v = vec![];

        let llama = find_llama_server(&self.paths, settings);
        v.push(DepStatus {
            id: "llama".into(),
            name: "llama.cpp (llama-server)".into(),
            description: "Yerel modelleri çalıştıran motor. GPU için Vulkan (AMD/Intel/NVIDIA), istenirse CUDA.".into(),
            required: true,
            installed: llama.is_some(),
            version: llama.as_ref().and_then(|p| {
                st.llama_tag.clone().or_else(|| self.version_of(p, "--version").map(|v| v.replace("version: ", "")))
            }),
            path: llama.map(|p| p.display().to_string()),
            needs_admin: false,
            size_hint: "40 MB (CUDA: 700 MB)".into(),
            note: None,
            applicable: true,
        });

        let git = self.which("git");
        let bash_ok = !win || crate::shell::Shell::detect(&self.paths, "bash").kind == crate::shell::ShellKind::Bash;
        v.push(DepStatus {
            id: "git".into(),
            name: if win { "Git + Git Bash".into() } else { "Git".into() },
            description: "Ajanın git kullanması ve Windows'ta bash komutlarını çalıştırması için. Taşınabilir sürüm kullanıcı klasörüne kurulur.".into(),
            required: false,
            installed: git.is_some() && bash_ok,
            version: git.as_ref().and_then(|g| self.version_of(g, "--version")),
            path: git.map(|p| p.display().to_string()),
            needs_admin: !win && !cfg!(target_os = "macos"),
            size_hint: "60 MB".into(),
            note: None,
            applicable: true,
        });

        let uv = self.which("uv");
        v.push(DepStatus {
            id: "uv".into(),
            name: "uv (Python yöneticisi)".into(),
            description: "Belge stüdyosu, ses ve Python tabanlı MCP sunucuları için Python'u kendisi indirir; sisteme dokunmaz.".into(),
            required: false,
            installed: uv.is_some(),
            version: uv.as_ref().and_then(|u| self.version_of(u, "--version")),
            path: uv.map(|p| p.display().to_string()),
            needs_admin: false,
            size_hint: "20 MB".into(),
            note: None,
            applicable: true,
        });

        let py = self.paths.pyenv_python();
        let docs_ok = py.is_file() && self.paths.pyenv().join(".feride-docs").exists();
        v.push(DepStatus {
            id: "pydocs".into(),
            name: "Belge ve CAD stüdyosu".into(),
            description: "PDF, Word, Excel, PowerPoint, görsel (OCR), ses ve AutoCAD (.dwg/.dxf) okuma/oluşturma araçları.".into(),
            required: false,
            installed: docs_ok,
            version: None,
            path: docs_ok.then(|| py.display().to_string()),
            needs_admin: false,
            size_hint: "350 MB".into(),
            note: Some("uv gerektirir".into()),
            applicable: true,
        });

        // İşaret dosyası paket sürümünü taşır; eski kurulumlar (kadın sesi bağımlılıkları ve yeni
        // Whisper modelleri olmadan) "güncelleme gerekli" görünür.
        let voice_marker = std::fs::read_to_string(self.paths.pyenv().join(".feride-voice")).unwrap_or_default();
        let voice_ok = py.is_file() && voice_marker.contains(VOICE_PACK);
        v.push(DepStatus {
            id: "voice".into(),
            name: "Ses paketi (Whisper + Feride sesi)".into(),
            description: "Konuşmayı yazıya çevirme, Türkçe sesli yanıt ve canlı sesli sohbet. Tamamen yerel çalışır.".into(),
            required: false,
            installed: voice_ok,
            version: None,
            path: None,
            needs_admin: false,
            size_hint: "4,4 GB".into(),
            note: Some(if !voice_marker.is_empty() && !voice_ok {
                "Güncelleme gerekli: Feride (kadın) sesi ve ekran kartında doğru Türkçe konuşma tanıma".into()
            } else {
                "uv gerektirir".into()
            }),
            applicable: true,
        });

        let node = self.which("node");
        v.push(DepStatus {
            id: "node".into(),
            name: "Node.js (LTS)".into(),
            description: "npx ile çalışan MCP sunucuları için (dosya sistemi, hafıza grafiği, GitHub…).".into(),
            required: false,
            installed: node.is_some(),
            version: node.as_ref().and_then(|n| self.version_of(n, "--version")),
            path: node.map(|p| p.display().to_string()),
            needs_admin: false,
            size_hint: "30 MB".into(),
            note: None,
            applicable: true,
        });

        if win {
            let wv = webview2_version();
            v.push(DepStatus {
                id: "webview2".into(),
                name: "Microsoft Edge WebView2".into(),
                description: "Arayüzün çizildiği bileşen (Windows 11'de hazır gelir).".into(),
                required: true,
                installed: wv.is_some(),
                version: wv,
                path: None,
                needs_admin: false,
                size_hint: "2 MB indirici".into(),
                note: None,
                applicable: true,
            });
            let vc = vcruntime_installed();
            v.push(DepStatus {
                id: "vcredist".into(),
                name: "Visual C++ çalışma zamanı".into(),
                description: "llama.cpp ve Python paketlerinin ihtiyaç duyduğu Microsoft kitaplıkları.".into(),
                required: true,
                installed: vc,
                version: None,
                path: None,
                needs_admin: true,
                size_hint: "25 MB".into(),
                note: None,
                applicable: true,
            });
            let lp = long_paths_enabled();
            v.push(DepStatus {
                id: "longpaths".into(),
                name: "Uzun dosya yolları".into(),
                description: "260 karakterden uzun yollar (derin node_modules, Python paketleri) için Windows ayarı.".into(),
                required: false,
                installed: lp,
                version: None,
                path: None,
                needs_admin: true,
                size_hint: "—".into(),
                note: None,
                applicable: true,
            });
        }
        if cfg!(target_os = "linux") {
            let vk = linux_has_vulkan();
            v.push(DepStatus {
                id: "vulkan".into(),
                name: "Vulkan çalışma zamanı".into(),
                description: "GPU hızlandırma için (libvulkan + Mesa sürücüleri).".into(),
                required: false,
                installed: vk,
                version: None,
                path: None,
                needs_admin: true,
                size_hint: "—".into(),
                note: None,
                applicable: true,
            });
        }
        v
    }

    async fn latest_llama_release(&self) -> anyhow::Result<Release> {
        // Not: llama.cpp derlemeleri "ön sürüm" olarak yayınlanıyor; /releases/latest artık
        // derleme döndürmüyor. Listeyi alıp varlıkları olan ilk "bNNNN" etiketini seçiyoruz.
        let list: Vec<Release> = self
            .http
            .get("https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=10")
            .send()
            .await?
            .error_for_status()?
            .json()
            .await?;
        list.into_iter()
            .find(|r| r.tag_name.starts_with('b') && r.assets.iter().any(|a| a.name.contains("-bin-")))
            .ok_or_else(|| anyhow::anyhow!("llama.cpp sürümü bulunamadı"))
    }

    async fn github_latest(&self, repo: &str) -> anyhow::Result<Release> {
        Ok(self
            .http
            .get(format!("https://api.github.com/repos/{repo}/releases/latest"))
            .send()
            .await?
            .error_for_status()?
            .json()
            .await?)
    }

    /// Dosyayı ilerleme bildirerek indirir.
    pub async fn download(&self, id: &str, url: &str, dest: &Path, label: &str) -> anyhow::Result<()> {
        use futures::StreamExt;
        use tokio::io::AsyncWriteExt;
        if let Some(p) = dest.parent() {
            tokio::fs::create_dir_all(p).await?;
        }
        let resp = self.http.get(url).send().await?.error_for_status()?;
        let total = resp.content_length().unwrap_or(0);
        let tmp = dest.with_extension("indiriliyor");
        let mut f = tokio::fs::File::create(&tmp).await?;
        let mut done = 0u64;
        let mut last = std::time::Instant::now();
        let mut stream = resp.bytes_stream();
        while let Some(chunk) = tokio::time::timeout(Duration::from_secs(120), stream.next())
            .await
            .map_err(|_| anyhow::anyhow!("indirme 2 dakikadır ilerlemiyor"))?
        {
            let chunk = chunk?;
            f.write_all(&chunk).await?;
            done += chunk.len() as u64;
            if last.elapsed() > Duration::from_millis(250) {
                self.progress(id, &format!("{label} indiriliyor"), done, total);
                last = std::time::Instant::now();
            }
        }
        f.flush().await?;
        drop(f);
        tokio::fs::rename(&tmp, dest).await?;
        self.progress(id, &format!("{label} indirildi"), done, done);
        Ok(())
    }

    pub async fn install(&self, id: &str, settings: &Settings) -> anyhow::Result<String> {
        let _g = self.busy.lock().await;
        let r = match id {
            "llama" => self.install_llama(&settings.model.backend).await,
            "git" => self.install_git().await,
            "uv" => self.install_uv().await,
            "node" => self.install_node().await,
            "pydocs" => self.install_python_pack("docs").await,
            "voice" => self.install_python_pack("voice").await,
            "webview2" => self.install_webview2().await,
            other => Err(anyhow::anyhow!("'{other}' tek başına kurulamaz; yönetici gerektiren işler birlikte kurulur.")),
        };
        match &r {
            Ok(m) => self.events.emit("setup.done", json!({"id": id, "ok": true, "message": m})),
            Err(e) => self.events.emit("setup.done", json!({"id": id, "ok": false, "message": e.to_string()})),
        }
        r
    }

    /// Eksik olanları kurar: önce yönetici gerektirmeyenler, en sonda (gerekirse) TEK yönetici onayı.
    pub async fn install_missing(&self, settings: &Settings, ids: &[String]) -> Vec<(String, Result<String, String>)> {
        let status = self.check(settings);
        let wanted = |d: &DepStatus| ids.is_empty() && d.required || ids.contains(&d.id);
        let mut results = vec![];
        let order = ["vcredist", "longpaths", "vulkan", "webview2", "llama", "git", "uv", "node", "pydocs", "voice"];
        let mut admin_ids = vec![];
        for id in order {
            let Some(d) = status.iter().find(|d| d.id == id) else { continue };
            if d.installed || !wanted(d) {
                continue;
            }
            if d.needs_admin {
                admin_ids.push(id.to_string());
                continue;
            }
            if (id == "pydocs" || id == "voice") && self.which("uv").is_none() {
                let r = self.install("uv", settings).await.map_err(|e| e.to_string());
                results.push(("uv".to_string(), r));
            }
            let r = self.install(id, settings).await.map_err(|e| e.to_string());
            results.push((id.to_string(), r));
        }
        if !admin_ids.is_empty() {
            let r = self.run_admin_batch(&admin_ids).await.map_err(|e| e.to_string());
            results.push(("admin".to_string(), r));
        }
        self.update_state(|s| s.first_run_done = true);
        results
    }

    // ------------------------------------------------------------------ llama.cpp
    async fn install_llama(&self, backend_pref: &str) -> anyhow::Result<String> {
        let os = if cfg!(windows) { "windows" } else if cfg!(target_os = "macos") { "macos" } else { "linux" };
        let backend = match backend_pref {
            "auto" | "" => {
                if os == "macos" {
                    "metal".to_string()
                } else if os == "windows" && self.which("nvidia-smi").is_some() {
                    "cuda".to_string()
                } else {
                    "vulkan".to_string()
                }
            }
            b => b.to_string(),
        };
        self.progress("llama", "llama.cpp sürümü sorgulanıyor", 0, 0);
        let rel = self.latest_llama_release().await?;
        let assets = pick_llama_assets(&rel.assets, os, std::env::consts::ARCH, &backend);
        if assets.is_empty() {
            anyhow::bail!("Bu platform için llama.cpp derlemesi bulunamadı ({os}, {backend}).");
        }
        let dir_name = format!("{}-{}", rel.tag_name, backend);
        let root = self.paths.llama_root();
        let target = root.join(&dir_name);
        let staging = root.join(format!("{dir_name}.kuruluyor"));
        let _ = tokio::fs::remove_dir_all(&staging).await;
        tokio::fs::create_dir_all(&staging).await?;
        for a in &assets {
            let file = self.paths.cache().join(&a.name);
            self.download("llama", &a.browser_download_url, &file, &format!("llama.cpp {}", rel.tag_name)).await?;
            self.progress("llama", "Arşiv açılıyor", 0, 0);
            let (f, s) = (file.clone(), staging.clone());
            tokio::task::spawn_blocking(move || extract_archive(&f, &s)).await??;
            let _ = tokio::fs::remove_file(&file).await;
        }
        // CUDA çalışma zamanı DLL'leri llama-server'ın yanına gelmeli.
        let server = find_file(&staging, &exe("llama-server")).ok_or_else(|| anyhow::anyhow!("arşivde llama-server yok"))?;
        let server_dir = server.parent().unwrap().to_path_buf();
        if server_dir != staging {
            for e in std::fs::read_dir(&staging)?.flatten() {
                let p = e.path();
                if p.is_file() && p.extension().map(|x| x.eq_ignore_ascii_case("dll")).unwrap_or(false) {
                    let _ = std::fs::rename(&p, server_dir.join(e.file_name()));
                }
            }
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            for e in std::fs::read_dir(&server_dir)?.flatten() {
                let n = e.file_name().to_string_lossy().to_string();
                if n.starts_with("llama-") || n.starts_with("rpc-") {
                    let _ = std::fs::set_permissions(e.path(), std::fs::Permissions::from_mode(0o755));
                }
            }
        }
        // Çalışıyor mu?
        let ver = self.version_of(&server, "--version");
        if ver.is_none() {
            anyhow::bail!("llama-server kuruldu ama çalıştırılamadı (eksik sürücü ya da çalışma zamanı olabilir).");
        }
        let _ = tokio::fs::remove_dir_all(&target).await;
        tokio::fs::rename(&staging, &target).await?;
        let rel_dir = server_dir.strip_prefix(&staging).unwrap_or(Path::new("")).to_path_buf();
        let current = PathBuf::from(&dir_name).join(rel_dir);
        crate::util::write_atomic(&root.join("current.txt"), current.to_string_lossy().as_bytes())?;
        self.update_state(|s| {
            s.llama_tag = Some(rel.tag_name.clone());
            s.llama_backend = Some(backend.clone());
        });
        self.cleanup_old_llama(&dir_name);
        Ok(format!("llama.cpp {} ({backend}) kuruldu.", rel.tag_name))
    }

    /// Eski sürüm klasörlerini siler (çalışan sürüm Windows'ta kilitliyse sessizce atlanır).
    fn cleanup_old_llama(&self, keep: &str) {
        let root = self.paths.llama_root();
        let Ok(rd) = std::fs::read_dir(&root) else { return };
        let mut dirs: Vec<(std::time::SystemTime, PathBuf)> = rd
            .flatten()
            .filter(|e| e.path().is_dir() && e.file_name().to_string_lossy().starts_with('b') && e.file_name() != keep)
            .map(|e| (e.metadata().and_then(|m| m.modified()).unwrap_or(std::time::UNIX_EPOCH), e.path()))
            .collect();
        dirs.sort();
        // Bir önceki sürümü geri dönüş için tut.
        dirs.pop();
        for (_, d) in dirs {
            let _ = std::fs::remove_dir_all(d);
        }
    }

    // ------------------------------------------------------------------ Git
    async fn install_git(&self) -> anyhow::Result<String> {
        if !cfg!(windows) {
            anyhow::bail!("Git'i paket yöneticinizle kurun (ör. sudo apt install git). Kurulum sihirbazı bunu yönetici adımında yapabilir.");
        }
        let rel = self.github_latest("git-for-windows/git").await?;
        let arch = if std::env::consts::ARCH == "aarch64" { "arm64" } else { "64-bit" };
        let a = rel
            .assets
            .iter()
            .find(|a| a.name.starts_with("PortableGit-") && a.name.contains(arch) && a.name.ends_with(".7z.exe"))
            .ok_or_else(|| anyhow::anyhow!("PortableGit bulunamadı"))?;
        let file = self.paths.cache().join(&a.name);
        self.download("git", &a.browser_download_url, &file, "Git").await?;
        let dest = self.paths.tools().join("git");
        let _ = tokio::fs::remove_dir_all(&dest).await;
        tokio::fs::create_dir_all(&dest).await?;
        self.progress("git", "Git açılıyor", 0, 0);
        let mut cmd = crate::proc::command(&self.paths, &file.to_string_lossy(), &["-y".into(), format!("-o{}", dest.display())]);
        let (code, _, err, timed_out) = crate::proc::run_capture(&mut cmd, Duration::from_secs(600)).await?;
        let _ = tokio::fs::remove_file(&file).await;
        if timed_out || code != Some(0) || !dest.join("bin").join("bash.exe").is_file() {
            anyhow::bail!("Git açılamadı: {err}");
        }
        // İlk kurulum betiği (varsa) sessizce çalışsın.
        let post = dest.join("post-install.bat");
        if post.is_file() {
            let mut c = crate::proc::command(&self.paths, "cmd.exe", &["/C".into(), post.to_string_lossy().into()]);
            c.current_dir(&dest);
            let _ = crate::proc::run_capture(&mut c, Duration::from_secs(120)).await;
        }
        Ok(format!("Git {} (taşınabilir) kuruldu.", rel.tag_name))
    }

    // ------------------------------------------------------------------ uv
    async fn install_uv(&self) -> anyhow::Result<String> {
        let rel = self.github_latest("astral-sh/uv").await?;
        let triple = match (std::env::consts::OS, std::env::consts::ARCH) {
            ("windows", "aarch64") => "aarch64-pc-windows-msvc.zip",
            ("windows", _) => "x86_64-pc-windows-msvc.zip",
            ("macos", "aarch64") => "aarch64-apple-darwin.tar.gz",
            ("macos", _) => "x86_64-apple-darwin.tar.gz",
            (_, "aarch64") => "aarch64-unknown-linux-gnu.tar.gz",
            _ => "x86_64-unknown-linux-gnu.tar.gz",
        };
        let a = rel
            .assets
            .iter()
            .find(|a| a.name == format!("uv-{triple}"))
            .ok_or_else(|| anyhow::anyhow!("uv derlemesi bulunamadı"))?;
        let file = self.paths.cache().join(&a.name);
        self.download("uv", &a.browser_download_url, &file, "uv").await?;
        let dest = self.paths.tools().join("uv");
        let tmp = self.paths.tools().join("uv.kuruluyor");
        let _ = tokio::fs::remove_dir_all(&tmp).await;
        let (f, t) = (file.clone(), tmp.clone());
        tokio::task::spawn_blocking(move || extract_archive(&f, &t)).await??;
        let _ = tokio::fs::remove_file(&file).await;
        let uv = find_file(&tmp, &exe("uv")).ok_or_else(|| anyhow::anyhow!("arşivde uv yok"))?;
        let _ = tokio::fs::remove_dir_all(&dest).await;
        tokio::fs::create_dir_all(&dest).await?;
        for e in std::fs::read_dir(uv.parent().unwrap())?.flatten() {
            std::fs::rename(e.path(), dest.join(e.file_name()))?;
        }
        let _ = tokio::fs::remove_dir_all(&tmp).await;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            for n in ["uv", "uvx"] {
                let _ = std::fs::set_permissions(dest.join(n), std::fs::Permissions::from_mode(0o755));
            }
        }
        Ok(format!("uv {} kuruldu.", rel.tag_name))
    }

    // ------------------------------------------------------------------ Node.js
    async fn install_node(&self) -> anyhow::Result<String> {
        let idx: Vec<serde_json::Value> = self.http.get("https://nodejs.org/dist/index.json").send().await?.json().await?;
        let lts = idx
            .iter()
            .find(|v| v["lts"].is_string())
            .ok_or_else(|| anyhow::anyhow!("Node.js LTS bulunamadı"))?;
        let ver = lts["version"].as_str().unwrap_or_default().to_string();
        let arch = if std::env::consts::ARCH == "aarch64" { "arm64" } else { "x64" };
        let name = match std::env::consts::OS {
            "windows" => format!("node-{ver}-win-{arch}.zip"),
            "macos" => format!("node-{ver}-darwin-{arch}.tar.gz"),
            _ => format!("node-{ver}-linux-{arch}.tar.gz"),
        };
        let url = format!("https://nodejs.org/dist/{ver}/{name}");
        let file = self.paths.cache().join(&name);
        self.download("node", &url, &file, "Node.js").await?;
        // SHA-256 doğrulaması (resmi SHASUMS256.txt).
        if let Ok(sums) = self.http.get(format!("https://nodejs.org/dist/{ver}/SHASUMS256.txt")).send().await {
            if let Ok(text) = sums.text().await {
                if let Some(expected) = text.lines().find(|l| l.ends_with(&name)).and_then(|l| l.split_whitespace().next()) {
                    let f = file.clone();
                    let actual = tokio::task::spawn_blocking(move || sha256_file(&f)).await??;
                    if !actual.eq_ignore_ascii_case(expected) {
                        let _ = tokio::fs::remove_file(&file).await;
                        anyhow::bail!("Node.js indirmesi doğrulanamadı (SHA-256 uyuşmuyor).");
                    }
                }
            }
        }
        let tmp = self.paths.tools().join("node.kuruluyor");
        let _ = tokio::fs::remove_dir_all(&tmp).await;
        let (f, t) = (file.clone(), tmp.clone());
        tokio::task::spawn_blocking(move || extract_archive(&f, &t)).await??;
        let _ = tokio::fs::remove_file(&file).await;
        let inner = std::fs::read_dir(&tmp)?.flatten().find(|e| e.path().is_dir()).map(|e| e.path()).unwrap_or(tmp.clone());
        let dest = self.paths.tools().join("node");
        let _ = tokio::fs::remove_dir_all(&dest).await;
        tokio::fs::rename(&inner, &dest).await?;
        let _ = tokio::fs::remove_dir_all(&tmp).await;
        Ok(format!("Node.js {ver} kuruldu."))
    }

    // ------------------------------------------------------------------ Python paketleri
    async fn install_python_pack(&self, pack: &str) -> anyhow::Result<String> {
        let uv = self.which("uv").ok_or_else(|| anyhow::anyhow!("Önce uv kurulmalı."))?;
        let pyenv = self.paths.pyenv();
        let id = if pack == "docs" { "pydocs" } else { "voice" };
        if !self.paths.pyenv_python().is_file() {
            self.progress(id, "Python 3.12 ortamı hazırlanıyor (uv indiriyor)", 0, 0);
            let mut c = crate::proc::command(
                &self.paths,
                &uv.to_string_lossy(),
                &["venv".into(), "--python".into(), "3.12".into(), "--seed".into(), pyenv.to_string_lossy().into()],
            );
            let (code, out, err, _) = crate::proc::run_capture(&mut c, Duration::from_secs(900)).await?;
            if code != Some(0) {
                anyhow::bail!("Python ortamı oluşturulamadı: {}{}", out, err);
            }
        }
        let req = self.paths.resources().join("python").join(format!("requirements-{pack}.txt"));
        if !req.is_file() {
            anyhow::bail!("Gereksinim dosyası bulunamadı: {}", req.display());
        }
        self.progress(id, "Python paketleri kuruluyor (birkaç dakika sürebilir)", 0, 0);
        let mut args: Vec<String> = vec![
            "pip".into(),
            "install".into(),
            "--python".into(),
            self.paths.pyenv_python().to_string_lossy().into(),
            "-r".into(),
            req.to_string_lossy().into(),
        ];
        if pack == "voice" {
            args.extend(["--extra-index-url".into(), "https://download.pytorch.org/whl/cpu".into(), "--index-strategy".into(), "unsafe-best-match".into()]);
        }
        let mut c = crate::proc::command(&self.paths, &uv.to_string_lossy(), &args);
        let (code, out, err, timed_out) = crate::proc::run_capture(&mut c, Duration::from_secs(3600)).await?;
        if timed_out || code != Some(0) {
            anyhow::bail!("Python paketleri kurulamadı:\n{}", crate::util::truncate_middle(&format!("{out}\n{err}"), 3000));
        }
        if pack == "voice" {
            self.fetch_voice_models().await?;
        }
        let marker = if pack == "voice" { format!("{VOICE_PACK} {}", crate::util::now_iso()) } else { crate::util::now_iso() };
        std::fs::write(pyenv.join(format!(".feride-{pack}")), marker)?;
        Ok(if pack == "docs" { "Belge ve CAD stüdyosu kuruldu.".into() } else { "Ses paketi kuruldu.".into() })
    }

    /// Ses modelleri: Piper (Türkçe erkek sesi) ve Whisper base. Ahenk Cep (Feride sesi)
    /// v5.3.8 kurulumundan taşınmışsa kullanılır.
    async fn fetch_voice_models(&self) -> anyhow::Result<()> {
        let models = self.paths.voice().join("models");
        let piper = models.join("piper");
        let files = [
            (piper.join("tr_TR-fahrettin-medium.onnx"), "https://huggingface.co/rhasspy/piper-voices/resolve/main/tr/tr_TR/fahrettin/medium/tr_TR-fahrettin-medium.onnx"),
            (piper.join("tr_TR-fahrettin-medium.onnx.json"), "https://huggingface.co/rhasspy/piper-voices/resolve/main/tr/tr_TR/fahrettin/medium/tr_TR-fahrettin-medium.onnx.json"),
        ];
        for (dest, url) in files {
            if !dest.is_file() {
                self.download("voice", url, &dest, "Türkçe ses modeli").await?;
            }
        }
        // large-v3-turbo: Türkçede en doğrusu (~3 sn); "otomatik" kipte hızlı modelin emin olmadığı
        // cümlelerde ve "sesle yaz"da kullanılır.
        let turbo = models.join("whisper").join("large-v3-turbo");
        for f in ["config.json", "preprocessor_config.json", "tokenizer.json", "vocabulary.json", "model.bin"] {
            let dest = turbo.join(f);
            if !dest.is_file() {
                let url = format!("https://huggingface.co/mobiuslabsgmbh/faster-whisper-large-v3-turbo/resolve/main/{f}");
                self.download("voice", &url, &dest, "Whisper large-v3-turbo").await?;
            }
        }
        // GPU motoru isteğe bağlıdır: kurulamazsa yalnızca uyarılır, konuşma tanıma işlemcide çalışır.
        if let Err(e) = self.fetch_whisper_gpu().await {
            tracing::warn!("GPU konuşma tanıma kurulamadı (işlemci kullanılacak): {e}");
        }
        // base: hızlı yedek; small: canlı sohbetin hızlı modeli (~1 sn).
        for size in ["base", "small"] {
            let wdir = models.join("whisper").join(size);
            for f in ["config.json", "tokenizer.json", "vocabulary.txt", "model.bin"] {
                let dest = wdir.join(f);
                if !dest.is_file() {
                    let url = format!("https://huggingface.co/Systran/faster-whisper-{size}/resolve/main/{f}");
                    self.download("voice", &url, &dest, &format!("Whisper {size}")).await?;
                }
            }
        }
        Ok(())
    }

    /// whisper.cpp GPU sunucusu (SHA-256 doğrulamalı) ve ggml Whisper large-v3-turbo modeli.
    async fn fetch_whisper_gpu(&self) -> anyhow::Result<()> {
        let asset = if cfg!(all(windows, target_arch = "x86_64")) {
            "whisper-vulkan-windows-x64.zip"
        } else if cfg!(all(target_os = "linux", target_arch = "x86_64")) {
            "whisper-vulkan-linux-x64.tar.gz"
        } else if cfg!(all(target_os = "macos", target_arch = "aarch64")) {
            "whisper-metal-macos-arm64.tar.gz"
        } else {
            return Ok(());
        };
        let dest = self.paths.tools().join("whisper");
        let exe = dest.join(if cfg!(windows) { "whisper-server.exe" } else { "whisper-server" });
        if !exe.is_file() {
            let file = self.paths.cache().join(asset);
            self.download("voice", &format!("{WHISPER_GPU_RELEASE}/{asset}"), &file, "GPU konuşma tanıma (whisper.cpp)").await?;
            let sums = self
                .http
                .get(format!("{WHISPER_GPU_RELEASE}/{asset}.sha256"))
                .send()
                .await?
                .error_for_status()?
                .text()
                .await?;
            let expected = sums.split_whitespace().next().unwrap_or_default().to_lowercase();
            let f = file.clone();
            let actual = tokio::task::spawn_blocking(move || sha256_file(&f)).await??;
            if expected.len() != 64 || actual != expected {
                let _ = tokio::fs::remove_file(&file).await;
                anyhow::bail!("whisper.cpp paketi doğrulanamadı (SHA-256 uyuşmuyor)");
            }
            let (f, d) = (file.clone(), dest.clone());
            tokio::task::spawn_blocking(move || extract_archive(&f, &d)).await??;
            let _ = tokio::fs::remove_file(&file).await;
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let _ = std::fs::set_permissions(&exe, std::fs::Permissions::from_mode(0o755));
            }
        }
        let model = self.paths.voice().join("models").join("whisper-ggml").join(crate::voice::GGML_STT_MODEL);
        if !model.is_file() {
            let url = format!("https://huggingface.co/ggerganov/whisper.cpp/resolve/main/{}", crate::voice::GGML_STT_MODEL);
            self.download("voice", &url, &model, "Whisper large-v3-turbo (GPU)").await?;
            let m = model.clone();
            if tokio::task::spawn_blocking(move || sha256_file(&m)).await?? != GGML_STT_SHA256 {
                let _ = tokio::fs::remove_file(&model).await;
                anyhow::bail!("Whisper GPU modeli doğrulanamadı (SHA-256 uyuşmuyor)");
            }
        }
        Ok(())
    }

    // ------------------------------------------------------------------ WebView2
    async fn install_webview2(&self) -> anyhow::Result<String> {
        if !cfg!(windows) {
            return Ok("Gerekmiyor.".into());
        }
        let file = self.paths.cache().join("MicrosoftEdgeWebview2Setup.exe");
        self.download("webview2", "https://go.microsoft.com/fwlink/p/?LinkId=2124703", &file, "WebView2").await?;
        let mut c = crate::proc::command(&self.paths, &file.to_string_lossy(), &["/silent".into(), "/install".into()]);
        let (code, _, _, _) = crate::proc::run_capture(&mut c, Duration::from_secs(900)).await?;
        let _ = tokio::fs::remove_file(&file).await;
        if code != Some(0) && webview2_version().is_none() {
            anyhow::bail!("WebView2 kurulamadı (çıkış kodu {code:?}).");
        }
        Ok("WebView2 kuruldu.".into())
    }

    // ------------------------------------------------------------------ yönetici betiği
    /// Yönetici gerektiren işleri tek betikte toplar ve tek onayla çalıştırır.
    pub async fn run_admin_batch(&self, ids: &[String]) -> anyhow::Result<String> {
        let ids: Vec<String> = ids.iter().filter(|i| !self.state().admin_done.contains(i)).cloned().collect();
        if ids.is_empty() {
            return Ok("Yönetici gerektiren iş yok.".into());
        }
        if cfg!(windows) {
            let mut script = String::from("$ErrorActionPreference='Continue'\n$log=@()\n");
            if ids.iter().any(|i| i == "vcredist") {
                let f = self.paths.cache().join("vc_redist.x64.exe");
                let url = if std::env::consts::ARCH == "aarch64" {
                    "https://aka.ms/vs/17/release/vc_redist.arm64.exe"
                } else {
                    "https://aka.ms/vs/17/release/vc_redist.x64.exe"
                };
                self.download("admin", url, &f, "Visual C++ çalışma zamanı").await?;
                script.push_str(&format!(
                    "$p = Start-Process -FilePath '{}' -ArgumentList '/install','/quiet','/norestart' -Wait -PassThru\n$log += \"vcredist=$($p.ExitCode)\"\n",
                    ps_quote(&f.to_string_lossy())
                ));
            }
            if ids.iter().any(|i| i == "longpaths") {
                script.push_str("New-ItemProperty -Path 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\FileSystem' -Name 'LongPathsEnabled' -Value 1 -PropertyType DWORD -Force | Out-Null\n$log += 'longpaths=0'\n");
            }
            let result = self.paths.run().join("admin-result.txt");
            let _ = std::fs::remove_file(&result);
            script.push_str(&format!("$log -join \"`n\" | Out-File -Encoding utf8 '{}'\n", ps_quote(&result.to_string_lossy())));
            let script_file = self.paths.run().join("feride-admin.ps1");
            std::fs::write(&script_file, script.as_bytes())?;
            self.progress("admin", "Yönetici onayı bekleniyor (tek seferlik)", 0, 0);
            let launcher = format!(
                "try {{ $p = Start-Process powershell -Verb RunAs -WindowStyle Hidden -Wait -PassThru -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','\"{}\"'; exit $p.ExitCode }} catch {{ exit 1223 }}",
                ps_quote(&script_file.to_string_lossy())
            );
            let mut c = crate::proc::command(
                &self.paths,
                "powershell.exe",
                &["-NoProfile".into(), "-NonInteractive".into(), "-Command".into(), launcher],
            );
            let (code, _, _, _) = crate::proc::run_capture(&mut c, Duration::from_secs(1800)).await?;
            let _ = std::fs::remove_file(&script_file);
            if code == Some(1223) {
                self.update_state(|s| s.admin_declined_at = Some(crate::util::now_iso()));
                anyhow::bail!("Yönetici izni verilmedi. İsterseniz Ayarlar > Kurulum'dan daha sonra tekrar deneyebilirsiniz.");
            }
            let out = std::fs::read_to_string(&result).unwrap_or_default();
            let _ = std::fs::remove_file(&result);
            self.update_state(|s| {
                for i in &ids {
                    if !s.admin_done.contains(i) {
                        s.admin_done.push(i.clone());
                    }
                }
            });
            Ok(format!("Yönetici adımları tamamlandı. {}", out.trim().replace('\n', ", ")))
        } else if cfg!(target_os = "linux") {
            let pm = linux_package_command(&ids).ok_or_else(|| anyhow::anyhow!("Paket yöneticisi bulunamadı (apt/dnf/pacman/zypper)."))?;
            self.progress("admin", "Yönetici parolası isteniyor (tek seferlik)", 0, 0);
            let mut c = crate::proc::command(&self.paths, "pkexec", &["sh".into(), "-c".into(), pm]);
            let (code, out, err, _) = crate::proc::run_capture(&mut c, Duration::from_secs(1800)).await?;
            if code == Some(126) || code == Some(127) {
                anyhow::bail!("Yönetici izni verilmedi.");
            }
            if code != Some(0) {
                anyhow::bail!("Sistem paketleri kurulamadı: {out}{err}");
            }
            self.update_state(|s| s.admin_done.extend(ids.clone()));
            Ok("Sistem paketleri kuruldu.".into())
        } else {
            Ok("Bu platformda yönetici adımı gerekmiyor.".into())
        }
    }
}

fn ps_quote(s: &str) -> String {
    s.replace('\'', "''")
}

#[allow(unused_variables)]
fn linux_package_command(ids: &[String]) -> Option<String> {
    let want_git = ids.iter().any(|i| i == "git");
    let want_vk = ids.iter().any(|i| i == "vulkan");
    let has = |p: &str| Path::new(p).exists();
    let (cmd, git, vk) = if has("/usr/bin/apt-get") {
        ("apt-get update && apt-get install -y", "git", "libvulkan1 mesa-vulkan-drivers")
    } else if has("/usr/bin/dnf") {
        ("dnf install -y", "git", "vulkan-loader mesa-vulkan-drivers")
    } else if has("/usr/bin/pacman") {
        ("pacman -S --needed --noconfirm", "git", "vulkan-icd-loader vulkan-radeon vulkan-intel")
    } else if has("/usr/bin/zypper") {
        ("zypper --non-interactive install", "git", "libvulkan1 Mesa-vulkan-device-select")
    } else {
        return None;
    };
    let mut pkgs = vec![];
    if want_git {
        pkgs.push(git);
    }
    if want_vk {
        pkgs.push(vk);
    }
    Some(format!("{cmd} {}", pkgs.join(" ")))
}

pub fn find_file(dir: &Path, name: &str) -> Option<PathBuf> {
    ignore::WalkBuilder::new(dir)
        .standard_filters(false)
        .max_depth(Some(6))
        .build()
        .flatten()
        .find(|e| e.file_name().to_string_lossy() == name)
        .map(|e| e.path().to_path_buf())
}

/// zip / tar.gz arşivini açar. Arşiv dışına yazma ("zip slip") engellenir.
pub fn extract_archive(file: &Path, dest: &Path) -> anyhow::Result<()> {
    std::fs::create_dir_all(dest)?;
    let name = file.to_string_lossy().to_lowercase();
    if name.ends_with(".zip") {
        let mut z = zip::ZipArchive::new(std::fs::File::open(file)?)?;
        for i in 0..z.len() {
            let mut entry = z.by_index(i)?;
            let Some(rel) = entry.enclosed_name() else { continue };
            let out = dest.join(rel);
            if entry.is_dir() {
                std::fs::create_dir_all(&out)?;
                continue;
            }
            if let Some(p) = out.parent() {
                std::fs::create_dir_all(p)?;
            }
            let mut f = std::fs::File::create(&out)?;
            std::io::copy(&mut entry, &mut f)?;
            #[cfg(unix)]
            if let Some(mode) = entry.unix_mode() {
                use std::os::unix::fs::PermissionsExt;
                let _ = std::fs::set_permissions(&out, std::fs::Permissions::from_mode(mode));
            }
        }
        Ok(())
    } else if name.ends_with(".tar.gz") || name.ends_with(".tgz") {
        let gz = flate2::read::GzDecoder::new(std::fs::File::open(file)?);
        let mut ar = tar::Archive::new(gz);
        ar.set_preserve_permissions(true);
        for entry in ar.entries()? {
            let mut e = entry?;
            // unpack_in, ".." ve mutlak yolları reddeder.
            e.unpack_in(dest)?;
        }
        Ok(())
    } else {
        anyhow::bail!("Desteklenmeyen arşiv: {}", file.display())
    }
}

pub fn sha256_file(path: &Path) -> anyhow::Result<String> {
    use sha2::{Digest, Sha256};
    use std::io::Read;
    let mut f = std::fs::File::open(path)?;
    let mut h = Sha256::new();
    let mut buf = vec![0u8; 1 << 20];
    loop {
        let n = f.read(&mut buf)?;
        if n == 0 {
            break;
        }
        h.update(&buf[..n]);
    }
    Ok(hex::encode(h.finalize()))
}

#[cfg(windows)]
fn reg_query(key: &str, value: &str) -> Option<String> {
    let out = std::process::Command::new("reg")
        .args(["query", key, "/v", value])
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .creation_flags_compat()
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let s = String::from_utf8_lossy(&out.stdout);
    s.lines()
        .find(|l| l.trim_start().starts_with(value))
        .and_then(|l| l.split_whitespace().last())
        .map(|v| v.to_string())
}

#[cfg(windows)]
trait NoWindow {
    fn creation_flags_compat(&mut self) -> &mut Self;
}
#[cfg(windows)]
impl NoWindow for std::process::Command {
    fn creation_flags_compat(&mut self) -> &mut Self {
        use std::os::windows::process::CommandExt;
        self.creation_flags(0x0800_0000)
    }
}

pub fn webview2_version() -> Option<String> {
    #[cfg(windows)]
    {
        const ID: &str = "{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}";
        for k in [
            format!("HKLM\\SOFTWARE\\WOW6432Node\\Microsoft\\EdgeUpdate\\Clients\\{ID}"),
            format!("HKLM\\SOFTWARE\\Microsoft\\EdgeUpdate\\Clients\\{ID}"),
            format!("HKCU\\Software\\Microsoft\\EdgeUpdate\\Clients\\{ID}"),
        ] {
            if let Some(v) = reg_query(&k, "pv").filter(|v| v != "0.0.0.0") {
                return Some(v);
            }
        }
        None
    }
    #[cfg(not(windows))]
    None
}

pub fn vcruntime_installed() -> bool {
    #[cfg(windows)]
    {
        let sys = std::env::var_os("SystemRoot").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("C:\\Windows"));
        ["vcruntime140.dll", "vcruntime140_1.dll", "msvcp140.dll"].iter().all(|d| sys.join("System32").join(d).is_file())
    }
    #[cfg(not(windows))]
    true
}

pub fn long_paths_enabled() -> bool {
    #[cfg(windows)]
    {
        reg_query("HKLM\\SYSTEM\\CurrentControlSet\\Control\\FileSystem", "LongPathsEnabled")
            .map(|v| v == "0x1")
            .unwrap_or(false)
    }
    #[cfg(not(windows))]
    true
}

fn linux_has_vulkan() -> bool {
    ["/usr/lib/x86_64-linux-gnu/libvulkan.so.1", "/usr/lib64/libvulkan.so.1", "/usr/lib/libvulkan.so.1", "/usr/lib/aarch64-linux-gnu/libvulkan.so.1"]
        .iter()
        .any(|p| Path::new(p).exists())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn a(n: &str) -> Asset {
        Asset { name: n.into(), browser_download_url: format!("https://x/{n}"), size: 1 }
    }

    fn assets() -> Vec<Asset> {
        [
            "cudart-llama-bin-win-cuda-12.4-x64.zip",
            "cudart-llama-bin-win-cuda-13.5-x64.zip",
            "llama-b12244-bin-macos-arm64.tar.gz",
            "llama-b12244-bin-ubuntu-vulkan-x64.tar.gz",
            "llama-b12244-bin-ubuntu-x64.tar.gz",
            "llama-b12244-bin-ubuntu-rocm-10.0-x64.tar.gz",
            "llama-b12244-bin-win-cpu-x64.zip",
            "llama-b12244-bin-win-cuda-12.4-x64.zip",
            "llama-b12244-bin-win-cuda-13.5-x64.zip",
            "llama-b12244-bin-win-vulkan-x64.zip",
            "llama-b12244-bin-win-vulkan-arm64.zip",
            "llama-b12244-bin-win-rocm-10.0-x64.zip",
            "llama-b12244-bin-linux-arm64-snapdragon.tar.gz",
        ]
        .iter()
        .map(|n| a(n))
        .collect()
    }

    #[test]
    fn picks_assets() {
        let v = pick_llama_assets(&assets(), "windows", "x86_64", "vulkan");
        assert_eq!(v[0].name, "llama-b12244-bin-win-vulkan-x64.zip");
        let c = pick_llama_assets(&assets(), "windows", "x86_64", "cuda");
        assert_eq!(c.len(), 2);
        assert_eq!(c[0].name, "llama-b12244-bin-win-cuda-12.4-x64.zip");
        assert_eq!(c[1].name, "cudart-llama-bin-win-cuda-12.4-x64.zip");
        assert_eq!(pick_llama_assets(&assets(), "windows", "x86_64", "cpu")[0].name, "llama-b12244-bin-win-cpu-x64.zip");
        assert_eq!(pick_llama_assets(&assets(), "linux", "x86_64", "vulkan")[0].name, "llama-b12244-bin-ubuntu-vulkan-x64.tar.gz");
        assert_eq!(pick_llama_assets(&assets(), "linux", "x86_64", "cpu")[0].name, "llama-b12244-bin-ubuntu-x64.tar.gz");
        assert_eq!(pick_llama_assets(&assets(), "macos", "aarch64", "metal")[0].name, "llama-b12244-bin-macos-arm64.tar.gz");
        assert_eq!(pick_llama_assets(&assets(), "windows", "aarch64", "vulkan")[0].name, "llama-b12244-bin-win-vulkan-arm64.zip");
    }

    #[test]
    fn zip_slip_blocked() {
        use std::io::Write;
        let dir = tempfile::tempdir().unwrap();
        let zpath = dir.path().join("t.zip");
        {
            let f = std::fs::File::create(&zpath).unwrap();
            let mut z = zip::ZipWriter::new(f);
            let o: zip::write::SimpleFileOptions = Default::default();
            z.start_file("../kotu.txt", o).unwrap();
            z.write_all(b"x").unwrap();
            z.start_file("iyi/a.txt", o).unwrap();
            z.write_all(b"y").unwrap();
            z.finish().unwrap();
        }
        let out = dir.path().join("out");
        extract_archive(&zpath, &out).unwrap();
        assert!(out.join("iyi").join("a.txt").is_file());
        assert!(!dir.path().join("kotu.txt").exists());
    }
}
