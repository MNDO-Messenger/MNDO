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
import '../models/mndo_message_envelope.dart';

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
    // Safety buffer: look back at least 7 days (or 30 days if no latestTimestamp) so that clock skew
    // between peers (which can be hours or days) never causes relays to drop incoming messages or receipts!
    final adjustedTimestamp = latestTimestamp != null
        ? latestTimestamp.subtract(const Duration(days: 7))
        : DateTime.now().subtract(const Duration(days: 30));
    
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
      if (nostrPubKeyHex != null && nostrPubKeyHex.isNotEmpty && user.nostrPubKeyHex != nostrPubKeyHex) {
        final oldKey = user.nostrPubKeyHex;
        user.nostrPubKeyHex = nostrPubKeyHex;
        if (chatHistories.containsKey(oldKey)) {
          final existingHistory = chatHistories[nostrPubKeyHex] ?? [];
          final oldHistory = chatHistories.remove(oldKey)!;
          chatHistories[nostrPubKeyHex] = [...oldHistory, ...existingHistory];
        }
      }
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

  Future<void> addMessage(String nostrPubKey, ChatMessage message) async {
    if (!chatHistories.containsKey(nostrPubKey)) {
      chatHistories[nostrPubKey] = [];
    }
    final history = chatHistories[nostrPubKey]!;

    // Deduplication check: prevent duplicate bubbles if multiple relays send the same event
    final isDuplicate = history.any((m) =>
      m.messageId == message.messageId ||
      (m.isMe == message.isMe &&
       m.text == message.text &&
       m.timestamp.millisecondsSinceEpoch == message.timestamp.millisecondsSinceEpoch)
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

  Future<void> sendReceipt({
    required String recipientNostrPubKey,
    required String targetMessageId,
    required String status,
  }) async {
    try {
      if (signalService == null) return;
      await signalService!.sendMessage(
        recipientNostrPubKey,
        '',
        type: 'receipt',
        extraBody: {
          'targetId': targetMessageId,
          'status': status,
        },
      );
    } catch (e) {
      print("DEBUG: sendReceipt error: $e");
    }
  }

  Future<void> markChatAsRead(String nostrPubKey) async {
    activeChatUserId = nostrPubKey;
    unreadCounts.remove(nostrPubKey);

    if (!chatHistories.containsKey(nostrPubKey)) {
      final msgs = await chatRepo.getMessagesForChat(nostrPubKey);
      msgs.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      chatHistories[nostrPubKey] = msgs;
    }

    // Target #9: Send read receipts for incoming messages that are not yet marked read
    final history = chatHistories[nostrPubKey];
    if (history != null) {
      for (final msg in history.where((m) => !m.isMe && m.status != MessageStatus.read)) {
        msg.status = MessageStatus.read;
        unawaited(chatRepo.updateMessageStatus(msg.messageId, MessageStatus.read));
        unawaited(sendReceipt(
          recipientNostrPubKey: nostrPubKey,
          targetMessageId: msg.messageId,
          status: 'read',
        ));
      }
    }
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
        final incomingMsgId = result.$4;
        final isIdentityKeyChanged = result.$5;

        // Target #1: Visual Security Alert on peer identity key change
        if (isIdentityKeyChanged) {
          addMessage(senderNostrPubKey, ChatMessage(
            text: "⚠️ Security Notice: Peer's Signal identity key changed. End-to-end session re-established.",
            isMe: false,
            timestamp: DateTime.now(),
            status: MessageStatus.sent,
          ));
        }
        
        if (plaintext == "__SESSION_RESET__") {
          print("DEBUG: Received session reset from $senderNostrPubKey. Deleting local session.");
          await signalService!.deleteSession(senderNostrPubKey);
          return;
        }

        // Target #9: Process receipt envelopes without creating chat bubbles
        final receiptEnvelope = MndoMessageEnvelope.tryParse(plaintext);
        if (receiptEnvelope != null && receiptEnvelope.type == 'receipt') {
          final targetId = receiptEnvelope.body['targetId'] as String?;
          final statusStr = receiptEnvelope.body['status'] as String?;
          if (targetId != null && statusStr != null) {
            ChatMessage? targetMsg;
            final directHistory = chatHistories[senderNostrPubKey];
            if (directHistory != null) {
              targetMsg = directHistory.where((m) => m.messageId == targetId).firstOrNull;
            }
            if (targetMsg == null) {
              for (final history in chatHistories.values) {
                targetMsg = history.where((m) => m.messageId == targetId).firstOrNull;
                if (targetMsg != null) break;
              }
            }

            if (statusStr == 'read') {
              if (targetMsg != null) {
                targetMsg.status = MessageStatus.read;
              }
              await chatRepo.updateMessageStatus(targetId, MessageStatus.read);
              notifyListeners();
            } else if (statusStr == 'delivered') {
              if (targetMsg != null && targetMsg.status != MessageStatus.read) {
                targetMsg.status = MessageStatus.delivered;
                await chatRepo.updateMessageStatus(targetId, MessageStatus.delivered);
                notifyListeners();
              } else if (targetMsg == null) {
                await chatRepo.updateMessageStatus(targetId, MessageStatus.delivered);
              }
            }
          }
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
        
        final receptionTime = DateTime.now();
        if (!activeChats.any((u) => u.nostrPubKeyHex == senderNostrPubKey)) {
          final displayUsername = "Ghost #${masterPubKeyToVerify.substring(0, 4)}";
          
          addChat(DiscoverUser(
            masterPubKeyHex: masterPubKeyToVerify,
            nostrPubKeyHex: senderNostrPubKey,
            username: displayUsername,
            displayName: null,
            lastSeen: receptionTime,
            lastSeenFromMessage: receptionTime,
          ));
        }
        
        try {
          final existingUser = activeChats.firstWhere((u) => u.nostrPubKeyHex == senderNostrPubKey);
          existingUser.lastSeen = receptionTime;
          existingUser.lastSeenFromMessage = receptionTime;
          existingUser.isExplicitlyOffline = false;
        } catch (_) {}
        
        addMessage(senderNostrPubKey, ChatMessage(
          messageId: incomingMsgId,
          text: plaintext,
          isMe: false,
          timestamp: messageTimestamp,
          status: MessageStatus.sent,
        ));

        // Target #9: Dispatch automatic delivery receipt
        if (incomingMsgId != null) {
          unawaited(sendReceipt(
            recipientNostrPubKey: senderNostrPubKey,
            targetMessageId: incomingMsgId,
            status: activeChatUserId == senderNostrPubKey ? 'read' : 'delivered',
          ));
        }
      }
    }
  }

  Future<bool> sendOutgoingMessage(
    String recipientNostrPubKey, 
    String text, {
    DateTime? sentAt,
    String? replyToId,
  }) async {
    final timestamp = sentAt ?? DateTime.now();
    final message = ChatMessage(
      text: text,
      isMe: true,
      timestamp: timestamp,
      status: MessageStatus.sending,
      replyToId: replyToId,
    );

    await addMessage(recipientNostrPubKey, message);

    try {
      if (signalService == null) throw StateError("Signal service not initialized");
      await signalService!.sendMessage(
        recipientNostrPubKey,
        text,
        sentAt: timestamp,
        messageId: message.messageId,
        type: 'text',
        replyToId: replyToId,
      );
      if (message.status == MessageStatus.sending) {
        message.status = MessageStatus.sent;
        await chatRepo.updateMessageStatus(message.messageId, MessageStatus.sent);
        notifyListeners();
      }
      return true;
    } catch (e) {
      print("Error sending message: $e");
      if (message.status == MessageStatus.sending) {
        message.status = MessageStatus.failed;
        await chatRepo.updateMessageStatus(message.messageId, MessageStatus.failed);
        notifyListeners();
      }
      return false;
    }
  }

  Future<bool> sendOutgoingVoiceNote({
    required String recipientNostrPubKey,
    required String localAudioPath,
    required int durationMs,
    required List<int> waveform,
    DateTime? sentAt,
    String? replyToId,
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
      replyToId: replyToId,
    );

    // 2. Add message to sender's memory and local DB immediately
    await addMessage(recipientNostrPubKey, message);

    // 3. Target #6: ATOMIC MEDIA PIPELINE - Upload encrypted bytes to Blossom FIRST
    // Guarantees recipient will never receive a voice note notification before the blob is available!
    try {
      final uploadUrl = await VoiceNoteService().uploadEncryptedBytes(
        encryptedBytes,
        payload.fileHash,
      );

      if (uploadUrl == null) {
        if (message.status == MessageStatus.sending) {
          message.status = MessageStatus.failed;
          await chatRepo.updateMessageStatus(message.messageId, MessageStatus.failed);
          notifyListeners();
        }
        return false;
      }
    } catch (e) {
      print("Error uploading voice note to Blossom: $e");
      if (message.status == MessageStatus.sending) {
        message.status = MessageStatus.failed;
        await chatRepo.updateMessageStatus(message.messageId, MessageStatus.failed);
        notifyListeners();
      }
      return false;
    }

    // 4. Blossom upload confirmed! Transmit Signal payload
    try {
      if (signalService == null) throw StateError("Signal service not initialized");
      await signalService!.sendMessage(
        recipientNostrPubKey,
        payload.serializeForNetwork(),
        sentAt: timestamp,
        messageId: message.messageId,
        type: 'voice_note',
        extraBody: {'fileHash': payload.fileHash},
        replyToId: replyToId,
      );
      if (message.status == MessageStatus.sending) {
        message.status = MessageStatus.sent;
        await chatRepo.updateMessageStatus(message.messageId, MessageStatus.sent);
        notifyListeners();
      }
      return true;
    } catch (e) {
      print("Error transmitting voice note over Signal: $e");
      if (message.status == MessageStatus.sending) {
        message.status = MessageStatus.failed;
        await chatRepo.updateMessageStatus(message.messageId, MessageStatus.failed);
        notifyListeners();
      }
      return false;
    }
  }

  Future<bool> retryOutgoingMessage(String recipientNostrPubKey, ChatMessage message) async {
    if (!message.isMe) return false;

    // Check if this is a voice note
    final voicePayload = VoiceNotePayload.tryParse(message.text);
    if (voicePayload != null) {
      message.status = MessageStatus.sending;
      await chatRepo.updateMessageStatus(message.messageId, MessageStatus.sending);
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
              if (message.status == MessageStatus.sending) {
                message.status = MessageStatus.failed;
                await chatRepo.updateMessageStatus(message.messageId, MessageStatus.failed);
                notifyListeners();
              }
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
          messageId: message.messageId,
          type: 'voice_note',
          extraBody: {'fileHash': readyPayload.fileHash},
          replyToId: message.replyToId,
        );

        if (message.status == MessageStatus.sending) {
          message.status = MessageStatus.sent;
          await chatRepo.updateMessageStatus(message.messageId, MessageStatus.sent);
          notifyListeners();
        }
        return true;
      } catch (e) {
        print("Error retrying voice note: $e");
        if (message.status == MessageStatus.sending) {
          message.status = MessageStatus.failed;
          await chatRepo.updateMessageStatus(message.messageId, MessageStatus.failed);
          notifyListeners();
        }
        return false;
      }
    }

    // Regular text message retry
    message.status = MessageStatus.sending;
    await chatRepo.updateMessageStatus(message.messageId, MessageStatus.sending);
    notifyListeners();

    try {
      if (signalService == null) throw StateError("Signal service not initialized");
      await signalService!.sendMessage(
        recipientNostrPubKey,
        message.text,
        sentAt: message.timestamp,
        messageId: message.messageId,
        type: 'text',
        replyToId: message.replyToId,
      );
      if (message.status == MessageStatus.sending) {
        message.status = MessageStatus.sent;
        await chatRepo.updateMessageStatus(message.messageId, MessageStatus.sent);
        notifyListeners();
      }
      return true;
    } catch (e) {
      print("Error retrying message: $e");
      if (message.status == MessageStatus.sending) {
        message.status = MessageStatus.failed;
        await chatRepo.updateMessageStatus(message.messageId, MessageStatus.failed);
        notifyListeners();
      }
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

