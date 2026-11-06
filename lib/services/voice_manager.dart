import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'app_paths.dart';
import 'process_manager.dart';

final voiceManagerProvider = StateNotifierProvider<VoiceManager, VoiceState>((ref) {
  return VoiceManager();
});

class VoiceState {
  final bool isRecording;
  final bool isProcessingSTT;
  final bool isSpeaking;
  final bool isLiveSession;
  final String? lastTranscript;
  final int transcriptSeq;
  final String? lastError;
  final int pendingQueueCount;

  VoiceState({
    this.isRecording = false,
    this.isProcessingSTT = false,
    this.isSpeaking = false,
    this.isLiveSession = false,
    this.lastTranscript,
    this.transcriptSeq = 0,
    this.lastError,
    this.pendingQueueCount = 0,
  });

  VoiceState copyWith({
    bool? isRecording,
    bool? isProcessingSTT,
    bool? isSpeaking,
    bool? isLiveSession,
    String? lastTranscript,
    int? transcriptSeq,
    String? lastError,
    int? pendingQueueCount,
    bool clearTranscript = false,
    bool clearError = false,
  }) {
    return VoiceState(
      isRecording: isRecording ?? this.isRecording,
      isProcessingSTT: isProcessingSTT ?? this.isProcessingSTT,
      isSpeaking: isSpeaking ?? this.isSpeaking,
      isLiveSession: isLiveSession ?? this.isLiveSession,
      lastTranscript: clearTranscript ? null : (lastTranscript ?? this.lastTranscript),
      transcriptSeq: transcriptSeq ?? this.transcriptSeq,
      lastError: clearError ? null : (lastError ?? this.lastError),
      pendingQueueCount: pendingQueueCount ?? this.pendingQueueCount,
    );
  }
}

/// ProcessManager logunun son satırını okur (çapraz platform).
String _lastProcessManagerLogLine() {
  try {
    final f = File(p.join(AppPaths.ferideDataDir, 'logs', 'process_manager.log'));
    if (!f.existsSync()) {
      return 'process_manager.log henüz oluşturulmadı';
    }
    final lines = f.readAsLinesSync().where((l) => l.trim().isNotEmpty).toList();
    if (lines.isEmpty) return 'log boş';
    return lines.last;
  } catch (e) {
    return 'log okunamadı ($e)';
  }
}

class VoiceManager extends StateNotifier<VoiceState> {
  VoiceManager() : super(VoiceState());

  static final HttpClient _httpClient = HttpClient()
    ..connectionTimeout = const Duration(seconds: 8)
    ..idleTimeout = const Duration(seconds: 30);

  AudioRecorder? _audioRecorder;
  AudioRecorder get _recorder {
    _audioRecorder ??= AudioRecorder();
    return _audioRecorder!;
  }

  bool _isAudioRecorderDisposed = false;
  String? _recordPath;
  Process? _cliRecorderProc;
  WebSocketChannel? _channel;
  StreamSubscription? _audioStreamSub;
  int _ttsSessionGen = 0;

  /// Linux dağıtımlarında AudioRecorder eklentisi eksik bir araç yüzünden hata verirse
  /// doğrudan parecord / pw-record / arecord / ffmpeg ile yedek mikrofon kaydı başlatır.
  Future<bool> _startNativeCliFallback(String wavPath) async {
    if (!Platform.isLinux && !Platform.isMacOS) return false;
    final candidates = <List<String>>[
      if (Platform.isLinux) ...[
        ['parecord', '--file-format=wav', '--rate=16000', '--channels=1', wavPath],
        ['pw-record', '--rate=16000', '--channels=1', wavPath],
        ['arecord', '-q', '-f', 'S16_LE', '-r', '16000', '-c', '1', wavPath],
        ['ffmpeg', '-nostdin', '-hide_banner', '-loglevel', 'error', '-y', '-f', 'pulse', '-i', 'default', '-ar', '16000', '-ac', '1', wavPath],
      ],
      if (Platform.isMacOS) ...[
        ['ffmpeg', '-nostdin', '-hide_banner', '-loglevel', 'error', '-y', '-f', 'avfoundation', '-i', ':0', '-ar', '16000', '-ac', '1', wavPath],
      ],
    ];

    for (final cmd in candidates) {
      try {
        final proc = await Process.start(
          cmd.first,
          cmd.sublist(1),
          environment: AppPaths.buildSubprocessEnv(),
        );
        await Future.delayed(const Duration(milliseconds: 180));
        // Erken çökmüş mü kontrol et
        bool exitedEarly = false;
        proc.exitCode.timeout(const Duration(milliseconds: 10), onTimeout: () => -999).then((c) {
          if (c != -999) exitedEarly = true;
        });
        await Future.delayed(const Duration(milliseconds: 30));
        if (!exitedEarly) {
          _cliRecorderProc = proc;
          return true;
        }
      } catch (_) {}
    }
    return false;
  }

