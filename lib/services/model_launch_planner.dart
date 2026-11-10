/// Yerel modelin nasıl başlatılacağına (GPU / CPU / karma, bağlam boyutu)
/// bellek ölçümüne göre karar veren saf planlayıcı.
///
/// Temel kural: sığmayacak bir yapılandırma ASLA başlatılmaz. Paylaşımlı bellekli
/// sistemlerde (AMD Strix Halo, Apple Silicon) GPU belleği masaüstü, tarayıcı ve
/// FerIDE ile ortaktır; GPU belleği tamamen dolarsa bu uygulamalar çöker. Bu
/// yüzden her zaman bir güvenlik payı bırakılır.
library;

import 'dart:math' as math;

import 'gguf_info.dart';
import 'hardware_probe.dart';

enum ComputeMode { auto, gpu, hybrid, cpu }

ComputeMode computeModeFromName(String? name) =>
    ComputeMode.values.firstWhere((m) => m.name == name, orElse: () => ComputeMode.auto);

String computeModeLabel(ComputeMode m) => switch (m) {
      ComputeMode.auto => 'Otomatik (önerilen)',
      ComputeMode.gpu => 'GPU offload — tamamı ekran kartında',
      ComputeMode.hybrid => 'CPU offload — MoE uzmanları RAM\'de, kalanı GPU\'da',
      ComputeMode.cpu => 'Yalnızca CPU',
    };

String computeModeHelp(ComputeMode m) => switch (m) {
      ComputeMode.auto =>
        'FerIDE belleği ölçer: model sığıyorsa tamamını GPU\'ya, sığmıyorsa sığan kısmını GPU\'ya ve kalanını RAM\'e koyar; bağlam boyutunu da buna göre seçer.',
      ComputeMode.gpu =>
        'En hızlısı. Modelin tamamı ve bağlam GPU belleğine sığmalıdır; sığmazsa model başlatılmaz ve neden gösterilir.',
      ComputeMode.hybrid =>
        'Büyük MoE modelleri (GLM-4.5-Air, Qwen-A3B) için: uzman ağırlıkları RAM\'de, dikkat katmanları ve bağlam GPU\'da. GPU belleği azken en kararlısı.',
      ComputeMode.cpu => 'Ekran kartı hiç kullanılmaz. En uyumlu ama en yavaş seçenek.',
    };

class LaunchPlan {
  final ComputeMode mode;

  /// Gerçekleşen yerleşim: 'gpu', 'mixed' (otomatik karma), 'moe-cpu', 'cpu'.
  final String placement;
  final int ctx;
  final List<String> args;
  final String summary;
  final List<String> warnings;

  /// Boş değilse model başlatılmaz; kullanıcıya bu açıklama gösterilir.
  final String? blocker;

  const LaunchPlan({
    required this.mode,
    required this.placement,
    required this.ctx,
    required this.args,
    required this.summary,
    this.warnings = const [],
    this.blocker,
  });

  bool get canStart => blocker == null;

  @override
  String toString() => 'LaunchPlan($placement, ctx=$ctx, args=${args.join(' ')}${blocker != null ? ', ENGEL: $blocker' : ''})';
}

class ModelLaunchPlanner {
  static const gib = 1 << 30;
  static const ctxSteps = [131072, 65536, 32768, 16384, 8192, 4096];

  /// Ajanın rahat çalışması için en küçük bağlam. Sistem talimatı ve araç
  /// tanımları tek başına ~4-5K token tutar; 4K bağlamda ilk mesaj bile sığmaz
  /// ("request exceeds the available context size"). Bellek gerçekten yetmedikçe
  /// bunun altına inilmez; bağlamın GPU'ya sığmayan kısmı RAM'de tutulur.
  static const minAgentCtx = 16384;

  /// Hesaplama tamponları vb. için GPU'da ayrılan tahmini ek bellek.
  static const computeOverhead = 3 * gib ~/ 2;

  /// RAM'de her zaman boş bırakılan pay (işletim sistemi + masaüstü).
  static const ramSafety = 4 * gib;

  static String g(int bytes) => (bytes / gib).toStringAsFixed(1).replaceAll('.', ',');
  static String k(int ctx) => '${ctx ~/ 1024}K';

