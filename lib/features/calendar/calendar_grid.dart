import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:voyager/core/theme/app_fonts.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/features/calendar/calendar_day_grid.dart';

export 'calendar_day_grid.dart'
    show
        CalendarDayIndicator,
        MonthDayCellStyle,
        MonthDayGrid,
        MonthDayGridLayout,
        MonthZoomMorphOverlay,
        monthGridDates;

class CalendarGrid extends StatelessWidget {
  const CalendarGrid({
    super.key,
    required this.mode,
    required this.focused,
    required this.events,
    required this.onDayTap,
    required this.onMonthTap,
    this.indicators = const [],
    this.weekStartsMonday = true,
    this.dayCellKeyBuilder,
    this.zoomSourceMonth,
    this.nonTransitionOpacity = 1,
    this.hideZoomSourceDayCells = false,
    this.fadeNonSourceMonthsOnly = false,
  });

  final CalendarViewMode mode;
  final DateTime focused;
  final List<CalendarEvent> events;
  final List<CalendarDayIndicator> indicators;
  final void Function(DateTime day) onDayTap;
  final void Function(DateTime month, Map<DateTime, Rect> dayGlobalRects)
  onMonthTap;
  final bool weekStartsMonday;
  final GlobalKey Function(DateTime ownerMonth, DateTime cellDate)?
  dayCellKeyBuilder;
  final DateTime? zoomSourceMonth;
  final double nonTransitionOpacity;
  final bool hideZoomSourceDayCells;
  final bool fadeNonSourceMonthsOnly;

  @override
  Widget build(BuildContext context) {
    return switch (mode) {
      CalendarViewMode.week => _WeekGrid(
        focused: focused,
        events: events,
        indicators: indicators,
        onDayTap: onDayTap,
        weekStartsMonday: weekStartsMonday,
      ),
      CalendarViewMode.month => _MonthGrid(
        focused: focused,
        events: events,
        indicators: indicators,
        onDayTap: onDayTap,
        weekStartsMonday: weekStartsMonday,
        dayCellKeyBuilder: dayCellKeyBuilder == null
            ? null
            : (date) => dayCellKeyBuilder!(focused, date),
      ),
      CalendarViewMode.year => _YearGrid(
        focused: focused,
        events: events,
        indicators: indicators,
        onDayTap: onDayTap,
        onMonthTap: onMonthTap,
        weekStartsMonday: weekStartsMonday,
        dayCellKeyBuilder: dayCellKeyBuilder,
        zoomSourceMonth: zoomSourceMonth,
        nonTransitionOpacity: nonTransitionOpacity,
        hideZoomSourceDayCells: hideZoomSourceDayCells,
        fadeNonSourceMonthsOnly: fadeNonSourceMonthsOnly,
      ),
    };
  }
}

/// Persistent sidebar mini calendar with 6 rows and grey adjacent-month days.
class MiniMonthCalendar extends StatelessWidget {
  const MiniMonthCalendar({
    super.key,
    required this.month,
    required this.weekStartsMonday,
    required this.onDayTap,
    this.selectedDay,
  });

  final DateTime month;
  final bool weekStartsMonday;
  final void Function(DateTime day) onDayTap;
  final DateTime? selectedDay;

  @override
  Widget build(BuildContext context) {
    final cells = monthGridDates(month, weekStartsMonday: weekStartsMonday);
    final labels = weekStartsMonday
        ? calendarWeekdayLabelsMonday
        : calendarWeekdayLabelsSunday;

    return SizedBox(
      width: 180,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            DateFormat.yMMMM().format(month),
            style: Theme.of(context).textTheme.titleSmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Row(
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
          ),
          const SizedBox(height: 4),
          Expanded(
            child: Column(
              children: List.generate(6, (row) {
                return Expanded(
                  child: Row(
                    children: List.generate(7, (col) {
                      final date = cells[row * 7 + col];
                      return Expanded(
                        child: CalendarDayNumber(
                          date: date,
                          month: month,
                          fontSize: 12,
                          mutedWhenAdjacent: date.month != month.month,
                        ),
                      );
                    }),
                  ),
                );
              }),
            ),
          ),
        ],
      ),
    );
  }
}

/// Hour-by-hour view for a single day.
class DayHourGrid extends StatelessWidget {
  const DayHourGrid({
    super.key,
    required this.day,
    required this.events,
    required this.onHourTap,
    this.onDayChanged,
  });

  final DateTime day;
  final List<CalendarEvent> events;
  final void Function(DateTime hour) onHourTap;
  final ValueChanged<DateTime>? onDayChanged;

