import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;
import 'nostr_relay_service.dart';
import 'account_session.dart';

/// Server health and dynamic latency metrics
class BlossomServerMetric {
  final String uploadUrl;
  final String getBaseUrl;
  double movingAverageLatencyMs;
  int consecutiveFailures;
  DateTime lastTested;

  BlossomServerMetric({
    required this.uploadUrl,
    required this.getBaseUrl,
    this.movingAverageLatencyMs = 400.0,
    this.consecutiveFailures = 0,
    DateTime? lastTested,
  }) : lastTested = lastTested ?? DateTime.now();

  void recordSuccess(int latencyMs) {
    consecutiveFailures = 0;
    // Exponential Moving Average (70% history, 30% current sample)
    movingAverageLatencyMs = (movingAverageLatencyMs * 0.7) + (latencyMs * 0.3);
    lastTested = DateTime.now();
  }

  void recordFailure() {
    consecutiveFailures++;
    // Heavily penalize failed or hanging server so it drops to bottom of priority rank
    movingAverageLatencyMs += 4000.0;
    lastTested = DateTime.now();
  }
}

/// Stage S2 Storage Router:
/// Manages decentralized Blossom server pool with dynamic latency ranking,
/// fast failover (1.5s circuit breaker), and BUD-11 cryptographic authorization.
class StorageRouter {
  StorageRouter._internal() {
    _initServerMetrics();
  }
  static final StorageRouter _instance = StorageRouter._internal();
  factory StorageRouter() => _instance;

  final List<BlossomServerMetric> _metrics = [];

  void _initServerMetrics() {
    _metrics.clear();
    _metrics.addAll([
      BlossomServerMetric(
        uploadUrl: 'https://blossom.primal.net/upload',
        getBaseUrl: 'https://blossom.primal.net',
        movingAverageLatencyMs: 350.0,
      ),
      BlossomServerMetric(
        uploadUrl: 'https://nostr.download/upload',
        getBaseUrl: 'https://nostr.download',
        movingAverageLatencyMs: 500.0,
      ),
      BlossomServerMetric(
        uploadUrl: 'https://blossom.band/upload',
        getBaseUrl: 'https://blossom.band',
        movingAverageLatencyMs: 800.0,
      ),
    ]);
  }

  /// Returns active servers ranked from fastest (lowest latency) to slowest
  List<BlossomServerMetric> get rankedServers {
    final list = List<BlossomServerMetric>.from(_metrics);
    list.sort((a, b) => a.movingAverageLatencyMs.compareTo(b.movingAverageLatencyMs));
    return list;
  }

  /// Uploads encrypted bytes to the fastest available Blossom server with automatic fallback.
  /// Enforces BUD-11 cryptographic authorization fail-closed: upload is rejected immediately
  /// if authorization token cannot be generated, or if payload SHA-256 does not match fileHashHex.
  Future<String?> uploadEncryptedBlob(
    List<int> encryptedBytes,
    String fileHashHex, {
    int? sessionGen,
    Duration connectTimeout = const Duration(seconds: 25),
    http.Client? client,
  }) async {
    // 1. Verify ciphertext hash binding to prevent submitting mismatched payload
    final computedHash = crypto.sha256.convert(encryptedBytes).toString();
    if (computedHash.toLowerCase() != fileHashHex.toLowerCase()) {
      print('[STORAGE_ROUTER] Upload rejected: payload SHA-256 does not match provided fileHashHex');
      return null;
    }

    final targets = rankedServers;

    for (final server in targets) {
      if (sessionGen != null && !AccountSession.isGenerationValid(sessionGen)) {
        print('[STORAGE_ROUTER] Upload aborted: session generation $sessionGen is stale');
        return null;
      }

      final activeGen = sessionGen ?? AccountSession.currentGeneration;

      // 2. Strict BUD-11 authorization: must succeed or fail-closed without network upload
      final String authHeader;
      try {
        authHeader = NostrRelayService().createBlossomAuthHeader(
          sha256Hex: fileHashHex,
          action: 'upload',
          sessionGen: activeGen,
        );
      } catch (e) {
        print('[STORAGE_ROUTER] Blossom upload aborted: failed to create authorization header: $e');
        return null;
      }

      if (authHeader.isEmpty) {
        print('[STORAGE_ROUTER] Blossom upload aborted: empty authorization header');
        return null;
      }

      final stopwatch = Stopwatch()..start();
      try {
        final uri = Uri.parse(server.uploadUrl);
        final httpClient = client;
        final response = httpClient != null
            ? await httpClient.put(
                uri,
                headers: {
                  'Content-Type': 'application/octet-stream',
                  'Authorization': authHeader,
                },
                body: encryptedBytes,
              ).timeout(connectTimeout)
            : await http.put(
                uri,
                headers: {
                  'Content-Type': 'application/octet-stream',
                  'Authorization': authHeader,
                },
                body: encryptedBytes,
              ).timeout(connectTimeout);

        stopwatch.stop();

        if (sessionGen != null && !AccountSession.isGenerationValid(sessionGen)) {
          return null;
        }

        if (response.statusCode == 200 || response.statusCode == 201) {
          server.recordSuccess(stopwatch.elapsedMilliseconds);
          String? finalUrl;
          try {
            final jsonResp = jsonDecode(response.body) as Map<String, dynamic>;
            finalUrl = jsonResp['url'] as String?;
          } catch (_) {
            finalUrl = '${server.getBaseUrl}/$fileHashHex';
          }

          if (finalUrl != null && finalUrl.isNotEmpty) {
            print('[STORAGE_ROUTER] Successfully uploaded to ${server.uploadUrl} in ${stopwatch.elapsedMilliseconds}ms -> $finalUrl');
            return finalUrl;
          }
        } else {
          print('[STORAGE_ROUTER] Server ${server.uploadUrl} returned status ${response.statusCode}');
          server.recordFailure();
        }
      } catch (e) {
        stopwatch.stop();
        server.recordFailure();
        print('[STORAGE_ROUTER] Upload attempt to ${server.uploadUrl} failed after ${stopwatch.elapsedMilliseconds}ms: $e');
      }
    }

    print('[STORAGE_ROUTER] All Blossom servers in pool failed to accept upload');
    return null;
  }

