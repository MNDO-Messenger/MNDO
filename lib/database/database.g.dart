// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'database.dart';

// ignore_for_file: type=lint
class $ActiveChatsTable extends ActiveChats
    with TableInfo<$ActiveChatsTable, ActiveChatRecord> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ActiveChatsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _masterPubKeyHexMeta = const VerificationMeta(
    'masterPubKeyHex',
  );
  @override
  late final GeneratedColumn<String> masterPubKeyHex = GeneratedColumn<String>(
    'master_pub_key_hex',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nostrPubKeyHexMeta = const VerificationMeta(
    'nostrPubKeyHex',
  );
  @override
  late final GeneratedColumn<String> nostrPubKeyHex = GeneratedColumn<String>(
    'nostr_pub_key_hex',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _usernameMeta = const VerificationMeta(
    'username',
  );
  @override
  late final GeneratedColumn<String> username = GeneratedColumn<String>(
    'username',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _displayNameMeta = const VerificationMeta(
    'displayName',
  );
  @override
  late final GeneratedColumn<String> displayName = GeneratedColumn<String>(
    'display_name',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _bioMeta = const VerificationMeta('bio');
  @override
  late final GeneratedColumn<String> bio = GeneratedColumn<String>(
    'bio',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _lastSeenMeta = const VerificationMeta(
    'lastSeen',
  );
  @override
  late final GeneratedColumn<DateTime> lastSeen = GeneratedColumn<DateTime>(
    'last_seen',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    masterPubKeyHex,
    nostrPubKeyHex,
    username,
    displayName,
    bio,
    lastSeen,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'active_chats';
  @override
  VerificationContext validateIntegrity(
    Insertable<ActiveChatRecord> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('master_pub_key_hex')) {
      context.handle(
        _masterPubKeyHexMeta,
        masterPubKeyHex.isAcceptableOrUnknown(
          data['master_pub_key_hex']!,
          _masterPubKeyHexMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_masterPubKeyHexMeta);
    }
    if (data.containsKey('nostr_pub_key_hex')) {
      context.handle(
        _nostrPubKeyHexMeta,
        nostrPubKeyHex.isAcceptableOrUnknown(
          data['nostr_pub_key_hex']!,
          _nostrPubKeyHexMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_nostrPubKeyHexMeta);
    }
    if (data.containsKey('username')) {
      context.handle(
        _usernameMeta,
        username.isAcceptableOrUnknown(data['username']!, _usernameMeta),
      );
    } else if (isInserting) {
      context.missing(_usernameMeta);
    }
    if (data.containsKey('display_name')) {
      context.handle(
        _displayNameMeta,
        displayName.isAcceptableOrUnknown(
          data['display_name']!,
          _displayNameMeta,
        ),
      );
    }
    if (data.containsKey('bio')) {
      context.handle(
        _bioMeta,
        bio.isAcceptableOrUnknown(data['bio']!, _bioMeta),
      );
    }
    if (data.containsKey('last_seen')) {
      context.handle(
        _lastSeenMeta,
        lastSeen.isAcceptableOrUnknown(data['last_seen']!, _lastSeenMeta),
      );
    } else if (isInserting) {
      context.missing(_lastSeenMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {masterPubKeyHex};
  @override
  ActiveChatRecord map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ActiveChatRecord(
      masterPubKeyHex: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}master_pub_key_hex'],
      )!,
      nostrPubKeyHex: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}nostr_pub_key_hex'],
      )!,
      username: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}username'],
      )!,
      displayName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}display_name'],
      ),
      bio: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}bio'],
      ),
      lastSeen: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}last_seen'],
      )!,
    );
  }

  @override
  $ActiveChatsTable createAlias(String alias) {
    return $ActiveChatsTable(attachedDatabase, alias);
  }
}

