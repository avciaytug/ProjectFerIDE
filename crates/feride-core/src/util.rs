//! Küçük yardımcılar.

use std::path::Path;

/// Dosyayı önce geçici dosyaya yazar, sonra yerine taşır (yarım yazılmış dosya kalmaz).
pub fn write_atomic(path: &Path, data: &[u8]) -> anyhow::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let tmp = path.with_extension(format!(
        "{}.tmp{}",
        path.extension().and_then(|e| e.to_str()).unwrap_or(""),
        std::process::id()
    ));
    std::fs::write(&tmp, data)?;
    // Windows'ta hedef açıksa rename başarısız olabilir; birkaç kez dene.
    let mut last = None;
    for _ in 0..5 {
        match std::fs::rename(&tmp, path) {
            Ok(()) => return Ok(()),
            Err(e) => {
                last = Some(e);
                std::thread::sleep(std::time::Duration::from_millis(40));
            }
        }
    }
    let _ = std::fs::remove_file(&tmp);
    Err(last.map(anyhow::Error::from).unwrap_or_else(|| anyhow::anyhow!("yazılamadı")))
}

/// JSON nesnelerini derinlemesine birleştirir (patch, base'in üzerine yazılır).
pub fn json_merge(base: &mut serde_json::Value, patch: &serde_json::Value) {
    match (base, patch) {
        (serde_json::Value::Object(b), serde_json::Value::Object(p)) => {
            for (k, v) in p {
                json_merge(b.entry(k.clone()).or_insert(serde_json::Value::Null), v);
            }
        }
        (b, p) => *b = p.clone(),
    }
}

/// Metni karakter sınırında keser; kesildiyse not ekler.
pub fn truncate_middle(s: &str, max_chars: usize) -> String {
    let count = s.chars().count();
    if count <= max_chars {
        return s.to_string();
    }
    let head = max_chars * 2 / 3;
    let tail = max_chars - head;
    let h: String = s.chars().take(head).collect();
    let t: String = s.chars().skip(count - tail).collect();
    format!("{h}\n\n… [{} karakter kısaltıldı] …\n\n{t}", count - max_chars)
}

pub fn truncate_end(s: &str, max_chars: usize) -> String {
    if s.chars().count() <= max_chars {
        return s.to_string();
    }
    let mut out: String = s.chars().take(max_chars).collect();
    out.push('…');
    out
}

pub fn gib(bytes: u64) -> String {
    format!("{:.1}", bytes as f64 / (1u64 << 30) as f64).replace('.', ",")
}

pub fn human_bytes(bytes: u64) -> String {
    const U: [&str; 5] = ["B", "KB", "MB", "GB", "TB"];
    let mut v = bytes as f64;
    let mut i = 0;
    while v >= 1024.0 && i < U.len() - 1 {
        v /= 1024.0;
        i += 1;
    }
    if i == 0 {
        format!("{bytes} B")
    } else {
        format!("{v:.1} {}", U[i])
    }
}

pub fn now_iso() -> String {
    chrono::Local::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
}

/// Dosyanın ikili (metin dışı) olup olmadığını ilk baytlarına bakarak tahmin eder.
pub fn looks_binary(bytes: &[u8]) -> bool {
    let n = bytes.len().min(8000);
    bytes[..n].contains(&0)
}

/// Rastgele, tahmin edilemez jeton (UUID v4 = işletim sisteminin CSPRNG'si).
pub fn random_token() -> String {
    format!("{}{}", uuid::Uuid::new_v4().simple(), uuid::Uuid::new_v4().simple())
}

/// Sabit zamanlı karşılaştırma (jeton denetimi için).
pub fn ct_eq(a: &str, b: &str) -> bool {
    let (a, b) = (a.as_bytes(), b.as_bytes());
    if a.len() != b.len() {
        return false;
    }
    a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn truncation() {
        let s = "a".repeat(100);
        let t = truncate_middle(&s, 30);
        assert!(t.contains("70 karakter"));
        assert_eq!(truncate_middle("kısa", 10), "kısa");
    }

    #[test]
    fn merge() {
        let mut a = serde_json::json!({"x": {"y": 1, "z": 2}});
        json_merge(&mut a, &serde_json::json!({"x": {"y": 5}}));
        assert_eq!(a, serde_json::json!({"x": {"y": 5, "z": 2}}));
    }

    #[test]
    fn ct() {
        assert!(ct_eq("abc", "abc"));
        assert!(!ct_eq("abc", "abd"));
        assert!(!ct_eq("abc", "ab"));
    }
}
