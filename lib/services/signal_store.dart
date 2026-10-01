import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import '../database/database.dart';
import 'package:drift/drift.dart' as drift;
import 'account_session.dart';

class SignalStore implements SignalProtocolStore {
  final AppDatabase db;
  final IdentityKeyPair localIdentityKeyPair;
  final int localRegistrationId;
  final int sessionGeneration;

  SignalStore(
    this.db, 
    this.localIdentityKeyPair, 
    this.localRegistrationId, {
    int? sessionGeneration,
  }) : sessionGeneration = sessionGeneration ?? AccountSession.currentGeneration;

  void _ensureActive() {
    if (!AccountSession.isGenerationValid(sessionGeneration)) {
      throw StateError(
        'SignalStore operation aborted: stale session generation $sessionGeneration (active: ${AccountSession.currentGeneration})'
      );
    }
  }

  // IdentityKeyStore Implementation
  @override
  Future<IdentityKeyPair> getIdentityKeyPair() async {
    _ensureActive();
    return localIdentityKeyPair;
  }

  @override
  Future<int> getLocalRegistrationId() async {
    _ensureActive();
    return localRegistrationId;
  }

  @override
  Future<bool> saveIdentity(SignalProtocolAddress address, IdentityKey? identityKey) async {
    _ensureActive();
    if (identityKey == null) return false;
    await db.into(db.signalIdentities).insertOnConflictUpdate(
      SignalIdentitiesCompanion(
        address: drift.Value(address.toString()),
        identityKey: drift.Value(identityKey.serialize()),
      )
    );
    _ensureActive();
    return true;
  }

  @override
  Future<bool> isTrustedIdentity(SignalProtocolAddress address, IdentityKey? identityKey, Direction direction) async {
    _ensureActive();
    if (identityKey == null) return false;
    final records = await (db.select(db.signalIdentities)..where((t) => t.address.equals(address.toString()))).get();
    _ensureActive();
    if (records.isEmpty) {
      return true; // Trust on first use
    }
    final existingIdentity = IdentityKey.fromBytes(records.first.identityKey, 0);
    return existingIdentity == identityKey;
  }

  @override
  Future<IdentityKey?> getIdentity(SignalProtocolAddress address) async {
    _ensureActive();
    final records = await (db.select(db.signalIdentities)..where((t) => t.address.equals(address.toString()))).get();
    _ensureActive();
    if (records.isEmpty) return null;
    return IdentityKey.fromBytes(records.first.identityKey, 0);
  }

  // PreKeyStore Implementation
  @override
  Future<PreKeyRecord> loadPreKey(int preKeyId) async {
    _ensureActive();
    final records = await (db.select(db.signalPreKeys)..where((t) => t.preKeyId.equals(preKeyId))).get();
    _ensureActive();
    if (records.isEmpty) throw InvalidKeyIdException('No such prekeyRecord!');
    return PreKeyRecord.fromBuffer(records.first.record);
  }

  Future<int> getPreKeyCount() async {
    _ensureActive();
    final res = await db.getPreKeyCount();
    _ensureActive();
    return res;
  }

  Future<int> getMaxPreKeyId() async {
    _ensureActive();
    final res = await db.getMaxPreKeyId();
    _ensureActive();
    return res;
  }

  Future<List<PreKeyRecord>> getAllPreKeys() async {
    _ensureActive();
    final records = await db.getAllPreKeys();
    _ensureActive();
    return records.map((r) => PreKeyRecord.fromBuffer(r.record)).toList();
  }

  @override
  Future<void> storePreKey(int preKeyId, PreKeyRecord record) async {
    _ensureActive();
    await db.into(db.signalPreKeys).insertOnConflictUpdate(
      SignalPreKeysCompanion(
        preKeyId: drift.Value(preKeyId),
        record: drift.Value(record.serialize()),
      )
    );
    _ensureActive();
  }

  @override
  Future<bool> containsPreKey(int preKeyId) async {
    _ensureActive();
    final count = await (db.select(db.signalPreKeys)..where((t) => t.preKeyId.equals(preKeyId))).get();
    _ensureActive();
    return count.isNotEmpty;
  }

