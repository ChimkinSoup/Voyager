import 'dart:math';
import 'dart:ui';

/// Where [date] falls in the lunar cycle: 0 new, 0.5 full, back to 1.
double moonPhaseAt(DateTime date) {
  const synodicMonthDays = 29.530588853;
  final knownNewMoon = DateTime.utc(2000, 1, 6, 18, 14);
  final days = date.toUtc().difference(knownNewMoon).inMinutes / 1440;
  return (days / synodicMonthDays) % 1;
}

/// Hours from the moon's highest at [hour], as a share of the six either
/// side it's up: -1 rising, 1 setting, beyond that below the horizon.
/// Without a place to know its rising by, it's as at the equator: highest
/// about noon when new and midnight when full.
double moonHourAngle(double phase, double hour) =>
    ((hour - phase * 24) % 24 - 12) / 6;

/// How much of the moon at [phase] is lit, 0 to 1.
double moonLit(double phase) => (1 - cos(2 * pi * phase)) / 2;

/// How far the moon is up, 0 below the horizon to 1 clear of it.
double moonUpAt(double hourAngle) =>
    ((1 - hourAngle.abs()) / 0.08).clamp(0.0, 1.0);

/// How much the moon's light washes out faint stars, 0 to 1: by how much
/// of it is lit, and how high it is.
double moonlightAt(double phase, double hour) {
  final a = moonHourAngle(phase, hour);
  final up = moonUpAt(a);
  if (up == 0) return 0;
  return up * moonLit(phase) * (0.4 + 0.6 * cos(a * pi / 2));
}

/// A star of [alpha] by [moonlight]: the faint drowned first.
double moonlit(double alpha, double moonlight) {
  final floor = 0.3 * moonlight;
  return max(0, (alpha - floor) / (1 - floor));
}

/// The lit part of a moon of radius [r] at [phase], about the origin, lit
/// on the right: mirror it for a waning moon, past 0.5.
Path moonLitPath(double r, double phase) {
  final disc = Rect.fromCircle(center: Offset.zero, radius: r);
  // The terminator is a half-ellipse whose width runs r → 0 → r across
  // the half cycle; it bulges toward the lit side until the half moon.
  final k = cos(2 * pi * phase);
  return Path()
    ..moveTo(0, -r)
    ..arcTo(disc, -pi / 2, pi, false)
    ..arcTo(
      Rect.fromCenter(
        center: Offset.zero,
        width: 2 * r * k.abs(),
        height: 2 * r,
      ),
      pi / 2,
      k > 0 ? -pi : pi,
      false,
    )
    ..close();
}
