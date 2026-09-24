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

  Future<void> clearAll() async {
    await db.clearChats();
    await db.clearMessages();
  }

  Future<DateTime?> getLatestMessageTimestamp() async {
    return await db.getLatestMessageTimestamp();
  }
}
