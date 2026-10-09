import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:convert';
import 'dart:math' as dart_math;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite3_raw;
import '../services/account_session.dart';
import '../models/mndo_message_envelope.dart';

part 'database.g.dart';

@DataClassName('ActiveChatRecord')
class ActiveChats extends Table {
  TextColumn get masterPubKeyHex => text()();
  TextColumn get nostrPubKeyHex => text()();
  TextColumn get username => text()();
  TextColumn get displayName => text().nullable()();
  TextColumn get bio => text().nullable()();
  DateTimeColumn get lastSeen => dateTime()();

  @override
  Set<Column> get primaryKey => {masterPubKeyHex};
}

@DataClassName('SignalIdentityRecord')
class SignalIdentities extends Table {
  TextColumn get address => text()();
  BlobColumn get identityKey => blob()();

  @override
  Set<Column> get primaryKey => {address};
}

@DataClassName('SignalPreKeyRecord')
class SignalPreKeys extends Table {
  IntColumn get preKeyId => integer()();
  BlobColumn get record => blob()();

  @override
  Set<Column> get primaryKey => {preKeyId};
}

@DataClassName('SignalSignedPreKeyRecord')
class SignalSignedPreKeys extends Table {
  IntColumn get signedPreKeyId => integer()();
  BlobColumn get record => blob()();

  @override
  Set<Column> get primaryKey => {signedPreKeyId};
}

@DataClassName('SignalSessionRecord')
class SignalSessions extends Table {
  TextColumn get address => text()();
  BlobColumn get record => blob()();

  @override
  Set<Column> get primaryKey => {address};
}

@DataClassName('ChatMessageRecord')
class ChatMessages extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get messageId => text().unique()();
  TextColumn get nostrPubKeyHex => text()();
  TextColumn get messageText => text()();
  BoolColumn get isMe => boolean()();
  DateTimeColumn get timestamp => dateTime()();
  TextColumn get status => text().withDefault(const Constant('sent'))();
  TextColumn get replyToId => text().nullable()();
}

@DataClassName('OutboxRecord')
class OutboxMessages extends Table {
  TextColumn get messageId => text()();
  TextColumn get recipientNostrPubKey => text()();
  TextColumn get payloadJson => text()();
  IntColumn get attempts => integer().withDefault(const Constant(0))();
  DateTimeColumn get lastAttemptAt => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get expiresAt => dateTime()();
  TextColumn get status => text().withDefault(const Constant('pending'))();

  @override
  Set<Column> get primaryKey => {messageId};
}

@DriftDatabase(tables: [ActiveChats, ChatMessages, SignalIdentities, SignalPreKeys, SignalSignedPreKeys, SignalSessions, OutboxMessages])
class AppDatabase extends _$AppDatabase {
  final int sessionGeneration;

  AppDatabase({int? sessionGeneration})
      : sessionGeneration = sessionGeneration ?? AccountSession.currentGeneration,
        super(_openConnection());

  AppDatabase.forTesting(super.e, {int? sessionGeneration})
      : sessionGeneration = sessionGeneration ?? AccountSession.currentGeneration;

  void _ensureActive() {
    if (!AccountSession.isGenerationValid(sessionGeneration)) {
      throw StateError(
        'AppDatabase operation rejected: stale session generation $sessionGeneration (active: ${AccountSession.currentGeneration})'
      );
    }
  }

