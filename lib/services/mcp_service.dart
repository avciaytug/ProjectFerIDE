import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'app_paths.dart';

/// Bir MCP stdio surecinin stdout akisini TEK seferde dinler ve gelen
/// JSON-RPC yanitlarini `id`'lerine gore ilgili bekleyiciye (completer)
/// yonlendirir.
///
/// Dart'ta Process.stdout single-subscription akistir; bir kez `listen`
/// edilen akisi `StreamSubscription.cancel()` bile olsa "dinlendi" olarak
/// isaretler. MCP'de initialize el sikismasi stdout'u dinler, ardindan
/// tools/call yeniden dinlemek ister -> "Stream has already been listened
/// to". Bu dispatcher akisi tek dinleyiciyle acik tutarak her yaniti
/// dogru id'ye teslim eder.
class _McpStdioDispatcher {
  final Process _proc;
  final Map<Object, Completer<Map<String, dynamic>>> _waiters = {};
  StreamSubscription<String>? _sub;

  _McpStdioDispatcher(this._proc) {
    _sub = _proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      try {
        final decoded = jsonDecode(line) as Map<String, dynamic>;
        final id = decoded["id"];
        if (id == null) return; // bildirim (notification)
        final waiter = _waiters.remove(id);
        if (waiter != null && !waiter.isCompleted) {
          waiter.complete(decoded);
        }
      } catch (_) {}
    });
  }

  /// Verilen `id`'li JSON-RPC yanitini bekler.
  Future<Map<String, dynamic>> next(int id) {
    final completer = Completer<Map<String, dynamic>>();
    _waiters[id] = completer;
    return completer.future;
  }

  Future<void> dispose() async {
    try {
      await _sub?.cancel();
    } catch (_) {}
    _waiters.clear();
  }
}

