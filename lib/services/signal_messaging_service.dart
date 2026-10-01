import 'dart:async';
import 'dart:convert';
import 'dart:math' as dart_math;
import 'package:flutter/foundation.dart';
import 'package:cryptography/cryptography.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'signal_store.dart';
import 'nostr_relay_service.dart';
import 'crypto_service.dart';
import 'master_binding_verifier.dart';
import 'account_session.dart';
import '../models/mndo_message_envelope.dart';

/// A non-blocking asynchronous mutex that serializes asynchronous closures.
class AsyncMutex {
  Future<void>? _last;

  Future<T> synchronize<T>(Future<T> Function() action) {
    final previous = _last;
    final completer = Completer<void>();
    _last = completer.future;

    return Future<T>(() async {
      if (previous != null) {
        try {
          await previous;
        } catch (_) {}
      }
      try {
        return await action();
      } finally {
        completer.complete();
        if (identical(_last, completer.future)) {
          _last = null;
        }
      }
    });
  }
}

/// Manages per-peer independent asynchronous mutexes to prevent concurrent
/// Double Ratchet state corruption during overlapping send, receive, or reset operations.
class PeerSessionLockManager {
  final Map<String, AsyncMutex> _peerLocks = {};

  Future<T> withPeerLock<T>(String peerKey, Future<T> Function() action) {
    final normalized = peerKey.toLowerCase();
    final lock = _peerLocks.putIfAbsent(normalized, () => AsyncMutex());
    return lock.synchronize(action);
  }

  @visibleForTesting
  bool hasActiveLock(String peerKey) {
    final normalized = peerKey.toLowerCase();
    final lock = _peerLocks[normalized];
    return lock != null && lock._last != null;
  }
}

class SignalMessagingService {
  final SignalStore signalStore;
  final NostrRelayService nostrService;
  final String masterPublicKeyHex;
  final SimpleKeyPair? masterKeyPair;
  final CryptoService cryptoService;
  final MasterBindingVerifier masterBindingVerifier;
  final int sessionGeneration;

  final PeerSessionLockManager _lockManager = PeerSessionLockManager();

  PeerSessionLockManager get lockManager => _lockManager;

  Future<T> withPeerLock<T>(String peerKey, Future<T> Function() action) =>
      _lockManager.withPeerLock(peerKey, action);

  final Map<String, IdentityKey> _pendingUntrustedIdentities = {};
  final Map<String, PreKeyBundle> _pendingPreKeyBundles = {};

  bool isIdentityBlocked(String peerNostrPubKey) => _pendingUntrustedIdentities.containsKey(peerNostrPubKey);
  IdentityKey? getPendingUntrustedKey(String peerNostrPubKey) => _pendingUntrustedIdentities[peerNostrPubKey];

  @visibleForTesting
  void markIdentityBlockedForTesting(String peerNostrPubKey, [IdentityKey? key]) {
    _pendingUntrustedIdentities[peerNostrPubKey] = key ?? generateIdentityKeyPair().getPublicKey();
  }

  /// Authoritative check: can we send an end-to-end encrypted message to [peerNostrPubKey]?
  /// Returns true only if:
  /// 1. The service is not disposed and session generation is active
  /// 2. The peer's identity key is trusted (not blocked in _pendingUntrustedIdentities)
  /// 3. An active Signal Double Ratchet session exists in the store
  Future<bool> canSendToPeer(String peerNostrPubKey) async {
    if (_isDisposed || !AccountSession.isGenerationValid(sessionGeneration)) return false;
    if (isIdentityBlocked(peerNostrPubKey)) return false;
    final address = SignalProtocolAddress(peerNostrPubKey, 1);
    return await signalStore.containsSession(address);
  }

  /// Callback triggered whenever a peer's identity key changes (either during outbound session
  /// establishment or inbound message decryption), allowing the chat provider and UI to alert the user.
  void Function(String peerNostrPubKey)? onIdentityKeyChanged;

