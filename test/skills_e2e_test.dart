// Skill katmanı uçtan uca testi. Gerçek ~/.feride verisine dokunmamak için yalnızca
// HOME geçici bir dizini gösterirken çalışır:
//   HOME=$(mktemp -d) FERIDE_SKILLS_SRC=~/.feride/skills flutter test test/skills_e2e_test.dart
import 'dart:ffi';
import 'dart:io';

import 'package:feride_v5_2/aegis/aegis_service.dart';
import 'package:feride_v5_2/agent/permissions.dart';
import 'package:feride_v5_2/agent/tools.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/open.dart';

void main() {
  // Test ortamında sistemdeki SQLite kullanılır (uygulama kendi kopyasını taşır).
  if (Platform.isLinux) open.overrideFor(OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
  final home = Platform.environment['HOME'] ?? '';
  final isolated = home.startsWith(Directory.systemTemp.path) || home.startsWith('/tmp');
  final src = Platform.environment['FERIDE_SKILLS_SRC'] ?? '';

  test('Parser: tırnaklı ve çok satırlı açıklamalar', () {
    final a = AegisService.parseSkillMd('---\nname: x\ndescription: "You MUST use this \\"now\\""\n---\nGövde');
    expect(a, ['x', 'You MUST use this "now"', 'Gövde']);
    final b = AegisService.parseSkillMd('---\nname: y\ndescription: >\n  Birinci satır\n  ikinci satır\n---\nG');
    expect(b![1], 'Birinci satır ikinci satır');
  });

  test('Diskteki tüm skill\'ler senkronize olur, use_skill klasörü verir', () async {
    // Gerçek skill'lerin kopyası geçici ~/.feride/skills altına alınır.
    final dest = Directory(p.join(home, '.feride', 'skills'))..createSync(recursive: true);
    final copy = await Process.run('cp', ['-r', '$src/.', dest.path]);
    expect(copy.exitCode, 0);
    final onDisk = dest.listSync().whereType<Directory>().where((d) => File(p.join(d.path, 'SKILL.md')).existsSync()).length;

    // Eski sürümün bozuk kaydını taklit et (use_count'a tarih yazılmış).
    final svc = AegisService.instance;
    svc.saveSkill(name: 'eski-kayit', description: 'd', content: 'c');
    svc.syncFromDisk();
    final skills = svc.listSkills();
    // ignore: avoid_print
    print('Diskte $onDisk skill, veritabanında ${skills.length} (eski-kayit dahil)');
    expect(skills.length, onDisk + 1);
    expect(skills.every((s) => !s.description.startsWith('"')), isTrue, reason: 'tırnaklar temizlenmeli');
    expect(skills.every((s) => s.useCount >= 0 && s.useCount < 1000), isTrue, reason: 'use_count sayı olmalı');

    final ex = ToolExecutor(BuiltinTools.core());
    final ctx = ToolContext(workspaceDir: home, policy: PermissionPolicy(mode: PermissionMode.ask, workspaceDir: home));
    final out = await ex.execute('use_skill', {'name': 'brainstorming'}, ctx);
    expect(out, contains('Bu becerinin klasörü'));
    expect(out, contains('visual-companion.md'));
    svc.bumpSkillUse('brainstorming');
    expect(svc.loadSkill('brainstorming')!.useCount, 2); // use_skill + bump
    final index = svc.getSkillIndex();
    expect(index, contains('systematic-debugging'));
  }, skip: !(isolated && src.isNotEmpty) ? 'Yalnızca geçici HOME ile çalışır' : false);
}
