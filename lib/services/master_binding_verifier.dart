import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'crypto_service.dart';

enum BindingRejectionReason {
  none,
  missingMasterKey,
  missingNostrKey,
  missingSignature,
  missingTimestamp,
  missingSignalIdentity,
  invalidSignatureFormat,
  signatureVerificationFailed,
  authorMismatch,
  masterKeyMismatch,
  timestampFutureSkew,
  timestampExpired,
  missingBundleEpoch,
  invalidBundleEpoch,
  staleBundleEpoch,
  conflictingBundleEpoch,
  invalidBundleVersion,
  missingRequiredV2Fields,
  invalidValidityInterval,
}

class BindingVerificationResult {
  final bool isValid;
  final BindingRejectionReason reason;
  final String? errorMessage;
  final bool isStaleReplay;

  const BindingVerificationResult.valid({this.isStaleReplay = false})
      : isValid = true,
        reason = BindingRejectionReason.none,
        errorMessage = null;

  const BindingVerificationResult.invalid(this.reason, this.errorMessage)
      : isValid = false,
        isStaleReplay = false;

  @override
  String toString() => isValid
      ? 'BindingVerificationResult(valid, isStaleReplay: $isStaleReplay)'
      : 'BindingVerificationResult(invalid: $reason, error: $errorMessage)';
}

/// Centralized, authoritative verifier enforcing fail-closed cryptographic bindings
/// between Master Identity Keys (Ed25519), Nostr Transport Keys (secp256k1),
/// and Signal Encryption Keys (Curve25519).
class MasterBindingVerifier {
  final CryptoService cryptoService;

  MasterBindingVerifier({CryptoService? cryptoService})
      : cryptoService = cryptoService ?? CryptoService();

  /// Verifies a Kind 21111 presence ping event.
  /// Enforces mandatory presence of master key, nostr key, timestamp, and signature.
  /// Rejects future clock skew (>10m) and identifies stale replays (>80s).
  Future<BindingVerificationResult> verifyPresencePing({
    required String masterPubKeyHex,
    required String nostrPubKeyHex,
    required int? timestampMs,
    required String? signatureHex,
    DateTime? createdAt,
    required bool isOnline,
  }) async {
    if (masterPubKeyHex.isEmpty || masterPubKeyHex.length != 64) {
      return const BindingVerificationResult.invalid(
        BindingRejectionReason.missingMasterKey,
        'Master public key is missing or not 64 hex characters',
      );
    }

    if (nostrPubKeyHex.isEmpty) {
      return const BindingVerificationResult.invalid(
        BindingRejectionReason.missingNostrKey,
        'Nostr public key is missing or empty',
      );
    }

    if (signatureHex == null || signatureHex.isEmpty) {
      return const BindingVerificationResult.invalid(
        BindingRejectionReason.missingSignature,
        'Presence ping is missing masterSig delegation signature',
      );
    }

    if (signatureHex.length != 128) {
      return const BindingVerificationResult.invalid(
        BindingRejectionReason.invalidSignatureFormat,
        'masterSig delegation signature must be exactly 128 hex characters',
      );
    }

    if (timestampMs == null) {
      return const BindingVerificationResult.invalid(
        BindingRejectionReason.missingTimestamp,
        'Presence ping is missing timestamp',
      );
    }

    final now = DateTime.now();
    final nowMs = now.millisecondsSinceEpoch;
    final ageInSeconds = (nowMs - timestampMs) / 1000.0;

    // Drop pings with timestamps > 10 minutes in future
    if (ageInSeconds < -600) {
      return BindingVerificationResult.invalid(
        BindingRejectionReason.timestampFutureSkew,
        'Presence ping timestamp is > 10 minutes in the future (skew: ${ageInSeconds.toStringAsFixed(1)}s)',
      );
    }

    // Cryptographically verify delegation signature: MNDO-BIND:<nostrPubKey>:<timestamp>
    final isValidSig = await cryptoService.verifyDelegationToken(
      masterPubKeyHex: masterPubKeyHex,
      nostrPubKeyHex: nostrPubKeyHex,
      timestamp: timestampMs,
      signatureHex: signatureHex,
    );

    if (!isValidSig) {
      return const BindingVerificationResult.invalid(
        BindingRejectionReason.signatureVerificationFailed,
        'Cryptographic Ed25519 delegation signature verification failed',
      );
    }

    // Heartbeat TTL is ~70 seconds (sent every ~25s).
    // If an online ping was created > 80s ago, it's a stale event and must not revive a user as online.
    final isStaleReplay = isOnline && ageInSeconds > 80;

    return BindingVerificationResult.valid(isStaleReplay: isStaleReplay);
  }

