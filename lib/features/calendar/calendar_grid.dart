import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:voyager/core/theme/app_fonts.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/domain/models/enums.dart';

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
  });

  final CalendarViewMode mode;
  final DateTime focused;
  final List<CalendarEvent> events;
  final List<CalendarDayIndicator> indicators;
  final void Function(DateTime day) onDayTap;
  final void Function(DateTime month) onMonthTap;
  final bool weekStartsMonday;

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
      ),
      CalendarViewMode.year => _YearGrid(
        focused: focused,
        events: events,
        indicators: indicators,
        onDayTap: onDayTap,
        onMonthTap: onMonthTap,
        weekStartsMonday: weekStartsMonday,
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

  static const _weekdayLabelsMonday = [
    'Mon',
    'Tue',
    'Wed',
    'Thu',
    'Fri',
    'Sat',
    'Sun',
  ];
  static const _weekdayLabelsSunday = [
    'Sun',
    'Mon',
    'Tue',
    'Wed',
    'Thu',
    'Fri',
    'Sat',
  ];

  @override
  Widget build(BuildContext context) {
    final cells = monthGridDates(month, weekStartsMonday: weekStartsMonday);
    final labels = weekStartsMonday
        ? _weekdayLabelsMonday
        : _weekdayLabelsSunday;

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
                        child: _DayNumberCell(
                          date: date,
                          month: month,
                          fontSize: 12,
                          onTap: () => onDayTap(date),
                          selected:
                              selectedDay != null &&
                              _sameDay(selectedDay!, date),
                          selectedIsSoft: true,
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
    final dayEvents = events.where((e) => _sameDay(e.start, day)).toList()
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

class _MonthGrid extends StatelessWidget {
  const _MonthGrid({
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
    final cells = monthGridDates(focused, weekStartsMonday: weekStartsMonday);
    final labels = weekStartsMonday
        ? MiniMonthCalendar._weekdayLabelsMonday
        : MiniMonthCalendar._weekdayLabelsSunday;

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
        const SizedBox(height: 4),
        Expanded(
          child: Column(
            children: List.generate(6, (row) {
              return Expanded(
                child: Row(
                  children: List.generate(7, (col) {
                    final date = cells[row * 7 + col];
                    final inMonth = date.month == focused.month;
                    final dayEvents = events
                        .where((e) => _sameDay(e.start, date))
                        .toList();
                    final dayIndicators = indicators
                        .where((i) => _sameDay(i.day, date))
                        .take(3)
                        .toList();
                    return Expanded(
                      child: InkWell(
                        onTap: () => onDayTap(date),
                        borderRadius: BorderRadius.circular(10),
                        child: Container(
                          margin: const EdgeInsets.all(1),
                          padding: const EdgeInsets.all(3),
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: Theme.of(context).dividerColor,
                            ),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _DayNumberCell(
                                date: date,
                                month: focused,
                                fontSize: 15,
                                mutedWhenAdjacent: !inMonth,
                              ),
                              if (dayIndicators.isNotEmpty) ...[
                                const SizedBox(height: 2),
                                _IndicatorDots(indicators: dayIndicators),
                              ],
                              if (dayEvents.isNotEmpty)
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: dayEvents.take(2).map((e) {
                                      return Container(
                                        margin: const EdgeInsets.only(top: 1),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 2,
                                        ),
                                        color: Color(
                                          e.colorValue,
                                        ).withValues(alpha: 0.45),
                                        child: Text(
                                          e.title,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: AppFonts.style(fontSize: 9),
                                        ),
                                      );
                                    }).toList(),
                                  ),
                                ),
                            ],
                          ),
                        ),
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
        ? MiniMonthCalendar._weekdayLabelsMonday
        : MiniMonthCalendar._weekdayLabelsSunday;
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
                  .where((e) => _sameDay(e.start, date))
                  .toList();
              final dayIndicators = indicators
                  .where((indicator) => _sameDay(indicator.day, date))
                  .take(4)
                  .toList();
              return Expanded(
                child: InkWell(
                  onTap: () => onDayTap(date),
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      border: Border.all(color: Theme.of(context).dividerColor),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _DayNumberCell(date: date, month: date, fontSize: 13),
                        const SizedBox(height: 2),
                        if (dayIndicators.isNotEmpty) ...[
                          _IndicatorDots(indicators: dayIndicators),
                          const SizedBox(height: 4),
                        ],
                        Expanded(
                          child: ListView(
                            padding: EdgeInsets.zero,
                            children: dayEvents
                                .map(
                                  (e) => Padding(
                                    padding: const EdgeInsets.only(bottom: 2),
                                    child: Row(
                                      children: [
                                        CircleAvatar(
                                          radius: 3,
                                          backgroundColor: Color(e.colorValue),
                                        ),
                                        const SizedBox(width: 4),
                                        Expanded(
                                          child: Text(
                                            e.title,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: AppFonts.style(fontSize: 10),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                )
                                .toList(),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
      ],
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
  });

  final DateTime focused;
  final List<CalendarEvent> events;
  final List<CalendarDayIndicator> indicators;
  final void Function(DateTime day) onDayTap;
  final void Function(DateTime month) onMonthTap;
  final bool weekStartsMonday;

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
        final count = events
            .where(
              (e) => e.start.year == focused.year && e.start.month == month,
            )
            .length;
        return InkWell(
          onTap: () => onMonthTap(monthDate),
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
                  if (count > 0)
                    Text(
                      '$count events',
                      style: Theme.of(context).textTheme.bodySmall,
                      textAlign: TextAlign.center,
                    ),
                  const SizedBox(height: 4),
                  Expanded(
                    child: _CompactMonthGrid(
                      month: monthDate,
                      weekStartsMonday: weekStartsMonday,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _CompactMonthGrid extends StatelessWidget {
  const _CompactMonthGrid({
    required this.month,
    required this.weekStartsMonday,
  });

  final DateTime month;
  final bool weekStartsMonday;

  @override
  Widget build(BuildContext context) {
    final cells = monthGridDates(month, weekStartsMonday: weekStartsMonday);

    return Column(
      children: List.generate(6, (row) {
        return Expanded(
          child: Row(
            children: List.generate(7, (col) {
              final date = cells[row * 7 + col];
              return Expanded(
                child: _DayNumberCell(
                  date: date,
                  month: month,
                  fontSize: 8,
                  mutedWhenAdjacent: date.month != month.month,
                ),
              );
            }),
          ),
        );
      }),
    );
  }
}

class _DayNumberCell extends StatelessWidget {
  const _DayNumberCell({
    required this.date,
    required this.month,
    required this.fontSize,
    this.onTap,
    this.selected = false,
    this.selectedIsSoft = false,
    this.mutedWhenAdjacent = false,
  });

  final DateTime date;
  final DateTime month;
  final double fontSize;
  final VoidCallback? onTap;
  final bool selected;
  final bool selectedIsSoft;
  final bool mutedWhenAdjacent;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final isToday = _isToday(date);
    final isAdjacent = date.month != month.month;
    final muted = mutedWhenAdjacent && isAdjacent;
    final diameter = fontSize + 10;

    final textStyle = AppFonts.style(
      fontSize: fontSize,
      fontWeight: isToday ? FontWeight.w600 : FontWeight.w500,
      color: isToday
          ? Theme.of(context).colorScheme.onPrimary
          : muted
          ? Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.55)
          : Theme.of(context).colorScheme.onSurface,
    );

    final child = Container(
      width: diameter,
      height: diameter,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: isToday ? accent : null,
        shape: BoxShape.circle,
        border: selected && !isToday
            ? Border.all(
                color: accent.withValues(alpha: selectedIsSoft ? 0.45 : 1),
                width: 2,
              )
            : null,
      ),
      child: Text('${date.day}', style: textStyle),
    );

    return Center(
      child: onTap == null
          ? child
          : InkWell(
              onTap: onTap,
              customBorder: const CircleBorder(),
              child: child,
            ),
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

class _IndicatorDots extends StatelessWidget {
  const _IndicatorDots({required this.indicators});

  final List<CalendarDayIndicator> indicators;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 2,
      runSpacing: 2,
      alignment: WrapAlignment.center,
      children: [
        for (final indicator in indicators)
          Tooltip(
            message: indicator.label,
            child: Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                color: Color(indicator.colorValue).withValues(
                  alpha: (0.35 + 0.65 * indicator.intensity).clamp(0.35, 1),
                ),
                shape: BoxShape.circle,
              ),
            ),
          ),
      ],
    );
  }
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

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

bool _isToday(DateTime date) {
  final now = DateTime.now();
  return _sameDay(date, now);
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
