import 'package:flutter/foundation.dart';

enum VoyagerPlatform { windows, android, other }

VoyagerPlatform get currentPlatform {
  if (defaultTargetPlatform == TargetPlatform.windows) {
    return VoyagerPlatform.windows;
  }
  if (defaultTargetPlatform == TargetPlatform.android) {
    return VoyagerPlatform.android;
  }
  return VoyagerPlatform.other;
}

bool get isWindows => currentPlatform == VoyagerPlatform.windows;
bool get isAndroid => currentPlatform == VoyagerPlatform.android;

/// Linux desktop, which [VoyagerPlatform] folds into [VoyagerPlatform.other]
/// because nothing else in the app treats it as its own case.
///
/// Kept as a standalone getter for the Caps Lock indicator, whose platform gate
/// is "Windows or Linux desktop" (CAPS_LOCK.md §2.2) — the two places a
/// hardware Caps Lock key exists and the OS draws nothing of its own.
bool get isLinux => defaultTargetPlatform == TargetPlatform.linux;
