//! İzin ve güvenlik katmanı.
//!
//! Her araç çağrısının bir risk sınıfı vardır. Kullanıcının seçtiği moda göre çağrı
//! doğrudan çalışır, kullanıcıya sorulur ya da engellenir.
//!
//! * Yıkıcı komutlar (disk biçimlendirme, `rm -rf /`, gölge kopya silme…) HİÇBİR modda çalışmaz.
//! * FerIDE'nin kendi ayarları ve sırları ajan tarafından değiştirilemez (izinlerini
//!   kendisi yükseltemesin diye).
//! * Kimlik bilgisi klasörleri (.ssh, .aws…) ve başlangıç (autostart) konumları her
//!   modda onaya tabidir.
//! * Yerel ağ/loopback adreslerine istek her modda onaya tabidir (SSRF koruması).

use regex::Regex;
use std::path::{Path, PathBuf};
use std::sync::LazyLock;

use crate::config::PermissionMode;
use crate::paths::{is_within, Paths};

#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Risk {
    Read,
    Write,
    Execute,
    Network,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Decision {
    Allow,
    Ask(String),
    Deny(String),
}

static CATASTROPHIC: LazyLock<Vec<Regex>> = LazyLock::new(|| {
    [
        r"\brm\s+(-[a-zA-Z]*\s+)*-[a-zA-Z]*[rf][a-zA-Z]*\s+(-[a-zA-Z]+\s+)*(/|/\*|~|~/|\$HOME|/home|/usr|/etc|/boot|/var|/bin|/lib|[A-Za-z]:[/\\]?|/[a-z]/?)\s*($|[;&|])",
        r"\bmkfs(\.\w+)?\b",
        r"\bdd\b[^|;&]*\bof=/dev/(sd|nvme|hd|mmcblk|vd|disk)",
        r":\(\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:",
        r">\s*/dev/(sd|nvme|hd|mmcblk|vd)[a-z0-9]*",
        r"\bchmod\s+(-R\s+)?[0-7]*777\s+/\s*($|[;&|])",
        r"\bchown\s+-R\s+\S+\s+/\s*($|[;&|])",
        r"(?i)\bformat(\.com)?\s+[a-z]:",
        r"(?i)Remove-Item\b.*-Recurse.*\s[A-Z]:\\?\*?\s*($|;|\|)",
        r"(?i)\b(rd|rmdir)\s+/s\b.*\s[a-z]:\\?\s*($|&|\|)",
        r"(?i)\bdel\s+(/[a-z]\s+)*[a-z]:\\\*",
        r"(?i)\bdiskpart\b",
        r"(?i)\bvssadmin\b.*\bdelete\b",
        r"(?i)\bwmic\b.*shadowcopy.*delete",
        r"(?i)\bbcdedit\b",
        r"(?i)\bcipher\s+/w",
        r"(?i)\breg\s+delete\s+HKLM",
        r"(?i)Clear-Disk|Initialize-Disk|Format-Volume",
        r"(?i)\btakeown\b.*[a-z]:\\windows",
        r"\bsudo\s+rm\s+-[a-zA-Z]*r[a-zA-Z]*f?\s+/\s*($|[;&|])",
    ]
    .iter()
    .map(|r| Regex::new(r).unwrap())
    .collect()
});

