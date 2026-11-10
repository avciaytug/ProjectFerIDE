//! Ses: isteğe bağlı STT (Whisper) ve TTS (Feride/Ahenk Cep, Piper) sunucularının denetimi.
//! Ses arayüzde (WebView) çalınır; v5.3.8'deki gibi her cümle için ayrı bir oynatıcı süreci açılmaz.
//! Sunucular İş Nesnesi'ne bağlıdır ve yalnızca 127.0.0.1'i dinler; hiçbiri çalışırken internete çıkmaz.
//!
//! Konuşma tanıma iki motorla yapılır:
//! - GPU: whisper.cpp sunucusu (Vulkan/Metal) + Whisper large-v3-turbo — doğru ve hızlı (~0,5 sn).
//! - CPU: Python faster-whisper (small / large-v3-turbo) — GPU yoksa ya da GPU motoru hata verirse.

use base64::Engine;
use serde::Serialize;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{LazyLock, Mutex};
use std::time::Duration;

/// GPU konuşma tanıma modeli (ggerganov/whisper.cpp, MIT).
pub const GGML_STT_MODEL: &str = "ggml-large-v3-turbo-q8_0.bin";
/// Whisper'a bağlam ipucu: asistanın adını ve Türkçe konuşmayı doğru yazması için.
const STT_PROMPT: &str = "Bu Türkçe bir konuşmadır. Feride bir yapay zeka asistanıdır.";

static HALLUCINATION: LazyLock<regex::Regex> = LazyLock::new(|| {
    regex::Regex::new(
        r"(?i)\[[^\]]*\]|\([^)]*müzik[^)]*\)|altyazı(\s+m\.?\s*k\.?)?|abone olmayı unutmayın|izlediğiniz için teşekkürler|amara\.org",
    )
    .unwrap()
});

use crate::paths::Paths;
use crate::proc::KillHandle;

#[derive(Clone, Debug, Serialize, Default)]
pub struct VoiceStatus {
    pub installed: bool,
    pub stt: String,
    pub tts: String,
    /// TTS sunucusunda gerçekten yüklenen sesler (female = Feride/Ahenk Cep, male = Fahrettin/Piper).
    pub voices: Option<serde_json::Value>,
    /// Konuşma tanıma motoru: "gpu" (whisper.cpp) | "cpu" (faster-whisper) | null (henüz başlamadı)
    pub stt_engine: Option<String>,
    /// Ses paketi eski sürüm (kadın sesi bağımlılıkları / yeni Whisper modelleri yok): Kurulum'dan güncellenmeli.
    pub update_needed: bool,
    pub error: Option<String>,
}

struct Srv {
    port: u16,
    kill: KillHandle,
}

pub struct Voice {
    paths: Paths,
    http: reqwest::Client,
    stt: Mutex<Option<Srv>>,
    tts: Mutex<Option<Srv>>,
    /// whisper.cpp GPU sunucusu
    gpu: Mutex<Option<Srv>>,
    /// GPU motoru bu oturumda başlatılamadı / GPU bulamadı: bir daha denenmez.
    gpu_off: AtomicBool,
    voices: Mutex<Option<serde_json::Value>>,
    start_lock: tokio::sync::Mutex<()>,
}

impl Voice {
    pub fn new(paths: Paths) -> Self {
        Self {
            paths,
            http: reqwest::Client::builder().timeout(Duration::from_secs(120)).build().unwrap(),
            stt: Mutex::new(None),
            tts: Mutex::new(None),
            gpu: Mutex::new(None),
            gpu_off: AtomicBool::new(false),
            voices: Mutex::new(None),
            start_lock: tokio::sync::Mutex::new(()),
        }
    }

    pub fn installed(&self) -> bool {
        self.paths.pyenv_python().is_file() && self.paths.pyenv().join(".feride-voice").exists()
    }

    pub fn status(&self) -> VoiceStatus {
        VoiceStatus {
            installed: self.installed(),
            stt: if self.stt.lock().unwrap().is_some() { "ready".into() } else { "stopped".into() },
            tts: if self.tts.lock().unwrap().is_some() { "ready".into() } else { "stopped".into() },
            voices: self.voices.lock().unwrap().clone(),
            stt_engine: if self.gpu.lock().unwrap().is_some() {
                Some("gpu".into())
            } else if self.stt.lock().unwrap().is_some() {
                Some("cpu".into())
            } else {
                None
            },
            update_needed: self.installed()
                && !std::fs::read_to_string(self.paths.pyenv().join(".feride-voice"))
                    .unwrap_or_default()
                    .contains(crate::deps::VOICE_PACK),
            error: None,
        }
    }

