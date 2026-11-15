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

/// Kullanıcıya gösterilen açıklama ve çözüm (yalnızca bir bileşen gerçekten engellendiğinde gösterilir).
pub const SAC_HELP: &str = "Windows'un Akıllı Uygulama Denetimi (Smart App Control), FerIDE'nin kullandığı ve henüz \
dijital olarak imzalanmamış bir bileşeni (llama.cpp model motoru ya da ses motoru) engelledi (\"Bozuk Görüntü \
0xc0e90002\" hatası). Çözüm: Windows Güvenlik → Uygulama ve tarayıcı denetimi → Akıllı Uygulama Denetimi ayarları → \
Kapalı; ardından FerIDE'yi yeniden başlatın. Windows'un Nisan 2026 ve sonraki güncellemelerinde bu ayar sonradan \
yeniden açılabilir.";

/// llama.cpp'nin kullanmadığı arka uç kitaplıklarının taşındığı alt klasör (llama.cpp alt klasörlere bakmaz).
pub const UNUSED_BACKENDS_DIR: &str = "kullanilmayan";

/// llama.cpp her açılışta klasöründeki bütün işlemci çeşitlerini (`ggml-cpu-*.dll`, ~14 adet) ve RPC arka ucunu tek
/// tek yükleyip en uygununu seçer. Akıllı Uygulama Denetimi açık bilgisayarlarda Windows bunlardan itibarı
/// olmayanları engeller ve her açılışta "Bu uygulamanın bir kısmı engellendi" bildirimi gösterir — işlemcinin zaten
/// kullanamadığı bir çeşit (ör. AVX-512'siz işlemcide `ggml-cpu-skylakex.dll`) için bile. Bu bilgisayarda gerçekten
/// yüklenen çeşit `--list-devices` çıktısından ("loaded CPU backend from …") öğrenilince geri kalanlar ve RPC arka ucu
/// (FerIDE kullanmaz) [`UNUSED_BACKENDS_DIR`] alt klasörüne taşınır; silinmez. Taşınan dosya sayısını döner.
pub fn prune_llama_backends(server: &std::path::Path, output: &str) -> usize {
    if !cfg!(windows) {
        return 0;
    }
    let Some(dir) = server.parent() else { return 0 };
    let Some(loaded) = output.lines().find_map(|l| l.split("loaded CPU backend from ").nth(1)).map(|p| std::path::PathBuf::from(p.trim())) else {
        return 0;
    };
    // Yalnızca llama-server'ın kendi klasöründen yüklendiyse (çalışma klasöründen değil) dokun.
    let same_dir = loaded.parent().map(|p| crate::install::same_path(p, dir)).unwrap_or(false);
    let Some(keep) = loaded.file_name().map(|n| n.to_string_lossy().to_lowercase()).filter(|_| same_dir) else {
        return 0;
    };
    let Ok(rd) = std::fs::read_dir(dir) else { return 0 };
    let unused = dir.join(UNUSED_BACKENDS_DIR);
    let mut moved = 0;
    for e in rd.flatten() {
        let name = e.file_name().to_string_lossy().to_lowercase();
        let cpu_variant = name.starts_with("ggml-cpu-") && name.ends_with(".dll") && name != keep;
        if !(cpu_variant || name == "ggml-rpc.dll") || !e.path().is_file() {
            continue;
        }
        if std::fs::create_dir_all(&unused).is_ok() && std::fs::rename(e.path(), unused.join(e.file_name())).is_ok() {
            moved += 1;
        }
    }
    if moved > 0 {
        tracing::info!("llama.cpp: bu işlemcide {keep} kullanılıyor; kullanılmayan {moved} arka uç kitaplığı {} klasörüne taşındı", unused.display());
    }
    moved
}

/// Klasörde hiç işlemci arka ucu kalmadıysa (ör. kullanılan dosya silindi) taşınanları geri getirir; llama.cpp
/// işlemci arka ucu olmadan çalışmaz.
pub fn restore_llama_backends(server: &std::path::Path) {
    let Some(dir) = server.parent() else { return };
    let unused = dir.join(UNUSED_BACKENDS_DIR);
    if !unused.is_dir() {
        return;
    }
    let has_cpu = std::fs::read_dir(dir)
        .map(|rd| rd.flatten().any(|e| e.file_name().to_string_lossy().to_lowercase().starts_with("ggml-cpu")))
        .unwrap_or(true);
    if has_cpu {
        return;
    }
    if let Ok(rd) = std::fs::read_dir(&unused) {
        for e in rd.flatten() {
            let _ = std::fs::rename(e.path(), dir.join(e.file_name()));
        }
    }
    tracing::warn!("llama.cpp işlemci arka ucu eksikti; taşınan kitaplıklar geri getirildi");
}

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
