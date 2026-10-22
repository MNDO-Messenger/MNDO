import 'dart:async';
import 'dart:convert';
import '../models/chat_message.dart';
import '../repositories/chat_repository.dart';
import 'signal_messaging_service.dart';
import 'account_session.dart';
import 'app_logger.dart';

typedef SignalServiceGetter = SignalMessagingService? Function();
typedef PeerIdentityBlockedChecker = bool Function(String peerNostrPubKey);
typedef MessageStatusCallback = void Function(String messageId, MessageStatus status);

/// Responsible for dispatching, retrying, and managing outbound messages
/// queued in the persistent outbox.
class OutboxDispatcherService {
  ChatRepository chatRepo;
  SignalServiceGetter getSignalService;
  PeerIdentityBlockedChecker isPeerIdentityBlocked;
  MessageStatusCallback? onMessageStatusChanged;

  bool _isDrainingOutbox = false;
  bool get isDrainingOutbox => _isDrainingOutbox;

  Timer? _outboxDrainTimer;
  final Map<String, DateTime> _lastPeerRetryTime = {};

  OutboxDispatcherService({
    required this.chatRepo,
    required this.getSignalService,
    required this.isPeerIdentityBlocked,
    this.onMessageStatusChanged,
  });

  void updateDependencies({
    required ChatRepository newRepo,
    required SignalServiceGetter newGetSignalService,
    required PeerIdentityBlockedChecker newIsPeerIdentityBlocked,
  }) {
    chatRepo = newRepo;
    getSignalService = newGetSignalService;
    isPeerIdentityBlocked = newIsPeerIdentityBlocked;
  }

  void startPeriodicDrain({Duration interval = const Duration(seconds: 30)}) {
    _outboxDrainTimer?.cancel();
    _outboxDrainTimer = Timer.periodic(interval, (_) {
      unawaited(drainOutbox());
    });
  }

  void stopPeriodicDrain() {
    _outboxDrainTimer?.cancel();
    _outboxDrainTimer = null;
  }

  void resetPeerRetryThrottles() {
    _lastPeerRetryTime.clear();
  }

  void clearPeerRetryThrottle() {
    _lastPeerRetryTime.clear();
  }

  /// Returns the required delay in seconds before the next retry attempt according to policy:
  /// Attempt 1: Immediate (0s)
  /// Attempt 2: 30s
  /// Attempt 3: 1m (60s)
  /// Attempt 4: 2m (120s)
  /// Attempt 5: 5m (300s)
  /// Attempt 6: 10m (600s)
  /// Attempt 7: 20m (1200s)
  /// Attempt 8: 30m (1800s)
  /// Attempt 9+: Every 1 hour (3600s)
  static int getOutboxRetryBackoffSeconds(int attempts) {
    if (attempts <= 0) return 0;
    if (attempts == 1) return 30;
    if (attempts == 2) return 60;
    if (attempts == 3) return 120;
    if (attempts == 4) return 300;
    if (attempts == 5) return 600;
    if (attempts == 6) return 1200;
    if (attempts == 7) return 1800;
    return 3600;
  }

