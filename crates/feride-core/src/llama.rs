//! llama-server yaşam döngüsü.
//!
//! * Aynı anda tek model; başlatma/durdurma sıralı (çift başlatma olmaz).
//! * Önce bellek ölçülür ve plan yapılır; sığmayan yapılandırma başlatılmaz.
//! * Süreç İş Nesnesi'ne bağlıdır: FerIDE kapanınca model de kapanır, GPU belleği boşalır.
//! * Çökme nedeni günlükten Türkçe açıklanır.

use regex::Regex;
use serde::Serialize;
use std::collections::{BTreeSet, HashMap, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::{Arc, LazyLock, Mutex};
use std::time::{Duration, Instant};
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::sync::watch;

use crate::config::{ComputeMode, Settings};
use crate::events::EventBus;
use crate::gguf::{self, GgufInfo};
use crate::hardware::{self, HardwareInfo};
use crate::paths::Paths;
use crate::planner::{self, LaunchPlan, PlanInput};
use crate::proc::{self, KillHandle};

#[derive(Clone, Debug, Serialize)]
pub struct LocalModel {
    pub path: PathBuf,
    pub name: String,
    pub size_bytes: u64,
    pub parts: usize,
    pub mmproj: Option<PathBuf>,
    pub quant: String,
    pub folder: PathBuf,
}

#[derive(Clone, Debug, Serialize, Default, PartialEq)]
pub struct ModelStatus {
    /// idle | starting | ready | failed | stopping
    pub state: String,
    pub model_path: Option<PathBuf>,
    pub model_name: Option<String>,
    pub port: Option<u16>,
    pub base_url: Option<String>,
    pub ctx: Option<i64>,
    pub placement: Option<String>,
    pub summary: Option<String>,
    pub warnings: Vec<String>,
    pub error: Option<String>,
    pub vision: bool,
    pub started_at: Option<String>,
    pub load_seconds: Option<f64>,
    pub mmproj: Option<PathBuf>,
}

static QUANT_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)\b((?:UD-)?(?:I?Q\d(?:_[A-Z0-9]+)*|F16|BF16|F32|MXFP4))\b").unwrap());
static PARAM_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)(\d+(?:\.\d+)?)b\b").unwrap());

/// Model klasörlerindeki GGUF dosyalarını listeler (bölünmüş modeller tek kayıt; mmproj hariç).
pub fn scan_models(dirs: &[PathBuf]) -> Vec<LocalModel> {
    let mut out: Vec<LocalModel> = vec![];
    let mut seen = BTreeSet::new();
    for dir in dirs {
        let walker = ignore::WalkBuilder::new(dir).max_depth(Some(3)).standard_filters(false).build();
        for e in walker.flatten() {
            let p = e.path();
            let Some(name) = p.file_name().map(|n| n.to_string_lossy().to_string()) else { continue };
            if !name.to_lowercase().ends_with(".gguf") || name.to_lowercase().contains("mmproj") {
                continue;
            }
            if p.components().any(|c| c.as_os_str().to_string_lossy().eq_ignore_ascii_case("mmproj")) {
                continue;
            }
            if gguf::is_split_secondary(p) || name.ends_with(".part") {
                continue;
            }
            let key = p.to_string_lossy().to_lowercase();
            if !seen.insert(key) {
                continue;
            }
            let parts = gguf::split_parts(p);
            let size = parts.iter().filter_map(|x| std::fs::metadata(x).ok()).map(|m| m.len()).sum();
            let base = gguf::base_name(p);
            let quant = QUANT_RE.captures(&base).map(|c| c[1].to_uppercase()).unwrap_or_default();
            out.push(LocalModel {
                path: p.to_path_buf(),
                name: base,
                size_bytes: size,
                parts: parts.len(),
                mmproj: None,
                quant,
                folder: dir.clone(),
            });
        }
    }
    let mmproj_dirs: Vec<PathBuf> = dirs.to_vec();
    for m in &mut out {
        m.mmproj = find_mmproj(&m.path, &mmproj_dirs);
    }
    out.sort_by_key(|a| a.name.to_lowercase());
    out
}

fn norm(s: &str) -> String {
    s.to_lowercase().chars().filter(|c| c.is_alphanumeric()).collect()
}

