import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:image/image.dart' as img;

import '../models/media_payload.dart';
import 'storage_router.dart';
import 'media_cache_manager.dart';
import 'account_session.dart';

class MediaService {
  MediaService._internal();
  static final MediaService _instance = MediaService._internal();
  factory MediaService() => _instance;

  final AesGcm _aesGcm = AesGcm.with256bits();
  final StorageRouter _router = StorageRouter();
  final MediaCacheManager _cacheManager = MediaCacheManager();

  /// Infers mediaType ('image', 'video', 'audio', 'document') from MIME type or file extension
  String inferMediaType(String filePath, [String? mimeType]) {
    final mime = mimeType ?? lookupMimeType(filePath) ?? '';
    if (mime.startsWith('image/')) return 'image';
    if (mime.startsWith('video/')) return 'video';
    if (mime.startsWith('audio/')) return 'audio';

    final ext = p.extension(filePath).toLowerCase();
    if (['.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp'].contains(ext)) return 'image';
    if (['.mp4', '.mkv', '.mov', '.avi', '.webm'].contains(ext)) return 'video';
    if (['.mp3', '.m4a', '.wav', '.aac', '.ogg', '.flac'].contains(ext)) return 'audio';
    return 'document';
  }

  /// Generates a tiny, compressed, low-res preview thumbnail (~1KB Base64) for instant rendering
  String? generateMicroThumbnail(String imagePath) {
    try {
      final file = File(imagePath);
      if (!file.existsSync()) return null;
      final bytes = file.readAsBytesSync();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return null;

      // Resize to max 32x32 for ultra-lightweight instant blurry placeholder preview
      final thumbnail = img.copyResize(
        decoded,
        width: decoded.width > decoded.height ? 32 : null,
        height: decoded.height >= decoded.width ? 32 : null,
      );

      final jpgBytes = img.encodeJpg(thumbnail, quality: 35);
      return base64Encode(jpgBytes);
    } catch (_) {
      return null;
    }
  }

  /// Prepares and encrypts any media file using AES-256-GCM in constant memory.
  /// Generates a one-time 256-bit AES key, 96-bit nonce, 128-bit MAC tag,
  /// computes SHA-256 hash of ciphertext, creates MediaPayload, and caches local plaintext.
  Future<({MediaPayload payload, List<int> encryptedBytes})?> prepareAndEncryptMedia({
    required String localFilePath,
    String? customFileName,
    String? mediaType,
    int? sentAt,
    bool keepSource = true,
    String? caption,
  }) async {
    final sourceFile = File(localFilePath);
    if (!await sourceFile.exists()) return null;

    final fileName = customFileName ?? p.basename(localFilePath);
    final ext = p.extension(localFilePath);
    final mimeType = lookupMimeType(localFilePath) ?? 'application/octet-stream';
    final inferredType = mediaType ?? inferMediaType(localFilePath, mimeType);
    final fileSize = await sourceFile.length();

    // 1. Generate one-time 256-bit AES key and 96-bit nonce
    final secretKey = await _aesGcm.newSecretKey();
    final secretKeyBytes = await secretKey.extractBytes();
    final nonce = _aesGcm.newNonce();

    // 2. Encrypt locally with AES-256-GCM
    final rawBytes = await sourceFile.readAsBytes();
    final secretBox = await _aesGcm.encrypt(
      rawBytes,
      secretKey: secretKey,
      nonce: nonce,
    );

    final encryptedBytes = secretBox.cipherText;
    final fileHashHex = crypto.sha256.convert(encryptedBytes).toString();

    // 3. Register in local cache for immediate sender instant playback/viewing
    String effectivePath = localFilePath;
    try {
      final cachedPath = await _cacheManager.getCacheFilePathForHash(fileHashHex, ext: ext);
      final cacheFile = File(cachedPath);
      if (!await cacheFile.exists()) {
        if (keepSource) {
          await sourceFile.copy(cachedPath);
        } else {
          await sourceFile.rename(cachedPath);
        }
      }
      if (await cacheFile.exists()) {
        effectivePath = cachedPath;
        await _cacheManager.registerFile(fileHash: fileHashHex, filePath: cachedPath);
      }
    } catch (e) {
      print('[MEDIA] Error caching local plaintext file: $e');
    }
    await _cacheManager.registerFile(fileHash: fileHashHex, filePath: effectivePath);

    // 4. Generate instant micro-thumbnail for images
    String? thumbnail;
    int? width;
    int? height;
    if (inferredType == 'image') {
      thumbnail = generateMicroThumbnail(effectivePath);
      try {
        final decoded = img.decodeImage(rawBytes);
        if (decoded != null) {
          width = decoded.width;
          height = decoded.height;
        }
      } catch (_) {}
    }

    final primaryUrl = 'https://blossom.primal.net/$fileHashHex';

    final payload = MediaPayload(
      type: 'media',
      mediaType: inferredType,
      url: primaryUrl,
      key: base64Encode(secretKeyBytes),
      nonce: base64Encode(nonce),
      mac: base64Encode(secretBox.mac.bytes),
      fileHash: fileHashHex,
      fileName: fileName,
      fileSize: fileSize,
      mimeType: mimeType,
      thumbnail: thumbnail,
      width: width,
      height: height,
      sentAt: sentAt ?? DateTime.now().millisecondsSinceEpoch,
      localPath: effectivePath,
      caption: caption,
    );

    return (payload: payload, encryptedBytes: encryptedBytes);
  }

