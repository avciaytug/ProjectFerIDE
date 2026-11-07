import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import '../../aegis/aegis_service.dart';
import '../../agent/permissions.dart';
import '../../services/model_launch_planner.dart';
import '../../services/app_paths.dart';
import '../../services/mcp_service.dart';

final sharedPreferencesProvider = Provider<SharedPreferences>((ref) {
  throw UnimplementedError();
});

class SettingsState {
  final bool useGpuForStt;
  final bool useGpuForTts;
  /// Yerel modelin nasıl çalıştırılacağı (Otomatik / GPU / CPU offload / Yalnızca CPU).
  final ComputeMode computeMode;

  /// Bağlam boyutu (token); 0 = otomatik (belleğe göre seçilir).
  final int contextSetting;

  bool get useGpuForLlm => computeMode != ComputeMode.cpu;
  final String skillsPath;
  final String chatHistoryPath;
  final List<String> disabledSkills;
  final int maxSteps;
  final String? preferredModel;
  final String backendEngine; // 'llama.cpp', 'ollama', 'vllm'
  final String apiUrl;
  final String customLlamaServerPath;
  final String hfToken;

  // MCP Ayarları
  final bool mcpEnabled;
  final String mcpConfigPath;
  final bool mcpAutoDiscover;
  final int mcpTimeoutSeconds;
  final List<String> disabledMcpServers;

  // Güvenlik / çalışma alanı
  final PermissionMode permissionMode;
  final String workspaceDir;

  /// FerIDE'nin sesi: 'female' (Feride, varsayılan) veya 'male'.
  final String ttsVoice;

  /// Konuşma hızı çarpanı (0.8 – 1.3).
  final double speechRate;

  /// Ajanın göreceli yolları çözdüğü ve komutları çalıştırdığı dizin.
  String get effectiveWorkspaceDir {
    final ws = workspaceDir.trim();
    if (ws.isNotEmpty && Directory(ws).existsSync()) return ws;
    return AppPaths.homeDir;
  }

  SettingsState({
    required this.useGpuForStt,
    required this.useGpuForTts,
    this.computeMode = ComputeMode.auto,
    this.contextSetting = 0,
    required this.skillsPath,
    required this.chatHistoryPath,
    required this.disabledSkills,
    this.maxSteps = 100,
    this.preferredModel,
    this.backendEngine = 'llama.cpp',
    this.apiUrl = 'http://127.0.0.1:8080/v1',
    this.customLlamaServerPath = '',
    this.hfToken = '',
    this.mcpEnabled = true,
    required this.mcpConfigPath,
    this.mcpAutoDiscover = true,
    this.mcpTimeoutSeconds = 60,
    this.disabledMcpServers = const [],
    this.permissionMode = PermissionMode.autoEdit,
    this.workspaceDir = '',
    this.ttsVoice = 'female',
    this.speechRate = 1.0,
  });

  bool isMcpServerEnabled(String serverName) {
    if (!mcpEnabled) return false;
    return !disabledMcpServers.contains(serverName);
  }

  SettingsState copyWith({
    bool? useGpuForStt,
    bool? useGpuForTts,
    ComputeMode? computeMode,
    int? contextSetting,
    String? skillsPath,
    String? chatHistoryPath,
    List<String>? disabledSkills,
    int? maxSteps,
    String? preferredModel,
    String? backendEngine,
    String? apiUrl,
    String? customLlamaServerPath,
    String? hfToken,
    bool? mcpEnabled,
    String? mcpConfigPath,
    bool? mcpAutoDiscover,
    int? mcpTimeoutSeconds,
    List<String>? disabledMcpServers,
    PermissionMode? permissionMode,
    String? workspaceDir,
    String? ttsVoice,
    double? speechRate,
  }) {
    return SettingsState(
      useGpuForStt: useGpuForStt ?? this.useGpuForStt,
      useGpuForTts: useGpuForTts ?? this.useGpuForTts,
      computeMode: computeMode ?? this.computeMode,
      contextSetting: contextSetting ?? this.contextSetting,
      skillsPath: skillsPath ?? this.skillsPath,
      chatHistoryPath: chatHistoryPath ?? this.chatHistoryPath,
      disabledSkills: disabledSkills ?? this.disabledSkills,
      maxSteps: maxSteps ?? this.maxSteps,
      preferredModel: preferredModel ?? this.preferredModel,
      backendEngine: backendEngine ?? this.backendEngine,
      apiUrl: apiUrl ?? this.apiUrl,
      customLlamaServerPath: customLlamaServerPath ?? this.customLlamaServerPath,
      hfToken: hfToken ?? this.hfToken,
      mcpEnabled: mcpEnabled ?? this.mcpEnabled,
      mcpConfigPath: mcpConfigPath ?? this.mcpConfigPath,
      mcpAutoDiscover: mcpAutoDiscover ?? this.mcpAutoDiscover,
      mcpTimeoutSeconds: mcpTimeoutSeconds ?? this.mcpTimeoutSeconds,
      disabledMcpServers: disabledMcpServers ?? this.disabledMcpServers,
      permissionMode: permissionMode ?? this.permissionMode,
      workspaceDir: workspaceDir ?? this.workspaceDir,
      ttsVoice: ttsVoice ?? this.ttsVoice,
      speechRate: speechRate ?? this.speechRate,
    );
  }
}

