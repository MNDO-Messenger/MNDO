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
import '../services/master_binding_verifier.dart';
import '../services/voice_note_service.dart';
import '../providers/auth_provider.dart';
import '../models/mndo_message_envelope.dart';
import '../services/account_session.dart';

class ChatProvider extends ChangeNotifier {
  ChatRepository chatRepo;
  AuthProvider authProvider;
  SignalMessagingService? signalService;
  
  List<DiscoverUser> activeChats = [];
  Map<String, List<ChatMessage>> chatHistories = {};
  Map<String, int> unreadCounts = {};
  String? activeChatUserId;
  bool isAppFocused = true; // Track whether the app window is focused/visible
  
  // Cooldown map to prevent RESET_SESSION storms (peer key → last reset timestamp)
  final Map<String, DateTime> _lastResetTimestamps = {};
  
  // Track the latest message ID for which a read receipt was dispatched per peer
  final Map<String, String> _lastReadReceiptSentMsgId = {};
  
  StreamSubscription<NostrEvent>? _globalMessageSubscription;
  Timer? _outboxDrainTimer;
  final Map<String, DateTime> _lastPeerRetryTime = {};
  MasterBindingVerifier masterBindingVerifier;
  
  ChatProvider({
    required this.chatRepo,
    required this.authProvider,
    required this.signalService,
    MasterBindingVerifier? masterBindingVerifier,
  }) : masterBindingVerifier = masterBindingVerifier ?? MasterBindingVerifier(cryptoService: authProvider.cryptoService) {
    _bindSignalService();
  }

  void updateDependencies(ChatRepository newRepo, AuthProvider newAuth, SignalMessagingService? newSignal) {
    chatRepo = newRepo;
    authProvider = newAuth;
    signalService = newSignal;
    masterBindingVerifier = MasterBindingVerifier(cryptoService: newAuth.cryptoService);
    _bindSignalService();
  }

  void _bindSignalService() {
    if (signalService != null) {
      signalService!.onIdentityKeyChanged = (peerNostrPubKey) {
        handlePeerIdentityKeyChanged(peerNostrPubKey);
      };
    }
  }

  final Set<String> _blockedIdentityPeers = {};
  bool isPeerIdentityBlocked(String peerNostrPubKey) {
    if (_blockedIdentityPeers.contains(peerNostrPubKey)) return true;
    final aliased = _keyAliases[peerNostrPubKey];
    if (aliased != null && _blockedIdentityPeers.contains(aliased)) return true;
    return (signalService?.isIdentityBlocked(peerNostrPubKey) ?? false) ||
           (aliased != null && (signalService?.isIdentityBlocked(aliased) ?? false));
  }

  /// Authoritative check across all sending paths:
  /// Verifies peer is not identity-blocked and an active encryption session exists
  Future<bool> canSendToPeer(String peerNostrPubKey) async {
    if (isPeerIdentityBlocked(peerNostrPubKey)) return false;
    if (signalService == null) return false;
    final canDirect = await signalService!.canSendToPeer(peerNostrPubKey);
    if (canDirect) return true;
    final aliased = _keyAliases[peerNostrPubKey];
    if (aliased != null && !isPeerIdentityBlocked(aliased)) {
      return await signalService!.canSendToPeer(aliased);
    }
    return false;
  }

  Future<void> handlePeerIdentityKeyChanged(String peerNostrPubKey) async {
    _blockedIdentityPeers.add(peerNostrPubKey);
    final history = chatHistories[peerNostrPubKey];
    final lastNotice = history?.where((m) => m.text.contains("Peer's Signal identity key changed")).lastOrNull;
    if (lastNotice == null || DateTime.now().difference(lastNotice.timestamp).inSeconds >= 10) {
      await addMessage(peerNostrPubKey, ChatMessage(
        text: "⚠️ Security Notice: Peer's Signal identity key changed. Messages are paused to protect your privacy. Tap to verify Safety Number.",
        isMe: false,
        timestamp: DateTime.now(),
        status: MessageStatus.sent,
      ));
    }
    notifyListeners();
  }

  Future<bool> approvePeerIdentity(String peerNostrPubKey) async {
    if (signalService == null) return false;
    final success = await signalService!.approveUntrustedIdentity(peerNostrPubKey);
    if (success) {
      _blockedIdentityPeers.remove(peerNostrPubKey);
      await addMessage(peerNostrPubKey, ChatMessage(
        text: "✅ Security Identity Verified: New encryption key approved. End-to-end encryption restored.",
        isMe: false,
        timestamp: DateTime.now(),
        status: MessageStatus.sent,
      ));
      notifyListeners();
    }
    return success;
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
    try {
      activeChats = await chatRepo.getAllChats();
      for (final user in activeChats) {
        final msgs = await chatRepo.getMessagesForChat(user.nostrPubKeyHex);
        msgs.sort((a, b) => a.timestamp.compareTo(b.timestamp));
        chatHistories[user.nostrPubKeyHex] = msgs;
      }
      _sortActiveChats();
      notifyListeners();
      unawaited(drainOutbox());
    } catch (e, st) {
      debugPrint('[CHAT_PROVIDER] Error loading initial chat data: $e\n$st');
    }
  }

  Future<void> startListeningForMessages() async {
    // 1. Fetch timestamp of the latest message locally to sync offline messages
    DateTime? latestTimestamp;
    try {
      latestTimestamp = await chatRepo.getLatestMessageTimestamp();
    } catch (_) {}

    // Safety buffer: look back at least 7 days (or 30 days if no latestTimestamp) so that clock skew
    // between peers never causes relays to drop incoming messages or receipts!
    final adjustedTimestamp = latestTimestamp != null
        ? latestTimestamp.subtract(const Duration(days: 7))
        : DateTime.now().subtract(const Duration(days: 30));

    // 2. Register with NostrRelayService subscription registry so that any reconnection
    // (network restoration, resume, force: true) automatically recreates this subscription!
    NostrRelayService().registerMessageSubscription(
      onEvent: _handleIncomingNostrEvent,
      sinceProvider: () => adjustedTimestamp,
    );

    // 3. Connect or verify connection to relays and hook outbox drainer
    NostrRelayService().addOnReadyListener(() => unawaited(drainOutbox()));
    await NostrRelayService().connectToRelays();
    _startOutboxPeriodicDrain();
    unawaited(drainOutbox());

    // 4. PreKey replenishment check and periodic replenishment
    unawaited(signalService?.checkAndReplenishPreKeys());
    signalService?.startPeriodicReplenishment();
  }

  void stopListening() {
    _outboxDrainTimer?.cancel();
    _outboxDrainTimer = null;
    _globalMessageSubscription?.cancel();
    _globalMessageSubscription = null;
    signalService?.stopPeriodicReplenishment();
    NostrRelayService().unregisterMessageSubscription();
  }

