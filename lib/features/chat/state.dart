import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:async';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import '../../models/chat_session.dart';
import '../../models/chat_folder.dart';
import '../../repositories/chat_repository.dart';
import '../../services/agent_engine.dart';
import '../../services/app_paths.dart';
import '../../services/claude_tools.dart';
import '../../services/backend_manager.dart';
import '../../services/system_installer_service.dart';
import '../settings/settings_provider.dart';

// 1. Theme State (Dark / Light)
final themeModeProvider = StateProvider<ThemeMode>((ref) => ThemeMode.dark);


// 2. Language State (TR / EN)
enum AppLanguage { tr, en }

final languageProvider = StateProvider<AppLanguage>((ref) => AppLanguage.tr);

final localizationProvider = Provider<Map<String, Map<String, String>>>((ref) {
  return {
    'search': {'tr': 'Sohbet ara...', 'en': 'Search chat...'},
    'new_chat': {'tr': 'Yeni Sohbet', 'en': 'New Chat'},
    'live_sessions': {'tr': 'CANLI OTURUMLAR', 'en': 'LIVE SESSIONS'},
    'active_voice': {
      'tr': 'Aktif: Sesli Ajan (TR)',
      'en': 'Active: Voice Agent (EN)'
    },
    'chat_history': {'tr': 'SOHBET GEÇMİŞİ', 'en': 'CHAT HISTORY'},
    'context_usage': {'tr': 'Kontekst Kullanımı', 'en': 'Context Usage'},
    'send_msg': {
      'tr': 'FerIDE\'ye mesaj gönder...',
      'en': 'Send message to FerIDE...'
    },
    'settings': {'tr': 'AYARLAR', 'en': 'SETTINGS'},
  };
});

// 2.5 API Config State
// Web'de (Docker) göreceli /v1 → nginx proxy'si konteyner içi beyne yönlendirir.
// Native'de 127.0.0.1:8080 (yerel llama-server) veya Ayarlar'daki özel API adresi.
final _isWebApi = kIsWeb;
final apiUrlProvider = StateProvider<String>((ref) {
  if (_isWebApi) return '/v1';
  try {
    final saved = ref.watch(settingsProvider.select((s) => s.apiUrl));
    if (saved.trim().isNotEmpty) return saved.trim();
  } catch (_) {}
  return 'http://127.0.0.1:8080/v1';
});

/// Sesli (canlı) oturumda kullanılan HIZLI modelin API adresi.
final liveApiUrlProvider =
    StateProvider<String>((ref) => _isWebApi ? '/v1' : 'http://127.0.0.1:11434/v1');

/// Sesli oturumda STT websocket adresi (mevcut sabit provider'a taşındı).
final liveSttWsUrlProvider =
    StateProvider<String>((ref) => 'ws://127.0.0.1:5052/ws');

// ── Web (Docker) motor eşlemesi ─────────────────────────────────────────────
// Beyin konteyneri iki llama-server barındırır; nginx GUI'ye proxy açar:
//   Gemma 12B → /v1       (8081, hızlı)
//   Qwen  27B → /v1-qwen  (8082, güçlü)
const _webGemmaModel = '/models/gemma-4-12b-it-Q4_K_M.gguf';
const _webQwenModel =
    '/models/ThinkingCap-Qwen3.8-27B-abliterated-UD-Q4_K_XL.gguf';

/// Seçilen model etiketini gerçek GGUF model ID'sine çevirir.
/// Web'de "Gemma 12B (...)" → Gemma GGUF, "Qwen 27B (...)" → Qwen GGUF;
/// native'de (veya GGUF path/ada) olduğu gibi döner.
String modelForLabel(String label) {
  if (!_isWebApi) return label;
  if (label.contains('Qwen')) return _webQwenModel;
  return _webGemmaModel;
}

/// Seçilen model etiketine göre taban API URL'si.
/// Web'de "Qwen" → /v1-qwen, aksi → /v1. Native'de özel URL veya 127.0.0.1:8080/v1.
String baseUrlForModel(String label, {String? customApiUrl}) {
  if (!_isWebApi) {
    if (customApiUrl != null && customApiUrl.trim().isNotEmpty) {
      return customApiUrl.trim();
    }
    return 'http://127.0.0.1:8080/v1';
  }
  return label.contains('Qwen') ? '/v1-qwen' : '/v1';
}

/// Yardımcı: mmproj, vocab, imatrix veya mtp draft dosyalarını ana model listesinden ayıklar
bool isAuxiliaryGgufFile(String fileName) {
  final lower = fileName.toLowerCase();
  return lower.contains('mmproj') ||
      lower.contains('vocab') ||
      lower.contains('imatrix') ||
      lower.startsWith('mtp-') ||
      lower.contains('/mtp-');
}

