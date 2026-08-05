import 'package:flutter/widgets.dart';

/// Reads the platform's "reduce motion" accessibility setting. Flutter
/// surfaces `prefers-reduced-motion`/`UIAccessibilityIsReduceMotionEnabled`/
/// the Android equivalent uniformly through [MediaQueryData.disableAnimations].
///
/// Reduced motion is not "no motion" — it means dropping slides/springs/
/// parallax/overshoot in favor of a short opacity cross-fade. Call
/// [reduced] at the call site that builds the transition and branch to a
/// plain [FadeTransition]/[AnimatedOpacity] instead of a spring/transform.
abstract final class VoyagerMotion {
  static bool reduced(BuildContext context) =>
      MediaQuery.maybeOf(context)?.disableAnimations ?? false;

  /// Duration for the reduced-motion cross-fade fallback.
  static const crossfade = Duration(milliseconds: 150);
}
