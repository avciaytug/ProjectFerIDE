//! Windows ile bütünleşme: Başlat menüsü ve masaüstü kısayolları, kullanıcı PATH'i, "Yüklü uygulamalar" kaydı,
//! yönetici olarak çalıştırma ve tek seferlik sistem ayarları.
//!
//! Hepsi doğrudan Windows API'siyle yapılır. Eskiden bu işler gizli pencerede `powershell -ExecutionPolicy Bypass
//! -EncodedCommand …` betikleriyle, yönetici adımı da gizli pencerede yönetici PowerShell'iyle yapılıyordu. Kötü
//! amaçlı yazılımların da kullandığı bu kalıplar yüzünden Microsoft Defender'ın makine öğrenmesi modeli FerIDE'yi
//! "Trojan:Win32/Bearfoos.B!ml" sanıp karantinaya aldı (2026-11-16). Artık FerIDE PowerShell çalıştırmaz.

use std::ffi::OsStr;
use std::os::windows::ffi::OsStrExt;
use std::path::{Path, PathBuf};

use windows_sys::Win32::System::Registry::{
    RegDeleteTreeW, RegGetValueW, RegSetKeyValueW, HKEY, HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE, REG_DWORD,
    REG_EXPAND_SZ, REG_SZ, RRF_NOEXPAND, RRF_RT_REG_EXPAND_SZ, RRF_RT_REG_SZ,
};

use crate::install::InstallInfo;

/// "Yüklü uygulamalar" kaydının yeri (HKCU; yönetici izni gerekmez).
pub const UNINSTALL_KEY: &str = r"Software\Microsoft\Windows\CurrentVersion\Uninstall\FerIDE";

fn wide(s: &OsStr) -> Vec<u16> {
    s.encode_wide().chain(std::iter::once(0)).collect()
}

