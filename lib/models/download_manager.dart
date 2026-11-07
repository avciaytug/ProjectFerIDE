import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import '../features/chat/state.dart';
import '../features/settings/settings_provider.dart';
import '../services/app_paths.dart';
import '../services/system_installer_service.dart';

enum DownloadStatus {
  downloading,
  paused,
  completed,
  error,
  canceled,
}

class DownloadTask {
  final String modelId;
  final String fileName;
  final String url;
  final int receivedBytes;
  final int totalBytes;
  final double speedBytesPerSec;
  final String? rawSpeed;
  final String? rawDownloaded;
  final String? rawTotal;
  final String? rawPercent;
  final String? rawEta;
  final int connections;
  final Duration? eta;
  final DownloadStatus status;
  final String? errorMessage;
  final List<Map<String, String>> queue;
  final int partIndex;
  final int partCount;
  final String? primaryModelFile;

  DownloadTask({
    required this.modelId,
    required this.fileName,
    required this.url,
    this.receivedBytes = 0,
    this.totalBytes = 0,
    this.speedBytesPerSec = 0.0,
    this.rawSpeed,
    this.rawDownloaded,
    this.rawTotal,
    this.rawPercent,
    this.rawEta,
    this.connections = 16,
    this.eta,
    this.status = DownloadStatus.downloading,
    this.errorMessage,
    this.queue = const [],
    this.partIndex = 1,
    this.partCount = 1,
    this.primaryModelFile,
  });

  DownloadTask copyWith({
    String? modelId,
    String? fileName,
    String? url,
    int? receivedBytes,
    int? totalBytes,
    double? speedBytesPerSec,
    String? rawSpeed,
    bool clearRawSpeed = false,
    String? rawDownloaded,
    bool clearRawDownloaded = false,
    String? rawTotal,
    bool clearRawTotal = false,
    String? rawPercent,
    bool clearRawPercent = false,
    String? rawEta,
    bool clearRawEta = false,
    int? connections,
    Duration? eta,
    DownloadStatus? status,
    String? errorMessage,
    bool clearError = false,
    List<Map<String, String>>? queue,
    int? partIndex,
    int? partCount,
    String? primaryModelFile,
  }) {
    return DownloadTask(
      modelId: modelId ?? this.modelId,
      fileName: fileName ?? this.fileName,
      url: url ?? this.url,
      receivedBytes: receivedBytes ?? this.receivedBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      speedBytesPerSec: speedBytesPerSec ?? this.speedBytesPerSec,
      rawSpeed: clearRawSpeed ? null : (rawSpeed ?? this.rawSpeed),
      rawDownloaded: clearRawDownloaded ? null : (rawDownloaded ?? this.rawDownloaded),
      rawTotal: clearRawTotal ? null : (rawTotal ?? this.rawTotal),
      rawPercent: clearRawPercent ? null : (rawPercent ?? this.rawPercent),
      rawEta: clearRawEta ? null : (rawEta ?? this.rawEta),
      connections: connections ?? this.connections,
      eta: eta ?? this.eta,
      status: status ?? this.status,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      queue: queue ?? this.queue,
      partIndex: partIndex ?? this.partIndex,
      partCount: partCount ?? this.partCount,
      primaryModelFile: primaryModelFile ?? this.primaryModelFile,
    );
  }

  double get progress {
    if (status == DownloadStatus.completed) return 1.0;
    if (rawPercent != null) {
      final pVal = double.tryParse(rawPercent!.replaceAll('%', ''));
      if (pVal != null) return (pVal / 100.0).clamp(0.0, 1.0);
    }
    if (totalBytes > 0) {
      return (receivedBytes / totalBytes).clamp(0.0, 1.0);
    }
    return 0.0;
  }

  String get progressPercent {
    if (status == DownloadStatus.completed) return '100%';
    if (rawPercent != null && rawPercent!.isNotEmpty) return rawPercent!;
    return '${(progress * 100).toStringAsFixed(1)}%';
  }

