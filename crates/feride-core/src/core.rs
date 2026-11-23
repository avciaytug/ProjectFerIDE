//! Çekirdek: tüm servisleri bir araya getirir. Arayüz (yerel sunucu) yalnızca bunu görür.

use serde_json::json;
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::{Arc, Mutex, RwLock};

use crate::agent;
use crate::config::Settings;
use crate::deps::Deps;
use crate::events::EventBus;
use crate::hub::Hub;
use crate::llama::{LlamaManager, StartRequest};
use crate::llm::LlmClient;
use crate::mcp::McpManager;
use crate::memory::MemoryStore;
use crate::paths::Paths;
use crate::secrets::Secrets;
use crate::sessions::Sessions;
use crate::skills::{self, Skill};
use crate::terminal::Terminals;
use crate::voice::Voice;

pub struct Core {
    pub paths: Paths,
    pub events: EventBus,
    settings: RwLock<Settings>,
    pub secrets: Secrets,
    pub deps: Deps,
    pub llama: Arc<LlamaManager>,
    pub updater: Arc<crate::update::Updater>,
    pub hub: Arc<Hub>,
    pub mcp: Arc<McpManager>,
    pub sessions: Sessions,
    pub memory: Option<MemoryStore>,
    pub terminals: Terminals,
    pub voice: Voice,
    pub runs: Mutex<HashMap<String, Arc<agent::Run>>>,
    pub session_allow: Mutex<HashMap<String, HashSet<String>>>,
    pub background: agent::tools::Background,
    /// Ajanın oturum başına gördüğü dosyalar (görmeden üzerine yazmayı önler).
    pub seen_files: agent::tools::SeenFiles,
    /// FerIDE'nin kontrol ettiği gerçek tarayıcı.
    pub browser: Arc<crate::browser::BrowserManager>,
    /// Otomatik bağlamı en son büyüten sohbet (aynı sohbette küçültülmez; önbelleği korunur).
    ctx_grown_for: Mutex<Option<String>>,
}

impl Core {
    pub fn new(paths: Paths) -> Arc<Core> {
        let events = EventBus::new();
        let settings = Settings::load(&paths.config_file());
        if !paths.config_file().exists() {
            let _ = settings.save(&paths.config_file());
        }
        let deps = Deps::new(paths.clone(), events.clone());
        deps.recover_staged_llama();
        crate::resources::install(&paths, &deps);
        let memory = match MemoryStore::open(&paths.memory_db()) {
            Ok(m) => {
                m.migrate_legacy(&paths.legacy_aegis_db());
                Some(m)
            }
            Err(e) => {
                tracing::error!("hafıza veritabanı açılamadı: {e}");
                None
            }
        };
        
        Arc::new(Core {
            secrets: Secrets::new(paths.secrets_file()),
            llama: Arc::new(LlamaManager::new(paths.clone(), events.clone())),
            updater: Arc::new(crate::update::Updater::new(paths.clone(), events.clone())),
            hub: Arc::new(Hub::new(paths.clone(), events.clone())),
            mcp: Arc::new(McpManager::new(paths.clone(), events.clone())),
            sessions: Sessions::new(paths.sessions()),
            terminals: Terminals::new(paths.clone(), events.clone()),
            voice: Voice::new(paths.clone()),
            settings: RwLock::new(settings),
            runs: Mutex::new(HashMap::new()),
            session_allow: Mutex::new(HashMap::new()),
            background: agent::tools::Background::default(),
            seen_files: agent::tools::SeenFiles::default(),
            browser: Arc::new(crate::browser::BrowserManager::new(paths.clone(), events.clone())),
            ctx_grown_for: Mutex::new(None),
            memory,
            deps,
            events,
            paths,
        })
    }

    /// Arka plan işleri: MCP sunucuları, (istenirse) modelin otomatik başlatılması.
    pub fn start_background(self: &Arc<Self>) {
        if let Some(ws) = self.settings().workspace {
            self.mcp.set_roots(vec![ws]);
        }
        self.mcp.start_all();
        let s = self.settings();
        // Güncelleme için yeniden başlatıldıysa o sırada yüklü olan model yeniden yüklenir.
        let resume = self.deps.state().resume_model;
        if resume.is_some() {
            self.deps.update_state(|st| st.resume_model = None);
        }
        let to_start = resume.filter(|m| m.is_file()).or_else(|| s.model.selected.clone().filter(|_| s.model.auto_start));
        if s.provider.kind == "local" {
            if let Some(m) = to_start {
                let me = Arc::clone(self);
                tokio::spawn(async move {
                    let st = me.settings();
                    let _ = me.llama.start(&st, StartRequest { model: m, mode: st.model.compute_mode, ctx: st.model.context, auto_base: None }).await;
                });
            }
        }
        // Güncelleme denetimi: açılıştan bir dakika sonra, sonra altı saatte bir. Otomatik güncelleme kapalıysa yalnızca
        // yeni sürüm olup olmadığına bakılır; hiçbir şey indirilmez.
        let me = Arc::clone(self);
        tokio::spawn(async move {
            tokio::time::sleep(crate::update::FIRST_CHECK).await;
            loop {
                me.updater.run(me.update_mode()).await;
                tokio::time::sleep(crate::update::INTERVAL).await;
            }
        });
    }

