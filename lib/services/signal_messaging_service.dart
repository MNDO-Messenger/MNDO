import 'dart:convert';
import 'dart:math' as dart_math;
import 'package:flutter/foundation.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'signal_store.dart';
import 'nostr_relay_service.dart';
import '../models/mndo_message_envelope.dart';

class SignalMessagingService {
  final SignalStore signalStore;
  final NostrRelayService nostrService;
  final String masterPublicKeyHex;

  SignalMessagingService({
    required this.signalStore,
    required this.nostrService,
    required this.masterPublicKeyHex,
  });

  /// Check local unused OTPKs and automatically replenish to Nostr when pool drops below threshold (Target #3)
  Future<void> checkAndReplenishPreKeys(IdentityKeyPair signalIdentityKeyPair, int signalRegistrationId) async {
    final count = await signalStore.getPreKeyCount();
    if (count < 25) {
      print("DEBUG: PreKeys pool low ($count < 25). Replenishing fresh One-Time PreKeys...");
      await generateAndBroadcastPreKeys(signalIdentityKeyPair, signalRegistrationId);
    }
  }

  Future<void> generateAndBroadcastPreKeys(IdentityKeyPair signalIdentityKeyPair, int signalRegistrationId) async {
    // 1. Signed PreKey
    SignedPreKeyRecord signedPreKey;
    if (await signalStore.containsSignedPreKey(1)) {
      signedPreKey = await signalStore.loadSignedPreKey(1);
    } else {
      signedPreKey = generateSignedPreKey(signalIdentityKeyPair, 1);
      await signalStore.storeSignedPreKey(1, signedPreKey);
    }
    
    // 2. Intelligent PreKey Top-Up
    final currentPreKeyCount = await signalStore.getPreKeyCount();
    
    if (currentPreKeyCount < 15) {
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
    
    final identityPubBase64 = base64Encode(signalIdentityKeyPair.getPublicKey().serialize());
    
    final signedPreKeyMap = {
      'id': signedPreKey.id,
      'pubKey': base64Encode(signedPreKey.getKeyPair().publicKey.serialize()),
      'signature': base64Encode(signedPreKey.signature),
    };
    
    final oneTimePreKeysMap = allAvailablePreKeys.map((pk) => {
      'id': pk.id,
      'pubKey': base64Encode(pk.getKeyPair().publicKey.serialize()),
    }).toList();
    
    final payload = {
      'masterKey': masterPublicKeyHex,
      'registrationId': signalRegistrationId,
      'identityPubKey': identityPubBase64,
      'signedPreKey': signedPreKeyMap,
      'oneTimePreKeys': oneTimePreKeysMap,
    };
    
    await nostrService.broadcastPreKeyBundle(masterPublicKeyHex, payload);
  }

  Future<bool> hasSignalSession(String nostrPubKey) async {
    return await signalStore.containsSession(SignalProtocolAddress(nostrPubKey, 1));
  }

  Future<void> deleteSession(String nostrPubKey) async {
    final address = SignalProtocolAddress(nostrPubKey, 1);
    await signalStore.deleteSession(address);
  }

  Future<bool> fetchAndEstablishSession(
    String recipientNostrPubKey, {
    String? masterPubKeyHex,
    bool force = false,
  }) async {
    if (!force) {
      final hasSession = await hasSignalSession(recipientNostrPubKey);
      if (hasSession) return true;
    } else {
      await deleteSession(recipientNostrPubKey);
    }
    
    final bundleMap = await nostrService.fetchUserPrekeys(recipientNostrPubKey, masterPubKeyHex: masterPubKeyHex);
    if (bundleMap == null || bundleMap.isEmpty) {
      print("No PreKey bundle found for user on network!");
      return false;
    }
    
    try {
      final registrationId = bundleMap['registrationId'];
      final identityPubKey = IdentityKey.fromBytes(base64Decode(bundleMap['identityPubKey']), 0);
      
      final signedPreKeyMap = bundleMap['signedPreKey'];
      final signedPreKeyId = signedPreKeyMap['id'];
      final signedPreKeyPub = Curve.decodePoint(base64Decode(signedPreKeyMap['pubKey']), 0);
      final signature = base64Decode(signedPreKeyMap['signature']);
      
      final rawOneTime = bundleMap['oneTimePreKeys'];
      if (rawOneTime == null || rawOneTime is! List || rawOneTime.isEmpty) {
        print("PreKey bundle for $recipientNostrPubKey contains no one-time prekeys.");
        return false;
      }
      final oneTimePreKeys = List<Map<String, dynamic>>.from(rawOneTime);
      
      final randomIndex = dart_math.Random().nextInt(oneTimePreKeys.length);
      final randomOtkp = oneTimePreKeys[randomIndex];
      final preKeyId = randomOtkp['id'] as int;
      final preKeyPub = Curve.decodePoint(base64Decode(randomOtkp['pubKey']), 0);
      
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
      
      try {
        await sessionBuilder.processPreKeyBundle(preKeyBundle);
      } catch (e) {
        if (e is UntrustedIdentityException || e.toString().contains('UntrustedIdentity')) {
          print("Identity key changed for $recipientNostrPubKey during bundle processing. Trusting new identity key and rebuilding session...");
          await signalStore.saveIdentity(address, identityPubKey);
          await signalStore.deleteSession(address);
          final freshSessionBuilder = SessionBuilder(signalStore, signalStore, signalStore, signalStore, address);
          await freshSessionBuilder.processPreKeyBundle(preKeyBundle);
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
      final ciphertextMessage = await sessionCipher.encrypt(Uint8List.fromList(utf8.encode(innerPayload)));
      
      final payloadMap = {
        'type': ciphertextMessage.getType(),
        'ciphertext': base64Encode(ciphertextMessage.serialize()),
        'sentAt': timestamp.millisecondsSinceEpoch,
        'id': msgId,
      };
      
      print("DEBUG: Sending encrypted payload to relay (Type: ${ciphertextMessage.getType()}, ID: $msgId)...");
      await nostrService.sendEncryptedPayload(recipientNostrPubKey, jsonEncode(payloadMap));
      return msgId;
    } catch (e) {
      print('DEBUG: Encryption or sending failed: $e');
      rethrow;
    }
  }

  Future<(String plaintext, String senderMasterPubKeyToVerify, DateTime? sentAt, String? messageId, bool isIdentityKeyChanged)?> decryptMessage(String senderNostrPubKey, Map<String, dynamic> map) async {
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
        } catch (e) {
          if (e is UntrustedIdentityException || e.toString().contains('UntrustedIdentity')) {
            print("Peer identity key changed or reinstalled (UntrustedIdentity). Updating identity and resetting session for $senderNostrPubKey...");
            isIdentityKeyChanged = true;
            await signalStore.saveIdentity(address, preKeyMessage.identityKey);
            await signalStore.deleteSession(address);
            final freshSessionCipher = SessionCipher(signalStore, signalStore, signalStore, signalStore, address);
            plaintextBytes = await freshSessionCipher.decrypt(preKeyMessage);
          } else {
            rethrow;
          }
        }
      } else {
        final signalMessage = SignalMessage.fromSerialized(base64Decode(ciphertext));
        try {
          plaintextBytes = await sessionCipher.decryptFromSignal(signalMessage);
        } catch (e) {
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
          text = envelope.body['payload'] as String? ?? rawDecrypted;
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
      print('Error processing incoming encrypted message: $e');
      return null;
    }
  }
}
