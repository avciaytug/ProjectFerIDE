//! Ajanın başka bir işletim sistemine ait komut yazmasını yakalar (ör. Windows'ta `sudo apt install`,
//! `systemctl`, `lsblk`). Komut çalıştırılmadan reddedilir ve model bu sistemdeki karşılığına yönlendirilir;
//! "komut bulunamadı" hatalarına da aynı ipucu eklenir.

use regex::Regex;
use std::sync::LazyLock;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Os {
    Windows,
    Linux,
    MacOs,
}

impl Os {
    pub fn current() -> Os {
        if cfg!(windows) {
            Os::Windows
        } else if cfg!(target_os = "macos") {
            Os::MacOs
        } else {
            Os::Linux
        }
    }

    fn name(self) -> &'static str {
        match self {
            Os::Windows => "Windows",
            Os::Linux => "Linux",
            Os::MacOs => "macOS",
        }
    }
}

/// (komutlar, ipucu): bu işletim sisteminde OLMAYAN komutlar ve karşılıkları.
fn table(os: Os) -> &'static [(&'static [&'static str], &'static str)] {
    match os {
        Os::Windows => &[
            (&["sudo", "doas", "su"], "Windows'ta sudo yok ve FerIDE yönetici olarak çalışmaz. Yönetici izni gereken bir işse kullanıcıya ne yapması gerektiğini söyle."),
            (
                &["apt", "apt-get", "apt-cache", "dpkg", "yum", "dnf", "rpm", "pacman", "zypper", "snap", "flatpak", "apk", "brew"],
                "Program kurmak için winget kullan: winget install --id <Kimlik> -e --accept-source-agreements --accept-package-agreements (kimliği bulmak için: winget search <ad>). Python paketleri için pip/uv, Node paketleri için npm.",
            ),
            (&["systemctl", "service", "launchctl"], "Windows hizmetleri: powershell -NoProfile -Command \"Get-Service <ad>\" (Start-Service, Stop-Service, Restart-Service) ya da sc.exe query <ad>."),
            (&["journalctl", "dmesg"], "Olay günlüğü: powershell -NoProfile -Command \"Get-WinEvent -LogName System -MaxEvents 30 | Format-List TimeCreated,Id,LevelDisplayName,Message\" (uygulama hataları için -LogName Application)."),
            (&["lsblk", "blkid", "fdisk", "parted", "diskutil"], "Diskler: powershell -NoProfile -Command \"Get-Volume\" ya da \"Get-Disk\"; boş alan: df -h."),
            (&["free", "vmstat"], "Bellek: powershell -NoProfile -Command \"Get-CimInstance Win32_OperatingSystem | Select-Object TotalVisibleMemorySize,FreePhysicalMemory\" (KB)."),
            (&["top", "htop", "btop"], "Süreçler: tasklist ya da powershell -NoProfile -Command \"Get-Process | Sort-Object CPU -Descending | Select-Object -First 15 Name,Id,CPU,WS\"."),
            (&["pkill", "killall", "pgrep", "pidof"], "Süreç bulmak: tasklist /FI \"IMAGENAME eq <ad>.exe\"; sonlandırmak: taskkill /IM <ad>.exe /F (ya da /PID <pid> /F)."),
            (&["lsof", "fuser", "ss"], "Portu kullanan süreç: netstat -ano | findstr :<port>, ardından tasklist /FI \"PID eq <pid>\"."),
            (&["ifconfig", "ip", "nmcli", "iwconfig"], "Ağ: ipconfig /all; bağlantılar: netstat -ano."),
            (&["iptables", "ufw", "firewall-cmd"], "Güvenlik duvarı: powershell -NoProfile -Command \"Get-NetFirewallRule\" (değiştirmek yönetici izni ister)."),
            (&["xdg-open", "open", "gio"], "Dosya, klasör ya da web adresi açmak için open_in_system aracını kullan."),
            (&["useradd", "usermod", "userdel", "groupadd", "adduser"], "Kullanıcılar: powershell -NoProfile -Command \"Get-LocalUser\" (değiştirmek yönetici izni ister)."),
            (&["crontab"], "Zamanlanmış görevler: schtasks /Query ya da powershell Get-ScheduledTask / Register-ScheduledTask."),
            (&["lscpu", "lspci", "lsusb", "lshw", "dmidecode", "inxi"], "Donanım: powershell -NoProfile -Command \"Get-CimInstance Win32_Processor\" (ekran kartı: Win32_VideoController, aygıtlar: Win32_PnPEntity)."),
            (&["modprobe", "insmod", "rmmod", "lsmod", "ldconfig", "update-alternatives", "update-grub", "sysctl", "chroot", "mkfs"], "Bu Linux çekirdek/sistem komutunun Windows'ta karşılığı yok; görevi Windows araçlarıyla yeniden düşün."),
            (&["pbcopy", "pbpaste", "xclip", "xsel", "wl-copy", "wl-paste"], "Pano: yazmak için clip (ör. echo metin | clip), okumak için powershell -NoProfile -Command Get-Clipboard."),
            (&["sw_vers", "lsb_release", "hostnamectl"], "Sistem bilgisi: systeminfo ya da powershell -NoProfile -Command \"Get-ComputerInfo | Select-Object OsName,OsVersion\"."),
        ],
        Os::Linux => &[
            (&["tasklist"], "Süreçler: ps aux | grep <ad> ya da pgrep -a <ad>."),
            (&["taskkill"], "Süreç sonlandırmak: kill <pid> ya da pkill <ad>."),
            (&["ipconfig"], "Ağ: ip a (ya da ifconfig)."),
            (&["winget", "choco", "scoop"], "Paketler dağıtımın paket yöneticisiyle kurulur (apt, dnf, pacman, zypper); sudo gerekir, kullanıcıya sor."),
            (&["wmic", "systeminfo"], "Sistem bilgisi: uname -a, lscpu, free -h, lsblk."),
            (&["schtasks"], "Zamanlanmış görevler: crontab -l ya da systemctl list-timers."),
            (&["netsh"], "Ağ ayarları: ip / nmcli."),
            (&["findstr"], "Metin arama: grep."),
            (&["cmd", "powershell.exe", "pwsh.exe"], "Bu bir Linux bilgisayar; Windows kabukları yok. bash kullan."),
            (&["clip"], "Pano: xclip -selection clipboard ya da wl-copy."),
            (&["launchctl", "diskutil", "sw_vers", "pbcopy", "pbpaste", "softwareupdate"], "Bu bir macOS komutu; Linux'ta yok (servisler: systemctl, diskler: lsblk, pano: xclip/wl-copy)."),
        ],
        Os::MacOs => &[
            (&["apt", "apt-get", "apt-cache", "dpkg", "yum", "dnf", "rpm", "pacman", "zypper", "snap", "flatpak", "apk"], "macOS'ta paketler Homebrew ile kurulur: brew install <ad> (brew kurulu değilse kullanıcıya sor)."),
            (&["systemctl", "service", "journalctl"], "Servisler: launchctl list ya da brew services; günlükler: log show --last 10m."),
            (&["lsblk", "blkid", "fdisk"], "Diskler: diskutil list; boş alan: df -h."),
            (&["free"], "Bellek: vm_stat ya da top -l 1 | head -n 10."),
            (&["ip", "nmcli"], "Ağ: ifconfig; yönlendirme: netstat -rn."),
            (&["xdg-open"], "Açmak için open <yol> ya da open_in_system aracı."),
            (&["lscpu", "lspci", "lsusb"], "Donanım: system_profiler SPHardwareDataType ya da sysctl -n machdep.cpu.brand_string."),
            (&["xclip", "xsel", "wl-copy", "wl-paste"], "Pano: pbcopy / pbpaste."),
            (&["tasklist"], "Süreçler: ps aux | grep <ad>."),
            (&["taskkill"], "Süreç sonlandırmak: kill <pid> ya da pkill <ad>."),
            (&["ipconfig"], "Ağ: ifconfig."),
            (&["winget", "choco", "scoop"], "Paketler: brew install <ad>."),
            (&["wmic", "systeminfo"], "Sistem bilgisi: sw_vers, system_profiler SPSoftwareDataType."),
            (&["findstr"], "Metin arama: grep."),
            (&["cmd", "powershell.exe", "pwsh.exe"], "Bu bir Mac; Windows kabukları yok. zsh/bash kullan."),
            (&["clip"], "Pano: pbcopy."),
        ],
    }
}

