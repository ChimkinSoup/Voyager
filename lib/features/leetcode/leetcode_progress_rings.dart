import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/constants/leetcode_constants.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/leetcode_api_models.dart';
import 'package:voyager/features/finance/geometric_progress_ring.dart';

/// The Dashboard's top section: a main "total solved" ring plus one ring per
/// difficulty tier, each filled against that tier's total available problems.
class LeetCodeProgressRings extends ConsumerWidget {
  const LeetCodeProgressRings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final problemsAsync = ref.watch(leetcodeProblemsProvider);
    final countsAsync = ref.watch(leetcodeQuestionCountsProvider);

    final problems = problemsAsync.valueOrNull ?? const [];
    final counts = countsAsync.valueOrNull;

    final solvedByDifficulty = <LeetCodeDifficulty, int>{
      for (final d in LeetCodeDifficulty.values) d: 0,
    };
    for (final p in problems) {
      solvedByDifficulty[p.difficulty] = (solvedByDifficulty[p.difficulty] ?? 0) + 1;
    }
    final totalSolved = problems.length;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          _RingTile(
            size: 132,
            progress: counts == null || counts.total == 0
                ? 0
                : totalSolved / counts.total,
            color: accent,
            gradientColors: [accent.withValues(alpha: 0.55), accent],
            label: counts == null
                ? '$totalSolved solved'
                : '$totalSolved / ${counts.total}',
          ),
          const SizedBox(width: 16),
          for (final d in LeetCodeDifficulty.values) ...[
            _RingTile(
              size: 96,
              progress: _progressFor(d, counts, solvedByDifficulty[d] ?? 0),
              color: colorForLeetCodeDifficulty(d),
              label:
                  '${solvedByDifficulty[d] ?? 0}${counts == null ? '' : '/${_totalFor(d, counts)}'}',
              caption: labelForLeetCodeDifficulty(d),
            ),
            const SizedBox(width: 16),
          ],
        ],
      ),
    );
  }

  double _progressFor(
    LeetCodeDifficulty d,
    LeetCodeQuestionCounts? counts,
    int solved,
  ) {
    final total = counts == null ? 0 : _totalFor(d, counts);
    if (total == 0) return 0;
    return solved / total;
  }

  int _totalFor(LeetCodeDifficulty d, LeetCodeQuestionCounts counts) => switch (d) {
    LeetCodeDifficulty.easy => counts.easy,
    LeetCodeDifficulty.medium => counts.medium,
    LeetCodeDifficulty.hard => counts.hard,
  };
}

class _RingTile extends StatelessWidget {
  const _RingTile({
    required this.size,
    required this.progress,
    required this.color,
    required this.label,
    this.gradientColors,
    this.caption,
  });

  final double size;
  final double progress;
  final Color color;
  final String label;
  final List<Color>? gradientColors;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GeometricProgressRing(
          progress: progress,
          color: color,
          gradientColors: gradientColors,
          size: size,
          strokeWidth: size >= 120 ? 10 : 8,
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: (size >= 120
                    ? theme.textTheme.titleMedium
                    : theme.textTheme.titleSmall)
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
        if (caption != null) ...[
          const SizedBox(height: 6),
          Text(
            caption!,
            style: theme.textTheme.labelMedium?.copyWith(color: color),
          ),
        ],
      ],
    );
  }
}
