import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:feride_v5_2/services/claude_tools.dart';

void main() {
  group('ClaudeTools Services Tests', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('feride_test_');
    });

    tearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('CheckpointService creates and rolls back file backup', () async {
      final testFile = File('${tempDir.path}/code.txt');
      await testFile.writeAsString('original version');

      final backupPath = await CheckpointService.instance.createCheckpoint(testFile.path);
      expect(backupPath, isNotNull);
      expect(File(backupPath!).existsSync(), isTrue);

      // Modify original
      await testFile.writeAsString('corrupted version');
      expect(await testFile.readAsString(), 'corrupted version');

      // Rollback
      final restored = await CheckpointService.instance.rollback(testFile.path, backupPath);
      expect(restored, isTrue);
      expect(await testFile.readAsString(), 'original version');
    });

    test('GlobService matches files by wildcard pattern', () async {
      File('${tempDir.path}/main.dart').writeAsStringSync('void main() {}');
      File('${tempDir.path}/test_item.dart').writeAsStringSync('class Item {}');
      File('${tempDir.path}/readme.md').writeAsStringSync('# Readme');

      final result = await GlobService.findFiles(pattern: '*.dart', path: tempDir.path);
      expect(result, contains('main.dart'));
      expect(result, contains('test_item.dart'));
      expect(result, isNot(contains('readme.md')));
    });

    test('GrepSearchService finds matching lines in files', () async {
      final file = File('${tempDir.path}/sample.txt');
      file.writeAsStringSync('line 1: hello\nline 2: FerIDE Claude\nline 3: goodbye');

      final result = await GrepSearchService.search(query: 'Claude', path: file.path);
      expect(result, contains('FerIDE Claude'));
    });

    test('ProjectRulesService reads FERIDE.md and CLAUDE.md', () {
      final ferideMd = File('${tempDir.path}/FERIDE.md');
      ferideMd.writeAsStringSync('Custom Project Rule: Always run tests before build.');

      final rules = ProjectRulesService.getProjectRules(tempDir.path);
      expect(rules, contains('PROJE KURALLARI (FERIDE.md)'));
      expect(rules, contains('Always run tests before build.'));
    });
  });
}
