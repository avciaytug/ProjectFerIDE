import 'package:flutter_test/flutter_test.dart';
import 'package:feride_v5_2/services/tool_registry.dart';

void main() {
  group('ToolRegistry Tests', () {
    test('returns core coding tools without dispatch_worker in normal coding session', () {
      final tools = ToolRegistry.getToolsForSession(isLiveSession: false);
      final names = tools.map((t) => t['function']['name']).toSet();

      expect(names, contains('run_command'));
      expect(names, contains('read_file'));
      expect(names, contains('write_to_file'));
      expect(names, contains('replace_file_content'));
      expect(names, contains('grep_search'));
      expect(names, contains('glob'));
      expect(names, contains('read_document'));
      expect(names, contains('edit_media_or_document'));
      expect(names, contains('open_file_in_system'));
      expect(names, contains('todo_write'));
      expect(names, contains('spawn_agent'));
      expect(names, isNot(contains('dispatch_worker')));
      expect(names, isNot(contains('check_market')));
      expect(names, isNot(contains('analyze_market')));
    });

    test('returns dispatch_worker instead of spawn_agent in live voice session', () {
      final tools = ToolRegistry.getToolsForSession(isLiveSession: true);
      final names = tools.map((t) => t['function']['name']).toSet();

      expect(names, contains('dispatch_worker'));
      expect(names, isNot(contains('spawn_agent')));
    });

    test('includes market tools only when explicitly requested', () {
      final standard = ToolRegistry.getToolsForSession(isLiveSession: false, includeMarketTools: false);
      expect(standard.any((t) => t['function']['name'] == 'check_market'), isFalse);

      final withMarket = ToolRegistry.getToolsForSession(isLiveSession: false, includeMarketTools: true);
      expect(withMarket.any((t) => t['function']['name'] == 'check_market'), isTrue);
    });
  });
}
