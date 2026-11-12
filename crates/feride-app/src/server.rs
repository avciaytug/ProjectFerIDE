//! Yerel sunucu: arayüz dosyaları + WebSocket JSON-RPC/olay akışı.
//!
//! Güvenlik:
//! * Yalnızca 127.0.0.1 dinlenir (başsız modda `--listen` ile açıkça değiştirilebilir).
//! * Her açılışta yeni rastgele jeton; WebSocket bağlantısı jetonsuz kabul edilmez.
//! * Tarayıcıdan gelen bağlantılarda `Origin` yalnızca FerIDE'nin kendi adresi olabilir
//!   (başka bir web sitesi yerel FerIDE'ye bağlanamaz).
//! * Sıkı içerik güvenlik politikası (CSP): satır içi betik yok, dış kaynak yok.

use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::{Query, State};
use axum::http::{header, HeaderMap, HeaderValue, StatusCode, Uri};
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use axum::Router;
use futures::{SinkExt, StreamExt};
use rust_embed::RustEmbed;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::Arc;
use tokio::sync::{mpsc, Notify};

use feride_core::Core;

#[derive(RustEmbed)]
#[folder = "../../ui/"]
struct Ui;

#[derive(Clone)]
pub struct AppState {
    pub core: Arc<Core>,
    pub token: String,
    pub port: u16,
    pub quit: Arc<Notify>,
    pub desktop: bool,
}

pub(crate) const CSP: &str = "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; \
media-src 'self' data: blob:; font-src 'self' data:; connect-src 'self' ws://127.0.0.1:* ws://localhost:*; \
object-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'";

pub struct Started {
    pub port: u16,
    pub token: String,
    pub quit: Arc<Notify>,
}

pub async fn start(core: Arc<Core>, listen: &str, port: u16, desktop: bool) -> anyhow::Result<Started> {
    let listener = tokio::net::TcpListener::bind(format!("{listen}:{port}")).await?;
    let port = listener.local_addr()?.port();
    let token = feride_core::util::random_token();
    let quit = Arc::new(Notify::new());
    let state = AppState { core, token: token.clone(), port, quit: quit.clone(), desktop };
    let app = Router::new().route("/ws", get(ws_handler)).fallback(get(static_handler)).with_state(state);
    tokio::spawn(async move {
        if let Err(e) = axum::serve(listener, app.into_make_service_with_connect_info::<SocketAddr>()).await {
            tracing::error!("sunucu durdu: {e}");
        }
    });
    Ok(Started { port, token, quit })
}

pub(crate) async fn static_handler(uri: Uri) -> Response {
    let mut path = uri.path().trim_start_matches('/').to_string();
    if path.is_empty() {
        path = "index.html".into();
    }
    if path.contains("..") {
        return StatusCode::BAD_REQUEST.into_response();
    }
    match Ui::get(&path) {
        Some(f) => {
            let mime = mime_guess::from_path(&path).first_or_octet_stream();
            let mut r = (StatusCode::OK, f.data.into_owned()).into_response();
            let h = r.headers_mut();
            h.insert(header::CONTENT_TYPE, HeaderValue::from_str(mime.as_ref()).unwrap());
            h.insert(header::CONTENT_SECURITY_POLICY, HeaderValue::from_static(CSP));
            h.insert("X-Content-Type-Options", HeaderValue::from_static("nosniff"));
            h.insert("Referrer-Policy", HeaderValue::from_static("no-referrer"));
            h.insert(header::CACHE_CONTROL, HeaderValue::from_static("no-cache"));
            r
        }
        None => StatusCode::NOT_FOUND.into_response(),
    }
}

async fn ws_handler(
    ws: WebSocketUpgrade,
    State(st): State<AppState>,
    Query(q): Query<HashMap<String, String>>,
    headers: HeaderMap,
) -> Response {
    let token_ok = q.get("token").map(|t| feride_core::util::ct_eq(t, &st.token)).unwrap_or(false);
    if !token_ok {
        tracing::warn!("geçersiz jetonla WebSocket bağlantı denemesi");
        return StatusCode::UNAUTHORIZED.into_response();
    }
    if let Some(origin) = headers.get(header::ORIGIN).and_then(|o| o.to_str().ok()) {
        let allowed = [format!("http://127.0.0.1:{}", st.port), format!("http://localhost:{}", st.port)];
        if !allowed.iter().any(|a| a == origin) {
            tracing::warn!("izin verilmeyen kaynaktan bağlantı: {origin}");
            return StatusCode::FORBIDDEN.into_response();
        }
    }
    ws.max_message_size(64 << 20).on_upgrade(move |socket| client(socket, st))
}

async fn client(socket: WebSocket, st: AppState) {
    let (mut sink, mut stream) = socket.split();
    let (tx, mut rx) = mpsc::unbounded_channel::<String>();
    // Yazıcı
    let writer = tokio::spawn(async move {
        while let Some(m) = rx.recv().await {
            if sink.send(Message::Text(m.into())).await.is_err() {
                break;
            }
        }
    });
    // Olayları ilet
    let mut events = st.core.events.subscribe();
    let etx = tx.clone();
    let forwarder = tokio::spawn(async move {
        loop {
            match events.recv().await {
                Ok(ev) => {
                    if etx.send(json!({"event": ev.topic, "data": ev.data}).to_string()).is_err() {
                        break;
                    }
                }
                Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                    let _ = etx.send(json!({"event": "lagged", "data": {"missed": n}}).to_string());
                }
                Err(_) => break,
            }
        }
    });
    while let Some(Ok(msg)) = stream.next().await {
        let text = match msg {
            Message::Text(t) => t.to_string(),
            Message::Close(_) => break,
            _ => continue,
        };
        let Ok(req) = serde_json::from_str::<Value>(&text) else { continue };
        let id = req["id"].clone();
        let method = req["method"].as_str().unwrap_or("").to_string();
        let params = req.get("params").cloned().unwrap_or(json!({}));
        let st2 = st.clone();
        let tx2 = tx.clone();
        tokio::spawn(async move {
            let res = crate::rpc::handle(&st2, &method, params).await;
            let out = match res {
                Ok(v) => json!({"id": id, "result": v}),
                Err(e) => {
                    tracing::debug!("rpc {method} hata: {e:#}");
                    json!({"id": id, "error": format!("{e}")})
                }
            };
            let _ = tx2.send(out.to_string());
        });
    }
    forwarder.abort();
    drop(tx);
    let _ = writer.await;
}