  @override
  void dispose() {
    stopListening();
    super.dispose();
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

  final Map<String, String> _keyAliases = {};

  @visibleForTesting
  Map<String, String> get keyAliases => Map.unmodifiable(_keyAliases);

  List<ChatMessage> getMessagesFor(String nostrPubKey, {String? masterPubKeyHex}) {
    if (chatHistories.containsKey(nostrPubKey) && chatHistories[nostrPubKey]!.isNotEmpty) {
      return chatHistories[nostrPubKey]!;
    }
    final targetKey = _keyAliases[nostrPubKey];
    if (targetKey != null && chatHistories.containsKey(targetKey) && chatHistories[targetKey]!.isNotEmpty) {
      return chatHistories[targetKey]!;
    }
    if (masterPubKeyHex != null && masterPubKeyHex.isNotEmpty) {
      final user = activeChats.where((u) => u.masterPubKeyHex == masterPubKeyHex).firstOrNull;
      if (user != null && chatHistories.containsKey(user.nostrPubKeyHex)) {
        return chatHistories[user.nostrPubKeyHex]!;
      }
    }
    return chatHistories[nostrPubKey] ?? [];
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
      // Guard: Never cross-alias if masterPubKeyHex is provided and differs
      if (masterPubKeyHex.isNotEmpty && user.masterPubKeyHex.isNotEmpty && user.masterPubKeyHex != masterPubKeyHex) {
        print('[PRESENCE] SECURITY ALERT: Rejecting presence update for ${user.username}: mismatched master key ($masterPubKeyHex != ${user.masterPubKeyHex})');
        return;
      }
      if (nostrPubKeyHex != null && nostrPubKeyHex.isNotEmpty && user.nostrPubKeyHex != nostrPubKeyHex) {
        final oldKey = user.nostrPubKeyHex;
        user.nostrPubKeyHex = nostrPubKeyHex;
        _keyAliases[oldKey] = nostrPubKeyHex;
        _keyAliases[nostrPubKeyHex] = oldKey;
        if (chatHistories.containsKey(oldKey)) {
          final existingHistory = chatHistories[nostrPubKeyHex] ?? [];
          final oldHistory = chatHistories[oldKey]!;
          final merged = [...oldHistory, ...existingHistory];
          chatHistories[nostrPubKeyHex] = merged;
          chatHistories[oldKey] = merged; // Keep oldKey referencing merged history so active screens don't blank out
        }
        unawaited(chatRepo.saveChat(user));
      }
      user.isExplicitlyOffline = !isOnline;
      if (isOnline) {
        user.lastSeen = lastSeen;
        user.lastSeenFromPing = lastSeen;
        final targetKey = nostrPubKeyHex ?? user.nostrPubKeyHex;
        if (targetKey.isNotEmpty) {
          unawaited(retryUnacknowledgedForPeer(targetKey));
        }
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
    
    // Check if this chat is active AND app is focused before skipping unread increment
    final isActiveChat = isAppFocused && (
        activeChatUserId == nostrPubKey ||
        (_keyAliases[nostrPubKey] != null && activeChatUserId == _keyAliases[nostrPubKey]));
    if (!isActiveChat && !message.isMe) {
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
      if (isPeerIdentityBlocked(recipientNostrPubKey)) {
        print('[MSG] SEND_RECEIPT aborted: peer $recipientNostrPubKey identity is blocked');
        return;
      }

      // Resolve the active key: if no Signal session exists under the given key or peer is blocked,
      // try the aliased key so receipts reach the peer's current session.
      String activeKey = recipientNostrPubKey;
      bool sessionReady = await canSendToPeer(recipientNostrPubKey);
      if (!sessionReady) {
        final aliased = _keyAliases[recipientNostrPubKey];
        if (aliased != null && await canSendToPeer(aliased)) {
          activeKey = aliased;
          sessionReady = true;
        }
      }
      if (!sessionReady) {
        if (isPeerIdentityBlocked(recipientNostrPubKey)) {
          print('[MSG] SEND_RECEIPT aborted: peer $recipientNostrPubKey identity is blocked');
          return;
        }
        final aliased = _keyAliases[recipientNostrPubKey];
        if (aliased != null && isPeerIdentityBlocked(aliased)) {
          print('[MSG] SEND_RECEIPT aborted: peer $aliased identity is blocked');
          return;
        }

        print('[MSG] SEND_RECEIPT no active session for $recipientNostrPubKey, establishing...');
        final chatUser = activeChats.where((c) =>
            c.nostrPubKeyHex == recipientNostrPubKey ||
            _keyAliases[c.nostrPubKeyHex] == recipientNostrPubKey ||
            _keyAliases[recipientNostrPubKey] == c.nostrPubKeyHex).firstOrNull;
        final expectedMaster = chatUser?.masterPubKeyHex;

        sessionReady = await signalService!.fetchAndEstablishSession(
          recipientNostrPubKey,
          masterPubKeyHex: expectedMaster,
        );
        if (sessionReady) {
          activeKey = recipientNostrPubKey;
        } else {
          print('[MSG] SEND_RECEIPT cannot establish session for $recipientNostrPubKey, aborting receipt');
          if (status == 'read') {
            _lastReadReceiptSentMsgId.remove(recipientNostrPubKey);
            _lastReadReceiptSentMsgId.remove(activeKey);
          }
          return;
        }
      }

      if (isPeerIdentityBlocked(activeKey)) {
        print('[MSG] SEND_RECEIPT aborted: peer $activeKey identity is blocked');
        return;
      }

      print('[MSG] SEND_RECEIPT status=$status targetId=$targetMessageId recipient=$activeKey (requested=$recipientNostrPubKey)');
      await signalService!.sendMessage(
        activeKey,
        '',
        type: 'receipt',
        extraBody: {
          'targetId': targetMessageId,
          'status': status,
        },
      );
      if (status == 'read') {
        _lastReadReceiptSentMsgId[recipientNostrPubKey] = targetMessageId;
        _lastReadReceiptSentMsgId[activeKey] = targetMessageId;
      }
    } catch (e) {
      print("DEBUG: sendReceipt error: $e");
      if (status == 'read') {
        _lastReadReceiptSentMsgId.remove(recipientNostrPubKey);
      }
    }
  }

  Future<void> sendControlMessage({
    required String recipientNostrPubKey,
    required String control,
  }) async {
    try {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      String? sig;
      final masterKeyPair = authProvider.masterKeyPair;
      if (masterKeyPair != null) {
        sig = await authProvider.cryptoService.signControlToken(
          masterKeyPair: masterKeyPair,
          control: control,
          recipientNostrPubKey: recipientNostrPubKey,
          timestamp: nowMs,
        );
      }

      final payload = {
        'type': -1,
        'control': control,
        'senderMasterPubKey': authProvider.masterPublicKeyHex ?? '',
        if (sig != null) 'sig': sig,
        'sentAt': nowMs,
      };
      await NostrRelayService().sendEncryptedPayload(recipientNostrPubKey, jsonEncode(payload));
      print("DEBUG: Sent control message '$control' to $recipientNostrPubKey (authenticated: ${sig != null})");
    } catch (e) {
      print("DEBUG: sendControlMessage error: $e");
    }
  }

  String _findPeerKeyForReceipt(String senderNostrPubKey, String targetId) {
    if (chatHistories[senderNostrPubKey]?.any((m) => m.messageId == targetId) ?? false) {
      return senderNostrPubKey;
    }
    final aliased = _keyAliases[senderNostrPubKey];
    if (aliased != null && (chatHistories[aliased]?.any((m) => m.messageId == targetId) ?? false)) {
      return aliased;
    }
    for (final entry in chatHistories.entries) {
      if (entry.value.any((m) => m.messageId == targetId)) {
        return entry.key;
      }
    }
    return senderNostrPubKey;
  }

  Future<void> markChatAsRead(String nostrPubKey) async {
    activeChatUserId = nostrPubKey;
    unreadCounts.remove(nostrPubKey);

    // Also clear unread count for aliased keys
    final aliasedKey = _keyAliases[nostrPubKey];
    if (aliasedKey != null) {
      unreadCounts.remove(aliasedKey);
    }

    if (!chatHistories.containsKey(nostrPubKey)) {
      final msgs = await chatRepo.getMessagesForChat(nostrPubKey);
      msgs.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      chatHistories[nostrPubKey] = msgs;
    }

    // Use getMessagesFor to resolve messages across aliased keys
    final history = getMessagesFor(nostrPubKey);
    final unreadIncoming = history.where((m) => !m.isMe && m.status != MessageStatus.read).toList();
    for (final msg in unreadIncoming) {
      msg.status = MessageStatus.read;
      unawaited(chatRepo.updateMessageStatus(msg.messageId, MessageStatus.read));
    }

    // Telegram-style Cumulative Read Watermark:
    // Only dispatch a single receipt acknowledging the latest incoming message
    final latestIncoming = history.where((m) => !m.isMe).lastOrNull;
    if (latestIncoming != null && _lastReadReceiptSentMsgId[nostrPubKey] != latestIncoming.messageId) {
      _lastReadReceiptSentMsgId[nostrPubKey] = latestIncoming.messageId;
      final aliased = _keyAliases[nostrPubKey];
      if (aliased != null) {
        _lastReadReceiptSentMsgId[aliased] = latestIncoming.messageId;
      }
      await sendReceipt(
        recipientNostrPubKey: nostrPubKey,
        targetMessageId: latestIncoming.messageId,
        status: 'read',
      );
    }
    notifyListeners();
  }
  
  void clearActiveChat() {
    activeChatUserId = null;
  }

  @visibleForTesting
  Future<void> handleIncomingEventForTest(NostrEvent event) => _handleIncomingNostrEvent(event);

  Future<void> _handleIncomingNostrEvent(NostrEvent event) async {
    final sessionGen = AccountSession.currentGeneration;
    if (!AccountSession.isGenerationValid(sessionGen)) {
      print('[CHAT] Dropping incoming Nostr event: stale session gen $sessionGen != current ${AccountSession.currentGeneration}');
      return;
    }
    if (signalService == null) return;
    
    final senderNostrPubKey = event.pubkey;
    print("DEBUG: Received incoming event kind ${event.kind} from $senderNostrPubKey. Content length: ${event.content?.length}");
    
    if (event.kind == 4444 && event.content != null) {
      print('[RECV] Kind 4444 received');
      print("DEBUG: Event is 4444. Attempting to parse JSON...");
      Map<String, dynamic> map;
      try {
        map = jsonDecode(event.content!);
      } catch (e) {
        print("DEBUG: JSON parsing failed: $e");
        return;
      }

      // Check for unencrypted control messages (e.g. session renegotiation / reset requests)
      if (map['type'] == -1 || map['control'] != null) {
        final control = map['control'] as String?;
        if (control == 'RESET_SESSION') {
          // Gate 1: Known Contact / Conversation Check (Anti-DoS / Anti-Spam)
          // Drop reset requests from strangers on Nostr who do not have an active chat or known contact entry
          final isKnownPeer = chatHistories.containsKey(senderNostrPubKey) ||
              activeChats.any((c) => c.nostrPubKeyHex == senderNostrPubKey || (map['senderMasterPubKey'] != null && c.masterPubKeyHex == map['senderMasterPubKey']));
          if (!isKnownPeer) {
            print('[RECV] Dropping unauthenticated RESET_SESSION from unknown peer $senderNostrPubKey (no chat history)');
            return;
          }

          // Gate 2: Freshness / Anti-Replay Check (within 120 seconds)
          final sentAt = map['sentAt'] as int?;
          if (sentAt != null) {
            final ageSeconds = (DateTime.now().millisecondsSinceEpoch - sentAt).abs() / 1000;
            if (ageSeconds > 120) {
              print('[RECV] Dropping stale RESET_SESSION from $senderNostrPubKey (age: ${ageSeconds.toStringAsFixed(1)}s > 120s)');
              return;
            }
          }

          // Gate 3: Master Key & Cryptographic Signature Check (Centralized & Fail-Closed)
          final senderMasterPubKey = map['senderMasterPubKey'] as String?;
          final sig = map['sig'] as String?;
          final myNostrPubKey = NostrRelayService().publicHex;

          final verifyResult = await masterBindingVerifier.verifyControlMessage(
            senderMasterPubKeyHex: senderMasterPubKey,
            controlType: control ?? 'RESET_SESSION',
            recipientNostrPubKey: myNostrPubKey,
            timestampMs: sentAt,
            signatureHex: sig,
          );

          if (!verifyResult.isValid) {
            print('[RECV] SECURITY ALERT: Dropping unauthenticated RESET_SESSION from $senderNostrPubKey: ${verifyResult.reason} (${verifyResult.errorMessage})');
            return;
          }

          // Strict sanity check against local pinned contact
          final knownContact = activeChats.where((c) => c.nostrPubKeyHex == senderNostrPubKey).firstOrNull;
          if (knownContact != null && knownContact.masterPubKeyHex.isNotEmpty && knownContact.masterPubKeyHex != senderMasterPubKey) {
            print('[RECV] SECURITY ALERT: RESET_SESSION senderMasterPubKey mismatch ($senderMasterPubKey != ${knownContact.masterPubKeyHex}) from $senderNostrPubKey! Dropping.');
            return;
          }

          // Gate 4: Cooldown (ignore repeated RESET_SESSION from same peer within 60 seconds)
          final now = DateTime.now();
          final lastReset = _lastResetTimestamps[senderNostrPubKey];
          if (lastReset != null && now.difference(lastReset).inSeconds < 60) {
            print('[RECV] RESET_SESSION from $senderNostrPubKey ignored (cooldown: ${now.difference(lastReset).inSeconds}s ago)');
            return;
          }
          _lastResetTimestamps[senderNostrPubKey] = now;

          print("DEBUG: Received authenticated RESET_SESSION control request from $senderNostrPubKey. Rebuilding session from network...");
          await signalService!.fetchAndEstablishSession(senderNostrPubKey, masterPubKeyHex: senderMasterPubKey, force: true);
          if (!AccountSession.isGenerationValid(sessionGen)) return;

          // Only retry messages stuck in sending/failed — never re-send already-sent messages
          // (re-sending 'sent' messages causes tick→clock→tick flicker)
          final history = chatHistories[senderNostrPubKey];
          if (history != null) {
            final pendingMsg = history.where((m) => m.isMe && (m.status == MessageStatus.sending || m.status == MessageStatus.failed)).lastOrNull;
            if (pendingMsg != null) {
              if (!AccountSession.isGenerationValid(sessionGen)) return;
              print("DEBUG: Re-sending pending message ${pendingMsg.messageId} after session reset...");
              await retryOutgoingMessage(senderNostrPubKey, pendingMsg);
            }
          }
          return;
        }
      }
      
      print("DEBUG: Attempting to decrypt message...");
      final result = await signalService!.decryptMessage(senderNostrPubKey, map);

      // CRITICAL SECURITY BARRIER: Inbound decryption post-await generation check
      if (!AccountSession.isGenerationValid(sessionGen)) {
        print('[CHAT] Dropping decrypted incoming message: session generation $sessionGen is stale');
        return;
      }
      
      if (result == null) {
        if (!AccountSession.isGenerationValid(sessionGen)) return;
        // Cooldown: only send RESET_SESSION if we haven't sent one to this peer recently
        final now = DateTime.now();
        final lastReset = _lastResetTimestamps[senderNostrPubKey];
        if (lastReset == null || now.difference(lastReset).inSeconds >= 60) {
          _lastResetTimestamps[senderNostrPubKey] = now;
          print('[RECV] Signal decrypt failure id=${map['id']} from=$senderNostrPubKey. Requesting session renegotiation...');
          unawaited(sendControlMessage(
            recipientNostrPubKey: senderNostrPubKey,
            control: 'RESET_SESSION',
          ));
        } else {
          print('[RECV] Signal decrypt failure id=${map['id']} from=$senderNostrPubKey. RESET_SESSION suppressed (cooldown)');
        }
        return;
      }

      print('[RECV] Signal decrypt success');
      print("DEBUG: Decryption successful!");
      final plaintext = result.$1;
      final senderMasterPubKeyFromPayload = result.$2;
      final sentAt = result.$3;
      final incomingMsgId = result.$4;
      final isIdentityKeyChanged = result.$5;

      if (plaintext == "__DUPLICATE_MESSAGE__") {
        if (!AccountSession.isGenerationValid(sessionGen)) return;
        print('[RECV] Dropping duplicate/replayed message id=$incomingMsgId; re-acknowledging delivery receipt');
        if (incomingMsgId != null && incomingMsgId.isNotEmpty) {
          unawaited(sendReceipt(
            recipientNostrPubKey: senderNostrPubKey,
            targetMessageId: incomingMsgId,
            status: 'delivered',
          ));
        }
        return;
      }

      if (plaintext == "__UNTRUSTED_IDENTITY__") {
        if (!AccountSession.isGenerationValid(sessionGen)) return;
        print('[RECV] Incoming message from $senderNostrPubKey BLOCKED due to untrusted identity key change.');
        await handlePeerIdentityKeyChanged(senderNostrPubKey);
        return;
      }

      if (plaintext == "__NEED_SESSION_RESET__") {
        if (!AccountSession.isGenerationValid(sessionGen)) return;
        print("DEBUG: Decryption failed for $senderNostrPubKey (missing/invalid session). Sending RESET_SESSION request...");
        unawaited(sendControlMessage(
          recipientNostrPubKey: senderNostrPubKey,
          control: 'RESET_SESSION',
        ));
        return;
      }

      // Target #1: Visual Security Alert on peer identity key change
      if (isIdentityKeyChanged) {
        if (!AccountSession.isGenerationValid(sessionGen)) return;
        await handlePeerIdentityKeyChanged(senderNostrPubKey);
      }
      
      if (plaintext == "__SESSION_RESET__") {
        if (!AccountSession.isGenerationValid(sessionGen)) return;
        print("DEBUG: Received session reset from $senderNostrPubKey. Deleting local session.");
        await signalService!.deleteSession(senderNostrPubKey);
        return;
      }

      // Target #9: Process receipt envelopes without creating chat bubbles
      final receiptEnvelope = MndoMessageEnvelope.tryParse(plaintext);
      if (receiptEnvelope != null && receiptEnvelope.type == 'receipt') {
        if (!AccountSession.isGenerationValid(sessionGen)) return;
        final targetId = receiptEnvelope.body['targetId'] as String?;
        final statusStr = receiptEnvelope.body['status'] as String?;
        if (targetId != null && statusStr != null) {
          print('[MSG] ${statusStr.toUpperCase()}_RECEIPT targetId=$targetId from=$senderNostrPubKey');
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
            DateTime? cutoff = targetMsg?.timestamp;
            if (cutoff == null) {
              final dbRecord = await chatRepo.getMessageByMessageId(targetId);
              cutoff = dbRecord?.timestamp;
            }

            if (!AccountSession.isGenerationValid(sessionGen)) return;
            if (cutoff != null) {
              final peerKey = _findPeerKeyForReceipt(senderNostrPubKey, targetId);
              final keysToUpdate = {
                senderNostrPubKey,
                peerKey,
                if (_keyAliases[senderNostrPubKey] != null) _keyAliases[senderNostrPubKey]!,
                if (_keyAliases[peerKey] != null) _keyAliases[peerKey]!,
              };
              for (final key in keysToUpdate) {
                if (!AccountSession.isGenerationValid(sessionGen)) return;
                final hist = chatHistories[key];
                if (hist != null) {
                  for (final m in hist) {
                    if (m.isMe && !m.timestamp.isAfter(cutoff) && m.status != MessageStatus.read) {
                      m.status = MessageStatus.read;
                      unawaited(chatRepo.deleteFromOutbox(m.messageId));
                    }
                  }
                }
                await chatRepo.markMessagesReadUpTo(key, cutoff);
              }
              if (!AccountSession.isGenerationValid(sessionGen)) return;
              if (targetMsg != null) {
                targetMsg.status = MessageStatus.read;
              }
              await chatRepo.updateMessageStatus(targetId, MessageStatus.read);
              await chatRepo.deleteFromOutbox(targetId);
              notifyListeners();
            } else {
              if (!AccountSession.isGenerationValid(sessionGen)) return;
              if (targetMsg != null) {
                targetMsg.status = MessageStatus.read;
              }
              await chatRepo.updateMessageStatus(targetId, MessageStatus.read);
              await chatRepo.deleteFromOutbox(targetId);
              notifyListeners();
            }
          } else if (statusStr == 'delivered') {
            if (!AccountSession.isGenerationValid(sessionGen)) return;
            if (targetMsg != null && targetMsg.status != MessageStatus.read) {
              targetMsg.status = MessageStatus.delivered;
              await chatRepo.updateMessageStatus(targetId, MessageStatus.delivered);
              notifyListeners();
            } else if (targetMsg == null) {
              await chatRepo.updateMessageStatus(targetId, MessageStatus.delivered);
            }
            await chatRepo.deleteFromOutbox(targetId);
          }
        }
        return;
      }

      if (!AccountSession.isGenerationValid(sessionGen)) return;

      // Peer is actively sending messages: opportunistic retry for any pending unacknowledged outbox items
      unawaited(retryUnacknowledgedForPeer(senderNostrPubKey));
      
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
      
      final now = DateTime.now();
      final messageAgeSeconds = (now.millisecondsSinceEpoch - messageTimestamp.millisecondsSinceEpoch) / 1000.0;
      final isRecentLiveMessage = messageAgeSeconds >= -300 && messageAgeSeconds < 70;

      final existingIndex = activeChats.indexWhere((u) =>
        u.nostrPubKeyHex == senderNostrPubKey ||
        (masterPubKeyToVerify.isNotEmpty && u.masterPubKeyHex == masterPubKeyToVerify)
      );

      if (!AccountSession.isGenerationValid(sessionGen)) return;

      if (existingIndex == -1) {
        final displayUsername = "Ghost #${masterPubKeyToVerify.substring(0, 4)}";
        
        addChat(DiscoverUser(
          masterPubKeyHex: masterPubKeyToVerify,
          nostrPubKeyHex: senderNostrPubKey,
          username: displayUsername,
          displayName: null,
          lastSeen: messageTimestamp,
          lastSeenFromMessage: isRecentLiveMessage ? (messageAgeSeconds < 0 ? now : messageTimestamp) : null,
        ));
      } else {
        final existingUser = activeChats[existingIndex];
        if (existingUser.nostrPubKeyHex != senderNostrPubKey) {
          existingUser.nostrPubKeyHex = senderNostrPubKey;
        }
        if (messageTimestamp.isAfter(existingUser.lastSeen)) {
          existingUser.lastSeen = messageTimestamp;
        }
        if (isRecentLiveMessage) {
          existingUser.lastSeenFromMessage = messageAgeSeconds < 0 ? now : messageTimestamp;
          existingUser.isExplicitlyOffline = false;
        }
      }
      
      if (!AccountSession.isGenerationValid(sessionGen)) return;
      print('[MSG] RECEIVED id=$incomingMsgId from=$senderNostrPubKey');
      print('[RECV] Message stored');
      addMessage(senderNostrPubKey, ChatMessage(
        messageId: incomingMsgId,
        text: plaintext,
        isMe: false,
        timestamp: messageTimestamp,
        status: MessageStatus.sent,
      ));

      // Target #9: Dispatch automatic delivery/read receipt
      // Only mark as 'read' if chat is active AND app window is focused/visible
      final isChatActive = isAppFocused && (
          activeChatUserId == senderNostrPubKey ||
          (_keyAliases[senderNostrPubKey] != null && activeChatUserId == _keyAliases[senderNostrPubKey]) ||
          (_keyAliases[activeChatUserId] != null && _keyAliases[activeChatUserId] == senderNostrPubKey));
      if (incomingMsgId != null) {
        if (!AccountSession.isGenerationValid(sessionGen)) return;
        final receiptStatus = isChatActive ? 'read' : 'delivered';
        print('[RECV] $receiptStatus receipt sent for $incomingMsgId');
        // If chat is active, also update the message status in memory and DB to read
        if (isChatActive) {
          final justAdded = chatHistories[senderNostrPubKey]?.where((m) => m.messageId == incomingMsgId).firstOrNull;
          if (justAdded != null) {
            justAdded.status = MessageStatus.read;
            unawaited(chatRepo.updateMessageStatus(incomingMsgId, MessageStatus.read));
          }
        }
        unawaited(sendReceipt(
          recipientNostrPubKey: senderNostrPubKey,
          targetMessageId: incomingMsgId,
          status: receiptStatus,
        ));
      }
    }
  }

  bool _isDrainingOutbox = false;

  void _startOutboxPeriodicDrain() {
    _outboxDrainTimer?.cancel();
    _outboxDrainTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      unawaited(drainOutbox());
    });
  }

  /// Automatically drains pending and unacknowledged messages from the persistent Outbox.
  /// Re-transmits the exact stored ciphertexts without advancing the Signal Double Ratchet.
  /// If [forceAll] is false, messages in 'sent' state respect exponential backoff.
  Future<void> drainOutbox({bool forceAll = false}) async {
    final sessionGen = AccountSession.currentGeneration;
    if (_isDrainingOutbox) return;
    if (signalService == null || !AccountSession.isGenerationValid(sessionGen)) return;
    _isDrainingOutbox = true;

    try {
      final undelivered = await chatRepo.getPendingOutboxMessages();
      if (undelivered.isEmpty || !AccountSession.isGenerationValid(sessionGen)) return;

      final now = DateTime.now();

      for (final record in undelivered) {
        if (!AccountSession.isGenerationValid(sessionGen)) {
          print('[OUTBOX] drainOutbox interrupted: session generation $sessionGen is stale');
          break;
        }

        if (isPeerIdentityBlocked(record.recipientNostrPubKey)) {
          print('[OUTBOX] Skipping dispatch for ${record.messageId}: recipient ${record.recipientNostrPubKey} identity is blocked pending verification');
          continue;
        }
        // If status is 'sent' (awaiting delivery ack), check exponential backoff unless forceAll is true
        if (record.status == 'sent' && !forceAll) {
          final attempts = record.attempts;
          // Max periodic retry attempts: 5 (wait for opportunistic peer presence instead of endless relay spam)
          if (attempts >= 5) {
            continue;
          }

          // Backoff schedule: attempt 1: 30s, 2: 60s, 3: 120s, 4+: 300s
          final backoffSeconds = attempts <= 1 ? 30 : (attempts == 2 ? 60 : (attempts == 3 ? 120 : 300));
          final lastAttempt = record.lastAttemptAt ?? record.createdAt;
          if (now.difference(lastAttempt).inSeconds < backoffSeconds) {
            continue; // Not yet time to retry this message
          }
        }

        try {
          final payloadMap = jsonDecode(record.payloadJson) as Map<String, dynamic>;
          print('[OUTBOX] Dispatching undelivered messageId=${record.messageId} (status: ${record.status}, attempt: ${record.attempts + 1})...');
          
          if (!AccountSession.isGenerationValid(sessionGen)) break;
          await signalService!.sendPreparedPayload(record.recipientNostrPubKey, payloadMap);

          if (!AccountSession.isGenerationValid(sessionGen)) break;

          // Update attempt timestamp and keep status 'sent' (awaiting peer delivery receipt)
          await chatRepo.updateOutboxStatus(
            record.messageId,
            status: 'sent',
            attempts: record.attempts + 1,
            lastAttemptAt: DateTime.now(),
          );
          await chatRepo.updateMessageStatus(record.messageId, MessageStatus.sent);

          // Update in-memory message status if needed
          for (final chat in chatHistories.values) {
            for (final msg in chat) {
              if (msg.messageId == record.messageId && msg.status == MessageStatus.failed) {
                msg.status = MessageStatus.sent;
                break;
              }
            }
          }
          notifyListeners();
          print('[OUTBOX] Successfully dispatched messageId=${record.messageId}');
        } catch (e) {
          if (!AccountSession.isGenerationValid(sessionGen)) break;
          print('[OUTBOX] Failed to dispatch messageId=${record.messageId}: $e');
          try {
            await chatRepo.updateOutboxAttempt(
              record.messageId,
              attempts: record.attempts + 1,
              lastAttemptAt: DateTime.now(),
              status: record.status == 'sent' ? 'sent' : 'failed',
            );
          } catch (_) {}
        }
      }
    } catch (e) {
      print('[OUTBOX] Error during drain: $e');
    } finally {
      _isDrainingOutbox = false;
    }
  }

  /// Immediately re-dispatches unacknowledged messages when peer comes online or interacts.
  Future<void> retryUnacknowledgedForPeer(String recipientNostrPubKey) async {
    final sessionGen = AccountSession.currentGeneration;
    if (signalService == null || !AccountSession.isGenerationValid(sessionGen)) return;
    if (isPeerIdentityBlocked(recipientNostrPubKey)) {
      print('[OUTBOX] retryUnacknowledgedForPeer aborted: peer $recipientNostrPubKey identity is blocked');
      return;
    }
    
    // Throttle per-peer retries to avoid spamming relays on frequent presence pings (min 15 seconds)
    final now = DateTime.now();
    final lastTime = _lastPeerRetryTime[recipientNostrPubKey];
    if (lastTime != null && now.difference(lastTime).inSeconds < 15) {
      return;
    }
    _lastPeerRetryTime[recipientNostrPubKey] = now;

    try {
      final pendingForPeer = await chatRepo.getUndeliveredMessagesForPeer(recipientNostrPubKey);
      if (pendingForPeer.isEmpty || !AccountSession.isGenerationValid(sessionGen)) return;

      print('[OUTBOX] Opportunistic retry: peer $recipientNostrPubKey is active. Resending ${pendingForPeer.length} unacknowledged message(s)...');
      for (final record in pendingForPeer) {
        if (!AccountSession.isGenerationValid(sessionGen)) break;
        try {
          final payloadMap = jsonDecode(record.payloadJson) as Map<String, dynamic>;
          await signalService!.sendPreparedPayload(recipientNostrPubKey, payloadMap);
          if (!AccountSession.isGenerationValid(sessionGen)) break;
          await chatRepo.updateOutboxStatus(
            record.messageId,
            status: 'sent',
            attempts: record.attempts + 1,
            lastAttemptAt: DateTime.now(),
          );
        } catch (e) {
          print('[OUTBOX] Peer retry failed for ${record.messageId}: $e');
        }
      }
    } catch (e) {
      print('[OUTBOX] Error in retryUnacknowledgedForPeer: $e');
    }
  }

  Future<bool> sendOutgoingMessage(
    String recipientNostrPubKey, 
    String text, {
    DateTime? sentAt,
    String? replyToId,
  }) async {
    final sessionGen = AccountSession.currentGeneration;
    if (!AccountSession.isGenerationValid(sessionGen)) {
      print('[MSG] sendOutgoingMessage dropped: stale session generation $sessionGen');
      return false;
    }

    final timestamp = sentAt ?? DateTime.now();
    final message = ChatMessage(
      text: text,
      isMe: true,
      timestamp: timestamp,
      status: MessageStatus.sending,
      replyToId: replyToId,
    );

    await addMessage(recipientNostrPubKey, message);

    if (!AccountSession.isGenerationValid(sessionGen)) {
      print('[MSG] sendOutgoingMessage aborted after addMessage: stale session $sessionGen');
      return false;
    }

    if (isPeerIdentityBlocked(recipientNostrPubKey)) {
      print('[MSG] sendOutgoingMessage BLOCKED for $recipientNostrPubKey: peer identity is blocked pending verification');
      message.status = MessageStatus.failed;
      await chatRepo.updateMessageStatus(message.messageId, MessageStatus.failed);
      notifyListeners();
      return false;
    }

    print('[MSG] SEND id=${message.messageId} recipient=$recipientNostrPubKey type=text');
    try {
      if (signalService == null || !AccountSession.isGenerationValid(sessionGen)) {
        throw StateError("Signal service not initialized or session stale");
      }
      
      // 1. Prepare and encrypt payload (advances ratchet ONCE)
      final (msgId, payloadMap) = await signalService!.prepareEncryptedPayload(
        recipientNostrPubKey,
        text,
        sentAt: timestamp,
        messageId: message.messageId,
        type: 'text',
        replyToId: replyToId,
      );

      if (!AccountSession.isGenerationValid(sessionGen)) {
        print('[MSG] sendOutgoingMessage aborted post-encrypt: stale session $sessionGen');
        return false;
      }

      // 2. Atomically persist to durable Outbox in encrypted DB
      await chatRepo.enqueueOutbox(
        messageId: msgId,
        recipientNostrPubKey: recipientNostrPubKey,
        payloadJson: jsonEncode(payloadMap),
        createdAt: timestamp,
      );

      if (!AccountSession.isGenerationValid(sessionGen)) {
        print('[MSG] sendOutgoingMessage aborted post-enqueue: stale session $sessionGen');
        return false;
      }

      // 3. Dispatch over network
      await signalService!.sendPreparedPayload(recipientNostrPubKey, payloadMap);

      if (!AccountSession.isGenerationValid(sessionGen)) {
        print('[MSG] sendOutgoingMessage post-send update skipped: stale session $sessionGen');
        return true;
      }

      // 4. Relay accepted! Update Outbox record to 'sent' (awaiting peer delivery ack)
      await chatRepo.updateOutboxStatus(
        msgId,
        status: 'sent',
        attempts: 1,
        lastAttemptAt: DateTime.now(),
      );

      if (message.status == MessageStatus.sending) {
        message.status = MessageStatus.sent;
        await chatRepo.updateMessageStatus(message.messageId, MessageStatus.sent);
        notifyListeners();
      }
      print('[MSG] SEND SUCCESS id=${message.messageId}');
      return true;
    } catch (e) {
      if (!AccountSession.isGenerationValid(sessionGen)) return false;
      print('[MSG] SEND FAILURE id=${message.messageId} error: $e');
      try {
        await chatRepo.updateOutboxAttempt(
          message.messageId,
          attempts: 1,
          lastAttemptAt: DateTime.now(),
          status: 'failed',
        );
      } catch (_) {}

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
    final sessionGen = AccountSession.currentGeneration;
    if (!AccountSession.isGenerationValid(sessionGen)) {
      print('[VOICE] sendOutgoingVoiceNote dropped: stale session generation $sessionGen');
      return false;
    }

    final timestamp = sentAt ?? DateTime.now();

    if (isPeerIdentityBlocked(recipientNostrPubKey)) {
      print('[VOICE] sendOutgoingVoiceNote BLOCKED for $recipientNostrPubKey: peer identity is blocked pending verification');
      return false;
    }

    // 1. Locally encrypt with AES-256-GCM in ~3ms to generate the full decryption treasure map
    final prepared = await VoiceNoteService().prepareAndEncryptVoiceNote(
      localAudioPath: localAudioPath,
      durationMs: durationMs,
      waveform: waveform,
      sentAt: timestamp.millisecondsSinceEpoch,
    );

    if (prepared == null || !AccountSession.isGenerationValid(sessionGen)) {
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

    if (!AccountSession.isGenerationValid(sessionGen)) {
      print('[VOICE] sendOutgoingVoiceNote aborted after addMessage: stale session $sessionGen');
      return false;
    }

    // 3. Target #6: ATOMIC MEDIA PIPELINE - Upload encrypted bytes to Blossom FIRST
    // Guarantees recipient will never receive a voice note notification before the blob is available!
    try {
      final uploadUrl = await VoiceNoteService().uploadEncryptedBytes(
        encryptedBytes,
        payload.fileHash,
        sessionGen: sessionGen,
      );

      if (!AccountSession.isGenerationValid(sessionGen)) {
        print('[VOICE] sendOutgoingVoiceNote aborted post-upload: stale session $sessionGen');
        return false;
      }

      if (uploadUrl == null) {
        if (message.status == MessageStatus.sending) {
          message.status = MessageStatus.failed;
          await chatRepo.updateMessageStatus(message.messageId, MessageStatus.failed);
          notifyListeners();
        }
        return false;
      }
    } catch (e) {
      if (!AccountSession.isGenerationValid(sessionGen)) return false;
      print("Error uploading voice note to Blossom: $e");
      if (message.status == MessageStatus.sending) {
        message.status = MessageStatus.failed;
        await chatRepo.updateMessageStatus(message.messageId, MessageStatus.failed);
        notifyListeners();
      }
      return false;
    }

    // 4. Blossom upload confirmed! Transmit Signal payload via Outbox
    try {
      if (signalService == null || !AccountSession.isGenerationValid(sessionGen)) {
        throw StateError("Signal service not initialized or session stale");
      }
      final (msgId, payloadMap) = await signalService!.prepareEncryptedPayload(
        recipientNostrPubKey,
        payload.serializeForNetwork(),
        sentAt: timestamp,
        messageId: message.messageId,
        type: 'voice_note',
        extraBody: {'fileHash': payload.fileHash},
        replyToId: replyToId,
      );

      if (!AccountSession.isGenerationValid(sessionGen)) {
        print('[VOICE] sendOutgoingVoiceNote aborted post-encrypt: stale session $sessionGen');
        return false;
      }

      await chatRepo.enqueueOutbox(
        messageId: msgId,
        recipientNostrPubKey: recipientNostrPubKey,
        payloadJson: jsonEncode(payloadMap),
        createdAt: timestamp,
      );

      if (!AccountSession.isGenerationValid(sessionGen)) {
        print('[VOICE] sendOutgoingVoiceNote aborted post-enqueue: stale session $sessionGen');
        return false;
      }

      await signalService!.sendPreparedPayload(recipientNostrPubKey, payloadMap);

      if (!AccountSession.isGenerationValid(sessionGen)) {
        return true;
      }

      await chatRepo.updateOutboxStatus(
        msgId,
        status: 'sent',
        attempts: 1,
        lastAttemptAt: DateTime.now(),
      );

      if (message.status == MessageStatus.sending) {
        message.status = MessageStatus.sent;
        await chatRepo.updateMessageStatus(message.messageId, MessageStatus.sent);
        notifyListeners();
      }
      return true;
    } catch (e) {
      if (!AccountSession.isGenerationValid(sessionGen)) return false;
      print("Error transmitting voice note over Signal: $e");
      try {
        await chatRepo.updateOutboxAttempt(
          message.messageId,
          attempts: 1,
          lastAttemptAt: DateTime.now(),
          status: 'failed',
        );
      } catch (_) {}

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
    final sessionGen = AccountSession.currentGeneration;
    if (!AccountSession.isGenerationValid(sessionGen)) return false;

    if (isPeerIdentityBlocked(recipientNostrPubKey)) {
      print('[OUTBOX] retryOutgoingMessage BLOCKED for $recipientNostrPubKey: peer identity is blocked pending verification');
      return false;
    }

    // 1. Check if an Outbox record already exists for this message.
    // If found, re-transmit the stored ciphertext WITHOUT advancing the Double Ratchet!
    final outboxRecord = await chatRepo.getOutboxRecord(message.messageId);
    if (!AccountSession.isGenerationValid(sessionGen)) return false;

    if (outboxRecord != null) {
      message.status = MessageStatus.sending;
      await chatRepo.updateMessageStatus(message.messageId, MessageStatus.sending);
      notifyListeners();

      try {
        if (signalService == null || !AccountSession.isGenerationValid(sessionGen)) {
          throw StateError("Signal service not initialized or session stale");
        }
        final payloadMap = jsonDecode(outboxRecord.payloadJson) as Map<String, dynamic>;
        print('[OUTBOX] Retrying messageId=${message.messageId} using stored ciphertext (no ratchet advancement)...');
        await signalService!.sendPreparedPayload(outboxRecord.recipientNostrPubKey, payloadMap);

        if (!AccountSession.isGenerationValid(sessionGen)) return true;

        await chatRepo.updateOutboxStatus(
          message.messageId,
          status: 'sent',
          attempts: outboxRecord.attempts + 1,
          lastAttemptAt: DateTime.now(),
        );

        if (message.status != MessageStatus.delivered && message.status != MessageStatus.read) {
          message.status = MessageStatus.sent;
          await chatRepo.updateMessageStatus(message.messageId, MessageStatus.sent);
          notifyListeners();
        }
        return true;
      } catch (e) {
        if (!AccountSession.isGenerationValid(sessionGen)) return false;
        print('[OUTBOX] Error retrying stored payload: $e');
        try {
          await chatRepo.updateOutboxAttempt(
            message.messageId,
            attempts: outboxRecord.attempts + 1,
            lastAttemptAt: DateTime.now(),
            status: 'failed',
          );
        } catch (_) {}
        if (message.status == MessageStatus.sending) {
          message.status = MessageStatus.failed;
          await chatRepo.updateMessageStatus(message.messageId, MessageStatus.failed);
          notifyListeners();
        }
        return false;
      }
    }

    // Fallback: If no outbox record exists (e.g. legacy failed message before v4):
    final voicePayload = VoiceNotePayload.tryParse(message.text);
    if (voicePayload != null) {
      message.status = MessageStatus.sending;
      await chatRepo.updateMessageStatus(message.messageId, MessageStatus.sending);
      notifyListeners();

      try {
        VoiceNotePayload readyPayload = voicePayload;

        if (voicePayload.localPath != null && File(voicePayload.localPath!).existsSync()) {
          final prepared = await VoiceNoteService().prepareAndEncryptVoiceNote(
            localAudioPath: voicePayload.localPath!,
            durationMs: voicePayload.durationMs,
            waveform: voicePayload.waveform,
            sentAt: message.timestamp.millisecondsSinceEpoch,
          );

          if (!AccountSession.isGenerationValid(sessionGen)) return false;

          if (prepared != null) {
            readyPayload = prepared.payload;
            message.text = readyPayload.serialize();

            final uploadResult = await VoiceNoteService().uploadEncryptedBytes(
              prepared.encryptedBytes,
              readyPayload.fileHash,
              sessionGen: sessionGen,
            );
            if (!AccountSession.isGenerationValid(sessionGen)) return false;
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

        if (signalService == null || !AccountSession.isGenerationValid(sessionGen)) {
          throw StateError("Signal service not initialized or session stale");
        }
        final (msgId, payloadMap) = await signalService!.prepareEncryptedPayload(
          recipientNostrPubKey,
          readyPayload.serializeForNetwork(),
          sentAt: message.timestamp,
          messageId: message.messageId,
          type: 'voice_note',
          extraBody: {'fileHash': readyPayload.fileHash},
          replyToId: message.replyToId,
        );

        if (!AccountSession.isGenerationValid(sessionGen)) return false;

        await chatRepo.enqueueOutbox(
          messageId: msgId,
          recipientNostrPubKey: recipientNostrPubKey,
          payloadJson: jsonEncode(payloadMap),
          createdAt: message.timestamp,
        );

        if (!AccountSession.isGenerationValid(sessionGen)) return false;

        await signalService!.sendPreparedPayload(recipientNostrPubKey, payloadMap);

        if (!AccountSession.isGenerationValid(sessionGen)) return true;

        await chatRepo.updateOutboxStatus(
          msgId,
          status: 'sent',
          attempts: 1,
          lastAttemptAt: DateTime.now(),
        );

        if (message.status == MessageStatus.sending) {
          message.status = MessageStatus.sent;
          await chatRepo.updateMessageStatus(message.messageId, MessageStatus.sent);
          notifyListeners();
        }
        return true;
      } catch (e) {
        if (!AccountSession.isGenerationValid(sessionGen)) return false;
        print("Error retrying voice note: $e");
        try {
          await chatRepo.updateOutboxAttempt(
            message.messageId,
            attempts: 1,
            lastAttemptAt: DateTime.now(),
            status: 'failed',
          );
        } catch (_) {}

        if (message.status == MessageStatus.sending) {
          message.status = MessageStatus.failed;
          await chatRepo.updateMessageStatus(message.messageId, MessageStatus.failed);
          notifyListeners();
        }
        return false;
      }
    }

    // Regular text message fallback retry
    message.status = MessageStatus.sending;
    await chatRepo.updateMessageStatus(message.messageId, MessageStatus.sending);
    notifyListeners();

    try {
      if (signalService == null || !AccountSession.isGenerationValid(sessionGen)) {
        throw StateError("Signal service not initialized or session stale");
      }
      final (msgId, payloadMap) = await signalService!.prepareEncryptedPayload(
        recipientNostrPubKey,
        message.text,
        sentAt: message.timestamp,
        messageId: message.messageId,
        type: 'text',
        replyToId: message.replyToId,
      );

      if (!AccountSession.isGenerationValid(sessionGen)) return false;

      await chatRepo.enqueueOutbox(
        messageId: msgId,
        recipientNostrPubKey: recipientNostrPubKey,
        payloadJson: jsonEncode(payloadMap),
        createdAt: message.timestamp,
      );

      if (!AccountSession.isGenerationValid(sessionGen)) return false;

      await signalService!.sendPreparedPayload(recipientNostrPubKey, payloadMap);

      if (!AccountSession.isGenerationValid(sessionGen)) return true;

      await chatRepo.updateOutboxStatus(
        msgId,
        status: 'sent',
        attempts: 1,
        lastAttemptAt: DateTime.now(),
      );

      if (message.status == MessageStatus.sending) {
        message.status = MessageStatus.sent;
        await chatRepo.updateMessageStatus(message.messageId, MessageStatus.sent);
        notifyListeners();
      }
      return true;
    } catch (e) {
      if (!AccountSession.isGenerationValid(sessionGen)) return false;
      print("Error retrying message: $e");
      try {
        await chatRepo.updateOutboxAttempt(
          message.messageId,
          attempts: 1,
          lastAttemptAt: DateTime.now(),
          status: 'failed',
        );
      } catch (_) {}

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
    _lastResetTimestamps.clear();
    _lastPeerRetryTime.clear();
    notifyListeners();
  }

  Future<void> clearAll() async {
    stopListening();
    await chatRepo.clearAll();
    clearAllMemory();
  }
}

