import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../agent/permissions.dart';
import '../../models/chat_session.dart';
import '../../services/agent_engine.dart';
import '../../services/process_manager.dart';
import '../../services/sentence_chunker.dart';
import '../../services/voice_manager.dart';
import '../../theme/ide_palette.dart';
import '../chat/state.dart';
import 'voice_intent.dart';

/// Sesli asistanın anlık durumu.
enum _Phase { idle, listening, hearing, transcribing, thinking, speaking }

/// FerIDE sesli asistan ekranı: dinle → anla → düşün/yap → konuş → tekrar dinle.
class LiveSessionView extends ConsumerStatefulWidget {
  const LiveSessionView({super.key});

  @override
  ConsumerState<LiveSessionView> createState() => _LiveSessionViewState();
}

class _LiveSessionViewState extends ConsumerState<LiveSessionView> with SingleTickerProviderStateMixin {
  late final AnimationController _anim;
  final _scroll = ScrollController();
  final _entries = <_Entry>[];
  final _chunker = SentenceChunker();
  final _spoken = <String>{};

  bool _active = false;
  bool _engineBusy = false;
  String? _sessionId;
  String _task = '';
  StreamSubscription<AgentEvent>? _eventsSub;
  StreamSubscription<ApprovalRequest>? _approvalSub;
  ProviderSubscription<VoiceState>? _voiceSub;

  /// Sesle yanıt beklenen onay isteği.
  ApprovalRequest? _pendingApproval;