static SENSITIVE_CMD: LazyLock<Vec<Regex>> = LazyLock::new(|| {
    [
        r"\bsudo\b|\bpkexec\b|\bdoas\b|(?i)\brunas\b|(?i)-Verb\s+RunAs",
        r"\b(shutdown|reboot|poweroff|halt)\b|(?i)Stop-Computer|Restart-Computer",
        r"\bsystemctl\s+(stop|disable|mask|poweroff|reboot)",
        r"\bgit\s+(push\s+.*(--force|-f\b)|reset\s+--hard|clean\s+-[a-z]*f)",
        r"(curl|wget|iwr|Invoke-WebRequest|irm|Invoke-RestMethod)[^|]*\|\s*(sudo\s+)?((ba|z)?sh|iex|Invoke-Expression|python)\b",
        r"(?i)\b(apt|apt-get|dnf|pacman|zypper|snap|flatpak|brew|winget|choco|scoop)\s+(install|remove|purge|uninstall|-S|-R)",
        r"\bkill(all)?\s+-9\b|\bpkill\b|(?i)\btaskkill\b|(?i)Stop-Process",
        r"\bcrontab\s+-r\b|(?i)schtasks\s+/(create|delete)|(?i)Register-ScheduledTask",
        r"(?i)\breg\s+(add|delete|import)\b|(?i)Set-ItemProperty\s+.*HK(LM|CU)",
        r"(?i)Set-ExecutionPolicy|(?i)\bnetsh\b|(?i)\bsetx\b",
    ]
    .iter()
    .map(|r| Regex::new(r).unwrap())
    .collect()
});

pub fn is_catastrophic(cmd: &str) -> bool {
    CATASTROPHIC.iter().any(|r| r.is_match(cmd))
}

pub fn is_sensitive_command(cmd: &str) -> bool {
    SENSITIVE_CMD.iter().any(|r| r.is_match(cmd))
}

/// Yalnızca okuyan komut mu? (Onay gerektirmez.) Yönlendirme, alt kabuk ve
/// tehlikeli seçenekler içeren komutlar okuma sayılmaz.
pub fn is_read_only_command(cmd: &str) -> bool {
    const SAFE: &[&str] = &[
        "ls", "dir", "pwd", "cat", "head", "tail", "wc", "grep", "rg", "find", "tree", "echo", "which", "where", "whoami",
        "file", "stat", "du", "df", "date", "uname", "hostname", "type", "sort", "uniq", "cut", "diff", "less", "more",
        "get-childitem", "gci", "get-content", "gc", "select-string", "sls", "get-location", "get-item", "test-path",
        "get-command", "resolve-path", "measure-object", "get-process", "get-date", "cargo-metadata",
    ];
    const SAFE_GIT: &[&str] = &["status", "log", "diff", "show", "branch", "remote", "rev-parse", "ls-files", "blame", "describe", "tag"];
    if cmd.contains('>') || cmd.contains('`') || cmd.contains("$(") || cmd.contains("<(") || cmd.trim().is_empty() {
        return false;
    }
    let lower = cmd.to_lowercase();
    if lower.contains("-delete") || lower.contains("-exec") || lower.contains("--output") || lower.contains("-remove") {
        return false;
    }
    static SEG: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"&&|\|\||;|\|").unwrap());
    let parts: Vec<&str> = SEG.split(cmd).collect();
    parts.into_iter().all(|seg| {
        let mut words = seg.split_whitespace();
        let Some(first) = words.next() else { return true };
        let first = first.trim_matches(|c| c == '"' || c == '\'').to_lowercase();
        let first = first.rsplit(['/', '\\']).next().unwrap_or(&first).trim_end_matches(".exe").to_string();
        if first == "git" {
            return words.next().map(|w| SAFE_GIT.contains(&w)).unwrap_or(false);
        }
        if first == "cargo" || first == "npm" || first == "python" || first == "node" {
            let a: Vec<&str> = words.collect();
            return a == ["--version"] || a == ["-v"] || a == ["-V"];
        }
        SAFE.contains(&first.as_str())
    })
}

pub struct Policy<'a> {
    pub mode: PermissionMode,
    pub workspace: &'a Path,
    pub paths: &'a Paths,
}