// 2.6 Autonomous Mode State
final autonomousModeProvider = StateProvider<bool>((ref) => false);
// 2.8 Plan Mode State
final planModeProvider = StateProvider<bool>((ref) => false);

// 2.9 Permission Mode (Ask / AutoEdit / FullAuto)
enum PermissionMode { ask, autoEdit, fullAuto }
final permissionModeProvider = StateProvider<PermissionMode>((ref) => PermissionMode.autoEdit);

// 2.10 Live Todos State
final activeTodosProvider = StateProvider<List<TodoItem>>((ref) => []);


// 2.7 Agent Running State
final agentIsRunningProvider = StateProvider<bool>((ref) => false);

// 3. Thinking Level State
enum ThinkingLevel { low, med, high, xHigh, max }

final thinkingLevelProvider =
    StateProvider<ThinkingLevel>((ref) => ThinkingLevel.med);

// 4. Hardware Monitor State
class MemoryInfo {
  final String label;
  final String details;
  final bool isUnified;
  MemoryInfo(this.label, this.details, this.isUnified);
}

MemoryInfo _detectLocalMemoryInfo() {
  if (_isWebApi) {
    return MemoryInfo('Bulut / Konteyner', 'Yerel Sunucu', false);
  }
  String ramLabel = 'Sistem Belleği';
  String gpuLabel = Platform.isMacOS ? 'Apple Silicon / Metal' : 'Yerel GPU / CPU';
  bool unified = Platform.isMacOS;
  try {
    if (Platform.isLinux) {
      final memFile = File('/proc/meminfo');
      if (memFile.existsSync()) {
        final line = memFile
            .readAsLinesSync()
            .firstWhere((l) => l.startsWith('MemTotal:'), orElse: () => '');
        final match = RegExp(r'(\d+)').firstMatch(line);
        if (match != null) {
          final kb = int.tryParse(match.group(1)!) ?? 0;
          if (kb > 0) {
            final gbRaw = kb / (1024 * 1024);
            final roundedGb = ((gbRaw + 2) ~/ 4) * 4;
            ramLabel = '${roundedGb > 0 ? roundedGb : gbRaw.round()} GB RAM';
          }
        }
      }
      final drmDir = Directory('/sys/class/drm');
      if (drmDir.existsSync()) {
        for (final ent in drmDir.listSync()) {
          final name = p.basename(ent.path);
          if (!RegExp(r'^card\d+$').hasMatch(name)) continue;
          final uevent = File(p.join(ent.path, 'device', 'uevent'));
          if (uevent.existsSync()) {
            final txt = uevent.readAsStringSync();
            if (txt.contains('PCI_ID=1002:1586')) {
              gpuLabel = 'AMD Radeon 8060S';
              unified = true;
              ramLabel = ramLabel.replaceFirst(' RAM', ' Unified');
              break;
            } else if (txt.contains('DRIVER=amdgpu')) {
              gpuLabel = 'AMD Radeon GPU';
              break;
            } else if (txt.contains('DRIVER=nvidia')) {
              gpuLabel = 'NVIDIA GPU';
              break;
            } else if (txt.contains('DRIVER=i915') || txt.contains('DRIVER=xe')) {
              gpuLabel = 'Intel Arc / iGPU';
              break;
            }
          }
        }
      }
    } else if (Platform.isMacOS && !Platform.environment.containsKey('FLUTTER_TEST')) {
      final memRes = Process.runSync('sysctl', ['-n', 'hw.memsize']);
      if (memRes.exitCode == 0) {
        final bytes = int.tryParse(memRes.stdout.toString().trim()) ?? 0;
        if (bytes > 0) {
          final gb = (bytes / (1024 * 1024 * 1024)).round();
          ramLabel = '$gb GB Unified';
        }
      }
      final cpuRes = Process.runSync('sysctl', ['-n', 'machdep.cpu.brand_string']);
      if (cpuRes.exitCode == 0 && cpuRes.stdout.toString().trim().isNotEmpty) {
        gpuLabel = cpuRes.stdout.toString().trim();
      }
    } else if (Platform.isWindows && !Platform.environment.containsKey('FLUTTER_TEST')) {
      final psRes = Process.runSync('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        r'[math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)',
      ]);
      if (psRes.exitCode == 0) {
        final gb = int.tryParse(psRes.stdout.toString().trim()) ?? 0;
        if (gb > 0) ramLabel = '$gb GB RAM';
      }
      gpuLabel = 'Windows GPU / Vulkan';
    }
  } catch (_) {}
  return MemoryInfo(ramLabel, gpuLabel, unified);
}

