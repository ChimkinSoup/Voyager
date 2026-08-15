import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/theme/app_fonts.dart';
import 'package:voyager/core/theme/voyager_theme.dart';

/// [AppFonts.applyTo] derives leading and tracking from each slot's font size,
/// so it has to be handed a text theme that *has* sizes. A raw [ThemeData]'s
/// is colour-only — Material merges the geometry in later, inside the [Theme]
/// widget — and tuning that one silently sizes all fifteen slots as 14px. The
/// merge that follows keeps whatever is already non-null, so the wrong leading
/// survives it and only the sizes look right.
void main() {
  test('every text slot is tuned for its own size', () {
    for (final theme in [VoyagerTheme.light(), VoyagerTheme.dark()]) {
      final slots = <String, TextStyle?>{
        'displayLarge': theme.textTheme.displayLarge,
        'displayMedium': theme.textTheme.displayMedium,
        'displaySmall': theme.textTheme.displaySmall,
        'headlineLarge': theme.textTheme.headlineLarge,
        'headlineMedium': theme.textTheme.headlineMedium,
        'headlineSmall': theme.textTheme.headlineSmall,
        'titleLarge': theme.textTheme.titleLarge,
        'titleMedium': theme.textTheme.titleMedium,
        'titleSmall': theme.textTheme.titleSmall,
        'bodyLarge': theme.textTheme.bodyLarge,
        'bodyMedium': theme.textTheme.bodyMedium,
        'bodySmall': theme.textTheme.bodySmall,
        'labelLarge': theme.textTheme.labelLarge,
        'labelMedium': theme.textTheme.labelMedium,
        'labelSmall': theme.textTheme.labelSmall,
      };

      for (final entry in slots.entries) {
        final style = entry.value!;
        final size = style.fontSize;
        expect(size, isNotNull, reason: '${entry.key} lost its font size');
        expect(
          style.height,
          AppFonts.leadingFor(size!),
          reason: '${entry.key} ($size px) has leading for the wrong size',
        );
        expect(
          style.letterSpacing,
          closeTo(AppFonts.trackingFor(size), 0.0001),
          reason: '${entry.key} ($size px) has tracking for the wrong size',
        );
      }
    }
  });

  test('large text gets tighter leading than small text', () {
    final t = VoyagerTheme.light().textTheme;
    expect(t.headlineMedium!.height, lessThan(t.bodySmall!.height!));
    expect(t.headlineMedium!.letterSpacing, isNegative);
  });
}
