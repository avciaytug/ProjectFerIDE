/// Claude Code Tarzı Yardımcı Araçlar ve Servisler
/// (Grep, Glob, Checkpoint, Geri Alma ve Otomatik Kod Doğrulama)
library;

import 'dart:io';
import 'package:path/path.dart' as p;
import 'app_paths.dart';

class TodoItem {
  final String id;
  final String content;
  final String status; // 'pending', 'in_progress', 'completed'

  const TodoItem({
    required this.id,
    required this.content,
    required this.status,
  });

  factory TodoItem.fromMap(Map<String, dynamic> map) {
    return TodoItem(
      id: map['id']?.toString() ?? '',
      content: map['content']?.toString() ?? '',
      status: map['status']?.toString() ?? 'pending',
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'content': content,
        'status': status,
      };
}

class CheckpointService {
  static final CheckpointService instance = CheckpointService._();
  CheckpointService._();

  Future<String?> createCheckpoint(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return null;

      final cpDir = Directory(p.join(AppPaths.ferideDataDir, 'checkpoints'));
      if (!await cpDir.exists()) await cpDir.create(recursive: true);

      final ts = DateTime.now().millisecondsSinceEpoch;
      final baseName = p.basename(filePath);
      final backupPath = p.join(cpDir.path, '${ts}_$baseName');
      await file.copy(backupPath);
      return backupPath;
    } catch (_) {
      return null;
    }
  }

  Future<bool> rollback(String originalPath, String checkpointPath) async {
    try {
      final cpFile = File(checkpointPath);
      if (!await cpFile.exists()) return false;
      await cpFile.copy(originalPath);
      return true;
    } catch (_) {
      return false;
    }
  }
}

class CodeValidator {
  static Future<String?> validateFile(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return null;
      final ext = p.extension(filePath).toLowerCase();
      final env = AppPaths.buildSubprocessEnv();

      if (ext == '.dart') {
        final res = await Process.run('dart', ['analyze', filePath], environment: env)
            .timeout(const Duration(seconds: 15));
        if (res.exitCode != 0) {
          final out = res.stdout.toString() + res.stderr.toString();
          final lines = out
              .split('\n')
              .where((l) =>
                  l.contains('error •') ||
                  l.contains('Error:') ||
                  l.contains('warning •'))
              .take(6)
              .join('\n');
          if (lines.trim().isNotEmpty) {
            return '[Otomatik Doğrulama Uyarısı (dart analyze)]:\n$lines';
          }
        }
      } else if (ext == '.py') {
        final py = AppPaths.resolvePython();
        final res = await Process.run(py, ['-m', 'py_compile', filePath], environment: env)
            .timeout(const Duration(seconds: 15));
        if (res.exitCode != 0) {
          return '[Otomatik Doğrulama Hatası (py_compile)]:\n${res.stderr.toString().trim()}';
        }
      }
    } catch (_) {}
    return null;
  }
}

class GrepSearchService {
  static const Set<String> _skippedDirNames = {
    '.git',
    'node_modules',
    'build',
    '.dart_tool',
    'dosdevices',
    'venv',
    '.venv',
    '__pycache__',
    'models',
    '.feride',
    'proc',
    'sys',
    'dev',
    '.steam',
  };

