import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/providers.dart';
import '../providers/auth_provider.dart';
import 'chat_list_screen.dart';

class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  bool _isLoading = true;
  bool _isCreating = false;
  bool _isLoggingIn = false;
  bool _hasCopied = false;
  bool _isObscured = false;
  bool _hasConfirmed = false;
  Timer? _copyTimer;
  final TextEditingController _mnemonicController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _copyTimer?.cancel();
    _mnemonicController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _checkExisting();
  }

  Future<void> _initializeApp() async {
    if (!mounted) return;
    final chatProvider = ref.read(chatNotifierProvider);
    final discoverProvider = ref.read(discoverNotifierProvider);
    await chatProvider.loadInitialData();
    chatProvider.startListeningForMessages();
    await discoverProvider.loadState();

    final auth = ref.read(authNotifierProvider);
    final signal = ref.read(signalMessagingServiceProvider);
    if (signal != null && auth.signalIdentityKeyPair != null && auth.signalRegistrationId != null) {
      await signal.generateAndBroadcastPreKeys(auth.signalIdentityKeyPair!, auth.signalRegistrationId!);
    }
  }

  Future<void> _checkExisting() async {
    final hasIdentity = await ref.read(authNotifierProvider).restoreIdentity();
    if (hasIdentity && mounted) {
      await _initializeApp();
      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => const ChatListScreen()),
        );
      }
    } else {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _generateIdentity() async {
    if (_isCreating) return;
    setState(() => _isCreating = true);

    // Ensure any leftover state from a previous account is wiped
    await ref.read(chatNotifierProvider).clearAll();
    await ref.read(appDatabaseProvider).clearAllUserData();
    await ref.read(discoverNotifierProvider).logout();

    // Quick 250ms visual micro-interaction so the button immediately acknowledges the tap
    await Future.delayed(const Duration(milliseconds: 250));

    if (!mounted) return;
    ref.read(authNotifierProvider).generateAndSaveIdentity();
    if (mounted) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          0.0,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
      setState(() => _isCreating = false);
    }
  }

  void _login() async {
    final text = _mnemonicController.text.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    final words = text.split(' ').where((w) => w.isNotEmpty).toList();
    if (words.length != 12) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter all 12 words of your recovery phrase')),
      );
      return;
    }

    final isValid = ref.read(authNotifierProvider).validateMnemonic(text);
    if (!isValid) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Invalid recovery phrase. Please check for typos or incorrect words.')),
      );
      return;
    }
    
    setState(() => _isLoggingIn = true);

    // Purge previous user chats/sessions from disk and memory to prevent session clash
    await ref.read(chatNotifierProvider).clearAll();
    await ref.read(appDatabaseProvider).clearAllUserData();
    await ref.read(discoverNotifierProvider).logout();

    final success = await ref.read(authNotifierProvider).loginWithMnemonic(text);
    if (success && mounted) {
      await _initializeApp();
      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => const ChatListScreen()),
        );
      }
    } else {
      if (mounted) {
        setState(() => _isLoggingIn = false);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to login. Invalid phrase.')));
      }
    }
  }

  void _continue() async {
    final initFuture = ref.read(authNotifierProvider).identityInitFuture;
    if (initFuture != null) await initFuture;
    await _initializeApp();
    if (mounted) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const ChatListScreen()),
      );
    }
  }

  void _copyPhrase(String mnemonic) {
    Clipboard.setData(ClipboardData(text: mnemonic));
    setState(() => _hasCopied = true);
    _copyTimer?.cancel();
    _copyTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _hasCopied = false);
    });
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Row(
          children: [
            Icon(Icons.check_circle_rounded, color: Colors.white, size: 18),
            SizedBox(width: 10),
            Text('12-word recovery phrase copied to clipboard'),
          ],
        ),
        backgroundColor: const Color(0xFF10B981),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authNotifierProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 320),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        child: _isLoading
            ? const Center(
                key: ValueKey('loading_splash'),
                child: MndoLoadingSplash(),
              )
            : Stack(
                key: const ValueKey('onboarding_content'),
                children: [
          // Ambient glow behind header
          Positioned(
            top: -120,
            left: 0,
            right: 0,
            height: 360,
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 450),
                curve: Curves.easeOutCubic,
                width: authState.mnemonic == null ? 400 : 480,
                height: authState.mnemonic == null ? 320 : 360,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      const Color(0xFF6366F1).withValues(
                        alpha: isDark
                            ? (authState.mnemonic == null ? 0.16 : 0.22)
                            : (authState.mnemonic == null ? 0.08 : 0.13),
                      ),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            child: Center(
              child: ScrollConfiguration(
                behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
                child: SingleChildScrollView(
                  controller: _scrollController,
                  padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 28.0),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 480),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Step Indicator Pills
                        Padding(
                          padding: const EdgeInsets.only(bottom: 24.0),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              AnimatedContainer(
                                duration: const Duration(milliseconds: 350),
                                curve: Curves.easeOutCubic,
                                width: authState.mnemonic == null ? 28 : 8,
                                height: 4,
                                decoration: BoxDecoration(
                                  color: authState.mnemonic == null
                                      ? const Color(0xFF6366F1)
                                      : (isDark ? const Color(0xFF3F3F46) : const Color(0xFFE4E4E7)),
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                              const SizedBox(width: 6),
                              AnimatedContainer(
                                duration: const Duration(milliseconds: 350),
                                curve: Curves.easeOutCubic,
                                width: authState.mnemonic != null ? 28 : 8,
                                height: 4,
                                decoration: BoxDecoration(
                                  color: authState.mnemonic != null
                                      ? const Color(0xFF6366F1)
                                      : (isDark ? const Color(0xFF3F3F46) : const Color(0xFFE4E4E7)),
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                            ],
                          ),
                        ),
                        AnimatedSize(
                          duration: const Duration(milliseconds: 380),
                          curve: Curves.easeOutCubic,
                          alignment: Alignment.topCenter,
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 400),
                            switchInCurve: Curves.easeOutCubic,
                            switchOutCurve: Curves.easeInCubic,
                            layoutBuilder: (Widget? currentChild, List<Widget> previousChildren) {
                              return Stack(
                                alignment: Alignment.topCenter,
                                children: <Widget>[
                                  ...previousChildren,
                                  ?currentChild,
                                ],
                              );
                            },
                            transitionBuilder: (Widget child, Animation<double> animation) {
                              final isNewView = child.key == const ValueKey('save_mnemonic_view');
                              final curvedAnimation = CurvedAnimation(
                                parent: animation,
                                curve: Curves.easeOutCubic,
                                reverseCurve: Curves.easeInCubic,
                              );
                              final slideAnimation = Tween<Offset>(
                                begin: isNewView ? const Offset(0.20, 0.0) : const Offset(-0.20, 0.0),
                                end: Offset.zero,
                              ).animate(curvedAnimation);
                              final scaleAnimation = Tween<double>(
                                begin: 0.95,
                                end: 1.0,
                              ).animate(curvedAnimation);
                              final fadeAnimation = CurvedAnimation(
                                parent: animation,
                                curve: const Interval(0.12, 1.0, curve: Curves.easeInOut),
                              );
                              return SlideTransition(
                                position: slideAnimation,
                                child: ScaleTransition(
                                  scale: scaleAnimation,
                                  child: FadeTransition(
                                    opacity: fadeAnimation,
                                    child: child,
                                  ),
                                ),
                              );
                            },
                            child: authState.mnemonic == null
                                ? _buildLoginView(isDark)
                                : _buildSaveMnemonicView(authState, isDark),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

  Widget _buildLoginView(bool isDark) {
    return Column(
      key: const ValueKey('login_view'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: SvgPicture.asset(
            'assets/icon.svg',
            width: 64,
            height: 64,
            colorFilter: const ColorFilter.mode(Color(0xFF6366F1), BlendMode.srcIn),
          ),
        ),
        const SizedBox(height: 24),
        Text(
          'MNDO',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.bold,
            letterSpacing: 2,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Secure, decentralized messaging.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: isDark ? const Color(0xFFA1A1AA) : Colors.black54,
          ),
        ),
        const SizedBox(height: 48),
        ElevatedButton(
          onPressed: _isCreating ? null : _generateIdentity,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: _isCreating
                ? const SizedBox(
                    key: ValueKey('spinner'),
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.2,
                      color: Colors.white,
                    ),
                  )
                : const Text(
                    'Create New Account',
                    key: ValueKey('label'),
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
          ),
        ),
        const SizedBox(height: 32),
        Row(
          children: [
            Expanded(child: Divider(color: isDark ? const Color(0xFF27272A) : Colors.grey[300])),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'OR RESTORE',
                style: TextStyle(
                  color: isDark ? const Color(0xFF71717A) : Colors.black54,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            Expanded(child: Divider(color: isDark ? const Color(0xFF27272A) : Colors.grey[300])),
          ],
        ),
        const SizedBox(height: 32),
        TextField(
          controller: _mnemonicController,
          minLines: 1,
          maxLines: 3,
          textAlignVertical: TextAlignVertical.center,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w400,
            color: isDark ? Colors.white : const Color(0xFF18181B),
          ),
          decoration: InputDecoration(
            hintText: 'Enter your 12-word recovery phrase',
            hintStyle: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w300,
              color: isDark
                  ? Colors.white.withValues(alpha: 0.28)
                  : Colors.black.withValues(alpha: 0.35),
              letterSpacing: 0.1,
            ),
            prefixIcon: Icon(
              Icons.vpn_key_outlined,
              size: 20,
              color: isDark ? const Color(0xFF71717A) : const Color(0xFFA1A1AA),
            ),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          ),
        ),
        const SizedBox(height: 16),
        _isLoggingIn 
            ? const Center(
                child: SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
              )
            : OutlinedButton(
                onPressed: _login,
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  side: BorderSide(color: isDark ? const Color(0xFF3F3F46) : const Color(0xFFE4E4E7)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: Text('Restore Account', style: TextStyle(color: isDark ? Colors.white : Colors.black87)),
              ),
      ],
    );
  }

  Widget _buildSaveMnemonicView(AuthProvider authState, bool isDark) {
    final rawMnemonic = authState.mnemonic ?? '';
    final words = rawMnemonic.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final cleanMnemonic = words.join(' ');

    return Column(
      key: const ValueKey('save_mnemonic_view'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Top Navigation Bar
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            InkWell(
              onTap: () {
                if (_scrollController.hasClients) {
                  _scrollController.jumpTo(0.0);
                }
                ref.read(authNotifierProvider).resetOnboarding();
              },
              borderRadius: BorderRadius.circular(20),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF1E1E24) : const Color(0xFFF1F5F9),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: isDark ? const Color(0xFF2E2E36) : const Color(0xFFE2E8F0),
                    width: 0.8,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.arrow_back_rounded,
                      size: 15,
                      color: isDark ? const Color(0xFFD4D4D8) : const Color(0xFF475569),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'Back',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: isDark ? const Color(0xFFD4D4D8) : const Color(0xFF475569),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: const Color(0xFF10B981).withValues(alpha: isDark ? 0.15 : 0.08),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: const Color(0xFF10B981).withValues(alpha: isDark ? 0.35 : 0.20),
                  width: 0.8,
                ),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.lock_outline_rounded, size: 12, color: Color(0xFF10B981)),
                  SizedBox(width: 5),
                  Text(
                    'E2EE Vault',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF10B981),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),

        // Minimal Security Key Badge
        Center(
          child: Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: const Color(0xFF6366F1).withValues(alpha: isDark ? 0.18 : 0.08),
              shape: BoxShape.circle,
              border: Border.all(
                color: const Color(0xFF6366F1).withValues(alpha: isDark ? 0.35 : 0.20),
                width: 1.2,
              ),
            ),
            child: const Center(
              child: Icon(
                Icons.vpn_key_rounded,
                size: 25,
                color: Color(0xFF6366F1),
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),

        Text(
          'Secret Recovery Phrase',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: -0.4,
            fontSize: 21,
          ),
        ),
        const SizedBox(height: 6),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10.0),
          child: Text(
            'This 12-word master key is the only way to recover your account and messages. Keep it safe and private.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              height: 1.45,
              color: isDark ? const Color(0xFFA1A1AA) : const Color(0xFF64748B),
            ),
          ),
        ),
        const SizedBox(height: 22),

        // 12 Words Single Sentence Box (Minimal, sleek container)
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF141418) : const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isDark ? const Color(0xFF27272A) : const Color(0xFFE2E8F0),
              width: 1.0,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        decoration: const BoxDecoration(
                          color: Color(0xFF6366F1),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '12-WORD MASTER KEY',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.0,
                          color: isDark ? const Color(0xFFA1A1AA) : const Color(0xFF64748B),
                        ),
                      ),
                    ],
                  ),
                  InkWell(
                    onTap: () => setState(() => _isObscured = !_isObscured),
                    borderRadius: BorderRadius.circular(12),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _isObscured ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                            size: 13,
                            color: isDark ? const Color(0xFFD4D4D8) : const Color(0xFF475569),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            _isObscured ? 'Reveal' : 'Hide',
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              color: isDark ? const Color(0xFFD4D4D8) : const Color(0xFF475569),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              SelectableText(
                _isObscured
                    ? List.filled(words.isNotEmpty ? words.length : 12, '••••').join('  ')
                    : cleanMnemonic,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 15.5,
                  height: 1.6,
                  fontWeight: FontWeight.w600,
                  letterSpacing: _isObscured ? 2.0 : 0.3,
                  color: isDark ? Colors.white : const Color(0xFF0F172A),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // Minimal Outlined Copy Button
        OutlinedButton.icon(
          onPressed: () => _copyPhrase(authState.mnemonic ?? ''),
          icon: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: _hasCopied
                ? const Icon(Icons.check_circle_rounded, key: ValueKey('check'), color: Color(0xFF10B981), size: 16)
                : Icon(Icons.copy_rounded, key: const ValueKey('copy'), color: isDark ? const Color(0xFFA1A1AA) : const Color(0xFF64748B), size: 16),
          ),
          label: Text(
            _hasCopied ? 'Copied to Clipboard!' : 'Copy 12 Words to Clipboard',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 13,
              color: _hasCopied
                  ? const Color(0xFF10B981)
                  : (isDark ? Colors.white : const Color(0xFF1E293B)),
            ),
          ),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 12),
            side: BorderSide(
              color: _hasCopied
                  ? const Color(0xFF10B981).withValues(alpha: 0.6)
                  : (isDark ? const Color(0xFF27272A) : const Color(0xFFE2E8F0)),
              width: 1.0,
            ),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            backgroundColor: _hasCopied
                ? const Color(0xFF10B981).withValues(alpha: isDark ? 0.12 : 0.06)
                : (isDark ? const Color(0xFF141418) : Colors.white),
            elevation: 0,
          ),
        ),
        const SizedBox(height: 20),

        // Crucial Security Rules (Minimal text, cool look, no card container)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.shield_outlined,
                    size: 13,
                    color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Crucial Security Rules',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
                      color: isDark ? const Color(0xFFA1A1AA) : const Color(0xFF64748B),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              _buildMinimalSecurityRule(
                title: 'No password resets:',
                text: 'MNDO is peer-to-peer. If lost, nobody can restore your account.',
                isDark: isDark,
              ),
              const SizedBox(height: 7),
              _buildMinimalSecurityRule(
                title: 'Never share it:',
                text: 'Anyone with this phrase can access your messages and identity.',
                isDark: isDark,
              ),
              const SizedBox(height: 7),
              _buildMinimalSecurityRule(
                title: 'Write it down:',
                text: 'Keep an offline physical copy or store in a secure password vault.',
                isDark: isDark,
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),

        // Confirmation Row (Minimal ticking without card background)
        InkWell(
          onTap: () => setState(() => _hasConfirmed = !_hasConfirmed),
          borderRadius: BorderRadius.circular(8),
          splashColor: Colors.transparent,
          highlightColor: Colors.transparent,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
            child: Row(
              children: [
                SizedBox(
                  width: 20,
                  height: 20,
                  child: Checkbox(
                    value: _hasConfirmed,
                    onChanged: (val) => setState(() => _hasConfirmed = val ?? false),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
                    activeColor: const Color(0xFF6366F1),
                    side: BorderSide(
                      color: isDark ? const Color(0xFF52525B) : const Color(0xFFCBD5E1),
                      width: 1.4,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'I have safely written down or saved my 12-word phrase.',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: _hasConfirmed ? FontWeight.w600 : FontWeight.w400,
                      color: isDark ? const Color(0xFFD4D4D8) : const Color(0xFF334155),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 18),

        // Continue Button
        Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            boxShadow: _hasConfirmed
                ? [
                    BoxShadow(
                      color: const Color(0xFF6366F1).withValues(alpha: 0.35),
                      blurRadius: 14,
                      offset: const Offset(0, 4),
                    ),
                  ]
                : null,
          ),
          child: ElevatedButton(
            onPressed: _hasConfirmed
                ? _continue
                : () {
                    ScaffoldMessenger.of(context).hideCurrentSnackBar();
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: const Text('Please confirm you have saved your recovery phrase.'),
                        behavior: SnackBarBehavior.floating,
                        backgroundColor: const Color(0xFF4F46E5),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    );
                  },
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              backgroundColor: _hasConfirmed
                  ? const Color(0xFF6366F1)
                  : (isDark ? const Color(0xFF27272A) : const Color(0xFFE4E4E7)),
              foregroundColor: _hasConfirmed
                  ? Colors.white
                  : (isDark ? const Color(0xFF71717A) : const Color(0xFFA1A1AA)),
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  'Continue to MNDO',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15, letterSpacing: 0.2),
                ),
                SizedBox(width: 8),
                Icon(Icons.arrow_forward_rounded, size: 18),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMinimalSecurityRule({
    required String title,
    required String text,
    required bool isDark,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 6, right: 8),
          child: Container(
            width: 4,
            height: 4,
            decoration: BoxDecoration(
              color: const Color(0xFF6366F1).withValues(alpha: isDark ? 0.8 : 0.6),
              shape: BoxShape.circle,
            ),
          ),
        ),
        Expanded(
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: title,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: isDark ? const Color(0xFFE4E4E7) : const Color(0xFF1E293B),
                  ),
                ),
                const TextSpan(text: ' '),
                TextSpan(
                  text: text,
                  style: TextStyle(
                    color: isDark ? const Color(0xFFA1A1AA) : const Color(0xFF64748B),
                  ),
                ),
              ],
            ),
            style: const TextStyle(fontSize: 12, height: 1.4),
          ),
        ),
      ],
    );
  }
}

