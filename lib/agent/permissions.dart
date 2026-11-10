/// FerIDE izin ve güvenlik katmanı.
///
/// Her araç bir risk sınıfına sahiptir. Kullanıcının seçtiği izin moduna göre
/// araç doğrudan çalışır, kullanıcıya sorulur ya da tamamen engellenir.
/// Katastrofik komutlar (disk silme, fork bomb vb.) hiçbir modda çalışmaz.
library;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../services/app_paths.dart';

/// Aracın sistem üzerindeki etkisi.
enum ToolRisk {
  /// Sadece okur (dosya okuma, arama, listeleme).
  read,

  /// Diskte dosya oluşturur/değiştirir.
  write,

  /// Komut/uygulama çalıştırır veya sistemin durumunu değiştirir.
  execute,

  /// Dış ağa istek atar (web arama, URL okuma).
  network,
}

/// Kullanıcının seçtiği izin modu.
enum PermissionMode {
  /// Okuma dışındaki her işlem için onay iste.
  ask,

  /// Dosya düzenlemelerine (çalışma alanında) izin ver, komutlar için onay iste.
  autoEdit,

  /// Her şey otomatik (katastrofik komutlar yine engellenir).
  fullAuto,
}

PermissionMode permissionModeFromName(String? name) => PermissionMode.values
    .firstWhere((m) => m.name == name, orElse: () => PermissionMode.autoEdit);

String permissionModeLabel(PermissionMode m) => switch (m) {
      PermissionMode.ask => 'Her işlemde sor',
      PermissionMode.autoEdit => 'Dosya düzenlemeye izin ver, komutları sor',
      PermissionMode.fullAuto => 'Tam otonom (hiçbir şey sorulmaz; yalnızca sistemi yok eden komutlar engellenir)',
    };

enum PermissionDecision { allow, ask, deny }

class PermissionVerdict {
  final PermissionDecision decision;
  final String reason;
  const PermissionVerdict(this.decision, [this.reason = '']);

  static const allow = PermissionVerdict(PermissionDecision.allow);
}

/// Kullanıcıya gösterilecek onay isteği.
class ApprovalRequest {
  final String id;
  final String toolName;
  final String summary;
  final String reason;
  final ToolRisk risk;
  final Completer<bool> _completer = Completer<bool>();

  ApprovalRequest({
    required this.id,
    required this.toolName,
    required this.summary,
    required this.reason,
    required this.risk,
  });

  Future<bool> get future => _completer.future;
  bool get isResolved => _completer.isCompleted;

  void resolve(bool approved) {
    if (!_completer.isCompleted) _completer.complete(approved);
  }
}

/// Onay isteklerini UI'a ileten köprü. UI [requests] akışını dinler ve
/// kullanıcı kararını [ApprovalRequest.resolve] ile bildirir.
class ApprovalBroker {
  ApprovalBroker._();
  static final ApprovalBroker instance = ApprovalBroker._();

  final _controller = StreamController<ApprovalRequest>.broadcast();
  final List<ApprovalRequest> _pending = [];

  Stream<ApprovalRequest> get requests => _controller.stream;
  List<ApprovalRequest> get pending => List.unmodifiable(_pending);

  /// Oturum boyunca "her zaman izin ver" denilmiş araç adları.
  final Set<String> sessionAllowedTools = {};

  /// Kimse dinlemiyorsa (ör. testler, başsız çalışma) istek reddedilir.
  Future<bool> request(ApprovalRequest req,
      {Duration timeout = const Duration(minutes: 10)}) async {
    if (sessionAllowedTools.contains(req.toolName)) return true;
    if (!_controller.hasListener) return false;
    _pending.add(req);
    _controller.add(req);
    try {
      return await req.future.timeout(timeout, onTimeout: () => false);
    } finally {
      _pending.remove(req);
    }
  }

  /// Bekleyen tüm istekleri onaylar (kullanıcı "Tam otonom"a geçtiğinde).
  void approveAll() {
    for (final r in List.of(_pending)) {
      r.resolve(true);
    }
    _pending.clear();
  }

  /// Bekleyen tüm istekleri reddeder (ajan durdurulduğunda).
  void rejectAll() {
    for (final r in List.of(_pending)) {
      r.resolve(false);
    }
    _pending.clear();
  }
}

class PermissionPolicy {
  final PermissionMode _mode;
  final String workspaceDir;

  /// Verilirse izin modu her araç çağrısında buradan GÜNCEL olarak okunur.
  /// Böylece görev sürerken üst çubuktan "Tam otonom"a geçmek o görevi de
  /// hemen etkiler (eskiden görev başındaki mod sonuna kadar kullanılıyordu).
  final PermissionMode Function()? _modeOf;

  const PermissionPolicy({
    required PermissionMode mode,
    required this.workspaceDir,
    PermissionMode Function()? modeOf,
  })  : _mode = mode,
        _modeOf = modeOf;

  PermissionMode get mode => _modeOf?.call() ?? _mode;

