import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'app_paths.dart';

class SystemHealthState {
  final String? llamaServerPath;
  final String llamaVersion;
  final String gpuDeviceSummary;
  final bool hasAria2;
  final bool hasPythonSuite;
  final bool hasSttReady;
  final bool hasCadTools;
  final bool hasFfmpeg;
  final bool hasOcr;
  final int mmprojCount;
  final bool isBusy;
  final String? activeTaskTitle;
  final List<String> logs;
  final String? lastError;

  const SystemHealthState({
    this.llamaServerPath,
    this.llamaVersion = 'Kontrol ediliyor...',
    this.gpuDeviceSummary = 'Algılanıyor...',
    this.hasAria2 = false,
    this.hasPythonSuite = false,
    this.hasSttReady = false,
    this.hasCadTools = false,
    this.hasFfmpeg = false,
    this.hasOcr = false,
    this.mmprojCount = 0,
    this.isBusy = false,
    this.activeTaskTitle,
    this.logs = const [],
    this.lastError,
  });

  bool get isLlamaReady => llamaServerPath != null && llamaServerPath!.isNotEmpty;

  SystemHealthState copyWith({
    String? llamaServerPath,
    bool clearLlamaPath = false,
    String? llamaVersion,
    String? gpuDeviceSummary,
    bool? hasAria2,
    bool? hasPythonSuite,
    bool? hasSttReady,
    bool? hasCadTools,
    bool? hasFfmpeg,
    bool? hasOcr,
    int? mmprojCount,
    bool? isBusy,
    String? activeTaskTitle,
    bool clearTaskTitle = false,
    List<String>? logs,
    String? lastError,
    bool clearError = false,
  }) {
    return SystemHealthState(
      llamaServerPath: clearLlamaPath ? null : (llamaServerPath ?? this.llamaServerPath),
      llamaVersion: llamaVersion ?? this.llamaVersion,
      gpuDeviceSummary: gpuDeviceSummary ?? this.gpuDeviceSummary,
      hasAria2: hasAria2 ?? this.hasAria2,
      hasPythonSuite: hasPythonSuite ?? this.hasPythonSuite,
      hasSttReady: hasSttReady ?? this.hasSttReady,
      hasCadTools: hasCadTools ?? this.hasCadTools,
      hasFfmpeg: hasFfmpeg ?? this.hasFfmpeg,
      hasOcr: hasOcr ?? this.hasOcr,
      mmprojCount: mmprojCount ?? this.mmprojCount,
      isBusy: isBusy ?? this.isBusy,
      activeTaskTitle: clearTaskTitle ? null : (activeTaskTitle ?? this.activeTaskTitle),
      logs: logs ?? this.logs,
      lastError: clearError ? null : (lastError ?? this.lastError),
    );
  }
}

class SystemInstallerNotifier extends StateNotifier<SystemHealthState> {
  SystemInstallerNotifier() : super(const SystemHealthState()) {
    if (!Platform.environment.containsKey('FLUTTER_TEST')) {
      Future.microtask(refreshStatus);
    }
  }

  void _appendLog(String line) {
    final trimmed = line.trimRight();
    if (trimmed.isEmpty) return;
    final updated = [...state.logs, trimmed];
    if (updated.length > 150) {
      updated.removeRange(0, updated.length - 150);
    }
    state = state.copyWith(logs: updated);
  }

