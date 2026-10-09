import 'dart:convert';
import 'dart:math' as math;

/// Formal versioned protocol envelope for all MNDO application messages.
/// Enforces structured schemas for text messages, media, receipts, and typing indicators.
class MndoMessageEnvelope {
  static const int currentVersion = 1;
  static final math.Random _secureRandom = math.Random.secure();

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

  /// Helper to generate a cryptographically secure UUIDv4 client message ID (MSG-ID-01A).
  /// Uses 128 random bits from CSPRNG (Random.secure) with UUID version 4 and RFC variant bits.
  static String generateMessageId([String? prefix]) {
    final bytes = List<int>.generate(16, (_) => _secureRandom.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // UUID version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // RFC variant
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final uuid = [
      hex.substring(0, 8),
      hex.substring(8, 12),
      hex.substring(12, 16),
      hex.substring(16, 20),
      hex.substring(20),
    ].join('-');
    return prefix == null ? uuid : '$prefix-$uuid';
  }
}