    pub fn settings(&self) -> Settings {
        self.settings.read().unwrap().clone()
    }

    /// Ayarlardaki "Yeni sürümleri otomatik indir ve kur" kutusuna göre denetim kipi.
    pub fn update_mode(&self) -> crate::update::UpdateMode {
        if self.settings().updates.auto {
            crate::update::UpdateMode::Auto
        } else {
            crate::update::UpdateMode::Check
        }
    }

    pub fn update_settings(&self, patch: &serde_json::Value) -> anyhow::Result<Settings> {
        let new = {
            let cur = self.settings.read().unwrap();
            cur.merged(patch)?
        };
        new.save(&self.paths.config_file())?;
        let old_ws = self.settings().workspace;
        *self.settings.write().unwrap() = new.clone();
        if new.workspace != old_ws {
            if let Some(ws) = &new.workspace {
                self.mcp.set_roots(vec![ws.clone()]);
            }
        }
        self.events.emit_ser("settings.changed", &new);
        Ok(new)
    }

    pub fn set_workspace(&self, ws: PathBuf) -> anyhow::Result<Settings> {
        let ws = dunce::canonicalize(&ws)?;
        if !ws.is_dir() {
            anyhow::bail!("klasör değil: {}", ws.display());
        }
        let mut recent = self.settings().recent_workspaces;
        recent.retain(|p| p != &ws);
        recent.insert(0, ws.clone());
        recent.truncate(12);
        self.update_settings(&json!({"workspace": ws, "recent_workspaces": recent}))
    }

    /// Ajanın kullanacağı çalışma alanı (seçilmemişse kullanıcı klasöründe FerIDE çalışma klasörü).
    pub fn workspace(&self) -> PathBuf {
        self.settings().workspace.filter(|p| p.is_dir()).unwrap_or_else(|| {
            let d = self.paths.home.join("FerIDE-Calisma");
            let _ = std::fs::create_dir_all(&d);
            d
        })
    }

    pub fn skills(&self) -> Vec<Skill> {
        let s = self.settings();
        let mut dirs = vec![];
        if let Some(ws) = &s.workspace {
            dirs.push((ws.join(".feride").join("skills"), "çalışma alanı"));
        }
        dirs.push((self.paths.skills(), "kullanıcı"));
        skills::scan(&dirs, &s.disabled_skills)
    }

    /// Ayarlara göre LLM istemcisi ve bağlam boyutu. Yerel modelde model hazır değilse
    /// seçili model başlatılır ve beklenir.
    pub async fn llm(self: &Arc<Self>, on_status: &(dyn Fn(String) + Send + Sync)) -> anyhow::Result<(LlmClient, i64, bool)> {
        let s = self.settings();
        if s.provider.kind == "openai" {
            if s.provider.base_url.trim().is_empty() {
                anyhow::bail!("Uzak uç nokta adresi girilmemiş (Ayarlar > Model sağlayıcı).");
            }
            let key = self.secrets.get("provider_api_key");
            return Ok((LlmClient::new(&s.provider.base_url, &s.provider.model, key), s.provider.context as i64, false));
        }
        let mut st = self.llama.status();
        if st.state != "ready" {
            let selected = st
                .model_path
                .clone()
                .filter(|_| st.state == "starting")
                .or(s.model.selected.clone())
                .ok_or_else(|| anyhow::anyhow!("Henüz model seçilmedi. Model Merkezi'nden bir model seçip başlatın."))?;
            on_status(format!("Model yükleniyor: {}", crate::gguf::base_name(&selected)));
            let mut rx = self.llama.subscribe();
            // Şimdiki durum (ör. az önce kapanan sunucunun "failed"ı) yeni başlatmanın sonucu değil: görülmüş sayılır ve
            // başlatma onu değiştirene kadar beklenir. Yoksa eski hata, model yüklenmeden hemen yeniden bildirilirdi.
            if st.state != "starting" && rx.borrow_and_update().state != "ready" {
                let me = Arc::clone(self);
                let ss = s.clone();
                let sel = selected.clone();
                tokio::spawn(async move {
                    let _ = me.llama.start(&ss, StartRequest { model: sel, mode: ss.model.compute_mode, ctx: ss.model.context, auto_base: None }).await;
                });
                if tokio::time::timeout(std::time::Duration::from_secs(1800), rx.changed()).await.is_err() {
                    anyhow::bail!("Model yüklenmesi çok uzun sürdü.");
                }
            }
            loop {
                st = rx.borrow_and_update().clone();
                match st.state.as_str() {
                    "ready" => break,
                    "failed" => anyhow::bail!(st.error.unwrap_or_else(|| "Model başlatılamadı.".into())),
                    _ => {}
                }
                if tokio::time::timeout(std::time::Duration::from_secs(1800), rx.changed()).await.is_err() {
                    anyhow::bail!("Model yüklenmesi çok uzun sürdü.");
                }
            }
        }
        let base = st.base_url.clone().ok_or_else(|| anyhow::anyhow!("model adresi yok"))?;
        let name = st.model_name.clone().unwrap_or_else(|| "local".into());
        Ok((LlmClient::new(&base, &name, None), st.ctx.unwrap_or(16384), st.vision))
    }