  @override
  int get schemaVersion => 6;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
    },
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        await m.addColumn(activeChats, activeChats.displayName);
        await m.addColumn(activeChats, activeChats.bio);
      }
      if (from < 3) {
        await customStatement('ALTER TABLE chat_messages ADD COLUMN message_id TEXT;');
        await customStatement("ALTER TABLE chat_messages ADD COLUMN status TEXT NOT NULL DEFAULT 'sent';");
        await customStatement('ALTER TABLE chat_messages ADD COLUMN reply_to_id TEXT;');
      }
      if (from < 4) {
        await m.createTable(outboxMessages);
      }
      if (from < 5) {
        try {
          await customStatement(
            'ALTER TABLE outbox_messages ADD COLUMN expires_at INTEGER NOT NULL DEFAULT 0;',
          );
        } catch (_) {
          // Column may already exist if table was created during upgrade from < 4
        }
        // REL-OUTBOX-01: Derive expiration from createdAt + 7 days (604,800s)
        // rather than leaving it at 0 (1970-01-01), preventing inadvertent immediate expiration.
        await customStatement(
          'UPDATE outbox_messages SET expires_at = created_at + ${const Duration(days: 7).inSeconds} WHERE expires_at = 0;',
        );
      }
      if (from < 6) {
        await _migrateChatMessagesToVersion6();
      }
    },
    beforeOpen: (details) async {
      // Heal any legacy or migrated records with expires_at == 0
      try {
        await customStatement(
          'UPDATE outbox_messages SET expires_at = created_at + ${const Duration(days: 7).inSeconds} WHERE expires_at = 0;',
        );
      } catch (_) {}
    },
  );

  /// MSG-ID-01B: Transactionally migrates chat_messages table to enforce NOT NULL
  /// and UNIQUE constraints on messageId, deterministically repairing any null
  /// or duplicate legacy rows while preserving row counts, message payloads,
  /// outbox relationships, and reply_to_id references.
  Future<void> _migrateChatMessagesToVersion6() async {
    // Transactional savepoint: ensures failed migration rolls back to usable pre-upgrade database
    await customStatement('SAVEPOINT migration_v6;');

    try {
      // 1. Pre-mutation inspection: Map all chat_messages rows by primary key id
      final rows = await customSelect(
        'SELECT id, message_id, nostr_pub_key_hex, message_text, is_me, timestamp, status, reply_to_id '
        'FROM chat_messages ORDER BY id ASC;',
        readsFrom: {},
      ).get();
      final initialCount = rows.length;

      // Check if outbox_messages table exists
      final outboxTableCheck = await customSelect(
        "SELECT count(*) AS c FROM sqlite_master WHERE type='table' AND name='outbox_messages';",
        readsFrom: {},
      ).getSingle();
      final hasOutbox = outboxTableCheck.read<int>('c') > 0;

      // 2. Build deterministic repair plan before mutation
      final Map<int, String> assignedMessageIdByRowId = {};
      final Map<String, List<QueryRow>> rowsByOriginalId = {};
      final List<QueryRow> nullOrEmptyRows = [];

      for (final row in rows) {
        final rawMsgId = row.readNullable<String>('message_id');
        final trimmed = rawMsgId?.trim();
        if (trimmed == null || trimmed.isEmpty) {
          nullOrEmptyRows.add(row);
        } else {
          rowsByOriginalId.putIfAbsent(trimmed, () => []).add(row);
        }
      }

      int nullRepairedCount = 0;
      for (final row in nullOrEmptyRows) {
        final rowId = row.read<int>('id');
        final freshId = MndoMessageEnvelope.generateMessageId('msg');
        assignedMessageIdByRowId[rowId] = freshId;
        nullRepairedCount++;
      }

      int duplicateRepairedCount = 0;
      final List<_DuplicateRepairPlanItem> duplicateRepairs = [];

      for (final entry in rowsByOriginalId.entries) {
        final origId = entry.key;
        final rowGroup = entry.value;

        // Canonical row (lowest id) retains the original message_id
        final canonicalRow = rowGroup.first;
        final canonicalRowId = canonicalRow.read<int>('id');
        assignedMessageIdByRowId[canonicalRowId] = origId;

        // Subsequent duplicate rows are re-keyed with fresh CSPRNG UUIDs
        for (int i = 1; i < rowGroup.length; i++) {
          final dupRow = rowGroup[i];
          final dupRowId = dupRow.read<int>('id');
          final freshId = MndoMessageEnvelope.generateMessageId('msg');
          assignedMessageIdByRowId[dupRowId] = freshId;
          duplicateRepairedCount++;

          duplicateRepairs.add(_DuplicateRepairPlanItem(
            rowId: dupRowId,
            originalId: origId,
            freshId: freshId,
            peer: dupRow.read<String>('nostr_pub_key_hex'),
            isMe: dupRow.read<int>('is_me') == 1,
            timestamp: dupRow.read<int>('timestamp'),
            messageText: dupRow.read<String>('message_text'),
          ));
        }
      }

      // 3. Reconcile outbox_messages references before mutation
      int outboxReconciledCount = 0;
      if (hasOutbox && duplicateRepairs.isNotEmpty) {
        final outboxRows = await customSelect(
          'SELECT message_id, recipient_nostr_pub_key, payload_json FROM outbox_messages;',
          readsFrom: {},
        ).get();

        for (final outboxRow in outboxRows) {
          final outboxMsgId = outboxRow.read<String>('message_id');
          final recipient = outboxRow.read<String>('recipient_nostr_pub_key');

          final matchingDups = duplicateRepairs.where((d) => d.originalId == outboxMsgId).toList();
          if (matchingDups.isNotEmpty) {
            final canonicalRows = rowsByOriginalId[outboxMsgId];
            final canonicalRow = canonicalRows?.first;
            final canonicalIsMe = canonicalRow != null && canonicalRow.read<int>('is_me') == 1;
            final canonicalPeer = canonicalRow?.read<String>('nostr_pub_key_hex');

            // If canonical row was NOT outgoing to this recipient, but a duplicate row was:
            final matchingDupForRecipient = matchingDups.where((d) => d.isMe && d.peer == recipient).toList();
            if (matchingDupForRecipient.isNotEmpty && (!canonicalIsMe || canonicalPeer != recipient)) {
              final targetDup = matchingDupForRecipient.first;
              await customStatement(
                'UPDATE outbox_messages SET message_id = ? WHERE message_id = ? AND recipient_nostr_pub_key = ?;',
                [targetDup.freshId, outboxMsgId, recipient],
              );
              outboxReconciledCount++;
            }
          }
        }
      }

      // 4. Reconcile reply_to_id references deterministically with documented canonical mapping
      // Policy:
      // (a) Chat-isolated: If reply is in Chat B and canonical is in Chat A, and a duplicate in Chat B was re-keyed,
      //     the reply deterministically targets that re-keyed duplicate.
      // (b) Temporal causality: Exclude candidates occurring strictly after the reply timestamp.
      // (c) Documented canonical mapping: If multiple candidates remain in the same chat and precede the reply,
      //     reply_to_id cannot distinguish them without external metadata; it canonically maps to the lowest-id
      //     canonical row, retaining the original message_id.
      final Map<int, String> replyToIdUpdates = {};
      for (final row in rows) {
        final replyToId = row.readNullable<String>('reply_to_id')?.trim();
        if (replyToId == null || replyToId.isEmpty) continue;

        final matchingDups = duplicateRepairs.where((d) => d.originalId == replyToId).toList();
        if (matchingDups.isEmpty) continue;

        final replyRowId = row.read<int>('id');
        final replyPeer = row.read<String>('nostr_pub_key_hex');
        final replyTimestamp = row.read<int>('timestamp');

        final canonicalRows = rowsByOriginalId[replyToId];
        final canonicalRow = canonicalRows?.first;
        final canonicalPeer = canonicalRow?.read<String>('nostr_pub_key_hex');

        final dupsInSameChat = matchingDups.where((d) => d.peer == replyPeer).toList();
        final canonicalInSameChat = canonicalPeer == replyPeer;

        if (dupsInSameChat.isNotEmpty && !canonicalInSameChat) {
          // Unambiguous cross-peer: reply is in this chat, canonical belongs to another chat
          final temporallyPreceding = dupsInSameChat.where((d) => d.timestamp <= replyTimestamp).toList();
          final chosenDup = temporallyPreceding.isNotEmpty ? temporallyPreceding.last : dupsInSameChat.first;
          replyToIdUpdates[replyRowId] = chosenDup.freshId;
        } else if (canonicalInSameChat && dupsInSameChat.isNotEmpty) {
          final canonicalTimestamp = canonicalRow!.read<int>('timestamp');
          // If canonical message was created in the future relative to reply, target the preceding duplicate
          if (canonicalTimestamp > replyTimestamp) {
            final precedingDups = dupsInSameChat.where((d) => d.timestamp <= replyTimestamp).toList();
            if (precedingDups.isNotEmpty) {
              replyToIdUpdates[replyRowId] = precedingDups.last.freshId;
            }
          }
          // Otherwise retains canonical replyToId as documented
        }
      }

      // 5. Apply assigned message_ids to original chat_messages rows before copying
      for (final entry in assignedMessageIdByRowId.entries) {
        await customStatement(
          'UPDATE chat_messages SET message_id = ? WHERE id = ?;',
          [entry.value, entry.key],
        );
      }

      // Apply reply_to_id updates
      for (final entry in replyToIdUpdates.entries) {
        await customStatement(
          'UPDATE chat_messages SET reply_to_id = ? WHERE id = ?;',
          [entry.value, entry.key],
        );
      }

      // 6. Rebuild chat_messages table enforcing NOT NULL + UNIQUE constraints
      await customStatement('''
        CREATE TABLE chat_messages_v6 (
          id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
          message_id TEXT NOT NULL UNIQUE,
          nostr_pub_key_hex TEXT NOT NULL,
          message_text TEXT NOT NULL,
          is_me INTEGER NOT NULL CHECK ("is_me" IN (0, 1)),
          timestamp INTEGER NOT NULL,
          status TEXT NOT NULL DEFAULT 'sent',
          reply_to_id TEXT
        );
      ''');

      await customStatement('''
        INSERT INTO chat_messages_v6 (id, message_id, nostr_pub_key_hex, message_text, is_me, timestamp, status, reply_to_id)
        SELECT id, message_id, nostr_pub_key_hex, message_text, is_me, timestamp, status, reply_to_id
        FROM chat_messages ORDER BY id ASC;
      ''');

      await customStatement('DROP TABLE chat_messages;');
      await customStatement('ALTER TABLE chat_messages_v6 RENAME TO chat_messages;');

      // 7. Post-migration integrity verification
      final nullCountResult = await customSelect(
        'SELECT COUNT(*) AS c FROM chat_messages WHERE message_id IS NULL OR length(trim(message_id)) = 0;',
        readsFrom: {},
      ).getSingle();
      final nullCount = nullCountResult.read<int>('c');
      if (nullCount > 0) {
        throw StateError('chat_messages migration integrity check failed: $nullCount null/empty message IDs remain');
      }

      final dupResult = await customSelect(
        'SELECT COUNT(*) AS c FROM (SELECT message_id FROM chat_messages GROUP BY message_id HAVING COUNT(*) > 1);',
        readsFrom: {},
      ).getSingle();
      final dupCount = dupResult.read<int>('c');
      if (dupCount > 0) {
        throw StateError('chat_messages migration integrity check failed: $dupCount duplicate message IDs remain');
      }

      final rowCountResult = await customSelect(
        'SELECT COUNT(*) AS c FROM chat_messages;',
        readsFrom: {},
      ).getSingle();
      final finalCount = rowCountResult.read<int>('c');
      if (finalCount != initialCount) {
        throw StateError('chat_messages migration integrity check failed: row count mismatch (expected $initialCount, got $finalCount)');
      }

      // Success: release savepoint
      await customStatement('RELEASE SAVEPOINT migration_v6;');

      print('[MIGRATION] Completed chat_messages v6 migration: '
            'totalRows=$initialCount, nullRepaired=$nullRepairedCount, duplicatesRepaired=$duplicateRepairedCount, '
            'outboxReconciled=$outboxReconciledCount, repliesReconciled=${replyToIdUpdates.length}');
    } catch (e) {
      // Rollback to savepoint on any failure, leaving pre-upgrade database intact and usable
      try {
        await customStatement('ROLLBACK TO SAVEPOINT migration_v6;');
        await customStatement('RELEASE SAVEPOINT migration_v6;');
      } catch (_) {}
      rethrow;
    }
  }

  // Active Chats Queries
  Future<List<ActiveChatRecord>> getAllChats() {
    _ensureActive();
    return select(activeChats).get();
  }

  Future<void> insertChat(Insertable<ActiveChatRecord> chat) {
    _ensureActive();
    return into(activeChats).insertOnConflictUpdate(chat);
  }

  Future<void> clearChats() {
    _ensureActive();
    return delete(activeChats).go();
  }

  // Signal Queries
  Future<int> getPreKeyCount() async {
    _ensureActive();
    final countExp = signalPreKeys.preKeyId.count();
    final query = selectOnly(signalPreKeys)..addColumns([countExp]);
    final result = await query.getSingle();
    _ensureActive();
    return result.read(countExp) ?? 0;
  }

  Future<int> getMaxPreKeyId() async {
    _ensureActive();
    final maxExp = signalPreKeys.preKeyId.max();
    final query = selectOnly(signalPreKeys)..addColumns([maxExp]);
    final result = await query.getSingle();
    _ensureActive();
    return result.read(maxExp) ?? 0;
  }

  Future<List<SignalPreKeyRecord>> getAllPreKeys() {
    _ensureActive();
    return select(signalPreKeys).get();
  }

  Future<void> clearSignalData() async {
    _ensureActive();
    await delete(signalIdentities).go();
    await delete(signalPreKeys).go();
    await delete(signalSignedPreKeys).go();
    await delete(signalSessions).go();
    try {
      await customStatement('DELETE FROM signal_signed_prekey_metadata;');
    } catch (_) {}
    _ensureActive();
  }

  // Chat Messages Queries
  Future<List<ChatMessageRecord>> getMessagesForChat(String nostrPubKey) {
    _ensureActive();
    return (select(chatMessages)
      ..where((t) => t.nostrPubKeyHex.equals(nostrPubKey))
      ..orderBy([(t) => OrderingTerm(expression: t.timestamp, mode: OrderingMode.asc)])
    ).get();
  }

  Future<void> insertMessage(Insertable<ChatMessageRecord> msg) {
    _ensureActive();
    return into(chatMessages).insert(msg);
  }

  Future<void> clearMessages() {
    _ensureActive();
    return delete(chatMessages).go();
  }
  
  Future<ChatMessageRecord?> getMessageByMessageId(String messageId) {
    _ensureActive();
    return (select(chatMessages)..where((t) => t.messageId.equals(messageId))).getSingleOrNull();
  }

  Future<int> deleteMessageByMessageId(String messageId) {
    _ensureActive();
    return (delete(chatMessages)..where((t) => t.messageId.equals(messageId))).go();
  }

  Future<void> updateMessageStatus(String messageId, String newStatus) {
    _ensureActive();
    return (update(chatMessages)..where((t) => t.messageId.equals(messageId)))
        .write(ChatMessagesCompanion(status: Value(newStatus)));
  }

  Future<int> markMessagesReadUpTo(String peerNostrPubKey, DateTime timestamp) {
    _ensureActive();
    return (update(chatMessages)
      ..where((t) =>
        t.nostrPubKeyHex.equals(peerNostrPubKey) &
        t.isMe.equals(true) &
        t.timestamp.isSmallerOrEqualValue(timestamp) &
        t.status.equals('read').not()
      )
    ).write(const ChatMessagesCompanion(status: Value('read')));
  }

  Future<DateTime?> getLatestMessageTimestamp() async {
    _ensureActive();
    final query = select(chatMessages)
      ..orderBy([(t) => OrderingTerm(expression: t.timestamp, mode: OrderingMode.desc)])
      ..limit(1);
    final result = await query.getSingleOrNull();
    _ensureActive();
    return result?.timestamp;
  }

  // Outbox Queries
  Future<List<OutboxRecord>> getPendingOutboxMessages() {
    _ensureActive();
    return (select(outboxMessages)
      ..where((t) => t.status.isNotIn(['delivered', 'read', 'expired']))
      ..orderBy([(t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.asc)])
    ).get();
  }

  Future<List<OutboxRecord>> getUndeliveredMessagesForPeer(String recipientNostrPubKey) {
    _ensureActive();
    return (select(outboxMessages)
      ..where((t) => t.recipientNostrPubKey.equals(recipientNostrPubKey) & t.status.isNotIn(['delivered', 'read', 'expired']))
      ..orderBy([(t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.asc)])
    ).get();
  }

  Future<int> markExpiredOutboxMessages(DateTime now) {
    _ensureActive();
    return (update(outboxMessages)
      ..where((t) => t.status.isNotIn(['delivered', 'read', 'expired']) & t.expiresAt.isSmallerOrEqualValue(now))
    ).write(const OutboxMessagesCompanion(status: Value('expired')));
  }

  Future<void> enqueueOutboxMessage(Insertable<OutboxRecord> record) {
    _ensureActive();
    return into(outboxMessages).insertOnConflictUpdate(record);
  }

  Future<void> deleteOutboxMessage(String messageId) {
    _ensureActive();
    return (delete(outboxMessages)..where((t) => t.messageId.equals(messageId))).go();
  }

  Future<void> updateOutboxAttempt(
    String messageId, {
    required int attempts,
    required DateTime lastAttemptAt,
    required String status,
  }) {
    _ensureActive();
    return (update(outboxMessages)..where((t) => t.messageId.equals(messageId))).write(
      OutboxMessagesCompanion(
        attempts: Value(attempts),
        lastAttemptAt: Value(lastAttemptAt),
        status: Value(status),
      ),
    );
  }

  Future<void> updateOutboxStatus(
    String messageId, {
    required String status,
    int? attempts,
    DateTime? lastAttemptAt,
  }) {
    _ensureActive();
    return (update(outboxMessages)..where((t) => t.messageId.equals(messageId))).write(
      OutboxMessagesCompanion(
        status: Value(status),
        attempts: attempts != null ? Value(attempts) : const Value.absent(),
        lastAttemptAt: lastAttemptAt != null ? Value(lastAttemptAt) : const Value.absent(),
      ),
    );
  }

  Future<OutboxRecord?> getOutboxMessage(String messageId) {
    _ensureActive();
    return (select(outboxMessages)..where((t) => t.messageId.equals(messageId))).getSingleOrNull();
  }

  Future<void> clearOutbox() {
    _ensureActive();
    return delete(outboxMessages).go();
  }

  /// Normal-path wipe of all user data during an active session.
  /// Requires that this database's session generation matches the active session.
  Future<void> clearAllUserData() async {
    _ensureActive();
    await clearAllUserDataForTeardown(expectedGeneration: sessionGeneration);
    _ensureActive();
  }

  /// Privileged teardown method callable exclusively during [AccountSession.dispose].
  /// Bypasses [_ensureActive] because the session generation has already been incremented
  /// to immediately invalidate all in-flight asynchronous user operations.
  /// Requires [expectedGeneration] matching this database's [sessionGeneration]
  /// to guarantee that only the decommissioning session can wipe its own database instance.
  Future<void> clearAllUserDataForTeardown({required int expectedGeneration}) async {
    if (sessionGeneration != expectedGeneration) {
      throw StateError(
        'AppDatabase teardown rejected: expected generation $expectedGeneration but database is bound to $sessionGeneration',
      );
    }
    await transaction(() async {
      await delete(activeChats).go();
      await delete(chatMessages).go();
      await delete(signalIdentities).go();
      await delete(signalPreKeys).go();
      await delete(signalSignedPreKeys).go();
      await delete(signalSessions).go();
      await delete(outboxMessages).go();
      try {
        await customStatement('DELETE FROM signal_signed_prekey_metadata;');
      } catch (_) {}
      try {
        await customStatement('DELETE FROM signal_peer_identity_bindings;');
      } catch (_) {}
    });
  }
}

