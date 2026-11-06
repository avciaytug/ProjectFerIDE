import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'dart:ui';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../state.dart';
import '../../../models/chat_session.dart';
import '../../../services/agent_engine.dart';
import '../../../models/chat_folder.dart';
import '../../../theme/ide_palette.dart';

class IdeSidebar extends ConsumerWidget {
  const IdeSidebar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final language = ref.watch(languageProvider);
    final langStr = language == AppLanguage.tr ? 'tr' : 'en';
    final loc = ref.watch(localizationProvider);

    return RepaintBoundary(
      child: Container(
        width: 320,
        decoration: BoxDecoration(
          border: Border(right: BorderSide(color: IdePalette.glassBorder)),
        ),
      child: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            color: IdePalette.glassBackground,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildHeader(context, ref),
                const Divider(height: 1, color: IdePalette.glassBorder),

                if (ref.watch(recordingProvider).isRecording) ...[
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Text(
                        loc['live_sessions']?[langStr] ?? 'CANLI OTURUMLAR',
                        style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: IdePalette.textTertiary)),
                  ),
                  _buildListItem(context, ref,
                      defaultIcon: Icons.graphic_eq,
                      defaultTitle:
                          loc['active_voice']?[langStr] ?? 'Aktif: Sesli Ajan',
                      isActive: true),
                  const SizedBox(height: 16),
                ],