  @override
  Future<void> removePreKey(int preKeyId) async {
    _ensureActive();
    await (db.delete(db.signalPreKeys)..where((t) => t.preKeyId.equals(preKeyId))).go();
    _ensureActive();
  }

  // SignedPreKeyStore Implementation
  @override
  Future<SignedPreKeyRecord> loadSignedPreKey(int signedPreKeyId) async {
    _ensureActive();
    final records = await (db.select(db.signalSignedPreKeys)..where((t) => t.signedPreKeyId.equals(signedPreKeyId))).get();
    _ensureActive();
    if (records.isEmpty) throw InvalidKeyIdException('No such signed prekey');
    return SignedPreKeyRecord.fromSerialized(records.first.record);
  }

  @override
  Future<List<SignedPreKeyRecord>> loadSignedPreKeys() async {
    _ensureActive();
    final records = await db.select(db.signalSignedPreKeys).get();
    _ensureActive();
    return records.map((r) => SignedPreKeyRecord.fromSerialized(r.record)).toList();
  }

  @override
  Future<void> storeSignedPreKey(int signedPreKeyId, SignedPreKeyRecord record) async {
    _ensureActive();
    await db.into(db.signalSignedPreKeys).insertOnConflictUpdate(
      SignalSignedPreKeysCompanion(
        signedPreKeyId: drift.Value(signedPreKeyId),
        record: drift.Value(record.serialize()),
      )
    );
    _ensureActive();
  }

  @override
  Future<bool> containsSignedPreKey(int signedPreKeyId) async {
    _ensureActive();
    final count = await (db.select(db.signalSignedPreKeys)..where((t) => t.signedPreKeyId.equals(signedPreKeyId))).get();
    _ensureActive();
    return count.isNotEmpty;
  }

  @override
  Future<void> removeSignedPreKey(int signedPreKeyId) async {
    _ensureActive();
    await (db.delete(db.signalSignedPreKeys)..where((t) => t.signedPreKeyId.equals(signedPreKeyId))).go();
    _ensureActive();
  }

  // SessionStore Implementation
  @override
  Future<SessionRecord> loadSession(SignalProtocolAddress address) async {
    _ensureActive();
    final records = await (db.select(db.signalSessions)..where((t) => t.address.equals(address.toString()))).get();
    _ensureActive();
    if (records.isEmpty) return SessionRecord();
    return SessionRecord.fromSerialized(records.first.record);
  }

  @override
  Future<List<int>> getSubDeviceSessions(String name) async {
    _ensureActive();
    return []; // We do not support multiple devices with the same name right now
  }

  @override
  Future<void> storeSession(SignalProtocolAddress address, SessionRecord record) async {
    _ensureActive();
    await db.into(db.signalSessions).insertOnConflictUpdate(
      SignalSessionsCompanion(
        address: drift.Value(address.toString()),
        record: drift.Value(record.serialize()),
      )
    );
    _ensureActive();
  }

  @override
  Future<bool> containsSession(SignalProtocolAddress address) async {
    _ensureActive();
    final records = await (db.select(db.signalSessions)..where((t) => t.address.equals(address.toString()))).get();
    _ensureActive();
    return records.isNotEmpty;
  }

  @override
  Future<void> deleteSession(SignalProtocolAddress address) async {
    _ensureActive();
    await (db.delete(db.signalSessions)..where((t) => t.address.equals(address.toString()))).go();
    _ensureActive();
  }

  @override
  Future<void> deleteAllSessions(String name) async {
    _ensureActive();
    await (db.delete(db.signalSessions)..where((t) => t.address.like('$name%'))).go();
    _ensureActive();
  }

  // SenderKeyStore Implementation (not used in direct 1:1 messaging)
  Future<void> storeSenderKey(SignalProtocolAddress sender, String distributionId, SenderKeyRecord record) async {
    _ensureActive();
  }
  
  Future<SenderKeyRecord> loadSenderKey(SignalProtocolAddress sender, String distributionId) async {
    _ensureActive();
    return SenderKeyRecord();
  }

  Future<void> clearStore() async {
    _ensureActive();
    await db.delete(db.signalIdentities).go();
    await db.delete(db.signalPreKeys).go();
    await db.delete(db.signalSignedPreKeys).go();
    await db.delete(db.signalSessions).go();
    _ensureActive();
  }
}
