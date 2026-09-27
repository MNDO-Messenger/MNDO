import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:convert';
import 'dart:math' as dart_math;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite3_raw;

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
  TextColumn get messageId => text().nullable()();
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
  TextColumn get status => text().withDefault(const Constant('pending'))();

  @override
  Set<Column> get primaryKey => {messageId};
}

@DriftDatabase(tables: [ActiveChats, ChatMessages, SignalIdentities, SignalPreKeys, SignalSignedPreKeys, SignalSessions, OutboxMessages])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  @override
  int get schemaVersion => 4;

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
        await m.addColumn(chatMessages, chatMessages.messageId);
        await m.addColumn(chatMessages, chatMessages.status);
        await m.addColumn(chatMessages, chatMessages.replyToId);
      }
      if (from < 4) {
        await m.createTable(outboxMessages);
      }
    },
  );

  // Active Chats Queries
  Future<List<ActiveChatRecord>> getAllChats() => select(activeChats).get();
  Future<void> insertChat(Insertable<ActiveChatRecord> chat) => into(activeChats).insertOnConflictUpdate(chat);
  Future<void> clearChats() => delete(activeChats).go();

  // Signal Queries
  Future<int> getPreKeyCount() async {
    final countExp = signalPreKeys.preKeyId.count();
    final query = selectOnly(signalPreKeys)..addColumns([countExp]);
    final result = await query.getSingle();
    return result.read(countExp) ?? 0;
  }

  Future<int> getMaxPreKeyId() async {
    final maxExp = signalPreKeys.preKeyId.max();
    final query = selectOnly(signalPreKeys)..addColumns([maxExp]);
    final result = await query.getSingle();
    return result.read(maxExp) ?? 0;
  }

  Future<List<SignalPreKeyRecord>> getAllPreKeys() => select(signalPreKeys).get();

  Future<void> clearSignalData() async {
    await delete(signalIdentities).go();
    await delete(signalPreKeys).go();
    await delete(signalSignedPreKeys).go();
    await delete(signalSessions).go();
  }

  // Chat Messages Queries
  Future<List<ChatMessageRecord>> getMessagesForChat(String nostrPubKey) {
    return (select(chatMessages)
      ..where((t) => t.nostrPubKeyHex.equals(nostrPubKey))
      ..orderBy([(t) => OrderingTerm(expression: t.timestamp, mode: OrderingMode.asc)])
    ).get();
  }
  Future<void> insertMessage(Insertable<ChatMessageRecord> msg) => into(chatMessages).insert(msg);
  Future<void> clearMessages() => delete(chatMessages).go();
  
  Future<ChatMessageRecord?> getMessageByMessageId(String messageId) {
    return (select(chatMessages)..where((t) => t.messageId.equals(messageId))).getSingleOrNull();
  }

  Future<void> updateMessageStatus(String messageId, String newStatus) {
    return (update(chatMessages)..where((t) => t.messageId.equals(messageId)))
        .write(ChatMessagesCompanion(status: Value(newStatus)));
  }

  Future<int> markMessagesReadUpTo(String peerNostrPubKey, DateTime timestamp) {
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
    final query = select(chatMessages)
      ..orderBy([(t) => OrderingTerm(expression: t.timestamp, mode: OrderingMode.desc)])
      ..limit(1);
    final result = await query.getSingleOrNull();
    return result?.timestamp;
  }

  // Outbox Queries
  Future<List<OutboxRecord>> getPendingOutboxMessages() {
    return (select(outboxMessages)
      ..where((t) => t.status.isNotIn(['delivered', 'read']))
      ..orderBy([(t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.asc)])
    ).get();
  }

  Future<List<OutboxRecord>> getUndeliveredMessagesForPeer(String recipientNostrPubKey) {
    return (select(outboxMessages)
      ..where((t) => t.recipientNostrPubKey.equals(recipientNostrPubKey) & t.status.isNotIn(['delivered', 'read']))
      ..orderBy([(t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.asc)])
    ).get();
  }

  Future<void> enqueueOutboxMessage(Insertable<OutboxRecord> record) =>
      into(outboxMessages).insertOnConflictUpdate(record);

  Future<void> deleteOutboxMessage(String messageId) =>
      (delete(outboxMessages)..where((t) => t.messageId.equals(messageId))).go();

  Future<void> updateOutboxAttempt(
    String messageId, {
    required int attempts,
    required DateTime lastAttemptAt,
    required String status,
  }) {
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
    return (update(outboxMessages)..where((t) => t.messageId.equals(messageId))).write(
      OutboxMessagesCompanion(
        status: Value(status),
        attempts: attempts != null ? Value(attempts) : const Value.absent(),
        lastAttemptAt: lastAttemptAt != null ? Value(lastAttemptAt) : const Value.absent(),
      ),
    );
  }

  Future<OutboxRecord?> getOutboxMessage(String messageId) {
    return (select(outboxMessages)..where((t) => t.messageId.equals(messageId))).getSingleOrNull();
  }

  Future<void> clearOutbox() => delete(outboxMessages).go();

  Future<void> clearAllUserData() async {
    await clearChats();
    await clearMessages();
    await clearSignalData();
    await clearOutbox();
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

/// Checks if an existing database file is an unencrypted legacy SQLite database.
/// All unencrypted SQLite databases begin with the 16-byte magic ASCII header:
/// "SQLite format 3\000" (83, 81, 76, 105, 116, 101, 32, 102, 111, 114, 109, 97, 116, 32, 51, 0).
Future<bool> isLegacyPlaintextDatabase(File file) async {
  if (!file.existsSync() || file.lengthSync() < 16) return false;
  try {
    final raf = await file.open(mode: FileMode.read);
    final headerBytes = await raf.read(16);
    await raf.close();
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

/// Automatically migrates an unencrypted legacy database to an encrypted SQLite3MC database
/// using an ATTACH + copy procedure, preserving all existing chats, messages, and cryptographic keys.
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
    for (final row in tables) {
      final name = row['name'] as String;
      final sql = row['sql'] as String;
      plainDb.execute(sql.replaceFirst('CREATE TABLE ', 'CREATE TABLE enc.'));
      plainDb.execute('INSERT INTO enc.$name SELECT * FROM main.$name;');
    }

    plainDb.execute("DETACH DATABASE enc;");
    plainDb.dispose();
    plainDb = null;

    // Preserve plaintext backup
    final backupFile = File('${file.path}.plain_bak');
    if (backupFile.existsSync()) {
      try { backupFile.deleteSync(); } catch (_) {}
    }
    file.renameSync(backupFile.path);

    // Clean up old wal and shm files
    final walFile = File('${file.path}-wal');
    if (walFile.existsSync()) {
      try { walFile.deleteSync(); } catch (_) {}
    }
    final shmFile = File('${file.path}-shm');
    if (shmFile.existsSync()) {
      try { shmFile.deleteSync(); } catch (_) {}
    }

    // Move newly encrypted database into place
    tempEncryptedFile.renameSync(file.path);
    print('[DATABASE] Plaintext database migrated to encrypted database successfully!');
  } catch (e, st) {
    if (plainDb != null) {
      try { plainDb.dispose(); } catch (_) {}
      plainDb = null;
    }
    print('[DATABASE] Error migrating legacy plaintext database: $e\n$st');
    if (tempEncryptedFile.existsSync()) {
      try { tempEncryptedFile.deleteSync(); } catch (_) {}
    }
    // If migration failed due to corrupt plaintext, backup corrupt file to unblock initialization
    try {
      final corruptFile = File('${file.path}.corrupt_${DateTime.now().millisecondsSinceEpoch}');
      file.renameSync(corruptFile.path);
      final walFile = File('${file.path}-wal');
      if (walFile.existsSync()) {
        try { walFile.deleteSync(); } catch (_) {}
      }
      final shmFile = File('${file.path}-shm');
      if (shmFile.existsSync()) {
        try { shmFile.deleteSync(); } catch (_) {}
      }
      print('[DATABASE] Backed up corrupted database file to ${corruptFile.path}');
    } catch (_) {}
  }
}

/// Verifies that an existing database file can be decrypted with [encryptionKey].
/// If the file is corrupt or key was lost/invalid (causing SQLITE_NOTADB code 26),
/// the unreadable file is backed up and removed so the database can initialize cleanly.
void verifyOrRecoverEncryptedDatabase(File file, String encryptionKey) {
  if (!file.existsSync() || file.lengthSync() == 0) return;
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
      print('[DATABASE] Preserved corrupt database as ${unrecoverableFile.path}. Initializing fresh database.');
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

    // Step 1: Detect legacy unencrypted plaintext database and migrate it seamlessly
    if (await isLegacyPlaintextDatabase(file)) {
      await migratePlaintextDatabaseToEncrypted(file, encryptionKey);
    }

    // Step 2: Pre-flight verify that the database can be decrypted with the active key
    verifyOrRecoverEncryptedDatabase(file, encryptionKey);

    return NativeDatabase.createInBackground(file, setup: (db) {
      setupDatabaseEncryption(db, encryptionKey!);
    });
  });
}


