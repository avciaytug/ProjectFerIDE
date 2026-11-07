// Model seçimi regresyon testi: "GLM-4.5-Air'i seçince gemma geliyor" hatası.
// Uygulamanın gerçek model seçim kodu, sahte bir llama-server (HTTP) ve kaydedici
// bir motor yöneticisiyle çalıştırılır.
import 'dart:convert';
import 'dart:io';

import 'package:feride_v5_2/features/chat/state.dart';
import 'package:feride_v5_2/features/settings/settings_provider.dart';
import 'package:feride_v5_2/services/backend_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// llama-server taklidi: /v1/models yüklü modeli bildirir. Durdurulduktan sonra
/// bir süre daha eski modelle yanıt verir (gerçek sunucunun kapanma gecikmesi).
class FakeServer {
  late final HttpServer http;
  String? model;
  Future<void> start() async {
    http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    http.listen((req) {
      if (model == null) {
        req.response.statusCode = 503;
      } else {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({
          'data': [
            {'id': model}
          ]
        }));
      }
      req.response.close();
    });
  }

  String get api => 'http://127.0.0.1:${http.port}/v1';
}

class RecordingBackend extends BackendManager {
  final Ref ref;
  final FakeServer server;
  final starts = <String>[];
  RecordingBackend(this.ref, this.server) : super(ref);

  @override
  Future<void> stopBackend({int port = 8080}) async {
    ref.read(isBackendRunningProvider.notifier).state = false;
    // Eski sunucu 600 ms daha yanıt vermeye devam eder.
    Future.delayed(const Duration(milliseconds: 600), () => server.model = null);
  }

  @override
  Future<void> startBackend(BackendConfig config) async {
    starts.add(p.basename(config.modelPathOrName));
    await Future.delayed(const Duration(milliseconds: 900)); // yükleme
    server.model = config.modelPathOrName;
    ref.read(isBackendRunningProvider.notifier).state = true;
  }
}

void main() {
  late Directory tmp;
  late FakeServer server;
  late ProviderContainer c;
  late RecordingBackend backend;
  final originalCwd = Directory.current;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('feride_switch_');
    final models = Directory(p.join(tmp.path, 'models'))..createSync();
    for (final f in [
      'gemma-4-12b-it-UD-Q8_K_XL.gguf',
      'GLM-4.5-Air-Q4_K_S-00001-of-00002.gguf',
      'GLM-4.5-Air-Q4_K_S-00002-of-00002.gguf',
    ]) {
      File(p.join(models.path, f)).writeAsStringSync('x');
    }
    Directory.current = tmp; // model tarama dizinlerinden biri: <cwd>/models
    server = FakeServer();
    await server.start();
    server.model = p.join(models.path, 'gemma-4-12b-it-UD-Q8_K_XL.gguf'); // gemma çalışıyor
    SharedPreferences.setMockInitialValues({
      'apiUrl': server.api,
      'preferredModel': 'gemma-4-12b-it-UD-Q8_K_XL.gguf',
      'customLlamaServerPath': Platform.resolvedExecutable,
    });
    final prefs = await SharedPreferences.getInstance();
    c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      backendManagerProvider.overrideWith((ref) {
        backend = RecordingBackend(ref, server);
        return backend;
      }),
    ]);
    c.read(backendManagerProvider);
  });

  tearDown(() async {
    Directory.current = originalCwd;
    await server.http.close(force: true);
    c.dispose();
    tmp.deleteSync(recursive: true);
  });

  test('gemma çalışırken GLM seçilince GLM yüklenir; seçim gemma ile ezilmez', () async {
    final notifier = c.read(selectedModelProvider.notifier);
    await notifier.syncWithRunningServer();
    expect(c.read(selectedModelProvider), 'gemma-4-12b-it-UD-Q8_K_XL.gguf');

    final seen = <String>[];
    c.listen<String>(selectedModelProvider, (_, n) => seen.add(n));

    // Açılır menüden GLM seçilir. Uygulamada ayar değişince arka planda
    // "sunucuyla eşitle" adımı da çalışır; aynısını eşzamanlı tetikliyoruz.
    final switching = notifier.switchModel('GLM-4.5-Air-Q4_K_S');
    final syncs = [for (var i = 0; i < 5; i++) Future.delayed(Duration(milliseconds: 50 + i * 150), notifier.syncWithRunningServer)];
    await switching;
    await Future.wait(syncs);
    await notifier.syncWithRunningServer();

    expect(backend.starts, ['GLM-4.5-Air-Q4_K_S-00001-of-00002.gguf'], reason: 'yalnızca GLM, bir kez yüklenmeli');
    expect(c.read(selectedModelProvider), 'GLM-4.5-Air-Q4_K_S');
    expect(c.read(settingsProvider).preferredModel, 'GLM-4.5-Air-Q4_K_S');
    expect(seen.where((s) => s.startsWith('gemma')), isEmpty, reason: 'seçim hiçbir an gemma\'ya dönmemeli: $seen');

    // Aynı model yeniden seçilirse yeniden yüklenmez.
    await notifier.switchModel('GLM-4.5-Air-Q4_K_S');
    expect(backend.starts.length, 1);
  });

  test('Seçilen model diskte yoksa yerine başka model sessizce yüklenmez', () async {
    final notifier = c.read(selectedModelProvider.notifier);
    await notifier.syncWithRunningServer();
    await notifier.switchModel('Silinmis-Model-Q4_K_M.gguf');
    expect(backend.starts, isEmpty, reason: 'eskiden diskteki ilk model (gemma) yükleniyordu');
    expect(c.read(selectedModelProvider), 'Silinmis-Model-Q4_K_M.gguf');
    expect(c.read(lastBackendStatusMessageProvider), contains('diskte bulunamadı'));
  });

  test('Başlıktaki menü her zaman gerçekten seçili/çalışan modeli gösterir', () {
    const models = ['gemma-4-12b-it-UD-Q8_K_XL.gguf', 'Qwen3.8-35B-A3B-Q8_0.gguf', 'GLM-4.5-Air-Q4_K_S'];
    expect(headerModelValue(models, 'GLM-4.5-Air-Q4_K_S-00001-of-00002.gguf'), 'GLM-4.5-Air-Q4_K_S');
    expect(headerModelValue(models, '/m/Qwen3.8-35B-A3B-Q8_0.gguf'), 'Qwen3.8-35B-A3B-Q8_0.gguf');
    // Listede yoksa listenin ilk modeli (yanlış bilgi) değil, kendisi gösterilir.
    expect(headerModelValue(models, 'baska-model.gguf'), 'baska-model.gguf');
  });
}
