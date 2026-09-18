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
    // Safety buffer: subtract 5 minutes to prevent missing messages due to clock skew or delayed relay ingestion
    final adjustedTimestamp = latestTimestamp?.subtract(const Duration(minutes: 5));
    
    _globalMessageSubscription?.cancel();
    _globalMessageSubscription = NostrRelayService().listenForIncomingMessages(since: adjustedTimestamp).listen(_handleIncomingNostrEvent);
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

  Future<void> updateChatUserProfile({
    required String masterPubKeyHex,
    required String username,
    String? displayName,
    String? bio,
  }) async {
    final index = activeChats.indexWhere((u) => u.masterPubKeyHex == masterPubKeyHex);
    if (index != -1) {
      final user = activeChats[index];
      bool changed = false;

      // Only upgrade if incoming username is real (never overwrite a real username with a Ghost name)
      if (username.isNotEmpty && !username.startsWith('Ghost #') && user.username != username) {
        user.username = username;
        changed = true;
      }
      if (displayName != null && displayName.isNotEmpty && user.displayName != displayName) {
        user.displayName = displayName;
        changed = true;
      }
      if (bio != null && bio.isNotEmpty && user.bio != bio) {
        user.bio = bio;
        changed = true;
      }

      if (changed) {
        await chatRepo.saveChat(user);
        notifyListeners();
      }
    }
  }

  void updateUserPresence({
    required String masterPubKeyHex,
    String? nostrPubKeyHex,
    required bool isOnline,
    required DateTime lastSeen,
  }) {
    final index = activeChats.indexWhere((u) => 
      (masterPubKeyHex.isNotEmpty && u.masterPubKeyHex == masterPubKeyHex) ||
      (nostrPubKeyHex != null && nostrPubKeyHex.isNotEmpty && u.nostrPubKeyHex == nostrPubKeyHex)
    );
    if (index != -1) {
      final user = activeChats[index];
      user.isExplicitlyOffline = !isOnline;
      if (isOnline) {
        user.lastSeen = lastSeen;
        user.lastSeenFromPing = lastSeen;
      } else {
        user.lastSeenFromPing = null;
        user.lastSeenFromMessage = null;
      }
      notifyListeners();
    }
  }

  void refreshPresence() {
    notifyListeners();
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
        
        if (plaintext == "__SESSION_RESET__") {
          print("DEBUG: Received session reset from $senderNostrPubKey. Deleting local session.");
          await signalService!.deleteSession(senderNostrPubKey);
          return;
        }
        
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
          String? displayProfileName;
          final profileMap = await NostrRelayService().fetchUserProfile(senderNostrPubKey);
          if (profileMap != null && profileMap['name'] != null && profileMap['name'].toString().isNotEmpty) {
            displayUsername = profileMap['name'].toString();
            displayProfileName = profileMap['displayName']?.toString();
          }
          
          addChat(DiscoverUser(
            masterPubKeyHex: masterPubKeyToVerify,
            nostrPubKeyHex: senderNostrPubKey,
            username: displayUsername,
            displayName: displayProfileName,
            lastSeen: DateTime.now(),
            lastSeenFromMessage: DateTime.now(),
          ));
        } else {
          // If already in active chats and currently shown as Ghost, attempt to resolve their profile
          try {
            final existing = activeChats.firstWhere((u) => u.nostrPubKeyHex == senderNostrPubKey);
            if (existing.username.startsWith('Ghost #')) {
              final profileMap = await NostrRelayService().fetchUserProfile(senderNostrPubKey);
              if (profileMap != null && profileMap['name'] != null && profileMap['name'].toString().isNotEmpty) {
                await updateChatUserProfile(
                  masterPubKeyHex: existing.masterPubKeyHex,
                  username: profileMap['name'].toString(),
                  displayName: profileMap['displayName']?.toString(),
                );
              }
            }
          } catch (_) {}
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
