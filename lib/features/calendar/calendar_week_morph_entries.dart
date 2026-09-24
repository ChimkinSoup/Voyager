import 'package:flutter/material.dart';
import 'package:voyager/core/theme/app_fonts.dart';
import 'package:voyager/core/theme/palette_color.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/domain/services/calendar_recurrence.dart';
import 'package:voyager/features/calendar/calendar_day_grid.dart';
import 'package:voyager/features/calendar/calendar_overlap_engine.dart';
import 'package:voyager/features/calendar/calendar_todo_markers.dart';

/// [CalendarDayCell]'s border stroke, which its content clip is inset by.
const _monthCellBorderWidth = 1.0;

/// Where an entry sits at one end of the month↔week morph, in calendar-area
/// coordinates.
class CalendarWeekMorphPill {
  const CalendarWeekMorphPill({
    required this.rect,
    required this.radius,
    required this.showTitle,
  });

  final Rect rect;
  final BorderRadius radius;
  final bool showTitle;
}

/// One day's segment of an event (or a todo bar) that the month↔week morph
/// drags between its month-cell pill and its week-view block.
///
/// An entry missing one end — past a cell's "+N", on an adjacent-month day,
/// or a todo, which the month cell draws as an icon — fades in place at the
/// end it has.
class CalendarWeekMorphEntry {
  const CalendarWeekMorphEntry({
    required this.id,
    required this.column,
    required this.timed,
    this.event,
    this.todo,
    this.month,
    this.week,
    this.monthFontSize = 0,
  });

  final String id;
  final int column;

  /// The week end is in the scrolled timed grid rather than the all-day
  /// shelf; its [week] rect is unscrolled.
  final bool timed;
  final CalendarEvent? event;
  final CalendarTodoMarker? todo;
  final CalendarWeekMorphPill? month;
  final CalendarWeekMorphPill? week;
  final double monthFontSize;
}

/// Content clip of the month cell at [monthCellRect] — what hides the parts
/// of its pills that bleed past the cell.
RRect calendarWeekMorphMonthClip(Rect monthCellRect) {
  final style = MonthDayCellStyle.full;
  return RRect.fromRectAndRadius(
    monthCellRect.deflate(style.cellMargin.left + _monthCellBorderWidth),
    Radius.circular(style.borderRadius - _monthCellBorderWidth),
  );
}

/// The week timed grid's viewport in the day column at [weekColumnRect].
RRect calendarWeekMorphTimedClip(Rect weekColumnRect) {
  final style = weekViewDayCellStyle;
  return RRect.fromRectAndRadius(
    weekColumnRect.deflate(style.cellMargin.left),
    Radius.circular(style.borderRadius),
  );
}

