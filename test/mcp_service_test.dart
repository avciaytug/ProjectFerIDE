import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:feride_v5_2/services/mcp_service.dart';

void main() {
  group('McpService Tests', () {
    late Directory tempDir;
    late String testConfigPath;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('mcp_test_dir_');
      testConfigPath = '${tempDir.path}/mcp_config.json';
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('initializes with recommended presets when file does not exist', () {
      final service = McpService.instance;
      service.loadConfig(testConfigPath);

      expect(File(testConfigPath).existsSync(), isTrue);
      expect(service.servers.isNotEmpty, isTrue);
      final names = service.servers.map((s) => s.name).toList();
      expect(names, contains('filesystem'));
      expect(names, contains('fetch'));
      expect(names, contains('memory'));
    });

    test('can add, update, toggle and delete an MCP server', () {
      final service = McpService.instance;
      service.loadConfig(testConfigPath);

      final custom = McpServerConfig(
        name: 'custom_tool',
        description: 'Test tool',
        transport: 'stdio',
        command: 'echo',
        args: ['hello'],
        isEnabled: true,
      );

      service.addOrUpdateServer(custom);
      expect(service.servers.any((s) => s.name == 'custom_tool'), isTrue);

      service.toggleServer('custom_tool', false);
      final toggled = service.servers.firstWhere((s) => s.name == 'custom_tool');
      expect(toggled.isEnabled, isFalse);
      expect(toggled.status, 'Devre Dışı');

      service.deleteServer('custom_tool');
      expect(service.servers.any((s) => s.name == 'custom_tool'), isFalse);
    });

    test('exports to Claude Desktop compatible JSON', () {
      final config = McpServerConfig(
        name: 'git_mcp',
        transport: 'stdio',
        command: 'npx',
        args: ['-y', '@modelcontextprotocol/server-git'],
        env: {'DEBUG': 'true'},
        isEnabled: true,
      );

      final claudeJson = config.toClaudeFormat();
      expect(claudeJson['command'], 'npx');
      expect(claudeJson['args'], contains('-y'));
      expect(claudeJson['env'], containsPair('DEBUG', 'true'));
      expect(claudeJson['disabled'], isFalse);
    });

    // --- Gercek stdio JSON-RPC entegrasyon testi (python3 ile sahte sunucu) ---
    test('callTool performs real initialize + tools/call round-trip over stdio',
        () async {
      final python = await Process.run('which', ['python3']);
      if (python.exitCode != 0) {
        markTestSkipped('python3 bulunamadi');
        return;
      }
      final py = python.stdout.toString().trim();

      // Minimal MCP stdio sunucusu: initialize + tools/call (echo)
      final script = '''
import sys, json
def send(o):
    sys.stdout.write(json.dumps(o) + "\\n"); sys.stdout.flush()
for line in sys.stdin:
    line=line.strip()
    if not line: continue
    try: m=json.loads(line)
    except: continue
    if m.get("method")=="initialize":
        send({"jsonrpc":"2.0","id":m.get("id"),"result":{"protocolVersion":"2024-11-05","capabilities":{},"serverInfo":{"name":"fake","version":"1"}}})
    elif m.get("method")=="tools/call":
        args=m.get("params",{}).get("arguments",{})
        send({"jsonrpc":"2.0","id":m.get("id"),"result":{"content":[{"type":"text","text":"echo:" + str(args.get("msg",""))}],"isError":False}})
    elif m.get("method")=="notifications/initialized":
        pass
''';
      final scriptPath = '${tempDir.path}/fake_mcp.py';
      File(scriptPath).writeAsStringSync(script);

      final service = McpService.instance;
      final server = McpServerConfig(
        name: 'fake_echo',
        transport: 'stdio',
        command: py,
        args: [scriptPath],
        isEnabled: true,
      );

      final out = await service.callTool(server, 'echo', {'msg': 'merhaba'},
          timeoutSeconds: 15);
      expect(out, contains('echo:merhaba'));
    });

    test('callTool returns graceful error when command is missing', () async {
      final service = McpService.instance;
      final server = McpServerConfig(
        name: 'ghost',
        transport: 'stdio',
        command: 'definitely_not_a_real_cmd_xyz',
        isEnabled: true,
      );
      final out = await service.callTool(server, 'x', {}, timeoutSeconds: 8);
      expect(out, contains('MCP ghost'));
    });
  });
}
