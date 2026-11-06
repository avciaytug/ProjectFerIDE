import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:feride_v5_2/features/chat/agent_activity_group.dart';
import 'package:feride_v5_2/models/chat_session.dart';
import 'package:feride_v5_2/services/agent_engine.dart';

void main() {
  group('AgentActivityGroup Widget Tests', () {
    testWidgets('renders collapsed summary bar with step count and tool names', (tester) async {
      final messages = [
        ChatMessage(
          id: '1',
          event: StepStarted(AgentStep('Dosya taranıyor')),
        ),
        ChatMessage(
          id: '2',
          event: ToolInvoked('run_command', {'command': 'ls -la'}),
        ),
        ChatMessage(
          id: '3',
          event: ToolCompleted('run_command', 'total 0'),
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AgentActivityGroup(
              messages: messages,
              isLive: false,
            ),
          ),
        ),
      );

      // Başlangıçta özet barı görünmeli
      expect(find.textContaining('1 işlem tamamlandı'), findsOneWidget);
      expect(find.textContaining('3 adım'), findsOneWidget);

      // Başlangıçta detaylar kapalı
      expect(find.text('total 0'), findsNothing);

      // Tıklandığında detaylar açılmalı
      await tester.tap(find.byType(InkWell));
      await tester.pumpAndSettle();

      expect(find.text('total 0'), findsOneWidget);
      expect(find.textContaining('Dosya taranıyor'), findsOneWidget);
    });

    testWidgets('renders live spinning indicator when isLive is true', (tester) async {
      final messages = [
        ChatMessage(
          id: '1',
          event: ToolInvoked('read_file', {'path': '/tmp/test.txt'}),
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AgentActivityGroup(
              messages: messages,
              isLive: true,
            ),
          ),
        ),
      );

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.textContaining('read_file'), findsOneWidget);
    });
  });
}
