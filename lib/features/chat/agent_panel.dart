import 'package:path/path.dart' as p;
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:pasteboard/pasteboard.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../services/agent_engine.dart';
import '../../services/claude_tools.dart';
import '../../services/voice_manager.dart';
import '../../services/file_service.dart';
import 'agent_activity_group.dart';
import '../../../theme/ide_palette.dart';
import 'state.dart';
import '../../models/chat_session.dart';

class AgentPanel extends ConsumerStatefulWidget {
  const AgentPanel({super.key});

  @override
  ConsumerState<AgentPanel> createState() => _AgentPanelState();
}

abstract class _ChatDisplayItem {}

class _SingleMessageItem extends _ChatDisplayItem {
  final ChatMessage message;
  _SingleMessageItem(this.message);
}

class _ActivityGroupItem extends _ChatDisplayItem {
  final List<ChatMessage> messages;
  final bool isLatest;
  _ActivityGroupItem(this.messages, {this.isLatest = false});
}

class _AgentPanelState extends ConsumerState<AgentPanel> {
  final TextEditingController _promptController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _focusNode = FocusNode();
  final List<AttachedFile> _attachedFiles = [];
  final Map<String, Uint8List> _imageCache = {};
  bool _isDragging = false;
  bool _isExtracting = false;

  Widget _buildImageAttachment(String imageRef) {
    if (imageRef.startsWith('file://')) {
      final filePath = imageRef.substring(7);
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.file(
          File(filePath),
          width: 120,
          height: 120,
          fit: BoxFit.cover,
          cacheWidth: 240,
          errorBuilder: (_, __, ___) => const Icon(Icons.broken_image, size: 40, color: Colors.grey),
        ),
      );
    } else if (imageRef.startsWith('/') && File(imageRef).existsSync()) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.file(
          File(imageRef),
          width: 120,
          height: 120,
          fit: BoxFit.cover,
          cacheWidth: 240,
          errorBuilder: (_, __, ___) => const Icon(Icons.broken_image, size: 40, color: Colors.grey),
        ),
      );
    } else {
      final cleanB64 = imageRef.contains('base64,') ? imageRef.split('base64,').last : imageRef;
      final cachedBytes = _imageCache.putIfAbsent(cleanB64, () {
        try {
          return base64Decode(cleanB64);
        } catch (_) {
          return Uint8List(0);
        }
      });
      if (cachedBytes.isEmpty) {
        return const Icon(Icons.broken_image, size: 40, color: Colors.grey);
      }
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.memory(
          cachedBytes,
          width: 120,
          height: 120,
          fit: BoxFit.cover,
          cacheWidth: 240,
        ),
      );
    }
  }

  Future<void> _pickFiles() async {
    try {
      final files = await FilePicker.pickFiles();

      if (files.isNotEmpty) {
        for (var file in files) {
          if (file.path != null) {
            final attached = await FileService.processFile(file.path!);
            if (attached != null) {
              setState(() {
                _attachedFiles.add(attached);
              });
            }
          }
        }
      }
    } catch (e) {
      print("Dosya seçme hatası: $e");
    }
  }

  Future<bool> _handleClipboardPaste() async {
    try {
      final imageBytes = await FileService.getClipboardImage();
      if (imageBytes != null && imageBytes.isNotEmpty) {
        final attached = await FileService.createFromImageBytes(imageBytes);
        if (mounted) {
          setState(() {
            _attachedFiles.add(attached);
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              backgroundColor: const Color(0xFF1E1E2E),
              content: const Row(
                children: [
                  Icon(Icons.image_rounded, color: IdePalette.accentSoft, size: 20),
                  SizedBox(width: 10),
                  Text(
                    '📷 Ekran görüntüsü panodan eklendi!',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              duration: const Duration(seconds: 2),
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
          );
        }
        return true;
      }
    } catch (e) {
      print('Clipboard paste error: $e');
    }
    return false;
  }

  Future<void> _handlePasteUnified({bool focusInput = true}) async {
    // 1. Önce panoda görsel (ekran görüntüsü / resim) var mı kontrol et
    final isImagePasted = await _handleClipboardPaste();
    if (isImagePasted) {
      if (focusInput && !_focusNode.hasFocus) {
        _focusNode.requestFocus();
      }
      return;
    }

    // 2. Panoda kopyalanmış dosya yolu (ör. dosya yöneticisinden kopyalanan resim/belge) var mı kontrol et
    try {
      final files = await Pasteboard.files();
      if (files.isNotEmpty) {
        bool addedAny = false;
        for (final filePath in files) {
          final attached = await FileService.processFile(filePath);
          if (attached != null) {
            if (mounted) {
              setState(() {
                _attachedFiles.add(attached);
              });
              addedAny = true;
            }
          }
        }
        if (addedAny && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              backgroundColor: const Color(0xFF1E1E2E),
              content: Row(
                children: [
                  const Icon(Icons.attach_file, color: IdePalette.accentSoft, size: 20),
                  const SizedBox(width: 10),
                  Text(
                    '📎 ${files.length} dosya panodan eklendi!',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              duration: const Duration(seconds: 2),
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
          );
          if (focusInput && !_focusNode.hasFocus) {
            _focusNode.requestFocus();
          }
          return;
        }
      }
    } catch (_) {}

    // 3. Panodaki metin bir dosya yolu ise doğrudan ekle, değilse metin olarak yapıştır
    try {
      final clipData = await Clipboard.getData(Clipboard.kTextPlain);
      if (clipData?.text != null && clipData!.text!.isNotEmpty) {
        final text = clipData.text!.trim();
        final rawPath = text.startsWith('file://') ? text.substring(7) : text;
        if ((rawPath.startsWith('/') || rawPath.startsWith('~')) && File(rawPath).existsSync()) {
          final attached = await FileService.processFile(rawPath);
          if (attached != null && mounted) {
            setState(() {
              _attachedFiles.add(attached);
            });
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                backgroundColor: const Color(0xFF1E1E2E),
                content: Row(
                  children: [
                    const Icon(Icons.attach_file, color: IdePalette.accentSoft, size: 20),
                    const SizedBox(width: 10),
                    Text(
                      '📎 Dosya eklendi: ${p.basename(rawPath)}',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                duration: const Duration(seconds: 2),
              ),
            );
            if (focusInput && !_focusNode.hasFocus) {
              _focusNode.requestFocus();
            }
            return;
          }
        }

        final fullText = clipData.text!;
        final value = _promptController.value;
        final start = value.selection.isValid ? value.selection.start : value.text.length;
        final end = value.selection.isValid ? value.selection.end : value.text.length;
        final newText = value.text.replaceRange(start, end, fullText);
        _promptController.value = TextEditingValue(
          text: newText,
          selection: TextSelection.collapsed(offset: start + fullText.length),
        );
        if (focusInput && !_focusNode.hasFocus) {
          _focusNode.requestFocus();
        }
      }
    } catch (_) {}
  }

  List<_ChatDisplayItem> _groupMessages(List<ChatMessage> rawMessages) {
    if (rawMessages.isEmpty) return const [];
    final List<_ChatDisplayItem> result = [];
    List<ChatMessage> currentGroup = [];

    void flushGroup({bool isLatest = false}) {
      if (currentGroup.isNotEmpty) {
        result.add(_ActivityGroupItem(List.unmodifiable(currentGroup), isLatest: isLatest));
        currentGroup = [];
      }
    }

    for (int i = 0; i < rawMessages.length; i++) {
      final msg = rawMessages[i];
      final event = msg.event;
      final isActivity = event is ToolInvoked ||
          event is ToolCompleted ||
          event is StepStarted ||
          event is ReasoningMessage;

      if (isActivity) {
        currentGroup.add(msg);
      } else {
        flushGroup(isLatest: false);
        result.add(_SingleMessageItem(msg));
      }
    }
    flushGroup(isLatest: true);
    return result;
  }

  @override
  Widget build(BuildContext context) {
    // 1. Olay dinleyici: Yeni olay akışını dinle (kayıt motor tarafından yönetilir)
    final sessionId = ref.watch(activeSessionProvider.select((s) => s?.id));
    ref.listen<AsyncValue<AgentEvent>>(
      agentEventsProvider(sessionId),
      (previous, next) {},
    );

    // 2. Aktif oturumu al
    final activeSession = ref.watch(activeSessionProvider);
    final isRunning = ref.watch(agentIsRunningProvider);
    final displayItems = _groupMessages(activeSession?.messages ?? []).reversed.toList();

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyV, control: true): () {
          _handlePasteUnified(focusInput: true);
        },
        const SingleActivator(LogicalKeyboardKey.keyV, meta: true): () {
          _handlePasteUnified(focusInput: true);
        },
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (isRunning) {
            final sessionId = ref.read(activeSessionProvider)?.id;
            ref.read(agentEngineProvider(sessionId)).cancel();
          }
        },
      },
      child: DropTarget(
        onDragEntered: (details) => setState(() => _isDragging = true),
      onDragExited: (details) => setState(() => _isDragging = false),
      onDragDone: (details) async {
        setState(() => _isDragging = false);
        for (final xfile in details.files) {
          final attached = await FileService.processFile(xfile.path);
          if (attached != null) {
            setState(() {
              _attachedFiles.add(attached);
            });
          }
        }
      },
      child: Stack(
        children: [
          Column(
            children: [
              if (ref.watch(activeTodosProvider).isNotEmpty)
                _buildLiveTodoBar(ref.watch(activeTodosProvider)),
              Expanded(
                child: displayItems.isEmpty
                    ? _buildEmptyState()
                    : SelectionArea(
                        child: ListView.builder(
                          controller: _scrollController,
                          reverse: true,
                          padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
                          itemCount: displayItems.length,
                          itemBuilder: (context, index) {
                            final item = displayItems[index];
                            if (item is _ActivityGroupItem) {
                              return AgentActivityGroup(
                                messages: item.messages,
                                isLive: isRunning && item.isLatest,
                              );
                            } else if (item is _SingleMessageItem) {
                              return _buildEventBubble(item.message);
                            }
                            return const SizedBox.shrink();
                          },
                        ),
                      ),
              ),
              _buildChatInputBar(),
            ],
          ),
          if (_isDragging)
            Positioned.fill(
              child: Container(
                margin: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E2E).withOpacity(0.92),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: IdePalette.accentSoft, width: 2),
                  boxShadow: const [
                    BoxShadow(
                      color: IdePalette.accentGlow,
                      blurRadius: 30,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: IdePalette.accentSoft.withOpacity(0.15),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.cloud_upload_outlined,
                          size: 56,
                          color: IdePalette.accentSoft,
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'Dosyaları FerIDE\'ye Bırakın',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Ofis (.docx, .xlsx, .pptx) · PDF · AutoCAD (.dwg, .dxf) · Müzik/Ses (.mp3, .wav, .flac) · Resim',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.7),
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    ));
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: IdePalette.accentGlow,
            ),
            child: const Icon(Icons.auto_awesome, size: 48, color: IdePalette.accentSoft),
          ),
          const SizedBox(height: 24),
          const Text('Nasıl yardımcı olabilirim?', style: TextStyle(fontSize: 24, color: IdePalette.textPrimary, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          const Text(
            'Kod yazabilir; Ofis, PDF, Resim, Müzik/Ses ve AutoCAD (.dwg/.dxf) dosyalarını anlayıp düzenleyebilirim.',
            style: TextStyle(color: IdePalette.textSecondary),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildEventBubble(ChatMessage message) {
    final event = message.event;
    bool isUser = event is AgentStarted;
    
    // Terminal Log Bloğu
    if (event is ToolInvoked || event is StepStarted || event is ToolCompleted || event is ReasoningMessage) {
      return AgentActivityGroup(messages: [message], isLive: false);
    }

    String text = '';
    if (event is AgentStarted) {
      text = event.goal;
    } else if (event is AgentMessage) {
      text = event.message;
    } else if (event is AgentFailed) {
      text = 'Hata: ${event.error}';
    } else {
      return const SizedBox.shrink();
    }

    // Kullanıcı mesajında ekli belge/dosya içeriği varsa şık bir badge ve soru göster
    bool hasAttachedDocuments = isUser && text.contains('[EK DOSYA VE BELGELER]:');
    String displayUserText = text;
    if (hasAttachedDocuments) {
      final parts = text.split('[KULLANICI SORUSU / TALİMATI]:');
      if (parts.length > 1) {
        displayUserText = parts[1].trim();
      } else {
        final altParts = text.split('[KULLANICI TALİMATI]:');
        if (altParts.length > 1) {
          displayUserText = altParts[1].trim();
        } else {
          displayUserText = 'Ekli dosya/belgeler incelendi.';
        }
      }
    }

    return RepaintBoundary(
      key: ValueKey(message.id),
      child: Align(
        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: Column(
          crossAxisAlignment: isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Container(
              margin: const EdgeInsets.only(bottom: 4),
              constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * (isUser ? 0.65 : 0.82)),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              decoration: BoxDecoration(
                color: isUser 
                    ? IdePalette.accentSoft.withOpacity(0.1) 
                    : (event is AgentFailed && event.error.contains('Maksimum adım'))
                        ? Colors.amber.withOpacity(0.08)
                        : Colors.transparent,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: isUser 
                      ? IdePalette.accentSoft.withOpacity(0.3) 
                      : (event is AgentFailed && event.error.contains('Maksimum adım'))
                          ? Colors.amber.withOpacity(0.4)
                          : IdePalette.glassBorder.withOpacity(0.5),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (hasAttachedDocuments)
                    Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: IdePalette.accentSoft.withOpacity(0.18),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: IdePalette.accentSoft.withOpacity(0.4)),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.attachment_rounded, size: 16, color: IdePalette.accentSoft),
                          SizedBox(width: 6),
                          Text(
                            'Ekli Dosyalar / Belgeler İncelendi',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: IdePalette.accentSoft,
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (event is AgentStarted && event.base64Images != null && event.base64Images!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8.0),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: event.base64Images!.map((imgRef) => _buildImageAttachment(imgRef)).toList(),
                      ),
                    ),
                  _buildMessageBody(context, displayUserText, isUser),
                  if (event is AgentFailed && (event.error.contains('Maksimum adım') || event.error.contains('salt okuma') || event.error.contains('tekrarlandı') || event.error.contains('Durduruldu'))) ...[
                    const SizedBox(height: 12),
                    ElevatedButton.icon(
                      onPressed: ref.watch(agentIsRunningProvider)
                          ? null
                          : () => _sendPrompt('Önceki analize ve işleme kaldığın yerden devam et.'),
                      icon: const Icon(Icons.play_arrow_rounded, size: 18),
                      label: const Text(
                        'İşleme Kaldığı Yerden Devam Et',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: IdePalette.accentSoft,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        elevation: 2,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.only(
                left: isUser ? 0 : 8,
                right: isUser ? 8 : 0,
                bottom: 8,
              ),
              child: Text(
                '${message.timestamp.hour.toString().padLeft(2, '0')}:${message.timestamp.minute.toString().padLeft(2, '0')}',
                style: TextStyle(
                  color: IdePalette.textSecondary.withOpacity(0.6),
                  fontSize: 10,
                ),
              ),
            ),
            if (!isUser && event is AgentMessage && event.inputTokens != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 16, left: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildTelemetryChip(Icons.input, '${event.inputTokens} in'),
                    const SizedBox(width: 8),
                    _buildTelemetryChip(Icons.output, '${event.outputTokens} out'),
                    if (event.tokensPerSecond != null) ...[
                      const SizedBox(width: 8),
                      _buildTelemetryChip(Icons.speed, '${event.tokensPerSecond!.toStringAsFixed(1)} t/s'),
                    ],
                  ],
                ),
              )
            else
              const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Widget _buildTelemetryChip(IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.light ? Colors.black.withValues(alpha: 0.05) : Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Theme.of(context).brightness == Brightness.light ? Colors.black.withValues(alpha: 0.1) : Colors.white.withValues(alpha: 0.1)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10, color: Theme.of(context).brightness == Brightness.light ? Colors.black54 : IdePalette.textTertiary),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(fontSize: 10, color: Theme.of(context).brightness == Brightness.light ? Colors.black54 : IdePalette.textTertiary, fontFamily: 'monospace')),
        ],
      ),
    );
  }

  Widget _buildAttachedFilesList() {
    return Container(
      margin: const EdgeInsets.only(bottom: 8.0, top: 4.0),
      constraints: const BoxConstraints(maxHeight: 120),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: _attachedFiles.asMap().entries.map((entry) {
            final index = entry.key;
            final file = entry.value;

            // Görsel ise küçük önizleme kartı
            // KÖK NEDEN DÜZELTİSİ (v5.3.1): base64Image artık BİR DOSYA YOLU olabilir
            // (FileService._saveToAttachments resimleri diske kaydeder). Eski kod bu
            // yolu base64Decode'a sokup FormatException fırlatıyor → build çöküyor →
            // "tema hatası" kırmızı ekranı. _buildImageAttachment yolu/base64'ü/
            // file://'yü kendisi ayırt eder — tek güvenli giriş noktası odur.
            if (file.type == AttachedFileType.image && file.base64Image != null) {
              return Container(
                margin: const EdgeInsets.only(right: 8),
                child: Stack(
                  children: [
                    _buildImageAttachment(file.base64Image!),
                    Positioned(
                      top: -6,
                      right: -6,
                      child: GestureDetector(
                        onTap: () {
                          setState(() {
                            _attachedFiles.removeAt(index);
                          });
                        },
                        child: Container(
                          padding: const EdgeInsets.all(2),
                          decoration: const BoxDecoration(
                            color: Colors.black87,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.close, color: Colors.white, size: 14),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }

            // PDF, Word, Excel, Ses vb. için şık badge kartı
            Color cardColor;
            IconData cardIcon;
            String typeLabel;

            switch (file.type) {
              case AttachedFileType.cad:
                cardColor = Colors.amberAccent;
                cardIcon = Icons.architecture_rounded;
                typeLabel = 'AutoCAD';
                break;
              case AttachedFileType.pdf:
                cardColor = Colors.redAccent;
                cardIcon = Icons.picture_as_pdf_rounded;
                typeLabel = 'PDF';
                break;
              case AttachedFileType.word:
                cardColor = Colors.blueAccent;
                cardIcon = Icons.description_rounded;
                typeLabel = 'Word';
                break;
              case AttachedFileType.excel:
                cardColor = Colors.greenAccent;
                cardIcon = Icons.table_chart_rounded;
                typeLabel = 'Excel';
                break;
              case AttachedFileType.powerpoint:
                cardColor = Colors.orangeAccent;
                cardIcon = Icons.slideshow_rounded;
                typeLabel = 'Sunum';
                break;
              case AttachedFileType.audio:
                cardColor = Colors.purpleAccent;
                cardIcon = Icons.audiotrack_rounded;
                typeLabel = 'Müzik/Ses';
                break;
              case AttachedFileType.archive:
                cardColor = Colors.tealAccent;
                cardIcon = Icons.folder_zip_rounded;
                typeLabel = 'Arşiv';
                break;
              case AttachedFileType.codeOrText:
                cardColor = Colors.cyanAccent;
                cardIcon = Icons.code_rounded;
                typeLabel = 'Kod/Metin';
                break;
              default:
                cardColor = IdePalette.accentSoft;
                cardIcon = Icons.insert_drive_file_rounded;
                typeLabel = 'Dosya';
            }

            return Tooltip(
              message: 'Sistem uygulamasıyla açmak için dokunun: ${file.name}',
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => FileService.openInSystem(file.path),
                child: Container(
                  margin: const EdgeInsets.only(right: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: cardColor.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: cardColor.withOpacity(0.35)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(cardIcon, color: cardColor, size: 20),
                      const SizedBox(width: 8),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            file.name.length > 20 ? '${file.name.substring(0, 18)}...' : file.name,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            '${file.formattedSize} · $typeLabel',
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.6),
                              fontSize: 10,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: () {
                          setState(() {
                            _attachedFiles.removeAt(index);
                          });
                        },
                        child: Container(
                          padding: const EdgeInsets.all(3),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.12),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.close, color: Colors.white70, size: 12),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildChatInputBar() {
    final voiceState = ref.watch(voiceManagerProvider);
    // Eğer Canlı Oturum aktifse, buradaki normal mikrofon uykuya geçsin (isRecording = false gibi davransın)
    final isRecording = !voiceState.isLiveSession && (voiceState.isRecording || voiceState.isProcessingSTT);
    final isLight = Theme.of(context).brightness == Brightness.light;
    final language = ref.watch(languageProvider);
    final langStr = language == AppLanguage.tr ? 'tr' : 'en';
    final loc = ref.watch(localizationProvider);
    final isRunning = ref.watch(agentIsRunningProvider);

    return Container(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          Container(
            decoration: BoxDecoration(
              color: IdePalette.glassBackground,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: _focusNode.hasFocus || isRecording ? IdePalette.accentSoft : IdePalette.glassBorder),
              boxShadow: _focusNode.hasFocus || isRecording
                  ? const [BoxShadow(color: IdePalette.accentGlow, blurRadius: 20)]
                  : [],
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Row(
              children: [
                // Ataç Butonu (Ofis, PDF, AutoCAD DWG/DXF, Müzik/Ses, Resim vb. tüm dosyalar)
                IconButton(
                  tooltip: 'Dosya Ekle (Word, Excel, PowerPoint, PDF, AutoCAD DWG/DXF, Müzik/Ses, Resim)',
                  icon: const Icon(Icons.attach_file_rounded, color: IdePalette.accentSoft),
                  onPressed: _pickFiles,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: isRecording
                      ? _buildRecordingIndicator()
                      : _isExtracting
                          ? Row(
                              children: [
                                const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: IdePalette.accentSoft),
                                ),
                                const SizedBox(width: 10),
                                const Text(
                                  'Belgeler & ses kayıtları yapay zeka için ayrıştırılıyor...',
                                  style: TextStyle(color: IdePalette.accentSoft, fontSize: 13, fontWeight: FontWeight.w500),
                                ),
                              ],
                            )
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (_attachedFiles.isNotEmpty) _buildAttachedFilesList(),
                                Actions(
                                  actions: <Type, Action<Intent>>{
                                    PasteTextIntent: CallbackAction<PasteTextIntent>(
                                      onInvoke: (PasteTextIntent intent) async {
                                        _handlePasteUnified(focusInput: true);
                                        return null;
                                      },
                                    ),
                                  },
                                  child: Focus(
                                    onKeyEvent: (node, event) {
                                      if (event is KeyDownEvent) {
                                        final isCtrlOrMeta = HardwareKeyboard.instance.isControlPressed ||
                                            HardwareKeyboard.instance.isMetaPressed;
                                        if (isCtrlOrMeta && event.logicalKey == LogicalKeyboardKey.keyV) {
                                          _handlePasteUnified(focusInput: true);
                                          return KeyEventResult.handled;
                                        }
                                        if (event.logicalKey == LogicalKeyboardKey.enter) {
                                          if (!HardwareKeyboard.instance.isLogicalKeyPressed(LogicalKeyboardKey.shiftLeft) && 
                                              !HardwareKeyboard.instance.isLogicalKeyPressed(LogicalKeyboardKey.shiftRight)) {
                                            _sendPrompt();
                                            return KeyEventResult.handled;
                                          }
                                        }
                                      }
                                      return KeyEventResult.ignored;
                                    },
                                    child: TextField(
                                      controller: _promptController,
                                      focusNode: _focusNode,
                                      maxLines: null,
                                      keyboardType: TextInputType.multiline,
                                      style: TextStyle(color: isLight ? Colors.black87 : IdePalette.textPrimary),
                                      decoration: InputDecoration(
                                        hintText: loc['send_msg']?[langStr] ?? 'FerIDE\'ye mesaj gönder, dosya veya ekran görüntüsü yapıştır...',
                                        hintStyle: const TextStyle(color: IdePalette.textTertiary),
                                        border: InputBorder.none,
                                        isDense: true,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                ),
                // Geri Al Butonu
                if (ref.watch(activeSessionProvider)?.messages.isNotEmpty == true)
                  GestureDetector(
                    onTap: () {
                      ref.read(activeSessionProvider.notifier).undoLastInteraction();
                    },
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.transparent,
                      ),
                      child: const Icon(
                        Icons.undo,
                        color: IdePalette.textSecondary,
                        size: 20,
                      ),
                    ),
                  ),
                // Plan Modu Butonu (Claude Code Plan Mode)
                GestureDetector(
                  onTap: () {
                    final current = ref.read(planModeProvider);
                    ref.read(planModeProvider.notifier).state = !current;
                  },
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: ref.watch(planModeProvider)
                          ? IdePalette.accentSoft.withValues(alpha: 0.25)
                          : Colors.transparent,
                    ),
                    child: Tooltip(
                      message: ref.watch(planModeProvider) ? 'Plan Modu Aktif (Salt Okuma & Planlama)' : 'Plan Modu',
                      child: Icon(
                        Icons.assignment_outlined,
                        color: ref.watch(planModeProvider)
                            ? IdePalette.accentSoft
                            : IdePalette.textSecondary,
                        size: 20,
                      ),
                    ),
                  ),
                ),
                // Sesli İletişim Butonu (Mikrofon)
                GestureDetector(
                  onTap: () async {
                    final voiceState = ref.read(voiceManagerProvider);
                    if (voiceState.isProcessingSTT) return;
                    // Yalnızca bu düğmenin başlattığı kaydı durdur; mikrofon başka
                    // bir kullanıcıdaysa yeni bir sohbet kaydı başlat.
                    if (voiceState.isRecording && voiceState.micOwner == 'chat') {
                      final transcript = await ref.read(voiceManagerProvider.notifier).stopRecording();
                      final updatedVoice = ref.read(voiceManagerProvider);
                      if (transcript != null && transcript.trim().isNotEmpty) {
                        final existing = _promptController.text;
                        final sep = (existing.isNotEmpty &&
                                !existing.endsWith(' ') &&
                                !existing.endsWith('\n'))
                            ? ' '
                            : '';
                        _promptController.text = '$existing$sep${transcript.trim()}';
                        _promptController.selection = TextSelection.fromPosition(
                          TextPosition(offset: _promptController.text.length),
                        );
                        _focusNode.requestFocus();
                      } else if (mounted) {
                        final errMsg = updatedVoice.lastError;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              (errMsg != null && errMsg.isNotEmpty)
                                  ? errMsg
                                  : 'Konuşma algılanamadı. Lütfen mikrofona biraz daha yakın konuşup tekrar deneyin.',
                            ),
                            backgroundColor: (errMsg != null && errMsg.isNotEmpty)
                                ? Colors.redAccent
                                : Colors.orange.shade800,
                            duration: const Duration(seconds: 3),
                          ),
                        );
                      }
                    } else {
                      await ref.read(voiceManagerProvider.notifier).startRecording();
                      final afterStart = ref.read(voiceManagerProvider);
                      if (!afterStart.isRecording && afterStart.lastError != null && mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(afterStart.lastError!),
                            backgroundColor: Colors.redAccent,
                            duration: const Duration(seconds: 4),
                          ),
                        );
                      }
                    }
                  },
                  child: Tooltip(
                    message: isRecording ? 'Kaydı Durdur ve Yazıya Çevir' : 'Sesli Yazma (Mikrofon)',
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isRecording ? Colors.redAccent.withOpacity(0.2) : Colors.transparent,
                      ),
                      child: Icon(
                        isRecording ? Icons.stop_circle : Icons.mic,
                        color: isRecording ? Colors.redAccent : IdePalette.textSecondary,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Gönder / Durdur Butonu
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: isRunning
                          ? [Colors.redAccent, Colors.red]
                          : isRecording
                              ? [Colors.grey, Colors.grey.shade700]
                              : [const Color(0xFF3B82F6), const Color(0xFF8B5CF6)],
                    ),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: IconButton(
                    icon: Icon(isRunning ? Icons.stop : Icons.arrow_upward, size: 18, color: Colors.white),
                    onPressed: isRunning 
                        ? () {
                            final sessionId = ref.read(activeSessionProvider)?.id;
                            ref.read(agentEngineProvider(sessionId)).cancel();
                          }
                        : (isRecording || _isExtracting ? null : _sendPrompt),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          const Text('⏎ Gönder · ⇧⏎ Yeni Satır · Esc Durdur · Ctrl+V Yapıştır · Sürükle-Bırak', style: TextStyle(color: IdePalette.textTertiary, fontSize: 11)),
        ],
      ),
    );
  }

  Widget _buildRecordingIndicator() {
    final voiceState = ref.watch(voiceManagerProvider);
    final isProcessing = voiceState.isProcessingSTT;
    final text = isProcessing ? "Ses metne çevriliyor (STT)..." : "Ses kaydediliyor...";
    
    return Row(
      children: [
        if (isProcessing)
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.redAccent),
          )
        else
          const Icon(Icons.mic, color: Colors.redAccent, size: 16),
        const SizedBox(width: 8),
        Text(text, style: const TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold)),
      ],
    );
  }

  Future<void> _sendPrompt([String? customPrompt]) async {
    final text = customPrompt?.trim() ?? _promptController.text.trim();
    if (text.isEmpty && _attachedFiles.isEmpty) return;

    final filesToSend = customPrompt != null
        ? <AttachedFile>[]
        : List<AttachedFile>.from(_attachedFiles);
    setState(() {
      if (customPrompt == null) {
        _promptController.clear();
        _attachedFiles.clear();
        _isExtracting = filesToSend.any((f) => f.type != AttachedFileType.image);
      }
    });

    final List<String> base64Images = [];
    final List<String> docContexts = [];

    final imageFiles =
        filesToSend.where((f) => f.type == AttachedFileType.image && f.base64Image != null);
    for (final img in imageFiles) {
      base64Images.add(img.base64Image!);
    }

    final docFiles = filesToSend
        .where((f) => f.type != AttachedFileType.image || f.base64Image == null)
        .toList();
    if (docFiles.isNotEmpty) {
      final docResults = await Future.wait(docFiles.map((file) async {
        try {
          final extracted = await FileService.extractContentWithPreview(file.path)
              .timeout(const Duration(seconds: 120));
          if (extracted.renderedPreviewImage != null) {
            base64Images.add(extracted.renderedPreviewImage!);
          }
          return "### Ekli Dosya: ${file.name} (${file.formattedSize})\nPath: ${file.path}\n```\n${extracted.content}\n```";
        } catch (e) {
          return "### Ekli Dosya: ${file.name} (Hata: İçerik çıkarılamadı - $e)";
        }
      }));
      docContexts.addAll(docResults);
    }

    if (mounted) {
      setState(() {
        _isExtracting = false;
      });
    }

    String finalInput = "";
    if (docContexts.isNotEmpty) {
      finalInput = "[EK DOSYA VE BELGELER]:\n${docContexts.join("\n\n")}\n\n";
      if (text.isNotEmpty) {
        finalInput += "[KULLANICI SORUSU / TALİMATI]:\n$text";
      } else {
        finalInput += "[KULLANICI TALİMATI]: Lütfen ekli dosya/belgeleri detaylı incele, özetle veya ana noktalarını açıkla.";
      }
    } else {
      finalInput = text.isEmpty ? "Resmi analiz et." : text;
    }

    final isThinking = ref.read(thinkingModeProvider);
    final currentTokens = ref.read(tokenCountProvider);
    final tLevel = ref.read(thinkingLevelProvider);

    var session = ref.read(activeSessionProvider);
    if (session == null) {
      final title = text.isNotEmpty
          ? (text.length > 20 ? '${text.substring(0, 20)}...' : text)
          : (filesToSend.isNotEmpty ? filesToSend.first.name : 'Yeni Sohbet');
      session = ChatSession(title: title);
      ref.read(activeSessionProvider.notifier).setSession(session);
    }

    final sessionId = session.id;
    final images = base64Images.isNotEmpty ? base64Images : null;

    // Kullanıcının mesajını Stream'i beklemeden doğrudan arayüze ekle (Sıfır Gecikme)
    ref.read(activeSessionProvider.notifier).addEvent(AgentStarted(finalInput, base64Images: images));

    ref.read(agentEngineProvider(sessionId)).run(
      finalInput, 
      isThinking, 
      currentTokens, 
      base64Images: images,
      thinkingLevel: tLevel,
    );

    _focusNode.requestFocus();
  }
  Widget _buildLiveTodoBar(List<TodoItem> todos) {
    final completedCount = todos.where((t) => t.status == 'completed').length;
    final totalCount = todos.length;
    final isDone = completedCount == totalCount;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 40, vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: IdePalette.backgroundBase,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDone
              ? Colors.green.withValues(alpha: 0.4)
              : IdePalette.accentSoft.withValues(alpha: 0.35),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                isDone ? Icons.task_alt_rounded : Icons.checklist_rounded,
                size: 18,
                color: isDone ? Colors.greenAccent : IdePalette.accentSoft,
              ),
              const SizedBox(width: 8),
              Text(
                'Görev Planı ($completedCount/$totalCount)',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                  color: IdePalette.textPrimary,
                ),
              ),
              const Spacer(),
              if (!isDone)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: IdePalette.accentSoft,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          ...todos.map((item) {
            IconData icon;
            Color iconColor;
            TextStyle textStyle;

            if (item.status == 'completed') {
              icon = Icons.check_circle_rounded;
              iconColor = Colors.greenAccent;
              textStyle = const TextStyle(
                fontSize: 12,
                color: IdePalette.textTertiary,
                decoration: TextDecoration.lineThrough,
              );
            } else if (item.status == 'in_progress') {
              icon = Icons.play_circle_fill_rounded;
              iconColor = IdePalette.accentSoft;
              textStyle = const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: IdePalette.textPrimary,
              );
            } else {
              icon = Icons.radio_button_unchecked_rounded;
              iconColor = IdePalette.textTertiary;
              textStyle = const TextStyle(
                fontSize: 12,
                color: IdePalette.textSecondary,
              );
            }

            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 2.0),
              child: Row(
                children: [
                  Icon(icon, size: 14, color: iconColor),
                  const SizedBox(width: 6),
                  Expanded(child: Text(item.content, style: textStyle)),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }


  Widget _buildMessageBody(BuildContext context, String text, bool isUser) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final textColor = isUser
        ? (isLight ? Colors.black87 : Colors.white)
        : (isLight ? Colors.black87 : IdePalette.textPrimary);

    if (isUser) {
      return Text(
        text,
        style: TextStyle(
          color: textColor,
          height: 1.6,
          fontSize: 14,
        ),
      );
    }

    return MarkdownBody(
      data: text,
      selectable: true,
      extensionSet: md.ExtensionSet.gitHubFlavored,
      styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
        p: TextStyle(
          color: textColor,
          fontSize: 14,
          height: 1.6,
        ),
        h1: TextStyle(
          color: isLight ? Colors.black : IdePalette.accentSoft,
          fontSize: 20,
          fontWeight: FontWeight.bold,
          height: 1.4,
        ),
        h2: TextStyle(
          color: isLight ? Colors.black87 : IdePalette.accentSoft,
          fontSize: 17,
          fontWeight: FontWeight.bold,
          height: 1.4,
        ),
        h3: TextStyle(
          color: isLight ? Colors.black87 : Colors.white,
          fontSize: 15,
          fontWeight: FontWeight.w600,
          height: 1.4,
        ),
        strong: TextStyle(
          color: isLight ? Colors.black : Colors.white,
          fontWeight: FontWeight.bold,
        ),
        em: const TextStyle(fontStyle: FontStyle.italic),
        code: TextStyle(
          backgroundColor: isLight ? Colors.grey.shade200 : const Color(0xFF1E1E1E),
          color: IdePalette.accentSoft,
          fontFamily: 'monospace',
          fontSize: 12.5,
        ),
        codeblockPadding: const EdgeInsets.all(12),
        codeblockDecoration: BoxDecoration(
          color: isLight ? const Color(0xFFF3F3F3) : const Color(0xFF161616),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: isLight ? Colors.black12 : IdePalette.glassBorder.withOpacity(0.6)),
        ),
        tableHead: TextStyle(
          fontWeight: FontWeight.bold,
          color: isLight ? Colors.black87 : IdePalette.accentSoft,
          fontSize: 13,
        ),
        tableBody: TextStyle(
          color: textColor,
          fontSize: 13,
          height: 1.4,
        ),
        tableBorder: TableBorder.all(
          color: isLight ? Colors.black12 : IdePalette.glassBorder.withOpacity(0.7),
          width: 1,
          borderRadius: BorderRadius.circular(6),
        ),
        tableHeadAlign: TextAlign.left,
        tableCellsPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        tableCellsDecoration: BoxDecoration(
          color: isLight ? Colors.grey.shade50 : IdePalette.backgroundBase.withOpacity(0.3),
        ),
        blockquote: TextStyle(
          color: isLight ? Colors.grey.shade700 : IdePalette.textSecondary,
          fontStyle: FontStyle.italic,
          fontSize: 13.5,
        ),
        blockquoteDecoration: BoxDecoration(
          border: Border(left: BorderSide(color: IdePalette.accentSoft, width: 3.5)),
        ),
        listBullet: const TextStyle(color: IdePalette.accentSoft, fontSize: 14),
      ),
    );
  }

}
