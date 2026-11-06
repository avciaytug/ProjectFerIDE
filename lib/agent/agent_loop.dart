/// Ana ajan ve alt ajanların paylaştığı tek araç döngüsü.
///
/// model → araç çağrıları → araç sonuçları → model ... döngüsünü yürütür;
/// Riverpod/UI'dan bağımsızdır, bu yüzden test edilebilir ve alt ajanlarda
/// aynen kullanılır.
library;

import 'package:dio/dio.dart';

import '../harness/context_manager.dart';
import '../harness/progress_tracker.dart';
import 'llm_client.dart';
import 'tools.dart';

class AgentLoopCallbacks {
  final void Function(String status, {String? details})? onStatus;
  final void Function(String text)? onContent;
  final void Function(String text)? onReasoning;
  final void Function(String tool, Map<String, dynamic> args)? onToolStart;
  final void Function(String tool, String output)? onToolEnd;

  /// Bir model turu araç çağrısıyla bittiğinde (yeni adım başlarken).
  final void Function(LlmTurn turn)? onTurnEnd;

  const AgentLoopCallbacks({
    this.onStatus,
    this.onContent,
    this.onReasoning,
    this.onToolStart,
    this.onToolEnd,
    this.onTurnEnd,
  });
}

enum AgentStopReason { completed, maxSteps, cancelled, loop, error }

class AgentLoopResult {
  final AgentStopReason reason;
  final String finalText;
  final String? error;
  final int steps;
  final List<String> toolsUsed;
  final LlmTurn? lastTurn;

  const AgentLoopResult({
    required this.reason,
    required this.finalText,
    required this.steps,
    required this.toolsUsed,
    this.error,
    this.lastTurn,
  });

  bool get ok => reason == AgentStopReason.completed;
}

class AgentLoop {
  final LlmClient llm;
  final ToolExecutor tools;
  final ToolContext ctx;
  final int maxSteps;
  final int maxContextTokens;
  final bool thinking;
  final double temperature;
  final CancelToken cancelToken;

  AgentLoop({
    required this.llm,
    required this.tools,
    required this.ctx,
    required this.cancelToken,
    this.maxSteps = 100,
    this.maxContextTokens = 32768,
    this.thinking = false,
    this.temperature = 0.6,
  });

  /// [messages] yerinde güncellenir (system + geçmiş + yeni kullanıcı mesajı).
  Future<AgentLoopResult> run(List<Map<String, dynamic>> messages,
      {AgentLoopCallbacks callbacks = const AgentLoopCallbacks()}) async {
    final tracker = ProgressTracker();
    final used = <String>[];
    LlmTurn? last;

    for (var step = 1; step <= maxSteps; step++) {
      if (cancelToken.isCancelled) {
        return AgentLoopResult(
            reason: AgentStopReason.cancelled, finalText: '', steps: step - 1, toolsUsed: used, lastTurn: last);
      }

      ContextManager.compactIfNeeded(messages: messages, maxContextTokens: maxContextTokens, sessionId: ctx.sessionId);

      LlmTurn turn;
      try {
        turn = await llm.complete(
          messages: messages,
          tools: tools.schemas,
          enableThinking: thinking,
          temperature: temperature,
          cancelToken: cancelToken,
          onContent: callbacks.onContent,
          onReasoning: callbacks.onReasoning,
          onStatus: (s) => callbacks.onStatus?.call(s),
        );
      } on LlmCancelled {
        return AgentLoopResult(
            reason: AgentStopReason.cancelled, finalText: '', steps: step, toolsUsed: used, lastTurn: last);
      } catch (e) {
        return AgentLoopResult(
            reason: AgentStopReason.error, finalText: '', error: e.toString(), steps: step, toolsUsed: used, lastTurn: last);
      }
      last = turn;

      if (turn.toolCalls.isEmpty) {
        var text = turn.content.trim();
        // Bazı modeller tüm cevabı düşünce bloğuna yazar; boş bırakma.
        if (text.isEmpty && turn.reasoning.trim().isNotEmpty) text = turn.reasoning.trim();
        if (text.isEmpty) {
          return AgentLoopResult(
            reason: AgentStopReason.error,
            finalText: '',
            error: 'Model boş yanıt döndürdü.',
            steps: step,
            toolsUsed: used,
            lastTurn: turn,
          );
        }
        messages.add({'role': 'assistant', 'content': text});
        return AgentLoopResult(
            reason: AgentStopReason.completed, finalText: text, steps: step, toolsUsed: used, lastTurn: turn);
      }

      callbacks.onTurnEnd?.call(turn);
      messages.add({
        'role': 'assistant',
        'content': turn.content,
        'tool_calls': turn.toolCalls.map((c) => c.toPayload()).toList(),
      });

      var loopAbort = false;
      for (final call in turn.toolCalls) {
        if (cancelToken.isCancelled) {
          // Her tool_call'a yanıt verilmeli; yoksa sonraki istekte şablon hatası olur.
          messages.add(_toolMsg(call, 'İptal edildi.'));
          continue;
        }
        final args = call.arguments;
        callbacks.onToolStart?.call(call.name, args ?? const {});

        String output;
        final status = tracker.recordToolCall(call.name, args ?? const {});
        if (status == ProgressActionStatus.loopDetected && tracker.consecutiveLoopCount >= 3) {
          output = 'DURDURULDU: Aynı çağrı art arda tekrarlandı.';
          loopAbort = true;
        } else if (status == ProgressActionStatus.loopDetected) {
          output = 'UYARI: "${call.name}" aynı parametrelerle zaten çalıştırıldı. Önceki sonucu kullan ve sonraki adıma geç.';
        } else {
          callbacks.onStatus?.call('Araç çalışıyor: ${call.name}');
          output = await tools.execute(call.name, args, ctx);
          used.add(call.name);
          // Yönlendirme notları araç sonucuna eklenir; araya "user" mesajı
          // sokmak tool_calls → tool sırasını bozup sunucu hatası veriyordu.
          if (status == ProgressActionStatus.stalled) {
            output += '\n\n[Sistem notu: ${tracker.stepsSinceLastMutation} adımdır yalnızca inceleme yapılıyor. '
                'Yeterli bilgi toplandıysa bulguları özetle veya uygulamaya geç.]';
          }
        }
        callbacks.onToolEnd?.call(call.name, output);
        messages.add(_toolMsg(call, output));
      }

      if (loopAbort) {
        return AgentLoopResult(
          reason: AgentStopReason.loop,
          finalText: 'Aynı işlem art arda tekrarlandığı için güvenlik amacıyla durduruldu.',
          steps: step,
          toolsUsed: used,
          lastTurn: turn,
        );
      }
      callbacks.onStatus?.call('Araç sonuçları değerlendiriliyor...',
          details: '${turn.toolCalls.length} araç çağrısı | ${messages.length} mesaj');
    }

    return AgentLoopResult(
      reason: AgentStopReason.maxSteps,
      finalText: '',
      error: 'Maksimum adım sınırına ($maxSteps) ulaşıldı. "Devam et" yazarak kaldığı yerden sürdürebilirsiniz.',
      steps: maxSteps,
      toolsUsed: used,
      lastTurn: last,
    );
  }

  static Map<String, dynamic> _toolMsg(LlmToolCall call, String content) => {
        'role': 'tool',
        'tool_call_id': call.id,
        'name': call.name,
        'content': content,
      };
}
