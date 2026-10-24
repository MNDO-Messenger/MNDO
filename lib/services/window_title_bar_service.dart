import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Helper service that coordinates with the Windows Desktop Window Manager (DWM)
/// to dynamically match the top title bar (caption, minimize, maximize, and close buttons)
/// with the MNDO app theme (#171717 in dark mode, #FDFDFD in light mode).
class WindowTitleBarService {
  static const MethodChannel _channel = MethodChannel('mndo/window');

  /// Updates the Windows title bar caption color, text color, and border color.
  static Future<void> setTitleBarColor({required bool isDark}) async {
    if (kIsWeb || !Platform.isWindows) return;
    try {
      await _channel.invokeMethod('setTitleBarColor', {'isDark': isDark});
    } catch (_) {
      // Ignored if running on a platform/build that doesn't support the channel
    }
  }
}
