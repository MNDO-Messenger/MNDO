import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/database.dart';
import '../repositories/chat_repository.dart';
import '../repositories/identity_repository.dart';
import '../services/crypto_service.dart';
import '../services/nostr_relay_service.dart';
import '../services/signal_messaging_service.dart';
import '../services/signal_store.dart';
import '../providers/auth_provider.dart';
import '../providers/chat_provider.dart';
import '../providers/discover_provider.dart';
import '../providers/theme_provider.dart';

/// Database and Repository Providers
final appDatabaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(() => db.close());
  return db;
});

final identityRepositoryProvider = Provider<IdentityRepository>((ref) {
  return IdentityRepository();
});

final cryptoServiceProvider = Provider<CryptoService>((ref) {
  return CryptoService();
});

final chatRepositoryProvider = Provider<ChatRepository>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return ChatRepository(db);
});

/// Theme Notifier Provider
final themeNotifierProvider = ChangeNotifierProvider<ThemeProvider>((ref) {
  return ThemeProvider();
});

/// Auth Notifier Provider
final authNotifierProvider = ChangeNotifierProvider<AuthProvider>((ref) {
  final identityRepo = ref.watch(identityRepositoryProvider);
  final crypto = ref.watch(cryptoServiceProvider);
  return AuthProvider(
    identityRepo: identityRepo,
    cryptoService: crypto,
  );
});

/// Signal Store Provider
final signalStoreProvider = Provider<SignalStore?>((ref) {
  final isAuth = ref.watch(authNotifierProvider.select((a) => a.isAuthenticated));
  final keyPair = ref.watch(authNotifierProvider.select((a) => a.signalIdentityKeyPair));
  final regId = ref.watch(authNotifierProvider.select((a) => a.signalRegistrationId));
  final db = ref.watch(appDatabaseProvider);
  if (isAuth && keyPair != null && regId != null) {
    return SignalStore(db, keyPair, regId);
  }
  return null;
});

/// Signal Messaging Service Provider
final signalMessagingServiceProvider = Provider<SignalMessagingService?>((ref) {
  final store = ref.watch(signalStoreProvider);
  final masterPubKeyHex = ref.watch(authNotifierProvider.select((a) => a.masterPublicKeyHex));
  if (store != null && masterPubKeyHex != null) {
    return SignalMessagingService(
      signalStore: store,
      nostrService: NostrRelayService(),
      masterPublicKeyHex: masterPubKeyHex,
    );
  }
  return null;
});

/// Chat Notifier Provider
final chatNotifierProvider = ChangeNotifierProvider<ChatProvider>((ref) {
  final repo = ref.watch(chatRepositoryProvider);
  final auth = ref.watch(authNotifierProvider.notifier);
  final initialSignal = ref.read(signalMessagingServiceProvider);

  final chatProvider = ChatProvider(
    chatRepo: repo,
    authProvider: auth,
    signalService: initialSignal,
  );

  // Update dependencies when signalMessagingService becomes ready upon login
  ref.listen<SignalMessagingService?>(signalMessagingServiceProvider, (_, nextSignal) {
    chatProvider.updateDependencies(repo, auth, nextSignal);
  });

  return chatProvider;
});

/// Discover Notifier Provider
final discoverNotifierProvider = ChangeNotifierProvider<DiscoverProvider>((ref) {
  final auth = ref.watch(authNotifierProvider.notifier);
  final chat = ref.watch(chatNotifierProvider.notifier);
  final crypto = ref.watch(cryptoServiceProvider);
  final initialSignal = ref.read(signalMessagingServiceProvider);

  final discoverProvider = DiscoverProvider(
    authProvider: auth,
    chatProvider: chat,
    signalService: initialSignal,
    cryptoService: crypto,
  );

  // Update dependencies when signalMessagingService becomes ready upon login
  ref.listen<SignalMessagingService?>(signalMessagingServiceProvider, (_, nextSignal) {
    discoverProvider.updateDependencies(auth, chat, nextSignal, crypto);
  });

  return discoverProvider;
});

