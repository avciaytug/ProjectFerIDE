//! Hugging Face: GGUF model arama ve devam ettirilebilir indirme.
//!
//! * Yarım kalan indirme `.part` dosyasından devam eder (HTTP Range).
//! * LFS özeti (SHA-256) varsa indirme sırasında hesaplanır ve doğrulanır.
//! * Görsel adaptörü (mmproj) `models/mmproj/<model>__<dosya>` adıyla kaydedilir;
//!   böylece model başlatılırken otomatik eşleşir.

use futures::StreamExt;
use serde::Serialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::io::AsyncWriteExt;
use tokio_util::sync::CancellationToken;

use crate::events::EventBus;
use crate::paths::Paths;

#[derive(Clone, Debug, Serialize)]
pub struct HubModel {
    pub id: String,
    pub downloads: u64,
    pub likes: u64,
    pub updated: String,
    pub tags: Vec<String>,
    pub gated: bool,
}

#[derive(Clone, Debug, Serialize)]
pub struct HubFile {
    pub path: String,
    pub size: u64,
    pub sha256: Option<String>,
    pub is_mmproj: bool,
    pub quant: String,
    /// Bölünmüş modelin diğer parçaları (ilk parça için).
    pub parts: Vec<String>,
    pub total_size: u64,
}

#[derive(Clone, Debug, Serialize)]
pub struct DownloadInfo {
    pub id: String,
    pub repo: String,
    pub file: String,
    pub dest: PathBuf,
    pub done: u64,
    pub total: u64,
    pub speed: f64,
    /// running | done | failed | cancelled | verifying
    pub state: String,
    pub error: Option<String>,
}

static QUANT_RE: std::sync::LazyLock<regex::Regex> =
    std::sync::LazyLock::new(|| regex::Regex::new(r"(?i)((?:UD-)?I?Q\d(?:_[A-Z0-9]+)*|F16|BF16|F32|MXFP4)").unwrap());

pub struct Hub {
    paths: Paths,
    events: EventBus,
    http: reqwest::Client,
    downloads: Mutex<HashMap<String, (DownloadInfo, CancellationToken)>>,
}

impl Hub {
    pub fn new(paths: Paths, events: EventBus) -> Self {
        let http = reqwest::Client::builder()
            .user_agent(concat!("FerIDE/", env!("CARGO_PKG_VERSION")))
            .connect_timeout(Duration::from_secs(20))
            .build()
            .unwrap();
        Self { paths, events, http, downloads: Mutex::new(HashMap::new()) }
    }

    fn get(&self, url: &str, token: Option<&str>) -> reqwest::RequestBuilder {
        let mut r = self.http.get(url);
        if let Some(t) = token {
            r = r.bearer_auth(t);
        }
        r
    }

    pub async fn search(&self, query: &str, token: Option<&str>) -> anyhow::Result<Vec<HubModel>> {
        let mut url = url::Url::parse("https://huggingface.co/api/models")?;
        url.query_pairs_mut()
            .append_pair("search", query)
            .append_pair("filter", "gguf")
            .append_pair("sort", "downloads")
            .append_pair("direction", "-1")
            .append_pair("limit", "40")
            .append_pair("full", "false");
        let v: Vec<Value> = self.get(url.as_str(), token).send().await?.error_for_status()?.json().await?;
        Ok(v.into_iter()
            .map(|m| HubModel {
                id: m["id"].as_str().unwrap_or_default().to_string(),
                downloads: m["downloads"].as_u64().unwrap_or(0),
                likes: m["likes"].as_u64().unwrap_or(0),
                updated: m["lastModified"].as_str().unwrap_or_default().to_string(),
                tags: m["tags"]
                    .as_array()
                    .map(|a| a.iter().filter_map(|t| t.as_str().map(String::from)).take(12).collect())
                    .unwrap_or_default(),
                gated: m["gated"].as_bool().unwrap_or(false) || m["gated"].is_string(),
            })
            .collect())
    }