  static String formatBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    } else if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    } else if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    } else {
      return '$bytes B';
    }
  }

  String get sizeText {
    final partPrefix = partCount > 1 ? '[Parça $partIndex/$partCount] ' : '';
    if (rawDownloaded != null && rawTotal != null) {
      return '$partPrefix$rawDownloaded / $rawTotal ($progressPercent)';
    }
    return '$partPrefix${formatBytes(receivedBytes)} / ${totalBytes > 0 ? formatBytes(totalBytes) : 'Hesaplanıyor'} ($progressPercent)';
  }

  String get speedText {
    if (status == DownloadStatus.completed) return 'Model Hazır & Entegre Edildi';
    if (status == DownloadStatus.paused) return 'Duraklatıldı';
    if (status == DownloadStatus.canceled) return 'İptal edildi';
    if (status == DownloadStatus.error) {
      return errorMessage != null && errorMessage!.isNotEmpty
          ? 'Hata: $errorMessage'
          : 'İndirme hatası';
    }
    if (rawSpeed != null && rawSpeed!.isNotEmpty) {
      return connections > 1 ? '$rawSpeed (${connections}x Hız)' : rawSpeed!;
    }
    if (speedBytesPerSec >= 1024 * 1024) {
      return '${(speedBytesPerSec / (1024 * 1024)).toStringAsFixed(2)} MB/s';
    } else if (speedBytesPerSec >= 1024) {
      return '${(speedBytesPerSec / 1024).toStringAsFixed(0)} KB/s';
    } else {
      return '${speedBytesPerSec.toStringAsFixed(0)} B/s';
    }
  }

  String get etaText {
    if (status == DownloadStatus.completed) return 'Tamamlandı';
    if (status == DownloadStatus.paused) return 'Duraklatıldı';
    if (status == DownloadStatus.error) return 'Yeniden deneyin';
    if (status == DownloadStatus.canceled) return 'İptal edildi';
    if (rawEta != null && rawEta!.isNotEmpty) {
      return rawEta!;
    }
    if (eta == null || eta!.isNegative || speedBytesPerSec <= 0) {
      return 'Hesaplanıyor...';
    }
    final h = eta!.inHours;
    final m = eta!.inMinutes.remainder(60);
    final s = eta!.inSeconds.remainder(60);
    if (h > 0) return '~$h sa $m dk';
    if (m > 0) return '~$m dk $s sn';
    return '~$s sn';
  }
}

/// Çift Motorlu Kusursuz Model İndirici (v5.3.8):
/// 1. Birincil Motor: `aria2c` (16x çoklu bağlantı, kaldığı yerden devam).
/// 2. Yerleşik Yedek Motor: Saf Dart Resumable HTTP Stream Motoru (0 dış paketle her dağıtımda çalışır).
/// 3. Tamamlandığında modeli (ve varsa mmproj görsel eklentisini) otomatik entegre eder ve seçer.
class DownloadController extends StateNotifier<DownloadTask?> {
  final Ref _ref;
  Process? _process;
  HttpClient? _httpClient;
  bool _isPaused = false;
  bool _isCanceled = false;
  StreamSubscription? _stdoutSub;
  StreamSubscription? _stderrSub;

  DownloadController(this._ref) : super(null);

  String get _modelsDir => AppPaths.persistentModelsDir;

  static int _parseAriaSize(String s) {
    final upper = s.toUpperCase();
    final numPart = double.tryParse(upper.replaceAll(RegExp(r'[^0-9\.]'), '')) ?? 0.0;
    if (upper.contains('TIB') || upper.contains('TB')) return (numPart * 1024 * 1024 * 1024 * 1024).round();
    if (upper.contains('GIB') || upper.contains('GB')) return (numPart * 1024 * 1024 * 1024).round();
    if (upper.contains('MIB') || upper.contains('MB')) return (numPart * 1024 * 1024).round();
    if (upper.contains('KIB') || upper.contains('KB')) return (numPart * 1024).round();
    return numPart.round();
  }

  static String _formatEta(String? etaStr) {
    if (etaStr == null || etaStr.isEmpty) return 'Hesaplanıyor...';
    final res = etaStr
        .replaceAllMapped(RegExp(r'(\d+)h'), (m) => '${m[1]} sa ')
        .replaceAllMapped(RegExp(r'(\d+)m'), (m) => '${m[1]} dk ')
        .replaceAllMapped(RegExp(r'(\d+)s'), (m) => '${m[1]} sn')
        .trim();
    return '~$res';
  }

