library;

import 'dart:collection';
import 'dart:convert';

/// FerIDE Akıllı Durdurma ve Döngü Önleme Yöneticisi (Claude Code Standartları)
///
/// Salt-okuma döngülerini ve yinelenen araç çağrılarını tespit ederek
/// gereksiz token tüketimini ve takılmaları önler.

enum ProgressActionStatus {
  progress,     // Mutasyon yapıldı (dosya yazıldı, derlendi, vb.)
  readOnly,     // Salt okuma yapıldı
  warning,      // 5 adımdır sadece okuma yapılıyor (modele yönlendirme)
  stalled,      // 8 adımdır mutasyon yok (modele özetleme/eylem uyarısı)
  loopDetected, // Aynı araç çağrısı birebir tekrarlandı
}

class ProgressTracker {
  int totalSteps = 0;
  int stepsSinceLastMutation = 0;
  int consecutiveLoopCount = 0;
  final Set<String> inspectedPaths = {};
  final List<String> recentToolSignatures = [];

  static const int kWarningThreshold = 5;
  static const int kStallThreshold = 8;
  static const int kMaxRepetition = 3;

  /// "İlerleme" sayılan (stall sayacını sıfırlayan) keşif araçları
  static const Set<String> _exploratoryTools = {
    'grep_search',
    'glob',
  };

  ProgressActionStatus recordToolCall(String name, Map<String, dynamic> args) {
    totalSteps++;

    // 1. Döngü tespiti (deterministik anahtar sıralamalı imza)
    String serializedArgs;
    try {
      final sortedMap = SplayTreeMap<String, dynamic>.from(args);
      serializedArgs = jsonEncode(sortedMap);
    } catch (_) {
      serializedArgs = args.toString();
    }
    final signature = '$name:$serializedArgs';

    recentToolSignatures.add(signature);
    if (recentToolSignatures.length > 10) {
      recentToolSignatures.removeAt(0);
    }

    if (recentToolSignatures.length >= kMaxRepetition) {
      final last = recentToolSignatures.last;
      bool allEqual = true;
      for (int i = recentToolSignatures.length - kMaxRepetition;
          i < recentToolSignatures.length;
          i++) {
        if (recentToolSignatures[i] != last) {
          allEqual = false;
          break;
        }
      }
      if (allEqual) {
        consecutiveLoopCount++;
        return ProgressActionStatus.loopDetected;
      }
    }
    consecutiveLoopCount = 0;

    // 2. Mutasyon kontrolü
    final isMutating = isMutationTool(name, args);
    if (isMutating) {
      stepsSinceLastMutation = 0;
      return ProgressActionStatus.progress;
    }

    // 3. Keşif araçları (grep, glob) stall sayacını sıfırlar
    if (_exploratoryTools.contains(name)) {
      stepsSinceLastMutation = 0;
      return ProgressActionStatus.readOnly;
    }

    // 4. Salt okuma (read_file / read_document / run_command cat vb.)
    if (name == 'read_file' || name == 'read_document') {
      final p = args['path']?.toString();
      if (p != null) {
        inspectedPaths.add(p);
      }
    }
    stepsSinceLastMutation++;

    if (stepsSinceLastMutation >= kStallThreshold) {
      return ProgressActionStatus.stalled;
    }
    if (stepsSinceLastMutation >= kWarningThreshold) {
      return ProgressActionStatus.warning;
    }

    return ProgressActionStatus.readOnly;
  }

  static bool isMutationTool(String name, Map<String, dynamic> args) {
    if (name == 'write_to_file' ||
        name == 'replace_file_content' ||
        name == 'edit_media_or_document' ||
        name == 'open_file_in_system' ||
        name == 'apply_patch' ||
        name == 'save_skill' ||
        name == 'todo_write') {
      return true;
    }

    if (name == 'run_command') {
      final cmd = (args['command'] ?? '').toString().toLowerCase();
      // Salt okuma komutları
      final isReadOnly = RegExp(
              r'^\s*(cat|grep|strings|find|head|tail|ls|which|objdump|echo\s+[^\>]*$)\b')
          .hasMatch(cmd);
      if (isReadOnly) return false;

      // Değişiklik yapan komutlar (build, test, git commit, mkdir, touch, cp, mv, sed vb.)
      return true;
    }

    return false;
  }

  void reset() {
    totalSteps = 0;
    stepsSinceLastMutation = 0;
    consecutiveLoopCount = 0;
    inspectedPaths.clear();
    recentToolSignatures.clear();
  }
}
