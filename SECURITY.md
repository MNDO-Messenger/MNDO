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

### 2. Media Transport Security & Attachment Architecture

* **Attachment Size Enforcement:** MNDO strictly enforces client-side file size guards at transmission boundaries to prevent memory exhaustion, abuse, and network stalls:
  * **Images:** Maximum 20 MB (`20 * 1024 * 1024` bytes).
  * **Audio & Voice Notes:** Maximum 25 MB (`25 * 1024 * 1024` bytes).
  * **Videos & Documents:** Maximum 100 MB (`100 * 1024 * 1024` bytes).
  Any payload exceeding these bounds is rejected before disk reading or cryptographic processing.
* **BUD-11 Nostr Authorization:** Media upload requests to decentralized Blossom servers use signed, ephemeral Nostr events (Kind `24242`) preventing unauthorized blob access.

#### Current Media Format: Single-Blob AES-256-GCM (Version 1)
* **Encryption Scheme:** The media binary is encrypted client-side using authenticated 256-bit AES-GCM with a randomly generated ephemeral symmetric key, a 96-bit nonce, and a 128-bit authentication tag (`mac`).
* **Integrity & Addressing:** The encrypted ciphertext is hashed using SHA-256 (`fileHash`) to derive the canonical Blossom blob identifier.
* **Envelope Delivery:** The symmetric key, nonce, MAC tag, file hash, and metadata (dimensions, duration, MIME type) are encapsulated within the inner Signal ratchet envelope, ensuring only the intended recipient can obtain decryption keys.

#### Architectural Specification: Chunked & Streaming Encryption (Version 2 Media Payload)
To support seamless transport of large attachments (up to 100 MB) without peak in-memory buffer pressure or mobile OS out-of-memory terminations, MNDO specifies the Version 2 Media Payload architecture:

1. **Deterministic Stream Chunking:**
   * Files exceeding a threshold (default 4 MB) are partitioned into fixed-size chunks of $C = 2\,\text{MB}$ ($2{,}097{,}152$ bytes), with the final chunk containing the residual bytes.
   * Each chunk $i \in [0, N-1]$ is encrypted independently with AES-256-GCM using:
     * File Base Key: $K_{\text{media}} \leftarrow \text{CSPRNG}(256\text{ bits})$
     * Per-Chunk Nonce: $Nonce_i = Nonce_0 \oplus \text{BigEndian}(i)$ (where $Nonce_0$ is a random 96-bit initialization vector).
     * Authentication Tag: $T_i \leftarrow \text{AES-GCM-Tag}(K_{\text{media}}, Nonce_i, Chunk_i)$.

2. **Chunk Manifest & Merkle Integrity Root:**
   * Each encrypted chunk produces an individual SHA-256 hash: $H_i = \text{SHA-256}(Ciphertext_i)$.
   * The manifest integrity root is computed hierarchically:
     $$\mathcal{H}_{\text{root}} = \text{SHA-256}(H_0 \parallel H_1 \parallel \dots \parallel H_{N-1})$$
   * The V2 payload JSON includes:
     ```json
     {
       "version": 2,
       "type": "media",
       "mediaType": "video",
       "chunkSize": 2097152,
       "totalChunks": 25,
       "totalSize": 51200000,
       "key": "<base64-aes-256-key>",
       "nonce": "<base64-96bit-nonce0>",
       "rootHash": "<hex-sha256-merkle-root>",
       "chunks": [
         {"index": 0, "hash": "<sha256-0>", "mac": "<base64-mac-0>", "url": "<blossom-url-0>"},
         {"index": 1, "hash": "<sha256-1>", "mac": "<base64-mac-1>", "url": "<blossom-url-1>"}
       ]
     }
     ```

3. **Streaming Decryption & Fail-Closed Tamper Detection:**
   * Decryption operates as a progressive stream directly into the local encrypted cache.
   * Prior to writing chunk $i$ to disk or feeding to playback buffers, the client verifies $H_i == \text{SHA-256}(Ciphertext_i)$ and evaluates $T_i$ with AES-256-GCM.
   * If any chunk fails MAC authentication or hash verification, the stream terminates immediately, partial decrypted data is deleted, and the user is alerted to corrupt or tampered media.

4. **Backward Compatibility Strategy:**
   * Clients check the `version` field of incoming media payloads:
     * If `version == 2`: Use the streaming chunked decryptor pipeline.
     * If `version` is absent or `1`: Treat as a legacy single-blob payload using single-buffer AES-256-GCM decryption.
   * Historical messages, voice notes, and smaller media continue functioning without modification.

### 3. Data at Rest
* **SQLite3MultipleCiphers 256-bit AES:** The local SQLite database is encrypted using SQLite3MultipleCiphers via the `sqlite3mc` build hook, enforcing fail-closed key validation (`PRAGMA cipher_version`).
* **Hardware Keystore:** Database encryption passphrases and master mnemonic materials are stored securely in hardware-backed storage (`flutter_secure_storage`).
* **BIP-39 Mnemonic Identity Vault:** 12-word recovery phrases are held in secure memory and never logged to stdout, files, or telemetry.
* **Bounded Sensitive Media Cache:** Managed media and voice caches are bounded by TTL and byte budgets (500 MB) and subjected to verified best-effort filesystem deletion on logout. SQLite3MultipleCiphers protects encrypted records at rest, while cached plaintext media files undergo verified unlinking and directory removal.

### 4. Metadata Scope & Known Boundaries

> **Privacy Guarantee:** MNDO uses end-to-end encryption for message contents and decentralized relays for delivery. Relays and storage providers may observe connection IP addresses, public keys, timestamps, traffic size and some presence/profile metadata.

#### Concise Metadata Disclosure Matrix

| Data Category | What Peers Can See | What Nostr Relays Can See | What Blossom Storage Operators Can See | What Remains E2EE Encrypted |
|---|---|---|---|---|
| **Message Contents** (text, voice, media keys) | Plaintext after Signal Double Ratchet decryption | Ciphertext payload only (`Kind 4444`) | Nothing | Full content, envelopes, and keys (Signal Protocol) |
| **Recipient & Sender Routing** | Sender & Recipient keys | Outer Nostr recipient `p` tag, sender ephemeral key | Nothing | Sender sovereign master key binding inside Signal ciphertext |
| **Network IP Address** | Hidden behind relays | Connecting device public IP & port | Uploading / downloading device public IP | N/A (transport-level connection metadata) |
| **Traffic Timing & Size** | Message arrival time & size | Packet arrival time, WebSocket frame size | Blob upload/download time & file size | Exact plaintext length (masked by encryption padding) |
| **Media Attachments** | Decrypted image/audio/video | Nothing (stored on Blossom) | Encrypted ciphertext blob (`fileHash`, byte size) | Decryption key, nonce, MAC tag, and file metadata |
| **Presence & Profile** | Online/offline status, username, avatar (if opted-in) | Ephemeral presence pings (`Kind 21111`), profile metadata (`Kind 0`) | Nothing | Suppressed completely when hidden mode is active (`isAnnounced: false`) |

* **Physical Device Compromise:** If an attacker has root/jailbreak access to your physical hardware with active memory dumping tools, key material in active RAM may theoretically be vulnerable. We recommend OS-level device encryption and biometric screen locks.

---

## 🤝 Safe Harbor

We consider security research conducted under this policy to be authorized. If you:
* Act in good faith to avoid privacy violations, data destruction, and interruption of service,
* Give us reasonable time to fix the issue before publishing details, and
* Do not access, modify, or leak other users' private communications,

we will not initiate legal action against you or request law enforcement investigation. Thank you for helping keep MNDO secure!
