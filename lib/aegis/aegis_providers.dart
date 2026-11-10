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
  final Map<String, SubagentEngine> _engines = {};

  @override
  List<RunningSubagent> build() => const [];

  /// Arka planda bir alt ajan başlatır; bitince [onCompleted] çağrılır.
  void spawn(String goal, {int maxSteps = 40, void Function(String)? onCompleted}) {
    unawaited(_start(goal, maxSteps).then((r) => onCompleted?.call(r)));
  }

  /// spawn_agent aracı için: alt ajanı çalıştırır ve özetini döndürür.
  /// UI'daki alt ajan panelinde de canlı görünür.
  Future<String> spawnAndWait({required String goal, int maxSteps = 25}) => _start(goal, maxSteps);

  Future<String> _start(String goal, int maxSteps) async {
    final id = 'sub_${DateTime.now().microsecondsSinceEpoch}';
    state = [...state, RunningSubagent(id: id, goal: goal)];

    final settings = ref.read(settingsProvider);
    final engine = SubagentEngine(
      apiUrl: ref.read(apiUrlProvider),
      model: ref.read(selectedModelProvider),
      workspaceDir: settings.effectiveWorkspaceDir,
      permissionMode: settings.permissionMode,
      permissionModeOf: () => ref.read(settingsProvider).permissionMode,
      maxSteps: maxSteps,
    );
    _engines[id] = engine;
    try {
      final summary = await engine.run(goal, onEvent: (e) => _appendLog(id, '[${e.type.toUpperCase()}] ${e.message}'));
      _setStatus(id, summary.startsWith('Alt ajan') ? SubagentStatus.failed : SubagentStatus.done, result: summary);
      return summary;
    } catch (e) {
      _setStatus(id, SubagentStatus.failed, result: 'Hata: $e');
      return 'Alt ajan hatası: $e';
    } finally {
      _engines.remove(id);
    }
  }

  /// Çalışan tüm alt ajanları durdurur.
  void cancelAll() {
    for (final e in _engines.values) {
      e.cancel();
    }
  }

  void _appendLog(String id, String line) {
    state = [
      for (final s in state)
        if (s.id == id)
          RunningSubagent(id: s.id, goal: s.goal, status: s.status, log: [...s.log, line], result: s.result)
        else
          s
    ];
  }

  void _setStatus(String id, SubagentStatus st, {String? result}) {
    state = [
      for (final s in state)
        if (s.id == id)
          RunningSubagent(id: s.id, goal: s.goal, status: st, log: s.log, result: result ?? s.result)
        else
          s
    ];
  }

  void clearFinished() {
    state = state.where((s) => s.status == SubagentStatus.running).toList();
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