    /// Depodaki GGUF dosyaları (bölünmüş modeller tek satırda).
    pub async fn files(&self, repo: &str, token: Option<&str>) -> anyhow::Result<Vec<HubFile>> {
        validate_repo(repo)?;
        let url = format!("https://huggingface.co/api/models/{repo}/tree/main?recursive=true");
        let v: Vec<Value> = self.get(&url, token).send().await?.error_for_status()?.json().await?;
        let mut all: Vec<(String, u64, Option<String>)> = v
            .iter()
            .filter(|f| f["type"] == "file")
            .filter_map(|f| {
                let p = f["path"].as_str()?.to_string();
                if !p.to_lowercase().ends_with(".gguf") {
                    return None;
                }
                let size = f["lfs"]["size"].as_u64().or(f["size"].as_u64()).unwrap_or(0);
                let sha = f["lfs"]["oid"].as_str().map(String::from);
                Some((p, size, sha))
            })
            .collect();
        all.sort();
        let mut out = vec![];
        for (p, size, sha) in &all {
            let pb = Path::new(p);
            if crate::gguf::is_split_secondary(pb) {
                continue;
            }
            let parts: Vec<String> = crate::gguf::split_parts(pb)
                .iter()
                .map(|x| x.to_string_lossy().replace('\\', "/"))
                .collect();
            let total: u64 = all.iter().filter(|(q, _, _)| parts.contains(q)).map(|(_, s, _)| *s).sum();
            let base = crate::gguf::base_name(pb);
            let quant = QUANT_RE
                .captures(&base)
                .map(|c| c[1].to_uppercase())
                .unwrap_or_default();
            out.push(HubFile {
                path: p.clone(),
                size: *size,
                sha256: sha.clone(),
                is_mmproj: p.to_lowercase().contains("mmproj"),
                quant,
                parts: if parts.len() > 1 { parts } else { vec![] },
                total_size: if total > 0 { total } else { *size },
            });
        }
        Ok(out)
    }

    pub fn list_downloads(&self) -> Vec<DownloadInfo> {
        self.downloads.lock().unwrap().values().map(|(d, _)| d.clone()).collect()
    }

    pub fn cancel(&self, id: &str) -> bool {
        if let Some((_, t)) = self.downloads.lock().unwrap().get(id) {
            t.cancel();
            return true;
        }
        false
    }

    fn update(&self, info: &DownloadInfo) {
        if let Some(e) = self.downloads.lock().unwrap().get_mut(&info.id) {
            e.0 = info.clone();
        }
        self.events.emit_ser("download.progress", info);
    }

