/// FerIDE araç sistemi.
///
/// Tüm araçlar tek bir [AgentTool] tanımında toplanır: şema, risk sınıfı ve
/// çalıştırıcı aynı yerde durur. Ana ajan ve alt ajanlar aynı
/// [ToolExecutor]'ı kullanır; böylece izin denetimi, çıktı kısaltma ve hata
/// yönetimi tek noktadan yapılır (eskiden 3 ayrı kopya vardı).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../aegis/aegis_service.dart';
import '../services/app_paths.dart';
import '../services/claude_tools.dart';
import '../services/file_service.dart';
import '../services/mcp_service.dart';
import '../services/pty_sandbox.dart';
import 'permissions.dart';

typedef ToolHandler = Future<String> Function(Map<String, dynamic> args, ToolContext ctx);

/// Araç çalışırken erişebildiği ortam.
class ToolContext {
  final String workspaceDir;
  final PermissionPolicy policy;
  final String? sessionId;

  /// todo_write çağrıldığında UI'ı günceller.
  final void Function(List<TodoItem> todos)? onTodos;

  /// spawn_agent: alt ajanı çalıştırıp özetini döndürür.
  final Future<String> Function(String goal, int maxSteps)? spawnSubagent;

  /// dispatch_worker (sesli oturum): görevi arka plana devreder.
  final void Function(String goal)? dispatchWorker;

  /// Beceri/deneyim kaydı sonrası UI sayaçlarını yenilemek için.
  final void Function()? onMemoryChanged;

  const ToolContext({
    required this.workspaceDir,
    required this.policy,
    this.sessionId,
    this.onTodos,
    this.spawnSubagent,
    this.dispatchWorker,
    this.onMemoryChanged,
  });

  /// `~` ve göreceli yolları çalışma alanına göre mutlak yola çevirir.
  String resolvePath(String raw) {
    var path = raw.trim();
    if (path.startsWith('file://')) path = Uri.parse(path).toFilePath();
    if (path == '~') return AppPaths.homeDir;
    if (path.startsWith('~/') || path.startsWith(r'~\')) {
      path = p.join(AppPaths.homeDir, path.substring(2));
    }
    if (!p.isAbsolute(path)) path = p.join(workspaceDir, path);
    return p.normalize(path);
  }
}

class AgentTool {
  final String name;
  final String description;
  final Map<String, dynamic> parameters;
  final ToolRisk risk;
  final ToolHandler handler;

  /// Argümanlara göre riski yeniden belirler (ör. çalıştırılabilir dosya açmak).
  final ToolRisk Function(Map<String, dynamic> args, ToolContext ctx)? riskOf;

  /// İzin denetimi için çalıştırılacak komut.
  final String? Function(Map<String, dynamic> args)? commandOf;

  /// İzin denetimi için yazılacak yollar.
  final List<String> Function(Map<String, dynamic> args, ToolContext ctx)? pathsOf;

  /// Onay penceresinde gösterilecek kısa açıklama.
  final String Function(Map<String, dynamic> args)? summarize;

  /// Çıktı en fazla bu kadar karakter modele gönderilir.
  final int maxOutputChars;

  const AgentTool({
    required this.name,
    required this.description,
    required this.parameters,
    required this.risk,
    required this.handler,
    this.riskOf,
    this.commandOf,
    this.pathsOf,
    this.summarize,
    this.maxOutputChars = 16000,
  });

  Map<String, dynamic> get schema => {
        'type': 'function',
        'function': {
          'name': name,
          'description': description,
          'parameters': parameters,
        },
      };
}

// ---------------------------------------------------------------------------
// Argüman yardımcıları: yerel modeller sayıları string, bool'ları "true" gibi
// gönderebilir; eskiden `as int` dönüşümü tüm turu çökertiyordu.
// ---------------------------------------------------------------------------
String argStr(Map<String, dynamic> a, String key, [String fallback = '']) {
  final v = a[key];
  if (v == null) return fallback;
  return v is String ? v : v.toString();
}

int argInt(Map<String, dynamic> a, String key, int fallback) {
  final v = a[key];
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim()) ?? fallback;
  return fallback;
}

bool argBool(Map<String, dynamic> a, String key, bool fallback) {
  final v = a[key];
  if (v is bool) return v;
  if (v is String) return v.toLowerCase() == 'true' || v == '1';
  if (v is num) return v != 0;
  return fallback;
}

String truncate(String s, int max) {
  if (s.length <= max) return s;
  final head = (max * 0.7).floor();
  final tail = max - head;
  return '${s.substring(0, head)}\n...[${s.length - max} karakter kısaltıldı]...\n${s.substring(s.length - tail)}';
}

class ToolExecutor {
  final Map<String, AgentTool> _tools;

  ToolExecutor(List<AgentTool> tools) : _tools = {for (final t in tools) t.name: t};

  List<Map<String, dynamic>> get schemas => _tools.values.map((t) => t.schema).toList();
  Iterable<String> get names => _tools.keys;
  bool has(String name) => _tools.containsKey(name);

