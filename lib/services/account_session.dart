import 'dart:async';
import '../database/database.dart';
import '../providers/auth_provider.dart';
import '../providers/chat_provider.dart';
import '../providers/discover_provider.dart';
import 'nostr_relay_service.dart';
import 'signal_messaging_service.dart';
import 'voice_note_cache_manager.dart';

/// Lifecycle states governing account isolation and session transitions.
enum AccountLifecycleState {
  active,
  tearingDown,
  readyForReplacement,
  starting,
  teardownFailed,
}

/// Manages the lifecycle and generation boundaries of an authenticated account session.
/// Guarantees that logging out or switching accounts cleanly tears down all cryptographic
/// material, network subscriptions, timers, and invalidates any in-flight asynchronous callbacks.
class AccountSession {
  static int _currentGeneration = 1;
  static final StreamController<int> _generationController = StreamController<int>.broadcast();
  static AccountLifecycleState _state = AccountLifecycleState.active;
  static Future<void> _lifecycleLock = Future.value();

  /// Current lifecycle state of the account session.
  static AccountLifecycleState get state => _state;

  /// Stream of session generations emitted on logout, account switch, or teardown.
  static Stream<int> get generationStream => _generationController.stream;

  /// The active session generation ID. Incremented on every account logout or teardown.
  static int get currentGeneration => _currentGeneration;

  static final _lockZoneKey = Object();

  /// Serializes lifecycle transitions so teardown and new-account initialization never interleave.
  /// Re-entrant safe when called from within an active synchronized context.
  static Future<T> synchronize<T>(Future<T> Function() action) {
    if (Zone.current[_lockZoneKey] == true) {
      return action();
    }

    final prev = _lifecycleLock;
    final completer = Completer<void>();
    _lifecycleLock = completer.future;

    return prev.then((_) {
      return runZoned(
        () => action(),
        zoneValues: {_lockZoneKey: true},
      );
    }).whenComplete(() {
      completer.complete();
    });
  }

  /// Starts a fresh session generation (e.g. after login or identity generation)
  static int startNewSession() {
    if (_state == AccountLifecycleState.tearingDown) {
      throw StateError('Cannot start new session: account teardown is currently in progress');
    }
    if (_state == AccountLifecycleState.teardownFailed) {
      throw StateError('Cannot start new session: previous account teardown failed closed');
    }
    _state = AccountLifecycleState.starting;
    _currentGeneration++;
    _state = AccountLifecycleState.active;
    _generationController.add(_currentGeneration);
    return _currentGeneration;
  }

  /// Checks if a callback originating from [generation] is still valid in the active session.
  static bool isGenerationValid(int generation) {
    return generation == _currentGeneration && _currentGeneration > 0 && _state == AccountLifecycleState.active;
  }

  /// Sets generation for testing purposes.
  static void setGenerationForTesting(int gen) {
    _state = AccountLifecycleState.active;
    _currentGeneration = gen;
    _generationController.add(_currentGeneration);
  }

  /// Resets lifecycle lock and state for testing.
  static void resetForTesting() {
    _state = AccountLifecycleState.active;
    _currentGeneration = 1;
    _lifecycleLock = Future.value();
  }