  static Map<String, String> _libEnv(String binDir) {
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

  Future<void> refreshStatus({String? customLlamaPath}) async {
    try {
      final llamaPath = AppPaths.resolveLlamaServer(customPath: customLlamaPath);
      String versionStr = 'Kurulu değil';
      String gpuStr = Platform.isMacOS ? 'Apple Metal / CPU' : 'CPU Modu';

      if (llamaPath != null) {
        final binDir = p.dirname(llamaPath);
        if (!Platform.isWindows) {
          await repairSharedLibSymlinks(binDir);
        }
        final env = _libEnv(binDir);

        final verFile = File(p.join(binDir, 'VERSION.txt'));
        if (verFile.existsSync()) {
          versionStr = verFile.readAsStringSync().trim();
        }

        try {
          final verRes = await Process.run(llamaPath, ['--version'], environment: env)
              .timeout(const Duration(seconds: 4));
          final combined = '${verRes.stdout}\n${verRes.stderr}';
          final match = RegExp(r'build\s+(\d+)').firstMatch(combined);
          if (match != null) {
            versionStr = 'b${match.group(1)} (${llamaPath.contains(AppPaths.appRoot) ? "Gömülü" : "Kurulu"})';
          } else if (versionStr == 'Kurulu değil') {
            versionStr = 'Hazır';
          }
        } catch (_) {}

        try {
          final devRes = await Process.run(llamaPath, ['--list-devices'], environment: env)
              .timeout(const Duration(seconds: 4));
          final devOut = '${devRes.stdout}\n${devRes.stderr}';
          final devLines = devOut
              .split(RegExp(r'\r?\n'))
              .map((l) => l.trim())
              .where((l) =>
                  l.startsWith('Vulkan') ||
                  l.startsWith('CUDA') ||
                  l.startsWith('ROCm') ||
                  l.startsWith('HIP') ||
                  l.startsWith('MTL'))
              .toList();
          if (devLines.isNotEmpty) {
            gpuStr = devLines.first;
          }
        } catch (_) {}
      }

      final hasAria2 = AppPaths.resolveAria2c() != null;
      final hasCad = AppPaths.resolveCadBinary('dwg2dxf') != null;
      final hasFfmpeg = await _cmdExists(AppPaths.exeName('ffmpeg'));
      final hasOcr = await _cmdExists(AppPaths.exeName('tesseract'));

      bool hasPySuite = false;
      bool hasStt = false;
      try {
        final py = AppPaths.resolvePython();
        final pyCheck = await Process.run(
          py,
          ['-c', 'import docx, openpyxl, pptx, fitz, PIL, ezdxf; print("OK")'],
          environment: AppPaths.buildSubprocessEnv(),
        ).timeout(const Duration(seconds: 5));
        hasPySuite = pyCheck.exitCode == 0 && pyCheck.stdout.toString().contains('OK');
      } catch (_) {}

      try {
        final sttPy = AppPaths.resolvePython(preferVoiceEnv: true);
        final bundledWhisper = File(p.join(AppPaths.bundledModelsDir, 'whisper', 'base', 'model.bin')).existsSync() ||
            File(p.join(AppPaths.persistentModelsDir, 'whisper', 'base', 'model.bin')).existsSync();
        final sttCheck = await Process.run(
          sttPy,
          ['-c', 'import faster_whisper, numpy; print("OK")'],
          environment: AppPaths.buildSubprocessEnv(),
        ).timeout(const Duration(seconds: 5));
        hasStt = (sttCheck.exitCode == 0 && sttCheck.stdout.toString().contains('OK')) && bundledWhisper;
      } catch (_) {}

      int mmprojTotal = 0;
      for (final scanDir in AppPaths.modelScanDirs) {
        final d = Directory(scanDir);
        if (d.existsSync()) {
          try {
            await for (final entity in d.list(recursive: true).handleError((_) {})) {
              if (entity is File &&
                  entity.path.toLowerCase().endsWith('.gguf') &&
                  p.basename(entity.path).toLowerCase().contains('mmproj')) {
                mmprojTotal++;
              }
            }
          } catch (_) {}
        }
      }

      state = state.copyWith(
        llamaServerPath: llamaPath,
        clearLlamaPath: llamaPath == null,
        llamaVersion: versionStr,
        gpuDeviceSummary: gpuStr,
        hasAria2: hasAria2,
        hasPythonSuite: hasPySuite,
        hasSttReady: hasStt,
        hasCadTools: hasCad,
        hasFfmpeg: hasFfmpeg,
        hasOcr: hasOcr,
        mmprojCount: mmprojTotal,
      );
    } catch (e) {
      state = state.copyWith(lastError: 'Durum kontrol hatası: $e');
    }
  }

  /// exFAT/USB taşımalarında bozulabilecek .so / .dylib sembolik bağlarını otomatik onarır
  static Future<void> repairSharedLibSymlinks(String dirPath) async {
    if (Platform.isWindows) return;
    final dir = Directory(dirPath);
    if (!dir.existsSync()) return;
    try {
      final files = dir.listSync().whereType<File>().toList();
      for (final f in files) {
        final base = p.basename(f.path);
        // Linux: libllama.so.0.8.0 -> libllama.so.0 ve libllama.so
        final m = RegExp(r'^(lib[a-zA-Z0-9_-]+\.so)\.(\d+)\.\d+.*$').firstMatch(base);
        if (m != null) {
          final soRoot = m.group(1)!;
          final major = m.group(2)!;
          final majorPath = p.join(dirPath, '$soRoot.$major');
          final plainPath = p.join(dirPath, soRoot);
          if (!File(majorPath).existsSync() && !Link(majorPath).existsSync()) {
            try {
              Link(majorPath).createSync(base);
            } catch (_) {
              f.copySync(majorPath);
            }
          }
          if (!File(plainPath).existsSync() && !Link(plainPath).existsSync()) {
            try {
              Link(plainPath).createSync('$soRoot.$major');
            } catch (_) {
              f.copySync(plainPath);
            }
          }
        }
      }
    } catch (_) {}
  }

  static Future<bool> _isArm64Host() async {
    try {
      if (Platform.isWindows) {
        final arch = (Platform.environment['PROCESSOR_ARCHITECTURE'] ?? '').toLowerCase();
        return arch.contains('arm64');
      }
      final res = await Process.run('uname', ['-m']);
      final out = res.stdout.toString().trim().toLowerCase();
      return out.contains('arm64') || out.contains('aarch64');
    } catch (_) {
      return false;
    }
  }

  static bool _matchesPlatformReleaseAsset(String assetLower, String flavor, bool isArm64) {
    if (assetLower.startsWith('cudart-')) return false;

    if (Platform.isWindows) {
      if (!assetLower.endsWith('.zip') || !assetLower.contains('win-')) return false;
      final archTag = isArm64 ? 'arm64' : 'x64';
      if (!assetLower.contains(archTag)) return false;

      if (flavor == 'vulkan') return assetLower.contains('vulkan');
      if (flavor == 'rocm') return assetLower.contains('hip') || assetLower.contains('rocm');
      if (flavor == 'cuda') return assetLower.contains('cuda');
      if (flavor == 'cpu' || flavor == 'metal') {
        return assetLower.contains('cpu') ||
            (!assetLower.contains('vulkan') &&
                !assetLower.contains('cuda') &&
                !assetLower.contains('hip') &&
                !assetLower.contains('sycl') &&
                !assetLower.contains('openvino'));
      }
      return assetLower.contains('vulkan');
    }

    if (Platform.isMacOS) {
      if (!(assetLower.endsWith('.tar.gz') || assetLower.endsWith('.zip')) ||
          !assetLower.contains('macos-')) {
        return false;
      }
      final archTag = isArm64 ? 'arm64' : 'x64';
      return assetLower.contains(archTag);
    }

    // Linux
    if (!assetLower.endsWith('.tar.gz') || !assetLower.contains('ubuntu')) return false;
    final archTag = isArm64 ? 'arm64' : 'x64';
    if (!assetLower.contains(archTag)) return false;

    if (flavor == 'vulkan' || flavor == 'metal') return assetLower.contains('vulkan');
    if (flavor == 'rocm') return assetLower.contains('rocm');
    if (flavor == 'cuda') return assetLower.contains('cuda');
    if (flavor == 'cpu') {
      return !assetLower.contains('vulkan') &&
          !assetLower.contains('cuda') &&
          !assetLower.contains('rocm') &&
          !assetLower.contains('sycl') &&
          !assetLower.contains('openvino');
    }
    return false;
  }

  static Future<void> _extractArchiveCrossPlatform(String archivePath, String destDir) async {
    final lower = archivePath.toLowerCase();
    if (lower.endsWith('.tar.gz') || lower.endsWith('.tgz')) {
      final tarRes = await Process.run('tar', ['-xzf', archivePath, '-C', destDir]);
      if (tarRes.exitCode != 0) {
        throw 'Arşiv açılamadı (tar): ${tarRes.stderr}';
      }
      return;
    }

    if (lower.endsWith('.zip')) {
      if (Platform.isWindows) {
        // Windows 10/11 yerleşik bsdtar (çok hızlı) -> yedek olarak PowerShell Expand-Archive
        final tarRes = await Process.run('tar', ['-xf', archivePath, '-C', destDir]);
        if (tarRes.exitCode == 0) return;
        final psRes = await Process.run('powershell', [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          'Expand-Archive -LiteralPath "$archivePath" -DestinationPath "$destDir" -Force',
        ]);
        if (psRes.exitCode != 0) {
          throw 'ZIP arşivi açılamadı: ${psRes.stderr}';
        }
      } else {
        final unzipRes = await Process.run('unzip', ['-oq', archivePath, '-d', destDir]);
        if (unzipRes.exitCode != 0) {
          final py = AppPaths.resolvePython();
          final pyRes = await Process.run(py, [
            '-c',
            'import zipfile, sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])',
            archivePath,
            destDir,
          ]);
          if (pyRes.exitCode != 0) {
            throw 'ZIP arşivi açılamadı: ${unzipRes.stderr}';
          }
        }
      }
    }
  }

  static Future<void> _copyDirectoryContents(Directory src, Directory dst) async {
    if (!dst.existsSync()) dst.createSync(recursive: true);
    await for (final entity in src.list(recursive: false, followLinks: false)) {
      final name = p.basename(entity.path);
      final targetPath = p.join(dst.path, name);
      if (entity is Link) {
        final linkTarget = entity.targetSync();
        try {
          if (Link(targetPath).existsSync() || File(targetPath).existsSync()) {
            File(targetPath).deleteSync();
          }
          Link(targetPath).createSync(linkTarget);
        } catch (_) {
          final resolved = File(entity.resolveSymbolicLinksSync());
          if (resolved.existsSync()) {
            resolved.copySync(targetPath);
          }
        }
      } else if (entity is File) {
        entity.copySync(targetPath);
      } else if (entity is Directory) {
        await _copyDirectoryContents(entity, Directory(targetPath));
      }
    }
  }

  /// Ayarlar içinden tek tıkla Llama.cpp motorunu (Linux, Windows, macOS) otonom kurar veya günceller.
  Future<bool> installOrUpdateLlamaCpp({String flavor = 'vulkan'}) async {
    if (state.isBusy) return false;

    final osLabel = Platform.isWindows
        ? 'Windows'
        : (Platform.isMacOS ? 'macOS Metal' : 'Linux');

    state = state.copyWith(
      isBusy: true,
      activeTaskTitle: 'Llama.cpp ($osLabel / $flavor) Otonom Kurulumu',
      logs: ['[Başlatıldı] $osLabel için Llama.cpp ($flavor) otonom kurulumu...'],
      clearError: true,
    );

    final targetDir = Directory(p.join(AppPaths.ferideDataDir, 'bin', 'llama-cpp'));
    if (!targetDir.existsSync()) {
      targetDir.createSync(recursive: true);
    }

    try {
      if (flavor == 'source') {
        final ok = await _compileLlamaFromSource(targetDir.path);
        await refreshStatus();
        state = state.copyWith(isBusy: false, clearTaskTitle: true);
        return ok;
      }

      final isArm64 = await _isArm64Host();
      _appendLog('GitHub ggml-org/llama.cpp sürümleri sorgulanıyor ($osLabel ${isArm64 ? "arm64" : "x64"})...');
      final resp = await http
          .get(
            Uri.parse('https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=10'),
            headers: {'Accept': 'application/vnd.github+json', 'User-Agent': 'FerIDE-5.3.8'},
          )
          .timeout(const Duration(seconds: 20));

      if (resp.statusCode != 200) {
        throw 'GitHub API yanıt vermedi (HTTP ${resp.statusCode}).';
      }

      final releases = jsonDecode(resp.body) as List;
      String? downloadUrl;
      String? assetName;
      String? cudartUrl;
      String? cudartName;
      String? releaseTag;

      for (final rel in releases) {
        if (rel is! Map) continue;
        final tag = (rel['tag_name'] ?? '').toString();
        final assets = (rel['assets'] as List?) ?? const [];

        Map? chosen;
        for (final a in assets) {
          if (a is! Map) continue;
          final name = (a['name'] ?? '').toString().toLowerCase();
          if (_matchesPlatformReleaseAsset(name, flavor, isArm64)) {
            chosen = a;
            break;
          }
        }

        // Seçilen GPU paketi bu sürümde yoksa Windows/Linux için CPU yedek paketini kontrol et
        if (chosen == null && flavor != 'cpu') {
          for (final a in assets) {
            if (a is! Map) continue;
            final name = (a['name'] ?? '').toString().toLowerCase();
            if (_matchesPlatformReleaseAsset(name, 'cpu', isArm64)) {
              chosen = a;
              break;
            }
          }
        }

        if (chosen != null) {
          downloadUrl = chosen['browser_download_url']?.toString();
          assetName = chosen['name']?.toString();
          releaseTag = tag;
          if (Platform.isWindows && flavor == 'cuda') {
            for (final a in assets) {
              if (a is! Map) continue;
              final n = (a['name'] ?? '').toString().toLowerCase();
              if (n.startsWith('cudart-') && n.contains('win-') && n.endsWith('.zip')) {
                cudartUrl = a['browser_download_url']?.toString();
                cudartName = a['name']?.toString();
                break;
              }
            }
          }
          break;
        }
      }

      if (downloadUrl == null || assetName == null) {
        throw 'Seçilen sistem ($osLabel / $flavor) için hazır paket bulunamadı.';
      }

      _appendLog('Bulunan güncel sürüm: $releaseTag ($assetName)');
      final tempDir = await Directory.systemTemp.createTemp('feride_llama_');
      final archivePath = p.join(tempDir.path, assetName);

      await _downloadFileWithProgress(downloadUrl, archivePath);
      _appendLog('Arşiv açılıyor: $assetName ...');
      await _extractArchiveCrossPlatform(archivePath, tempDir.path);

      if (cudartUrl != null && cudartName != null) {
        _appendLog('CUDA çalışma zamanı kütüphaneleri indiriliyor: $cudartName ...');
        final cudartArchive = p.join(tempDir.path, cudartName);
        await _downloadFileWithProgress(cudartUrl, cudartArchive);
        await _extractArchiveCrossPlatform(cudartArchive, tempDir.path);
      }

      final targetExe = AppPaths.exeName('llama-server');
      String? extractedBinDir;
      await for (final entity in tempDir.list(recursive: true, followLinks: false)) {
        if (entity is File && p.basename(entity.path).toLowerCase() == targetExe.toLowerCase()) {
          extractedBinDir = p.dirname(entity.path);
          break;
        }
      }

      if (extractedBinDir == null) {
        throw 'İndirilen paket içinde $targetExe bulunamadı.';
      }

      _appendLog('Dosyalar ${targetDir.path} dizinine yerleştiriliyor...');
      for (final old in targetDir.listSync()) {
        try {
          old.deleteSync(recursive: true);
        } catch (_) {}
      }

      await _copyDirectoryContents(Directory(extractedBinDir), targetDir);

      if (!Platform.isWindows) {
        await Process.run('chmod', ['-R', 'u+rwX,go+rX', targetDir.path]);
        await Process.run('chmod', ['+x', p.join(targetDir.path, targetExe)]);
        await repairSharedLibSymlinks(targetDir.path);
      }

      File(p.join(targetDir.path, 'VERSION.txt')).writeAsStringSync('$releaseTag-$flavor');

      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}

      _appendLog('Sağlık ve GPU kontrolü yapılıyor...');
      await refreshStatus();
      _appendLog('✓ Llama.cpp ($releaseTag) başarıyla kuruldu! Aktif cihaz: ${state.gpuDeviceSummary}');

      state = state.copyWith(isBusy: false, clearTaskTitle: true);
      return true;
    } catch (e) {
      _appendLog('✗ HATA: $e');
      state = state.copyWith(
        isBusy: false,
        clearTaskTitle: true,
        lastError: e.toString(),
      );
      return false;
    }
  }

