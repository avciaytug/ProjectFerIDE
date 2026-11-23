//! Bağlam yönetimi: uzun görevler modelin bağlamına sığmazsa iş durmaz.
//!
//! - Ölçüm (`Meter`): kaba karakter tahmini, sunucunun bildirdiği gerçek istem token sayısıyla her adımda ayarlanır.
//! - Yer açma: Otomatik bağlamda bellek elverirse önce bağlam büyütülür (`Core::grow_context`); yetmezse eski kısım
//!   sıkıştırılır (`compact`): önce eski büyük araç çıktıları, dosya içerikleri ve görseller kısaltılır; bu yetmezse
//!   eski kısım modelin kendi yazdığı bir çalışma özetiyle değiştirilir. Kesme noktası bir "birim" başıdır (kullanıcı
//!   mesajı ya da asistan mesajı + araç yanıtları): araç çağrısı/yanıt çiftleri bölünmez, uzun tek bir görevin ortasında
//!   da kesilebilir.
//! - Kalıcılık: sohbet dosyasındaki geçmiş silinmez. Sıkıştırmadan sonra modelin göreceği mesajlar bir `compaction`
//!   kaydı olarak dosyaya eklenir; `model_view` modele gidecek geçmişi son kayıttan itibaren kurar. Arayüz geçmişin
//!   tamamını gösterir, kaydı bir ayraç olarak çizer.

use serde_json::{json, Value};
use std::time::{Duration, Instant};
use tokio_util::sync::CancellationToken;

use crate::llm::{CompleteOptions, Delta, LlmClient, LlmError};
use crate::sessions::content_text;

/// Kaba token tahmini (~3 karakter/token; görsel ~800 token). Gerçek değere `Meter` yaklaştırır.
pub fn estimate_tokens(messages: &[Value]) -> i64 {
    let mut chars = 0usize;
    let mut images = 0;
    for m in messages {
        match &m["content"] {
            Value::String(s) => chars += s.len(),
            Value::Array(parts) => {
                for p in parts {
                    if p["type"] == "text" {
                        chars += p["text"].as_str().map(|s| s.len()).unwrap_or(0);
                    } else {
                        images += 1;
                    }
                }
            }
            _ => {}
        }
        if let Some(tc) = m["tool_calls"].as_array() {
            for c in tc {
                chars += c["function"]["arguments"].as_str().map(|s| s.len()).unwrap_or(0) + 30;
            }
        }
        chars += 12;
    }
    (chars / 3) as i64 + images * 800
}

/// Araç tanımlarının token tahmini.
pub fn tools_tokens(tools: &[Value]) -> i64 {
    (tools.iter().map(|t| t.to_string().len()).sum::<usize>() / 3) as i64
}

/// Token ölçer: tahmini, sunucunun bildirdiği gerçek istem uzunluğuna göre ölçekler. Kod ve İngilizce metinde
/// karakter/token oranı Türkçeden farklı olduğundan sabit bir oran bağlamı yanlış ölçer (sohbet "%85" sanılırken
/// gerçekte dolabilir).
#[derive(Clone, Debug)]
pub struct Meter {
    ratio: f64,
}

impl Default for Meter {
    fn default() -> Self {
        // İlk gerçek ölçüme kadar ihtiyatlı: tahmin genellikle eksik kalır.
        Self { ratio: 1.2 }
    }
}

impl Meter {
    /// Önceki turda ölçülen oranla başlar.
    pub fn with_ratio(ratio: f64) -> Self {
        Self { ratio: ratio.clamp(0.4, 4.0) }
    }

    pub fn ratio(&self) -> f64 {
        self.ratio
    }

    /// Ham tahmini gerçek token ölçeğine çevirir.
    pub fn scale(&self, est: i64) -> i64 {
        (est as f64 * self.ratio).ceil() as i64
    }

    /// Mesajlar + araç tanımları için beklenen istem uzunluğu (token).
    pub fn tokens(&self, messages: &[Value], tools_est: i64) -> i64 {
        self.scale(estimate_tokens(messages) + tools_est)
    }

    /// Sunucunun bu mesajlar için bildirdiği gerçek istem uzunluğuyla oranı günceller.
    pub fn observe(&mut self, real: i64, messages: &[Value], tools_est: i64) {
        let est = estimate_tokens(messages) + tools_est;
        if real > 0 && est >= 1000 {
            self.ratio = (real as f64 / est as f64).clamp(0.4, 4.0);
        }
    }

    /// Sunucu bağlamın aşıldığını bildirdi: gerçek uzunluk biliniyorsa ona, bilinmiyorsa en az %25 yukarı ayarla.
    pub fn observe_overflow(&mut self, real: Option<i64>, messages: &[Value], tools_est: i64) {
        let before = self.ratio;
        if let Some(r) = real.filter(|r| *r > 0) {
            self.observe(r, messages, tools_est);
        }
        if self.ratio <= before {
            self.ratio = (before * 1.25).min(4.0);
        }
    }
}

