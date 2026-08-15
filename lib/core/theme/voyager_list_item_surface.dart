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

  /// Outline for the row whose content is open in the page's editor or detail
  /// pane — the entry you are reading, the task you are editing.
  static Color focusBorderColor(BuildContext context) =>
      Theme.of(context).colorScheme.outline.withValues(alpha: 0.35);

  static Color _restingBorderColor(BuildContext context) =>
      Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.06);

  /// [ListTile.shape] for sidebar rows, outlined while [focused].
  ///
  /// The unfocused side is transparent rather than [BorderSide.none]: a
  /// [ShapeDecoration] pads its child by `shape.dimensions`, which is the
  /// side's width — so a border that appears out of nothing makes the row two
  /// pixels taller, and every row below it jumps as the selection moves. A
  /// side that is always one pixel wide and only changes colour holds the
  /// geometry still.
  static RoundedRectangleBorder focusShape(
    BuildContext context, {
    required bool focused,
    double borderRadius = 12,
  }) {
    return RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(borderRadius),
      side: BorderSide(
        color: focused ? focusBorderColor(context) : Colors.transparent,
      ),
    );
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
        color: selected
            ? focusBorderColor(context)
            : _restingBorderColor(context),
      ),
    );
  }
}