/// Kurulmus bir MCP stdio baglantisinin sureci ve stdout dispatcher'i.
class _McpConnection {
  final Process proc;
  final _McpStdioDispatcher dispatcher;
  _McpConnection(this.proc, this.dispatcher);
}

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
      "ferideVersion": "5.3.5",
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
    saveConfig();
  }

  /// Sunucuyu siler
  void deleteServer(String name) {
    _servers.removeWhere((s) => s.name == name);
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
      saveConfig();
    }
  }

  /// Sunucu baglantisini test eder
  Future<Map<String, dynamic>> testServer(McpServerConfig server) async {
    final idx = _servers.indexWhere((s) => s.name == server.name);
    if (server.transport == "sse" || server.transport == "http") {
      try {
        final dio = Dio();
        final res = await dio.get(
          server.url,
          options: Options(
            validateStatus: (status) => true,
            sendTimeout: const Duration(seconds: 4),
            receiveTimeout: const Duration(seconds: 4),
          ),
        );
        final success = res.statusCode != null && res.statusCode! < 500;
        final newStatus = success ? "Bağlantı Başarılı (${res.statusCode})" : "Hata (${res.statusCode})";
        if (idx >= 0) {
          _servers[idx] = _servers[idx].copyWith(status: newStatus);
        }
        return {"success": success, "message": "SSE/HTTP Yanıtı: ${res.statusCode}"};
      } catch (e) {
        if (idx >= 0) {
          _servers[idx] = _servers[idx].copyWith(status: "Erişilemedi");
        }
        return {"success": false, "message": "Bağlantı kurulamadı: $e"};
      }
    } else {
      try {
        final cmd = server.command.trim();
        if (cmd.isEmpty) {
          return {"success": false, "message": "Komut tanımlanmamış"};
        }
        final check = await Process.run("which", [cmd]);
        if (check.exitCode == 0) {
          final binaryPath = check.stdout.toString().trim();
          final newStatus = "Bağlantı Hazır ($cmd)";
          if (idx >= 0) {
            _servers[idx] = _servers[idx].copyWith(status: newStatus);
          }
          return {
            "success": true,
            "message": "Komut doğrulandı: $binaryPath",
          };
        } else {
          final newStatus = "Komut Bulunamadı ($cmd)";
          if (idx >= 0) {
            _servers[idx] = _servers[idx].copyWith(status: newStatus);
          }
          return {
            "success": false,
            "message": "$cmd sistem PATH içinde bulunamadı.",
          };
        }
      } catch (e) {
        if (idx >= 0) {
          _servers[idx] = _servers[idx].copyWith(status: "Hata");
        }
        return {"success": false, "message": "Hata: $e"};
      }
    }
  }

  /// Populer ve hazir MCP sablonlari
  // ---------------------------------------------------------------------------
  // Gercek MCP stdio JSON-RPC istemcisi (initialize + tools/call)
  // ---------------------------------------------------------------------------

  /// node/npx/npm gibi komutlari sisteme bagimsiz olarak bulur.
  /// Bu makinede node/npx PATH'te olmayabilir; bilinen yerlerden cozulur.
  static String? _resolveBinary(String cmd) {
    final sep = Platform.isWindows ? ';' : ':';
    final pathRaw = Platform.environment['PATH'] ?? Platform.environment['Path'] ?? '';
    final pathDirs = pathRaw.split(sep).where((dir) => dir.isNotEmpty);
    final candidates = Platform.isWindows
        ? <String>[cmd, '$cmd.cmd', '$cmd.exe']
        : <String>[cmd];
    for (final d in pathDirs) {
      for (final c in candidates) {
        final candidate = File(p.join(d, c));
        if (candidate.existsSync() && candidate.statSync().type == FileSystemEntityType.file) {
          return candidate.path;
        }
      }
    }
    final fallbacks = <String>[
      if (Platform.isMacOS) '/opt/homebrew/bin',
      if (!Platform.isWindows) ...[
        '/usr/local/bin',
        '/usr/bin',
      ],
      if (Platform.isWindows) r'C:\Program Files\nodejs',
    ];
    for (final d in fallbacks) {
      for (final c in candidates) {
        final candidate = File(p.join(d, c));
        if (candidate.existsSync() && candidate.statSync().type == FileSystemEntityType.file) {
          return candidate.path;
        }
      }
    }
    return null;
  }

  /// Verilen sunucu icin MCP stdio baglantisi kurar (initialize el sikismasi).
  /// Basarida (surec + stdout dispatcher) doner, hatada null.
  Future<_McpConnection?> _connect(McpServerConfig server) async {
    final cmd = server.command.trim();
    if (cmd.isEmpty) return null;

    final resolved = _resolveBinary(cmd);
    final Process proc;
    if (resolved != null) {
      proc = await Process.start(resolved, server.args,
          environment: {
            ...Platform.environment,
            ...server.env,
            // npx/uvx icin gereksiz sorulari kapat
            "NO_COLOR": "1",
            "FORCE_COLOR": "0",
          },
          mode: ProcessStartMode.normal);
    } else {
      // Cok parcali komutlar icin (ornek: "python3 -m ...") degiskeni ayirtla
      final parts = cmd.split(' ');
      proc = await Process.start(
          parts.first, [...parts.skip(1), ...server.args],
          environment: {...Platform.environment, ...server.env},
          mode: ProcessStartMode.normal);
    }

    // stdout'u TEK dinleyiciyle acik tut; yanitlar id'ye gore yonlendirilir.
    final dispatcher = _McpStdioDispatcher(proc);

    final initRequest = jsonEncode({
      "jsonrpc": "2.0",
      "id": 1,
      "method": "initialize",
      "params": {
        "protocolVersion": "2024-11-05",
        "capabilities": {},
        "clientInfo": {"name": "FerIDE", "version": "5.3.0"},
      },
    });
    proc.stdin.write('$initRequest\n');
    await proc.stdin.flush();

    // initialize yanitini bekle (8 sn)
    try {
      await dispatcher.next(1).timeout(const Duration(seconds: 8));
    } catch (_) {
      await dispatcher.dispose();
      proc.kill(ProcessSignal.sigterm);
      return null;
    }

    // initialized bildirimini gonder
    proc.stdin.write('${jsonEncode({"jsonrpc": "2.0", "method": "notifications/initialized"})}\n');
    await proc.stdin.flush();
    return _McpConnection(proc, dispatcher);
  }

  /// Gercek MCP araci cagrisi: sunucuyu baslatir, tools/call gonderir,
  /// sonucu metin olarak dondurur ve sureci kapatir.
  Future<String> callTool(
    McpServerConfig server,
    String toolName,
    Map<String, dynamic> arguments, {
    int timeoutSeconds = 60,
  }) async {
    _McpConnection? conn;
    try {
      conn = await _connect(server);
    } catch (e) {
      return "[MCP ${server.name}] Hata: Surec baslatilamadi (komut bulunamadi: ${server.command}) - $e";
    }
    if (conn == null) {
      return "[MCP ${server.name}] Hata: initialize el sikismasi kurulamadi (timeout veya komut bulunamadi: ${server.command})";
    }

    try {
      const callId = 2;
      final request = jsonEncode({
        "jsonrpc": "2.0",
        "id": callId,
        "method": "tools/call",
        "params": {"name": toolName, "arguments": arguments},
      });
      conn.proc.stdin.write('$request\n');
      await conn.proc.stdin.flush();

      try {
        final decoded = await conn.dispatcher
            .next(callId)
            .timeout(Duration(seconds: timeoutSeconds));
        final result = decoded["result"];
        if (decoded.containsKey("error")) {
          final err = decoded["error"];
          return "[MCP ${server.name}::$toolName] JSON-RPC Hata: ${err is Map ? err['message'] ?? err : err}";
        } else if (result is Map && result.containsKey("content")) {
          final content = result["content"];
          final sb = StringBuffer();
          if (content is List) {
            for (final part in content) {
              if (part is Map && part.containsKey("text")) {
                sb.write(part["text"]);
                sb.write("\n");
              } else {
                sb.write(part.toString());
                sb.write("\n");
              }
            }
          } else {
            sb.write(content?.toString() ?? "");
          }
          final isError = (result["isError"] ?? false).toString();
          return (isError == "true" ? "[MCP ${server.name}::$toolName] ⚠️ " : "") +
              sb.toString().trim();
        } else {
          return "[MCP ${server.name}::$toolName] Sonuc: ${result ?? 'boş'}";
        }
      } on TimeoutException {
        return "[MCP ${server.name}::$toolName] Zaman asimi ($timeoutSeconds sn).";
      }
    } finally {
      await conn.dispatcher.dispose();
      try {
        conn.proc.kill(ProcessSignal.sigterm);
      } catch (_) {}
    }
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