  Future<void> startDownload({
    required String modelId,
    required String fileName,
    required String url,
    int? knownTotalBytes,
    List<Map<String, String>>? queue,
    int partIndex = 1,
    int partCount = 1,
    String? primaryModelFile,
    bool isChainedNextPart = false,
  }) async {
    if (!isChainedNextPart &&
        state != null &&
        state!.status == DownloadStatus.downloading) {
      return; // Zaten aktif bir indirme sürüyor
    }

    _isPaused = false;
    _isCanceled = false;

    // Alt klasörlü hedefler (örn. mmproj/...) için dizin ve saf dosya adını ayır (Linux/Windows/macOS uyumlu)
    final cleanRelativePath = p.normalize(
      (fileName.startsWith('/') ? fileName.substring(1) : fileName).replaceAll('/', p.separator),
    );
    final fullDestPath = p.join(_modelsDir, cleanRelativePath);
    final destParentDir = Directory(p.dirname(fullDestPath));
    final destBaseName = p.basename(fullDestPath);

    if (!await destParentDir.exists()) {
      await destParentDir.create(recursive: true);
    }

    final effectiveTotalParts = partCount > 1
        ? partCount
        : (1 + (queue?.length ?? 0));

    final mainFile = primaryModelFile ??
        (!destBaseName.toLowerCase().contains('mmproj') ? destBaseName : null);

    state = DownloadTask(
      modelId: modelId,
      fileName: cleanRelativePath,
      url: url,
      totalBytes: knownTotalBytes ?? 0,
      receivedBytes: 0,
      status: DownloadStatus.downloading,
      rawSpeed: 'Bağlanılıyor...',
      rawEta: 'Hesaplanıyor...',
      queue: queue ?? const [],
      partIndex: partIndex,
      partCount: effectiveTotalParts,
      primaryModelFile: mainFile,
    );

    final hfToken = _ref.read(settingsProvider).hfToken.trim();
    final ariaBinary = AppPaths.resolveAria2c();

    bool completedCurrentFile = false;
    String? failureReason;

    // 1. Birincil Motor: aria2c (varsa)
    if (ariaBinary != null) {
      final ariaResult = await _downloadViaAria2(
        ariaBinary: ariaBinary,
        destDir: destParentDir.path,
        destFileName: destBaseName,
        url: url,
        hfToken: hfToken,
      );
      completedCurrentFile = ariaResult.$1;
      failureReason = ariaResult.$2;
    }

    // 2. Yerleşik Saf Dart Resumable HTTP Motoru (aria2c yoksa veya hata verdiyse otomatik devreye girer)
    if (!completedCurrentFile && !_isPaused && !_isCanceled) {
      state = state?.copyWith(
        connections: 1,
        rawSpeed: 'Yerleşik HTTP motoruyla indiriliyor...',
        clearError: true,
      );
      final dartResult = await _downloadViaNativeHttp(
        destFilePath: fullDestPath,
        url: url,
        hfToken: hfToken,
      );
      completedCurrentFile = dartResult.$1;
      failureReason = dartResult.$2 ?? failureReason;
    }

    if (_isPaused) {
      state = state?.copyWith(
        status: DownloadStatus.paused,
        speedBytesPerSec: 0,
        rawSpeed: 'Duraklatıldı',
        rawEta: 'Beklemede',
      );
      return;
    }

    if (_isCanceled) {
      state = state?.copyWith(
        status: DownloadStatus.canceled,
        speedBytesPerSec: 0,
        rawSpeed: 'İptal edildi',
        rawEta: 'Durduruldu',
      );
      return;
    }

    if (completedCurrentFile) {
      final remaining = state?.queue ?? const <Map<String, String>>[];
      if (remaining.isNotEmpty) {
        final next = remaining.first;
        final nextRest = remaining.sublist(1);
        final nextIndex = (state?.partIndex ?? 1) + 1;
        final nextBytes = int.tryParse(next['size'] ?? '') ?? 0;

        await Future.delayed(const Duration(milliseconds: 250));
        await startDownload(
          modelId: modelId,
          fileName: next['fileName']!,
          url: next['url']!,
          knownTotalBytes: nextBytes > 0 ? nextBytes : null,
          queue: nextRest,
          partIndex: nextIndex,
          partCount: effectiveTotalParts,
          primaryModelFile: mainFile,
          isChainedNextPart: true,
        );
        return;
      }

      // Tüm parçalar (ve varsa mmproj) tamamlandı -> Otomatik model entegrasyonu!
      state = state?.copyWith(
        status: DownloadStatus.completed,
        rawPercent: '100%',
        rawSpeed: 'Tamamlandı',
        rawEta: 'Tamamlandı',
        clearError: true,
      );

      await _integrateCompletedModel(mainFile);
    } else {
      state = state?.copyWith(
        status: DownloadStatus.error,
        errorMessage: failureReason ?? 'Bağlantı kesildi veya sunucu yanıt vermedi.',
      );
    }
  }

