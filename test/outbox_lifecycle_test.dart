import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:aisat_connect/database/database.dart';
import 'package:aisat_connect/models/chat_message.dart';
import 'package:aisat_connect/providers/auth_provider.dart';
import 'package:aisat_connect/providers/chat_provider.dart';
import 'package:aisat_connect/repositories/chat_repository.dart';
import 'package:aisat_connect/services/account_session.dart';
import 'package:aisat_connect/services/crypto_service.dart';
import 'package:aisat_connect/services/signal_messaging_service.dart';

class _MockAuthProvider extends ChangeNotifier implements AuthProvider {
  @override
  CryptoService cryptoService = CryptoService();

  @override
  String? masterPublicKeyHex = 'abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890';
  @override
  String? displayName = 'Alice Nakamoto';
  @override
  String? username = 'alice';
  @override
  String? bio = 'Building decentralized messaging';
  @override
  String? mnemonic;

  @override
  bool get isAuthenticated => masterPublicKeyHex != null;

  @override
  Future<bool> restoreIdentity() async => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MockSignalServiceForLifecycle implements SignalMessagingService {
  @override
  void Function(String peerNostrPubKey)? onIdentityKeyChanged;

  final List<Map<String, dynamic>> sentPayloads = [];
  int sendCalls = 0;

  @override
  Future<void> sendPreparedPayload(String recipientNostrPubKey, Map<String, dynamic> payloadMap) async {
    sendCalls++;
    sentPayloads.add(Map<String, dynamic>.from(payloadMap));
  }

  @override
  bool isIdentityBlocked(String peerNostrPubKey) => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _LifecycleChatRepo implements ChatRepository {
  @override
  int get sessionGeneration => AccountSession.currentGeneration;

  final List<OutboxRecord> outbox = [];
  final Map<String, MessageStatus> messageStatuses = {};
  final List<ChatMessage> messages = [];

  @override
  Future<void> enqueueOutbox({
    required String messageId,
    required String recipientNostrPubKey,
    required String payloadJson,
    DateTime? createdAt,
    Duration ttl = ChatRepository.defaultOutboxTtl,
    DateTime? expiresAt,
  }) async {
    final now = createdAt ?? DateTime.now();
    outbox.add(OutboxRecord(
      messageId: messageId,
      recipientNostrPubKey: recipientNostrPubKey,
      payloadJson: payloadJson,
      attempts: 0,
      createdAt: now,
      expiresAt: expiresAt ?? now.add(ttl),
      status: 'pending',
    ));
  }

  @override
  Future<List<OutboxRecord>> getPendingOutboxMessages() async {
    return outbox
        .where((r) => r.status != 'delivered' && r.status != 'read' && r.status != 'expired')
        .toList();
  }

  @override
  Future<List<OutboxRecord>> getUndeliveredMessagesForPeer(String recipientNostrPubKey) async {
    return outbox
        .where((r) =>
            r.recipientNostrPubKey == recipientNostrPubKey &&
            r.status != 'delivered' &&
            r.status != 'read' &&
            r.status != 'expired')
        .toList();
  }

  @override
  Future<OutboxRecord?> getOutboxRecord(String messageId) async {
    try {
      return outbox.firstWhere((r) => r.messageId == messageId);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> deleteFromOutbox(String messageId) async {
    outbox.removeWhere((r) => r.messageId == messageId);
  }

  @override
  Future<void> updateOutboxAttempt(
    String messageId, {
    required int attempts,
    required DateTime lastAttemptAt,
    required String status,
  }) async {
    final idx = outbox.indexWhere((r) => r.messageId == messageId);
    if (idx != -1) {
      final prev = outbox[idx];
      outbox[idx] = OutboxRecord(
        messageId: prev.messageId,
        recipientNostrPubKey: prev.recipientNostrPubKey,
        payloadJson: prev.payloadJson,
        attempts: attempts,
        lastAttemptAt: lastAttemptAt,
        createdAt: prev.createdAt,
        expiresAt: prev.expiresAt,
        status: status,
      );
    }
  }

  @override
  Future<void> updateOutboxStatus(
    String messageId, {
    required String status,
    int? attempts,
    DateTime? lastAttemptAt,
  }) async {
    final idx = outbox.indexWhere((r) => r.messageId == messageId);
    if (idx != -1) {
      final prev = outbox[idx];
      outbox[idx] = OutboxRecord(
        messageId: prev.messageId,
        recipientNostrPubKey: prev.recipientNostrPubKey,
        payloadJson: prev.payloadJson,
        attempts: attempts ?? prev.attempts,
        lastAttemptAt: lastAttemptAt ?? prev.lastAttemptAt,
        createdAt: prev.createdAt,
        expiresAt: prev.expiresAt,
        status: status,
      );
    }
  }

  @override
  Future<void> updateMessageStatus(String messageId, MessageStatus status) async {
    messageStatuses[messageId] = status;
    final msg = messages.where((m) => m.messageId == messageId).firstOrNull;
    if (msg != null) {
      msg.status = status;
    }
  }

  @override
  Future<int> markExpiredOutboxMessages(DateTime now) async {
    int count = 0;
    for (int i = 0; i < outbox.length; i++) {
      final r = outbox[i];
      if (r.status != 'delivered' && r.status != 'read' && r.status != 'expired') {
        if (now.isAfter(r.expiresAt) || now.isAtSameMomentAs(r.expiresAt)) {
          outbox[i] = OutboxRecord(
            messageId: r.messageId,
            recipientNostrPubKey: r.recipientNostrPubKey,
            payloadJson: r.payloadJson,
            attempts: r.attempts,
            lastAttemptAt: r.lastAttemptAt,
            createdAt: r.createdAt,
            expiresAt: r.expiresAt,
            status: 'expired',
          );
          count++;
        }
      }
    }
    return count;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('MNDO Outbox Retry Lifecycle and Expiration Tests (REL-OUTBOX-01)', () {
    late _LifecycleChatRepo repo;
    late _MockSignalServiceForLifecycle mockSignal;
    late _MockAuthProvider mockAuth;
    late ChatProvider chatProvider;
    const recipientKey = 'peer_nostr_lifecycle_abc';

    setUp(() {
      AccountSession.resetForTesting();
      AccountSession.setGenerationForTesting(1);
      repo = _LifecycleChatRepo();
      mockSignal = _MockSignalServiceForLifecycle();
      mockAuth = _MockAuthProvider();
      chatProvider = ChatProvider(
        chatRepo: repo,
        authProvider: mockAuth,
        signalService: mockSignal,
      );
    });

    tearDown(() {
      AccountSession.resetForTesting();
    });

    test('1. Backoff schedule table: verifies exact delays for attempts 1 through 9+', () {
      expect(ChatProvider.getOutboxRetryBackoffSeconds(0), 30);
      expect(ChatProvider.getOutboxRetryBackoffSeconds(1), 30); // Attempt 2: 30s
      expect(ChatProvider.getOutboxRetryBackoffSeconds(2), 60); // Attempt 3: 1m
      expect(ChatProvider.getOutboxRetryBackoffSeconds(3), 120); // Attempt 4: 2m
      expect(ChatProvider.getOutboxRetryBackoffSeconds(4), 300); // Attempt 5: 5m
      expect(ChatProvider.getOutboxRetryBackoffSeconds(5), 600); // Attempt 6: 10m
      expect(ChatProvider.getOutboxRetryBackoffSeconds(6), 1200); // Attempt 7: 20m
      expect(ChatProvider.getOutboxRetryBackoffSeconds(7), 1800); // Attempt 8: 30m
      expect(ChatProvider.getOutboxRetryBackoffSeconds(8), 3600); // Attempt 9: 1h
      expect(ChatProvider.getOutboxRetryBackoffSeconds(9), 3600); // Attempt 10: 1h
      expect(ChatProvider.getOutboxRetryBackoffSeconds(15), 3600); // Attempt 16+: 1h
    });

    test('2. Retry continues beyond attempt 5 while message is still within TTL', () async {
      final now = DateTime.now();
      final msg = ChatMessage(
        messageId: 'msg_attempt_5',
        text: 'Testing attempt 5 retry',
        isMe: true,
        timestamp: now.subtract(const Duration(hours: 1)),
        status: MessageStatus.sent,
      );
      repo.messages.add(msg);
      chatProvider.chatHistories[recipientKey] = [msg];

      // Enqueue record at attempt 5, lastAttemptAt 400s ago (backoff is 600s)
      repo.outbox.add(OutboxRecord(
        messageId: 'msg_attempt_5',
        recipientNostrPubKey: recipientKey,
        payloadJson: '{"id": "msg_attempt_5", "ciphertext": "ct_at_5"}',
        attempts: 5,
        lastAttemptAt: now.subtract(const Duration(seconds: 400)),
        createdAt: now.subtract(const Duration(hours: 1)),
        expiresAt: now.add(const Duration(days: 6)), // well within 7-day TTL
        status: 'sent',
      ));

      // 400s < 600s: not yet due, should NOT dispatch
      await chatProvider.drainOutbox();
      expect(mockSignal.sendCalls, 0);
      expect(repo.outbox.first.attempts, 5);

      // Now set lastAttemptAt to 650s ago (> 600s)
      repo.outbox[0] = repo.outbox[0].copyWith(
        lastAttemptAt: Value(now.subtract(const Duration(seconds: 650))),
      );

      // Backoff satisfied: should dispatch attempt 6!
      await chatProvider.drainOutbox();
      expect(mockSignal.sendCalls, 1);
      expect(repo.outbox.first.attempts, 6);
      expect(repo.outbox.first.status, 'sent');
    });

    test('3. Attempt 9+ follows hourly retry policy (3600s)', () async {
      final now = DateTime.now();
      repo.outbox.add(OutboxRecord(
        messageId: 'msg_attempt_9',
        recipientNostrPubKey: recipientKey,
        payloadJson: '{"id": "msg_attempt_9", "ciphertext": "ct_at_9"}',
        attempts: 9,
        lastAttemptAt: now.subtract(const Duration(seconds: 3500)), // 3500s < 3600s
        createdAt: now.subtract(const Duration(days: 1)),
        expiresAt: now.add(const Duration(days: 6)),
        status: 'sent',
      ));

      // Not yet 1 hour: should NOT retry
      await chatProvider.drainOutbox();
      expect(mockSignal.sendCalls, 0);
      expect(repo.outbox.first.attempts, 9);

      // Advance lastAttemptAt to 3650s ago (> 3600s)
      repo.outbox[0] = repo.outbox[0].copyWith(
        lastAttemptAt: Value(now.subtract(const Duration(seconds: 3650))),
      );

      // Retry is now due: dispatches attempt 10
      await chatProvider.drainOutbox();
      expect(mockSignal.sendCalls, 1);
      expect(repo.outbox.first.attempts, 10);
      expect(repo.outbox.first.status, 'sent');
    });

    test('4. Expiration prevents further periodic retries (marks expired without retransmitting)', () async {
      final now = DateTime.now();
      final msg = ChatMessage(
        messageId: 'msg_expired_periodic',
        text: 'Expired message',
        isMe: true,
        timestamp: now.subtract(const Duration(days: 8)),
        status: MessageStatus.sent,
      );
      repo.messages.add(msg);
      chatProvider.chatHistories[recipientKey] = [msg];

      // Enqueue record that expired 1 hour ago
      repo.outbox.add(OutboxRecord(
        messageId: 'msg_expired_periodic',
        recipientNostrPubKey: recipientKey,
        payloadJson: '{"id": "msg_expired_periodic", "ciphertext": "ct_exp"}',
        attempts: 20,
        lastAttemptAt: now.subtract(const Duration(hours: 2)),
        createdAt: now.subtract(const Duration(days: 8)),
        expiresAt: now.subtract(const Duration(hours: 1)), // EXPIRED!
        status: 'sent',
      ));

      await chatProvider.drainOutbox();

      // Zero retransmissions
      expect(mockSignal.sendCalls, 0);

      // Record transitioned to terminal 'expired'
      expect(repo.outbox.first.status, 'expired');
      expect(msg.status, MessageStatus.expired);

      // Subsequent drain ignores expired record
      await chatProvider.drainOutbox();
      expect(mockSignal.sendCalls, 0);
    });

    test('5. Expiration prevents peer-online opportunistic retries (retryUnacknowledgedForPeer)', () async {
      final now = DateTime.now();
      final msg = ChatMessage(
        messageId: 'msg_expired_peer',
        text: 'Expired peer message',
        isMe: true,
        timestamp: now.subtract(const Duration(days: 8)),
        status: MessageStatus.sent,
      );
      repo.messages.add(msg);
      chatProvider.chatHistories[recipientKey] = [msg];

      repo.outbox.add(OutboxRecord(
        messageId: 'msg_expired_peer',
        recipientNostrPubKey: recipientKey,
        payloadJson: '{"id": "msg_expired_peer", "ciphertext": "ct_peer_exp"}',
        attempts: 12,
        lastAttemptAt: now.subtract(const Duration(hours: 3)),
        createdAt: now.subtract(const Duration(days: 8)),
        expiresAt: now.subtract(const Duration(minutes: 30)), // EXPIRED!
        status: 'sent',
      ));

      // Peer comes online
      await chatProvider.retryUnacknowledgedForPeer(recipientKey);

      // Zero network dispatches!
      expect(mockSignal.sendCalls, 0);

      // Marked expired
      expect(repo.outbox.first.status, 'expired');
      expect(msg.status, MessageStatus.expired);
    });

    test('6. An expired message is never retransmitted, even with forceAll: true or retryOutgoingMessage', () async {
      final now = DateTime.now();
      final msg = ChatMessage(
        messageId: 'msg_force_exp',
        text: 'Never retransmit',
        isMe: true,
        timestamp: now.subtract(const Duration(days: 9)),
        status: MessageStatus.sent,
      );
      repo.messages.add(msg);
      chatProvider.chatHistories[recipientKey] = [msg];

      repo.outbox.add(OutboxRecord(
        messageId: 'msg_force_exp',
        recipientNostrPubKey: recipientKey,
        payloadJson: '{"id": "msg_force_exp", "ciphertext": "ct_force"}',
        attempts: 10,
        lastAttemptAt: now.subtract(const Duration(days: 1)),
        createdAt: now.subtract(const Duration(days: 9)),
        expiresAt: now.subtract(const Duration(days: 2)), // EXPIRED
        status: 'sent',
      ));

      // Attempt drain with forceAll: true
      await chatProvider.drainOutbox(forceAll: true);
      expect(mockSignal.sendCalls, 0);
      expect(repo.outbox.first.status, 'expired');

      // Attempt manual UI retry on expired message
      final retrySuccess = await chatProvider.retryOutgoingMessage(recipientKey, msg);
      expect(retrySuccess, isFalse);
      expect(mockSignal.sendCalls, 0);
      expect(msg.status, MessageStatus.expired);
    });

    test('7. Retries use the exact same stored ciphertext without re-encrypting or advancing Double Ratchet', () async {
      final now = DateTime.now();
      const storedPayloadJson = '{"id": "msg_exact_ct", "type": 3, "ciphertext": "ORIGINAL_CIPHERTEXT_12345"}';

      repo.outbox.add(OutboxRecord(
        messageId: 'msg_exact_ct',
        recipientNostrPubKey: recipientKey,
        payloadJson: storedPayloadJson,
        attempts: 1,
        lastAttemptAt: now.subtract(const Duration(seconds: 45)), // 45s > 30s backoff
        createdAt: now.subtract(const Duration(minutes: 5)),
        expiresAt: now.add(const Duration(days: 7)),
        status: 'sent',
      ));

      await chatProvider.drainOutbox();

      expect(mockSignal.sendCalls, 1);
      final dispatchedPayload = mockSignal.sentPayloads.first;
      expect(dispatchedPayload['ciphertext'], 'ORIGINAL_CIPHERTEXT_12345');
      expect(dispatchedPayload['id'], 'msg_exact_ct');
      expect(jsonEncode(dispatchedPayload), jsonEncode(jsonDecode(storedPayloadJson)));
    });

    test('8. Delivered messages stop retrying immediately (receipt removes outbox record)', () async {
      final now = DateTime.now();
      repo.outbox.add(OutboxRecord(
        messageId: 'msg_ack_test',
        recipientNostrPubKey: recipientKey,
        payloadJson: '{"id": "msg_ack_test", "ciphertext": "abc"}',
        attempts: 1,
        lastAttemptAt: now.subtract(const Duration(seconds: 10)),
        createdAt: now.subtract(const Duration(minutes: 1)),
        expiresAt: now.add(const Duration(days: 7)),
        status: 'sent',
      ));

      expect(repo.outbox.length, 1);

      // Delivery receipt deletes record from outbox
      await repo.deleteFromOutbox('msg_ack_test');
      expect(repo.outbox.isEmpty, isTrue);

      // Subsequent drain does nothing
      await chatProvider.drainOutbox(forceAll: true);
      expect(mockSignal.sendCalls, 0);
    });

    test('9. expiresAt is strictly immutable and is never extended by retries', () async {
      final now = DateTime.now();
      final initialExpiresAt = now.add(const Duration(days: 7));

      await repo.enqueueOutbox(
        messageId: 'msg_immutable_ttl',
        recipientNostrPubKey: recipientKey,
        payloadJson: '{"id": "msg_immutable_ttl", "ciphertext": "abc"}',
        createdAt: now,
        expiresAt: initialExpiresAt,
      );

      expect(repo.outbox.first.expiresAt, initialExpiresAt);

      // Perform retry 1
      repo.outbox[0] = repo.outbox[0].copyWith(
        status: 'sent',
        attempts: 1,
        lastAttemptAt: Value(now),
      );
      await chatProvider.drainOutbox(forceAll: true);
      expect(repo.outbox.first.attempts, 2);
      expect(repo.outbox.first.expiresAt, initialExpiresAt); // UNCHANGED!

      // Perform retry 2
      await chatProvider.drainOutbox(forceAll: true);
      expect(repo.outbox.first.attempts, 3);
      expect(repo.outbox.first.expiresAt, initialExpiresAt); // UNCHANGED!
    });

    test('10. SQLite Database persistence: schema v5 includes expires_at and excludes expired records', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final now = DateTime.now();

      // Enqueue 3 records: pending, delivered, expired
      await db.enqueueOutboxMessage(OutboxMessagesCompanion.insert(
        messageId: 'db_pending',
        recipientNostrPubKey: recipientKey,
        payloadJson: '{"id": "db_pending"}',
        createdAt: now,
        expiresAt: now.add(const Duration(days: 7)),
        status: const Value('pending'),
      ));

      await db.enqueueOutboxMessage(OutboxMessagesCompanion.insert(
        messageId: 'db_delivered',
        recipientNostrPubKey: recipientKey,
        payloadJson: '{"id": "db_delivered"}',
        createdAt: now,
        expiresAt: now.add(const Duration(days: 7)),
        status: const Value('delivered'),
      ));

      await db.enqueueOutboxMessage(OutboxMessagesCompanion.insert(
        messageId: 'db_expired',
        recipientNostrPubKey: recipientKey,
        payloadJson: '{"id": "db_expired"}',
        createdAt: now.subtract(const Duration(days: 8)),
        expiresAt: now.subtract(const Duration(days: 1)),
        status: const Value('expired'),
      ));

      // getPendingOutboxMessages MUST only return the active pending message
      final pending = await db.getPendingOutboxMessages();
      expect(pending.length, 1);
      expect(pending.first.messageId, 'db_pending');

      // getUndeliveredMessagesForPeer MUST only return the active pending message
      final peerMessages = await db.getUndeliveredMessagesForPeer(recipientKey);
      expect(peerMessages.length, 1);
      expect(peerMessages.first.messageId, 'db_pending');

      // Add a message with status 'sent' whose expiresAt is in the past
      await db.enqueueOutboxMessage(OutboxMessagesCompanion.insert(
        messageId: 'db_due_to_expire',
        recipientNostrPubKey: recipientKey,
        payloadJson: '{"id": "db_due_to_expire"}',
        createdAt: now.subtract(const Duration(days: 8)),
        expiresAt: now.subtract(const Duration(seconds: 10)),
        status: const Value('sent'),
      ));

      // Batch mark expired
      final markedCount = await db.markExpiredOutboxMessages(now);
      expect(markedCount, 1);

      // Verify db_due_to_expire is now marked 'expired' and excluded
      final record = await db.getOutboxMessage('db_due_to_expire');
      expect(record?.status, 'expired');

      final pendingAfter = await db.getPendingOutboxMessages();
      expect(pendingAfter.length, 1);
      expect(pendingAfter.first.messageId, 'db_pending');

      await db.close();
    });
  });
}
