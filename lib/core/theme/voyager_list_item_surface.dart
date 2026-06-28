import 'package:flutter/material.dart';

/// Resting and selected backgrounds for shell sidebar list rows.
abstract final class VoyagerListItemSurface {
  static Color restingColor(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Color.lerp(
          colorScheme.surface,
          Theme.of(context).scaffoldBackgroundColor,
          0.18,
        )!
        .withValues(alpha: 0.25);
  }

  static Color selectedColor(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Color.lerp(
          colorScheme.surface,
          Theme.of(context).scaffoldBackgroundColor,
          0.35,
        )!
        .withValues(alpha: 0.92);
  }

  static BoxDecoration decoration(
    BuildContext context, {
    required bool selected,
    double borderRadius = 16,
  }) {
    return BoxDecoration(
      color: selected ? selectedColor(context) : restingColor(context),
      borderRadius: BorderRadius.circular(borderRadius),
    );
  }
}