class SettingsNotifier extends StateNotifier<SettingsState> {
  final SharedPreferences prefs;

  static String _defaultSkillsPath() {
    final userSkills = p.join(AppPaths.ferideDataDir, 'skills');
    if (Directory(userSkills).existsSync()) return userSkills;
    final bundledSkills = p.join(AppPaths.appRoot, 'skills_data');
    if (Directory(bundledSkills).existsSync()) return bundledSkills;
    return userSkills;
  }

  static String _defaultChatsPath() {
    final appChats = p.join(AppPaths.appRoot, 'Chats');
    if (Directory(appChats).existsSync()) return appChats;
    return p.join(AppPaths.ferideDataDir, 'Chats');
  }

  /// MCP yapılandırması her zaman kullanıcı veri klasöründe tutulur. Uygulama
  /// klasöründeki mcp_config.json yalnızca ilk açılışta kopyalanan bir şablondur:
  /// eskiden doğrudan o dosya kullanılıp içine bu makineye özgü mutlak yollar
  /// yazılıyordu; yedek başka bir bilgisayara (Windows/macOS) taşınınca MCP
  /// sunucuları bozuluyordu.
  static String _defaultMcpPath() {
    final userMcp = p.join(AppPaths.ferideDataDir, 'mcp_config.json');
    if (!File(userMcp).existsSync()) {
      try {
        final template = File(p.join(AppPaths.appRoot, 'mcp_config.json'));
        if (template.existsSync()) {
          Directory(AppPaths.ferideDataDir).createSync(recursive: true);
          template.copySync(userMcp);
        }
      } catch (_) {}
    }
    return userMcp;
  }

  static String _mcpPathFrom(String? saved) {
    final template = p.join(AppPaths.appRoot, 'mcp_config.json');
    if (saved == null || saved.trim().isEmpty || p.equals(saved, template)) return _defaultMcpPath();
    return saved;
  }

  SettingsNotifier(this.prefs)
      : super(SettingsState(
          useGpuForStt: prefs.getBool('useGpuForStt') ?? true,
          useGpuForTts: prefs.getBool('useGpuForTts') ?? true,
          // Eski "GPU kapalı" tercihi "Yalnızca CPU" olarak taşınır.
          computeMode: prefs.getString('computeMode') != null
              ? computeModeFromName(prefs.getString('computeMode'))
              : ((prefs.getBool('useGpuForLlm') ?? true) ? ComputeMode.auto : ComputeMode.cpu),
          contextSetting: prefs.getInt('contextSetting') ?? 0,
          skillsPath: prefs.getString('skillsPath') ?? _defaultSkillsPath(),
          chatHistoryPath: prefs.getString('chatHistoryPath') ?? _defaultChatsPath(),
          disabledSkills: prefs.getStringList('disabledSkills') ?? [],
          maxSteps: prefs.getInt('maxSteps') ?? 100,
          preferredModel: prefs.getString('preferredModel'),
          backendEngine: prefs.getString('backendEngine') ?? 'llama.cpp',
          apiUrl: prefs.getString('apiUrl') ?? 'http://127.0.0.1:8080/v1',
          customLlamaServerPath: prefs.getString('customLlamaServerPath') ?? '',
          hfToken: prefs.getString('hfToken') ?? '',
          mcpEnabled: prefs.getBool('mcpEnabled') ?? true,
          mcpConfigPath: _mcpPathFrom(prefs.getString('mcpConfigPath')),
          mcpAutoDiscover: prefs.getBool('mcpAutoDiscover') ?? true,
          mcpTimeoutSeconds: prefs.getInt('mcpTimeoutSeconds') ?? 60,
          disabledMcpServers: prefs.getStringList('disabledMcpServers') ?? [],
          permissionMode: permissionModeFromName(prefs.getString('permissionMode')),
          workspaceDir: prefs.getString('workspaceDir') ?? '',
          ttsVoice: prefs.getString('ttsVoice') ?? 'female',
          speechRate: prefs.getDouble('speechRate') ?? 1.0,
        )) {
    try {
      McpService.instance.loadConfig(state.mcpConfigPath);
    } catch (_) {}
  }

  void setPreferredModel(String modelName) {
    state = state.copyWith(preferredModel: modelName);
    prefs.setString('preferredModel', modelName);
  }