final memoryInfoProvider = StateProvider<MemoryInfo>((ref) {
  return _detectLocalMemoryInfo();
});
final thinkingModeProvider = StateProvider<bool>((ref) => false);

// 4. Model State (Dynamic Scanning)
List<String> getModelScanDirs() {
  if (_isWebApi) return const [];
  return AppPaths.modelScanDirs;
}

/// Bir GGUF dosya adının bölünmüş (split) olup olmadığını ve kaç parçadan
/// oluştuğunu ayıklar. Tek parça GGUF'lar null döner.
/// Örnek: "qwen2.5-7b-instruct-q4_k_m-00001-of-00002.gguf"
///   -> { part: 1, total: 2, base: "qwen2.5-7b-instruct-q4_k_m" }
Map<String, dynamic>? _splitGgufInfo(String name) {
  final m = RegExp(r'-(\d{4,})-of-(\d{4,})\.gguf$').firstMatch(name);
  if (m == null) return null;
  final part = int.tryParse(m.group(1) ?? '') ?? 1;
  final total = int.tryParse(m.group(2) ?? '') ?? 1;
  if (total < 1) return null;
  return {'part': part, 'total': total, 'base': name.substring(0, m.start)};
}

/// Bir modelin (tek parça GGUF veya bölünmüş GGUF setinin 1. parçası)
/// indirmenin tamamlanıp tamamlanmadığını kontrol eder.
bool _isModelComplete(FileSystemEntity entity, String name) {
  final info = _splitGgufInfo(name);
  if (info == null) return true; // Tek parça -> tamam
  if (info['part'] != 1) return false; // 1. parça değil -> setin temsilcisi değil
  final total = info['total'] as int;
  final base = info['base'] as String;
  final parentDir = entity.parent;
  for (int i = 2; i <= total; i++) {
    final pStr = i.toString().padLeft(5, '0');
    final tStr = total.toString().padLeft(5, '0');
    final nextPart = '$base-$pStr-of-$tStr.gguf';
    if (!File(p.join(parentDir.path, nextPart)).existsSync()) {
      return false;
    }
  }
  return true;
}

/// Bölünmüş bir GGUF'ın set adını (parça ekleri olmadan) döndürür.
/// "qwen2.5-7b-instruct-q4_k_m-00001-of-00002.gguf" -> "qwen2.5-7b-instruct-q4_k_m"
/// Tek parça GGUF'lar aynen geri döner.
String _ggufDisplayName(String name) {
  final info = _splitGgufInfo(name);
  return info == null ? name : (info['base'] as String);
}

final availableModelsProvider = FutureProvider<List<String>>((ref) async {
  List<String> models = [];
  try {
    // Web'de (Docker) beyin konteyneri iki modeli barındırır:
    //   /v1      → Gemma 12B  (hızlı, varsayılan)
    //   /v1-qwen → Qwen 27B   (güçlü)
    // Yerel disk taraması web'de boş kalır → iki motoru da listele.
    if (_isWebApi) {
      models.add('Gemma 12B  (/v1  -  hızlı)');
      models.add('Qwen 27B  (/v1-qwen  -  güçlü)');
      return models;
    }
    final dirsToScan = getModelScanDirs();

    for (var dirPath in dirsToScan) {
      final dir = Directory(dirPath);
      if (await dir.exists()) {
        await for (var entity
            in dir.list(recursive: true).handleError((_) {})) {
          final name = p.basename(entity.path);
          final pathLower = name.toLowerCase();
          if ((entity is File || entity is Link) &&
              pathLower.endsWith('.gguf') &&
              !isAuxiliaryGgufFile(name)) {
            if (_isModelComplete(entity, name)) {
              // Bölünmüş GGUF setlerini tek model adı olarak normalize et
              // ki kullanıcı "qwen2.5-7b-instruct-q4_k_m" olarak görsün.
              models.add(_ggufDisplayName(name));
            }
          }
        }
      }
    }
  } catch (e) {
    // ignore
  }
  if (models.isEmpty) {
    models.add('Model İndirin (Ayarlar > Model Merkezi)');
  }
  return models.toSet().toList(); // Remove duplicates
});

class SelectedModelNotifier extends Notifier<String> {
  @override
  String build() {
    String? preferred;
    try {
      preferred = ref.watch(settingsProvider.select((s) => s.preferredModel));
    } catch (_) {}
    final initial = (preferred != null && preferred.isNotEmpty)
        ? preferred
        : (_isWebApi
            ? 'Gemma 12B  (/v1  -  hızlı)'
            : 'Model İndirin (Ayarlar > Model Merkezi)');
    if (!Platform.environment.containsKey('FLUTTER_TEST')) {
      if (_isWebApi) {
        Future.microtask(() => syncWithRunningServer('/v1'));
      } else {
        Future.microtask(() => syncWithRunningServer(ref.read(apiUrlProvider)));
      }
    }
    return initial;
  }

