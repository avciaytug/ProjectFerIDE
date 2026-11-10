import 'package:dio/dio.dart';

import '../agent/agent_loop.dart';
import '../agent/llm_client.dart';
import '../agent/permissions.dart';
import '../agent/tools.dart';

/// Alt ajan ilerleme olayı (UI'daki alt ajan panelinde gösterilir).
class SubagentEvent {
  final String type; // thinking | tool_invoked | tool_completed | done | failed
  final String message;
  const SubagentEvent(this.type, this.message);
}

/// Alt ajan: ana ajanın bağlamını şişirmeden, kendi bağlam penceresinde
/// görevi tamamlar ve kısa bir özet döndürür. Ana ajanla AYNI araç döngüsünü,
/// araçları ve izin denetimini kullanır.
class SubagentEngine {
  final String apiUrl;
  final String model;
  final int maxSteps;
  final String workspaceDir;
  final PermissionMode permissionMode;
  /// Verilirse izin modu her araç çağrısında güncel ayardan okunur.
  final PermissionMode Function()? permissionModeOf;
  final List<AgentTool> extraTools;
  final CancelToken cancelToken = CancelToken();

  SubagentEngine({
    required this.apiUrl,
    required this.model,
    required this.workspaceDir,
    this.permissionMode = PermissionMode.autoEdit,
    this.permissionModeOf,
    this.maxSteps = 25,
    this.extraTools = const [],
  });

  /// Alt ajanların kullanabileceği araçlar (kendi alt ajanını doğuramaz).
  static List<AgentTool> defaultTools() => BuiltinTools.core()
      .where((t) => t.name != 'todo_write' && t.name != 'save_skill' && t.name != 'record_experience')
      .toList();

  void cancel() => cancelToken.cancel('İptal edildi');

  Future<String> run(String goal, {required void Function(SubagentEvent e) onEvent}) async {
    final messages = <Map<String, dynamic>>[
      {
        'role': 'system',
        'content': 'Sen FerIDE\'in bir ALT AJANISIN. Tek görevin sana verilen işi araçlarla tamamlamak. '
            'Çalışma alanı: $workspaceDir. Gereksiz yan işlere girme. '
            'Bitirdiğinde ana ajana bulguları ve yaptıklarını en fazla 10 satırda, somut (dosya yolları, komut sonuçları) olarak bildir.',
      },
      {'role': 'user', 'content': goal},
    ];

    final loop = AgentLoop(
      llm: LlmClient(baseUrl: apiUrl, model: model),
      tools: ToolExecutor([...defaultTools(), ...extraTools]),
      ctx: ToolContext(
        workspaceDir: workspaceDir,
        policy: PermissionPolicy(
            mode: permissionMode, workspaceDir: workspaceDir, modeOf: permissionModeOf),
      ),
      cancelToken: cancelToken,
      maxSteps: maxSteps,
      temperature: 0.3,
    );

    var step = 0;
    final result = await loop.run(messages,
        callbacks: AgentLoopCallbacks(
          onTurnEnd: (_) => onEvent(SubagentEvent('thinking', 'Adım ${++step}')),
          onToolStart: (name, args) {
            final hint = args['command'] ?? args['path'] ?? args['query'] ?? args['url'] ?? '';
            onEvent(SubagentEvent('tool_invoked', '$name $hint'.trim()));
          },
          onToolEnd: (name, out) =>
              onEvent(SubagentEvent('tool_completed', out.length > 300 ? '${out.substring(0, 300)}...' : out)),
        ));

    if (result.ok) {
      onEvent(SubagentEvent('done', result.finalText));
      return result.finalText;
    }
    final msg = switch (result.reason) {
      AgentStopReason.cancelled => 'Alt ajan iptal edildi.',
      AgentStopReason.maxSteps => 'Alt ajan $maxSteps adımda görevi bitiremedi. Son durum: ${result.lastTurn?.content ?? '-'}',
      _ => 'Alt ajan hatası: ${result.error ?? result.finalText}',
    };
    onEvent(SubagentEvent('failed', msg));
    return msg;
  }
}
