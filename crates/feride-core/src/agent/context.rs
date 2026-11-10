//! Bağlam yönetimi: sohbet modelin bağlamına sığmazsa önce eski araç çıktıları
//! kısaltılır, yetmezse eski konuşma modelin kendi yazdığı bir özetle değiştirilir.
//! Kesme noktası her zaman bir kullanıcı mesajıdır; araç çağrısı/yanıt çiftleri bölünmez.

use serde_json::{json, Value};
use tokio_util::sync::CancellationToken;

use crate::llm::LlmClient;
use crate::sessions::content_text;

/// Kaba token tahmini (Türkçe metinde ~3 karakter/token; görsel ~800 token).
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

/// Gerekirse mesajları sığdırır. `messages[0]` sistem mesajıdır.
/// Dönüş: sıkıştırma yapıldıysa yeni (sistem hariç) geçmiş.
pub async fn fit(
    messages: &mut Vec<Value>,
    n_ctx: i64,
    reserve: i64,
    llm: &LlmClient,
    cancel: &CancellationToken,
    on_status: &(dyn Fn(String) + Send + Sync),
) -> bool {
    let budget = n_ctx - reserve;
    if estimate_tokens(messages) <= budget * 85 / 100 {
        return false;
    }
    // 1) Son iki kullanıcı turundan önceki araç çıktılarını kısalt.
    let user_idx: Vec<usize> = messages.iter().enumerate().filter(|(_, m)| m["role"] == "user").map(|(i, _)| i).collect();
    let keep_from = if user_idx.len() >= 2 { user_idx[user_idx.len() - 2] } else { 1 };
    for m in messages.iter_mut().take(keep_from).skip(1) {
        if m["role"] == "tool" {
            if let Some(s) = m["content"].as_str() {
                if s.chars().count() > 600 {
                    m["content"] = json!(format!("{}… [eski araç çıktısı kısaltıldı]", s.chars().take(500).collect::<String>()));
                }
            }
        }
    }
    if estimate_tokens(messages) <= budget * 85 / 100 {
        return true;
    }
    // 2) Eski konuşmayı özetle. Son kısmı (bütçenin ~%40'ı) olduğu gibi tut.
    on_status("Bağlam doldu; eski konuşma özetleniyor…".into());
    let mut cut = None;
    for &i in user_idx.iter().rev() {
        if i <= 1 {
            continue;
        }
        if estimate_tokens(&messages[i..]) <= budget * 40 / 100 {
            cut = Some(i);
        } else {
            break;
        }
    }
    let cut = match cut.or_else(|| user_idx.last().copied().filter(|&i| i > 1)) {
        Some(c) => c,
        None => {
            // Tek dev tur: en eski araç çıktılarını sert kısalt.
            for m in messages.iter_mut().skip(1) {
                if m["role"] == "tool" {
                    if let Some(s) = m["content"].as_str() {
                        m["content"] = json!(crate::util::truncate_middle(s, 1500));
                    }
                }
            }
            return true;
        }
    };
    let old: Vec<Value> = messages[1..cut].to_vec();
    let mut transcript = String::new();
    for m in &old {
        let role = m["role"].as_str().unwrap_or("");
        let text = content_text(&m["content"]);
        match role {
            "user" => transcript.push_str(&format!("KULLANICI: {}\n", crate::util::truncate_middle(&text, 3000))),
            "assistant" => {
                if !text.trim().is_empty() {
                    transcript.push_str(&format!("ASİSTAN: {}\n", crate::util::truncate_middle(&text, 2000)));
                }
                for c in m["tool_calls"].as_array().cloned().unwrap_or_default() {
                    transcript.push_str(&format!(
                        "ARAÇ ÇAĞRISI: {} {}\n",
                        c["function"]["name"].as_str().unwrap_or(""),
                        crate::util::truncate_end(c["function"]["arguments"].as_str().unwrap_or(""), 300)
                    ));
                }
            }
            "tool" => transcript.push_str(&format!("ARAÇ SONUCU: {}\n", crate::util::truncate_middle(&text, 400))),
            _ => {}
        }
    }
    let transcript = crate::util::truncate_middle(&transcript, (budget as usize).saturating_mul(2).max(4000));
    let req = vec![
        json!({"role": "system", "content": "Bir yazılım asistanının önceki çalışma oturumunu özetliyorsun. Özet, işe kaldığı yerden devam edebilmek için gereken her şeyi içermeli: kullanıcının istekleri ve tercihleri, alınan kararlar, değiştirilen/oluşturulan dosyalar (yollarıyla), çalıştırılan önemli komutlar ve sonuçları, çözülmemiş hatalar, kalan işler. Madde madde, Türkçe yaz."}),
        json!({"role": "user", "content": format!("Özetlenecek oturum:\n\n{transcript}")}),
    ];
    let summary = match llm.simple(&req, 1500, cancel).await {
        Ok(s) if !s.trim().is_empty() => s,
        _ => format!("(Özet üretilemedi; eski {} mesaj bağlamdan çıkarıldı.)", old.len()),
    };
    let mut new = vec![messages[0].clone()];
    let mut tail: Vec<Value> = messages[cut..].to_vec();
    // Özeti ilk kalan kullanıcı mesajının başına ekle (art arda iki kullanıcı mesajı olmasın).
    if let Some(first) = tail.first_mut() {
        let orig = first["content"].clone();
        let prefix = format!("[Önceki konuşmanın özeti]\n{summary}\n\n[Güncel mesaj]\n");
        first["content"] = match orig {
            Value::String(s) => json!(format!("{prefix}{s}")),
            Value::Array(mut parts) => {
                parts.insert(0, json!({"type": "text", "text": prefix}));
                Value::Array(parts)
            }
            other => other,
        };
    }
    new.append(&mut tail);
    *messages = new;
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn estimate() {
        let m = vec![json!({"role": "user", "content": "a".repeat(3000)})];
        let t = estimate_tokens(&m);
        assert!((1000..1100).contains(&t));
    }
}
