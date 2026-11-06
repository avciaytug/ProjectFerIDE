import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../models/chat_session.dart';
import '../../services/agent_engine.dart';
import '../../theme/ide_palette.dart';

class AgentActivityGroup extends StatefulWidget {
  final List<ChatMessage> messages;
  final bool isLive;

  const AgentActivityGroup({
    Key? key,
    required this.messages,
    this.isLive = false,
  }) : super(key: key);

  @override
  State<AgentActivityGroup> createState() => _AgentActivityGroupState();
}

class _AgentActivityGroupState extends State<AgentActivityGroup> {
  bool _isExpanded = false;

  @override
  Widget build(BuildContext context) {
    if (widget.messages.isEmpty) return const SizedBox.shrink();

    final isLight = Theme.of(context).brightness == Brightness.light;
    final toolInvokedEvents = widget.messages
        .map((m) => m.event)
        .whereType<ToolInvoked>()
        .toList();
    final toolCount = toolInvokedEvents.length;

    final distinctToolNames = <String>{};
    for (final t in toolInvokedEvents) {
      distinctToolNames.add(t.toolName);
    }

    final hasReasoning = widget.messages.any((m) => m.event is ReasoningMessage);

    // Başlık ve durum metni oluştur
    String statusTitle;
    if (widget.isLive) {
      final lastTool = toolInvokedEvents.isNotEmpty ? toolInvokedEvents.last.toolName : null;
      if (lastTool != null) {
        statusTitle = 'İşlem yürütülüyor: $lastTool...';
      } else if (hasReasoning) {
        statusTitle = 'Derin düşünülüyor (Reasoning)...';
      } else {
        final stepEvents = widget.messages.map((m) => m.event).whereType<StepStarted>().toList();
        if (stepEvents.isNotEmpty) {
          statusTitle = stepEvents.last.step.description;
        } else {
          statusTitle = 'Ajan çalışıyor...';
        }
      }
    } else {
      if (toolCount > 0) {
        final toolsStr = distinctToolNames.take(3).join(', ') + (distinctToolNames.length > 3 ? '...' : '');
        statusTitle = '⚡ $toolCount işlem tamamlandı ($toolsStr)';
      } else if (hasReasoning) {
        statusTitle = '🧠 Model düşünce süreci tamamlandı';
      } else {
        statusTitle = '⚡ ${widget.messages.length} adım tamamlandı';
      }
    }

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: isLight
            ? (widget.isLive ? Colors.blue.shade50 : Colors.grey.shade100)
            : (widget.isLive ? const Color(0xFF161B26) : const Color(0xFF12141A)),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: widget.isLive
              ? IdePalette.accentSoft.withOpacity(0.6)
              : (isLight ? Colors.grey.shade300 : IdePalette.glassBorder.withOpacity(0.4)),
          width: widget.isLive ? 1.5 : 1.0,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Başlık Çubuğu (Tıklanabilir)
          InkWell(
            onTap: () {
              setState(() {
                _isExpanded = !_isExpanded;
              });
            },
            borderRadius: BorderRadius.circular(9),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  if (widget.isLive)
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(IdePalette.accentSoft),
                      ),
                    )
                  else
                    Icon(
                      toolCount > 0 ? Icons.terminal_rounded : Icons.psychology_outlined,
                      size: 16,
                      color: isLight ? Colors.blue.shade700 : IdePalette.accentSoft,
                    ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      statusTitle,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: widget.isLive
                            ? (isLight ? Colors.blue.shade800 : IdePalette.accentSoft)
                            : (isLight ? Colors.black87 : IdePalette.textPrimary),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: isLight ? Colors.black12 : Colors.white.withOpacity(0.06),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      '${widget.messages.length} adım',
                      style: TextStyle(
                        fontSize: 10,
                        fontFamily: 'monospace',
                        color: isLight ? Colors.black54 : IdePalette.textTertiary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Icon(
                    _isExpanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
                    size: 18,
                    color: isLight ? Colors.black54 : IdePalette.textSecondary,
                  ),
                ],
              ),
            ),
          ),

          // Genişletilmiş Detaylar Paneli
          if (_isExpanded) ...[
            Divider(
              height: 1,
              thickness: 1,
              color: isLight ? Colors.grey.shade300 : IdePalette.glassBorder.withOpacity(0.3),
            ),
            Container(
              padding: const EdgeInsets.all(12),
              constraints: const BoxConstraints(maxHeight: 380),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: widget.messages.map((m) => _buildDetailItem(m, isLight)).toList(),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDetailItem(ChatMessage message, bool isLight) {
    final event = message.event;

    if (event is ReasoningMessage) {
      return Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: isLight ? Colors.purple.shade50 : IdePalette.accentSoft.withOpacity(0.08),
          borderRadius: BorderRadius.circular(6),
          border: Border(
            left: BorderSide(
              color: isLight ? Colors.purple.shade400 : IdePalette.accentSoft,
              width: 3,
            ),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.psychology_outlined,
                  size: 14,
                  color: isLight ? Colors.purple.shade700 : IdePalette.accentSoft,
                ),
                const SizedBox(width: 6),
                Text(
                  'Model Düşüncesi (Reasoning):',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: isLight ? Colors.purple.shade700 : IdePalette.accentSoft,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            SelectableText(
              event.message,
              style: TextStyle(
                fontSize: 11.5,
                fontFamily: 'monospace',
                height: 1.4,
                color: isLight ? Colors.purple.shade900 : Colors.white.withOpacity(0.85),
              ),
            ),
          ],
        ),
      );
    }

    if (event is StepStarted) {
      return Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.arrow_right_rounded, size: 16, color: IdePalette.accentSoft),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                event.step.description,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: isLight ? Colors.black87 : IdePalette.textPrimary,
                ),
              ),
            ),
          ],
        ),
      );
    }

    if (event is ToolInvoked) {
      String cmdPreview = '';
      if (event.toolName == 'run_command') {
        cmdPreview = '\$ ${(event.arguments['command'] ?? '')}';
      } else if (event.toolName == 'read_file') {
        cmdPreview = '📖 read_file: ${(event.arguments['path'] ?? '')}';
      } else if (event.toolName == 'write_to_file') {
        cmdPreview = '✏️ write_to_file: ${(event.arguments['path'] ?? '')}';
      } else if (event.toolName == 'replace_file_content') {
        cmdPreview = '🔄 replace: ${(event.arguments['path'] ?? '')}';
      } else {
        cmdPreview = '⚙️ ${event.toolName}(${event.arguments})';
      }

      return Container(
        margin: const EdgeInsets.only(top: 4, bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isLight ? Colors.grey.shade200 : Colors.black.withOpacity(0.35),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            Expanded(
              child: SelectableText(
                cmdPreview,
                style: TextStyle(
                  fontSize: 11.5,
                  fontFamily: 'monospace',
                  color: isLight ? Colors.teal.shade800 : const Color(0xFF6EE7B7),
                ),
              ),
            ),
          ],
        ),
      );
    }

    if (event is ToolCompleted) {
      final out = event.output;
      final displayOut = out.length > 2000
          ? '${out.substring(0, 2000)}\n...[Kalan ${out.length - 2000} karakter gizlendi]'
          : out;

      return Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: isLight ? Colors.grey.shade100 : const Color(0xFF0D0F14),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isLight ? Colors.grey.shade300 : Colors.white.withOpacity(0.06),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Çıktı (${event.toolName}):',
                  style: TextStyle(
                    fontSize: 10,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.bold,
                    color: isLight ? Colors.grey.shade600 : IdePalette.textTertiary,
                  ),
                ),
                InkWell(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: out));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Çıktı panoya kopyalandı'),
                        duration: Duration(seconds: 1),
                      ),
                    );
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: Icon(
                      Icons.copy_rounded,
                      size: 13,
                      color: isLight ? Colors.grey.shade600 : IdePalette.textTertiary,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            SelectableText(
              displayOut,
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                color: isLight ? Colors.grey.shade800 : IdePalette.textSecondary,
              ),
            ),
          ],
        ),
      );
    }

    return const SizedBox.shrink();
  }
}