  Future<(bool, String?)> _downloadViaAria2({
    required String ariaBinary,
    required String destDir,
    required String destFileName,
    required String url,
    required String hfToken,
  }) async {
    try {
      final args = <String>[
        '-c',
        '-x', '16',
        '-s', '16',
        '-k', '1M',
        '--file-allocation=none',
        '--summary-interval=1',
        '--console-log-level=warn',
        '--check-certificate=true',
        '--max-tries=5',
        '--retry-wait=2',
        '--user-agent=FerIDE/5.3.8',
        if (hfToken.isNotEmpty) '--header=Authorization: Bearer $hfToken',
        '-d', destDir,
        '-o', destFileName,
        url,
      ];

      _process = await Process.start(
        ariaBinary,
        args,
        environment: AppPaths.buildSubprocessEnv(),
      );

      final ariaRegex = RegExp(
        r'\[#\w+\s+([0-9\.]+[KkMmGgTt]?i?B)/([0-9\.]+[KkMmGgTt]?i?B)\((\d+)%\)\s+CN:(\d+)\s+DL:([0-9\.]+[KkMmGgTt]?i?B)(?:\s+ETA:([0-9a-z]+))?\]',
      );

      String lastErrLine = '';

      _stdoutSub = _process!.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen((line) {
        if (_isPaused || _isCanceled) return;

        final match = ariaRegex.firstMatch(line);
        if (match != null) {
          final downloadedStr = match.group(1)!;
          final totalStr = match.group(2)!;
          final percentStr = match.group(3)!;
          final connectionsStr = match.group(4)!;
          final speedStr = match.group(5)!;
          final etaStr = match.group(6);

          final recBytes = _parseAriaSize(downloadedStr);
          final totBytes = _parseAriaSize(totalStr);

          state = state?.copyWith(
            receivedBytes: recBytes,
            totalBytes: totBytes > 0 ? totBytes : state?.totalBytes,
            rawSpeed: '$speedStr/s',
            rawDownloaded: downloadedStr,
            rawTotal: totalStr,
            rawPercent: '$percentStr%',
            rawEta: _formatEta(etaStr),
            connections: int.tryParse(connectionsStr) ?? 16,
            status: DownloadStatus.downloading,
          );
        } else if (line.contains('errorCode=') || line.toLowerCase().contains('exception')) {
          lastErrLine = line.trim();
        }
      });

      _stderrSub = _process!.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen((errLine) {
        if (errLine.trim().isNotEmpty) {
          lastErrLine = errLine.trim();
        }
      });

      final exitCode = await _process!.exitCode;
      await _stdoutSub?.cancel();
      await _stderrSub?.cancel();
      _process = null;

      if (exitCode == 0) {
        final finalFile = File(p.join(destDir, destFileName));
        if (finalFile.existsSync() && finalFile.lengthSync() > 0) {
          return (true, null);
        }
      }
      return (
        false,
        lastErrLine.isNotEmpty ? lastErrLine : 'aria2c çıkış kodu: $exitCode',
      );
    } catch (e) {
      _process = null;
      return (false, e.toString());
    }
  }