  /// Aracı izin denetiminden geçirip çalıştırır. Hiçbir zaman fırlatmaz;
  /// hata durumunda modelin anlayacağı bir metin döner.
  Future<String> execute(String name, Map<String, dynamic>? args, ToolContext ctx) async {
    final tool = _tools[name];
    if (tool == null) {
      return "Hata: '$name' adında bir araç yok. Kullanılabilir araçlar: ${_tools.keys.join(', ')}";
    }
    if (args == null) {
      return 'Hata: Araç argümanları geçerli JSON değil. Parametreleri geçerli bir JSON nesnesi olarak yeniden gönder.';
    }

    final risk = tool.riskOf?.call(args, ctx) ?? tool.risk;
    final command = tool.commandOf?.call(args);
    final paths = tool.pathsOf?.call(args, ctx) ?? const <String>[];
    final verdict = ctx.policy.evaluate(toolName: name, risk: risk, command: command, paths: paths);

    if (verdict.decision == PermissionDecision.deny) {
      return 'ENGELLENDİ: ${verdict.reason} Kullanıcıdan bu işlemi kendisinin yapmasını iste veya daha güvenli bir yol öner.';
    }
    if (verdict.decision == PermissionDecision.ask) {
      final approved = await ApprovalBroker.instance.request(ApprovalRequest(
        id: '${DateTime.now().microsecondsSinceEpoch}',
        toolName: name,
        summary: tool.summarize?.call(args) ?? _defaultSummary(name, args),
        reason: verdict.reason,
        risk: risk,
      ));
      if (!approved) {
        return 'REDDEDİLDİ: Kullanıcı bu işleme izin vermedi. Aynı işlemi tekrar deneme; kullanıcıya ne yapmak istediğini sor veya farklı bir yol öner.';
      }
    }

    try {
      final out = await tool.handler(args, ctx);
      final trimmed = out.trim().isEmpty ? '(Araç başarıyla çalıştı, çıktı yok.)' : out;
      return truncate(trimmed, tool.maxOutputChars);
    } catch (e) {
      return 'Hata ($name): $e';
    }
  }

  static String _defaultSummary(String name, Map<String, dynamic> args) {
    final s = const JsonEncoder.withIndent('  ').convert(args);
    return '$name\n${truncate(s, 1200)}';
  }
}

// ===========================================================================
// Yerleşik araçlar
// ===========================================================================
class BuiltinTools {
  static const _obj = 'object';

  static List<AgentTool> core() => [
        runCommand,
        readFile,
        writeFile,
        editFile,
        listDirectory,
        grepSearch,
        glob,
        readDocument,
        editDocument,
        openInSystem,
        takeScreenshot,
        searchWeb,
        fetchUrl,
        todoWrite,
        useSkill,
        saveSkill,
        recordExperience,
      ];

  // ---------------------------------------------------------------- komut
  static final runCommand = AgentTool(
    name: 'run_command',
    description:
        'Kabukta komut çalıştırır (Linux/macOS: bash, Windows: PowerShell). Derleme, test, git, paket yönetimi, '
        'sistem bilgisi ve uygulama başlatma için kullan. GUI uygulamaları ve uzun süren servisler için background=true ver. '
        'Çalışma dizini varsayılan olarak çalışma alanıdır.',
    parameters: {
      'type': _obj,
      'properties': {
        'command': {'type': 'string', 'description': 'Çalıştırılacak komut'},
        'background': {
          'type': 'boolean',
          'description': 'true ise komut ayrık süreçte başlatılır ve beklenmez (GUI uygulamaları, sunucular).'
        },
        'cwd': {'type': 'string', 'description': 'İsteğe bağlı çalışma dizini'},
        'timeout_seconds': {'type': 'integer', 'description': 'Zaman aşımı (varsayılan 120, en fazla 900)'},
      },
      'required': ['command'],
    },
    risk: ToolRisk.execute,
    commandOf: (a) => argStr(a, 'command'),
    summarize: (a) => '\$ ${argStr(a, 'command')}${argBool(a, 'background', false) ? '   (arka planda)' : ''}',
    maxOutputChars: 12000,
    handler: (a, ctx) async {
      final cmd = argStr(a, 'command').trim();
      if (cmd.isEmpty) return 'Hata: "command" boş.';
      final cwdRaw = argStr(a, 'cwd');
      final cwd = cwdRaw.isEmpty ? ctx.workspaceDir : ctx.resolvePath(cwdRaw);
      if (!Directory(cwd).existsSync()) return 'Hata: Çalışma dizini yok: $cwd';

      if (argBool(a, 'background', false)) {
        final (exe, args) = Platform.isWindows
            ? ('powershell', ['-NoProfile', '-Command', 'Start-Process -FilePath powershell -ArgumentList \'-NoProfile\',\'-Command\',${_psQuote(cmd)} -WindowStyle Hidden'])
            : ('bash', ['-c', 'setsid nohup bash -c ${_shQuote(cmd)} >/dev/null 2>&1 &']);
        await Process.start(exe, args,
            workingDirectory: cwd, mode: ProcessStartMode.detached, environment: AppPaths.buildSubprocessEnv());
        return 'Arka planda başlatıldı: $cmd';
      }

      final timeout = argInt(a, 'timeout_seconds', 120).clamp(5, 900);
      final (exe, args) = AppPaths.shellCommand(cmd);
      final res = await PtySandbox.runCommand(exe, args,
          workingDirectory: cwd, environment: AppPaths.buildSubprocessEnv(), timeout: Duration(seconds: timeout));
      final b = StringBuffer();
      if (res.timedOut) b.writeln('ZAMAN AŞIMI: Komut $timeout sn içinde bitmedi ve sonlandırıldı.');
      b.writeln('exit_code: ${res.exitCode}');
      if (res.stdout.trim().isNotEmpty) b.writeln('STDOUT:\n${res.stdout.trimRight()}');
      if (res.stderr.trim().isNotEmpty) b.writeln('STDERR:\n${res.stderr.trimRight()}');
      return b.toString();
    },
  );

