//! Kullanıcı ayarları (`~/.feride/config.toml`).

use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ComputeMode {
    /// Belleği ölç, en iyi yerleşimi seç.
    #[default]
    Auto,
    /// Tamamı GPU'da.
    Gpu,
    /// MoE uzmanları RAM'de, kalanı GPU'da.
    Hybrid,
    /// Yalnızca işlemci.
    Cpu,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PermissionMode {
    /// Salt okunur: ajan inceler ve plan yapar, hiçbir şeyi değiştirmez.
    Plan,
    /// Okuma dışındaki her işlem için sor.
    Ask,
    /// Çalışma alanındaki dosya düzenlemelerine izin ver; komutları sor.
    #[default]
    AutoEdit,
    /// Hiçbir şey sorulmaz (yıkıcı komutlar yine engellenir).
    FullAuto,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct Settings {
    pub language: String,
    pub theme: String,
    pub workspace: Option<PathBuf>,
    pub recent_workspaces: Vec<PathBuf>,
    pub model: ModelSettings,
    pub provider: ProviderSettings,
    pub agent: AgentSettings,
    pub voice: VoiceSettings,
    pub editor: EditorSettings,
    pub disabled_skills: Vec<String>,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            language: "tr".into(),
            theme: "dark".into(),
            workspace: None,
            recent_workspaces: vec![],
            model: ModelSettings::default(),
            provider: ProviderSettings::default(),
            agent: AgentSettings::default(),
            voice: VoiceSettings::default(),
            editor: EditorSettings::default(),
            disabled_skills: vec![],
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct ModelSettings {
    /// Seçili GGUF dosyasının tam yolu.
    pub selected: Option<PathBuf>,
    pub compute_mode: ComputeMode,
    /// 0 = otomatik.
    pub context: u32,
    /// Modellerin arandığı ek klasörler.
    pub extra_dirs: Vec<PathBuf>,
    /// llama.cpp derlemesi: auto | vulkan | cuda | cpu | hip | metal
    pub backend: String,
    /// Elle seçilmiş llama-server yolu (boşsa FerIDE'nin kurduğu kullanılır).
    pub server_path: Option<PathBuf>,
    /// Açılışta seçili modeli otomatik başlat.
    pub auto_start: bool,
}

impl Default for ModelSettings {
    fn default() -> Self {
        Self {
            selected: None,
            compute_mode: ComputeMode::Auto,
            context: 0,
            extra_dirs: vec![],
            backend: "auto".into(),
            server_path: None,
            auto_start: false,
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct ProviderSettings {
    /// local = FerIDE'nin yönettiği llama-server; openai = OpenAI uyumlu uzak/yerel uç nokta.
    pub kind: String,
    pub base_url: String,
    pub model: String,
    /// Uzak uç nokta için bağlam sınırı (yerelde sunucudan okunur).
    pub context: u32,
}

impl Default for ProviderSettings {
    fn default() -> Self {
        Self { kind: "local".into(), base_url: String::new(), model: String::new(), context: 32768 }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct AgentSettings {
    pub permission_mode: PermissionMode,
    pub max_steps: u32,
    pub temperature: f32,
    pub thinking: bool,
    pub max_tool_output_chars: usize,
    /// auto | bash | powershell | cmd | sh
    pub shell: String,
    pub command_timeout_secs: u64,
}

impl Default for AgentSettings {
    fn default() -> Self {
        Self {
            permission_mode: PermissionMode::AutoEdit,
            max_steps: 100,
            temperature: 0.6,
            thinking: false,
            max_tool_output_chars: 16_000,
            shell: "auto".into(),
            command_timeout_secs: 300,
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct VoiceSettings {
    pub enabled: bool,
    /// female (Feride — Ahenk Cep) | male (Fahrettin — Piper)
    pub voice: String,
    pub speed: f32,
    pub auto_speak: bool,
}

impl Default for VoiceSettings {
    fn default() -> Self {
        Self { enabled: false, voice: "female".into(), speed: 1.0, auto_speak: false }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct EditorSettings {
    pub font_size: u32,
    pub tab_size: u32,
    pub word_wrap: bool,
}

impl Default for EditorSettings {
    fn default() -> Self {
        Self { font_size: 14, tab_size: 4, word_wrap: false }
    }
}

impl Settings {
    pub fn load(path: &Path) -> Self {
        match std::fs::read_to_string(path) {
            Ok(s) => toml::from_str(&s).unwrap_or_else(|e| {
                tracing::warn!("config.toml okunamadı, varsayılanlar kullanılıyor: {e}");
                let _ = std::fs::copy(path, path.with_extension("toml.bozuk"));
                Settings::default()
            }),
            Err(_) => Settings::default(),
        }
    }

    pub fn save(&self, path: &Path) -> anyhow::Result<()> {
        let text = toml::to_string_pretty(self)?;
        crate::util::write_atomic(path, text.as_bytes())
    }

    /// Arayüzden gelen kısmi JSON'u mevcut ayarların üzerine uygular.
    pub fn merged(&self, patch: &serde_json::Value) -> anyhow::Result<Settings> {
        let mut base = serde_json::to_value(self)?;
        crate::util::json_merge(&mut base, patch);
        Ok(serde_json::from_value(base)?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip_and_merge() {
        let s = Settings::default();
        let t = toml::to_string_pretty(&s).unwrap();
        let back: Settings = toml::from_str(&t).unwrap();
        assert_eq!(back.agent.permission_mode, PermissionMode::AutoEdit);
        let m = s.merged(&serde_json::json!({"agent": {"permission_mode": "plan"}, "theme": "light"})).unwrap();
        assert_eq!(m.agent.permission_mode, PermissionMode::Plan);
        assert_eq!(m.theme, "light");
        assert_eq!(m.agent.max_steps, 100);
    }

    #[test]
    fn partial_file_uses_defaults() {
        let s: Settings = toml::from_str("theme = \"light\"\n[model]\ncontext = 8192\n").unwrap();
        assert_eq!(s.model.context, 8192);
        assert_eq!(s.model.backend, "auto");
    }
}