  void setPermissionMode(PermissionMode mode) {
    state = state.copyWith(permissionMode: mode);
    prefs.setString('permissionMode', mode.name);
  }

  void setTtsVoice(String v) {
    state = state.copyWith(ttsVoice: v);
    prefs.setString('ttsVoice', v);
  }

  void setSpeechRate(double v) {
    final r = v.clamp(0.8, 1.3).toDouble();
    state = state.copyWith(speechRate: r);
    prefs.setDouble('speechRate', r);
  }


  void setWorkspaceDir(String dir) {
    state = state.copyWith(workspaceDir: dir.trim());
    prefs.setString('workspaceDir', dir.trim());
  }

  void setBackendEngine(String engine) {
    state = state.copyWith(backendEngine: engine);
    prefs.setString('backendEngine', engine);
  }

  void setApiUrl(String url) {
    state = state.copyWith(apiUrl: url.trim());
    prefs.setString('apiUrl', url.trim());
  }

  void setCustomLlamaServerPath(String path) {
    state = state.copyWith(customLlamaServerPath: path.trim());
    prefs.setString('customLlamaServerPath', path.trim());
  }

  void setHfToken(String token) {
    state = state.copyWith(hfToken: token.trim());
    prefs.setString('hfToken', token.trim());
  }

  void toggleSttGpu(bool value) {
    state = state.copyWith(useGpuForStt: value);
    prefs.setBool('useGpuForStt', value);
  }

  void toggleTtsGpu(bool value) {
    state = state.copyWith(useGpuForTts: value);
    prefs.setBool('useGpuForTts', value);
  }

  void setComputeMode(ComputeMode mode) {
    state = state.copyWith(computeMode: mode);
    prefs.setString('computeMode', mode.name);
  }

  void setContextSetting(int ctx) {
    state = state.copyWith(contextSetting: ctx);
    prefs.setInt('contextSetting', ctx);
  }

  void setSkillsPath(String path) {
    state = state.copyWith(skillsPath: path);
    prefs.setString('skillsPath', path);
    try {
      AegisService.instance.importSkillsFromDirectory(path);
    } catch (_) {}
  }

  void setChatHistoryPath(String path) {
    state = state.copyWith(chatHistoryPath: path);
    prefs.setString('chatHistoryPath', path);
  }

  void setMaxSteps(int steps) {
    state = state.copyWith(maxSteps: steps);
    prefs.setInt('maxSteps', steps);
  }

  void toggleSkill(String skillName, bool enabled) {
    final list = List<String>.from(state.disabledSkills);
    if (enabled) {
      list.remove(skillName);
    } else if (!list.contains(skillName)) {
      list.add(skillName);
    }
    state = state.copyWith(disabledSkills: list);
    prefs.setStringList('disabledSkills', list);
  }

  bool isSkillEnabled(String skillName) {
    return !state.disabledSkills.contains(skillName);
  }

  void deleteSkill(String skillName) {
    AegisService.instance.deleteSkillCompletely(skillName, customSkillsPath: state.skillsPath);
    final list = List<String>.from(state.disabledSkills)..remove(skillName);
    state = state.copyWith(disabledSkills: list);
    prefs.setStringList('disabledSkills', list);
  }

  void toggleMcp(bool enabled) {
    state = state.copyWith(mcpEnabled: enabled);
    prefs.setBool('mcpEnabled', enabled);
  }

  void setMcpConfigPath(String path) {
    state = state.copyWith(mcpConfigPath: path);
    prefs.setString('mcpConfigPath', path);
    try {
      McpService.instance.loadConfig(path);
    } catch (_) {}
  }

  void toggleMcpAutoDiscover(bool enabled) {
    state = state.copyWith(mcpAutoDiscover: enabled);
    prefs.setBool('mcpAutoDiscover', enabled);
  }

  void setMcpTimeoutSeconds(int seconds) {
    state = state.copyWith(mcpTimeoutSeconds: seconds);
    prefs.setInt('mcpTimeoutSeconds', seconds);
  }

  void toggleMcpServer(String serverName, bool enabled) {
    final list = List<String>.from(state.disabledMcpServers);
    if (enabled) {
      list.remove(serverName);
    } else if (!list.contains(serverName)) {
      list.add(serverName);
    }
    state = state.copyWith(disabledMcpServers: list);
    prefs.setStringList('disabledMcpServers', list);
    McpService.instance.toggleServer(serverName, enabled);
  }

  bool isMcpServerEnabled(String serverName) {
    if (!state.mcpEnabled) return false;
    return !state.disabledMcpServers.contains(serverName);
  }
}

final settingsProvider = StateNotifierProvider<SettingsNotifier, SettingsState>((ref) {
  final prefs = ref.watch(sharedPreferencesProvider);
  return SettingsNotifier(prefs);
});