  static String _shQuote(String s) => "'${s.replaceAll("'", r"'\''")}'";
  static String _psQuote(String s) => "'${s.replaceAll("'", "''")}'";

  // ---------------------------------------------------------------- dosya
  static const _richDocExts = {
    '.pdf', '.docx', '.doc', '.odt', '.rtf', '.xlsx', '.xls', '.ods', '.pptx', '.ppt', '.odp',
    '.dwg', '.dxf', '.mp3', '.wav', '.m4a', '.ogg', '.flac', '.aac', '.opus',
    '.png', '.jpg', '.jpeg', '.webp', '.bmp', '.tiff', '.tif',
  };

  static final readFile = AgentTool(
    name: 'read_file',
    description:
        'Bir metin/kod dosyasını satır numaralarıyla okur. PDF, Office, görsel, ses ve CAD dosyaları otomatik olarak read_document ile çözülür.',
    parameters: {
      'type': _obj,
      'properties': {
        'path': {'type': 'string', 'description': 'Dosya yolu (mutlak, ~ veya çalışma alanına göre)'},
        'offset': {'type': 'integer', 'description': 'Başlangıç satırı (1 tabanlı, varsayılan 1)'},
        'limit': {'type': 'integer', 'description': 'En fazla satır (varsayılan 400)'},
      },
      'required': ['path'],
    },
    risk: ToolRisk.read,
    handler: (a, ctx) async {
      final path = ctx.resolvePath(argStr(a, 'path'));
      final file = File(path);
      if (!await file.exists()) {
        if (await Directory(path).exists()) return 'Hata: "$path" bir klasör. list_directory kullan.';
        return 'Hata: Dosya bulunamadı: $path';
      }
      if (_richDocExts.contains(p.extension(path).toLowerCase())) {
        return FileService.extractContent(path);
      }
      final raf = await file.open();
      final header = await raf.read(1024);
      await raf.close();
      if (header.contains(0)) return 'Hata: İkili (binary) dosya; metin olarak okunamaz. read_document dene.';

      final start = argInt(a, 'offset', 1).clamp(1, 1 << 30);
      final limit = argInt(a, 'limit', 400).clamp(1, 4000);
      final lines = await file
          .openRead(0, 8 * 1024 * 1024)
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .skip(start - 1)
          .take(limit + 1)
          .toList();
      final shown = lines.take(limit).toList();
      final b = StringBuffer();
      for (var i = 0; i < shown.length; i++) {
        b.writeln('${(start + i).toString().padLeft(5)}\t${shown[i]}');
      }
      if (lines.length > limit) {
        b.writeln('...[devamı var: offset=${start + limit} ile okumayı sürdür]');
      }
      if (shown.isEmpty) b.writeln('(Bu aralıkta satır yok veya dosya boş.)');
      return b.toString();
    },
  );

  static final writeFile = AgentTool(
    name: 'write_to_file',
    description: 'Yeni dosya oluşturur veya mevcut dosyanın tamamını değiştirir. Küçük değişiklikler için replace_file_content kullan.',
    parameters: {
      'type': _obj,
      'properties': {
        'path': {'type': 'string', 'description': 'Dosya yolu'},
        'content': {'type': 'string', 'description': 'Dosyanın tam içeriği'},
      },
      'required': ['path', 'content'],
    },
    risk: ToolRisk.write,
    pathsOf: (a, ctx) => [ctx.resolvePath(argStr(a, 'path'))],
    summarize: (a) {
      final c = argStr(a, 'content');
      return 'Dosya yaz: ${argStr(a, 'path')} (${c.length} karakter)\n\n${truncate(c, 1500)}';
    },
    handler: (a, ctx) async {
      final path = ctx.resolvePath(argStr(a, 'path'));
      final file = File(path);
      await file.parent.create(recursive: true);
      String? cp;
      if (await file.exists()) cp = await CheckpointService.instance.createCheckpoint(path);
      await file.writeAsString(argStr(a, 'content'));
      final warn = await CodeValidator.validateFile(path);
      return 'Yazıldı: $path${cp != null ? ' (yedek: $cp)' : ''}${warn != null ? '\n\n$warn' : ''}';
    },
  );

