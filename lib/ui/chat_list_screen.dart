import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/discover_user.dart';
import '../providers/chat_provider.dart';
import '../providers/discover_provider.dart';
import 'chat_screen.dart';
import 'profile_screen.dart';
import 'discover_screen.dart';
import 'widgets/online_status_indicator.dart';
import 'widgets/identicon.dart';

class ChatListScreen extends StatefulWidget {
  const ChatListScreen({super.key});

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final discoverProvider = context.watch<DiscoverProvider>();
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
      body: Consumer<ChatProvider>(
        builder: (context, chatProvider, child) {
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

          return ListView.builder(
            itemCount: chatProvider.activeChats.length,
            itemBuilder: (context, index) {
              final chatUser = chatProvider.activeChats[index];
              final knownUser = discoverProvider.findUserByMaster(chatUser.masterPubKeyHex) ?? 
                                discoverProvider.findUser(chatUser.nostrPubKeyHex);

              // Always preserve resolved username even if user is currently hidden
              final resolvedUsername = (chatUser.username.isNotEmpty && !chatUser.username.startsWith('Ghost #'))
                  ? chatUser.username
                  : (knownUser != null && !knownUser.username.startsWith('Ghost #') ? knownUser.username : chatUser.username);
              final resolvedDisplayName = chatUser.displayName ?? knownUser?.displayName;
              final resolvedBio = chatUser.bio ?? knownUser?.bio;

              final isOffline = (knownUser?.isExplicitlyOffline == true) || chatUser.isExplicitlyOffline;

              final user = DiscoverUser(
                masterPubKeyHex: chatUser.masterPubKeyHex,
                nostrPubKeyHex: chatUser.nostrPubKeyHex,
                username: resolvedUsername,
                displayName: resolvedDisplayName,
                bio: resolvedBio,
                lastSeen: knownUser?.lastSeen ?? chatUser.lastSeen,
                lastSeenFromPing: isOffline ? null : (knownUser?.lastSeenFromPing ?? chatUser.lastSeenFromPing),
                lastSeenFromMessage: isOffline ? null : chatUser.lastSeenFromMessage,
                isExplicitlyOffline: isOffline,
                isHidden: knownUser?.isHidden ?? chatUser.isHidden,
              );
              
              final unreadCount = chatProvider.unreadCounts[user.nostrPubKeyHex] ?? 0;
              
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
                        child: Container(
                          decoration: BoxDecoration(
                            color: Theme.of(context).scaffoldBackgroundColor,
                            shape: BoxShape.circle,
                          ),
                          padding: const EdgeInsets.all(2),
                          child: OnlineStatusIndicator(user: user),
                        ),
                      ),
                    ],
                  ),
                  title: Text(user.displayName ?? user.username, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                  subtitle: (user.displayName != null && user.displayName!.isNotEmpty)
                      ? Text('@${user.username}', style: TextStyle(fontSize: 12, color: Colors.grey[600]))
                      : null,
                  trailing: unreadCount > 0 
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
                    : Icon(Icons.chevron_right, color: Colors.grey[600]),
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
}
