// "Sen kimsin?" sorusuna eski bir sürümün yanıtı ("Claude Code standartlarında...")
// hafızadaki deneyim kaydından geri geliyordu. Bu testler kimlik talimatını ve
// hafıza dizininin silinen kayıtları gerçekten unuttuğunu doğrular.
// Gerçek ~/.feride verisine dokunmamak için yalnızca geçici HOME ile çalışır.
import 'dart:ffi';
import 'dart:io';

import 'package:feride_v5_2/aegis/aegis_service.dart';
import 'package:feride_v5_2/features/chat/state.dart';
import 'package:feride_v5_2/services/agent_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  if (Platform.isLinux) open.overrideFor(OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
  final isolated = (Platform.environment['HOME'] ?? '').startsWith('/tmp');

  test('Sistem talimatı FerIDE\'yi başka bir ürünün standardı olarak tanıtmaz', () {
    final prompt = AgentEngine.buildSystemPrompt(
      isLiveSession: false,
      thinkingMode: false,
      thinkingLevel: ThinkingLevel.med,
      workingDirectory: '/tmp',
    );
    expect(prompt, contains("Sen FerIDE'sin"));
    expect(prompt.toLowerCase(), isNot(contains('claude code standart')));
    expect(prompt, contains('başka bir ürünün'));
  });

  test('Silinen deneyim hafıza aramasında ve dizinde kalmaz; eski tetikleyiciler onarılır', () {
    final svc = AegisService.instance;
    // Eski (hatalı) tetikleyicili bir veritabanı hazırla.
    File(svc.dbPath).parent.createSync(recursive: true);
    final old = sqlite3.open(svc.dbPath)
      ..execute('CREATE TABLE IF NOT EXISTS experiences (id INTEGER PRIMARY KEY AUTOINCREMENT, summary TEXT, '
          'tools_used TEXT, result TEXT, success INTEGER DEFAULT 1, created_at TEXT)')
      ..execute("CREATE VIRTUAL TABLE IF NOT EXISTS experiences_fts USING fts5(summary, tools_used, result, "
          "content='experiences', content_rowid='id')")
      ..execute('CREATE TRIGGER IF NOT EXISTS experiences_ai AFTER INSERT ON experiences BEGIN '
          'INSERT INTO experiences_fts(rowid, summary, tools_used, result) VALUES (new.id, new.summary, new.tools_used, new.result); END')
      ..execute('CREATE TRIGGER IF NOT EXISTS experiences_ad AFTER DELETE ON experiences BEGIN '
          'DELETE FROM experiences_fts WHERE rowid = old.id; END');
    old.dispose();

    svc.recordExperience(summary: 'SORU: sen kimsin? SONUÇ: eskiyanit', toolsUsed: 'x');
    expect(svc.searchExperiences('eskiyanit'), isNotEmpty);

    final db = sqlite3.open(svc.dbPath);
    expect(db.select("SELECT sql FROM sqlite_master WHERE name='experiences_ad'").first['sql'], contains("'delete'"));
    db.execute("DELETE FROM experiences WHERE summary LIKE '%eskiyanit%'");
    expect(db.select("SELECT COUNT(*) AS c FROM experiences_fts WHERE experiences_fts MATCH 'eskiyanit'").first['c'], 0);
    db.dispose();
    expect(svc.searchExperiences('eskiyanit'), isEmpty);
  }, skip: isolated ? false : 'Yalnızca geçici HOME ile çalışır');
}