fn wide_str(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

fn win_err(code: u32) -> std::io::Error {
    std::io::Error::from_raw_os_error(code as i32)
}

// ------------------------------------------------------------------ kayıt defteri yardımcıları

fn reg_set(root: HKEY, key: &str, name: &str, kind: u32, data: &[u8]) -> std::io::Result<()> {
    let (k, n) = (wide_str(key), wide_str(name));
    // SAFETY: anahtar/değer adları sıfırla biten UTF-16; veri arabelleği ve boyutu birlikte verilir.
    let rc = unsafe { RegSetKeyValueW(root, k.as_ptr(), n.as_ptr(), kind, data.as_ptr().cast(), data.len() as u32) };
    if rc == 0 {
        Ok(())
    } else {
        Err(win_err(rc))
    }
}

fn reg_set_text(root: HKEY, key: &str, name: &str, kind: u32, value: &str) -> std::io::Result<()> {
    let bytes: Vec<u8> = wide_str(value).iter().flat_map(|u| u.to_le_bytes()).collect();
    reg_set(root, key, name, kind, &bytes)
}

/// Metin değeri ham hâliyle (%DEĞİŞKEN%'ler genişletilmeden) ve türüyle okur; değer yoksa `Ok(None)`.
fn reg_get_text(root: HKEY, key: &str, name: &str) -> std::io::Result<Option<(String, u32)>> {
    let (k, n) = (wide_str(key), wide_str(name));
    let flags = RRF_RT_REG_SZ | RRF_RT_REG_EXPAND_SZ | RRF_NOEXPAND;
    let mut kind = 0u32;
    let mut size = 0u32;
    // SAFETY: önce yalnızca boyut sorulur, sonra o boyutta arabelleğe okunur.
    let rc = unsafe { RegGetValueW(root, k.as_ptr(), n.as_ptr(), flags, &mut kind, std::ptr::null_mut(), &mut size) };
    if rc == 2 {
        return Ok(None); // ERROR_FILE_NOT_FOUND
    }
    if rc != 0 {
        return Err(win_err(rc));
    }
    let mut buf = vec![0u16; (size as usize).div_ceil(2) + 1];
    let mut size = (buf.len() * 2) as u32;
    // SAFETY: arabellek ve boyutu birlikte verilir.
    let rc = unsafe { RegGetValueW(root, k.as_ptr(), n.as_ptr(), flags, &mut kind, buf.as_mut_ptr().cast(), &mut size) };
    if rc != 0 {
        return Err(win_err(rc));
    }
    let len = (size as usize / 2).min(buf.len());
    let text = String::from_utf16_lossy(&buf[..len]).trim_end_matches('\0').to_string();
    Ok(Some((text, kind)))
}

// ------------------------------------------------------------------ "Yüklü uygulamalar" kaydı

/// Kaldırma kaydının değerlerini yazar (anahtar yoksa oluşturulur). `fresh`: yeni kurulum; kurulum tarihi de yazılır
/// (güncellemede korunur).
pub fn write_uninstall_entry(key: &str, info: &InstallInfo, exe: &Path, fresh: bool) -> std::io::Result<()> {
    let root = HKEY_CURRENT_USER;
    let exe_s = exe.to_string_lossy();
    let text = |name: &str, value: &str| reg_set_text(root, key, name, REG_SZ, value);
    let dword = |name: &str, value: u32| reg_set(root, key, name, REG_DWORD, &value.to_le_bytes());
    text("DisplayName", "FerIDE")?;
    text("DisplayVersion", &info.version)?;
    text("Publisher", "ProjectFerIDE")?;
    text("DisplayIcon", &format!("{exe_s},0"))?;
    text("InstallLocation", &info.install_dir.to_string_lossy())?;
    text("UninstallString", &format!("\"{exe_s}\" uninstall"))?;
    text("QuietUninstallString", &format!("\"{exe_s}\" uninstall --yes"))?;
    text("URLInfoAbout", "https://github.com/avciaytug/ProjectFerIDE")?;
    if fresh {
        text("InstallDate", &chrono::Local::now().format("%Y%m%d").to_string())?;
    }
    dword("NoModify", 1)?;
    dword("NoRepair", 1)?;
    dword("EstimatedSize", (std::fs::metadata(exe).map(|m| m.len() / 1024).unwrap_or(0)).min(u32::MAX as u64) as u32)?;
    Ok(())
}

/// Kaldırma kaydını siler; başka bir klasöre kurulmuş FerIDE'nin kaydıysa dokunmaz.
pub fn remove_uninstall_entry(key: &str, install_dir: &Path) -> std::io::Result<()> {
    let location = match reg_get_text(HKEY_CURRENT_USER, key, "InstallLocation") {
        Ok(v) => v.map(|v| v.0),
        Err(e) if e.raw_os_error() == Some(2) => return Ok(()), // anahtar yok
        Err(e) => return Err(e),
    };
    if location.as_deref().is_some_and(|l| !l.is_empty() && !same_dir_text(l, &install_dir.to_string_lossy())) {
        return Ok(());
    }
    let k = wide_str(key);
    // SAFETY: yalnızca FerIDE'nin kendi kaldırma anahtarı silinir.
    let rc = unsafe { RegDeleteTreeW(HKEY_CURRENT_USER, k.as_ptr()) };
    if rc == 0 || rc == 2 {
        Ok(())
    } else {
        Err(win_err(rc))
    }
}

fn same_dir_text(a: &str, b: &str) -> bool {
    a.trim_end_matches('\\').to_lowercase() == b.trim_end_matches('\\').to_lowercase()
}

// ------------------------------------------------------------------ kullanıcı PATH'i

/// PATH'e `dir` eklenmiş hâli; zaten varsa `None`. Diğer girdilere (boş olanlar dahil) dokunulmaz.
pub fn path_with(value: &str, dir: &str, expand: impl Fn(&str) -> String) -> Option<String> {
    if value.split(';').any(|e| !e.is_empty() && same_dir_text(&expand(e), dir)) {
        return None;
    }
    Some(if value.is_empty() || value.ends_with(';') { format!("{value}{dir}") } else { format!("{value};{dir}") })
}

/// PATH'ten `dir` çıkarılmış hâli; hiç yoksa `None` (değer hiç yeniden yazılmaz). Diğer girdiler olduğu gibi kalır.
pub fn path_without(value: &str, dir: &str, expand: impl Fn(&str) -> String) -> Option<String> {
    let parts: Vec<&str> = value.split(';').collect();
    let keep: Vec<&str> = parts.iter().copied().filter(|e| e.is_empty() || !same_dir_text(&expand(e), dir)).collect();
    (keep.len() != parts.len()).then(|| keep.join(";"))
}

fn expand_env(s: &str) -> String {
    use windows_sys::Win32::System::Environment::ExpandEnvironmentStringsW;
    let src = wide_str(s);
    let mut buf = vec![0u16; 4096];
    // SAFETY: kaynak sıfırla biter; hedef arabelleğin boyutu verilir.
    let n = unsafe { ExpandEnvironmentStringsW(src.as_ptr(), buf.as_mut_ptr(), buf.len() as u32) } as usize;
    if n == 0 || n > buf.len() {
        return s.to_string();
    }
    String::from_utf16_lossy(&buf[..n.saturating_sub(1)])
}

/// Ortam değişkenleri değişti: açık uygulamalara (Gezgin, yeni terminaller) duyurulur.
fn broadcast_environment_change() {
    use windows_sys::Win32::UI::WindowsAndMessaging::{SendMessageTimeoutW, HWND_BROADCAST, SMTO_ABORTIFHUNG, WM_SETTINGCHANGE};
    let env = wide_str("Environment");
    let mut result = 0usize;
    // SAFETY: duyuru metni çağrı süresince yaşar; yanıt vermeyen pencereler en çok 5 sn bekletir.
    unsafe {
        SendMessageTimeoutW(HWND_BROADCAST, WM_SETTINGCHANGE, 0, env.as_ptr() as isize, SMTO_ABORTIFHUNG, 5000, &mut result);
    }
}

const ENV_KEY: &str = "Environment";

/// Program klasörünü kullanıcı PATH'ine ekler (değer türü ve diğer girdiler korunur).
pub fn user_path_add(dir: &Path) -> std::io::Result<()> {
    let (value, kind) = reg_get_text(HKEY_CURRENT_USER, ENV_KEY, "Path")?.unwrap_or((String::new(), REG_EXPAND_SZ));
    if let Some(new) = path_with(&value, &dir.to_string_lossy(), expand_env) {
        reg_set_text(HKEY_CURRENT_USER, ENV_KEY, "Path", kind, &new)?;
        broadcast_environment_change();
    }
    Ok(())
}

/// Program klasörünü kullanıcı PATH'inden çıkarır; PATH'te yoksa hiçbir şeye dokunmaz.
pub fn user_path_remove(dir: &Path) -> std::io::Result<()> {
    let Some((value, kind)) = reg_get_text(HKEY_CURRENT_USER, ENV_KEY, "Path")? else { return Ok(()) };
    if let Some(new) = path_without(&value, &dir.to_string_lossy(), expand_env) {
        reg_set_text(HKEY_CURRENT_USER, ENV_KEY, "Path", kind, &new)?;
        broadcast_environment_change();
    }
    Ok(())
}

// ------------------------------------------------------------------ kısayollar (IShellLink)

/// Başlat menüsünün "Programlar" klasörü.
pub fn start_menu_programs() -> Option<PathBuf> {
    known_folder(&windows::Win32::UI::Shell::FOLDERID_Programs)
}

/// Masaüstü klasörü (OneDrive'a taşınmışsa oradaki).
pub fn desktop() -> Option<PathBuf> {
    known_folder(&windows::Win32::UI::Shell::FOLDERID_Desktop)
}

fn known_folder(id: &windows::core::GUID) -> Option<PathBuf> {
    use windows::Win32::System::Com::CoTaskMemFree;
    use windows::Win32::UI::Shell::{SHGetKnownFolderPath, KF_FLAG_DEFAULT};
    // SAFETY: Windows'un ayırdığı metin okunduktan sonra serbest bırakılır.
    unsafe {
        let p = SHGetKnownFolderPath(id, KF_FLAG_DEFAULT, None).ok()?;
        let s = p.to_string().ok();
        CoTaskMemFree(Some(p.0 as *const _));
        s.map(PathBuf::from)
    }
}

/// COM nesneleri ayrı bir iş parçacığında (tek iş parçacıklı daire) kullanılır; çağıranın COM durumundan bağımsızdır.
fn with_com<T: Send + 'static>(f: impl FnOnce() -> windows::core::Result<T> + Send + 'static) -> anyhow::Result<T> {
    std::thread::spawn(move || {
        use windows::Win32::System::Com::{CoInitializeEx, CoUninitialize, COINIT_APARTMENTTHREADED};
        // SAFETY: bu iş parçacığına ait COM başlatılır ve iş bitince kapatılır.
        let hr = unsafe { CoInitializeEx(None, COINIT_APARTMENTTHREADED) };
        let r = f();
        if hr.is_ok() {
            unsafe { CoUninitialize() };
        }
        r
    })
    .join()
    .map_err(|_| anyhow::anyhow!("kısayol iş parçacığı beklenmedik biçimde sonlandı"))?
    .map_err(|e| anyhow::anyhow!("{e}"))
}

