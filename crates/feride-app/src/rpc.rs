//! Arayüzün çağırdığı yöntemler.

use anyhow::{anyhow, bail, Result};
use serde_json::{json, Value};
use std::path::PathBuf;
use std::sync::Arc;

use feride_core::agent::{self, ApprovalAnswer};
use feride_core::config::ComputeMode;
use feride_core::fsops;
use feride_core::llama::StartRequest;

use crate::server::AppState;

fn p_str<'a>(p: &'a Value, k: &str) -> Result<&'a str> {
    p.get(k).and_then(|v| v.as_str()).ok_or_else(|| anyhow!("'{k}' parametresi eksik"))
}

fn p_path(p: &Value, k: &str) -> Result<PathBuf> {
    fsops::sanitize_ui_path(p_str(p, k)?)
}

const SECRET_KEYS: &[&str] = &["provider_api_key", "hf_token"];

pub async fn handle(st: &AppState, method: &str, p: Value) -> Result<Value> {
    let core = &st.core;
    Ok(match method {
        // ------------------------------------------------------------ uygulama
        "app.info" => {
            let s = core.settings();
            let shell = feride_core::shell::Shell::detect(&core.paths, &s.agent.shell);
            let deps = core.deps.check(&s);
            let needs_setup = deps.iter().any(|d| d.required && !d.installed) || !core.deps.state().first_run_done;
            json!({
                "version": feride_core::VERSION,
                "display_version": feride_core::DISPLAY_VERSION,
                "os": std::env::consts::OS,
                "arch": std::env::consts::ARCH,
                "data_dir": core.paths.data,
                "home": core.paths.home,
                "workspace": core.workspace(),
                "shell": shell.display_name(),
                "needs_setup": needs_setup,
                "desktop": st.desktop,
                "memory_count": core.memory.as_ref().map(|m| m.count()).unwrap_or(0),
                "smart_app_control": feride_core::winsec::smart_app_control(),
            })
        }
        "app.quit" => {
            st.quit.notify_waiters();
            st.quit.notify_one();
            json!(true)
        }
        "app.hardware" => {
            let s = core.settings();
            let server = feride_core::deps::find_llama_server(&core.paths, &s);
            serde_json::to_value(core.llama.hardware(server.as_deref(), p["fresh"].as_bool().unwrap_or(false)).await)?
        }
        "app.open_path" => {
            let path = p_str(&p, "path")?;
            let target = match path {
                "data" => core.paths.data.clone(),
                "logs" => core.paths.logs(),
                "skills" => core.paths.skills(),
                "models" => core.paths.models(),
                other => fsops::sanitize_ui_path(other)?,
            };
            open::that_detached(&target)?;
            json!(true)
        }
        "app.install_info" => {
            let info = crate::installer::running_info();
            json!({
                "installed": info.is_some(),
                "info": info,
                "exe_dir": feride_core::install::current_exe_dir(),
                "data_dir": core.paths.data,
            })
        }
        "app.data_size" => {
            let d = core.paths.data.clone();
            json!(tokio::task::spawn_blocking(move || feride_core::install::dir_size(&d)).await?)
        }
        "app.uninstall" => {
            if crate::installer::running_info().is_none() {
                bail!("Bu FerIDE kurulmadan (taşınabilir) çalışıyor; kaldırmak için klasörünü silmeniz yeterli.");
            }
            crate::installer::spawn_uninstaller(p["purge"].as_bool().unwrap_or(false))?;
            // Yanıt arayüze ulaşsın, sonra kapan: kaldırıcı bu sürecin bitmesini bekliyor.
            let quit = st.quit.clone();
            tokio::spawn(async move {
                tokio::time::sleep(std::time::Duration::from_millis(500)).await;
                quit.notify_waiters();
                quit.notify_one();
            });
            json!(true)
        }
        "app.open_security" => {
            feride_core::winsec::open_security_settings()?;
            json!(true)
        }
        "app.open_url" => {
            let u = p_str(&p, "url")?;
            if !(u.starts_with("https://") || u.starts_with("http://")) {
                bail!("yalnızca web adresleri açılabilir");
            }
            open::that_detached(u)?;
            json!(true)
        }

        // ------------------------------------------------------------ ayarlar
        "settings.get" => {
            let s = core.settings();
            let secrets: Vec<&str> = SECRET_KEYS.iter().copied().filter(|k| core.secrets.is_set(k)).collect();
            json!({"settings": s, "secrets_set": secrets})
        }
        "settings.set" => serde_json::to_value(core.update_settings(&p["patch"])?)?,
        "secrets.set" => {
            let key = p_str(&p, "key")?;
            if !SECRET_KEYS.contains(&key) {
                bail!("bilinmeyen sır anahtarı");
            }
            core.secrets.set(key, p["value"].as_str())?;
            json!(true)
        }

        // ------------------------------------------------------------ kurulum
        "setup.status" => {
            let s = core.settings();
            json!({
                "deps": core.deps.check(&s),
                "state": core.deps.state(),
                "smart_app_control": feride_core::winsec::smart_app_control(),
                "sac_help": feride_core::winsec::SAC_HELP,
            })
        }
        "setup.install" => {
            let ids: Vec<String> = serde_json::from_value(p["ids"].clone()).unwrap_or_default();
            let force = p["force"].as_bool().unwrap_or(false);
            let c = Arc::clone(core);
            tokio::spawn(async move {
                let s = c.settings();
                let results = c.deps.install_selected(&s, &ids, force).await;
                let list: Vec<Value> = results
                    .into_iter()
                    .map(|(id, r)| match r {
                        Ok(m) => json!({"id": id, "ok": true, "message": m}),
                        Err(e) => json!({"id": id, "ok": false, "message": e}),
                    })
                    .collect();
                c.events.emit("setup.finished", json!({"results": list}));
            });
            json!({"started": true})
        }
        "setup.skip" => {
            core.deps.update_state(|s| s.first_run_done = true);
            json!(true)
        }

        // ------------------------------------------------------------ dosyalar
        "fs.pick_folder" => {
            #[cfg(feature = "desktop")]
            {
                let picked = rfd::AsyncFileDialog::new().set_title("Çalışma klasörü seçin").pick_folder().await;
                json!(picked.map(|f| f.path().to_path_buf()))
            }
            #[cfg(not(feature = "desktop"))]
            {
                json!(null)
            }
        }
        "fs.pick_files" => {
            #[cfg(feature = "desktop")]
            {
                let picked = rfd::AsyncFileDialog::new().set_title("Dosya seçin").pick_files().await;
                json!(picked.map(|v| v.iter().map(|f| f.path().to_path_buf()).collect::<Vec<_>>()))
            }
            #[cfg(not(feature = "desktop"))]
            {
                json!(null)
            }
        }
        "fs.open_workspace" => serde_json::to_value(core.set_workspace(p_path(&p, "path")?)?)?,
        "fs.list" => serde_json::to_value(fsops::list_dir(&p_path(&p, "path")?)?)?,
        "fs.read" => serde_json::to_value(fsops::read_text(&p_path(&p, "path")?)?)?,
        "fs.read_base64" => {
            use base64::Engine;
            let path = p_path(&p, "path")?;
            let md = std::fs::metadata(&path)?;
            if md.len() > 25 << 20 {
                bail!("dosya çok büyük");
            }
            let b = std::fs::read(&path)?;
            let mime = mime_guess::from_path(&path).first_or_octet_stream().to_string();
            json!({"mime": mime, "data": base64::engine::general_purpose::STANDARD.encode(b)})
        }
        "fs.write" => {
            fsops::write_text(&p_path(&p, "path")?, p_str(&p, "text")?)?;
            json!(true)
        }
        "fs.create" => {
            fsops::create(&p_path(&p, "path")?, p["dir"].as_bool().unwrap_or(false))?;
            json!(true)
        }
        "fs.rename" => {
            fsops::rename(&p_path(&p, "from")?, &p_path(&p, "to")?)?;
            json!(true)
        }
        "fs.delete" => json!(fsops::trash(&p_path(&p, "path")?, &core.paths.trash())?),
        "fs.git_status" => {
            let root = match p["root"].as_str() {
                Some(r) if !r.is_empty() => fsops::sanitize_ui_path(r)?,
                _ => core.workspace(),
            };
            serde_json::to_value(fsops::git_status(&core.paths, &root).await)?
        }

        // ------------------------------------------------------------ modeller
        "models.list" => {
            let s = core.settings();
            let dirs = core.llama.model_dirs(&s);
            let models = tokio::task::spawn_blocking(move || feride_core::llama::scan_models(&dirs)).await?;
            json!({"models": models, "selected": s.model.selected, "status": core.llama.status(), "dirs": core.llama.model_dirs(&s)})
        }
        "models.status" => serde_json::to_value(core.llama.status())?,
        "models.logs" => json!(core.llama.logs()),
        "models.plan" => {
            let s = core.settings();
            let req = start_request(&p, &s)?;
            let (plan, info, hw) = core.llama.preview_plan(&s, &req).await?;
            json!({"plan": plan, "info": info, "hardware": hw})
        }
        "models.start" => {
            let s = core.settings();
            let req = start_request(&p, &s)?;
            core.update_settings(&json!({"model": {"selected": req.model}}))?;
            let c = Arc::clone(core);
            tokio::spawn(async move {
                let s = c.settings();
                let _ = c.llama.start(&s, req).await;
            });
            json!({"started": true})
        }
        "models.stop" => {
            core.llama.stop().await;
            json!(true)
        }
        "models.delete" => {
            let path = p_path(&p, "path")?;
            let s = core.settings();
            if !core.llama.model_dirs(&s).iter().any(|d| feride_core::paths::is_within(d, &path)) {
                bail!("yalnızca model klasöründeki dosyalar silinebilir");
            }
            if core.llama.status().model_path.as_deref() == Some(path.as_path()) {
                core.llama.stop().await;
            }
            for part in feride_core::gguf::split_parts(&path) {
                let _ = std::fs::remove_file(part);
            }
            core.events.emit("models.changed", json!({}));
            json!(true)
        }
        "hub.search" => serde_json::to_value(core.hub.search(p_str(&p, "query")?, core.secrets.get("hf_token").as_deref()).await?)?,
        "hub.files" => serde_json::to_value(core.hub.files(p_str(&p, "repo")?, core.secrets.get("hf_token").as_deref()).await?)?,
        "hub.download" => {
            let parts: Vec<String> = serde_json::from_value(p["parts"].clone()).unwrap_or_default();
            let id = core.hub.start_download(
                p_str(&p, "repo")?,
                p_str(&p, "file")?,
                parts,
                p["mmproj_for"].as_str().map(String::from),
                core.secrets.get("hf_token"),
            )?;
            json!({"id": id})
        }
        "hub.downloads" => serde_json::to_value(core.hub.list_downloads())?,
        "hub.cancel" => json!(core.hub.cancel(p_str(&p, "id")?)),

        // ------------------------------------------------------------ sohbet / ajan
        "chat.sessions" => {
            let running: Vec<String> = core.runs.lock().unwrap().keys().cloned().collect();
            json!({"sessions": core.sessions.list(), "running": running})
        }
        "chat.load" => {
            let id = p_str(&p, "id")?;
            let cps: Vec<Value> = core.sessions.checkpoints(id).into_iter().map(|(t, f)| json!({"turn": t, "files": f})).collect();
            json!({
                "meta": core.sessions.meta(id)?,
                "messages": core.sessions.messages(id)?,
                "todos": core.sessions.todos(id),
                "checkpoints": cps,
                "running": core.runs.lock().unwrap().contains_key(id),
            })
        }
        "chat.new" => {
            let ws = core.workspace();
            let s = core.settings();
            serde_json::to_value(core.sessions.create(Some(ws), s.model.selected.as_ref().map(|m| feride_core::gguf::base_name(m)))?)?
        }
        "chat.send" => {
            let text = p_str(&p, "text")?.to_string();
            if text.trim().is_empty() {
                bail!("boş mesaj");
            }
            let images: Vec<String> = serde_json::from_value(p["images"].clone()).unwrap_or_default();
            let voice = p["voice"].as_bool().unwrap_or(false);
            let sid = agent::start(core, p["session"].as_str().map(String::from), text, images, voice)?;
            json!({"session": sid})
        }
        "chat.stop" => json!(agent::stop(core, p_str(&p, "session")?)),
        "chat.prewarm" => {
            let c = Arc::clone(core);
            let sid = p["session"].as_str().map(String::from);
            let voice = p["voice"].as_bool().unwrap_or(false);
            tokio::spawn(async move { agent::prewarm(&c, sid, voice).await });
            json!(true)
        }
        "chat.approve" => {
            let answer = match p_str(&p, "answer")? {
                "allow" => ApprovalAnswer::Allow,
                "session" => ApprovalAnswer::AllowSession,
                _ => ApprovalAnswer::Deny(p["message"].as_str().map(String::from)),
            };
            json!(agent::answer_approval(core, p_str(&p, "session")?, p_str(&p, "id")?, answer))
        }
        "chat.delete" => {
            let id = p_str(&p, "id")?;
            agent::stop(core, id);
            core.sessions.delete(id, &core.paths.trash())?;
            json!(true)
        }
        "chat.rename" => serde_json::to_value(core.sessions.touch(p_str(&p, "id")?, |m| {
            m.title = feride_core::util::truncate_end(p["title"].as_str().unwrap_or("Sohbet"), 80)
        })?)?,
        "chat.pin" => serde_json::to_value(core.sessions.touch(p_str(&p, "id")?, |m| m.pinned = p["pinned"].as_bool().unwrap_or(false))?)?,
        "chat.export" => json!(core.sessions.export_markdown(p_str(&p, "id")?)?),
        "chat.revert" => {
            let id = p_str(&p, "id")?;
            if core.runs.lock().unwrap().contains_key(id) {
                bail!("Ajan çalışırken geri alınamaz; önce durdurun.");
            }
            let turn = p["turn"].as_u64().ok_or_else(|| anyhow!("turn eksik"))? as u32;
            json!(core.sessions.revert_from(id, turn)?)
        }

        // ------------------------------------------------------------ MCP / skill / hafıza
        "mcp.list" => json!({"servers": core.mcp.statuses(), "tools": core.mcp.tools()}),
        "mcp.config_get" => serde_json::to_value(core.mcp.load_config())?,
        "mcp.config_set" => {
            let cfg: feride_core::mcp::McpConfig = serde_json::from_value(p["config"].clone())?;
            core.mcp.save_config(&cfg)?;
            core.mcp.stop_all();
            core.mcp.start_all();
            json!(true)
        }
        "mcp.restart" => {
            core.mcp.restart(p_str(&p, "name")?).await?;
            json!(true)
        }
        "mcp.toggle" => {
            let name = p_str(&p, "name")?;
            let mut cfg = core.mcp.load_config();
            let enabled = p["enabled"].as_bool().unwrap_or(true);
            cfg.servers.get_mut(name).ok_or_else(|| anyhow!("sunucu yok"))?.disabled = !enabled;
            core.mcp.save_config(&cfg)?;
            if enabled {
                let _ = core.mcp.restart(name).await;
            } else {
                core.mcp.stop(name);
            }
            json!(true)
        }
        "skills.list" => serde_json::to_value(core.skills())?,
        "skills.read" => {
            let name = p_str(&p, "name")?;
            let sk = core.skills().into_iter().find(|s| s.name == name).ok_or_else(|| anyhow!("skill yok"))?;
            json!(std::fs::read_to_string(sk.dir.join("SKILL.md"))?)
        }
        "skills.toggle" => {
            let name = p_str(&p, "name")?.to_string();
            let mut disabled = core.settings().disabled_skills;
            disabled.retain(|n| n != &name);
            if !p["enabled"].as_bool().unwrap_or(true) {
                disabled.push(name);
            }
            core.update_settings(&json!({"disabled_skills": disabled}))?;
            json!(true)
        }
        "memory.list" => json!(core.memory.as_ref().map(|m| m.list(500)).unwrap_or_default()),
        "memory.add" => json!(core.memory.as_ref().ok_or_else(|| anyhow!("hafıza yok"))?.add(
            p["kind"].as_str().unwrap_or("fact"),
            p_str(&p, "content")?,
            p["tags"].as_str().unwrap_or("")
        )?),
        "memory.delete" => {
            core.memory.as_ref().ok_or_else(|| anyhow!("hafıza yok"))?.delete(p["id"].as_i64().ok_or_else(|| anyhow!("id"))?)?;
            json!(true)
        }

        // ------------------------------------------------------------ terminal / süreçler
        "term.open" => {
            let cwd = match p["cwd"].as_str() {
                Some(c) if !c.is_empty() => fsops::sanitize_ui_path(c)?,
                _ => core.workspace(),
            };
            let s = core.settings();
            json!(core.terminals.open(&cwd, &s.agent.shell, p["cols"].as_u64().unwrap_or(100) as u16, p["rows"].as_u64().unwrap_or(30) as u16)?)
        }
        "term.write" => {
            core.terminals.write(p_str(&p, "id")?, p_str(&p, "data")?)?;
            json!(true)
        }
        "term.resize" => {
            core.terminals.resize(p_str(&p, "id")?, p["cols"].as_u64().unwrap_or(100) as u16, p["rows"].as_u64().unwrap_or(30) as u16)?;
            json!(true)
        }
        "term.close" => {
            core.terminals.close(p_str(&p, "id")?);
            json!(true)
        }
        "proc.list" => json!(core.background.list()),
        "proc.kill" => json!(core.background.kill(p_str(&p, "id")?)),

        // ------------------------------------------------------------ ses
        "voice.status" => serde_json::to_value(core.voice.status())?,
        "voice.warmup" => {
            core.voice.warmup().await?;
            serde_json::to_value(core.voice.status())?
        }
        "voice.transcribe" => {
            let quality = p["quality"].as_str().map(String::from).unwrap_or_else(|| core.settings().voice.stt_quality);
            let mime = p["mime"].as_str().unwrap_or("audio/webm");
            json!(core.voice.transcribe(p_str(&p, "audio")?, mime, p["vad"].as_bool().unwrap_or(true), &quality).await?)
        }
        "voice.speak" => {
            let s = core.settings();
            json!(core.voice.speak(p_str(&p, "text")?, &s.voice.voice, s.voice.speed).await?)
        }

        other => bail!("bilinmeyen yöntem: {other}"),
    })
}

fn start_request(p: &Value, s: &feride_core::config::Settings) -> Result<StartRequest> {
    let model = match p["model"].as_str() {
        Some(m) => fsops::sanitize_ui_path(m)?,
        None => s.model.selected.clone().ok_or_else(|| anyhow!("model seçilmedi"))?,
    };
    let mode: ComputeMode = match p.get("mode").filter(|m| !m.is_null()) {
        Some(m) => serde_json::from_value(m.clone())?,
        None => s.model.compute_mode,
    };
    let ctx = p["ctx"].as_u64().map(|c| c as u32).unwrap_or(s.model.context);
    Ok(StartRequest { model, mode, ctx })
}
