import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:voyager/core/platform/platform_info.dart';

/// Mitigates a Flutter Windows debug assertion when modifier keys (often Alt)
/// arrive with inconsistent state after Alt+Tab or window focus changes.
///
/// See: https://github.com/flutter/flutter/issues/143155
void installWindowsKeyboardWorkaround() {
  if (!isWindows || !kDebugMode) return;

  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    if (_isKnownWindowsKeyboardDesync(details)) return;
    if (previous != null) {
      previous(details);
    } else {
      FlutterError.presentError(details);
    }
  };
}

bool _isKnownWindowsKeyboardDesync(FlutterErrorDetails details) {
  final exception = details.exception;
  if (exception is! AssertionError) return false;
  final message = exception.message?.toString() ?? '';
  if (!message.contains(
    'Attempted to send a key down event when no keys are in keysPressed',
  )) {
    return false;
  }
  return details.stack?.toString().contains('raw_keyboard.dart') ?? false;
}

Future<void> resyncWindowsKeyboardState() async {
  if (!isWindows) return;
  await HardwareKeyboard.instance.syncKeyboardState();
}
