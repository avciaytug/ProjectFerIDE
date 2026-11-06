import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'app_paths.dart';

/// MCP (Model Context Protocol) Sunucu Yapilandirma Modeli
class McpServerConfig {
  final String name;
  final String description;
  final String transport; // 'stdio', 'sse', 'http'
  final String command;
  final List<String> args;
  final Map<String, String> env;
  final String url;
  final bool isEnabled;
  final String status;
  final List<String> tools;

  McpServerConfig({
    required this.name,
    this.description = "",
    this.transport = "stdio",
    this.command = "",
    this.args = const [],
    this.env = const {},
    this.url = "",
    this.isEnabled = true,
    this.status = "Hazır",
    this.tools = const [],
  });

  McpServerConfig copyWith({
    String? name,
    String? description,
    String? transport,
    String? command,
    List<String>? args,
    Map<String, String>? env,
    String? url,
    bool? isEnabled,
    String? status,
    List<String>? tools,
  }) {
    return McpServerConfig(
      name: name ?? this.name,
      description: description ?? this.description,
      transport: transport ?? this.transport,
      command: command ?? this.command,
      args: args ?? this.args,
      env: env ?? this.env,
      url: url ?? this.url,
      isEnabled: isEnabled ?? this.isEnabled,
      status: status ?? this.status,
      tools: tools ?? this.tools,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      "name": name,
      "description": description,
      "transport": transport,
      "command": command,
      "args": args,
      "env": env,
      "url": url,
      "isEnabled": isEnabled,
      "status": status,
      "tools": tools,
    };
  }

  factory McpServerConfig.fromMap(Map<String, dynamic> map) {
    return McpServerConfig(
      name: map["name"] ?? "",
      description: map["description"] ?? "",
      transport: map["transport"] ?? "stdio",
      command: map["command"] ?? "",
      args: (map["args"] as List?)?.map((e) => e.toString()).toList() ?? [],
      env: (map["env"] as Map?)?.map((k, v) => MapEntry(k.toString(), v.toString())) ?? {},
      url: map["url"] ?? "",
      isEnabled: map["isEnabled"] ?? true,
      status: map["status"] ?? "Hazır",
      tools: (map["tools"] as List?)?.map((e) => e.toString()).toList() ?? [],
    );
  }

  /// Standart Claude Desktop / Antigravity mcp_config.json formati
  Map<String, dynamic> toClaudeFormat() {
    if (transport == "sse" || transport == "http") {
      return {
        "url": url,
        "transport": transport,
        if (description.isNotEmpty) "description": description,
        "disabled": !isEnabled,
      };
    } else {
      return {
        "command": command,
        "args": args,
        if (env.isNotEmpty) "env": env,
        if (description.isNotEmpty) "description": description,
        "disabled": !isEnabled,
      };
    }
  }

  factory McpServerConfig.fromClaudeEntry(String name, Map<String, dynamic> data) {
    final bool disabled = data["disabled"] == true;
    final String transport = data["transport"] ?? (data.containsKey("url") ? "sse" : "stdio");
    final home = AppPaths.homeDir;
    String expandArg(String raw) {
      if (raw == '~') return home;
      if (raw.startsWith('~/')) return '$home/${raw.substring(2)}';
      if (raw.contains(r'$HOME')) return raw.replaceAll(r'$HOME', home);
      return raw;
    }
    return McpServerConfig(
      name: name,
      description: data["description"]?.toString() ?? "",
      transport: transport,
      command: expandArg(data["command"]?.toString() ?? ""),
      args: (data["args"] as List?)?.map((e) => expandArg(e.toString())).toList() ?? [],
      env: (data["env"] as Map?)?.map((k, v) => MapEntry(k.toString(), expandArg(v.toString()))) ?? {},
      url: data["url"]?.toString() ?? "",
      isEnabled: !disabled,
      status: disabled ? "Devre Dışı" : "Hazır",
      tools: (data["tools"] as List?)?.map((e) => e.toString()).toList() ?? [],
    );
  }
}

/// FerIDE MCP Yonetim Servisi
class McpService {
  McpService._();
  static final McpService instance = McpService._();

