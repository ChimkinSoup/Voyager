import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/theme/voyager_theme.dart';

double contrast(Color a, Color b) {
  final x = a.computeLuminance();
  final y = b.computeLuminance();
  final lighter = x > y ? x : y;
  final darker = x > y ? y : x;
  return (lighter + 0.05) / (darker + 0.05);
}

/// Hue survives the scale toward black: each channel keeps its share of the
/// fill's total, so the ink is the same color, not a grey.
void expectSameHue(Color ink, Color fill) {
  final inkSum = ink.r + ink.g + ink.b;
  final fillSum = fill.r + fill.g + fill.b;
  expect(ink.r / inkSum, closeTo(fill.r / fillSum, 0.02));
  expect(ink.g / inkSum, closeTo(fill.g / fillSum, 0.02));
  expect(ink.b / inkSum, closeTo(fill.b / fillSum, 0.02));
}

void main() {
  const bone = Color(0xFFE6E6EA); // VoyagerPalette.dark.onSurface
  const slate = Color(0xFF2B303B); // VoyagerPalette.light.onSurface

  group('chromatic fills get a hue-linked ink', () {
    // The accent that motivated the change: white on it is ~1.8:1.
    const pastel = Color(0xFFB7BDF8);

    test('the pale accent no longer keeps white', () {
      final label = onColorLabel(pastel, themeInk: slate);
      expect(label, isNot(Colors.white));
      expect(contrast(label, pastel), greaterThanOrEqualTo(4.5));
      expectSameHue(label, pastel);
    });

    test('pure yellow clears the floor without going neutral', () {
      const yellow = Color(0xFFFFD700);
      final label = onColorLabel(yellow, themeInk: slate);
      expect(label, isNot(slate));
      expect(contrast(label, yellow), greaterThanOrEqualTo(4.5));
      expectSameHue(label, yellow);
    });

    test('near-white resolves to a readable ink', () {
      const nearWhite = Color(0xFFFAFAF5);
      final label = onColorLabel(nearWhite, themeInk: slate);
      expect(contrast(label, nearWhite), greaterThanOrEqualTo(4.5));
    });

    test('the same ink is chosen under either theme', () {
      expect(
        onColorLabel(pastel, themeInk: slate),
        onColorLabel(pastel, themeInk: bone),
      );
    });
  });

  group('dark fills keep a light label', () {
    const navy = Color(0xFF1B2A4A);
    const nearBlack = Color(0xFF1E1E28);

    test('dark navy takes the light candidate, not a scaled ink', () {
      final label = onColorLabel(navy, themeInk: slate);
      expect(label, Colors.white);
      expect(contrast(label, navy), greaterThanOrEqualTo(4.5));
    });

    test('near-black takes white on the cream theme', () {
      expect(onColorLabel(nearBlack, themeInk: slate), Colors.white);
    });

    test('near-black takes theme bone on the dark theme', () {
      final label = onColorLabel(nearBlack, themeInk: bone);
      expect(label, bone);
      expect(contrast(label, nearBlack), greaterThanOrEqualTo(4.5));
    });

    test('an explicit light candidate wins over the theme ink', () {
      expect(
        onColorLabel(nearBlack, light: bone, themeInk: slate),
        bone,
      );
    });
  });

  test('every palette swatch gets a label that clears the floor', () {
    const swatches = <Color>[
      Color(0xFFF2D5CF),
      Color(0xFFEEBEBE),
      Color(0xFFF4B8E4),
      Color(0xFFCA9EE6),
      Color(0xFFE78284),
      Color(0xFFEA999C),
      Color(0xFFEF9F76),
      Color(0xFFE5C890),
      Color(0xFFA6D189),
      Color(0xFF81C8BE),
      Color(0xFF99D1DB),
      Color(0xFF85C1DC),
      Color(0xFF8CAAEE),
      Color(0xFFBABBF1),
    ];
    for (final swatch in swatches) {
      for (final ink in [slate, bone]) {
        expect(
          contrast(onColorLabel(swatch, themeInk: ink), swatch),
          greaterThanOrEqualTo(4.5),
          reason: '$swatch under $ink',
        );
      }
    }
  });

  test('the theme exposes the resolved label as onPrimary and onAccent', () {
    const pastel = Color(0xFFB7BDF8);
    for (final theme in [
      VoyagerTheme.dark(accent: pastel),
      VoyagerTheme.light(accent: pastel),
    ]) {
      final expected = onColorLabel(
        pastel,
        themeInk: theme.colorScheme.onSurface,
      );
      expect(theme.colorScheme.onPrimary, expected);
      expect(theme.extension<VoyagerColors>()!.onAccent, expected);
    }
  });
}
