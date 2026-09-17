class DiscoverUser {
  final String masterPubKeyHex;
  final String nostrPubKeyHex;
  final String username;
  String? displayName;
  String? bio;
  DateTime lastSeen;
  DateTime? lastSeenFromPing;
  DateTime? lastSeenFromMessage;
  DateTime? lastEventTimestamp;
  bool isExplicitlyOffline;
  bool isHidden;
  
  DiscoverUser({
    required this.masterPubKeyHex,
    required this.nostrPubKeyHex,
    required this.username,
    this.displayName,
    this.bio,
    required this.lastSeen,
    this.lastSeenFromPing,
    this.lastSeenFromMessage,
    this.isExplicitlyOffline = false,
    this.isHidden = false,
  });

  bool get isOnline {
    if (isExplicitlyOffline) return false;
    
    final now = DateTime.now();
    // A user is online if they pinged in the last 60 seconds OR sent a message in the last 60 seconds
    final recentlyPinged = lastSeenFromPing != null && now.difference(lastSeenFromPing!).inSeconds < 60;
    final recentlyMessaged = lastSeenFromMessage != null && now.difference(lastSeenFromMessage!).inSeconds < 60;
    return recentlyPinged || recentlyMessaged;
  }
}
