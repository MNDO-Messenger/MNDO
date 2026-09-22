enum MessageStatus {
  sending,
  sent,
  failed,
}

class ChatMessage {
  String text;
  final bool isMe;
  final DateTime timestamp;
  MessageStatus status;

  ChatMessage({
    required this.text,
    required this.isMe,
    required this.timestamp,
    this.status = MessageStatus.sent,
  });
}

