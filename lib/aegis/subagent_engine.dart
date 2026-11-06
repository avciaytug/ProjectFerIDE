import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';
import '../services/app_paths.dart';
import '../services/file_service.dart';
import '../services/pty_sandbox.dart';
import '../services/tool_registry.dart';

/// FerIDE Subagent motoru: ana ajanın context'ini şişirmeden,
/// izole bir bağlam penceresinde görevi tamamlar ve özet döner.
class SubagentEvent {
  final String type; // thinking | tool_invoked | tool_completed | done | failed
  final String message;
  const SubagentEvent(this.type, this.message);
}

class SubagentEngine {
  final String apiUrl;
  final String model;
  final int maxSteps;
  final Dio _dio;

  SubagentEngine({
    required this.apiUrl,
    required this.model,
    this.maxSteps = 50,
    Dio? dio,
  }) : _dio = dio ?? Dio() {
    _dio.options.connectTimeout = const Duration(seconds: 15);
    _dio.options.receiveTimeout = const Duration(minutes: 10);
  }

  /// [onEvent] ile ilerlemeyi canlı yayınlar. Dönen değer: görevin final özeti.
  Future<String> run(
    String goal, {
    required void Function(SubagentEvent e) onEvent,
  }) async {
    final payload = <Map<String, dynamic>>[
      {
        'role': 'system',
        'content':
            'Sen FerIDE\'in bir SUBAGENT\'ısın. Tek odak: sana verilen görevi '
                'efektif araç çağrılarıyla tamamlamak. Türkçe düşün. '
                'Komut çalıştırmak için run_command aracını kullan. '
                'Görev bittiğinde KISA ve net bir sonuç özeti ver (en fazla 5-8 satır).',
      },
      {'role': 'user', 'content': goal},
    ];

    for (var step = 0; step < maxSteps; step++) {
      onEvent(SubagentEvent(
          'thinking', 'Subagent düşünüyor (adım ${step + 1})...'));
      final resp = await _dio.post(
        '$apiUrl/chat/completions',
        options: Options(
          headers: {'Content-Type': 'application/json'},
          validateStatus: (s) => true,
        ),
        data: {
          'model': model,
          'messages': payload,
          'max_tokens': 4096,
          'temperature': 0.3,
          'stream': false,
          'tools': [
            ToolRegistry.runCommandTool,
            ToolRegistry.readDocumentTool,
            ToolRegistry.editMediaOrDocumentTool,
            ToolRegistry.checkMarketTool,
            ToolRegistry.searchWebTool,
            ToolRegistry.readUrlContentTool,
          ],
        },
      );

      if (resp.statusCode != 200) {
        onEvent(SubagentEvent('failed', 'API hatası [${resp.statusCode}]'));
        return 'HATA: Subagent sunucuya ulaşamadı ([${resp.statusCode}]).';
      }

      final data = resp.data;
      final choices = data?['choices'];
      if (choices == null || choices.isEmpty) {
        onEvent(SubagentEvent('failed', 'Geçersiz yanıt formatı'));
        return 'HATA: Model boş yanıt verdi.';
      }

      final msg = choices[0]['message'];
      final reply = (msg['content'] ?? '') as String;
      final toolCalls = msg['tool_calls'];

      if (toolCalls != null && (toolCalls as List).isNotEmpty) {
        payload.add(
            {'role': 'assistant', 'content': reply, 'tool_calls': toolCalls});
        for (final tc in toolCalls) {
          final fn = tc['function'];
          final name = fn['name'] as String;
          final callId = (tc['id'] ??
              'call_${const Uuid().v4()}') as String;
          Map<String, dynamic> args = {};
          try {
            args =
                jsonDecode(fn['arguments'] as String) as Map<String, dynamic>;
          } catch (_) {}

          if (name == 'run_command') {
            final cmd = (args['command'] ?? '') as String;
            final bool explicitBg = args['background'] == true;
            onEvent(SubagentEvent('tool_invoked', '\$ $cmd'));
            var out = '';
            final lowerCmd = cmd.trim().toLowerCase();
            final isGui = explicitBg ||
                RegExp(r'\b(brave|brave-browser|firefox|chrome|google-chrome|chromium|code|dolphin|nautilus|thunar|vlc|gimp|xdg-open|gedit|kate|kwrite|evince|okular|obs|blender|feride_v5_2)\b')
                    .hasMatch(lowerCmd);

            if (isGui) {
              try {
                final (shExe, shArgs) = Platform.isWindows
                    ? ('powershell', ['-NoProfile', '-Command', 'Start-Process $cmd'])
                    : ('bash', ['-c', 'setsid nohup $cmd >/dev/null 2>&1 &']);
                await Process.start(
                  shExe,
                  shArgs,
                  mode: ProcessStartMode.detached,
                );
                out = 'Uygulama/komut arka planda başarıyla başlatıldı (ayrık süreç).';
              } catch (e) {
                out = 'Arka plan süreci başlatılamadı: $e';
              }
            } else {
              try {
                final isRea = lowerCmd.startsWith('rea ') || lowerCmd.contains(' rea ');
                final timeoutSec = isRea ? 300 : 120;
                final (shExe, shArgs) = AppPaths.shellCommand(cmd);
                final res = await PtySandbox.runCommand(
                  shExe,
                  shArgs,
                  timeout: Duration(seconds: timeoutSec),
                );
                if (res.timedOut) {
                  out = 'Komut $timeoutSec sn zaman aşımına uğradı ve sonlandırıldı.\nSTDOUT:\n${res.stdout}\nSTDERR:\n${res.stderr}';
                } else {
                  out = 'STDOUT:\n${res.stdout}\nSTDERR:\n${res.stderr}'.trim();
                }
              } catch (e) {
                out = 'Komut çalıştırılamadı: $e';
              }
            }
            if (out.length > 20000) {
              out = out.substring(0, 20000) + '\n...[KESİLDİ]';
            }
            if (out.trim().isEmpty)
              out = 'Komut başarıyla çalıştı (çıktı yok).';
            onEvent(SubagentEvent('tool_completed',
                out.length > 500 ? '${out.substring(0, 500)}...' : out));
            payload.add({
              'role': 'tool',
              'tool_call_id': callId,
              'name': name,
              'content': out,
            });
          } else if (name == 'read_document') {
            final docPath = (args['path'] ?? '').toString();
            onEvent(SubagentEvent('tool_invoked', 'Belge Okunuyor: $docPath'));
            var out = await FileService.extractContent(docPath);
            if (out.length > 14000) out = '${out.substring(0, 14000)}\n...[Kesildi]';
            onEvent(SubagentEvent('tool_completed', out.length > 200 ? '${out.substring(0, 200)}...' : out));
            payload.add({
              'role': 'tool',
              'tool_call_id': callId,
              'name': name,
              'content': out,
            });
          } else if (name == 'edit_media_or_document') {
            onEvent(SubagentEvent('tool_invoked', 'Belge/Medya İşleniyor: ${args['output_path']}'));
            final out = await FileService.runFileStudio(args);
            onEvent(SubagentEvent('tool_completed', out));
            payload.add({
              'role': 'tool',
              'tool_call_id': callId,
              'name': name,
              'content': out,
            });
          } else if (name == 'check_market') {
            final asset = (args['asset_type'] ?? 'crypto') as String;
            final sym = (args['symbol'] ?? 'BTC') as String;
            onEvent(SubagentEvent(
                'tool_invoked', 'Finans Verisi Çekiliyor: $sym ($asset)'));
            var out = '';
            try {
              final script = AppPaths.scriptPath('finance_engine.py');
              final pr = await Process.run(
                AppPaths.resolvePython(),
                [script, asset, sym],
                environment: AppPaths.buildSubprocessEnv(),
              ).timeout(const Duration(seconds: 30));
              out = pr.stdout.toString().trim();
              if (out.isEmpty) out = pr.stderr.toString();
            } catch (e) {
              out = 'Finans motoru çalıştırılamadı: $e';
            }
            onEvent(SubagentEvent('tool_completed', out));
            payload.add({
              'role': 'tool',
              'tool_call_id': callId,
              'name': name,
              'content': out,
            });
          } else if (name == 'search_web') {
            final query = (args['query'] ?? '').toString();
            onEvent(SubagentEvent('tool_invoked', 'Araştırılıyor: $query'));
            var out = '';
            try {
              final script = AppPaths.scriptPath('search_engine.py');
              final pr = await Process.run(
                AppPaths.resolvePython(),
                [script, query],
                environment: AppPaths.buildSubprocessEnv(),
              ).timeout(const Duration(seconds: 30));
              out = pr.stdout.toString().trim();
              if (out.isEmpty) out = pr.stderr.toString().trim();
            } catch (e) {
              out = 'Hata: $e';
            }
            onEvent(SubagentEvent('tool_completed', out.length > 200 ? '${out.substring(0, 200)}...' : out));
            payload.add({
              'role': 'tool',
              'tool_call_id': callId,
              'name': name,
              'content': out,
            });
          } else if (name == 'read_url_content') {
            final url = args['url'] ?? '';
            onEvent(SubagentEvent('tool_invoked', 'Bağlantı Okunuyor: $url'));
            var out = '';
            try {
              final res = await Process.run('curl', [
                '-sL',
                '--max-time', '20',
                '--max-filesize', '5242880',
                url,
              ]);
              out = res.stdout.toString();
              if (out.length > 12000) out = out.substring(0, 12000) + '...[Kesildi]';
              if (out.trim().isEmpty && res.stderr.toString().isNotEmpty) {
                out = 'Hata: ${res.stderr}';
              }
            } catch (e) {
              out = 'Hata: $e';
            }
            onEvent(SubagentEvent('tool_completed', out.length > 200 ? '${out.substring(0, 200)}...' : out));
            payload.add({
              'role': 'tool',
              'tool_call_id': callId,
              'name': name,
              'content': out,
            });
          } else {
            onEvent(SubagentEvent('tool_completed', 'Hata: Bilinmeyen araç ($name).'));
            payload.add({
              'role': 'tool',
              'tool_call_id': callId,
              'name': name,
              'content': 'Hata: Bilinmeyen araç.',
            });
          }
        }
        continue; // bir sonraki adım
      }

      // Tool yok -> görev bitti
      final summary =
          reply.trim().isEmpty ? 'Görev tamamlandı (özet yok).' : reply.trim();
      onEvent(SubagentEvent('done', summary));
      return summary;
    }

    final msg =
        'MAX adım ($maxSteps) aşıldı. Kısmi sonuç: görev tamamlanamadı.';
    onEvent(SubagentEvent('failed', msg));
    return msg;
  }

  /// Arka planda rezerve edilen VRAM/RAM'i boşaltmak için modeli Ollama'dan unload eder.
  Future<void> unload() async {
    try {
      final uri = Uri.parse(apiUrl);
      final baseUrl = '${uri.scheme}://${uri.host}:${uri.port}';
      await _dio.post(
        '$baseUrl/api/generate',
        data: {'model': model, 'keep_alive': 0},
        options: Options(validateStatus: (s) => true),
      );
    } catch (_) {}
  }
}
