//! Windows güvenlik özellikleriyle uyum: Akıllı Uygulama Denetimi (Smart App Control) ve hata pencereleri.
//!
//! Akıllı Uygulama Denetimi açıkken Windows 11 yalnızca dijital olarak imzalı ya da Microsoft'un "bilinen iyi"
//! saydığı programları çalıştırır. llama.cpp gibi imzasız bileşenler yüklenirken "Bozuk Görüntü (0xc0e90002)"
//! hatası verir. FerIDE bunu tanır, kullanıcıya açıklar ve hata pencerelerinin art arda açılmasını önler.

/// Akıllı Uygulama Denetimi durumu: `Some(0)` kapalı, `Some(1)` açık (engeller), `Some(2)` değerlendirme
/// (engellemez). Windows dışı ve eski Windows'ta `None`.
pub fn smart_app_control() -> Option<u32> {
    // Test ve destek için: FERIDE_SAC_STATE=1 denetimi açıkmış gibi davranır.
    if let Some(v) = std::env::var("FERIDE_SAC_STATE").ok().and_then(|v| v.parse().ok()) {
        return Some(v);
    }
    #[cfg(windows)]
    {
        use windows_sys::Win32::System::Registry::{RegGetValueW, HKEY_LOCAL_MACHINE, RRF_RT_REG_DWORD};
        let key: Vec<u16> = "SYSTEM\\CurrentControlSet\\Control\\CI\\Policy\0".encode_utf16().collect();
        let name: Vec<u16> = "VerifiedAndReputablePolicyState\0".encode_utf16().collect();
        let mut data: u32 = 0;
        let mut size: u32 = 4;
        // SAFETY: arabellekler geçerli ve boyutları doğru; yalnızca okuma yapılır.
        let rc = unsafe {
            RegGetValueW(
                HKEY_LOCAL_MACHINE,
                key.as_ptr(),
                name.as_ptr(),
                RRF_RT_REG_DWORD,
                std::ptr::null_mut(),
                (&mut data as *mut u32).cast(),
                &mut size,
            )
        };
        if rc == 0 {
            return Some(data);
        }
        None
    }
    #[cfg(not(windows))]
    {
        None
    }
}

/// Akıllı Uygulama Denetimi açık ve imzasız programları engelliyor mu?
pub fn sac_enforced() -> bool {
    smart_app_control() == Some(1)
}

/// Kullanıcıya gösterilen açıklama ve çözüm.
pub const SAC_HELP: &str = "Windows'un Akıllı Uygulama Denetimi (Smart App Control) açık ve dijital olarak imzalanmamış \
programları engelliyor. FerIDE'nin kullandığı llama.cpp (model motoru) ve ses motorları henüz imzalı olmadığı için \
çalışamıyor (\"Bozuk Görüntü 0xc0e90002\" hatası). Çözüm: Windows Güvenlik → Uygulama ve tarayıcı denetimi → \
Akıllı Uygulama Denetimi ayarları → Kapalı; ardından FerIDE'yi yeniden başlatın. Windows'un Nisan 2026 ve sonraki \
güncellemelerinde bu ayar sonradan yeniden açılabilir.";

/// Alt süreçlerde Windows'un "Bozuk Görüntü" / "DLL bulunamadı" pencerelerini kapatır (alt süreçler hata kipini
/// devralır). Hata pencere yerine çıkış koduna dönüşür ve FerIDE onu açıklar; aksi halde her deneme (donanım
/// ölçümü, model başlatma) yeni bir pencere açar.
pub fn suppress_error_dialogs() {
    #[cfg(windows)]
    {
        use windows_sys::Win32::System::Diagnostics::Debug::{
            SetErrorMode, SEM_FAILCRITICALERRORS, SEM_NOGPFAULTERRORBOX, SEM_NOOPENFILEERRORBOX,
        };
        // SAFETY: yalnızca sürecin hata kipini ayarlar.
        unsafe {
            SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX | SEM_NOOPENFILEERRORBOX);
        }
    }
}

/// Windows Güvenlik'te "Uygulama ve tarayıcı denetimi" sayfasını açar.
pub fn open_security_settings() -> anyhow::Result<()> {
    #[cfg(windows)]
    {
        std::process::Command::new("explorer.exe").arg("windowsdefender://appbrowser").spawn()?;
        Ok(())
    }
    #[cfg(not(windows))]
    {
        anyhow::bail!("yalnızca Windows'ta")
    }
}

/// Bir sürecin çıkış kodu Akıllı Uygulama Denetimi / kod bütünlüğü engellemesi mi?
pub fn blocked_exit(exit_code: Option<i32>) -> bool {
    matches!(
        exit_code.map(|c| c as u32),
        Some(0xC0E9_0002) // Akıllı Uygulama Denetimi
            | Some(0xC000_0428) // STATUS_INVALID_IMAGE_HASH (kod bütünlüğü)
            | Some(0xC000_0603) // STATUS_INVALID_IMAGE_PROTECT
            | Some(0xC000_007B) // STATUS_INVALID_IMAGE_FORMAT ("Bozuk Görüntü")
    )
}

static ENGINE_BLOCKED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// llama.cpp bu oturumda Akıllı Uygulama Denetimi tarafından engellendi mi? Engellendiyse FerIDE onu yeniden
/// çalıştırmaz: her deneme Windows'ta yeni bir "Bozuk Görüntü" penceresi açar. Ayar kapatılıp FerIDE yeniden
/// başlatılınca sıfırlanır.
pub fn engine_blocked() -> bool {
    ENGINE_BLOCKED.load(std::sync::atomic::Ordering::Relaxed)
}

/// Bir llama.cpp çalıştırmasının sonucunu not eder; engelleme gibi görünüyorsa `true` döner.
pub fn note_engine_result(exit_code: Option<i32>, output: &str) -> bool {
    if likely_blocked(exit_code, output) {
        if !ENGINE_BLOCKED.swap(true, std::sync::atomic::Ordering::Relaxed) {
            tracing::warn!("llama.cpp Windows Akıllı Uygulama Denetimi tarafından engellendi (çıkış kodu {exit_code:?}); bu oturumda yeniden denenmeyecek");
        }
        return true;
    }
    false
}

/// Süreç hiçbir çıktı üretmeden başarısız olduysa ve denetim açıksa, büyük olasılıkla engellenmiştir.
pub fn likely_blocked(exit_code: Option<i32>, output: &str) -> bool {
    blocked_exit(exit_code) || (sac_enforced() && exit_code.is_some_and(|c| c != 0) && output.trim().len() < 40)
}
