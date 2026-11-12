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
                if self.unified_memory { " (paylaşımlı)" } else { "" },
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
    HardwareInfo {
        ram_total_bytes: total,
        ram_available_bytes: avail,
        physical_cores: cores.max(1),
        gpus,
        unified_memory: unified,
        gpu_memory_limit_bytes: linux_apu.map(|l| l.0),
        suggested_gpu_memory_limit_bytes: linux_apu.map(|l| l.1),
        os: format!("{} {}", std::env::consts::OS, std::env::consts::ARCH),
        cpu_name,
    }
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
