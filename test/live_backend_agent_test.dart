// Gerçek büyük model + ajan uçtan uca testi. Ağır olduğu için yalnızca açıkça
// istenince ve geçici bir HOME ile çalışır (gerçek ~/.feride verisine dokunmaz):
//   HOME=$(mktemp -d) FERIDE_LIVE=1 FERIDE_LLAMA=... FERIDE_MODEL=... FERIDE_VENV=... \
//   FERIDE_SKILLS_SRC=... flutter test test/live_backend_agent_test.dart
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:feride_v5_2/aegis/aegis_service.dart';
import 'package:feride_v5_2/aegis/subagent_engine.dart';
import 'package:feride_v5_2/agent/agent_loop.dart';
import 'package:feride_v5_2/agent/llm_client.dart';
import 'package:feride_v5_2/agent/permissions.dart';
import 'package:feride_v5_2/agent/tools.dart';
import 'package:feride_v5_2/features/chat/state.dart';
import 'package:feride_v5_2/services/agent_engine.dart';
import 'package:feride_v5_2/services/backend_manager.dart';
import 'package:feride_v5_2/services/hardware_probe.dart';
import 'package:feride_v5_2/services/mcp_service.dart';
import 'package:feride_v5_2/services/model_launch_planner.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/open.dart';

final env = Platform.environment;
final live = env['FERIDE_LIVE'] == '1' && (env['HOME'] ?? '').startsWith('/tmp');
final llama = env['FERIDE_LLAMA'] ?? '';
final model = env['FERIDE_MODEL'] ?? '';
const port = 8090;
final api = 'http://127.0.0.1:$port/v1';

void log(String s) => stdout.writeln('CANLI │ $s');
String gib(int b) => (b / (1 << 30)).toStringAsFixed(1);

Future<int> gpuFree() async {
  final h = await HardwareProbe.probe(llamaServer: llama, env: BackendManager.libraryEnvFor(p.dirname(llama)));
  return h.primaryGpu?.freeBytes ?? -1;
}

Future<List<String>> kernelGpuErrors(DateTime since) async {
  final s = '${since.year}-${since.month.toString().padLeft(2, '0')}-${since.day.toString().padLeft(2, '0')} '
      '${since.hour.toString().padLeft(2, '0')}:${since.minute.toString().padLeft(2, '0')}:${since.second.toString().padLeft(2, '0')}';
  final r = await Process.run('journalctl', ['-k', '--since', s, '--no-pager']);
  return r.stdout
      .toString()
      .split('\n')
      .where((l) => RegExp(r'amdgpu.*(ERROR|ENOSPC|reset|timeout)|Out of memory|Killed process').hasMatch(l))
      .toList();
}

Future<({String text, double tps})> chat(String prompt) async {
  final res = await Dio().post('$api/chat/completions',
      data: {
        'messages': [
          {'role': 'user', 'content': prompt}
        ],
        'max_tokens': 120,
        'chat_template_kwargs': {'enable_thinking': false},
      },
      options: Options(receiveTimeout: const Duration(minutes: 5)));
  final t = res.data['timings'];
  return (
    text: (res.data['choices'][0]['message']['content'] ?? '').toString().trim(),
    tps: (t?['predicted_per_second'] as num?)?.toDouble() ?? 0,
  );
}

