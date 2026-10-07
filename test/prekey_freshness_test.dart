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
  group('PreKey Bundle Replay and Freshness Security Tests (CRYPTO-PK-01 & CRYPTO-PK-01A)', () {
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
      int? bundleVersion = 2,
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
        version: bundleVersion ?? 2,
      );

      return <String, dynamic>{
        if (bundleVersion != null) 'bundleVersion': bundleVersion,
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

    test('Test 1: Valid v2 bundle with valid epoch & timestamp is accepted', () async {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final bundle = await createSignedBundle(
        bundleVersion: 2,
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

    test('Test 2: Legacy v1 bundle without v2 metadata is rejected (invalidBundleVersion)', () async {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final idPub = base64Encode(generateIdentityKeyPair().getPublicKey().serialize());
      final legacySig = await crypto.signLegacyV1BundleBindingTokenForTesting(
        masterKeyPair: masterKeyPair,
        nostrPubKeyHex: peerNostrPubKey,
        signalIdentityPubBase64: idPub,
        timestamp: nowMs,
      );

      final legacyBundle = <String, dynamic>{
        // bundleVersion is omitted (legacy v1 bundle)
        'masterKey': masterPubKeyHex,
        'identityPubKey': idPub,
        'timestamp': nowMs,
        'masterBindingSig': legacySig,
      };

      final res = await verifier.verifyPreKeyBundle(
        expectedMasterPubKeyHex: masterPubKeyHex,
        recipientNostrPubKey: peerNostrPubKey,
        bundleMap: legacyBundle,
        eventAuthor: peerNostrPubKey,
      );

      expect(res.isValid, isFalse);
      expect(res.reason, BindingRejectionReason.invalidBundleVersion);
    });

    test('Test 3: Legacy v1 signature with attacker-forged bundleEpoch: 999 is rejected (signatureVerificationFailed)', () async {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final idPub = base64Encode(generateIdentityKeyPair().getPublicKey().serialize());

      // Attacker captures genuine v1 signature from legacy bundle
      final legacyV1Sig = await crypto.signLegacyV1BundleBindingTokenForTesting(
        masterKeyPair: masterKeyPair,
        nostrPubKeyHex: peerNostrPubKey,
        signalIdentityPubBase64: idPub,
        timestamp: nowMs,
      );

      // Attacker presents legacy bundle but injects forged v2 metadata
      final forgedBundle = <String, dynamic>{
        'bundleVersion': 2,
        'masterKey': masterPubKeyHex,
        'identityPubKey': idPub,
        'bundleEpoch': 999, // Forged epoch!
        'issuedAt': nowMs,
        'expiresAt': nowMs + 1209600000,
        'timestamp': nowMs,
        'masterBindingSig': legacyV1Sig, // v1 signature that never signed epoch 999
      };

      final res = await verifier.verifyPreKeyBundle(
        expectedMasterPubKeyHex: masterPubKeyHex,
        recipientNostrPubKey: peerNostrPubKey,
        bundleMap: forgedBundle,
        eventAuthor: peerNostrPubKey,
      );

      // Must be rejected cryptographically; no v1 fallback allowed!
      expect(res.isValid, isFalse);
      expect(res.reason, BindingRejectionReason.signatureVerificationFailed);
    });

    test('Test 4: Legacy v1 signature with attacker-forged expiresAt is rejected (signatureVerificationFailed)', () async {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final idPub = base64Encode(generateIdentityKeyPair().getPublicKey().serialize());

      final legacyV1Sig = await crypto.signLegacyV1BundleBindingTokenForTesting(
        masterKeyPair: masterKeyPair,
        nostrPubKeyHex: peerNostrPubKey,
        signalIdentityPubBase64: idPub,
        timestamp: nowMs,
      );

      final forgedBundle = <String, dynamic>{
        'bundleVersion': 2,
        'masterKey': masterPubKeyHex,
        'identityPubKey': idPub,
        'bundleEpoch': 1,
        'issuedAt': nowMs,
        'expiresAt': nowMs + 86400000, // Attacker forged expiration
        'timestamp': nowMs,
        'masterBindingSig': legacyV1Sig,
      };

      final res = await verifier.verifyPreKeyBundle(
        expectedMasterPubKeyHex: masterPubKeyHex,
        recipientNostrPubKey: peerNostrPubKey,
        bundleMap: forgedBundle,
        eventAuthor: peerNostrPubKey,
      );

      expect(res.isValid, isFalse);
      expect(res.reason, BindingRejectionReason.signatureVerificationFailed);
    });

    test('Test 5: Modified v2 bundleEpoch (42 -> 43) without re-signing fails signature verification', () async {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final bundle = await createSignedBundle(
        bundleVersion: 2,
        bundleEpoch: 42,
        issuedAt: nowMs,
        expiresAt: nowMs + 1209600000,
      );

      // Adversary tampers with epoch from 42 to 43
      bundle['bundleEpoch'] = 43;

      final res = await verifier.verifyPreKeyBundle(
        expectedMasterPubKeyHex: masterPubKeyHex,
        recipientNostrPubKey: peerNostrPubKey,
        bundleMap: bundle,
        eventAuthor: peerNostrPubKey,
      );

      expect(res.isValid, isFalse);
      expect(res.reason, BindingRejectionReason.signatureVerificationFailed);
    });

    test('Test 6: Modified v2 issuedAt without re-signing fails signature verification', () async {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final bundle = await createSignedBundle(
        bundleVersion: 2,
        bundleEpoch: 1,
        issuedAt: nowMs,
        expiresAt: nowMs + 1209600000,
      );

      // Adversary tampers with issuedAt without re-signing
      bundle['issuedAt'] = nowMs + 1000;

      final res = await verifier.verifyPreKeyBundle(
        expectedMasterPubKeyHex: masterPubKeyHex,
        recipientNostrPubKey: peerNostrPubKey,
        bundleMap: bundle,
        eventAuthor: peerNostrPubKey,
      );

      expect(res.isValid, isFalse);
      expect(res.reason, BindingRejectionReason.signatureVerificationFailed);
    });

    test('Test 7: Older epoch candidate (epoch < storedEpoch) is rejected (staleBundleEpoch)', () async {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final bundle = await createSignedBundle(
        bundleVersion: 2,
        bundleEpoch: 41,
        issuedAt: nowMs,
        expiresAt: nowMs + 1209600000,
      );

      final res = await verifier.verifyPreKeyBundle(
        expectedMasterPubKeyHex: masterPubKeyHex,
        recipientNostrPubKey: peerNostrPubKey,
        bundleMap: bundle,
        eventAuthor: peerNostrPubKey,
        storedEpoch: 42, // Stored epoch is 42
      );

      expect(res.isValid, isFalse);
      expect(res.reason, BindingRejectionReason.staleBundleEpoch);
    });

    test('Test 8: Newer epoch candidate (epoch > storedEpoch) is accepted and stored epoch updates', () async {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final bundleEpoch42 = await createSignedBundle(
        bundleVersion: 2,
        bundleEpoch: 42,
        issuedAt: nowMs - 10000,
        expiresAt: nowMs + 1209600000,
      );

      // 1. Initial bundle at epoch 42 is accepted and saved
      final res42 = await verifier.verifyPreKeyBundle(
        expectedMasterPubKeyHex: masterPubKeyHex,
        recipientNostrPubKey: peerNostrPubKey,
        bundleMap: bundleEpoch42,
        eventAuthor: peerNostrPubKey,
        storedEpoch: null,
      );
      expect(res42.isValid, isTrue);

      await signalStore.savePeerPreKeyState(PeerPreKeyState(
        nostrPubKeyHex: peerNostrPubKey,
        masterPubKeyHex: masterPubKeyHex,
        lastBundleEpoch: 42,
        lastBundleTimestamp: bundleEpoch42['issuedAt'] as int,
        lastBundleHash: MasterBindingVerifier.computeBundleHash(bundleEpoch42),
        updatedAt: DateTime.now(),
      ));

      var storedState = await signalStore.getPeerPreKeyState(peerNostrPubKey);
      expect(storedState?.lastBundleEpoch, equals(42));

      // 2. Newer bundle at epoch 43 is verified against stored epoch 42
      final bundleEpoch43 = await createSignedBundle(
        bundleVersion: 2,
        bundleEpoch: 43,
        issuedAt: nowMs,
        expiresAt: nowMs + 1209600000,
      );

      final res43 = await verifier.verifyPreKeyBundle(
        expectedMasterPubKeyHex: masterPubKeyHex,
        recipientNostrPubKey: peerNostrPubKey,
        bundleMap: bundleEpoch43,
        eventAuthor: peerNostrPubKey,
        storedEpoch: storedState?.lastBundleEpoch,
      );
      expect(res43.isValid, isTrue);

      // Persist newer state
      await signalStore.savePeerPreKeyState(PeerPreKeyState(
        nostrPubKeyHex: peerNostrPubKey,
        masterPubKeyHex: masterPubKeyHex,
        lastBundleEpoch: 43,
        lastBundleTimestamp: bundleEpoch43['issuedAt'] as int,
        lastBundleHash: MasterBindingVerifier.computeBundleHash(bundleEpoch43),
        updatedAt: DateTime.now(),
      ));

      storedState = await signalStore.getPeerPreKeyState(peerNostrPubKey);
      expect(storedState?.lastBundleEpoch, equals(43));
    });

    test('Test 9: Same epoch with conflicting key material is rejected (conflictingBundleEpoch)', () async {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final bundleA = await createSignedBundle(
        bundleVersion: 2,
        bundleEpoch: 42,
        issuedAt: nowMs,
        expiresAt: nowMs + 1209600000,
      );

      final hashA = MasterBindingVerifier.computeBundleHash(bundleA);

      // Bundle B has same epoch 42, but different identity key material
      final bundleB = await createSignedBundle(
        bundleVersion: 2,
        bundleEpoch: 42,
        issuedAt: nowMs,
        expiresAt: nowMs + 1209600000,
        customIdentityPubKeyBase64: base64Encode(generateIdentityKeyPair().getPublicKey().serialize()),
      );

      final res = await verifier.verifyPreKeyBundle(
        expectedMasterPubKeyHex: masterPubKeyHex,
        recipientNostrPubKey: peerNostrPubKey,
        bundleMap: bundleB,
        eventAuthor: peerNostrPubKey,
        storedEpoch: 42,
        storedBundleHash: hashA, // Conflicting hash
      );

      expect(res.isValid, isFalse);
      expect(res.reason, BindingRejectionReason.conflictingBundleEpoch);
    });

    test('Test 10: Same epoch with identical bundle is accepted as duplicate without conflict', () async {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final bundle = await createSignedBundle(
        bundleVersion: 2,
        bundleEpoch: 42,
        issuedAt: nowMs,
        expiresAt: nowMs + 1209600000,
      );

      final bundleHash = MasterBindingVerifier.computeBundleHash(bundle);

      final res = await verifier.verifyPreKeyBundle(
        expectedMasterPubKeyHex: masterPubKeyHex,
        recipientNostrPubKey: peerNostrPubKey,
        bundleMap: bundle,
        eventAuthor: peerNostrPubKey,
        storedEpoch: 42,
        storedBundleHash: bundleHash,
      );

      expect(res.isValid, isTrue);
      expect(res.reason, BindingRejectionReason.none);
    });

    test('Test 11: Multi-candidate relay arrival order invariance selects highest valid epoch', () async {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final bundle40 = await createSignedBundle(
        bundleVersion: 2,
        bundleEpoch: 40,
        issuedAt: nowMs - 20000,
        expiresAt: nowMs + 1209600000,
      );
      final bundle41 = await createSignedBundle(
        bundleVersion: 2,
        bundleEpoch: 41,
        issuedAt: nowMs - 10000,
        expiresAt: nowMs + 1209600000,
      );
      final bundle42 = await createSignedBundle(
        bundleVersion: 2,
        bundleEpoch: 42,
        issuedAt: nowMs,
        expiresAt: nowMs + 1209600000,
      );

      // Arbitrary relay arrival order: [40, 42, 41]
      final candidates = <Map<String, dynamic>>[bundle40, bundle42, bundle41];

      // Sorting rule: highest bundleEpoch descending, then newest issuedAt descending
      candidates.sort((a, b) {
        final epochA = a['bundleEpoch'] as int? ?? 0;
        final epochB = b['bundleEpoch'] as int? ?? 0;
        if (epochA != epochB) return epochB.compareTo(epochA);
        final tsA = a['issuedAt'] as int? ?? a['timestamp'] as int? ?? 0;
        final tsB = b['issuedAt'] as int? ?? b['timestamp'] as int? ?? 0;
        return tsB.compareTo(tsA);
      });

      expect(candidates.first['bundleEpoch'], equals(42));
      expect(candidates[1]['bundleEpoch'], equals(41));
      expect(candidates.last['bundleEpoch'], equals(40));

      final selected = candidates.first;
      final res = await verifier.verifyPreKeyBundle(
        expectedMasterPubKeyHex: masterPubKeyHex,
        recipientNostrPubKey: peerNostrPubKey,
        bundleMap: selected,
        eventAuthor: peerNostrPubKey,
      );
      expect(res.isValid, isTrue);
      expect(selected['bundleEpoch'], equals(42));
    });

    test('Test 12: Expired v2 bundle (now > expiresAt) is rejected (timestampExpired)', () async {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final issuedAt = nowMs - 2000000;
      final expiresAt = nowMs - 5000; // expired 5 seconds ago

      final bundle = await createSignedBundle(
        bundleVersion: 2,
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

    test('Test 13: Future-dated v2 bundle (issuedAt > now + 10m) is rejected (timestampFutureSkew)', () async {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final futureIssuedAt = nowMs + 700000; // ~11.6 minutes in future (> 10 min skew limit)
      final expiresAt = futureIssuedAt + 1209600000;

      final bundle = await createSignedBundle(
        bundleVersion: 2,
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

    test('Test 14: Invalid validity interval (expiresAt <= issuedAt or interval > 30d) is rejected (invalidValidityInterval)', () async {
      final nowMs = DateTime.now().millisecondsSinceEpoch;

      // Inverted interval: expiresAt <= issuedAt
      final invertedBundle = await createSignedBundle(
        bundleVersion: 2,
        bundleEpoch: 1,
        issuedAt: nowMs,
        expiresAt: nowMs - 1000,
      );

      final resInverted = await verifier.verifyPreKeyBundle(
        expectedMasterPubKeyHex: masterPubKeyHex,
        recipientNostrPubKey: peerNostrPubKey,
        bundleMap: invertedBundle,
        eventAuthor: peerNostrPubKey,
        nowMs: nowMs - 2000,
      );
      expect(resInverted.isValid, isFalse);
      expect(resInverted.reason, BindingRejectionReason.invalidValidityInterval);

      // Excessive interval: > 30 days
      final excessiveBundle = await createSignedBundle(
        bundleVersion: 2,
        bundleEpoch: 1,
        issuedAt: nowMs,
        expiresAt: nowMs + const Duration(days: 35).inMilliseconds,
      );

      final resExcessive = await verifier.verifyPreKeyBundle(
        expectedMasterPubKeyHex: masterPubKeyHex,
        recipientNostrPubKey: peerNostrPubKey,
        bundleMap: excessiveBundle,
        eventAuthor: peerNostrPubKey,
        nowMs: nowMs,
      );
      expect(resExcessive.isValid, isFalse);
      expect(resExcessive.reason, BindingRejectionReason.invalidValidityInterval);
    });

    test('Test 15: Application restart / store reload retains persisted lastBundleEpoch and rejects replayed older bundles', () async {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final bundleEpoch42 = await createSignedBundle(
        bundleVersion: 2,
        bundleEpoch: 42,
        issuedAt: nowMs,
        expiresAt: nowMs + 1209600000,
      );

      // Persist state in signalStore 1
      await signalStore.savePeerPreKeyState(PeerPreKeyState(
        nostrPubKeyHex: peerNostrPubKey,
        masterPubKeyHex: masterPubKeyHex,
        lastBundleEpoch: 42,
        lastBundleTimestamp: nowMs,
        lastBundleHash: MasterBindingVerifier.computeBundleHash(bundleEpoch42),
        updatedAt: DateTime.now(),
      ));

      // Simulate App Restart by creating a new SignalStore instance over same database
      final reloadedSignalStore = SignalStore(db, localIdentityKeyPair, 11111);
      final reloadedPeerState = await reloadedSignalStore.getPeerPreKeyState(peerNostrPubKey);

      expect(reloadedPeerState, isNotNull);
      expect(reloadedPeerState?.lastBundleEpoch, equals(42));

      // Replay attack with older bundle (epoch 41) against reloaded state
      final replayedBundle = await createSignedBundle(
        bundleVersion: 2,
        bundleEpoch: 41,
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

    test('Test 16: Local bundle epoch tracking is strictly monotonic', () async {
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
