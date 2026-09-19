import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:voyager/core/motion/motion.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/widgets/chart_hover_bubble.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/domain/services/finance_analytics.dart';
import 'package:voyager/features/analytics/stat_number_format.dart';
import 'package:voyager/features/finance/finance_transaction_modal.dart';
import 'package:voyager/features/leetcode/leetcode_activity_bubble.dart';

/// Horizontal gridlines the expanded chart aims for on the larger side of
/// zero, zero included.
const int _kGridLines = 4;

/// Height reserved under the expanded chart's plot for its dated labels.
const double _kBottomAxisHeight = 26;

/// The colour a signed amount is drawn in across the hero: green at or above
/// zero, the app's accent below it. A quiet day reads as green.
Color netFlowSignColor(int cents, ThemeData theme) =>
    cents >= 0 ? kIncomeGreen : theme.colorScheme.primary;

Color netFlowSeriesColor(NetFlowSeries series, ThemeData theme) =>
    switch (series) {
      NetFlowSeries.net => theme.colorScheme.onSurfaceVariant,
      NetFlowSeries.income => kIncomeGreen,
      NetFlowSeries.expense => theme.colorScheme.primary,
    };

String netFlowSeriesLabel(NetFlowSeries series) => switch (series) {
  NetFlowSeries.net => 'Net',
  NetFlowSeries.income => 'Income',
  NetFlowSeries.expense => 'Expense',
};

/// Where zero falls, as a 0–1 fraction from [top] down to [bottom], for a
/// gradient spanning that band. Null when zero is outside it — the whole band
/// is on one side, and one colour will do.
@visibleForTesting
double? zeroStopFraction({required double top, required double bottom}) {
  if (top < 0 || bottom > 0 || top == bottom) return null;
  return top / (top - bottom);
}

/// Days between dated labels on the expanded chart's X axis, picked so a
/// window gets about five labels whatever its length.
int _labelInterval(int days) {
  for (final interval in const [1, 2, 7, 14, 30, 60]) {
    if (days / interval <= 6) return interval;
  }
  return 90;
}

/// The hero's signed daily-net line, and in the expanded view the income and
/// expense lines on the same axes.
///
/// The net line changes colour where it crosses zero, and each side is filled
/// toward the zero axis rather than toward the bottom of the plot. Both come
/// from fl_chart rather than per-segment geometry. The line has one vertical
/// gradient with a hard stop at zero. The fills are a below-area and an
/// above-area, each cut off at zero, and fl_chart clears whatever part of a
/// cut-off area lands on the far side of the line. So a straddling segment
/// splits exactly at its crossing, and the chart costs two layers however
/// often the month changes sign.
///
/// [compact] is the hero card: the net line alone, no axes, no hover. Wrap it
/// in an [IgnorePointer]: fl_chart hit-tests its plot even with touches off,
/// and the card's own tap opens the expanded view.
class FinanceNetFlowChart extends StatefulWidget {
  const FinanceNetFlowChart({
    super.key,
    required this.flows,
    this.compact = false,
    this.selected,
  });

  final List<DailyFlow> flows;
  final bool compact;

  /// The legend's solo series, or null for all three. Ignored when compact,
  /// which only ever draws net.
  final NetFlowSeries? selected;

  @override
  State<FinanceNetFlowChart> createState() => _FinanceNetFlowChartState();
}

