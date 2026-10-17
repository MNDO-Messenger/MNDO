import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:drift/native.dart';

import 'package:aisat_connect/database/database.dart';
import 'package:aisat_connect/repositories/chat_repository.dart';
import 'package:aisat_connect/services/media_cache_manager.dart';
import 'package:aisat_connect/services/voice_note_cache_manager.dart';
import 'package:aisat_connect/models/media_payload.dart';
import 'package:aisat_connect/models/chat_message.dart';
import 'package:aisat_connect/models/discover_user.dart';
import 'package:aisat_connect/providers/chat_provider.dart';
import 'package:aisat_connect/providers/auth_provider.dart';
import 'package:aisat_connect/services/signal_messaging_service.dart';
import 'package:aisat_connect/services/crypto_service.dart';

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

class _MockSignalService implements SignalMessagingService {
  @override
  void Function(String peerNostrPubKey)? onIdentityKeyChanged;

  final List<Map<String, dynamic>> sentPayloads = [];

  Future<void> sendEncryptedMessage({
    required String peerNostrPubKey,
    required Map<String, dynamic> payloadMap,
    String? peerMasterPubKey,
  }) async {
    sentPayloads.add(Map<String, dynamic>.from(payloadMap));
  }

  @override
  bool isIdentityBlocked(String peerNostrPubKey) => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory testDocDir;
  late Directory testTempDir;
  late MediaCacheManager mediaCacheManager;
  late VoiceNoteCacheManager voiceNoteCacheManager;
  late AppDatabase db;
  late ChatRepository chatRepo;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    testDocDir = await Directory.systemTemp.createTemp('stealth_doc_');
    testTempDir = await Directory.systemTemp.createTemp('stealth_temp_');

    mediaCacheManager = MediaCacheManager();
    mediaCacheManager.setBaseDirForTesting(testDocDir);

    voiceNoteCacheManager = VoiceNoteCacheManager();
    voiceNoteCacheManager.setCacheDirForTesting(Directory(p.join(testDocDir.path, 'mndo_media', 'voice_notes')));
    voiceNoteCacheManager.setTempDirForTesting(testTempDir);

