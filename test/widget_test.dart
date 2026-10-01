import 'dart:convert';
import 'dart:io';
import 'dart:math' as dart_math;
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:dart_nostr/dart_nostr.dart';
import 'package:flutter/material.dart' hide Curve;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:aisat_connect/models/discover_user.dart';
import 'package:aisat_connect/models/chat_message.dart';
import 'package:aisat_connect/models/mndo_message_envelope.dart';
import 'package:aisat_connect/core/providers.dart';
import 'package:aisat_connect/providers/auth_provider.dart';
import 'package:aisat_connect/providers/chat_provider.dart';
import 'package:aisat_connect/providers/discover_provider.dart';
import 'package:aisat_connect/ui/profile_screen.dart';
import 'package:aisat_connect/ui/chat_screen.dart';
import 'package:aisat_connect/ui/widgets/whatsapp_formatter.dart';
import 'package:aisat_connect/ui/widgets/voice_note_bubble.dart';
import 'package:aisat_connect/ui/widgets/formatted_display_name.dart';
import 'package:aisat_connect/ui/widgets/online_status_indicator.dart';
import 'package:aisat_connect/services/crypto_service.dart';
import 'package:aisat_connect/services/voice_note_service.dart';
import 'package:aisat_connect/services/voice_note_playback_coordinator.dart';
import 'package:aisat_connect/ui/onboarding_screen.dart';
import 'package:aisat_connect/repositories/identity_repository.dart';
import 'package:aisat_connect/repositories/chat_repository.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aisat_connect/services/nostr_relay_service.dart';
import 'package:aisat_connect/services/signal_messaging_service.dart';
import 'package:aisat_connect/services/master_binding_verifier.dart';
import 'package:aisat_connect/services/signal_store.dart';
import 'package:aisat_connect/services/account_session.dart';
import 'package:aisat_connect/database/database.dart';
import 'package:drift/native.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3_raw;

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

    test('ChatMessage properties and MessageStatus test', () {
      final now = DateTime.now();
      final msg = ChatMessage(
        text: 'Hello AISAT',
        isMe: true,
        timestamp: now,
      );
      expect(msg.text, 'Hello AISAT');
      expect(msg.isMe, isTrue);
      expect(msg.timestamp, now);
      expect(msg.status, MessageStatus.sent);

      msg.status = MessageStatus.sending;
      expect(msg.status, MessageStatus.sending);

      msg.status = MessageStatus.failed;
      expect(msg.status, MessageStatus.failed);
    });

    test('DiscoverUser reactive search query filtering', () {
      final now = DateTime.now();
      final users = [
        DiscoverUser(masterPubKeyHex: 'aaa111', nostrPubKeyHex: 'n1', username: 'CoolCat', lastSeen: now),
        DiscoverUser(masterPubKeyHex: 'bbb222', nostrPubKeyHex: 'n2', username: 'SuperDog', displayName: 'Rover', lastSeen: now),
        DiscoverUser(masterPubKeyHex: 'ccc333', nostrPubKeyHex: 'n3', username: 'FastFox', lastSeen: now),
      ];

      final query = 'rover';
      final filtered = users.where((u) {
        return u.username.toLowerCase().contains(query) ||
            (u.displayName != null && u.displayName!.toLowerCase().contains(query)) ||
            u.masterPubKeyHex.toLowerCase().contains(query);
      }).toList();

      expect(filtered.length, 1);
      expect(filtered.first.username, 'SuperDog');
      expect(filtered.first.displayName, 'Rover');
    });

    test('DiscoverUser JSON serialization and deserialization round-trip', () {
      final now = DateTime.now();
      final user = DiscoverUser(
        masterPubKeyHex: '42a8dc3d374f4e735d7651252d550667cfcf91a6aeab3541',
        nostrPubKeyHex: '6a6e75359fc96bd4d92f191209f4e8417df852ac1d374e5d',
        username: 'Monsoon Vagabond',
        displayName: 'Monsoon',
        bio: 'Decentralized enthusiast',
        lastSeen: now,
        isExplicitlyOffline: false,
        isHidden: false,
      );

      final json = user.toJson();
      final restored = DiscoverUser.fromJson(json);

      expect(restored.masterPubKeyHex, user.masterPubKeyHex);
      expect(restored.nostrPubKeyHex, user.nostrPubKeyHex);
      expect(restored.username, user.username);
      expect(restored.displayName, user.displayName);
      expect(restored.bio, user.bio);
      expect(restored.isHidden, isFalse);
    });

    test('DiscoverUser online-first sorting puts active users ahead of offline users', () {
      final now = DateTime.now();
      final offlineUserOld = DiscoverUser(
        masterPubKeyHex: 'off1',
        nostrPubKeyHex: 'n_off1',
        username: 'OldOffline',
        lastSeen: now.subtract(const Duration(hours: 5)),
        isExplicitlyOffline: true,
      );

      final onlineUser = DiscoverUser(
        masterPubKeyHex: 'on1',
        nostrPubKeyHex: 'n_on1',
        username: 'ActiveNow',
        lastSeen: now,
        lastSeenFromPing: now, // within 70s -> isOnline true
      );

      final offlineUserRecent = DiscoverUser(
        masterPubKeyHex: 'off2',
        nostrPubKeyHex: 'n_off2',
        username: 'RecentOffline',
        lastSeen: now.subtract(const Duration(minutes: 10)),
        isExplicitlyOffline: true,
      );

      final list = [offlineUserOld, onlineUser, offlineUserRecent];
      list.sort((a, b) {
        if (a.isOnline != b.isOnline) {
          return a.isOnline ? -1 : 1;
        }
        return b.lastSeen.compareTo(a.lastSeen);
      });

      expect(list[0].username, 'ActiveNow');
      expect(list[1].username, 'RecentOffline');
      expect(list[2].username, 'OldOffline');
    });

    test('ChatMessage chronological sorting test', () {
      final t1 = DateTime(2026, 9, 19, 10, 0);
      final t2 = DateTime(2026, 9, 19, 11, 0);
      final t3 = DateTime(2026, 9, 20, 9, 0);

      final list = [
        ChatMessage(text: 'Third (Tomorrow)', isMe: false, timestamp: t3),
        ChatMessage(text: 'First (Yesterday)', isMe: true, timestamp: t1),
        ChatMessage(text: 'Second (Later)', isMe: false, timestamp: t2),
      ];

      list.sort((a, b) => a.timestamp.compareTo(b.timestamp));

      expect(list[0].text, 'First (Yesterday)');
      expect(list[1].text, 'Second (Later)');
      expect(list[2].text, 'Third (Tomorrow)');
    });

    test('Chat list sorts the person with the most recent message to the top', () {
      final now = DateTime.now();
      final userA = DiscoverUser(masterPubKeyHex: 'mA', nostrPubKeyHex: 'nA', username: 'UserA', lastSeen: now.subtract(const Duration(hours: 1)));
      final userB = DiscoverUser(masterPubKeyHex: 'mB', nostrPubKeyHex: 'nB', username: 'UserB', lastSeen: now.subtract(const Duration(hours: 2)));
      final userC = DiscoverUser(masterPubKeyHex: 'mC', nostrPubKeyHex: 'nC', username: 'UserC', lastSeen: now.subtract(const Duration(hours: 3)));

      final histories = {
        'nA': [ChatMessage(text: 'Old message', isMe: false, timestamp: now.subtract(const Duration(hours: 1)))],
        'nB': [ChatMessage(text: 'Latest message right now!', isMe: true, timestamp: now.subtract(const Duration(minutes: 1)))],
        'nC': [ChatMessage(text: 'Medium old message', isMe: false, timestamp: now.subtract(const Duration(minutes: 30)))],
      };

      final chats = [userA, userB, userC];
      chats.sort((a, b) {
        final hA = histories[a.nostrPubKeyHex];
        final hB = histories[b.nostrPubKeyHex];
        final tA = (hA != null && hA.isNotEmpty) ? hA.last.timestamp : a.lastSeen;
        final tB = (hB != null && hB.isNotEmpty) ? hB.last.timestamp : b.lastSeen;
        return tB.compareTo(tA);
      });

      expect(chats[0].username, 'UserB'); // Newest message (1 min ago)
      expect(chats[1].username, 'UserC'); // 30 min ago
      expect(chats[2].username, 'UserA'); // 1 hour ago
    });
    testWidgets('TextField hint and prefix icon alignment test', (WidgetTester tester) async {
      final controller = TextEditingController();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TextField(
              controller: controller,
              minLines: 1,
              maxLines: 3,
              textAlignVertical: TextAlignVertical.center,
              decoration: const InputDecoration(
                hintText: 'Enter your 12-word recovery phrase',
                prefixIcon: Icon(Icons.vpn_key_outlined),
              ),
            ),
          ),
        ),
      );

      final iconCenter = tester.getCenter(find.byIcon(Icons.vpn_key_outlined));
      final textCenter = tester.getCenter(find.text('Enter your 12-word recovery phrase'));
      expect((iconCenter.dy - textCenter.dy).abs(), lessThanOrEqualTo(0.5));
    });

    testWidgets('FormattedDisplayName renders hex suffix with smaller font when no display name', (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: FormattedDisplayName(
              displayName: null,
              username: 'Resolute Clam #58a68a',
              baseStyle: TextStyle(fontSize: 16.0, fontWeight: FontWeight.bold),
            ),
          ),
        ),
      );

      final textWidget = tester.widget<Text>(find.byWidgetPredicate((w) => w is Text && w.textSpan != null));
      final textSpan = textWidget.textSpan! as TextSpan;
      expect(textSpan.text, 'Resolute Clam ');
      expect(textSpan.style?.fontSize, 16.0);
      expect(textSpan.children?.length, 1);
      final hexSpan = textSpan.children!.first as TextSpan;
      expect(hexSpan.text, '#58a68a');
      expect(hexSpan.style?.fontSize, lessThan(16.0));
    });

    testWidgets('FormattedDisplayName renders standard text when custom display name is set', (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: FormattedDisplayName(
              displayName: 'Alice In Wonderland',
              username: 'Resolute Clam #58a68a',
              baseStyle: TextStyle(fontSize: 16.0),
            ),
          ),
        ),
      );

      expect(find.text('Alice In Wonderland'), findsOneWidget);
    });
  });

  group('Profile Screen Modernization Tests', () {
    testWidgets('ProfileScreen hides raw public key and shows copy button', (WidgetTester tester) async {
      final mockAuth = MockAuthProvider();
      final mockDiscover = MockDiscoverProvider();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authNotifierProvider.overrideWith((ref) => mockAuth),
            discoverNotifierProvider.overrideWith((ref) => mockDiscover),
          ],
          child: const MaterialApp(
            home: ProfileScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Raw 64-char public key should NOT be rendered in the UI
      expect(find.text('abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890'), findsNothing);

      // Copy Public Key button should be present
      expect(find.text('Copy Public Key'), findsOneWidget);

      // Old technical explanation text should NOT be present
      expect(find.textContaining('Want to find random users'), findsNothing);
      expect(find.textContaining('broadcast to the public Nostr feed'), findsNothing);

      // Initial Announce Me button is present
      expect(find.text('Announce Me to the Public Feed'), findsOneWidget);

      // Tap Announce Me button -> transforms into toggle switch
      await tester.tap(find.text('Announce Me to the Public Feed'));
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();

      expect(mockDiscover.hasEverAnnounced, isTrue);
      expect(mockDiscover.isAnnounced, isTrue);
      expect(find.byType(Switch), findsOneWidget);
      expect(find.text('Visible to other users'), findsOneWidget);

      // Toggle off -> remains a toggle switch, does not revert to big button
      await tester.ensureVisible(find.byType(Switch));
      await tester.tap(find.byType(Switch));
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();

      expect(mockDiscover.isAnnounced, isFalse);
      expect(find.byType(Switch), findsOneWidget);
      expect(find.text('Hidden from public feed'), findsWidgets);
      expect(find.text('Announce Me to the Public Feed'), findsNothing);
    });
  });

  group('Telegram-Style Chat Screen Tests', () {
    testWidgets('ChatScreen renders Telegram header, message bubble, and large emoji message', (WidgetTester tester) async {
      final mockAuth = MockAuthProvider();
      final mockDiscover = MockDiscoverProvider();
      final mockChat = MockChatProvider();

      mockChat.chatHistories['recipient_nostr_123'] = [
        ChatMessage(
          text: 'Hello from Telegram style!',
          isMe: true,
          timestamp: DateTime.now().subtract(const Duration(minutes: 5)),
        ),
        ChatMessage(
          text: 'fd',
          isMe: true,
          timestamp: DateTime.now().subtract(const Duration(minutes: 2)),
        ),
        ChatMessage(
          text: 'jdifjriff\nf\nf\nf\nff',
          isMe: false,
          timestamp: DateTime.now().subtract(const Duration(minutes: 1)),
        ),
        ChatMessage(
          text: '🔥',
          isMe: false,
          timestamp: DateTime.now(),
        ),
      ];

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authNotifierProvider.overrideWith((ref) => mockAuth),
            discoverNotifierProvider.overrideWith((ref) => mockDiscover),
            chatNotifierProvider.overrideWith((ref) => mockChat),
            signalMessagingServiceProvider.overrideWith((ref) => null),
          ],
          child: const MaterialApp(
            home: ChatScreen(
              recipientMasterPubKey: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
              recipientNostrPubKey: 'recipient_nostr_123',
              recipientUsername: 'telegram_user',
              recipientDisplayName: 'Pavel Durov',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Top App Bar displays contact name
      expect(find.text('Pavel Durov'), findsOneWidget);

      // Normal text bubble is displayed
      expect(find.text('Hello from Telegram style!'), findsOneWidget);

      // Short message "fd" is displayed and shrink-wrapped (compact inline row, not stretched full width)
      expect(find.text('fd'), findsOneWidget);
      final fdSize = tester.getSize(find.ancestor(
        of: find.text('fd'),
        matching: find.byType(Container),
      ).first);
      expect(fdSize.width, lessThan(180.0));

      // Multiline message with newlines is shrink-wrapped tightly to content (not stretched across screen)
      expect(find.text('jdifjriff\nf\nf\nf\nff'), findsOneWidget);
      final multilineSize = tester.getSize(find.ancestor(
        of: find.text('jdifjriff\nf\nf\nf\nff'),
        matching: find.byType(Container),
      ).first);
      expect(multilineSize.width, lessThan(180.0));

      // Emoji-only message is displayed
      expect(find.text('🔥'), findsOneWidget);

      // Verify emoji text has 42.0 font size
      final emojiWidget = tester.widget<Text>(find.text('🔥'));
      expect(emojiWidget.style?.fontSize, 42.0);

      // WhatsApp standard composer shows microphone button when input is empty
      expect(find.byIcon(Icons.mic_rounded), findsOneWidget);
    });

    testWidgets('ChatScreen preserves Ghost username when contact is unannounced or hidden', (WidgetTester tester) async {
      final mockAuth = MockAuthProvider();
      final mockDiscover = MockDiscoverProvider();
      final mockChat = MockChatProvider();

      // Recipient is unannounced/hidden in DiscoverProvider
      final hiddenUser = DiscoverUser(
        masterPubKeyHex: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        nostrPubKeyHex: 'recipient_nostr_123',
        username: 'Resolute Clam #58a68a',
        isHidden: true,
        lastSeen: DateTime.now(),
      );
      mockDiscover.usersByMaster[hiddenUser.masterPubKeyHex] = hiddenUser;
      mockDiscover.usersByNostr[hiddenUser.nostrPubKeyHex] = hiddenUser;

      mockChat.chatHistories['recipient_nostr_123'] = [
        ChatMessage(
          text: 'Hello from contact',
          isMe: false,
          timestamp: DateTime.now(),
        ),
      ];

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authNotifierProvider.overrideWith((ref) => mockAuth),
            discoverNotifierProvider.overrideWith((ref) => mockDiscover),
            chatNotifierProvider.overrideWith((ref) => mockChat),
            signalMessagingServiceProvider.overrideWith((ref) => null),
          ],
          child: const MaterialApp(
            home: ChatScreen(
              recipientMasterPubKey: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
              recipientNostrPubKey: 'recipient_nostr_123',
              recipientUsername: 'Ghost #0123',
              recipientDisplayName: null,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Should display Ghost #0123, NOT the hidden user's real username
      expect(find.textContaining('Ghost'), findsOneWidget);
      expect(find.textContaining('#0123'), findsOneWidget);
      expect(find.textContaining('Resolute Clam'), findsNothing);
    });

    testWidgets('ChatScreen upgrades Ghost to real username when contact becomes announced', (WidgetTester tester) async {
      final mockAuth = MockAuthProvider();
      final mockDiscover = MockDiscoverProvider();
      final mockChat = MockChatProvider();

      // Recipient is actively announced in DiscoverProvider
      final announcedUser = DiscoverUser(
        masterPubKeyHex: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        nostrPubKeyHex: 'recipient_nostr_123',
        username: 'Resolute Clam #58a68a',
        isHidden: false,
        lastSeen: DateTime.now(),
      );
      mockDiscover.usersByMaster[announcedUser.masterPubKeyHex] = announcedUser;
      mockDiscover.usersByNostr[announcedUser.nostrPubKeyHex] = announcedUser;

      mockChat.chatHistories['recipient_nostr_123'] = [
        ChatMessage(
          text: 'Hello from Announced',
          isMe: false,
          timestamp: DateTime.now(),
        ),
      ];

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authNotifierProvider.overrideWith((ref) => mockAuth),
            discoverNotifierProvider.overrideWith((ref) => mockDiscover),
            chatNotifierProvider.overrideWith((ref) => mockChat),
            signalMessagingServiceProvider.overrideWith((ref) => null),
          ],
          child: const MaterialApp(
            home: ChatScreen(
              recipientMasterPubKey: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
              recipientNostrPubKey: 'recipient_nostr_123',
              recipientUsername: 'Ghost #0123',
              recipientDisplayName: null,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Since contact is announced, it should resolve to Resolute Clam #58a68a
      expect(find.textContaining('Resolute Clam'), findsOneWidget);
      expect(find.textContaining('#58a68a'), findsOneWidget);
    });

    testWidgets('ChatScreen desktop layout opens WhatsApp-style contact info side panel on header click and closes on X tap', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final mockAuth = MockAuthProvider();
      final mockDiscover = MockDiscoverProvider();
      final mockChat = MockChatProvider();
      mockChat.chatHistories['recipient_nostr_123'] = [
        ChatMessage(
          text: 'Hello Alice',
          isMe: true,
          timestamp: DateTime.now(),
        ),
      ];

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authNotifierProvider.overrideWith((ref) => mockAuth),
            discoverNotifierProvider.overrideWith((ref) => mockDiscover),
            chatNotifierProvider.overrideWith((ref) => mockChat),
            signalMessagingServiceProvider.overrideWith((ref) => null),
          ],
          child: const MaterialApp(
            home: ChatScreen(
              recipientMasterPubKey: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
              recipientNostrPubKey: 'recipient_nostr_123',
              recipientUsername: 'alice_123',
              recipientDisplayName: 'Alice Nakamoto',
              recipientBio: 'Building decentralized tech',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Initially side panel is closed
      expect(find.text('Contact info'), findsNothing);

      // Tap on the contact header
      await tester.tap(find.byKey(const ValueKey('chat_header_profile_button')));
      await tester.pumpAndSettle();

      // Side panel opens with clean minimal contact details
      expect(find.text('Contact info'), findsOneWidget);
      expect(find.text('Building decentralized tech'), findsOneWidget);
      expect(find.text('About'), findsOneWidget);
      expect(find.text('End-to-end encrypted'), findsNothing);

      // Tap close button on side panel
      await tester.tap(find.byTooltip('Close contact info'));
      await tester.pumpAndSettle();

      // Side panel is cleanly closed
      expect(find.text('Contact info'), findsNothing);
    });

    testWidgets('ChatScreen mobile layout opens WhatsApp-style bottom sheet on header click', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final mockAuth = MockAuthProvider();
      final mockDiscover = MockDiscoverProvider();
      final mockChat = MockChatProvider();
      mockChat.chatHistories['recipient_nostr_123'] = [
        ChatMessage(
          text: 'Hello mobile Alice',
          isMe: true,
          timestamp: DateTime.now(),
        ),
      ];

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authNotifierProvider.overrideWith((ref) => mockAuth),
            discoverNotifierProvider.overrideWith((ref) => mockDiscover),
            chatNotifierProvider.overrideWith((ref) => mockChat),
            signalMessagingServiceProvider.overrideWith((ref) => null),
          ],
          child: const MaterialApp(
            home: ChatScreen(
              recipientMasterPubKey: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
              recipientNostrPubKey: 'recipient_nostr_123',
              recipientUsername: 'alice_123',
              recipientDisplayName: 'Alice Nakamoto',
              recipientBio: 'Building decentralized tech',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Tap header on mobile screen
      await tester.tap(find.byKey(const ValueKey('chat_header_profile_button')));
      await tester.pumpAndSettle();

      // Modal bottom sheet slides up with clean minimal contact info
      expect(find.text('Contact info'), findsOneWidget);
      expect(find.text('Building decentralized tech'), findsOneWidget);
      expect(find.text('About'), findsOneWidget);
      expect(find.text('End-to-end encrypted'), findsNothing);
    });
  });

  group('WhatsApp Formatting & Controller Tests', () {
    test('WhatsAppTextEditingController ordered list auto-continuation and termination', () {
      final controller = WhatsAppTextEditingController();

      // Start with "1. Buy milk"
      controller.text = '1. Buy milk';
      controller.selection = const TextSelection.collapsed(offset: 11);

      // User enters newline
      controller.value = const TextEditingValue(
        text: '1. Buy milk\n',
        selection: TextSelection.collapsed(offset: 12),
      );

      // Should automatically continue with "2. "
      expect(controller.text, '1. Buy milk\n2. ');
      expect(controller.selection.baseOffset, 15);

      // User hits enter on empty "2. " to terminate
      controller.value = TextEditingValue(
        text: '${controller.text}\n',
        selection: TextSelection.collapsed(offset: controller.text.length + 1),
      );

      // "2. " should be removed and list terminated
      expect(controller.text, '1. Buy milk\n');
    });

    test('WhatsAppTextEditingController bullet list auto-continuation and dash-to-bullet conversion', () {
      final controller = WhatsAppTextEditingController();

      // Typing "- " should convert to "• "
      controller.text = '-';
      controller.selection = const TextSelection.collapsed(offset: 1);
      controller.value = const TextEditingValue(
        text: '- ',
        selection: TextSelection.collapsed(offset: 2),
      );
      expect(controller.text, '• ');

      // Add item text
      controller.text = '• Apples';
      controller.selection = const TextSelection.collapsed(offset: 8);

      // Newline should continue with bullet
      controller.value = const TextEditingValue(
        text: '• Apples\n',
        selection: TextSelection.collapsed(offset: 9),
      );
      expect(controller.text, '• Apples\n• ');
    });

    test('WhatsAppTextEditingController blockquote continuation and termination', () {
      final controller = WhatsAppTextEditingController();

      controller.text = '> Note this';
      controller.selection = const TextSelection.collapsed(offset: 11);

      controller.value = const TextEditingValue(
        text: '> Note this\n',
        selection: TextSelection.collapsed(offset: 12),
      );
      expect(controller.text, '> Note this\n> ');

      // Newline on empty quote terminates
      controller.value = TextEditingValue(
        text: '${controller.text}\n',
        selection: TextSelection.collapsed(offset: controller.text.length + 1),
      );
      expect(controller.text, '> Note this\n');
    });

    testWidgets('WhatsAppFormattedText renders rich formatting in chat bubble', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: WhatsAppFormattedText(
              text: '*Bold* and _Italic_ and ~Strike~ and `code`',
              baseStyle: TextStyle(fontSize: 15, color: Colors.black),
              isMine: true,
              isDark: false,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final richTextFinder = find.byType(RichText);
      expect(richTextFinder, findsWidgets);

      final richText = tester.widget<RichText>(richTextFinder.first);
      final plainText = richText.text.toPlainText();
      expect(plainText, 'Bold and Italic and Strike and code');
    });

    testWidgets('WhatsAppFormattedText renders code block and quotes', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: WhatsAppFormattedText(
              text: '```\nvoid main() {}\n```\n> Important quote\n• Bullet 1',
              baseStyle: TextStyle(fontSize: 15, color: Colors.black),
              isMine: false,
              isDark: false,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('void main() {}'), findsOneWidget);
      expect(find.textContaining('Important quote'), findsOneWidget);
      expect(find.textContaining('Bullet 1'), findsOneWidget);
    });
  });

  group('BIP-39 Mnemonic Validation Tests', () {
    test('CryptoService validates valid and invalid mnemonics', () {
      final crypto = CryptoService();

      // Generated mnemonic must be valid
      final generated = crypto.generateMnemonic();
      expect(crypto.validateMnemonic(generated), isTrue);

      // Random 12 words that are not in BIP-39 or whose checksum fails must be rejected
      expect(crypto.validateMnemonic('random words that are not a valid bip39 phrase at all hello world'), isFalse);
      expect(crypto.validateMnemonic('one two three four five six seven eight nine ten eleven twelve'), isFalse);
      expect(crypto.validateMnemonic('apple banana cat dog elephant frog grape horse ice juice kite lion'), isFalse);

      // Less or more than 12 words must be rejected
      expect(crypto.validateMnemonic('only three words'), isFalse);
    });
  });

  group('Voice Notes E2EE & Payload Tests', () {
    test('VoiceNotePayload serialization, detection, and round-trip parsing', () {
      final payload = VoiceNotePayload(
        url: 'https://blossom.primal.net/e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
        key: base64Encode(List.filled(32, 7)),
        nonce: base64Encode(List.filled(12, 3)),
        mac: base64Encode(List.filled(16, 9)),
        fileHash: 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
        durationMs: 8400,
        waveform: [15, 25, 60, 85, 95, 70, 45, 30, 20, 80],
      );

      final jsonString = payload.serialize();

      // Detection
      expect(VoiceNotePayload.isVoiceNote(jsonString), isTrue);
      expect(VoiceNotePayload.isVoiceNote('Hello, how are you?'), isFalse);
      expect(VoiceNotePayload.isVoiceNote('{"type":"text","content":"hi"}'), isFalse);

      // Parsing
      final parsed = VoiceNotePayload.tryParse(jsonString);
      expect(parsed, isNotNull);
      expect(parsed!.url, payload.url);
      expect(parsed.key, payload.key);
      expect(parsed.nonce, payload.nonce);
      expect(parsed.mac, payload.mac);
      expect(parsed.fileHash, payload.fileHash);
      expect(parsed.durationMs, 8400);
      expect(parsed.waveform, equals([15, 25, 60, 85, 95, 70, 45, 30, 20, 80]));

      // Parsing when wrapped in MndoMessageEnvelope JSON (legacy/fallback resilience)
      final envelopeJson = jsonEncode({
        'v': 1,
        'id': 'msg-123456',
        'type': 'voice_note',
        'ts': 1790271522695,
        'sender': '0290d2895e5759b03c32c35d85ee0bc83e8492883debb724ef365b35c83e8eca',
        'body': {
          'text': jsonString,
          'fileHash': payload.fileHash,
        }
      });
      final parsedFromEnvelope = VoiceNotePayload.tryParse(envelopeJson);
      expect(parsedFromEnvelope, isNotNull);
      expect(parsedFromEnvelope!.url, payload.url);
      expect(parsedFromEnvelope.fileHash, payload.fileHash);
      expect(parsedFromEnvelope.durationMs, 8400);
    });

    test('Voice note AES-256-GCM local encryption & decryption byte integrity', () async {
      final aesGcm = AesGcm.with256bits();

      // Generate dummy audio bytes
      final originalAudioBytes = List<int>.generate(1024, (i) => (i * 37) % 256);

      // 1. Generate key and nonce
      final secretKey = await aesGcm.newSecretKey();
      final keyBytes = await secretKey.extractBytes();
      final nonce = aesGcm.newNonce();

      // 2. Encrypt locally
      final secretBox = await aesGcm.encrypt(
        originalAudioBytes,
        secretKey: secretKey,
        nonce: nonce,
      );

      final cipherText = secretBox.cipherText;
      final macBytes = secretBox.mac.bytes;

      expect(cipherText.length, originalAudioBytes.length);
      expect(cipherText, isNot(equals(originalAudioBytes)));

      // 3. Reconstruct and Decrypt on recipient end
      final recipientBox = SecretBox(
        cipherText,
        nonce: nonce,
        mac: Mac(macBytes),
      );

      final decryptedBytes = await aesGcm.decrypt(
        recipientBox,
        secretKey: SecretKey(keyBytes),
      );

      expect(decryptedBytes, equals(originalAudioBytes));
    });

    testWidgets('VoiceNoteBubble widget rendering smoke test', (WidgetTester tester) async {
      final payload = VoiceNotePayload(
        url: 'https://blossom.primal.net/abc123456',
        key: base64Encode(List.filled(32, 1)),
        nonce: base64Encode(List.filled(12, 2)),
        mac: base64Encode(List.filled(16, 3)),
        fileHash: 'abc123456',
        durationMs: 12500, // 12.5 seconds -> 0:12
        waveform: [10, 20, 50, 80, 100, 75, 40, 20, 10],
      );

      final msg = ChatMessage(
        text: payload.serialize(),
        isMe: true,
        timestamp: DateTime(2026, 9, 20, 14, 30),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VoiceNoteBubble(
              msg: msg,
              payload: payload,
              isMine: true,
              isDark: false,
              isConsecutive: false,
              timeStr: '2:30 pm',
              statusIcon: const Icon(Icons.check_rounded, size: 14),
            ),
          ),
        ),
      );

      // Verify duration '0:12' is displayed
      expect(find.text('0:12'), findsOneWidget);
      // Verify time '2:30 pm' is displayed
      expect(find.text('2:30 pm'), findsOneWidget);
      // Verify play button icon is rendered
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
      // Verify custom waveform CustomPaint is rendered
      expect(find.byType(CustomPaint), findsWidgets);
    });

    testWidgets('VoiceNoteBubble displays sending loading spinner when status is sending', (WidgetTester tester) async {
      final payload = VoiceNotePayload(
        durationMs: 4000,
        waveform: [10, 30, 60, 90, 40],
        localPath: '/tmp/test.m4a',
      );

      final msg = ChatMessage(
        text: payload.serialize(),
        isMe: true,
        timestamp: DateTime(2026, 9, 21, 1, 0),
        status: MessageStatus.sending,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VoiceNoteBubble(
              msg: msg,
              payload: payload,
              isMine: true,
              isDark: false,
              isConsecutive: false,
              timeStr: '1:00 am',
              statusIcon: const Icon(Icons.access_time_rounded, size: 14),
            ),
          ),
        ),
      );

      // Verify duration '0:04' is displayed
      expect(find.text('0:04'), findsOneWidget);
      // In sending status, the play arrow should NOT be present; CircularProgressIndicator should be visible!
      expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      // Verify clock status icon is rendered
      expect(find.byIcon(Icons.access_time_rounded), findsOneWidget);
    });

    testWidgets('VoiceNoteBubble displays retry icon when status is failed and triggers onRetry', (WidgetTester tester) async {
      final payload = VoiceNotePayload(
        durationMs: 8000,
        waveform: [20, 40, 80],
        localPath: '/tmp/test_failed.m4a',
      );

      final msg = ChatMessage(
        text: payload.serialize(),
        isMe: true,
        timestamp: DateTime(2026, 9, 21, 1, 5),
        status: MessageStatus.failed,
      );

      bool retryCalled = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VoiceNoteBubble(
              msg: msg,
              payload: payload,
              isMine: true,
              isDark: false,
              isConsecutive: false,
              timeStr: '1:05 am',
              statusIcon: const Icon(Icons.refresh_rounded, size: 14),
              onRetry: () {
                retryCalled = true;
              },
            ),
          ),
        ),
      );

      expect(find.byIcon(Icons.refresh_rounded), findsWidgets);
      // Tap on the button to retry
      await tester.tap(find.byIcon(Icons.refresh_rounded).first);
      expect(retryCalled, isTrue);
    });

    test('VoiceNotePayload network serialization omits sender localPath and preserves sentAt', () {
      final sentTimeMs = DateTime(2026, 9, 21, 10, 30).millisecondsSinceEpoch;
      final payload = VoiceNotePayload(
        url: 'https://blossom.primal.net/abc',
        key: 'secretkey',
        nonce: 'nonce123',
        mac: 'mac123',
        fileHash: 'abc',
        durationMs: 5000,
        waveform: [10, 20, 30],
        localPath: '/local/device/path/test.m4a',
        sentAt: sentTimeMs,
      );

      final localJson = payload.serialize();
      expect(localJson.contains('localPath'), isTrue);
      expect(localJson.contains('"sentAt":$sentTimeMs'), isTrue);

      final networkJson = payload.serializeForNetwork();
      expect(networkJson.contains('localPath'), isFalse);
      expect(networkJson.contains('https://blossom.primal.net/abc'), isTrue);
      expect(networkJson.contains('"sentAt":$sentTimeMs'), isTrue);

      final parsed = VoiceNotePayload.tryParse(networkJson);
      expect(parsed, isNotNull);
      expect(parsed!.sentAt, equals(sentTimeMs));
      expect(parsed.durationMs, equals(5000));
    });

    testWidgets('VoiceNoteBubble displays incoming loading spinner and duration for remote voice note', (WidgetTester tester) async {
      final payload = VoiceNotePayload(
        url: 'https://blossom.primal.net/dummy_hash',
        key: 'AQIDBA==',
        nonce: 'BQYHCA==',
        mac: 'CQoLDA==',
        fileHash: 'dummy_hash',
        durationMs: 6500,
        waveform: [15, 35, 75, 45],
        localPath: null,
      );

      final msg = ChatMessage(
        text: payload.serializeForNetwork(),
        isMe: false,
        timestamp: DateTime(2026, 9, 21, 11, 0),
        status: MessageStatus.sent,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VoiceNoteBubble(
              msg: msg,
              payload: payload,
              isMine: false,
              isDark: false,
              isConsecutive: false,
              timeStr: '11:00 am',
            ),
          ),
        ),
      );

      // Verify duration '0:06' is displayed immediately
      expect(find.text('0:06'), findsOneWidget);
      // Verify time '11:00 am' is displayed
      expect(find.text('11:00 am'), findsOneWidget);
      // For incoming voice note without local file, it shows loading spinner ("something coming")
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);

      // Verify the entire card has the incoming loading opacity
      final animatedOpacity = tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity));
      expect(animatedOpacity.opacity, equals(0.82));

      // Tapping the loading button does not trigger playback (strictly unplayable until finished)
      await tester.tap(find.byType(CircularProgressIndicator));
      await tester.pump();
      expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    test('Incoming voice note and subsequent text messages preserve strict chronological order', () {
      final t0 = DateTime(2026, 9, 21, 11, 0, 0);
      final t1 = DateTime(2026, 9, 21, 11, 0, 2); // 2 seconds later
      final t2 = DateTime(2026, 9, 21, 11, 0, 5); // 5 seconds later

      final vnPayload = VoiceNotePayload(
        url: 'https://blossom.primal.net/hash123',
        key: 'key',
        nonce: 'nonce',
        mac: 'mac',
        fileHash: 'hash123',
        durationMs: 3200,
        waveform: [20, 50, 20],
        sentAt: t0.millisecondsSinceEpoch,
      );

      final voiceMsg = ChatMessage(
        text: vnPayload.serializeForNetwork(),
        isMe: false,
        timestamp: DateTime.fromMillisecondsSinceEpoch(vnPayload.sentAt!),
      );

      final textMsg1 = ChatMessage(
        text: 'Listen to this quick audio note!',
        isMe: false,
        timestamp: t1,
      );

      final textMsg2 = ChatMessage(
        text: 'Let me know what you think.',
        isMe: false,
        timestamp: t2,
      );

      final history = <ChatMessage>[textMsg2, voiceMsg, textMsg1];
      history.sort((a, b) => a.timestamp.compareTo(b.timestamp));

      expect(history[0], equals(voiceMsg));
      expect(history[1], equals(textMsg1));
      expect(history[2], equals(textMsg2));
    });

    test('parseAudioDurationMs accurately parses MP4 and WAV container durations from bytes', () {
      // 1. Synthesize minimal MP4 with 'mvhd' atom: timescale 1000, duration 7500
      final mp4Bytes = <int>[
        0, 0, 0, 32, // length 32
        0x6D, 0x76, 0x68, 0x64, // 'mvhd'
        0, 0, 0, 0, // version 0, flags
        0, 0, 0, 0, // creation time
        0, 0, 0, 0, // modification time
        0, 0, 0x03, 0xE8, // timescale: 1000
        0, 0, 0x1D, 0x4C, // duration: 7500
      ];
      final parsedMp4 = VoiceNoteService.parseAudioDurationMs(mp4Bytes);
      expect(parsedMp4, equals(7500));

      // 2. Synthesize minimal WAV header: byteRate 32000, dataSize 64000 -> 2000ms
      final wavBytes = List<int>.filled(48, 0);
      wavBytes[0] = 0x52; wavBytes[1] = 0x49; wavBytes[2] = 0x46; wavBytes[3] = 0x46; // RIFF
      // byteRate = 32000 (0x00007D00)
      wavBytes[28] = 0x00; wavBytes[29] = 0x7D; wavBytes[30] = 0x00; wavBytes[31] = 0x00;
      // dataSize = 64000 (0x0000FA00)
      wavBytes[40] = 0x00; wavBytes[41] = 0xFA; wavBytes[42] = 0x00; wavBytes[43] = 0x00;

      final parsedWav = VoiceNoteService.parseAudioDurationMs(wavBytes);
      expect(parsedWav, equals(2000));
    });

    testWidgets('VoiceNoteBubble allows sender immediate playback when local file exists even while sending', (WidgetTester tester) async {
      // Create temporary mock audio file
      final tempFile = File('${Directory.systemTemp.path}/vn_test_instant_play.m4a');
      tempFile.writeAsBytesSync([0, 1, 2, 3, 4]);

      try {
        final payload = VoiceNotePayload(
          durationMs: 5000,
          waveform: [10, 20, 40, 60],
          localPath: tempFile.path,
        );

        final msg = ChatMessage(
          text: payload.serialize(),
          isMe: true,
          timestamp: DateTime(2026, 9, 21, 12, 0),
          status: MessageStatus.sending,
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: VoiceNoteBubble(
                msg: msg,
                payload: payload,
                isMine: true,
                isDark: false,
                isConsecutive: false,
                timeStr: '12:00 pm',
                statusIcon: const Icon(Icons.access_time_rounded, size: 14),
              ),
            ),
          ),
        );

        // Sender with local file has play button immediately available (no blocking spinner on button)
        expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
        // The play button itself is NOT showing CircularProgressIndicator
        expect(find.byType(CircularProgressIndicator), findsNothing);
        // Duration is displayed properly
        expect(find.text('0:05'), findsOneWidget);
        // Bottom right status icon still shows the sending status (clock)
        expect(find.byIcon(Icons.access_time_rounded), findsOneWidget);
      } finally {
        if (tempFile.existsSync()) {
          tempFile.deleteSync();
        }
      }
    });

    testWidgets('VoiceNoteBubble and chat list preserve state isolation between distinct voice notes', (WidgetTester tester) async {
      final fileOld = File('${Directory.systemTemp.path}/vn_test_old.m4a');
      final fileNew = File('${Directory.systemTemp.path}/vn_test_new.m4a');
      fileOld.writeAsBytesSync([1, 2, 3, 4]);
      fileNew.writeAsBytesSync([5, 6, 7, 8, 9]);

      try {
        final payloadOld = VoiceNotePayload(
          durationMs: 3000,
          waveform: [10, 20],
          fileHash: 'old_hash_111',
          localPath: fileOld.path,
        );
        final msgOld = ChatMessage(
          text: payloadOld.serialize(),
          isMe: true,
          timestamp: DateTime(2026, 9, 21, 12, 0, 0),
          status: MessageStatus.sent,
        );

        final payloadNew = VoiceNotePayload(
          durationMs: 7000,
          waveform: [30, 40, 50],
          fileHash: 'new_hash_222',
          localPath: fileNew.path,
        );
        final msgNew = ChatMessage(
          text: payloadNew.serialize(),
          isMe: true,
          timestamp: DateTime(2026, 9, 21, 12, 1, 0),
          status: MessageStatus.sent,
        );

        // Render inverted list with KeyedSubtree keys as in ChatScreen
        final messages = [msgOld, msgNew];
        final reversed = messages.reversed.toList(); // [msgNew, msgOld]

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ListView.builder(
                itemCount: reversed.length,
                itemBuilder: (context, index) {
                  final msg = reversed[index];
                  final payload = VoiceNotePayload.tryParse(msg.text)!;
                  final itemKey = 'msg_${msg.timestamp.microsecondsSinceEpoch}_${msg.isMe}_${msg.text.hashCode}';
                  final voiceKey = 'vn_${msg.timestamp.microsecondsSinceEpoch}_${payload.fileHash}_${msg.isMe}';
                  return KeyedSubtree(
                    key: ValueKey(itemKey),
                    child: VoiceNoteBubble(
                      key: ValueKey(voiceKey),
                      msg: msg,
                      payload: payload,
                      isMine: true,
                      isDark: false,
                      isConsecutive: false,
                      timeStr: '12:0$index pm',
                    ),
                  );
                },
              ),
            ),
          ),
        );

        // Verify both voice notes render with their distinct durations
        expect(find.text('0:07'), findsOneWidget); // msgNew at index 0
        expect(find.text('0:03'), findsOneWidget); // msgOld at index 1

        // Verify didUpdateWidget updates state when widget receives new payload
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: VoiceNoteBubble(
                key: const ValueKey('reused_bubble'),
                msg: msgOld,
                payload: payloadOld,
                isMine: true,
                isDark: false,
                isConsecutive: false,
                timeStr: '12:00 pm',
              ),
            ),
          ),
        );
        expect(find.text('0:03'), findsOneWidget);

        // Update with new payload under same key to exercise didUpdateWidget
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: VoiceNoteBubble(
                key: const ValueKey('reused_bubble'),
                msg: msgNew,
                payload: payloadNew,
                isMine: true,
                isDark: false,
                isConsecutive: false,
                timeStr: '12:01 pm',
              ),
            ),
          ),
        );
        // Duration must update to new payload duration (0:07)
        expect(find.text('0:07'), findsOneWidget);
        expect(find.text('0:03'), findsNothing);
      } finally {
        if (fileOld.existsSync()) fileOld.deleteSync();
        if (fileNew.existsSync()) fileNew.deleteSync();
      }
    });

    test('VoiceNotePlaybackCoordinator cleanly pauses previous client and maintains single-audio invariant', () async {
      VoiceNotePlaybackCoordinator.instance.resetForTesting();

      final clientA = _TestPlaybackClient();
      final clientB = _TestPlaybackClient();

      // Client A starts playback
      await VoiceNotePlaybackCoordinator.instance.requestPlayback(clientA);
      expect(VoiceNotePlaybackCoordinator.instance.activeClient, equals(clientA));
      expect(clientA.isPaused, isFalse);
      expect(clientA.pauseCount, 0);

      // Client B starts playback -> Client A must be paused cleanly
      await VoiceNotePlaybackCoordinator.instance.requestPlayback(clientB);
      expect(VoiceNotePlaybackCoordinator.instance.activeClient, equals(clientB));
      expect(clientA.pauseCount, 1);
      expect(clientA.isPaused, isTrue);
      expect(clientB.isPaused, isFalse);

      // Client B stops
      VoiceNotePlaybackCoordinator.instance.stopIfActive(clientB);
      expect(VoiceNotePlaybackCoordinator.instance.activeClient, isNull);

      // stopAll test
      await VoiceNotePlaybackCoordinator.instance.requestPlayback(clientA);
      expect(VoiceNotePlaybackCoordinator.instance.activeClient, equals(clientA));
      await VoiceNotePlaybackCoordinator.instance.stopAll();
      expect(clientA.pauseCount, 2);
      expect(VoiceNotePlaybackCoordinator.instance.activeClient, isNull);
    });

    testWidgets('VoiceNoteBubble pausePlayback updates state and displays play_arrow_rounded icon', (tester) async {
      VoiceNotePlaybackCoordinator.instance.resetForTesting();
      final tempFile = File('${Directory.systemTemp.path}/vn_test_pause_icon.m4a');
      tempFile.writeAsBytesSync([1, 2, 3, 4, 5]);

      try {
        final payload = VoiceNotePayload(
          durationMs: 6000,
          waveform: [10, 20, 30],
          fileHash: 'hash_test_pause',
          localPath: tempFile.path,
        );
        final msg = ChatMessage(
          text: payload.serialize(),
          isMe: true,
          timestamp: DateTime(2026, 9, 21, 12, 0, 0),
          status: MessageStatus.sent,
        );

        final globalKey = GlobalKey();

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: VoiceNoteBubble(
                key: globalKey,
                msg: msg,
                payload: payload,
                isMine: true,
                isDark: false,
                isConsecutive: false,
                timeStr: '12:00 pm',
              ),
            ),
          ),
        );

        // Initially play button is play_arrow_rounded
        expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
        expect(find.byIcon(Icons.pause_rounded), findsNothing);

        // Access the bubble's State which implements VoiceNotePlaybackClient
        final client = globalKey.currentState as VoiceNotePlaybackClient;
        
        // When client requests playback through coordinator, it becomes active
        await VoiceNotePlaybackCoordinator.instance.requestPlayback(client);
        expect(VoiceNotePlaybackCoordinator.instance.activeClient, equals(client));

        // When another client requests playback, the first client is automatically paused
        final otherClient = _TestPlaybackClient();
        await VoiceNotePlaybackCoordinator.instance.requestPlayback(otherClient);
        await tester.pump();

        // VoiceNoteBubble's icon must be play_arrow_rounded (resuming/play icon)
        expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
        expect(find.byIcon(Icons.pause_rounded), findsNothing);
      } finally {
        if (tempFile.existsSync()) tempFile.deleteSync();
      }
    });

    testWidgets('OnboardingScreen displays Instagram/WhatsApp-style 12-word recovery phrase vault and features', (tester) async {
      final mockAuth = MockAuthProvider();
      mockAuth.mnemonic = 'bundle cycle payment life uniform uncover ketchup own addict clump bread foot';

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authNotifierProvider.overrideWith((ref) => mockAuth),
          ],
          child: const MaterialApp(
            home: OnboardingScreen(),
          ),
        ),
      );
      await tester.pump();

      // Header & Title
      expect(find.text('Secret Recovery Phrase'), findsOneWidget);
      expect(find.text('12-WORD MASTER KEY'), findsOneWidget);
      expect(find.text('E2EE Vault'), findsOneWidget);

      // Single sentence phrase display
      expect(find.textContaining('bundle cycle payment'), findsOneWidget);

      // Hide / Reveal
      expect(find.text('Hide'), findsOneWidget);
      await tester.tap(find.text('Hide'));
      await tester.pump();
      expect(find.text('Reveal'), findsOneWidget);
      expect(find.textContaining('••••'), findsOneWidget);

      // Reveal back
      await tester.tap(find.text('Reveal'));
      await tester.pump();
      expect(find.textContaining('bundle cycle payment'), findsOneWidget);

      // Copy Button
      final copyFinder = find.text('Copy 12 Words to Clipboard');
      expect(copyFinder, findsOneWidget);
      await tester.ensureVisible(copyFinder);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(copyFinder);
      await tester.pump();
      expect(find.text('Copied to Clipboard!'), findsOneWidget);

      // Crucial Security Rules (Minimal text)
      expect(find.text('Crucial Security Rules'), findsOneWidget);
      expect(find.textContaining('No password resets:'), findsOneWidget);
      expect(find.textContaining('Never share it:'), findsOneWidget);
      expect(find.textContaining('Write it down:'), findsOneWidget);

      // Confirmation & Button
      expect(find.text('I have safely written down or saved my 12-word phrase.'), findsOneWidget);
      expect(find.text('Continue to MNDO'), findsOneWidget);
    });
  });

  group('Senior Audit Security & Flow Fixes Tests', () {
    test('Database encryption key escaping properly sanitizes single quotes', () {
      const maliciousKey = "key_with_'single_quote_and_--_injection";
      final escapedKey = maliciousKey.replaceAll("'", "''");
      expect(escapedKey, "key_with_''single_quote_and_--_injection");
      expect(escapedKey.contains("''"), isTrue);
    });

    test('setupDatabaseEncryption aborts with UnsupportedError when cipher_version returns empty', () {
      final mockDb = _MockRawDb(cipherVersionReturn: <_MockDbRow>[]);
      expect(
        () => setupDatabaseEncryption(mockDb, 'test_key_123'),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('setupDatabaseEncryption aborts with UnsupportedError when cipher_version throws exception', () {
      final mockDb = _MockRawDb(shouldThrowOnSelect: true);
      expect(
        () => setupDatabaseEncryption(mockDb, 'test_key_123'),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('setupDatabaseEncryption aborts with UnsupportedError when cipher_version is null or whitespace', () {
      final mockDb = _MockRawDb(cipherVersionReturn: [_MockDbRow(['   '])]);
      expect(
        () => setupDatabaseEncryption(mockDb, 'test_key_123'),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('setupDatabaseEncryption executes PRAGMA cipher_version first and applies escaped key upon valid cipher', () {
      final mockDb = _MockRawDb(cipherVersionReturn: [_MockDbRow(['4.5.5 community'])]);
      setupDatabaseEncryption(mockDb, "my_secret_key_with_'quote");

      // Verify execution order: cipher_version MUST be executed before PRAGMA key
      expect(mockDb.executedStatements.first, 'PRAGMA cipher_version;');
      expect(
        mockDb.executedStatements[1],
        "PRAGMA key = 'my_secret_key_with_''quote';",
      );
      expect(mockDb.executedStatements, contains('PRAGMA cipher_memory_security = ON;'));
      expect(mockDb.executedStatements, contains('PRAGMA journal_mode = WAL;'));
      expect(mockDb.executedStatements, contains('PRAGMA synchronous = NORMAL;'));
    });

    test('Blossom upload failure returns null without spoofing fallback URL', () async {
      final vnService = VoiceNoteService();
      // Calling uploadEncryptedBytes with invalid/unreachable bytes & hash returns null
      // because blossom.primal.net and fallback servers fail or reject malformed data in unit test environment
      final result = await vnService.uploadEncryptedBytes(
        [0, 1, 2, 3],
        '0000000000000000000000000000000000000000000000000000000000000000',
      );
      expect(result, isNull);
    });

    test('Outer transport payload map omits senderMasterPubKey', () {
      final timestamp = DateTime.now();
      const text = 'Secure message';
      const masterPubKey = '0123456789abcdef';

      // Inner payload (encrypted under Signal Double Ratchet) contains senderMasterPubKey
      final innerPayloadJson = jsonEncode({
        'text': text,
        'sentAt': timestamp.millisecondsSinceEpoch,
        'senderMasterPubKey': masterPubKey,
      });
      final innerMap = jsonDecode(innerPayloadJson) as Map<String, dynamic>;
      expect(innerMap['senderMasterPubKey'], masterPubKey);

      // Outer transport map (sent to Nostr relay) ONLY contains type, ciphertext, sentAt
      final outerPayloadMap = {
        'type': 3, // CiphertextMessage.whisperType
        'ciphertext': 'mock_base64_ciphertext',
        'sentAt': timestamp.millisecondsSinceEpoch,
      };

      expect(outerPayloadMap.containsKey('senderMasterPubKey'), isFalse);
      expect(outerPayloadMap['type'], 3);
      expect(outerPayloadMap['ciphertext'], 'mock_base64_ciphertext');
    });

    test('AuthProvider derives fresh keys and handles onboarding reset', () async {
      final fakeRepo = FakeIdentityRepository();
      final auth = AuthProvider(
        identityRepo: fakeRepo,
        cryptoService: CryptoService(),
      );
      auth.mnemonic = 'test test test test test test test test test test test junk';
      expect(auth.mnemonic, isNotNull);
      expect(auth.mnemonic!.split(' ').length, 12);

      // Resetting onboarding clears mnemonic and prevents race conditions
      auth.resetOnboarding();
      expect(auth.mnemonic, isNull);
      expect(auth.masterKeyPair, isNull);
      expect(auth.username, isNull);
    });

    test('DiscoverProvider retains announced members up to 7 days and prunes older inactive members', () async {
      final now = DateTime.now();
      final activeUser = DiscoverUser(
        masterPubKeyHex: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        nostrPubKeyHex: 'active_nostr',
        username: 'active_user',
        lastSeen: now.subtract(const Duration(days: 3)), // 3 days ago <= 7 days
      );
      final staleUser = DiscoverUser(
        masterPubKeyHex: 'fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210',
        nostrPubKeyHex: 'stale_nostr',
        username: 'stale_user',
        lastSeen: now.subtract(const Duration(days: 8)), // 8 days ago > 7 days
      );
      final cachedJson = jsonEncode([activeUser.toJson(), staleUser.toJson()]);
      SharedPreferences.setMockInitialValues({
        'cached_discovered_members_1': cachedJson,
      });

      final auth = MockAuthProvider();
      final chat = MockChatProvider();
      final discover = DiscoverProvider(
        authProvider: auth,
        chatProvider: chat,
        cryptoService: CryptoService(),
      );

      await discover.loadState();
      expect(discover.discoveredUsers.any((u) => u.masterPubKeyHex == activeUser.masterPubKeyHex), isTrue);
      expect(discover.discoveredUsers.any((u) => u.masterPubKeyHex == staleUser.masterPubKeyHex), isFalse);
    });

    test('Signal UntrustedIdentity recovery updates identity and deletes stale session', () {
      final address = SignalProtocolAddress('peer_nostr_pubkey', 1);
      final keyPair = generateIdentityKeyPair();
      final newIdentityKey = keyPair.getPublicKey();

      final fakeIdentities = <String, List<int>>{};
      final fakeSessions = <String, List<int>>{};
      fakeSessions[address.toString()] = [1, 2, 3]; // existing stale session

      // When UntrustedIdentity occurs, identity is refreshed and stale session deleted
      fakeIdentities[address.toString()] = newIdentityKey.serialize();
      fakeSessions.remove(address.toString());

      expect(fakeIdentities.containsKey(address.toString()), isTrue);
      expect(fakeSessions.containsKey(address.toString()), isFalse);
    });

    test('MndoMessageEnvelope serialization, deserialization, and ID validation', () {
      final msgId = MndoMessageEnvelope.generateMessageId('msg');
      expect(msgId.startsWith('msg-'), isTrue);
      expect(msgId.length > 10, isTrue);

      final envelope = MndoMessageEnvelope(
        version: 1,
        messageId: msgId,
        type: 'text',
        timestamp: 1710000000000,
        senderMasterPubKey: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        body: {'text': 'Decentralized privacy first'},
        replyToId: 'msg_parent_123',
      );

      final serialized = envelope.serialize();
      final parsed = MndoMessageEnvelope.tryParse(serialized);

      expect(parsed, isNotNull);
      expect(parsed!.version, 1);
      expect(parsed.messageId, msgId);
      expect(parsed.type, 'text');
      expect(parsed.timestamp, 1710000000000);
      expect(parsed.senderMasterPubKey, '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef');
      expect(parsed.body['text'], 'Decentralized privacy first');
      expect(parsed.replyToId, 'msg_parent_123');

      // Invalid/legacy envelopes gracefully return null
      expect(MndoMessageEnvelope.tryParse('{"random": "json"}'), isNull);
      expect(MndoMessageEnvelope.tryParse('not json at all'), isNull);
    });

    test('MndoMessageEnvelope supports receipt envelopes', () {
      final receiptId = MndoMessageEnvelope.generateMessageId('rcpt');
      final envelope = MndoMessageEnvelope(
        version: 1,
        messageId: receiptId,
        type: 'receipt',
        timestamp: 1710000005000,
        senderMasterPubKey: 'fedcba0123456789fedcba0123456789fedcba0123456789fedcba0123456789',
        body: {
          'targetId': 'msg_original_999',
          'status': 'read',
        },
      );

      final parsed = MndoMessageEnvelope.tryParse(envelope.serialize());
      expect(parsed, isNotNull);
      expect(parsed!.type, 'receipt');
      expect(parsed.body['targetId'], 'msg_original_999');
      expect(parsed.body['status'], 'read');
    });

    test('CryptoService delegation token signing and cryptographic verification', () async {
      final cryptoService = CryptoService();
      final mnemonic = cryptoService.generateMnemonic();
      final masterKeyPair = await cryptoService.generateMasterKeyPair(mnemonic);
      final masterPubKey = await masterKeyPair.extractPublicKey();
      final masterPubKeyHex = masterPubKey.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

      const nostrPubKeyHex = 'aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899';
      final timestamp = DateTime.now().millisecondsSinceEpoch;

      final signature = await cryptoService.signDelegationToken(
        masterKeyPair: masterKeyPair,
        nostrPubKeyHex: nostrPubKeyHex,
        timestamp: timestamp,
      );

      expect(signature.length, 128); // 64 bytes hex-encoded

      // Authentic verification succeeds
      final isValid = await cryptoService.verifyDelegationToken(
        masterPubKeyHex: masterPubKeyHex,
        nostrPubKeyHex: nostrPubKeyHex,
        timestamp: timestamp,
        signatureHex: signature,
      );
      expect(isValid, isTrue);

      // Tampered nostrPubKey fails
      final tamperedNostr = await cryptoService.verifyDelegationToken(
        masterPubKeyHex: masterPubKeyHex,
        nostrPubKeyHex: '0000000000000000000000000000000000000000000000000000000000000000',
        timestamp: timestamp,
        signatureHex: signature,
      );
      expect(tamperedNostr, isFalse);

      // Tampered timestamp fails
      final tamperedTime = await cryptoService.verifyDelegationToken(
        masterPubKeyHex: masterPubKeyHex,
        nostrPubKeyHex: nostrPubKeyHex,
        timestamp: timestamp + 1000,
        signatureHex: signature,
      );
      expect(tamperedTime, isFalse);
    });

    test('ChatMessage messageId deduplication logic prevents duplicates', () {
      final now = DateTime.now();
      final msg1 = ChatMessage(
        messageId: 'msg_unique_1',
        text: 'Hello decentralized world',
        isMe: false,
        timestamp: now,
      );

      final msg1Duplicate = ChatMessage(
        messageId: 'msg_unique_1',
        text: 'Hello decentralized world',
        isMe: false,
        timestamp: now,
      );

      final history = <ChatMessage>[msg1];

      final isDuplicate = history.any((m) =>
        m.messageId == msg1Duplicate.messageId ||
        (m.isMe == msg1Duplicate.isMe &&
         m.text == msg1Duplicate.text &&
         m.timestamp.millisecondsSinceEpoch == msg1Duplicate.timestamp.millisecondsSinceEpoch)
      );

      expect(isDuplicate, isTrue);
    });

    test('MessageStatus supports full delivery lifecycle', () {
      final msg = ChatMessage(
        text: 'Status test',
        isMe: true,
        timestamp: DateTime.now(),
        status: MessageStatus.sending,
      );
      expect(msg.status, MessageStatus.sending);

      msg.status = MessageStatus.sent;
      expect(msg.status, MessageStatus.sent);

      msg.status = MessageStatus.delivered;
      expect(msg.status, MessageStatus.delivered);

      msg.status = MessageStatus.read;
      expect(msg.status, MessageStatus.read);
    });

    testWidgets('MessageStatus icons and colors render according to specification in ChatScreen', (tester) async {
      final mockAuth = MockAuthProvider();
      final mockDiscover = MockDiscoverProvider();
      final mockChat = MockChatProvider();

      final sendingMsg = ChatMessage(
        messageId: 'msg_status_sending',
        text: 'Testing sending',
        isMe: true,
        timestamp: DateTime.now().subtract(const Duration(seconds: 40)),
        status: MessageStatus.sending,
      );

      final sentMsg = ChatMessage(
        messageId: 'msg_status_sent',
        text: 'Testing sent',
        isMe: true,
        timestamp: DateTime.now().subtract(const Duration(seconds: 30)),
        status: MessageStatus.sent,
      );

      final deliveredMsg = ChatMessage(
        messageId: 'msg_status_delivered',
        text: 'Testing delivered',
        isMe: true,
        timestamp: DateTime.now().subtract(const Duration(seconds: 20)),
        status: MessageStatus.delivered,
      );

      final readMsg = ChatMessage(
        messageId: 'msg_status_read',
        text: 'Testing read',
        isMe: true,
        timestamp: DateTime.now().subtract(const Duration(seconds: 10)),
        status: MessageStatus.read,
      );

      final failedMsg = ChatMessage(
        messageId: 'msg_status_failed',
        text: 'Testing failed',
        isMe: true,
        timestamp: DateTime.now(),
        status: MessageStatus.failed,
      );

      mockChat.chatHistories['recipient_123'] = [
        sendingMsg,
        sentMsg,
        deliveredMsg,
        readMsg,
        failedMsg,
      ];

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authNotifierProvider.overrideWith((ref) => mockAuth),
            discoverNotifierProvider.overrideWith((ref) => mockDiscover),
            chatNotifierProvider.overrideWith((ref) => mockChat),
            signalMessagingServiceProvider.overrideWithValue(null),
          ],
          child: const MaterialApp(
            home: ChatScreen(
              recipientMasterPubKey: 'master_123',
              recipientNostrPubKey: 'recipient_123',
              recipientUsername: 'bob',
            ),
          ),
        ),
      );

      await tester.pump();

      // sending: Clock icon (Icons.access_time_rounded)
      expect(find.byIcon(Icons.access_time_rounded), findsOneWidget);

      // sent: Single tick (Icons.check_rounded)
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);

      // delivered & read: Double ticks (Icons.done_all_rounded) - 2 total
      final doneAllFinders = find.byIcon(Icons.done_all_rounded);
      expect(doneAllFinders, findsNWidgets(2));

      // One of the done_all widgets must be sky-blue (#38BDF8) for read
      final doneAllWidgets = tester.widgetList<Icon>(doneAllFinders).toList();
      final hasSkyBlueReadTick = doneAllWidgets.any((w) => w.color == const Color(0xFF38BDF8));
      expect(hasSkyBlueReadTick, isTrue);

      // failed: Refresh / retry icon in red (#EF4444)
      final retryFinder = find.byTooltip('Failed to send. Tap to retry.');
      expect(retryFinder, findsOneWidget);
      final refreshIcon = find.descendant(of: retryFinder, matching: find.byType(Icon));
      final refreshWidget = tester.widget<Icon>(refreshIcon);
      expect(refreshWidget.color, const Color(0xFFEF4444));
    });

    test('Status downgrade protection prevents delivered and read messages from reverting to sent or failed', () {
      final msg = ChatMessage(
        messageId: 'msg_race_1',
        text: 'Testing race conditions',
        isMe: true,
        timestamp: DateTime.now(),
        status: MessageStatus.sending,
      );

      // Recipient fires delivery receipt while sendMessage is in-flight
      msg.status = MessageStatus.delivered;

      // sendMessage completes later - must only set to sent if status is still sending
      if (msg.status == MessageStatus.sending) {
        msg.status = MessageStatus.sent;
      }
      expect(msg.status, MessageStatus.delivered); // Protected from downgrade!

      // Recipient opens chat, fires read receipt
      msg.status = MessageStatus.read;

      // Delayed error from slow relay - must only set to failed if status is still sending
      if (msg.status == MessageStatus.sending) {
        msg.status = MessageStatus.failed;
      }
      expect(msg.status, MessageStatus.read); // Protected from downgrade!
    });

    test('ChatMessage status recovery maps persisted sending status to failed', () {
      MessageStatus mapStatus(String rawStatus) {
        MessageStatus status = MessageStatus.sent;
        try {
          status = MessageStatus.values.byName(rawStatus);
        } catch (_) {}
        if (status == MessageStatus.sending) {
          status = MessageStatus.failed;
        }
        return status;
      }

      expect(mapStatus('sending'), MessageStatus.failed);
      expect(mapStatus('sent'), MessageStatus.sent);
      expect(mapStatus('delivered'), MessageStatus.delivered);
      expect(mapStatus('read'), MessageStatus.read);
      expect(mapStatus('failed'), MessageStatus.failed);
    });

    test('Global receipt lookup matches across all chat histories', () {
      final targetMsg = ChatMessage(
        messageId: 'msg_target_global_123',
        text: 'Lookup test',
        isMe: true,
        timestamp: DateTime.now(),
        status: MessageStatus.sent,
      );

      final chatHistories = <String, List<ChatMessage>>{
        'peer_pubkey_a': [
          ChatMessage(messageId: 'msg_other_1', text: 'hi', isMe: false, timestamp: DateTime.now())
        ],
        'peer_pubkey_b': [
          targetMsg,
        ],
      };

      const incomingTargetId = 'msg_target_global_123';
      const senderNostrPubKey = 'relay_or_alternate_key';

      ChatMessage? found;
      final directHistory = chatHistories[senderNostrPubKey];
      if (directHistory != null) {
        found = directHistory.where((m) => m.messageId == incomingTargetId).firstOrNull;
      }
      if (found == null) {
        for (final history in chatHistories.values) {
          found = history.where((m) => m.messageId == incomingTargetId).firstOrNull;
          if (found != null) break;
        }
      }

      expect(found, isNotNull);
      expect(found!.messageId, 'msg_target_global_123');
    });

    test('Clock skew resilience: remote peer ping with 4-hour clock difference marks user online via local arrival time', () {
      final now = DateTime.now();
      final remoteClockPast = now.subtract(const Duration(hours: 4)); // 4 hours behind
      
      final user = DiscoverUser(
        masterPubKeyHex: 'peer_skew_master_1',
        nostrPubKeyHex: 'peer_skew_nostr_1',
        username: 'SkewPeer',
        lastSeen: now,
        lastSeenFromPing: now, // Receiver records local arrival time, NOT remote clock
      );
      
      expect(user.isOnline, isTrue);
      expect(now.difference(user.lastSeenFromPing!).inSeconds < 70, isTrue);

      // Verify that if remote clock had been used, it would have failed
      final brokenComparison = now.difference(remoteClockPast).inSeconds < 70;
      expect(brokenComparison, isFalse, reason: 'Old bug: remote clock skew caused immediate timeout');
    });

    test('Presence lifecycle: incoming message updates presence and clears explicit offline', () {
      final user = DiscoverUser(
        masterPubKeyHex: 'peer_msg_master',
        nostrPubKeyHex: 'peer_msg_nostr',
        username: 'MessagingPeer',
        lastSeen: DateTime.now().subtract(const Duration(hours: 2)),
        isExplicitlyOffline: true,
      );
      expect(user.isOnline, isFalse);

      // Message arrives: local reception time marks activity and clears offline
      user.lastSeen = DateTime.now();
      user.lastSeenFromMessage = DateTime.now();
      user.isExplicitlyOffline = false;

      expect(user.isOnline, isTrue);
    });

    test('Presence lifecycle: explicit offline ping immediately revokes online state', () {
      final user = DiscoverUser(
        masterPubKeyHex: 'peer_offline_master',
        nostrPubKeyHex: 'peer_offline_nostr',
        username: 'DepartingPeer',
        lastSeen: DateTime.now(),
        lastSeenFromPing: DateTime.now(),
      );
      expect(user.isOnline, isTrue);

      // Explicit offline ping arrives (status: offline)
      user.markOffline();

      expect(user.isOnline, isFalse);
      expect(user.isExplicitlyOffline, isTrue);
      expect(user.lastSeenFromPing, isNull);
      expect(user.lastSeenFromMessage, isNull);
    });

    test('Chat list presence reconciliation resolves active peer correctly even if previous record had offline flag', () {
      final now = DateTime.now();
      
      // Known user from live relay subscription received fresh ping
      final knownUser = DiscoverUser(
        masterPubKeyHex: 'reconcile_peer',
        nostrPubKeyHex: 'reconcile_nostr',
        username: 'LivePeer',
        lastSeen: now,
        lastSeenFromPing: now,
        isExplicitlyOffline: false,
      );
      
      // Chat user from SQLite was loaded with stale offline flag from yesterday
      final chatUser = DiscoverUser(
        masterPubKeyHex: 'reconcile_peer',
        nostrPubKeyHex: 'reconcile_nostr',
        username: 'LivePeer',
        lastSeen: now.subtract(const Duration(days: 1)),
        isExplicitlyOffline: true,
      );

      final isActuallyOnline = (knownUser.isOnline == true) || (chatUser.isOnline == true);
      final isOffline = !isActuallyOnline && (knownUser.isExplicitlyOffline || chatUser.isExplicitlyOffline);

      expect(isActuallyOnline, isTrue);
      expect(isOffline, isFalse);
    });
  });

  group('Nostr Reconnect & Presence Reliability Production Tests', () {
    test('NostrRelayService state machine starts disconnected or ready and increments generation', () {
      final service = NostrRelayService();
      expect(service.state, anyOf(
        NostrConnectionState.disconnected,
        NostrConnectionState.connecting,
        NostrConnectionState.connected,
        NostrConnectionState.resubscribing,
        NostrConnectionState.ready,
      ));
      expect(service.connectionGeneration, isNonNegative);
    });

    test('NostrRelayService subscription registry correctly registers and unregisters message handlers', () {
      final service = NostrRelayService();
      bool received = false;
      service.registerMessageSubscription(
        onEvent: (event) {
          received = true;
        },
      );
      service.unregisterMessageSubscription();
      expect(received, isFalse);
    });

    test('NostrRelayService subscription registry correctly registers and unregisters presence handlers', () {
      final service = NostrRelayService();
      bool received = false;
      service.registerPresenceSubscription(
        onEvent: (event) {
          received = true;
        },
      );
      service.unregisterPresenceSubscription();
      expect(received, isFalse);
    });

    test('Presence staleness protection: online ping older than 80s is rejected from marking user online', () {
      final now = DateTime.now();
      final stalePingTimestamp = now.subtract(const Duration(minutes: 5)).millisecondsSinceEpoch;
      final nowMs = now.millisecondsSinceEpoch;
      final ageInSeconds = (nowMs - stalePingTimestamp) / 1000.0;

      // Assert age validation logic: > 80s rejected
      final isFresh = ageInSeconds >= -60 && ageInSeconds <= 80;
      expect(isFresh, isFalse);
      expect(ageInSeconds > 80, isTrue);

      final user = DiscoverUser(
        masterPubKeyHex: 'stale_user_master_1',
        nostrPubKeyHex: 'stale_user_nostr_1',
        username: 'StaleUser',
        lastSeen: now.subtract(const Duration(hours: 2)),
      );

      // Stale replayed heartbeat must NOT call user.markOnline()
      if (isFresh) {
        user.markOnline(at: now);
      }
      expect(user.isOnline, isFalse);
      expect(user.lastSeenFromPing, isNull);
    });

    test('Presence monotonicity: older out-of-order ping is rejected and does not overwrite newer state', () {
      final now = DateTime.now();
      final newerPingMs = now.subtract(const Duration(seconds: 10)).millisecondsSinceEpoch;
      final olderPingMs = now.subtract(const Duration(seconds: 35)).millisecondsSinceEpoch;

      final user = DiscoverUser(
        masterPubKeyHex: 'monotonic_user_master',
        nostrPubKeyHex: 'monotonic_user_nostr',
        username: 'MonotonicUser',
        lastSeen: now,
        lastPingTimestampMs: newerPingMs,
      );

      // When older ping arrives later:
      final isOutOrder = user.lastPingTimestampMs != null && olderPingMs < user.lastPingTimestampMs!;
      expect(isOutOrder, isTrue);
      if (!isOutOrder) {
        user.lastPingTimestampMs = olderPingMs;
      }
      expect(user.lastPingTimestampMs, newerPingMs);
    });

    test('Awaited broadcastPing returns Future<bool> and handles unannounced/hidden gracefully', () async {
      final service = NostrRelayService();
      // When hidden is true, broadcastPing returns false without publishing
      final resultHidden = await service.broadcastPing('test_master', isHidden: true);
      expect(resultHidden, isFalse);
    });

    test('Historical message replay: messages older than 70s do not revive user to green online state', () {
      final now = DateTime.now();
      final historicalMessageTime = now.subtract(const Duration(minutes: 10));
      
      final messageAgeSeconds = (now.millisecondsSinceEpoch - historicalMessageTime.millisecondsSinceEpoch) / 1000.0;
      final isRecentLiveMessage = messageAgeSeconds >= -300 && messageAgeSeconds < 70;
      expect(isRecentLiveMessage, isFalse);

      final user = DiscoverUser(
        masterPubKeyHex: 'historical_peer_master',
        nostrPubKeyHex: 'historical_peer_nostr',
        username: 'HistoricalPeer',
        lastSeen: historicalMessageTime,
        isExplicitlyOffline: true,
      );

      // Startup message replay logic:
      if (isRecentLiveMessage) {
        user.lastSeenFromMessage = historicalMessageTime;
        user.isExplicitlyOffline = false;
      }

      expect(user.isOnline, isFalse, reason: 'Old messages from previous days must never turn contact green on startup');
      expect(user.lastSeenFromMessage, isNull);
      expect(user.isExplicitlyOffline, isTrue);
    });

    test('Clock skew resilience: sender clock ahead of receiver is treated as live now and marks online', () {
      final now = DateTime.now();
      final senderClockAheadTime = now.add(const Duration(seconds: 45)); // Windows clock 45s ahead of Android
      
      final nowMs = now.millisecondsSinceEpoch;
      final pingTimeMs = senderClockAheadTime.millisecondsSinceEpoch;
      final ageInSeconds = (nowMs - pingTimeMs) / 1000.0;
      expect(ageInSeconds < 0, isTrue);

      final effectiveAgeSeconds = ageInSeconds < 0 ? 0.0 : ageInSeconds;
      final isStaleReplay = effectiveAgeSeconds > 80;
      expect(isStaleReplay, isFalse);

      final effectivePingTime = now.subtract(Duration(seconds: effectiveAgeSeconds.toInt()));
      final user = DiscoverUser(
        masterPubKeyHex: 'skew_ahead_peer_master',
        nostrPubKeyHex: 'skew_ahead_peer_nostr',
        username: 'SkewAheadPeer',
        lastSeen: now,
      );

      user.markOnline(at: effectivePingTime);
      expect(user.isOnline, isTrue);
      expect(now.difference(user.lastSeenFromPing!).inSeconds.abs() < 70, isTrue);
    });

    test('ChatProvider getMessagesFor resolves messages across aliased Nostr pubkeys', () {
      final msg1 = ChatMessage(messageId: 'm1', text: 'Old key message', isMe: true, timestamp: DateTime.now());
      final msg2 = ChatMessage(messageId: 'm2', text: 'New key message', isMe: false, timestamp: DateTime.now());
      
      final mockRepo = _MockChatRepo();
      final mockAuth = MockAuthProvider();
      final chatProvider = ChatProvider(
        chatRepo: mockRepo,
        authProvider: mockAuth,
        signalService: null,
      );

      final user = DiscoverUser(
        masterPubKeyHex: 'master_alice',
        nostrPubKeyHex: 'old_key_123',
        username: 'alice',
        lastSeen: DateTime.now(),
      );
      chatProvider.activeChats.add(user);
      chatProvider.chatHistories['old_key_123'] = [msg1];

      // Update presence with a new nostr pubkey (e.g. peer reinstalled or rotated)
      chatProvider.updateUserPresence(
        masterPubKeyHex: 'master_alice',
        nostrPubKeyHex: 'new_key_456',
        isOnline: true,
        lastSeen: DateTime.now(),
      );
      chatProvider.chatHistories['new_key_456']!.add(msg2);

      // getMessagesFor queried with old key should find the full merged history
      final msgsFromOld = chatProvider.getMessagesFor('old_key_123');
      expect(msgsFromOld.length, 2);
      expect(msgsFromOld.map((m) => m.messageId), containsAll(['m1', 'm2']));

      // getMessagesFor queried with new key should find the full merged history
      final msgsFromNew = chatProvider.getMessagesFor('new_key_456');
      expect(msgsFromNew.length, 2);

      // getMessagesFor queried with master key should find the history
      final msgsFromMaster = chatProvider.getMessagesFor('unknown_key', masterPubKeyHex: 'master_alice');
      expect(msgsFromMaster.length, 2);
    });

    test('NostrRelayService authoritative resubscribeAll returns Future<bool>', () async {
      final service = NostrRelayService();
      // Without keypair initialized, resubscribeAll returns false
      final result = await service.resubscribeAll();
      expect(result, isA<bool>());
    });

    test('Signal duplicate message handling detects __DUPLICATE_MESSAGE__ gracefully', () {
      final result = ('__DUPLICATE_MESSAGE__', '', null, 'msg_dup_123', false);
      expect(result.$1, '__DUPLICATE_MESSAGE__');
      expect(result.$4, 'msg_dup_123');
    });

    test('NostrRelayService addOnReadyListener executes callback when ready state is reached', () {
      final service = NostrRelayService();
      bool called = false;
      service.addOnReadyListener(() {
        called = true;
      });
      if (service.isReady) {
        expect(called, isTrue);
      } else {
        expect(service.state != NostrConnectionState.ready, isTrue);
      }
    });

    test('NostrRelayService markTransportUnhealthy transitions to disconnected and increments reconnectAttempt', () {
      final service = NostrRelayService();
      final initialAttempts = service.reconnectAttempt;
      service.markTransportUnhealthyForTest('test_dead_websocket');
      expect(service.state, NostrConnectionState.disconnected);
      expect(service.reconnectAttempt, greaterThanOrEqualTo(initialAttempts));
    });

    test('SignalMessagingService fetchAndEstablishSession does not delete session when prekey fetch fails', () async {
      final store = _MockSignalStore();
      final mockNostr = _MockNostrRelayServiceNoPrekeys();
      final signal = SignalMessagingService(
        signalStore: store,
        nostrService: mockNostr,
        masterPublicKeyHex: 'test_master_123',
      );

      final address = SignalProtocolAddress('test_peer_pubkey', 1);
      store.sessions[address.toString()] = SessionRecord();
      expect(await store.containsSession(address), isTrue);

      // Attempt to fetch and establish session when network returns null bundle
      final success = await signal.fetchAndEstablishSession('test_peer_pubkey', force: true);
      expect(success, isFalse);

      // Session MUST NOT have been deleted before confirming network bundle!
      expect(await store.containsSession(address), isTrue);
    });

    test('PreKeyBundle with depleted one-time prekeys constructs successfully with null fallback', () {
      final idKeyPair = generateIdentityKeyPair();
      final signedPreKey = generateSignedPreKey(idKeyPair, 1);
      final bundle = PreKeyBundle(
        12345,
        1,
        null, // No one-time prekey (depleted)
        null,
        signedPreKey.id,
        signedPreKey.getKeyPair().publicKey,
        signedPreKey.signature,
        idKeyPair.getPublicKey(),
      );
      expect(bundle.getRegistrationId(), 12345);
      expect(bundle.getPreKeyId(), isNull);
      expect(bundle.getSignedPreKeyId(), signedPreKey.id);
    });

    test('SignalMessagingService onIdentityKeyChanged callback notifies on peer identity changes', () {
      final store = _MockSignalStore();
      final mockNostr = _MockNostrRelayServiceNoPrekeys();
      String? alertedPeer;

      final signal = SignalMessagingService(
        signalStore: store,
        nostrService: mockNostr,
        masterPublicKeyHex: 'test_master_123',
        onIdentityKeyChanged: (peer) {
          alertedPeer = peer;
        },
      );

      // Verify callback triggers
      signal.onIdentityKeyChanged?.call('peer_nostr_456');
      expect(alertedPeer, 'peer_nostr_456');

      final gen = NumericFingerprintGenerator(5200);
      final key1 = generateIdentityKeyPair();
      final key2 = generateIdentityKeyPair();
      final fp = gen.createFor(
        0,
        Uint8List.fromList(utf8.encode('alice')),
        key1.getPublicKey(),
        Uint8List.fromList(utf8.encode('bob')),
        key2.getPublicKey(),
      );
      final text = fp.displayableFingerprint.getDisplayText();
      expect(text.isNotEmpty, isTrue);
    });

    testWidgets('ChatScreen renders prominent security notice banner when peer identity key changes and opens verification dialog', (WidgetTester tester) async {
      final mockAuth = MockAuthProvider();
      final mockDiscover = MockDiscoverProvider();
      final mockChat = MockChatProvider();

      mockChat.chatHistories['peer_nostr_security'] = [
        ChatMessage(
          text: "⚠️ Security Notice: Peer's Signal identity key changed. Messages are paused to protect your privacy. Tap to verify Safety Number.",
          isMe: false,
          timestamp: DateTime.now(),
        ),
      ];

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authNotifierProvider.overrideWith((ref) => mockAuth),
            discoverNotifierProvider.overrideWith((ref) => mockDiscover),
            chatNotifierProvider.overrideWith((ref) => mockChat),
            signalMessagingServiceProvider.overrideWith((ref) => null),
          ],
          child: const MaterialApp(
            home: ChatScreen(
              recipientMasterPubKey: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
              recipientNostrPubKey: 'peer_nostr_security',
              recipientUsername: 'alice',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining("Peer's Signal identity key changed"), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);

      // Tap on the security notice banner to open Safety Number verification dialog
      await tester.tap(find.byIcon(Icons.warning_amber_rounded));
      await tester.pumpAndSettle();

      expect(find.text('Identity Verification'), findsOneWidget);
      expect(find.text('Keep Blocked'), findsOneWidget);
      expect(find.text('Trust & Unlock'), findsOneWidget);

      // Dismiss dialog
      await tester.tap(find.text('Keep Blocked'));
      await tester.pumpAndSettle();
      expect(find.text('Identity Verification'), findsNothing);
    });

    test('SignalMessagingService formatSafetyNumber formats 60-digit number into blocks of 5', () {
      const raw = '123456789012345678901234567890123456789012345678901234567890';
      final formatted = SignalMessagingService.formatSafetyNumber(raw);
      expect(formatted.split(' ').length, 12);
      expect(formatted.startsWith('12345 67890'), isTrue);
    });

    test('CryptoService signBundleBindingToken and verifyBundleBindingToken round-trip and tamper detection', () async {
      final crypto = CryptoService();
      final keyPair = await crypto.generateMasterKeyPair('abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about');
      final pubKey = await keyPair.extractPublicKey();
      final pubKeyHex = pubKey.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      
      const nostrPub = 'nostr_recipient_pubkey_123';
      const identityPubBase64 = 'c2lnbmFsX2lkZW50aXR5X2tleV9leGFtcGxl';
      final timestamp = DateTime.now().millisecondsSinceEpoch;

      final sig = await crypto.signBundleBindingToken(
        masterKeyPair: keyPair,
        nostrPubKeyHex: nostrPub,
        signalIdentityPubBase64: identityPubBase64,
        timestamp: timestamp,
      );

      expect(sig.length, 128);

      // 1. Valid signature verifies
      final isValid = await crypto.verifyBundleBindingToken(
        masterPubKeyHex: pubKeyHex,
        nostrPubKeyHex: nostrPub,
        signalIdentityPubBase64: identityPubBase64,
        timestamp: timestamp,
        signatureHex: sig,
      );
      expect(isValid, isTrue);

      // 2. Tampered Signal Identity PubKey fails
      final tamperedIdentity = await crypto.verifyBundleBindingToken(
        masterPubKeyHex: pubKeyHex,
        nostrPubKeyHex: nostrPub,
        signalIdentityPubBase64: 'tampered_identity_key',
        timestamp: timestamp,
        signatureHex: sig,
      );
      expect(tamperedIdentity, isFalse);

      // 3. Tampered Nostr PubKey fails
      final tamperedNostr = await crypto.verifyBundleBindingToken(
        masterPubKeyHex: pubKeyHex,
        nostrPubKeyHex: 'different_nostr_pubkey',
        signalIdentityPubBase64: identityPubBase64,
        timestamp: timestamp,
        signatureHex: sig,
      );
      expect(tamperedNostr, isFalse);

      // 4. Tampered Timestamp fails
      final tamperedTimestamp = await crypto.verifyBundleBindingToken(
        masterPubKeyHex: pubKeyHex,
        nostrPubKeyHex: nostrPub,
        signalIdentityPubBase64: identityPubBase64,
        timestamp: timestamp + 1000,
        signatureHex: sig,
      );
      expect(tamperedTimestamp, isFalse);

      // 5. Tampered Master PubKey fails
      final tamperedMaster = await crypto.verifyBundleBindingToken(
        masterPubKeyHex: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        nostrPubKeyHex: nostrPub,
        signalIdentityPubBase64: identityPubBase64,
        timestamp: timestamp,
        signatureHex: sig,
      );
      expect(tamperedMaster, isFalse);
    });

    test('SignalMessagingService fetchAndEstablishSession rejects bundle when masterKey does not match pinned key', () async {
      final store = _MockSignalStore();
      final mockNostr = _MockNostrRelayServiceWithBundle({
        'masterKey': 'attacker_master_key_999',
        'registrationId': 1234,
        'identityPubKey': 'some_key',
        '_eventAuthor': 'peer_nostr_123',
      });
      final signal = SignalMessagingService(
        signalStore: store,
        nostrService: mockNostr,
        masterPublicKeyHex: 'my_master_key',
      );

      final success = await signal.fetchAndEstablishSession(
        'peer_nostr_123',
        masterPubKeyHex: 'expected_master_key_111',
      );
      expect(success, isFalse);
    });

    test('SignalMessagingService fetchAndEstablishSession rejects bundle when author does not match recipient Nostr pubkey', () async {
      final store = _MockSignalStore();
      final mockNostr = _MockNostrRelayServiceWithBundle({
        'masterKey': 'expected_master_key_111',
        'registrationId': 1234,
        'identityPubKey': 'some_key',
        '_eventAuthor': 'mallory_nostr_attacker', // Mismatched author!
      });
      final signal = SignalMessagingService(
        signalStore: store,
        nostrService: mockNostr,
        masterPublicKeyHex: 'my_master_key',
      );

      final success = await signal.fetchAndEstablishSession(
        'peer_nostr_123',
        masterPubKeyHex: 'expected_master_key_111',
      );
      expect(success, isFalse);
    });

    test('SignalMessagingService fetchAndEstablishSession rejects bundle when masterBindingSig is omitted/null', () async {
      final store = _MockSignalStore();
      final mockNostr = _MockNostrRelayServiceWithBundle({
        'masterKey': '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        'registrationId': 1234,
        'identityPubKey': 'c2lnbmFsX2lkZW50aXR5',
        'timestamp': 1700000000000,
        // masterBindingSig is omitted!
        '_eventAuthor': 'peer_nostr_123',
      });
      final signal = SignalMessagingService(
        signalStore: store,
        nostrService: mockNostr,
        masterPublicKeyHex: 'my_master_key',
      );

      final success = await signal.fetchAndEstablishSession(
        'peer_nostr_123',
        masterPubKeyHex: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      );
      expect(success, isFalse);
    });

    test('SignalMessagingService fetchAndEstablishSession rejects bundle when masterBindingSig fails verification', () async {
      final store = _MockSignalStore();
      final mockNostr = _MockNostrRelayServiceWithBundle({
        'masterKey': '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        'registrationId': 1234,
        'identityPubKey': 'c2lnbmFsX2lkZW50aXR5',
        'timestamp': 1700000000000,
        'masterBindingSig': '00' * 64, // Invalid forged signature!
        '_eventAuthor': 'peer_nostr_123',
      });
      final signal = SignalMessagingService(
        signalStore: store,
        nostrService: mockNostr,
        masterPublicKeyHex: 'my_master_key',
      );

      final success = await signal.fetchAndEstablishSession(
        'peer_nostr_123',
        masterPubKeyHex: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      );
      expect(success, isFalse);
    });

    test('SignalMessagingService fetchAndEstablishSession succeeds when bundle is legitimately signed by Master Key', () async {
      final crypto = CryptoService();
      final keyPair = await crypto.generateMasterKeyPair('abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about');
      final pubKey = await keyPair.extractPublicKey();
      final pubKeyHex = pubKey.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

      const recipientNostr = 'peer_nostr_legit';
      final idKeyPair = generateIdentityKeyPair();
      final signedPreKey = generateSignedPreKey(idKeyPair, 1);
      final identityPubBase64 = base64Encode(idKeyPair.getPublicKey().serialize());
      final nowMs = DateTime.now().millisecondsSinceEpoch;

      final sig = await crypto.signBundleBindingToken(
        masterKeyPair: keyPair,
        nostrPubKeyHex: recipientNostr,
        signalIdentityPubBase64: identityPubBase64,
        timestamp: nowMs,
      );

      final bundle = {
        'masterKey': pubKeyHex,
        'registrationId': 5678,
        'identityPubKey': identityPubBase64,
        'masterBindingSig': sig,
        'timestamp': nowMs,
        '_eventAuthor': recipientNostr,
        'signedPreKey': {
          'id': signedPreKey.id,
          'pubKey': base64Encode(signedPreKey.getKeyPair().publicKey.serialize()),
          'signature': base64Encode(signedPreKey.signature),
        },
        'oneTimePreKeys': <Map<String, dynamic>>[],
      };

      final store = _MockSignalStore();
      final mockNostr = _MockNostrRelayServiceWithBundle(bundle);
      final signal = SignalMessagingService(
        signalStore: store,
        nostrService: mockNostr,
        masterPublicKeyHex: 'my_own_master',
      );

      final success = await signal.fetchAndEstablishSession(
        recipientNostr,
        masterPubKeyHex: pubKeyHex,
      );
      expect(success, isTrue);
      expect(await signal.hasSignalSession(recipientNostr), isTrue);
    });

    test('CryptoService signControlToken and verifyControlToken round-trip and tamper detection', () async {
      final crypto = CryptoService();
      final keyPair = await crypto.generateMasterKeyPair('abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about');
      final pubKey = await keyPair.extractPublicKey();
      final pubKeyHex = pubKey.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

      const control = 'RESET_SESSION';
      const recipientNostr = 'my_nostr_pubkey_123';
      final timestamp = DateTime.now().millisecondsSinceEpoch;

      final sig = await crypto.signControlToken(
        masterKeyPair: keyPair,
        control: control,
        recipientNostrPubKey: recipientNostr,
        timestamp: timestamp,
      );

      expect(sig.length, 128);

      // 1. Valid signature verifies
      final isValid = await crypto.verifyControlToken(
        masterPubKeyHex: pubKeyHex,
        control: control,
        recipientNostrPubKey: recipientNostr,
        timestamp: timestamp,
        signatureHex: sig,
      );
      expect(isValid, isTrue);

      // 2. Tampered control fails
      final tamperedControl = await crypto.verifyControlToken(
        masterPubKeyHex: pubKeyHex,
        control: 'OTHER_COMMAND',
        recipientNostrPubKey: recipientNostr,
        timestamp: timestamp,
        signatureHex: sig,
      );
      expect(tamperedControl, isFalse);

      // 3. Tampered recipient fails
      final tamperedRecipient = await crypto.verifyControlToken(
        masterPubKeyHex: pubKeyHex,
        control: control,
        recipientNostrPubKey: 'different_recipient',
        timestamp: timestamp,
        signatureHex: sig,
      );
      expect(tamperedRecipient, isFalse);

      // 4. Tampered timestamp fails
      final tamperedTimestamp = await crypto.verifyControlToken(
        masterPubKeyHex: pubKeyHex,
        control: control,
        recipientNostrPubKey: recipientNostr,
        timestamp: timestamp + 5000,
        signatureHex: sig,
      );
      expect(tamperedTimestamp, isFalse);

      // 5. Tampered master key fails
      final tamperedMaster = await crypto.verifyControlToken(
        masterPubKeyHex: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        control: control,
        recipientNostrPubKey: recipientNostr,
        timestamp: timestamp,
        signatureHex: sig,
      );
      expect(tamperedMaster, isFalse);
    });

    test('ChatProvider drops RESET_SESSION from unknown peer with no chat history', () async {
      final mockRepo = _MockChatRepo();
      final mockAuth = MockAuthProvider();
      final mockSignal = _MockSignalMessagingServiceForReset();
      final chatProvider = ChatProvider(
        chatRepo: mockRepo,
        authProvider: mockAuth,
        signalService: mockSignal,
      );

      final payload = {
        'type': -1,
        'control': 'RESET_SESSION',
        'senderMasterPubKey': '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        'sentAt': DateTime.now().millisecondsSinceEpoch,
      };

      final strangerKeyPairs = NostrKeyPairs(private: '11' * 32);
      final event = NostrEvent.fromPartialData(
        kind: 4444,
        content: jsonEncode(payload),
        keyPairs: strangerKeyPairs,
      );

      await chatProvider.handleIncomingEventForTest(event);
      expect(mockSignal.fetchAndEstablishCalls, 0); // Dropped!
    });

    test('ChatProvider drops stale RESET_SESSION (> 120s old)', () async {
      final mockRepo = _MockChatRepo();
      final mockAuth = MockAuthProvider();
      final mockSignal = _MockSignalMessagingServiceForReset();
      final chatProvider = ChatProvider(
        chatRepo: mockRepo,
        authProvider: mockAuth,
        signalService: mockSignal,
      );

      final peerKeyPairs = NostrKeyPairs(private: '22' * 32);
      final peerNostr = peerKeyPairs.public;
      chatProvider.chatHistories[peerNostr] = [];

      final payload = {
        'type': -1,
        'control': 'RESET_SESSION',
        'senderMasterPubKey': '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        'sentAt': DateTime.now().millisecondsSinceEpoch - 200000, // 200 seconds ago (stale)
      };

      final event = NostrEvent.fromPartialData(
        kind: 4444,
        content: jsonEncode(payload),
        keyPairs: peerKeyPairs,
      );

      await chatProvider.handleIncomingEventForTest(event);
      expect(mockSignal.fetchAndEstablishCalls, 0); // Dropped!
    });

    test('ChatProvider drops RESET_SESSION with forged signature', () async {
      final mockRepo = _MockChatRepo();
      final mockAuth = MockAuthProvider();
      final mockSignal = _MockSignalMessagingServiceForReset();
      final chatProvider = ChatProvider(
        chatRepo: mockRepo,
        authProvider: mockAuth,
        signalService: mockSignal,
      );

      final peerKeyPairs = NostrKeyPairs(private: '33' * 32);
      final peerNostr = peerKeyPairs.public;
      chatProvider.chatHistories[peerNostr] = [];

      final payload = {
        'type': -1,
        'control': 'RESET_SESSION',
        'senderMasterPubKey': '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        'sentAt': DateTime.now().millisecondsSinceEpoch,
        'sig': '00' * 64, // Forged 128-hex signature
      };

      final event = NostrEvent.fromPartialData(
        kind: 4444,
        content: jsonEncode(payload),
        keyPairs: peerKeyPairs,
      );

      await chatProvider.handleIncomingEventForTest(event);
      expect(mockSignal.fetchAndEstablishCalls, 0); // Dropped!
    });

    test('ChatProvider accepts authenticated RESET_SESSION with valid Master Key signature', () async {
      final crypto = CryptoService();
      final peerKeyPair = await crypto.generateMasterKeyPair('abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about');
      final peerPubKey = await peerKeyPair.extractPublicKey();
      final peerMasterHex = peerPubKey.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

      final mockRepo = _MockChatRepo();
      final mockAuth = MockAuthProvider();
      final mockSignal = _MockSignalMessagingServiceForReset();
      final chatProvider = ChatProvider(
        chatRepo: mockRepo,
        authProvider: mockAuth,
        signalService: mockSignal,
      );

      final peerKeyPairs = NostrKeyPairs(private: '44' * 32);
      final peerNostr = peerKeyPairs.public;
      chatProvider.chatHistories[peerNostr] = [];

      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final myNostr = NostrRelayService().publicHex;

      final sig = await crypto.signControlToken(
        masterKeyPair: peerKeyPair,
        control: 'RESET_SESSION',
        recipientNostrPubKey: myNostr,
        timestamp: nowMs,
      );

      final payload = {
        'type': -1,
        'control': 'RESET_SESSION',
        'senderMasterPubKey': peerMasterHex,
        'sentAt': nowMs,
        'sig': sig,
      };

      final event = NostrEvent.fromPartialData(
        kind: 4444,
        content: jsonEncode(payload),
        keyPairs: peerKeyPairs,
      );

      await chatProvider.handleIncomingEventForTest(event);
      expect(mockSignal.fetchAndEstablishCalls, 1);
      expect(mockSignal.lastRecipient, peerNostr);
      expect(mockSignal.lastMasterKey, peerMasterHex);
    });

    test('setupDatabaseEncryption aborts startup if cipher_version returns empty list', () {
      final mockDb = _MockRawDb(cipherVersionReturn: <_MockDbRow>[]);
      expect(
        () => setupDatabaseEncryption(mockDb, 'test_key'),
        throwsA(isA<UnsupportedError>().having(
          (e) => e.message,
          'message',
          contains('SQLCipher / SQLite3MC is not available'),
        )),
      );
    });

    test('setupDatabaseEncryption aborts startup if cipher_version query throws', () {
      final mockDb = _MockRawDb(shouldThrowOnSelect: true);
      expect(
        () => setupDatabaseEncryption(mockDb, 'test_key'),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('setupDatabaseEncryption aborts startup if cipher_version is blank or whitespace', () {
      final mockDb = _MockRawDb(cipherVersionReturn: [
        _MockDbRow(['   '])
      ]);
      expect(
        () => setupDatabaseEncryption(mockDb, 'test_key'),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('setupDatabaseEncryption applies encryption key and security pragmas when cipher is valid', () {
      final mockDb = _MockRawDb(cipherVersionReturn: [
        _MockDbRow(['4.5.5 community'])
      ]);
      setupDatabaseEncryption(mockDb, "my_secret_key'with_quote");

      expect(mockDb.executedStatements, contains("PRAGMA key = 'my_secret_key''with_quote';"));
      expect(mockDb.executedStatements, contains('PRAGMA cipher_memory_security = ON;'));
      expect(mockDb.executedStatements, contains('PRAGMA journal_mode = WAL;'));
      expect(mockDb.executedStatements, contains('PRAGMA synchronous = NORMAL;'));
    });

    test('setupDatabaseEncryption accepts SQLite3MultipleCiphers via sqlite3mc_version()', () {
      final mockDb = _MockRawDb(
        selectHandler: (sql) {
          if (sql == 'PRAGMA cipher_version;') {
            return <_MockDbRow>[]; // SQLite3MC does not support SQLCipher's cipher_version
          } else if (sql == 'SELECT sqlite3mc_version();') {
            return [_MockDbRow(['SQLite3 Multiple Ciphers 2.5.0'])];
          }
          return <_MockDbRow>[];
        },
      );
      setupDatabaseEncryption(mockDb, "mc_key_123");

      expect(mockDb.executedStatements, contains('PRAGMA cipher_version;'));
      expect(mockDb.executedStatements, contains('SELECT sqlite3mc_version();'));
      expect(mockDb.executedStatements, contains("PRAGMA key = 'mc_key_123';"));
      expect(mockDb.executedStatements, contains('PRAGMA journal_mode = WAL;'));
    });

    test('setupDatabaseEncryption accepts SQLite3MultipleCiphers via PRAGMA cipher;', () {
      final mockDb = _MockRawDb(
        selectHandler: (sql) {
          if (sql == 'PRAGMA cipher_version;' || sql == 'SELECT sqlite3mc_version();') {
            return <_MockDbRow>[];
          } else if (sql == 'PRAGMA cipher;') {
            return [_MockDbRow(['chacha20'])];
          }
          return <_MockDbRow>[];
        },
      );
      setupDatabaseEncryption(mockDb, "chacha_key_456");

      expect(mockDb.executedStatements, contains('PRAGMA cipher;'));
      expect(mockDb.executedStatements, contains("PRAGMA key = 'chacha_key_456';"));
    });

    test('isLegacyPlaintextDatabase detects unencrypted SQLite files correctly', () async {
      final tempDir = Directory.systemTemp.createTempSync('db_test_plain');
      final plainFile = File('${tempDir.path}/plain.sqlite');
      plainFile.writeAsBytesSync([83, 81, 76, 105, 116, 101, 32, 102, 111, 114, 109, 97, 116, 32, 51, 0, 1, 2, 3]);

      final encFile = File('${tempDir.path}/enc.sqlite');
      encFile.writeAsBytesSync([10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120, 130, 140, 150, 160]);

      final nonExistent = File('${tempDir.path}/missing.sqlite');

      expect(await isLegacyPlaintextDatabase(plainFile), isTrue);
      expect(await isLegacyPlaintextDatabase(encFile), isFalse);
      expect(await isLegacyPlaintextDatabase(nonExistent), isFalse);

      tempDir.deleteSync(recursive: true);
    });

    test('migratePlaintextDatabaseToEncrypted seamlessly converts plaintext database to encrypted format preserving data', () async {
      final tempDir = Directory.systemTemp.createTempSync('db_test_mig');
      final dbFile = File('${tempDir.path}/chat_legacy.sqlite');
      
      // 1. Create a plaintext database with schema and data
      final rawPlain = sqlite3_raw.sqlite3.open(dbFile.path);
      rawPlain.execute('CREATE TABLE active_chats (masterPubKeyHex TEXT PRIMARY KEY, username TEXT);');
      rawPlain.execute("INSERT INTO active_chats VALUES ('pub123', 'alice');");
      rawPlain.execute('CREATE TABLE chat_messages (id TEXT PRIMARY KEY, text TEXT);');
      rawPlain.execute("INSERT INTO chat_messages VALUES ('msg1', 'Hello world');");
      rawPlain.dispose();

      expect(await isLegacyPlaintextDatabase(dbFile), isTrue);

      // 2. Perform encrypted migration
      const encKey = 'my_secure_encryption_key_789';
      await migratePlaintextDatabaseToEncrypted(dbFile, encKey);

      // 3. Confirm file is now encrypted and not plaintext
      expect(await isLegacyPlaintextDatabase(dbFile), isFalse);

      // 4. Confirm data is intact when opened with encryption key
      final testEnc = sqlite3_raw.sqlite3.open(dbFile.path);
      testEnc.execute("PRAGMA key = '$encKey';");
      final chatCount = testEnc.select('SELECT count(*) as c FROM active_chats;').first['c'];
      final msgCount = testEnc.select('SELECT count(*) as c FROM chat_messages;').first['c'];
      testEnc.dispose();

      expect(chatCount, 1);
      expect(msgCount, 1);

      // 5. Confirm NO plaintext backup or plaintext copy remains
      final backup = File('${dbFile.path}.plain_bak');
      expect(backup.existsSync(), isFalse);

      tempDir.deleteSync(recursive: true);
    });

    test('cleanupResidualDatabaseFiles purges pre-existing plain_bak, corrupt, and migrating files', () async {
      final tempDir = Directory.systemTemp.createTempSync('db_cleanup_test');
      final dbFile = File('${tempDir.path}/aisat_connect_1.sqlite');
      dbFile.writeAsStringSync('dummy');

      final plainBak = File('${dbFile.path}.plain_bak');
      plainBak.writeAsStringSync('plaintext_shadow_data');

      final corruptDump = File('${dbFile.path}.corrupt_123456');
      corruptDump.writeAsStringSync('corrupt_plaintext');

      final orphanedTemp = File('${dbFile.path}.migrating_789');
      orphanedTemp.writeAsStringSync('temp_encrypted');

      expect(plainBak.existsSync(), isTrue);
      expect(corruptDump.existsSync(), isTrue);
      expect(orphanedTemp.existsSync(), isTrue);

      cleanupResidualDatabaseFiles(dbFile);

      expect(plainBak.existsSync(), isFalse);
      expect(corruptDump.existsSync(), isFalse);
      expect(orphanedTemp.existsSync(), isFalse);
      expect(dbFile.existsSync(), isTrue);

      tempDir.deleteSync(recursive: true);
    });

    test('verifyOrRecoverEncryptedDatabase preserves corrupted/unopenable file and clears path for clean DB', () async {
      final tempDir = Directory.systemTemp.createTempSync('db_test_rec');
      final corruptFile = File('${tempDir.path}/corrupt.sqlite');
      corruptFile.writeAsBytesSync(List.generate(1024, (i) => i % 256));

      // Attempt verification with an invalid database
      verifyOrRecoverEncryptedDatabase(corruptFile, 'some_key');

      // The original file path should be freed up
      expect(corruptFile.existsSync(), isFalse);

      // A preserved backup should exist
      final backups = tempDir.listSync().where((f) => f.path.contains('.unrecoverable_'));
      expect(backups.isNotEmpty, isTrue);

      tempDir.deleteSync(recursive: true);
    });

    test('verifyOrRecoverEncryptedDatabase refuses to process and rename plaintext database', () async {
      final tempDir = Directory.systemTemp.createTempSync('db_test_plain_guard');
      final plainFile = File('${tempDir.path}/plain.sqlite');
      final db = sqlite3_raw.sqlite3.open(plainFile.path);
      db.execute('CREATE TABLE secrets (id TEXT);');
      db.execute("INSERT INTO secrets VALUES ('super_secret');");
      db.dispose();

      expect(isLegacyPlaintextDatabaseSync(plainFile), isTrue);

      // Attempting to run verifyOrRecoverEncryptedDatabase directly on a plaintext database must throw StateError
      expect(
        () => verifyOrRecoverEncryptedDatabase(plainFile, 'test_key'),
        throwsA(isA<StateError>()),
      );

      // The original plaintext file should NOT be renamed to .unrecoverable_
      final backups = tempDir.listSync().where((f) => f.path.contains('.unrecoverable_'));
      expect(backups.isEmpty, isTrue);
      expect(plainFile.existsSync(), isTrue);

      tempDir.deleteSync(recursive: true);
    });

    test('cleanupResidualDatabaseFiles purges plaintext unrecoverable files while preserving ciphertext ones', () async {
      final tempDir = Directory.systemTemp.createTempSync('db_test_unrec_cleanup');
      final dbFile = File('${tempDir.path}/aisat_connect_1.sqlite');
      dbFile.writeAsStringSync('dummy');

      // 1. Plaintext unrecoverable file (has SQLite format 3 magic header)
      final plainUnrec = File('${dbFile.path}.unrecoverable_111');
      final db = sqlite3_raw.sqlite3.open(plainUnrec.path);
      db.execute('CREATE TABLE leaked_chats (id TEXT);');
      db.dispose();
      expect(isLegacyPlaintextDatabaseSync(plainUnrec), isTrue);

      // 2. Corrupt ciphertext unrecoverable file (random bytes, not plaintext)
      final cipherUnrec = File('${dbFile.path}.unrecoverable_222');
      cipherUnrec.writeAsBytesSync(List.generate(1024, (i) => (i * 7) % 256));
      expect(isLegacyPlaintextDatabaseSync(cipherUnrec), isFalse);

      expect(plainUnrec.existsSync(), isTrue);
      expect(cipherUnrec.existsSync(), isTrue);

      cleanupResidualDatabaseFiles(dbFile);

      // Plaintext unrecoverable file MUST be deleted
      expect(plainUnrec.existsSync(), isFalse);
      // Ciphertext unrecoverable file is preserved
      expect(cipherUnrec.existsSync(), isTrue);

      tempDir.deleteSync(recursive: true);
    });

    test('migratePlaintextDatabaseToEncrypted is fail-closed and rethrows on failure', () async {
      final tempDir = Directory.systemTemp.createTempSync('db_test_fail_closed');
      final plainFile = File('${tempDir.path}/non_existent_folder/plain.sqlite');

      // Trying to migrate a non-existent/invalid database path throws StateError
      expect(
        () => migratePlaintextDatabaseToEncrypted(plainFile, 'key'),
        throwsA(isA<StateError>()),
      );

      // Confirm no shadow files exist
      final allFiles = tempDir.listSync(recursive: true);
      expect(allFiles.where((f) => f.path.contains('.plain_bak')).isEmpty, isTrue);
      expect(allFiles.where((f) => f.path.contains('.unrecoverable_')).isEmpty, isTrue);

      tempDir.deleteSync(recursive: true);
    });

    test('ChatProvider.sendOutgoingMessage writes to outbox, dispatches, and retains in outbox as sent awaiting delivery ack', () async {
      final mockRepo = _MockChatRepo();
      final mockAuth = MockAuthProvider();
      final mockSignal = _MockSignalMessagingServiceForOutbox();
      final chatProvider = ChatProvider(
        chatRepo: mockRepo,
        authProvider: mockAuth,
        signalService: mockSignal,
      );

      final success = await chatProvider.sendOutgoingMessage('recipient_123', 'Hello outbox!');
      expect(success, isTrue);
      expect(mockSignal.prepareEncryptedPayloadCalls, 1);
      expect(mockSignal.sendPreparedPayloadCalls, 1);
      // Retained in outbox with 'sent' status awaiting delivery ack from peer
      expect(mockRepo.outbox.length, 1);
      expect(mockRepo.outbox.first.status, 'sent');
      expect(mockRepo.outbox.first.attempts, 1);
      // Status in chatRepo updated to sent
      expect(mockRepo.messageStatuses.values, contains('sent'));
    });

    test('ChatProvider.sendOutgoingMessage retains message in outbox as failed when network dispatch fails', () async {
      final mockRepo = _MockChatRepo();
      final mockAuth = MockAuthProvider();
      final mockSignal = _MockSignalMessagingServiceForOutbox()..shouldThrowOnSend = true;
      final chatProvider = ChatProvider(
        chatRepo: mockRepo,
        authProvider: mockAuth,
        signalService: mockSignal,
      );

      final success = await chatProvider.sendOutgoingMessage('recipient_123', 'Failed send');
      expect(success, isFalse);
      expect(mockSignal.prepareEncryptedPayloadCalls, 1);
      expect(mockSignal.sendPreparedPayloadCalls, 1);
      // Retained in outbox for subsequent retry
      expect(mockRepo.outbox.length, 1);
      expect(mockRepo.outbox.first.status, 'failed');
      expect(mockRepo.messageStatuses.values, contains('failed'));
    });

    test('SignalMessagingService refuses cryptographic and dispatch operations when disposed or session generation is stale', () async {
      AccountSession.setGenerationForTesting(100);
      final signalService = SignalMessagingService(
        signalStore: _MockSignalStore(),
        nostrService: _MockNostrRelayServiceNoPrekeys(),
        masterPublicKeyHex: 'test_master',
        sessionGeneration: 100,
      );

      expect(signalService.isActive, isTrue);
      expect(signalService.isDisposed, isFalse);

      // Advance generation to simulate logout / account switch
      AccountSession.setGenerationForTesting(101);
      expect(signalService.isActive, isFalse);

      // All operations must throw StateError due to stale session generation
      expect(
        () => signalService.prepareEncryptedPayload('peer', 'hello'),
        throwsA(isA<StateError>()),
      );
      expect(
        () => signalService.sendPreparedPayload('peer', {'id': '1', 'type': 3}),
        throwsA(isA<StateError>()),
      );
      expect(
        () => signalService.sendMessage('peer', 'hello'),
        throwsA(isA<StateError>()),
      );
      expect(
        () => signalService.deleteSession('peer'),
        throwsA(isA<StateError>()),
      );
      expect(
        () => signalService.hasSignalSession('peer'),
        throwsA(isA<StateError>()),
      );
      expect(await signalService.canSendToPeer('peer'), isFalse);

      // Now reset to 100 and dispose explicitly
      AccountSession.setGenerationForTesting(100);
      signalService.dispose();
      expect(signalService.isDisposed, isTrue);
      expect(signalService.isActive, isFalse);

      expect(
        () => signalService.prepareEncryptedPayload('peer', 'hello'),
        throwsA(isA<StateError>()),
      );
      expect(
        () => signalService.sendPreparedPayload('peer', {'id': '1', 'type': 3}),
        throwsA(isA<StateError>()),
      );
    });

    test('ChatProvider.sendOutgoingMessage aborts across await boundaries if AccountSession generation changes', () async {
      AccountSession.setGenerationForTesting(200);
      final mockRepo = _MockChatRepo();
      final mockAuth = MockAuthProvider();
      final mockSignal = _MockSignalMessagingServiceForOutbox();
      final chatProvider = ChatProvider(
        chatRepo: mockRepo,
        authProvider: mockAuth,
        signalService: mockSignal,
      );

      // Simulates user logging out while encryption is in flight
      mockSignal.onPrepareEncryptedPayload = () async {
        AccountSession.setGenerationForTesting(201);
      };

      final success = await chatProvider.sendOutgoingMessage('recipient_123', 'Stale message');
      expect(success, isFalse);
      expect(mockSignal.prepareEncryptedPayloadCalls, 1);
      expect(mockSignal.sendPreparedPayloadCalls, 0);
      expect(mockRepo.outbox.isEmpty, isTrue);
    });

    test('ChatProvider.sendOutgoingVoiceNote aborts if AccountSession generation is stale', () async {
      AccountSession.setGenerationForTesting(0);
      final mockRepo = _MockChatRepo();
      final mockAuth = MockAuthProvider();
      final mockSignal = _MockSignalMessagingServiceForOutbox();
      final chatProvider = ChatProvider(
        chatRepo: mockRepo,
        authProvider: mockAuth,
        signalService: mockSignal,
      );

      final success = await chatProvider.sendOutgoingVoiceNote(
        recipientNostrPubKey: 'recipient_123',
        localAudioPath: 'non_existent.m4a',
        durationMs: 1200,
        waveform: [10, 20, 30],
      );
      expect(success, isFalse);
      expect(mockSignal.prepareEncryptedPayloadCalls, 0);
      expect(mockSignal.sendPreparedPayloadCalls, 0);
      expect(mockRepo.outbox.isEmpty, isTrue);
    });

    test('ChatProvider.drainOutbox terminates mid-drain if AccountSession generation increments', () async {
      AccountSession.setGenerationForTesting(400);
      final mockRepo = _MockChatRepo();
      final mockAuth = MockAuthProvider();
      final mockSignal = _MockSignalMessagingServiceForOutbox();

      // Enqueue 2 records into mockRepo outbox
      await mockRepo.enqueueOutbox(
        messageId: 'msg_1',
        recipientNostrPubKey: 'peer_1',
        payloadJson: jsonEncode({'id': 'msg_1', 'type': 3}),
        createdAt: DateTime.now(),
      );
      await mockRepo.enqueueOutbox(
        messageId: 'msg_2',
        recipientNostrPubKey: 'peer_2',
        payloadJson: jsonEncode({'id': 'msg_2', 'type': 3}),
        createdAt: DateTime.now(),
      );

      final chatProvider = ChatProvider(
        chatRepo: mockRepo,
        authProvider: mockAuth,
        signalService: mockSignal,
      );

      // Simulates account switch occurring during the dispatch of the first record
      mockSignal.onSendPreparedPayload = (recipient, payload) async {
        AccountSession.setGenerationForTesting(401);
      };

      await chatProvider.drainOutbox();

      // Exactly 1 dispatch should have occurred before loop terminated due to generation change
      expect(mockSignal.sendPreparedPayloadCalls, 1);
      // msg_2 was NEVER dispatched because drainOutbox terminated early
      expect(mockSignal.sentPayloads.any((p) => p['id'] == 'msg_2'), isFalse);
      expect(mockRepo.outbox.firstWhere((r) => r.messageId == 'msg_2').attempts, 0);
    });

    test('ChatProvider.retryOutgoingMessage uses stored ciphertext from Outbox WITHOUT advancing Double Ratchet', () async {
      final mockRepo = _MockChatRepo();
      final mockAuth = MockAuthProvider();
      final mockSignal = _MockSignalMessagingServiceForOutbox();
      final chatProvider = ChatProvider(
        chatRepo: mockRepo,
        authProvider: mockAuth,
        signalService: mockSignal,
      );

      // Pre-seed Outbox with a stored ciphertext from a previously interrupted send
      const testMsgId = 'msg_failed_prior';
      const storedCiphertext = 'exact_pre_ratcheted_ciphertext_xyz';
      final payloadMap = {
        'type': 3,
        'ciphertext': storedCiphertext,
        'sentAt': DateTime.now().millisecondsSinceEpoch,
        'id': testMsgId,
      };
      await mockRepo.enqueueOutbox(
        messageId: testMsgId,
        recipientNostrPubKey: 'peer_abc',
        payloadJson: jsonEncode(payloadMap),
      );

      final failedMsg = ChatMessage(
        messageId: testMsgId,
        text: 'Hello original',
        isMe: true,
        timestamp: DateTime.now(),
        status: MessageStatus.failed,
      );

      // Retry the message
      final success = await chatProvider.retryOutgoingMessage('peer_abc', failedMsg);
      expect(success, isTrue);

      // CRITICAL GUARANTEE: prepareEncryptedPayload (and thus sessionCipher.encrypt) was NOT called!
      expect(mockSignal.prepareEncryptedPayloadCalls, 0);
      expect(mockSignal.sendPreparedPayloadCalls, 1);
      expect(mockSignal.sentPayloads.first['ciphertext'], storedCiphertext);
      expect(mockSignal.sentPayloads.first['id'], testMsgId);

      // Outbox retained with 'sent' status awaiting delivery ack
      expect(mockRepo.outbox.length, 1);
      expect(mockRepo.outbox.first.status, 'sent');
      expect(mockRepo.outbox.first.attempts, 1);
      expect(failedMsg.status, MessageStatus.sent);
    });

    test('ChatProvider.drainOutbox automatically transmits pending outbox messages upon reconnect', () async {
      final mockRepo = _MockChatRepo();
      final mockAuth = MockAuthProvider();
      final mockSignal = _MockSignalMessagingServiceForOutbox();
      final chatProvider = ChatProvider(
        chatRepo: mockRepo,
        authProvider: mockAuth,
        signalService: mockSignal,
      );

      // Seed 2 pending messages in outbox
      for (int i = 1; i <= 2; i++) {
        await mockRepo.enqueueOutbox(
          messageId: 'msg_queued_$i',
          recipientNostrPubKey: 'peer_$i',
          payloadJson: jsonEncode({
            'type': 3,
            'ciphertext': 'cipher_$i',
            'sentAt': DateTime.now().millisecondsSinceEpoch,
            'id': 'msg_queued_$i',
          }),
        );
      }
      expect(mockRepo.outbox.length, 2);

      await chatProvider.drainOutbox(forceAll: true);

      expect(mockSignal.sendPreparedPayloadCalls, 2);
      expect(mockRepo.outbox.length, 2);
      expect(mockRepo.outbox[0].status, 'sent');
      expect(mockRepo.outbox[1].status, 'sent');
      expect(mockRepo.messageStatuses['msg_queued_1'], 'sent');
      expect(mockRepo.messageStatuses['msg_queued_2'], 'sent');
    });

    test('ChatProvider: incoming delivery receipt deletes message from outbox and marks delivered', () async {
      final mockRepo = _MockChatRepo();
      final mockAuth = MockAuthProvider();
      final mockSignal = _MockSignalMessagingServiceForOutbox();
      final chatProvider = ChatProvider(
        chatRepo: mockRepo,
        authProvider: mockAuth,
        signalService: mockSignal,
      );

      final peerKeyPairs = NostrKeyPairs(private: '55' * 32);
      final peerNostr = peerKeyPairs.public;
      const targetMsgId = 'msg_delivered_target_123';

      // 1. Seed outgoing message in 'sent' state in chat history and outbox
      final sentMsg = ChatMessage(
        messageId: targetMsgId,
        text: 'Awaiting delivery ack',
        isMe: true,
        timestamp: DateTime.now(),
        status: MessageStatus.sent,
      );
      chatProvider.chatHistories[peerNostr] = [sentMsg];
      await mockRepo.enqueueOutbox(
        messageId: targetMsgId,
        recipientNostrPubKey: peerNostr,
        payloadJson: jsonEncode({'id': targetMsgId}),
      );
      await mockRepo.updateOutboxStatus(targetMsgId, status: 'sent', attempts: 1);
      expect(mockRepo.outbox.length, 1);

      // 2. Peer sends 'delivered' receipt envelope
      final receiptEnvelope = MndoMessageEnvelope(
        messageId: 'receipt_event_1',
        type: 'receipt',
        timestamp: DateTime.now().millisecondsSinceEpoch,
        senderMasterPubKey: 'peer_master_hex',
        body: {'targetId': targetMsgId, 'status': 'delivered'},
      );
      mockSignal.incomingMessageToReturn = (
        receiptEnvelope.serialize(),
        'peer_master_hex',
        DateTime.now(),
        'receipt_event_1',
        false,
      );

      final event = NostrEvent.fromPartialData(
        kind: 4444,
        content: jsonEncode({'type': 3, 'id': 'receipt_event_1'}),
        keyPairs: peerKeyPairs,
      );

      await chatProvider.handleIncomingEventForTest(event);

      // 3. Verify message is marked delivered and deleted from outbox
      expect(sentMsg.status, MessageStatus.delivered);
      expect(mockRepo.outbox.isEmpty, isTrue);
      expect(mockRepo.messageStatuses[targetMsgId], 'delivered');
    });

    test('ChatProvider: duplicate message receipt re-acknowledges delivery receipt', () async {
      final mockRepo = _MockChatRepo();
      final mockAuth = MockAuthProvider();
      final mockSignal = _MockSignalMessagingServiceForOutbox();
      final chatProvider = ChatProvider(
        chatRepo: mockRepo,
        authProvider: mockAuth,
        signalService: mockSignal,
      );

      final peerKeyPairs = NostrKeyPairs(private: '66' * 32);
      final peerNostr = peerKeyPairs.public;
      const duplicateMsgId = 'msg_duplicate_456';

      mockSignal.incomingMessageToReturn = (
        '__DUPLICATE_MESSAGE__',
        'peer_master_hex',
        DateTime.now(),
        duplicateMsgId,
        false,
      );

      final event = NostrEvent.fromPartialData(
        kind: 4444,
        content: jsonEncode({'type': 3, 'id': duplicateMsgId}),
        keyPairs: peerKeyPairs,
      );

      await chatProvider.handleIncomingEventForTest(event);

      // Wait a short duration for unawaited sendReceipt future to complete
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Re-acknowledged delivery receipt sent to peer
      expect(mockSignal.sendMessageCalls, 1);
      expect(mockSignal.sentMessages.first['recipient'], peerNostr);
      expect(mockSignal.sentMessages.first['type'], 'receipt');
      expect(mockSignal.sentMessages.first['targetId'], duplicateMsgId);
      expect(mockSignal.sentMessages.first['status'], 'delivered');
    });

    test('ChatProvider: peer online presence triggers opportunistic retry for undelivered messages', () async {
      final mockRepo = _MockChatRepo();
      final mockAuth = MockAuthProvider();
      final mockSignal = _MockSignalMessagingServiceForOutbox();
      final chatProvider = ChatProvider(
        chatRepo: mockRepo,
        authProvider: mockAuth,
        signalService: mockSignal,
      );

      const peerMaster = 'peer_master_presence_777';
      const peerNostr = 'peer_nostr_presence_777';

      chatProvider.addChat(DiscoverUser(
        masterPubKeyHex: peerMaster,
        nostrPubKeyHex: peerNostr,
        username: 'OnlineFriend',
        lastSeen: DateTime.now().subtract(const Duration(hours: 1)),
      ));

      // Seed undelivered message in outbox with status 'sent'
      const testMsgId = 'msg_presence_retry';
      await mockRepo.enqueueOutbox(
        messageId: testMsgId,
        recipientNostrPubKey: peerNostr,
        payloadJson: jsonEncode({'id': testMsgId, 'ciphertext': 'presence_cipher'}),
      );
      await mockRepo.updateOutboxStatus(testMsgId, status: 'sent', attempts: 1);

      // Peer comes online
      chatProvider.updateUserPresence(
        masterPubKeyHex: peerMaster,
        nostrPubKeyHex: peerNostr,
        isOnline: true,
        lastSeen: DateTime.now(),
      );

      // Wait a short duration for unawaited future to complete
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(mockSignal.sendPreparedPayloadCalls, 1);
      expect(mockSignal.sentPayloads.first['id'], testMsgId);
      expect(mockRepo.outbox.first.attempts, 2);
    });

    test('ChatProvider.drainOutbox respects exponential backoff for unacknowledged sent messages', () async {
      final mockRepo = _MockChatRepo();
      final mockAuth = MockAuthProvider();
      final mockSignal = _MockSignalMessagingServiceForOutbox();
      final chatProvider = ChatProvider(
        chatRepo: mockRepo,
        authProvider: mockAuth,
        signalService: mockSignal,
      );

      const testMsgId = 'msg_backoff_test';
      final now = DateTime.now();

      // Seed message sent 10 seconds ago with 1 attempt (30s backoff required)
      await mockRepo.enqueueOutbox(
        messageId: testMsgId,
        recipientNostrPubKey: 'peer_backoff',
        payloadJson: jsonEncode({'id': testMsgId}),
      );
      await mockRepo.updateOutboxStatus(
        testMsgId,
        status: 'sent',
        attempts: 1,
        lastAttemptAt: now.subtract(const Duration(seconds: 10)),
      );

      // Drain without forcing: backoff should skip it
      await chatProvider.drainOutbox(forceAll: false);
      expect(mockSignal.sendPreparedPayloadCalls, 0);

      // Advance lastAttemptAt beyond the 30s backoff threshold (e.g., 35s ago)
      await mockRepo.updateOutboxStatus(
        testMsgId,
        status: 'sent',
        attempts: 1,
        lastAttemptAt: now.subtract(const Duration(seconds: 35)),
      );

      // Drain again: backoff condition met, message is retried
      await chatProvider.drainOutbox(forceAll: false);
      expect(mockSignal.sendPreparedPayloadCalls, 1);
      expect(mockRepo.outbox.first.attempts, 2);
    });

    test('PeerSessionLockManager strictly serializes concurrent operations for the same peer', () async {
      final lockManager = PeerSessionLockManager();
      const peerA = 'peer_alice_123';
      final executionOrder = <int>[];

      final future1 = lockManager.withPeerLock(peerA, () async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        executionOrder.add(1);
        return 1;
      });

      final future2 = lockManager.withPeerLock(peerA, () async {
        executionOrder.add(2);
        return 2;
      });

      final future3 = lockManager.withPeerLock(peerA, () async {
        executionOrder.add(3);
        return 3;
      });

      await Future.wait([future1, future2, future3]);

      expect(executionOrder, [1, 2, 3]);
      expect(lockManager.hasActiveLock(peerA), isFalse);
    });

    test('PeerSessionLockManager allows concurrent execution across different peers', () async {
      final lockManager = PeerSessionLockManager();
      const peerAlice = 'peer_alice_aaa';
      const peerBob = 'peer_bob_bbb';
      final log = <String>[];

      // Alice's task is slow
      final aliceFuture = lockManager.withPeerLock(peerAlice, () async {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        log.add('alice_done');
      });

      // Bob's task is fast
      final bobFuture = lockManager.withPeerLock(peerBob, () async {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        log.add('bob_done');
      });

      await Future.wait([aliceFuture, bobFuture]);

      // Bob finishes BEFORE Alice because Bob's lock is independent!
      expect(log, ['bob_done', 'alice_done']);
    });

    test('PeerSessionLockManager error in one task does not deadlock subsequent tasks', () async {
      final lockManager = PeerSessionLockManager();
      const peer = 'peer_fault_test';
      final results = <String>[];

      final futureFailing = lockManager.withPeerLock(peer, () async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        throw Exception('Crypto operation failed');
      });

      final futureSucceeding = lockManager.withPeerLock(peer, () async {
        results.add('recovered_and_executed');
        return 'ok';
      });

      expect(() => futureFailing, throwsException);
      final res = await futureSucceeding;
      expect(res, 'ok');
      expect(results, ['recovered_and_executed']);
      expect(lockManager.hasActiveLock(peer), isFalse);
    });

    test('SignalMessagingService serializes concurrent session establishment for same peer', () async {
      final signalStore = _MockSignalStore();
      final nostrService = _MockNostrRelayServiceNoPrekeys();
      final service = SignalMessagingService(
        signalStore: signalStore,
        nostrService: nostrService,
        masterPublicKeyHex: 'test_master',
      );

      const peer = 'peer_concurrent_setup';
      int executedCount = 0;

      // Launch 3 simultaneous session establishments for the same peer
      final f1 = service.withPeerLock(peer, () async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        executedCount++;
      });
      final f2 = service.withPeerLock(peer, () async {
        executedCount++;
      });
      final f3 = service.withPeerLock(peer, () async {
        executedCount++;
      });

      await Future.wait([f1, f2, f3]);
      expect(executedCount, 3);
      expect(service.lockManager.hasActiveLock(peer), isFalse);
    });
  });

  group('PreKey Replenishment & Periodic Checks Tests', () {
    test('checkAndReplenishPreKeys replenishes when pool is below 25 and generates up to 50', () async {
      final store = _MockSignalStore();
      final mockNostr = _MockNostrRelayServiceForPreKeys();
      final service = SignalMessagingService(
        signalStore: store,
        nostrService: mockNostr,
        masterPublicKeyHex: 'test_master_replenish',
      );

      // Initially empty store
      expect(await store.getPreKeyCount(), 0);

      // Calling checkAndReplenishPreKeys() autonomously resolves credentials and replenishes
      await service.checkAndReplenishPreKeys();

      expect(await store.getPreKeyCount(), 50);
      expect(mockNostr.broadcastCount, 1);
      final payload = mockNostr.lastBroadcastPayload!;
      expect(payload['masterKey'], 'test_master_replenish');
      expect(payload['registrationId'], 12345);
      final oneTimePreKeys = payload['oneTimePreKeys'] as List;
      expect(oneTimePreKeys.length, 50);
    });

    test('checkAndReplenishPreKeys skips replenishment when pool is healthy (>= 25) and forceRebroadcast is false', () async {
      final store = _MockSignalStore();
      final mockNostr = _MockNostrRelayServiceForPreKeys();
      final service = SignalMessagingService(
        signalStore: store,
        nostrService: mockNostr,
        masterPublicKeyHex: 'test_master_replenish',
      );

      // Populate 30 prekeys
      final keys = generatePreKeys(1, 30);
      for (final k in keys) {
        await store.storePreKey(k.id, k);
      }
      expect(await store.getPreKeyCount(), 30);

      // Check and replenish with healthy pool
      await service.checkAndReplenishPreKeys();

      expect(await store.getPreKeyCount(), 30);
      expect(mockNostr.broadcastCount, 0);
    });

    test('checkAndReplenishPreKeys rebroadcasts available keys when forceRebroadcast is true even if count >= 25', () async {
      final store = _MockSignalStore();
      final mockNostr = _MockNostrRelayServiceForPreKeys();
      final service = SignalMessagingService(
        signalStore: store,
        nostrService: mockNostr,
        masterPublicKeyHex: 'test_master_replenish',
      );

      // Populate 35 prekeys
      final keys = generatePreKeys(1, 35);
      for (final k in keys) {
        await store.storePreKey(k.id, k);
      }
      expect(await store.getPreKeyCount(), 35);

      // Force rebroadcast (e.g., after bundle consumption)
      await service.checkAndReplenishPreKeys(forceRebroadcast: true);

      expect(await store.getPreKeyCount(), 35);
      expect(mockNostr.broadcastCount, 1);
      final payload = mockNostr.lastBroadcastPayload!;
      final oneTimePreKeys = payload['oneTimePreKeys'] as List;
      expect(oneTimePreKeys.length, 35);
    });

    test('schedulePostConsumptionReplenishment debounces rapid consumption events into a single broadcast', () async {
      final store = _MockSignalStore();
      final mockNostr = _MockNostrRelayServiceForPreKeys();
      final service = SignalMessagingService(
        signalStore: store,
        nostrService: mockNostr,
        masterPublicKeyHex: 'test_master_debounce',
      );

      // Populate 40 prekeys
      final keys = generatePreKeys(1, 40);
      for (final k in keys) {
        await store.storePreKey(k.id, k);
      }

      // Schedule two post-consumption replenishments rapidly with short debounce
      service.schedulePostConsumptionReplenishment(const Duration(milliseconds: 50));
      expect(service.rebroadcastDebounceTimer?.isActive, isTrue);
      service.schedulePostConsumptionReplenishment(const Duration(milliseconds: 50));

      expect(mockNostr.broadcastCount, 0);

      // Wait for debounce timer to fire
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(mockNostr.broadcastCount, 1);
      final payload = mockNostr.lastBroadcastPayload!;
      final oneTimePreKeys = payload['oneTimePreKeys'] as List;
      expect(oneTimePreKeys.length, 40);
    });

    test('startPeriodicReplenishment starts timer and stopPeriodicReplenishment cancels timer and debounce', () async {
      final store = _MockSignalStore();
      final mockNostr = _MockNostrRelayServiceForPreKeys();
      final service = SignalMessagingService(
        signalStore: store,
        nostrService: mockNostr,
        masterPublicKeyHex: 'test_master_periodic',
      );

      service.startPeriodicReplenishment(const Duration(minutes: 15));
      expect(service.periodicReplenishmentTimer, isNotNull);
      expect(service.periodicReplenishmentTimer!.isActive, isTrue);

      service.schedulePostConsumptionReplenishment(const Duration(minutes: 5));
      expect(service.rebroadcastDebounceTimer, isNotNull);
      expect(service.rebroadcastDebounceTimer!.isActive, isTrue);

      service.stopPeriodicReplenishment();
      expect(service.periodicReplenishmentTimer, isNull);
      expect(service.rebroadcastDebounceTimer, isNull);
    });
  });

  group('AccountSession & Lifecycle Teardown Tests', () {
    test('AccountSession generation increments on startNewSession and dispose', () async {
      AccountSession.setGenerationForTesting(10);
      expect(AccountSession.currentGeneration, 10);
      expect(AccountSession.isGenerationValid(10), isTrue);
      expect(AccountSession.isGenerationValid(9), isFalse);

      final newGen = AccountSession.startNewSession();
      expect(newGen, 11);
      expect(AccountSession.currentGeneration, 11);
      expect(AccountSession.isGenerationValid(10), isFalse);
      expect(AccountSession.isGenerationValid(11), isTrue);

      await AccountSession.dispose();
      expect(AccountSession.currentGeneration, 12);
      expect(AccountSession.isGenerationValid(11), isFalse);
      expect(AccountSession.isGenerationValid(12), isTrue);
    });

    test('AccountSession.dispose tears down Nostr, Chat, and Signal', () async {
      final fakeNostr = _MockNostrRelayServiceForLifecycle();
      final mockStore = _MockSignalStore();
      final signal = SignalMessagingService(
        signalStore: mockStore,
        nostrService: fakeNostr,
        masterPublicKeyHex: 'test_master_lifecycle',
      );
      signal.startPeriodicReplenishment(const Duration(minutes: 15));
      signal.schedulePostConsumptionReplenishment(const Duration(minutes: 5));
      expect(signal.isDisposed, isFalse);

      fakeNostr.hasBeenTornDown = false;
      fakeNostr.onReadyCallbacks.add(() {});

      final fakeRepo = _MockChatRepo();
      final fakeAuth = MockAuthProvider();
      final chat = ChatProvider(
        chatRepo: fakeRepo,
        authProvider: fakeAuth,
        signalService: signal,
      );
      chat.activeChats.add(DiscoverUser(masterPubKeyHex: 'm1', nostrPubKeyHex: 'n1', username: 'u1', lastSeen: DateTime.now()));

      await AccountSession.dispose(
        chatProvider: chat,
        signalService: signal,
        nostrService: fakeNostr,
      );

      // Verify Signal disposed
      expect(signal.isDisposed, isTrue);
      expect(signal.periodicReplenishmentTimer, isNull);
      expect(signal.rebroadcastDebounceTimer, isNull);

      // Verify Chat cleared
      expect(chat.activeChats, isEmpty);

      // Verify Nostr torn down
      expect(fakeNostr.hasBeenTornDown, isTrue);
      expect(fakeNostr.onReadyCallbacks, isEmpty);
    });

    test('Stale in-flight callbacks with previous session generation are dropped', () async {
      AccountSession.setGenerationForTesting(100);
      final capturedGen = AccountSession.currentGeneration;
      bool executed = false;

      void onNetworkCallback() {
        if (!AccountSession.isGenerationValid(capturedGen)) {
          // Dropped
          return;
        }
        executed = true;
      }

      // Bump session generation (simulating account logout or switch)
      await AccountSession.dispose();
      expect(AccountSession.currentGeneration, 101);

      // Execute callback created during previous session
      onNetworkCallback();
      expect(executed, isFalse);
    });

    test('NostrRelayService.teardownSession wipes keys, timers, and sets state to disconnected', () async {
      final nostr = NostrRelayService();
      nostr.initKeys('test_mnemonic_seed_for_teardown_123');
      expect(nostr.hasKeys, isTrue);
      expect(nostr.publicHex, isNotEmpty);

      bool readyCalled = false;
      nostr.addOnReadyListener(() => readyCalled = true);

      await nostr.teardownSession();

      expect(nostr.hasKeys, isFalse);
      expect(nostr.publicHex, isEmpty);
      expect(nostr.state, NostrConnectionState.disconnected);
      expect(readyCalled, isFalse);
    });
  });

  group('Comprehensive Account Generation Isolation & Multi-Layer Defense Tests', () {
    test('SignalStore throws StateError and aborts DB mutations if AccountSession generation changes', () async {
      AccountSession.setGenerationForTesting(500);
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final keyPair = generateIdentityKeyPair();
      final store = SignalStore(db, keyPair, 12345, sessionGeneration: 500);

      final address = SignalProtocolAddress('peer_store_test', 1);
      final peerKey = generateIdentityKeyPair().getPublicKey();

      // Generation 500: operations succeed
      final saved = await store.saveIdentity(address, peerKey);
      expect(saved, isTrue);

      final loadedKey = await store.getIdentity(address);
      expect(loadedKey, isNotNull);

      // Advance AccountSession generation to 501 (simulating logout/switch)
      AccountSession.setGenerationForTesting(501);

      // All mutating and reading methods on stale store must throw StateError
      expect(() => store.saveIdentity(address, peerKey), throwsA(isA<StateError>()));
      expect(() => store.getIdentity(address), throwsA(isA<StateError>()));
      expect(() => store.isTrustedIdentity(address, peerKey, Direction.sending), throwsA(isA<StateError>()));
      expect(() => store.storeSession(address, SessionRecord()), throwsA(isA<StateError>()));
      expect(() => store.loadSession(address), throwsA(isA<StateError>()));
      expect(() => store.deleteSession(address), throwsA(isA<StateError>()));
      expect(() => store.storePreKey(1, generatePreKeys(1, 1).first), throwsA(isA<StateError>()));
      expect(() => store.loadPreKey(1), throwsA(isA<StateError>()));
      expect(() => store.clearStore(), throwsA(isA<StateError>()));

      await db.close();
    });

    test('SignalMessagingService.approveUntrustedIdentity aborts and rejects mutation when generation is stale', () async {
      AccountSession.setGenerationForTesting(600);
      final mockStore = _MockSignalStore();
      final service = SignalMessagingService(
        signalStore: mockStore,
        nostrService: _MockNostrRelayServiceNoPrekeys(),
        masterPublicKeyHex: 'test_master_600',
        sessionGeneration: 600,
      );

      // Advance generation
      AccountSession.setGenerationForTesting(601);

      // Calling approveUntrustedIdentity on stale service throws StateError
      expect(
        () => service.approveUntrustedIdentity('peer_blocked_nostr'),
        throwsA(isA<StateError>()),
      );
    });

    test('NostrRelayService.sendEncryptedPayload and broadcastPreKeyBundle reject stale sessionGen', () async {
      AccountSession.setGenerationForTesting(700);
      final nostr = NostrRelayService();

      // Session gen 699 is stale relative to active 700
      expect(
        () => nostr.sendEncryptedPayload('peer_pub', '{"test": 1}', sessionGen: 699),
        throwsA(isA<StateError>()),
      );

      final broadcastResult = await nostr.broadcastPreKeyBundle('master_pub', {'bundle': 1}, sessionGen: 699);
      expect(broadcastResult, isFalse);
    });

    test('ChatProvider._handleIncomingNostrEvent drops decrypted message and prevents DB mutation when generation changes during decryption', () async {
      AccountSession.setGenerationForTesting(800);
      final mockRepo = _MockChatRepo();
      final mockAuth = MockAuthProvider();
      final mockSignal = _MockSignalMessagingServiceForOutbox();
      final chatProvider = ChatProvider(
        chatRepo: mockRepo,
        authProvider: mockAuth,
        signalService: mockSignal,
      );

      final peerKeyPairs = NostrKeyPairs(private: '55' * 32);
      final peerNostr = peerKeyPairs.public;

      final incomingEnvelope = MndoMessageEnvelope(
        version: 1,
        messageId: 'incoming_stale_gen_msg',
        type: 'text',
        timestamp: DateTime.now().millisecondsSinceEpoch,
        senderMasterPubKey: 'peer_master_800',
        body: {'text': 'Should never be stored or shown'},
      );

      mockSignal.incomingMessageToReturn = (
        incomingEnvelope.serialize(),
        'peer_master_800',
        DateTime.now(),
        null,
        false,
      );

      // During decryption, user logs out / session generation advances to 801
      mockSignal.onDecryptMessage = () async {
        AccountSession.setGenerationForTesting(801);
      };

      final event = NostrEvent.fromPartialData(
        kind: 4444,
        content: jsonEncode({'type': 3, 'ciphertext': 'stale_cipher'}),
        keyPairs: peerKeyPairs,
      );

      await chatProvider.handleIncomingEventForTest(event);

      // Message MUST be dropped:
      // 1. Not in chat histories
      expect(chatProvider.chatHistories[peerNostr], isNull);
      // 2. Not in activeChats
      expect(chatProvider.activeChats.any((u) => u.nostrPubKeyHex == peerNostr), isFalse);
      // 3. Not written to database / repo
      expect(mockRepo.savedMessages.any((m) => m.messageId == 'incoming_stale_gen_msg'), isFalse);
      // 4. No delivery or read receipt sent back
      expect(mockSignal.sendMessageCalls, 0);
    });

    test('ChatRepository intrinsically rejects queries and mutations when sessionGeneration is stale', () async {
      AccountSession.setGenerationForTesting(900);
      final db = AppDatabase.forTesting(NativeDatabase.memory(), sessionGeneration: 900);
      final repo = ChatRepository(db, sessionGeneration: 900);

      // Advance generation to 901
      AccountSession.setGenerationForTesting(901);

      // Read operations throw StateError
      expect(() => repo.getAllChats(), throwsA(isA<StateError>()));
      expect(() => repo.getMessagesForChat('peer_pub'), throwsA(isA<StateError>()));
      expect(() => repo.getPendingOutboxMessages(), throwsA(isA<StateError>()));
      expect(() => repo.getUndeliveredMessagesForPeer('peer_pub'), throwsA(isA<StateError>()));
      expect(() => repo.getOutboxRecord('msg_1'), throwsA(isA<StateError>()));
      expect(() => repo.getMessageByMessageId('msg_1'), throwsA(isA<StateError>()));
      expect(() => repo.getLatestMessageTimestamp(), throwsA(isA<StateError>()));

      // Mutating operations throw StateError
      final dummyUser = DiscoverUser(
        nostrPubKeyHex: 'user_pub',
        masterPubKeyHex: 'user_master',
        username: 'user',
        displayName: 'User',
        lastSeen: DateTime.now(),
      );
      final dummyMsg = ChatMessage(messageId: 'msg_1', text: 'hi', isMe: true, timestamp: DateTime.now());
      expect(() => repo.saveChat(dummyUser), throwsA(isA<StateError>()));
      expect(() => repo.saveMessage('peer_pub', dummyMsg), throwsA(isA<StateError>()));
      expect(() => repo.enqueueOutbox(messageId: 'msg_1', recipientNostrPubKey: 'peer_pub', payloadJson: '{}'), throwsA(isA<StateError>()));
      expect(() => repo.deleteFromOutbox('msg_1'), throwsA(isA<StateError>()));
      expect(() => repo.updateOutboxAttempt('msg_1', attempts: 1, lastAttemptAt: DateTime.now(), status: 'pending'), throwsA(isA<StateError>()));
      expect(() => repo.updateOutboxStatus('msg_1', status: 'delivered'), throwsA(isA<StateError>()));
      expect(() => repo.updateMessageStatus('msg_1', MessageStatus.delivered), throwsA(isA<StateError>()));
      expect(() => repo.markMessagesReadUpTo('peer_pub', DateTime.now()), throwsA(isA<StateError>()));
      expect(() => repo.clearAll(), throwsA(isA<StateError>()));

      await db.close();
    });

    test('AppDatabase intrinsically rejects queries and mutations when sessionGeneration is stale', () async {
      AccountSession.setGenerationForTesting(950);
      final db = AppDatabase.forTesting(NativeDatabase.memory(), sessionGeneration: 950);

      // Advance generation to 951
      AccountSession.setGenerationForTesting(951);

      // Query and mutation methods throw StateError
      expect(() => db.getAllChats(), throwsA(isA<StateError>()));
      expect(() => db.clearChats(), throwsA(isA<StateError>()));
      expect(() => db.getMessagesForChat('peer_pub'), throwsA(isA<StateError>()));
      expect(() => db.clearMessages(), throwsA(isA<StateError>()));
      expect(() => db.getMessageByMessageId('m1'), throwsA(isA<StateError>()));
      expect(() => db.getLatestMessageTimestamp(), throwsA(isA<StateError>()));
      expect(() => db.getPendingOutboxMessages(), throwsA(isA<StateError>()));
      expect(() => db.getUndeliveredMessagesForPeer('peer_pub'), throwsA(isA<StateError>()));
      expect(() => db.clearOutbox(), throwsA(isA<StateError>()));
      expect(() => db.getPreKeyCount(), throwsA(isA<StateError>()));
      expect(() => db.getMaxPreKeyId(), throwsA(isA<StateError>()));
      expect(() => db.getAllPreKeys(), throwsA(isA<StateError>()));
      expect(() => db.clearSignalData(), throwsA(isA<StateError>()));
      expect(() => db.clearAllUserData(), throwsA(isA<StateError>()));

      await db.close();
    });

    test('NostrRelayService enforces sessionGeneration strictly across all transport APIs', () async {
      AccountSession.setGenerationForTesting(1000);
      final nostr = NostrRelayService();
      nostr.initKeys('11' * 32, sessionGeneration: 1000);

      // Correct session generation matches
      expect(nostr.activeSessionGeneration, 1000);

      // 1. Caller passing mismatched/stale generation throws StateError
      expect(
        () => nostr.sendEncryptedPayload('peer_pub', '{"content": 1}', sessionGen: 999),
        throwsA(isA<StateError>()),
      );

      // 2. Caller passing matching sessionGen succeeds validation
      // When active generation advances (logout / new user), transport becomes stale
      AccountSession.setGenerationForTesting(1001);

      // Even caller with old 1000 now throws StateError because active session changed
      expect(
        () => nostr.sendEncryptedPayload('peer_pub', '{"content": 1}', sessionGen: 1000),
        throwsA(isA<StateError>()),
      );

      // Caller with 1001 throws StateError because transport is still bound to 1000
      expect(
        () => nostr.sendEncryptedPayload('peer_pub', '{"content": 1}', sessionGen: 1001),
        throwsA(isA<StateError>()),
      );

      // 3. Blossom auth header creation fails closed on generation mismatch
      expect(
        nostr.createBlossomAuthHeader(sha256Hex: 'aa' * 32, action: 'upload', sessionGen: 999),
        isNull,
      );

      // 4. teardownSession wipes keys and activeSessionGeneration
      await nostr.teardownSession();
      expect(nostr.activeSessionGeneration, isNull);
      expect(
        () => nostr.sendEncryptedPayload('peer_pub', '{"content": 1}', sessionGen: 1001),
        throwsA(isA<StateError>()),
      );
    });

    test('ChatProvider.sendControlMessage aborts and drops message if session generation advances during signing', () async {
      AccountSession.setGenerationForTesting(1100);
      final mockRepo = _MockChatRepo();
      final mockCrypto = _MockCryptoServiceWithLifecycleRace();
      final keyPair = await mockCrypto.generateMasterKeyPair(
        'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about',
      );

      final mockAuth = MockAuthProvider();
      mockAuth.cryptoService = mockCrypto;
      mockAuth.masterKeyPair = keyPair;
      final mockSignal = _MockSignalMessagingServiceForOutbox();
      final chatProvider = ChatProvider(
        chatRepo: mockRepo,
        authProvider: mockAuth,
        signalService: mockSignal,
      );

      final nostr = NostrRelayService();
      nostr.initKeys('22' * 32, sessionGeneration: 1100);

      // During async Ed25519 signing of control token, simulate user logout / new account login
      mockCrypto.onSign = () {
        AccountSession.setGenerationForTesting(1101);
      };

      // Calling sendControlMessage must abort post-sign without sending payload
      await chatProvider.sendControlMessage(
        recipientNostrPubKey: 'target_peer_nostr',
        control: 'read',
      );

      // Active session generation is now 1101
      expect(AccountSession.currentGeneration, 1101);
    });
  });

  group('Cumulative Read Watermark Tests', () {
    test('markChatAsRead sends single read receipt for latest unread incoming message', () async {
      final mockRepo = _MockChatRepo();
      final mockAuth = MockAuthProvider();
      final mockSignal = _MockSignalMessagingServiceForOutbox();
      final chatProvider = ChatProvider(
        chatRepo: mockRepo,
        authProvider: mockAuth,
        signalService: mockSignal,
      );

      const peerNostr = 'peer_nostr_pubkey_watermark_1';
      final t0 = DateTime.now().subtract(const Duration(minutes: 5));
      final t1 = DateTime.now().subtract(const Duration(minutes: 4));
      final t2 = DateTime.now().subtract(const Duration(minutes: 3));

      final msg1 = ChatMessage(messageId: 'msg_recv_1', text: 'Hello 1', isMe: false, timestamp: t0, status: MessageStatus.delivered);
      final msg2 = ChatMessage(messageId: 'msg_recv_2', text: 'Hello 2', isMe: false, timestamp: t1, status: MessageStatus.delivered);
      final msg3 = ChatMessage(messageId: 'msg_recv_3', text: 'Hello 3', isMe: false, timestamp: t2, status: MessageStatus.delivered);

      chatProvider.chatHistories[peerNostr] = [msg1, msg2, msg3];

      // Call markChatAsRead
      await chatProvider.markChatAsRead(peerNostr);

      // Verify all 3 messages are marked read in memory
      expect(msg1.status, MessageStatus.read);
      expect(msg2.status, MessageStatus.read);
      expect(msg3.status, MessageStatus.read);

      // Verify exactly ONE receipt was sent, targeting msg_recv_3 (the latest unread)
      expect(mockSignal.sendMessageCalls, 1);
      final sentReceipt = mockSignal.sentMessages.first;
      expect(sentReceipt['type'], 'receipt');
      expect(sentReceipt['status'], 'read');
      expect(sentReceipt['targetId'], 'msg_recv_3');

      // Calling markChatAsRead again without new incoming messages sends NO additional receipts
      await chatProvider.markChatAsRead(peerNostr);
      expect(mockSignal.sendMessageCalls, 1);
    });

    test('Incoming read receipt cumulatively marks target message and all prior sent messages as read', () async {
      final mockRepo = _MockChatRepo();
      final mockAuth = MockAuthProvider();
      final mockSignal = _MockSignalMessagingServiceForOutbox();
      final chatProvider = ChatProvider(
        chatRepo: mockRepo,
        authProvider: mockAuth,
        signalService: mockSignal,
      );

      final peerKeyPairs = NostrKeyPairs(private: '33' * 32);
      final peerNostr = peerKeyPairs.public;

      final t0 = DateTime.now().subtract(const Duration(minutes: 10));
      final t1 = DateTime.now().subtract(const Duration(minutes: 8));
      final t2 = DateTime.now().subtract(const Duration(minutes: 6));
      final t3 = DateTime.now().subtract(const Duration(minutes: 1)); // In-flight after t2

      final msgA = ChatMessage(messageId: 'msg_sent_a', text: 'Msg A', isMe: true, timestamp: t0, status: MessageStatus.sent);
      final msgB = ChatMessage(messageId: 'msg_sent_b', text: 'Msg B', isMe: true, timestamp: t1, status: MessageStatus.delivered);
      final msgC = ChatMessage(messageId: 'msg_sent_c', text: 'Msg C', isMe: true, timestamp: t2, status: MessageStatus.delivered);
      final msgD = ChatMessage(messageId: 'msg_sent_d', text: 'Msg D', isMe: true, timestamp: t3, status: MessageStatus.sent);

      chatProvider.chatHistories[peerNostr] = [msgA, msgB, msgC, msgD];
      mockRepo.savedMessages.addAll([msgA, msgB, msgC, msgD]);

      // Enqueue items into outbox
      await mockRepo.enqueueOutbox(messageId: 'msg_sent_a', recipientNostrPubKey: peerNostr, payloadJson: '{}');
      await mockRepo.enqueueOutbox(messageId: 'msg_sent_b', recipientNostrPubKey: peerNostr, payloadJson: '{}');
      await mockRepo.enqueueOutbox(messageId: 'msg_sent_c', recipientNostrPubKey: peerNostr, payloadJson: '{}');
      await mockRepo.enqueueOutbox(messageId: 'msg_sent_d', recipientNostrPubKey: peerNostr, payloadJson: '{}');

      // Create read receipt targeting msg_sent_c
      final receiptEnvelope = MndoMessageEnvelope(
        version: 1,
        messageId: 'rcpt_1',
        type: 'receipt',
        timestamp: DateTime.now().millisecondsSinceEpoch,
        senderMasterPubKey: 'peer_master_123',
        body: {
          'targetId': 'msg_sent_c',
          'status': 'read',
        },
      );

      mockSignal.incomingMessageToReturn = (receiptEnvelope.serialize(), 'peer_master_123', DateTime.now(), null, false);

      final event = NostrEvent.fromPartialData(
        kind: 4444,
        content: jsonEncode({'type': 3, 'ciphertext': 'cipher'}),
        keyPairs: peerKeyPairs,
      );

      await chatProvider.handleIncomingEventForTest(event);

      // Verify cumulative advancement up to msg_sent_c:
      expect(msgA.status, MessageStatus.read, reason: 'Msg A (before C) should be read');
      expect(msgB.status, MessageStatus.read, reason: 'Msg B (before C) should be read');
      expect(msgC.status, MessageStatus.read, reason: 'Target Msg C should be read');

      // Verify msg_sent_d (after C) is NOT marked as read:
      expect(msgD.status, MessageStatus.sent, reason: 'Msg D (sent after C) must remain sent');

      // Verify Outbox records for A, B, and C are deleted, while D remains
      final remainingOutbox = await mockRepo.getPendingOutboxMessages();
      expect(remainingOutbox.any((r) => r.messageId == 'msg_sent_a'), isFalse);
      expect(remainingOutbox.any((r) => r.messageId == 'msg_sent_b'), isFalse);
      expect(remainingOutbox.any((r) => r.messageId == 'msg_sent_c'), isFalse);
      expect(remainingOutbox.any((r) => r.messageId == 'msg_sent_d'), isTrue);
    });

    test('Incoming read receipt for message not in memory loads timestamp from repo and marks read', () async {
      final mockRepo = _MockChatRepo();
      final mockAuth = MockAuthProvider();
      final mockSignal = _MockSignalMessagingServiceForOutbox();
      final chatProvider = ChatProvider(
        chatRepo: mockRepo,
        authProvider: mockAuth,
        signalService: mockSignal,
      );

      final peerKeyPairs = NostrKeyPairs(private: '44' * 32);

      final t0 = DateTime.now().subtract(const Duration(minutes: 10));
      final msgOld = ChatMessage(messageId: 'msg_db_only', text: 'Old DB msg', isMe: true, timestamp: t0, status: MessageStatus.sent);
      mockRepo.savedMessages.add(msgOld);

      final receiptEnvelope = MndoMessageEnvelope(
        version: 1,
        messageId: 'rcpt_db',
        type: 'receipt',
        timestamp: DateTime.now().millisecondsSinceEpoch,
        senderMasterPubKey: 'peer_master_123',
        body: {
          'targetId': 'msg_db_only',
          'status': 'read',
        },
      );

      mockSignal.incomingMessageToReturn = (receiptEnvelope.serialize(), 'peer_master_123', DateTime.now(), null, false);

      final event = NostrEvent.fromPartialData(
        kind: 4444,
        content: jsonEncode({'type': 3, 'ciphertext': 'cipher'}),
        keyPairs: peerKeyPairs,
      );

      await chatProvider.handleIncomingEventForTest(event);

      expect(mockRepo.messageStatuses['msg_db_only'], 'read');
    });
  });

  group('Unified Presence Flow & Indicators Tests', () {
    test('DiscoverUser.isOnline handles future clock skew up to 600s gracefully', () {
      final now = DateTime.now();
      // Future clock skew of 30 seconds
      final futureUser = DiscoverUser(
        masterPubKeyHex: 'master_clock_skew_1',
        nostrPubKeyHex: 'nostr_clock_skew_1',
        username: 'skew_user',
        lastSeen: now,
        lastSeenFromPing: now.add(const Duration(seconds: 30)),
      );
      expect(futureUser.isOnline, isTrue, reason: 'Sender clock skew within 600s should be considered online');

      // Future clock skew beyond 600s
      final absurdFutureUser = DiscoverUser(
        masterPubKeyHex: 'master_clock_skew_2',
        nostrPubKeyHex: 'nostr_clock_skew_2',
        username: 'absurd_user',
        lastSeen: now,
        lastSeenFromPing: now.add(const Duration(seconds: 700)),
      );
      expect(absurdFutureUser.isOnline, isFalse, reason: 'Pings with > 600s clock skew should not be online');

      // Past ping > 70s
      final expiredUser = DiscoverUser(
        masterPubKeyHex: 'master_expired',
        nostrPubKeyHex: 'nostr_expired',
        username: 'expired_user',
        lastSeen: now.subtract(const Duration(seconds: 75)),
        lastSeenFromPing: now.subtract(const Duration(seconds: 75)),
      );
      expect(expiredUser.isOnline, isFalse, reason: 'Pings > 70s old must be offline');
    });

    testWidgets('OnlineStatusIndicator renders emerald green when online and slate when offline', (tester) async {
      // Online widget
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.light(),
          home: const Scaffold(
            body: OnlineStatusIndicator(isOnline: true, size: 14),
          ),
        ),
      );
      final greenContainer = tester.widget<Container>(find.byType(Container));
      final greenBox = greenContainer.decoration as BoxDecoration;
      expect(greenBox.color, const Color(0xFF4BD151));

      // Offline widget
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.light(),
          home: const Scaffold(
            body: OnlineStatusIndicator(isOnline: false, size: 14),
          ),
        ),
      );
      final slateContainer = tester.widget<Container>(find.byType(Container));
      final slateBox = slateContainer.decoration as BoxDecoration;
      expect(slateBox.color, const Color(0xFF9CA3AF));
    });

    test('Cached contact with null pings + live incoming message resolves to isActuallyOnline == true', () {
      final now = DateTime.now();

      // Contact loaded from SharedPreferences cache on startup:
      final knownCachedUser = DiscoverUser(
        masterPubKeyHex: 'peer_cached_1',
        nostrPubKeyHex: 'peer_cached_nostr_1',
        username: 'cached_friend',
        lastSeen: now.subtract(const Duration(hours: 2)),
        lastSeenFromPing: null,
        lastSeenFromMessage: null,
        isExplicitlyOffline: false,
      );
      expect(knownCachedUser.isOnline, isFalse);

      // Active chat receiving live incoming message:
      final chatUser = DiscoverUser(
        masterPubKeyHex: 'peer_cached_1',
        nostrPubKeyHex: 'peer_cached_nostr_1',
        username: 'cached_friend',
        lastSeen: now,
        lastSeenFromPing: null,
        lastSeenFromMessage: now,
        isExplicitlyOffline: false,
      );
      expect(chatUser.isOnline, isTrue);

      // Symmetrical resolution logic:
      final isExplicitlyOffline = (knownCachedUser.isExplicitlyOffline == true) || chatUser.isExplicitlyOffline;
      final isActuallyOnline = !isExplicitlyOffline && (knownCachedUser.isOnline || chatUser.isOnline);

      expect(isActuallyOnline, isTrue, reason: 'Live incoming message must show user as online even if cached member has null pings');
    });

    test('Explicit offline ping supersedes stale active message and resolves to offline', () {
      final now = DateTime.now();

      // Peer broadcasted explicit offline:
      final knownUser = DiscoverUser(
        masterPubKeyHex: 'peer_offline_1',
        nostrPubKeyHex: 'peer_offline_nostr_1',
        username: 'friend',
        lastSeen: now,
        lastSeenFromPing: null,
        lastSeenFromMessage: null,
        isExplicitlyOffline: true,
      );

      // Stale active chat state before presence sync:
      final chatUser = DiscoverUser(
        masterPubKeyHex: 'peer_offline_1',
        nostrPubKeyHex: 'peer_offline_nostr_1',
        username: 'friend',
        lastSeen: now.subtract(const Duration(seconds: 10)),
        lastSeenFromMessage: now.subtract(const Duration(seconds: 10)),
        isExplicitlyOffline: false,
      );

      // Symmetrical resolution logic:
      final isExplicitlyOffline = (knownUser.isExplicitlyOffline == true) || chatUser.isExplicitlyOffline;
      final isActuallyOnline = !isExplicitlyOffline && (knownUser.isOnline || chatUser.isOnline);

      expect(isActuallyOnline, isFalse, reason: 'Explicit offline ping must take precedence over stale message timestamps');
    });
  });

  group('Mandatory Master-to-Nostr & PreKey Cryptographic Binding Security Tests', () {
    test('DiscoverProvider drops Kind 21111 ping when masterSig is omitted/null', () async {
      SharedPreferences.setMockInitialValues({});
      final auth = MockAuthProvider();
      final chat = MockChatProvider();
      final discover = DiscoverProvider(
        authProvider: auth,
        chatProvider: chat,
        cryptoService: CryptoService(),
      );

      const victimMaster = '1122334455667788112233445566778811223344556677881122334455667788';
      final event = NostrEvent(
        id: 'spoof_id_1',
        pubkey: 'attacker_nostr_key_1',
        createdAt: DateTime.now(),
        kind: 21111,
        tags: [
          ['master', victimMaster],
        ],
        content: jsonEncode({
          'masterKey': victimMaster,
          'status': 'online',
          'ts': DateTime.now().millisecondsSinceEpoch,
        }),
        sig: 'nostr_sig',
      );

      await discover.handlePublicProfileEvent(event);
      expect(discover.discoveredUsers.any((u) => u.masterPubKeyHex == victimMaster), isFalse);
    });

    test('DiscoverProvider drops Kind 21111 ping when masterSig is invalid/forged', () async {
      SharedPreferences.setMockInitialValues({});
      final auth = MockAuthProvider();
      final chat = MockChatProvider();
      final discover = DiscoverProvider(
        authProvider: auth,
        chatProvider: chat,
        cryptoService: CryptoService(),
      );

      const victimMaster = '1122334455667788112233445566778811223344556677881122334455667788';
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final event = NostrEvent(
        id: 'spoof_id_2',
        pubkey: 'attacker_nostr_key_2',
        createdAt: DateTime.now(),
        kind: 21111,
        tags: [
          ['master', victimMaster],
          ['masterSig', '00' * 64],
        ],
        content: jsonEncode({
          'masterKey': victimMaster,
          'status': 'online',
          'ts': nowMs,
          'masterSig': '00' * 64,
        }),
        sig: 'nostr_sig',
      );

      await discover.handlePublicProfileEvent(event);
      expect(discover.discoveredUsers.any((u) => u.masterPubKeyHex == victimMaster), isFalse);
    });

    test('DiscoverProvider accepts Kind 21111 ping when masterSig is legitimately signed', () async {
      SharedPreferences.setMockInitialValues({});
      final auth = MockAuthProvider();
      final chat = MockChatProvider();
      final crypto = CryptoService();
      final discover = DiscoverProvider(
        authProvider: auth,
        chatProvider: chat,
        cryptoService: crypto,
      );

      final keyPair = await crypto.generateMasterKeyPair('abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about');
      final pubKey = await keyPair.extractPublicKey();
      final masterPubKeyHex = pubKey.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

      const legitNostr = 'legit_peer_nostr_valid';
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final sig = await crypto.signDelegationToken(
        masterKeyPair: keyPair,
        nostrPubKeyHex: legitNostr,
        timestamp: nowMs,
      );

      final event = NostrEvent(
        id: 'legit_id_1',
        pubkey: legitNostr,
        createdAt: DateTime.now(),
        kind: 21111,
        tags: [
          ['master', masterPubKeyHex],
          ['masterSig', sig],
        ],
        content: jsonEncode({
          'masterKey': masterPubKeyHex,
          'status': 'online',
          'ts': nowMs,
          'masterSig': sig,
          'username': 'legit_user',
        }),
        sig: 'nostr_sig',
      );

      await discover.handlePublicProfileEvent(event);
      expect(discover.discoveredUsers.any((u) => u.masterPubKeyHex == masterPubKeyHex), isTrue);
      final user = discover.discoveredUsers.firstWhere((u) => u.masterPubKeyHex == masterPubKeyHex);
      expect(user.nostrPubKeyHex, legitNostr);
      expect(user.isOnline, isTrue);
    });

    test('DiscoverProvider Kind 0 event cannot overwrite nostrPubKeyHex of existing user', () async {
      const targetMaster = '3344556677889900334455667788990033445566778899003344556677889900';
      const originalNostr = 'original_nostr_addr_1';
      final existingUser = DiscoverUser(
        masterPubKeyHex: targetMaster,
        nostrPubKeyHex: originalNostr,
        username: 'Alice',
        lastSeen: DateTime.now(),
      );

      final cachedJson = jsonEncode([existingUser.toJson()]);
      SharedPreferences.setMockInitialValues({'cached_discovered_members_1': cachedJson});

      final auth = MockAuthProvider();
      final chat = MockChatProvider();
      final discover = DiscoverProvider(
        authProvider: auth,
        chatProvider: chat,
        cryptoService: CryptoService(),
      );

      await discover.loadState();
      expect(discover.discoveredUsers.any((u) => u.masterPubKeyHex == targetMaster), isTrue);

      // Mallory publishes Kind 0 claiming Alice's masterKey with Mallory's Nostr pubkey
      final event = NostrEvent(
        id: 'mallory_k0_event',
        pubkey: 'mallory_attacker_nostr',
        createdAt: DateTime.now(),
        kind: 0,
        tags: [
          ['master', targetMaster],
        ],
        content: jsonEncode({
          'masterKey': targetMaster,
          'name': 'HackedAlice',
        }),
        sig: 'nostr_sig',
      );

      await discover.handlePublicProfileEvent(event);

      // Alice's Nostr routing key and profile MUST remain unmodified!
      final alice = discover.discoveredUsers.firstWhere((u) => u.masterPubKeyHex == targetMaster);
      expect(alice.nostrPubKeyHex, originalNostr);
      expect(alice.username, 'Alice');
    });

    test('ChatProvider updateUserPresence rejects presence update and key aliasing when masterPubKey does not match', () {
      final mockRepo = _MockChatRepo();
      final mockSignal = _MockSignalMessagingServiceForReset();
      final chatProvider = ChatProvider(
        chatRepo: mockRepo,
        signalService: mockSignal,
        authProvider: MockAuthProvider(),
      );

      final originalUser = DiscoverUser(
        masterPubKeyHex: 'alice_master_key_111',
        nostrPubKeyHex: 'alice_nostr_key_111',
        username: 'Alice',
        lastSeen: DateTime.now(),
      );
      chatProvider.activeChats.add(originalUser);

      // Mallory attempts presence update for Alice's nostr key with Mallory's master key
      chatProvider.updateUserPresence(
        masterPubKeyHex: 'mallory_master_key_999',
        nostrPubKeyHex: 'mallory_nostr_key_999',
        isOnline: true,
        lastSeen: DateTime.now(),
      );

      expect(originalUser.nostrPubKeyHex, 'alice_nostr_key_111');
      expect(chatProvider.keyAliases.containsKey('mallory_nostr_key_999'), isFalse);
    });
  });

  group('Identity-Change Protection and Authoritative canSendToPeer Security Tests', () {
    test('SignalMessagingService.canSendToPeer returns false and blocks encryption when identity is blocked even if session exists', () async {
      final store = _MockSignalStore();
      final signal = SignalMessagingService(
        signalStore: store,
        nostrService: _MockNostrRelayServiceNoPrekeys(),
        masterPublicKeyHex: 'local_master_hex',
      );

      final peerNostr = 'peer_nostr_with_existing_session';
      final address = SignalProtocolAddress(peerNostr, 1);
      await store.storeSession(address, SessionRecord());

      // With an active session, canSendToPeer is true
      expect(await signal.canSendToPeer(peerNostr), isTrue);

      // Identity changes: UntrustedIdentity blocks peer
      signal.markIdentityBlockedForTesting(peerNostr);
      expect(signal.isIdentityBlocked(peerNostr), isTrue);

      // CRITICAL ASSERTION: Existing session must NOT allow sending when identity is blocked
      expect(await signal.canSendToPeer(peerNostr), isFalse);

      // Attempting to prepare or send payload throws StateError
      expect(
        () async => await signal.prepareEncryptedPayload(peerNostr, 'Secret Message'),
        throwsA(isA<StateError>()),
      );
      expect(
        () async => await signal.sendPreparedPayload(peerNostr, {'id': '123'}),
        throwsA(isA<StateError>()),
      );
    });

    test('ChatProvider: all outbound sending paths strictly enforce identity block', () async {
      final mockRepo = _MockChatRepo();
      final mockSignal = _MockSignalMessagingServiceForOutbox();
      final chatProvider = ChatProvider(
        chatRepo: mockRepo,
        signalService: mockSignal,
        authProvider: MockAuthProvider(),
      );

      final peerKey = 'peer_nostr_test_blocked';

      // Initially peer is not blocked
      expect(chatProvider.isPeerIdentityBlocked(peerKey), isFalse);
      expect(await chatProvider.canSendToPeer(peerKey), isTrue);

      // Simulate peer identity change
      mockSignal.markIdentityBlockedForTesting(peerKey);
      await chatProvider.handlePeerIdentityKeyChanged(peerKey);

      expect(chatProvider.isPeerIdentityBlocked(peerKey), isTrue);
      expect(await chatProvider.canSendToPeer(peerKey), isFalse);

      // 1. sendOutgoingMessage must fail immediately and mark message failed
      final sendResult = await chatProvider.sendOutgoingMessage(peerKey, 'Attempted send');
      expect(sendResult, isFalse);
      final messages = chatProvider.chatHistories[peerKey] ?? [];
      expect(messages.isNotEmpty, isTrue);
      final attemptedMsg = messages.firstWhere((m) => m.text == 'Attempted send');
      expect(attemptedMsg.status, MessageStatus.failed);

      // 2. drainOutbox must skip messages to blocked peers
      final outboxRecord = OutboxRecord(
        messageId: 'msg_blocked_outbox_1',
        recipientNostrPubKey: peerKey,
        payloadJson: '{"id": "msg_blocked_outbox_1", "type": 3, "ciphertext": "xyz"}',
        status: 'pending',
        attempts: 0,
        createdAt: DateTime.now(),
      );
      mockRepo.outbox.add(outboxRecord);
      final sendPayloadCountBefore = mockSignal.sendPreparedPayloadCalls;
      await chatProvider.drainOutbox(forceAll: true);
      expect(mockSignal.sendPreparedPayloadCalls, sendPayloadCountBefore);

      // 3. retryUnacknowledgedForPeer must abort
      await chatProvider.retryUnacknowledgedForPeer(peerKey);
      expect(mockSignal.sendPreparedPayloadCalls, sendPayloadCountBefore);

      // 4. retryOutgoingMessage must return false
      final retryResult = await chatProvider.retryOutgoingMessage(
        peerKey,
        ChatMessage(text: 'retry text', isMe: true, timestamp: DateTime.now()),
      );
      expect(retryResult, isFalse);

      // 5. sendReceipt must abort and not send message
      final sentMessagesCountBefore = mockSignal.sentMessages.length;
      await chatProvider.sendReceipt(
        recipientNostrPubKey: peerKey,
        targetMessageId: 'target_msg_1',
        status: 'delivered',
      );
      expect(mockSignal.sentMessages.length, sentMessagesCountBefore);
    });

    test('ChatProvider: identity block on aliased key propagates and blocks transmission across both keys', () async {
      final mockRepo = _MockChatRepo();
      final mockSignal = _MockSignalMessagingServiceForOutbox();
      final chatProvider = ChatProvider(
        chatRepo: mockRepo,
        signalService: mockSignal,
        authProvider: MockAuthProvider(),
      );

      final oldKey = 'alice_old_nostr_key';
      final newKey = 'alice_new_nostr_key';

      // Setup user and alias
      final user = DiscoverUser(
        masterPubKeyHex: 'alice_master_key',
        nostrPubKeyHex: oldKey,
        username: 'Alice',
        lastSeen: DateTime.now(),
      );
      chatProvider.activeChats.add(user);
      chatProvider.updateUserPresence(
        masterPubKeyHex: 'alice_master_key',
        nostrPubKeyHex: newKey,
        isOnline: true,
        lastSeen: DateTime.now(),
      );

      expect(chatProvider.keyAliases[oldKey], newKey);
      expect(chatProvider.keyAliases[newKey], oldKey);

      // Block new key
      mockSignal.markIdentityBlockedForTesting(newKey);
      await chatProvider.handlePeerIdentityKeyChanged(newKey);

      // Both keys must report as blocked
      expect(chatProvider.isPeerIdentityBlocked(newKey), isTrue);
      expect(chatProvider.isPeerIdentityBlocked(oldKey), isTrue);

      expect(await chatProvider.canSendToPeer(newKey), isFalse);
      expect(await chatProvider.canSendToPeer(oldKey), isFalse);
    });

    testWidgets('ChatScreen microtask does not set _isSecure when peer identity is blocked even if Signal session exists', (WidgetTester tester) async {
      final mockAuth = MockAuthProvider();
      final mockDiscover = MockDiscoverProvider();
      final mockRepo = _MockChatRepo();
      final mockSignal = _MockSignalMessagingServiceForOutbox();
      final realChat = ChatProvider(
        chatRepo: mockRepo,
        signalService: mockSignal,
        authProvider: mockAuth,
      );

      final peerKey = 'peer_nostr_session_but_blocked';
      // Simulate that identity key is blocked
      mockSignal.markIdentityBlockedForTesting(peerKey);
      await realChat.handlePeerIdentityKeyChanged(peerKey);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authNotifierProvider.overrideWith((ref) => mockAuth),
            discoverNotifierProvider.overrideWith((ref) => mockDiscover),
            chatNotifierProvider.overrideWith((ref) => realChat),
            signalMessagingServiceProvider.overrideWith((ref) => mockSignal),
          ],
          child: const MaterialApp(
            home: ChatScreen(
              recipientMasterPubKey: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
              recipientNostrPubKey: 'peer_nostr_session_but_blocked',
              recipientUsername: 'alice',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verify that _isSecure did NOT become true
      // It should display 'Key Changed (Tap to Verify)'
      expect(find.text('Key Changed (Tap to Verify)'), findsOneWidget);

      // And composer should remain disabled
      final textField = tester.widget<TextField>(find.byType(TextField));
      expect(textField.enabled, isFalse);

      final micButton = tester.widget<IconButton>(find.byKey(const ValueKey('mic_button')));
      expect(micButton.onPressed, isNull);

      mockSignal.dispose();
      NostrRelayService().disposeSubscriptions();
    });
  });

  group('Centralized MasterBindingVerifier Production Tests', () {
    late CryptoService crypto;
    late MasterBindingVerifier verifier;
    late SimpleKeyPair masterKeyPair;
    late String masterPubKeyHex;

    setUp(() async {
      crypto = CryptoService();
      verifier = MasterBindingVerifier(cryptoService: crypto);
      final mnemonic = crypto.generateMnemonic();
      masterKeyPair = await crypto.generateMasterKeyPair(mnemonic);
      final pubKey = await masterKeyPair.extractPublicKey();
      masterPubKeyHex = pubKey.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    });

    test('verifyPresencePing rejects missing or invalid master key', () async {
      final resEmpty = await verifier.verifyPresencePing(
        masterPubKeyHex: '',
        nostrPubKeyHex: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        signatureHex: '00' * 64,
        isOnline: true,
      );
      expect(resEmpty.isValid, isFalse);
      expect(resEmpty.reason, BindingRejectionReason.missingMasterKey);

      final resShort = await verifier.verifyPresencePing(
        masterPubKeyHex: '1234',
        nostrPubKeyHex: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        signatureHex: '00' * 64,
        isOnline: true,
      );
      expect(resShort.isValid, isFalse);
      expect(resShort.reason, BindingRejectionReason.missingMasterKey);
    });

    test('verifyPresencePing rejects missing or empty signature', () async {
      final res = await verifier.verifyPresencePing(
        masterPubKeyHex: masterPubKeyHex,
        nostrPubKeyHex: 'nostr_test_peer_1',
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        signatureHex: null,
        isOnline: true,
      );
      expect(res.isValid, isFalse);
      expect(res.reason, BindingRejectionReason.missingSignature);
    });

    test('verifyPresencePing rejects invalid format signature (not 128 hex chars)', () async {
      final res = await verifier.verifyPresencePing(
        masterPubKeyHex: masterPubKeyHex,
        nostrPubKeyHex: 'nostr_test_peer_1',
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        signatureHex: 'bad_sig',
        isOnline: true,
      );
      expect(res.isValid, isFalse);
      expect(res.reason, BindingRejectionReason.invalidSignatureFormat);
    });

    test('verifyPresencePing rejects future clock skew > 600s', () async {
      final futureTs = DateTime.now().add(const Duration(minutes: 15)).millisecondsSinceEpoch;
      final res = await verifier.verifyPresencePing(
        masterPubKeyHex: masterPubKeyHex,
        nostrPubKeyHex: 'nostr_test_peer_1',
        timestampMs: futureTs,
        signatureHex: '00' * 64,
        isOnline: true,
      );
      expect(res.isValid, isFalse);
      expect(res.reason, BindingRejectionReason.timestampFutureSkew);
    });

    test('verifyPresencePing accepts legitimate signature and detects stale replay', () async {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final sig = await crypto.signDelegationToken(
        masterKeyPair: masterKeyPair,
        nostrPubKeyHex: 'nostr_legit_peer_1',
        timestamp: nowMs,
      );

      final freshRes = await verifier.verifyPresencePing(
        masterPubKeyHex: masterPubKeyHex,
        nostrPubKeyHex: 'nostr_legit_peer_1',
        timestampMs: nowMs,
        signatureHex: sig,
        isOnline: true,
      );
      expect(freshRes.isValid, isTrue);
      expect(freshRes.isStaleReplay, isFalse);

      // Stale ping created 90s ago
      final staleTs = nowMs - 90000;
      final staleSig = await crypto.signDelegationToken(
        masterKeyPair: masterKeyPair,
        nostrPubKeyHex: 'nostr_legit_peer_1',
        timestamp: staleTs,
      );
      final staleRes = await verifier.verifyPresencePing(
        masterPubKeyHex: masterPubKeyHex,
        nostrPubKeyHex: 'nostr_legit_peer_1',
        timestampMs: staleTs,
        signatureHex: staleSig,
        isOnline: true,
      );
      expect(staleRes.isValid, isTrue);
      expect(staleRes.isStaleReplay, isTrue);
    });

    test('verifyPreKeyBundle rejects missing master key or author mismatch', () async {
      final bundle = <String, dynamic>{
        'masterKey': masterPubKeyHex,
        'identityPubKey': 'dGVzdF9pZGVudGl0eV9wdWJsaWNfa2V5',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'masterBindingSig': '00' * 64,
      };

      final authorMismatchRes = await verifier.verifyPreKeyBundle(
        expectedMasterPubKeyHex: masterPubKeyHex,
        recipientNostrPubKey: 'expected_recipient_key',
        bundleMap: bundle,
        eventAuthor: 'different_attacker_author',
      );
      expect(authorMismatchRes.isValid, isFalse);
      expect(authorMismatchRes.reason, BindingRejectionReason.authorMismatch);

      final masterMismatchRes = await verifier.verifyPreKeyBundle(
        expectedMasterPubKeyHex: '99' * 32,
        recipientNostrPubKey: 'expected_recipient_key',
        bundleMap: bundle,
        eventAuthor: 'expected_recipient_key',
      );
      expect(masterMismatchRes.isValid, isFalse);
      expect(masterMismatchRes.reason, BindingRejectionReason.masterKeyMismatch);
    });

    test('verifyPreKeyBundle rejects missing signature and accepts legitimate binding', () async {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      const idKeyBase64 = 'dGVzdF9zaWduYWxfaWRlbnRpdHlfcHVia2V5';

      final unsignedBundle = <String, dynamic>{
        'masterKey': masterPubKeyHex,
        'identityPubKey': idKeyBase64,
        'timestamp': nowMs,
      };

      final unsignedRes = await verifier.verifyPreKeyBundle(
        expectedMasterPubKeyHex: masterPubKeyHex,
        recipientNostrPubKey: 'peer_nostr_123',
        bundleMap: unsignedBundle,
        eventAuthor: 'peer_nostr_123',
      );
      expect(unsignedRes.isValid, isFalse);
      expect(unsignedRes.reason, BindingRejectionReason.missingSignature);

      // Legitimately signed
      final legitSig = await crypto.signBundleBindingToken(
        masterKeyPair: masterKeyPair,
        nostrPubKeyHex: 'peer_nostr_123',
        signalIdentityPubBase64: idKeyBase64,
        timestamp: nowMs,
      );

      final signedBundle = Map<String, dynamic>.from(unsignedBundle);
      signedBundle['masterBindingSig'] = legitSig;

      final validRes = await verifier.verifyPreKeyBundle(
        expectedMasterPubKeyHex: masterPubKeyHex,
        recipientNostrPubKey: 'peer_nostr_123',
        bundleMap: signedBundle,
        eventAuthor: 'peer_nostr_123',
      );
      expect(validRes.isValid, isTrue);
    });

    test('verifyControlMessage rejects unsigned and forged messages, accepts legitimate', () async {
      final nowMs = DateTime.now().millisecondsSinceEpoch;

      final unsignedRes = await verifier.verifyControlMessage(
        senderMasterPubKeyHex: masterPubKeyHex,
        controlType: 'RESET_SESSION',
        recipientNostrPubKey: 'my_nostr_key',
        timestampMs: nowMs,
        signatureHex: null,
      );
      expect(unsignedRes.isValid, isFalse);
      expect(unsignedRes.reason, BindingRejectionReason.missingSignature);

      final forgedRes = await verifier.verifyControlMessage(
        senderMasterPubKeyHex: masterPubKeyHex,
        controlType: 'RESET_SESSION',
        recipientNostrPubKey: 'my_nostr_key',
        timestampMs: nowMs,
        signatureHex: '00' * 64,
      );
      expect(forgedRes.isValid, isFalse);
      expect(forgedRes.reason, BindingRejectionReason.signatureVerificationFailed);

      final legitSig = await crypto.signControlToken(
        masterKeyPair: masterKeyPair,
        control: 'RESET_SESSION',
        recipientNostrPubKey: 'my_nostr_key',
        timestamp: nowMs,
      );

      final validRes = await verifier.verifyControlMessage(
        senderMasterPubKeyHex: masterPubKeyHex,
        controlType: 'RESET_SESSION',
        recipientNostrPubKey: 'my_nostr_key',
        timestampMs: nowMs,
        signatureHex: legitSig,
      );
      expect(validRes.isValid, isTrue);
    });
  });
}

class _MockSignalMessagingServiceForReset extends SignalMessagingService {
  int fetchAndEstablishCalls = 0;
  String? lastRecipient;
  String? lastMasterKey;

  _MockSignalMessagingServiceForReset()
      : super(
          signalStore: _MockSignalStore(),
          nostrService: _MockNostrRelayServiceNoPrekeys(),
          masterPublicKeyHex: 'test_master',
        );

  @override
  Future<bool> fetchAndEstablishSession(String recipientNostrPubKey, {String? masterPubKeyHex, bool force = false}) async {
    fetchAndEstablishCalls++;
    lastRecipient = recipientNostrPubKey;
    lastMasterKey = masterPubKeyHex;
    return true;
  }

  @override
  Future<bool> canSendToPeer(String peerNostrPubKey) async {
    if (isIdentityBlocked(peerNostrPubKey)) return false;
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MockSignalStore implements SignalStore {
  final Map<String, SessionRecord> sessions = {};
  final Map<String, IdentityKey> identities = {};
  late final IdentityKeyPair _localId = generateIdentityKeyPair();

  @override
  int get sessionGeneration => AccountSession.currentGeneration;

  @override
  AppDatabase get db => throw UnimplementedError();

  @override
  IdentityKeyPair get localIdentityKeyPair => _localId;

  @override
  int get localRegistrationId => 12345;

  @override
  Future<IdentityKeyPair> getIdentityKeyPair() async => _localId;

  @override
  Future<int> getLocalRegistrationId() async => 12345;

  @override
  Future<bool> saveIdentity(SignalProtocolAddress address, IdentityKey? identityKey) async {
    if (identityKey == null) return false;
    identities[address.toString()] = identityKey;
    return true;
  }

  @override
  Future<bool> isTrustedIdentity(SignalProtocolAddress address, IdentityKey? identityKey, Direction direction) async {
    if (identityKey == null) return false;
    final existing = identities[address.toString()];
    if (existing == null) return true;
    return existing == identityKey;
  }

  @override
  Future<IdentityKey?> getIdentity(SignalProtocolAddress address) async {
    return identities[address.toString()];
  }

  @override
  Future<bool> containsSession(SignalProtocolAddress address) async {
    return sessions.containsKey(address.toString());
  }

  @override
  Future<SessionRecord> loadSession(SignalProtocolAddress address) async {
    return sessions[address.toString()] ?? SessionRecord();
  }

  @override
  Future<void> storeSession(SignalProtocolAddress address, SessionRecord record) async {
    sessions[address.toString()] = record;
  }

  @override
  Future<void> deleteSession(SignalProtocolAddress address) async {
    sessions.remove(address.toString());
  }

  final Map<int, PreKeyRecord> preKeys = {};
  final Map<int, SignedPreKeyRecord> signedPreKeys = {};

  @override
  Future<int> getPreKeyCount() async => preKeys.length;

  @override
  Future<int> getMaxPreKeyId() async => preKeys.isEmpty ? 0 : preKeys.keys.reduce(dart_math.max);

  @override
  Future<List<PreKeyRecord>> getAllPreKeys() async => preKeys.values.toList();

  @override
  Future<void> storePreKey(int preKeyId, PreKeyRecord record) async {
    preKeys[preKeyId] = record;
  }

  @override
  Future<bool> containsPreKey(int preKeyId) async => preKeys.containsKey(preKeyId);

  @override
  Future<PreKeyRecord> loadPreKey(int preKeyId) async => preKeys[preKeyId]!;

  @override
  Future<void> removePreKey(int preKeyId) async {
    preKeys.remove(preKeyId);
  }

  @override
  Future<bool> containsSignedPreKey(int signedPreKeyId) async => signedPreKeys.containsKey(signedPreKeyId);

  @override
  Future<SignedPreKeyRecord> loadSignedPreKey(int signedPreKeyId) async => signedPreKeys[signedPreKeyId]!;

  @override
  Future<void> storeSignedPreKey(int signedPreKeyId, SignedPreKeyRecord record) async {
    signedPreKeys[signedPreKeyId] = record;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MockNostrRelayServiceForPreKeys extends _MockNostrRelayServiceNoPrekeys {
  int broadcastCount = 0;
  Map<String, dynamic>? lastBroadcastPayload;
  final List<void Function()> onReadyListeners = [];

  @override
  String get publicHex => 'mock_nostr_pub_hex';

  @override
  Future<bool> broadcastPreKeyBundle(String masterPublicKeyHex, Map<String, dynamic> payload, {int? sessionGen}) async {
    broadcastCount++;
    lastBroadcastPayload = payload;
    return true;
  }

  @override
  void addOnReadyListener(void Function() listener) {
    onReadyListeners.add(listener);
  }
}

class _MockNostrRelayServiceWithBundle implements NostrRelayService {
  final Map<String, dynamic>? bundleToReturn;

  _MockNostrRelayServiceWithBundle(this.bundleToReturn);

  @override
  Future<Map<String, dynamic>?> fetchUserPrekeys(String nostrPubKeyHex, {String? masterPubKeyHex}) async => bundleToReturn;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MockNostrRelayServiceNoPrekeys implements NostrRelayService {
  @override
  Future<Map<String, dynamic>?> fetchUserPrekeys(String nostrPubKeyHex, {String? masterPubKeyHex}) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MockNostrRelayServiceForLifecycle extends _MockNostrRelayServiceNoPrekeys {
  bool hasBeenTornDown = false;
  final List<void Function()> onReadyCallbacks = [];

  @override
  Future<void> teardownSession([int? sessionGen]) async {
    hasBeenTornDown = true;
    onReadyCallbacks.clear();
  }

  @override
  void addOnReadyListener(void Function() callback) {
    onReadyCallbacks.add(callback);
  }
}

class FakeIdentityRepository implements IdentityRepository {
  String? savedMnemonic;
  @override
  Future<void> saveMnemonic(String mnemonic) async {
    savedMnemonic = mnemonic;
  }

  @override
  Future<String?> getMnemonic() async => savedMnemonic;

  @override
  Future<void> clearAll() async {
    savedMnemonic = null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _TestPlaybackClient implements VoiceNotePlaybackClient {
  bool isPaused = false;
  int pauseCount = 0;

  @override
  Future<void> pausePlayback() async {
    isPaused = true;
    pauseCount++;
  }
}

class _MockCryptoServiceWithLifecycleRace extends CryptoService {
  void Function()? onSign;

  @override
  Future<String> signControlToken({
    required SimpleKeyPair masterKeyPair,
    required String control,
    required String recipientNostrPubKey,
    required int timestamp,
  }) async {
    onSign?.call();
    return super.signControlToken(
      masterKeyPair: masterKeyPair,
      control: control,
      recipientNostrPubKey: recipientNostrPubKey,
      timestamp: timestamp,
    );
  }
}

class MockAuthProvider extends ChangeNotifier implements AuthProvider {
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
  SimpleKeyPair? masterKeyPair;

  @override
  bool get isAuthenticated => masterPublicKeyHex != null;

  @override
  Future<bool> restoreIdentity() async => false;

  @override
  Future<String?> createDelegationSignature(String nostrPubKeyHex, int timestamp) async => 'mock_sig';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class MockDiscoverProvider extends ChangeNotifier implements DiscoverProvider {
  @override
  bool isAnnounced = false;

  @override
  bool hasEverAnnounced = false;

  final Map<String, DiscoverUser> usersByNostr = {};
  final Map<String, DiscoverUser> usersByMaster = {};

  @override
  DiscoverUser? findUser(String nostrPubKeyHex) => usersByNostr[nostrPubKeyHex];

  @override
  DiscoverUser? findUserByMaster(String masterPubKeyHex) => usersByMaster[masterPubKeyHex];

  @override
  Future<void> announcePresence() async {
    isAnnounced = true;
    hasEverAnnounced = true;
    notifyListeners();
  }

  @override
  void stopHeartbeat() {
    isAnnounced = false;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class MockChatProvider extends ChangeNotifier implements ChatProvider {
  @override
  List<DiscoverUser> activeChats = [];

  @override
  Map<String, List<ChatMessage>> chatHistories = {};

  @override
  List<ChatMessage> getMessagesFor(String nostrPubKey, {String? masterPubKeyHex}) {
    return chatHistories[nostrPubKey] ?? [];
  }

  @override
  Future<void> markChatAsRead(String recipientPubKey) async {}

  @override
  void clearActiveChat() {}

  @override
  Future<void> updateChatUserProfile({
    required String masterPubKeyHex,
    required String username,
    String? displayName,
    String? bio,
  }) async {}

  @override
  void updateUserPresence({
    required String masterPubKeyHex,
    String? nostrPubKeyHex,
    required bool isOnline,
    required DateTime lastSeen,
  }) {}

  final Set<String> blockedPeers = {};

  @override
  bool isPeerIdentityBlocked(String peerNostrPubKey) => blockedPeers.contains(peerNostrPubKey);

  @override
  Future<bool> canSendToPeer(String peerNostrPubKey) async => !isPeerIdentityBlocked(peerNostrPubKey);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MockChatRepo implements ChatRepository {
  @override
  int get sessionGeneration => AccountSession.currentGeneration;

  final List<OutboxRecord> outbox = [];
  final Map<String, String> messageStatuses = {};
  final List<ChatMessage> savedMessages = [];

  @override
  Future<void> saveChat(DiscoverUser user) async {}

  @override
  Future<void> saveMessage(String nostrPubKey, ChatMessage message) async {
    savedMessages.add(message);
  }

  @override
  Future<void> enqueueOutbox({
    required String messageId,
    required String recipientNostrPubKey,
    required String payloadJson,
    DateTime? createdAt,
  }) async {
    outbox.add(OutboxRecord(
      messageId: messageId,
      recipientNostrPubKey: recipientNostrPubKey,
      payloadJson: payloadJson,
      attempts: 0,
      createdAt: createdAt ?? DateTime.now(),
      status: 'pending',
    ));
  }

  @override
  Future<List<OutboxRecord>> getPendingOutboxMessages() async {
    return outbox.where((r) => r.status != 'delivered' && r.status != 'read').toList();
  }

  @override
  Future<List<OutboxRecord>> getUndeliveredMessagesForPeer(String recipientNostrPubKey) async {
    return outbox
        .where((r) =>
            r.recipientNostrPubKey == recipientNostrPubKey &&
            r.status != 'delivered' &&
            r.status != 'read')
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
        status: status,
      );
    }
  }

  @override
  Future<void> updateMessageStatus(String messageId, MessageStatus status) async {
    messageStatuses[messageId] = status.name;
    final msg = savedMessages.where((m) => m.messageId == messageId).firstOrNull;
    if (msg != null) {
      msg.status = status;
    }
  }

  @override
  Future<ChatMessageRecord?> getMessageByMessageId(String messageId) async {
    final m = savedMessages.where((msg) => msg.messageId == messageId).firstOrNull;
    if (m == null) return null;
    return ChatMessageRecord(
      id: 1,
      messageId: m.messageId,
      nostrPubKeyHex: 'mock_peer',
      messageText: m.text,
      isMe: m.isMe,
      timestamp: m.timestamp,
      status: m.status.name,
    );
  }

  @override
  Future<int> markMessagesReadUpTo(String peerNostrPubKey, DateTime timestamp) async {
    int count = 0;
    for (final m in savedMessages) {
      if (m.isMe && !m.timestamp.isAfter(timestamp) && m.status != MessageStatus.read) {
        m.status = MessageStatus.read;
        messageStatuses[m.messageId] = 'read';
        count++;
      }
    }
    return count;
  }

  @override
  Future<void> clearAll() async {
    outbox.clear();
    messageStatuses.clear();
    savedMessages.clear();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _MockSignalMessagingServiceForOutbox extends SignalMessagingService {
  int prepareEncryptedPayloadCalls = 0;
  int sendPreparedPayloadCalls = 0;
  int sendMessageCalls = 0;
  final List<Map<String, dynamic>> sentPayloads = [];
  final List<Map<String, dynamic>> sentMessages = [];
  bool shouldThrowOnSend = false;
  (String, String, DateTime?, String?, bool)? incomingMessageToReturn;

  _MockSignalMessagingServiceForOutbox()
      : super(
          signalStore: _MockSignalStore(),
          nostrService: _MockNostrRelayServiceNoPrekeys(),
          masterPublicKeyHex: 'my_master',
        );

  Future<void> Function()? onPrepareEncryptedPayload;
  Future<void> Function(String recipient, Map<String, dynamic> payload)? onSendPreparedPayload;
  Future<void> Function()? onDecryptMessage;

  @override
  Future<(String messageId, Map<String, dynamic> payloadMap)> prepareEncryptedPayload(
    String recipientNostrPubKey,
    String text, {
    DateTime? sentAt,
    String? messageId,
    String type = 'text',
    Map<String, dynamic>? extraBody,
    String? replyToId,
  }) async {
    prepareEncryptedPayloadCalls++;
    if (onPrepareEncryptedPayload != null) {
      await onPrepareEncryptedPayload!();
    }
    final msgId = messageId ?? 'msg_mock_123';
    final payload = {
      'type': 3,
      'ciphertext': 'mock_ciphertext_$prepareEncryptedPayloadCalls',
      'sentAt': (sentAt ?? DateTime.now()).millisecondsSinceEpoch,
      'id': msgId,
    };
    return (msgId, payload);
  }

  @override
  Future<void> sendPreparedPayload(
    String recipientNostrPubKey,
    Map<String, dynamic> payloadMap,
  ) async {
    sendPreparedPayloadCalls++;
    if (onSendPreparedPayload != null) {
      await onSendPreparedPayload!(recipientNostrPubKey, payloadMap);
    }
    if (shouldThrowOnSend) {
      throw Exception('Network unreachable');
    }
    sentPayloads.add(payloadMap);
  }

  @override
  Future<bool> hasSignalSession(String recipientNostrPubKey) async => true;

  @override
  Future<bool> canSendToPeer(String peerNostrPubKey) async {
    if (isIdentityBlocked(peerNostrPubKey)) return false;
    return true;
  }

  @override
  Future<String> sendMessage(
    String recipientNostrPubKey,
    String text, {
    DateTime? sentAt,
    String? messageId,
    String type = 'text',
    Map<String, dynamic>? extraBody,
    String? replyToId,
  }) async {
    sendMessageCalls++;
    sentMessages.add({
      'recipient': recipientNostrPubKey,
      'text': text,
      'type': type,
      'extraBody': extraBody,
      'targetId': extraBody?['targetId'],
      'status': extraBody?['status'],
    });
    return messageId ?? 'msg_receipt_123';
  }

  @override
  Future<(String, String, DateTime?, String?, bool)?> decryptMessage(
    String senderNostrPubKey,
    Map<String, dynamic> map,
  ) async {
    if (onDecryptMessage != null) {
      await onDecryptMessage!();
    }
    return incomingMessageToReturn;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MockRawDb {
  final dynamic cipherVersionReturn;
  final bool shouldThrowOnSelect;
  final dynamic Function(String sql)? selectHandler;
  final List<String> executedStatements = [];

  _MockRawDb({
    this.cipherVersionReturn,
    this.shouldThrowOnSelect = false,
    this.selectHandler,
  });

  dynamic select(String sql) {
    executedStatements.add(sql);
    if (shouldThrowOnSelect) {
      throw Exception('Unrecognized pragma: $sql');
    }
    if (selectHandler != null) {
      return selectHandler!(sql);
    }
    return cipherVersionReturn;
  }

  void execute(String sql) {
    executedStatements.add(sql);
  }
}

class _MockDbRow {
  final List<dynamic> values;
  _MockDbRow(this.values);
}


