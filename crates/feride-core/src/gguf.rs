//! GGUF başlık okuyucu.
//!
//! Model dosyasının yalnızca başlığını okuyarak (birkaç MB) bellek ihtiyacını
//! hesaplamaya yetecek bilgileri çıkarır: mimari, katman sayısı, KV başlıkları,
//! eğitim bağlamı, MoE uzman sayısı ve tensör boyutları. Kayan pencereli (SWA),
//! karma/recurrent ve MTP katmanlı modeller doğru hesaplanır. Bölünmüş modellerde
//! (…-00001-of-00003.gguf) bütün parçalar okunur.

use regex::Regex;
use serde::Serialize;
use std::collections::HashMap;
use std::fs::File;
use std::io::{BufReader, Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::LazyLock;

#[derive(Clone, Debug, Serialize, Default)]
pub struct GgufInfo {
    pub architecture: String,
    pub name: String,
    pub block_count: u64,
    pub context_length: u64,
    pub head_count: u64,
    pub head_count_kv: u64,
    pub embedding_length: u64,
    pub key_length: u64,
    pub value_length: u64,
    pub expert_count: u64,
    /// Tam dikkat katmanlarının token başına KV boyutu (q8_0, bayt).
    pub full_kv_per_token: u64,
    /// Kayan pencereli katmanların token başına KV boyutu.
    pub swa_kv_per_token: u64,
    pub sliding_window: u64,
    /// Bütün parçaların tensör verisi toplamı (bayt).
    pub weight_bytes: u64,
    /// MoE uzman tensörlerinin toplamı (bayt).
    pub expert_bytes: u64,
    pub parts: Vec<PathBuf>,
    pub has_chat_template: bool,
    pub nextn_layers: u64,
}

impl GgufInfo {
    pub fn is_moe(&self) -> bool {
        self.expert_count > 1 && self.expert_bytes > 0
    }
    /// GPU'da kalacak (uzman dışı) ağırlıklar.
    pub fn dense_bytes(&self) -> u64 {
        self.weight_bytes.saturating_sub(self.expert_bytes)
    }
    /// `ctx` token bağlam için q8_0 KV önbelleğinin toplam boyutu.
    pub fn kv_bytes(&self, ctx: u64) -> u64 {
        let ubatch = 2048;
        self.full_kv_per_token * ctx + self.swa_kv_per_token * ctx.min(self.sliding_window + ubatch)
    }
}

static SPLIT_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)-(\d{5})-of-(\d{5})\.gguf$").unwrap());

/// Bölünmüş modelin bütün parça yolları (tek parçalıysa kendisi).
pub fn split_parts(path: &Path) -> Vec<PathBuf> {
    let s = path.to_string_lossy();
    let Some(m) = SPLIT_RE.captures(&s) else { return vec![path.to_path_buf()] };
    let total: usize = m[2].parse().unwrap_or(1);
    let prefix = &s[..s.len() - m[0].len()];
    (1..=total).map(|i| PathBuf::from(format!("{prefix}-{i:05}-of-{}.gguf", &m[2]))).collect()
}

/// Parça ekini atar: `model-00001-of-00002.gguf` → `model`.
pub fn base_name(path: &Path) -> String {
    let name = path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
    let n = SPLIT_RE.replace(&name, "").to_string();
    n.strip_suffix(".gguf").or_else(|| n.strip_suffix(".GGUF")).unwrap_or(&n).to_string()
}

pub fn is_split_secondary(path: &Path) -> bool {
    SPLIT_RE
        .captures(&path.to_string_lossy())
        .map(|m| &m[1] != "00001")
        .unwrap_or(false)
}

#[derive(Debug, Clone)]
enum Val {
    U(u64),
    I(i64),
    #[allow(dead_code)]
    F(f64),
    B(bool),
    S(String),
    Arr(Vec<Val>),
}

impl Val {
    fn as_u64(&self) -> Option<u64> {
        match self {
            Val::U(v) => Some(*v),
            Val::I(v) if *v >= 0 => Some(*v as u64),
            Val::Arr(a) => a.iter().filter_map(|x| x.as_u64()).max(),
            _ => None,
        }
    }
}

struct Reader<R: Read + Seek> {
    r: R,
}

