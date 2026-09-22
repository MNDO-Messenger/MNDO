# MNDO - Architecture & Instructions

## Core Tech Stack
- **Framework**: Flutter
- **Networking**: Nostr Protocol (Relays)
- **Encryption**: Signal Protocol (Double Ratchet, PreKeys)
- **Local Database**: SQLite via Drift (`sqlcipher_flutter_libs` for at-rest encryption)
- **State Management**: `provider` (MultiProvider with ProxyProvider for Dependency Injection)

## Architecture

The application is structured into four main layers to prevent monolithic classes and ensure maintainability.

### 1. UI Layer (`lib/ui/`)
Contains all Flutter screens and widgets. 
- UI components should **only** be responsible for rendering data and handling user inputs.
- They consume State via `context.watch<ProviderName>()` or `Consumer<ProviderName>`.

### 2. State Management Layer (`lib/providers/`)
Holds the business logic and exposes state to the UI.
- **`AuthProvider`**: Manages user identity, onboarding, and active keys.
- **`ChatProvider`**: Manages active chats, messages, unread counts, and orchestrates sending/receiving messages.
- **`DiscoverProvider`**: Manages the "Discover" feed and online status (heartbeats) of users.

### 3. Services Layer (`lib/services/`)
Handles complex, asynchronous external operations.
- **`NostrRelayService`**: Manages WebSocket connections and Nostr Event publishing/subscriptions.
- **`CryptoService`**: Generates cryptographic keys and identities.
- **`SignalMessagingService`**: Handles the complex Signal Protocol handshakes, PreKey bundling, encryption, and decryption of messages.
- **`SignalStore`**: Implements the required interfaces for the Signal Protocol to store keys and sessions.

### 4. Data Layer (`lib/models/`, `lib/repositories/`)
- **Models**: Pure data classes (`DiscoverUser`, `ChatMessage`).
- **Repositories**: 
  - `ChatRepository`: Abstracts all Drift database queries.
  - `IdentityRepository`: Abstracts all secure storage operations (reading/writing to `flutter_secure_storage`).

## Dependency Injection Graph
Dependencies are injected sequentially in `main.dart` using `MultiProvider`:

1. `AppDatabase` (Drift)
2. `ChatRepository` & `IdentityRepository`
3. `NostrRelayService` & `CryptoService`
4. `AuthProvider`
5. `SignalMessagingService` (Requires Identity/Keys from AuthProvider)
6. `ChatProvider` & `DiscoverProvider`

## Guidelines for Adding Features
1. **Never use the UI for Business Logic**: If a button needs to encrypt and send a message, the UI should call `chatProvider.sendMessage(text)`, and the Provider should coordinate with the `SignalMessagingService`.
2. **Avoid God Objects**: Do not add unrelated functionality to existing providers. Create a new Provider or Service if necessary.
3. **Database Security**: All local storage must be encrypted. Use `IdentityRepository` (Secure Storage) for keys and `ChatRepository` (SQLCipher) for messages.
