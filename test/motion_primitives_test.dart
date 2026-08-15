import 'package:flutter/physics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/motion/motion.dart';
import 'package:voyager/core/widgets/resizable_pane_divider.dart';

/// Guards `lib/core/motion` — the spring/rubber-band primitives that the
/// window frame, dialogs, popovers, context menus, flip cards and pane
/// dividers all animate through. They are pure math with no visual assertion
/// of their own, so a regression here shows up as "everything feels slightly
/// wrong" rather than as a failure anywhere near the cause.
void main() {
  // A spring is critically damped exactly when c^2 == 4mk; below that it
  // overshoots and oscillates.
  group('VoyagerSpring.of', () {
    test('damping: 1.0 produces a critically damped spring', () {
      final spring = VoyagerSpring.of(damping: 1.0, response: 0.4);
      expect(
        spring.damping * spring.damping,
        closeTo(4 * spring.mass * spring.stiffness, 1e-6),
      );
    });

    test('damping below 1.0 produces an underdamped (bouncy) spring', () {
      final spring = VoyagerSpring.of(damping: 0.8, response: 0.4);
      expect(
        spring.damping * spring.damping,
        lessThan(4 * spring.mass * spring.stiffness),
      );
    });

    test('a lower response is stiffer, i.e. snappier', () {
      final slow = VoyagerSpring.of(response: 0.5);
      final fast = VoyagerSpring.of(response: 0.25);
      expect(fast.stiffness, greaterThan(slow.stiffness));
    });

    test('presets match their documented character', () {
      // move/snappy are the no-overshoot workhorses...
      for (final spring in [VoyagerSpring.move, VoyagerSpring.snappy]) {
        expect(
          spring.damping * spring.damping,
          closeTo(4 * spring.mass * spring.stiffness, 1e-6),
        );
      }
      // ...momentum/drawer are deliberately bouncy.
      for (final spring in [VoyagerSpring.momentum, VoyagerSpring.drawer]) {
        expect(
          spring.damping * spring.damping,
          lessThan(4 * spring.mass * spring.stiffness),
        );
      }
    });
  });

  group('VoyagerSpring.dampen', () {
    test('removes overshoot from a bouncy spring', () {
      final damped = VoyagerSpring.dampen(VoyagerSpring.momentum);
      expect(
        damped.damping * damped.damping,
        closeTo(4 * damped.mass * damped.stiffness, 1e-6),
      );
    });

    test('preserves mass and stiffness, so only the bounce is dropped', () {
      const bouncy = SpringDescription(mass: 2, stiffness: 300, damping: 10);
      final damped = VoyagerSpring.dampen(bouncy);
      expect(damped.mass, bouncy.mass);
      expect(damped.stiffness, bouncy.stiffness);
      expect(damped.damping, greaterThan(bouncy.damping));
    });

    test('leaves an already critical/over-damped spring untouched', () {
      final critical = VoyagerSpring.move;
      expect(identical(VoyagerSpring.dampen(critical), critical), isTrue);

      const overDamped = SpringDescription(
        mass: 1,
        stiffness: 100,
        damping: 100,
      );
      expect(identical(VoyagerSpring.dampen(overDamped), overDamped), isTrue);
    });

    test('is idempotent', () {
      final once = VoyagerSpring.dampen(VoyagerSpring.drawer);
      final twice = VoyagerSpring.dampen(once);
      expect(twice.damping, closeTo(once.damping, 1e-9));
      expect(twice.stiffness, once.stiffness);
    });
  });

  group('SpringCurve', () {
    // SpringCurve overrides Curve.transform directly, which skips the base
    // class's "t == 0 -> 0, t == 1 -> 1" shortcut. Every `curve:` call site
    // depends on the endpoints still landing, or widgets settle slightly off
    // their target value.
    test('starts exactly at 0 and lands on 1 within spring tolerance', () {
      for (final curve in [
        VoyagerSpring.moveCurve,
        VoyagerSpring.snappyCurve,
        VoyagerSpring.momentumCurve,
        VoyagerSpring.drawerCurve,
      ]) {
        expect(curve.transform(0), 0.0);
        expect(curve.transform(1), closeTo(1.0, 1e-3));
      }
    });

    test('non-bouncy presets never overshoot', () {
      for (final curve in [
        VoyagerSpring.moveCurve,
        VoyagerSpring.snappyCurve,
      ]) {
        for (var i = 0; i <= 100; i++) {
          final v = curve.transform(i / 100);
          expect(v, inInclusiveRange(0.0, 1.0));
        }
      }
    });

    test('bouncy presets do overshoot past the target', () {
      for (final curve in [
        VoyagerSpring.momentumCurve,
        VoyagerSpring.drawerCurve,
      ]) {
        final peak = [
          for (var i = 0; i <= 100; i++) curve.transform(i / 100),
        ].reduce((a, b) => a > b ? a : b);
        expect(peak, greaterThan(1.0), reason: 'bouncy preset should overshoot');
        // ...but stays sane — an overshoot this small reads as life, not a glitch.
        expect(peak, lessThan(1.1));
      }
    });

    test('makes progress across the whole range', () {
      final curve = VoyagerSpring.moveCurve;
      expect(curve.transform(0.5), greaterThan(curve.transform(0.1)));
      expect(curve.transform(0.9), greaterThan(curve.transform(0.5)));
    });
  });

  group('rubberBand', () {
    test('no overshoot means no displacement', () {
      expect(rubberBand(0, 1000), 0);
    });

    test('always resists — the result trails the raw overshoot', () {
      for (final overshoot in [1.0, 10.0, 100.0, 500.0, 5000.0]) {
        expect(rubberBand(overshoot, 1000), lessThan(overshoot));
        expect(rubberBand(overshoot, 1000), greaterThan(0));
      }
    });

    test('is symmetric about zero', () {
      expect(rubberBand(-100, 1000), -rubberBand(100, 1000));
    });

    test('resistance grows — doubling the drag less than doubles the follow', () {
      final single = rubberBand(100, 1000);
      final double_ = rubberBand(200, 1000);
      expect(double_, greaterThan(single));
      expect(double_, lessThan(single * 2));
    });

    test('is asymptotically bounded by the dimension', () {
      // No matter how far the drag goes, the pane cannot run away.
      expect(rubberBand(1e9, 1000), lessThan(1000));
      expect(rubberBand(1e9, 1000), greaterThan(990));
    });

    test('a non-positive dimension yields no displacement', () {
      expect(rubberBand(100, 0), 0);
      expect(rubberBand(100, -50), 0);
    });
  });

  group('resizePaneRubberBand', () {
    const totalWidth = 1200.0;
    const minWidth = 180.0;
    const maxWidth = 520.0;

    double band(double width) => resizePaneRubberBand(
      width: width,
      totalWidth: totalWidth,
      minWidth: minWidth,
      maxWidth: maxWidth,
    );

    test('passes widths inside the range through untouched', () {
      expect(band(minWidth), minWidth);
      expect(band(350), 350);
      expect(band(maxWidth), maxWidth);
    });

    test('past the minimum it resists instead of stopping hard', () {
      final resisted = band(minWidth - 100);
      expect(resisted, lessThan(minWidth), reason: 'it must still give');
      expect(
        resisted,
        greaterThan(minWidth - 100),
        reason: 'but not follow the drag one-to-one',
      );
    });

    test('past the maximum it resists instead of stopping hard', () {
      final resisted = band(maxWidth + 100);
      expect(resisted, greaterThan(maxWidth));
      expect(resisted, lessThan(maxWidth + 100));
    });

    test('never escapes the pane by more than the window width', () {
      expect(band(maxWidth + 1e6), lessThan(maxWidth + totalWidth));
      expect(band(minWidth - 1e6), greaterThan(minWidth - totalWidth));
    });
  });

  group('projectMomentum', () {
    test('a flick with no velocity travels nowhere', () {
      expect(projectMomentum(0), 0);
    });

    test('carries further the faster the flick', () {
      expect(projectMomentum(2000), greaterThan(projectMomentum(1000)));
    });

    test('keeps the direction of the flick', () {
      expect(projectMomentum(-1000), -projectMomentum(1000));
    });

    test('a lower deceleration rate lands shorter', () {
      expect(projectMomentum(1000, 0.99), lessThan(projectMomentum(1000)));
    });
  });

  group('SpringMotion', () {
    testWidgets('re-targeting mid-flight continues from the live value', (
      tester,
    ) async {
      final motion = SpringMotion(vsync: const TestVSync());
      addTearDown(motion.dispose);

      motion.animateTo(1);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));

      final midValue = motion.value;
      expect(midValue, greaterThan(0.0));
      expect(midValue, lessThan(1.0));
      expect(motion.velocity, greaterThan(0.0));

      // Reversing must not cut back to 0 and restart — that is the seam the
      // whole class exists to avoid.
      motion.animateTo(0);
      await tester.pump();
      expect(motion.value, closeTo(midValue, 1e-6));

      await tester.pump(const Duration(milliseconds: 200));
      expect(motion.value, lessThan(midValue));

      motion.stop(); // leave no ticker running past the test body
    });

    testWidgets('jumpTo lands exactly and clears residual velocity', (
      tester,
    ) async {
      final motion = SpringMotion(vsync: const TestVSync());
      addTearDown(motion.dispose);

      motion.animateTo(1);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      expect(motion.velocity, greaterThan(0.0));

      motion.jumpTo(0.25);
      expect(motion.value, 0.25);
      expect(motion.velocity, 0.0);
    });

    testWidgets('an explicit velocity seeds the spring from a gesture', (
      tester,
    ) async {
      final thrown = SpringMotion(vsync: const TestVSync());
      final still = SpringMotion(vsync: const TestVSync());
      addTearDown(() {
        thrown.dispose();
        still.dispose();
      });

      thrown.animateTo(1, velocity: 5);
      still.animateTo(1);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));

      // The one released with a flick is further along.
      expect(thrown.value, greaterThan(still.value));

      thrown.stop(); // leave no tickers running past the test body
      still.stop();
    });
  });
}
