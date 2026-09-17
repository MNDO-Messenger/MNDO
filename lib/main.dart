import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:window_manager/window_manager.dart';

import 'database/database.dart';
import 'repositories/chat_repository.dart';
import 'repositories/identity_repository.dart';
import 'services/crypto_service.dart';
import 'services/nostr_relay_service.dart';
import 'services/signal_messaging_service.dart';
import 'services/signal_store.dart';
import 'providers/auth_provider.dart';
import 'providers/chat_provider.dart';
import 'providers/discover_provider.dart';
import 'providers/theme_provider.dart';

import 'ui/onboarding_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await windowManager.ensureInitialized();
    WindowOptions windowOptions = const WindowOptions(
      size: Size(800, 600),
      center: true,
      backgroundColor: Colors.transparent,
      skipTaskbar: false,
      titleBarStyle: TitleBarStyle.normal,
    );
    windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.setPreventClose(true); // We will intercept the close event!
      await windowManager.show();
      await windowManager.focus();
    });
  }

  runApp(
    MultiProvider(
      providers: [
        Provider<AppDatabase>(create: (_) => AppDatabase()),
        Provider<IdentityRepository>(create: (_) => IdentityRepository()),
        Provider<CryptoService>(create: (_) => CryptoService()),
        ChangeNotifierProvider<ThemeProvider>(create: (_) => ThemeProvider()),
        
        ProxyProvider<AppDatabase, ChatRepository>(
          update: (_, db, __) => ChatRepository(db),
        ),
        
        ChangeNotifierProxyProvider2<IdentityRepository, CryptoService, AuthProvider>(
          create: (ctx) => AuthProvider(
            identityRepo: ctx.read<IdentityRepository>(),
            cryptoService: ctx.read<CryptoService>(),
          ),
          update: (_, identityRepo, cryptoService, previous) => previous!, 
        ),
        
        ProxyProvider2<AuthProvider, AppDatabase, SignalStore?>(
          update: (_, auth, db, previous) {
            if (auth.isAuthenticated && auth.signalIdentityKeyPair != null && auth.signalRegistrationId != null) {
               if (previous != null && previous.localRegistrationId == auth.signalRegistrationId) {
                 return previous;
               }
               return SignalStore(
                 db, 
                 auth.signalIdentityKeyPair!, 
                 auth.signalRegistrationId!
               );
            }
            return null;
          }
        ),
        
        ProxyProvider2<SignalStore?, AuthProvider, SignalMessagingService?>(
          update: (_, store, auth, previous) {
            if (store != null && auth.masterPublicKeyHex != null) {
              if (previous != null && previous.masterPublicKeyHex == auth.masterPublicKeyHex && previous.signalStore == store) {
                return previous;
              }
              return SignalMessagingService(
                signalStore: store,
                nostrService: NostrRelayService(), 
                masterPublicKeyHex: auth.masterPublicKeyHex!,
              );
            }
            return null;
          }
        ),
        
        ChangeNotifierProxyProvider3<ChatRepository, AuthProvider, SignalMessagingService?, ChatProvider>(
          create: (ctx) => ChatProvider(
            chatRepo: ctx.read<ChatRepository>(),
            authProvider: ctx.read<AuthProvider>(),
            signalService: ctx.read<SignalMessagingService?>(),
          ),
          update: (_, repo, auth, signal, previous) => previous!..updateDependencies(repo, auth, signal),
        ),

        ChangeNotifierProxyProvider4<AuthProvider, ChatProvider, SignalMessagingService?, CryptoService, DiscoverProvider>(
          create: (ctx) => DiscoverProvider(
            authProvider: ctx.read<AuthProvider>(),
            chatProvider: ctx.read<ChatProvider>(),
            signalService: ctx.read<SignalMessagingService?>(),
            cryptoService: ctx.read<CryptoService>(),
          ),
          update: (_, auth, chat, signal, crypto, previous) => previous!..updateDependencies(auth, chat, signal, crypto),
        ),
      ],
      child: const AisatConnectApp(),
    ),
  );
}

class AisatConnectApp extends StatefulWidget {
  const AisatConnectApp({super.key});

  @override
  State<AisatConnectApp> createState() => _AisatConnectAppState();
}