  void setModel(String modelName) {
    state = modelName;
    try {
      ref.read(settingsProvider.notifier).setPreferredModel(modelName);
    } catch (_) {}
  }

  Future<String?> fetchRunningServerModel([String? apiUrl]) async {
    final effectiveUrl = apiUrl ?? ref.read(apiUrlProvider);
    try {
      final res = await http.get(Uri.parse('$effectiveUrl/models')).timeout(const Duration(seconds: 2));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data is Map && data['data'] is List && (data['data'] as List).isNotEmpty) {
          final firstModel = data['data'][0];
          return firstModel['id']?.toString();
        }
      }
    } catch (_) {}
    return null;
  }

  Future<void> syncWithRunningServer([String? apiUrl]) async {
    final runningModel = await fetchRunningServerModel(apiUrl);
    if (runningModel != null && runningModel.isNotEmpty) {
      if (_isWebApi) {
        if (!state.contains('Gemma') && !state.contains('Qwen')) {
          state = 'Gemma 12B  (/v1  -  hızlı)';
          try { ref.read(settingsProvider.notifier).setPreferredModel(state); } catch (_) {}
        }
      } else {
        final fileName = p.basename(runningModel);
        if (state != fileName) {
          state = fileName;
          try { ref.read(settingsProvider.notifier).setPreferredModel(fileName); } catch (_) {}
        }
      }
      ref.read(isBackendRunningProvider.notifier).state = true;
    } else {
      // Sunucu şu an çalışmıyorsa ve seçili model "Model İndirin..." ise diskteki ilk GGUF'ı otomatik seç
      if (!_isWebApi && (state.startsWith('Model İndirin') || state.contains('Fallback'))) {
        try {
          for (final dirPath in getModelScanDirs()) {
            final d = Directory(dirPath);
            if (!d.existsSync()) continue;
            for (final ent in d.listSync(recursive: true)) {
              final name = p.basename(ent.path);
              if ((ent is File || ent is Link) &&
                  name.toLowerCase().endsWith('.gguf') &&
                  !isAuxiliaryGgufFile(name) &&
                  _isModelComplete(ent, name)) {
                final disp = _ggufDisplayName(name);
                state = disp;
                try { ref.read(settingsProvider.notifier).setPreferredModel(disp); } catch (_) {}
                break;
              }
            }
            if (!state.startsWith('Model İndirin')) break;
          }
        } catch (_) {}
      }
      ref.read(isBackendRunningProvider.notifier).state = false;
    }
  }

  Future<void> switchModel(String newModelName) async {
    if (newModelName.startsWith('Model İndirin')) return;
    if (state == newModelName && ref.read(isBackendRunningProvider)) return;

    state = newModelName;
    try { ref.read(settingsProvider.notifier).setPreferredModel(newModelName); } catch (_) {}

    if (_isWebApi) {
      ref.read(isBackendRunningProvider.notifier).state = true;
      return;
    }

    ref.read(isModelSwitchingProvider.notifier).state = true;
    try {
      final backendManager = ref.read(backendManagerProvider);
      await backendManager.stopBackend();
      await Future.delayed(const Duration(seconds: 1));
      await _startModelInternal(newModelName);
    } catch (e) {
      print('[SelectedModelNotifier] switchModel hatası: $e');
    } finally {
      ref.read(isModelSwitchingProvider.notifier).state = false;
    }
  }

  Future<void> startModel() async {
    if (_isWebApi) {
      final runningModel = await fetchRunningServerModel(baseUrlForModel(state));
      if (runningModel != null && runningModel.isNotEmpty) {
        ref.read(isBackendRunningProvider.notifier).state = true;
      }
      return;
    }

    final runningModel = await fetchRunningServerModel();
    if (runningModel != null && runningModel.isNotEmpty) {
      final fileName = p.basename(runningModel);
      state = fileName;
      ref.read(isBackendRunningProvider.notifier).state = true;
      try { ref.read(settingsProvider.notifier).setPreferredModel(fileName); } catch (_) {}
      return;
    }

    final targetModel = state;
    await _startModelInternal(targetModel);
  }

  Future<void> _startModelInternal(String modelName) async {
    final backendManager = ref.read(backendManagerProvider);
    final settings = ref.read(settingsProvider);

    if (settings.backendEngine == 'ollama') {
      await backendManager.startBackend(BackendConfig(
        type: BackendType.ollama,
        executablePath: 'ollama',
        modelPathOrName: modelName,
        port: 11434,
        contextSize: ref.read(maxContextSizeProvider),
        useGpu: settings.useGpuForLlm,
      ));
      await syncWithRunningServer('http://127.0.0.1:11434/v1');
      return;
    }

    if (settings.backendEngine == 'vllm') {
      await backendManager.startBackend(BackendConfig(
        type: BackendType.vllm,
        executablePath: 'vllm',
        modelPathOrName: modelName,
        port: 8000,
        contextSize: ref.read(maxContextSizeProvider),
        useGpu: settings.useGpuForLlm,
      ));
      await syncWithRunningServer('http://127.0.0.1:8000/v1');
      return;
    }

    final dirsToScan = getModelScanDirs();
    String? absoluteModelPath;
    try {
      for (var dirPath in dirsToScan) {
        if (absoluteModelPath != null) break;
        final dir = Directory(dirPath);
        if (await dir.exists()) {
          await for (var entity in dir.list(recursive: true).handleError((_) {})) {
            final name = p.basename(entity.path);
            if ((entity is File || entity is Link) && !isAuxiliaryGgufFile(name)) {
              bool match = name == modelName;
              if (!match && _splitGgufInfo(name) != null) {
                final info = _splitGgufInfo(name)!;
                if (info['base'] == modelName && info['part'] == 1) {
                  match = true;
                }
              }
              if (match) {
                absoluteModelPath = entity.path;
                if (entity is Link) {
                  absoluteModelPath = await entity.resolveSymbolicLinks();
                }
                break;
              }
            }
          }
        }
      }
    } catch (_) {}

    if (absoluteModelPath == null) {
      // Otomatik model keşfi: İlk bulunan gerçek GGUF modelini bağla
      try {
        for (var dirPath in dirsToScan) {
          if (absoluteModelPath != null) break;
          final dir = Directory(dirPath);
          if (await dir.exists()) {
            await for (var entity in dir.list(recursive: true).handleError((_) {})) {
              final name = p.basename(entity.path);
              final pathLower = name.toLowerCase();
              if ((entity is File || entity is Link) &&
                  pathLower.endsWith('.gguf') &&
                  !isAuxiliaryGgufFile(name)) {
                if (!_isModelComplete(entity, name)) continue;
                absoluteModelPath = entity.path;
                if (entity is Link) {
                  absoluteModelPath = await entity.resolveSymbolicLinks();
                }
                final disp = _ggufDisplayName(name);
                state = disp;
                try { ref.read(settingsProvider.notifier).setPreferredModel(disp); } catch (_) {}
                break;
              }
            }
          }
        }
      } catch (_) {}
    }

    if (absoluteModelPath == null) {
      ref.read(lastBackendStatusMessageProvider.notifier).state =
          'Henüz indirilmiş yerel GGUF modeli bulunamadı. Lütfen Ayarlar > Model Merkezi sekmesinden bir model indirin.';
      return;
    }

    // llama-server yolunu çöz; eksikse otonom olarak indirip kur!
    String? llamaExe = AppPaths.resolveLlamaServer(customPath: settings.customLlamaServerPath);
    if (llamaExe == null) {
      ref.read(lastBackendStatusMessageProvider.notifier).state =
          'llama-server bulunamadı; otonom kurulum başlatılıyor...';
      final installed = await ref
          .read(systemInstallerProvider.notifier)
          .installOrUpdateLlamaCpp(flavor: 'vulkan');
      if (installed) {
        llamaExe = AppPaths.resolveLlamaServer(customPath: settings.customLlamaServerPath);
      }
    }

    await backendManager.startBackend(BackendConfig(
      type: BackendType.llamaCpp,
      executablePath: llamaExe ?? p.join(AppPaths.appRoot, 'bin', 'llama-cpp', AppPaths.exeName('llama-server')),
      modelPathOrName: absoluteModelPath,
      contextSize: ref.read(maxContextSizeProvider),
      useGpu: settings.useGpuForLlm,
    ));
    await syncWithRunningServer();
  }

  Future<void> toggleModel() async {
    final backendManager = ref.read(backendManagerProvider);
    final isRunning = ref.read(isBackendRunningProvider);

    if (isRunning) {
      await backendManager.stopBackend();
      return;
    }
    await startModel();
  }

  Future<void> restartWithNewContext(int newContextSize) async {
    final backendManager = ref.read(backendManagerProvider);
    await backendManager.stopBackend();
    await Future.delayed(const Duration(seconds: 1));
    await startModel();
  }

  Future<void> deleteModel(String modelName) async {
    final dirsToScan = getModelScanDirs();
    for (var dirPath in dirsToScan) {
      final dir = Directory(dirPath);
      if (await dir.exists()) {
        await for (var entity in dir.list(recursive: true).handleError((_) {})) {
          final name = p.basename(entity.path);
          bool match = name == modelName;
          // Bölünmüş GGUF set adı: setin tüm parçalarını sil
          if (!match && _splitGgufInfo(name) != null) {
            final info = _splitGgufInfo(name)!;
            if (info['base'] == modelName) match = true;
          }
          if ((entity is File || entity is Link) && match) {
            try {
              if (entity is Link) {
                try {
                  final target = await entity.resolveSymbolicLinks();
                  final targetFile = File(target);
                  if (await targetFile.exists()) {
                    await targetFile.delete();
                  }
                } catch (_) {}
              }
              await entity.delete();
            } catch (_) {}
          }
        }
      }
    }
    ref.invalidate(availableModelsProvider);
  }
}

