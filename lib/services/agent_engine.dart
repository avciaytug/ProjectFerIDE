import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../aegis/aegis_providers.dart';
import '../aegis/aegis_service.dart';
import '../agent/agent_loop.dart';
import '../agent/llm_client.dart';
import '../agent/permissions.dart';
import '../agent/tools.dart';
import '../features/chat/state.dart';
import '../features/settings/settings_provider.dart';
import '../harness/context_manager.dart';
import '../models/chat_session.dart';
import 'app_paths.dart';
import 'claude_tools.dart';
import 'file_service.dart';
import 'backend_manager.dart';
import 'mcp_service.dart';
import 'pty_sandbox.dart';

// ============================================================================
// Ajan olayları (UI ve sohbet kaydı bu olayları dinler/saklar)
// ============================================================================
abstract class AgentEvent {}

class AgentStarted extends AgentEvent {
  final String goal;
  final List<String>? base64Images;
  AgentStarted(this.goal, {this.base64Images});
}

class StepStarted extends AgentEvent {
  final AgentStep step;
  final String? details;
  StepStarted(this.step, {this.details});
}

class AgentMessage extends AgentEvent {
  final String message;
  final int? inputTokens;
  final int? outputTokens;
  final double? tokensPerSecond;
  AgentMessage(this.message, {this.inputTokens, this.outputTokens, this.tokensPerSecond});
}

class ReasoningMessage extends AgentEvent {
  final String message;
  ReasoningMessage(this.message);
}

class ToolInvoked extends AgentEvent {
  final String toolName;
  final Map<String, dynamic> arguments;
  ToolInvoked(this.toolName, this.arguments);
}

class ToolCompleted extends AgentEvent {
  final String toolName;
  final String output;
  ToolCompleted(this.toolName, this.output);
}

class AgentCompleted extends AgentEvent {
  final String finalMessage;
  AgentCompleted(this.finalMessage);
}

class TodoUpdated extends AgentEvent {
  final List<TodoItem> todos;
  TodoUpdated(this.todos);
}

class AgentFailed extends AgentEvent {
  final String error;
  AgentFailed(this.error);
}

/// Arka plan işçisi (sesli oturumdaki dispatch_worker) olayları.
class JobStarted extends AgentEvent {
  final String jobId;
  final String taskDescription;
  JobStarted(this.jobId, this.taskDescription);
}

class JobProgress extends AgentEvent {
  final String jobId;
  final String statusMessage;
  JobProgress(this.jobId, this.statusMessage);
}

class JobCompleted extends AgentEvent {
  final String jobId;
  final String result;
  JobCompleted(this.jobId, this.result);
}

/// Eski sohbet kayıtlarıyla uyumluluk için korunur.
class JobAwaitingHuman extends AgentEvent {
  final String jobId;
  final String actionRequired;
  JobAwaitingHuman(this.jobId, this.actionRequired);
}

class AgentStep {
  final String description;
  AgentStep(this.description);
}

// ============================================================================
// AgentEngine: bir sohbet oturumunun ajanı
// ============================================================================
class AgentEngine {
  final StreamController<AgentEvent> _controller = StreamController<AgentEvent>.broadcast();
  final Ref _ref;
  final String? sessionId;
  CancelToken? _cancelToken;
  bool _isCurrentRunLiveSession = false;

  /// Aynı oturumda koşular sırayla çalışır (ör. arka plan işçisi bitince
  /// tetiklenen bildirim, süren bir koşunun üstüne binmesin).
  Future<void> _queue = Future.value();

  AgentEngine(this._ref, [this.sessionId]);

  bool get isCurrentRunLiveSession => _isCurrentRunLiveSession;
  Stream<AgentEvent> get events => _controller.stream;

  void _emit(AgentEvent event) {
    if (_controller.isClosed) return;
    _controller.add(event);
    if (sessionId != null && !_isCurrentRunLiveSession) {
      _ref.read(activeSessionProvider.notifier).handleEngineEvent(sessionId!, event);
    }
  }

  void _status(String text, {String? details}) => _emit(StepStarted(AgentStep(text), details: details));