  static final editFile = AgentTool(
    name: 'replace_file_content',
    description:
        'Dosyadaki bir metin bloğunu yenisiyle değiştirir. "target" dosyadaki metinle birebir (boşluklar dahil) eşleşmeli ve tekil olmalı; '
        'birden fazla yeri değiştirmek için replace_all=true ver.',
    parameters: {
      'type': _obj,
      'properties': {
        'path': {'type': 'string', 'description': 'Dosya yolu'},
        'target': {'type': 'string', 'description': 'Değiştirilecek mevcut metin'},
        'replacement': {'type': 'string', 'description': 'Yeni metin'},
        'replace_all': {'type': 'boolean', 'description': 'Tüm eşleşmeleri değiştir (varsayılan false)'},
      },
      'required': ['path', 'target', 'replacement'],
    },
    risk: ToolRisk.write,
    pathsOf: (a, ctx) => [ctx.resolvePath(argStr(a, 'path'))],
    summarize: (a) =>
        'Düzenle: ${argStr(a, 'path')}\n\n--- eski\n${truncate(argStr(a, 'target'), 700)}\n+++ yeni\n${truncate(argStr(a, 'replacement'), 700)}',
    handler: (a, ctx) async {
      final path = ctx.resolvePath(argStr(a, 'path'));
      final file = File(path);
      if (!await file.exists()) return 'Hata: Dosya bulunamadı: $path';
      final target = argStr(a, 'target');
      if (target.isEmpty) return 'Hata: "target" boş olamaz.';
      final text = await file.readAsString();
      final count = target.allMatches(text).length;
      final all = argBool(a, 'replace_all', false);
      if (count == 0) {
        return 'Hata: "target" dosyada bulunamadı. Önce read_file ile güncel içeriği oku; satır numarası sütununu target\'a dahil etme.';
      }
      if (count > 1 && !all) {
        return 'Hata: "target" $count yerde geçiyor. Daha fazla bağlam satırı ekleyerek tekilleştir ya da replace_all=true ver.';
      }
      await CheckpointService.instance.createCheckpoint(path);
      final replacement = argStr(a, 'replacement');
      final updated = all ? text.replaceAll(target, replacement) : text.replaceFirst(target, replacement);
      await file.writeAsString(updated);
      final warn = await CodeValidator.validateFile(path);
      return 'Düzenlendi: $path ($count değişiklik)${warn != null ? '\n\n$warn' : ''}';
    },
  );

  static final listDirectory = AgentTool(
    name: 'list_directory',
    description: 'Bir klasörün içeriğini (dosya boyutlarıyla) listeler.',
    parameters: {
      'type': _obj,
      'properties': {
        'path': {'type': 'string', 'description': 'Klasör yolu (varsayılan çalışma alanı)'},
        'show_hidden': {'type': 'boolean', 'description': 'Gizli dosyaları da göster'},
      },
    },
    risk: ToolRisk.read,
    handler: (a, ctx) async {
      final raw = argStr(a, 'path');
      final dir = Directory(raw.isEmpty ? ctx.workspaceDir : ctx.resolvePath(raw));
      if (!await dir.exists()) return 'Hata: Klasör bulunamadı: ${dir.path}';
      final hidden = argBool(a, 'show_hidden', false);
      final entries = await dir.list(followLinks: false).handleError((_) {}).toList();
      entries.sort((x, y) {
        final dx = x is Directory ? 0 : 1, dy = y is Directory ? 0 : 1;
        return dx != dy ? dx - dy : p.basename(x.path).toLowerCase().compareTo(p.basename(y.path).toLowerCase());
      });
      final b = StringBuffer('${dir.path}\n');
      var n = 0;
      for (final e in entries) {
        final name = p.basename(e.path);
        if (!hidden && name.startsWith('.')) continue;
        if (++n > 500) {
          b.writeln('...[500+ öğe, liste kısaltıldı]');
          break;
        }
        if (e is Directory) {
          b.writeln('  $name/');
        } else {
          int size = 0;
          try {
            size = e.statSync().size;
          } catch (_) {}
          b.writeln('  $name  (${_fmtSize(size)})');
        }
      }
      if (n == 0) b.writeln('  (boş)');
      return b.toString();
    },
  );

  static String _fmtSize(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
    return '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  static final grepSearch = AgentTool(
    name: 'grep_search',
    description: 'Dosya içeriklerinde regex/metin arar (ripgrep). Sonuçlar dosya:satır: içerik biçimindedir.',
    parameters: {
      'type': _obj,
      'properties': {
        'query': {'type': 'string', 'description': 'Aranacak metin veya regex'},
        'path': {'type': 'string', 'description': 'Aranacak klasör/dosya (varsayılan çalışma alanı)'},
        'case_insensitive': {'type': 'boolean', 'description': 'Büyük/küçük harf duyarsız (varsayılan true)'},
      },
      'required': ['query'],
    },
    risk: ToolRisk.read,
    handler: (a, ctx) {
      final raw = argStr(a, 'path');
      return GrepSearchService.search(
        query: argStr(a, 'query'),
        path: raw.isEmpty ? ctx.workspaceDir : ctx.resolvePath(raw),
        caseInsensitive: argBool(a, 'case_insensitive', true),
      );
    },
  );

