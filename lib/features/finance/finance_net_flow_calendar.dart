import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/utils/calendar_days.dart';
import 'package:voyager/core/widgets/chart_hover_bubble.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/domain/services/finance_analytics.dart';
import 'package:voyager/features/calendar/calendar_day_grid.dart';
import 'package:voyager/features/calendar/calendar_grid.dart';
import 'package:voyager/features/finance/finance_net_flow_chart.dart';
import 'package:voyager/features/finance/finance_transaction_modal.dart';
import 'package:voyager/features/leetcode/leetcode_activity_bubble.dart';

/// Month tiles per row for the width the calendar has — the same breakpoints
/// as the LeetCode activity calendar, which lives in the same kind of overlay.
int _columnsFor(double width) {
  if (width >= 1000) return 4;
  if (width >= 700) return 3;
  if (width >= 420) return 2;
  return 1;
}

const _monthNames = [
  '',
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

/// A year of daily money: each day tinted by the hero chart's solo series (net
/// when none is soloed), scaled against that year's busiest day.
///
/// Days inside the chart's range carry the colour; days outside it stay
/// muted, but still hover and still jump. Tapping any day asks [onDayTap] to
/// take the ledger there.
///
/// Structure and hover plumbing follow LeetCodeActivityCalendar; see it for
/// why hover lives in a notifier and the grid in a [RepaintBoundary].
class FinanceNetFlowCalendar extends ConsumerStatefulWidget {
  const FinanceNetFlowCalendar({
    super.key,
    required this.transactions,
    required this.where,
    required this.series,
    required this.rangeStart,
    required this.today,
    required this.onDayTap,
  });

  final List<FinancialTransaction> transactions;
  final bool Function(FinancialTransaction transaction)? where;
  final NetFlowSeries series;

  /// First day of the chart's range, local midnight. The range ends [today].
  final DateTime rangeStart;
  final DateTime today;
  final ValueChanged<DateTime> onDayTap;

  @override
  ConsumerState<FinanceNetFlowCalendar> createState() =>
      _FinanceNetFlowCalendarState();
}

typedef _CalendarHover = ({
  DateTime date,
  Offset position,
  double visibleTop,
  double visibleBottom,
});

class _FinanceNetFlowCalendarState
    extends ConsumerState<FinanceNetFlowCalendar> {
  final _stackKey = GlobalKey();
  final _scrollController = ScrollController();
  final _hover = ValueNotifier<_CalendarHover?>(null);

  late int _year = widget.today.year;

  @override
  void dispose() {
    _hover.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onHover(DateTime date, Offset globalPosition) {
    final box = _stackKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final position = _scrollController.hasClients
        ? _scrollController.position
        : null;
    final visibleTop = position?.pixels ?? 0.0;
    _hover.value = (
      date: date,
      position: box.globalToLocal(globalPosition),
      visibleTop: visibleTop,
      visibleBottom:
          visibleTop + (position?.viewportDimension ?? box.size.height),
    );
  }

  void _endHover(DateTime date) {
    if (_hover.value?.date != date) return;
    _hover.value = null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final weekStartsMonday =
        ref.watch(settingsProvider).valueOrNull?.weekStartsOnMonday ?? true;

    // The window stops at today: nothing after it has happened yet.
    final yearStart = DateTime(_year, 1, 1);
    final yearEnd = DateTime(_year, 12, 31);
    final flows = dailyNetSeries(
      widget.transactions,
      from: yearStart,
      to: yearEnd.isAfter(widget.today) ? widget.today : yearEnd,
      where: widget.where,
    );
    DailyFlow flowOn(DateTime date) {
      final index = calendarDaysBetween(yearStart, date);
      return index >= 0 && index < flows.length
          ? flows[index]
          : DailyFlow(day: date);
    }

    final busiest = busiestDailyFlow(flows, widget.series);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              icon: const Icon(Icons.chevron_left),
              tooltip: 'Previous year',
              onPressed: () => setState(() => _year--),
            ),
            Text(
              '$_year',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.chevron_right),
              tooltip: 'Next year',
              onPressed: () => setState(() => _year++),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: VoyagerScrollView(
            controller: _scrollController,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final columns = _columnsFor(constraints.maxWidth);
                final rows = (12 / columns).ceil();
                return Stack(
                  key: _stackKey,
                  clipBehavior: Clip.none,
                  children: [
                    RepaintBoundary(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (var row = 0; row < rows; row++) ...[
                            if (row > 0) const SizedBox(height: 8),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                for (var col = 0; col < columns; col++) ...[
                                  if (col > 0) const SizedBox(width: 8),
                                  Expanded(
                                    child: row * columns + col < 12
                                        ? _MonthTile(
                                            month: DateTime(
                                              _year,
                                              row * columns + col + 1,
                                            ),
                                            flowOn: flowOn,
                                            busiest: busiest,
                                            series: widget.series,
                                            rangeStart: widget.rangeStart,
                                            today: widget.today,
                                            weekStartsMonday: weekStartsMonday,
                                            onHover: _onHover,
                                            onHoverEnd: _endHover,
                                            onTap: widget.onDayTap,
                                          )
                                        : const SizedBox.shrink(),
                                  ),
                                ],
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                    ValueListenableBuilder<_CalendarHover?>(
                      valueListenable: _hover,
                      builder: (context, hover, _) {
                        if (hover == null) return const SizedBox.shrink();
                        return LeetCodeActivityBubbleLayer(
                          anchor: hover.position,
                          visibleTop: hover.visibleTop,
                          visibleBottom: hover.visibleBottom,
                          child: FinanceNetFlowBubble(flow: flowOn(hover.date)),
                        );
                      },
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _MonthTile extends StatelessWidget {
  const _MonthTile({
    required this.month,
    required this.flowOn,
    required this.busiest,
    required this.series,
    required this.rangeStart,
    required this.today,
    required this.weekStartsMonday,
    required this.onHover,
    required this.onHoverEnd,
    required this.onTap,
  });

  final DateTime month;
  final DailyFlow Function(DateTime date) flowOn;
  final int busiest;
  final NetFlowSeries series;
  final DateTime rangeStart;
  final DateTime today;
  final bool weekStartsMonday;
  final void Function(DateTime date, Offset globalPosition) onHover;
  final ValueChanged<DateTime> onHoverEnd;
  final ValueChanged<DateTime> onTap;

  @override
  Widget build(BuildContext context) {
    final cells = monthGridDates(month, weekStartsMonday: weekStartsMonday);
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      color: chartTooltipBubbleColor(context),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final daySize = constraints.maxWidth / 7;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _monthNames[month.month],
                  style: MonthTitleHeader.yearTileMonthNameStyle(context),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textHeightBehavior: MonthTitleHeader.titleTextHeightBehavior,
                ),
                const SizedBox(height: MonthTitleHeader.titleGap),
                WeekdayHeaderRow(
                  weekStartsMonday: weekStartsMonday,
                  useSingleLetterLabels: false,
                  labelStyle: calendarWeekdayLabelStyle(
                    context,
                    fontSize: MonthDayCellStyle.compact.fontSize,
                  ),
                ),
                const SizedBox(height: monthDayGridWeekdayHeaderGap),
                for (var row = 0; row < 6; row++)
                  Row(
                    children: [
                      for (var col = 0; col < 7; col++)
                        SizedBox(
                          width: daySize,
                          height: daySize,
                          child: _DayCell(
                            date: cells[row * 7 + col],
                            month: month,
                            flow: flowOn(cells[row * 7 + col]),
                            busiest: busiest,
                            series: series,
                            rangeStart: rangeStart,
                            today: today,
                            onHover: onHover,
                            onHoverEnd: onHoverEnd,
                            onTap: onTap,
                          ),
                        ),
                    ],
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.date,
    required this.month,
    required this.flow,
    required this.busiest,
    required this.series,
    required this.rangeStart,
    required this.today,
    required this.onHover,
    required this.onHoverEnd,
    required this.onTap,
  });

  final DateTime date;
  final DateTime month;
  final DailyFlow flow;
  final int busiest;
  final NetFlowSeries series;
  final DateTime rangeStart;
  final DateTime today;
  final void Function(DateTime date, Offset globalPosition) onHover;
  final ValueChanged<DateTime> onHoverEnd;
  final ValueChanged<DateTime> onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final inMonth = date.month == month.month && date.year == month.year;
    final inRange = !date.isBefore(rangeStart) && !date.isAfter(today);
    final value = flow.valueFor(series);
    final hue = switch (series) {
      NetFlowSeries.net => netFlowSignColor(value, theme),
      NetFlowSeries.income => kIncomeGreen,
      NetFlowSeries.expense => theme.colorScheme.primary,
    };
    final intensity = busiest <= 0
        ? 0.0
        : (value.abs() / busiest).clamp(0.0, 1.0);

    // Days spilling in from an adjacent month stay neutral, as on every year
    // heatmap in the app; so do days outside the chart's range. A quiet day in
    // range is a whisper of green — nothing lost reads as "at or above zero".
    final Color fill;
    if (!inMonth || !inRange) {
      fill = theme.colorScheme.onSurface.withValues(
        alpha: 0.05 * (inMonth ? 1.0 : 0.4),
      );
    } else if (value == 0) {
      fill = kIncomeGreen.withValues(alpha: 0.08);
    } else {
      fill = hue.withValues(alpha: 0.15 + 0.85 * intensity);
    }

    final cell = Container(
      margin: const EdgeInsets.all(1),
      padding: const EdgeInsets.all(1),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(
          MonthDayCellStyle.compact.borderRadius,
        ),
      ),
      child: Align(
        alignment: Alignment.topLeft,
        child: Text(
          '${date.day}',
          style: TextStyle(
            fontSize: MonthDayCellStyle.compact.fontSize,
            fontWeight: FontWeight.w500,
            color: inMonth
                ? theme.colorScheme.onSurfaceVariant
                : theme.colorScheme.onSurfaceVariant.withValues(
                    alpha: calendarAdjacentMonthTextOpacity,
                  ),
          ),
        ),
      ),
    );
    if (!inMonth) return cell;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (event) => onHover(date, event.position),
      onHover: (event) => onHover(date, event.position),
      onExit: (_) => onHoverEnd(date),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onTap(date),
        child: cell,
      ),
    );
  }
}
