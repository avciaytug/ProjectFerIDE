//! Bellek-farkında model başlatma planlayıcısı (v5.3.8'den birebir taşındı).
//!
//! Temel kural: sığmayacak bir yapılandırma ASLA başlatılmaz. Paylaşımlı bellekli
//! sistemlerde (AMD Strix Halo, Apple Silicon) GPU belleği masaüstü, tarayıcı ve
//! FerIDE ile ortaktır; GPU belleği tamamen dolarsa bu uygulamalar çöker. Bu yüzden
//! her zaman bir güvenlik payı bırakılır.

use serde::Serialize;
use std::collections::BTreeSet;

use crate::config::ComputeMode;
use crate::gguf::GgufInfo;
use crate::hardware::HardwareInfo;

pub const GIB: i64 = 1 << 30;
pub const CTX_STEPS: [i64; 6] = [131072, 65536, 32768, 16384, 8192, 4096];
/// Ajanın rahat çalışması için en küçük bağlam (talimat + araç tanımları ~5K token).
pub const MIN_AGENT_CTX: i64 = 16384;
pub const COMPUTE_OVERHEAD: i64 = 3 * GIB / 2;
pub const RAM_SAFETY: i64 = 4 * GIB;

#[derive(Clone, Debug, Serialize)]
pub struct LaunchPlan {
    pub mode: ComputeMode,
    /// gpu | mixed | moe-cpu | cpu
    pub placement: String,
    pub ctx: i64,
    pub args: Vec<String>,
    pub summary: String,
    pub warnings: Vec<String>,
    /// Doluysa model başlatılmaz; kullanıcıya bu açıklama gösterilir.
    pub blocker: Option<String>,
}

impl LaunchPlan {
    pub fn can_start(&self) -> bool {
        self.blocker.is_none()
    }
}

fn g(bytes: i64) -> String {
    format!("{:.1}", bytes as f64 / GIB as f64).replace('.', ",")
}
fn k(ctx: i64) -> String {
    format!("{}K", ctx / 1024)
}
fn s(v: &[&str]) -> Vec<String> {
    v.iter().map(|x| x.to_string()).collect()
}

pub struct PlanInput<'a> {
    pub model_bytes: i64,
    pub info: Option<&'a GgufInfo>,
    pub hw: &'a HardwareInfo,
    pub mode: ComputeMode,
    pub requested_ctx: i64,
    pub extra_gpu_bytes: i64,
    /// Kurulu llama-server'ın desteklediği seçenekler; boşsa güncel sürüm varsayılır.
    pub flags: &'a BTreeSet<String>,
}

