import 'package:flutter/material.dart';

/// Application-wide font family registered in [pubspec.yaml].
abstract final class AppFonts {
  static const family = 'IosevkaAile';

  /// Fixed-pitch sibling of [family], for code. Shares Aile's vertical
  /// metrics exactly, so swapping between the two leaves baselines put.
  static const monoFamily = 'IosevkaMono';

  static TextStyle style({
    double? fontSize,
    FontWeight? fontWeight,
    FontStyle? fontStyle,
    Color? color,
    TextDecoration? decoration,
    double? height,
    double? letterSpacing,
  }) {
    return TextStyle(
      fontFamily: family,
      fontSize: fontSize,
      fontWeight: fontWeight,
      fontStyle: fontStyle,
      color: color,
      decoration: decoration,
      height: height ?? leadingFor(fontSize ?? 14.0),
      letterSpacing: letterSpacing ?? trackingFor(fontSize ?? 14.0),
    );
  }

  /// Applies the family + color, then re-tunes every slot's tracking
  /// (letter-spacing) and leading (line-height) for [family]'s metrics —
  /// Material 3's built-in scale is tuned for its reference font, not this
  /// one. Large text gets negative tracking and tight leading; small text
  /// gets slightly positive tracking and looser leading, continuously
  /// interpolated by size rather than hardcoded per style name.
  static TextTheme applyTo(TextTheme theme, Color textColor) {
    final base = theme.apply(
      fontFamily: family,
      bodyColor: textColor,
      displayColor: textColor,
    );
    return base.copyWith(
      displayLarge: _tuned(base.displayLarge),
      displayMedium: _tuned(base.displayMedium),
      displaySmall: _tuned(base.displaySmall),
      headlineLarge: _tuned(base.headlineLarge),
      headlineMedium: _tuned(base.headlineMedium),
      headlineSmall: _tuned(base.headlineSmall),
      titleLarge: _tuned(base.titleLarge),
      titleMedium: _tuned(base.titleMedium),
      titleSmall: _tuned(base.titleSmall),
      bodyLarge: _tuned(base.bodyLarge),
      bodyMedium: _tuned(base.bodyMedium),
      bodySmall: _tuned(base.bodySmall),
      labelLarge: _tuned(base.labelLarge),
      labelMedium: _tuned(base.labelMedium),
      labelSmall: _tuned(base.labelSmall),
    );
  }

  static TextStyle? _tuned(TextStyle? style) {
    if (style == null) return null;
    final size = style.fontSize ?? 14.0;
    return style.copyWith(
      letterSpacing: trackingFor(size),
      height: leadingFor(size),
    );
  }

  /// Letter-spacing in logical pixels for a given [fontSize]: -0.02em at
  /// display sizes (34+), 0 around body text (16), +0.02em at the smallest
  /// label sizes (11 and below), linearly interpolated between anchors.
  static double trackingFor(double fontSize) {
    double trackingEm;
    if (fontSize >= 34) {
      trackingEm = -0.02;
    } else if (fontSize <= 11) {
      trackingEm = 0.02;
    } else if (fontSize >= 16) {
      trackingEm = (-0.02) * (fontSize - 16) / (34 - 16);
    } else {
      trackingEm = 0.02 * (16 - fontSize) / (16 - 11);
    }
    return trackingEm * fontSize;
  }

  /// Line-height multiplier for a given [fontSize]: tight (1.05) at display
  /// sizes, comfortable (1.5) at the smallest label sizes.
  static double leadingFor(double fontSize) {
    if (fontSize >= 34) return 1.05;
    if (fontSize >= 22) return 1.15;
    if (fontSize >= 16) return 1.35;
    if (fontSize >= 12) return 1.45;
    return 1.5;
  }
}
