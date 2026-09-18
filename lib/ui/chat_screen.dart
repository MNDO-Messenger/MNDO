import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/providers.dart';
import '../models/discover_user.dart';
import '../models/chat_message.dart';
import '../providers/chat_provider.dart';

class ChatScreen extends ConsumerStatefulWidget {
  final String recipientMasterPubKey;
  final String recipientNostrPubKey;
  final String recipientUsername;
  final String? recipientDisplayName;
  final String? recipientBio;

  const ChatScreen({
    super.key, 
    required this.recipientMasterPubKey,
    required this.recipientNostrPubKey,
    required this.recipientUsername,
    this.recipientDisplayName,
    this.recipientBio,
  });

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _focusNode = FocusNode();
  late ChatProvider _chatProvider;

  bool get _isDesktop => !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  bool _isSecure = false;
  bool _isEstablishing = true;
  String? _sessionError;

  @override
  void initState() {
    super.initState();
    _chatProvider = ref.read(chatNotifierProvider);
    
    // Mark as read immediately when opening the screen, after the first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _chatProvider.markChatAsRead(widget.recipientNostrPubKey);
    });

    _checkAndEstablishSession();
  }
  
  Future<void> _checkAndEstablishSession() async {
    if (!mounted) return;
    setState(() {
      _isEstablishing = true;
      _sessionError = null;
    });
    
    final signalService = ref.read(signalMessagingServiceProvider);
    if (signalService == null) {
      if (mounted) setState(() { _isEstablishing = false; _sessionError = "Crypto service unavailable."; });
      return;
    }
    
    try {
      bool hasSession = await signalService.hasSignalSession(widget.recipientNostrPubKey);
      if (!hasSession) {
        hasSession = await signalService.fetchAndEstablishSession(widget.recipientNostrPubKey);
      }
      
      if (mounted) {
        setState(() {
          _isSecure = hasSession;
          _isEstablishing = false;
          if (!hasSession) _sessionError = "Could not fetch recipient's encryption keys from network.";
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isEstablishing = false;
          _sessionError = "Error establishing session: $e";
        });
      }
    }
  }
  
  @override
  void dispose() {
    _chatProvider.clearActiveChat();
    _controller.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _sendMessage() async {
    final signalService = ref.read(signalMessagingServiceProvider);
    final chatProvider = ref.read(chatNotifierProvider);
    
    final text = _controller.text.trim();
    if (text.isEmpty || !_isSecure || signalService == null) return;
    
    _controller.clear();
    if (_isDesktop) {
      _focusNode.requestFocus();
    }
    
    chatProvider.addMessage(widget.recipientNostrPubKey, ChatMessage(
      text: text, 
      isMe: true, 
      timestamp: DateTime.now()
    ));
    
    // Make sure they are in our activeChats list so they show up on the main screen
    chatProvider.addChat(DiscoverUser(
      masterPubKeyHex: widget.recipientMasterPubKey,
      nostrPubKeyHex: widget.recipientNostrPubKey,
      username: widget.recipientUsername,
      lastSeen: DateTime.now(),
    ));
    
    await signalService.sendMessage(widget.recipientNostrPubKey, text);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Consumer(
              builder: (context, ref, _) {
                final discoverState = ref.watch(discoverNotifierProvider);
                final knownUser = discoverState.findUserByMaster(widget.recipientMasterPubKey) ?? 
                                  discoverState.findUser(widget.recipientNostrPubKey);
                final displayName = (knownUser?.displayName != null && knownUser!.displayName!.isNotEmpty)
                    ? knownUser.displayName
                    : widget.recipientDisplayName;
                final username = (knownUser != null && !knownUser.username.startsWith('Ghost #'))
                    ? knownUser.username
                    : widget.recipientUsername;
                return Text(
                  displayName ?? username,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                );
              },
            ),
            Text(
              _isEstablishing 
                ? 'Establishing Secure Session...'
                : (_isSecure 
                    ? '🔒 E2E Encrypted Session Active' 
                    : 'Session Error (Tap to Retry)'),
              style: TextStyle(
                fontSize: 11, 
                color: _isEstablishing ? Colors.orange : (_isSecure ? Colors.green : Colors.red),
                fontWeight: FontWeight.normal,
              ),
            ),
          ],
        ),
        actions: [
          if (!_isSecure && !_isEstablishing)
            IconButton(
              icon: const Icon(Icons.refresh, color: Colors.redAccent),
              onPressed: _checkAndEstablishSession,
              tooltip: 'Retry Secure Session',
            )
        ],
      ),
      body: Column(
        children: [
          if (_sessionError != null)
            Container(
              width: double.infinity,
              color: Colors.red.withOpacity(0.1),
              padding: const EdgeInsets.all(8.0),
              child: Text(
                _sessionError!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ),
          Expanded(
            child: Consumer(
              builder: (context, ref, child) {
                final messages = ref.watch(chatNotifierProvider.select(
                  (provider) => provider.chatHistories[widget.recipientNostrPubKey]?.toList() ?? [],
                ));
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (_scrollController.hasClients) {
                    _scrollController.animateTo(
                      _scrollController.position.maxScrollExtent,
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeOut,
                    );
                  }
                });

                return ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(16),
                  itemCount: messages.length,
                  itemBuilder: (context, index) {
                    final msg = messages[index];
                    return Align(
                      alignment: msg.isMe ? Alignment.centerRight : Alignment.centerLeft,
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        decoration: BoxDecoration(
                          color: msg.isMe ? Theme.of(context).colorScheme.primary : Theme.of(context).cardTheme.color ?? const Color(0xFFE4E4E7),
                          borderRadius: BorderRadius.only(
                            topLeft: const Radius.circular(20),
                            topRight: const Radius.circular(20),
                            bottomLeft: Radius.circular(msg.isMe ? 20 : 4),
                            bottomRight: Radius.circular(msg.isMe ? 4 : 20),
                          ),
                        ),
                        child: Text(
                          msg.text,
                          style: TextStyle(
                            color: msg.isMe ? Colors.white : Theme.of(context).textTheme.bodyMedium?.color ?? Colors.black87,
                            fontSize: 16,
                            height: 1.3,
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          Container(
            padding: const EdgeInsets.all(16.0),
            decoration: BoxDecoration(
              color: Theme.of(context).scaffoldBackgroundColor,
              border: Border(top: BorderSide(color: Theme.of(context).colorScheme.outlineVariant)),
            ),
            child: SafeArea(
              child: Row(
                children: [
                  Expanded(
                    child: Focus(
                      onKeyEvent: (node, event) {
                        if (_isDesktop &&
                            event is KeyDownEvent &&
                            event.logicalKey == LogicalKeyboardKey.enter &&
                            !HardwareKeyboard.instance.isShiftPressed) {
                          if (_isSecure) {
                            _sendMessage();
                          }
                          return KeyEventResult.handled;
                        }
                        return KeyEventResult.ignored;
                      },
                      child: TextField(
                        controller: _controller,
                        focusNode: _focusNode,
                        enabled: _isSecure,
                        minLines: 1,
                        maxLines: _isDesktop ? 4 : 1,
                        textInputAction: _isDesktop ? TextInputAction.send : TextInputAction.newline,
                        onSubmitted: _isDesktop && _isSecure ? (_) => _sendMessage() : null,
                        decoration: InputDecoration(
                          hintText: _isSecure ? 'Type an encrypted message...' : 'Waiting for keys...',
                          filled: true,
                          fillColor: Theme.of(context).inputDecorationTheme.fillColor,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(24),
                            borderSide: BorderSide.none,
                          ),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FloatingActionButton(
                    onPressed: _isSecure ? _sendMessage : null,
                    backgroundColor: _isSecure ? Theme.of(context).colorScheme.primary : Theme.of(context).disabledColor,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: const CircleBorder(),
                    child: const Icon(Icons.send_rounded),
                  )
                ],
              ),
            ),
          )
        ],
      ),
    );
  }
}
