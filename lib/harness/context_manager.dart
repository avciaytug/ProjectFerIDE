import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:path/path.dart' as p;
import '../services/app_paths.dart';

/// FerIDE Context & Prompt Budget Manager
class ContextManager {
  /// Fetches actual active context size (n_ctx) from llama-server /props endpoint.
  static Future<int?> fetchServerContextSize(String apiUrl) async {
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 2);
      final request = await client.getUrl(Uri.parse('$apiUrl/props'));
      final response = await request.close().timeout(const Duration(seconds: 3));
      if (response.statusCode == 200) {
        final body = await response.transform(utf8.decoder).join();
        final json = jsonDecode(body) as Map<String, dynamic>;
        client.close(force: true);
        if (json.containsKey('default_generation_settings')) {
          final nCtx = json['default_generation_settings']?['n_ctx'];
          if (nCtx is num) return nCtx.toInt();
        }
        if (json.containsKey('n_ctx') && json['n_ctx'] is num) {
          return (json['n_ctx'] as num).toInt();
        }
      }
      client.close(force: true);
    } catch (_) {}
    return null;
  }

  /// Mesaj sırası geçerli mi? Hata listesini döndürür (boşsa geçerli).
  static List<String> validateMessageOrder(List<Map<String, dynamic>> messages) {
    final List<String> errors = [];
    final Set<String> expectedToolCallIds = {};
    final Set<String> answeredToolCallIds = {};

    for (int i = 0; i < messages.length; i++) {
      final msg = messages[i];
      final role = msg['role'] as String? ?? '';

      // 1. system rolü yalnızca 0. indekste olabilir.
      if (role == 'system' && i != 0) {
        errors.add('System mesajı index 0 dışında bulundu: index $i');
      }

      // 2. assistant mesajlarında tool_calls id\'lerini topla
      if (role == 'assistant') {
        final toolCalls = msg['tool_calls'];
        if (toolCalls is List) {
          for (var tc in toolCalls) {
            if (tc is Map && tc['id'] != null) {
              expectedToolCallIds.add(tc['id'].toString());
            }
          }
        }
      }

      // 3. tool mesajlarının tool_call_id kontrolü
      if (role == 'tool') {
        final id = msg['tool_call_id']?.toString() ?? '';
        if (id.isEmpty) {
          errors.add('Tool mesajı için tool_call_id eksik: index $i');
        } else if (!expectedToolCallIds.contains(id)) {
          errors.add('Yetim tool mesajı (önceki assistant.tool_calls içinde bulunamadı): id=$id, index $i');
        } else {
          answeredToolCallIds.add(id);
        }
      }
    }

    // 4. assistant.tool_calls içindeki tüm id\'ler yanıtlanmış olmalı
    for (final expectedId in expectedToolCallIds) {
      if (!answeredToolCallIds.contains(expectedId)) {
        errors.add('Cevapsız tool çağrısı (karşılık gelen tool rolü mesajı yok): id=$expectedId');
      }
    }

    return errors;
  }

  /// Sadece ekleyen (append-only) bağlam ve eşikte tek seferlik sıkıştırma.
  /// Eşik altında hiçbir mesaja dokunulmaz (önbellek korunur).
  /// Eşik aşıldığında:
  /// - System mesajı (index 0) KESİNLİKLE KORUNUR.
  /// - Kullanıcı ana talebi (user query) KESİNLİKLE KORUNUR (Jinja "No user query" hatasını önler).
  /// - Ara adımlar (araç çıktıları vb.) özetlenerek kullanıcı talebinin altına eklenir.
  /// - Son turdaki assistant ve tool mesajları bütünlük içinde korunur.
  static void compactIfNeeded({
    required List<Map<String, dynamic>> messages,
    required int maxContextTokens,
    String? sessionId,
  }) {
    if (messages.length <= 8) return;

    // Eşik: maxContextTokens * 0.5 (maks 60000 token)
    final int compactAt = min((maxContextTokens * 0.5).round(), 60000);

    // Token tahmini (~3.2 karakter / token)
    int totalEstimatedChars = 0;
    for (var msg in messages) {
      final content = msg['content'];
      if (content is String) {
        totalEstimatedChars += content.length;
      } else if (content is List) {
        for (var part in content) {
          if (part is Map && part['text'] is String) {
            totalEstimatedChars += (part['text'] as String).length;
          }
        }
      }
    }

    int estimatedTokens = (totalEstimatedChars / 3.2).ceil();
    // Eşik altındaysa mesajlara dokunulmaz (önbellek %100 korunur)
    if (estimatedTokens <= compactAt) return;

    // 1. İlk kullanıcı mesajını bul (korunması şart)
    int firstUserIdx = -1;
    for (int i = 0; i < messages.length; i++) {
      if (messages[i]['role'] == 'user') {
        firstUserIdx = i;
        break;
      }
    }

    // 2. Korunacak son mesajlar penceresi (en az 6-8 mesaj)
    const int preserveCount = 8;
    int splitIndex = messages.length - preserveCount;
    if (splitIndex <= (firstUserIdx >= 0 ? firstUserIdx + 1 : 1)) {
      return; // Sıkıştırılacak yeterli ara mesaj yok
    }

    // Tool / Assistant çiftlerini bölmemek için kontrol:
    // Eğer splitIndex bir 'tool' mesajına denk geliyorsa, o aracın çağrıldığı 'assistant'
    // mesajına kadar geriye kaydır.
    while (splitIndex > (firstUserIdx >= 0 ? firstUserIdx + 1 : 1) &&
        messages[splitIndex]['role'] == 'tool') {
      splitIndex--;
    }

    // 3. Sıkıştırılacak ara mesajları ayıkla (ilk kullanıcı mesajından sonra, splitIndex'e kadar)
    final int pruneStart = firstUserIdx >= 0 ? firstUserIdx + 1 : 1;
    if (splitIndex <= pruneStart) return;

    final discarded = messages.sublist(pruneStart, splitIndex);
    messages.removeRange(pruneStart, splitIndex);

    // 4. Çıkarılan araç çıktılarını ve ara yanıtları özetle
    final List<String> summaryLines = [];
    for (var d in discarded) {
      final role = d['role'];
      if (role == 'tool') {
        final out = d['content']?.toString() ?? '';
        final snippet = out.length > 200 ? '${out.substring(0, 200)}... [özet]' : out;
        summaryLines.add('- Araç [${d['name'] ?? 'tool'}]: $snippet');
      } else if (role == 'assistant' && d['content'] != null) {
        final text = d['content'].toString();
        if (text.isNotEmpty) {
          final snippet = text.length > 150 ? '${text.substring(0, 150)}...' : text;
          summaryLines.add('- Asistan Notu: $snippet');
        }
      }
    }

    // 5. Özeti kullanıcı mesajına entegre et (Böylece model ne yaptığını hatırlar)
    if (summaryLines.isNotEmpty) {
      if (firstUserIdx >= 0 && firstUserIdx < messages.length) {
        final existingContent = messages[firstUserIdx]['content']?.toString() ?? '';
        messages[firstUserIdx]['content'] =
            '$existingContent\n\n[SIKIŞTIRILMIŞ GEÇMİŞ ÖZETİ (${discarded.length} adım derlendi)]:\n${summaryLines.join("\n")}';
      } else {
        // Kullanıcı mesajı yoksa hemen system arkasına kullanıcı mesajı olarak ekle
        final insertIdx = messages.isNotEmpty && messages[0]['role'] == 'system' ? 1 : 0;
        messages.insert(insertIdx, {
          'role': 'user',
          'content': '[ÖNCEKİ ADIMLAR VE BULGULAR ÖZETİ]:\n${summaryLines.join("\n")}\n\nLütfen analize ve göreve devam edin.',
        });
      }
    }

    // 6. KESİN GÜVENCE: Jinja template "No user query found" hatasını engellemek için
    // dizide en az bir 'user' mesajı bulunduğunu garanti et.
    final bool hasUser = messages.any((m) => m['role'] == 'user');
    if (!hasUser) {
      final insertIdx = messages.isNotEmpty && messages[0]['role'] == 'system' ? 1 : 0;
      messages.insert(insertIdx, {
        'role': 'user',
        'content': 'Lütfen mevcut bağlamı ve hedefleri dikkate alarak göreve devam edin.',
      });
    }

    // perf.jsonl log
    try {
      final logDir = Directory(p.join(AppPaths.ferideDataDir, 'logs'));
      if (!logDir.existsSync()) logDir.createSync(recursive: true);
      final perfFile = File(p.join(logDir.path, 'perf.jsonl'));
      perfFile.writeAsStringSync(
        jsonEncode({
          "event": "compaction",
          "session": sessionId ?? "default",
          "before_msgs": discarded.length + messages.length,
          "after_msgs": messages.length,
          "ts": DateTime.now().toIso8601String()
        }) + String.fromCharCode(10),
        mode: FileMode.append,
      );
    } catch (_) {}
  }

  /// Geriye uyumluluk için alias
  static void pruneAndBudgetMessages({
    required List<Map<String, dynamic>> messages,
    required int maxContextTokens,
  }) {
    compactIfNeeded(messages: messages, maxContextTokens: maxContextTokens);
  }
}
