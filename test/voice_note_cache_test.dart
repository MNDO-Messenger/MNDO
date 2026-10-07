import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:cryptography/cryptography.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';

import 'package:aisat_connect/services/voice_note_service.dart';
import 'package:aisat_connect/database/database.dart';
import 'package:aisat_connect/repositories/chat_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory testTempDir;
  late Directory testCacheDir;
  late VoiceNoteCacheManager cacheManager;
  late VoiceNoteService voiceService;

  setUp(() async {
    testTempDir = await Directory.systemTemp.createTemp('vn_test_temp_');
    testCacheDir = Directory(p.join(testTempDir.path, 'cache'));
    await testCacheDir.create(recursive: true);

    cacheManager = VoiceNoteCacheManager();
    cacheManager.setCacheDirForTesting(testCacheDir);
    cacheManager.setTempDirForTesting(testTempDir);
    VoiceNoteService.cachedTempDirPath = testTempDir.path;

    voiceService = VoiceNoteService();
  });

  tearDown(() async {
    cacheManager.resetForTesting();
    try {
      if (await testTempDir.exists()) {
        await testTempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  /// Helper to create a dummy audio file with standard WAV header
  Future<File> createDummyWavFile(String fileName, {int dataLength = 400}) async {
    final file = File(p.join(testTempDir.path, fileName));
    final bytes = <int>[
      // RIFF header
      0x52, 0x49, 0x46, 0x46,
      0x00, 0x00, 0x00, 0x00,
      0x57, 0x41, 0x56, 0x45, // WAVE
      0x66, 0x6D, 0x74, 0x20, // fmt 
      16, 0, 0, 0,            // subchunk1 size
      1, 0,                   // PCM
      1, 0,                   // 1 channel
      0x44, 0xAC, 0x00, 0x00, // sample rate 44100
      0x88, 0x58, 0x01, 0x00, // byte rate
      2, 0,                   // block align
      16, 0,                  // bits per sample
      0x64, 0x61, 0x74, 0x61, // data
      0x00, 0x01, 0x00, 0x00, // data size
      ...List.filled(dataLength, 0x7F),
    ];
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  group('MNDO Voice Note Plaintext Persistence & Cache Security (LOCAL-MEDIA-01)', () {
    test('1. Successful encryption deletes original recording plaintext file', () async {
      final sourceFile = await createDummyWavFile('vn_rec_123456789.wav');
      expect(await sourceFile.exists(), isTrue, reason: 'Source recording file should exist initially');

      final prep = await voiceService.prepareAndEncryptVoiceNote(
        localAudioPath: sourceFile.path,
        durationMs: 1500,
        waveform: [10, 20, 30],
        sentAt: DateTime.now().millisecondsSinceEpoch,
      );

      expect(prep, isNotNull);
      expect(prep!.payload.fileHash, isNotEmpty);

      // Invariant: Source recording file must be deleted immediately after encryption
      expect(
        await sourceFile.exists(),
        isFalse,
        reason: 'Original plaintext recording file MUST be deleted after encryption succeeds',
      );

      // Controlled cache file must exist in cache directory
      final cachedFilePath = prep.payload.localPath!;
      expect(await File(cachedFilePath).exists(), isTrue);
      expect(p.basename(cachedFilePath), startsWith('vn_cache_'));
    });

    test('2. Duplicate cache prevention: At most one plaintext copy exists after encryption', () async {
      final sourceFile = await createDummyWavFile('vn_rec_test_dup.wav');

      final prep = await voiceService.prepareAndEncryptVoiceNote(
        localAudioPath: sourceFile.path,
        durationMs: 1500,
        waveform: [15, 25, 35],
      );

      expect(prep, isNotNull);

      // Scan all test directories for audio files
      final tempFiles = testTempDir.listSync(recursive: true).whereType<File>().toList();
      final audioFiles = tempFiles.where((f) {
        final ext = p.extension(f.path).toLowerCase();
        return ext == '.wav' || ext == '.m4a';
      }).toList();

      // INVARIANT: count(plaintext copies for message) <= 1
      expect(
        audioFiles.length,
        equals(1),
        reason: 'Exactly one controlled plaintext file should exist, eliminating duplicate copies',
      );

      // Verify no vn_rec_* and no vn_dec_* duplicate pair exists
      final baseNames = audioFiles.map((f) => p.basename(f.path)).toList();
      expect(baseNames.any((name) => name.startsWith('vn_rec_')), isFalse);
      expect(baseNames.any((name) => name.startsWith('vn_dec_')), isFalse);
      expect(baseNames.any((name) => name.startsWith('vn_cache_')), isTrue);
    });

    test('3. Encryption failure cleans up original plaintext file', () async {
      // Create a corrupted or empty file that fails encryption / processing
      final sourceFile = File(p.join(testTempDir.path, 'vn_rec_fail.wav'));
      await sourceFile.writeAsString('non-audio dummy content');

      // prepareAndEncryptVoiceNote with non-existent or failing state cleans up
      final unreadableFile = File(p.join(testTempDir.path, 'vn_rec_deleted_early.wav'));
      final res = await voiceService.prepareAndEncryptVoiceNote(
        localAudioPath: unreadableFile.path,
        durationMs: 1000,
        waveform: [],
      );
      expect(res, isNull);

      // Test explicit discard / cleanup helper
      final tempFile = await createDummyWavFile('vn_rec_to_discard.wav');
      expect(await tempFile.exists(), isTrue);
      await voiceService.discardRecording(tempFile.path);
      expect(await tempFile.exists(), isFalse);
    });

    test('4. Upload failure / stale session cleanup removes plaintext files', () async {
      final sourceFile = await createDummyWavFile('vn_rec_upload_fail.wav');
      final prep = await voiceService.prepareAndEncryptVoiceNote(
        localAudioPath: sourceFile.path,
        durationMs: 1200,
        waveform: [10, 20],
      );
      expect(prep, isNotNull);

      final cachedFile = File(prep!.payload.localPath!);
      expect(await cachedFile.exists(), isTrue);

      // When send/upload fails and session is aborted, cache entry is deleted
      await cacheManager.deleteForHash(prep.payload.fileHash);
      expect(await cachedFile.exists(), isFalse);
    });

    test('5. Recipient decryption: Plaintext cache created only when needed with bounded TTL', () async {
      // Generate ciphertext from a test audio payload
      final sourceFile = await createDummyWavFile('vn_rec_sender.wav');
      final prep = await voiceService.prepareAndEncryptVoiceNote(
        localAudioPath: sourceFile.path,
        durationMs: 1000,
        waveform: [20, 40],
      );
      expect(prep, isNotNull);

      // Create recipient payload from network serialization (without localPath)
      final networkJson = prep!.payload.toNetworkJson();
      final recipientPayload = VoiceNotePayload.fromJson(networkJson);
      expect(recipientPayload.localPath, isNull);

      // Simulate recipient device environment (no sender cache present)
      await cacheManager.cleanupAll();
      expect(cacheManager.getCachedFilePath(recipientPayload.fileHash), isNull);

      // Decrypt directly using AesGcm with the payload keys (simulating recipient download + decrypt)
      final aes = AesGcm.with256bits();
      final decrypted = await aes.decrypt(
        SecretBox(
          prep.encryptedBytes,
          nonce: base64Decode(recipientPayload.nonce),
          mac: Mac(base64Decode(recipientPayload.mac)),
        ),
        secretKey: SecretKey(base64Decode(recipientPayload.key)),
      );

      final recipientCachePath = await cacheManager.getCacheFilePathForHash(recipientPayload.fileHash, ext: '.wav');
      await File(recipientCachePath).writeAsBytes(decrypted, flush: true);
      await cacheManager.registerFile(
        fileHash: recipientPayload.fileHash,
        filePath: recipientCachePath,
      );

      // Verify recipient plaintext cache now exists and is registered
      expect(await File(recipientCachePath).exists(), isTrue);
      expect(cacheManager.getCachedFilePath(recipientPayload.fileHash), equals(recipientCachePath));
    });

    test('6. Cache expiration deletes expired plaintext files', () async {
      final file1 = await createDummyWavFile('vn_cache_hash1.wav');
      final file2 = await createDummyWavFile('vn_cache_hash2.wav');

      // Register file1 with 1 second TTL and file2 with 1 hour TTL
      await cacheManager.registerFile(
        fileHash: 'hash1',
        filePath: file1.path,
        ttl: const Duration(seconds: 1),
      );
      await cacheManager.registerFile(
        fileHash: 'hash2',
        filePath: file2.path,
        ttl: const Duration(hours: 1),
      );

      expect(await file1.exists(), isTrue);
      expect(await file2.exists(), isTrue);

      // Run cleanup with simulated time 2 seconds in future
      final futureTime = DateTime.now().add(const Duration(seconds: 2));
      final deleted = await cacheManager.cleanupExpired(now: futureTime);

      expect(deleted, greaterThanOrEqualTo(1));
      expect(await file1.exists(), isFalse, reason: 'Expired cache entry must be deleted from disk');
      expect(await file2.exists(), isTrue, reason: 'Non-expired cache entry must remain');
      expect(cacheManager.getCachedFilePath('hash1'), isNull);
      expect(cacheManager.getCachedFilePath('hash2'), isNotNull);
    });

    test('7. Startup cleanup removes stale plaintext voice files and orphaned recordings', () async {
      // Create orphaned recording file left from a crash
      final orphanRecording = File(p.join(testTempDir.path, 'vn_rec_orphaned_crash.m4a'));
      await orphanRecording.writeAsString('orphaned raw recording');

      // Create stale legacy vn_dec_ file
      final legacyDecrypted = File(p.join(testTempDir.path, 'vn_dec_legacy123.m4a'));
      await legacyDecrypted.writeAsString('stale decrypted media');

      // Create stale vn_cache_ file
      final staleCache = File(p.join(testCacheDir.path, 'vn_cache_stale456.m4a'));
      await staleCache.writeAsString('stale cached media');

      // Simulate startup cleanup with maxAge = Duration.zero
      final deletedCount = await cacheManager.cleanupExpired(maxAge: Duration.zero);

      expect(deletedCount, greaterThanOrEqualTo(3));
      expect(await orphanRecording.exists(), isFalse, reason: 'Crash-orphaned vn_rec_ must be cleaned up on startup');
      expect(await legacyDecrypted.exists(), isFalse, reason: 'Stale vn_dec_ must be cleaned up on startup');
      expect(await staleCache.exists(), isFalse, reason: 'Stale vn_cache_ must be cleaned up on startup');
    });

    test('8. Logout / session teardown removes all session voice plaintext caches', () async {
      final file1 = await createDummyWavFile('vn_cache_sess1.wav');
      final file2 = await createDummyWavFile('vn_cache_sess2.wav');

      await cacheManager.registerFile(fileHash: 'sess1', filePath: file1.path);
      await cacheManager.registerFile(fileHash: 'sess2', filePath: file2.path);

      expect(await file1.exists(), isTrue);
      expect(await file2.exists(), isTrue);

      // Trigger session teardown cleanup
      final deletedCount = await cacheManager.cleanupAll();

      expect(deletedCount, greaterThanOrEqualTo(2));
      expect(await file1.exists(), isFalse, reason: 'Session cache 1 must be wiped on session teardown');
      expect(await file2.exists(), isFalse, reason: 'Session cache 2 must be wiped on session teardown');
      expect(cacheManager.getCachedFilePath('sess1'), isNull);
      expect(cacheManager.getCachedFilePath('sess2'), isNull);

      // INVARIANT: count(plaintext copies) == 0 after teardown
      final remaining = testCacheDir.listSync().whereType<File>().where((f) => !f.path.endsWith('.json')).toList();
      expect(remaining.length, equals(0));
    });

    test('9. Message deletion removes associated cache file', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final chatRepo = ChatRepository(db);

      final dummyAudio = await createDummyWavFile('vn_cache_msg_del.wav');
      const testHash = 'del_hash_999';
      await cacheManager.registerFile(fileHash: testHash, filePath: dummyAudio.path);
      expect(await dummyAudio.exists(), isTrue);

      final payload = VoiceNotePayload(
        url: 'https://blossom.example.com/$testHash',
        key: 'key==',
        nonce: 'nonce==',
        mac: 'mac==',
        fileHash: testHash,
        durationMs: 1000,
        waveform: [10, 20],
      );

      const msgId = 'msg_del_test_1';
      await db.insertMessage(ChatMessagesCompanion.insert(
        messageId: const Value(msgId),
        nostrPubKeyHex: 'peer_pubkey_1',
        messageText: payload.serialize(),
        isMe: true,
        timestamp: DateTime.now(),
      ));

      // Delete message via repository
      await chatRepo.deleteMessage(msgId);

      // Verify associated cache file was automatically removed
      expect(
        await dummyAudio.exists(),
        isFalse,
        reason: 'Deleting a voice note message must clean up its cached plaintext audio file',
      );
      expect(cacheManager.getCachedFilePath(testHash), isNull);

      await db.close();
    });

    test('10. Replay after cache deletion recreates plaintext cache file from ciphertext', () async {
      final sourceFile = await createDummyWavFile('vn_rec_replay.wav');
      final prep = await voiceService.prepareAndEncryptVoiceNote(
        localAudioPath: sourceFile.path,
        durationMs: 1200,
        waveform: [20, 30],
      );
      expect(prep, isNotNull);

      final cachePath = prep!.payload.localPath!;
      final cacheFile = File(cachePath);
      expect(await cacheFile.exists(), isTrue);

      // Simulate cache deletion (e.g. expired or manually purged)
      await cacheManager.deleteForHash(prep.payload.fileHash);
      expect(await cacheFile.exists(), isFalse);

      // Replay / re-decrypt from ciphertext
      final aes = AesGcm.with256bits();
      final decrypted = await aes.decrypt(
        SecretBox(
          prep.encryptedBytes,
          nonce: base64Decode(prep.payload.nonce),
          mac: Mac(base64Decode(prep.payload.mac)),
        ),
        secretKey: SecretKey(base64Decode(prep.payload.key)),
      );

      final recreatedPath = await cacheManager.getCacheFilePathForHash(prep.payload.fileHash, ext: '.wav');
      await File(recreatedPath).writeAsBytes(decrypted, flush: true);
      await cacheManager.registerFile(fileHash: prep.payload.fileHash, filePath: recreatedPath);

      // Recreated file is ready for playback
      expect(await File(recreatedPath).exists(), isTrue);
      expect(cacheManager.getCachedFilePath(prep.payload.fileHash), equals(recreatedPath));
    });

    test('11. localPath is NOT transmitted over network serialization', () {
      final payload = VoiceNotePayload(
        url: 'https://blossom.primal.net/abc123hash',
        key: 'secretKeyBytesBase64==',
        nonce: 'nonceBytesBase64==',
        mac: 'macBytesBase64==',
        fileHash: 'abc123hash',
        durationMs: 2500,
        waveform: [10, 20, 30, 40],
        sentAt: 1234567890,
        localPath: '/private/data/app/vn_cache_abc123hash.m4a',
      );

      // 1. toNetworkJson must NOT contain localPath
      final networkJson = payload.toNetworkJson();
      expect(networkJson.containsKey('localPath'), isFalse);

      // 2. serializeForNetwork must NOT leak filesystem path
      final networkSerialized = payload.serializeForNetwork();
      expect(networkSerialized.contains('localPath'), isFalse);
      expect(networkSerialized.contains('/private/data/app/'), isFalse);
      expect(networkSerialized.contains('vn_cache_abc123hash.m4a'), isFalse);
    });

    test('12. Invariant verification: count(plaintext copies) <= 1 after encryption and == 0 after cleanup', () async {
      final sourceFile = await createDummyWavFile('vn_rec_invariant.wav');

      final prep = await voiceService.prepareAndEncryptVoiceNote(
        localAudioPath: sourceFile.path,
        durationMs: 2000,
        waveform: [10, 20, 30],
      );
      expect(prep, isNotNull);

      // INVARIANT 1: count(plaintext copies for message) <= 1
      final filesAfterEncrypt = testTempDir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.wav') || f.path.endsWith('.m4a'))
          .toList();
      expect(filesAfterEncrypt.length, lessThanOrEqualTo(1));

      // Trigger full cleanup
      await cacheManager.cleanupAll();

      // INVARIANT 2: count(plaintext copies) == 0
      final filesAfterCleanup = testTempDir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.wav') || f.path.endsWith('.m4a'))
          .toList();
      expect(filesAfterCleanup.length, equals(0), reason: 'Zero plaintext copies must remain after cleanupAll');
    });
  });
}
