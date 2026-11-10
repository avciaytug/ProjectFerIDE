//! OpenAI uyumlu (llama-server, Ollama, LM Studio, vLLM, bulut) akışlı istemci.
//!
//! Yanıt SSE ile alınır. Araç çağrıları hem standart `tool_calls` alanından hem de
//! bazı modellerin metne yazdığı `<tool_call>` bloklarından (Qwen/Hermes JSON veya
//! `<function=..><parameter=..>` biçimi) ayrıştırılır.

use futures::StreamExt;
use regex::Regex;
use serde::Serialize;
use serde_json::{json, Value};
use std::sync::LazyLock;
use std::time::{Duration, Instant};
use tokio_util::sync::CancellationToken;

#[derive(Clone, Debug, Serialize)]
pub struct ToolCall {
    pub id: String,
    pub name: String,
    pub raw_arguments: String,
}

impl ToolCall {
    /// Argümanları çözer; bozuksa `None`.
    pub fn arguments(&self) -> Option<Value> {
        let raw = self.raw_arguments.trim();
        if raw.is_empty() {
            return Some(json!({}));
        }
        match serde_json::from_str::<Value>(raw) {
            Ok(v @ Value::Object(_)) => Some(v),
            Ok(Value::String(s)) => serde_json::from_str::<Value>(&s).ok().filter(|v| v.is_object()),
            _ => repair_json(raw),
        }
    }

    pub fn to_payload(&self) -> Value {
        // Geçersiz JSON'u sunucuya geri göndermek llama-server'da 500 hatası doğurur.
        let args = match self.arguments() {
            Some(v) => v.to_string(),
            None => "{}".into(),
        };
        json!({"id": self.id, "type": "function", "function": {"name": self.name, "arguments": args}})
    }
}

/// Modelin ürettiği hafif bozuk JSON'u onarmayı dener (sondaki virgül, eksik kapanış).
fn repair_json(raw: &str) -> Option<Value> {
    let mut s = raw.trim().trim_end_matches(',').to_string();
    let opens = s.matches('{').count() as i64 - s.matches('}').count() as i64;
    for _ in 0..opens.max(0) {
        s.push('}');
    }
    serde_json::from_str::<Value>(&s).ok().filter(|v| v.is_object())
}

#[derive(Clone, Debug, Default, Serialize)]
pub struct Turn {
    pub content: String,
    pub reasoning: String,
    pub tool_calls: Vec<ToolCall>,
    pub prompt_tokens: Option<u64>,
    pub completion_tokens: Option<u64>,
    /// Üretim hızı (çıktı token/sn). llama-server'da sunucunun ölçtüğü değer,
    /// diğer uç noktalarda ilk token ile akış sonu arasındaki süreden hesaplanır.
    pub tokens_per_second: Option<f64>,
    /// İstem işleme hızı (girdi token/sn); yalnızca llama-server bildirir.
    pub prompt_per_second: Option<f64>,
    /// Önbellekten (KV cache) gelen, yeniden işlenmeyen girdi tokenları.
    pub cached_tokens: Option<u64>,
    /// Çıktı üretiminin süresi (sn).
    pub gen_seconds: f64,
    pub finish_reason: Option<String>,
}

#[derive(Debug)]
pub enum LlmError {
    Cancelled,
    Http { status: u16, message: String },
    Other(String),
}

impl std::fmt::Display for LlmError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            LlmError::Cancelled => write!(f, "İptal edildi"),
            LlmError::Http { message, .. } => write!(f, "{message}"),
            LlmError::Other(m) => write!(f, "{m}"),
        }
    }
}
impl std::error::Error for LlmError {}

pub enum Delta<'a> {
    Content(&'a str),
    Reasoning(&'a str),
    Status(String),
}

#[derive(Clone)]
pub struct LlmClient {
    pub base_url: String,
    pub model: String,
    pub api_key: Option<String>,
    http: reqwest::Client,
}

pub struct CompleteOptions<'a> {
    pub tools: &'a [Value],
    pub temperature: f32,
    pub max_tokens: u32,
    pub thinking: bool,
}

