import 'package:feride_v5_2/features/chat/state.dart';
import 'package:feride_v5_2/services/backend_manager.dart';
import 'package:flutter_test/flutter_test.dart';

const dir = '/home/u/.feride/models';
const projectors = [
  '$dir/mmproj/gemma-4-12b-it__mmproj-F16.gguf',
  '$dir/mmproj/Huihui-Qwen3.8-27B-abliterated__mmproj-model-bf16.gguf',
  '$dir/mmproj/Qwen3.8-35B-A3B-Distill__mmproj-Qwen3.8-35B-A3B-F16.gguf',
];

void main() {
  group('Model kimliği (aynı modelin yeniden yüklenmemesi)', () {
    test('Sunucunun bildirdiği tam yol listedeki ada çevrilir', () {
      expect(modelDisplayName('$dir/GLM-4.5-Air-Q4_K_S-00001-of-00002.gguf'), 'GLM-4.5-Air-Q4_K_S');
      expect(modelDisplayName('$dir/Qwen3.8-35B-A3B-Q8_0.gguf'), 'Qwen3.8-35B-A3B-Q8_0.gguf');
      expect(modelDisplayName(r'C:\Users\a\.feride\models\gemma-4-12b-it-Q4_0.gguf'), 'gemma-4-12b-it-Q4_0.gguf');
    });

    test('sameModel: yol, .gguf ve parça eki farkı aynı model sayılır', () {
      expect(sameModel('GLM-4.5-Air-Q4_K_S', 'GLM-4.5-Air-Q4_K_S-00001-of-00002.gguf'), isTrue);
      expect(sameModel('Qwen3.8-35B-A3B-Q8_0.gguf', '$dir/Qwen3.8-35B-A3B-Q8_0.gguf'), isTrue);
      expect(sameModel('GLM-4.5-Air-Q4_K_S', 'Qwen3.8-35B-A3B-Q8_0.gguf'), isFalse);
    });
  });

  group('Görüntü projektörü (mmproj) eşleştirme', () {
    String? pick(String model) => BackendManager.pickMmproj('$dir/$model', projectors, scanDirs: [dir]);

    test('Qwen3.8-35B kendi projektörünü alır (eskiden 27B\'ninkini alıp yüklenemiyordu)', () {
      expect(pick('Qwen3.8-35B-A3B-Q8_0.gguf'), contains('Qwen3.8-35B-A3B-Distill__mmproj'));
    });

    test('Huihui 27B ve Gemma 12B kendi projektörlerini alır', () {
      expect(pick('Huihui-Qwen3.8-27B-abliterated-Q8_0_L.gguf'), contains('Huihui-Qwen3.8-27B'));
      expect(pick('Huihui-Qwen3.8-27B-abliterated-UD-DW-Q4_K_M.gguf'), contains('Huihui-Qwen3.8-27B'));
      expect(pick('gemma-4-12b-it-UD-Q8_K_XL.gguf'), contains('gemma-4-12b-it__mmproj'));
    });

    test('Projektörü olmayan modele yanlış projektör verilmez', () {
      expect(pick('GLM-4.5-Air-Q4_K_S-00001-of-00002.gguf'), isNull);
      // Yalnızca 27B projektörü olsaydı 35B'ye verilmemeli (boyut farklı)
      expect(BackendManager.pickMmproj('$dir/Qwen3.8-35B-A3B-Q8_0.gguf', [projectors[1]], scanDirs: [dir]), isNull);
      expect(BackendManager.pickMmproj('$dir/gemma-4-27b-it-Q4_0.gguf', [projectors[0]], scanDirs: [dir]), isNull);
    });
  });
}
