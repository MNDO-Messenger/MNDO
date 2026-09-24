import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:window_manager/window_manager.dart';

import 'core/providers.dart';
import 'services/nostr_relay_service.dart';
import 'package:audioplayers/audioplayers.dart';
import 'ui/onboarding_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Configure AudioPlayer to output to loudspeaker / media stream by default
  try {
    await AudioPlayer.global.setAudioContext(
      AudioContext(
        android: const AudioContextAndroid(
          isSpeakerphoneOn: true,
          stayAwake: true,
          contentType: AndroidContentType.music,
          usageType: AndroidUsageType.media,
          audioFocus: AndroidAudioFocus.gain,
        ),
        iOS: AudioContextIOS(
          category: AVAudioSessionCategory.playback,
          options: const {
            AVAudioSessionOptions.defaultToSpeaker,
          },
        ),
      ),
    );
  } catch (_) {}
  
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

    NostrRelayService().addOnReadyListener(() {
      final auth = ref.read(authNotifierProvider);
      if (auth.isAuthenticated) {
        final signal = ref.read(signalMessagingServiceProvider);
        if (signal != null && auth.signalIdentityKeyPair != null && auth.signalRegistrationId != null) {
          signal.generateAndBroadcastPreKeys(auth.signalIdentityKeyPair!, auth.signalRegistrationId!);
        }
      }
    });
  }

  @override
  void dispose() {
    _windowStateDebounceTimer?.cancel();
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
      if (auth.isAuthenticated && auth.masterPublicKeyHex != null && discover.isAnnounced) {
        print('[PRESENCE] OFFLINE Desktop window closing, broadcasting offline ping...');
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        final sig = await auth.createDelegationSignature(NostrRelayService().publicHex, nowMs);
        try {
          await NostrRelayService().broadcastPing(
            auth.masterPublicKeyHex!, 
            isOnline: false,
            isHidden: false,
            masterSig: sig,
            timestampMs: nowMs,
          ).timeout(const Duration(seconds: 3));
        } catch (_) {}
      }
    }
    NostrRelayService().disposeSubscriptions();
    await windowManager.destroy(); // Now kill the process completely!
  }

  bool _isDesktopMinimized = false;
  Timer? _windowStateDebounceTimer;

  void _handleDesktopMinimized() {
    if (_isDesktopMinimized) return;
    _isDesktopMinimized = true;
    // Mark app as unfocused so incoming messages get 'delivered' not 'read'
    ref.read(chatNotifierProvider).isAppFocused = false;
    _windowStateDebounceTimer?.cancel();
    _windowStateDebounceTimer = Timer(const Duration(milliseconds: 600), () async {
      if (!_isDesktopMinimized || !mounted) return;
      print('DEBUG: Desktop window minimized (debounced), broadcasting offline ping...');
      final discover = ref.read(discoverNotifierProvider);
      await discover.sendDirectOfflinePing();
    });
  }

  void _handleDesktopRestored() {
    _isDesktopMinimized = false;
    // Mark app as focused and upgrade any pending 'delivered' messages to 'read'
    final chatProvider = ref.read(chatNotifierProvider);
    chatProvider.isAppFocused = true;
    if (chatProvider.activeChatUserId != null) {
      chatProvider.markChatAsRead(chatProvider.activeChatUserId!);
    }
    _windowStateDebounceTimer?.cancel();
    _windowStateDebounceTimer = Timer(const Duration(milliseconds: 400), () async {
      if (_isDesktopMinimized || !mounted) return;
      print('DEBUG: Desktop window restored (debounced), broadcasting online ping...');
      final discover = ref.read(discoverNotifierProvider);
      await discover.sendDirectOnlinePing();

      NostrRelayService().connectToRelays().then((_) {
        if (mounted) {
          ref.read(chatNotifierProvider).startListeningForMessages();
          discover.startDiscovery();
        }
      });
    });
  }

  @override
  void onWindowMinimize() {
    print('DEBUG: onWindowMinimize triggered');
    _handleDesktopMinimized();
  }

  void onWindowMinimized() {
    print('DEBUG: onWindowMinimized triggered');
    _handleDesktopMinimized();
  }

  @override
  void onWindowRestore() {
    print('DEBUG: onWindowRestore triggered');
    _handleDesktopRestored();
  }

  void onWindowRestored() {
    print('DEBUG: onWindowRestored triggered');
    _handleDesktopRestored();
  }

  @override
  void onWindowMaximize() {
    print('DEBUG: onWindowMaximize triggered');
    if (_isDesktopMinimized) {
      _handleDesktopRestored();
    }
  }

  @override
  void onWindowFocus() async {
    print('DEBUG: onWindowFocus triggered');
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      final isMin = await windowManager.isMinimized();
      if (!isMin) {
        final discover = ref.read(discoverNotifierProvider);
        if (_isDesktopMinimized || !discover.isHeartbeatActive) {
          _handleDesktopRestored();
        }
      }
    }
  }

  @override
  void onWindowEvent(String eventName) async {
    print('DEBUG: Window event received: $eventName');
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      if (eventName == 'minimize') {
        _handleDesktopMinimized();
      } else if (eventName == 'restore' ||
          eventName == 'unmaximize' ||
          eventName == 'show' ||
          eventName == 'focus' ||
          eventName == 'maximize') {
        final isMin = await windowManager.isMinimized();
        if (!isMin) {
          final discover = ref.read(discoverNotifierProvider);
          if (_isDesktopMinimized || !discover.isHeartbeatActive) {
            _handleDesktopRestored();
          }
        }
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      if (state == AppLifecycleState.resumed) {
        windowManager.isMinimized().then((isMin) {
          if (!isMin) {
            final discover = ref.read(discoverNotifierProvider);
            if (_isDesktopMinimized || !discover.isHeartbeatActive) {
              _handleDesktopRestored();
            }
          }
        });
      }
      // On desktop, window minimization is handled strictly by WindowListener
      // and windowManager.isMinimized(). Flutter's AppLifecycleState.hidden/inactive
      // occurs whenever the window loses focus, which must NEVER flip presence!
      return;
    }

    if (state == AppLifecycleState.resumed) {
      print('App resumed. Checking Nostr relays...');
      // Mark app as focused and upgrade any pending 'delivered' messages to 'read'
      final chatProvider = ref.read(chatNotifierProvider);
      chatProvider.isAppFocused = true;
      if (chatProvider.activeChatUserId != null) {
        chatProvider.markChatAsRead(chatProvider.activeChatUserId!);
      }
      NostrRelayService().connectToRelays().then((_) {
        if (mounted) {
          ref.read(chatNotifierProvider).startListeningForMessages();
          ref.read(discoverNotifierProvider).startDiscovery();
        }
      });
    } else if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused || state == AppLifecycleState.detached || state == AppLifecycleState.hidden) {
      print('App inactive, backgrounded or hidden.');
      // Mark app as unfocused so incoming messages get 'delivered' not 'read'
      ref.read(chatNotifierProvider).isAppFocused = false;
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