/// Both ends of every event and todo in the morphing week, laid out exactly
/// as [CalendarDayCell] (month) and [CalendarWeekTimeline] (week) draw them.
///
/// [monthRowRects] are the week row's month cells; [weekColumnRects] the
/// week view's timed day columns, below an all-day shelf sized for [events].
List<CalendarWeekMorphEntry> calendarWeekMorphEntries({
  required List<DateTime> weekDates,
  required DateTime month,
  required List<CalendarEvent> events,
  required List<CalendarTodoMarker> todoMarkers,
  required List<CalendarDayIndicator> indicators,
  required List<Rect> monthRowRects,
  required List<Rect> weekColumnRects,
}) {
  const radius = Radius.circular(calendarEventCornerRadius);
  final monthStyle = MonthDayCellStyle.full;
  final weekMargin = weekViewDayCellStyle.cellMargin.left;
  final monthPills = <String, (CalendarWeekMorphPill, double)>{};
  final weekPills = <String, (CalendarWeekMorphPill, bool)>{};
  final entries = <CalendarWeekMorphEntry>[];

  // Month: the lanes [CalendarDayCell] shows, clipped to the cell.
  final packed = calendarPackWeekEvents(weekDates, events);
  for (var c = 0; c < 7; c++) {
    final date = weekDates[c];
    if (date.month != month.month) continue;
    final dayEvents = packed[c];
    final hasIndicators = indicators.any((i) => calendarSameDay(i.day, date));
    final clip = calendarWeekMorphMonthClip(monthRowRects[c]).outerRect;
    final content = monthStyle.cellPadding.deflateRect(clip);
    final visible = calendarVisibleEventCount(
      cellHeight: content.height,
      style: monthStyle,
      eventCount: dayEvents.length,
      hasIndicators: hasIndicators,
    );
    final displayed = visible.clamp(0, monthStyle.maxEventLines);
    final barHeight = calendarMonthEventBarHeight(
      cellHeight: content.height,
      style: monthStyle,
      visibleEventCount: visible,
      hasIndicators: hasIndicators,
    );
    final fontSize = calendarMonthEventFontSize(
      barHeight: barHeight,
      style: monthStyle,
    );
    final barsTop =
        content.top +
        monthStyle.fontSize +
        8 +
        (hasIndicators ? 2 + monthStyle.dotSize : 0) +
        2;
    for (var k = 0; k < displayed && k < dayEvents.length; k++) {
      final event = dayEvents[k];
      if (event == null) continue;
      final isStart = calendarEventBarStartsOnDay(event, date);
      final isEnd = calendarEventBarEndsOnDay(event, date);
      // The 4th bar sits flush on the cell's rounded bottom edge, square-
      // cornered so the cell clip alone shapes it.
      final isBottom = displayed >= 4 && k == displayed - 1;
      monthPills['${event.id}@$c'] = (
        CalendarWeekMorphPill(
          // Every bar reaches past the content box to the clip, or beyond
          // it where it bridges to the next day.
          rect: Rect.fromLTWH(
            clip.left,
            barsTop + k * (barHeight + 1),
            clip.width,
            barHeight,
          ),
          radius: BorderRadius.only(
            topLeft: isStart ? radius : Radius.zero,
            topRight: isEnd ? radius : Radius.zero,
            bottomLeft: isStart && !isBottom ? radius : Radius.zero,
            bottomRight: isEnd && !isBottom ? radius : Radius.zero,
          ),
          showTitle: isStart,
        ),
        fontSize,
      );
    }
  }

  // Week: the all-day shelf, pinned above the timed columns.
  final shelf = calendarPackWeekAllDayShelf(
    events: events,
    weekDays: weekDates,
  );
  final shelfHeight = calendarWeekAllDayShelfHeightFor(
    events: events,
    weekDays: weekDates,
  );
  for (var c = 0; c < 7; c++) {
    final column = weekColumnRects[c];
    final shelfTop = column.top - shelfHeight + weekMargin;
    for (var r = 0; r < shelf[c].length; r++) {
      final event = shelf[c][r];
      if (event == null) continue;
      final (bridgeLeft, bridgeRight) = calendarWeekEventBridges(
        event,
        day: weekDates[c],
        isFirstColumn: c == 0,
        isLastColumn: c == 6,
      );
      final rect = Rect.fromLTRB(
        column.left + weekMargin - (bridgeLeft ? weekMargin + 2 : 0),
        shelfTop + r * calendarWeekAllDayEventRowHeight,
        column.right - weekMargin + (bridgeRight ? weekMargin + 2 : 0),
        shelfTop + (r + 1) * calendarWeekAllDayEventRowHeight,
      );
      weekPills['${event.id}@$c'] = (
        CalendarWeekMorphPill(
          rect: rect,
          radius: BorderRadius.horizontal(
            left: bridgeLeft ? Radius.zero : radius,
            right: bridgeRight ? Radius.zero : radius,
          ),
          showTitle: !bridgeLeft && rect.width >= 12,
        ),
        false,
      );
    }
  }

  // Week: the timed grid, laid out with the same todos it shares columns with.
  for (var c = 0; c < 7; c++) {
    final column = weekColumnRects[c];
    final innerLeft = column.left + weekMargin;
    final innerWidth = column.width - weekMargin * 2;
    final slots = layoutDayColumn(
      day: weekDates[c],
      events: events,
      todos: calendarTodoMarkersForDay(todoMarkers, weekDates[c]),
      pxPerHour: calendarWeekPxPerHour,
      taskBarHeight: calendarWeekTaskBarHeight,
    );
    for (final slot in slots) {
      final rect = Rect.fromLTWH(
        innerLeft + slot.left * innerWidth,
        column.top + weekMargin + calendarWeekTimelineScrollPadding + slot.top,
        slot.width * innerWidth,
        slot.height,
      );
      final todo = slot.entry.todo;
      if (todo != null) {
        entries.add(
          CalendarWeekMorphEntry(
            id: 'todo-${todo.taskId}@$c',
            column: c,
            timed: true,
            todo: todo,
            week: CalendarWeekMorphPill(
              rect: rect,
              radius: BorderRadius.zero,
              showTitle: false,
            ),
          ),
        );
        continue;
      }
      weekPills['${slot.entry.event!.id}@$c'] = (
        CalendarWeekMorphPill(
          rect: rect,
          radius: const BorderRadius.all(radius),
          showTitle: rect.width >= 12,
        ),
        true,
      );
    }
  }

  final byId = {for (final e in events) e.id: e};
  for (final key in {...monthPills.keys, ...weekPills.keys}) {
    final at = key.lastIndexOf('@');
    final monthPill = monthPills[key];
    final weekPill = weekPills[key];
    entries.add(
      CalendarWeekMorphEntry(
        id: key,
        column: int.parse(key.substring(at + 1)),
        timed: weekPill?.$2 ?? false,
        event: byId[key.substring(0, at)],
        month: monthPill?.$1,
        week: weekPill?.$1,
        monthFontSize: monthPill?.$2 ?? 0,
      ),
    );
  }
  return entries;
}

