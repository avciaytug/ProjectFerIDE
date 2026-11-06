import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../services/mcp_service.dart';
import '../../theme/ide_palette.dart';
import '../settings/settings_provider.dart';

/// FerIDE MCP Ayarları Sekmesi (Model Context Protocol Settings)
class McpSettingsTabWidget extends ConsumerStatefulWidget {
  const McpSettingsTabWidget({super.key});

  @override
  ConsumerState<McpSettingsTabWidget> createState() => _McpSettingsTabWidgetState();
}

class _McpSettingsTabWidgetState extends ConsumerState<McpSettingsTabWidget> {
  late TextEditingController _searchController;
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final configPath = ref.read(settingsProvider).mcpConfigPath;
      McpService.instance.loadConfig(configPath);
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final textColor = isLight ? Colors.black87 : IdePalette.textPrimary;
    final secondaryTextColor = isLight ? Colors.black54 : IdePalette.textSecondary;
    final settings = ref.watch(settingsProvider);
    final allServers = McpService.instance.servers;

    final filtered = allServers.where((s) {
      if (_searchQuery.isEmpty) return true;
      final q = _searchQuery.toLowerCase();
      return s.name.toLowerCase().contains(q) ||
          s.description.toLowerCase().contains(q) ||
          s.command.toLowerCase().contains(q);
    }).toList();

    final activeCount = allServers.where((s) => s.isEnabled && settings.isMcpServerEnabled(s.name)).length;
    final disabledCount = allServers.length - activeCount;

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 1. Başlık ve Üst Kart
          _buildHeaderSection(context, settings, isLight, textColor, secondaryTextColor),
          const SizedBox(height: 16),

