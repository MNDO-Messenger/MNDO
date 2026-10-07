import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Represents a single tracked plaintext voice cache entry.
class VoiceCacheEntry {
  final String fileHash;
  final String path;
  final DateTime createdAt;
  DateTime lastAccessedAt;
  final Duration ttl;

  VoiceCacheEntry({
    required this.fileHash,
    required this.path,
    required this.createdAt,
    required this.lastAccessedAt,
    this.ttl = const Duration(hours: 24),
  });

  bool isExpired({DateTime? now, Duration? overrideTtl}) {
    final effectiveNow = now ?? DateTime.now();
    final effectiveTtl = overrideTtl ?? ttl;
    return effectiveNow.difference(lastAccessedAt) > effectiveTtl;
  }

  Map<String, dynamic> toJson() => {
    'fileHash': fileHash,
    'path': path,
    'createdAt': createdAt.toIso8601String(),
    'lastAccessedAt': lastAccessedAt.toIso8601String(),
    'ttlSeconds': ttl.inSeconds,
  };

  factory VoiceCacheEntry.fromJson(Map<String, dynamic> json) {
    return VoiceCacheEntry(
      fileHash: json['fileHash'] as String? ?? '',
      path: json['path'] as String? ?? '',
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
      lastAccessedAt: DateTime.tryParse(json['lastAccessedAt'] as String? ?? '') ?? DateTime.now(),
      ttl: Duration(seconds: json['ttlSeconds'] as int? ?? 86400),
    );
  }
}

/// Centralized manager for local plaintext voice note audio files.
/// Enforces bounded TTL (default 24h), single copy per voice note,
/// and automated cleanup across app lifecycle events (startup, logout, message deletion).
class VoiceNoteCacheManager {
  static final VoiceNoteCacheManager _instance = VoiceNoteCacheManager._internal();
  factory VoiceNoteCacheManager() => _instance;
  VoiceNoteCacheManager._internal();

  static const Duration defaultTtl = Duration(hours: 24);
  static const Duration orphanedRecordingTtl = Duration(minutes: 10);
  static const String cacheDirName = 'mndo_voice_cache';
  static const String manifestFileName = 'voice_cache_manifest.json';

  static String? cachedCacheDirPath;

  final Map<String, VoiceCacheEntry> _entries = {};
  bool _initialized = false;
  Directory? _customCacheDir;
  Directory? _customTempDir;

  @visibleForTesting
  bool failNextRegistration = false;

  @visibleForTesting
  bool failNextCachePath = false;

  @visibleForTesting
  void setCacheDirForTesting(Directory dir) {
    _customCacheDir = dir;
    cachedCacheDirPath = dir.path;
    _initialized = false;
    _entries.clear();
  }

  @visibleForTesting
  void setTempDirForTesting(Directory dir) {
    _customTempDir = dir;
  }

  @visibleForTesting
  void resetForTesting() {
    _customCacheDir = null;
    _customTempDir = null;
    cachedCacheDirPath = null;
    failNextRegistration = false;
    failNextCachePath = false;
    _initialized = false;
    _entries.clear();
  }

  Future<Directory> getCacheDirectory() async {
    if (_customCacheDir != null) {
      if (!await _customCacheDir!.exists()) {
        await _customCacheDir!.create(recursive: true);
      }
      return _customCacheDir!;
    }
    try {
      final tempDir = await getTemporaryDirectory();
      final cacheDir = Directory(p.normalize(p.join(tempDir.path, cacheDirName)));
      if (!await cacheDir.exists()) {
        await cacheDir.create(recursive: true);
      }
      cachedCacheDirPath = cacheDir.path;
      return cacheDir;
    } catch (_) {
      final sysTemp = Directory(p.normalize(p.join(Directory.systemTemp.path, cacheDirName)));
      if (!await sysTemp.exists()) {
        await sysTemp.create(recursive: true);
      }
      cachedCacheDirPath = sysTemp.path;
      return sysTemp;
    }
  }

  Future<Directory> getTempDirectory() async {
    if (_customTempDir != null) {
      if (!await _customTempDir!.exists()) {
        await _customTempDir!.create(recursive: true);
      }
      return _customTempDir!;
    }
    try {
      return await getTemporaryDirectory();
    } catch (_) {
      return Directory.systemTemp;
    }
  }

  Future<void> init() async {
    if (_initialized) return;
    await _loadManifest();
    _initialized = true;
  }

  File _getManifestFile(Directory cacheDir) {
    return File(p.join(cacheDir.path, manifestFileName));
  }