/// Modele uygun görsel adaptörünü (mmproj) bulur: en uzun ortak ad + aynı parametre boyutu.
pub fn find_mmproj(model: &Path, dirs: &[PathBuf]) -> Option<PathBuf> {
    let model_base = gguf::base_name(model);
    let mnorm = norm(&model_base);
    let mparam = PARAM_RE.captures(&model_base).map(|c| c[1].to_string());
    let mut cands: Vec<PathBuf> = vec![];
    for d in dirs {
        for sub in [d.join("mmproj"), d.clone(), model.parent().map(|p| p.to_path_buf()).unwrap_or_default()] {
            if let Ok(rd) = std::fs::read_dir(&sub) {
                for e in rd.flatten() {
                    let n = e.file_name().to_string_lossy().to_lowercase();
                    if n.contains("mmproj") && n.ends_with(".gguf") {
                        cands.push(e.path());
                    }
                }
            }
        }
    }
    cands.sort();
    cands.dedup();
    let mut best: Option<(usize, PathBuf)> = None;
    for c in cands {
        let fname = c.file_name().unwrap().to_string_lossy().to_string();
        // FerIDE adlandırması: "<model>__mmproj-….gguf" → ön ek modelle eşleşmeli.
        let prefix = fname.split("__").next().unwrap_or(&fname);
        let prefix = prefix.split("mmproj").next().unwrap_or(prefix);
        let pnorm = norm(prefix);
        if pnorm.is_empty() {
            continue;
        }
        if let (Some(mp), Some(cp)) = (&mparam, PARAM_RE.captures(prefix).map(|c| c[1].to_string())) {
            if mp != &cp {
                continue;
            }
        }
        let common = mnorm.chars().zip(pnorm.chars()).take_while(|(a, b)| a == b).count();
        let score = if mnorm.starts_with(&pnorm) || pnorm.starts_with(&mnorm) { common + 100 } else { common };
        if common >= 6 && best.as_ref().map(|(s, _)| score > *s).unwrap_or(true) {
            best = Some((score, c));
        }
    }
    best.map(|b| b.1)
}

/// Başarısız başlatmanın nedenini günlükten Türkçe açıklar.
pub fn explain_failure(log: &str, exit_code: Option<i32>) -> String {
    let l = log.to_lowercase();
    if let Some(code) = exit_code {
        match code as u32 {
            0xC000_0135 => {
                return "llama-server başlatılamadı: gerekli bir DLL bulunamadı. Microsoft Visual C++ çalışma zamanı \
                        eksik olabilir. Ayarlar > Kurulum'dan \"Eksikleri kur\" deyin."
                    .into()
            }
            0xC000_001D => {
                return "İşlemci bu llama.cpp derlemesindeki komut setini desteklemiyor. Kurulum'dan \"CPU\" derlemesini \
                        seçip llama.cpp'yi yeniden kurun."
                    .into()
            }
            0xC000_0409 | 0xC000_0005
                if !l.contains("out of memory") => {
                    return "llama-server beklenmedik şekilde çöktü (bellek erişim hatası). Ekran kartı sürücüsünü \
                            güncelleyin veya \"Yalnızca CPU\" modunu deneyin."
                        .into();
                }
            _ => {}
        }
    }
    if l.contains("out of memory") || l.contains("erroroutofdevicememory") || l.contains("failed to allocate") || l.contains("unable to allocate") {
        return "Bellek yetersiz: model ve bağlam GPU/RAM'e sığmadı. Bağlamı küçültün, \"CPU offload\" modunu seçin ya da \
                daha düşük kuantize bir model kullanın."
            .into();
    }
    if l.contains("unknown model architecture") || l.contains("unknown architecture") {
        return "Bu model mimarisi kurulu llama.cpp sürümünde desteklenmiyor. Kurulum'dan llama.cpp'yi güncelleyin.".into();
    }
    if l.contains("address already in use") || l.contains("couldn't bind") || l.contains("failed to bind") {
        return "Port kullanımda: başka bir program aynı portu tutuyor.".into();
    }
    if l.contains("error loading model") || l.contains("failed to load model") || l.contains("invalid magic") {
        return "Model dosyası açılamadı: dosya eksik inmiş, bozuk ya da desteklenmeyen bir biçimde olabilir.".into();
    }
    if l.contains("vk::") || l.contains("vulkan") && l.contains("error") {
        return "Vulkan hatası: ekran kartı sürücüsünü güncelleyin veya \"Yalnızca CPU\" modunu deneyin.".into();
    }
    let tail: Vec<&str> = log.lines().rev().filter(|x| !x.trim().is_empty()).take(4).collect();
    format!(
        "Model sunucusu başlatılamadı{}. Son satırlar:\n{}",
        exit_code.map(|c| format!(" (çıkış kodu {c})")).unwrap_or_default(),
        tail.into_iter().rev().collect::<Vec<_>>().join("\n")
    )
}

