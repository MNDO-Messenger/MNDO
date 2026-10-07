import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:path/path.dart' as p;
import 'nostr_relay_service.dart';
import 'account_session.dart';
import 'voice_note_cache_manager.dart';
export 'voice_note_cache_manager.dart';

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
    if (!trimmed.startsWith('{')) return false;
    return trimmed.contains('"type":"voice"') ||
        trimmed.contains('"type": "voice"') ||
        trimmed.contains(r'\"type\":\"voice\"') ||
        trimmed.contains(r'\"type\": \"voice\"') ||
        trimmed.contains('"type":"voice_note"') ||
        trimmed.contains('"type": "voice_note"');
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
      final map = jsonDecode(text);
      if (map is! Map<String, dynamic>) return null;

      // Handle envelope wrapping: if this is a MndoMessageEnvelope containing a voice note
      if (map['type'] == 'voice_note' && map['body'] is Map) {
        final body = map['body'] as Map;
        final innerText = body['text'] ?? body['payload'];
        if (innerText is String) {
          final innerParsed = tryParse(innerText);
          if (innerParsed != null) return innerParsed;
        } else if (innerText is Map) {
          final innerParsed = VoiceNotePayload.fromJson(Map<String, dynamic>.from(innerText));
          if (innerParsed.url.isNotEmpty) return innerParsed;
        }
      }

      final payload = VoiceNotePayload.fromJson(map);
      if (payload.url.isEmpty && (payload.localPath == null || payload.localPath!.isEmpty) && payload.fileHash.isEmpty) {
        return null;
      }
      return payload;
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

  AudioRecorder? _audioRecorder;
  AudioRecorder get _recorder => _audioRecorder ??= AudioRecorder();
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

    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) return false;

    final tempDir = await getTemporaryDirectory();
    cachedTempDirPath = p.normalize(tempDir.path);
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    _currentRecordingPath = p.normalize(p.join(tempDir.path, 'vn_rec_$timestamp.m4a'));
    _recordedWaveform.clear();

    try {
      await _recorder.start(
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
        await _recorder.start(
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
    _amplitudeSub = _recorder
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
      final path = await _audioRecorder?.stop();
      if (path != null) {
        await deletePlaintextFile(path);
      }
    } catch (_) {}

    if (_currentRecordingPath != null) {
      await deletePlaintextFile(_currentRecordingPath!);
    }

    _recordedWaveform.clear();
    _currentRecordingPath = null;
  }

  /// Discards and deletes an abandoned/cancelled recording path
  Future<void> discardRecording(String path) async {
    await deletePlaintextFile(path);
    await VoiceNoteCacheManager().deleteFile(path);
  }

  @visibleForTesting
  static bool failNextDeletePlaintextFile = false;

  /// Central helper for deleting sensitive temporary plaintext audio files.
  /// Returns true only if the file no longer exists after deletion.
  static Future<bool> deletePlaintextFile(String path) async {
    if (failNextDeletePlaintextFile) {
      failNextDeletePlaintextFile = false;
      return false;
    }
    try {
      final file = File(path);
      if (!await file.exists()) {
        return true;
      }
      await file.delete();
      return !(await file.exists());
    } catch (_) {
      return false;
    }
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

    final path = await _audioRecorder?.stop();
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
  /// generates deterministic Blossom URL, registers single controlled plaintext cache,
  /// immediately deletes original recording source file, and prepares VoiceNotePayload.
  /// Strict ordering: READ -> ENCRYPT -> VALIDATE -> CREATE CACHE/MOVE -> DELETE PLAINTEXT SOURCE.
  Future<({VoiceNotePayload payload, List<int> encryptedBytes})?> prepareAndEncryptVoiceNote({
    required String localAudioPath,
    required int durationMs,
    required List<int> waveform,
    int? sentAt,
    bool deleteSourceOnSuccess = true,
  }) async {
    final audioFile = File(localAudioPath);
    if (!await audioFile.exists()) return null;

    List<int> rawBytes;
    try {
      rawBytes = await audioFile.readAsBytes();
    } catch (e) {
      if (deleteSourceOnSuccess) {
        await deletePlaintextFile(localAudioPath);
      }
      return null;
    }

    // Check exact container duration from headers to guarantee precise timing
    final containerDuration = parseAudioDurationMs(rawBytes);
    if (containerDuration != null && containerDuration > 200) {
      durationMs = containerDuration;
    }

    SecretKey secretKey;
    List<int> secretKeyBytes;
    List<int> nonce;
    SecretBox secretBox;
    List<int> encryptedBytes;
    String fileHashHex;

    try {
      // 1. Generate one-time 256-bit AES key and 96-bit nonce
      secretKey = await _aesGcm.newSecretKey();
      secretKeyBytes = await secretKey.extractBytes();
      nonce = _aesGcm.newNonce();

      // 2. Encrypt locally (Lock)
      secretBox = await _aesGcm.encrypt(
        rawBytes,
        secretKey: secretKey,
        nonce: nonce,
      );

      encryptedBytes = secretBox.cipherText;
      fileHashHex = crypto.sha256.convert(encryptedBytes).toString();
    } catch (e) {
      // Clean up plaintext source on encryption failure
      if (deleteSourceOnSuccess) {
        await deletePlaintextFile(localAudioPath);
      }
      rethrow;
    }

    // Canonical BUD-01 Blossom content URL
    final primaryUrl = 'https://blossom.primal.net/$fileHashHex';

    // 3. Move/write into single controlled temporary-cache location (Fail-Closed).
    // Invariant: Do NOT keep duplicate plaintext copies (vn_rec_* + vn_dec_* eliminated).
    final ext = p.extension(localAudioPath).isNotEmpty ? p.extension(localAudioPath) : '.m4a';
    final cacheManager = VoiceNoteCacheManager();

    String? targetCachePath;
    try {
      targetCachePath = await cacheManager.getCacheFilePathForHash(fileHashHex, ext: ext);
      if (p.normalize(audioFile.path) != p.normalize(targetCachePath)) {
        final cacheFile = File(targetCachePath);
        if (!await cacheFile.exists()) {
          // Attempt atomic move / rename to cache file
          bool moved = false;
          try {
            await audioFile.rename(targetCachePath);
            moved = true;
          } catch (_) {
            // Fallback across volumes: copy then delete source
            try {
              await audioFile.copy(targetCachePath);
              moved = true;
            } catch (_) {
              moved = false;
            }
          }

          if (!moved || !await File(targetCachePath).exists() || (await File(targetCachePath).length()) == 0) {
            // Step 5/6 failure: Cache creation/move failed -> Fail closed!
            await deletePlaintextFile(targetCachePath);
            if (deleteSourceOnSuccess) {
              await deletePlaintextFile(localAudioPath);
            }
            return null;
          }
        }

        // Step 7 & 8: Delete source plaintext and verify it no longer exists
        if (deleteSourceOnSuccess) {
          final deleted = await deletePlaintextFile(localAudioPath);
          final stillExists = await audioFile.exists();
          if (!deleted || stillExists) {
            // Step 8 failure: Source plaintext could not be verified deleted -> Fail closed!
            await deletePlaintextFile(targetCachePath);
            return null;
          }
        }
      }

      // Step 9: Register cache entry in VoiceNoteCacheManager
      await cacheManager.registerFile(
        fileHash: fileHashHex,
        filePath: targetCachePath,
      );
    } catch (e) {
      // Any filesystem/cache error during transition -> Clean up and Fail closed!
      if (targetCachePath != null) {
        await deletePlaintextFile(targetCachePath);
      }
      if (deleteSourceOnSuccess) {
        await deletePlaintextFile(localAudioPath);
      }
      return null;
    }

    // Strict verification: Cache file MUST exist, source MUST NOT exist, and localPath must NEVER be localAudioPath
    if (!await File(targetCachePath).exists()) {
      if (deleteSourceOnSuccess) {
        await deletePlaintextFile(localAudioPath);
      }
      return null;
    }
    if (deleteSourceOnSuccess && await audioFile.exists()) {
      await deletePlaintextFile(targetCachePath);
      return null;
    }

    final payload = VoiceNotePayload(
      url: primaryUrl,
      key: base64Encode(secretKeyBytes),
      nonce: base64Encode(nonce),
      mac: base64Encode(secretBox.mac.bytes),
      fileHash: fileHashHex,
      durationMs: durationMs,
      waveform: waveform,
      sentAt: sentAt,
      localPath: targetCachePath,
    );

    return (payload: payload, encryptedBytes: encryptedBytes);
  }

  /// Step 2: Uploads encrypted ciphertext bytes to Blossom server pool in background
  Future<String?> uploadEncryptedBytes(
    List<int> encryptedBytes,
    String fileHashHex, {
    int? sessionGen,
  }) async {
    String? uploadUrl;

    for (final serverUrl in _blossomServers) {
      if (sessionGen != null && !AccountSession.isGenerationValid(sessionGen)) {
        print('[VOICE] Blossom upload aborted: session generation $sessionGen is stale');
        return null;
      }
      try {
        final activeGen = sessionGen ?? AccountSession.currentGeneration;
        final authHeader = NostrRelayService().createBlossomAuthHeader(
          sha256Hex: fileHashHex,
          action: 'upload',
          sessionGen: activeGen,
        );

        final response = await http.put(
          Uri.parse(serverUrl),
          headers: {
            'Content-Type': 'application/octet-stream',
            if (authHeader != null) 'Authorization': authHeader,
          },
          body: encryptedBytes,
        ).timeout(const Duration(seconds: 4));

        if (sessionGen != null && !AccountSession.isGenerationValid(sessionGen)) {
          print('[VOICE] Blossom upload response ignored: session generation $sessionGen is stale');
          return null;
        }

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
    int? sessionGen,
  }) async {
    if (sessionGen != null && !AccountSession.isGenerationValid(sessionGen)) return null;
    final prep = await prepareAndEncryptVoiceNote(
      localAudioPath: localAudioPath,
      durationMs: durationMs,
      waveform: waveform,
      sentAt: sentAt,
    );
    if (prep == null) return null;
    if (sessionGen != null && !AccountSession.isGenerationValid(sessionGen)) return null;

    final uploadUrl = await uploadEncryptedBytes(
      prep.encryptedBytes,
      prep.payload.fileHash,
      sessionGen: sessionGen,
    );
    if (uploadUrl == null) {
      await VoiceNoteCacheManager().deleteForHash(prep.payload.fileHash);
      return null;
    }
    return prep.payload;
  }

  /// Downloads encrypted blob from Blossom, verifies SHA-256, and decrypts locally.
  /// Decrypted plaintext is managed exclusively by VoiceNoteCacheManager with bounded TTL.
  /// Supports polling retries in case the sender is in the middle of uploading right now.
  Future<String?> downloadAndDecryptVoiceNote(VoiceNotePayload payload, {int? sessionGen}) async {
    final cacheManager = VoiceNoteCacheManager();

    // 1. If already cached in cache manager, touch and return immediately
    if (payload.fileHash.isNotEmpty) {
      final cached = cacheManager.getCachedFilePath(payload.fileHash);
      if (cached != null) {
        await cacheManager.touch(payload.fileHash);
        return cached;
      }
    }

    // 2. If local unencrypted file is available on this device, register and return
    if (payload.localPath != null && payload.localPath!.isNotEmpty) {
      final localFile = File(payload.localPath!);
      if (await localFile.exists() && (await localFile.length()) > 0) {
        if (payload.fileHash.isNotEmpty) {
          await cacheManager.registerFile(
            fileHash: payload.fileHash,
            filePath: payload.localPath!,
          );
        }
        return payload.localPath;
      }
    }

    // Check on-disk cache path candidates for fileHash
    if (payload.fileHash.isNotEmpty) {
      for (final ext in ['.m4a', '.wav']) {
        final candidate = await cacheManager.getCacheFilePathForHash(payload.fileHash, ext: ext);
        if (await File(candidate).exists() && (await File(candidate).length()) > 0) {
          await cacheManager.registerFile(
            fileHash: payload.fileHash,
            filePath: candidate,
          );
          return candidate;
        }
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
        if (sessionGen != null && !AccountSession.isGenerationValid(sessionGen)) return null;
        for (final targetUrl in urlsToTry) {
          try {
            final response = await http.get(Uri.parse(targetUrl)).timeout(
              const Duration(seconds: 4),
            );
            if (sessionGen != null && !AccountSession.isGenerationValid(sessionGen)) return null;
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

      if (sessionGen != null && !AccountSession.isGenerationValid(sessionGen)) return null;

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

      if (sessionGen != null && !AccountSession.isGenerationValid(sessionGen)) return null;

      // 4. Determine container format (RIFF for WAV, otherwise M4A) to ensure correct playback on all platforms
      final isWav = decryptedBytes.length > 4 &&
          decryptedBytes[0] == 0x52 &&
          decryptedBytes[1] == 0x49 &&
          decryptedBytes[2] == 0x46 &&
          decryptedBytes[3] == 0x46;
      final ext = isWav ? '.wav' : '.m4a';
      final outPath = await cacheManager.getCacheFilePathForHash(payload.fileHash, ext: ext);
      final outFile = File(outPath);
      await outFile.writeAsBytes(decryptedBytes, flush: true);

      // Register with cache manager for bounded TTL management
      await cacheManager.registerFile(
        fileHash: payload.fileHash,
        filePath: outPath,
      );

      return outPath;
    } catch (e) {
      print('Error downloading/decrypting voice note: $e');
      return null;
    }
  }
}
