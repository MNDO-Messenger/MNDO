import 'dart:typed_data';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import '../database/database.dart';
import 'package:drift/drift.dart' as drift;

class SignalStore implements SignalProtocolStore {
  final AppDatabase db;
  final IdentityKeyPair localIdentityKeyPair;
  final int localRegistrationId;

  SignalStore(this.db, this.localIdentityKeyPair, this.localRegistrationId);

  // IdentityKeyStore Implementation
  @override
  Future<IdentityKeyPair> getIdentityKeyPair() async => localIdentityKeyPair;

  @override
  Future<int> getLocalRegistrationId() async => localRegistrationId;

  @override
  Future<bool> saveIdentity(SignalProtocolAddress address, IdentityKey? identityKey) async {
    if (identityKey == null) return false;
    await db.into(db.signalIdentities).insertOnConflictUpdate(
      SignalIdentitiesCompanion(
        address: drift.Value(address.toString()),
        identityKey: drift.Value(identityKey.serialize()),
      )
    );
    return true;
  }

  @override
  Future<bool> isTrustedIdentity(SignalProtocolAddress address, IdentityKey? identityKey, Direction direction) async {
    if (identityKey == null) return false;
    final records = await (db.select(db.signalIdentities)..where((t) => t.address.equals(address.toString()))).get();
    if (records.isEmpty) {
      return true; // Trust on first use
    }
    final existingIdentity = IdentityKey.fromBytes(records.first.identityKey, 0);
    return existingIdentity == identityKey;
  }

  @override
  Future<IdentityKey?> getIdentity(SignalProtocolAddress address) async {
    final records = await (db.select(db.signalIdentities)..where((t) => t.address.equals(address.toString()))).get();
    if (records.isEmpty) return null;
    return IdentityKey.fromBytes(records.first.identityKey, 0);
  }

  // PreKeyStore Implementation
  @override
  Future<PreKeyRecord> loadPreKey(int preKeyId) async {
    final records = await (db.select(db.signalPreKeys)..where((t) => t.preKeyId.equals(preKeyId))).get();
    if (records.isEmpty) throw InvalidKeyIdException('No such prekeyRecord!');
    return PreKeyRecord.fromBuffer(records.first.record);
  }

  Future<int> getPreKeyCount() async {
    return await db.getPreKeyCount();
  }

  Future<int> getMaxPreKeyId() async {
    return await db.getMaxPreKeyId();
  }

  Future<List<PreKeyRecord>> getAllPreKeys() async {
    final records = await db.getAllPreKeys();
    return records.map((r) => PreKeyRecord.fromBuffer(r.record)).toList();
  }

  @override
  Future<void> storePreKey(int preKeyId, PreKeyRecord record) async {
    await db.into(db.signalPreKeys).insertOnConflictUpdate(
      SignalPreKeysCompanion(
        preKeyId: drift.Value(preKeyId),
        record: drift.Value(record.serialize()),
      )
    );
  }

  @override
  Future<bool> containsPreKey(int preKeyId) async {
    final count = await (db.select(db.signalPreKeys)..where((t) => t.preKeyId.equals(preKeyId))).get();
    return count.isNotEmpty;
  }

  @override
  Future<void> removePreKey(int preKeyId) async {
    await (db.delete(db.signalPreKeys)..where((t) => t.preKeyId.equals(preKeyId))).go();
  }

  // SignedPreKeyStore Implementation
  @override
  Future<SignedPreKeyRecord> loadSignedPreKey(int signedPreKeyId) async {
    final records = await (db.select(db.signalSignedPreKeys)..where((t) => t.signedPreKeyId.equals(signedPreKeyId))).get();
    if (records.isEmpty) throw InvalidKeyIdException('No such signed prekey');
    return SignedPreKeyRecord.fromSerialized(records.first.record);
  }

  @override
  Future<List<SignedPreKeyRecord>> loadSignedPreKeys() async {
    final records = await db.select(db.signalSignedPreKeys).get();
    return records.map((r) => SignedPreKeyRecord.fromSerialized(r.record)).toList();
  }

  @override
  Future<void> storeSignedPreKey(int signedPreKeyId, SignedPreKeyRecord record) async {
    await db.into(db.signalSignedPreKeys).insertOnConflictUpdate(
      SignalSignedPreKeysCompanion(
        signedPreKeyId: drift.Value(signedPreKeyId),
        record: drift.Value(record.serialize()),
      )
    );
  }

  @override
  Future<bool> containsSignedPreKey(int signedPreKeyId) async {
    final count = await (db.select(db.signalSignedPreKeys)..where((t) => t.signedPreKeyId.equals(signedPreKeyId))).get();
    return count.isNotEmpty;
  }

  @override
  Future<void> removeSignedPreKey(int signedPreKeyId) async {
    await (db.delete(db.signalSignedPreKeys)..where((t) => t.signedPreKeyId.equals(signedPreKeyId))).go();
  }

  // SessionStore Implementation
  @override
  Future<SessionRecord> loadSession(SignalProtocolAddress address) async {
    final records = await (db.select(db.signalSessions)..where((t) => t.address.equals(address.toString()))).get();
    if (records.isEmpty) return SessionRecord();
    return SessionRecord.fromSerialized(records.first.record);
  }

  @override
  Future<List<int>> getSubDeviceSessions(String name) async {
    return []; // We do not support multiple devices with the same name right now
  }

  @override
  Future<void> storeSession(SignalProtocolAddress address, SessionRecord record) async {
    await db.into(db.signalSessions).insertOnConflictUpdate(
      SignalSessionsCompanion(
        address: drift.Value(address.toString()),
        record: drift.Value(record.serialize()),
      )
    );
  }

  @override
  Future<bool> containsSession(SignalProtocolAddress address) async {
    final records = await (db.select(db.signalSessions)..where((t) => t.address.equals(address.toString()))).get();
    return records.isNotEmpty;
  }

  @override
  Future<void> deleteSession(SignalProtocolAddress address) async {
    await (db.delete(db.signalSessions)..where((t) => t.address.equals(address.toString()))).go();
  }

  @override
  Future<void> deleteAllSessions(String name) async {
    await (db.delete(db.signalSessions)..where((t) => t.address.like('$name%'))).go();
  }

  // SenderKeyStore Implementation (not used in direct 1:1 messaging)
  Future<void> storeSenderKey(SignalProtocolAddress sender, String distributionId, SenderKeyRecord record) async {}
  Future<SenderKeyRecord> loadSenderKey(SignalProtocolAddress sender, String distributionId) async {
    return SenderKeyRecord();
  }

  Future<void> clearStore() async {
    await db.delete(db.signalIdentities).go();
    await db.delete(db.signalPreKeys).go();
    await db.delete(db.signalSignedPreKeys).go();
    await db.delete(db.signalSessions).go();
  }
}
