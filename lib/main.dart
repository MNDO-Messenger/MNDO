import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:window_manager/window_manager.dart';

import 'core/providers.dart';
import 'services/nostr_relay_service.dart';
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
    const ProviderScope(
      child: AisatConnectApp(),
    ),
  );
}

class AisatConnectApp extends ConsumerStatefulWidget {
  const AisatConnectApp({super.key});

  @override
  ConsumerState<AisatConnectApp> createState() => _AisatConnectAppState();
}

class _AisatConnectAppState extends ConsumerState<AisatConnectApp> with WidgetsBindingObserver, WindowListener {

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
      final auth = ref.read(authNotifierProvider);
      if (auth.isAuthenticated) {
        ref.read(chatNotifierProvider).startListeningForMessages();
        ref.read(discoverNotifierProvider).startDiscovery();
        
        final signal = ref.read(signalMessagingServiceProvider);
        if (signal != null && auth.signalIdentityKeyPair != null && auth.signalRegistrationId != null) {
          signal.generateAndBroadcastPreKeys(auth.signalIdentityKeyPair!, auth.signalRegistrationId!);
        }
      }
    });
  }

  @override
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
      final auth = ref.read(authNotifierProvider);
      final discover = ref.read(discoverNotifierProvider);
      if (auth.isAuthenticated && auth.masterPublicKeyHex != null) {
        print('DEBUG: Window closing, broadcasting offline ping...');
        await NostrRelayService().broadcastPing(
          auth.masterPublicKeyHex!, 
          isOnline: false,
          isHidden: !discover.isAnnounced,
          username: auth.username,
          displayName: auth.displayName,
          bio: auth.bio,
        );
        // Small buffer to ensure socket frame leaves the OS TCP buffer
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }
    await windowManager.destroy(); // Now kill the process completely!
  }

  @override
  void onWindowEvent(String eventName) {
    print('DEBUG: Window event received: $eventName');
  }

  @override
  void onWindowMinimize() async {
    print('DEBUG: onWindowMinimize triggered');
    if (mounted) {
      final discover = ref.read(discoverNotifierProvider);
      print('DEBUG: Window minimize, broadcasting offline ping immediately...');
      await discover.sendDirectOfflinePing();
    }
  }

  void onWindowMinimized() {
    print('DEBUG: onWindowMinimized triggered');
    onWindowMinimize();
  }

  @override
  void onWindowRestore() async {
    print('DEBUG: onWindowRestore triggered');
    if (mounted) {
      final discover = ref.read(discoverNotifierProvider);
      print('DEBUG: Window restore, broadcasting online ping immediately...');
      await discover.sendDirectOnlinePing();
    }
  }

  void onWindowRestored() {
    print('DEBUG: onWindowRestored triggered');
    onWindowRestore();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      // On desktop platforms, focus and blur are handled by the OS window manager.
      // Losing keyboard focus must NOT trigger offline presence or reconnect relays!
      return;
    }

    if (state == AppLifecycleState.resumed) {
      print('App resumed. Checking Nostr relays...');
      NostrRelayService().connectToRelays().then((_) {
        if (mounted) {
          ref.read(chatNotifierProvider).startListeningForMessages();
          ref.read(discoverNotifierProvider).startDiscovery();
        }
      });
    } else if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused || state == AppLifecycleState.detached || state == AppLifecycleState.hidden) {
      print('App inactive, backgrounded or hidden.');
    }
    
    // Pass lifecycle to DiscoverProvider for presence pinging on mobile
    if (mounted) {
      ref.read(discoverNotifierProvider).didChangeAppLifecycleState(state);
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = ref.watch(themeNotifierProvider);
    
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