/// Verifies that SQLCipher or SQLite3MultipleCiphers is loaded and applies the encryption key.
/// Throws [UnsupportedError] if encryption is unavailable to prevent silent plaintext fallback.
void setupDatabaseEncryption(dynamic rawDb, String encryptionKey) {
  // Step 1: Mandatory Cipher Verification
  // Detect either SQLCipher (PRAGMA cipher_version;) or SQLite3MultipleCiphers (SELECT sqlite3mc_version(); or PRAGMA cipher;)
  String? detectedEngine;

  // Check SQLCipher PRAGMA cipher_version first
  try {
    final versionRows = rawDb.select('PRAGMA cipher_version;');
    if (versionRows is Iterable && versionRows.isNotEmpty) {
      final firstRow = versionRows.first;
      if (firstRow != null && firstRow.values.isNotEmpty) {
        final val = firstRow.values.first?.toString().trim();
        if (val != null && val.isNotEmpty) {
          detectedEngine = 'SQLCipher v$val';
        }
      }
    }
  } catch (_) {}

  // If not SQLCipher, check SQLite3MultipleCiphers (built into sqlite3 via build hooks)
  if (detectedEngine == null) {
    try {
      final mcRows = rawDb.select('SELECT sqlite3mc_version();');
      if (mcRows is Iterable && mcRows.isNotEmpty) {
        final firstRow = mcRows.first;
        if (firstRow != null && firstRow.values.isNotEmpty) {
          final val = firstRow.values.first?.toString().trim();
          if (val != null && val.isNotEmpty) {
            detectedEngine = val;
          }
        }
      }
    } catch (_) {}
  }

  // Fallback check for SQLite3MC active cipher pragma
  if (detectedEngine == null) {
    try {
      final cipherRows = rawDb.select('PRAGMA cipher;');
      if (cipherRows is Iterable && cipherRows.isNotEmpty) {
        final firstRow = cipherRows.first;
        if (firstRow != null && firstRow.values.isNotEmpty) {
          final val = firstRow.values.first?.toString().trim();
          if (val != null && val.isNotEmpty) {
            detectedEngine = 'SQLite3MC ($val)';
          }
        }
      }
    } catch (_) {}
  }

  if (detectedEngine == null) {
    throw UnsupportedError(
      'FATAL: SQLCipher / SQLite3MC is not available in the runtime environment! '
      'Aborting database open to prevent writing unencrypted data to disk.',
    );
  }

  print('DEBUG: Database encryption verified active ($detectedEngine)');

  // Step 2: Apply the encryption key BEFORE any data or table creation
  final escapedKey = encryptionKey.replaceAll("'", "''");
  rawDb.execute("PRAGMA key = '$escapedKey';");

  // Step 3: Apply memory security and performance pragmas
  try {
    rawDb.execute('PRAGMA cipher_memory_security = ON;');
  } catch (_) {}
  try {
    rawDb.execute('PRAGMA journal_mode = WAL;');
    rawDb.execute('PRAGMA synchronous = NORMAL;');
  } catch (_) {}
}