  /// Hiçbir modda çalıştırılmayacak komut desenleri.
  static final List<RegExp> _catastrophic = [
    RegExp(r'\brm\s+(-[a-zA-Z]*\s+)*-[a-zA-Z]*[rf][a-zA-Z]*\s+(-[a-zA-Z]+\s+)*(/|/\*|~|~/|\$HOME|/home|/usr|/etc|/boot|/var)\s*($|[;&|])'),
    RegExp(r'\bmkfs(\.\w+)?\b'),
    RegExp(r'\bdd\b[^|;&]*\bof=/dev/(sd|nvme|hd|mmcblk|vd)'),
    RegExp(r':\(\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:'), // fork bomb
    RegExp(r'>\s*/dev/(sd|nvme|hd|mmcblk|vd)[a-z0-9]*'),
    RegExp(r'\bchmod\s+(-R\s+)?[0-7]*777\s+/\s*($|[;&|])'),
    RegExp(r'\bchown\s+-R\s+\S+\s+/\s*($|[;&|])'),
    RegExp(r'\bformat\s+[a-z]:', caseSensitive: false), // Windows
    RegExp(r'Remove-Item\s+.*-Recurse.*\s+[A-Z]:\\\s*($|;)', caseSensitive: false),
    RegExp(r'\bdiskpart\b', caseSensitive: false),
  ];

  /// Tam otonom dışındaki modlarda kullanıcıya sorulacak riskli komutlar.
  /// Tam otonom modda hiçbir şey sorulmaz (yalnızca katastrofik komutlar engellenir).
  static final List<RegExp> _sensitive = [
    RegExp(r'\bsudo\b|\bpkexec\b|\bdoas\b|\brunas\b'),
    RegExp(r'\b(shutdown|reboot|poweroff|halt)\b'),
    RegExp(r'\bsystemctl\s+(stop|disable|mask|poweroff|reboot)'),
    RegExp(r'\brm\s+(-[a-zA-Z]*r[a-zA-Z]*|-[a-zA-Z]*f[a-zA-Z]*)'),
    RegExp(r'\bgit\s+(push\s+.*--force|push\s+-f|reset\s+--hard|clean\s+-[a-z]*f)'),
    RegExp(r'(curl|wget)[^|]*\|\s*(sudo\s+)?(ba|z)?sh\b'),
    RegExp(r'\b(apt|apt-get|dnf|pacman|zypper|snap|flatpak|brew|winget|choco)\s+(install|remove|purge|uninstall|-S|-R)'),
    RegExp(r'\bkill(all)?\s+-9\b|\bpkill\b'),
    RegExp(r'\bcrontab\s+-r\b'),
  ];

  /// Yazma için hassas sayılan dizinler (çalışma alanı içinde olsalar bile sorulur).
  static List<String> get _sensitivePaths {
    final home = AppPaths.homeDir;
    return [
      p.join(home, '.ssh'),
      p.join(home, '.gnupg'),
      p.join(home, '.config', 'autostart'),
      p.join(home, '.bashrc'),
      p.join(home, '.profile'),
      p.join(home, '.zshrc'),
      if (!Platform.isWindows) '/etc',
      if (!Platform.isWindows) '/usr',
      if (!Platform.isWindows) '/boot',
      if (Platform.isWindows) r'C:\Windows',
    ];
  }

  static bool isCatastrophicCommand(String cmd) =>
      _catastrophic.any((r) => r.hasMatch(cmd));

  static bool isSensitiveCommand(String cmd) =>
      _sensitive.any((r) => r.hasMatch(cmd));

  bool isInsideWorkspace(String path) {
    final abs = p.normalize(p.absolute(path));
    final ws = p.normalize(p.absolute(workspaceDir));
    return abs == ws || p.isWithin(ws, abs);
  }

  static bool isSensitivePath(String path) {
    final abs = p.normalize(p.absolute(path));
    return _sensitivePaths.any((s) => abs == s || p.isWithin(s, abs));
  }

  /// Bir araç çağrısının izin kararını verir.
  /// [command] run_command için; [paths] yazma araçlarının hedef yolları için.
  PermissionVerdict evaluate({
    required String toolName,
    required ToolRisk risk,
    String? command,
    List<String> paths = const [],
  }) {
    if (command != null && isCatastrophicCommand(command)) {
      return const PermissionVerdict(PermissionDecision.deny,
          'Bu komut sistemi geri dönülmez şekilde bozabilir ve güvenlik nedeniyle engellendi.');
    }

    switch (risk) {
      case ToolRisk.read:
        return PermissionVerdict.allow;

      case ToolRisk.network:
        return mode == PermissionMode.ask
            ? const PermissionVerdict(PermissionDecision.ask, 'İnternete erişim')
            : PermissionVerdict.allow;

      case ToolRisk.write:
        if (mode == PermissionMode.fullAuto) return PermissionVerdict.allow;
        if (paths.any(isSensitivePath)) {
          return const PermissionVerdict(
              PermissionDecision.ask, 'Hassas bir sistem/yapılandırma dosyasına yazma');
        }
        if (mode == PermissionMode.autoEdit &&
            paths.isNotEmpty &&
            paths.every(isInsideWorkspace)) {
          return PermissionVerdict.allow;
        }
        return PermissionVerdict(PermissionDecision.ask,
            paths.every(isInsideWorkspace) ? 'Dosya değişikliği' : 'Çalışma alanı dışına yazma');

      case ToolRisk.execute:
        if (mode == PermissionMode.fullAuto) return PermissionVerdict.allow;
        if (command != null && isSensitiveCommand(command)) {
          return const PermissionVerdict(
              PermissionDecision.ask, 'Yönetici yetkisi, silme veya sistem değişikliği içeren komut');
        }
        return const PermissionVerdict(PermissionDecision.ask, 'Komut çalıştırma');
    }
  }
}
