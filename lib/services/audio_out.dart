import 'dart:async';
import 'dart:io';

/// İşletim sisteminin yerleşik oynatıcısıyla WAV çalar.
///
/// GStreamer/eklenti bağımlılığı yoktur: Linux'ta pw-play / paplay / aplay,
/// macOS'ta afplay, Windows'ta .NET SoundPlayer kullanılır. Çalma bitene kadar
/// [play] beklenir; [stop] çalmayı anında keser.
class AudioOut {
  Process? _proc;
  static List<List<String>>? _candidates;

  static List<List<String>> _players(String path) {
    if (Platform.isMacOS) return [['afplay', path]];
    if (Platform.isWindows) {
      final p = path.replaceAll("'", "''");
      return [
        ['powershell', '-NoProfile', '-NonInteractive', '-Command', "(New-Object Media.SoundPlayer '$p').PlaySync()"]
      ];
    }
    return [
      ['pw-play', path],
      ['paplay', path],
      ['aplay', '-q', path],
    ];
  }

  /// WAV dosyasını çalar; bitince (veya durdurulunca) tamamlanır.
  Future<bool> play(String path) async {
    await stop();
    final options = _players(path);
    // Daha önce çalışan oynatıcıyı öne al (her seferinde denemeyelim).
    final ordered = _candidates == null
        ? options
        : [
            ...options.where((o) => _candidates!.any((c) => c.first == o.first)),
            ...options.where((o) => !_candidates!.any((c) => c.first == o.first)),
          ];
    for (final cmd in ordered) {
      try {
        final proc = await Process.start(cmd.first, cmd.sublist(1));
        _proc = proc;
        unawaited(proc.stdout.drain<void>());
        unawaited(proc.stderr.drain<void>());
        final code = await proc.exitCode;
        if (identical(_proc, proc)) _proc = null;
        // Durdurulduysa (sinyal) veya başarılıysa bu oynatıcı çalışıyor demektir.
        if (code == 0 || code < 0 || code == 143 || code == 137) {
          _candidates = [cmd];
          return code == 0;
        }
      } on ProcessException {
        continue; // bu oynatıcı sistemde yok, sıradakini dene
      }
    }
    return false;
  }

  Future<void> stop() async {
    final p = _proc;
    _proc = null;
    if (p != null) {
      p.kill(Platform.isWindows ? ProcessSignal.sigterm : ProcessSignal.sigkill);
    }
  }

  void dispose() => stop();
}