pub fn plan(inp: PlanInput) -> LaunchPlan {
    let PlanInput { model_bytes, info, hw, mode, requested_ctx, extra_gpu_bytes, flags } = inp;
    let has = |f: &str| flags.is_empty() || flags.contains(f);
    let no_mmap: Vec<String> = if has("--load-mode") {
        s(&["--load-mode", "none"])
    } else if has("--no-mmap") {
        s(&["--no-mmap"])
    } else {
        vec![]
    };
    let ngl_all = if has("ngl-all") { "all" } else { "999" };
    let no_host: Vec<String> = if has("--no-host") { s(&["--no-host"]) } else { vec![] };
    let cpu_moe: Vec<String> = if has("--cpu-moe") {
        s(&["--cpu-moe"])
    } else {
        s(&["-ot", r"\.ffn_(up|down|gate)_exps\.=CPU"])
    };
    let can_fit = has("--fit");
    let weights = info.map(|i| i.weight_bytes as i64).unwrap_or(model_bytes);
    let train_ctx = info.map(|i| i.context_length as i64).unwrap_or(0);
    let kv = |c: i64| -> i64 { info.map(|i| i.kv_bytes(c as u64) as i64).unwrap_or(c * 128 * 1024) };
    let overhead = COMPUTE_OVERHEAD + extra_gpu_bytes;
    let threads = vec!["-t".to_string(), hw.physical_cores.max(1).to_string()];

    let mut cands: Vec<i64> = if requested_ctx > 0 {
        vec![if train_ctx > 0 { requested_ctx.min(train_ctx) } else { requested_ctx }]
    } else {
        CTX_STEPS.iter().copied().filter(|c| train_ctx <= 0 || *c <= train_ctx).collect()
    };
    if cands.is_empty() {
        cands.push(if train_ctx > 0 { 4096.min(train_ctx) } else { 4096 });
    }
    let fixed_ctx = requested_ctx > 0;
    let last = *cands.last().unwrap();
    let floor = cands.iter().copied().find(|c| *c <= MIN_AGENT_CTX).unwrap_or(last);
    let small_ctx_warning = |c: i64| -> Option<String> {
        (c < MIN_AGENT_CTX && !fixed_ctx).then(|| {
            format!(
                "Bağlam yalnızca {}: bellek daha fazlasına yetmiyor. FerIDE'nin talimat ve araçları ~5K token tuttuğu \
                 için uzun sohbetler hata verebilir; daha küçük (daha düşük kuantize) bir model seçin.",
                k(c)
            )
        })
    };

    let gpu = hw.primary_gpu();
    let has_gpu = gpu.map(|g| g.total_bytes as i64 >= 2 * GIB).unwrap_or(false);
    let ram_budget = hw.ram_available_bytes as i64 - RAM_SAFETY;
    let (gpu_total, gpu_free) = gpu.map(|g| (g.total_bytes as i64, g.free_bytes as i64)).unwrap_or((0, 0));

    let reserve: i64 = if !has_gpu {
        0
    } else if hw.unified_memory {
        (8 * GIB).max((gpu_total as f64 * 0.12).round() as i64).min((gpu_total as f64 * 0.35).round() as i64)
    } else {
        GIB.max((gpu_total as f64 * 0.06).round() as i64)
    };
    let gpu_budget = if has_gpu { gpu_free - reserve } else { 0 };
    let is_vulkan = gpu.map(|g| g.is_vulkan()).unwrap_or(false);
    let vulkan_args: Vec<String> =
        if has_gpu && is_vulkan { vec!["--device".into(), gpu.unwrap().id.clone()] } else { vec![] };
    let raise_hint: Option<String> = if hw.can_raise_gpu_memory_limit() {
        Some(format!(
            "GPU şu an yalnızca {} GiB kullanabiliyor (Linux varsayılanı: RAM'in yarısı). Sınırı {} GiB'a yükseltirseniz \
             model tamamen GPU'ya sığar ve belirgin şekilde hızlanır: Ayarlar > Model Çalıştırma'daki komutu çalıştırıp \
             bilgisayarı yeniden başlatın.",
            g(hw.gpu_memory_limit_bytes.unwrap() as i64),
            g(hw.suggested_gpu_memory_limit_bytes.unwrap() as i64)
        ))
    } else {
        None
    };
    let fits_total = |bytes: i64| -> bool {
        bytes <= if hw.unified_memory { ram_budget } else { ram_budget + gpu_budget.max(0) }
    };

    let mk = |placement: &str, ctx: i64, args: Vec<String>, summary: String, warnings: Vec<String>, blocker: Option<String>| {
        LaunchPlan { mode, placement: placement.into(), ctx, args, summary, warnings, blocker }
    };

    let cpu_plan = |pre_warnings: Vec<String>| -> LaunchPlan {
        for &c in &cands {
            let need = weights + kv(c) + GIB / 2;
            if need <= ram_budget && (fixed_ctx || c <= floor || kv(c) as f64 <= ram_budget as f64 * 0.2) {
                let mut w = pre_warnings.clone();
                if fixed_ctx && c < requested_ctx {
                    w.push(format!("Bağlam modelin eğitim sınırına ({}) indirildi.", k(c)));
                }
                if let Some(x) = small_ctx_warning(c) {
                    w.push(x);
                }
                let mut args = s(&["--device", "none", "-ngl", "0", "-c"]);
                args.push(c.to_string());
                args.extend(threads.clone());
                return mk(
                    "cpu",
                    c,
                    args,
                    format!("Yalnızca CPU • {} çekirdek • bağlam {} • RAM ~{} GiB", hw.physical_cores, k(c), g(need)),
                    w,
                    None,
                );
            }
        }
        mk(
            "cpu",
            last,
            vec![],
            String::new(),
            vec![],
            Some(format!(
                "Model RAM'e sığmıyor: {} GiB gerekiyor, kullanılabilir RAM {} GiB. Daha küçük (daha düşük kuantize) bir \
                 model seçin veya açık uygulamaları kapatın.",
                g(weights + kv(last)),
                g(ram_budget.max(0))
            )),
        )
    };

    if mode == ComputeMode::Cpu {
        return cpu_plan(vec![]);
    }
    if !has_gpu {
        if mode == ComputeMode::Gpu {
            return mk(
                "gpu",
                last,
                vec![],
                String::new(),
                vec![],
                Some("Kullanılabilir bir GPU bulunamadı. \"Otomatik\" veya \"Yalnızca CPU\" modunu seçin.".into()),
            );
        }
        return cpu_plan(vec!["GPU bulunamadı; model işlemcide çalışacak.".into()]);
    }

    // ---------------------------------------------- tamamı GPU'ya sığıyor mu?
    let mut full_gpu_ctx: Option<i64> = None;
    for &c in &cands {
        let need = weights + kv(c) + overhead;
        if need <= gpu_budget && fits_total(need) && (fixed_ctx || c <= floor || kv(c) as f64 <= gpu_budget as f64 * 0.25) {
            full_gpu_ctx = Some(c);
            break;
        }
    }
    let uma_no_mmap: Vec<String> = if hw.unified_memory { no_mmap.clone() } else { vec![] };

    if mode == ComputeMode::Gpu {
        let Some(fc) = full_gpu_ctx else {
            return mk(
                "gpu",
                last,
                vec![],
                String::new(),
                vec![],
                Some(format!(
                    "Model GPU belleğine sığmıyor: {} GiB gerekiyor, GPU'da {} GiB kullanılabilir (masaüstü için {} GiB pay \
                     bırakılıyor). \"Otomatik\" veya \"CPU offload\" modunu seçin.{}",
                    g(weights + kv(last) + overhead),
                    g(gpu_budget.max(0)),
                    g(reserve),
                    raise_hint.as_ref().map(|h| format!("\n\n{h}")).unwrap_or_default()
                )),
            );
        };
        let mut args = vulkan_args.clone();
        args.extend(["-ngl".to_string(), ngl_all.to_string()]);
        if can_fit {
            args.extend(s(&["--fit", "off"]));
        }
        args.extend(["-c".to_string(), fc.to_string()]);
        args.extend(threads.clone());
        args.extend(uma_no_mmap.clone());
        let mut w = vec![];
        if small_ctx_warning(fc).is_some() {
            w.push(format!(
                "Bağlam yalnızca {}: GPU belleği daha fazlasına yetmiyor. \"Otomatik\" mod bağlamın bir kısmını RAM'de \
                 tutarak {} ve üstüne çıkabilir.",
                k(fc),
                k(MIN_AGENT_CTX)
            ));
        }
        return mk(
            "gpu",
            fc,
            args,
            format!("Tamamı GPU'da • bağlam {} • GPU ~{} GiB", k(fc), g(weights + kv(fc) + overhead)),
            w,
            None,
        );
    }

    // ------------------------------------------- CPU offload: MoE uzmanları RAM'de
    if mode == ComputeMode::Hybrid {
        if let Some(info) = info.filter(|i| i.is_moe()) {
            for &c in &cands {
                let gpu_need = info.dense_bytes() as i64 + kv(c) + overhead;
                let total = weights + kv(c) + overhead;
                if gpu_need <= gpu_budget
                    && fits_total(total)
                    && (hw.unified_memory || info.expert_bytes as i64 <= ram_budget)
                    && (fixed_ctx || c <= floor || kv(c) as f64 <= gpu_budget as f64 * 0.35)
                {
                    let mut args = vulkan_args.clone();
                    args.extend(["-ngl".to_string(), ngl_all.to_string()]);
                    args.extend(cpu_moe.clone());
                    if can_fit {
                        args.extend(s(&["--fit", "off"]));
                    }
                    if is_vulkan {
                        args.extend(no_host.clone());
                    }
                    args.extend(["-c".to_string(), c.to_string()]);
                    args.extend(threads.clone());
                    let mut w = vec![];
                    if fixed_ctx && c < requested_ctx {
                        w.push(format!("Bağlam modelin eğitim sınırına ({}) indirildi.", k(c)));
                    }
                    return mk(
                        "moe-cpu",
                        c,
                        args,
                        format!(
                            "MoE uzmanları RAM'de ({} GiB), dikkat katmanları ve bağlam GPU'da (~{} GiB) • bağlam {}",
                            g(info.expert_bytes as i64),
                            g(gpu_need),
                            k(c)
                        ),
                        w,
                        None,
                    );
                }
            }
            return mk(
                "moe-cpu",
                last,
                vec![],
                String::new(),
                vec![],
                Some(format!(
                    "Model bu bilgisayarın belleğine sığmıyor: {} GiB gerekiyor. Daha düşük kuantize bir sürüm seçin.",
                    g(weights + kv(last) + overhead)
                )),
            );
        }
    }

    // --------------------------- Otomatik (ve MoE olmayan modelde CPU offload)
    let mut base_warnings = vec![];
    if mode == ComputeMode::Hybrid {
        base_warnings.push("Bu model MoE değil; katmanlar GPU ve RAM arasında otomatik paylaştırılıyor.".to_string());
    }
    let fit_args = |ctx: i64| -> Vec<String> {
        if can_fit {
            let mut a = s(&["--fit", "on", "--fit-target"]);
            a.push((reserve >> 20).to_string());
            if has("--fit-ctx") {
                a.push("--fit-ctx".into());
                a.push(ctx.min(MIN_AGENT_CTX).to_string());
            }
            return a;
        }
        let layers = info.map(|i| i.block_count as i64).unwrap_or(48).max(1);
        let per_layer = weights as f64 / layers as f64;
        let n = (((gpu_budget - kv(ctx) - overhead) as f64 / per_layer).floor() as i64).clamp(0, layers);
        vec!["-ngl".into(), n.to_string()]
    };
    let full_gpu_plan = |fc: i64| -> LaunchPlan {
        let mut args = vulkan_args.clone();
        args.extend(fit_args(fc));
        args.extend(["-c".to_string(), fc.to_string()]);
        args.extend(threads.clone());
        args.extend(uma_no_mmap.clone());
        let mut w = base_warnings.clone();
        if let Some(x) = small_ctx_warning(fc) {
            w.push(x);
        }
        mk(
            "gpu",
            fc,
            args,
            format!(
                "Tamamı GPU'da • bağlam {} • GPU ~{} GiB ({} GiB masaüstü payı)",
                k(fc),
                g(weights + kv(fc) + overhead),
                g(reserve)
            ),
            w,
            None,
        )
    };
    if let Some(fc) = full_gpu_ctx {
        if fc >= floor || fixed_ctx {
            return full_gpu_plan(fc);
        }
    }
    for &c in &cands {
        let total = weights + kv(c) + overhead;
        let small = fixed_ctx || c <= floor || (kv(c) as f64 <= gpu_budget as f64 * 0.08 && c <= 32768);
        if small && fits_total(total) {
            if let Some(fc) = full_gpu_ctx {
                if c <= fc {
                    return full_gpu_plan(fc);
                }
            }
            let on_gpu = (gpu_budget - kv(c) - overhead).max(0);
            let pct = (on_gpu.min(weights) as f64 * 100.0 / weights.max(1) as f64).round() as i64;
            let mut args = vulkan_args.clone();
            args.extend(fit_args(c));
            args.extend(["-c".to_string(), c.to_string()]);
            args.extend(threads.clone());
            if is_vulkan {
                args.extend(no_host.clone());
            }
            args.extend(uma_no_mmap.clone());
            let mut w = base_warnings.clone();
            if let Some(h) = &raise_hint {
                w.push(h.clone());
            }
            if let Some(x) = small_ctx_warning(c) {
                w.push(x);
            }
            return mk(
                "mixed",
                c,
                args,
                format!(
                    "GPU + RAM karma • modelin ~%{pct}'i GPU'da, kalanı RAM'de • bağlam {} • {} GiB masaüstü payı",
                    k(c),
                    g(reserve)
                ),
                w,
                None,
            );
        }
    }
    mk(
        "mixed",
        last,
        vec![],
        String::new(),
        vec![],
        Some(format!(
            "Model bu bilgisayarın belleğine sığmıyor: {} GiB gerekiyor, kullanılabilir toplam {} GiB. Daha düşük kuantize \
             bir sürüm seçin veya açık uygulamaları kapatın.",
            g(weights + kv(last) + overhead),
            g(if hw.unified_memory { ram_budget } else { ram_budget + gpu_budget }.max(0))
        )),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hardware::GpuDevice;

    const MIB: u64 = 1 << 20;
    const G: u64 = 1 << 30;

    fn glm_air() -> GgufInfo {
        GgufInfo {
            architecture: "glm4moe".into(),
            block_count: 47,
            context_length: 131072,
            head_count: 96,
            head_count_kv: 8,
            embedding_length: 4096,
            key_length: 128,
            value_length: 128,
            expert_count: 128,
            full_kv_per_token: 97920,
            weight_bytes: 67021939712,
            expert_bytes: 61729153024,
            ..Default::default()
        }
    }

    fn qwen35b() -> GgufInfo {
        GgufInfo {
            architecture: "qwen35moe".into(),
            block_count: 41,
            context_length: 262144,
            expert_count: 256,
            full_kv_per_token: 10880,
            weight_bytes: 37795000000,
            expert_bytes: 35080000000,
            ..Default::default()
        }
    }

    fn strix(gtt: f64, free: f64, ram_avail: f64) -> HardwareInfo {
        HardwareInfo {
            ram_total_bytes: 124 * G,
            ram_available_bytes: (ram_avail * G as f64) as u64,
            physical_cores: 16,
            gpus: vec![GpuDevice {
                id: "Vulkan0".into(),
                name: "AMD Radeon 8060S Graphics (RADV STRIX_HALO)".into(),
                total_bytes: (gtt * G as f64) as u64,
                free_bytes: (free * G as f64) as u64,
            }],
            unified_memory: true,
            gpu_memory_limit_bytes: Some((gtt * G as f64) as u64 - 512 * MIB),
            suggested_gpu_memory_limit_bytes: Some(112 * G),
            os: String::new(),
            cpu_name: String::new(),
        }
    }

    fn p(info: &GgufInfo, hw: &HardwareInfo, mode: ComputeMode, req: i64, flags: &BTreeSet<String>) -> LaunchPlan {
        plan(PlanInput {
            model_bytes: info.weight_bytes as i64,
            info: Some(info),
            hw,
            mode,
            requested_ctx: req,
            extra_gpu_bytes: 0,
            flags,
        })
    }

    fn contains_seq(args: &[String], seq: &[&str]) -> bool {
        args.windows(seq.len()).any(|w| w.iter().zip(seq).all(|(a, b)| a == b))
    }

    #[test]
    fn strix_auto_mixed() {
        let none = BTreeSet::new();
        let r = p(&glm_air(), &strix(62.97, 60.0, 100.0), ComputeMode::Auto, 0, &none);
        assert!(r.can_start(), "{r:?}");
        assert_eq!(r.placement, "mixed");
        assert_eq!(r.ctx, 32768);
        assert!(contains_seq(&r.args, &["--fit", "on", "--fit-target", "8192"]));
        assert!(r.args.contains(&"--no-host".to_string()));
        assert!(contains_seq(&r.args, &["--device", "Vulkan0"]));
        assert!(contains_seq(&r.args, &["--load-mode", "none"]));
        assert!(!r.args.contains(&"-ngl".to_string()));
        assert!(r.warnings.join("").contains("112,0 GiB"));
    }

    #[test]
    fn strix_gpu_blocked() {
        let none = BTreeSet::new();
        let r = p(&glm_air(), &strix(62.97, 60.0, 100.0), ComputeMode::Gpu, 0, &none);
        assert!(!r.can_start());
        let b = r.blocker.unwrap();
        assert!(b.contains("sığmıyor") && b.contains("Otomatik"));
    }

    #[test]
    fn strix_hybrid() {
        let none = BTreeSet::new();
        let r = p(&glm_air(), &strix(62.97, 60.0, 100.0), ComputeMode::Hybrid, 0, &none);
        assert_eq!(r.placement, "moe-cpu");
        assert_eq!(r.ctx, 131072);
        for a in ["--cpu-moe", "-ngl", "all", "--no-host"] {
            assert!(r.args.contains(&a.to_string()), "{a}");
        }
    }

    #[test]
    fn cpu_only() {
        let none = BTreeSet::new();
        let r = p(&glm_air(), &strix(62.97, 60.0, 100.0), ComputeMode::Cpu, 0, &none);
        assert!(contains_seq(&r.args, &["--device", "none", "-ngl", "0"]));
        assert!(contains_seq(&r.args, &["-t", "16"]));
    }

    #[test]
    fn raised_limit_full_gpu() {
        let none = BTreeSet::new();
        let hw = strix(112.5, 109.0, 100.0);
        let r = p(&glm_air(), &hw, ComputeMode::Auto, 0, &none);
        assert_eq!(r.placement, "gpu");
        assert_eq!(r.ctx, 131072);
        let g = p(&glm_air(), &hw, ComputeMode::Gpu, 0, &none);
        assert!(g.can_start());
        assert!(contains_seq(&g.args, &["-ngl", "all"]));
        assert!(contains_seq(&g.args, &["--load-mode", "none"]));
    }

    #[test]
    fn old_llama_flags() {
        let old: BTreeSet<String> =
            ["--no-mmap", "--device", "--n-gpu-layers", "--ctx-size", "--threads"].iter().map(|s| s.to_string()).collect();
        let r = p(&glm_air(), &strix(62.97, 60.0, 100.0), ComputeMode::Auto, 0, &old);
        assert!(r.args.contains(&"--no-mmap".to_string()));
        assert!(!r.args.contains(&"--fit".to_string()));
        let i = r.args.iter().position(|a| a == "-ngl").unwrap();
        let n: i64 = r.args[i + 1].parse().unwrap();
        assert!((30..=46).contains(&n), "{n}");
        let h = p(&glm_air(), &strix(62.97, 60.0, 100.0), ComputeMode::Hybrid, 0, &old);
        assert!(contains_seq(&h.args, &["-ot", r"\.ffn_(up|down|gate)_exps\.=CPU"]));
        assert!(contains_seq(&h.args, &["-ngl", "999"]));
    }

    #[test]
    fn qwen_full_gpu() {
        let none = BTreeSet::new();
        let r = p(&qwen35b(), &strix(62.97, 60.0, 100.0), ComputeMode::Auto, 0, &none);
        assert_eq!(r.placement, "gpu");
        assert_eq!(r.ctx, 131072);
    }

    #[test]
    fn requested_ctx_capped() {
        let none = BTreeSet::new();
        let r = p(&glm_air(), &strix(62.97, 60.0, 100.0), ComputeMode::Hybrid, 262144, &none);
        assert_eq!(r.ctx, 131072);
    }

    #[test]
    fn small_laptop_rejects() {
        let none = BTreeSet::new();
        let hw = HardwareInfo {
            ram_total_bytes: 16 * G,
            ram_available_bytes: 10 * G,
            physical_cores: 4,
            gpus: vec![],
            unified_memory: false,
            gpu_memory_limit_bytes: None,
            suggested_gpu_memory_limit_bytes: None,
            os: String::new(),
            cpu_name: String::new(),
        };
        let r = p(&glm_air(), &hw, ComputeMode::Auto, 0, &none);
        assert!(!r.can_start());
        assert!(r.blocker.unwrap().contains("RAM"));
    }

    #[test]
    fn nvidia_mixed() {
        let none = BTreeSet::new();
        let hw = HardwareInfo {
            ram_total_bytes: 64 * G,
            ram_available_bytes: 50 * G,
            physical_cores: 8,
            gpus: vec![GpuDevice { id: "CUDA0".into(), name: "NVIDIA GeForce RTX 4090".into(), total_bytes: 24 * G, free_bytes: 23 * G }],
            unified_memory: false,
            gpu_memory_limit_bytes: None,
            suggested_gpu_memory_limit_bytes: None,
            os: String::new(),
            cpu_name: String::new(),
        };
        let r = p(&glm_air(), &hw, ComputeMode::Auto, 0, &none);
        assert!(r.can_start());
        assert_eq!(r.placement, "mixed");
        assert!(!r.args.contains(&"--no-host".to_string()));
        assert!(!r.args.contains(&"--device".to_string()));
    }

    #[test]
    fn windows_laptop_min_ctx() {
        let none = BTreeSet::new();
        let gemma = GgufInfo {
            architecture: "gemma3".into(),
            block_count: 48,
            context_length: 131072,
            full_kv_per_token: 65536,
            swa_kv_per_token: 327680,
            sliding_window: 1024,
            weight_bytes: 4600 * MIB,
            ..Default::default()
        };
        let laptop = HardwareInfo {
            ram_total_bytes: 32 * G,
            ram_available_bytes: 22 * G,
            physical_cores: 8,
            gpus: vec![GpuDevice {
                id: "Vulkan0".into(),
                name: "NVIDIA GeForce RTX 4050 Laptop GPU".into(),
                total_bytes: 6 * G,
                free_bytes: (5.3 * G as f64) as u64,
            }],
            unified_memory: false,
            gpu_memory_limit_bytes: None,
            suggested_gpu_memory_limit_bytes: None,
            os: String::new(),
            cpu_name: String::new(),
        };
        let r = p(&gemma, &laptop, ComputeMode::Auto, 0, &none);
        assert!(r.can_start());
        assert!(r.ctx >= MIN_AGENT_CTX);
        assert_eq!(r.placement, "mixed");
        assert!(r.args.join(" ").contains("--fit-ctx 16384"));
        let c = p(&gemma, &laptop, ComputeMode::Cpu, 0, &none);
        assert!(c.ctx >= MIN_AGENT_CTX);
        let tiny = HardwareInfo { ram_total_bytes: 8 * G, ram_available_bytes: (10.5 * G as f64) as u64, physical_cores: 4, gpus: vec![], ..laptop.clone() };
        let t = p(&gemma, &tiny, ComputeMode::Auto, 0, &none);
        assert!(t.can_start());
        assert!(t.ctx < MIN_AGENT_CTX);
        assert!(t.warnings.join("").contains("Bağlam yalnızca"));
    }
}