final maxContextSizeProvider = StateProvider<int>((ref) => 131072);

final chatSearchQueryProvider = StateProvider<String>((ref) => '');

final isBackendRunningProvider = StateProvider<bool>((ref) => false);
final isModelSwitchingProvider = StateProvider<bool>((ref) => false);

final selectedModelProvider = NotifierProvider<SelectedModelNotifier, String>(
    () => SelectedModelNotifier());

// 5. Sidebar State
final isSidebarOpenProvider = StateProvider<bool>((ref) => true);

// 6. Recording State
enum RecordingPhase { idle, recording }

class RecordingData {
  final RecordingPhase phase;
  final int seconds;
  const RecordingData(this.phase, this.seconds);
  bool get isRecording => phase == RecordingPhase.recording;
}

class RecordingController extends Notifier<RecordingData> {
  @override
  RecordingData build() => const RecordingData(RecordingPhase.idle, 0);

  void start() => state = const RecordingData(RecordingPhase.recording, 0);
  void stop() => state = const RecordingData(RecordingPhase.idle, 0);
}

final recordingProvider = NotifierProvider<RecordingController, RecordingData>(
    () => RecordingController());

// 7. Context Usage State
final contextUsageProvider = StateProvider<double>((ref) => 0.0);
final tokenCountProvider = StateProvider<int>((ref) => 0);

