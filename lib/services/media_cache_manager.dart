import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'cache_cleanup_result.dart';

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

  @visibleForTesting
  bool failNextCleanupAll = false;

  /// Purges cached media older than TTL or when total size exceeds budget (P1.1).
  /// Recursively walks the entire media directory and all nested subdirectories.
  Future<void> cleanupExpired({Duration? ttl, int? maxBytes}) async {
    final effectiveTtl = ttl ?? defaultTtl;
    final effectiveMaxBytes = maxBytes ?? maxCacheSizeBytes;
    final cutoff = DateTime.now().subtract(effectiveTtl);

    try {
      final baseDir = await _getMediaDirectory();
      if (!await baseDir.exists()) return;

      final remainingFiles = <File>[];
      int totalSize = 0;

      // Truly recursive traversal of baseDir and all nested subdirectories (P1.1)
      final entities = await baseDir.list(recursive: true).toList();
      for (final entity in entities) {
        if (entity is File) {
          try {
            final stat = await entity.stat();
            if (stat.modified.isBefore(cutoff)) {
              await entity.delete();
              _memoryCache.removeWhere((_, path) => path == entity.path);
            } else {
              final length = await entity.length();
              totalSize += length;
              remainingFiles.add(entity);
            }
          } catch (_) {}
        }
      }

      // Check size budget across all managed media
      if (totalSize > effectiveMaxBytes) {
        final fileStats = <File, DateTime>{};
        for (final f in remainingFiles) {
          try {
            fileStats[f] = (await f.stat()).modified;
          } catch (_) {
            fileStats[f] = DateTime.now();
          }
        }

        // Sort oldest first and purge until under 70% budget
        remainingFiles.sort((a, b) => (fileStats[a] ?? DateTime.now()).compareTo(fileStats[b] ?? DateTime.now()));
        final targetBudget = (effectiveMaxBytes * 0.7).toInt();

        for (final f in remainingFiles) {
          if (totalSize <= targetBudget) break;
          try {
            if (await f.exists()) {
              final len = await f.length();
              await f.delete();
              totalSize -= len;
              _memoryCache.removeWhere((_, path) => path == f.path);
            }
          } catch (_) {}
        }
      }
    } catch (e) {
      debugPrint('[MEDIA_CACHE] Cleanup error: $e');
    }
  }

  /// Purges all cached media files and returns an explicit cleanup result (P1.2).
  Future<CacheCleanupResult> cleanupAll() async {
    _memoryCache.clear();
    int deleted = 0;
    int failed = 0;
    final failedPaths = <String>[];

    if (failNextCleanupAll) {
      failNextCleanupAll = false;
      return const CacheCleanupResult(
        deletedCount: 0,
        failedCount: 1,
        failedPaths: ['injected_media_cleanup_failure'],
      );
    }

    try {
      final baseDir = await _getMediaDirectory();
      if (await baseDir.exists()) {
        final subdirs = ['images', 'videos', 'audio', 'documents'];
        for (final sub in subdirs) {
          final sDir = Directory(p.join(baseDir.path, sub));
          if (await sDir.exists()) {
            try {
              final entities = await sDir.list().toList();
              for (final entity in entities) {
                if (entity is File) {
                  try {
                    await entity.delete();
                    deleted++;
                  } catch (e) {
                    failed++;
                    failedPaths.add(entity.path);
                  }
                }
              }
              try {
                await sDir.delete();
              } catch (_) {}
            } catch (e) {
              failed++;
              failedPaths.add(sDir.path);
            }
          }
        }

        final topEntities = await baseDir.list().toList();
        for (final entity in topEntities) {
          if (entity is File) {
            try {
              await entity.delete();
              deleted++;
            } catch (e) {
              failed++;
              failedPaths.add(entity.path);
            }
          }
        }

        try {
          await baseDir.delete(recursive: true);
        } catch (_) {
          if (await baseDir.exists()) {
            final remaining = await baseDir.list().toList();
            if (remaining.isNotEmpty) {
              failed += remaining.length;
              failedPaths.addAll(remaining.map((e) => e.path));
            }
          }
        }
      }

      // Also clean up legacy temporary cache if present
      try {
        final tempDir = await getTemporaryDirectory();
        final legacyDir = Directory(p.join(tempDir.path, 'mndo_media_cache'));
        if (await legacyDir.exists()) {
          try {
            await legacyDir.delete(recursive: true);
          } catch (_) {
            if (await legacyDir.exists()) {
              failed++;
              failedPaths.add(legacyDir.path);
            }
          }
        }
      } catch (e) {
        // In production (_customBaseDir == null), track failure to verify legacy temp cache location
        // Headless unit and widget tests may not mock getTemporaryDirectory platform channel
        if (_customBaseDir == null && !e.toString().contains('MissingPluginException')) {
          failed++;
          failedPaths.add('legacy_temp_dir: $e');
        }
      }
    } catch (e) {
      debugPrint('[MEDIA_CACHE] CleanupAll error: $e');
      if (_customBaseDir == null && e.toString().contains('MissingPluginException')) {
        // Platform channels not available in headless unit/widget tests
      } else {
        failed++;
        failedPaths.add('media_cache_root');
      }
    }

    return CacheCleanupResult(
      deletedCount: deleted,
      failedCount: failed,
      failedPaths: failedPaths,
    );
  }
}
