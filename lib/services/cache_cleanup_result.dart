/// Typed result contract representing verifiable cache cleanup operations (P1.2).
/// Distinguishes between deleted, failed, and safely cleared items without suppressing errors.
class CacheCleanupResult {
  final int deletedCount;
  final int failedCount;
  final List<String> failedPaths;

  const CacheCleanupResult({
    this.deletedCount = 0,
    this.failedCount = 0,
    this.failedPaths = const [],
  });

  /// True only if zero deletion failures occurred.
  bool get isSuccess => failedCount == 0;

  /// Combines two cleanup results into an aggregate result.
  CacheCleanupResult combine(CacheCleanupResult other) {
    return CacheCleanupResult(
      deletedCount: deletedCount + other.deletedCount,
      failedCount: failedCount + other.failedCount,
      failedPaths: [...failedPaths, ...other.failedPaths],
    );
  }

  @override
  String toString() =>
      'CacheCleanupResult(deleted: $deletedCount, failed: $failedCount, paths: $failedPaths)';
}
