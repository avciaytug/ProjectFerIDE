import 'package:uuid/uuid.dart';
import '../services/agent_engine.dart';
import '../services/claude_tools.dart';

/// Bir oturum içindeki tek bir mesaj (AgentEvent sarmalayıcısı).
///
/// Disk formatı (eski sürüm oturumlarıyla birebir uyumlu):
/// {"id": "...", "type": "AgentStarted", "data": {...}, "timestamp": "ISO8601"}
class ChatMessage {
  final String id;
  AgentEvent event;
  final DateTime timestamp;

  ChatMessage({
    required this.id,
    required this.event,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String? ?? '';
    final data = (json['data'] as Map?)?.cast<String, dynamic>() ?? const {};
    final ts = json['timestamp'] as String?;
    return ChatMessage(
      id: json['id'] as String? ?? const Uuid().v4(),
      event: _eventFromJson(type, data),
      timestamp: (ts != null && DateTime.tryParse(ts) != null)
          ? DateTime.parse(ts)
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'type': _eventType(event),
      'data': _eventToJson(event),
      'timestamp': timestamp.toIso8601String(),
    };
  }
}

String _eventType(AgentEvent e) {
  if (e is AgentStarted) return 'AgentStarted';
  if (e is StepStarted) return 'StepStarted';
  if (e is AgentMessage) return 'AgentMessage';
  if (e is ReasoningMessage) return 'ReasoningMessage';
  if (e is ToolInvoked) return 'ToolInvoked';
  if (e is ToolCompleted) return 'ToolCompleted';
  if (e is AgentCompleted) return 'AgentCompleted';
  if (e is AgentFailed) return 'AgentFailed';
  if (e is TodoUpdated) return 'TodoUpdated';
  if (e is JobStarted) return 'JobStarted';
  if (e is JobProgress) return 'JobProgress';
  if (e is JobCompleted) return 'JobCompleted';
  if (e is JobAwaitingHuman) return 'JobAwaitingHuman';
  return e.runtimeType.toString();
}

Map<String, dynamic> _eventToJson(AgentEvent e) {
  if (e is AgentStarted) {
    return {'goal': e.goal, 'base64Images': e.base64Images};
  }
  if (e is StepStarted) {
    return {'description': e.step.description, 'details': e.details};
  }
  if (e is AgentMessage) {
    return {
      'message': e.message,
      'inputTokens': e.inputTokens,
      'outputTokens': e.outputTokens,
      'tokensPerSecond': e.tokensPerSecond,
    };
  }
  if (e is ReasoningMessage) {
    return {'message': e.message};
  }
  if (e is ToolInvoked) {
    return {'toolName': e.toolName, 'arguments': e.arguments};
  }
  if (e is ToolCompleted) {
    return {'toolName': e.toolName, 'output': e.output};
  }
  if (e is AgentCompleted) {
    return {'finalMessage': e.finalMessage};
  }
  if (e is TodoUpdated) {
    return {'todos': e.todos.map((t) => t.toMap()).toList()};
  }
  if (e is AgentFailed) {
    return {'error': e.error};
  }
  if (e is JobStarted) {
    return {'jobId': e.jobId, 'taskDescription': e.taskDescription};
  }
  if (e is JobProgress) {
    return {'jobId': e.jobId, 'statusMessage': e.statusMessage};
  }
  if (e is JobCompleted) {
    return {'jobId': e.jobId, 'result': e.result};
  }
  if (e is JobAwaitingHuman) {
    return {'jobId': e.jobId, 'actionRequired': e.actionRequired};
  }
  return {'message': e.toString()};
}

AgentEvent _eventFromJson(String type, Map<String, dynamic> d) {
  switch (type) {
    case 'AgentStarted':
      return AgentStarted(
        d['goal'] as String? ?? '',
        base64Images: (d['base64Images'] as List?)?.cast<String>(),
      );
    case 'StepStarted':
      return StepStarted(
        AgentStep(d['description'] as String? ?? ''),
        details: d['details'] as String?,
      );
    case 'AgentMessage':
      return AgentMessage(
        d['message'] as String? ?? '',
        inputTokens: (d['inputTokens'] as num?)?.toInt(),
        outputTokens: (d['outputTokens'] as num?)?.toInt(),
        tokensPerSecond: (d['tokensPerSecond'] as num?)?.toDouble(),
      );
    case 'ReasoningMessage':
      return ReasoningMessage(d['message'] as String? ?? '');
    case 'ToolInvoked':
      return ToolInvoked(
        d['toolName'] as String? ?? '',
        (d['arguments'] as Map?)?.cast<String, dynamic>() ?? const {},
      );
    case 'ToolCompleted':
      return ToolCompleted(
        d['toolName'] as String? ?? '',
        d['output'] as String? ?? '',
      );
    case 'AgentCompleted':
      return AgentCompleted(d['finalMessage'] as String? ?? '');
        case 'TodoUpdated':
      final rawList = d['todos'] as List? ?? [];
      return TodoUpdated(rawList.map((item) => TodoItem.fromMap(Map<String, dynamic>.from(item as Map))).toList());
    case 'AgentFailed':
      return AgentFailed(d['error'] as String? ?? '');
    case 'JobStarted':
      return JobStarted(
        d['jobId'] as String? ?? '',
        d['taskDescription'] as String? ?? '',
      );
    case 'JobProgress':
      return JobProgress(
        d['jobId'] as String? ?? '',
        d['statusMessage'] as String? ?? '',
      );
    case 'JobCompleted':
      return JobCompleted(
        d['jobId'] as String? ?? '',
        d['result'] as String? ?? '',
      );
    case 'JobAwaitingHuman':
      return JobAwaitingHuman(
        d['jobId'] as String? ?? '',
        d['actionRequired'] as String? ?? '',
      );
    default:
      // Bilinmeyen / eski olay türü: AgentMessage olarak sar.
      final raw = d['message'] ?? d['goal'] ?? d['error'] ?? d.toString();
      return AgentMessage(raw.toString());
  }
}

/// Bir sohbet oturumu.
class ChatSession {
  String id;
  String? folderId;
  String title;
  DateTime createdAt;
  DateTime updatedAt;
  List<ChatMessage> messages;