    async fn ensure(&self, which: &str) -> anyhow::Result<u16> {
        let slot = if which == "stt" { &self.stt } else { &self.tts };
        if let Some(s) = slot.lock().unwrap().as_ref() {
            return Ok(s.port);
        }
        let _g = self.start_lock.lock().await;
        if let Some(s) = slot.lock().unwrap().as_ref() {
            return Ok(s.port);
        }
        if !self.installed() {
            anyhow::bail!("Ses paketi kurulu değil. Ayarlar > Kurulum'dan \"Ses paketi\"ni kurun.");
        }
        let port = crate::llama::free_port().ok_or_else(|| anyhow::anyhow!("boş port yok"))?;
        let script = self.paths.resources().join("python").join(if which == "stt" { "stt_server.py" } else { "tts_server.py" });
        let mut args = vec![script.to_string_lossy().to_string()];
        if which == "stt" {
            args.extend(["--port".into(), port.to_string()]);
        }
        let mut cmd = crate::proc::command(&self.paths, &self.paths.pyenv_python().to_string_lossy(), &args);
        cmd.env("FERIDE_ROOT", self.paths.voice())
            .env("FERIDE_TTS_PORT", port.to_string())
            .env("PYTHONIOENCODING", "utf-8")
            .env("HF_HOME", self.paths.cache().join("hf"))
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null());
        let (mut child, kill) = crate::proc::spawn(&mut cmd)?;
        tokio::spawn(async move {
            let _ = child.wait().await;
        });
        // Hazır olmasını bekle (model yükleme 30 sn'ye kadar sürebilir).
        let url = format!("http://127.0.0.1:{port}/health");
        for _ in 0..240 {
            if let Ok(r) = self.http.get(&url).timeout(Duration::from_secs(2)).send().await {
                if r.status().is_success() {
                    if which == "tts" {
                        if let Ok(j) = r.json::<serde_json::Value>().await {
                            *self.voices.lock().unwrap() = Some(j["voices"].clone());
                        }
                    }
                    *slot.lock().unwrap() = Some(Srv { port, kill });
                    return Ok(port);
                }
            }
            tokio::time::sleep(Duration::from_millis(250)).await;
        }
        kill.kill_tree();
        anyhow::bail!("Ses sunucusu ({which}) 60 saniyede başlamadı.")
    }

    /// whisper.cpp sunucusu ve GPU modeli kuruluysa yolları.
    fn gpu_files(&self) -> Option<(PathBuf, PathBuf)> {
        let exe = self.paths.tools().join("whisper").join(if cfg!(windows) { "whisper-server.exe" } else { "whisper-server" });
        let model = self.paths.voice().join("models").join("whisper-ggml").join(GGML_STT_MODEL);
        (exe.is_file() && model.is_file()).then_some((exe, model))
    }

    /// GPU konuşma tanıma sunucusunu başlatır. GPU bulunamazsa (yalnızca CPU) kapatır ve `None` döner;
    /// o durumda Python faster-whisper (CTranslate2 int8) işlemcide daha hızlıdır.
    async fn ensure_gpu(&self) -> Option<u16> {
        if self.gpu_off.load(Ordering::Relaxed) {
            return None;
        }
        if let Some(s) = self.gpu.lock().unwrap().as_ref() {
            return Some(s.port);
        }
        let (exe, model) = self.gpu_files()?;
        let _g = self.start_lock.lock().await;
        if let Some(s) = self.gpu.lock().unwrap().as_ref() {
            return Some(s.port);
        }
        match self.start_gpu(&exe, &model).await {
            Ok(port) => Some(port),
            Err(e) => {
                tracing::warn!("GPU konuşma tanıma kullanılamıyor, işlemciye geçiliyor: {e}");
                self.gpu_off.store(true, Ordering::Relaxed);
                None
            }
        }
    }

    async fn start_gpu(&self, exe: &std::path::Path, model: &std::path::Path) -> anyhow::Result<u16> {
        let port = crate::llama::free_port().ok_or_else(|| anyhow::anyhow!("boş port yok"))?;
        let log_path = self.paths.logs().join("whisper_server.log");
        let log = std::fs::File::create(&log_path)?;
        let args: Vec<String> = vec![
            "-m".into(),
            model.to_string_lossy().into(),
            "--host".into(),
            "127.0.0.1".into(),
            "--port".into(),
            port.to_string(),
            "-l".into(),
            "tr".into(),
            "-t".into(),
            "4".into(),
            "-bs".into(),
            "5".into(),
            "-fa".into(),
            "--prompt".into(),
            STT_PROMPT.into(),
        ];
        let mut cmd = crate::proc::command(&self.paths, &exe.to_string_lossy(), &args);
        cmd.stdout(std::process::Stdio::from(log.try_clone()?)).stderr(std::process::Stdio::from(log));
        let (mut child, kill) = crate::proc::spawn(&mut cmd)?;
        let url = format!("http://127.0.0.1:{port}/");
        for _ in 0..240 {
            if let Ok(Some(st)) = child.try_wait() {
                anyhow::bail!("whisper-server kapandı ({st}); ayrıntı: {}", log_path.display());
            }
            if self.http.get(&url).timeout(Duration::from_secs(2)).send().await.is_ok() {
                // Gerçekten GPU mu? whisper.cpp yalnızca CPU bulduysa Python motoru daha hızlı.
                let out = std::fs::read_to_string(&log_path).unwrap_or_default().to_lowercase();
                let gpu = (out.contains("vulkan") && !out.contains("found 0 vulkan devices")) || out.contains("metal");
                if !gpu || out.contains("no gpu found") {
                    kill.kill_tree();
                    anyhow::bail!("whisper.cpp GPU bulamadı");
                }
                tokio::spawn(async move {
                    let _ = child.wait().await;
                });
                tracing::info!("GPU konuşma tanıma hazır (whisper.cpp, port {port})");
                *self.gpu.lock().unwrap() = Some(Srv { port, kill });
                // İlk çıkarım GPU hesap grafiğini hazırlar (~2 sn); kullanıcının ilk cümlesi beklemesin.
                let _ = self.transcribe_gpu(port, &silent_wav(1000)).await;
                return Ok(port);
            }
            tokio::time::sleep(Duration::from_millis(250)).await;
        }
        kill.kill_tree();
        anyhow::bail!("whisper-server 60 saniyede başlamadı")
    }

    async fn transcribe_gpu(&self, port: u16, wav: &[u8]) -> anyhow::Result<String> {
        // multipart/form-data elle kurulur (reqwest'in multipart özelliğine gerek yok).
        let boundary = format!("feride{}", uuid::Uuid::new_v4().simple());
        let mut body: Vec<u8> = Vec::with_capacity(wav.len() + 1024);
        let field = |b: &mut Vec<u8>, name: &str, value: &str| {
            b.extend(format!("--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{value}\r\n").as_bytes());
        };
        field(&mut body, "response_format", "json");
        field(&mut body, "language", "tr");
        field(&mut body, "temperature", "0.0");
        body.extend(
            format!("--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"ses.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
                .as_bytes(),
        );
        body.extend_from_slice(wav);
        body.extend(format!("\r\n--{boundary}--\r\n").as_bytes());
        let started = std::time::Instant::now();
        let r = self
            .http
            .post(format!("http://127.0.0.1:{port}/inference"))
            .header("Content-Type", format!("multipart/form-data; boundary={boundary}"))
            .body(body)
            .send()
            .await?
            .error_for_status()?;
        let j: serde_json::Value = r.json().await?;
        if let Some(e) = j["error"].as_str() {
            anyhow::bail!("{e}");
        }
        let text = clean_transcript(j["text"].as_str().unwrap_or_default());
        tracing::info!("GPU konuşma tanıma: {:.2} sn → {text:?}", started.elapsed().as_secs_f64());
        Ok(text)
    }

    /// Canlı sohbet öncesi konuşma tanıma ve ses sunucularını başlatır (ilk yanıt beklemesin).
    pub async fn warmup(&self) -> anyhow::Result<()> {
        if self.ensure_gpu().await.is_none() {
            self.ensure("stt").await?;
        }
        self.ensure("tts").await?;
        Ok(())
    }

    /// Ses kaydını yazıya çevirir. `audio` base64 (webm/wav/ogg).
    /// `vad`: false ise sunucudaki Silero VAD atlanır (kayıt arayüzde zaten konuşma olarak ayrıldıysa).
    /// `quality`: auto | fast | accurate (bkz. `VoiceSettings::stt_quality`).
    pub async fn transcribe(&self, audio_b64: &str, mime: &str, vad: bool, quality: &str) -> anyhow::Result<String> {
        let bytes = base64::engine::general_purpose::STANDARD.decode(audio_b64)?;
        if bytes.len() > 50 << 20 {
            anyhow::bail!("ses kaydı çok büyük");
        }
        // GPU motoru: en doğru model, hızlı. "fast" kipinde ve WAV dışı kayıtlarda Python motoru kullanılır.
        if quality != "fast" && mime.contains("wav") {
            if let Some(port) = self.ensure_gpu().await {
                match self.transcribe_gpu(port, &bytes).await {
                    Ok(t) => return Ok(t),
                    Err(e) => tracing::warn!("GPU konuşma tanıma hatası, işlemciye geçiliyor: {e}"),
                }
            }
        }
        let port = self.ensure("stt").await?;
        let r = self
            .http
            .post(format!("http://127.0.0.1:{port}/transcribe"))
            .header("Content-Type", mime)
            .header("X-Language", "tr")
            .header("X-Vad", if vad { "on" } else { "off" })
            .header("X-Quality", quality)
            .body(bytes)
            .send()
            .await?;
        let j: serde_json::Value = r.json().await?;
        if let Some(e) = j["error"].as_str() {
            anyhow::bail!("{e}");
        }
        Ok(j["text"].as_str().unwrap_or_default().trim().to_string())
    }

    /// Metni sese çevirir; WAV baytlarını base64 döndürür.
    pub async fn speak(&self, text: &str, voice: &str, speed: f32) -> anyhow::Result<String> {
        let port = self.ensure("tts").await?;
        let r = self
            .http
            .post(format!("http://127.0.0.1:{port}/tts"))
            .json(&serde_json::json!({"text": crate::util::truncate_end(text, 4000), "voice": voice, "speed": speed}))
            .send()
            .await?
            .error_for_status()?;
        let b = r.bytes().await?;
        Ok(base64::engine::general_purpose::STANDARD.encode(&b))
    }

    pub fn shutdown(&self) {
        for slot in [&self.stt, &self.tts, &self.gpu] {
            if let Some(s) = slot.lock().unwrap().take() {
                s.kill.kill_tree();
            }
        }
    }
}

