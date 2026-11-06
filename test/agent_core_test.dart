import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:feride_v5_2/agent/agent_loop.dart';
import 'package:feride_v5_2/agent/llm_client.dart';
import 'package:feride_v5_2/agent/permissions.dart';
import 'package:feride_v5_2/agent/tools.dart';
import 'package:feride_v5_2/services/mcp_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Sırayla verilen yanıtları SSE olarak akıtan sahte OpenAI uyumlu sunucu.
Future<(HttpServer, List<Map<String, dynamic>>)> _fakeLlm(List<Map<String, dynamic>> deltas) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final requests = <Map<String, dynamic>>[];
  var i = 0;
  server.listen((req) async {
    final body = jsonDecode(await utf8.decoder.bind(req).join()) as Map<String, dynamic>;
    requests.add(body);
    final delta = deltas[i < deltas.length ? i : deltas.length - 1];
    i++;
    req.response.headers.contentType = ContentType('text', 'event-stream');
    req.response.write('data: ${jsonEncode({
          'choices': [
            {'delta': delta}
          ]
        })}\n\n');
    req.response.write('data: ${jsonEncode({
          'choices': [],
          'usage': {'prompt_tokens': 10, 'completion_tokens': 5}
        })}\n\n');
    req.response.write('data: [DONE]\n\n');
    await req.response.close();
  });
  return (server, requests);
}

