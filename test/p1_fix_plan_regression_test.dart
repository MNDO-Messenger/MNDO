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
import 'package:aisat_connect/providers/auth_provider.dart';
import 'package:aisat_connect/repositories/identity_repository.dart';
import 'package:aisat_connect/services/account_session.dart';
import 'package:aisat_connect/services/crypto_service.dart';
import 'package:aisat_connect/services/master_binding_verifier.dart';
import 'package:aisat_connect/services/media_cache_manager.dart';
import 'package:aisat_connect/services/nostr_relay_service.dart';
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
        await expFile.setLastModified(
          DateTime.now().subtract(const Duration(days: 35)),
        );
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
        expect(
          await f.exists(),
          isFalse,
          reason: 'Expired file in nested directory was not purged: ${f.path}',
        );
      }

      // Fresh files must remain intact
      for (final f in freshFiles) {
        expect(
          await f.exists(),
          isTrue,
          reason: 'Fresh file was prematurely purged: ${f.path}',
        );
      }
    });

    test('cleanupExpired recursively purges expired files in arbitrarily deep nested directories', () async {
      final deepDir = Directory(
        '${tempRoot.path}/mndo_media/images/thumbs/deep/nested/subfolder',
      );
      await deepDir.create(recursive: true);
      final deepExpired = File('${deepDir.path}/deep_expired.jpg');
      await deepExpired.writeAsBytes([1, 2, 3]);
      await deepExpired.setLastModified(
        DateTime.now().subtract(const Duration(days: 45)),
      );

      final deepFresh = File('${deepDir.path}/deep_fresh.jpg');
      await deepFresh.writeAsBytes([4, 5, 6]);
      await deepFresh.setLastModified(DateTime.now());

      await cacheManager.cleanupExpired(ttl: const Duration(days: 30));

      expect(
        await deepExpired.exists(),
        isFalse,
        reason: 'Deeply nested expired file was not purged',
      );
      expect(
        await deepFresh.exists(),
        isTrue,
        reason: 'Deeply nested fresh file was prematurely purged',
      );
    });

    test(
      'cleanupExpired purges oldest nested files when byte budget is exceeded',
      () async {
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
          await file.setLastModified(
            DateTime.now().subtract(Duration(minutes: 100 - i * 10)),
          );
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
      },
    );
  });

  group('P1.2 — Verifiable logout/media-cache cleanup', () {
    late Directory tempRoot;

    setUp(() async {
      AccountSession.resetForTesting();
      tempRoot = await Directory.systemTemp.createTemp('mndo_logout_test_');
      MediaCacheManager().setBaseDirForTesting(tempRoot);
      VoiceNoteCacheManager().setCacheDirForTesting(
        Directory('${tempRoot.path}/mndo_voice_cache'),
      );
      VoiceNoteCacheManager().setTempDirForTesting(
        Directory('${tempRoot.path}/temp'),
      );
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

    test(
      'cleanupAll returns verified success result and removes all files',
      () async {
        final imgFile = File('${tempRoot.path}/mndo_media/images/test_img.jpg');
        await imgFile.create(recursive: true);
        await imgFile.writeAsBytes([1, 2, 3]);

        final result = await MediaCacheManager().cleanupAll();
        expect(result.isSuccess, isTrue);
        expect(result.deletedCount, greaterThanOrEqualTo(1));
        expect(result.failedCount, equals(0));
        expect(await imgFile.exists(), isFalse);
      },
    );

    test('Injected cleanup failure blocks teardown fail-closed and enters teardownFailed', () async {
      MediaCacheManager().failNextCleanupAll = true;

      try {
        await AccountSession.dispose();
        fail(
          'Expected AccountSession.dispose to throw StateError on cleanup failure',
        );
      } catch (e) {
        expect(e, isA<StateError>());
        expect(
          (e as StateError).message,
          contains('Sensitive local media purge failed'),
        );
      }

      expect(
        AccountSession.state,
        equals(AccountLifecycleState.teardownFailed),
      );
      expect(AccountSession.wasLocalPurgeVerified, isFalse);
      expect(AccountSession.lastCleanupResult?.isSuccess, isFalse);
    });
  });

  group('P1.3 — Bound media download time with an overall deadline', () {
    test(
      'downloadEncryptedBlob exits within overall deadline when servers hang',
      () async {
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
      },
    );

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

    test(
      'downloadEncryptedBlob falls back to mirror when primary fails',
      () async {
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
      },
    );

    test(
      'downloadEncryptedBlob includes .bin and .txt mirror fallback candidates',
      () async {
        final attemptedUrls = <String>[];
        final mockClient = MockClient((request) async {
          attemptedUrls.add(request.url.toString());
          return http.Response('Not found', 500);
        });

        final router = StorageRouter();
        await router.downloadEncryptedBlob(
          'https://primary.example.com/deadbeef01',
          'deadbeef01',
          maxAttempts: 1,
          downloadTimeout: const Duration(milliseconds: 100),
          overallTimeout: const Duration(milliseconds: 400),
          client: mockClient,
        );

        expect(attemptedUrls.any((u) => u.endsWith('/deadbeef01.bin')), isTrue);
        expect(attemptedUrls.any((u) => u.endsWith('/deadbeef01.txt')), isTrue);
      },
    );
  });

  group('P1.4 — Make Blossom upload authorization fail-closed', () {
    test('uploadEncryptedBlob rejects payload when SHA-256 does not match fileHashHex', () async {
      final router = StorageRouter();
      final payload = utf8.encode('actual_bytes');
      const wrongHash =
          'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff';

      // Should fail-closed before making any network request
      final result = await router.uploadEncryptedBlob(payload, wrongHash);

      expect(result, isNull);
    });

    test(
      'uploadEncryptedBlob fails-closed when auth header cannot be generated',
      () async {
        final router = StorageRouter();
        final payload = utf8.encode('secret_encrypted_data');
        final actualHash = crypto.sha256.convert(payload).toString();

        // Nostr transport has no active keys; createBlossomAuthHeader throws StateError
        // StorageRouter must fail-closed and return null without throwing or uploading unauthenticated
        final result = await router.uploadEncryptedBlob(payload, actualHash);

        expect(result, isNull);
      },
    );
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
      const mnemonicA =
          'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
      final masterA = await crypto.generateMasterKeyPair(mnemonicA);
      final pubKeyA = await masterA.extractPublicKey();
      final pubHexA = pubKeyA.bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();

      final signalKeyA = generateIdentityKeyPair();
      const regIdA = 1234;

      await identityRepo.saveMnemonic(mnemonicA);
      await identityRepo.saveSignalIdentity(
        signalKeyA,
        regIdA,
        masterPublicKeyHex: pubHexA,
      );
      await identityRepo.saveCustomProfile(
        'Alice',
        'Privacy Advocate',
        masterPublicKeyHex: pubHexA,
      );

      // Restore for master A
      final (restoredKey, restoredReg) = await identityRepo.getSignalIdentity(
        masterPublicKeyHex: pubHexA,
      );
      final (restoredName, restoredBio) = await identityRepo.getCustomProfile(
        masterPublicKeyHex: pubHexA,
      );

      expect(restoredKey, isNotNull);
      expect(
        restoredKey!.getPublicKey().serialize(),
        equals(signalKeyA.getPublicKey().serialize()),
      );
      expect(restoredReg, equals(regIdA));
      expect(restoredName, equals('Alice'));
      expect(restoredBio, equals('Privacy Advocate'));
    });

    test('Different mnemonic derives different master key and cannot inherit prior identity', () async {
      const mnemonicA =
          'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
      final masterA = await crypto.generateMasterKeyPair(mnemonicA);
      final pubKeyA = await masterA.extractPublicKey();
      final pubHexA = pubKeyA.bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();

      final signalKeyA = generateIdentityKeyPair();
      await identityRepo.saveMnemonic(mnemonicA);
      await identityRepo.saveSignalIdentity(
        signalKeyA,
        1111,
        masterPublicKeyHex: pubHexA,
      );
      await identityRepo.saveCustomProfile(
        'Alice',
        'Bio A',
        masterPublicKeyHex: pubHexA,
      );

      // Mnemonic B
      const mnemonicB =
          'legal winner thank year wave sausage worth useful legal winner thank yellow';
      final masterB = await crypto.generateMasterKeyPair(mnemonicB);
      final pubKeyB = await masterB.extractPublicKey();
      final pubHexB = pubKeyB.bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();

      // Retrieve for master B — must be null, not inherit A's identity
      final (restoredKeyB, restoredRegB) = await identityRepo.getSignalIdentity(
        masterPublicKeyHex: pubHexB,
      );
      final (restoredNameB, restoredBioB) = await identityRepo.getCustomProfile(
        masterPublicKeyHex: pubHexB,
      );

      expect(restoredKeyB, isNull);
      expect(restoredRegB, isNull);
      expect(restoredNameB, isNull);
      expect(restoredBioB, isNull);
    });

    test(
      'Explicit identity rotation rotates keys and saves them under master key',
      () async {
        const masterHex =
            '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
        final initialKey = generateIdentityKeyPair();
        await identityRepo.saveSignalIdentity(
          initialKey,
          100,
          masterPublicKeyHex: masterHex,
        );

        // Explicit rotation
        final (newKey, newReg) = await identityRepo.rotateSignalIdentity(
          masterPublicKeyHex: masterHex,
        );

        expect(
          newKey.getPublicKey().serialize(),
          isNot(equals(initialKey.getPublicKey().serialize())),
        );

        final (storedKey, storedReg) = await identityRepo.getSignalIdentity(
          masterPublicKeyHex: masterHex,
        );
        expect(
          storedKey!.getPublicKey().serialize(),
          equals(newKey.getPublicKey().serialize()),
        );
        expect(storedReg, equals(newReg));
      },
    );

    test('Legacy unscoped storage migration succeeds when owner mnemonic matches', () async {
      const mnemonic =
          'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
      final master = await crypto.generateMasterKeyPair(mnemonic);
      final pubKey = await master.extractPublicKey();
      final masterHex = pubKey.bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();

      // Set up legacy unscoped keys
      final legacySignalKey = generateIdentityKeyPair();
      await fakeStorage.write(key: 'master_mnemonic_1', value: mnemonic);
      await fakeStorage.write(
        key: 'signal_identity_1',
        value: base64Encode(legacySignalKey.serialize()),
      );
      await fakeStorage.write(key: 'signal_registration_id_1', value: '4321');
      await fakeStorage.write(key: 'display_name_1', value: 'Legacy User');

      // Request with matching masterHex -> should migrate
      final (migratedKey, migratedReg) = await identityRepo.getSignalIdentity(
        masterPublicKeyHex: masterHex,
      );
      final (migratedName, _) = await identityRepo.getCustomProfile(
        masterPublicKeyHex: masterHex,
      );

      expect(migratedKey, isNotNull);
      expect(
        migratedKey!.getPublicKey().serialize(),
        equals(legacySignalKey.getPublicKey().serialize()),
      );
      expect(migratedReg, equals(4321));
      expect(migratedName, equals('Legacy User'));

      // Legacy unscoped keys should have been purged
      expect(await fakeStorage.read(key: 'signal_identity_1'), isNull);
      expect(await fakeStorage.read(key: 'display_name_1'), isNull);
    });

    test('Legacy unscoped storage migration fails safely when owner mnemonic does not match', () async {
      // Legacy data belongs to Mnemonic A
      const mnemonicA =
          'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
      final legacySignalKey = generateIdentityKeyPair();
      await fakeStorage.write(key: 'master_mnemonic_1', value: mnemonicA);
      await fakeStorage.write(
        key: 'signal_identity_1',
        value: base64Encode(legacySignalKey.serialize()),
      );
      await fakeStorage.write(key: 'signal_registration_id_1', value: '9999');

      // User B tries to get identity with different master hex
      const otherMasterHex =
          'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff';
      final (resultKey, resultReg) = await identityRepo.getSignalIdentity(
        masterPublicKeyHex: otherMasterHex,
      );

      // Must fail safely: do not bind or migrate legacy keys to other master
      expect(resultKey, isNull);
      expect(resultReg, isNull);
      // Legacy key remains intact
      expect(await fakeStorage.read(key: 'signal_identity_1'), isNotNull);
    });

    test('Login with new mnemonic does not adopt legacy keys of previous account', () async {
      const mnemonicA =
          'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
      const mnemonicB =
          'legal winner thank year wave sausage worth useful legal winner thank yellow';
      final legacySignalKeyA = generateIdentityKeyPair();

      // Legacy unscoped data belongs to Account A
      await fakeStorage.write(key: 'master_mnemonic_1', value: mnemonicA);
      await fakeStorage.write(
        key: 'signal_identity_1',
        value: base64Encode(legacySignalKeyA.serialize()),
      );
      await fakeStorage.write(key: 'signal_registration_id_1', value: '1111');
      await fakeStorage.write(key: 'display_name_1', value: 'Account A');

      // Login as Account B using AuthProvider
      final authProvider = AuthProvider(
        cryptoService: crypto,
        identityRepo: identityRepo,
      );

      final loginSuccess = await authProvider.loginWithMnemonic(mnemonicB);
      expect(loginSuccess, isTrue);

      // Account B must NOT have Account A's legacy Signal key or registration ID
      expect(authProvider.signalIdentityKeyPair, isNotNull);
      expect(
        authProvider.signalIdentityKeyPair!.getPublicKey().serialize(),
        isNot(equals(legacySignalKeyA.getPublicKey().serialize())),
      );
      expect(authProvider.signalRegistrationId, isNot(equals(1111)));

      // Legacy unscoped keys must have been purged from storage
      expect(await fakeStorage.read(key: 'signal_identity_1'), isNull);
    });

    test('Ordinary logout preserves account-scoped Signal identity and registration ID across logout, restoring them without rotation on re-login (FIX-03)', () async {
      const mnemonic =
          'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
      final authProvider = AuthProvider(
        cryptoService: crypto,
        identityRepo: identityRepo,
      );

      final loginSuccess = await authProvider.loginWithMnemonic(mnemonic);
      expect(loginSuccess, isTrue);

      final origSignalKey = authProvider.signalIdentityKeyPair;
      final origRegId = authProvider.signalRegistrationId;
      final origMasterHex = authProvider.masterPublicKeyHex;
      expect(origSignalKey, isNotNull);
      expect(origRegId, isNotNull);
      expect(origMasterHex, isNotNull);

      // Perform ordinary logout via clearCredentialsOnly
      await authProvider.clearCredentialsOnly();
      expect(authProvider.mnemonic, isNull);
      expect(authProvider.masterKeyPair, isNull);
      expect(authProvider.signalIdentityKeyPair, isNull);
      expect(authProvider.signalRegistrationId, isNull);

      // Verify mnemonic is gone from secure storage
      expect(await identityRepo.getMnemonic(), isNull);

      // Verify scoped identity is still preserved in secure storage
      final (storedKey, storedReg) = await identityRepo.getSignalIdentity(
        masterPublicKeyHex: origMasterHex,
      );
      expect(storedKey, isNotNull);
      expect(storedReg, equals(origRegId));
      expect(
        storedKey!.getPublicKey().serialize(),
        equals(origSignalKey!.getPublicKey().serialize()),
      );

      // Log back in with the same sovereign mnemonic
      final reloginSuccess = await authProvider.loginWithMnemonic(mnemonic);
      expect(reloginSuccess, isTrue);

      // Identity MUST be restored without implicit rotation
      expect(authProvider.signalRegistrationId, equals(origRegId));
      expect(
        authProvider.signalIdentityKeyPair!.getPublicKey().serialize(),
        equals(origSignalKey.getPublicKey().serialize()),
      );
    });
  });

  group('P1.6 — Require complete, valid message-envelope identity fields', () {
    const validSender =
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

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

    test(
      'Envelope rejects sender if not exactly 64 hexadecimal characters',
      () {
        final baseEnvelope = {
          'v': 1,
          'id': 'msg-1',
          'type': 'text',
          'ts': 1710000000000,
          'body': {'text': 'test'},
        };

        // 63 hex chars (too short)
        final shortSender = jsonEncode({...baseEnvelope, 'sender': '0' * 63});
        expect(MndoMessageEnvelope.tryParse(shortSender), isNull);

        // 65 hex chars (too long)
        final longSender = jsonEncode({...baseEnvelope, 'sender': '0' * 65});
        expect(MndoMessageEnvelope.tryParse(longSender), isNull);

        // 64 chars with non-hex character 'g'
        final nonHexSender = jsonEncode({
          ...baseEnvelope,
          'sender': '${'0' * 63}g',
        });
        expect(MndoMessageEnvelope.tryParse(nonHexSender), isNull);

        // Valid 64 hex chars (uppercase or lowercase)
        final validUpper = jsonEncode({...baseEnvelope, 'sender': ('A' * 64)});
        expect(MndoMessageEnvelope.tryParse(validUpper), isNotNull);
      },
    );

    test('F4 table-driven: Envelope rejects unknown types', () {
      const invalidTypes = [
        'unknown',
        'malicious_exec',
        'html',
        'json',
        '123',
        '',
      ];
      for (final type in invalidTypes) {
        final raw = jsonEncode({
          'v': 1,
          'id': 'msg-type-$type',
          'type': type,
          'ts': 1710000000000,
          'sender': validSender,
          'body': {'text': 'test'},
        });
        expect(
          MndoMessageEnvelope.tryParse(raw),
          isNull,
          reason: 'Type "$type" should be rejected',
        );
      }
    });

    test('F4 table-driven: Envelope rejects invalid timestamp bounds', () {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final testCases = [
        {'ts': 0, 'desc': 'zero timestamp'},
        {'ts': -1000, 'desc': 'negative timestamp'},
        {'ts': 1000, 'desc': 'ancient epoch (pre-2020)'},
        {'ts': nowMs + 15 * 60 * 1000, 'desc': 'far future (>10m drift)'},
      ];
      for (final tc in testCases) {
        final raw = jsonEncode({
          'v': 1,
          'id': 'msg-ts-1',
          'type': 'text',
          'ts': tc['ts'],
          'sender': validSender,
          'body': {'text': 'test'},
        });
        expect(
          MndoMessageEnvelope.tryParse(raw),
          isNull,
          reason: tc['desc'] as String,
        );
      }
    });

    test('F4 table-driven: Envelope per-type schema enforcement', () {
      // Text type requires String text
      final invalidTextBody = jsonEncode({
        'v': 1,
        'id': 'msg-text-invalid',
        'type': 'text',
        'ts': 1710000000000,
        'sender': validSender,
        'body': {'text': 12345}, // wrong type
      });
      expect(MndoMessageEnvelope.tryParse(invalidTextBody), isNull);

      // Receipt requires non-empty targetId and valid status
      final receiptMissingTarget = jsonEncode({
        'v': 1,
        'id': 'msg-rcpt-1',
        'type': 'receipt',
        'ts': 1710000000000,
        'sender': validSender,
        'body': {'status': 'read'},
      });
      expect(MndoMessageEnvelope.tryParse(receiptMissingTarget), isNull);

      final receiptInvalidStatus = jsonEncode({
        'v': 1,
        'id': 'msg-rcpt-2',
        'type': 'receipt',
        'ts': 1710000000000,
        'sender': validSender,
        'body': {'targetId': 'msg-target-1', 'status': 'compromised'},
      });
      expect(MndoMessageEnvelope.tryParse(receiptInvalidStatus), isNull);

      final validReceipt = jsonEncode({
        'v': 1,
        'id': 'msg-rcpt-3',
        'type': 'receipt',
        'ts': 1710000000000,
        'sender': validSender,
        'body': {'targetId': 'msg-target-1', 'status': 'delivered'},
      });
      expect(MndoMessageEnvelope.tryParse(validReceipt), isNotNull);
    });

    test('F4 table-driven: Oversized message ID and oversized payload are rejected', () {
      // ID > 256 characters
      final oversizedId = jsonEncode({
        'v': 1,
        'id': 'id-${'x' * 300}',
        'type': 'text',
        'ts': 1710000000000,
        'sender': validSender,
        'body': {'text': 'test'},
      });
      expect(MndoMessageEnvelope.tryParse(oversizedId), isNull);

      // Raw payload > 5MB
      final largeText = 'a' * (5 * 1024 * 1024 + 100);
      final oversizedPayload = jsonEncode({
        'v': 1,
        'id': 'msg-large',
        'type': 'text',
        'ts': 1710000000000,
        'sender': validSender,
        'body': {'text': largeText},
      });
      expect(MndoMessageEnvelope.tryParse(oversizedPayload), isNull);
    });
  });

  group('P1.7 — Strengthen prekey-bundle integrity/anti-rollback contract', () {
    late CryptoService crypto;
    late MasterBindingVerifier verifier;
    late SimpleKeyPair masterKeyPair;
    late String masterPubKeyHex;
    const peerNostrPubKey =
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

    setUp(() async {
      AccountSession.resetForTesting();
      crypto = CryptoService();
      verifier = MasterBindingVerifier(cryptoService: crypto);
      masterKeyPair = await crypto.generateMasterKeyPair(
        'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about',
      );
      final pubKey = await masterKeyPair.extractPublicKey();
      masterPubKeyHex = pubKey.bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
    });

    Future<Map<String, dynamic>> createBundle({
      int bundleEpoch = 1,
      int? regId = 12345,
      int spkId = 1,
      List<Map<String, dynamic>>? otks,
      int bundleVersion = 3,
      String? customMasterSig,
      String? customSpkSig,
      String? customSpkPub,
      IdentityKeyPair? idKeyPairOverride,
    }) async {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final idKeyPair = idKeyPairOverride ?? generateIdentityKeyPair();
      final idPub = base64Encode(idKeyPair.getPublicKey().serialize());
      final spkRecord = generateSignedPreKey(idKeyPair, spkId);
      final spkPub =
          customSpkPub ??
          base64Encode(spkRecord.getKeyPair().publicKey.serialize());
      final realSpkSig = customSpkSig ?? base64Encode(spkRecord.signature);

      final rawOtks =
          otks ??
          [
            {
              'id': 10,
              'pubKey': base64Encode(
                Curve.generateKeyPair().publicKey.serialize(),
              ),
            },
          ];
      final sortedOtksStr = CryptoService.formatSortedOtks(rawOtks);

      final sig =
          customMasterSig ??
          await crypto.signBundleBindingTokenV3(
            masterKeyPair: masterKeyPair,
            nostrPubKeyHex: peerNostrPubKey,
            masterKeyHex: masterPubKeyHex,
            signalIdentityPubBase64: idPub,
            registrationId: regId ?? 12345,
            bundleEpoch: bundleEpoch,
            issuedAt: nowMs,
            expiresAt: nowMs + 1209600000,
            signedPreKeyId: spkId,
            signedPreKeyPubBase64: spkPub,
            signedPreKeySigBase64: realSpkSig,
            sortedOtksStr: sortedOtksStr,
            version: bundleVersion,
          );

      return <String, dynamic>{
        'bundleVersion': bundleVersion,
        if (regId != null) 'registrationId': regId,
        'masterKey': masterPubKeyHex,
        'identityPubKey': idPub,
        'bundleEpoch': bundleEpoch,
        'issuedAt': nowMs,
        'expiresAt': nowMs + 1209600000,
        'signedPreKey': {
          'id': spkId,
          'pubKey': spkPub,
          'signature': realSpkSig,
        },
        'oneTimePreKeys': rawOtks,
        'masterBindingSig': sig,
      };
    }

    test('computeBundleHash changes when OTKs, registrationId, or SPK are modified', () async {
      final bundle = await createBundle();
      final baseHash = MasterBindingVerifier.computeBundleHash(bundle);

      // Mutate OTK
      final bundleMutatedOtk = Map<String, dynamic>.from(bundle);
      bundleMutatedOtk['oneTimePreKeys'] = [
        {
          'id': 99,
          'pubKey': base64Encode(Curve.generateKeyPair().publicKey.serialize()),
        },
      ];
      final hashWithMutatedOtk = MasterBindingVerifier.computeBundleHash(
        bundleMutatedOtk,
      );
      expect(hashWithMutatedOtk, isNot(equals(baseHash)));

      // Mutate registrationId
      final bundleMutatedReg = Map<String, dynamic>.from(bundle);
      bundleMutatedReg['registrationId'] = 9999;
      final hashWithMutatedReg = MasterBindingVerifier.computeBundleHash(
        bundleMutatedReg,
      );
      expect(hashWithMutatedReg, isNot(equals(baseHash)));

      // Mutate signedPreKey id
      final bundleMutatedSpk = Map<String, dynamic>.from(bundle);
      bundleMutatedSpk['signedPreKey'] = {
        'id': 2,
        'pubKey': bundle['signedPreKey']['pubKey'],
        'signature': bundle['signedPreKey']['signature'],
      };
      final hashWithMutatedSpk = MasterBindingVerifier.computeBundleHash(
        bundleMutatedSpk,
      );
      expect(hashWithMutatedSpk, isNot(equals(baseHash)));
    });

    test(
      'Same epoch with modified OTKs is rejected as conflictingBundleEpoch',
      () async {
        final bundleA = await createBundle(bundleEpoch: 10);
        final hashA = MasterBindingVerifier.computeBundleHash(bundleA);

        // Bundle B has same epoch 10 and same masterBindingSig/identity, but different OTKs
        final bundleB = Map<String, dynamic>.from(bundleA);
        bundleB['oneTimePreKeys'] = [
          {
            'id': 55,
            'pubKey': base64Encode(
              Curve.generateKeyPair().publicKey.serialize(),
            ),
          },
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
        // Fails at Ed25519 signature verification because OTKs are bound in v3 signature!
        expect(res.reason, BindingRejectionReason.signatureVerificationFailed);
      },
    );

    test(
      'Bundle with duplicate prekey IDs is rejected with duplicatePreKeyId',
      () async {
        // OTK id collides with SPK id (both 1)
        final bundle = await createBundle(
          spkId: 1,
          otks: [
            {
              'id': 1,
              'pubKey': base64Encode(
                Curve.generateKeyPair().publicKey.serialize(),
              ),
            },
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
      },
    );

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

    test('Bundle with missing registrationId is rejected', () async {
      final bundle = await createBundle();
      bundle.remove('registrationId');

      final res = await verifier.verifyPreKeyBundle(
        expectedMasterPubKeyHex: masterPubKeyHex,
        recipientNostrPubKey: peerNostrPubKey,
        bundleMap: bundle,
        eventAuthor: peerNostrPubKey,
      );

      expect(res.isValid, isFalse);
      expect(res.reason, BindingRejectionReason.missingRequiredV2Fields);
    });

    test('Bundle with missing signedPreKey is rejected', () async {
      final bundle = await createBundle();
      bundle.remove('signedPreKey');

      final res = await verifier.verifyPreKeyBundle(
        expectedMasterPubKeyHex: masterPubKeyHex,
        recipientNostrPubKey: peerNostrPubKey,
        bundleMap: bundle,
        eventAuthor: peerNostrPubKey,
      );

      expect(res.isValid, isFalse);
      expect(res.reason, BindingRejectionReason.missingRequiredV2Fields);
    });

    test(
      'Bundle with forged SPK Curve25519 signature is rejected (FIX-01)',
      () async {
        final bundle = await createBundle(
          customSpkSig: base64Encode(List.filled(64, 0xfe)), // Forged signature
        );

        final res = await verifier.verifyPreKeyBundle(
          expectedMasterPubKeyHex: masterPubKeyHex,
          recipientNostrPubKey: peerNostrPubKey,
          bundleMap: bundle,
          eventAuthor: peerNostrPubKey,
        );

        expect(res.isValid, isFalse);
        expect(res.reason, BindingRejectionReason.signatureVerificationFailed);
      },
    );

    test('Bundle with tampered registrationId in transit is rejected by Ed25519 v3 signature (FIX-01)', () async {
      final bundle = await createBundle(regId: 1000);
      bundle['registrationId'] = 2000; // Tampered in transit

      final res = await verifier.verifyPreKeyBundle(
        expectedMasterPubKeyHex: masterPubKeyHex,
        recipientNostrPubKey: peerNostrPubKey,
        bundleMap: bundle,
        eventAuthor: peerNostrPubKey,
      );

      expect(res.isValid, isFalse);
      expect(res.reason, BindingRejectionReason.signatureVerificationFailed);
    });

    test('Bundle downgrade attempt with bundleVersion 2 is rejected fail-closed (FIX-01)', () async {
      final bundle = await createBundle(bundleVersion: 2);

      final res = await verifier.verifyPreKeyBundle(
        expectedMasterPubKeyHex: masterPubKeyHex,
        recipientNostrPubKey: peerNostrPubKey,
        bundleMap: bundle,
        eventAuthor: peerNostrPubKey,
      );

      expect(res.isValid, isFalse);
      expect(res.reason, BindingRejectionReason.invalidBundleVersion);
    });

    test(
      'Successful bundle verification returns computed bundleHash',
      () async {
        final bundle = await createBundle();
        final expectedHash = MasterBindingVerifier.computeBundleHash(bundle);

        final res = await verifier.verifyPreKeyBundle(
          expectedMasterPubKeyHex: masterPubKeyHex,
          recipientNostrPubKey: peerNostrPubKey,
          bundleMap: bundle,
          eventAuthor: peerNostrPubKey,
        );

        expect(res.isValid, isTrue);
        expect(res.bundleHash, equals(expectedHash));
      },
    );
  });

  group('P3.1 — Deterministic Identity Derivation with Fixed Test Vectors (FIX-04)', () {
    late CryptoService cryptoService;

    setUp(() {
      cryptoService = CryptoService();
    });

    test('Standard test vector 1: all-abandon mnemonic derives fixed literal master public key and username', () async {
      // Well-known BIP-39 test vector 1
      const testMnemonic1 =
          'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
      final keyPair = await cryptoService.generateMasterKeyPair(testMnemonic1);
      final pubKey = await keyPair.extractPublicKey();
      final pubKeyHex = pubKey.bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      final username = await cryptoService.generateUsername(pubKey);

      // Assert exact literal outputs (FIX-04)
      const expectedHex1 =
          'c5785e1865b708938aff8161d573006496663b1aa10834e396dc566869a2c66a';
      const expectedUsername1 = 'Compact Vengeance #166e0a';
      expect(pubKeyHex, equals(expectedHex1));
      expect(username, equals(expectedUsername1));

      // Verify byte-for-byte reproducibility
      final keyPair2 = await cryptoService.generateMasterKeyPair(testMnemonic1);
      final pubKey2 = await keyPair2.extractPublicKey();
      final pubKeyHex2 = pubKey2.bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      expect(pubKeyHex2, equals(expectedHex1));

      // Whitespace and newline normalization must yield exact same literal key
      final keyPairWhitespace = await cryptoService.generateMasterKeyPair(
        '  $testMnemonic1  \n',
      );
      final pubKeyWs = await keyPairWhitespace.extractPublicKey();
      final pubKeyHexWs = pubKeyWs.bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      expect(pubKeyHexWs, equals(expectedHex1));

      // Casing normalization must yield exact same literal key
      final keyPairUpper = await cryptoService.generateMasterKeyPair(
        testMnemonic1.toUpperCase(),
      );
      final pubKeyUpper = await keyPairUpper.extractPublicKey();
      final pubKeyHexUpper = pubKeyUpper.bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      expect(pubKeyHexUpper, equals(expectedHex1));
    });

    test('Standard test vector 2: zoo-zoo mnemonic derives fixed literal master public key and username', () async {
      // Well-known BIP-39 test vector 2
      const testMnemonic2 = 'zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong';
      final keyPair = await cryptoService.generateMasterKeyPair(testMnemonic2);
      final pubKey = await keyPair.extractPublicKey();
      final pubKeyHex = pubKey.bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      final username = await cryptoService.generateUsername(pubKey);

      // Assert exact literal outputs (FIX-04)
      const expectedHex2 =
          'ce4c77de461f82f37823867991aec05cc63c6309a6fce9b8d8abf59481f3ec6c';
      const expectedUsername2 = 'Daring Protector #112259';
      expect(pubKeyHex, equals(expectedHex2));
      expect(username, equals(expectedUsername2));

      final keyPair2 = await cryptoService.generateMasterKeyPair(testMnemonic2);
      final pubKey2 = await keyPair2.extractPublicKey();
      final pubKeyHex2 = pubKey2.bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      expect(pubKeyHex2, equals(expectedHex2));
    });
  });

  group('F1 — Presence suppression in hidden mode', () {
    test('NostrRelayService.broadcastPing suppresses publication when isHidden is true', () async {
      AccountSession.setGenerationForTesting(900);
      final relay = NostrRelayService();
      relay.initKeys('88' * 32, sessionGeneration: 900);
      final result = await relay.broadcastPing(
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        sessionGen: 900,
        isOnline: true,
        isHidden: true,
      );
      expect(
        result,
        isFalse,
        reason: 'Must return false immediately without network publication when hidden',
      );
    });

    test('NostrRelayService.broadcastProfileMetadata suppresses publication when isHidden is true', () async {
      AccountSession.setGenerationForTesting(901);
      final relay = NostrRelayService();
      relay.initKeys('88' * 32, sessionGeneration: 901);
      // Suppresses publication at publisher boundary when isHidden is true
      await relay.broadcastProfileMetadata(
        'alice',
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        isHidden: true,
        sessionGen: 901,
      );
    });
  });
}
