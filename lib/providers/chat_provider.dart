import 'dart:async';
import 'dart:convert';
import 'dart:io' show File;
import 'package:flutter/foundation.dart';
import 'package:dart_nostr/dart_nostr.dart';
import '../models/discover_user.dart';
import '../models/chat_message.dart';
import '../repositories/chat_repository.dart';
import '../services/nostr_relay_service.dart';
import '../services/signal_messaging_service.dart';
import '../services/voice_note_service.dart';
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

  DateTime getLatestMessageTimestamp(String nostrPubKey) {
    final history = chatHistories[nostrPubKey];
    if (history != null && history.isNotEmpty) {
      return history.last.timestamp;
    }
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  void _sortActiveChats() {
    activeChats.sort((a, b) {
      final timeA = getLatestMessageTimestamp(a.nostrPubKeyHex);
      final timeB = getLatestMessageTimestamp(b.nostrPubKeyHex);
      if (timeA != timeB) {
        return timeB.compareTo(timeA); // Newest message person on top
      }
      return b.lastSeen.compareTo(a.lastSeen);
    });
  }

  Future<void> loadInitialData() async {
    activeChats = await chatRepo.getAllChats();
    for (final user in activeChats) {
      final msgs = await chatRepo.getMessagesForChat(user.nostrPubKeyHex);
      msgs.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      chatHistories[user.nostrPubKeyHex] = msgs;
    }
    _sortActiveChats();
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
      activeChats.insert(0, user);
      await chatRepo.saveChat(user);
      _sortActiveChats();
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
    final history = chatHistories[nostrPubKey]!;

    // Deduplication check: prevent duplicate bubbles if multiple relays send the same event
    final isDuplicate = history.any((m) =>
      m.isMe == message.isMe &&
      m.text == message.text &&
      m.timestamp.millisecondsSinceEpoch == message.timestamp.millisecondsSinceEpoch
    );
    if (isDuplicate) return;

    history.add(message);
    history.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    
    await chatRepo.saveMessage(nostrPubKey, message);
    
    if (activeChatUserId != nostrPubKey && !message.isMe) {
      unreadCounts[nostrPubKey] = (unreadCounts[nostrPubKey] ?? 0) + 1;
    }
    
    _sortActiveChats();
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
        final sentAt = result.$3;
        
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

        // Determine message timestamp from sender's payload, falling back to event.createdAt or now
        DateTime messageTimestamp = sentAt ?? event.createdAt ?? DateTime.now();
        final voicePayload = VoiceNotePayload.tryParse(plaintext);
        if (voicePayload != null && voicePayload.sentAt != null) {
          messageTimestamp = DateTime.fromMillisecondsSinceEpoch(voicePayload.sentAt!);
        }
        
        if (!activeChats.any((u) => u.nostrPubKeyHex == senderNostrPubKey)) {
          final displayUsername = "Ghost #${masterPubKeyToVerify.substring(0, 4)}";
          
          addChat(DiscoverUser(
            masterPubKeyHex: masterPubKeyToVerify,
            nostrPubKeyHex: senderNostrPubKey,
            username: displayUsername,
            displayName: null,
            lastSeen: messageTimestamp,
            lastSeenFromMessage: messageTimestamp,
          ));
        }
        
        try {
          final existingUser = activeChats.firstWhere((u) => u.nostrPubKeyHex == senderNostrPubKey);
          existingUser.lastSeen = messageTimestamp;
          existingUser.lastSeenFromMessage = messageTimestamp;
        } catch (_) {}
        
        addMessage(senderNostrPubKey, ChatMessage(
          text: plaintext,
          isMe: false,
          timestamp: messageTimestamp,
          status: MessageStatus.sent,
        ));
      }
    }
  }

  Future<bool> sendOutgoingMessage(String recipientNostrPubKey, String text, {DateTime? sentAt}) async {
    final timestamp = sentAt ?? DateTime.now();
    final message = ChatMessage(
      text: text,
      isMe: true,
      timestamp: timestamp,
      status: MessageStatus.sending,
    );

    addMessage(recipientNostrPubKey, message);

    try {
      if (signalService == null) throw StateError("Signal service not initialized");
      await signalService!.sendMessage(recipientNostrPubKey, text, sentAt: timestamp);
      message.status = MessageStatus.sent;
      notifyListeners();
      return true;
    } catch (e) {
      print("Error sending message: $e");
      message.status = MessageStatus.failed;
      notifyListeners();
      return false;
    }
  }

  Future<bool> sendOutgoingVoiceNote({
    required String recipientNostrPubKey,
    required String localAudioPath,
    required int durationMs,
    required List<int> waveform,
    DateTime? sentAt,
  }) async {
    final timestamp = sentAt ?? DateTime.now();

    // 1. Locally encrypt with AES-256-GCM in ~3ms to generate the full decryption treasure map
    final prepared = await VoiceNoteService().prepareAndEncryptVoiceNote(
      localAudioPath: localAudioPath,
      durationMs: durationMs,
      waveform: waveform,
      sentAt: timestamp.millisecondsSinceEpoch,
    );

    if (prepared == null) {
      return false;
    }

    final payload = prepared.payload;
    final encryptedBytes = prepared.encryptedBytes;

    final message = ChatMessage(
      text: payload.serialize(),
      isMe: true,
      timestamp: timestamp,
      status: MessageStatus.sending,
    );

    // 2. Add message to sender's memory history immediately
    if (!chatHistories.containsKey(recipientNostrPubKey)) {
      chatHistories[recipientNostrPubKey] = [];
    }
    final history = chatHistories[recipientNostrPubKey]!;
    history.add(message);
    history.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    notifyListeners();

    // 3. INSTANT SIGNAL TRANSMISSION!
    // Send the voice note payload (duration, waveform, sentAt, decryption keys) to the recipient
    // IMMEDIATELY so the recipient receives it right now in the exact chronological order!
    try {
      if (signalService == null) throw StateError("Signal service not initialized");
      await signalService!.sendMessage(
        recipientNostrPubKey,
        payload.serializeForNetwork(),
        sentAt: timestamp,
      );
    } catch (e) {
      print("Error transmitting voice note over Signal: $e");
      message.status = MessageStatus.failed;
      notifyListeners();
      return false;
    }

    // 4. Upload encrypted bytes to Blossom servers in the background
    unawaited(() async {
      try {
        final uploadUrl = await VoiceNoteService().uploadEncryptedBytes(
          encryptedBytes,
          payload.fileHash,
        );

        if (uploadUrl != null) {
          message.status = MessageStatus.sent;
          await chatRepo.saveMessage(recipientNostrPubKey, message);
        } else {
          message.status = MessageStatus.failed;
        }
      } catch (e) {
        print("Error uploading voice note to Blossom in background: $e");
        message.status = MessageStatus.failed;
      } finally {
        notifyListeners();
      }
    }());

    return true;
  }

  Future<bool> retryOutgoingMessage(String recipientNostrPubKey, ChatMessage message) async {
    if (!message.isMe) return false;

    // Check if this is a voice note
    final voicePayload = VoiceNotePayload.tryParse(message.text);
    if (voicePayload != null) {
      message.status = MessageStatus.sending;
      notifyListeners();

      try {
        VoiceNotePayload readyPayload = voicePayload;

        // If local audio file is still on device, re-encrypt/prepare if necessary
        if (voicePayload.localPath != null && File(voicePayload.localPath!).existsSync()) {
          final prepared = await VoiceNoteService().prepareAndEncryptVoiceNote(
            localAudioPath: voicePayload.localPath!,
            durationMs: voicePayload.durationMs,
            waveform: voicePayload.waveform,
            sentAt: message.timestamp.millisecondsSinceEpoch,
          );

          if (prepared != null) {
            readyPayload = prepared.payload;
            message.text = readyPayload.serialize();

            // Background Blossom upload verification
            final uploadResult = await VoiceNoteService().uploadEncryptedBytes(
              prepared.encryptedBytes,
              readyPayload.fileHash,
            );
            if (uploadResult == null) {
              message.status = MessageStatus.failed;
              notifyListeners();
              return false;
            }
          }
        }

        // Transmit via Signal ratchet
        if (signalService == null) throw StateError("Signal service not initialized");
        await signalService!.sendMessage(
          recipientNostrPubKey,
          readyPayload.serializeForNetwork(),
          sentAt: message.timestamp,
        );

        message.status = MessageStatus.sent;
        await chatRepo.saveMessage(recipientNostrPubKey, message);
        notifyListeners();
        return true;
      } catch (e) {
        print("Error retrying voice note: $e");
        message.status = MessageStatus.failed;
        notifyListeners();
        return false;
      }
    }

    // Regular text message retry
    message.status = MessageStatus.sending;
    notifyListeners();

    try {
      if (signalService == null) throw StateError("Signal service not initialized");
      await signalService!.sendMessage(recipientNostrPubKey, message.text, sentAt: message.timestamp);
      message.status = MessageStatus.sent;
      notifyListeners();
      return true;
    } catch (e) {
      print("Error retrying message: $e");
      message.status = MessageStatus.failed;
      notifyListeners();
      return false;
    }
  }

  void clearAllMemory() {
    activeChats.clear();
    chatHistories.clear();
    unreadCounts.clear();
    activeChatUserId = null;
    notifyListeners();
  }

  Future<void> clearAll() async {
    await chatRepo.clearAll();
    clearAllMemory();
  }
}

