import 'dart:async';
import '../database/database.dart';
import '../providers/auth_provider.dart';
import '../providers/chat_provider.dart';
import '../providers/discover_provider.dart';
import 'nostr_relay_service.dart';
import 'signal_messaging_service.dart';

/// Manages the lifecycle and generation boundaries of an authenticated account session.
/// Guarantees that logging out or switching accounts cleanly tears down all cryptographic
/// material, network subscriptions, timers, and invalidates any in-flight asynchronous callbacks.
class AccountSession {
  static int _currentGeneration = 1;

  /// The active session generation ID. Incremented on every account logout or teardown.
  static int get currentGeneration => _currentGeneration;

  /// Starts a fresh session generation (e.g. after login or identity generation)
  static int startNewSession() {
    _currentGeneration++;
    return _currentGeneration;
  }

  /// Checks if a callback originating from [generation] is still valid in the active session.
  static bool isGenerationValid(int generation) {
    return generation == _currentGeneration && _currentGeneration > 0;
  }

  /// Sets generation for testing purposes.
  static void setGenerationForTesting(int gen) {
    _currentGeneration = gen;
  }

  /// Fully tears down the current account session:
  /// 1. Increments session generation so all pending/in-flight callbacks are dropped immediately.
  /// 2. Stops and clears ChatProvider listeners, outbox timers, and chat histories.
  /// 3. Stops DiscoverProvider discovery subscriptions and heartbeat timers.
  /// 4. Disposes the active SignalMessagingService (cancels timers, clears pending keys).
  /// 5. Hard teardown of NostrRelayService (cancels timers, unregisters callbacks, closes subscriptions, disconnects transport, clears keypair).
  /// 6. Clears AppDatabase user tables if provided.
  /// 7. Clears AuthProvider credentials and IdentityRepository mnemonic/keys.
  static Future<void> dispose({
    AuthProvider? authProvider,
    ChatProvider? chatProvider,
    DiscoverProvider? discoverProvider,
    SignalMessagingService? signalService,
    NostrRelayService? nostrService,
    AppDatabase? database,
  }) async {
    final oldGen = _currentGeneration;
    _currentGeneration++;
    print('[ACCOUNT_SESSION] Disposing session generation $oldGen -> advanced to $_currentGeneration');

    // 1. Stop chat listeners and outbox timers
    try {
      chatProvider?.stopListening();
      chatProvider?.clearAllMemory();
    } catch (e) {
      print('[ACCOUNT_SESSION] Error stopping chat provider: $e');
    }

    // 2. Stop discovery and presence heartbeats
    try {
      discoverProvider?.stopHeartbeat();
      discoverProvider?.stopDiscovery();
    } catch (e) {
      print('[ACCOUNT_SESSION] Error stopping discovery provider: $e');
    }

    // 3. Invalidate and dispose Signal messaging service
    try {
      signalService?.dispose();
    } catch (e) {
      print('[ACCOUNT_SESSION] Error disposing signal service: $e');
    }

    // 4. Hard teardown of Nostr transport and singleton state
    try {
      final nostr = nostrService ?? NostrRelayService();
      await nostr.teardownSession(oldGen);
    } catch (e) {
      print('[ACCOUNT_SESSION] Error tearing down Nostr relay service: $e');
    }

    // 5. Clear database user data if provided
    try {
      if (database != null) {
        await database.clearAllUserData();
      }
    } catch (e) {
      print('[ACCOUNT_SESSION] Error clearing database data: $e');
    }

    // 6. Clear Auth credentials & Identity storage
    try {
      if (authProvider != null) {
        await authProvider.clearCredentialsOnly();
      }
    } catch (e) {
      print('[ACCOUNT_SESSION] Error clearing auth credentials: $e');
    }
  }
}
