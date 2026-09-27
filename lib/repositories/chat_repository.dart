import 'package:drift/drift.dart';
import '../database/database.dart';
import '../models/discover_user.dart';
import '../models/chat_message.dart';

class ChatRepository {
  final AppDatabase db;
  
  ChatRepository(this.db);

  Future<List<DiscoverUser>> getAllChats() async {
    final savedChats = await db.getAllChats();
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
    await db.insertChat(ActiveChatsCompanion(
      masterPubKeyHex: Value(user.masterPubKeyHex),
      nostrPubKeyHex: Value(user.nostrPubKeyHex),
      username: Value(user.username),
      displayName: Value(user.displayName),
      bio: Value(user.bio),
      lastSeen: Value(user.lastSeen),
    ));
  }

  Future<List<ChatMessage>> getMessagesForChat(String nostrPubKey) async {
    final messages = await db.getMessagesForChat(nostrPubKey);
    return messages.map((m) {
      MessageStatus status = MessageStatus.sent;
      try {
        status = MessageStatus.values.byName(m.status);
      } catch (_) {}
      // If a message was left in 'sending' state across app restarts, recover as failed so user can tap to retry
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
    await db.insertMessage(ChatMessagesCompanion.insert(
      messageId: Value(message.messageId),
      nostrPubKeyHex: nostrPubKey,
      messageText: message.text,
      isMe: message.isMe,
      timestamp: message.timestamp,
      status: Value(message.status.name),
      replyToId: Value(message.replyToId),
    ));
  }

  Future<void> updateMessageStatus(String messageId, MessageStatus status) async {
    await db.updateMessageStatus(messageId, status.name);
  }

  Future<ChatMessageRecord?> getMessageByMessageId(String messageId) async {
    return await db.getMessageByMessageId(messageId);
  }

  Future<int> markMessagesReadUpTo(String peerNostrPubKey, DateTime timestamp) async {
    return await db.markMessagesReadUpTo(peerNostrPubKey, timestamp);
  }

  Future<void> clearAll() async {
    await db.clearChats();
    await db.clearMessages();
    await db.clearOutbox();
  }

  Future<DateTime?> getLatestMessageTimestamp() async {
    return await db.getLatestMessageTimestamp();
  }

  // Outbox operations
  Future<void> enqueueOutbox({
    required String messageId,
    required String recipientNostrPubKey,
    required String payloadJson,
    DateTime? createdAt,
  }) async {
    final now = createdAt ?? DateTime.now();
    await db.enqueueOutboxMessage(OutboxMessagesCompanion.insert(
      messageId: messageId,
      recipientNostrPubKey: recipientNostrPubKey,
      payloadJson: payloadJson,
      createdAt: now,
      status: const Value('pending'),
    ));
  }

  Future<List<OutboxRecord>> getPendingOutboxMessages() async {
    return await db.getPendingOutboxMessages();
  }

  Future<OutboxRecord?> getOutboxRecord(String messageId) async {
    return await db.getOutboxMessage(messageId);
  }

  Future<void> deleteFromOutbox(String messageId) async {
    await db.deleteOutboxMessage(messageId);
  }

  Future<void> updateOutboxAttempt(
    String messageId, {
    required int attempts,
    required DateTime lastAttemptAt,
    required String status,
  }) async {
    await db.updateOutboxAttempt(
      messageId,
      attempts: attempts,
      lastAttemptAt: lastAttemptAt,
      status: status,
    );
  }

  Future<List<OutboxRecord>> getUndeliveredMessagesForPeer(String recipientNostrPubKey) async {
    return await db.getUndeliveredMessagesForPeer(recipientNostrPubKey);
  }

  Future<void> updateOutboxStatus(
    String messageId, {
    required String status,
    int? attempts,
    DateTime? lastAttemptAt,
  }) async {
    await db.updateOutboxStatus(
      messageId,
      status: status,
      attempts: attempts,
      lastAttemptAt: lastAttemptAt,
    );
  }
}
