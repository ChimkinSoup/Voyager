import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/features/leetcode/leetcode_flashcard.dart';

/// Focused flashcard mode: swipe/paginate through every tracked problem.
class LeetCodeReviewDeck extends ConsumerWidget {
  const LeetCodeReviewDeck({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final problemsAsync = ref.watch(leetcodeProblemsProvider);
    final problems = problemsAsync.valueOrNull ?? const [];

    if (problems.isEmpty) {
      return Center(
        child: Text(
          'No problems tracked yet',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return Padding(
      // Extra bottom clearance (vs. a symmetric pad) keeps the card's bottom
      // edge clear of the page's "+ Track" FAB, which sits over the same
      // bottom-right corner.
      padding: const EdgeInsets.fromLTRB(0, 32, 0, 96),
      child: PageView.builder(
        // PageView clips each page to its own viewport slot by default
        // (Clip.hardEdge), which was cutting the flashcard's drop shadow off
        // entirely at every edge. Nothing overlaps behind adjacent pages
        // here, so letting shadows bleed into the gutter is safe.
        clipBehavior: Clip.none,
        itemCount: problems.length,
        controller: PageController(viewportFraction: 0.86),
        itemBuilder: (context, index) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: LeetCodeFlashcard(problem: problems[index]),
        ),
      ),
    );
  }
}