    /// İndirmeyi arka planda başlatır. `mmproj_for`: görsel adaptörü hangi modele ait; `expected_size`: dosyanın
    /// Hugging Face'teki boyutu (biliniyorsa). Görsel adaptörü bu bilgisayarda zaten varsa (aynı modelin başka bir
    /// sürümü için indirilmişse) yeniden indirilmez: indirme hemen "bitti" olur ve ikinci değer `true` döner.
    pub fn start_download(
        self: &Arc<Self>,
        repo: &str,
        file: &str,
        parts: Vec<String>,
        mmproj_for: Option<String>,
        expected_size: Option<u64>,
        token: Option<String>,
    ) -> anyhow::Result<(String, bool)> {
        validate_repo(repo)?;
        let files: Vec<String> = if parts.is_empty() { vec![file.to_string()] } else { parts };
        for f in &files {
            if f.contains("..") || f.starts_with('/') || f.contains('\\') {
                anyhow::bail!("geçersiz dosya adı");
            }
        }
        let id = uuid::Uuid::new_v4().simple().to_string()[..12].to_string();
        let first_name = Path::new(file).file_name().unwrap().to_string_lossy().to_string();
        let dest_dir = if mmproj_for.is_some() { self.paths.models().join("mmproj") } else { self.paths.models() };
        let family = mmproj_for.as_deref().map(|m| mmproj_family(repo, m));
        if let Some(fam) = &family {
            if let Some(existing) = existing_adapter(&dest_dir, fam, &first_name, expected_size) {
                let size = std::fs::metadata(&existing).map(|m| m.len()).unwrap_or(0);
                let info = DownloadInfo {
                    id: id.clone(),
                    repo: repo.to_string(),
                    file: file.to_string(),
                    dest: existing,
                    done: size,
                    total: size,
                    speed: 0.0,
                    state: "done".into(),
                    error: None,
                };
                self.downloads.lock().unwrap().insert(id.clone(), (info.clone(), CancellationToken::new()));
                self.events.emit_ser("download.progress", &info);
                return Ok((id, true));
            }
        }
        let dest_name = match &family {
            Some(fam) => format!("{fam}__{first_name}"),
            None => first_name.clone(),
        };
        let info = DownloadInfo {
            id: id.clone(),
            repo: repo.to_string(),
            file: file.to_string(),
            dest: dest_dir.join(&dest_name),
            done: 0,
            total: 0,
            speed: 0.0,
            state: "running".into(),
            error: None,
        };
        let token_c = CancellationToken::new();
        self.downloads.lock().unwrap().insert(id.clone(), (info.clone(), token_c.clone()));
        let me = Arc::clone(self);
        let repo = repo.to_string();
        tokio::spawn(async move {
            let mut info = info;
            let res = me.run_download(&mut info, &repo, &files, &dest_dir, mmproj_for.is_some(), token.as_deref(), &token_c).await;
            match res {
                Ok(()) => info.state = "done".into(),
                Err(e) if token_c.is_cancelled() => {
                    info.state = "cancelled".into();
                    info.error = Some(e.to_string());
                }
                Err(e) => {
                    info.state = "failed".into();
                    info.error = Some(e.to_string());
                }
            }
            me.update(&info);
            if info.state == "done" {
                me.events.emit("models.changed", json!({}));
            }
        });
        Ok((id, false))
    }

    #[allow(clippy::too_many_arguments)]
    async fn run_download(
        &self,
        info: &mut DownloadInfo,
        repo: &str,
        files: &[String],
        dest_dir: &Path,
        is_mmproj: bool,
        token: Option<&str>,
        cancel: &CancellationToken,
    ) -> anyhow::Result<()> {
        // Toplam boyut ve özetler.
        let meta = self.files(repo, token).await.unwrap_or_default();
        let tree: HashMap<String, (u64, Option<String>)> = {
            let url = format!("https://huggingface.co/api/models/{repo}/tree/main?recursive=true");
            let v: Vec<Value> = self.get(&url, token).send().await?.json().await.unwrap_or_default();
            v.iter()
                .filter_map(|f| {
                    Some((
                        f["path"].as_str()?.to_string(),
                        (f["lfs"]["size"].as_u64().or(f["size"].as_u64()).unwrap_or(0), f["lfs"]["oid"].as_str().map(String::from)),
                    ))
                })
                .collect()
        };
        let _ = meta;
        info.total = files.iter().map(|f| tree.get(f).map(|t| t.0).unwrap_or(0)).sum();
        let free = free_space(dest_dir);
        if let Some(free) = free {
            if info.total > 0 && free < info.total + (2u64 << 30) {
                anyhow::bail!(
                    "Diskte yeterli yer yok: {} gerekiyor, {} boş.",
                    crate::util::human_bytes(info.total),
                    crate::util::human_bytes(free)
                );
            }
        }
        tokio::fs::create_dir_all(dest_dir).await?;
        let mut base_done = 0u64;
        for f in files {
            let name = Path::new(f).file_name().unwrap().to_string_lossy().to_string();
            let dest = if is_mmproj { info.dest.clone() } else { dest_dir.join(&name) };
            let (size, sha) = tree.get(f).cloned().unwrap_or((0, None));
            if dest.is_file() && std::fs::metadata(&dest).map(|m| m.len()).unwrap_or(0) == size && size > 0 {
                base_done += size;
                continue;
            }
            self.download_one(info, repo, f, &dest, size, sha.as_deref(), base_done, token, cancel).await?;
            base_done += size;
        }
        info.done = info.total;
        Ok(())
    }

