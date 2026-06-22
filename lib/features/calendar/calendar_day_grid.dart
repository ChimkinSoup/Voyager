import 'dart:math' as math;

import 'dart:ui' show lerpDouble;

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
    cellPadding: EdgeInsets.all(3),
    cellMargin: EdgeInsets.all(1),
    maxEventLines: 2,
    dotSize: 7,
    eventFontSize: 9,
  );

  MonthDayCellStyle lerp(MonthDayCellStyle other, double t) {
    return MonthDayCellStyle(
      fontSize: lerpDouble(fontSize, other.fontSize, t)!,
      borderRadius: lerpDouble(borderRadius, other.borderRadius, t)!,
      cellPadding: EdgeInsets.lerp(cellPadding, other.cellPadding, t)!,
      cellMargin: EdgeInsets.lerp(cellMargin, other.cellMargin, t)!,
      maxEventLines: t < 0.5 ? maxEventLines : other.maxEventLines,
      dotSize: lerpDouble(dotSize, other.dotSize, t)!,
      eventFontSize: lerpDouble(eventFontSize, other.eventFontSize, t)!,
      borderOpacity: lerpDouble(borderOpacity, other.borderOpacity, t)!,
    );
  }

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
  });

  final DateTime date;
  final DateTime month;
  final List<CalendarEvent> events;
  final List<CalendarDayIndicator> indicators;
  final MonthDayCellStyle style;
  final VoidCallback? onTap;

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
    return LayoutBuilder(
      builder: (context, constraints) {
        final tight = constraints.maxHeight < 22;
        final showIndicators = indicators.isNotEmpty && !tight;
        final showEvents =
            events.isNotEmpty && style.maxEventLines > 0 && !tight;

        return FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: constraints.maxWidth,
              minWidth: constraints.maxWidth,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                CalendarDayNumber(
                  date: date,
                  month: month,
                  fontSize: style.fontSize,
                  mutedWhenAdjacent: !inMonth,
                ),
                if (showIndicators) ...[
                  SizedBox(height: style.maxEventLines > 1 ? 2 : 1),
                  CalendarDayIndicatorDots(
                    indicators: indicators,
                    dotSize: style.dotSize,
                  ),
                ],
                if (showEvents)
                  for (final event in events.take(style.maxEventLines))
                    Container(
                      margin: const EdgeInsets.only(top: 1),
                      padding: EdgeInsets.symmetric(
                        horizontal: style.maxEventLines > 1 ? 2 : 1,
                      ),
                      color: Color(event.colorValue).withValues(alpha: 0.45),
                      child: Text(
                        event.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppFonts.style(fontSize: style.eventFontSize),
                      ),
                    ),
              ],
            ),
          ),
        );
      },
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
  });

  final DateTime date;
  final DateTime month;
  final double fontSize;
  final bool mutedWhenAdjacent;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final isToday = calendarIsToday(date);
    final muted = mutedWhenAdjacent && date.month != month.month;
    final diameter = fontSize + (fontSize <= 9 ? 3 : 8);

    return Center(
      child: Container(
        width: diameter,
        height: diameter,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isToday ? accent : null,
          shape: BoxShape.circle,
        ),
        child: Text(
          '${date.day}',
          style: AppFonts.style(
            fontSize: fontSize,
            fontWeight: isToday ? FontWeight.w600 : FontWeight.w500,
            color: isToday
                ? Theme.of(context).colorScheme.onPrimary
                : muted
                ? Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.55)
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
  });

  final bool weekStartsMonday;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    final labels = weekStartsMonday
        ? calendarWeekdayLabelsMonday
        : calendarWeekdayLabelsSunday;
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
    this.dayCellKeyBuilder,
    this.showWeekdayHeader = false,
    this.weekdayHeaderOpacity = 1,
  });

  final DateTime month;
  final List<CalendarEvent> events;
  final List<CalendarDayIndicator> indicators;
  final bool weekStartsMonday;
  final MonthDayCellStyle style;
  final void Function(DateTime day)? onDayTap;
  final GlobalKey Function(DateTime date)? dayCellKeyBuilder;
  final bool showWeekdayHeader;
  final double weekdayHeaderOpacity;

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
          ),
          const SizedBox(height: MonthDayGridLayout.weekdayHeaderGap),
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
                    final cellKey = dayCellKeyBuilder?.call(date);

                    return Expanded(
                      child: KeyedSubtree(
                        key: cellKey,
                        child: CalendarDayCell(
                          date: date,
                          month: month,
                          events: dayEvents,
                          indicators: dayIndicators,
                          style: style,
                          onTap: onDayTap == null ? null : () => onDayTap!(date),
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

class MonthDayGridLayout {
  static const weekdayHeaderGap = 4.0;

  /// Measures the weekday label row height used by [MonthDayGrid].
  static double measureWeekdayHeaderHeight(
    BuildContext context, {
    required bool weekStartsMonday,
  }) {
    final style = Theme.of(context).textTheme.labelSmall;
    if (style == null) return 14 + weekdayHeaderGap;

    final labels = weekStartsMonday
        ? calendarWeekdayLabelsMonday
        : calendarWeekdayLabelsSunday;
    final textScaler = MediaQuery.textScalerOf(context);
    final textDirection = Directionality.of(context);

    var maxHeight = 0.0;
    for (final label in labels) {
      final painter = TextPainter(
        text: TextSpan(text: label, style: style),
        textDirection: textDirection,
        textScaler: textScaler,
      )..layout();
      maxHeight = math.max(maxHeight, painter.height);
    }
    return maxHeight + weekdayHeaderGap;
  }

  static Map<DateTime, Rect> computeFullCellRects({
    required Size areaSize,
    required DateTime month,
    required bool weekStartsMonday,
    required double weekdayHeaderHeight,
  }) {
    return mapDatesToSlotRects(
      month: month,
      weekStartsMonday: weekStartsMonday,
      slotRects: computeSlotRects(
        areaSize: areaSize,
        weekdayHeaderHeight: weekdayHeaderHeight,
      ),
    );
  }

  /// Slot geometry for a 6×7 month grid — identical for every month.
  static List<Rect> computeSlotRects({
    required Size areaSize,
    required double weekdayHeaderHeight,
  }) {
    final gridHeight = areaSize.height - weekdayHeaderHeight;
    final cellWidth = areaSize.width / 7;
    final cellHeight = gridHeight / 6;

    return List.generate(42, (i) {
      final row = i ~/ 7;
      final col = i % 7;
      return Rect.fromLTWH(
        col * cellWidth,
        weekdayHeaderHeight + row * cellHeight,
        cellWidth,
        cellHeight,
      );
    });
  }

  static Map<DateTime, Rect> mapDatesToSlotRects({
    required DateTime month,
    required bool weekStartsMonday,
    required List<Rect> slotRects,
  }) {
    final cells = monthGridDates(month, weekStartsMonday: weekStartsMonday);
    final rects = <DateTime, Rect>{};
    for (var i = 0; i < cells.length && i < slotRects.length; i++) {
      rects[cells[i]] = slotRects[i];
    }
    return rects;
  }

  /// Reads the 42 slot rects from a laid-out [MonthDayGrid] (calendar-area local space).
  static List<Rect> readSlotRectsFromKeys({
    required DateTime month,
    required bool weekStartsMonday,
    required GlobalKey Function(DateTime date) dayCellKeyBuilder,
    required RenderBox areaBox,
  }) {
    final stackOrigin = areaBox.localToGlobal(Offset.zero);
    final rects = <Rect>[];

    for (final date in monthGridDates(month, weekStartsMonday: weekStartsMonday)) {
      final key = dayCellKeyBuilder(date);
      final box = key.currentContext?.findRenderObject() as RenderBox?;
      if (box != null && box.hasSize && box.attached) {
        rects.add((box.localToGlobal(Offset.zero) & box.size).shift(-stackOrigin));
      } else {
        return const [];
      }
    }
    return rects;
  }

  /// Reads day-cell bounds from laid-out [MonthDayGrid] keys (calendar-area local space).
  static Map<DateTime, Rect> readCellRectsFromKeys({
    required DateTime month,
    required bool weekStartsMonday,
    required GlobalKey Function(DateTime date) dayCellKeyBuilder,
    required RenderBox areaBox,
  }) {
    final slotRects = readSlotRectsFromKeys(
      month: month,
      weekStartsMonday: weekStartsMonday,
      dayCellKeyBuilder: dayCellKeyBuilder,
      areaBox: areaBox,
    );
    if (slotRects.length < 42) return const {};
    return mapDatesToSlotRects(
      month: month,
      weekStartsMonday: weekStartsMonday,
      slotRects: slotRects,
    );
  }
}

/// Morphs individual day cells from year mini-month positions into month layout.
class MonthZoomMorphOverlay extends StatelessWidget {
  const MonthZoomMorphOverlay({
    super.key,
    required this.progress,
    required this.month,
    required this.fromLocalRects,
    required this.toLocalRects,
    required this.events,
    required this.indicators,
    required this.weekStartsMonday,
    this.zoomOut = false,
  });

  final double progress;
  final DateTime month;
  final Map<DateTime, Rect> fromLocalRects;
  final Map<DateTime, Rect> toLocalRects;
  final List<CalendarEvent> events;
  final List<CalendarDayIndicator> indicators;
  final bool weekStartsMonday;
  final bool zoomOut;

  @override
  Widget build(BuildContext context) {
    final styleProgress = zoomOut ? (1 - progress) : progress;
    final style =
        MonthDayCellStyle.compact.lerp(MonthDayCellStyle.full, styleProgress);
    final cells = monthGridDates(month, weekStartsMonday: weekStartsMonday);
    final headerOpacity = zoomOut
        ? (1 - ((progress - 0.55) / 0.4).clamp(0.0, 1.0))
        : ((progress - 0.55) / 0.4).clamp(0.0, 1.0);

    return Stack(
      clipBehavior: Clip.none,
      fit: StackFit.expand,
      children: [
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: WeekdayHeaderRow(
            weekStartsMonday: weekStartsMonday,
            opacity: headerOpacity,
          ),
        ),
        for (final date in cells)
          if (fromLocalRects[date] != null && toLocalRects[date] != null)
            Positioned.fromRect(
              rect: Rect.lerp(fromLocalRects[date]!, toLocalRects[date]!, progress)!,
              child: IgnorePointer(
                child: CalendarDayCell(
                  date: date,
                  month: month,
                  events: events
                      .where((e) => calendarSameDay(e.start, date))
                      .toList(),
                  indicators: indicators
                      .where((i) => calendarSameDay(i.day, date))
                      .take(3)
                      .toList(),
                  style: style,
                ),
              ),
            ),
      ],
    );
  }
}

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

const calendarWeekdayLabelsSunday = [
  'Sun',
  'Mon',
  'Tue',
  'Wed',
  'Thu',
  'Fri',
  'Sat',
];