  static final glob = AgentTool(
    name: 'glob',
    description: 'Dosya adı desenine göre dosya bulur (örn. **/*.dart, src/**/*.ts, *.pdf).',
    parameters: {
      'type': _obj,
      'properties': {
        'pattern': {'type': 'string', 'description': 'Glob deseni'},
        'path': {'type': 'string', 'description': 'Kök klasör (varsayılan çalışma alanı)'},
      },
      'required': ['pattern'],
    },
    risk: ToolRisk.read,
    handler: (a, ctx) {
      final raw = argStr(a, 'path');
      return GlobService.findFiles(
          pattern: argStr(a, 'pattern'), path: raw.isEmpty ? ctx.workspaceDir : ctx.resolvePath(raw));
    },
  );

  // ------------------------------------------------------ belge / medya
  static final readDocument = AgentTool(
    name: 'read_document',
    description:
        'PDF, Word (.docx/.doc/.odt), Excel (.xlsx/.xls/.ods/.csv), PowerPoint (.pptx/.odp), görsel (OCR), ses (Whisper deşifre) '
        've AutoCAD (.dwg/.dxf) dosyalarını metne çevirir.',
    parameters: {
      'type': _obj,
      'properties': {
        'path': {'type': 'string', 'description': 'Belge yolu'},
      },
      'required': ['path'],
    },
    risk: ToolRisk.read,
    handler: (a, ctx) => FileService.extractContent(ctx.resolvePath(argStr(a, 'path'))),
  );

  static final editDocument = AgentTool(
    name: 'edit_media_or_document',
    description:
        'Word, Excel/CSV, PowerPoint, PDF, AutoCAD (.dwg/.dxf), görsel ve ses dosyaları oluşturur/düzenler/dönüştürür. '
        'category + action + output_path ver; içerik alanları kategoriye göre değişir.',
    parameters: {
      'type': _obj,
      'properties': {
        'category': {
          'type': 'string',
          'enum': ['docx', 'xlsx', 'pptx', 'pdf', 'cad', 'image', 'audio'],
        },
        'action': {
          'type': 'string',
          'description': 'create, edit, replace_text, update_cells, merge, extract_pages, rotate, stamp_text, convert, trim'
        },
        'input_path': {'type': 'string', 'description': 'Düzenlenecek mevcut dosya'},
        'output_path': {'type': 'string', 'description': 'Hedef dosya yolu'},
        'title': {'type': 'string'},
        'paragraphs': {'type': 'array', 'items': {'type': 'string'}},
        'sections': {
          'type': 'array',
          'items': {'type': 'object'},
          'description': '[{"heading":"..","paragraphs":[..],"bullets":[..],"table":[[..]]}]'
        },
        'headers': {'type': 'array', 'items': {'type': 'string'}},
        'rows': {'type': 'array', 'items': {'type': 'array', 'items': {}}},
        'cells': {'type': 'object', 'description': '{"B2": 450, "C2": "=SUM(A2:B2)"}'},
        'slides': {'type': 'array', 'items': {'type': 'object'}, 'description': '[{"title":"..","bullets":[..]}]'},
        'replacements': {'type': 'object', 'description': '{"eski": "yeni"}'},
        'operations': {
          'type': 'array',
          'items': {'type': 'object'},
          'description': 'CAD: [{"op":"add_rect","origin":[0,0],"width":500,"height":400}, {"op":"add_line",...}, {"op":"add_text",...}]'
        },
        'input_paths': {'type': 'array', 'items': {'type': 'string'}, 'description': 'Birleştirme kaynakları'},
        'width': {'type': 'integer'},
        'height': {'type': 'integer'},
        'rotate': {'type': 'number'},
        'start_sec': {'type': 'number'},
        'end_sec': {'type': 'number'},
      },
      'required': ['category', 'output_path'],
    },
    risk: ToolRisk.write,
    pathsOf: (a, ctx) => [ctx.resolvePath(argStr(a, 'output_path'))],
    handler: (a, ctx) {
      final spec = Map<String, dynamic>.from(a);
      for (final k in ['input_path', 'output_path']) {
        if (argStr(a, k).isNotEmpty) spec[k] = ctx.resolvePath(argStr(a, k));
      }
      if (a['input_paths'] is List) {
        spec['input_paths'] = (a['input_paths'] as List).map((e) => ctx.resolvePath(e.toString())).toList();
      }
      return FileService.runFileStudio(spec);
    },
  );

  static const _executableExts = {
    '.sh', '.bash', '.desktop', '.appimage', '.run', '.bin', '.exe', '.bat', '.cmd', '.ps1', '.msi', '.app', '.command', '.py', '.jar'
  };