/// 16 kHz mono 16-bit sessiz WAV (GPU ısıtması için).
fn silent_wav(ms: u32) -> Vec<u8> {
    let data_len = 16 * ms * 2;
    let mut b = Vec::with_capacity(44 + data_len as usize);
    b.extend(b"RIFF");
    b.extend((36 + data_len).to_le_bytes());
    b.extend(b"WAVEfmt ");
    b.extend(16u32.to_le_bytes());
    b.extend(1u16.to_le_bytes()); // PCM
    b.extend(1u16.to_le_bytes()); // mono
    b.extend(16000u32.to_le_bytes());
    b.extend(32000u32.to_le_bytes());
    b.extend(2u16.to_le_bytes());
    b.extend(16u16.to_le_bytes());
    b.extend(b"data");
    b.extend(data_len.to_le_bytes());
    b.resize(44 + data_len as usize, 0);
    b
}

/// Whisper'ın sessizlikte uydurduğu kalıpları ve [BLANK_AUDIO] gibi işaretleri siler.
pub fn clean_transcript(t: &str) -> String {
    let t = HALLUCINATION.replace_all(t, " ");
    let t = t.split_whitespace().collect::<Vec<_>>().join(" ");
    t.trim_start_matches(|c: char| c == '.' || c == ',' || c == '?' || c == '!' || c.is_whitespace()).to_string()
}

#[cfg(test)]
mod tests {
    use super::clean_transcript;

    #[test]
    fn transcript_cleanup() {
        assert_eq!(clean_transcript(" [BLANK_AUDIO]"), "");
        assert_eq!(clean_transcript(" Merhaba, beni duyabiliyor musun?"), "Merhaba, beni duyabiliyor musun?");
        assert_eq!(clean_transcript("Altyazı M.K."), "");
        assert_eq!(clean_transcript("Tamam. (müzik)"), "Tamam.");
    }
}
