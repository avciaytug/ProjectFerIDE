/// OpenAI uyumlu (llama.cpp llama-server, Ollama, LM Studio, vLLM) yerel LLM
/// istemcisi. Akış (SSE) ile yanıtı alır; yerel araç çağrılarını hem
/// standart `tool_calls` alanından hem de bazı modellerin metin içine yazdığı
/// `<tool_call>` XML/JSON bloklarından ayrıştırır.
library;

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';

class LlmToolCall {
  final String id;
  final String name;

  /// Ham JSON argüman metni (model bozuk JSON üretmiş olabilir).
  String rawArguments;

  LlmToolCall({required this.id, required this.name, this.rawArguments = ''});

  /// Argümanları Map olarak çözer; bozuksa null döner.
  Map<String, dynamic>? get arguments {
    final raw = rawArguments.trim();
    if (raw.isEmpty) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      return null;
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> toPayload() => {
        'id': id,
        'type': 'function',
        'function': {
          'name': name,
          // Sunucuya geçersiz JSON geri göndermek llama-server'da 500 hatası
          // doğurur; bozuksa boş obje gönder.
          'arguments': arguments == null ? '{}' : (rawArguments.trim().isEmpty ? '{}' : rawArguments),
        },
      };
}

class LlmTurn {
  final String content;
  final String reasoning;
  final List<LlmToolCall> toolCalls;
  final int? promptTokens;
  final int? completionTokens;
  final double? tokensPerSecond;

  const LlmTurn({
    required this.content,
    required this.reasoning,
    required this.toolCalls,
    this.promptTokens,
    this.completionTokens,
    this.tokensPerSecond,
  });
}

class LlmException implements Exception {
  final String message;
  final int? statusCode;
  LlmException(this.message, {this.statusCode});
  @override
  String toString() => message;
}

class LlmCancelled implements Exception {
  const LlmCancelled();
}

class LlmClient {
  final String baseUrl;
  final String model;
  final Dio _dio;

  LlmClient({required this.baseUrl, required this.model, Dio? dio})
      : _dio = dio ?? Dio() {
    _dio.options.connectTimeout = const Duration(seconds: 15);
  }

  static const _uuid = Uuid();

  /// Bir tur sohbet tamamlaması ister. [onContent] / [onReasoning] biriken
  /// metinle (en fazla ~30 fps) çağrılır. Geçici sunucu hatalarında
  /// (503 model yükleniyor, 5xx, 429) otomatik yeniden dener.
  Future<LlmTurn> complete({
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>> tools = const [],
    bool enableThinking = false,
    double temperature = 0.6,
    int maxTokens = 8192,
    CancelToken? cancelToken,
    void Function(String content)? onContent,
    void Function(String reasoning)? onReasoning,
    void Function(String status)? onStatus,
  }) async {
    var attempt = 0;
    while (true) {
      attempt++;
      try {
        return await _completeOnce(
          messages: messages,
          tools: tools,
          enableThinking: enableThinking,
          temperature: temperature,
          maxTokens: maxTokens,
          cancelToken: cancelToken,
          onContent: onContent,
          onReasoning: onReasoning,
        );
      } on LlmException catch (e) {
        final code = e.statusCode;
        final transient = code == 503 || code == 502 || code == 504 || code == 429 || code == 500;
        // 503 (model yükleniyor) için ~2 dk, diğer geçici hatalar için 5 deneme.
        final maxAttempts = code == 503 ? 40 : 5;
        if (!transient || attempt >= maxAttempts) rethrow;
        final wait = code == 503 ? 3 : attempt;
        onStatus?.call(code == 503
            ? 'Model belleğe yükleniyor ($attempt/$maxAttempts)...'
            : 'Sunucu geçici hata verdi (HTTP $code), $wait sn sonra yeniden deneniyor...');
        await Future.delayed(Duration(seconds: wait));
      }
    }
  }

  Future<LlmTurn> _completeOnce({
    required List<Map<String, dynamic>> messages,
    required List<Map<String, dynamic>> tools,
    required bool enableThinking,
    required double temperature,
    required int maxTokens,
    CancelToken? cancelToken,
    void Function(String content)? onContent,
    void Function(String reasoning)? onReasoning,
  }) async {
    final body = <String, dynamic>{
      'model': model,
      'messages': messages,
      'stream': true,
      'stream_options': {'include_usage': true},
      'cache_prompt': true,
      'max_tokens': maxTokens,
      'temperature': temperature,
      'chat_template_kwargs': {'enable_thinking': enableThinking},
      if (tools.isNotEmpty) 'tools': tools,
    };

    final Response<ResponseBody> response;
    try {
      response = await _dio.post<ResponseBody>(
        '$baseUrl/chat/completions',
        data: body,
        cancelToken: cancelToken,
        options: Options(
          headers: {'Content-Type': 'application/json'},
          responseType: ResponseType.stream,
          validateStatus: (_) => true,
          sendTimeout: const Duration(seconds: 60),
          receiveTimeout: null,
        ),
      );
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) throw const LlmCancelled();
      throw LlmException(
          'Model sunucusuna ulaşılamadı ($baseUrl). Sunucunun çalıştığından emin olun. Detay: ${e.message}');
    }

