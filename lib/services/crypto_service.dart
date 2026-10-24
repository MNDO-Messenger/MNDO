import 'dart:convert';

import 'package:bip39/bip39.dart' as bip39;
import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart';

import '../core/dictionary.dart';

class CryptoService {
  final _ed25519 = Ed25519();

  // Uses appAdjectives and appNouns from dictionary.dart

  /// Generates a 12-word BIP-39 mnemonic
  String generateMnemonic() {
    return bip39.generateMnemonic();
  }

  /// Validates if the mnemonic adheres to the BIP-39 standard (valid dictionary words and valid checksum)
  bool validateMnemonic(String mnemonic) {
    final clean = mnemonic.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    if (clean.split(' ').where((w) => w.isNotEmpty).length != 12) return false;
    return bip39.validateMnemonic(clean);
  }

  /// Derives an Ed25519 Master KeyPair from the mnemonic
  /// Deterministically derives the master Ed25519 keypair from a BIP-39 mnemonic (P3.1).
  ///
  /// Specification:
  /// 1. Mnemonic normalization: Whitespace-trimmed, single-space separated 12 or 24 BIP-39 words.
  /// 2. BIP-39 seed derivation: 512-bit (64-byte) seed derived via PBKDF2-HMAC-SHA512
  ///    using salt "mnemonic" and 2048 iterations (`bip39.mnemonicToSeed`).
  /// 3. Seed slicing: The first 32 bytes (`seed.sublist(0, 32)`) form the raw Ed25519 seed.
  /// 4. Keypair derivation: Ed25519 keypair generated via RFC 8032 from the 32-byte seed.
  /// 5. Master Public Key Format: 32 raw bytes encoded as a lowercase 64-character hex string.
  ///
  /// INVARIANT: Never change this derivation for existing protocol versions as it
  /// would alter account identities derived from existing user recovery phrases.
  Future<SimpleKeyPair> generateMasterKeyPair(String mnemonic) async {
    final normalized = mnemonic.trim().toLowerCase().replaceAll(
      RegExp(r'\s+'),
      ' ',
    );
    final seed = bip39.mnemonicToSeed(normalized);
    // Ed25519 requires a 32-byte seed, but bip39 gives 64 bytes.
    // We take the first 32 bytes.
    final seed32 = seed.sublist(0, 32);

    return await _ed25519.newKeyPairFromSeed(seed32);
  }

  /// Generates the deterministic username from the public key
  Future<String> generateUsername(SimplePublicKey publicKey) async {
    // Hash the public key bytes using SHA-256 for deterministic distribution
    final hash = sha256.convert(publicKey.bytes);
    final hashBytes = hash.bytes;

    // Convert first few bytes to integers to pick adjective and noun
    int adjIndex = ((hashBytes[0] << 8) | hashBytes[1]) % appAdjectives.length;
    int nounIndex = ((hashBytes[2] << 8) | hashBytes[3]) % appNouns.length;

    final adjective = appAdjectives[adjIndex];
    final noun = appNouns[nounIndex];

    // Generate a 6-character hex suffix from bytes 4, 5, and 6 for 16.7 trillion combinations
    final hexSuffix =
        '${hashBytes[4].toRadixString(16).padLeft(2, '0')}${hashBytes[5].toRadixString(16).padLeft(2, '0')}${hashBytes[6].toRadixString(16).padLeft(2, '0')}';

    return '$adjective $noun #$hexSuffix';
  }

