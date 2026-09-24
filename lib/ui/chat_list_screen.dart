import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/providers.dart';
import '../models/discover_user.dart';
import 'chat_screen.dart';
import 'profile_screen.dart';
import 'discover_screen.dart';
import 'widgets/online_status_indicator.dart';
import 'widgets/identicon.dart';
import 'widgets/formatted_display_name.dart';
import '../models/chat_message.dart';
import '../services/voice_note_service.dart';

class ChatListScreen extends ConsumerWidget {
  const ChatListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final discoverProvider = ref.watch(discoverNotifierProvider);
    final chatProvider = ref.watch(chatNotifierProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Chats'),
        actions: [
          IconButton(
            icon: const Icon(Icons.explore),
            tooltip: 'Discover Users',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const DiscoverScreen()),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.person),
            tooltip: 'Profile',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const ProfileScreen()),
              );
            },
          )
        ],
      ),
      body: Builder(
        builder: (context) {
          if (chatProvider.activeChats.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.chat_bubble_outline, size: 64, color: Colors.grey),
                  const SizedBox(height: 16),
                  const Text('No active chats yet.', style: TextStyle(fontSize: 18, color: Colors.grey)),
                  const SizedBox(height: 16),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.explore),
                    label: const Text('Find someone in Discover'),
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (context) => const DiscoverScreen()),
                      );
                    },
                  )
                ],
              ),
            );
          }

          final isDark = Theme.of(context).brightness == Brightness.dark;
          final sortedChats = List<DiscoverUser>.from(chatProvider.activeChats);
          sortedChats.sort((a, b) {
            final historyA = chatProvider.chatHistories[a.nostrPubKeyHex];
            final historyB = chatProvider.chatHistories[b.nostrPubKeyHex];
            final timeA = (historyA != null && historyA.isNotEmpty)
                ? historyA.last.timestamp
                : a.lastSeen;
            final timeB = (historyB != null && historyB.isNotEmpty)
                ? historyB.last.timestamp
                : b.lastSeen;
            return timeB.compareTo(timeA); // Most recent message on top!
          });

          return ListView.builder(
            itemCount: sortedChats.length,
            itemBuilder: (context, index) {
              final chatUser = sortedChats[index];
              final knownUser = discoverProvider.findUserByMaster(chatUser.masterPubKeyHex) ?? 
                                discoverProvider.findUser(chatUser.nostrPubKeyHex);

              // Only resolve Ghost username if the contact is actively announced (!knownUser.isHidden)
              final isKnownAnnounced = knownUser != null && !knownUser.isHidden;
              final resolvedUsername = isKnownAnnounced
                  ? ((knownUser.username.isNotEmpty && !knownUser.username.startsWith('Ghost #'))
                      ? knownUser.username
                      : (chatUser.username.isNotEmpty && !chatUser.username.startsWith('Ghost #')
                          ? chatUser.username
                          : 'Ghost #${chatUser.masterPubKeyHex.substring(0, 4)}'))
                  : 'Ghost #${chatUser.masterPubKeyHex.substring(0, 4)}';
              final resolvedDisplayName = isKnownAnnounced
                  ? (knownUser.displayName != null && knownUser.displayName!.isNotEmpty ? knownUser.displayName : chatUser.displayName)
                  : null;
              final resolvedBio = isKnownAnnounced
                  ? (knownUser.bio != null && knownUser.bio!.isNotEmpty ? knownUser.bio : chatUser.bio)
                  : null;

              final effectiveLastPing = (knownUser?.lastSeenFromPing != null && chatUser.lastSeenFromPing != null)
                  ? (knownUser!.lastSeenFromPing!.isAfter(chatUser.lastSeenFromPing!) ? knownUser.lastSeenFromPing : chatUser.lastSeenFromPing)
                  : (knownUser?.lastSeenFromPing ?? chatUser.lastSeenFromPing);
              final effectiveLastMsg = (knownUser?.lastSeenFromMessage != null && chatUser.lastSeenFromMessage != null)
                  ? (knownUser!.lastSeenFromMessage!.isAfter(chatUser.lastSeenFromMessage!) ? knownUser.lastSeenFromMessage : chatUser.lastSeenFromMessage)
                  : (knownUser?.lastSeenFromMessage ?? chatUser.lastSeenFromMessage);

              final isActuallyOnline = (knownUser?.isOnline == true) || (chatUser.isOnline == true);
              final isOffline = !isActuallyOnline && ((knownUser?.isExplicitlyOffline == true) || chatUser.isExplicitlyOffline);

              final user = DiscoverUser(
                masterPubKeyHex: chatUser.masterPubKeyHex,
                nostrPubKeyHex: chatUser.nostrPubKeyHex,
                username: resolvedUsername,
                displayName: resolvedDisplayName,
                bio: resolvedBio,
                lastSeen: knownUser?.lastSeen ?? chatUser.lastSeen,
                lastSeenFromPing: isOffline ? null : effectiveLastPing,
                lastSeenFromMessage: isOffline ? null : effectiveLastMsg,
                isExplicitlyOffline: isOffline,
                isHidden: knownUser?.isHidden ?? chatUser.isHidden,
              );
              
              final unreadCount = chatProvider.unreadCounts[user.nostrPubKeyHex] ?? 0;
              final history = chatProvider.chatHistories[user.nostrPubKeyHex];
              final lastMsg = (history != null && history.isNotEmpty) ? history.last : null;

              Widget? subtitleWidget;
              if (lastMsg != null) {
                Widget statusPrefix = const SizedBox.shrink();
                if (lastMsg.isMe) {
                  final tickColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
                  if (lastMsg.status == MessageStatus.sending) {
                    statusPrefix = Padding(
                      padding: const EdgeInsets.only(right: 3.5),
                      child: Icon(Icons.access_time_rounded, size: 12, color: tickColor),
                    );
                  } else if (lastMsg.status == MessageStatus.failed) {
                    statusPrefix = const Padding(
                      padding: EdgeInsets.only(right: 3.5),
                      child: Icon(Icons.error_outline_rounded, size: 13, color: Color(0xFFEF4444)),
                    );
                  } else if (lastMsg.status == MessageStatus.delivered) {
                    statusPrefix = Padding(
                      padding: const EdgeInsets.only(right: 3.5),
                      child: Icon(Icons.done_all_rounded, size: 14, color: tickColor),
                    );
                  } else if (lastMsg.status == MessageStatus.read) {
                    statusPrefix = const Padding(
                      padding: EdgeInsets.only(right: 3.5),
                      child: Icon(Icons.done_all_rounded, size: 14, color: Color(0xFF38BDF8)),
                    );
                  } else {
                    // sent
                    statusPrefix = Padding(
                      padding: const EdgeInsets.only(right: 3.5),
                      child: Icon(Icons.check_rounded, size: 14, color: tickColor),
                    );
                  }
                }

                if (VoiceNotePayload.isVoiceNote(lastMsg.text)) {
                  subtitleWidget = Row(
                    children: [
                      statusPrefix,
                      Icon(
                        Icons.mic_rounded,
                        size: 15,
                        color: unreadCount > 0
                            ? const Color(0xFF6366F1)
                            : (isDark ? Colors.white54 : Colors.black45),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'Voice message',
                        style: TextStyle(
                          fontSize: 13,
                          color: unreadCount > 0
                              ? (isDark ? Colors.white : Colors.black87)
                              : (isDark ? Colors.white60 : Colors.black54),
                          fontWeight: unreadCount > 0 ? FontWeight.w600 : FontWeight.normal,
                        ),
                      ),
                    ],
                  );
                } else {
                  subtitleWidget = Row(
                    children: [
                      statusPrefix,
                      Expanded(
                        child: Text(
                          lastMsg.text,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            color: unreadCount > 0
                                ? (isDark ? Colors.white : Colors.black87)
                                : (isDark ? Colors.white60 : Colors.black54),
                            fontWeight: unreadCount > 0 ? FontWeight.w600 : FontWeight.normal,
                          ),
                        ),
                      ),
                    ],
                  );
                }
              } else if (user.displayName != null && user.displayName!.isNotEmpty) {
                subtitleWidget = Text('@${user.username}', style: TextStyle(fontSize: 12, color: Colors.grey[600]));
              }

              final Widget trailingWidget;
              if (lastMsg != null) {
                trailingWidget = Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _formatChatTimestamp(lastMsg.timestamp),
                      style: TextStyle(
                        fontSize: 11.5,
                        color: unreadCount > 0
                            ? const Color(0xFF6366F1)
                            : (isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B)),
                        fontWeight: unreadCount > 0 ? FontWeight.w600 : FontWeight.normal,
                      ),
                    ),
                    if (unreadCount > 0) ...[
                      const SizedBox(height: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFF6366F1),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          unreadCount.toString(),
                          style: const TextStyle(color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ],
                );
              } else {
                trailingWidget = unreadCount > 0
                    ? Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: const Color(0xFF6366F1),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          unreadCount.toString(),
                          style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                        ),
                      )
                    : Icon(Icons.chevron_right, color: Colors.grey[600]);
              }

              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: ListTile(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  tileColor: Colors.transparent,
                  hoverColor: Theme.of(context).cardTheme.color,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  leading: Stack(
                    children: [
                      Identicon(
                        seed: user.masterPubKeyHex,
                        size: 48,
                      ),
                      Positioned(
                        right: 0,
                        bottom: 0,
                        child: OnlineStatusIndicator(user: user, size: 14),
                      ),
                    ],
                  ),
                  title: FormattedDisplayName(
                    displayName: user.displayName,
                    username: user.username,
                    baseStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
                  ),
                  subtitle: subtitleWidget,
                  trailing: trailingWidget,
                  onTap: () {
                    chatProvider.markChatAsRead(user.nostrPubKeyHex);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => ChatScreen(
                          recipientMasterPubKey: user.masterPubKeyHex,
                          recipientNostrPubKey: user.nostrPubKeyHex,
                          recipientUsername: user.username,
                          recipientDisplayName: user.displayName,
                          recipientBio: user.bio,
                        ),
                      ),
                    );
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }

  String _formatChatTimestamp(DateTime time) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final messageDate = DateTime(time.year, time.month, time.day);
    final diffDays = today.difference(messageDate).inDays;

    if (diffDays == 0) {
      final period = time.hour >= 12 ? 'pm' : 'am';
      final hour = time.hour % 12 == 0 ? 12 : time.hour % 12;
      final minute = time.minute.toString().padLeft(2, '0');
      return '$hour:$minute $period';
    } else if (diffDays == 1) {
      return 'Yesterday';
    } else if (diffDays < 7) {
      const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      return days[time.weekday - 1];
    } else {
      return '${time.day}/${time.month}/${time.year}';
    }
  }
}