/// `.lnk` kısayolu oluşturur (ya da üzerine yazar).
pub fn create_shortcut(lnk: &Path, target: &Path, workdir: &Path, description: &str) -> anyhow::Result<()> {
    let (lnk, target, workdir, description) = (lnk.to_path_buf(), target.to_path_buf(), workdir.to_path_buf(), description.to_string());
    with_com(move || {
        use windows::core::{Interface, HSTRING};
        use windows::Win32::System::Com::{CoCreateInstance, IPersistFile, CLSCTX_INPROC_SERVER};
        use windows::Win32::UI::Shell::{IShellLinkW, ShellLink};
        // SAFETY: COM arayüzleri windows kütüphanesinin güvenli sarmalayıcılarıyla kullanılır; metinler HSTRING.
        unsafe {
            let link: IShellLinkW = CoCreateInstance(&ShellLink, None, CLSCTX_INPROC_SERVER)?;
            link.SetPath(&HSTRING::from(target.as_os_str()))?;
            link.SetWorkingDirectory(&HSTRING::from(workdir.as_os_str()))?;
            link.SetIconLocation(&HSTRING::from(target.as_os_str()), 0)?;
            link.SetDescription(&HSTRING::from(description.as_str()))?;
            let file: IPersistFile = link.cast()?;
            file.Save(&HSTRING::from(lnk.as_os_str()), true)?;
        }
        Ok(())
    })
}