/// Bir adımın çıktısı (düşünce + yanıt + araç argümanları) için bağlamda boş bırakılan yer.
pub fn out_reserve(n_ctx: i64) -> i64 {
    (n_ctx / 8).clamp(1024, 16384)
}

/// Bir model adımına izin verilen en uzun çıktı. Yerel sunucuda bağlamda kalan yerin tamamı (en fazla 32K) kullanılabilir;
/// düşünen modeller büyük dosyaları yazarken 8K'yı kolayca aşar. Uzak uç noktalarda sağlayıcı sınırları yüzünden 8K.
pub fn step_max_tokens(local: bool, n_ctx: i64, need: i64) -> u32 {
    if !local {
        return 8192;
    }
    (n_ctx - need - 256).clamp(1024, 32768) as u32
}

/// Bu kadar tam tarayıcı çıktısı birikince sonuncusu dışındakiler kısaltılır.
const BROWSER_FULL_MAX: usize = 3;

/// Eski tarayıcı çıktıları (sayfa metinleri, ekran görüntüleri) bağlamı doldurmasın: tam çıktı sayısı sınırı aşınca
/// sonuncusu dışındakiler tek satırlık bir özetle değiştirilir. Kısaltma toplu yapılır ki yerel sunucu önbelleği (KV)
/// her adımda bozulmasın. Kısa çıktılar (hatalar, kullanıcı yanıtları) olduğu gibi kalır.
pub fn elide_browser(messages: &mut [Value]) {
    let full: Vec<usize> = messages
        .iter()
        .enumerate()
        .filter(|(_, m)| m["role"] == "tool" && m["name"] == "browser" && (!m["content"].is_string() || content_text(&m["content"]).chars().count() > 700))
        .map(|(i, _)| i)
        .collect();
    if full.len() <= BROWSER_FULL_MAX {
        return;
    }
    for &i in &full[..full.len() - 1] {
        let text = content_text(&messages[i]["content"]);
        if text.chars().count() <= 700 {
            // Yalnızca görsel atılır, metin kalır.
            messages[i]["content"] = json!(text);
            continue;
        }
        let head = text.lines().find(|l| l.starts_with("Sayfa: ")).map(|l| crate::util::truncate_end(l, 200)).unwrap_or_default();
        messages[i]["content"] = json!(format!(
            "<untrusted_content source=\"browser\">[Eski tarayıcı çıktısı kaldırıldı] {head}</untrusted_content>"
        ));
    }
}

/// Sohbet dosyasındaki kayıtlardan modele gidecek geçmiş: son `compaction` kaydının sakladığı mesajlar + ondan sonra
/// eklenenler. Arayüze özel alanlar (düşünce, kullanım, ses ve otomatik mesaj işaretleri) ve notlar atılır.
pub fn model_view(history: Vec<Value>) -> Vec<Value> {
    let start = history.iter().rposition(|m| m["role"] == "compaction" && m["messages"].is_array());
    let mut out: Vec<Value> = match start {
        Some(j) => history[j]["messages"].as_array().cloned().unwrap_or_default(),
        None => vec![],
    };
    let skip = start.map(|j| j + 1).unwrap_or(0);
    out.extend(history.into_iter().skip(skip).filter(|m| matches!(m["role"].as_str(), Some("user" | "assistant" | "tool"))));
    for m in out.iter_mut() {
        if let Some(o) = m.as_object_mut() {
            for k in ["reasoning", "usage", "voice", "auto"] {
                o.remove(k);
            }
        }
    }
    out
}

/// Kullanıcı mesajı ekler; son mesaj da kullanıcı mesajıysa (ör. önceki tur yanıtsız kaldıysa) ona eklenir. Bazı sohbet
/// şablonları (Gemma, Mistral) art arda iki kullanıcı mesajını reddeder.
pub fn push_user(messages: &mut Vec<Value>, msg: Value) {
    let Some(last) = messages.last_mut().filter(|m| m["role"] == "user") else {
        messages.push(msg);
        return;
    };
    let parts = |c: &Value| -> Vec<Value> {
        match c {
            Value::String(s) => vec![json!({"type": "text", "text": s})],
            Value::Array(a) => a.clone(),
            _ => vec![],
        }
    };
    let (a, b) = (parts(&last["content"]), parts(&msg["content"]));
    last["content"] = if a.iter().chain(b.iter()).all(|p| p["type"] == "text") {
        json!(format!("{}\n\n{}", content_text(&last["content"]), content_text(&msg["content"])))
    } else {
        let mut all = a;
        all.extend(b);
        Value::Array(all)
    };
}

/// Sıkıştırmanın sonucu (arayüzde ayraç olarak gösterilir ve sohbet dosyasına yazılır).
#[derive(Clone, Debug)]
pub struct Compaction {
    /// "trim": yalnızca eski büyük çıktılar kısaltıldı; "summary": eski kısım bir özetle değiştirildi.
    pub kind: &'static str,
    pub summary: Option<String>,
    /// Öncesi ve sonrası (tahmini token).
    pub before: i64,
    pub after: i64,
}

