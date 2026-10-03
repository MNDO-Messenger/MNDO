import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:dart_nostr/dart_nostr.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/nostr_relay_service.dart';
import '../services/signal_messaging_service.dart';
import '../services/crypto_service.dart';
import '../services/master_binding_verifier.dart';
import '../models/discover_user.dart';
import 'package:cryptography/cryptography.dart';
import 'auth_provider.dart';
import 'chat_provider.dart';
import '../services/account_session.dart';

class DiscoverProvider extends ChangeNotifier with WidgetsBindingObserver {
  AuthProvider authProvider;
  ChatProvider chatProvider;
  SignalMessagingService? signalService;
  CryptoService cryptoService;
  MasterBindingVerifier masterBindingVerifier;
  
  bool isAnnounced = false;
  bool hasEverAnnounced = false;
  Timer? _foregroundHeartbeatTimer;
  Timer? _initialPingTimer;
  Timer? _offlinePingTimer;
  Timer? _presenceRefreshTimer;
  Timer? _persistTimer;
  StreamSubscription<NostrEvent>? _discoverySubscription;
  final List<DiscoverUser> _discoveredUsers = [];

  List<DiscoverUser> get discoveredUsers {
    final now = DateTime.now();
    return _discoveredUsers.where((u) {
      if (u.isHidden) return false;
      if (u.isOnline) return true;
      return now.difference(u.lastSeen).inDays <= 7;
    }).toList();
  }
  List<DiscoverUser> get allKnownUsers => List.unmodifiable(_discoveredUsers);

  DiscoverUser? findUser(String nostrPubKeyHex) {
    try {
      return _discoveredUsers.firstWhere((u) => u.nostrPubKeyHex == nostrPubKeyHex);
    } catch (_) {
      return null;
    }
  }

  DiscoverUser? findUserByMaster(String masterPubKeyHex) {
    try {
      return _discoveredUsers.firstWhere((u) => u.masterPubKeyHex == masterPubKeyHex);
    } catch (_) {
      return null;
    }
  }

  DiscoverProvider({
    required this.authProvider, 
    required this.chatProvider, 
    required this.cryptoService,
    this.signalService,
    MasterBindingVerifier? masterBindingVerifier,
  }) : masterBindingVerifier = masterBindingVerifier ?? MasterBindingVerifier(cryptoService: cryptoService);

  void updateDependencies(AuthProvider newAuth, ChatProvider newChat, SignalMessagingService? newSignal, CryptoService newCrypto) {
    authProvider = newAuth;
    chatProvider = newChat;
    cryptoService = newCrypto;
    signalService = newSignal;
    masterBindingVerifier = MasterBindingVerifier(cryptoService: newCrypto);
  }

  final String suffix = const String.fromEnvironment('INSTANCE', defaultValue: '1');
  String _key(String base) {
    final masterKey = authProvider.masterPublicKeyHex;
    if (masterKey != null && masterKey.isNotEmpty) {
      return '${base}_${masterKey}_$suffix';
    }
    return '${base}_$suffix';
  }
  String _legacyKey(String base) => '${base}_$suffix';

