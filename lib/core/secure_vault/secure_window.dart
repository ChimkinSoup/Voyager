import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Keeps the window out of screen captures while it's set. On Android,
/// `FLAG_SECURE` through `MainActivity`: the window is blank in screenshots,
/// screen recordings and the recent-apps thumbnail. On Windows,
/// `WDA_EXCLUDEFROMCAPTURE` through `flutter_window.cpp`: screenshots, Gaia's
/// captures included, and screen shares show what's behind the main window.
/// Nothing on other platforms.
abstract final class SecureWindow {
  /// Whether to go through the native channel. Tests turn it on.
  @visibleForTesting
  static bool useNative =
      Platform.isAndroid ||
      (Platform.isWindows &&
          !Platform.environment.containsKey('FLUTTER_TEST'));

  static const _channel = MethodChannel('voyager/secure_window');

  static Future<void> set(bool secure) async {
    if (!useNative) return;
    await _channel.invokeMethod<void>('set', secure);
  }
}
