import 'package:drift/drift.dart';
import '../database/database.dart';
import '../models/discover_user.dart';
import '../models/chat_message.dart';
import '../services/account_session.dart';
import '../services/voice_note_service.dart';

class ChatRepository {
  final AppDatabase db;
  final int sessionGeneration;
  
  ChatRepository(this.db, {int? sessionGeneration})
      : sessionGeneration = sessionGeneration ?? AccountSession.currentGeneration;

  void _ensureActive() {
    if (!AccountSession.isGenerationValid(sessionGeneration)) {
      throw StateError(
        'ChatRepository operation aborted: stale session generation $sessionGeneration (active: ${AccountSession.currentGeneration})'
      );
    }
  }

  Future<List<DiscoverUser>> getAllChats() async {
    _ensureActive();
    final savedChats = await db.getAllChats();
    _ensureActive();
    return savedChats.map((chat) => DiscoverUser(
      masterPubKeyHex: chat.masterPubKeyHex,
      nostrPubKeyHex: chat.nostrPubKeyHex,
      username: chat.username,
      displayName: chat.displayName,
      bio: chat.bio,
      lastSeen: chat.lastSeen,
    )).toList();
  }

  Future<void> saveChat(DiscoverUser user) async {
    _ensureActive();
    await db.insertChat(ActiveChatsCompanion(
      masterPubKeyHex: Value(user.masterPubKeyHex),
      nostrPubKeyHex: Value(user.nostrPubKeyHex),
      username: Value(user.username),
      displayName: Value(user.displayName),
      bio: Value(user.bio),
      lastSeen: Value(user.lastSeen),
    ));
    _ensureActive();
  }

  Future<List<ChatMessage>> getMessagesForChat(String nostrPubKey) async {
    _ensureActive();
    final messages = await db.getMessagesForChat(nostrPubKey);
    _ensureActive();
    return messages.map((m) {
      MessageStatus status = MessageStatus.sent;
      try {
        status = MessageStatus.values.byName(m.status);
      } catch (_) {}
      if (status == MessageStatus.sending) {
        status = MessageStatus.failed;
      }
      return ChatMessage(
        messageId: m.messageId,
        text: m.messageText,
        isMe: m.isMe,
        timestamp: m.timestamp,
        status: status,
        replyToId: m.replyToId,
      );
    }).toList();
  }

  Future<void> saveMessage(String nostrPubKey, ChatMessage message) async {
    _ensureActive();
    final existing = await db.getMessageByMessageId(message.messageId);
    if (existing != null) {
      if (existing.nostrPubKeyHex == nostrPubKey &&
          existing.messageText == message.text &&
          existing.isMe == message.isMe) {
        // Identical replay: deduplicate safely without re-inserting or mutating
        return;
      }
      // Conflicting reuse: reject without modifying or overwriting existing row
      print('[REPO] Conflicting messageId reuse rejected for id=${message.messageId}');
      return;
    }
    await db.insertMessage(ChatMessagesCompanion.insert(
      messageId: message.messageId,
      nostrPubKeyHex: nostrPubKey,
      messageText: message.text,
      isMe: message.isMe,
      timestamp: message.timestamp,
      status: Value(message.status.name),
      replyToId: Value(message.replyToId),
    ));
    _ensureActive();
  }

  Future<void> updateMessageStatus(String messageId, MessageStatus status) async {
    _ensureActive();
    await db.updateMessageStatus(messageId, status.name);
    _ensureActive();
  }

  Future<ChatMessageRecord?> getMessageByMessageId(String messageId) async {
    _ensureActive();
    final record = await db.getMessageByMessageId(messageId);
    _ensureActive();
    return record;
  }

  Future<int> markMessagesReadUpTo(String peerNostrPubKey, DateTime timestamp) async {
    _ensureActive();
    final count = await db.markMessagesReadUpTo(peerNostrPubKey, timestamp);
    _ensureActive();
    return count;
  }

  Future<void> deleteMessage(String messageId) async {
    _ensureActive();
    final record = await db.getMessageByMessageId(messageId);
    if (record != null && VoiceNotePayload.isVoiceNote(record.messageText)) {
      final payload = VoiceNotePayload.tryParse(record.messageText);
      if (payload != null && payload.fileHash.isNotEmpty) {
        await VoiceNoteCacheManager().deleteForHash(payload.fileHash);
      }
    }
    await db.deleteMessageByMessageId(messageId);
    _ensureActive();
  }

  Future<void> clearAll() async {
    _ensureActive();
    await db.clearChats();
    await db.clearMessages();
    await db.clearOutbox();
    try {
      await VoiceNoteCacheManager().cleanupAll();
    } catch (_) {}
    _ensureActive();
  }

  Future<DateTime?> getLatestMessageTimestamp() async {
    _ensureActive();
    final ts = await db.getLatestMessageTimestamp();
    _ensureActive();
    return ts;
  }

  static const Duration defaultOutboxTtl = Duration(days: 7);

  // Outbox operations
  Future<void> enqueueOutbox({
    required String messageId,
    required String recipientNostrPubKey,
    required String payloadJson,
    DateTime? createdAt,
    Duration ttl = defaultOutboxTtl,
    DateTime? expiresAt,
  }) async {
    _ensureActive();
    final now = createdAt ?? DateTime.now();
    final effectiveExpiresAt = expiresAt ?? now.add(ttl);
    await db.enqueueOutboxMessage(OutboxMessagesCompanion.insert(
      messageId: messageId,
      recipientNostrPubKey: recipientNostrPubKey,
      payloadJson: payloadJson,
      createdAt: now,
      expiresAt: effectiveExpiresAt,
      status: const Value('pending'),
    ));
    _ensureActive();
  }

  Future<int> markExpiredOutboxMessages(DateTime now) async {
    _ensureActive();
    final count = await db.markExpiredOutboxMessages(now);
    _ensureActive();
    return count;
  }

  Future<List<OutboxRecord>> getPendingOutboxMessages() async {
    _ensureActive();
    final records = await db.getPendingOutboxMessages();
    _ensureActive();
    return records;
  }

  Future<OutboxRecord?> getOutboxRecord(String messageId) async {
    _ensureActive();
    final record = await db.getOutboxMessage(messageId);
    _ensureActive();
    return record;
  }

  Future<void> deleteFromOutbox(String messageId) async {
    _ensureActive();
    await db.deleteOutboxMessage(messageId);
    _ensureActive();
  }

  Future<void> updateOutboxAttempt(
    String messageId, {
    required int attempts,
    required DateTime lastAttemptAt,
    required String status,
  }) async {
    _ensureActive();
    await db.updateOutboxAttempt(
      messageId,
      attempts: attempts,
      lastAttemptAt: lastAttemptAt,
      status: status,
    );
    _ensureActive();
  }

  Future<List<OutboxRecord>> getUndeliveredMessagesForPeer(String recipientNostrPubKey) async {
    _ensureActive();
    final records = await db.getUndeliveredMessagesForPeer(recipientNostrPubKey);
    _ensureActive();
    return records;
  }

  Future<void> updateOutboxStatus(
    String messageId, {
    required String status,
    int? attempts,
    DateTime? lastAttemptAt,
  }) async {
    _ensureActive();
    await db.updateOutboxStatus(
      messageId,
      status: status,
      attempts: attempts,
      lastAttemptAt: lastAttemptAt,
    );
    _ensureActive();
  }
}