  SignalMessagingService({
    required this.signalStore,
    required this.nostrService,
    required this.masterPublicKeyHex,
    this.masterKeyPair,
    CryptoService? cryptoService,
    MasterBindingVerifier? masterBindingVerifier,
    this.onIdentityKeyChanged,
    int? sessionGeneration,
  }) : cryptoService = cryptoService ?? CryptoService(),
       masterBindingVerifier = masterBindingVerifier ?? MasterBindingVerifier(cryptoService: cryptoService),
       sessionGeneration = sessionGeneration ?? AccountSession.currentGeneration;

  Timer? _rebroadcastDebounceTimer;
  Timer? _periodicReplenishmentTimer;
  bool _isDisposed = false;

  bool get isDisposed => _isDisposed;
  bool get isActive => !_isDisposed && AccountSession.isGenerationValid(sessionGeneration);

  void _ensureActive() {
    if (_isDisposed || !AccountSession.isGenerationValid(sessionGeneration)) {
      throw StateError(
        'SignalMessagingService is disposed or session generation is stale '
        '(bound: $sessionGeneration, current: ${AccountSession.currentGeneration}).',
      );
    }
  }

  @visibleForTesting
  Timer? get rebroadcastDebounceTimer => _rebroadcastDebounceTimer;

  @visibleForTesting
  Timer? get periodicReplenishmentTimer => _periodicReplenishmentTimer;

  /// Check local unused OTPKs and automatically replenish to Nostr when pool drops below threshold (Target #3)
  /// or when [forceRebroadcast] is requested (e.g., after session handshake / one-time key consumption).
  Future<void> checkAndReplenishPreKeys({
    IdentityKeyPair? signalIdentityKeyPair,
    int? signalRegistrationId,
    bool forceRebroadcast = false,
  }) async {
    if (_isDisposed) return;
    final keyPair = signalIdentityKeyPair ?? signalStore.localIdentityKeyPair;
    final regId = signalRegistrationId ?? signalStore.localRegistrationId;
    final count = await signalStore.getPreKeyCount();
    if (count < 25 || forceRebroadcast) {
      print("DEBUG: PreKeys pool check (count: $count, force: $forceRebroadcast). Replenishing/broadcasting...");
      await generateAndBroadcastPreKeys(keyPair, regId);
    }
  }

  /// Debounced replenishment trigger called whenever an inbound PreKeySignalMessage
  /// is successfully decrypted and consumes a one-time prekey from the local store.
  void schedulePostConsumptionReplenishment([Duration delay = const Duration(seconds: 5)]) {
    final sessionGen = AccountSession.currentGeneration;
    _rebroadcastDebounceTimer?.cancel();
    _rebroadcastDebounceTimer = Timer(delay, () async {
      if (_isDisposed || !AccountSession.isGenerationValid(sessionGen)) {
        print('[SIGNAL] Post-consumption replenishment dropped: service disposed or stale session');
        return;
      }
      try {
        await checkAndReplenishPreKeys(forceRebroadcast: true);
      } catch (e) {
        print('Error during post-consumption prekey replenishment: $e');
      }
    });
  }

  /// Start periodic replenishment timer to ensure keys stay healthy during active sessions.
  void startPeriodicReplenishment([Duration interval = const Duration(minutes: 15)]) {
    final sessionGen = AccountSession.currentGeneration;
    _periodicReplenishmentTimer?.cancel();
    _periodicReplenishmentTimer = Timer.periodic(interval, (_) async {
      if (_isDisposed || !AccountSession.isGenerationValid(sessionGen)) {
        _periodicReplenishmentTimer?.cancel();
        _periodicReplenishmentTimer = null;
        return;
      }
      try {
        await checkAndReplenishPreKeys();
      } catch (e) {
        print('Periodic prekey replenishment check error: $e');
      }
    });
  }

  /// Stop periodic replenishment and pending debounce timers.
  void stopPeriodicReplenishment() {
    _periodicReplenishmentTimer?.cancel();
    _periodicReplenishmentTimer = null;
    _rebroadcastDebounceTimer?.cancel();
    _rebroadcastDebounceTimer = null;
  }

  /// Cleanly invalidates the SignalMessagingService instance on account logout or session teardown.
  void dispose() {
    _isDisposed = true;
    stopPeriodicReplenishment();
    _pendingUntrustedIdentities.clear();
    _pendingPreKeyBundles.clear();
  }

  bool _isBroadcastingPrekeys = false;
  bool _hasRegisteredReadyListener = false;