  static LaunchPlan plan({
    required int modelBytes,
    GgufInfo? info,
    required HardwareInfo hw,
    required ComputeMode mode,
    int requestedCtx = 0,
    int extraGpuBytes = 0,

    /// Kurulu llama-server'ın desteklediği seçenekler; boşsa güncel sürüm varsayılır.
    Set<String> flags = const {},
  }) {
    bool has(String f) => flags.isEmpty || flags.contains(f);
    // Bellek eşlemesiz yükleme: yeni sürümlerde --load-mode none, eskilerde --no-mmap.
    final noMmap = has('--load-mode') ? ['--load-mode', 'none'] : (has('--no-mmap') ? ['--no-mmap'] : <String>[]);
    final nglAll = has('ngl-all') ? 'all' : '999';
    final noHost = has('--no-host') ? ['--no-host'] : <String>[];
    // MoE uzmanlarını CPU'ya alma: --cpu-moe yoksa eşdeğer tensör kuralı.
    final cpuMoe = has('--cpu-moe') ? ['--cpu-moe'] : ['-ot', r'\.ffn_(up|down|gate)_exps\.=CPU'];
    final canFit = has('--fit');
    final weights = info?.weightBytes ?? modelBytes;
    final trainCtx = info?.contextLength ?? 0;
    int kv(int c) => info?.kvBytes(c) ?? c * 128 * 1024;
    final overhead = computeOverhead + extraGpuBytes;
    final threads = ['-t', '${math.max(1, hw.physicalCores)}'];

    final cands = <int>[
      if (requestedCtx > 0) trainCtx > 0 ? math.min(requestedCtx, trainCtx) : requestedCtx,
      if (requestedCtx <= 0) ...ctxSteps.where((c) => trainCtx <= 0 || c <= trainCtx),
    ];
    if (cands.isEmpty) cands.add(trainCtx > 0 ? math.min(4096, trainCtx) : 4096);
    final fixedCtx = requestedCtx > 0;
    // Bu boyuta kadar olan bağlamlar, bellek yettiği sürece GPU payına bakılmadan
    // kabul edilir (büyükten küçüğe denendiği için önce bu taban seçilir).
    final floor = cands.firstWhere((c) => c <= minAgentCtx, orElse: () => cands.last);
    String? smallCtxWarning(int c) => c < minAgentCtx && !fixedCtx
        ? 'Bağlam yalnızca ${k(c)}: bellek daha fazlasına yetmiyor. FerIDE\'nin talimat ve araçları ~5K token tuttuğu '
            'için uzun sohbetler hata verebilir; daha küçük (daha düşük kuantize) bir model seçin.'
        : null;

    final gpu = hw.primaryGpu;
    final hasGpu = gpu != null && gpu.totalBytes >= 2 * gib;
    final ramBudget = hw.ramAvailableBytes - ramSafety;

    // Paylaşımlı bellekte masaüstü/tarayıcı da GPU belleği kullanır: büyük pay.
    final reserve = !hasGpu
        ? 0
        : hw.unifiedMemory
            ? math.min(math.max(8 * gib, (gpu.totalBytes * 0.12).round()), (gpu.totalBytes * 0.35).round())
            : math.max(gib, (gpu.totalBytes * 0.06).round());
    final gpuBudget = hasGpu ? gpu.freeBytes - reserve : 0;
    final vulkanArgs = hasGpu && gpu.isVulkan ? ['--device', gpu.id] : <String>[];
    final raiseHint = hw.canRaiseGpuMemoryLimit
        ? 'GPU şu an yalnızca ${g(hw.gpuMemoryLimitBytes!)} GiB kullanabiliyor (Linux varsayılanı: RAM\'in yarısı). '
            'Sınırı ${g(hw.suggestedGpuMemoryLimitBytes!)} GiB\'a yükseltirseniz model tamamen GPU\'ya sığar ve belirgin şekilde hızlanır: '
            'Ayarlar > Genel > Model Çalıştırma\'daki komutu çalıştırıp bilgisayarı yeniden başlatın.'
        : null;

    // Paylaşımlı bellekte GPU'ya giden her bayt RAM'den de düşer.
    bool fitsTotal(int bytes) => bytes <= (hw.unifiedMemory ? ramBudget : ramBudget + math.max(0, gpuBudget));

    LaunchPlan cpuPlan({List<String> warnings = const []}) {
      for (final c in cands) {
        final need = weights + kv(c) + gib ~/ 2;
        if (need <= ramBudget && (fixedCtx || c <= floor || kv(c) <= ramBudget * 0.2)) {
          return LaunchPlan(
            mode: mode,
            placement: 'cpu',
            ctx: c,
            args: ['--device', 'none', '-ngl', '0', '-c', '$c', ...threads],
            summary: 'Yalnızca CPU • ${hw.physicalCores} çekirdek • bağlam ${k(c)} • RAM ~${g(need)} GiB',
            warnings: [
              ...warnings,
              if (fixedCtx && c < requestedCtx) 'Bağlam modelin eğitim sınırına (${k(c)}) indirildi.',
              if (smallCtxWarning(c) != null) smallCtxWarning(c)!,
            ],
          );
        }
      }
      return LaunchPlan(
        mode: mode,
        placement: 'cpu',
        ctx: cands.last,
        args: const [],
        summary: '',
        blocker: 'Model RAM\'e sığmıyor: ${g(weights + kv(cands.last))} GiB gerekiyor, '
            'kullanılabilir RAM ${g(math.max(0, ramBudget))} GiB. Daha küçük (daha düşük kuantize) bir model seçin '
            'veya açık uygulamaları kapatın.',
      );
    }

    if (mode == ComputeMode.cpu) return cpuPlan();
    if (!hasGpu) {
      if (mode == ComputeMode.gpu) {
        return LaunchPlan(
          mode: mode,
          placement: 'gpu',
          ctx: cands.last,
          args: const [],
          summary: '',
          blocker: 'Kullanılabilir bir GPU bulunamadı. "Otomatik" veya "Yalnızca CPU" modunu seçin.',
        );
      }
      return cpuPlan(warnings: ['GPU bulunamadı; model işlemcide çalışacak.']);
    }

    // ------------------------------------------------- tamamı GPU'da sığıyor mu?
    int? fullGpuCtx;
    for (final c in cands) {
      final need = weights + kv(c) + overhead;
      if (need <= gpuBudget && fitsTotal(need) && (fixedCtx || c <= floor || kv(c) <= gpuBudget * 0.25)) {
        fullGpuCtx = c;
        break;
      }
    }
    final umaNoMmap = hw.unifiedMemory ? noMmap : <String>[];

    if (mode == ComputeMode.gpu) {
      if (fullGpuCtx == null) {
        final c = cands.last;
        return LaunchPlan(
          mode: mode,
          placement: 'gpu',
          ctx: c,
          args: const [],
          summary: '',
          blocker: 'Model GPU belleğine sığmıyor: ${g(weights + kv(c) + overhead)} GiB gerekiyor, GPU\'da '
              '${g(math.max(0, gpuBudget))} GiB kullanılabilir (masaüstü için ${g(reserve)} GiB pay bırakılıyor). '
              '"Otomatik" veya "CPU offload" modunu seçin.${raiseHint != null ? '\n\n$raiseHint' : ''}',
        );
      }
      return LaunchPlan(
        mode: mode,
        placement: 'gpu',
        ctx: fullGpuCtx,
        args: [...vulkanArgs, '-ngl', nglAll, if (canFit) ...['--fit', 'off'], '-c', '$fullGpuCtx', ...threads, ...umaNoMmap],
        summary: 'Tamamı GPU\'da • bağlam ${k(fullGpuCtx)} • GPU ~${g(weights + kv(fullGpuCtx) + overhead)} GiB',
        warnings: [
          if (smallCtxWarning(fullGpuCtx) != null)
            'Bağlam yalnızca ${k(fullGpuCtx)}: GPU belleği daha fazlasına yetmiyor. "Otomatik" mod bağlamın bir kısmını '
                'RAM\'de tutarak ${k(minAgentCtx)} ve üstüne çıkabilir.',
        ],
      );
    }

    // ------------------------------------- CPU offload: MoE uzmanları RAM'de
    if (mode == ComputeMode.hybrid && info != null && info.isMoe) {
      for (final c in cands) {
        final gpuNeed = info.denseBytes + kv(c) + overhead;
        final total = weights + kv(c) + overhead;
        if (gpuNeed <= gpuBudget &&
            fitsTotal(total) &&
            (hw.unifiedMemory || info.expertBytes <= ramBudget) &&
            (fixedCtx || c <= floor || kv(c) <= gpuBudget * 0.35)) {
          return LaunchPlan(
            mode: mode,
            placement: 'moe-cpu',
            ctx: c,
            args: [
              ...vulkanArgs,
              '-ngl', nglAll,
              ...cpuMoe,
              if (canFit) ...['--fit', 'off'],
              if (gpu.isVulkan) ...noHost,
              '-c', '$c',
              ...threads,
            ],
            summary: 'MoE uzmanları RAM\'de (${g(info.expertBytes)} GiB), dikkat katmanları ve bağlam GPU\'da '
                '(~${g(gpuNeed)} GiB) • bağlam ${k(c)}',
            warnings: [if (fixedCtx && c < requestedCtx) 'Bağlam modelin eğitim sınırına (${k(c)}) indirildi.'],
          );
        }
      }
      return LaunchPlan(
        mode: mode,
        placement: 'moe-cpu',
        ctx: cands.last,
        args: const [],
        summary: '',
        blocker: 'Model bu bilgisayarın belleğine sığmıyor: ${g(weights + kv(cands.last) + overhead)} GiB gerekiyor. '
            'Daha düşük kuantize bir sürüm seçin.',
      );
    }

    // ------------------------------- Otomatik (ve MoE olmayan modelde CPU offload)
    final warnings = <String>[
      if (mode == ComputeMode.hybrid) 'Bu model MoE değil; katmanlar GPU ve RAM arasında otomatik paylaştırılıyor.',
    ];
    // --fit yoksa (eski llama.cpp) GPU'ya sığacak katman sayısı burada hesaplanır.
    List<String> fitArgs(int ctx) {
      if (canFit) {
        return [
          '--fit', 'on', '--fit-target', '${reserve >> 20}',
          // Sunucunun kendi sığdırma ayarı bağlamı ajan tabanının altına indirmesin.
          if (has('--fit-ctx')) ...['--fit-ctx', '${math.min(ctx, minAgentCtx)}'],
        ];
      }
      final layers = math.max(1, info?.blockCount ?? 48);
      final perLayer = weights / layers;
      final n = ((gpuBudget - kv(ctx) - overhead) / perLayer).floor().clamp(0, layers);
      return ['-ngl', '$n'];
    }
    LaunchPlan fullGpuPlan(int fullGpuCtx) => LaunchPlan(
          mode: mode,
          placement: 'gpu',
          ctx: fullGpuCtx,
          args: [...vulkanArgs, ...fitArgs(fullGpuCtx), '-c', '$fullGpuCtx', ...threads, ...umaNoMmap],
          summary: 'Tamamı GPU\'da • bağlam ${k(fullGpuCtx)} • GPU ~${g(weights + kv(fullGpuCtx) + overhead)} GiB '
              '(${g(reserve)} GiB masaüstü payı)',
          warnings: [...warnings, if (smallCtxWarning(fullGpuCtx) != null) smallCtxWarning(fullGpuCtx)!],
        );
    // Tamamı GPU'ya ancak çok küçük bir bağlamla sığıyorsa (ör. 6 GB ekran kartı)
    // karma yerleşim tercih edilir: biraz daha yavaş ama ajan gerçekten çalışır.
    if (fullGpuCtx != null && (fullGpuCtx >= floor || fixedCtx)) return fullGpuPlan(fullGpuCtx);
    // Sığmıyor: bağlamı ölçülü tut ki GPU'da model ağırlıklarına yer kalsın;
    // ama ajan için gereken tabanın (16K) altına, bellek yettiği sürece inme.
    for (final c in cands) {
      final total = weights + kv(c) + overhead;
      final small = fixedCtx || c <= floor || (kv(c) <= gpuBudget * 0.08 && c <= 32768);
      if (small && fitsTotal(total)) {
        if (fullGpuCtx != null && c <= fullGpuCtx) return fullGpuPlan(fullGpuCtx);
        final onGpu = math.max(0, gpuBudget - kv(c) - overhead);
        final pct = (math.min(onGpu, weights) * 100 / weights).round();
        return LaunchPlan(
          mode: mode,
          placement: 'mixed',
          ctx: c,
          args: [...vulkanArgs, ...fitArgs(c), '-c', '$c', ...threads, if (gpu.isVulkan) ...noHost, ...umaNoMmap],
          summary: 'GPU + RAM karma • modelin ~%$pct\'i GPU\'da, kalanı RAM\'de • bağlam ${k(c)} • '
              '${g(reserve)} GiB masaüstü payı',
          warnings: [...warnings, if (raiseHint != null) raiseHint, if (smallCtxWarning(c) != null) smallCtxWarning(c)!],
        );
      }
    }
    return LaunchPlan(
      mode: mode,
      placement: 'mixed',
      ctx: cands.last,
      args: const [],
      summary: '',
      blocker: 'Model bu bilgisayarın belleğine sığmıyor: ${g(weights + kv(cands.last) + overhead)} GiB gerekiyor, '
          'kullanılabilir toplam ${g(math.max(0, hw.unifiedMemory ? ramBudget : ramBudget + gpuBudget))} GiB. '
          'Daha düşük kuantize bir sürüm seçin veya açık uygulamaları kapatın.',
    );
  }
}