  Future<bool> _compileLlamaFromSource(String targetDirPath) async {
    if (Platform.isWindows) {
      _appendLog('Windows üzerinde kaynaktan derleme yerine hazır Vulkan/CUDA paketi önerilir; git + cmake deneniyor...');
      final srcDir = p.join(AppPaths.ferideDataDir, 'src', 'llama.cpp');
      Directory(p.dirname(srcDir)).createSync(recursive: true);
      final psScript = '''
\$ErrorActionPreference = "Stop"
if (Test-Path "$srcDir\\.git") {
  Set-Location "$srcDir"; git pull --ff-only
} else {
  if (Test-Path "$srcDir") { Remove-Item -Recurse -Force "$srcDir" }
  git clone --depth 1 https://github.com/ggml-org/llama.cpp.git "$srcDir"
  Set-Location "$srcDir"
}
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --config Release --target llama-server llama-cli
Get-ChildItem -Path build -Recurse -Include *.exe,*.dll | Copy-Item -Destination "$targetDirPath" -Force
Set-Content -Path "$targetDirPath\\VERSION.txt" -Value "source-build"
''';
      return await _runStreamingShell(psScript);
    }

    _appendLog('Kaynaktan derleme seçildi (git + cmake)...');
    final srcDir = p.join(AppPaths.ferideDataDir, 'src', 'llama.cpp');
    Directory(p.dirname(srcDir)).createSync(recursive: true);

    String gpuFlags = '';
    if (Platform.isMacOS) {
      gpuFlags = '-DGGML_METAL=ON';
      _appendLog('macOS algılandı: Apple Metal hızlandırması açık.');
    } else {
      final hasVulkanHeaders = File('/usr/include/vulkan/vulkan.h').existsSync();
      gpuFlags = hasVulkanHeaders ? '-DGGML_VULKAN=ON' : '-DGGML_VULKAN=OFF';
      _appendLog('Vulkan geliştirici başlıkları: ${hasVulkanHeaders ? "Mevcut (Vulkan Açık)" : "Yok (CPU Modu)"}');
    }

    final script = '''
set -e
if [ -d "$srcDir/.git" ]; then
  cd "$srcDir" && git pull --ff-only
else
  rm -rf "$srcDir"
  git clone --depth 1 https://github.com/ggml-org/llama.cpp.git "$srcDir"
  cd "$srcDir"
fi
CORES=\$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
cmake -B build -DCMAKE_BUILD_TYPE=Release $gpuFlags
cmake --build build --config Release -j\$CORES --target llama-server llama-cli
cp -a build/bin/* "$targetDirPath/" 2>/dev/null || true
find build \\( -name "*.so*" -o -name "*.dylib*" \\) -exec cp -a {} "$targetDirPath/" \\; 2>/dev/null || true
echo "source-build" > "$targetDirPath/VERSION.txt"
''';

    final ok = await _runStreamingShell(script);
    if (ok) {
      await repairSharedLibSymlinks(targetDirPath);
      _appendLog('✓ Kaynaktan derleme başarıyla tamamlandı!');
    }
    return ok;
  }

