//! Aegis hafıza: ajanın kalıcı olarak hatırladıkları (SQLite + FTS5 tam metin arama).
//!
//! v5.3.8'deki `aegis/memory.db` içindeki deneyimler ilk açılışta taşınır.

use rusqlite::{params, Connection};
use serde::Serialize;
use std::path::Path;
use std::sync::Mutex;

#[derive(Clone, Debug, Serialize)]
pub struct Memory {
    pub id: i64,
    /// fact | preference | experience | project
    pub kind: String,
    pub content: String,
    pub tags: String,
    pub created_at: String,
    pub use_count: i64,
}

pub struct MemoryStore {
    conn: Mutex<Connection>,
}

impl MemoryStore {
    pub fn open(path: &Path) -> anyhow::Result<Self> {
        let conn = Connection::open(path)?;
        conn.execute_batch(
            "PRAGMA journal_mode=WAL;
             PRAGMA busy_timeout=3000;
             CREATE TABLE IF NOT EXISTS memories (
               id INTEGER PRIMARY KEY AUTOINCREMENT,
               kind TEXT NOT NULL DEFAULT 'fact',
               content TEXT NOT NULL,
               tags TEXT NOT NULL DEFAULT '',
               created_at TEXT NOT NULL,
               use_count INTEGER NOT NULL DEFAULT 0
             );
             CREATE VIRTUAL TABLE IF NOT EXISTS memories_fts USING fts5(
               content, tags, content='memories', content_rowid='id', tokenize='unicode61 remove_diacritics 2'
             );
             CREATE TRIGGER IF NOT EXISTS memories_ai AFTER INSERT ON memories BEGIN
               INSERT INTO memories_fts(rowid, content, tags) VALUES (new.id, new.content, new.tags);
             END;
             CREATE TRIGGER IF NOT EXISTS memories_ad AFTER DELETE ON memories BEGIN
               INSERT INTO memories_fts(memories_fts, rowid, content, tags) VALUES ('delete', old.id, old.content, old.tags);
             END;
             CREATE TRIGGER IF NOT EXISTS memories_au AFTER UPDATE ON memories BEGIN
               INSERT INTO memories_fts(memories_fts, rowid, content, tags) VALUES ('delete', old.id, old.content, old.tags);
               INSERT INTO memories_fts(rowid, content, tags) VALUES (new.id, new.content, new.tags);
             END;
             CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT);",
        )?;
        Ok(Self { conn: Mutex::new(conn) })
    }

    /// v5.3.8 deneyimlerini bir kez taşır.
    pub fn migrate_legacy(&self, legacy: &Path) {
        if !legacy.is_file() {
            return;
        }
        let c = self.conn.lock().unwrap();
        let done: Option<String> = c.query_row("SELECT v FROM meta WHERE k='legacy_migrated'", [], |r| r.get(0)).ok();
        if done.is_some() {
            return;
        }
        let res = (|| -> anyhow::Result<usize> {
            let old = Connection::open_with_flags(legacy, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)?;
            let mut st = old.prepare("SELECT summary, tools_used, result, created_at FROM experiences")?;
            let rows = st.query_map([], |r| {
                Ok((
                    r.get::<_, Option<String>>(0)?.unwrap_or_default(),
                    r.get::<_, Option<String>>(1)?.unwrap_or_default(),
                    r.get::<_, Option<String>>(2)?.unwrap_or_default(),
                    r.get::<_, Option<String>>(3)?.unwrap_or_default(),
                ))
            })?;
            let mut n = 0;
            for row in rows.flatten() {
                let (summary, tools, result, created) = row;
                if summary.trim().is_empty() {
                    continue;
                }
                let content = if result.trim().is_empty() { summary } else { format!("{summary}\nSonuç: {result}") };
                c.execute(
                    "INSERT INTO memories(kind, content, tags, created_at) VALUES ('experience', ?1, ?2, ?3)",
                    params![content, tools, if created.is_empty() { crate::util::now_iso() } else { created }],
                )?;
                n += 1;
            }
            Ok(n)
        })();
        match res {
            Ok(n) => tracing::info!("v5.3.8 hafızasından {n} kayıt taşındı"),
            Err(e) => tracing::warn!("eski hafıza taşınamadı: {e}"),
        }
        let _ = c.execute("INSERT OR REPLACE INTO meta(k, v) VALUES ('legacy_migrated', ?1)", params![crate::util::now_iso()]);
    }

    pub fn add(&self, kind: &str, content: &str, tags: &str) -> anyhow::Result<i64> {
        let kind = match kind {
            "preference" | "experience" | "project" => kind,
            _ => "fact",
        };
        let content = crate::util::truncate_end(content.trim(), 4000);
        if content.is_empty() {
            anyhow::bail!("boş hafıza kaydı");
        }
        let c = self.conn.lock().unwrap();
        // Aynısı varsa tekrar ekleme.
        if let Ok(id) = c.query_row("SELECT id FROM memories WHERE content = ?1", params![content], |r| r.get::<_, i64>(0)) {
            return Ok(id);
        }
        c.execute(
            "INSERT INTO memories(kind, content, tags, created_at) VALUES (?1, ?2, ?3, ?4)",
            params![kind, content, tags, crate::util::now_iso()],
        )?;
        Ok(c.last_insert_rowid())
    }

    /// Tam metin arama; sorgudaki kelimeler VEYA ile birleştirilir (FTS sözdizimi kaçışlanır).
    pub fn search(&self, query: &str, limit: usize) -> Vec<Memory> {
        let terms: Vec<String> = query
            .split(|c: char| !c.is_alphanumeric())
            .filter(|w| w.chars().count() >= 3)
            .take(16)
            .map(|w| format!("\"{}\"", w.replace('"', "")))
            .collect();
        if terms.is_empty() {
            return vec![];
        }
        let q = terms.join(" OR ");
        let c = self.conn.lock().unwrap();
        let Ok(mut st) = c.prepare(
            "SELECT m.id, m.kind, m.content, m.tags, m.created_at, m.use_count FROM memories_fts f
             JOIN memories m ON m.id = f.rowid WHERE memories_fts MATCH ?1 ORDER BY bm25(memories_fts) LIMIT ?2",
        ) else {
            return vec![];
        };
        let rows = st.query_map(params![q, limit as i64], row_to_memory);
        let v: Vec<Memory> = rows.map(|r| r.flatten().collect()).unwrap_or_default();
        for m in &v {
            let _ = c.execute("UPDATE memories SET use_count = use_count + 1 WHERE id = ?1", params![m.id]);
        }
        v
    }

    pub fn list(&self, limit: usize) -> Vec<Memory> {
        let c = self.conn.lock().unwrap();
        let Ok(mut st) = c.prepare("SELECT id, kind, content, tags, created_at, use_count FROM memories ORDER BY id DESC LIMIT ?1") else {
            return vec![];
        };
        st.query_map(params![limit as i64], row_to_memory).map(|r| r.flatten().collect()).unwrap_or_default()
    }

    /// Her istekte sistem talimatına eklenen kalıcı tercihler.
    pub fn preferences(&self, limit: usize) -> Vec<Memory> {
        let c = self.conn.lock().unwrap();
        let Ok(mut st) = c.prepare(
            "SELECT id, kind, content, tags, created_at, use_count FROM memories WHERE kind = 'preference' ORDER BY id DESC LIMIT ?1",
        ) else {
            return vec![];
        };
        st.query_map(params![limit as i64], row_to_memory).map(|r| r.flatten().collect()).unwrap_or_default()
    }

    pub fn delete(&self, id: i64) -> anyhow::Result<()> {
        self.conn.lock().unwrap().execute("DELETE FROM memories WHERE id = ?1", params![id])?;
        Ok(())
    }

    pub fn count(&self) -> i64 {
        self.conn.lock().unwrap().query_row("SELECT COUNT(*) FROM memories", [], |r| r.get(0)).unwrap_or(0)
    }
}

