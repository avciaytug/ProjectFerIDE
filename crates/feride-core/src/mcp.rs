//! MCP (Model Context Protocol) stdio istemcisi.
//!
//! Yapılandırma v5.3.8 ile aynı biçimdedir (`~/.feride/mcp_config.json`, `mcpServers`).
//! Windows'ta `npx`/`uvx` gibi `.cmd` komutları doğru çalıştırılır (bkz. `proc::command`).
//! Sunucu süreçleri İş Nesnesi'ne bağlıdır; FerIDE kapanınca kapanır.

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{BTreeMap, HashMap};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::{mpsc, oneshot};

use crate::events::EventBus;
use crate::paths::Paths;
use crate::proc::KillHandle;

pub const PROTOCOL_VERSION: &str = "2025-06-18";

#[derive(Clone, Debug, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct ServerConfig {
    pub command: String,
    pub args: Vec<String>,
    pub env: BTreeMap<String, String>,
    pub description: String,
    pub disabled: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize, Default)]
pub struct McpConfig {
    #[serde(rename = "mcpServers", default)]
    pub servers: BTreeMap<String, ServerConfig>,
    #[serde(flatten)]
    pub other: BTreeMap<String, Value>,
}

#[derive(Clone, Debug, Serialize)]
pub struct McpTool {
    pub server: String,
    pub name: String,
    /// Ajana gösterilen ad: mcp__sunucu__araç
    pub full_name: String,
    pub description: String,
    pub input_schema: Value,
    pub read_only: bool,
}

#[derive(Clone, Debug, Serialize)]
pub struct ServerStatus {
    pub name: String,
    /// stopped | starting | ready | error | disabled
    pub state: String,
    pub error: Option<String>,
    pub tools: usize,
    pub command: String,
    pub description: String,
    pub missing_runtime: Option<String>,
}

type Pending = Arc<Mutex<HashMap<u64, oneshot::Sender<Result<Value, String>>>>>;

struct Client {
    tx: mpsc::UnboundedSender<String>,
    pending: Pending,
    next_id: AtomicU64,
    kill: KillHandle,
}

impl Client {
    async fn request(&self, method: &str, params: Value, timeout: Duration) -> Result<Value, String> {
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        let (tx, rx) = oneshot::channel();
        self.pending.lock().unwrap().insert(id, tx);
        let msg = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        self.tx.send(msg.to_string()).map_err(|_| "sunucu kapalı".to_string())?;
        match tokio::time::timeout(timeout, rx).await {
            Ok(Ok(r)) => r,
            Ok(Err(_)) => Err("sunucu bağlantısı kapandı".into()),
            Err(_) => {
                self.pending.lock().unwrap().remove(&id);
                let _ = self.tx.send(json!({"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId": id, "reason": "zaman aşımı"}}).to_string());
                Err(format!("{method}: {} sn içinde yanıt gelmedi", timeout.as_secs()))
            }
        }
    }

    fn notify(&self, method: &str, params: Value) {
        let _ = self.tx.send(json!({"jsonrpc": "2.0", "method": method, "params": params}).to_string());
    }
}

struct ServerEntry {
    status: ServerStatus,
    client: Option<Arc<Client>>,
    tools: Vec<McpTool>,
}

pub struct McpManager {
    paths: Paths,
    events: EventBus,
    servers: Mutex<BTreeMap<String, ServerEntry>>,
    roots: Mutex<Vec<PathBuf>>,
}

pub fn sanitize(s: &str) -> String {
    s.chars().map(|c| if c.is_ascii_alphanumeric() || c == '_' || c == '-' { c } else { '_' }).collect()
}

impl McpManager {
    pub fn new(paths: Paths, events: EventBus) -> Self {
        Self { paths, events, servers: Mutex::new(BTreeMap::new()), roots: Mutex::new(vec![]) }
    }

