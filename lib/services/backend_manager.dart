import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'app_paths.dart';
import 'pty_sandbox.dart';
import 'system_installer_service.dart';
import '../features/chat/state.dart';

enum BackendType { llamaCpp, vllm, ollama }

class BackendConfig {
  final BackendType type;
  final String executablePath;
  final String modelPathOrName;
  final int port;
  final int contextSize;
  final int threads;
  final bool useGpu;
  final bool disableMmproj;

  BackendConfig({
    required this.type,
    required this.executablePath,
    required this.modelPathOrName,
    this.port = 8080,
    this.contextSize = 4096,
    this.threads = 8,
    this.useGpu = true,
    this.disableMmproj = false,
  });

  BackendConfig copyWith({bool? disableMmproj}) {
    return BackendConfig(
      type: type,
      executablePath: executablePath,
      modelPathOrName: modelPathOrName,
      port: port,
      contextSize: contextSize,
      threads: threads,
      useGpu: useGpu,
      disableMmproj: disableMmproj ?? this.disableMmproj,
    );
  }
}

final lastBackendStatusMessageProvider = StateProvider<String?>((ref) => null);

class BackendManager {
  final Ref _ref;
  Process? _activeProcess;
  bool _isStopping = false;

  BackendManager(this._ref);

  Map<String, String> _libraryEnvFor(String binDir) {
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

  Future<void> startBackend(BackendConfig config) async {
    _isStopping = false;
    _ref.read(lastBackendStatusMessageProvider.notifier).state = null;

    if (config.type == BackendType.llamaCpp && !File(config.executablePath).existsSync()) {
      final err =
          'llama-server bulunamadı (${config.executablePath}). Ayarlar > Genel sekmesinden tek tıkla otonom kurabilirsiniz.';
      _log(err);
      _ref.read(lastBackendStatusMessageProvider.notifier).state = err;
      _ref.read(isBackendRunningProvider.notifier).state = false;
      return;
    }

    if (_activeProcess != null) {
      _log('Önceki motor çalışıyor, durduruluyor...');
      await stopBackend(port: config.port);
      _isStopping = false;
    }

    _log('Bağlantı noktası (${config.port}) kontrol ediliyor...');
    await _ensurePortFree(config.port);

    final binDir = p.dirname(config.executablePath);
    if (config.type == BackendType.llamaCpp && !Platform.isWindows) {
      await SystemInstallerNotifier.repairSharedLibSymlinks(binDir);
    }

    final (args, attachedMmproj) = await _buildArgs(config);
    _log('${config.type.name} başlatılıyor: ${config.executablePath}');

    try {
      final backendEnv = _libraryEnvFor(binDir);

      if (Platform.isWindows) {
        _activeProcess = await Process.start(
          config.executablePath,
          args,
          workingDirectory: binDir,
          runInShell: false,
          environment: backendEnv,
        );
      } else {
        // Linux ve macOS ile %100 POSIX uyumlu ebeveyn-izleyici (GNU tail --pid gerektirmez!)
        // Not: "\${@:2}" bash'e özgüdür; /bin/sh -> dash olan Ubuntu/Kubuntu'da
        // "Bad substitution" verip motoru hiç başlatmıyordu. POSIX 'shift' kullanılır.
        final dartPid = pid;
        final shArgs = [
          '-c',
          '''
          EXE="\$1"; shift
          "\$EXE" "\$@" &
          CHILD_PID=\$!
          ( while kill -0 $dartPid 2>/dev/null; do sleep 2; done; kill -9 \$CHILD_PID 2>/dev/null ) &
          wait \$CHILD_PID
          ''',
          '--',
          config.executablePath,
          ...args,
        ];
        _activeProcess = await Process.start(
          'sh',
          shArgs,
          runInShell: false,
          environment: backendEnv,
        );
      }

      final recentErrLines = <String>[];

      _activeProcess!.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen((data) {
        print('[Backend STDOUT]: $data');
      });

      _activeProcess!.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen((line) {
        print('[Backend STDERR]: $line');
        if (line.trim().isNotEmpty) {
          recentErrLines.add(line.trim());
          if (recentErrLines.length > 20) recentErrLines.removeAt(0);
        }
      });

      final isHealthy = await _pollHealthCheck('http://127.0.0.1:${config.port}', config.type);

      if (isHealthy && !_isStopping) {
        _log('${config.type.name} başarıyla ayaklandı ve trafiğe hazır!');
        _ref.read(isBackendRunningProvider.notifier).state = true;
        _ref.read(lastBackendStatusMessageProvider.notifier).state = null;
      } else if (!_isStopping && attachedMmproj != null && !config.disableMmproj) {
        // Kendi kendini iyileştirme (Self-Healing): mmproj uyumsuzsa mmproj olmadan otomatik yeniden başlat!
        _log('Uyarı: mmproj ($attachedMmproj) ile başlatma başarısız oldu; salt model ile otomatik yeniden deneniyor...');
        await stopBackend(port: config.port);
        await startBackend(config.copyWith(disableMmproj: true));
      } else {
        final tailErr = recentErrLines.isNotEmpty ? recentErrLines.last : 'Sağlık kontrolü zaman aşımına uğradı.';
        _log('Hata: Model motoru başlatılamadı ($tailErr)');
        _ref.read(lastBackendStatusMessageProvider.notifier).state = tailErr;
        await stopBackend(port: config.port);
      }
    } catch (e) {
      _log('Kritik Hata: Arka uç başlatılırken istisna fırlatıldı - $e');
      _ref.read(lastBackendStatusMessageProvider.notifier).state = e.toString();
      _ref.read(isBackendRunningProvider.notifier).state = false;
    }
  }

  Future<void> stopBackend({int port = 8080}) async {
    _isStopping = true;
    _ref.read(isBackendRunningProvider.notifier).state = false;
    if (_activeProcess != null) {
      _log('Aktif süreç ağacı temizleniyor (PID: ${_activeProcess!.pid})...');
      await ProcessTreeKiller.kill(_activeProcess!.pid);
      _activeProcess = null;
    }
    await _killProcessOnPort(port);
    _log('Motor durduruldu ve port $port temizlendi.');
  }

  Future<(List<String>, String?)> _buildArgs(BackendConfig config) async {
    switch (config.type) {
      case BackendType.llamaCpp:
        final safeContextSize = config.contextSize;
        String? gpuDevice;

        if (config.useGpu) {
          try {
            final binDir = p.dirname(config.executablePath);
            final env = _libraryEnvFor(binDir);
            final devRes = Process.runSync(
              config.executablePath,
              ['--list-devices'],
              environment: env,
            );
            final out = '${devRes.stdout}\n${devRes.stderr}';
            final m = RegExp(r'\b(Vulkan\d+|CUDA\d+|ROCm\d+|MTL\d+)\b').firstMatch(out);
            if (m != null) {
              gpuDevice = m.group(1);
            }
          } catch (_) {}
        }

        final args = <String>[
          '-m', config.modelPathOrName,
          if (config.useGpu && gpuDevice != null && gpuDevice.startsWith('Vulkan')) ...[
            '--device',
            gpuDevice,
          ],
          '-c', safeContextSize.toString(),
          '-np', '1',
          '--port', config.port.toString(),
          '-t', config.threads.toString(),
          '-fa', 'on',
          '-ctk', 'q8_0',
          '-ctv', 'q8_0',
          '-ngl', config.useGpu ? '999' : '0',
          '-b', '2048',
          '-ub', '2048',
          '--cache-reuse', '256',
          '--cache-ram', '8192',
        ];

        final modelBaseLower = p.basename(config.modelPathOrName).toLowerCase();
        final bool isMtpModel = gpuDevice == null &&
            (modelBaseLower.contains('thinkingcap') ||
                modelBaseLower.contains('huihui') ||
                modelBaseLower.contains('mtp') ||
                modelBaseLower.contains('nextn'));
        if (isMtpModel) {
          args.addAll(['--spec-type', 'draft-mtp']);
        }

        String? foundMmproj;
        if (!config.disableMmproj) {
          foundMmproj = await _findMatchingMmproj(config.modelPathOrName);
          if (foundMmproj != null) {
            _log('Görme (Vision mmproj) eklentisi otomatik eşleşti: $foundMmproj');
            args.addAll(['--mmproj', foundMmproj]);
          }
        }
        return (args, foundMmproj);

      case BackendType.vllm:
        return (
          [
            'serve',
            config.modelPathOrName,
            '--port',
            config.port.toString(),
            '--tensor-parallel-size',
            '1',
          ],
          null,
        );

      case BackendType.ollama:
        return (['serve'], null);
    }
  }

  /// Seçilen GGUF modeline ait doğru mmproj dosyasını akıllı aile/önek eşleşmesiyle bulur.
  Future<String?> _findMatchingMmproj(String modelPath) async {
    final modelBase = p.basenameWithoutExtension(modelPath).toLowerCase();

    final familyKeywords = <String>[
      'gemma-4-27b',
      'gemma-4-12b',
      'gemma-4-4b',
      'gemma-4',
      'gemma-3-27b',
      'gemma-3-12b',
      'gemma-3-4b',
      'gemma-3',
      'qwen3.8',
      'qwen3.5',
      'qwen3-vl',
      'qwen2.5-vl',
      'qwen2-vl',
      'pixtral',
      'llava',
      'minicpm',
      'internvl',
      'molmo',
      'smolvlm',
    ];

    String? detectedFamily;
    for (final fk in familyKeywords) {
      if (modelBase.contains(fk)) {
        detectedFamily = fk;
        break;
      }
    }

    final candidates = <String>[];
    final parentDir = File(modelPath).parent;
    final dirsToCheck = <String>{
      parentDir.path,
      ...AppPaths.modelScanDirs,
    };

    for (final dPath in dirsToCheck) {
      final d = Directory(dPath);
      if (!d.existsSync()) continue;
      try {
        await for (final entity in d.list(recursive: true).handleError((_) {})) {
          if (entity is File || entity is Link) {
            final pLower = p.basename(entity.path).toLowerCase();
            if (pLower.endsWith('.gguf') && pLower.contains('mmproj')) {
              candidates.add(entity.path);
            }
          }
        }
      } catch (_) {}
    }

    if (candidates.isEmpty) return null;

    // 1. Tam önek eşleşmesi (örn. gemma-4-12b-it__mmproj-F16.gguf <-> gemma-4-12b-it-UD-Q8_K_XL.gguf)
    for (final c in candidates) {
      final cBase = p.basenameWithoutExtension(c).toLowerCase();
      if (cBase.contains('__')) {
        final repoPrefix = cBase.split('__').first;
        if (repoPrefix.isNotEmpty && modelBase.contains(repoPrefix)) {
          return c;
        }
      }
    }

    // 2. Model ailesi eşleşmesi (örn. gemma-4-12b)
    if (detectedFamily != null) {
      for (final c in candidates) {
        final cLower = p.basename(c).toLowerCase();
        if (cLower.contains(detectedFamily)) {
          return c;
        }
      }
      final broadFamily = detectedFamily.split('-').take(2).join('-');
      for (final c in candidates) {
        final cLower = p.basename(c).toLowerCase();
        if (broadFamily.length >= 5 && cLower.contains(broadFamily)) {
          return c;
        }
      }
    }

    // 3. Model kendi özel alt klasöründeyse ve aynı klasörde mmproj varsa
    final modelParentNorm = p.normalize(parentDir.path);
    final scanNorms = AppPaths.modelScanDirs.map(p.normalize).toSet();
    if (!scanNorms.contains(modelParentNorm)) {
      for (final c in candidates) {
        if (p.normalize(p.dirname(c)) == modelParentNorm) {
          return c;
        }
      }
    }

    return null;
  }

  Future<bool> _isProcessAlive(int targetPid) async {
    try {
      if (Platform.isWindows) {
        final res = await Process.run('tasklist', ['/FI', 'PID eq $targetPid', '/NH']);
        return res.stdout.toString().contains(targetPid.toString());
      } else {
        final res = await Process.run('ps', ['-p', '$targetPid']);
        return res.stdout.toString().contains(targetPid.toString());
      }
    } catch (_) {
      return true;
    }
  }

  Future<bool> _pollHealthCheck(String baseUrl, BackendType type) async {
    final endpoint = type == BackendType.ollama ? '/api/tags' : '/v1/models';
    final url = Uri.parse('$baseUrl$endpoint');

    _log('Sağlık kontrolü başlatıldı ($url)...');

    for (int i = 0; i < 90; i++) {
      if (_isStopping) return false;

      try {
        final response = await http.get(url).timeout(const Duration(seconds: 2));
        if (response.statusCode == 200) {
          return true;
        }
      } catch (_) {}

      if (i > 2 && _activeProcess != null) {
        final alive = await _isProcessAlive(_activeProcess!.pid);
        if (!alive) {
          _log('Hata: Motor süreci (PID ${_activeProcess!.pid}) erken sonlandı!');
          return false;
        }
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

  void _log(String message) {
    print('[BackendManager] $message');
  }
}

final backendManagerProvider = Provider<BackendManager>((ref) {
  return BackendManager(ref);
});
