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

  Map<String, dynamic> toJson() => {
    'masterPubKeyHex': masterPubKeyHex,
    'nostrPubKeyHex': nostrPubKeyHex,
    'username': username,
    if (displayName != null) 'displayName': displayName,
    if (bio != null) 'bio': bio,
    'lastSeen': lastSeen.toIso8601String(),
    if (lastSeenFromPing != null) 'lastSeenFromPing': lastSeenFromPing!.toIso8601String(),
    if (lastSeenFromMessage != null) 'lastSeenFromMessage': lastSeenFromMessage!.toIso8601String(),
    if (lastPingTimestampMs != null) 'lastPingTimestampMs': lastPingTimestampMs,
    'isExplicitlyOffline': isExplicitlyOffline,
    'isHidden': isHidden,
  };

  factory DiscoverUser.fromJson(Map<String, dynamic> json) => DiscoverUser(
    masterPubKeyHex: json['masterPubKeyHex'] as String? ?? '',
    nostrPubKeyHex: json['nostrPubKeyHex'] as String? ?? '',
    username: json['username'] as String? ?? '',
    displayName: json['displayName'] as String?,
    bio: json['bio'] as String?,
    lastSeen: json['lastSeen'] != null ? (DateTime.tryParse(json['lastSeen'] as String) ?? DateTime.now()) : DateTime.now(),
    lastSeenFromPing: json['lastSeenFromPing'] != null ? DateTime.tryParse(json['lastSeenFromPing'] as String) : null,
    lastSeenFromMessage: json['lastSeenFromMessage'] != null ? DateTime.tryParse(json['lastSeenFromMessage'] as String) : null,
    lastPingTimestampMs: (json['lastPingTimestampMs'] as num?)?.toInt(),
    isExplicitlyOffline: json['isExplicitlyOffline'] as bool? ?? false,
    isHidden: json['isHidden'] as bool? ?? false,
  );
}
