import 'package:flutter/material.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';
import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/core/theme/voyager_theme.dart';

/// A visually dense cluster of tag pills sized by how often each tag appears
/// across tracked problems — client-side aggregation, no dedicated query.
class LeetCodeTagMatrix extends StatelessWidget {
  const LeetCodeTagMatrix({super.key, required this.problems});

  final List<LeetCodeProblem> problems;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Counted ignoring case, under the first spelling met: problems saved
    // before tags were folded can carry both `#Draft` and `#draft`.
    final counts = <String, int>{};
    final spellings = <String, String>{};
    for (final p in problems) {
      for (final tag in p.tags.map((t) => t.toLowerCase()).toSet()) {
        counts[tag] = (counts[tag] ?? 0) + 1;
      }
      for (final tag in p.tags) {
        spellings.putIfAbsent(tag.toLowerCase(), () => tag);
      }
    }
    if (counts.isEmpty) {
      return Center(
        child: Text(
          'No tags yet',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    final entries = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final maxCount = entries.first.value;

    return VoyagerScrollView(
      padding: const EdgeInsets.all(12),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final entry in entries)
            _WeightedTagPill(
              tag: spellings[entry.key]!,
              count: entry.value,
              weight: entry.value / maxCount,
            ),
        ],
      ),
    );
  }
}

class _WeightedTagPill extends StatelessWidget {
  const _WeightedTagPill({
    required this.tag,
    required this.count,
    required this.weight,
  });

  final String tag;
  final int count;
  final double weight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final fontSize = 11.0 + weight * 6.0;
    final fill = accent.withValues(alpha: 0.08 + weight * 0.18);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(VoyagerTheme.fieldRadius),
      ),
      child: Text(
        // The tag in a first-strong isolate (FSI … PDI), so a right-to-left
        // tag can't pull the count into its run: "#مرحبا (1)", not
        // "#(1) مرحبا" (BUG-154).
        '#\u2068$tag\u2069 ($count)',
        style: theme.textTheme.labelMedium?.copyWith(
          fontSize: fontSize,
          // Light darkens the accent to read on the pale fill (BUG-153).
          color: themedLabelInk(
            theme,
            accent,
            background: Color.alphaBlend(fill, theme.scaffoldBackgroundColor),
          ),
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}
