import 'package:flutter/material.dart';
import 'package:voyager/core/theme/app_fonts.dart';

/// The worked examples of a problem, one numbered block each.
///
/// "Example 1", "Example 2" … come from list position rather than from the
/// stored text, so deleting an example in the track modal renumbers the rest
/// with nothing to rewrite.
///
/// Bodies are fixed-pitch with their line breaks intact: they hold the
/// Input/Output lines LeetCode shows in a `<pre>`, which only line up in a
/// mono face. [AppFonts.monoFamily] shares the body font's vertical metrics,
/// so the switch costs no baseline drift.
class LeetCodeExamplesView extends StatelessWidget {
  const LeetCodeExamplesView({
    super.key,
    required this.examples,
    this.labelStyle,
    this.bodyStyle,
    this.spacing = 12,
  });

  final List<String> examples;
  final TextStyle? labelStyle;
  final TextStyle? bodyStyle;

  /// Vertical gap between one example and the next.
  final double spacing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label =
        labelStyle ??
        theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        );
    final body = (bodyStyle ?? theme.textTheme.bodyMedium)?.copyWith(
      fontFamily: AppFonts.monoFamily,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < examples.length; i++) ...[
          if (i > 0) SizedBox(height: spacing),
          Text('Example ${i + 1}', style: label),
          const SizedBox(height: 4),
          Text(examples[i], style: body),
        ],
      ],
    );
  }
}