impl<R: Read + Seek> Reader<R> {
    fn bytes(&mut self, n: usize) -> std::io::Result<Vec<u8>> {
        let mut b = vec![0u8; n];
        self.r.read_exact(&mut b)?;
        Ok(b)
    }
    fn u32(&mut self) -> std::io::Result<u32> {
        let mut b = [0u8; 4];
        self.r.read_exact(&mut b)?;
        Ok(u32::from_le_bytes(b))
    }
    fn u64(&mut self) -> std::io::Result<u64> {
        let mut b = [0u8; 8];
        self.r.read_exact(&mut b)?;
        Ok(u64::from_le_bytes(b))
    }
    fn skip(&mut self, n: u64) -> std::io::Result<()> {
        self.r.seek(SeekFrom::Current(n as i64))?;
        Ok(())
    }
    fn pos(&mut self) -> std::io::Result<u64> {
        self.r.stream_position()
    }
    fn string(&mut self) -> std::io::Result<String> {
        let len = self.u64()?;
        if len > (64 << 20) {
            return Err(bad("geçersiz metin uzunluğu"));
        }
        Ok(String::from_utf8_lossy(&self.bytes(len as usize)?).into_owned())
    }

    fn fixed_size(t: u32) -> Option<u64> {
        Some(match t {
            0 | 1 | 7 => 1,
            2 | 3 => 2,
            4..=6 => 4,
            10..=12 => 8,
            _ => return None,
        })
    }

    /// Değeri okur; `keep` false ise atlar (büyük tokenizer dizileri gibi).
    fn value(&mut self, t: u32, keep: bool) -> std::io::Result<Option<Val>> {
        match t {
            8 => {
                if !keep {
                    let n = self.u64()?;
                    self.skip(n)?;
                    return Ok(None);
                }
                Ok(Some(Val::S(self.string()?)))
            }
            9 => {
                let et = self.u32()?;
                let count = self.u64()?;
                if !keep || count > 4096 {
                    if let Some(sz) = Self::fixed_size(et) {
                        self.skip(sz * count)?;
                    } else {
                        for _ in 0..count {
                            self.value(et, false)?;
                        }
                    }
                    return Ok(None);
                }
                let mut v = Vec::with_capacity(count as usize);
                for _ in 0..count {
                    if let Some(x) = self.value(et, true)? {
                        v.push(x);
                    }
                }
                Ok(Some(Val::Arr(v)))
            }
            _ => {
                let sz = Self::fixed_size(t).ok_or_else(|| bad("bilinmeyen GGUF tipi"))?;
                let b = self.bytes(sz as usize)?;
                if !keep {
                    return Ok(None);
                }
                Ok(Some(match t {
                    0 => Val::U(b[0] as u64),
                    1 => Val::I(b[0] as i8 as i64),
                    2 => Val::U(u16::from_le_bytes([b[0], b[1]]) as u64),
                    3 => Val::I(i16::from_le_bytes([b[0], b[1]]) as i64),
                    4 => Val::U(u32::from_le_bytes(b[..4].try_into().unwrap()) as u64),
                    5 => Val::I(i32::from_le_bytes(b[..4].try_into().unwrap()) as i64),
                    6 => Val::F(f32::from_le_bytes(b[..4].try_into().unwrap()) as f64),
                    7 => Val::B(b[0] != 0),
                    10 => Val::U(u64::from_le_bytes(b[..8].try_into().unwrap())),
                    11 => Val::I(i64::from_le_bytes(b[..8].try_into().unwrap())),
                    _ => Val::F(f64::from_le_bytes(b[..8].try_into().unwrap())),
                }))
            }
        }
    }
}

fn bad(msg: &str) -> std::io::Error {
    std::io::Error::new(std::io::ErrorKind::InvalidData, msg.to_string())
}

struct Parsed {
    meta: HashMap<String, Val>,
    data_bytes: u64,
    expert_bytes: u64,
}

