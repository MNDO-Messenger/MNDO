import 'package:flutter/material.dart';
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
  bool _isGenerating = false;
  bool _isLoading = true;
  bool _isLoggingIn = false;
  final TextEditingController _mnemonicController = TextEditingController();

  @override
  void dispose() {
    _mnemonicController.dispose();
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
    setState(() => _isGenerating = true);
    await ref.read(authNotifierProvider).generateAndSaveIdentity();
    setState(() => _isGenerating = false);
  }

  void _login() async {
    final text = _mnemonicController.text.trim();
    if (text.split(' ').length != 12) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please enter a valid 12-word phrase')));
      return;
    }
    
    setState(() => _isLoggingIn = true);
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
    await _initializeApp();
    if (mounted) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const ChatListScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: MndoLoadingSplash(),
      );
    }

    final authState = ref.watch(authNotifierProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24.0),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 450),
              child: Card(
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24),
                  side: BorderSide(
                    color: isDark ? const Color(0xFF2C2C2C) : const Color(0xFFE4E4E7),
                    width: 1,
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(40.0),
                  child: authState.mnemonic == null
                      ? _buildLoginView(isDark)
                      : _buildSaveMnemonicView(authState, isDark),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLoginView(bool isDark) {
    return Column(
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
        _isGenerating 
            ? const Center(
                child: SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
              )
            : ElevatedButton(
                onPressed: _generateIdentity,
                child: const Text('Create New Account', style: TextStyle(fontWeight: FontWeight.bold)),
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
          decoration: const InputDecoration(
            hintText: 'Enter your 12-word recovery phrase',
            prefixIcon: Icon(Icons.vpn_key_outlined, color: Colors.grey),
          ),
          maxLines: 2,
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
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(Icons.vpn_key, size: 64, color: Color(0xFF10B981)),
        const SizedBox(height: 24),
        Text(
          'Backup Your Key',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Save these 12 words securely. If you lose them, you will lose access to your account forever.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: const Color(0xFFEF4444)),
        ),
        const SizedBox(height: 32),
        Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF18181B) : const Color(0xFFFDFDFD),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: isDark ? const Color(0xFF27272A) : const Color(0xFFE4E4E7)),
          ),
          child: Text(
            authState.mnemonic!, 
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 18, 
              height: 1.5,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.5,
              color: isDark ? Colors.white : Colors.black87,
            ),
          ),
        ),
        const SizedBox(height: 32),
        ElevatedButton(
          onPressed: _continue,
          child: const Text('I saved it securely', style: TextStyle(fontWeight: FontWeight.bold)),
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

    _scaleAnimation = Tween<double>(begin: 0.94, end: 1.04).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOutCubic),
    );
    _opacityAnimation = Tween<double>(begin: 0.70, end: 1.0).animate(
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
            // Branded SVG Icon with ambient glow
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: primaryColor.withValues(alpha: isDark ? 0.35 : 0.20),
                    blurRadius: 40,
                    spreadRadius: 8,
                  ),
                ],
              ),
              child: SvgPicture.asset(
                'assets/icon.svg',
                width: 80,
                height: 80,
                colorFilter: const ColorFilter.mode(primaryColor, BlendMode.srcIn),
              ),
            ),
            const SizedBox(height: 28),
            // MNDO Title
            Text(
              'MNDO',
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w800,
                letterSpacing: 8.0,
                color: isDark ? Colors.white : const Color(0xFF18181B),
              ),
            ),
            const SizedBox(height: 20),
            // Sleek lightweight progress bar
            SizedBox(
              width: 130,
              height: 3,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  backgroundColor: isDark ? const Color(0xFF27272A) : const Color(0xFFE4E4E7),
                  valueColor: const AlwaysStoppedAnimation<Color>(primaryColor),
                ),
              ),
            ),
            const SizedBox(height: 20),
            // Status or tagline
            Text(
              widget.message ?? 'SECURE • PRIVATE • DECENTRALIZED',
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                letterSpacing: 2.2,
                color: isDark ? const Color(0xFF71717A) : const Color(0xFFA1A1AA),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
