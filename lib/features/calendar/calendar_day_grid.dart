import 'package:flutter/material.dart';
import 'package:voyager/core/theme/app_fonts.dart';
import 'package:voyager/domain/models/calendar_models.dart';

class CalendarDayIndicator {
  const CalendarDayIndicator({
    required this.day,
    required this.colorValue,
    required this.label,
    this.intensity = 1,
  });

  final DateTime day;
  final int colorValue;
  final String label;
  final double intensity;
}

/// Builds 42 dates (6 weeks) for a month grid, including adjacent-month padding.
List<DateTime> monthGridDates(
  DateTime month, {
  required bool weekStartsMonday,
}) {
  final first = DateTime(month.year, month.month, 1);
  final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
  final startWeekday = first.weekday;
  final leading = weekStartsMonday ? (startWeekday - 1) % 7 : startWeekday % 7;

  final cells = <DateTime>[];
  final prevMonthLast = DateTime(month.year, month.month, 0).day;
  for (var i = leading - 1; i >= 0; i--) {
    cells.add(DateTime(month.year, month.month - 1, prevMonthLast - i));
  }
  for (var day = 1; day <= daysInMonth; day++) {
    cells.add(DateTime(month.year, month.month, day));
  }
  var nextDay = 1;
  while (cells.length < 42) {
    cells.add(DateTime(month.year, month.month + 1, nextDay++));
  }
  return cells;
}

/// Text opacity for day numbers outside the displayed month (padding weeks).
const calendarAdjacentMonthTextOpacity = 0.20;

/// Visual density for [CalendarDayCell] — compact in year tiles, full in month view.
class MonthDayCellStyle {
  const MonthDayCellStyle({
    required this.fontSize,
    required this.borderRadius,
    required this.cellPadding,
    required this.cellMargin,
    required this.maxEventLines,
    required this.dotSize,
    required this.eventFontSize,
    this.borderOpacity = 1,
  });

  final double fontSize;
  final double borderRadius;
  final EdgeInsets cellPadding;
  final EdgeInsets cellMargin;
  final int maxEventLines;
  final double dotSize;
  final double eventFontSize;
  final double borderOpacity;

  static const compact = MonthDayCellStyle(
    fontSize: 7,
    borderRadius: 4,
    cellPadding: EdgeInsets.all(1),
    cellMargin: EdgeInsets.all(0.5),
    maxEventLines: 1,
    dotSize: 3.5,
    eventFontSize: 5.5,
    borderOpacity: 0,
  );

  static const full = MonthDayCellStyle(
    fontSize: 15,
    borderRadius: 10,
    cellPadding: EdgeInsets.fromLTRB(3, 5, 3, 3),
    cellMargin: EdgeInsets.all(1),
    maxEventLines: 2,
    dotSize: 7,
    eventFontSize: 9,
  );

  /// Year mini-month tiles use adaptive shrink-to-fit; month/week fill their slot.
  bool get isCompactLayout => maxEventLines == 1 && eventFontSize < 8;
}

/// Bordered day square shared by year mini-months and the full month grid.
class CalendarDayCell extends StatelessWidget {
  const CalendarDayCell({
    super.key,
    required this.date,
    required this.month,
    required this.events,
    required this.indicators,
    required this.style,
    this.onTap,
    this.isSelected = false,
  });

  final DateTime date;
  final DateTime month;
  final List<CalendarEvent> events;
  final List<CalendarDayIndicator> indicators;
  final MonthDayCellStyle style;
  final VoidCallback? onTap;
  final bool isSelected;

  @override
  Widget build(BuildContext context) {
    final inMonth = date.month == month.month;
    final divider = Theme.of(context).dividerColor;

    final cell = Container(
      width: double.infinity,
      height: double.infinity,
      margin: style.cellMargin,
      padding: style.cellPadding,
      decoration: BoxDecoration(
        border: Border.all(
          color: divider.withValues(alpha: style.borderOpacity.clamp(0.0, 1.0)),
        ),
        borderRadius: BorderRadius.circular(style.borderRadius),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final useCompact =
              style.isCompactLayout || constraints.maxHeight < 28;
          return useCompact
              ? _buildCompactCellContent(inMonth)
              : _buildFullCellContent(inMonth);
        },
      ),
    );

