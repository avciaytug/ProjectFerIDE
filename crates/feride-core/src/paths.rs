//! FerIDE dizinleri.
//!
//! Veri dizini v5.3.8 ile aynıdır (`~/.feride`); böylece indirilmiş modeller,
//! skill'ler, MCP ayarları ve llama.cpp kurulumu yeni sürümde de kullanılır.
//! Kurulumda başka bir yer seçildiyse program klasöründeki `install.json` onu gösterir (bkz. `install`);
//! `FERIDE_HOME` ortam değişkeni ikisini de geçersiz kılar (testler, taşınabilir kullanım).

use std::path::{Path, PathBuf};

#[derive(Clone, Debug)]
pub struct Paths {
    pub home: PathBuf,
    pub data: PathBuf,
}

impl Paths {
    pub fn detect() -> Self {
        let home = home_dir();
        let data = crate::install::resolve_data_dir();
        let p = Self { home, data };
        p.ensure();
        p
    }

    pub fn with_data_dir(data: PathBuf) -> Self {
        let p = Self { home: home_dir(), data };
        p.ensure();
        p
    }

    fn ensure(&self) {
        for d in [
            self.data.clone(),
            self.models(),
            self.models().join("mmproj"),
            self.skills(),
            self.sessions(),
            self.logs(),
            self.tools(),
            self.run(),
            self.cache(),
            self.trash(),
        ] {
            let _ = std::fs::create_dir_all(d);
        }
    }

    pub fn config_file(&self) -> PathBuf {
        self.data.join("config.toml")
    }
    pub fn state_file(&self) -> PathBuf {
        self.data.join("state.json")
    }
    pub fn secrets_file(&self) -> PathBuf {
        self.data.join("secrets.bin")
    }
    pub fn mcp_config(&self) -> PathBuf {
        self.data.join("mcp_config.json")
    }
    pub fn memory_db(&self) -> PathBuf {
        self.data.join("memory.db")
    }
    pub fn legacy_aegis_db(&self) -> PathBuf {
        self.data.join("aegis").join("memory.db")
    }
    pub fn models(&self) -> PathBuf {
        self.data.join("models")
    }
    pub fn skills(&self) -> PathBuf {
        self.data.join("skills")
    }
    pub fn sessions(&self) -> PathBuf {
        self.data.join("sessions")
    }
    pub fn logs(&self) -> PathBuf {
        self.data.join("logs")
    }
    /// llama.cpp sürümleri: `bin/llama-cpp/<etiket>/...` (eski kurulum doğrudan `bin/llama-cpp`).
    pub fn llama_root(&self) -> PathBuf {
        self.data.join("bin").join("llama-cpp")
    }
    /// Taşınabilir araçlar: git, node, uv.
    pub fn tools(&self) -> PathBuf {
        self.data.join("tools")
    }
    /// Belge stüdyosu ve ses için Python ortamı (uv ile kurulur).
    pub fn pyenv(&self) -> PathBuf {
        self.data.join("pyenv")
    }
    pub fn voice(&self) -> PathBuf {
        self.data.join("voice")
    }
    /// Gömülü kaynakların (Python betikleri) açıldığı yer.
    pub fn resources(&self) -> PathBuf {
        self.data.join("resources")
    }
    pub fn run(&self) -> PathBuf {
        self.data.join("run")
    }
    pub fn cache(&self) -> PathBuf {
        self.data.join("cache")
    }
    /// Arayüzden silinen dosyalar buraya taşınır (geri alınabilir).
    pub fn trash(&self) -> PathBuf {
        self.data.join("trash")
    }

    pub fn pyenv_python(&self) -> PathBuf {
        if cfg!(windows) {
            self.pyenv().join("Scripts").join("python.exe")
        } else {
            self.pyenv().join("bin").join("python3")
        }
    }

    /// Alt süreçlerin PATH'inin başına eklenen dizinler (taşınabilir araçlar).
    pub fn tool_path_dirs(&self) -> Vec<PathBuf> {
        let t = self.tools();
        let mut v = vec![];
        if cfg!(windows) {
            v.push(t.join("git").join("cmd"));
            v.push(t.join("git").join("bin"));
            v.push(t.join("git").join("usr").join("bin"));
            v.push(t.join("node"));
            v.push(t.join("uv"));
            v.push(self.pyenv().join("Scripts"));
        } else {
            v.push(t.join("node").join("bin"));
            v.push(t.join("uv"));
            v.push(self.pyenv().join("bin"));
        }
        v.into_iter().filter(|p| p.exists()).collect()
    }
}

pub fn home_dir() -> PathBuf {
    #[cfg(windows)]
    let var = "USERPROFILE";
    #[cfg(not(windows))]
    let var = "HOME";
    std::env::var_os(var)
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .unwrap_or_else(|| PathBuf::from("."))
}

/// `~` ile başlayan yolu açar.
pub fn expand_tilde(s: &str, home: &Path) -> PathBuf {
    if s == "~" {
        return home.to_path_buf();
    }
    if let Some(rest) = s.strip_prefix("~/").or_else(|| s.strip_prefix("~\\")) {
        return home.join(rest);
    }
    PathBuf::from(s)
}

/// `..` ve `.` parçalarını dosya sistemine dokunmadan çözer.
pub fn normalize(p: &Path) -> PathBuf {
    use std::path::Component;
    let mut out = PathBuf::new();
    for c in p.components() {
        match c {
            Component::ParentDir => {
                if !out.pop() {
                    out.push("..");
                }
            }
            Component::CurDir => {}
            other => out.push(other.as_os_str()),
        }
    }
    out
}

/// `child`, `parent`'ın içinde mi (ya da kendisi mi)? Büyük/küçük harf Windows'ta önemsiz.
pub fn is_within(parent: &Path, child: &Path) -> bool {
    let p = normalize(parent);
    let c = normalize(child);
    if cfg!(windows) {
        let ps = p.to_string_lossy().to_lowercase().replace('/', "\\");
        let cs = c.to_string_lossy().to_lowercase().replace('/', "\\");
        let ps = ps.trim_end_matches('\\').to_string();
        cs == ps || cs.starts_with(&format!("{ps}\\"))
    } else {
        c.starts_with(&p)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn within() {
        let base = if cfg!(windows) { PathBuf::from(r"C:\Proj") } else { PathBuf::from("/proj") };
        assert!(is_within(&base, &base.join("a").join("b")));
        assert!(is_within(&base, &base));
        assert!(!is_within(&base, &base.join("..").join("other")));
        if cfg!(windows) {
            assert!(is_within(Path::new(r"C:\Proj"), Path::new(r"c:\proj\x")));
            assert!(!is_within(Path::new(r"C:\Proj"), Path::new(r"C:\Project2\x")));
        }
    }

    #[test]
    fn tilde() {
        let h = PathBuf::from("/home/u");
        assert_eq!(expand_tilde("~/x", &h), h.join("x"));
        assert_eq!(expand_tilde("abc", &h), PathBuf::from("abc"));
    }
}