  static Future<String> search({
    required String query,
    String? path,
    bool caseInsensitive = true,
  }) async {
    final targetPath = (path != null && path.trim().isNotEmpty)
        ? path.trim()
        : Directory.current.path;

    final env = AppPaths.buildSubprocessEnv();

    // 1. Önce ripgrep (rg) dene - En hızlı ve güvenli
    try {
      final rgArgs = [
        '-n',
        '--no-heading',
        '--color', 'never',
        '--max-count', '50',
        '--max-filesize', '2M',
        '--glob', '!.git/**',
        '--glob', '!**/node_modules/**',
        '--glob', '!**/build/**',
        '--glob', '!**/.dart_tool/**',
        '--glob', '!**/dosdevices/**',
        '--glob', '!**/models/**',
        '--glob', '!**/*.dat',
        if (caseInsensitive) '-i',
        query,
        targetPath,
      ];
      final rgBin = AppPaths.resolveRipgrep() ?? 'rg';
      final rgRes = await Process.run(rgBin, rgArgs, environment: env)
          .timeout(const Duration(seconds: 15));
      if (rgRes.exitCode == 0) {
        final lines = rgRes.stdout
            .toString()
            .split('\n')
            .where((l) => l.trim().isNotEmpty)
            .take(50)
            .join('\n');
        return lines.isNotEmpty ? lines : 'Eşleşme bulunamadı.';
      }
      if (rgRes.exitCode == 1) {
        return 'Eşleşme bulunamadı.';
      }
    } catch (_) {}

    // 2. İkinci seçenek: grep (Genişletilmiş Regex (-E) ve kesin çıkış kodu kontrolü ile)
    try {
      final grepArgs = [
        '-rnIE',
        '--binary-files=without-match',
        '--exclude-dir=.git',
        '--exclude-dir=node_modules',
        '--exclude-dir=build',
        '--exclude-dir=.dart_tool',
        '--exclude-dir=dosdevices',
        '--exclude-dir=venv',
        '--exclude-dir=.venv',
        '--exclude-dir=__pycache__',
        '--exclude-dir=models',
        '--exclude-dir=.feride',
        if (caseInsensitive) '-i',
        query,
        targetPath,
      ];
      final grepRes = await Process.run('grep', grepArgs, environment: env)
          .timeout(const Duration(seconds: 15));
      if (grepRes.exitCode == 0) {
        final lines = grepRes.stdout
            .toString()
            .split('\n')
            .where((l) => l.trim().isNotEmpty)
            .take(50)
            .join('\n');
        return lines.isNotEmpty ? lines : 'Eşleşme bulunamadı.';
      }
      if (grepRes.exitCode == 1) {
        return 'Eşleşme bulunamadı.';
      }
    } catch (_) {}

    // 3. Üçüncü seçenek: Bellek ve Sembolik Bağ Korumalı Saf Dart Araması
    // Yalnızca sistemde rg veya grep yoksa devreye girer.
    try {
      final target = File(targetPath);
      RegExp regex;
      try {
        regex = RegExp(query, caseSensitive: !caseInsensitive);
      } catch (_) {
        regex = RegExp(RegExp.escape(query), caseSensitive: !caseInsensitive);
      }

      final List<String> matches = [];

      if (target.existsSync()) {
        final stat = target.statSync();
        if (stat.size <= 2 * 1024 * 1024) {
          final lines = await target.readAsLines();
          for (int i = 0; i < lines.length; i++) {
            if (regex.hasMatch(lines[i])) {
              matches.add('${target.path}:${i + 1}: ${lines[i]}');
              if (matches.length >= 50) break;
            }
          }
        }
      } else {
        final dir = Directory(targetPath);
        if (dir.existsSync()) {
          final deadline = DateTime.now().add(const Duration(seconds: 15));
          int scannedFiles = 0;

          // followLinks: false kritik önemdedir: Wine/Proton dosdevices döngülerini engeller!
          await for (var entity in dir
              .list(recursive: true, followLinks: false)
              .handleError((_) {})) {
            if (DateTime.now().isAfter(deadline)) break;

            if (entity is Directory) {
              final base = p.basename(entity.path);
              if (_skippedDirNames.contains(base)) continue;
            } else if (entity is File) {
              final base = p.basename(entity.path);
              if (base.startsWith('.')) continue;

              // Yol üzerinde yasaklı klasör kontrolü
              final parts = p.split(entity.path);
              if (parts.any(_skippedDirNames.contains)) continue;

              try {
                final stat = await entity.stat();
                // 2 MB'dan büyük dosyaları ve binary dosyaları atla (OOM koruması)
                if (stat.size > 2 * 1024 * 1024) continue;

                final raf = await entity.open(mode: FileMode.read);
                final header = await raf.read(512);
                await raf.close();
                if (header.contains(0)) continue; // İkili (binary) dosya

                scannedFiles++;
                final lines = await entity.readAsLines();
                for (int i = 0; i < lines.length; i++) {
                  if (regex.hasMatch(lines[i])) {
                    matches.add('${entity.path}:${i + 1}: ${lines[i]}');
                    if (matches.length >= 50) break;
                  }
                }
              } catch (_) {}

              if (matches.length >= 50 || scannedFiles >= 2000) break;
            }
          }
        }
      }

      if (matches.isEmpty) return 'Eşleşme bulunamadı.';
      return matches.join('\n');
    } catch (e) {
      return 'Arama hatası: $e';
    }
  }
}

class GlobService {
  static const Set<String> _ignoredDirs = {
    '.git',
    'node_modules',
    'build',
    '.dart_tool',
    'dosdevices',
    'venv',
    '.venv',
    '__pycache__',
    'models',
    '.feride',
    'proc',
    'sys',
    'dev',
  };

  static Future<String> findFiles({
    required String pattern,
    String? path,
  }) async {
    final searchDir = (path != null && path.trim().isNotEmpty)
        ? Directory(path.trim())
        : Directory.current;

    if (!await searchDir.exists()) {
      return 'Hata: Arama dizini bulunamadı: ${searchDir.path}';
    }

    try {
      // ** ile * çakışmasını önleyen doğru dönüştürme
      final regExpPattern = pattern
          .replaceAll('.', r'\.')
          .replaceAll('**', '__GLOB_STAR_STAR__')
          .replaceAll('*', r'[^/]*')
          .replaceAll('__GLOB_STAR_STAR__', r'.*')
          .replaceAll('?', r'.');
      final regex = RegExp('^.*$regExpPattern\$');

      final List<String> matches = [];
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      int visitedCount = 0;

      await for (var entity in searchDir
          .list(recursive: true, followLinks: false)
          .handleError((_) {})) {
        visitedCount++;
        if (visitedCount >= 25000 || DateTime.now().isAfter(deadline)) break;

        final base = p.basename(entity.path);
        if (_ignoredDirs.contains(base)) continue;

        if (entity is File) {
          final relPath = p.relative(entity.path, from: searchDir.path);
          if (regex.hasMatch(relPath) || regex.hasMatch(base)) {
            matches.add(relPath);
            if (matches.length >= 100) break;
          }
        }
      }

      if (matches.isEmpty) return 'Desenle eşleşen dosya bulunamadı: $pattern';
      return matches.join('\n');
    } catch (e) {
      return 'Glob hatası: $e';
    }
  }
}

class ProjectRulesService {
  static String getProjectRules(String workingDir) {
    try {
      final ferideMd = File(p.join(workingDir, 'FERIDE.md'));
      if (ferideMd.existsSync()) {
        return '\n\n# PROJE KURALLARI (FERIDE.md):\n${ferideMd.readAsStringSync()}\n';
      }
      final claudeMd = File(p.join(workingDir, 'CLAUDE.md'));
      if (claudeMd.existsSync()) {
        return '\n\n# PROJE KURALLARI (CLAUDE.md):\n${claudeMd.readAsStringSync()}\n';
      }
    } catch (_) {}
    return '';
  }
}
