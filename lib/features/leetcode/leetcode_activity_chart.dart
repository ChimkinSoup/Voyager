import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:voyager/core/constants/leetcode_constants.dart';
import 'package:voyager/core/motion/motion.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/features/analytics/stat_number_format.dart';
import 'package:voyager/features/calendar/calendar_day_grid.dart';
import 'package:voyager/features/leetcode/leetcode_activity_bubble.dart';
import 'package:voyager/features/leetcode/leetcode_activity_data.dart';

/// Horizontal gridlines the expanded sparkline draws, baseline included. The
/// dashboard card draws none: at ~70px of plot height they read as noise, the
/// same call the analytics tile makes.
const int _kGridLines = 4;

/// Days between dated labels on the expanded chart's X axis — a week, so the
/// 30-day window gets five labels instead of a solid run of them.
const int _kBottomTitleInterval = 7;

/// The three difficulty curves over the same 30 days, drawn on shared axes so
/// they overlap and can be read against each other.
///
/// Each series is a plain per-day count: a day with nothing solved reads 0
/// rather than being interpolated across, which is what keeps the three curves
/// telling the truth about *when* the work happened.
///
/// [compact] is the dashboard card — line work only, no axes and no hover.
/// Full size adds the axes, gridlines and the hover breakdown bubble.
///
/// [selected] narrows the plot to a single tier, driven by the legend. The Y
/// axis rescales with it: a Hard-only view of a month that ran on mediums would
/// otherwise be a flat line pinned to the baseline.
class LeetCodeActivityChart extends StatefulWidget {
  const LeetCodeActivityChart({
    super.key,
    required this.window,
    this.compact = false,
    this.selected,
  });

  final List<({DateTime date, LeetCodeDayCounts counts})> window;
  final bool compact;
  final LeetCodeDifficulty? selected;

  @override
  State<LeetCodeActivityChart> createState() => _LeetCodeActivityChartState();
}

class _LeetCodeActivityChartState extends State<LeetCodeActivityChart> {
  /// Index into [LeetCodeActivityChart.window] the pointer is resting on, and
  /// where in the chart's own box it is. Both are cleared together — a bubble
  /// with no pointer to sit under has nowhere to be.
  int? _hoverIndex;
  Offset? _hoverPosition;

  void _clearHover() {
    if (_hoverIndex == null && _hoverPosition == null) return;
    setState(() {
      _hoverIndex = null;
      _hoverPosition = null;
    });
  }

  void _handleTouch(FlTouchEvent event, LineTouchResponse? response) {
    final hits = response?.lineBarSpots;
    final position = event.localPosition;
    if (!event.isInterestedForInteractions ||
        position == null ||
        hits == null ||
        hits.isEmpty) {
      _clearHover();
      return;
    }
    // Every difficulty has a spot on every day, so all three curves report the
    // same index — the first hit is as good as any of them.
    final index = hits.first.spotIndex;
    if (index < 0 || index >= widget.window.length) {
      _clearHover();
      return;
    }
    if (_hoverIndex == index && _hoverPosition == position) return;
    setState(() {
      _hoverIndex = index;
      _hoverPosition = position;
    });
  }

