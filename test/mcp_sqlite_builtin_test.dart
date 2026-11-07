import 'dart:io';

import 'package:feride_v5_2/services/mcp_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('Arşivlenmiş mcp-server-sqlite yerleşik sunucuya taşınır ve gerçekten çalışır', () async {
    final dir = Directory.systemTemp.createTempSync('feride_sqlite_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final db = p.join(dir.path, 'bilgi.db');
    final old = McpServerConfig(name: 'sqlite', command: 'uvx', args: ['mcp-server-sqlite', '--db-path', db]);

    final m = McpService.migrateServer(old);
    expect(m.args.first, endsWith('mcp_sqlite_server.py'));
    expect(m.args, containsAllInOrder(['--db-path', db]));
    expect(McpService.migrateServer(m), same(m)); // ikinci kez dokunulmaz

    final svc = McpService.instance;
    svc.loadConfig(p.join(dir.path, 'mcp.json'));
    svc.addOrUpdateServer(m);
    addTearDown(svc.shutdownAll);

    final tools = await svc.listTools(m);
    expect(tools.map((t) => t.name), containsAll(['read_query', 'write_query', 'create_table', 'list_tables', 'describe_table']));
    expect(tools.firstWhere((t) => t.name == 'read_query').readOnlyHint, isTrue);
    expect(tools.firstWhere((t) => t.name == 'write_query').readOnlyHint, isFalse);

    expect(await svc.callToolByName('sqlite', 'create_table', {'query': 'CREATE TABLE notlar (id INTEGER, metin TEXT)'}), contains('oluşturuldu'));
    expect(await svc.callToolByName('sqlite', 'write_query', {'query': "INSERT INTO notlar VALUES (1, 'FerIDE çalışıyor')"}), contains('1 satır'));
    expect(await svc.callToolByName('sqlite', 'read_query', {'query': 'SELECT metin FROM notlar'}), contains('FerIDE çalışıyor'));
    // Güvenlik: okuma aracıyla yazma yapılamaz
    expect(await svc.callToolByName('sqlite', 'read_query', {'query': 'DROP TABLE notlar'}), contains('yalnızca'));
    expect(await svc.callToolByName('sqlite', 'list_tables', {}), contains('notlar'));
  });
}
