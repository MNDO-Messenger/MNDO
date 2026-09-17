import 'dart:convert';
import 'dart:math' as dart_math;
import 'package:flutter/foundation.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'signal_store.dart';
import 'nostr_relay_service.dart';

class SignalMessagingService {
  final SignalStore signalStore;
  final NostrRelayService nostrService;
  final String masterPublicKeyHex;

  SignalMessagingService({
    required this.signalStore,
    required this.nostrService,
    required this.masterPublicKeyHex,
  });

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
    
    nostrService.broadcastPreKeyBundle(masterPublicKeyHex, payload);
  }

  Future<bool> hasSignalSession(String nostrPubKey) async {
    return await signalStore.containsSession(SignalProtocolAddress(nostrPubKey, 1));
  }

  Future<bool> fetchAndEstablishSession(String recipientNostrPubKey) async {
    final hasSession = await hasSignalSession(recipientNostrPubKey);
    if (hasSession) return true;
    
    final bundleMap = await nostrService.fetchUserPrekeys(recipientNostrPubKey);
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
      
      final oneTimePreKeys = List<Map<String, dynamic>>.from(bundleMap['oneTimePreKeys']);
      
      final randomIndex = dart_math.Random().nextInt(oneTimePreKeys.length);
      final randomOtkp = oneTimePreKeys[randomIndex];
      final preKeyId = randomOtkp['id'];
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
      
      await sessionBuilder.processPreKeyBundle(preKeyBundle);
      print("Successfully established Signal Session with $recipientNostrPubKey");
      return true;
    } catch (e) {
      print("Failed to process PreKey Bundle: $e");
      return false;
    }
  }

  Future<void> sendMessage(String recipientNostrPubKey, String text) async {
    try {
      print("DEBUG: Encrypting message for $recipientNostrPubKey...");
      final address = SignalProtocolAddress(recipientNostrPubKey, 1);
      final sessionCipher = SessionCipher(signalStore, signalStore, signalStore, signalStore, address);
      
      final ciphertextMessage = await sessionCipher.encrypt(Uint8List.fromList(utf8.encode(text)));
      
      final payloadMap = {
        'type': ciphertextMessage.getType(),
        'ciphertext': base64Encode(ciphertextMessage.serialize()),
        'senderMasterPubKey': masterPublicKeyHex,
      };
      
      print("DEBUG: Sending encrypted payload to relay (Type: ${ciphertextMessage.getType()})...");
      nostrService.sendEncryptedPayload(recipientNostrPubKey, jsonEncode(payloadMap));
    } catch (e) {
      print('DEBUG: Encryption failed: $e');
    }
  }

  Future<(String plaintext, String senderMasterPubKeyToVerify)?> decryptMessage(String senderNostrPubKey, Map<String, dynamic> map) async {
    try {
      final type = map['type'];
      final ciphertext = map['ciphertext'];
      final senderMasterPubKeyFromPayload = map['senderMasterPubKey'];
      
      final address = SignalProtocolAddress(senderNostrPubKey, 1);
      final sessionCipher = SessionCipher(signalStore, signalStore, signalStore, signalStore, address);
      
      Uint8List plaintextBytes;
      if (type == CiphertextMessage.prekeyType) {
        final preKeyMessage = PreKeySignalMessage(base64Decode(ciphertext));
        plaintextBytes = await sessionCipher.decrypt(preKeyMessage);
      } else {
        final signalMessage = SignalMessage.fromSerialized(base64Decode(ciphertext));
        plaintextBytes = await sessionCipher.decryptFromSignal(signalMessage);
      }
      
      final plaintext = utf8.decode(plaintextBytes);
      return (plaintext, senderMasterPubKeyFromPayload as String? ?? '');
    } catch (e) {
      print('Error processing incoming encrypted message: $e');
      return null;
    }
  }
}
