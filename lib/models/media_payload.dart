import 'dart:convert';

import '../services/voice_note_service.dart';

/// Unified model for all media types (images, videos, audio, documents, voice notes).
/// Backed by client-side AES-256-GCM symmetric encryption and decentralized Blossom storage.
class MediaPayload {
  final String type; // 'media' or 'voice'
  final String mediaType; // 'image', 'video', 'audio', 'document', 'voice'
  final String url;
  final String key; // Base64-encoded AES-256 key
  final String nonce; // Base64-encoded 96-bit nonce
  final String mac; // Base64-encoded 128-bit MAC tag
  final String fileHash; // SHA-256 hex digest of encrypted blob
  final String fileName; // Original file name with extension
  final int fileSize; // File size in bytes
  final String mimeType; // e.g. 'image/jpeg', 'video/mp4', 'application/pdf'
  final String?
  thumbnail; // Optional Base64 low-res preview or blurred placeholder
  final int? width; // Image or video width in pixels
  final int? height; // Image or video height in pixels
  final int durationMs; // Duration in milliseconds (for audio, video, voice)
  final List<int> waveform; // Normalized amplitude array for voice notes
  final int? sentAt; // Milliseconds timestamp
  final String?
  localPath; // Local unencrypted cache path for sender instant preview
  final String? caption; // Optional caption text for media

  MediaPayload({
    this.type = 'media',
    required this.mediaType,
    this.url = '',
    this.key = '',
    this.nonce = '',
    this.mac = '',
    this.fileHash = '',
    this.fileName = '',
    this.fileSize = 0,
    this.mimeType = '',
    this.thumbnail,
    this.width,
    this.height,
    this.durationMs = 0,
    this.waveform = const [],
    this.sentAt,
    this.localPath,
    this.caption,
  });

  bool get isImage => mediaType == 'image';
  bool get isVideo => mediaType == 'video';
  bool get isDocument => mediaType == 'document';
  bool get isAudio => mediaType == 'audio';
  bool get isVoiceNote => mediaType == 'voice' || type == 'voice';

  MediaPayload copyWith({
    String? type,
    String? mediaType,
    String? url,
    String? key,
    String? nonce,
    String? mac,
    String? fileHash,
    String? fileName,
    int? fileSize,
    String? mimeType,
    String? thumbnail,
    int? width,
    int? height,
    int? durationMs,
    List<int>? waveform,
    int? sentAt,
    String? localPath,
    String? caption,
  }) {
    return MediaPayload(
      type: type ?? this.type,
      mediaType: mediaType ?? this.mediaType,
      url: url ?? this.url,
      key: key ?? this.key,
      nonce: nonce ?? this.nonce,
      mac: mac ?? this.mac,
      fileHash: fileHash ?? this.fileHash,
      fileName: fileName ?? this.fileName,
      fileSize: fileSize ?? this.fileSize,
      mimeType: mimeType ?? this.mimeType,
      thumbnail: thumbnail ?? this.thumbnail,
      width: width ?? this.width,
      height: height ?? this.height,
      durationMs: durationMs ?? this.durationMs,
      waveform: waveform ?? this.waveform,
      sentAt: sentAt ?? this.sentAt,
      localPath: localPath ?? this.localPath,
      caption: caption ?? this.caption,
    );
  }

  Map<String, dynamic> toJson() => {
    'type': type,
    'mediaType': mediaType,
    'url': url,
    'key': key,
    'nonce': nonce,
    'mac': mac,
    'fileHash': fileHash,
    'fileName': fileName,
    'fileSize': fileSize,
    'mimeType': mimeType,
    if (thumbnail != null && thumbnail!.isNotEmpty) 'thumbnail': thumbnail,
    if (width != null) 'width': width,
    if (height != null) 'height': height,
    'durationMs': durationMs,
    if (waveform.isNotEmpty) 'waveform': waveform,
    if (sentAt != null) 'sentAt': sentAt,
    if (localPath != null && localPath!.isNotEmpty) 'localPath': localPath,
    if (caption != null && caption!.isNotEmpty) 'caption': caption,
  };

  Map<String, dynamic> toNetworkJson() => {
    'type': type,
    'mediaType': mediaType,
    'url': url,
    'key': key,
    'nonce': nonce,
    'mac': mac,
    'fileHash': fileHash,
    'fileName': fileName,
    'fileSize': fileSize,
    'mimeType': mimeType,
    if (thumbnail != null && thumbnail!.isNotEmpty) 'thumbnail': thumbnail,
    if (width != null) 'width': width,
    if (height != null) 'height': height,
    'durationMs': durationMs,
    if (waveform.isNotEmpty) 'waveform': waveform,
    if (sentAt != null) 'sentAt': sentAt,
    if (caption != null && caption!.isNotEmpty) 'caption': caption,
  };

  String serialize() => jsonEncode(toJson());

