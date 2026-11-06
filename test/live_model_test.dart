// Gerçek yerel model ile uçtan uca deneme. Yalnızca FERIDE_LIVE=1 iken çalışır:
//   FERIDE_LIVE=1 flutter test test/live_model_test.dart
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:feride_v5_2/agent/agent_loop.dart';
import 'package:feride_v5_2/agent/llm_client.dart';
import 'package:feride_v5_2/agent/permissions.dart';
import 'package:feride_v5_2/agent/tools.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  final live = Platform.environment['FERIDE_LIVE'] == '1';
  final url = Platform.environment['FERIDE_API'] ?? 'http://127.0.0.1:8080/v1';

  test('yerel model araç kullanarak dosya oluşturur ve sorar', () async {
    final ws = Directory.systemTemp.createTempSync('feride_live_');
    addTearDown(() => ws.deleteSync(recursive: true));
    File(p.join(ws.path, 'fiyatlar.csv')).writeAsStringSync('urun,fiyat\nelma,12\narmut,30\nkiraz,55\n');

    final loop = AgentLoop(
      llm: LlmClient(baseUrl: url, model: 'local'),
      tools: ToolExecutor(BuiltinTools.core()),
      ctx: ToolContext(workspaceDir: ws.path, policy: PermissionPolicy(mode: PermissionMode.autoEdit, workspaceDir: ws.path)),
      cancelToken: CancelToken(),
      maxSteps: 12,
    );
    final used = <String>[];
    final res = await loop.run([
      {'role': 'system', 'content': 'Sen yerel bir masaüstü ajanısın. Çalışma alanı: ${ws.path}. İşleri araçlarla yap.'},
      {'role': 'user', 'content': 'fiyatlar.csv dosyasını oku, en pahalı ürünü bul ve sonucu ozet.txt dosyasına "EN PAHALI: <ürün>" biçiminde yaz.'},
    ], callbacks: AgentLoopCallbacks(onToolStart: (n, a) {
      used.add(n);
      stdout.writeln('ARAÇ → $n $a');
    }));
    stdout.writeln('SONUÇ (${res.reason}, ${res.steps} adım): ${res.finalText}');
    expect(res.ok, isTrue, reason: res.error);
    expect(File(p.join(ws.path, 'ozet.txt')).readAsStringSync().toLowerCase(), contains('kiraz'));
  }, skip: !live, timeout: const Timeout(Duration(minutes: 8)));
}