  Future<void> loadState() async {
    final prefs = await SharedPreferences.getInstance();
    isAnnounced = prefs.getBool(_key('is_announced')) ?? false;
    hasEverAnnounced = prefs.getBool(_key('has_ever_announced')) ?? isAnnounced;
    WidgetsBinding.instance.addObserver(this);
    
    // Load previously discovered announced members from local cache
    var cachedMembersJson = prefs.getString(_key('cached_discovered_members'));
    if (cachedMembersJson == null || cachedMembersJson.isEmpty) {
      cachedMembersJson = prefs.getString(_legacyKey('cached_discovered_members'));
    }
    if (cachedMembersJson != null && cachedMembersJson.isNotEmpty) {
      try {
        final list = jsonDecode(cachedMembersJson) as List<dynamic>;
        final now = DateTime.now();
        for (final item in list) {
          final user = DiscoverUser.fromJson(item as Map<String, dynamic>);
          // Prune cached members inactive for more than 7 days
          if (!user.isHidden && now.difference(user.lastSeen).inDays <= 7) {
            user.lastSeenFromPing = null;
            user.lastSeenFromMessage = null;
            user.lastPingTimestampMs = null;
            if (!_discoveredUsers.any((u) => u.masterPubKeyHex == user.masterPubKeyHex)) {
              _discoveredUsers.add(user);
            }
          }
        }
        notifyListeners();
      } catch (_) {}
    }

    // Automatically start listening for public profiles and pings so that
    // user presence and announcements stay synchronized across all screens!
    startDiscovery();

    final sessionGen = AccountSession.currentGeneration;
    if (authProvider.masterPublicKeyHex != null && AccountSession.isGenerationValid(sessionGen)) {
      // Re-announce presence on startup without requiring profile screen toggle
      _startForegroundHeartbeat();
      
      // Wait 2 seconds before firing the first ping to ensure 
      // NostrRelayService has successfully connected to the socket!
      _initialPingTimer?.cancel();
      _initialPingTimer = Timer(const Duration(seconds: 2), () {
        if (!AccountSession.isGenerationValid(sessionGen)) return;
        if (authProvider.masterPublicKeyHex != null) {
          if (isAnnounced) {
            _broadcastInitialPresence();
          } else {
            _broadcastCurrentPresence(isOnline: true);
          }
        }
      });
    }
  }

  void _persistDiscoveredUsers() {
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(seconds: 3), () async {
      try {
        final prefs = await SharedPreferences.getInstance();
        final now = DateTime.now();
        final nonHidden = _discoveredUsers
            .where((u) => !u.isHidden && (u.isOnline || now.difference(u.lastSeen).inDays <= 7))
            .take(200)
            .map((u) => u.toJson())
            .toList();
        await prefs.setString(_key('cached_discovered_members'), jsonEncode(nonHidden));
      } catch (_) {}
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    // On Desktop, window minimization and closing are handled explicitly by WindowListener in main.dart.
    // Window focus/blur on desktop should NOT flip online/offline presence.
    if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      return;
    }

    if (!authProvider.isAuthenticated) return;
    
    if (state == AppLifecycleState.resumed) {
      _offlinePingTimer?.cancel();
      // Ensure we have a fresh connection and active discovery subscription on mobile resume
      await NostrRelayService().connectToRelays(force: true);
      startDiscovery();
      chatProvider.startListeningForMessages();
      
      _startForegroundHeartbeat();
      unawaited(_broadcastCurrentPresence(isOnline: true));
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      _stopForegroundHeartbeat();
      _offlinePingTimer?.cancel();
      // Send offline ping immediately so that if the user closes/swipes away the app on mobile,
      // the offline status is transmitted before the OS terminates the process.
      unawaited(_broadcastCurrentPresence(isOnline: false));
    }
  }

  /// Target #4 & #10: Broadcast presence with cryptographic delegation signature and metadata privacy
  Future<void> _broadcastCurrentPresence({required bool isOnline}) async {
    final sessionGen = AccountSession.currentGeneration;
    if (!AccountSession.isGenerationValid(sessionGen)) return;
    if (authProvider.masterPublicKeyHex == null) return;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    String? sig;
    try {
      sig = await authProvider.createDelegationSignature(NostrRelayService().publicHex, nowMs);
    } catch (_) {}
    if (!AccountSession.isGenerationValid(sessionGen)) return;
    try {
      await NostrRelayService().broadcastPing(
        authProvider.masterPublicKeyHex!,
        isOnline: isOnline,
        isHidden: false,
        username: (isOnline && isAnnounced) ? authProvider.username : null,
        displayName: (isOnline && isAnnounced) ? authProvider.displayName : null,
        bio: (isOnline && isAnnounced) ? authProvider.bio : null,
        masterSig: sig,
        timestampMs: nowMs,
        sessionGen: sessionGen,
      );
    } catch (_) {}
  }

