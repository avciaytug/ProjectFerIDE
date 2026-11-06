import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class ProcessTreeKiller {
  static Future<void> kill(int pid, {Duration grace = const Duration(milliseconds: 2000), bool force = true}) async {
    if (Platform.isWindows) {
      // Windows: taskkill /T (Tree) /PID
      try {
        await Process.run('taskkill', ['/T', '/PID', '$pid']);
        await Future.delayed(grace);
        if (force) {
          await Process.run('taskkill', ['/F', '/T', '/PID', '$pid']);
        }
      } catch (_) {}
    } else {
      // Linux / macOS: Collect descendants and kill
      final pids = await _collectDescendants(pid);
      pids.add(pid);
      
      // SIGTERM (15)
      for (final id in pids) {
        try { Process.killPid(id, ProcessSignal.sigterm); } catch (_) {}
      }
      
      await Future.delayed(grace);
      
      // SIGKILL (9)
      if (force) {
        for (final id in pids) {
          try { Process.killPid(id, ProcessSignal.sigkill); } catch (_) {}
        }
      }
    }
  }

  static Future<List<int>> _collectDescendants(int pid) async {
    final result = <int>[];
    final queue = [pid];
    
    while (queue.isNotEmpty) {
      final current = queue.removeAt(0);
      List<int> children = [];
      try {
        if (Platform.isMacOS) {
          final r = await Process.run('pgrep', ['-P', '$current']);
          children = _parsePids(r.stdout.toString());
        } else {
          // Linux
          final r = await Process.run('ps', ['-o', 'pid=', '--ppid', '$current']);
          children = _parsePids(r.stdout.toString());
        }
      } catch (_) {}
      
      for (final c in children) {
        if (!result.contains(c)) {
          result.add(c);
          queue.add(c);
        }
      }
    }
    return result;
  }

  static List<int> _parsePids(String s) {
    return s.trim().split(RegExp(r'\s+')).where((t) => int.tryParse(t) != null).map(int.parse).toList();
  }
}

class SandboxResult {
  final int exitCode;
  final String stdout;
  final String stderr;
  final bool timedOut;

  SandboxResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    this.timedOut = false,
  });
}

class PtySandbox {
  static final Set<int> _activePids = <int>{};

  /// Kullanıcı iptal ettiğinde veya oturum kapandığında çalışan tüm sandbox komut süreçlerini öldürür
  static Future<void> killAllActiveProcesses() async {
    final pids = List<int>.from(_activePids);
    _activePids.clear();
    for (final pid in pids) {
      try {
        await ProcessTreeKiller.kill(pid);
      } catch (_) {}
    }
  }

  static Future<SandboxResult> runCommand(String executable, List<String> args, {
    String? workingDirectory,
    Map<String, String>? environment,
    Duration? timeout,
    int maxOutputBytes = 1024 * 1024 * 5, // 5MB limit
  }) async {
    final process = await Process.start(
      executable,
      args,
      workingDirectory: workingDirectory,
      environment: environment,
      runInShell: false, // Security: Direct execution without shell injection vulnerabilities
    );

    _activePids.add(process.pid);

    final stdoutBuilder = BytesBuilder(copy: false);
    final stderrBuilder = BytesBuilder(copy: false);
    int stdoutBytes = 0;
    int stderrBytes = 0;

    final stdoutSub = process.stdout.listen((chunk) {
      if (stdoutBytes < maxOutputBytes) {
        final remaining = maxOutputBytes - stdoutBytes;
        if (chunk.length <= remaining) {
          stdoutBuilder.add(chunk);
          stdoutBytes += chunk.length;
        } else {
          stdoutBuilder.add(chunk.sublist(0, remaining));
          stdoutBytes += remaining;
        }
      }
    });

    final stderrSub = process.stderr.listen((chunk) {
      if (stderrBytes < maxOutputBytes) {
        final remaining = maxOutputBytes - stderrBytes;
        if (chunk.length <= remaining) {
          stderrBuilder.add(chunk);
          stderrBytes += chunk.length;
        } else {
          stderrBuilder.add(chunk.sublist(0, remaining));
          stderrBytes += remaining;
        }
      }
    });

    bool timedOut = false;
    Timer? timeoutTimer;

    if (timeout != null) {
      timeoutTimer = Timer(timeout, () async {
        timedOut = true;
        await ProcessTreeKiller.kill(process.pid);
      });
    }

    try {
      final exitCode = await process.exitCode;
      timeoutTimer?.cancel();
      // Süreç bittikten sonra borularda kalan son çıktıyı da topla
      // (eskiden abonelik hemen iptal edildiği için son satırlar kayboluyordu).
      await Future.wait([stdoutSub.asFuture<void>(), stderrSub.asFuture<void>()])
          .timeout(const Duration(seconds: 2), onTimeout: () => const []);
      await stdoutSub.cancel();
      await stderrSub.cancel();

      const decoder = Utf8Decoder(allowMalformed: true);
      var stdoutText = decoder.convert(stdoutBuilder.toBytes());
      var stderrText = decoder.convert(stderrBuilder.toBytes());

      if (stdoutBytes >= maxOutputBytes) {
        stdoutText += '\n...[Çıktı $maxOutputBytes bayt sınırına ulaştığı için kesildi]';
      }
      if (stderrBytes >= maxOutputBytes) {
        stderrText += '\n...[Hata çıktısı $maxOutputBytes bayt sınırına ulaştığı için kesildi]';
      }

      return SandboxResult(
        exitCode: exitCode,
        stdout: stdoutText,
        stderr: stderrText,
        timedOut: timedOut,
      );
    } finally {
      timeoutTimer?.cancel();
      _activePids.remove(process.pid);
    }
  }
}
