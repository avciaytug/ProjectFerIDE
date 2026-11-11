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

pub async fn probe(paths: &Paths, server: Option<&Path>) -> HardwareInfo {
    let (total, avail, cores, cpu_name) = tokio::task::spawn_blocking(ram_and_cpu).await.unwrap_or((16 << 30, 8 << 30, 4, String::new()));
    let mut gpus = vec![];
    if let Some(server) = server.filter(|_| !crate::winsec::engine_blocked()) {
        let mut cmd = crate::proc::command(paths, &server.to_string_lossy(), &["--list-devices".to_string()]);
        if let Ok((code, out, err, _)) = crate::proc::run_capture(&mut cmd, std::time::Duration::from_secs(25)).await {
            let all = format!("{out}\n{err}");
            if code != Some(0) {
                crate::winsec::note_engine_result(code, &all);
            }
            gpus = parse_list_devices(&all);
        }
    }
    gpus.retain(|g| !g.name.to_lowercase().contains("llvmpipe"));

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