fn parse_file(path: &Path, want_meta: bool) -> std::io::Result<Parsed> {
    let f = File::open(path)?;
    let len = f.metadata()?.len();
    let mut r = Reader { r: BufReader::with_capacity(1 << 20, f) };
    if r.bytes(4)? != b"GGUF" {
        return Err(bad("GGUF değil"));
    }
    let version = r.u32()?;
    if version < 2 {
        return Err(bad("eski GGUF sürümü"));
    }
    let tensor_count = r.u64()?;
    let kv_count = r.u64()?;
    let mut meta = HashMap::new();
    let mut alignment = 32u64;
    for _ in 0..kv_count {
        let key = r.string()?;
        let t = r.u32()?;
        let interesting = key == "general.alignment"
            || key == "tokenizer.chat_template"
            || (want_meta && (key == "general.architecture" || !key.starts_with("tokenizer.")));
        // Sohbet şablonu çok uzun olabilir; yalnızca varlığını kaydet.
        if key == "tokenizer.chat_template" {
            r.value(t, false)?;
            meta.insert(key, Val::B(true));
            continue;
        }
        let v = r.value(t, interesting)?;
        if let Some(v) = v {
            if key == "general.alignment" {
                if let Some(a) = v.as_u64().filter(|a| *a > 0) {
                    alignment = a;
                }
            }
            if interesting {
                meta.insert(key, v);
            }
        }
    }
    let mut names = Vec::with_capacity(tensor_count as usize);
    let mut offsets = Vec::with_capacity(tensor_count as usize);
    for _ in 0..tensor_count {
        names.push(r.string()?);
        let n_dims = r.u32()?;
        r.skip(8 * n_dims as u64)?;
        r.u32()?; // ggml tipi
        offsets.push(r.u64()?);
    }
    let pos = r.pos()?;
    let data_start = pos.div_ceil(alignment) * alignment;
    let data_bytes = len.saturating_sub(data_start);
    let mut order: Vec<usize> = (0..offsets.len()).collect();
    order.sort_by_key(|&i| offsets[i]);
    let mut expert = 0u64;
    for (j, &i) in order.iter().enumerate() {
        let end = if j + 1 < order.len() { offsets[order[j + 1]] } else { data_bytes };
        if names[i].contains("_exps") {
            expert += end.saturating_sub(offsets[i]);
        }
    }
    Ok(Parsed { meta, data_bytes, expert_bytes: expert })
}

pub fn read(path: &Path) -> Option<GgufInfo> {
    match read_inner(path) {
        Ok(i) => Some(i),
        Err(e) => {
            tracing::debug!("GGUF okunamadı {}: {e}", path.display());
            None
        }
    }
}

