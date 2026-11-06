import 'mcp_service.dart';
import 'package:path/path.dart' as p;
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';
import '../features/chat/state.dart';
import '../aegis/aegis_providers.dart';
import '../aegis/aegis_service.dart';
import '../features/settings/settings_provider.dart';
import 'app_paths.dart';
import 'backend_manager.dart';
import 'file_service.dart';
import 'pty_sandbox.dart';
import '../harness/context_manager.dart';
import '../harness/progress_tracker.dart';
import 'tool_registry.dart';
import 'claude_tools.dart';

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
  AgentMessage(this.message,
      {this.inputTokens, this.outputTokens, this.tokensPerSecond});
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

// === GÖLGE AJAN (SHADOW AGENT) OLAYLARI ===

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

class JobAwaitingHuman extends AgentEvent {
  final String jobId;
  final String actionRequired;
  JobAwaitingHuman(this.jobId, this.actionRequired);
}

class AgentStep {
  final String description;
  AgentStep(this.description);
}

class AgentEngine {

  static Future<bool> _checkServerVisionSupport(String apiUrl) async {
    try {
      final dio = Dio();
      final res = await dio.get('$apiUrl/models',
          options: Options(receiveTimeout: const Duration(milliseconds: 1500)));
      if (res.statusCode == 200 && res.data is Map) {
        final data = res.data['data'];
        if (data is List && data.isNotEmpty) {
          final arch = data.first['architecture'];
          if (arch is Map && arch['input_modalities'] is List) {
            final modalities = (arch['input_modalities'] as List).cast<String>();
            return modalities.contains('image');
          }
        }
      }
    } catch (_) {}
    return false;
  }

  static Future<String?> _performOcrOnImage(String imageRef) async {
    File? tempFile;
    try {
      String filePath;
      if (imageRef.startsWith('/') || imageRef.startsWith('file://')) {
        filePath = imageRef.startsWith('file://') ? imageRef.substring(7) : imageRef;
      } else {
        var raw = imageRef;
        if (raw.contains(',')) {
          raw = raw.split(',').last;
        }
        final bytes = base64Decode(raw);
        final tempDir = Directory.systemTemp;
        tempFile = File(p.join(tempDir.path, 'ocr_${DateTime.now().microsecondsSinceEpoch}.png'));
        await tempFile.writeAsBytes(bytes);
        filePath = tempFile.path;
      }

      final f = File(filePath);
      if (await f.exists()) {
        // 1. Önce Python file_parser.py ile tam görsel analizi (Çözünürlük + EXIF + PyTesseract OCR)
        final pyBin = FileService.pythonBinary;
        final scriptToUse = AppPaths.scriptPath('file_parser.py');

        if (File(scriptToUse).existsSync()) {
          final res = await Process.run(
            pyBin,
            [scriptToUse, filePath],
            environment: AppPaths.buildSubprocessEnv(),
          );
          if (res.exitCode == 0 && res.stdout.toString().trim().isNotEmpty) {
            try {
              final data = jsonDecode(res.stdout.toString().trim());
              if (data['success'] == true && data['content'] != null) {
                return data['content'] as String;
              }
            } catch (_) {}
          }
        }

        // 2. Doğrudan tesseract CLI çağrısı (tur+eng ve eng fallback)
        final tessEnv = AppPaths.buildSubprocessEnv();
        for (final lang in ['tur+eng', 'tur', 'eng']) {
          final res = await Process.run(
            'tesseract',
            [filePath, 'stdout', '-l', lang],
            environment: tessEnv,
          );
          if (res.exitCode == 0) {
            final text = res.stdout.toString().trim();
            if (text.isNotEmpty) {
              return '### Görsel Analizi (${p.basename(filePath)})\n[Görselden Okunan Metinler (OCR)]:\n$text';
            }
          }
        }
      }
    } catch (e) {
      print('Tesseract OCR ayrıştırma hatası: $e');
    } finally {
      if (tempFile != null) {
        try {
          await tempFile.delete();
        } catch (_) {}
      }
    }
    return null;
  }

  final StreamController<AgentEvent> _controller =
      StreamController<AgentEvent>.broadcast();
  final Dio _dio = Dio();
  final Ref _ref;
  final String? sessionId;
  CancelToken? _cancelToken;
  bool _isCurrentRunLiveSession = false;
  bool get isCurrentRunLiveSession => _isCurrentRunLiveSession;

  AgentEngine(this._ref, [this.sessionId]) {
    _dio.options.connectTimeout = const Duration(seconds: 15);
    _dio.options.receiveTimeout = const Duration(minutes: 60);
  }

  Stream<AgentEvent> get events => _controller.stream;

  void _emit(AgentEvent event) {
    _controller.add(event);
    if (sessionId != null && !_isCurrentRunLiveSession) {
      _ref.read(activeSessionProvider.notifier).handleEngineEvent(sessionId!, event);
    }
  }

  void stop() {
    _cancelToken?.cancel('Kullanıcı tarafından durduruldu');
    PtySandbox.killAllActiveProcesses();
    _ref.read(agentIsRunningProvider.notifier).state = false;
  }

  /// Faz 6 & 8: Claude Code standartlarında net, doğrudan sistem promptu ve proje kuralları.
  static String buildSystemPrompt({
    required bool isLiveSession,
    required bool thinkingMode,
    required ThinkingLevel thinkingLevel,
    bool planMode = false,
    String agentSystemPrompt = "",
    String? workingDirectory,
  }) {
    if (isLiveSession) {
      return "Senin adın Feride. Aytuğ AVCI tarafından geliştirilen yapayzeka destekli bir asistanım demelisin. "
          "Doğal, samimi ama her zaman SAYGILI ve KİBAR bir Türkçe ile konuşuyorsun. Cevapların kısa ve anlaşılır olmalı. "
          "Uzun sürecek işlemlerde 'dispatch_worker' aracını çağırıp 'Arka planda işlemi başlattım' diyerek sohbete devam et." +
          agentSystemPrompt;
    }

    String prompt =
        "Sen FerIDE; Aytuğ AVCI tarafından geliştirilen, Claude Code standartlarında çalışan otonom bir yazılım mühendisi ve sistem asistanısın.\n\n"
        "TEMEL ÇALIŞMA İLKELERİ:\n"
        "1. Dosya İnceleme: Dosya okumak için 'read_file' veya 'read_document' kullan. Terminalden cat/head kullanma.\n"
        "2. Arama: Kod tabanında arama yapmak için 'grep_search' ve 'glob' kullan.\n"
        "3. Planlama & Todo: Karmaşık görevlerde adımları belirlemek için 'todo_write' kullan.\n"
        "4. Kod Yazma ve Düzenleme: Yeni dosya için 'write_to_file', var olan dosyayı değiştirmek için 'replace_file_content' kullan. Bash ile dosya yazmaktan kaçın.\n"
        "5. Komut Çalıştırma: 'run_command' aracını sadece derleme, test çalıştırma, paket yönetimi, git işlemleri ve servis yönetimi için kullan.\n"
        "6. Görev Tamamlama: İstenen işlem tamamlandığında DERHAL DUR ve kullanıcıya net, öz bir özet sun. Yan görevlere dalma, gereksiz konuşma yapma.\n"
        "7. Masaüstü/GUI: GUI veya arka plan servislerini 'background: true' parametresiyle başlat.\n"
        "8. Tablo ve Yapılandırılmış Çıktı: Karşılaştırmalar, mimari katmanlar, artı/eksi analizleri veya çok boyutlu veriler sunarken standart Markdown tabloları (| Kolon 1 | Kolon 2 |) kullan.\n"
        "9. Evrensel Dosya, Ofis, Medya ve AutoCAD Yeteneği: Word (.docx/.doc/.odt), Excel (.xlsx/.xls/.ods/.csv), PowerPoint (.pptx/.ppt/.odp), PDF (.pdf), Görsel/OCR (.png/.jpg/.webp/.tiff/.svg), Müzik/Ses (.mp3/.wav/.flac/.ogg/.m4a) ve AutoCAD (.dwg/.dxf) dosyalarını okumak ve anlamak için 'read_document', sıfırdan üretmek veya düzenlemek için 'edit_media_or_document', kullanıcının ekranında varsayılan uygulamayla açmak için 'open_file_in_system' aracını kullan.\n";

    if (planMode) {
      prompt += "\n[PLAN MODU AKTİF]: Bu oturumda dosyaları DEĞİŞTİRME. Sadece inceleme araçlarını (read_file, grep_search, glob) ve 'todo_write' aracını kullanarak adım adım detaylı bir uygulama planı hazırla ve kullanıcıya sun.\n";
    }

    final projectRules = ProjectRulesService.getProjectRules(workingDirectory ?? Directory.current.path);
    if (projectRules.isNotEmpty) {
      prompt += projectRules;
    }

    if (thinkingMode) {
      switch (thinkingLevel) {
        case ThinkingLevel.low:
          prompt += "\nKURAL: Kısaca düşün (<think>) ve yanıtla.\n";
          break;
        case ThinkingLevel.med:
          prompt += "\nKURAL: Adım adım düşün (<think>) ve mantıklı bir sonuca vararak yanıtla.\n";
          break;
        case ThinkingLevel.high:
          prompt += "\nKURAL: Derinlemesine analiz et, tüm olasılıkları düşün (<think>) ve kapsamlı yanıtla.\n";
          break;
        case ThinkingLevel.xHigh:
        case ThinkingLevel.max:
          prompt += "\nKURAL: Çok derin düşün, uç durumları değerlendir (<think>) ve kusursuz yanıtla.\n";
          break;
      }
    }

    return prompt + agentSystemPrompt;
  }

