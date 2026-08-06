import 'package:flutter/material.dart';

/// Resting and selected backgrounds for shell sidebar list rows.
abstract final class VoyagerListItemSurface {
  static Color restingColor(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Color.lerp(
      colorScheme.surface,
      Theme.of(context).scaffoldBackgroundColor,
      0.18,
    )!.withValues(alpha: 0.25);
  }

  static Color selectedColor(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Color.lerp(
      colorScheme.surface,
      Theme.of(context).scaffoldBackgroundColor,
      0.35,
    )!.withValues(alpha: 0.65);
  }

  static Color hoverColor(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Color.lerp(
      colorScheme.surface,
      Theme.of(context).scaffoldBackgroundColor,
      0.3,
    )!.withValues(alpha: 0.75);
  }

  static BoxDecoration decoration(
    BuildContext context, {
    required bool selected,
    bool hovered = false,
    double borderRadius = 16,
  }) {
    final color = hovered
        ? hoverColor(context)
        : selected
        ? selectedColor(context)
        : restingColor(context);
    return BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(borderRadius),
      border: Border.all(
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.06),
      ),
    );
  }
}
