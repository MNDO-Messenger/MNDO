import 'package:flutter/foundation.dart';

/// Privacy-aware structured logger for MNDO.
/// Redacts sensitive cryptographic identifiers, suppresses debug output in release builds,
/// and prevents leaking plaintexts or private keys to system device logs.
class AppLogger {
  AppLogger._();

  /// Whether debug logs should be printed. Automatically disabled in release mode.
  static bool enableDebugLogs = !kReleaseMode;

  /// Custom log output sink (useful for testing or routing to crashlytics).
  /// Defaults to [debugPrint].
  static void Function(String message) logSink = (msg) => debugPrint(msg);

  /// Redacts a 64-hex public key or string identifier to prefix...suffix (e.g. "a1b2c3...f8e9").
  static String redact(String? identifier, {int lead = 6, int trail = 4}) {
    if (identifier == null || identifier.isEmpty) return '<null>';
    if (identifier.length <= lead + trail) return '***';
    return '${identifier.substring(0, lead)}...${identifier.substring(identifier.length - trail)}';
  }

  /// Redacts a Nostr pubkey or npub
  static String redactNostrKey(String? key) => redact(key, lead: 6, trail: 4);

  /// Redacts a Master public key
  static String redactMasterKey(String? key) => redact(key, lead: 6, trail: 4);

  /// Debug level: suppressed in release mode
  static void debug(String message, [Object? error, StackTrace? stackTrace]) {
    if (!enableDebugLogs) return;
    final formatted = '[DEBUG] $message${error != null ? ' | Error: $error' : ''}';
    logSink(formatted);
    if (stackTrace != null && error != null) {
      logSink(stackTrace.toString());
    }
  }

  /// Info level: operational milestones
  static void info(String message) {
    logSink('[INFO] $message');
  }

  /// Warning level: non-fatal anomalies or security alerts
  static void warning(String message, [Object? error]) {
    logSink('[WARN] $message${error != null ? ' | $error' : ''}');
  }

  /// Error level: caught exceptions or critical failures
  static void error(String message, [Object? error, StackTrace? stackTrace]) {
    logSink('[ERROR] $message${error != null ? ' | $error' : ''}');
    if (stackTrace != null) {
      logSink(stackTrace.toString());
    }
  }
}
