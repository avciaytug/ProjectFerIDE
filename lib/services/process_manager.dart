import 'dart:async';
import 'dart:convert' as dart_convert;
import 'dart:io';
import 'package:path/path.dart' as p;
import 'app_paths.dart';

/// FerIDE Çapraz Platform Ses Sunucuları Yaşam Döngüsü Yöneticisi (v5.3.8)
///
/// Linux, Windows ve macOS üzerinde gömülü/yerel faster-whisper STT (port 5052),
/// Türkçe kadın/erkek TTS (port 5050) ve WebSocket VAD (port 5051) servislerini
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
        'FERIDE_ROOT': AppPaths.appRoot,
        // Ses sunucuları çalışırken asla ağa çıkmaz: modeller yalnızca kurulumda iner.
        'HF_HUB_OFFLINE': '1',
        'TRANSFORMERS_OFFLINE': '1',
      });

  /// Tek ses sunucusu: kadın (Ahenk Cep) ve erkek (Piper) sesleri birlikte sunar.
  static (String python, String script, String pgrep) _resolveTtsServer() =>
      (AppPaths.resolvePython(preferVoiceEnv: false), 'tts_server.py', 'tts_server.py');

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

  /// Birim testlerinde gerçek ses sunucusu başlatılmaz (FERIDE_INTEGRATION=1 hariç).
  static bool get _disabledInTests =>
      Platform.environment.containsKey('FLUTTER_TEST') && Platform.environment['FERIDE_INTEGRATION'] != '1';

  Future<void> startAll() async {
    if (_disabledInTests) return;
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

      if (_processes.containsKey(name)) continue;
      final scriptName0 = s['script'] as String;
      final fp = _fingerprint(AppPaths.scriptPath(scriptName0));
      // Karar yalnızca portu dinleyen sunucuya göre verilir; aynı adda başka
      // bir süreç bulunması (pgrep) portun hizmet verdiği anlamına gelmez.
      if (await _isPortOpen(port)) {
        // Portta bir sunucu var. Aynı betik sürümünü çalıştırıyorsa kullan;
        // eski bir sürümden (veya çökmüş bir oturumdan) kalmışsa yenile.
        if (_runRecordMatches(name, fp)) {
          _log('$name: güncel sunucu zaten çalışıyor (port=$port), yeniden kullanılıyor');
          continue;
        }
        if (!await _replaceStaleServer(name, scriptName0, port)) {
          _log('$name: portta eski bir sunucu var ve yenilenemedi (port=$port), mevcut olan kullanılacak');
          continue;
        }
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
        _writeRunRecord(name, proc.pid, fp);
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

  // ---------------------------------------------------------------------------
  // Sunucu sürüm takibi: ~/.feride/run/<ad>.json = {pid, fp}. fp betiğin
  // boyutu+değiştirilme zamanıdır; betik güncellenince eski süreç yenilenir.
  // ---------------------------------------------------------------------------
  static String _fingerprint(String path) {
    try {
      final st = File(path).statSync();
      return '${st.size}-${st.modified.millisecondsSinceEpoch}';
    } catch (_) {
      return 'yok';
    }
  }

  static File _runFile(String name) => File(p.join(AppPaths.ferideDataDir, 'run', '$name.json'));

  void _writeRunRecord(String name, int pid, String fp) {
    try {
      final f = _runFile(name);
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(dart_convert.jsonEncode({'pid': pid, 'fp': fp}));
    } catch (_) {}
  }

  bool _runRecordMatches(String name, String fp) {
    try {
      final rec = dart_convert.jsonDecode(_runFile(name).readAsStringSync()) as Map;
      return rec['fp'] == fp && _pidAlive((rec['pid'] as num).toInt());
    } catch (_) {
      return false;
    }
  }

  static bool _pidAlive(int pid) {
    if (Platform.isLinux) return Directory('/proc/$pid').existsSync();
    if (Platform.isWindows) return true; // Windows'ta güvenli varsayım: dokunma
    try {
      return Process.runSync('kill', ['-0', '$pid']).exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// Yalnızca FerIDE ses betiklerini çalıştıran eski süreçleri sonlandırır.
  Future<bool> _replaceStaleServer(String name, String script, int port) async {
    if (Platform.isWindows) return false;
    final pids = <int>{};
    try {
      final rec = dart_convert.jsonDecode(_runFile(name).readAsStringSync()) as Map;
      pids.add((rec['pid'] as num).toInt());
    } catch (_) {}
    try {
      final r = Process.runSync('pgrep', ['-f', 'scripts/$script']);
      for (final l in r.stdout.toString().split('\n')) {
        final v = int.tryParse(l.trim());
        if (v != null) pids.add(v);
      }
    } catch (_) {}
    var killed = false;
    for (final target in pids) {
      if (target == pid) continue; // kendi sürecimiz
      if (!_isFerideScriptProcess(target, script)) continue;
      _log('$name: eski sürüm sunucu yenileniyor (pid=$target)');
      killed = Process.killPid(target, ProcessSignal.sigterm) || killed;
    }
    if (!killed) return false;
    for (var i = 0; i < 30 && await _isPortOpen(port); i++) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    return !await _isPortOpen(port);
  }

  static bool _isFerideScriptProcess(int pid, String script) {
    if (Platform.isLinux) {
      try {
        final cmd = File('/proc/$pid/cmdline').readAsStringSync();
        return cmd.contains('scripts/$script');
      } catch (_) {
        return false;
      }
    }
    try {
      final r = Process.runSync('ps', ['-o', 'command=', '-p', '$pid']);
      return r.stdout.toString().contains('scripts/$script');
    } catch (_) {
      return false;
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
    // Yalnızca BU uygulamanın başlattığı süreçler öldürülür. Eskiden
    // `pkill -f stt_server.py` ile sistemdeki tüm eşleşen süreçler (başka bir
    // FerIDE örneği veya testler dahil) öldürülüyordu.
    _processes.clear();
  }

}
