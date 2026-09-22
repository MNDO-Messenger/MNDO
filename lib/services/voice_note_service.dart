import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path/path.dart' as p;
import 'nostr_relay_service.dart';

/// Payload transmitted out-of-band inside the Signal end-to-end encrypted message
class VoiceNotePayload {
  final String url;
  final String key;      // Base64-encoded AES-256 key
  final String nonce;    // Base64-encoded 96-bit nonce
  final String mac;      // Base64-encoded 128-bit MAC tag
  final String fileHash; // SHA-256 hex of encrypted blob
  final int durationMs;  // Clip duration in milliseconds
  final List<int> waveform; // Normalized amplitude values (0 - 100)
  final int? sentAt;     // Timestamp in millisecondsSinceEpoch
  final String? localPath; // Optional local unencrypted path for sender instant playback

  VoiceNotePayload({
    this.url = '',
    this.key = '',
    this.nonce = '',
    this.mac = '',
    this.fileHash = '',
    required this.durationMs,
    required this.waveform,
    this.sentAt,
    this.localPath,
  });

  Map<String, dynamic> toJson() => {
    'type': 'voice',
    'url': url,
    'key': key,
    'nonce': nonce,
    'mac': mac,
    'fileHash': fileHash,
    'durationMs': durationMs,
    'waveform': waveform,
    if (sentAt != null) 'sentAt': sentAt,
    if (localPath != null && localPath!.isNotEmpty) 'localPath': localPath,
  };

  Map<String, dynamic> toNetworkJson() => {
    'type': 'voice',
    'url': url,
    'key': key,
    'nonce': nonce,
    'mac': mac,
    'fileHash': fileHash,
    'durationMs': durationMs,
    'waveform': waveform,
    if (sentAt != null) 'sentAt': sentAt,
  };

  String serialize() => jsonEncode(toJson());

  String serializeForNetwork() => jsonEncode(toNetworkJson());

  static bool isVoiceNote(String text) {
    final trimmed = text.trim();
    return trimmed.startsWith('{') && trimmed.contains('"type":"voice"');
  }

  factory VoiceNotePayload.fromJson(Map<String, dynamic> json) {
    return VoiceNotePayload(
      url: json['url'] as String? ?? '',
      key: json['key'] as String? ?? '',
      nonce: json['nonce'] as String? ?? '',
      mac: json['mac'] as String? ?? '',
      fileHash: json['fileHash'] as String? ?? '',
      durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
      waveform: (json['waveform'] as List<dynamic>?)
          ?.map((e) => (e as num).toInt())
          .toList() ?? [],
      sentAt: (json['sentAt'] as num?)?.toInt(),
      localPath: json['localPath'] as String?,
    );
  }

  static VoiceNotePayload? tryParse(String text) {
    try {
      if (!isVoiceNote(text)) return null;
      final map = jsonDecode(text) as Map<String, dynamic>;
      return VoiceNotePayload.fromJson(map);
    } catch (_) {
      return null;
    }
  }
}

/// Service managing recording, local AES-GCM encryption, Blossom server upload,
/// and recipient download, verification, and local decryption.
class VoiceNoteService {
  VoiceNoteService._internal();
  static final VoiceNoteService _instance = VoiceNoteService._internal();
  factory VoiceNoteService() => _instance;

  static String? cachedTempDirPath;

  final AudioRecorder _audioRecorder = AudioRecorder();
  final AesGcm _aesGcm = AesGcm.with256bits();

  bool _isRecording = false;
  bool get isRecording => _isRecording;

  DateTime? _recordingStartTime;
  StreamSubscription<Amplitude>? _amplitudeSub;
  final List<int> _recordedWaveform = [];
  String? _currentRecordingPath;
  final StreamController<int> _amplitudeController = StreamController<int>.broadcast();
  Stream<int> get onLiveAmplitude => _amplitudeController.stream;