// 8. Chat Session State
final chatRepositoryProvider = Provider<ChatRepository>((ref) {
  final chatHistoryPath =
      ref.watch(settingsProvider.select((s) => s.chatHistoryPath));
  return ChatRepository(chatHistoryPath);
});

final foldersProvider = FutureProvider<List<ChatFolder>>((ref) async {
  final repo = ref.read(chatRepositoryProvider);
  return repo.loadAllFolders();
});

class FolderNotifier extends Notifier<void> {
  @override
  void build() {}

  Future<void> createFolder(String name) async {
    final repo = ref.read(chatRepositoryProvider);
    final folders = await repo.loadAllFolders();
    folders.add(ChatFolder(name: name));
    await repo.saveFolders(folders);
    ref.invalidate(foldersProvider);
  }

  Future<void> deleteFolder(String folderId) async {
    final repo = ref.read(chatRepositoryProvider);
    final folders = await repo.loadAllFolders();
    folders.removeWhere((f) => f.id == folderId);
    await repo.saveFolders(folders);

    // Ana dizine düşür (folderId = null yap)
    final sessions = await repo.loadAllSessions();
    for (var s in sessions.where((s) => s.folderId == folderId)) {
      final full = await repo.loadSession(s.id);
      if (full != null) {
        full.folderId = null;
        await repo.saveSession(full);
      }
    }

    ref.invalidate(foldersProvider);
    ref.invalidate(chatHistoryProvider);
  }
}

final folderNotifierProvider =
    NotifierProvider<FolderNotifier, void>(() => FolderNotifier());

final chatHistoryProvider = FutureProvider<List<ChatSession>>((ref) async {
  final repo = ref.read(chatRepositoryProvider);
  return repo.loadAllSessions();
});

class ActiveSessionNotifier extends Notifier<ChatSession?> {
  Timer? _saveDebounceTimer;

  @override
  ChatSession? build() => null;

  void _debouncedSave() {
    _saveDebounceTimer?.cancel();
    _saveDebounceTimer = Timer(const Duration(milliseconds: 1500), () async {
      if (state != null) {
        final repo = ref.read(chatRepositoryProvider);
        await repo.saveSession(state!);
      }
    });
  }