impl LlmClient {
    pub fn new(base_url: &str, model: &str, api_key: Option<String>) -> Self {
        let http = reqwest::Client::builder()
            .connect_timeout(Duration::from_secs(15))
            .pool_idle_timeout(Duration::from_secs(90))
            .build()
            .expect("http istemcisi");
        Self { base_url: base_url.trim_end_matches('/').to_string(), model: model.to_string(), api_key, http }
    }

    /// Bir tur tamamlama. Geçici hatalarda (503 model yükleniyor, 5xx, 429) yeniden dener.
    pub async fn complete(
        &self,
        messages: &[Value],
        opts: &CompleteOptions<'_>,
        cancel: &CancellationToken,
        on_delta: &mut (dyn FnMut(Delta) + Send),
    ) -> Result<Turn, LlmError> {
        let mut attempt = 0u32;
        loop {
            attempt += 1;
            match self.complete_once(messages, opts, cancel, on_delta).await {
                Ok(t) => return Ok(t),
                Err(LlmError::Http { status, message }) => {
                    let transient = matches!(status, 500 | 502 | 503 | 504 | 429);
                    let max = if status == 503 { 40 } else { 5 };
                    if !transient || attempt >= max {
                        return Err(LlmError::Http { status, message });
                    }
                    let wait = if status == 503 { 3 } else { attempt as u64 };
                    on_delta(Delta::Status(if status == 503 {
                        format!("Model belleğe yükleniyor ({attempt}/{max})…")
                    } else {
                        format!("Sunucu geçici hata verdi (HTTP {status}), {wait} sn sonra yeniden deneniyor…")
                    }));
                    tokio::select! {
                        _ = tokio::time::sleep(Duration::from_secs(wait)) => {}
                        _ = cancel.cancelled() => return Err(LlmError::Cancelled),
                    }
                }
                Err(e) => return Err(e),
            }
        }
    }

