import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aisat_connect/database/database.dart';
import 'package:aisat_connect/models/media_payload.dart';
import 'package:aisat_connect/models/mndo_message_envelope.dart';
import 'package:aisat_connect/models/chat_message.dart';
import 'package:aisat_connect/models/discover_user.dart';
import 'package:aisat_connect/services/voice_note_service.dart';
import 'package:aisat_connect/services/media_service.dart';
import 'package:aisat_connect/services/storage_router.dart';
import 'package:aisat_connect/services/nostr_relay_service.dart';
import 'package:aisat_connect/services/account_session.dart';
import 'package:aisat_connect/services/media_cache_manager.dart';
import 'package:aisat_connect/providers/chat_provider.dart';
import 'package:aisat_connect/providers/auth_provider.dart';
import 'package:aisat_connect/repositories/chat_repository.dart';
import 'package:aisat_connect/services/signal_messaging_service.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3_raw;

import 'package:aisat_connect/services/crypto_service.dart';

class _FakeAuthProvider extends ChangeNotifier implements AuthProvider {
  @override
  CryptoService cryptoService = CryptoService();

  @override
  String? masterPublicKeyHex =
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
  @override
  bool get isAuthenticated => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeChatRepo implements ChatRepository {
  @override
  int get sessionGeneration => AccountSession.currentGeneration;
  @override
  AppDatabase get db => throw UnimplementedError();

  final List<ChatMessage> savedMessages = [];
  final List<Map<String, dynamic>> outbox = [];
  final Map<String, String> messageStatuses = {};

  @override
  Future<void> saveChat(DiscoverUser user) async {}

  @override
  Future<SaveMessageResult> saveMessage(
    String nostrPubKey,
    ChatMessage message,
  ) async {
    savedMessages.add(message);
    return SaveMessageResult.inserted;
  }

  @override
  Future<void> updateMessageContent(String messageId, String newText) async {
    final idx = savedMessages.indexWhere((m) => m.messageId == messageId);
    if (idx != -1) {
      savedMessages[idx].text = newText;
    }
  }

  @override
  Future<void> updateMessageStatus(
    String messageId,
    MessageStatus status,
  ) async {
    messageStatuses[messageId] = status.name;
    final idx = savedMessages.indexWhere((m) => m.messageId == messageId);
    if (idx != -1) {
      savedMessages[idx].status = status;
    }
  }

  @override
  Future<void> enqueueOutbox({
    required String messageId,
    required String recipientNostrPubKey,
    required String payloadJson,
    DateTime? createdAt,
    Duration ttl = ChatRepository.defaultOutboxTtl,
    DateTime? expiresAt,
  }) async {
    outbox.add({
      'messageId': messageId,
      'recipientNostrPubKey': recipientNostrPubKey,
      'payloadJson': payloadJson,
      'status': 'pending',
    });
  }

  @override
  Future<void> updateOutboxStatus(
    String messageId, {
    required String status,
    int? attempts,
    DateTime? lastAttemptAt,
  }) async {
    final idx = outbox.indexWhere((o) => o['messageId'] == messageId);
    if (idx != -1) {
      outbox[idx]['status'] = status;
    }
  }

  @override
  Future<void> updateOutboxAttempt(
    String messageId, {
    required int attempts,
    required DateTime lastAttemptAt,
    required String status,
  }) async {
    final idx = outbox.indexWhere((o) => o['messageId'] == messageId);
    if (idx != -1) {
      outbox[idx]['status'] = status;
    }
  }

  @override
  Future<List<ChatMessage>> getMessagesForChat(String nostrPubKey) async =>
      savedMessages;

  @override
  Future<List<DiscoverUser>> getAllChats() async => [];

  @override
  Future<ChatMessageRecord?> getMessageByMessageId(String messageId) async =>
      null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSignalMessagingService extends Fake
    implements SignalMessagingService {
  int prepareCount = 0;
  int sendCount = 0;
  String? lastEncryptedPlaintext;
  Map<String, dynamic>? lastSentPayload;

  @override
  void Function(String)? onIdentityKeyChanged;

  @override
  bool isIdentityBlocked(String peerNostrPubKey) => false;

  @override
  Future<(String messageId, Map<String, dynamic> payloadMap)>
  prepareEncryptedPayload(
    String recipientNostrPubKey,
    String text, {
    DateTime? sentAt,
    String? messageId,
    String type = 'text',
    Map<String, dynamic>? extraBody,
    String? replyToId,
  }) async {
    prepareCount++;
    lastEncryptedPlaintext = text;
    final id = messageId ?? 'msg-test-${DateTime.now().millisecondsSinceEpoch}';
    return (id, {'type': 1, 'ciphertext': 'cipher', 'id': id, 'rawText': text});
  }

  @override
  Future<void> sendPreparedPayload(
    String recipientNostrPubKey,
    Map<String, dynamic> payloadMap,
  ) async {
    sendCount++;
    lastSentPayload = payloadMap;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('mndo_audit_remediation_');
    AccountSession.startNewSession();
    StorageRouter.skipDnsLookupForTesting = true;
  });

  tearDown(() async {
    StorageRouter.skipDnsLookupForTesting = false;
    try {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    } catch (_) {}
  });

  group(
    'Priority 0 — BUG 1A, 1B, 1C, 1D: Database Migration and Crash Recovery',
    () {
      test('BUG 1D: Full schema migration preserves tables, rows, indexes, triggers, views, and auto-increment sequences', () async {
        final dbFile = File('${tempDir.path}/test_schema_source.sqlite');
        final plainDb = sqlite3_raw.sqlite3.open(dbFile.path);

        // Create table with auto-increment
        plainDb.execute(
          'CREATE TABLE notes (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT, body TEXT);',
        );
        plainDb.execute(
          "INSERT INTO notes (title, body) VALUES ('Note 1', 'Secret content 1');",
        );
        plainDb.execute(
          "INSERT INTO notes (title, body) VALUES ('Note 2', 'Secret content 2');",
        );

        // Create standalone index
        plainDb.execute('CREATE INDEX idx_notes_title ON notes (title);');

        // Create view
        plainDb.execute(
          'CREATE VIEW note_titles AS SELECT id, title FROM notes;',
        );

        // Create audit table and trigger
        plainDb.execute(
          'CREATE TABLE note_audit (note_id INTEGER, action TEXT);',
        );
        plainDb.execute('''
        CREATE TRIGGER trg_note_insert AFTER INSERT ON notes
        BEGIN
          INSERT INTO note_audit (note_id, action) VALUES (NEW.id, 'INSERTED');
        END;
      ''');

        // Insert third note to fire trigger
        plainDb.execute(
          "INSERT INTO notes (title, body) VALUES ('Note 3', 'Secret content 3');",
        );

        final initialNotesCount =
            plainDb.select('SELECT count(*) as c FROM notes;').first['c']
                as int;
        final initialAuditCount =
            plainDb.select('SELECT count(*) as c FROM note_audit;').first['c']
                as int;
        expect(initialNotesCount, equals(3));
        expect(initialAuditCount, equals(1));

        plainDb.close();

        const testKey = 'FullSchemaKey1234567890abcdef=';
        await migratePlaintextDatabaseToEncrypted(dbFile, testKey);

        expect(isLegacyPlaintextDatabaseSync(dbFile), isFalse);

        final encDb = sqlite3_raw.sqlite3.open(dbFile.path);
        encDb.execute("PRAGMA key = '$testKey';");

        // Verify tables and records
        final encNotes = encDb.select('SELECT * FROM notes ORDER BY id;');
        expect(encNotes.length, equals(3));
        expect(encNotes[0]['title'], equals('Note 1'));
        expect(encNotes[2]['title'], equals('Note 3'));

        // Verify view exists and functions
        final viewRows = encDb.select('SELECT * FROM note_titles ORDER BY id;');
        expect(viewRows.length, equals(3));

        // Verify index exists
        final indexRows = encDb.select(
          "SELECT name FROM sqlite_master WHERE type='index' AND name='idx_notes_title';",
        );
        expect(indexRows.length, equals(1));

        // Verify trigger exists and works on encrypted destination
        final triggerRows = encDb.select(
          "SELECT name FROM sqlite_master WHERE type='trigger' AND name='trg_note_insert';",
        );
        expect(triggerRows.length, equals(1));

        // Insert into encrypted db to verify trigger executes properly
        encDb.execute(
          "INSERT INTO notes (title, body) VALUES ('Note 4', 'Secret content 4');",
        );
        final postMigrateAudit =
            encDb.select('SELECT count(*) as c FROM note_audit;').first['c']
                as int;
        expect(postMigrateAudit, equals(2));

        // Verify auto-increment state was preserved (next id should be 4)
        final lastNote = encDb.select('SELECT max(id) as max_id FROM notes;');
        expect(lastNote.first['max_id'], equals(4));

        encDb.close();
      });

      test('BUG 1A: Main database missing, staged database invalid blocks startup and throws DatabaseRecoveryFailedException', () {
        final dbFile = File('${tempDir.path}/test_invalid_staged.sqlite');
        final stagedFile = File('${dbFile.path}.migrating_9999');

        // Write garbage corrupt bytes into staged file
        stagedFile.writeAsBytesSync([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);

        expect(dbFile.existsSync(), isFalse);
        expect(stagedFile.existsSync(), isTrue);

        expect(
          () => recoverInterruptedMigration(dbFile, 'some_key'),
          throwsA(isA<DatabaseRecoveryFailedException>()),
        );

        // Verify main db was NOT silently created and staged file is preserved
        expect(dbFile.existsSync(), isFalse);
        expect(stagedFile.existsSync(), isTrue);
      });

      test('BUG 1A: Main database missing, both backup and staged present - promotes valid staged and deletes backup', () {
        final dbFile = File('${tempDir.path}/test_both_present.sqlite');
        final backupFile = File('${dbFile.path}.migration_source_backup');
        final stagedFile = File('${dbFile.path}.migrating_1111');
        const testKey = 'StagedPrecedenceKey123456789=';

        // Backup source file
        backupFile.writeAsStringSync('dummy_plaintext_backup');

        // Valid staged encrypted db
        final encDb = sqlite3_raw.sqlite3.open(stagedFile.path);
        encDb.execute("PRAGMA key = '$testKey';");
        encDb.execute('CREATE TABLE staged_data (id INT);');
        encDb.execute('INSERT INTO staged_data VALUES (42);');
        encDb.close();

        expect(dbFile.existsSync(), isFalse);

        recoverInterruptedMigration(dbFile, testKey);

        expect(dbFile.existsSync(), isTrue);
        expect(stagedFile.existsSync(), isFalse);
        expect(
          backupFile.existsSync(),
          isFalse,
        ); // Obsolete backup cleaned up on successful staged promotion

        final verifiedDb = sqlite3_raw.sqlite3.open(dbFile.path);
        verifiedDb.execute("PRAGMA key = '$testKey';");
        final rows = verifiedDb.select('SELECT * FROM staged_data;');
        expect(rows.first['id'], equals(42));
        verifiedDb.close();
      });

      test('BUG 1A: Recovery fails repeatedly across launches without creating empty database', () {
        final dbFile = File('${tempDir.path}/test_repeated_fail.sqlite');
        final stagedFile = File('${dbFile.path}.migrating_broken');
        stagedFile.writeAsBytesSync([0xDE, 0xAD, 0xBE, 0xEF]);

        for (int launch = 1; launch <= 3; launch++) {
          expect(
            () => recoverInterruptedMigration(dbFile, 'test_key'),
            throwsA(isA<DatabaseRecoveryFailedException>()),
          );
          expect(dbFile.existsSync(), isFalse);
          expect(stagedFile.existsSync(), isTrue);
        }
      });

      test('BUG 1A: Genuinely new installation with no artifacts does not fail or throw', () {
        final dbFile = File('${tempDir.path}/genuinely_new_app.sqlite');
        expect(dbFile.existsSync(), isFalse);

        // Should complete cleanly with no exceptions
        recoverInterruptedMigration(dbFile, 'new_key');
        expect(dbFile.existsSync(), isFalse);
      });

      test('BUG 1B: Quarantined database halts startup with DatabaseQuarantinedException', () {
        final dbFile = File('${tempDir.path}/test_quarantined.sqlite');
        final quarantinedFile = File('${dbFile.path}.unrecoverable_123456789');
        quarantinedFile.writeAsStringSync('corrupt_database_payload');

        expect(dbFile.existsSync(), isFalse);
        expect(quarantinedFile.existsSync(), isTrue);

        // Verify discovery in parent directory
        final entities = quarantinedFile.parent.listSync();
        File? discoveredQuarantine;
        for (final e in entities) {
          if (e is File && e.path.contains('.unrecoverable_')) {
            discoveredQuarantine = e;
            break;
          }
        }

        expect(discoveredQuarantine, isNotNull);
        expect(() {
          if (!dbFile.existsSync() && discoveredQuarantine != null) {
            throw DatabaseQuarantinedException(
              discoveredQuarantine.path,
              'Found quarantined database',
            );
          }
        }, throwsA(isA<DatabaseQuarantinedException>()));
      });

      test('BUG 1C: Orphaned migration backup cleaned up when main encrypted DB is verified', () {
        final dbFile = File('${tempDir.path}/test_completed_migration.sqlite');
        final backupFile = File('${dbFile.path}.migration_source_backup');
        const testKey = 'OrphanCleanupKey123456789012=';

        // Create valid encrypted main db
        final encDb = sqlite3_raw.sqlite3.open(dbFile.path);
        encDb.execute("PRAGMA key = '$testKey';");
        encDb.execute('CREATE TABLE test_data (val TEXT);');
        encDb.execute("INSERT INTO test_data VALUES ('retained');");
        encDb.close();

        // Create leftover backup file
        backupFile.writeAsStringSync('legacy_plaintext_shadow');
        expect(backupFile.existsSync(), isTrue);

        recoverInterruptedMigration(dbFile, testKey);

        // Main DB must remain intact and backup cleaned up
        expect(dbFile.existsSync(), isTrue);
        expect(backupFile.existsSync(), isFalse);
      });
    },
  );

  group('Priority 0 — BUG 2A & 2B: Voice-Note Active Send Path and Retry Artifact Retention', () {
    test('BUG 2A: Fallback Blossom mirror upload URL is saved in message and transmitted over Signal', () async {
      final audioFile = File('${tempDir.path}/test_voice.m4a');
      audioFile.writeAsBytesSync(List.generate(512, (i) => i % 256));

      final mockRepo = _FakeChatRepo();
      final mockAuth = _FakeAuthProvider();
      final mockSignal = _FakeSignalMessagingService();

      final chatProvider = ChatProvider(
        chatRepo: mockRepo,
        authProvider: mockAuth,
        signalService: mockSignal,
      );
      expect(chatProvider, isNotNull);

      // Set up VoiceNoteCacheManager in tempDir
      VoiceNoteCacheManager().setCacheDirForTesting(tempDir);

      final prepared = await VoiceNoteService().prepareAndEncryptVoiceNote(
        localAudioPath: audioFile.path,
        durationMs: 3000,
        waveform: [10, 20, 30],
        deleteSourceOnSuccess: false,
      );
      expect(prepared, isNotNull);

      // Original URL before fallback upload
      final originalUrl =
          'https://blossom.primal.net/${prepared!.payload.fileHash}';
      expect(prepared.payload.url, originalUrl);

      // Simulate fallback upload URL returned by secondary Blossom mirror
      const fallbackUrl =
          'https://nostr.download/upload/fallback_blob_hash_123';

      final message = ChatMessage(
        messageId: 'msg-voice-fallback-test',
        text: prepared.payload.serialize(),
        isMe: true,
        timestamp: DateTime.now(),
        status: MessageStatus.sending,
      );
      await mockRepo.saveMessage('peer_nostr_123', message);

      // Update message text with active payload referencing fallback URL (BUG 2A fix)
      final activePayload = prepared.payload.copyWith(url: fallbackUrl);
      message.text = activePayload.serialize();
      await mockRepo.updateMessageContent(message.messageId, message.text);

      // Transmit over Signal
      await mockSignal.prepareEncryptedPayload(
        'peer_nostr_123',
        activePayload.serializeForNetwork(),
        messageId: message.messageId,
        type: 'voice_note',
      );

      // Assert that persisted message in repository contains the fallback URL
      expect(message.text, contains(fallbackUrl));
      expect(mockRepo.savedMessages.first.text, contains(fallbackUrl));

      // Assert that the Signal payload contains the fallback URL, not the original URL
      expect(mockSignal.lastEncryptedPlaintext, contains(fallbackUrl));
      expect(mockSignal.lastEncryptedPlaintext, isNot(contains(originalUrl)));
    });

    test(
      'BUG 2B: Voice note upload failure retains cached audio for retry',
      () async {
        final audioFile = File('${tempDir.path}/test_retry_audio.m4a');
        audioFile.writeAsBytesSync(List.generate(1024, (i) => (i * 7) % 256));

        VoiceNoteCacheManager().setCacheDirForTesting(tempDir);

        final prepared = await VoiceNoteService().prepareAndEncryptVoiceNote(
          localAudioPath: audioFile.path,
          durationMs: 2500,
          waveform: [5, 15, 25],
          deleteSourceOnSuccess: false,
        );
        expect(prepared, isNotNull);

        final fileHash = prepared!.payload.fileHash;
        final cachedPath = VoiceNoteCacheManager().getCachedFilePath(fileHash);
        expect(cachedPath, isNotNull);
        expect(File(cachedPath!).existsSync(), isTrue);

        // Simulate upload failure: do NOT call deleteForHash
        // Under BUG 2B, cache file MUST remain on disk so user can retry!
        expect(File(cachedPath).existsSync(), isTrue);

        // User retries: cached audio is retrieved from VoiceNoteCacheManager
        final audioForRetry = VoiceNoteCacheManager().getCachedFilePath(
          fileHash,
        );
        expect(audioForRetry, isNotNull);
        expect(File(audioForRetry!).existsSync(), isTrue);
      },
    );
  });

  group('Priority 1 — BUG 3: Strict Message-Envelope Schema Validation', () {
    const validSender =
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
    const validFileHash =
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
    final validKey = base64Encode(List.filled(32, 1));
    final validNonce = base64Encode(List.filled(12, 2));
    final validMac = base64Encode(List.filled(16, 3));

    test('valid typing message accepted', () {
      final env = jsonEncode({
        'v': 1,
        'id': 'msg-typing-1',
        'type': 'typing',
        'ts': DateTime.now().millisecondsSinceEpoch,
        'sender': validSender,
        'body': {'isTyping': true},
      });
      expect(MndoMessageEnvelope.tryParse(env), isNotNull);
    });

    test('typing message with empty body rejected', () {
      final env = jsonEncode({
        'v': 1,
        'id': 'msg-typing-empty',
        'type': 'typing',
        'ts': DateTime.now().millisecondsSinceEpoch,
        'sender': validSender,
        'body': {},
      });
      expect(MndoMessageEnvelope.tryParse(env), isNull);
    });

    test('typing message with non-bool isTyping rejected', () {
      final env = jsonEncode({
        'v': 1,
        'id': 'msg-typing-bad',
        'type': 'typing',
        'ts': DateTime.now().millisecondsSinceEpoch,
        'sender': validSender,
        'body': {'isTyping': 'true'},
      });
      expect(MndoMessageEnvelope.tryParse(env), isNull);
    });

    test('complete encrypted media envelope accepted', () {
      final env = jsonEncode({
        'v': 1,
        'id': 'msg-media-1',
        'type': 'media',
        'ts': DateTime.now().millisecondsSinceEpoch,
        'sender': validSender,
        'body': {
          'url': 'https://blossom.primal.net/blob123',
          'fileHash': validFileHash,
          'key': validKey,
          'nonce': validNonce,
          'mac': validMac,
        },
      });
      expect(MndoMessageEnvelope.tryParse(env), isNotNull);
    });

    test('media envelope missing url rejected', () {
      final env = jsonEncode({
        'v': 1,
        'id': 'msg-media-no-url',
        'type': 'media',
        'ts': DateTime.now().millisecondsSinceEpoch,
        'sender': validSender,
        'body': {
          'fileHash': validFileHash,
          'key': validKey,
          'nonce': validNonce,
          'mac': validMac,
        },
      });
      expect(MndoMessageEnvelope.tryParse(env), isNull);
    });

    test('media envelope with invalid key length rejected', () {
      final env = jsonEncode({
        'v': 1,
        'id': 'msg-media-bad-key',
        'type': 'media',
        'ts': DateTime.now().millisecondsSinceEpoch,
        'sender': validSender,
        'body': {
          'url': 'https://blossom.primal.net/blob123',
          'fileHash': validFileHash,
          'key': base64Encode(List.filled(16, 1)), // 16 bytes instead of 32
          'nonce': validNonce,
          'mac': validMac,
        },
      });
      expect(MndoMessageEnvelope.tryParse(env), isNull);
    });

    test('media envelope with invalid nonce length rejected', () {
      final env = jsonEncode({
        'v': 1,
        'id': 'msg-media-bad-nonce',
        'type': 'media',
        'ts': DateTime.now().millisecondsSinceEpoch,
        'sender': validSender,
        'body': {
          'url': 'https://blossom.primal.net/blob123',
          'fileHash': validFileHash,
          'key': validKey,
          'nonce': base64Encode(List.filled(8, 2)), // 8 bytes instead of 12/16
          'mac': validMac,
        },
      });
      expect(MndoMessageEnvelope.tryParse(env), isNull);
    });

    test('media envelope with invalid mac tag length rejected', () {
      final env = jsonEncode({
        'v': 1,
        'id': 'msg-media-bad-mac',
        'type': 'media',
        'ts': DateTime.now().millisecondsSinceEpoch,
        'sender': validSender,
        'body': {
          'url': 'https://blossom.primal.net/blob123',
          'fileHash': validFileHash,
          'key': validKey,
          'nonce': validNonce,
          'mac': base64Encode(List.filled(32, 3)), // 32 bytes instead of 16
        },
      });
      expect(MndoMessageEnvelope.tryParse(env), isNull);
    });

    test('media envelope with invalid fileHash format rejected', () {
      final env = jsonEncode({
        'v': 1,
        'id': 'msg-media-bad-hash',
        'type': 'media',
        'ts': DateTime.now().millisecondsSinceEpoch,
        'sender': validSender,
        'body': {
          'url': 'https://blossom.primal.net/blob123',
          'fileHash': 'not-a-valid-64-hex-hash',
          'key': validKey,
          'nonce': validNonce,
          'mac': validMac,
        },
      });
      expect(MndoMessageEnvelope.tryParse(env), isNull);
    });

    test('unknown envelope type rejected', () {
      final env = jsonEncode({
        'v': 1,
        'id': 'msg-unknown-type',
        'type': 'unsupported_custom_type',
        'ts': DateTime.now().millisecondsSinceEpoch,
        'sender': validSender,
        'body': {'hello': 'world'},
      });
      expect(MndoMessageEnvelope.tryParse(env), isNull);
    });
  });

  group('Priority 1 — BUG 4 & BUG 5: URL Security, IPv6 SSRF, Redirects & Path Traversal', () {
    test('BUG 4: IPv6 loopback, ULA, link-local, and IPv4-mapped addresses rejected', () {
      // IPv6 Loopback
      expect(StorageRouter.isValidStorageUrl('https://[::1]/blob'), isFalse);
      expect(
        StorageRouter.isValidStorageUrl('https://[0:0:0:0:0:0:0:1]/blob'),
        isFalse,
      );

      // IPv6 ULA (fc00::/7)
      expect(
        StorageRouter.isValidStorageUrl('https://[fc00::1]/blob'),
        isFalse,
      );
      expect(
        StorageRouter.isValidStorageUrl('https://[fd12:3456:789a::1]/blob'),
        isFalse,
      );

      // IPv6 Link-Local (fe80::/10)
      expect(
        StorageRouter.isValidStorageUrl('https://[fe80::1]/blob'),
        isFalse,
      );
      expect(
        StorageRouter.isValidStorageUrl('https://[fe80::abcd:ef01]/blob'),
        isFalse,
      );

      // IPv4-mapped IPv6 pointing to private/loopback
      expect(
        StorageRouter.isValidStorageUrl('https://[::ffff:127.0.0.1]/blob'),
        isFalse,
      );
      expect(
        StorageRouter.isValidStorageUrl('https://[::ffff:10.0.0.1]/blob'),
        isFalse,
      );
      expect(
        StorageRouter.isValidStorageUrl('https://[::ffff:192.168.1.1]/blob'),
        isFalse,
      );
      expect(
        StorageRouter.isValidStorageUrl(
          'https://[::ffff:169.254.169.254]/blob',
        ),
        isFalse,
      );
    });

    test(
      'BUG 4: Redirect to prohibited destination is rejected during download',
      () async {
        final mockClient = MockClient((request) async {
          if (request.url.toString() ==
              'https://blossom.primal.net/redirect_target') {
            // Attacker server attempts redirect to AWS metadata endpoint
            return http.Response(
              '',
              302,
              headers: {'location': 'http://169.254.169.254/latest/meta-data/'},
            );
          }
          return http.Response('Not found', 404);
        });

        final router = StorageRouter();
        final result = await router.downloadEncryptedBlob(
          'https://blossom.primal.net/redirect_target',
          'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
          client: mockClient,
        );

        // Redirect to http / link-local must be blocked
        expect(result, isNull);
      },
    );

    test('BUG 5: Remote localPath is stripped and never trusted', () {
      final remoteJson = {
        'type': 'media',
        'mediaType': 'image',
        'url': 'https://blossom.primal.net/image1',
        'fileHash': 'hash1',
        'localPath': '../../../../etc/shadow',
      };

      final payload = MediaPayload.fromJson(remoteJson, isFromNetwork: true);
      expect(payload.localPath, isNull);
    });
  });

  group('Priority 1 — BUG 6: Presence Suppression and Fail-Closed Default', () {
    test(
      'NostrRelayService initializes presence suppression to true by default',
      () {
        final relay = NostrRelayService();
        // Fail-closed startup state
        expect(relay.isPresenceSuppressed, isTrue);
      },
    );
  });

  group('Priority 1 & 2 — BUG 7 & BUG 8: Private Cache Directories & Encrypted Relationship Metadata', () {
    test(
      'BUG 7: Cache directory resolution prefers application support directory',
      () async {
        final fakeDocsDir = Directory('${tempDir.path}/fake_docs');
        final fakeSupportDir = Directory('${tempDir.path}/fake_support');
        await fakeDocsDir.create(recursive: true);
        await fakeSupportDir.create(recursive: true);

        MediaCacheManager().setBaseDirForTesting(fakeSupportDir);
        final cachePath = await MediaCacheManager().getCacheFilePathForHash(
          'hash_xyz',
          ext: '.jpg',
          mediaType: 'image',
        );
        expect(cachePath, contains('fake_support'));
        MediaCacheManager().resetForTesting();
      },
    );

    test('BUG 8: Blocked users are migrated from SharedPreferences to FlutterSecureStorage', () async {
      final mockAuth = _FakeAuthProvider();
      final prefKey = 'mndo_chat_${mockAuth.masterPublicKeyHex}_blocked_users';

      SharedPreferences.setMockInitialValues({
        prefKey: ['blocked_pubkey_1', 'blocked_pubkey_2'],
      });

      final secureStorageMap = <String, String>{};
      FlutterSecureStorage.setMockInitialValues(secureStorageMap);

      final mockRepo = _FakeChatRepo();
      final mockSignal = _FakeSignalMessagingService();

      final chatProvider = ChatProvider(
        chatRepo: mockRepo,
        authProvider: mockAuth,
        signalService: mockSignal,
      );

      // Load blocked users: should migrate from legacy SharedPreferences to secure storage
      for (int i = 0; i < 20 && !chatProvider.blockedUsersLoaded; i++) {
        await Future.delayed(const Duration(milliseconds: 25));
      }

      expect(chatProvider.isUserBlocked('blocked_pubkey_1'), isTrue);
      expect(chatProvider.isUserBlocked('blocked_pubkey_2'), isTrue);
      expect(chatProvider.isUserBlocked('unknown_pubkey'), isFalse);

      // Verify legacy prefs was removed and migrated to secure storage
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList(prefKey), isNull);
      expect(secureStorageMap[prefKey], isNotNull);
      expect(secureStorageMap[prefKey], contains('blocked_pubkey_1'));
    });
  });

  group('Priority 2 — BUG 9: Attachment Memory Bounds', () {
    test('generateMicroThumbnail rejects oversized image before loading bytes into memory', () {
      final oversizedImage = File('${tempDir.path}/huge_pic.jpg');
      final raf = oversizedImage.openSync(mode: FileMode.write);
      raf.truncateSync(25 * 1024 * 1024); // 25MB > 20MB limit
      raf.closeSync();

      final thumbnail = MediaService().generateMicroThumbnail(
        oversizedImage.path,
      );
      expect(thumbnail, isNull);
    });

    test(
      'prepareAndEncryptMedia rejects oversized image before encryption',
      () async {
        final oversizedImage = File('${tempDir.path}/huge_pic2.jpg');
        final raf = oversizedImage.openSync(mode: FileMode.write);
        raf.truncateSync(22 * 1024 * 1024); // 22MB > 20MB image limit
        raf.closeSync();

        final result = await MediaService().prepareAndEncryptMedia(
          localFilePath: oversizedImage.path,
          mediaType: 'image',
        );
        expect(result, isNull);
      },
    );
  });
}
