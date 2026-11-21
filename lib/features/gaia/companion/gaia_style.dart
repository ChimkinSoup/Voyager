import 'package:flutter/material.dart';

/// Gaia's ink: the greys its text and icons are drawn in on its dark
/// surface, brightest first. Neutral, so the user's accent is the only hue
/// that isn't a status.
abstract final class GaiaInk {
  /// Lit text: a hovered or selected row, a title.
  static const bright = Color(0xFFF5F5F5);

  /// A row at rest.
  static const dim = Color(0xFFD4D4D4);

  /// Secondary text and icons: a detail, a shortcut, a message's time.
  static const muted = Color(0xFFA3A3A3);

  /// Tertiary: a count, a section's heading, a hint.
  static const faint = Color(0xFF737373);

  /// A one pixel edge: a ring at rest, a selected row's border, a rule.
  static final hairline = Colors.white.withValues(alpha: 0.1);

  /// A row's fill under the cursor, and while it's the selected one.
  static final hover = Colors.white.withValues(alpha: 0.05);
  static final selected = Colors.white.withValues(alpha: 0.08);
}

/// What floats over the chat, as a menu does: the surface darkened towards
/// black, in a one pixel edge, over a soft shadow. The glow rings' fill, for
/// what has no ring of its own.
BoxDecoration gaiaFloating(ColorScheme colors, {required double radius}) =>
    BoxDecoration(
      color: Color.lerp(colors.surface, Colors.black, 0.5),
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: GaiaInk.hairline),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.45),
          offset: const Offset(0, 8),
          blurRadius: 24,
          spreadRadius: -6,
        ),
      ],
    );

/// A chip's shadow, as it floats over the chat's text: [gaiaFloating]'s,
/// scaled to a chip.
const kGaiaChipShadow = BoxShadow(
  color: Color(0x4D000000),
  offset: Offset(0, 1),
  blurRadius: 4,
  spreadRadius: -1,
);

/// Gaia's corner radii, by what's rounded.
abstract final class GaiaRadius {
  /// A chip, a menu's row, a small button.
  static const chip = 6.0;

  /// A list's row, a thumbnail.
  static const row = 8.0;

  /// A panel, a card, a bubble.
  static const panel = 12.0;
}

/// How far the chat fades into the surface under what's over its edges:
/// the header, the pinned prompt, the composer and the btw panel.
const kGaiaChatFade = 32.0;

/// [color] easing in from clear at [clear] to itself at [full], fractions of
/// a gradient's length, as colors and stops in order. Eased at both ends: a
/// straight fade shows its ends as edges, which trace what it fades under
/// like a glow round it.
({List<Color> colors, List<double> stops}) gaiaFade(
  Color color, {
  required double clear,
  required double full,
}) {
  const steps = _gaiaFadeSteps;
  final up = clear < full;
  final lo = up ? clear : full, hi = up ? full : clear;
  return (
    colors: [
      for (var k = 0; k <= steps; k++)
        color.withValues(
          alpha:
              color.a *
              Curves.easeInOut.transform(up ? k / steps : 1 - k / steps),
        ),
    ],
    stops: [for (var k = 0; k <= steps; k++) lo + (hi - lo) * k / steps],
  );
}

/// [gaiaFade]'s strength [t] of the way from its clear end to its full one,
/// 0 to 1, stepped as its stops are.
double gaiaFadeAt(double t) {
  final at = t.clamp(0.0, 1.0) * _gaiaFadeSteps;
  final step = at.floor().clamp(0, _gaiaFadeSteps - 1);
  final from = Curves.easeInOut.transform(step / _gaiaFadeSteps);
  final to = Curves.easeInOut.transform((step + 1) / _gaiaFadeSteps);
  return from + (to - from) * (at - step);
}

const _gaiaFadeSteps = 8;

/// The chat's header: room for the buttons' shadows. A divider's 1
/// sits under it.
const kGaiaHeaderHeight = 52.0;

/// Gaia's timings. A state change (hover, selection, a fade) is [quick]; what
/// moves or resizes is [move]; panels grow on the notch's spring.
abstract final class GaiaMotion {
  static const quick = Duration(milliseconds: 150);
  static const move = Duration(milliseconds: 250);

  /// Coming in, and a state changing.
  static const curve = Curves.easeOutCubic;

  /// Travelling from one place to another, as a scroll does.
  static const travel = Curves.easeInOutCubic;
}

/// Gaia's chrome text: everything that isn't a message. Sizes only, so the
/// family and spacing come from the theme's text around it.
abstract final class GaiaType {
  /// A list's row, a menu's item.
  static const row = TextStyle(fontSize: 13, fontWeight: FontWeight.w500);

  /// A trigger, a count, a key's name.
  static const label = TextStyle(fontSize: 12, fontWeight: FontWeight.w500);

  /// What heads a section of a list: small, spaced out and faint, since it
  /// names what's under it and isn't something to click.
  static const heading = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.6,
    color: GaiaInk.faint,
  );
}