  Future<bool> generateAndBroadcastPreKeys([
    IdentityKeyPair? signalIdentityKeyPair,
    int? signalRegistrationId,
  ]) async {
    _ensureActive();
    final keyPair = signalIdentityKeyPair ?? signalStore.localIdentityKeyPair;
    final regId = signalRegistrationId ?? signalStore.localRegistrationId;

    if (_isBroadcastingPrekeys) return false;
    _isBroadcastingPrekeys = true;
    try {
      // 1. Signed PreKey
      SignedPreKeyRecord signedPreKey;
      if (await signalStore.containsSignedPreKey(1)) {
        signedPreKey = await signalStore.loadSignedPreKey(1);
      } else {
        signedPreKey = generateSignedPreKey(keyPair, 1);
        await signalStore.storeSignedPreKey(1, signedPreKey);
      }
      
      // 2. Intelligent PreKey Top-Up (Reconciled threshold to 25)
      final currentPreKeyCount = await signalStore.getPreKeyCount();
      
      if (currentPreKeyCount < 25) {
        final maxId = await signalStore.getMaxPreKeyId();
        final amountToGenerate = 50 - currentPreKeyCount;
        
        final newPreKeys = generatePreKeys(maxId + 1, amountToGenerate);
        for (final preKey in newPreKeys) {
          await signalStore.storePreKey(preKey.id, preKey);
        }
        print("PreKey pool was low ($currentPreKeyCount). Generated $amountToGenerate new keys.");
      } else {
        print("PreKey pool is healthy ($currentPreKeyCount). Skipping generation.");
      }

      // 3. Fetch all currently available PreKeys
      final allAvailablePreKeys = await signalStore.getAllPreKeys();
      
      final identityPubBase64 = base64Encode(keyPair.getPublicKey().serialize());
      
      final signedPreKeyMap = {
        'id': signedPreKey.id,
        'pubKey': base64Encode(signedPreKey.getKeyPair().publicKey.serialize()),
        'signature': base64Encode(signedPreKey.signature),
      };
      
      final oneTimePreKeysMap = allAvailablePreKeys.map((pk) => {
        'id': pk.id,
        'pubKey': base64Encode(pk.getKeyPair().publicKey.serialize()),
      }).toList();

      final nowMs = DateTime.now().millisecondsSinceEpoch;
      String? masterBindingSig;
      if (masterKeyPair != null && nostrService.publicHex.isNotEmpty) {
        masterBindingSig = await cryptoService.signBundleBindingToken(
          masterKeyPair: masterKeyPair!,
          nostrPubKeyHex: nostrService.publicHex,
          signalIdentityPubBase64: identityPubBase64,
          timestamp: nowMs,
        );
      }
      
      final payload = {
        'masterKey': masterPublicKeyHex,
        'registrationId': regId,
        'identityPubKey': identityPubBase64,
        if (masterBindingSig != null) 'masterBindingSig': masterBindingSig,
        'timestamp': nowMs,
        'signedPreKey': signedPreKeyMap,
        'oneTimePreKeys': oneTimePreKeysMap,
      };
      
      _ensureActive();
      final ok = await nostrService.broadcastPreKeyBundle(masterPublicKeyHex, payload);
      if (!ok && !_hasRegisteredReadyListener) {
        _hasRegisteredReadyListener = true;
        nostrService.addOnReadyListener(() {
          generateAndBroadcastPreKeys(keyPair, regId);
        });
      }
      return ok;
    } finally {
      _isBroadcastingPrekeys = false;
    }
  }

  Future<bool> hasSignalSession(String nostrPubKey) async {
    _ensureActive();
    return await signalStore.containsSession(SignalProtocolAddress(nostrPubKey, 1));
  }

  Future<void> deleteSession(String nostrPubKey) async {
    _ensureActive();
    return withPeerLock(nostrPubKey, () async {
      _ensureActive();
      final address = SignalProtocolAddress(nostrPubKey, 1);
      await signalStore.deleteSession(address);
    });
  }

