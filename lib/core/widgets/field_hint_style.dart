import 'package:flutter/material.dart';

/// The placeholder style for a field whose text renders in [style].
///
/// A hint has to occupy exactly the line box the text replacing it will, or
/// the field stands at one height with the placeholder showing and another the
/// instant a character is typed — the box visibly shrinks under the cursor on
/// the first keystroke.
///
/// The theme's own `hintStyle` is a smaller type slot with its own line height,
/// which is precisely that mismatch for any field that tightens its text style
/// (a dense one pins the height to 1.0, well under the hint's). So the metrics
/// are taken from the field and only the colour from the theme: a placeholder
/// still reads as quieter than real input, it just no longer changes the shape
/// of the box it sits in.
TextStyle? fieldHintStyle(BuildContext context, TextStyle? style) {
  if (style == null) return null;
  final theme = Theme.of(context);
  return style.copyWith(
    color:
        theme.inputDecorationTheme.hintStyle?.color ??
        theme.colorScheme.onSurface.withValues(alpha: 0.55),
  );
}