/// Paints [entries] at morph progress [t] (0 = month, 1 = week).
///
/// A pure function of [t], so week→month plays month→week exactly backwards.
/// Each entry is clipped by its day's cell as that cell grows into the week
/// column, so a timed block headed for an hour scrolled out of view slides
/// off the edge of the column instead of floating over the chrome.
class CalendarWeekMorphEntriesLayer extends StatelessWidget {
  const CalendarWeekMorphEntriesLayer({
    super.key,
    required this.entries,
    required this.t,
    required this.scrollOffset,
    required this.monthRowRects,
    required this.weekColumnRects,
  });

  final List<CalendarWeekMorphEntry> entries;
  final double t;
  final double scrollOffset;
  final List<Rect> monthRowRects;
  final List<Rect> weekColumnRects;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.none,
      children: [for (final entry in entries) _entry(context, entry)],
    );
  }

  Widget _entry(BuildContext context, CalendarWeekMorphEntry entry) {
    final monthClip = calendarWeekMorphMonthClip(monthRowRects[entry.column]);
    final month = entry.month;
    var week = entry.week;
    if (week != null && entry.timed) {
      week = CalendarWeekMorphPill(
        rect: week.rect.shift(Offset(0, -scrollOffset)),
        radius: week.radius,
        showTitle: week.showTitle,
      );
    }

    // An entry with one end fades there in the half of the morph nearest
    // that end, clear of the other view's layout still moving through.
    final Rect rect;
    final BorderRadius radius;
    final double opacity;
    final double styleT;
    if (month != null && week != null) {
      rect = Rect.lerp(month.rect, week.rect, t)!;
      radius = BorderRadius.lerp(month.radius, week.radius, t)!;
      opacity = 1;
      styleT = t;
    } else if (week != null) {
      rect = week.rect;
      radius = week.radius;
      opacity = ((t - 0.5) * 2).clamp(0.0, 1.0);
      styleT = 1;
    } else {
      rect = month!.rect;
      radius = month.radius;
      opacity = (1 - t * 2).clamp(0.0, 1.0);
      styleT = 0;
    }
    if (opacity <= 0) return const SizedBox.shrink();

    // Clip from the month cell to the timed viewport, or — for the shelf,
    // which sits outside the column — to the pill's own final shape.
    final Rect clip;
    final BorderRadius clipRadius;
    final monthClipRadius = BorderRadius.all(monthClip.tlRadius);
    if (week == null) {
      clip = monthClip.outerRect;
      clipRadius = monthClipRadius;
    } else if (entry.timed) {
      final timedClip = calendarWeekMorphTimedClip(
        weekColumnRects[entry.column],
      );
      clip = Rect.lerp(monthClip.outerRect, timedClip.outerRect, t)!;
      clipRadius = BorderRadius.lerp(
        monthClipRadius,
        BorderRadius.all(timedClip.tlRadius),
        t,
      )!;
    } else if (month != null) {
      clip = Rect.lerp(monthClip.outerRect, week.rect, t)!;
      clipRadius = BorderRadius.lerp(monthClipRadius, week.radius, t)!;
    } else {
      clip = rect;
      clipRadius = radius;
    }

    final todo = entry.todo;
    final Widget body = todo != null
        ? CalendarWeekTaskBar(marker: todo, onTap: () {})
        : _CalendarWeekMorphPillBody(
            key: ValueKey('week-morph-${entry.id}'),
            event: entry.event!,
            radius: radius,
            styleT: styleT,
            titleOpacity: switch ((
              month?.showTitle ?? week!.showTitle,
              week?.showTitle ?? month!.showTitle,
            )) {
              (true, true) => 1.0,
              (true, false) => 1 - t,
              (false, true) => t,
              (false, false) => 0.0,
            },
            monthFontSize: entry.monthFontSize,
          );

    return Positioned.fromRect(
      rect: clip,
      child: ClipRRect(
        borderRadius: clipRadius,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fromRect(
              rect: rect.shift(-clip.topLeft),
              child: Opacity(opacity: opacity, child: body),
            ),
          ],
        ),
      ),
    );
  }
}

