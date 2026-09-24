import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:dart_nostr/dart_nostr.dart';
import 'package:crypto/crypto.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

enum NostrConnectionState {
  disconnected,
  connecting,
  connected,
  resubscribing,
  ready,
  failed,
}

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

  /// Creates a BUD-11 signed authorization header for Blossom blob management
  String? createBlossomAuthHeader({
    required String sha256Hex,
    required String action,
    int validSeconds = 300,
  }) {
    if (_nostrKeyPair == null) return null;
    final exp = (DateTime.now().millisecondsSinceEpoch ~/ 1000) + validSeconds;
    final event = NostrEvent.fromPartialData(
      kind: 24242,
      tags: [
        ['t', action],
        ['x', sha256Hex],
        ['expiration', exp.toString()],
      ],
      content: 'Authorize $action $sha256Hex',
      keyPairs: _nostrKeyPair!,
    );
    final eventMap = event.toMap();
    final jsonStr = jsonEncode(eventMap);
    final base64Auth = base64Encode(utf8.encode(jsonStr));
    return 'Nostr $base64Auth';
  }

  // --- Connection State Machine & Lifecycle ---
  NostrConnectionState _state = NostrConnectionState.disconnected;
  NostrConnectionState get state => _state;
  bool get isReady => _state == NostrConnectionState.ready;
  bool get isConnected => _state == NostrConnectionState.connected ||
      _state == NostrConnectionState.resubscribing ||
      _state == NostrConnectionState.ready;

  final List<void Function()> _onReadyCallbacks = [];

  void addOnReadyListener(void Function() callback) {
    if (!_onReadyCallbacks.contains(callback)) {
      _onReadyCallbacks.add(callback);
    }
    if (isReady) {
      try {
        callback();
      } catch (e) {
        print('[NOSTR] Error executing immediate ready listener: $e');
      }
    }
  }

  void removeOnReadyListener(void Function() callback) {
    _onReadyCallbacks.remove(callback);
  }

  void _notifyReady() {
    for (final cb in List<void Function()>.of(_onReadyCallbacks)) {
      try {
        cb();
      } catch (e) {
        print('[NOSTR] Error executing ready listener: $e');
      }
    }
  }

  int _connectionGeneration = 0;
  int get connectionGeneration => _connectionGeneration;

  Future<void>? _reconnectFuture;

  // --- Subscription Registry ---
  void Function(NostrEvent event)? _messageHandler;
  DateTime Function()? _messageSinceProvider;
  String? _activeMessageSubscriptionId;
  StreamSubscription<NostrEvent>? _activeMessageStreamSub;

  void Function(NostrEvent event)? _presenceHandler;
  String? _activePresenceSubscriptionId;
  StreamSubscription<NostrEvent>? _activePresenceStreamSub;

  /// Register application-level Kind 4444 message subscription handler
  void registerMessageSubscription({
    required void Function(NostrEvent event) onEvent,
    DateTime Function()? sinceProvider,
  }) {
    _messageHandler = onEvent;
    _messageSinceProvider = sinceProvider;
    if (isConnected) {
      _subscribeMessagesInternal().then((ok) {
        if (ok && _state != NostrConnectionState.ready) {
          _state = NostrConnectionState.ready;
          print('[NOSTR #$_connectionGeneration] READY (registered message subscription active)');
        }
      });
    }
  }

  /// Unregister message subscription
  void unregisterMessageSubscription() {
    _messageHandler = null;
    _messageSinceProvider = null;
    _cancelMessageSubscription();
  }

  /// Register application-level Kind 0 & Kind 21111 profile/presence subscription handler
  void registerPresenceSubscription({
    required void Function(NostrEvent event) onEvent,
  }) {
    _presenceHandler = onEvent;
    if (isConnected) {
      _subscribePresenceInternal();
    }
  }

  /// Unregister presence subscription
  void unregisterPresenceSubscription() {
    _presenceHandler = null;
    _cancelPresenceSubscription();
  }

  void _cancelMessageSubscription() {
    if (_activeMessageStreamSub != null) {
      _activeMessageStreamSub!.cancel();
      _activeMessageStreamSub = null;
    }
    if (_activeMessageSubscriptionId != null) {
      try {
        Nostr.instance.subscriptions.closeSubscription(_activeMessageSubscriptionId!);
      } catch (_) {}
      _activeMessageSubscriptionId = null;
    }
  }

  void _cancelPresenceSubscription() {
    if (_activePresenceStreamSub != null) {
      _activePresenceStreamSub!.cancel();
      _activePresenceStreamSub = null;
    }
    if (_activePresenceSubscriptionId != null) {
      try {
        Nostr.instance.subscriptions.closeSubscription(_activePresenceSubscriptionId!);
      } catch (_) {}
      _activePresenceSubscriptionId = null;
    }
  }

  Timer? _retryTimer;
  Timer? _watchdogTimer;

  DateTime? _lastRelayActivity;
  DateTime? get lastRelayActivity => _lastRelayActivity;

  int _reconnectAttempt = 0;
  int get reconnectAttempt => _reconnectAttempt;

  Duration _calculateBackoff(int attempt) {
    // 1s, 2s, 4s, 8s, 16s, up to max 30s
    final seconds = min(30, 1 << min(attempt, 5));
    // Add ±250ms random jitter to avoid thundering herd on relays
    final jitterMs = Random().nextInt(500);
    return Duration(milliseconds: (seconds * 1000) + jitterMs);
  }

  void _scheduleReconnectRetry({bool immediate = false}) {
    _retryTimer?.cancel();
    if (immediate) {
      _retryTimer = Timer(Duration.zero, () {
        if (_state != NostrConnectionState.ready) {
          connectToRelays(force: true);
        }
      });
      return;
    }

    _reconnectAttempt++;
    final delay = _calculateBackoff(_reconnectAttempt);
    print('[NOSTR #$_connectionGeneration] Scheduling reconnect attempt #$_reconnectAttempt in ${delay.inMilliseconds}ms...');
    _retryTimer = Timer(delay, () {
      if (_state != NostrConnectionState.ready) {
        print('[NOSTR #$_connectionGeneration] Executing scheduled reconnect attempt #$_reconnectAttempt...');
        connectToRelays(force: true);
      }
    });
  }

  /// Centralized recovery pipeline: marks transport as unhealthy, safely tears down stale
  /// connection-scoped subscriptions asynchronously, and starts the serialized reconnect loop.
  void _markTransportUnhealthy(String reason) {
    if (_state == NostrConnectionState.disconnected || _state == NostrConnectionState.connecting) {
      return;
    }
    print('[NOSTR #$_connectionGeneration] Transport UNHEALTHY ($reason). Initiating recovery pipeline...');
    _state = NostrConnectionState.disconnected;

    // Safely tear down active subscription streams asynchronously to avoid onDone/onError callback recursion
    _safeTeardownSubscriptions();

    // Trigger serialized reconnect with exponential backoff
    _scheduleReconnectRetry();
  }

  void markTransportUnhealthyForTest(String reason) => _markTransportUnhealthy(reason);

  void _safeTeardownSubscriptions() {
    final msgSub = _activeMessageStreamSub;
    _activeMessageStreamSub = null;
    final msgId = _activeMessageSubscriptionId;
    _activeMessageSubscriptionId = null;

    final presenceSub = _activePresenceStreamSub;
    _activePresenceStreamSub = null;
    final presenceId = _activePresenceSubscriptionId;
    _activePresenceSubscriptionId = null;

    Future.microtask(() async {
      try {
        await msgSub?.cancel();
      } catch (_) {}
      try {
        if (msgId != null) Nostr.instance.subscriptions.closeSubscription(msgId);
      } catch (_) {}
      try {
        await presenceSub?.cancel();
      } catch (_) {}
      try {
        if (presenceId != null) Nostr.instance.subscriptions.closeSubscription(presenceId);
      } catch (_) {}
    });
  }

  /// Cleanly closes all application subscriptions
  void disposeSubscriptions() {
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    _cancelMessageSubscription();
    _cancelPresenceSubscription();
  }

  Future<bool> _subscribeMessagesInternal() async {
    _cancelMessageSubscription();
    if (_messageHandler == null) return true;
    if (_nostrKeyPair == null) {
      print('[NOSTR #$_connectionGeneration] Cannot subscribe messages: keypair not initialized');
      return false;
    }

    final since = _messageSinceProvider != null
        ? _messageSinceProvider!()
        : DateTime.now().subtract(const Duration(days: 30));

    final request = NostrRequest(
      filters: [
        NostrFilter(
          kinds: [4444],
          p: [_nostrKeyPair!.public],
          since: since,
        ),
      ],
    );

    final subResult = Nostr.instance.subscribeRequest(request);
    return subResult.fold(
      (subscription) {
        _activeMessageSubscriptionId = subscription.subscriptionId;
        _activeMessageStreamSub = subscription.stream.listen((event) {
          _lastRelayActivity = DateTime.now();
          if (_messageHandler != null) {
            _messageHandler!(event);
          }
        }, onError: (err) {
          print('[NOSTR #$_connectionGeneration] Message stream error: $err');
          _markTransportUnhealthy('message_stream_error: $err');
        }, onDone: () {
          print('[NOSTR #$_connectionGeneration] Message subscription stream CLOSED by relay.');
          _markTransportUnhealthy('message_stream_closed');
        });
        print('[NOSTR #$_connectionGeneration] SUBSCRIBED messages (id: ${subscription.subscriptionId}, since: $since)');
        return true;
      },
      (failure) {
        print('[NOSTR #$_connectionGeneration] Failed subscribing messages: ${failure.message}');
        return false;
      },
    );
  }

  Future<bool> _subscribePresenceInternal() async {
    _cancelPresenceSubscription();
    if (_presenceHandler == null) return true;

    final request = NostrRequest(
      filters: [
        NostrFilter(
          kinds: [0],
          since: DateTime.now().subtract(const Duration(days: 7)),
          limit: 150,
        ),
        NostrFilter(
          kinds: [21111],
          since: DateTime.now().subtract(const Duration(minutes: 3)), // 3-minute replay window to prevent stale presence revival
        ),
      ],
    );

    final subResult = Nostr.instance.subscribeRequest(request);
    return subResult.fold(
      (subscription) {
        _activePresenceSubscriptionId = subscription.subscriptionId;
        _activePresenceStreamSub = subscription.stream.listen((event) {
          _lastRelayActivity = DateTime.now();
          if (_presenceHandler != null) {
            _presenceHandler!(event);
          }
        }, onError: (err) {
          print('[NOSTR #$_connectionGeneration] Presence stream error: $err');
          _markTransportUnhealthy('presence_stream_error: $err');
        }, onDone: () {
          print('[NOSTR #$_connectionGeneration] Presence stream CLOSED by relay.');
          _markTransportUnhealthy('presence_stream_closed');
        });
        print('[NOSTR #$_connectionGeneration] SUBSCRIBED presence (id: ${subscription.subscriptionId})');
        return true;
      },
      (failure) {
        print('[NOSTR #$_connectionGeneration] Failed subscribing presence: ${failure.message}');
        return false;
      },
    );
  }

  /// Recreates all registered subscriptions on the active WebSocket connection
  Future<bool> resubscribeAll() async {
    print('[NOSTR #$_connectionGeneration] RESUBSCRIBING application streams...');
    _state = NostrConnectionState.resubscribing;
    final msgOk = await _subscribeMessagesInternal();
    final presenceOk = await _subscribePresenceInternal();
    return msgOk && presenceOk;
  }

  /// Initialize or recover Relay connections with strict mutex serialization
  Future<void> connectToRelays({bool force = false}) {
    if (isReady && Nostr.instance.isConnected && !force) return Future.value();
    if (_reconnectFuture != null) return _reconnectFuture!;
    _reconnectFuture = _doConnect(force: force);
    return _reconnectFuture!.whenComplete(() {
      _reconnectFuture = null;
    });
  }

  Future<void> _doConnect({bool force = false}) async {
    _connectionGeneration++;
    final currentGen = _connectionGeneration;
    _state = NostrConnectionState.connecting;
    print('[NOSTR #$currentGen] CONNECTING (force: $force, attempt: $_reconnectAttempt)...');

    try {
      if (force) {
        print('[NOSTR #$currentGen] DISCONNECTING broken/stale socket...');
        _cancelMessageSubscription();
        _cancelPresenceSubscription();
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
        print('[NOSTR #$currentGen] Relay connection failed: ${connectResult.failureOrNull}');
        _state = NostrConnectionState.failed;
        _scheduleReconnectRetry();
      } else {
        print('[NOSTR #$currentGen] CONNECTED to Nostr relays.');
        _state = NostrConnectionState.connected;
        final subscriptionsOk = await resubscribeAll();
        if (subscriptionsOk) {
          _state = NostrConnectionState.ready;
          _reconnectAttempt = 0; // Reset backoff counter on full successful recovery!
          _lastRelayActivity = DateTime.now();
          print('[NOSTR #$currentGen] READY (transport + all subscriptions active)');
          _notifyReady();
        } else {
          print('[NOSTR #$currentGen] Subscription failed — entering failed state to schedule retry');
          _state = NostrConnectionState.failed;
          _scheduleReconnectRetry();
        }
      }
    } catch (e) {
      print('[NOSTR #$currentGen] Exception during relay connection: $e');
      _state = NostrConnectionState.failed;
      _scheduleReconnectRetry();
    }
  }

  /// Start OS-level network listeners and watchdog heartbeat
  void initConnectionListeners() {
    Connectivity().onConnectivityChanged.listen((List<ConnectivityResult> results) {
      if (!results.contains(ConnectivityResult.none)) {
        print('[NOSTR] Network restored via ConnectivityPlus. Resetting backoff and triggering reconnect...');
        _reconnectAttempt = 0;
        _retryTimer?.cancel();
        connectToRelays(force: true);
      }
    });

    _watchdogTimer?.cancel();
    _watchdogTimer = Timer.periodic(const Duration(seconds: 25), (_) {
      if (_state == NostrConnectionState.ready) {
        final isClientConnected = Nostr.instance.isConnected;
        final hasMessageSub = _messageHandler == null ||
            (_activeMessageStreamSub != null && _activeMessageSubscriptionId != null);
        if (!isClientConnected || !hasMessageSub) {
          _markTransportUnhealthy('watchdog_detected_dead_connection(connected=$isClientConnected, sub=$hasMessageSub)');
        }
      } else if (_state == NostrConnectionState.failed || _state == NostrConnectionState.disconnected) {
        print('[NOSTR #$_connectionGeneration] Watchdog fallback for disconnected/failed state...');
        _scheduleReconnectRetry();
      }
    });
  }

  /// Send our custom encrypted payload as a Regular Nostr Event (Kind 4444)
  Future<void> sendEncryptedPayload(String recipientNostrPubkey, String base64Payload) async {
    if (_nostrKeyPair == null) throw StateError("Nostr keypair not initialized");
    final event = NostrEvent.fromPartialData(
      kind: 4444,
      content: base64Payload,
      keyPairs: _nostrKeyPair!,
      tags: [
        ['p', recipientNostrPubkey] // Tag the recipient so they can filter it
      ],
    );

    print('[NOSTR] PUBLISH message to $recipientNostrPubkey');
    try {
      final publishResult = await Nostr.instance.publish(event).timeout(const Duration(seconds: 10));
      publishResult.fold(
        (ok) {
          if (ok.isEventAccepted == true) {
            print('[NOSTR] PUBLISH RESULT accepted=true eventId=${ok.eventId}');
          } else {
            print('[NOSTR] PUBLISH RESULT accepted=false message=${ok.message}');
            throw StateError('Relay rejected event: ${ok.message}');
          }
        },
        (failure) {
          print('[NOSTR] PUBLISH FAILURE code=${failure.code} message=${failure.message}');
          throw StateError('Publish failed (${failure.code}): ${failure.message}');
        },
      );
    } catch (e) {
      print('[NOSTR] PUBLISH FAILURE message to $recipientNostrPubkey: $e');
      rethrow;
    }
  }

  /// Listen for incoming Messages (Kind 4444)
  Stream<NostrEvent> listenForIncomingMessages({DateTime? since}) {
    if (_nostrKeyPair == null) return const Stream.empty();
    final request = NostrRequest(
      filters: [
        NostrFilter(
          kinds: [4444],
          p: [_nostrKeyPair!.public], // Messages tagging us
          since: since ?? DateTime.now().subtract(const Duration(days: 30)), 
        ),
      ],
    );

    final subResult = Nostr.instance.subscribeRequest(request);
    
    return subResult.fold(
      (subscription) => subscription.stream,
      (failure) {
        print('[NOSTR] Subscription failed: ${failure.message}');
        return const Stream.empty();
      }
    );
  }

  /// Broadcast an online/offline presence ping (Kind 21111)
  Future<bool> broadcastPing(
    String masterPublicKeyHex, {
    bool isOnline = true,
    bool isHidden = false,
    String? username,
    String? displayName,
    String? bio,
    String? masterSig,
    int? timestampMs,
  }) async {
    // Target #10: Strong metadata privacy: In hidden mode, completely suppress relay pings
    if (isHidden) return false;
    if (_nostrKeyPair == null) return false;
    final nowMs = timestampMs ?? DateTime.now().millisecondsSinceEpoch;
    final payload = {
      "masterKey": masterPublicKeyHex,
      "status": isOnline ? "online" : "offline",
      "isHidden": false,
      "ts": nowMs,
      if (username != null) "username": username,
      if (displayName != null) "displayName": displayName,
      if (bio != null) "bio": bio,
      if (masterSig != null) "masterSig": masterSig,
    };
    
    final event = NostrEvent.fromPartialData(
      kind: 21111,
      content: jsonEncode(payload),
      keyPairs: _nostrKeyPair!,
      tags: [
        ['master', masterPublicKeyHex],
        if (masterSig != null) ['masterSig', masterSig],
      ],
    );
    
    try {
      print('[NOSTR] PUBLISH presence (isOnline: $isOnline, master: ${masterPublicKeyHex.length >= 8 ? masterPublicKeyHex.substring(0, 8) : masterPublicKeyHex}...)');
      final publishResult = await Nostr.instance.publish(event).timeout(const Duration(seconds: 10));
      bool accepted = false;
      publishResult.fold(
        (ok) {
          accepted = ok.isEventAccepted ?? false;
          if (accepted) {
            print('[NOSTR] PUBLISH RESULT presence accepted=true (isOnline: $isOnline)');
          } else {
            print('[NOSTR] PUBLISH RESULT presence accepted=false message=${ok.message}');
          }
        },
        (failure) {
          print('[NOSTR] PUBLISH FAILURE presence code=${failure.code} message=${failure.message}');
        },
      );
      return accepted;
    } catch (e) {
      print('[NOSTR] PUBLISH FAILURE presence: $e');
      return false;
    }
  }

  /// Listen for our App's Pings (21111) and Profile Metadata (0)
  Stream<NostrEvent> listenForPublicProfiles() {
    final request = NostrRequest(
      filters: [
        NostrFilter(
          kinds: [0],
          since: DateTime.now().subtract(const Duration(days: 7)), // Discover announced profile metadata up to 7 days old
          limit: 150,
        ),
        NostrFilter(
          kinds: [21111],
          since: DateTime.now().subtract(const Duration(minutes: 3)), // 3-minute replay window to prevent stale presence revival
        ),
      ],
    );

    final subResult = Nostr.instance.subscribeRequest(request);
    
    return subResult.fold(
      (subscription) => subscription.stream,
      (failure) {
        print('[NOSTR] Profile subscription failed: ${failure.message}');
        return const Stream.empty();
      }
    );
  }

  /// Broadcasts our Signal Protocol Prekey Bundle (Kind 10446)
  Future<bool> broadcastPreKeyBundle(String masterPublicKeyHex, Map<String, dynamic> payload) async {
    if (_nostrKeyPair == null) return false;
    final payloadString = jsonEncode(payload);
    
    final event = NostrEvent.fromPartialData(
      kind: 10446, 
      content: payloadString,
      keyPairs: _nostrKeyPair!,
      tags: [
        ['p', masterPublicKeyHex],
        ['p', _nostrKeyPair!.public],
        ['master', masterPublicKeyHex],
      ],
    );
    
    print("DEBUG: Publishing 10446 PreKey Bundle to Nostr! Payload size: ${payloadString.length}");
    try {
      final publishResult = await Nostr.instance.publish(event).timeout(const Duration(seconds: 5));
      bool accepted = false;
      publishResult.fold(
        (ok) {
          accepted = ok.isEventAccepted ?? false;
          if (accepted) {
            print('[NOSTR] PUBLISH RESULT prekey accepted=true eventId=${ok.eventId}');
          } else {
            print('[NOSTR] PUBLISH RESULT prekey accepted=false message=${ok.message}');
          }
        },
        (failure) {
          print('[NOSTR] PUBLISH FAILURE prekey code=${failure.code} message=${failure.message}');
        },
      );
      return accepted;
    } catch (e) {
      print('Error publishing PreKey bundle: $e');
      return false;
    }
  }

  /// Fetches a specific user's PreKey bundle
  Future<Map<String, dynamic>?> fetchUserPrekeys(String nostrPubKeyHex, {String? masterPubKeyHex}) async {
    if (!isConnected) {
      try {
        await connectToRelays().timeout(const Duration(seconds: 3));
      } catch (_) {}
    }

    final completer = Completer<Map<String, dynamic>?>();
    StreamSubscription<NostrEvent>? streamSub;
    Timer? timeoutTimer;
    
    final filters = <NostrFilter>[
      NostrFilter(
        kinds: [10446, 14446],
        authors: [nostrPubKeyHex],
        limit: 1,
      ),
      NostrFilter(
        kinds: [10446, 14446],
        p: [nostrPubKeyHex],
        limit: 1,
      ),
    ];
    if (masterPubKeyHex != null && masterPubKeyHex.isNotEmpty) {
      filters.add(
        NostrFilter(
          kinds: [10446, 14446],
          p: [masterPubKeyHex],
          limit: 1,
        ),
      );
    }
    final request = NostrRequest(filters: filters);
    print("DEBUG: fetchUserPrekeys -> Subscribing for 10446/14446 events from author $nostrPubKeyHex (master: $masterPubKeyHex)");

    final subResult = Nostr.instance.subscribeRequest(request);
    subResult.fold(
      (subscription) {
        void finish(Map<String, dynamic>? result) {
          if (!completer.isCompleted) {
            timeoutTimer?.cancel();
            streamSub?.cancel();
            try {
              Nostr.instance.subscriptions.closeSubscription(subscription.subscriptionId);
            } catch (_) {}
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
  void broadcastProfileMetadata(String username, String masterPublicKeyHex, {String? displayName, String? bio}) {
    if (_nostrKeyPair == null) return;
    final payload = jsonEncode({
      'name': username,
      'about': 'MNDO User',
      'masterKey': masterPublicKeyHex,
      if (displayName != null) 'displayName': displayName,
      if (bio != null) 'bio': bio,
    });
    
    final event = NostrEvent.fromPartialData(
      kind: 0, 
      content: payload,
      keyPairs: _nostrKeyPair!,
      tags: [
        ['master', masterPublicKeyHex],
      ],
    );
    
    unawaited(Nostr.instance.publish(event).then((_) {}).catchError((e) {
      print('Error publishing profile metadata: $e');
    }));
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
            try {
              Nostr.instance.subscriptions.closeSubscription(subscription.subscriptionId);
            } catch (_) {}
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
