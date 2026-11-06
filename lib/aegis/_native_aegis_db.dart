/// Native (masaüstü) ortamda Aegis hafızasının sqlite3 motoru.
/// Web'de bu dosya YÜKLENMEZ (aegis_service.dart'ta koşullu import),
/// böylece `package:sqlite3` -> `dart:ffi` web derlemesine girmez.
library;

import 'package:sqlite3/sqlite3.dart' as sqlite;

class NativeAegisDb {
  final String dbPath;
  late final sqlite.Database db;
  bool hasFts = false;

  NativeAegisDb(this.dbPath) {
    db = sqlite.sqlite3.open(dbPath);
    _init();
  }

  void _init() {
    db.execute('PRAGMA journal_mode = WAL;');
    db.execute('''
      CREATE TABLE IF NOT EXISTS skills (
        name TEXT PRIMARY KEY, description TEXT, content TEXT,
        use_count INTEGER DEFAULT 0, created_at TEXT, updated_at TEXT
      );
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS experiences (
        id INTEGER PRIMARY KEY AUTOINCREMENT, summary TEXT, tools_used TEXT,
        result TEXT, success INTEGER DEFAULT 1, created_at TEXT
      );
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS uninstalled_skills (
        name TEXT PRIMARY KEY, uninstalled_at TEXT
      );
    ''');
    try {
      db.execute('''
        CREATE VIRTUAL TABLE IF NOT EXISTS experiences_fts USING fts5(
          summary, tools_used, result,
          content='experiences', content_rowid='id'
        );
      ''');
      db.execute('''
        CREATE TRIGGER IF NOT EXISTS experiences_ai AFTER INSERT ON experiences BEGIN
          INSERT INTO experiences_fts(rowid, summary, tools_used, result)
          VALUES (new.id, new.summary, new.tools_used, new.result);
        END;
      ''');
      db.execute('''
        CREATE TRIGGER IF NOT EXISTS experiences_au AFTER UPDATE ON experiences BEGIN
          DELETE FROM experiences_fts WHERE rowid = old.id;
          INSERT INTO experiences_fts(rowid, summary, tools_used, result)
          VALUES (new.id, new.summary, new.tools_used, new.result);
        END;
      ''');
      hasFts = true;
    } catch (_) {
      hasFts = false;
    }
  }

  void dispose() => db.dispose();
}