fn row_to_memory(r: &rusqlite::Row) -> rusqlite::Result<Memory> {
    Ok(Memory {
        id: r.get(0)?,
        kind: r.get(1)?,
        content: r.get(2)?,
        tags: r.get(3)?,
        created_at: r.get(4)?,
        use_count: r.get(5)?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn add_search_delete() {
        let dir = tempfile::tempdir().unwrap();
        let m = MemoryStore::open(&dir.path().join("m.db")).unwrap();
        m.add("preference", "Kullanıcı yanıtların Türkçe ve kısa olmasını istiyor", "dil").unwrap();
        let id = m.add("fact", "Proje Rust ile yazılıyor; derleme cargo build", "rust").unwrap();
        m.add("fact", "Proje Rust ile yazılıyor; derleme cargo build", "rust").unwrap(); // tekrar eklenmez
        assert_eq!(m.count(), 2);
        let r = m.search("rust derleme nasıl", 5);
        assert_eq!(r.len(), 1);
        assert_eq!(r[0].id, id);
        // Aksan duyarsız arama: "turkce" → "Türkçe"
        assert_eq!(m.search("turkce yanit", 5).len(), 1);
        assert_eq!(m.preferences(5).len(), 1);
        m.delete(id).unwrap();
        assert!(m.search("rust", 5).is_empty());
        // FTS sözdizimi enjeksiyonu hata vermez.
        assert!(m.search("\"OR NEAR( * ", 5).is_empty());
    }
}
