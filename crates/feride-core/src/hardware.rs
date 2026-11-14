//! Donanım ölçümü: RAM, fiziksel çekirdek, GPU belleği.
//!
//! GPU belleği llama-server'ın kendi `--list-devices` çıktısından okunur; bu çıktı
//! Vulkan, CUDA, ROCm ve Metal için aynı biçimdedir ve sürücünün o an gerçekten
//! ayırabileceği belleği bildirir. RAM ve çekirdek `sysinfo` ile süreç içinde ölçülür
//! (v5.3.8'deki gibi her ölçümde PowerShell açılmaz).

use regex::Regex;
use serde::Serialize;
use std::collections::BTreeSet;
use std::path::Path;
use std::sync::LazyLock;

use crate::paths::Paths;

#[derive(Clone, Debug, Serialize)]
pub struct GpuDevice {
    /// Vulkan0, CUDA0, ROCm0, MTL0 …
    pub id: String,
    pub name: String,
    pub total_bytes: u64,
    pub free_bytes: u64,
}

impl GpuDevice {
    pub fn is_vulkan(&self) -> bool {
        self.id.starts_with("Vulkan")
    }
}

#[derive(Clone, Debug, Serialize)]
pub struct HardwareInfo {
    pub ram_total_bytes: u64,
    pub ram_available_bytes: u64,
    pub physical_cores: usize,
    pub gpus: Vec<GpuDevice>,
    /// GPU sistem RAM'ini paylaşıyor mu (AMD/Intel APU, Apple Silicon)?
    pub unified_memory: bool,
    /// Linux AMD APU: GPU'nun kullanabildiği üst sınır (GTT) ve önerilen değer.
    pub gpu_memory_limit_bytes: Option<u64>,
    pub suggested_gpu_memory_limit_bytes: Option<u64>,
    /// Paylaşımlı bellekli GPU'ya (APU) BIOS/sürücüyle ayrılmış, işletim sisteminin RAM olarak görmediği bellek
    /// (Windows: AMD Adrenalin "Değişken Grafik Belleği", Linux: amdgpu VRAM). GPU önce bu kısmı kullanır; model
    /// buraya sığdığı sürece RAM'den yer kaplamaz.
    pub dedicated_gpu_bytes: Option<u64>,
    /// Windows: kullanılabilir sanal bellek taahhüdü (RAM + sayfa dosyası − kullanılan). Windows GPU'ya yüklenen
    /// belleği de bu sınırdan düşer.
    pub commit_available_bytes: Option<u64>,
    pub os: String,
    pub cpu_name: String,
}

impl HardwareInfo {
    pub fn primary_gpu(&self) -> Option<&GpuDevice> {
        self.gpus.first()
    }

    pub fn can_raise_gpu_memory_limit(&self) -> bool {
        matches!((self.gpu_memory_limit_bytes, self.suggested_gpu_memory_limit_bytes),
            (Some(l), Some(s)) if s > l + (4u64 << 30))
    }

    pub fn describe(&self) -> String {
        use crate::util::gib;
        let g = match self.primary_gpu() {
            None => "GPU bulunamadı".to_string(),
            Some(g) => format!(
                "{} — {} GiB{}, {} GiB boş",
                g.name,
                gib(g.total_bytes),
                match (self.unified_memory, self.dedicated_gpu_bytes.filter(|d| *d >= 2 << 30)) {
                    (false, _) => String::new(),
                    (true, Some(d)) => format!(" ({} GiB ayrılmış, kalanı paylaşımlı)", gib(d)),
                    (true, None) => " (paylaşımlı)".to_string(),
                },
                gib(g.free_bytes)
            ),
        };
        format!(
            "{g} • RAM {} GiB ({} GiB boş) • {} çekirdek",
            gib(self.ram_total_bytes),
            gib(self.ram_available_bytes),
            self.physical_cores
        )
    }
}

static DEV_LINE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?m)^\s*([A-Za-z]+\d+):\s*(.+?)\s*\((\d+)\s*MiB,\s*(\d+)\s*MiB free\)").unwrap()
});

static UNIFIED_GPU: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)Radeon\(TM\) \d+M|Radeon \d{3,4}[MS]\b|8060S|8050S|890M|880M|780M|760M|740M|Vega \d+ Graphics|Intel\(R\) (Arc\(TM\) |Iris|UHD)|Intel.*Graphics|Apple").unwrap()
});

