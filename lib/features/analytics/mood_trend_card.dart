import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/widgets/chart_hover_bubble.dart';
import 'package:voyager/domain/models/analytics_models.dart';
import 'package:voyager/features/leetcode/leetcode_activity_bubble.dart';

/// Height of the plot, dated axis included. Tall enough to clear the hover
/// bubble, which is laid out inside the chart's own box.
const double _kChartHeight = 160;

/// Points between dated labels on the X axis — the days are recorded ones, not
/// consecutive, so this is every seventh entry rather than every week.
const int _kBottomTitleInterval = 7;

/// Full-width card under the analytics page's stat chips: the average mood of
/// each of the last [kMoodChartDays] days that have one, drawn the way the
/// LeetCode activity chart draws its curves. Hidden until there is a mood to
/// plot.
class MoodTrendCard extends ConsumerStatefulWidget {
  const MoodTrendCard({super.key});

  @override
  ConsumerState<MoodTrendCard> createState() => _MoodTrendCardState();
}

class _MoodTrendCardState extends ConsumerState<MoodTrendCard> {
  int? _hoverIndex;
  Offset? _hoverPosition;

  void _clearHover() {
    if (_hoverIndex == null && _hoverPosition == null) return;
    setState(() {
      _hoverIndex = null;
      _hoverPosition = null;
    });
  }

  void _handleTouch(
    FlTouchEvent event,
    LineTouchResponse? response,
    int length,
  ) {
    final hits = response?.lineBarSpots;
    final position = event.localPosition;
    if (!event.isInterestedForInteractions ||
        position == null ||
        hits == null ||
        hits.isEmpty) {
      _clearHover();
      return;
    }
    final index = hits.first.spotIndex;
    if (index < 0 || index >= length) {
      _clearHover();
      return;
    }
    if (_hoverIndex == index && _hoverPosition == position) return;
    setState(() {
      _hoverIndex = index;
      _hoverPosition = position;
    });
  }

  @override
  Widget build(BuildContext context) {
    final entries = ref.watch(allJournalEntriesProvider).valueOrNull;
    final journals = ref.watch(journalsProvider).valueOrNull;
    if (entries == null || journals == null) return const SizedBox.shrink();
    final days = recentMoodDays(
      entries,
      moodJournalIds: {
        for (final j in journals)
          if (j.showMood) j.id,
      },
    );
    if (days.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final color = theme.colorScheme.primary;
    final axisStyle = theme.textTheme.labelSmall?.copyWith(fontSize: 9);
    final gridLine = FlLine(
      color: theme.colorScheme.outline.withValues(alpha: 0.10),
      strokeWidth: 1,
    );

    final chart = LineChart(
      LineChartData(
        showingTooltipIndicators: const [],
        lineTouchData: LineTouchData(
          // The bubble is drawn in the stack below, so fl_chart's own tooltip
          // stays off.
          handleBuiltInTouches: false,
          touchSpotThreshold: 10000,
          touchCallback: (event, response) =>
              _handleTouch(event, response, days.length),
          getTouchedSpotIndicator: (barData, spotIndexes) => [
            for (final _ in spotIndexes)
              TouchedSpotIndicatorData(
                const FlLine(color: Colors.transparent),
                FlDotData(
                  getDotPainter: (spot, percent, bar, index) =>
                      FlDotCirclePainter(
                        radius: 3,
                        color: color,
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
        // A single day would otherwise give the X axis zero width.
        maxX: days.length < 2 ? 1 : (days.length - 1).toDouble(),
        minY: 0,
        maxY: 10,
        gridData: FlGridData(
          verticalInterval: _kBottomTitleInterval.toDouble(),
          horizontalInterval: 2,
          getDrawingVerticalLine: (_) => gridLine,
          getDrawingHorizontalLine: (_) => gridLine,
        ),
        titlesData: FlTitlesData(
          rightTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          topTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 24,
              interval: 2,
              getTitlesWidget: (value, meta) => SideTitleWidget(
                meta: meta,
                space: 8,
                child: Text('${value.round()}', style: axisStyle),
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
                // Only points on the interval get a date — fl_chart also
                // labels the axis maximum, which crowds the last one.
                if (index < 0 ||
                    index >= days.length ||
                    index % _kBottomTitleInterval != 0) {
                  return const SizedBox.shrink();
                }
                return SideTitleWidget(
                  meta: meta,
                  space: 8,
                  child: Text(
                    DateFormat('MMM d').format(days[index].day),
                    style: axisStyle,
                  ),
                );
              },
            ),
          ),
        ),
        borderData: FlBorderData(
          show: true,
          border: Border(
            bottom: BorderSide(color: VoyagerColors.of(context).strongHairline),
            left: BorderSide(color: VoyagerColors.of(context).strongHairline),
          ),
        ),
        lineBarsData: [
          LineChartBarData(
            spots: [
              for (var i = 0; i < days.length; i++)
                FlSpot(i.toDouble(), days[i].mood),
            ],
            isCurved: false,
            color: color.withValues(alpha: 0.9),
            barWidth: 2,
            // A lone day has no segment to draw, so it needs its dot.
            dotData: FlDotData(show: days.length == 1),
            belowBarData: BarAreaData(
              show: true,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                // The analytics sparklines' 30% wash, not the LeetCode chart's
                // 10%: that one is faint because four series overlap there, and
                // this is a single line.
                colors: [
                  color.withValues(alpha: 0.30),
                  color.withValues(alpha: 0.0),
                ],
              ),
            ),
            showingIndicators: _hoverIndex == null ? const [] : [_hoverIndex!],
          ),
        ],
      ),
      // Hover is the only thing that changes this data; lerping it made the
      // hover line crawl after the pointer (see [LeetCodeActivityChart]).
      duration: Duration.zero,
    );

    final hoverIndex = _hoverIndex;
    final hoverPosition = _hoverPosition;
    final plot =
        hoverIndex == null || hoverPosition == null || hoverIndex >= days.length
        ? chart
        : Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(child: chart),
              LeetCodeActivityBubbleLayer(
                anchor: hoverPosition,
                child: ChartHoverBubble(
                  periodLabel: DateFormat(
                    'EEE, MMM d',
                  ).format(days[hoverIndex].day),
                  // "7", not "7.0" — trimmed after rounding so 6.96 shows
                  // as "7" too.
                  valueLabel: days[hoverIndex].mood
                      .toStringAsFixed(1)
                      .replaceFirst(RegExp(r'\.0$'), ''),
                ),
              ),
            ],
          );

    // Brings its own gap to the toolbar below, so a hidden card leaves none.
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.onSurface.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: VoyagerColors.of(context).hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Mood · last $kMoodChartDays recorded days',
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: _kChartHeight,
            child: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: plot,
            ),
          ),
        ],
      ),
    );
  }
}
