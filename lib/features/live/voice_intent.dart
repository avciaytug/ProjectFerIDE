import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Uygulama genelinde diyalog açabilmek için kök gezgin anahtarı.
final rootNavigatorKey = GlobalKey<NavigatorState>();

/// Sesli asistan penceresi açık mı? (İkinci kez açılmasını engeller.)
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
