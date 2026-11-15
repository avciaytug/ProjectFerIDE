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
const MIB: i64 = 1 << 20;
pub const CTX_STEPS: [i64; 6] = [131072, 65536, 32768, 16384, 8192, 4096];
/// Ajanın rahat çalışması için en küçük bağlam (talimat + araç tanımları ~5K token).
pub const MIN_AGENT_CTX: i64 = 16384;
/// Mimarisi okunamayan modellerde GPU hesap tamponu tahmini.
pub const COMPUTE_OVERHEAD: i64 = 3 * GIB / 2;
pub const RAM_SAFETY: i64 = 4 * GIB;
/// GPU'da denenecek toplu işlem (`-ub`) boyutları. Büyüğü uzun istemleri daha hızlı işler; hesap tamponu ve kayan
/// pencereli KV önbelleği onunla büyüdüğü için küçük GPU'larda küçüğü seçilir (Gemma 4 12B, ölçülen: 2048'de
/// 0,55 GiB, 512'de 0,14 GiB hesap tamponu).
pub const UB_STEPS: [i64; 4] = [2048, 1024, 512, 256];
/// İşlemcide ve küçük GPU'lu karma yerleşimde kullanılan toplu işlem boyutu.
pub const SMALL_UBATCH: i64 = 512;

#[derive(Clone, Debug, Serialize)]
pub struct LaunchPlan {
    pub mode: ComputeMode,
    /// gpu | mixed | moe-cpu | cpu
    pub placement: String,
    pub ctx: i64,
    /// llama-server `-ub` (fiziksel toplu işlem boyutu).
    pub ubatch: i64,
    /// Görsel adaptör (mmproj) GPU'ya yüklensin mi? `false`: işlemcide çalışır (`--no-mmproj-offload`), GPU belleği
    /// modele kalır.
    pub mmproj_offload: bool,
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
    /// Görsel adaptör (mmproj) dosyasının boyutu; yoksa 0.
    pub mmproj_bytes: i64,
    /// Kurulu llama-server'ın desteklediği seçenekler; boşsa güncel sürüm varsayılır.
    pub flags: &'a BTreeSet<String>,
}

/// Bir GPU yerleşimi adayı: bağlam, toplu işlem boyutu ve görsel adaptörün GPU'da olup olmadığı.
#[derive(Clone, Copy, Debug)]
struct Fit {
    ctx: i64,
    ub: i64,
    vision_gpu: bool,
}

/// Ajanın rahat çalıştığı bağlam: buna kadar bağlam her şeyden önce gelir.
const COMFORT_CTX: i64 = 32768;

/// Uygun adaylar arasından en iyisini seçer. Tercih sırası: bağlam (32K'ya kadar; ajan için en önemlisi), büyük toplu
/// işlem (uzun istemleri hızlı işler), görsel adaptör GPU'da, daha da büyük bağlam. `max_ctx`: kullanıcı belirli bir
/// bağlam istediyse sığan en büyük bağlam önce gelir.
fn pick(ctxs: &[i64], ubs: &[i64], vision_opts: &[bool], max_ctx: bool, ok: impl Fn(Fit) -> bool) -> Option<Fit> {
    let mut best: Option<(Fit, (i64, i64, bool, i64))> = None;
    for &ctx in ctxs {
        for &ub in ubs {
            for &vision_gpu in vision_opts {
                let f = Fit { ctx, ub, vision_gpu };
                if !ok(f) {
                    continue;
                }
                let key = if max_ctx { (ctx, ub, vision_gpu, 0) } else { (ctx.min(COMFORT_CTX), ub, vision_gpu, ctx) };
                if best.as_ref().is_none_or(|(_, b)| key > *b) {
                    best = Some((f, key));
                }
            }
        }
    }
    best.map(|(f, _)| f)
}

