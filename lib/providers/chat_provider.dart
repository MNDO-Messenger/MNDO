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
import '../models/media_payload.dart';
import '../models/verified_peer_identity.dart';
import '../services/account_session.dart';
import '../services/media_service.dart';

import 'package:shared_preferences/shared_preferences.dart';

import '../services/media_cache_manager.dart';
import '../services/outbox_dispatcher_service.dart';
import '../services/app_logger.dart';

class ChatProvider extends ChangeNotifier {
  ChatRepository chatRepo;
  AuthProvider authProvider;
  SignalMessagingService? signalService;
  late OutboxDispatcherService outboxDispatcher;

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
  final Map<String, DateTime> _lastPeerRetryTime = {};
  MasterBindingVerifier masterBindingVerifier;

  final Set<String> _blockedUserPubKeys = {};
  bool _blockedUsersLoaded = false;
  bool get blockedUsersLoaded => _blockedUsersLoaded;
  Set<String> get blockedUserPubKeys => Set.unmodifiable(_blockedUserPubKeys);

  ChatProvider({
    required this.chatRepo,
    required this.authProvider,
    required this.signalService,
    MasterBindingVerifier? masterBindingVerifier,
  }) : masterBindingVerifier =
           masterBindingVerifier ??
           MasterBindingVerifier(cryptoService: authProvider.cryptoService) {
    outboxDispatcher = OutboxDispatcherService(
      chatRepo: chatRepo,
      getSignalService: () => signalService,
      isPeerIdentityBlocked: isPeerIdentityBlocked,
      onMessageStatusChanged: _handleOutboxMessageStatusChanged,
    );
    _bindSignalService();
    unawaited(_loadBlockedUsers());
  }

  void _handleOutboxMessageStatusChanged(
    String messageId,
    MessageStatus status,
  ) {
    for (final chat in chatHistories.values) {
      for (final msg in chat) {
        if (msg.messageId == messageId) {
          msg.status = status;
          break;
        }
      }
    }
    notifyListeners();
  }

  void updateDependencies(
    ChatRepository newRepo,
    AuthProvider newAuth,
    SignalMessagingService? newSignal,
  ) {
    chatRepo = newRepo;
    authProvider = newAuth;
    signalService = newSignal;
    masterBindingVerifier = MasterBindingVerifier(
      cryptoService: newAuth.cryptoService,
    );
    outboxDispatcher.updateDependencies(
      newRepo: newRepo,
      newGetSignalService: () => newSignal,
      newIsPeerIdentityBlocked: isPeerIdentityBlocked,
    );
    _bindSignalService();
    unawaited(_loadBlockedUsers());
  }

  String _prefKey(String base) =>
      'mndo_chat_${authProvider.masterPublicKeyHex ?? "anon"}_$base';