  // --------------------------------------------------------------- prompt
  static String _platformName() {
    if (Platform.isLinux) return 'Linux';
    if (Platform.isMacOS) return 'macOS';
    if (Platform.isWindows) return 'Windows';
    return Platform.operatingSystem;
  }

  /// Sistem talimatı. Kısa ve net tutulur: yerel modellerde her token pahalı.
  static String buildSystemPrompt({
    required bool isLiveSession,
    required bool thinkingMode,
    required ThinkingLevel thinkingLevel,
    bool planMode = false,
    String extraContext = '',
    String? workingDirectory,
  }) {
    final ws = workingDirectory ?? AppPaths.homeDir;
    final now = DateTime.now();
    final env = 'Ortam: ${_platformName()} (${Platform.operatingSystemVersion}), kullanıcı dizini ${AppPaths.homeDir}, '
        'çalışma alanı $ws, tarih ${now.day.toString().padLeft(2, '0')}.${now.month.toString().padLeft(2, '0')}.${now.year} '
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}.';

    if (isLiveSession) {
      return 'Senin adın Feride; Aytuğ AVCI tarafından geliştirilen, bilgisayarda işleri yapabilen sesli bir yapay zeka asistanısın. '
          'Doğal, samimi ve kibar bir Türkçe konuş. Yanıtların SESLİ okunacak: kısa tut (1-3 cümle), markdown, tablo, kod bloğu ve emoji kullanma. '
          'Kullanıcı bir iş isterse araçlarla gerçekten yap ve sonucu tek cümleyle söyle. '
          'Uzun sürecek işleri dispatch_worker ile arka plana ver ve "Arka planda başlattım" de.\n$env$extraContext';
    }

    final b = StringBuffer()
      ..writeln('Sen FerIDE\'sin: Aytuğ AVCI tarafından geliştirilen, tamamen yerel çalışan, kullanıcının bilgisayarında '
          'gerçek işler yapabilen otonom bir masaüstü asistanı ve yazılım mühendisisin.')
      ..writeln(env)
      ..writeln()
      ..writeln('ÇALIŞMA İLKELERİ:')
      ..writeln('- Bir işi yapabiliyorsan araçlarla gerçekten yap; sadece nasıl yapılacağını anlatma.')
      ..writeln('- Dosya okumak için read_file/read_document, aramak için grep_search/glob/list_directory kullan; bunlar için terminal komutu yazma.')
      ..writeln('- Mevcut dosyayı değiştirirken önce oku, sonra replace_file_content ile hedefli değişiklik yap. Yeni dosya için write_to_file.')
      ..writeln('- run_command: derleme, test, git, paket yönetimi, sistem bilgisi ve uygulama başlatma. GUI uygulamaları için background=true.')
      ..writeln('- Çok adımlı işlerde todo_write ile plan yap ve ilerledikçe güncelle.')
      ..writeln('- Bağımsız ve geniş kapsamlı alt işleri spawn_agent ile alt ajana ver.')
      ..writeln('- Bir aracın sonucu REDDEDİLDİ veya ENGELLENDİ ise aynı işlemi tekrar deneme; kullanıcıya açıkla.')
      ..writeln('- Ekranda ne olduğunu görmen gerekirse take_screenshot + read_document kullan.')
      ..writeln('- İş bittiğinde dur ve kısa, net bir özet ver. Karşılaştırmalarda Markdown tablo kullan.')
      ..writeln('- Kullanıcı Türkçe yazıyorsa Türkçe yanıt ver.');

