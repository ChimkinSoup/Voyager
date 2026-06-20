import 'package:flutter/material.dart';
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
    this.indicators = const [],
    this.weekStartsMonday = true,
  });

  final CalendarViewMode mode;
  final DateTime focused;
  final List<CalendarEvent> events;
  final List<CalendarDayIndicator> indicators;
  final void Function(DateTime day) onDayTap;
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
      ),
    };
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
    final first = DateTime(focused.year, focused.month, 1);
    final daysInMonth = DateTime(focused.year, focused.month + 1, 0).day;
    final startWeekday = first.weekday;
    final leading = weekStartsMonday
        ? (startWeekday - 1) % 7
        : startWeekday % 7;
    final totalCells = leading + daysInMonth;
    final rowCount = (totalCells / 7).ceil();

    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children:
              (weekStartsMonday
                      ? const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']
                      : const ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'])
                  .map(
                    (d) => Expanded(
                      child: Center(
                        child: Text(
                          d,
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ),
                    ),
                  )
                  .toList(),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: Column(
            children: List.generate(rowCount, (row) {
              return Expanded(
                child: Row(
                  children: List.generate(7, (col) {
                    final index = row * 7 + col;
                    if (index < leading || index >= leading + daysInMonth) {
                      return const Expanded(child: SizedBox.shrink());
                    }
                    final day = index - leading + 1;
                    final date = DateTime(focused.year, focused.month, day);
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
                              Text('$day', style: AppFonts.style(fontSize: 11)),
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
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: List.generate(7, (i) {
        final date = start.add(Duration(days: i));
        final dayEvents = events.where((e) => _sameDay(e.start, date)).toList();
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
                  Text(
                    '${date.month}/${date.day}',
                    style: AppFonts.style(fontSize: 11),
                  ),
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
    );
  }
}

class _YearGrid extends StatelessWidget {
  const _YearGrid({
    required this.focused,
    required this.events,
    required this.indicators,
    required this.onDayTap,
  });

  final DateTime focused;
  final List<CalendarEvent> events;
  final List<CalendarDayIndicator> indicators;
  final void Function(DateTime day) onDayTap;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        childAspectRatio: 2.2,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
      ),
      itemCount: 12,
      itemBuilder: (_, i) {
        final month = i + 1;
        final count = events
            .where(
              (e) => e.start.year == focused.year && e.start.month == month,
            )
            .length;
        final statCount = indicators
            .where(
              (indicator) =>
                  indicator.day.year == focused.year &&
                  indicator.day.month == month,
            )
            .length;
        return InkWell(
          onTap: () => onDayTap(DateTime(focused.year, month, 1)),
          borderRadius: BorderRadius.circular(18),
          child: Card(
            margin: EdgeInsets.zero,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    DateTime(
                      focused.year,
                      month,
                    ).toString().split(' ')[0].split('-')[1],
                  ),
                  Text(
                    '$count events',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (statCount > 0)
                    Text(
                      '$statCount stats',
                      style: Theme.of(context).textTheme.bodySmall,
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

class _IndicatorDots extends StatelessWidget {
  const _IndicatorDots({required this.indicators});

  final List<CalendarDayIndicator> indicators;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 2,
      runSpacing: 2,
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

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

DateTime _weekStart(DateTime date, bool weekStartsMonday) {
  final weekday = date.weekday;
  final offset = weekStartsMonday ? weekday - DateTime.monday : weekday % 7;
  return DateTime(
    date.year,
    date.month,
    date.day,
  ).subtract(Duration(days: offset));
}
