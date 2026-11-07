import 'dart:io';
import 'package:path/path.dart' as p;

/// FerIDE Çapraz Platform Taşınabilir Yol ve İkili Dosya Çözümleyicisi (v5.3.8)
///
/// Linux, Windows ve macOS üzerinde sabit kullanıcı veya dizin yollarını tamamen
/// ortadan kaldırır. Uygulama masaüstünde, /opt altında, Program Files içinde,
/// Applications klasöründe veya harici diskte çalıştırılsa bile tüm betik,
/// model ve motor yollarını dinamik olarak bulur.
class AppPaths {
  AppPaths._();

  static String? _cachedAppRoot;

  /// Kullanıcı ev dizini (Linux/macOS: $HOME, Windows: %USERPROFILE%)
  static String get homeDir {
    final envHome = Platform.environment['HOME'];
    if (envHome != null && envHome.trim().isNotEmpty) {
      return envHome.trim();
    }
    final userProfile = Platform.environment['USERPROFILE'];
    if (userProfile != null && userProfile.trim().isNotEmpty) {
      return userProfile.trim();
    }
    final homeDrive = Platform.environment['HOMEDRIVE'] ?? '';
    final homePath = Platform.environment['HOMEPATH'] ?? '';
    if (homeDrive.isNotEmpty && homePath.isNotEmpty) {
      return '$homeDrive$homePath';
    }
    return Directory.current.path;
  }

  /// İşletim sistemine uygun çalıştırılabilir dosya adı (Windows'ta .exe ekler)
  static String exeName(String base) {
    if (Platform.isWindows && !base.toLowerCase().endsWith('.exe')) {
      return '$base.exe';
    }
    return base;
  }

  /// İşletim sistemine uygun kabuk (shell) komutu döndürür
  static (String executable, List<String> args) shellCommand(String command) {
    if (Platform.isWindows) {
      return ('powershell', ['-NoProfile', '-NonInteractive', '-Command', command]);
    }
    return ('bash', ['-c', command]);
  }

  /// FerIDE kalıcı kullanıcı veri dizini (~/.feride veya %USERPROFILE%\.feride)
  static String get ferideDataDir {
    final dir = Directory(p.join(homeDir, '.feride'));
    if (!dir.existsSync()) {
      try {
        dir.createSync(recursive: true);
      } catch (_) {}
    }
    return dir.path;
  }

  /// Uygulamanın kök klasörü (scripts/, assets/, bin/, models/ barındıran dizin)
  static String get appRoot {
    if (_cachedAppRoot != null) return _cachedAppRoot!;

    // 1. Başlatıcı betik (run.sh / baslat_windows.bat / baslat_macos.command) tarafından verilen FERIDE_ROOT
    final envRoot = Platform.environment['FERIDE_ROOT'];
    if (envRoot != null && envRoot.isNotEmpty && _looksLikeAppRoot(envRoot)) {
      _cachedAppRoot = envRoot;
      return envRoot;
    }

    // 2. Çalışan ikili dosyadan yukarı doğru yürü (Linux bundle, Windows Release, macOS .app/Contents/MacOS)
    try {
      var dir = File(Platform.resolvedExecutable).parent;
      for (int i = 0; i < 9; i++) {
        if (_looksLikeAppRoot(dir.path)) {
          _cachedAppRoot = dir.path;
          return dir.path;
        }
        final parent = dir.parent;
        if (parent.path == dir.path) break;
        dir = parent;
      }
    } catch (_) {}

    // 3. Mevcut çalışma dizini kontrolü
    if (_looksLikeAppRoot(Directory.current.path)) {
      _cachedAppRoot = Directory.current.path;
      return Directory.current.path;
    }

    return Directory.current.path;
  }

  static bool _looksLikeAppRoot(String dirPath) {
    try {
      return File(p.join(dirPath, 'scripts', 'file_parser.py')).existsSync() ||
          File(p.join(dirPath, 'assets', 'app_icon.png')).existsSync() ||
          File(p.join(dirPath, 'kurulum.sh')).existsSync() ||
          File(p.join(dirPath, 'kurulum_windows.bat')).existsSync() ||
          File(p.join(dirPath, 'kurulum_macos.command')).existsSync();
    } catch (_) {
      return false;
    }
  }

  /// Kalıcı indirilen modeller klasörü (~/.feride/models)
  static String get persistentModelsDir {
    final dir = Directory(p.join(ferideDataDir, 'models'));
    if (!dir.existsSync()) {
      try {
        dir.createSync(recursive: true);
      } catch (_) {}
    }
    return dir.path;
  }