  Future<void> run(String input, bool thinkingMode, int currentTokens,
      {List<String>? base64Images,
      bool isLiveSession = false,
      ThinkingLevel thinkingLevel = ThinkingLevel.med}) async {
    _isCurrentRunLiveSession = isLiveSession;
    _ref.read(agentIsRunningProvider.notifier).state = true;
    _cancelToken = CancelToken();

    // Web'de model etiketi ("Gemma 12B (...)" / "Qwen 27B (...)") gerçek GGUF
    // ID'sine, taban URL ise seçilen motora (/v1 veya /v1-qwen) çevrilir.
    final _selectedLabel = _ref.read(selectedModelProvider);
    final configuredApiUrl = _ref.read(apiUrlProvider);
    String currentApiUrl = isLiveSession
        ? _ref.read(liveApiUrlProvider)
        : baseUrlForModel(_selectedLabel, customApiUrl: configuredApiUrl);
    String currentModel = modelForLabel(_selectedLabel);
    int currentMaxCtx = _ref.read(maxContextSizeProvider);

    // Read server n_ctx from /props if available
    try {
      final serverCtx = await ContextManager.fetchServerContextSize(currentApiUrl);
      if (serverCtx != null && serverCtx > 0) {
        currentMaxCtx = serverCtx;
        _ref.read(maxContextSizeProvider.notifier).state = serverCtx;
      }
    } catch (_) {}

    if (thinkingMode) {
      _emit(StepStarted(AgentStep('Bağlam analiz ediliyor...'),
          details: 'Yeni talep değerlendiriliyor...\nMesaj: $input'));
      await Future.delayed(const Duration(milliseconds: 500));
    }

    if (!_ref.read(isBackendRunningProvider) &&
        !isLiveSession &&
        currentApiUrl.contains('127.0.0.1')) {
      _emit(StepStarted(AgentStep('Model başlatılıyor (Yükleniyor)...')));
      try {
        await _ref
            .read(selectedModelProvider.notifier)
            .startModel()
            .timeout(const Duration(seconds: 130));
      } catch (e) {
        _emit(AgentFailed(
            'Model motoru başlatılırken kritik bir hata oluştu: $e'));
        _ref.read(agentIsRunningProvider.notifier).state = false;
        return;
      }

      // Başlatma denemesinden sonra hala çalışmıyorsa detaylı hata mesajını göster ve çık
      if (!_ref.read(isBackendRunningProvider)) {
        final detail = _ref.read(lastBackendStatusMessageProvider);
        _emit(AgentFailed(
            detail != null && detail.isNotEmpty
                ? 'Model motoru başlatılamadı: $detail'
                : 'Model motoru başlatılamadı! Ayarlar > Model Merkezi sekmesinden yerel bir GGUF modeli indirdiğinizden emin olun.'));
        _ref.read(agentIsRunningProvider.notifier).state = false;
        return;
      }
    }

    try {
      // Aegis: kazanılmış beceriler + geçmiş deneyimler system prompt'a enjekte edilir
      String aegisContext = '';
      try {
        aegisContext = AegisService.instance.getRelevantContext(
          input,
          disabledSkills: _ref.read(settingsProvider).disabledSkills,
        );
      } catch (_) {}

      // Skill & Agent configs
      String agentSystemPrompt = '';
      try {
        final skillsPath = _ref.read(settingsProvider).skillsPath;
        final rootDir = Directory(skillsPath);

        if (rootDir.existsSync()) {
          final agentsFile = File('$skillsPath/AGENTS.md');
          final agentFile = File('$skillsPath/AGENT.md');

          if (agentsFile.existsSync()) {
            agentSystemPrompt +=
                '\n\n# YÖNERGE (AGENTS)\n${agentsFile.readAsStringSync()}';
          } else if (agentFile.existsSync()) {
            agentSystemPrompt +=
                '\n\n# YÖNERGE (AGENT)\n${agentFile.readAsStringSync()}';
          }

          // Yetenekleri (Skills) tam metin olarak System Prompt'a gömmek yerine,
          // AegisService üzerinden indeksliyoruz. (Progressive Disclosure)
          // Bu sayede 40.000+ tokenlik context şişmesini önlüyoruz.
          // Not: Disk taraması açılışta ve ayarlar sekmesinde yapılır; her promptta tekrarlanmaz.
          final skillsDir = Directory('$skillsPath/skills');
          if (!skillsDir.existsSync()) {
            // Eğer doğrudan SKILL.md varsa (eski tip), sadece onu ekle
            final skillFile = File('$skillsPath/SKILL.md');
            if (skillFile.existsSync()) {
              agentSystemPrompt +=
                  '\n\n# YETENEKLER (SKILL)\n${skillFile.readAsStringSync()}';
            }
          }
        }
      } catch (e) {
        // ...
      }

      final activeSession = _ref.read(activeSessionProvider);

      // MCP Aktif Sunuculari Bilgisi
      try {
        final settings = _ref.read(settingsProvider);
        if (settings.mcpEnabled) {
          final activeServers = McpService.instance.servers
              .where((s) => s.isEnabled && settings.isMcpServerEnabled(s.name))
              .toList();
          if (activeServers.isNotEmpty) {
            agentSystemPrompt += "\n\n# AKTIF MCP SUNUCULARI (Model Context Protocol)\n";
            for (final s in activeServers) {
              agentSystemPrompt += '- ' + s.name + ' (' + s.transport + '): ' + s.description + '\n';
            }
          }
        }
      } catch (_) {}

      final isPlanMode = _ref.read(planModeProvider);
      final systemPrompt = buildSystemPrompt(
        isLiveSession: isLiveSession,
        thinkingMode: thinkingMode,
        thinkingLevel: thinkingLevel,
        planMode: isPlanMode,
        agentSystemPrompt: agentSystemPrompt,
      );

      List<Map<String, dynamic>> messagesPayload = [
        {
          "role": "system",
          "content": systemPrompt,
        }
      ];

      final List<String> previousToolOutputs = [];
      if (activeSession != null) {
        // Son eklenen mesaj şu anki kullanıcı promptu olabilir; mükerrerliği önlemek için ayır:
        final allMsgs = activeSession.messages;
        List<dynamic> historyMsgs = allMsgs;
        if (allMsgs.isNotEmpty && allMsgs.last.event is AgentStarted) {
          final lastEvent = allMsgs.last.event as AgentStarted;
          if (lastEvent.goal == input) {
            historyMsgs = allMsgs.sublist(0, allMsgs.length - 1);
          }
        }

        // Geçmişteki tüm araç çağrılarını ve çıktılarını takip et (Amnesia önleme):
        String? lastToolName;
        String? lastToolArgs;
        for (var msg in historyMsgs) {
          if (msg.event is ToolInvoked) {
            final ti = msg.event as ToolInvoked;
            lastToolName = ti.toolName;
            lastToolArgs = ti.arguments.entries
                .map((e) => '${e.key}: ${e.value}')
                .take(3)
                .join(', ');
          } else if (msg.event is ToolCompleted) {
            final tc = msg.event as ToolCompleted;
            final snippet = tc.output.length > 250
                ? '${tc.output.substring(0, 250)}... [özet]'
                : tc.output;
            final tName = lastToolName ?? tc.toolName;
            final argsStr = lastToolArgs != null ? ' ($lastToolArgs)' : '';
            previousToolOutputs.add('- $tName$argsStr -> $snippet');
            lastToolName = null;
            lastToolArgs = null;
          }
        }

        // Faz 3: Önbellek dostu 8'li blok pencere (son 12 mesaj temelinde)
        final n = historyMsgs.length;
        final start = n <= 12 ? 0 : ((n - 12) ~/ 8) * 8;
        final recentMessages = historyMsgs.sublist(start);

        for (var msg in recentMessages) {
          if (msg.event is AgentStarted) {
            final asEvent = msg.event as AgentStarted;
            // Geçmiş turlardaki base64 görselleri tekrar tekrar göndermeyerek VRAM ve token tasarrufu sağla
            if (asEvent.base64Images != null &&
                asEvent.base64Images!.isNotEmpty) {
              messagesPayload.add({
                "role": "user",
                "content": "${asEvent.goal}\n[Görsel önceki turda incelendi]"
              });
            } else {
              messagesPayload.add({"role": "user", "content": asEvent.goal});
            }
          } else if (msg.event is AgentMessage) {
            messagesPayload.add({
              "role": "assistant",
              "content": (msg.event as AgentMessage).message
            });
          }
        }
      }

      // Faz 3: Dinamik bağlamlar doğrudan geçerli kullanıcı mesajının başına eklenir.
      String finalInput = input;
      if (aegisContext.isNotEmpty) {
        finalInput = '[İLGİLİ BECERİLER VE GEÇMİŞ DENEYİM]:\n$aegisContext\n\n$finalInput';
      }
      if (previousToolOutputs.isNotEmpty) {
        final takenTools = previousToolOutputs.length > 15
            ? previousToolOutputs.sublist(previousToolOutputs.length - 15)
            : previousToolOutputs;
        finalInput = '[DAHA ÖNCEKİ ADIMLARDA ÇALIŞTIRILAN ARAÇLAR VE İNCELENEN DOSYALAR]:\n${takenTools.join("\n")}\n\n$finalInput';
      }
// Faz 4: Manuel <think> enjeksiyonu kaldırıldı (chat_template_kwargs ile doğal kontrol)

      if (base64Images != null && base64Images.isNotEmpty) {
        final supportsVision = await _checkServerVisionSupport(currentApiUrl);
        if (supportsVision) {
          List<Map<String, dynamic>> currentContentList = [
            {"type": "text", "text": finalInput}
          ];
          for (var b64 in base64Images) {
            String dataUri = b64;
            if (b64.startsWith('/') || b64.startsWith('file://')) {
              final fPath = b64.startsWith('file://') ? b64.substring(7) : b64;
              final f = File(fPath);
              if (f.existsSync()) {
                final bytes = f.readAsBytesSync();
                final encoded = base64Encode(bytes);
                final ext = p.extension(fPath).toLowerCase();
                final mime = ext == '.png'
                    ? 'image/png'
                    : (ext == '.webp' ? 'image/webp' : 'image/jpeg');
                dataUri = 'data:$mime;base64,$encoded';
              }
            } else {
              final prefix =
                  b64.startsWith('data:') ? '' : 'data:image/jpeg;base64,';
              dataUri = '$prefix$b64';
            }
            currentContentList.add({
              "type": "image_url",
              "image_url": {"url": dataUri}
            });
          }
          messagesPayload.add({"role": "user", "content": currentContentList});
        } else {
          _emit(StepStarted(AgentStep('Görsel analiz ediliyor (Tesseract OCR)...'),
              details: 'Aktif model metin tabanlı olduğu için yapıştırılan görsel OCR ile taranıyor.'));
          final ocrResults = <String>[];
          for (var b64 in base64Images) {
            final ocrText = await _performOcrOnImage(b64);
            if (ocrText != null && ocrText.isNotEmpty) {
              ocrResults.add(ocrText);
            }
          }
          if (ocrResults.isNotEmpty) {
            final joined = ocrResults.join('\n---\n');
            finalInput = '$finalInput\n\n[Kullanıcının Yapıştırdığı Ekran Görüntüsü / Görselden Çıkarılan Metin (OCR)]:\n$joined';
            _emit(StepStarted(
                AgentStep('✅ Görsel OCR analizi tamamlandı (${ocrResults.length} görsel incelendi)'),
                details: 'Görsel metinleri ve özellikleri başarıyla çıkarıldı.'));
          } else {
            finalInput = '$finalInput\n\n[Not: Kullanıcı bir görsel/ekran görüntüsü ekledi. Aktif yerel model Vision projektörüne sahip olmadığı için OCR metin analizi uygulandı ancak okunabilir metin bulunamadı.]';
            _emit(StepStarted(
                AgentStep('ℹ️ Görsel OCR analizi tamamlandı (Metin bulunamadı)'),
                details: 'Görsel üzerinde ayrıştırılabilir metin tespit edilemedi.'));
          }
          messagesPayload.add({"role": "user", "content": finalInput});
        }
      } else {
        messagesPayload.add({"role": "user", "content": finalInput});
      }

      bool agentFinished = false;
      int stepCount = 0;
      final bool isAutonomous = _ref.read(autonomousModeProvider);
      final int configuredSteps = _ref.read(settingsProvider).maxSteps;
      final int maxSteps = isAutonomous ? (configuredSteps * 2).clamp(150, 500) : configuredSteps;
      int retry503Count = 0;
      const int max503Retries = 40; // 40 * 3s = 120s max bekleme
      int transientErrCount = 0;
      const int maxTransientRetries = 5; // 500/502/503 geçici hatalarında 5 deneme
      const List<int> transientCodes = [500, 502, 503, 504, 429];
      final progressTracker = ProgressTracker();

      while (!agentFinished && stepCount < maxSteps) {
        stepCount++;

        // Faz 3: Bağlam bütçesi kontrolü ve akıllı tek seferlik sıkıştırma (önbellek korumalı)
        ContextManager.compactIfNeeded(
          messages: messagesPayload,
          maxContextTokens: currentMaxCtx,
          sessionId: activeSession?.id,
        );

        final stepDetails = 'Model: $currentModel | Mesaj sayısı: ${messagesPayload.length}';
        if (thinkingMode) {
          _emit(StepStarted(
              AgentStep('Düşünüyor ($_selectedLabel)...'),
              details: stepDetails));
        } else {
          _emit(StepStarted(
              AgentStep('Yanıt Bekleniyor ($_selectedLabel)...'),
              details: stepDetails));
        }

        // Plan Task 2: Sesli oturumda stream:true yapılarak anında görsel/işitsel geri bildirim sağlanır.
        // Not: Streaming açıkken Ollama üzerinden Tool çağrıları yakalamak zorlaşabilir.
        // Ancak canlı oturumda hızlı tepki (TTS için chunk-by-chunk akış) daha önemlidir.
        final isStreaming = true; // Her zaman streaming açık (manuel parsing destekli)

        final orderErrors = ContextManager.validateMessageOrder(messagesPayload);
        if (orderErrors.isNotEmpty) {
          print("[UYARI] Mesaj sırası doğrulama hataları tespit edildi: " + orderErrors.toString());
          try {
            final logDir = Directory(p.join(AppPaths.ferideDataDir, 'logs'));
            if (!logDir.existsSync()) logDir.createSync(recursive: true);
            final logFile = File(p.join(logDir.path, 'order_errors.log'));
            final errBody = orderErrors.join(String.fromCharCode(10));
            logFile.writeAsStringSync(
              DateTime.now().toIso8601String() + " [step $stepCount] Hatalar:" + String.fromCharCode(10) + errBody + String.fromCharCode(10) + String.fromCharCode(10),
              mode: FileMode.append,
            );
          } catch (_) {}
        }

        // KESİN GÜVENCE: Jinja template'inde "No user query found" hatasını önlemek için
        // messagesPayload içinde en az bir "user" rolü bulunmalıdır.
        if (!messagesPayload.any((m) => m['role'] == 'user')) {
          final insertIdx = messagesPayload.isNotEmpty && messagesPayload[0]['role'] == 'system' ? 1 : 0;
          messagesPayload.insert(insertIdx, {
            'role': 'user',
            'content': input.trim().isNotEmpty ? input : 'Lütfen göreve devam edin.',
          });
        }

        final bool effectiveThinking = isLiveSession ? false : thinkingMode;
        final requestData = {
              "model": currentModel,
              "messages": messagesPayload,
              "cache_prompt": true,
              "max_tokens": 8192,
              "chat_template_kwargs": {"enable_thinking": effectiveThinking},
              "temperature": isLiveSession ? 0.5 : 0.7,
              "stream": isStreaming,
              if (isStreaming) "stream_options": {"include_usage": true},
              "tools": ToolRegistry.getToolsForSession( // "tools": [

                isLiveSession: isLiveSession,
              ),
        };

        if (Platform.environment['FERIDE_DUMP_PAYLOAD'] == '1') {
          try {
            final logDir = Directory(p.join(AppPaths.ferideDataDir, 'logs'));
            if (!logDir.existsSync()) logDir.createSync(recursive: true);
            final dumpFile = File(p.join(logDir.path, 'payload_${sessionId ?? "default"}_step$stepCount.json'));
            dumpFile.writeAsStringSync(jsonEncode(requestData));
          } catch (_) {}
        }

        try {
          final response = await _dio.post(
            '$currentApiUrl/chat/completions',
            cancelToken: _cancelToken,
            options: Options(
              headers: {'Content-Type': 'application/json'},
              validateStatus: (status) => true,
              responseType: ResponseType.stream,
              sendTimeout: const Duration(seconds: 45),
              receiveTimeout: null, // Streaming modunda chunk aktığı sürece bağlantıyı kesme
            ),
            data: requestData,
          );

          if (response.statusCode == 200) {
            String replyOrig = '';
            String accumulatedReasoning = '';
            List<dynamic>? toolCalls;
            int? pTokens;
            int? cTokens;
            double? tps;
            int cacheN = 0;
            int promptN = 0;
            double promptMs = 0.0;
            int predictedN = 0;

            if (isStreaming) {
              // Herhangi bir token/chunk gelmeksizin 5 dakika donarsa zaman aşımına uğrat
              final stream = response.data.stream
                  .cast<List<int>>()
                  .transform(utf8.decoder)
                  .transform(const LineSplitter())
                  .timeout(const Duration(minutes: 5));
              final streamStopwatch = Stopwatch()..start();
              int lastMsgFlushMs = 0;
              int lastReasoningFlushMs = 0;
              bool hasToolCallTag = false;
              bool reasoningFinished = false;

              await for (final lineChunk in stream) {
                var line = lineChunk.trim();
                if (line.startsWith('data: ') && line != 'data: [DONE]') {
                  try {
                    final jsonData = jsonDecode(line.substring(6));

                    if (jsonData['usage'] != null) {
                      pTokens =
                          (jsonData['usage']['prompt_tokens'] as num?)?.toInt();
                      cTokens = (jsonData['usage']['completion_tokens'] as num?)
                          ?.toInt();
                      final totalTokens =
                          (jsonData['usage']['total_tokens'] as num?)
                                  ?.toInt() ??
                              ((pTokens ?? 0) + (cTokens ?? 0));
                      _ref.read(tokenCountProvider.notifier).state =
                          totalTokens;
                      _ref.read(contextUsageProvider.notifier).state =
                          (totalTokens /
                                  _ref.read(maxContextSizeProvider).toDouble())
                              .clamp(0.0, 1.0);
                    }
                    if (jsonData['timings'] != null) {
                      final t = jsonData['timings'];
                      if (t['predicted_per_second'] != null) {
                        tps = (t['predicted_per_second'] as num).toDouble();
                      }
                      if (t['cache_n'] != null) cacheN = (t['cache_n'] as num).toInt();
                      if (t['prompt_n'] != null) promptN = (t['prompt_n'] as num).toInt();
                      if (t['prompt_ms'] != null) promptMs = (t['prompt_ms'] as num).toDouble();
                      if (t['predicted_n'] != null) predictedN = (t['predicted_n'] as num).toInt();
                    }

                    final delta = jsonData['choices']?[0]?['delta'];
                    if (delta != null) {
                      final content = delta['content'];
                      final reasoning =
                          delta['reasoning'] ?? delta['reasoning_content'];
                      final deltaToolCalls = delta['tool_calls'];

                      if (deltaToolCalls != null) {
                        toolCalls ??= [];
                        for (var dtc in deltaToolCalls) {
                          int index = dtc['index'] ?? 0;
                          while (toolCalls.length <= index) {
                            toolCalls.add({
                              "id": dtc['id'] ??
                                  'call_${const Uuid().v4()}',
                              "type": "function",
                              "function": {
                                "name": dtc['function']?['name'] ?? '',
                                "arguments": ""
                              }
                            });
                          }
                          if (dtc['function']?['arguments'] != null) {
                            toolCalls[index]['function']['arguments'] +=
                                dtc['function']['arguments'];
                          }
                        }
                      }

                      if (reasoning != null &&
                          reasoning.toString().isNotEmpty) {
                        accumulatedReasoning += reasoning.toString();
                        final nowMs = streamStopwatch.elapsedMilliseconds;
                        if (thinkingMode && (nowMs - lastReasoningFlushMs >= 33)) {
                          lastReasoningFlushMs = nowMs;
                          _emit(ReasoningMessage(accumulatedReasoning));
                        } else if (!thinkingMode && (nowMs - lastReasoningFlushMs >= 350)) {
                          lastReasoningFlushMs = nowMs;
                          final estTokens = (accumulatedReasoning.length / 3.5).ceil();
                          _emit(StepStarted(
                            AgentStep('Model düşünüyor ($estTokens token)...'),
                            details: 'Yanıt hazırlanıyor ($currentModel)',
                          ));
                        }
                      }

                      if (content != null) {
                        // Reasoning'den content akışına geçildiğinde son reasoning durumunu bir defaya mahsus flush et
                        if (!reasoningFinished) {
                          reasoningFinished = true;
                          if (thinkingMode && accumulatedReasoning.isNotEmpty) {
                            _emit(ReasoningMessage(accumulatedReasoning));
                          }
                        }

                        replyOrig += content;

                        if (!hasToolCallTag && replyOrig.contains('<tool_call>')) {
                          hasToolCallTag = true;
                        }

                        final nowMs = streamStopwatch.elapsedMilliseconds;
                        if (nowMs - lastMsgFlushMs >= 33) {
                          lastMsgFlushMs = nowMs;
                          if (hasToolCallTag) {
                            int toolIndex = replyOrig.indexOf('<tool_call>');
                            String displayText =
                                replyOrig.substring(0, toolIndex).trim();
                            if (displayText.isNotEmpty) {
                              _emit(AgentMessage(displayText));
                            }
                          } else {
                            if (replyOrig.trim().isNotEmpty) {
                              _emit(AgentMessage(replyOrig));
                            }
                          }
                        }
                      }
                    }
                  } catch (_) {}
                }
              }

              // Final flush when stream ends
              // Sadece reasoning henüz tamamlanmadıysa (örn. hiç content üretmeden direkt tool çağırdıysa) flush et.
              // Content başladıysa reasoning zaten flush edilmiştir; AgentMessage'dan sonra tekrar ReasoningMessage emit edilmez!
              if (!reasoningFinished && thinkingMode && accumulatedReasoning.isNotEmpty) {
                _emit(ReasoningMessage(accumulatedReasoning));
                reasoningFinished = true;
              }

              // Faz 2: Performans günlüğü (~/.feride/logs/perf.jsonl)
              try {
                final logDir = Directory(p.join(AppPaths.ferideDataDir, 'logs'));
                if (!logDir.existsSync()) logDir.createSync(recursive: true);
                final perfFile = File(p.join(logDir.path, 'perf.jsonl'));
                int estTokens = 0;
                for (var m in messagesPayload) {
                  final c = m['content'];
                  if (c is String) {
                    estTokens += (c.length / 3.2).ceil();
                  }
                }
                final perfRecord = jsonEncode({
                  "ts": DateTime.now().toIso8601String(),
                  "session": sessionId ?? "default",
                  "step": stepCount,
                  "model": currentModel,
                  "msgs": messagesPayload.length,
                  "est_tokens": estTokens,
                  "prompt_n": promptN,
                  "cache_n": cacheN,
                  "prompt_ms": promptMs,
                  "predicted_n": predictedN,
                  "predicted_per_second": tps ?? 0.0,
                  "thinking": thinkingMode,
                  "reasoning_chars": accumulatedReasoning.length,
                  "event": "step",
                });
                perfFile.writeAsStringSync(perfRecord + String.fromCharCode(10), mode: FileMode.append);
              } catch (_) {}
              if (hasToolCallTag) {
                int toolIndex = replyOrig.indexOf('<tool_call>');
                String displayText = replyOrig.substring(0, toolIndex).trim();
                if (displayText.isNotEmpty) {
                  _emit(AgentMessage(displayText));
                }
              } else if (replyOrig.trim().isNotEmpty) {
                _emit(AgentMessage(replyOrig));
              }
            }

            // XML formatındaki tool_call'ları manuel parse et (bazı Ollama/Uncensored modelleri json tool_calls API'sini desteklemez)
            if (toolCalls == null || toolCalls.isEmpty) {
              final regex = RegExp(
                  r'<tool_call>\s*<function=([^>]+)>\s*(.*?)\s*</function>\s*</tool_call>',
                  dotAll: true);
              final matches = regex.allMatches(replyOrig);
              if (matches.isNotEmpty) {
                toolCalls = [];
                for (final match in matches) {
                  final funcName = match.group(1)?.trim() ?? '';
                  final paramBlock = match.group(2)?.trim() ?? '';

                  String argsJson = '{}';
                  if (paramBlock.startsWith('{') && paramBlock.endsWith('}')) {
                    argsJson = paramBlock;
                  } else {
                    final paramRegex = RegExp(
                        r'<parameter=([^>]+)>(.*?)</parameter>',
                        dotAll: true);
                    final paramMatches = paramRegex.allMatches(paramBlock);
                    Map<String, dynamic> args = {};
                    for (final pMatch in paramMatches) {
                      args[pMatch.group(1)?.trim() ?? ''] =
                          pMatch.group(2)?.trim() ?? '';
                    }
                    argsJson = jsonEncode(args);
                  }

                  toolCalls.add({
                    "function": {"name": funcName, "arguments": argsJson},
                    "id": "call_${const Uuid().v4()}"
                  });
                }
                replyOrig = replyOrig.replaceAll(regex, '').trim();
              }
            }

            String reply = replyOrig;

            if (toolCalls != null && toolCalls.isNotEmpty) {
              // Hata Koruması: Model yarım kesilirse (max tokens) geçersiz JSON üretmiş olabilir.
              // Geçersiz JSON'ı llama-server'a geri gönderirsek 500 hatası fırlatır!
              for (var tc in toolCalls) {
                if (tc['function'] != null &&
                    tc['function']['arguments'] != null) {
                  try {
                    jsonDecode(tc['function']['arguments']);
                  } catch (_) {
                    tc['function']['arguments'] = '{}';
                  }
                }
              }

              // Asistanın tool call isteğini geçmişe eklememiz şart
              messagesPayload.add({
                "role": "assistant",
                "content": reply,
                "tool_calls": toolCalls
              });

              for (var toolCall in toolCalls) {
                final functionCall = toolCall['function'];
                final toolName = functionCall['name'];
                final toolCallId = toolCall['id'] ??
                    'call_${const Uuid().v4()}';

                Map<String, dynamic> args = {};
                try {
                  args = jsonDecode(functionCall['arguments']);
                } catch (e) {
                  final parseErrMsg = 'Parametre JSON ayrıştırma hatası: $e\nSağlanan argüman: ${functionCall['arguments']}\nLütfen geçerli JSON formatında parametreler sağlayın.';
                  _emit(ToolInvoked(toolName, {}));
                  _emit(ToolCompleted(toolName, parseErrMsg));
                  messagesPayload.add({
                    "role": "tool",
                    "tool_call_id": toolCallId,
                    "name": toolName,
                    "content": parseErrMsg,
                  });
                  continue;
                }

                // Faz 5: Akıllı Yönlendirme ve Döngü Önleme (ProgressTracker)
                final progressStatus = progressTracker.recordToolCall(toolName, args);
                if (progressStatus == ProgressActionStatus.loopDetected) {
                  if (progressTracker.consecutiveLoopCount >= 3) {
                    const loopMsg = 'Aynı işlem art arda çok kez tekrarlandı. Süreç güvenliği için durduruluyor.';
                    _emit(AgentMessage(loopMsg));
                    agentFinished = true;
                    break;
                  }
                  final loopWarn = '[UYARI: Tekrarlanan Çağrı] "$toolName" aracı aynı parametrelerle daha önce çalıştırıldı. Tekrar çalıştırmak yerine mevcut sonuçları kullanarak analizinizi tamamlayın veya sonraki adıma geçin.';
                  _emit(ToolInvoked(toolName, args));
                  _emit(ToolCompleted(toolName, loopWarn));
                  messagesPayload.add({
                    "role": "tool",
                    "tool_call_id": toolCallId,
                    "name": toolName,
                    "content": loopWarn,
                  });
                  continue;
                }

                if (progressStatus == ProgressActionStatus.stalled) {
                  _emit(AgentMessage(
                    '[Sistem Hatırlatması: ${progressTracker.stepsSinceLastMutation} adımdır sadece okuma/inceleme yapılıyor. Yeterli bulgu toplandıysa planlama veya uygulama adımına geçebilirsiniz.]',
                  ));
                  messagesPayload.add({
                    "role": "user",
                    "content": "[Sistem Hatırlatması: Yeterli dosya incelemesi yapıldı. Lütfen şu ana kadarki bulgularınızı özetleyerek görevin kalan kısmını tamamlayın.]",
                  });
                } else if (progressStatus == ProgressActionStatus.warning) {
                  _emit(AgentMessage(
                    '[Sistem Notu: Son ${progressTracker.stepsSinceLastMutation} adımdır sadece okuma yapıldı.]',
                  ));
                  messagesPayload.add({
                    "role": "user",
                    "content": "[Sistem Notu: İnceleme verileri toplandıysa bir sonraki adıma (özet veya değişiklik) geçin.]",
                  });
                }



                if (toolName == 'spawn_agent') {
                  final goal = (args['goal'] ?? '') as String;
                  final maxSteps = (args['max_steps'] as num?)?.toInt() ?? 8;
                  _emit(ToolInvoked(toolName, args));
                  String subResult;
                  try {
                    // spawn -> state'e ekler ve arka planda çalıştırır;
                    // sonucu beklemek için engine'de doğrudan SubagentEngine kullanıyoruz
                    final engine = _ref.read(subagentsProvider.notifier);
                    subResult = await engine.spawnAndWait(
                        goal: goal, maxSteps: maxSteps);
                  } catch (e) {
                    subResult = 'Subagent hatası: $e';
                  }
                  _emit(
                      ToolCompleted(toolName, 'SUBAGENT SONUCU:\n$subResult'));
                  messagesPayload.add({
                    "role": "tool",
                    "tool_call_id": toolCallId,
                    "name": toolName,
                    "content": 'SUBAGENT SONUCU:\n$subResult'
                  });
                  continue;
                } else if (toolName == 'dispatch_worker') {
                  final goal = (args['goal'] ?? '') as String;
                  _emit(ToolInvoked(toolName, args));
                  final id = 'job_${DateTime.now().millisecondsSinceEpoch}';
                  _emit(JobStarted(id, goal));

                  try {
                    final subNotifier = _ref.read(subagentsProvider.notifier);
                    subNotifier.spawn(goal, onCompleted: (result) {
                      _emit(JobCompleted(id, result));
                      final prompt =
                          "GÖLGE AJAN BİLDİRİMİ (Tamamlanan Görev: $goal)\nSonuç:\n$result\nLütfen bu sonucu doğal bir dille kullanıcıya özetle/söyle.";
                      this.run(prompt, thinkingMode, currentTokens,
                          isLiveSession: isLiveSession,
                          thinkingLevel: thinkingLevel);
                    });
                    final msg = 'Görev arka plan ajanına devredildi.';
                    _emit(ToolCompleted(toolName, msg));
                    messagesPayload.add({
                      "role": "tool",
                      "tool_call_id": toolCallId,
                      "name": toolName,
                      "content": msg
                    });
                  } catch (e) {
                    _emit(ToolCompleted(toolName, 'Hata: $e'));
                  }
                  continue;
                } else if (toolName == 'check_market') {
                  final asset = (args['asset_type'] ?? 'crypto') as String;
                  final sym = (args['symbol'] ?? 'BTC') as String;
                  _emit(ToolInvoked(toolName, args));
                  var out = '';
                  try {
                    final script = AppPaths.scriptPath('finance_engine.py');
                    final pr = await Process.run(
                      AppPaths.resolvePython(),
                      [script, asset, sym],
                      environment: AppPaths.buildSubprocessEnv(),
                    );
                    out = pr.stdout.toString().trim();
                    if (out.isEmpty) out = pr.stderr.toString();
                  } catch (e) {
                    out = 'Finans motoru çalıştırılamadı: $e';
                  }
                  _emit(ToolCompleted(toolName, out));
                  messagesPayload.add({
                    "role": "tool",
                    "tool_call_id": toolCallId,
                    "name": toolName,
                    "content": out
                  });
                  continue;
                } else if (toolName == 'analyze_market') {
                  final sym = (args['symbol'] ?? 'BTC-USD') as String;
                  _emit(ToolInvoked(toolName, args));
                  var out = '';
                  try {
                    final script = AppPaths.scriptPath('finance_analyzer.py');
                    final pr = await Process.run(
                      AppPaths.resolvePython(),
                      [script, sym],
                      environment: AppPaths.buildSubprocessEnv(),
                    );
                    out = pr.stdout.toString().trim();
                    if (out.isEmpty) out = pr.stderr.toString();
                  } catch (e) {
                    out = 'Analiz motoru çalıştırılamadı: $e';
                  }
                  _emit(ToolCompleted(toolName, out));
                  messagesPayload.add({
                    "role": "tool",
                    "tool_call_id": toolCallId,
                    "name": toolName,
                    "content": out
                  });
                  continue;
                } else if (toolName == 'save_skill') {
                  final name = (args['name'] ?? '') as String;
                  final desc = (args['description'] ?? '') as String;
                  final content =
                      (args['content'] ?? args['instructions'] ?? '') as String;
                  _emit(ToolInvoked(toolName, args));
                  String out;
                  if (name.isEmpty || content.isEmpty) {
                    out = 'Hata: name ve instructions/content zorunlu.';
                  } else {
                    try {
                      AegisService.instance.saveSkill(
                          name: name, description: desc, content: content);
                      _ref.read(skillsProvider.notifier).refresh();
                      out =
                          'Beceri kaydedildi: $name (toplam ${AegisService.instance.listSkills().length} beceri)';
                    } catch (e) {
                      out = 'Beceri kaydedilemedi: $e';
                    }
                  }
                  _emit(ToolCompleted(toolName, out));
                  messagesPayload.add({
                    "role": "tool",
                    "tool_call_id": toolCallId,
                    "name": toolName,
                    "content": out
                  });
                  continue;
                } else if (toolName == 'use_skill') {
                  final name = (args['name'] ?? '') as String;
                  _emit(ToolInvoked(toolName, args));
                  String out;
                  try {
                    final skill = AegisService.instance.loadSkill(name);
                    if (skill == null) {
                      out =
                          'Beceri bulunamadı: $name (indeksten doğru adı kullan)';
                    } else {
                      AegisService.instance.bumpSkillUse(name);
                      _ref.read(skillsProvider.notifier).refresh();
                      out =
                          'BECERİ YÜKLENDİ: ${skill.name}\n\n${skill.content}';
                    }
                  } catch (e) {
                    out = 'Beceri yüklenemedi: $e';
                  }
                  _emit(ToolCompleted(toolName, out));
                  messagesPayload.add({
                    "role": "tool",
                    "tool_call_id": toolCallId,
                    "name": toolName,
                    "content": out
                  });
                  continue;
                } else if (toolName == 'mcp_call') {
                  final serverName = (args['server_name'] ?? '') as String;
                  final mcpTool = (args['tool_name'] ?? '') as String;
                  final toolArgs = Map<String, dynamic>.from((args['arguments'] as Map?) ?? {});
                  _emit(ToolInvoked(toolName, args));
                  String out;
                  try {
                    final server = McpService.instance.servers.firstWhere(
                      (s) => s.name.toLowerCase() == serverName.toLowerCase(),
                      orElse: () => throw 'MCP Sunucusu bulunamadı: $serverName',
                    );
                    if (!server.isEnabled) {
                      out = 'Hata: $serverName MCP sunucusu Ayarlar > MCP Ayarları sekmesinde devre dışı.';
                    } else {
                      final timeoutSec = _ref.read(settingsProvider).mcpTimeoutSeconds;
                      out = await McpService.instance
                          .callTool(server, mcpTool, toolArgs,
                              timeoutSeconds: timeoutSec);
                    }
                  } catch (e) {
                    out = 'MCP Çağrı Hatası: $e';
                  }
                  _emit(ToolCompleted(toolName, out));
                  messagesPayload.add({
                    "role": "tool",
                    "tool_call_id": toolCallId,
                    "name": toolName,
                    "content": out
                  });
                  continue;
                } else if (toolName == 'record_experience') {
                  final summary = (args['summary'] ?? '') as String;
                  final toolsUsed = (args['tools_used'] ?? '') as String;
                  final success = (args['success'] as bool?) ?? true;
                  _emit(ToolInvoked(toolName, args));
                  String out;
                  try {
                    AegisService.instance.recordExperience(
                        summary: summary,
                        toolsUsed: toolsUsed,
                        success: success);
                    _ref.read(experienceCountProvider.notifier).state =
                        AegisService.instance.experienceCount();
                    out = 'Deneyim hafızaya yazıldı.';
                  } catch (e) {
                    out = 'Deneyim yazılamadı: $e';
                  }
                  _emit(ToolCompleted(toolName, out));
                  messagesPayload.add({
                    "role": "tool",
                    "tool_call_id": toolCallId,
                    "name": toolName,
                    "content": out
                  });
                  continue;
                } else if (toolName == 'run_command') {
                  final cmd = (args['command'] ?? '') as String;
                  final bool explicitBg = args['background'] == true;
                  _emit(ToolInvoked(toolName, args));

                  String commandOutput = '';
                  if (cmd.trim().isEmpty) {
                    commandOutput =
                        'Hata: "command" parametresi boş! Lütfen çalıştırmak için gerçek bir komut sağla veya aracı kullanmayı bırakıp metin ile yanıt ver.';
                  } else {
                    final lowerCmd = cmd.trim().toLowerCase();
                    final isGui = explicitBg ||
                        RegExp(r'(?:^|[;&|]\s*)(brave|brave-browser|firefox|chrome|google-chrome|chromium|dolphin|nautilus|thunar|vlc|gimp|xdg-open|gedit|kate|kwrite|evince|okular|obs|blender)\b')
                            .hasMatch(lowerCmd);

                    if (isGui) {
                      try {
                        final (shExe, shArgs) = Platform.isWindows
                            ? ('powershell', ['-NoProfile', '-Command', 'Start-Process $cmd'])
                            : ('bash', ['-c', 'setsid nohup $cmd >/dev/null 2>&1 &']);
                        await Process.start(
                          shExe,
                          shArgs,
                          mode: ProcessStartMode.detached,
                        );
                        commandOutput =
                            'Uygulama/komut arka planda başarıyla başlatıldı (ayrık süreç oluşturuldu, sistem bloke edilmedi).';
                      } catch (e) {
                        commandOutput = 'Arka plan süreci başlatılamadı: $e';
                      }
                    } else {
                      try {
                        final isRea = lowerCmd.startsWith('rea ') || lowerCmd.contains(' rea ');
                        final timeoutSec = isRea ? 300 : 120;
                        final (shExe, shArgs) = AppPaths.shellCommand(cmd);
                        final sandboxRes = await PtySandbox.runCommand(
                          shExe,
                          shArgs,
                          timeout: Duration(seconds: timeoutSec),
                        );
                        if (sandboxRes.timedOut) {
                          commandOutput = 'HATA: Komut $timeoutSec saniyelik zaman aşımına uğradı ve tüm alt süreçleriyle birlikte sonlandırıldı.\n'
                              'STDOUT:\n${sandboxRes.stdout}\nSTDERR:\n${sandboxRes.stderr}';
                        } else {
                          commandOutput =
                              'STDOUT:\n${sandboxRes.stdout}\nSTDERR:\n${sandboxRes.stderr}';
                        }
                        if (commandOutput.length > 8000) {
                          commandOutput = commandOutput.substring(0, 8000) +
                              '\n...[KESİLDİ - ÇIKTI ÇOK UZUN]';
                        }
                        if (commandOutput.trim().isEmpty) {
                          commandOutput =
                              'Komut başarılı şekilde çalıştı ama çıktı üretmedi.';
                        }
                      } catch (e) {
                        commandOutput = 'Komut çalıştırılamadı: $e';
                      }
                    }
                  }

                  _emit(ToolCompleted(toolName, commandOutput));

                  messagesPayload.add({
                    "role": "tool",
                    "tool_call_id": toolCallId,
                    "name": toolName,
                    "content": commandOutput
                  });
                } else if (toolName == 'search_web') {
                  final query = (args['query'] ?? '').toString();
                  _emit(ToolInvoked(toolName, args));
                  String out = '';
                  try {
                    final script = AppPaths.scriptPath('search_engine.py');
                    final res = await Process.run(
                      AppPaths.resolvePython(),
                      [script, query],
                      environment: AppPaths.buildSubprocessEnv(),
                    ).timeout(const Duration(seconds: 30));
                    out = res.stdout.toString().trim();
                    if (out.isEmpty) out = res.stderr.toString().trim();
                  } catch (e) {
                    out = 'Hata: $e';
                  }
                  _emit(ToolCompleted(toolName, out));
                  messagesPayload.add({
                    "role": "tool",
                    "tool_call_id": toolCallId,
                    "name": toolName,
                    "content": out
                  });
                } else if (toolName == 'read_url_content') {
                  final url = args['url'] ?? '';
                  _emit(ToolInvoked(toolName, args));
                  String out = '';
                  try {
                    final res = await Process.run('curl', [
                      '-sL',
                      '--max-time', '20',
                      '--max-filesize', '5242880',
                      url,
                    ]);
                    out = res.stdout.toString();
                    if (out.length > 12000) {
                      out = out.substring(0, 12000) + '...[Kesildi]';
                    }
                    if (out.trim().isEmpty && res.stderr.toString().isNotEmpty) {
                      out = 'Hata: ${res.stderr}';
                    }
                  } catch (e) {
                    out = 'Hata: $e';
                  }
                  _emit(ToolCompleted(toolName, out));
                  messagesPayload.add({
                    "role": "tool",
                    "tool_call_id": toolCallId,
                    "name": toolName,
                    "content": out
                  });
                } else if (toolName == 'read_document') {
                  final path = (args['path'] ?? '').toString();
                  _emit(ToolInvoked(toolName, args));
                  String out = '';
                  try {
                    out = await FileService.extractContent(path);
                    if (out.length > 14000) {
                      out =
                          '${out.substring(0, 14000)}\n...[İçerik çok uzun olduğu için ilk 14.000 karakter gösterildi]';
                    }
                  } catch (e) {
                    out = 'Hata: $e';
                  }
                  _emit(ToolCompleted(toolName, out));
                  messagesPayload.add({
                    "role": "tool",
                    "tool_call_id": toolCallId,
                    "name": toolName,
                    "content": out
                  });
                } else if (toolName == 'edit_media_or_document') {
                  _emit(ToolInvoked(toolName, args));
                  final out = await FileService.runFileStudio(args);
                  _emit(ToolCompleted(toolName, out));
                  messagesPayload.add({
                    "role": "tool",
                    "tool_call_id": toolCallId,
                    "name": toolName,
                    "content": out
                  });
                } else if (toolName == 'open_file_in_system') {
                  final targetPath = (args['path'] ?? '').toString();
                  _emit(ToolInvoked(toolName, args));
                  final out = await FileService.openInSystem(targetPath);
                  _emit(ToolCompleted(toolName, out));
                  messagesPayload.add({
                    "role": "tool",
                    "tool_call_id": toolCallId,
                    "name": toolName,
                    "content": out
                  });
                } else if (toolName == 'read_file') {
                  final path = (args['path'] ?? '') as String;
                  final int offset = (args['offset'] as int?) ?? 0;
                  final int limit = (args['limit'] as int?) ?? 500;
                  _emit(ToolInvoked(toolName, args));
                  String out = '';
                  try {
                    final file = File(path);
                    if (!await file.exists()) {
                      out = 'Hata: Dosya bulunamadı ($path)';
                    } else {
                      final ext = p.extension(path).toLowerCase();
                      const richDocExts = {
                        '.pdf', '.docx', '.doc', '.odt', '.rtf',
                        '.xlsx', '.xls', '.ods', '.pptx', '.ppt', '.odp',
                        '.dwg', '.dxf',
                        '.mp3', '.wav', '.m4a', '.ogg', '.flac', '.aac', '.opus',
                        '.png', '.jpg', '.jpeg', '.webp', '.bmp', '.tiff', '.tif',
                      };
                      if (richDocExts.contains(ext)) {
                        out = await FileService.extractContent(path);
                      } else {
                        final stat = await file.stat();
                        final raf = await file.open(mode: FileMode.read);
                        final headerBytes = await raf.read(512);
                        await raf.close();

                        if (headerBytes.contains(0)) {
                          out = 'Hata: Bu dosya ikili (binary) bir formattadır ve düz metin olarak okunamaz. İnceleme için "read_document" aracını kullanın.';
                        } else {
                          // OOM Koruması: Tek satırlık devasa dosyalarda bellek patlamasını önlemek için akışı 4MB ile sınırla
                          final lines = await file
                              .openRead(0, 4 * 1024 * 1024)
                              .transform(const Utf8Decoder(allowMalformed: true))
                              .transform(const LineSplitter())
                              .skip(offset)
                              .take(limit)
                              .toList();
                          out = lines.join('\n');
                          if (stat.size > 256 * 1024 && lines.length >= limit) {
                            out += '\n...[Dosya ${stat.size} bayt; $offset. satırdan itibaren ilk $limit satır gösterildi]';
                          }
                        }
                      }
                    }
                    if (out.length > 14000) {
                      out = '${out.substring(0, 14000)}...[Kesildi]';
                    }
                  } catch (e) {
                    out = 'Hata: $e';
                  }
                  _emit(ToolCompleted(toolName, out));
                  messagesPayload.add({
                    "role": "tool",
                    "tool_call_id": toolCallId,
                    "name": toolName,
                    "content": out
                  });
                } else if (toolName == 'todo_write') {
                  _emit(ToolInvoked(toolName, args));
                  String out = '';
                  try {
                    final rawTodos = args['todos'];
                    final List<TodoItem> todosList = [];
                    if (rawTodos is List) {
                      for (var t in rawTodos) {
                        if (t is Map<String, dynamic>) {
                          todosList.add(TodoItem.fromMap(t));
                        } else if (t is Map) {
                          todosList.add(TodoItem.fromMap(Map<String, dynamic>.from(t)));
                        }
                      }
                    }
                    _emit(TodoUpdated(todosList));
                    try {
                      final todoDir = Directory(p.join(AppPaths.ferideDataDir, 'todos'));
                      if (!todoDir.existsSync()) todoDir.createSync(recursive: true);
                      final todoFile = File(p.join(todoDir.path, '${activeSession?.id ?? "default"}.json'));
                      todoFile.writeAsStringSync(jsonEncode(todosList.map((e) => e.toMap()).toList()));
                    } catch (_) {}
                    out = 'Görev listesi başarıyla güncellendi (${todosList.length} adım).';
                  } catch (e) {
                    out = 'Todo hatası: $e';
                  }
                  _emit(ToolCompleted(toolName, out));
                  messagesPayload.add({
                    "role": "tool",
                    "tool_call_id": toolCallId,
                    "name": toolName,
                    "content": out
                  });
                } else if (toolName == 'grep_search') {
                  final query = (args['query'] ?? '') as String;
                  final path = args['path'] as String?;
                  final caseInsensitive = (args['case_insensitive'] as bool?) ?? true;
                  _emit(ToolInvoked(toolName, args));
                  final out = await GrepSearchService.search(
                    query: query,
                    path: path,
                    caseInsensitive: caseInsensitive,
                  );
                  _emit(ToolCompleted(toolName, out));
                  messagesPayload.add({
                    "role": "tool",
                    "tool_call_id": toolCallId,
                    "name": toolName,
                    "content": out
                  });
                } else if (toolName == 'glob') {
                  final pattern = (args['pattern'] ?? '') as String;
                  final path = args['path'] as String?;
                  _emit(ToolInvoked(toolName, args));
                  final out = await GlobService.findFiles(
                    pattern: pattern,
                    path: path,
                  );
                  _emit(ToolCompleted(toolName, out));
                  messagesPayload.add({
                    "role": "tool",
                    "tool_call_id": toolCallId,
                    "name": toolName,
                    "content": out
                  });
                } else if (toolName == 'write_to_file') {
                  final path = args['path'] ?? '';
                  final content = args['content'] ?? '';
                  _emit(ToolInvoked(toolName, args));
                  String out = '';
                  try {
                    final file = File(path);
                    if (!await file.parent.exists()) {
                      await file.parent.create(recursive: true);
                    }
                    if (await file.exists()) {
                      await CheckpointService.instance.createCheckpoint(path);
                    }
                    await file.writeAsString(content);
                    out = 'Dosya başarıyla yazıldı: $path';

                    final validationWarning = await CodeValidator.validateFile(path);
                    if (validationWarning != null) {
                      out += '\n\n$validationWarning';
                    }
                  } catch (e) {
                    out = 'Hata: $e';
                  }
                  _emit(ToolCompleted(toolName, out));
                  messagesPayload.add({
                    "role": "tool",
                    "tool_call_id": toolCallId,
                    "name": toolName,
                    "content": out
                  });
                } else if (toolName == 'replace_file_content') {
                  final path = args['path'] ?? '';
                  final target = args['target'] ?? '';
                  final replacement = args['replacement'] ?? '';
                  _emit(ToolInvoked(toolName, args));
                  String out = '';
                  try {
                    final file = File(path);
                    if (!await file.exists()) {
                      out = 'Hata: Dosya bulunamadı: $path';
                    } else {
                      String text = await file.readAsString();
                      final count = target.isEmpty ? 0 : target.allMatches(text).length;
                      if (count == 0) {
                        out = 'Hata: Hedef metin ("target") dosyada bulunamadı. Lütfen önce "read_file" ile dosyanın güncel halini oku ve "target" parametresini tam satırlarıyla eşleşecek şekilde ver.';
                      } else if (count > 1) {
                        out = 'Hata: Hedef metin ("target") dosya içinde birden fazla yerde ($count kez) geçiyor. Yanlış yeri değiştirmemek için hedef bloğun öncesine veya sonrasına birkaç benzersiz satır daha ekleyerek tekilleştir.';
                      } else {
                        await CheckpointService.instance.createCheckpoint(path);
                        text = text.replaceFirst(target, replacement);
                        await file.writeAsString(text);
                        out = 'Değişiklik başarılı: $path';

                        final validationWarning = await CodeValidator.validateFile(path);
                        if (validationWarning != null) {
                          out += '\n\n$validationWarning';
                        }
                      }
                    }
                  } catch (e) {
                    out = 'Hata: $e';
                  }
                  _emit(ToolCompleted(toolName, out));
                  messagesPayload.add({
                    "role": "tool",
                    "tool_call_id": toolCallId,
                    "name": toolName,
                    "content": out
                  });
                } else {
                  // Bilinmeyen araç
                  _emit(ToolCompleted(toolName, "Hata: '$toolName' adında bir araç tanımlı değil."));
                  messagesPayload.add({
                    "role": "tool",
                    "tool_call_id": toolCallId,
                    "name": toolName,
                    "content": "Hata: '$toolName' adında bir araç tanımlı değil."
                  });
                }
              }
              // Araçlar eklendi, while döngüsü devam edip tekrar API isteği yapacak
              _emit(StepStarted(
                  AgentStep('Araç sonuçları değerlendiriliyor...'),
                  details: 'Çağrılan araç sayısı: ${toolCalls.length} | Toplam mesaj: ${messagesPayload.length}'));
              continue;
            } else {
              // Tool call yoksa döngüyü bitir ve mesajı yayınla (token ve TPS metrikleri ile)
              if (reply.trim().isNotEmpty) {
                if (pTokens == null || cTokens == null) {
                  cTokens ??= (reply.length / 3.2).ceil();
                  if (pTokens == null) {
                    int approxInput = 0;
                    for (final msg in messagesPayload) {
                      final c = msg['content'];
                      if (c is String) {
                        approxInput += (c.length / 3.2).ceil();
                      }
                    }
                    pTokens = approxInput;
                  }
                  final totalEst = pTokens + cTokens;
                  _ref.read(tokenCountProvider.notifier).state = totalEst;
                  _ref.read(contextUsageProvider.notifier).state =
                      (totalEst / _ref.read(maxContextSizeProvider).toDouble())
                          .clamp(0.0, 1.0);
                }
                _emit(AgentMessage(reply,
                    inputTokens: pTokens,
                    outputTokens: cTokens,
                    tokensPerSecond: tps));
              } else if (accumulatedReasoning.trim().isNotEmpty && !thinkingMode) {
                // Model tüm yanıtını reasoning içine yazmışsa ve content üretmediyse, reasoning'i kullanıcıya göster!
                _emit(AgentMessage(accumulatedReasoning.trim(),
                    inputTokens: pTokens,
                    outputTokens: cTokens ?? (accumulatedReasoning.length / 3.2).ceil(),
                    tokensPerSecond: tps));
              } else {
                _emit(AgentFailed('Model boş yanıt döndürdü veya bağlantı erken kapandı. Lütfen modelin aktif olduğunu kontrol edin.'));
              }
              // Aegis: görev otomatik hafızaya işlenir (sonraki seanslar daha akıllı başlar)
              // P1-13: Yalnızca araç kullanılan veya çok adımlı başarılı işlemler deneyim olarak kaydedilir.
              if (stepCount > 1) {
                try {
                  final shortInput = input.length > 120
                      ? '${input.substring(0, 120)}...'
                      : input;
                  final shortReply = reply.length > 200
                      ? '${reply.substring(0, 200)}...'
                      : reply;
                  AegisService.instance.recordExperience(
                    summary: 'SORU: $shortInput\nSONUÇ: $shortReply',
                    result: stepCount.toString(),
                    success: true,
                  );
                  _ref.read(experienceCountProvider.notifier).state =
                      AegisService.instance.experienceCount();
                } catch (_) {}
              }
              retry503Count = 0; // Başarılı 200 yanıtında retry sayacını sıfırla
              transientErrCount = 0;
              agentFinished = true;
            }
          } else if (response.statusCode == 503) {
            // Model yükleniyor durumu (llama-server 503 döner)
            stepCount--; // 503 denemeleri kullanıcı/ajan adımı sayılmamalı
            retry503Count++;
            if (retry503Count > max503Retries) {
              _emit(AgentFailed(
                  'Model yüklenemedi: Sunucu 120 saniyeden uzun süredir 503 (yükleniyor) yanıtı veriyor. Lütfen sunucuyu kontrol edin.'));
              agentFinished = true;
              break;
            }
            _emit(StepStarted(AgentStep(
                'Model RAM/VRAM\'e yükleniyor ($retry503Count/$max503Retries, lütfen bekleyin)...')));
            await Future.delayed(const Duration(seconds: 3));
          } else {
            if (response.statusCode == 400) {
              _emit(AgentFailed(
                  'API Hatası [400]: Bağlam (Context) sınırı aşıldı! Gönderilen geçmiş mesajların toplam boyutu, modelin kapasitesinden büyük. Lütfen "Yeni Sohbet" başlatın veya sunucunuzu (llama-server) daha yüksek bir --ctx-size ile başlatın.'));
            } else if (transientCodes.contains(response.statusCode)) {
              // Geçici hata (500/502/504/429): sunucu model yüklerken veya
              // yoğunlukta geçici yanıt veriyor olabilir. Otomatik yeniden dene.
              stepCount--; // denemeler kullanıcı adımı sayılmamalı
              transientErrCount++;
              if (transientErrCount > maxTransientRetries) {
                String serverMsg = '';
                try {
                  if (response.data is Map && response.data['error'] != null) {
                    final err = response.data['error'];
                    if (err is Map && err['message'] != null) {
                      serverMsg = '\nDetay: ${err['message']}';
                    }
                  }
                } catch (_) {}
                _emit(AgentFailed(
                    'API Hatası [${response.statusCode}]: Sunucu yanıt vermedi (5 kez yeniden denendi).$serverMsg\nLütfen sunucunuzun "$currentApiUrl" adresinde çalıştığından emin olun.'));
                agentFinished = true;
                break;
              }
              final waitSec = transientErrCount; // 1s, 2s, 3s... (yumuşak backoff)
              _emit(StepStarted(AgentStep(
                  'Sunucu geçici hata verdi (HTTP ${response.statusCode}). $waitSec sn sonra yeniden denenecek ($transientErrCount/$maxTransientRetries)...')));
              await Future.delayed(Duration(seconds: waitSec));
            } else {
              String serverMsg = '';
              try {
                if (response.data is Map && response.data['error'] != null) {
                  final err = response.data['error'];
                  if (err is Map && err['message'] != null) {
                    serverMsg = '\nDetay: ${err['message']}';
                  }
                }
              } catch (_) {}
              _emit(AgentFailed(
                  'API Hatası [${response.statusCode}]: Sunucu yanıt vermedi.$serverMsg\nLütfen sunucunuzun "$currentApiUrl" adresinde çalıştığından emin olun.'));
              agentFinished = true;
            }
          }
        } catch (e) {
          if (e is DioException && e.type == DioExceptionType.cancel) {
            agentFinished = true;
          } else if (e is DioException && e.response != null) {
            final res = e.response!;
            String errMsg =
                'API Hatası [${res.statusCode}]: Sunucu hata döndürdü.';
            try {
              if (res.data is Map && res.data['error'] != null) {
                final err = res.data['error'];
                if (err is Map && err['message'] != null) {
                  final msg = err['message'].toString();
                  if (msg.contains('mmproj') ||
                      msg.contains('image input is not supported')) {
                    errMsg =
                        '⚠️ Görsel Desteği Hatası: Model Vision (mmproj) eklentisi olmadan başlatılmış. Lütfen modeli yeniden başlatın.';
                  } else {
                    errMsg += '\nDetay: $msg';
                  }
                }
              }
            } catch (_) {}
            _emit(AgentFailed(errMsg));
            agentFinished = true;
          } else {
            _emit(AgentFailed(
                'Bağlantı Hatası: Localhost sunucusuna ulaşılamadı. Detay: $e'));
            agentFinished = true;
          }
        }
      }

      if (!agentFinished && stepCount >= maxSteps) {
        _emit(AgentFailed(
            'Maksimum adım sınırına ($maxSteps adım) ulaşıldı. "Devam et" diyerek işleme kaldığınız yerden devam edebilirsiniz.'));
      }
    } catch (e) {
      if (e is DioException && e.type == DioExceptionType.cancel) {
        // İptal edildiyse bir şey yapma (cancel methodu zaten mesaj atıyor)
      } else {
        _emit(AgentFailed(
            'Bağlantı Hatası: Localhost sunucusuna ulaşılamadı. Detay: $e'));
      }
    } finally {
      _ref.read(agentIsRunningProvider.notifier).state = false;
    }
  }

  void cancel() {
    _cancelToken?.cancel('İptal edildi');
    _cancelToken = null;
    PtySandbox.killAllActiveProcesses();
    _emit(AgentFailed('İşlem kullanıcı tarafından durduruldu!'));
    _ref.read(agentIsRunningProvider.notifier).state = false;
  }

  void dispose() {
    _controller.close();
  }
}

final agentEngineProvider =
    Provider.family<AgentEngine, String?>((ref, sessionId) {
  final engine = AgentEngine(ref, sessionId);
  ref.onDispose(() => engine.dispose());
  return engine;
});