  Future<void> sendDirectOfflinePing() async {
    _stopForegroundHeartbeat();
    _offlinePingTimer?.cancel();
    await _broadcastCurrentPresence(isOnline: false);
  }

  Future<void> sendDirectOnlinePing() async {
    _offlinePingTimer?.cancel();
    _startForegroundHeartbeat();
    await _broadcastCurrentPresence(isOnline: true);
  }

  void _startForegroundHeartbeat() {
    final sessionGen = AccountSession.currentGeneration;
    _foregroundHeartbeatTimer?.cancel();
    if (!authProvider.isAuthenticated) return;
    _foregroundHeartbeatTimer = Timer.periodic(const Duration(seconds: 25), (_) {
      if (!AccountSession.isGenerationValid(sessionGen)) {
        _stopForegroundHeartbeat();
        return;
      }
      if (authProvider.isAuthenticated && authProvider.masterPublicKeyHex != null) {
        _broadcastCurrentPresence(isOnline: true);
      } else {
        _stopForegroundHeartbeat();
      }
    });
  }

  bool get isHeartbeatActive => _foregroundHeartbeatTimer != null;

  /// Public method to stop heartbeat timer without changing isAnnounced or broadcasting offline.
  /// Used by main.dart to immediately kill the heartbeat on desktop minimize,
  /// preventing the 25s heartbeat from racing with the debounced offline broadcast.
  void stopHeartbeatOnly() {
    _stopForegroundHeartbeat();
  }

  void _stopForegroundHeartbeat() {
    _initialPingTimer?.cancel();
    _initialPingTimer = null;
    _foregroundHeartbeatTimer?.cancel();
    _foregroundHeartbeatTimer = null;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopForegroundHeartbeat();
    stopDiscovery();
    super.dispose();
  }

  Future<void> _broadcastInitialPresence() async {
    final sessionGen = AccountSession.currentGeneration;
    if (!AccountSession.isGenerationValid(sessionGen)) return;
    if (!authProvider.isAuthenticated) return;
    
    if (authProvider.username != null && authProvider.masterPublicKeyHex != null) {
      await NostrRelayService().broadcastProfileMetadata(
        authProvider.username!,
        authProvider.masterPublicKeyHex!,
        displayName: authProvider.displayName,
        bio: authProvider.bio,
        sessionGen: sessionGen,
      );
    }
    if (!AccountSession.isGenerationValid(sessionGen)) return;
    await _broadcastCurrentPresence(isOnline: true);
    
    if (!AccountSession.isGenerationValid(sessionGen)) return;
    // Replenish and broadcast prekey bundle to Nostr to ensure peers can connect
    if (signalService != null && authProvider.signalIdentityKeyPair != null && authProvider.signalRegistrationId != null) {
      signalService!.generateAndBroadcastPreKeys(
        authProvider.signalIdentityKeyPair!, 
        authProvider.signalRegistrationId!
      );
    }
  }

  Future<void> announcePresence() async {
    if (!authProvider.isAuthenticated) return;
    
    isAnnounced = true;
    hasEverAnnounced = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key('is_announced'), true);
    await prefs.setBool(_key('has_ever_announced'), true);
    
    await _broadcastInitialPresence();
    _startForegroundHeartbeat();
    
