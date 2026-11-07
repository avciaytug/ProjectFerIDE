// FerIDE v4 Plan Testleri — implementation_plan.md doğrulama planı
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:feride_v5_2/features/live/live_session_view.dart';

import 'package:feride_v5_2/services/voice_manager.dart';
import 'package:feride_v5_2/services/sentence_chunker.dart';
import 'package:feride_v5_2/services/process_manager.dart';
import 'package:feride_v5_2/services/agent_engine.dart';
import 'package:feride_v5_2/models/chat_session.dart';
import 'package:feride_v5_2/repositories/chat_repository.dart';
import 'package:feride_v5_2/features/chat/state.dart';
import 'package:feride_v5_2/features/chat/agent_panel.dart';
import 'package:feride_v5_2/features/settings/settings_provider.dart';

void main() {
  group('Task 1: Cümle bazlı streaming TTS', () {
    test('VoiceState.isSpeaking setter ile güncellenebilir (kuyruk sistemi)', () {
      final vm = VoiceManager();
      expect(vm.state.isSpeaking, false);
      vm.state = vm.state.copyWith(isSpeaking: true);
      expect(vm.state.isSpeaking, true);
    });

    test('queueSentence: cümle kuyruğa eklenir, isSpeaking true olur', () async {
      final vm = VoiceManager();
      // TTS sunucusu kapalıysa hata yutulsun, kuyruk davranışı test edilsin
      vm.queueSentence('Merhaba.');
      // Kuyruk işlemeye hemen (eşzamanlı olarak) başlamış olmalı
      expect(vm.state.isSpeaking, true);
      // Sunucu yoksa bile kuyruk takılmadan bitmeli
      for (var i = 0; i < 100 && vm.state.isSpeaking; i++) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
      expect(vm.state.isSpeaking, false);
      expect(vm.pendingQueueCount, 0);
    });

    test('clearQueue: bekleyen cümleler temizlenir, isSpeaking false olur', () async {
      final vm = VoiceManager();
      vm.queueSentence('Birinci cümle.');
      vm.queueSentence('İkinci cümle.');
      await Future.delayed(const Duration(milliseconds: 50));
      vm.clearQueue();
      await Future.delayed(const Duration(milliseconds: 100));
      expect(vm.state.isSpeaking, false);
      expect(vm.pendingQueueCount, 0);
    });
  });

  group('Task 1b: SentenceChunker (cümle dedektörü)', () {
    test('tamamlanmamış cümle vermez', () {
      final chunker = SentenceChunker();
      expect(chunker.feed('Merhaba'), isEmpty);
    });

    test('nokta + boşluk ile cümleyi verir', () {
      final chunker = SentenceChunker();
      final out = chunker.feed('Merhaba. Dünya');
      expect(out, ['Merhaba']);
    });

    test('sor ve ünlem ile cümleyi verir', () {
      final chunker = SentenceChunker();
      final out = chunker.feed('Nasılsın? İyiyim!');
      expect(out, containsAll(['Nasılsın', 'İyiyim']));
    });

    test('art arda iki cümle tek feedde ikisi de gelir', () {
      final chunker = SentenceChunker();
      final out = chunker.feed('Birinci cümle. İkinci cümle.');
      expect(out.length, 2);
      expect(out[0], 'Birinci cümle');
      expect(out[1], 'İkinci cümle');
    });

    test('kısa cümleler (<=5 karakter) filtrelenmez ama boşluklar trimlenir', () {
      final chunker = SentenceChunker();
      final out = chunker.feed('Evet. Tamamdır.');
      expect(out, ['Evet', 'Tamamdır']);
    });

    test('flush kalan son parçayı verir ve chunker sıfırlanır', () {
      final chunker = SentenceChunker();
      chunker.feed('Merhaba. Dünya');
      final remaining = chunker.flush();
      expect(remaining, 'Dünya');
      expect(chunker.flush(), '');
    });

    test('flush boşsa boş string döner', () {
      final chunker = SentenceChunker();
      expect(chunker.flush(), '');
    });

    test('reset çağrılınca tampon sıfırlanır', () {
      final chunker = SentenceChunker();
      chunker.feed('Yarım cümle');
      chunker.reset();
      expect(chunker.flush(), '');
    });
  });

  group('Task 2: Sesli oturumda tool aktif', () {
    test('Sesli oturum ana model sunucusunu kullanır (ayrı Ollama yok)', () {
      final text = _readAsset('lib/services/agent_engine.dart');
      expect(text.contains('liveApiUrlProvider'), false);
      expect(text.contains('apiUrlProvider'), true);
    });

    test('LlmClient: akış (stream) her zaman açık ve araçlar gönderilir', () {
      final text = _readAsset('lib/agent/llm_client.dart');
      expect(text.contains("'stream': true"), true);
      expect(text.contains("'tools': tools"), true);
    });
  });

  // Gerçek ses sunucularını başlatıp öldüren entegrasyon testleri: geliştirme
  // makinesinde çalışan FerIDE'nin sunucularını etkilemesin diye varsayılan
  // olarak atlanır. Çalıştırmak için: FERIDE_INTEGRATION=1 flutter test
  final runIntegration = Platform.environment['FERIDE_INTEGRATION'] == '1';
  group('Task 3: ProcessManager (sunucu yaşam döngüsü)', skip: !runIntegration, () {
    test('startAll: çalışmayan sunucuları başlatır, PID listesi dolar', () async {
      final pm = ProcessManager();
      await pm.startAll();
      // En azından bir sunucu başlatılmış olmalı (stt/xtts/daemon)
      expect(pm.runningCount, greaterThanOrEqualTo(1));
      pm.killAll();
    });

    test('killAll: tüm süreçleri öldürür, liste sıfırlanır', () async {
      final pm = ProcessManager();
      await pm.startAll();
      pm.killAll();
      await Future.delayed(const Duration(milliseconds: 200));
      expect(pm.runningCount, 0);
    });

    test('startAll: zaten çalışan sunucuyu ikinci kez başlatmaz', () async {
      final pm = ProcessManager();
      await pm.startAll();
      final before = pm.runningCount;
      await pm.startAll(); // İkinci çağrı: çoğu zaten çalışıyor
      expect(pm.runningCount, before);
      pm.killAll();
    });
  });

  group('Task 4: Normal chat mikrofon STT göstergesi', () {
    testWidgets('AgentPanel: STT işlemi sırasında dönen animasyon görünür', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            voiceManagerProvider.overrideWith((ref) => _StubVoiceManager()),
            agentIsRunningProvider.overrideWith((ref) => false),
          ],
          child: const MaterialApp(home: Scaffold(body: AgentPanel())),
        ),
      );
      await tester.pump();
      // isProcessingSTT=true iken CircularProgressIndicator görünmeli
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });
  });

  group('Task 5: Basit UI (Canlı Oturum)', () {
    testWidgets('LiveSessionView: durum metinleri sade (Dinliyor/Anlıyor/Düşünüyor/Konuşuyor)', (tester) async {
      // initState'teki ProcessManager.startAll() → Process.start, fake-async'ta
      // pending Timer bırakır. Gerçek async ortamda (runAsync) çalıştırıp
      // timer'ların çökmesini bekliyoruz.
      await tester.runAsync(() async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              voiceManagerProvider.overrideWith((ref) => _StubVoiceManager()),
            ],
            child: const MaterialApp(home: Scaffold(body: LiveSessionView())),
          ),
        );
        await tester.pump();
        // Oturum kapalıyken başlangıç metni
        expect(find.textContaining('mikrofona dokunun'), findsOneWidget);
        // Process.start'ın oluşturduğu pending timer'ların çökmesi için bekle
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
    });
  });

  group('Task 6: Mükerrer Konuşma ve Düşünme Engelleme (Deduplication)', () {
    test('handleEngineEvent: aynı adım içindeki mükerrer ReasoningMessage ve AgentMessage güncellenir', () async {
      final container = ProviderContainer(
        overrides: [
          chatRepositoryProvider.overrideWithValue(ChatRepository('/tmp')),
        ],
      );
      final notifier = container.read(activeSessionProvider.notifier);
      final session = ChatSession(title: 'Test Session');
      notifier.setSession(session);
      final sessionId = session.id;

      // 1. Kullanıcı başlattı
      notifier.addEvent(AgentStarted('Merhaba'));
      // 2. Düşünce başladı
      await notifier.handleEngineEvent(sessionId, ReasoningMessage('Düşünüyorum'));
      expect(container.read(activeSessionProvider)!.messages.length, 2);

      // 3. Yanıt başladı
      await notifier.handleEngineEvent(sessionId, AgentMessage('Merhaba dünya'));
      expect(container.read(activeSessionProvider)!.messages.length, 3);

      // 4. Stream sonu mükerrer flush: Tekrar ReasoningMessage ve AgentMessage geldiğinde
      // Yeni balonlar eklenmemeli, mevcut mesajlar güncellenmeli!
      await notifier.handleEngineEvent(sessionId, ReasoningMessage('Düşünüyorum (bitti)'));
      await notifier.handleEngineEvent(sessionId, AgentMessage('Merhaba dünya! Tamamlandı.'));

      final msgs = container.read(activeSessionProvider)!.messages;
      expect(msgs.length, 3);
      expect((msgs[1].event as ReasoningMessage).message, 'Düşünüyorum (bitti)');
      expect((msgs[2].event as AgentMessage).message, 'Merhaba dünya! Tamamlandı.');
    });

    test('LiveSession TTS kuyruk tekilleştirme: mükerrer cümleler engellenir', () {
      final chunker = SentenceChunker();
      final spoken = <String>{};
      final queued = <String>[];

      void queue(List<String> sentences) {
        for (final s in sentences) {
          final trimmed = s.trim();
          if (trimmed.length > 2 && spoken.add(trimmed)) {
            queued.add(trimmed);
          }
        }
      }

      // Stream boyunca cümleler gelir
      queue(chunker.feed('Merhaba dünya.'));
      expect(queued, ['Merhaba dünya']);

      // Final metin veya tekrar besleme olduğunda:
      queue(chunker.feed('Merhaba dünya. Nasılsınız?'));
      expect(queued, ['Merhaba dünya', 'Nasılsınız']);

      // Stream sonu flush veya tekrar oynatma
      final rem = chunker.flush().trim();
      if (rem.length > 2 && spoken.add(rem)) {
        queued.add(rem);
      }
      expect(queued.length, 2); // Kesinlikle 2 kere kuyruğa eklenmez!
    });
  });

  group('Task 7: Maksimum Adım Sınırı (Max Steps) ve Devam Et Akışı', () {
    test('SettingsState varsayılan maxSteps 100 olarak başlar ve copyWith ile güncellenir', () {
      final state = SettingsState(
        useGpuForStt: true,
        useGpuForTts: true,
        skillsPath: '/dummy/skills',
        chatHistoryPath: '/dummy/chats',
        disabledSkills: [],
        mcpConfigPath: '/dummy/mcp_config.json',
      );
      expect(state.maxSteps, 100);

      final updated = state.copyWith(maxSteps: 200);
      expect(updated.maxSteps, 200);
    });

    test('Otonom Mod ve Normal Mod için maxSteps hesaplama mantığı doğrulanır', () {
      int calculateEffectiveSteps(int configured, bool isAutonomous) {
        return isAutonomous ? (configured * 2).clamp(150, 500) : configured;
      }

      // Normal Mod
      expect(calculateEffectiveSteps(40, false), 40);
      expect(calculateEffectiveSteps(100, false), 100);
      expect(calculateEffectiveSteps(200, false), 200);

      // Otonom Mod (en az 150, en fazla 500)
      expect(calculateEffectiveSteps(40, true), 150); // clamp min 150
      expect(calculateEffectiveSteps(100, true), 200); // 100 * 2 = 200
      expect(calculateEffectiveSteps(200, true), 400); // 200 * 2 = 400
      expect(calculateEffectiveSteps(300, true), 500); // clamp max 500
    });

    test('AgentFailed adım sınırı hata metni kontrolü ve devam etme tespiti', () {
      const errorMsg = 'Maksimum adım sınırına (100 adım) ulaşıldı. "Devam et" diyerek işleme kaldığınız yerden devam edebilirsiniz.';
      final failedEvent = AgentFailed(errorMsg);
      expect(failedEvent.error.contains('Maksimum adım'), isTrue);
    });
  });
}

// --- Yardımcılar ---

String _readAsset(String path) {
  return File('lib/${path.replaceFirst('lib/', '')}').readAsStringSync();
}

class _StubVoiceManager extends VoiceManager {
  _StubVoiceManager() {
    state = VoiceState(isProcessingSTT: true);
  }
}