/// `llama-server --list-devices` çıktısını ayrıştırır.
pub fn parse_list_devices(out: &str) -> Vec<GpuDevice> {
    DEV_LINE
        .captures_iter(out)
        .map(|m| GpuDevice {
            id: m[1].to_string(),
            name: m[2].trim().to_string(),
            total_bytes: m[3].parse::<u64>().unwrap_or(0) << 20,
            free_bytes: m[4].parse::<u64>().unwrap_or(0) << 20,
        })
        .collect()
}

/// AMD GPU adından ROCm (gfx) ailesi: Lemonade'in ROCm derlemeleri GPU ailesine özel yayınlanır
/// (`llama-…-windows-rocm-gfx1151-x64.zip`). Bilinmeyen GPU için `None`.
pub fn rocm_family(gpu_name: &str) -> Option<&'static str> {
    let n = gpu_name.to_lowercase();
    if !n.contains("radeon") && !n.contains("amd") {
        return None;
    }
    let has = |xs: &[&str]| xs.iter().any(|x| n.contains(x));
    // Tümleşik (APU) GPU'lar: adlarında model numarası var.
    if has(&["8060s", "8050s", "8040s"]) {
        return Some("gfx1151"); // Strix Halo
    }
    if has(&["890m", "880m"]) {
        return Some("gfx1150"); // Strix Point
    }
    if has(&["860m", "840m", "820m"]) {
        return Some("gfx1152"); // Krackan Point
    }
    if has(&["780m", "760m", "740m"]) {
        return Some("gfx110X"); // Phoenix / Hawk Point (gfx1103)
    }
    if has(&["680m", "660m", "610m"]) {
        return Some("gfx103X"); // Rembrandt / Raphael (gfx1035/1036)
    }
    // Ayrık ekran kartları: RX 9000 → RDNA4, RX 7000 → RDNA3, RX 6000 → RDNA2.
    static RX: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"rx\s*([5-9])\d{3}").unwrap());
    if let Some(c) = RX.captures(&n) {
        return match &c[1] {
            "9" => Some("gfx120X"),
            "7" => Some("gfx110X"),
            "6" => Some("gfx103X"),
            _ => None,
        };
    }
    if has(&["ai pro r9700", "ai pro r9600"]) {
        return Some("gfx120X");
    }
    if has(&["pro w7", "pro w7900", "pro w7800"]) {
        return Some("gfx110X");
    }
    None
}

/// RAM ve işlemci bilgisi (hızlı, süreç içinde).
pub fn ram_and_cpu() -> (u64, u64, usize, String) {
    let mut sys = sysinfo::System::new();
    sys.refresh_memory();
    sys.refresh_cpu_all();
    let total = sys.total_memory();
    let avail = sys.available_memory();
    let logical = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4);
    let cores = sys.physical_core_count().filter(|c| *c > 0).unwrap_or(if logical >= 8 { logical / 2 } else { logical });
    let cpu = sys.cpus().first().map(|c| c.brand().trim().to_string()).unwrap_or_default();
    (total, avail, cores, cpu)
}

/// Kurulu llama-server'ın desteklediği seçenekler (`--help`). "ngl-all" sözde bayrağı,
/// `-ngl all` değerinin kabul edildiğini belirtir.
pub async fn llama_flags(paths: &Paths, server: &Path) -> BTreeSet<String> {
    static RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?:^|[^\w-])(--[a-z0-9][a-z0-9-]*)").unwrap());
    if crate::winsec::engine_blocked() {
        return BTreeSet::new();
    }
    let mut cmd = crate::proc::command(paths, &server.to_string_lossy(), &["--help".to_string()]);
    let Ok((code, out, err, _)) = crate::proc::run_capture(&mut cmd, std::time::Duration::from_secs(20)).await else {
        return BTreeSet::new();
    };
    if code != Some(0) && crate::winsec::note_engine_result(code, &format!("{out}{err}")) {
        return BTreeSet::new();
    }
    let help = format!("{out}\n{err}");
    let mut flags: BTreeSet<String> = RE.captures_iter(&help).map(|c| c[1].to_string()).collect();
    if help.contains("'all'") {
        flags.insert("ngl-all".into());
    }
    if flags.len() > 20 {
        flags
    } else {
        BTreeSet::new()
    }
}

