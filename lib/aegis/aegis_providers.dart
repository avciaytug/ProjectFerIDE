import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'aegis_service.dart';
import 'subagent_engine.dart';
import '../features/chat/state.dart';
import '../features/settings/settings_provider.dart';

/// Aegis (Skills + Subagents) state katmanı.
final aegisServiceProvider = Provider<AegisService>((ref) {
  final svc = AegisService.instance;
  ref.onDispose(svc.dispose);
  return svc;
});

// ---- SKILLS ----
class SkillsNotifier extends Notifier<List<AegisSkill>> {
  @override
  List<AegisSkill> build() => _load();

  List<AegisSkill> _load() => AegisService.instance.listSkills();

  void refresh() => state = _load();

  void upsert(
      {required String name,
      required String description,
      required String content}) {
    AegisService.instance
        .saveSkill(name: name, description: description, content: content);
    state = _load();
  }

  void remove(String name) {
    AegisService.instance.deleteSkill(name);
    state = _load();
  }
}

final skillsProvider =
    NotifierProvider<SkillsNotifier, List<AegisSkill>>(() => SkillsNotifier());

// ---- SUBAGENTS ----
enum SubagentStatus { idle, running, done, failed }

class RunningSubagent {
  final String id;
  final String goal;
  final SubagentStatus status;
  final List<String> log;
  final String? result;
  RunningSubagent({
    required this.id,
    required this.goal,
    this.status = SubagentStatus.running,
    this.log = const [],
    this.result,
  });
}

class SubagentsNotifier extends Notifier<List<RunningSubagent>> {
  @override
  List<RunningSubagent> build() => const [];

  /// Yeni bir subagent başlatır; olayları state'e yazar.
  void spawn(String goal,
      {String? apiUrl,
      String? model,
      int maxSteps = 50,
      void Function(String)? onCompleted}) {
    final id = 'sub_${DateTime.now().millisecondsSinceEpoch}';
    final item = RunningSubagent(id: id, goal: goal);
    state = [...state, item];

    _run(id, goal,
        apiUrl: apiUrl,
        model: model,
        maxSteps: maxSteps,
        onCompleted: onCompleted);
  }

  Future<void> _run(
    String id,
    String goal, {
    String? apiUrl,
    String? model,
    int maxSteps = 50,
    void Function(String)? onCompleted,
  }) async {
    final mainModel = ref.read(selectedModelProvider);
    final customUrl = ref.read(settingsProvider).apiUrl;
    // Web'de model etiketi → GGUF ID + motor URL'si (/v1 | /v1-qwen).
    final effectiveApiUrl = apiUrl ?? baseUrlForModel(mainModel, customApiUrl: customUrl);
    final effectiveModel = model ?? modelForLabel(mainModel);

    final engine = SubagentEngine(
      apiUrl: effectiveApiUrl,
      model: effectiveModel,
      maxSteps: maxSteps,
    );
    try {
      final summary = await engine.run(goal, onEvent: (e) {
        _appendLog(id, '${e.type.toUpperCase()}: ${e.message}');
      });
      _setStatus(id, SubagentStatus.done, result: summary);
      if (onCompleted != null) onCompleted(summary);
    } catch (e) {
      _setStatus(id, SubagentStatus.failed, result: 'Hata: $e');
      if (onCompleted != null) onCompleted('Hata: $e');
    } finally {
      if (effectiveApiUrl.contains('11434')) {
        await engine.unload();
      }
    }
  }

  void _appendLog(String id, String line) {
    state = state.map((s) {
      if (s.id != id) return s;
      return RunningSubagent(
        id: s.id,
        goal: s.goal,
        status: s.status,
        log: [...s.log, line],
        result: s.result,
      );
    }).toList();
  }

  void _setStatus(String id, SubagentStatus st, {String? result}) {
    state = state.map((s) {
      if (s.id != id) return s;
      return RunningSubagent(
        id: s.id,
        goal: s.goal,
        status: st,
        log: s.log,
        result: result ?? s.result,
      );
    }).toList();
  }

  void clearFinished() {
    state = state.where((s) => s.status == SubagentStatus.running).toList();
  }

  /// AgentEngine'in spawn_agent tool'u için: subagent'ı başlatıp SONUCUNU BEKLER.
  /// UI'da da canlı görünür (state'e yazar).
  Future<String> spawnAndWait({required String goal, int maxSteps = 8}) async {
    final id = 'sub_${DateTime.now().millisecondsSinceEpoch}';
    state = [...state, RunningSubagent(id: id, goal: goal)];

    final mainModel = ref.read(selectedModelProvider);
    final customUrl = ref.read(settingsProvider).apiUrl;
    // Web'de model etiketi → GGUF ID + motor URL'si (/v1 | /v1-qwen).
    final effectiveApiUrl = baseUrlForModel(mainModel, customApiUrl: customUrl);
    final effectiveModel = modelForLabel(mainModel);

    final engine =
        SubagentEngine(apiUrl: effectiveApiUrl, model: effectiveModel, maxSteps: maxSteps);
    try {
      final summary = await engine.run(goal, onEvent: (e) {
        _appendLog(id, '[${e.type.toUpperCase()}] ${e.message}');
      });
      _setStatus(id, SubagentStatus.done, result: summary);
      return summary;
    } catch (e) {
      _setStatus(id, SubagentStatus.failed, result: 'Hata: $e');
      return 'Subagent hatası: $e';
    } finally {
      if (effectiveApiUrl.contains('11434')) {
        await engine.unload();
      }
    }
  }
}

final subagentsProvider =
    NotifierProvider<SubagentsNotifier, List<RunningSubagent>>(
        () => SubagentsNotifier());

// ---- DENEYİM SAYACI (sidebar rozeti için) ----
final experienceCountProvider = StateProvider<int>((ref) {
  try {
    return AegisService.instance.experienceCount();
  } catch (_) {
    return 0;
  }
});