    async fn complete_once(
        &self,
        messages: &[Value],
        opts: &CompleteOptions<'_>,
        cancel: &CancellationToken,
        on_delta: &mut (dyn FnMut(Delta) + Send),
    ) -> Result<Turn, LlmError> {
        let mut body = json!({
            "model": self.model,
            "messages": messages,
            "stream": true,
            "stream_options": {"include_usage": true},
            "max_tokens": opts.max_tokens,
            "temperature": opts.temperature,
        });
        if self.is_local() {
            body["cache_prompt"] = json!(true);
            body["chat_template_kwargs"] = json!({"enable_thinking": opts.thinking});
        }
        if !opts.tools.is_empty() {
            body["tools"] = Value::Array(opts.tools.to_vec());
        }
        let mut req = self.http.post(format!("{}/chat/completions", self.base_url)).json(&body);
        if let Some(k) = &self.api_key {
            req = req.bearer_auth(k);
        }
        let resp = tokio::select! {
            r = req.send() => r,
            _ = cancel.cancelled() => return Err(LlmError::Cancelled),
        }
        .map_err(|e| {
            LlmError::Other(format!(
                "Model sunucusuna ulaşılamadı ({}). Modelin çalıştığından emin olun. Ayrıntı: {e}",
                self.base_url
            ))
        })?;
        let status = resp.status().as_u16();
        if status != 200 {
            let text = resp.text().await.unwrap_or_default();
            return Err(LlmError::Http { status, message: describe_http_error(status, &text) });
        }

        let mut stream = resp.bytes_stream();
        let mut buf: Vec<u8> = Vec::new();
        let mut content = String::new();
        let mut reasoning = String::new();
        let mut calls: Vec<ToolCall> = Vec::new();
        let mut call_index: Vec<i64> = Vec::new();
        let mut turn = Turn::default();
        let mut last_flush = Instant::now();
        let mut pending_c = String::new();
        let mut pending_r = String::new();
        let mut first_token: Option<Instant> = None;
        let mut predicted_ms: Option<f64> = None;

        'outer: loop {
            let chunk = tokio::select! {
                c = tokio::time::timeout(Duration::from_secs(300), stream.next()) => c,
                _ = cancel.cancelled() => return Err(LlmError::Cancelled),
            };
            let chunk = match chunk {
                Err(_) => return Err(LlmError::Other("Model 5 dakikadır yanıt üretmiyor; bağlantı kesildi.".into())),
                Ok(None) => break,
                Ok(Some(Err(e))) => return Err(LlmError::Other(format!("Akış kesildi: {e}"))),
                Ok(Some(Ok(b))) => b,
            };
            buf.extend_from_slice(&chunk);
            while let Some(pos) = buf.iter().position(|&b| b == b'\n') {
                let line: Vec<u8> = buf.drain(..=pos).collect();
                let line = String::from_utf8_lossy(&line);
                let line = line.trim();
                let Some(data) = line.strip_prefix("data:") else { continue };
                let data = data.trim();
                if data == "[DONE]" {
                    break 'outer;
                }
                let Ok(j) = serde_json::from_str::<Value>(data) else { continue };
                if let Some(u) = j.get("usage").filter(|u| u.is_object()) {
                    turn.prompt_tokens = u["prompt_tokens"].as_u64().or(turn.prompt_tokens);
                    turn.completion_tokens = u["completion_tokens"].as_u64().or(turn.completion_tokens);
                    turn.cached_tokens = u["prompt_tokens_details"]["cached_tokens"].as_u64().or(turn.cached_tokens);
                }
                if let Some(t) = j.get("timings").filter(|t| t.is_object()) {
                    turn.tokens_per_second = t["predicted_per_second"].as_f64().or(turn.tokens_per_second);
                    turn.prompt_per_second = t["prompt_per_second"].as_f64().or(turn.prompt_per_second);
                    predicted_ms = t["predicted_ms"].as_f64().or(predicted_ms);
                    if let Some(c) = t["cache_n"].as_u64() {
                        turn.cached_tokens = Some(c);
                    }
                    if turn.completion_tokens.is_none() {
                        turn.completion_tokens = t["predicted_n"].as_u64();
                    }
                    if turn.prompt_tokens.is_none() {
                        if let Some(n) = t["prompt_n"].as_u64() {
                            turn.prompt_tokens = Some(n + t["cache_n"].as_u64().unwrap_or(0));
                        }
                    }
                }
                let Some(choice) = j["choices"].get(0) else { continue };
                if let Some(fr) = choice["finish_reason"].as_str() {
                    turn.finish_reason = Some(fr.to_string());
                }
                let delta = &choice["delta"];
                if first_token.is_none()
                    && ["content", "reasoning_content", "reasoning", "tool_calls"]
                        .iter()
                        .any(|k| delta[k].as_str().is_some_and(|s| !s.is_empty()) || delta[k].is_array())
                {
                    first_token = Some(Instant::now());
                }
                let r = delta["reasoning_content"].as_str().or(delta["reasoning"].as_str());
                if let Some(r) = r.filter(|r| !r.is_empty()) {
                    reasoning.push_str(r);
                    pending_r.push_str(r);
                }
                if let Some(c) = delta["content"].as_str().filter(|c| !c.is_empty()) {
                    content.push_str(c);
                    pending_c.push_str(c);
                }
                if let Some(tcs) = delta["tool_calls"].as_array() {
                    for tc in tcs {
                        let idx = tc["index"].as_i64().unwrap_or(calls.len() as i64);
                        let f = &tc["function"];
                        if let Some(pos) = call_index.iter().position(|&i| i == idx) {
                            if let Some(a) = f["arguments"].as_str() {
                                calls[pos].raw_arguments.push_str(a);
                            }
                            if let Some(n) = f["name"].as_str().filter(|n| !n.is_empty()) {
                                if calls[pos].name.is_empty() {
                                    calls[pos].name = n.to_string();
                                }
                            }
                        } else {
                            call_index.push(idx);
                            calls.push(ToolCall {
                                id: tc["id"].as_str().map(String::from).unwrap_or_else(new_call_id),
                                name: f["name"].as_str().unwrap_or("").to_string(),
                                raw_arguments: f["arguments"].as_str().unwrap_or("").to_string(),
                            });
                        }
                    }
                }
            }
            // Arayüzü en fazla ~30 fps güncelle.
            if last_flush.elapsed() >= Duration::from_millis(33) {
                flush(&mut pending_c, &mut pending_r, on_delta);
                last_flush = Instant::now();
            }
        }
        flush(&mut pending_c, &mut pending_r, on_delta);