  static final openInSystem = AgentTool(
    name: 'open_file_in_system',
    description: 'Dosya, klasör veya web adresini kullanıcının varsayılan uygulamasıyla açar (PDF görüntüleyici, dosya yöneticisi, tarayıcı...).',
    parameters: {
      'type': _obj,
      'properties': {
        'path': {'type': 'string', 'description': 'Dosya/klasör yolu veya http(s) adresi'},
      },
      'required': ['path'],
    },
    risk: ToolRisk.read,
    // Çalıştırılabilir dosyaları açmak kod çalıştırmaktır → onaya tabi.
    riskOf: (a, ctx) {
      final raw = argStr(a, 'path');
      if (raw.startsWith('http://') || raw.startsWith('https://')) return ToolRisk.read;
      final path = ctx.resolvePath(raw);
      if (_executableExts.contains(p.extension(path).toLowerCase())) return ToolRisk.execute;
      if (!Platform.isWindows) {
        try {
          final st = File(path).statSync();
          if (st.type == FileSystemEntityType.file && (st.mode & 0x49) != 0) return ToolRisk.execute;
        } catch (_) {}
      }
      return ToolRisk.read;
    },
    commandOf: (a) => 'open ${argStr(a, 'path')}',
    handler: (a, ctx) async {
      final raw = argStr(a, 'path');
      final target = (raw.startsWith('http://') || raw.startsWith('https://')) ? raw : ctx.resolvePath(raw);
      if (!target.startsWith('http') && !File(target).existsSync() && !Directory(target).existsSync()) {
        return 'Hata: Bulunamadı: $target';
      }
      return FileService.openInSystem(target);
    },
  );

  static final takeScreenshot = AgentTool(
    name: 'take_screenshot',
    description:
        'Ekranın görüntüsünü alıp PNG olarak kaydeder ve yolunu döndürür. Ekranda ne olduğunu anlamak için ardından read_document ile (OCR) okuyabilirsin.',
    parameters: {'type': _obj, 'properties': {}},
    risk: ToolRisk.read,
    handler: (a, ctx) async {
      final dir = Directory(p.join(AppPaths.ferideDataDir, 'tmp'));
      await dir.create(recursive: true);
      final out = p.join(dir.path, 'screen_${DateTime.now().millisecondsSinceEpoch}.png');
      final candidates = <List<String>>[
        if (Platform.isMacOS) ['screencapture', '-x', out],
        if (Platform.isWindows)
          [
            'powershell',
            '-NoProfile',
            '-Command',
            'Add-Type -AssemblyName System.Windows.Forms,System.Drawing; '
                '\$b=[System.Windows.Forms.SystemInformation]::VirtualScreen; '
                '\$bmp=New-Object System.Drawing.Bitmap \$b.Width,\$b.Height; '
                '\$g=[System.Drawing.Graphics]::FromImage(\$bmp); '
                '\$g.CopyFromScreen(\$b.Left,\$b.Top,0,0,\$bmp.Size); '
                '\$bmp.Save(${_psQuote(out)})'
          ],
        if (Platform.isLinux) ...[
          ['spectacle', '-b', '-n', '-f', '-o', out],
          ['gnome-screenshot', '-f', out],
          ['grim', out],
          ['scrot', '-o', out],
          ['import', '-window', 'root', out],
        ],
      ];
      for (final c in candidates) {
        try {
          final r = await Process.run(c.first, c.sublist(1), environment: AppPaths.buildSubprocessEnv())
              .timeout(const Duration(seconds: 20));
          if (r.exitCode == 0 && File(out).existsSync() && File(out).lengthSync() > 0) {
            return 'Ekran görüntüsü kaydedildi: $out';
          }
        } catch (_) {}
      }
      return 'Hata: Ekran görüntüsü alınamadı (spectacle, gnome-screenshot, grim, scrot veya ImageMagick bulunamadı).';
    },
  );

  // ---------------------------------------------------------------- web
  static final searchWeb = AgentTool(
    name: 'search_web',
    description: 'İnternette arama yapar (DuckDuckGo) ve başlık, özet, URL listesi döndürür.',
    parameters: {
      'type': _obj,
      'properties': {
        'query': {'type': 'string', 'description': 'Arama sorgusu'},
        'max_results': {'type': 'integer', 'description': 'Sonuç sayısı (varsayılan 6)'},
      },
      'required': ['query'],
    },
    risk: ToolRisk.network,
    handler: (a, ctx) async {
      final res = await Process.run(
        AppPaths.resolvePython(),
        [AppPaths.scriptPath('search_engine.py'), argStr(a, 'query'), '${argInt(a, 'max_results', 6).clamp(1, 15)}'],
        environment: AppPaths.buildSubprocessEnv(),
      ).timeout(const Duration(seconds: 40));
      final out = res.stdout.toString().trim();
      try {
        final list = jsonDecode(out) as List;
        final b = StringBuffer();
        for (final r in list) {
          if (r is! Map) continue;
          if (r['error'] != null) return 'Hata: ${r['error']}';
          b.writeln('• ${r['title'] ?? ''}\n  ${r['href'] ?? r['url'] ?? ''}\n  ${r['body'] ?? ''}\n');
        }
        return b.isEmpty ? 'Sonuç bulunamadı.' : b.toString();
      } catch (_) {
        return out.isNotEmpty ? out : 'Hata: ${res.stderr}';
      }
    },
  );