impl Compaction {
    /// Sohbet dosyasına yazılacak kayıt: modelin bundan sonra göreceği mesajlar (`messages[1..]`) dahil.
    pub fn record(&self, messages: &[Value]) -> Value {
        let kept: Vec<Value> = messages
            .iter()
            .skip(1)
            .map(|m| {
                // Araç sonuçlarındaki görseller (ekran görüntüleri) dosyaya yazılmaz.
                if m["role"] == "tool" && m["content"].is_array() {
                    let mut m = m.clone();
                    m["content"] = json!(content_text(&m["content"]));
                    m
                } else {
                    m.clone()
                }
            })
            .collect();
        json!({
            "role": "compaction", "kind": self.kind, "summary": self.summary, "before": self.before, "after": self.after,
            "at": crate::util::now_iso(), "messages": kept,
        })
    }
}

/// Sıkıştırma girdileri.
pub struct CompactInput<'a> {
    pub n_ctx: i64,
    /// Ana döngünün kullandığı araç tanımları (özet isteği aynı öneki gönderip sunucu önbelleğini kullanabilsin diye).
    pub tools: &'a [Value],
    pub thinking: bool,
    /// Ajanın güncel yapılacaklar listesi (özete eklenir).
    pub todos: String,
    /// Sunucu bağlamın aşıldığını bildirdi: özet, sığmayan istemle değil ayrı bir istekle yazılır.
    pub overflow: bool,
}

/// Özet mesajının başlığı (yeniden özetlemede tanınır).
const SUMMARY_HEAD: &str = "[Bağlam özeti]";
const TASK_HEAD: &str = "[Kullanıcının son isteği]";

/// Mesajların "birim" başları: kullanıcı ya da asistan mesajı (araç yanıtları kendinden önceki asistan mesajına aittir).
fn unit_starts(messages: &[Value]) -> Vec<usize> {
    messages
        .iter()
        .enumerate()
        .skip(1)
        .filter(|(_, m)| matches!(m["role"].as_str(), Some("user" | "assistant")))
        .map(|(i, _)| i)
        .collect()
}

fn truncate_note(s: &str, keep: usize, what: &str) -> String {
    let n = s.chars().count();
    if n <= keep {
        return s.to_string();
    }
    let head = keep * 2 / 3;
    let tail = keep - head;
    let h: String = s.chars().take(head).collect();
    let t: String = s.chars().skip(n - tail).collect();
    format!("{h}\n… [{what}: {} karakter kısaltıldı] …\n{t}", n - keep)
}

/// JSON değerindeki uzun metinleri (ör. write_file içeriği) kısaltır; JSON geçerli kalır.
fn shrink_strings(v: &mut Value, max: usize) -> bool {
    match v {
        Value::String(s) if s.chars().count() > max => {
            *s = truncate_note(s, max, "eski içerik, dosyanın güncel hali diskte");
            true
        }
        // Her öğe kısaltılmalı: ilk değişiklikte durulmaz.
        Value::Array(a) => {
            let mut changed = false;
            for x in a.iter_mut() {
                changed |= shrink_strings(x, max);
            }
            changed
        }
        Value::Object(o) => {
            let mut changed = false;
            for x in o.values_mut() {
                changed |= shrink_strings(x, max);
            }
            changed
        }
        _ => false,
    }
}

/// Eski mesajlardaki büyük içerikleri kısaltır: araç çıktıları, araç argümanlarındaki dosya içerikleri, uzun asistan
/// metinleri, yapıştırılmış dev metinler ve görseller. `scale`: 1 = olağan sınırlar, daha küçüğü daha sert.
fn trim_bulk(messages: &mut [Value], scale: f64) -> bool {
    let lim = |n: usize| ((n as f64 * scale) as usize).max(200);
    let mut changed = false;
    for m in messages.iter_mut() {
        match m["role"].as_str() {
            Some("tool") => {
                let text = content_text(&m["content"]);
                let short = truncate_note(&text, lim(1500), "eski araç çıktısı");
                if short != text || !m["content"].is_string() {
                    m["content"] = json!(short);
                    changed = true;
                }
            }
            Some("assistant") => {
                if let Some(s) = m["content"].as_str() {
                    let short = truncate_note(s, lim(3000), "eski yanıt");
                    if short != s {
                        m["content"] = json!(short);
                        changed = true;
                    }
                }
                if let Some(calls) = m["tool_calls"].as_array_mut() {
                    for c in calls {
                        let raw = c["function"]["arguments"].as_str().unwrap_or("").to_string();
                        if raw.chars().count() <= lim(800) {
                            continue;
                        }
                        let new = match serde_json::from_str::<Value>(&raw) {
                            Ok(mut v) => {
                                if !shrink_strings(&mut v, lim(600)) {
                                    continue;
                                }
                                v.to_string()
                            }
                            Err(_) => "{}".to_string(),
                        };
                        c["function"]["arguments"] = json!(new);
                        changed = true;
                    }
                }
            }
            Some("user") => match &m["content"] {
                Value::String(s) => {
                    let short = truncate_note(s, lim(8000), "eski mesaj");
                    if &short != s {
                        m["content"] = json!(short);
                        changed = true;
                    }
                }
                Value::Array(_) => {
                    // Eski görseller atılır, metin kalır.
                    let text = truncate_note(&content_text(&m["content"]), lim(8000), "eski mesaj");
                    m["content"] = json!(text.replace("[görsel]", "[görsel kaldırıldı]"));
                    changed = true;
                }
                _ => {}
            },
            _ => {}
        }
    }
    changed
}