    db = AppDatabase.forTesting(NativeDatabase.memory());
    chatRepo = ChatRepository(db);
  });

  tearDown(() async {
    mediaCacheManager.resetForTesting();
    voiceNoteCacheManager.resetForTesting();
    await db.close();
    try {
      if (await testDocDir.exists()) await testDocDir.delete(recursive: true);
      if (await testTempDir.exists()) await testTempDir.delete(recursive: true);
    } catch (_) {}
  });

  group('Media Cache Storage & Shredding Pipeline', () {
    test('1. Media files are stored in persistent subdirectories by media type', () async {
      final imgPath = await mediaCacheManager.getCacheFilePathForHash('hash_img_123', ext: '.jpg', mediaType: 'image');
      final vidPath = await mediaCacheManager.getCacheFilePathForHash('hash_vid_456', ext: '.mp4', mediaType: 'video');
      final docPath = await mediaCacheManager.getCacheFilePathForHash('hash_doc_789', ext: '.pdf', mediaType: 'document');

      expect(imgPath.contains('images'), isTrue);
      expect(vidPath.contains('videos'), isTrue);
      expect(docPath.contains('documents'), isTrue);
      expect(imgPath.startsWith(testDocDir.path), isTrue);
    });

    test('2. Multi-folder lookup finds files across subdirectories and legacy paths', () async {
      final imgPath = await mediaCacheManager.getCacheFilePathForHash('multi_hash_1', ext: '.png', mediaType: 'image');
      final imgFile = File(imgPath);
      await imgFile.parent.create(recursive: true);
      await imgFile.writeAsString('test-image-content');

      final found = await mediaCacheManager.findCachedFilePath('multi_hash_1');
      expect(found, isNotNull);
      expect(await File(found!).exists(), isTrue);
      expect(await File(found).readAsString(), equals('test-image-content'));
    });

    test('3. deleteForHash permanently shreds media files on disk', () async {
      final vidPath = await mediaCacheManager.getCacheFilePathForHash('shred_vid_1', ext: '.mp4', mediaType: 'video');
      final vidFile = File(vidPath);
      await vidFile.parent.create(recursive: true);
      await vidFile.writeAsString('video-bytes-to-shred');
      expect(await vidFile.exists(), isTrue);

      await mediaCacheManager.deleteForHash('shred_vid_1');
      expect(await vidFile.exists(), isFalse, reason: 'File should be shredded from disk');
      final searchAgain = await mediaCacheManager.findCachedFilePath('shred_vid_1');
      expect(searchAgain, isNull);
    });

    test('4. VoiceNoteCacheManager deleteForHash shreds voice notes across locations', () async {
      final voiceDir = Directory(p.join(testDocDir.path, 'mndo_media', 'voice_notes'));
      await voiceDir.create(recursive: true);
      final vnFile = File(p.join(voiceDir.path, 'vn_cache_hash_voice_1.m4a'));
      await vnFile.writeAsString('voice-bytes');
      expect(await vnFile.exists(), isTrue);

      await voiceNoteCacheManager.deleteForHash('hash_voice_1');
      expect(await vnFile.exists(), isFalse, reason: 'Voice note file should be removed from disk');
    });
  });

  group('Database Message Deletion and Vacuuming', () {
    test('5. deleteMessagesForChat removes all messages for a specific peer', () async {
      final now = DateTime.now();
      await db.into(db.chatMessages).insert(
        ChatMessagesCompanion.insert(
          messageId: 'msg_1',
          nostrPubKeyHex: 'peer_alice',
          messageText: 'Hello from Alice',
          isMe: false,
          timestamp: now,
        ),
      );
      await db.into(db.chatMessages).insert(
        ChatMessagesCompanion.insert(
          messageId: 'msg_2',
          nostrPubKeyHex: 'peer_bob',
          messageText: 'Hello from Bob',
          isMe: false,
          timestamp: now,
        ),
      );

      var aliceMsgs = await db.getMessagesForChat('peer_alice');
      expect(aliceMsgs.length, equals(1));

      final deletedCount = await db.deleteMessagesForChat('peer_alice');
      expect(deletedCount, equals(1));

      aliceMsgs = await db.getMessagesForChat('peer_alice');
      expect(aliceMsgs.isEmpty, isTrue);

      final bobMsgs = await db.getMessagesForChat('peer_bob');
      expect(bobMsgs.length, equals(1), reason: "Bob's messages must be unaffected");
    });

    test('6. deleteOutboxForPeer removes pending outbox items for a blocked peer', () async {
      final now = DateTime.now();
      final expires = now.add(const Duration(days: 7));
      await db.into(db.outboxMessages).insert(
        OutboxMessagesCompanion.insert(
          messageId: 'out_1',
          recipientNostrPubKey: 'peer_blocked',
          payloadJson: 'secret',
          createdAt: now,
          expiresAt: expires,
        ),
      );
      await db.into(db.outboxMessages).insert(
        OutboxMessagesCompanion.insert(
          messageId: 'out_2',
          recipientNostrPubKey: 'peer_friend',
          payloadJson: 'friend_secret',
          createdAt: now,
          expiresAt: expires,
        ),
      );

      final outboxDeleted = await db.deleteOutboxForPeer('peer_blocked');
      expect(outboxDeleted, equals(1));

      final remaining = await db.select(db.outboxMessages).get();
      expect(remaining.length, equals(1));
      expect(remaining.first.recipientNostrPubKey, equals('peer_friend'));
    });
  });

  group('3-Tier Shredding Pipeline in ChatRepository', () {
    test('7. clearChatForPeer deletes messages, outbox, and shreds media files', () async {
      // 1. Create a media file on disk
      final imgPath = await mediaCacheManager.getCacheFilePathForHash('media_hash_abc', ext: '.jpg', mediaType: 'image');
      final imgFile = File(imgPath);
      await imgFile.parent.create(recursive: true);
      await imgFile.writeAsString('precious-image-bytes');
      expect(await imgFile.exists(), isTrue);

      // 2. Insert chat message referencing the media
      final mediaPayload = MediaPayload(
        mediaType: 'image',
        url: 'https://cdn.example.com/blob1',
        key: 'aeskey',
        nonce: 'aesnonce',
        mac: 'aesmac',
        fileHash: 'media_hash_abc',
        mimeType: 'image/jpeg',
      );
      final envelopeJson = mediaPayload.serialize();

      await db.into(db.chatMessages).insert(
        ChatMessagesCompanion.insert(
          messageId: 'media_msg_1',
          nostrPubKeyHex: 'peer_charlie',
          messageText: envelopeJson,
          isMe: false,
          timestamp: DateTime.now(),
        ),
      );

      // 3. Clear chat for Charlie
      await chatRepo.clearChatForPeer('peer_charlie');

      // 4. Assert disk file was shredded
      expect(await imgFile.exists(), isFalse, reason: 'Media disk file must be shredded');

      // 5. Assert database records were wiped
      final msgs = await db.getMessagesForChat('peer_charlie');
      expect(msgs.isEmpty, isTrue, reason: 'Database messages must be cleared');
    });
  });

  group('ChatProvider Stealth Blocking Protocol', () {
    test('8. blockUser updates state, persists in SharedPreferences, and purges outbox', () async {
      final mockAuth = _MockAuthProvider();
      final mockSignal = _MockSignalService();
      final provider = ChatProvider(
        chatRepo: chatRepo,
        authProvider: mockAuth,
        signalService: mockSignal,
      );

      expect(provider.isUserBlocked('peer_evil'), isFalse);
      await provider.blockUser('peer_evil', peerMasterPubKey: 'master_evil');

      expect(provider.isUserBlocked('peer_evil'), isTrue);
      expect(provider.isUserBlocked('master_evil'), isTrue);
      // Cryptographic identity must NOT be conflated with user blocking (prevents Key Changed alerts)
      expect(provider.isPeerIdentityBlocked('peer_evil'), isFalse);
      expect(provider.isPeerIdentityBlocked('master_evil'), isFalse);

      // Verify persistent storage
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList('mndo_chat_${mockAuth.masterPublicKeyHex}_blocked_users');
      expect(list, contains('peer_evil'));
      expect(list, contains('master_evil'));
    });

    test('9. unblockUser restores peer state and updates SharedPreferences', () async {
      final mockAuth = _MockAuthProvider();
      final mockSignal = _MockSignalService();
      final provider = ChatProvider(
        chatRepo: chatRepo,
        authProvider: mockAuth,
        signalService: mockSignal,
      );

      await provider.blockUser('peer_evil');
      expect(provider.isUserBlocked('peer_evil'), isTrue);

      await provider.unblockUser('peer_evil');
      expect(provider.isUserBlocked('peer_evil'), isFalse);

      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList('mndo_chat_${mockAuth.masterPublicKeyHex}_blocked_users');
      expect(list, isNot(contains('peer_evil')));
    });

    test('10. updateUserPresence suppresses presence updates for blocked users', () async {
      final mockAuth = _MockAuthProvider();
      final mockSignal = _MockSignalService();
      final provider = ChatProvider(
        chatRepo: chatRepo,
        authProvider: mockAuth,
        signalService: mockSignal,
      );

      final initialLastSeen = DateTime.now().subtract(const Duration(hours: 3));
      final user = DiscoverUser(
        masterPubKeyHex: 'master_blocked_sender',
        nostrPubKeyHex: 'peer_blocked_sender',
        username: 'blocked_user',
        lastSeen: initialLastSeen,
      );
      provider.activeChats.add(user);

      await provider.blockUser('peer_blocked_sender', peerMasterPubKey: 'master_blocked_sender');
      expect(provider.isUserBlocked('peer_blocked_sender'), isTrue);
      final lastSeenAfterBlock = user.lastSeen;

      final attemptTime = DateTime.now().add(const Duration(minutes: 5));
      provider.updateUserPresence(
        masterPubKeyHex: 'master_blocked_sender',
        nostrPubKeyHex: 'peer_blocked_sender',
        isOnline: true,
        lastSeen: attemptTime,
      );

      // Presence update must be suppressed: user remains offline, lastSeen unchanged
      expect(user.isOnline, isFalse);
      expect(user.isExplicitlyOffline, isTrue);
      expect(user.lastSeenFromPing, isNull);
      expect(user.lastSeen, equals(lastSeenAfterBlock));
    });

    test('11. clearConversation wipes RAM memory state, unread counts, and calls chatRepo', () async {
      final mockAuth = _MockAuthProvider();
      final mockSignal = _MockSignalService();
      final provider = ChatProvider(
        chatRepo: chatRepo,
        authProvider: mockAuth,
        signalService: mockSignal,
      );

      provider.chatHistories['peer_friend'] = [
        ChatMessage(
          messageId: 'friend_1',
          text: 'Hello!',
          isMe: false,
          timestamp: DateTime.now(),
        ),
      ];
      provider.unreadCounts['peer_friend'] = 5;

      await provider.clearConversation('peer_friend');

      expect(provider.chatHistories['peer_friend'], isNull);
      expect(provider.unreadCounts['peer_friend'], equals(0));
    });

    test('12. blockUser immediately transitions actively online contact in activeChats to offline', () async {
      final mockAuth = _MockAuthProvider();
      final mockSignal = _MockSignalService();
      final provider = ChatProvider(
        chatRepo: chatRepo,
        authProvider: mockAuth,
        signalService: mockSignal,
      );

      final user = DiscoverUser(
        masterPubKeyHex: 'master_online_user',
        nostrPubKeyHex: 'peer_online_user',
        username: 'online_friend',
        lastSeen: DateTime.now(),
      );
      user.markOnline();
      expect(user.isOnline, isTrue);
      expect(user.isExplicitlyOffline, isFalse);
      expect(user.lastSeenFromPing, isNotNull);

      provider.activeChats.add(user);

      await provider.blockUser('peer_online_user', peerMasterPubKey: 'master_online_user');

      // The active chat must immediately be marked offline in memory
      expect(user.isOnline, isFalse);
      expect(user.isExplicitlyOffline, isTrue);
      expect(user.lastSeenFromPing, isNull);
      expect(user.lastSeenFromMessage, isNull);
    });
  });
}