  Future<bool> fetchAndEstablishSession(
    String recipientNostrPubKey, {
    String? masterPubKeyHex,
    bool force = false,
  }) async {
    _ensureActive();
    return withPeerLock(recipientNostrPubKey, () async {
      _ensureActive();
      if (!force) {
        final hasSession = await hasSignalSession(recipientNostrPubKey);
        if (hasSession) return true;
      }
      
      final bundleMap = await nostrService.fetchUserPrekeys(recipientNostrPubKey, masterPubKeyHex: masterPubKeyHex);
      _ensureActive();
      if (bundleMap == null || bundleMap.isEmpty) {
        print("No PreKey bundle found for user on network!");
        return false;
      }

      // Security Gate 1: Verify pinned masterKey matches if expected
      if (masterPubKeyHex != null && masterPubKeyHex.isNotEmpty) {
        final bundleMasterKey = bundleMap['masterKey'];
        if (bundleMasterKey != masterPubKeyHex) {
          print("SECURITY ALERT: PreKey bundle masterKey ($bundleMasterKey) does not match expected master key ($masterPubKeyHex)! Aborting session establishment.");
          return false;
        }
      }

      // Security Gate 2 & 3: Authoritative PreKey bundle cryptographic binding verification
      final expectedMaster = masterPubKeyHex ?? (bundleMap['masterKey'] as String?);

      if (expectedMaster == null || expectedMaster.isEmpty) {
        print("SECURITY ALERT: PreKey bundle for $recipientNostrPubKey lacks master key association and none was supplied! Aborting session establishment.");
        return false;
      }

      final bindingResult = await masterBindingVerifier.verifyPreKeyBundle(
        expectedMasterPubKeyHex: expectedMaster,
        recipientNostrPubKey: recipientNostrPubKey,
        bundleMap: bundleMap,
        eventAuthor: bundleMap['_eventAuthor'] as String?,
      );

      _ensureActive();
      if (!bindingResult.isValid) {
        print("SECURITY ALERT: PreKey bundle verification failed for $recipientNostrPubKey: ${bindingResult.reason} (${bindingResult.errorMessage}). Aborting session establishment.");
        return false;
      }
      print("DEBUG: PreKey bundle cryptographic binding verified successfully for $recipientNostrPubKey (master: $expectedMaster)");
      
      try {
        final registrationId = bundleMap['registrationId'];
        final identityPubKey = IdentityKey.fromBytes(base64Decode(bundleMap['identityPubKey']), 0);
        
        final signedPreKeyMap = bundleMap['signedPreKey'];
        final signedPreKeyId = signedPreKeyMap['id'];
        final signedPreKeyPub = Curve.decodePoint(base64Decode(signedPreKeyMap['pubKey']), 0);
        final signature = base64Decode(signedPreKeyMap['signature']);
        
        final rawOneTime = bundleMap['oneTimePreKeys'];
        int? preKeyId;
        ECPublicKey? preKeyPub;
        if (rawOneTime != null && rawOneTime is List && rawOneTime.isNotEmpty) {
          final oneTimePreKeys = List<Map<String, dynamic>>.from(rawOneTime);
          final randomIndex = dart_math.Random().nextInt(oneTimePreKeys.length);
          final randomOtkp = oneTimePreKeys[randomIndex];
          preKeyId = randomOtkp['id'] as int;
          preKeyPub = Curve.decodePoint(base64Decode(randomOtkp['pubKey']), 0);
        }
        
        final preKeyBundle = PreKeyBundle(
          registrationId,
          1,
          preKeyId,
          preKeyPub,
          signedPreKeyId,
          signedPreKeyPub,
          signature,
          identityPubKey,
        );
        
        final address = SignalProtocolAddress(recipientNostrPubKey, 1);
        final sessionBuilder = SessionBuilder(signalStore, signalStore, signalStore, signalStore, address);
        
        _ensureActive();
        if (force) {
          // Only delete stale session once we have confirmed a new PreKeyBundle has been downloaded
          await signalStore.deleteSession(address);
        }

        try {
          _ensureActive();
          await sessionBuilder.processPreKeyBundle(preKeyBundle);
        } catch (e) {
          if (e is UntrustedIdentityException || e.toString().contains('UntrustedIdentity')) {
            print("Untrusted Identity detected for $recipientNostrPubKey during bundle processing. Blocking automatic session rebuild pending user confirmation...");
            _pendingUntrustedIdentities[recipientNostrPubKey] = identityPubKey;
            _pendingPreKeyBundles[recipientNostrPubKey] = preKeyBundle;
            onIdentityKeyChanged?.call(recipientNostrPubKey);
            return false;
          } else {
            rethrow;
          }
        }
        print("Successfully established Signal Session with $recipientNostrPubKey");
        return true;
      } catch (e) {
        print("Failed to process PreKey Bundle: $e");
        return false;
      }
    });
  }

