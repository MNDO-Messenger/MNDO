import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:dart_nostr/dart_nostr.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/nostr_relay_service.dart';
import '../services/signal_messaging_service.dart';
import '../services/crypto_service.dart';
import '../models/discover_user.dart';
import 'package:cryptography/cryptography.dart';
import 'auth_provider.dart';
import 'chat_provider.dart';

class DiscoverProvider extends ChangeNotifier with WidgetsBindingObserver {
  AuthProvider authProvider;
  ChatProvider chatProvider;
  SignalMessagingService? signalService;
  CryptoService cryptoService;
  
  bool isAnnounced = false;
  bool hasEverAnnounced = false;
  Timer? _foregroundHeartbeatTimer;
  Timer? _offlinePingTimer;
  Timer? _presenceRefreshTimer;
  Timer? _persistTimer;
  StreamSubscription<NostrEvent>? _discoverySubscription;
  final List<DiscoverUser> _discoveredUsers = [];

  List<DiscoverUser> get discoveredUsers => _discoveredUsers.where((u) => !u.isHidden).toList();
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
  });

  void updateDependencies(AuthProvider newAuth, ChatProvider newChat, SignalMessagingService? newSignal, CryptoService newCrypto) {
    authProvider = newAuth;
    chatProvider = newChat;
    cryptoService = newCrypto;
    signalService = newSignal;
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
    final cachedMembersJson = prefs.getString(_key('cached_discovered_members'));
    if (cachedMembersJson != null && cachedMembersJson.isNotEmpty) {
      try {
        final list = jsonDecode(cachedMembersJson) as List<dynamic>;
        for (final item in list) {
          final user = DiscoverUser.fromJson(item as Map<String, dynamic>);
          // Presence will be refreshed by incoming live Nostr pings
          user.lastSeenFromPing = null;
          user.lastSeenFromMessage = null;
          if (!_discoveredUsers.any((u) => u.masterPubKeyHex == user.masterPubKeyHex)) {
            _discoveredUsers.add(user);
          }
        }
        notifyListeners();
      } catch (_) {}
    }

    // Automatically start listening for public profiles and pings so that
    // user presence and announcements stay synchronized across all screens!
    startDiscovery();

    if (isAnnounced) {
      // Re-announce presence on startup without toggling the switch
      _startForegroundHeartbeat();
      
      // Wait 2 seconds before firing the first ping to ensure 
      // NostrRelayService has successfully connected to the socket!
      Future.delayed(const Duration(seconds: 2), () {
        if (isAnnounced) _broadcastInitialPresence();
      });
    }
  }

  void _persistDiscoveredUsers() {
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(seconds: 3), () async {
      try {
        final prefs = await SharedPreferences.getInstance();
        final nonHidden = _discoveredUsers.where((u) => !u.isHidden).take(200).map((u) => u.toJson()).toList();
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
      await NostrRelayService().connectToRelays();
      startDiscovery();
      
      if (isAnnounced) {
        _startForegroundHeartbeat();
        if (authProvider.masterPublicKeyHex != null) {
          NostrRelayService().broadcastPing(
            authProvider.masterPublicKeyHex!, 
            isOnline: true,
            isHidden: false,
            username: authProvider.username,
            displayName: authProvider.displayName,
            bio: authProvider.bio,
          );
        }
      }
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.detached || state == AppLifecycleState.hidden) {
      _stopForegroundHeartbeat();
      _offlinePingTimer?.cancel();
      if (isAnnounced && authProvider.masterPublicKeyHex != null) {
        NostrRelayService().broadcastPing(
          authProvider.masterPublicKeyHex!, 
          isOnline: false,
          isHidden: false,
        );
      }
    }
  }

  Future<void> sendDirectOfflinePing() async {
    _stopForegroundHeartbeat();
    _offlinePingTimer?.cancel();
    if (isAnnounced && authProvider.isAuthenticated && authProvider.masterPublicKeyHex != null) {
      await NostrRelayService().broadcastPing(
        authProvider.masterPublicKeyHex!,
        isOnline: false,
        isHidden: false,
      );
    }
  }

  Future<void> sendDirectOnlinePing() async {
    _offlinePingTimer?.cancel();
    if (isAnnounced) {
      _startForegroundHeartbeat();
      if (authProvider.isAuthenticated && authProvider.masterPublicKeyHex != null) {
        NostrRelayService().broadcastPing(
          authProvider.masterPublicKeyHex!,
          isOnline: true,
          isHidden: false,
          username: authProvider.username,
          displayName: authProvider.displayName,
          bio: authProvider.bio,
        );
      }
    }
  }

  void _startForegroundHeartbeat() {
    _foregroundHeartbeatTimer?.cancel();
    if (!isAnnounced) return;
    _foregroundHeartbeatTimer = Timer.periodic(const Duration(seconds: 25), (_) {
      if (authProvider.isAuthenticated && authProvider.masterPublicKeyHex != null && isAnnounced) {
        NostrRelayService().broadcastPing(
          authProvider.masterPublicKeyHex!, 
          isOnline: true,
          isHidden: false,
          username: authProvider.username, 
          displayName: authProvider.displayName,
          bio: authProvider.bio,
        );
      } else {
        _stopForegroundHeartbeat();
      }
    });
  }

  bool get isHeartbeatActive => _foregroundHeartbeatTimer != null;

  void _stopForegroundHeartbeat() {
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
    if (!authProvider.isAuthenticated) return;
    
    if (authProvider.username != null) {
      NostrRelayService().broadcastProfileMetadata(
        authProvider.username!,
        authProvider.masterPublicKeyHex!,
        displayName: authProvider.displayName,
        bio: authProvider.bio,
      );
    }
    NostrRelayService().broadcastPing(
      authProvider.masterPublicKeyHex!, 
      isOnline: true,
      username: authProvider.username,
      displayName: authProvider.displayName,
      bio: authProvider.bio,
    );
    
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
    if (isAnnounced && authProvider.isAuthenticated && authProvider.masterPublicKeyHex != null) {
      NostrRelayService().broadcastPing(
        authProvider.masterPublicKeyHex!, 
        isOnline: false,
        isHidden: true,
      );
    }
    isAnnounced = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key('is_announced'), false);
    notifyListeners();
  }

  void startDiscovery() {
    _discoverySubscription?.cancel();
    _presenceRefreshTimer?.cancel();
    _presenceRefreshTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (_discoveredUsers.isNotEmpty) {
        notifyListeners();
      }
      if (chatProvider.activeChats.isNotEmpty) {
        chatProvider.refreshPresence();
      }
    });
    _discoverySubscription = NostrRelayService().listenForPublicProfiles().listen((event) async {
      String masterPubKeyHex = '';
      bool isOnlineStatus = true;
      bool isHiddenStatus = false;
      int? pingTimestampMs;
      String? username;
      String? displayName;
      String? bio;

      if (event.kind == 21111) {
        // Read from tags
        final masterTag = event.tags?.firstWhere((t) => t.first == 'master', orElse: () => []);
        if (masterTag != null && masterTag.length > 1) {
          masterPubKeyHex = masterTag[1];
        }
        
        try {
          final payload = jsonDecode(event.content!);
          print('DEBUG: Received ping payload: $payload');
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
          if (payload.containsKey('username')) username = payload['username'] as String?;
          if (payload.containsKey('displayName')) displayName = payload['displayName'] as String?;
          if (payload.containsKey('bio')) bio = payload['bio'] as String?;
        } catch (_) {}
      }

      if (masterPubKeyHex.isEmpty || masterPubKeyHex.length != 64) return;
      if (masterPubKeyHex == authProvider.masterPublicKeyHex) return;
      
      final existingUserIndex = _discoveredUsers.indexWhere((u) => u.masterPubKeyHex == masterPubKeyHex);
      
      if (existingUserIndex != -1) {
        _updateUser(existingUserIndex, event, isOnlineStatus, isHiddenStatus, username, displayName, bio, pingTimestampMs: pingTimestampMs);
      } else {
        try {
          final bytes = _hexToBytes(masterPubKeyHex);
          final pubKey = SimplePublicKey(bytes, type: KeyPairType.ed25519);
          final generatedUsername = await cryptoService.generateUsername(pubKey);
          
          // RECHECK: another event for this user might have finished generating a username
          // while we were waiting! If so, update the existing user instead of overwriting/ignoring!
          final recheckIndex = _discoveredUsers.indexWhere((u) => u.masterPubKeyHex == masterPubKeyHex);
          if (recheckIndex != -1) {
            _updateUser(recheckIndex, event, isOnlineStatus, isHiddenStatus, username, displayName, bio, pingTimestampMs: pingTimestampMs);
            return;
          }
          
          final eventTime = event.createdAt ?? DateTime.now();
          final lastSeenTime = (event.kind == 21111 && isOnlineStatus)
              ? eventTime
              : eventTime.subtract(const Duration(hours: 1));
          
          final user = DiscoverUser(
            masterPubKeyHex: masterPubKeyHex, 
            nostrPubKeyHex: event.pubkey,
            username: username ?? generatedUsername, 
            displayName: displayName,
            bio: bio,
            lastSeen: lastSeenTime,
            lastSeenFromPing: (event.kind == 21111 && isOnlineStatus) ? eventTime : null,
            lastPingTimestampMs: pingTimestampMs,
          );
          user.isExplicitlyOffline = !isOnlineStatus;
          user.isHidden = isHiddenStatus;
          user.lastEventTimestamp = event.createdAt;
          
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
            chatProvider.updateUserPresence(
              masterPubKeyHex: user.masterPubKeyHex,
              nostrPubKeyHex: event.pubkey,
              isOnline: isOnlineStatus,
              lastSeen: eventTime,
            );
            _persistDiscoveredUsers();
            notifyListeners();
          }
        } catch (e) {
          debugPrint('Error processing discovery event: $e');
        }
      }
    });
  }

  void _updateUser(
    int existingUserIndex, 
    NostrEvent event, 
    bool isOnlineStatus, 
    bool isHiddenStatus, 
    String? username, 
    String? displayName, 
    String? bio, 
    {int? pingTimestampMs}
  ) {
    final user = _discoveredUsers[existingUserIndex];

    // Millisecond-precision ordering if available (from payload 'ts')
    if (pingTimestampMs != null) {
      if (user.lastPingTimestampMs != null && pingTimestampMs < user.lastPingTimestampMs!) {
        return; // Ignore older out-of-order ping
      }
      user.lastPingTimestampMs = pingTimestampMs;
      if (event.createdAt != null) {
        user.lastEventTimestamp = event.createdAt;
      }
    } else if (event.createdAt != null) {
      final lastEvent = user.lastEventTimestamp;
      if (lastEvent != null && event.createdAt!.isBefore(lastEvent)) {
        return; // Ignore older out-of-order event
      }
      user.lastEventTimestamp = event.createdAt;
    }
    
    user.isHidden = isHiddenStatus;

    final eventTime = event.createdAt ?? DateTime.now();
    
    if (event.kind == 21111) {
      if (isOnlineStatus) {
        user.lastSeen = eventTime;
        user.lastSeenFromPing = eventTime;
        user.isExplicitlyOffline = false;
      } else {
        user.isExplicitlyOffline = true;
        user.lastSeenFromPing = null;
        user.lastSeenFromMessage = null;
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
    chatProvider.updateUserPresence(
      masterPubKeyHex: user.masterPubKeyHex,
      nostrPubKeyHex: event.pubkey,
      isOnline: isOnlineStatus,
      lastSeen: eventTime,
    );

    _persistDiscoveredUsers();
    notifyListeners();
  }

  void stopDiscovery() {
    _presenceRefreshTimer?.cancel();
    _presenceRefreshTimer = null;
    _discoverySubscription?.cancel();
    _discoverySubscription = null;
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
}
