import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/providers.dart';
import '../models/discover_user.dart';
import 'chat_screen.dart';
import 'widgets/online_status_indicator.dart';
import 'widgets/identicon.dart';
import 'widgets/formatted_display_name.dart';

class DiscoverScreen extends ConsumerStatefulWidget {
  const DiscoverScreen({super.key});

  @override
  ConsumerState<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends ConsumerState<DiscoverScreen> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  bool _isFocused = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      ref.read(discoverNotifierProvider).startDiscovery();
    });
    _searchController.addListener(_onSearchChanged);
    _searchFocusNode.addListener(_onFocusChanged);
  }

  void _onFocusChanged() {
    if (mounted) {
      setState(() {
        _isFocused = _searchFocusNode.hasFocus;
      });
    }
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchFocusNode.removeListener(_onFocusChanged);
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    setState(() {});
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

  String _formatLastSeen(DateTime lastSeen) {
    final diff = DateTime.now().difference(lastSeen);
    if (diff.inSeconds < 60) return 'Active just now';
    if (diff.inMinutes < 60) return 'Last seen ${diff.inMinutes}m ago';
    if (diff.inHours < 24) return 'Last seen ${diff.inHours}h ago';
    if (diff.inDays == 1) return 'Last seen yesterday';
    if (diff.inDays < 7) return 'Last seen ${diff.inDays}d ago';
    return 'Last seen ${lastSeen.day}/${lastSeen.month}/${lastSeen.year}';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final discoverProvider = ref.watch(discoverNotifierProvider);
    final query = _searchController.text.trim().toLowerCase();
    final allUsers = discoverProvider.discoveredUsers;
    final displayUsers = query.isEmpty
        ? List<DiscoverUser>.from(allUsers)
        : allUsers.where((user) {
            return user.username.toLowerCase().contains(query) ||
                (user.displayName != null && user.displayName!.toLowerCase().contains(query)) ||
                user.masterPubKeyHex.toLowerCase().contains(query) ||
                user.nostrPubKeyHex.toLowerCase().contains(query);
          }).toList();

    // Sort: Online members on top, then by most recent activity
    displayUsers.sort((a, b) {
      if (a.isOnline != b.isOnline) {
        return a.isOnline ? -1 : 1;
      }
      return b.lastSeen.compareTo(a.lastSeen);
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text('Discover'),
      ),
      body: Column(
        children: [
          // Modern Aesthetic Floating Capsule Search Bar
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              decoration: BoxDecoration(
                color: isDark
                    ? (_isFocused ? const Color(0xFF1E1E28) : const Color(0xFF181820))
                    : (_isFocused ? Colors.white : const Color(0xFFF3F4F8)),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: _isFocused
                      ? const Color(0xFF6366F1)
                      : (isDark ? const Color(0xFF2A2A38) : const Color(0xFFE2E4EC)),
                  width: _isFocused ? 1.4 : 1.0,
                ),
                boxShadow: [
                  BoxShadow(
                    color: _isFocused
                        ? const Color(0xFF6366F1).withValues(alpha: isDark ? 0.22 : 0.15)
                        : (isDark
                            ? Colors.black.withValues(alpha: 0.22)
                            : Colors.black.withValues(alpha: 0.04)),
                    blurRadius: _isFocused ? 14 : 6,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Row(
                children: [
                  // Animated Search Icon / Accent Badge
                  Padding(
                    padding: const EdgeInsets.only(left: 12, right: 6),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: _isFocused
                            ? const Color(0xFF6366F1).withValues(alpha: 0.15)
                            : (isDark
                                ? Colors.white.withValues(alpha: 0.05)
                                : Colors.black.withValues(alpha: 0.04)),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        Icons.search_rounded,
                        size: 18,
                        color: _isFocused
                            ? const Color(0xFF818CF8)
                            : (isDark ? Colors.white54 : Colors.black45),
                      ),
                    ),
                  ),

                  // Seamless Input Field
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      focusNode: _searchFocusNode,
                      textAlignVertical: TextAlignVertical.center,
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w500,
                        color: isDark ? Colors.white : const Color(0xFF18181B),
                        letterSpacing: -0.2,
                      ),
                      decoration: InputDecoration(
                        hintText: 'Search members, @usernames, or keys...',
                        hintStyle: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w400,
                          color: isDark ? Colors.white38 : Colors.black38,
                          letterSpacing: -0.2,
                        ),
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(vertical: 13, horizontal: 6),
                        filled: false,
                      ),
                    ),
                  ),

                  // Interactive Clear Button & Matching Count Pill
                  if (_searchController.text.isNotEmpty) ...[
                    Container(
                      margin: const EdgeInsets.only(right: 4),
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
                      decoration: BoxDecoration(
                        color: isDark
                            ? Colors.white.withValues(alpha: 0.08)
                            : Colors.black.withValues(alpha: 0.05),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '${displayUsers.length}',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: isDark ? Colors.white70 : Colors.black54,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: Icon(
                        Icons.cancel_rounded,
                        size: 18,
                        color: isDark ? Colors.white54 : Colors.black45,
                      ),
                      splashRadius: 16,
                      padding: const EdgeInsets.all(8),
                      constraints: const BoxConstraints(),
                      tooltip: 'Clear search',
                      onPressed: () {
                        _searchController.clear();
                        setState(() {});
                      },
                    ),
                    const SizedBox(width: 4),
                  ] else ...[
                    const SizedBox(width: 8),
                  ],
                ],
              ),
            ),
          ),
          Expanded(
            child: Builder(
              builder: (context) {

                if (displayUsers.isEmpty) {
                  if (query.isNotEmpty) {
                    return Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.search_off_rounded, size: 48, color: Colors.grey[400]),
                          const SizedBox(height: 12),
                          Text(
                            'No members matching "$query"',
                            style: TextStyle(color: Colors.grey[600], fontSize: 14),
                          ),
                        ],
                      ),
                    );
                  }
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.people_outline_rounded, size: 48, color: Colors.grey[400]),
                        const SizedBox(height: 12),
                        const Text(
                          'No announced members discovered yet',
                          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Toggle your presence in Settings to announce yourself!',
                          style: TextStyle(color: Colors.grey[600], fontSize: 13),
                        ),
                      ],
                    ),
                  );
                }

                return ListView.builder(
                  itemCount: displayUsers.length,
                  itemBuilder: (context, index) {
                    final user = displayUsers[index];
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      child: ListTile(
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        tileColor: user.isOnline
                            ? (Theme.of(context).brightness == Brightness.dark
                                ? const Color(0xFF1B2A20).withValues(alpha: 0.35)
                                : const Color(0xFFF0FDF4))
                            : Colors.transparent,
                        hoverColor: Theme.of(context).cardTheme.color,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                        leading: Stack(
                          children: [
                            Identicon(
                              seed: user.masterPubKeyHex,
                              size: 46,
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
                          baseStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15.5),
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (user.displayName != null && user.displayName!.isNotEmpty)
                              Text('@${user.username}', style: TextStyle(fontSize: 11.5, color: Colors.grey[600])),
                            if (user.bio != null && user.bio!.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(
                                user.bio!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 12.5, color: Theme.of(context).textTheme.bodyMedium?.color),
                              ),
                            ],
                            const SizedBox(height: 2),
                            Text(
                              user.isOnline
                                  ? 'Active now'
                                  : _formatLastSeen(user.lastSeen),
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: user.isOnline ? FontWeight.w600 : FontWeight.normal,
                                color: user.isOnline
                                    ? const Color(0xFF4BD151)
                                    : (Theme.of(context).brightness == Brightness.dark
                                        ? const Color(0xFF94A3B8)
                                        : const Color(0xFF64748B)),
                              ),
                            ),
                          ],
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.chat_bubble_outline_rounded, size: 21),
                          color: const Color(0xFF6366F1),
                          onPressed: () => _openChat(user),
                        ),
                        onTap: () => _openChat(user),
                      ),
                    );
                  },
                );
              },
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