    if (onTap == null) return cell;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(style.borderRadius),
      child: cell,
    );
  }

  Widget _buildFullCellContent(bool inMonth) {
    return ClipRect(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CalendarDayNumber(
            date: date,
            month: month,
            fontSize: style.fontSize,
            mutedWhenAdjacent: !inMonth,
            isSelected: isSelected,
          ),
          if (indicators.isNotEmpty) ...[
            SizedBox(height: style.maxEventLines > 1 ? 2 : 1),
            CalendarDayIndicatorDots(
              indicators: indicators,
              dotSize: style.dotSize,
            ),
          ],
          if (events.isNotEmpty && style.maxEventLines > 0)
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final event in events.take(style.maxEventLines))
                    Flexible(
                      child: Container(
                        margin: const EdgeInsets.only(top: 1),
                        padding: EdgeInsets.symmetric(
                          horizontal: style.maxEventLines > 1 ? 2 : 1,
                        ),
                        color: Color(event.colorValue).withValues(alpha: 0.45),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            event.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppFonts.style(fontSize: style.eventFontSize),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCompactCellContent(bool inMonth) {
    return Center(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: CalendarDayNumber(
          date: date,
          month: month,
          fontSize: style.fontSize,
          mutedWhenAdjacent: !inMonth,
          isSelected: isSelected,
        ),
      ),
    );
  }
}

class CalendarDayNumber extends StatelessWidget {
  const CalendarDayNumber({
    super.key,
    required this.date,
    required this.month,
    required this.fontSize,
    this.mutedWhenAdjacent = false,
    this.isSelected = false,
  });

  final DateTime date;
  final DateTime month;
  final double fontSize;
  final bool mutedWhenAdjacent;
  final bool isSelected;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final isToday = calendarIsToday(date);
    final muted = mutedWhenAdjacent && date.month != month.month;
    final diameter = fontSize + (fontSize <= 9 ? 3 : 8);
    final showSelection = isSelected && !isToday;

    return Center(
      child: Container(
        width: diameter,
        height: diameter,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isToday
              ? accent
              : showSelection
              ? accent.withValues(alpha: 0.2)
              : null,
          shape: BoxShape.circle,
          border: showSelection ? Border.all(color: accent) : null,
        ),
        child: Text(
          '${date.day}',
          textAlign: TextAlign.center,
          textHeightBehavior: const TextHeightBehavior(
            applyHeightToFirstAscent: false,
            applyHeightToLastDescent: false,
          ),
          style: AppFonts.style(
            fontSize: fontSize,
            fontWeight: isToday ? FontWeight.w600 : FontWeight.w500,
            height: 1,
            color: isToday
                ? Theme.of(context).colorScheme.onPrimary
                : muted
                ? Theme.of(context).colorScheme.onSurface.withValues(
                    alpha: calendarAdjacentMonthTextOpacity,
                  )
                : Theme.of(context).colorScheme.onSurface,
          ),
        ),
      ),
    );
  }
}

class CalendarDayIndicatorDots extends StatelessWidget {
  const CalendarDayIndicatorDots({
    super.key,
    required this.indicators,
    required this.dotSize,
  });

  final List<CalendarDayIndicator> indicators;
  final double dotSize;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 2,
      runSpacing: 2,
      alignment: WrapAlignment.center,
      children: [
        for (final indicator in indicators)
          Container(
            width: dotSize,
            height: dotSize,
            decoration: BoxDecoration(
              color: Color(indicator.colorValue).withValues(
                alpha: (0.35 + 0.65 * indicator.intensity).clamp(0.35, 1),
              ),
              shape: BoxShape.circle,
            ),
          ),
      ],
    );
  }
}