  /// İndeks özetinden yüklenen hızlı token sayısı (null ise hesaplanır).
  int? cachedTokens;

  ChatSession({
    String? id,
    this.folderId,
    String? title,
    DateTime? createdAt,
    DateTime? updatedAt,
    List<ChatMessage>? messages,
  })  : id = id ?? const Uuid().v4(),
        title = title ?? 'Yeni Sohbet',
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now(),
        messages = messages ?? [];

  /// Oturumdaki toplam token sayısı (önbellek varsa ondan, yoksa
  /// AgentMessage olaylarının input+output tokenlarından hesaplanır).
  int get calculatedTokens {
    final cached = cachedTokens;
    if (cached != null) return cached;
    var total = 0;
    for (final m in messages) {
      final e = m.event;
      if (e is AgentMessage) {
        total += e.inputTokens ?? 0;
        total += e.outputTokens ?? 0;
      }
    }
    return total;
  }

  ChatSession copyWith({
    String? id,
    String? folderId,
    String? title,
    DateTime? createdAt,
    DateTime? updatedAt,
    List<ChatMessage>? messages,
  }) {
    return ChatSession(
      id: id ?? this.id,
      folderId: folderId ?? this.folderId,
      title: title ?? this.title,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      messages: messages ?? this.messages,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'folderId': folderId,
      'title': title,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'messages': messages.map((m) => m.toJson()).toList(),
    };
  }

  factory ChatSession.fromJson(Map<String, dynamic> json) {
    DateTime? parseTs(String? v) {
      if (v == null) return null;
      return DateTime.tryParse(v);
    }

    return ChatSession(
      id: json['id'] as String?,
      folderId: json['folderId'] as String?,
      title: json['title'] as String? ?? 'Yeni Sohbet',
      createdAt: parseTs(json['createdAt'] as String?) ?? DateTime.now(),
      updatedAt: parseTs(json['updatedAt'] as String?) ?? DateTime.now(),
      messages: (json['messages'] as List? ?? [])
          .whereType<Map<String, dynamic>>()
          .map((e) => ChatMessage.fromJson(e))
          .toList(),
    );
  }
}
