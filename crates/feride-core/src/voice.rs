//! Ses: isteğe bağlı Python STT (Whisper) ve TTS (Feride/Ahenk Cep, Piper) sunucularının
//! denetimi. Ses arayüzde (WebView) çalınır; v5.3.8'deki gibi her cümle için ayrı bir
//! oynatıcı süreci açılmaz. Sunucular İş Nesnesi'ne bağlıdır ve yalnızca 127.0.0.1'i dinler.

use base64::Engine;
use serde::Serialize;
use std::sync::Mutex;
use std::time::Duration;

use crate::paths::Paths;
use crate::proc::KillHandle;

#[derive(Clone, Debug, Serialize, Default)]
pub struct VoiceStatus {
    pub installed: bool,
    pub stt: String,
    pub tts: String,
    /// TTS sunucusunda gerçekten yüklenen sesler (female = Feride/Ahenk Cep, male = Fahrettin/Piper).
    pub voices: Option<serde_json::Value>,
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

    /// Canlı sohbet öncesi iki sunucuyu da başlatır (ilk yanıt beklemesin).
    pub async fn warmup(&self) -> anyhow::Result<()> {
        self.ensure("stt").await?;
        self.ensure("tts").await?;
        Ok(())
    }

    /// Ses kaydını yazıya çevirir. `audio` base64 (webm/wav/ogg).
    /// `vad`: false ise sunucudaki Silero VAD atlanır (kayıt arayüzde zaten konuşma olarak ayrıldıysa).
    /// `quality`: auto | fast | accurate (bkz. `VoiceSettings::stt_quality`).
    pub async fn transcribe(&self, audio_b64: &str, mime: &str, vad: bool, quality: &str) -> anyhow::Result<String> {
        let port = self.ensure("stt").await?;
        let bytes = base64::engine::general_purpose::STANDARD.decode(audio_b64)?;
        if bytes.len() > 50 << 20 {
            anyhow::bail!("ses kaydı çok büyük");
        }
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
        for slot in [&self.stt, &self.tts] {
            if let Some(s) = slot.lock().unwrap().take() {
                s.kill.kill_tree();
            }
        }
    }
}