struct Inner {
    kill: Option<KillHandle>,
    generation: u64,
}

pub struct LlamaManager {
    paths: Paths,
    events: EventBus,
    inner: Mutex<Inner>,
    status_tx: watch::Sender<ModelStatus>,
    op: tokio::sync::Mutex<()>,
    log: Mutex<VecDeque<String>>,
    hw_cache: Mutex<Option<(Instant, HardwareInfo)>>,
    flags_cache: Mutex<HashMap<String, BTreeSet<String>>>,
    http: reqwest::Client,
}

pub struct StartRequest {
    pub model: PathBuf,
    pub mode: ComputeMode,
    pub ctx: u32,
}

impl LlamaManager {
    pub fn new(paths: Paths, events: EventBus) -> Self {
        let (status_tx, _) = watch::channel(ModelStatus { state: "idle".into(), ..Default::default() });
        Self {
            paths,
            events,
            inner: Mutex::new(Inner { kill: None, generation: 0 }),
            status_tx,
            op: tokio::sync::Mutex::new(()),
            log: Mutex::new(VecDeque::with_capacity(500)),
            hw_cache: Mutex::new(None),
            flags_cache: Mutex::new(HashMap::new()),
            http: reqwest::Client::builder().timeout(Duration::from_secs(5)).build().unwrap(),
        }
    }

    pub fn status(&self) -> ModelStatus {
        self.status_tx.borrow().clone()
    }

    pub fn subscribe(&self) -> watch::Receiver<ModelStatus> {
        self.status_tx.subscribe()
    }

    pub fn logs(&self) -> Vec<String> {
        self.log.lock().unwrap().iter().cloned().collect()
    }

    fn set_status(&self, s: ModelStatus) {
        self.events.emit_ser("model.status", &s);
        self.status_tx.send_replace(s);
    }

    fn push_log(&self, line: String) {
        {
            let mut l = self.log.lock().unwrap();
            if l.len() >= 500 {
                l.pop_front();
            }
            l.push_back(line.clone());
        }
        self.events.emit("model.log", serde_json::json!({ "line": line }));
    }

    pub fn model_dirs(&self, settings: &Settings) -> Vec<PathBuf> {
        let mut d = vec![self.paths.models()];
        d.extend(settings.model.extra_dirs.iter().filter(|p| p.is_dir()).cloned());
        d
    }

    /// Donanım bilgisi (20 sn önbellekli; model yüklüyken GPU boşluğu değişir).
    pub async fn hardware(&self, server: Option<&Path>, fresh: bool) -> HardwareInfo {
        if !fresh {
            if let Some((t, h)) = self.hw_cache.lock().unwrap().as_ref() {
                if t.elapsed() < Duration::from_secs(20) {
                    return h.clone();
                }
            }
        }
        let h = hardware::probe(&self.paths, server).await;
        *self.hw_cache.lock().unwrap() = Some((Instant::now(), h.clone()));
        h
    }

    pub async fn flags(&self, server: &Path) -> BTreeSet<String> {
        let key = format!(
            "{}:{:?}",
            server.display(),
            std::fs::metadata(server).and_then(|m| m.modified()).ok()
        );
        if let Some(f) = self.flags_cache.lock().unwrap().get(&key) {
            return f.clone();
        }
        let f = hardware::llama_flags(&self.paths, server).await;
        if !f.is_empty() {
            self.flags_cache.lock().unwrap().insert(key, f.clone());
        }
        f
    }