  Future<void> startRecording({bool autoStop = false, bool isLiveSession = false}) async {
    try {
      // Ses sunucularını arka planda hemen uyandır
      unawaited(ProcessManager.instance.startAll());

      if (_isAudioRecorderDisposed) {
        _audioRecorder = AudioRecorder();
        _isAudioRecorderDisposed = false;
      }

      Directory tempDir;
      try {
        tempDir = await getTemporaryDirectory();
      } catch (_) {
        tempDir = Directory.systemTemp;
      }
      _recordPath = p.join(
        tempDir.path,
        'feride_voice_${DateTime.now().millisecondsSinceEpoch}.wav',
      );

      bool hasMicPerm = true;
      try {
        hasMicPerm = await _recorder.hasPermission();
      } catch (_) {
        hasMicPerm = true;
      }

      if (!hasMicPerm) {
        state = state.copyWith(
          isRecording: false,
          isLiveSession: false,
          lastError: 'Mikrofon erişim izni verilmedi. Lütfen sistem ses/mikrofon izinlerini kontrol edin.',
        );
        return;
      }

      state = state.copyWith(
        isRecording: true,
        isLiveSession: isLiveSession,
        clearError: true,
        clearTranscript: true,
      );

      if (autoStop) {
        // LIVE SESSION (CANLI OTURUM VAD) MODU: Sunucunun hazır olduğundan emin ol
        await ProcessManager.instance.ensureVadReady(timeout: const Duration(seconds: 20));
        _channel = WebSocketChannel.connect(Uri.parse('ws://127.0.0.1:5051'));

        try {
          await _channel!.ready.timeout(const Duration(seconds: 12));
        } catch (_) {
          _channel = null;
          state = state.copyWith(
            isRecording: false,
            isLiveSession: false,
            lastError: 'Canlı ses sunucusu (port 5051) yanıt vermiyor.\n'
                'Son log: ${_lastProcessManagerLogLine()}',
          );
          return;
        }

        final audioStream = await _recorder.startStream(
          const RecordConfig(
            encoder: AudioEncoder.pcm16bits,
            numChannels: 1,
            sampleRate: 16000,
          ),
        );

        _audioStreamSub = audioStream.listen((data) {
          if (_channel != null) {
            _channel!.sink.add(data);
          }
        });

        _channel!.stream.listen((message) {
          try {
            final decoded = jsonDecode(message);
            if (decoded['type'] == 'transcript' || decoded['event'] == 'transcription') {
              final text = (decoded['text'] ?? '').toString().trim();
              if (text.isNotEmpty) {
                state = state.copyWith(
                  isRecording: false,
                  lastTranscript: text,
                  transcriptSeq: state.transcriptSeq + 1,
                  clearError: true,
                );
                stopRecording(fromLiveSession: true);
              }
            }
          } catch (_) {}
        }, onDone: () {
          stopRecording(fromLiveSession: true);
        });
      } else {
        // NORMAL SOHBET MİKROFON MODU: 16kHz Mono WAV kaydı
        try {
          await _recorder.start(
            const RecordConfig(
              encoder: AudioEncoder.wav,
              sampleRate: 16000,
              numChannels: 1,
            ),
            path: _recordPath!,
          );
        } catch (recErr) {
          final fallbackOk = await _startNativeCliFallback(_recordPath!);
          if (!fallbackOk) {
            state = state.copyWith(
              isRecording: false,
              isLiveSession: false,
              lastError: 'Mikrofon kaydı başlatılamadı: $recErr',
            );
          }
        }
      }
    } catch (e) {
      state = state.copyWith(
        isRecording: false,
        isLiveSession: false,
        lastError: 'Kayıt başlatılamadı: $e',
      );
    }
  }

