import 'dart:async';
import 'dart:convert' as dart_convert;
import 'dart:io';
import 'package:path/path.dart' as p;
import 'app_paths.dart';

/// FerIDE Çapraz Platform Ses Sunucuları Yaşam Döngüsü Yöneticisi (v5.3.4)
///
/// Linux, Windows ve macOS üzerinde gömülü/yerel faster-whisper STT (port 5052),
/// Türkçe Piper / Sistem TTS (port 5050) ve WebSocket VAD (port 5051) servislerini
/// otomatik başlatır, sağlık kontrolü yapar ve kapanışta temizler.
class ProcessManager {
  ProcessManager();
  static final ProcessManager instance = ProcessManager();

  final Map<String, Process> _processes = {};
  Future<void>? _startingFuture;

  int get runningCount => _processes.length;
  bool isRunning(String name) => _processes.containsKey(name);

  static Map<String, String> get _serverEnv => AppPaths.buildSubprocessEnv(extra: {
        'HSA_OVERRIDE_GFX_VERSION': '11.0.0',
        'COQUI_TOS_AGREED': '1',
      });

  /// Coqui XTTS kuruluysa xtts_server.py, değilse gömülü/sistem destekli piper_tts_server.py seçer
  static (String python, String script, String pgrep) _resolveTtsServer() {
    final voicePy = AppPaths.resolvePython(preferVoiceEnv: true);
    try {
      final check = Process.runSync(
        voicePy,
        ['-c', 'import TTS; print("OK")'],
        environment: _serverEnv,
      );
      if (check.exitCode == 0 && check.stdout.toString().contains('OK')) {
        return (voicePy, 'xtts_server.py', 'xtts_server.py');
      }
    } catch (_) {}

    final venvPy = AppPaths.resolvePython(preferVoiceEnv: false);
    final piperScript = File(AppPaths.scriptPath('piper_tts_server.py'));
    if (piperScript.existsSync()) {
      // piper_tts_server.py hem gömülü Türkçe Piper modelini hem de macOS/Windows/Linux
      // yerel sistem seslendiricilerini destekler.
      return (venvPy, 'piper_tts_server.py', 'piper_tts_server.py');
    }
    return (venvPy, 'edge_tts_server.py', 'edge_tts_server.py');
  }

  void _log(String line) {
    final msg = '[${DateTime.now().toIso8601String()}] $line';
    print('ProcessManager: $msg');
    try {
      final logDir = Directory(p.join(AppPaths.ferideDataDir, 'logs'));
      if (!logDir.existsSync()) logDir.createSync(recursive: true);
      File(p.join(logDir.path, 'process_manager.log'))
          .writeAsStringSync('$msg\n', mode: FileMode.append, flush: true);
    } catch (_) {}
  }

