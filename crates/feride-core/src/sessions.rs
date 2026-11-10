//! Sohbet oturumları.
//!
//! `sessions/<id>/meta.json`       başlık, çalışma alanı, model, zamanlar
//! `sessions/<id>/messages.jsonl`  salt-ekleme mesaj günlüğü (çökmede kayıp olmaz)
//! `sessions/<id>/todos.json`      ajanın yapılacaklar listesi
//! `sessions/<id>/checkpoints/<tur>/` ajanın değiştirdiği dosyaların önceki halleri

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

#[derive(Clone, Debug, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct SessionMeta {
    pub id: String,
    pub title: String,
    pub created_at: String,
    pub updated_at: String,
    pub workspace: Option<PathBuf>,
    pub model: Option<String>,
    pub message_count: usize,
    pub turns: u32,
    pub pinned: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Todo {
    pub content: String,
    /// pending | in_progress | completed
    pub status: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct CheckpointEntry {
    path: PathBuf,
    /// Önceki içeriğin yedeği; yoksa dosya ajan tarafından oluşturulmuştur.
    backup: Option<String>,
}

pub struct Sessions {
    root: PathBuf,
    lock: Mutex<()>,
}

pub fn valid_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 64 && id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
}

impl Sessions {
    pub fn new(root: PathBuf) -> Self {
        let _ = std::fs::create_dir_all(&root);
        Self { root, lock: Mutex::new(()) }
    }

    fn dir(&self, id: &str) -> anyhow::Result<PathBuf> {
        if !valid_id(id) {
            anyhow::bail!("geçersiz oturum kimliği");
        }
        Ok(self.root.join(id))
    }

    pub fn create(&self, workspace: Option<PathBuf>, model: Option<String>) -> anyhow::Result<SessionMeta> {
        let id = format!("{}-{}", chrono::Local::now().format("%Y%m%d-%H%M%S"), &uuid::Uuid::new_v4().simple().to_string()[..6]);
        let now = crate::util::now_iso();
        let meta = SessionMeta {
            id: id.clone(),
            title: "Yeni sohbet".into(),
            created_at: now.clone(),
            updated_at: now,
            workspace,
            model,
            ..Default::default()
        };
        std::fs::create_dir_all(self.dir(&id)?)?;
        self.save_meta(&meta)?;
        Ok(meta)
    }

    pub fn save_meta(&self, meta: &SessionMeta) -> anyhow::Result<()> {
        let d = self.dir(&meta.id)?;
        crate::util::write_atomic(&d.join("meta.json"), &serde_json::to_vec_pretty(meta)?)
    }

    pub fn meta(&self, id: &str) -> anyhow::Result<SessionMeta> {
        let d = self.dir(id)?;
        Ok(serde_json::from_slice(&std::fs::read(d.join("meta.json"))?)?)
    }

    pub fn list(&self) -> Vec<SessionMeta> {
        let mut v: Vec<SessionMeta> = std::fs::read_dir(&self.root)
            .into_iter()
            .flatten()
            .flatten()
            .filter_map(|e| std::fs::read(e.path().join("meta.json")).ok())
            .filter_map(|b| serde_json::from_slice(&b).ok())
            .collect();
        v.sort_by(|a, b| (b.pinned, &b.updated_at).cmp(&(a.pinned, &a.updated_at)));
        v
    }

    pub fn append(&self, id: &str, msg: &Value) -> anyhow::Result<()> {
        let _g = self.lock.lock().unwrap();
        let d = self.dir(id)?;
        let mut f = std::fs::OpenOptions::new().create(true).append(true).open(d.join("messages.jsonl"))?;
        let mut line = serde_json::to_vec(msg)?;
        line.push(b'\n');
        f.write_all(&line)?;
        Ok(())
    }

    pub fn messages(&self, id: &str) -> anyhow::Result<Vec<Value>> {
        let d = self.dir(id)?;
        let text = std::fs::read_to_string(d.join("messages.jsonl")).unwrap_or_default();
        // Yarım yazılmış son satır (çökme) sessizce atlanır.
        Ok(text.lines().filter_map(|l| serde_json::from_str(l).ok()).collect())
    }

