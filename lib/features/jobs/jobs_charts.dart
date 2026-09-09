import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

/// Applications per day over the last 30 days (§8.3).
///
/// The same compact line the LeetCode activity card draws: straight segments
/// with a faint wash under them, no axes, no gridlines and no hover. Straight
/// rather than curved for the reason the bars it replaces existed — these are
/// whole-number counts on discrete days, most of them zero, and splining them
/// would invent applications on the days between two spikes.
class JobsSparkline extends StatelessWidget {
  const JobsSparkline({super.key, required this.counts, this.color});

  final List<int> counts;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (counts.isEmpty) return const SizedBox.shrink();
    final color = this.color ?? theme.colorScheme.primary;

    final dataMax = counts
        .fold<int>(0, (max, count) => count > max ? count : max)
        .toDouble();

    return LineChart(
      LineChartData(
        // Nothing here is interactive, so the plot neither tracks the pointer
        // nor draws a tooltip.
        lineTouchData: const LineTouchData(enabled: false),
        minX: 0,
        maxX: (counts.length - 1).toDouble(),
        minY: 0,
        // The chart fills its box: a header slot two applications tall
        // shouldn't waste half its height on headroom for gridlines it isn't
        // drawing.
        maxY: dataMax <= 0 ? 1.0 : dataMax * 1.25,
        gridData: const FlGridData(show: false),
        titlesData: const FlTitlesData(show: false),
        borderData: FlBorderData(show: false),
        lineBarsData: [
          LineChartBarData(
            spots: [
              for (var i = 0; i < counts.length; i++)
                FlSpot(i.toDouble(), counts[i].toDouble()),
            ],
            isCurved: false,
            color: color.withValues(alpha: 0.9),
            barWidth: 1.5,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  color.withValues(alpha: 0.10),
                  color.withValues(alpha: 0.0),
                ],
              ),
            ),
          ),
        ],
      ),
      // fl_chart implicitly lerps every [LineChartData] change over 150ms. The
      // header rebuilds on every keystroke in the search field and on every
      // filter chip, and re-lerping thirty spots through each of those buys
      // nothing this chart is asking for.
      duration: Duration.zero,
    );
  }
}
