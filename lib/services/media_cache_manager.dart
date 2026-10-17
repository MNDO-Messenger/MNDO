import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

class MediaCacheManager {
  MediaCacheManager._internal();
  static final MediaCacheManager _instance = MediaCacheManager._internal();
  factory MediaCacheManager() => _instance;

  static const Duration defaultTtl = Duration(hours: 24);
  static const int maxCacheSizeBytes = 500 * 1024 * 1024; // 500 MB budget

  static String? cachedCacheDirPath;
  final Map<String, String> _memoryCache = {}; // fileHash -> filePath
  Directory? _customBaseDir;

  @visibleForTesting
  void setBaseDirForTesting(Directory dir) {
    _customBaseDir = dir;
    cachedCacheDirPath = dir.path;
  }

  @visibleForTesting
  void resetForTesting() {
    _customBaseDir = null;
    cachedCacheDirPath = null;
    _memoryCache.clear();
  }

  Future<Directory> _getMediaDirectory({String subDir = ''}) async {
    final base = _customBaseDir != null ? _customBaseDir!.path : (await getApplicationDocumentsDirectory()).path;
    final path = subDir.isNotEmpty
        ? p.join(base, 'mndo_media', subDir)
        : p.join(base, 'mndo_media');
    final mediaDir = Directory(path);
    if (!await mediaDir.exists()) {
      await mediaDir.create(recursive: true);
    }
    cachedCacheDirPath = p.join(base, 'mndo_media');
    return mediaDir;
  }

  String getMediaSubdir(String ext, {String? mediaType}) {
    final cleanExt = ext.toLowerCase();
    if (mediaType == 'image' || ['.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp'].contains(cleanExt)) {
      return 'images';
    }
    if (mediaType == 'video' || ['.mp4', '.mkv', '.mov', '.avi', '.webm'].contains(cleanExt)) {
      return 'videos';
    }
    if (mediaType == 'audio' || ['.mp3', '.m4a', '.wav', '.ogg', '.aac', '.flac'].contains(cleanExt)) {
      return 'audio';
    }
    return 'documents';
  }

  Future<String> getCacheFilePathForHash(String fileHash, {String ext = '', String? mediaType}) async {
    final cleanExt = ext.isNotEmpty && !ext.startsWith('.') ? '.$ext' : ext;
    final subDir = getMediaSubdir(cleanExt, mediaType: mediaType);
    final dir = await _getMediaDirectory(subDir: subDir);
    return p.normalize(p.join(dir.path, '$fileHash$cleanExt'));
  }

  /// Synchronous cache lookup checking in-memory cache and known disk storage directories
  String? getCachedFilePath(String fileHash) {
    if (fileHash.isEmpty) return null;
    final path = _memoryCache[fileHash];
    if (path != null && File(path).existsSync()) {
      return path;
    }

    final knownDir = cachedCacheDirPath;
    if (knownDir != null) {
      try {
        final dir = Directory(knownDir);
        if (dir.existsSync()) {
          // Check top-level and structured subdirectories (images, videos, audio, documents)
          final subdirs = ['images', 'videos', 'audio', 'documents'];
          for (final sub in subdirs) {
            final sDir = Directory(p.join(knownDir, sub));
            if (sDir.existsSync()) {
              final entities = sDir.listSync();
              for (final entity in entities) {
                if (entity is File && p.basenameWithoutExtension(entity.path) == fileHash) {
                  if (entity.existsSync() && entity.lengthSync() > 0) {
                    _memoryCache[fileHash] = entity.path;
                    return entity.path;
                  }
                }
              }
            }
          }
          final entities = dir.listSync();
          for (final entity in entities) {
            if (entity is File && p.basenameWithoutExtension(entity.path) == fileHash) {
              if (entity.existsSync() && entity.lengthSync() > 0) {
                _memoryCache[fileHash] = entity.path;
                return entity.path;
              }
            }
          }
        }
      } catch (_) {}
    }
    return null;
  }

