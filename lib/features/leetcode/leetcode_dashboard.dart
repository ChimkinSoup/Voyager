import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/features/leetcode/leetcode_activity_card.dart';
import 'package:voyager/features/leetcode/leetcode_progress_rings.dart';
import 'package:voyager/features/leetcode/leetcode_recent_completions.dart';
import 'package:voyager/features/leetcode/leetcode_tag_matrix.dart';

/// Width at/above which Recent Completions and the Tag Matrix sit side by
/// side instead of stacking.
const double _kLeetCodeSplitBreakpoint = 720;

/// Width at/above which the 30-day activity card sits beside the progress
/// rings rather than under them. The rings scroll horizontally, so this is
/// about the *card* still having a readable width once it has taken its share
/// — below this it gets a row of its own instead of a sliver.
const double _kLeetCodeActivityBreakpoint = 700;

/// Width the activity card takes beside the rings.
const double _kLeetCodeActivityCardWidth = 280;

/// The Dashboard's top band: the progress rings, with the 30-day activity card
/// filling the space that used to sit empty to their right.
///
/// Narrow, the card drops to a row of its own rather than squeezing in beside
/// rings that are already scrolling.
class LeetCodeDashboardHeader extends StatelessWidget {
  const LeetCodeDashboardHeader({super.key});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < _kLeetCodeActivityBreakpoint) {
          return const Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LeetCodeProgressRings(),
              SizedBox(height: 12),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: LeetCodeActivityCard(),
              ),
            ],
          );
        }
        return const Row(
          children: [
            Expanded(child: LeetCodeProgressRings()),
            SizedBox(width: 8),
            Padding(
              padding: EdgeInsets.only(right: 16),
              child: SizedBox(
                width: _kLeetCodeActivityCardWidth,
                child: LeetCodeActivityCard(),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The least height the recent-completions feed keeps when stacked: a few
/// rows, not the one row the minimum window height left it.
const double _kLeetCodeFeedMinHeight = 240;

/// The tag matrix's height when stacked under the feed.
const double _kLeetCodeStackedMatrixHeight = 160;

/// Room under the stacked matrix for the floating Track button, which
/// otherwise sits over the matrix's right end.
const double _kLeetCodeTrackButtonClearance = 80;

/// Default Dashboard view: progress rings on top, then a responsive split
/// between the recent-completions feed and the tag matrix.
class LeetCodeDashboard extends ConsumerWidget {
  const LeetCodeDashboard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final problemsAsync = ref.watch(leetcodeProblemsProvider.settled);
    final problems = problemsAsync.valueOrNull ?? const [];

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= _kLeetCodeSplitBreakpoint) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 16),
              const LeetCodeDashboardHeader(),
              const SizedBox(height: 20),
              Expanded(
                child: Padding(
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
                ),
              ),
            ],
          );
        }
        // Stacked, the header takes a tall share of a short window. The feed
        // and matrix fill what is left below it, but never less than a
        // usable feed: past that the whole page scrolls and the header
        // scrolls away.
        return CustomScrollView(
          slivers: [
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.only(top: 16, bottom: 20),
                child: LeetCodeDashboardHeader(),
              ),
            ),
            SliverLayoutBuilder(
              builder: (context, sliver) => SliverToBoxAdapter(
                child: SizedBox(
                  height: math.max(
                    sliver.viewportMainAxisExtent -
                        sliver.precedingScrollExtent,
                    _kLeetCodeFeedMinHeight +
                        _kLeetCodeStackedMatrixHeight +
                        _kLeetCodeTrackButtonClearance,
                  ),
                  child: Column(
                    children: [
                      Expanded(
                        child: LeetCodeRecentCompletions(problems: problems),
                      ),
                      SizedBox(
                        height: _kLeetCodeStackedMatrixHeight,
                        child: LeetCodeTagMatrix(problems: problems),
                      ),
                      const SizedBox(height: _kLeetCodeTrackButtonClearance),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