  /// Encrypts an outgoing message once and advances the Signal sending chain ratchet.
  /// Returns a record of the generated (or supplied) [messageId] and the serializable payload map
  /// ready for atomic Outbox persistence or network transmission.
  Future<(String messageId, Map<String, dynamic> payloadMap)> prepareEncryptedPayload(
    String recipientNostrPubKey,
    String text, {
    DateTime? sentAt,
    String? messageId,
    String type = 'text',
    Map<String, dynamic>? extraBody,
    String? replyToId,
  }) async {
    _ensureActive();
    return withPeerLock(recipientNostrPubKey, () async {
      _ensureActive();
      if (isIdentityBlocked(recipientNostrPubKey)) {
        throw StateError("Cannot encrypt payload for $recipientNostrPubKey: peer's Signal identity key changed and is blocked pending verification.");
      }
      try {
        print("DEBUG: Encrypting message for $recipientNostrPubKey...");
        final address = SignalProtocolAddress(recipientNostrPubKey, 1);
        final sessionCipher = SessionCipher(signalStore, signalStore, signalStore, signalStore, address);
        
        final timestamp = sentAt ?? DateTime.now();
        final msgId = messageId ?? MndoMessageEnvelope.generateMessageId('msg');

        final bodyMap = <String, dynamic>{
          'text': text,
          if (extraBody != null) ...extraBody,
        };

        final envelope = MndoMessageEnvelope(
          version: MndoMessageEnvelope.currentVersion,
          messageId: msgId,
          type: type,
          timestamp: timestamp.millisecondsSinceEpoch,
          senderMasterPubKey: masterPublicKeyHex,
          body: bodyMap,
          replyToId: replyToId,
        );

        final innerPayload = envelope.serialize();
        _ensureActive();
        final ciphertextMessage = await sessionCipher.encrypt(Uint8List.fromList(utf8.encode(innerPayload)));
        _ensureActive();
        
        final payloadMap = <String, dynamic>{
          'type': ciphertextMessage.getType(),
          'ciphertext': base64Encode(ciphertextMessage.serialize()),
          'sentAt': timestamp.millisecondsSinceEpoch,
          'id': msgId,
        };
        
        return (msgId, payloadMap);
      } catch (e) {
        print('DEBUG: Encryption failed: $e');
        rethrow;
      }
    });
  }

  /// Sends a previously prepared and encrypted payload map over the Nostr network.
  /// This operation does NOT advance the Signal ratchet and is completely idempotent.
  Future<void> sendPreparedPayload(
    String recipientNostrPubKey,
    Map<String, dynamic> payloadMap,
  ) async {
    _ensureActive();
    if (isIdentityBlocked(recipientNostrPubKey)) {
      throw StateError("Cannot send payload to $recipientNostrPubKey: peer's Signal identity key changed and is blocked pending verification.");
    }
    try {
      final msgId = payloadMap['id'];
      final type = payloadMap['type'];
      print("DEBUG: Sending encrypted payload to relay (Type: $type, ID: $msgId)...");
      _ensureActive();
      await nostrService.sendEncryptedPayload(recipientNostrPubKey, jsonEncode(payloadMap));
    } catch (e) {
      print('DEBUG: Sending prepared payload failed: $e');
      rethrow;
    }
  }

  Future<String> sendMessage(
    String recipientNostrPubKey,
    String text, {
    DateTime? sentAt,
    String? messageId,
    String type = 'text',
    Map<String, dynamic>? extraBody,
    String? replyToId,
  }) async {
    _ensureActive();
    final (msgId, payloadMap) = await prepareEncryptedPayload(
      recipientNostrPubKey,
      text,
      sentAt: sentAt,
      messageId: messageId,
      type: type,
      extraBody: extraBody,
      replyToId: replyToId,
    );
    _ensureActive();
    await sendPreparedPayload(recipientNostrPubKey, payloadMap);
    return msgId;
  }