    pub fn load_config(&self) -> McpConfig {
        let f = self.paths.mcp_config();
        let mut cfg: McpConfig = std::fs::read(&f).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
        if cfg.servers.is_empty() && !f.exists() {
            cfg = default_config();
            let _ = self.save_config(&cfg);
        }
        // v5.3.8: arşivlenmiş mcp-server-sqlite → yerleşik sunucu.
        if let Some(s) = cfg.servers.get_mut("sqlite") {
            // Eski sürümler: arşivlenmiş paket ya da v5.3.8 klasörüne mutlak yol.
            let legacy = s.args.iter().any(|a| a == "mcp-server-sqlite")
                || s.args.iter().any(|a| a.ends_with("mcp_sqlite_server.py") && !a.contains("${FERIDE_RESOURCES}"));
            if legacy {
                *s = builtin_sqlite();
                let _ = self.save_config(&cfg);
            }
        }
        cfg
    }

    pub fn save_config(&self, cfg: &McpConfig) -> anyhow::Result<()> {
        crate::util::write_atomic(&self.paths.mcp_config(), &serde_json::to_vec_pretty(cfg)?)
    }

    pub fn set_roots(&self, roots: Vec<PathBuf>) {
        *self.roots.lock().unwrap() = roots;
        for e in self.servers.lock().unwrap().values() {
            if let Some(c) = &e.client {
                c.notify("notifications/roots/list_changed", json!({}));
            }
        }
    }

    pub fn statuses(&self) -> Vec<ServerStatus> {
        let cfg = self.load_config();
        let live = self.servers.lock().unwrap();
        let path_var = crate::proc::child_path(&self.paths, &[]);
        cfg.servers
            .iter()
            .map(|(name, sc)| {
                let mut st = live.get(name).map(|e| e.status.clone()).unwrap_or(ServerStatus {
                    name: name.clone(),
                    state: if sc.disabled { "disabled".into() } else { "stopped".into() },
                    error: None,
                    tools: 0,
                    command: String::new(),
                    description: String::new(),
                    missing_runtime: None,
                });
                if sc.disabled {
                    st.state = "disabled".into();
                }
                st.command = format!("{} {}", sc.command, sc.args.join(" "));
                st.description = sc.description.clone();
                let cmd = resolve_command(&self.paths, &sc.command);
                st.missing_runtime = if crate::proc::which_in(&cmd, &path_var).is_none() {
                    Some(match sc.command.as_str() {
                        "npx" | "node" => "Node.js gerekli (Kurulum > Node.js)".into(),
                        "uvx" | "uv" => "uv gerekli (Kurulum > uv)".into(),
                        "python" | "python3" | "feride-python" => "Python ortamı gerekli (Kurulum > Belge stüdyosu)".into(),
                        c => format!("'{c}' bulunamadı"),
                    })
                } else {
                    None
                };
                st
            })
            .collect()
    }

    pub fn tools(&self) -> Vec<McpTool> {
        self.servers.lock().unwrap().values().flat_map(|e| e.tools.clone()).collect()
    }

    /// Etkin tüm sunucuları arka planda başlatır.
    pub fn start_all(self: &Arc<Self>) {
        let cfg = self.load_config();
        for (name, sc) in cfg.servers {
            if sc.disabled {
                continue;
            }
            let me = Arc::clone(self);
            tokio::spawn(async move {
                if let Err(e) = me.start(&name, &sc).await {
                    tracing::warn!("MCP {name}: {e}");
                }
            });
        }
    }

    pub async fn restart(self: &Arc<Self>, name: &str) -> anyhow::Result<()> {
        self.stop(name);
        let cfg = self.load_config();
        let sc = cfg.servers.get(name).cloned().ok_or_else(|| anyhow::anyhow!("sunucu yok: {name}"))?;
        if sc.disabled {
            return Ok(());
        }
        self.start(name, &sc).await
    }

    pub fn stop(&self, name: &str) {
        if let Some(e) = self.servers.lock().unwrap().remove(name) {
            if let Some(c) = e.client {
                c.kill.kill_tree();
            }
        }
        self.events.emit("mcp.changed", json!({}));
    }

