//! Sırlar (API anahtarları, Hugging Face jetonu).
//!
//! Windows'ta DPAPI ile kullanıcı hesabına bağlı şifrelenir; dosya başka bir
//! kullanıcıya ya da bilgisayara kopyalansa çözülemez. Unix'te yalnızca sahibinin
//! okuyabildiği (0600) bir dosyada tutulur. Sırlar hiçbir zaman arayüze geri gönderilmez;
//! arayüz yalnızca "tanımlı mı" bilgisini görür.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::Mutex;

pub struct Secrets {
    file: PathBuf,
    cache: Mutex<Option<BTreeMap<String, String>>>,
}

impl Secrets {
    pub fn new(file: PathBuf) -> Self {
        Self { file, cache: Mutex::new(None) }
    }

    fn load(&self) -> BTreeMap<String, String> {
        let Ok(raw) = std::fs::read(&self.file) else { return BTreeMap::new() };
        let Some(plain) = unprotect(&raw) else {
            tracing::warn!("sır dosyası çözülemedi (başka kullanıcı/bilgisayar?)");
            return BTreeMap::new();
        };
        serde_json::from_slice(&plain).unwrap_or_default()
    }

    fn with<R>(&self, f: impl FnOnce(&mut BTreeMap<String, String>) -> R) -> R {
        let mut g = self.cache.lock().unwrap();
        if g.is_none() {
            *g = Some(self.load());
        }
        f(g.as_mut().unwrap())
    }

    pub fn get(&self, key: &str) -> Option<String> {
        self.with(|m| m.get(key).cloned()).filter(|v| !v.is_empty())
    }

    pub fn is_set(&self, key: &str) -> bool {
        self.get(key).is_some()
    }

    pub fn keys(&self) -> Vec<String> {
        self.with(|m| m.keys().cloned().collect())
    }

    pub fn set(&self, key: &str, value: Option<&str>) -> anyhow::Result<()> {
        let data = self.with(|m| {
            match value {
                Some(v) if !v.is_empty() => {
                    m.insert(key.to_string(), v.to_string());
                }
                _ => {
                    m.remove(key);
                }
            }
            serde_json::to_vec(m)
        })?;
        let enc = protect(&data)?;
        crate::util::write_atomic(&self.file, &enc)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&self.file, std::fs::Permissions::from_mode(0o600));
        }
        Ok(())
    }
}

#[cfg(windows)]
fn protect(data: &[u8]) -> anyhow::Result<Vec<u8>> {
    use windows_sys::Win32::Foundation::LocalFree;
    use windows_sys::Win32::Security::Cryptography::{CryptProtectData, CRYPT_INTEGER_BLOB};
    unsafe {
        let input = CRYPT_INTEGER_BLOB { cbData: data.len() as u32, pbData: data.as_ptr() as *mut u8 };
        let mut out = CRYPT_INTEGER_BLOB { cbData: 0, pbData: std::ptr::null_mut() };
        let ok = CryptProtectData(
            &input,
            std::ptr::null(),
            std::ptr::null(),
            std::ptr::null(),
            std::ptr::null(),
            0,
            &mut out,
        );
        if ok == 0 {
            anyhow::bail!("DPAPI şifreleme başarısız: {}", std::io::Error::last_os_error());
        }
        let v = std::slice::from_raw_parts(out.pbData, out.cbData as usize).to_vec();
        LocalFree(out.pbData as _);
        let mut res = b"FDP1".to_vec();
        res.extend(v);
        Ok(res)
    }
}

#[cfg(windows)]
fn unprotect(raw: &[u8]) -> Option<Vec<u8>> {
    use windows_sys::Win32::Foundation::LocalFree;
    use windows_sys::Win32::Security::Cryptography::{CryptUnprotectData, CRYPT_INTEGER_BLOB};
    let body = raw.strip_prefix(b"FDP1")?;
    unsafe {
        let input = CRYPT_INTEGER_BLOB { cbData: body.len() as u32, pbData: body.as_ptr() as *mut u8 };
        let mut out = CRYPT_INTEGER_BLOB { cbData: 0, pbData: std::ptr::null_mut() };
        let ok = CryptUnprotectData(
            &input,
            std::ptr::null_mut(),
            std::ptr::null(),
            std::ptr::null(),
            std::ptr::null(),
            0,
            &mut out,
        );
        if ok == 0 {
            return None;
        }
        let v = std::slice::from_raw_parts(out.pbData, out.cbData as usize).to_vec();
        LocalFree(out.pbData as _);
        Some(v)
    }
}

#[cfg(not(windows))]
fn protect(data: &[u8]) -> anyhow::Result<Vec<u8>> {
    let mut v = b"FPL1".to_vec();
    v.extend_from_slice(data);
    Ok(v)
}

#[cfg(not(windows))]
fn unprotect(raw: &[u8]) -> Option<Vec<u8>> {
    raw.strip_prefix(b"FPL1").map(|b| b.to_vec())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip() {
        let dir = tempfile::tempdir().unwrap();
        let f = dir.path().join("s.bin");
        let s = Secrets::new(f.clone());
        s.set("hf_token", Some("abc123")).unwrap();
        assert!(!std::fs::read(&f).unwrap().windows(6).any(|w| w == b"abc123") || cfg!(not(windows)));
        let s2 = Secrets::new(f);
        assert_eq!(s2.get("hf_token").as_deref(), Some("abc123"));
        s2.set("hf_token", None).unwrap();
        assert!(!s2.is_set("hf_token"));
    }
}