class _FinanceNetFlowChartState extends State<FinanceNetFlowChart> {
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
    // Every series plots every day at x = its index, so the x of any hit
    // names the day.
    final index = hits.first.x.round();
    if (index < 0 || index >= widget.flows.length) {
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
  void didUpdateWidget(covariant FinanceNetFlowChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A range change can leave the hovered index past the new window's end.
    if (oldWidget.flows.length != widget.flows.length) {
      _hoverIndex = null;
      _hoverPosition = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final flows = widget.flows;
    if (flows.isEmpty) return const SizedBox.shrink();

    final shown = widget.compact || widget.selected == null
        ? (widget.compact ? const [NetFlowSeries.net] : NetFlowSeries.values)
        : [widget.selected!];

    // Plotted in dollars so the axis labels read as money.
    double valueAt(int i, NetFlowSeries series) =>
        flows[i].valueFor(series) / 100;

    var lo = 0.0;
    var hi = 0.0;
    for (var i = 0; i < flows.length; i++) {
      for (final series in shown) {
        final v = valueAt(i, series);
        lo = math.min(lo, v);
        hi = math.max(hi, v);
      }
    }

    final double minY;
    final double maxY;
    final double yStep;
    if (widget.compact) {
      // Always spans zero, so the fill has an axis to reach. A flat month sits
      // mid-card rather than on its bottom edge.
      if (hi == lo) {
        minY = -1;
        maxY = 1;
      } else {
        final pad = (hi - lo) * 0.12;
        minY = lo < 0 ? lo - pad : 0;
        maxY = hi > 0 ? hi + pad : 0;
      }
      yStep = 1;
    } else {
      yStep = niceAxisStep(math.max(hi, -lo), _kGridLines);
      final up = (hi / yStep).ceil();
      final down = (-lo / yStep).ceil();
      maxY = (up == 0 && down == 0 ? 1 : up) * yStep;
      minY = -down * yStep;
    }

    final single = flows.length == 1;
    List<LineChartBarData> barsFor(double plotHeight) => [
      if (!widget.compact && shown.contains(NetFlowSeries.income))
        _flowBar(NetFlowSeries.income, valueAt, theme, solo: shown.length == 1),
      if (!widget.compact && shown.contains(NetFlowSeries.expense))
        _flowBar(
          NetFlowSeries.expense,
          valueAt,
          theme,
          solo: shown.length == 1,
        ),
      if (shown.contains(NetFlowSeries.net))
        _netBar(
          valueAt,
          theme,
          minY: minY,
          maxY: maxY,
          single: single,
          plotHeight: plotHeight,
        ),
    ];

    final hoverEnabled = !widget.compact;
    final labelInterval = _labelInterval(flows.length);
    final gridColor = theme.colorScheme.outline.withValues(alpha: 0.10);

    // The net line's colour split is placed in pixels, so it needs the plot's
    // height: the box less the dated axis under the expanded chart.
    Widget chartFor(double plotHeight) => LineChart(
      LineChartData(
        showingTooltipIndicators: const [],
        lineTouchData: LineTouchData(
          enabled: hoverEnabled,
          handleBuiltInTouches: false,
          touchSpotThreshold: 10000,
          touchCallback: _handleTouch,
          getTouchedSpotIndicator: (barData, spotIndexes) => [
            for (final _ in spotIndexes)
              TouchedSpotIndicatorData(
                const FlLine(color: Colors.transparent),
                FlDotData(
                  getDotPainter: (spot, percent, bar, index) =>
                      FlDotCirclePainter(
                        radius: 3,
                        // The net line has no single colour; its dot takes the
                        // side of zero it sits on.
                        color:
                            barData.color ??
                            netFlowSignColor((spot.y * 100).round(), theme),
                        strokeWidth: 0,
                      ),
                ),
              ),
          ],
        ),
        extraLinesData: ExtraLinesData(
          horizontalLines: [
            if (!widget.compact)
              HorizontalLine(
                y: 0,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.28),
                strokeWidth: 1,
              ),
          ],
          verticalLines: [
            if (_hoverIndex != null)
              VerticalLine(
                x: _hoverIndex!.toDouble(),
                color: theme.colorScheme.onSurface.withValues(alpha: 0.25),
                strokeWidth: 1,
              ),
          ],
        ),
        // A lone day has no width to span; centre its dot instead of dividing
        // by a zero-wide axis.
        minX: single ? -1 : 0,
        maxX: single ? 1 : (flows.length - 1).toDouble(),
        minY: minY,
        maxY: maxY,
        gridData: FlGridData(
          show: !widget.compact,
          drawVerticalLine: true,
          verticalInterval: labelInterval.toDouble(),
          horizontalInterval: yStep,
          getDrawingVerticalLine: (_) =>
              FlLine(color: gridColor, strokeWidth: 1),
          getDrawingHorizontalLine: (_) =>
              FlLine(color: gridColor, strokeWidth: 1),
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
                    // Sized for the widest label, a minus sign included.
                    reservedSize: axisReservedSize(
                      minY < 0 ? -math.max(maxY, -minY) : maxY,
                      9,
                      8,
                    ),
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
                    reservedSize: _kBottomAxisHeight,
                    interval: single ? 1 : labelInterval.toDouble(),
                    getTitlesWidget: (value, meta) {
                      final index = value.round();
                      if (index < 0 ||
                          index >= flows.length ||
                          index != value ||
                          index % labelInterval != 0) {
                        return const SizedBox.shrink();
                      }
                      return SideTitleWidget(
                        meta: meta,
                        space: 8,
                        child: Text(
                          DateFormat('MMM d').format(flows[index].day),
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
        lineBarsData: barsFor(plotHeight),
      ),
      // Nothing about this data is worth tweening: the hover is the common
      // change, and a lerped hover line crawls after the pointer — see
      // LeetCodeActivityChart.
      duration: Duration.zero,
    );
    final chart = LayoutBuilder(
      builder: (context, constraints) => chartFor(
        constraints.maxHeight - (widget.compact ? 0 : _kBottomAxisHeight),
      ),
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
          child: FinanceNetFlowBubble(flow: flows[hoverIndex]),
        ),
      ],
    );
  }

  List<FlSpot> _spots(
    NetFlowSeries series,
    double Function(int, NetFlowSeries) valueAt,
  ) => [
    for (var i = 0; i < widget.flows.length; i++)
      FlSpot(i.toDouble(), valueAt(i, series)),
  ];

  LineChartBarData _netBar(
    double Function(int, NetFlowSeries) valueAt,
    ThemeData theme, {
    required double minY,
    required double maxY,
    required bool single,
    required double plotHeight,
  }) {
    final spots = _spots(NetFlowSeries.net, valueAt);
    var top = spots.first.y;
    var bottom = spots.first.y;
    for (final spot in spots) {
      top = math.max(top, spot.y);
      bottom = math.min(bottom, spot.y);
    }
    final green = kIncomeGreen;
    final accent = theme.colorScheme.primary;

    // fl_chart spans a line gradient over the box around the line's own
    // spots, top to bottom — which is exactly the band [zeroStopFraction]
    // measures.
    //
    // Quiet days run flat along zero, right on that stop, which would paint
    // the stroke's upper half green and its lower half accent. So the stop
    // sits half a stroke (plus antialiasing) below zero: a zero day is green
    // through, and a month that never goes above zero still has a green zero.
    final barWidth = widget.compact ? 1.75 : 2.0;
    final zeroStop = bottom < 0
        ? zeroStopFraction(top: top, bottom: bottom)
        : null;
    final bandPixels = (top - bottom) * math.max(plotHeight, 1) / (maxY - minY);
    final lineStop = zeroStop == null
        ? null
        : math.min(1.0, zeroStop + (barWidth / 2 + 0.5) / bandPixels);
    final lineGradient = lineStop == null
        ? null
        : LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [green, green, accent, accent],
            stops: [0, lineStop, lineStop, 1],
          );

    // The below-area's gradient box runs from the highest spot to the bottom
    // of the plot (minY); the above-area's from the top of the plot (maxY) to
    // the lowest spot. Each fades out where zero sits in its own box.
    final strong = widget.compact ? 0.26 : 0.22;
    const faint = 0.02;
    final belowStop = top > 0
        ? zeroStopFraction(top: top, bottom: math.min(minY, 0))
        : null;
    final aboveStop = bottom < 0
        ? zeroStopFraction(top: math.max(maxY, 0), bottom: bottom)
        : null;

    return LineChartBarData(
      spots: single ? [FlSpot(0, spots.first.y)] : spots,
      isCurved: false,
      color: lineGradient == null ? (bottom < 0 ? accent : green) : null,
      gradient: lineGradient,
      barWidth: barWidth,
      isStrokeCapRound: true,
      isStrokeJoinRound: true,
      dotData: FlDotData(
        show: single,
        getDotPainter: (spot, percent, bar, index) => FlDotCirclePainter(
          radius: 3,
          color: netFlowSignColor((spot.y * 100).round(), theme),
          strokeWidth: 0,
        ),
      ),
      belowBarData: BarAreaData(
        show: belowStop != null,
        cutOffY: 0,
        applyCutOffY: true,
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            green.withValues(alpha: strong),
            green.withValues(alpha: faint),
          ],
          stops: [0, belowStop ?? 1],
        ),
      ),
      aboveBarData: BarAreaData(
        show: aboveStop != null,
        cutOffY: 0,
        applyCutOffY: true,
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [
            accent.withValues(alpha: strong),
            accent.withValues(alpha: faint),
          ],
          // Measured from the bottom here, since the gradient runs upward.
          stops: [0, aboveStop == null ? 1 : 1 - aboveStop],
        ),
      ),
      showingIndicators: _hoverIndex == null ? const [] : [_hoverIndex!],
    );
  }

  /// Income or expense: a plain line under the net one. Dashed and lighter
  /// while all three share the plot, because each shares a colour with one
  /// side of the net line; drawn solid once it is the only series.
  LineChartBarData _flowBar(
    NetFlowSeries series,
    double Function(int, NetFlowSeries) valueAt,
    ThemeData theme, {
    required bool solo,
  }) {
    final color = netFlowSeriesColor(series, theme);
    final spots = _spots(series, valueAt);
    return LineChartBarData(
      spots: widget.flows.length == 1 ? [spots.first] : spots,
      isCurved: false,
      color: color.withValues(alpha: solo ? 0.95 : 0.6),
      barWidth: solo ? 2 : 1.5,
      dashArray: solo ? null : const [4, 3],
      dotData: FlDotData(show: widget.flows.length == 1),
      belowBarData: BarAreaData(
        show: solo,
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0.18), color.withValues(alpha: 0)],
        ),
      ),
      showingIndicators: _hoverIndex == null ? const [] : [_hoverIndex!],
    );
  }
}