  /// dispose sırasında ağaca erişmemek için baştan saklanır.
  late final StateController<bool> _dialogOpen;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));
    // Ses sunucularını önceden ısıt: ilk konuşmada bekleme olmasın.
    unawaited(ProcessManager.instance.startAll());
    _voiceSub = ref.listenManual<VoiceState>(voiceManagerProvider, _onVoiceChanged);
    // Pencere açık olarak işaretlenir (ikinci kez açılmasın).
    _dialogOpen = ref.read(voiceDialogOpenProvider.notifier);
    Future.microtask(() {
      if (mounted) _dialogOpen.state = true;
    });
  }

  @override
  void dispose() {
    if (_active) _stop(fromDispose: true);
    _voiceSub?.close();
    // dispose sırasında provider durumu doğrudan değiştirilemez; bir sonraki tura bırak.
    final open = _dialogOpen;
    Future.microtask(() {
      try {
        open.state = false;
      } catch (_) {}
    });
    _anim.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------- yaşam döngüsü
  void _start({bool listenNow = true}) {
    // Oturumu ÖNCEDEN oluştur: motor olayları baştan doğru oturuma bağlanır
    // (eskiden ilk cümlede oturum kimliği değiştiği için olaylar kaçabiliyordu).
    var session = ref.read(activeSessionProvider);
    if (session == null) {
      final now = DateTime.now();
      session = ChatSession(
          title: 'Sesli sohbet ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}');
      ref.read(activeSessionProvider.notifier).setSession(session);
    }
    _sessionId = session.id;
    _eventsSub = ref.read(agentEngineProvider(_sessionId)).events.listen(_onAgentEvent);
    _approvalSub = ApprovalBroker.instance.requests.listen(_onApprovalRequest);
    setState(() => _active = true);
    if (listenNow) _listen();
  }

  /// Onay isteğini sesli sorar; yanıt "evet/hayır" ile ya da ekrandan verilebilir.
  void _onApprovalRequest(ApprovalRequest req) {
    if (!_active) return;
    _pendingApproval = req;
    req.future.then((_) {
      if (identical(_pendingApproval, req)) {
        _pendingApproval = null;
        if (mounted) setState(() {});
      }
    });
    final what = switch (req.risk) {
      ToolRisk.execute => 'bir komut çalıştırmam',
      ToolRisk.write => 'bir dosyayı değiştirmem',
      ToolRisk.network => 'internete bağlanmam',
      ToolRisk.read => 'bir işlem yapmam',
    };
    _add(_Entry.activity('Onay bekleniyor: ${req.summary.split('\n').first}'));
    _say('Bunun için $what gerekiyor. Onaylıyor musunuz? Evet ya da hayır diyebilirsiniz.');
    setState(() {});
  }

  void _answerApproval(String text) {
    final req = _pendingApproval;
    if (req == null) return;
    _add(_Entry.user(text));
    switch (VoiceIntent.classifyYesNo(text)) {
      case YesNo.yes:
        _pendingApproval = null;
        req.resolve(true);
        _say('Tamam, yapıyorum.');
      case YesNo.no:
        _pendingApproval = null;
        req.resolve(false);
        _say('Peki, yapmıyorum.');
      case null:
        _say('Anlayamadım. Evet ya da hayır der misiniz?');
    }
    setState(() {});
  }

  void _stop({bool fromDispose = false}) {
    _active = false;
    _eventsSub?.cancel();
    _approvalSub?.cancel();
    _eventsSub = null;
    _approvalSub = null;
    if (_engineBusy) ref.read(agentEngineProvider(_sessionId)).cancel(silent: true);
    final voice = ref.read(voiceManagerProvider.notifier);
    voice.clearQueue();
    voice.stopSpeaking();
    if (ref.read(voiceManagerProvider).isRecording) voice.stopRecording(fromLiveSession: true);
    _chunker.reset();
    _spoken.clear();
    _engineBusy = false;
  }

  void _listen() {
    if (!_active || !mounted) return;
    if (_engineBusy && _pendingApproval == null) return;
    final vs = ref.read(voiceManagerProvider);
    if (vs.isRecording || vs.isSpeaking || vs.pendingQueueCount > 0) return;
    ref.read(voiceManagerProvider.notifier).startRecording(autoStop: true, isLiveSession: true);
  }

  /// Konuşmayı keser ve hemen dinlemeye geçer (barge-in).
  void _interrupt() {
    final voice = ref.read(voiceManagerProvider.notifier);
    voice.clearQueue();
    voice.stopSpeaking();
    if (_engineBusy) ref.read(agentEngineProvider(_sessionId)).cancel(silent: true);
    Future.delayed(const Duration(milliseconds: 250), _listen);
  }

  void _say(String text) => ref.read(voiceManagerProvider.notifier).queueSentence(text);

  // ------------------------------------------------------------------ olaylar
  void _onVoiceChanged(VoiceState? prev, VoiceState next) {
    if (!_active) return;
    final isNew = next.transcriptSeq > (prev?.transcriptSeq ?? 0) &&
        next.transcriptOwner == 'live' &&
        (next.lastTranscript?.isNotEmpty ?? false);
    if (isNew) {
      if (_pendingApproval != null) {
        _answerApproval(next.lastTranscript!);
      } else if (!_engineBusy) {
        unawaited(_handleUtterance(next.lastTranscript!));
      }
      return;
    }
    // Konuşma bitti → tekrar dinle (kesintisiz döngü)
    if (prev?.isSpeaking == true && !next.isSpeaking && next.pendingQueueCount == 0) {
      Future.delayed(const Duration(milliseconds: 350), _listen);
    }
    // Mikrofon bir hata nedeniyle kapandıysa kullanıcıya göster
    if (next.lastError != null && next.lastError != prev?.lastError) {
      _add(_Entry.error(next.lastError!));
    }
  }

  Future<void> _handleUtterance(String text) async {
    _add(_Entry.user(text));
    ref.read(activeSessionProvider.notifier).addEvent(AgentStarted(text));
    _chunker.reset();
    _spoken.clear();
    setState(() {
      _engineBusy = true;
      _task = 'Düşünüyorum';
    });

    await ref.read(agentEngineProvider(_sessionId)).run(
          text,
          ref.read(thinkingModeProvider),
          0,
          isLiveSession: true,
        );

    if (!mounted || !_active) return;
    // Noktayla bitmeyen son parçayı da seslendir.
    final rest = _chunker.flush().trim();
    if (rest.length > 2 && _spoken.add(rest)) _say(rest);
    _chunker.reset();

    final last = _entries.isNotEmpty ? _entries.last : null;
    if (last != null && last.kind == _Kind.feride && last.text.isNotEmpty) {
      ref.read(activeSessionProvider.notifier).addEvent(AgentMessage(last.text));
    }
    setState(() => _engineBusy = false);
    final vs = ref.read(voiceManagerProvider);
    if (!vs.isSpeaking && vs.pendingQueueCount == 0) {
      Future.delayed(const Duration(milliseconds: 400), _listen);
    }
  }

  void _onAgentEvent(AgentEvent e) {
    if (!_active || !mounted) return;
    if (e is AgentMessage) {
      _setFerideText(e.message);
      if (e.inputTokens != null) return; // akış sonu özeti: tekrar okuma
      for (final s in _chunker.feed(_speakable(e.message))) {
        final t = s.trim();
        if (t.length > 2 && _spoken.add(t)) _say(t);
      }
    } else if (e is StepStarted) {
      setState(() => _task = e.step.description);
    } else if (e is ToolInvoked) {
      setState(() => _task = _toolLabel(e.toolName));
      _add(_Entry.activity(_toolLabel(e.toolName)));
    } else if (e is JobStarted) {
      _add(_Entry.activity('Arka planda başlatıldı: ${e.taskDescription}'));
    } else if (e is JobCompleted) {
      _add(_Entry.activity('Arka plan görevi tamamlandı'));
    } else if (e is AgentFailed) {
      if (e.error.contains('durduruldu')) return;
      _add(_Entry.error(e.error));
      _say('Üzgünüm, bir sorun oluştu. Ayrıntıları ekranda görebilirsin.');
    }
  }

  void _setFerideText(String text) {
    final clean = text.trim();
    if (clean.isEmpty) return;
    setState(() {
      if (_entries.isNotEmpty && _entries.last.kind == _Kind.feride) {
        _entries.last.text = clean;
      } else {
        _entries.add(_Entry.feride(clean));
      }
    });
    _scrollToEnd();
  }

  void _add(_Entry e) {
    if (!mounted) return;
    setState(() => _entries.add(e));
    _scrollToEnd();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
      }
    });
  }

  static final _emoji = RegExp(r'[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}\u{FE0F}]', unicode: true);

  static String _speakable(String s) =>
      s.replaceAll(RegExp(r'```[\s\S]*?(```|$)'), ' ').replaceAll(RegExp(r'[*_#>`|]'), '').replaceAll(_emoji, '');

  static String _toolLabel(String tool) {
    if (tool.startsWith('mcp__')) return 'MCP aracı kullanılıyor (${tool.split('__').last})';
    return switch (tool) {
      'run_command' => 'Komut çalıştırılıyor',
      'read_file' || 'read_document' => 'Dosya okunuyor',
      'write_to_file' || 'replace_file_content' => 'Dosya düzenleniyor',
      'list_directory' || 'glob' => 'Dosyalar taranıyor',
      'grep_search' => 'Aranıyor',
      'search_web' => 'İnternette aranıyor',
      'read_url_content' => 'Web sayfası okunuyor',
      'open_file_in_system' => 'Açılıyor',
      'take_screenshot' => 'Ekrana bakılıyor',
      'dispatch_worker' || 'spawn_agent' => 'Alt ajana devrediliyor',
      _ => 'Çalışıyor: $tool',
    };
  }

  _Phase _phase(VoiceState vs) {
    if (!_active) return _Phase.idle;
    if (vs.isSpeaking) return _Phase.speaking;
    if (_pendingApproval != null && vs.isRecording) return vs.userSpeaking ? _Phase.hearing : _Phase.listening;
    if (_engineBusy) return _Phase.thinking;
    if (vs.isProcessingSTT) return _Phase.transcribing;
    if (vs.userSpeaking) return _Phase.hearing;
    if (vs.isRecording) return _Phase.listening;
    return _Phase.transcribing;
  }

  // ---------------------------------------------------------------------- UI
  @override
  Widget build(BuildContext context) {
    final vs = ref.watch(voiceManagerProvider);
    final phase = _phase(vs);
    final model = ref.watch(selectedModelProvider);
    final backendUp = ref.watch(isBackendRunningProvider);
    final isLight = Theme.of(context).brightness == Brightness.light;
    final fg = isLight ? const Color(0xFF111827) : IdePalette.textPrimary;
    final muted = isLight ? const Color(0xFF6B7280) : IdePalette.textSecondary;
    final color = _phaseColor(phase);
    // Boştayken animasyonu durdur: arka planda sıfır CPU/GPU kullanımı.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (phase == _Phase.idle && _anim.isAnimating) _anim.stop();
      if (phase != _Phase.idle && !_anim.isAnimating) _anim.repeat();
    });

    final (title, hint) = switch (phase) {
      _Phase.idle => ('Sesli asistan hazır', 'Başlamak için mikrofona dokunun'),
      _Phase.listening when _pendingApproval != null => ('Onayınızı bekliyorum', '"Evet" ya da "hayır" deyin'),
      _Phase.listening => ('Dinliyorum', 'Konuşmaya başlayabilirsiniz'),
      _Phase.hearing => ('Sizi duyuyorum', 'Sustuğunuzda yanıtlayacağım'),
      _Phase.transcribing => ('Anlıyorum', 'Söyledikleriniz yazıya çevriliyor'),
      _Phase.thinking => (_task.isEmpty ? 'Düşünüyorum' : _task, 'Kesmek için küreye dokunun'),
      _Phase.speaking => ('Konuşuyorum', 'Sözümü kesmek için küreye dokunun'),
    };

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 760, maxHeight: 720),
      child: Material(
        color: isLight ? Colors.white : const Color(0xFF14161C),
        elevation: 24,
        shadowColor: Colors.black54,
        borderRadius: BorderRadius.circular(24),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 14, 10, 6),
              child: Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _active ? const Color(0xFF22C55E) : muted.withValues(alpha: 0.5),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text('Feride • Sesli Asistan', style: TextStyle(color: fg, fontSize: 16, fontWeight: FontWeight.w600)),
                  const SizedBox(width: 12),
                  Flexible(
                    child: Text(
                      backendUp ? model : 'Model başlatılıyor...',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: muted, fontSize: 12),
                    ),
                  ),
                  const Spacer(),
                  Tooltip(
                    message: 'Düşünme modu (daha yavaş, daha derin yanıt)',
                    child: Row(children: [
                      Icon(Icons.psychology_alt_outlined, size: 18, color: muted),
                      Switch(
                        value: ref.watch(thinkingModeProvider),
                        onChanged: (v) => ref.read(thinkingModeProvider.notifier).state = v,
                      ),
                    ]),
                  ),
                  IconButton(
                    tooltip: 'Kapat',
                    icon: Icon(Icons.close_rounded, color: muted),
                    onPressed: () {
                      if (_active) setState(_stop);
                      Navigator.of(context).maybePop();
                    },
                  ),
                ],
              ),
            ),
            Expanded(
              flex: 5,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  GestureDetector(
                    onTap: () {
                      if (!_active) {
                        _start();
                      } else if (phase == _Phase.speaking || phase == _Phase.thinking) {
                        _interrupt();
                      }
                    },
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: RepaintBoundary(
                        child: AnimatedBuilder(
                          animation: _anim,
                          builder: (_, __) => CustomPaint(
                            painter: _OrbPainter(phase: phase, level: vs.micLevel, t: _anim.value, color: color),
                            child: SizedBox(
                              width: 210,
                              height: 210,
                              child: Icon(_phaseIcon(phase), size: 38, color: Colors.white),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: Text(title,
                        key: ValueKey(title),
                        textAlign: TextAlign.center,
                        style: TextStyle(color: fg, fontSize: 18, fontWeight: FontWeight.w600)),
                  ),
                  const SizedBox(height: 4),
                  Text(hint, style: TextStyle(color: muted, fontSize: 13)),
                  if (_active) ...[
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 10,
                      alignment: WrapAlignment.center,
                      children: [
                        if (phase == _Phase.speaking || phase == _Phase.thinking)
                          OutlinedButton.icon(
                            onPressed: _interrupt,
                            icon: const Icon(Icons.pan_tool_alt_outlined, size: 18),
                            label: const Text('Sözünü kes'),
                          ),
                        FilledButton.tonalIcon(
                          onPressed: () => setState(_stop),
                          icon: const Icon(Icons.stop_rounded, size: 18),
                          label: const Text('Oturumu bitir'),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            Expanded(
              flex: 4,
              child: Container(
                margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                decoration: BoxDecoration(
                  color: isLight ? const Color(0xFFF6F7F9) : Colors.white.withValues(alpha: 0.03),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: _entries.isEmpty
                    ? Center(
                        child: Text(
                          _active ? 'Konuşmaya başlayın...' : 'Henüz konuşma yok',
                          style: TextStyle(color: muted, fontSize: 13),
                        ),
                      )
                    : ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.all(14),
                        itemCount: _entries.length,
                        itemBuilder: (_, i) => _bubble(_entries[i], isLight, fg, muted),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bubble(_Entry e, bool isLight, Color fg, Color muted) {
    switch (e.kind) {
      case _Kind.activity:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(children: [
            Icon(Icons.bolt_rounded, size: 14, color: IdePalette.accentSoft.withValues(alpha: 0.8)),
            const SizedBox(width: 6),
            Expanded(child: Text(e.text, style: TextStyle(color: muted, fontSize: 12))),
          ]),
        );
      case _Kind.error:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.error_outline, size: 16, color: Color(0xFFEF4444)),
            const SizedBox(width: 6),
            Expanded(child: SelectableText(e.text, style: const TextStyle(color: Color(0xFFEF4444), fontSize: 12))),
          ]),
        );
      case _Kind.user:
      case _Kind.feride:
        final mine = e.kind == _Kind.user;
        return Align(
          alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 520),
            margin: const EdgeInsets.symmetric(vertical: 4),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: mine
                  ? IdePalette.accentSoft.withValues(alpha: isLight ? 0.16 : 0.22)
                  : (isLight ? Colors.white : Colors.white.withValues(alpha: 0.06)),
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(16),
                topRight: const Radius.circular(16),
                bottomLeft: Radius.circular(mine ? 16 : 4),
                bottomRight: Radius.circular(mine ? 4 : 16),
              ),
            ),
            child: SelectableText(e.text, style: TextStyle(color: fg, fontSize: 14, height: 1.4)),
          ),
        );
    }
  }

  static Color _phaseColor(_Phase p) => switch (p) {
        _Phase.idle => const Color(0xFF64748B),
        _Phase.listening => const Color(0xFF22C55E),
        _Phase.hearing => const Color(0xFF10B981),
        _Phase.transcribing => const Color(0xFFF59E0B),
        _Phase.thinking => const Color(0xFFA855F7),
        _Phase.speaking => IdePalette.accentSoft,
      };

  static IconData _phaseIcon(_Phase p) => switch (p) {
        _Phase.idle => Icons.mic_none_rounded,
        _Phase.listening || _Phase.hearing => Icons.mic_rounded,
        _Phase.transcribing => Icons.translate_rounded,
        _Phase.thinking => Icons.auto_awesome_rounded,
        _Phase.speaking => Icons.graphic_eq_rounded,
      };
}

class _OrbPainter extends CustomPainter {
  final _Phase phase;
  final double level;
  final double t;
  final Color color;

  _OrbPainter({required this.phase, required this.level, required this.t, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    const base = 54.0;
    final wave = math.sin(t * 2 * math.pi);
    final react = switch (phase) {
      _Phase.hearing || _Phase.listening => level.clamp(0.0, 1.0) * 26,
      _Phase.speaking => 6 + 6 * wave.abs(),
      _Phase.thinking => 3 + 3 * wave,
      _ => 0.0,
    };
    final r = base + react;

    canvas.drawCircle(
      c,
      r * 1.9,
      Paint()
        ..shader = RadialGradient(colors: [color.withValues(alpha: 0.32), color.withValues(alpha: 0.0)])
            .createShader(Rect.fromCircle(center: c, radius: r * 1.9)),
    );

    if (phase == _Phase.listening || phase == _Phase.hearing || phase == _Phase.speaking) {
      for (var i = 0; i < 2; i++) {
        final p = (t + i * 0.5) % 1.0;
        canvas.drawCircle(
          c,
          r + 8 + p * 34,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = color.withValues(alpha: (1 - p) * 0.35),
        );
      }
    }

    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color.lerp(color, Colors.white, 0.25)!, Color.lerp(color, Colors.black, 0.25)!],
        ).createShader(Rect.fromCircle(center: c, radius: r)),
    );

    if (phase == _Phase.thinking || phase == _Phase.transcribing) {
      canvas.drawArc(
        Rect.fromCircle(center: c, radius: r + 10),
        t * 2 * math.pi,
        math.pi * 0.7,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = 3
          ..color = color.withValues(alpha: 0.9),
      );
    }
  }

  @override
  bool shouldRepaint(_OrbPainter old) => old.t != t || old.level != level || old.phase != phase || old.color != color;
}

enum _Kind { user, feride, activity, error }

class _Entry {
  final _Kind kind;
  String text;
  _Entry(this.kind, this.text);
  factory _Entry.user(String t) => _Entry(_Kind.user, t);
  factory _Entry.feride(String t) => _Entry(_Kind.feride, t);
  factory _Entry.activity(String t) => _Entry(_Kind.activity, t);
  factory _Entry.error(String t) => _Entry(_Kind.error, t);
}


/// Sesli asistan penceresini açar (başlıktaki düğme ve Ctrl+M).
Future<void> openVoiceAssistant(BuildContext? context) async {
  final ctx = context ?? rootNavigatorKey.currentContext;
  if (ctx == null) return;
  final container = ProviderScope.containerOf(ctx, listen: false);
  if (container.read(voiceDialogOpenProvider)) return; // zaten açık
  await showDialog(
    context: ctx,
    barrierColor: Colors.black.withValues(alpha: 0.45),
    builder: (_) => Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.all(24),
      child: const LiveSessionView(),
    ),
  );
}
