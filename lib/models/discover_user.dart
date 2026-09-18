class DiscoverUser {
  final String masterPubKeyHex;
  final String nostrPubKeyHex;
  String username;
  String? displayName;
  String? bio;
  DateTime lastSeen;
  DateTime? lastSeenFromPing;
  DateTime? lastSeenFromMessage;
  DateTime? lastEventTimestamp;
  int? lastPingTimestampMs;
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
    this.lastPingTimestampMs,
    this.isExplicitlyOffline = false,
    this.isHidden = false,
  });

  bool get isOnline {
    if (isExplicitlyOffline) return false;
    
    final now = DateTime.now();
    // A user is online if they pinged in the last 70 seconds OR sent a message in the last 70 seconds
    final recentlyPinged = lastSeenFromPing != null && now.difference(lastSeenFromPing!).inSeconds < 70;
    final recentlyMessaged = lastSeenFromMessage != null && now.difference(lastSeenFromMessage!).inSeconds < 70;
    return recentlyPinged || recentlyMessaged;
  }
}
