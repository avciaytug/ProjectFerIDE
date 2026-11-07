/// GGUF model dosyasının yalnızca başlığını okuyarak (birkaç MB) modelin bellek
/// ihtiyacını hesaplamaya yetecek bilgileri çıkarır: mimari, katman sayısı,
/// KV başlıkları, eğitim bağlamı, MoE uzman sayısı ve tensör boyutları.
///
/// Bölünmüş modellerde (…-00001-of-00003.gguf) bütün parçalar okunur.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as p;

class GgufInfo {
  final String architecture;
  final int blockCount;
  final int contextLength;
  final int headCount;
  final int headCountKv;
  final int embeddingLength;
  final int keyLength;
  final int valueLength;

  final int expertCount;

  /// Tam dikkat katmanlarının token başına KV boyutu (q8_0, bayt).
  final int fullKvPerToken;

  /// Kayan pencereli (SWA) katmanların token başına KV boyutu; bu katmanlar
  /// en fazla [slidingWindow] + ubatch token tutar.
  final int swaKvPerToken;
  final int slidingWindow;

  /// Bütün parçaların tensör verisi toplamı (bayt).
  final int weightBytes;

  /// MoE uzman tensörlerinin toplamı (bayt); "CPU offload" modunda RAM'e gider.
  final int expertBytes;
  final List<String> parts;

  const GgufInfo({
    required this.architecture,
    required this.blockCount,
    required this.contextLength,
    required this.headCount,
    required this.headCountKv,
    required this.embeddingLength,
    required this.keyLength,
    required this.valueLength,
    required this.expertCount,
    required this.fullKvPerToken,
    required this.swaKvPerToken,
    required this.slidingWindow,
    required this.weightBytes,
    required this.expertBytes,
    required this.parts,
  });

  bool get isMoe => expertCount > 1 && expertBytes > 0;

  /// GPU'da kalacak (uzman dışı) ağırlıklar.
  int get denseBytes => weightBytes - expertBytes;

  /// [ctx] token bağlam için q8_0 KV önbelleğinin toplam boyutu (bayt).
  int kvBytes(int ctx, {int ubatch = 2048}) =>
      fullKvPerToken * ctx + swaKvPerToken * math.min(ctx, slidingWindow + ubatch);

  @override
  String toString() =>
      'GgufInfo($architecture, ${blockCount}L, kvHeads=$headCountKv, k=$keyLength v=$valueLength, '
      'ctxTrain=$contextLength, kvFull=$fullKvPerToken kvSwa=$swaKvPerToken/$slidingWindow, experts=$expertCount, weights=${(weightBytes / (1 << 30)).toStringAsFixed(1)} GiB, '
      'experts=${(expertBytes / (1 << 30)).toStringAsFixed(1)} GiB, parts=${parts.length})';
}

class GgufReader {
  static final _splitRe = RegExp(r'-(\d{5})-of-(\d{5})\.gguf$', caseSensitive: false);

  /// Bölünmüş modelin bütün parça yollarını döndürür (tek parçalıysa kendisi).
  static List<String> splitParts(String path) {
    final m = _splitRe.firstMatch(p.basename(path));
    if (m == null) return [path];
    final total = int.parse(m.group(2)!);
    final prefix = path.substring(0, path.length - m.group(0)!.length);
    return [
      for (var i = 1; i <= total; i++) '$prefix-${i.toString().padLeft(5, '0')}-of-${m.group(2)}.gguf',
    ];
  }

  /// Ana iş parçacığını bloke etmeden okur.
  static Future<GgufInfo?> readAsync(String path) => Isolate.run(() => read(path));

