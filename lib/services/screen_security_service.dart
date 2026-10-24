import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'app_logger.dart';

/// Cross-platform service coordinating hardware window protection
/// and native OS screenshot event detection.
class ScreenSecurityService {
  static final ScreenSecurityService _instance =
      ScreenSecurityService._internal();
  factory ScreenSecurityService() => _instance;

  ScreenSecurityService._internal() {
    _initChannel();
  }

  static const MethodChannel _mobileChannel = MethodChannel(
    'mndo/screen_security',
  );
  static const MethodChannel _windowChannel = MethodChannel('mndo/window');

  final StreamController<void> _screenshotController =
      StreamController<void>.broadcast();
  bool _initialized = false;
  bool _isSecure = false;

  /// Stream emitting events whenever a native screenshot is taken by the user.
  Stream<void> get onScreenshotDetected => _screenshotController.stream;

  /// Whether screen security (anti-capture) is currently active.
  bool get isScreenSecurityActive => _isSecure;

  void _initChannel() {
    if (_initialized || kIsWeb) return;
    _initialized = true;

    if (Platform.isAndroid || Platform.isIOS) {
      _mobileChannel.setMethodCallHandler((call) async {
        if (call.method == 'onScreenshotDetected') {
          AppLogger.info(
            '[SCREEN_SECURITY] Native screenshot detected by OS callback',
          );
          _screenshotController.add(null);
        }
      });
    }
  }

  /// Enables or disables hardware/compositor-level screenshot blocking.
  /// - Windows: SetWindowDisplayAffinity (WDA_EXCLUDEFROMCAPTURE)
  /// - Android: WindowManager.FLAG_SECURE
  /// - iOS / Desktop: Graceful platform dispatch
  Future<void> setScreenSecurity(bool enable) async {
    if (kIsWeb) return;
    _isSecure = enable;

    try {
      if (Platform.isWindows) {
        await _windowChannel.invokeMethod('setScreenSecurity', {
          'enable': enable,
        });
        AppLogger.debug(
          '[SCREEN_SECURITY] Windows screen security set to: $enable',
        );
      } else if (Platform.isAndroid || Platform.isIOS) {
        await _mobileChannel.invokeMethod('setScreenSecurity', {
          'enable': enable,
        });
        AppLogger.debug(
          '[SCREEN_SECURITY] Mobile screen security set to: $enable',
        );
      }
    } catch (e) {
      AppLogger.debug(
        '[SCREEN_SECURITY] setScreenSecurity failed or unsupported on this platform: $e',
      );
    }
  }

  /// Disposes service resources
  @visibleForTesting
  void dispose() {
    _screenshotController.close();
  }
}