  Future<bool> _isPortOpen(int port) async {
    try {
      final socket = await Socket.connect(
        '127.0.0.1',
        port,
        timeout: const Duration(milliseconds: 250),
      );
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> startAll() async {
    if (_startingFuture != null) {
      return _startingFuture!;
    }
    final completer = Completer<void>();
    _startingFuture = completer.future;
    try {
      await _startAllInternal();
    } finally {
      _startingFuture = null;
      completer.complete();
    }
  }

  Future<void> _startAllInternal() async {
    final sttPy = AppPaths.resolvePython(preferVoiceEnv: true);
    final ttsInfo = _resolveTtsServer();

    final servers = <Map<String, Object>>[
      {'name': 'stt', 'script': 'stt_server.py', 'pgrep': 'stt_server.py', 'python': sttPy, 'port': 5052},
      {'name': 'tts', 'script': ttsInfo.$2, 'pgrep': ttsInfo.$3, 'python': ttsInfo.$1, 'port': 5050},
      {'name': 'vad', 'script': 'voice_engine_daemon.py', 'pgrep': 'voice_engine_daemon.py', 'python': sttPy, 'port': 5051},
    ];

    final logDir = Directory(p.join(AppPaths.ferideDataDir, 'logs'));
    if (!logDir.existsSync()) {
      try {
        logDir.createSync(recursive: true);
      } catch (_) {}
    }

    for (final s in servers) {
      final name = s['name'] as String;
      final port = s['port'] as int;
      final pgrepPattern = s['pgrep'] as String;

      if (_processes.containsKey(name)) continue;
      if (await _isPortOpen(port) || _alreadyRunning(pgrepPattern)) {
        _log('$name: zaten çalışıyor (port=$port / $pgrepPattern), atlanıyor');
        continue;
      }

      final python = s['python'] as String;
      final scriptName = s['script'] as String;
      final scriptFullPath = AppPaths.scriptPath(scriptName);
      if (!File(scriptFullPath).existsSync()) {
        _log('$name: betik bulunamadı ($scriptFullPath)');
        continue;
      }

      try {
        final proc = await Process.start(
          python,
          [scriptFullPath],
          environment: _serverEnv,
        );
        _processes[name] = proc;
        _log('$name: başlatıldı (python=$python, script=$scriptFullPath, pid=${proc.pid})');

        final procLogFile = File(p.join(logDir.path, '${name}_process.log'));
        proc.stdout
            .transform(const dart_convert.Utf8Decoder(allowMalformed: true))
            .listen((chunk) {
          try {
            procLogFile.writeAsStringSync(chunk, mode: FileMode.append);
          } catch (_) {}
        });
        proc.stderr
            .transform(const dart_convert.Utf8Decoder(allowMalformed: true))
            .listen((chunk) {
          try {
            procLogFile.writeAsStringSync(chunk, mode: FileMode.append);
          } catch (_) {}
        });

        proc.exitCode.then((code) {
          _processes.remove(name);
          if (code != 0) {
            _log('$name: kapandı (exit=$code, script=$scriptName)');
          }
        });
      } catch (e) {
        _log('$name: başlatılamadı ($e)');
      }
    }
  }

  /// STT sunucusunun (port 5052) model yüklemesini tamamlayıp hazır olmasını bekler
  Future<bool> ensureSttReady({Duration timeout = const Duration(seconds: 25)}) async {
    await startAll();
    final deadline = DateTime.now().add(timeout);
    final client = HttpClient()..connectionTimeout = const Duration(milliseconds: 800);
    try {
      while (DateTime.now().isBefore(deadline)) {
        try {
          final req = await client.getUrl(Uri.parse('http://127.0.0.1:5052/health'));
          final res = await req.close().timeout(const Duration(seconds: 2));
          await res.drain();
          if (res.statusCode == 200) {
            return true;
          }
        } catch (_) {}
        await Future.delayed(const Duration(milliseconds: 350));
      }
    } finally {
      client.close(force: true);
    }
    return false;
  }

  /// Canlı Oturum (VAD WebSocket port 5051 + STT port 5052) hazır olana kadar bekler
  Future<bool> ensureVadReady({Duration timeout = const Duration(seconds: 20)}) async {
    await startAll();
    final sttOk = await ensureSttReady(timeout: timeout);
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (DateTime.now().isBefore(deadline)) {
      if (await _isPortOpen(5051)) {
        return sttOk;
      }
      await Future.delayed(const Duration(milliseconds: 300));
    }
    return false;
  }

  void killAll() {
    for (final proc in _processes.values) {
      try {
        if (Platform.isWindows) {
          proc.kill();
        } else {
          proc.kill(ProcessSignal.sigkill);
        }
      } catch (_) {}
    }
    _processes.clear();

    const patterns = [
      'stt_server.py',
      'xtts_server.py',
      'piper_tts_server.py',
      'edge_tts_server.py',
      'voice_engine_daemon.py',
    ];

    if (Platform.isWindows) {
      try {
        final regex = patterns.map((e) => e.replaceAll('.', r'\.')).join('|');
        Process.runSync('powershell', [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          "Get-CimInstance Win32_Process | Where-Object { \$_.CommandLine -match '$regex' } | ForEach-Object { Stop-Process -Id \$_.ProcessId -Force -ErrorAction SilentlyContinue }",
        ]);
      } catch (_) {}
    } else {
      for (final pattern in patterns) {
        try {
          Process.runSync('pkill', ['-f', pattern]);
        } catch (_) {}
      }
    }
  }

  bool _alreadyRunning(String pattern) {
    if (Platform.isWindows) {
      try {
        final r = Process.runSync('powershell', [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          "if (Get-CimInstance Win32_Process | Where-Object { \$_.CommandLine -like '*$pattern*' }) { exit 0 } else { exit 1 }",
        ]);
        return r.exitCode == 0;
      } catch (_) {
        return false;
      }
    }
    try {
      final r = Process.runSync('pgrep', ['-f', pattern]);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  Future<void> unloadOllamaModels() async {
    try {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
      final request = await client.getUrl(Uri.parse('http://127.0.0.1:11434/api/ps'));
      final response = await request.close();
      if (response.statusCode == 200) {
        final body = await response.transform(dart_convert.utf8.decoder).join();
        final data = dart_convert.jsonDecode(body);
        final models = data['models'] as List?;
        if (models != null) {
          for (final m in models) {
            final modelName = m['name'];
            final postReq = await client.postUrl(Uri.parse('http://127.0.0.1:11434/api/generate'));
            postReq.headers.contentType = ContentType.json;
            postReq.write(dart_convert.jsonEncode({'model': modelName, 'keep_alive': 0}));
            final postRes = await postReq.close();
            await postRes.drain();
          }
        }
      }
      client.close();
    } catch (_) {}
  }
}