  String serializeForNetwork() => jsonEncode(toNetworkJson());

  /// Converts this [MediaPayload] into a legacy [VoiceNotePayload] if mediaType is voice
  VoiceNotePayload toVoiceNotePayload() {
    return VoiceNotePayload(
      url: url,
      key: key,
      nonce: nonce,
      mac: mac,
      fileHash: fileHash,
      durationMs: durationMs,
      waveform: waveform,
      sentAt: sentAt,
      localPath: localPath,
    );
  }

  /// Factory constructor to bridge from legacy [VoiceNotePayload]
  factory MediaPayload.fromVoiceNotePayload(VoiceNotePayload vn) {
    return MediaPayload(
      type: 'voice',
      mediaType: 'voice',
      url: vn.url,
      key: vn.key,
      nonce: vn.nonce,
      mac: vn.mac,
      fileHash: vn.fileHash,
      fileName: 'voice_note.m4a',
      mimeType: 'audio/m4a',
      durationMs: vn.durationMs,
      waveform: vn.waveform,
      sentAt: vn.sentAt,
      localPath: vn.localPath,
    );
  }

  factory MediaPayload.fromJson(
    Map<String, dynamic> json, {
    bool isFromNetwork = false,
  }) {
    // If incoming json is a legacy VoiceNotePayload without explicit 'mediaType'
    final rawType = (json['type'] as String?)?.toLowerCase() ?? 'media';
    final inferredMediaType =
        (json['mediaType'] as String?)?.toLowerCase() ??
        (rawType == 'voice' || rawType == 'voice_note' ? 'voice' : 'document');

    return MediaPayload(
      type: rawType,
      mediaType: inferredMediaType,
      url: json['url'] as String? ?? '',
      key: json['key'] as String? ?? '',
      nonce: json['nonce'] as String? ?? '',
      mac: json['mac'] as String? ?? '',
      fileHash: json['fileHash'] as String? ?? '',
      fileName: json['fileName'] as String? ?? '',
      fileSize: (json['fileSize'] as num?)?.toInt() ?? 0,
      mimeType: json['mimeType'] as String? ?? '',
      thumbnail: json['thumbnail'] as String?,
      width: (json['width'] as num?)?.toInt(),
      height: (json['height'] as num?)?.toInt(),
      durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
      waveform:
          (json['waveform'] as List<dynamic>?)
              ?.map((e) => (e as num).toInt())
              .toList() ??
          [],
      sentAt: (json['sentAt'] as num?)?.toInt(),
      // BUG 9: Strip remotely supplied localPath to prevent accessing arbitrary local files
      localPath: isFromNetwork ? null : json['localPath'] as String?,
      caption: json['caption'] as String?,
    );
  }

  static bool isMedia(String text) {
    final trimmed = text.trim();
    if (!trimmed.startsWith('{')) return false;
    return trimmed.contains('"type":"media"') ||
        trimmed.contains('"type": "media"') ||
        trimmed.contains('"type":"voice"') ||
        trimmed.contains('"type": "voice"') ||
        trimmed.contains('"type":"voice_note"') ||
        trimmed.contains('"type": "voice_note"');
  }

  static MediaPayload? tryParse(String text, {bool isFromNetwork = false}) {
    try {
      if (!isMedia(text)) return null;
      final map = jsonDecode(text);
      if (map is! Map<String, dynamic>) return null;

      // Handle envelope wrapping: if this is a MndoMessageEnvelope containing media
      if ((map['type'] == 'media' ||
              map['type'] == 'voice_note' ||
              map['type'] == 'voice') &&
          map['body'] is Map) {
        final body = map['body'] as Map;
        final innerText = body['text'] ?? body['payload'];
        if (innerText is String) {
          final innerParsed = tryParse(innerText, isFromNetwork: isFromNetwork);
          if (innerParsed != null) return innerParsed;
        } else if (innerText is Map) {
          final innerParsed = MediaPayload.fromJson(
            Map<String, dynamic>.from(innerText),
            isFromNetwork: isFromNetwork,
          );
          if (innerParsed.url.isNotEmpty || innerParsed.fileHash.isNotEmpty) {
            return innerParsed;
          }
        }
      }

      if (map['media'] is Map) {
        final innerParsed = MediaPayload.fromJson(
          Map<String, dynamic>.from(map['media'] as Map),
          isFromNetwork: isFromNetwork,
        );
        if (innerParsed.url.isNotEmpty || innerParsed.fileHash.isNotEmpty) {
          return innerParsed;
        }
      }

      final payload = MediaPayload.fromJson(map, isFromNetwork: isFromNetwork);
      if (payload.url.isEmpty &&
          (payload.localPath == null || payload.localPath!.isEmpty) &&
          payload.fileHash.isEmpty) {
        return null;
      }
      return payload;
    } catch (_) {
      return null;
    }
  }
}