  /// Asynchronous cache lookup ensuring directories are scanned for file
  Future<String?> findCachedFilePath(String fileHash) async {
    if (fileHash.isEmpty) return null;
    final syncHit = getCachedFilePath(fileHash);
    if (syncHit != null) return syncHit;

    try {
      final baseDir = await _getMediaDirectory();
      final subdirs = ['images', 'videos', 'audio', 'documents'];
      for (final sub in subdirs) {
        final sDir = Directory(p.join(baseDir.path, sub));
        if (await sDir.exists()) {
          final entities = sDir.listSync();
          for (final entity in entities) {
            if (entity is File && p.basenameWithoutExtension(entity.path) == fileHash) {
              if (await entity.exists() && (await entity.length()) > 0) {
                _memoryCache[fileHash] = entity.path;
                return entity.path;
              }
            }
          }
        }
      }
      final entities = baseDir.listSync();
      for (final entity in entities) {
        if (entity is File && p.basenameWithoutExtension(entity.path) == fileHash) {
          if (await entity.exists() && (await entity.length()) > 0) {
            _memoryCache[fileHash] = entity.path;
            return entity.path;
          }
        }
      }

      // Check legacy temporary cache as fallback for older sessions
      final tempDir = await getTemporaryDirectory();
      final legacyDir = Directory(p.join(tempDir.path, 'mndo_media_cache'));
      if (await legacyDir.exists()) {
        final legacyEntities = legacyDir.listSync();
        for (final entity in legacyEntities) {
          if (entity is File && p.basenameWithoutExtension(entity.path) == fileHash) {
            if (await entity.exists() && (await entity.length()) > 0) {
              _memoryCache[fileHash] = entity.path;
              return entity.path;
            }
          }
        }
      }
    } catch (_) {}
    return null;
  }

  Future<void> registerFile({required String fileHash, required String filePath}) async {
    _memoryCache[fileHash] = filePath;
    try {
      final file = File(filePath);
      if (await file.exists()) {
        await file.setLastModified(DateTime.now());
      }
    } catch (_) {}
  }

  Future<void> touch(String fileHash) async {
    final path = getCachedFilePath(fileHash);
    if (path != null) {
      try {
        final file = File(path);
        if (await file.exists()) {
          await file.setLastModified(DateTime.now());
        }
      } catch (_) {}
    }
  }

  Future<void> deleteForHash(String fileHash) async {
    final path = _memoryCache.remove(fileHash);
    if (path != null) {
      await deleteFile(path);
    }
    try {
      final baseDir = await _getMediaDirectory();
      final subdirs = ['images', 'videos', 'audio', 'documents'];
      for (final sub in subdirs) {
        final sDir = Directory(p.join(baseDir.path, sub));
        if (sDir.existsSync()) {
          final entities = sDir.listSync();
          for (final entity in entities) {
            if (entity is File && p.basenameWithoutExtension(entity.path) == fileHash) {
              try {
                entity.deleteSync();
              } catch (_) {}
            }
          }
        }
      }
      final entities = baseDir.listSync();
      for (final entity in entities) {
        if (entity is File && p.basenameWithoutExtension(entity.path) == fileHash) {
          try {
            entity.deleteSync();
          } catch (_) {}
        }
      }

      // Also clean up legacy temporary cache if present
      final tempDir = await getTemporaryDirectory();
      final legacyDir = Directory(p.join(tempDir.path, 'mndo_media_cache'));
      if (legacyDir.existsSync()) {
        final legacyEntities = legacyDir.listSync();
        for (final entity in legacyEntities) {
          if (entity is File && p.basenameWithoutExtension(entity.path) == fileHash) {
            try {
              entity.deleteSync();
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
  }

  Future<bool> deleteFile(String filePath) async {
    try {
      final file = File(filePath);
      if (await file.exists()) {
        await file.delete();
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Purges cached media older than TTL or when total size exceeds budget
  Future<void> cleanupExpired({Duration? ttl}) async {
    final effectiveTtl = ttl ?? defaultTtl;
    final cutoff = DateTime.now().subtract(effectiveTtl);

    try {
      final dir = await _getMediaDirectory();
      if (!await dir.exists()) return;

      final entities = dir.listSync();
      final files = <File>[];

      for (final entity in entities) {
        if (entity is File) {
          files.add(entity);
          try {
            final stat = entity.statSync();
            if (stat.modified.isBefore(cutoff)) {
              entity.deleteSync();
            }
          } catch (_) {}
        }
      }

      // Check size budget
      int totalSize = 0;
      for (final f in files) {
        try {
          if (f.existsSync()) totalSize += f.lengthSync();
        } catch (_) {}
      }

      if (totalSize > maxCacheSizeBytes) {
        // Sort oldest first and purge until under 70% budget
        files.sort((a, b) => a.statSync().modified.compareTo(b.statSync().modified));
        for (final f in files) {
          if (totalSize <= (maxCacheSizeBytes * 0.7)) break;
          try {
            if (f.existsSync()) {
              final len = f.lengthSync();
              f.deleteSync();
              totalSize -= len;
            }
          } catch (_) {}
        }
      }
    } catch (e) {
      debugPrint('[MEDIA_CACHE] Cleanup error: $e');
    }
  }

  /// Purges all cached media files (used on account logout)
  Future<void> cleanupAll() async {
    _memoryCache.clear();
    try {
      final dir = await _getMediaDirectory();
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (e) {
      debugPrint('[MEDIA_CACHE] CleanupAll error: $e');
    }
  }
}
