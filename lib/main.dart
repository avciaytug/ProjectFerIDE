import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'features/chat/ide_shell.dart';
import 'features/chat/state.dart'; // added to access themeModeProvider
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as p;
import 'features/settings/settings_provider.dart';
import 'services/app_paths.dart';
import 'services/process_manager.dart';
import 'services/pty_sandbox.dart';
import 'services/mcp_service.dart';
import 'agent/permissions.dart';
import 'features/chat/approval_listener.dart';
import 'features/live/wake_word.dart';
import 'package:window_manager/window_manager.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Web (Docker) build'inde window_manager native MethodChannel'e sahip değildir;
  // ensureInitialized() MissingPluginException fırlatıp bembeyaz sayfa yapar.
  if (!kIsWeb) {
    await windowManager.ensureInitialized();
  }

  // ============================================================================
  // KÜRESEL HATA AĞI (v5.3.7): Bir build/runtime hatası tüm paneli kırmızı
  // "tema" ekranına boğmasın — FerIDE tarzında okunabilir bir hata kartı
  // göstersin + hata ~/.feride/logs/feride_errors.log dosyasına yazılsın.
  // ============================================================================
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    _logFerideError('FlutterError', details.exceptionAsString(), details.stack?.toString() ?? '');
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    _logFerideError('PlatformError', error.toString(), stack.toString());
    return true; // uygulamayı öldürme, hata kartıyla devam et
  };
  ErrorWidget.builder = (FlutterErrorDetails details) => _FerideErrorCard(
        error: details.exceptionAsString(),
        stack: details.stack?.toString() ?? '',
      );

  const WindowOptions windowOptions = WindowOptions(
    size: Size(1420, 880),
    minimumSize: Size(980, 640),
    center: true,
    title: 'FerIDE Beta v5.3.7',
  );
  if (!kIsWeb) {
    windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
      await windowManager.setPreventClose(true);
    });
  }

  final prefs = await SharedPreferences.getInstance();

  // Ses (STT/TTS/VAD) motorlarını açılışta arka planda ısıt; kullanıcı mikrofona
  // bastığında sıfır bekleme ile anında yazıya çevirsin.
  final processManager = ProcessManager.instance;
  if (!kIsWeb && !Platform.environment.containsKey('FLUTTER_TEST')) {
    ProcessSignal.sigint.watch().listen((_) => _cleanupAndExit(processManager));
    if (!Platform.isWindows) {
      ProcessSignal.sigterm.watch().listen((_) => _cleanupAndExit(processManager));
    }
  }

  runApp(ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
    ],
    child: const FerIDEApp(),
  ));
}

/// Bir hata oluştuğunda ~/.feride/logs/feride_errors.log dosyasına yazar (çapraz platform).
void _logFerideError(String kind, String message, String stack) {
  try {
    final logDir = Directory(p.join(AppPaths.ferideDataDir, 'logs'));
    if (!logDir.existsSync()) logDir.createSync(recursive: true);
    final file = File(p.join(logDir.path, 'feride_errors.log'));
    final entry =
        '--- ${DateTime.now().toIso8601String()} [$kind] ---\n$message\n$stack\n\n';
    file.writeAsStringSync(entry, mode: FileMode.append, flush: true);
  } catch (_) {}
}

Future<void> _cleanupAndExit(ProcessManager pm) async {
  try {
    ApprovalBroker.instance.rejectAll();
    await McpService.instance.shutdownAll().timeout(const Duration(seconds: 3));
  } catch (_) {}
  try {
    await PtySandbox.killAllActiveProcesses();
  } catch (_) {}
  try {
    pm.killAll();
  } catch (_) {}
  exit(0);
}

class FerIDEApp extends ConsumerStatefulWidget {
  const FerIDEApp({super.key});

  @override
  ConsumerState<FerIDEApp> createState() => _FerIDEAppState();
}

class _FerIDEAppState extends ConsumerState<FerIDEApp> with WindowListener {
  @override
  void initState() {
    super.initState();
    if (!kIsWeb) windowManager.addListener(this);
  }