  Future<String?> stopRecording({bool fromLiveSession = false}) async {
    final bool wasLive = fromLiveSession || state.isLiveSession;
    await _audioStreamSub?.cancel();
    _audioStreamSub = null;
    if (_channel != null) {
      try {
        _channel!.sink.add('stop');
        await _channel!.sink.close();
      } catch (_) {}
      _channel = null;
    }

    // Yedek CLI kaydedici aktifse nazikçe durdurup WAV başlığının yazılmasını bekle
    if (_cliRecorderProc != null) {
      final proc = _cliRecorderProc!;
      _cliRecorderProc = null;
      try {
        proc.kill(ProcessSignal.sigint);
        await proc.exitCode.timeout(
          const Duration(milliseconds: 1200),
          onTimeout: () {
            proc.kill(ProcessSignal.sigterm);
            return -1;
          },
        );
      } catch (_) {}
      state = state.copyWith(isRecording: false, isLiveSession: false);
      if (!wasLive && _recordPath != null) {
        return await processSTT(_recordPath!);
      }
      return state.lastTranscript;
    }

    try {
      if (await _recorder.isRecording()) {
        final path = await _recorder.stop().timeout(const Duration(seconds: 3));
        state = state.copyWith(isRecording: false, isLiveSession: false);
        final effectivePath = path ?? _recordPath;
        if (effectivePath != null && !wasLive) {
          return await processSTT(effectivePath);
        }
      } else {
        state = state.copyWith(isRecording: false, isLiveSession: false);
      }
    } catch (e) {
      state = state.copyWith(
        isRecording: false,
        isLiveSession: false,
        lastError: 'Kayıt durdurulamadı: $e',
      );
      try {
        if (await _recorder.isRecording()) {
          await _recorder.dispose();
          _isAudioRecorderDisposed = true;
        }
      } catch (_) {}
    }
    return state.lastTranscript;
  }