    /// Başlatmadan önce planı gösterir (Model Merkezi'ndeki "Plan" düğmesi).
    pub async fn preview_plan(&self, settings: &Settings, req: &StartRequest) -> anyhow::Result<(LaunchPlan, Option<GgufInfo>, HardwareInfo)> {
        let server = crate::deps::find_llama_server(&self.paths, settings)
            .ok_or_else(|| anyhow::anyhow!("llama.cpp kurulu değil. Kurulum sihirbazından kurun."))?;
        let model = req.model.clone();
        let t0 = Instant::now();
        let info = tokio::task::spawn_blocking(move || gguf::read(&model)).await?;
        let t_gguf = t0.elapsed();
        let hw = self.hardware(Some(&server), true).await;
        let t_hw = t0.elapsed();
        let flags = self.flags(&server).await;
        tracing::debug!(
            "plan süreleri: gguf {:.2} sn, donanım {:.2} sn, bayraklar {:.2} sn ({} bayrak)",
            t_gguf.as_secs_f64(),
            (t_hw - t_gguf).as_secs_f64(),
            (t0.elapsed() - t_hw).as_secs_f64(),
            flags.len()
        );
        let size = gguf::split_parts(&req.model).iter().filter_map(|p| std::fs::metadata(p).ok()).map(|m| m.len()).sum::<u64>();
        let mmproj_extra = find_mmproj(&req.model, &self.model_dirs(settings))
            .and_then(|m| std::fs::metadata(m).ok())
            .map(|m| m.len() as i64)
            .unwrap_or(0);
        let plan = planner::plan(PlanInput {
            model_bytes: size as i64,
            info: info.as_ref(),
            hw: &hw,
            mode: req.mode,
            requested_ctx: req.ctx as i64,
            extra_gpu_bytes: mmproj_extra,
            flags: &flags,
        });
        Ok((plan, info, hw))
    }