  /// Fully tears down the current account session under the lifecycle lock:
  /// 1. Acquires lifecycle lock and sets state to TEARING_DOWN.
  /// 2. Increments session generation so all pending/in-flight callbacks are dropped immediately.
  /// 3. Stops and clears ChatProvider listeners, outbox timers, and chat histories.
  /// 4. Stops DiscoverProvider discovery subscriptions and heartbeat timers.
  /// 5. Disposes the active SignalMessagingService (cancels timers, clears pending keys).
  /// 6. Hard teardown of NostrRelayService (validates ownership before clearing state).
  /// 7. Clears AppDatabase user tables via atomic privileged teardown and closes the database connection (Fail-Closed).
  /// 8. Clears AuthProvider credentials and IdentityRepository mnemonic/keys (Fail-Closed).
  /// 9. If any critical step fails, state is set to TEARDOWN_FAILED and provider emission is aborted.
  /// 10. Only on complete success, emits the new generation to Riverpod and transitions to ACTIVE.
  static Future<void> dispose({
    AuthProvider? authProvider,
    ChatProvider? chatProvider,
    DiscoverProvider? discoverProvider,
    SignalMessagingService? signalService,
    NostrRelayService? nostrService,
    AppDatabase? database,
  }) {
    _state = AccountLifecycleState.tearingDown;
    final oldGen = _currentGeneration;
    // Step 1: Immediately increment session generation.
    // This serves as the synchronous security and invalidation barrier:
    // Any in-flight callbacks, outbox sends, or transport operations from oldGen
    // will immediately fail-closed when checking AccountSession.isGenerationValid() or _ensureActive().
    _currentGeneration++;
    print('[ACCOUNT_SESSION] Disposing session generation $oldGen -> advanced to $_currentGeneration');

    return synchronize(() async {
      // Best-effort cleanup of non-critical memory listeners & timers
      try {
        chatProvider?.stopListening();
        chatProvider?.clearAllMemory();
      } catch (e) {
        print('[ACCOUNT_SESSION] Error stopping chat provider: $e');
      }

      try {
        discoverProvider?.stopHeartbeat();
        discoverProvider?.stopDiscovery();
      } catch (e) {
        print('[ACCOUNT_SESSION] Error stopping discovery provider: $e');
      }

      try {
        signalService?.dispose();
      } catch (e) {
        print('[ACCOUNT_SESSION] Error disposing signal service: $e');
      }

      try {
        await VoiceNoteCacheManager().cleanupAll();
      } catch (e) {
        print('[ACCOUNT_SESSION] Error cleaning up voice note cache: $e');
      }

      final criticalFailures = <String, Object>{};

      // CRITICAL STEP 1: Nostr transport and key teardown (Fail-Closed)
      try {
        final nostr = nostrService ?? NostrRelayService();
        await nostr.teardownSession(oldGen);
      } catch (e) {
        criticalFailures['nostr_teardown'] = e;
        print('[ACCOUNT_SESSION] CRITICAL TEARDOWN FAILURE: Nostr teardown failed: $e');
      }

      // CRITICAL STEP 2: Database atomic wipe (Fail-Closed)
      if (database != null) {
        try {
          await database.clearAllUserDataForTeardown(expectedGeneration: oldGen);
        } catch (e) {
          criticalFailures['database_wipe'] = e;
          print('[ACCOUNT_SESSION] CRITICAL TEARDOWN FAILURE: Database wipe failed: $e');
        }

        // CRITICAL STEP 3: Database close (Fail-Closed)
        try {
          await database.close();
        } catch (e) {
          criticalFailures['database_close'] = e;
          print('[ACCOUNT_SESSION] CRITICAL TEARDOWN FAILURE: Database close failed: $e');
        }
      }

      // CRITICAL STEP 4: Clear Auth credentials & Identity storage (Fail-Closed)
      if (authProvider != null) {
        try {
          await authProvider.clearCredentialsOnly(expectedGeneration: oldGen);
        } catch (e) {
          criticalFailures['auth_cleanup'] = e;
          print('[ACCOUNT_SESSION] CRITICAL TEARDOWN FAILURE: Auth credential cleanup failed: $e');
        }
      }

      // If ANY critical step failed, enter teardownFailed and refuse to emit generation.
      if (criticalFailures.isNotEmpty) {
        _state = AccountLifecycleState.teardownFailed;
        print('[ACCOUNT_SESSION] Teardown aborted due to critical failure(s): ${criticalFailures.keys.toList()}');
        final firstError = criticalFailures.values.first;
        if (firstError is Error) {
          throw firstError;
        } else if (firstError is Exception) {
          throw firstError;
        } else {
          throw StateError('Teardown failed: $firstError');
        }
      }

      // Step 2: Emit the generation change to Riverpod and external listeners ONLY AFTER
      // all security-critical resources have been completely sanitized and closed without error.
      _state = AccountLifecycleState.readyForReplacement;
      _generationController.add(_currentGeneration);
      _state = AccountLifecycleState.active;
      print('[ACCOUNT_SESSION] Teardown of session $oldGen complete. Emitted generation $_currentGeneration to providers.');
    });
  }
}