/// Kullanıcının en son (otomatik olmayan) isteği. Önceki bir özetin içindeyse oradan çıkarılır.
fn last_user_request(messages: &[Value]) -> Option<(usize, String)> {
    let (i, m) = messages
        .iter()
        .enumerate()
        .skip(1)
        .rev()
        .find(|(_, m)| m["role"] == "user" && m["auto"] != true && !content_text(&m["content"]).starts_with("[FerIDE]"))?;
    let text = content_text(&m["content"]);
    if text.starts_with(SUMMARY_HEAD) {
        if let Some(p) = text.find("[Güncel mesaj]\n") {
            return Some((i, text[p + "[Güncel mesaj]\n".len()..].to_string()));
        }
        if let Some(p) = text.find(&format!("{TASK_HEAD}\n")) {
            let rest = &text[p + TASK_HEAD.len() + 1..];
            let end = rest.find("\n\n[Talimat]").unwrap_or(rest.len());
            return Some((i, rest[..end].to_string()));
        }
        return None;
    }
    Some((i, text))
}

/// Özet + (gerekirse) kullanıcının son isteği + yapılacaklar listesinden kurulan kullanıcı mesajı metni.
fn summary_block(summary: &str, todos: &str, task: Option<&str>) -> String {
    let mut s = format!(
        "{SUMMARY_HEAD} Konuşmanın eski kısmı modelin bağlamına sığmadığı için FerIDE onu aşağıdaki özetle değiştirdi. \
         Bu senin kendi çalışmanın özeti; kullanıcıya özetten bahsetmen gerekmez.\n\n{}",
        summary.trim()
    );
    if !todos.trim().is_empty() {
        s.push_str(&format!("\n\n[Yapılacaklar listen]\n{}", todos.trim()));
    }
    if let Some(t) = task.filter(|t| !t.trim().is_empty()) {
        s.push_str(&format!("\n\n{TASK_HEAD}\n{}", crate::util::truncate_middle(t.trim(), 6000)));
    }
    s.push_str(
        "\n\n[Talimat] Kaldığın yerden devam et. Bir dosyanın güncel halinden emin değilsen düzenlemeden önce yeniden oku.",
    );
    s
}

const SUMMARY_INSTRUCTION: &str = "Bağlam penceresi dolmak üzere: konuşmanın buraya kadarki kısmı birazdan senin yazacağın \
bir çalışma özetiyle değiştirilecek. Görevi kaldığın yerden kesintisiz sürdürebilmen için gereken her şeyi içeren özeti \
şimdi yaz. Araç çağırma; uzun düşünme, doğrudan özeti yaz.\n\nŞu başlıkları kullan (kısa maddeler, en fazla ~500 kelime):\n\
1. Amaç ve istekler — kullanıcının istekleri ve tercihleri (önemli olanları aynen).\n\
2. Yapılanlar — tamamlanan adımlar, alınan kararlar ve nedenleri.\n\
3. Dosyalar — oluşturulan/değiştirilen dosyalar (tam yol) ve her birinde ne olduğu.\n\
4. Komutlar ve sonuçlar — testler, derlemeler, önemli çıktılar ve hatalar.\n\
5. Açık sorunlar — çözülmemiş hatalar, doğrulanamayanlar.\n\
6. Şu anki iş — tam olarak nerede kaldığın ve sıradaki ilk somut adım.";

const SUMMARIZER_SYSTEM: &str = "Bir yazılım ajanının uzun çalışma oturumunun eski kısmını özetliyorsun. Özet, ajanın işe \
kaldığı yerden kesintisiz devam edebilmesi için gereken her şeyi içermeli. Önceki bir özet varsa onu da kapsa.";

/// Eski kısmı özet isteği için metne döker (yeni, önbelleksiz istek: yalnızca bağlam aşıldığında kullanılır).
fn transcript(old: &[Value], max_chars: usize) -> String {
    let mut out = String::new();
    for m in old {
        let text = content_text(&m["content"]);
        match m["role"].as_str().unwrap_or("") {
            "user" if text.starts_with(SUMMARY_HEAD) => out.push_str(&format!("ÖNCEKİ ÖZET:\n{}\n\n", crate::util::truncate_middle(&text, 12000))),
            "user" => out.push_str(&format!("KULLANICI: {}\n", crate::util::truncate_middle(&text, 4000))),
            "assistant" => {
                if !text.trim().is_empty() {
                    out.push_str(&format!("ASİSTAN: {}\n", crate::util::truncate_middle(&text, 2000)));
                }
                for c in m["tool_calls"].as_array().cloned().unwrap_or_default() {
                    out.push_str(&format!(
                        "ARAÇ ÇAĞRISI: {} {}\n",
                        c["function"]["name"].as_str().unwrap_or(""),
                        crate::util::truncate_end(c["function"]["arguments"].as_str().unwrap_or(""), 300)
                    ));
                }
            }
            "tool" => out.push_str(&format!("ARAÇ SONUCU: {}\n", crate::util::truncate_middle(&text, 500))),
            _ => {}
        }
    }
    crate::util::truncate_middle(&out, max_chars.max(4000))
}