/// GPU'ları `llama-server --list-devices` ile listeler. Sürücü o an meşgulse (az önce kapatılan bir modelin
/// belleği bırakılırken, Windows'ta virüs taraması sürerken…) liste bir kerelik boş ya da eksik gelebilir;
/// yanlışlıkla "GPU yok" deyip modeli işlemcide (10 kat yavaş) başlatmamak için birkaç kez denenir.
pub async fn list_gpus(paths: &Paths, server: &Path) -> Vec<GpuDevice> {
    const ATTEMPTS: u32 = 3;
    for attempt in 1..=ATTEMPTS {
        let mut cmd = crate::proc::command(paths, &server.to_string_lossy(), &["--list-devices".to_string()]);
        let (code, all, timed_out) = match crate::proc::run_capture(&mut cmd, std::time::Duration::from_secs(30)).await {
            Ok((code, out, err, timed_out)) => (code, format!("{out}\n{err}"), timed_out),
            Err(e) => (None, format!("başlatılamadı: {e}"), false),
        };
        if code.is_some_and(|c| c != 0) && crate::winsec::note_engine_result(code, &all) {
            return vec![];
        }
        let mut gpus = parse_list_devices(&all);
        gpus.retain(|g| !g.name.to_lowercase().contains("llvmpipe"));
        // Liste sorunsuz geldi ama boşsa ve bu bilgisayarda daha önce hiç GPU görülmediyse gerçekten GPU yoktur;
        // her ölçümde boşuna beklemeyelim. Daha önce görüldüyse boş liste geçici bir sürücü durumudur.
        let seen_marker = paths.cache().join("gpu-seen");
        let clean_empty = code == Some(0) && !timed_out && all.contains("Available devices") && !seen_marker.is_file();
        if !gpus.is_empty() {
            let _ = std::fs::create_dir_all(paths.cache());
            let _ = std::fs::write(&seen_marker, gpus[0].name.as_bytes());
        }
        if !gpus.is_empty() || clean_empty {
            if attempt > 1 {
                tracing::info!("GPU {attempt}. denemede bulundu: {} adet", gpus.len());
            }
            return gpus;
        }
        tracing::warn!(
            "GPU listesi alınamadı (deneme {attempt}/{ATTEMPTS}, çıkış {code:?}{}): {}",
            if timed_out { ", zaman aşımı" } else { "" },
            crate::util::truncate_end(all.trim(), 300)
        );
        if attempt < ATTEMPTS {
            tokio::time::sleep(std::time::Duration::from_millis(1500 * attempt as u64)).await;
        }
    }
    vec![]
}

pub async fn probe(paths: &Paths, server: Option<&Path>) -> HardwareInfo {
    let (total, avail, cores, cpu_name) = tokio::task::spawn_blocking(ram_and_cpu).await.unwrap_or((16 << 30, 8 << 30, 4, String::new()));
    let gpus = match server.filter(|_| !crate::winsec::engine_blocked()) {
        Some(server) => list_gpus(paths, server).await,
        None => vec![],
    };

    let linux_apu = linux_amd_apu_limits(total);
    let unified = cfg!(target_os = "macos") || linux_apu.is_some() || gpus.iter().any(|g| UNIFIED_GPU.is_match(&g.name));
    let dedicated = match gpus.first().filter(|_| unified) {
        Some(g) => {
            let name = g.name.clone();
            tokio::task::spawn_blocking(move || dedicated_gpu_memory(&name)).await.ok().flatten()
        }
        None => None,
    };
    HardwareInfo {
        ram_total_bytes: total,
        ram_available_bytes: avail,
        physical_cores: cores.max(1),
        gpus,
        unified_memory: unified,
        gpu_memory_limit_bytes: linux_apu.map(|l| l.0),
        suggested_gpu_memory_limit_bytes: linux_apu.map(|l| l.1),
        dedicated_gpu_bytes: dedicated,
        commit_available_bytes: commit_available(),
        os: format!("{} {}", std::env::consts::OS, std::env::consts::ARCH),
        cpu_name,
    }
}

