import 'dart:io';

import 'package:feride_v5_2/services/gguf_info.dart';
import 'package:feride_v5_2/services/hardware_probe.dart';
import 'package:feride_v5_2/services/model_launch_planner.dart';
import 'package:flutter_test/flutter_test.dart';

const gib = 1 << 30;
const mib = 1 << 20;

/// Bu makinedeki gerçek GLM-4.5-Air Q4_K_S değerleri (GgufReader çıktısı).
const glmAir = GgufInfo(
  architecture: 'glm4moe', blockCount: 47, contextLength: 131072, headCount: 96, headCountKv: 8,
  embeddingLength: 4096, keyLength: 128, valueLength: 128, expertCount: 128,
  fullKvPerToken: 97920, swaKvPerToken: 0, slidingWindow: 0,
  weightBytes: 67021939712, expertBytes: 61729153024, parts: ['a', 'b'],
);

const qwen35bA3b = GgufInfo(
  architecture: 'qwen35moe', blockCount: 41, contextLength: 262144, headCount: 16, headCountKv: 2,
  embeddingLength: 2048, keyLength: 256, valueLength: 256, expertCount: 256,
  fullKvPerToken: 10880, swaKvPerToken: 0, slidingWindow: 0,
  weightBytes: 37795000000, expertBytes: 35080000000, parts: ['a'],
);

HardwareInfo strixHalo({double gttGiB = 62.97, double freeGiB = 60.0, double ramAvailGiB = 100}) => HardwareInfo(
      ramTotalBytes: 124 * gib,
      ramAvailableBytes: (ramAvailGiB * gib).round(),
      physicalCores: 16,
      gpus: [GpuDevice(id: 'Vulkan0', name: 'AMD Radeon 8060S Graphics (RADV STRIX_HALO)', totalBytes: (gttGiB * gib).round(), freeBytes: (freeGiB * gib).round())],
      unifiedMemory: true,
      gpuMemoryLimitBytes: (gttGiB * gib).round() - 512 * mib,
      suggestedGpuMemoryLimitBytes: 112 * gib,
    );