  /// Cryptographically signs a delegation/presence token with the Master Ed25519 key
  Future<String> signDelegationToken({
    required SimpleKeyPair masterKeyPair,
    required String nostrPubKeyHex,
    required int timestamp,
  }) async {
    final message = utf8.encode('MNDO-BIND:$nostrPubKeyHex:$timestamp');
    final sig = await _ed25519.sign(message, keyPair: masterKeyPair);
    return sig.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Verifies a delegation/presence token signed by the Master Ed25519 public key
  Future<bool> verifyDelegationToken({
    required String masterPubKeyHex,
    required String nostrPubKeyHex,
    required int timestamp,
    required String signatureHex,
  }) async {
    try {
      if (signatureHex.isEmpty ||
          masterPubKeyHex.length != 64 ||
          signatureHex.length != 128) {
        return false;
      }
      final pubKeyBytes = <int>[];
      for (int i = 0; i < masterPubKeyHex.length; i += 2) {
        pubKeyBytes.add(
          int.parse(masterPubKeyHex.substring(i, i + 2), radix: 16),
        );
      }
      final sigBytes = <int>[];
      for (int i = 0; i < signatureHex.length; i += 2) {
        sigBytes.add(int.parse(signatureHex.substring(i, i + 2), radix: 16));
      }

      final message = utf8.encode('MNDO-BIND:$nostrPubKeyHex:$timestamp');
      final simplePubKey = SimplePublicKey(
        pubKeyBytes,
        type: KeyPairType.ed25519,
      );
      final signature = Signature(sigBytes, publicKey: simplePubKey);

      return await _ed25519.verify(message, signature: signature);
    } catch (_) {
      return false;
    }
  }

  /// Builds the single canonical message string for PreKey bundle binding authentication
  static String canonicalBundleBindingMessage({
    required int version,
    required String nostrPubKeyHex,
    required String signalIdentityPubBase64,
    required int bundleEpoch,
    required int issuedAt,
    required int expiresAt,
  }) {
    return 'MNDO-BUNDLE-BIND:$version:'
        '$nostrPubKeyHex:'
        '$signalIdentityPubBase64:'
        '$bundleEpoch:'
        '$issuedAt:'
        '$expiresAt';
  }

  /// Formats and deterministically sorts a list of one-time prekeys as '$id:$pubKey' joined by commas.
  static String formatSortedOtks(List<dynamic>? rawOtks) {
    if (rawOtks == null || rawOtks.isEmpty) return '';
    final otks = <String>[];
    for (final item in rawOtks) {
      if (item is Map) {
        final kId = item['id'] ?? item['keyId'] ?? '';
        final kPub = item['pubKey'] ?? '';
        otks.add('$kId:$kPub');
      }
    }
    otks.sort();
    return otks.join(',');
  }

  /// Builds the single canonical message string for PreKey bundle binding authentication (v3 full object)
  static String canonicalBundleBindingMessageV3({
    int version = 3,
    required String nostrPubKeyHex,
    required String masterKeyHex,
    required String signalIdentityPubBase64,
    required int registrationId,
    required int bundleEpoch,
    required int issuedAt,
    required int expiresAt,
    required int signedPreKeyId,
    required String signedPreKeyPubBase64,
    required String signedPreKeySigBase64,
    String? sortedOtksStr,
    List<dynamic>? oneTimePreKeys,
  }) {
    final otksStr = sortedOtksStr ?? formatSortedOtks(oneTimePreKeys);
    return 'MNDO-BUNDLE-BIND-V3:$version:'
        '$nostrPubKeyHex:'
        '$masterKeyHex:'
        '$signalIdentityPubBase64:'
        '$registrationId:'
        '$bundleEpoch:'
        '$issuedAt:'
        '$expiresAt:'
        '$signedPreKeyId:'
        '$signedPreKeyPubBase64:'
        '$signedPreKeySigBase64:'
        '$otksStr';
  }

  /// Cryptographically signs a full Signal PreKey bundle binding object with the Master Ed25519 key (v3 mandatory)
  Future<String> signBundleBindingTokenV3({
    required SimpleKeyPair masterKeyPair,
    required String nostrPubKeyHex,
    required String masterKeyHex,
    required String signalIdentityPubBase64,
    required int registrationId,
    required int bundleEpoch,
    required int issuedAt,
    required int expiresAt,
    required int signedPreKeyId,
    required String signedPreKeyPubBase64,
    required String signedPreKeySigBase64,
    String? sortedOtksStr,
    List<dynamic>? oneTimePreKeys,
    int version = 3,
  }) async {
    final messageStr = canonicalBundleBindingMessageV3(
      version: version,
      nostrPubKeyHex: nostrPubKeyHex,
      masterKeyHex: masterKeyHex,
      signalIdentityPubBase64: signalIdentityPubBase64,
      registrationId: registrationId,
      bundleEpoch: bundleEpoch,
      issuedAt: issuedAt,
      expiresAt: expiresAt,
      signedPreKeyId: signedPreKeyId,
      signedPreKeyPubBase64: signedPreKeyPubBase64,
      signedPreKeySigBase64: signedPreKeySigBase64,
      sortedOtksStr: sortedOtksStr,
      oneTimePreKeys: oneTimePreKeys,
    );
    final message = utf8.encode(messageStr);
    final sig = await _ed25519.sign(message, keyPair: masterKeyPair);
    return sig.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Verifies a full Signal PreKey bundle binding object signed by the Master Ed25519 public key (v3 mandatory).
  Future<bool> verifyBundleBindingTokenV3({
    required String masterPubKeyHex,
    required String nostrPubKeyHex,
    required String signalIdentityPubBase64,
    required int registrationId,
    required int bundleEpoch,
    required int issuedAt,
    required int expiresAt,
    required int signedPreKeyId,
    required String signedPreKeyPubBase64,
    required String signedPreKeySigBase64,
    String? sortedOtksStr,
    List<dynamic>? oneTimePreKeys,
    int version = 3,
    required String signatureHex,
  }) async {
    try {
      if (signatureHex.isEmpty ||
          masterPubKeyHex.length != 64 ||
          signatureHex.length != 128) {
        return false;
      }
      final pubKeyBytes = <int>[];
      for (int i = 0; i < masterPubKeyHex.length; i += 2) {
        pubKeyBytes.add(
          int.parse(masterPubKeyHex.substring(i, i + 2), radix: 16),
        );
      }
      final sigBytes = <int>[];
      for (int i = 0; i < signatureHex.length; i += 2) {
        sigBytes.add(int.parse(signatureHex.substring(i, i + 2), radix: 16));
      }

      final simplePubKey = SimplePublicKey(
        pubKeyBytes,
        type: KeyPairType.ed25519,
      );
      final signature = Signature(sigBytes, publicKey: simplePubKey);

      final messageStr = canonicalBundleBindingMessageV3(
        version: version,
        nostrPubKeyHex: nostrPubKeyHex,
        masterKeyHex: masterPubKeyHex,
        signalIdentityPubBase64: signalIdentityPubBase64,
        registrationId: registrationId,
        bundleEpoch: bundleEpoch,
        issuedAt: issuedAt,
        expiresAt: expiresAt,
        signedPreKeyId: signedPreKeyId,
        signedPreKeyPubBase64: signedPreKeyPubBase64,
        signedPreKeySigBase64: signedPreKeySigBase64,
        sortedOtksStr: sortedOtksStr,
        oneTimePreKeys: oneTimePreKeys,
      );
      final message = utf8.encode(messageStr);
      return await _ed25519.verify(message, signature: signature);
    } catch (_) {
      return false;
    }
  }

  /// Cryptographically signs a Signal PreKey bundle binding with the Master Ed25519 key (v2 mandatory)
  Future<String> signBundleBindingToken({
    required SimpleKeyPair masterKeyPair,
    required String nostrPubKeyHex,
    required String signalIdentityPubBase64,
    required int bundleEpoch,
    required int issuedAt,
    required int expiresAt,
    int version = 2,
  }) async {
    final messageStr = canonicalBundleBindingMessage(
      version: version,
      nostrPubKeyHex: nostrPubKeyHex,
      signalIdentityPubBase64: signalIdentityPubBase64,
      bundleEpoch: bundleEpoch,
      issuedAt: issuedAt,
      expiresAt: expiresAt,
    );
    final message = utf8.encode(messageStr);
    final sig = await _ed25519.sign(message, keyPair: masterKeyPair);
    return sig.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Verifies a Signal PreKey bundle binding signed by the Master Ed25519 public key.
  /// Strictly verifies the v2 domain-separated token format with zero fallback to legacy formats.
  Future<bool> verifyBundleBindingToken({
    required String masterPubKeyHex,
    required String nostrPubKeyHex,
    required String signalIdentityPubBase64,
    required int bundleEpoch,
    required int issuedAt,
    required int expiresAt,
    int version = 2,
    required String signatureHex,
  }) async {
    try {
      if (signatureHex.isEmpty ||
          masterPubKeyHex.length != 64 ||
          signatureHex.length != 128) {
        return false;
      }
      final pubKeyBytes = <int>[];
      for (int i = 0; i < masterPubKeyHex.length; i += 2) {
        pubKeyBytes.add(
          int.parse(masterPubKeyHex.substring(i, i + 2), radix: 16),
        );
      }
      final sigBytes = <int>[];
      for (int i = 0; i < signatureHex.length; i += 2) {
        sigBytes.add(int.parse(signatureHex.substring(i, i + 2), radix: 16));
      }

      final simplePubKey = SimplePublicKey(
        pubKeyBytes,
        type: KeyPairType.ed25519,
      );
      final signature = Signature(sigBytes, publicKey: simplePubKey);

      final messageStr = canonicalBundleBindingMessage(
        version: version,
        nostrPubKeyHex: nostrPubKeyHex,
        signalIdentityPubBase64: signalIdentityPubBase64,
        bundleEpoch: bundleEpoch,
        issuedAt: issuedAt,
        expiresAt: expiresAt,
      );
      final message = utf8.encode(messageStr);
      return await _ed25519.verify(message, signature: signature);
    } catch (_) {
      return false;
    }
  }

  /// Isolated legacy v1 token generator for testing downgrade rejection
  Future<String> signLegacyV1BundleBindingTokenForTesting({
    required SimpleKeyPair masterKeyPair,
    required String nostrPubKeyHex,
    required String signalIdentityPubBase64,
    required int timestamp,
  }) async {
    final message = utf8.encode(
      'MNDO-BUNDLE-BIND:$nostrPubKeyHex:$signalIdentityPubBase64:$timestamp',
    );
    final sig = await _ed25519.sign(message, keyPair: masterKeyPair);
    return sig.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Cryptographically signs a control message (e.g. RESET_SESSION) with the Master Ed25519 key
  Future<String> signControlToken({
    required SimpleKeyPair masterKeyPair,
    required String control,
    required String recipientNostrPubKey,
    required int timestamp,
  }) async {
    final message = utf8.encode(
      'MNDO-CONTROL:$control:$recipientNostrPubKey:$timestamp',
    );
    final sig = await _ed25519.sign(message, keyPair: masterKeyPair);
    return sig.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Verifies a control message token signed by the sender's Master Ed25519 public key
  Future<bool> verifyControlToken({
    required String masterPubKeyHex,
    required String control,
    required String recipientNostrPubKey,
    required int timestamp,
    required String signatureHex,
  }) async {
    try {
      if (signatureHex.isEmpty ||
          masterPubKeyHex.length != 64 ||
          signatureHex.length != 128) {
        return false;
      }
      final pubKeyBytes = <int>[];
      for (int i = 0; i < masterPubKeyHex.length; i += 2) {
        pubKeyBytes.add(
          int.parse(masterPubKeyHex.substring(i, i + 2), radix: 16),
        );
      }
      final sigBytes = <int>[];
      for (int i = 0; i < signatureHex.length; i += 2) {
        sigBytes.add(int.parse(signatureHex.substring(i, i + 2), radix: 16));
      }

      final message = utf8.encode(
        'MNDO-CONTROL:$control:$recipientNostrPubKey:$timestamp',
      );
      final simplePubKey = SimplePublicKey(
        pubKeyBytes,
        type: KeyPairType.ed25519,
      );
      final signature = Signature(sigBytes, publicKey: simplePubKey);

      return await _ed25519.verify(message, signature: signature);
    } catch (_) {
      return false;
    }
  }
}
