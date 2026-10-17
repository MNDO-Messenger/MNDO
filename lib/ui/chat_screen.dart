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
import '../services/nostr_relay_service.dart';
import '../services/signal_messaging_service.dart';
import '../services/voice_note_service.dart';
import '../services/voice_note_playback_coordinator.dart';
import 'package:file_selector/file_selector.dart';
import '../models/media_payload.dart';
import 'widgets/identicon.dart';
import 'widgets/voice_note_bubble.dart';
import 'widgets/media_bubbles.dart';
import 'widgets/whatsapp_formatter.dart';
import 'widgets/formatted_display_name.dart';
import 'widgets/media_send_preview_screen.dart';

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
  final TextEditingController _controller = WhatsAppTextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _focusNode = FocusNode();
  late ChatProvider _chatProvider;

  bool get _isDesktop => !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);
  bool _isProfilePanelOpen = false;

  bool _isSecure = false;
  bool _isEstablishing = true;
  String? _sessionError;
  bool _canSend = false;

  bool _isRecordingVoice = false;
  int _recordingDurationSeconds = 0;
  Timer? _recordingTimer;
  StreamSubscription<int>? _liveAmpSub;
  final List<int> _liveAmplitudes = [];

  @override
  void initState() {
    super.initState();
    _chatProvider = ref.read(chatNotifierProvider);

    _controller.addListener(_onTextChanged);

    // Mark as read immediately when opening the screen, after the first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _chatProvider.markChatAsRead(widget.recipientNostrPubKey);
    });

    if (widget.recipientUsername.startsWith('Ghost #')) {
      _resolveGhostProfile();
    }

    _checkAndEstablishSession();
  }

  Future<void> _resolveGhostProfile() async {
    try {
      final profileMap = await NostrRelayService().fetchUserProfile(widget.recipientNostrPubKey);
      if (profileMap != null && profileMap['name'] != null && profileMap['name'].toString().isNotEmpty) {
        final realName = profileMap['name'].toString();
        final realDisplayName = profileMap['displayName']?.toString();
        final realBio = profileMap['bio']?.toString();
        await _chatProvider.updateChatUserProfile(
          masterPubKeyHex: widget.recipientMasterPubKey,
          username: realName,
          displayName: realDisplayName,
          bio: realBio,
        );
      }
    } catch (_) {}
  }

  void _insertNewlineAtCursor() {
    final val = _controller.value;
    final text = val.text;
    final sel = val.selection;
    final start = sel.start >= 0 ? sel.start : text.length;
    final end = sel.end >= 0 ? sel.end : text.length;
    final newText = text.replaceRange(start, end, '\n');
    _controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: start + 1),
    );
  }

  void _onTextChanged() {
    final canSend = _controller.text.trim().isNotEmpty;
    if (canSend != _canSend) {
      setState(() => _canSend = canSend);
    }
  }

  Future<void> _checkAndEstablishSession() async {
    if (!mounted) return;
    setState(() {
      _isEstablishing = true;
      _sessionError = null;
    });

    final signalService = ref.read(signalMessagingServiceProvider);
    if (signalService == null) {
      if (mounted) {
        setState(() {
          _isEstablishing = false;
          _sessionError = "Crypto service unavailable.";
        });
      }
      return;
    }

    try {
      final auth = ref.read(authNotifierProvider);
      if (auth.signalIdentityKeyPair != null && auth.signalRegistrationId != null) {
        signalService.generateAndBroadcastPreKeys(auth.signalIdentityKeyPair!, auth.signalRegistrationId!);
      }

      final discoverState = ref.read(discoverNotifierProvider);
      final knownUser = discoverState.findUserByMaster(widget.recipientMasterPubKey) ??
          discoverState.findUser(widget.recipientNostrPubKey);
      final targetNostrPubKey = (knownUser != null && knownUser.nostrPubKeyHex.isNotEmpty)
          ? knownUser.nostrPubKeyHex
          : widget.recipientNostrPubKey;

      final isUserBlocked = _chatProvider.isUserBlocked(widget.recipientNostrPubKey) ||
          _chatProvider.isUserBlocked(targetNostrPubKey);
      if (isUserBlocked) {
        if (mounted) {
          setState(() {
            _isSecure = false;
            _isEstablishing = false;
            _sessionError = null;
          });
        }
        return;
      }

      bool hasSession = await signalService.hasSignalSession(targetNostrPubKey);
      if (!hasSession && targetNostrPubKey != widget.recipientNostrPubKey) {
        hasSession = await signalService.hasSignalSession(widget.recipientNostrPubKey);
      }
      if (!hasSession) {
        hasSession = await signalService.fetchAndEstablishSession(
          targetNostrPubKey,
          masterPubKeyHex: widget.recipientMasterPubKey,
        );
      }
      if (!hasSession && targetNostrPubKey != widget.recipientNostrPubKey) {
        hasSession = await signalService.fetchAndEstablishSession(
          widget.recipientNostrPubKey,
          masterPubKeyHex: widget.recipientMasterPubKey,
        );
      }

      final isBlocked = (_chatProvider.isPeerIdentityBlocked(widget.recipientNostrPubKey) ||
          _chatProvider.isPeerIdentityBlocked(targetNostrPubKey) ||
          signalService.isIdentityBlocked(widget.recipientNostrPubKey) ||
          signalService.isIdentityBlocked(targetNostrPubKey));

      if (mounted) {
        setState(() {
          _isSecure = hasSession && !isBlocked;
          _isEstablishing = false;
          if (isBlocked) {
            _sessionError = "Security Alert: Peer's encryption key changed. Verification required.";
          } else if (!hasSession) {
            _sessionError = "Could not fetch recipient's encryption keys from network.";
          } else {
            _sessionError = null;
          }
        });
      }

      if (hasSession && !isBlocked) {
        _chatProvider.markChatAsRead(widget.recipientNostrPubKey);
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
    VoiceNotePlaybackCoordinator.instance.stopAll();
    _recordingTimer?.cancel();
    _liveAmpSub?.cancel();
    if (_isRecordingVoice) {
      VoiceNoteService().cancelRecording();
    }
    _controller.removeListener(_onTextChanged);
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
    if (text.isEmpty || signalService == null) return;

    if (!_isSecure) {
      await _checkAndEstablishSession();
      if (!_isSecure) {
        return;
      }
    }

    _controller.clear();
    if (_isDesktop) {
      _focusNode.requestFocus();
    }

    final sentAt = DateTime.now();

    final discoverState = ref.read(discoverNotifierProvider);
    final knownUser = discoverState.findUserByMaster(widget.recipientMasterPubKey) ??
        discoverState.findUser(widget.recipientNostrPubKey);
    final targetNostrPubKey = (knownUser != null && knownUser.nostrPubKeyHex.isNotEmpty)
        ? knownUser.nostrPubKeyHex
        : widget.recipientNostrPubKey;

    final canSend = await chatProvider.canSendToPeer(targetNostrPubKey);
    if (!canSend) {
      return;
    }

    // Make sure they are in our activeChats list so they show up on the main screen
    chatProvider.addChat(DiscoverUser(
      masterPubKeyHex: widget.recipientMasterPubKey,
      nostrPubKeyHex: targetNostrPubKey,
      username: widget.recipientUsername,
      displayName: widget.recipientDisplayName,
      bio: widget.recipientBio,
      lastSeen: sentAt,
      lastSeenFromPing: knownUser?.lastSeenFromPing,
      isExplicitlyOffline: knownUser?.isExplicitlyOffline ?? false,
    ));

    // Smoothly animate reversed scroll list to bottom (offset 0)
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    }

    await chatProvider.sendOutgoingMessage(targetNostrPubKey, text, sentAt: sentAt);
  }

  void _retrySendMessage(ChatMessage msg) async {
    final chatProvider = ref.read(chatNotifierProvider);
    final discoverState = ref.read(discoverNotifierProvider);
    final knownUser = discoverState.findUserByMaster(widget.recipientMasterPubKey) ??
        discoverState.findUser(widget.recipientNostrPubKey);
    final targetNostrPubKey = (knownUser != null && knownUser.nostrPubKeyHex.isNotEmpty)
        ? knownUser.nostrPubKeyHex
        : widget.recipientNostrPubKey;

    final canSend = await chatProvider.canSendToPeer(targetNostrPubKey);
    if (!canSend) {
      return;
    }
    await chatProvider.retryOutgoingMessage(targetNostrPubKey, msg);
  }

  Future<void> _startVoiceRecording() async {
    if (!_isSecure || _isRecordingVoice) return;

    await VoiceNotePlaybackCoordinator.instance.stopAll();

    final voiceService = VoiceNoteService();
    final success = await voiceService.startRecording();
    if (!success) {
      return;
    }

    if (mounted) {
      setState(() {
        _isRecordingVoice = true;
        _recordingDurationSeconds = 0;
        _liveAmplitudes.clear();
      });
    }

    final recordingStart = DateTime.now();
    _recordingTimer?.cancel();
    _recordingTimer = Timer.periodic(const Duration(milliseconds: 200), (t) {
      if (mounted) {
        final sec = DateTime.now().difference(recordingStart).inSeconds;
        if (sec != _recordingDurationSeconds) {
          setState(() {
            _recordingDurationSeconds = sec;
          });
        }
      }
    });

    _liveAmpSub?.cancel();
    _liveAmpSub = voiceService.onLiveAmplitude.listen((amp) {
      if (mounted) {
        setState(() {
          _liveAmplitudes.add(amp);
          if (_liveAmplitudes.length > 28) {
            _liveAmplitudes.removeAt(0);
          }
        });
      }
    });
  }

  Future<void> _cancelVoiceRecording() async {
    _recordingTimer?.cancel();
    _recordingTimer = null;
    await _liveAmpSub?.cancel();
    _liveAmpSub = null;

    await VoiceNoteService().cancelRecording();

    if (mounted) {
      setState(() {
        _isRecordingVoice = false;
        _recordingDurationSeconds = 0;
        _liveAmplitudes.clear();
      });
    }
  }

  Future<void> _sendVoiceRecording() async {
    if (!_isRecordingVoice) return;

    final observedSeconds = _recordingDurationSeconds;
    _recordingTimer?.cancel();
    _recordingTimer = null;
    await _liveAmpSub?.cancel();
    _liveAmpSub = null;

    // Immediately dismiss the recording bar (Optimistic UI - zero delay!)
    setState(() {
      _isRecordingVoice = false;
      _recordingDurationSeconds = 0;
      _liveAmplitudes.clear();
    });

    final recorded = await VoiceNoteService().stopRecording(
      userObservedDuration: Duration(seconds: observedSeconds),
    );
    if (recorded == null) return;

    final localPath = recorded['path'] as String;
    final durationMs = recorded['durationMs'] as int;
    final waveform = (recorded['waveform'] as List<dynamic>).map((e) => (e as num).toInt()).toList();

    // If audio is under 600ms, discard
    if (durationMs < 600) {
      await VoiceNoteService.deletePlaintextFile(localPath);
      return;
    }

    if (!_isSecure) {
      await VoiceNoteService.deletePlaintextFile(localPath);
      return;
    }

    final sentAt = DateTime.now();

    final discoverState = ref.read(discoverNotifierProvider);
    final knownUser = discoverState.findUserByMaster(widget.recipientMasterPubKey) ??
        discoverState.findUser(widget.recipientNostrPubKey);
    final targetNostrPubKey = (knownUser != null && knownUser.nostrPubKeyHex.isNotEmpty)
        ? knownUser.nostrPubKeyHex
        : widget.recipientNostrPubKey;

    final chatProvider = ref.read(chatNotifierProvider);
    final canSend = await chatProvider.canSendToPeer(targetNostrPubKey);
    if (!canSend) {
      await VoiceNoteService.deletePlaintextFile(localPath);
      return;
    }

    chatProvider.addChat(DiscoverUser(
      masterPubKeyHex: widget.recipientMasterPubKey,
      nostrPubKeyHex: targetNostrPubKey,
      username: widget.recipientUsername,
      lastSeen: sentAt,
    ));

    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    }

    // Immediately dispatch outgoing voice note:
    // 1. Optimistic bubble appears instantly on the chat screen with sending spinner
    // 2. Text composer is immediately active, letting user type with zero freeze
    // 3. Blossom upload and Signal ratchet run asynchronously in background
    unawaited(chatProvider.sendOutgoingVoiceNote(
      recipientNostrPubKey: targetNostrPubKey,
      localAudioPath: localPath,
      durationMs: durationMs,
      waveform: waveform,
      sentAt: sentAt,
    ));
  }

  /// Determines if a message contains only Unicode emojis (1-15 characters)
  bool _isEmojiOnly(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return false;
    // Disallow regular letters or numbers
    if (RegExp(r'[a-zA-Z0-9]').hasMatch(trimmed)) return false;

    // Unicode emoji sequence check
    for (final rune in trimmed.runes) {
      if (rune == 0x20 || rune == 0xFE0F || rune == 0x200D) continue;
      final isEmoji = (rune >= 0x1F300 && rune <= 0x1FAFF) ||
          (rune >= 0x1F600 && rune <= 0x1F64F) ||
          (rune >= 0x1F680 && rune <= 0x1F6FF) ||
          (rune >= 0x2600 && rune <= 0x27BF) ||
          (rune >= 0x2300 && rune <= 0x23FF) ||
          (rune >= 0x2B50 && rune <= 0x2B55) ||
          (rune >= 0x1F1E6 && rune <= 0x1F1FF) ||
          (rune >= 0x2000 && rune <= 0x3300) ||
          rune == 0x00A9 || rune == 0x00AE;
      if (!isEmoji) return false;
    }
    // Keep it clean and avoid huge essays of symbols
    return trimmed.runes.length <= 15;
  }

  Widget _buildStatusIcon(ChatMessage msg, Color timeColor) {
    if (msg.status == MessageStatus.sending) {
      return Icon(
        Icons.access_time_rounded,
        size: 13,
        color: timeColor,
      );
    } else if (msg.status == MessageStatus.failed) {
      return GestureDetector(
        onTap: () => _retrySendMessage(msg),
        child: const Tooltip(
          message: 'Failed to send. Tap to retry.',
          child: Icon(
            Icons.refresh_rounded,
            size: 15,
            color: Color(0xFFEF4444),
          ),
        ),
      );
    } else if (msg.status == MessageStatus.delivered) {
      return Icon(
        Icons.done_all_rounded,
        size: 15,
        color: timeColor, // Double grey ticks for delivered
      );
    } else if (msg.status == MessageStatus.read) {
      return const Icon(
        Icons.done_all_rounded,
        size: 15,
        color: Color(0xFF38BDF8), // Sky-blue ticks for read
      );
    } else if (msg.status == MessageStatus.expired) {
      return const Tooltip(
        message: 'Message delivery expired',
        child: Icon(
          Icons.timer_off_outlined,
          size: 15,
          color: Color(0xFF9CA3AF),
        ),
      );
    } else {
      // MessageStatus.sent: single grey tick
      return Icon(
        Icons.check_rounded,
        size: 15,
        color: timeColor,
      );
    }
  }

  String _formatTime(DateTime time) {
    final period = time.hour >= 12 ? 'pm' : 'am';
    final hour = time.hour % 12 == 0 ? 12 : time.hour % 12;
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute $period';
  }

  String _formatDateSeparator(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final messageDate = DateTime(date.year, date.month, date.day);
    final diffDays = today.difference(messageDate).inDays;

    if (diffDays == 0) return 'Today';
    if (diffDays == 1) return 'Yesterday';

    const months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December'
    ];
    if (date.year == now.year) {
      return '${months[date.month - 1]} ${date.day}';
    }
    return '${months[date.month - 1]} ${date.day}, ${date.year}';
  }

  Future<void> _showClearChatDialog(bool isDark) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: isDark ? const Color(0xFF212121) : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.delete_sweep_rounded, color: Color(0xFFEF4444), size: 24),
            SizedBox(width: 10),
            Text(
              'Clear chat history?',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        content: Text(
          'All messages, photos, videos, voice notes, and documents in this chat will be permanently deleted from this device and cannot be recovered.',
          style: TextStyle(
            fontSize: 14,
            color: isDark ? const Color(0xFFD4D4D8) : const Color(0xFF52525B),
            height: 1.4,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              'Cancel',
              style: TextStyle(color: isDark ? Colors.white70 : const Color(0xFF64748B)),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFEF4444),
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear Chat'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      final discoverState = ref.read(discoverNotifierProvider);
      final knownUser = discoverState.findUser(widget.recipientNostrPubKey) ??
          discoverState.findUserByMaster(widget.recipientMasterPubKey);
      final targetKey = (knownUser != null && knownUser.nostrPubKeyHex.isNotEmpty)
          ? knownUser.nostrPubKeyHex
          : widget.recipientNostrPubKey;

      await _chatProvider.clearConversation(widget.recipientNostrPubKey);
      if (targetKey.isNotEmpty && targetKey != widget.recipientNostrPubKey) {
        await _chatProvider.clearConversation(targetKey);
      }

      if (!mounted) return;
    }
  }

  Future<void> _showBlockUserDialog(bool isDark, String? name) async {
    final effectiveName = (name != null && name.isNotEmpty) ? name : widget.recipientUsername;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: isDark ? const Color(0xFF212121) : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            const Icon(Icons.block_rounded, color: Color(0xFF2B5278), size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Block $effectiveName?',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        content: Text(
          'Blocked contacts cannot message you or see your online status.',
          style: TextStyle(
            fontSize: 14,
            color: isDark ? const Color(0xFFD4D4D8) : const Color(0xFF52525B),
            height: 1.4,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              'Cancel',
              style: TextStyle(color: isDark ? Colors.white70 : const Color(0xFF64748B)),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF2B5278),
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Block'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      final discoverState = ref.read(discoverNotifierProvider);
      final knownUser = discoverState.findUser(widget.recipientNostrPubKey) ??
          discoverState.findUserByMaster(widget.recipientMasterPubKey);
      final targetKey = (knownUser != null && knownUser.nostrPubKeyHex.isNotEmpty)
          ? knownUser.nostrPubKeyHex
          : widget.recipientNostrPubKey;

      await _chatProvider.blockUser(
        widget.recipientNostrPubKey,
        peerMasterPubKey: widget.recipientMasterPubKey,
      );
      if (targetKey.isNotEmpty && targetKey != widget.recipientNostrPubKey) {
        await _chatProvider.blockUser(targetKey);
      }

      ref.read(discoverNotifierProvider).markUserOfflineByPubkey(widget.recipientNostrPubKey);
      ref.read(discoverNotifierProvider).markUserOfflineByPubkey(targetKey);
      if (widget.recipientMasterPubKey.isNotEmpty) {
        ref.read(discoverNotifierProvider).markUserOfflineByPubkey(widget.recipientMasterPubKey);
      }

      if (mounted) {
        setState(() {
          _sessionError = null;
          _isSecure = false;
          _isEstablishing = false;
        });
      }
    }
  }

  Future<void> _showUnblockDialog(bool isDark, String? name) async {
    final effectiveName = (name != null && name.isNotEmpty) ? name : widget.recipientUsername;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: isDark ? const Color(0xFF212121) : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            const Icon(Icons.lock_open_rounded, color: Color(0xFF2B5278), size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Unblock $effectiveName?',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        content: Text(
          'Unblock this contact to send and receive messages.',
          style: TextStyle(
            fontSize: 14,
            color: isDark ? const Color(0xFFD4D4D8) : const Color(0xFF52525B),
            height: 1.4,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              'Cancel',
              style: TextStyle(color: isDark ? Colors.white70 : const Color(0xFF64748B)),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF2B5278),
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Unblock'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      final discoverState = ref.read(discoverNotifierProvider);
      final knownUser = discoverState.findUser(widget.recipientNostrPubKey) ??
          discoverState.findUserByMaster(widget.recipientMasterPubKey);
      final targetKey = (knownUser != null && knownUser.nostrPubKeyHex.isNotEmpty)
          ? knownUser.nostrPubKeyHex
          : widget.recipientNostrPubKey;

      await _chatProvider.unblockUser(
        widget.recipientNostrPubKey,
        peerMasterPubKey: widget.recipientMasterPubKey,
      );
      if (targetKey.isNotEmpty && targetKey != widget.recipientNostrPubKey) {
        await _chatProvider.unblockUser(targetKey);
      }

      if (mounted) {
        _checkAndEstablishSession();
      }
    }
  }

  void _onHeaderTapped({
    required BuildContext context,
    required bool isDark,
    required String? displayName,
    required String username,
    required String? bio,
    required bool isOnline,
    required bool isKnownAnnounced,
  }) {
    final isDesktopLayout = MediaQuery.of(context).size.width >= 700;
    if (isDesktopLayout) {
      setState(() {
        _isProfilePanelOpen = !_isProfilePanelOpen;
      });
    } else {
      _showMobileProfileSheet(
        context,
        isDark: isDark,
        displayName: displayName,
        username: username,
        bio: bio,
        isOnline: isOnline,
        isKnownAnnounced: isKnownAnnounced,
      );
    }
  }

  void _showMobileProfileSheet(
    BuildContext context, {
    required bool isDark,
    required String? displayName,
    required String username,
    required String? bio,
    required bool isOnline,
    required bool isKnownAnnounced,
  }) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.88,
          ),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF171717) : Colors.white,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.35),
                blurRadius: 24,
                offset: const Offset(0, -6),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 10),
              // Drag handle pill
              Center(
                child: Container(
                  width: 38,
                  height: 4.5,
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF3F3F46) : const Color(0xFFCBD5E1),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
              // Header bar
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 10, 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Contact info',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.3,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded, size: 22),
                      tooltip: 'Close',
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, thickness: 0.8),
              // Scrollable Content
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
                  child: _buildProfileContent(
                    ctx,
                    isDark: isDark,
                    displayName: displayName,
                    username: username,
                    bio: bio,
                    isOnline: isOnline,
                    isKnownAnnounced: isKnownAnnounced,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDesktopProfilePanel(
    BuildContext context, {
    required bool isDark,
    required String? displayName,
    required String username,
    required String? bio,
    required bool isOnline,
    required bool isKnownAnnounced,
    required Color backgroundColor,
    required Color borderColor,
  }) {
    return Container(
      color: backgroundColor,
      child: Column(
        children: [
          // Side Panel Header (aligned with AppBar 62px height)
          Container(
            height: 62,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: backgroundColor,
              border: Border(
                bottom: BorderSide(
                  color: borderColor,
                  width: 0.8,
                ),
              ),
            ),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.close_rounded, size: 21),
                  tooltip: 'Close contact info',
                  onPressed: () {
                    setState(() {
                      _isProfilePanelOpen = false;
                    });
                  },
                ),
                const SizedBox(width: 8),
                const Text(
                  'Contact info',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          // Scrollable Body
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
              child: _buildProfileContent(
                context,
                isDark: isDark,
                displayName: displayName,
                username: username,
                bio: bio,
                isOnline: isOnline,
                isKnownAnnounced: isKnownAnnounced,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProfileContent(
    BuildContext context, {
    required bool isDark,
    required String? displayName,
    required String username,
    required String? bio,
    required bool isOnline,
    required bool isKnownAnnounced,
  }) {
    final subtextColor = isDark ? const Color(0xFF8E959B) : const Color(0xFF64748B);
    final primaryTextColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final dividerColor = isDark ? const Color(0xFF222226) : const Color(0xFFF0F0F2);

    final effectiveBio = (bio != null && bio.trim().isNotEmpty)
        ? bio.trim()
        : (isKnownAnnounced
            ? 'Hey there! I am using MNDO'
            : 'Identity protected as Ghost');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),

        // 1. Clean Circular Identicon Hero (with subtle ring, online dot)
        Center(
          child: Stack(
            alignment: Alignment.bottomRight,
            children: [
              Container(
                width: 108,
                height: 108,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: isDark ? const Color(0xFF2A2A32) : const Color(0xFFE2E8F0),
                    width: 2.0,
                  ),
                ),
                child: ClipOval(
                  child: Identicon(
                    seed: widget.recipientMasterPubKey,
                    size: 108,
                  ),
                ),
              ),
              if (isOnline)
                Positioned(
                  right: 4,
                  bottom: 4,
                  child: Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      color: const Color(0xFF10B981),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: isDark ? const Color(0xFF171717) : Colors.white,
                        width: 3.0,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 18),

        // 2. Name & Identity Header (Pure Typography)
        if (displayName != null && displayName.isNotEmpty) ...[
          Text(
            displayName,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 21,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.3,
              color: primaryTextColor,
            ),
          ),
          const SizedBox(height: 4),
          Center(
            child: FormattedDisplayName(
              displayName: null,
              username: username,
              baseStyle: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w400,
                color: subtextColor,
              ),
            ),
          ),
        ] else ...[
          Center(
            child: FormattedDisplayName(
              displayName: null,
              username: username,
              baseStyle: TextStyle(
                fontSize: 21,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.3,
                color: primaryTextColor,
              ),
            ),
          ),
        ],
        const SizedBox(height: 8),

        // 3. Online status (Minimalist single line, no box)
        Center(
          child: isOnline
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 6.5,
                      height: 6.5,
                      decoration: const BoxDecoration(
                        color: Color(0xFF10B981),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    const Text(
                      'online',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFF10B981),
                      ),
                    ),
                  ],
                )
              : Text(
                  (_chatProvider.isUserBlocked(widget.recipientNostrPubKey) || _chatProvider.isUserBlocked(widget.recipientMasterPubKey))
                      ? 'last seen recently'
                      : (isKnownAnnounced ? 'last seen recently' : 'Ghost • Unannounced'),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.normal,
                    color: subtextColor,
                  ),
                ),
        ),
        const SizedBox(height: 24),

        // 4. Subtle Hairline Divider
        Divider(height: 1, thickness: 0.8, color: dividerColor),
        const SizedBox(height: 18),

        // 5. About (Bio) Section - Flat, Minimal, Elegant
        Text(
          'About',
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2,
            color: subtextColor,
          ),
        ),
        const SizedBox(height: 8),
        SelectableText(
          effectiveBio,
          style: TextStyle(
            fontSize: 14.5,
            height: 1.5,
            color: (bio == null || bio.trim().isEmpty) ? subtextColor : primaryTextColor,
            fontStyle: (bio == null || bio.trim().isEmpty) ? FontStyle.italic : FontStyle.normal,
          ),
        ),
        const SizedBox(height: 18),

        // 6. Subtle Hairline Divider
        Divider(height: 1, thickness: 0.8, color: dividerColor),
        const SizedBox(height: 18),

        // 7. Username Section - Flat, Minimal
        Text(
          'Username',
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2,
            color: subtextColor,
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: FormattedDisplayName(
                displayName: null,
                username: username,
                baseStyle: TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w500,
                  color: primaryTextColor,
                ),
              ),
            ),
            IconButton(
              icon: Icon(Icons.copy_rounded, size: 16, color: subtextColor),
              tooltip: 'Copy username',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              splashRadius: 16,
              onPressed: () {
                Clipboard.setData(ClipboardData(text: username));
              },
            ),
          ],
        ),
        const SizedBox(height: 18),

        // 8. Subtle Hairline Divider
        Divider(height: 1, thickness: 0.8, color: dividerColor),
        const SizedBox(height: 18),

        // 9. Public ID Section (Minimal one-liner with copy icon)
        Text(
          'Public ID',
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2,
            color: subtextColor,
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: Text(
                widget.recipientMasterPubKey.length > 24
                    ? '${widget.recipientMasterPubKey.substring(0, 12)}...${widget.recipientMasterPubKey.substring(widget.recipientMasterPubKey.length - 12)}'
                    : widget.recipientMasterPubKey,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                  color: subtextColor,
                ),
              ),
            ),
            IconButton(
              icon: Icon(Icons.copy_rounded, size: 16, color: subtextColor),
              tooltip: 'Copy public key',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              splashRadius: 16,
              onPressed: () {
                Clipboard.setData(ClipboardData(text: widget.recipientMasterPubKey));
              },
            ),
          ],
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isDesktopLayout = MediaQuery.of(context).size.width >= 700;

    // Early app theme background colors (#141414 dark, #FDFDFD light)
    final backgroundColor = isDark ? const Color(0xFF171717) : const Color(0xFFFDFDFD);
    final borderColor = isDark ? const Color(0xFF2E2E2E) : const Color(0xFFE4E4E7);

    final discoverState = ref.watch(discoverNotifierProvider);
    final chatState = ref.watch(chatNotifierProvider);
    DiscoverUser? activeUser;
    try {
      activeUser = chatState.activeChats.cast<DiscoverUser?>().firstWhere(
        (u) => u?.masterPubKeyHex == widget.recipientMasterPubKey || u?.nostrPubKeyHex == widget.recipientNostrPubKey,
        orElse: () => null,
      );
    } catch (_) {
      activeUser = null;
    }
    final discoveredUser = discoverState.findUserByMaster(widget.recipientMasterPubKey) ??
        discoverState.findUser(widget.recipientNostrPubKey);
    final knownUser = discoveredUser ?? activeUser;

    final isKnownAnnounced = knownUser != null && !knownUser.isHidden;
    final displayName = (isKnownAnnounced && knownUser.displayName != null && knownUser.displayName!.isNotEmpty)
        ? knownUser.displayName
        : (activeUser?.displayName ?? widget.recipientDisplayName);
    final username = (isKnownAnnounced && !knownUser.username.startsWith('Ghost #'))
        ? knownUser.username
        : (activeUser != null && !activeUser.username.startsWith('Ghost #') && !activeUser.isHidden
            ? activeUser.username
            : widget.recipientUsername);
    final bio = isKnownAnnounced
        ? (knownUser.bio ?? activeUser?.bio ?? widget.recipientBio)
        : (widget.recipientUsername.startsWith('Ghost #') ? null : widget.recipientBio);
    final signalService = ref.read(signalMessagingServiceProvider);
    final targetKey = (knownUser != null && knownUser.nostrPubKeyHex.isNotEmpty)
        ? knownUser.nostrPubKeyHex
        : widget.recipientNostrPubKey;
    final isUserBlocked = _chatProvider.isUserBlocked(widget.recipientNostrPubKey) ||
        _chatProvider.isUserBlocked(targetKey) ||
        _chatProvider.isUserBlocked(widget.recipientMasterPubKey);

    final isExplicitlyOffline = isUserBlocked || (discoveredUser?.isExplicitlyOffline == true) || (activeUser?.isExplicitlyOffline == true);
    final isOnline = !isUserBlocked && !isExplicitlyOffline && ((discoveredUser?.isOnline == true) || (activeUser?.isOnline == true));

    if (isUserBlocked) {
      if (_sessionError != null) {
        Future.microtask(() {
          if (mounted && _sessionError != null) {
            setState(() {
              _sessionError = null;
              _isEstablishing = false;
            });
          }
        });
      }
    } else {
      final isPeerBlocked = _chatProvider.isPeerIdentityBlocked(widget.recipientNostrPubKey) ||
          _chatProvider.isPeerIdentityBlocked(targetKey) ||
          (signalService?.isIdentityBlocked(widget.recipientNostrPubKey) ?? false) ||
          (signalService?.isIdentityBlocked(targetKey) ?? false);

      if (isPeerBlocked && _isSecure) {
        Future.microtask(() {
          if (mounted && _isSecure) {
            setState(() {
              _isSecure = false;
              _sessionError = "Security Alert: Peer's encryption key changed. Verification required.";
            });
          }
        });
      } else if (!_isSecure && !isPeerBlocked && signalService != null) {
        Future.microtask(() async {
          if (!mounted || _isSecure) return;
          final currentBlocked = _chatProvider.isPeerIdentityBlocked(widget.recipientNostrPubKey) ||
              _chatProvider.isPeerIdentityBlocked(targetKey) ||
              signalService.isIdentityBlocked(widget.recipientNostrPubKey) ||
              signalService.isIdentityBlocked(targetKey);
          if (currentBlocked) return;

          final canSend1 = await signalService.canSendToPeer(widget.recipientNostrPubKey);
          final canSend2 = await signalService.canSendToPeer(targetKey);
          if ((canSend1 || canSend2) && mounted && !_isSecure) {
            setState(() {
              _isSecure = true;
              _isEstablishing = false;
              _sessionError = null;
            });
          }
        });
      }
    }

    return Scaffold(
      backgroundColor: backgroundColor,
      resizeToAvoidBottomInset: true,
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(62),
        child: AppBar(
          elevation: 0,
          scrolledUnderElevation: 0,
          surfaceTintColor: Colors.transparent,
          backgroundColor: backgroundColor,
          leading: const BackButton(),
          titleSpacing: 0,
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(1),
            child: Container(
              color: borderColor,
              height: 0.8,
            ),
          ),
          title: InkWell(
            key: const ValueKey('chat_header_profile_button'),
            borderRadius: BorderRadius.circular(10),
            onTap: () => _onHeaderTapped(
              context: context,
              isDark: isDark,
              displayName: displayName,
              username: username,
              bio: bio,
              isOnline: isOnline,
              isKnownAnnounced: isKnownAnnounced,
            ),
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                child: Row(
                  children: [
                    // Circular avatar with presence badge
                    Stack(
                      alignment: Alignment.bottomRight,
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: borderColor,
                              width: 1.5,
                            ),
                          ),
                          child: ClipOval(
                            child: Identicon(
                              seed: widget.recipientMasterPubKey,
                              size: 40,
                            ),
                          ),
                        ),
                        if (isOnline)
                          Positioned(
                            right: 0,
                            bottom: 0,
                            child: Container(
                              width: 11,
                              height: 11,
                              decoration: BoxDecoration(
                                color: const Color(0xFF4BD151),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: backgroundColor,
                                  width: 2,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          FormattedDisplayName(
                            displayName: displayName,
                            username: username,
                            baseStyle: TextStyle(
                              fontSize: 15.5,
                              fontWeight: FontWeight.w600,
                              letterSpacing: -0.2,
                              color: isDark ? Colors.white : const Color(0xFF17202A),
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 1.5),
                          _buildSubtitle(isOnline, isDark),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            if (!_isSecure && !_isEstablishing)
              IconButton(
                icon: Icon(Icons.refresh_rounded, color: isDark ? const Color(0xFF8E959B) : const Color(0xFF64748B)),
                onPressed: _checkAndEstablishSession,
                tooltip: 'Retry Secure Session',
              ),
            PopupMenuButton<String>(
              icon: Icon(
                Icons.more_vert_rounded,
                color: isDark ? const Color(0xFF8E959B) : const Color(0xFF64748B),
              ),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              onSelected: (val) {
                if (val == 'info') {
                  _onHeaderTapped(
                    context: context,
                    isDark: isDark,
                    displayName: displayName,
                    username: username,
                    bio: bio,
                    isOnline: isOnline,
                    isKnownAnnounced: isKnownAnnounced,
                  );
                } else if (val == 'retry') {
                  _checkAndEstablishSession();
                } else if (val == 'clear_chat') {
                  _showClearChatDialog(isDark);
                } else if (val == 'toggle_block') {
                  final isCurrentlyBlocked = _chatProvider.isUserBlocked(widget.recipientNostrPubKey) ||
                      _chatProvider.isUserBlocked(targetKey);
                  if (isCurrentlyBlocked) {
                    _showUnblockDialog(isDark, displayName);
                  } else {
                    _showBlockUserDialog(isDark, displayName);
                  }
                }
              },
              itemBuilder: (context) {
                final isCurrentlyBlocked = _chatProvider.isUserBlocked(widget.recipientNostrPubKey) ||
                    _chatProvider.isUserBlocked(targetKey);
                return [
                  PopupMenuItem(
                    value: 'info',
                    child: Row(
                      children: [
                        Icon(Icons.person_outline_rounded, size: 18, color: isDark ? Colors.white : const Color(0xFF171717)),
                        const SizedBox(width: 10),
                        const Text('Contact info', style: TextStyle(fontSize: 14)),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'retry',
                    child: Row(
                      children: [
                        Icon(Icons.sync_rounded, size: 18, color: isDark ? Colors.white70 : const Color(0xFF171717)),
                        const SizedBox(width: 10),
                        const Text('Refresh Connection', style: TextStyle(fontSize: 14)),
                      ],
                    ),
                  ),
                  const PopupMenuDivider(),
                  PopupMenuItem(
                    value: 'clear_chat',
                    child: Row(
                      children: [
                        Icon(Icons.delete_sweep_rounded, size: 18, color: isDark ? Colors.white70 : const Color(0xFF171717)),
                        const SizedBox(width: 10),
                        const Text('Clear chat', style: TextStyle(fontSize: 14)),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'toggle_block',
                    child: Row(
                      children: [
                        Icon(
                          isCurrentlyBlocked ? Icons.lock_open_rounded : Icons.block_rounded,
                          size: 18,
                          color: isDark ? Colors.white70 : const Color(0xFF171717),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          isCurrentlyBlocked ? 'Unblock user' : 'Block user',
                          style: const TextStyle(fontSize: 14),
                        ),
                      ],
                    ),
                  ),
                ];
              },
            ),
            const SizedBox(width: 4),
          ],
        ),
      ),
      body: Row(
        children: [
          Expanded(
            child: Container(
        decoration: BoxDecoration(
          color: backgroundColor,
          image: DecorationImage(
            image: AssetImage(
              isDark ? 'assets/white-bg-chat.png' : 'assets/dark-bg-chat.png',
            ),
            repeat: ImageRepeat.repeat,
            alignment: Alignment.topLeft,
            scale: 0.18,
            opacity: isDark ? 0.04 : 0.025,
          ),
        ),
        child: Column(
          children: [
            if (_sessionError != null && !isUserBlocked)
              InkWell(
                onTap: _checkAndEstablishSession,
                child: Container(
                  width: double.infinity,
                  color: isDark ? const Color(0xFF1E2630) : const Color(0xFFEDF2F7),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
                  child: Row(
                    children: [
                      const Icon(Icons.info_outline_rounded, color: Color(0xFF2B5278), size: 16),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _sessionError!,
                          style: TextStyle(
                            color: isDark ? Colors.white70 : const Color(0xFF2B5278),
                            fontSize: 12,
                            fontWeight: FontWeight.w400,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const Text(
                        'Tap to retry',
                        style: TextStyle(
                          color: Color(0xFF2B5278),
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 840),
                  child: Consumer(
                    builder: (context, ref, _) {
                      final discoverState = ref.watch(discoverNotifierProvider);
                      final knownUser = discoverState.findUserByMaster(widget.recipientMasterPubKey) ??
                          discoverState.findUser(widget.recipientNostrPubKey);
                      final currentKey = (knownUser != null && knownUser.nostrPubKeyHex.isNotEmpty)
                          ? knownUser.nostrPubKeyHex
                          : widget.recipientNostrPubKey;

                      final messages = ref.watch(chatNotifierProvider.select(
                        (provider) => provider.getMessagesFor(
                          currentKey,
                          masterPubKeyHex: widget.recipientMasterPubKey,
                        ).toList(),
                      ));

                      if (messages.isEmpty) {
                        return _buildEmptyState(isDark);
                      }

                      // Inverted list: index 0 is the newest message
                      final reversedMessages = messages.reversed.toList();

                      return ScrollConfiguration(
                        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
                        child: ListView.builder(
                          controller: _scrollController,
                          reverse: true,
                          padding: EdgeInsets.symmetric(
                            horizontal: _isDesktop ? 24 : 12,
                            vertical: 10,
                          ),
                          itemCount: reversedMessages.length,
                          itemBuilder: (context, index) {
                            final msg = reversedMessages[index];
                            final isMine = msg.isMe;

                            // Consecutive grouping detection:
                            // The chronologically prior message is at index + 1 in a reversed list
                            final hasPrior = index < reversedMessages.length - 1;
                            final priorMsg = hasPrior ? reversedMessages[index + 1] : null;
                            final isConsecutive = priorMsg != null && priorMsg.isMe == isMine;

                            // Date header detection:
                            // If there is no prior message (oldest in list), or the day changed from prior message
                            final showDateHeader = priorMsg == null ||
                                priorMsg.timestamp.year != msg.timestamp.year ||
                                priorMsg.timestamp.month != msg.timestamp.month ||
                                priorMsg.timestamp.day != msg.timestamp.day;

                            final verticalMargin = isConsecutive ? 3.0 : 10.0;
                            final itemKey = 'msg_${msg.messageId}_${msg.status.name}';

                            return KeyedSubtree(
                              key: ValueKey(itemKey),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (showDateHeader)
                                    Padding(
                                      padding: const EdgeInsets.symmetric(vertical: 14.0),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                                        decoration: BoxDecoration(
                                          color: isDark
                                              ? const Color(0xFF212121)
                                              : const Color(0xFFE4E4E7),
                                          borderRadius: BorderRadius.circular(12),
                                          border: Border.all(
                                            color: borderColor,
                                            width: 0.8,
                                          ),
                                        ),
                                        child: Text(
                                          _formatDateSeparator(msg.timestamp),
                                          style: TextStyle(
                                            fontSize: 11.5,
                                            fontWeight: FontWeight.w500,
                                            color: isDark ? const Color(0xFFD4D4D8) : const Color(0xFF3F3F46),
                                          ),
                                        ),
                                      ),
                                    ),
                                  Padding(
                                    padding: EdgeInsets.only(bottom: verticalMargin),
                                    child: _buildMessageItem(msg, isMine, isDark, isConsecutive),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),

            // Expanding Pill Composer
            _buildMessageComposer(isDark),
          ],
        ),
      ),
    ),
    if (_isProfilePanelOpen && isDesktopLayout) ...[
      Container(
        width: 1,
        color: borderColor,
      ),
      SizedBox(
        width: 360,
        child: _buildDesktopProfilePanel(
          context,
          isDark: isDark,
          displayName: displayName,
          username: username,
          bio: bio,
          isOnline: isOnline,
          isKnownAnnounced: isKnownAnnounced,
          backgroundColor: backgroundColor,
          borderColor: borderColor,
        ),
      ),
    ],
  ],
),
    );
  }

  Widget _buildSubtitle(bool isOnline, bool isDark) {
    final discoverState = ref.watch(discoverNotifierProvider);
    final knownUser = discoverState.findUser(widget.recipientNostrPubKey) ??
        discoverState.findUserByMaster(widget.recipientMasterPubKey);
    final targetKey = (knownUser != null && knownUser.nostrPubKeyHex.isNotEmpty)
        ? knownUser.nostrPubKeyHex
        : widget.recipientNostrPubKey;
    final isBlocked = _chatProvider.isUserBlocked(widget.recipientNostrPubKey) ||
        _chatProvider.isUserBlocked(targetKey) ||
        _chatProvider.isUserBlocked(widget.recipientMasterPubKey);

    if (isBlocked) {
      return Text(
        'last seen recently',
        style: TextStyle(
          fontSize: 11.5,
          color: isDark ? const Color(0xFF8E959B) : const Color(0xFF64748B),
          fontWeight: FontWeight.normal,
        ),
      );
    }

    if (_isEstablishing) {
      return Text(
        'Connecting...',
        style: TextStyle(
          fontSize: 11.5,
          color: isDark ? const Color(0xFF8E959B) : const Color(0xFF64748B),
          fontWeight: FontWeight.normal,
        ),
      );
    }

    if (!_isSecure) {
      final isIdentityBlocked = _chatProvider.isPeerIdentityBlocked(widget.recipientNostrPubKey) ||
          _chatProvider.isPeerIdentityBlocked(targetKey);
      return InkWell(
        onTap: isIdentityBlocked ? _showSafetyNumberDialog : _checkAndEstablishSession,
        child: Text(
          isIdentityBlocked ? 'Key Changed (Tap to Verify)' : 'Tap to retry connection',
          style: TextStyle(
            fontSize: 11.5,
            color: isIdentityBlocked ? const Color(0xFFE53935) : const Color(0xFF2B5278),
            fontWeight: FontWeight.w500,
          ),
        ),
      );
    }

    return Text(
      isOnline ? 'online' : 'last seen recently',
      style: TextStyle(
        fontSize: 11.5,
        color: isDark ? const Color(0xFF8E959B) : const Color(0xFF64748B),
        fontWeight: FontWeight.normal,
      ),
    );
  }

  Widget _buildEmptyState(bool isDark) {
    return Center(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF212121) : const Color(0xFFF4F4F5),
                shape: BoxShape.circle,
                border: Border.all(
                  color: isDark ? const Color(0xFF2E2E2E) : const Color(0xFFE4E4E7),
                  width: 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.05),
                    blurRadius: 16,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Icon(Icons.lock_outline_rounded, size: 36, color: isDark ? Colors.white : const Color(0xFF171717)),
            ),
            const SizedBox(height: 14),
            Text(
              'No messages yet',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: isDark ? Colors.white : const Color(0xFF17202A),
              ),
            ),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40.0),
              child: Text(
                'end-to-end encrypted',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: isDark ? const Color(0xFF8E959B) : const Color(0xFF64748B),
                  height: 1.4,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showSafetyNumberDialog() {
    final signalService = ref.read(signalMessagingServiceProvider);
    final discoverState = ref.read(discoverNotifierProvider);
    final knownUser = discoverState.findUserByMaster(widget.recipientMasterPubKey) ??
        discoverState.findUser(widget.recipientNostrPubKey);
    final targetNostrPubKey = (knownUser != null && knownUser.nostrPubKeyHex.isNotEmpty)
        ? knownUser.nostrPubKeyHex
        : widget.recipientNostrPubKey;

    final rawSafetyNumber = signalService?.computeSafetyNumber(targetNostrPubKey) ??
        signalService?.computeSafetyNumber(widget.recipientNostrPubKey);
    final formattedSafetyNumber = rawSafetyNumber != null
        ? SignalMessagingService.formatSafetyNumber(rawSafetyNumber)
        : 'Safety Number unavailable offline';

    final isDark = Theme.of(context).brightness == Brightness.dark;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: isDark ? const Color(0xFF212121) : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: const [
            Icon(Icons.shield_outlined, color: Color(0xFFFFA000), size: 24),
            SizedBox(width: 10),
            Text('Identity Verification', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'The encryption key for ${widget.recipientDisplayName ?? widget.recipientUsername} does not match your saved records.',
                style: const TextStyle(fontSize: 13.5),
              ),
              const SizedBox(height: 10),
              Text(
                'Compare this Safety Number with your contact to verify their identity and prevent impersonation:',
                style: TextStyle(fontSize: 12.5, color: isDark ? Colors.white70 : Colors.black87),
              ),
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: isDark ? Colors.black26 : const Color(0xFFF4F6F8),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: isDark ? Colors.white12 : Colors.black12),
                ),
                child: SelectableText(
                  formattedSafetyNumber,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.1,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'If this contact recently reinstalled the app or switched devices, you can verify and trust this key. If not, someone may be intercepting your communications.',
                style: TextStyle(fontSize: 11.5, color: isDark ? Colors.white54 : Colors.black54),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Keep Blocked'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF2E7D32),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () async {
              Navigator.of(ctx).pop();
              await ref.read(chatNotifierProvider).approvePeerIdentity(targetNostrPubKey);
              if (targetNostrPubKey != widget.recipientNostrPubKey) {
                await ref.read(chatNotifierProvider).approvePeerIdentity(widget.recipientNostrPubKey);
              }
              if (mounted) {
                await _checkAndEstablishSession();
              }
            },
            child: const Text('Trust & Unlock'),
          ),
        ],
      ),
    );
  }

  Widget _buildSecurityNoticeBubble(ChatMessage msg, bool isDark) {
    return Center(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: _showSafetyNumberDialog,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 10, horizontal: 20),
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF332700) : const Color(0xFFFFF9E6),
            border: Border.all(
              color: isDark
                  ? const Color(0xFFFFD54F).withValues(alpha: 0.3)
                  : const Color(0xFFFFB300).withValues(alpha: 0.5),
              width: 1,
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.warning_amber_rounded,
                    size: 18,
                    color: Color(0xFFFFA000),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      msg.text.replaceFirst("⚠️ ", ""),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                        color: isDark ? const Color(0xFFFFE082) : const Color(0xFF6D4C00),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                "Tap to view Safety Number & Verify",
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: isDark ? const Color(0xFFFFCA28) : const Color(0xFFB78103),
                  decoration: TextDecoration.underline,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMessageItem(ChatMessage msg, bool isMine, bool isDark, bool isConsecutive) {
    if (msg.text.contains("Security Notice: Peer's Signal identity key changed")) {
      return _buildSecurityNoticeBubble(msg, isDark);
    }

    final mediaPayload = MediaPayload.tryParse(msg.text);
    if (mediaPayload != null) {
      if (mediaPayload.isVoiceNote) {
        return _buildVoiceNoteBubble(msg, mediaPayload.toVoiceNotePayload(), isMine, isDark, isConsecutive);
      }
      final timeStr = _formatTime(msg.timestamp);
      final timeColor = isMine
          ? Colors.white.withValues(alpha: 0.7)
          : (isDark ? Colors.white.withValues(alpha: 0.5) : const Color(0xFF8E959B));
      return MediaBubble(
        key: ValueKey('media_${msg.timestamp.microsecondsSinceEpoch}_${mediaPayload.fileHash}_$isMine'),
        msg: msg,
        payload: mediaPayload,
        isMine: isMine,
        isDark: isDark,
        isConsecutive: isConsecutive,
        timeStr: timeStr,
        statusIcon: _buildStatusIcon(msg, timeColor),
        onRetry: () {
          ref.read(chatNotifierProvider).retryOutgoingMessage(widget.recipientNostrPubKey, msg);
        },
      );
    }

    final voicePayload = VoiceNotePayload.tryParse(msg.text);
    if (voicePayload != null) {
      return _buildVoiceNoteBubble(msg, voicePayload, isMine, isDark, isConsecutive);
    }

    final isEmoji = _isEmojiOnly(msg.text);

    if (isEmoji) {
      return _buildEmojiMessage(msg, isMine, isDark);
    }

    return _buildTextBubble(msg, isMine, isDark, isConsecutive);
  }

  Widget _buildVoiceNoteBubble(
    ChatMessage msg,
    VoiceNotePayload payload,
    bool isMine,
    bool isDark,
    bool isConsecutive,
  ) {
    final timeStr = _formatTime(msg.timestamp);
    final timeColor = isMine
        ? Colors.white.withValues(alpha: 0.7)
        : (isDark ? Colors.white.withValues(alpha: 0.5) : const Color(0xFF8E959B));
    final voiceKey = 'vn_${msg.timestamp.microsecondsSinceEpoch}_${payload.fileHash}_$isMine';

    return VoiceNoteBubble(
      key: ValueKey(voiceKey),
      msg: msg,
      payload: payload,
      isMine: isMine,
      isDark: isDark,
      isConsecutive: isConsecutive,
      timeStr: timeStr,
      statusIcon: _buildStatusIcon(msg, timeColor),
      onRetry: () {
        ref.read(chatNotifierProvider).retryOutgoingMessage(widget.recipientNostrPubKey, msg);
      },
    );
  }

  /// Telegram Layer 2: Animated Large Emoji Message
  Widget _buildEmojiMessage(ChatMessage msg, bool isMine, bool isDark) {
    final timeStr = _formatTime(msg.timestamp);

    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 0.86, end: 1.0),
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutBack,
        builder: (context, scale, child) {
          return Transform.scale(
            scale: scale,
            alignment: isMine ? Alignment.bottomRight : Alignment.bottomLeft,
            child: child,
          );
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 2.0),
          child: Column(
            crossAxisAlignment: isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                msg.text,
                style: const TextStyle(
                  fontSize: 42,
                  height: 1.15,
                ),
              ),
              const SizedBox(height: 2),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xFF212121).withValues(alpha: 0.8)
                      : Colors.black.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      timeStr,
                      style: const TextStyle(
                        fontSize: 10,
                        color: Colors.white,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (isMine) ...[
                      const SizedBox(width: 3),
                      _buildStatusIcon(msg, Colors.white70),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// WhatsApp-style Message Bubble with Asymmetric Corners & Inline Timestamp
  Widget _buildTextBubble(ChatMessage msg, bool isMine, bool isDark, bool isConsecutive) {
    final timeStr = _formatTime(msg.timestamp);

    // Bubble Colors
    final bubbleColor = isMine
        ? const Color(0xFF2B5278)
        : (isDark ? const Color(0xFF242424) : Colors.white);

    final textColor = isMine
        ? Colors.white
        : (isDark ? Colors.white : const Color(0xFF17202A));

    final timeColor = isMine
        ? Colors.white.withValues(alpha: 0.7)
        : (isDark ? Colors.white.withValues(alpha: 0.5) : const Color(0xFF8E959B));

    // WhatsApp shape:
    // Outgoing first in group: top-right 2px, other 3 corners 8px
    // Incoming first in group: top-left 2px, other 3 corners 8px
    // Consecutive: all 4 corners 8px
    final borderRadius = BorderRadius.only(
      topLeft: Radius.circular(!isMine && !isConsecutive ? 2 : 8),
      topRight: Radius.circular(isMine && !isConsecutive ? 2 : 8),
      bottomLeft: const Radius.circular(8),
      bottomRight: const Radius.circular(8),
    );

    final maxBubbleWidth = _isDesktop ? 540.0 : MediaQuery.sizeOf(context).width * 0.76;

    final textStyle = TextStyle(
      fontSize: 15,
      height: 1.3,
      color: textColor,
    );

    final hasBlockFormatting = msg.text.contains('\n') ||
        msg.text.contains('```') ||
        msg.text.trimLeft().startsWith('>') ||
        RegExp(r'^\s*([-*•]|\d+\.)\s+', multiLine: true).hasMatch(msg.text);

    final textScaler = MediaQuery.textScalerOf(context);
    final textSpan = TextSpan(text: msg.text, style: textStyle);
    final textPainter = TextPainter(
      text: textSpan,
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
    )..layout(maxWidth: maxBubbleWidth - 26);

    final isSingleLine = !hasBlockFormatting && textPainter.computeLineMetrics().length <= 1;
    final timestampWidth = textScaler.scale(70.0) + (isMine ? 20.0 : 0.0);
    final fitsSingleLine = isSingleLine && (textPainter.width + timestampWidth <= (maxBubbleWidth - 26));

    final timestampWidget = Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          timeStr,
          style: TextStyle(
            fontSize: 11,
            color: timeColor,
            fontWeight: FontWeight.normal,
          ),
        ),
        if (isMine) ...[
          const SizedBox(width: 3.5),
          _buildStatusIcon(msg, timeColor),
        ],
      ],
    );

    Widget bubbleContent;
    if (fitsSingleLine) {
      bubbleContent = Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Flexible(
            child: WhatsAppFormattedText(
              text: msg.text,
              baseStyle: textStyle,
              isMine: isMine,
              isDark: isDark,
            ),
          ),
          const SizedBox(width: 8),
          timestampWidget,
        ],
      );
    } else {
      bubbleContent = IntrinsicWidth(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            WhatsAppFormattedText(
              text: msg.text,
              baseStyle: textStyle,
              isMine: isMine,
              isDark: isDark,
            ),
            const SizedBox(height: 2),
            Align(
              alignment: Alignment.bottomRight,
              child: Padding(
                padding: const EdgeInsets.only(left: 12.0),
                child: timestampWidget,
              ),
            ),
          ],
        ),
      );
    }

    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: () {
          Clipboard.setData(ClipboardData(text: msg.text));
        },
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: maxBubbleWidth,
          ),
          child: Container(
            padding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
            decoration: BoxDecoration(
              color: bubbleColor,
              borderRadius: borderRadius,
              border: !isMine
                  ? Border.all(
                      color: isDark
                          ? const Color(0xFF2E2E2E)
                          : const Color(0xFFE4E4E7),
                      width: 1,
                    )
                  : null,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.04),
                  blurRadius: 3,
                  offset: const Offset(0, 1),
                ),
              ],
            ),
            child: bubbleContent,
          ),
        ),
      ),
    );
  }

  /// Expanding Pill Message Composer (Floating without background bar)
  Widget _buildMessageComposer(bool isDark) {
    if (_isRecordingVoice) {
      return _buildVoiceRecordingBar(isDark);
    }

    final discoverState = ref.read(discoverNotifierProvider);
    final knownUser = discoverState.findUser(widget.recipientNostrPubKey) ??
        discoverState.findUserByMaster(widget.recipientMasterPubKey);
    final targetKey = (knownUser != null && knownUser.nostrPubKeyHex.isNotEmpty)
        ? knownUser.nostrPubKeyHex
        : widget.recipientNostrPubKey;
    final isBlocked = _chatProvider.isUserBlocked(widget.recipientNostrPubKey) ||
        _chatProvider.isUserBlocked(targetKey);

    if (isBlocked) {
      final activeUser = _chatProvider.activeChats.where((u) => u.nostrPubKeyHex == widget.recipientNostrPubKey).firstOrNull;
      final displayName = widget.recipientDisplayName ?? activeUser?.displayName ?? widget.recipientUsername;
      return SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 840),
            child: Container(
              margin: EdgeInsets.symmetric(horizontal: _isDesktop ? 24 : 12, vertical: 12),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF212121) : const Color(0xFFF4F4F5),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: isDark ? const Color(0xFF2E2E2E) : const Color(0xFFE4E4E7),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.block_rounded, size: 18, color: Color(0xFF2B5278)),
                  const SizedBox(width: 8),
                  Text(
                    'You blocked this contact. ',
                    style: TextStyle(
                      fontSize: 13.5,
                      color: isDark ? Colors.white70 : const Color(0xFF52525B),
                    ),
                  ),
                  GestureDetector(
                    onTap: () => _showUnblockDialog(isDark, displayName),
                    child: const Text(
                      'Tap to unblock',
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF2B5278),
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final borderColor = isDark ? const Color(0xFF2E2E2E) : const Color(0xFFE4E4E7);
    final inputColor = isDark ? const Color(0xFF212121) : Colors.white;

    return SafeArea(
      top: false,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 840),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: _isDesktop ? 24 : 10,
              vertical: 8,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Container(
                    constraints: const BoxConstraints(
                      minHeight: 46,
                      maxHeight: 130,
                    ),
                    decoration: BoxDecoration(
                      color: inputColor,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                        color: borderColor,
                        width: 1,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.08),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(left: 4.0, bottom: 2.0),
                          child: IconButton(
                            icon: Icon(
                              Icons.attach_file_rounded,
                              color: _isSecure
                                  ? (isDark ? Colors.white70 : const Color(0xFF64748B))
                                  : (isDark ? Colors.white24 : const Color(0xFFCBD5E1)),
                              size: 22,
                            ),
                            onPressed: _isSecure ? () => _showAttachmentMenu(context, isDark) : null,
                            tooltip: 'Attach media',
                          ),
                        ),
                        Expanded(
                          child: Focus(
                            onKeyEvent: (node, event) {
                              if (_isDesktop && event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.enter) {
                                final isShift = HardwareKeyboard.instance.isShiftPressed;
                                final isAlt = HardwareKeyboard.instance.isAltPressed;
                                final isControl = HardwareKeyboard.instance.isControlPressed;
                                final isMeta = HardwareKeyboard.instance.isMetaPressed;

                                if (isShift || isAlt || isControl || isMeta) {
                                  _insertNewlineAtCursor();
                                  return KeyEventResult.handled;
                                } else {
                                  if (_isSecure && _canSend) {
                                    _sendMessage();
                                  }
                                  return KeyEventResult.handled;
                                }
                              }
                              return KeyEventResult.ignored;
                            },
                            child: TextField(
                              controller: _controller,
                              focusNode: _focusNode,
                              enabled: _isSecure,
                              minLines: 1,
                              maxLines: 5,
                              textInputAction: TextInputAction.newline,
                              style: TextStyle(
                                fontSize: 15,
                                color: isDark ? Colors.white : const Color(0xFF17202A),
                              ),
                              decoration: InputDecoration(
                                hintText: _isSecure ? 'Message' : 'Waiting for secure session...',
                                hintStyle: TextStyle(
                                  fontSize: 15,
                                  color: isDark ? const Color(0xFF8E959B) : const Color(0xFF94A3B8),
                                ),
                                filled: false,
                                border: InputBorder.none,
                                enabledBorder: InputBorder.none,
                                focusedBorder: InputBorder.none,
                                contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                AnimatedScale(
                  scale: 1.0,
                  duration: const Duration(milliseconds: 160),
                  curve: Curves.easeOutCubic,
                  child: Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      color: _isSecure
                          ? const Color(0xFF2B5278)
                          : (isDark ? const Color(0xFF212121) : const Color(0xFFE2E8F0)),
                      shape: BoxShape.circle,
                      boxShadow: _isSecure
                          ? [
                              BoxShadow(
                                color: const Color(0xFF2B5278).withValues(alpha: 0.38),
                                blurRadius: 8,
                                offset: const Offset(0, 2),
                              ),
                            ]
                          : null,
                    ),
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      transitionBuilder: (child, animation) {
                        return ScaleTransition(
                          scale: animation,
                          child: child,
                        );
                      },
                      child: _canSend
                          ? IconButton(
                              key: const ValueKey('send_button'),
                              onPressed: _isSecure ? _sendMessage : null,
                              padding: EdgeInsets.zero,
                              tooltip: 'Send message',
                              icon: const Padding(
                                padding: EdgeInsets.only(left: 3.0),
                                child: Icon(
                                  Icons.send_rounded,
                                  color: Colors.white,
                                  size: 21,
                                ),
                              ),
                            )
                          : IconButton(
                              key: const ValueKey('mic_button'),
                              onPressed: _isSecure ? _startVoiceRecording : null,
                              padding: EdgeInsets.zero,
                              tooltip: 'Record voice note',
                              icon: Icon(
                                Icons.mic_rounded,
                                color: _isSecure
                                    ? Colors.white
                                    : (isDark ? Colors.white24 : const Color(0xFFCBD5E1)),
                                size: 22,
                              ),
                            ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildVoiceRecordingBar(bool isDark) {
    final borderColor = isDark ? const Color(0xFF2E2E2E) : const Color(0xFFE4E4E7);
    final inputColor = isDark ? const Color(0xFF212121) : Colors.white;
    final minutes = _recordingDurationSeconds ~/ 60;
    final seconds = _recordingDurationSeconds % 60;
    final timerStr = '$minutes:${seconds.toString().padLeft(2, '0')}';

    return SafeArea(
      top: false,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 840),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: _isDesktop ? 24 : 10,
              vertical: 8,
            ),
            child: Row(
              children: [
                // Trash / Discard Button
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF2A1C1C) : const Color(0xFFFFECEC),
                    shape: BoxShape.circle,
                  ),
                  child: IconButton(
                    onPressed: _cancelVoiceRecording,
                    tooltip: 'Discard recording',
                    icon: const Icon(
                      Icons.delete_outline_rounded,
                      color: Color(0xFFEF4444),
                      size: 22,
                    ),
                  ),
                ),
                const SizedBox(width: 8),

                // Live recording pill
                Expanded(
                  child: Container(
                    height: 46,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(
                      color: inputColor,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: borderColor, width: 1),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.08),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        const _PulsingRedDot(),
                        const SizedBox(width: 8),
                        Text(
                          timerStr,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: isDark ? Colors.white : const Color(0xFF17202A),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _LiveWaveformVisualizer(
                            amplitudes: _liveAmplitudes,
                            isDark: isDark,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),

                // Send Voice Note Button
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    color: const Color(0xFF2B5278),
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF2B5278).withValues(alpha: 0.38),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: IconButton(
                    onPressed: _sendVoiceRecording,
                    padding: EdgeInsets.zero,
                    tooltip: 'Send voice note',
                    icon: const Icon(
                      Icons.send_rounded,
                      color: Colors.white,
                      size: 21,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showAttachmentMenu(BuildContext context, bool isDark) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return Container(
          margin: const EdgeInsets.all(16),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF212121) : Colors.white,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: isDark ? const Color(0xFF2E2E2E) : const Color(0xFFE4E4E7),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.15),
                blurRadius: 16,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _buildAttachmentOption(
                    icon: Icons.image_rounded,
                    label: 'Gallery',
                    color: const Color(0xFF6366F1),
                    onTap: () {
                      Navigator.pop(ctx);
                      _pickAndSendMedia('gallery');
                    },
                  ),
                  _buildAttachmentOption(
                    icon: Icons.videocam_rounded,
                    label: 'Video',
                    color: const Color(0xFFEC4899),
                    onTap: () {
                      Navigator.pop(ctx);
                      _pickAndSendMedia('video');
                    },
                  ),
                  _buildAttachmentOption(
                    icon: Icons.insert_drive_file_rounded,
                    label: 'Document',
                    color: const Color(0xFF10B981),
                    onTap: () {
                      Navigator.pop(ctx);
                      _pickAndSendMedia('document');
                    },
                  ),
                  _buildAttachmentOption(
                    icon: Icons.audiotrack_rounded,
                    label: 'Audio',
                    color: const Color(0xFFF59E0B),
                    onTap: () {
                      Navigator.pop(ctx);
                      _pickAndSendMedia('audio');
                    },
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildAttachmentOption({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: color, size: 26),
            ),
            const SizedBox(height: 8),
            Text(
              label,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickAndSendMedia(String type) async {
    try {
      XTypeGroup? typeGroup;
      if (type == 'gallery') {
        typeGroup = const XTypeGroup(
          label: 'Images and Videos',
          extensions: ['jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp', 'mp4', 'mov', 'avi'],
        );
      } else if (type == 'video') {
        typeGroup = const XTypeGroup(
          label: 'Videos',
          extensions: ['mp4', 'mov', 'avi', 'mkv', 'webm'],
        );
      } else if (type == 'audio') {
        typeGroup = const XTypeGroup(
          label: 'Audio Files',
          extensions: ['mp3', 'wav', 'm4a', 'aac', 'ogg', 'flac'],
        );
      } else {
        typeGroup = const XTypeGroup(
          label: 'Documents',
        );
      }

      final files = await openFiles(acceptedTypeGroups: [typeGroup]);
      if (files.isEmpty || !mounted) return;

      final outgoingItems = files.map(OutgoingMediaItem.fromFile).toList();

      final discoverState = ref.read(discoverNotifierProvider);
      final knownUser = discoverState.findUserByMaster(widget.recipientMasterPubKey) ??
          discoverState.findUser(widget.recipientNostrPubKey);
      final activeUser = _chatProvider.activeChats
          .where((u) => u.nostrPubKeyHex == widget.recipientNostrPubKey)
          .firstOrNull;
      final targetNostrPubKey = (knownUser != null && knownUser.nostrPubKeyHex.isNotEmpty)
          ? knownUser.nostrPubKeyHex
          : widget.recipientNostrPubKey;
      final displayName = widget.recipientDisplayName ??
          knownUser?.displayName ??
          activeUser?.displayName ??
          widget.recipientUsername;

      final result = await Navigator.push<MediaSendResult>(
        context,
        MaterialPageRoute(
          builder: (_) => MediaSendPreviewScreen(
            initialItems: outgoingItems,
            recipientName: displayName,
          ),
        ),
      );

      if (result == null || result.items.isEmpty || !mounted) return;

      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          0,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        );
      }

      for (int i = 0; i < result.items.length; i++) {
        final item = result.items[i];
        final itemCaption = (i == 0) ? result.caption : null;

        await _chatProvider.sendOutgoingMedia(
          recipientNostrPubKey: targetNostrPubKey,
          localFilePath: item.path,
          mediaType: item.mediaType,
          customFileName: item.name,
          caption: itemCaption,
        );
      }
    } catch (e) {
      debugPrint('[MEDIA] Error picking/sending media: $e');
    }
  }
}

class _PulsingRedDot extends StatefulWidget {
  const _PulsingRedDot();

  @override
  State<_PulsingRedDot> createState() => _PulsingRedDotState();
}

class _PulsingRedDotState extends State<_PulsingRedDot> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _animation = Tween<double>(begin: 0.3, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _animation,
      child: Container(
        width: 10,
        height: 10,
        decoration: const BoxDecoration(
          color: Color(0xFFEF4444),
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

class _LiveWaveformVisualizer extends StatelessWidget {
  final List<int> amplitudes;
  final bool isDark;

  const _LiveWaveformVisualizer({
    required this.amplitudes,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final barColor = const Color(0xFF2B5278);
    final emptyColor = isDark ? Colors.white12 : const Color(0xFFE2E8F0);

    return SizedBox(
      height: 24,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: List.generate(24, (index) {
          final revIdx = amplitudes.length - 1 - (23 - index);
          final amp = (revIdx >= 0 && revIdx < amplitudes.length) ? amplitudes[revIdx] : 0;
          final height = amp > 0 ? (amp / 100.0 * 22).clamp(4.0, 22.0) : 4.0;
          final color = amp > 0 ? barColor : emptyColor;

          return Container(
            width: 3,
            height: height,
            margin: const EdgeInsets.symmetric(horizontal: 1.2),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(2),
            ),
          );
        }),
      ),
    );
  }
}