void main() {
  test('--list-devices çıktısı ayrıştırılır', () {
    final devs = HardwareProbe.parseListDevices('''
Available devices:
  Vulkan0: AMD Radeon 8060S Graphics (RADV STRIX_HALO) (64481 MiB, 5543 MiB free)
  CUDA0: NVIDIA GeForce RTX 4090 (24563 MiB, 23400 MiB free)
''');
    expect(devs.map((d) => d.id), ['Vulkan0', 'CUDA0']);
    expect(devs.first.totalBytes, 64481 * mib);
    expect(devs.first.freeBytes, 5543 * mib);
    expect(devs.last.name, 'NVIDIA GeForce RTX 4090');
  });

  group('Strix Halo (128 GB, GPU sınırı 62 GB) + GLM-4.5-Air', () {
    test('Otomatik: karma yerleşim, 32K bağlam, 8 GiB masaüstü payı, çökme yok', () {
      final p = ModelLaunchPlanner.plan(modelBytes: glmAir.weightBytes, info: glmAir, hw: strixHalo(), mode: ComputeMode.auto);
      expect(p.canStart, isTrue);
      expect(p.placement, 'mixed');
      expect(p.ctx, 32768);
      expect(p.args, containsAllInOrder(['--fit', 'on', '--fit-target', '8192']));
      expect(p.args, containsAll(['--no-host', '--device', 'Vulkan0']));
      expect(p.args, containsAllInOrder(['--load-mode', 'none']));
      expect(p.args, isNot(contains('-ngl')));
      expect(p.warnings.join(), contains('112,0 GiB')); // GPU sınırını yükseltme önerisi
    });

    test('GPU modu: sığmadığı için BAŞLATILMAZ (eskiden masaüstünü çökertiyordu)', () {
      final p = ModelLaunchPlanner.plan(modelBytes: glmAir.weightBytes, info: glmAir, hw: strixHalo(), mode: ComputeMode.gpu);
      expect(p.canStart, isFalse);
      expect(p.blocker, contains('sığmıyor'));
      expect(p.blocker, contains('Otomatik'));
    });

    test('CPU offload: uzmanlar RAM\'de, GPU\'da yalnızca ~5 GiB + bağlam, 128K', () {
      final p = ModelLaunchPlanner.plan(modelBytes: glmAir.weightBytes, info: glmAir, hw: strixHalo(), mode: ComputeMode.hybrid);
      expect(p.canStart, isTrue);
      expect(p.placement, 'moe-cpu');
      expect(p.args, containsAll(['--cpu-moe', '-ngl', 'all', '--no-host']));
      expect(p.ctx, 131072);
    });

    test('Yalnızca CPU: GPU hiç kullanılmaz', () {
      final p = ModelLaunchPlanner.plan(modelBytes: glmAir.weightBytes, info: glmAir, hw: strixHalo(), mode: ComputeMode.cpu);
      expect(p.canStart, isTrue);
      expect(p.args, containsAllInOrder(['--device', 'none', '-ngl', '0']));
      expect(p.args, containsAllInOrder(['-t', '16']));
    });

    test('GPU sınırı 112 GiB\'a yükseltilince: tamamı GPU\'da, 128K', () {
      final hw = strixHalo(gttGiB: 112.5, freeGiB: 109);
      final p = ModelLaunchPlanner.plan(modelBytes: glmAir.weightBytes, info: glmAir, hw: hw, mode: ComputeMode.auto);
      expect(p.placement, 'gpu');
      expect(p.ctx, 131072);
      final g = ModelLaunchPlanner.plan(modelBytes: glmAir.weightBytes, info: glmAir, hw: hw, mode: ComputeMode.gpu);
      expect(g.canStart, isTrue);
      expect(g.args, containsAll(['-ngl', 'all', '--load-mode', 'none']));
    });
  });

  test('Eski llama.cpp (--fit ve --load-mode yok): --no-mmap ve hesaplanmış -ngl', () {
    const old = {'--no-mmap', '--device', '--n-gpu-layers', '--ctx-size', '--threads'};
    final p = ModelLaunchPlanner.plan(modelBytes: glmAir.weightBytes, info: glmAir, hw: strixHalo(), mode: ComputeMode.auto, flags: old);
    expect(p.args, contains('--no-mmap'));
    expect(p.args, isNot(contains('--fit')));
    expect(p.args, isNot(contains('--load-mode')));
    final i = p.args.indexOf('-ngl');
    expect(i, greaterThanOrEqualTo(0));
    final ngl = int.parse(p.args[i + 1]);
    expect(ngl, inInclusiveRange(30, 46)); // ~%78'i GPU'da
    final h = ModelLaunchPlanner.plan(modelBytes: glmAir.weightBytes, info: glmAir, hw: strixHalo(), mode: ComputeMode.hybrid, flags: old);
    expect(h.args, containsAllInOrder(['-ot', r'\.ffn_(up|down|gate)_exps\.=CPU']));
    expect(h.args, containsAllInOrder(['-ngl', '999']));
  });

  test('Kurulu llama-server bayrakları okunur', () async {
    final exe = '${Platform.environment['HOME']}/.feride/bin/llama-cpp/llama-server';
    if (!File(exe).existsSync()) return;
    final f = await HardwareProbe.llamaFlags(exe, {'LD_LIBRARY_PATH': File(exe).parent.path});
    // ignore: avoid_print
    print('Bayrak sayısı: ${f.length}; load-mode=${f.contains('--load-mode')} no-mmap=${f.contains('--no-mmap')} fit=${f.contains('--fit')} cpu-moe=${f.contains('--cpu-moe')} ngl-all=${f.contains('ngl-all')}');
    expect(f, containsAll(['--fit', '--cpu-moe', '--load-mode', 'ngl-all']));
    expect(f, isNot(contains('--no-mmap')));
  });

  test('Qwen3.8-35B-A3B bugünkü sınırda bile tamamen GPU\'da, 128K', () {
    final p = ModelLaunchPlanner.plan(modelBytes: qwen35bA3b.weightBytes, info: qwen35bA3b, hw: strixHalo(), mode: ComputeMode.auto);
    expect(p.placement, 'gpu');
    expect(p.ctx, 131072);
  });

  test('Bağlam elle seçilirse korunur, eğitim sınırını aşamaz', () {
    final p = ModelLaunchPlanner.plan(
        modelBytes: glmAir.weightBytes, info: glmAir, hw: strixHalo(), mode: ComputeMode.hybrid, requestedCtx: 262144);
    expect(p.ctx, 131072);
  });

  test('GPU\'suz 16 GB dizüstü: dev model açıkça reddedilir', () {
    const hw = HardwareInfo(ramTotalBytes: 16 * gib, ramAvailableBytes: 10 * gib, physicalCores: 4, gpus: [], unifiedMemory: false);
    final p = ModelLaunchPlanner.plan(modelBytes: glmAir.weightBytes, info: glmAir, hw: hw, mode: ComputeMode.auto);
    expect(p.canStart, isFalse);
    expect(p.blocker, contains('RAM'));
  });

  test('24 GB NVIDIA + 64 GB RAM: otomatik karma çalışır', () {
    final hw = HardwareInfo(
      ramTotalBytes: 64 * gib,
      ramAvailableBytes: 50 * gib,
      physicalCores: 8,
      gpus: [GpuDevice(id: 'CUDA0', name: 'NVIDIA GeForce RTX 4090', totalBytes: 24 * gib, freeBytes: 23 * gib)],
      unifiedMemory: false,
    );
    final p = ModelLaunchPlanner.plan(modelBytes: glmAir.weightBytes, info: glmAir, hw: hw, mode: ComputeMode.auto);
    expect(p.canStart, isTrue);
    expect(p.placement, 'mixed');
    expect(p.args, isNot(contains('--no-host'))); // yalnızca Vulkan'da
    expect(p.args, isNot(contains('--device'))); // CUDA varsayılan aygıtı kullanır
  });

  test('64 GB Mac (paylaşımlı): 62 GB model RAM\'e sığmaz, reddedilir', () {
    final hw = HardwareInfo(
      ramTotalBytes: 64 * gib,
      ramAvailableBytes: 48 * gib,
      physicalCores: 12,
      gpus: [GpuDevice(id: 'MTL0', name: 'Apple M3 Max', totalBytes: 48 * gib, freeBytes: 48 * gib)],
      unifiedMemory: true,
    );
    final p = ModelLaunchPlanner.plan(modelBytes: glmAir.weightBytes, info: glmAir, hw: hw, mode: ComputeMode.auto);
    expect(p.canStart, isFalse);
  });

  group('Windows dizüstü: 6 GB VRAM + 32 GB RAM (kullanıcının "4096 token" hatası)', () {
    // Gemma 12B IQ2_M: 48 katman, 8 tam + 40 kayan pencereli (1024) dikkat katmanı.
    const gemma12bIq2 = GgufInfo(
      architecture: 'gemma3', blockCount: 48, contextLength: 131072, headCount: 16, headCountKv: 8,
      embeddingLength: 3840, keyLength: 256, valueLength: 256, expertCount: 0,
      fullKvPerToken: 65536, swaKvPerToken: 327680, slidingWindow: 1024,
      weightBytes: 4600 * mib, expertBytes: 0, parts: ['a'],
    );
    final laptop = HardwareInfo(
      ramTotalBytes: 32 * gib,
      ramAvailableBytes: 22 * gib,
      physicalCores: 8,
      gpus: [GpuDevice(id: 'Vulkan0', name: 'NVIDIA GeForce RTX 4050 Laptop GPU', totalBytes: 6 * gib, freeBytes: (5.3 * gib).round())],
      unifiedMemory: false,
    );

    test('Otomatik: bağlam 4K\'ya düşmez; en az 16K, fazlası RAM\'de (karma)', () {
      final p = ModelLaunchPlanner.plan(modelBytes: gemma12bIq2.weightBytes, info: gemma12bIq2, hw: laptop, mode: ComputeMode.auto);
      expect(p.canStart, isTrue);
      expect(p.ctx, greaterThanOrEqualTo(ModelLaunchPlanner.minAgentCtx));
      expect(p.placement, 'mixed');
      expect(p.warnings.join(), isNot(contains('yalnızca')));
      // llama-server'ın kendi sığdırma ayarı da bağlamı 16K altına indiremez.
      expect(p.args.join(' '), contains('--fit-ctx 16384'));
    });

    test('Yalnızca CPU da en az 16K bağlamla başlar', () {
      final p = ModelLaunchPlanner.plan(modelBytes: gemma12bIq2.weightBytes, info: gemma12bIq2, hw: laptop, mode: ComputeMode.cpu);
      expect(p.ctx, greaterThanOrEqualTo(ModelLaunchPlanner.minAgentCtx));
    });

    test('Belleğe gerçekten sığmayan küçük bağlam açıkça uyarılır', () {
      final tiny = HardwareInfo(ramTotalBytes: 8 * gib, ramAvailableBytes: (10.5 * gib).round(), physicalCores: 4, gpus: const [], unifiedMemory: false);
      final p = ModelLaunchPlanner.plan(modelBytes: gemma12bIq2.weightBytes, info: gemma12bIq2, hw: tiny, mode: ComputeMode.auto);
      expect(p.canStart, isTrue);
      expect(p.ctx, lessThan(ModelLaunchPlanner.minAgentCtx));
      expect(p.warnings.join(), contains('Bağlam yalnızca'));
    });
  });

  group('Windows bellek ölçümü', () {
    test('önbellek dahil "kullanılabilir" bellek kullanılır (FreePhysicalMemory değil)', () {
      // 32 GB Windows: boş 3 GB görünür ama önbellekle birlikte 24 GB kullanılabilir.
      final r = HardwareProbe.parseWindowsRam('33406844 3145728 ${24 * gib}');
      expect(r.total, 33406844 * 1024);
      expect(r.available, 24 * gib);
    });

    test('kullanılabilir değer okunamazsa boş bellek kullanılır', () {
      expect(HardwareProbe.parseWindowsRam('33406844 3145728 ').available, 3145728 * 1024);
      expect(HardwareProbe.parseWindowsRam('33406844 3145728').available, 3145728 * 1024);
    });
  });
}
