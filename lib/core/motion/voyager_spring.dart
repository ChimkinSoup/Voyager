import 'dart:math' as math;

import 'package:flutter/animation.dart';
import 'package:flutter/physics.dart';

/// Designer-friendly spring construction: damping ratio + response (settle
/// speed, seconds) instead of raw mass/stiffness/damping, mirroring the two
/// parameters Apple exposes for `UISpringTimingParameters`/SwiftUI's
/// `.spring(response:dampingFraction:)`.
///
/// `damping` — 1.0 is critically damped (no overshoot); below 1.0 overshoots
/// and oscillates, lower is bouncier. `response` — how quickly the value
/// closes on the target; lower is snappier. This is not a fixed duration —
/// the spring's settle time emerges from these two parameters plus whatever
/// velocity it is carrying when it starts.
abstract final class VoyagerSpring {
  static SpringDescription of({
    double damping = 1.0,
    double response = 0.4,
    double mass = 1.0,
  }) {
    final stiffness = math.pow(2 * math.pi / response, 2) * mass;
    final dampingCoefficient = 4 * math.pi * damping * mass / response;
    return SpringDescription(
      mass: mass,
      stiffness: stiffness.toDouble(),
      damping: dampingCoefficient,
    );
  }

  /// Default for most UI motion: reposition, resize, show/hide. No overshoot.
  static final move = of(damping: 1.0, response: 0.4);

  /// A little snappier than [move], for small/frequent state changes (press
  /// scale, toggle, selection pill).
  static final snappy = of(damping: 1.0, response: 0.28);

  /// Momentum-carrying interactions only: a flick, a throw, a drag release.
  /// Never use for content that just appeared without a preceding gesture.
  static final momentum = of(damping: 0.8, response: 0.4);

  /// Sheets/drawers/popovers opening or closing.
  static final drawer = of(damping: 0.8, response: 0.3);

  /// Same curve with overshoot removed — the reduced-motion fallback for any
  /// of the bouncier presets above.
  static SpringDescription dampen(SpringDescription spring) {
    if (spring.damping * spring.damping >= 4 * spring.mass * spring.stiffness) {
      return spring;
    }
    return SpringDescription(
      mass: spring.mass,
      stiffness: spring.stiffness,
      damping: 2 * math.sqrt(spring.mass * spring.stiffness),
    );
  }

  /// A [Curve] shaped like [move] — for the many call sites (`CurvedAnimation`,
  /// implicit-animation `curve:` params, `Tween.animate`) that already drive a
  /// fixed-duration `AnimationController` and just need a spring *shape*, not
  /// full gesture-interruptible physics. For anything driven by a live drag or
  /// that must be retargetable mid-flight, use [SpringMotion] instead.
  static final moveCurve = SpringCurve(damping: 1.0, response: 0.4);
  static final snappyCurve = SpringCurve(damping: 1.0, response: 0.28);
  static final momentumCurve = SpringCurve(damping: 0.8, response: 0.4);
  static final drawerCurve = SpringCurve(damping: 0.8, response: 0.3);
}

/// Maps normalized animation progress (0 → 1) through a spring's natural
/// motion instead of a bezier/polynomial easing function. Built once (spring
/// settle time is solved eagerly in the constructor) so it's cheap to reuse
/// as a `static final` preset.
class SpringCurve extends Curve {
  SpringCurve({double damping = 1.0, double response = 0.4})
    : this._(VoyagerSpring.of(damping: damping, response: response));

  SpringCurve._(this._spring) : _settleSeconds = _findSettleSeconds(_spring);

  final SpringDescription _spring;
  final double _settleSeconds;

  static double _findSettleSeconds(SpringDescription spring) {
    final sim = SpringSimulation(spring, 0, 1, 0);
    var t = 0.0;
    const step = 0.01;
    const maxSeconds = 5.0;
    while (!sim.isDone(t) && t < maxSeconds) {
      t += step;
    }
    return t <= 0 ? 0.001 : t;
  }

  @override
  double transform(double t) {
    final sim = SpringSimulation(_spring, 0, 1, 0);
    return sim.x(t.clamp(0.0, 1.0) * _settleSeconds);
  }
}