    /// Çalışan yerel model "Otomatik" bağlamla mı açık ve bağlamı yeniden boyutlamak güvenli mi? Başka bir sohbet de
    /// modeli kullanıyorsa yeniden başlatma onun isteğini keserdi.
    fn resizable(&self) -> Option<crate::llama::ModelStatus> {
        let s = self.settings();
        if s.provider.kind != "local" || s.model.context != 0 {
            return None;
        }
        let st = self.llama.status();
        if st.state != "ready" || !st.auto_ctx || st.ctx.is_none() || st.model_path.is_none() {
            return None;
        }
        if self.runs.lock().unwrap().len() > 1 {
            return None;
        }
        Some(st)
    }

    fn client_for(st: &crate::llama::ModelStatus) -> Option<(LlmClient, i64)> {
        let base = st.base_url.clone()?;
        let name = st.model_name.clone().unwrap_or_else(|| "local".into());
        Some((LlmClient::new(&base, &name, None), st.ctx?))
    }

    /// Otomatik bağlamda: `need` tokenlık istem mevcut bağlama sığmıyorsa ve bellek elveriyorsa modeli daha büyük
    /// bağlamla yeniden başlatır (modelin eğitim sınırına kadar). Dönüş: yeni bağlantı ve bağlam boyu; büyütülemediyse
    /// `None` (ajan o zaman eski konuşmayı özetler).
    pub async fn grow_context(
        self: &Arc<Self>,
        session: &str,
        need: i64,
        on_status: &(dyn Fn(String) + Send + Sync),
    ) -> Option<(LlmClient, i64)> {
        let st = self.resizable()?;
        let (cur, model) = (st.ctx?, st.model_path.clone()?);
        let base = st.base_ctx.unwrap_or(cur);
        let m = model.clone();
        let info = tokio::task::spawn_blocking(move || crate::gguf::read(&m)).await.ok().flatten()?;
        let train = info.context_length as i64;
        let s = self.settings();
        let mut target = None;
        for c in growth_candidates(cur, need, train) {
            let req = StartRequest { model: model.clone(), mode: s.model.compute_mode, ctx: c as u32, auto_base: Some(base) };
            let Ok((plan, _, _)) = self.llama.preview_plan(&s, &req).await else { continue };
            // Sığmalı, istenen bağlamı tam vermeli ve yerleşim değişmemeli (GPU'dan RAM'e kaymak modeli çok yavaşlatır).
            if plan.can_start() && plan.ctx >= c && Some(&plan.placement) == st.placement.as_ref() {
                target = Some(c);
                break;
            }
        }
        let Some(target) = target else {
            tracing::info!("bağlam büyütülemedi: gereken ~{need}, şu an {cur}, model sınırı {train} (bellek ya da sınır yetmiyor)");
            return None;
        };
        on_status(format!(
            "Bağlam büyütülüyor: {}K → {}K (bellek yeterli). Model yeniden yükleniyor; ardından geçmiş yeniden işlenecek…",
            cur / 1024,
            target / 1024
        ));
        tracing::info!("otomatik bağlam büyütülüyor: {cur} → {target} (gereken ~{need})");
        let req = StartRequest { model: model.clone(), mode: s.model.compute_mode, ctx: target as u32, auto_base: Some(base) };
        match self.llama.restart(&s, req).await {
            Ok(new) if new.state == "ready" => {
                *self.ctx_grown_for.lock().unwrap() = Some(session.to_string());
                Self::client_for(&new)
            }
            other => {
                tracing::warn!("bağlam büyütülemedi: {:?}", other.err());
                on_status("Bağlam büyütülemedi; model önceki bağlamla yeniden açılıyor…".into());
                let back = StartRequest { model, mode: s.model.compute_mode, ctx: cur as u32, auto_base: Some(base) };
                let _ = self.llama.restart(&s, back).await;
                None
            }
        }
    }

