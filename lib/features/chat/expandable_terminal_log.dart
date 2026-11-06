import 'package:flutter/material.dart';
import '../../services/agent_engine.dart';
import '../../models/chat_session.dart';
import 'agent_activity_group.dart';

class ExpandableTerminalLog extends StatelessWidget {
  final AgentEvent event;

  const ExpandableTerminalLog({Key? key, required this.event}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    // Tek bir AgentEvent geldiğinde bunu AgentActivityGroup ile sarmalayarak göster
    final dummyMessage = ChatMessage(
      id: 'log_${DateTime.now().millisecondsSinceEpoch}',
      event: event,
    );
    return AgentActivityGroup(
      messages: [dummyMessage],
      isLive: false,
    );
  }
}