/// Tümleşik GPU'ya ayrılmış (işletim sisteminin RAM olarak görmediği) bellek.
/// Windows: ekran kartı sürücüsünün kayıt defterindeki `HardwareInformation.qwMemorySize` (Görev Yöneticisi'ndeki
/// "Ayrılmış GPU belleği"; AMD Adrenalin'deki "Değişken Grafik Belleği" ayarı bunu değiştirir).
/// Linux: tek AMD GPU'nun `mem_info_vram_total` değeri. macOS'ta bellek gerçekten ortaktır: `None`.
#[allow(unused_variables)]
fn dedicated_gpu_memory(gpu_name: &str) -> Option<u64> {
    #[cfg(windows)]
    {
        windows_dedicated_vram(gpu_name)
    }
    #[cfg(target_os = "linux")]
    {
        let n = gpu_name.to_lowercase();
        if !n.contains("amd") && !n.contains("radeon") {
            return None;
        }
        let mut found = vec![];
        for e in std::fs::read_dir("/sys/class/drm").ok()?.flatten() {
            let name = e.file_name().to_string_lossy().to_string();
            if !name.starts_with("card") || !name[4..].chars().all(|c| c.is_ascii_digit()) {
                continue;
            }
            let dev = e.path().join("device");
            if std::fs::read_to_string(dev.join("vendor")).map(|v| v.trim() != "0x1002").unwrap_or(true) {
                continue;
            }
            if let Some(b) = std::fs::read_to_string(dev.join("mem_info_vram_total")).ok().and_then(|v| v.trim().parse::<u64>().ok()) {
                found.push(b);
            }
        }
        // Birden çok AMD GPU varsa hangisinin tümleşik olduğu bilinemez.
        (found.len() == 1).then(|| found[0])
    }
    #[cfg(not(any(windows, target_os = "linux")))]
    {
        None
    }
}

/// Windows'ta kullanılabilir sanal bellek taahhüdü (`GlobalMemoryStatusEx.ullAvailPageFile`).
fn commit_available() -> Option<u64> {
    #[cfg(windows)]
    {
        use windows_sys::Win32::System::SystemInformation::{GlobalMemoryStatusEx, MEMORYSTATUSEX};
        // SAFETY: yapı sıfırla doldurulup boyutu yazıldıktan sonra yalnızca okunmak üzere API'ye verilir.
        let mut m: MEMORYSTATUSEX = unsafe { std::mem::zeroed() };
        m.dwLength = std::mem::size_of::<MEMORYSTATUSEX>() as u32;
        if unsafe { GlobalMemoryStatusEx(&mut m) } != 0 {
            return Some(m.ullAvailPageFile);
        }
        None
    }
    #[cfg(not(windows))]
    {
        None
    }
}

/// Ad karşılaştırması için: küçük harf, "(TM)"/"(R)" ve harf/rakam dışı karakterler atılır.
#[cfg_attr(not(windows), allow(dead_code))]
fn gpu_name_key(s: &str) -> String {
    s.to_lowercase().replace("(tm)", "").replace("(r)", "").chars().filter(|c| c.is_ascii_alphanumeric()).collect()
}

#[cfg(windows)]
fn windows_dedicated_vram(gpu_name: &str) -> Option<u64> {
    use windows_sys::Win32::System::Registry::{RegGetValueW, HKEY_LOCAL_MACHINE, RRF_RT_ANY, RRF_RT_REG_SZ};
    const CLASS: &str = "SYSTEM\\CurrentControlSet\\Control\\Class\\{4d36e968-e325-11ce-bfc1-08002be10318}";
    let wide = |s: &str| -> Vec<u16> { s.encode_utf16().chain(std::iter::once(0)).collect() };
    let desc_name = wide("DriverDesc");
    let mem_name = wide("HardwareInformation.qwMemorySize");
    let want = gpu_name_key(gpu_name);
    let mut found: Vec<(String, u64)> = vec![];
    for i in 0..32 {
        let key = wide(&format!("{CLASS}\\{i:04}"));
        let mut buf = [0u16; 512];
        let mut size = (buf.len() * 2) as u32;
        // SAFETY: arabellekler geçerli ve boyutları doğru; yalnızca okuma yapılır.
        let rc = unsafe {
            RegGetValueW(
                HKEY_LOCAL_MACHINE,
                key.as_ptr(),
                desc_name.as_ptr(),
                RRF_RT_REG_SZ,
                std::ptr::null_mut(),
                buf.as_mut_ptr().cast(),
                &mut size,
            )
        };
        if rc != 0 {
            continue;
        }
        let len = (size as usize / 2).min(buf.len());
        let desc = String::from_utf16_lossy(&buf[..len]).trim_end_matches('\0').to_string();
        let mut mem: u64 = 0;
        let mut msize = 8u32;
        // SAFETY: 8 baytlık arabellek; değer QWORD (bazı sürücülerde 8 baytlık BINARY) olarak saklanır.
        let rc = unsafe {
            RegGetValueW(
                HKEY_LOCAL_MACHINE,
                key.as_ptr(),
                mem_name.as_ptr(),
                RRF_RT_ANY,
                std::ptr::null_mut(),
                (&mut mem as *mut u64).cast(),
                &mut msize,
            )
        };
        if rc == 0 && msize == 8 && mem > 0 {
            found.push((gpu_name_key(&desc), mem));
        }
    }
    found
        .iter()
        .find(|(d, _)| !d.is_empty() && (*d == want || want.contains(d.as_str()) || d.contains(want.as_str())))
        .map(|x| x.1)
        .or_else(|| (found.len() == 1).then(|| found[0].1))
}