class _AisatConnectAppState extends State<AisatConnectApp> with WidgetsBindingObserver, WindowListener {

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      windowManager.addListener(this);
    }
    NostrRelayService().connectToRelays();
    NostrRelayService().initConnectionListeners();
    
    // Automatically start listening for messages if already authenticated
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final auth = context.read<AuthProvider>();
      if (auth.isAuthenticated) {
        context.read<ChatProvider>().startListeningForMessages();
        
        final signal = context.read<SignalMessagingService?>();
        if (signal != null && auth.signalIdentityKeyPair != null && auth.signalRegistrationId != null) {
          signal.generateAndBroadcastPreKeys(auth.signalIdentityKeyPair!, auth.signalRegistrationId!);
        }
      }
    });
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      windowManager.removeListener(this);
    }
    super.dispose();
  }

  @override
  void onWindowClose() async {
    // Instantly hide the window so the user thinks it closed immediately!
    await windowManager.hide();
    
    // Intercept the close event to broadcast our offline status before dying!
    if (mounted) {
      final auth = context.read<AuthProvider>();
      final discover = context.read<DiscoverProvider>();
      if (auth.isAuthenticated && auth.masterPublicKeyHex != null && discover.isAnnounced) {
        NostrRelayService().broadcastPing(auth.masterPublicKeyHex!, isOnline: false);
        // Wait long enough for the event to be signed and socket to flush the message before killing the process
        await Future.delayed(const Duration(milliseconds: 1000));
      }
    }
    await windowManager.destroy(); // Now kill the process completely!
  }

  @override
  void onWindowMinimize() {
    // When the Windows app is minimized, explicitly trigger the hidden lifecycle
    didChangeAppLifecycleState(AppLifecycleState.hidden);
  }

  @override
  void onWindowRestore() {
    // When the Windows app is restored, explicitly trigger the resumed lifecycle
    didChangeAppLifecycleState(AppLifecycleState.resumed);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      print('App resumed. Reconnecting to Nostr relays...');
      NostrRelayService().connectToRelays();
      
      // Also forcefully restart listeners so we can catch up on any messages
      // that arrived while our sockets were dead.
      if (mounted) {
        context.read<ChatProvider>().startListeningForMessages();
      }
    } else if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused || state == AppLifecycleState.detached || state == AppLifecycleState.hidden) {
      print('App inactive, backgrounded or hidden.');
    }
    
    // Pass lifecycle to DiscoverProvider for presence pinging
    if (mounted) {
      context.read<DiscoverProvider>().didChangeAppLifecycleState(state);
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = context.watch<ThemeProvider>();
    
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'MNDO',
      themeMode: themeProvider.themeMode,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        scaffoldBackgroundColor: const Color(0xFFFDFDFD),
        colorScheme: const ColorScheme.light(
          primary: Color(0xFF6366F1), // Electric Indigo
          secondary: Color(0xFF818CF8),
          surface: Color(0xFFF4F4F5), // Slightly lighter than background
          background: Color(0xFFFDFDFD),
          error: Color(0xFFEF4444),
        ),
        textTheme: GoogleFonts.interTextTheme(ThemeData.light().textTheme),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          centerTitle: true,
          scrolledUnderElevation: 0, // Disable material 3 scroll elevation color change
        ),
        cardTheme: const CardThemeData(
          color: Color(0xFFF4F4F5),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(16)),
            side: BorderSide(color: Color(0xFFE4E4E7), width: 1),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFFF4F4F5),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFFE4E4E7)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFFE4E4E7)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFF6366F1), width: 2),
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF6366F1),
            foregroundColor: Colors.white,
            elevation: 0,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF141414),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF6366F1), // Electric Indigo
          secondary: Color(0xFF818CF8),
          surface: Color(0xFF1E1E1E), // Slightly lighter than #141414
          background: Color(0xFF141414),
          error: Color(0xFFEF4444),
        ),
        textTheme: GoogleFonts.interTextTheme(ThemeData.dark().textTheme),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          centerTitle: true,
          scrolledUnderElevation: 0,
        ),
        cardTheme: const CardThemeData(
          color: Color(0xFF1E1E1E),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(16)),
            side: BorderSide(color: Color(0xFF2C2C2C), width: 1),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF1E1E1E),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFF2C2C2C)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFF2C2C2C)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFF6366F1), width: 2),
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF6366F1),
            foregroundColor: Colors.white,
            elevation: 0,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
      ),
      home: const OnboardingScreen(),
    );
  }
}