fn lookup(os: Os, head: &str) -> Option<&'static str> {
    table(os).iter().find(|(names, _)| names.contains(&head)).map(|(_, hint)| *hint)
}

/// Komut satırını alt komutlara böler (`;`, `|`, `&`, `&&`, `||`, satır sonu, parantez, `` ` ``);
/// tırnak içindekiler bölünmez. Her parçanın sözcükleri (tırnaklar kaldırılmış) döner.
fn segments(cmd: &str) -> Vec<Vec<String>> {
    let mut out: Vec<Vec<String>> = vec![];
    let mut words: Vec<String> = vec![];
    let mut cur = String::new();
    let mut has_cur = false;
    let (mut sq, mut dq, mut esc) = (false, false, false);
    let flush_word = |cur: &mut String, has_cur: &mut bool, words: &mut Vec<String>| {
        if *has_cur {
            words.push(std::mem::take(cur));
            *has_cur = false;
        }
    };
    for ch in cmd.chars() {
        if esc {
            cur.push(ch);
            has_cur = true;
            esc = false;
            continue;
        }
        match ch {
            '\\' if !sq => {
                esc = true;
            }
            '\'' if !dq => {
                sq = !sq;
                has_cur = true;
            }
            '"' if !sq => {
                dq = !dq;
                has_cur = true;
            }
            _ if sq || dq => {
                cur.push(ch);
                has_cur = true;
            }
            ';' | '|' | '&' | '\n' | '(' | ')' | '`' => {
                flush_word(&mut cur, &mut has_cur, &mut words);
                if !words.is_empty() {
                    out.push(std::mem::take(&mut words));
                }
            }
            c if c.is_whitespace() => flush_word(&mut cur, &mut has_cur, &mut words),
            c => {
                cur.push(c);
                has_cur = true;
            }
        }
    }
    flush_word(&mut cur, &mut has_cur, &mut words);
    if !words.is_empty() {
        out.push(words);
    }
    out
}