    /// Otomatik bağlam bir görev için büyütüldüyse ve şimdi başka, küçük bir sohbet başlıyorsa modeli taban bağlamla
    /// yeniden açar: büyük bağlamın belleği serbest kalır. Aynı sohbette küçültülmez (önbelleği boşa gitmesin).
    pub async fn shrink_context(
        self: &Arc<Self>,
        session: &str,
        need: i64,
        on_status: &(dyn Fn(String) + Send + Sync),
    ) -> Option<(LlmClient, i64)> {
        let st = self.resizable()?;
        let (cur, base) = (st.ctx?, st.base_ctx?);
        if cur <= base || need > base / 2 || self.ctx_grown_for.lock().unwrap().as_deref() == Some(session) {
            return None;
        }
        let s = self.settings();
        on_status(format!("Bağlam küçültülüyor: {}K → {}K (yeni sohbet; büyük bağlamın belleği serbest bırakılıyor)…", cur / 1024, base / 1024));
        tracing::info!("otomatik bağlam küçültülüyor: {cur} → taban");
        let req = StartRequest { model: st.model_path.clone()?, mode: s.model.compute_mode, ctx: 0, auto_base: None };
        match self.llama.restart(&s, req).await {
            Ok(new) if new.state == "ready" => {
                *self.ctx_grown_for.lock().unwrap() = None;
                Self::client_for(&new)
            }
            _ => None,
        }
    }

    pub fn shutdown(&self) {
        tracing::info!("FerIDE kapanıyor");
        for r in self.runs.lock().unwrap().values() {
            r.cancel.cancel();
        }
        self.background.kill_all();
        self.browser.shutdown();
        self.terminals.close_all();
        self.mcp.stop_all();
        self.voice.shutdown();
        self.llama.shutdown();
    }
}

/// Otomatik bağlamı büyütürken denenecek boylar (büyükten küçüğe), modelin eğitim sınırına kadar: ihtiyacın 1,5 katı ya
/// da iki katı (sık yeniden yüklemeyi önler); o sığmazsa bir buçuk katı. Bellek bir anda modelin en büyük bağlamına
/// ayrılmaz, adım adım büyür. Boy, gereken istem + çıktı payını almıyorsa aday olmaz (büyütmek işe yaramaz, özetlenir).
pub fn growth_candidates(cur: i64, need: i64, train: i64) -> Vec<i64> {
    use crate::agent::context::out_reserve;
    let round = |v: i64| (v + 8191) / 8192 * 8192;
    let mut cands = vec![round((need * 3 / 2).max(cur * 2)).min(train), round(cur * 3 / 2).min(train)];
    cands.retain(|c| *c > cur && *c <= train && *c >= need + out_reserve(*c));
    cands.sort_unstable_by(|a, b| b.cmp(a));
    cands.dedup();
    cands
}

#[cfg(test)]
mod tests {
    use super::growth_candidates;

    #[test]
    fn context_grows_stepwise_up_to_the_model_limit() {
        // Kullanıcının durumu: 128K doldu, model 256K destekliyor → önce 256K, sığmazsa 192K.
        assert_eq!(growth_candidates(131072, 120_000, 262144), vec![262144, 196608]);
        // Model zaten sınırında: büyütülmez (özetlenir).
        assert!(growth_candidates(262144, 250_000, 262144).is_empty());
        // Çok büyük sınırlı modelde bir anda en büyüğüne atlanmaz.
        assert_eq!(growth_candidates(131072, 120_000, 1_048_576)[0], 262144);
        // İhtiyaç iki katı aşıyorsa 1,5 katına göre (ör. sabit taban yüklü uzun bir sohbet açılınca).
        assert_eq!(growth_candidates(24576, 60_000, 131072)[0], 90112);
        // Modelin sınırı ihtiyacı karşılamıyorsa aday yok.
        assert!(growth_candidates(131072, 255_000, 262144).is_empty());
    }
}