impl Policy<'_> {
    /// Ajanın asla yazamayacağı yollar (FerIDE ayarları ve sırları).
    fn is_protected(&self, p: &Path) -> bool {
        [self.paths.config_file(), self.paths.secrets_file(), self.paths.state_file()]
            .iter()
            .any(|x| is_within(x, p))
    }

    /// Her modda onaya tabi yollar (kimlik bilgileri, açılışta çalışan betikler, FerIDE yapılandırması).
    fn is_sensitive_path(&self, p: &Path) -> bool {
        let h = &self.paths.home;
        let mut list: Vec<PathBuf> = [
            ".ssh", ".gnupg", ".aws", ".azure", ".kube", ".docker", ".config/gcloud", ".config/autostart", ".bashrc",
            ".bash_profile", ".profile", ".zshrc", ".zprofile", ".gitconfig", ".npmrc", ".pypirc", ".netrc",
        ]
        .iter()
        .map(|x| h.join(x))
        .collect();
        list.push(self.paths.mcp_config());
        list.push(self.paths.llama_root());
        list.push(self.paths.tools());
        if cfg!(windows) {
            list.push(h.join("AppData").join("Roaming").join("Microsoft").join("Windows").join("Start Menu").join("Programs").join("Startup"));
            if let Some(w) = std::env::var_os("SystemRoot") {
                list.push(PathBuf::from(w));
            }
            for v in ["ProgramFiles", "ProgramFiles(x86)", "ProgramData"] {
                if let Some(x) = std::env::var_os(v) {
                    list.push(PathBuf::from(x));
                }
            }
        } else {
            for x in ["/etc", "/usr", "/boot", "/bin", "/sbin", "/lib", "/var", "/Library", "/System"] {
                list.push(PathBuf::from(x));
            }
        }
        list.iter().any(|s| is_within(s, p))
    }

    pub fn inside_workspace(&self, p: &Path) -> bool {
        is_within(self.workspace, p)
    }

    pub fn evaluate(&self, risk: Risk, command: Option<&str>, targets: &[PathBuf], private_network: bool) -> Decision {
        if let Some(c) = command {
            if is_catastrophic(c) {
                return Decision::Deny("Bu komut sistemi geri dönülmez şekilde bozabilir; güvenlik nedeniyle hiçbir modda çalıştırılmaz.".into());
            }
        }
        if targets.iter().any(|p| self.is_protected(p)) {
            return Decision::Deny("FerIDE'nin kendi ayar ve sır dosyaları ajan tarafından değiştirilemez.".into());
        }
        if private_network {
            return Decision::Ask("Yerel ağ / bu bilgisayardaki bir adrese istek".into());
        }
        let mode = self.mode;
        match risk {
            Risk::Read => Decision::Allow,
            Risk::Network => {
                if mode == PermissionMode::Ask {
                    Decision::Ask("İnternete erişim".into())
                } else {
                    Decision::Allow
                }
            }
            Risk::Write => {
                if mode == PermissionMode::Plan {
                    return Decision::Deny("Plan modundasınız: dosya değiştirilemez. Değişiklik için modu değiştirin.".into());
                }
                if targets.iter().any(|p| self.is_sensitive_path(p)) {
                    return Decision::Ask("Hassas bir sistem/kimlik bilgisi konumuna yazma".into());
                }
                if mode == PermissionMode::FullAuto {
                    return Decision::Allow;
                }
                let all_inside = !targets.is_empty() && targets.iter().all(|p| self.inside_workspace(p));
                if mode == PermissionMode::AutoEdit && all_inside {
                    return Decision::Allow;
                }
                Decision::Ask(if all_inside { "Dosya değişikliği".into() } else { "Çalışma alanı dışına yazma".into() })
            }
            Risk::Execute => {
                if let Some(c) = command {
                    if is_read_only_command(c) {
                        return Decision::Allow;
                    }
                }
                if mode == PermissionMode::Plan {
                    return Decision::Deny("Plan modundasınız: yalnızca okuyan komutlar çalıştırılabilir.".into());
                }
                if mode == PermissionMode::FullAuto {
                    return Decision::Allow;
                }
                if command.map(is_sensitive_command).unwrap_or(false) {
                    return Decision::Ask("Yönetici yetkisi, silme veya sistem değişikliği içeren komut".into());
                }
                Decision::Ask("Komut çalıştırma".into())
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn catastrophic_blocked() {
        for c in [
            "rm -rf /",
            "rm -rf ~",
            "sudo rm -rf / ",
            "mkfs.ext4 /dev/sda1",
            "dd if=/dev/zero of=/dev/nvme0n1",
            ":(){ :|:& };:",
            "format C:",
            "Remove-Item -Recurse -Force C:\\",
            "rd /s /q C:\\",
            "vssadmin delete shadows /all",
            "diskpart",
            "bcdedit /delete",
            "reg delete HKLM\\Software\\X",
            "rm -rf /c/",
        ] {
            assert!(is_catastrophic(c), "engellenmeliydi: {c}");
        }
        for c in ["rm -rf ./build", "rm -rf node_modules", "Remove-Item -Recurse .\\dist", "rd /s /q build", "git status"] {
            assert!(!is_catastrophic(c), "engellenmemeliydi: {c}");
        }
    }

    #[test]
    fn read_only_commands() {
        assert!(is_read_only_command("ls -la"));
        assert!(is_read_only_command("git status && git diff --stat"));
        assert!(is_read_only_command("cat a.txt | grep foo | wc -l"));
        assert!(is_read_only_command("Get-ChildItem -Recurse | Select-String foo"));
        assert!(!is_read_only_command("echo hi > a.txt"));
        assert!(!is_read_only_command("find . -name x -delete"));
        assert!(!is_read_only_command("git push"));
        assert!(!is_read_only_command("ls; rm a"));
        assert!(!is_read_only_command("cat $(rm x)"));
        assert!(!is_read_only_command("python script.py"));
    }

    #[test]
    fn modes() {
        let dir = tempfile::tempdir().unwrap();
        let paths = Paths::with_data_dir(dir.path().join("data"));
        let ws = dir.path().join("proje");
        let inside = vec![ws.join("a.rs")];
        let outside = vec![dir.path().join("baska").join("b.rs")];
        let p = |m| Policy { mode: m, workspace: &ws, paths: &paths };

        assert_eq!(p(PermissionMode::AutoEdit).evaluate(Risk::Write, None, &inside, false), Decision::Allow);
        assert!(matches!(p(PermissionMode::AutoEdit).evaluate(Risk::Write, None, &outside, false), Decision::Ask(_)));
        assert!(matches!(p(PermissionMode::Ask).evaluate(Risk::Write, None, &inside, false), Decision::Ask(_)));
        assert!(matches!(p(PermissionMode::Plan).evaluate(Risk::Write, None, &inside, false), Decision::Deny(_)));
        assert_eq!(p(PermissionMode::Plan).evaluate(Risk::Execute, Some("git log"), &[], false), Decision::Allow);
        assert!(matches!(p(PermissionMode::Plan).evaluate(Risk::Execute, Some("cargo build"), &[], false), Decision::Deny(_)));
        assert!(matches!(p(PermissionMode::AutoEdit).evaluate(Risk::Execute, Some("cargo build"), &[], false), Decision::Ask(_)));
        assert_eq!(p(PermissionMode::FullAuto).evaluate(Risk::Execute, Some("cargo build"), &[], false), Decision::Allow);
        assert!(matches!(p(PermissionMode::FullAuto).evaluate(Risk::Execute, Some("rm -rf /"), &[], false), Decision::Deny(_)));
        // FerIDE ayarları korumalı, tam otonomda bile.
        let cfg = vec![paths.config_file()];
        assert!(matches!(p(PermissionMode::FullAuto).evaluate(Risk::Write, None, &cfg, false), Decision::Deny(_)));
        // Kimlik bilgisi klasörü tam otonomda da sorulur.
        let ssh = vec![paths.home.join(".ssh").join("authorized_keys")];
        assert!(matches!(p(PermissionMode::FullAuto).evaluate(Risk::Write, None, &ssh, false), Decision::Ask(_)));
        // Yerel ağ isteği her modda sorulur.
        assert!(matches!(p(PermissionMode::FullAuto).evaluate(Risk::Network, None, &[], true), Decision::Ask(_)));
    }
}
