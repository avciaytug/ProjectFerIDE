import 'dart:convert';
import 'mcp_settings_tab.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'widgets/aurora_background.dart';
import 'widgets/ide_sidebar.dart';
import 'agent_panel.dart';
import 'state.dart';
import '../../theme/ide_palette.dart';
import '../live/live_session_view.dart';
import 'dart:async';
import 'dart:io' show Directory, File, Platform;
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import '../settings/settings_provider.dart';
import '../../models/download_manager.dart';
import 'package:file_picker/file_picker.dart';
import '../../aegis/aegis_service.dart';
import '../../services/system_installer_service.dart';


class IdeShell extends ConsumerStatefulWidget {
  const IdeShell({super.key});

  @override
  ConsumerState<IdeShell> createState() => _IdeShellState();
}

class _IdeShellState extends ConsumerState<IdeShell> {
  @override
  void initState() {
    super.initState();
    if (!Platform.environment.containsKey('FLUTTER_TEST')) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await ref.read(selectedModelProvider.notifier).syncWithRunningServer();
        ref.read(selectedModelProvider.notifier).startModel();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeMode = ref.watch(themeModeProvider);
    final isSidebarOpen = ref.watch(isSidebarOpenProvider);
    final isLight = themeMode == ThemeMode.light;

    // Not: main.dart'ta zaten MaterialApp var → burada iç (nested) MaterialApp
    // yerine Theme kullanıyoruz. Nested MaterialApp, testte iki MaterialApp
    // bulunduran ve MediaQuery/Navigator'ı çift sarmalayan bir hata kaynağıydı.
    return Theme(
      data: themeMode == ThemeMode.dark
          ? ThemeData.dark().copyWith(
              scaffoldBackgroundColor: IdePalette.backgroundBase,
              colorScheme: const ColorScheme.dark(
                surface: IdePalette.glassBackground,
                primary: IdePalette.accentSoft,
              ),
            )
          : ThemeData.light().copyWith(
              scaffoldBackgroundColor: Colors.white,
              colorScheme: const ColorScheme.light(
                surface: Color(0xFFF3F3F3), // VSCode sidebar light grey
                primary: Color(0xFF0066B8), // VSCode blue accent
              ),
            ),
      child: Scaffold(
        backgroundColor: themeMode == ThemeMode.light
            ? Colors.white
            : IdePalette.backgroundBase,
        body: AuroraBackground(
          child: Column(
            children: [
              _buildFerIdeHeader(),
              const Divider(height: 1, color: IdePalette.glassBorder),
              Consumer(
                builder: (context, ref, _) {
                  final activeDl = ref.watch(downloadControllerProvider);
                  if (activeDl != null && activeDl.status != DownloadStatus.canceled) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                      child: FloatingDownloadBar(download: activeDl, isLight: isLight),
                    );
                  }
                  return const SizedBox.shrink();
                },
              ),
              Expanded(
                child: Row(
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeInOut,
                      width: isSidebarOpen ? 280 : 0,
                      child: ClipRect(
                        child: OverflowBox(
                          minWidth: 0,
                          maxWidth: 280,
                          alignment: Alignment.centerLeft,
                          child: const IdeSidebar(),
                        ),
                      ),
                    ),
                    const Expanded(
                      child: AgentPanel(),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFerIdeHeader() {
    final language = ref.watch(languageProvider);
    final langStr = language == AppLanguage.tr ? 'tr' : 'en';
    final loc = ref.watch(localizationProvider);

    final isDark = ref.watch(themeModeProvider) == ThemeMode.dark;
    final selectedModel = ref.watch(selectedModelProvider);
    final isThinkingOn = ref.watch(thinkingModeProvider);
    final thinkingLevel = ref.watch(thinkingLevelProvider);
    final isSidebarOpen = ref.watch(isSidebarOpenProvider);
    final availableModelsAsync = ref.watch(availableModelsProvider);

    final isLight = Theme.of(context).brightness == Brightness.light;
    final glassColor = isLight
        ? Colors.black.withOpacity(0.05)
        : Colors.white.withOpacity(0.05);
    final textColor = isLight ? Colors.black87 : IdePalette.textPrimary;
    final iconColor = isLight ? Colors.black54 : IdePalette.textSecondary;

    return Container(
      height: 60,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      color:
          isLight ? Colors.white.withOpacity(0.8) : IdePalette.glassBackground,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              _buildIconButton(
                context,
                icon: isSidebarOpen ? Icons.menu_open : Icons.menu,
                onTap: () => ref.read(isSidebarOpenProvider.notifier).state =
                    !isSidebarOpen,
                tooltip: 'Menüyü Aç/Kapat',
                glassColor: glassColor,
                iconColor: iconColor,
              ),
              const SizedBox(width: 16),
              const Icon(Icons.auto_awesome,
                  color: IdePalette.accentSoft, size: 22),
              const SizedBox(width: 8),
              Text('FerIDE Beta v5.3.4',
                  style: TextStyle(
                      color: textColor,
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                      letterSpacing: 1.0)),

            ],
          ),
          Row(
            children: [
              // Live Session Button
              _buildIconButton(
                context,
                icon: Icons.record_voice_over,
                onTap: () {
                  showDialog(
                    context: context,
                    builder: (context) => const Dialog(
                      backgroundColor: Colors.transparent,
                      elevation: 0,
                      insetPadding: EdgeInsets.all(24),
                      child: LiveSessionView(),
                    ),
                  );
                },
                tooltip: loc['live_session']?[langStr] ?? 'Canlı Oturum',
                glassColor: glassColor,
                iconColor: IdePalette.accentSoft, // Make it pop
              ),
              const SizedBox(width: 16),
              // Thinking Mode Switch
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: glassColor,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                      color: isLight ? Colors.black12 : IdePalette.glassBorder),
                ),
                child: Row(
                  children: [
                    Text('Thinking:',
                        style: TextStyle(
                            color: iconColor,
                            fontSize: 13,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(width: 8),
                    SizedBox(
                      height: 24,
                      child: Switch(
                        value: isThinkingOn,
                        onChanged: (val) =>
                            ref.read(thinkingModeProvider.notifier).state = val,
                        activeColor: IdePalette.accentSoft,
                      ),
                    ),
                    if (isThinkingOn) ...[
                      const SizedBox(width: 8),
                      DropdownButton<ThinkingLevel>(
                        value: thinkingLevel,
                        dropdownColor:
                            isLight ? Colors.white : IdePalette.backgroundBase,
                        underline: const SizedBox(),
                        icon: Icon(Icons.arrow_drop_down,
                            color: iconColor, size: 18),
                        style: const TextStyle(
                            color: IdePalette.accentSoft,
                            fontSize: 13,
                            fontWeight: FontWeight.bold),
                        items: ThinkingLevel.values.map((lvl) {
                          String label = '';
                          switch (lvl) {
                            case ThinkingLevel.low:
                              label = 'Low';
                              break;
                            case ThinkingLevel.med:
                              label = 'Med';
                              break;
                            case ThinkingLevel.high:
                              label = 'High';
                              break;
                            case ThinkingLevel.xHigh:
                              label = 'xHigh';
                              break;
                            case ThinkingLevel.max:
                              label = 'Max';
                              break;
                          }
                          return DropdownMenuItem(
                              value: lvl, child: Text(label));
                        }).toList(),
                        onChanged: (val) {
                          if (val != null)
                            ref.read(thinkingLevelProvider.notifier).state =
                                val;
                        },
                      ),
                    ]
                  ],
                ),
              ),
              const SizedBox(width: 16),

              // Real Model Selector Combobox and Power Button
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    decoration: BoxDecoration(
                      color: glassColor,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                          color: isLight
                              ? Colors.black12
                              : IdePalette.glassBorder),
                    ),
                    child: availableModelsAsync.when(
                      data: (models) {
                        if (models.isEmpty) models = ['llama.cpp (Fallback)'];

                        final isRunning = ref.watch(isBackendRunningProvider);
                        final isSwitching = ref.watch(isModelSwitchingProvider);

                        final currentVal = models.contains(selectedModel)
                            ? selectedModel
                            : models.first;

                        return Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (isSwitching)
                              const Padding(
                                padding: EdgeInsets.only(right: 8),
                                child: SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: IdePalette.accentSoft,
                                  ),
                                ),
                              ),
                            DropdownButton<String>(
                              value: currentVal,
                              dropdownColor: isLight
                                  ? Colors.white
                                  : IdePalette.backgroundBase,
                              underline: const SizedBox(),
                              icon: Icon(Icons.memory,
                                  color: isSwitching
                                      ? IdePalette.accentSoft
                                      : (isRunning
                                          ? IdePalette.accentSoft
                                          : iconColor),
                                  size: 16),
                              style: TextStyle(
                                  color: isSwitching
                                      ? IdePalette.accentSoft
                                      : (isRunning
                                          ? IdePalette.accentSoft
                                          : textColor),
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500),
                              items: models.map((model) {
                                return DropdownMenuItem(
                                    value: model, child: Text(model));
                              }).toList(),
                              onChanged: isSwitching
                                  ? null
                                  : (val) {
                                      if (val != null && val != selectedModel) {
                                        ref
                                            .read(selectedModelProvider.notifier)
                                            .switchModel(val);
                                      }
                                    },
                            ),
                          ],
                        );
                      },
                      loading: () => const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2)),
                      error: (_, __) => const Text('Hata'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Power/Play Button for Model
                  Consumer(
                    builder: (context, ref, _) {
                      final isRunning = ref.watch(isBackendRunningProvider);
                      final isSwitching = ref.watch(isModelSwitchingProvider);
                      return _buildIconButton(
                        context,
                        icon: isSwitching
                            ? Icons.hourglass_top_rounded
                            : (isRunning
                                ? Icons.power_settings_new
                                : Icons.play_arrow_rounded),
                        onTap: isSwitching
                            ? () {}
                            : () => ref
                                .read(selectedModelProvider.notifier)
                                .toggleModel(),
                        tooltip: isSwitching
                            ? 'Model yükleniyor, lütfen bekleyin...'
                            : (isRunning
                                ? 'Modeli Durdur (RAMi Boşalt)'
                                : 'Modeli Başlat'),
                        glassColor: isRunning
                            ? IdePalette.accentGlow.withOpacity(0.2)
                            : glassColor,
                        iconColor:
                            isRunning ? IdePalette.accentSoft : iconColor,
                      );
                    },
                  ),
                ],
              ),
              const SizedBox(width: 20),
              Container(width: 1, height: 24, color: IdePalette.glassBorder),
              const SizedBox(width: 20),

              // Language Toggle
              _buildTextButton(
                context,
                text: language == AppLanguage.tr ? 'TR' : 'EN',
                onTap: () => ref.read(languageProvider.notifier).state =
                    language == AppLanguage.tr
                        ? AppLanguage.en
                        : AppLanguage.tr,
                tooltip: 'Dili Değiştir',
                glassColor: glassColor,
                textColor: iconColor,
              ),
              const SizedBox(width: 8),

