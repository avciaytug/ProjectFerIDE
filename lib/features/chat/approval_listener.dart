import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';

import '../../agent/permissions.dart';

/// Ajanın onay isteklerini dinler ve kullanıcıya sırayla onay penceresi gösterir.
class ApprovalListener extends StatefulWidget {
  final Widget child;
  const ApprovalListener({super.key, required this.child});

  @override
  State<ApprovalListener> createState() => _ApprovalListenerState();
}

class _ApprovalListenerState extends State<ApprovalListener> {
  StreamSubscription<ApprovalRequest>? _sub;
  final Queue<ApprovalRequest> _queue = Queue();
  bool _showing = false;

  @override
  void initState() {
    super.initState();
    _sub = ApprovalBroker.instance.requests.listen((r) {
      _queue.add(r);
      _pump();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _pump() async {
    if (_showing || !mounted) return;
    while (_queue.isNotEmpty && mounted) {
      final req = _queue.removeFirst();
      if (req.isResolved) continue; // ajan durdurulmuş olabilir
      _showing = true;
      final result = await showDialog<_Choice>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _ApprovalDialog(request: req),
      );
      _showing = false;
      if (result == _Choice.always) ApprovalBroker.instance.sessionAllowedTools.add(req.toolName);
      req.resolve(result == _Choice.once || result == _Choice.always);
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

enum _Choice { deny, once, always }

class _ApprovalDialog extends StatefulWidget {
  final ApprovalRequest request;
  const _ApprovalDialog({required this.request});

  @override
  State<_ApprovalDialog> createState() => _ApprovalDialogState();
}

class _ApprovalDialogState extends State<_ApprovalDialog> {
  @override
  void initState() {
    super.initState();
    // Ajan iptal edilirse pencereyi kendiliğinden kapat.
    widget.request.future.then((_) {
      if (mounted && Navigator.of(context).canPop()) Navigator.of(context).pop(_Choice.deny);
    });
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.request;
    final scheme = Theme.of(context).colorScheme;
    final (icon, color, title) = switch (r.risk) {
      ToolRisk.execute => (Icons.terminal_rounded, Colors.orange, 'Komut çalıştırma onayı'),
      ToolRisk.write => (Icons.edit_document, Colors.blue, 'Dosya değişikliği onayı'),
      ToolRisk.network => (Icons.public, Colors.teal, 'İnternet erişimi onayı'),
      ToolRisk.read => (Icons.visibility, Colors.green, 'Onay'),
    };
    // "Hep izin ver" komut çalıştırma için sunulmaz: her komut ayrı değerlendirilmeli.
    final allowAlways = r.risk != ToolRisk.execute;

    return AlertDialog(
      title: Row(children: [
        Icon(icon, color: color),
        const SizedBox(width: 10),
        Expanded(child: Text(title, style: const TextStyle(fontSize: 17))),
      ]),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('FerIDE şu işlemi yapmak istiyor (${r.toolName}). Neden soruluyor: ${r.reason}.',
                style: TextStyle(fontSize: 13, color: scheme.onSurface.withValues(alpha: 0.8))),
            const SizedBox(height: 12),
            Flexible(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(r.summary, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, _Choice.deny), child: const Text('Reddet')),
        if (allowAlways)
          TextButton(
              onPressed: () => Navigator.pop(context, _Choice.always), child: const Text('Bu oturumda hep izin ver')),
        FilledButton(
          autofocus: true,
          onPressed: () => Navigator.pop(context, _Choice.once),
          child: const Text('İzin ver'),
        ),
      ],
    );
  }
}