  Future<(String plaintext, String senderMasterPubKeyToVerify, DateTime? sentAt, String? messageId, bool isIdentityKeyChanged)?> decryptMessage(String senderNostrPubKey, Map<String, dynamic> map) async {
    _ensureActive();
    return withPeerLock(senderNostrPubKey, () async {
      _ensureActive();
      try {
      final type = map['type'];
      final ciphertext = map['ciphertext'];
      
      final address = SignalProtocolAddress(senderNostrPubKey, 1);
      final sessionCipher = SessionCipher(signalStore, signalStore, signalStore, signalStore, address);
      
      Uint8List plaintextBytes;
      bool isIdentityKeyChanged = false;
      if (type == CiphertextMessage.prekeyType) {
        final preKeyMessage = PreKeySignalMessage(base64Decode(ciphertext));
        try {
          plaintextBytes = await sessionCipher.decrypt(preKeyMessage);
          _ensureActive();
          // PreKey consumed during handshake; schedule debounced replenishment & updated Nostr bundle broadcast
          schedulePostConsumptionReplenishment();
        } catch (e) {
          if (e is DuplicateMessageException || e.toString().contains('DuplicateMessage')) {
            print('[RECV] Signal duplicate/replay prekey message for $senderNostrPubKey (id: ${map['id']})');
            return ('__DUPLICATE_MESSAGE__', '', null, map['id'] as String?, false);
          }
          if (e is UntrustedIdentityException || e.toString().contains('UntrustedIdentity')) {
            print("Peer identity key changed or reinstalled (UntrustedIdentity). Blocking message decryption pending user confirmation for $senderNostrPubKey...");
            _pendingUntrustedIdentities[senderNostrPubKey] = preKeyMessage.identityKey;
            isIdentityKeyChanged = true;
            onIdentityKeyChanged?.call(senderNostrPubKey);
            return ('__UNTRUSTED_IDENTITY__', '', null, map['id'] as String?, true);
          } else {
            rethrow;
          }
        }
      } else {
        final signalMessage = SignalMessage.fromSerialized(base64Decode(ciphertext));
        try {
          plaintextBytes = await sessionCipher.decryptFromSignal(signalMessage);
          _ensureActive();
        } catch (e) {
          if (e is DuplicateMessageException || e.toString().contains('DuplicateMessage')) {
            print('[RECV] Signal duplicate/replay message for $senderNostrPubKey (id: ${map['id']})');
            return ('__DUPLICATE_MESSAGE__', '', null, map['id'] as String?, false);
          }
          if (e is NoSessionException || e.toString().contains('NoSessionException') ||
              e is InvalidKeyIdException || e.toString().contains('InvalidKeyIdException')) {
            print("Session desynchronized for $senderNostrPubKey ($e). Requesting renegotiation...");
            return ('__NEED_SESSION_RESET__', '', null, map['id'] as String?, false);
          }
          rethrow;
        }
      }
      
      final rawDecrypted = utf8.decode(plaintextBytes);
      String text = rawDecrypted;
      DateTime? sentAt;
      String? senderMasterPubKey;
      String? messageId = map['id'] as String?;

      // Target #7: Parse formal MndoMessageEnvelope
      final envelope = MndoMessageEnvelope.tryParse(rawDecrypted);
      if (envelope != null) {
        messageId = envelope.messageId;
        senderMasterPubKey = envelope.senderMasterPubKey;
        sentAt = DateTime.fromMillisecondsSinceEpoch(envelope.timestamp);
        if (envelope.type == 'text') {
          text = envelope.body['text'] as String? ?? '';
        } else if (envelope.type == 'voice_note') {
          text = (envelope.body['text'] ?? envelope.body['payload']) as String? ?? rawDecrypted;
        } else if (envelope.type == 'receipt') {
          text = rawDecrypted;
        } else {
          text = envelope.body['text'] as String? ?? rawDecrypted;
        }
      } else {
        // Fallback for legacy JSON
        try {
          final decoded = jsonDecode(rawDecrypted);
          if (decoded is Map<String, dynamic> && decoded.containsKey('text')) {
            text = decoded['text'] as String? ?? rawDecrypted;
            if (decoded.containsKey('senderMasterPubKey')) {
              senderMasterPubKey = decoded['senderMasterPubKey'] as String?;
            }
            if (decoded.containsKey('sentAt')) {
              final rawSentAt = decoded['sentAt'];
              if (rawSentAt is int) {
                sentAt = DateTime.fromMillisecondsSinceEpoch(rawSentAt);
              } else if (rawSentAt is String) {
                sentAt = DateTime.tryParse(rawSentAt);
              }
            }
          }
        } catch (_) {
          // Plain text legacy message or control token like __SESSION_RESET__
        }
      }

      // Backward compatibility fallback to outer payload if older client sent it
      senderMasterPubKey ??= map['senderMasterPubKey'] as String? ?? '';

      // Fallback: check outer payload 'sentAt' if inner was not present
      if (sentAt == null && map.containsKey('sentAt')) {
        final rawSentAt = map['sentAt'];
        if (rawSentAt is int) {
          sentAt = DateTime.fromMillisecondsSinceEpoch(rawSentAt);
        } else if (rawSentAt is String) {
          sentAt = DateTime.tryParse(rawSentAt);
        }
      }

      return (text, senderMasterPubKey, sentAt, messageId, isIdentityKeyChanged);
    } catch (e) {
      final msg = e.toString();
      final concise = msg.contains('No valid sessions')
          ? 'Session expired or uninitialized (No valid sessions)'
          : (msg.length > 100 ? '${msg.substring(0, 100)}...' : msg);
      print('[RECV] Signal decrypt error for $senderNostrPubKey (id: ${map['id']}): $concise');
      return null;
    }
    });
  }

