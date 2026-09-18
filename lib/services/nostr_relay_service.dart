import 'dart:async';
import 'dart:convert';
import 'package:dart_nostr/dart_nostr.dart';
import 'package:crypto/crypto.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

class NostrRelayService {
  NostrRelayService._internal();
  static final NostrRelayService _instance = NostrRelayService._internal();
  factory NostrRelayService() => _instance;

  NostrKeyPairs? _nostrKeyPair;

  /// Derive a Nostr secp256k1 keypair from the mnemonic seed.
  void initKeys(String mnemonicSeedHex) {
    // Hash the seed to get a deterministic 32-byte private key for Nostr
    final hash = sha256.convert(utf8.encode(mnemonicSeedHex + "_nostr")).bytes;
    final privateKeyHex = hash.map((b) => b.toRadixString(16).padLeft(2, '0')).join('');
    
    _nostrKeyPair = NostrKeyPairs(private: privateKeyHex);
  }

  String get publicHex => _nostrKeyPair?.public ?? '';
  bool get hasKeys => _nostrKeyPair != null;

  bool _isConnected = false;
  bool get isConnected => _isConnected;
  Future<void>? _connectionFuture;

  /// Initialize Relay connections
  Future<void> connectToRelays({bool force = false}) {
    if (_isConnected && !force) return Future.value();
    if (_connectionFuture != null) return _connectionFuture!;
    _connectionFuture = _doConnect(force: force);
    return _connectionFuture!;
  }

  Future<void> _doConnect({bool force = false}) async {
    try {
      if (force) {
        try {
          await Nostr.instance.disconnect();
        } catch (_) {}
      }
      
      final connectResult = await Nostr.instance.connect([
        'wss://relay.damus.io',
        'wss://nos.lol',
        'wss://relay.snort.social'
      ]);
      
      if (connectResult.isFailure) {
        print('Relay error: ${connectResult.failureOrNull}');
        _isConnected = false;
      } else {
        print('Successfully connected to Nostr relays.');
        _isConnected = true;
      }
    } catch (e) {
      print('Exception during relay connection: $e');
      _isConnected = false;
    } finally {
      _connectionFuture = null; // Reset so we can reconnect later if needed
    }
  }

  /// Start OS-level network listeners
  void initConnectionListeners() {
    Connectivity().onConnectivityChanged.listen((List<ConnectivityResult> results) {
      if (!results.contains(ConnectivityResult.none)) {
        print('Network restored via ConnectivityPlus. Reconnecting to Nostr...');
        connectToRelays();
      }
    });
  }

  /// Send our custom encrypted payload as a Regular Nostr Event (Kind 4444)
  void sendEncryptedPayload(String recipientNostrPubkey, String base64Payload) {
    if (_nostrKeyPair == null) return;
    final event = NostrEvent.fromPartialData(
      kind: 4444,
      content: base64Payload,
      keyPairs: _nostrKeyPair!,
      tags: [
        ['p', recipientNostrPubkey] // Tag the recipient so they can filter it
      ],
    );

    Nostr.instance.publish(event).then((_) {}, onError: (e) {
      print('Error publishing 4444: $e');
    });
  }

  /// Listen for incoming Messages (14444)
  Stream<NostrEvent> listenForIncomingMessages({DateTime? since}) {
    if (_nostrKeyPair == null) return const Stream.empty();
    final request = NostrRequest(
      filters: [
        NostrFilter(
          kinds: [4444],
          p: [_nostrKeyPair!.public], // Messages tagging us
          since: since ?? DateTime.now().subtract(const Duration(minutes: 5)), 
        ),
      ],
    );

    final subResult = Nostr.instance.subscribeRequest(request);
    
    return subResult.fold(
      (subscription) => subscription.stream,
      (failure) {
        print('Subscription failed: ${failure.message}');
        return const Stream.empty();
      }
    );
  }

  /// Broadcast our custom App Profile (Kind 14445)
  void broadcastProfile(String masterPublicKeyHex, {bool isHidden = false, String? username, String? displayName, String? bio}) {
    if (_nostrKeyPair == null) return;
    final payload = jsonEncode({
      'masterKey': masterPublicKeyHex,
      'status': isHidden ? 'hidden' : 'active',
      'isHidden': isHidden,
      if (username != null) 'username': username,
      if (displayName != null) 'displayName': displayName,
      if (bio != null) 'bio': bio,
    });
    
    final event = NostrEvent.fromPartialData(
      kind: 14445, 
      content: payload,
      keyPairs: _nostrKeyPair!,
    );
    
    Nostr.instance.publish(event).then((_) {}, onError: (e) {
      print('Error publishing profile: $e');
    });
  }

  /// Broadcast an online/offline presence ping (Kind 21111)
  Future<void> broadcastPing(
    String masterPublicKeyHex, {
    bool isOnline = true,
    bool isHidden = false,
    String? username,
    String? displayName,
    String? bio,
  }) async {
    if (_nostrKeyPair == null) return;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final payload = {
      "masterKey": masterPublicKeyHex,
      "status": isOnline ? "online" : "offline",
      "isHidden": isHidden,
      "ts": nowMs,
      if (username != null) "username": username,
      if (displayName != null) "displayName": displayName,
      if (bio != null) "bio": bio,
    };
    
    final event = NostrEvent.fromPartialData(
      kind: 21111,
      content: jsonEncode(payload),
      keyPairs: _nostrKeyPair!,
      tags: [
        ['master', masterPublicKeyHex],
      ],
    );
    
    try {
      await Nostr.instance.publish(event).timeout(const Duration(seconds: 4));
    } catch (e) {
      print('DEBUG: broadcastPing error: $e');
    }
  }

