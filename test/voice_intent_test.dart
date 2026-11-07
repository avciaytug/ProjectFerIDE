import 'package:feride_v5_2/features/live/voice_intent.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Sesle onay', () {
    test('olumlu yanıtlar', () {
      for (final t in ['Evet.', 'Tamam yap', 'Olur', 'Onaylıyorum', 'evet devam et']) {
        expect(VoiceIntent.classifyYesNo(t), YesNo.yes, reason: t);
      }
    });

    test('olumsuz yanıtlar ve olumsuzluk önceliği', () {
      for (final t in ['Hayır', 'İptal et', 'Vazgeç', 'hayır yapma', 'Tamam, hayır vazgeçtim', 'Gerek yok']) {
        expect(VoiceIntent.classifyYesNo(t), YesNo.no, reason: t);
      }
    });

    test('belirsiz yanıt null döner', () {
      expect(VoiceIntent.classifyYesNo('Bilmiyorum ne diyeyim'), isNull);
    });
  });
}