  /// Uygulama paketiyle birlikte gelen gömülü modeller klasörü (<appRoot>/models)
  static String get bundledModelsDir => p.join(appRoot, 'models');

  /// GGUF modellerinin ve mmproj dosyalarının taranacağı tüm dizinler
  static List<String> get modelScanDirs {
    final candidates = <String>[
      persistentModelsDir,
      bundledModelsDir,
      p.join(Directory.current.path, 'models'),
      p.join(homeDir, 'models'),
      p.join(homeDir, 'Belgeler', 'feride_models'),
      p.join(homeDir, 'Documents', 'feride_models'),
      p.join(homeDir, '.lmstudio', 'models'),
    ];
    final seen = <String>{};
    final result = <String>[];
    for (final c in candidates) {
      final norm = p.normalize(c);
      if (seen.add(norm)) {
        result.add(norm);
      }
    }
    return result;
  }

  /// scripts/ altındaki bir Python veya kabuk betiğinin tam yolunu döndürür
  static String scriptPath(String scriptName) {
    final candidates = [
      p.join(appRoot, 'scripts', scriptName),
      p.join(Directory.current.path, 'scripts', scriptName),
      p.join(ferideDataDir, 'scripts', scriptName),
    ];
    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    return p.join(appRoot, 'scripts', scriptName);
  }

