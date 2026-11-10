//! Alt süreç yönetimi.
//!
//! * Windows: her süreç "kapanınca öldür" ayarlı bir İş Nesnesi'ne (Job Object)
//!   bağlanır. FerIDE kapanır ya da çökerse işletim sistemi tutamaçları kapatır ve
//!   llama-server, MCP sunucuları, ajan komutları ağacıyla birlikte sonlanır.
//!   Konsol penceresi açılmaz (CREATE_NO_WINDOW).
//! * Unix: süreç kendi süreç grubunda başlar; grup birlikte sonlandırılır.
//!   Linux'ta ana süreç ölürse çocuk SIGKILL alır (PR_SET_PDEATHSIG).
//! * Windows'ta `npx`, `uvx` gibi komutlar `.cmd`/`.bat` olabilir; bunlar PATH'te
//!   uzantılarıyla aranır ve `cmd /C` ile çalıştırılır.

use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use crate::paths::Paths;

/// Alt süreçlere verilecek PATH: FerIDE'nin taşınabilir araçları + sistem PATH'i.
pub fn child_path(paths: &Paths, extra: &[PathBuf]) -> OsString {
    let mut dirs: Vec<PathBuf> = extra.to_vec();
    dirs.extend(paths.tool_path_dirs());
    if let Some(sys) = std::env::var_os("PATH") {
        dirs.extend(std::env::split_paths(&sys));
    }
    std::env::join_paths(dirs).unwrap_or_else(|_| std::env::var_os("PATH").unwrap_or_default())
}

/// Bir programı PATH (ve verilen ek PATH) içinde arar. Windows'ta PATHEXT uzantılarını dener.
pub fn which_in(program: &str, path_var: &OsString) -> Option<PathBuf> {
    let p = Path::new(program);
    if p.components().count() > 1 || p.is_absolute() {
        return resolve_with_ext(p);
    }
    for dir in std::env::split_paths(path_var) {
        if let Some(found) = resolve_with_ext(&dir.join(program)) {
            return Some(found);
        }
    }
    None
}

fn resolve_with_ext(p: &Path) -> Option<PathBuf> {
    if cfg!(windows) {
        if p.extension().is_some() && p.is_file() {
            return Some(p.to_path_buf());
        }
        for ext in ["exe", "cmd", "bat", "com"] {
            let c = p.with_extension(ext);
            if c.is_file() {
                return Some(c);
            }
        }
        None
    } else if p.is_file() {
        Some(p.to_path_buf())
    } else {
        None
    }
}

/// Komut oluşturur: gizli pencere, kendi süreç grubu, stdin kapalı, FerIDE PATH'i.
/// Windows'ta `.cmd/.bat` hedefleri `cmd /C` üzerinden çalıştırılır.
pub fn command(paths: &Paths, program: &str, args: &[String]) -> tokio::process::Command {
    let path_var = child_path(paths, &[]);
    let resolved = which_in(program, &path_var).unwrap_or_else(|| PathBuf::from(program));
    let is_script = cfg!(windows)
        && resolved
            .extension()
            .and_then(|e| e.to_str())
            .map(|e| e.eq_ignore_ascii_case("cmd") || e.eq_ignore_ascii_case("bat"))
            .unwrap_or(false);
    let mut cmd = if is_script {
        let mut c = tokio::process::Command::new("cmd.exe");
        c.arg("/D").arg("/S").arg("/C").arg(&resolved);
        c.args(args);
        c
    } else {
        let mut c = tokio::process::Command::new(&resolved);
        c.args(args);
        c
    };
    cmd.env("PATH", &path_var);
    // Python alt süreçleri Windows'ta yönlendirilmiş çıktıyı kod sayfasıyla (cp1254) yazar;
    // UTF-8'e zorla (aksi halde MCP/JSON akışı ilk Türkçe karakterde bozulur).
    cmd.env("PYTHONUTF8", "1").env("PYTHONIOENCODING", "utf-8");
    cmd.stdin(std::process::Stdio::null());
    cmd.kill_on_drop(true);
    harden(&mut cmd);
    cmd
}