  List<McpServerConfig> _servers = [];
  List<McpServerConfig> get servers => List.unmodifiable(_servers);

  String _configPath = "";
  String get configPath => _configPath;

  /// Konfigurasyon dosyasini yukler
  void loadConfig([String? customPath]) {
    _configPath = customPath ?? p.join(AppPaths.ferideDataDir, 'mcp_config.json');
    final file = File(_configPath);

    if (!file.existsSync()) {
      // Varsayilan hazir sunucularla ilk dosyayi olustur
      _servers = getRecommendedPresets();
      saveConfig(_configPath);
      return;
    }

    try {
      final content = file.readAsStringSync();
      final Map<String, dynamic> parsed = jsonDecode(content);
      final Map<String, dynamic> serversMap =
          parsed["mcpServers"] as Map<String, dynamic>? ?? {};

      _servers = serversMap.entries.map((entry) {
        final val = entry.value as Map<String, dynamic>;
        return McpServerConfig.fromClaudeEntry(entry.key, val);
      }).toList();
    } catch (e) {
      if (_servers.isEmpty) {
        _servers = getRecommendedPresets();
      }
    }
  }

  /// Konfigurasyonu diske kaydeder (Claude / Cursor uyumlu mcp_config.json)
  void saveConfig([String? customPath]) {
    final targetPath = customPath ?? _configPath;
    if (targetPath.isEmpty) return;

    final file = File(targetPath);
    if (!file.parent.existsSync()) {
      file.parent.createSync(recursive: true);
    }

    final Map<String, dynamic> serversMap = {};
    for (final s in _servers) {
      serversMap[s.name] = s.toClaudeFormat();
    }

    final fullConfig = {
      "mcpServers": serversMap,
      "updatedAt": DateTime.now().toIso8601String(),
      "ferideVersion": "5.3.7",
    };

    const encoder = JsonEncoder.withIndent("  ");
    file.writeAsStringSync(encoder.convert(fullConfig));
    _configPath = targetPath;
  }

  /// Yeni sunucu ekler veya mevcut olani gunceller
  void addOrUpdateServer(McpServerConfig server) {
    final idx = _servers.indexWhere((s) => s.name == server.name);
    if (idx >= 0) {
      _servers[idx] = server;
    } else {
      _servers.add(server);
    }
    unawaited(_closeSession(server.name));
    saveConfig();
  }

  /// Sunucuyu siler
  void deleteServer(String name) {
    _servers.removeWhere((s) => s.name == name);
    unawaited(_closeSession(name));
    saveConfig();
  }

  /// Sunucu durumunu acip kapatir
  void toggleServer(String name, bool enabled) {
    final idx = _servers.indexWhere((s) => s.name == name);
    if (idx >= 0) {
      _servers[idx] = _servers[idx].copyWith(
        isEnabled: enabled,
        status: enabled ? "Hazır" : "Devre Dışı",
      );
      if (!enabled) unawaited(_closeSession(name));
      saveConfig();
    }
  }

  // ---------------------------------------------------------------------------
  // MCP istemcisi: kalıcı bağlantılar, tools/list keşfi ve tools/call.
  // stdio (yerel süreç) ve Streamable HTTP taşıyıcıları desteklenir.
  // ---------------------------------------------------------------------------

  final Map<String, _McpSession> _sessions = {};
  final Map<String, List<McpToolInfo>> _toolCache = {};

  /// Sunucu bağlantısını gerçekten kurar ve araç listesini çeker.
  Future<Map<String, dynamic>> testServer(McpServerConfig server) async {
    final idx = _servers.indexWhere((s) => s.name == server.name);
    void setStatus(String st, [List<String>? tools]) {
      if (idx >= 0) _servers[idx] = _servers[idx].copyWith(status: st, tools: tools);
    }

    try {
      await _closeSession(server.name);
      final tools = await listTools(server, refresh: true);
      final names = tools.map((t) => t.name).toList();
      setStatus('Bağlandı (${names.length} araç)', names);
      return {"success": true, "message": "Bağlantı başarılı. Araçlar: ${names.join(', ')}"};
    } catch (e) {
      setStatus('Hata');
      return {"success": false, "message": "Bağlantı kurulamadı: $e"};
    }
  }

