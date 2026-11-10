//! Skill'ler: `SKILL.md` dosyaları tek doğru kaynaktır (Anthropic Agent Skills biçimi).
//!
//! Aranan yerler: `~/.feride/skills/*/SKILL.md` ve çalışma alanındaki `.feride/skills/*/SKILL.md`.
//! v5.3.8'deki gibi veritabanı kopyası yoktur; dosya değişince bir sonraki istekte görünür.

use serde::Serialize;
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, Serialize)]
pub struct Skill {
    pub name: String,
    pub description: String,
    pub dir: PathBuf,
    pub source: String,
    pub enabled: bool,
}

/// YAML ön bilgisinden `name` ve `description` okur (tırnaklı ve çok satırlı değerler dahil).
pub fn parse_frontmatter(text: &str) -> (Option<String>, Option<String>, String) {
    let t = text.trim_start_matches('\u{feff}');
    let Some(rest) = t.strip_prefix("---") else { return (None, None, t.to_string()) };
    let Some(end) = rest.find("\n---") else { return (None, None, t.to_string()) };
    let fm = &rest[..end];
    let body = rest[end + 4..].trim_start_matches(['\r', '\n', '-']).to_string();
    let mut name = None;
    let mut desc = None;
    let lines: Vec<&str> = fm.lines().collect();
    let mut i = 0;
    while i < lines.len() {
        let line = lines[i];
        if let Some((k, v)) = line.split_once(':') {
            if !line.starts_with(' ') && !line.starts_with('\t') {
                let key = k.trim();
                let mut val = v.trim().to_string();
                if val == "|" || val == ">" || val == "|-" || val == ">-" || val.is_empty() {
                    let mut parts = vec![];
                    i += 1;
                    while i < lines.len() && (lines[i].starts_with(' ') || lines[i].starts_with('\t') || lines[i].trim().is_empty()) {
                        parts.push(lines[i].trim());
                        i += 1;
                    }
                    val = parts.join(" ").trim().to_string();
                    i -= 1;
                }
                let val = val.trim_matches('"').trim_matches('\'').replace("\\\"", "\"").to_string();
                match key {
                    "name" => name = Some(val),
                    "description" => desc = Some(val),
                    _ => {}
                }
            }
        }
        i += 1;
    }
    (name, desc, body)
}

pub fn scan(dirs: &[(PathBuf, &str)], disabled: &[String]) -> Vec<Skill> {
    let mut out: Vec<Skill> = vec![];
    for (dir, source) in dirs {
        let Ok(rd) = std::fs::read_dir(dir) else { continue };
        for e in rd.flatten() {
            let f = e.path().join("SKILL.md");
            let Ok(text) = std::fs::read_to_string(&f) else { continue };
            let (name, desc, _) = parse_frontmatter(&text);
            let name = name.unwrap_or_else(|| e.file_name().to_string_lossy().to_string());
            if out.iter().any(|s| s.name == name) {
                continue; // çalışma alanındaki aynı adlı skill öncelikli (önce taranır)
            }
            out.push(Skill {
                enabled: !disabled.contains(&name),
                name,
                description: desc.unwrap_or_default(),
                dir: e.path(),
                source: source.to_string(),
            });
        }
    }
    out.sort_by(|a, b| a.name.cmp(&b.name));
    out
}

/// Skill içeriği + klasördeki ek dosyaların listesi (ajan `read_file` ile okuyabilir).
pub fn load(skill: &Skill) -> anyhow::Result<String> {
    let text = std::fs::read_to_string(skill.dir.join("SKILL.md"))?;
    let (_, _, body) = parse_frontmatter(&text);
    let mut extra = vec![];
    for e in ignore::WalkBuilder::new(&skill.dir).max_depth(Some(3)).build().flatten() {
        if e.path().is_file() && e.file_name() != "SKILL.md" {
            if let Ok(rel) = e.path().strip_prefix(&skill.dir) {
                extra.push(rel.to_string_lossy().replace('\\', "/"));
            }
        }
    }
    let mut out = format!("# Skill: {}\nKlasör: {}\n\n{}", skill.name, skill.dir.display(), body.trim());
    if !extra.is_empty() {
        out.push_str("\n\n## Ek dosyalar (gerekirse read_file ile oku)\n");
        for x in extra.iter().take(40) {
            out.push_str(&format!("- {}\n", skill.dir.join(x).display()));
        }
    }
    Ok(out)
}

/// Ajanın kaydettiği yeni skill.
pub fn save(dir: &Path, name: &str, description: &str, content: &str) -> anyhow::Result<PathBuf> {
    let slug: String = name
        .to_lowercase()
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect::<String>()
        .trim_matches('-')
        .to_string();
    if slug.is_empty() || slug.len() > 64 {
        anyhow::bail!("geçersiz skill adı");
    }
    let d = dir.join(&slug);
    std::fs::create_dir_all(&d)?;
    let desc = description.replace('\n', " ").replace('"', "'");
    let text = format!("---\nname: {slug}\ndescription: \"{desc}\"\n---\n\n{}\n", content.trim());
    crate::util::write_atomic(&d.join("SKILL.md"), text.as_bytes())?;
    Ok(d)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frontmatter_variants() {
        let (n, d, b) = parse_frontmatter("---\nname: tdd\ndescription: \"Test önce: kırmızı, yeşil\"\n---\n# Gövde\n");
        assert_eq!(n.unwrap(), "tdd");
        assert_eq!(d.unwrap(), "Test önce: kırmızı, yeşil");
        assert!(b.starts_with("# Gövde"));
        let (_, d, _) = parse_frontmatter("---\nname: x\ndescription: >\n  çok satırlı\n  açıklama\nlicense: MIT\n---\nx");
        assert_eq!(d.unwrap(), "çok satırlı açıklama");
    }

    #[test]
    fn save_and_scan() {
        let dir = tempfile::tempdir().unwrap();
        save(dir.path(), "Rapor Yaz", "Rapor yazma adımları", "1. Topla\n2. Yaz").unwrap();
        let s = scan(&[(dir.path().to_path_buf(), "kullanıcı")], &[]);
        assert_eq!(s.len(), 1);
        assert_eq!(s[0].name, "rapor-yaz");
        assert!(load(&s[0]).unwrap().contains("2. Yaz"));
    }
}
