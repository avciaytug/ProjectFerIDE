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
    let md = std::fs::metadata(path)?;
    let size = md.len();
    if size > 8 * 1024 * 1024 {
        return Ok(FileContent { path: path.into(), text: None, binary: false, size, too_large: true });
    }
    let bytes = std::fs::read(path)?;
    if crate::util::looks_binary(&bytes) {
        return Ok(FileContent { path: path.into(), text: None, binary: true, size, too_large: false });
    }
    let text = String::from_utf8(bytes).unwrap_or_else(|e| String::from_utf8_lossy(e.as_bytes()).into_owned());
    Ok(FileContent { path: path.into(), text: Some(text), binary: false, size, too_large: false })
}

pub fn write_text(path: &Path, text: &str) -> anyhow::Result<()> {
    crate::util::write_atomic(path, text.as_bytes())
}

pub fn create(path: &Path, dir: bool) -> anyhow::Result<()> {
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
    if to.exists() {
        anyhow::bail!("hedef zaten var: {}", to.display());
    }
    std::fs::rename(from, to)?;
    Ok(())
}

/// Silinen dosya/klasör FerIDE çöp kutusuna taşınır (geri alınabilir).
pub fn trash(path: &Path, trash_dir: &Path) -> anyhow::Result<PathBuf> {
    let stamp = chrono::Local::now().format("%Y%m%d-%H%M%S").to_string();
    let name = path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_else(|| "dosya".into());
    let dest = trash_dir.join(format!("{stamp}-{name}"));
    std::fs::create_dir_all(trash_dir)?;
    if std::fs::rename(path, &dest).is_err() {
        // Farklı diskteyse kopyala + sil.
        if path.is_dir() {
            copy_dir(path, &dest)?;
            std::fs::remove_dir_all(path)?;
        } else {
            std::fs::copy(path, &dest)?;
            std::fs::remove_file(path)?;
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
