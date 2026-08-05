import 'package:flutter/material.dart';
import 'package:voyager/domain/models/leetcode_models.dart';

/// A visually dense cluster of tag pills sized by how often each tag appears
/// across tracked problems — client-side aggregation, no dedicated query.
class LeetCodeTagMatrix extends StatelessWidget {
  const LeetCodeTagMatrix({super.key, required this.problems});

  final List<LeetCodeProblem> problems;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final counts = <String, int>{};
    for (final p in problems) {
      for (final tag in p.tags) {
        counts[tag] = (counts[tag] ?? 0) + 1;
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

    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final entry in entries)
            _WeightedTagPill(
              tag: entry.key,
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.08 + weight * 0.18),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '#$tag ($count)',
        style: theme.textTheme.labelMedium?.copyWith(
          fontSize: fontSize,
          color: accent,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}