  Future<void> _loadManifest() async {
    try {
      final cacheDir = await getCacheDirectory();
      final manifestFile = _getManifestFile(cacheDir);
      if (await manifestFile.exists()) {
        final content = await manifestFile.readAsString();
        final json = jsonDecode(content);
        if (json is Map<String, dynamic>) {
          _entries.clear();
          for (final entry in json.entries) {
            if (entry.value is Map<String, dynamic>) {
              final parsed = VoiceCacheEntry.fromJson(entry.value as Map<String, dynamic>);
              if (parsed.fileHash.isNotEmpty && File(parsed.path).existsSync()) {
                _entries[parsed.fileHash] = parsed;
              }
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[VOICE_CACHE] Error loading manifest: $e');
    }
  }

  Future<void> _saveManifest() async {
    try {
      final cacheDir = await getCacheDirectory();
      final manifestFile = _getManifestFile(cacheDir);
      final jsonMap = _entries.map((k, v) => MapEntry(k, v.toJson()));
      await manifestFile.writeAsString(jsonEncode(jsonMap), flush: true);
    } catch (e) {
      debugPrint('[VOICE_CACHE] Error saving manifest: $e');
    }
  }

  /// Returns canonical target path for cached file by hash: `vn_cache_<fileHash>.<ext>`
  Future<String> getCacheFilePathForHash(String fileHash, {String ext = '.m4a'}) async {
    if (failNextCachePath) {
      failNextCachePath = false;
      throw const FileSystemException('Simulated controlled cache path resolution error');
    }
    final cacheDir = await getCacheDirectory();
    final cleanExt = ext.startsWith('.') ? ext : '.$ext';
    return p.normalize(p.join(cacheDir.path, 'vn_cache_$fileHash$cleanExt'));
  }

  /// Synchronously or fast-resolves cached file path if it exists on disk.
  String? getCachedFilePath(String fileHash) {
    if (fileHash.isEmpty) return null;
    final entry = _entries[fileHash];
    if (entry != null) {
      final file = File(entry.path);
      if (file.existsSync() && file.lengthSync() > 0) {
        return entry.path;
      } else {
        _entries.remove(fileHash);
      }
    }

    // Direct filesystem check in known cache directory
    final knownCacheDir = _customCacheDir?.path ?? cachedCacheDirPath;
    if (knownCacheDir != null) {
      for (final ext in ['.m4a', '.wav']) {
        final candidate = p.normalize(p.join(knownCacheDir, 'vn_cache_$fileHash$ext'));
        if (File(candidate).existsSync() && File(candidate).lengthSync() > 0) {
          final now = DateTime.now();
          _entries[fileHash] = VoiceCacheEntry(
            fileHash: fileHash,
            path: candidate,
            createdAt: now,
            lastAccessedAt: now,
          );
          return candidate;
        }
      }
    }
    return null;
  }

  /// Registers or updates a cached plaintext voice note.
  Future<void> registerFile({
    required String fileHash,
    required String filePath,
    Duration ttl = defaultTtl,
  }) async {
    if (failNextRegistration) {
      failNextRegistration = false;
      throw const FileSystemException('Simulated manifest write error');
    }
    await init();
    final now = DateTime.now();
    _entries[fileHash] = VoiceCacheEntry(
      fileHash: fileHash,
      path: p.normalize(filePath),
      createdAt: now,
      lastAccessedAt: now,
      ttl: ttl,
    );
    await _saveManifest();
  }

  /// Updates lastAccessedAt for an active or played voice note.
  Future<void> touch(String fileHash) async {
    final entry = _entries[fileHash];
    if (entry != null) {
      entry.lastAccessedAt = DateTime.now();
      await _saveManifest();
    }
  }

  /// Deletes a specific file and removes it from the manifest.
  Future<void> deleteFile(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
    _entries.removeWhere((_, entry) => p.normalize(entry.path) == p.normalize(path));
    await _saveManifest();
  }

  /// Deletes cache entry and file for a specific file hash.
  Future<void> deleteForHash(String fileHash) async {
    final entry = _entries.remove(fileHash);
    if (entry != null) {
      try {
        final file = File(entry.path);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {}
    }
    try {
      final cacheDir = await getCacheDirectory();
      for (final ext in ['.m4a', '.wav']) {
        final f = File(p.join(cacheDir.path, 'vn_cache_$fileHash$ext'));
        if (await f.exists()) {
          await f.delete();
        }
        final legacyF = File(p.join(cacheDir.path, 'vn_dec_$fileHash$ext'));
        if (await legacyF.exists()) {
          await legacyF.delete();
        }
      }
    } catch (_) {}
    await _saveManifest();
  }

  /// Cleans up expired voice notes according to TTL, plus any orphaned recordings.
  /// Safe to call on application startup, in background, or periodically.
  Future<int> cleanupExpired({Duration? maxAge, DateTime? now}) async {
    await init();
    final effectiveNow = now ?? DateTime.now();
    int deletedCount = 0;

    // 1. Remove expired manifest entries
    final expiredHashes = <String>[];
    for (final entry in _entries.values) {
      if (entry.isExpired(now: effectiveNow, overrideTtl: maxAge)) {
        expiredHashes.add(entry.fileHash);
      }
    }

    for (final hash in expiredHashes) {
      final entry = _entries.remove(hash);
      if (entry != null) {
        try {
          final file = File(entry.path);
          if (await file.exists()) {
            await file.delete();
            deletedCount++;
          }
        } catch (_) {}
      }
    }

    // 2. Scan cache directory for unindexed or stale vn_cache_* and legacy vn_dec_* files
    try {
      final cacheDir = await getCacheDirectory();
      if (await cacheDir.exists()) {
        final entities = cacheDir.listSync();
        for (final entity in entities) {
          if (entity is File) {
            final filename = p.basename(entity.path);
            if (filename == manifestFileName) continue;
            if (filename.startsWith('vn_cache_') || filename.startsWith('vn_dec_')) {
              final stat = entity.statSync();
              final age = effectiveNow.difference(stat.modified);
              final threshold = maxAge ?? defaultTtl;
              if (age > threshold) {
                try {
                  await entity.delete();
                  deletedCount++;
                } catch (_) {}
              }
            }
          }
        }
      }
    } catch (_) {}

    // 3. Scan temp directory for orphaned recording files (vn_rec_*) or legacy vn_dec_* files
    try {
      final tempDir = await getTempDirectory();
      if (await tempDir.exists()) {
        final entities = tempDir.listSync();
        for (final entity in entities) {
          if (entity is File) {
            final filename = p.basename(entity.path);
            if (filename.startsWith('vn_rec_')) {
              // Orphaned recording file older than 10 minutes (or maxAge if shorter)
              final stat = entity.statSync();
              final age = effectiveNow.difference(stat.modified);
              final recThreshold = (maxAge != null && maxAge < orphanedRecordingTtl)
                  ? maxAge
                  : orphanedRecordingTtl;
              if (age > recThreshold) {
                try {
                  await entity.delete();
                  deletedCount++;
                } catch (_) {}
              }
            } else if (filename.startsWith('vn_dec_') || filename.startsWith('vn_cache_')) {
              final stat = entity.statSync();
              final age = effectiveNow.difference(stat.modified);
              final threshold = maxAge ?? defaultTtl;
              if (age > threshold) {
                try {
                  await entity.delete();
                  deletedCount++;
                } catch (_) {}
              }
            }
          }
        }
      }
    } catch (_) {}

    await _saveManifest();
    return deletedCount;
  }

  /// Completely wipes all cached voice files and clears manifest.
  /// Invoked on user logout / account teardown / session wipe.
  Future<int> cleanupAll() async {
    await init();
    int deletedCount = 0;

    for (final entry in _entries.values) {
      try {
        final file = File(entry.path);
        if (await file.exists()) {
          await file.delete();
          deletedCount++;
        }
      } catch (_) {}
    }
    _entries.clear();

    // Wipe all files in cache directory
    try {
      final cacheDir = await getCacheDirectory();
      if (await cacheDir.exists()) {
        final entities = cacheDir.listSync();
        for (final entity in entities) {
          if (entity is File) {
            try {
              await entity.delete();
              deletedCount++;
            } catch (_) {}
          }
        }
      }
    } catch (_) {}

    // Also clean up any lingering voice files in temp directory
    try {
      final tempDir = await getTempDirectory();
      if (await tempDir.exists()) {
        final entities = tempDir.listSync();
        for (final entity in entities) {
          if (entity is File) {
            final filename = p.basename(entity.path);
            if (filename.startsWith('vn_rec_') ||
                filename.startsWith('vn_dec_') ||
                filename.startsWith('vn_cache_')) {
              try {
                await entity.delete();
                deletedCount++;
              } catch (_) {}
            }
          }
        }
      }
    } catch (_) {}

    return deletedCount;
  }
}
