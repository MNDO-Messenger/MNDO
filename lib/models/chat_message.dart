import 'mndo_message_envelope.dart';

enum MessageStatus {
  sending,
  sent,
  delivered,
  read,
  failed,
}

class ChatMessage {
  final String messageId;
  String text;
  final bool isMe;
  final DateTime timestamp;
  MessageStatus status;
  final String? replyToId;

  ChatMessage({
    String? messageId,
    required this.text,
    required this.isMe,
    required this.timestamp,
    this.status = MessageStatus.sent,
    this.replyToId,
  }) : messageId = messageId ?? MndoMessageEnvelope.generateMessageId('msg');
}