  @override
  void dispose() {
    if (!kIsWeb) windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowClose() async {
    _cleanupAndExit(ProcessManager.instance);
  }

  @override
  Widget build(BuildContext context) {
    final themeMode = ref.watch(themeModeProvider);

    return MaterialApp(
      navigatorKey: rootNavigatorKey,
      title: 'FerIDE Beta v5.3.7',
      debugShowCheckedModeBanner: false,
      themeMode: themeMode,
      // v5.3.1: Build/runtime çöküşlerinde kırmızı "tema" ekranı yerine
      // okunabilir bir FerIDE hata kartı göster. (3.47 uyumu: MaterialApp'ta
      // errorWidget parametresi kalmadığından global ErrorWidget.builder,
      // main() içinde tanımlı; detay logda da saklanır.)
      builder: (context, child) {
        final data = MediaQuery.of(context);
        return MediaQuery(
          data: data.copyWith(
            textScaler: const TextScaler.linear(1.05),
          ),
          child: child!,
        );
      },
      // Light Theme
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6366F1), // Modern Indigo/Purple
          brightness: Brightness.light,
          surface: const Color(0xFFF8FAFC),
        ),
        scaffoldBackgroundColor: const Color(0xFFF1F5F9),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFFFFFFF),
          elevation: 0,
        ),
      ),
      // Dark Theme
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF8B5CF6), // Purple accent for FerIDE
          brightness: Brightness.dark,
          surface: const Color(0xFF1E1E2E), // Dark background
        ),
        scaffoldBackgroundColor: const Color(0xFF181825),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF1E1E2E),
          elevation: 0,
        ),
      ),
      home: const ApprovalListener(child: IdeShell()),
    );
  }
}

/// v5.3.1 — FerIDE tarzı global hata kartı.
/// Bir widget build sırasında çökerse kırmızı "tema" ekranı yerine
/// bu kart gösterilir; hata mesajı ve stacktrace okunur, logda saklanır.
/// "Anladım" basılınca detay katlanır, log yolunu gösteren sade bir bara dönüşür.
class _FerideErrorCard extends StatefulWidget {
  final String error;
  final String stack;
  const _FerideErrorCard({required this.error, required this.stack});

  @override
  State<_FerideErrorCard> createState() => _FerideErrorCardState();
}

class _FerideErrorCardState extends State<_FerideErrorCard> {
  bool _acknowledged = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final logPath = p.join(AppPaths.ferideDataDir, 'logs', 'feride_errors.log');

    if (_acknowledged) {
      return Material(
        color: isDark ? const Color(0xFF181825) : const Color(0xFFF1F5F9),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1E1E2E) : Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey.shade400),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.warning_amber_rounded, size: 16, color: Colors.orange),
                  const SizedBox(width: 8),
                  Text(
                    'Hata kaydedildi: $logPath',
                    style: TextStyle(fontSize: 12, color: isDark ? Colors.white70 : Colors.black54),
                  ),
                  const SizedBox(width: 12),
                  TextButton(
                    onPressed: () => setState(() => _acknowledged = false),
                    child: const Text('Detay'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Material(
      color: isDark ? const Color(0xFF181825) : const Color(0xFFF1F5F9),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Container(
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1E1E2E) : Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isDark ? const Color(0xFF8B5CF6) : const Color(0xFF6366F1),
                  width: 1,
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.error_outline,
                          color: isDark ? const Color(0xFF8B5CF6) : const Color(0xFF6366F1),
                          size: 28,
                        ),
                        const SizedBox(width: 10),
                        Text(
                          'FerIDE Hata Kartı',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: isDark ? Colors.white : Colors.black87,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'Arayüzün bu bölümü bir hata nedeniyle çöktü. Hata detayı aşağıda ve logda saklanıyor.',
                      style: TextStyle(
                        fontSize: 13,
                        color: isDark ? Colors.white70 : Colors.black54,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: isDark ? const Color(0xFF11111B) : const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: SelectableText(
                        widget.error,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                          color: Colors.redAccent,
                        ),
                      ),
                    ),
                    if (widget.stack.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Container(
                        width: double.infinity,
                        constraints: const BoxConstraints(maxHeight: 140),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: isDark ? const Color(0xFF11111B) : const Color(0xFFF8FAFC),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: SingleChildScrollView(
                          child: SelectableText(
                            widget.stack.split('\n').take(8).join('\n'),
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 10,
                              color: isDark ? Colors.white54 : Colors.black45,
                            ),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 14),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => setState(() => _acknowledged = true),
                          child: const Text('Anladım'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}


