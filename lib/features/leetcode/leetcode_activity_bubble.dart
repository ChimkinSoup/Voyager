import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:voyager/core/constants/leetcode_constants.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/widgets/chart_hover_bubble.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/features/leetcode/leetcode_activity_data.dart';

/// Gap between the pointer and the bubble it summons, on whichever side the
/// bubble ends up.
const double _kBubbleGap = 10;

/// The hover card both LeetCode activity surfaces show: the day, then how many
/// problems of each difficulty it holds.
///
/// Built on the app's chart bubble chrome ([chartTooltipBubbleColor] and
/// friends) rather than its [ChartHoverBubble] widget, because that widget
/// prints a single value line and this one prints a three-row breakdown. The
/// card around them is deliberately identical — a hover bubble on the LeetCode
/// page should not read as a different kind of object from one on the
/// analytics page.
///
/// All three difficulties are always listed, zeros included and muted, so the
/// bubble keeps its size and its rows stay in the same place as the pointer
/// sweeps across days.
///
/// [only] is the legend's filter: with a tier selected the surface underneath
/// is counting just that tier, and a bubble still reciting all three would be
/// answering a question the page is no longer asking.
class LeetCodeActivityBubble extends StatelessWidget {
  const LeetCodeActivityBubble({
    super.key,
    required this.date,
    required this.counts,
    this.only,
  });

  final DateTime date;
  final LeetCodeDayCounts counts;
  final LeetCodeDifficulty? only;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      type: MaterialType.transparency,
      child: IntrinsicWidth(
        child: Container(
          constraints: const BoxConstraints(minWidth: 96),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: chartTooltipBubbleColor(context),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: VoyagerColors.of(context).hairline),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                child: Text(
                  DateFormat('MMM d, yyyy').format(date),
                  maxLines: 1,
                  softWrap: false,
                  style: chartTooltipDateStyle(theme),
                ),
              ),
              const SizedBox(height: 4),
              for (final difficulty
                  in only == null ? LeetCodeDifficulty.values : [only!])
                _BreakdownRow(
                  difficulty: difficulty,
                  count: counts.countFor(difficulty),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BreakdownRow extends StatelessWidget {
  const _BreakdownRow({required this.difficulty, required this.count});

  final LeetCodeDifficulty difficulty;
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = colorForLeetCodeDifficulty(difficulty);
    // A day with none of this difficulty greys out exactly the way an empty
    // period does on the analytics bubbles — see [chartTooltipMutedValueColor].
    final muted = count == 0;
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: color.withValues(alpha: muted ? 0.3 : 1),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            labelForLeetCodeDifficulty(difficulty),
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: 11,
              color: muted
                  ? chartTooltipMutedValueColor(theme)
                  : theme.colorScheme.onSurface,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '$count',
              textAlign: TextAlign.right,
              style: theme.textTheme.labelSmall?.copyWith(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: muted ? chartTooltipMutedValueColor(theme) : color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Places [child] just above [anchor] inside the [Stack] it is dropped into,
/// clamped so it can never hang off an edge, and flipping below the pointer
/// when there isn't room above.
///
/// Hover bubbles are laid out rather than positioned because the bubble sizes
/// itself to its own text — a [Positioned] would need that size in advance.
class LeetCodeActivityBubbleLayer extends StatelessWidget {
  const LeetCodeActivityBubbleLayer({
    super.key,
    required this.anchor,
    required this.child,
  });

  final Offset anchor;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      // Never steals the pointer: the bubble sits directly under it, and
      // absorbing the hover would make it flicker itself away.
      child: IgnorePointer(
        child: CustomSingleChildLayout(
          delegate: _BubbleLayout(anchor: anchor),
          child: child,
        ),
      ),
    );
  }
}

class _BubbleLayout extends SingleChildLayoutDelegate {
  const _BubbleLayout({required this.anchor});

  final Offset anchor;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    // [loosen] keeps the stack's max height (the short sparkline box). Size to
    // content instead so a taller bubble doesn't assert; host stacks use
    // [Clip.none] so overflow paints rather than clips mid-layout.
    return const BoxConstraints(maxWidth: 280);
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final maxLeft = math.max(0.0, size.width - childSize.width);
    final left = (anchor.dx - childSize.width / 2).clamp(0.0, maxLeft);
    final above = anchor.dy - childSize.height - _kBubbleGap;
    // Prefer above the pointer; if that hangs off the top, flip below. When
    // the bubble is taller than the stack, pin to y=0 and let Clip.none
    // carry the rest.
    final top = above >= 0
        ? above
        : math.min(
            anchor.dy + _kBubbleGap,
            math.max(0.0, size.height - childSize.height),
          );
    return Offset(left, top);
  }

  @override
  bool shouldRelayout(_BubbleLayout oldDelegate) =>
      oldDelegate.anchor != anchor;
}