class ActiveChatRecord extends DataClass
    implements Insertable<ActiveChatRecord> {
  final String masterPubKeyHex;
  final String nostrPubKeyHex;
  final String username;
  final String? displayName;
  final String? bio;
  final DateTime lastSeen;
  const ActiveChatRecord({
    required this.masterPubKeyHex,
    required this.nostrPubKeyHex,
    required this.username,
    this.displayName,
    this.bio,
    required this.lastSeen,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['master_pub_key_hex'] = Variable<String>(masterPubKeyHex);
    map['nostr_pub_key_hex'] = Variable<String>(nostrPubKeyHex);
    map['username'] = Variable<String>(username);
    if (!nullToAbsent || displayName != null) {
      map['display_name'] = Variable<String>(displayName);
    }
    if (!nullToAbsent || bio != null) {
      map['bio'] = Variable<String>(bio);
    }
    map['last_seen'] = Variable<DateTime>(lastSeen);
    return map;
  }

  ActiveChatsCompanion toCompanion(bool nullToAbsent) {
    return ActiveChatsCompanion(
      masterPubKeyHex: Value(masterPubKeyHex),
      nostrPubKeyHex: Value(nostrPubKeyHex),
      username: Value(username),
      displayName: displayName == null && nullToAbsent
          ? const Value.absent()
          : Value(displayName),
      bio: bio == null && nullToAbsent ? const Value.absent() : Value(bio),
      lastSeen: Value(lastSeen),
    );
  }

  factory ActiveChatRecord.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ActiveChatRecord(
      masterPubKeyHex: serializer.fromJson<String>(json['masterPubKeyHex']),
      nostrPubKeyHex: serializer.fromJson<String>(json['nostrPubKeyHex']),
      username: serializer.fromJson<String>(json['username']),
      displayName: serializer.fromJson<String?>(json['displayName']),
      bio: serializer.fromJson<String?>(json['bio']),
      lastSeen: serializer.fromJson<DateTime>(json['lastSeen']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'masterPubKeyHex': serializer.toJson<String>(masterPubKeyHex),
      'nostrPubKeyHex': serializer.toJson<String>(nostrPubKeyHex),
      'username': serializer.toJson<String>(username),
      'displayName': serializer.toJson<String?>(displayName),
      'bio': serializer.toJson<String?>(bio),
      'lastSeen': serializer.toJson<DateTime>(lastSeen),
    };
  }

  ActiveChatRecord copyWith({
    String? masterPubKeyHex,
    String? nostrPubKeyHex,
    String? username,
    Value<String?> displayName = const Value.absent(),
    Value<String?> bio = const Value.absent(),
    DateTime? lastSeen,
  }) => ActiveChatRecord(
    masterPubKeyHex: masterPubKeyHex ?? this.masterPubKeyHex,
    nostrPubKeyHex: nostrPubKeyHex ?? this.nostrPubKeyHex,
    username: username ?? this.username,
    displayName: displayName.present ? displayName.value : this.displayName,
    bio: bio.present ? bio.value : this.bio,
    lastSeen: lastSeen ?? this.lastSeen,
  );
  ActiveChatRecord copyWithCompanion(ActiveChatsCompanion data) {
    return ActiveChatRecord(
      masterPubKeyHex: data.masterPubKeyHex.present
          ? data.masterPubKeyHex.value
          : this.masterPubKeyHex,
      nostrPubKeyHex: data.nostrPubKeyHex.present
          ? data.nostrPubKeyHex.value
          : this.nostrPubKeyHex,
      username: data.username.present ? data.username.value : this.username,
      displayName: data.displayName.present
          ? data.displayName.value
          : this.displayName,
      bio: data.bio.present ? data.bio.value : this.bio,
      lastSeen: data.lastSeen.present ? data.lastSeen.value : this.lastSeen,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ActiveChatRecord(')
          ..write('masterPubKeyHex: $masterPubKeyHex, ')
          ..write('nostrPubKeyHex: $nostrPubKeyHex, ')
          ..write('username: $username, ')
          ..write('displayName: $displayName, ')
          ..write('bio: $bio, ')
          ..write('lastSeen: $lastSeen')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    masterPubKeyHex,
    nostrPubKeyHex,
    username,
    displayName,
    bio,
    lastSeen,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ActiveChatRecord &&
          other.masterPubKeyHex == this.masterPubKeyHex &&
          other.nostrPubKeyHex == this.nostrPubKeyHex &&
          other.username == this.username &&
          other.displayName == this.displayName &&
          other.bio == this.bio &&
          other.lastSeen == this.lastSeen);
}

class ActiveChatsCompanion extends UpdateCompanion<ActiveChatRecord> {
  final Value<String> masterPubKeyHex;
  final Value<String> nostrPubKeyHex;
  final Value<String> username;
  final Value<String?> displayName;
  final Value<String?> bio;
  final Value<DateTime> lastSeen;
  final Value<int> rowid;
  const ActiveChatsCompanion({
    this.masterPubKeyHex = const Value.absent(),
    this.nostrPubKeyHex = const Value.absent(),
    this.username = const Value.absent(),
    this.displayName = const Value.absent(),
    this.bio = const Value.absent(),
    this.lastSeen = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ActiveChatsCompanion.insert({
    required String masterPubKeyHex,
    required String nostrPubKeyHex,
    required String username,
    this.displayName = const Value.absent(),
    this.bio = const Value.absent(),
    required DateTime lastSeen,
    this.rowid = const Value.absent(),
  }) : masterPubKeyHex = Value(masterPubKeyHex),
       nostrPubKeyHex = Value(nostrPubKeyHex),
       username = Value(username),
       lastSeen = Value(lastSeen);
  static Insertable<ActiveChatRecord> custom({
    Expression<String>? masterPubKeyHex,
    Expression<String>? nostrPubKeyHex,
    Expression<String>? username,
    Expression<String>? displayName,
    Expression<String>? bio,
    Expression<DateTime>? lastSeen,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (masterPubKeyHex != null) 'master_pub_key_hex': masterPubKeyHex,
      if (nostrPubKeyHex != null) 'nostr_pub_key_hex': nostrPubKeyHex,
      if (username != null) 'username': username,
      if (displayName != null) 'display_name': displayName,
      if (bio != null) 'bio': bio,
      if (lastSeen != null) 'last_seen': lastSeen,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ActiveChatsCompanion copyWith({
    Value<String>? masterPubKeyHex,
    Value<String>? nostrPubKeyHex,
    Value<String>? username,
    Value<String?>? displayName,
    Value<String?>? bio,
    Value<DateTime>? lastSeen,
    Value<int>? rowid,
  }) {
    return ActiveChatsCompanion(
      masterPubKeyHex: masterPubKeyHex ?? this.masterPubKeyHex,
      nostrPubKeyHex: nostrPubKeyHex ?? this.nostrPubKeyHex,
      username: username ?? this.username,
      displayName: displayName ?? this.displayName,
      bio: bio ?? this.bio,
      lastSeen: lastSeen ?? this.lastSeen,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (masterPubKeyHex.present) {
      map['master_pub_key_hex'] = Variable<String>(masterPubKeyHex.value);
    }
    if (nostrPubKeyHex.present) {
      map['nostr_pub_key_hex'] = Variable<String>(nostrPubKeyHex.value);
    }
    if (username.present) {
      map['username'] = Variable<String>(username.value);
    }
    if (displayName.present) {
      map['display_name'] = Variable<String>(displayName.value);
    }
    if (bio.present) {
      map['bio'] = Variable<String>(bio.value);
    }
    if (lastSeen.present) {
      map['last_seen'] = Variable<DateTime>(lastSeen.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ActiveChatsCompanion(')
          ..write('masterPubKeyHex: $masterPubKeyHex, ')
          ..write('nostrPubKeyHex: $nostrPubKeyHex, ')
          ..write('username: $username, ')
          ..write('displayName: $displayName, ')
          ..write('bio: $bio, ')
          ..write('lastSeen: $lastSeen, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ChatMessagesTable extends ChatMessages
    with TableInfo<$ChatMessagesTable, ChatMessageRecord> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ChatMessagesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _nostrPubKeyHexMeta = const VerificationMeta(
    'nostrPubKeyHex',
  );
  @override
  late final GeneratedColumn<String> nostrPubKeyHex = GeneratedColumn<String>(
    'nostr_pub_key_hex',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _messageTextMeta = const VerificationMeta(
    'messageText',
  );
  @override
  late final GeneratedColumn<String> messageText = GeneratedColumn<String>(
    'message_text',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _isMeMeta = const VerificationMeta('isMe');
  @override
  late final GeneratedColumn<bool> isMe = GeneratedColumn<bool>(
    'is_me',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_me" IN (0, 1))',
    ),
  );
  static const VerificationMeta _timestampMeta = const VerificationMeta(
    'timestamp',
  );
  @override
  late final GeneratedColumn<DateTime> timestamp = GeneratedColumn<DateTime>(
    'timestamp',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    nostrPubKeyHex,
    messageText,
    isMe,
    timestamp,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'chat_messages';
  @override
  VerificationContext validateIntegrity(
    Insertable<ChatMessageRecord> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('nostr_pub_key_hex')) {
      context.handle(
        _nostrPubKeyHexMeta,
        nostrPubKeyHex.isAcceptableOrUnknown(
          data['nostr_pub_key_hex']!,
          _nostrPubKeyHexMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_nostrPubKeyHexMeta);
    }
    if (data.containsKey('message_text')) {
      context.handle(
        _messageTextMeta,
        messageText.isAcceptableOrUnknown(
          data['message_text']!,
          _messageTextMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_messageTextMeta);
    }
    if (data.containsKey('is_me')) {
      context.handle(
        _isMeMeta,
        isMe.isAcceptableOrUnknown(data['is_me']!, _isMeMeta),
      );
    } else if (isInserting) {
      context.missing(_isMeMeta);
    }
    if (data.containsKey('timestamp')) {
      context.handle(
        _timestampMeta,
        timestamp.isAcceptableOrUnknown(data['timestamp']!, _timestampMeta),
      );
    } else if (isInserting) {
      context.missing(_timestampMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  ChatMessageRecord map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ChatMessageRecord(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      nostrPubKeyHex: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}nostr_pub_key_hex'],
      )!,
      messageText: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}message_text'],
      )!,
      isMe: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_me'],
      )!,
      timestamp: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}timestamp'],
      )!,
    );
  }

  @override
  $ChatMessagesTable createAlias(String alias) {
    return $ChatMessagesTable(attachedDatabase, alias);
  }
}

class ChatMessageRecord extends DataClass
    implements Insertable<ChatMessageRecord> {
  final int id;
  final String nostrPubKeyHex;
  final String messageText;
  final bool isMe;
  final DateTime timestamp;
  const ChatMessageRecord({
    required this.id,
    required this.nostrPubKeyHex,
    required this.messageText,
    required this.isMe,
    required this.timestamp,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['nostr_pub_key_hex'] = Variable<String>(nostrPubKeyHex);
    map['message_text'] = Variable<String>(messageText);
    map['is_me'] = Variable<bool>(isMe);
    map['timestamp'] = Variable<DateTime>(timestamp);
    return map;
  }

  ChatMessagesCompanion toCompanion(bool nullToAbsent) {
    return ChatMessagesCompanion(
      id: Value(id),
      nostrPubKeyHex: Value(nostrPubKeyHex),
      messageText: Value(messageText),
      isMe: Value(isMe),
      timestamp: Value(timestamp),
    );
  }

  factory ChatMessageRecord.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ChatMessageRecord(
      id: serializer.fromJson<int>(json['id']),
      nostrPubKeyHex: serializer.fromJson<String>(json['nostrPubKeyHex']),
      messageText: serializer.fromJson<String>(json['messageText']),
      isMe: serializer.fromJson<bool>(json['isMe']),
      timestamp: serializer.fromJson<DateTime>(json['timestamp']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'nostrPubKeyHex': serializer.toJson<String>(nostrPubKeyHex),
      'messageText': serializer.toJson<String>(messageText),
      'isMe': serializer.toJson<bool>(isMe),
      'timestamp': serializer.toJson<DateTime>(timestamp),
    };
  }

  ChatMessageRecord copyWith({
    int? id,
    String? nostrPubKeyHex,
    String? messageText,
    bool? isMe,
    DateTime? timestamp,
  }) => ChatMessageRecord(
    id: id ?? this.id,
    nostrPubKeyHex: nostrPubKeyHex ?? this.nostrPubKeyHex,
    messageText: messageText ?? this.messageText,
    isMe: isMe ?? this.isMe,
    timestamp: timestamp ?? this.timestamp,
  );
  ChatMessageRecord copyWithCompanion(ChatMessagesCompanion data) {
    return ChatMessageRecord(
      id: data.id.present ? data.id.value : this.id,
      nostrPubKeyHex: data.nostrPubKeyHex.present
          ? data.nostrPubKeyHex.value
          : this.nostrPubKeyHex,
      messageText: data.messageText.present
          ? data.messageText.value
          : this.messageText,
      isMe: data.isMe.present ? data.isMe.value : this.isMe,
      timestamp: data.timestamp.present ? data.timestamp.value : this.timestamp,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ChatMessageRecord(')
          ..write('id: $id, ')
          ..write('nostrPubKeyHex: $nostrPubKeyHex, ')
          ..write('messageText: $messageText, ')
          ..write('isMe: $isMe, ')
          ..write('timestamp: $timestamp')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, nostrPubKeyHex, messageText, isMe, timestamp);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ChatMessageRecord &&
          other.id == this.id &&
          other.nostrPubKeyHex == this.nostrPubKeyHex &&
          other.messageText == this.messageText &&
          other.isMe == this.isMe &&
          other.timestamp == this.timestamp);
}

class ChatMessagesCompanion extends UpdateCompanion<ChatMessageRecord> {
  final Value<int> id;
  final Value<String> nostrPubKeyHex;
  final Value<String> messageText;
  final Value<bool> isMe;
  final Value<DateTime> timestamp;
  const ChatMessagesCompanion({
    this.id = const Value.absent(),
    this.nostrPubKeyHex = const Value.absent(),
    this.messageText = const Value.absent(),
    this.isMe = const Value.absent(),
    this.timestamp = const Value.absent(),
  });
  ChatMessagesCompanion.insert({
    this.id = const Value.absent(),
    required String nostrPubKeyHex,
    required String messageText,
    required bool isMe,
    required DateTime timestamp,
  }) : nostrPubKeyHex = Value(nostrPubKeyHex),
       messageText = Value(messageText),
       isMe = Value(isMe),
       timestamp = Value(timestamp);
  static Insertable<ChatMessageRecord> custom({
    Expression<int>? id,
    Expression<String>? nostrPubKeyHex,
    Expression<String>? messageText,
    Expression<bool>? isMe,
    Expression<DateTime>? timestamp,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (nostrPubKeyHex != null) 'nostr_pub_key_hex': nostrPubKeyHex,
      if (messageText != null) 'message_text': messageText,
      if (isMe != null) 'is_me': isMe,
      if (timestamp != null) 'timestamp': timestamp,
    });
  }

  ChatMessagesCompanion copyWith({
    Value<int>? id,
    Value<String>? nostrPubKeyHex,
    Value<String>? messageText,
    Value<bool>? isMe,
    Value<DateTime>? timestamp,
  }) {
    return ChatMessagesCompanion(
      id: id ?? this.id,
      nostrPubKeyHex: nostrPubKeyHex ?? this.nostrPubKeyHex,
      messageText: messageText ?? this.messageText,
      isMe: isMe ?? this.isMe,
      timestamp: timestamp ?? this.timestamp,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (nostrPubKeyHex.present) {
      map['nostr_pub_key_hex'] = Variable<String>(nostrPubKeyHex.value);
    }
    if (messageText.present) {
      map['message_text'] = Variable<String>(messageText.value);
    }
    if (isMe.present) {
      map['is_me'] = Variable<bool>(isMe.value);
    }
    if (timestamp.present) {
      map['timestamp'] = Variable<DateTime>(timestamp.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ChatMessagesCompanion(')
          ..write('id: $id, ')
          ..write('nostrPubKeyHex: $nostrPubKeyHex, ')
          ..write('messageText: $messageText, ')
          ..write('isMe: $isMe, ')
          ..write('timestamp: $timestamp')
          ..write(')'))
        .toString();
  }
}

class $SignalIdentitiesTable extends SignalIdentities
    with TableInfo<$SignalIdentitiesTable, SignalIdentityRecord> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SignalIdentitiesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _addressMeta = const VerificationMeta(
    'address',
  );
  @override
  late final GeneratedColumn<String> address = GeneratedColumn<String>(
    'address',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _identityKeyMeta = const VerificationMeta(
    'identityKey',
  );
  @override
  late final GeneratedColumn<Uint8List> identityKey =
      GeneratedColumn<Uint8List>(
        'identity_key',
        aliasedName,
        false,
        type: DriftSqlType.blob,
        requiredDuringInsert: true,
      );
  @override
  List<GeneratedColumn> get $columns => [address, identityKey];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'signal_identities';
  @override
  VerificationContext validateIntegrity(
    Insertable<SignalIdentityRecord> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('address')) {
      context.handle(
        _addressMeta,
        address.isAcceptableOrUnknown(data['address']!, _addressMeta),
      );
    } else if (isInserting) {
      context.missing(_addressMeta);
    }
    if (data.containsKey('identity_key')) {
      context.handle(
        _identityKeyMeta,
        identityKey.isAcceptableOrUnknown(
          data['identity_key']!,
          _identityKeyMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_identityKeyMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {address};
  @override
  SignalIdentityRecord map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SignalIdentityRecord(
      address: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}address'],
      )!,
      identityKey: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}identity_key'],
      )!,
    );
  }

  @override
  $SignalIdentitiesTable createAlias(String alias) {
    return $SignalIdentitiesTable(attachedDatabase, alias);
  }
}

class SignalIdentityRecord extends DataClass
    implements Insertable<SignalIdentityRecord> {
  final String address;
  final Uint8List identityKey;
  const SignalIdentityRecord({
    required this.address,
    required this.identityKey,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['address'] = Variable<String>(address);
    map['identity_key'] = Variable<Uint8List>(identityKey);
    return map;
  }

  SignalIdentitiesCompanion toCompanion(bool nullToAbsent) {
    return SignalIdentitiesCompanion(
      address: Value(address),
      identityKey: Value(identityKey),
    );
  }

  factory SignalIdentityRecord.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SignalIdentityRecord(
      address: serializer.fromJson<String>(json['address']),
      identityKey: serializer.fromJson<Uint8List>(json['identityKey']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'address': serializer.toJson<String>(address),
      'identityKey': serializer.toJson<Uint8List>(identityKey),
    };
  }

  SignalIdentityRecord copyWith({String? address, Uint8List? identityKey}) =>
      SignalIdentityRecord(
        address: address ?? this.address,
        identityKey: identityKey ?? this.identityKey,
      );
  SignalIdentityRecord copyWithCompanion(SignalIdentitiesCompanion data) {
    return SignalIdentityRecord(
      address: data.address.present ? data.address.value : this.address,
      identityKey: data.identityKey.present
          ? data.identityKey.value
          : this.identityKey,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SignalIdentityRecord(')
          ..write('address: $address, ')
          ..write('identityKey: $identityKey')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(address, $driftBlobEquality.hash(identityKey));
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SignalIdentityRecord &&
          other.address == this.address &&
          $driftBlobEquality.equals(other.identityKey, this.identityKey));
}

class SignalIdentitiesCompanion extends UpdateCompanion<SignalIdentityRecord> {
  final Value<String> address;
  final Value<Uint8List> identityKey;
  final Value<int> rowid;
  const SignalIdentitiesCompanion({
    this.address = const Value.absent(),
    this.identityKey = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SignalIdentitiesCompanion.insert({
    required String address,
    required Uint8List identityKey,
    this.rowid = const Value.absent(),
  }) : address = Value(address),
       identityKey = Value(identityKey);
  static Insertable<SignalIdentityRecord> custom({
    Expression<String>? address,
    Expression<Uint8List>? identityKey,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (address != null) 'address': address,
      if (identityKey != null) 'identity_key': identityKey,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SignalIdentitiesCompanion copyWith({
    Value<String>? address,
    Value<Uint8List>? identityKey,
    Value<int>? rowid,
  }) {
    return SignalIdentitiesCompanion(
      address: address ?? this.address,
      identityKey: identityKey ?? this.identityKey,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (address.present) {
      map['address'] = Variable<String>(address.value);
    }
    if (identityKey.present) {
      map['identity_key'] = Variable<Uint8List>(identityKey.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SignalIdentitiesCompanion(')
          ..write('address: $address, ')
          ..write('identityKey: $identityKey, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SignalPreKeysTable extends SignalPreKeys
    with TableInfo<$SignalPreKeysTable, SignalPreKeyRecord> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SignalPreKeysTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _preKeyIdMeta = const VerificationMeta(
    'preKeyId',
  );
  @override
  late final GeneratedColumn<int> preKeyId = GeneratedColumn<int>(
    'pre_key_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _recordMeta = const VerificationMeta('record');
  @override
  late final GeneratedColumn<Uint8List> record = GeneratedColumn<Uint8List>(
    'record',
    aliasedName,
    false,
    type: DriftSqlType.blob,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [preKeyId, record];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'signal_pre_keys';
  @override
  VerificationContext validateIntegrity(
    Insertable<SignalPreKeyRecord> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('pre_key_id')) {
      context.handle(
        _preKeyIdMeta,
        preKeyId.isAcceptableOrUnknown(data['pre_key_id']!, _preKeyIdMeta),
      );
    }
    if (data.containsKey('record')) {
      context.handle(
        _recordMeta,
        record.isAcceptableOrUnknown(data['record']!, _recordMeta),
      );
    } else if (isInserting) {
      context.missing(_recordMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {preKeyId};
  @override
  SignalPreKeyRecord map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SignalPreKeyRecord(
      preKeyId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}pre_key_id'],
      )!,
      record: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}record'],
      )!,
    );
  }

  @override
  $SignalPreKeysTable createAlias(String alias) {
    return $SignalPreKeysTable(attachedDatabase, alias);
  }
}

class SignalPreKeyRecord extends DataClass
    implements Insertable<SignalPreKeyRecord> {
  final int preKeyId;
  final Uint8List record;
  const SignalPreKeyRecord({required this.preKeyId, required this.record});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['pre_key_id'] = Variable<int>(preKeyId);
    map['record'] = Variable<Uint8List>(record);
    return map;
  }

  SignalPreKeysCompanion toCompanion(bool nullToAbsent) {
    return SignalPreKeysCompanion(
      preKeyId: Value(preKeyId),
      record: Value(record),
    );
  }

  factory SignalPreKeyRecord.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SignalPreKeyRecord(
      preKeyId: serializer.fromJson<int>(json['preKeyId']),
      record: serializer.fromJson<Uint8List>(json['record']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'preKeyId': serializer.toJson<int>(preKeyId),
      'record': serializer.toJson<Uint8List>(record),
    };
  }

  SignalPreKeyRecord copyWith({int? preKeyId, Uint8List? record}) =>
      SignalPreKeyRecord(
        preKeyId: preKeyId ?? this.preKeyId,
        record: record ?? this.record,
      );
  SignalPreKeyRecord copyWithCompanion(SignalPreKeysCompanion data) {
    return SignalPreKeyRecord(
      preKeyId: data.preKeyId.present ? data.preKeyId.value : this.preKeyId,
      record: data.record.present ? data.record.value : this.record,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SignalPreKeyRecord(')
          ..write('preKeyId: $preKeyId, ')
          ..write('record: $record')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(preKeyId, $driftBlobEquality.hash(record));
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SignalPreKeyRecord &&
          other.preKeyId == this.preKeyId &&
          $driftBlobEquality.equals(other.record, this.record));
}

class SignalPreKeysCompanion extends UpdateCompanion<SignalPreKeyRecord> {
  final Value<int> preKeyId;
  final Value<Uint8List> record;
  const SignalPreKeysCompanion({
    this.preKeyId = const Value.absent(),
    this.record = const Value.absent(),
  });
  SignalPreKeysCompanion.insert({
    this.preKeyId = const Value.absent(),
    required Uint8List record,
  }) : record = Value(record);
  static Insertable<SignalPreKeyRecord> custom({
    Expression<int>? preKeyId,
    Expression<Uint8List>? record,
  }) {
    return RawValuesInsertable({
      if (preKeyId != null) 'pre_key_id': preKeyId,
      if (record != null) 'record': record,
    });
  }

  SignalPreKeysCompanion copyWith({
    Value<int>? preKeyId,
    Value<Uint8List>? record,
  }) {
    return SignalPreKeysCompanion(
      preKeyId: preKeyId ?? this.preKeyId,
      record: record ?? this.record,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (preKeyId.present) {
      map['pre_key_id'] = Variable<int>(preKeyId.value);
    }
    if (record.present) {
      map['record'] = Variable<Uint8List>(record.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SignalPreKeysCompanion(')
          ..write('preKeyId: $preKeyId, ')
          ..write('record: $record')
          ..write(')'))
        .toString();
  }
}

class $SignalSignedPreKeysTable extends SignalSignedPreKeys
    with TableInfo<$SignalSignedPreKeysTable, SignalSignedPreKeyRecord> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SignalSignedPreKeysTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _signedPreKeyIdMeta = const VerificationMeta(
    'signedPreKeyId',
  );
  @override
  late final GeneratedColumn<int> signedPreKeyId = GeneratedColumn<int>(
    'signed_pre_key_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _recordMeta = const VerificationMeta('record');
  @override
  late final GeneratedColumn<Uint8List> record = GeneratedColumn<Uint8List>(
    'record',
    aliasedName,
    false,
    type: DriftSqlType.blob,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [signedPreKeyId, record];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'signal_signed_pre_keys';
  @override
  VerificationContext validateIntegrity(
    Insertable<SignalSignedPreKeyRecord> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('signed_pre_key_id')) {
      context.handle(
        _signedPreKeyIdMeta,
        signedPreKeyId.isAcceptableOrUnknown(
          data['signed_pre_key_id']!,
          _signedPreKeyIdMeta,
        ),
      );
    }
    if (data.containsKey('record')) {
      context.handle(
        _recordMeta,
        record.isAcceptableOrUnknown(data['record']!, _recordMeta),
      );
    } else if (isInserting) {
      context.missing(_recordMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {signedPreKeyId};
  @override
  SignalSignedPreKeyRecord map(
    Map<String, dynamic> data, {
    String? tablePrefix,
  }) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SignalSignedPreKeyRecord(
      signedPreKeyId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}signed_pre_key_id'],
      )!,
      record: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}record'],
      )!,
    );
  }

  @override
  $SignalSignedPreKeysTable createAlias(String alias) {
    return $SignalSignedPreKeysTable(attachedDatabase, alias);
  }
}

class SignalSignedPreKeyRecord extends DataClass
    implements Insertable<SignalSignedPreKeyRecord> {
  final int signedPreKeyId;
  final Uint8List record;
  const SignalSignedPreKeyRecord({
    required this.signedPreKeyId,
    required this.record,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['signed_pre_key_id'] = Variable<int>(signedPreKeyId);
    map['record'] = Variable<Uint8List>(record);
    return map;
  }

  SignalSignedPreKeysCompanion toCompanion(bool nullToAbsent) {
    return SignalSignedPreKeysCompanion(
      signedPreKeyId: Value(signedPreKeyId),
      record: Value(record),
    );
  }

  factory SignalSignedPreKeyRecord.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SignalSignedPreKeyRecord(
      signedPreKeyId: serializer.fromJson<int>(json['signedPreKeyId']),
      record: serializer.fromJson<Uint8List>(json['record']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'signedPreKeyId': serializer.toJson<int>(signedPreKeyId),
      'record': serializer.toJson<Uint8List>(record),
    };
  }

  SignalSignedPreKeyRecord copyWith({int? signedPreKeyId, Uint8List? record}) =>
      SignalSignedPreKeyRecord(
        signedPreKeyId: signedPreKeyId ?? this.signedPreKeyId,
        record: record ?? this.record,
      );
  SignalSignedPreKeyRecord copyWithCompanion(
    SignalSignedPreKeysCompanion data,
  ) {
    return SignalSignedPreKeyRecord(
      signedPreKeyId: data.signedPreKeyId.present
          ? data.signedPreKeyId.value
          : this.signedPreKeyId,
      record: data.record.present ? data.record.value : this.record,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SignalSignedPreKeyRecord(')
          ..write('signedPreKeyId: $signedPreKeyId, ')
          ..write('record: $record')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(signedPreKeyId, $driftBlobEquality.hash(record));
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SignalSignedPreKeyRecord &&
          other.signedPreKeyId == this.signedPreKeyId &&
          $driftBlobEquality.equals(other.record, this.record));
}

class SignalSignedPreKeysCompanion
    extends UpdateCompanion<SignalSignedPreKeyRecord> {
  final Value<int> signedPreKeyId;
  final Value<Uint8List> record;
  const SignalSignedPreKeysCompanion({
    this.signedPreKeyId = const Value.absent(),
    this.record = const Value.absent(),
  });
  SignalSignedPreKeysCompanion.insert({
    this.signedPreKeyId = const Value.absent(),
    required Uint8List record,
  }) : record = Value(record);
  static Insertable<SignalSignedPreKeyRecord> custom({
    Expression<int>? signedPreKeyId,
    Expression<Uint8List>? record,
  }) {
    return RawValuesInsertable({
      if (signedPreKeyId != null) 'signed_pre_key_id': signedPreKeyId,
      if (record != null) 'record': record,
    });
  }

  SignalSignedPreKeysCompanion copyWith({
    Value<int>? signedPreKeyId,
    Value<Uint8List>? record,
  }) {
    return SignalSignedPreKeysCompanion(
      signedPreKeyId: signedPreKeyId ?? this.signedPreKeyId,
      record: record ?? this.record,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (signedPreKeyId.present) {
      map['signed_pre_key_id'] = Variable<int>(signedPreKeyId.value);
    }
    if (record.present) {
      map['record'] = Variable<Uint8List>(record.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SignalSignedPreKeysCompanion(')
          ..write('signedPreKeyId: $signedPreKeyId, ')
          ..write('record: $record')
          ..write(')'))
        .toString();
  }
}

class $SignalSessionsTable extends SignalSessions
    with TableInfo<$SignalSessionsTable, SignalSessionRecord> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SignalSessionsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _addressMeta = const VerificationMeta(
    'address',
  );
  @override
  late final GeneratedColumn<String> address = GeneratedColumn<String>(
    'address',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _recordMeta = const VerificationMeta('record');
  @override
  late final GeneratedColumn<Uint8List> record = GeneratedColumn<Uint8List>(
    'record',
    aliasedName,
    false,
    type: DriftSqlType.blob,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [address, record];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'signal_sessions';
  @override
  VerificationContext validateIntegrity(
    Insertable<SignalSessionRecord> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('address')) {
      context.handle(
        _addressMeta,
        address.isAcceptableOrUnknown(data['address']!, _addressMeta),
      );
    } else if (isInserting) {
      context.missing(_addressMeta);
    }
    if (data.containsKey('record')) {
      context.handle(
        _recordMeta,
        record.isAcceptableOrUnknown(data['record']!, _recordMeta),
      );
    } else if (isInserting) {
      context.missing(_recordMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {address};
  @override
  SignalSessionRecord map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SignalSessionRecord(
      address: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}address'],
      )!,
      record: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}record'],
      )!,
    );
  }

  @override
  $SignalSessionsTable createAlias(String alias) {
    return $SignalSessionsTable(attachedDatabase, alias);
  }
}

class SignalSessionRecord extends DataClass
    implements Insertable<SignalSessionRecord> {
  final String address;
  final Uint8List record;
  const SignalSessionRecord({required this.address, required this.record});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['address'] = Variable<String>(address);
    map['record'] = Variable<Uint8List>(record);
    return map;
  }

  SignalSessionsCompanion toCompanion(bool nullToAbsent) {
    return SignalSessionsCompanion(
      address: Value(address),
      record: Value(record),
    );
  }

  factory SignalSessionRecord.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SignalSessionRecord(
      address: serializer.fromJson<String>(json['address']),
      record: serializer.fromJson<Uint8List>(json['record']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'address': serializer.toJson<String>(address),
      'record': serializer.toJson<Uint8List>(record),
    };
  }

  SignalSessionRecord copyWith({String? address, Uint8List? record}) =>
      SignalSessionRecord(
        address: address ?? this.address,
        record: record ?? this.record,
      );
  SignalSessionRecord copyWithCompanion(SignalSessionsCompanion data) {
    return SignalSessionRecord(
      address: data.address.present ? data.address.value : this.address,
      record: data.record.present ? data.record.value : this.record,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SignalSessionRecord(')
          ..write('address: $address, ')
          ..write('record: $record')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(address, $driftBlobEquality.hash(record));
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SignalSessionRecord &&
          other.address == this.address &&
          $driftBlobEquality.equals(other.record, this.record));
}

class SignalSessionsCompanion extends UpdateCompanion<SignalSessionRecord> {
  final Value<String> address;
  final Value<Uint8List> record;
  final Value<int> rowid;
  const SignalSessionsCompanion({
    this.address = const Value.absent(),
    this.record = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SignalSessionsCompanion.insert({
    required String address,
    required Uint8List record,
    this.rowid = const Value.absent(),
  }) : address = Value(address),
       record = Value(record);
  static Insertable<SignalSessionRecord> custom({
    Expression<String>? address,
    Expression<Uint8List>? record,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (address != null) 'address': address,
      if (record != null) 'record': record,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SignalSessionsCompanion copyWith({
    Value<String>? address,
    Value<Uint8List>? record,
    Value<int>? rowid,
  }) {
    return SignalSessionsCompanion(
      address: address ?? this.address,
      record: record ?? this.record,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (address.present) {
      map['address'] = Variable<String>(address.value);
    }
    if (record.present) {
      map['record'] = Variable<Uint8List>(record.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SignalSessionsCompanion(')
          ..write('address: $address, ')
          ..write('record: $record, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $ActiveChatsTable activeChats = $ActiveChatsTable(this);
  late final $ChatMessagesTable chatMessages = $ChatMessagesTable(this);
  late final $SignalIdentitiesTable signalIdentities = $SignalIdentitiesTable(
    this,
  );
  late final $SignalPreKeysTable signalPreKeys = $SignalPreKeysTable(this);
  late final $SignalSignedPreKeysTable signalSignedPreKeys =
      $SignalSignedPreKeysTable(this);
  late final $SignalSessionsTable signalSessions = $SignalSessionsTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    activeChats,
    chatMessages,
    signalIdentities,
    signalPreKeys,
    signalSignedPreKeys,
    signalSessions,
  ];
}

typedef $$ActiveChatsTableCreateCompanionBuilder =
    ActiveChatsCompanion Function({
      required String masterPubKeyHex,
      required String nostrPubKeyHex,
      required String username,
      Value<String?> displayName,
      Value<String?> bio,
      required DateTime lastSeen,
      Value<int> rowid,
    });
typedef $$ActiveChatsTableUpdateCompanionBuilder =
    ActiveChatsCompanion Function({
      Value<String> masterPubKeyHex,
      Value<String> nostrPubKeyHex,
      Value<String> username,
      Value<String?> displayName,
      Value<String?> bio,
      Value<DateTime> lastSeen,
      Value<int> rowid,
    });

class $$ActiveChatsTableFilterComposer
    extends Composer<_$AppDatabase, $ActiveChatsTable> {
  $$ActiveChatsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get masterPubKeyHex => $composableBuilder(
    column: $table.masterPubKeyHex,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get nostrPubKeyHex => $composableBuilder(
    column: $table.nostrPubKeyHex,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get username => $composableBuilder(
    column: $table.username,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get bio => $composableBuilder(
    column: $table.bio,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get lastSeen => $composableBuilder(
    column: $table.lastSeen,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ActiveChatsTableOrderingComposer
    extends Composer<_$AppDatabase, $ActiveChatsTable> {
  $$ActiveChatsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get masterPubKeyHex => $composableBuilder(
    column: $table.masterPubKeyHex,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get nostrPubKeyHex => $composableBuilder(
    column: $table.nostrPubKeyHex,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get username => $composableBuilder(
    column: $table.username,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get bio => $composableBuilder(
    column: $table.bio,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get lastSeen => $composableBuilder(
    column: $table.lastSeen,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ActiveChatsTableAnnotationComposer
    extends Composer<_$AppDatabase, $ActiveChatsTable> {
  $$ActiveChatsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get masterPubKeyHex => $composableBuilder(
    column: $table.masterPubKeyHex,
    builder: (column) => column,
  );

  GeneratedColumn<String> get nostrPubKeyHex => $composableBuilder(
    column: $table.nostrPubKeyHex,
    builder: (column) => column,
  );

  GeneratedColumn<String> get username =>
      $composableBuilder(column: $table.username, builder: (column) => column);

  GeneratedColumn<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => column,
  );

  GeneratedColumn<String> get bio =>
      $composableBuilder(column: $table.bio, builder: (column) => column);

  GeneratedColumn<DateTime> get lastSeen =>
      $composableBuilder(column: $table.lastSeen, builder: (column) => column);
}

class $$ActiveChatsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ActiveChatsTable,
          ActiveChatRecord,
          $$ActiveChatsTableFilterComposer,
          $$ActiveChatsTableOrderingComposer,
          $$ActiveChatsTableAnnotationComposer,
          $$ActiveChatsTableCreateCompanionBuilder,
          $$ActiveChatsTableUpdateCompanionBuilder,
          (
            ActiveChatRecord,
            BaseReferences<_$AppDatabase, $ActiveChatsTable, ActiveChatRecord>,
          ),
          ActiveChatRecord,
          PrefetchHooks Function()
        > {
  $$ActiveChatsTableTableManager(_$AppDatabase db, $ActiveChatsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ActiveChatsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ActiveChatsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ActiveChatsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> masterPubKeyHex = const Value.absent(),
                Value<String> nostrPubKeyHex = const Value.absent(),
                Value<String> username = const Value.absent(),
                Value<String?> displayName = const Value.absent(),
                Value<String?> bio = const Value.absent(),
                Value<DateTime> lastSeen = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ActiveChatsCompanion(
                masterPubKeyHex: masterPubKeyHex,
                nostrPubKeyHex: nostrPubKeyHex,
                username: username,
                displayName: displayName,
                bio: bio,
                lastSeen: lastSeen,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String masterPubKeyHex,
                required String nostrPubKeyHex,
                required String username,
                Value<String?> displayName = const Value.absent(),
                Value<String?> bio = const Value.absent(),
                required DateTime lastSeen,
                Value<int> rowid = const Value.absent(),
              }) => ActiveChatsCompanion.insert(
                masterPubKeyHex: masterPubKeyHex,
                nostrPubKeyHex: nostrPubKeyHex,
                username: username,
                displayName: displayName,
                bio: bio,
                lastSeen: lastSeen,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$ActiveChatsTable, ActiveChatRecord>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $ActiveChatsTable,
                    ActiveChatRecord
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ActiveChatsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ActiveChatsTable,
      ActiveChatRecord,
      $$ActiveChatsTableFilterComposer,
      $$ActiveChatsTableOrderingComposer,
      $$ActiveChatsTableAnnotationComposer,
      $$ActiveChatsTableCreateCompanionBuilder,
      $$ActiveChatsTableUpdateCompanionBuilder,
      (
        ActiveChatRecord,
        BaseReferences<_$AppDatabase, $ActiveChatsTable, ActiveChatRecord>,
      ),
      ActiveChatRecord,
      PrefetchHooks Function()
    >;
typedef $$ChatMessagesTableCreateCompanionBuilder =
    ChatMessagesCompanion Function({
      Value<int> id,
      required String nostrPubKeyHex,
      required String messageText,
      required bool isMe,
      required DateTime timestamp,
    });
typedef $$ChatMessagesTableUpdateCompanionBuilder =
    ChatMessagesCompanion Function({
      Value<int> id,
      Value<String> nostrPubKeyHex,
      Value<String> messageText,
      Value<bool> isMe,
      Value<DateTime> timestamp,
    });

class $$ChatMessagesTableFilterComposer
    extends Composer<_$AppDatabase, $ChatMessagesTable> {
  $$ChatMessagesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get nostrPubKeyHex => $composableBuilder(
    column: $table.nostrPubKeyHex,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get messageText => $composableBuilder(
    column: $table.messageText,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isMe => $composableBuilder(
    column: $table.isMe,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get timestamp => $composableBuilder(
    column: $table.timestamp,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ChatMessagesTableOrderingComposer
    extends Composer<_$AppDatabase, $ChatMessagesTable> {
  $$ChatMessagesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get nostrPubKeyHex => $composableBuilder(
    column: $table.nostrPubKeyHex,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get messageText => $composableBuilder(
    column: $table.messageText,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isMe => $composableBuilder(
    column: $table.isMe,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get timestamp => $composableBuilder(
    column: $table.timestamp,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ChatMessagesTableAnnotationComposer
    extends Composer<_$AppDatabase, $ChatMessagesTable> {
  $$ChatMessagesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get nostrPubKeyHex => $composableBuilder(
    column: $table.nostrPubKeyHex,
    builder: (column) => column,
  );

  GeneratedColumn<String> get messageText => $composableBuilder(
    column: $table.messageText,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get isMe =>
      $composableBuilder(column: $table.isMe, builder: (column) => column);

  GeneratedColumn<DateTime> get timestamp =>
      $composableBuilder(column: $table.timestamp, builder: (column) => column);
}

class $$ChatMessagesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ChatMessagesTable,
          ChatMessageRecord,
          $$ChatMessagesTableFilterComposer,
          $$ChatMessagesTableOrderingComposer,
          $$ChatMessagesTableAnnotationComposer,
          $$ChatMessagesTableCreateCompanionBuilder,
          $$ChatMessagesTableUpdateCompanionBuilder,
          (
            ChatMessageRecord,
            BaseReferences<
              _$AppDatabase,
              $ChatMessagesTable,
              ChatMessageRecord
            >,
          ),
          ChatMessageRecord,
          PrefetchHooks Function()
        > {
  $$ChatMessagesTableTableManager(_$AppDatabase db, $ChatMessagesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ChatMessagesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ChatMessagesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ChatMessagesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> nostrPubKeyHex = const Value.absent(),
                Value<String> messageText = const Value.absent(),
                Value<bool> isMe = const Value.absent(),
                Value<DateTime> timestamp = const Value.absent(),
              }) => ChatMessagesCompanion(
                id: id,
                nostrPubKeyHex: nostrPubKeyHex,
                messageText: messageText,
                isMe: isMe,
                timestamp: timestamp,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String nostrPubKeyHex,
                required String messageText,
                required bool isMe,
                required DateTime timestamp,
              }) => ChatMessagesCompanion.insert(
                id: id,
                nostrPubKeyHex: nostrPubKeyHex,
                messageText: messageText,
                isMe: isMe,
                timestamp: timestamp,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$ChatMessagesTable, ChatMessageRecord>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $ChatMessagesTable,
                    ChatMessageRecord
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ChatMessagesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ChatMessagesTable,
      ChatMessageRecord,
      $$ChatMessagesTableFilterComposer,
      $$ChatMessagesTableOrderingComposer,
      $$ChatMessagesTableAnnotationComposer,
      $$ChatMessagesTableCreateCompanionBuilder,
      $$ChatMessagesTableUpdateCompanionBuilder,
      (
        ChatMessageRecord,
        BaseReferences<_$AppDatabase, $ChatMessagesTable, ChatMessageRecord>,
      ),
      ChatMessageRecord,
      PrefetchHooks Function()
    >;
typedef $$SignalIdentitiesTableCreateCompanionBuilder =
    SignalIdentitiesCompanion Function({
      required String address,
      required Uint8List identityKey,
      Value<int> rowid,
    });
typedef $$SignalIdentitiesTableUpdateCompanionBuilder =
    SignalIdentitiesCompanion Function({
      Value<String> address,
      Value<Uint8List> identityKey,
      Value<int> rowid,
    });

class $$SignalIdentitiesTableFilterComposer
    extends Composer<_$AppDatabase, $SignalIdentitiesTable> {
  $$SignalIdentitiesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get address => $composableBuilder(
    column: $table.address,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get identityKey => $composableBuilder(
    column: $table.identityKey,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SignalIdentitiesTableOrderingComposer
    extends Composer<_$AppDatabase, $SignalIdentitiesTable> {
  $$SignalIdentitiesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get address => $composableBuilder(
    column: $table.address,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get identityKey => $composableBuilder(
    column: $table.identityKey,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SignalIdentitiesTableAnnotationComposer
    extends Composer<_$AppDatabase, $SignalIdentitiesTable> {
  $$SignalIdentitiesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get address =>
      $composableBuilder(column: $table.address, builder: (column) => column);

  GeneratedColumn<Uint8List> get identityKey => $composableBuilder(
    column: $table.identityKey,
    builder: (column) => column,
  );
}

class $$SignalIdentitiesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $SignalIdentitiesTable,
          SignalIdentityRecord,
          $$SignalIdentitiesTableFilterComposer,
          $$SignalIdentitiesTableOrderingComposer,
          $$SignalIdentitiesTableAnnotationComposer,
          $$SignalIdentitiesTableCreateCompanionBuilder,
          $$SignalIdentitiesTableUpdateCompanionBuilder,
          (
            SignalIdentityRecord,
            BaseReferences<
              _$AppDatabase,
              $SignalIdentitiesTable,
              SignalIdentityRecord
            >,
          ),
          SignalIdentityRecord,
          PrefetchHooks Function()
        > {
  $$SignalIdentitiesTableTableManager(
    _$AppDatabase db,
    $SignalIdentitiesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SignalIdentitiesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SignalIdentitiesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SignalIdentitiesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> address = const Value.absent(),
                Value<Uint8List> identityKey = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SignalIdentitiesCompanion(
                address: address,
                identityKey: identityKey,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String address,
                required Uint8List identityKey,
                Value<int> rowid = const Value.absent(),
              }) => SignalIdentitiesCompanion.insert(
                address: address,
                identityKey: identityKey,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$SignalIdentitiesTable, SignalIdentityRecord>(
                    table,
                  ),
                  BaseReferences<
                    _$AppDatabase,
                    $SignalIdentitiesTable,
                    SignalIdentityRecord
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SignalIdentitiesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $SignalIdentitiesTable,
      SignalIdentityRecord,
      $$SignalIdentitiesTableFilterComposer,
      $$SignalIdentitiesTableOrderingComposer,
      $$SignalIdentitiesTableAnnotationComposer,
      $$SignalIdentitiesTableCreateCompanionBuilder,
      $$SignalIdentitiesTableUpdateCompanionBuilder,
      (
        SignalIdentityRecord,
        BaseReferences<
          _$AppDatabase,
          $SignalIdentitiesTable,
          SignalIdentityRecord
        >,
      ),
      SignalIdentityRecord,
      PrefetchHooks Function()
    >;
typedef $$SignalPreKeysTableCreateCompanionBuilder =
    SignalPreKeysCompanion Function({
      Value<int> preKeyId,
      required Uint8List record,
    });
typedef $$SignalPreKeysTableUpdateCompanionBuilder =
    SignalPreKeysCompanion Function({
      Value<int> preKeyId,
      Value<Uint8List> record,
    });

class $$SignalPreKeysTableFilterComposer
    extends Composer<_$AppDatabase, $SignalPreKeysTable> {
  $$SignalPreKeysTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get preKeyId => $composableBuilder(
    column: $table.preKeyId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get record => $composableBuilder(
    column: $table.record,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SignalPreKeysTableOrderingComposer
    extends Composer<_$AppDatabase, $SignalPreKeysTable> {
  $$SignalPreKeysTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get preKeyId => $composableBuilder(
    column: $table.preKeyId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get record => $composableBuilder(
    column: $table.record,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SignalPreKeysTableAnnotationComposer
    extends Composer<_$AppDatabase, $SignalPreKeysTable> {
  $$SignalPreKeysTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get preKeyId =>
      $composableBuilder(column: $table.preKeyId, builder: (column) => column);

  GeneratedColumn<Uint8List> get record =>
      $composableBuilder(column: $table.record, builder: (column) => column);
}

class $$SignalPreKeysTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $SignalPreKeysTable,
          SignalPreKeyRecord,
          $$SignalPreKeysTableFilterComposer,
          $$SignalPreKeysTableOrderingComposer,
          $$SignalPreKeysTableAnnotationComposer,
          $$SignalPreKeysTableCreateCompanionBuilder,
          $$SignalPreKeysTableUpdateCompanionBuilder,
          (
            SignalPreKeyRecord,
            BaseReferences<
              _$AppDatabase,
              $SignalPreKeysTable,
              SignalPreKeyRecord
            >,
          ),
          SignalPreKeyRecord,
          PrefetchHooks Function()
        > {
  $$SignalPreKeysTableTableManager(_$AppDatabase db, $SignalPreKeysTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SignalPreKeysTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SignalPreKeysTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SignalPreKeysTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> preKeyId = const Value.absent(),
            Value<Uint8List> record = const Value.absent(),
          }) => SignalPreKeysCompanion(preKeyId: preKeyId, record: record),
          createCompanionCallback:
              ({
                Value<int> preKeyId = const Value.absent(),
                required Uint8List record,
              }) => SignalPreKeysCompanion.insert(
                preKeyId: preKeyId,
                record: record,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$SignalPreKeysTable, SignalPreKeyRecord>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $SignalPreKeysTable,
                    SignalPreKeyRecord
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SignalPreKeysTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $SignalPreKeysTable,
      SignalPreKeyRecord,
      $$SignalPreKeysTableFilterComposer,
      $$SignalPreKeysTableOrderingComposer,
      $$SignalPreKeysTableAnnotationComposer,
      $$SignalPreKeysTableCreateCompanionBuilder,
      $$SignalPreKeysTableUpdateCompanionBuilder,
      (
        SignalPreKeyRecord,
        BaseReferences<_$AppDatabase, $SignalPreKeysTable, SignalPreKeyRecord>,
      ),
      SignalPreKeyRecord,
      PrefetchHooks Function()
    >;
typedef $$SignalSignedPreKeysTableCreateCompanionBuilder =
    SignalSignedPreKeysCompanion Function({
      Value<int> signedPreKeyId,
      required Uint8List record,
    });
typedef $$SignalSignedPreKeysTableUpdateCompanionBuilder =
    SignalSignedPreKeysCompanion Function({
      Value<int> signedPreKeyId,
      Value<Uint8List> record,
    });

class $$SignalSignedPreKeysTableFilterComposer
    extends Composer<_$AppDatabase, $SignalSignedPreKeysTable> {
  $$SignalSignedPreKeysTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get signedPreKeyId => $composableBuilder(
    column: $table.signedPreKeyId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get record => $composableBuilder(
    column: $table.record,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SignalSignedPreKeysTableOrderingComposer
    extends Composer<_$AppDatabase, $SignalSignedPreKeysTable> {
  $$SignalSignedPreKeysTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get signedPreKeyId => $composableBuilder(
    column: $table.signedPreKeyId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get record => $composableBuilder(
    column: $table.record,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SignalSignedPreKeysTableAnnotationComposer
    extends Composer<_$AppDatabase, $SignalSignedPreKeysTable> {
  $$SignalSignedPreKeysTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get signedPreKeyId => $composableBuilder(
    column: $table.signedPreKeyId,
    builder: (column) => column,
  );

  GeneratedColumn<Uint8List> get record =>
      $composableBuilder(column: $table.record, builder: (column) => column);
}

class $$SignalSignedPreKeysTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $SignalSignedPreKeysTable,
          SignalSignedPreKeyRecord,
          $$SignalSignedPreKeysTableFilterComposer,
          $$SignalSignedPreKeysTableOrderingComposer,
          $$SignalSignedPreKeysTableAnnotationComposer,
          $$SignalSignedPreKeysTableCreateCompanionBuilder,
          $$SignalSignedPreKeysTableUpdateCompanionBuilder,
          (
            SignalSignedPreKeyRecord,
            BaseReferences<
              _$AppDatabase,
              $SignalSignedPreKeysTable,
              SignalSignedPreKeyRecord
            >,
          ),
          SignalSignedPreKeyRecord,
          PrefetchHooks Function()
        > {
  $$SignalSignedPreKeysTableTableManager(
    _$AppDatabase db,
    $SignalSignedPreKeysTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SignalSignedPreKeysTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SignalSignedPreKeysTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$SignalSignedPreKeysTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<int> signedPreKeyId = const Value.absent(),
                Value<Uint8List> record = const Value.absent(),
              }) => SignalSignedPreKeysCompanion(
                signedPreKeyId: signedPreKeyId,
                record: record,
              ),
          createCompanionCallback:
              ({
                Value<int> signedPreKeyId = const Value.absent(),
                required Uint8List record,
              }) => SignalSignedPreKeysCompanion.insert(
                signedPreKeyId: signedPreKeyId,
                record: record,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<
                    $SignalSignedPreKeysTable,
                    SignalSignedPreKeyRecord
                  >(table),
                  BaseReferences<
                    _$AppDatabase,
                    $SignalSignedPreKeysTable,
                    SignalSignedPreKeyRecord
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SignalSignedPreKeysTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $SignalSignedPreKeysTable,
      SignalSignedPreKeyRecord,
      $$SignalSignedPreKeysTableFilterComposer,
      $$SignalSignedPreKeysTableOrderingComposer,
      $$SignalSignedPreKeysTableAnnotationComposer,
      $$SignalSignedPreKeysTableCreateCompanionBuilder,
      $$SignalSignedPreKeysTableUpdateCompanionBuilder,
      (
        SignalSignedPreKeyRecord,
        BaseReferences<
          _$AppDatabase,
          $SignalSignedPreKeysTable,
          SignalSignedPreKeyRecord
        >,
      ),
      SignalSignedPreKeyRecord,
      PrefetchHooks Function()
    >;
typedef $$SignalSessionsTableCreateCompanionBuilder =
    SignalSessionsCompanion Function({
      required String address,
      required Uint8List record,
      Value<int> rowid,
    });
typedef $$SignalSessionsTableUpdateCompanionBuilder =
    SignalSessionsCompanion Function({
      Value<String> address,
      Value<Uint8List> record,
      Value<int> rowid,
    });

class $$SignalSessionsTableFilterComposer
    extends Composer<_$AppDatabase, $SignalSessionsTable> {
  $$SignalSessionsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get address => $composableBuilder(
    column: $table.address,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get record => $composableBuilder(
    column: $table.record,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SignalSessionsTableOrderingComposer
    extends Composer<_$AppDatabase, $SignalSessionsTable> {
  $$SignalSessionsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get address => $composableBuilder(
    column: $table.address,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get record => $composableBuilder(
    column: $table.record,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SignalSessionsTableAnnotationComposer
    extends Composer<_$AppDatabase, $SignalSessionsTable> {
  $$SignalSessionsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get address =>
      $composableBuilder(column: $table.address, builder: (column) => column);

  GeneratedColumn<Uint8List> get record =>
      $composableBuilder(column: $table.record, builder: (column) => column);
}

class $$SignalSessionsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $SignalSessionsTable,
          SignalSessionRecord,
          $$SignalSessionsTableFilterComposer,
          $$SignalSessionsTableOrderingComposer,
          $$SignalSessionsTableAnnotationComposer,
          $$SignalSessionsTableCreateCompanionBuilder,
          $$SignalSessionsTableUpdateCompanionBuilder,
          (
            SignalSessionRecord,
            BaseReferences<
              _$AppDatabase,
              $SignalSessionsTable,
              SignalSessionRecord
            >,
          ),
          SignalSessionRecord,
          PrefetchHooks Function()
        > {
  $$SignalSessionsTableTableManager(
    _$AppDatabase db,
    $SignalSessionsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SignalSessionsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SignalSessionsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SignalSessionsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> address = const Value.absent(),
                Value<Uint8List> record = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SignalSessionsCompanion(
                address: address,
                record: record,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String address,
                required Uint8List record,
                Value<int> rowid = const Value.absent(),
              }) => SignalSessionsCompanion.insert(
                address: address,
                record: record,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$SignalSessionsTable, SignalSessionRecord>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $SignalSessionsTable,
                    SignalSessionRecord
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SignalSessionsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $SignalSessionsTable,
      SignalSessionRecord,
      $$SignalSessionsTableFilterComposer,
      $$SignalSessionsTableOrderingComposer,
      $$SignalSessionsTableAnnotationComposer,
      $$SignalSessionsTableCreateCompanionBuilder,
      $$SignalSessionsTableUpdateCompanionBuilder,
      (
        SignalSessionRecord,
        BaseReferences<
          _$AppDatabase,
          $SignalSessionsTable,
          SignalSessionRecord
        >,
      ),
      SignalSessionRecord,
      PrefetchHooks Function()
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$ActiveChatsTableTableManager get activeChats =>
      $$ActiveChatsTableTableManager(_db, _db.activeChats);
  $$ChatMessagesTableTableManager get chatMessages =>
      $$ChatMessagesTableTableManager(_db, _db.chatMessages);
  $$SignalIdentitiesTableTableManager get signalIdentities =>
      $$SignalIdentitiesTableTableManager(_db, _db.signalIdentities);
  $$SignalPreKeysTableTableManager get signalPreKeys =>
      $$SignalPreKeysTableTableManager(_db, _db.signalPreKeys);
  $$SignalSignedPreKeysTableTableManager get signalSignedPreKeys =>
      $$SignalSignedPreKeysTableTableManager(_db, _db.signalSignedPreKeys);
  $$SignalSessionsTableTableManager get signalSessions =>
      $$SignalSessionsTableTableManager(_db, _db.signalSessions);
}