/// Modelle özet yazdırır; ilerleme durum satırında gösterilir.
async fn generate(
    llm: &LlmClient,
    req: &[Value],
    opts: &CompleteOptions<'_>,
    cancel: &CancellationToken,
    on_status: &(dyn Fn(String) + Send + Sync),
) -> Result<Option<String>, LlmError> {
    let started = Instant::now();
    let mut last = Instant::now();
    let mut chars = 0usize;
    let mut thinking = false;
    let mut sink = |d: Delta| {
        match d {
            Delta::Content(c) => {
                chars += c.len();
                thinking = false;
            }
            Delta::Reasoning(r) => {
                chars += r.len();
                thinking = true;
            }
            Delta::Status(s) => {
                on_status(s);
                return;
            }
        }
        if last.elapsed() >= Duration::from_secs(3) {
            last = Instant::now();
            on_status(format!(
                "Bağlam özetleniyor… {} (~{} token, {} sn)",
                if thinking { "model düşünüyor" } else { "özet yazılıyor" },
                chars / 3,
                started.elapsed().as_secs()
            ));
        }
    };
    let t = llm.complete(req, opts, cancel, &mut sink).await?;
    let content = t.content.trim().to_string();
    if !content.is_empty() {
        let cut = t.finish_reason.as_deref() == Some("length");
        return Ok(Some(if cut { format!("{content}\n(Özet uzunluk sınırında kesildi.)") } else { content }));
    }
    // Yanıt yalnızca düşünceden ibaretse ve yarıda kesilmediyse özeti düşünceye yazmış olabilir.
    if t.tool_calls.is_empty() && t.finish_reason.as_deref() != Some("length") && t.reasoning.trim().len() > 200 {
        return Ok(Some(t.reasoning.trim().to_string()));
    }
    Ok(None)
}

