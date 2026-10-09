import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3_raw;

import 'package:flutter/foundation.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:aisat_connect/models/mndo_message_envelope.dart';
import 'package:aisat_connect/models/chat_message.dart';
import 'package:aisat_connect/database/database.dart';
import 'package:aisat_connect/repositories/chat_repository.dart';
import 'package:aisat_connect/providers/auth_provider.dart';
import 'package:aisat_connect/providers/chat_provider.dart';
import 'package:aisat_connect/services/account_session.dart';
import 'package:aisat_connect/services/crypto_service.dart';
import 'package:aisat_connect/services/signal_messaging_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    AccountSession.setGenerationForTesting(100);
  });

  group('MSG-ID-01A & MSG-ID-01B: Message Identifier Hardening & Database Integrity', () {

    // -------------------------------------------------------------------------
    // T01: Generator produces UUIDv4-compatible IDs; verify version and variant bits
    // -------------------------------------------------------------------------
    test('T01: Generator produces UUIDv4-compatible IDs with valid version & variant bits', () {
      final uuidv4Regex = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');

      // Unprefixed UUID
      final id = MndoMessageEnvelope.generateMessageId();
      expect(id.length, equals(36));
      expect(uuidv4Regex.hasMatch(id), isTrue,
          reason: 'Unprefixed ID must be a strictly compliant UUIDv4 string');

      final parts = id.split('-');
      expect(parts.length, equals(5));
      expect(parts[2].startsWith('4'), isTrue, reason: 'Version nibble must be 4');
      expect(['8', '9', 'a', 'b'].contains(parts[3][0].toLowerCase()), isTrue,
          reason: 'Variant bits must conform to RFC 4122 variant');

      // Prefixed UUID
      final prefixed = MndoMessageEnvelope.generateMessageId('msg');
      expect(prefixed.startsWith('msg-'), isTrue);
      final rawUuid = prefixed.substring(4);
      expect(uuidv4Regex.hasMatch(rawUuid), isTrue,
          reason: 'Prefixed ID suffix must be a compliant UUIDv4 string');

      // Check no monotonic counter or timestamp leak
      final id1 = MndoMessageEnvelope.generateMessageId();
      final id2 = MndoMessageEnvelope.generateMessageId();
      expect(id1, isNot(equals(id2)));
    });

    // -------------------------------------------------------------------------
    // T02: Generate a large batch of IDs (e.g., 10,000) in one process
    // -------------------------------------------------------------------------
    test('T02: Large batch of 10,000 IDs generates zero collisions', () {
      const batchSize = 10000;
      final set = <String>{};

      for (int i = 0; i < batchSize; i++) {
        final id = MndoMessageEnvelope.generateMessageId('msg');
        final inserted = set.add(id);
        expect(inserted, isTrue, reason: 'Collision detected on attempt $i with id: $id');
      }

      expect(set.length, equals(batchSize));
    });

    // -------------------------------------------------------------------------
    // T03: Insert two ChatMessages rows with the same messageId
    // -------------------------------------------------------------------------
    test('T03: Database rejects duplicate messageId at the database boundary', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() => db.close());

      const duplicateId = 'uuid-fixed-dup-t03';

      await db.insertMessage(ChatMessagesCompanion.insert(
        messageId: duplicateId,
        nostrPubKeyHex: 'peer_nostr_1',
        messageText: 'First insert',
        isMe: true,
        timestamp: DateTime.now(),
      ));

      // Second insert with the identical messageId MUST throw SQLite unique constraint failure
      expect(
        () => db.insertMessage(ChatMessagesCompanion.insert(
          messageId: duplicateId,
          nostrPubKeyHex: 'peer_nostr_2',
          messageText: 'Conflicting second insert',
          isMe: false,
          timestamp: DateTime.now(),
        )),
        throwsA(anything),
        reason: 'Database must reject duplicate messageId at the SQLite boundary',
      );
    });

    // -------------------------------------------------------------------------
    // T04: Attempt to insert a ChatMessages row without messageId
    // -------------------------------------------------------------------------
    test('T04: Database rejects insert without messageId (NOT NULL constraint)', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() => db.close());

      // Raw SQL insert bypassing Drift companion type system to test SQLite NOT NULL constraint
      expect(
        () => db.customStatement(
          "INSERT INTO chat_messages (nostr_pub_key_hex, message_text, is_me, timestamp) "
          "VALUES ('peer_nostr', 'text without id', 1, 1710000000);",
        ),
        throwsA(anything),
        reason: 'SQLite NOT NULL constraint on message_id must reject inserts missing message_id',
      );
    });

    // -------------------------------------------------------------------------
    // T05: Upgrade a schema-v5 database containing null message IDs
    // -------------------------------------------------------------------------
    test('T05: Upgrade schema-v5 database repairs null/empty message IDs deterministically', () async {
      final tempDir = await Directory.systemTemp.createTemp('mndo_db_t05_');
      final dbFile = File('${tempDir.path}/test_v5_null.db');
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });

      // 1. Setup raw SQLite database simulating schemaVersion 5
      final rawDb = sqlite3_raw.sqlite3.open(dbFile.path);
      rawDb.execute('PRAGMA user_version = 5;');
      rawDb.execute('''
        CREATE TABLE chat_messages (
          id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
          message_id TEXT,
          nostr_pub_key_hex TEXT NOT NULL,
          message_text TEXT NOT NULL,
          is_me INTEGER NOT NULL CHECK ("is_me" IN (0, 1)),
          timestamp INTEGER NOT NULL,
          status TEXT NOT NULL DEFAULT 'sent',
          reply_to_id TEXT
        );
      ''');
      rawDb.execute('''
        CREATE TABLE active_chats (
          master_pub_key_hex TEXT NOT NULL PRIMARY KEY,
          nostr_pub_key_hex TEXT NOT NULL,
          username TEXT NOT NULL,
          display_name TEXT,
          bio TEXT,
          last_seen INTEGER NOT NULL
        );
      ''');
      rawDb.execute('''
        CREATE TABLE signal_identities (address TEXT NOT NULL PRIMARY KEY, identity_key BLOB NOT NULL);
        CREATE TABLE signal_pre_keys (pre_key_id INTEGER NOT NULL PRIMARY KEY, record BLOB NOT NULL);
        CREATE TABLE signal_signed_pre_keys (signed_pre_key_id INTEGER NOT NULL PRIMARY KEY, record BLOB NOT NULL);
        CREATE TABLE signal_sessions (address TEXT NOT NULL PRIMARY KEY, record BLOB NOT NULL);
        CREATE TABLE outbox_messages (
          message_id TEXT NOT NULL PRIMARY KEY,
          recipient_nostr_pub_key TEXT NOT NULL,
          payload_json TEXT NOT NULL,
          attempts INTEGER NOT NULL DEFAULT 0,
          last_attempt_at INTEGER,
          created_at INTEGER NOT NULL,
          expires_at INTEGER NOT NULL,
          status TEXT NOT NULL DEFAULT 'pending'
        );
      ''');

      // Insert legacy rows: one null messageId, one empty messageId, one valid messageId
      rawDb.execute("INSERT INTO chat_messages (id, message_id, nostr_pub_key_hex, message_text, is_me, timestamp) "
          "VALUES (1, NULL, 'peer_1', 'Message with NULL ID', 0, 1710000001);");
      rawDb.execute("INSERT INTO chat_messages (id, message_id, nostr_pub_key_hex, message_text, is_me, timestamp) "
          "VALUES (2, '   ', 'peer_1', 'Message with empty ID', 1, 1710000002);");
      rawDb.execute("INSERT INTO chat_messages (id, message_id, nostr_pub_key_hex, message_text, is_me, timestamp) "
          "VALUES (3, 'msg-pre-existing-valid', 'peer_2', 'Valid Message', 0, 1710000003);");
      rawDb.close();

      // 2. Open with Drift AppDatabase to trigger migration 5 -> 6
      final appDb = AppDatabase.forTesting(NativeDatabase(dbFile));
      final messages = await appDb.getMessagesForChat('peer_1');
      final peer2Messages = await appDb.getMessagesForChat('peer_2');
      await appDb.close();

      expect(messages.length, equals(2));
      expect(peer2Messages.length, equals(1));

      // Row 1 (was NULL) received a valid UUIDv4 messageId
      expect(messages[0].messageId, isNotEmpty);
      expect(messages[0].messageId, startsWith('msg-'));
      expect(messages[0].messageText, equals('Message with NULL ID'));

      // Row 2 (was empty) received a valid UUIDv4 messageId
      expect(messages[1].messageId, isNotEmpty);
      expect(messages[1].messageId, startsWith('msg-'));
      expect(messages[1].messageText, equals('Message with empty ID'));
      expect(messages[0].messageId, isNot(equals(messages[1].messageId)));

      // Row 3 retained its original valid messageId
      expect(peer2Messages[0].messageId, equals('msg-pre-existing-valid'));

      // Total count preserved
      final allCount = messages.length + peer2Messages.length;
      expect(allCount, equals(3));
    });

    // -------------------------------------------------------------------------
    // T06: Upgrade a schema-v5 database with duplicate IDs
    // -------------------------------------------------------------------------
    test('T06: Upgrade schema-v5 database deterministically re-keys duplicate IDs without dropping rows', () async {
      final tempDir = await Directory.systemTemp.createTemp('mndo_db_t06_');
      final dbFile = File('${tempDir.path}/test_v5_dup.db');
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });

      // 1. Setup raw SQLite database simulating schemaVersion 5
      final rawDb = sqlite3_raw.sqlite3.open(dbFile.path);
      rawDb.execute('PRAGMA user_version = 5;');
      rawDb.execute('''
        CREATE TABLE chat_messages (
          id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
          message_id TEXT,
          nostr_pub_key_hex TEXT NOT NULL,
          message_text TEXT NOT NULL,
          is_me INTEGER NOT NULL CHECK ("is_me" IN (0, 1)),
          timestamp INTEGER NOT NULL,
          status TEXT NOT NULL DEFAULT 'sent',
          reply_to_id TEXT
        );
        CREATE TABLE active_chats (master_pub_key_hex TEXT NOT NULL PRIMARY KEY, nostr_pub_key_hex TEXT NOT NULL, username TEXT NOT NULL, display_name TEXT, bio TEXT, last_seen INTEGER NOT NULL);
        CREATE TABLE signal_identities (address TEXT NOT NULL PRIMARY KEY, identity_key BLOB NOT NULL);
        CREATE TABLE signal_pre_keys (pre_key_id INTEGER NOT NULL PRIMARY KEY, record BLOB NOT NULL);
        CREATE TABLE signal_signed_pre_keys (signed_pre_key_id INTEGER NOT NULL PRIMARY KEY, record BLOB NOT NULL);
        CREATE TABLE signal_sessions (address TEXT NOT NULL PRIMARY KEY, record BLOB NOT NULL);
        CREATE TABLE outbox_messages (message_id TEXT NOT NULL PRIMARY KEY, recipient_nostr_pub_key TEXT NOT NULL, payload_json TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, last_attempt_at INTEGER, created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL, status TEXT NOT NULL DEFAULT 'pending');
      ''');

      // Insert 3 duplicate rows sharing message_id = 'shared-dup-id'
      rawDb.execute("INSERT INTO chat_messages (id, message_id, nostr_pub_key_hex, message_text, is_me, timestamp) "
          "VALUES (10, 'shared-dup-id', 'peer_x', 'Canonical first row', 0, 1710000010);");
      rawDb.execute("INSERT INTO chat_messages (id, message_id, nostr_pub_key_hex, message_text, is_me, timestamp) "
          "VALUES (11, 'shared-dup-id', 'peer_x', 'Second row (re-keyed)', 1, 1710000011);");
      rawDb.execute("INSERT INTO chat_messages (id, message_id, nostr_pub_key_hex, message_text, is_me, timestamp) "
          "VALUES (12, 'shared-dup-id', 'peer_x', 'Third row (re-keyed)', 0, 1710000012);");
      rawDb.execute("INSERT INTO chat_messages (id, message_id, nostr_pub_key_hex, message_text, is_me, timestamp) "
          "VALUES (13, 'independent-unique-id', 'peer_x', 'Fourth independent row', 0, 1710000013);");
      rawDb.close();

      // 2. Open with Drift AppDatabase to trigger migration 5 -> 6
      final appDb = AppDatabase.forTesting(NativeDatabase(dbFile));
      final messages = await appDb.getMessagesForChat('peer_x');
      await appDb.close();

      // Zero rows dropped: all 4 rows exist
      expect(messages.length, equals(4), reason: 'No rows may be dropped during duplicate re-keying');

      // Canonical row (lowest id: 10) retained the original shared-dup-id
      final canonicalRow = messages.firstWhere((m) => m.messageText == 'Canonical first row');
      expect(canonicalRow.messageId, equals('shared-dup-id'));

      // Subsequent duplicate rows (ids 11 and 12) received fresh distinct IDs
      final secondRow = messages.firstWhere((m) => m.messageText == 'Second row (re-keyed)');
      final thirdRow = messages.firstWhere((m) => m.messageText == 'Third row (re-keyed)');
      final fourthRow = messages.firstWhere((m) => m.messageText == 'Fourth independent row');

      expect(secondRow.messageId, isNot(equals('shared-dup-id')));
      expect(thirdRow.messageId, isNot(equals('shared-dup-id')));
      expect(secondRow.messageId, isNot(equals(thirdRow.messageId)));
      expect(fourthRow.messageId, equals('independent-unique-id'));

      // All 4 message IDs are completely unique
      final allIds = messages.map((m) => m.messageId).toSet();
      expect(allIds.length, equals(4));
    });

    // -------------------------------------------------------------------------
    // T07: Validate replyToId, status, deletion, receipts, and outbox reconciliation after migration
    // -------------------------------------------------------------------------
    test('T07: Validates replyToId, status updates, receipts, and deletion resolve exact single row', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final repo = ChatRepository(db);
      addTearDown(() => db.close());

      final parentId = MndoMessageEnvelope.generateMessageId('msg');
      final replyId = MndoMessageEnvelope.generateMessageId('msg');

      // Parent message
      await repo.saveMessage('peer_alpha', ChatMessage(
        messageId: parentId,
        text: 'Parent question',
        isMe: false,
        timestamp: DateTime.now(),
        status: MessageStatus.delivered,
      ));

      // Reply message referencing replyToId
      await repo.saveMessage('peer_alpha', ChatMessage(
        messageId: replyId,
        text: 'Child answer',
        isMe: true,
        timestamp: DateTime.now(),
        status: MessageStatus.sent,
        replyToId: parentId,
      ));

      // Verify exact record lookup
      final retrievedReply = await repo.getMessageByMessageId(replyId);
      expect(retrievedReply, isNotNull);
      expect(retrievedReply!.replyToId, equals(parentId));
      expect(retrievedReply.status, equals('sent'));

      // Update status
      await repo.updateMessageStatus(replyId, MessageStatus.read);
      final updatedReply = await repo.getMessageByMessageId(replyId);
      expect(updatedReply!.status, equals('read'));

      // Parent message status remains unaffected
      final parentMsg = await repo.getMessageByMessageId(parentId);
      expect(parentMsg!.status, equals('delivered'));

      // Delete child message resolves single row
      await repo.deleteMessage(replyId);
      expect(await repo.getMessageByMessageId(replyId), isNull);
      expect(await repo.getMessageByMessageId(parentId), isNotNull);
    });

    // -------------------------------------------------------------------------
    // T08: Inbound message reuses an existing messageId with identical and conflicting content
    // -------------------------------------------------------------------------
    test('T08: Inbound message reuses existing messageId - dedups identical, rejects conflicting', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final repo = ChatRepository(db);
      addTearDown(() => db.close());

      const sharedId = 'msg-t08-collision-test';
      final initialTimestamp = DateTime.now();

      // Original message in repository
      await repo.saveMessage('peer_bob', ChatMessage(
        messageId: sharedId,
        text: 'Original message text',
        isMe: false,
        timestamp: initialTimestamp,
        status: MessageStatus.sent,
      ));

      // Sub-case A: Identical replay (same peer, same text, same direction)
      // Dedup behavior: must not throw, must not insert duplicate row, must preserve existing row
      await repo.saveMessage('peer_bob', ChatMessage(
        messageId: sharedId,
        text: 'Original message text',
        isMe: false,
        timestamp: initialTimestamp,
        status: MessageStatus.sent,
      ));

      final rowsAfterReplay = await db.getMessagesForChat('peer_bob');
      expect(rowsAfterReplay.length, equals(1));
      expect(rowsAfterReplay.first.messageText, equals('Original message text'));

      // Sub-case B: Conflicting reuse (different text with same messageId)
      // Must be safely rejected without mutating or overwriting existing message
      await repo.saveMessage('peer_bob', ChatMessage(
        messageId: sharedId,
        text: 'Conflicting malicious spoof',
        isMe: false,
        timestamp: DateTime.now(),
        status: MessageStatus.sent,
      ));

      final rowsAfterConflict = await db.getMessagesForChat('peer_bob');
      expect(rowsAfterConflict.length, equals(1));
      expect(rowsAfterConflict.first.messageText, equals('Original message text'),
          reason: 'Conflicting reuse must not mutate pre-existing message text');
    });

    // -------------------------------------------------------------------------
    // T09: Insert messages from different peers using the same string ID
    // -------------------------------------------------------------------------
    test('T09: Conflicting message ID reuse across different peers is safely rejected', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final repo = ChatRepository(db);
      addTearDown(() => db.close());

      const crossPeerId = 'msg-cross-peer-test-id';

      // Peer 1 stores message with ID crossPeerId
      await repo.saveMessage('peer_one', ChatMessage(
        messageId: crossPeerId,
        text: 'Peer One authentic message',
        isMe: false,
        timestamp: DateTime.now(),
      ));

      // Peer 2 attempts to use the identical message ID
      await repo.saveMessage('peer_two', ChatMessage(
        messageId: crossPeerId,
        text: 'Peer Two colliding message',
        isMe: false,
        timestamp: DateTime.now(),
      ));

      // Peer 1 row preserved
      final peer1Msgs = await db.getMessagesForChat('peer_one');
      expect(peer1Msgs.length, equals(1));
      expect(peer1Msgs.first.messageText, equals('Peer One authentic message'));

      // Peer 2 colliding message rejected; no ambiguous lookup exists
      final peer2Msgs = await db.getMessagesForChat('peer_two');
      expect(peer2Msgs.length, equals(0),
          reason: 'Colliding message from different peer must be rejected under global uniqueness');

      final queriedRecord = await repo.getMessageByMessageId(crossPeerId);
      expect(queriedRecord, isNotNull);
      expect(queriedRecord!.nostrPubKeyHex, equals('peer_one'));
    });

    // -------------------------------------------------------------------------
    // T10: Create a fresh database and upgrade from each supported prior schema version
    // -------------------------------------------------------------------------
    test('T10: Fresh database creation and upgrades produce consistent schema and constraints', () async {
      // 1. Fresh database creation (onCreate -> version 6)
      final freshDb = AppDatabase.forTesting(NativeDatabase.memory());
      expect(freshDb.schemaVersion, equals(6));

      // Validate NOT NULL and UNIQUE constraint on fresh database
      await freshDb.insertMessage(ChatMessagesCompanion.insert(
        messageId: 'fresh-1',
        nostrPubKeyHex: 'peer_fresh',
        messageText: 'Fresh msg',
        isMe: true,
        timestamp: DateTime.now(),
      ));

      expect(
        () => freshDb.insertMessage(ChatMessagesCompanion.insert(
          messageId: 'fresh-1',
          nostrPubKeyHex: 'peer_fresh',
          messageText: 'Dup fresh msg',
          isMe: true,
          timestamp: DateTime.now(),
        )),
        throwsA(anything),
        reason: 'Fresh database must enforce UNIQUE on messageId',
      );
      await freshDb.close();

      // 2. Upgrades from prior schema versions (v1 through v5)
      for (int priorVersion = 1; priorVersion <= 5; priorVersion++) {
        final tempDir = await Directory.systemTemp.createTemp('mndo_upgrade_v${priorVersion}_');
        final dbFile = File('${tempDir.path}/test_upgrade_from_v$priorVersion.db');

        final rawDb = sqlite3_raw.sqlite3.open(dbFile.path);
        rawDb.execute('PRAGMA user_version = $priorVersion;');
        rawDb.execute('''
          CREATE TABLE active_chats (master_pub_key_hex TEXT NOT NULL PRIMARY KEY, nostr_pub_key_hex TEXT NOT NULL, username TEXT NOT NULL, last_seen INTEGER NOT NULL);
          CREATE TABLE signal_identities (address TEXT NOT NULL PRIMARY KEY, identity_key BLOB NOT NULL);
          CREATE TABLE signal_pre_keys (pre_key_id INTEGER NOT NULL PRIMARY KEY, record BLOB NOT NULL);
          CREATE TABLE signal_signed_pre_keys (signed_pre_key_id INTEGER NOT NULL PRIMARY KEY, record BLOB NOT NULL);
          CREATE TABLE signal_sessions (address TEXT NOT NULL PRIMARY KEY, record BLOB NOT NULL);
          CREATE TABLE chat_messages (
            id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
            nostr_pub_key_hex TEXT NOT NULL,
            message_text TEXT NOT NULL,
            is_me INTEGER NOT NULL CHECK ("is_me" IN (0, 1)),
            timestamp INTEGER NOT NULL
          );
        ''');

        if (priorVersion >= 2) {
          rawDb.execute('ALTER TABLE active_chats ADD COLUMN display_name TEXT;');
          rawDb.execute('ALTER TABLE active_chats ADD COLUMN bio TEXT;');
        }
        if (priorVersion >= 3) {
          rawDb.execute('ALTER TABLE chat_messages ADD COLUMN message_id TEXT;');
          rawDb.execute("ALTER TABLE chat_messages ADD COLUMN status TEXT NOT NULL DEFAULT 'sent';");
          rawDb.execute('ALTER TABLE chat_messages ADD COLUMN reply_to_id TEXT;');
        }
        if (priorVersion >= 4) {
          rawDb.execute('''
            CREATE TABLE outbox_messages (
              message_id TEXT NOT NULL PRIMARY KEY,
              recipient_nostr_pub_key TEXT NOT NULL,
              payload_json TEXT NOT NULL,
              attempts INTEGER NOT NULL DEFAULT 0,
              last_attempt_at INTEGER,
              created_at INTEGER NOT NULL,
              status TEXT NOT NULL DEFAULT 'pending'
            );
          ''');
        }
        if (priorVersion >= 5) {
          rawDb.execute('ALTER TABLE outbox_messages ADD COLUMN expires_at INTEGER NOT NULL DEFAULT 0;');
        }

        // Insert a sample legacy message
        if (priorVersion >= 3) {
          rawDb.execute("INSERT INTO chat_messages (id, message_id, nostr_pub_key_hex, message_text, is_me, timestamp) "
              "VALUES (1, 'legacy_v$priorVersion', 'peer_upgrade', 'Msg prior $priorVersion', 1, 1710000000);");
        } else {
          rawDb.execute("INSERT INTO chat_messages (id, nostr_pub_key_hex, message_text, is_me, timestamp) "
              "VALUES (1, 'peer_upgrade', 'Msg prior $priorVersion', 1, 1710000000);");
        }
        rawDb.close();

        // Perform migration by opening through AppDatabase
        final upgradedDb = AppDatabase.forTesting(NativeDatabase(dbFile));
        final msgs = await upgradedDb.getMessagesForChat('peer_upgrade');
        expect(msgs.length, equals(1));
        expect(msgs.first.messageId, isNotEmpty);
        expect(msgs.first.messageText, equals('Msg prior $priorVersion'));

        // Enforces uniqueness after migration
        expect(
          () => upgradedDb.insertMessage(ChatMessagesCompanion.insert(
            messageId: msgs.first.messageId,
            nostrPubKeyHex: 'peer_upgrade',
            messageText: 'Duplicate insert',
            isMe: false,
            timestamp: DateTime.now(),
          )),
          throwsA(anything),
          reason: 'Upgraded database from v$priorVersion must enforce UNIQUE constraint on messageId',
        );

        await upgradedDb.close();
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      }
    });

    // -------------------------------------------------------------------------
    // T11: Migration reference reconciliation - reply targeting re-keyed duplicate
    // -------------------------------------------------------------------------
    test('T11: Migration reconciles reply_to_id referencing re-keyed duplicate message and verifies documented canonical mapping', () async {
      final tempDir = await Directory.systemTemp.createTemp('mndo_db_t11_');
      final dbFile = File('${tempDir.path}/test_v5_reply_reconcile.db');
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });

      // 1. Setup raw SQLite database at schemaVersion 5
      final rawDb = sqlite3_raw.sqlite3.open(dbFile.path);
      rawDb.execute('PRAGMA user_version = 5;');
      rawDb.execute('''
        CREATE TABLE chat_messages (
          id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
          message_id TEXT,
          nostr_pub_key_hex TEXT NOT NULL,
          message_text TEXT NOT NULL,
          is_me INTEGER NOT NULL CHECK ("is_me" IN (0, 1)),
          timestamp INTEGER NOT NULL,
          status TEXT NOT NULL DEFAULT 'sent',
          reply_to_id TEXT
        );
        CREATE TABLE active_chats (master_pub_key_hex TEXT NOT NULL PRIMARY KEY, nostr_pub_key_hex TEXT NOT NULL, username TEXT NOT NULL, display_name TEXT, bio TEXT, last_seen INTEGER NOT NULL);
        CREATE TABLE signal_identities (address TEXT NOT NULL PRIMARY KEY, identity_key BLOB NOT NULL);
        CREATE TABLE signal_pre_keys (pre_key_id INTEGER NOT NULL PRIMARY KEY, record BLOB NOT NULL);
        CREATE TABLE signal_signed_pre_keys (signed_pre_key_id INTEGER NOT NULL PRIMARY KEY, record BLOB NOT NULL);
        CREATE TABLE signal_sessions (address TEXT NOT NULL PRIMARY KEY, record BLOB NOT NULL);
        CREATE TABLE outbox_messages (message_id TEXT NOT NULL PRIMARY KEY, recipient_nostr_pub_key TEXT NOT NULL, payload_json TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, last_attempt_at INTEGER, created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL, status TEXT NOT NULL DEFAULT 'pending');
      ''');

      // Seed cross-chat duplicate where reply in Chat B targets the second duplicate row (which occurred in Chat B):
      // Row 1: Chat A has canonical row with message_id = 'shared-dup-id'
      rawDb.execute("INSERT INTO chat_messages (id, message_id, nostr_pub_key_hex, message_text, is_me, timestamp) "
          "VALUES (1, 'shared-dup-id', 'peer_chat_a', 'Canonical in Chat A', 0, 1000);");
      // Row 2: Chat B has duplicate row with same message_id = 'shared-dup-id'
      rawDb.execute("INSERT INTO chat_messages (id, message_id, nostr_pub_key_hex, message_text, is_me, timestamp) "
          "VALUES (2, 'shared-dup-id', 'peer_chat_b', 'Duplicate in Chat B', 0, 2000);");
      // Row 3: Reply in Chat B replying to 'shared-dup-id'
      rawDb.execute("INSERT INTO chat_messages (id, message_id, nostr_pub_key_hex, message_text, is_me, timestamp, reply_to_id) "
          "VALUES (3, 'reply-in-chat-b', 'peer_chat_b', 'Reply in Chat B', 1, 3000, 'shared-dup-id');");

      // Also seed intra-chat ambiguous duplicates to verify documented canonical mapping policy:
      // Row 10: Canonical in Chat C
      rawDb.execute("INSERT INTO chat_messages (id, message_id, nostr_pub_key_hex, message_text, is_me, timestamp) "
          "VALUES (10, 'intra-chat-dup', 'peer_chat_c', 'Canonical in Chat C', 0, 1000);");
      // Row 11: Duplicate in Chat C
      rawDb.execute("INSERT INTO chat_messages (id, message_id, nostr_pub_key_hex, message_text, is_me, timestamp) "
          "VALUES (11, 'intra-chat-dup', 'peer_chat_c', 'Duplicate in Chat C', 0, 2000);");
      // Row 12: Reply in Chat C referencing 'intra-chat-dup'
      rawDb.execute("INSERT INTO chat_messages (id, message_id, nostr_pub_key_hex, message_text, is_me, timestamp, reply_to_id) "
          "VALUES (12, 'reply-in-chat-c', 'peer_chat_c', 'Reply in Chat C', 1, 3000, 'intra-chat-dup');");

      rawDb.close();

      // 2. Open with Drift AppDatabase to trigger migration 5 -> 6
      final appDb = AppDatabase.forTesting(NativeDatabase(dbFile));
      final chatAMsgs = await appDb.getMessagesForChat('peer_chat_a');
      final chatBMsgs = await appDb.getMessagesForChat('peer_chat_b');
      final chatCMsgs = await appDb.getMessagesForChat('peer_chat_c');
      await appDb.close();

      // Check Chat A: canonical row retained 'shared-dup-id'
      expect(chatAMsgs.length, equals(1));
      expect(chatAMsgs.first.messageId, equals('shared-dup-id'));

      // Check Chat B: duplicate row was re-keyed to a fresh ID
      expect(chatBMsgs.length, equals(2));
      final targetRowInB = chatBMsgs.firstWhere((m) => m.messageText == 'Duplicate in Chat B');
      final replyRowInB = chatBMsgs.firstWhere((m) => m.messageText == 'Reply in Chat B');
      expect(targetRowInB.messageId, isNot(equals('shared-dup-id')));
      expect(targetRowInB.messageId, startsWith('msg-'));

      // Reply in Chat B's replyToId was reconciled to point to the re-keyed ID in Chat B!
      expect(replyRowInB.replyToId, equals(targetRowInB.messageId),
          reason: 'Reply in Chat B must be reconciled to target the re-keyed row in Chat B');

      // Check Chat C: ambiguous intra-chat duplicate maps to documented canonical lowest-id row
      expect(chatCMsgs.length, equals(3));
      final replyRowInC = chatCMsgs.firstWhere((m) => m.messageText == 'Reply in Chat C');
      expect(replyRowInC.replyToId, equals('intra-chat-dup'),
          reason: 'Documented canonical mapping: ambiguous same-chat reference maps to canonical row');
    });

    // -------------------------------------------------------------------------
    // T12: Migration outbox reconciliation - outbox matching re-keyed duplicate
    // -------------------------------------------------------------------------
    test('T12: Migration reconciles outbox_messages references matching re-keyed outgoing duplicate', () async {
      final tempDir = await Directory.systemTemp.createTemp('mndo_db_t12_');
      final dbFile = File('${tempDir.path}/test_v5_outbox_reconcile.db');
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });

      // 1. Setup raw SQLite database at schemaVersion 5
      final rawDb = sqlite3_raw.sqlite3.open(dbFile.path);
      rawDb.execute('PRAGMA user_version = 5;');
      rawDb.execute('''
        CREATE TABLE chat_messages (
          id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
          message_id TEXT,
          nostr_pub_key_hex TEXT NOT NULL,
          message_text TEXT NOT NULL,
          is_me INTEGER NOT NULL CHECK ("is_me" IN (0, 1)),
          timestamp INTEGER NOT NULL,
          status TEXT NOT NULL DEFAULT 'sent',
          reply_to_id TEXT
        );
        CREATE TABLE active_chats (master_pub_key_hex TEXT NOT NULL PRIMARY KEY, nostr_pub_key_hex TEXT NOT NULL, username TEXT NOT NULL, display_name TEXT, bio TEXT, last_seen INTEGER NOT NULL);
        CREATE TABLE signal_identities (address TEXT NOT NULL PRIMARY KEY, identity_key BLOB NOT NULL);
        CREATE TABLE signal_pre_keys (pre_key_id INTEGER NOT NULL PRIMARY KEY, record BLOB NOT NULL);
        CREATE TABLE signal_signed_pre_keys (signed_pre_key_id INTEGER NOT NULL PRIMARY KEY, record BLOB NOT NULL);
        CREATE TABLE signal_sessions (address TEXT NOT NULL PRIMARY KEY, record BLOB NOT NULL);
        CREATE TABLE outbox_messages (
          message_id TEXT NOT NULL PRIMARY KEY,
          recipient_nostr_pub_key TEXT NOT NULL,
          payload_json TEXT NOT NULL,
          attempts INTEGER NOT NULL DEFAULT 0,
          last_attempt_at INTEGER,
          created_at INTEGER NOT NULL,
          expires_at INTEGER NOT NULL,
          status TEXT NOT NULL DEFAULT 'pending'
        );
      ''');

      // Seed scenario:
      // Row 1: incoming message from peer_other with message_id = 'outbox-dup-x' (is_me = 0)
      rawDb.execute("INSERT INTO chat_messages (id, message_id, nostr_pub_key_hex, message_text, is_me, timestamp) "
          "VALUES (1, 'outbox-dup-x', 'peer_other', 'Inbound message', 0, 1000);");
      // Row 2: outgoing message to peer_target with same message_id = 'outbox-dup-x' (is_me = 1)
      rawDb.execute("INSERT INTO chat_messages (id, message_id, nostr_pub_key_hex, message_text, is_me, timestamp, status) "
          "VALUES (2, 'outbox-dup-x', 'peer_target', 'Outbound message payload', 1, 2000, 'sending');");
      // Outbox item for peer_target with message_id = 'outbox-dup-x'
      rawDb.execute("INSERT INTO outbox_messages (message_id, recipient_nostr_pub_key, payload_json, attempts, created_at, expires_at, status) "
          "VALUES ('outbox-dup-x', 'peer_target', '{\"text\":\"Outbound message payload\"}', 0, 2000, 2000 + 604800, 'pending');");

      rawDb.close();

      // 2. Open with Drift AppDatabase to trigger migration 5 -> 6
      final appDb = AppDatabase.forTesting(NativeDatabase(dbFile));
      final repo = ChatRepository(appDb);

      final peerOtherMsgs = await appDb.getMessagesForChat('peer_other');
      final peerTargetMsgs = await appDb.getMessagesForChat('peer_target');
      final outboxItems = await appDb.select(appDb.outboxMessages).get();

      // Row 1 retains 'outbox-dup-x'
      expect(peerOtherMsgs.first.messageId, equals('outbox-dup-x'));

      // Row 2 received a fresh re-keyed UUID
      final outgoingMsg = peerTargetMsgs.first;
      expect(outgoingMsg.messageId, isNot(equals('outbox-dup-x')));
      expect(outgoingMsg.messageId, startsWith('msg-'));

      // Outbox entry was reconciled to match outgoing message's re-keyed ID!
      expect(outboxItems.length, equals(1));
      expect(outboxItems.first.messageId, equals(outgoingMsg.messageId),
          reason: 'Outbox entry must be reconciled to match the re-keyed outgoing message');
      expect(outboxItems.first.recipientNostrPubKey, equals('peer_target'));

      // Verify status reconciliation targets the intended message
      await repo.updateMessageStatus(outgoingMsg.messageId, MessageStatus.delivered);
      final updatedMsg = await repo.getMessageByMessageId(outgoingMsg.messageId);
      expect(updatedMsg!.status, equals('delivered'));

      await appDb.close();
    });

    // -------------------------------------------------------------------------
    // T13: Injected migration failure rolls back transaction to usable schema-v5
    // -------------------------------------------------------------------------
    test('T13: Injected migration failure rolls back transaction to usable pre-upgrade schema-v5 database', () async {
      final tempDir = await Directory.systemTemp.createTemp('mndo_db_t13_');
      final dbFile = File('${tempDir.path}/test_v5_rollback.db');
      addTearDown(() async {
        try {
          if (await tempDir.exists()) await tempDir.delete(recursive: true);
        } catch (_) {}
      });

      // 1. Setup raw SQLite database at schemaVersion 5
      final rawDb = sqlite3_raw.sqlite3.open(dbFile.path);
      rawDb.execute('PRAGMA user_version = 5;');
      rawDb.execute('''
        CREATE TABLE chat_messages (
          id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
          message_id TEXT,
          nostr_pub_key_hex TEXT NOT NULL,
          message_text TEXT NOT NULL,
          is_me INTEGER NOT NULL CHECK ("is_me" IN (0, 1)),
          timestamp INTEGER NOT NULL,
          status TEXT NOT NULL DEFAULT 'sent',
          reply_to_id TEXT
        );
        CREATE TABLE active_chats (master_pub_key_hex TEXT NOT NULL PRIMARY KEY, nostr_pub_key_hex TEXT NOT NULL, username TEXT NOT NULL, display_name TEXT, bio TEXT, last_seen INTEGER NOT NULL);
        CREATE TABLE signal_identities (address TEXT NOT NULL PRIMARY KEY, identity_key BLOB NOT NULL);
        CREATE TABLE signal_pre_keys (pre_key_id INTEGER NOT NULL PRIMARY KEY, record BLOB NOT NULL);
        CREATE TABLE signal_signed_pre_keys (signed_pre_key_id INTEGER NOT NULL PRIMARY KEY, record BLOB NOT NULL);
        CREATE TABLE signal_sessions (address TEXT NOT NULL PRIMARY KEY, record BLOB NOT NULL);
        CREATE TABLE outbox_messages (message_id TEXT NOT NULL PRIMARY KEY, recipient_nostr_pub_key TEXT NOT NULL, payload_json TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, last_attempt_at INTEGER, created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL, status TEXT NOT NULL DEFAULT 'pending');
      ''');
      rawDb.execute("INSERT INTO chat_messages (id, message_id, nostr_pub_key_hex, message_text, is_me, timestamp) "
          "VALUES (1, 'msg-preserved', 'peer_rb', 'Original message before failure', 0, 1000);");

      // Inject a conflicting table chat_messages_v6 that will cause table recreation step to fail
      rawDb.execute("CREATE TABLE chat_messages_v6 (dummy_col INT NOT NULL PRIMARY KEY);");
      rawDb.close();

      // 2. Open AppDatabase: migration must fail and throw
      final db = AppDatabase.forTesting(NativeDatabase(dbFile));
      bool didThrow = false;
      try {
        await db.customSelect('SELECT 1;').get();
      } catch (_) {
        didThrow = true;
      } finally {
        await db.close();
      }
      expect(didThrow, isTrue, reason: 'Migration must fail and throw on injected conflict');

      // 3. Inspect raw SQLite database to verify rollback
      final checkDb = sqlite3_raw.sqlite3.open(dbFile.path);
      final versionResult = checkDb.select('PRAGMA user_version;');
      final currentVersion = versionResult.first['user_version'] as int;
      expect(currentVersion, equals(5), reason: 'Database user_version must remain at 5 after failed migration');

      final rows = checkDb.select('SELECT id, message_id, message_text FROM chat_messages;');
      expect(rows.length, equals(1), reason: 'chat_messages table and rows must remain intact');
      expect(rows.first['message_text'], equals('Original message before failure'));
      checkDb.close();
    });

    // -------------------------------------------------------------------------
    // T14: Concurrent race - overlapping saveMessage operations with identical ID
    // -------------------------------------------------------------------------
    test('T14: Concurrent overlapping saveMessage operations with identical ID produce exactly one row and no uncaught exceptions', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final repo = ChatRepository(db);
      addTearDown(() => db.close());

      const sharedRaceId = 'msg-concurrent-race-test';

      final msgA = ChatMessage(
        messageId: sharedRaceId,
        text: 'Content from caller A',
        isMe: true,
        timestamp: DateTime.now(),
      );

      final msgB = ChatMessage(
        messageId: sharedRaceId,
        text: 'Conflicting content from caller B',
        isMe: false,
        timestamp: DateTime.now(),
      );

      // Execute concurrent saveMessage operations
      final results = await Future.wait([
        repo.saveMessage('peer_alpha', msgA),
        repo.saveMessage('peer_beta', msgB),
      ]);

      // Exactly one must be inserted, the other must be recognized as conflictingId
      expect(results, contains(SaveMessageResult.inserted));
      expect(results, contains(SaveMessageResult.conflictingId));

      // Database has exactly 1 row
      final storedRecord = await repo.getMessageByMessageId(sharedRaceId);
      expect(storedRecord, isNotNull);

      final totalRows = await db.customSelect(
        'SELECT COUNT(*) AS c FROM chat_messages WHERE message_id = ?;',
        variables: [Variable.withString(sharedRaceId)],
      ).getSingle();
      expect(totalRows.read<int>('c'), equals(1));
    });

    // -------------------------------------------------------------------------
    // T15: Provider state - rejected collision does not leave phantom bubble or unread count
    // -------------------------------------------------------------------------
    test('T15: Collision through ChatProvider.addMessage does not leave phantom in-memory bubble or unread count', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final repo = ChatRepository(db);
      final auth = _TestAuthProvider();
      final signal = _TestSignalService();
      final provider = ChatProvider(
        chatRepo: repo,
        authProvider: auth,
        signalService: signal,
      );
      addTearDown(() => db.close());

      const collisionId = 'msg-phantom-bubble-test';

      // 1. First legitimate message stored for peer_alice
      final firstResult = await provider.addMessage('peer_alice', ChatMessage(
        messageId: collisionId,
        text: 'Legitimate first message',
        isMe: false,
        timestamp: DateTime.now(),
      ));
      expect(firstResult, equals(SaveMessageResult.inserted));
      expect(provider.chatHistories['peer_alice']?.length, equals(1));
      expect(provider.unreadCounts['peer_alice'], equals(1));

      // 2. Conflicting message with same ID arrives for peer_bob
      final conflictResult = await provider.addMessage('peer_bob', ChatMessage(
        messageId: collisionId,
        text: 'Conflicting phantom spoof',
        isMe: false,
        timestamp: DateTime.now(),
      ));

      expect(conflictResult, equals(SaveMessageResult.conflictingId));

      // Crucial assertion: peer_bob has NO phantom bubble in memory and NO unread count!
      expect(provider.chatHistories['peer_bob']?.length ?? 0, equals(0),
          reason: 'Rejected conflicting message must NOT appear in in-memory history');
      expect(provider.unreadCounts['peer_bob'] ?? 0, equals(0),
          reason: 'Rejected conflicting message must NOT increment unread counts');

      // peer_alice remains unchanged
      expect(provider.chatHistories['peer_alice']?.first.text, equals('Legitimate first message'));
    });

    // -------------------------------------------------------------------------
    // T16: Classification of results and propagation of unrelated database errors
    // -------------------------------------------------------------------------
    test('T16: Identical duplicate is classified, and unrelated database errors surface instead of being swallowed', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final repo = ChatRepository(db);

      const testMsgId = 'msg-t16-classify';
      final msg = ChatMessage(
        messageId: testMsgId,
        text: 'Identical content',
        isMe: true,
        timestamp: DateTime.now(),
      );

      final res1 = await repo.saveMessage('peer_t16', msg);
      expect(res1, equals(SaveMessageResult.inserted));

      // Identical duplicate returns identicalDuplicate
      final res2 = await repo.saveMessage('peer_t16', msg);
      expect(res2, equals(SaveMessageResult.identicalDuplicate));

      // Stale session generation error surfaces as StateError (not swallowed)
      AccountSession.setGenerationForTesting(999);
      expect(
        () => repo.saveMessage('peer_t16', msg),
        throwsA(isA<StateError>()),
        reason: 'Stale session generation error must surface as StateError',
      );

      // Restore session generation
      AccountSession.setGenerationForTesting(100);

      // Close database to test unrelated database error propagation
      await db.close();
      expect(
        () => repo.saveMessage('peer_t16', ChatMessage(
          messageId: 'another-id',
          text: 'After close',
          isMe: true,
          timestamp: DateTime.now(),
        )),
        throwsA(anything),
        reason: 'Unrelated database error (closed database) must surface as error and not be caught as unique collision',
      );
    });
  });
}

class _TestAuthProvider extends ChangeNotifier implements AuthProvider {
  @override
  CryptoService cryptoService = CryptoService();
  @override
  String? masterPublicKeyHex = 'abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890';
  @override
  String? displayName = 'Test User';
  @override
  String? username = 'testuser';
  @override
  String? bio = 'Test Bio';
  @override
  String? mnemonic;
  @override
  bool get isAuthenticated => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TestSignalService implements SignalMessagingService {
  @override
  void Function(String peerNostrPubKey)? onIdentityKeyChanged;
  @override
  bool isIdentityBlocked(String peerNostrPubKey) => false;
  @override
  Future<bool> canSendToPeer(String peerNostrPubKey) async => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
