import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/chat_provider.dart';
import '../providers/discover_provider.dart';
import 'chat_list_screen.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
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
    await context.read<ChatProvider>().loadInitialData();
    context.read<ChatProvider>().startListeningForMessages();
    await context.read<DiscoverProvider>().loadState();
  }

  Future<void> _checkExisting() async {
    final hasIdentity = await context.read<AuthProvider>().restoreIdentity();
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
    await context.read<AuthProvider>().generateAndSaveIdentity();
    setState(() => _isGenerating = false);
  }

  void _login() async {
    final text = _mnemonicController.text.trim();
    if (text.split(' ').length != 12) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please enter a valid 12-word phrase')));
      return;
    }
    
    setState(() => _isLoggingIn = true);
    final success = await context.read<AuthProvider>().loginWithMnemonic(text);
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
    final authState = context.watch<AuthProvider>();

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
                  side: const BorderSide(color: Color(0xFFE4E4E7), width: 1),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(40.0),
                  child: _isLoading 
                      ? const Center(child: CircularProgressIndicator())
                      : authState.mnemonic == null
                          ? _buildLoginView()
                          : _buildSaveMnemonicView(authState),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLoginView() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SvgPicture.asset(
          'assets/icon.svg',
          width: 64,
          height: 64,
          colorFilter: const ColorFilter.mode(Color(0xFF6366F1), BlendMode.srcIn),
        ),
        const SizedBox(height: 24),
        Text(
          'MNDO',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.bold,
            
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Secure, decentralized messaging.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Colors.black54,
          ),
        ),
        const SizedBox(height: 48),
        _isGenerating 
            ? const Center(child: CircularProgressIndicator())
            : ElevatedButton(
                onPressed: _generateIdentity,
                child: const Text('Create New Account', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
        const SizedBox(height: 32),
        Row(
          children: [
            Expanded(child: Divider(color: Colors.grey[800])),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text('OR RESTORE', style: TextStyle(color: Colors.black54, fontSize: 12, fontWeight: FontWeight.bold)),
            ),
            Expanded(child: Divider(color: Colors.grey[800])),
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
            ? const Center(child: CircularProgressIndicator())
            : OutlinedButton(
                onPressed: _login,
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  side: const BorderSide(color: Color(0xFFE4E4E7)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text('Restore Account', style: TextStyle(color: Colors.black87)),
              ),
      ],
    );
  }

  Widget _buildSaveMnemonicView(AuthProvider authState) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(Icons.vpn_key, size: 64, color: Color(0xFF10B981)),
        const SizedBox(height: 24),
        Text(
          'Backup Your Key',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold, color: Colors.white),
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
            color: const Color(0xFFFDFDFD),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFE4E4E7)),
          ),
          child: Text(
            authState.mnemonic!, 
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 18, 
              height: 1.5,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.5,
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