  /// Computes a deterministic SHA-256 digest of a PreKey bundle's cryptographic contents
  static String computeBundleHash(Map<String, dynamic> bundleMap) {
    final version = bundleMap['bundleVersion'] ?? '';
    final idPub = bundleMap['identityPubKey'] ?? '';
    final masterSig = bundleMap['masterBindingSig'] ?? '';
    final epoch = bundleMap['bundleEpoch'] ?? '';
    final issued = bundleMap['issuedAt'] ?? bundleMap['timestamp'] ?? '';
    final expires = bundleMap['expiresAt'] ?? '';
    final signedPreKey = bundleMap['signedPreKey'];
    final spkPub = signedPreKey is Map ? (signedPreKey['pubKey'] ?? '') : '';
    final spkSig = signedPreKey is Map ? (signedPreKey['signature'] ?? '') : '';
    final canonical = '$version|$idPub|$masterSig|$epoch|$issued|$expires|$spkPub|$spkSig';
    return sha256.convert(utf8.encode(canonical)).toString();
  }

  /// Verifies a Kind 10446 Signal PreKey bundle before establishing a session.
  /// Enforces author matching, master key pinning, mandatory v2 protocol version,
  /// monotonic epoch (anti-rollback), semantic validity intervals, and cryptographic binding.
  Future<BindingVerificationResult> verifyPreKeyBundle({
    required String expectedMasterPubKeyHex,
    required String recipientNostrPubKey,
    required Map<String, dynamic> bundleMap,
    String? eventAuthor,
    int? storedEpoch,
    String? storedBundleHash,
    int? nowMs,
  }) async {
    if (expectedMasterPubKeyHex.isEmpty || expectedMasterPubKeyHex.length != 64) {
      return const BindingVerificationResult.invalid(
        BindingRejectionReason.missingMasterKey,
        'Expected master public key is missing or not 64 hex characters',
      );
    }

    // Author check
    if (eventAuthor != null && eventAuthor.isNotEmpty && eventAuthor != recipientNostrPubKey) {
      return BindingVerificationResult.invalid(
        BindingRejectionReason.authorMismatch,
        'PreKey bundle event author ($eventAuthor) does not match expected recipient ($recipientNostrPubKey)',
      );
    }

    // Master key consistency check
    final bundleMaster = bundleMap['masterKey'] as String?;
    if (bundleMaster != null && bundleMaster != expectedMasterPubKeyHex) {
      return BindingVerificationResult.invalid(
        BindingRejectionReason.masterKeyMismatch,
        'PreKey bundle master key ($bundleMaster) does not match expected master ($expectedMasterPubKeyHex)',
      );
    }

    // Mandatory Protocol Version Check (v2 required, CRYPTO-PK-01A)
    final bundleVersion = bundleMap['bundleVersion'];
    if (bundleVersion != 2) {
      return const BindingVerificationResult.invalid(
        BindingRejectionReason.invalidBundleVersion,
        'PreKey bundle bundleVersion must be 2',
      );
    }

    // Mandatory v2 Fields Check
    final masterBindingSig = bundleMap['masterBindingSig'] as String?;
    final identityPubBase64 = bundleMap['identityPubKey'] as String?;
    final issuedAt = bundleMap['issuedAt'] as int?;
    final expiresAt = bundleMap['expiresAt'] as int?;
    final bundleEpoch = bundleMap['bundleEpoch'] as int?;

    if (bundleEpoch == null || issuedAt == null || expiresAt == null) {
      return const BindingVerificationResult.invalid(
        BindingRejectionReason.missingRequiredV2Fields,
        'PreKey bundle is missing mandatory v2 security fields (bundleEpoch, issuedAt, expiresAt)',
      );
    }

    if (masterBindingSig == null || masterBindingSig.isEmpty) {
      return const BindingVerificationResult.invalid(
        BindingRejectionReason.missingSignature,
        'PreKey bundle is missing required masterBindingSig',
      );
    }

    if (masterBindingSig.length != 128) {
      return const BindingVerificationResult.invalid(
        BindingRejectionReason.invalidSignatureFormat,
        'PreKey bundle masterBindingSig must be exactly 128 hex characters',
      );
    }

    if (identityPubBase64 == null || identityPubBase64.isEmpty) {
      return const BindingVerificationResult.invalid(
        BindingRejectionReason.missingSignalIdentity,
        'PreKey bundle is missing identityPubKey (Signal identity key)',
      );
    }

    // Epoch validity check (must be non-negative)
    if (bundleEpoch < 0) {
      return const BindingVerificationResult.invalid(
        BindingRejectionReason.invalidBundleEpoch,
        'PreKey bundle bundleEpoch must be a non-negative integer',
      );
    }

    // Semantic timestamp freshness & validity interval checks
    final current = nowMs ?? DateTime.now().millisecondsSinceEpoch;

    // Bounded future clock skew check (10 minutes)
    if (issuedAt > current + 600000) {
      return const BindingVerificationResult.invalid(
        BindingRejectionReason.timestampFutureSkew,
        'PreKey bundle issuedAt timestamp is in the future beyond allowed clock skew (10m)',
      );
    }

    // Validity interval consistency: expiresAt must be strictly greater than issuedAt
    if (expiresAt <= issuedAt) {
      return const BindingVerificationResult.invalid(
        BindingRejectionReason.invalidValidityInterval,
        'PreKey bundle expiresAt must be strictly greater than issuedAt',
      );
    }

    // Maximum allowed bundle lifetime: 30 days
    const maxBundleLifetimeMs = 30 * 24 * 60 * 60 * 1000;
    if (expiresAt - issuedAt > maxBundleLifetimeMs) {
      return const BindingVerificationResult.invalid(
        BindingRejectionReason.invalidValidityInterval,
        'PreKey bundle validity interval exceeds maximum allowed lifetime (30 days)',
      );
    }

    // Expiration check
    if (current > expiresAt) {
      return const BindingVerificationResult.invalid(
        BindingRejectionReason.timestampExpired,
        'PreKey bundle has expired (current time exceeds expiresAt)',
      );
    }

    // Cryptographic verification of v2 token with ZERO fallback to v1
    final isValid = await cryptoService.verifyBundleBindingToken(
      masterPubKeyHex: expectedMasterPubKeyHex,
      nostrPubKeyHex: recipientNostrPubKey,
      signalIdentityPubBase64: identityPubBase64,
      bundleEpoch: bundleEpoch,
      issuedAt: issuedAt,
      expiresAt: expiresAt,
      version: 2,
      signatureHex: masterBindingSig,
    );

    if (!isValid) {
      return const BindingVerificationResult.invalid(
        BindingRejectionReason.signatureVerificationFailed,
        'Cryptographic Ed25519 bundle binding signature verification failed',
      );
    }

    // Anti-rollback / monotonic epoch verification against persisted state (evaluated only after cryptographic signature verification!)
    if (storedEpoch != null) {
      if (bundleEpoch < storedEpoch) {
        return BindingVerificationResult.invalid(
          BindingRejectionReason.staleBundleEpoch,
          'Candidate PreKey bundle epoch ($bundleEpoch) is older than accepted epoch ($storedEpoch)',
        );
      } else if (bundleEpoch == storedEpoch) {
        final candidateHash = computeBundleHash(bundleMap);
        if (storedBundleHash != null && storedBundleHash.isNotEmpty && candidateHash != storedBundleHash) {
          return BindingVerificationResult.invalid(
            BindingRejectionReason.conflictingBundleEpoch,
            'Candidate PreKey bundle conflicts with already accepted bundle for epoch $bundleEpoch',
          );
        }
      }
    }

    return const BindingVerificationResult.valid();
  }