        let wall = first_token.map(|t| t.elapsed().as_secs_f64()).unwrap_or(0.0);
        turn.gen_seconds = predicted_ms.map(|ms| ms / 1000.0).unwrap_or(wall);
        if turn.tokens_per_second.is_none() {
            if let Some(n) = turn.completion_tokens.filter(|n| *n > 0) {
                if turn.gen_seconds > 0.05 {
                    turn.tokens_per_second = Some(n as f64 / turn.gen_seconds);
                }
            }
        }

        let mut calls: Vec<ToolCall> = calls.into_iter().filter(|c| !c.name.is_empty()).collect();
        let mut text = content;
        if calls.is_empty() {
            let (parsed, rest) = parse_inline_tool_calls(&text);
            if !parsed.is_empty() {
                calls = parsed;
                text = rest;
            }
        }
        let (visible, think) = split_think(&text);
        if !think.is_empty() && reasoning.is_empty() {
            reasoning = think;
        }
        turn.content = visible;
        turn.reasoning = reasoning;
        turn.tool_calls = calls;
        Ok(turn)
    }

    pub fn is_local(&self) -> bool {
        self.base_url.contains("127.0.0.1") || self.base_url.contains("localhost")
    }

    /// Araçsız, akışsız kısa tamamlama (özetleme, başlık üretme).
    pub async fn simple(&self, messages: &[Value], max_tokens: u32, cancel: &CancellationToken) -> Result<String, LlmError> {
        let opts = CompleteOptions { tools: &[], temperature: 0.3, max_tokens, thinking: false };
        let mut sink = |_d: Delta| {};
        let t = self.complete(messages, &opts, cancel, &mut sink).await?;
        Ok(if t.content.trim().is_empty() { t.reasoning } else { t.content })
    }
}

fn flush(c: &mut String, r: &mut String, on_delta: &mut (dyn FnMut(Delta) + Send)) {
    if !r.is_empty() {
        on_delta(Delta::Reasoning(r));
        r.clear();
    }
    if !c.is_empty() {
        on_delta(Delta::Content(c));
        c.clear();
    }
}

pub fn new_call_id() -> String {
    format!("call_{}", &uuid::Uuid::new_v4().simple().to_string()[..20])
}

static THINK_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?s)<think>(.*?)</think>").unwrap());

/// Görünür metni ve `<think>` içeriğini ayırır; `<tool_call>` ve sonrası gizlenir.
pub fn split_think(text: &str) -> (String, String) {
    let mut t = text.to_string();
    if let Some(i) = t.find("<tool_call>") {
        t.truncate(i);
    }
    let mut think = String::new();
    for c in THINK_RE.captures_iter(&t) {
        think.push_str(c[1].trim());
        think.push('\n');
    }
    let mut visible = THINK_RE.replace_all(&t, "").to_string();
    if let Some(i) = visible.find("<think>") {
        think.push_str(&visible[i + 7..]);
        visible.truncate(i);
    }
    (visible.trim().to_string(), think.trim().to_string())
}

static BLOCK_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?s)<tool_call>(.*?)(?:</tool_call>|$)").unwrap());
static FN_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?s)<function=([^>]+)>(.*?)(?:</function>|$)").unwrap());
static PARAM_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?s)<parameter=([^>]+)>(.*?)</parameter>").unwrap());

/// Metin içine gömülü araç çağrılarını çözer.
pub fn parse_inline_tool_calls(text: &str) -> (Vec<ToolCall>, String) {
    let mut calls = vec![];
    for m in BLOCK_RE.captures_iter(text) {
        let inner = m[1].trim();
        if inner.is_empty() {
            continue;
        }
        if let Some(f) = FN_RE.captures(inner) {
            let name = f[1].trim().to_string();
            let params = f[2].trim();
            let args = if params.starts_with('{') {
                params.to_string()
            } else {
                let mut map = serde_json::Map::new();
                for p in PARAM_RE.captures_iter(params) {
                    map.insert(p[1].trim().to_string(), coerce_scalar(p[2].trim()));
                }
                Value::Object(map).to_string()
            };
            calls.push(ToolCall { id: new_call_id(), name, raw_arguments: args });
            continue;
        }
        if let Ok(v) = serde_json::from_str::<Value>(inner) {
            if let Some(name) = v["name"].as_str() {
                let a = v.get("arguments").or(v.get("parameters")).cloned().unwrap_or(json!({}));
                let raw = if let Value::String(s) = &a { s.clone() } else { a.to_string() };
                calls.push(ToolCall { id: new_call_id(), name: name.to_string(), raw_arguments: raw });
            }
        }
    }
    let rest = BLOCK_RE.replace_all(text, "").trim().to_string();
    (calls, rest)
}

