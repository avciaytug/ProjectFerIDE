import 'dart:io';

import 'package:feride_v5_2/services/claude_tools.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  setUp(() {
    root = Directory.systemTemp.createTempSync('feride_glob_');
    for (final f in [
      'a.txt',
      'b.txt',
      'notlar (eski).txt',
      'src/main.dart',
      'src/ui/panel.dart',
      'docs/rapor.pdf',
      'node_modules/pkg/index.js',
      'node_modules/pkg/readme.txt',
      'build/app.dart',
    ]) {
      File(p.join(root.path, f))
        ..createSync(recursive: true)
        ..writeAsStringSync('x');
    }
  });
  tearDown(() => root.deleteSync(recursive: true));

  Future<List<String>> find(String pattern) async {
    final out = await GlobService.findFiles(pattern: pattern, path: root.path);
    if (out.startsWith('Desenle eşleşen')) return [];
    return out.split('\n')..sort();
  }

  test('**/*.txt kökteki dosyaları da bulur (eskiden bulamıyordu)', () async {
    expect(await find('**/*.txt'), ['a.txt', 'b.txt', 'notlar (eski).txt']);
  });

  test('**/*.dart alt klasörlerde bulur, yoksayılan klasörlerin içine girmez', () async {
    expect(await find('**/*.dart'), ['src/main.dart', 'src/ui/panel.dart']);
  });

  test('Klasörsüz desen her derinlikte dosya adına uygulanır', () async {
    expect(await find('*.pdf'), ['docs/rapor.pdf']);
  });

  test('Klasörlü desen yalnızca o yola uyar', () async {
    expect(await find('src/*.dart'), ['src/main.dart']);
    expect(await find('src/**/*.dart'), ['src/main.dart', 'src/ui/panel.dart']);
  });

  test('Parantezli adlar ve {a,b} seçenekleri', () async {
    expect(await find('notlar (eski).txt'), ['notlar (eski).txt']);
    expect(await find('**/*.{pdf,dart}'), ['docs/rapor.pdf', 'src/main.dart', 'src/ui/panel.dart']);
  });

  test('globToRegExp: ? tek karakter, * klasör ayırıcıyı geçmez', () {
    expect(GlobService.globToRegExp('?.txt').hasMatch('a.txt'), isTrue);
    expect(GlobService.globToRegExp('?.txt').hasMatch('ab.txt'), isFalse);
    expect(GlobService.globToRegExp('*.txt').hasMatch('dir/a.txt'), isFalse);
  });
}
