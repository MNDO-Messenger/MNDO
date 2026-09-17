import 'dart:async';
import 'dart:convert';
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
  Timer? _foregroundHeartbeatTimer;
  Timer? _offlinePingTimer;
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
  String _key(String base) => '${base}_$suffix';

  Future<void> loadState() async {
    final prefs = await SharedPreferences.getInstance();
    isAnnounced = prefs.getBool(_key('is_announced')) ?? false;
    WidgetsBinding.instance.addObserver(this);
    
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

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    if (!authProvider.isAuthenticated) return;
    
    if (state == AppLifecycleState.resumed) {
      _offlinePingTimer?.cancel();
      // Ensure we have a fresh connection and active discovery subscription on resume
      await NostrRelayService().connectToRelays();
      startDiscovery();
      
      _startForegroundHeartbeat();
      if (authProvider.masterPublicKeyHex != null) {
        NostrRelayService().broadcastPing(
          authProvider.masterPublicKeyHex!, 
          isOnline: true,
          isHidden: !isAnnounced,
          username: authProvider.username,
          displayName: authProvider.displayName,
          bio: authProvider.bio,
        );
      }
    } else if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused || state == AppLifecycleState.detached || state == AppLifecycleState.hidden) {
      _stopForegroundHeartbeat();
      _offlinePingTimer?.cancel();
      if (authProvider.masterPublicKeyHex != null) {
        NostrRelayService().broadcastPing(
          authProvider.masterPublicKeyHex!, 
          isOnline: false,
          isHidden: !isAnnounced,
          username: authProvider.username,
          displayName: authProvider.displayName,
          bio: authProvider.bio,
        );
      }
    }
  }

  void _startForegroundHeartbeat() {
    _foregroundHeartbeatTimer?.cancel();
    _foregroundHeartbeatTimer = Timer.periodic(const Duration(seconds: 25), (_) {
      if (authProvider.isAuthenticated && authProvider.masterPublicKeyHex != null) {
        NostrRelayService().broadcastPing(
          authProvider.masterPublicKeyHex!, 
          isOnline: true,
          isHidden: !isAnnounced,
          username: authProvider.username,
          displayName: authProvider.displayName,
          bio: authProvider.bio,
        );
      } else {
        _stopForegroundHeartbeat();
      }
    });
  }

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
    
    NostrRelayService().broadcastProfile(
      authProvider.masterPublicKeyHex!, 
      username: authProvider.username,
      displayName: authProvider.displayName,
      bio: authProvider.bio,
    );
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
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key('is_announced'), true);
    
    await _broadcastInitialPresence();
    _startForegroundHeartbeat();
    
    notifyListeners();
  }

  void stopHeartbeat() async {
    _stopForegroundHeartbeat();
    if (isAnnounced && authProvider.isAuthenticated) {
      NostrRelayService().broadcastPing(
        authProvider.masterPublicKeyHex!, 
        isOnline: false,
        isHidden: true,
        username: authProvider.username,
        displayName: authProvider.displayName,
        bio: authProvider.bio,
      );
      NostrRelayService().broadcastProfile(
        authProvider.masterPublicKeyHex!,
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
    _discoverySubscription = NostrRelayService().listenForPublicProfiles().listen((event) async {
      String masterPubKeyHex = '';
      bool isOnlineStatus = true;
      bool isHiddenStatus = false;
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
          if (masterPubKeyHex.isEmpty && payload.containsKey('masterKey')) {
            masterPubKeyHex = payload['masterKey'] as String;
          }
          if (payload.containsKey('username')) username = payload['username'] as String?;
          if (payload.containsKey('displayName')) displayName = payload['displayName'] as String?;
          if (payload.containsKey('bio')) bio = payload['bio'] as String?;
        } catch (_) {}
      } else if (event.kind == 14445) {
        try {
          final payload = jsonDecode(event.content!);
          masterPubKeyHex = payload['masterKey'] as String;
          if (payload['status'] == 'hidden') {
            isOnlineStatus = false;
            isHiddenStatus = true;
          }
          username = payload['username'] as String?;
          displayName = payload['displayName'] as String?;
          bio = payload['bio'] as String?;
        } catch (_) {
          if (event.content != null && event.content!.length == 64) {
            masterPubKeyHex = event.content!;
          }
        }
      }

      if (masterPubKeyHex.isEmpty || masterPubKeyHex.length != 64) return;
      if (masterPubKeyHex == authProvider.masterPublicKeyHex) return;
      
      final existingUserIndex = _discoveredUsers.indexWhere((u) => u.masterPubKeyHex == masterPubKeyHex);
      
      if (existingUserIndex != -1) {
        _updateUser(existingUserIndex, event, isOnlineStatus, isHiddenStatus, username, displayName, bio);
      } else {
        try {
          final bytes = _hexToBytes(masterPubKeyHex);
          final pubKey = SimplePublicKey(bytes, type: KeyPairType.ed25519);
          final generatedUsername = await cryptoService.generateUsername(pubKey);
          
          // RECHECK: another event for this user might have finished generating a username
          // while we were waiting! If so, update the existing user instead of overwriting/ignoring!
          final recheckIndex = _discoveredUsers.indexWhere((u) => u.masterPubKeyHex == masterPubKeyHex);
          if (recheckIndex != -1) {
            _updateUser(recheckIndex, event, isOnlineStatus, isHiddenStatus, username, displayName, bio);
            return;
          }
          
          final eventTime = event.createdAt ?? DateTime.now();
          final lastSeenTime = (event.kind == 21111 && isOnlineStatus) || event.kind == 14445
              ? eventTime
              : eventTime.subtract(const Duration(hours: 1));
          
          final user = DiscoverUser(
            masterPubKeyHex: masterPubKeyHex, 
            nostrPubKeyHex: event.pubkey,
            username: username ?? generatedUsername, 
            displayName: displayName,
            bio: bio,
            lastSeen: lastSeenTime,
            lastSeenFromPing: (event.kind == 21111 && isOnlineStatus) || event.kind == 14445 ? eventTime : null,
          );
          user.isExplicitlyOffline = !isOnlineStatus;
          user.isHidden = isHiddenStatus;
          user.lastEventTimestamp = event.createdAt;
          
          if (!_discoveredUsers.any((u) => u.masterPubKeyHex == user.masterPubKeyHex)) {
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
            notifyListeners();
          }
        } catch (e) {
          debugPrint('Error processing discovery event: $e');
        }
      }
    });
  }

  void _updateUser(int existingUserIndex, NostrEvent event, bool isOnlineStatus, bool isHiddenStatus, String? username, String? displayName, String? bio) {
    // Prevent historical out-of-order events from overriding newer ones
    if (event.createdAt != null) {
      final lastEvent = _discoveredUsers[existingUserIndex].lastEventTimestamp;
      if (lastEvent != null) {
        if (event.createdAt!.isBefore(lastEvent)) {
          return; // Ignore older out-of-order event
        }
        if (event.createdAt!.isAtSameMomentAs(lastEvent)) {
          // If events happened in the exact same second, resolve the collision.
          // Prioritize offline/hidden pings to prevent "ghost online" states.
          if (event.kind == 21111 && isOnlineStatus) {
            // We received an online ping. But if we already processed an offline ping for this second, drop the online one!
            if (_discoveredUsers[existingUserIndex].isExplicitlyOffline) {
              return;
            }
          }
        }
      }
      _discoveredUsers[existingUserIndex].lastEventTimestamp = event.createdAt;
    }
    
    _discoveredUsers[existingUserIndex].isHidden = isHiddenStatus;

    final eventTime = event.createdAt ?? DateTime.now();
    
    if (event.kind == 21111) {
      if (isOnlineStatus) {
        _discoveredUsers[existingUserIndex].lastSeen = eventTime;
        _discoveredUsers[existingUserIndex].lastSeenFromPing = eventTime;
        _discoveredUsers[existingUserIndex].isExplicitlyOffline = false;
      } else {
        _discoveredUsers[existingUserIndex].isExplicitlyOffline = true;
      }
    } else if (event.kind == 14445) {
      // If we receive a new profile broadcast, they just came online.
      _discoveredUsers[existingUserIndex].lastSeen = eventTime;
      _discoveredUsers[existingUserIndex].lastSeenFromPing = eventTime;
      _discoveredUsers[existingUserIndex].isExplicitlyOffline = false;
    }

    // Update profile info if new non-empty values are announced.
    // Never revert back to Ghost or clear an existing username when hidden.
    if (username != null && username.isNotEmpty && !username.startsWith('Ghost #')) {
      _discoveredUsers[existingUserIndex].username = username;
    }
    if (displayName != null && displayName.isNotEmpty) {
      _discoveredUsers[existingUserIndex].displayName = displayName;
    }
    if (bio != null && bio.isNotEmpty) {
      _discoveredUsers[existingUserIndex].bio = bio;
    }

    // Always sync the known identity and presence to ChatProvider for connected chats
    chatProvider.updateChatUserProfile(
      masterPubKeyHex: _discoveredUsers[existingUserIndex].masterPubKeyHex,
      username: _discoveredUsers[existingUserIndex].username,
      displayName: _discoveredUsers[existingUserIndex].displayName,
      bio: _discoveredUsers[existingUserIndex].bio,
    );
    chatProvider.updateUserPresence(
      masterPubKeyHex: _discoveredUsers[existingUserIndex].masterPubKeyHex,
      nostrPubKeyHex: event.pubkey,
      isOnline: isOnlineStatus,
      lastSeen: eventTime,
    );

    notifyListeners();
  }

  void stopDiscovery() {
    _discoverySubscription?.cancel();
    _discoverySubscription = null;
    _discoveredUsers.clear();
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
    discoveredUsers.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key('is_announced'));
    notifyListeners();
  }
}