  /// Bir sunucunun araçlarını döndürür (önbellekli).
  Future<List<McpToolInfo>> listTools(McpServerConfig server, {bool refresh = false}) async {
    if (!refresh && _toolCache.containsKey(server.name)) return _toolCache[server.name]!;
    final session = await _session(server);
    final result = await session.request('tools/list', {}, timeout: const Duration(seconds: 20));
    final tools = <McpToolInfo>[];
    final list = result['tools'];
    if (list is List) {
      for (final t in list) {
        if (t is! Map || t['name'] == null) continue;
        final annotations = t['annotations'];
        tools.add(McpToolInfo(
          server: server.name,
          name: t['name'].toString(),
          description: (t['description'] ?? '').toString(),
          inputSchema: t['inputSchema'] is Map ? Map<String, dynamic>.from(t['inputSchema']) : const {},
          readOnlyHint: annotations is Map && annotations['readOnlyHint'] == true,
        ));
      }
    }
    _toolCache[server.name] = tools;
    return tools;
  }

  /// Verilen etkin sunucuların araçlarını paralel keşfeder; ulaşılamayanları atlar.
  Future<List<McpToolInfo>> discoverTools(Iterable<McpServerConfig> servers,
      {Duration timeout = const Duration(seconds: 25)}) async {
    final results = await Future.wait(servers.map((s) async {
      try {
        return await listTools(s).timeout(timeout);
      } catch (_) {
        return <McpToolInfo>[];
      }
    }));
    return results.expand((e) => e).toList();
  }

  /// Ada göre araç çağırır (ajan tarafından kullanılır).
  Future<String> callToolByName(String serverName, String toolName, Map<String, dynamic> arguments,
      {int timeoutSeconds = 60}) async {
    final server = _servers.where((s) => s.name == serverName).firstOrNull;
    if (server == null) return '[MCP] Sunucu bulunamadı: $serverName';
    return callTool(server, toolName, arguments, timeoutSeconds: timeoutSeconds);
  }

  Future<String> callTool(
    McpServerConfig server,
    String toolName,
    Map<String, dynamic> arguments, {
    int timeoutSeconds = 60,
  }) async {
    _McpSession session;
    try {
      session = await _session(server);
    } catch (e) {
      return "[MCP ${server.name}] Hata: Bağlantı kurulamadı (${server.command}${server.url}) - $e";
    }
    try {
      final result = await session.request('tools/call', {"name": toolName, "arguments": arguments},
          timeout: Duration(seconds: timeoutSeconds));
      return _formatToolResult(server.name, toolName, result);
    } on TimeoutException {
      return "[MCP ${server.name}::$toolName] Zaman aşımı ($timeoutSeconds sn).";
    } on McpRpcError catch (e) {
      return "[MCP ${server.name}::$toolName] JSON-RPC Hata: ${e.message}";
    } catch (e) {
      // Süreç çökmüş olabilir: bağlantıyı at, bir sonraki çağrıda yeniden kurulur.
      await _closeSession(server.name);
      return "[MCP ${server.name}::$toolName] Hata: $e";
    }
  }

  static String _formatToolResult(String server, String tool, Map<String, dynamic> result) {
    final content = result["content"];
    final sb = StringBuffer();
    if (content is List) {
      for (final part in content) {
        if (part is Map && part["type"] == "text") {
          sb.writeln(part["text"]);
        } else if (part is Map && part["type"] == "image") {
          sb.writeln('[görsel: ${part["mimeType"] ?? "image"}]');
        } else if (part is Map && part["type"] == "resource") {
          final r = part["resource"];
          sb.writeln(r is Map ? (r["text"] ?? r["uri"] ?? r).toString() : r.toString());
        } else {
          sb.writeln(part.toString());
        }
      }
    } else if (result["structuredContent"] != null) {
      sb.write(jsonEncode(result["structuredContent"]));
    } else {
      sb.write(content?.toString() ?? jsonEncode(result));
    }
    final isError = result["isError"] == true;
    return (isError ? "[MCP $server::$tool] ⚠️ " : "") + sb.toString().trim();
  }