  /// Verifies a control message (e.g. RESET_SESSION).
  /// Strictly requires a valid signature and timestamp; no unsigned fallback allowed.
  Future<BindingVerificationResult> verifyControlMessage({
    required String? senderMasterPubKeyHex,
    required String controlType,
    required String recipientNostrPubKey,
    required int? timestampMs,
    required String? signatureHex,
  }) async {
    if (senderMasterPubKeyHex == null ||
        senderMasterPubKeyHex.isEmpty ||
        senderMasterPubKeyHex.length != 64) {
      return const BindingVerificationResult.invalid(
        BindingRejectionReason.missingMasterKey,
        'Control message sender master key is missing or invalid',
      );
    }

    if (signatureHex == null || signatureHex.isEmpty) {
      return const BindingVerificationResult.invalid(
        BindingRejectionReason.missingSignature,
        'Control message is missing required cryptographic signature',
      );
    }

    if (signatureHex.length != 128) {
      return const BindingVerificationResult.invalid(
        BindingRejectionReason.invalidSignatureFormat,
        'Control message signature must be 128 hex characters',
      );
    }

    if (timestampMs == null) {
      return const BindingVerificationResult.invalid(
        BindingRejectionReason.missingTimestamp,
        'Control message is missing timestamp',
      );
    }

    final isValid = await cryptoService.verifyControlToken(
      masterPubKeyHex: senderMasterPubKeyHex,
      control: controlType,
      recipientNostrPubKey: recipientNostrPubKey,
      timestamp: timestampMs,
      signatureHex: signatureHex,
    );

    if (!isValid) {
      return const BindingVerificationResult.invalid(
        BindingRejectionReason.signatureVerificationFailed,
        'Control message Ed25519 signature verification failed',
      );
    }

    return const BindingVerificationResult.valid();
  }

  /// Verifies that a profile metadata event (Kind 0) originates from the
  /// user's verified Nostr routing public key.
  BindingVerificationResult verifyProfileMetadataAuthor({
    required String masterPubKeyHex,
    required String eventAuthorNostrPubKey,
    required String pinnedNostrPubKey,
  }) {
    if (eventAuthorNostrPubKey != pinnedNostrPubKey) {
      return BindingVerificationResult.invalid(
        BindingRejectionReason.authorMismatch,
        'Kind 0 profile author ($eventAuthorNostrPubKey) does not match verified Nostr key ($pinnedNostrPubKey)',
      );
    }

    return const BindingVerificationResult.valid();
  }
}