  /// Tüm sistem, belge, Ofis, PDF, Ses (STT/TTS), OCR ve AutoCAD DWG/DXF bağımlılıklarını otonom onarır
  Future<bool> repairAllSystemDependencies() async {
    if (state.isBusy) return false;

    state = state.copyWith(
      isBusy: true,
      activeTaskTitle: 'Sistem & Dosya Bağımlılıkları Otonom Kurulumu',
      logs: ['[Başlatıldı] Tüm FerIDE bağımlılıkları kontrol ediliyor ve kuruluyor...'],
      clearError: true,
    );

    try {
      bool ok = false;
      if (Platform.isWindows) {
        final psSetup = p.join(AppPaths.appRoot, 'kurulum.ps1');
        if (!File(psSetup).existsSync()) {
          throw 'kurulum.ps1 bulunamadı ($psSetup)';
        }
        ok = await _runStreamingShell('& "$psSetup" -Autonomous');
      } else if (Platform.isMacOS) {
        final macSetup = p.join(AppPaths.appRoot, 'kurulum_macos.command');
        if (!File(macSetup).existsSync()) {
          throw 'kurulum_macos.command bulunamadı ($macSetup)';
        }
        ok = await _runStreamingShell('bash "$macSetup" --autonomous');
      } else {
        final linuxSetup = p.join(AppPaths.appRoot, 'kurulum.sh');
        if (!File(linuxSetup).existsSync()) {
          throw 'kurulum.sh bulunamadı ($linuxSetup)';
        }
        ok = await _runStreamingShell('bash "$linuxSetup" --autonomous');
      }

      await refreshStatus();
      if (ok) {
        _appendLog('✓ Tüm bağımlılıklar, ses motoru (STT/TTS) ve Python ortamı hazır!');
      } else {
        _appendLog('! Bazı isteğe bağlı paketler atlandı, mevcut bileşenler güncellendi.');
      }
      state = state.copyWith(isBusy: false, clearTaskTitle: true);
      return ok;
    } catch (e) {
      _appendLog('✗ Kurulum hatası: $e');
      state = state.copyWith(
        isBusy: false,
        clearTaskTitle: true,
        lastError: e.toString(),
      );
      return false;
    }
  }

