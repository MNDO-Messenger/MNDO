import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:convert';
import 'dart:math' as dart_math;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;

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
  TextColumn get nostrPubKeyHex => text()();
  TextColumn get messageText => text()();
  BoolColumn get isMe => boolean()();
  DateTimeColumn get timestamp => dateTime()();
}

@DriftDatabase(tables: [ActiveChats, ChatMessages, SignalIdentities, SignalPreKeys, SignalSignedPreKeys, SignalSessions])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
    },
    onUpgrade: (m, from, to) async {
      if (from == 1) {
        await m.addColumn(activeChats, activeChats.displayName);
        await m.addColumn(activeChats, activeChats.bio);
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
  
  Future<DateTime?> getLatestMessageTimestamp() async {
    final query = select(chatMessages)
      ..orderBy([(t) => OrderingTerm(expression: t.timestamp, mode: OrderingMode.desc)])
      ..limit(1);
    final result = await query.getSingleOrNull();
    return result?.timestamp;
  }

  Future<void> clearAllUserData() async {
    await clearChats();
    await clearMessages();
    await clearSignalData();
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

    return NativeDatabase.createInBackground(file, setup: (db) {
      final escapedKey = encryptionKey!.replaceAll("'", "''");
      db.execute("PRAGMA key = '$escapedKey';");
      try {
        db.execute("PRAGMA cipher_memory_security = ON;");
      } catch (_) {}
      try {
        db.execute("PRAGMA journal_mode = WAL;");
        db.execute("PRAGMA synchronous = NORMAL;");
      } catch (_) {}
    });
  });
}

