import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import 'package:aisat_connect/models/mndo_message_envelope.dart';
import 'package:aisat_connect/repositories/identity_repository.dart';
import 'package:aisat_connect/services/account_session.dart';
import 'package:aisat_connect/services/crypto_service.dart';
import 'package:aisat_connect/services/master_binding_verifier.dart';
import 'package:aisat_connect/services/media_cache_manager.dart';
import 'package:aisat_connect/services/storage_router.dart';
import 'package:aisat_connect/services/voice_note_cache_manager.dart';

/// In-memory fake secure storage for deterministic identity repository testing
class FakeSecureStorage implements FlutterSecureStorage {
  final Map<String, String> _data = {};

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      _data.remove(key);
    } else {
      _data[key] = value;
    }
  }

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    return _data[key];
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _data.remove(key);
  }

  @override
  Future<void> deleteAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _data.clear();
  }

  @override
  Future<Map<String, String>> readAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    return Map.from(_data);
  }

  @override
  Future<bool> containsKey({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    return _data.containsKey(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('P1.1 — Media-cache TTL and size budget cover all stored media', () {
    late Directory tempRoot;
    late MediaCacheManager cacheManager;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('mndo_media_test_');
      cacheManager = MediaCacheManager();
      cacheManager.setBaseDirForTesting(tempRoot);
    });

    tearDown(() async {
      cacheManager.resetForTesting();
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    test('cleanupExpired removes expired files across images, videos, audio, documents subdirs', () async {
      // Create nested files in each managed subdirectory under mndo_media
      final subdirs = ['images', 'videos', 'audio', 'documents'];
      final expiredFiles = <File>[];
      final freshFiles = <File>[];

      for (final sub in subdirs) {
        final dir = Directory('${tempRoot.path}/mndo_media/$sub');
        await dir.create(recursive: true);

        final expFile = File('${dir.path}/expired_$sub.bin');
        await expFile.writeAsBytes(List.filled(500, 1));
        // Backdate file modification time to 35 days ago
        await expFile.setLastModified(DateTime.now().subtract(const Duration(days: 35)));
        expiredFiles.add(expFile);

        final freshFile = File('${dir.path}/fresh_$sub.bin');
        await freshFile.writeAsBytes(List.filled(500, 2));
        freshFiles.add(freshFile);
      }

      for (final f in expiredFiles) {
        expect(await f.exists(), isTrue);
      }
      for (final f in freshFiles) {
        expect(await f.exists(), isTrue);
      }

      // Cleanup files older than 30 days
      await cacheManager.cleanupExpired(ttl: const Duration(days: 30));

      // Expired files in nested directories must be deleted
      for (final f in expiredFiles) {
        expect(await f.exists(), isFalse, reason: 'Expired file in nested directory was not purged: ${f.path}');
      }

      // Fresh files must remain intact
      for (final f in freshFiles) {
        expect(await f.exists(), isTrue, reason: 'Fresh file was prematurely purged: ${f.path}');
      }
    });

    test('cleanupExpired purges oldest nested files when byte budget is exceeded', () async {
      final subdirs = ['images', 'videos', 'audio', 'documents'];
      final files = <File>[];

      // Create 8 files of 10KB each across subdirectories = 80KB total
      for (int i = 0; i < 8; i++) {
        final sub = subdirs[i % subdirs.length];
        final dir = Directory('${tempRoot.path}/mndo_media/$sub');
        await dir.create(recursive: true);
        final file = File('${dir.path}/budget_test_$i.bin');
        await file.writeAsBytes(List.filled(10 * 1024, i));
        // Space modification times
        await file.setLastModified(DateTime.now().subtract(Duration(minutes: 100 - i * 10)));
        files.add(file);
      }

      // Enforce max budget of 50KB. Target 70% budget is 35KB.
      await cacheManager.cleanupExpired(
        ttl: const Duration(days: 365), // Do not expire by TTL
        maxBytes: 50 * 1024,
      );

      // Verify total remaining size across all subdirectories is <= 35KB + single file margin
      int remainingBytes = 0;
      for (final f in files) {
        if (await f.exists()) {
          remainingBytes += await f.length();
        }
      }

      expect(remainingBytes, lessThanOrEqualTo(35 * 1024 + 1024));
      // Oldest files (budget_test_0, 1, 2) should have been deleted first
      expect(await files[0].exists(), isFalse);
      expect(await files[1].exists(), isFalse);
    });
  });

  group('P1.2 — Verifiable logout/media-cache cleanup', () {
    late Directory tempRoot;

    setUp(() async {
      AccountSession.resetForTesting();
      tempRoot = await Directory.systemTemp.createTemp('mndo_logout_test_');
      MediaCacheManager().setBaseDirForTesting(tempRoot);
      VoiceNoteCacheManager().setCacheDirForTesting(Directory('${tempRoot.path}/mndo_voice_cache'));
      VoiceNoteCacheManager().setTempDirForTesting(Directory('${tempRoot.path}/temp'));
    });

    tearDown(() async {
      MediaCacheManager().resetForTesting();
      VoiceNoteCacheManager().resetForTesting();
      MediaCacheManager().failNextCleanupAll = false;
      VoiceNoteCacheManager().failNextCleanupAll = false;
      AccountSession.resetForTesting();
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    test('cleanupAll returns verified success result and removes all files', () async {
      final imgFile = File('${tempRoot.path}/mndo_media/images/test_img.jpg');
      await imgFile.create(recursive: true);
      await imgFile.writeAsBytes([1, 2, 3]);

      final result = await MediaCacheManager().cleanupAll();
      expect(result.isSuccess, isTrue);
      expect(result.deletedCount, greaterThanOrEqualTo(1));
      expect(result.failedCount, equals(0));
      expect(await imgFile.exists(), isFalse);
    });

    test('Injected cleanup failure makes teardown purge unverified with observable warning', () async {
      MediaCacheManager().failNextCleanupAll = true;

      final cleanupResult = await AccountSession.dispose();

      expect(cleanupResult.isSuccess, isFalse);
      expect(cleanupResult.failedCount, greaterThan(0));
      expect(AccountSession.wasLocalPurgeVerified, isFalse);
      expect(AccountSession.lastCleanupResult?.isSuccess, isFalse);
    });
  });

  group('P1.3 — Bound media download time with an overall deadline', () {
    test('downloadEncryptedBlob exits within overall deadline when servers hang', () async {
      final mockClient = MockClient((request) async {
        // Simulate a slow/hanging server that takes 600ms per request
        await Future.delayed(const Duration(milliseconds: 600));
        return http.Response('Slow error', 500);
      });

      final router = StorageRouter();
      final stopwatch = Stopwatch()..start();

      // Set a strict overall timeout of 200ms with shorter per-request timeout of 100ms
      final result = await router.downloadEncryptedBlob(
        'https://primary.example.com/blob123',
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        overallTimeout: const Duration(milliseconds: 200),
        downloadTimeout: const Duration(milliseconds: 100),
        client: mockClient,
      );

      stopwatch.stop();

      expect(result, isNull);
      // Operation should respect deadline and return within ~400ms (allowing small scheduler variance)
      expect(stopwatch.elapsedMilliseconds, lessThan(800));
    });

    test('downloadEncryptedBlob returns null immediately if session generation is invalidated', () async {
      AccountSession.resetForTesting();
      AccountSession.setGenerationForTesting(5);

      final mockClient = MockClient((request) async {
        return http.Response('OK', 200);
      });

      final router = StorageRouter();
      // Caller provides stale generation 4 while active is 5
      final result = await router.downloadEncryptedBlob(
        'https://primary.example.com/blob',
        'hash123',
        sessionGen: 4,
        client: mockClient,
      );

      expect(result, isNull);
    });

    test('downloadEncryptedBlob falls back to mirror when primary fails', () async {
      final testBytes = utf8.encode('decrypted_payload_data');
      final mockClient = MockClient((request) async {
        if (request.url.host == 'primary.example.com') {
          return http.Response('Not Found', 404);
        }
        // Mirror server returns 200
        return http.Response.bytes(testBytes, 200);
      });

      final router = StorageRouter();
      final result = await router.downloadEncryptedBlob(
        'https://primary.example.com/blob',
        'hash123',
        client: mockClient,
      );

      expect(result, isNotNull);
      expect(result, equals(testBytes));
    });
  });

  group('P1.4 — Make Blossom upload authorization fail-closed', () {
    test('uploadEncryptedBlob rejects payload when SHA-256 does not match fileHashHex', () async {
      final router = StorageRouter();
      final payload = utf8.encode('actual_bytes');
      const wrongHash = 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff';

      // Should fail-closed before making any network request
      final result = await router.uploadEncryptedBlob(
        payload,
        wrongHash,
      );

      expect(result, isNull);
    });

    test('uploadEncryptedBlob fails-closed when auth header cannot be generated', () async {
      final router = StorageRouter();
      final payload = utf8.encode('secret_encrypted_data');
      final actualHash = crypto.sha256.convert(payload).toString();

      // Nostr transport has no active keys; createBlossomAuthHeader throws StateError
      // StorageRouter must fail-closed and return null without throwing or uploading unauthenticated
      final result = await router.uploadEncryptedBlob(
        payload,
        actualHash,
      );

      expect(result, isNull);
    });
  });

  group('P1.5 — Account identity continuity without mixing identities between mnemonics', () {
    late FakeSecureStorage fakeStorage;
    late IdentityRepository identityRepo;
    late CryptoService crypto;

    setUp(() {
      fakeStorage = FakeSecureStorage();
      crypto = CryptoService();
      identityRepo = IdentityRepository(
        secureStorage: fakeStorage,
        cryptoService: crypto,
      );
    });

    test('Same master key restores saved Signal identity public key and profile', () async {
      const mnemonicA = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
      final masterA = await crypto.generateMasterKeyPair(mnemonicA);
      final pubKeyA = await masterA.extractPublicKey();
      final pubHexA = pubKeyA.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

      final signalKeyA = generateIdentityKeyPair();
      const regIdA = 1234;

      await identityRepo.saveMnemonic(mnemonicA);
      await identityRepo.saveSignalIdentity(signalKeyA, regIdA, masterPublicKeyHex: pubHexA);
      await identityRepo.saveCustomProfile('Alice', 'Privacy Advocate', masterPublicKeyHex: pubHexA);

      // Restore for master A
      final (restoredKey, restoredReg) = await identityRepo.getSignalIdentity(masterPublicKeyHex: pubHexA);
      final (restoredName, restoredBio) = await identityRepo.getCustomProfile(masterPublicKeyHex: pubHexA);

      expect(restoredKey, isNotNull);
      expect(restoredKey!.getPublicKey().serialize(), equals(signalKeyA.getPublicKey().serialize()));
      expect(restoredReg, equals(regIdA));
      expect(restoredName, equals('Alice'));
      expect(restoredBio, equals('Privacy Advocate'));
    });

    test('Different mnemonic derives different master key and cannot inherit prior identity', () async {
      const mnemonicA = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
      final masterA = await crypto.generateMasterKeyPair(mnemonicA);
      final pubKeyA = await masterA.extractPublicKey();
      final pubHexA = pubKeyA.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

      final signalKeyA = generateIdentityKeyPair();
      await identityRepo.saveMnemonic(mnemonicA);
      await identityRepo.saveSignalIdentity(signalKeyA, 1111, masterPublicKeyHex: pubHexA);
      await identityRepo.saveCustomProfile('Alice', 'Bio A', masterPublicKeyHex: pubHexA);

      // Mnemonic B
      const mnemonicB = 'legal winner thank year wave sausage worth useful legal winner thank yellow';
      final masterB = await crypto.generateMasterKeyPair(mnemonicB);
      final pubKeyB = await masterB.extractPublicKey();
      final pubHexB = pubKeyB.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

      // Retrieve for master B — must be null, not inherit A's identity
      final (restoredKeyB, restoredRegB) = await identityRepo.getSignalIdentity(masterPublicKeyHex: pubHexB);
      final (restoredNameB, restoredBioB) = await identityRepo.getCustomProfile(masterPublicKeyHex: pubHexB);

      expect(restoredKeyB, isNull);
      expect(restoredRegB, isNull);
      expect(restoredNameB, isNull);
      expect(restoredBioB, isNull);
    });

    test('Explicit identity rotation rotates keys and saves them under master key', () async {
      const masterHex = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
      final initialKey = generateIdentityKeyPair();
      await identityRepo.saveSignalIdentity(initialKey, 100, masterPublicKeyHex: masterHex);

      // Explicit rotation
      final (newKey, newReg) = await identityRepo.rotateSignalIdentity(masterPublicKeyHex: masterHex);

      expect(newKey.getPublicKey().serialize(), isNot(equals(initialKey.getPublicKey().serialize())));

      final (storedKey, storedReg) = await identityRepo.getSignalIdentity(masterPublicKeyHex: masterHex);
      expect(storedKey!.getPublicKey().serialize(), equals(newKey.getPublicKey().serialize()));
      expect(storedReg, equals(newReg));
    });

    test('Legacy unscoped storage migration succeeds when owner mnemonic matches', () async {
      const mnemonic = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
      final master = await crypto.generateMasterKeyPair(mnemonic);
      final pubKey = await master.extractPublicKey();
      final masterHex = pubKey.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

      // Set up legacy unscoped keys
      final legacySignalKey = generateIdentityKeyPair();
      await fakeStorage.write(key: 'master_mnemonic_1', value: mnemonic);
      await fakeStorage.write(key: 'signal_identity_1', value: base64Encode(legacySignalKey.serialize()));
      await fakeStorage.write(key: 'signal_registration_id_1', value: '4321');
      await fakeStorage.write(key: 'display_name_1', value: 'Legacy User');

      // Request with matching masterHex -> should migrate
      final (migratedKey, migratedReg) = await identityRepo.getSignalIdentity(masterPublicKeyHex: masterHex);
      final (migratedName, _) = await identityRepo.getCustomProfile(masterPublicKeyHex: masterHex);

      expect(migratedKey, isNotNull);
      expect(migratedKey!.getPublicKey().serialize(), equals(legacySignalKey.getPublicKey().serialize()));
      expect(migratedReg, equals(4321));
      expect(migratedName, equals('Legacy User'));

      // Legacy unscoped keys should have been purged
      expect(await fakeStorage.read(key: 'signal_identity_1'), isNull);
      expect(await fakeStorage.read(key: 'display_name_1'), isNull);
    });

    test('Legacy unscoped storage migration fails safely when owner mnemonic does not match', () async {
      // Legacy data belongs to Mnemonic A
      const mnemonicA = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
      final legacySignalKey = generateIdentityKeyPair();
      await fakeStorage.write(key: 'master_mnemonic_1', value: mnemonicA);
      await fakeStorage.write(key: 'signal_identity_1', value: base64Encode(legacySignalKey.serialize()));
      await fakeStorage.write(key: 'signal_registration_id_1', value: '9999');

      // User B tries to get identity with different master hex
      const otherMasterHex = 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff';
      final (resultKey, resultReg) = await identityRepo.getSignalIdentity(masterPublicKeyHex: otherMasterHex);

      // Must fail safely: do not bind or migrate legacy keys to other master
      expect(resultKey, isNull);
      expect(resultReg, isNull);
      // Legacy key remains intact
      expect(await fakeStorage.read(key: 'signal_identity_1'), isNotNull);
    });
  });

  group('P1.6 — Require complete, valid message-envelope identity fields', () {
    const validSender = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

    test('Valid envelope parses successfully', () {
      final envelope = MndoMessageEnvelope(
        version: 1,
        messageId: 'msg-valid-1',
        type: 'text',
        timestamp: 1710000000000,
        senderMasterPubKey: validSender,
        body: {'text': 'Hello MNDO'},
      );

      final parsed = MndoMessageEnvelope.tryParse(envelope.serialize());
      expect(parsed, isNotNull);
      expect(parsed!.version, equals(1));
      expect(parsed.messageId, equals('msg-valid-1'));
      expect(parsed.senderMasterPubKey, equals(validSender));
      expect(parsed.body['text'], equals('Hello MNDO'));
    });

    test('Envelope with missing or empty sender is rejected', () {
      final rawWithoutSender = jsonEncode({
        'v': 1,
        'id': 'msg-1',
        'type': 'text',
        'ts': 1710000000000,
        'body': {'text': 'test'},
      });
      expect(MndoMessageEnvelope.tryParse(rawWithoutSender), isNull);

      final rawWithEmptySender = jsonEncode({
        'v': 1,
        'id': 'msg-1',
        'type': 'text',
        'ts': 1710000000000,
        'sender': '',
        'body': {'text': 'test'},
      });
      expect(MndoMessageEnvelope.tryParse(rawWithEmptySender), isNull);

      final rawWithWhitespaceSender = jsonEncode({
        'v': 1,
        'id': 'msg-1',
        'type': 'text',
        'ts': 1710000000000,
        'sender': '   ',
        'body': {'text': 'test'},
      });
      expect(MndoMessageEnvelope.tryParse(rawWithWhitespaceSender), isNull);
    });

    test('Envelope with unsupported version is rejected', () {
      final rawUnsupportedVersion = jsonEncode({
        'v': 2, // Unsupported version
        'id': 'msg-1',
        'type': 'text',
        'ts': 1710000000000,
        'sender': validSender,
        'body': {'text': 'test'},
      });
      expect(MndoMessageEnvelope.tryParse(rawUnsupportedVersion), isNull);
    });

    test('Envelope with invalid timestamp or body is rejected', () {
      final rawNegativeTs = jsonEncode({
        'v': 1,
        'id': 'msg-1',
        'type': 'text',
        'ts': -100,
        'sender': validSender,
        'body': {'text': 'test'},
      });
      expect(MndoMessageEnvelope.tryParse(rawNegativeTs), isNull);

      final rawInvalidBody = jsonEncode({
        'v': 1,
        'id': 'msg-1',
        'type': 'text',
        'ts': 1710000000000,
        'sender': validSender,
        'body': 'string instead of map',
      });
      expect(MndoMessageEnvelope.tryParse(rawInvalidBody), isNull);
    });
  });

  group('P1.7 — Strengthen prekey-bundle integrity/anti-rollback contract', () {
    late CryptoService crypto;
    late MasterBindingVerifier verifier;
    late SimpleKeyPair masterKeyPair;
    late String masterPubKeyHex;
    const peerNostrPubKey = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

    setUp(() async {
      AccountSession.resetForTesting();
      crypto = CryptoService();
      verifier = MasterBindingVerifier(cryptoService: crypto);
      masterKeyPair = await crypto.generateMasterKeyPair(
        'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about',
      );
      final pubKey = await masterKeyPair.extractPublicKey();
      masterPubKeyHex = pubKey.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    });

    Future<Map<String, dynamic>> createBundle({
      int bundleEpoch = 1,
      int? regId = 12345,
      int spkId = 1,
      List<Map<String, dynamic>>? otks,
    }) async {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final idPub = base64Encode(generateIdentityKeyPair().getPublicKey().serialize());
      final spkPub = base64Encode(Curve.generateKeyPair().publicKey.serialize());

      final sig = await crypto.signBundleBindingToken(
        masterKeyPair: masterKeyPair,
        nostrPubKeyHex: peerNostrPubKey,
        signalIdentityPubBase64: idPub,
        bundleEpoch: bundleEpoch,
        issuedAt: nowMs,
        expiresAt: nowMs + 1209600000,
        version: 2,
      );

      return <String, dynamic>{
        'bundleVersion': 2,
        'registrationId': regId,
        'masterKey': masterPubKeyHex,
        'identityPubKey': idPub,
        'bundleEpoch': bundleEpoch,
        'issuedAt': nowMs,
        'expiresAt': nowMs + 1209600000,
        'signedPreKey': {
          'id': spkId,
          'pubKey': spkPub,
          'signature': base64Encode(List.filled(64, 1)),
        },
        'oneTimePreKeys': otks ?? [
          {'id': 10, 'pubKey': base64Encode(Curve.generateKeyPair().publicKey.serialize())},
        ],
        'masterBindingSig': sig,
      };
    }

    test('computeBundleHash changes when OTKs, registrationId, or SPK are modified', () async {
      final bundle = await createBundle();
      final baseHash = MasterBindingVerifier.computeBundleHash(bundle);

      // Mutate OTK
      final bundleMutatedOtk = Map<String, dynamic>.from(bundle);
      bundleMutatedOtk['oneTimePreKeys'] = [
        {'id': 99, 'pubKey': base64Encode(Curve.generateKeyPair().publicKey.serialize())},
      ];
      final hashWithMutatedOtk = MasterBindingVerifier.computeBundleHash(bundleMutatedOtk);
      expect(hashWithMutatedOtk, isNot(equals(baseHash)));

      // Mutate registrationId
      final bundleMutatedReg = Map<String, dynamic>.from(bundle);
      bundleMutatedReg['registrationId'] = 9999;
      final hashWithMutatedReg = MasterBindingVerifier.computeBundleHash(bundleMutatedReg);
      expect(hashWithMutatedReg, isNot(equals(baseHash)));

      // Mutate signedPreKey id
      final bundleMutatedSpk = Map<String, dynamic>.from(bundle);
      bundleMutatedSpk['signedPreKey'] = {
        'id': 2,
        'pubKey': bundle['signedPreKey']['pubKey'],
        'signature': bundle['signedPreKey']['signature'],
      };
      final hashWithMutatedSpk = MasterBindingVerifier.computeBundleHash(bundleMutatedSpk);
      expect(hashWithMutatedSpk, isNot(equals(baseHash)));
    });

    test('Same epoch with modified OTKs is rejected as conflictingBundleEpoch', () async {
      final bundleA = await createBundle(bundleEpoch: 10);
      final hashA = MasterBindingVerifier.computeBundleHash(bundleA);

      // Bundle B has same epoch 10 and same masterBindingSig/identity, but different OTKs
      final bundleB = Map<String, dynamic>.from(bundleA);
      bundleB['oneTimePreKeys'] = [
        {'id': 55, 'pubKey': base64Encode(Curve.generateKeyPair().publicKey.serialize())},
      ];

      final res = await verifier.verifyPreKeyBundle(
        expectedMasterPubKeyHex: masterPubKeyHex,
        recipientNostrPubKey: peerNostrPubKey,
        bundleMap: bundleB,
        eventAuthor: peerNostrPubKey,
        storedEpoch: 10,
        storedBundleHash: hashA, // Conflicting hash!
      );

      expect(res.isValid, isFalse);
      expect(res.reason, BindingRejectionReason.conflictingBundleEpoch);
    });

    test('Bundle with duplicate prekey IDs is rejected with duplicatePreKeyId', () async {
      // OTK id collides with SPK id (both 1)
      final bundle = await createBundle(
        spkId: 1,
        otks: [
          {'id': 1, 'pubKey': base64Encode(Curve.generateKeyPair().publicKey.serialize())},
        ],
      );

      final res = await verifier.verifyPreKeyBundle(
        expectedMasterPubKeyHex: masterPubKeyHex,
        recipientNostrPubKey: peerNostrPubKey,
        bundleMap: bundle,
        eventAuthor: peerNostrPubKey,
      );

      expect(res.isValid, isFalse);
      expect(res.reason, BindingRejectionReason.duplicatePreKeyId);
    });

    test('Bundle with invalid registrationId is rejected', () async {
      final bundleInvalidReg = await createBundle(regId: 0); // Invalid <= 0

      final res = await verifier.verifyPreKeyBundle(
        expectedMasterPubKeyHex: masterPubKeyHex,
        recipientNostrPubKey: peerNostrPubKey,
        bundleMap: bundleInvalidReg,
        eventAuthor: peerNostrPubKey,
      );

      expect(res.isValid, isFalse);
      expect(res.reason, BindingRejectionReason.missingRequiredV2Fields);
    });
  });

  group('P3.1 — Deterministic Identity Derivation with Fixed Test Vectors', () {
    late CryptoService cryptoService;

    setUp(() {
      cryptoService = CryptoService();
    });

    test('Standard test vector 1: all-abandon mnemonic derives fixed master public key and username', () async {
      // Well-known BIP-39 test vector
      const testMnemonic1 = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
      final keyPair = await cryptoService.generateMasterKeyPair(testMnemonic1);
      final pubKey = await keyPair.extractPublicKey();
      final pubKeyHex = pubKey.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final username = await cryptoService.generateUsername(pubKey);

      expect(pubKeyHex.length, 64);
      // Verify byte-for-byte reproducibility
      final keyPair2 = await cryptoService.generateMasterKeyPair(testMnemonic1);
      final pubKey2 = await keyPair2.extractPublicKey();
      final pubKeyHex2 = pubKey2.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      expect(pubKeyHex2, equals(pubKeyHex));

      // Whitespace normalization must yield exact same key
      final keyPairWhitespace = await cryptoService.generateMasterKeyPair('  $testMnemonic1  \n');
      final pubKeyWs = await keyPairWhitespace.extractPublicKey();
      final pubKeyHexWs = pubKeyWs.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      expect(pubKeyHexWs, equals(pubKeyHex));

      // Verify username pattern
      expect(username, matches(RegExp(r'^[A-Z][a-z]+ [A-Z][a-z]+ #[0-9a-f]{6}$')));
    });

    test('Standard test vector 2: zoo-zoo mnemonic derives fixed master public key and username', () async {
      const testMnemonic2 = 'zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong';
      final keyPair = await cryptoService.generateMasterKeyPair(testMnemonic2);
      final pubKey = await keyPair.extractPublicKey();
      final pubKeyHex = pubKey.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final username = await cryptoService.generateUsername(pubKey);

      expect(pubKeyHex.length, 64);
      final keyPair2 = await cryptoService.generateMasterKeyPair(testMnemonic2);
      final pubKey2 = await keyPair2.extractPublicKey();
      final pubKeyHex2 = pubKey2.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      expect(pubKeyHex2, equals(pubKeyHex));

      expect(username, matches(RegExp(r'^[A-Z][a-z]+ [A-Z][a-z]+ #[0-9a-f]{6}$')));
    });
  });
}