  @override
  Widget build(BuildContext context) {
    final dayEvents = events.where((e) => calendarSameDay(e.start, day)).toList()
      ..sort((a, b) => a.start.compareTo(b.start));
    final fullDayEvents = dayEvents.where((e) => e.isFullDay).toList();
    final timedEvents = dayEvents.where((e) => !e.isFullDay).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            children: [
              IconButton(
                visualDensity: VisualDensity.compact,
                onPressed: onDayChanged == null
                    ? null
                    : () =>
                          onDayChanged!(day.subtract(const Duration(days: 1))),
                icon: const Icon(Icons.chevron_left),
              ),
              Expanded(
                child: Text(
                  DateFormat.yMMMMEEEEd().format(day),
                  style: Theme.of(context).textTheme.titleMedium,
                  textAlign: TextAlign.center,
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                onPressed: onDayChanged == null
                    ? null
                    : () => onDayChanged!(day.add(const Duration(days: 1))),
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
        ),
        if (fullDayEvents.isNotEmpty) ...[
          ...fullDayEvents.map(
            (event) => _DayEventTile(event: event, allDay: true),
          ),
          const SizedBox(height: 8),
        ],
        Expanded(
          child: ListView.builder(
            itemCount: 24,
            itemBuilder: (_, hour) {
              final slotStart = DateTime(day.year, day.month, day.day, hour);
              final slotEvents = timedEvents.where((event) {
                final start = event.start.toLocal();
                return start.year == day.year &&
                    start.month == day.month &&
                    start.day == day.day &&
                    start.hour == hour;
              }).toList();
              return InkWell(
                onTap: () => onHourTap(slotStart),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(color: Theme.of(context).dividerColor),
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 72,
                        child: Text(
                          DateFormat.jm().format(slotStart),
                          style: AppFonts.style(
                            fontSize: 12,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final event in slotEvents)
                              _DayEventTile(event: event),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _MonthGrid extends StatelessWidget {
  const _MonthGrid({
    required this.focused,
    required this.events,
    required this.indicators,
    required this.onDayTap,
    required this.weekStartsMonday,
    this.dayCellKeyBuilder,
  });

  final DateTime focused;
  final List<CalendarEvent> events;
  final List<CalendarDayIndicator> indicators;
  final void Function(DateTime day) onDayTap;
  final bool weekStartsMonday;
  final GlobalKey Function(DateTime date)? dayCellKeyBuilder;

  @override
  Widget build(BuildContext context) {
    return MonthDayGrid(
      month: focused,
      events: events,
      indicators: indicators,
      weekStartsMonday: weekStartsMonday,
      style: MonthDayCellStyle.full,
      onDayTap: onDayTap,
      showWeekdayHeader: true,
      dayCellKeyBuilder: dayCellKeyBuilder,
    );
  }
}

class _WeekGrid extends StatelessWidget {
  const _WeekGrid({
    required this.focused,
    required this.events,
    required this.indicators,
    required this.onDayTap,
    required this.weekStartsMonday,
  });

  final DateTime focused;
  final List<CalendarEvent> events;
  final List<CalendarDayIndicator> indicators;
  final void Function(DateTime day) onDayTap;
  final bool weekStartsMonday;

  @override
  Widget build(BuildContext context) {
    final start = _weekStart(focused, weekStartsMonday);
    final labels = weekStartsMonday
        ? calendarWeekdayLabelsMonday
        : calendarWeekdayLabelsSunday;
    return Column(
      children: [
        Row(
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
        ),
        const SizedBox(height: 6),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: List.generate(7, (i) {
              final date = start.add(Duration(days: i));
              final dayEvents = events
                  .where((e) => calendarSameDay(e.start, date))
                  .toList();
              final dayIndicators = indicators
                  .where((indicator) => calendarSameDay(indicator.day, date))
                  .take(4)
                  .toList();
              return Expanded(
                child: CalendarDayCell(
                  date: date,
                  month: date,
                  events: dayEvents,
                  indicators: dayIndicators,
                  style: _weekDayStyle,
                  onTap: () => onDayTap(date),
                ),
              );
            }),
          ),
        ),
      ],
    );
  }
}

const _weekDayStyle = MonthDayCellStyle(
  fontSize: 13,
  borderRadius: 12,
  cellPadding: EdgeInsets.all(4),
  cellMargin: EdgeInsets.symmetric(horizontal: 2),
  maxEventLines: 8,
  dotSize: 7,
  eventFontSize: 10,
);

/// Computes year-tile day cell positions without mounting a year grid.
class YearMonthTileLayout {
  YearMonthTileLayout._();

  static const crossAxisCount = 4;
  static const childAspectRatio = 1.35;
  static const mainAxisSpacing = 8.0;
  static const crossAxisSpacing = 8.0;
  static const tilePadding = EdgeInsets.all(8);
  static const titleGap = 4.0;

  static double measureMonthTitleHeight(BuildContext context) {
    final style = Theme.of(context).textTheme.titleSmall;
    if (style == null) return 20 + titleGap;

    final painter = TextPainter(
      text: TextSpan(text: 'September', style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    return painter.height + titleGap;
  }

  static Map<DateTime, Rect> computeDayRects({
    required Size areaSize,
    required DateTime month,
    required bool weekStartsMonday,
    required double monthTitleHeight,
  }) {
    final index = month.month - 1;
    final col = index % crossAxisCount;
    final row = index ~/ crossAxisCount;

    final childWidth =
        (areaSize.width - crossAxisSpacing * (crossAxisCount - 1)) /
        crossAxisCount;
    final childHeight = childWidth / childAspectRatio;

    final tileLeft = col * (childWidth + crossAxisSpacing);
    final tileTop = row * (childHeight + mainAxisSpacing);

    final gridLeft = tileLeft + tilePadding.left;
    final gridTop = tileTop + tilePadding.top + monthTitleHeight;
    final gridWidth =
        childWidth - tilePadding.left - tilePadding.right;
    final gridHeight =
        childHeight -
        tilePadding.top -
        tilePadding.bottom -
        monthTitleHeight;

    if (gridWidth <= 0 || gridHeight <= 0) return const {};

    final slotRects = MonthDayGridLayout.computeSlotRects(
      areaSize: Size(gridWidth, gridHeight),
      weekdayHeaderHeight: 0,
    );

    final localSlots = [
      for (final rect in slotRects) rect.shift(Offset(gridLeft, gridTop)),
    ];

    return MonthDayGridLayout.mapDatesToSlotRects(
      month: month,
      weekStartsMonday: weekStartsMonday,
      slotRects: localSlots,
    );
  }
}

class _YearGrid extends StatelessWidget {
  const _YearGrid({
    required this.focused,
    required this.events,
    required this.indicators,
    required this.onDayTap,
    required this.onMonthTap,
    required this.weekStartsMonday,
    this.dayCellKeyBuilder,
    this.zoomSourceMonth,
    this.nonTransitionOpacity = 1,
    this.hideZoomSourceDayCells = false,
    this.fadeNonSourceMonthsOnly = false,
  });

  final DateTime focused;
  final List<CalendarEvent> events;
  final List<CalendarDayIndicator> indicators;
  final void Function(DateTime day) onDayTap;
  final void Function(DateTime month, Map<DateTime, Rect> dayGlobalRects)
  onMonthTap;
  final bool weekStartsMonday;
  final GlobalKey Function(DateTime ownerMonth, DateTime cellDate)?
  dayCellKeyBuilder;
  final DateTime? zoomSourceMonth;
  final double nonTransitionOpacity;
  final bool hideZoomSourceDayCells;
  final bool fadeNonSourceMonthsOnly;

  Map<DateTime, Rect> _collectDayRects(DateTime monthDate) {
    final rects = <DateTime, Rect>{};
    if (dayCellKeyBuilder == null) return rects;

    for (final date in monthGridDates(
      monthDate,
      weekStartsMonday: weekStartsMonday,
    )) {
      final key = dayCellKeyBuilder!(monthDate, date);
      final box = key.currentContext?.findRenderObject() as RenderBox?;
      if (box != null && box.hasSize && box.attached) {
        rects[date] = box.localToGlobal(Offset.zero) & box.size;
      }
    }
    return rects;
  }

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        childAspectRatio: 1.35,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
      ),
      itemCount: 12,
      itemBuilder: (_, i) {
        final month = i + 1;
        final monthDate = DateTime(focused.year, month);
        final isZoomSource = zoomSourceMonth != null &&
            monthDate.year == zoomSourceMonth!.year &&
            monthDate.month == zoomSourceMonth!.month;

        Widget monthTile = InkWell(
          onTap: () => onMonthTap(monthDate, _collectDayRects(monthDate)),
          borderRadius: BorderRadius.circular(18),
          child: Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    DateFormat.MMMM().format(monthDate),
                    style: Theme.of(context).textTheme.titleSmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 4),
                  Expanded(
                    child: hideZoomSourceDayCells && isZoomSource
                        ? const SizedBox.expand()
                        : MonthDayGrid(
                            month: monthDate,
                            events: events,
                            indicators: indicators,
                            weekStartsMonday: weekStartsMonday,
                            style: MonthDayCellStyle.compact,
                            dayCellKeyBuilder: dayCellKeyBuilder == null
                                ? null
                                : (date) =>
                                      dayCellKeyBuilder!(monthDate, date),
                          ),
                  ),
                ],
              ),
            ),
          ),
        );

        if (zoomSourceMonth != null) {
          final applyOpacity =
              !fadeNonSourceMonthsOnly || !isZoomSource;
          if (applyOpacity) {
            monthTile = Opacity(
              opacity: nonTransitionOpacity.clamp(0.0, 1.0),
              child: monthTile,
            );
          }
        }

        return monthTile;
      },
    );
  }
}

class _DayEventTile extends StatelessWidget {
  const _DayEventTile({required this.event, this.allDay = false});

  final CalendarEvent event;
  final bool allDay;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Color(event.colorValue).withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          if (!allDay) ...[
            Text(
              DateFormat.jm().format(event.start.toLocal()),
              style: AppFonts.style(fontSize: 11),
            ),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Text(event.title, style: AppFonts.style(fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

DateTime _weekStart(DateTime date, bool weekStartsMonday) {
  final weekday = date.weekday;
  final offset = weekStartsMonday ? weekday - DateTime.monday : weekday % 7;
  return DateTime(
    date.year,
    date.month,
    date.day,
  ).subtract(Duration(days: offset));
}