              // Theme Toggle
              _buildIconButton(
                context,
                icon: isDark ? Icons.light_mode : Icons.dark_mode,
                onTap: () => ref.read(themeModeProvider.notifier).state =
                    isDark ? ThemeMode.light : ThemeMode.dark,
                tooltip: 'Temayı Değiştir',
                glassColor: glassColor,
                iconColor: iconColor,
              ),
              const SizedBox(width: 8),

              // Settings Modal
              _buildIconButton(
                context,
                icon: Icons.settings,
                onTap: () => _showSettingsDialog(context),
                tooltip: 'Ayarlar',
                glassColor: glassColor,
                iconColor: iconColor,
              ),
            ],
          )
        ],
      ),
    );
  }

  Widget _buildIconButton(BuildContext context,
      {required IconData icon,
      required VoidCallback onTap,
      required String tooltip,
      required Color glassColor,
      required Color iconColor}) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: glassColor,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
                color: Theme.of(context).brightness == Brightness.light
                    ? Colors.black12
                    : IdePalette.glassBorder),
          ),
          child: Icon(icon, size: 20, color: iconColor),
        ),
      ),
    );
  }

  Widget _buildTextButton(BuildContext context,
      {required String text,
      required VoidCallback onTap,
      required String tooltip,
      required Color glassColor,
      required Color textColor}) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: glassColor,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
                color: Theme.of(context).brightness == Brightness.light
                    ? Colors.black12
                    : IdePalette.glassBorder),
          ),
          child: Text(text,
              style: TextStyle(
                  color: textColor, fontWeight: FontWeight.bold, fontSize: 14)),
        ),
      ),
    );
  }



  void _showSettingsDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) {
        return Dialog(
          insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          child: const SettingsDialogWidget(),
        );
      },
    );
  }
}

// Geniş Ekran Ayarlar & Model Merkezi Modalı (v5.3.4)
class SettingsDialogWidget extends ConsumerStatefulWidget {
  const SettingsDialogWidget({super.key});

  @override
  ConsumerState<SettingsDialogWidget> createState() =>
      _SettingsDialogWidgetState();
}

class _SettingsDialogWidgetState extends ConsumerState<SettingsDialogWidget> {
  String _llamaFlavor = Platform.isMacOS ? 'metal' : 'vulkan';
  late TextEditingController _apiController;
  late TextEditingController _hfTokenController;
  late TextEditingController _modelSearchController;
  late TextEditingController _skillSearchController;
  late ScrollController _hfScrollController;
  late ScrollController _localScrollController;
  String _modelQuery = '';
  String _skillQuery = '';

  final Dio _dio = Dio();
  Timer? _debounce;
  List<Map<String, dynamic>> _searchResults = [];
  bool _isSearching = false;

  Map<String, String> _hfHeaders() {
    final token = ref.read(settingsProvider).hfToken.trim();
    return {
      'User-Agent': 'FerIDE-5.3.4',
      if (token.isNotEmpty) 'Authorization': 'Bearer $token',
    };
  }

  static String _encodeRepoFilePath(String repoFilePath) {
    return repoFilePath.split('/').map(Uri.encodeComponent).join('/');
  }