static ASSIGN: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^[A-Za-z_][A-Za-z0-9_]*=").unwrap());
/// Asıl komutu önündeki sarmalayıcı/anahtar sözcükler (bunlar atlanır).
const SKIP: &[&str] = &["time", "nohup", "exec", "command", "builtin", "env", "then", "do", "else", "elif", "if", "while", "until", "!", "{", "}", "nice"];

/// Bir parçanın asıl komut adı (küçük harf, yol ve `.exe` atılmış) ve argümanları.
fn head_of(words: &[String]) -> Option<(String, &[String])> {
    let mut i = 0;
    while i < words.len() && (ASSIGN.is_match(&words[i]) || SKIP.contains(&words[i].as_str())) {
        i += 1;
    }
    let w = words.get(i)?;
    let base = w.rsplit(['/', '\\']).next().unwrap_or(w).to_lowercase();
    let base = base.strip_suffix(".exe").map(str::to_string).filter(|b| b != "powershell" && b != "pwsh").unwrap_or(base);
    Some((base, &words[i + 1..]))
}

/// Bu işletim sisteminde bulunmayan bir komut kullanılıyorsa, modele gösterilecek hata ve ipucu.
pub fn foreign_command(cmd: &str, os: Os) -> Option<String> {
    for seg in segments(cmd) {
        let Some((head, args)) = head_of(&seg) else { continue };
        // Windows'ta Git Bash'in ps'i yalnızca bash süreçlerini gösterir; "ps aux" yanıltıcı sonuç verir.
        if os == Os::Windows && head == "ps" && args.iter().any(|a| a == "aux" || a == "-ef" || a == "-e" || a == "-A") {
            return Some(
                "HATA: Bu bilgisayar Windows; Git Bash'teki `ps` yalnızca bash süreçlerini gösterir, komut çalıştırılmadı. \
                 Windows süreçleri için: tasklist (ya da tasklist /FI \"IMAGENAME eq <ad>.exe\") veya powershell -NoProfile -Command \"Get-Process\"."
                    .to_string(),
            );
        }
        if let Some(hint) = lookup(os, &head) {
            return Some(format!(
                "HATA: Bu bilgisayar {os}; `{head}` komutu burada yok, komut çalıştırılmadı. {hint} Komutu {os}'a uygun biçimde yeniden yaz.",
                os = os.name()
            ));
        }
    }
    None
}

