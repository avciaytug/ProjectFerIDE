// Gerçek ses hattı entegrasyon testi (TTS → DC kaymalı "mikrofon" → VAD → STT → niyet).
// Gerçek sunucular başlatıldığı için yalnızca açıkça istenince çalışır:
//   FERIDE_INTEGRATION=1 flutter test test/voice_pipeline_integration_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:feride_v5_2/features/live/wake_word.dart';
import 'package:feride_v5_2/services/process_manager.dart';
import 'package:flutter_test/flutter_test.dart';

/// TTS'ten WAV alır ve 16 kHz int16 PCM'e çevirir.
Future<Int16List> _speak(String text) async {
  final client = HttpClient();
  final req = await client.postUrl(Uri.parse('http://127.0.0.1:5050/tts'));
  req.headers.contentType = ContentType.json;
  req.add(utf8.encode(jsonEncode({'text': text})));
  final res = await req.close();
  final bytes = await res.fold<List<int>>([], (a, b) => a..addAll(b));
  client.close();
  final data = ByteData.sublistView(Uint8List.fromList(bytes));
  final sr = data.getUint32(24, Endian.little);
  final samples = (bytes.length - 44) ~/ 2;
  final src = List<double>.generate(samples, (i) => data.getInt16(44 + i * 2, Endian.little) / 32768.0);
  final outLen = (samples * 16000 / sr).floor();
  return Int16List.fromList(List.generate(outLen, (i) {
    final v = src[(i * sr / 16000).floor().clamp(0, samples - 1)];
    return (v * 32767).round();
  }));
}

/// Kullanıcının mikrofonunu taklit eder: −0,23 DC + 10 Hz uğultu + gürültü.
Uint8List _asUserMic(Int16List speech) {
  final rnd = math.Random(1);
  final total = 8000 + speech.length + 32000;
  final out = Int16List(total);
  for (var i = 0; i < total; i++) {
    final s = (i >= 8000 && i < 8000 + speech.length) ? speech[i - 8000] / 32768.0 * 0.35 : 0.0;
    final v = s - 0.233 + 0.01 * math.sin(2 * math.pi * 10 * i / 16000) + 0.002 * (rnd.nextDouble() * 2 - 1);
    out[i] = (v.clamp(-1.0, 1.0) * 32767).round();
  }
  return out.buffer.asUint8List();
}

Future<String> _transcribeViaVad(Uint8List pcm) async {
  final ws = await WebSocket.connect('ws://127.0.0.1:5051');
  final done = ws.firstWhere((m) => m is String && (jsonDecode(m) as Map)['type'] == 'transcript');
  for (var i = 0; i < pcm.length; i += 3200) {
    ws.add(pcm.sublist(i, math.min(i + 3200, pcm.length)));
    await Future.delayed(const Duration(milliseconds: 100));
  }
  final msg = await done.timeout(const Duration(seconds: 30));
  await ws.close();
  return (jsonDecode(msg as String) as Map)['text'] as String;
}

void main() {
  final enabled = Platform.environment['FERIDE_INTEGRATION'] == '1';
  final pm = ProcessManager();

  setUpAll(() async {
    if (!enabled) return;
    await pm.startAll();
    expect(await pm.ensureVadReady(timeout: const Duration(seconds: 60)), isTrue);
    for (var i = 0; i < 60; i++) {
      try {
        final s = await Socket.connect('127.0.0.1', 5050, timeout: const Duration(milliseconds: 300));
        s.destroy();
        break;
      } catch (_) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }
  });
  tearDownAll(() {
    if (enabled) pm.killAll();
  });

  test('"Evet." DC kaymalı mikrofonda doğru duyulur ve onay sayılır', () async {
    final text = await _transcribeViaVad(_asUserMic(await _speak('Evet.')));
    // ignore: avoid_print
    print('duyulan: $text');
    expect(VoiceIntent.classifyYesNo(text), YesNo.yes);
  }, skip: !enabled, timeout: const Timeout(Duration(minutes: 2)));

  test('"Feride, saat kaç?" uyandırır ve komutu ayırır', () async {
    final text = await _transcribeViaVad(_asUserMic(await _speak('Feride, saat kaç?')));
    // ignore: avoid_print
    print('duyulan: $text');
    final cmd = VoiceIntent.matchWake(text);
    expect(cmd, isNotNull);
    expect(cmd!.toLowerCase(), contains('saat'));
  }, skip: !enabled, timeout: const Timeout(Duration(minutes: 2)));
}
