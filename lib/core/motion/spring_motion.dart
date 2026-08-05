import 'package:flutter/animation.dart';
import 'package:flutter/physics.dart';

import 'voyager_spring.dart';

/// A single animated double driven by a spring instead of a curve+duration.
///
/// The core property that makes gesture-driven UI feel alive: calling
/// [animateTo] while a previous spring is still in flight does not cut the
/// motion and restart it — it reads the controller's live (presentation)
/// value and velocity and re-targets from there, so a reversed or redirected
/// animation never shows a seam. Never read [value]/[velocity] once and
/// cache them across a rebuild; always go through this object so the numbers
/// stay live.
class SpringMotion {
  SpringMotion({
    required TickerProvider vsync,
    double initialValue = 0,
    SpringDescription? spring,
  }) : _spring = spring ?? VoyagerSpring.move,
       controller = AnimationController.unbounded(
         vsync: vsync,
         value: initialValue,
       );

  /// The underlying controller — pass this directly to [AnimatedBuilder] or
  /// [Listenable.merge]; it fires on every tick like any other
  /// `AnimationController`.
  final AnimationController controller;

  SpringDescription _spring;

  double get value => controller.value;

  /// Instantaneous velocity of the live simulation (0 when at rest). Read
  /// this to hand off into a gesture, or to seed a subsequent [animateTo].
  double get velocity => controller.velocity;

  /// Animates toward [target]. If a spring is already in flight, continues
  /// from its current value/velocity rather than snapping — this is what
  /// makes the motion interruptible and reversible mid-flight.
  ///
  /// [velocity] overrides the carried-over velocity, e.g. a gesture's
  /// release velocity from [DragEndDetails.velocity].
  TickerFuture animateTo(
    double target, {
    SpringDescription? spring,
    double? velocity,
  }) {
    final effectiveSpring = spring ?? _spring;
    return controller.animateWith(
      SpringSimulation(
        effectiveSpring,
        controller.value,
        target,
        velocity ?? controller.velocity,
      ),
    );
  }

  /// Sets the default spring used by future [animateTo] calls that don't
  /// pass one explicitly (e.g. after a reduced-motion check).
  set defaultSpring(SpringDescription spring) => _spring = spring;

  /// Jumps to [target] with no animation and clears any residual velocity.
  void jumpTo(double target) {
    controller.stop();
    controller.value = target;
  }

  void stop() => controller.stop();

  void dispose() => controller.dispose();
}