static NOT_FOUND: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?m)(?:^|: )([A-Za-z0-9_.\-]+): (?:command not found|komut bulunamad)|The term '([^']+)' is not recognized|'([^']+)' terimi").unwrap()
});

/// "komut bulunamadı" hatasındaki komut başka bir işletim sistemine aitse ipucu döner.
pub fn not_found_hint(output: &str, os: Os) -> Option<String> {
    for c in NOT_FOUND.captures_iter(output) {
        let name = c.get(1).or(c.get(2)).or(c.get(3))?.as_str().to_lowercase();
        let name = name.rsplit(['/', '\\']).next().unwrap_or(&name).trim_end_matches(".exe").to_string();
        if let Some(hint) = lookup(os, &name) {
            return Some(format!("[İpucu: bu bilgisayar {}; `{name}` burada yok. {hint}]", os.name()));
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_commands_and_respects_quotes() {
        let s = segments("FOO=1 sudo apt-get install -y git && echo \"a; b | c\" | grep x; (cd /tmp && ls)");
        let heads: Vec<String> = s.iter().filter_map(|w| head_of(w).map(|h| h.0)).collect();
        assert_eq!(heads, vec!["sudo", "echo", "grep", "cd", "ls"]);
    }

    #[test]
    fn windows_rejects_linux_commands() {
        let w = Os::Windows;
        assert!(foreign_command("sudo apt install git", w).unwrap().contains("sudo"));
        assert!(foreign_command("systemctl restart nginx", w).unwrap().contains("Get-Service"));
        assert!(foreign_command("ls -la && lsblk", w).unwrap().contains("Get-Volume"));
        assert!(foreign_command("/usr/bin/free -h", w).is_some());
        assert!(foreign_command("ps aux | grep python", w).unwrap().contains("tasklist"));
        // Windows'ta da çalışanlar engellenmez.
        for ok in ["ls -la \"C:/Program Files\"", "git status", "echo 'sudo apt'", "powershell -NoProfile -Command \"Get-Process\"", "ps", "grep -r foo .", "npm install", "df -h", "tasklist"] {
            assert!(foreign_command(ok, w).is_none(), "{ok}");
        }
    }

    #[test]
    fn linux_and_mac_reject_foreign_commands() {
        assert!(foreign_command("tasklist /FI \"IMAGENAME eq x.exe\"", Os::Linux).is_some());
        assert!(foreign_command("ipconfig /all", Os::Linux).is_some());
        assert!(foreign_command("sudo apt install git", Os::Linux).is_none());
        assert!(foreign_command("apt install git", Os::MacOs).unwrap().contains("brew"));
        assert!(foreign_command("brew install git", Os::MacOs).is_none());
    }

    #[test]
    fn hints_for_not_found() {
        let h = not_found_hint("bash: line 1: lsblk: command not found", Os::Windows).unwrap();
        assert!(h.contains("Get-Volume"));
        assert!(not_found_hint("bash: foo: command not found", Os::Windows).is_none());
        assert!(not_found_hint("The term 'apt' is not recognized as a name of a cmdlet", Os::Windows).is_some());
    }
}