#[cfg(windows)]
fn harden(cmd: &mut tokio::process::Command) {
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    cmd.creation_flags(CREATE_NO_WINDOW);
}

#[cfg(unix)]
fn harden(cmd: &mut tokio::process::Command) {
    cmd.process_group(0);
    #[cfg(target_os = "linux")]
    unsafe {
        cmd.pre_exec(|| {
            libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL);
            Ok(())
        });
    }
}

/// Senkron (std) komutlar için aynı sertleştirme (kısa sorgular: --version, --help).
pub fn std_command(paths: &Paths, program: &Path) -> std::process::Command {
    let mut c = std::process::Command::new(program);
    c.env("PATH", child_path(paths, &[]));
    c.stdin(std::process::Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        c.creation_flags(0x0800_0000);
    }
    c
}

/// Çalışan bir alt süreci (ve tüm torunlarını) sonlandırabilen tutamaç.
#[derive(Clone)]
pub struct KillHandle {
    pub pid: Option<u32>,
    #[cfg(windows)]
    job: Option<Arc<win::Job>>,
}

impl KillHandle {
    /// Süreç ağacını sonlandırır.
    pub fn kill_tree(&self) {
        #[cfg(windows)]
        {
            if let Some(j) = &self.job {
                j.terminate();
                return;
            }
            if let Some(pid) = self.pid {
                let _ = std::process::Command::new("taskkill")
                    .args(["/T", "/F", "/PID", &pid.to_string()])
                    .stdout(std::process::Stdio::null())
                    .stderr(std::process::Stdio::null())
                    .status();
            }
        }
        #[cfg(unix)]
        {
            if let Some(pid) = self.pid {
                unsafe {
                    libc::killpg(pid as i32, libc::SIGTERM);
                }
                let pid = pid as i32;
                std::thread::spawn(move || {
                    std::thread::sleep(std::time::Duration::from_millis(1500));
                    unsafe {
                        libc::killpg(pid, libc::SIGKILL);
                    }
                });
            }
        }
    }
}

/// Komutu başlatır ve süreç ağacını İş Nesnesi'ne / süreç grubuna bağlar.
pub fn spawn(cmd: &mut tokio::process::Command) -> std::io::Result<(tokio::process::Child, KillHandle)> {
    let child = cmd.spawn()?;
    let pid = child.id();
    #[cfg(windows)]
    {
        let job = match (win::Job::new(), child.raw_handle()) {
            (Ok(job), Some(h)) => {
                if job.assign(h) {
                    Some(Arc::new(job))
                } else {
                    None
                }
            }
            _ => None,
        };
        Ok((child, KillHandle { pid, job }))
    }
    #[cfg(unix)]
    {
        let _ = Arc::new(());
        Ok((child, KillHandle { pid }))
    }
}

#[cfg(windows)]
mod win {
    use std::ffi::c_void;
    use windows_sys::Win32::Foundation::{CloseHandle, HANDLE};
    use windows_sys::Win32::System::JobObjects::{
        AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation, SetInformationJobObject,
        TerminateJobObject, JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
    };

    pub struct Job(HANDLE);
    unsafe impl Send for Job {}
    unsafe impl Sync for Job {}

    impl Job {
        pub fn new() -> std::io::Result<Self> {
            unsafe {
                let h = CreateJobObjectW(std::ptr::null(), std::ptr::null());
                if h.is_null() {
                    return Err(std::io::Error::last_os_error());
                }
                let mut info: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std::mem::zeroed();
                info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
                let ok = SetInformationJobObject(
                    h,
                    JobObjectExtendedLimitInformation,
                    &info as *const _ as *const c_void,
                    std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
                );
                if ok == 0 {
                    CloseHandle(h);
                    return Err(std::io::Error::last_os_error());
                }
                Ok(Job(h))
            }
        }

        pub fn assign(&self, process: *mut c_void) -> bool {
            unsafe { AssignProcessToJobObject(self.0, process as HANDLE) != 0 }
        }