  /// Automatically drains pending and unacknowledged messages from the persistent Outbox.
  /// Re-transmits the exact stored ciphertexts without advancing the Signal Double Ratchet.
  /// If [forceAll] is false, messages in 'sent' state respect exponential backoff.
  Future<void> drainOutbox({bool forceAll = false}) async {
    final sessionGen = AccountSession.currentGeneration;
    if (_isDrainingOutbox) return;
    final signalService = getSignalService();
    if (signalService == null || !AccountSession.isGenerationValid(sessionGen)) return;
    _isDrainingOutbox = true;

    try {
      final undelivered = await chatRepo.getPendingOutboxMessages();
      if (undelivered.isEmpty || !AccountSession.isGenerationValid(sessionGen)) return;

      final now = DateTime.now();

      for (final record in undelivered) {
        if (!AccountSession.isGenerationValid(sessionGen)) {
          AppLogger.debug('[OUTBOX] drainOutbox interrupted: session generation $sessionGen is stale');
          break;
        }

        if (isPeerIdentityBlocked(record.recipientNostrPubKey)) {
          AppLogger.debug('[OUTBOX] Skipping dispatch for ${record.messageId}: recipient ${AppLogger.redactNostrKey(record.recipientNostrPubKey)} identity is blocked pending verification');
          continue;
        }

        // Section 5 Order of Decisions:
        // 1. if message is delivered/read: complete/remove outbox record
        if (record.status == 'delivered' || record.status == 'read') {
          await chatRepo.deleteFromOutbox(record.messageId);
          continue;
        }

        // 2. else if now >= expiresAt: status = expired
        if (now.isAfter(record.expiresAt) || now.isAtSameMomentAs(record.expiresAt)) {
          AppLogger.debug('[OUTBOX] Message ${record.messageId} reached expiration at ${record.expiresAt}. Marking terminal expired.');
          await chatRepo.updateOutboxStatus(record.messageId, status: 'expired');
          await chatRepo.updateMessageStatus(record.messageId, MessageStatus.expired);
          onMessageStatusChanged?.call(record.messageId, MessageStatus.expired);
          continue;
        }

        // 3. else if retry is due: retransmit the SAME stored ciphertext
        // The retry scheduler is authoritative across all retryable states (pending, failed, sent)
        if (!forceAll) {
          final attempts = record.attempts;
          final backoffSeconds = getOutboxRetryBackoffSeconds(attempts);
          final lastAttempt = record.lastAttemptAt ?? record.createdAt;
          if (now.difference(lastAttempt).inSeconds < backoffSeconds) {
            continue; // Not yet time to retry this message
          }
        }

        try {
          final payloadMap = jsonDecode(record.payloadJson) as Map<String, dynamic>;
          AppLogger.debug('[OUTBOX] Dispatching undelivered messageId=${record.messageId} (status: ${record.status}, attempt: ${record.attempts + 1})...');
          
          if (!AccountSession.isGenerationValid(sessionGen)) break;
          await signalService.sendPreparedPayload(record.recipientNostrPubKey, payloadMap);

          if (!AccountSession.isGenerationValid(sessionGen)) break;

          // Update attempt timestamp and keep status 'sent' (awaiting peer delivery receipt)
          await chatRepo.updateOutboxStatus(
            record.messageId,
            status: 'sent',
            attempts: record.attempts + 1,
            lastAttemptAt: DateTime.now(),
          );
          await chatRepo.updateMessageStatus(record.messageId, MessageStatus.sent);
          onMessageStatusChanged?.call(record.messageId, MessageStatus.sent);
          AppLogger.debug('[OUTBOX] Successfully dispatched messageId=${record.messageId}');
        } catch (e) {
          if (!AccountSession.isGenerationValid(sessionGen)) break;
          AppLogger.warning('[OUTBOX] Failed to dispatch messageId=${record.messageId}: $e');
          try {
            await chatRepo.updateOutboxAttempt(
              record.messageId,
              attempts: record.attempts + 1,
              lastAttemptAt: DateTime.now(),
              status: record.status == 'sent' ? 'sent' : 'failed',
            );
          } catch (_) {}
        }
      }
    } catch (e) {
      AppLogger.error('[OUTBOX] Error during drain: $e');
    } finally {
      _isDrainingOutbox = false;
    }
  }

