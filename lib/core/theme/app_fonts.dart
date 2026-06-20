import 'package:flutter/material.dart';

/// Application-wide font family registered in [pubspec.yaml].
abstract final class AppFonts {
  static const family = 'IosevkaAile';

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
      height: height,
      letterSpacing: letterSpacing,
    );
  }

  static TextTheme applyTo(TextTheme theme, Color textColor) {
    return theme.apply(
      fontFamily: family,
      bodyColor: textColor,
      displayColor: textColor,
    );
  }
}