    pub async fn start(self: &Arc<Self>, settings: &Settings, req: StartRequest) -> anyhow::Result<ModelStatus> {
        let _op = self.op.lock().await;
        let cur = self.status();
        if cur.model_path.as_deref() == Some(req.model.as_path()) && (cur.state == "ready" || cur.state == "starting") {
            return Ok(cur);
        }
        self.stop_locked().await;

        if !req.model.is_file() {
            let s = ModelStatus {
                state: "failed".into(),
                error: Some(format!("Model dosyası bulunamadı: {}", req.model.display())),
                ..Default::default()
            };
            self.set_status(s.clone());
            anyhow::bail!(s.error.unwrap());
        }
        let name = gguf::base_name(&req.model);
        self.set_status(ModelStatus {
            state: "starting".into(),
            model_path: Some(req.model.clone()),
            model_name: Some(name.clone()),
            summary: Some("Bellek ölçülüyor ve plan yapılıyor…".into()),
            ..Default::default()
        });

        let server = match crate::deps::find_llama_server(&self.paths, settings) {
            Some(s) => s,
            None => {
                let msg = "llama.cpp (llama-server) kurulu değil. Ayarlar > Kurulum'dan kurun.".to_string();
                self.fail(&req.model, &name, &msg, vec![]);
                anyhow::bail!(msg);
            }
        };
        let (plan, _info, _hw) = match self.preview_plan(settings, &req).await {
            Ok(x) => x,
            Err(e) => {
                self.fail(&req.model, &name, &e.to_string(), vec![]);
                return Err(e);
            }
        };
        if let Some(b) = &plan.blocker {
            self.fail(&req.model, &name, b, plan.warnings.clone());
            anyhow::bail!(b.clone());
        }
        let flags = self.flags(&server).await;
        let has = |f: &str| flags.is_empty() || flags.contains(f);
        let mmproj = find_mmproj(&req.model, &self.model_dirs(settings));
        let port = free_port().ok_or_else(|| anyhow::anyhow!("boş port bulunamadı"))?;

        let mut args: Vec<String> = vec!["-m".into(), req.model.to_string_lossy().into()];
        args.extend(plan.args.clone());
        args.extend(["-np".into(), "1".into(), "--host".into(), "127.0.0.1".into(), "--port".into(), port.to_string()]);
        if has("--flash-attn") {
            args.extend(["-fa".into(), "on".into()]);
        }
        args.extend(["-ctk".into(), "q8_0".into(), "-ctv".into(), "q8_0".into(), "-b".into(), "2048".into()]);
        args.extend(["-ub".into(), if plan.placement == "cpu" { "512".into() } else { "2048".into() }]);
        if has("--cache-reuse") {
            args.extend(["--cache-reuse".into(), "256".into()]);
        }
        if has("--jinja") {
            args.push("--jinja".into());
        }
        if has("--no-webui") {
            args.push("--no-webui".into());
        }
        if has("--alias") {
            args.extend(["--alias".into(), name.clone()]);
        }
        if let Some(m) = &mmproj {
            args.extend(["--mmproj".into(), m.to_string_lossy().into()]);
        }

        self.log.lock().unwrap().clear();
        self.push_log(format!("$ {} {}", server.display(), args.join(" ")));
        let mut cmd = proc::command(&self.paths, &server.to_string_lossy(), &args);
        if let Some(dir) = server.parent() {
            cmd.current_dir(dir);
        }
        cmd.stdout(std::process::Stdio::piped()).stderr(std::process::Stdio::piped());
        let (mut child, kill) = match proc::spawn(&mut cmd) {
            Ok(x) => x,
            Err(e) => {
                let msg = format!("llama-server çalıştırılamadı: {e}");
                self.fail(&req.model, &name, &msg, vec![]);
                anyhow::bail!(msg);
            }
        };
        let generation = {
            let mut g = self.inner.lock().unwrap();
            g.generation += 1;
            g.kill = Some(kill.clone());
            g.generation
        };
        // Günlükleri oku.
        if let Some(out) = child.stdout.take() {
            let me = Arc::clone(self);
            tokio::spawn(async move {
                let mut lines = BufReader::new(out).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    me.push_log(line);
                }
            });
        }
        if let Some(err) = child.stderr.take() {
            let me = Arc::clone(self);
            tokio::spawn(async move {
                let mut lines = BufReader::new(err).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    me.push_log(line);
                }
            });
        }
        let started = Instant::now();
        let base_url = format!("http://127.0.0.1:{port}");
        self.set_status(ModelStatus {
            state: "starting".into(),
            model_path: Some(req.model.clone()),
            model_name: Some(name.clone()),
            port: Some(port),
            base_url: Some(format!("{base_url}/v1")),
            ctx: Some(plan.ctx),
            placement: Some(plan.placement.clone()),
            summary: Some(plan.summary.clone()),
            warnings: plan.warnings.clone(),
            mmproj: mmproj.clone(),
            ..Default::default()
        });

        // Sağlık denetimi: büyük modeller için daha uzun bekle (60 sn + GB başına 10 sn).
        let size_gb = gguf::split_parts(&req.model).iter().filter_map(|p| std::fs::metadata(p).ok()).map(|m| m.len()).sum::<u64>() >> 30;
        let deadline = Duration::from_secs(90 + size_gb * 10);
        let ready = loop {
            if let Ok(Some(status)) = child.try_wait() {
                tokio::time::sleep(Duration::from_millis(200)).await;
                let msg = explain_failure(&self.logs().join("\n"), status.code());
                self.fail(&req.model, &name, &msg, plan.warnings.clone());
                self.inner.lock().unwrap().kill = None;
                anyhow::bail!(msg);
            }
            if self.inner.lock().unwrap().generation != generation {
                anyhow::bail!("Başlatma iptal edildi.");
            }
            if let Ok(r) = self.http.get(format!("{base_url}/health")).send().await {
                if r.status().is_success() {
                    break true;
                }
            }
            if started.elapsed() > deadline {
                break false;
            }
            tokio::time::sleep(Duration::from_millis(500)).await;
        };
        if !ready {
            kill.kill_tree();
            let msg = format!(
                "Model {} saniyede yüklenemedi; başlatma iptal edildi.\n{}",
                deadline.as_secs(),
                explain_failure(&self.logs().join("\n"), None)
            );
            self.fail(&req.model, &name, &msg, plan.warnings.clone());
            anyhow::bail!(msg);
        }

        // Gerçek bağlam ve görsel desteği.
        let (mut ctx, mut vision) = (plan.ctx, mmproj.is_some());
        if let Ok(r) = self.http.get(format!("{base_url}/props")).send().await {
            if let Ok(j) = r.json::<serde_json::Value>().await {
                if let Some(n) = j["default_generation_settings"]["n_ctx"].as_i64().or(j["n_ctx"].as_i64()) {
                    ctx = n;
                }
                if let Some(v) = j["modalities"]["vision"].as_bool() {
                    vision = v;
                }
            }
        }
        let st = ModelStatus {
            state: "ready".into(),
            model_path: Some(req.model.clone()),
            model_name: Some(name.clone()),
            port: Some(port),
            base_url: Some(format!("{base_url}/v1")),
            ctx: Some(ctx),
            placement: Some(plan.placement.clone()),
            summary: Some(plan.summary.clone()),
            warnings: plan.warnings.clone(),
            vision,
            started_at: Some(crate::util::now_iso()),
            load_seconds: Some(started.elapsed().as_secs_f64()),
            mmproj: mmproj.clone(),
            error: None,
        };
        self.set_status(st.clone());
        self.hw_cache.lock().unwrap().take();

        // Beklenmedik kapanmayı izle.
        let me = Arc::clone(self);
        tokio::spawn(async move {
            let status = child.wait().await.ok();
            me.on_exit(generation, status.and_then(|s| s.code()));
        });
        Ok(st)
    }

    fn fail(&self, model: &Path, name: &str, msg: &str, warnings: Vec<String>) {
        tracing::warn!("model başlatılamadı: {msg}");
        self.set_status(ModelStatus {
            state: "failed".into(),
            model_path: Some(model.to_path_buf()),
            model_name: Some(name.to_string()),
            error: Some(msg.to_string()),
            warnings,
            ..Default::default()
        });
    }

    pub async fn stop(&self) {
        let _op = self.op.lock().await;
        self.stop_locked().await;
    }

    async fn stop_locked(&self) {
        let kill = {
            let mut g = self.inner.lock().unwrap();
            g.generation += 1;
            g.kill.take()
        };
        if let Some(k) = kill {
            let mut s = self.status();
            s.state = "stopping".into();
            self.set_status(s);
            k.kill_tree();
            // Portun ve belleğin boşalması için kısa bekleme.
            tokio::time::sleep(Duration::from_millis(600)).await;
        }
        let cur = self.status();
        if cur.state != "idle" {
            self.set_status(ModelStatus { state: "idle".into(), ..Default::default() });
        }
        self.hw_cache.lock().unwrap().take();
    }

    fn on_exit(&self, generation: u64, code: Option<i32>) {
        {
            let mut g = self.inner.lock().unwrap();
            if g.generation != generation {
                return; // bilerek durduruldu
            }
            g.kill = None;
        }
        let s = self.status();
        let logs = self.logs();
        let msg = format!("Model sunucusu beklenmedik şekilde kapandı. {}", explain_failure(&logs.join("\n"), code));
        // Yeniden başlatmada günlük sıfırlanır; nedeni kalıcı günlüğe de yaz.
        tracing::warn!(
            "llama-server kapandı (kod {code:?}): {}\n{}",
            s.model_name.as_deref().unwrap_or("?"),
            logs.iter().rev().take(25).rev().cloned().collect::<Vec<_>>().join("\n")
        );
        self.set_status(ModelStatus {
            state: "failed".into(),
            error: Some(msg),
            model_path: s.model_path,
            model_name: s.model_name,
            ..Default::default()
        });
    }

    /// Uygulama kapanırken: beklemeden öldür.
    pub fn shutdown(&self) {
        if let Some(k) = self.inner.lock().unwrap().kill.take() {
            k.kill_tree();
        }
    }
}

