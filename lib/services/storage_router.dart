import 'dart:async';
import 'dart:convert';
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

  /// Uploads encrypted bytes to the fastest available Blossom server with automatic fallback
  Future<String?> uploadEncryptedBlob(
    List<int> encryptedBytes,
    String fileHashHex, {
    int? sessionGen,
    Duration connectTimeout = const Duration(seconds: 25),
  }) async {
    final targets = rankedServers;

    for (final server in targets) {
      if (sessionGen != null && !AccountSession.isGenerationValid(sessionGen)) {
        print('[STORAGE_ROUTER] Upload aborted: session generation $sessionGen is stale');
        return null;
      }

      final activeGen = sessionGen ?? AccountSession.currentGeneration;
      final authHeader = NostrRelayService().createBlossomAuthHeader(
        sha256Hex: fileHashHex,
        action: 'upload',
        sessionGen: activeGen,
      );

      final stopwatch = Stopwatch()..start();
      try {
        final response = await http.put(
          Uri.parse(server.uploadUrl),
          headers: {
            'Content-Type': 'application/octet-stream',
            if (authHeader != null) 'Authorization': authHeader,
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

  /// Downloads encrypted bytes from primary URL or fallback mirrors in the pool
  Future<List<int>?> downloadEncryptedBlob(
    String primaryUrl,
    String fileHashHex, {
    int? sessionGen,
    int maxAttempts = 3,
    Duration pollDelay = const Duration(milliseconds: 800),
    Duration downloadTimeout = const Duration(seconds: 15),
  }) async {
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
      addCandidate('${server.getBaseUrl}/$fileHashHex.bin');
      addCandidate('${server.getBaseUrl}/$fileHashHex.txt');
    }

    for (int attempt = 0; attempt < maxAttempts; attempt++) {
      if (sessionGen != null && !AccountSession.isGenerationValid(sessionGen)) {
        return null;
      }

      for (final url in urlsToTry) {
        try {
          final response = await http.get(Uri.parse(url)).timeout(downloadTimeout);
          if (sessionGen != null && !AccountSession.isGenerationValid(sessionGen)) {
            return null;
          }
          if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
            return response.bodyBytes;
          }
        } catch (_) {}
      }

      // If sender is currently in flight uploading, wait briefly before retrying
      if (attempt < maxAttempts - 1) {
        await Future.delayed(pollDelay);
      }
    }

    return null;
  }
}
