import 'package:flutter_test/flutter_test.dart';
import 'package:aisat_connect/models/discover_user.dart';
import 'package:aisat_connect/models/chat_message.dart';

void main() {
  group('Model Smoke Tests', () {
    test('DiscoverUser offline calculation', () {
      final user = DiscoverUser(
        masterPubKeyHex: '1234',
        nostrPubKeyHex: '5678',
        username: 'TestUser',
        lastSeen: DateTime.now().subtract(const Duration(minutes: 5)),
      );
      expect(user.isOnline, isFalse);
    });

    test('ChatMessage properties test', () {
      final now = DateTime.now();
      final msg = ChatMessage(
        text: 'Hello AISAT',
        isMe: true,
        timestamp: now,
      );
      expect(msg.text, 'Hello AISAT');
      expect(msg.isMe, isTrue);
      expect(msg.timestamp, now);
    });
  });
}