/// Kısayolun gösterdiği program (okunamazsa `None`).
pub fn shortcut_target(lnk: &Path) -> Option<PathBuf> {
    let lnk = lnk.to_path_buf();
    with_com(move || {
        use windows::core::{Interface, HSTRING};
        use windows::Win32::System::Com::{CoCreateInstance, IPersistFile, CLSCTX_INPROC_SERVER, STGM_READ};
        use windows::Win32::UI::Shell::{IShellLinkW, ShellLink, SLGP_RAWPATH};
        // SAFETY: arabellek GetPath'e diliminin boyutuyla verilir.
        unsafe {
            let link: IShellLinkW = CoCreateInstance(&ShellLink, None, CLSCTX_INPROC_SERVER)?;
            let file: IPersistFile = link.cast()?;
            file.Load(&HSTRING::from(lnk.as_os_str()), STGM_READ)?;
            let mut buf = [0u16; 1024];
            link.GetPath(&mut buf, std::ptr::null_mut(), SLGP_RAWPATH.0 as u32)?;
            let n = buf.iter().position(|c| *c == 0).unwrap_or(buf.len());
            Ok(PathBuf::from(String::from_utf16_lossy(&buf[..n])))
        }
    })
    .ok()
    .filter(|p| !p.as_os_str().is_empty())
}

// ------------------------------------------------------------------ yönetici izni

/// Programı yönetici olarak (UAC onayıyla) çalıştırır ve bitmesini bekler. Çıkış kodunu döner; kullanıcı onayı
/// reddederse `Ok(None)`. Bekler; zaman uyumsuz kodda `spawn_blocking` ile çağrılmalı.
pub fn run_elevated(exe: &Path, params: &str) -> std::io::Result<Option<u32>> {
    use windows_sys::Win32::Foundation::{CloseHandle, GetLastError};
    use windows_sys::Win32::System::Threading::{GetExitCodeProcess, WaitForSingleObject, INFINITE};
    use windows_sys::Win32::UI::Shell::{ShellExecuteExW, SEE_MASK_NOCLOSEPROCESS, SHELLEXECUTEINFOW};
    use windows_sys::Win32::UI::WindowsAndMessaging::SW_SHOWNORMAL;
    let verb = wide_str("runas");
    let file = wide(exe.as_os_str());
    let params_w = wide_str(params);
    // SAFETY: yapı sıfırla doldurulur, metinler çağrı boyunca yaşar; süreç tanıtıcısı beklenip kapatılır.
    unsafe {
        let mut info: SHELLEXECUTEINFOW = std::mem::zeroed();
        info.cbSize = std::mem::size_of::<SHELLEXECUTEINFOW>() as u32;
        info.fMask = SEE_MASK_NOCLOSEPROCESS;
        info.lpVerb = verb.as_ptr();
        info.lpFile = file.as_ptr();
        info.lpParameters = params_w.as_ptr();
        info.nShow = SW_SHOWNORMAL;
        if ShellExecuteExW(&mut info) == 0 {
            let err = GetLastError();
            if err == 1223 {
                return Ok(None); // ERROR_CANCELLED: kullanıcı onay vermedi
            }
            return Err(win_err(err));
        }
        if info.hProcess.is_null() {
            return Ok(Some(0));
        }
        WaitForSingleObject(info.hProcess, INFINITE);
        let mut code = 0u32;
        GetExitCodeProcess(info.hProcess, &mut code);
        CloseHandle(info.hProcess);
        Ok(Some(code))
    }
}