  /// Uploads encrypted ciphertext bytes to the fastest Blossom server via StorageRouter
  Future<String?> uploadEncryptedMedia(
    List<int> encryptedBytes,
    String fileHashHex, {
    int? sessionGen,
  }) async {
    return await _router.uploadEncryptedBlob(
      encryptedBytes,
      fileHashHex,
      sessionGen: sessionGen,
    );
  }

  /// Downloads encrypted blob, verifies SHA-256 digest, and decrypts with AES-256-GCM
  Future<String?> downloadAndDecryptMedia(
    MediaPayload payload, {
    int? sessionGen,
  }) async {
    // 1. Check if already in cache
    if (payload.fileHash.isNotEmpty) {
      final cached = _cacheManager.getCachedFilePath(payload.fileHash);
      if (cached != null && File(cached).existsSync()) {
        await _cacheManager.touch(payload.fileHash);
        return cached;
      }
      final asyncCached = await _cacheManager.findCachedFilePath(payload.fileHash);
      if (asyncCached != null && File(asyncCached).existsSync()) {
        await _cacheManager.touch(payload.fileHash);
        return asyncCached;
      }
    }

    // 2. Check if local path is still valid
    if (payload.localPath != null && payload.localPath!.isNotEmpty) {
      final localFile = File(payload.localPath!);
      if (await localFile.exists() && (await localFile.length()) > 0) {
        await _cacheManager.registerFile(
          fileHash: payload.fileHash,
          filePath: payload.localPath!,
        );
        return payload.localPath;
      }
    }

    if (payload.url.isEmpty || payload.fileHash.isEmpty) {
      return null;
    }

    try {
      // 3. Download encrypted ciphertext from fastest Blossom mirror
      final encryptedBytes = await _router.downloadEncryptedBlob(
        payload.url,
        payload.fileHash,
        sessionGen: sessionGen,
      );

      if (encryptedBytes == null || encryptedBytes.isEmpty) {
        print('[MEDIA] Failed to download media blob for ${payload.fileName}');
        return null;
      }

      if (sessionGen != null && !AccountSession.isGenerationValid(sessionGen)) {
        return null;
      }

      // 4. Cryptographic integrity check: verify SHA-256 against expected fileHash
      final actualHash = crypto.sha256.convert(encryptedBytes).toString();
      if (actualHash.toLowerCase() != payload.fileHash.toLowerCase()) {
        print('[MEDIA] SHA-256 hash mismatch! Expected: ${payload.fileHash}, got: $actualHash');
        return null;
      }

      // 5. Decrypt with AES-256-GCM
      final secretBox = SecretBox(
        encryptedBytes,
        nonce: base64Decode(payload.nonce),
        mac: Mac(base64Decode(payload.mac)),
      );

      final decryptedBytes = await _aesGcm.decrypt(
        secretBox,
        secretKey: SecretKey(base64Decode(payload.key)),
      );

      if (sessionGen != null && !AccountSession.isGenerationValid(sessionGen)) {
        return null;
      }

      // 6. Write decrypted plaintext to cache
      final ext = p.extension(payload.fileName).isNotEmpty
          ? p.extension(payload.fileName)
          : (payload.isImage ? '.jpg' : (payload.isVideo ? '.mp4' : ''));
      final targetPath = await _cacheManager.getCacheFilePathForHash(payload.fileHash, ext: ext);
      final outFile = File(targetPath);
      await outFile.writeAsBytes(decryptedBytes, flush: true);

      await _cacheManager.registerFile(
        fileHash: payload.fileHash,
        filePath: targetPath,
      );

      return targetPath;
    } catch (e) {
      print('[MEDIA] Error downloading/decrypting media: $e');
      return null;
    }
  }
}