  /// Sıfır dış paket gerektiren, kaldığı yerden devam edebilen (HTTP Range) yerleşik Dart indirici
  Future<(bool, String?)> _downloadViaNativeHttp({
    required String destFilePath,
    required String url,
    required String hfToken,
  }) async {
    IOSink? sink;
    try {
      final finalFile = File(destFilePath);
      final partFile = File('$destFilePath.part');

      // Eğer aria2c yarım bıraktıysa ve .aria2 yoksa kaldığı yerden devam et
      int existingBytes = 0;
      if (partFile.existsSync()) {
        existingBytes = partFile.lengthSync();
      } else if (finalFile.existsSync() && File('$destFilePath.aria2').existsSync()) {
        // aria2 seyrek (sparse) dosya bırakmış olabilir; temiz .part başlat
        try {
          finalFile.deleteSync();
          File('$destFilePath.aria2').deleteSync();
        } catch (_) {}
      }

      _httpClient = HttpClient()
        ..connectionTimeout = const Duration(seconds: 25)
        ..idleTimeout = const Duration(seconds: 60)
        ..userAgent = 'FerIDE/5.3.8';

      Uri currentUri = Uri.parse(url);
      HttpClientResponse? response;

      // HuggingFace Xet / CDN 302-307 yönlendirmelerini takip et (Authorization başlığını koruyarak/temizleyerek)
      for (int redirectCount = 0; redirectCount < 8; redirectCount++) {
        final request = await _httpClient!.getUrl(currentUri);
        request.followRedirects = false;
        if (hfToken.isNotEmpty && currentUri.host.contains('huggingface.co')) {
          request.headers.set('Authorization', 'Bearer $hfToken');
        }
        if (existingBytes > 0) {
          request.headers.set('Range', 'bytes=$existingBytes-');
        }

        final res = await request.close();
        if (res.isRedirect ||
            res.statusCode == 301 ||
            res.statusCode == 302 ||
            res.statusCode == 303 ||
            res.statusCode == 307 ||
            res.statusCode == 308) {
          final loc = res.headers.value(HttpHeaders.locationHeader);
          await res.drain();
          if (loc == null) break;
          currentUri = currentUri.resolve(loc);
          continue;
        }
        response = res;
        break;
      }

      if (response == null) {
        return (false, 'Yönlendirme sınırı aşıldı.');
      }

      if (response.statusCode == 401 || response.statusCode == 403) {
        return (
          false,
          'Erişim reddedildi (HTTP ${response.statusCode}). Bu model kısıtlı (gated) ise Ayarlar\'dan HuggingFace Token girin.',
        );
      }

      if (response.statusCode == 416) {
        // Dosya zaten tamamen inmiş olabilir
        if (partFile.existsSync()) {
          await partFile.rename(destFilePath);
          return (true, null);
        }
        existingBytes = 0;
      } else if (response.statusCode != 200 && response.statusCode != 206) {
        return (false, 'Sunucu hatası: HTTP ${response.statusCode}');
      }

      final isResumed = response.statusCode == 206 && existingBytes > 0;
      final startOffset = isResumed ? existingBytes : 0;
      final contentLen = response.contentLength;
      final totalExpected = contentLen > 0
          ? startOffset + contentLen
          : (state?.totalBytes ?? 0);

      final activeSink = partFile.openWrite(mode: isResumed ? FileMode.append : FileMode.write);
      sink = activeSink;

      int downloaded = startOffset;
      int windowBytes = 0;
      DateTime lastTick = DateTime.now();

      await for (final chunk in response) {
        if (_isPaused || _isCanceled) {
          await activeSink.flush();
          await activeSink.close();
          sink = null;
          _httpClient?.close(force: true);
          _httpClient = null;
          return (false, null);
        }

        activeSink.add(chunk);
        downloaded += chunk.length;
        windowBytes += chunk.length;

        final now = DateTime.now();
        final elapsedMs = now.difference(lastTick).inMilliseconds;
        if (elapsedMs >= 500) {
          final speed = (windowBytes * 1000.0) / elapsedMs;
          final remainingBytes = totalExpected > downloaded ? (totalExpected - downloaded) : 0;
          final etaDur = speed > 0 && remainingBytes > 0
              ? Duration(seconds: (remainingBytes / speed).round())
              : null;

          state = state?.copyWith(
            receivedBytes: downloaded,
            totalBytes: totalExpected > 0 ? totalExpected : state?.totalBytes,
            speedBytesPerSec: speed,
            clearRawSpeed: true,
            clearRawDownloaded: true,
            clearRawTotal: true,
            clearRawPercent: true,
            clearRawEta: true,
            connections: 1,
            eta: etaDur,
            status: DownloadStatus.downloading,
          );

          windowBytes = 0;
          lastTick = now;
        }
      }

      await activeSink.flush();
      await activeSink.close();
      sink = null;
      _httpClient?.close();
      _httpClient = null;

      if (await finalFile.exists()) {
        await finalFile.delete();
      }
      await partFile.rename(destFilePath);
      return (true, null);
    } catch (e) {
      try {
        await sink?.close();
      } catch (_) {}
      _httpClient?.close(force: true);
      _httpClient = null;
      return (false, e.toString());
    }
  }