    pub fn stop_all(&self) {
        let names: Vec<String> = self.servers.lock().unwrap().keys().cloned().collect();
        for n in names {
            self.stop(&n);
        }
    }

    fn set_status(&self, name: &str, state: &str, error: Option<String>, client: Option<Arc<Client>>, tools: Option<Vec<McpTool>>) {
        let mut g = self.servers.lock().unwrap();
        let e = g.entry(name.to_string()).or_insert_with(|| ServerEntry {
            status: ServerStatus {
                name: name.into(),
                state: String::new(),
                error: None,
                tools: 0,
                command: String::new(),
                description: String::new(),
                missing_runtime: None,
            },
            client: None,
            tools: vec![],
        });
        e.status.state = state.into();
        e.status.error = error;
        if let Some(c) = client {
            e.client = Some(c);
        }
        if let Some(t) = tools {
            e.status.tools = t.len();
            e.tools = t;
        }
        drop(g);
        self.events.emit("mcp.changed", json!({}));
    }

    async fn start(self: &Arc<Self>, name: &str, sc: &ServerConfig) -> anyhow::Result<()> {
        self.set_status(name, "starting", None, None, None);
        let res = self.start_inner(name, sc).await;
        if let Err(e) = &res {
            self.set_status(name, "error", Some(e.to_string()), None, Some(vec![]));
        }
        res
    }

