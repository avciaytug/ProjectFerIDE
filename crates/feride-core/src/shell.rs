//! Ajan ve terminal için kabuk seçimi.
//!
//! Yerel modeller komutları neredeyse her zaman bash sözdizimiyle yazar. Bu yüzden
//! Windows'ta önce Git Bash aranır (FerIDE'nin kurduğu taşınabilir Git dahil); WSL'nin
//! `System32\bash.exe`'si seçilmez. Bulunamazsa PowerShell kullanılır ve ajan buna göre
//! bilgilendirilir.

use std::path::PathBuf;

use crate::paths::Paths;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ShellKind {
    Bash,
    PowerShell,
    Cmd,
    Sh,
    Zsh,
}

#[derive(Clone, Debug)]
pub struct Shell {
    pub kind: ShellKind,
    pub program: PathBuf,
}

impl Shell {
    pub fn detect(paths: &Paths, preference: &str) -> Shell {
        let pref = preference.to_ascii_lowercase();
        if cfg!(windows) {
            if pref == "auto" || pref == "bash" {
                if let Some(b) = find_git_bash(paths) {
                    return Shell { kind: ShellKind::Bash, program: b };
                }
            }
            if pref == "cmd" {
                return Shell { kind: ShellKind::Cmd, program: PathBuf::from("cmd.exe") };
            }
            let path_var = crate::proc::child_path(paths, &[]);
            let ps = crate::proc::which_in("pwsh", &path_var).unwrap_or_else(|| PathBuf::from("powershell.exe"));
            Shell { kind: ShellKind::PowerShell, program: ps }
        } else {
            let candidates: Vec<(ShellKind, PathBuf)> = match pref.as_str() {
                "sh" => vec![(ShellKind::Sh, "/bin/sh".into())],
                "zsh" => vec![(ShellKind::Zsh, "/bin/zsh".into()), (ShellKind::Bash, "/bin/bash".into())],
                _ => vec![
                    (ShellKind::Bash, "/bin/bash".into()),
                    (ShellKind::Bash, "/usr/bin/bash".into()),
                    (ShellKind::Zsh, "/bin/zsh".into()),
                    (ShellKind::Sh, "/bin/sh".into()),
                ],
            };
            for (k, p) in candidates {
                if p.exists() {
                    return Shell { kind: k, program: p };
                }
            }
            Shell { kind: ShellKind::Sh, program: "/bin/sh".into() }
        }
    }

    /// Tek bir komut satırını çalıştırmak için program + argümanlar.
    pub fn command_args(&self, command: &str) -> (String, Vec<String>) {
        let prog = self.program.to_string_lossy().to_string();
        match self.kind {
            ShellKind::PowerShell => (
                prog,
                vec![
                    "-NoProfile".into(),
                    "-NonInteractive".into(),
                    "-ExecutionPolicy".into(),
                    "Bypass".into(),
                    "-Command".into(),
                    format!(
                        "[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; $ProgressPreference='SilentlyContinue'; {command}"
                    ),
                ],
            ),
            ShellKind::Cmd => (prog, vec!["/D".into(), "/S".into(), "/C".into(), format!("chcp 65001>nul & {command}")]),
            _ => (prog, vec!["-c".into(), command.to_string()]),
        }
    }

    /// Etkileşimli terminal için argümanlar.
    pub fn interactive_args(&self) -> Vec<String> {
        match self.kind {
            ShellKind::Bash => vec!["--login".into(), "-i".into()],
            ShellKind::PowerShell => vec!["-NoLogo".into()],
            _ => vec![],
        }
    }

    pub fn display_name(&self) -> &'static str {
        match self.kind {
            ShellKind::Bash if cfg!(windows) => "Git Bash (bash)",
            ShellKind::Bash => "bash",
            ShellKind::Zsh => "zsh",
            ShellKind::Sh => "sh",
            ShellKind::PowerShell => "PowerShell",
            ShellKind::Cmd => "cmd.exe",
        }
    }

    /// Ajanın sistem talimatına eklenen kısa not.
    pub fn agent_hint(&self) -> String {
        match self.kind {
            ShellKind::Bash if cfg!(windows) => "Komutlar Windows üzerinde Git Bash ile çalışır: bash sözdizimi kullan \
                (ls, grep, cat, &&). Windows yollarını tırnak içinde ve / ile yaz (\"C:/Users/...\"). \
                Windows programları (where, ipconfig, powershell -Command ...) da çağrılabilir."
                .into(),
            ShellKind::PowerShell => "Komutlar PowerShell ile çalışır: bash komutları (grep, cat <<EOF, &&) ÇALIŞMAZ. \
                PowerShell karşılıklarını kullan (Get-ChildItem, Select-String, Get-Content, ; ile ayır)."
                .into(),
            ShellKind::Cmd => "Komutlar cmd.exe ile çalışır.".into(),
            _ => format!("Komutlar {} ile çalışır.", self.display_name()),
        }
    }
}

fn find_git_bash(paths: &Paths) -> Option<PathBuf> {
    let mut c = vec![paths.tools().join("git").join("bin").join("bash.exe")];
    for var in ["ProgramFiles", "ProgramW6432", "LOCALAPPDATA"] {
        if let Some(base) = std::env::var_os(var) {
            let base = PathBuf::from(base);
            c.push(base.join("Git").join("bin").join("bash.exe"));
            c.push(base.join("Programs").join("Git").join("bin").join("bash.exe"));
        }
    }
    // PATH'teki git.exe'den Git kökünü bul (…\Git\cmd\git.exe → …\Git\bin\bash.exe).
    let path_var = crate::proc::child_path(paths, &[]);
    if let Some(git) = crate::proc::which_in("git", &path_var) {
        if let Some(root) = git.parent().and_then(|p| p.parent()) {
            c.push(root.join("bin").join("bash.exe"));
        }
    }
    c.into_iter().find(|p| {
        p.is_file() && !p.to_string_lossy().to_lowercase().contains("\\windows\\system32\\")
    })
}
