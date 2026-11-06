import 'package:flutter_test/flutter_test.dart';
import 'package:feride_v5_2/harness/context_manager.dart';

void main() {
  group('ContextManager.validateMessageOrder Tests', () {
    test('valid message sequence passes without errors', () {
      final messages = [
        {"role": "system", "content": "You are FerIDE"},
        {"role": "user", "content": "Read file foo.txt"},
        {
          "role": "assistant",
          "content": "",
          "tool_calls": [
            {
              "id": "call_123",
              "type": "function",
              "function": {"name": "read_file", "arguments": "{}"}
            }
          ]
        },
        {"role": "tool", "tool_call_id": "call_123", "name": "read_file", "content": "file content"},
        {"role": "assistant", "content": "The file contains: file content"}
      ];

      final errors = ContextManager.validateMessageOrder(messages);
      expect(errors, isEmpty);
    });

    test('detects system message placed in middle of conversation', () {
      final messages = [
        {"role": "system", "content": "System prompt"},
        {"role": "user", "content": "Hi"},
        {"role": "system", "content": "Middle system message (ILLEGAL)"},
        {"role": "assistant", "content": "Hello"}
      ];

      final errors = ContextManager.validateMessageOrder(messages);
      expect(errors.length, 1);
      expect(errors.first, contains('System mesajı index 0 dışında bulundu: index 2'));
    });

    test('detects orphan tool message without matching assistant tool_calls', () {
      final messages = [
        {"role": "system", "content": "System prompt"},
        {"role": "user", "content": "Hi"},
        {"role": "tool", "tool_call_id": "call_orphan", "name": "read_file", "content": "orphan content"}
      ];

      final errors = ContextManager.validateMessageOrder(messages);
      expect(errors.any((e) => e.contains('Yetim tool mesajı')), isTrue);
    });

    test('detects unanswered assistant tool call', () {
      final messages = [
        {"role": "system", "content": "System prompt"},
        {"role": "user", "content": "Hi"},
        {
          "role": "assistant",
          "content": "",
          "tool_calls": [
            {
              "id": "call_unanswered",
              "type": "function",
              "function": {"name": "run_command", "arguments": "{}"}
            }
          ]
        }
      ];

      final errors = ContextManager.validateMessageOrder(messages);
      expect(errors.any((e) => e.contains('Cevapsız tool çağrısı')), isTrue);
    });
  });

  group("ContextManager.compactIfNeeded Tests", () {
    test("does not touch messages below threshold (KV cache preserved)", () {
      final messages = [
        {"role": "system", "content": "You are FerIDE"},
        {"role": "user", "content": "hello world"},
        {"role": "assistant", "content": "hi there"}
      ];

      final originalSystem = messages[0]["content"];
      final originalUser = messages[1]["content"];
      final originalLength = messages.length;

      // 32768 tokens context -> threshold is 16384 tokens (~52000 chars)
      ContextManager.compactIfNeeded(messages: messages, maxContextTokens: 32768);

      expect(messages.length, originalLength);
      expect(messages[0]["content"], originalSystem);
      expect(messages[1]["content"], originalUser);
    });

    test("compacts old history while preserving system prompt and recent messages", () {
      // Build a conversation exceeding threshold
      final messages = <Map<String, dynamic>>[
        {"role": "system", "content": "System prompt strictly preserved"},
      ];

      // Add 12 turns with large content
      for (int i = 0; i < 10; i++) {
        messages.add({"role": "user", "content": "Query $i: " + "a" * 1000});
        messages.add({
          "role": "assistant",
          "content": "",
          "tool_calls": [
            {
              "id": "call_$i",
              "type": "function",
              "function": {"name": "read_file", "arguments": "{}"}
            }
          ]
        });
        messages.add({
          "role": "tool",
          "tool_call_id": "call_$i",
          "name": "read_file",
          "content": "output $i: " + "b" * 1500
        });
        messages.add({"role": "assistant", "content": "Answer $i"});
      }

      // Small maxContextTokens to trigger compaction
      ContextManager.compactIfNeeded(messages: messages, maxContextTokens: 4000);

      // System prompt strictly preserved at index 0
      expect(messages[0]["role"], "system");
      expect(messages[0]["content"], "System prompt strictly preserved");

      // Length should be compacted
      expect(messages.length, lessThan(41));

      // Order validator should still pass!
      final orderErrors = ContextManager.validateMessageOrder(messages);
      expect(orderErrors, isEmpty);
    });
  });

}