  /// İndirme bittiğinde modeli listeye ekler, seçili model yapar ve boşta ise otomatik başlatır!
  Future<void> _integrateCompletedModel(String? primaryFile) async {
    _ref.invalidate(availableModelsProvider);
    try {
      await _ref.read(systemInstallerProvider.notifier).refreshStatus();
    } catch (_) {}

    if (primaryFile != null && primaryFile.isNotEmpty) {
      // Hiçbir model çalışmıyor ve yüklenmiyorsa yeni ineni seçip başlat. Bir model
      // çalışırken seçimi değiştirmek, başlıkta çalışmayan bir modeli gösteriyordu.
      if (!_ref.read(isBackendRunningProvider) && !_ref.read(isModelSwitchingProvider)) {
        unawaited(_ref.read(selectedModelProvider.notifier).switchModel(modelDisplayName(primaryFile)));
      }
    }
  }

  Future<void> pauseDownload() async {
    if (state == null || state!.status != DownloadStatus.downloading) return;
    _isPaused = true;
    try {
      if (Platform.isWindows) {
        _process?.kill();
      } else {
        _process?.kill(ProcessSignal.sigterm);
      }
    } catch (_) {}
    _httpClient?.close(force: true);
    state = state?.copyWith(
      status: DownloadStatus.paused,
      speedBytesPerSec: 0,
      rawSpeed: 'Duraklatıldı',
      rawEta: 'Beklemede',
    );
  }

  Future<void> resumeDownload() async {
    if (state == null) return;
    if (state!.status != DownloadStatus.paused &&
        state!.status != DownloadStatus.error &&
        state!.status != DownloadStatus.canceled) {
      return;
    }
    _isPaused = false;
    _isCanceled = false;
    await startDownload(
      modelId: state!.modelId,
      fileName: state!.fileName,
      url: state!.url,
      knownTotalBytes: state!.totalBytes,
      queue: state!.queue,
      partIndex: state!.partIndex,
      partCount: state!.partCount,
      primaryModelFile: state!.primaryModelFile,
      isChainedNextPart: true,
    );
  }

  Future<void> cancelDownload() async {
    if (state == null) return;
    _isCanceled = true;
    try {
      if (Platform.isWindows) {
        _process?.kill();
      } else {
        _process?.kill(ProcessSignal.sigterm);
      }
    } catch (_) {}
    _httpClient?.close(force: true);

    final target = File(p.join(_modelsDir, state!.fileName));
    final ariaFile = File('${target.path}.aria2');
    final partFile = File('${target.path}.part');

    try {
      if (await target.exists()) await target.delete();
      if (await ariaFile.exists()) await ariaFile.delete();
      if (await partFile.exists()) await partFile.delete();
    } catch (_) {}

    state = state?.copyWith(
      status: DownloadStatus.canceled,
      speedBytesPerSec: 0,
      rawSpeed: 'İptal edildi',
      rawEta: 'Durduruldu',
    );
  }

  void clear() {
    if (state?.status == DownloadStatus.downloading) {
      cancelDownload();
    }
    state = null;
  }
}

final downloadControllerProvider =
    StateNotifierProvider<DownloadController, DownloadTask?>((ref) {
  return DownloadController(ref);
});