    final status = response.statusCode ?? 0;
    final stream = response.data!.stream;

    if (status != 200) {
      final errBody = await _readAll(stream);
      throw LlmException(_describeHttpError(status, errBody), statusCode: status);
    }

    final content = StringBuffer();
    final reasoning = StringBuffer();
    final toolCalls = <int, LlmToolCall>{};
    int? promptTokens;
    int? completionTokens;
    double? tps;
    final sw = Stopwatch()..start();
    var lastContentFlush = 0;
    var lastReasoningFlush = 0;

    try {
      final lines = stream
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          // Hiç veri akmadan 5 dk geçerse bağlantıyı ölü kabul et.
          .timeout(const Duration(minutes: 5));

      await for (final raw in lines) {
        final line = raw.trim();
        if (!line.startsWith('data:')) continue;
        final data = line.substring(5).trim();
        if (data == '[DONE]') break;

        Map<String, dynamic> json;
        try {
          json = jsonDecode(data) as Map<String, dynamic>;
        } catch (_) {
          continue;
        }

        final usage = json['usage'];
        if (usage is Map) {
          promptTokens = (usage['prompt_tokens'] as num?)?.toInt() ?? promptTokens;
          completionTokens = (usage['completion_tokens'] as num?)?.toInt() ?? completionTokens;
        }
        final timings = json['timings'];
        if (timings is Map && timings['predicted_per_second'] is num) {
          tps = (timings['predicted_per_second'] as num).toDouble();
        }

        final choices = json['choices'];
        if (choices is! List || choices.isEmpty) continue;
        final delta = (choices.first as Map)['delta'];
        if (delta is! Map) continue;

        final r = delta['reasoning_content'] ?? delta['reasoning'];
        if (r is String && r.isNotEmpty) {
          reasoning.write(r);
          final now = sw.elapsedMilliseconds;
          if (now - lastReasoningFlush >= 33) {
            lastReasoningFlush = now;
            onReasoning?.call(reasoning.toString());
          }
        }

        final c = delta['content'];
        if (c is String && c.isNotEmpty) {
          content.write(c);
          final now = sw.elapsedMilliseconds;
          if (now - lastContentFlush >= 33) {
            lastContentFlush = now;
            onContent?.call(visibleText(content.toString()));
          }
        }

        final tcs = delta['tool_calls'];
        if (tcs is List) {
          for (final tc in tcs) {
            if (tc is! Map) continue;
            final index = (tc['index'] as num?)?.toInt() ?? toolCalls.length;
            final fn = tc['function'];
            final existing = toolCalls[index];
            if (existing == null) {
              toolCalls[index] = LlmToolCall(
                id: (tc['id'] as String?) ?? 'call_${_uuid.v4()}',
                name: (fn is Map ? fn['name'] as String? : null) ?? '',
                rawArguments: (fn is Map ? fn['arguments'] as String? : null) ?? '',
              );
            } else if (fn is Map && fn['arguments'] is String) {
              existing.rawArguments += fn['arguments'] as String;
            }
          }
        }
      }
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) throw const LlmCancelled();
      rethrow;
    } on TimeoutException {
      throw LlmException('Model 5 dakikadır yanıt üretmiyor; bağlantı kesildi.');
    }

    if (cancelToken?.isCancelled ?? false) throw const LlmCancelled();

    var text = content.toString();
    var calls = toolCalls.values.where((c) => c.name.isNotEmpty).toList();
    if (calls.isEmpty) {
      final parsed = parseInlineToolCalls(text);
      if (parsed.calls.isNotEmpty) {
        calls = parsed.calls;
        text = parsed.remainingText;
      }
    }

    onReasoning?.call(reasoning.toString());
    onContent?.call(visibleText(text));

