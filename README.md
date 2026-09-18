# MNDO

MNDO is a decentralized, secure, and privacy-focused messaging application built with Flutter. It leverages the Nostr protocol for decentralized networking and implements the Signal Protocol (Double Ratchet) for robust End-to-End Encryption (E2EE).

## 🌟 Key Features

*   **Decentralized Networking:** Uses the Nostr Protocol (`dart_nostr`) to route messages through decentralized relays, ensuring no central server has control over your data.
*   **End-to-End Encryption (E2EE):** All direct messages are encrypted using the Signal Protocol (`libsignal_protocol_dart`), utilizing Double Ratchet and PreKeys to ensure forward secrecy and post-compromise security.
*   **Local Encrypted Database:** Your data never leaves your device unencrypted. Local persistence is managed by SQLite via Drift, with at-rest database encryption provided by `sqlcipher_flutter_libs`.
*   **Privacy First:** No phone numbers, emails, or central accounts are required. Your identity is a cryptographic keypair.
*   **Offline Support & Key Broadcasting:** PreKeys are securely broadcasted on startup, allowing peers to initiate secure sessions and send messages even when you are offline or hidden.
*   **Cross-Platform:** Built with Flutter, supporting Android, iOS, Windows, and macOS with a unified, responsive UI.

## 🛠️ Architecture & Tech Stack

*   **UI/Framework:** Flutter & Dart
*   **State Management:** `provider`
*   **Networking:** `dart_nostr` (Nostr Protocol over WebSockets)
*   **Cryptography:** `libsignal_protocol_dart` (E2EE), `cryptography`, `crypto`
*   **Local Storage:** `drift` (SQLite ORM) with `sqlcipher` (Encrypted at-rest)
*   **Dependency Injection:** Cascading `ProxyProvider` architecture ensuring highly decoupled services.

## 📦 Getting Started

### Prerequisites

*   Flutter SDK (3.13.1 or higher)
*   Dart SDK

### Installation

1.  **Clone the repository:**
    ```bash
    git clone https://github.com/MNDO-Messenger/MNDO.git
    cd MNDO
    ```

2.  **Install dependencies:**
    ```bash
    flutter pub get
    ```

3.  **Run the app:**
    ```bash
    flutter run
    ```

## 🔒 Security Model

MNDO uses the Signal Protocol over the Nostr network. 
*   **Public Key Infrastructure:** Users discover each other using Nostr public keys.
*   **Session Establishment:** The app broadcasts signed PreKey bundles to the Nostr network (using specific custom event kinds). When User A wants to message User B, they fetch User B's PreKey bundle and establish a secure Signal session.
*   **Data at Rest:** The local SQLite database is encrypted with a 256-bit secure key stored securely in the device's keystore/keychain using `flutter_secure_storage`.

## 🤝 Contributing

Contributions, issues, and feature requests are welcome! Feel free to check the issues page.

## 📄 License

This project is open-source and available under the AGPLv3 License.
