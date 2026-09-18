import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/providers.dart';
import '../models/discover_user.dart';
import 'chat_screen.dart';
import 'widgets/online_status_indicator.dart';
import 'widgets/identicon.dart';

class DiscoverScreen extends ConsumerStatefulWidget {
  const DiscoverScreen({super.key});

  @override
  ConsumerState<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends ConsumerState<DiscoverScreen> {
  final TextEditingController _searchController = TextEditingController();
  List<DiscoverUser> _filteredUsers = [];

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      ref.read(discoverNotifierProvider).startDiscovery();
    });
    _searchController.addListener(_filterUsers);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _filterUsers() {
    final query = _searchController.text.toLowerCase();
    final allUsers = ref.read(discoverNotifierProvider).discoveredUsers;
    
    setState(() {
      if (query.isEmpty) {
        _filteredUsers = List.from(allUsers);
      } else {
        _filteredUsers = allUsers.where((user) {
          return user.username.toLowerCase().contains(query) || 
                 (user.displayName != null && user.displayName!.toLowerCase().contains(query)) ||
                 user.masterPubKeyHex.toLowerCase().contains(query);
        }).toList();
      }
    });
  }


  void _startRandomChat() {
    final allUsers = ref.read(discoverNotifierProvider).discoveredUsers;
    final onlineUsers = allUsers.where((u) => u.isOnline).toList();
    if (onlineUsers.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No users are actively online right now!')),
      );
      return;
    }
    
    final random = Random();
    final randomUser = onlineUsers[random.nextInt(onlineUsers.length)];
    _openChat(randomUser);
  }
  
  void _openChat(DiscoverUser user) {
    print("DEBUG: Tapped on user! masterKey: ${user.masterPubKeyHex}");
    print("DEBUG: Searching for PreKeys for Nostr Author: ${user.nostrPubKeyHex}");
    
    // Clear unread count before navigating
    ref.read(chatNotifierProvider).markChatAsRead(user.nostrPubKeyHex);
    
    // Navigate to ChatScreen
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
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Discover'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search Usernames...',
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                filled: true,
                fillColor: Theme.of(context).inputDecorationTheme.fillColor,
              ),
            ),
          ),
          Expanded(
            child: Consumer(
              builder: (context, ref, child) {
                final discoverProvider = ref.watch(discoverNotifierProvider);
                // If there is no search query, display all users directly from provider
                // Otherwise use the local filtered list
                final displayUsers = _searchController.text.isEmpty 
                    ? discoverProvider.discoveredUsers 
                    : _filteredUsers;
                    
                if (displayUsers.isEmpty) {
                  return const Center(child: Text('Listening for online users...'));
                }
                
                return ListView.builder(
                    itemCount: displayUsers.length,
                    itemBuilder: (context, index) {
                      final user = displayUsers[index];
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
                                      color: const Color(0xFFFDFDFD),
                                      shape: BoxShape.circle,
                                    ),
                                    padding: const EdgeInsets.all(2),
                                    child: OnlineStatusIndicator(user: user),
                                  ),
                                ),
                              ],
                            ),
                            title: Text(user.displayName ?? user.username, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (user.displayName != null && user.displayName!.isNotEmpty)
                                  Text('@${user.username}', style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                                if (user.bio != null && user.bio!.isNotEmpty) ...[
                                  const SizedBox(height: 2),
                                  Text(
                                    user.bio!,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(fontSize: 13, color: Theme.of(context).textTheme.bodyMedium?.color),
                                  ),
                                ],
                                const SizedBox(height: 2),
                                Text(
                                  user.masterPubKeyHex,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                                ),
                              ],
                            ),
                            trailing: IconButton(
                              icon: const Icon(Icons.chat_bubble_outline),
                              color: const Color(0xFF6366F1),
                              onPressed: () => _openChat(user),
                            ),
                            onTap: () => _openChat(user),
                          ),
                        );
                      },
                    );
              }
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _startRandomChat,
        icon: const Icon(Icons.shuffle),
        label: const Text('Random Chat'),
        backgroundColor: const Color(0xFF6366F1),
        foregroundColor: Colors.white,
      ),
    );
  }
}