    /// Mesaj listesini baştan yazar (bağlam sıkıştırma, düzenleme sonrası).
    pub fn rewrite(&self, id: &str, msgs: &[Value]) -> anyhow::Result<()> {
        let _g = self.lock.lock().unwrap();
        let d = self.dir(id)?;
        let mut buf = Vec::new();
        for m in msgs {
            buf.extend(serde_json::to_vec(m)?);
            buf.push(b'\n');
        }
        crate::util::write_atomic(&d.join("messages.jsonl"), &buf)
    }

    pub fn touch(&self, id: &str, f: impl FnOnce(&mut SessionMeta)) -> anyhow::Result<SessionMeta> {
        let mut m = self.meta(id)?;
        f(&mut m);
        m.updated_at = crate::util::now_iso();
        self.save_meta(&m)?;
        Ok(m)
    }

    pub fn delete(&self, id: &str, trash: &Path) -> anyhow::Result<()> {
        let d = self.dir(id)?;
        let dest = trash.join(format!("sohbet-{id}"));
        let _ = std::fs::remove_dir_all(&dest);
        std::fs::rename(&d, &dest).or_else(|_| std::fs::remove_dir_all(&d))?;
        Ok(())
    }

    pub fn todos(&self, id: &str) -> Vec<Todo> {
        self.dir(id)
            .ok()
            .and_then(|d| std::fs::read(d.join("todos.json")).ok())
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default()
    }

    pub fn set_todos(&self, id: &str, todos: &[Todo]) -> anyhow::Result<()> {
        let d = self.dir(id)?;
        crate::util::write_atomic(&d.join("todos.json"), &serde_json::to_vec_pretty(todos)?)
    }

    /// Markdown dışa aktarım.
    pub fn export_markdown(&self, id: &str) -> anyhow::Result<String> {
        let meta = self.meta(id)?;
        let mut out = format!("# {}\n\n_{}_\n\n", meta.title, meta.created_at);
        for m in self.messages(id)? {
            let role = m["role"].as_str().unwrap_or("");
            let content = content_text(&m["content"]);
            match role {
                "user" => out.push_str(&format!("## Siz\n\n{content}\n\n")),
                "assistant" => {
                    if !content.trim().is_empty() {
                        out.push_str(&format!("## Feride\n\n{content}\n\n"));
                    }
                    if let Some(tc) = m["tool_calls"].as_array() {
                        for c in tc {
                            out.push_str(&format!(
                                "> araç: `{}` {}\n\n",
                                c["function"]["name"].as_str().unwrap_or(""),
                                crate::util::truncate_end(c["function"]["arguments"].as_str().unwrap_or(""), 200)
                            ));
                        }
                    }
                }
                _ => {}
            }
        }
        Ok(out)
    }

    // ------------------------------------------------------------- kontrol noktaları

    /// Ajan bir dosyayı değiştirmeden önce çağrılır; dosyanın o turdaki ilk halini saklar.
    pub fn checkpoint_file(&self, id: &str, turn: u32, path: &Path) -> anyhow::Result<()> {
        let _g = self.lock.lock().unwrap();
        let cp = self.dir(id)?.join("checkpoints").join(turn.to_string());
        std::fs::create_dir_all(cp.join("files"))?;
        let manifest_path = cp.join("manifest.json");
        let mut entries: Vec<CheckpointEntry> = std::fs::read(&manifest_path)
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default();
        if entries.iter().any(|e| e.path == path) {
            return Ok(());
        }
        let backup = if path.is_file() {
            let name = format!("{}", entries.len());
            std::fs::copy(path, cp.join("files").join(&name))?;
            Some(name)
        } else {
            None
        };
        entries.push(CheckpointEntry { path: path.to_path_buf(), backup });
        crate::util::write_atomic(&manifest_path, &serde_json::to_vec_pretty(&entries)?)
    }

