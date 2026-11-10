import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as p;
import 'package:feride_v5_2/aegis/_native_aegis_db.dart'
    if (dart.library.js) 'package:feride_v5_2/aegis/_native_aegis_db_stub.dart';
import '../services/app_paths.dart';

/// FerIDE'ye özel "kendini geliştiren" hafıza katmanı.
/// Adlandırma tamamen bizim: Skills (beceriler) + Experiences (deneyimler).
class AegisSkill {
  final String name;
  final String description;
  final String content;
  final int useCount;
  final String updatedAt;
  AegisSkill({
    required this.name,
    required this.description,
    required this.content,
    required this.useCount,
    required this.updatedAt,
  });
}

class AegisService {
  AegisService._();
  static final AegisService instance = AegisService._();

  NativeAegisDb? _db;
  bool _hasFts = false;
  bool get hasFts => _hasFts;

  // ---- Web (tarayıcı) modu: sqlite3/dart:ffi çalışmadığı için in-memory ----
  final bool _isWeb = kIsWeb;
  final List<Map<String, Object?>> _webSkills = [];
  final List<Map<String, Object?>> _webExps = [];
  final Set<String> _webUninstalled = {};
  int _webExpId = 0;

  String get _dataDir {
    if (_isWeb) return '/tmp';
    return p.join(AppPaths.ferideDataDir, 'aegis');
  }

  String get dbPath => p.join(_dataDir, 'memory.db');