void main() {
  late Directory ws;
  setUp(() => ws = Directory.systemTemp.createTempSync('feride_ws_'));
  tearDown(() => ws.deleteSync(recursive: true));

  group('PermissionPolicy', () {
    test('katastrofik komutlar her modda engellenir', () {
      final pol = PermissionPolicy(mode: PermissionMode.fullAuto, workspaceDir: ws.path);
      for (final c in ['rm -rf /', 'rm -rf ~', 'sudo mkfs.ext4 /dev/sda1', 'dd if=/dev/zero of=/dev/nvme0n1', ':(){ :|:& };:']) {
        expect(pol.evaluate(toolName: 'run_command', risk: ToolRisk.execute, command: c).decision,
            PermissionDecision.deny,
            reason: c);
      }
    });

    test('tam otonomda riskli komutlar yine sorulur, sıradan komutlar çalışır', () {
      final pol = PermissionPolicy(mode: PermissionMode.fullAuto, workspaceDir: ws.path);
      expect(pol.evaluate(toolName: 'run_command', risk: ToolRisk.execute, command: 'sudo apt install x').decision,
          PermissionDecision.ask);
      expect(pol.evaluate(toolName: 'run_command', risk: ToolRisk.execute, command: 'ls -la').decision,
          PermissionDecision.allow);
    });

    test('autoEdit: çalışma alanı içi yazma serbest, dışı ve komutlar sorulur', () {
      final pol = PermissionPolicy(mode: PermissionMode.autoEdit, workspaceDir: ws.path);
      expect(pol.evaluate(toolName: 'w', risk: ToolRisk.write, paths: [p.join(ws.path, 'a.txt')]).decision,
          PermissionDecision.allow);
      expect(pol.evaluate(toolName: 'w', risk: ToolRisk.write, paths: ['/tmp/../etc/passwd']).decision,
          PermissionDecision.ask);
      expect(pol.evaluate(toolName: 'run_command', risk: ToolRisk.execute, command: 'ls').decision,
          PermissionDecision.ask);
      expect(pol.evaluate(toolName: 'r', risk: ToolRisk.read).decision, PermissionDecision.allow);
    });
  });

  group('LlmClient ayrıştırma', () {
    test('Qwen/Hermes JSON biçimli <tool_call> bloğu', () {
      final r = LlmClient.parseInlineToolCalls(
          'Bakıyorum.<tool_call>{"name": "read_file", "arguments": {"path": "a.txt"}}</tool_call>');
      expect(r.calls.single.name, 'read_file');
      expect(r.calls.single.arguments, {'path': 'a.txt'});
      expect(r.remainingText, 'Bakıyorum.');
    });

    test('<function=..><parameter=..> biçimi, sayılar dönüştürülür', () {
      final r = LlmClient.parseInlineToolCalls(
          '<tool_call><function=read_file><parameter=path>x.dart</parameter><parameter=limit>20</parameter></function></tool_call>');
      expect(r.calls.single.arguments, {'path': 'x.dart', 'limit': 20});
    });

    test('görünür metin düşünce ve araç bloklarını gizler', () {
      expect(LlmClient.visibleText('<think>gizli</think>Merhaba<tool_call>{}'), 'Merhaba');
    });
  });

  group('ToolExecutor', () {
    test('string sayı argümanları çökertmez, dosya satır numaralı okunur', () async {
      File(p.join(ws.path, 'a.txt')).writeAsStringSync('bir\niki\nüç\n');
      final ex = ToolExecutor(BuiltinTools.core());
      final ctx = ToolContext(
          workspaceDir: ws.path, policy: PermissionPolicy(mode: PermissionMode.autoEdit, workspaceDir: ws.path));
      final out = await ex.execute('read_file', {'path': 'a.txt', 'offset': '2', 'limit': '1'}, ctx);
      expect(out, contains('2\tiki'));
      expect(out, isNot(contains('üç')));
    });

    test('onay dinleyicisi yoksa komut reddedilir (güvenli varsayılan)', () async {
      final ex = ToolExecutor(BuiltinTools.core());
      final ctx = ToolContext(
          workspaceDir: ws.path, policy: PermissionPolicy(mode: PermissionMode.ask, workspaceDir: ws.path));
      final out = await ex.execute('run_command', {'command': 'echo merhaba'}, ctx);
      expect(out, startsWith('REDDEDİLDİ'));
    });

    test('onay verilince komut çalışır ve çıktının tamamı alınır', () async {
      final sub = ApprovalBroker.instance.requests.listen((r) => r.resolve(true));
      addTearDown(sub.cancel);
      final ex = ToolExecutor(BuiltinTools.core());
      final ctx = ToolContext(
          workspaceDir: ws.path, policy: PermissionPolicy(mode: PermissionMode.ask, workspaceDir: ws.path));
      final out = await ex.execute('run_command', {'command': 'pwd; echo son-satir'}, ctx);
      expect(out, contains(ws.path));
      expect(out, contains('son-satir'));
    });

    test('url aracı file:// adreslerini reddeder', () async {
      final ex = ToolExecutor(BuiltinTools.core());
      final ctx = ToolContext(
          workspaceDir: ws.path, policy: PermissionPolicy(mode: PermissionMode.fullAuto, workspaceDir: ws.path));
      expect(await ex.execute('read_url_content', {'url': 'file:///etc/passwd'}, ctx), contains('Yalnızca http'));
    });

    test('replace_file_content tekil eşleşme ister', () async {
      final f = File(p.join(ws.path, 'k.txt'))..writeAsStringSync('a\na\nb\n');
      final ex = ToolExecutor(BuiltinTools.core());
      final ctx = ToolContext(
          workspaceDir: ws.path, policy: PermissionPolicy(mode: PermissionMode.autoEdit, workspaceDir: ws.path));
      expect(await ex.execute('replace_file_content', {'path': 'k.txt', 'target': 'a', 'replacement': 'x'}, ctx),
          contains('2 yerde'));
      await ex.execute('replace_file_content', {'path': 'k.txt', 'target': 'b', 'replacement': 'c'}, ctx);
      expect(f.readAsStringSync(), 'a\na\nc\n');
    });
  });

  group('AgentLoop (sahte model sunucusu ile uçtan uca)', () {
    test('araç çağırır, sonucu modele geri verir ve biter', () async {
      File(p.join(ws.path, 'not.txt')).writeAsStringSync('gizli kelime: elma');
      final (server, requests) = await _fakeLlm([
        {
          'tool_calls': [
            {
              'index': 0,
              'id': 'c1',
              'function': {'name': 'read_file', 'arguments': '{"path":"not.txt"}'}
            }
          ]
        },
        {'content': 'Kelime elma.'},
      ]);
      addTearDown(() => server.close(force: true));

      final loop = AgentLoop(
        llm: LlmClient(baseUrl: 'http://127.0.0.1:${server.port}/v1', model: 'test'),
        tools: ToolExecutor(BuiltinTools.core()),
        ctx: ToolContext(
            workspaceDir: ws.path, policy: PermissionPolicy(mode: PermissionMode.autoEdit, workspaceDir: ws.path)),
        cancelToken: CancelToken(),
      );
      final msgs = <Map<String, dynamic>>[
        {'role': 'system', 'content': 's'},
        {'role': 'user', 'content': 'not.txt içindeki kelime ne?'},
      ];
      final tools = <String>[];
      final res = await loop.run(msgs, callbacks: AgentLoopCallbacks(onToolStart: (n, _) => tools.add(n)));

      expect(res.ok, isTrue);
      expect(res.finalText, 'Kelime elma.');
      expect(tools, ['read_file']);
      // İkinci istekte araç sonucu doğru sırayla gönderilmiş olmalı.
      final second = requests[1]['messages'] as List;
      expect(second[2]['role'], 'assistant');
      expect(second[3]['role'], 'tool');
      expect(second[3]['tool_call_id'], 'c1');
      expect(second[3]['content'], contains('elma'));
    });

    test('ulaşılamayan sunucu anlaşılır hata döndürür', () async {
      final loop = AgentLoop(
        llm: LlmClient(baseUrl: 'http://127.0.0.1:9/v1', model: 'test'),
        tools: ToolExecutor(const []),
        ctx: ToolContext(
            workspaceDir: ws.path, policy: PermissionPolicy(mode: PermissionMode.ask, workspaceDir: ws.path)),
        cancelToken: CancelToken(),
      );
      final res = await loop.run([
        {'role': 'user', 'content': 'merhaba'}
      ]);
      expect(res.reason, AgentStopReason.error);
      expect(res.error, contains('ulaşılamadı'));
    });
  });

  group('MCP istemcisi', () {
    test('kalıcı stdio bağlantısı: tools/list + art arda iki tools/call', () async {
      final script = File(p.join(ws.path, 'srv.py'))
        ..writeAsStringSync(r'''
import sys, json
count = 0
for line in sys.stdin:
    m = json.loads(line)
    if 'id' not in m: continue
    if m['method'] == 'initialize':
        r = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}}, "serverInfo": {"name": "t", "version": "1"}}
    elif m['method'] == 'tools/list':
        r = {"tools": [{"name": "count", "description": "sayaç", "inputSchema": {"type": "object", "properties": {}}}]}
    else:
        count += 1
        r = {"content": [{"type": "text", "text": "sayi=%d" % count}]}
    sys.stderr.write("log\n" * 50)
    print(json.dumps({"jsonrpc": "2.0", "id": m['id'], "result": r}), flush=True)
''');
      final svc = McpService.instance;
      svc.loadConfig(p.join(ws.path, 'mcp.json'));
      final cfg = McpServerConfig(name: 'sayac', command: 'python3', args: [script.path]);
      svc.addOrUpdateServer(cfg);
      addTearDown(svc.shutdownAll);

      final tools = await svc.listTools(cfg);
      expect(tools.single.qualifiedName, 'mcp__sayac__count');
      expect(await svc.callToolByName('sayac', 'count', {}), 'sayi=1');
      // Aynı süreç: durum korunur (eskiden her çağrıda süreç yeniden açılıyordu).
      expect(await svc.callToolByName('sayac', 'count', {}), 'sayi=2');
    });
  });
}
