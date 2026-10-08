import 'package:flutter/material.dart';
import 'package:voyager/core/constants/leetcode_constants.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/domain/models/enums.dart';

/// A problem's difficulty as a small chip tinted with its tier colour.
///
/// One widget owns both the fill and the label, because the label's colour
/// depends on the fill: Light darkens the tier colour, hue kept, until it
/// clears 4.5:1 on the chip (BUG-153: Medium's yellow was about 1.5:1 on
/// cream); Dark keeps LeetCode's own colours. Measured against the scaffold,
/// the darkest of Light's cream surfaces, so a chip on a card clears it too.
class LeetCodeDifficultyChip extends StatelessWidget {
  const LeetCodeDifficultyChip(
    this.difficulty, {
    super.key,
    this.tint = 0.14,
    this.padding = const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    this.style,
  });

  final LeetCodeDifficulty difficulty;

  /// Alpha of the tier colour in the fill.
  final double tint;

  final EdgeInsetsGeometry padding;

  /// Merged over `labelSmall`; its colour is ignored.
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = colorForLeetCodeDifficulty(difficulty);
    final fill = color.withValues(alpha: tint);
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(VoyagerTheme.fieldRadius),
      ),
      child: Text(
        labelForLeetCodeDifficulty(difficulty),
        style: theme.textTheme.labelSmall
            ?.merge(style)
            .copyWith(
              color: themedLabelInk(
                theme,
                color,
                background: Color.alphaBlend(
                  fill,
                  theme.scaffoldBackgroundColor,
                ),
              ),
            ),
      ),
    );
  }
}