  /// Immediately re-dispatches unacknowledged messages when peer comes online or interacts.
  Future<void> retryUnacknowledgedForPeer(String recipientNostrPubKey) async {
    final sessionGen = AccountSession.currentGeneration;
    final signalService = getSignalService();
    if (signalService == null || !AccountSession.isGenerationValid(sessionGen)) return;
    if (isPeerIdentityBlocked(recipientNostrPubKey)) {
      AppLogger.debug('[OUTBOX] retryUnacknowledgedForPeer aborted: peer ${AppLogger.redactNostrKey(recipientNostrPubKey)} identity is blocked');
      return;
    }
    
    // Throttle per-peer retries to avoid spamming relays on frequent presence pings (min 15 seconds)
    final now = DateTime.now();
    final lastTime = _lastPeerRetryTime[recipientNostrPubKey];
    if (lastTime != null && now.difference(lastTime).inSeconds < 15) {
      return;
    }
    _lastPeerRetryTime[recipientNostrPubKey] = now;

    try {
      final pendingForPeer = await chatRepo.getUndeliveredMessagesForPeer(recipientNostrPubKey);
      if (pendingForPeer.isEmpty || !AccountSession.isGenerationValid(sessionGen)) return;

      AppLogger.debug('[OUTBOX] Opportunistic retry: peer ${AppLogger.redactNostrKey(recipientNostrPubKey)} is active. Resending ${pendingForPeer.length} unacknowledged message(s)...');
      for (final record in pendingForPeer) {
        if (!AccountSession.isGenerationValid(sessionGen)) break;

        // 1. if message is delivered/read: complete/remove outbox record
        if (record.status == 'delivered' || record.status == 'read') {
          await chatRepo.deleteFromOutbox(record.messageId);
          continue;
        }

        // 2. else if now >= expiresAt: status = expired (peer presence retry must NOT bypass expiration!)
        if (now.isAfter(record.expiresAt) || now.isAtSameMomentAs(record.expiresAt)) {
          AppLogger.debug('[OUTBOX] Peer retry: message ${record.messageId} reached expiration at ${record.expiresAt}. Marking terminal expired.');
          await chatRepo.updateOutboxStatus(record.messageId, status: 'expired');
          await chatRepo.updateMessageStatus(record.messageId, MessageStatus.expired);
          onMessageStatusChanged?.call(record.messageId, MessageStatus.expired);
          continue;
        }

        // 3. else check retryDue: peer presence must NOT bypass the authoritative backoff schedule!
        final backoffSeconds = getOutboxRetryBackoffSeconds(record.attempts);
        final lastAttempt = record.lastAttemptAt ?? record.createdAt;
        if (now.difference(lastAttempt).inSeconds < backoffSeconds) {
          // Message is not yet due under the retry backoff schedule
          continue;
        }

        try {
          final payloadMap = jsonDecode(record.payloadJson) as Map<String, dynamic>;
          AppLogger.debug('[OUTBOX] Peer presence dispatch: resending messageId=${record.messageId} (attempt: ${record.attempts + 1})...');
          await signalService.sendPreparedPayload(recipientNostrPubKey, payloadMap);
          if (!AccountSession.isGenerationValid(sessionGen)) break;
          await chatRepo.updateOutboxStatus(
            record.messageId,
            status: 'sent',
            attempts: record.attempts + 1,
            lastAttemptAt: DateTime.now(),
          );
          await chatRepo.updateMessageStatus(record.messageId, MessageStatus.sent);
          onMessageStatusChanged?.call(record.messageId, MessageStatus.sent);
        } catch (e) {
          if (!AccountSession.isGenerationValid(sessionGen)) break;
          AppLogger.warning('[OUTBOX] Peer retry failed for ${record.messageId}: $e');
          try {
            await chatRepo.updateOutboxAttempt(
              record.messageId,
              attempts: record.attempts + 1,
              lastAttemptAt: DateTime.now(),
              status: record.status == 'sent' ? 'sent' : 'failed',
            );
          } catch (_) {}
        }
      }
    } catch (e) {
      AppLogger.error('[OUTBOX] Error in retryUnacknowledgedForPeer: $e');
    }
  }

  void dispose() {
    stopPeriodicDrain();
    resetPeerRetryThrottles();
  }
}