  /// Listen for our App's Profiles (14445) and Pings (21111) exclusively
  Stream<NostrEvent> listenForPublicProfiles() {
    final request = NostrRequest(
      filters: [
        NostrFilter(
          kinds: [14445],
          since: DateTime.now().subtract(const Duration(days: 7)), // Discover profiles up to 7 days old
          limit: 100,
        ),
        NostrFilter(
          kinds: [21111],
          since: DateTime.now().subtract(const Duration(minutes: 2)), // Catch active presence pings
        ),
      ],
    );

    final subResult = Nostr.instance.subscribeRequest(request);
    
    return subResult.fold(
      (subscription) => subscription.stream,
      (failure) {
        print('Profile subscription failed: ${failure.message}');
        return const Stream.empty();
      }
    );
  }

  /// Broadcasts our Signal Protocol Prekey Bundle (Kind 10446)
  void broadcastPreKeyBundle(String masterPublicKeyHex, Map<String, dynamic> payload) {
    if (_nostrKeyPair == null) return;
    final payloadString = jsonEncode(payload);
    
    final event = NostrEvent.fromPartialData(
      kind: 10446, 
      content: payloadString,
      keyPairs: _nostrKeyPair!,
      tags: [
        ['p', masterPublicKeyHex]
      ],
    );
    
    print("DEBUG: Publishing 10446 PreKey Bundle to Nostr! Payload size: ${payloadString.length}");
    Nostr.instance.publish(event).then((_) {}, onError: (e) {
      print('Error publishing PreKey bundle: $e');
    });
  }

  /// Fetches a specific user's PreKey bundle
  Future<Map<String, dynamic>?> fetchUserPrekeys(String nostrPubKeyHex) async {
    final completer = Completer<Map<String, dynamic>?>();
    StreamSubscription<NostrEvent>? streamSub;
    Timer? timeoutTimer;
    
    final request = NostrRequest(
      filters: [
        NostrFilter(
          kinds: [10446, 14446],
          authors: [nostrPubKeyHex],
          limit: 1,
        ),
      ],
    );
    print("DEBUG: fetchUserPrekeys -> Subscribing for 10446/14446 events from author $nostrPubKeyHex");

    final subResult = Nostr.instance.subscribeRequest(request);
    subResult.fold(
      (subscription) {
        void finish(Map<String, dynamic>? result) {
          if (!completer.isCompleted) {
            timeoutTimer?.cancel();
            streamSub?.cancel();
            completer.complete(result);
          }
        }

        streamSub = subscription.stream.listen((event) {
          try {
            print("DEBUG: fetchUserPrekeys -> Received event! size: ${event.content?.length}");
            final map = jsonDecode(event.content!);
            finish(map);
          } catch (e) {
            print("Failed parsing PreKey bundle: $e");
          }
        });
        
        // Timeout if no bundle found
        timeoutTimer = Timer(const Duration(seconds: 10), () {
          print("DEBUG: fetchUserPrekeys -> TIMED OUT WAITING FOR 10446/14446");
          finish(null);
        });
      },
      (failure) {
        completer.complete(null);
      }
    );
    
    return completer.future;
  }

  /// Broadcast standard Nostr Profile (Kind 0)
  void broadcastProfileMetadata(String username, String masterPublicKeyHex) {
    if (_nostrKeyPair == null) return;
    final payload = jsonEncode({
      'name': username,
      'about': 'MNDO User',
      'masterKey': masterPublicKeyHex,
    });
    
    final event = NostrEvent.fromPartialData(
      kind: 0, 
      content: payload,
      keyPairs: _nostrKeyPair!,
    );
    
    Nostr.instance.publish(event).then((_) {}, onError: (e) {
      print('Error publishing profile metadata: $e');
    });
  }

  /// Fetch a user's standard Nostr Profile (Kind 0)
  Future<Map<String, dynamic>?> fetchUserProfile(String nostrPubKeyHex) async {
    final completer = Completer<Map<String, dynamic>?>();
    StreamSubscription<NostrEvent>? streamSub;
    Timer? timeoutTimer;
    
    final request = NostrRequest(
      filters: [
        NostrFilter(
          kinds: [0],
          authors: [nostrPubKeyHex],
          limit: 1,
        ),
      ],
    );

    final subResult = Nostr.instance.subscribeRequest(request);
    subResult.fold(
      (subscription) {
        void finish(Map<String, dynamic>? result) {
          if (!completer.isCompleted) {
            timeoutTimer?.cancel();
            streamSub?.cancel();
            completer.complete(result);
          }
        }

        streamSub = subscription.stream.listen((event) {
          try {
            final map = jsonDecode(event.content!);
            finish(map);
          } catch (e) {
            print("Failed parsing Profile Metadata: $e");
          }
        });
        
        // Timeout if no profile found
        timeoutTimer = Timer(const Duration(seconds: 3), () {
          finish(null);
        });
      },
      (failure) {
        completer.complete(null);
      }
    );
    
    return completer.future;
  }
}
