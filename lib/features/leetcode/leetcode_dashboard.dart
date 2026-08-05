import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/features/leetcode/leetcode_progress_rings.dart';
import 'package:voyager/features/leetcode/leetcode_recent_completions.dart';
import 'package:voyager/features/leetcode/leetcode_tag_matrix.dart';

/// Width at/above which Recent Completions and the Tag Matrix sit side by
/// side instead of stacking.
const double _kLeetCodeSplitBreakpoint = 720;

/// Default Dashboard view: progress rings on top, then a responsive split
/// between the recent-completions feed and the tag matrix.
class LeetCodeDashboard extends ConsumerWidget {
  const LeetCodeDashboard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final problemsAsync = ref.watch(leetcodeProblemsProvider);
    final problems = problemsAsync.valueOrNull ?? const [];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 16),
        const LeetCodeProgressRings(),
        const SizedBox(height: 20),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= _kLeetCodeSplitBreakpoint;
              if (wide) {
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        flex: 7,
                        child: LeetCodeRecentCompletions(problems: problems),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 3,
                        child: LeetCodeTagMatrix(problems: problems),
                      ),
                    ],
                  ),
                );
              }
              return Column(
                children: [
                  Expanded(
                    child: LeetCodeRecentCompletions(problems: problems),
                  ),
                  SizedBox(
                    height: 160,
                    child: LeetCodeTagMatrix(problems: problems),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}