pub fn free_port() -> Option<u16> {
    std::net::TcpListener::bind("127.0.0.1:0").ok()?.local_addr().ok().map(|a| a.port())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mmproj_matching() {
        let dir = tempfile::tempdir().unwrap();
        let mm = dir.path().join("mmproj");
        std::fs::create_dir_all(&mm).unwrap();
        for f in [
            "Huihui-Qwen3.8-27B-abliterated__mmproj-model-bf16.gguf",
            "Qwen3.8-35B-A3B-Distill-MTP-APEX-I-MiniPlus-V2.1-Abliterated__mmproj-Q8_0.gguf",
            "gemma-4-12b-it__mmproj-F16.gguf",
        ] {
            std::fs::write(mm.join(f), b"x").unwrap();
        }
        let dirs = vec![dir.path().to_path_buf()];
        let q35 = find_mmproj(Path::new("Qwen3.8-35B-A3B-Distill.APEX-I-MiniPlus-V2.1-Abliterated.gguf"), &dirs).unwrap();
        assert!(q35.to_string_lossy().contains("35B"), "{q35:?}");
        let q27 = find_mmproj(Path::new("Huihui-Qwen3.8-27B-abliterated-UD-Q8_K_XL.gguf"), &dirs).unwrap();
        assert!(q27.to_string_lossy().contains("27B"));
        let g = find_mmproj(Path::new("gemma-4-12b-it-UD-Q8_K_XL.gguf"), &dirs).unwrap();
        assert!(g.to_string_lossy().contains("gemma"));
        assert!(find_mmproj(Path::new("Mistral-7B-Q4_K_M.gguf"), &dirs).is_none());
    }

    #[test]
    fn failure_texts() {
        assert!(explain_failure("ggml_vulkan: ErrorOutOfDeviceMemory", Some(1)).contains("Bellek yetersiz"));
        assert!(explain_failure("", Some(0xC0000135u32 as i32)).contains("Visual C++"));
        assert!(explain_failure("llama_model_load: error loading model architecture: unknown model architecture: 'xyz'", Some(1))
            .contains("desteklenmiyor"));
    }
}