    #[allow(clippy::too_many_arguments)]
    async fn download_one(
        &self,
        info: &mut DownloadInfo,
        repo: &str,
        file: &str,
        dest: &Path,
        size: u64,
        sha: Option<&str>,
        base_done: u64,
        token: Option<&str>,
        cancel: &CancellationToken,
    ) -> anyhow::Result<()> {
        let part = PathBuf::from(format!("{}.part", dest.display()));
        let mut have = tokio::fs::metadata(&part).await.map(|m| m.len()).unwrap_or(0);
        if size > 0 && have > size {
            have = 0;
            let _ = tokio::fs::remove_file(&part).await;
        }
        // Devam eden indirmede özet, mevcut parçadan başlatılır.
        let mut hasher = Sha256::new();
        if have > 0 && sha.is_some() {
            info.state = "verifying".into();
            self.update(info);
            let p = part.clone();
            let h = tokio::task::spawn_blocking(move || -> std::io::Result<Sha256> {
                use std::io::Read;
                let mut f = std::fs::File::open(p)?;
                let mut h = Sha256::new();
                let mut buf = vec![0u8; 4 << 20];
                loop {
                    let n = f.read(&mut buf)?;
                    if n == 0 {
                        break;
                    }
                    h.update(&buf[..n]);
                }
                Ok(h)
            })
            .await??;
            hasher = h;
            info.state = "running".into();
        }
        let url = format!("https://huggingface.co/{repo}/resolve/main/{file}?download=true");
        let mut req = self.get(&url, token);
        if have > 0 {
            req = req.header("Range", format!("bytes={have}-"));
        }
        let resp = tokio::select! {
            r = req.send() => r?,
            _ = cancel.cancelled() => anyhow::bail!("İndirme iptal edildi."),
        };
        let status = resp.status();
        if status.as_u16() == 401 || status.as_u16() == 403 {
            anyhow::bail!("Bu model erişim izni istiyor: Hugging Face'te lisansı kabul edip Ayarlar'a erişim jetonu girin.");
        }
        if !status.is_success() {
            anyhow::bail!("İndirme başarısız: HTTP {status}");
        }
        if have > 0 && status.as_u16() != 206 {
            // Sunucu devam ettirmeyi desteklemedi: baştan başla.
            have = 0;
            hasher = Sha256::new();
        }
        let mut f = tokio::fs::OpenOptions::new()
            .create(true)
            .write(true)
            .append(have > 0)
            .truncate(have == 0)
            .open(&part)
            .await?;
        let mut stream = resp.bytes_stream();
        let mut done = have;
        let mut last = Instant::now();
        let mut last_bytes = done;
        loop {
            let next = tokio::select! {
                n = tokio::time::timeout(Duration::from_secs(90), stream.next()) => n,
                _ = cancel.cancelled() => { f.flush().await.ok(); anyhow::bail!("İndirme iptal edildi; kaldığı yerden devam edilebilir."); }
            };
            let Some(chunk) = next.map_err(|_| anyhow::anyhow!("Bağlantı 90 saniyedir veri göndermiyor."))? else { break };
            let chunk = chunk?;
            if sha.is_some() {
                hasher.update(&chunk);
            }
            f.write_all(&chunk).await?;
            done += chunk.len() as u64;
            if last.elapsed() >= Duration::from_millis(500) {
                info.speed = (done - last_bytes) as f64 / last.elapsed().as_secs_f64();
                info.done = base_done + done;
                last = Instant::now();
                last_bytes = done;
                self.update(info);
            }
        }
        f.flush().await?;
        drop(f);
        if size > 0 && done != size {
            anyhow::bail!("İndirme eksik kaldı ({done}/{size} bayt); tekrar deneyince kaldığı yerden devam eder.");
        }
        if let Some(expected) = sha {
            let actual = hex::encode(hasher.finalize());
            if !actual.eq_ignore_ascii_case(expected) {
                let _ = tokio::fs::remove_file(&part).await;
                anyhow::bail!("Dosya doğrulanamadı (SHA-256 uyuşmuyor); bozuk parça silindi, tekrar indirin.");
            }
        }
        tokio::fs::rename(&part, dest).await?;
        Ok(())
    }
}