  /// İkili dosyanın mevcut işletim sistemiyle uyumlu olup olmadığını doğrular
  /// (Örn: macOS veya Windows'ta paketin içindeki Linux ELF ikilisini yanlışlıkla seçmeyi önler)
  static bool _isCompatibleNativeBinary(String filePath) {
    try {
      final f = File(filePath);
      if (!f.existsSync()) return false;
      final raf = f.openSync(mode: FileMode.read);
      final bytes = raf.readSync(4);
      raf.closeSync();
      if (bytes.length < 2) return false;

      // '#!' betik dosyaları Unix sistemlerde geçerlidir
      final isShebang = bytes[0] == 0x23 && bytes[1] == 0x21;
      // Windows PE ('MZ')
      final isPe = bytes[0] == 0x4D && bytes[1] == 0x5A;
      // Linux ELF (0x7F 'E' 'L' 'F')
      final isElf = bytes.length >= 4 &&
          bytes[0] == 0x7F &&
          bytes[1] == 0x45 &&
          bytes[2] == 0x4C &&
          bytes[3] == 0x46;
      // macOS Mach-O / Universal Binary
      final isMachO = bytes.length >= 4 &&
          ((bytes[0] == 0xCF && bytes[1] == 0xFA && bytes[2] == 0xED && bytes[3] == 0xFE) ||
              (bytes[0] == 0xCE && bytes[1] == 0xFA && bytes[2] == 0xED && bytes[3] == 0xFE) ||
              (bytes[0] == 0xFE && bytes[1] == 0xED && bytes[2] == 0xFA && bytes[3] == 0xCF) ||
              (bytes[0] == 0xFE && bytes[1] == 0xED && bytes[2] == 0xFA && bytes[3] == 0xCE) ||
              (bytes[0] == 0xCA && bytes[1] == 0xFE && bytes[2] == 0xBA && bytes[3] == 0xBE));

      if (Platform.isWindows) {
        final lower = filePath.toLowerCase();
        return isPe || lower.endsWith('.bat') || lower.endsWith('.cmd');
      }
      if (Platform.isMacOS) {
        return isMachO || isShebang;
      }
      if (Platform.isLinux) {
        return isElf || isShebang;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// llama-server ikili dosyasını öncelik sırasıyla çözer:
  /// 1) Özel ayar yolu -> 2) ~/.feride/bin/llama-cpp (otonom kurulum/güncelleme)
  /// -> 3) <appRoot>/bin/llama-cpp (paket içi gömülü) -> 4) Sistem / Homebrew / WinGet -> 5) PATH
  static String? resolveLlamaServer({String? customPath}) {
    final bin = exeName('llama-server');
    final candidates = <String>[
      if (customPath != null && customPath.trim().isNotEmpty) customPath.trim(),
      p.join(ferideDataDir, 'bin', 'llama-cpp', bin),
      p.join(ferideDataDir, 'bin', 'llama-cpp', 'build', 'bin', bin),
      p.join(appRoot, 'bin', 'llama-cpp', bin),
      p.join(ferideDataDir, 'bin', bin),
      p.join(appRoot, 'bin', bin),
      p.join(homeDir, 'llama.cpp', 'build', 'bin', bin),
      if (Platform.isMacOS) ...[
        '/opt/homebrew/bin/llama-server',
        '/usr/local/bin/llama-server',
      ],
      if (Platform.isLinux) ...[
        '/usr/local/bin/llama-server',
        '/usr/bin/llama-server',
      ],
      if (Platform.isWindows) ...[
        p.join(homeDir, 'AppData', 'Local', 'Microsoft', 'WinGet', 'Links', 'llama-server.exe'),
      ],
    ];

    for (final path in candidates) {
      if (_isCompatibleNativeBinary(path)) {
        _ensureExecutable(path);
        return path;
      }
    }

    final fromPath = _which(bin);
    if (fromPath != null && _isCompatibleNativeBinary(fromPath)) return fromPath;
    return null;
  }

  /// aria2c varsa yolunu döndürür; yoksa null döner (yerleşik Dart HTTP indirici devreye girer)
  static String? resolveAria2c() {
    final bin = exeName('aria2c');
    final candidates = <String>[
      p.join(appRoot, 'bin', bin),
      p.join(ferideDataDir, 'bin', bin),
      if (Platform.isMacOS) '/opt/homebrew/bin/aria2c',
      if (!Platform.isWindows) ...[
        '/usr/bin/aria2c',
        '/usr/local/bin/aria2c',
      ],
      if (Platform.isWindows) ...[
        p.join(homeDir, 'AppData', 'Local', 'Microsoft', 'WinGet', 'Links', 'aria2c.exe'),
        r'C:\Program Files\aria2\aria2c.exe',
      ],
    ];
    for (final c in candidates) {
      if (_isCompatibleNativeBinary(c)) {
        _ensureExecutable(c);
        return c;
      }
    }
    return _which(bin);
  }

  /// ripgrep (rg) ikili dosyasını çözer
  static String? resolveRipgrep() {
    final bin = exeName('rg');
    final candidates = <String>[
      p.join(appRoot, 'bin', bin),
      p.join(ferideDataDir, 'bin', bin),
      if (Platform.isMacOS) '/opt/homebrew/bin/rg',
      if (!Platform.isWindows) ...[
        '/usr/bin/rg',
        '/usr/local/bin/rg',
      ],
      if (Platform.isWindows) ...[
        p.join(homeDir, 'AppData', 'Local', 'Microsoft', 'WinGet', 'Links', 'rg.exe'),
        r'C:\Program Files\ripgrep\rg.exe',
      ],
    ];
    for (final c in candidates) {
      if (_isCompatibleNativeBinary(c)) {
        _ensureExecutable(c);
        return c;
      }
    }
    return _which(bin);
  }

  /// AutoCAD (LibreDWG) araçlarını (dwg2dxf, dxf2dwg, dwgread vb.) çözer
  static String? resolveCadBinary(String name) {
    final bin = exeName(name);
    final candidates = <String>[
      p.join(appRoot, 'bin', 'cad', bin),
      p.join(ferideDataDir, 'bin', 'cad', bin),
      if (Platform.isMacOS) '/opt/homebrew/bin/$bin',
      if (!Platform.isWindows) ...[
        '/usr/local/bin/$bin',
        '/usr/bin/$bin',
      ],
    ];
    for (final c in candidates) {
      if (_isCompatibleNativeBinary(c)) {
        _ensureExecutable(c);
        return c;
      }
    }
    return _which(bin);
  }

  /// Python yorumlayıcısını çözer (~/.feride/venv öncelikli, Linux/Windows/macOS uyumlu)
  static String resolvePython({bool preferVoiceEnv = false}) {
    if (Platform.isWindows) {
      final winCandidates = <String>[
        if (preferVoiceEnv) p.join(ferideDataDir, 'voice_env', 'Scripts', 'python.exe'),
        p.join(ferideDataDir, 'venv', 'Scripts', 'python.exe'),
        p.join(appRoot, '.venv', 'Scripts', 'python.exe'),
      ];
      for (final c in winCandidates) {
        if (File(c).existsSync()) return c;
      }
      final fromPath = _which('python.exe') ?? _which('python');
      if (fromPath != null) return fromPath;
      return 'python';
    }

    final unixCandidates = preferVoiceEnv
        ? <String>[
            p.join(homeDir, 'AI', 'feride_env', 'bin', 'python3'),
            p.join(ferideDataDir, 'voice_env', 'bin', 'python3'),
            p.join(ferideDataDir, 'venv', 'bin', 'python3'),
            p.join(appRoot, '.venv', 'bin', 'python3'),
            if (Platform.isMacOS) '/opt/homebrew/bin/python3',
            '/usr/local/bin/python3',
            '/usr/bin/python3',
          ]
        : <String>[
            p.join(ferideDataDir, 'venv', 'bin', 'python3'),
            p.join(appRoot, '.venv', 'bin', 'python3'),
            p.join(homeDir, 'AI', 'feride_env', 'bin', 'python3'),
            if (Platform.isMacOS) '/opt/homebrew/bin/python3',
            '/usr/local/bin/python3',
            '/usr/bin/python3',
          ];

    for (final c in unixCandidates) {
      if (File(c).existsSync()) return c;
    }
    return _which('python3') ?? 'python3';
  }

  /// Tesseract dil verileri dizini (varsa)
  static String? get tessdataPrefix {
    final candidates = <String>[
      p.join(ferideDataDir, 'tessdata'),
      p.join(appRoot, 'assets', 'tessdata'),
      p.join(homeDir, '.local', 'share', 'tessdata'),
      if (Platform.isMacOS) ...[
        '/opt/homebrew/share/tessdata',
        '/usr/local/share/tessdata',
      ],
      if (Platform.isLinux) ...[
        '/usr/share/tesseract-ocr/5/tessdata',
        '/usr/share/tesseract-ocr/4.00/tessdata',
        '/usr/share/tessdata',
      ],
      if (Platform.isWindows) ...[
        r'C:\Program Files\Tesseract-OCR\tessdata',
      ],
    ];
    for (final c in candidates) {
      if (Directory(c).existsSync()) return c;
    }
    return null;
  }

  /// Alt süreçler (Python, llama-server, CAD, OCR vb.) için zenginleştirilmiş ortam değişkenleri
  static Map<String, String> buildSubprocessEnv({Map<String, String>? extra}) {
    final env = Map<String, String>.from(Platform.environment);
    final sep = Platform.isWindows ? ';' : ':';
    final venvBin = Platform.isWindows
        ? p.join(ferideDataDir, 'venv', 'Scripts')
        : p.join(ferideDataDir, 'venv', 'bin');

    final extraPaths = <String>[
      p.join(appRoot, 'bin'),
      p.join(appRoot, 'bin', 'cad'),
      p.join(appRoot, 'bin', 'llama-cpp'),
      p.join(ferideDataDir, 'bin'),
      p.join(ferideDataDir, 'bin', 'cad'),
      p.join(ferideDataDir, 'bin', 'llama-cpp'),
      venvBin,
      if (!Platform.isWindows) p.join(homeDir, '.local', 'bin'),
      if (Platform.isMacOS) '/opt/homebrew/bin',
      if (!Platform.isWindows) ...[
        '/usr/local/bin',
        '/usr/bin',
        '/bin',
      ],
      if (Platform.isWindows) ...[
        r'C:\Program Files\Tesseract-OCR',
        r'C:\Program Files\ffmpeg\bin',
      ],
    ];

    final currentPath = env['PATH'] ?? env['Path'] ?? '';
    env['PATH'] = '${extraPaths.join(sep)}$sep$currentPath';
    env['FERIDE_ROOT'] = appRoot;
    env['PYTHONIOENCODING'] = 'utf-8';
    env['PYTHONUTF8'] = '1';

    final tess = tessdataPrefix;
    if (tess != null && (env['TESSDATA_PREFIX'] == null || env['TESSDATA_PREFIX']!.isEmpty)) {
      env['TESSDATA_PREFIX'] = tess;
    }

    if (extra != null) {
      env.addAll(extra);
    }
    return env;
  }

  static void _ensureExecutable(String filePath) {
    if (!Platform.isLinux && !Platform.isMacOS) return;
    try {
      final stat = File(filePath).statSync();
      // exFAT/NTFS yedeklemelerinden dönüldüğünde +x izni düşmüş olabilir; otomatik onar
      if ((stat.mode & 0x49) == 0) {
        Process.runSync('chmod', ['+x', filePath]);
      }
    } catch (_) {}
  }

  static String? _which(String binary) {
    try {
      final res = Platform.isWindows
          ? Process.runSync('where', [binary])
          : Process.runSync('which', [binary]);
      if (res.exitCode == 0) {
        final lines = res.stdout
            .toString()
            .split(RegExp(r'\r?\n'))
            .map((l) => l.trim())
            .where((l) => l.isNotEmpty)
            .toList();
        for (final line in lines) {
          // Windows 'where' bazen AppExecutionAlias (0 byte python.exe) döndürebilir; gerçek dosyayı doğrula
          final f = File(line);
          if (f.existsSync()) {
            if (Platform.isWindows &&
                line.toLowerCase().contains('windowsapps') &&
                f.statSync().size == 0) {
              continue;
            }
            return line;
          }
        }
      }
    } catch (_) {}
    return null;
  }
}