    notifyListeners();
  }

  void stopHeartbeat() async {
    _stopForegroundHeartbeat();
    if (authProvider.isAuthenticated && authProvider.masterPublicKeyHex != null) {
      await _broadcastCurrentPresence(isOnline: false);
    }
    isAnnounced = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key('is_announced'), false);
    notifyListeners();
  }

  void startDiscovery() {
    _discoverySubscription?.cancel();
    _presenceRefreshTimer?.cancel();
    final sessionGen = AccountSession.currentGeneration;
    _presenceRefreshTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!AccountSession.isGenerationValid(sessionGen)) {
        _presenceRefreshTimer?.cancel();
        _presenceRefreshTimer = null;
        return;
      }
      if (_discoveredUsers.isNotEmpty) {
        notifyListeners();
      }
      if (chatProvider.activeChats.isNotEmpty) {
        chatProvider.refreshPresence();
      }
    });

    // Register with NostrRelayService subscription registry so that any reconnection
    // (network restoration, resume, force: true) automatically recreates this subscription!
    NostrRelayService().registerPresenceSubscription(
      onEvent: _handlePublicProfileEvent,
    );
  }

  Future<void> _handlePublicProfileEvent(NostrEvent event) async {
    final sessionGen = AccountSession.currentGeneration;
    if (!AccountSession.isGenerationValid(sessionGen)) {
      return;
    }
    String masterPubKeyHex = '';
    bool isOnlineStatus = true;
    bool isHiddenStatus = false;
    int? pingTimestampMs;
    String? username;
    String? displayName;
    String? bio;
    String? masterSig;

    if (event.kind == 21111) {
      // Read from tags
      final masterTag = event.tags?.firstWhere((t) => t.first == 'master', orElse: () => []);
      if (masterTag != null && masterTag.length > 1) {
        masterPubKeyHex = masterTag[1];
      }
      final sigTag = event.tags?.firstWhere((t) => t.first == 'masterSig', orElse: () => []);
      if (sigTag != null && sigTag.length > 1) {
        masterSig = sigTag[1];
      }
      
      try {
        final payload = jsonDecode(event.content!);
        if (payload['status'] == 'offline') {
          isOnlineStatus = false;
        } else if (payload['status'] == 'online') {
          isOnlineStatus = true;
        } else if (payload['status'] == 'hidden') {
          isOnlineStatus = false;
          isHiddenStatus = true;
        }
        if (payload.containsKey('isHidden')) {
          isHiddenStatus = payload['isHidden'] == true;
        }
        if (payload.containsKey('ts') && payload['ts'] is int) {
          pingTimestampMs = payload['ts'] as int;
        }
        if (masterPubKeyHex.isEmpty && payload.containsKey('masterKey')) {
          masterPubKeyHex = payload['masterKey'] as String;
        }
        if (masterSig == null && payload.containsKey('masterSig')) {
          masterSig = payload['masterSig'] as String?;
        }
        if (payload.containsKey('username')) username = payload['username'] as String?;
        if (payload.containsKey('displayName')) displayName = payload['displayName'] as String?;
        if (payload.containsKey('bio')) bio = payload['bio'] as String?;
      } catch (_) {}
    } else if (event.kind == 0) {
      // Drop profile announcements older than 7 days
      if (event.createdAt != null && DateTime.now().difference(event.createdAt!).inDays > 7) {
        return;
      }
      final masterTag = event.tags?.firstWhere((t) => t.first == 'master', orElse: () => []);
      if (masterTag != null && masterTag.length > 1) {
        masterPubKeyHex = masterTag[1];
      }
      try {
        final payload = jsonDecode(event.content!);
        if (masterPubKeyHex.isEmpty && payload.containsKey('masterKey')) {
          masterPubKeyHex = payload['masterKey'] as String;
        }
        if (payload.containsKey('name')) username = payload['name'] as String?;
        if (payload.containsKey('displayName')) displayName = payload['displayName'] as String?;
        if (payload.containsKey('bio')) bio = payload['bio'] as String?;
        isOnlineStatus = false; // Metadata event; presence is determined by Kind 21111 pings
        isHiddenStatus = false; // Intentionally announced public profile
      } catch (_) {}
    }

    if (masterPubKeyHex.isEmpty || masterPubKeyHex.length != 64) return;
    if (masterPubKeyHex == authProvider.masterPublicKeyHex) return;

    // Freshness & Replay Validation for Kind 21111 online pings
    bool isStaleReplay = false;
    DateTime? effectivePingTime;
    if (event.kind == 21111) {
      final now = DateTime.now();
      final nowMs = now.millisecondsSinceEpoch;
      final pingTimeMs = pingTimestampMs ?? (event.createdAt != null ? event.createdAt!.millisecondsSinceEpoch : nowMs);
      final ageInSeconds = (nowMs - pingTimeMs) / 1000.0;

      // Drop pings with timestamps > 10 minutes in future
      if (ageInSeconds < -600) {
        print('[PRESENCE] REPLAY_REJECTED user=$masterPubKeyHex age=${ageInSeconds.toStringAsFixed(1)}s (future clock skew > 600s)');
        return;
      }

      // If ping has a future timestamp due to sender clock skew, clamp effective age to 0 (live right now)
      final effectiveAgeSeconds = ageInSeconds < 0 ? 0.0 : ageInSeconds;

      // Heartbeat TTL is ~70 seconds (sent every ~25s).
      // If an online ping was created > 80s ago, it's a replayed/stale event
      // and must NOT revive a user as currently online.
      if (isOnlineStatus && effectiveAgeSeconds > 80) {
        isStaleReplay = true;
        print('[PRESENCE] REPLAY_REJECTED user=$masterPubKeyHex age=${ageInSeconds.toStringAsFixed(1)}s (stale heartbeat)');
      } else {
        effectivePingTime = now.subtract(Duration(seconds: effectiveAgeSeconds.toInt()));
      }
    }

    // Target #4: Verify cryptographic delegation signature for Kind 21111 pings using centralized MasterBindingVerifier
    if (event.kind == 21111) {
      final verifyResult = await masterBindingVerifier.verifyPresencePing(
        masterPubKeyHex: masterPubKeyHex,
        nostrPubKeyHex: event.pubkey,
        timestampMs: pingTimestampMs,
        signatureHex: masterSig,
        createdAt: event.createdAt,
        isOnline: isOnlineStatus,
      );
      if (!verifyResult.isValid) {
        print('[PRESENCE] SECURITY ALERT: Dropping unauthenticated Kind 21111 ping for master=$masterPubKeyHex from author=${event.pubkey}: ${verifyResult.reason} - ${verifyResult.errorMessage}');
        return;
      }
      if (verifyResult.isStaleReplay) {
        isStaleReplay = true;
      }
    }
    
    final existingUserIndex = _discoveredUsers.indexWhere((u) => u.masterPubKeyHex == masterPubKeyHex);
    
    if (existingUserIndex != -1) {
      // If event.kind == 0, only accept metadata updates from the user's verified Nostr pubkey
      if (event.kind == 0) {
        final authorResult = masterBindingVerifier.verifyProfileMetadataAuthor(
          masterPubKeyHex: masterPubKeyHex,
          eventAuthorNostrPubKey: event.pubkey,
          pinnedNostrPubKey: _discoveredUsers[existingUserIndex].nostrPubKeyHex,
        );
        if (!authorResult.isValid) {
          print('[DISCOVER] SECURITY ALERT: Dropping unauthorized Kind 0 profile update for master=$masterPubKeyHex from unverified author ${event.pubkey} (expected ${_discoveredUsers[existingUserIndex].nostrPubKeyHex}): ${authorResult.errorMessage}');
          return;
        }
      }
      _updateUser(
        existingUserIndex, 
        event, 
        isOnlineStatus, 
        isHiddenStatus, 
        username, 
        displayName, 
        bio, 
        pingTimestampMs: pingTimestampMs,
        isStaleReplay: isStaleReplay,
      );
    } else {
      // If user is not yet known, Kind 0 cannot register a user because Kind 0 lacks cryptographic delegation signature
      if (event.kind == 0) {
        print('[DISCOVER] SECURITY ALERT: Dropping Kind 0 profile registration for unknown master=$masterPubKeyHex: unauthenticated metadata cannot register users');
        return;
      }
      try {
        final bytes = _hexToBytes(masterPubKeyHex);
        final pubKey = SimplePublicKey(bytes, type: KeyPairType.ed25519);
        final generatedUsername = await cryptoService.generateUsername(pubKey);
        
        // RECHECK: another event for this user might have finished generating a username
        // while we were waiting! If so, update the existing user instead of overwriting/ignoring!
        final recheckIndex = _discoveredUsers.indexWhere((u) => u.masterPubKeyHex == masterPubKeyHex);
        if (recheckIndex != -1) {
          _updateUser(
            recheckIndex, 
            event, 
            isOnlineStatus, 
            isHiddenStatus, 
            username, 
            displayName, 
            bio, 
            pingTimestampMs: pingTimestampMs,
            isStaleReplay: isStaleReplay,
          );
          return;
        }
        
        final now = DateTime.now();
        final effectiveOnline = isOnlineStatus && !isStaleReplay;
        final lastSeenTime = (event.kind == 21111 && effectiveOnline)
            ? (effectivePingTime ?? now)
            : (event.kind == 0 ? (event.createdAt ?? now) : (event.createdAt ?? now).subtract(const Duration(hours: 1)));
        
        final user = DiscoverUser(
          masterPubKeyHex: masterPubKeyHex, 
          nostrPubKeyHex: event.pubkey,
          username: username ?? generatedUsername, 
          displayName: displayName,
          bio: bio,
          lastSeen: lastSeenTime,
          lastSeenFromPing: (event.kind == 21111 && effectiveOnline) ? (effectivePingTime ?? now) : null,
          lastPingTimestampMs: pingTimestampMs,
        );
        user.isExplicitlyOffline = (event.kind == 21111 && !isOnlineStatus);
        user.isHidden = isHiddenStatus;
        user.lastEventTimestamp = event.createdAt;

        if (event.kind == 21111) {
          if (effectiveOnline) {
            print('[PRESENCE] ONLINE user=$masterPubKeyHex');
          } else if (!isOnlineStatus) {
            print('[PRESENCE] OFFLINE user=$masterPubKeyHex');
          }
        }
        
        if (!_discoveredUsers.any((u) => u.masterPubKeyHex == user.masterPubKeyHex)) {
          if (_discoveredUsers.length >= 500) {
            final evictIndex = _discoveredUsers.indexWhere((u) => !u.isOnline);
            if (evictIndex != -1) {
              _discoveredUsers.removeAt(evictIndex);
            }
          }
          _discoveredUsers.add(user);
          chatProvider.updateChatUserProfile(
            masterPubKeyHex: user.masterPubKeyHex,
            username: user.username,
            displayName: user.displayName,
            bio: user.bio,
          );
          if (event.kind == 21111) {
            chatProvider.updateUserPresence(
              masterPubKeyHex: user.masterPubKeyHex,
              nostrPubKeyHex: event.pubkey,
              isOnline: effectiveOnline,
              lastSeen: effectivePingTime ?? now,
            );
          }
          _persistDiscoveredUsers();
          notifyListeners();
        }
      } catch (e) {
        debugPrint('Error processing discovery event: $e');
      }
    }
  }

  void _updateUser(
    int existingUserIndex, 
    NostrEvent event, 
    bool isOnlineStatus, 
    bool isHiddenStatus, 
    String? username, 
    String? displayName, 
    String? bio, 
    {int? pingTimestampMs, bool isStaleReplay = false}
  ) {
    final user = _discoveredUsers[existingUserIndex];

    // Monotonicity check: reject older out-of-order ping within the same session window (< 60s)
    if (pingTimestampMs != null) {
      if (user.lastPingTimestampMs != null &&
          pingTimestampMs < user.lastPingTimestampMs! &&
          (user.lastPingTimestampMs! - pingTimestampMs) < 60000) {
        print('[PRESENCE] REPLAY_REJECTED user=${user.masterPubKeyHex} out_of_order (ts: $pingTimestampMs < last: ${user.lastPingTimestampMs})');
        return;
      }
      user.lastPingTimestampMs = pingTimestampMs;
      if (event.createdAt != null) {
        user.lastEventTimestamp = event.createdAt;
      }
    } else if (event.createdAt != null) {
      final lastEvent = user.lastEventTimestamp;
      if (lastEvent != null &&
          event.createdAt!.isBefore(lastEvent) &&
          lastEvent.difference(event.createdAt!).inSeconds < 60) {
        print('[PRESENCE] REPLAY_REJECTED user=${user.masterPubKeyHex} out_of_order event.createdAt');
        return;
      }
      user.lastEventTimestamp = event.createdAt;
    }
    
    user.isHidden = isHiddenStatus;

    if (event.kind == 21111 && event.pubkey.isNotEmpty && user.nostrPubKeyHex != event.pubkey) {
      print('[DISCOVER] Cryptographically verified routing update for ${user.masterPubKeyHex}: ${user.nostrPubKeyHex} -> ${event.pubkey}');
      user.nostrPubKeyHex = event.pubkey;
    }

    final now = DateTime.now();
    final nowMs = now.millisecondsSinceEpoch;
    final pingTimeMs = pingTimestampMs ?? (event.createdAt != null ? event.createdAt!.millisecondsSinceEpoch : nowMs);
    final ageInSeconds = (nowMs - pingTimeMs) / 1000.0;
    final effectiveAgeSeconds = ageInSeconds < 0 ? 0.0 : ageInSeconds;
    final effectivePingTime = now.subtract(Duration(seconds: effectiveAgeSeconds.toInt()));
    
    if (event.kind == 21111) {
      if (isStaleReplay) {
        // Stale replayed heartbeat: do not revive or change online status
      } else if (isOnlineStatus) {
        final wasOnline = user.isOnline;
        user.markOnline(at: effectivePingTime);
        if (wasOnline) {
          print('[PRESENCE] HEARTBEAT user=${user.masterPubKeyHex}');
        } else {
          print('[PRESENCE] ONLINE user=${user.masterPubKeyHex}');
        }
      } else {
        print('[PRESENCE] OFFLINE user=${user.masterPubKeyHex}');
        user.markOffline(at: now);
      }
    } else if (event.kind == 0) {
      final eventTime = event.createdAt ?? now;
      if (eventTime.isAfter(user.lastSeen)) {
        user.lastSeen = eventTime;
      }
    }

    // Update profile info if new non-empty values are announced.
    // Never revert back to Ghost or clear an existing username when hidden.
    if (username != null && username.isNotEmpty && !username.startsWith('Ghost #')) {
      user.username = username;
    }
    if (displayName != null && displayName.isNotEmpty) {
      user.displayName = displayName;
    }
    if (bio != null && bio.isNotEmpty) {
      user.bio = bio;
    }

    // Only sync profile info to ChatProvider if user is publicly announced (!user.isHidden)
    if (!user.isHidden) {
      chatProvider.updateChatUserProfile(
        masterPubKeyHex: user.masterPubKeyHex,
        username: user.username,
        displayName: user.displayName,
        bio: user.bio,
      );
    }
    if (event.kind == 21111) {
      chatProvider.updateUserPresence(
        masterPubKeyHex: user.masterPubKeyHex,
        nostrPubKeyHex: event.pubkey,
        isOnline: isStaleReplay ? user.isOnline : isOnlineStatus,
        lastSeen: effectivePingTime,
      );
    }

    _persistDiscoveredUsers();
    notifyListeners();
  }

  void stopDiscovery() {
    _presenceRefreshTimer?.cancel();
    _presenceRefreshTimer = null;
    _discoverySubscription?.cancel();
    _discoverySubscription = null;
    NostrRelayService().unregisterPresenceSubscription();
  }

  List<int> _hexToBytes(String hex) {
    final bytes = <int>[];
    for (int i = 0; i < hex.length; i += 2) {
      bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return bytes;
  }


  Future<void> logout() async {
    stopHeartbeat();
    stopDiscovery();
    _discoveredUsers.clear();
    isAnnounced = false;
    hasEverAnnounced = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key('is_announced'));
    await prefs.remove(_key('has_ever_announced'));
    await prefs.remove(_legacyKey('is_announced'));
    await prefs.remove(_legacyKey('has_ever_announced'));
    await prefs.remove(_key('cached_discovered_members'));
    notifyListeners();
  }

  @visibleForTesting
  Future<void> handlePublicProfileEvent(NostrEvent event) => _handlePublicProfileEvent(event);
}