  void setSession(ChatSession? session) {
    _saveDebounceTimer?.cancel();
    state = session;
    if (session == null) {
      ref.read(tokenCountProvider.notifier).state = 0;
      ref.read(contextUsageProvider.notifier).state = 0.0;
    } else {
      final tokens = session.calculatedTokens;
      ref.read(tokenCountProvider.notifier).state = tokens;
      ref.read(contextUsageProvider.notifier).state =
          (tokens / ref.read(maxContextSizeProvider).toDouble())
              .clamp(0.0, 1.0);

      // Tembel yükleme: Eğer index stub'ı ise (preview ile yüklendiyse), arka planda tam oturumu çek
      if (session.messages.isEmpty ||
          (session.messages.length == 1 &&
              session.messages.first.id == 'preview')) {
        final repo = ref.read(chatRepositoryProvider);
        repo.loadSession(session.id).then((fullSession) {
          if (fullSession != null && state?.id == session.id) {
            state = fullSession;
            final fullTokens = fullSession.calculatedTokens;
            ref.read(tokenCountProvider.notifier).state = fullTokens;
            ref.read(contextUsageProvider.notifier).state =
                (fullTokens / ref.read(maxContextSizeProvider).toDouble())
                    .clamp(0.0, 1.0);
          }
        });
      }
    }
  }

  Future<void> addEvent(AgentEvent event) async {
    _saveDebounceTimer?.cancel();
    // Determine a title for new sessions
    String? newTitle;
    if (state == null) {
      newTitle = 'Yeni Sohbet';
      if (event is AgentStarted) {
        newTitle = event.goal;
      } else if (event is AgentMessage) {
        newTitle = event.message.length > 20
            ? '${event.message.substring(0, 20)}...'
            : event.message;
      }
      state = ChatSession(title: newTitle);
    } else if (state!.messages.isEmpty && event is AgentStarted) {
      // If session exists but is empty (created via New Chat button)
      state!.title = event.goal;
      newTitle = event.goal;
    }

    final message = ChatMessage(
      id: const Uuid().v4(),
      event: event,
      timestamp: DateTime.now(),
    );

    // Riverpod UI'ı tetiklemek için state'i kopyalayarak güncellemeliyiz
    state = state!.copyWith(
      updatedAt: DateTime.now(),
      messages: List.from(state!.messages)..add(message),
    );

    final tokens = state!.calculatedTokens;
    ref.read(tokenCountProvider.notifier).state = tokens;
    ref.read(contextUsageProvider.notifier).state =
        (tokens / ref.read(maxContextSizeProvider).toDouble()).clamp(0.0, 1.0);

    // Save to disk
    final repo = ref.read(chatRepositoryProvider);
    await repo.saveSession(state!);

    // Re-trigger history load to update sidebar if title changed or new session
    if (newTitle != null) {
      ref.invalidate(chatHistoryProvider);
    }
  }

  Future<void> updateEventAt(int index, AgentEvent newEvent) async {
    if (state == null || index < 0 || index >= state!.messages.length) return;

    final messages = List<ChatMessage>.from(state!.messages);
    final targetMsg = messages[index];

    messages[index] = ChatMessage(
      id: targetMsg.id,
      event: newEvent,
      timestamp: targetMsg.timestamp,
    );

    state = state!.copyWith(
      updatedAt: DateTime.now(),
      messages: messages,
    );

    // Streaming bittiğinde veya hata/araç tamamlandığında HEMEN diske yaz:
    final bool isStreamFinished =
        (newEvent is AgentMessage && newEvent.inputTokens != null) ||
            newEvent is AgentFailed ||
            newEvent is ToolCompleted ||
            newEvent is AgentCompleted;

    if (isStreamFinished) {
      _saveDebounceTimer?.cancel();
      final tokens = state!.calculatedTokens;
      ref.read(tokenCountProvider.notifier).state = tokens;
      ref.read(contextUsageProvider.notifier).state =
          (tokens / ref.read(maxContextSizeProvider).toDouble())
              .clamp(0.0, 1.0);

      final repo = ref.read(chatRepositoryProvider);
      await repo.saveSession(state!);
    } else {
      // Streaming sırasında her karakterde diske 30MB JSON yazmak yerine debounced kaydet!
      _debouncedSave();
    }
  }

  Future<void> updateLastEvent(AgentEvent newEvent) async {
    if (state == null || state!.messages.isEmpty) return;
    await updateEventAt(state!.messages.length - 1, newEvent);
  }

  Future<void> deleteSession(String sessionId) async {
    final repo = ref.read(chatRepositoryProvider);
    await repo.deleteSession(sessionId);
    if (state?.id == sessionId) {
      state = null;
      ref.read(tokenCountProvider.notifier).state = 0;
      ref.read(contextUsageProvider.notifier).state = 0.0;
    }
    ref.invalidate(chatHistoryProvider);
  }

  Future<void> updateSessionFolder(String sessionId, String? folderId) async {
    final repo = ref.read(chatRepositoryProvider);
    final session = await repo.loadSession(sessionId);
    if (session != null) {
      session.folderId = folderId;
      await repo.saveSession(session);
      ref.invalidate(chatHistoryProvider);
      if (state?.id == sessionId) {
        state = session;
      }
    }
  }