Future<void> loadAndMeasure(ProviderContainer c, ComputeMode mode) async {
  final bm = c.read(backendManagerProvider);
  final since = DateTime.now();
  final sw = Stopwatch()..start();
  await bm.startBackend(BackendConfig(type: BackendType.llamaCpp, executablePath: llama, modelPathOrName: model, port: port, computeMode: mode));
  final plan = c.read(lastLaunchPlanProvider)!;
  log('[${mode.name}] Plan: ${plan.summary}');
  for (final w in plan.warnings) {
    log('[${mode.name}] Uyarı: ${w.split('.').first}.');
  }
  expect(c.read(isBackendRunningProvider), isTrue, reason: c.read(lastBackendStatusMessageProvider));
  log('[${mode.name}] Hazır: ${sw.elapsed.inSeconds} sn');
  await Future.delayed(const Duration(seconds: 3));
  final free = await gpuFree();
  log('[${mode.name}] GPU\'da kullanılan: ${gib(c.read(lastGpuUsageBytesProvider) ?? 0)} GiB • boş kalan: ${gib(free)} GiB');
  final r = await chat('Merhaba! Tek cümleyle kendini tanıt.');
  log('[${mode.name}] Yanıt (${r.tps.toStringAsFixed(1)} token/sn): ${r.text.replaceAll('\n', ' ')}');
  expect(r.text, isNotEmpty);
  final errs = await kernelGpuErrors(since);
  log('[${mode.name}] Çekirdekte yeni GPU/bellek hatası: ${errs.length}');
  expect(errs, isEmpty, reason: errs.join('\n'));
  expect(free, greaterThan(4 << 30), reason: 'Masaüstü için GPU belleğinde pay kalmalı');
}

Future<AgentLoopResult> agent(String prompt, ToolExecutor tools, ToolContext ctx, String system, List<String> used) {
  final loop = AgentLoop(
    llm: LlmClient(baseUrl: api, model: 'glm'),
    tools: tools,
    ctx: ctx,
    cancelToken: CancelToken(),
    maxSteps: 10,
    maxContextTokens: 32768,
  );
  return loop.run([
    {'role': 'system', 'content': system},
    {'role': 'user', 'content': prompt},
  ], callbacks: AgentLoopCallbacks(onToolStart: (n, a) {
    used.add(n);
    log('   araç → $n ${jsonEncode(a).substring(0, jsonEncode(a).length.clamp(0, 140))}');
  }));
}