  List<FlSpot> _spotsFor(LeetCodeDifficulty difficulty) => [
    for (var i = 0; i < widget.window.length; i++)
      FlSpot(
        i.toDouble(),
        widget.window[i].counts.countFor(difficulty).toDouble(),
      ),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final window = widget.window;
    if (window.isEmpty) return const SizedBox.shrink();

    final shown = widget.selected == null
        ? LeetCodeDifficulty.values
        : [widget.selected!];

    final dataMax = window.fold<double>(0, (max, day) {
      final busiest = [
        for (final d in shown) day.counts.countFor(d),
      ].reduce((a, b) => a > b ? a : b).toDouble();
      return busiest > max ? busiest : max;
    });

    // Compact fills its box: a card two problems tall shouldn't waste half its
    // height on headroom for gridlines it isn't drawing. Full size rounds out
    // to whole steps so the labelled ticks are round numbers.
    final yStep = niceAxisStep(dataMax, _kGridLines);
    final maxY = widget.compact
        ? (dataMax <= 0 ? 1.0 : dataMax * 1.25)
        : yStep * (_kGridLines - 1);

    final bars = [for (final difficulty in shown) _barFor(difficulty, theme)];

    // Compact normally skips hover so the card's tap-to-expand isn't stolen by
    // the plot.
    final hoverEnabled = !widget.compact;

    final chart = LineChart(
      LineChartData(
        showingTooltipIndicators: const [],
        lineTouchData: LineTouchData(
          enabled: hoverEnabled,
          // The bubble is [LeetCodeActivityBubble], drawn in the stack below,
          // so fl_chart's own tooltip stays off.
          handleBuiltInTouches: false,
          // Large enough that hovering anywhere over the plot resolves to the
          // nearest day instead of leaving dead gaps between the curves.
          touchSpotThreshold: 10000,
          touchCallback: _handleTouch,
          getTouchedSpotIndicator: (barData, spotIndexes) => [
            for (final _ in spotIndexes)
              TouchedSpotIndicatorData(
                // The vertical line is drawn once via [ExtraLinesData] below —
                // three curves each drawing their own would stack up into a
                // thick band.
                const FlLine(color: Colors.transparent),
                FlDotData(
                  getDotPainter: (spot, percent, bar, index) =>
                      FlDotCirclePainter(
                        radius: 3,
                        color: barData.color ?? theme.colorScheme.primary,
                        strokeWidth: 0,
                      ),
                ),
              ),
          ],
        ),
        extraLinesData: ExtraLinesData(
          verticalLines: [
            if (_hoverIndex != null)
              VerticalLine(
                x: _hoverIndex!.toDouble(),
                color: theme.colorScheme.onSurface.withValues(alpha: 0.25),
                strokeWidth: 1,
              ),
          ],
        ),
        minX: 0,
        maxX: (window.length - 1).toDouble(),
        minY: 0,
        maxY: maxY,
        gridData: FlGridData(
          show: !widget.compact,
          drawVerticalLine: true,
          verticalInterval: _kBottomTitleInterval.toDouble(),
          horizontalInterval: yStep,
          getDrawingVerticalLine: (_) => FlLine(
            color: theme.colorScheme.outline.withValues(alpha: 0.10),
            strokeWidth: 1,
          ),
          getDrawingHorizontalLine: (_) => FlLine(
            color: theme.colorScheme.outline.withValues(alpha: 0.10),
            strokeWidth: 1,
          ),
        ),
        titlesData: widget.compact
            ? const FlTitlesData(show: false)
            : FlTitlesData(
                rightTitles: const AxisTitles(
                  sideTitles: SideTitles(showTitles: false),
                ),
                topTitles: const AxisTitles(
                  sideTitles: SideTitles(showTitles: false),
                ),
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: axisReservedSize(maxY, 9, 8),
                    interval: yStep,
                    getTitlesWidget: (value, meta) => SideTitleWidget(
                      meta: meta,
                      space: 8,
                      child: Text(
                        compactNumberLabel(value),
                        maxLines: 1,
                        softWrap: false,
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontSize: 9,
                        ),
                      ),
                    ),
                  ),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 26,
                    interval: _kBottomTitleInterval.toDouble(),
                    getTitlesWidget: (value, meta) {
                      final index = value.round();
                      if (index < 0 || index >= window.length) {
                        return const SizedBox.shrink();
                      }
                      // fl_chart labels the axis maximum on top of the ticks
                      // the interval asks for, which crowded the last week's
                      // label against the final day's. Only days that land on
                      // the interval — the same days the vertical gridlines
                      // are drawn on — get one.
                      if (index % _kBottomTitleInterval != 0) {
                        return const SizedBox.shrink();
                      }
                      return SideTitleWidget(
                        meta: meta,
                        space: 8,
                        child: Text(
                          DateFormat('MMM d').format(window[index].date),
                          style: theme.textTheme.labelSmall?.copyWith(
                            fontSize: 9,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
        borderData: FlBorderData(
          show: !widget.compact,
          border: Border(
            bottom: BorderSide(color: VoyagerColors.of(context).strongHairline),
            left: BorderSide(color: VoyagerColors.of(context).strongHairline),
          ),
        ),
        lineBarsData: bars,
      ),
      // fl_chart implicitly lerps every [LineChartData] change over 150ms, and
      // that includes the hover line's x — so the line crawled after the
      // pointer instead of snapping to the day under it, and re-lerped all
      // three series spot by spot on every frame of the crawl. The only thing
      // that changes this data is the hover itself, so there is nothing left
      // worth animating.
      duration: Duration.zero,
    );

    final hoverIndex = _hoverIndex;
    final hoverPosition = _hoverPosition;
    if (!hoverEnabled || hoverIndex == null || hoverPosition == null) {
      return chart;
    }
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(child: chart),
        LeetCodeActivityBubbleLayer(
          anchor: hoverPosition,
          child: LeetCodeActivityBubble(
            date: window[hoverIndex].date,
            counts: window[hoverIndex].counts,
            only: widget.selected,
          ),
        ),
      ],
    );
  }

  LineChartBarData _barFor(LeetCodeDifficulty difficulty, ThemeData theme) {
    final color = colorForLeetCodeDifficulty(difficulty);
    return LineChartBarData(
      spots: _spotsFor(difficulty),
      // Straight segments, unlike the analytics sparklines. Those plot a value
      // interpolated across every day, where a curve is telling the truth;
      // these are counts of a single day, and splining them turned a day with
      // three solves into a bell that claimed work on the two days either
      // side of it.
      isCurved: false,
      color: color.withValues(alpha: 0.9),
      barWidth: widget.compact ? 1.5 : 2,
      dotData: const FlDotData(show: false),
      // Much fainter than the analytics sparkline's 30% wash: three of these
      // overlap here, and at that strength the overlaps read as a fourth
      // colour rather than as two series crossing.
      belowBarData: BarAreaData(
        show: true,
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0.10), color.withValues(alpha: 0.0)],
        ),
      ),
      showingIndicators: _hoverIndex == null ? const [] : [_hoverIndex!],
    );
  }
}