/// Windows'ta 260 karakterden uzun yolları açar (HKLM; yönetici olarak çalışan süreçte çağrılır).
pub fn enable_long_paths() -> std::io::Result<()> {
    reg_set(HKEY_LOCAL_MACHINE, r"SYSTEM\CurrentControlSet\Control\FileSystem", "LongPathsEnabled", REG_DWORD, &1u32.to_le_bytes())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn no_expand(s: &str) -> String {
        s.replace("%LOCALAPPDATA%", r"C:\Users\x\AppData\Local")
    }

    #[test]
    fn path_add_and_remove_keep_other_entries() {
        let dir = r"C:\Users\x\FerIDE";
        // Kullanıcının PATH'indeki boş girdi (;;) korunur.
        let v = r"C:\a;;C:\b";
        let added = path_with(v, dir, no_expand).unwrap();
        assert_eq!(added, r"C:\a;;C:\b;C:\Users\x\FerIDE");
        assert_eq!(path_with(&added, dir, no_expand), None, "ikinci kez eklenmez");
        assert_eq!(path_with(r"C:\a;C:\USERS\X\FERIDE\;C:\b", dir, no_expand), None, "büyük/küçük harf ve \\ fark etmez");
        assert_eq!(path_with("", dir, no_expand).unwrap(), dir);
        assert_eq!(path_with(r"C:\a;", dir, no_expand).unwrap(), r"C:\a;C:\Users\x\FerIDE");
        assert_eq!(path_without(&added, dir, no_expand).unwrap(), v);
        assert_eq!(path_without(v, dir, no_expand), None, "bizim girdimiz yoksa PATH'e dokunulmaz");
        // %DEĞİŞKEN%'li yazılmış girdi de tanınır ve yalnızca o çıkarılır.
        let w = r"%LOCALAPPDATA%\Programs\FerIDE;C:\a";
        assert_eq!(path_without(w, r"C:\Users\x\AppData\Local\Programs\FerIDE", no_expand).unwrap(), r"C:\a");
    }

    #[test]
    fn shortcut_roundtrip() {
        let d = std::env::temp_dir().join(format!("feride-lnk-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        let target = d.join("hedef program.exe");
        std::fs::write(&target, b"MZ").unwrap();
        let lnk = d.join("FerIDE.lnk");
        create_shortcut(&lnk, &target, &d, "FerIDE - deneme").unwrap();
        assert!(lnk.is_file());
        let got = shortcut_target(&lnk).expect("hedef okunamadı");
        assert!(crate::install::same_path(&got, &target), "{got:?}");
        assert!(shortcut_target(&d.join("yok.lnk")).is_none());
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn known_folders_exist() {
        assert!(start_menu_programs().is_some_and(|p| p.is_absolute()));
        assert!(desktop().is_some_and(|p| p.is_absolute()));
    }

    /// Gerçek kayda değil, test için açılan ayrı anahtarlara yazar ve siler.
    #[test]
    fn uninstall_entry_write_and_guarded_remove() {
        let key = format!(r"Software\FerIDE-test-winint-{}", std::process::id());
        let dir = std::env::temp_dir().join(format!("feride-reg-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let exe = dir.join("feride.exe");
        std::fs::write(&exe, vec![0u8; 2048]).unwrap();
        let info = InstallInfo {
            version: "5.4.0-beta.99".into(),
            install_dir: dir.clone(),
            data_dir: dir.clone(),
            desktop_shortcut: false,
            menu_shortcut: false,
            add_path: false,
            installed_at: String::new(),
        };
        write_uninstall_entry(&key, &info, &exe, true).unwrap();
        assert_eq!(reg_get_text(HKEY_CURRENT_USER, &key, "DisplayVersion").unwrap().unwrap().0, "5.4.0-beta.99");
        assert!(reg_get_text(HKEY_CURRENT_USER, &key, "InstallDate").unwrap().is_some());
        // Başka klasöre kurulu FerIDE'nin kaydı silinmez.
        remove_uninstall_entry(&key, Path::new(r"C:\baska\yer")).unwrap();
        assert!(reg_get_text(HKEY_CURRENT_USER, &key, "DisplayVersion").unwrap().is_some());
        remove_uninstall_entry(&key, &dir).unwrap();
        assert!(reg_get_text(HKEY_CURRENT_USER, &key, "DisplayVersion").unwrap().is_none());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