/// Checks if an existing database file is an unencrypted legacy SQLite database (synchronous).
/// All unencrypted SQLite databases begin with the 16-byte magic ASCII header:
/// "SQLite format 3\000" (83, 81, 76, 105, 116, 101, 32, 102, 111, 114, 109, 97, 116, 32, 51, 0).
bool isLegacyPlaintextDatabaseSync(File file) {
  if (!file.existsSync() || file.lengthSync() < 16) return false;
  try {
    final raf = file.openSync(mode: FileMode.read);
    final headerBytes = raf.readSync(16);
    raf.closeSync();
    const expected = [83, 81, 76, 105, 116, 101, 32, 102, 111, 114, 109, 97, 116, 32, 51, 0];
    if (headerBytes.length < 16) return false;
    for (int i = 0; i < 16; i++) {
      if (headerBytes[i] != expected[i]) return false;
    }
    return true;
  } catch (_) {
    return false;
  }
}

/// Checks if an existing database file is an unencrypted legacy SQLite database.
Future<bool> isLegacyPlaintextDatabase(File file) async {
  return isLegacyPlaintextDatabaseSync(file);
}

/// Automatically migrates an unencrypted legacy database to an encrypted SQLite3MC database
/// using an ATTACH + copy procedure, preserving all existing chats, messages, and cryptographic keys.
/// Upon positive cryptographic verification of the encrypted destination, the unencrypted source
/// files are immediately and permanently deleted to ensure no plaintext copies remain at rest.
/// This function is strictly FAIL-CLOSED: any failure rethrows to halt initialization and avoid leakage.
Future<void> migratePlaintextDatabaseToEncrypted(File file, String encryptionKey) async {
  print('[DATABASE] Legacy plaintext database detected at ${file.path}. Migrating to encrypted SQLite3MC format...');
  final tempEncryptedFile = File('${file.path}.migrating_${DateTime.now().millisecondsSinceEpoch}');
  if (tempEncryptedFile.existsSync()) {
    try { tempEncryptedFile.deleteSync(); } catch (_) {}
  }

  sqlite3_raw.Database? plainDb;
  try {
    plainDb = sqlite3_raw.sqlite3.open(file.path);
    try {
      plainDb.execute('PRAGMA wal_checkpoint(TRUNCATE);');
    } catch (_) {}

    final escapedKey = encryptionKey.replaceAll("'", "''");
    plainDb.execute("ATTACH DATABASE '${tempEncryptedFile.path.replaceAll("'", "''")}' AS enc KEY '$escapedKey';");

    final tables = plainDb.select("SELECT name, sql FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';");
    final originalTableCount = tables.length;
    for (final row in tables) {
      final name = row['name'] as String;
      final sql = row['sql'] as String;
      plainDb.execute(sql.replaceFirst('CREATE TABLE ', 'CREATE TABLE enc.'));
      plainDb.execute('INSERT INTO enc.$name SELECT * FROM main.$name;');
    }

    plainDb.execute("DETACH DATABASE enc;");
    plainDb.dispose();
    plainDb = null;

    // Step 1: Verification-First Protocol
    // Independently open the newly encrypted database with the encryption key to verify its integrity
    sqlite3_raw.Database? verifyDb;
    try {
      verifyDb = sqlite3_raw.sqlite3.open(tempEncryptedFile.path);
      verifyDb.execute("PRAGMA key = '$escapedKey';");
      final verifyTables = verifyDb.select("SELECT count(*) as c FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';");
      final encryptedTableCount = verifyTables.first['c'] as int;
      if (originalTableCount > 0 && encryptedTableCount < originalTableCount) {
        throw StateError('Encrypted database verification failed: expected $originalTableCount tables, found $encryptedTableCount');
      }
      verifyDb.dispose();
      verifyDb = null;
    } catch (verifyErr) {
      if (verifyDb != null) {
        try { verifyDb.dispose(); } catch (_) {}
      }
      throw StateError('Encrypted database verification failed: $verifyErr');
    }

    // Step 2: Permanently delete unencrypted source files (NEVER retain a .plain_bak copy)
    if (file.existsSync()) {
      file.deleteSync();
      if (file.existsSync()) {
        throw StateError('Failed to securely delete plaintext database source file: ${file.path}');
      }
    }
    final walFile = File('${file.path}-wal');
    if (walFile.existsSync()) {
      try { walFile.deleteSync(); } catch (_) {}
    }
    final shmFile = File('${file.path}-shm');
    if (shmFile.existsSync()) {
      try { shmFile.deleteSync(); } catch (_) {}
    }

    // Step 3: Move verified encrypted database into place
    tempEncryptedFile.renameSync(file.path);
    print('[DATABASE] Plaintext database migrated to encrypted database successfully and plaintext source permanently deleted.');
  } catch (e, st) {
    if (plainDb != null) {
      try { plainDb.dispose(); } catch (_) {}
      plainDb = null;
    }
    print('[DATABASE] Error migrating legacy plaintext database: $e\n$st');
    if (tempEncryptedFile.existsSync()) {
      try { tempEncryptedFile.deleteSync(); } catch (_) {}
    }
    // Fail-Closed: Never silently swallow migration failures or allow plaintext DB to fall through to recovery
    throw StateError('Plaintext database migration failed: $e');
  }
}

/// Cleans up any pre-existing plaintext backup files (.plain_bak), legacy corrupt dumps,
/// orphaned migration temporary files, or plaintext unrecoverable files left on the filesystem.
void cleanupResidualDatabaseFiles(File dbFile) {
  try {
    final parentDir = dbFile.parent;
    if (!parentDir.existsSync()) return;

    final baseName = p.basename(dbFile.path);
    final entities = parentDir.listSync();

    for (final entity in entities) {
      if (entity is File) {
        final name = p.basename(entity.path);
        // Clean up legacy plaintext backups, corrupt dumps, or aborted migration temps
        if (name.startsWith('$baseName.plain_bak') ||
            name.startsWith('$baseName.corrupt_') ||
            name.startsWith('$baseName.migrating_')) {
          try {
            entity.deleteSync();
            print('[DATABASE] Sanitized residual plaintext/temporary file: ${entity.path}');
          } catch (_) {}
        } else if (name.startsWith('$baseName.unrecoverable_')) {
          // If an unrecoverable dump contains an unencrypted SQLite plaintext header, purge it immediately
          if (isLegacyPlaintextDatabaseSync(entity)) {
            try {
              entity.deleteSync();
              print('[DATABASE] Sanitized legacy plaintext unrecoverable file: ${entity.path}');
            } catch (_) {}
          }
        }
      }
    }
  } catch (e) {
    print('[DATABASE] Note: Error during residual file cleanup: $e');
  }
}

/// Verifies that an existing database file can be decrypted with [encryptionKey].
/// If the file is corrupt or key was lost/invalid (causing SQLITE_NOTADB code 26),
/// the unreadable file is backed up and removed so the database can initialize cleanly.
/// IMPORTANT: This function will NEVER rename or preserve an unencrypted plaintext database.
void verifyOrRecoverEncryptedDatabase(File file, String encryptionKey) {
  if (!file.existsSync() || file.lengthSync() == 0) return;

  // Strict Anti-Plaintext Guard: Refuse to process an unencrypted plaintext database as an unrecoverable corrupted file.
  // Plaintext databases must never be renamed to .unrecoverable_* as that creates a plaintext leak at rest.
  if (isLegacyPlaintextDatabaseSync(file)) {
    throw StateError(
      'Plaintext database detected in encrypted recovery path for ${file.path}. '
      'Aborting to prevent unencrypted data retention.',
    );
  }

  sqlite3_raw.Database? testDb;
  try {
    testDb = sqlite3_raw.sqlite3.open(file.path);
    final escapedKey = encryptionKey.replaceAll("'", "''");
    testDb.execute("PRAGMA key = '$escapedKey';");
    testDb.select('SELECT count(*) FROM sqlite_master;');
    testDb.dispose();
    testDb = null;
  } catch (e) {
    if (testDb != null) {
      try { testDb.dispose(); } catch (_) {}
      testDb = null;
    }
    print('[DATABASE] Corrupt or unopenable database detected at ${file.path}: $e');
    // Double-check: ensure file is NOT plaintext before backing up
    if (isLegacyPlaintextDatabaseSync(file)) {
      throw StateError(
        'Refusing to rename unencrypted database to .unrecoverable_*: ${file.path}',
      );
    }
    try {
      final unrecoverableFile = File('${file.path}.unrecoverable_${DateTime.now().millisecondsSinceEpoch}');
      file.renameSync(unrecoverableFile.path);
      final walFile = File('${file.path}-wal');
      if (walFile.existsSync()) {
        try { walFile.deleteSync(); } catch (_) {}
      }
      final shmFile = File('${file.path}-shm');
      if (shmFile.existsSync()) {
        try { shmFile.deleteSync(); } catch (_) {}
      }
      print('[DATABASE] Preserved corrupt encrypted database as ${unrecoverableFile.path}. Initializing fresh database.');
    } catch (renameErr) {
      print('[DATABASE] Could not preserve corrupt database: $renameErr');
    }
  }
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dbFolder = await getApplicationDocumentsDirectory();
    const instance = String.fromEnvironment('INSTANCE', defaultValue: '1');
    final file = File(p.join(dbFolder.path, 'aisat_connect_$instance.sqlite'));
    
    final secureStorage = const FlutterSecureStorage();
    String? encryptionKey = await secureStorage.read(key: 'db_encryption_key_$instance');
    
    if (encryptionKey == null) {
      // Generate a new secure key (32 bytes = 256 bits)
      final random = dart_math.Random.secure();
      final keyBytes = List<int>.generate(32, (i) => random.nextInt(256));
      encryptionKey = base64UrlEncode(keyBytes);
      await secureStorage.write(key: 'db_encryption_key_$instance', value: encryptionKey);
    }

    // Step 0: Clean up any legacy plaintext backup files or aborted migration remnants
    cleanupResidualDatabaseFiles(file);

    // Step 1: Detect legacy unencrypted plaintext database and migrate it seamlessly
    if (await isLegacyPlaintextDatabase(file)) {
      await migratePlaintextDatabaseToEncrypted(file, encryptionKey);
      if (await isLegacyPlaintextDatabase(file)) {
        throw StateError('Fatal: Legacy database is still unencrypted plaintext after migration: ${file.path}');
      }
    }

    // Step 2: Pre-flight verify that the database can be decrypted with the active key
    verifyOrRecoverEncryptedDatabase(file, encryptionKey);

    return NativeDatabase.createInBackground(file, setup: (db) {
      setupDatabaseEncryption(db, encryptionKey!);
    });
  });
}

class _DuplicateRepairPlanItem {
  final int rowId;
  final String originalId;
  final String freshId;
  final String peer;
  final bool isMe;
  final int timestamp;
  final String messageText;

  _DuplicateRepairPlanItem({
    required this.rowId,
    required this.originalId,
    required this.freshId,
    required this.peer,
    required this.isMe,
    required this.timestamp,
    required this.messageText,
  });
}


