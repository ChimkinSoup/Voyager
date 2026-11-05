import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Plays one of Gaia's on-screen flashes (GAIA_AUTONOMY_HLD.md §6) in [accent]
/// (0xRRGGBB, or ARGB), as `gaia_os_control.dart` describes it: fire and
/// forget, since an action never waits on its animation. Windows only.
/// Live actions default to Astral's accepted Trace + Bloom material; debug
/// previews can explicitly override the family and click study.
void gaiaFlash(Map<String, Object?> flash, int accent) {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) return;
  unawaited(
    const MethodChannel('voyager/gaia_border')
        .invokeMethod<void>('flash', {
          'style': 'astral',
          if (flash['kind'] == 'click') 'click_variant': 'traceBloom',
          ...flash,
          'accent': accent & 0xFFFFFF,
        })
        .catchError((Object error) {
          debugPrint('[gaia] flash not shown: $error');
        }),
  );
}

/// Ends every flash playing, at once. All of them: there's no ending one.
void gaiaStopFlashes() {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) return;
  unawaited(
    const MethodChannel(
      'voyager/gaia_border',
    ).invokeMethod<void>('stopFlashes').catchError((Object error) {
      debugPrint('[gaia] flashes not stopped: $error');
    }),
  );
}
