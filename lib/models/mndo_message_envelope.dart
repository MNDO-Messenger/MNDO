import 'dart:convert';
import 'dart:math' as math;

/// Formal versioned protocol envelope for all MNDO application messages.
/// Enforces structured schemas for text messages, media, receipts, and typing indicators.
class MndoMessageEnvelope {
  static const int currentVersion = 1;
  static final math.Random _secureRandom = math.Random.secure();

  static const Set<int> supportedVersions = {1};
  static const Set<String> supportedTypes = {
    'text',
    'media',
    'voice_note',
    'voice',
    'receipt',
    'typing',
    'control',
  };
  static const int maxRawPayloadBytes = 5 * 1024 * 1024; // 5 MB max payload
  static const int minValidTimestamp = 1577836800000; // 2020-01-01 UTC
  static final RegExp hex64Regex = RegExp(r'^[0-9a-fA-F]{64}$');

  final int version;
  final String messageId;
  final String type; // 'text', 'media', 'voice_note', 'voice', 'receipt', 'typing', 'control'
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
      if (raw.length > maxRawPayloadBytes) {
        return null;
      }

      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;

      // 1. Version validation: must be an explicitly supported protocol version
      final versionRaw = decoded['v'];
      if (versionRaw is! int || !supportedVersions.contains(versionRaw)) {
        return null;
      }

      // 2. Message ID validation: non-empty string within bounds
      final idRaw = decoded['id'];
      if (idRaw is! String || idRaw.trim().isEmpty || idRaw.length > 256) {
        return null;
      }

      // 3. Type validation: must be a recognized supported message type
      final typeRaw = decoded['type'];
      if (typeRaw is! String || !supportedTypes.contains(typeRaw)) {
        return null;
      }

      // 4. Timestamp validation: positive epoch integer within sensible bounds
      final tsRaw = decoded['ts'];
      if (tsRaw is! int || tsRaw <= 0) {
        return null;
      }
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      // Allow up to 10 minutes forward clock drift and sensible past epoch bounds
      if (tsRaw > nowMs + 10 * 60 * 1000 || tsRaw < minValidTimestamp) {
        return null;
      }

      // 5. Body shape validation: must be a Map
      final bodyRaw = decoded['body'];
      if (bodyRaw is! Map) {
        return null;
      }
      final bodyMap = Map<String, dynamic>.from(bodyRaw);

      // Per-type schema validation (F4)
      switch (typeRaw) {
        case 'text':
          if (bodyMap['text'] is! String) return null;
          break;
        case 'receipt':
          final targetId = bodyMap['targetId'];
          final status = bodyMap['status'];
          if (targetId is! String || targetId.trim().isEmpty || targetId.length > 256) {
            return null;
          }
          if (status is! String || !const {'sent', 'delivered', 'read'}.contains(status)) {
            return null;
          }
          break;
        case 'voice_note':
        case 'voice':
        case 'media':
          final text = bodyMap['text'];
          final payload = bodyMap['payload'];
          final url = bodyMap['url'];
          final fileHash = bodyMap['fileHash'];
          if (text is! String && payload == null && url is! String && fileHash is! String) {
            return null;
          }
          break;
        case 'typing':
          final isTyping = bodyMap['isTyping'];
          if (isTyping != null && isTyping is! bool) return null;
          break;
        case 'control':
          final control = bodyMap['control'] ?? bodyMap['text'];
          if (control is! String || control.trim().isEmpty) return null;
          break;
      }

      // 6. Sender identity validation:
      // Mandatory for message types requiring identity; must be a valid 64-character hexadecimal public key
      final senderRaw = decoded['sender'];
      if (senderRaw is! String || !hex64Regex.hasMatch(senderRaw)) {
        return null;
      }

      // 7. Optional replyTo validation
      final replyToRaw = decoded['replyTo'];
      if (replyToRaw != null && (replyToRaw is! String || replyToRaw.length > 256)) {
        return null;
      }

      return MndoMessageEnvelope(
        version: versionRaw,
        messageId: idRaw,
        type: typeRaw,
        timestamp: tsRaw,
        senderMasterPubKey: senderRaw,
        body: bodyMap,
        replyToId: replyToRaw as String?,
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