/// An event pill partway ([styleT]) between [CalendarDayEventBar] and
/// [CalendarWeekEventBlock]: one title whose size, inset and alignment move
/// from the month bar's to the week block's, so it never doubles up.
class _CalendarWeekMorphPillBody extends StatelessWidget {
  const _CalendarWeekMorphPillBody({
    super.key,
    required this.event,
    required this.radius,
    required this.styleT,
    required this.titleOpacity,
    required this.monthFontSize,
  });

  final CalendarEvent event;
  final BorderRadius radius;
  final double styleT;
  final double titleOpacity;
  final double monthFontSize;

  @override
  Widget build(BuildContext context) {
    final color = paletteColor(event.colorValue, context).withAlpha(255);
    final labelColor = onColorLabel(color);
    final base = DefaultTextStyle.of(context).style;
    final style = TextStyle.lerp(
      base.merge(
        AppFonts.style(fontSize: monthFontSize, height: 1, color: labelColor),
      ),
      base.merge(TextStyle(fontSize: 10, color: labelColor)),
      styleT,
    );
    return DecoratedBox(
      decoration: calendarEventFillDecoration(color, borderRadius: radius),
      child: titleOpacity <= 0
          ? const SizedBox.expand()
          : LayoutBuilder(
              builder: (context, constraints) {
                return Opacity(
                  opacity: titleOpacity,
                  child: Padding(
                    padding: EdgeInsets.lerp(
                      const EdgeInsets.symmetric(horizontal: 4),
                      EdgeInsets.symmetric(
                        horizontal: constraints.maxWidth < 24 ? 2 : 6,
                        vertical: 4,
                      ),
                      styleT,
                    )!,
                    child: Align(
                      alignment: Alignment.lerp(
                        Alignment.centerLeft,
                        Alignment.topLeft,
                        styleT,
                      )!,
                      child: Text(
                        event.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: style,
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}
