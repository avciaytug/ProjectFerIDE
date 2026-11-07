/// Model başlatma kararları için donanım ölçümü (Linux / Windows / macOS).
///
/// GPU belleği, llama-server'ın kendi `--list-devices` çıktısından okunur; bu
/// çıktı Vulkan, CUDA, ROCm ve Metal için aynı biçimdedir ve sürücünün o an
/// gerçekten ayırabileceği belleği (toplam ve boş) bildirir.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

class GpuDevice {
  final String id; // Vulkan0, CUDA0, ROCm0, MTL0 ...
  final String name;
  final int totalBytes;
  final int freeBytes;

  const GpuDevice({required this.id, required this.name, required this.totalBytes, required this.freeBytes});

  bool get isVulkan => id.startsWith('Vulkan');

  @override
  String toString() => '$id: $name (${_gib(totalBytes)} GiB, ${_gib(freeBytes)} GiB boş)';
}

class HardwareInfo {
  final int ramTotalBytes;
  final int ramAvailableBytes;
  final int physicalCores;
  final List<GpuDevice> gpus;

  /// GPU sistem RAM'ini paylaşıyor mu (AMD/Intel APU, Apple Silicon)?
  final bool unifiedMemory;

  /// Linux AMD APU'da GPU'nun kullanabileceği bellek üst sınırı (GTT) ve
  /// yükseltilebileceği önerilen değer; değilse null.
  final int? gpuMemoryLimitBytes;
  final int? suggestedGpuMemoryLimitBytes;

  const HardwareInfo({
    required this.ramTotalBytes,
    required this.ramAvailableBytes,
    required this.physicalCores,
    required this.gpus,
    required this.unifiedMemory,
    this.gpuMemoryLimitBytes,
    this.suggestedGpuMemoryLimitBytes,
  });

  GpuDevice? get primaryGpu => gpus.isEmpty ? null : gpus.first;

  /// GPU bellek sınırı yükseltilebilir mi (Linux AMD APU, sınır RAM'in %80'inden az)?
  bool get canRaiseGpuMemoryLimit =>
      gpuMemoryLimitBytes != null &&
      suggestedGpuMemoryLimitBytes != null &&
      suggestedGpuMemoryLimitBytes! > gpuMemoryLimitBytes! + (4 << 30);

  String describe() {
    final g = primaryGpu;
    final gpuText = g == null
        ? 'GPU bulunamadı'
        : '${g.name} — ${_gib(g.totalBytes)} GiB${unifiedMemory ? ' (paylaşımlı)' : ''}, ${_gib(g.freeBytes)} GiB boş';
    return '$gpuText • RAM ${_gib(ramTotalBytes)} GiB (${_gib(ramAvailableBytes)} GiB boş) • $physicalCores çekirdek';
  }
}

String _gib(int bytes) => (bytes / (1 << 30)).toStringAsFixed(1);

class HardwareProbe {
  static final _devLine = RegExp(r'^\s*([A-Za-z]+\d+):\s*(.+?)\s*\((\d+)\s*MiB,\s*(\d+)\s*MiB free\)', multiLine: true);

  /// `llama-server --list-devices` çıktısını ayrıştırır.
  static List<GpuDevice> parseListDevices(String out) => [
        for (final m in _devLine.allMatches(out))
          GpuDevice(
            id: m.group(1)!,
            name: m.group(2)!.trim(),
            totalBytes: int.parse(m.group(3)!) << 20,
            freeBytes: int.parse(m.group(4)!) << 20,
          ),
      ];

  static final Map<String, Set<String>> _flagCache = {};

  /// Kurulu llama-server'ın desteklediği seçenekleri `--help` çıktısından okur.
  /// llama.cpp sürümleri arasında seçenek adları değişebiliyor (ör. --no-mmap →
  /// --load-mode); planlayıcı yalnızca gerçekten desteklenen seçenekleri kullanır.
  /// "ngl-all" sözde bayrağı, `-ngl all` değerinin kabul edildiğini belirtir.
  static Future<Set<String>> llamaFlags(String llamaServer, Map<String, String> env) async {
    String key;
    try {
      key = '$llamaServer:${File(llamaServer).lastModifiedSync().millisecondsSinceEpoch}';
    } catch (_) {
      key = llamaServer;
    }
    final cached = _flagCache[key];
    if (cached != null) return cached;
    try {
      final r = await Process.run(llamaServer, ['--help'], environment: env).timeout(const Duration(seconds: 20));
      final help = '${r.stdout}\n${r.stderr}';
      final flags = {for (final m in RegExp(r'(?<![\w-])(--[a-z0-9][a-z0-9-]*)').allMatches(help)) m.group(1)!};
      if (help.contains("'all'")) flags.add('ngl-all');
      if (flags.length > 20) return _flagCache[key] = flags;
    } catch (_) {}
    return const {};
  }