  Future<String?> processSTT(String audioPath) async {
    state = state.copyWith(isProcessingSTT: true, clearError: true);
    final file = File(audioPath);
    try {
      // Dosyanın diske tam yazılması için kısa kontrol
      for (int i = 0; i < 5; i++) {
        if (await file.exists() && await file.length() > 128) break;
        await Future.delayed(const Duration(milliseconds: 80));
      }

      if (!await file.exists()) {
        state = state.copyWith(isProcessingSTT: false, lastError: 'Ses kaydı dosyası oluşturulamadı.');
        return null;
      }

      final audioData = await file.readAsBytes();
      if (audioData.length < 100) {
        state = state.copyWith(
          isProcessingSTT: false,
          lastError: 'Mikrofondan ses verisi alınamadı (mikrofon sessizde olabilir).',
        );
        return null;
      }

      // STT sunucusunun hazır olduğundan emin ol (soğuk başlangıçta modeli bekler)
      final sttReady = await ProcessManager.instance.ensureSttReady(
        timeout: const Duration(seconds: 25),
      );
      if (!sttReady) {
        state = state.copyWith(
          isProcessingSTT: false,
          lastError: 'Ses tanıma (STT) motoru başlatılamadı. Ayarlar > Genel sekmesinden bağımlılıkları onarabilirsiniz.',
        );
        return null;
      }

      final request = await _httpClient
          .postUrl(Uri.parse('http://127.0.0.1:5052/transcribe'))
          .timeout(const Duration(seconds: 10));
      request.headers.set('Content-Type', 'application/octet-stream');
      request.headers.set('Content-Length', audioData.length.toString());
      request.add(audioData);

      final response = await request.close().timeout(const Duration(seconds: 45));
      final resBody = await response.transform(utf8.decoder).join();

      if (response.statusCode == 200) {
        final decoded = jsonDecode(resBody);
        final text = (decoded['text'] as String?)?.trim();

        state = state.copyWith(
          isProcessingSTT: false,
          isLiveSession: false,
          lastTranscript: text,
          transcriptSeq: state.transcriptSeq + 1,
          clearError: true,
        );
        return text;
      } else {
        state = state.copyWith(
          isProcessingSTT: false,
          lastError: 'STT Hatası (${response.statusCode}): $resBody',
        );
        return null;
      }
    } catch (e) {
      state = state.copyWith(
        isProcessingSTT: false,
        isLiveSession: false,
        lastError: 'STT İşlem Hatası: $e',
      );
      return null;
    } finally {
      try {
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {}
    }
  }

  AudioPlayer? _audioPlayer;
  bool _playerCreated = false;

  void _ensurePlayer() {
    if (!_playerCreated) {
      _playerCreated = true;
      _audioPlayer = AudioPlayer();
    }
  }

  AudioPlayer? get _player => _playerCreated ? _audioPlayer : null;

  final List<String> _ttsQueue = [];
  bool _isProcessingQueue = false;

  int get pendingQueueCount => _ttsQueue.length;

  void queueSentence(String sentence) {
    final s = sentence.trim();
    if (s.length < 3) return;
    _ttsQueue.add(s);
    state = state.copyWith(pendingQueueCount: _ttsQueue.length);
    if (!_isProcessingQueue) {
      _processQueue();
    }
  }

  Future<void> _processQueue() async {
    if (_isProcessingQueue) return;
    _isProcessingQueue = true;
    state = state.copyWith(isSpeaking: true, pendingQueueCount: _ttsQueue.length);
    final sw = Stopwatch()..start();
    final currentGen = _ttsSessionGen;

    try {
      while (_ttsQueue.isNotEmpty && currentGen == _ttsSessionGen) {
        final sentence = _ttsQueue.removeAt(0);
        state = state.copyWith(pendingQueueCount: _ttsQueue.length);
        await _speakSingle(sentence, manageSpeaking: false, expectedGen: currentGen);
        if (_ttsQueue.isNotEmpty && currentGen == _ttsSessionGen) {
          await Future.delayed(const Duration(milliseconds: 100));
        }
      }
      if (sw.elapsedMilliseconds < 300) {
        await Future.delayed(Duration(milliseconds: 300 - sw.elapsedMilliseconds));
      }
    } finally {
      if (currentGen == _ttsSessionGen) {
        _isProcessingQueue = false;
        state = state.copyWith(isSpeaking: false, pendingQueueCount: _ttsQueue.length);
      }
    }
  }

  void clearQueue() {
    _ttsSessionGen++;
    _ttsQueue.clear();
    final player = _player;
    if (player != null) {
      try {
        player.stop();
      } catch (_) {}
    }
    _isProcessingQueue = false;
    state = state.copyWith(isSpeaking: false, pendingQueueCount: 0);
  }

  Future<void> speak(String text) => _speakSingle(text);

  Future<void> _speakSingle(String text, {bool manageSpeaking = true, int? expectedGen}) async {
    if (expectedGen != null && expectedGen != _ttsSessionGen) return;
    if (manageSpeaking) state = state.copyWith(isSpeaking: true);
    File? tempFile;
    try {
      String cleanText = text;
      cleanText = cleanText.replaceAll(RegExp(r'<think>[\s\S]*?</think>'), '');
      cleanText = cleanText.replaceAll(RegExp(r'<tool_call>[\s\S]*?</tool_call>'), '');
      cleanText = cleanText.replaceAll(RegExp(r'\{[^}]*\}'), '');
      cleanText = cleanText.replaceAll(RegExp(r'\[[^\]]*\]'), '');
      cleanText = cleanText.replaceAll(RegExp(r'```[\s\S]*?```'), '');
      cleanText = cleanText.replaceAll(RegExp(r'`[^`]+`'), '');
      cleanText = cleanText.replaceAll(RegExp(r'\*+'), '');
      cleanText = cleanText.replaceAll(RegExp(r'#+\s*'), '');
      cleanText = cleanText.replaceAll(RegExp(r'https?://\S+'), '');
      cleanText = cleanText.replaceAll(RegExp(r'[<>{}()\[\]|\\/@#\$%^&=+~]'), ' ');
      cleanText = cleanText.replaceAll(RegExp(r'\s+'), ' ').trim();

      if (cleanText.length < 3) {
        if (manageSpeaking) state = state.copyWith(isSpeaking: false);
        return;
      }

      if (!Platform.environment.containsKey('FLUTTER_TEST') &&
          !ProcessManager.instance.isRunning('tts')) {
        unawaited(ProcessManager.instance.startAll());
      }

      final request = await _httpClient
          .postUrl(Uri.parse('http://127.0.0.1:5050/tts'))
          .timeout(const Duration(seconds: 10));
      request.headers.set('Content-Type', 'application/json');
      final payload = utf8.encode(jsonEncode({'text': cleanText, 'language': 'tr'}));
      request.headers.set('Content-Length', payload.length.toString());
      request.add(payload);

      final response = await request.close().timeout(const Duration(seconds: 30));
      if (response.statusCode == 200) {
        final audioBytes = await response.fold<List<int>>([], (prev, element) => prev..addAll(element));
        if (expectedGen != null && expectedGen != _ttsSessionGen) return;

        Directory tempDir;
        try {
          tempDir = await getTemporaryDirectory();
        } catch (_) {
          tempDir = Directory.systemTemp;
        }
        final ts = DateTime.now().microsecondsSinceEpoch;
        tempFile = File(p.join(tempDir.path, 'feride_tts_$ts.wav'));
        await tempFile.writeAsBytes(audioBytes);

        final fileSize = audioBytes.length;
        if (fileSize > 1000 && (expectedGen == null || expectedGen == _ttsSessionGen)) {
          _ensurePlayer();
          final player = _player;
          if (player != null) {
            await player.setVolume(1.5);
            await player.play(DeviceFileSource(tempFile.path));
            int byteRate = 44100;
            if (audioBytes.length >= 32) {
              final br = audioBytes[28] |
                  (audioBytes[29] << 8) |
                  (audioBytes[30] << 16) |
                  (audioBytes[31] << 24);
              if (br > 8000 && br < 1000000) {
                byteRate = br;
              }
            }
            final durationSec = (fileSize / byteRate).ceil() + 2;
            await player.onPlayerComplete.first.timeout(
              Duration(seconds: durationSec.clamp(3, 300)),
              onTimeout: () {
                try {
                  player.stop();
                } catch (_) {}
                return null;
              },
            );
          }
        }
      }
    } catch (e) {
      state = state.copyWith(lastError: 'TTS Hatası: $e');
    } finally {
      if (manageSpeaking) {
        state = state.copyWith(isSpeaking: false);
      }
      if (tempFile != null) {
        try {
          if (await tempFile.exists()) await tempFile.delete();
        } catch (_) {}
      }
    }
  }

  Future<void> stopSpeaking() async {
    _ttsSessionGen++;
    try {
      final player = _player;
      if (player != null) await player.stop();
    } catch (_) {}
    _isProcessingQueue = false;
    state = state.copyWith(isSpeaking: false);
  }

  @override
  void dispose() {
    _audioStreamSub?.cancel();
    _channel?.sink.close();
    if (!_isAudioRecorderDisposed && _audioRecorder != null) {
      _audioRecorder!.dispose();
      _isAudioRecorderDisposed = true;
    }
    if (_playerCreated && _audioPlayer != null) {
      _audioPlayer!.dispose();
    }
    super.dispose();
  }
}