    /// Kontrol noktası olan turlar ve değişen dosyalar.
    pub fn checkpoints(&self, id: &str) -> Vec<(u32, Vec<PathBuf>)> {
        let Ok(d) = self.dir(id) else { return vec![] };
        let mut v: Vec<(u32, Vec<PathBuf>)> = std::fs::read_dir(d.join("checkpoints"))
            .into_iter()
            .flatten()
            .flatten()
            .filter_map(|e| {
                let turn: u32 = e.file_name().to_string_lossy().parse().ok()?;
                let entries: Vec<CheckpointEntry> =
                    serde_json::from_slice(&std::fs::read(e.path().join("manifest.json")).ok()?).ok()?;
                Some((turn, entries.into_iter().map(|e| e.path).collect()))
            })
            .collect();
        v.sort_by_key(|x| x.0);
        v
    }

    /// Belirtilen turdan itibaren ajanın yaptığı tüm dosya değişikliklerini geri alır.
    pub fn revert_from(&self, id: &str, turn: u32) -> anyhow::Result<Vec<PathBuf>> {
        let d = self.dir(id)?;
        let mut restored = vec![];
        let mut turns: Vec<u32> = self.checkpoints(id).into_iter().map(|x| x.0).filter(|t| *t >= turn).collect();
        turns.sort_unstable_by(|a, b| b.cmp(a)); // en yeniden eskiye
        for t in turns {
            let cp = d.join("checkpoints").join(t.to_string());
            let entries: Vec<CheckpointEntry> = serde_json::from_slice(&std::fs::read(cp.join("manifest.json"))?)?;
            for e in entries.iter().rev() {
                match &e.backup {
                    Some(b) => {
                        if let Some(p) = e.path.parent() {
                            std::fs::create_dir_all(p)?;
                        }
                        std::fs::copy(cp.join("files").join(b), &e.path)?;
                    }
                    None => {
                        let _ = std::fs::remove_file(&e.path);
                    }
                }
                restored.push(e.path.clone());
            }
            std::fs::remove_dir_all(&cp)?;
        }
        restored.sort();
        restored.dedup();
        Ok(restored)
    }
}

/// Mesaj içeriğini düz metne çevirir (çok parçalı içerikte metin parçaları).
pub fn content_text(c: &Value) -> String {
    match c {
        Value::String(s) => s.clone(),
        Value::Array(parts) => parts
            .iter()
            .filter_map(|p| if p["type"] == "text" { p["text"].as_str().map(String::from) } else { Some("[görsel]".into()) })
            .collect::<Vec<_>>()
            .join("\n"),
        _ => String::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn append_and_checkpoints() {
        let dir = tempfile::tempdir().unwrap();
        let s = Sessions::new(dir.path().join("sessions"));
        let m = s.create(None, None).unwrap();
        s.append(&m.id, &json!({"role": "user", "content": "selam"})).unwrap();
        s.append(&m.id, &json!({"role": "assistant", "content": "merhaba"})).unwrap();
        assert_eq!(s.messages(&m.id).unwrap().len(), 2);

        let f = dir.path().join("a.txt");
        std::fs::write(&f, "eski").unwrap();
        let newf = dir.path().join("yeni.txt");
        s.checkpoint_file(&m.id, 1, &f).unwrap();
        s.checkpoint_file(&m.id, 1, &newf).unwrap();
        std::fs::write(&f, "değişti").unwrap();
        std::fs::write(&newf, "oluşturuldu").unwrap();
        s.checkpoint_file(&m.id, 2, &f).unwrap();
        std::fs::write(&f, "yine değişti").unwrap();

        let restored = s.revert_from(&m.id, 1).unwrap();
        assert_eq!(restored.len(), 2);
        assert_eq!(std::fs::read_to_string(&f).unwrap(), "eski");
        assert!(!newf.exists());
        assert!(s.checkpoints(&m.id).is_empty());
    }

    #[test]
    fn rejects_bad_ids() {
        let dir = tempfile::tempdir().unwrap();
        let s = Sessions::new(dir.path().to_path_buf());
        assert!(s.meta("../../etc").is_err());
        assert!(s.messages("a/b").is_err());
    }
}
