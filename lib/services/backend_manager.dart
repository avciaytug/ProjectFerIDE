import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'app_paths.dart';
import 'gguf_info.dart';
import 'hardware_probe.dart';
import 'model_launch_planner.dart';
import 'pty_sandbox.dart';
import 'system_installer_service.dart';
import '../features/chat/state.dart';

enum BackendType { llamaCpp, vllm, ollama }

class BackendConfig {
  final BackendType type;
  final String executablePath;
  final String modelPathOrName;
  final int port;

  /// 0 = otomatik (planlayıcı belleğe göre seçer).
  final int contextSize;
  final ComputeMode computeMode;
  final bool disableMmproj;

  BackendConfig({
    required this.type,
    required this.executablePath,
    required this.modelPathOrName,
    this.port = 8080,
    this.contextSize = 0,
    this.computeMode = ComputeMode.auto,
    this.disableMmproj = false,
  });

  bool get useGpu => computeMode != ComputeMode.cpu;

  BackendConfig copyWith({bool? disableMmproj}) => BackendConfig(
        type: type,
        executablePath: executablePath,
        modelPathOrName: modelPathOrName,
        port: port,
        contextSize: contextSize,
        computeMode: computeMode,
        disableMmproj: disableMmproj ?? this.disableMmproj,
      );
}

final lastBackendStatusMessageProvider = StateProvider<String?>((ref) => null);

/// Son başlatma planı (Ayarlar'da gösterilir) ve yüklemeden sonra ölçülen GPU kullanımı.
final lastLaunchPlanProvider = StateProvider<LaunchPlan?>((ref) => null);
final lastGpuUsageBytesProvider = StateProvider<int?>((ref) => null);

class BackendManager {
  final Ref _ref;
  Process? _activeProcess;
  bool _isStopping = false;

  /// Başlatma/durdurma işlemleri sırayla yürür: aynı anda iki model yüklenemez.
  Future<void> _queue = Future.value();

  BackendManager(this._ref);

  /// llama-server'ın paylaşımlı kütüphanelerini bulabilmesi için ortam değişkenleri.
  static Map<String, String> libraryEnvFor(String binDir) {
    final extra = <String, String>{};
    if (Platform.isLinux) {
      final prev = Platform.environment['LD_LIBRARY_PATH'] ?? '';
      extra['LD_LIBRARY_PATH'] = prev.isEmpty ? binDir : '$binDir:$prev';
    } else if (Platform.isMacOS) {
      final prev = Platform.environment['DYLD_LIBRARY_PATH'] ?? '';
      extra['DYLD_LIBRARY_PATH'] = prev.isEmpty ? binDir : '$binDir:$prev';
    }
    return AppPaths.buildSubprocessEnv(extra: extra);
  }