    return LlmTurn(
      content: visibleText(text),
      reasoning: reasoning.toString(),
      toolCalls: calls,
      promptTokens: promptTokens,
      completionTokens: completionTokens,
      tokensPerSecond: tps,
    );
  }

  /// Kullanıcıya gösterilecek metin: `<tool_call>` bloğu ve sonrasını gizler,
  /// sunucu ayrıştırmadıysa `<think>` bloklarını temizler.
  static String visibleText(String text) {
    var t = text;
    final tc = t.indexOf('<tool_call>');
    if (tc >= 0) t = t.substring(0, tc);
    t = t.replaceAll(RegExp(r'<think>.*?</think>', dotAll: true), '');
    final openThink = t.indexOf('<think>');
    if (openThink >= 0) t = t.substring(0, openThink);
    return t.trim();
  }

  /// Metin içine gömülü araç çağrılarını çözer. Desteklenen biçimler:
  ///  * `<tool_call>{"name": "...", "arguments": {...}}</tool_call>` (Qwen/Hermes)
  ///  * `<tool_call><function=ad><parameter=x>..</parameter></function></tool_call>`
  static ({List<LlmToolCall> calls, String remainingText}) parseInlineToolCalls(String text) {
    final calls = <LlmToolCall>[];
    final block = RegExp(r'<tool_call>(.*?)(</tool_call>|$)', dotAll: true);
    for (final m in block.allMatches(text)) {
      final inner = (m.group(1) ?? '').trim();
      if (inner.isEmpty) continue;

      final fnMatch = RegExp(r'<function=([^>]+)>(.*?)(</function>|$)', dotAll: true).firstMatch(inner);
      if (fnMatch != null) {
        final name = fnMatch.group(1)!.trim();
        final params = fnMatch.group(2)!.trim();
        String argsJson;
        if (params.startsWith('{')) {
          argsJson = params;
        } else {
          final args = <String, dynamic>{};
          for (final pm in RegExp(r'<parameter=([^>]+)>(.*?)</parameter>', dotAll: true).allMatches(params)) {
            final value = pm.group(2)!.trim();
            args[pm.group(1)!.trim()] = _coerceScalar(value);
          }
          argsJson = jsonEncode(args);
        }
        calls.add(LlmToolCall(id: 'call_${_uuid.v4()}', name: name, rawArguments: argsJson));
        continue;
      }

      try {
        final decoded = jsonDecode(inner);
        if (decoded is Map && decoded['name'] is String) {
          final args = decoded['arguments'] ?? decoded['parameters'] ?? {};
          calls.add(LlmToolCall(
            id: 'call_${_uuid.v4()}',
            name: decoded['name'] as String,
            rawArguments: args is String ? args : jsonEncode(args),
          ));
        }
      } catch (_) {}
    }
    final remaining = text.replaceAll(block, '').trim();
    return (calls: calls, remainingText: remaining);
  }

  static dynamic _coerceScalar(String v) {
    if (v == 'true') return true;
    if (v == 'false') return false;
    final asInt = int.tryParse(v);
    if (asInt != null) return asInt;
    final asNum = double.tryParse(v);
    if (asNum != null) return asNum;
    if ((v.startsWith('{') && v.endsWith('}')) || (v.startsWith('[') && v.endsWith(']'))) {
      try {
        return jsonDecode(v);
      } catch (_) {}
    }
    return v;
  }

  static Future<String> _readAll(Stream<List<int>> s) async {
    try {
      return await s.cast<List<int>>().transform(utf8.decoder).join().timeout(const Duration(seconds: 10));
    } catch (_) {
      return '';
    }
  }

  static String _describeHttpError(int status, String body) {
    var detail = body;
    try {
      final j = jsonDecode(body);
      if (j is Map && j['error'] is Map && j['error']['message'] != null) {
        detail = j['error']['message'].toString();
      } else if (j is Map && j['error'] != null) {
        detail = j['error'].toString();
      }
    } catch (_) {}
    if (detail.length > 600) detail = '${detail.substring(0, 600)}...';

    final lower = detail.toLowerCase();
    if (lower.contains('mmproj') || lower.contains('image input is not supported')) {
      return 'Görsel desteği yok: model Vision (mmproj) eklentisi olmadan başlatılmış. Modeli mmproj ile yeniden başlatın.';
    }
    if (lower.contains('context') && (lower.contains('exceed') || lower.contains('too long') || lower.contains('n_ctx'))) {
      return 'Bağlam sınırı aşıldı: sohbet, modelin başlatıldığı bağlam boyutuna sığmıyor. '
          'Yeni sohbet başlatın ya da Ayarlar > Genel > Model Çalıştırma\'dan bağlamı büyütüp (en az 16K) modeli yeniden başlatın. ($detail)';
    }
    return 'Model sunucusu hata döndürdü [HTTP $status]: $detail';
  }

  /// Sunucunun görsel girdi destekleyip desteklemediğini kontrol eder.
  Future<bool> supportsVision() async {
    try {
      final res = await _dio.get('$baseUrl/models',
          options: Options(receiveTimeout: const Duration(seconds: 2), validateStatus: (_) => true));
      if (res.statusCode == 200 && res.data is Map) {
        final data = res.data['data'];
        if (data is List && data.isNotEmpty) {
          final arch = data.first['architecture'];
          if (arch is Map && arch['input_modalities'] is List) {
            return (arch['input_modalities'] as List).contains('image');
          }
        }
        // llama-server eski sürümleri modalities bildirmez; /props'a bak.
      }
      final props = await _dio.get('${baseUrl.replaceAll(RegExp(r'/v1/?$'), '')}/props',
          options: Options(receiveTimeout: const Duration(seconds: 2), validateStatus: (_) => true));
      if (props.statusCode == 200 && props.data is Map) {
        final mod = props.data['modalities'];
        if (mod is Map && mod['vision'] == true) return true;
      }
    } catch (_) {}
    return false;
  }
}