fn validate_repo(repo: &str) -> anyhow::Result<()> {
    let ok = repo.split('/').count() == 2
        && repo.chars().all(|c| c.is_ascii_alphanumeric() || "-_./".contains(c))
        && !repo.contains("..");
    if !ok {
        anyhow::bail!("geçersiz depo adı: {repo}");
    }
    Ok(())
}

/// Görsel adaptörün (mmproj) kaydedileceği aile adı. Bir depodaki bütün kuantizasyonlar (Q4_K, Q8_0…) aynı adaptörü
/// kullanır; ad modelin değil ailenin adıyla verilir ki sürümler onu paylaşsın: depo adı ile model adının ortak başı
/// ("…/Huihui-Qwen3.8-27B-abliterated-GGUF" + "Huihui-Qwen3.8-27B-abliterated-Q4_K.gguf" →
/// "Huihui-Qwen3.8-27B-abliterated"). Ortak baş çok kısaysa modelin adı kullanılır. Model başlatılırken adaptör ad
/// ön ekiyle eşleştirildiğinden (`llama::find_mmproj`) ailenin bütün sürümleri onu bulur.
pub fn mmproj_family(repo: &str, model_file: &str) -> String {
    let model = crate::gguf::base_name(Path::new(model_file));
    let repo_name = repo.rsplit('/').next().unwrap_or(repo);
    let lower = repo_name.to_lowercase();
    let repo_name = ["-gguf", "_gguf", ".gguf"]
        .iter()
        .find(|s| lower.ends_with(*s))
        .map(|s| &repo_name[..repo_name.len() - s.len()])
        .unwrap_or(repo_name);
    let common = model.chars().zip(repo_name.chars()).take_while(|(a, b)| a.eq_ignore_ascii_case(b)).count();
    let family: String = model.chars().take(common).collect::<String>().trim_end_matches(['-', '_', '.', ' ']).to_string();
    if family.chars().count() >= 6 {
        family
    } else {
        model
    }
}

/// Bu aileye ait aynı adaptör dosyası zaten indirilmiş mi? Eski sürümler adaptörü her kuantizasyon için ayrı adla
/// (`<model-Q4_K>__mmproj-….gguf`) kaydediyordu; onlar da sayılır. Boyut biliniyorsa aynı olmalı.
fn existing_adapter(dir: &Path, family: &str, file_name: &str, expected_size: Option<u64>) -> Option<PathBuf> {
    let suffix = format!("__{}", file_name.to_lowercase());
    let fam = family.to_lowercase();
    let mut found: Vec<PathBuf> = std::fs::read_dir(dir)
        .ok()?
        .flatten()
        .filter(|e| {
            let n = e.file_name().to_string_lossy().to_lowercase();
            n.ends_with(&suffix) && n.starts_with(&fam) && e.path().is_file()
        })
        .filter(|e| expected_size.is_none_or(|s| e.metadata().is_ok_and(|m| m.len() == s)))
        .map(|e| e.path())
        .collect();
    found.sort();
    found.into_iter().next()
}

