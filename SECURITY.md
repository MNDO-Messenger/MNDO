# Security Policy

At **MNDO**, security and user privacy are our primary objectives. We design our architecture with the assumption that networks, relays, and intermediate transport nodes may be adversarial or compromised.

---

## 🛡️ Supported Versions

We provide security updates and patches for the following versions of MNDO:

| Version | Supported          |
| ------- | ------------------ |
| `1.x.x` (Current Main) | :white_check_mark: |
| `< 1.0.0` (Pre-release) | :x:                |

---

## 🚨 Reporting a Vulnerability

If you discover a security vulnerability or cryptographic flaw in MNDO, **please do not open a public issue or discuss it publicly.**

### How to Report Privately:
1. **GitHub Security Advisory (Preferred):**  
   Submit a confidential advisory directly through GitHub via:  
   [https://github.com/MNDO-Messenger/MNDO/security/advisories/new](https://github.com/MNDO-Messenger/MNDO/security/advisories/new)

2. **Direct Maintainer Contact:**  
   If GitHub Security Advisories are unavailable, contact the core maintainers via GitHub or secure channels with the prefix `[SECURITY VULNERABILITY]` in the subject.

### What to Include in Your Report:
To help us triage and resolve the issue quickly, please provide:
* A detailed description of the vulnerability.
* Steps to reproduce the vulnerability (proof of concept, scripts, or reproduction logs).
* The affected components (e.g., Signal ratchet implementation, Blossom encryption, SQLCipher key derivation, or Nostr envelope parsing).
* The potential impact on users (e.g., plaintext leak, identity impersonation, replay attack, denial of service).
* Any proposed fixes or remediations if available.

### Response Timeline:
* **Initial Acknowledgment:** Within **48 hours** of report receipt.
* **Triage & Assessment:** Within **7 days** with an initial severity rating and verification status.
* **Remediation & Patch:** We aim to release a patch within **14–30 days** depending on vulnerability complexity.
* **Public Disclosure:** Coordinated disclosure will occur only after a patched release is deployed to users.

---

## 🔒 Security Architecture & Guarantees

### 1. End-to-End Encryption (E2EE)
* **Double Ratchet Algorithm:** Uses `libsignal_protocol_dart` to provide **Forward Secrecy** (past messages cannot be decrypted even if current keys are compromised) and **Post-Compromise Security** (the ratchet heals automatically once compromise ceases).
* **X3DH PreKey Exchange:** Secure key agreement without requiring both peers to be online simultaneously.
* **Untrusted Identity Protection:** The app detects when a peer's identity key changes, updates local identity bindings, invalidates stale sessions, and alerts the user to potential impersonation.

### 2. Media Encryption (Voice Notes)
* **Local AES-256-GCM:** Voice notes and media are encrypted on the client device prior to network transmission using authenticated 256-bit AES-GCM with unique cryptographic nonces and authentication tags.
* **BUD-11 Nostr Authorization:** Media upload requests to Blossom servers use signed, ephemeral Nostr events (Kind `24242`) preventing unauthorized blob access.

### 3. Data at Rest
* **SQLCipher 256-bit AES:** The local SQLite database is encrypted using SQLCipher via `sqlcipher_flutter_libs`.
* **Hardware Keystore:** Encryption passphrases are generated using cryptographically secure random number generators and stored inside hardware-backed storage (`flutter_secure_storage`).
* **BIP-39 Mnemonic Identity Vault:** 12-word recovery phrases are held in secure memory and never logged to stdout, files, or telemetry.

### 4. Known Boundaries & Non-Goals
* **Relay IP Visibility:** Like all Nostr-based applications, connecting directly to public relays exposes your IP address to relay operators. Users requiring network-level anonymity should route their connections through a VPN or Tor.
* **Physical Device Compromise:** If an attacker has root/jailbreak access to your physical hardware with active memory dumping tools, key material in active RAM may theoretically be vulnerable. We recommend OS-level device encryption and biometric screen locks.

---

## 🤝 Safe Harbor

We consider security research conducted under this policy to be authorized. If you:
* Act in good faith to avoid privacy violations, data destruction, and interruption of service,
* Give us reasonable time to fix the issue before publishing details, and
* Do not access, modify, or leak other users' private communications,

we will not initiate legal action against you or request law enforcement investigation. Thank you for helping keep MNDO secure!