  Future<void> _downloadFileWithProgress(String url, String destPath) async {
    final client = HttpClient();
    client.userAgent = 'FerIDE-5.3.8';
    try {
      final req = await client.getUrl(Uri.parse(url));
      final res = await req.close();
      if (res.statusCode < 200 || res.statusCode >= 400) {
        throw 'İndirme başarısız (HTTP ${res.statusCode})';
      }
      final total = res.contentLength;
      final out = File(destPath).openWrite();
      int received = 0;
      int lastReportedPct = -10;

      await for (final chunk in res) {
        out.add(chunk);
        received += chunk.length;
        if (total > 0) {
          final pct = ((received / total) * 100).floor();
          if (pct >= lastReportedPct + 20 || pct == 100) {
            lastReportedPct = pct;
            final mb = (received / (1024 * 1024)).toStringAsFixed(1);
            final totMb = (total / (1024 * 1024)).toStringAsFixed(1);
            _appendLog('İndiriliyor: %$pct ($mb / $totMb MB)');
          }
        }
      }
      await out.flush();
      await out.close();
    } finally {
      client.close(force: true);
    }
  }

  Future<bool> _runStreamingShell(String command) async {
    final (exe, args) = AppPaths.shellCommand(command);
    final proc = await Process.start(
      exe,
      args,
      environment: AppPaths.buildSubprocessEnv(),
    );

    proc.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(_appendLog);
    proc.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(_appendLog);

    final code = await proc.exitCode;
    return code == 0;
  }

  Future<bool> _cmdExists(String cmd) async {
    try {
      final res = Platform.isWindows
          ? await Process.run('where', [cmd], environment: AppPaths.buildSubprocessEnv())
          : await Process.run('which', [cmd], environment: AppPaths.buildSubprocessEnv());
      return res.exitCode == 0;
    } catch (_) {
      return false;
    }
  }
}

final systemInstallerProvider =
    StateNotifierProvider<SystemInstallerNotifier, SystemHealthState>((ref) {
  return SystemInstallerNotifier();
});