fn coerce_scalar(v: &str) -> Value {
    match v {
        "true" => return json!(true),
        "false" => return json!(false),
        _ => {}
    }
    if let Ok(i) = v.parse::<i64>() {
        return json!(i);
    }
    if let Ok(f) = v.parse::<f64>() {
        return json!(f);
    }
    if (v.starts_with('{') && v.ends_with('}')) || (v.starts_with('[') && v.ends_with(']')) {
        if let Ok(j) = serde_json::from_str::<Value>(v) {
            return j;
        }
    }
    json!(v)
}

pub fn describe_http_error(status: u16, body: &str) -> String {
    let mut detail = body.to_string();
    if let Ok(j) = serde_json::from_str::<Value>(body) {
        if let Some(m) = j["error"]["message"].as_str() {
            detail = m.to_string();
        } else if !j["error"].is_null() {
            detail = j["error"].to_string();
        }
    }
    let detail = crate::util::truncate_end(&detail, 600);
    let lower = detail.to_lowercase();
    if lower.contains("mmproj") || lower.contains("image input is not supported") {
        return "Görsel desteği yok: model görsel adaptörü (mmproj) olmadan başlatılmış. Model Merkezi'nden adaptörü \
                indirip modeli yeniden başlatın."
            .into();
    }
    if lower.contains("context") && (lower.contains("exceed") || lower.contains("too long") || lower.contains("n_ctx")) {
        return format!(
            "Bağlam sınırı aşıldı: sohbet, modelin başlatıldığı bağlam boyutuna sığmıyor. Yeni sohbet başlatın ya da \
             Model Merkezi'nden bağlamı büyütüp modeli yeniden başlatın. ({detail})"
        );
    }
    if status == 401 || status == 403 {
        return format!("Uç nokta erişimi reddetti (HTTP {status}): API anahtarını kontrol edin. {detail}");
    }
    format!("Model sunucusu hata döndürdü [HTTP {status}]: {detail}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn inline_json_call() {
        let (c, rest) = parse_inline_tool_calls(
            "Bakıyorum.\n<tool_call>{\"name\": \"read_file\", \"arguments\": {\"path\": \"a.txt\"}}</tool_call>",
        );
        assert_eq!(c.len(), 1);
        assert_eq!(c[0].name, "read_file");
        assert_eq!(c[0].arguments().unwrap()["path"], "a.txt");
        assert_eq!(rest, "Bakıyorum.");
    }

    #[test]
    fn inline_xml_call() {
        let (c, _) = parse_inline_tool_calls(
            "<tool_call><function=run_command><parameter=command>ls -la</parameter><parameter=timeout_secs>30</parameter></function></tool_call>",
        );
        assert_eq!(c[0].name, "run_command");
        let a = c[0].arguments().unwrap();
        assert_eq!(a["command"], "ls -la");
        assert_eq!(a["timeout_secs"], 30);
    }

    #[test]
    fn think_split() {
        let (v, t) = split_think("<think>plan yapıyorum</think>Merhaba!");
        assert_eq!(v, "Merhaba!");
        assert_eq!(t, "plan yapıyorum");
        let (v, _) = split_think("Cevap <tool_call>{...}");
        assert_eq!(v, "Cevap");
    }

    #[test]
    fn broken_args_repaired_or_rejected() {
        let c = ToolCall { id: "1".into(), name: "x".into(), raw_arguments: "{\"a\": 1".into() };
        assert_eq!(c.arguments().unwrap()["a"], 1);
        let bad = ToolCall { id: "1".into(), name: "x".into(), raw_arguments: "not json".into() };
        assert!(bad.arguments().is_none());
        assert_eq!(bad.to_payload()["function"]["arguments"], "{}");
    }

    #[test]
    fn errors_translated() {
        assert!(describe_http_error(400, r#"{"error":{"message":"the request exceeds the available context size"}}"#)
            .contains("Bağlam sınırı"));
    }
}
