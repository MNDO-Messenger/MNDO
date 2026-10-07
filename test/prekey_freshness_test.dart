import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
import 'package:aisat_connect/database/database.dart';
import 'package:aisat_connect/services/crypto_service.dart';
import 'package:aisat_connect/services/master_binding_verifier.dart';
import 'package:aisat_connect/services/signal_store.dart';
import 'package:aisat_connect/services/account_session.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

void main() {
  group('PreKey Bundle Replay and Freshness Security Tests (CRYPTO-PK-01)', () {
    late CryptoService crypto;
    late MasterBindingVerifier verifier;
    late SimpleKeyPair masterKeyPair;
    late String masterPubKeyHex;
    const String peerNostrPubKey = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

    late AppDatabase db;
    late SignalStore signalStore;
    late IdentityKeyPair localIdentityKeyPair;

    setUp(() async {
      AccountSession.resetForTesting();
      crypto = CryptoService();
      verifier = MasterBindingVerifier(cryptoService: crypto);
      final mnemonic = crypto.generateMnemonic();
      masterKeyPair = await crypto.generateMasterKeyPair(mnemonic);
      final pubKey = await masterKeyPair.extractPublicKey();
      masterPubKeyHex = pubKey.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

      db = AppDatabase.forTesting(NativeDatabase.memory());
      localIdentityKeyPair = generateIdentityKeyPair();
      signalStore = SignalStore(db, localIdentityKeyPair, 11111);
    });

    tearDown(() async {
      await db.close();
    });

    Future<Map<String, dynamic>> createSignedBundle({
      required int bundleEpoch,
      required int issuedAt,
      required int expiresAt,
      String? customIdentityPubKeyBase64,
      String? customSignedPreKeyPubBase64,
      SimpleKeyPair? signingKey,
      String? signingNostrKey,
    }) async {
      final idPubBase64 = customIdentityPubKeyBase64 ??
          base64Encode(generateIdentityKeyPair().getPublicKey().serialize());
      final spkPubBase64 = customSignedPreKeyPubBase64 ??
          base64Encode(Curve.generateKeyPair().publicKey.serialize());

      final sig = await crypto.signBundleBindingToken(
        masterKeyPair: signingKey ?? masterKeyPair,
        nostrPubKeyHex: signingNostrKey ?? peerNostrPubKey,
        signalIdentityPubBase64: idPubBase64,
        bundleEpoch: bundleEpoch,
        issuedAt: issuedAt,
        expiresAt: expiresAt,
      );

      return <String, dynamic>{
        'registrationId': 12345,
        'masterKey': masterPubKeyHex,
        'identityPubKey': idPubBase64,
        'bundleEpoch': bundleEpoch,
        'issuedAt': issuedAt,
        'expiresAt': expiresAt,
        'timestamp': issuedAt,
        'signedPreKey': {
          'id': 1,
          'pubKey': spkPubBase64,
          'signature': base64Encode(List.filled(64, 1)),
        },
        'oneTimePreKeys': <Map<String, dynamic>>[
          {
            'id': 10,
            'pubKey': base64Encode(Curve.generateKeyPair().publicKey.serialize()),
          }
        ],
        'masterBindingSig': sig,
      };
    }

    test('Test 1: Fresh bundle with valid epoch & timestamp is accepted', () async {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final bundle = await createSignedBundle(
        bundleEpoch: 1,
        issuedAt: nowMs,
        expiresAt: nowMs + 1209600000, // 14 days
      );

      final res = await verifier.verifyPreKeyBundle(
        expectedMasterPubKeyHex: masterPubKeyHex,
        recipientNostrPubKey: peerNostrPubKey,
        bundleMap: bundle,
        eventAuthor: peerNostrPubKey,
        storedEpoch: null,
      );

      expect(res.isValid, isTrue);
      expect(res.reason, BindingRejectionReason.none);
    });

    test('Test 2: Expired bundle (now > expiresAt) is rejected (timestampExpired)', () async {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final issuedAt = nowMs - 2000000;
      final expiresAt = nowMs - 5000; // expired 5 seconds ago

      final bundle = await createSignedBundle(
        bundleEpoch: 1,
        issuedAt: issuedAt,
        expiresAt: expiresAt,
      );

      final res = await verifier.verifyPreKeyBundle(
        expectedMasterPubKeyHex: masterPubKeyHex,
        recipientNostrPubKey: peerNostrPubKey,
        bundleMap: bundle,
        eventAuthor: peerNostrPubKey,
        nowMs: nowMs,
      );

      expect(res.isValid, isFalse);
      expect(res.reason, BindingRejectionReason.timestampExpired);
    });

    test('Test 3: Future-dated bundle (issuedAt > now + 10m) is rejected (timestampFutureSkew)', () async {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final futureIssuedAt = nowMs + 700000; // ~11.6 minutes in future (> 10 min skew limit)
      final expiresAt = futureIssuedAt + 1209600000;

      final bundle = await createSignedBundle(
        bundleEpoch: 1,
        issuedAt: futureIssuedAt,
        expiresAt: expiresAt,
      );

      final res = await verifier.verifyPreKeyBundle(
        expectedMasterPubKeyHex: masterPubKeyHex,
        recipientNostrPubKey: peerNostrPubKey,
        bundleMap: bundle,
        eventAuthor: peerNostrPubKey,
        nowMs: nowMs,
      );

      expect(res.isValid, isFalse);
      expect(res.reason, BindingRejectionReason.timestampFutureSkew);
    });

    test('Test 4: Older epoch candidate (epoch < storedEpoch) is rejected (staleBundleEpoch)', () async {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final bundle = await createSignedBundle(
        bundleEpoch: 2,
        issuedAt: nowMs,
        expiresAt: nowMs + 1209600000,
      );

      final res = await verifier.verifyPreKeyBundle(
        expectedMasterPubKeyHex: masterPubKeyHex,
        recipientNostrPubKey: peerNostrPubKey,
        bundleMap: bundle,
        eventAuthor: peerNostrPubKey,
        storedEpoch: 5, // Already accepted epoch 5
      );

      expect(res.isValid, isFalse);
      expect(res.reason, BindingRejectionReason.staleBundleEpoch);
    });

    test('Test 5: Newer epoch candidate (epoch > storedEpoch) is accepted and stored epoch updates', () async {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final bundleEpoch2 = await createSignedBundle(
        bundleEpoch: 2,
        issuedAt: nowMs - 10000,
        expiresAt: nowMs + 1209600000,
      );

      // 1. Initial bundle at epoch 2 is accepted and saved
      final res2 = await verifier.verifyPreKeyBundle(
        expectedMasterPubKeyHex: masterPubKeyHex,
        recipientNostrPubKey: peerNostrPubKey,
        bundleMap: bundleEpoch2,
        eventAuthor: peerNostrPubKey,
        storedEpoch: null,
      );
      expect(res2.isValid, isTrue);

      await signalStore.savePeerPreKeyState(PeerPreKeyState(
        nostrPubKeyHex: peerNostrPubKey,
        masterPubKeyHex: masterPubKeyHex,
        lastBundleEpoch: 2,
        lastBundleTimestamp: bundleEpoch2['issuedAt'] as int,
        lastBundleHash: MasterBindingVerifier.computeBundleHash(bundleEpoch2),
        updatedAt: DateTime.now(),
      ));

      var storedState = await signalStore.getPeerPreKeyState(peerNostrPubKey);
      expect(storedState?.lastBundleEpoch, equals(2));

      // 2. Newer bundle at epoch 3 is verified against stored epoch 2
      final bundleEpoch3 = await createSignedBundle(
        bundleEpoch: 3,
        issuedAt: nowMs,
        expiresAt: nowMs + 1209600000,
      );

      final res3 = await verifier.verifyPreKeyBundle(
        expectedMasterPubKeyHex: masterPubKeyHex,
        recipientNostrPubKey: peerNostrPubKey,
        bundleMap: bundleEpoch3,
        eventAuthor: peerNostrPubKey,
        storedEpoch: storedState?.lastBundleEpoch,
      );
      expect(res3.isValid, isTrue);

      // Persist newer state
      await signalStore.savePeerPreKeyState(PeerPreKeyState(
        nostrPubKeyHex: peerNostrPubKey,
        masterPubKeyHex: masterPubKeyHex,
        lastBundleEpoch: 3,
        lastBundleTimestamp: bundleEpoch3['issuedAt'] as int,
        lastBundleHash: MasterBindingVerifier.computeBundleHash(bundleEpoch3),
        updatedAt: DateTime.now(),
      ));

      storedState = await signalStore.getPeerPreKeyState(peerNostrPubKey);
      expect(storedState?.lastBundleEpoch, equals(3));
    });

    test('Test 6: Relay returns old bundle first, then new bundle -> newest valid epoch is selected', () async {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final bundleOld = await createSignedBundle(
        bundleEpoch: 1,
        issuedAt: nowMs - 10000,
        expiresAt: nowMs + 1209600000,
      );
      final bundleNew = await createSignedBundle(
        bundleEpoch: 2,
        issuedAt: nowMs,
        expiresAt: nowMs + 1209600000,
      );

      // Relay arrival order: old bundle first, then new bundle
      final candidates = <Map<String, dynamic>>[bundleOld, bundleNew];

      // Sorting rule: highest bundleEpoch descending, then newest issuedAt descending
      candidates.sort((a, b) {
        final epochA = a['bundleEpoch'] as int? ?? 0;
        final epochB = b['bundleEpoch'] as int? ?? 0;
        if (epochA != epochB) return epochB.compareTo(epochA);
        final tsA = a['issuedAt'] as int? ?? a['timestamp'] as int? ?? 0;
        final tsB = b['issuedAt'] as int? ?? b['timestamp'] as int? ?? 0;
        return tsB.compareTo(tsA);
      });

      expect(candidates.first['bundleEpoch'], equals(2));
      expect(candidates.last['bundleEpoch'], equals(1));

      // Candidate selection picks top candidate
      final selected = candidates.first;
      final res = await verifier.verifyPreKeyBundle(
        expectedMasterPubKeyHex: masterPubKeyHex,
        recipientNostrPubKey: peerNostrPubKey,
        bundleMap: selected,
        eventAuthor: peerNostrPubKey,
      );
      expect(res.isValid, isTrue);
      expect(selected['bundleEpoch'], equals(2));
    });

    test('Test 7: Relay returns new bundle first, then old bundle -> newest valid epoch is selected', () async {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final bundleOld = await createSignedBundle(
        bundleEpoch: 1,
        issuedAt: nowMs - 10000,
        expiresAt: nowMs + 1209600000,
      );
      final bundleNew = await createSignedBundle(
        bundleEpoch: 2,
        issuedAt: nowMs,
        expiresAt: nowMs + 1209600000,
      );

      // Relay arrival order: new bundle first, then old bundle
      final candidates = <Map<String, dynamic>>[bundleNew, bundleOld];

      candidates.sort((a, b) {
        final epochA = a['bundleEpoch'] as int? ?? 0;
        final epochB = b['bundleEpoch'] as int? ?? 0;
        if (epochA != epochB) return epochB.compareTo(epochA);
        final tsA = a['issuedAt'] as int? ?? a['timestamp'] as int? ?? 0;
        final tsB = b['issuedAt'] as int? ?? b['timestamp'] as int? ?? 0;
        return tsB.compareTo(tsA);
      });

      expect(candidates.first['bundleEpoch'], equals(2));
      final selected = candidates.first;
      final res = await verifier.verifyPreKeyBundle(
        expectedMasterPubKeyHex: masterPubKeyHex,
        recipientNostrPubKey: peerNostrPubKey,
        bundleMap: selected,
        eventAuthor: peerNostrPubKey,
      );
      expect(res.isValid, isTrue);
      expect(selected['bundleEpoch'], equals(2));
    });

    test('Test 8: Same epoch with identical bundle -> accepted as duplicate without conflict', () async {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final bundle = await createSignedBundle(
        bundleEpoch: 3,
        issuedAt: nowMs,
        expiresAt: nowMs + 1209600000,
      );

      final bundleHash = MasterBindingVerifier.computeBundleHash(bundle);

      final res = await verifier.verifyPreKeyBundle(
        expectedMasterPubKeyHex: masterPubKeyHex,
        recipientNostrPubKey: peerNostrPubKey,
        bundleMap: bundle,
        eventAuthor: peerNostrPubKey,
        storedEpoch: 3,
        storedBundleHash: bundleHash,
      );

      expect(res.isValid, isTrue);
      expect(res.reason, BindingRejectionReason.none);
    });

    test('Test 9: Same epoch with conflicting key material -> rejected (conflictingBundleEpoch)', () async {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final bundleA = await createSignedBundle(
        bundleEpoch: 3,
        issuedAt: nowMs,
        expiresAt: nowMs + 1209600000,
      );

      final hashA = MasterBindingVerifier.computeBundleHash(bundleA);

      // Bundle B has same epoch 3, but different identity key material
      final bundleB = await createSignedBundle(
        bundleEpoch: 3,
        issuedAt: nowMs,
        expiresAt: nowMs + 1209600000,
        customIdentityPubKeyBase64: base64Encode(generateIdentityKeyPair().getPublicKey().serialize()),
      );

      final res = await verifier.verifyPreKeyBundle(
        expectedMasterPubKeyHex: masterPubKeyHex,
        recipientNostrPubKey: peerNostrPubKey,
        bundleMap: bundleB,
        eventAuthor: peerNostrPubKey,
        storedEpoch: 3,
        storedBundleHash: hashA, // Conflicting hash
      );

      expect(res.isValid, isFalse);
      expect(res.reason, BindingRejectionReason.conflictingBundleEpoch);
    });

    test('Test 10: Application restart / store reload retains persisted lastBundleEpoch and rejects replayed older bundles', () async {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final bundleEpoch5 = await createSignedBundle(
        bundleEpoch: 5,
        issuedAt: nowMs,
        expiresAt: nowMs + 1209600000,
      );

      // Persist state in signalStore 1
      await signalStore.savePeerPreKeyState(PeerPreKeyState(
        nostrPubKeyHex: peerNostrPubKey,
        masterPubKeyHex: masterPubKeyHex,
        lastBundleEpoch: 5,
        lastBundleTimestamp: nowMs,
        lastBundleHash: MasterBindingVerifier.computeBundleHash(bundleEpoch5),
        updatedAt: DateTime.now(),
      ));

      // Simulate App Restart by creating a new SignalStore instance over same database
      final reloadedSignalStore = SignalStore(db, localIdentityKeyPair, 11111);
      final reloadedPeerState = await reloadedSignalStore.getPeerPreKeyState(peerNostrPubKey);

      expect(reloadedPeerState, isNotNull);
      expect(reloadedPeerState?.lastBundleEpoch, equals(5));

      // Replay attack with older bundle (epoch 4) against reloaded state
      final replayedBundle = await createSignedBundle(
        bundleEpoch: 4,
        issuedAt: nowMs - 50000,
        expiresAt: nowMs + 1209600000,
      );

      final replayRes = await verifier.verifyPreKeyBundle(
        expectedMasterPubKeyHex: masterPubKeyHex,
        recipientNostrPubKey: peerNostrPubKey,
        bundleMap: replayedBundle,
        eventAuthor: peerNostrPubKey,
        storedEpoch: reloadedPeerState?.lastBundleEpoch,
      );

      expect(replayRes.isValid, isFalse);
      expect(replayRes.reason, BindingRejectionReason.staleBundleEpoch);
    });

    test('Test 11: Tampering with bundleEpoch without re-signing fails cryptographic verification', () async {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      // Legitimate bundle signed with epoch 1
      final bundle = await createSignedBundle(
        bundleEpoch: 1,
        issuedAt: nowMs,
        expiresAt: nowMs + 1209600000,
      );

      // Adversary tampers with epoch field to 2 without valid master signature
      bundle['bundleEpoch'] = 2;

      final res = await verifier.verifyPreKeyBundle(
        expectedMasterPubKeyHex: masterPubKeyHex,
        recipientNostrPubKey: peerNostrPubKey,
        bundleMap: bundle,
        eventAuthor: peerNostrPubKey,
      );

      expect(res.isValid, isFalse);
      expect(res.reason, BindingRejectionReason.signatureVerificationFailed);
    });

    test('Test 12: Tampering with issuedAt or expiresAt without re-signing fails cryptographic verification', () async {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final bundle = await createSignedBundle(
        bundleEpoch: 1,
        issuedAt: nowMs,
        expiresAt: nowMs + 1209600000,
      );

      // Adversary tampers with issuedAt without re-signing
      final tamperedIssuedAtBundle = Map<String, dynamic>.from(bundle);
      tamperedIssuedAtBundle['issuedAt'] = nowMs + 1000;

      final resIssued = await verifier.verifyPreKeyBundle(
        expectedMasterPubKeyHex: masterPubKeyHex,
        recipientNostrPubKey: peerNostrPubKey,
        bundleMap: tamperedIssuedAtBundle,
        eventAuthor: peerNostrPubKey,
      );
      expect(resIssued.isValid, isFalse);
      expect(resIssued.reason, BindingRejectionReason.signatureVerificationFailed);

      // Adversary tampers with expiresAt without re-signing
      final tamperedExpiresAtBundle = Map<String, dynamic>.from(bundle);
      tamperedExpiresAtBundle['expiresAt'] = (bundle['expiresAt'] as int) + 86400000;

      final resExpires = await verifier.verifyPreKeyBundle(
        expectedMasterPubKeyHex: masterPubKeyHex,
        recipientNostrPubKey: peerNostrPubKey,
        bundleMap: tamperedExpiresAtBundle,
        eventAuthor: peerNostrPubKey,
      );
      expect(resExpires.isValid, isFalse);
      expect(resExpires.reason, BindingRejectionReason.signatureVerificationFailed);
    });

    test('Test 13: Local bundle epoch tracking is strictly monotonic', () async {
      final initialEpoch = await signalStore.getCurrentLocalBundleEpoch();
      expect(initialEpoch, equals(0));

      final nextEpoch1 = await signalStore.getNextLocalBundleEpoch();
      expect(nextEpoch1, equals(1));

      await signalStore.commitLocalBundleEpoch(1);
      final currentEpoch1 = await signalStore.getCurrentLocalBundleEpoch();
      expect(currentEpoch1, equals(1));

      final nextEpoch2 = await signalStore.getNextLocalBundleEpoch();
      expect(nextEpoch2, equals(2));

      await signalStore.commitLocalBundleEpoch(2);
      final currentEpoch2 = await signalStore.getCurrentLocalBundleEpoch();
      expect(currentEpoch2, equals(2));
    });
  });
}