  void _onSearchChanged(String query) {
    setState(() {
      _modelQuery = query;
    });
    if (_debounce?.isActive ?? false) _debounce!.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), () {
      _searchHuggingFace(query);
    });
  }

  Future<void> _searchHuggingFace(String query) async {
    if (query.trim().isEmpty) {
      if (mounted) {
        setState(() {
          _searchResults = [];
          _isSearching = false;
        });
      }
      return;
    }
    if (mounted) {
      setState(() {
        _isSearching = true;
      });
    }
    try {
      final res = await _dio.get(
        'https://huggingface.co/api/models',
        queryParameters: {
          'search': query,
          'filter': 'gguf',
          'sort': 'downloads',
          'direction': '-1',
          'limit': 30,
        },
        options: Options(headers: _hfHeaders()),
      );
      if (res.statusCode == 200 && mounted) {
        final List data = res.data;
        setState(() {
          _searchResults = data
              .map((e) => {
                    'name': e['id'] ?? '',
                    'downloads': e['downloads'] ?? 0,
                    'likes': e['likes'] ?? 0,
                    'url': 'https://huggingface.co/${e['id']}',
                  })
              .toList();
        });
      }
    } catch (_) {
      // ignore search network errors
    } finally {
      if (mounted) {
        setState(() {
          _isSearching = false;
        });
      }
    }
  }

  // Kuantizasyon kalitesine göre sıralama (en iyiden en kötüye).
  // Bilinmeyen/özel (örn. abliterated, ud) etiketler 500 (orta) alır.
  static int _quantRank(String path) {
    final lower = path.toLowerCase();
    if (lower.contains('q8_0') || lower.contains('q8_k') || lower.contains('q8')) return 1000;
    if (lower.contains('q6_k')) return 900;
    if (lower.contains('q5_k_m') || lower.contains('q5_0') || lower.contains('q5_k_s')) return 800;
    if (lower.contains('q4_k_m') || lower.contains('q4_k_s') || lower.contains('q4_0')) return 700;
    if (lower.contains('q3_k_m') || lower.contains('q3_k_s') || lower.contains('q3_k_l')) return 550;
    if (lower.contains('q2_k')) return 450;
    if (lower.contains('fp16') || lower.contains('f16')) return 300;
    if (lower.contains('bf16')) return 320;
    if (lower.contains('f32') || lower.contains('fp32')) return 200;
    if (lower.contains('iq') || lower.contains('imatrix')) return 600;
    return 500; // bilinmeyen
  }

  static String _getShortQuantName(String path) {
    final lower = path.toLowerCase();
    if (lower.contains('q8_0')) return 'Q8_0';
    if (lower.contains('q8')) return 'Q8';
    if (lower.contains('q6_k')) return 'Q6_K';
    if (lower.contains('q5_k_m')) return 'Q5_K_M';
    if (lower.contains('q5_k_s')) return 'Q5_K_S';
    if (lower.contains('q5_0')) return 'Q5_0';
    if (lower.contains('q4_k_m')) return 'Q4_K_M';
    if (lower.contains('q4_k_s')) return 'Q4_K_S';
    if (lower.contains('q4_0')) return 'Q4_0';
    if (lower.contains('q3_k_m')) return 'Q3_K_M';
    if (lower.contains('q2_k')) return 'Q2_K';
    if (lower.contains('fp16')) return 'FP16';
    if (lower.contains('bf16')) return 'BF16';
    return 'GGUF';
  }

  // Bir GGUF dosya adının bölünmüş olup olmadığını ve kaç parça olduğunu ayıklar.
  // Tek parça -> {part:1,total:1,base:ad}. Bölünmüş -> parça/toplam/base.
  Map<String, dynamic> _splitGgufInfoLocal(String name) {
    final m =
        RegExp(r'-(\d{4,})-of-(\d{4,})\.gguf$', caseSensitive: false)
            .firstMatch(name);
    if (m == null) return {'part': 1, 'total': 1, 'base': name};
    return {
      'part': int.tryParse(m.group(1) ?? '') ?? 1,
      'total': int.tryParse(m.group(2) ?? '') ?? 1,
      'base': name.substring(0, m.start),
    };
  }

  Future<void> _downloadModel(String modelId) async {
    await _downloadFromRepo(modelId, modelId);
  }

  Future<void> _downloadModelFromUrl(String name, String baseUrl) async {
    await _downloadFromRepo(name, baseUrl);
  }

  /// Bir HuggingFace reposundan GGUF modelini (veya kullanıcının seçtiği kuantizasyonu)
  /// indirir. İndirme ilerlemesi downloadControllerProvider üzerinden hem Model
  /// Merkezi'nde hem de ana IDE ekranında canlı olarak gösterilir.
  Future<void> _downloadFromRepo(String name, String baseUrl,
      {String? repoPath}) async {
    String cleanRepo = (repoPath != null && repoPath.isNotEmpty)
        ? repoPath
        : baseUrl.replaceFirst(RegExp(r'^https?://huggingface\.co/'), '');
    cleanRepo = cleanRepo.trim();
    while (cleanRepo.endsWith('/')) {
      cleanRepo = cleanRepo.substring(0, cleanRepo.length - 1);
    }

    // Model id'sinde repo sahibi yoksa (örn: "Qwen2.5-7B-Instruct-GGUF"),
    // HuggingFace API aramasından en popüler repo sahibini otomatik tamamla.
    if (!cleanRepo.contains('/')) {
      try {
        final searchRes = await _dio.get(
          'https://huggingface.co/api/models',
          queryParameters: {
            'search': cleanRepo,
            'filter': 'gguf',
            'sort': 'downloads',
            'direction': '-1',
            'limit': 1,
          },
        );
        if (searchRes.statusCode == 200 &&
            searchRes.data is List &&
            (searchRes.data as List).isNotEmpty) {
          cleanRepo = (searchRes.data[0]['id'] ?? cleanRepo) as String;
        }
      } catch (_) {}
    }

    // DÜZELTME: Doğru Hugging Face JSON API uç noktası: /api/models/.../tree/main
    final treeUrl = 'https://huggingface.co/api/models/$cleanRepo/tree/main?recursive=true';
    final resolveBase = 'https://huggingface.co/$cleanRepo';

    try {
      final res = await _dio.get(treeUrl, options: Options(headers: _hfHeaders()));
      if (res.statusCode != 200) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text('Model listesi alınamadı (HTTP ${res.statusCode}).'),
              backgroundColor: Colors.redAccent));
        }
        return;
      }

      List rawFiles = [];
      if (res.data is List) {
        rawFiles = res.data as List;
      } else if (res.data is String) {
        rawFiles = jsonDecode(res.data as String) as List;
      }

      final ggufs = <Map<String, dynamic>>[];
      final mmprojCandidates = <Map<String, dynamic>>[];
      for (final item in rawFiles) {
        if (item is Map) {
          final map = Map<String, dynamic>.from(item);
          final path = (map['path'] ?? '').toString();
          final lower = path.toLowerCase();
          if (!lower.endsWith('.gguf')) continue;
          if (lower.contains('mmproj')) {
            mmprojCandidates.add(map);
            continue;
          }
          if (!isAuxiliaryGgufFile(path)) {
            ggufs.add(map);
          }
        }
      }

      if (ggufs.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text(
                  'Bu model deposunda indirilebilir bir .gguf dosyası bulunamadı.'),
              backgroundColor: Colors.redAccent));
        }
        return;
      }

      // Kuantizasyon setlerine göre grupla (base = parça eki olmadan).
      final Map<String, List<Map<String, dynamic>>> sets = {};
      for (final f in ggufs) {
        final path = f['path'] as String;
        final info = _splitGgufInfoLocal(path);
        final key = info['base'] as String;
        sets.putIfAbsent(key, () => []).add(f);
      }

      // Setleri kalite puanına göre sırala (Q8 > Q6 > Q5 > Q4)
      final ranked = sets.entries.toList()
        ..sort((a, b) {
          final ra = a.value.map((f) => _quantRank(f['path'] as String))
              .reduce((x, y) => x > y ? x : y);
          final rb = b.value.map((f) => _quantRank(f['path'] as String))
              .reduce((x, y) => x > y ? x : y);
          return rb.compareTo(ra);
        });

      List<Map<String, dynamic>> chosenFiles;

      // 1. Kullanıcının arama kutusuna veya repo adına göre kuantizasyon tespiti
      final queryLower = _modelQuery.toLowerCase();
      final nameLower = name.toLowerCase();
      String? matchedKey;

      for (final targetQuant in [
        'q8_0',
        'q8',
        'q6_k',
        'q5_k_m',
        'q5_0',
        'q5',
        'q4_k_m',
        'q4_0',
        'q4'
      ]) {
        if (queryLower.contains(targetQuant) || nameLower.contains(targetQuant)) {
          final found =
              ranked.where((e) => e.key.toLowerCase().contains(targetQuant));
          if (found.isNotEmpty) {
            matchedKey = found.first.key;
            break;
          }
        }
      }

      if (matchedKey != null && sets.containsKey(matchedKey)) {
        chosenFiles = sets[matchedKey]!;
      } else if (sets.length > 1 && mounted) {
        // 2. Çoklu kuantizasyon varsa kullanıcıya seçim penceresi göster:
        final selected = await showDialog<String>(
          context: context,
          builder: (ctx) {
            final isLightDialog = Theme.of(ctx).brightness == Brightness.light;
            final dialogTextColor =
                isLightDialog ? Colors.black87 : Colors.white;
            return AlertDialog(
              backgroundColor:
                  isLightDialog ? Colors.white : const Color(0xFF1E1E2E),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
              title: Row(
                children: [
                  const Icon(Icons.tune, color: IdePalette.accentSoft),
                  const SizedBox(width: 10),
                  Text('Kuantizasyon (Kalite) Seçin',
                      style: TextStyle(
                          color: dialogTextColor,
                          fontSize: 17,
                          fontWeight: FontWeight.bold)),
                ],
              ),
              content: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 680, maxHeight: 520),
                child: SizedBox(
                  width: 660,
                  child: Scrollbar(
                    thumbVisibility: true,
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: ranked.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, idx) {
                        final entry = ranked[idx];
                        final totalB = entry.value
                            .map((f) =>
                                (f['size'] is num) ? (f['size'] as num).toInt() : 0)
                            .reduce((a, b) => a + b);
                        final isSplit = entry.value.length > 1;
                        final qBadge = _getShortQuantName(entry.key);
                        return ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 3),
                          leading: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: IdePalette.accentSoft.withOpacity(0.18),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              qBadge,
                              style: const TextStyle(
                                  color: IdePalette.accentSoft,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12),
                            ),
                          ),
                          title: Text(entry.key,
                              style: TextStyle(
                                  color: dialogTextColor,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600)),
                          subtitle: Text(
                            '${isSplit ? "${entry.value.length} Parça • " : ""}${DownloadTask.formatBytes(totalB)}',
                            style: TextStyle(
                                color: isLightDialog
                                    ? Colors.black54
                                    : Colors.white60,
                                fontSize: 11),
                          ),
                          trailing: const Icon(Icons.download,
                              color: IdePalette.accentSoft, size: 20),
                          onTap: () => Navigator.of(ctx).pop(entry.key),
                        );
                      },
                    ),
                  ),
                ),
              ),
            );
          },
        );
        if (selected == null) return; // İptal edildi
        chosenFiles = sets[selected]!;
      } else {
        // Tek set varsa doğrudan onu al
        chosenFiles = ranked.first.value;
      }

      // Seçilen setin parçalarını sırala (1..N).
      final parts = chosenFiles.map((f) {
        final path = f['path'] as String;
        final info = _splitGgufInfoLocal(path);
        final sz = (f['size'] is num) ? (f['size'] as num).toInt() : 0;
        return {'path': path, 'part': info['part'], 'total': info['total'], 'size': sz};
      }).toList()
        ..sort((a, b) => (a['part'] as int).compareTo(b['part'] as int));

      final totalParts = (parts.first['total'] as int);
      int totalBytes = chosenFiles
          .map((f) => (f['size'] is num) ? (f['size'] as num).toInt() : 0)
          .reduce((a, b) => a + b);

      // Vision / Multimodal repolarda en uygun mmproj dosyasını otomatik tespit et
      Map<String, String>? mmprojQueueEntry;
      bool mmprojAlreadyInstalled = false;
      if (mmprojCandidates.isNotEmpty) {
        mmprojCandidates.sort((a, b) {
          int score(String s) {
            final l = s.toLowerCase();
            if (l.contains('f16') || l.contains('fp16')) return 100;
            if (l.contains('bf16')) return 90;
            if (l.contains('q8')) return 80;
            if (l.contains('f32')) return 60;
            return 50;
          }
          return score((b['path'] ?? '').toString())
              .compareTo(score((a['path'] ?? '').toString()));
        });
        final bestMmproj = mmprojCandidates.first;
        final mmprojRepoPath = (bestMmproj['path'] ?? '').toString();
        final mmprojSize = (bestMmproj['size'] is num) ? (bestMmproj['size'] as num).toInt() : 0;
        final repoSlug = cleanRepo
            .split('/')
            .last
            .replaceAll(RegExp(r'-gguf$', caseSensitive: false), '');
        final mmprojDestRel = 'mmproj/${repoSlug}__${p.basename(mmprojRepoPath)}';

        // Gömülü veya daha önce indirilmiş eşleşen mmproj var mı kontrol et
        for (final scanDir in getModelScanDirs()) {
          final direct = File(p.join(scanDir, mmprojDestRel));
          if (direct.existsSync() && direct.lengthSync() > 1024 * 1024) {
            mmprojAlreadyInstalled = true;
            break;
          }
          final mmDir = Directory(p.join(scanDir, 'mmproj'));
          if (mmDir.existsSync()) {
            final slugLower = repoSlug.toLowerCase();
            final hit = mmDir.listSync().whereType<File>().any((f) =>
                p.basename(f.path).toLowerCase().contains(slugLower) &&
                f.lengthSync() > 1024 * 1024);
            if (hit) {
              mmprojAlreadyInstalled = true;
              break;
            }
          }
        }

        if (!mmprojAlreadyInstalled) {
          mmprojQueueEntry = <String, String>{
            'fileName': mmprojDestRel,
            'url': '$resolveBase/resolve/main/${_encodeRepoFilePath(mmprojRepoPath)}',
            'size': mmprojSize.toString(),
          };
          totalBytes += mmprojSize;
        }
      }

      if (mounted) {
        final firstBase = p.basename(parts.first['path'] as String);
        final visionSuffix = mmprojAlreadyInstalled
            ? ' • Dahili mmproj hazır'
            : (mmprojQueueEntry != null ? ' • +mmproj dahil' : '');
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(totalParts > 1
                ? 'İndirme başladı: $firstBase ($totalParts parça, ${DownloadTask.formatBytes(totalBytes)}$visionSuffix)'
                : 'İndirme başladı: $firstBase (${DownloadTask.formatBytes(totalBytes)}$visionSuffix)'),
            backgroundColor: IdePalette.accentSoft,
            duration: const Duration(seconds: 4)));
      }

      final firstPartPath = parts.first['path'] as String;
      final firstPartSize = parts.first['size'] as int;

      // Parça 1'i başlat (kalan parçalar + varsa mmproj tamamlandığında otomatik zincirlenir ve model entegre edilir).
      ref.read(downloadControllerProvider.notifier).startDownload(
            modelId: name,
            fileName: p.basename(firstPartPath),
            url: '$resolveBase/resolve/main/${_encodeRepoFilePath(firstPartPath)}',
            knownTotalBytes: firstPartSize,
            queue: <Map<String, String>>[
              for (int i = 1; i < parts.length; i++)
                <String, String>{
                  'fileName': p.basename(parts[i]['path'] as String),
                  'url':
                      '$resolveBase/resolve/main/${_encodeRepoFilePath(parts[i]['path'] as String)}',
                  'size': (parts[i]['size'] ?? 0).toString(),
                },
              if (mmprojQueueEntry != null) mmprojQueueEntry,
            ],
          );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Bağlantı hatası: $e'),
            backgroundColor: Colors.redAccent));
      }
    }
  }

  void _confirmDeleteModel(
      BuildContext context, WidgetRef ref, String modelName) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: isLight ? Colors.white : IdePalette.backgroundBase,
        title: Row(
          children: const [
            Icon(Icons.delete_forever, color: Colors.redAccent, size: 24),
            SizedBox(width: 8),
            Text('Modeli Sil',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ],
        ),
        content: Text(
          '"$modelName" modelini bilgisayarınızdan kalıcı olarak silmek istediğinizden emin misiniz?',
          style: TextStyle(
              fontSize: 13,
              color: isLight ? Colors.black87 : IdePalette.textPrimary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('İptal',
                style: TextStyle(
                    color: isLight ? Colors.black54 : IdePalette.textSecondary)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
            ),
            onPressed: () async {
              Navigator.pop(ctx);
              await ref.read(selectedModelProvider.notifier).deleteModel(modelName);
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text('Model silindi: $modelName'),
                  backgroundColor: Colors.redAccent,
                ));
              }
            },
            child: const Text('Sil'),
          ),
        ],
      ),
    );
  }

  Widget _buildRealLocalModelCard(
    WidgetRef ref,
    String modelName,
    bool isLight,
    Color textColor,
    Color secondaryTextColor,
  ) {
    String sizeStr = 'Hazır';
    bool hasVisionMmproj = false;
    try {
      final dirs = getModelScanDirs();
      int totalBytes = 0;
      String? foundModelPath;
      for (final d in dirs) {
        final dir = Directory(d);
        if (!dir.existsSync()) continue;
        for (final ent in dir.listSync(recursive: true)) {
          if (ent is File) {
            final b = p.basename(ent.path);
            if (b == modelName || b.startsWith('$modelName-')) {
              totalBytes += ent.lengthSync();
              foundModelPath ??= ent.path;
            }
          }
        }
        if (totalBytes > 0) break;
      }
      if (totalBytes > 0) {
        sizeStr = DownloadTask.formatBytes(totalBytes);
      }
      if (foundModelPath != null) {
        hasVisionMmproj = dirs.any((d) {
              final mmDir = Directory(p.join(d, 'mmproj'));
              if (!mmDir.existsSync()) return false;
              final lowerModel = modelName.toLowerCase();
              return mmDir.listSync().whereType<File>().any((f) {
                final base = p.basename(f.path).toLowerCase();
                if (!base.contains('mmproj')) return false;
                if (base.contains('__')) {
                  final prefix = base.split('__').first;
                  return lowerModel.contains(prefix);
                }
                return true;
              });
            });
      }
    } catch (_) {}

    String quant = 'GGUF';
    final upper = modelName.toUpperCase();
    if (upper.contains('Q8_K_XL')) quant = 'UD-Q8_K_XL';
    else if (upper.contains('Q8_0') || upper.contains('Q8')) quant = '8-Bit (Q8)';
    else if (upper.contains('Q4_K_M') || upper.contains('Q4_K')) quant = '4-Bit (Q4_K)';
    else if (upper.contains('IQ3_S')) quant = '3-Bit (IQ3_S)';
    else if (upper.contains('Q5_K_M') || upper.contains('Q5_K')) quant = '5-Bit (Q5_K)';
    else if (upper.contains('Q6_K')) quant = '6-Bit (Q6_K)';
    else if (upper.contains('BF16')) quant = 'BF16';
    else if (upper.contains('F16')) quant = 'F16';
    if (hasVisionMmproj) {
      quant = '$quant • Vision';
    }

    String params = 'GGUF';
    final paramMatch = RegExp(r'(\d+(?:\.\d+)?B)\b', caseSensitive: false).firstMatch(modelName);
    if (paramMatch != null) {
      params = paramMatch.group(1)!.toUpperCase();
    }

    return _buildModelCard(
      ref,
      modelName,
      params,
      quant,
      sizeStr,
      'Auto',
      isLight,
      textColor,
      secondaryTextColor,
      isLocal: true,
    );
  }

  void _confirmDeleteSkill(
      BuildContext context, WidgetRef ref, AegisSkill skill) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: isLight ? Colors.white : const Color(0xFF1E1E2E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded,
                color: Colors.redAccent, size: 28),
            SizedBox(width: 10),
            Text('Yeteneği Sil',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          ],
        ),
        content: Text(
          '\'${skill.name}\' yeteneğini silmek istediğinizden emin misiniz?\n\nBu yetenek hafızadan ve varsa diskteki klasöründen kalıcı olarak silinecektir.',
          style: TextStyle(
              color: isLight ? Colors.black87 : Colors.white70, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('İptal', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () {
              Navigator.pop(ctx);
              ref.read(settingsProvider.notifier).deleteSkill(skill.name);
              setState(() {});
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content:
                      Text('\'${skill.name}\' yeteneği başarıyla silindi.'),
                  backgroundColor: Colors.redAccent,
                  duration: const Duration(seconds: 2),
                ),
              );
            },
            child: const Text('Sil'),
          ),
        ],
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _apiController = TextEditingController(text: ref.read(apiUrlProvider));
    _hfTokenController =
        TextEditingController(text: ref.read(settingsProvider).hfToken);
    _modelSearchController = TextEditingController();
    _skillSearchController = TextEditingController();
    _hfScrollController = ScrollController();
    _localScrollController = ScrollController();
    if (!Platform.environment.containsKey('FLUTTER_TEST')) {
      Future.microtask(() => ref
          .read(systemInstallerProvider.notifier)
          .refreshStatus(
              customLlamaPath:
                  ref.read(settingsProvider).customLlamaServerPath));
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _apiController.dispose();
    _hfTokenController.dispose();
    _modelSearchController.dispose();
    _skillSearchController.dispose();
    _hfScrollController.dispose();
    _localScrollController.dispose();
    super.dispose();
  }

  Widget _buildAutonomousSystemInstallerCard(
      bool isLight, Color textColor, Color secondaryTextColor) {
    final health = ref.watch(systemInstallerProvider);
    return _buildGlassCard(
      isLight: isLight,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                health.isLlamaReady ? Icons.verified_rounded : Icons.warning_amber_rounded,
                color: health.isLlamaReady ? Colors.greenAccent : Colors.orangeAccent,
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Llama.cpp: ${health.llamaVersion}  •  GPU: ${health.gpuDeviceSummary}',
                  style: TextStyle(
                    color: textColor,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Durumu Yenile',
                icon: Icon(Icons.refresh_rounded, size: 18, color: secondaryTextColor),
                onPressed: health.isBusy
                    ? null
                    : () => ref.read(systemInstallerProvider.notifier).refreshStatus(
                          customLlamaPath: ref.read(settingsProvider).customLlamaServerPath,
                        ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildChip(
                'Görsel Motor (mmproj): ${health.mmprojCount > 0 ? "${health.mmprojCount} Dahili/Hazır" : "Yok"}',
                health.mmprojCount > 0 ? Colors.greenAccent : Colors.orangeAccent,
                isLight,
              ),
              _buildChip(
                'Sesli Yazma (STT): ${health.hasSttReady ? "Aktif (Çevrimdışı + TR)" : "Hazır"}',
                health.hasSttReady ? Colors.greenAccent : Colors.cyanAccent,
                isLight,
              ),
              _buildChip(
                'Ofis/PDF/Görsel: ${health.hasPythonSuite ? "Aktif" : "Kurulum Gerekli"}',
                health.hasPythonSuite ? Colors.greenAccent : Colors.orangeAccent,
                isLight,
              ),
              _buildChip(
                'AutoCAD (DWG/DXF): ${health.hasCadTools ? "Aktif" : "Eksik"}',
                health.hasCadTools ? Colors.amberAccent : Colors.orangeAccent,
                isLight,
              ),
              _buildChip(
                'Ses/Müzik & OCR: ${(health.hasFfmpeg && health.hasOcr) ? "Aktif" : "Kısmi"}',
                (health.hasFfmpeg && health.hasOcr) ? Colors.cyanAccent : Colors.orangeAccent,
                isLight,
              ),
              _buildChip(
                'İndirici: ${health.hasAria2 ? "Aria2c 16x + Yerleşik" : "Yerleşik HTTP"}',
                IdePalette.accentSoft,
                isLight,
              ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 250,
                child: DropdownButtonFormField<String>(
                  value: _llamaFlavor,
                  decoration: InputDecoration(
                    labelText: 'Llama.cpp Mimari Seçimi',
                    labelStyle: TextStyle(color: secondaryTextColor, fontSize: 12),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                    filled: true,
                    fillColor: isLight
                        ? Colors.grey.withOpacity(0.1)
                        : Colors.black.withOpacity(0.2),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                  dropdownColor: Theme.of(context).scaffoldBackgroundColor,
                  items: [
                    if (Platform.isMacOS)
                      const DropdownMenuItem(
                          value: 'metal', child: Text('Apple Metal GPU (Önerilen)')),
                    const DropdownMenuItem(
                        value: 'vulkan', child: Text('Vulkan GPU (AMD/Intel/NVIDIA)')),
                    if (!Platform.isMacOS) ...[
                      const DropdownMenuItem(value: 'rocm', child: Text('AMD ROCm / HIP GPU')),
                      const DropdownMenuItem(value: 'cuda', child: Text('NVIDIA CUDA GPU')),
                    ],
                    const DropdownMenuItem(value: 'cpu', child: Text('Saf CPU')),
                    const DropdownMenuItem(
                        value: 'source', child: Text('Kaynaktan Derle (Git + CMake)')),
                  ]
                      .map((e) => DropdownMenuItem<String>(
                            value: e.value,
                            child: Text((e.child as Text).data!,
                                style: TextStyle(color: textColor, fontSize: 12)),
                          ))
                      .toList(),
                  onChanged: health.isBusy
                      ? null
                      : (v) {
                          if (v != null) setState(() => _llamaFlavor = v);
                        },
                ),
              ),
              ElevatedButton.icon(
                onPressed: health.isBusy
                    ? null
                    : () async {
                        await ref
                            .read(systemInstallerProvider.notifier)
                            .installOrUpdateLlamaCpp(flavor: _llamaFlavor);
                      },
                icon: health.isBusy
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.memory_rounded, size: 17),
                label: const Text('Llama.cpp Otonom Kur / Güncelle'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: IdePalette.accentSoft.withOpacity(0.2),
                  foregroundColor: IdePalette.accentSoft,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
              OutlinedButton.icon(
                onPressed: health.isBusy
                    ? null
                    : () async {
                        await ref
                            .read(systemInstallerProvider.notifier)
                            .repairAllSystemDependencies();
                      },
                icon: const Icon(Icons.build_circle_outlined, size: 17),
                label: const Text('Tüm Bağımlılıkları Otonom Onar'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: textColor,
                  side: BorderSide(color: IdePalette.accentSoft.withOpacity(0.5)),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ],
          ),
          if (health.logs.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 130),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.75),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white12),
              ),
              child: SingleChildScrollView(
                reverse: true,
                child: SelectableText(
                  health.logs.join('\n'),
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: Colors.greenAccent,
                    height: 1.35,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final bgColor = isLight ? Colors.white : IdePalette.backgroundBase;
    final textColor = isLight ? Colors.black87 : IdePalette.textPrimary;
    final secondaryTextColor =
        isLight ? Colors.black54 : IdePalette.textSecondary;
    final isThinkingOn = ref.watch(thinkingModeProvider);

    final screenSize = MediaQuery.sizeOf(context);
    final maxW = (screenSize.width - 36).clamp(320.0, 1560.0);
    final maxH = (screenSize.height - 28).clamp(400.0, 1020.0);
    final modalWidth = (screenSize.width * 0.95).clamp(320.0, maxW);
    final modalHeight = (screenSize.height * 0.93).clamp(400.0, maxH);

    return DefaultTabController(
      length: 4,
      child: Container(
        width: modalWidth,
        height: modalHeight,
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
              color: isLight ? Colors.black12 : IdePalette.glassBorder),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(isLight ? 0.14 : 0.45),
              blurRadius: 32,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.only(
                  top: 14.0, left: 22.0, right: 16.0, bottom: 4.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.tune_rounded,
                          color: IdePalette.accentSoft, size: 20),
                      const SizedBox(width: 10),
                      Text('AYARLAR & MODEL MERKEZİ',
                          style: TextStyle(
                              color: textColor,
                              fontSize: 17,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.2)),
                    ],
                  ),
                  IconButton(
                    tooltip: 'Kapat',
                    icon: Icon(Icons.close, color: secondaryTextColor),
                    onPressed: () => Navigator.pop(context),
                  )
                ],
              ),
            ),
            TabBar(
              labelColor: IdePalette.accentSoft,
              unselectedLabelColor: secondaryTextColor,
              indicatorColor: IdePalette.accentSoft,
              tabs: const [
                Tab(text: 'Genel (Ajan & Sistem)'),
                Tab(text: 'Yetenekler (Skills)'),
                Tab(text: 'MCP Ayarları'),
                Tab(text: 'Model Merkezi'),
              ],
            ),
            const Divider(height: 1),
            // Tab Contents
            Expanded(
              child: TabBarView(
                children: [
                  // Tab 1: Genel Ayarlar
                  ListView(
                    padding: const EdgeInsets.all(24),
                    children: [
                      _buildSectionTitle(Icons.rocket_launch_rounded,
                          'Otonom Sistem, Llama.cpp & Evrensel Dosya Motoru', textColor),
                      _buildAutonomousSystemInstallerCard(
                          isLight, textColor, secondaryTextColor),
                      const SizedBox(height: 20),
                      _buildSectionTitle(Icons.settings,
                          'Ajan Davranışı & Bağlantı', textColor),
                      _buildGlassCard(
                        isLight: isLight,
                        child: Column(
                          children: [
                            SwitchListTile(
                              title: Text('Düşünce Sürecini Göster',
                                  style: TextStyle(
                                      color: textColor,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 14)),
                              subtitle: Text(
                                  'Yapay zekanın adım adım mantık yürütmesini (<think>) sohbet ekranında gösterir.',
                                  style: TextStyle(
                                      color: secondaryTextColor, fontSize: 12)),
                              value: isThinkingOn,
                              activeColor: IdePalette.accentSoft,
                              onChanged: (val) => ref
                                  .read(thinkingModeProvider.notifier)
                                  .state = val,
                              contentPadding: EdgeInsets.zero,
                            ),
                            const Divider(),
                            SwitchListTile(
                              title: Text('Tam Otonom Mod',
                                  style: TextStyle(
                                      color: textColor,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 14)),
                              subtitle: Text(
                                  'Komutların onayınız olmadan otomatik çalışmasına izin verir.',
                                  style: TextStyle(
                                      color: secondaryTextColor, fontSize: 12)),
                              value: ref.watch(autonomousModeProvider),
                              activeColor: IdePalette.accentSoft,
                              onChanged: (val) {
                                ref
                                    .read(autonomousModeProvider.notifier)
                                    .state = val;
                              },
                              contentPadding: EdgeInsets.zero,
                            ),
                            const Divider(),
                            Padding(
                              padding: const EdgeInsets.only(top: 8.0, bottom: 8.0),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('Maksimum Adım Sınırı (Max Steps)',
                                      style: TextStyle(
                                          color: textColor,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 14)),
                                  const SizedBox(height: 4),
                                  Text(
                                      'Ajanın tek seferde çalıştırabileceği maksimum araç (tool) döngüsü. Tersine mühendislik ve derin analizler için 100-200 önerilir.',
                                      style: TextStyle(
                                          color: secondaryTextColor,
                                          fontSize: 12)),
                                  const SizedBox(height: 12),
                                  DropdownButtonFormField<int>(
                                    value: [40, 80, 100, 150, 200, 300].contains(ref.watch(settingsProvider).maxSteps)
                                        ? ref.watch(settingsProvider).maxSteps
                                        : 100,
                                    decoration: InputDecoration(
                                      border: OutlineInputBorder(
                                          borderRadius:
                                              BorderRadius.circular(8)),
                                      filled: true,
                                      fillColor: isLight
                                          ? Colors.grey.withOpacity(0.1)
                                          : Colors.black.withOpacity(0.2),
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                              horizontal: 12, vertical: 8),
                                    ),
                                    items: const [
                                      DropdownMenuItem(value: 40, child: Text('40 Adım (Hafif / Kısa Görevler)')),
                                      DropdownMenuItem(value: 80, child: Text('80 Adım (Orta Seviye)')),
                                      DropdownMenuItem(value: 100, child: Text('100 Adım (Varsayılan / Önerilen)')),
                                      DropdownMenuItem(value: 150, child: Text('150 Adım (Geniş Kapsamlı)')),
                                      DropdownMenuItem(value: 200, child: Text('200 Adım (Derin Analiz & Tersine Mühendislik)')),
                                      DropdownMenuItem(value: 300, child: Text('300 Adım (Ultra Derin / Komple Görev)')),
                                    ]
                                        .map((item) => DropdownMenuItem<int>(
                                            value: item.value,
                                            child: Text(
                                                (item.child as Text).data!,
                                                style: TextStyle(
                                                    color: textColor,
                                                    fontSize: 14))))
                                        .toList(),
                                    onChanged: (val) {
                                      if (val != null) {
                                        ref.read(settingsProvider.notifier).setMaxSteps(val);
                                      }
                                    },
                                    dropdownColor: Theme.of(context)
                                        .scaffoldBackgroundColor,
                                  ),
                                ],
                              ),
                            ),
                            const Divider(),
                            Padding(
                              padding:
                                  const EdgeInsets.only(top: 8.0, bottom: 8.0),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('API Endpoint (LLM)',
                                      style: TextStyle(
                                          color: textColor,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 14)),
                                  const SizedBox(height: 4),
                                  Text(
                                      'Bağlanılacak yerel sunucu adresi (Örn: http://localhost:1234/v1)',
                                      style: TextStyle(
                                          color: secondaryTextColor,
                                          fontSize: 12)),
                                  const SizedBox(height: 12),
                                  TextField(
                                    controller: _apiController,
                                    style: TextStyle(
                                        color: textColor, fontSize: 13),
                                    onChanged: (val) {
                                      ref.read(apiUrlProvider.notifier).state = val;
                                      ref.read(settingsProvider.notifier).setApiUrl(val);
                                    },
                                    decoration: InputDecoration(
                                      border: OutlineInputBorder(
                                          borderRadius:
                                              BorderRadius.circular(8)),
                                      filled: true,
                                      fillColor: isLight
                                          ? Colors.grey.withOpacity(0.1)
                                          : Colors.black.withOpacity(0.2),
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                              horizontal: 12, vertical: 8),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const Divider(),
                            SwitchListTile(
                              title: Text('GPU Hızlandırma (Vulkan / ROCm / CUDA)',
                                  style: TextStyle(
                                      color: textColor,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 14)),
                              subtitle: Text(
                                  'Model katmanlarını ekran kartına (-ngl 999) yükler; kapatılırsa saf CPU kullanılır.',
                                  style: TextStyle(
                                      color: secondaryTextColor, fontSize: 12)),
                              value: ref.watch(settingsProvider).useGpuForLlm,
                              activeColor: IdePalette.accentSoft,
                              onChanged: (val) => ref
                                  .read(settingsProvider.notifier)
                                  .toggleGpuForLlm(val),
                              contentPadding: EdgeInsets.zero,
                            ),
                            const Divider(),
                            Padding(
                              padding:
                                  const EdgeInsets.only(top: 8.0, bottom: 8.0),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('Arka Uç (Backend) Motoru',
                                      style: TextStyle(
                                          color: textColor,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 14)),
                                  const SizedBox(height: 4),
                                  Text(
                                      'Modeli çalıştıracak otonom çekirdeği seçin.',
                                      style: TextStyle(
                                          color: secondaryTextColor,
                                          fontSize: 12)),
                                  const SizedBox(height: 12),
                                  DropdownButtonFormField<String>(
                                    value: ['llama.cpp', 'vllm', 'ollama'].contains(
                                            ref.watch(settingsProvider).backendEngine)
                                        ? ref.watch(settingsProvider).backendEngine
                                        : 'llama.cpp',
                                    decoration: InputDecoration(
                                      border: OutlineInputBorder(
                                          borderRadius:
                                              BorderRadius.circular(8)),
                                      filled: true,
                                      fillColor: isLight
                                          ? Colors.grey.withOpacity(0.1)
                                          : Colors.black.withOpacity(0.2),
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                              horizontal: 12, vertical: 8),
                                    ),
                                    items: [
                                      const DropdownMenuItem(
                                          value: 'llama.cpp',
                                          child: Text(
                                              'llama.cpp (Önerilen / Gömülü Vulkan)')),
                                      const DropdownMenuItem(
                                          value: 'vllm',
                                          child: Text('vLLM (Hızlı / Sunucu)')),
                                      const DropdownMenuItem(
                                          value: 'ollama',
                                          child: Text('Ollama (Harici Servis)')),
                                    ]
                                        .map((item) => DropdownMenuItem(
                                            value: item.value,
                                            child: Text(
                                                (item.child as Text).data!,
                                                style: TextStyle(
                                                    color: textColor,
                                                    fontSize: 14))))
                                        .toList(),
                                    onChanged: (val) {
                                      if (val != null) {
                                        ref.read(settingsProvider.notifier).setBackendEngine(val);
                                        final suggestedUrl = val == 'ollama'
                                            ? 'http://127.0.0.1:11434/v1'
                                            : (val == 'vllm'
                                                ? 'http://127.0.0.1:8000/v1'
                                                : 'http://127.0.0.1:8080/v1');
                                        _apiController.text = suggestedUrl;
                                        ref.read(apiUrlProvider.notifier).state = suggestedUrl;
                                        ref.read(settingsProvider.notifier).setApiUrl(suggestedUrl);
                                      }
                                    },
                                    dropdownColor: Theme.of(context)
                                        .scaffoldBackgroundColor,
                                  ),
                                ],
                              ),
                            ),
                            const Divider(),
                            Padding(
                              padding: const EdgeInsets.only(top: 8.0, bottom: 8.0),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('HuggingFace Erişim Anahtarı (İsteğe Bağlı)',
                                      style: TextStyle(
                                          color: textColor,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 14)),
                                  const SizedBox(height: 4),
                                  Text(
                                      'Açık modeller anahtar gerektirmez; sadece izinli/özel (gated) HuggingFace depoları için girilir.',
                                      style: TextStyle(
                                          color: secondaryTextColor,
                                          fontSize: 12)),
                                  const SizedBox(height: 12),
                                  TextField(
                                    controller: _hfTokenController,
                                    obscureText: true,
                                    style: TextStyle(color: textColor, fontSize: 13),
                                    onChanged: (val) => ref
                                        .read(settingsProvider.notifier)
                                        .setHfToken(val),
                                    decoration: InputDecoration(
                                      hintText: 'hf_...',
                                      hintStyle: TextStyle(color: secondaryTextColor),
                                      border: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(8)),
                                      filled: true,
                                      fillColor: isLight
                                          ? Colors.grey.withOpacity(0.1)
                                          : Colors.black.withOpacity(0.2),
                                      contentPadding: const EdgeInsets.symmetric(
                                          horizontal: 12, vertical: 8),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const Divider(),
                            _buildDirectorySetting(
                              context,
                              title: 'Sohbet Geçmişi Klasörü',
                              subtitle:
                                  'Sohbet kayıtlarının kaydedileceği yerel klasör.',
                              value:
                                  ref.watch(settingsProvider).chatHistoryPath,
                              onChanged: (path) => ref
                                  .read(settingsProvider.notifier)
                                  .setChatHistoryPath(path),
                              isLight: isLight,
                              textColor: textColor,
                              secondaryTextColor: secondaryTextColor,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                  ),

                  // Tab 2: Yetenekler (Skills)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildSectionTitle(Icons.auto_awesome,
                            'Yetenek & Ajan Klasörü', textColor),
                        _buildGlassCard(
                          isLight: isLight,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildDirectorySetting(
                                context,
                                title: 'Yetenek (Skill) & Agent Klasörü',
                                subtitle:
                                    'Feride\'nin kullanacağı ajan ve yeteneklerin yerel klasörü.',
                                value: ref.watch(settingsProvider).skillsPath,
                                onChanged: (path) {
                                  ref
                                      .read(settingsProvider.notifier)
                                      .setSkillsPath(path);
                                  setState(() {});
                                },
                                isLight: isLight,
                                textColor: textColor,
                                secondaryTextColor: secondaryTextColor,
                              ),
                              const SizedBox(height: 8),
                              Align(
                                alignment: Alignment.centerRight,
                                child: ElevatedButton.icon(
                                  onPressed: () {
                                    final currentPath =
                                        ref.read(settingsProvider).skillsPath;
                                    final imported = AegisService.instance
                                        .importSkillsFromDirectory(currentPath);
                                    setState(() {});
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(
                                            'Yetenek klasörü tarandı (${imported.length} yetenek güncellendi).'),
                                        backgroundColor: IdePalette.accentSoft,
                                        duration: const Duration(seconds: 2),
                                      ),
                                    );
                                  },
                                  icon:
                                      const Icon(Icons.sync_rounded, size: 16),
                                  label: const Text(
                                      'Klasörü Tara & Hafızayı Güncelle'),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor:
                                        IdePalette.accentSoft.withOpacity(0.18),
                                    foregroundColor: IdePalette.accentSoft,
                                    elevation: 0,
                                    shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(8)),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 20),
                        // Arama ve İstatistik Çubuğu
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _skillSearchController,
                                style:
                                    TextStyle(color: textColor, fontSize: 13),
                                onChanged: (val) =>
                                    setState(() => _skillQuery = val.trim()),
                                decoration: InputDecoration(
                                  hintText:
                                      'Yüklü yeteneklerde ara (örn: git, plan, kod)...',
                                  hintStyle: TextStyle(
                                      color: secondaryTextColor, fontSize: 13),
                                  prefixIcon: Icon(Icons.search,
                                      color: secondaryTextColor, size: 20),
                                  suffixIcon: _skillQuery.isNotEmpty
                                      ? IconButton(
                                          icon:
                                              const Icon(Icons.clear, size: 18),
                                          color: secondaryTextColor,
                                          onPressed: () {
                                            _skillSearchController.clear();
                                            setState(() => _skillQuery = '');
                                          },
                                        )
                                      : null,
                                  border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(8)),
                                  filled: true,
                                  fillColor: isLight
                                      ? Colors.grey.withOpacity(0.1)
                                      : Colors.black.withOpacity(0.2),
                                  contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 14, vertical: 10),
                                ),
                              ),
                            ),
                            const SizedBox(width: 16),
                            Builder(
                              builder: (context) {
                                final skills =
                                    AegisService.instance.listSkills();
                                final disabledCount = ref
                                    .watch(settingsProvider)
                                    .disabledSkills
                                    .length;
                                final activeCount =
                                    skills.length - disabledCount;
                                return Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 14, vertical: 10),
                                  decoration: BoxDecoration(
                                    color: isLight
                                        ? Colors.grey.withOpacity(0.1)
                                        : Colors.black.withOpacity(0.2),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                        color: isLight
                                            ? Colors.black12
                                            : IdePalette.glassBorder),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(Icons.extension_rounded,
                                          size: 16,
                                          color: IdePalette.accentSoft),
                                      const SizedBox(width: 8),
                                      Text(
                                        '${skills.length} Yetenek ($activeCount Aktif)',
                                        style: TextStyle(
                                            color: textColor,
                                            fontSize: 12,
                                            fontWeight: FontWeight.bold),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        // Yetenekler Listesi
                        Expanded(
                          child: Builder(
                            builder: (context) {
                              final allSkills =
                                  AegisService.instance.listSkills();
                              final disabledList =
                                  ref.watch(settingsProvider).disabledSkills;
                              final filtered = allSkills.where((s) {
                                if (_skillQuery.isEmpty) return true;
                                final q = _skillQuery.toLowerCase();
                                return s.name.toLowerCase().contains(q) ||
                                    s.description.toLowerCase().contains(q);
                              }).toList();

                              if (filtered.isEmpty) {
                                return Center(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.extension_off_rounded,
                                          size: 48,
                                          color: secondaryTextColor
                                              .withOpacity(0.5)),
                                      const SizedBox(height: 12),
                                      Text(
                                        _skillQuery.isEmpty
                                            ? 'Henüz yüklü yetenek bulunamadı.\nYukarıdaki "Klasörü Tara" butonuna tıklayarak yetenekleri yükleyebilirsiniz.'
                                            : '"$_skillQuery" aramasına uygun yetenek bulunamadı.',
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                            color: secondaryTextColor,
                                            fontSize: 13),
                                      ),
                                    ],
                                  ),
                                );
                              }

                              return ListView.separated(
                                itemCount: filtered.length,
                                separatorBuilder: (context, i) =>
                                    const SizedBox(height: 8),
                                itemBuilder: (context, index) {
                                  final skill = filtered[index];
                                  final isEnabled =
                                      !disabledList.contains(skill.name);

                                  return Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 16, vertical: 12),
                                    decoration: BoxDecoration(
                                      color: isLight
                                          ? (isEnabled
                                              ? Colors.white
                                              : Colors.grey.withOpacity(0.08))
                                          : (isEnabled
                                              ? Colors.white.withOpacity(0.04)
                                              : Colors.black.withOpacity(0.2)),
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: isEnabled
                                            ? IdePalette.accentSoft.withOpacity(
                                                isLight ? 0.3 : 0.4)
                                            : (isLight
                                                ? Colors.black12
                                                : IdePalette.glassBorder
                                                    .withOpacity(0.3)),
                                      ),
                                    ),
                                    child: Row(
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.all(10),
                                          decoration: BoxDecoration(
                                            color: isEnabled
                                                ? IdePalette.accentSoft
                                                    .withOpacity(0.15)
                                                : Colors.grey.withOpacity(0.1),
                                            shape: BoxShape.circle,
                                          ),
                                          child: Icon(
                                            Icons.extension_rounded,
                                            size: 20,
                                            color: isEnabled
                                                ? IdePalette.accentSoft
                                                : Colors.grey,
                                          ),
                                        ),
                                        const SizedBox(width: 14),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Row(
                                                children: [
                                                  Text(
                                                    skill.name,
                                                    style: TextStyle(
                                                      color: isEnabled
                                                          ? textColor
                                                          : secondaryTextColor,
                                                      fontSize: 14,
                                                      fontWeight:
                                                          FontWeight.bold,
                                                      letterSpacing: 0.3,
                                                    ),
                                                  ),
                                                  const SizedBox(width: 8),
                                                  _buildChip(
                                                    isEnabled
                                                        ? 'AKTİF'
                                                        : 'KAPALI',
                                                    isEnabled
                                                        ? Colors.greenAccent
                                                        : Colors.grey,
                                                    isLight,
                                                  ),
                                                  if (skill.useCount > 0) ...[
                                                    const SizedBox(width: 6),
                                                    _buildChip(
                                                      '${skill.useCount}x',
                                                      IdePalette.accentSoft,
                                                      isLight,
                                                    ),
                                                  ],
                                                ],
                                              ),
                                              const SizedBox(height: 4),
                                              Text(
                                                skill.description.isNotEmpty
                                                    ? skill.description
                                                    : 'Açıklama belirtilmemiş.',
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  color: secondaryTextColor,
                                                  fontSize: 12,
                                                  height: 1.3,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        // On / Off Switch
                                        Switch(
                                          value: isEnabled,
                                          activeColor: IdePalette.accentSoft,
                                          onChanged: (val) {
                                            ref
                                                .read(settingsProvider.notifier)
                                                .toggleSkill(skill.name, val);
                                          },
                                        ),
                                        const SizedBox(width: 4),
                                        // Silme Butonu
                                        IconButton(
                                          icon: const Icon(
                                              Icons.delete_outline_rounded,
                                              color: Colors.redAccent,
                                              size: 20),
                                          tooltip: 'Yeteneği Sil',
                                          onPressed: () => _confirmDeleteSkill(
                                              context, ref, skill),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Tab 3: MCP Ayarları
                  const McpSettingsTabWidget(),

                  // Tab 4: Model Merkezi (Geniş 2 Sütunlu Görünüm)
                  _buildModelCenterTab(isLight, textColor, secondaryTextColor),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildCuratedRemoteModelCards(
    bool isLight,
    Color textColor,
    Color secondaryTextColor,
  ) {
    const curated = <Map<String, String>>[
      {
        'id': 'unsloth/gemma-4-12b-it-GGUF',
        'badge1': '12B • Vision',
        'badge2': 'Dahili mmproj Hazır',
        'size': '~7.3 - 12.7 GB',
        'ram': '12-16 GB',
      },
      {
        'id': 'Qwen/Qwen2.5-Coder-7B-Instruct-GGUF',
        'badge1': '7B • Kodlama',
        'badge2': 'Q4/Q8',
        'size': '~4.8 - 8.5 GB',
        'ram': '8-12 GB',
      },
      {
        'id': 'bartowski/Qwen2.5-14B-Instruct-GGUF',
        'badge1': '14B • Ajan/Kod',
        'badge2': 'Q4/Q6/Q8',
        'size': '~9.0 - 15.7 GB',
        'ram': '16 GB',
      },
      {
        'id': 'bartowski/Qwen2.5-7B-Instruct-GGUF',
        'badge1': '7B • Genel/Hızlı',
        'badge2': 'Q4/Q8',
        'size': '~4.7 - 8.1 GB',
        'ram': '8-12 GB',
      },
      {
        'id': 'unsloth/DeepSeek-R1-Distill-Qwen-14B-GGUF',
        'badge1': '14B • Muhakeme',
        'badge2': 'Q4/Q8',
        'size': '~9.0 - 15.7 GB',
        'ram': '16 GB',
      },
    ];

    return [
      for (int i = 0; i < curated.length; i++) ...[
        if (i > 0) const SizedBox(height: 10),
        _buildModelCard(
          ref,
          curated[i]['id']!,
          curated[i]['badge1']!,
          curated[i]['badge2']!,
          curated[i]['size']!,
          curated[i]['ram']!,
          isLight,
          textColor,
          secondaryTextColor,
          isLocal: false,
          modelUrl: 'https://huggingface.co/${curated[i]['id']!}',
        ),
      ],
    ];
  }

  Widget _buildModelCenterTab(
    bool isLight,
    Color textColor,
    Color secondaryTextColor,
  ) {
    final activeDl = ref.watch(downloadControllerProvider);
    final quickQueries = const <String>[
      'gemma 4',
      'Qwen3 GGUF',
      'Qwen2.5 Coder',
      'DeepSeek R1',
      'Llama 3.3',
      'Mistral',
    ];

    Widget buildSearchHeader() {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.travel_explore_rounded,
                  color: IdePalette.accentSoft, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'HuggingFace Model Merkezi (GGUF)',
                  style: TextStyle(
                    color: textColor,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              _buildChip(
                _modelQuery.trim().isEmpty
                    ? 'Önerilen Modeller'
                    : (_isSearching
                        ? 'Aranıyor...'
                        : '${_searchResults.length} Sonuç'),
                IdePalette.accentSoft,
                isLight,
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'İndirilen GGUF modelleri otomatik olarak FerIDE\'ye entegre edilir; Vision (mmproj) destekli modellerin görsel projektörleri otomatik eşleştirilir.',
            style: TextStyle(color: secondaryTextColor, fontSize: 12),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _modelSearchController,
            style: TextStyle(color: textColor, fontSize: 14),
            onChanged: _onSearchChanged,
            decoration: InputDecoration(
              hintText:
                  'Model ara (örn: gemma 4 12B, Qwen 2.5 Coder, DeepSeek, Llama 3.3)...',
              hintStyle: TextStyle(color: secondaryTextColor, fontSize: 13),
              prefixIcon: Icon(Icons.search, color: secondaryTextColor),
              suffixIcon: _modelQuery.isNotEmpty
                  ? IconButton(
                      tooltip: 'Temizle',
                      icon: const Icon(Icons.clear, size: 18),
                      color: secondaryTextColor,
                      onPressed: () {
                        _modelSearchController.clear();
                        setState(() {
                          _modelQuery = '';
                          _searchResults = [];
                        });
                      },
                    )
                  : null,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10)),
              filled: true,
              fillColor: isLight
                  ? Colors.grey.withValues(alpha: 0.1)
                  : Colors.black.withValues(alpha: 0.24),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final q in quickQueries)
                InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: () {
                    _modelSearchController.text = q;
                    _modelSearchController.selection = TextSelection.fromPosition(
                      TextPosition(offset: q.length),
                    );
                    _onSearchChanged(q);
                  },
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                    decoration: BoxDecoration(
                      color: _modelQuery.toLowerCase() == q.toLowerCase()
                          ? IdePalette.accentSoft.withOpacity(0.24)
                          : (isLight
                              ? Colors.grey.withOpacity(0.12)
                              : Colors.white.withOpacity(0.05)),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: _modelQuery.toLowerCase() == q.toLowerCase()
                            ? IdePalette.accentSoft
                            : (isLight ? Colors.black12 : Colors.white12),
                      ),
                    ),
                    child: Text(
                      q,
                      style: TextStyle(
                        color: _modelQuery.toLowerCase() == q.toLowerCase()
                            ? IdePalette.accentSoft
                            : secondaryTextColor,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      );
    }

    Widget buildRemoteResultsScrollable() {
      if (_isSearching) {
        return const Center(
          child: Padding(
            padding: EdgeInsets.all(32.0),
            child: CircularProgressIndicator(color: IdePalette.accentSoft),
          ),
        );
      }
      if (_modelQuery.trim().isEmpty) {
        final cards =
            _buildCuratedRemoteModelCards(isLight, textColor, secondaryTextColor);
        return Scrollbar(
          controller: _hfScrollController,
          thumbVisibility: true,
          child: ListView(
            controller: _hfScrollController,
            padding: const EdgeInsets.only(right: 10, bottom: 8),
            children: cards,
          ),
        );
      }
      if (_searchResults.isEmpty) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              '"$_modelQuery" ile eşleşen GGUF model bulunamadı.\nFarklı bir anahtar kelime deneyin (örn: Qwen, Gemma, Llama, GGUF).',
              textAlign: TextAlign.center,
              style: TextStyle(color: secondaryTextColor, fontSize: 13),
            ),
          ),
        );
      }
      return Scrollbar(
        controller: _hfScrollController,
        thumbVisibility: true,
        child: ListView.separated(
          controller: _hfScrollController,
          padding: const EdgeInsets.only(right: 10, bottom: 8),
          itemCount: _searchResults.length,
          separatorBuilder: (_, __) => const SizedBox(height: 10),
          itemBuilder: (_, i) {
            final item = _searchResults[i];
            return _buildModelCard(
              ref,
              item['name'] as String,
              'İndirme: ${item['downloads']}',
              'Beğeni: ${item['likes']}',
              'GGUF (Kalite Seçimli)',
              'Auto',
              isLight,
              textColor,
              secondaryTextColor,
              isLocal: false,
              modelUrl: item['url'] as String?,
            );
          },
        ),
      );
    }

    Widget buildLocalModelsHeader(int count) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Row(
              children: [
                const Icon(Icons.storage_rounded,
                    color: Colors.greenAccent, size: 19),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    'Bilgisayarınızdaki Modeller',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: textColor,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _buildChip('$count Hazır', Colors.greenAccent, isLight),
              ],
            ),
          ),
          TextButton.icon(
            onPressed: () => ref.invalidate(availableModelsProvider),
            icon: const Icon(Icons.refresh_rounded, size: 16),
            label: const Text('Yenile'),
          ),
        ],
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (activeDl != null) ...[
            FloatingDownloadBar(
              download: activeDl,
              isLight: isLight,
            ),
            const SizedBox(height: 12),
          ],
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final isWide = constraints.maxWidth >= 900;
                final modelsAsync = ref.watch(availableModelsProvider);

                if (isWide) {
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Sol Sütun (%60): Arama Kutusu + Tam Boy Kaydırılabilir HuggingFace Sonuçları
                      Expanded(
                        flex: 60,
                        child: Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: isLight
                                ? Colors.grey.withOpacity(0.04)
                                : Colors.white.withOpacity(0.02),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: isLight
                                  ? Colors.black12
                                  : IdePalette.glassBorder,
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              buildSearchHeader(),
                              const SizedBox(height: 12),
                              const Divider(height: 1),
                              const SizedBox(height: 10),
                              Expanded(child: buildRemoteResultsScrollable()),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      // Sağ Sütun (%40): Yüklü Yerel GGUF Modelleriniz
                      Expanded(
                        flex: 40,
                        child: Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: isLight
                                ? Colors.grey.withOpacity(0.04)
                                : Colors.white.withOpacity(0.02),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: isLight
                                  ? Colors.black12
                                  : IdePalette.glassBorder,
                            ),
                          ),
                          child: modelsAsync.when(
                            data: (models) {
                              final localModels = models
                                  .where((m) =>
                                      !m.contains('(Fallback)') &&
                                      !m.startsWith('Model İndirin'))
                                  .toList();
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  buildLocalModelsHeader(localModels.length),
                                  const SizedBox(height: 4),
                                  Text(
                                    'İndirdiğiniz modeller kalıcı olarak ~/.feride/models dizininde saklanır. Çalıştırmak için ▶ butonuna tıklayın.',
                                    style: TextStyle(
                                        color: secondaryTextColor, fontSize: 11.5),
                                  ),
                                  const SizedBox(height: 10),
                                  const Divider(height: 1),
                                  const SizedBox(height: 10),
                                  Expanded(
                                    child: localModels.isEmpty
                                        ? Center(
                                            child: Padding(
                                              padding: const EdgeInsets.all(18.0),
                                              child: Column(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Icon(
                                                    Icons.download_for_offline_outlined,
                                                    size: 40,
                                                    color: secondaryTextColor
                                                        .withOpacity(0.5),
                                                  ),
                                                  const SizedBox(height: 10),
                                                  Text(
                                                    'Henüz indirilmiş yerel GGUF modeli bulunmuyor.\nSol taraftan dilediğiniz modeli aratıp tek tıkla indirebilirsiniz.',
                                                    textAlign: TextAlign.center,
                                                    style: TextStyle(
                                                      color: secondaryTextColor,
                                                      fontSize: 12.5,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          )
                                        : Scrollbar(
                                            controller: _localScrollController,
                                            thumbVisibility: true,
                                            child: ListView.separated(
                                              controller: _localScrollController,
                                              padding: const EdgeInsets.only(
                                                  right: 8, bottom: 8),
                                              itemCount: localModels.length,
                                              separatorBuilder: (_, __) =>
                                                  const SizedBox(height: 10),
                                              itemBuilder: (_, idx) =>
                                                  _buildRealLocalModelCard(
                                                ref,
                                                localModels[idx],
                                                isLight,
                                                textColor,
                                                secondaryTextColor,
                                              ),
                                            ),
                                          ),
                                  ),
                                ],
                              );
                            },
                            loading: () => const Center(
                                child: CircularProgressIndicator()),
                            error: (e, _) => Center(
                              child: Text('Hata: $e',
                                  style:
                                      const TextStyle(color: Colors.redAccent)),
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                }

                // Dar pencere (<900px) yedek görünümü
                return Scrollbar(
                  controller: _hfScrollController,
                  thumbVisibility: true,
                  child: ListView(
                    controller: _hfScrollController,
                    padding: const EdgeInsets.only(right: 8),
                    children: [
                      buildSearchHeader(),
                      const SizedBox(height: 14),
                      if (_isSearching)
                        const Padding(
                          padding: EdgeInsets.all(24),
                          child: Center(
                              child: CircularProgressIndicator(
                                  color: IdePalette.accentSoft)),
                        )
                      else if (_modelQuery.trim().isEmpty)
                        ..._buildCuratedRemoteModelCards(
                            isLight, textColor, secondaryTextColor)
                      else
                        for (int i = 0; i < _searchResults.length; i++) ...[
                          if (i > 0) const SizedBox(height: 10),
                          _buildModelCard(
                            ref,
                            _searchResults[i]['name'] as String,
                            'İndirme: ${_searchResults[i]['downloads']}',
                            'Beğeni: ${_searchResults[i]['likes']}',
                            'GGUF (Kalite Seçimli)',
                            'Auto',
                            isLight,
                            textColor,
                            secondaryTextColor,
                            isLocal: false,
                            modelUrl: _searchResults[i]['url'] as String?,
                          ),
                        ],
                      const SizedBox(height: 20),
                      const Divider(),
                      const SizedBox(height: 10),
                      modelsAsync.when(
                        data: (models) {
                          final localModels = models
                              .where((m) =>
                                  !m.contains('(Fallback)') &&
                                  !m.startsWith('Model İndirin'))
                              .toList();
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              buildLocalModelsHeader(localModels.length),
                              const SizedBox(height: 8),
                              for (int i = 0; i < localModels.length; i++) ...[
                                if (i > 0) const SizedBox(height: 10),
                                _buildRealLocalModelCard(
                                  ref,
                                  localModels[i],
                                  isLight,
                                  textColor,
                                  secondaryTextColor,
                                ),
                              ],
                            ],
                          );
                        },
                        loading: () =>
                            const Center(child: CircularProgressIndicator()),
                        error: (e, _) => Text('Hata: $e',
                            style: const TextStyle(color: Colors.redAccent)),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(IconData icon, String title, Color color) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Icon(icon, size: 20, color: IdePalette.accentSoft),
          const SizedBox(width: 8),
          Text(title,
              style: TextStyle(
                  color: color, fontSize: 16, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _buildGlassCard(
      {required bool isLight,
      required Widget child,
      EdgeInsetsGeometry padding = const EdgeInsets.all(16)}) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: isLight
            ? Colors.grey.withOpacity(0.05)
            : Colors.white.withOpacity(0.03),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: isLight ? Colors.black12 : IdePalette.glassBorder),
      ),
      child: child,
    );
  }

  Widget _buildModelCard(
      WidgetRef ref,
      String name,
      String params,
      String quant,
      String disk,
      String ram,
      bool isLight,
      Color textColor,
      Color secondaryTextColor,
      {bool isLocal = false, String? modelUrl}) {
    final activeDownload = ref.watch(downloadControllerProvider);
    final dlName = activeDownload?.fileName ?? '';
    final dlBase =
        RegExp(r'-(\d{4,})-of-(\d{4,})\.gguf$', caseSensitive: false)
                .firstMatch(dlName) !=
            null
        ? RegExp(r'-(\d{4,})-of-(\d{4,})\.gguf$', caseSensitive: false)
            .firstMatch(dlName)!
            .group(0)!
            .split('-of-')[0]
            .replaceFirst(RegExp(r'-\d{4,}$'), '')
        : dlName;
    final isThisDownloading = activeDownload != null &&
        (activeDownload.modelId.toLowerCase() == name.toLowerCase() ||
            dlName.toLowerCase() == name.toLowerCase() ||
            dlBase.toLowerCase() == name.toLowerCase() ||
            dlName.toLowerCase().contains(name.toLowerCase()) ||
            name.toLowerCase().contains(dlName.toLowerCase()) ||
            name.toLowerCase().contains(dlBase.toLowerCase()) ||
            (activeDownload.modelId.contains('/') &&
                name.toLowerCase().contains(activeDownload.modelId.split('/').last.toLowerCase())) ||
            (name.contains('/') &&
                activeDownload.modelId.toLowerCase().contains(name.split('/').last.toLowerCase())));

    return _buildGlassCard(
      isLight: isLight,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Icon(Icons.hub, color: IdePalette.accentSoft, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(name,
                        style: TextStyle(
                            color: textColor,
                            fontSize: 13,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        _buildChip(params, IdePalette.accentSoft, isLight),
                        const SizedBox(width: 6),
                        _buildChip(quant, Colors.orangeAccent, isLight),
                        const SizedBox(width: 8),
                        Text('Boyut: $disk',
                            style: TextStyle(
                                color: secondaryTextColor, fontSize: 11)),
                      ],
                    ),
                  ],
                ),
              ),
              if (isLocal)
                IconButton(
                  icon: const Icon(Icons.delete_outline,
                      color: Colors.redAccent, size: 20),
                  onPressed: () {
                    _confirmDeleteModel(context, ref, name);
                  },
                  tooltip: 'Modeli Sil',
                ),
              if (isThisDownloading &&
                  (activeDownload.status == DownloadStatus.downloading ||
                      activeDownload.status == DownloadStatus.paused))
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (activeDownload.status == DownloadStatus.downloading) ...[
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          value: activeDownload.totalBytes > 0
                              ? activeDownload.progress
                              : null,
                          strokeWidth: 2,
                          color: IdePalette.accentSoft,
                        ),
                      ),
                      const SizedBox(width: 4),
                      IconButton(
                        icon: const Icon(Icons.pause,
                            color: Colors.orangeAccent, size: 20),
                        onPressed: () {
                          ref
                              .read(downloadControllerProvider.notifier)
                              .pauseDownload();
                        },
                        tooltip: 'İndirmeyi Durdur',
                      ),
                      IconButton(
                        icon: const Icon(Icons.close,
                            color: Colors.redAccent, size: 20),
                        onPressed: () {
                          ref
                              .read(downloadControllerProvider.notifier)
                              .cancelDownload();
                        },
                        tooltip: 'İptal Et',
                      ),
                    ] else ...[
                      IconButton(
                        icon: const Icon(Icons.play_arrow,
                            color: Colors.greenAccent, size: 20),
                        onPressed: () {
                          ref
                              .read(downloadControllerProvider.notifier)
                              .resumeDownload();
                        },
                        tooltip: 'Devam Et',
                      ),
                      IconButton(
                        icon: const Icon(Icons.close,
                            color: Colors.redAccent, size: 20),
                        onPressed: () {
                          ref
                              .read(downloadControllerProvider.notifier)
                              .cancelDownload();
                        },
                        tooltip: 'İptal Et',
                      ),
                    ],
                  ],
                )
              else
                IconButton(
                  icon: Icon(isLocal ? Icons.play_arrow : Icons.download,
                      color: IdePalette.accentSoft, size: 22),
                  onPressed: () {
                    if (isLocal) {
                      ref.read(selectedModelProvider.notifier).switchModel(name);
                      Navigator.of(context).pop();
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('$name modeline geçiliyor, lütfen bekleyin...'),
                          duration: const Duration(seconds: 4),
                        ),
                      );
                    } else {
                      if (modelUrl != null && modelUrl.isNotEmpty) {
                        _downloadModelFromUrl(name, modelUrl);
                      } else {
                        _downloadModel(name);
                      }
                    }
                  },
                  tooltip: isLocal ? 'Modeli Çalıştır / Geçiş Yap' : 'İndir & Kur',
                )
            ],
          ),
          if (isThisDownloading) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: activeDownload.status == DownloadStatus.completed
                    ? 1.0
                    : (activeDownload.totalBytes > 0
                        ? activeDownload.progress
                        : null),
                minHeight: 5,
                backgroundColor:
                    isLight ? Colors.grey.shade300 : Colors.white12,
                valueColor: AlwaysStoppedAnimation(
                  activeDownload.status == DownloadStatus.completed
                      ? Colors.greenAccent
                      : activeDownload.status == DownloadStatus.paused
                          ? Colors.orangeAccent
                          : activeDownload.status == DownloadStatus.error
                              ? Colors.redAccent
                              : IdePalette.accentSoft,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(activeDownload.sizeText,
                    style:
                        TextStyle(color: secondaryTextColor, fontSize: 11)),
                Text('${activeDownload.speedText} • ${activeDownload.etaText}',
                    style: TextStyle(
                        color: activeDownload.status == DownloadStatus.paused
                            ? Colors.orangeAccent
                            : IdePalette.accentSoft,
                        fontSize: 11,
                        fontWeight: FontWeight.bold)),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildChip(String label, Color color, bool isLight) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(isLight ? 0.2 : 0.1),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withOpacity(0.5)),
      ),
      child: Text(label,
          style: TextStyle(
              color: color, fontSize: 10, fontWeight: FontWeight.bold)),
    );
  }

  Widget _buildDirectorySetting(
    BuildContext context, {
    required String title,
    required String subtitle,
    required String value,
    required Function(String) onChanged,
    required bool isLight,
    required Color textColor,
    required Color secondaryTextColor,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: TextStyle(
                  color: textColor, fontWeight: FontWeight.bold, fontSize: 14)),
          const SizedBox(height: 4),
          Text(subtitle,
              style: TextStyle(color: secondaryTextColor, fontSize: 12)),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: isLight
                        ? Colors.grey.withOpacity(0.1)
                        : Colors.black.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color:
                            isLight ? Colors.black12 : IdePalette.glassBorder),
                  ),
                  child: Text(value,
                      style: TextStyle(color: textColor, fontSize: 13),
                      overflow: TextOverflow.ellipsis),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed: () async {
                  String? selectedDirectory =
                      await FilePicker.getDirectoryPath();
                  if (selectedDirectory != null) {
                    onChanged(selectedDirectory);
                  }
                },
                icon: const Icon(Icons.folder_open, size: 16),
                label: const Text('Seç'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: IdePalette.accentSoft.withOpacity(0.2),
                  foregroundColor: IdePalette.accentSoft,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

}