          // 2. Arama ve İstatistik Çubuğu
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchController,
                  style: TextStyle(color: textColor, fontSize: 13),
                  onChanged: (val) => setState(() => _searchQuery = val.trim()),
                  decoration: InputDecoration(
                    hintText: 'MCP sunucularında ara (örn: filesystem, fetch, github, sqlite)...',
                    hintStyle: TextStyle(color: secondaryTextColor, fontSize: 13),
                    prefixIcon: Icon(Icons.search, color: secondaryTextColor, size: 20),
                    suffixIcon: _searchQuery.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear, size: 18),
                            color: secondaryTextColor,
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _searchQuery = '');
                            },
                          )
                        : null,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                    filled: true,
                    fillColor: isLight
                        ? Colors.grey.withOpacity(0.1)
                        : Colors.black.withOpacity(0.2),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: isLight
                      ? Colors.grey.withOpacity(0.1)
                      : Colors.black.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                      color: isLight ? Colors.black12 : IdePalette.glassBorder),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.dns_rounded, size: 16, color: IdePalette.accentSoft),
                    const SizedBox(width: 8),
                    Text(
                      '${allServers.length} Sunucu ($activeCount Aktif, $disabledCount Kapalı)',
                      style: TextStyle(
                          color: textColor,
                          fontSize: 12,
                          fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // 3. Sunucu Listesi
          Expanded(
            child: filtered.isEmpty
                ? _buildEmptyState(secondaryTextColor)
                : ListView.separated(
                    itemCount: filtered.length,
                    separatorBuilder: (context, i) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final server = filtered[index];
                      final isEnabled = server.isEnabled && settings.isMcpServerEnabled(server.name);
                      return _buildServerCard(context, server, isEnabled, isLight, textColor, secondaryTextColor);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeaderSection(
    BuildContext context,
    SettingsState settings,
    bool isLight,
    Color textColor,
    Color secondaryTextColor,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                const Icon(Icons.hub_rounded, size: 20, color: IdePalette.accentSoft),
                const SizedBox(width: 8),
                Text(
                  'MCP (Model Context Protocol) Sunucuları',
                  style: TextStyle(color: textColor, fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: () => _showPresetsDialog(context, isLight, textColor, secondaryTextColor),
                  icon: const Icon(Icons.auto_awesome, size: 15),
                  label: const Text('Hazır Şablonlar'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: IdePalette.accentSoft,
                    side: const BorderSide(color: IdePalette.accentSoft),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: () => _showRawJsonDialog(context, isLight, textColor),
                  icon: const Icon(Icons.code_rounded, size: 15),
                  label: const Text('JSON Düzenle'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: secondaryTextColor,
                    side: BorderSide(color: secondaryTextColor.withOpacity(0.5)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: () => _showAddEditServerDialog(context, null, isLight, textColor, secondaryTextColor),
                  icon: const Icon(Icons.add_rounded, size: 16),
                  label: const Text('Yeni Sunucu Ekle'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: IdePalette.accentSoft,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 12),
        // Yapılandırma Kartı
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: isLight
                ? Colors.grey.withOpacity(0.05)
                : Colors.white.withOpacity(0.03),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: isLight ? Colors.black12 : IdePalette.glassBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('MCP Yapılandırma Dosyası (mcp_config.json)',
                            style: TextStyle(
                                color: textColor,
                                fontWeight: FontWeight.bold,
                                fontSize: 13)),
                        const SizedBox(height: 4),
                        Text(
                          'Claude Desktop ve Cursor standartlarıyla tam uyumlu JSON dosya yolu.',
                          style: TextStyle(color: secondaryTextColor, fontSize: 12),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                decoration: BoxDecoration(
                                  color: isLight
                                      ? Colors.grey.withOpacity(0.1)
                                      : Colors.black.withOpacity(0.2),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                      color: isLight ? Colors.black12 : IdePalette.glassBorder),
                                ),
                                child: Text(
                                  settings.mcpConfigPath,
                                  style: TextStyle(color: textColor, fontSize: 12, fontFamily: 'monospace'),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            ElevatedButton.icon(
                              onPressed: () async {
                                final file = await FilePicker.pickFile();
                                if (file != null && file.path != null) {
                                  final p = file.path!;
                                  ref.read(settingsProvider.notifier).setMcpConfigPath(p);
                                  McpService.instance.loadConfig(p);
                                  setState(() {});
                                }
                              },
                              icon: const Icon(Icons.file_open_rounded, size: 14),
                              label: const Text('Dosya Seç'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: IdePalette.accentSoft.withOpacity(0.2),
                                foregroundColor: IdePalette.accentSoft,
                                elevation: 0,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 24),
                  // Sağ Taraf: Ana MCP Şalteri
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            settings.mcpEnabled ? 'MCP AKTİF' : 'MCP KAPALI',
                            style: TextStyle(
                              color: settings.mcpEnabled ? Colors.greenAccent : Colors.grey,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Switch(
                            value: settings.mcpEnabled,
                            activeColor: IdePalette.accentSoft,
                            onChanged: (val) {
                              ref.read(settingsProvider.notifier).toggleMcp(val);
                              setState(() {});
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('Araçları Otomatik Keşfet',
                              style: TextStyle(color: secondaryTextColor, fontSize: 11)),
                          const SizedBox(width: 4),
                          Checkbox(
                            value: settings.mcpAutoDiscover,
                            activeColor: IdePalette.accentSoft,
                            onChanged: (val) {
                              ref.read(settingsProvider.notifier).toggleMcpAutoDiscover(val ?? true);
                              setState(() {});
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyState(Color secondaryTextColor) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.hub_outlined, size: 52, color: secondaryTextColor.withOpacity(0.5)),
          const SizedBox(height: 12),
          Text(
            _searchQuery.isEmpty
                ? 'Henüz yüklü MCP sunucusu bulunamadı.\nYukarıdaki "Hazır Şablonlar" veya "Yeni Sunucu Ekle" butonlarını kullanabilirsiniz.'
                : '"$_searchQuery" aramasına uygun MCP sunucusu bulunamadı.',
            textAlign: TextAlign.center,
            style: TextStyle(color: secondaryTextColor, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _buildServerCard(
    BuildContext context,
    McpServerConfig server,
    bool isEnabled,
    bool isLight,
    Color textColor,
    Color secondaryTextColor,
  ) {
    IconData iconData = Icons.terminal_rounded;
    if (server.transport == 'sse' || server.transport == 'http') {
      iconData = Icons.cloud_sync_rounded;
    } else if (server.name.contains('sqlite') || server.name.contains('postgres') || server.name.contains('db')) {
      iconData = Icons.storage_rounded;
    } else if (server.name.contains('github') || server.name.contains('git')) {
      iconData = Icons.code_rounded;
    } else if (server.name.contains('puppeteer') || server.name.contains('browser')) {
      iconData = Icons.web_rounded;
    } else if (server.name.contains('memory')) {
      iconData = Icons.psychology_rounded;
    } else if (server.name.contains('file')) {
      iconData = Icons.folder_copy_rounded;
    }

    final commandPreview = server.transport == 'sse' || server.transport == 'http'
        ? server.url
        : '${server.command} ${server.args.join(" ")}';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: isLight
            ? (isEnabled ? Colors.white : Colors.grey.withOpacity(0.08))
            : (isEnabled ? Colors.white.withOpacity(0.04) : Colors.black.withOpacity(0.2)),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isEnabled
              ? IdePalette.accentSoft.withOpacity(isLight ? 0.3 : 0.4)
              : (isLight ? Colors.black12 : IdePalette.glassBorder.withOpacity(0.3)),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Sol İkon
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: isEnabled
                  ? IdePalette.accentSoft.withOpacity(0.15)
                  : Colors.grey.withOpacity(0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(
              iconData,
              size: 20,
              color: isEnabled ? IdePalette.accentSoft : Colors.grey,
            ),
          ),
          const SizedBox(width: 14),

          // Orta Alan (Bilgiler)
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      server.name,
                      style: TextStyle(
                        color: isEnabled ? textColor : secondaryTextColor,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.3,
                      ),
                    ),
                    const SizedBox(width: 8),
                    _buildChip(
                      isEnabled ? 'AKTİF' : 'KAPALI',
                      isEnabled ? Colors.greenAccent : Colors.grey,
                      isLight,
                    ),
                    const SizedBox(width: 6),
                    _buildChip(
                      server.transport.toUpperCase(),
                      IdePalette.accentSoft,
                      isLight,
                    ),
                    if (server.tools.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      _buildChip(
                        '${server.tools.length} Araç',
                        Colors.orangeAccent,
                        isLight,
                      ),
                    ],
                    if (server.status.isNotEmpty && server.status != 'Hazır' && server.status != 'Devre Dışı') ...[
                      const SizedBox(width: 6),
                      _buildChip(
                        server.status,
                        server.status.contains('Başarılı') || server.status.contains('Hazır')
                            ? Colors.greenAccent
                            : Colors.amberAccent,
                        isLight,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  server.description.isNotEmpty
                      ? server.description
                      : 'MCP standart eklenti sunucusu.',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: secondaryTextColor, fontSize: 12),
                ),
                const SizedBox(height: 6),
                // Komut / URL Önizleme
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: isLight ? Colors.black.withOpacity(0.04) : Colors.black.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: isLight ? Colors.black12 : Colors.white10,
                    ),
                  ),
                  child: Text(
                    commandPreview,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: isEnabled
                          ? (isLight ? Colors.black87 : Colors.white70)
                          : secondaryTextColor.withOpacity(0.7),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),

          // Butonlar
          // 1. Test Et
          OutlinedButton.icon(
            onPressed: () async {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('${server.name} bağlantısı test ediliyor...'),
                  duration: const Duration(seconds: 1),
                ),
              );
              final res = await McpService.instance.testServer(server);
              if (mounted) {
                setState(() {});
                final msg = res['message']?.toString() ?? '';
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('[${server.name}] $msg'),
                    backgroundColor: res['success'] == true ? Colors.green : Colors.orange,
                    duration: const Duration(seconds: 3),
                  ),
                );
              }
            },
            icon: const Icon(Icons.speed_rounded, size: 14),
            label: const Text('Test Et', style: TextStyle(fontSize: 11)),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              foregroundColor: IdePalette.accentSoft,
              side: BorderSide(color: IdePalette.accentSoft.withOpacity(0.5)),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
            ),
          ),
          const SizedBox(width: 6),

          // 2. Düzenle
          IconButton(
            icon: const Icon(Icons.edit_note_rounded, size: 20),
            color: secondaryTextColor,
            tooltip: 'Yapılandırmayı Düzenle',
            onPressed: () => _showAddEditServerDialog(context, server, isLight, textColor, secondaryTextColor),
          ),

          // 3. Aç/Kapa Şalteri
          Switch(
            value: isEnabled,
            activeColor: IdePalette.accentSoft,
            onChanged: (val) {
              ref.read(settingsProvider.notifier).toggleMcpServer(server.name, val);
              setState(() {});
            },
          ),
          const SizedBox(width: 4),

          // 4. Sil
          IconButton(
            icon: const Icon(Icons.delete_outline_rounded, color: Colors.redAccent, size: 20),
            tooltip: 'Sunucuyu Sil',
            onPressed: () => _confirmDeleteServer(context, server, isLight),
          ),
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
      child: Text(
        label,
        style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.bold),
      ),
    );
  }

  void _confirmDeleteServer(BuildContext context, McpServerConfig server, bool isLight) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: isLight ? Colors.white : const Color(0xFF1E1E2E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.redAccent, size: 28),
            SizedBox(width: 10),
            Text('Sunucuyu Sil', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          ],
        ),
        content: Text(
          '"${server.name}" MCP sunucusunu silmek istediğinizden emin misiniz?\n\nBu sunucu mcp_config.json dosyasından kaldırılacaktır.',
          style: TextStyle(color: isLight ? Colors.black87 : Colors.white70, fontSize: 13),
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
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () {
              Navigator.pop(ctx);
              McpService.instance.deleteServer(server.name);
              setState(() {});
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('"${server.name}" MCP sunucusu silindi.'),
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

  void _showAddEditServerDialog(
    BuildContext context,
    McpServerConfig? existing,
    bool isLight,
    Color textColor,
    Color secondaryTextColor,
  ) {
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final descCtrl = TextEditingController(text: existing?.description ?? '');
    String transport = existing?.transport ?? 'stdio';
    final cmdCtrl = TextEditingController(text: existing?.command ?? 'npx');
    final argsCtrl = TextEditingController(text: existing?.args.join(' ') ?? '');
    final urlCtrl = TextEditingController(text: existing?.url ?? '');
    final envCtrl = TextEditingController(
      text: existing?.env.entries.map((e) => '${e.key}=${e.value}').join('\n') ?? '',
    );

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: isLight ? Colors.white : const Color(0xFF1E1E2E),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: [
              Icon(
                existing == null ? Icons.add_circle_outline_rounded : Icons.edit_note_rounded,
                color: IdePalette.accentSoft,
                size: 26,
              ),
              const SizedBox(width: 10),
              Text(
                existing == null ? 'Yeni MCP Sunucusu Ekle' : 'MCP Sunucusunu Düzenle',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          content: SizedBox(
            width: 550,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: nameCtrl,
                    enabled: existing == null,
                    decoration: InputDecoration(
                      labelText: 'Sunucu Kimliği (Name / ID)',
                      hintText: 'örn: filesystem, fetch, my_sqlite',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: descCtrl,
                    decoration: InputDecoration(
                      labelText: 'Açıklama',
                      hintText: 'Sunucunun sağladığı araçlar veya görevler',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    value: transport,
                    decoration: InputDecoration(
                      labelText: 'İletişim Türü (Transport)',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    items: const [
                      DropdownMenuItem(value: 'stdio', child: Text('stdio (Komut / Konsol Çıktısı)')),
                      DropdownMenuItem(value: 'sse', child: Text('sse (Server-Sent Events / HTTP)')),
                      DropdownMenuItem(value: 'http', child: Text('http (Streamable HTTP)')),
                    ],
                    onChanged: (val) {
                      if (val != null) setDialogState(() => transport = val);
                    },
                  ),
                  const SizedBox(height: 12),
                  if (transport == 'stdio') ...[
                    TextField(
                      controller: cmdCtrl,
                      decoration: InputDecoration(
                        labelText: 'Çalıştırılacak Komut (Command)',
                        hintText: 'örn: npx, uvx, node, python3, docker',
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: argsCtrl,
                      decoration: InputDecoration(
                        labelText: 'Argümanlar (Boşlukla ayrılmış)',
                        hintText: 'örn: -y @modelcontextprotocol/server-filesystem \$HOME',
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                    ),
                  ] else ...[
                    TextField(
                      controller: urlCtrl,
                      decoration: InputDecoration(
                        labelText: 'Sunucu URL Adresi',
                        hintText: 'örn: http://localhost:8000/sse',
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  TextField(
                    controller: envCtrl,
                    maxLines: 2,
                    decoration: InputDecoration(
                      labelText: 'Çevre Değişkenleri (KEY=VALUE, her satıra bir tane)',
                      hintText: 'GITHUB_TOKEN=ghp_xxx\nDATABASE_URL=postgres://...',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('İptal', style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: IdePalette.accentSoft,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: () {
                final name = nameCtrl.text.trim();
                if (name.isEmpty) return;

                final envMap = <String, String>{};
                for (final line in envCtrl.text.split('\n')) {
                  final trimmed = line.trim();
                  if (trimmed.contains('=')) {
                    final parts = trimmed.split('=');
                    envMap[parts[0].trim()] = parts.sublist(1).join('=').trim();
                  }
                }

                final argsList = argsCtrl.text
                    .split(' ')
                    .map((e) => e.trim())
                    .where((e) => e.isNotEmpty)
                    .toList();

                final newServer = McpServerConfig(
                  name: name,
                  description: descCtrl.text.trim(),
                  transport: transport,
                  command: cmdCtrl.text.trim(),
                  args: argsList,
                  env: envMap,
                  url: urlCtrl.text.trim(),
                  isEnabled: existing?.isEnabled ?? true,
                  status: existing?.status ?? 'Hazır',
                  tools: existing?.tools ?? [],
                );

                McpService.instance.addOrUpdateServer(newServer);
                Navigator.pop(ctx);
                setState(() {});
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('"$name" MCP sunucusu kaydedildi.'),
                    backgroundColor: IdePalette.accentSoft,
                  ),
                );
              },
              child: const Text('Kaydet'),
            ),
          ],
        ),
      ),
    );
  }

  void _showPresetsDialog(BuildContext context, bool isLight, Color textColor, Color secondaryTextColor) {
    final presets = McpService.instance.getRecommendedPresets();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: isLight ? Colors.white : const Color(0xFF1E1E2E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.auto_awesome, color: IdePalette.accentSoft, size: 24),
            SizedBox(width: 10),
            Text('Hazır MCP Sunucu Şablonları', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          ],
        ),
        content: SizedBox(
          width: 600,
          height: 480,
          child: ListView.separated(
            itemCount: presets.length,
            separatorBuilder: (context, i) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final preset = presets[i];
              final isAlreadyAdded = McpService.instance.servers.any((s) => s.name == preset.name);
              return ListTile(
                leading: CircleAvatar(
                  backgroundColor: IdePalette.accentSoft.withOpacity(0.15),
                  child: const Icon(Icons.hub, color: IdePalette.accentSoft, size: 20),
                ),
                title: Text(preset.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                subtitle: Text(preset.description, style: TextStyle(color: secondaryTextColor, fontSize: 12)),
                trailing: isAlreadyAdded
                    ? Chip(
                        label: const Text('Yüklü', style: TextStyle(fontSize: 11, color: Colors.greenAccent)),
                        backgroundColor: Colors.greenAccent.withOpacity(0.1),
                      )
                    : ElevatedButton.icon(
                        icon: const Icon(Icons.add, size: 14),
                        label: const Text('Ekle'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: IdePalette.accentSoft,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        ),
                        onPressed: () {
                          McpService.instance.addOrUpdateServer(preset);
                          Navigator.pop(ctx);
                          setState(() {});
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('"${preset.name}" MCP sunucusu eklendi.'),
                              backgroundColor: IdePalette.accentSoft,
                            ),
                          );
                        },
                      ),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Kapat'),
          ),
        ],
      ),
    );
  }

  void _showRawJsonDialog(BuildContext context, bool isLight, Color textColor) {
    final file = File(McpService.instance.configPath);
    String currentContent = '';
    if (file.existsSync()) {
      currentContent = file.readAsStringSync();
    } else {
      currentContent = '{\n  "mcpServers": {}\n}';
    }
    final textCtrl = TextEditingController(text: currentContent);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: isLight ? Colors.white : const Color(0xFF1E1E2E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.code_rounded, color: IdePalette.accentSoft, size: 24),
            SizedBox(width: 10),
            Text('mcp_config.json Düzenle', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          ],
        ),
        content: SizedBox(
          width: 650,
          height: 500,
          child: Column(
            children: [
              Expanded(
                child: TextField(
                  controller: textCtrl,
                  maxLines: null,
                  expands: true,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  decoration: InputDecoration(
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                    filled: true,
                    fillColor: isLight ? Colors.grey.withOpacity(0.05) : Colors.black.withOpacity(0.3),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('İptal', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: IdePalette.accentSoft,
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              try {
                final parsed = jsonDecode(textCtrl.text);
                if (parsed is! Map) throw 'Geçersiz JSON formatı';
                file.writeAsStringSync(textCtrl.text);
                McpService.instance.loadConfig();
                Navigator.pop(ctx);
                setState(() {});
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('mcp_config.json başarıyla kaydedildi.'),
                    backgroundColor: Colors.green,
                  ),
                );
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('JSON Hatası: $e'),
                    backgroundColor: Colors.redAccent,
                  ),
                );
              }
            },
            child: const Text('Kaydet'),
          ),
        ],
      ),
    );
  }
}