    async fn start_inner(self: &Arc<Self>, name: &str, sc: &ServerConfig) -> anyhow::Result<()> {
        let program = resolve_command(&self.paths, &sc.command);
        let args: Vec<String> = sc
            .args
            .iter()
            .map(|a| {
                let a = a.replace("${FERIDE_HOME}", &self.paths.data.to_string_lossy()).replace(
                    "${FERIDE_RESOURCES}",
                    &self.paths.resources().to_string_lossy(),
                );
                if a.starts_with('~') {
                    crate::paths::expand_tilde(&a, &self.paths.home).to_string_lossy().to_string()
                } else {
                    a
                }
            })
            .collect();
        let mut cmd = crate::proc::command(&self.paths, &program, &args);
        for (k, v) in &sc.env {
            if !v.is_empty() {
                cmd.env(k, v);
            }
        }
        cmd.stdin(std::process::Stdio::piped()).stdout(std::process::Stdio::piped()).stderr(std::process::Stdio::piped());
        let (mut child, kill) = crate::proc::spawn(&mut cmd).map_err(|e| anyhow::anyhow!("başlatılamadı ({program}): {e}"))?;
        let mut stdin = child.stdin.take().unwrap();
        let stdout = child.stdout.take().unwrap();
        let stderr = child.stderr.take().unwrap();
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let pending: Pending = Arc::new(Mutex::new(HashMap::new()));
        let client = Arc::new(Client { tx: tx.clone(), pending: pending.clone(), next_id: AtomicU64::new(1), kill });

        // Yazıcı
        tokio::spawn(async move {
            while let Some(line) = rx.recv().await {
                if stdin.write_all(line.as_bytes()).await.is_err() || stdin.write_all(b"\n").await.is_err() {
                    break;
                }
                let _ = stdin.flush().await;
            }
        });
        // Hata akışı (günlüğe)
        let sname = name.to_string();
        let stderr_tail = Arc::new(Mutex::new(Vec::<String>::new()));
        let st2 = stderr_tail.clone();
        tokio::spawn(async move {
            let mut lines = BufReader::new(stderr).lines();
            while let Ok(Some(l)) = lines.next_line().await {
                tracing::debug!("MCP {sname}: {l}");
                let mut t = st2.lock().unwrap();
                if t.len() > 20 {
                    t.remove(0);
                }
                t.push(l);
            }
        });
        // Okuyucu: yanıtları eşleştir, sunucu isteklerini yanıtla.
        let me = Arc::clone(self);
        let rname = name.to_string();
        let roots_tx = tx.clone();
        tokio::spawn(async move {
            // Satırlar bayt olarak okunur: geçersiz UTF-8 bağlantıyı koparmaz.
            let mut reader = BufReader::new(stdout);
            let mut buf = Vec::new();
            loop {
                buf.clear();
                match reader.read_until(b'\n', &mut buf).await {
                    Ok(0) | Err(_) => break,
                    Ok(_) => {}
                }
                let line = String::from_utf8_lossy(&buf);
                let Ok(msg) = serde_json::from_str::<Value>(line.trim()) else { continue };
                if let (Some(id), true) = (msg["id"].as_u64(), msg.get("method").is_none()) {
                    if let Some(tx) = pending.lock().unwrap().remove(&id) {
                        let r = if let Some(e) = msg.get("error") {
                            Err(e["message"].as_str().unwrap_or("MCP hatası").to_string())
                        } else {
                            Ok(msg["result"].clone())
                        };
                        let _ = tx.send(r);
                    }
                    continue;
                }
                if let Some(method) = msg["method"].as_str() {
                    let id = msg.get("id").cloned();
                    match (method, id) {
                        ("ping", Some(id)) => {
                            let _ = roots_tx.send(json!({"jsonrpc":"2.0","id":id,"result":{}}).to_string());
                        }
                        ("roots/list", Some(id)) => {
                            let roots: Vec<Value> = me
                                .roots
                                .lock()
                                .unwrap()
                                .iter()
                                .map(|r| json!({"uri": path_to_uri(r), "name": r.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default()}))
                                .collect();
                            let _ = roots_tx.send(json!({"jsonrpc":"2.0","id":id,"result":{"roots": roots}}).to_string());
                        }
                        ("notifications/tools/list_changed", None) => {
                            let me2 = Arc::clone(&me);
                            let n = rname.clone();
                            tokio::spawn(async move { me2.refresh_tools(&n).await });
                        }
                        (_, Some(id)) => {
                            let _ = roots_tx.send(
                                json!({"jsonrpc":"2.0","id":id,"error":{"code":-32601,"message":"FerIDE bu isteği desteklemiyor"}}).to_string(),
                            );
                        }
                        _ => {}
                    }
                }
            }
            // Süreç kapandı
            let still = me.servers.lock().unwrap().get(&rname).map(|e| e.status.state == "ready").unwrap_or(false);
            if still {
                me.set_status(&rname, "error", Some("Sunucu kapandı".into()), None, Some(vec![]));
            }
        });
        // Süreç bitince kaynakları bırak.
        tokio::spawn(async move {
            let _ = child.wait().await;
        });

        let init = client
            .request(
                "initialize",
                json!({
                    "protocolVersion": PROTOCOL_VERSION,
                    "capabilities": {"roots": {"listChanged": true}},
                    "clientInfo": {"name": "FerIDE", "version": crate::VERSION}
                }),
                Duration::from_secs(90),
            )
            .await
            .map_err(|e| {
                let tail = stderr_tail.lock().unwrap().join("\n");
                anyhow::anyhow!("başlatma başarısız: {e}{}", if tail.is_empty() { String::new() } else { format!("\n{tail}") })
            })?;
        let _ = init;
        client.notify("notifications/initialized", json!({}));
        self.set_status(name, "starting", None, Some(client.clone()), None);
        self.refresh_tools(name).await;
        Ok(())
    }

    async fn refresh_tools(&self, name: &str) {
        let Some(client) = self.servers.lock().unwrap().get(name).and_then(|e| e.client.clone()) else { return };
        let mut tools = vec![];
        let mut cursor: Option<String> = None;
        for _ in 0..20 {
            let params = match &cursor {
                Some(c) => json!({"cursor": c}),
                None => json!({}),
            };
            match client.request("tools/list", params, Duration::from_secs(30)).await {
                Ok(r) => {
                    for t in r["tools"].as_array().cloned().unwrap_or_default() {
                        let tname = t["name"].as_str().unwrap_or_default().to_string();
                        let full = format!("mcp__{}__{}", sanitize(name), sanitize(&tname));
                        tools.push(McpTool {
                            server: name.to_string(),
                            name: tname,
                            full_name: full.chars().take(64).collect(),
                            description: crate::util::truncate_end(t["description"].as_str().unwrap_or(""), 1000),
                            input_schema: if t["inputSchema"].is_object() { t["inputSchema"].clone() } else { json!({"type":"object","properties":{}}) },
                            read_only: t["annotations"]["readOnlyHint"].as_bool().unwrap_or(false),
                        });
                    }
                    cursor = r["nextCursor"].as_str().map(String::from);
                    if cursor.is_none() {
                        break;
                    }
                }
                Err(e) => {
                    self.set_status(name, "error", Some(format!("araç listesi alınamadı: {e}")), None, Some(vec![]));
                    return;
                }
            }
        }
        self.set_status(name, "ready", None, None, Some(tools));
    }

