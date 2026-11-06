import 'package:feride_v5_2/features/live/wake_word.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Uyandırma kelimesi', () {
    test('komutlu çağrı: komut ayrıştırılır', () {
      expect(VoiceIntent.matchWake('Feride, masaüstündeki dosyaları listele.'),
          'masaüstündeki dosyaları listele.');
      expect(VoiceIntent.matchWake('Hey Feride saat kaç?'), 'saat kaç?');
    });

    test('yalnızca isim: boş komut', () {
      expect(VoiceIntent.matchWake('Feride.'), '');
      expect(VoiceIntent.matchWake('FERİDE'), '');
    });

    test('Whisper yazım varyasyonları ve ekler', () {
      expect(VoiceIntent.matchWake('Ferit, müziği aç'), 'müziği aç');
      expect(VoiceIntent.matchWake("Feride'ye sor bakalım"), 'sor bakalım');
      expect(VoiceIntent.matchWake('Feridé hava nasıl'), 'hava nasıl');
      expect(VoiceIntent.matchWake('Felida.'), ''); // Whisper duyma hatası
      expect(VoiceIntent.matchWake('Felaket bir gün'), isNull);
      expect(VoiceIntent.matchWake('Fethiye çok sıcak'), isNull);
    });

    test('sıradan konuşmalar uyandırmaz', () {
      expect(VoiceIntent.matchWake('Bugün hava çok güzel'), isNull);
      expect(VoiceIntent.matchWake('Ferah bir oda'), isNull);
      expect(VoiceIntent.matchWake('Dün Feride ile konuştum'), isNull); // isim cümlenin başında değil
      expect(VoiceIntent.matchWake(''), isNull);
    });
  });

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