  Future<_McpSession> _session(McpServerConfig server) async {
    final existing = _sessions[server.name];
    if (existing != null && existing.isAlive) return existing;
    if (existing != null) await _closeSession(server.name);

    final session = (server.transport == 'http' || server.transport == 'sse' || server.url.isNotEmpty)
        ? _McpHttpSession(server.url, server.env)
        : await _McpStdioSession.start(server);
    try {
      await session.request('initialize', {
        "protocolVersion": "2025-06-18",
        "capabilities": {},
        "clientInfo": {"name": "FerIDE", "version": "6.0.0"},
      }, timeout: const Duration(seconds: 30));
      session.notify('notifications/initialized');
    } catch (e) {
      await session.close();
      rethrow;
    }
    _sessions[server.name] = session;
    return session;
  }

  Future<void> _closeSession(String name) async {
    _toolCache.remove(name);
    final s = _sessions.remove(name);
    if (s != null) await s.close();
  }

  /// Tüm MCP süreçlerini kapatır (uygulama kapanırken).
  Future<void> shutdownAll() async {
    for (final name in _sessions.keys.toList()) {
      await _closeSession(name);
    }
  }

  /// node/npx/uvx gibi komutları PATH ve bilinen konumlardan bulur.
  static String? resolveBinary(String cmd) {
    if (p.isAbsolute(cmd)) return File(cmd).existsSync() ? cmd : null;
    final sep = Platform.isWindows ? ';' : ':';
    final pathRaw = Platform.environment['PATH'] ?? Platform.environment['Path'] ?? '';
    final dirs = <String>[
      ...pathRaw.split(sep).where((d) => d.isNotEmpty),
      if (Platform.isMacOS) '/opt/homebrew/bin',
      if (!Platform.isWindows) ...['/usr/local/bin', '/usr/bin', p.join(AppPaths.homeDir, '.local', 'bin')],
      if (Platform.isWindows) r'C:\Program Files\nodejs',
    ];
    final names = Platform.isWindows ? [cmd, '$cmd.cmd', '$cmd.exe', '$cmd.bat'] : [cmd];
    for (final d in dirs) {
      for (final n in names) {
        final f = File(p.join(d, n));
        if (f.existsSync()) return f.path;
      }
    }
    return null;
  }

  List<McpServerConfig> getRecommendedPresets() {
    final home = AppPaths.homeDir;
    return [
      McpServerConfig(
        name: "filesystem",
        description: "Yerel dosya okuma, yazma, dizin listeleme ve dosya arama MCP sunucusu.",
        transport: "stdio",
        command: "npx",
        args: ["-y", "@modelcontextprotocol/server-filesystem", home],
        isEnabled: true,
        status: "Hazır",
        tools: ["read_file", "write_file", "list_directory", "directory_tree", "move_file", "search_files"],
      ),
      McpServerConfig(
        name: "fetch",
        description: "Web sayfalarını hızlıca indirip sadeleştirilmiş markdown formatına çeviren web sunucusu.",
        transport: "stdio",
        command: "uvx",
        args: ["mcp-server-fetch"],
        isEnabled: true,
        status: "Hazır",
        tools: ["fetch_markdown", "fetch_html"],
      ),
      McpServerConfig(
        name: "memory",
        description: "Ajan için oturumlar arası kalıcı varlık ve ilişkisel bilgi grafiği hafıza sunucusu.",
        transport: "stdio",
        command: "npx",
        args: ["-y", "@modelcontextprotocol/server-memory"],
        isEnabled: true,
        status: "Hazır",
        tools: ["create_entities", "create_relations", "read_graph", "search_nodes", "open_nodes"],
      ),
      McpServerConfig(
        name: "sqlite",
        description: "Yerel SQLite veritabanı sorgulama, tablo şeması okuma ve SQL analizi.",
        transport: "stdio",
        command: "uvx",
        args: ["mcp-server-sqlite", "--db-path", "$home/.feride/feride_knowledge.db"],
        isEnabled: false,
        status: "Devre Dışı",
        tools: ["read_query", "write_query", "describe_table", "list_tables"],
      ),
      McpServerConfig(
        name: "github",
        description: "GitHub depoları, commitler, issue ve PR yönetimi için resmi MCP sunucusu.",
        transport: "stdio",
        command: "npx",
        args: ["-y", "@modelcontextprotocol/server-github"],
        env: {"GITHUB_PERSONAL_ACCESS_TOKEN": ""},
        isEnabled: false,
        status: "Devre Dışı",
        tools: ["create_or_update_file", "push_files", "create_issue", "fork_repository", "search_repositories"],
      ),
      McpServerConfig(
        name: "puppeteer",
        description: "Başsız (headless) Chromium tarayıcısı ile web sayfalarında gezinme ve ekran görüntüsü alma.",
        transport: "stdio",
        command: "npx",
        args: ["-y", "@modelcontextprotocol/server-puppeteer"],
        isEnabled: false,
        status: "Devre Dışı",
        tools: ["navigate", "screenshot", "click", "fill", "evaluate_script"],
      ),
    ];
  }
}


