//! Gerçek terminal (Windows: ConPTY, Unix: PTY). Çıktı base64 olarak arayüze akar.

use base64::Engine;
use portable_pty::{native_pty_system, CommandBuilder, MasterPty, PtySize};
use serde_json::json;
use std::collections::HashMap;
use std::io::{Read, Write};
use std::path::Path;
use std::sync::{Arc, Mutex};

use crate::events::EventBus;
use crate::paths::Paths;

struct Term {
    master: Box<dyn MasterPty + Send>,
    writer: Box<dyn Write + Send>,
    child: Box<dyn portable_pty::Child + Send + Sync>,
}

pub struct Terminals {
    paths: Paths,
    events: EventBus,
    terms: Mutex<HashMap<String, Arc<Mutex<Term>>>>,
}

impl Terminals {
    pub fn new(paths: Paths, events: EventBus) -> Self {
        Self { paths, events, terms: Mutex::new(HashMap::new()) }
    }

    pub fn open(&self, cwd: &Path, shell_pref: &str, cols: u16, rows: u16) -> anyhow::Result<String> {
        let shell = crate::shell::Shell::detect(&self.paths, shell_pref);
        let pty = native_pty_system();
        let pair = pty.openpty(PtySize { rows: rows.max(5), cols: cols.max(20), pixel_width: 0, pixel_height: 0 })?;
        let mut cmd = CommandBuilder::new(&shell.program);
        for a in shell.interactive_args() {
            cmd.arg(a);
        }
        cmd.cwd(if cwd.is_dir() { cwd.to_path_buf() } else { self.paths.home.clone() });
        cmd.env("PATH", crate::proc::child_path(&self.paths, &[]));
        cmd.env("TERM", "xterm-256color");
        cmd.env("FERIDE", "1");
        if cfg!(windows) {
            cmd.env("CHERE_INVOKING", "1"); // Git Bash: başlangıç klasörünü değiştirme
            cmd.env("MSYS", "enable_pcon");
        }
        let child = pair.slave.spawn_command(cmd)?;
        drop(pair.slave);
        let mut reader = pair.master.try_clone_reader()?;
        let writer = pair.master.take_writer()?;
        let id = uuid::Uuid::new_v4().simple().to_string()[..10].to_string();
        let term = Arc::new(Mutex::new(Term { master: pair.master, writer, child }));
        self.terms.lock().unwrap().insert(id.clone(), term.clone());
        let events = self.events.clone();
        let tid = id.clone();
        std::thread::Builder::new().name(format!("pty-{tid}")).spawn(move || {
            const DSR: &[u8] = b"\x1b[6n";
            let mut buf = [0u8; 16384];
            loop {
                match reader.read(&mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => {
                        let mut chunk = buf[..n].to_vec();
                        // ConPTY açılışta imleç konumu sorar ve yanıt gelene kadar kabuğu bekletir.
                        // Arayüz henüz bağlanmamış olabilir: soruyu burada yanıtla, arayüze iletme.
                        if chunk.windows(DSR.len()).any(|w| w == DSR) {
                            if let Ok(mut t) = term.lock() {
                                let _ = t.writer.write_all(b"\x1b[1;1R");
                                let _ = t.writer.flush();
                            }
                            let mut cleaned = Vec::with_capacity(chunk.len());
                            let mut i = 0;
                            while i < chunk.len() {
                                if chunk[i..].starts_with(DSR) {
                                    i += DSR.len();
                                } else {
                                    cleaned.push(chunk[i]);
                                    i += 1;
                                }
                            }
                            chunk = cleaned;
                        }
                        if chunk.is_empty() {
                            continue;
                        }
                        let data = base64::engine::general_purpose::STANDARD.encode(&chunk);
                        events.emit("term.data", json!({"id": tid, "data": data}));
                    }
                }
            }
            events.emit("term.exit", json!({"id": tid}));
        })?;
        Ok(id)
    }

    fn get(&self, id: &str) -> anyhow::Result<Arc<Mutex<Term>>> {
        self.terms.lock().unwrap().get(id).cloned().ok_or_else(|| anyhow::anyhow!("terminal yok"))
    }

    pub fn write(&self, id: &str, data: &str) -> anyhow::Result<()> {
        let t = self.get(id)?;
        let mut g = t.lock().unwrap();
        g.writer.write_all(data.as_bytes())?;
        g.writer.flush()?;
        Ok(())
    }

    pub fn resize(&self, id: &str, cols: u16, rows: u16) -> anyhow::Result<()> {
        let t = self.get(id)?;
        let g = t.lock().unwrap();
        g.master.resize(PtySize { rows: rows.max(5), cols: cols.max(20), pixel_width: 0, pixel_height: 0 })?;
        Ok(())
    }

    pub fn close(&self, id: &str) {
        if let Some(t) = self.terms.lock().unwrap().remove(id) {
            let _ = t.lock().unwrap().child.kill();
        }
    }

    pub fn close_all(&self) {
        let ids: Vec<String> = self.terms.lock().unwrap().keys().cloned().collect();
        for id in ids {
            self.close(&id);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test(flavor = "multi_thread")]
    async fn pty_roundtrip() {
        let dir = tempfile::tempdir().unwrap();
        let paths = Paths::with_data_dir(dir.path().join("d"));
        let events = EventBus::new();
        let mut rx = events.subscribe();
        let t = Terminals::new(paths, events);
        let id = t.open(dir.path(), "auto", 100, 30).unwrap();
        tokio::time::sleep(std::time::Duration::from_millis(2500)).await;
        t.write(&id, "echo FERIDE_$((6*7))\r").unwrap();
        let mut out = String::new();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(8);
        while std::time::Instant::now() < deadline {
            if let Ok(Ok(ev)) = tokio::time::timeout(std::time::Duration::from_millis(500), rx.recv()).await {
                if ev.topic == "term.data" {
                    let b = base64::engine::general_purpose::STANDARD.decode(ev.data["data"].as_str().unwrap()).unwrap();
                    out.push_str(&String::from_utf8_lossy(&b));
                }
            }
            if out.contains("FERIDE_42") {
                break;
            }
        }
        t.close(&id);
        assert!(out.contains("FERIDE_42"), "çıktı: {out:?}");
    }
}