/// Bağlamı sıkıştırır. `messages[0]` sistem mesajıdır. Dönüş: bir şey değiştiyse sonucu.
pub async fn compact(
    messages: &mut Vec<Value>,
    inp: &CompactInput<'_>,
    meter: &Meter,
    llm: &LlmClient,
    cancel: &CancellationToken,
    on_status: &(dyn Fn(String) + Send + Sync),
) -> Result<Option<Compaction>, LlmError> {
    let n_ctx = inp.n_ctx;
    let tools_est = tools_tokens(inp.tools);
    let before = meter.tokens(messages, tools_est);
    let limit = n_ctx - out_reserve(n_ctx);
    // Sıkıştırmadan sonra korunacak son kısım (birebir) ve yalnızca kısaltmanın yeterli sayıldığı doluluk.
    let keep_budget = (n_ctx / 4).max(1024);
    let trim_target = n_ctx * 55 / 100;

    // Korunan son kısım: bütçeye sığan en uzun birim dizisi (en az bir şey özetlenebilsin diye 2. mesajdan sonra).
    let starts = unit_starts(messages);
    let mut tail_start = None;
    for &s in starts.iter().rev() {
        if s < 2 {
            break;
        }
        if meter.scale(estimate_tokens(&messages[s..])) <= keep_budget {
            tail_start = Some(s);
        } else {
            break;
        }
    }
    let tail_start = tail_start.or_else(|| starts.iter().rev().copied().find(|&s| s >= 2));
    let Some(tail_start) = tail_start else {
        // Yalnızca sistem + tek kullanıcı mesajı: dev bir yapıştırma. Ortasından kısaltılır.
        let mut work = messages.clone();
        let mut scale = 1.0;
        while meter.tokens(&work, tools_est) > limit && scale > 0.05 {
            work = messages.clone();
            trim_bulk(&mut work[1..], scale);
            scale /= 2.0;
        }
        let after = meter.tokens(&work, tools_est);
        if after >= before {
            return Ok(None);
        }
        *messages = work;
        return Ok(Some(Compaction { kind: "trim", summary: None, before, after }));
    };

    // 1) Ucuz yol: eski kısımdaki büyük içerikleri kısalt. Yeterince yer açılıyorsa özet yazdırmaya gerek yok.
    let mut work = messages.clone();
    trim_bulk(&mut work[1..tail_start], 1.0);
    let after_trim = meter.tokens(&work, tools_est);
    if after_trim <= trim_target {
        *messages = work;
        return Ok(Some(Compaction { kind: "trim", summary: None, before, after: after_trim }));
    }

    // 2) Eski kısmı özetlet.
    on_status(format!(
        "Bağlam doldu (~{}K / {}K token). Eski kısım özetleniyor; görev kaldığı yerden devam edecek…",
        before / 1024,
        n_ctx / 1024
    ));
    let room = n_ctx - before - 512;
    let mut summary = None;
    if !inp.overflow && room >= 3072 {
        // Önbellek dostu yol: aynı istem + sonuna özet talimatı. Sunucu önceki işlemeyi (KV) kullanır, yalnızca
        // talimat işlenir. Araçlar ve düşünme ayarı ana döngüyle aynı olmalı ki istem öneki değişmesin.
        let mut req = messages.clone();
        req.push(json!({"role": "user", "content": SUMMARY_INSTRUCTION}));
        let opts = CompleteOptions { tools: inp.tools, temperature: 0.3, max_tokens: room.min(8192) as u32, thinking: inp.thinking };
        match generate(llm, &req, &opts, cancel, on_status).await {
            Ok(s) => summary = s,
            Err(LlmError::Cancelled) => return Err(LlmError::Cancelled),
            Err(e) => tracing::warn!("özet (önbellekli) yazılamadı: {e}"),
        }
    }
    if summary.is_none() {
        // Yedek yol: eski kısmın kısaltılmış dökümünü ayrı bir istekle özetlet.
        let budget_tokens = (n_ctx - 6144).max(2048);
        let max_chars = (budget_tokens as f64 * 3.0 / meter.ratio().max(0.5) * 0.8) as usize;
        let req = vec![
            json!({"role": "system", "content": SUMMARIZER_SYSTEM}),
            json!({"role": "user", "content": format!("{}\n\nÖzetlenecek oturum:\n\n{}", SUMMARY_INSTRUCTION, transcript(&messages[1..tail_start], max_chars.min(400_000)))}),
        ];
        let opts = CompleteOptions { tools: &[], temperature: 0.3, max_tokens: 4096, thinking: false };
        match generate(llm, &req, &opts, cancel, on_status).await {
            Ok(s) => summary = s,
            Err(LlmError::Cancelled) => return Err(LlmError::Cancelled),
            Err(e) => tracing::warn!("özet yazılamadı: {e}"),
        }
    }
    let summary = summary.unwrap_or_else(|| fallback_summary(&messages[1..tail_start]));

    // Yeni bağlam: sistem + özet (+ kullanıcının son isteği) + korunan son kısım.
    let mut tail: Vec<Value> = messages[tail_start..].to_vec();
    let task = last_user_request(messages).filter(|(i, _)| *i < tail_start).map(|(_, t)| t);
    let mut new = vec![messages[0].clone()];
    match tail.first_mut() {
        Some(first) if first["role"] == "user" => {
            // Art arda iki kullanıcı mesajı olmasın: özet ilk kalan kullanıcı mesajının başına eklenir.
            let prefix = format!("{}\n\n[Güncel mesaj]\n", summary_block(&summary, &inp.todos, None));
            first["content"] = match first["content"].take() {
                Value::String(s) => json!(format!("{prefix}{s}")),
                Value::Array(mut parts) => {
                    parts.insert(0, json!({"type": "text", "text": prefix}));
                    Value::Array(parts)
                }
                other => other,
            };
        }
        _ => new.push(json!({"role": "user", "content": summary_block(&summary, &inp.todos, task.as_deref())})),
    }
    new.append(&mut tail);
    // Korunan kısım tek başına çok büyükse (ör. dev bir araç çıktısı) onu da kısalt.
    let mut scale = 1.0;
    while meter.tokens(&new, tools_est) > n_ctx * 60 / 100 && scale > 0.05 {
        let from = 2.min(new.len());
        if !trim_bulk(&mut new[from..], scale) && scale < 1.0 {
            break;
        }
        scale /= 2.0;
    }
    let after = meter.tokens(&new, tools_est);
    *messages = new;
    Ok(Some(Compaction { kind: "summary", summary: Some(summary), before, after }))
}

