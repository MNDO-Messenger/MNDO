# MNDO Messenger

<div align="center">

**Decentralized • End-to-End Encrypted • Zero Metadata • Sovereign Identity**

[![Flutter](https://img.shields.io/badge/Flutter-3.13+-02569B?logo=flutter&logoColor=white)](https://flutter.dev)
[![Dart](https://img.shields.io/badge/Dart-3.0+-0175C2?logo=dart&logoColor=white)](https://dart.dev)
[![Protocol](https://img.shields.io/badge/Protocol-Nostr-purple)](https://nostr.com)
[![Encryption](https://img.shields.io/badge/E2EE-Signal_Protocol-brightgreen)](https://signal.org/docs/)
[![License: AGPL v3](https://img.shields.io/badge/License-AGPL_v3-blue.svg)](LICENSE)
[![Platforms](https://img.shields.io/badge/Platforms-Android_%7C_iOS_%7C_Windows_%7C_Linux_%7C_macOS-lightgrey)](#)

</div>

---

## 📖 Overview

**MNDO** is a peer-to-peer, decentralized, and zero-compromise privacy messaging application built with Flutter. It combines the censorship-resistant relay transport of the **Nostr protocol** with the cryptographically audited **Signal Protocol (Double Ratchet + X3DH)** for true End-to-End Encryption (E2EE).

With MNDO, you have:
* **No phone numbers or emails required.**
* **No central servers, telemetry, or user databases.**
* **Sovereign cryptographic identity** derived deterministically from a standard BIP-39 12-word recovery phrase.
* **Encrypted storage at rest** using SQLCipher 256-bit AES encryption.

---

## 🌟 Key Features

### 🔒 Military-Grade End-to-End Encryption (E2EE)
* **Signal Double Ratchet (`libsignal_protocol_dart`):** Every chat exchange continuously ratchets cryptographic keys forward, providing Forward Secrecy and Post-Compromise Security.
* **X3DH PreKey Infrastructure:** Automatic generation and decentralized publication of Signed PreKeys and One-Time PreKeys, enabling peers to initiate secure encrypted sessions even when you are offline.
* **Untrusted Identity Protection:** Automatic session recovery and visual safety alerts if a peer's identity key changes or their device is reinstalled.
* **Formal Envelope Protocol:** Strict, versioned `MndoMessageEnvelope` payload format with message ID deduplication and anti-replay guards.

### 🎙️ End-to-End Encrypted Voice Notes
* **Client-Side AES-256-GCM:** Voice notes are recorded and encrypted directly on the device with a unique 256-bit symmetric key, nonce, and MAC tag.
* **Decentralized Media Storage (Blossom):** Uploads encrypted audio blobs across distributed Blossom servers (`blossom.primal.net`, `cdn.satellite.earth`, `nostr.download`) using cryptographically signed BUD-11 Nostr authorization headers (Kind `24242`).
* **In-App Interactive Player:** Real-time waveform rendering, interactive seek scrubbing, playback coordination (single-audio invariant), and sender instant-playback support.

### ⚡ Self-Healing WebSocket Transport Architecture
* **Strict Reconnect State Machine:** Deterministic lifecycle states (`disconnected` → `connecting` → `connected` → `resubscribing` → `ready`).
* **Centralized Recovery Pipeline:** Immediate trigger on relay errors, WebSocket closure, or watchdog alerts via `_markTransportUnhealthy()`.
* **Safe Asynchronous Teardown:** Stream subscriptions are decoupled and cancelled via microtasks to eliminate callback recursion during connection loss.
* **Exponential Backoff with Jitter:** Automatic reconnect backoff (1s → 2s → 4s → 8s → 16s → 30s) with randomized jitter (±250ms) to avoid relay rate-limiting and thundering herd storms.
* **Network Awareness:** Seamless recovery across Wi-Fi/Cellular handovers powered by `connectivity_plus`.
* **Liveness Tracking:** Real-time monitoring of relay activity (`lastRelayActivity`) and fallback watchdog heartbeat.

### 👥 Real-Time Presence & Heartbeat Engine
* **Decentralized Presence (Kind 21111):** Ephemeral peer status pings signed by master key delegation tokens.
* **Clock-Skew & Monotonicity Resilient:** Remote clock discrepancies are handled smoothly using local arrival normalization.
* **3-Minute Replay Window & 7-Day Discovery Retention:** Automatically cleans up stale presence revivals and preserves announced contacts up to 7 days.
* **Instant Offline Announcements:** Broadcasts immediate offline status on desktop window close or mobile app backgrounding.

### 💬 Modern Telegram & WhatsApp UI/UX
* **Focus-Aware Read Receipts:**
  - 🕒 Clock: Message sending / in transit.
  - ✓ Single grey tick: Published to relay network.
  - ✓✓ Double grey ticks: Delivered to recipient's device.
  - ✓✓ Double blue ticks: Read by recipient (only triggered when the chat is active and the application window is actually focused).
* **Rich Markdown Formatting:** Real-time parsing of WhatsApp-style syntax:
  - `*bold*` → **bold**
  - `_italic_` → *italic*
  - `~strikethrough~` → ~strikethrough~
  - ```` ```code``` ```` → monospace code block
  - `> quote` → blockquotes with visual accent bars
  - Lists: Ordered (`1. `) and Bullet (`- `) auto-formatting
* **Multi-Platform Adaptive Layout:**
  - **Desktop:** Telegram-style header with WhatsApp-style collapsible contact info side panel.
  - **Mobile:** Adaptive full-screen views with swipeable bottom sheets.

### 🗄️ At-Rest Encrypted Vault
* **SQLCipher Encrypted Database:** Drift ORM with full at-rest SQLite database encryption.
* **Secure Key Storage:** Database passphrase protected in system keystores via `flutter_secure_storage`.
* **BIP-39 Mnemonic Identity Vault:** 12-word seed phrase generator and validator with secure clipboard clearing.

---

## 📐 Protocol Specification & Event Kinds

| Event Kind | Purpose | Encryption & Format |
|---|---|---|
| **`Kind 0`** | User Profile & Identity | Public metadata (Display Name, Username, Bio) |
| **`Kind 4444`** | Encrypted Application Messages | Signal Ciphertext (Double Ratchet) containing `MndoMessageEnvelope` |
| **`Kind 10002`** | Relay List Discovery | Relay list metadata (NIP-65) |
| **`Kind 21111`** | Ephemeral Presence Pings | Encrypted / Authenticated heartbeats with master delegation signatures |
| **`Kind 24242`** | Blossom Media Authorization | BUD-11 signed authorization tokens for Blossom server uploads |
| **Custom Kind** | Signal PreKey Bundles | Signed PreKeys, Identity Keys, and One-Time PreKey pools |

---

## 🛠️ Tech Stack

* **Framework:** [Flutter](https://flutter.dev) (Dart 3+)
* **State Management:** `flutter_riverpod` & `provider`
* **Cryptography:**
  * `libsignal_protocol_dart` (Signal Protocol: Double Ratchet, X3DH)
  * `cryptography` (AES-256-GCM, HMAC, SHA-256)
  * `bip39` (Deterministic mnemonic identities)
* **Networking:** `dart_nostr` (Nostr protocol over WebSockets)
* **Database & Persistence:**
  * `drift` (SQLite ORM)
  * `sqlcipher_flutter_libs` (256-bit AES at-rest encryption)
  * `flutter_secure_storage` (Hardware-backed secure enclave key storage)
* **Audio & Media:** `record` & `audioplayers`
* **Desktop Window Management:** `window_manager`

---

## 🚀 Getting Started

### Prerequisites
* [Flutter SDK](https://docs.flutter.dev/get-started/install) (`>= 3.13.0`)
* [Dart SDK](https://dart.dev/get-started) (`>= 3.0.0`)
* **Windows Desktop:** Visual Studio with C++ Desktop Development Tools.
* **Android:** Android SDK / Java JDK.
* **Linux:** `clang`, `cmake`, `ninja-build`, `pkg-config`, `libgtk-3-dev`.
* **macOS / iOS:** Xcode (`>= 14.0`).

### Installation

1. **Clone the repository:**
   ```bash
   git clone https://github.com/MNDO-Messenger/MNDO.git
   cd MNDO
   ```

2. **Install Flutter packages:**
   ```bash
   flutter pub get
   ```

3. **Run in development mode:**
   ```bash
   # Run on Windows Desktop
   flutter run -d windows

   # Run on Android Device / Emulator
   flutter run -d android

   # Run on macOS / iOS
   flutter run -d macos
   ```

4. **Build Production Release Binaries:**
   ```bash
   # Windows Standalone (.exe)
   flutter build windows

   # Android APK (.apk)
   flutter build apk --release

   # Android App Bundle (.aab for Google Play)
   flutter build appbundle
   ```

---

## 🧪 Testing & Verification

MNDO has a comprehensive automated test suite covering all critical cryptographic paths, transport states, and UX behaviors:

```bash
flutter test test/widget_test.dart
```

### Test Coverage Highlights:
* ✅ **Model Smoke & Sorting:** DiscoverUser offline calculation, chronological ordering, and search filtering.
* ✅ **WhatsApp & Markdown Formatting:** List continuations, blockquotes, code blocks, and rich text tokens.
* ✅ **BIP-39 Mnemonic Validation:** Valid word lists, checksum validation, and seed generation.
* ✅ **Voice Notes E2EE:** AES-256-GCM byte integrity, Blossom upload payloads, interactive bubble rendering, and audio coordinator state isolation.
* ✅ **Signal Protocol:** Untrusted identity recovery, PreKey bundle exhaustion fallbacks, and duplicate message detection.
* ✅ **Presence Engine:** Clock-skew resilience, out-of-order rejection, replay prevention, and lifecycle state changes.
* ✅ **Nostr Transport:** State machine transitions, centralized recovery pipeline (`_markTransportUnhealthy`), backoff calculation, and subscription registry.

---

## 🔒 Security Architecture

```
[ BIP-39 12-Word Mnemonic Vault ]
               │
       ┌───────┴───────┐
       ▼               ▼
[ Master Keypair ]   [ Nostr Relays Keypair ]
 (secp256k1 Identity) (Ephemeral Transport)
       │                       │
       ▼                       ▼
[ Signal Double Ratchet ] [ Nostr Relay Network ]
 (X3DH PreKeys + E2EE)    (Kind 4444 Encrypted Payloads)
       │
       ▼
[ Local SQLCipher Database (256-bit AES) ]
```

1. **Deterministic Identity Derivation:** Your Master Identity Key is derived using standard BIP-39 PBKDF2 with SHA-512 from your 12-word mnemonic.
2. **Master Key Delegation:** Network transport Nostr keys are decoupled from Master Identity Keys. The app creates cryptographic delegation signatures, proving identity without exposing master private keys on relays.
3. **Double Ratchet Secrecy:** Direct messages are encrypted with ephemeral session keys. Compromising a single key exposes only that specific message, never past or future messages.
4. **Data at Rest Protection:** The local SQLite database is fully encrypted with SQLCipher; keys are stored in the device's hardware Keystore / Keychain.

---

## 📄 License

MNDO is free software licensed under the **GNU Affero General Public License v3.0 (AGPLv3)**. See the [LICENSE](LICENSE) file for details.