pub fn plan(inp: PlanInput) -> LaunchPlan {
    let PlanInput { model_bytes, info, hw, mode, requested_ctx, mmproj_bytes, flags } = inp;
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
    let kv = |c: i64, ub: i64| -> i64 { info.map(|i| i.kv_bytes(c as u64, ub as u64) as i64).unwrap_or(c * 128 * 1024) };
    let compute = |c: i64, ub: i64| -> i64 {
        info.and_then(|i| i.compute_bytes(c as u64, ub as u64)).map(|b| b as i64).unwrap_or(COMPUTE_OVERHEAD)
    };
    // Görsel adaptör: dosya + görüntü kodlama tamponu. Güncel llama.cpp onu işlemcide de çalıştırabilir.
    let vision = if mmproj_bytes > 0 { mmproj_bytes + (256 * MIB).max(mmproj_bytes / 2) } else { 0 };
    let vision_cpu_ok = vision > 0 && has("--no-mmproj-offload");
    let vision_opts: &[bool] = if vision == 0 {
        &[false]
    } else if vision_cpu_ok {
        &[true, false]
    } else {
        &[true]
    };
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
        // Ayrık kart: o an boş bellek zaten ölçülüyor ve tahmin gerçek kullanımın üstünde kalıyor; dizüstünde
        // masaüstü genellikle tümleşik GPU'da çalışır. 512 MiB – 2 GiB pay yeter.
        (512 * MIB).max((gpu_total as f64 * 0.06).round() as i64).min(2 * GIB)
    };
    let pay = if hw.unified_memory { "masaüstü payı" } else { "güvenlik payı" };
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
    // Paylaşımlı bellekli GPU'larda (APU) GPU önce kendisine ayrılmış bellekten (Windows'ta AMD Adrenalin "Değişken
    // Grafik Belleği", Linux'ta VRAM) yer alır; işletim sistemi bu kısmı RAM olarak görmez. Yalnızca bunu aşan GPU
    // kullanımı sistem RAM'inden yer. Ayrılmış bellek küçükse (ör. 512 MB–4 GB) GPU'nun her baytı RAM'den gelir.
    let dedicated_avail: i64 = if hw.unified_memory && has_gpu {
        let ded = (hw.dedicated_gpu_bytes.unwrap_or(0) as i64).min(gpu_total);
        (ded - (gpu_total - gpu_free).max(0) - reserve).max(0)
    } else {
        0
    };
    // GPU'ya konan `gpu_bytes`'ın sistem RAM'inden kullandığı kısım.
    let ram_for_gpu = |gpu_bytes: i64| -> i64 {
        if hw.unified_memory {
            (gpu_bytes - dedicated_avail).max(0)
        } else {
            0
        }
    };
    let total_capacity = if hw.unified_memory { ram_budget + dedicated_avail } else { ram_budget + gpu_budget.max(0) };
    let fits_total = |bytes: i64| -> bool { bytes <= total_capacity };
    // Windows, paylaşımlı bellekli GPU'ya yüklenen belleği (ayrılmış VRAM'e de olsa) sanal bellek taahhüt sınırından
    // düşer. Sınır aşılacaksa Windows sayfa dosyasını büyütmek zorundadır; sayfa dosyası kapalı ya da sabitse model
    // yüklenemez.
    let commit_warning = |gpu_bytes: i64| -> Option<String> {
        let avail = hw.commit_available_bytes? as i64;
        (hw.unified_memory && gpu_bytes + GIB > avail).then(|| {
            format!(
                "Windows, GPU'ya yüklenen belleği de sanal bellek (taahhüt) sınırından düşüyor; bu model sınırı ~{} GiB \
                 aşacak. Sayfa dosyası otomatikse Windows onu büyütür (ilk yükleme biraz uzayabilir); kapalı ya da sabit \
                 boyutluysa model yüklenemez: Sistem → Gelişmiş sistem ayarları → Performans → Gelişmiş → Sanal bellek → \
                 \"Tüm sürücüler için disk belleği dosyası boyutunu otomatik yönet\".",
                g(gpu_bytes + GIB - avail)
            )
        })
    };

    let mk = |placement: &str, ctx: i64, args: Vec<String>, summary: String, warnings: Vec<String>, blocker: Option<String>| {
        LaunchPlan {
            mode,
            placement: placement.into(),
            ctx,
            ubatch: UB_STEPS[0],
            mmproj_offload: true,
            args,
            summary,
            warnings,
            blocker,
        }
    };

    let cpu_plan = |pre_warnings: Vec<String>| -> LaunchPlan {
        for &c in &cands {
            let need = weights + kv(c, SMALL_UBATCH) + GIB / 2 + vision;
            if need <= ram_budget && (fixed_ctx || c <= floor || kv(c, SMALL_UBATCH) as f64 <= ram_budget as f64 * 0.2) {
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
                return LaunchPlan {
                    ubatch: SMALL_UBATCH,
                    mmproj_offload: false,
                    ..mk(
                        "cpu",
                        c,
                        args,
                        format!("Yalnızca CPU • {} çekirdek • bağlam {} • RAM ~{} GiB", hw.physical_cores, k(c), g(need)),
                        w,
                        None,
                    )
                };
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
                g(weights + kv(last, SMALL_UBATCH) + vision),
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
    // GPU'da duracak bellek: ağırlıklar + KV önbelleği + hesap tamponu (+ görsel adaptör GPU'daysa).
    let need_of = |f: Fit| -> i64 { weights + kv(f.ctx, f.ub) + compute(f.ctx, f.ub) + if f.vision_gpu { vision } else { 0 } };
    let fits_gpu = |f: Fit| -> bool {
        need_of(f) <= gpu_budget && fits_total(weights + kv(f.ctx, f.ub) + compute(f.ctx, f.ub) + vision)
    };
    // Büyük bağlam KV önbelleği için GPU'nun en fazla dörtte biri ayrılır (ajan tabanı ve altı her zaman serbest).
    let kv_share_ok = |f: Fit| -> bool { fixed_ctx || f.ctx <= floor || kv(f.ctx, f.ub) as f64 <= gpu_budget as f64 * 0.25 };
    let full: Option<Fit> = pick(&cands, &UB_STEPS, vision_opts, false, |f| fits_gpu(f) && kv_share_ok(f));
    let uma_no_mmap: Vec<String> = if hw.unified_memory { no_mmap.clone() } else { vec![] };
    let vision_note = |f: Fit| -> &'static str {
        if vision > 0 && !f.vision_gpu {
            " • görsel kodlayıcı işlemcide"
        } else {
            ""
        }
    };

    if mode == ComputeMode::Gpu {
        let mut w = vec![];
        let mut chosen = full;
        // Kullanıcının seçtiği bağlam sığmıyorsa sığan en büyük bağlamla tamamen GPU'da çalıştır (uyararak).
        if chosen.is_none() && fixed_ctx {
            let lower: Vec<i64> =
                CTX_STEPS.iter().copied().filter(|c| *c < cands[0] && (train_ctx <= 0 || *c <= train_ctx)).collect();
            if let Some(f) = pick(&lower, &UB_STEPS, vision_opts, true, fits_gpu) {
                w.push(format!(
                    "Seçtiğiniz {} bağlam GPU belleğine sığmıyor; model tamamen GPU'da {} bağlamla çalışıyor. Daha uzun \
                     bağlam için \"Otomatik\" modu seçin (modelin bir kısmı RAM'de tutulur).",
                    k(cands[0]),
                    k(f.ctx)
                ));
                chosen = Some(f);
            }
        }
        let Some(f) = chosen else {
            let min_ctx = CTX_STEPS[CTX_STEPS.len() - 1].min(if train_ctx > 0 { train_ctx } else { i64::MAX }).min(last);
            let min = Fit { ctx: min_ctx, ub: UB_STEPS[UB_STEPS.len() - 1], vision_gpu: vision > 0 && !vision_cpu_ok };
            let need = need_of(min);
            let msg = if need <= gpu_budget {
                // GPU'ya sığıyor; ama GPU bu belleğin bir kısmını sistem RAM'inden alıyor ve boş RAM yetmiyor.
                format!(
                    "Model GPU'ya sığıyor ama GPU bu belleğin bir kısmını sistem RAM'inden kullanıyor ve boş RAM yetmiyor: \
                     {} GiB gerekiyor; GPU'ya ayrılmış bellekte {} GiB, RAM'de {} GiB yer var. Açık uygulamaları kapatın \
                     veya daha düşük kuantize bir sürüm seçin.",
                    g(need),
                    g(dedicated_avail),
                    g(ram_budget.max(0))
                )
            } else {
                format!(
                    "Model GPU belleğine sığmıyor: en küçük ayarla ({} bağlam) bile {} GiB gerekiyor — model {} GiB, bağlam \
                     önbelleği {} GiB, çalışma alanı {} GiB{} — GPU'da ise {} GiB kullanılabilir ({} GiB {} bırakılıyor). \
                     \"Otomatik\" ya da \"CPU offload\" modunu seçin (modelin bir kısmı RAM'de çalışır) veya daha düşük \
                     kuantize bir sürüm seçin.{}",
                    k(min.ctx),
                    g(need),
                    g(weights),
                    g(kv(min.ctx, min.ub)),
                    g(compute(min.ctx, min.ub)),
                    if min.vision_gpu { format!(", görsel adaptör {} GiB", g(vision)) } else { String::new() },
                    g(gpu_budget.max(0)),
                    g(reserve),
                    pay,
                    raise_hint.as_ref().map(|h| format!("\n\n{h}")).unwrap_or_default()
                )
            };
            return mk("gpu", min.ctx, vec![], String::new(), vec![], Some(msg));
        };
        let mut args = vulkan_args.clone();
        args.extend(["-ngl".to_string(), ngl_all.to_string()]);
        if can_fit {
            args.extend(s(&["--fit", "off"]));
        }
        args.extend(["-c".to_string(), f.ctx.to_string()]);
        args.extend(threads.clone());
        args.extend(uma_no_mmap.clone());
        w.extend(commit_warning(need_of(f)));
        if small_ctx_warning(f.ctx).is_some() {
            w.push(format!(
                "Bağlam yalnızca {}: GPU belleği daha fazlasına yetmiyor. \"Otomatik\" mod bağlamın bir kısmını RAM'de \
                 tutarak {} ve üstüne çıkabilir.",
                k(f.ctx),
                k(MIN_AGENT_CTX)
            ));
        }
        return LaunchPlan {
            ubatch: f.ub,
            mmproj_offload: f.vision_gpu || vision == 0,
            ..mk(
                "gpu",
                f.ctx,
                args,
                format!("Tamamı GPU'da • bağlam {} • GPU ~{} GiB{}", k(f.ctx), g(need_of(f)), vision_note(f)),
                w,
                None,
            )
        };
    }

    // ------------------------------------------- CPU offload: MoE uzmanları RAM'de
    if mode == ComputeMode::Hybrid {
        if let Some(info) = info.filter(|i| i.is_moe()) {
            let moe_need = |f: Fit| -> i64 {
                info.dense_bytes() as i64 + kv(f.ctx, f.ub) + compute(f.ctx, f.ub) + if f.vision_gpu { vision } else { 0 }
            };
            let moe_ok = |f: Fit| -> bool {
                let gpu_need = moe_need(f);
                gpu_need <= gpu_budget
                    && fits_total(weights + kv(f.ctx, f.ub) + compute(f.ctx, f.ub) + vision)
                    && info.expert_bytes as i64 + ram_for_gpu(gpu_need) <= ram_budget
                    && (fixed_ctx || f.ctx <= floor || kv(f.ctx, f.ub) as f64 <= gpu_budget as f64 * 0.35)
            };
            // Uzmanlar işlemcideyken uzun istemleri büyük toplu işlem hızlandırır; 256'ya inilmez.
            if let Some(f) = pick(&cands, &UB_STEPS[..3], vision_opts, false, moe_ok) {
                let gpu_need = moe_need(f);
                let mut args = vulkan_args.clone();
                args.extend(["-ngl".to_string(), ngl_all.to_string()]);
                args.extend(cpu_moe.clone());
                if can_fit {
                    args.extend(s(&["--fit", "off"]));
                }
                if is_vulkan {
                    args.extend(no_host.clone());
                }
                args.extend(["-c".to_string(), f.ctx.to_string()]);
                args.extend(threads.clone());
                let mut w = vec![];
                w.extend(commit_warning(gpu_need));
                if fixed_ctx && f.ctx < requested_ctx {
                    w.push(format!("Bağlam modelin eğitim sınırına ({}) indirildi.", k(f.ctx)));
                }
                if let Some(x) = small_ctx_warning(f.ctx) {
                    w.push(x);
                }
                return LaunchPlan {
                    ubatch: f.ub,
                    mmproj_offload: f.vision_gpu || vision == 0,
                    ..mk(
                        "moe-cpu",
                        f.ctx,
                        args,
                        format!(
                            "MoE uzmanları RAM'de ({} GiB), dikkat katmanları ve bağlam GPU'da (~{} GiB) • bağlam {}{}",
                            g(info.expert_bytes as i64),
                            g(gpu_need),
                            k(f.ctx),
                            vision_note(f)
                        ),
                        w,
                        None,
                    )
                };
            }
            if full.is_none() {
                return mk(
                    "moe-cpu",
                    last,
                    vec![],
                    String::new(),
                    vec![],
                    Some(format!(
                        "Model bu bilgisayarın belleğine sığmıyor: {} GiB gerekiyor. Daha düşük kuantize bir sürüm seçin.",
                        g(weights + kv(last, SMALL_UBATCH) + compute(last, SMALL_UBATCH) + vision)
                    )),
                );
            }
            // Uzmanlara RAM yetmiyor ama model tamamen GPU'ya sığıyor: aşağıda GPU planı seçilir.
        }
    }

    // --------------------------- Otomatik (ve MoE olmayan modelde CPU offload)
    let mut base_warnings = vec![];
    if mode == ComputeMode::Hybrid {
        base_warnings.push(if info.is_some_and(|i| i.is_moe()) {
            "CPU offload için RAM yetmiyor; model tamamen GPU'da çalıştırılıyor (daha hızlı).".to_string()
        } else {
            "Bu model MoE değil; katmanlar GPU ve RAM arasında otomatik paylaştırılıyor.".to_string()
        });
    }
    // Karma yerleşimde GPU'nun her baytı katmanlara gitsin: küçük GPU'da küçük toplu işlem.
    let mixed_ub = if gpu_budget < 16 * GIB { SMALL_UBATCH } else { UB_STEPS[0] };
    let fit_args = |ctx: i64, ub: i64| -> Vec<String> {
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
        let n = (((gpu_budget - kv(ctx, ub) - compute(ctx, ub)) as f64 / per_layer).floor() as i64).clamp(0, layers);
        vec!["-ngl".into(), n.to_string()]
    };
    let full_gpu_plan = |f: Fit| -> LaunchPlan {
        let mut args = vulkan_args.clone();
        if hw.unified_memory {
            args.extend(fit_args(f.ctx, f.ub));
        } else {
            // Ayrık kartta llama.cpp'nin kendi sığdırma tahmini (bütün toplu işlemin logitlerini sayar) gerçeğin çok
            // üstünde kalıyor ve küçük kartlarda gereksiz yere katman taşıyor; plan zaten sığdığını hesapladı.
            args.extend(["-ngl".to_string(), ngl_all.to_string()]);
            if can_fit {
                args.extend(s(&["--fit", "off"]));
            }
        }
        args.extend(["-c".to_string(), f.ctx.to_string()]);
        args.extend(threads.clone());
        args.extend(uma_no_mmap.clone());
        let mut w = base_warnings.clone();
        w.extend(commit_warning(need_of(f)));
        if let Some(x) = small_ctx_warning(f.ctx) {
            w.push(x);
        }
        LaunchPlan {
            ubatch: f.ub,
            mmproj_offload: f.vision_gpu || vision == 0,
            ..mk(
                "gpu",
                f.ctx,
                args,
                format!(
                    "Tamamı GPU'da • bağlam {} • GPU ~{} GiB ({} GiB {}){}",
                    k(f.ctx),
                    g(need_of(f)),
                    g(reserve),
                    pay,
                    vision_note(f)
                ),
                w,
                None,
            )
        }
    };
    if let Some(f) = full {
        if f.ctx >= floor || fixed_ctx {
            return full_gpu_plan(f);
        }
    }
    let ub = mixed_ub;
    for &c in &cands {
        let total = weights + kv(c, ub) + compute(c, ub) + vision;
        let small = fixed_ctx || c <= floor || (kv(c, ub) as f64 <= gpu_budget as f64 * 0.08 && c <= 32768);
        if small && fits_total(total) {
            if let Some(f) = full {
                if c <= f.ctx {
                    return full_gpu_plan(f);
                }
            }
            let on_gpu = (gpu_budget - kv(c, ub) - compute(c, ub)).max(0);
            let pct = (on_gpu.min(weights) as f64 * 100.0 / weights.max(1) as f64).round() as i64;
            let mut args = vulkan_args.clone();
            args.extend(fit_args(c, ub));
            args.extend(["-c".to_string(), c.to_string()]);
            args.extend(threads.clone());
            if is_vulkan {
                args.extend(no_host.clone());
            }
            args.extend(uma_no_mmap.clone());
            let mut w = base_warnings.clone();
            w.extend(commit_warning(total.min(gpu_budget.max(0))));
            if let Some(h) = &raise_hint {
                w.push(h.clone());
            }
            if let Some(x) = small_ctx_warning(c) {
                w.push(x);
            }
            // GPU belleği katmanlara kalsın: görsel adaptör mümkünse işlemcide.
            let offload = vision == 0 || !vision_cpu_ok;
            return LaunchPlan {
                ubatch: ub,
                mmproj_offload: offload,
                ..mk(
                    "mixed",
                    c,
                    args,
                    format!(
                        "GPU + RAM karma • modelin ~%{pct}'i GPU'da, kalanı RAM'de • bağlam {} • {} GiB {}{}",
                        k(c),
                        g(reserve),
                        pay,
                        if offload { "" } else { " • görsel kodlayıcı işlemcide" }
                    ),
                    w,
                    None,
                )
            };
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
            g(weights + kv(last, ub) + compute(last, ub) + vision),
            g(total_capacity.max(0))
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
            dedicated_gpu_bytes: None,
            commit_available_bytes: None,
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
            mmproj_bytes: 0,
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
            dedicated_gpu_bytes: None,
            commit_available_bytes: None,
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
            dedicated_gpu_bytes: None,
            commit_available_bytes: None,
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
            dedicated_gpu_bytes: None,
            commit_available_bytes: None,
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
        let tiny = HardwareInfo { ram_total_bytes: 8 * G, ram_available_bytes: 10 * G, physical_cores: 4, gpus: vec![], ..laptop.clone() };
        let t = p(&gemma, &tiny, ComputeMode::Auto, 0, &none);
        assert!(t.can_start());
        assert!(t.ctx < MIN_AGENT_CTX);
        assert!(t.warnings.join("").contains("Bağlam yalnızca"));
    }

    /// Windows'ta AMD Adrenalin ile GPU'ya 96 GB ayrılmış, Windows'a 32 GB RAM kalmış Strix Halo (kullanıcının gerçek
    /// ölçümleri): Vulkan 111,8 GiB (106,2 boş), RAM 31,6 GiB (22,6 boş).
    fn strix_carveout(dedicated_gib: u64, ram_avail: f64) -> HardwareInfo {
        HardwareInfo {
            ram_total_bytes: (31.6 * G as f64) as u64,
            ram_available_bytes: (ram_avail * G as f64) as u64,
            physical_cores: 16,
            gpus: vec![GpuDevice {
                id: "Vulkan0".into(),
                name: "AMD Radeon(TM) 8060S Graphics".into(),
                total_bytes: 114507 * MIB,
                free_bytes: 108782 * MIB,
            }],
            unified_memory: true,
            gpu_memory_limit_bytes: None,
            suggested_gpu_memory_limit_bytes: None,
            dedicated_gpu_bytes: Some(dedicated_gib * G),
            commit_available_bytes: Some(50 * G),
            os: String::new(),
            cpu_name: String::new(),
        }
    }

    fn qwen27b_q8() -> GgufInfo {
        GgufInfo {
            architecture: "qwen35".into(),
            block_count: 64,
            context_length: 262144,
            full_kv_per_token: 16384,
            weight_bytes: 36_100_000_000,
            ..Default::default()
        }
    }

    #[test]
    fn carveout_runs_on_gpu() {
        let none = BTreeSet::new();
        let hw = strix_carveout(96, 22.6);
        let a = p(&qwen27b_q8(), &hw, ComputeMode::Auto, 0, &none);
        assert!(a.can_start(), "{a:?}");
        assert_eq!(a.placement, "gpu");
        assert_eq!(a.ctx, 131072);
        let g = p(&qwen27b_q8(), &hw, ComputeMode::Gpu, 0, &none);
        assert!(g.can_start(), "{g:?}");
        assert!(contains_seq(&g.args, &["-ngl", "all"]));
        // İşlemcide çalışamaz: RAM'e sığmıyor.
        assert!(!p(&qwen27b_q8(), &hw, ComputeMode::Cpu, 0, &none).can_start());
    }

    #[test]
    fn carveout_commit_warning() {
        let none = BTreeSet::new();
        let ok = p(&qwen27b_q8(), &strix_carveout(96, 22.6), ComputeMode::Auto, 0, &none);
        assert!(!ok.warnings.join("").contains("taahhüt"), "{ok:?}");
        let low = HardwareInfo { commit_available_bytes: Some(20 * G), ..strix_carveout(96, 22.6) };
        let w = p(&qwen27b_q8(), &low, ComputeMode::Auto, 0, &none);
        assert!(w.can_start());
        assert!(w.warnings.join("").contains("taahhüt"), "{w:?}");
    }

    #[test]
    fn preview_with_running_model() {
        // Sizin FerIDE'nizde ölçülen durum: Q8 yüklüyken taahhüt 11,3 GiB boş, RAM 13,6 GiB boş. Önizleme çalışan
        // modelin taahhüdünü (44 GiB) ve RAM'ini (5,6 GiB) geri eklemeli: uyarı çıkmamalı.
        let none = BTreeSet::new();
        let mut hw = HardwareInfo { commit_available_bytes: Some((11.3 * G as f64) as u64), ..strix_carveout(96, 13.6) };
        assert!(p(&qwen27b_q8(), &hw, ComputeMode::Auto, 0, &none).warnings.join("").contains("taahhüt"));
        hw.add_back_running((5.6 * G as f64) as u64, Some(44 * G));
        let r = p(&qwen27b_q8(), &hw, ComputeMode::Auto, 0, &none);
        assert!(r.can_start());
        assert!(!r.warnings.join("").contains("taahhüt"), "{r:?}");
        assert!(hw.ram_available_bytes <= hw.ram_total_bytes);
    }

    #[test]
    fn small_carveout_still_counts_ram() {
        // Ayrılmış bellek küçükse (eski davranış) GPU'nun kullandığı bellek RAM'den gelir: 22,6 GiB boş RAM'e
        // 36 GB'lık model sığmaz ve GPU modunda gerçek neden (RAM) söylenir.
        let none = BTreeSet::new();
        let hw = strix_carveout(4, 22.6);
        let g = p(&qwen27b_q8(), &hw, ComputeMode::Gpu, 0, &none);
        assert!(!g.can_start());
        assert!(g.blocker.unwrap().contains("RAM"));
        assert!(!p(&qwen27b_q8(), &hw, ComputeMode::Auto, 0, &none).can_start());
    }

    /// Gemma 4 12B UD-IQ2_M (3,9 GiB): değerler gerçek GGUF başlığından (FerIDE'nin kendi okuyucusuyla).
    fn gemma4_iq2() -> GgufInfo {
        GgufInfo {
            architecture: "gemma4".into(),
            block_count: 48,
            context_length: 262144,
            embedding_length: 3840,
            full_kv_per_token: 8704,
            swa_kv_per_token: 174080,
            sliding_window: 1024,
            weight_bytes: 4_197_529_088,
            vocab_size: 262144,
            ffn_width: 15360,
            ..Default::default()
        }
    }
    const GEMMA4_MMPROJ: i64 = 175_115_840;

    /// Kullanıcının ikinci bilgisayarı: ASUS ROG Strix (i7-9750H), 6 GB NVIDIA, 5,3 GiB boş. Vulkan derlemesinde
    /// listede Intel UHD de vardı ve eskiden bütün sistem "paylaşımlı bellek" sayılıyordu.
    fn rog_strix(id: &str) -> HardwareInfo {
        HardwareInfo {
            ram_total_bytes: 16 * G,
            ram_available_bytes: 9 * G,
            physical_cores: 6,
            gpus: vec![GpuDevice {
                id: id.into(),
                name: "NVIDIA GeForce RTX 2060".into(),
                total_bytes: 6144 * MIB,
                free_bytes: 5427 * MIB,
            }],
            unified_memory: false,
            gpu_memory_limit_bytes: None,
            suggested_gpu_memory_limit_bytes: None,
            dedicated_gpu_bytes: None,
            commit_available_bytes: Some(20 * G),
            os: String::new(),
            cpu_name: String::new(),
        }
    }

    fn pm(info: &GgufInfo, hw: &HardwareInfo, mode: ComputeMode, req: i64, mmproj: i64) -> LaunchPlan {
        let none = BTreeSet::new();
        plan(PlanInput { model_bytes: info.weight_bytes as i64, info: Some(info), hw, mode, requested_ctx: req, mmproj_bytes: mmproj, flags: &none })
    }

    #[test]
    fn small_nvidia_runs_4gb_model_on_gpu() {
        // Eskiden: "7,1 GiB gerekiyor, GPU'da 3,2 GiB kullanılabilir (masaüstü için 2,1 GiB pay)". Gerçekte (llama.cpp
        // ölçümü) 32K bağlam ve 512 toplu işlemle ~4,6 GiB yetiyor.
        for id in ["CUDA0", "Vulkan1"] {
            let hw = rog_strix(id);
            for mode in [ComputeMode::Gpu, ComputeMode::Auto] {
                let r = pm(&gemma4_iq2(), &hw, mode, 0, GEMMA4_MMPROJ);
                assert!(r.can_start(), "{id} {mode:?}: {r:?}");
                assert_eq!(r.placement, "gpu", "{r:?}");
                assert_eq!(r.ctx, 32768, "{r:?}");
                assert_eq!(r.ubatch, 512, "{r:?}");
                assert!(!r.mmproj_offload, "görsel kodlayıcı işlemcide olmalı: {r:?}");
                assert!(contains_seq(&r.args, &["-ngl", "all"]) && contains_seq(&r.args, &["--fit", "off"]), "{r:?}");
                assert!(r.summary.contains("işlemcide"), "{r:?}");
            }
        }
        // Görsel adaptör yoksa aynı bellekle daha büyük toplu işlem seçilebilir.
        let r = pm(&gemma4_iq2(), &rog_strix("CUDA0"), ComputeMode::Gpu, 0, 0);
        assert!(r.can_start() && r.ctx >= 32768, "{r:?}");
    }

    #[test]
    fn gpu_mode_shrinks_chosen_context() {
        // Kullanıcı 128K seçmiş: GPU modunda engellemek yerine sığan en büyük bağlamla tamamen GPU'da çalışır.
        let r = pm(&gemma4_iq2(), &rog_strix("CUDA0"), ComputeMode::Gpu, 131072, GEMMA4_MMPROJ);
        assert!(r.can_start(), "{r:?}");
        assert_eq!(r.placement, "gpu");
        assert!(r.ctx < 131072 && r.ctx >= MIN_AGENT_CTX, "{r:?}");
        assert!(r.warnings.join("").contains("sığmıyor"), "{r:?}");
        // Otomatik modda seçilen bağlam korunur, model GPU ile RAM arasında paylaştırılır.
        let a = pm(&gemma4_iq2(), &rog_strix("CUDA0"), ComputeMode::Auto, 131072, GEMMA4_MMPROJ);
        assert!(a.can_start(), "{a:?}");
        assert_eq!(a.placement, "mixed");
        assert_eq!(a.ctx, 131072);
    }

    #[test]
    fn gpu_mode_block_explains_breakdown() {
        // 6 GB karta 12 GB'lık model hiçbir ayarla sığmaz: neden ayrıntılı söylenir.
        let big = GgufInfo { weight_bytes: 12 * G, ..gemma4_iq2() };
        let r = pm(&big, &rog_strix("CUDA0"), ComputeMode::Gpu, 0, 0);
        assert!(!r.can_start());
        let b = r.blocker.unwrap();
        assert!(b.contains("sığmıyor") && b.contains("bağlam önbelleği") && b.contains("güvenlik payı"), "{b}");
    }

    #[test]
    fn discrete_reserve_is_small() {
        // Ayrık 6 GB kartta pay 512 MiB (eskiden APU sanılınca 2,1 GiB, ayrık sayılınca 1 GiB).
        let r = pm(&gemma4_iq2(), &rog_strix("CUDA0"), ComputeMode::Auto, 0, 0);
        assert!(r.summary.contains("0,5 GiB güvenlik payı"), "{r:?}");
    }

    #[test]
    fn big_gpu_keeps_fast_batches() {
        // Bellek bolsa davranış değişmez: 2048 toplu işlem, görsel adaptör GPU'da, 128K bağlam.
        let hw = HardwareInfo {
            gpus: vec![GpuDevice { id: "CUDA0".into(), name: "NVIDIA GeForce RTX 4090".into(), total_bytes: 24 * G, free_bytes: 23 * G }],
            ram_total_bytes: 64 * G,
            ram_available_bytes: 50 * G,
            ..rog_strix("CUDA0")
        };
        let r = pm(&gemma4_iq2(), &hw, ComputeMode::Auto, 0, GEMMA4_MMPROJ);
        assert_eq!((r.placement.as_str(), r.ctx, r.ubatch, r.mmproj_offload), ("gpu", 131072, 2048, true), "{r:?}");
    }

    #[test]
    fn estimates_cover_measured_server_memory() {
        // llama.cpp b12383 Vulkan, Gemma 4 12B: gerçek sunucu ölçümleri (KV + döndürme tamponu, hesap tamponu; MiB).
        let i = gemma4_iq2();
        for (ctx, ub, kv_real, compute_real) in
            [(16384u64, 256u64, 367.2, 68.6), (16384, 512, 409.7, 137.5), (65536, 1024, 902.7, 372.1), (16384, 2048, 664.7, 556.1), (131072, 2048, 1616.7, 1004.1)]
        {
            let kv = i.kv_bytes(ctx, ub) as f64 / MIB as f64;
            let c = i.compute_bytes(ctx, ub).unwrap() as f64 / MIB as f64;
            assert!(kv >= kv_real && kv <= kv_real * 1.15, "kv {ctx}/{ub}: {kv:.0} ↔ {kv_real}");
            assert!(c >= compute_real && c <= compute_real + 160.0, "hesap {ctx}/{ub}: {c:.0} ↔ {compute_real}");
        }
    }

    #[test]
    fn carveout_moe_experts_need_ram() {
        // Uzmanlar RAM'de durur: 57 GiB'lık uzmanlar 22,6 GiB boş RAM'e sığmaz, CPU offload yapılmaz. Model tamamen
        // GPU'ya sığdığı için engellenmez, GPU'da başlatılır.
        let none = BTreeSet::new();
        let r = p(&glm_air(), &strix_carveout(96, 22.6), ComputeMode::Hybrid, 0, &none);
        assert!(r.can_start(), "{r:?}");
        assert_eq!(r.placement, "gpu");
        assert!(r.warnings.join("").contains("RAM yetmiyor"));
    }
}