fn read_inner(path: &Path) -> std::io::Result<GgufInfo> {
    let parts = split_parts(path);
    let mut meta = HashMap::new();
    let mut weight = 0u64;
    let mut expert = 0u64;
    for (i, p) in parts.iter().enumerate() {
        let r = parse_file(p, i == 0)?;
        if i == 0 {
            meta = r.meta;
        }
        weight += r.data_bytes;
        expert += r.expert_bytes;
    }
    let arch = match meta.get("general.architecture") {
        Some(Val::S(s)) => s.clone(),
        _ => String::new(),
    };
    let name = match meta.get("general.name") {
        Some(Val::S(s)) => s.clone(),
        _ => String::new(),
    };
    let m = |k: &str| meta.get(&format!("{arch}.{k}"));
    let num = |k: &str| m(k).and_then(|v| v.as_u64()).unwrap_or(0);

    let layers = num("block_count");
    let head_count = num("attention.head_count");
    let embd = num("embedding_length");
    let head_dim = if embd > 0 && head_count > 0 { embd / head_count } else { 128 };
    let k_len = if num("attention.key_length") > 0 { num("attention.key_length") } else { head_dim };
    let v_len = if num("attention.value_length") > 0 { num("attention.value_length") } else { head_dim };
    let k_swa = if num("attention.key_length_swa") > 0 { num("attention.key_length_swa") } else { k_len };
    let v_swa = if num("attention.value_length_swa") > 0 { num("attention.value_length_swa") } else { v_len };
    let kv_heads_raw = m("attention.head_count_kv").cloned();
    let window = num("attention.sliding_window");
    let swa_pattern = m("attention.sliding_window_pattern").cloned();
    let recurrent = m("attention.recurrent_layers").cloned();
    let full_interval = num("full_attention_interval");
    let kv_lora = num("attention.kv_lora_rank");
    let rope_dim = num("rope.dimension_count");
    let nextn = num("nextn_predict_layers");
    let kv_layers = layers.saturating_sub(nextn);
    let bpe = 34.0 / 32.0; // q8_0: 32 eleman 34 bayt

    let idx_bool = |v: &Option<Val>, i: usize| -> Option<bool> {
        match v {
            Some(Val::Arr(a)) if i < a.len() => Some(matches!(a[i], Val::B(true))),
            _ => None,
        }
    };

    let mut full = 0.0f64;
    let mut swa = 0.0f64;
    for i in 0..kv_layers as usize {
        let is_recurrent = idx_bool(&recurrent, i)
            .unwrap_or(full_interval > 1 && !(i as u64 + 1).is_multiple_of(full_interval));
        if is_recurrent {
            continue;
        }
        let kv_heads = match &kv_heads_raw {
            Some(Val::Arr(a)) if i < a.len() => a[i].as_u64().unwrap_or(head_count),
            Some(v) => v.as_u64().filter(|x| *x > 0).unwrap_or(head_count),
            None => head_count,
        } as f64;
        if kv_lora > 0 {
            full += (kv_lora + rope_dim) as f64 * bpe;
            continue;
        }
        let is_swa = window > 0 && idx_bool(&swa_pattern, i) == Some(true);
        if is_swa {
            swa += kv_heads * (k_swa + v_swa) as f64 * bpe;
        } else {
            full += kv_heads * (k_len + v_len) as f64 * bpe;
        }
    }
    if layers == 0 {
        full = 128.0 * 1024.0; // bilinmeyen model: kötümser tahmin
    }

    Ok(GgufInfo {
        architecture: arch.clone(),
        name,
        block_count: layers,
        context_length: num("context_length"),
        head_count,
        head_count_kv: num("attention.head_count_kv"),
        embedding_length: embd,
        key_length: k_len,
        value_length: v_len,
        expert_count: num("expert_count"),
        full_kv_per_token: full.ceil() as u64,
        swa_kv_per_token: swa.ceil() as u64,
        sliding_window: window,
        weight_bytes: weight,
        expert_bytes: expert,
        parts,
        has_chat_template: meta.contains_key("tokenizer.chat_template"),
        nextn_layers: nextn,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn split() {
        let p = Path::new("/m/GLM-4.5-Air-Q4_K_S-00001-of-00002.gguf");
        let parts = split_parts(p);
        assert_eq!(parts.len(), 2);
        assert!(parts[1].to_string_lossy().ends_with("-00002-of-00002.gguf"));
        assert_eq!(base_name(p), "GLM-4.5-Air-Q4_K_S");
        assert!(!is_split_secondary(p));
        assert!(is_split_secondary(&parts[1]));
        assert_eq!(split_parts(Path::new("/m/x.gguf")).len(), 1);
    }

    fn put_str(b: &mut Vec<u8>, s: &str) {
        b.extend((s.len() as u64).to_le_bytes());
        b.extend(s.as_bytes());
    }

    #[test]
    fn parses_synthetic_file() {
        let mut b = b"GGUF".to_vec();
        b.extend(3u32.to_le_bytes());
        b.extend(2u64.to_le_bytes()); // tensörler
        b.extend(5u64.to_le_bytes()); // kv
        put_str(&mut b, "general.architecture");
        b.extend(8u32.to_le_bytes());
        put_str(&mut b, "llama");
        for (k, v) in [("llama.block_count", 4u32), ("llama.attention.head_count", 8), ("llama.attention.head_count_kv", 2), ("llama.embedding_length", 1024)] {
            put_str(&mut b, k);
            b.extend(4u32.to_le_bytes());
            b.extend(v.to_le_bytes());
        }
        for (name, off) in [("blk.0.attn_q.weight", 0u64), ("blk.0.ffn_up_exps.weight", 64)] {
            put_str(&mut b, name);
            b.extend(1u32.to_le_bytes());
            b.extend(16u64.to_le_bytes());
            b.extend(0u32.to_le_bytes());
            b.extend(off.to_le_bytes());
        }
        while !b.len().is_multiple_of(32) {
            b.push(0);
        }
        b.extend(vec![1u8; 128]);
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("t.gguf");
        std::fs::File::create(&p).unwrap().write_all(&b).unwrap();
        let info = read(&p).unwrap();
        assert_eq!(info.architecture, "llama");
        assert_eq!(info.block_count, 4);
        assert_eq!(info.weight_bytes, 128);
        assert_eq!(info.expert_bytes, 64);
        // 4 katman × 2 KV başı × (128+128) × 34/32
        assert_eq!(info.full_kv_per_token, (4.0 * 2.0 * 256.0 * 34.0 / 32.0) as u64);
    }
}
