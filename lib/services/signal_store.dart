import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import '../database/database.dart';
import '../models/verified_peer_identity.dart';
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
    try {
      await db.customStatement(
        'DELETE FROM signal_signed_prekey_metadata WHERE id = ?;',
        [signedPreKeyId],
      );
    } catch (_) {}
    _ensureActive();
  }

  Future<void> _ensureMetadataTable() async {
    _ensureActive();
    await db.customStatement('''
      CREATE TABLE IF NOT EXISTS signal_signed_prekey_metadata (
        id INTEGER PRIMARY KEY,
        status TEXT NOT NULL DEFAULT 'current',
        retired_at INTEGER
      );
    ''');
    try {
      final info = await db.customSelect('PRAGMA table_info(signal_signed_prekey_metadata);').get();
      final hasStatus = info.any((row) => row.read<String>('name') == 'status');
      if (!hasStatus) {
        await db.customStatement('ALTER TABLE signal_signed_prekey_metadata ADD COLUMN status TEXT NOT NULL DEFAULT "retired";');
      }
    } catch (_) {}
  }

  /// Sets the Signed PreKey as the active CURRENT key.
  Future<void> setCurrentSignedPreKeyId(int signedPreKeyId) async {
    _ensureActive();
    await _ensureMetadataTable();
    await db.customInsert(
      'INSERT OR REPLACE INTO signal_signed_prekey_metadata (id, status, retired_at) VALUES (?, ?, NULL);',
      variables: [
        drift.Variable.withInt(signedPreKeyId),
        drift.Variable.withString('current'),
      ],
    );
    _ensureActive();
  }

  /// Retrieves the ID of the CURRENT Signed PreKey, or null if not explicitly set.
  Future<int?> getCurrentSignedPreKeyId() async {
    _ensureActive();
    await _ensureMetadataTable();
    final rows = await db.customSelect(
      "SELECT id FROM signal_signed_prekey_metadata WHERE status = 'current' ORDER BY id DESC LIMIT 1;",
    ).get();
    _ensureActive();
    if (rows.isNotEmpty) {
      return rows.first.read<int>('id');
    }
    return null;
  }

  /// Sets the Signed PreKey status to PENDING (generated candidate awaiting broadcast confirmation).
  Future<void> setSignedPreKeyPending(int signedPreKeyId) async {
    _ensureActive();
    await _ensureMetadataTable();
    await db.customInsert(
      'INSERT OR REPLACE INTO signal_signed_prekey_metadata (id, status, retired_at) VALUES (?, ?, NULL);',
      variables: [
        drift.Variable.withInt(signedPreKeyId),
        drift.Variable.withString('pending'),
      ],
    );
    _ensureActive();
  }

  /// Retrieves the lifecycle status of a Signed PreKey ('pending', 'current', or 'retired').
  Future<String?> getSignedPreKeyStatus(int signedPreKeyId) async {
    _ensureActive();
    await _ensureMetadataTable();
    final rows = await db.customSelect(
      'SELECT status FROM signal_signed_prekey_metadata WHERE id = ?;',
      variables: [drift.Variable.withInt(signedPreKeyId)],
    ).get();
    _ensureActive();
    if (rows.isEmpty) return null;
    return rows.first.read<String>('status');
  }

  /// Explicitly marks a Signed PreKey as retired/superseded at rotation time (AC-03).
  Future<void> markSignedPreKeyRetired(int signedPreKeyId, DateTime retiredAt) async {
    _ensureActive();
    await _ensureMetadataTable();
    await db.customInsert(
      'INSERT OR REPLACE INTO signal_signed_prekey_metadata (id, status, retired_at) VALUES (?, ?, ?);',
      variables: [
        drift.Variable.withInt(signedPreKeyId),
        drift.Variable.withString('retired'),
        drift.Variable.withInt(retiredAt.millisecondsSinceEpoch),
      ],
    );
    _ensureActive();
  }

  /// Retrieves the retirement timestamp of a Signed PreKey, or null if not yet retired.
  Future<DateTime?> getSignedPreKeyRetiredAt(int signedPreKeyId) async {
    _ensureActive();
    await _ensureMetadataTable();
    final rows = await db.customSelect(
      'SELECT retired_at FROM signal_signed_prekey_metadata WHERE id = ? AND retired_at IS NOT NULL;',
      variables: [drift.Variable.withInt(signedPreKeyId)],
    ).get();
    _ensureActive();
    if (rows.isEmpty) return null;
    final ms = rows.first.read<int?>('retired_at');
    if (ms == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(ms);
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

  Future<void> _ensurePeerBindingsTable() async {
    _ensureActive();
    await db.customStatement('''
      CREATE TABLE IF NOT EXISTS signal_peer_identity_bindings (
        nostr_pub_key TEXT PRIMARY KEY,
        master_pub_key TEXT NOT NULL,
        signal_identity_key TEXT NOT NULL,
        verified_at INTEGER NOT NULL,
        session_generation INTEGER NOT NULL
      );
    ''');
    _ensureActive();
  }

  Future<void> saveVerifiedPeerIdentity(VerifiedPeerIdentity identity) async {
    _ensureActive();
    await _ensurePeerBindingsTable();
    await db.customStatement('''
      INSERT INTO signal_peer_identity_bindings (
        nostr_pub_key, master_pub_key, signal_identity_key, verified_at, session_generation
      ) VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(nostr_pub_key) DO UPDATE SET
        master_pub_key = excluded.master_pub_key,
        signal_identity_key = excluded.signal_identity_key,
        verified_at = excluded.verified_at,
        session_generation = excluded.session_generation;
    ''', [
      identity.nostrPubKeyHex,
      identity.masterPubKeyHex,
      identity.signalIdentityKeyBase64,
      identity.verifiedAt.millisecondsSinceEpoch,
      identity.sessionGeneration,
    ]);
    _ensureActive();
  }

  Future<VerifiedPeerIdentity?> getVerifiedPeerIdentity(String nostrPubKeyHex) async {
    _ensureActive();
    await _ensurePeerBindingsTable();
    final rows = await db.customSelect(
      'SELECT nostr_pub_key, master_pub_key, signal_identity_key, verified_at, session_generation FROM signal_peer_identity_bindings WHERE nostr_pub_key = ?;',
      variables: [drift.Variable.withString(nostrPubKeyHex)],
    ).get();
    _ensureActive();
    if (rows.isEmpty) return null;
    final row = rows.first;
    return VerifiedPeerIdentity(
      nostrPubKeyHex: row.read<String>('nostr_pub_key'),
      masterPubKeyHex: row.read<String>('master_pub_key'),
      signalIdentityKeyBase64: row.read<String>('signal_identity_key'),
      verifiedAt: DateTime.fromMillisecondsSinceEpoch(row.read<int>('verified_at')),
      sessionGeneration: row.read<int>('session_generation'),
    );
  }

  Future<void> deleteVerifiedPeerIdentity(String nostrPubKeyHex) async {
    _ensureActive();
    await _ensurePeerBindingsTable();
    await db.customStatement(
      'DELETE FROM signal_peer_identity_bindings WHERE nostr_pub_key = ?;',
      [nostrPubKeyHex],
    );
    _ensureActive();
  }

  Future<List<VerifiedPeerIdentity>> getAllVerifiedPeerIdentities() async {
    _ensureActive();
    await _ensurePeerBindingsTable();
    final rows = await db.customSelect(
      'SELECT nostr_pub_key, master_pub_key, signal_identity_key, verified_at, session_generation FROM signal_peer_identity_bindings;',
    ).get();
    _ensureActive();
    return rows.map((row) => VerifiedPeerIdentity(
      nostrPubKeyHex: row.read<String>('nostr_pub_key'),
      masterPubKeyHex: row.read<String>('master_pub_key'),
      signalIdentityKeyBase64: row.read<String>('signal_identity_key'),
      verifiedAt: DateTime.fromMillisecondsSinceEpoch(row.read<int>('verified_at')),
      sessionGeneration: row.read<int>('session_generation'),
    )).toList();
  }

  Future<void> clearStore() async {
    _ensureActive();
    await db.delete(db.signalIdentities).go();
    await db.delete(db.signalPreKeys).go();
    await db.delete(db.signalSignedPreKeys).go();
    await db.delete(db.signalSessions).go();
    try {
      await db.customStatement('DELETE FROM signal_peer_identity_bindings;');
    } catch (_) {}
    _ensureActive();
  }
}