  void _ensureInit() {
    if (_isWeb) {
      // Web'de hafıza in-memory; disk/ffi yok.
      if (_webSkills.isNotEmpty || _webExps.isNotEmpty || _webUninstalled.isNotEmpty) return;
      _hasFts = false;
      return;
    }
    if (_db != null) return;
    final dir = Directory(_dataDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    _db = NativeAegisDb(dbPath);
    _hasFts = _db!.hasFts;
    _exec('PRAGMA journal_mode = WAL;');
    _exec('''
      CREATE TABLE IF NOT EXISTS skills (
        name TEXT PRIMARY KEY,
        description TEXT,
        content TEXT,
        use_count INTEGER DEFAULT 0,
        created_at TEXT,
        updated_at TEXT
      );
    ''');
    // Eski sürümlerdeki sütun kayması: use_count'a tarih, created_at'e 0 yazılıyordu.
    try {
      _exec("UPDATE skills SET created_at = updated_at, use_count = 0 WHERE typeof(use_count) = 'text'");
    } catch (_) {}
    _exec('''
      CREATE TABLE IF NOT EXISTS experiences (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        summary TEXT,
        tools_used TEXT,
        result TEXT,
        success INTEGER DEFAULT 1,
        created_at TEXT
      );
    ''');
    _exec('''
      CREATE TABLE IF NOT EXISTS uninstalled_skills (
        name TEXT PRIMARY KEY,
        uninstalled_at TEXT
      );
    ''');
    // FTS5 tam metin arama (varsa). Yoksa LIKE fallback'e düşeriz.
    try {
      _exec('''
        CREATE VIRTUAL TABLE IF NOT EXISTS experiences_fts USING fts5(
          summary, tools_used, result,
          content='experiences', content_rowid='id'
        );
      ''');
      _exec('''
        CREATE TRIGGER IF NOT EXISTS experiences_ai AFTER INSERT ON experiences BEGIN
          INSERT INTO experiences_fts(rowid, summary, tools_used, result)
          VALUES (new.id, new.summary, new.tools_used, new.result);
        END;
      ''');
      // Harici içerikli FTS5'te satır 'delete' komutuyla ve eski değerlerle silinir.
      // Eski tetikleyiciler düz DELETE kullanıyordu; silinen kayıtların sözcükleri
      // dizinde kalıyordu. Bir kez değiştirilip dizin yeniden kurulur.
      final oldTrigger = _query("SELECT sql FROM sqlite_master WHERE name = 'experiences_ad'");
      final needsFix = oldTrigger.isNotEmpty && !(oldTrigger.first['sql'] as String? ?? '').contains("'delete'");
      if (needsFix) {
        _exec('DROP TRIGGER IF EXISTS experiences_ad;');
        _exec('DROP TRIGGER IF EXISTS experiences_au;');
      }
      _exec('''
        CREATE TRIGGER IF NOT EXISTS experiences_ad AFTER DELETE ON experiences BEGIN
          INSERT INTO experiences_fts(experiences_fts, rowid, summary, tools_used, result)
          VALUES ('delete', old.id, old.summary, old.tools_used, old.result);
        END;
      ''');
      _exec('''
        CREATE TRIGGER IF NOT EXISTS experiences_au AFTER UPDATE ON experiences BEGIN
          INSERT INTO experiences_fts(experiences_fts, rowid, summary, tools_used, result)
          VALUES ('delete', old.id, old.summary, old.tools_used, old.result);
          INSERT INTO experiences_fts(rowid, summary, tools_used, result)
          VALUES (new.id, new.summary, new.tools_used, new.result);
        END;
      ''');
      if (needsFix) _exec("INSERT INTO experiences_fts(experiences_fts) VALUES('rebuild');");
      _hasFts = true;
    } catch (_) {
      _hasFts = false;
    }
  }

  void recordExperience({
    required String summary,
    String toolsUsed = '',
    String result = '',
    bool success = true,
  }) {
    _ensureInit();
    final now = DateTime.now().toIso8601String();
    _exec(
      'INSERT INTO experiences (summary, tools_used, result, success, created_at) VALUES (?,?,?,?,?)',
      [summary, toolsUsed, result, success ? 1 : 0, now],
    );
    // 2000 kayıt tavanı (en eski kayıtlar silinsin)
    try {
      _exec('''
        DELETE FROM experiences WHERE id IN (
          SELECT id FROM experiences ORDER BY id DESC LIMIT -1 OFFSET 2000
        );
      ''');
    } catch (_) {}
  }

  List<Map<String, Object?>> searchExperiences(String query, {int limit = 5}) {
    _ensureInit();
    final q = query.trim();
    if (_hasFts && q.isNotEmpty && !_isWeb) {
      try {
        final words = RegExp(r'[a-zA-Z0-9ğüşıöçĞÜŞİÖÇ]{3,}')
            .allMatches(q)
            .map((m) => m.group(0)!)
            .take(8)
            .toList();
        if (words.isNotEmpty) {
          final ftsQuery = words.map((w) => '"$w"*').join(' OR ');
          final results = _query(
            'SELECT e.id, e.summary, e.tools_used, e.result, e.success, e.created_at '
            'FROM experiences_fts f JOIN experiences e ON e.id = f.rowid '
            'WHERE experiences_fts MATCH ? ORDER BY rank LIMIT ?',
            [ftsQuery, limit],
          );
          if (results.isNotEmpty) return results;
        }
      } catch (_) {
        // FTS sözdizimi hatası -> LIKE'a düş
      }
    }
    final like = '%$q%';
    return _query(
      'SELECT id, summary, tools_used, result, success, created_at FROM experiences '
      'WHERE summary LIKE ? OR tools_used LIKE ? OR result LIKE ? '
      'ORDER BY id DESC LIMIT ?',
      [like, like, like, limit],
    );
  }

  void saveSkill({
    required String name,
    required String description,
    required String content,
  }) {
    _ensureInit();
    final now = DateTime.now().toIso8601String();
    _exec(
      'INSERT INTO skills (name, description, content, use_count, created_at, updated_at) '
      'VALUES (?,?,?,0,?,?) '
      'ON CONFLICT(name) DO UPDATE SET '
      'description=excluded.description, content=excluded.content, updated_at=excluded.updated_at',
      [name, description, content, now, now],
    );
  }

  List<AegisSkill> listSkills() {
    _ensureInit();
    final rows = _query(
      'SELECT name, description, content, use_count, updated_at '
      'FROM skills ORDER BY use_count DESC, updated_at DESC',
    );
    return rows
        .map((r) => AegisSkill(
              name: r['name'] as String,
              description: (r['description'] as String?) ?? '',
              content: (r['content'] as String?) ?? '',
              useCount: int.tryParse('${r['use_count']}') ?? 0,
              updatedAt: (r['updated_at'] as String?) ?? '',
            ))
        .toList();
  }

  void bumpSkillUse(String name) {
    _ensureInit();
    _exec('UPDATE skills SET use_count = use_count + 1 WHERE name = ?', [name]);
  }

  void deleteSkill(String name) {
    _ensureInit();
    _exec('DELETE FROM skills WHERE name = ?', [name]);
  }

  void deleteSkillCompletely(String name, {String? customSkillsPath}) {
    _ensureInit();
    deleteSkill(name);
    try {
      // Tombstone: Tekrar taramada bu skill'in otomatik geri yüklenmesini önle
      _exec(
        'INSERT OR REPLACE INTO uninstalled_skills (name, uninstalled_at) VALUES (?, ?)',
        [name, DateTime.now().toIso8601String()],
      );
      // Sadece yerel ~/.feride/skills/<name> klasörünü sil
      final ferideSkillDir = Directory(p.join(skillsDir, name));
      if (ferideSkillDir.existsSync()) {
        ferideSkillDir.deleteSync(recursive: true);
      }
      // DİKKAT: customSkillsPath kaynak deposu (superpowers vb.) ASLA silinmez!
    } catch (_) {}
  }

  int experienceCount() {
    _ensureInit();
    final r = _query('SELECT COUNT(*) AS c FROM experiences');
    return (r.first['c'] as int?) ?? 0;
  }

  /// Sistem promptuna enjekte edilecek, sorguyla en alakalı beceri + deneyim bloğu.
  /// Aşamalı açıklama ("progressive disclosure"): prompt'a yalnızca skill İNDEKSİ
  /// (isim + açıklama) girer; tam talimat use_skill aracıyla yüklenir. Token tasarrufu sağlar.
  String getRelevantContext(String query, {int skillLimit = 40, int expLimit = 3, List<String> disabledSkills = const []}) {
    _ensureInit();
    final buf = StringBuffer();
    final index = getSkillIndex(limit: skillLimit, disabledSkills: disabledSkills);
    if (index.isNotEmpty) {
      buf.writeln(index);
      buf.writeln();
    }
    final exps = searchExperiences(query, limit: expLimit);
    if (exps.isNotEmpty) {
      buf.writeln('## GEÇMİŞ DENEYİMLER (Memory)');
      buf.writeln('(Yalnızca yöntem örneğidir. Eski yanıtları kopyalama; kimliğin doğrudan sorulmadıkça kendini tanıtma.)');
      for (final e in exps) {
        final ok = e['success'] == 1 ? 'Başarılı' : 'Hatalı';
        final tools = (e['tools_used'] as String?) ?? '';
        buf.writeln('- [$ok] ${e['summary']}${tools.isNotEmpty ? ' (araçlar: $tools)' : ''}');
      }
      buf.writeln();
    }
    return buf.toString().trim();
  }

  // ---------- SKILL.md desteği ----------
  // Klasik yapı: ~/.feride/skills/<skill-ad>/SKILL.md
  // SKILL.md: YAML frontmatter (name, description) + markdown gövde.

  /// Kişisel skill klasörü (~/.feride/skills).
  String get skillsDir => p.join(AppPaths.ferideDataDir, 'skills');

  /// SKILL.md içeriğini ayrıştırır: [name, description, body] döner, geçersizse null.
  /// Tırnaklı değerler ("..."/'...') ve çok satırlı YAML (>, |, girintili devam) desteklenir.
  static List<String>? parseSkillMd(String raw) {
    final text = raw.replaceAll('\r\n', '\n').trim();
    if (!text.startsWith('---')) return null;
    final end = text.indexOf('\n---', 3);
    if (end < 0) return null;
    final front = text.substring(3, end).split('\n');
    final body = text.substring(end + 4).trim();

    String? field(String key) {
      for (var i = 0; i < front.length; i++) {
        final line = front[i];
        if (!line.startsWith('$key:')) continue;
        var value = line.substring(key.length + 1).trim();
        final block = value == '>' || value == '|' || value == '>-' || value == '|-' || value.isEmpty;
        if (block) {
          final parts = <String>[];
          for (var j = i + 1; j < front.length && (front[j].startsWith(' ') || front[j].startsWith('\t')); j++) {
            parts.add(front[j].trim());
          }
          value = parts.join(' ');
        } else {
          // Girintili devam satırları (düz çok satırlı değer)
          for (var j = i + 1; j < front.length && front[j].startsWith('  '); j++) {
            value += ' ${front[j].trim()}';
          }
        }
        if (value.length >= 2 &&
            ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'")))) {
          value = value.substring(1, value.length - 1).replaceAll(r'\"', '"');
        }
        return value.trim();
      }
      return null;
    }

    final name = field('name');
    if (name == null || name.isEmpty) return null;
    return [name, field('description') ?? '', body];
  }

  /// Bir skill'in diskteki klasörü (yoksa null) ve içindeki ek dosyalar.
  ({String dir, List<String> files})? skillFolder(String name) {
    final d = Directory(p.join(skillsDir, name));
    if (!d.existsSync()) return null;
    final files = <String>[];
    try {
      for (final e in d.listSync(recursive: true)) {
        if (e is File && p.basename(e.path) != 'SKILL.md') files.add(p.relative(e.path, from: d.path));
        if (files.length >= 40) break;
      }
    } catch (_) {}
    files.sort();
    return (dir: d.path, files: files);
  }

  /// Tek bir skill klasörünü (içinde SKILL.md olan) ~/.feride/skills/'e kopyalar ve DB'ye kaydeder.
  /// Skill adını döndürür, hata mesajı döndürür (başarısızsa).
  String importSkillFolder(String folderPath) {
    _ensureInit();
    final skillFile = File(p.join(folderPath, 'SKILL.md'));
    if (!skillFile.existsSync()) return 'HATA: SKILL.md bulunamadı: $folderPath';
    final parsed = parseSkillMd(skillFile.readAsStringSync());
    if (parsed == null) return 'HATA: SKILL.md frontmatter eksik (name: gerekli): $folderPath';
    final name = parsed[0];
    final desc = parsed[1];
    final body = parsed[2];
    // Skill diskte de yaşar (~/.feride/skills/<name>/)
    final src = Directory(folderPath);
    final target = Directory(p.join(skillsDir, name));
    if (!target.existsSync()) {
      Directory(skillsDir).createSync(recursive: true);
      _copyDirRecursive(src, target);
    }
    final now = DateTime.now().toIso8601String();
    _exec(
      'INSERT INTO skills (name, description, content, use_count, created_at, updated_at) '
      'VALUES (?,?,?,0,?,?) '
      'ON CONFLICT(name) DO UPDATE SET '
      'description=excluded.description, content=excluded.content, updated_at=excluded.updated_at',
      [name, desc, body, now, now],
    );
    return name;
  }

  /// Bir dizindeki TÜM skill klasörlerini tarama (örn: superpowers/skills/ gibi).
  /// Başarıyla içe aktarılan skill adlarını döndürür.
  List<String> importSkillsFromDirectory(String dirPath) {
    final dir = Directory(dirPath);
    if (!dir.existsSync()) return [];
    final results = <String>[];

    // 1. Altındaki 'skills' alt dizini varsa orayı tara
    final subSkills = Directory(p.join(dirPath, 'skills'));
    if (subSkills.existsSync()) {
      for (final entry in subSkills.listSync()) {
        if (entry is Directory && File(p.join(entry.path, 'SKILL.md')).existsSync()) {
          final r = importSkillFolder(entry.path);
          if (!r.startsWith('HATA')) results.add(r);
        }
      }
    }

    // 2. Ana dizindeki yetenek klasörlerini tara
    for (final entry in dir.listSync()) {
      if (entry is Directory && File(p.join(entry.path, 'SKILL.md')).existsSync()) {
        final r = importSkillFolder(entry.path);
        if (!r.startsWith('HATA')) results.add(r);
      }
    }
    return results.toSet().toList();
  }

  /// Uygulama açılışında ~/.feride/skills/'i tarar, DB'de olmayan skill'leri ekler.
  /// Kullanıcı bir skill klasörünü buraya kopyaladığında bir sonraki açılışta otomatik yüklenir.
  void syncFromDisk() {
    final dir = Directory(skillsDir);
    if (!dir.existsSync()) return;
    final uninstalled = _getUninstalledSkillNames();
    for (final entry in dir.listSync()) {
      if (entry is Directory && File(p.join(entry.path, 'SKILL.md')).existsSync()) {
        final skillName = p.basename(entry.path);
        if (uninstalled.contains(skillName)) continue;
        try {
          importSkillFolder(entry.path);
        } catch (_) {}
      }
    }
  }

  Set<String> _getUninstalledSkillNames() {
    _ensureInit();
    try {
      final rows = _query('SELECT name FROM uninstalled_skills');
      return rows.map((r) => r['name'] as String).toSet();
    } catch (_) {
      return {};
    }
  }

  /// Sistem promptu için hafif indeks: yalnızca isim + açıklama (progressive disclosure).
  String getSkillIndex({int limit = 40, List<String> disabledSkills = const []}) {
    _ensureInit();
    final allSkills = listSkills();
    final skills = allSkills.where((s) => !disabledSkills.contains(s.name)).toList();
    if (skills.isEmpty) return '';
    final buf = StringBuffer();
    buf.writeln('## KAZANILMIŞ BECERİLER (Skills) — bir beceri görevi uyuşuyorsa TAM talimatı için use_skill aracıyla çağır:');
    for (final s in skills.take(limit)) {
      buf.writeln('- ${s.name}: ${s.description}');
    }
    return buf.toString().trim();
  }

  /// Tam skill gövdesini yükler (use_skill aracı bunu çağırır).
  AegisSkill? loadSkill(String name) {
    _ensureInit();
    for (final s in listSkills()) {
      if (s.name == name) return s;
    }
    return null;
  }

  /// Klasörün tamamını (alt klasörlerle) kopyalar.
  void _copyDirRecursive(Directory src, Directory dest) {
    dest.createSync(recursive: true);
    for (final entity in src.listSync()) {
      final target = p.join(dest.path, p.basename(entity.path));
      if (entity is Directory) {
        _copyDirRecursive(entity, Directory(target));
      } else {
        File(entity.path).copySync(target);
      }
    }
  }

  // ---- Web/Native ortak SQL sarmalayıcıları ----
  // Web'de hafıza in-memory; native'de sqlite3. Tüm _db!.execute/select
  // çağrıları bu iki metottan geçerek platform farkı tek noktada çözülür.
  void _exec(String sql, [List<Object?> params = const []]) {
    if (_isWeb) {
      _webExec(sql, params);
      return;
    }
    _db!.db.execute(sql, params);
  }

  List<Map<String, Object?>> _query(String sql, [List<Object?> params = const []]) {
    if (_isWeb) {
      return _webQuery(sql, params);
    }
    return _db!.db.select(sql, params);
  }

  // --- Web in-memory motoru (basit ama yeterli) ---
  void _webExec(String sql, List<Object?> params) {
    final s = sql.toLowerCase().trim();
    if (s.startsWith('insert into skills')) {
      final name = params[0] as String;
      final existing = _webSkills.where((r) => r['name'] == name).firstOrNull;
      if (existing != null) {
        existing['description'] = params[1];
        existing['content'] = params[2];
        existing['updated_at'] = params[4];
      } else {
        _webSkills.add({
          'name': name, 'description': params[1], 'content': params[2],
          'use_count': 0, 'created_at': params[4], 'updated_at': params[4],
        });
      }
    } else if (s.startsWith('update skills set use_count')) {
      for (final r in _webSkills) {
        if (r['name'] == params[0]) r['use_count'] = (r['use_count'] as int) + 1;
      }
    } else if (s.startsWith('delete from skills')) {
      _webSkills.removeWhere((r) => r['name'] == params[0]);
    } else if (s.startsWith('insert into experiences') || s.startsWith('insert or replace into experiences')) {
      _webExpId++;
      _webExps.add({
        'id': _webExpId, 'summary': params[0], 'tools_used': params[1],
        'result': params[2], 'success': params[3] as int, 'created_at': params[4],
      });
      if (_webExps.length > 2000) _webExps.removeAt(0);
    } else if (s.startsWith('insert or replace into uninstalled_skills') || s.startsWith('insert into uninstalled_skills')) {
      _webUninstalled.add(params[0] as String);
    }
  }

  List<Map<String, Object?>> _webQuery(String sql, List<Object?> params) {
    final s = sql.toLowerCase().trim();
    if (s.startsWith('select name, description, content')) {
      final sorted = _webSkills.toList()
        ..sort((a, b) {
          final uc = (b['use_count'] as int) - (a['use_count'] as int);
          return uc != 0 ? uc : 0;
        });
      return sorted;
    }
    if (s.startsWith('select count(*) as c from experiences')) {
      return [
        {'c': _webExps.length}
      ];
    }
    if (s.startsWith('select name from uninstalled_skills')) {
      return _webUninstalled.map((n) => {'name': n}).toList();
    }
    if (s.startsWith('select id, summary, tools_used') || s.startsWith('select e.id')) {
      final like = (params.firstOrNull as String?) ?? '';
      final lim = (params.last is int) ? params.last as int : 5;
      final q = like.replaceAll('%', '').toLowerCase();
      final filtered = _webExps.where((r) {
        if (q.isEmpty) return true;
        return '${r['summary']}'.toLowerCase().contains(q) ||
            '${r['tools_used']}'.toLowerCase().contains(q) ||
            '${r['result']}'.toLowerCase().contains(q);
      }).toList();
      filtered.sort((a, b) => (b['id'] as int) - (a['id'] as int));
      return filtered.take(lim).toList();
    }
    return const [];
  }

  void dispose() {
    if (_isWeb) {
      _webSkills.clear();
      _webExps.clear();
      _webUninstalled.clear();
      return;
    }
    _db?.dispose();
    _db = null;
  }
}