class FloatingDownloadBar extends ConsumerWidget {
  final DownloadTask download;
  final bool isLight;

  const FloatingDownloadBar({
    super.key,
    required this.download,
    required this.isLight,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textColor = isLight ? Colors.black87 : Colors.white;
    final secondaryTextColor = isLight ? Colors.black54 : Colors.white70;
    final isDone = download.status == DownloadStatus.completed;
    final isPaused = download.status == DownloadStatus.paused;
    final isError = download.status == DownloadStatus.error;
    final isCanceled = download.status == DownloadStatus.canceled;

    Color themeAccentColor = IdePalette.accentSoft;
    if (isDone) {
      themeAccentColor = Colors.greenAccent;
    } else if (isPaused) {
      themeAccentColor = Colors.orangeAccent;
    } else if (isError) {
      themeAccentColor = Colors.redAccent;
    } else if (isCanceled) {
      themeAccentColor = Colors.orangeAccent;
    }

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 0, vertical: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: isLight
            ? Colors.white.withOpacity(0.96)
            : const Color(0xFF1E1E2E).withOpacity(0.96),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: themeAccentColor.withOpacity(0.6),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.25),
            blurRadius: 12,
            offset: const Offset(0, 4),
          )
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                isDone
                    ? Icons.check_circle
                    : isPaused
                        ? Icons.pause_circle_filled
                        : isError
                            ? Icons.error_outline
                            : isCanceled
                                ? Icons.cancel_outlined
                                : Icons.downloading,
                color: themeAccentColor,
                size: 26,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            download.fileName,
                            style: TextStyle(
                              color: textColor,
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: themeAccentColor.withOpacity(0.18),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            isDone
                                ? 'Tamamlandı'
                                : isPaused
                                    ? 'Duraklatıldı'
                                    : isError
                                        ? 'Hata'
                                        : isCanceled
                                            ? 'İptal Edildi'
                                            : '${download.progressPercent} • 16x Hızlı',
                            style: TextStyle(
                              color: themeAccentColor,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (download.status == DownloadStatus.downloading) ...[
                IconButton(
                  icon: const Icon(Icons.pause_circle_outline,
                      color: Colors.orangeAccent, size: 24),
                  tooltip: 'İndirmeyi Durdur (Duraklat)',
                  onPressed: () {
                    ref.read(downloadControllerProvider.notifier).pauseDownload();
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.cancel_outlined,
                      color: Colors.redAccent, size: 24),
                  tooltip: 'İndirmeyi İptal Et ve Dosyayı Sil',
                  onPressed: () {
                    ref.read(downloadControllerProvider.notifier).cancelDownload();
                  },
                ),
              ] else if (download.status == DownloadStatus.paused) ...[
                IconButton(
                  icon: const Icon(Icons.play_circle_outline,
                      color: Colors.greenAccent, size: 24),
                  tooltip: 'İndirmeye Devam Et',
                  onPressed: () {
                    ref.read(downloadControllerProvider.notifier).resumeDownload();
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.cancel_outlined,
                      color: Colors.redAccent, size: 24),
                  tooltip: 'İptal Et ve Dosyayı Sil',
                  onPressed: () {
                    ref.read(downloadControllerProvider.notifier).cancelDownload();
                  },
                ),
              ] else if (download.status == DownloadStatus.completed) ...[
                TextButton.icon(
                  onPressed: () {
                    final target = ref.read(selectedModelProvider);
                    ref.read(selectedModelProvider.notifier).switchModel(target);
                  },
                  icon: const Icon(Icons.play_arrow_rounded,
                      color: Colors.greenAccent, size: 18),
                  label: const Text('Çalıştır',
                      style: TextStyle(
                          color: Colors.greenAccent,
                          fontSize: 12,
                          fontWeight: FontWeight.bold)),
                ),
                IconButton(
                  icon: Icon(Icons.close, color: secondaryTextColor, size: 20),
                  tooltip: 'Kapat',
                  onPressed: () {
                    ref.read(downloadControllerProvider.notifier).clear();
                  },
                ),
              ] else ...[
                IconButton(
                  icon: const Icon(Icons.refresh,
                      color: IdePalette.accentSoft, size: 22),
                  tooltip: 'Yeniden Başlat',
                  onPressed: () {
                    ref.read(downloadControllerProvider.notifier).resumeDownload();
                  },
                ),
                IconButton(
                  icon: Icon(Icons.close, color: secondaryTextColor, size: 20),
                  tooltip: 'Kapat',
                  onPressed: () {
                    ref.read(downloadControllerProvider.notifier).clear();
                  },
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: isDone
                  ? 1.0
                  : (download.totalBytes > 0
                      ? download.progress
                      : null),
              minHeight: 6,
              backgroundColor:
                  isLight ? Colors.grey.shade300 : Colors.white12,
              valueColor: AlwaysStoppedAnimation(themeAccentColor),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                download.sizeText,
                style: TextStyle(color: secondaryTextColor, fontSize: 11),
              ),
              Text(
                '${download.speedText} • ${download.etaText}',
                style: TextStyle(
                  color: themeAccentColor,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          if (isError && download.errorMessage != null && download.errorMessage!.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              download.errorMessage!,
              style: const TextStyle(color: Colors.redAccent, fontSize: 11),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}
