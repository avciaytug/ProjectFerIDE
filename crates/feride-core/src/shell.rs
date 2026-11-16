//! Ajan ve terminal için kabuk seçimi.
//!
//! Yerel modeller komutları neredeyse her zaman bash sözdizimiyle yazar. Bu yüzden
//! Windows'ta önce Git Bash aranır (FerIDE'nin kurduğu taşınabilir Git dahil); WSL'nin
//! `System32\bash.exe`'si seçilmez. Bulunamazsa PowerShell kullanılır ve ajan buna göre
//! bilgilendirilir.

use std::borrow::Cow;
use std::path::PathBuf;
use std::sync::LazyLock;

use crate::paths::Paths;

/// Git Bash'te `komut 2>nul` Windows'taki gibi "çıktıyı at" demek değildir: çalışma klasöründe `nul` adlı bir dosya
/// oluşturur ve Windows bu dosyayı normal yollarla açamaz, taşıyamaz, silemez (`nul` aygıt adıdır). Modeller bu
/// Windows alışkanlığıyla sık yazdığı için bash komutlarındaki `nul` yönlendirmeleri `/dev/null`'a çevrilir.
/// (`> nul.txt`, `>null` gibi gerçek dosya adlarına dokunulmaz.)
pub fn fix_nul_redirects(command: &str) -> Cow<'_, str> {
    static RE: LazyLock<regex::Regex> =
        LazyLock::new(|| regex::Regex::new(r"(?i)(\d?>>?|&>>?|\d?<)[ \t]*nul:?(\s|$|[;&|)])").unwrap());
    RE.replace_all(command, "${1}/dev/null${2}")
}

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
                    // RemoteSigned: çalışma alanındaki betikler çalışır; internetten inen imzasız betikler çalışmaz.
                    "-ExecutionPolicy".into(),
                    "RemoteSigned".into(),
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
            ShellKind::Bash if cfg!(windows) => format!(
                "Komutlar Windows üzerinde Git Bash ile çalışır: bash sözdizimi kullan (ls, grep, cat, &&). Windows \
                 yollarını tırnak içinde ve / ile yaz (\"C:/Users/...\"). {WINDOWS_NOTE}"
            ),
            ShellKind::PowerShell => format!(
                "Komutlar PowerShell ile çalışır: bash komutları (grep, cat <<EOF, &&) ÇALIŞMAZ. PowerShell karşılıklarını \
                 kullan (Get-ChildItem, Select-String, Get-Content, ; ile ayır). {WINDOWS_NOTE}"
            ),
            ShellKind::Cmd => format!("Komutlar cmd.exe ile çalışır. {WINDOWS_NOTE}"),
            _ if cfg!(target_os = "macos") => format!(
                "Komutlar {} ile çalışır (macOS). apt, systemctl, lsblk, free, xdg-open gibi Linux komutları ve Windows \
                 komutları yok; brew, launchctl, diskutil, vm_stat, open kullan. sudo gereken işleri kullanıcıya sor.",
                self.display_name()
            ),
            _ => format!(
                "Komutlar {} ile çalışır (Linux). Windows komutları (tasklist, ipconfig, winget, powershell) yok. \
                 sudo gereken işleri (paket kurma, sistem ayarı) kullanıcıya sor.",
                self.display_name()
            ),
        }
    }
}

/// Windows'ta çalışan ajana: Linux komutlarının olmadığını ve karşılıklarını açıkça söyler.
const WINDOWS_NOTE: &str = "Bu bir WINDOWS bilgisayar: sudo, apt/yum/pacman, systemctl/service, journalctl, lsblk, \
free, top, ifconfig/ip, xdg-open/open, pkill/killall gibi Linux/macOS komutları YOK ve çalıştırılmaz. Karşılıkları: program \
kurmak için `winget install --id <Kimlik> -e`; hizmet, süreç, disk ve olay günlüğü için `powershell -NoProfile -Command \
\"Get-Service | Get-Process | Get-Volume | Get-WinEvent ...\"`; `tasklist`/`taskkill`; `ipconfig`; `netstat -ano`; \
dosya ya da adres açmak için open_in_system aracı. Git Bash'teki ps/kill yalnızca bash süreçlerini görür. \
Yönetici izni gereken işleri kullanıcıya söyle.";

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

#[cfg(test)]
mod tests {
    use super::fix_nul_redirects as f;

    #[test]
    fn nul_redirects_become_dev_null() {
        // Kullanıcının bilgisayarındaki "nul" dosyasını bırakan komut türü.
        assert_eq!(f("wmic cpu get name 2>nul"), "wmic cpu get name 2>/dev/null");
        assert_eq!(f("dir /b >nul 2>&1 && echo ok"), "dir /b >/dev/null 2>&1 && echo ok");
        assert_eq!(f("git status > NUL"), "git status >/dev/null");
        assert_eq!(f("echo hi>nul; ls"), "echo hi>/dev/null; ls");
        assert_eq!(f("cmd &>nul"), "cmd &>/dev/null");
        assert_eq!(f("cmd 2>>NUL:"), "cmd 2>>/dev/null");
        assert_eq!(f("read x <nul"), "read x </dev/null");
        assert_eq!(f("(a 2>nul)|b"), "(a 2>/dev/null)|b");
        // Gerçek dosya adlarına ve doğru yazılmış komutlara dokunulmaz.
        for same in ["echo x > nul.txt", "echo x >null", "cat annul", "x 2>/dev/null", "echo nul", "x > nul_log"] {
            assert_eq!(f(same), same);
        }
    }
}