/// Linux AMD APU (küçük VRAM + GTT): GPU'nun kullanabildiği bellek GTT'dir; çekirdek
/// varsayılanı RAM'in yarısı. Önerilen sınır: RAM − 12 GiB.
#[allow(unused_variables)]
fn linux_amd_apu_limits(ram_total: u64) -> Option<(u64, u64)> {
    #[cfg(target_os = "linux")]
    {
        let rd = std::fs::read_dir("/sys/class/drm").ok()?;
        for e in rd.flatten() {
            let name = e.file_name().to_string_lossy().to_string();
            if !name.starts_with("card") || !name[4..].chars().all(|c| c.is_ascii_digit()) {
                continue;
            }
            let dev = e.path().join("device");
            let (Ok(v), Ok(g)) = (
                std::fs::read_to_string(dev.join("mem_info_vram_total")),
                std::fs::read_to_string(dev.join("mem_info_gtt_total")),
            ) else {
                continue;
            };
            let (Ok(vram), Ok(gtt)) = (v.trim().parse::<u64>(), g.trim().parse::<u64>()) else { continue };
            if vram > (8u64 << 30) {
                continue; // ayrık ekran kartı
            }
            let suggested = ram_total.saturating_sub(12u64 << 30);
            return Some((gtt, suggested.max(gtt)));
        }
        None
    }
    #[cfg(not(target_os = "linux"))]
    None
}

#[cfg(test)]
mod name_tests {
    #[test]
    fn gpu_name_key() {
        assert_eq!(super::gpu_name_key("AMD Radeon(TM) 8060S Graphics"), "amdradeon8060sgraphics");
        assert_eq!(super::gpu_name_key("AMD Radeon 8060S Graphics"), "amdradeon8060sgraphics");
    }

    #[cfg(windows)]
    #[test]
    fn windows_registry_read_does_not_panic() {
        let _ = super::windows_dedicated_vram("AMD Radeon(TM) 8060S Graphics");
    }
}

#[cfg(test)]
mod rocm_tests {
    use super::rocm_family;

    #[test]
    fn families() {
        assert_eq!(rocm_family("AMD Radeon(TM) 8060S Graphics"), Some("gfx1151"));
        assert_eq!(rocm_family("AMD Radeon 890M Graphics"), Some("gfx1150"));
        assert_eq!(rocm_family("AMD Radeon(TM) 780M"), Some("gfx110X"));
        assert_eq!(rocm_family("AMD Radeon RX 7900 XTX"), Some("gfx110X"));
        assert_eq!(rocm_family("AMD Radeon RX 9070 XT"), Some("gfx120X"));
        assert_eq!(rocm_family("AMD Radeon RX 6800"), Some("gfx103X"));
        assert_eq!(rocm_family("NVIDIA GeForce RTX 4090"), None);
        assert_eq!(rocm_family("Intel(R) Arc(TM) Graphics"), None);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn list_devices() {
        let d = parse_list_devices(
            "Available devices:\n  Vulkan0: AMD Radeon 8060S Graphics (RADV STRIX_HALO) (64481 MiB, 5543 MiB free)\n  CUDA0: NVIDIA GeForce RTX 4090 (24563 MiB, 23400 MiB free)\n",
        );
        assert_eq!(d.len(), 2);
        assert_eq!(d[0].id, "Vulkan0");
        assert_eq!(d[0].total_bytes, 64481 << 20);
        assert_eq!(d[0].free_bytes, 5543 << 20);
        assert_eq!(d[1].name, "NVIDIA GeForce RTX 4090");
        assert!(UNIFIED_GPU.is_match(&d[0].name));
        assert!(!UNIFIED_GPU.is_match(&d[1].name));
    }

    #[test]
    fn ram_works() {
        let (t, a, c, _) = ram_and_cpu();
        assert!(t > 0 && a > 0 && a <= t && c > 0);
    }
}
