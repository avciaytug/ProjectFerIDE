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
                    let _ = me.llama.start(&st, StartRequest { model: m, mode: st.model.compute_mode, ctx: st.model.context }).await;
                });
            }
        }
        // Otomatik güncelleme: açılıştan bir dakika sonra, sonra altı saatte bir.
        let me = Arc::clone(self);
        tokio::spawn(async move {
            tokio::time::sleep(crate::update::FIRST_CHECK).await;
            loop {
                if me.settings().updates.auto {
                    me.updater.run_once().await;
                }
                tokio::time::sleep(crate::update::INTERVAL).await;
            }
        });
    }

    pub fn settings(&self) -> Settings {
        self.settings.read().unwrap().clone()
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
            if st.state != "starting" {
                let me = Arc::clone(self);
                let ss = s.clone();
                let sel = selected.clone();
                tokio::spawn(async move {
                    let _ = me.llama.start(&ss, StartRequest { model: sel, mode: ss.model.compute_mode, ctx: ss.model.context }).await;
                });
            }
            let mut rx = self.llama.subscribe();
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

    pub fn shutdown(&self) {
        tracing::info!("FerIDE kapanıyor");
        for r in self.runs.lock().unwrap().values() {
            r.cancel.cancel();
        }
        self.background.kill_all();
        self.terminals.close_all();
        self.mcp.stop_all();
        self.voice.shutdown();
        self.llama.shutdown();
    }
}
