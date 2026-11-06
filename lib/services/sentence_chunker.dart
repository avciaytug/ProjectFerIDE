/// Cümle dedektörü — LLM stream'inde tamamlanan cümleleri yakalar.
///
/// Plan'daki chunking mantığının test edilebilir, saf (stateful ama bağımsız)
/// hali. `feed()` kümülatif metni alır, yeni tamamlanan cümleleri döndürür.
class SentenceChunker {
  final RegExp _sentenceEnders = RegExp(r'[.!?]\s');
  final RegExp _endsWithSentence = RegExp(r'[.!?]$');
  String _buffer = '';
  int _sentStart = 0;

  /// Kümülatif metni besle; yeni tamamlanan cümleleri (trimlenmiş) döndür.
  List<String> feed(String cumulative) {
    // Metin küçüldüyse yeni bir mesaj başlamış olabilir — tamponu sıfırla.
    // Ancak sadece sondaki boşluklar silindiyse sıfırlama (duplicate final mesajları için).
    if (cumulative.length < _buffer.length && _buffer.trim() != cumulative.trim()) {
      _buffer = '';
      _sentStart = 0;
    }
    _buffer = cumulative;
    final out = <String>[];

    for (final m in _sentenceEnders.allMatches(_buffer)) {
      if (m.start < _sentStart) continue;
      final sentence = _stripPunct(_buffer.substring(_sentStart, m.end).trim());
      if (sentence.length > 2) out.add(sentence);
      _sentStart = m.end;
    }

    // Uç kontrolü: metin [.!?] ile bitiyorsa (boşluk olmadan) o da cümledir
    final tail = _buffer.substring(_sentStart);
    final tailTrimmed = tail.trimRight();
    if (tailTrimmed.isNotEmpty && _endsWithSentence.hasMatch(tailTrimmed)) {
      final sentence = _stripPunct(tailTrimmed.trim());
      if (sentence.length > 2) out.add(sentence);
      _sentStart = _sentStart + tail.length;
    }

    return out;
  }

  /// Cümlenin sonundaki noktalama işaretlerini (. ? ! …) keser.
  static String _stripPunct(String s) =>
      s.replaceFirst(RegExp(r'[.!?…]+$'), '').trim();

  /// Kalan tamamlanmamış parçayı döndür ve tamponu sıfırla.
  String flush() {
    final remaining = _buffer.substring(_sentStart).trim();
    _buffer = '';
    _sentStart = 0;
    return remaining;
  }

  void reset() {
    _buffer = '';
    _sentStart = 0;
  }
}