/// Bir MCP aracının tanımı.
class McpToolInfo {
  final String server;
  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;
  final bool readOnlyHint;

  const McpToolInfo({
    required this.server,
    required this.name,
    required this.description,
    required this.inputSchema,
    this.readOnlyHint = false,
  });

  /// Modelin göreceği araç adı. OpenAI uyumlu adlar [a-zA-Z0-9_-] ile sınırlı.
  String get qualifiedName {
    String clean(String s) => s.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    final full = 'mcp__${clean(server)}__${clean(name)}';
    return full.length <= 64 ? full : full.substring(0, 64);
  }
}

class McpRpcError implements Exception {
  final String message;
  McpRpcError(this.message);
  @override
  String toString() => message;
}

abstract class _McpSession {
  bool get isAlive;
  Future<Map<String, dynamic>> request(String method, Map<String, dynamic> params, {required Duration timeout});
  void notify(String method, [Map<String, dynamic>? params]);
  Future<void> close();

  static Map<String, dynamic> unwrap(Map<String, dynamic> msg) {
    if (msg['error'] != null) {
      final err = msg['error'];
      throw McpRpcError(err is Map ? (err['message'] ?? err).toString() : err.toString());
    }
    final r = msg['result'];
    return r is Map ? Map<String, dynamic>.from(r) : <String, dynamic>{};
  }
}

/// Yerel süreç üzerinden satır bazlı JSON-RPC.
class _McpStdioSession extends _McpSession {
  final Process _proc;
  final Map<int, Completer<Map<String, dynamic>>> _waiters = {};
  final List<String> _stderrTail = [];
  int _nextId = 1;
  bool _alive = true;

