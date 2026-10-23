import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:aisat_connect/database/database.dart';
import 'package:aisat_connect/models/media_payload.dart';
import 'package:aisat_connect/services/voice_note_service.dart';
import 'package:aisat_connect/services/storage_router.dart';
import 'package:aisat_connect/services/nostr_relay_service.dart';
import 'package:aisat_connect/services/account_session.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3_raw;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('mndo_remediation_test_');
    AccountSession.startNewSession();
  });

  tearDown(() async {
    try {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    } catch (_) {}
  });

  group('BUG 1: Database Migration and Crash Recovery', () {
    test('migratePlaintextDatabaseToEncrypted preserves all data and safely replaces source', () async {
      final dbFile = File('${tempDir.path}/test_legacy.sqlite');
      final plainDb = sqlite3_raw.sqlite3.open(dbFile.path);
      plainDb.execute('CREATE TABLE messages (id TEXT PRIMARY KEY, content TEXT);');
      plainDb.execute("INSERT INTO messages VALUES ('m1', 'Hello secret world');");
      plainDb.execute("INSERT INTO messages VALUES ('m2', 'Decentralized privacy');");
      plainDb.dispose();

      expect(dbFile.existsSync(), isTrue);
      expect(isLegacyPlaintextDatabaseSync(dbFile), isTrue);

      const testKey = 'TestEncryptionKey1234567890abcdef=';
      await migratePlaintextDatabaseToEncrypted(dbFile, testKey);

      expect(dbFile.existsSync(), isTrue);
      expect(isLegacyPlaintextDatabaseSync(dbFile), isFalse);

      // Verify that destination encrypted database can be read with the key
      final encDb = sqlite3_raw.sqlite3.open(dbFile.path);
      encDb.execute("PRAGMA key = '$testKey';");
      final rows = encDb.select("SELECT * FROM messages ORDER BY id;");
      expect(rows.length, equals(2));
      expect(rows[0]['content'], equals('Hello secret world'));
      expect(rows[1]['content'], equals('Decentralized privacy'));
      encDb.dispose();

      // Ensure no leftover backup or temporary files
      final backup = File('${dbFile.path}.migration_source_backup');
      expect(backup.existsSync(), isFalse);
    });

    test('recoverInterruptedMigration restores source backup if main db missing after crash', () {
      final dbFile = File('${tempDir.path}/test_crash.sqlite');
      final backupFile = File('${dbFile.path}.migration_source_backup');

      final plainDb = sqlite3_raw.sqlite3.open(backupFile.path);
      plainDb.execute('CREATE TABLE chats (id TEXT PRIMARY KEY);');
      plainDb.execute("INSERT INTO chats VALUES ('c1');");
      plainDb.dispose();

      expect(dbFile.existsSync(), isFalse);
      expect(backupFile.existsSync(), isTrue);

      recoverInterruptedMigration(dbFile, 'some_key');

      expect(dbFile.existsSync(), isTrue);
      expect(backupFile.existsSync(), isFalse);

      final recoveredDb = sqlite3_raw.sqlite3.open(dbFile.path);
      final rows = recoveredDb.select('SELECT count(*) as c FROM chats;');
      expect(rows.first['c'], equals(1));
      recoveredDb.dispose();
    });

    test('recoverInterruptedMigration promotes valid staged encrypted file if main db missing', () {
      final dbFile = File('${tempDir.path}/test_staged_crash.sqlite');
      final stagedFile = File('${dbFile.path}.migrating_123456');
      const testKey = 'StagedTestKey1234567890abcdef=';

      final encDb = sqlite3_raw.sqlite3.open(stagedFile.path);
      encDb.execute("PRAGMA key = '$testKey';");
      encDb.execute('CREATE TABLE users (id TEXT PRIMARY KEY);');
      encDb.execute("INSERT INTO users VALUES ('u1');");
      encDb.dispose();

      expect(dbFile.existsSync(), isFalse);
      expect(stagedFile.existsSync(), isTrue);

      recoverInterruptedMigration(dbFile, testKey);

      expect(dbFile.existsSync(), isTrue);
      expect(stagedFile.existsSync(), isFalse);

      final verifiedDb = sqlite3_raw.sqlite3.open(dbFile.path);
      verifiedDb.execute("PRAGMA key = '$testKey';");
      final rows = verifiedDb.select('SELECT count(*) as c FROM users;');
      expect(rows.first['c'], equals(1));
      verifiedDb.dispose();
    });
  });

  group('BUG 2: Missing or Invalid Database Key Handling', () {
    test('verifyOrRecoverEncryptedDatabase throws DatabaseCorruptOrInvalidKeyException on invalid key', () {
      final dbFile = File('${tempDir.path}/test_wrong_key.sqlite');
      const originalKey = 'CorrectKey1234567890abcdef=';
      const wrongKey = 'WrongKey9999999990abcdef=';

      final db = sqlite3_raw.sqlite3.open(dbFile.path);
      db.execute("PRAGMA key = '$originalKey';");
      db.execute('CREATE TABLE secrets (data TEXT);');
      db.execute("INSERT INTO secrets VALUES ('classified');");
      db.dispose();

      expect(
        () => verifyOrRecoverEncryptedDatabase(dbFile, wrongKey),
        throwsA(isA<DatabaseCorruptOrInvalidKeyException>()),
      );

      // Verify original file was preserved as unrecoverable backup and not silently destroyed
      final entities = tempDir.listSync();
      final hasPreserved = entities.any((e) => e.path.contains('.unrecoverable_'));
      expect(hasPreserved, isTrue);
    });
  });

  group('BUG 3: Authoritative Privacy Boundary in NostrRelayService', () {
    test('presence suppression completely blocks broadcastPing even when caller passes isHidden: false', () async {
      final relay = NostrRelayService();
      relay.setPresenceSuppressed(true);
      expect(relay.isPresenceSuppressed, isTrue);

      final sessionGen = AccountSession.currentGeneration;
      // Even if a caller erroneously passes isHidden: false
      final pingResult = await relay.broadcastPing(
        '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff',
        sessionGen: sessionGen,
        isOnline: true,
        isHidden: false,
      );

      expect(pingResult, isFalse);

      // Reset
      relay.setPresenceSuppressed(false);
      expect(relay.isPresenceSuppressed, isFalse);
    });
  });

  group('BUG 6 & BUG 7: Voice Note Upload Fallback & Artifact Retention', () {
    test('VoiceNotePayload.copyWith updates URL correctly', () {
      final payload = VoiceNotePayload(
        url: 'https://primary.blossom.net/abc',
        durationMs: 3500,
        waveform: [10, 20, 30],
        fileHash: 'deadbeef123',
      );

      final updated = payload.copyWith(url: 'https://fallback.blossom.net/abc');
      expect(updated.url, equals('https://fallback.blossom.net/abc'));
      expect(updated.durationMs, equals(3500));
      expect(updated.fileHash, equals('deadbeef123'));
    });
  });

  group('BUG 9: Untrusted Local Paths and URL SSRF Protection', () {
    test('MediaPayload.fromJson strips localPath when isFromNetwork is true', () {
      final json = {
        'type': 'media',
        'mediaType': 'image',
        'url': 'https://blossom.mndo.chat/hash123',
        'fileHash': 'hash123',
        'localPath': '/etc/passwd',
      };

      final payload = MediaPayload.fromJson(json, isFromNetwork: true);
      expect(payload.localPath, isNull);

      final localPayload = MediaPayload.fromJson(json, isFromNetwork: false);
      expect(localPayload.localPath, equals('/etc/passwd'));
    });

    test('MediaPayload.tryParse strips localPath when isFromNetwork is true', () {
      final jsonStr = jsonEncode({
        'type': 'media',
        'mediaType': 'document',
        'url': 'https://blossom.mndo.chat/doc1',
        'fileHash': 'hashDoc',
        'localPath': 'C:\\Windows\\System32\\secret.txt',
      });

      final parsed = MediaPayload.tryParse(jsonStr, isFromNetwork: true);
      expect(parsed, isNotNull);
      expect(parsed!.localPath, isNull);
    });

    test('VoiceNotePayload.fromJson strips localPath when isFromNetwork is true', () {
      final json = {
        'type': 'voice',
        'url': 'https://blossom.mndo.chat/voice1',
        'durationMs': 2000,
        'waveform': [1, 2],
        'fileHash': 'vnHash',
        'localPath': '/untrusted/path.m4a',
      };

      final payload = VoiceNotePayload.fromJson(json, isFromNetwork: true);
      expect(payload.localPath, isNull);
    });

    test('StorageRouter.isValidStorageUrl enforces HTTPS and rejects SSRF destinations', () {
      // Valid HTTPS URLs
      expect(StorageRouter.isValidStorageUrl('https://blossom.primal.net/blob1'), isTrue);
      expect(StorageRouter.isValidStorageUrl('https://cdn.mndo.chat/file.bin'), isTrue);

      // Non-HTTPS schemes rejected
      expect(StorageRouter.isValidStorageUrl('http://blossom.primal.net/blob1'), isFalse);
      expect(StorageRouter.isValidStorageUrl('file:///etc/passwd'), isFalse);
      expect(StorageRouter.isValidStorageUrl('javascript:alert(1)'), isFalse);
      expect(StorageRouter.isValidStorageUrl('ftp://example.com/file'), isFalse);

      // Loopback rejected
      expect(StorageRouter.isValidStorageUrl('https://localhost/admin'), isFalse);
      expect(StorageRouter.isValidStorageUrl('https://127.0.0.1:8080/metrics'), isFalse);
      expect(StorageRouter.isValidStorageUrl('https://127.0.1.1/secret'), isFalse);

      // Private RFC 1918 IPv4 ranges rejected
      expect(StorageRouter.isValidStorageUrl('https://10.0.0.1/status'), isFalse);
      expect(StorageRouter.isValidStorageUrl('https://192.168.1.1/router'), isFalse);
      expect(StorageRouter.isValidStorageUrl('https://172.16.0.5/api'), isFalse);
      expect(StorageRouter.isValidStorageUrl('https://172.31.255.255/api'), isFalse);

      // Link-local RFC 3927 rejected
      expect(StorageRouter.isValidStorageUrl('https://169.254.169.254/latest/meta-data/'), isFalse);

      // Malformed or empty
      expect(StorageRouter.isValidStorageUrl(''), isFalse);
      expect(StorageRouter.isValidStorageUrl('not a url'), isFalse);
    });
  });

  group('BUG 12: Whole-File Media Encryption Limits', () {
    test('prepareAndEncryptVoiceNote rejects file larger than 25MB before reading', () async {
      final bigFile = File('${tempDir.path}/big_audio.m4a');
      // Create a sparse/simulated file over 25MB
      final raf = bigFile.openSync(mode: FileMode.write);
      raf.truncateSync(26 * 1024 * 1024); // 26MB
      raf.closeSync();

      expect(bigFile.lengthSync(), greaterThan(25 * 1024 * 1024));

      final service = VoiceNoteService();
      final result = await service.prepareAndEncryptVoiceNote(
        localAudioPath: bigFile.path,
        durationMs: 5000,
        waveform: [1, 2, 3],
        deleteSourceOnSuccess: false,
      );

      expect(result, isNull);
    });
  });
}