  final List<String> _blossomServers = [
    'https://blossom.primal.net/upload',
    'https://cdn.satellite.earth/upload',
    'https://nostr.download/upload',
  ];

  /// Starts recording audio and sampling amplitude values every 100ms
  Future<bool> startRecording() async {
    if (_isRecording) return true;

    final hasPermission = await _audioRecorder.hasPermission();
    if (!hasPermission) return false;

    final tempDir = await getTemporaryDirectory();
    cachedTempDirPath = p.normalize(tempDir.path);
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    _currentRecordingPath = p.normalize(p.join(tempDir.path, 'vn_rec_$timestamp.m4a'));
    _recordedWaveform.clear();

    try {
      await _audioRecorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 128000,
          sampleRate: 44100,
          numChannels: 1,
        ),
        path: _currentRecordingPath!,
      );
    } catch (e) {
      print('DEBUG: AAC recording start failed: $e, falling back to WAV');
      try {
        _currentRecordingPath = p.normalize(p.join(tempDir.path, 'vn_rec_$timestamp.wav'));
        await _audioRecorder.start(
          const RecordConfig(
            encoder: AudioEncoder.wav,
            sampleRate: 44100,
            numChannels: 1,
          ),
          path: _currentRecordingPath!,
        );
      } catch (err) {
        print('DEBUG: Fallback WAV recording failed: $err');
        return false;
      }
    }

    // Record start time only AFTER hardware encoder is actively capturing audio
    _recordingStartTime = DateTime.now();
    _isRecording = true;

    // Sample amplitude every 100ms to construct the waveform array
    _amplitudeSub = _audioRecorder
        .onAmplitudeChanged(const Duration(milliseconds: 100))
        .listen((amp) {
      // Current amplitude in dBFS: -50 dBFS (silence) to 0 dBFS (loud)
      final db = amp.current.clamp(-50.0, 0.0);
      final normalized = (((db + 50.0) / 50.0) * 100).round().clamp(5, 100);
      _recordedWaveform.add(normalized);
      if (!_amplitudeController.isClosed) {
        _amplitudeController.add(normalized);
      }
    });

    return true;
  }

  /// Cancels recording and deletes the temporary file
  Future<void> cancelRecording() async {
    if (!_isRecording) return;
    _isRecording = false;
    _recordingStartTime = null;
    await _amplitudeSub?.cancel();
    _amplitudeSub = null;

    try {
      final path = await _audioRecorder.stop();
      if (path != null) {
        final file = File(path);
        if (await file.exists()) {
          await file.delete();
        }
      }
    } catch (_) {}

    _recordedWaveform.clear();
    _currentRecordingPath = null;
  }

  /// Stops recording and returns local file path, duration, and downsampled waveform
  Future<Map<String, dynamic>?> stopRecording({Duration? userObservedDuration}) async {
    if (!_isRecording) return null;
    _isRecording = false;
    final stopTime = DateTime.now();
    await _amplitudeSub?.cancel();
    _amplitudeSub = null;

    // 1. Calculate elapsed duration from active recording start to the instant stop was requested
    int elapsedMs = _recordingStartTime != null
        ? stopTime.difference(_recordingStartTime!).inMilliseconds
        : (userObservedDuration?.inMilliseconds ?? 1000);
    _recordingStartTime = null;

    // Synchronize duration with what user observed on recording UI to prevent 1s under-reporting
    if (userObservedDuration != null && userObservedDuration.inMilliseconds > elapsedMs) {
      elapsedMs = userObservedDuration.inMilliseconds;
    }

    final path = await _audioRecorder.stop();
    _currentRecordingPath = null;
    if (path == null) return null;

    int finalDurationMs = elapsedMs;
    try {
      final file = File(path);
      if (file.existsSync()) {
        final bytes = file.readAsBytesSync();
        final containerDur = parseAudioDurationMs(bytes);
        if (containerDur != null && containerDur > 200) {
          finalDurationMs = containerDur;
        }
      }
    } catch (_) {}

    // Downsample waveform to ~30-50 bars max for clean visual display and small JSON payload
    final compactWaveform = _normalizeWaveform(_recordedWaveform, targetLength: 36);

    return {
      'path': path,
      'durationMs': finalDurationMs,
      'waveform': compactWaveform,
    };
  }

  /// Parses container duration in milliseconds from audio file bytes without opening any audio player
  static int? parseAudioDurationMs(List<int> bytes) {
    // 1. Parse MP4 / M4A mvhd box
    for (int i = 0; i <= bytes.length - 24; i++) {
      if (bytes[i] == 0x6D && bytes[i + 1] == 0x76 && bytes[i + 2] == 0x68 && bytes[i + 3] == 0x64) {
        final version = bytes[i + 4];
        if (version == 0 && i + 24 <= bytes.length) {
          final timescale = (bytes[i + 16] << 24) | (bytes[i + 17] << 16) | (bytes[i + 18] << 8) | bytes[i + 19];
          final durationUnits = (bytes[i + 20] << 24) | (bytes[i + 21] << 16) | (bytes[i + 22] << 8) | bytes[i + 23];
          if (timescale > 0 && durationUnits > 0) {
            return ((durationUnits / timescale) * 1000).round();
          }
        } else if (version == 1 && i + 36 <= bytes.length) {
          final timescale = (bytes[i + 24] << 24) | (bytes[i + 25] << 16) | (bytes[i + 26] << 8) | bytes[i + 27];
          final durationUnits = (bytes[i + 32] << 24) | (bytes[i + 33] << 16) | (bytes[i + 34] << 8) | bytes[i + 35];
          if (timescale > 0 && durationUnits > 0) {
            return ((durationUnits / timescale) * 1000).round();
          }
        }
        break;
      }
    }
    // 2. Parse standard WAV header (RIFF...WAVE)
    if (bytes.length > 44 && bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46) {
      final byteRate = bytes[28] | (bytes[29] << 8) | (bytes[30] << 16) | (bytes[31] << 24);
      final dataSize = bytes[40] | (bytes[41] << 8) | (bytes[42] << 16) | (bytes[43] << 24);
      if (byteRate > 0 && dataSize > 0) {
        return ((dataSize / byteRate) * 1000).round();
      }
    }
    return null;
  }

  /// Normalizes and downsamples raw amplitude measurements to a fixed count (e.g. 36 bars)
  List<int> _normalizeWaveform(List<int> raw, {int targetLength = 36}) {
    if (raw.isEmpty) {
      return List.filled(targetLength, 20);
    }
    if (raw.length <= targetLength) {
      return List<int>.from(raw);
    }

    final result = <int>[];
    final chunkSize = raw.length / targetLength;

    for (int i = 0; i < targetLength; i++) {
      final start = (i * chunkSize).floor();
      final end = mathMin(((i + 1) * chunkSize).ceil(), raw.length);
      int maxVal = 5;
      for (int j = start; j < end; j++) {
        if (raw[j] > maxVal) maxVal = raw[j];
      }
      result.add(maxVal);
    }

    return result;
  }

  int mathMin(int a, int b) => a < b ? a : b;

  /// Step 1: Locally encrypts audio file with AES-256-GCM in ~3ms,
  /// generates deterministic Blossom URL, caches sender audio, and prepares VoiceNotePayload
  /// ready for IMMEDIATE transmission to recipient over Signal Double Ratchet.
  Future<({VoiceNotePayload payload, List<int> encryptedBytes})?> prepareAndEncryptVoiceNote({
    required String localAudioPath,
    required int durationMs,
    required List<int> waveform,
    int? sentAt,
  }) async {
    final audioFile = File(localAudioPath);
    if (!await audioFile.exists()) return null;

    final rawBytes = await audioFile.readAsBytes();

    // Check exact container duration from headers to guarantee precise timing
    final containerDuration = parseAudioDurationMs(rawBytes);
    if (containerDuration != null && containerDuration > 200) {
      durationMs = containerDuration;
    }

    // 1. Generate one-time 256-bit AES key and 96-bit nonce
    final secretKey = await _aesGcm.newSecretKey();
    final secretKeyBytes = await secretKey.extractBytes();
    final nonce = _aesGcm.newNonce();

    // 2. Encrypt locally (Lock)
    final secretBox = await _aesGcm.encrypt(
      rawBytes,
      secretKey: secretKey,
      nonce: nonce,
    );

    final encryptedBytes = secretBox.cipherText;
    final fileHashHex = crypto.sha256.convert(encryptedBytes).toString();

    // Canonical BUD-01 Blossom content URL
    final primaryUrl = 'https://blossom.primal.net/$fileHashHex';

    // Copy audio file into decrypted local cache so the sender can play instantly
    String localPlaybackPath = localAudioPath;
    try {
      final tempDir = await getTemporaryDirectory();
      cachedTempDirPath = p.normalize(tempDir.path);
      final ext = p.extension(localAudioPath).isNotEmpty ? p.extension(localAudioPath) : '.m4a';
      final senderCachedPath = p.normalize(p.join(tempDir.path, 'vn_dec_$fileHashHex$ext'));
      final cachedFile = File(senderCachedPath);
      if (!await cachedFile.exists()) {
        await audioFile.copy(senderCachedPath);
      }
      if (await cachedFile.exists()) {
        localPlaybackPath = senderCachedPath;
      }
    } catch (_) {}

    final payload = VoiceNotePayload(
      url: primaryUrl,
      key: base64Encode(secretKeyBytes),
      nonce: base64Encode(nonce),
      mac: base64Encode(secretBox.mac.bytes),
      fileHash: fileHashHex,
      durationMs: durationMs,
      waveform: waveform,
      sentAt: sentAt,
      localPath: localPlaybackPath,
    );

    return (payload: payload, encryptedBytes: encryptedBytes);
  }

  /// Step 2: Uploads encrypted ciphertext bytes to Blossom server pool in background
  Future<String?> uploadEncryptedBytes(List<int> encryptedBytes, String fileHashHex) async {
    String? uploadUrl;

    for (final serverUrl in _blossomServers) {
      try {
        final authHeader = NostrRelayService().createBlossomAuthHeader(
          sha256Hex: fileHashHex,
          action: 'upload',
        );

        final response = await http.put(
          Uri.parse(serverUrl),
          headers: {
            'Content-Type': 'application/octet-stream',
            if (authHeader != null) 'Authorization': authHeader,
          },
          body: encryptedBytes,
        ).timeout(const Duration(seconds: 4));

        if (response.statusCode == 200 || response.statusCode == 201) {
          try {
            final jsonResp = jsonDecode(response.body) as Map<String, dynamic>;
            uploadUrl = jsonResp['url'] as String?;
          } catch (_) {
            final uri = Uri.parse(serverUrl);
            uploadUrl = '${uri.scheme}://${uri.host}/$fileHashHex';
          }
          if (uploadUrl != null && uploadUrl.isNotEmpty) {
            break;
          }
        }
      } catch (e) {
        print('Upload attempt to $serverUrl failed: $e');
      }
    }

    return uploadUrl;
  }

  /// Convenience wrapper performing both local encryption and background upload
  Future<VoiceNotePayload?> encryptAndUploadVoiceNote({
    required String localAudioPath,
    required int durationMs,
    required List<int> waveform,
    int? sentAt,
  }) async {
    final prep = await prepareAndEncryptVoiceNote(
      localAudioPath: localAudioPath,
      durationMs: durationMs,
      waveform: waveform,
      sentAt: sentAt,
    );
    if (prep == null) return null;

    final uploadUrl = await uploadEncryptedBytes(prep.encryptedBytes, prep.payload.fileHash);
    if (uploadUrl == null) return null;
    return prep.payload;
  }

  /// Downloads encrypted blob from Blossom, verifies SHA-256, and decrypts locally.
  /// Supports polling retries in case the sender is in the middle of uploading right now.
  Future<String?> downloadAndDecryptVoiceNote(VoiceNotePayload payload) async {
    // 1. If local unencrypted file is available on this device, return immediately
    if (payload.localPath != null && payload.localPath!.isNotEmpty) {
      final localFile = File(payload.localPath!);
      if (await localFile.exists()) {
        return payload.localPath;
      }
    }

    final tempDir = await getTemporaryDirectory();
    cachedTempDirPath = p.normalize(tempDir.path);

    // Check if decrypted file is already cached as .m4a or .wav
    if (payload.fileHash.isNotEmpty) {
      final cachedM4a = p.normalize(p.join(tempDir.path, 'vn_dec_${payload.fileHash}.m4a'));
      if (await File(cachedM4a).exists() && (await File(cachedM4a).length()) > 0) {
        return cachedM4a;
      }
      final cachedWav = p.normalize(p.join(tempDir.path, 'vn_dec_${payload.fileHash}.wav'));
      if (await File(cachedWav).exists() && (await File(cachedWav).length()) > 0) {
        return cachedWav;
      }
    }

    if (payload.url.isEmpty || payload.fileHash.isEmpty) {
      return null;
    }

    try {
      // 1. Download encrypted blob (with polling retry if sender upload is in progress)
      List<int>? encryptedBytes;
      final urlsToTry = [
        payload.url,
        if (!payload.url.contains('blossom.primal.net'))
          'https://blossom.primal.net/${payload.fileHash}',
        if (!payload.url.contains('nostr.download'))
          'https://nostr.download/${payload.fileHash}',
      ];

      for (int attempt = 0; attempt < 5; attempt++) {
        for (final targetUrl in urlsToTry) {
          try {
            final response = await http.get(Uri.parse(targetUrl)).timeout(
              const Duration(seconds: 4),
            );
            if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
              encryptedBytes = response.bodyBytes;
              break;
            }
          } catch (_) {}
        }
        if (encryptedBytes != null) break;

        // If sender is currently uploading to Blossom, wait briefly and retry
        await Future.delayed(const Duration(milliseconds: 750));
      }

      if (encryptedBytes == null) {
        print('Failed to download voice note after retries: ${payload.url}');
        return null;
      }

      // 2. Verify integrity
      final actualHash = crypto.sha256.convert(encryptedBytes).toString();
      if (actualHash.toLowerCase() != payload.fileHash.toLowerCase()) {
        print('SHA-256 hash mismatch on voice note blob! Expected: ${payload.fileHash}, got: $actualHash');
        return null;
      }

      // 3. Decrypt with AES-256-GCM
      final secretBox = SecretBox(
        encryptedBytes,
        nonce: base64Decode(payload.nonce),
        mac: Mac(base64Decode(payload.mac)),
      );

      final decryptedBytes = await _aesGcm.decrypt(
        secretBox,
        secretKey: SecretKey(base64Decode(payload.key)),
      );

      // 4. Determine container format (RIFF for WAV, otherwise M4A) to ensure correct playback on all platforms
      final isWav = decryptedBytes.length > 4 &&
          decryptedBytes[0] == 0x52 &&
          decryptedBytes[1] == 0x49 &&
          decryptedBytes[2] == 0x46 &&
          decryptedBytes[3] == 0x46;
      final ext = isWav ? '.wav' : '.m4a';
      final outPath = p.normalize(p.join(tempDir.path, 'vn_dec_${payload.fileHash}$ext'));
      final outFile = File(outPath);
      await outFile.writeAsBytes(decryptedBytes, flush: true);
      return outPath;
    } catch (e) {
      print('Error downloading/decrypting voice note: $e');
      return null;
    }
  }
}
