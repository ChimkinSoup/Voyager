import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android's `FLAG_SECURE`, through `MainActivity`: while it's set, the window
/// is blank in screenshots, screen recordings and the recent-apps thumbnail.
/// Nothing on other platforms.
abstract final class SecureWindow {
  /// Whether to go through `MainActivity`'s channel. Tests turn it on.
  @visibleForTesting
  static bool useAndroid = Platform.isAndroid;

  static const _android = MethodChannel('voyager/secure_window');

  static Future<void> set(bool secure) async {
    if (!useAndroid) return;
    await _android.invokeMethod<void>('set', secure);
  }
}