  Future<void> _loadBlockedUsers() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(_prefKey('blocked_users')) ?? [];
      _blockedUserPubKeys.clear();
      _blockedUserPubKeys.addAll(list);
      _blockedUsersLoaded = true;
      notifyListeners();
    } catch (_) {}
  }

  bool isUserBlocked(String peerNostrPubKey) {
    if (_blockedUserPubKeys.contains(peerNostrPubKey)) return true;
    final aliased = _keyAliases[peerNostrPubKey];
    if (aliased != null && _blockedUserPubKeys.contains(aliased)) return true;
    return false;
  }

  Future<void> blockUser(
    String peerNostrPubKey, {
    String? peerMasterPubKey,
  }) async {
    _blockedUserPubKeys.add(peerNostrPubKey);
    if (peerMasterPubKey != null && peerMasterPubKey.isNotEmpty) {
      _blockedUserPubKeys.add(peerMasterPubKey);
    }
    final aliased = _keyAliases[peerNostrPubKey];
    if (aliased != null) {
      _blockedUserPubKeys.add(aliased);
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        _prefKey('blocked_users'),
        _blockedUserPubKeys.toList(),
      );
    } catch (_) {}

    // Cancel and purge any pending outbox items directed to this peer
    try {
      await chatRepo.db.deleteOutboxForPeer(peerNostrPubKey);
      if (aliased != null) {
        await chatRepo.db.deleteOutboxForPeer(aliased);
      }
    } catch (_) {}

    // Immediately mark active chat entries offline so presence UI updates instantly
    for (final user in activeChats) {
      if (user.nostrPubKeyHex == peerNostrPubKey ||
          user.masterPubKeyHex == peerNostrPubKey ||
          (peerMasterPubKey != null &&
              (user.masterPubKeyHex == peerMasterPubKey ||
                  user.nostrPubKeyHex == peerMasterPubKey)) ||
          (aliased != null &&
              (user.nostrPubKeyHex == aliased ||
                  user.masterPubKeyHex == aliased))) {
        user.markOffline();
      }
    }

    notifyListeners();
  }

  Future<void> unblockUser(
    String peerNostrPubKey, {
    String? peerMasterPubKey,
  }) async {
    _blockedUserPubKeys.remove(peerNostrPubKey);
    if (peerMasterPubKey != null) {
      _blockedUserPubKeys.remove(peerMasterPubKey);
    }
    final aliased = _keyAliases[peerNostrPubKey];
    if (aliased != null) {
      _blockedUserPubKeys.remove(aliased);
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        _prefKey('blocked_users'),
        _blockedUserPubKeys.toList(),
      );
    } catch (_) {}

    notifyListeners();
  }

  /// Clears conversation completely:
  /// 1. Shreds all physical media and voice note files on disk
  /// 2. Deletes all SQLite chat_messages and outbox_messages
  /// 3. Clears in-memory RAM history and unread counts
  Future<void> clearConversation(String peerNostrPubKey) async {
    // 1. Shred disk files and delete DB records
    await chatRepo.clearChatForPeer(peerNostrPubKey);
    final aliased = _keyAliases[peerNostrPubKey];
    if (aliased != null) {
      await chatRepo.clearChatForPeer(aliased);
    }

    // 2. Clear RAM state
    chatHistories[peerNostrPubKey]?.clear();
    chatHistories.remove(peerNostrPubKey);
    unreadCounts[peerNostrPubKey] = 0;
    if (aliased != null) {
      chatHistories[aliased]?.clear();
      chatHistories.remove(aliased);
      unreadCounts[aliased] = 0;
    }

    final activeIndex = activeChats.indexWhere(
      (u) => u.nostrPubKeyHex == peerNostrPubKey || u.nostrPubKeyHex == aliased,
    );
    if (activeIndex != -1) {
      activeChats[activeIndex].lastSeenFromMessage = null;
    }

    notifyListeners();
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
        (aliased != null &&
            (signalService?.isIdentityBlocked(aliased) ?? false));
  }

  /// Authoritative check across all sending paths:
  /// Verifies peer is not blocked, identity is not blocked, and an active encryption session exists
  Future<bool> canSendToPeer(String peerNostrPubKey) async {
    if (isUserBlocked(peerNostrPubKey)) return false;
    if (isPeerIdentityBlocked(peerNostrPubKey)) return false;
    if (signalService == null) return false;
    final canDirect = await signalService!.canSendToPeer(peerNostrPubKey);
    if (canDirect) return true;
    final aliased = _keyAliases[peerNostrPubKey];
    if (aliased != null &&
        !isPeerIdentityBlocked(aliased) &&
        !isUserBlocked(aliased)) {
      return await signalService!.canSendToPeer(aliased);
    }
    return false;
  }

  Future<void> handlePeerIdentityKeyChanged(String peerNostrPubKey) async {
    _blockedIdentityPeers.add(peerNostrPubKey);
    final history = chatHistories[peerNostrPubKey];
    final lastNotice = history
        ?.where((m) => m.text.contains("Peer's Signal identity key changed"))
        .lastOrNull;
    if (lastNotice == null ||
        DateTime.now().difference(lastNotice.timestamp).inSeconds >= 10) {
      await addMessage(
        peerNostrPubKey,
        ChatMessage(
          text: "⚠️ Security Notice: Peer's Signal identity key changed. Messages are paused to protect your privacy. Tap to verify Safety Number.",
          isMe: false,
          timestamp: DateTime.now(),
          status: MessageStatus.sent,
        ),
      );
    }
    notifyListeners();
  }

  Future<bool> approvePeerIdentity(String peerNostrPubKey) async {
    if (signalService == null) return false;
    final success = await signalService!.approveUntrustedIdentity(
      peerNostrPubKey,
    );
    if (success) {
      _blockedIdentityPeers.remove(peerNostrPubKey);
      await addMessage(
        peerNostrPubKey,
        ChatMessage(
          text: "✅ Security Identity Verified: New encryption key approved. End-to-end encryption restored.",
          isMe: false,
          timestamp: DateTime.now(),
          status: MessageStatus.sent,
        ),
      );
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
    outboxDispatcher.stopPeriodicDrain();
    _globalMessageSubscription?.cancel();
    _globalMessageSubscription = null;
    signalService?.stopPeriodicReplenishment();
    NostrRelayService().unregisterMessageSubscription();
  }

  @override
  void dispose() {
    stopListening();
    outboxDispatcher.dispose();
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
    final index = activeChats.indexWhere(
      (u) => u.masterPubKeyHex == masterPubKeyHex,
    );
    if (index != -1) {
      final user = activeChats[index];
      bool changed = false;

      // Only upgrade if incoming username is real (never overwrite a real username with a Ghost name)
      if (username.isNotEmpty &&
          !username.startsWith('Ghost #') &&
          user.username != username) {
        user.username = username;
        changed = true;
      }
      if (displayName != null &&
          displayName.isNotEmpty &&
          user.displayName != displayName) {
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

  List<ChatMessage> getMessagesFor(
    String nostrPubKey, {
    String? masterPubKeyHex,
  }) {
    if (chatHistories.containsKey(nostrPubKey) &&
        chatHistories[nostrPubKey]!.isNotEmpty) {
      return chatHistories[nostrPubKey]!;
    }
    final targetKey = _keyAliases[nostrPubKey];
    if (targetKey != null &&
        chatHistories.containsKey(targetKey) &&
        chatHistories[targetKey]!.isNotEmpty) {
      return chatHistories[targetKey]!;
    }
    if (masterPubKeyHex != null && masterPubKeyHex.isNotEmpty) {
      final user = activeChats
          .where((u) => u.masterPubKeyHex == masterPubKeyHex)
          .firstOrNull;
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
    if (isUserBlocked(masterPubKeyHex) ||
        (nostrPubKeyHex != null && isUserBlocked(nostrPubKeyHex)) ||
        (_keyAliases[masterPubKeyHex] != null &&
            isUserBlocked(_keyAliases[masterPubKeyHex]!)) ||
        (nostrPubKeyHex != null &&
            _keyAliases[nostrPubKeyHex] != null &&
            isUserBlocked(_keyAliases[nostrPubKeyHex]!))) {
      return;
    }
    final index = activeChats.indexWhere(
      (u) =>
          (masterPubKeyHex.isNotEmpty &&
              u.masterPubKeyHex == masterPubKeyHex) ||
          (nostrPubKeyHex != null &&
              nostrPubKeyHex.isNotEmpty &&
              u.nostrPubKeyHex == nostrPubKeyHex),
    );
    if (index != -1) {
      final user = activeChats[index];
      // Guard: Never cross-alias if masterPubKeyHex is provided and differs
      if (masterPubKeyHex.isNotEmpty &&
          user.masterPubKeyHex.isNotEmpty &&
          user.masterPubKeyHex != masterPubKeyHex) {
        AppLogger.warning(
          '[PRESENCE] SECURITY ALERT: Rejecting presence update for ${user.username}: mismatched master key (${AppLogger.redactMasterKey(masterPubKeyHex)} != ${AppLogger.redactMasterKey(user.masterPubKeyHex)})',
        );
        return;
      }
      if (nostrPubKeyHex != null &&
          nostrPubKeyHex.isNotEmpty &&
          user.nostrPubKeyHex != nostrPubKeyHex) {
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

  Future<SaveMessageResult> addMessage(
    String nostrPubKey,
    ChatMessage message,
  ) async {
    // 1. Authoritative persistence in repository FIRST - SQLite constraint is final arbiter
    final result = await chatRepo.saveMessage(nostrPubKey, message);

    if (result == SaveMessageResult.conflictingId) {
      AppLogger.warning(
        '[CHAT] Rejecting conflicting messageId collision for ${message.messageId}',
      );
      return result;
    }

    if (result == SaveMessageResult.identicalDuplicate) {
      return result;
    }

    if (result != SaveMessageResult.inserted) {
      return result;
    }

    // 2. Only upon CONFIRMED insertion, mutate in-memory history and unread count:
    if (!chatHistories.containsKey(nostrPubKey)) {
      chatHistories[nostrPubKey] = [];
    }
    final history = chatHistories[nostrPubKey]!;

    // Deduplication check: prevent duplicate bubbles if already in memory
    final isDuplicate = history.any(
      (m) =>
          m.messageId == message.messageId ||
          (m.isMe == message.isMe &&
              m.text == message.text &&
              m.timestamp.millisecondsSinceEpoch ==
                  message.timestamp.millisecondsSinceEpoch),
    );
    if (!isDuplicate) {
      history.add(message);
      history.sort((a, b) => a.timestamp.compareTo(b.timestamp));

      // Check if this chat is active AND app is focused before skipping unread increment
      final isActiveChat =
          isAppFocused &&
          (activeChatUserId == nostrPubKey ||
              (_keyAliases[nostrPubKey] != null &&
                  activeChatUserId == _keyAliases[nostrPubKey]));
      if (!isActiveChat && !message.isMe) {
        unreadCounts[nostrPubKey] = (unreadCounts[nostrPubKey] ?? 0) + 1;
      }

      _sortActiveChats();
      notifyListeners();
    }

    return result;
  }

  Future<void> sendReceipt({
    required String recipientNostrPubKey,
    required String targetMessageId,
    required String status,
  }) async {
    try {
      if (signalService == null) return;
      if (isUserBlocked(recipientNostrPubKey) ||
          isPeerIdentityBlocked(recipientNostrPubKey)) {
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
          AppLogger.debug(
            '[MSG] SEND_RECEIPT aborted: peer ${AppLogger.redactNostrKey(recipientNostrPubKey)} identity is blocked',
          );
          return;
        }
        final aliased = _keyAliases[recipientNostrPubKey];
        if (aliased != null && isPeerIdentityBlocked(aliased)) {
          AppLogger.debug(
            '[MSG] SEND_RECEIPT aborted: peer ${AppLogger.redactNostrKey(aliased)} identity is blocked',
          );
          return;
        }

        AppLogger.debug(
          '[MSG] SEND_RECEIPT no active session for ${AppLogger.redactNostrKey(recipientNostrPubKey)}, establishing...',
        );
        final chatUser = activeChats
            .where(
              (c) =>
                  c.nostrPubKeyHex == recipientNostrPubKey ||
                  _keyAliases[c.nostrPubKeyHex] == recipientNostrPubKey ||
                  _keyAliases[recipientNostrPubKey] == c.nostrPubKeyHex,
            )
            .firstOrNull;
        final expectedMaster = chatUser?.masterPubKeyHex;

        sessionReady = await signalService!.fetchAndEstablishSession(
          recipientNostrPubKey,
          masterPubKeyHex: expectedMaster,
        );
        if (sessionReady) {
          activeKey = recipientNostrPubKey;
        } else {
          AppLogger.warning(
            '[MSG] SEND_RECEIPT cannot establish session for ${AppLogger.redactNostrKey(recipientNostrPubKey)}, aborting receipt',
          );
          if (status == 'read') {
            _lastReadReceiptSentMsgId.remove(recipientNostrPubKey);
            _lastReadReceiptSentMsgId.remove(activeKey);
          }
          return;
        }
      }

      if (isPeerIdentityBlocked(activeKey)) {
        AppLogger.debug(
          '[MSG] SEND_RECEIPT aborted: peer ${AppLogger.redactNostrKey(activeKey)} identity is blocked',
        );
        return;
      }

      AppLogger.debug(
        '[MSG] SEND_RECEIPT status=$status targetId=$targetMessageId recipient=${AppLogger.redactNostrKey(activeKey)}',
      );
      await signalService!.sendMessage(
        activeKey,
        '',
        type: 'receipt',
        extraBody: {'targetId': targetMessageId, 'status': status},
      );
      if (status == 'read') {
        _lastReadReceiptSentMsgId[recipientNostrPubKey] = targetMessageId;
        _lastReadReceiptSentMsgId[activeKey] = targetMessageId;
      }
    } catch (e) {
      AppLogger.warning('sendReceipt error: $e');
      if (status == 'read') {
        _lastReadReceiptSentMsgId.remove(recipientNostrPubKey);
      }
    }
  }

  Future<void> recordScreenshotTaken(
    String peerNostrPubKey, {
    required bool isMe,
  }) async {
    final sessionGen = AccountSession.currentGeneration;
    if (!AccountSession.isGenerationValid(sessionGen)) return;

    final text = isMe ? '📷 You took a screenshot' : '📷 Screenshot was taken';
    final noticeMsg = ChatMessage(
      text: text,
      isMe: isMe,
      timestamp: DateTime.now(),
      status: MessageStatus.sent,
    );

    await addMessage(peerNostrPubKey, noticeMsg);

    if (isMe) {
      unawaited(notifyScreenshotTaken(peerNostrPubKey));
    }
  }

  Future<void> notifyScreenshotTaken(String recipientNostrPubKey) async {
    AppLogger.info(
      '[CHAT] Screenshot detected! Sending secure notification to ${AppLogger.redactNostrKey(recipientNostrPubKey)}',
    );
    await sendControlMessage(
      recipientNostrPubKey: recipientNostrPubKey,
      control: 'SCREENSHOT_TAKEN',
    );
  }

  Future<void> sendControlMessage({
    required String recipientNostrPubKey,
    required String control,
  }) async {
    final sessionGen = AccountSession.currentGeneration;
    if (!AccountSession.isGenerationValid(sessionGen)) return;
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

      if (!AccountSession.isGenerationValid(sessionGen)) {
        AppLogger.debug(
          '[CHAT] sendControlMessage aborted post-sign: stale session $sessionGen (active: ${AccountSession.currentGeneration})',
        );
        return;
      }

      final payload = {
        'type': -1,
        'control': control,
        'senderMasterPubKey': authProvider.masterPublicKeyHex ?? '',
        if (sig != null) 'sig': sig,
        'sentAt': nowMs,
      };
      await NostrRelayService().sendEncryptedPayload(
        recipientNostrPubKey,
        jsonEncode(payload),
        sessionGen: sessionGen,
      );
      AppLogger.debug(
        "Sent control message '$control' to ${AppLogger.redactNostrKey(recipientNostrPubKey)} (authenticated: ${sig != null})",
      );
    } catch (e) {
      AppLogger.warning("sendControlMessage error: $e");
    }
  }

  String _findPeerKeyForReceipt(String senderNostrPubKey, String targetId) {
    if (chatHistories[senderNostrPubKey]?.any((m) => m.messageId == targetId) ??
        false) {
      return senderNostrPubKey;
    }
    final aliased = _keyAliases[senderNostrPubKey];
    if (aliased != null &&
        (chatHistories[aliased]?.any((m) => m.messageId == targetId) ??
            false)) {
      return aliased;
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
    final unreadIncoming = history
        .where((m) => !m.isMe && m.status != MessageStatus.read)
        .toList();
    for (final msg in unreadIncoming) {
      msg.status = MessageStatus.read;
      unawaited(
        chatRepo.updateMessageStatus(msg.messageId, MessageStatus.read),
      );
    }

    // Telegram-style Cumulative Read Watermark:
    // Only dispatch a single receipt acknowledging the latest incoming message
    final latestIncoming = history.where((m) => !m.isMe).lastOrNull;
    if (latestIncoming != null &&
        _lastReadReceiptSentMsgId[nostrPubKey] != latestIncoming.messageId) {
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

  void _logIdentityBindingViolation({
    required String event,
    required String senderNostrPubKey,
    String? expectedMaster,
    String? claimedMaster,
    String? reason,
    String? messageId,
  }) {
    final senderFp = senderNostrPubKey.length > 8
        ? senderNostrPubKey.substring(0, 8)
        : senderNostrPubKey;
    final expFp = expectedMaster != null && expectedMaster.length > 8
        ? expectedMaster.substring(0, 8)
        : (expectedMaster ?? 'none');
    final claimFp = claimedMaster != null && claimedMaster.length > 8
        ? claimedMaster.substring(0, 8)
        : (claimedMaster ?? 'none');
    AppLogger.warning(
      '[SECURITY ALERT] event=$event peer=$senderFp expected=$expFp claimed=$claimFp msgId=$messageId gen=${AccountSession.currentGeneration} reason=$reason',
    );
  }

  @visibleForTesting
  Future<void> handleIncomingEventForTest(NostrEvent event) =>
      _handleIncomingNostrEvent(event);

  Future<void> _handleIncomingNostrEvent(NostrEvent event) async {
    final sessionGen = AccountSession.currentGeneration;
    if (!AccountSession.isGenerationValid(sessionGen)) {
      AppLogger.debug(
        '[CHAT] Dropping incoming Nostr event: stale session gen $sessionGen != current ${AccountSession.currentGeneration}',
      );
      return;
    }
    if (signalService == null) return;

    final senderNostrPubKey = event.pubkey;
    AppLogger.debug(
      "Received incoming event kind ${event.kind} from ${AppLogger.redactNostrKey(senderNostrPubKey)}. Content length: ${event.content?.length}",
    );

    if (event.kind == 4444 && event.content != null) {
      AppLogger.debug('[RECV] Kind 4444 received. Attempting to parse JSON...');
      Map<String, dynamic> map;
      try {
        map = jsonDecode(event.content!);
      } catch (e) {
        AppLogger.warning("JSON parsing failed: $e");
        return;
      }

      // Check for unencrypted control messages (e.g. session renegotiation / reset requests)
      if (map['type'] == -1 || map['control'] != null) {
        final control = map['control'] as String?;
        if (control == 'RESET_SESSION') {
          // Gate 1: Known Contact / Conversation Check (Anti-DoS / Anti-Spam)
          // Drop reset requests from strangers on Nostr who do not have an active chat or known contact entry
          final isKnownPeer =
              chatHistories.containsKey(senderNostrPubKey) ||
              activeChats.any(
                (c) =>
                    c.nostrPubKeyHex == senderNostrPubKey ||
                    (map['senderMasterPubKey'] != null &&
                        c.masterPubKeyHex == map['senderMasterPubKey']),
              );
          if (!isKnownPeer) {
            AppLogger.debug(
              '[RECV] Dropping unauthenticated RESET_SESSION from unknown peer ${AppLogger.redactNostrKey(senderNostrPubKey)} (no chat history)',
            );
            return;
          }

          // Gate 2: Freshness / Anti-Replay Check (within 120 seconds)
          final sentAt = map['sentAt'] as int?;
          if (sentAt != null) {
            final ageSeconds =
                (DateTime.now().millisecondsSinceEpoch - sentAt).abs() / 1000;
            if (ageSeconds > 120) {
              AppLogger.debug(
                '[RECV] Dropping stale RESET_SESSION from ${AppLogger.redactNostrKey(senderNostrPubKey)} (age: ${ageSeconds.toStringAsFixed(1)}s > 120s)',
              );
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
            AppLogger.warning(
              '[RECV] SECURITY ALERT: Dropping unauthenticated RESET_SESSION from ${AppLogger.redactNostrKey(senderNostrPubKey)}: ${verifyResult.reason} (${verifyResult.errorMessage})',
            );
            return;
          }

          // Strict sanity check against local pinned contact
          final knownContact = activeChats
              .where((c) => c.nostrPubKeyHex == senderNostrPubKey)
              .firstOrNull;
          if (knownContact != null &&
              knownContact.masterPubKeyHex.isNotEmpty &&
              knownContact.masterPubKeyHex != senderMasterPubKey) {
            AppLogger.warning(
              '[RECV] SECURITY ALERT: RESET_SESSION senderMasterPubKey mismatch (${AppLogger.redactMasterKey(senderMasterPubKey)} != ${AppLogger.redactMasterKey(knownContact.masterPubKeyHex)}) from ${AppLogger.redactNostrKey(senderNostrPubKey)}! Dropping.',
            );
            return;
          }

          // Gate 4: Cooldown (ignore repeated RESET_SESSION from same peer within 60 seconds)
          final now = DateTime.now();
          final lastReset = _lastResetTimestamps[senderNostrPubKey];
          if (lastReset != null && now.difference(lastReset).inSeconds < 60) {
            AppLogger.debug(
              '[RECV] RESET_SESSION from ${AppLogger.redactNostrKey(senderNostrPubKey)} ignored (cooldown: ${now.difference(lastReset).inSeconds}s ago)',
            );
            return;
          }
          _lastResetTimestamps[senderNostrPubKey] = now;

          AppLogger.debug(
            "Received authenticated RESET_SESSION control request from ${AppLogger.redactNostrKey(senderNostrPubKey)}. Rebuilding session from network...",
          );
          await signalService!.fetchAndEstablishSession(
            senderNostrPubKey,
            masterPubKeyHex: senderMasterPubKey,
            force: true,
          );
          if (!AccountSession.isGenerationValid(sessionGen)) return;

          // Only retry messages stuck in sending/failed — never re-send already-sent messages
          // (re-sending 'sent' messages causes tick→clock→tick flicker)
          final history = chatHistories[senderNostrPubKey];
          if (history != null) {
            final pendingMsg = history
                .where(
                  (m) =>
                      m.isMe &&
                      (m.status == MessageStatus.sending ||
                          m.status == MessageStatus.failed),
                )
                .lastOrNull;
            if (pendingMsg != null) {
              if (!AccountSession.isGenerationValid(sessionGen)) return;
              AppLogger.debug(
                "Re-sending pending message ${pendingMsg.messageId} after session reset...",
              );
              await retryOutgoingMessage(
                senderNostrPubKey,
                pendingMsg,
                respectBackoff: true,
              );
            }
          }
          return;
        } else if (control == 'SCREENSHOT_TAKEN') {
          // Gate 1: Known Contact / Conversation Check (Anti-DoS / Anti-Spam)
          final isKnownPeer =
              chatHistories.containsKey(senderNostrPubKey) ||
              activeChats.any(
                (c) =>
                    c.nostrPubKeyHex == senderNostrPubKey ||
                    (map['senderMasterPubKey'] != null &&
                        c.masterPubKeyHex == map['senderMasterPubKey']),
              );
          if (!isKnownPeer) {
            AppLogger.debug(
              '[RECV] Dropping SCREENSHOT_TAKEN from unknown peer ${AppLogger.redactNostrKey(senderNostrPubKey)}',
            );
            return;
          }

          AppLogger.info(
            '[RECV] Validated SCREENSHOT_TAKEN notification from ${AppLogger.redactNostrKey(senderNostrPubKey)}',
          );
          await recordScreenshotTaken(senderNostrPubKey, isMe: false);
          return;
        }
      }

      AppLogger.debug("Attempting to decrypt message...");
      final result = await signalService!.decryptMessage(
        senderNostrPubKey,
        map,
      );

      // CRITICAL SECURITY BARRIER: Inbound decryption post-await generation check
      if (!AccountSession.isGenerationValid(sessionGen)) {
        AppLogger.debug(
          '[CHAT] Dropping decrypted incoming message: session generation $sessionGen is stale',
        );
        return;
      }

      if (result == null) {
        if (!AccountSession.isGenerationValid(sessionGen)) return;
        // Cooldown: only send RESET_SESSION if we haven't sent one to this peer recently
        final now = DateTime.now();
        final lastReset = _lastResetTimestamps[senderNostrPubKey];
        if (lastReset == null || now.difference(lastReset).inSeconds >= 60) {
          _lastResetTimestamps[senderNostrPubKey] = now;
          AppLogger.warning(
            '[RECV] Signal decrypt failure id=${map['id']} from=${AppLogger.redactNostrKey(senderNostrPubKey)}. Requesting session renegotiation...',
          );
          unawaited(
            sendControlMessage(
              recipientNostrPubKey: senderNostrPubKey,
              control: 'RESET_SESSION',
            ),
          );
        } else {
          AppLogger.debug(
            '[RECV] Signal decrypt failure id=${map['id']} from=${AppLogger.redactNostrKey(senderNostrPubKey)}. RESET_SESSION suppressed (cooldown)',
          );
        }
        return;
      }

      AppLogger.debug('[RECV] Signal decrypt success');
      final plaintext = result.$1;
      final senderMasterPubKeyFromPayload = result.$2;
      final sentAt = result.$3;
      final incomingMsgId = result.$4;
      final isIdentityKeyChanged = result.$5;

      if (plaintext == "__DUPLICATE_MESSAGE__") {
        if (!AccountSession.isGenerationValid(sessionGen)) return;
        AppLogger.debug(
          '[RECV] Dropping duplicate/replayed message id=$incomingMsgId; re-acknowledging delivery receipt',
        );
        if (incomingMsgId != null && incomingMsgId.isNotEmpty) {
          unawaited(
            sendReceipt(
              recipientNostrPubKey: senderNostrPubKey,
              targetMessageId: incomingMsgId,
              status: 'delivered',
            ),
          );
        }
        return;
      }

      if (plaintext == "__UNTRUSTED_IDENTITY__") {
        if (!AccountSession.isGenerationValid(sessionGen)) return;
        AppLogger.warning(
          '[RECV] Incoming message from ${AppLogger.redactNostrKey(senderNostrPubKey)} BLOCKED due to untrusted identity key change.',
        );
        await handlePeerIdentityKeyChanged(senderNostrPubKey);
        return;
      }

      if (plaintext == "__NEED_SESSION_RESET__") {
        if (!AccountSession.isGenerationValid(sessionGen)) return;
        AppLogger.debug(
          "Decryption failed for ${AppLogger.redactNostrKey(senderNostrPubKey)} (missing/invalid session). Sending RESET_SESSION request...",
        );
        unawaited(
          sendControlMessage(
            recipientNostrPubKey: senderNostrPubKey,
            control: 'RESET_SESSION',
          ),
        );
        return;
      }

      // Target #1: Visual Security Alert on peer identity key change
      if (isIdentityKeyChanged) {
        if (!AccountSession.isGenerationValid(sessionGen)) return;
        await handlePeerIdentityKeyChanged(senderNostrPubKey);
      }

      if (plaintext == "__SESSION_RESET__") {
        if (!AccountSession.isGenerationValid(sessionGen)) return;
        AppLogger.debug(
          "Received session reset from ${AppLogger.redactNostrKey(senderNostrPubKey)}. Deleting local session.",
        );
        await signalService!.deleteSession(senderNostrPubKey);
        return;
      }

      // Mandatory Cryptographic Identity-Binding Gate (Fail-Closed, Gates G2, G3, G4)
      final VerifiedPeerIdentity? verifiedIdentity = await signalService
          ?.getVerifiedPeerIdentity(senderNostrPubKey);
      if (verifiedIdentity == null) {
        _logIdentityBindingViolation(
          event: 'UNVERIFIED_PEER_REJECTED',
          senderNostrPubKey: senderNostrPubKey,
          reason: 'No cryptographically verified Master binding found for peer',
          messageId: incomingMsgId,
        );
        return; // Fail-closed: drop message, do not auto-create contact or process receipts
      }

      // Strict Consistency Invariant: Envelope senderMasterPubKey must be non-empty and match verified Master
      if (senderMasterPubKeyFromPayload.isEmpty ||
          senderMasterPubKeyFromPayload != verifiedIdentity.masterPubKeyHex) {
        _logIdentityBindingViolation(
          event: senderMasterPubKeyFromPayload.isEmpty
              ? 'MISSING_SENDER_IDENTITY_REJECTED'
              : 'MASTER_MISMATCH_REJECTED',
          senderNostrPubKey: senderNostrPubKey,
          expectedMaster: verifiedIdentity.masterPubKeyHex,
          claimedMaster: senderMasterPubKeyFromPayload,
          reason: senderMasterPubKeyFromPayload.isEmpty
              ? 'Envelope is missing required senderMasterPubKey'
              : 'Envelope senderMasterPubKey does not match verified Master binding',
          messageId: incomingMsgId,
        );
        return; // Fail-closed: drop message, do not persist, reassign, or notify
      }

      // Stealth Blocking Gate: Drop messages and receipts silently without dispatching receipts, DB writes, or notifications
      if (isUserBlocked(senderNostrPubKey) ||
          isUserBlocked(verifiedIdentity.masterPubKeyHex)) {
        AppLogger.debug(
          '[STEALTH_BLOCK] Silently dropped incoming event from blocked peer: ${AppLogger.redactNostrKey(senderNostrPubKey)}',
        );
        return;
      }

      // Target #9: Process receipt envelopes without creating chat bubbles
      final receiptEnvelope = MndoMessageEnvelope.tryParse(plaintext);
      if (receiptEnvelope != null && receiptEnvelope.type == 'receipt') {
        if (!AccountSession.isGenerationValid(sessionGen)) return;
        if (receiptEnvelope.senderMasterPubKey !=
            verifiedIdentity.masterPubKeyHex) {
          _logIdentityBindingViolation(
            event: 'MASTER_MISMATCH_REJECTED',
            senderNostrPubKey: senderNostrPubKey,
            expectedMaster: verifiedIdentity.masterPubKeyHex,
            claimedMaster: receiptEnvelope.senderMasterPubKey,
            reason: 'Receipt envelope senderMasterPubKey does not match verified Master binding',
            messageId: incomingMsgId,
          );
          return;
        }
        final targetId = receiptEnvelope.body['targetId'] as String?;
        final statusStr = receiptEnvelope.body['status'] as String?;
        if (targetId != null && statusStr != null) {
          AppLogger.debug(
            '[MSG] ${statusStr.toUpperCase()}_RECEIPT targetId=$targetId from=${AppLogger.redactNostrKey(senderNostrPubKey)}',
          );
          ChatMessage? targetMsg;
          final directHistory =
              chatHistories[senderNostrPubKey] ??
              (_keyAliases[senderNostrPubKey] != null
                  ? chatHistories[_keyAliases[senderNostrPubKey]!]
                  : null);
          if (directHistory != null) {
            targetMsg = directHistory
                .where((m) => m.messageId == targetId)
                .firstOrNull;
          }

          if (statusStr == 'read') {
            DateTime? cutoff = targetMsg?.timestamp;
            if (cutoff == null) {
              final dbRecord = await chatRepo.getMessageByMessageId(targetId);
              if (dbRecord != null &&
                  (dbRecord.nostrPubKeyHex == senderNostrPubKey ||
                      dbRecord.nostrPubKeyHex ==
                          _keyAliases[senderNostrPubKey])) {
                cutoff = dbRecord.timestamp;
              }
            }

            if (!AccountSession.isGenerationValid(sessionGen)) return;
            if (cutoff != null) {
              final peerKey = _findPeerKeyForReceipt(
                senderNostrPubKey,
                targetId,
              );
              final keysToUpdate = {
                senderNostrPubKey,
                peerKey,
                if (_keyAliases[senderNostrPubKey] != null)
                  _keyAliases[senderNostrPubKey]!,
                if (_keyAliases[peerKey] != null) _keyAliases[peerKey]!,
              };
              for (final key in keysToUpdate) {
                if (!AccountSession.isGenerationValid(sessionGen)) return;
                final hist = chatHistories[key];
                if (hist != null) {
                  for (final m in hist) {
                    if (m.isMe &&
                        !m.timestamp.isAfter(cutoff) &&
                        m.status != MessageStatus.read) {
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
            } else if (targetMsg != null) {
              if (!AccountSession.isGenerationValid(sessionGen)) return;
              targetMsg.status = MessageStatus.read;
              await chatRepo.updateMessageStatus(targetId, MessageStatus.read);
              await chatRepo.deleteFromOutbox(targetId);
              notifyListeners();
            }
          } else if (statusStr == 'delivered') {
            if (!AccountSession.isGenerationValid(sessionGen)) return;
            if (targetMsg != null && targetMsg.status != MessageStatus.read) {
              targetMsg.status = MessageStatus.delivered;
              await chatRepo.updateMessageStatus(
                targetId,
                MessageStatus.delivered,
              );
              notifyListeners();
            } else if (targetMsg != null) {
              await chatRepo.updateMessageStatus(
                targetId,
                MessageStatus.delivered,
              );
            }
            if (targetMsg != null) {
              await chatRepo.deleteFromOutbox(targetId);
            }
          }
        }
        return;
      }

      if (!AccountSession.isGenerationValid(sessionGen)) return;

      // Peer is actively sending messages: opportunistic retry for any pending unacknowledged outbox items
      unawaited(retryUnacknowledgedForPeer(senderNostrPubKey));

      final masterPubKeyToVerify = verifiedIdentity.masterPubKeyHex;

      // Determine message timestamp from sender's payload, falling back to event.createdAt or now
      DateTime messageTimestamp = sentAt ?? event.createdAt ?? DateTime.now();
      final mediaPayload = MediaPayload.tryParse(plaintext);
      if (mediaPayload != null && mediaPayload.sentAt != null) {
        messageTimestamp = DateTime.fromMillisecondsSinceEpoch(
          mediaPayload.sentAt!,
        );
      } else {
        final voicePayload = VoiceNotePayload.tryParse(plaintext);
        if (voicePayload != null && voicePayload.sentAt != null) {
          messageTimestamp = DateTime.fromMillisecondsSinceEpoch(
            voicePayload.sentAt!,
          );
        }
      }

      final now = DateTime.now();
      final messageAgeSeconds =
          (now.millisecondsSinceEpoch -
              messageTimestamp.millisecondsSinceEpoch) /
          1000.0;
      final isRecentLiveMessage =
          messageAgeSeconds >= -300 && messageAgeSeconds < 70;

      final existingIndex = activeChats.indexWhere(
        (u) => u.nostrPubKeyHex == senderNostrPubKey,
      );

      if (!AccountSession.isGenerationValid(sessionGen)) return;

      if (existingIndex == -1) {
        final displayUsername =
            "Ghost #${masterPubKeyToVerify.substring(0, 4)}";

        addChat(
          DiscoverUser(
            masterPubKeyHex: masterPubKeyToVerify,
            nostrPubKeyHex: senderNostrPubKey,
            username: displayUsername,
            displayName: null,
            lastSeen: messageTimestamp,
            lastSeenFromMessage: isRecentLiveMessage
                ? (messageAgeSeconds < 0 ? now : messageTimestamp)
                : null,
          ),
        );
      } else {
        final existingUser = activeChats[existingIndex];
        if (messageTimestamp.isAfter(existingUser.lastSeen)) {
          existingUser.lastSeen = messageTimestamp;
        }
        if (isRecentLiveMessage) {
          existingUser.lastSeenFromMessage = messageAgeSeconds < 0
              ? now
              : messageTimestamp;
          existingUser.isExplicitlyOffline = false;
        }
      }

      if (!AccountSession.isGenerationValid(sessionGen)) return;
      AppLogger.debug(
        '[MSG] RECEIVED id=$incomingMsgId from=${AppLogger.redactNostrKey(senderNostrPubKey)}',
      );

      final effectiveMsgId = (incomingMsgId != null && incomingMsgId.isNotEmpty)
          ? incomingMsgId
          : MndoMessageEnvelope.generateMessageId('msg');

      // Check if chat is active AND app window is focused/visible
      final isChatActive =
          isAppFocused &&
          (activeChatUserId == senderNostrPubKey ||
              (_keyAliases[senderNostrPubKey] != null &&
                  activeChatUserId == _keyAliases[senderNostrPubKey]) ||
              (_keyAliases[activeChatUserId] != null &&
                  _keyAliases[activeChatUserId] == senderNostrPubKey));

      // MSG-ID-01B: Check for collision before modifying state or database
      final existingRecord = await chatRepo.getMessageByMessageId(
        effectiveMsgId,
      );
      if (existingRecord != null) {
        final isSameSender = existingRecord.nostrPubKeyHex == senderNostrPubKey;
        final isSameContent = existingRecord.messageText == plaintext;
        final isSameDirection = !existingRecord.isMe;

        if (isSameSender && isSameContent && isSameDirection) {
          // Identical replay: defined dedup behavior, re-acknowledge delivery/read receipt
          AppLogger.debug(
            '[RECV] Dropping identical replayed message id=$effectiveMsgId',
          );
          if (incomingMsgId != null && incomingMsgId.isNotEmpty) {
            final receiptStatus = isChatActive ? 'read' : 'delivered';
            unawaited(
              sendReceipt(
                recipientNostrPubKey: senderNostrPubKey,
                targetMessageId: incomingMsgId,
                status: receiptStatus,
              ),
            );
          }
          return;
        } else {
          // Conflicting reuse: reject without modifying or mutating existing row
          AppLogger.warning(
            '[RECV] REJECTING conflicting messageId collision id=$effectiveMsgId from=${AppLogger.redactNostrKey(senderNostrPubKey)}',
          );
          return;
        }
      }

      final saveResult = await addMessage(
        senderNostrPubKey,
        ChatMessage(
          messageId: effectiveMsgId,
          text: plaintext,
          isMe: false,
          timestamp: messageTimestamp,
          status: MessageStatus.sent,
        ),
      );

      if (saveResult != SaveMessageResult.inserted &&
          saveResult != SaveMessageResult.identicalDuplicate) {
        AppLogger.debug(
          '[RECV] Message persistence was rejected (result=$saveResult), skipping receipt dispatch',
        );
        return;
      }
      AppLogger.debug('[RECV] Message stored');

      // Target #9: Dispatch automatic delivery/read receipt
      if (incomingMsgId != null) {
        if (!AccountSession.isGenerationValid(sessionGen)) return;
        final receiptStatus = isChatActive ? 'read' : 'delivered';
        AppLogger.debug(
          '[RECV] $receiptStatus receipt sent for $incomingMsgId',
        );
        // If chat is active, also update the message status in memory and DB to read
        if (isChatActive) {
          final justAdded = chatHistories[senderNostrPubKey]
              ?.where((m) => m.messageId == incomingMsgId)
              .firstOrNull;
          if (justAdded != null) {
            justAdded.status = MessageStatus.read;
            unawaited(
              chatRepo.updateMessageStatus(incomingMsgId, MessageStatus.read),
            );
          }
        }
        unawaited(
          sendReceipt(
            recipientNostrPubKey: senderNostrPubKey,
            targetMessageId: incomingMsgId,
            status: receiptStatus,
          ),
        );
      }
    }
  }

  bool get isDrainingOutbox => outboxDispatcher.isDrainingOutbox;

  void _startOutboxPeriodicDrain() {
    outboxDispatcher.startPeriodicDrain();
  }

  /// Returns the required delay in seconds before the next retry attempt according to policy:
  static int getOutboxRetryBackoffSeconds(int attempts) =>
      OutboxDispatcherService.getOutboxRetryBackoffSeconds(attempts);

  /// Automatically drains pending and unacknowledged messages from the persistent Outbox.
  /// Re-transmits the exact stored ciphertexts without advancing the Signal Double Ratchet.
  /// If [forceAll] is false, messages in 'sent' state respect exponential backoff.
  Future<void> drainOutbox({bool forceAll = false}) =>
      outboxDispatcher.drainOutbox(forceAll: forceAll);

  /// Immediately re-dispatches unacknowledged messages when peer comes online or interacts.
  Future<void> retryUnacknowledgedForPeer(String recipientNostrPubKey) =>
      outboxDispatcher.retryUnacknowledgedForPeer(recipientNostrPubKey);

  Future<bool> sendOutgoingMessage(
    String recipientNostrPubKey,
    String text, {
    DateTime? sentAt,
    String? replyToId,
  }) async {
    final sessionGen = AccountSession.currentGeneration;
    if (!AccountSession.isGenerationValid(sessionGen)) {
      AppLogger.debug(
        '[MSG] sendOutgoingMessage dropped: stale session generation $sessionGen',
      );
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

    final saveResult = await addMessage(recipientNostrPubKey, message);
    if (saveResult == SaveMessageResult.conflictingId) {
      AppLogger.warning(
        '[MSG] sendOutgoingMessage rejected: conflicting messageId',
      );
      message.status = MessageStatus.failed;
      notifyListeners();
      return false;
    }

    if (!AccountSession.isGenerationValid(sessionGen)) {
      AppLogger.debug(
        '[MSG] sendOutgoingMessage aborted after addMessage: stale session $sessionGen',
      );
      return false;
    }

    if (isPeerIdentityBlocked(recipientNostrPubKey)) {
      AppLogger.debug(
        '[MSG] sendOutgoingMessage BLOCKED for ${AppLogger.redactNostrKey(recipientNostrPubKey)}: peer identity is blocked pending verification',
      );
      message.status = MessageStatus.failed;
      await chatRepo.updateMessageStatus(
        message.messageId,
        MessageStatus.failed,
      );
      notifyListeners();
      return false;
    }

    AppLogger.debug(
      '[MSG] SEND id=${message.messageId} recipient=${AppLogger.redactNostrKey(recipientNostrPubKey)} type=text',
    );
    try {
      if (signalService == null ||
          !AccountSession.isGenerationValid(sessionGen)) {
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
        AppLogger.debug(
          '[MSG] sendOutgoingMessage aborted post-encrypt: stale session $sessionGen',
        );
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
        AppLogger.debug(
          '[MSG] sendOutgoingMessage aborted post-enqueue: stale session $sessionGen',
        );
        return false;
      }

      // 3. Dispatch over network
      await signalService!.sendPreparedPayload(
        recipientNostrPubKey,
        payloadMap,
      );

      if (!AccountSession.isGenerationValid(sessionGen)) {
        AppLogger.debug(
          '[MSG] sendOutgoingMessage post-send update skipped: stale session $sessionGen',
        );
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
        await chatRepo.updateMessageStatus(
          message.messageId,
          MessageStatus.sent,
        );
        notifyListeners();
      }
      AppLogger.debug('[MSG] SEND SUCCESS id=${message.messageId}');
      return true;
    } catch (e) {
      if (!AccountSession.isGenerationValid(sessionGen)) return false;
      AppLogger.warning('[MSG] SEND FAILURE id=${message.messageId} error: $e');
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
        await chatRepo.updateMessageStatus(
          message.messageId,
          MessageStatus.failed,
        );
        notifyListeners();
      }
      return false;
    }
  }

  /// Sends a rich media file (image, video, document, audio) encrypted with AES-256-GCM
  /// and uploaded to the decentralized Blossom pool via StorageRouter.
  Future<bool> sendOutgoingMedia({
    required String recipientNostrPubKey,
    required String localFilePath,
    required String mediaType, // 'image', 'video', 'document', 'audio'
    String? customFileName,
    DateTime? sentAt,
    String? replyToId,
    String? caption,
  }) async {
    final sessionGen = AccountSession.currentGeneration;
    if (!AccountSession.isGenerationValid(sessionGen)) {
      AppLogger.debug(
        '[MEDIA] sendOutgoingMedia dropped: stale session generation $sessionGen',
      );
      return false;
    }

    final timestamp = sentAt ?? DateTime.now();

    if (isPeerIdentityBlocked(recipientNostrPubKey)) {
      AppLogger.debug(
        '[MEDIA] sendOutgoingMedia BLOCKED for ${AppLogger.redactNostrKey(recipientNostrPubKey)}: peer identity is blocked pending verification',
      );
      return false;
    }

    // 1. Locally encrypt with AES-256-GCM (constant-memory streaming)
    final prepared = await MediaService().prepareAndEncryptMedia(
      localFilePath: localFilePath,
      customFileName: customFileName,
      mediaType: mediaType,
      sentAt: timestamp.millisecondsSinceEpoch,
      caption: caption,
    );

    if (prepared == null || !AccountSession.isGenerationValid(sessionGen)) {
      return false;
    }

    var payload = prepared.payload;
    final encryptedBytes = prepared.encryptedBytes;

    final message = ChatMessage(
      text: payload.serialize(),
      isMe: true,
      timestamp: timestamp,
      status: MessageStatus.sending,
      replyToId: replyToId,
    );

    // 2. Add message to sender's memory and local DB immediately
    final saveResult = await addMessage(recipientNostrPubKey, message);
    if (saveResult == SaveMessageResult.conflictingId) {
      AppLogger.warning(
        '[MEDIA] sendOutgoingMedia rejected: conflicting messageId',
      );
      return false;
    }

    if (!AccountSession.isGenerationValid(sessionGen)) {
      AppLogger.debug(
        '[MEDIA] sendOutgoingMedia aborted after addMessage: stale session $sessionGen',
      );
      return false;
    }

    // 3. Upload encrypted bytes to Blossom via StorageRouter FIRST
    try {
      final uploadUrl = await MediaService().uploadEncryptedMedia(
        encryptedBytes,
        payload.fileHash,
        sessionGen: sessionGen,
      );

      if (!AccountSession.isGenerationValid(sessionGen)) {
        AppLogger.debug(
          '[MEDIA] sendOutgoingMedia aborted post-upload: stale session $sessionGen',
        );
        return false;
      }

      if (uploadUrl == null) {
        // DO NOT delete cached media! The sender still owns their file.
        AppLogger.warning(
          '[MEDIA] sendOutgoingMedia upload failed: uploadUrl is null',
        );
        if (message.status == MessageStatus.sending) {
          message.status = MessageStatus.failed;
          await chatRepo.updateMessageStatus(
            message.messageId,
            MessageStatus.failed,
          );
          notifyListeners();
        }
        return false;
      }

      // 3b. Update payload with confirmed Blossom uploadUrl
      payload = payload.copyWith(url: uploadUrl);
      message.text = payload.serialize();
      await chatRepo.updateMessageContent(message.messageId, message.text);
    } catch (e) {
      if (!AccountSession.isGenerationValid(sessionGen)) return false;
      AppLogger.warning("[MEDIA] Error uploading media to Blossom: $e");
      if (message.status == MessageStatus.sending) {
        message.status = MessageStatus.failed;
        await chatRepo.updateMessageStatus(
          message.messageId,
          MessageStatus.failed,
        );
        notifyListeners();
      }
      return false;
    }

    // 4. Blossom upload confirmed! Transmit Signal payload via Outbox
    try {
      if (signalService == null ||
          !AccountSession.isGenerationValid(sessionGen)) {
        throw StateError("Signal service not initialized or session stale");
      }
      final (msgId, payloadMap) = await signalService!.prepareEncryptedPayload(
        recipientNostrPubKey,
        payload.serializeForNetwork(),
        sentAt: timestamp,
        messageId: message.messageId,
        type: 'media',
        extraBody: {'fileHash': payload.fileHash, 'mediaType': mediaType},
        replyToId: replyToId,
      );

      if (!AccountSession.isGenerationValid(sessionGen)) {
        AppLogger.debug(
          '[MEDIA] sendOutgoingMedia aborted post-encrypt: stale session $sessionGen',
        );
        await MediaCacheManager().deleteForHash(payload.fileHash);
        return false;
      }

      await chatRepo.enqueueOutbox(
        messageId: msgId,
        recipientNostrPubKey: recipientNostrPubKey,
        payloadJson: jsonEncode(payloadMap),
        createdAt: timestamp,
      );

      if (!AccountSession.isGenerationValid(sessionGen)) {
        AppLogger.debug(
          '[MEDIA] sendOutgoingMedia aborted post-enqueue: stale session $sessionGen',
        );
        await MediaCacheManager().deleteForHash(payload.fileHash);
        return false;
      }

      await signalService!.sendPreparedPayload(
        recipientNostrPubKey,
        payloadMap,
      );

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
        await chatRepo.updateMessageStatus(
          message.messageId,
          MessageStatus.sent,
        );
        notifyListeners();
      }
      return true;
    } catch (e) {
      if (!AccountSession.isGenerationValid(sessionGen)) return false;
      AppLogger.warning("Error transmitting media over Signal: $e");
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
        await chatRepo.updateMessageStatus(
          message.messageId,
          MessageStatus.failed,
        );
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
      AppLogger.debug(
        '[VOICE] sendOutgoingVoiceNote dropped: stale session generation $sessionGen',
      );
      return false;
    }

    final timestamp = sentAt ?? DateTime.now();

    if (isPeerIdentityBlocked(recipientNostrPubKey)) {
      AppLogger.debug(
        '[VOICE] sendOutgoingVoiceNote BLOCKED for ${AppLogger.redactNostrKey(recipientNostrPubKey)}: peer identity is blocked pending verification',
      );
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
      await VoiceNoteCacheManager().deleteFile(localAudioPath);
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
    final saveResult = await addMessage(recipientNostrPubKey, message);
    if (saveResult == SaveMessageResult.conflictingId) {
      AppLogger.warning(
        '[VOICE] sendOutgoingVoiceNote rejected: conflicting messageId',
      );
      await VoiceNoteCacheManager().deleteForHash(payload.fileHash);
      return false;
    }

    if (!AccountSession.isGenerationValid(sessionGen)) {
      AppLogger.debug(
        '[VOICE] sendOutgoingVoiceNote aborted after addMessage: stale session $sessionGen',
      );
      await VoiceNoteCacheManager().deleteForHash(payload.fileHash);
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
        AppLogger.debug(
          '[VOICE] sendOutgoingVoiceNote aborted post-upload: stale session $sessionGen',
        );
        await VoiceNoteCacheManager().deleteForHash(payload.fileHash);
        return false;
      }

      if (uploadUrl == null) {
        // Immediately clean up sender plaintext cache on upload failure
        await VoiceNoteCacheManager().deleteForHash(payload.fileHash);
        if (message.status == MessageStatus.sending) {
          message.status = MessageStatus.failed;
          await chatRepo.updateMessageStatus(
            message.messageId,
            MessageStatus.failed,
          );
          notifyListeners();
        }
        return false;
      }
    } catch (e) {
      // Immediately clean up sender plaintext cache on upload failure
      await VoiceNoteCacheManager().deleteForHash(payload.fileHash);
      if (!AccountSession.isGenerationValid(sessionGen)) return false;
      AppLogger.warning("Error uploading voice note to Blossom: $e");
      if (message.status == MessageStatus.sending) {
        message.status = MessageStatus.failed;
        await chatRepo.updateMessageStatus(
          message.messageId,
          MessageStatus.failed,
        );
        notifyListeners();
      }
      return false;
    }

    // 4. Blossom upload confirmed! Transmit Signal payload via Outbox
    try {
      if (signalService == null ||
          !AccountSession.isGenerationValid(sessionGen)) {
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
        AppLogger.debug(
          '[VOICE] sendOutgoingVoiceNote aborted post-encrypt: stale session $sessionGen',
        );
        await VoiceNoteCacheManager().deleteForHash(payload.fileHash);
        return false;
      }

      await chatRepo.enqueueOutbox(
        messageId: msgId,
        recipientNostrPubKey: recipientNostrPubKey,
        payloadJson: jsonEncode(payloadMap),
        createdAt: timestamp,
      );

      if (!AccountSession.isGenerationValid(sessionGen)) {
        AppLogger.debug(
          '[VOICE] sendOutgoingVoiceNote aborted post-enqueue: stale session $sessionGen',
        );
        await VoiceNoteCacheManager().deleteForHash(payload.fileHash);
        return false;
      }

      await signalService!.sendPreparedPayload(
        recipientNostrPubKey,
        payloadMap,
      );

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
        await chatRepo.updateMessageStatus(
          message.messageId,
          MessageStatus.sent,
        );
        notifyListeners();
      }
      return true;
    } catch (e) {
      if (!AccountSession.isGenerationValid(sessionGen)) return false;
      AppLogger.warning("Error transmitting voice note over Signal: $e");
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
        await chatRepo.updateMessageStatus(
          message.messageId,
          MessageStatus.failed,
        );
        notifyListeners();
      }
      return false;
    }
  }

  Future<bool> retryOutgoingMessage(
    String recipientNostrPubKey,
    ChatMessage message, {
    bool respectBackoff = false,
  }) async {
    if (!message.isMe) return false;
    final sessionGen = AccountSession.currentGeneration;
    if (!AccountSession.isGenerationValid(sessionGen)) return false;

    if (isPeerIdentityBlocked(recipientNostrPubKey)) {
      AppLogger.debug(
        '[OUTBOX] retryOutgoingMessage BLOCKED for ${AppLogger.redactNostrKey(recipientNostrPubKey)}: peer identity is blocked pending verification',
      );
      return false;
    }

    // 1. Check if an Outbox record already exists for this message.
    // If found, re-transmit the stored ciphertext WITHOUT advancing the Double Ratchet!
    final outboxRecord = await chatRepo.getOutboxRecord(message.messageId);
    if (!AccountSession.isGenerationValid(sessionGen)) return false;

    if (outboxRecord != null) {
      final now = DateTime.now();
      if (now.isAfter(outboxRecord.expiresAt) ||
          now.isAtSameMomentAs(outboxRecord.expiresAt)) {
        AppLogger.debug(
          '[OUTBOX] retryOutgoingMessage: messageId=${message.messageId} reached expiration at ${outboxRecord.expiresAt}. Marking terminal expired.',
        );
        await chatRepo.updateOutboxStatus(message.messageId, status: 'expired');
        await chatRepo.updateMessageStatus(
          message.messageId,
          MessageStatus.expired,
        );
        message.status = MessageStatus.expired;
        notifyListeners();
        return false;
      }

      // Check retry backoff for automatic retry paths (e.g. RESET_SESSION recovery)
      if (respectBackoff) {
        final backoffSeconds = getOutboxRetryBackoffSeconds(
          outboxRecord.attempts,
        );
        final lastAttempt =
            outboxRecord.lastAttemptAt ?? outboxRecord.createdAt;
        if (now.difference(lastAttempt).inSeconds < backoffSeconds) {
          AppLogger.debug(
            '[OUTBOX] Automatic retry postponed: messageId=${message.messageId} backoff not yet elapsed (${now.difference(lastAttempt).inSeconds}s < ${backoffSeconds}s)',
          );
          return false;
        }
      }

      message.status = MessageStatus.sending;
      await chatRepo.updateMessageStatus(
        message.messageId,
        MessageStatus.sending,
      );
      notifyListeners();

      try {
        if (signalService == null ||
            !AccountSession.isGenerationValid(sessionGen)) {
          throw StateError("Signal service not initialized or session stale");
        }
        final payloadMap =
            jsonDecode(outboxRecord.payloadJson) as Map<String, dynamic>;
        AppLogger.debug(
          '[OUTBOX] Retrying messageId=${message.messageId} using stored ciphertext (no ratchet advancement)...',
        );
        await signalService!.sendPreparedPayload(
          outboxRecord.recipientNostrPubKey,
          payloadMap,
        );

        if (!AccountSession.isGenerationValid(sessionGen)) return true;

        await chatRepo.updateOutboxStatus(
          message.messageId,
          status: 'sent',
          attempts: outboxRecord.attempts + 1,
          lastAttemptAt: DateTime.now(),
        );

        if (message.status != MessageStatus.delivered &&
            message.status != MessageStatus.read) {
          message.status = MessageStatus.sent;
          await chatRepo.updateMessageStatus(
            message.messageId,
            MessageStatus.sent,
          );
          notifyListeners();
        }
        return true;
      } catch (e) {
        if (!AccountSession.isGenerationValid(sessionGen)) return false;
        AppLogger.warning('[OUTBOX] Error retrying stored payload: $e');
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
          await chatRepo.updateMessageStatus(
            message.messageId,
            MessageStatus.failed,
          );
          notifyListeners();
        }
        return false;
      }
    }

    // Fallback: If no outbox record exists (e.g. legacy failed message before v4):
    if (respectBackoff) {
      final now = DateTime.now();
      if (now.difference(message.timestamp).inSeconds < 30) {
        AppLogger.debug(
          '[OUTBOX] Automatic fallback retry postponed: messageId=${message.messageId} created < 30s ago',
        );
        return false;
      }
    }
    final voicePayload = VoiceNotePayload.tryParse(message.text);
    if (voicePayload != null) {
      message.status = MessageStatus.sending;
      await chatRepo.updateMessageStatus(
        message.messageId,
        MessageStatus.sending,
      );
      notifyListeners();

      try {
        VoiceNotePayload readyPayload = voicePayload;

        if (voicePayload.localPath != null &&
            File(voicePayload.localPath!).existsSync()) {
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
                await chatRepo.updateMessageStatus(
                  message.messageId,
                  MessageStatus.failed,
                );
                notifyListeners();
              }
              return false;
            }
          }
        }

        if (signalService == null ||
            !AccountSession.isGenerationValid(sessionGen)) {
          throw StateError("Signal service not initialized or session stale");
        }
        final (msgId, payloadMap) = await signalService!
            .prepareEncryptedPayload(
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

        await signalService!.sendPreparedPayload(
          recipientNostrPubKey,
          payloadMap,
        );

        if (!AccountSession.isGenerationValid(sessionGen)) return true;

        await chatRepo.updateOutboxStatus(
          msgId,
          status: 'sent',
          attempts: 1,
          lastAttemptAt: DateTime.now(),
        );

        if (message.status == MessageStatus.sending) {
          message.status = MessageStatus.sent;
          await chatRepo.updateMessageStatus(
            message.messageId,
            MessageStatus.sent,
          );
          notifyListeners();
        }
        return true;
      } catch (e) {
        if (!AccountSession.isGenerationValid(sessionGen)) return false;
        AppLogger.warning("Error retrying voice note: $e");
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
          await chatRepo.updateMessageStatus(
            message.messageId,
            MessageStatus.failed,
          );
          notifyListeners();
        }
        return false;
      }
    }

    final mediaPayload = MediaPayload.tryParse(message.text);
    if (mediaPayload != null) {
      message.status = MessageStatus.sending;
      await chatRepo.updateMessageStatus(
        message.messageId,
        MessageStatus.sending,
      );
      notifyListeners();

      try {
        MediaPayload readyPayload = mediaPayload;
        String? effectiveLocal = mediaPayload.localPath;
        if (effectiveLocal == null || !File(effectiveLocal).existsSync()) {
          effectiveLocal = MediaCacheManager().getCachedFilePath(
            mediaPayload.fileHash,
          );
        }

        if (effectiveLocal != null && File(effectiveLocal).existsSync()) {
          final prepared = await MediaService().prepareAndEncryptMedia(
            localFilePath: effectiveLocal,
            customFileName: mediaPayload.fileName,
            mediaType: mediaPayload.mediaType,
            sentAt: message.timestamp.millisecondsSinceEpoch,
          );

          if (!AccountSession.isGenerationValid(sessionGen)) return false;

          if (prepared != null) {
            readyPayload = prepared.payload;
            final uploadResult = await MediaService().uploadEncryptedMedia(
              prepared.encryptedBytes,
              readyPayload.fileHash,
              sessionGen: sessionGen,
            );
            if (!AccountSession.isGenerationValid(sessionGen)) return false;
            if (uploadResult == null) {
              if (message.status == MessageStatus.sending) {
                message.status = MessageStatus.failed;
                await chatRepo.updateMessageStatus(
                  message.messageId,
                  MessageStatus.failed,
                );
                notifyListeners();
              }
              return false;
            }
            readyPayload = readyPayload.copyWith(url: uploadResult);
            message.text = readyPayload.serialize();
            await chatRepo.updateMessageContent(
              message.messageId,
              message.text,
            );
          }
        }

        if (signalService == null ||
            !AccountSession.isGenerationValid(sessionGen)) {
          throw StateError("Signal service not initialized or session stale");
        }
        final (msgId, payloadMap) = await signalService!
            .prepareEncryptedPayload(
              recipientNostrPubKey,
              readyPayload.serializeForNetwork(),
              sentAt: message.timestamp,
              messageId: message.messageId,
              type: 'media',
              extraBody: {
                'fileHash': readyPayload.fileHash,
                'mediaType': readyPayload.mediaType,
              },
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

        await signalService!.sendPreparedPayload(
          recipientNostrPubKey,
          payloadMap,
        );

        if (!AccountSession.isGenerationValid(sessionGen)) return true;

        await chatRepo.updateOutboxStatus(
          msgId,
          status: 'sent',
          attempts: 1,
          lastAttemptAt: DateTime.now(),
        );

        if (message.status == MessageStatus.sending) {
          message.status = MessageStatus.sent;
          await chatRepo.updateMessageStatus(
            message.messageId,
            MessageStatus.sent,
          );
          notifyListeners();
        }
        return true;
      } catch (e) {
        if (!AccountSession.isGenerationValid(sessionGen)) return false;
        AppLogger.warning("Error retrying media: $e");
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
          await chatRepo.updateMessageStatus(
            message.messageId,
            MessageStatus.failed,
          );
          notifyListeners();
        }
        return false;
      }
    }

    // Regular text message fallback retry
    message.status = MessageStatus.sending;
    await chatRepo.updateMessageStatus(
      message.messageId,
      MessageStatus.sending,
    );
    notifyListeners();

    try {
      if (signalService == null ||
          !AccountSession.isGenerationValid(sessionGen)) {
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

      await signalService!.sendPreparedPayload(
        recipientNostrPubKey,
        payloadMap,
      );

      if (!AccountSession.isGenerationValid(sessionGen)) return true;

      await chatRepo.updateOutboxStatus(
        msgId,
        status: 'sent',
        attempts: 1,
        lastAttemptAt: DateTime.now(),
      );

      if (message.status == MessageStatus.sending) {
        message.status = MessageStatus.sent;
        await chatRepo.updateMessageStatus(
          message.messageId,
          MessageStatus.sent,
        );
        notifyListeners();
      }
      return true;
    } catch (e) {
      if (!AccountSession.isGenerationValid(sessionGen)) return false;
      AppLogger.warning("Error retrying message: $e");
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
        await chatRepo.updateMessageStatus(
          message.messageId,
          MessageStatus.failed,
        );
        notifyListeners();
      }
      return false;
    }
  }

  @visibleForTesting
  void clearPeerRetryThrottle() {
    _lastPeerRetryTime.clear();
    outboxDispatcher.clearPeerRetryThrottle();
  }

  Future<void> deleteMessage(
    String messageId, {
    String? recipientNostrPubKey,
  }) async {
    await chatRepo.deleteMessage(messageId);
    if (recipientNostrPubKey != null &&
        chatHistories.containsKey(recipientNostrPubKey)) {
      chatHistories[recipientNostrPubKey]!.removeWhere(
        (m) => m.messageId == messageId,
      );
      notifyListeners();
    } else {
      for (final history in chatHistories.values) {
        history.removeWhere((m) => m.messageId == messageId);
      }
      notifyListeners();
    }
  }

  void clearAllMemory() {
    activeChats.clear();
    chatHistories.clear();
    unreadCounts.clear();
    activeChatUserId = null;
    _lastResetTimestamps.clear();
    _lastPeerRetryTime.clear();
    outboxDispatcher.clearPeerRetryThrottle();
    outboxDispatcher.stopPeriodicDrain();
    unawaited(VoiceNoteCacheManager().cleanupAll());
    notifyListeners();
  }

  Future<void> clearAll() async {
    stopListening();
    await chatRepo.clearAll();
    clearAllMemory();
  }
}
