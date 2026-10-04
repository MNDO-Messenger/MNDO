/// Canonical verified identity association binding a peer's Nostr routing key,
/// Master Ed25519 public key, and Signal Curve25519 identity key.
/// 
/// This represents an immutable cryptographic trust object created only when
/// the peer's PreKey bundle signature (masterBindingSig) has been successfully verified.
class VerifiedPeerIdentity {
  final String nostrPubKeyHex;
  final String masterPubKeyHex;
  final String signalIdentityKeyBase64;
  final DateTime verifiedAt;
  final int sessionGeneration;

  const VerifiedPeerIdentity({
    required this.nostrPubKeyHex,
    required this.masterPubKeyHex,
    required this.signalIdentityKeyBase64,
    required this.verifiedAt,
    required this.sessionGeneration,
  });

  VerifiedPeerIdentity copyWith({
    String? nostrPubKeyHex,
    String? masterPubKeyHex,
    String? signalIdentityKeyBase64,
    DateTime? verifiedAt,
    int? sessionGeneration,
  }) {
    return VerifiedPeerIdentity(
      nostrPubKeyHex: nostrPubKeyHex ?? this.nostrPubKeyHex,
      masterPubKeyHex: masterPubKeyHex ?? this.masterPubKeyHex,
      signalIdentityKeyBase64: signalIdentityKeyBase64 ?? this.signalIdentityKeyBase64,
      verifiedAt: verifiedAt ?? this.verifiedAt,
      sessionGeneration: sessionGeneration ?? this.sessionGeneration,
    );
  }

  @override
  String toString() => 'VerifiedPeerIdentity(nostr: $nostrPubKeyHex, master: $masterPubKeyHex, verifiedAt: $verifiedAt, gen: $sessionGeneration)';
}
