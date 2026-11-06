import 'package:feride_v5_2/features/chat/ide_shell.dart';
import 'package:feride_v5_2/models/download_manager.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Ekran görüntüsündeki durum: bölünmüş GGUF'un 1. parçası indiriliyor.
  final dl = DownloadTask(
    modelId: 'unsloth/GLM-4.5-Air-GGUF',
    fileName: 'GLM-4.5-Air-Q4_K_S-00001-of-00002.gguf',
    url: 'https://example.invalid/x',
  );

  test('yalnızca indirilen deponun arama kartında görünür', () {
    expect(isDownloadFor(dl, 'unsloth/GLM-4.5-Air-GGUF', isLocal: false), isTrue);
    expect(isDownloadFor(dl, 'bartowski/ArliAI_GLM-4.5-Air-Derestricted-GGUF', isLocal: false), isFalse);
    expect(isDownloadFor(dl, 'bartowski/zai-org_GLM-4.5-Air-GGUF', isLocal: false), isFalse);
  });

  test('yüklü modellerde görünmez (eskiden hepsinde görünüyordu)', () {
    for (final local in [
      'gemma-4-12b-it-UD-Q8_K_XL.gguf',
      'gemma-4-12b-it-Q4_0.gguf',
      'Huihui-Qwen3.8-27B-abliterated-Q8_0_L.gguf',
    ]) {
      expect(isDownloadFor(dl, local, isLocal: true), isFalse, reason: local);
    }
  });

  test('indirilen dosyanın yerel kartında görünür (parça ekleri yok sayılır)', () {
    expect(isDownloadFor(dl, 'GLM-4.5-Air-Q4_K_S', isLocal: true), isTrue);
    expect(isDownloadFor(dl, 'GLM-4.5-Air-Q4_K_S-00001-of-00002.gguf', isLocal: true), isTrue);
  });

  test('modelKey sadeleştirmesi', () {
    expect(modelKey('/a/b/Model-Q4-00002-of-00003.gguf'), 'model-q4');
    expect(modelKey('-00001-of-00002.gguf'), '');
  });
}