        pub fn terminate(&self) {
            unsafe {
                TerminateJobObject(self.0, 1);
            }
        }
    }

    impl Drop for Job {
        fn drop(&mut self) {
            unsafe {
                CloseHandle(self.0);
            }
        }
    }
}

/// Komutu çalıştırıp çıktısını toplar (zaman aşımı ile; aşılırsa ağaç öldürülür).
pub async fn run_capture(
    cmd: &mut tokio::process::Command,
    timeout: std::time::Duration,
) -> std::io::Result<(Option<i32>, String, String, bool)> {
    use tokio::io::AsyncReadExt;
    cmd.stdout(std::process::Stdio::piped()).stderr(std::process::Stdio::piped());
    let (mut child, kill) = spawn(cmd)?;
    let mut out = child.stdout.take();
    let mut err = child.stderr.take();
    let read_out = async {
        let mut b = Vec::new();
        if let Some(o) = out.as_mut() {
            let _ = o.read_to_end(&mut b).await;
        }
        b
    };
    let read_err = async {
        let mut b = Vec::new();
        if let Some(e) = err.as_mut() {
            let _ = e.read_to_end(&mut b).await;
        }
        b
    };
    let fut = async {
        let (o, e, status) = tokio::join!(read_out, read_err, child.wait());
        (o, e, status)
    };
    match tokio::time::timeout(timeout, fut).await {
        Ok((o, e, status)) => Ok((
            status.ok().and_then(|s| s.code()),
            decode_output(&o),
            decode_output(&e),
            false,
        )),
        Err(_) => {
            kill.kill_tree();
            Ok((None, String::new(), String::new(), true))
        }
    }
}

/// Komut çıktısını çözer. Windows'ta UTF-8 değilse OEM kod sayfası (Türkçe: CP857) denenir.
pub fn decode_output(b: &[u8]) -> String {
    match std::str::from_utf8(b) {
        Ok(s) => s.to_string(),
        Err(_) => {
            #[cfg(windows)]
            {
                // CP857/CP1254 → en sık görülen Türkçe karakterler için basit eşleme.
                let mut s = String::with_capacity(b.len());
                for &c in b {
                    s.push(match c {
                        0x80 => 'Ç', 0x87 => 'ç', 0x81 => 'ü', 0x9A => 'Ü', 0x94 => 'ö', 0x99 => 'Ö',
                        0xA7 => 'ğ', 0xA6 => 'Ğ', 0x8D => 'ı', 0x98 => 'İ', 0x9F => 'ş', 0x9E => 'Ş',
                        c if c < 0x80 => c as char,
                        _ => '?',
                    });
                }
                s
            }
            #[cfg(not(windows))]
            String::from_utf8_lossy(b).into_owned()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn capture_and_timeout() {
        let paths = Paths::with_data_dir(tempfile::tempdir().unwrap().keep());
        let (prog, args): (&str, Vec<String>) = if cfg!(windows) {
            ("cmd", vec!["/C".into(), "echo merhaba".into()])
        } else {
            ("sh", vec!["-c".into(), "echo merhaba".into()])
        };
        let mut c = command(&paths, prog, &args);
        let (code, out, _, timed_out) = run_capture(&mut c, std::time::Duration::from_secs(20)).await.unwrap();
        assert_eq!(code, Some(0));
        assert!(out.contains("merhaba"));
        assert!(!timed_out);

        let (prog, args): (&str, Vec<String>) = if cfg!(windows) {
            ("powershell", vec!["-NoProfile".into(), "-Command".into(), "Start-Sleep 30".into()])
        } else {
            ("sh", vec!["-c".into(), "sleep 30".into()])
        };
        let mut c = command(&paths, prog, &args);
        let t = std::time::Instant::now();
        let (_, _, _, timed_out) = run_capture(&mut c, std::time::Duration::from_millis(1500)).await.unwrap();
        assert!(timed_out);
        assert!(t.elapsed().as_secs() < 10);
    }
}