  /// Downloads encrypted bytes from primary URL or fallback mirrors in the pool.
  /// Bounded by an overall deadline (default 30 seconds) to prevent hanging,
  /// with shorter per-request timeouts (default 6 seconds), permanent failure handling,
  /// and session generation checks across network calls.
  Future<List<int>?> downloadEncryptedBlob(
    String primaryUrl,
    String fileHashHex, {
    int? sessionGen,
    int maxAttempts = 2,
    Duration pollDelay = const Duration(milliseconds: 500),
    Duration downloadTimeout = const Duration(seconds: 6),
    Duration overallTimeout = const Duration(seconds: 30),
    http.Client? client,
  }) async {
    final deadline = DateTime.now().add(overallTimeout);
    final httpClient = client;

    // Generate prioritized URL list starting with primaryUrl followed by mirrors
    final urlsToTry = <String>[];
    void addCandidate(String u) {
      if (u.isNotEmpty && !urlsToTry.contains(u)) {
        urlsToTry.add(u);
      }
    }

    addCandidate(primaryUrl);
    for (final server in rankedServers) {
      addCandidate('${server.getBaseUrl}/$fileHashHex');
    }

    final permanentFailures = <String>{};

    for (int attempt = 0; attempt < maxAttempts; attempt++) {
      if (sessionGen != null && !AccountSession.isGenerationValid(sessionGen)) {
        return null;
      }
      if (DateTime.now().isAfter(deadline)) {
        print('[STORAGE_ROUTER] Download aborted: overall deadline exceeded');
        return null;
      }

      for (final url in urlsToTry) {
        if (permanentFailures.contains(url)) continue;

        final remaining = deadline.difference(DateTime.now());
        if (remaining <= Duration.zero) {
          print('[STORAGE_ROUTER] Download aborted: overall deadline exceeded');
          return null;
        }

        final effectiveTimeout = downloadTimeout < remaining ? downloadTimeout : remaining;

        try {
          final uri = Uri.parse(url);
          final response = httpClient != null
              ? await httpClient.get(uri).timeout(effectiveTimeout)
              : await http.get(uri).timeout(effectiveTimeout);

          if (sessionGen != null && !AccountSession.isGenerationValid(sessionGen)) {
            return null;
          }

          if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
            return response.bodyBytes;
          } else if (response.statusCode == 404 || response.statusCode == 410) {
            // Permanent HTTP error: mark URL as failed so subsequent attempts don't retry it
            permanentFailures.add(url);
          }
        } catch (_) {
          // Timeout or network error on this candidate URL
        }
      }

      // If sender is currently in flight uploading, wait briefly before retrying
      if (attempt < maxAttempts - 1) {
        final remaining = deadline.difference(DateTime.now());
        if (remaining <= Duration.zero) {
          print('[STORAGE_ROUTER] Download aborted: overall deadline exceeded before retry delay');
          return null;
        }
        final waitTime = pollDelay < remaining ? pollDelay : remaining;
        await Future.delayed(waitTime);
      }
    }

    return null;
  }
}