class MndoLoadingSplash extends StatefulWidget {
  final String? message;
  const MndoLoadingSplash({super.key, this.message});

  @override
  State<MndoLoadingSplash> createState() => _MndoLoadingSplashState();
}

class _MndoLoadingSplashState extends State<MndoLoadingSplash> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scaleAnimation;
  late final Animation<double> _opacityAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat(reverse: true);

    _scaleAnimation = Tween<double>(begin: 0.96, end: 1.02).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOutCubic),
    );
    _opacityAnimation = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOutCubic),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    const primaryColor = Color(0xFF6366F1);

    return Center(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          return Opacity(
            opacity: _opacityAnimation.value,
            child: Transform.scale(
              scale: _scaleAnimation.value,
              child: child,
            ),
          );
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Clean Logo without any artificial border or stroke ring
            SvgPicture.asset(
              'assets/icon.svg',
              width: 72,
              height: 72,
              colorFilter: const ColorFilter.mode(primaryColor, BlendMode.srcIn),
            ),
            const SizedBox(height: 26),
            // Minimal "Dot Dot" loading bar
            const _MndoDotLoadingBar(),
            if (widget.message != null) ...[
              const SizedBox(height: 18),
              Text(
                widget.message!,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 1.2,
                  color: isDark ? const Color(0xFF71717A) : const Color(0xFFA1A1AA),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _MndoDotLoadingBar extends StatefulWidget {
  final Color color;
  final double dotSize;
  final double spacing;

  const _MndoDotLoadingBar({
    this.color = const Color(0xFF6366F1),
    this.dotSize = 7.0,
    this.spacing = 8.0,
  });

  @override
  State<_MndoDotLoadingBar> createState() => _MndoDotLoadingBarState();
}

class _MndoDotLoadingBarState extends State<_MndoDotLoadingBar> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(3, (index) {
            final offset = index * 0.22;
            final progress = (_controller.value - offset) % 1.0;
            final active = progress < 0.6 ? math.sin((progress / 0.6) * math.pi) : 0.0;
            final scale = 0.8 + (active * 0.45);
            final opacity = 0.35 + (active * 0.65);
            final translateY = -4.0 * active;

            return Padding(
              padding: EdgeInsets.symmetric(horizontal: widget.spacing / 2),
              child: Transform.translate(
                offset: Offset(0, translateY),
                child: Transform.scale(
                  scale: scale,
                  child: Opacity(
                    opacity: opacity,
                    child: Container(
                      width: widget.dotSize,
                      height: widget.dotSize,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: widget.color,
                      ),
                    ),
                  ),
                ),
              ),
            );
          }),
        );
      },
    );
  }
}