    /// MCP aracını çağırır; içerik metne çevrilir.
    pub async fn call(&self, full_name: &str, args: Value) -> anyhow::Result<(String, bool)> {
        let (client, tool) = {
            let g = self.servers.lock().unwrap();
            let mut found = None;
            for e in g.values() {
                if let Some(t) = e.tools.iter().find(|t| t.full_name == full_name) {
                    found = Some((e.client.clone(), t.clone()));
                    break;
                }
            }
            found.ok_or_else(|| anyhow::anyhow!("MCP aracı bulunamadı: {full_name}"))?
        };
        let client = client.ok_or_else(|| anyhow::anyhow!("MCP sunucusu çalışmıyor: {}", tool.server))?;
        let r = client
            .request("tools/call", json!({"name": tool.name, "arguments": args}), Duration::from_secs(180))
            .await
            .map_err(|e| anyhow::anyhow!(e))?;
        let is_error = r["isError"].as_bool().unwrap_or(false);
        let mut out = vec![];
        for c in r["content"].as_array().cloned().unwrap_or_default() {
            match c["type"].as_str() {
                Some("text") => out.push(c["text"].as_str().unwrap_or("").to_string()),
                Some("image") => out.push(format!("[görsel: {}]", c["mimeType"].as_str().unwrap_or("?"))),
                Some("resource") => out.push(c["resource"]["text"].as_str().map(String::from).unwrap_or_else(|| format!("[kaynak: {}]", c["resource"]["uri"]))),
                Some("resource_link") => out.push(format!("[bağlantı: {}]", c["uri"].as_str().unwrap_or(""))),
                _ => {}
            }
        }
        if out.is_empty() && !r["structuredContent"].is_null() {
            out.push(r["structuredContent"].to_string());
        }
        Ok((out.join("\n"), is_error))
    }
}

fn path_to_uri(p: &std::path::Path) -> String {
    url::Url::from_file_path(p).map(|u| u.to_string()).unwrap_or_else(|_| format!("file://{}", p.display()))
}

/// "feride-python" → FerIDE'nin Python ortamı; yoksa sistemdeki Python (yerleşik sunucular
/// yalnızca standart kitaplığı kullanır).
fn resolve_command(paths: &Paths, cmd: &str) -> String {
    match cmd {
        "feride-python" => {
            let py = paths.pyenv_python();
            if py.is_file() {
                return py.to_string_lossy().to_string();
            }
            let path_var = crate::proc::child_path(paths, &[]);
            for c in ["python3", "python", "py"] {
                if let Some(p) = crate::proc::which_in(c, &path_var) {
                    // Windows Mağazası'nın sahte python.exe kısayolunu atla.
                    if !p.to_string_lossy().to_lowercase().contains("windowsapps") {
                        return p.to_string_lossy().to_string();
                    }
                }
            }
            py.to_string_lossy().to_string()
        }
        c => c.to_string(),
    }
}

fn builtin_sqlite() -> ServerConfig {
    ServerConfig {
        command: "feride-python".into(),
        args: vec![
            "${FERIDE_RESOURCES}/python/mcp_sqlite_server.py".into(),
            "--db-path".into(),
            "${FERIDE_HOME}/feride_knowledge.db".into(),
        ],
        env: BTreeMap::new(),
        description: "Yerel SQLite veritabanı (FerIDE'ye yerleşik, yalnızca Python standart kitaplığı).".into(),
        disabled: false,
    }
}

