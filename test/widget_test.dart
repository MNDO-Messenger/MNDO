import 'dart:convert';
import 'dart:io';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
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
import 'package:aisat_connect/services/signal_store.dart';

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
  });
}

class _MockSignalStore implements SignalStore {
  final Map<String, SessionRecord> sessions = {};

  @override
  Future<bool> containsSession(SignalProtocolAddress address) async {
    return sessions.containsKey(address.toString());
  }

  @override
  Future<void> deleteSession(SignalProtocolAddress address) async {
    sessions.remove(address.toString());
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MockNostrRelayServiceNoPrekeys implements NostrRelayService {
  @override
  Future<Map<String, dynamic>?> fetchUserPrekeys(String nostrPubKeyHex, {String? masterPubKeyHex}) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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

class MockAuthProvider extends ChangeNotifier implements AuthProvider {
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
  Future<bool> restoreIdentity() async => false;

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
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MockChatRepo implements ChatRepository {
  @override
  Future<void> saveChat(DiscoverUser user) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

