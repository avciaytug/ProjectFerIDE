import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../services/voice_manager.dart';
import '../../services/agent_engine.dart';
import '../../services/sentence_chunker.dart';
import '../../services/process_manager.dart';
import '../../models/chat_session.dart';
import '../chat/state.dart';
import '../../../theme/ide_palette.dart';

class LiveSessionView extends ConsumerStatefulWidget {
  const LiveSessionView({super.key});

  @override
  ConsumerState<LiveSessionView> createState() => _LiveSessionViewState();
}

class _LiveSessionViewState extends ConsumerState<LiveSessionView> with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  final ScrollController _scrollController = ScrollController();
  final List<_TranscriptEntry> _transcriptHistory = [];
  bool _isSessionActive = false;
  bool _isWaitingForLLM = false;
  String _currentStreamingText = '';
  String _lastCompletedResponse = '';
  String _currentAgentTask = "Yanıt düşünüyor...";
  // Task 1: Cümle bazlı streaming TTS — her tamamlanan cümle anında kuyruğa eklenir
  final SentenceChunker _chunker = SentenceChunker();
  final Set<String> _spokenSentences = {};

  @override
  void initState() {
    super.initState();
    // Kullanıcı canlı oturum moduna geçtiğinde arka plan sunucularını başlat
    ProcessManager.instance.startAll();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _scrollController.dispose();
    if (_isSessionActive) {
      _stopSession();
    }
    // Sunucular (STT, TTS, Ollama) uygulamanın yaşam döngüsüne (main.dart) devredildi.
    // Sekme değiştiğinde sunucuları öldürmüyoruz ki modelin tekrar yüklenmesi 3 dakika sürmesin.
    
    super.dispose();
  }

  void _startSession() {
    setState(() {
      _isSessionActive = true;
    });
    // VAD modunda kaydı başlat — kullanıcı sustuğunda otomatik duracak
    ref.read(voiceManagerProvider.notifier).startRecording(autoStop: true, isLiveSession: true);
  }

  void _stopSession() {
    setState(() {
      _isSessionActive = false;
      _isWaitingForLLM = false;
    });
    
    // Devam eden LLM isteğini iptal et ki sunucu boşu boşuna çalışmaya devam etmesin
    final sessionId = ref.read(activeSessionProvider)?.id;
    ref.read(agentEngineProvider(sessionId)).cancel();
    
    final voiceState = ref.read(voiceManagerProvider);
    if (voiceState.isRecording) {
      ref.read(voiceManagerProvider.notifier).stopRecording();
    }
    
    // FerIDE'nin o anki konuşmasını ve bekleyen TTS işlemlerini de sustur
    ref.read(voiceManagerProvider.notifier).clearQueue();
    ref.read(voiceManagerProvider.notifier).stopSpeaking();
    _chunker.reset();
    _spokenSentences.clear();
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      Future.delayed(const Duration(milliseconds: 100), () {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent + 60,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // === LLM streaming olaylarını dinle ===
    final sessionId = ref.watch(activeSessionProvider.select((s) => s?.id));
    ref.listen<AsyncValue<AgentEvent>>(
      agentEventsProvider(sessionId), 
      (previous, next) {
        next.whenData((event) {
          if (event is AgentMessage) {
            _lastCompletedResponse = event.message;
            // Streaming: her token geldiğinde son FerIDE satırını GÜNCELLE
            // Eğer inputTokens null değilse bu stream'in bittiğini bildiren final metrik mesajıdır, 
            // bunu TTS ve UI için atla (aksi halde baştan okur).
            if (event.inputTokens != null) return;
            
            _currentStreamingText = event.message;

            // Ses motoruna gitmeden önce <think> ve <tool_call> bloklarını ayıkla (robotik iç ses okunmasın)
            String spokenChunk = event.message;
            if (spokenChunk.contains('<think>')) {
              if (spokenChunk.contains('</think>')) {
                spokenChunk = spokenChunk.replaceAll(RegExp(r'<think>[\s\S]*?</think>'), '');
              } else {
                spokenChunk = spokenChunk.substring(0, spokenChunk.indexOf('<think>'));
              }
            }
            if (spokenChunk.contains('<tool_call>')) {
              spokenChunk = spokenChunk.substring(0, spokenChunk.indexOf('<tool_call>'));
            }
            spokenChunk = spokenChunk.replaceAll(
                RegExp(r'[\u{1F600}-\u{1F64F}\u{1F300}-\u{1F5FF}\u{1F680}-\u{1F6FF}\u{1F700}-\u{1F77F}\u{1F780}-\u{1F7FF}\u{1F800}-\u{1F8FF}\u{1F900}-\u{1F9FF}\u{1FA00}-\u{1FA6F}\u{1FA70}-\u{1FAFF}\u{2600}-\u{26FF}\u{2700}-\u{27BF}]',
                    unicode: true),
                '');

            // Task 1: Tamamlanan cümleleri yakala → TTS kuyruğuna anında ekle
            final newSentences = _chunker.feed(spokenChunk);
            if (newSentences.isNotEmpty) {
              final voice = ref.read(voiceManagerProvider.notifier);
              for (final s in newSentences) {
                final trimmed = s.trim();
                if (trimmed.length > 2 && _spokenSentences.add(trimmed)) {
                  voice.queueSentence(trimmed);
                }
              }
            }
            if (mounted) {
              setState(() {
                if (_transcriptHistory.isNotEmpty && _transcriptHistory.last.isFeride) {
                  _transcriptHistory.last = _TranscriptEntry(
                    text: _currentStreamingText,
                    isFeride: true,
                  );
                } else {
                  _transcriptHistory.add(_TranscriptEntry(
                    text: _currentStreamingText,
                    isFeride: true,
                  ));
                }
              });
              _scrollToBottom();
            }
          } else if (event is StepStarted) {
            if (mounted) setState(() { _currentAgentTask = event.step.description; });
          } else if (event is ToolInvoked) {
            if (mounted) setState(() { _currentAgentTask = "Arama yapılıyor (${event.toolName})..."; });
          } else if (event is ToolCompleted) {
            if (mounted) setState(() { _currentAgentTask = "Sonuç inceleniyor..."; });
          } else if (event is JobStarted) {
            if (mounted) {
              setState(() {
                _transcriptHistory.add(_TranscriptEntry(
                  text: '🚀 Arka Plan Görevi: ${event.taskDescription}',
                  isFeride: true,
                  isJob: true,
                ));
              });
              _scrollToBottom();
            }
          } else if (event is JobProgress) {
            if (mounted) {
              setState(() {
                _transcriptHistory.add(_TranscriptEntry(
                  text: '⏳ ${event.statusMessage}',
                  isFeride: true,
                  isJob: true,
                ));
              });
              _scrollToBottom();
            }
          } else if (event is JobCompleted) {
            if (mounted) {
              setState(() {
                _transcriptHistory.add(_TranscriptEntry(
                  text: '✅ Görev Tamamlandı!',
                  isFeride: true,
                  isJob: true,
                ));
              });
              _scrollToBottom();
            }
          } else if (event is JobAwaitingHuman) {
            if (mounted) {
              setState(() {
                _transcriptHistory.add(_TranscriptEntry(
                  text: '⚠️ ONAY BEKLENİYOR: ${event.actionRequired}',
                  isFeride: true,
                  isJob: true,
                ));
              });
              _scrollToBottom();
            }
          } else if (event is AgentFailed) {
            if (mounted) {
              setState(() {
                _transcriptHistory.add(_TranscriptEntry(
                  text: '⚠️ ' + event.error,
                  isFeride: true,
                ));
              });
              _scrollToBottom();
            }
            if (!event.error.contains('durduruldu')) {
              ref.read(voiceManagerProvider.notifier).speak("Üzgünüm, sunucuya bağlanamadım. Lütfen modelin çalıştığından emin ol.");
            }
          }
        });
      }
    );

    // === LLM bittiğinde: yanıtı hafızaya yaz ve kalan cümleyi kuyruğa ekle ===
    ref.listen<bool>(agentIsRunningProvider, (prev, next) {
      if (prev == true && next == false && _isSessionActive) {
        _isWaitingForLLM = false;

        // Canlı oturum yanıtını aktif oturum geçmişine kalıcı olarak ekle
        var session = ref.read(activeSessionProvider);
        if (session == null) {
          final now = DateTime.now();
          final timeStr = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
          session = ChatSession(title: '🎙️ Canlı Oturum ($timeStr)');
          ref.read(activeSessionProvider.notifier).setSession(session);
        }

        if (_lastCompletedResponse.isNotEmpty) {
          ref.read(activeSessionProvider.notifier).addEvent(AgentMessage(_lastCompletedResponse));
          _lastCompletedResponse = '';
        }

        if (_currentStreamingText.isNotEmpty) {
          _currentStreamingText = '';
          // Cümle bazlı TTS: streaming sırasında tamamlanan cümleler zaten
          // kuyruğa eklendi. Burada sadece noktasız kalan son parçayı ekle.
          final remaining = _chunker.flush().trim();
          if (remaining.length > 2 && _spokenSentences.add(remaining)) {
            ref.read(voiceManagerProvider.notifier).queueSentence(remaining);
          }
        }
        _chunker.reset();
        _spokenSentences.clear();

        // Ölü mikrofon koruması: Model konuşma üretmediyse veya sadece araç çağırdıysa,
        // isSpeaking false kalır. Kuyruk da boşsa mikrofonu otomatik tekrar dinlemeye al.
        final vs = ref.read(voiceManagerProvider);
        if (!vs.isSpeaking && vs.pendingQueueCount == 0) {
          Future.delayed(const Duration(milliseconds: 600), () {
            if (mounted && _isSessionActive) {
              final currentVs = ref.read(voiceManagerProvider);
              if (!currentVs.isSpeaking && currentVs.pendingQueueCount == 0 && !currentVs.isRecording) {
                ref.read(voiceManagerProvider.notifier).startRecording(autoStop: true, isLiveSession: true);
              }
            }
          });
        }
      }
    });

    // === Kullanıcı konuşmasını bitirdiğinde LLM tetikle + TTS bitince VAD döngüsü ===
    ref.listen<VoiceState>(voiceManagerProvider, (prev, next) {
      if (!_isSessionActive) return;

      // 1. Kullanıcı konuşmasını bitirdiğinde (transcriptSeq ile mükerrer cümleler dahi kaçırılmaz)
      final hasNewTranscript = (next.transcriptSeq > (prev?.transcriptSeq ?? 0)) &&
          next.lastTranscript != null &&
          next.lastTranscript!.isNotEmpty;

      if (hasNewTranscript) {
        final userText = next.lastTranscript!;
        _spokenSentences.clear();
        _chunker.reset();

        // Canlı oturumdaki kullanıcı sorusunu aktif oturum hafızasına ekle
        var session = ref.read(activeSessionProvider);
        if (session == null) {
          final now = DateTime.now();
          final timeStr = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
          session = ChatSession(title: '🎙️ Canlı Oturum ($timeStr)');
          ref.read(activeSessionProvider.notifier).setSession(session);
        }
        ref.read(activeSessionProvider.notifier).addEvent(AgentStarted(userText));

        if (mounted) {
          setState(() {
            _transcriptHistory.add(_TranscriptEntry(
              text: userText,
              isFeride: false,
            ));
            _isWaitingForLLM = true;
          });
          _scrollToBottom();
        }

        // LLM'i tetikle
        final isRunning = ref.read(agentIsRunningProvider);
        if (!isRunning) {
          final isThinking = ref.read(thinkingModeProvider);
          final currentTokens = ref.read(tokenCountProvider);
          final sessionId = ref.read(activeSessionProvider)?.id;
          ref.read(agentEngineProvider(sessionId)).run(userText, isThinking, currentTokens, isLiveSession: true);
        }
      }

      // 2. FerIDE TTS bittiğinde -> mikrofonu tekrar aç (kesintisiz döngü)
      if (prev?.isSpeaking == true && next.isSpeaking == false && _isSessionActive) {
        Future.delayed(const Duration(milliseconds: 500), () {
          if (mounted && _isSessionActive) {
            ref.read(voiceManagerProvider.notifier).startRecording(autoStop: true, isLiveSession: true);
          }
        });
      }
    });

    final voiceState = ref.watch(voiceManagerProvider);
    final isAgentRunning = ref.watch(agentIsRunningProvider);
    final isLight = Theme.of(context).brightness == Brightness.light;

    // Durum metni ve rengi
    String statusText;
    Color statusColor;
    if (!_isSessionActive) {
      statusText = "Oturumu başlatmak için mikrofona dokunun";
      statusColor = IdePalette.textTertiary;
    } else if (voiceState.isSpeaking) {
      statusText = "Sizinle konuşuyor...";
      statusColor = IdePalette.accentSoft;
    } else if (isAgentRunning || _isWaitingForLLM) {
      statusText = _currentAgentTask;
      statusColor = const Color(0xFF9C27B0);
    } else if (voiceState.isProcessingSTT) {
      statusText = "Söylediklerinizi anlıyor...";
      statusColor = const Color(0xFFFFB300);
    } else if (voiceState.isRecording) {
      statusText = "Sizi dinliyor...";
      statusColor = const Color(0xFF4CAF50);
    } else if (voiceState.lastError != null) {
      statusText = voiceState.lastError!;
      statusColor = const Color(0xFFF44336);
    } else {
      statusText = "Hazırlanıyor...";
      statusColor = IdePalette.textTertiary;
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Container(
        decoration: BoxDecoration(
          color: isLight ? Colors.white.withOpacity(0.9) : IdePalette.backgroundBase.withOpacity(0.95),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: IdePalette.glassBorder),
        ),
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            // Header
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(
                      _isSessionActive ? Icons.fiber_manual_record : Icons.record_voice_over, 
                      color: _isSessionActive ? const Color(0xFF4CAF50) : IdePalette.accentSoft, 
                      size: 20,
                    ),
                    const SizedBox(width: 12),
                    Text(
                      _isSessionActive ? "Canlı Oturum • Aktif" : "Canlı Oturum",
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: isLight ? Colors.black87 : IdePalette.textPrimary,
                      ),
                    ),
                  ],
                ),
                Row(
                  children: [
                    if (_isSessionActive)
                      TextButton.icon(
                        onPressed: _stopSession,
                        icon: const Icon(Icons.stop_circle_outlined, size: 18, color: Colors.redAccent),
                        label: const Text("Bitir", style: TextStyle(color: Colors.redAccent, fontSize: 13)),
                      ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        if (_isSessionActive) _stopSession();
                        Navigator.of(context).pop();
                      },
                      color: IdePalette.textSecondary,
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 16),
            // Top Controls (Thinking Mode & Model Selector)
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 16,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Düşünce Modu (Thinking)', style: TextStyle(color: IdePalette.textTertiary, fontSize: 13)),
                    const SizedBox(width: 8),
                    Switch(
                      value: ref.watch(thinkingModeProvider),
                      activeColor: IdePalette.accentSoft,
                      onChanged: (val) {
                        ref.read(thinkingModeProvider.notifier).state = val;
                      },
                    ),
                  ],
                ),
                Consumer(
                  builder: (context, ref, child) {
                    final availableModelsAsync = ref.watch(availableModelsProvider);
                    final selectedModel = ref.watch(selectedModelProvider);
                    final isRunning = ref.watch(isBackendRunningProvider);
                    
                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      decoration: BoxDecoration(
                        color: isLight ? Colors.black.withOpacity(0.05) : Colors.white.withOpacity(0.05),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: IdePalette.glassBorder),
                      ),
                      child: availableModelsAsync.when(
                        data: (models) {
                          if (models.isEmpty) models = ['Yükleniyor...'];
                          return DropdownButton<String>(
                            value: models.contains(selectedModel) ? selectedModel : models.first,
                            dropdownColor: isLight ? Colors.white : IdePalette.backgroundBase,
                            underline: const SizedBox(),
                            icon: Icon(Icons.memory, color: isRunning ? IdePalette.textTertiary : IdePalette.accentSoft, size: 16),
                            style: TextStyle(
                              color: isRunning ? IdePalette.textTertiary : (isLight ? Colors.black87 : IdePalette.textPrimary), 
                              fontSize: 12, 
                              fontWeight: FontWeight.w500
                            ),
                            items: models.map((model) {
                              return DropdownMenuItem(value: model, child: Text(model.length > 25 ? '${model.substring(0, 25)}...' : model));
                            }).toList(),
                            onChanged: (val) {
                              if (val != null && val != selectedModel) {
                                ref.read(selectedModelProvider.notifier).switchModel(val);
                              }
                            },
                          );
                        },
                        loading: () => const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                        error: (_, __) => const Text('Hata', style: TextStyle(color: Colors.red)),
                      ),
                    );
                  },
                ),
              ],
            ),
            const SizedBox(height: 8),
            // Microphone Animation Centerpiece
            Expanded(
              flex: 3,
              child: Center(
                child: GestureDetector(
                  onTap: () {
                    if (!_isSessionActive) {
                      _startSession();
                    } else {
                      _stopSession();
                    }
                  },
                  child: AnimatedBuilder(
                    animation: _pulseController,
                    builder: (context, child) {
                      final isListening = _isSessionActive && voiceState.isRecording;
                      final isTalking = voiceState.isSpeaking;
                      final isThinking = isAgentRunning || _isWaitingForLLM;
                      final scale = isListening ? 1.0 + (_pulseController.value * 0.15) : 
                                    isTalking ? 1.0 + (_pulseController.value * 0.1) : 1.0;
                      
                      Color glowColor;
                      if (isTalking) {
                        glowColor = IdePalette.accentSoft;
                      } else if (isThinking) {
                        glowColor = const Color(0xFF9C27B0);
                      } else if (isListening) {
                        glowColor = const Color(0xFF4CAF50);
                      } else {
                        glowColor = Colors.grey;
                      }

                      return Transform.scale(
                        scale: scale,
                        child: Container(
                          width: 80,
                          height: 80,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: RadialGradient(
                              colors: _isSessionActive
                                  ? [glowColor.withOpacity(0.4), Colors.transparent]
                                  : [Colors.grey.withOpacity(0.15), Colors.transparent],
                              stops: const [0.5, 1.0],
                            ),
                            boxShadow: _isSessionActive
                                ? [BoxShadow(color: glowColor.withOpacity(0.6), blurRadius: 30 * _pulseController.value, spreadRadius: 8 * _pulseController.value)]
                                : [],
                          ),
                          child: Icon(
                            isTalking ? Icons.volume_up_rounded :
                            isThinking ? Icons.psychology :
                            isListening ? Icons.mic :
                            Icons.mic_none,
                            size: 40,
                            color: _isSessionActive ? Colors.white : IdePalette.textSecondary,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
            
            // Status Text
            Text(
              statusText,
              style: TextStyle(
                color: statusColor,
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 24),
            
            // Transcript History (kompakt, zarif)
            Expanded(
              flex: 4,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: isLight ? Colors.black.withOpacity(0.02) : Colors.white.withOpacity(0.02),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: IdePalette.glassBorder.withOpacity(0.5)),
                ),
                child: _transcriptHistory.isEmpty
                  ? Center(
                      child: Text(
                        _isSessionActive ? "Konuşmaya başlayın..." : "Henüz konuşma yok",
                        style: TextStyle(color: IdePalette.textTertiary, fontSize: 13),
                      ),
                    )
                  : ListView.builder(
                    controller: _scrollController,
                    itemCount: _transcriptHistory.length,
                    itemBuilder: (context, index) {
                      final entry = _transcriptHistory[index];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              entry.isFeride ? "FerIDE: " : "Siz: ",
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: entry.isFeride 
                                    ? IdePalette.accentSoft 
                                    : (isLight ? Colors.black87 : IdePalette.textPrimary),
                              ),
                            ),
                            Expanded(
                              child: Container(
                                padding: entry.isJob ? const EdgeInsets.symmetric(horizontal: 8, vertical: 4) : null,
                                decoration: entry.isJob ? BoxDecoration(
                                  color: Colors.orange.withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(color: Colors.orange.withOpacity(0.3)),
                                ) : null,
                                child: SelectableText(
                                  entry.text,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: entry.isJob 
                                        ? Colors.orangeAccent
                                        : (isLight 
                                            ? (entry.isFeride ? Colors.black54 : Colors.black87) 
                                            : (entry.isFeride ? IdePalette.textSecondary : IdePalette.textPrimary)),
                                    height: 1.4,
                                    fontStyle: entry.isJob ? FontStyle.italic : FontStyle.normal,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TranscriptEntry {
  String text;
  final bool isFeride;
  final bool isJob;
  _TranscriptEntry({required this.text, required this.isFeride, this.isJob = false});
}