  Future<T> _serial<T>(Future<T> Function() body) {
    final run = _queue.then((_) => body());
    _queue = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<void> startBackend(BackendConfig config) => _serial(() => _start(config));

  Future<void> stopBackend({int port = 8080}) {
    // Süren bir yüklemenin sağlık beklemesini hemen kes.
    _isStopping = true;
    _ref.read(isBackendRunningProvider.notifier).state = false;
    return _serial(() => _stop(port: port));
  }

  void _status(String? msg) => _ref.read(lastBackendStatusMessageProvider.notifier).state = msg;

  Future<void> _start(BackendConfig config) async {
    _isStopping = false;
    _status(null);

    if (config.type == BackendType.llamaCpp && !File(config.executablePath).existsSync()) {
      final err =
          'llama-server bulunamadı (${config.executablePath}). Ayarlar > Genel sekmesinden tek tıkla otonom kurabilirsiniz.';
      _log(err);
      _status(err);
      _ref.read(isBackendRunningProvider.notifier).state = false;
      return;
    }

    // Önce eski motoru tamamen kapat: bellek ölçümü ve plan ancak bundan sonra doğru olur.
    if (_activeProcess != null) {
      _log('Önceki motor durduruluyor...');
      await _stop(port: config.port);
      _isStopping = false;
    }
    await _ensurePortFree(config.port);

    final binDir = p.dirname(config.executablePath);
    if (config.type == BackendType.llamaCpp && !Platform.isWindows) {
      await SystemInstallerNotifier.repairSharedLibSymlinks(binDir);
    }
    final env = libraryEnvFor(binDir);

    List<String> args;
    String? attachedMmproj;
    var healthTimeout = const Duration(minutes: 3);
    int? gpuFreeBefore;
    if (config.type == BackendType.llamaCpp) {
      _status('Bellek ölçülüyor ve model planlanıyor...');
      final hw = await HardwareProbe.probe(llamaServer: config.executablePath, env: env);
      final flags = await HardwareProbe.llamaFlags(config.executablePath, env);
      final info = await GgufReader.readAsync(config.modelPathOrName);
      final modelBytes = info?.weightBytes ?? _fileSize(config.modelPathOrName);
      attachedMmproj = config.disableMmproj ? null : await _findMatchingMmproj(config.modelPathOrName);
      final plan = ModelLaunchPlanner.plan(
        modelBytes: modelBytes,
        info: info,
        hw: hw,
        mode: config.computeMode,
        requestedCtx: config.contextSize,
        extraGpuBytes: attachedMmproj != null ? _fileSize(attachedMmproj) : 0,
        flags: flags,
      );
      _ref.read(lastLaunchPlanProvider.notifier).state = plan;
      _log('Donanım: ${hw.describe()}');
      _log('Model: ${info ?? config.modelPathOrName}');
      _log('Plan: $plan');
      if (!plan.canStart) {
        _status(plan.blocker);
        _ref.read(isBackendRunningProvider.notifier).state = false;
        return;
      }
      gpuFreeBefore = hw.primaryGpu?.freeBytes;
      args = _llamaArgs(config, plan, attachedMmproj, hasGpu: hw.primaryGpu != null);
      // Büyük modeller diskten okunup GPU'ya aktarılırken dakikalar sürebilir.
      healthTimeout = Duration(seconds: (180 + modelBytes ~/ (400 << 20)).clamp(180, 1500));
      _status('Model yükleniyor: ${plan.summary}');
    } else {
      args = _otherArgs(config);
    }

    _log('${config.type.name} başlatılıyor: ${config.executablePath} ${args.join(' ')}');
    final recentErrLines = <String>[];
    try {
      if (Platform.isWindows) {
        _activeProcess = await Process.start(config.executablePath, args,
            workingDirectory: binDir, runInShell: false, environment: env);
      } else {
        // POSIX ebeveyn-izleyici: FerIDE kapanırsa motor da kapanır. Linux'ta motorun
        // oom_score_adj değeri yükseltilir: RAM biterse çekirdek masaüstünü ya da
        // FerIDE'yi değil, önce modeli kapatır.
        final dartPid = pid;
        final script = [
          r'EXE="$1"; shift',
          r'"$EXE" "$@" &',
          r'CHILD_PID=$!',
          r'[ -w /proc/$CHILD_PID/oom_score_adj ] && echo 800 > /proc/$CHILD_PID/oom_score_adj 2>/dev/null',
          '( while kill -0 $dartPid 2>/dev/null; do sleep 2; done; kill -9 \$CHILD_PID 2>/dev/null ) &',
          r'wait $CHILD_PID',
        ].join('\n');
        _activeProcess = await Process.start(
          'sh',
          ['-c', script, '--', config.executablePath, ...args],
          runInShell: false,
          environment: env,
        );
      }

      _activeProcess!.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen((data) => print('[Backend STDOUT]: $data'));
      _activeProcess!.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen((line) {
        print('[Backend STDERR]: $line');
        if (line.trim().isNotEmpty) {
          recentErrLines.add(line.trim());
          if (recentErrLines.length > 60) recentErrLines.removeAt(0);
        }
      });

      final isHealthy = await _pollHealthCheck('http://127.0.0.1:${config.port}', config.type, healthTimeout);

      if (isHealthy && !_isStopping) {
        _log('${config.type.name} başarıyla ayaklandı ve trafiğe hazır!');
        _ref.read(isBackendRunningProvider.notifier).state = true;
        _status(null);
        if (gpuFreeBefore != null) unawaited(_measureGpuUsage(config, env, gpuFreeBefore));
      } else if (_isStopping) {
        _log('Yükleme kullanıcı tarafından durduruldu.');
      } else if (attachedMmproj != null && !config.disableMmproj && !_looksLikeMemoryError(recentErrLines)) {
        // mmproj uyumsuzsa model mmproj olmadan bir kez daha denenir.
        _log('Uyarı: mmproj ($attachedMmproj) ile başlatma başarısız; mmproj olmadan yeniden deneniyor...');
        await _stop(port: config.port);
        await _start(config.copyWith(disableMmproj: true));
      } else {
        final reason = explainFailure(recentErrLines);
        _log('Hata: Model motoru başlatılamadı ($reason)');
        _status(reason);
        await _stop(port: config.port);
      }
    } catch (e) {
      _log('Kritik Hata: Arka uç başlatılırken istisna fırlatıldı - $e');
      _status(e.toString());
      _ref.read(isBackendRunningProvider.notifier).state = false;
    }
  }

  static int _fileSize(String path) {
    try {
      return GgufReader.splitParts(path)
          .fold<int>(0, (a, f) => a + (File(f).existsSync() ? File(f).lengthSync() : 0));
    } catch (_) {
      return 0;
    }
  }

  /// Yüklemeden sonra GPU'da gerçekten kullanılan belleği ölçer.
  Future<void> _measureGpuUsage(BackendConfig config, Map<String, String> env, int freeBefore) async {
    try {
      final hw = await HardwareProbe.probe(llamaServer: config.executablePath, env: env);
      final after = hw.primaryGpu?.freeBytes;
      if (after != null) {
        _ref.read(lastGpuUsageBytesProvider.notifier).state = (freeBefore - after).clamp(0, freeBefore);
      }
    } catch (_) {}
  }

  List<String> _llamaArgs(BackendConfig config, LaunchPlan plan, String? mmproj, {required bool hasGpu}) {
    final base = p.basename(config.modelPathOrName).toLowerCase();
    final isMtpModel = !hasGpu &&
        (base.contains('thinkingcap') || base.contains('huihui') || base.contains('mtp') || base.contains('nextn'));
    return [
      '-m', config.modelPathOrName,
      ...plan.args,
      '-np', '1',
      '--port', config.port.toString(),
      '-fa', 'on',
      '-ctk', 'q8_0',
      '-ctv', 'q8_0',
      '-b', '2048',
      '-ub', plan.placement == 'cpu' ? '512' : '2048',
      '--cache-reuse', '256',
      '--cache-ram', '4096',
      if (isMtpModel) ...['--spec-type', 'draft-mtp'],
      if (mmproj != null) ...['--mmproj', mmproj],
    ];
  }

  List<String> _otherArgs(BackendConfig config) => switch (config.type) {
        BackendType.vllm => [
            'serve',
            config.modelPathOrName,
            '--port',
            config.port.toString(),
            '--tensor-parallel-size',
            '1',
          ],
        BackendType.ollama => ['serve'],
        BackendType.llamaCpp => const [],
      };

  static bool _looksLikeMemoryError(List<String> lines) => lines.any((l) => RegExp(
          r'out of memory|OutOfDeviceMemory|failed to allocate|Not enough memory|cudaMalloc|ErrorDeviceLost',
          caseSensitive: false)
      .hasMatch(l));

  /// llama-server'ın son çıktılarından kullanıcıya anlaşılır bir neden üretir.
  static String explainFailure(List<String> lines) {
    final all = lines.join('\n');
    bool has(String re) => RegExp(re, caseSensitive: false).hasMatch(all);
    if (has(r'ErrorDeviceLost|device lost|GPU hang|ring \S+ timeout')) {
      return 'GPU sürücüsü yanıt vermeyi kesti (GPU sıfırlandı). Ayarlar > Genel > Model Çalıştırma\'dan '
          '"Otomatik" veya "CPU offload" modunu seçip tekrar deneyin.';
    }
    if (has(r'out of memory|OutOfDeviceMemory|failed to allocate|Not enough memory|cudaMalloc|unable to allocate')) {
      return 'Model belleğe sığmadı (GPU/RAM yetersiz). Ayarlar > Genel > Model Çalıştırma\'dan "Otomatik" veya '
          '"CPU offload" modunu seçin ya da bağlam boyutunu küçültün.';
    }
    if (has(r'unknown model architecture|unsupported model')) {
      return 'Bu llama.cpp sürümü bu model mimarisini tanımıyor. Ayarlar > Genel\'den llama.cpp\'yi güncelleyin.';
    }
    if (has(r'failed to load model|error loading model|invalid magic|corrupt')) {
      return 'Model dosyası okunamadı (eksik veya bozuk indirme olabilir). Model Merkezi\'nden yeniden indirin.';
    }
    if (has(r"address already in use|couldn't bind")) {
      return 'Model sunucusunun portu başka bir uygulama tarafından kullanılıyor.';
    }
    return lines.isNotEmpty ? lines.last : 'Model motoru zamanında yanıt vermedi.';
  }

  Future<void> _stop({int port = 8080}) async {
    _isStopping = true;
    _ref.read(isBackendRunningProvider.notifier).state = false;
    _ref.read(lastGpuUsageBytesProvider.notifier).state = null;
    if (_activeProcess != null) {
      _log('Aktif süreç ağacı temizleniyor (PID: ${_activeProcess!.pid})...');
      await ProcessTreeKiller.kill(_activeProcess!.pid);
      _activeProcess = null;
    }
    await _killProcessOnPort(port);
    // Sürücünün GPU belleğini geri vermesi için kısa bekleme (ölçüm doğru olsun).
    await Future.delayed(const Duration(milliseconds: 800));
    _log('Motor durduruldu ve port $port temizlendi.');
  }

  /// Seçilen GGUF modeline ait doğru mmproj dosyasını akıllı aile/önek eşleşmesiyle bulur.
  Future<String?> _findMatchingMmproj(String modelPath) async {
    final candidates = <String>[];
    final parentDir = File(modelPath).parent;
    final dirsToCheck = <String>{parentDir.path, ...AppPaths.modelScanDirs};
    for (final dPath in dirsToCheck) {
      final d = Directory(dPath);
      if (!d.existsSync()) continue;
      try {
        await for (final entity in d.list(recursive: true).handleError((_) {})) {
          if (entity is File || entity is Link) {
            final pLower = p.basename(entity.path).toLowerCase();
            if (pLower.endsWith('.gguf') && pLower.contains('mmproj')) candidates.add(entity.path);
          }
        }
      } catch (_) {}
    }
    return pickMmproj(modelPath, candidates, scanDirs: AppPaths.modelScanDirs);
  }

  /// Model için doğru görüntü projektörünü (mmproj) seçer.
  /// Adaylar, model adıyla en uzun ortak ada göre puanlanır; model adında
  /// parametre boyutu (ör. 35b) varsa eşleşmenin onu da içermesi gerekir. Böylece
  /// Qwen3.8-35B'ye Qwen3.8-27B'nin projektörü verilmez (eskiden "qwen3.8"
  /// ailesindeki ilk dosya seçiliyor ve model yüklenemiyordu).
  static String? pickMmproj(String modelPath, List<String> candidates, {Iterable<String> scanDirs = const []}) {
    String norm(String s) => p.basenameWithoutExtension(s).toLowerCase().replaceFirst(RegExp(r'-\d{5}-of-\d{5}$'), '');
    final model = norm(modelPath);
    final size = RegExp(r'(?:^|[-_.])(\d+(?:\.\d+)?b)(?=$|[-_.])').firstMatch(model)?.group(1);

    // Bir dizenin, başı veya "-", "_", "." sonrası konumlardan başlayan sonekleri.
    Iterable<String> starts(String s) sync* {
      yield s;
      for (var i = 0; i < s.length - 1; i++) {
        if ('-_.'.contains(s[i])) yield s.substring(i + 1);
      }
    }

    String common(String a, String b) {
      var n = 0;
      while (n < a.length && n < b.length && a[n] == b[n]) {
        n++;
      }
      return a.substring(0, n);
    }

    String? best;
    var bestScore = 0;
    for (final c in candidates) {
      final b = norm(c);
      final keys = <String>[
        if (b.contains('__')) b.split('__').first,
        if (b.contains('mmproj')) b.substring(0, b.indexOf('mmproj')),
        if (b.contains('mmproj')) b.substring(b.indexOf('mmproj') + 6),
      ].map((k) => k.replaceAll(RegExp(r'^[-_.]+|[-_.]+$'), '')).where((k) => k.length >= 3);
      for (final k in keys) {
        for (final ms in starts(model)) {
          for (final ks in starts(k)) {
            final cp = common(ms, ks);
            if (cp.length < 6) continue;
            if (size != null && !RegExp('(^|[-_.])${RegExp.escape(size)}(\$|[-_.])').hasMatch(cp)) continue;
            if (cp.length > bestScore) {
              bestScore = cp.length;
              best = c;
            }
          }
        }
      }
    }
    if (best != null) return best;

    // Model kendi alt klasöründeyse ve orada tek bir projektör varsa onu kullan.
    final parent = p.normalize(p.dirname(modelPath));
    if (!scanDirs.map(p.normalize).contains(parent)) {
      final local = candidates.where((c) => p.normalize(p.dirname(c)) == parent).toList();
      if (local.length == 1) return local.first;
    }
    return null;
  }

  Future<bool> _isProcessAlive(int targetPid) async {
    try {
      if (Platform.isWindows) {
        final res = await Process.run('tasklist', ['/FI', 'PID eq $targetPid', '/NH']);
        return res.stdout.toString().contains(targetPid.toString());
      }
      final res = await Process.run('ps', ['-p', '$targetPid']);
      return res.stdout.toString().contains(targetPid.toString());
    } catch (_) {
      return true;
    }
  }

  Future<bool> _pollHealthCheck(String baseUrl, BackendType type, Duration timeout) async {
    final endpoint = type == BackendType.ollama ? '/api/tags' : '/v1/models';
    final url = Uri.parse('$baseUrl$endpoint');
    final deadline = DateTime.now().add(timeout);
    _log('Sağlık kontrolü başlatıldı ($url, en fazla ${timeout.inSeconds} sn)...');
    var i = 0;
    while (DateTime.now().isBefore(deadline)) {
      if (_isStopping) return false;
      try {
        final response = await http.get(url).timeout(const Duration(seconds: 2));
        if (response.statusCode == 200) return true;
      } catch (_) {}
      if (++i > 2 && _activeProcess != null && !await _isProcessAlive(_activeProcess!.pid)) {
        _log('Hata: Motor süreci (PID ${_activeProcess!.pid}) erken sonlandı!');
        return false;
      }
      await Future.delayed(const Duration(seconds: 2));
    }
    return false;
  }

  Future<void> _ensurePortFree(int port) async {
    try {
      final socket = await ServerSocket.bind(InternetAddress.anyIPv4, port);
      await socket.close();
    } catch (_) {
      _log('Port $port meşgul. Temizleniyor...');
      await _killProcessOnPort(port);
      await Future.delayed(const Duration(seconds: 1));
    }
  }

  Future<void> _killProcessOnPort(int port) async {
    try {
      if (Platform.isWindows) {
        final res = await Process.run('cmd', ['/c', 'netstat -ano | findstr :$port']);
        for (final line in res.stdout.toString().trim().split(RegExp(r'\r?\n'))) {
          if (line.contains('LISTENING')) {
            final parts = line.trim().split(RegExp(r'\s+'));
            final pidVal = int.tryParse(parts.last);
            if (pidVal != null && pidVal > 0) await ProcessTreeKiller.kill(pidVal);
          }
        }
      } else {
        try {
          final res = await Process.run('lsof', ['-t', '-i:$port']);
          for (final pidStr in res.stdout.toString().trim().split('\n')) {
            final pidVal = int.tryParse(pidStr.trim());
            if (pidVal != null) {
              await ProcessTreeKiller.kill(pidVal);
              try {
                Process.killPid(pidVal, ProcessSignal.sigkill);
              } catch (_) {}
            }
          }
        } catch (_) {}
        if (Platform.isLinux) {
          try {
            await Process.run('fuser', ['-k', '$port/tcp']);
          } catch (_) {}
        }
        try {
          await Process.run('pkill', ['-9', '-f', 'llama-server.*$port']);
        } catch (_) {}
      }
    } catch (e) {
      _log('Port boşaltma uyarısı: $e');
    }
  }

  void _log(String message) => print('[BackendManager] $message');
}

final backendManagerProvider = Provider<BackendManager>((ref) => BackendManager(ref));