    if (planMode) {
      b.writeln('\n[PLAN MODU]: Hiçbir dosyayı değiştirme ve komut çalıştırma. Yalnızca inceleme araçlarıyla bilgi topla, '
          'todo_write ile adım adım bir uygulama planı hazırla ve kullanıcıya sun.');
    }
    if (thinkingMode) {
      b.writeln(switch (thinkingLevel) {
        ThinkingLevel.low => '\nYanıtlamadan önce kısaca düşün.',
        ThinkingLevel.med => '\nYanıtlamadan önce adım adım düşün.',
        ThinkingLevel.high => '\nDerinlemesine analiz et, alternatifleri değerlendir.',
        ThinkingLevel.xHigh || ThinkingLevel.max => '\nÇok derin düşün; uç durumları ve riskleri değerlendir.',
      });
    }
    b.write(ProjectRulesService.getProjectRules(ws));
    b.write(extraContext);
    return b.toString();
  }

  // ------------------------------------------------------------ kontrol
  void stop() => cancel(silent: true);

  void cancel({bool silent = false}) {
    _cancelToken?.cancel('Kullanıcı tarafından durduruldu');
    _cancelToken = null;
    ApprovalBroker.instance.rejectAll();
    PtySandbox.killAllActiveProcesses();
    if (!silent) _emit(AgentFailed('İşlem kullanıcı tarafından durduruldu.'));
    _ref.read(agentIsRunningProvider.notifier).state = false;
  }

  void dispose() => _controller.close();

  /// Bir kullanıcı mesajını işler. Aynı oturumdaki çağrılar sıraya alınır.
  Future<void> run(String input, bool thinkingMode, int currentTokens,
      {List<String>? base64Images, bool isLiveSession = false, ThinkingLevel thinkingLevel = ThinkingLevel.med}) {
    final next = _queue.then((_) => _run(input, thinkingMode,
        base64Images: base64Images, isLiveSession: isLiveSession, thinkingLevel: thinkingLevel));
    _queue = next.catchError((_) {});
    return next;
  }

  Future<void> _run(String input, bool thinkingMode,
      {List<String>? base64Images, required bool isLiveSession, required ThinkingLevel thinkingLevel}) async {
    _isCurrentRunLiveSession = isLiveSession;
    _ref.read(agentIsRunningProvider.notifier).state = true;
    final cancelToken = CancelToken();
    _cancelToken = cancelToken;

    try {
      final settings = _ref.read(settingsProvider);
      final apiUrl = _ref.read(apiUrlProvider);
      final modelLabel = _ref.read(selectedModelProvider);

      if (!await _ensureBackend(apiUrl)) return;

      var maxCtx = _ref.read(maxContextSizeProvider);
      final serverCtx = await ContextManager.fetchServerContextSize(apiUrl);
      if (serverCtx != null && serverCtx > 0) {
        maxCtx = serverCtx;
        _ref.read(maxContextSizeProvider.notifier).state = serverCtx;
      }

      final workspace = settings.effectiveWorkspaceDir;
      final planMode = _ref.read(planModeProvider);
      final llm = LlmClient(baseUrl: apiUrl, model: modelLabel);

      // Araçlar: çekirdek + alt ajan/işçi + MCP
      final toolList = <AgentTool>[
        ...BuiltinTools.core(),
        if (isLiveSession) BuiltinTools.dispatchWorker else BuiltinTools.spawnAgent,
      ];
      final mcpNote = StringBuffer();
      if (settings.mcpEnabled) {
        final servers = McpService.instance.servers.where((s) => s.isEnabled && settings.isMcpServerEnabled(s.name)).toList();
        if (servers.isNotEmpty) {
          _status('MCP araçları hazırlanıyor...', details: servers.map((s) => s.name).join(', '));
          final infos = await McpService.instance.discoverTools(servers);
          toolList.addAll(BuiltinTools.mcpTools(infos, timeoutSeconds: settings.mcpTimeoutSeconds));
          final reached = infos.map((i) => i.server).toSet();
          if (reached.isNotEmpty) mcpNote.write('\n\nBağlı MCP sunucuları: ${reached.join(', ')} (araç adları mcp__sunucu__araç).');
        }
      }
      // Plan modunda yalnızca okuma araçları verilir (eskiden sadece talimattı).
      final usableTools = planMode ? toolList.where((t) => t.risk == ToolRisk.read).toList() : toolList;
      final executor = ToolExecutor(usableTools);

      final ctx = ToolContext(
        workspaceDir: workspace,
        policy: PermissionPolicy(mode: settings.permissionMode, workspaceDir: workspace),
        sessionId: sessionId,
        onTodos: (todos) => _emit(TodoUpdated(todos)),
        spawnSubagent: (goal, steps) =>
            _ref.read(subagentsProvider.notifier).spawnAndWait(goal: goal, maxSteps: steps),
        dispatchWorker: (goal) => _dispatchWorker(goal, thinkingMode, thinkingLevel),
        onMemoryChanged: () {
          _ref.read(skillsProvider.notifier).refresh();
          _ref.read(experienceCountProvider.notifier).state = AegisService.instance.experienceCount();
        },
      );

      final messages = <Map<String, dynamic>>[
        {
          'role': 'system',
          'content': buildSystemPrompt(
            isLiveSession: isLiveSession,
            thinkingMode: thinkingMode,
            thinkingLevel: thinkingLevel,
            planMode: planMode,
            workingDirectory: workspace,
            extraContext: _memoryContext(input, settings) + mcpNote.toString(),
          ),
        },
        ...await _history(input),
      ];
      messages.add(await _userMessage(input, base64Images, llm));

      final effectiveThinking = !isLiveSession && thinkingMode;
      final loop = AgentLoop(
        llm: llm,
        tools: executor,
        ctx: ctx,
        cancelToken: cancelToken,
        maxSteps: settings.maxSteps,
        maxContextTokens: maxCtx,
        thinking: effectiveThinking,
        temperature: isLiveSession ? 0.5 : 0.6,
      );

      _status(effectiveThinking ? 'Düşünüyor...' : 'Yanıt hazırlanıyor...', details: 'Model: $modelLabel');
      var streamedSinceTool = false;
      final result = await loop.run(messages,
          callbacks: AgentLoopCallbacks(
            onStatus: (s, {details}) => _status(s, details: details),
            onReasoning: (r) {
              if (effectiveThinking && r.isNotEmpty) _emit(ReasoningMessage(r));
            },
            onContent: (c) {
              if (c.isNotEmpty) {
                streamedSinceTool = true;
                _emit(AgentMessage(c));
              }
            },
            onToolStart: (name, args) {
              streamedSinceTool = false;
              _emit(ToolInvoked(name, args));
            },
            onToolEnd: (name, out) => _emit(ToolCompleted(name, out)),
          ));

      switch (result.reason) {
        case AgentStopReason.completed:
          final t = result.lastTurn;
          _updateTokenUsage(t, messages);
          _emit(AgentMessage(result.finalText,
              inputTokens: t?.promptTokens ?? _estimateTokens(messages),
              outputTokens: t?.completionTokens ?? (result.finalText.length / 3.2).ceil(),
              tokensPerSecond: t?.tokensPerSecond));
          if (result.toolsUsed.isNotEmpty) _recordExperience(input, result);
        case AgentStopReason.loop:
          _emit(AgentMessage(result.finalText));
        case AgentStopReason.cancelled:
          break;
        case AgentStopReason.maxSteps:
        case AgentStopReason.error:
          if (!streamedSinceTool && result.lastTurn?.content.isNotEmpty == true) {
            _emit(AgentMessage(result.lastTurn!.content));
          }
          _emit(AgentFailed(result.error ?? 'Bilinmeyen hata'));
      }
    } catch (e) {
      _emit(AgentFailed('Beklenmeyen hata: $e'));
    } finally {
      if (identical(_cancelToken, cancelToken)) _cancelToken = null;
      _ref.read(agentIsRunningProvider.notifier).state = false;
    }
  }

  // ------------------------------------------------------------ yardımcılar
  Future<bool> _ensureBackend(String apiUrl) async {
    final isLocal = apiUrl.contains('127.0.0.1') || apiUrl.contains('localhost');
    if (_ref.read(isBackendRunningProvider) || !isLocal) return true;
    _status('Model başlatılıyor...');
    try {
      await _ref.read(selectedModelProvider.notifier).startModel().timeout(const Duration(seconds: 180));
    } catch (e) {
      _emit(AgentFailed('Model motoru başlatılamadı: $e'));
      return false;
    }
    if (!_ref.read(isBackendRunningProvider)) {
      final detail = _ref.read(lastBackendStatusMessageProvider);
      _emit(AgentFailed(detail != null && detail.isNotEmpty
          ? 'Model motoru başlatılamadı: $detail'
          : 'Model motoru başlatılamadı. Ayarlar > Model Merkezi\'nden bir GGUF modeli seçin/indirin.'));
      return false;
    }
    return true;
  }

  String _memoryContext(String input, SettingsState settings) {
    final b = StringBuffer();
    try {
      final agents = [File(p.join(settings.skillsPath, 'AGENTS.md')), File(p.join(settings.skillsPath, 'AGENT.md'))]
          .where((f) => f.existsSync())
          .firstOrNull;
      if (agents != null) b.write('\n\n# KULLANICI YÖNERGELERİ\n${agents.readAsStringSync()}');
    } catch (_) {}
    try {
      final aegis = AegisService.instance.getRelevantContext(input, disabledSkills: settings.disabledSkills);
      if (aegis.isNotEmpty) {
        b.write('\n\n# BECERİLER VE GEÇMİŞ DENEYİM\n'
            'Bir beceri işe uygunsa önce use_skill ile tam talimatını yükle.\n$aegis');
      }
    } catch (_) {}
    return b.toString();
  }

  /// Sohbet geçmişinden model mesajları üretir. Araç ayrıntıları yerine
  /// kısa bir özet eklenir: yerel modellerin bağlamı sınırlıdır.
  Future<List<Map<String, dynamic>>> _history(String currentInput) async {
    ChatSession? session = _ref.read(activeSessionProvider);
    if (sessionId != null && session?.id != sessionId) {
      // Kullanıcı başka sohbete geçmiş olabilir: bu motorun kendi oturumunu kullan.
      session = await _ref.read(chatRepositoryProvider).loadSession(sessionId!);
    }
    if (session == null) return [];

    var msgs = session.messages;
    if (msgs.isNotEmpty && msgs.last.event is AgentStarted && (msgs.last.event as AgentStarted).goal == currentInput) {
      msgs = msgs.sublist(0, msgs.length - 1);
    }

    final out = <Map<String, dynamic>>[];
    final toolNotes = <String>[];
    String? pendingAssistant;

    void flushAssistant() {
      if (pendingAssistant == null && toolNotes.isEmpty) return;
      final note = toolNotes.isEmpty ? '' : '[Kullanılan araçlar: ${toolNotes.take(12).join('; ')}]\n';
      out.add({'role': 'assistant', 'content': '$note${pendingAssistant ?? ''}'.trim()});
      pendingAssistant = null;
      toolNotes.clear();
    }

    for (final m in msgs) {
      final e = m.event;
      if (e is AgentStarted) {
        flushAssistant();
        final hadImage = e.base64Images?.isNotEmpty ?? false;
        out.add({'role': 'user', 'content': hadImage ? '${e.goal}\n[görsel eklenmişti]' : e.goal});
      } else if (e is AgentMessage && e.message.trim().isNotEmpty) {
        pendingAssistant = e.message;
      } else if (e is ToolInvoked) {
        final arg = e.arguments['path'] ?? e.arguments['command'] ?? e.arguments['query'] ?? e.arguments['goal'] ?? '';
        final a = arg.toString();
        toolNotes.add('${e.toolName}(${a.length > 80 ? '${a.substring(0, 80)}…' : a})');
      } else if (e is AgentFailed) {
        pendingAssistant = '${pendingAssistant ?? ''}\n[Hata: ${e.error}]';
      }
    }
    flushAssistant();

    // Son ~24 mesaj (12 tur) yeterli; sunucu önbelleği için başlangıcı
    // 8'lik bloklara hizala ki önek mümkün olduğunca sabit kalsın.
    if (out.length > 24) {
      final start = ((out.length - 24) ~/ 8) * 8;
      final trimmed = out.sublist(start);
      while (trimmed.isNotEmpty && trimmed.first['role'] != 'user') {
        trimmed.removeAt(0);
      }
      return trimmed;
    }
    return out;
  }

  Future<Map<String, dynamic>> _userMessage(String input, List<String>? images, LlmClient llm) async {
    if (images == null || images.isEmpty) return {'role': 'user', 'content': input};

    if (await llm.supportsVision()) {
      final parts = <Map<String, dynamic>>[
        {'type': 'text', 'text': input}
      ];
      for (final img in images) {
        final uri = _imageDataUri(img);
        if (uri != null) {
          parts.add({
            'type': 'image_url',
            'image_url': {'url': uri}
          });
        }
      }
      return {'role': 'user', 'content': parts};
    }

    _status('Görsel OCR ile okunuyor...', details: 'Aktif modelin görsel desteği yok.');
    final texts = <String>[];
    for (final img in images) {
      final t = await _ocr(img);
      if (t != null && t.trim().isNotEmpty) texts.add(t);
    }
    return {
      'role': 'user',
      'content': texts.isEmpty
          ? '$input\n\n[Kullanıcı bir görsel ekledi; model görsel desteklemiyor ve OCR metin bulamadı.]'
          : '$input\n\n[Eklenen görselden OCR ile çıkarılan metin]:\n${texts.join('\n---\n')}',
    };
  }

  static String? _imageDataUri(String ref) {
    if (ref.startsWith('data:')) return ref;
    if (ref.startsWith('/') || ref.startsWith('file://') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(ref)) {
      final path = ref.startsWith('file://') ? Uri.parse(ref).toFilePath() : ref;
      final f = File(path);
      if (!f.existsSync()) return null;
      final ext = p.extension(path).toLowerCase();
      final mime = switch (ext) { '.png' => 'image/png', '.webp' => 'image/webp', '.gif' => 'image/gif', _ => 'image/jpeg' };
      return 'data:$mime;base64,${base64Encode(f.readAsBytesSync())}';
    }
    return 'data:image/jpeg;base64,$ref';
  }

  static Future<String?> _ocr(String ref) async {
    File? temp;
    try {
      String path;
      if (ref.startsWith('/') || ref.startsWith('file://') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(ref)) {
        path = ref.startsWith('file://') ? Uri.parse(ref).toFilePath() : ref;
      } else {
        final raw = ref.contains(',') ? ref.split(',').last : ref;
        temp = File(p.join(Directory.systemTemp.path, 'feride_ocr_${DateTime.now().microsecondsSinceEpoch}.png'));
        await temp.writeAsBytes(base64Decode(raw));
        path = temp.path;
      }
      final text = await FileService.extractContent(path);
      return text.startsWith('Hata') ? null : text;
    } catch (_) {
      return null;
    } finally {
      try {
        await temp?.delete();
      } catch (_) {}
    }
  }

  void _dispatchWorker(String goal, bool thinkingMode, ThinkingLevel level) {
    final id = 'job_${DateTime.now().millisecondsSinceEpoch}';
    _emit(JobStarted(id, goal));
    _ref.read(subagentsProvider.notifier).spawn(goal, onCompleted: (result) {
      _emit(JobCompleted(id, result));
      run('ARKA PLAN GÖREVİ TAMAMLANDI: "$goal"\nSonuç:\n$result\n\nBu sonucu kullanıcıya kısaca ve doğal bir dille söyle.',
          thinkingMode, 0,
          isLiveSession: _isCurrentRunLiveSession, thinkingLevel: level);
    });
  }

  void _updateTokenUsage(LlmTurn? t, List<Map<String, dynamic>> messages) {
    final total = (t?.promptTokens ?? _estimateTokens(messages)) + (t?.completionTokens ?? 0);
    _ref.read(tokenCountProvider.notifier).state = total;
    _ref.read(contextUsageProvider.notifier).state =
        (total / _ref.read(maxContextSizeProvider).toDouble()).clamp(0.0, 1.0);
  }

  static int _estimateTokens(List<Map<String, dynamic>> messages) {
    var chars = 0;
    for (final m in messages) {
      final c = m['content'];
      if (c is String) chars += c.length;
    }
    return (chars / 3.2).ceil();
  }

  void _recordExperience(String input, AgentLoopResult r) {
    try {
      String clip(String s, int n) => s.length > n ? '${s.substring(0, n)}...' : s;
      AegisService.instance.recordExperience(
        summary: 'İSTEK: ${clip(input, 120)}\nSONUÇ: ${clip(r.finalText, 200)}',
        toolsUsed: r.toolsUsed.toSet().join(', '),
        result: '${r.steps} adım',
        success: true,
      );
      _ref.read(experienceCountProvider.notifier).state = AegisService.instance.experienceCount();
    } catch (_) {}
  }
}

final agentEngineProvider = Provider.family<AgentEngine, String?>((ref, sessionId) {
  final engine = AgentEngine(ref, sessionId);
  ref.onDispose(engine.dispose);
  return engine;
});
