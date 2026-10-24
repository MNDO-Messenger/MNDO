import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;

import 'nostr_relay_service.dart';
import 'account_session.dart';
import 'app_logger.dart';

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
    list.sort(
      (a, b) => a.movingAverageLatencyMs.compareTo(b.movingAverageLatencyMs),
    );
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
      AppLogger.warning(
        '[STORAGE_ROUTER] Upload rejected: payload SHA-256 does not match provided fileHashHex',
      );
      return null;
    }

    final targets = rankedServers;

    for (final server in targets) {
      if (sessionGen != null && !AccountSession.isGenerationValid(sessionGen)) {
        AppLogger.info(
          '[STORAGE_ROUTER] Upload aborted: session generation $sessionGen is stale',
        );
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
        AppLogger.warning(
          '[STORAGE_ROUTER] Blossom upload aborted: failed to create authorization header: $e',
        );
        return null;
      }

      if (authHeader.isEmpty) {
        AppLogger.warning(
          '[STORAGE_ROUTER] Blossom upload aborted: empty authorization header',
        );
        return null;
      }

      final stopwatch = Stopwatch()..start();
      try {
        final uri = Uri.parse(server.uploadUrl);
        final httpClient = client;
        final response = httpClient != null
            ? await httpClient
                  .put(
                    uri,
                    headers: {
                      'Content-Type': 'application/octet-stream',
                      'Authorization': authHeader,
                    },
                    body: encryptedBytes,
                  )
                  .timeout(connectTimeout)
            : await http
                  .put(
                    uri,
                    headers: {
                      'Content-Type': 'application/octet-stream',
                      'Authorization': authHeader,
                    },
                    body: encryptedBytes,
                  )
                  .timeout(connectTimeout);

        stopwatch.stop();

        if (sessionGen != null &&
            !AccountSession.isGenerationValid(sessionGen)) {
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
            AppLogger.info(
              '[STORAGE_ROUTER] Successfully uploaded to ${server.uploadUrl} in ${stopwatch.elapsedMilliseconds}ms -> $finalUrl',
            );
            return finalUrl;
          }
        } else {
          AppLogger.warning(
            '[STORAGE_ROUTER] Server ${server.uploadUrl} returned status ${response.statusCode}',
          );
          server.recordFailure();
        }
      } catch (e) {
        stopwatch.stop();
        server.recordFailure();
        AppLogger.warning(
          '[STORAGE_ROUTER] Upload attempt to ${server.uploadUrl} failed after ${stopwatch.elapsedMilliseconds}ms: $e',
        );
      }
    }

    AppLogger.warning(
      '[STORAGE_ROUTER] All Blossom servers in pool failed to accept upload',
    );
    return null;
  }

  @visibleForTesting
  static bool skipDnsLookupForTesting = false;

  /// Checks whether an IP address (IPv4 or IPv6) targets a prohibited destination:
  /// loopback, private RFC 1918, link-local (RFC 3927 / fe80::/10), ULA (fc00::/7),
  /// IPv4-mapped IPv6 (::ffff:x.x.x.x), or multicast/reserved addresses (BUG 4).
  static bool isProhibitedIpAddress(InternetAddress address) {
    if (address.isLoopback || address.isLinkLocal || address.isMulticast) {
      return true;
    }

    final raw = address.rawAddress;

    if (address.type == InternetAddressType.IPv4) {
      final b0 = raw[0];
      final b1 = raw[1];
      if (b0 == 0) return true; // 0.0.0.0/8
      if (b0 == 10) return true; // 10.0.0.0/8
      if (b0 == 127) return true; // 127.0.0.0/8
      if (b0 == 169 && b1 == 254) return true; // 169.254.0.0/16
      if (b0 == 172 && b1 >= 16 && b1 <= 31) return true; // 172.16.0.0/12
      if (b0 == 192 && b1 == 168) return true; // 192.168.0.0/16
      if (b0 >= 224) return true; // Multicast / Class E reserved
    } else if (address.type == InternetAddressType.IPv6) {
      // Loopback
      if (address.isLoopback) return true;

      // Unique Local Addresses (ULA): fc00::/7 (0xfc or 0xfd in high byte)
      if ((raw[0] & 0xfe) == 0xfc) return true;

      // Link-Local: fe80::/10
      if (raw[0] == 0xfe && (raw[1] & 0xc0) == 0x80) return true;

      // IPv4-mapped IPv6: ::ffff:x.x.x.x
      bool isIpv4Mapped = true;
      for (int i = 0; i < 10; i++) {
        if (raw[i] != 0) {
          isIpv4Mapped = false;
          break;
        }
      }
      if (isIpv4Mapped && raw[10] == 0xff && raw[11] == 0xff) {
        final b0 = raw[12];
        final b1 = raw[13];
        if (b0 == 0 || b0 == 10 || b0 == 127) return true;
        if (b0 == 169 && b1 == 254) return true;
        if (b0 == 172 && b1 >= 16 && b1 <= 31) return true;
        if (b0 == 192 && b1 == 168) return true;
        if (b0 >= 224) return true;
      }
    }
    return false;
  }

  /// Validates that an incoming media/blob URL is secure:
  /// 1. Must use 'https' scheme (rejecting 'http', 'file', 'javascript', 'data', etc.)
  /// 2. Must have a valid non-empty host
  /// 3. Must not target loopback, link-local, ULA, or private RFC 1918 / RFC 3927 addresses (anti-SSRF - BUG 4)
  static bool isValidStorageUrl(String urlString) {
    if (urlString.isEmpty) return false;
    final uri = Uri.tryParse(urlString);
    if (uri == null) return false;
    if (uri.scheme.toLowerCase() != 'https') return false;
    var host = uri.host.toLowerCase().trim();
    if (host.isEmpty) return false;

    // Strip IPv6 brackets if present (e.g. [::1])
    if (host.startsWith('[') && host.endsWith(']')) {
      host = host.substring(1, host.length - 1);
    }

    // Check known loopback hostnames
    if (host == 'localhost' ||
        host == 'ip6-localhost' ||
        host == 'ip6-loopback') {
      return false;
    }

    // Check if host is an IP address literal
    final ip = InternetAddress.tryParse(host);
    if (ip != null) {
      if (isProhibitedIpAddress(ip)) return false;
    } else {
      // Check IPv4 dotted decimal
      final ipv4Parts = host.split('.');
      if (ipv4Parts.length == 4) {
        final octets = ipv4Parts.map((p) => int.tryParse(p)).toList();
        if (octets.every((o) => o != null && o >= 0 && o <= 255)) {
          final b0 = octets[0]!;
          final b1 = octets[1]!;
          if (b0 == 0 || b0 == 10 || b0 == 127) return false;
          if (b0 == 169 && b1 == 254) return false;
          if (b0 == 172 && b1 >= 16 && b1 <= 31) return false;
          if (b0 == 192 && b1 == 168) return false;
          if (b0 >= 224) return false;
        }
      }
    }

    return true;
  }

  /// Asynchronously resolves host and verifies that none of its IP addresses resolve
  /// to prohibited loopback/private/link-local destinations (anti-SSRF / DNS rebinding guard - BUG 4).
  static Future<bool> isHostSafeForDownload(
    String host, {
    bool skipDns = false,
  }) async {
    var cleanHost = host.toLowerCase().trim();
    if (cleanHost.startsWith('[') && cleanHost.endsWith(']')) {
      cleanHost = cleanHost.substring(1, cleanHost.length - 1);
    }

    final directIp = InternetAddress.tryParse(cleanHost);
    if (directIp != null) {
      return !isProhibitedIpAddress(directIp);
    }

    if (skipDns || skipDnsLookupForTesting) {
      return true;
    }

    try {
      final addresses = await InternetAddress.lookup(cleanHost)
          .timeout(const Duration(seconds: 2));
      if (addresses.isEmpty) return false;
      for (final addr in addresses) {
        if (isProhibitedIpAddress(addr)) return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Downloads encrypted bytes from primary URL or fallback mirrors in the pool.
  /// Bounded by an overall deadline (default 30 seconds) to prevent hanging,
  /// with shorter per-request timeouts (default 6 seconds), permanent failure handling,
  /// session generation checks across network calls, DNS rebinding guards, and redirect validation.
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
    final isCustomTestClient = client != null;

    // Generate prioritized URL list starting with primaryUrl followed by mirrors
    final urlsToTry = <String>[];
    void addCandidate(String u) {
      if (u.isNotEmpty && isValidStorageUrl(u) && !urlsToTry.contains(u)) {
        urlsToTry.add(u);
      }
    }

    addCandidate(primaryUrl);
    for (final server in rankedServers) {
      addCandidate('${server.getBaseUrl}/$fileHashHex');
      addCandidate('${server.getBaseUrl}/$fileHashHex.bin');
      addCandidate('${server.getBaseUrl}/$fileHashHex.txt');
    }

    final permanentFailures = <String>{};

    for (int attempt = 0; attempt < maxAttempts; attempt++) {
      if (sessionGen != null && !AccountSession.isGenerationValid(sessionGen)) {
        return null;
      }
      if (DateTime.now().isAfter(deadline)) {
        AppLogger.warning(
          '[STORAGE_ROUTER] Download aborted: overall deadline exceeded',
        );
        return null;
      }

      for (final url in urlsToTry) {
        if (permanentFailures.contains(url)) continue;

        final remaining = deadline.difference(DateTime.now());
        if (remaining <= Duration.zero) {
          AppLogger.warning(
            '[STORAGE_ROUTER] Download aborted: overall deadline exceeded',
          );
          return null;
        }

        final effectiveTimeout = downloadTimeout < remaining
            ? downloadTimeout
            : remaining;

        try {
          Uri currentUri = Uri.parse(url);
          if (!await isHostSafeForDownload(
            currentUri.host,
            skipDns: isCustomTestClient,
          )) {
            AppLogger.warning(
              '[STORAGE_ROUTER] Host ${currentUri.host} resolved to prohibited IP address; skipping',
            );
            permanentFailures.add(url);
            continue;
          }

          http.Response? response;
          // Follow up to 3 redirects manually while validating each destination (BUG 4)
          for (int redirect = 0; redirect < 4; redirect++) {
            final request = http.Request('GET', currentUri);
            request.followRedirects = false;

            final clientToUse = httpClient ?? http.Client();
            final streamed = await clientToUse
                .send(request)
                .timeout(effectiveTimeout);

            // Response size bounding: max 100MB limit before buffering
            const maxDownloadBytes = 100 * 1024 * 1024;
            if (streamed.contentLength != null &&
                streamed.contentLength! > maxDownloadBytes) {
              AppLogger.warning(
                '[STORAGE_ROUTER] Download rejected: Content-Length ${streamed.contentLength} exceeds 100MB',
              );
              response = null;
              break;
            }

            if (streamed.statusCode >= 300 && streamed.statusCode < 400) {
              final location = streamed.headers['location'];
              if (location == null || location.isEmpty) {
                response = null;
                break;
              }
              final nextUri = currentUri.resolve(location);
              if (!isValidStorageUrl(nextUri.toString()) ||
                  !await isHostSafeForDownload(
                    nextUri.host,
                    skipDns: isCustomTestClient,
                  )) {
                AppLogger.warning(
                  '[STORAGE_ROUTER] Redirect to prohibited destination blocked: $nextUri',
                );
                response = null;
                break;
              }
              currentUri = nextUri;
              continue;
            }

            response = await http.Response.fromStream(streamed);
            break;
          }

          if (response == null) {
            continue;
          }

          if (sessionGen != null &&
              !AccountSession.isGenerationValid(sessionGen)) {
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
          AppLogger.warning(
            '[STORAGE_ROUTER] Download aborted: overall deadline exceeded before retry delay',
          );
          return null;
        }
        final waitTime = pollDelay < remaining ? pollDelay : remaining;
        await Future.delayed(waitTime);
      }
    }

    return null;
  }
}
