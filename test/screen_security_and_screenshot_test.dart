import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:drift/native.dart';
import 'package:dart_nostr/dart_nostr.dart';

import 'package:aisat_connect/database/database.dart';
import 'package:aisat_connect/repositories/chat_repository.dart';
import 'package:aisat_connect/models/chat_message.dart';
import 'package:aisat_connect/models/discover_user.dart';
import 'package:aisat_connect/providers/chat_provider.dart';
import 'package:aisat_connect/providers/auth_provider.dart';
import 'package:aisat_connect/services/screen_security_service.dart';
import 'package:aisat_connect/services/signal_messaging_service.dart';
import 'package:aisat_connect/services/crypto_service.dart';

class _MockAuthProvider extends ChangeNotifier implements AuthProvider {
  @override
  CryptoService cryptoService = CryptoService();

  @override
  String? masterPublicKeyHex =
      'abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890';
  @override
  String? displayName = 'Alice';
  @override
  String? username = 'alice';
  @override
  String? bio = 'Decentralized privacy';
  @override
  String? mnemonic;

  @override
  bool get isAuthenticated => masterPublicKeyHex != null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MockSignalService implements SignalMessagingService {
  int decryptAttempts = 0;

  @override
  void Function(String peerNostrPubKey)? onIdentityKeyChanged;

  @override
  Future<(String, String, DateTime?, String?, bool)?> decryptMessage(
    String senderNostrPubKey,
    Map<String, dynamic> map,
  ) async {
    decryptAttempts++;
    return null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late ChatRepository chatRepo;
  late _MockAuthProvider authProvider;
  late _MockSignalService signalService;
  late ChatProvider chatProvider;

  const testPeerPubKey =
      '1111222233334444555566667777888899990000aaaabbbbccccddddeeeeffff';

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase.forTesting(NativeDatabase.memory());
    chatRepo = ChatRepository(db);
    authProvider = _MockAuthProvider();
    signalService = _MockSignalService();

    chatProvider = ChatProvider(
      chatRepo: chatRepo,
      authProvider: authProvider,
      signalService: signalService,
    );
  });

  tearDown(() async {
    await db.close();
  });

  group('ScreenSecurityService', () {
    test('1. Singleton instance initialized and maintains state', () async {
      final s1 = ScreenSecurityService();
      final s2 = ScreenSecurityService();
      expect(identical(s1, s2), isTrue);

      await s1.setScreenSecurity(true);
      expect(s1.isScreenSecurityActive, isTrue);

      await s1.setScreenSecurity(false);
      expect(s1.isScreenSecurityActive, isFalse);
    });
  });

  group('ChatProvider Screenshot Recording & Control Message Handling', () {
    test('2. recordScreenshotTaken records local screenshot for sender (isMe: true)', () async {
      await chatProvider.recordScreenshotTaken(testPeerPubKey, isMe: true);

      final history = chatProvider.getMessagesFor(testPeerPubKey);
      expect(history.length, equals(1));
      expect(history.first.isMe, isTrue);
      expect(history.first.text, contains('You took a screenshot'));
      expect(history.first.status, equals(MessageStatus.sent));
    });

    test(
      '3. recordScreenshotTaken records peer screenshot (isMe: false)',
      () async {
        await chatProvider.recordScreenshotTaken(testPeerPubKey, isMe: false);

        final history = chatProvider.getMessagesFor(testPeerPubKey);
        expect(history.length, equals(1));
        expect(history.first.isMe, isFalse);
        expect(history.first.text, contains('Screenshot was taken'));
      },
    );

    test('4. Inbound SCREENSHOT_TAKEN from known contact records notice and bypasses Signal decrypt', () async {
      // Add peer to active chats
      chatProvider.addChat(
        DiscoverUser(
          masterPubKeyHex: 'peer_master_123',
          nostrPubKeyHex: testPeerPubKey,
          username: 'bob',
          lastSeen: DateTime.now(),
        ),
      );

      final controlPayload = jsonEncode({
        'type': -1,
        'control': 'SCREENSHOT_TAKEN',
        'senderMasterPubKey': 'peer_master_123',
        'sentAt': DateTime.now().millisecondsSinceEpoch,
      });

      final fakeEvent = NostrEvent(
        id: 'fake_event_id_1',
        kind: 4444,
        content: controlPayload,
        sig: 'fake_sig',
        pubkey: testPeerPubKey,
        createdAt: DateTime.now(),
        tags: [
          ['p', authProvider.masterPublicKeyHex!],
        ],
      );

      // Handle the incoming Kind 4444 event
      await chatProvider.handleIncomingEventForTest(fakeEvent);

      // Verify that Signal decrypt was NOT attempted (preventing decryption crash & spurious session reset)
      expect(signalService.decryptAttempts, equals(0));

      // Verify screenshot notice was placed in conversation history
      final history = chatProvider.getMessagesFor(testPeerPubKey);
      expect(history.length, equals(1));
      expect(history.first.isMe, isFalse);
      expect(history.first.text, contains('Screenshot was taken'));
    });

    test(
      '5. Inbound SCREENSHOT_TAKEN from unknown peer is dropped safely',
      () async {
        const unknownPubKey =
            'unknown_peer_9999999999999999999999999999999999999999999999999999';

        final controlPayload = jsonEncode({
          'type': -1,
          'control': 'SCREENSHOT_TAKEN',
          'sentAt': DateTime.now().millisecondsSinceEpoch,
        });

        final fakeEvent = NostrEvent(
          id: 'fake_event_id_2',
          kind: 4444,
          content: controlPayload,
          sig: 'fake_sig',
          pubkey: unknownPubKey,
          createdAt: DateTime.now(),
          tags: [
            ['p', authProvider.masterPublicKeyHex!],
          ],
        );

        await chatProvider.handleIncomingEventForTest(fakeEvent);

        expect(signalService.decryptAttempts, equals(0));
        expect(chatProvider.getMessagesFor(unknownPubKey), isEmpty);
      },
    );
  });
}
