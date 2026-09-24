# Contributing to MNDO

Thank you for your interest in contributing to **MNDO**! We welcome contributions from developers, security researchers, designers, and privacy advocates worldwide.

By contributing to this repository, you help build a decentralized, censorship-resistant, and mathematically secure communication platform for everyone.

---

## 📜 Code of Conduct

All contributors and participants are expected to adhere to our [Code of Conduct](CODE_OF_CONDUCT.md). Please treat fellow community members with empathy, respect, and professionalism.

---

## 🛠️ Getting Started

### Prerequisites
* **Flutter SDK**: `>= 3.13.0` ([Installation Guide](https://docs.flutter.dev/get-started/install))
* **Dart SDK**: `>= 3.0.0`
* **Git**: For version control
* **Platform Dependencies**:
  * **Windows**: Visual Studio with Desktop C++ development workload.
  * **Android**: Android SDK & Java JDK.
  * **macOS / iOS**: Xcode (`>= 14.0`).
  * **Linux**: `clang`, `cmake`, `ninja-build`, `pkg-config`, `libgtk-3-dev`.

### Fork & Clone Setup

1. **Fork the repository** on GitHub: [https://github.com/MNDO-Messenger/MNDO](https://github.com/MNDO-Messenger/MNDO)
2. **Clone your fork locally**:
   ```bash
   git clone https://github.com/<your-username>/MNDO.git
   cd MNDO
   ```
3. **Add upstream remote**:
   ```bash
   git remote add upstream https://github.com/MNDO-Messenger/MNDO.git
   ```
4. **Fetch dependencies**:
   ```bash
   flutter pub get
   ```
5. **Run the app locally**:
   ```bash
   flutter run
   ```

---

## 🧪 Testing Guidelines

**MNDO maintains a strict zero-regression policy.** All pull requests must pass the existing test suite and include tests for new functionality.

To execute the test suite:
```bash
flutter test test/widget_test.dart
```

When contributing:
- Always ensure all unit and integration tests pass before submitting a pull request.
- Add corresponding unit tests for new cryptographic parsers, protocol envelopes, state machines, or UI widgets.
- Mock network relays and cryptographic boundaries appropriately to keep tests fast and deterministic.

---

## 🔒 Architectural & Privacy Standards

MNDO has strict privacy, security, and cryptographic invariants that must never be broken:

1. **Zero Telemetry / No Centralized APIs**:
   - Never introduce tracking libraries, analytics SDKs, Google Analytics, Firebase telemetry, or third-party loggers.
   - All network communication must strictly travel via Nostr relays or decentralized media stores (Blossom).

2. **End-to-End Encryption (E2EE)**:
   - Cleartext messages or private audio files must **never** be sent over the wire.
   - All messages must be enveloped using `MndoMessageEnvelope` and encrypted via `SignalMessagingService` (Double Ratchet).
   - Audio must be locally encrypted with AES-256-GCM prior to uploading to Blossom servers.

3. **Data-at-Rest Security**:
   - All local message storage and contact identities must go through Drift backed by `sqlcipher_flutter_libs` with 256-bit encryption.
   - Key material must be securely persisted using `flutter_secure_storage`.
   - Never print raw private keys, mnemonics, or decrypted message contents to `print()` or system logs in production code.

4. **Decentralized Transport Hygiene**:
   - Connection recovery must adhere to the centralized `_markTransportUnhealthy()` pipeline with exponential backoff to avoid hammering public Nostr relays.
   - Asynchronous teardown (`_safeTeardownSubscriptions()`) must be preserved to prevent stream callback recursion.

---

## 🌿 Branching & Commit Conventions

1. Create a descriptive feature or fix branch from `main`:
   ```bash
   git checkout -b feature/voice-note-scrubber
   # or
   git checkout -b fix/relay-backoff-jitter
   ```

2. Format code and run static analysis before committing:
   ```bash
   dart format .
   flutter analyze
   flutter test test/widget_test.dart
   ```

3. Write clear, concise commit messages:
   ```bash
   git commit -m "feat(transport): add jitter to exponential backoff loop"
   # or
   git commit -m "fix(crypto): prevent untrusted identity session drop on replay"
   ```

---

## 🚀 Submitting a Pull Request (PR)

1. Push your branch to your GitHub fork:
   ```bash
   git push origin <your-branch-name>
   ```
2. Open a Pull Request against the `main` branch of `MNDO-Messenger/MNDO`.
3. Provide a clear description in your PR template:
   - What problem does this change solve?
   - How did you test and verify the fix?
   - Any relevant logs, screenshots, or screen recordings (for UI changes).

### PR Checklist
- [ ] Code follows project formatting (`dart format .`).
- [ ] No static analysis warnings (`flutter analyze`).
- [ ] All tests pass (`flutter test test/widget_test.dart`).
- [ ] No cleartext leaks, telemetry, or security compromises introduced.
- [ ] Documentation updated if relevant.

---

## 💬 Community & Questions

If you have questions about architectural decisions, protocol event kinds, or need guidance on implementing a feature, feel free to open a [GitHub Discussion](https://github.com/MNDO-Messenger/MNDO/discussions) or submit an Issue.
