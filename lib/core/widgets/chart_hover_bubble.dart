import 'package:flutter/material.dart';
import 'package:voyager/core/theme/voyager_theme.dart';

/// The app's chart hover bubble: a small opaque card printing what period the
/// pointer is on and what the series reads there.
///
/// It started on the analytics page (heatmap squares, sparklines, the morph
/// editor that grows out of one) and lives here because the finance charts
/// want the identical thing. Reading the same two lines in two different
/// shapes on two pages of the same app is the kind of drift that makes a UI
/// feel assembled rather than designed, so both surfaces build from this
/// rather than from two sets of matching constants.

/// Fill for a hover bubble.
///
/// Opaque, deliberately. The obvious choice is a translucent panel tone, but
/// these bubbles are drawn over charts that already have washes and hover
/// rectangles behind them, and those read straight through and make the text
/// hard to follow. Blending against the surface keeps the bubble reading as
/// something sitting *above* the chart rather than tinting it.
Color chartTooltipBubbleColor(BuildContext context) {
  final theme = Theme.of(context);
  final base =
      theme.inputDecorationTheme.fillColor ??
      theme.cardTheme.color ??
      theme.colorScheme.surface;
  return Color.alphaBlend(base, theme.colorScheme.surface);
}

/// The greyed shade a bubble's value line takes when it isn't showing
/// something the user recorded — the "–" of a period with no entry, and an
/// interpolated reading between two real ones.
///
/// One function so the two can't drift: they mean the same thing to the reader
/// ("this isn't your data"), so they have to look the same.
Color chartTooltipMutedValueColor(ThemeData theme) =>
    theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5);

/// Style of a bubble's period line — small, and quieter than the value it
/// labels.
TextStyle chartTooltipDateStyle(ThemeData theme) {
  return (theme.textTheme.bodySmall ?? const TextStyle()).copyWith(
    inherit: false,
    color: theme.colorScheme.onSurfaceVariant,
    fontSize: 10,
  );
}

/// A bubble's date + value content, without the card around it.
///
/// Split out from [ChartHoverBubble] because the analytics page's morph
/// popover reconstructs the bubble's interior inside a *different* container
/// while it animates into the value editor, and the two have to lay out
/// identically or the value text visibly jumps the instant the editor opens.
/// [dateKey] and [dateOpacity] exist for that: the popover measures the date's
/// rect to hand a separate sliding layer, and hides the copy underneath it.
///
/// Wrapped in its own transparent [Material] rather than relying on an ambient
/// one from a caller: the value [Text] sets no line height of its own, so it
/// would otherwise inherit whatever [DefaultTextStyle] happened to be nearest
/// above it and resolve a different vertical position in each of the two
/// places it is built.
Widget chartTooltipDateValueColumn({
  required String periodLabel,
  required String? valueLabel,
  required ThemeData theme,
  Key? dateKey,
  double dateOpacity = 1,
  Color? valueColor,
}) {
  return Material(
    type: MaterialType.transparency,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Both lines are held to one line: the bubble sizes itself to its own
        // text, so letting them wrap would break a long value across two lines
        // mid-number instead of widening the bubble to fit it.
        //
        // The date is centred *and* shrink-wrapped by the [Align] rather than
        // stretched. Both matter for short labels — a year, or anything
        // narrower than the bubble's minimum width: stretched, the date's box
        // spans the full width and its glyphs sit at the right edge while the
        // value below them sits centred, so the two lines visibly disagree.
        Opacity(
          opacity: dateOpacity,
          child: Align(
            child: Text(
              periodLabel,
              key: dateKey,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: chartTooltipDateStyle(theme),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          valueLabel ?? '–',
          textAlign: TextAlign.center,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: valueLabel == null
                ? chartTooltipMutedValueColor(theme)
                : (valueColor ?? theme.colorScheme.onSurface),
            fontWeight: FontWeight.normal,
            fontSize: 14,
          ),
        ),
      ],
    ),
  );
}

/// The finished bubble: [chartTooltipDateValueColumn] in the app's hover card.
///
/// Sized to its own content by [IntrinsicWidth], with a floor so a two-digit
/// reading doesn't produce a bubble narrower than it is tall.
class ChartHoverBubble extends StatelessWidget {
  const ChartHoverBubble({
    super.key,
    required this.periodLabel,
    required this.valueLabel,
    this.valueColor,
  });

  final String periodLabel;
  final String? valueLabel;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return IntrinsicWidth(
      child: Container(
        constraints: const BoxConstraints(minWidth: 64),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: chartTooltipBubbleColor(context),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: VoyagerColors.of(context).hairline),
        ),
        child: chartTooltipDateValueColumn(
          periodLabel: periodLabel,
          valueLabel: valueLabel,
          valueColor: valueColor,
          theme: theme,
        ),
      ),
    );
  }
}