  static GgufInfo? read(String path) {
    try {
      final parts = splitParts(path);
      final meta = <String, Object>{};
      var weightBytes = 0;
      var expertBytes = 0;
      for (var i = 0; i < parts.length; i++) {
        final f = File(parts[i]);
        if (!f.existsSync()) return null;
        final r = _parse(f, wantMeta: i == 0);
        if (i == 0) meta.addAll(r.meta);
        weightBytes += r.dataBytes;
        expertBytes += r.expertBytes;
      }
      final arch = (meta['general.architecture'] as String?) ?? '';
      Object? m(String key) => meta['$arch.$key'];
      int num(String key) {
        final v = m(key);
        if (v is int) return v;
        if (v is List && v.isNotEmpty) return v.whereType<int>().fold(0, math.max);
        return 0;
      }

      final layers = num('block_count');
      final headCount = num('attention.head_count');
      final embd = num('embedding_length');
      final headDim = embd > 0 && headCount > 0 ? embd ~/ headCount : 128;
      final kLen = num('attention.key_length') > 0 ? num('attention.key_length') : headDim;
      final vLen = num('attention.value_length') > 0 ? num('attention.value_length') : headDim;
      final kLenSwa = num('attention.key_length_swa') > 0 ? num('attention.key_length_swa') : kLen;
      final vLenSwa = num('attention.value_length_swa') > 0 ? num('attention.value_length_swa') : vLen;
      final kvHeadsRaw = m('attention.head_count_kv');
      final window = num('attention.sliding_window');
      final swaPattern = m('attention.sliding_window_pattern');
      final recurrent = m('attention.recurrent_layers');
      final fullInterval = num('full_attention_interval');
      final kvLoraRank = num('attention.kv_lora_rank');
      final ropeDim = num('rope.dimension_count');
      // MTP/NextN tahmin katmanları için KV ayrılmaz.
      final kvLayers = math.max(0, layers - num('nextn_predict_layers'));
      const bpe = 34 / 32; // q8_0: 32 eleman 34 bayt

      var full = 0.0;
      var swa = 0.0;
      for (var i = 0; i < kvLayers; i++) {
        final isRecurrent = recurrent is List && i < recurrent.length
            ? recurrent[i] == true
            : (fullInterval > 1 && (i + 1) % fullInterval != 0);
        if (isRecurrent) continue;
        final kvHeads = kvHeadsRaw is List && i < kvHeadsRaw.length
            ? (kvHeadsRaw[i] as int)
            : (kvHeadsRaw is int && kvHeadsRaw > 0 ? kvHeadsRaw : headCount);
        if (kvLoraRank > 0) {
          full += (kvLoraRank + ropeDim) * bpe; // MLA: sıkıştırılmış tek vektör
          continue;
        }
        final isSwa = window > 0 && swaPattern is List && i < swaPattern.length && swaPattern[i] == true;
        if (isSwa) {
          swa += kvHeads * (kLenSwa + vLenSwa) * bpe;
        } else {
          full += kvHeads * (kLen + vLen) * bpe;
        }
      }
      if (layers == 0) full = 128 * 1024; // bilinmeyen model: kötümser tahmin

      return GgufInfo(
        architecture: arch,
        blockCount: layers,
        contextLength: num('context_length'),
        headCount: headCount,
        headCountKv: num('attention.head_count_kv'),
        embeddingLength: embd,
        keyLength: kLen,
        valueLength: vLen,
        expertCount: num('expert_count'),
        fullKvPerToken: full.ceil(),
        swaKvPerToken: swa.ceil(),
        slidingWindow: window,
        weightBytes: weightBytes,
        expertBytes: expertBytes,
        parts: parts,
      );
    } catch (_) {
      return null;
    }
  }

