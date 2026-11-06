import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:pasteboard/pasteboard.dart';
import 'package:path/path.dart' as p;
import 'app_paths.dart';

enum AttachedFileType {
  image,
  pdf,
  word,
  excel,
  powerpoint,
  audio,
  cad,
  archive,
  codeOrText,
  other,
}

class ExtractedDocumentResult {
  final String content;
  final String? renderedPreviewImage;

  const ExtractedDocumentResult({
    required this.content,
    this.renderedPreviewImage,
  });
}

class AttachedFile {
  final String id;
  final String path;
  final String name;
  final int sizeBytes;
  final AttachedFileType type;
  final String? base64Image;
  bool isParsing;
  String? parsedContent;

  AttachedFile({
    required this.id,
    required this.path,
    required this.name,
    required this.sizeBytes,
    required this.type,
    this.base64Image,
    this.isParsing = false,
    this.parsedContent,
  });

  String get formattedSize {
    if (sizeBytes < 1024) return '$sizeBytes B';
    if (sizeBytes < 1024 * 1024) return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
    return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class FileService {
  static String get _parserScriptPath => AppPaths.scriptPath('file_parser.py');
  static String get _studioScriptPath => AppPaths.scriptPath('file_studio.py');
  static String get pythonBinary => AppPaths.resolvePython();

  static AttachedFileType getFileType(String filePath) {
    final ext = p.extension(filePath).toLowerCase();
    if (['.png', '.jpg', '.jpeg', '.webp', '.bmp', '.gif', '.tiff', '.tif', '.svg', '.ico']
        .contains(ext)) {
      return AttachedFileType.image;
    }
    if (['.dwg', '.dxf'].contains(ext)) {
      return AttachedFileType.cad;
    }
    if (ext == '.pdf') {
      return AttachedFileType.pdf;
    }
    if (['.docx', '.doc', '.odt', '.rtf'].contains(ext)) {
      return AttachedFileType.word;
    }
    if (['.xlsx', '.xls', '.ods', '.csv', '.tsv'].contains(ext)) {
      return AttachedFileType.excel;
    }
    if (['.pptx', '.ppt', '.odp'].contains(ext)) {
      return AttachedFileType.powerpoint;
    }
    if (['.mp3', '.wav', '.m4a', '.ogg', '.flac', '.aac', '.opus', '.wma'].contains(ext)) {
      return AttachedFileType.audio;
    }
    if (['.zip', '.tar', '.gz', '.tgz', '.xz'].contains(ext)) {
      return AttachedFileType.archive;
    }
    if ([
      '.txt', '.md', '.json', '.yaml', '.yml', '.xml', '.html', '.log',
      '.py', '.dart', '.rs', '.js', '.ts', '.tsx', '.jsx', '.css', '.sh',
      '.c', '.cpp', '.h', '.hpp', '.sql', '.toml', '.ini', '.conf', '.go', '.java', '.kt',
    ].contains(ext)) {
      return AttachedFileType.codeOrText;
    }
    return AttachedFileType.other;
  }

  static Future<Uint8List> resizeImageBytes(Uint8List originalBytes, {int maxDimension = 1568}) async {
    try {
      final codec = await ui.instantiateImageCodec(originalBytes);
      final frame = await codec.getNextFrame();
      final img = frame.image;
      final width = img.width;
      final height = img.height;

      if (width <= maxDimension && height <= maxDimension) {
        return originalBytes;
      }

      int targetWidth;
      int targetHeight;
      if (width > height) {
        targetWidth = maxDimension;
        targetHeight = (height * maxDimension / width).round();
      } else {
        targetHeight = maxDimension;
        targetWidth = (width * maxDimension / height).round();
      }

      final resizedCodec = await ui.instantiateImageCodec(
        originalBytes,
        targetWidth: targetWidth,
        targetHeight: targetHeight,
      );
      final resizedFrame = await resizedCodec.getNextFrame();
      final resizedImg = resizedFrame.image;
      final byteData = await resizedImg.toByteData(format: ui.ImageByteFormat.png);
      return byteData?.buffer.asUint8List() ?? originalBytes;
    } catch (_) {
      return originalBytes;
    }
  }

  static Future<String> _saveToAttachments(Uint8List bytes, String fileName) async {
    final now = DateTime.now();
    final stamp =
        '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_'
        '${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}'
        '${now.second.toString().padLeft(2, '0')}_${now.microsecond % 1000}';
    final ext = p.extension(fileName);
    final base = p.basenameWithoutExtension(fileName);
    final uniqueName = '${base}_$stamp$ext';

    try {
      final attachmentsDir = Directory(p.join(AppPaths.appRoot, 'Chats', 'attachments'));
      if (!attachmentsDir.existsSync()) {
        attachmentsDir.createSync(recursive: true);
      }
      final targetFile = File(p.join(attachmentsDir.path, uniqueName));
      await targetFile.writeAsBytes(bytes);
      return targetFile.absolute.path;
    } catch (_) {
      final fallbackDir = Directory(p.join(AppPaths.ferideDataDir, 'attachments'));
      if (!fallbackDir.existsSync()) {
        fallbackDir.createSync(recursive: true);
      }
      final targetFile = File(p.join(fallbackDir.path, uniqueName));
      await targetFile.writeAsBytes(bytes);
      return targetFile.absolute.path;
    }
  }

  static Future<AttachedFile?> processFile(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return null;

      final name = p.basename(filePath);
      final ext = p.extension(filePath).toLowerCase();
      final size = await file.length();
      final type = getFileType(filePath);

      String? base64Img;
      if (type == AttachedFileType.image && !['.svg', '.tiff', '.tif'].contains(ext)) {
        final rawBytes = await file.readAsBytes();
        final resizedBytes = await resizeImageBytes(rawBytes);
        final savedPath = await _saveToAttachments(resizedBytes, name);
        base64Img = savedPath;
      }

      return AttachedFile(
        id: '${DateTime.now().microsecondsSinceEpoch}_$name',
        path: filePath,
        name: name,
        sizeBytes: size,
        type: type,
        base64Image: base64Img,
      );
    } catch (e) {
      print('Dosya işleme hatası: $e');
      return null;
    }
  }

  static Future<ExtractedDocumentResult> extractContentWithPreview(String filePath) async {
    try {
      final type = getFileType(filePath);

      if (type == AttachedFileType.codeOrText) {
        try {
          final f = File(filePath);
          final stat = await f.stat();
          if (stat.size <= 512 * 1024) {
            final content = await f.readAsString();
            return ExtractedDocumentResult(content: content);
          } else {
            final raf = await f.open(mode: FileMode.read);
            final bytes = await raf.read(512 * 1024);
            await raf.close();
            if (bytes.contains(0)) {
              return const ExtractedDocumentResult(
                content: '[İkili (binary) dosya tespit edildi; metin olarak açılamaz]',
              );
            }
            final content = utf8.decode(bytes, allowMalformed: true);
            return ExtractedDocumentResult(
              content: '$content\n\n...[Dosya ${stat.size} bayt; ilk 512 KB gösterildi]',
            );
          }
        } catch (_) {}
      }

      final res = await Process.run(
        pythonBinary,
        [_parserScriptPath, filePath],
        environment: AppPaths.buildSubprocessEnv(),
      ).timeout(const Duration(seconds: 45));

      if (res.exitCode == 0 && res.stdout.toString().trim().isNotEmpty) {
        final data = jsonDecode(res.stdout.toString().trim());
        if (data['success'] == true) {
          final preview = data['rendered_image'] as String?;
          return ExtractedDocumentResult(
            content: data['content']?.toString() ?? '[Dosya içeriği boş]',
            renderedPreviewImage:
                (preview != null && File(preview).existsSync()) ? preview : null,
          );
        } else {
          return ExtractedDocumentResult(
            content: 'Ayrıştırma Hatası: ${data['error']}',
          );
        }
      } else {
        return ExtractedDocumentResult(
          content: 'Ayrıştırıcı Hatası: ${res.stderr.toString().trim()}',
        );
      }
    } catch (e) {
      return ExtractedDocumentResult(content: 'Dosya okuma hatası: $e');
    }
  }

  static Future<String> extractContent(String filePath) async {
    final res = await extractContentWithPreview(filePath);
    return res.content;
  }

  /// Word (.docx), Excel (.xlsx), PowerPoint (.pptx), PDF, AutoCAD (.dwg/.dxf), Görsel ve Ses/Müzik oluşturur/düzenler
  static Future<String> runFileStudio(Map<String, dynamic> spec) async {
    try {
      final proc = await Process.start(
        pythonBinary,
        [_studioScriptPath, '--stdin'],
        environment: AppPaths.buildSubprocessEnv(),
      );
      proc.stdin.write(jsonEncode(spec));
      await proc.stdin.flush();
      await proc.stdin.close();

      final stdoutStr = await proc.stdout.transform(const Utf8Decoder(allowMalformed: true)).join();
      final stderrStr = await proc.stderr.transform(const Utf8Decoder(allowMalformed: true)).join();
      final code = await proc.exitCode;

      if (stdoutStr.trim().isNotEmpty) {
        try {
          final parsed = jsonDecode(stdoutStr.trim()) as Map<String, dynamic>;
          if (parsed['success'] == true) {
            return 'BAŞARILI: ${parsed['message'] ?? parsed['output_path']}';
          }
          return 'HATA: ${parsed['error']}';
        } catch (_) {
          return stdoutStr.trim();
        }
      }
      return 'HATA (kod $code): ${stderrStr.trim()}';
    } catch (e) {
      return 'Dosya stüdyosu çalıştırma hatası: $e';
    }
  }

  /// Dosyayı kullanıcının masaüstü varsayılan uygulamasıyla (LibreOffice, Okular, CAD, VLC vb.) açar
  static Future<String> openInSystem(String targetPath) async {
    try {
      final f = File(targetPath);
      final d = Directory(targetPath);
      if (!f.existsSync() && !d.existsSync()) {
        return 'Hata: Açılacak dosya veya klasör bulunamadı ($targetPath)';
      }
      if (Platform.isLinux) {
        await Process.start(
          'xdg-open',
          [targetPath],
          mode: ProcessStartMode.detached,
          environment: AppPaths.buildSubprocessEnv(),
        );
      } else if (Platform.isMacOS) {
        await Process.start('open', [targetPath], mode: ProcessStartMode.detached);
      } else if (Platform.isWindows) {
        await Process.start('cmd', ['/c', 'start', '', targetPath], mode: ProcessStartMode.detached);
      }
      return 'Dosya sistem varsayılan uygulamasıyla açıldı: $targetPath';
    } catch (e) {
      return 'Dosya açılamadı: $e';
    }
  }

  static Future<AttachedFile> createFromImageBytes(Uint8List bytes, {String? customName}) async {
    final resizedBytes = await resizeImageBytes(bytes);
    final fileName = customName ?? 'screenshot_${DateTime.now().millisecondsSinceEpoch}.png';
    final savedPath = await _saveToAttachments(resizedBytes, fileName);

    return AttachedFile(
      id: '${DateTime.now().microsecondsSinceEpoch}_$fileName',
      path: savedPath,
      name: fileName,
      sizeBytes: resizedBytes.length,
      type: AttachedFileType.image,
      base64Image: savedPath,
    );
  }

  static Map<String, String> _getLinuxClipboardEnv() {
    final env = AppPaths.buildSubprocessEnv();
    if (!env.containsKey('XDG_RUNTIME_DIR') || env['XDG_RUNTIME_DIR']!.isEmpty) {
      final uid = Platform.environment['UID'] ?? '1000';
      if (Directory('/run/user/$uid').existsSync()) {
        env['XDG_RUNTIME_DIR'] = '/run/user/$uid';
      }
    }
    if (!env.containsKey('WAYLAND_DISPLAY') || env['WAYLAND_DISPLAY']!.isEmpty) {
      env['WAYLAND_DISPLAY'] = 'wayland-0';
    }
    if (!env.containsKey('DISPLAY') || env['DISPLAY']!.isEmpty) {
      env['DISPLAY'] = ':0';
    }
    return env;
  }

  static Future<Uint8List?> getClipboardImage() async {
    if (Platform.isLinux) {
      try {
        final listRes = await Process.run(
          'wl-paste',
          ['--list-types'],
          environment: _getLinuxClipboardEnv(),
        );
        if (listRes.exitCode == 0 && listRes.stdout is String) {
          final types = (listRes.stdout as String).toLowerCase();
          if (types.contains('image/png') ||
              types.contains('image/jpeg') ||
              types.contains('image/jpg') ||
              types.contains('image/webp')) {
            String mime = 'image/png';
            if (types.contains('image/png')) {
              mime = 'image/png';
            } else if (types.contains('image/jpeg')) {
              mime = 'image/jpeg';
            } else if (types.contains('image/webp')) {
              mime = 'image/webp';
            }
            final pasteRes = await Process.run(
              'wl-paste',
              ['-t', mime],
              stdoutEncoding: null,
              environment: _getLinuxClipboardEnv(),
            );
            if (pasteRes.exitCode == 0 && pasteRes.stdout != null) {
              final bytes = Uint8List.fromList((pasteRes.stdout as List).cast<int>());
              if (bytes.isNotEmpty) return bytes;
            }
          }
        }
      } catch (_) {}

      try {
        final pasteRes = await Process.run(
          'xclip',
          ['-selection', 'clipboard', '-t', 'image/png', '-o'],
          stdoutEncoding: null,
          environment: _getLinuxClipboardEnv(),
        );
        if (pasteRes.exitCode == 0 && pasteRes.stdout != null) {
          final bytes = Uint8List.fromList((pasteRes.stdout as List).cast<int>());
          if (bytes.isNotEmpty) return bytes;
        }
      } catch (_) {}
    }

    try {
      final img = await Pasteboard.image;
      if (img != null && img.isNotEmpty) {
        return img;
      }
    } catch (_) {}

    return null;
  }
}