  static final fetchUrl = AgentTool(
    name: 'read_url_content',
    description: 'Bir web sayfasını indirip okunabilir düz metne çevirir (yalnızca http/https).',
    parameters: {
      'type': _obj,
      'properties': {
        'url': {'type': 'string', 'description': 'http(s) adresi'},
      },
      'required': ['url'],
    },
    risk: ToolRisk.network,
    maxOutputChars: 14000,
    handler: (a, ctx) async {
      final uri = Uri.tryParse(argStr(a, 'url').trim());
      // Eskiden curl'e verilen file:// adresleri yerel dosyaları sızdırabiliyordu.
      if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
        return 'Hata: Yalnızca http/https adresleri desteklenir.';
      }
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 25),
        responseType: ResponseType.bytes,
        followRedirects: true,
        maxRedirects: 5,
        validateStatus: (_) => true,
        headers: {'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64) FerIDE/6.0'},
      ));
      final res = await dio.getUri<List<int>>(uri);
      final bytes = res.data ?? const <int>[];
      final body = utf8.decode(bytes.length > 5 * 1024 * 1024 ? bytes.sublist(0, 5 * 1024 * 1024) : bytes,
          allowMalformed: true);
      final type = res.headers.value('content-type') ?? '';
      final text = type.contains('html') || body.trimLeft().startsWith('<') ? htmlToText(body) : body;
      return 'HTTP ${res.statusCode} — $uri\n\n$text';
    },
  );

  /// Basit ama sağlam HTML → metin dönüştürücü.
  static String htmlToText(String html) {
    var s = html;
    s = s.replaceAll(RegExp(r'<(script|style|noscript|svg|head)[^>]*>.*?</\1>', dotAll: true, caseSensitive: false), ' ');
    s = s.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), ' ');
    s = s.replaceAll(RegExp(r'<(br|/p|/div|/li|/h[1-6]|/tr|/section|/article)[^>]*>', caseSensitive: false), '\n');
    s = s.replaceAll(RegExp(r'<li[^>]*>', caseSensitive: false), '\n• ');
    s = s.replaceAll(RegExp(r'<[^>]+>'), ' ');
    const entities = {'&nbsp;': ' ', '&amp;': '&', '&lt;': '<', '&gt;': '>', '&quot;': '"', '&#39;': "'", '&apos;': "'"};
    entities.forEach((k, v) => s = s.replaceAll(k, v));
    s = s.replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
      final c = int.tryParse(m.group(1)!);
      return c != null && c < 0x110000 ? String.fromCharCode(c) : ' ';
    });
    s = s.replaceAll(RegExp(r'[ \t\r\f]+'), ' ');
    s = s.replaceAll(RegExp(r'\n\s*\n\s*(\n\s*)+'), '\n\n');
    return s.trim();
  }

  // ------------------------------------------------- planlama & hafıza
  static final todoWrite = AgentTool(
    name: 'todo_write',
    description:
        'Çok adımlı işlerde görev listesini oluşturur/günceller. Her çağrıda listenin TAMAMINI gönder. Aynı anda yalnızca bir adım in_progress olsun.',
    parameters: {
      'type': _obj,
      'properties': {
        'todos': {
          'type': 'array',
          'items': {
            'type': 'object',
            'properties': {
              'id': {'type': 'string'},
              'content': {'type': 'string'},
              'status': {'type': 'string', 'enum': ['pending', 'in_progress', 'completed']},
            },
            'required': ['content', 'status'],
          },
        },
      },
      'required': ['todos'],
    },
    risk: ToolRisk.read,
    handler: (a, ctx) async {
      final raw = a['todos'];
      final list = <TodoItem>[];
      if (raw is List) {
        for (var i = 0; i < raw.length; i++) {
          final t = raw[i];
          if (t is Map) {
            final m = Map<String, dynamic>.from(t);
            m['id'] = (m['id']?.toString().isNotEmpty ?? false) ? m['id'] : 'step_${i + 1}';
            list.add(TodoItem.fromMap(m));
          }
        }
      }
      ctx.onTodos?.call(list);
      try {
        final dir = Directory(p.join(AppPaths.ferideDataDir, 'todos'));
        await dir.create(recursive: true);
        await File(p.join(dir.path, '${ctx.sessionId ?? 'default'}.json'))
            .writeAsString(jsonEncode(list.map((e) => e.toMap()).toList()));
      } catch (_) {}
      final done = list.where((t) => t.status == 'completed').length;
      return 'Görev listesi güncellendi ($done/${list.length} tamamlandı).';
    },
  );

  static final useSkill = AgentTool(
    name: 'use_skill',
    description: 'Kayıtlı bir becerinin (SKILL.md) tam talimatlarını yükler. Beceri adları sistem mesajındaki listede yer alır.',
    parameters: {
      'type': _obj,
      'properties': {
        'name': {'type': 'string', 'description': 'Beceri adı'},
      },
      'required': ['name'],
    },
    risk: ToolRisk.read,
    handler: (a, ctx) async {
      final name = argStr(a, 'name').trim();
      final skill = AegisService.instance.loadSkill(name);
      if (skill == null) {
        final names = AegisService.instance.listSkills().map((s) => s.name).join(', ');
        return 'Beceri bulunamadı: "$name". Mevcut beceriler: $names';
      }
      AegisService.instance.bumpSkillUse(skill.name);
      ctx.onMemoryChanged?.call();
      return 'BECERİ: ${skill.name}\n\n${skill.content}';
    },
  );

  static final saveSkill = AgentTool(
    name: 'save_skill',
    description: 'Başarıyla tamamlanmış, tekrar kullanılabilir bir iş akışını kalıcı beceri olarak kaydeder.',
    parameters: {
      'type': _obj,
      'properties': {
        'name': {'type': 'string', 'description': 'kisa-tireli-ad'},
        'description': {'type': 'string', 'description': 'Ne zaman kullanılacağı (tek cümle)'},
        'instructions': {'type': 'string', 'description': 'Adım adım talimatlar (Markdown)'},
      },
      'required': ['name', 'description', 'instructions'],
    },
    risk: ToolRisk.read,
    handler: (a, ctx) async {
      final name = argStr(a, 'name').trim();
      final content = argStr(a, 'instructions', argStr(a, 'content')).trim();
      if (name.isEmpty || content.isEmpty) return 'Hata: name ve instructions zorunlu.';
      AegisService.instance.saveSkill(name: name, description: argStr(a, 'description'), content: content);
      ctx.onMemoryChanged?.call();
      return 'Beceri kaydedildi: $name';
    },
  );

  static final recordExperience = AgentTool(
    name: 'record_experience',
    description: 'Önemli bir görevden çıkarılan dersi (neyin işe yarayıp yaramadığını) uzun süreli hafızaya yazar.',
    parameters: {
      'type': _obj,
      'properties': {
        'summary': {'type': 'string', 'description': '1-3 cümlelik özet'},
        'tools_used': {'type': 'string'},
        'success': {'type': 'boolean'},
      },
      'required': ['summary'],
    },
    risk: ToolRisk.read,
    handler: (a, ctx) async {
      AegisService.instance.recordExperience(
        summary: argStr(a, 'summary'),
        toolsUsed: argStr(a, 'tools_used'),
        success: argBool(a, 'success', true),
      );
      ctx.onMemoryChanged?.call();
      return 'Deneyim hafızaya yazıldı.';
    },
  );

  // ---------------------------------------------------------- alt ajanlar
  static final spawnAgent = AgentTool(
    name: 'spawn_agent',
    description:
        'Bağımsız bir alt görevi kendi bağlam penceresinde çalışan bir alt ajana verir ve sonucunu bekler. '
        'Geniş araştırma/inceleme gibi ana sohbeti şişirecek işler için kullan. Hedefi eksiksiz ve kendi başına anlaşılır yaz.',
    parameters: {
      'type': _obj,
      'properties': {
        'goal': {'type': 'string', 'description': 'Alt ajanın görevi ve beklenen çıktı'},
        'max_steps': {'type': 'integer', 'description': 'En fazla adım (varsayılan 25)'},
      },
      'required': ['goal'],
    },
    risk: ToolRisk.read,
    maxOutputChars: 12000,
    handler: (a, ctx) async {
      if (ctx.spawnSubagent == null) return 'Hata: Alt ajan bu bağlamda kullanılamaz.';
      final goal = argStr(a, 'goal').trim();
      if (goal.isEmpty) return 'Hata: goal boş.';
      return 'ALT AJAN SONUCU:\n${await ctx.spawnSubagent!(goal, argInt(a, 'max_steps', 25).clamp(1, 100))}';
    },
  );

  static final dispatchWorker = AgentTool(
    name: 'dispatch_worker',
    description: 'Uzun sürecek bir işi arka plandaki işçi ajana devreder; sonuç hazır olunca kullanıcıya bildirilir. Sohbete beklemeden devam et.',
    parameters: {
      'type': _obj,
      'properties': {
        'goal': {'type': 'string', 'description': 'İşin eksiksiz tanımı'},
      },
      'required': ['goal'],
    },
    risk: ToolRisk.read,
    handler: (a, ctx) async {
      if (ctx.dispatchWorker == null) return 'Hata: Arka plan işçisi bu bağlamda kullanılamaz.';
      final goal = argStr(a, 'goal').trim();
      if (goal.isEmpty) return 'Hata: goal boş.';
      ctx.dispatchWorker!(goal);
      return 'Görev arka plan işçisine devredildi; bitince sonuç bildirilecek.';
    },
  );

  // ------------------------------------------------------------------ MCP
  /// Etkin MCP sunucularının araçlarını `mcp__sunucu__arac` adıyla yerel
  /// araç olarak sunar; model şemaları doğrudan görür.
  static List<AgentTool> mcpTools(List<McpToolInfo> infos, {int timeoutSeconds = 60}) {
    return infos.map((info) {
      final schema = info.inputSchema.isEmpty ? {'type': _obj, 'properties': {}} : info.inputSchema;
      return AgentTool(
        name: info.qualifiedName,
        description: '[MCP: ${info.server}] ${info.description}',
        parameters: schema,
        // MCP sunucusunun ne yaptığını bilemeyiz; okuma ipucu yoksa onaya tabi.
        risk: info.readOnlyHint ? ToolRisk.read : ToolRisk.execute,
        summarize: (a) => 'MCP ${info.server} → ${info.name}\n${truncate(const JsonEncoder.withIndent('  ').convert(a), 1200)}',
        handler: (a, ctx) => McpService.instance.callToolByName(info.server, info.name, a, timeoutSeconds: timeoutSeconds),
      );
    }).toList();
  }
}
