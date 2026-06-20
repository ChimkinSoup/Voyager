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