  _McpStdioSession._(this._proc) {
    _proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      try {
        final msg = jsonDecode(line);
        if (msg is! Map) return;
        final id = msg['id'];
        if (id is int && msg.containsKey('method') == false) {
          _waiters.remove(id)?.complete(Map<String, dynamic>.from(msg));
        }
      } catch (_) {}
    }, onDone: _onExit);
    // stderr okunmazsa boru tamponu dolar ve sunucu kilitlenir.
    _proc.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((l) {
      _stderrTail.add(l);
      if (_stderrTail.length > 20) _stderrTail.removeAt(0);
    });
    _proc.exitCode.then((_) => _onExit());
  }

  static Future<_McpStdioSession> start(McpServerConfig server) async {
    final cmd = server.command.trim();
    if (cmd.isEmpty) throw McpRpcError('Komut tanımlanmamış');
    String exe;
    List<String> args;
    final resolved = McpService.resolveBinary(cmd);
    if (resolved != null) {
      exe = resolved;
      args = server.args;
    } else if (cmd.contains(' ')) {
      final parts = cmd.split(RegExp(r'\s+'));
      exe = McpService.resolveBinary(parts.first) ?? parts.first;
      args = [...parts.skip(1), ...server.args];
    } else {
      throw McpRpcError('"$cmd" bulunamadı (PATH içinde yok). Node.js/uv kurulu mu?');
    }
    final proc = await Process.start(exe, args,
        environment: {
          ...AppPaths.buildSubprocessEnv(),
          ...server.env,
          "NO_COLOR": "1",
          "FORCE_COLOR": "0",
        },
        runInShell: Platform.isWindows && (exe.endsWith('.cmd') || exe.endsWith('.bat')));
    return _McpStdioSession._(proc);
  }

  void _onExit() {
    if (!_alive) return;
    _alive = false;
    final tail = _stderrTail.isEmpty ? '' : ' Son çıktı: ${_stderrTail.join(' | ')}';
    for (final w in _waiters.values) {
      if (!w.isCompleted) w.completeError(McpRpcError('MCP süreci kapandı.$tail'));
    }
    _waiters.clear();
  }

  @override
  bool get isAlive => _alive;

  @override
  Future<Map<String, dynamic>> request(String method, Map<String, dynamic> params, {required Duration timeout}) async {
    if (!_alive) throw McpRpcError('MCP süreci çalışmıyor');
    final id = _nextId++;
    final c = Completer<Map<String, dynamic>>();
    _waiters[id] = c;
    _proc.stdin.writeln(jsonEncode({"jsonrpc": "2.0", "id": id, "method": method, "params": params}));
    try {
      return _McpSession.unwrap(await c.future.timeout(timeout));
    } finally {
      _waiters.remove(id);
    }
  }

  @override
  void notify(String method, [Map<String, dynamic>? params]) {
    if (!_alive) return;
    _proc.stdin.writeln(jsonEncode({"jsonrpc": "2.0", "method": method, if (params != null) "params": params}));
  }

  @override
  Future<void> close() async {
    _alive = false;
    try {
      await _proc.stdin.close();
    } catch (_) {}
    _proc.kill(ProcessSignal.sigterm);
    try {
      await _proc.exitCode.timeout(const Duration(seconds: 2));
    } catch (_) {
      _proc.kill(ProcessSignal.sigkill);
    }
  }
}

/// MCP Streamable HTTP taşıyıcısı (JSON veya SSE yanıtları).
class _McpHttpSession extends _McpSession {
  final String url;
  final Map<String, String> headers;
  final Dio _dio = Dio();
  String? _sessionId;
  int _nextId = 1;
  bool _alive = true;

  _McpHttpSession(this.url, this.headers);

  @override
  bool get isAlive => _alive;

  Future<Map<String, dynamic>?> _post(Map<String, dynamic> body, Duration timeout) async {
    final res = await _dio.post<String>(
      url,
      data: jsonEncode(body),
      options: Options(
        responseType: ResponseType.plain,
        receiveTimeout: timeout,
        sendTimeout: const Duration(seconds: 20),
        validateStatus: (_) => true,
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json, text/event-stream',
          if (_sessionId != null) 'Mcp-Session-Id': _sessionId!,
          ...headers,
        },
      ),
    );
    _sessionId = res.headers.value('mcp-session-id') ?? _sessionId;
    if ((res.statusCode ?? 500) >= 400) {
      throw McpRpcError('HTTP ${res.statusCode}: ${res.data}');
    }
    final text = res.data ?? '';
    if (text.trim().isEmpty) return null;
    if ((res.headers.value('content-type') ?? '').contains('event-stream')) {
      for (final line in const LineSplitter().convert(text)) {
        if (!line.startsWith('data:')) continue;
        try {
          final m = jsonDecode(line.substring(5).trim());
          if (m is Map && m['id'] == body['id']) return Map<String, dynamic>.from(m);
        } catch (_) {}
      }
      return null;
    }
    final m = jsonDecode(text);
    return m is Map ? Map<String, dynamic>.from(m) : null;
  }

  @override
  Future<Map<String, dynamic>> request(String method, Map<String, dynamic> params, {required Duration timeout}) async {
    final id = _nextId++;
    final msg = await _post({"jsonrpc": "2.0", "id": id, "method": method, "params": params}, timeout).timeout(timeout);
    if (msg == null) throw McpRpcError('Boş yanıt');
    return _McpSession.unwrap(msg);
  }

  @override
  void notify(String method, [Map<String, dynamic>? params]) {
    _post({"jsonrpc": "2.0", "method": method, if (params != null) "params": params}, const Duration(seconds: 10))
        .catchError((_) => null);
  }

  @override
  Future<void> close() async {
    _alive = false;
    _dio.close(force: true);
  }
}
