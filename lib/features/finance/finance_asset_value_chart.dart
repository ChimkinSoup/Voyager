import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/widgets/chart_hover_bubble.dart';
import 'package:voyager/domain/models/finance_models.dart';

/// One asset's value over time: a point on each date it was valued, carried
/// forward to today so a stale figure reads as a flat run rather than stopping
/// short.
///
/// Draws nothing until there are two points to join — a lone dot is no trend.
class AssetValueChart extends ConsumerStatefulWidget {
  const AssetValueChart({
    super.key,
    required this.assetId,
    required this.color,
  });

  final String assetId;
  final Color color;

  @override
  ConsumerState<AssetValueChart> createState() => _AssetValueChartState();
}

class _AssetValueChartState extends ConsumerState<AssetValueChart> {
  /// Index into the points the pointer is currently reading, or null.
  int? _touchedIndex;

  void _handleTouch(FlTouchEvent event, LineTouchResponse? response) {
    final hits = response?.lineBarSpots;
    final next =
        !event.isInterestedForInteractions || hits == null || hits.isEmpty
        ? null
        : hits.first.spotIndex;
    if (next == _touchedIndex) return;
    setState(() => _touchedIndex = next);
  }

  /// Whole days from [from] to [to], counted on the calendar so a DST shift
  /// can't knock a point off its day.
  static int _dayOffset(DateTime from, DateTime to) => DateTime.utc(
    to.year,
    to.month,
    to.day,
  ).difference(DateTime.utc(from.year, from.month, from.day)).inDays;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final valuations =
        (ref.watch(assetValuationsProvider).valueOrNull ?? const [])
            .where((v) => v.assetId == widget.assetId)
            .toList()
          ..sort((a, b) => a.asOf.compareTo(b.asOf));
    if (valuations.isEmpty) return const SizedBox.shrink();

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final points = <({DateTime date, int cents})>[
      for (final v in valuations) (date: v.asOf, cents: v.valueCents),
      if (_dayOffset(valuations.last.asOf, today) > 0)
        (date: today, cents: valuations.last.valueCents),
    ];
    if (points.length < 2) return const SizedBox.shrink();

    final first = points.first.date;
    final spots = [
      for (final p in points)
        FlSpot(_dayOffset(first, p.date).toDouble(), p.cents / 100),
    ];
    // The range always takes in zero, so a change reads against the asset's
    // whole value rather than filling the plot from its lowest point.
    final minValue = math.min(0.0, spots.map((s) => s.y).reduce(math.min));
    var maxValue = math.max(0.0, spots.map((s) => s.y).reduce(math.max));
    if (minValue == maxValue) maxValue = 1;
    final pad = (maxValue - minValue) * 0.15;
    final minY = minValue < 0 ? minValue - pad : 0.0;
    final maxY = maxValue > 0 ? maxValue + pad : 0.0;
    final minX = spots.first.x;
    final maxX = spots.last.x;

    final touched = _touchedIndex != null && _touchedIndex! < points.length
        ? _touchedIndex
        : null;
    final carriedForward = spots.length > valuations.length;
    final color = widget.color;

    final chart = LineChart(
      LineChartData(
        minX: minX,
        maxX: maxX,
        minY: minY,
        maxY: maxY,
        lineTouchData: LineTouchData(
          handleBuiltInTouches: false,
          // Always inside some point's zone, so the whole width reads a value
          // — see the net-worth chart, which this matches.
          touchSpotThreshold: 10000,
          touchCallback: _handleTouch,
        ),
        gridData: const FlGridData(show: false),
        borderData: FlBorderData(show: false),
        titlesData: const FlTitlesData(show: false),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            color: color,
            barWidth: 2,
            // A dot on each real valuation, none on the carried-forward end:
            // that one is today's reading of the last figure, not a new one.
            dotData: FlDotData(
              checkToShowDot: (spot, _) =>
                  !carriedForward || spot != spots.last,
              getDotPainter: (_, _, _, _) =>
                  FlDotCirclePainter(radius: 2.5, color: color, strokeWidth: 0),
            ),
            showingIndicators: touched == null ? const [] : [touched],
            belowBarData: BarAreaData(
              show: true,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  color.withValues(alpha: 0.22),
                  color.withValues(alpha: 0.0),
                ],
              ),
            ),
          ),
        ],
      ),
    );

    final labelStyle = theme.textTheme.labelSmall?.copyWith(
      fontSize: 9,
      color: theme.colorScheme.onSurfaceVariant,
    );
    final dateFormat = DateFormat('MMM d, yyyy');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 100,
          // The chart stays the Stack's first child hovered or not, so a hover
          // doesn't rebuild it and replay its draw-in animation.
          child: LayoutBuilder(
            builder: (context, constraints) {
              final spanX = maxX - minX == 0 ? 1.0 : maxX - minX;
              final spanY = maxY - minY;
              final point = touched == null ? null : points[touched];
              return Stack(
                clipBehavior: Clip.none,
                children: [
                  chart,
                  if (point != null)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: CustomSingleChildLayout(
                          delegate: ChartBubbleLayout(
                            anchor: Offset(
                              (spots[touched!].x - minX) /
                                  spanX *
                                  constraints.maxWidth,
                              constraints.maxHeight *
                                  (1 - (spots[touched].y - minY) / spanY),
                            ),
                          ),
                          child: ChartHoverBubble(
                            periodLabel:
                                carriedForward && touched == points.length - 1
                                ? 'Today'
                                : dateFormat.format(point.date),
                            valueLabel: formatCents(point.cents),
                            valueColor: point.cents < 0
                                ? theme.colorScheme.error
                                : color,
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Text(dateFormat.format(first), style: labelStyle),
            const Spacer(),
            Text(dateFormat.format(points.last.date), style: labelStyle),
          ],
        ),
      ],
    );
  }
}