  /// Explicit user gate: explicitly approve and trust a new identity key after user confirmation / safety number check.
  Future<bool> approveUntrustedIdentity(String peerNostrPubKey) async {
    return withPeerLock(peerNostrPubKey, () async {
      final address = SignalProtocolAddress(peerNostrPubKey, 1);
      final pendingKey = _pendingUntrustedIdentities[peerNostrPubKey];
      if (pendingKey != null) {
        await signalStore.saveIdentity(address, pendingKey);
        await signalStore.deleteSession(address);
        _pendingUntrustedIdentities.remove(peerNostrPubKey);

        final pendingBundle = _pendingPreKeyBundles[peerNostrPubKey];
        if (pendingBundle != null) {
          try {
            final sessionBuilder = SessionBuilder(signalStore, signalStore, signalStore, signalStore, address);
            await sessionBuilder.processPreKeyBundle(pendingBundle);
          } catch (e) {
            print('[SECURITY] Error processing approved PreKeyBundle: $e');
          }
          _pendingPreKeyBundles.remove(peerNostrPubKey);
        }
        return true;
      }
      return false;
    });
  }

  /// Calculates standard 60-digit Numeric Fingerprint (Safety Number) for comparing with peer
  String? computeSafetyNumber(String peerNostrPubKey, {IdentityKey? remoteKey}) {
    try {
      final localKeyPair = signalStore.localIdentityKeyPair;
      final remote = remoteKey ?? _pendingUntrustedIdentities[peerNostrPubKey];
      if (remote == null) return null;

      final gen = NumericFingerprintGenerator(5200);
      final fp = gen.createFor(
        0,
        Uint8List.fromList(utf8.encode(masterPublicKeyHex)),
        localKeyPair.getPublicKey(),
        Uint8List.fromList(utf8.encode(peerNostrPubKey)),
        remote,
      );
      return fp.displayableFingerprint.getDisplayText();
    } catch (e) {
      print('[SECURITY] Failed to compute safety number: $e');
      return null;
    }
  }

  /// Formats 60-digit raw safety number string into 12 readable blocks of 5 digits
  static String formatSafetyNumber(String rawDigits) {
    final clean = rawDigits.replaceAll(RegExp(r'\s+'), '');
    final chunks = <String>[];
    for (int i = 0; i < clean.length; i += 5) {
      chunks.add(clean.substring(i, dart_math.min(i + 5, clean.length)));
    }
    return chunks.join(' ');
  }
}