void main() {
  if (Platform.isLinux) open.overrideFor(OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
  final c = ProviderContainer();
  tearDownAll(() async {
    await c.read(backendManagerProvider).stopBackend(port: port);
    await McpService.instance.shutdownAll();
    c.dispose();
  });

  test('GPU modu: sığmayan model başlatılmaz (çökme yerine açıklama)', () async {
    final bm = c.read(backendManagerProvider);
    await bm.startBackend(BackendConfig(type: BackendType.llamaCpp, executablePath: llama, modelPathOrName: model, port: port, computeMode: ComputeMode.gpu));
    expect(c.read(isBackendRunningProvider), isFalse);
    log('[gpu] Engel: ${c.read(lastBackendStatusMessageProvider)?.split('\n').first}');
    expect(c.read(lastLaunchPlanProvider)!.canStart, isFalse);
  }, skip: !live, timeout: const Timeout(Duration(minutes: 3)));

  test('Otomatik mod: GLM-4.5-Air yüklenir, masaüstüne pay kalır, yanıt verir', () => loadAndMeasure(c, ComputeMode.auto),
      skip: !live, timeout: const Timeout(Duration(minutes: 12)));

  test('Ajan uçtan uca: skill + MCP sqlite + MCP fetch + alt ajan', () async {
    final home = env['HOME']!;
    final ws = Directory(p.join(home, 'calisma'))..createSync(recursive: true);
    for (final n in ['a.txt', 'b.txt', 'c.txt']) {
      File(p.join(ws.path, n)).writeAsStringSync('içerik $n');
    }
    // Skill'ler (kopya)
    final skills = Directory(p.join(home, '.feride', 'skills'))..createSync(recursive: true);
    await Process.run('cp', ['-r', '${env['FERIDE_SKILLS_SRC']}/.', skills.path]);
    AegisService.instance.syncFromDisk();
    // MCP (gerçek sunucular, FerIDE ortamındaki uvx ile)
    final uvx = p.join(env['FERIDE_VENV']!, 'bin', 'uvx');
    final cfg = File(p.join(home, 'mcp.json'))
      ..writeAsStringSync(jsonEncode({
        'mcpServers': {
          'fetch': {'command': uvx, 'args': ['mcp-server-fetch']},
          // Eski (arşivlenmiş) yapılandırma: FerIDE bunu yerleşik sunucuya taşımalı.
          'sqlite': {'command': uvx, 'args': ['mcp-server-sqlite', '--db-path', p.join(home, 'bilgi.db')]},
        }
      }));
    McpService.instance.loadConfig(cfg.path);
    final infos = await McpService.instance.discoverTools(McpService.instance.servers, timeout: const Duration(seconds: 90));
    log('MCP araçları: ${infos.map((i) => i.qualifiedName).join(', ')}');
    expect(infos.map((i) => i.server).toSet(), containsAll(['fetch', 'sqlite']));

    final tools = ToolExecutor([...BuiltinTools.core(), BuiltinTools.spawnAgent, ...BuiltinTools.mcpTools(infos)]);
    final ctx = ToolContext(
      workspaceDir: ws.path,
      policy: PermissionPolicy(mode: PermissionMode.fullAuto, workspaceDir: ws.path),
      spawnSubagent: (goal, steps) => SubagentEngine(
        apiUrl: api,
        model: 'glm',
        workspaceDir: ws.path,
        permissionMode: PermissionMode.fullAuto,
        maxSteps: steps,
      ).run(goal, onEvent: (e) => log('   alt ajan │ ${e.type}: ${e.message.split('\n').first}')),
    );
    final system = AgentEngine.buildSystemPrompt(
      isLiveSession: false,
      thinkingMode: false,
      thinkingLevel: ThinkingLevel.med,
      workingDirectory: ws.path,
      extraContext: '\n\n# BECERİLER\nBir beceri işe uygunsa önce use_skill ile tam talimatını yükle.\n${AegisService.instance.getSkillIndex()}'
          '\n\nBağlı MCP sunucuları: fetch, sqlite (araç adları mcp__sunucu__araç).',
    );

    Future<void> run(String name, String prompt, bool Function(List<String> used, String answer) ok) async {
      final used = <String>[];
      final sw = Stopwatch()..start();
      final r = await agent(prompt, tools, ctx, system, used);
      log('[$name] ${sw.elapsed.inSeconds} sn, ${r.steps} adım, sonuç: ${r.finalText.replaceAll('\n', ' ').substring(0, r.finalText.length.clamp(0, 220))}');
      expect(r.ok, isTrue, reason: r.error);
      expect(ok(used, r.finalText), isTrue, reason: 'araçlar: $used\nyanıt: ${r.finalText}');
    }

    await run('skill', 'Bir yazılım hatasını sistematik biçimde ayıklamak istiyorum. Önce bu iş için uygun beceriyi use_skill ile yükle, sonra becerinin önerdiği ilk aşamanın adını tek cümleyle söyle.',
        (u, a) => u.contains('use_skill'));
    await run('mcp-sqlite', 'MCP sqlite araçlarını kullanarak notlar adında (id INTEGER, metin TEXT) bir tablo oluştur, içine (1, \'FerIDE çalışıyor\') satırını ekle, sonra tabloyu sorgulayıp sonucu söyle.',
        (u, a) => u.any((t) => t.startsWith('mcp__sqlite__')) && a.contains('FerIDE çalışıyor'));
    await run('mcp-fetch', 'MCP fetch aracıyla https://example.com adresini getir ve sayfanın başlığını söyle.',
        (u, a) => u.any((t) => t.startsWith('mcp__fetch__')) && a.toLowerCase().contains('example domain'));
    await run('alt-ajan', 'spawn_agent aracıyla bir alt ajan başlat: çalışma alanındaki .txt dosyalarını saysın ve adlarını bildirsin. Sonra sonucu bana söyle.',
        (u, a) => u.contains('spawn_agent') && a.contains('3'));
  }, skip: !live, timeout: const Timeout(Duration(minutes: 20)));

  test('CPU offload modu: uzmanlar RAM\'de, yanıt verir', () => loadAndMeasure(c, ComputeMode.hybrid),
      skip: !live, timeout: const Timeout(Duration(minutes: 12)));
}