pub fn default_config() -> McpConfig {
    let mut s = BTreeMap::new();
    s.insert(
        "filesystem".into(),
        ServerConfig {
            command: "npx".into(),
            args: vec!["-y".into(), "@modelcontextprotocol/server-filesystem".into(), "~".into()],
            description: "Dosya okuma, yazma, dizin listeleme ve arama.".into(),
            disabled: true,
            ..Default::default()
        },
    );
    s.insert(
        "fetch".into(),
        ServerConfig {
            command: "uvx".into(),
            args: vec!["mcp-server-fetch".into()],
            description: "Web sayfalarını markdown olarak çeker.".into(),
            ..Default::default()
        },
    );
    s.insert(
        "memory".into(),
        ServerConfig {
            command: "npx".into(),
            args: vec!["-y".into(), "@modelcontextprotocol/server-memory".into()],
            description: "Kalıcı bilgi grafiği hafızası.".into(),
            disabled: true,
            ..Default::default()
        },
    );
    s.insert("sqlite".into(), builtin_sqlite());
    let mut env = BTreeMap::new();
    env.insert("GITHUB_PERSONAL_ACCESS_TOKEN".into(), String::new());
    s.insert(
        "github".into(),
        ServerConfig {
            command: "npx".into(),
            args: vec!["-y".into(), "@modelcontextprotocol/server-github".into()],
            env,
            description: "GitHub depoları, commit ve issue yönetimi.".into(),
            disabled: true,
        },
    );
    McpConfig { servers: s, other: BTreeMap::new() }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn legacy_config_parses() {
        let raw = r#"{"mcpServers":{"fetch":{"command":"uvx","args":["mcp-server-fetch"],"description":"x","disabled":false},
            "github":{"command":"npx","args":["-y","@modelcontextprotocol/server-github"],"env":{"GITHUB_PERSONAL_ACCESS_TOKEN":""},"disabled":true}},
            "updatedAt":"2026-11-02T15:05:00Z","ferideVersion":"5.3.8"}"#;
        let c: McpConfig = serde_json::from_str(raw).unwrap();
        assert_eq!(c.servers.len(), 2);
        assert!(c.servers["github"].disabled);
        assert!(c.other.contains_key("ferideVersion"));
        assert_eq!(sanitize("my.server/x"), "my_server_x");
    }

    /// Gerçek bir MCP sunucusuyla uçtan uca deneme (Python varsa).
    #[tokio::test]
    async fn python_sqlite_server_roundtrip() {
        let py = which_python();
        let Some(py) = py else { return };
        let script = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../resources/python/mcp_sqlite_server.py");
        if !script.is_file() {
            return;
        }
        let dir = tempfile::tempdir().unwrap();
        let paths = Paths::with_data_dir(dir.path().to_path_buf());
        let mut cfg = McpConfig::default();
        cfg.servers.insert(
            "sql".into(),
            ServerConfig {
                command: py,
                args: vec![script.to_string_lossy().into(), "--db-path".into(), dir.path().join("k.db").to_string_lossy().into()],
                ..Default::default()
            },
        );
        std::fs::write(paths.mcp_config(), serde_json::to_vec(&cfg).unwrap()).unwrap();
        let m = Arc::new(McpManager::new(paths, EventBus::new()));
        m.restart("sql").await.unwrap();
        let tools = m.tools();
        assert!(!tools.is_empty(), "araç yok");
        let write = tools.iter().find(|t| t.name.contains("write") || t.name.contains("create")).map(|t| t.full_name.clone());
        if let Some(w) = write {
            let _ = m.call(&w, json!({"query": "CREATE TABLE t(x INTEGER)"})).await;
        }
        m.stop_all();
    }

    fn which_python() -> Option<String> {
        for c in ["python", "python3"] {
            if std::process::Command::new(c).arg("--version").output().map(|o| o.status.success()).unwrap_or(false) {
                return Some(c.to_string());
            }
        }
        None
    }
}