/// Diskteki boş alan (bayt).
pub fn free_space(dir: &Path) -> Option<u64> {
    let disks = sysinfo::Disks::new_with_refreshed_list();
    let target = dunce::canonicalize(dir).ok().or_else(|| dir.parent().and_then(|p| dunce::canonicalize(p).ok()))?;
    disks
        .list()
        .iter()
        .filter(|d| target.starts_with(d.mount_point()))
        .max_by_key(|d| d.mount_point().as_os_str().len())
        .map(|d| d.available_space())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn repo_validation() {
        assert!(validate_repo("unsloth/gemma-3-12b-it-GGUF").is_ok());
        assert!(validate_repo("../etc").is_err());
        assert!(validate_repo("a/b/c").is_err());
        assert!(validate_repo("a/b?x=1").is_err());
    }

    #[test]
    fn adapter_family_names() {
        let f = |repo, model| mmproj_family(repo, model);
        assert_eq!(f("huihui-ai/Huihui-Qwen3.8-27B-abliterated-GGUF", "Huihui-Qwen3.8-27B-abliterated-Q4_K.gguf"), "Huihui-Qwen3.8-27B-abliterated");
        assert_eq!(f("huihui-ai/Huihui-Qwen3.8-27B-abliterated-GGUF", "Huihui-Qwen3.8-27B-abliterated-Q8_0_L.gguf"), "Huihui-Qwen3.8-27B-abliterated");
        assert_eq!(f("unsloth/gemma-4-12b-it-GGUF", "gemma-4-12b-it-UD-IQ2_M.gguf"), "gemma-4-12b-it");
        assert_eq!(f("bartowski/Qwen_Qwen3-8B-GGUF", "Qwen_Qwen3-8B-Q4_K_M.gguf"), "Qwen_Qwen3-8B");
        // Bölünmüş model: parça eki atılır.
        assert_eq!(f("x/GLM-4.5-Air-GGUF", "GLM-4.5-Air-Q4_K_S-00001-of-00002.gguf"), "GLM-4.5-Air");
        // Depo adı modelle hiç uyuşmuyorsa modelin kendi adı.
        assert_eq!(f("someone/vision-pack", "Mistral-7B-Q4_K_M.gguf"), "Mistral-7B-Q4_K_M");
        // Bu bilgisayarda iki kez inen adaptör artık ikisi için de aynı adı alır.
        assert_eq!(
            format!("{}__mmproj-model-bf16.gguf", f("huihui-ai/Huihui-Qwen3.8-27B-abliterated-GGUF", "Huihui-Qwen3.8-27B-abliterated-Q4_K.gguf")),
            "Huihui-Qwen3.8-27B-abliterated__mmproj-model-bf16.gguf"
        );
    }

    #[test]
    fn existing_adapter_is_reused() {
        let dir = tempfile::tempdir().unwrap();
        // Eski adlandırmayla (sürüme göre) indirilmiş adaptör.
        std::fs::write(dir.path().join("Huihui-Qwen3.8-27B-abliterated-Q8_0_L__mmproj-model-bf16.gguf"), vec![0u8; 100]).unwrap();
        let fam = "Huihui-Qwen3.8-27B-abliterated";
        assert!(existing_adapter(dir.path(), fam, "mmproj-model-bf16.gguf", Some(100)).is_some());
        assert!(existing_adapter(dir.path(), fam, "MMPROJ-model-BF16.gguf", None).is_some(), "büyük/küçük harf fark etmez");
        assert!(existing_adapter(dir.path(), fam, "mmproj-model-bf16.gguf", Some(999)).is_none(), "boyut farklıysa başka dosyadır");
        assert!(existing_adapter(dir.path(), fam, "mmproj-model-f16.gguf", None).is_none(), "başka adaptör");
        assert!(existing_adapter(dir.path(), "Qwen3.8-27B", "mmproj-model-bf16.gguf", None).is_none(), "başka aile");
        // Yeni (aile) adıyla kaydedilmiş adaptör de bulunur.
        std::fs::write(dir.path().join("gemma-4-12b-it__mmproj-F16.gguf"), b"x").unwrap();
        assert!(existing_adapter(dir.path(), "gemma-4-12b-it", "mmproj-F16.gguf", Some(1)).is_some());
    }

    /// Aile adıyla kaydedilen adaptör, model başlatılırken ailenin her sürümüyle eşleşir.
    #[test]
    fn family_named_adapter_matches_every_quant() {
        let dir = tempfile::tempdir().unwrap();
        let mm = dir.path().join("mmproj");
        std::fs::create_dir_all(&mm).unwrap();
        std::fs::write(mm.join("Huihui-Qwen3.8-27B-abliterated__mmproj-model-bf16.gguf"), b"x").unwrap();
        let dirs = vec![dir.path().to_path_buf()];
        for q in ["Q4_K", "Q8_0_L", "UD-Q8_K_XL"] {
            let model = dir.path().join(format!("Huihui-Qwen3.8-27B-abliterated-{q}.gguf"));
            assert!(crate::llama::find_mmproj(&model, &dirs).is_some(), "{q}");
        }
    }
}
