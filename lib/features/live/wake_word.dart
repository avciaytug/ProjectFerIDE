import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/voice_manager.dart';
import '../settings/settings_provider.dart';

/// Uygulama genelinde diyalog açabilmek için kök gezgin anahtarı.
final rootNavigatorKey = GlobalKey<NavigatorState>();

/// Sesli asistan penceresi açık mı? (Açıkken uyandırma dinleyicisi susar.)
final voiceDialogOpenProvider = StateProvider<bool>((ref) => false);

enum YesNo { yes, no }

/// Konuşma metni üzerinde çalışan saf yardımcılar (birim testli).
class VoiceIntent {
  /// Türkçe karakterleri sadeleştirir, küçük harfe çevirir, noktalamayı atar.
  static String normalize(String s) {
    final lower = s.replaceAll('İ', 'i').replaceAll('I', 'ı').toLowerCase();
    const map = {'ı': 'i', 'ş': 's', 'ğ': 'g', 'ü': 'u', 'ö': 'o', 'ç': 'c', 'â': 'a', 'î': 'i', 'û': 'u'};
    final b = StringBuffer();
    for (final ch in lower.split('')) {
      b.write(map[ch] ?? ch);
    }
    return b.toString().replaceAll(RegExp(r"[^a-z0-9\s']"), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static int _lev(String a, String b) {
    final d = List.generate(a.length + 1, (i) => List.filled(b.length + 1, 0));
    for (var i = 0; i <= a.length; i++) {
      d[i][0] = i;
    }
    for (var j = 0; j <= b.length; j++) {
      d[0][j] = j;
    }
    for (var i = 1; i <= a.length; i++) {
      for (var j = 1; j <= b.length; j++) {
        d[i][j] = [
          d[i - 1][j] + 1,
          d[i][j - 1] + 1,
          d[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1),
        ].reduce((x, y) => x < y ? x : y);
      }
    }
    return d[a.length][b.length];
  }

  /// "Feride" kelimesine benziyor mu? Whisper bazen "Ferit", "Feridé",
  /// "Ferideye" gibi yazar; ekleri ve küçük hataları tolere eder.
  static bool _isWakeToken(String t) {
    final w = t.replaceAll("'", '');
    if (w.length < 4) return false;
    if (w.startsWith('ferid') || w.startsWith('ferit')) return true;
    final head = w.length > 6 ? w.substring(0, 6) : w;
    // "Felida", "Feride" gibi duyulma hataları: "fe" ile başlayan ve en çok 2 harf farklı.
    return _lev(head, 'feride') <= (w.startsWith('fe') ? 2 : 1);
  }

  /// Uyandırma kelimesini arar. Eşleşirse kelimeden sonraki komutu döndürür
  /// (boş olabilir: kullanıcı yalnızca "Feride" demiştir).
  static String? matchWake(String transcript) {
    final words = transcript.trim().split(RegExp(r'\s+'));
    // Yalnızca baştaki birkaç kelimeye bak ("hey Feride", "Feride bak").
    for (var i = 0; i < words.length && i < 3; i++) {
      final n = normalize(words[i]);
      if (n.isEmpty) continue;
      if (_isWakeToken(n)) {
        final rest = words.sublist(i + 1).join(' ').replaceFirst(RegExp(r'^[\s,.:;!?-]+'), '').trim();
        return rest;
      }
      if (!const {'hey', 'hi', 'ey', 'hadi', 'selam', 'merhaba', 'tamam', 'sey'}.contains(n)) return null;
    }
    return null;
  }

  static const _no = ['hayir', 'iptal', 'vazgec', 'reddet', 'istemiyorum', 'yapma', 'olmaz', 'dur', 'durdur', 'gerek yok'];
  static const _yes = ['evet', 'tamam', 'olur', 'onayliyorum', 'onay', 'izin ver', 'yap', 'devam', 'tabii', 'tabi', 'kabul'];

  /// Onay sorusuna verilen sesli yanıtı yorumlar; belirsizse null.
  static YesNo? classifyYesNo(String transcript) {
    final n = ' ${normalize(transcript)} ';
    // "hayır, yapma" gibi ifadelerde olumsuzluk önceliklidir.
    if (_no.any((w) => n.contains(' $w '))) return YesNo.no;
    if (_yes.any((w) => n.contains(' $w '))) return YesNo.yes;
    return null;
  }
}

/// Uyandırma kelimesi dinleyicisinin durumu.
class WakeState {
  final bool enabled;
  final bool listening;
  const WakeState({this.enabled = false, this.listening = false});
}

/// "Feride" denildiğinde sesli asistanı açan arka plan dinleyicisi.
///
/// Mikrofon yalnızca kullanıcı bu özelliği açtığında dinlenir ve ses hiçbir
/// zaman bilgisayardan çıkmaz (yerel VAD + yerel Whisper). Sesli asistan
/// penceresi veya sohbet mikrofonu kullanılırken kendiliğinden susar.
class WakeWordController extends Notifier<WakeState> {
  Timer? _timer;

  /// Uyandırma algılandığında çağrılır (komut boş olabilir).
  void Function(String command)? onWake;

  @override
  WakeState build() {
    ref.onDispose(() => _timer?.cancel());
    ref.listen<VoiceState>(voiceManagerProvider, _onVoice);
    bool enabled = false;
    try {
      enabled = ref.watch(settingsProvider.select((s) => s.wakeWordEnabled));
    } catch (_) {}
    _timer?.cancel();
    if (enabled) {
      _timer = Timer.periodic(const Duration(milliseconds: 1200), (_) => _tick());
      Future.microtask(_tick);
    } else {
      Future.microtask(_release);
    }
    return WakeState(enabled: enabled);
  }

  void setEnabled(bool v) => ref.read(settingsProvider.notifier).setWakeWordEnabled(v);

  bool get _ownsMic {
    final vs = ref.read(voiceManagerProvider);
    return vs.isRecording && vs.micOwner == 'wake';
  }

  void _release() {
    if (_ownsMic) ref.read(voiceManagerProvider.notifier).stopRecording(fromLiveSession: true);
    if (state.listening) state = WakeState(enabled: state.enabled);
  }

  void _tick() {
    if (!state.enabled) return;
    if (ref.read(voiceDialogOpenProvider)) {
      if (state.listening) state = WakeState(enabled: state.enabled);
      return;
    }
    final vs = ref.read(voiceManagerProvider);
    final busy = vs.isRecording || vs.isProcessingSTT || vs.isSpeaking || vs.pendingQueueCount > 0;
    final listening = vs.isRecording && vs.micOwner == 'wake';
    if (listening != state.listening) state = WakeState(enabled: true, listening: listening);
    if (!busy) {
      ref.read(voiceManagerProvider.notifier).startRecording(autoStop: true, isLiveSession: true, owner: 'wake');
    }
  }

  void _onVoice(VoiceState? prev, VoiceState next) {
    if (!state.enabled) return;
    final isNew = next.transcriptSeq > (prev?.transcriptSeq ?? 0) && next.transcriptOwner == 'wake';
    if (!isNew) return;
    final command = VoiceIntent.matchWake(next.lastTranscript ?? '');
    if (command != null) onWake?.call(command);
    // Eşleşmediyse bir sonraki tıkta dinlemeye devam edilir.
  }
}

final wakeWordProvider = NotifierProvider<WakeWordController, WakeState>(WakeWordController.new);