/// The hover card on both expanded surfaces: the day, then its income,
/// expense and net. All three rows always show, so the card keeps its size as
/// the pointer sweeps; zeros are muted.
class FinanceNetFlowBubble extends StatelessWidget {
  const FinanceNetFlowBubble({super.key, required this.flow});

  final DailyFlow flow;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      type: MaterialType.transparency,
      child: IntrinsicWidth(
        child: Container(
          constraints: const BoxConstraints(minWidth: 128),
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
                  DateFormat('EEE, MMM d, yyyy').format(flow.day),
                  maxLines: 1,
                  softWrap: false,
                  style: chartTooltipDateStyle(theme),
                ),
              ),
              const SizedBox(height: 4),
              _BubbleRow(
                label: 'Income',
                value: formatCents(flow.incomeCents),
                color: kIncomeGreen,
                muted: flow.incomeCents == 0,
              ),
              _BubbleRow(
                label: 'Expense',
                value: formatCents(flow.expenseCents),
                color: theme.colorScheme.primary,
                muted: flow.expenseCents == 0,
              ),
              _BubbleRow(
                label: 'Net',
                value: formatCents(flow.netCents, signed: true),
                color: netFlowSignColor(flow.netCents, theme),
                muted: flow.incomeCents == 0 && flow.expenseCents == 0,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BubbleRow extends StatelessWidget {
  const _BubbleRow({
    required this.label,
    required this.value,
    required this.color,
    required this.muted,
  });

  final String label;
  final String value;
  final Color color;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mutedColor = chartTooltipMutedValueColor(theme);
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
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: 11,
              color: muted ? mutedColor : theme.colorScheme.onSurface,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: theme.textTheme.labelSmall?.copyWith(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: muted ? mutedColor : color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Net / Income / Expense with each one's total over the window. Tapping a
/// capsule solos that series across the chart and the heatmap; tapping the
/// solo one again brings all three back.
class FinanceNetFlowLegend extends StatelessWidget {
  const FinanceNetFlowLegend({
    super.key,
    required this.flows,
    required this.selected,
    required this.onSelect,
  });

  final List<DailyFlow> flows;
  final NetFlowSeries? selected;
  final ValueChanged<NetFlowSeries> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        for (final series in NetFlowSeries.values)
          _LegendCapsule(
            label: '${netFlowSeriesLabel(series)} ${_totalLabel(series)}',
            color: series == NetFlowSeries.net
                ? netFlowSignColor(_total(series), theme)
                : netFlowSeriesColor(series, theme),
            active: selected == series,
            dimmed: selected != null && selected != series,
            onTap: () => onSelect(series),
          ),
      ],
    );
  }

  int _total(NetFlowSeries series) =>
      flows.fold(0, (sum, flow) => sum + flow.valueFor(series));

  String _totalLabel(NetFlowSeries series) => series == NetFlowSeries.net
      ? formatCents(_total(series), signed: true)
      : formatCents(_total(series));
}

/// The LeetCode activity legend's capsule, in a series colour — see
/// LeetCodeActivityLegend for why one tween drives every part of it.
class _LegendCapsule extends StatelessWidget {
  const _LegendCapsule({
    required this.label,
    required this.color,
    required this.active,
    required this.dimmed,
    required this.onTap,
  });

  final String label;
  final Color color;
  final bool active;
  final bool dimmed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(end: active ? 1 : 0),
            duration: duration,
            curve: VoyagerSpring.snappyCurve,
            builder: (context, t, _) {
              final onFill = Color.lerp(
                theme.colorScheme.onSurfaceVariant,
                onColorLabel(color),
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
                      label,
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontSize: 11,
                        color: onFill,
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