  /// Phase 1.3: Olayları UI dinleyicisinden bağımsız olarak kaydeder.
  /// Oturum değiştirildiğinde arka plandaki koşunun sonuçlarının kaybolmasını engeller.
  Future<void> handleEngineEvent(
      String targetSessionId, AgentEvent event) async {
    if (event is TodoUpdated) {
      ref.read(activeTodosProvider.notifier).state = event.todos;
    }
    if (state?.id == targetSessionId) {
      if (state!.messages.isNotEmpty) {
        final lastEvent = state!.messages.last.event;
        if ((event is AgentMessage && lastEvent is AgentMessage) ||
            (event is ReasoningMessage && lastEvent is ReasoningMessage) ||
            (event is StepStarted && lastEvent is StepStarted)) {
          await updateLastEvent(event);
          return;
        }

        // Mevcut adım içinde zaten bu tipte bir mesaj varsa (örn. Reasoning veya AgentMessage),
        // yeni bir mükerrer baloncuğu eklemek yerine mevcut mesajı yerinde güncelle!
        if (event is ReasoningMessage || event is AgentMessage) {
          int existingIndex = -1;
          for (int i = state!.messages.length - 1; i >= 0; i--) {
            final e = state!.messages[i].event;
            if (e is StepStarted || e is AgentStarted) break;
            if ((event is ReasoningMessage && e is ReasoningMessage) ||
                (event is AgentMessage && e is AgentMessage)) {
              existingIndex = i;
              break;
            }
          }
          if (existingIndex != -1) {
            await updateEventAt(existingIndex, event);
            return;
          }
        }
      }
      addEvent(event);
    } else {
      final repo = ref.read(chatRepositoryProvider);
      final bgSession = await repo.loadSession(targetSessionId);
      if (bgSession != null) {
        if (bgSession.messages.isNotEmpty) {
          final lastEvent = bgSession.messages.last.event;
          if ((event is AgentMessage && lastEvent is AgentMessage) ||
              (event is ReasoningMessage && lastEvent is ReasoningMessage) ||
              (event is StepStarted && lastEvent is StepStarted)) {
            bgSession.messages.last = ChatMessage(
              id: bgSession.messages.last.id,
              event: event,
              timestamp: DateTime.now(),
            );
            await repo.saveSession(bgSession);
            return;
          }

          if (event is ReasoningMessage || event is AgentMessage) {
            int existingIndex = -1;
            for (int i = bgSession.messages.length - 1; i >= 0; i--) {
              final e = bgSession.messages[i].event;
              if (e is StepStarted || e is AgentStarted) break;
              if ((event is ReasoningMessage && e is ReasoningMessage) ||
                  (event is AgentMessage && e is AgentMessage)) {
                existingIndex = i;
                break;
              }
            }
            if (existingIndex != -1) {
              bgSession.messages[existingIndex] = ChatMessage(
                id: bgSession.messages[existingIndex].id,
                event: event,
                timestamp: DateTime.now(),
              );
              await repo.saveSession(bgSession);
              return;
            }
          }
        }
        bgSession.messages.add(ChatMessage(
          id: const Uuid().v4(),
          event: event,
          timestamp: DateTime.now(),
        ));
        await repo.saveSession(bgSession);
      }
    }
  }

  Future<void> undoLastInteraction() async {
    if (state == null || state!.messages.isEmpty) return;

    // Geri alırken ajan hala çalışıyorsa durdur
    ref.read(agentEngineProvider(state!.id)).cancel();

    final messages = List<ChatMessage>.from(state!.messages);
    int lastUserMessageIndex = -1;
    for (int i = messages.length - 1; i >= 0; i--) {
      if (messages[i].event is AgentStarted) {
        lastUserMessageIndex = i;
        break;
      }
    }

    if (lastUserMessageIndex != -1) {
      messages.removeRange(lastUserMessageIndex, messages.length);
      state = state!.copyWith(
        updatedAt: DateTime.now(),
        messages: messages,
      );

      final tokens = state!.calculatedTokens;
      ref.read(tokenCountProvider.notifier).state = tokens;
      ref.read(contextUsageProvider.notifier).state =
          (tokens / ref.read(maxContextSizeProvider).toDouble())
              .clamp(0.0, 1.0);

      final repo = ref.read(chatRepositoryProvider);
      await repo.saveSession(state!);
    }
  }
}

final activeSessionProvider =
    NotifierProvider<ActiveSessionNotifier, ChatSession?>(
        () => ActiveSessionNotifier());

final agentEventsProvider =
    StreamProvider.family<AgentEvent, String?>((ref, sessionId) {
  return ref.watch(agentEngineProvider(sessionId)).events;
});