/// The difficulty key, with each tier's total across the window beside it.
///
/// Three overlapping curves in three colours need naming somewhere, and the
/// totals are the reading the curves can't give — a month's worth of "how many
/// mediums, in the end".
///
/// Given [onSelect] it stops being a key and becomes the filter: each tier is a
/// capsule that fills with its own colour when it is the one being shown, and
/// tapping the filled one clears back to all three.
class LeetCodeActivityLegend extends StatelessWidget {
  const LeetCodeActivityLegend({
    super.key,
    required this.window,
    this.compact = false,
    this.selected,
    this.onSelect,
  });

  final List<({DateTime date, LeetCodeDayCounts counts})> window;
  final bool compact;
  final LeetCodeDifficulty? selected;
  final ValueChanged<LeetCodeDifficulty>? onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onSelect = this.onSelect;
    return Wrap(
      spacing: compact ? 10 : 8,
      runSpacing: 4,
      children: [
        for (final difficulty in LeetCodeDifficulty.values)
          if (onSelect != null)
            _LegendCapsule(
              difficulty: difficulty,
              total: _totalFor(difficulty),
              active: selected == difficulty,
              dimmed: selected != null && selected != difficulty,
              onTap: () => onSelect(difficulty),
            )
          else
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: colorForLeetCodeDifficulty(difficulty),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 5),
                Text(
                  compact
                      ? '${_totalFor(difficulty)}'
                      : '${labelForLeetCodeDifficulty(difficulty)} '
                            '${_totalFor(difficulty)}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontSize: 11,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
      ],
    );
  }

  int _totalFor(LeetCodeDifficulty difficulty) =>
      window.fold(0, (sum, day) => sum + day.counts.countFor(difficulty));
}

/// One tier's filter capsule: a tinted pill at rest, solid in the tier's colour
/// once it is the selection, faded while a *different* tier holds it.
class _LegendCapsule extends StatelessWidget {
  const _LegendCapsule({
    required this.difficulty,
    required this.total,
    required this.active,
    required this.dimmed,
    required this.onTap,
  });

  final LeetCodeDifficulty difficulty;
  final int total;
  final bool active;
  final bool dimmed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = colorForLeetCodeDifficulty(difficulty);
    final duration = VoyagerMotion.reduced(context)
        ? Duration.zero
        : const Duration(milliseconds: 180);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedOpacity(
          opacity: dimmed ? 0.45 : 1.0,
          duration: duration,
          curve: VoyagerSpring.snappyCurve,
          // One tween drives the fill, the border, the dot and the text
          // together: animating the pill's colour on its own would leave the
          // label's white sitting on a still-pale background halfway through.
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(end: active ? 1 : 0),
            duration: duration,
            curve: VoyagerSpring.snappyCurve,
            builder: (context, t, _) {
              final onFill = Color.lerp(
                theme.colorScheme.onSurfaceVariant,
                calendarContrastingLabelColor(color),
                t,
              )!;
              return Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: Color.lerp(color.withValues(alpha: 0.10), color, t),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: Color.lerp(color.withValues(alpha: 0.30), color, t)!,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: Color.lerp(color, onFill, t),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      '${labelForLeetCodeDifficulty(difficulty)} $total',
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontSize: 11,
                        color: onFill,
                        // Fixed weight: bolding the selection would resize the
                        // pill and shove its neighbours sideways on every tap.
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
