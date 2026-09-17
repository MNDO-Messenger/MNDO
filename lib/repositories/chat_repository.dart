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
      lastSeen: chat.lastSeen,
    )).toList();
  }

  Future<void> saveChat(DiscoverUser user) async {
    await db.insertChat(ActiveChatsCompanion.insert(
      masterPubKeyHex: user.masterPubKeyHex,
      nostrPubKeyHex: user.nostrPubKeyHex,
      username: user.username,
      lastSeen: user.lastSeen,
    ));
  }

  Future<List<ChatMessage>> getMessagesForChat(String nostrPubKey) async {
    final messages = await db.getMessagesForChat(nostrPubKey);
    return messages.map((m) => ChatMessage(
      text: m.messageText,
      isMe: m.isMe,
      timestamp: m.timestamp,
    )).toList();
  }

  Future<void> saveMessage(String nostrPubKey, ChatMessage message) async {
    await db.insertMessage(ChatMessagesCompanion.insert(
      nostrPubKeyHex: nostrPubKey,
      messageText: message.text,
      isMe: message.isMe,
      timestamp: message.timestamp,
    ));
  }

  Future<void> clearAll() async {
    await db.clearChats();
    await db.clearMessages();
  }

  Future<DateTime?> getLatestMessageTimestamp() async {
    return await db.getLatestMessageTimestamp();
  }
}
