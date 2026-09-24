import 'dart:convert';

/// Formal versioned protocol envelope for all MNDO application messages.
/// Enforces structured schemas for text messages, media, receipts, and typing indicators.
class MndoMessageEnvelope {
  static const int currentVersion = 1;

  final int version;
  final String messageId;
  final String type; // 'text', 'voice_note', 'receipt', 'typing', 'control'
  final int timestamp;
  final String senderMasterPubKey;
  final Map<String, dynamic> body;
  final String? replyToId;

  const MndoMessageEnvelope({
    this.version = currentVersion,
    required this.messageId,
    required this.type,
    required this.timestamp,
    required this.senderMasterPubKey,
    required this.body,
    this.replyToId,
  });

  Map<String, dynamic> toJson() => {
    'v': version,
    'id': messageId,
    'type': type,
    'ts': timestamp,
    'sender': senderMasterPubKey,
    'body': body,
    if (replyToId != null) 'replyTo': replyToId,
  };

  String serialize() => jsonEncode(toJson());

  static MndoMessageEnvelope? tryParse(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      if (!decoded.containsKey('id') || !decoded.containsKey('type')) return null;

      return MndoMessageEnvelope(
        version: decoded['v'] as int? ?? 1,
        messageId: decoded['id'] as String,
        type: decoded['type'] as String,
        timestamp: decoded['ts'] as int? ?? DateTime.now().millisecondsSinceEpoch,
        senderMasterPubKey: decoded['sender'] as String? ?? '',
        body: (decoded['body'] is Map)
            ? Map<String, dynamic>.from(decoded['body'] as Map)
            : <String, dynamic>{},
        replyToId: decoded['replyTo'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  /// Helper to generate a unique client message ID
  static String generateMessageId([String? prefix]) {
    final now = DateTime.now().microsecondsSinceEpoch;
    final salt = (now.hashCode ^ DateTime.now().millisecondsSinceEpoch).toRadixString(16);
    return prefix != null ? '$prefix-$now-$salt' : 'msg-$now-$salt';
  }
}
