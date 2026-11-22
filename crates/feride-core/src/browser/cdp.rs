//! Chrome DevTools Protocol istemcisi: tarayıcının kendi WebSocket ucuna bağlanır ve sekmelerle "flatten" oturum
//! kipinde konuşur (her komut ilgili sekmenin `sessionId`'siyle gider, olaylar aynı bağlantıdan gelir).

use futures::{SinkExt, StreamExt};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::{broadcast, mpsc, oneshot};
use tokio_tungstenite::tungstenite::Message;

/// Tarayıcıdan gelen olay. `session`: olayın ait olduğu sekme oturumu (tarayıcı düzeyindeki olaylarda yok).
#[derive(Clone, Debug)]
pub struct CdpEvent {
    pub method: String,
    pub params: Value,
    pub session: Option<String>,
}

/// Bağlantı kapanınca yayınlanan olay adı.
pub const CLOSED: &str = "_closed";

type Pending = Arc<Mutex<HashMap<u64, oneshot::Sender<Result<Value, String>>>>>;

pub struct Cdp {
    tx: mpsc::UnboundedSender<String>,
    pending: Pending,
    next: AtomicU64,
    events: broadcast::Sender<CdpEvent>,
    closed: Arc<AtomicBool>,
}

impl Cdp {
    pub async fn connect(ws_url: &str) -> anyhow::Result<Arc<Cdp>> {
        let (ws, _) = tokio::time::timeout(Duration::from_secs(10), tokio_tungstenite::connect_async(ws_url))
            .await
            .map_err(|_| anyhow::anyhow!("tarayıcıya bağlanılamadı (zaman aşımı)"))??;
        let (mut sink, mut stream) = ws.split();
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let pending: Pending = Arc::default();
        let (events, _) = broadcast::channel(2048);
        let closed = Arc::new(AtomicBool::new(false));

        tokio::spawn(async move {
            while let Some(m) = rx.recv().await {
                if sink.send(Message::Text(m.into())).await.is_err() {
                    break;
                }
            }
            let _ = sink.close().await;
        });
        {
            let (pending, events, closed) = (pending.clone(), events.clone(), closed.clone());
            tokio::spawn(async move {
                while let Some(msg) = stream.next().await {
                    let text = match msg {
                        Ok(Message::Text(t)) => t.as_str().to_string(),
                        Ok(Message::Binary(b)) => String::from_utf8_lossy(&b).into_owned(),
                        Ok(Message::Close(_)) | Err(_) => break,
                        Ok(_) => continue,
                    };
                    let Ok(v) = serde_json::from_str::<Value>(&text) else { continue };
                    if let Some(id) = v.get("id").and_then(|i| i.as_u64()) {
                        let waiter = pending.lock().unwrap().remove(&id);
                        if let Some(w) = waiter {
                            let r = match v.get("error") {
                                Some(e) => Err(e["message"].as_str().unwrap_or("tarayıcı hatası").to_string()),
                                None => Ok(v.get("result").cloned().unwrap_or(Value::Null)),
                            };
                            let _ = w.send(r);
                        }
                    } else if let Some(m) = v.get("method").and_then(|m| m.as_str()) {
                        let _ = events.send(CdpEvent {
                            method: m.to_string(),
                            params: v.get("params").cloned().unwrap_or(Value::Null),
                            session: v.get("sessionId").and_then(|s| s.as_str()).map(String::from),
                        });
                    }
                }
                closed.store(true, Ordering::SeqCst);
                for (_, w) in pending.lock().unwrap().drain() {
                    let _ = w.send(Err("tarayıcı bağlantısı kapandı".into()));
                }
                let _ = events.send(CdpEvent { method: CLOSED.into(), params: Value::Null, session: None });
            });
        }
        Ok(Arc::new(Cdp { tx, pending, next: AtomicU64::new(1), events, closed }))
    }

    pub fn is_closed(&self) -> bool {
        self.closed.load(Ordering::SeqCst)
    }

    pub fn subscribe(&self) -> broadcast::Receiver<CdpEvent> {
        self.events.subscribe()
    }

    fn message(&self, id: u64, session: Option<&str>, method: &str, params: Value) -> String {
        let mut m = json!({"id": id, "method": method, "params": params});
        if let Some(s) = session {
            m["sessionId"] = json!(s);
        }
        m.to_string()
    }

    /// Komut gönderir ve yanıtını bekler (30 sn).
    pub async fn call(&self, session: Option<&str>, method: &str, params: Value) -> Result<Value, String> {
        self.call_timeout(session, method, params, Duration::from_secs(30)).await
    }

    pub async fn call_timeout(&self, session: Option<&str>, method: &str, params: Value, timeout: Duration) -> Result<Value, String> {
        if self.is_closed() {
            return Err("tarayıcı bağlantısı kapalı".into());
        }
        let id = self.next.fetch_add(1, Ordering::SeqCst);
        let (tx, rx) = oneshot::channel();
        self.pending.lock().unwrap().insert(id, tx);
        if self.tx.send(self.message(id, session, method, params)).is_err() {
            self.pending.lock().unwrap().remove(&id);
            return Err("tarayıcı bağlantısı kapalı".into());
        }
        match tokio::time::timeout(timeout, rx).await {
            Ok(Ok(r)) => r,
            Ok(Err(_)) => Err("tarayıcı bağlantısı kapandı".into()),
            Err(_) => {
                self.pending.lock().unwrap().remove(&id);
                Err(format!("tarayıcı yanıt vermedi ({method})"))
            }
        }
    }

    /// Yanıtı beklenmeyen komut (ör. ekran akışı karesinin onayı, kapanışta Browser.close).
    pub fn send(&self, session: Option<&str>, method: &str, params: Value) {
        let id = self.next.fetch_add(1, Ordering::SeqCst);
        let _ = self.tx.send(self.message(id, session, method, params));
    }
}
