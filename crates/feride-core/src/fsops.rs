//! Arayüzün dosya işlemleri: gezgin, düzenleyici, arama, git durumu.

use serde::Serialize;
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, Serialize)]
pub struct Entry {
    pub name: String,
    pub path: PathBuf,
    pub is_dir: bool,
    pub size: u64,
    pub hidden: bool,
}

const HEAVY_DIRS: [&str; 8] = ["node_modules", "target", ".git", "build", ".dart_tool", "__pycache__", ".venv", "dist"];

/// Windows'ta dosya adı olarak kullanılamayan aygıt adları: `con`, `prn`, `aux`, `nul`, `com0`–`com9`, `lpt0`–`lpt9`
/// (uzantılı hâlleri de: `nul.txt`).
pub fn is_reserved_name(name: &str) -> bool {
    let stem = name.split('.').next().unwrap_or("").trim_end_matches(' ').to_ascii_lowercase();
    let b = stem.as_bytes();
    matches!(stem.as_str(), "con" | "prn" | "aux" | "nul")
        || (b.len() == 4 && (stem.starts_with("com") || stem.starts_with("lpt")) && b[3].is_ascii_digit())
}

/// Windows'ta dosya işlemleri için "ham" (`\\?\` önekli) yol. Normal yollarda Windows `nul`, `con` gibi adları aygıt
/// olarak yorumlar: Git Bash'te `komut 2>nul` yazınca oluşan `nul` dosyası bu yüzden açılamaz, taşınamaz, silinemez.
/// Ham yol bu yorumu (ve 260 karakter sınırını) kapatır. Göreli ya da zaten önekli yollara ve diğer sistemlere dokunmaz.
pub fn os_path(p: &Path) -> PathBuf {
    #[cfg(windows)]
    {
        use std::ffi::OsString;
        use std::path::{Component, Prefix};
        let mut comps = p.components();
        let mut out = match comps.next() {
            Some(Component::Prefix(pre)) => match pre.kind() {
                Prefix::Disk(d) => OsString::from(format!(r"\\?\{}:", (d as char).to_ascii_uppercase())),
                Prefix::UNC(server, share) => {
                    let mut s = OsString::from(r"\\?\UNC\");
                    s.push(server);
                    s.push(r"\");
                    s.push(share);
                    s
                }
                _ => return p.to_path_buf(),
            },
            _ => return p.to_path_buf(),
        };
        // Ham yolda "." ve ".." çözülmez; burada çözülür.
        let mut parts: Vec<&std::ffi::OsStr> = vec![];
        for c in comps {
            match c {
                Component::Normal(n) => parts.push(n),
                Component::ParentDir => {
                    parts.pop();
                }
                _ => {}
            }
        }
        if parts.is_empty() {
            out.push(r"\");
        }
        for part in parts {
            out.push(r"\");
            out.push(part);
        }
        PathBuf::from(out)
    }
    #[cfg(not(windows))]
    {
        p.to_path_buf()
    }
}

/// Windows'ta aygıt adıyla yeni dosya oluşturulmasını engeller (Windows onu dosya olarak açamaz).
fn check_new_name(path: &Path) -> anyhow::Result<()> {
    let name = path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
    if cfg!(windows) && is_reserved_name(&name) {
        anyhow::bail!("\"{name}\" Windows'ta aygıt adıdır (nul, con, prn, aux, com1, lpt1…); dosya adı olarak kullanılamaz.");
    }
    Ok(())
}

pub fn list_dir(path: &Path) -> anyhow::Result<Vec<Entry>> {
    let mut v: Vec<Entry> = std::fs::read_dir(path)?
        .flatten()
        .map(|e| {
            let md = e.metadata().ok();
            let name = e.file_name().to_string_lossy().to_string();
            Entry {
                hidden: name.starts_with('.') || HEAVY_DIRS.contains(&name.as_str()),
                is_dir: md.as_ref().map(|m| m.is_dir()).unwrap_or(false),
                size: md.map(|m| m.len()).unwrap_or(0),
                path: e.path(),
                name,
            }
        })
        .collect();
    v.sort_by(|a, b| b.is_dir.cmp(&a.is_dir).then(a.name.to_lowercase().cmp(&b.name.to_lowercase())));
    Ok(v)
}

#[derive(Serialize)]
pub struct FileContent {
    pub path: PathBuf,
    pub text: Option<String>,
    pub binary: bool,
    pub size: u64,
    pub too_large: bool,
}

pub fn read_text(path: &Path) -> anyhow::Result<FileContent> {
    let md = std::fs::metadata(os_path(path))?;
    let size = md.len();
    if size > 8 * 1024 * 1024 {
        return Ok(FileContent { path: path.into(), text: None, binary: false, size, too_large: true });
    }
    let bytes = std::fs::read(os_path(path))?;
    if crate::util::looks_binary(&bytes) {
        return Ok(FileContent { path: path.into(), text: None, binary: true, size, too_large: false });
    }
    let text = String::from_utf8(bytes).unwrap_or_else(|e| String::from_utf8_lossy(e.as_bytes()).into_owned());
    Ok(FileContent { path: path.into(), text: Some(text), binary: false, size, too_large: false })
}

pub fn write_text(path: &Path, text: &str) -> anyhow::Result<()> {
    crate::util::write_atomic(&os_path(path), text.as_bytes())
}

pub fn create(path: &Path, dir: bool) -> anyhow::Result<()> {
    check_new_name(path)?;
    if path.exists() {
        anyhow::bail!("zaten var: {}", path.display());
    }
    if dir {
        std::fs::create_dir_all(path)?;
    } else {
        if let Some(p) = path.parent() {
            std::fs::create_dir_all(p)?;
        }
        std::fs::write(path, b"")?;
    }
    Ok(())
}

pub fn rename(from: &Path, to: &Path) -> anyhow::Result<()> {
    check_new_name(to)?;
    if os_path(to).exists() {
        anyhow::bail!("hedef zaten var: {}", to.display());
    }
    std::fs::rename(os_path(from), os_path(to))?;
    Ok(())
}

/// Silinen dosya/klasör FerIDE çöp kutusuna taşınır (geri alınabilir).
pub fn trash(path: &Path, trash_dir: &Path) -> anyhow::Result<PathBuf> {
    let stamp = chrono::Local::now().format("%Y%m%d-%H%M%S").to_string();
    let name = path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_else(|| "dosya".into());
    let dest = trash_dir.join(format!("{stamp}-{name}"));
    std::fs::create_dir_all(trash_dir)?;
    // Ham yol: "nul" gibi aygıt adlı dosyalar da taşınabilsin.
    let (src, dst) = (os_path(path), os_path(&dest));
    if !src.exists() {
        anyhow::bail!("bulunamadı: {}", path.display());
    }
    if std::fs::rename(&src, &dst).is_err() {
        // Farklı diskteyse kopyala + sil.
        if src.is_dir() {
            copy_dir(&src, &dst)?;
            std::fs::remove_dir_all(&src)?;
        } else {
            std::fs::copy(&src, &dst)?;
            std::fs::remove_file(&src)?;
        }
    }
    Ok(dest)
}

fn copy_dir(from: &Path, to: &Path) -> std::io::Result<()> {
    std::fs::create_dir_all(to)?;
    for e in std::fs::read_dir(from)?.flatten() {
        let p = e.path();
        if p.is_dir() {
            copy_dir(&p, &to.join(e.file_name()))?;
        } else {
            std::fs::copy(&p, to.join(e.file_name()))?;
        }
    }
    Ok(())
}

#[derive(Clone, Debug, Serialize)]
pub struct SearchHit {
    pub path: PathBuf,
    pub line: usize,
    pub text: String,
}

/// Çalışma alanında metin/regex arama (.gitignore'a uyar).
pub fn search(root: &Path, query: &str, regex: bool, case_sensitive: bool, include: Option<&str>, limit: usize) -> anyhow::Result<Vec<SearchHit>> {
    let pat = if regex { query.to_string() } else { regex::escape(query) };
    let re = regex::RegexBuilder::new(&pat).case_insensitive(!case_sensitive).size_limit(1 << 22).build()?;
    let glob = match include.filter(|s| !s.trim().is_empty()) {
        Some(g) => Some(globset::Glob::new(g)?.compile_matcher()),
        None => None,
    };
    let mut hits = vec![];
    for e in ignore::WalkBuilder::new(root).hidden(true).git_ignore(true).build().flatten() {
        if hits.len() >= limit {
            break;
        }
        let p = e.path();
        if !p.is_file() {
            continue;
        }
        if let Some(g) = &glob {
            let rel = p.strip_prefix(root).unwrap_or(p);
            if !g.is_match(rel) && !g.is_match(p.file_name().unwrap_or_default()) {
                continue;
            }
        }
        if std::fs::metadata(p).map(|m| m.len() > 4 << 20).unwrap_or(true) {
            continue;
        }
        let Ok(bytes) = std::fs::read(p) else { continue };
        if crate::util::looks_binary(&bytes) {
            continue;
        }
        let text = String::from_utf8_lossy(&bytes);
        for (i, line) in text.lines().enumerate() {
            if re.is_match(line) {
                hits.push(SearchHit { path: p.to_path_buf(), line: i + 1, text: crate::util::truncate_end(line.trim(), 300) });
                if hits.len() >= limit {
                    break;
                }
            }
        }
    }
    Ok(hits)
}

#[derive(Clone, Debug, Serialize, Default)]
pub struct GitStatus {
    pub is_repo: bool,
    pub branch: Option<String>,
    pub ahead: u32,
    pub behind: u32,
    pub changes: Vec<(String, String)>,
}

pub async fn git_status(paths: &crate::paths::Paths, root: &Path) -> GitStatus {
    let mut cmd = crate::proc::command(paths, "git", &["status".into(), "--porcelain=v1".into(), "-b".into(), "-uall".into()]);
    cmd.current_dir(root);
    let Ok((Some(0), out, _, _)) = crate::proc::run_capture(&mut cmd, std::time::Duration::from_secs(10)).await else {
        return GitStatus::default();
    };
    let mut st = GitStatus { is_repo: true, ..Default::default() };
    for line in out.lines() {
        if let Some(b) = line.strip_prefix("## ") {
            let name = b.split("...").next().unwrap_or(b).split(' ').next().unwrap_or("");
            st.branch = Some(name.to_string());
            if let Some(i) = b.find("ahead ") {
                st.ahead = b[i + 6..].split(|c: char| !c.is_ascii_digit()).next().and_then(|n| n.parse().ok()).unwrap_or(0);
            }
            if let Some(i) = b.find("behind ") {
                st.behind = b[i + 7..].split(|c: char| !c.is_ascii_digit()).next().and_then(|n| n.parse().ok()).unwrap_or(0);
            }
        } else if line.len() > 3 {
            st.changes.push((line[..2].trim().to_string(), line[3..].to_string()));
        }
    }
    st
}

/// Arayüzün gösterdiği dosya yolunu doğrular: mutlak olmalı, `..` içermemeli.
pub fn sanitize_ui_path(p: &str) -> anyhow::Result<PathBuf> {
    let pb = PathBuf::from(p);
    if !pb.is_absolute() {
        anyhow::bail!("mutlak yol bekleniyordu: {p}");
    }
    Ok(crate::paths::normalize(&pb))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reserved_names() {
        for n in ["nul", "NUL", "Nul.txt", "con", "prn", "aux", "COM1", "lpt9", "com0", "nul "] {
            assert!(is_reserved_name(n), "{n}");
        }
        for n in ["null", "nul2", "com10", "console", "auxiliary", "annul", "nul_test.txt", "lptx"] {
            assert!(!is_reserved_name(n), "{n}");
        }
    }

    #[cfg(windows)]
    #[test]
    fn os_path_forms() {
        assert_eq!(os_path(Path::new(r"C:\a\b\..\nul")), PathBuf::from(r"\\?\C:\a\nul"));
        assert_eq!(os_path(Path::new("c:/x/./y")), PathBuf::from(r"\\?\C:\x\y"));
        assert_eq!(os_path(Path::new(r"\\srv\share\d\nul")), PathBuf::from(r"\\?\UNC\srv\share\d\nul"));
        assert_eq!(os_path(Path::new(r"\\?\C:\zaten")), PathBuf::from(r"\\?\C:\zaten"));
        assert_eq!(os_path(Path::new("göreli/yol")), PathBuf::from("göreli/yol"));
        assert_eq!(os_path(Path::new(r"C:\")), PathBuf::from(r"\\?\C:\"));
    }

    /// Git Bash'in "2>nul" ile bıraktığı dosya: gezginde açılabilmeli, çöp kutusuna taşınabilmeli.
    #[cfg(windows)]
    #[test]
    fn nul_file_can_be_read_and_trashed() {
        let dir = std::env::temp_dir().join(format!("feride-nul-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let nul = dir.join("nul");
        std::fs::write(os_path(&nul), b"/usr/bin/bash: line 1: wmic: command not found\n").unwrap();
        // Gezginde görünür (listede "nul" adlı dosya).
        assert!(list_dir(&dir).unwrap().iter().any(|e| e.name == "nul" && !e.is_dir));
        // Normal yolla okunamazdı (Windows aygıtı açardı); ham yolla içeriği gelir.
        assert!(read_text(&nul).unwrap().text.unwrap().contains("wmic"));
        // Silme (FerIDE çöp kutusuna taşıma) çalışır ve dosya gerçekten gider.
        let trash_dir = dir.join("cop");
        let moved = trash(&nul, &trash_dir).unwrap();
        assert!(!os_path(&nul).exists());
        assert!(std::fs::read_to_string(&moved).unwrap().contains("wmic"));
        // Bu adla yeni dosya oluşturulamaz ve yeniden adlandırılamaz.
        assert!(create(&dir.join("nul"), false).unwrap_err().to_string().contains("aygıt adı"));
        assert!(rename(&moved, &dir.join("con.txt")).is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn search_and_trash() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("a.rs"), "fn main() {\n  println!(\"Merhaba\");\n}\n").unwrap();
        std::fs::write(dir.path().join("b.txt"), "merhaba dünya").unwrap();
        let h = search(dir.path(), "merhaba", false, false, None, 50).unwrap();
        assert_eq!(h.len(), 2);
        let h = search(dir.path(), "merhaba", false, false, Some("*.rs"), 50).unwrap();
        assert_eq!(h.len(), 1);
        assert_eq!(h[0].line, 2);
        let t = trash(&dir.path().join("b.txt"), &dir.path().join(".trash")).unwrap();
        assert!(t.is_file());
        assert!(!dir.path().join("b.txt").exists());
    }
}