/// Weekday label row shown above the month day grid.
class WeekdayHeaderRow extends StatelessWidget {
  const WeekdayHeaderRow({
    super.key,
    required this.weekStartsMonday,
    this.opacity = 1,
    this.useSingleLetterLabels = false,
  });

  final bool weekStartsMonday;
  final double opacity;
  final bool useSingleLetterLabels;

  @override
  Widget build(BuildContext context) {
    final labels = useSingleLetterLabels
        ? (weekStartsMonday
              ? calendarWeekdayLettersMonday
              : calendarWeekdayLettersSunday)
        : (weekStartsMonday
              ? calendarWeekdayLabelsMonday
              : calendarWeekdayLabelsSunday);
    final row = Row(
      children: [
        for (final label in labels)
          Expanded(
            child: Center(
              child: Text(
                label,
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
          ),
      ],
    );
    if (opacity >= 1) return row;
    return Opacity(opacity: opacity.clamp(0.0, 1.0), child: row);
  }
}

/// Shared 6×7 day grid for year mini-months and the month view.
class MonthDayGrid extends StatelessWidget {
  const MonthDayGrid({
    super.key,
    required this.month,
    required this.events,
    required this.indicators,
    required this.weekStartsMonday,
    required this.style,
    this.onDayTap,
    this.showWeekdayHeader = false,
    this.weekdayHeaderOpacity = 1,
    this.useSingleLetterWeekdays = false,
    this.selectedDay,
  });

  final DateTime month;
  final List<CalendarEvent> events;
  final List<CalendarDayIndicator> indicators;
  final bool weekStartsMonday;
  final MonthDayCellStyle style;
  final void Function(DateTime day)? onDayTap;
  final bool showWeekdayHeader;
  final double weekdayHeaderOpacity;
  final bool useSingleLetterWeekdays;
  final DateTime? selectedDay;

  @override
  Widget build(BuildContext context) {
    final cells = monthGridDates(month, weekStartsMonday: weekStartsMonday);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showWeekdayHeader) ...[
          WeekdayHeaderRow(
            weekStartsMonday: weekStartsMonday,
            opacity: weekdayHeaderOpacity,
            useSingleLetterLabels: useSingleLetterWeekdays,
          ),
          const SizedBox(height: _weekdayHeaderGap),
        ],
        Expanded(
          child: Column(
            children: List.generate(6, (row) {
              return Expanded(
                child: Row(
                  children: List.generate(7, (col) {
                    final date = cells[row * 7 + col];
                    final dayEvents = events
                        .where((e) => calendarSameDay(e.start, date))
                        .toList();
                    final dayIndicators = indicators
                        .where((i) => calendarSameDay(i.day, date))
                        .take(3)
                        .toList();

                    final isSelected = selectedDay != null &&
                        calendarSameDay(date, selectedDay!);

                    return Expanded(
                      child: CalendarDayCell(
                        date: date,
                        month: month,
                        events: dayEvents,
                        indicators: dayIndicators,
                        style: style,
                        isSelected: isSelected,
                        onTap: onDayTap == null ? null : () => onDayTap!(date),
                      ),
                    );
                  }),
                ),
              );
            }),
          ),
        ),
      ],
    );
  }
}

// weekdayHeaderGap constant formerly in MonthDayGridLayout — inlined below.
const _weekdayHeaderGap = 4.0;

bool calendarIsToday(DateTime date) {
  final now = DateTime.now();
  return calendarSameDay(date, now);
}

bool calendarSameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

const calendarWeekdayLabelsMonday = [
  'Mon',
  'Tue',
  'Wed',
  'Thu',
  'Fri',
  'Sat',
  'Sun',
];

const calendarWeekdayLettersMonday = [
  'M',
  'T',
  'W',
  'T',
  'F',
  'S',
  'S',
];

const calendarWeekdayLabelsSunday = [
  'Sun',
  'Mon',
  'Tue',
  'Wed',
  'Thu',
  'Fri',
  'Sat',
];

const calendarWeekdayLettersSunday = [
  'S',
  'M',
  'T',
  'W',
  'T',
  'F',
  'S',
];
