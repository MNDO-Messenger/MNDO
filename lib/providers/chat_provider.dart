import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:dart_nostr/dart_nostr.dart';
import '../models/discover_user.dart';
import '../models/chat_message.dart';
import '../repositories/chat_repository.dart';
import '../services/nostr_relay_service.dart';
import '../services/signal_messaging_service.dart';
import '../providers/auth_provider.dart';

class ChatProvider extends ChangeNotifier {
  ChatRepository chatRepo;
  AuthProvider authProvider;
  SignalMessagingService? signalService;
  
  List<DiscoverUser> activeChats = [];
  Map<String, List<ChatMessage>> chatHistories = {};
  Map<String, int> unreadCounts = {};
  String? activeChatUserId;
  
  StreamSubscription<NostrEvent>? _globalMessageSubscription;
  
  ChatProvider({
    required this.chatRepo,
    required this.authProvider,
    required this.signalService,
  });

  void updateDependencies(ChatRepository newRepo, AuthProvider newAuth, SignalMessagingService? newSignal) {
    chatRepo = newRepo;
    authProvider = newAuth;
    signalService = newSignal;
  }

  Future<void> loadInitialData() async {
    activeChats = await chatRepo.getAllChats();
    for (final user in activeChats) {
      chatHistories[user.nostrPubKeyHex] = await chatRepo.getMessagesForChat(user.nostrPubKeyHex);
    }
    notifyListeners();
  }

  Future<void> startListeningForMessages() async {
    await NostrRelayService().connectToRelays(); // Ensure we are connected!
    
    // Fetch timestamp of the latest message we have locally to sync offline messages
    final latestTimestamp = await chatRepo.getLatestMessageTimestamp();
    
    _globalMessageSubscription?.cancel();
    _globalMessageSubscription = NostrRelayService().listenForIncomingMessages(since: latestTimestamp).listen(_handleIncomingNostrEvent);
  }

  void stopListening() {
    _globalMessageSubscription?.cancel();
  }

  void addChat(DiscoverUser user) async {
    if (!activeChats.any((u) => u.masterPubKeyHex == user.masterPubKeyHex)) {
      activeChats.add(user);
      await chatRepo.saveChat(user);
      notifyListeners();
    }
  }

  void addMessage(String nostrPubKey, ChatMessage message) async {
    if (!chatHistories.containsKey(nostrPubKey)) {
      chatHistories[nostrPubKey] = [];
    }
    chatHistories[nostrPubKey]!.add(message);
    
    await chatRepo.saveMessage(nostrPubKey, message);
    
    if (activeChatUserId != nostrPubKey && !message.isMe) {
      unreadCounts[nostrPubKey] = (unreadCounts[nostrPubKey] ?? 0) + 1;
    }
    
    notifyListeners();
  }

  void markChatAsRead(String nostrPubKey) {
    activeChatUserId = nostrPubKey;
    unreadCounts.remove(nostrPubKey);
    notifyListeners();
  }
  
  void clearActiveChat() {
    activeChatUserId = null;
  }

  Future<void> _handleIncomingNostrEvent(NostrEvent event) async {
    if (signalService == null) return;
    
    final senderNostrPubKey = event.pubkey;
    print("DEBUG: Received incoming event kind ${event.kind} from $senderNostrPubKey. Content length: ${event.content?.length}");
    
    if (event.kind == 4444 && event.content != null) {
      print("DEBUG: Event is 4444. Attempting to parse JSON...");
      Map<String, dynamic> map;
      try {
        map = jsonDecode(event.content!);
      } catch (e) {
        print("DEBUG: JSON parsing failed: $e");
        return;
      }
      
      print("DEBUG: Attempting to decrypt message...");
      final result = await signalService!.decryptMessage(senderNostrPubKey, map);
      
      if (result != null) {
        print("DEBUG: Decryption successful!");
        final plaintext = result.$1;
        final senderMasterPubKeyFromPayload = result.$2;
        
        if (plaintext == "__SESSION_RESET__") return;
        
        String masterPubKeyToVerify = senderMasterPubKeyFromPayload;
        if (masterPubKeyToVerify.isEmpty) {
          try {
            final user = activeChats.firstWhere((u) => u.nostrPubKeyHex == senderNostrPubKey);
            masterPubKeyToVerify = user.masterPubKeyHex;
          } catch (_) {
            return; // Unknown user and no master key provided
          }
        }
        
        if (!activeChats.any((u) => u.nostrPubKeyHex == senderNostrPubKey)) {
          String displayUsername = "Ghost #${masterPubKeyToVerify.substring(0, 4)}";
          final profileMap = await NostrRelayService().fetchUserProfile(senderNostrPubKey);
          if (profileMap != null && profileMap['name'] != null) {
            displayUsername = profileMap['name'];
          }
          
          addChat(DiscoverUser(
            masterPubKeyHex: masterPubKeyToVerify,
            nostrPubKeyHex: senderNostrPubKey,
            username: displayUsername,
            lastSeen: DateTime.now(),
            lastSeenFromMessage: DateTime.now(),
          ));
        }
        
        try {
          final existingUser = activeChats.firstWhere((u) => u.nostrPubKeyHex == senderNostrPubKey);
          existingUser.lastSeen = DateTime.now();
          existingUser.lastSeenFromMessage = DateTime.now();
        } catch (_) {}
        
        addMessage(senderNostrPubKey, ChatMessage(
          text: plaintext,
          isMe: false,
          timestamp: DateTime.now(),
        ));
      }
    }
  }

  Future<void> clearAll() async {
    await chatRepo.clearAll();
    activeChats.clear();
    chatHistories.clear();
    unreadCounts.clear();
    activeChatUserId = null;
    notifyListeners();
  }
}