/// Model özet yazamadıysa: araç çağrılarından çıkarılan bilgilerle kısa bir döküm.
fn fallback_summary(old: &[Value]) -> String {
    let mut files: Vec<String> = vec![];
    let mut cmds: Vec<String> = vec![];
    for m in old {
        for c in m["tool_calls"].as_array().cloned().unwrap_or_default() {
            let name = c["function"]["name"].as_str().unwrap_or("");
            let args: Value = serde_json::from_str(c["function"]["arguments"].as_str().unwrap_or("{}")).unwrap_or(json!({}));
            match name {
                "write_file" | "edit_file" | "edit_document" => {
                    let p = args["path"].as_str().or(args["output_path"].as_str()).unwrap_or("").to_string();
                    if !p.is_empty() && !files.contains(&p) {
                        files.push(p);
                    }
                }
                "run_command" => cmds.push(crate::util::truncate_end(args["command"].as_str().unwrap_or(""), 160)),
                _ => {}
            }
        }
    }
    let mut s = "(Model özet yazamadı; FerIDE eski kısımdan şunları çıkardı.)".to_string();
    if !files.is_empty() {
        s.push_str(&format!("\nDeğiştirilen dosyalar: {}", files.join(", ")));
    }
    if !cmds.is_empty() {
        let last: Vec<String> = cmds.iter().rev().take(15).rev().cloned().collect();
        s.push_str(&format!("\nSon komutlar:\n- {}", last.join("\n- ")));
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn old_browser_outputs_are_elided() {
        let page = |n: usize| {
            json!({"role": "tool", "name": "browser", "content": format!(
                "<untrusted_content source=\"browser\">\nSayfa: Sayfa {n} — https://ornek.com/{n}\n{}\n</untrusted_content>", "x".repeat(2000))})
        };
        let mut m = vec![json!({"role": "system", "content": "s"}), page(1), page(2), page(3)];
        elide_browser(&mut m);
        assert!(m[1..].iter().all(|x| content_text(&x["content"]).len() > 1000), "sınır aşılmadan kısaltılmamalı");
        m.push(json!({"role": "tool", "name": "browser", "content": "HATA: kısa"}));
        m.push(json!({"role": "tool", "name": "browser", "content": [
            {"type": "text", "text": "Tarayıcının ekran görüntüsü ektedir."}, {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,AAAA"}}]}));
        m.push(page(4));
        elide_browser(&mut m);
        assert!(content_text(&m[1]["content"]).contains("[Eski tarayıcı çıktısı kaldırıldı] Sayfa: Sayfa 1 — https://ornek.com/1"));
        assert!(content_text(&m[3]["content"]).contains("Eski tarayıcı"));
        assert_eq!(m[4]["content"], "HATA: kısa");
        assert!(m[5]["content"].is_string(), "eski ekran görüntüsü atılmalı");
        assert!(content_text(&m[6]["content"]).len() > 1000, "son çıktı olduğu gibi kalmalı");
    }

    #[test]
    fn estimate() {
        let m = vec![json!({"role": "user", "content": "a".repeat(3000)})];
        let t = estimate_tokens(&m);
        assert!((1000..1100).contains(&t));
    }

    #[test]
    fn meter_calibrates_to_server_counts() {
        let m = vec![json!({"role": "user", "content": "a".repeat(30000)})];
        let mut meter = Meter::default();
        let est = estimate_tokens(&m);
        meter.observe(est * 13 / 10, &m, 0);
        assert!((meter.ratio() - 1.3).abs() < 0.01);
        assert_eq!(meter.tokens(&m, 0), (est as f64 * meter.ratio()).ceil() as i64);
        // Bağlam aşıldı ama sunucu uzunluğu bildirmedi: oran en az %25 artar.
        meter.observe_overflow(None, &m, 0);
        assert!(meter.ratio() > 1.6);
    }

    #[test]
    fn step_tokens_use_remaining_context_locally() {
        assert_eq!(step_max_tokens(false, 131072, 1000), 8192);
        assert_eq!(step_max_tokens(true, 131072, 10_000), 32768);
        assert_eq!(step_max_tokens(true, 131072, 120_000), 131072 - 120_000 - 256);
        assert_eq!(step_max_tokens(true, 8192, 8000), 1024);
        assert_eq!(out_reserve(131072), 16384);
        assert_eq!(out_reserve(8192), 1024);
    }

    /// Uzun tek bir görev: kullanıcı mesajı + çok sayıda araç adımı.
    fn long_task(steps: usize, out_len: usize) -> Vec<Value> {
        let mut m = vec![json!({"role": "system", "content": "sistem"}), json!({"role": "user", "content": "ESO eklentisini yaz"})];
        for i in 0..steps {
            m.push(json!({"role": "assistant", "content": format!("Adım {i}"), "tool_calls": [{"id": format!("c{i}"), "type": "function",
                "function": {"name": "write_file", "arguments": json!({"path": format!("dosya{i}.lua"), "content": "x".repeat(out_len)}).to_string()}}]}));
            m.push(json!({"role": "tool", "tool_call_id": format!("c{i}"), "name": "write_file", "content": format!("Yazıldı {i} {}", "y".repeat(out_len))}));
        }
        m
    }

    #[test]
    fn trim_shortens_bulky_old_content_inside_one_turn() {
        let mut m = long_task(40, 6000);
        let n_ctx = 131072;
        let meter = Meter::default();
        let before = meter.tokens(&m, 0);
        assert!(before > n_ctx - out_reserve(n_ctx), "test sohbeti bağlamı aşmalı: {before}");
        let llm = LlmClient::new("http://127.0.0.1:9/v1", "yok", None);
        let inp = CompactInput { n_ctx, tools: &[], thinking: false, todos: String::new(), overflow: false };
        let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        let r = rt.block_on(compact(&mut m, &inp, &meter, &llm, &CancellationToken::new(), &|_| {})).unwrap().unwrap();
        assert_eq!(r.kind, "trim", "{r:?}");
        assert!(r.after <= n_ctx * 55 / 100, "{r:?}");
        // Görevin başı ve son adımlar birebir duruyor; eski dosya içerikleri kısaldı ama JSON geçerli.
        assert_eq!(m[1]["content"], "ESO eklentisini yaz");
        let last = &m[m.len() - 1];
        assert!(content_text(&last["content"]).len() > 6000, "son adım korunmalı");
        let old_args: Value = serde_json::from_str(m[2]["tool_calls"][0]["function"]["arguments"].as_str().unwrap()).unwrap();
        assert!(old_args["content"].as_str().unwrap().contains("kısaltıldı"));
        assert_eq!(old_args["path"], "dosya0.lua");
        // Araç çağrısı/yanıt çiftleri bozulmadı.
        for (i, x) in m.iter().enumerate() {
            if x["role"] == "tool" {
                assert!(m[i - 1]["tool_calls"].is_array() || m[i - 1]["role"] == "tool");
            }
        }
    }

    #[test]
    fn summary_cuts_inside_a_single_long_turn() {
        // Kısaltma yetmeyecek kadar çok adım: model özet yazamıyor (sunucu yok) → yedek özet; görev isteği korunur.
        let mut m = long_task(400, 1200);
        let n_ctx = 131072;
        let meter = Meter::default();
        let llm = LlmClient::new("http://127.0.0.1:9/v1", "yok", None);
        let inp = CompactInput { n_ctx, tools: &[], thinking: false, todos: "- [ ] Aşama 3".into(), overflow: false };
        let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        let r = rt.block_on(compact(&mut m, &inp, &meter, &llm, &CancellationToken::new(), &|_| {})).unwrap().unwrap();
        assert_eq!(r.kind, "summary");
        assert!(r.after < n_ctx / 2, "{r:?}");
        let first = content_text(&m[1]["content"]);
        assert_eq!(m[1]["role"], "user");
        assert!(first.starts_with(SUMMARY_HEAD), "{first}");
        assert!(first.contains("ESO eklentisini yaz"), "kullanıcının isteği özette olmalı");
        assert!(first.contains("Aşama 3"), "yapılacaklar özette olmalı");
        assert!(first.contains("dosya0.lua"), "yedek özet dosyaları saymalı");
        assert_eq!(m[2]["role"], "assistant", "özetten sonra bir birim başı gelmeli");
        // Yeniden özetlemede kullanıcının isteği özetin içinden bulunur.
        assert_eq!(last_user_request(&m).unwrap().1.trim(), "ESO eklentisini yaz");
    }

    #[test]
    fn consecutive_user_messages_are_merged() {
        let mut m = vec![json!({"role": "system", "content": "s"}), json!({"role": "user", "content": "ilk"})];
        push_user(&mut m, json!({"role": "user", "content": "ikinci"}));
        assert_eq!(m.len(), 2);
        assert_eq!(m[1]["content"], "ilk\n\nikinci");
        // Görsel içeren mesaj: parçalar korunur.
        push_user(&mut m, json!({"role": "user", "content": [{"type": "text", "text": "bak"}, {"type": "image_url", "image_url": {"url": "data:,"}}]}));
        let parts = m[1]["content"].as_array().unwrap();
        assert_eq!(parts.len(), 3);
        assert_eq!(parts[2]["type"], "image_url");
        // Önceki mesaj asistandan ise yeni mesaj eklenir.
        m.push(json!({"role": "assistant", "content": "yanıt"}));
        push_user(&mut m, json!({"role": "user", "content": "sonraki"}));
        assert_eq!(m.len(), 4);
    }

    #[test]
    fn model_view_starts_at_last_compaction_and_keeps_history() {
        let c = Compaction { kind: "summary", summary: Some("özet".into()), before: 100, after: 10 };
        let view = vec![
            json!({"role": "system", "content": "s"}),
            json!({"role": "user", "content": "[Bağlam özeti] özet"}),
            json!({"role": "assistant", "content": "", "tool_calls": [{"id": "1", "type": "function", "function": {"name": "x", "arguments": "{}"}}]}),
            json!({"role": "tool", "tool_call_id": "1", "content": [{"type": "text", "text": "ekran"}, {"type": "image_url", "image_url": {"url": "data:,"}}]}),
        ];
        let rec = c.record(&view);
        assert_eq!(rec["messages"].as_array().unwrap().len(), 3);
        assert!(rec["messages"][2]["content"].is_string(), "görsel dosyaya yazılmaz");
        let history = vec![
            json!({"role": "user", "content": "eski istek"}),
            json!({"role": "assistant", "content": "eski yanıt", "reasoning": "düşünce"}),
            rec,
            json!({"role": "note", "text": "Bağlam büyütüldü"}),
            json!({"role": "user", "content": "devam et", "auto": true}),
        ];
        let v = model_view(history);
        assert_eq!(v.len(), 4);
        assert_eq!(v[0]["content"], "[Bağlam özeti] özet");
        assert_eq!(v[3]["content"], "devam et");
        assert!(v[3].get("auto").is_none());
        // Kayıt yoksa geçmişin tamamı (notlar ve arayüz alanları hariç).
        let v = model_view(vec![json!({"role": "user", "content": "a"}), json!({"role": "assistant", "content": "b", "usage": {}})]);
        assert_eq!(v.len(), 2);
        assert!(v[1].get("usage").is_none());
    }
}