  static ({Map<String, Object> meta, int dataBytes, int expertBytes}) _parse(File file, {required bool wantMeta}) {
    final raf = file.openSync();
    try {
      final r = _Reader(raf);
      if (ascii.decode(r.bytes(4), allowInvalid: true) != 'GGUF') {
        throw const FormatException('GGUF değil');
      }
      final version = r.u32();
      if (version < 2) throw const FormatException('Eski GGUF sürümü');
      final tensorCount = r.u64();
      final kvCount = r.u64();
      final meta = <String, Object>{};
      var alignment = 32;
      for (var i = 0; i < kvCount; i++) {
        final key = r.str();
        final type = r.u32();
        final interesting = key == 'general.alignment' ||
            (wantMeta && (key == 'general.architecture' || !key.startsWith('tokenizer.')));
        final v = r.value(type, keep: interesting);
        if (v != null && interesting) meta[key] = v;
        if (key == 'general.alignment' && v is int && v > 0) alignment = v;
      }
      final names = <String>[];
      final offsets = <int>[];
      for (var i = 0; i < tensorCount; i++) {
        names.add(r.str());
        final nDims = r.u32();
        for (var d = 0; d < nDims; d++) {
          r.u64();
        }
        r.u32(); // ggml tipi
        offsets.add(r.u64());
      }
      final dataStart = (r.pos + alignment - 1) ~/ alignment * alignment;
      final dataBytes = math.max(0, file.lengthSync() - dataStart);
      // Tensör boyutu = bir sonraki tensörün ofseti - kendi ofseti (veri bitişik).
      final order = List<int>.generate(offsets.length, (i) => i)..sort((a, b) => offsets[a].compareTo(offsets[b]));
      var expert = 0;
      for (var j = 0; j < order.length; j++) {
        final i = order[j];
        final end = j + 1 < order.length ? offsets[order[j + 1]] : dataBytes;
        if (names[i].contains('_exps')) expert += math.max(0, end - offsets[i]);
      }
      return (meta: meta, dataBytes: dataBytes, expertBytes: expert);
    } finally {
      raf.closeSync();
    }
  }
}

/// Tamponlu, küçük-endian ikili okuyucu.
class _Reader {
  final RandomAccessFile _f;
  final Uint8List _buf = Uint8List(1 << 20);
  int _bufStart = 0;
  int _bufLen = 0;
  int pos = 0;

  _Reader(this._f);

  void _ensure(int n) {
    if (pos >= _bufStart && pos + n <= _bufStart + _bufLen) return;
    _f.setPositionSync(pos);
    _bufStart = pos;
    _bufLen = _f.readIntoSync(_buf, 0, _buf.length);
    if (_bufLen < n && n <= _buf.length) throw const FormatException('Beklenmedik dosya sonu');
  }

  Uint8List bytes(int n) {
    if (n > _buf.length) {
      _f.setPositionSync(pos);
      final out = _f.readSync(n);
      pos += n;
      return out;
    }
    _ensure(n);
    final off = pos - _bufStart;
    pos += n;
    return Uint8List.sublistView(_buf, off, off + n);
  }

  void skip(int n) => pos += n;

  int u32() => ByteData.sublistView(bytes(4)).getUint32(0, Endian.little);
  int u64() => ByteData.sublistView(bytes(8)).getUint64(0, Endian.little);

  String str() {
    final len = u64();
    if (len > (64 << 20)) throw const FormatException('Geçersiz metin uzunluğu');
    return utf8.decode(bytes(len), allowMalformed: true);
  }

  static const _fixed = {0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 7: 1, 10: 8, 11: 8, 12: 8};

  /// Bir değeri okur; [keep] false ise yalnızca atlar (büyük tokenizer dizileri gibi).
  Object? value(int type, {required bool keep}) {
    switch (type) {
      case 8:
        if (!keep) {
          skip(u64());
          return null;
        }
        return str();
      case 9:
        final elemType = u32();
        final count = u64();
        final size = _fixed[elemType];
        if (!keep || count > 4096) {
          if (size != null) {
            skip(size * count);
          } else {
            for (var i = 0; i < count; i++) {
              value(elemType, keep: false);
            }
          }
          return null;
        }
        return [for (var i = 0; i < count; i++) value(elemType, keep: true)];
      default:
        final size = _fixed[type];
        if (size == null) throw FormatException('Bilinmeyen GGUF tipi $type');
        final b = ByteData.sublistView(bytes(size));
        if (!keep) return null;
        return switch (type) {
          0 => b.getUint8(0),
          1 => b.getInt8(0),
          2 => b.getUint16(0, Endian.little),
          3 => b.getInt16(0, Endian.little),
          4 => b.getUint32(0, Endian.little),
          5 => b.getInt32(0, Endian.little),
          6 => b.getFloat32(0, Endian.little),
          7 => b.getUint8(0) != 0,
          10 => b.getUint64(0, Endian.little),
          11 => b.getInt64(0, Endian.little),
          _ => b.getFloat64(0, Endian.little),
        };
    }
  }
}