  static Future<HardwareInfo> probe({required String llamaServer, required Map<String, String> env}) async {
    final ram = await _ram();
    final cores = await _physicalCores();
    var gpus = <GpuDevice>[];
    try {
      final r = await Process.run(llamaServer, ['--list-devices'], environment: env)
          .timeout(const Duration(seconds: 20));
      gpus = parseListDevices('${r.stdout}\n${r.stderr}');
    } catch (_) {}
    // Yazılım GPU'larını (llvmpipe) gerçek GPU sayma.
    gpus = gpus.where((g) => !g.name.toLowerCase().contains('llvmpipe')).toList();

    final linuxApu = Platform.isLinux ? _linuxAmdApuLimits(ram.total) : null;
    final unified = Platform.isMacOS ||
        linuxApu != null ||
        gpus.any((g) => RegExp(r'Radeon\(TM\) \d+M|Radeon \d{3,4}[MS]\b|8060S|8050S|890M|880M|780M|760M|Vega \d+ Graphics|Intel\(R\) (Arc\(TM\) |Iris|UHD)|Intel.*Graphics', caseSensitive: false).hasMatch(g.name));
    return HardwareInfo(
      ramTotalBytes: ram.total,
      ramAvailableBytes: ram.available,
      physicalCores: cores,
      gpus: gpus,
      unifiedMemory: unified,
      gpuMemoryLimitBytes: linuxApu?.limit,
      suggestedGpuMemoryLimitBytes: linuxApu?.suggested,
    );
  }

  /// Linux AMD APU (küçük VRAM + GTT): GPU'nun kullanabildiği bellek GTT'dir ve
  /// çekirdek varsayılanı RAM'in yarısıdır. Önerilen sınır: RAM - 12 GiB.
  static ({int limit, int suggested})? _linuxAmdApuLimits(int ramTotal) {
    try {
      for (final card in Directory('/sys/class/drm').listSync()) {
        if (!RegExp(r'^card\d+$').hasMatch(p.basename(card.path))) continue;
        final vram = File('${card.path}/device/mem_info_vram_total');
        final gtt = File('${card.path}/device/mem_info_gtt_total');
        if (!vram.existsSync() || !gtt.existsSync()) continue;
        final vramBytes = int.parse(vram.readAsStringSync().trim());
        final gttBytes = int.parse(gtt.readAsStringSync().trim());
        if (vramBytes > (8 << 30)) continue; // ayrık ekran kartı
        final suggested = ramTotal - (12 << 30);
        return (limit: gttBytes, suggested: suggested > gttBytes ? suggested : gttBytes);
      }
    } catch (_) {}
    return null;
  }

  static Future<({int total, int available})> _ram() async {
    try {
      if (Platform.isLinux) {
        final txt = File('/proc/meminfo').readAsStringSync();
        int kb(String key) => int.parse(RegExp('^$key:\\s+(\\d+)', multiLine: true).firstMatch(txt)!.group(1)!);
        return (total: kb('MemTotal') * 1024, available: kb('MemAvailable') * 1024);
      }
      if (Platform.isMacOS) {
        final total = int.parse((await Process.run('sysctl', ['-n', 'hw.memsize'])).stdout.toString().trim());
        final vm = (await Process.run('vm_stat', [])).stdout.toString();
        final page = int.tryParse(RegExp(r'page size of (\d+)').firstMatch(vm)?.group(1) ?? '') ?? 16384;
        int pages(String key) => int.tryParse(RegExp('$key:\\s+(\\d+)').firstMatch(vm)?.group(1) ?? '') ?? 0;
        final avail = (pages('Pages free') + pages('Pages inactive') + pages('Pages purgeable')) * page;
        return (total: total, available: avail > 0 ? avail : total ~/ 2);
      }
      if (Platform.isWindows) {
        final r = await Process.run('powershell', [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          r'$o=Get-CimInstance Win32_OperatingSystem; "$($o.TotalVisibleMemorySize) $($o.FreePhysicalMemory)"'
        ]);
        final parts = r.stdout.toString().trim().split(RegExp(r'\s+'));
        return (total: int.parse(parts[0]) * 1024, available: int.parse(parts[1]) * 1024);
      }
    } catch (_) {}
    return (total: 16 << 30, available: 8 << 30);
  }

  static Future<int> _physicalCores() async {
    final logical = Platform.numberOfProcessors;
    try {
      if (Platform.isLinux) {
        final txt = File('/proc/cpuinfo').readAsStringSync();
        final ids = <String>{};
        String phys = '0';
        for (final line in txt.split('\n')) {
          if (line.startsWith('physical id')) phys = line.split(':').last.trim();
          if (line.startsWith('core id')) ids.add('$phys:${line.split(':').last.trim()}');
        }
        if (ids.isNotEmpty) return ids.length;
      }
      if (Platform.isMacOS) {
        final r = await Process.run('sysctl', ['-n', 'hw.perflevel0.physicalcpu']);
        final perf = int.tryParse(r.stdout.toString().trim());
        if (perf != null && perf > 0) return perf; // Apple: yalnızca performans çekirdekleri
      }
    } catch (_) {}
    return logical >= 8 ? logical ~/ 2 : logical;
  }
}