                // Sohbet Geçmişi
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(loc['chat_history']?[langStr] ?? 'SOHBET GEÇMİŞİ',
                          style: const TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: IdePalette.textTertiary)),
                      InkWell(
                        onTap: () => _showCreateFolderDialog(context, ref),
                        child: const Icon(Icons.create_new_folder_outlined,
                            size: 14, color: IdePalette.textTertiary),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ref.watch(chatHistoryProvider).when(
                        data: (sessions) {
                          return ref.watch(foldersProvider).when(
                                data: (folders) {
                                  if (sessions.isEmpty && folders.isEmpty) {
                                    return const Center(
                                        child: Text('Henüz sohbet yok',
                                            style: TextStyle(
                                                color: IdePalette.textTertiary,
                                                fontSize: 12)));
                                  }
                                  // removed aggressive auto-select so New Chat can remain empty
                                  return _buildHistoryList(
                                      context, ref, sessions, folders);
                                },
                                loading: () => const Center(
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2)),
                                error: (err, stack) => const Center(
                                    child: Text('Hata',
                                        style: TextStyle(color: Colors.red))),
                              );
                        },
                        loading: () => const Center(
                            child: CircularProgressIndicator(strokeWidth: 2)),
                        error: (err, stack) => const Center(
                            child: Text('Hata oluştu',
                                style: TextStyle(color: Colors.red))),
                      ),
                ),

                const Divider(height: 1, color: IdePalette.glassBorder),
                const _SidebarUsageCard(),
              ],
            ),
          ),
        ),
      ),
    ));
  }

  Widget _buildHistoryList(BuildContext context, WidgetRef ref,
      List<ChatSession> sessions, List<ChatFolder> folders) {
    final query = ref.watch(chatSearchQueryProvider).toLowerCase();
    final activeSessionId = ref.watch(activeSessionProvider.select((s) => s?.id));

    // Filtreleme
    final filteredSessions = query.isEmpty
        ? sessions
        : sessions.where((s) {
            final matchesTitle = s.title.toLowerCase().contains(query);
            final matchesMessages = s.messages.any((m) {
              String txt = '';
              if (m.event is AgentStarted) txt = (m.event as AgentStarted).goal;
              else if (m.event is AgentMessage) txt = (m.event as AgentMessage).message;
              return txt.toLowerCase().contains(query);
            });
            return matchesTitle || matchesMessages;
          }).toList();

    // 1. Kök dizindeki klasörleri çiz (DragTarget)
    // 2. Kök dizindeki sohbetleri çiz
    final rootSessions =
        filteredSessions.where((s) => s.folderId == null).toList();

    return ListView(
      padding: EdgeInsets.zero,
      children: [
        // Kök Dizine Bırakma Alanı
        DragTarget<ChatSession>(
          onAcceptWithDetails: (details) {
            ref
                .read(activeSessionProvider.notifier)
                .updateSessionFolder(details.data.id, null);
          },
          builder: (context, candidateData, rejectedData) {
            return Container(
              height: 20,
              color: candidateData.isNotEmpty
                  ? Colors.white.withValues(alpha: 0.1)
                  : Colors.transparent,
              child: candidateData.isNotEmpty
                  ? const Center(
                      child: Icon(Icons.arrow_downward,
                          size: 12, color: IdePalette.accentSoft))
                  : null,
            );
          },
        ),

        ...folders.map((f) => _buildFolderItem(context, ref, f,
            filteredSessions.where((s) => s.folderId == f.id).toList(), activeSessionId)),
        ...rootSessions.map((s) {
          final isActive = activeSessionId == s.id;
          return _buildListItem(context, ref, session: s, isActive: isActive);
        }),
      ],
    );
  }

  Widget _buildFolderItem(BuildContext context, WidgetRef ref,
      ChatFolder folder, List<ChatSession> folderSessions, String? activeSessionId) {
    return DragTarget<ChatSession>(
      onAcceptWithDetails: (details) {
        if (details.data.folderId != folder.id) {
          ref
              .read(activeSessionProvider.notifier)
              .updateSessionFolder(details.data.id, folder.id);
        }
      },
      builder: (context, candidateData, rejectedData) {
        return GestureDetector(
          onSecondaryTapDown: (details) {
            _showFolderContextMenu(
                context, ref, details.globalPosition, folder);
          },
          child: Container(
            color: candidateData.isNotEmpty
                ? IdePalette.accentSoft.withValues(alpha: 0.2)
                : Colors.transparent,
            child: Theme(
              data:
                  Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                dense: true,
                leading: const Icon(Icons.folder_outlined,
                    size: 16, color: IdePalette.textSecondary),
                title: Text(folder.name,
                    style: const TextStyle(
                        fontSize: 13, color: IdePalette.textSecondary)),
                children: folderSessions.map((s) {
                  final isActive = activeSessionId == s.id;
                  return Padding(
                    padding: const EdgeInsets.only(left: 16.0),
                    child: _buildListItem(context, ref,
                        session: s, isActive: isActive),
                  );
                }).toList(),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildListItem(BuildContext context, WidgetRef ref,
      {String? defaultTitle,
      IconData? defaultIcon,
      ChatSession? session,
      bool isActive = false}) {
    final title = session?.title ?? defaultTitle ?? '';
    final icon = defaultIcon ?? Icons.chat_bubble_outline;

    Widget tile = Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: isActive
            ? Colors.white.withValues(alpha: 0.06)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        border: isActive
            ? const Border(
                left: BorderSide(color: IdePalette.accentSoft, width: 3))
            : null,
      ),
      child: ListTile(
        dense: true,
        leading: Icon(icon,
            size: 16,
            color: isActive ? IdePalette.accentSoft : IdePalette.textSecondary),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title,
                style: TextStyle(
                    fontSize: 13,
                    color: isActive
                        ? IdePalette.textPrimary
                        : IdePalette.textSecondary,
                    fontWeight: isActive ? FontWeight.bold : FontWeight.normal),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
            if (session != null)
              Builder(builder: (ctx) {
                final tokens = session.calculatedTokens;
                if (tokens == 0) return const SizedBox.shrink();
                final maxContextSize = ref.watch(maxContextSizeProvider);
                final maxContextStr = '${(maxContextSize / 1024).round()}K';
                final val = tokens >= 1000
                    ? '${(tokens / 1000).toStringAsFixed(1)}k'
                    : tokens.toString();
                return Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text('$val / $maxContextStr token',
                      style: const TextStyle(
                          fontSize: 10, color: IdePalette.textTertiary)),
                );
              }),
          ],
        ),
        trailing: session != null
            ? IconButton(
                icon: const Icon(Icons.delete_outline,
                    size: 14, color: IdePalette.textTertiary),
                onPressed: () {
                  ref
                      .read(activeSessionProvider.notifier)
                      .deleteSession(session.id);
                },
              )
            : null,
        onTap: () {
          if (session != null) {
            ref.read(activeSessionProvider.notifier).setSession(session);
          }
        },
      ),
    );

    if (session != null) {
      return Draggable<ChatSession>(
        data: session,
        feedback: Material(
          color: Colors.transparent,
          child: Opacity(
            opacity: 0.7,
            child: SizedBox(
              width: 200,
              child: tile,
            ),
          ),
        ),
        childWhenDragging: Opacity(
          opacity: 0.3,
          child: tile,
        ),
        child: tile,
      );
    }

    return tile;
  }

  void _showFolderContextMenu(
      BuildContext context, WidgetRef ref, Offset position, ChatFolder folder) {
    showMenu(
      context: context,
      position: RelativeRect.fromLTRB(
          position.dx, position.dy, position.dx + 1, position.dy + 1),
      color: IdePalette.glassBackground,
      items: [
        PopupMenuItem(
          value: 'delete',
          child: const Text('Sil',
              style: TextStyle(color: Colors.red, fontSize: 13)),
          onTap: () {
            ref.read(folderNotifierProvider.notifier).deleteFolder(folder.id);
          },
        ),
      ],
    );
  }

  void _showCreateFolderDialog(BuildContext context, WidgetRef ref) {
    final tc = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: IdePalette.backgroundBase,
        title: const Text('Yeni Klasör',
            style: TextStyle(color: IdePalette.textPrimary, fontSize: 16)),
        content: TextField(
          controller: tc,
          style: const TextStyle(color: IdePalette.textPrimary, fontSize: 14),
          decoration: InputDecoration(
            hintText: 'Klasör adı...',
            hintStyle: const TextStyle(color: IdePalette.textTertiary),
            enabledBorder: OutlineInputBorder(
                borderSide: BorderSide(color: IdePalette.glassBorder)),
            focusedBorder: const OutlineInputBorder(
                borderSide: BorderSide(color: IdePalette.accentSoft)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('İptal',
                style: TextStyle(color: IdePalette.textSecondary)),
          ),
          TextButton(
            onPressed: () {
              if (tc.text.trim().isNotEmpty) {
                ref
                    .read(folderNotifierProvider.notifier)
                    .createFolder(tc.text.trim());
              }
              Navigator.pop(ctx);
            },
            child: const Text('Oluştur',
                style: TextStyle(color: IdePalette.accentSoft)),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        children: [
          // Search Field
          _ChatSearchBar(),
          const SizedBox(height: 16),
          // New Chat Button
          Container(
            height: 40,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF3B82F6), Color(0xFF8B5CF6)],
              ),
              borderRadius: BorderRadius.circular(8),
              boxShadow: [
                BoxShadow(
                    color: const Color(0xFF3B82F6).withOpacity(0.3),
                    blurRadius: 12,
                    offset: const Offset(0, 4)),
              ],
            ),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () {
                  ref.read(activeSessionProvider.notifier).setSession(null);
                  ref.read(tokenCountProvider.notifier).state = 0;
                  ref.read(contextUsageProvider.notifier).state = 0.0;
                },
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.add, size: 18, color: Colors.white),
                    SizedBox(width: 8),
                    Text('Yeni Sohbet',
                        style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 13)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

}

class _SidebarUsageCard extends ConsumerWidget {
  const _SidebarUsageCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final contextUsage = ref.watch(contextUsageProvider);
    final tokenCount = ref.watch(tokenCountProvider);
    final language = ref.watch(languageProvider);
    final langStr = language == AppLanguage.tr ? 'tr' : 'en';
    final loc = ref.watch(localizationProvider);
    final maxContextSize = ref.watch(maxContextSizeProvider);

    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(loc['context_usage']?[langStr] ?? 'Kontekst Kullanımı',
              style: const TextStyle(
                  fontSize: 11,
                  color: IdePalette.textSecondary,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: contextUsage.clamp(0.0, 1.0),
              backgroundColor: IdePalette.glassBorder,
              valueColor:
                  const AlwaysStoppedAnimation<Color>(IdePalette.accentSoft),
              minHeight: 6,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                tokenCount >= 1000
                    ? '${(tokenCount / 1000).toStringAsFixed(1)}k / ${(maxContextSize / 1024).round()}K token'
                    : '$tokenCount / ${(maxContextSize / 1024).round()}K token',
                style: const TextStyle(
                    fontSize: 11, color: IdePalette.textTertiary),
              ),
              Text(
                contextUsage > 0 && (contextUsage * 100) < 0.1
                    ? '<0.1%'
                    : '${(contextUsage * 100).toStringAsFixed(1)}%',
                style: const TextStyle(
                    fontSize: 11, color: IdePalette.textTertiary),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ChatSearchBar extends ConsumerStatefulWidget {
  @override
  ConsumerState<_ChatSearchBar> createState() => _ChatSearchBarState();
}

class _ChatSearchBarState extends ConsumerState<_ChatSearchBar> {
  final FocusNode _focusNode = FocusNode();
  final TextEditingController _controller = TextEditingController();
  Timer? _debounceTimer;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleKey);
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    HardwareKeyboard.instance.removeHandler(_handleKey);
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  bool _handleKey(KeyEvent event) {
    if (event is KeyDownEvent) {
      if ((HardwareKeyboard.instance.isControlPressed ||
              HardwareKeyboard.instance.isMetaPressed ||
              HardwareKeyboard.instance.isAltPressed) &&
          event.logicalKey == LogicalKeyboardKey.keyK) {
        if (!_focusNode.hasFocus) {
          _focusNode.requestFocus();
          return true; // handled
        }
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: IdePalette.glassBorder),
      ),
      child: Row(
        children: [
          const Icon(Icons.search, size: 16, color: IdePalette.textSecondary),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _controller,
              focusNode: _focusNode,
              style: const TextStyle(fontSize: 13, color: Colors.white),
              decoration: const InputDecoration(
                hintText: 'Sohbet geçmişinde ara ...',
                hintStyle:
                    TextStyle(fontSize: 13, color: IdePalette.textTertiary),
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.zero,
              ),
              onChanged: (val) {
                _debounceTimer?.cancel();
                _debounceTimer = Timer(const Duration(milliseconds: 250), () {
                  ref.read(chatSearchQueryProvider.notifier).state = val;
                });
              },
            ),
          ),
          const SizedBox(width: 8),
          const Text('⌘K / Alt+K',
              style: TextStyle(fontSize: 10, color: IdePalette.textTertiary)),
        ],
      ),
    );
  }
}
