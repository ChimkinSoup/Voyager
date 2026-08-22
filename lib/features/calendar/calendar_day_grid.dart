import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/motion/motion.dart';
import 'package:voyager/core/theme/app_fonts.dart';
import 'package:voyager/core/theme/voyager_list_item_surface.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/widgets/context_menu.dart';
import 'package:voyager/core/widgets/contextual_popover.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/domain/services/calendar_recurrence.dart';
import 'package:voyager/features/calendar/calendar_day_entries.dart';
import 'package:voyager/features/calendar/calendar_todo_markers.dart';

/// Builds the right-click context-menu items for a calendar [CalendarDayEntry]
/// (an event or a due todo). Returning an empty list suppresses the menu.
typedef CalendarEntryMenuBuilder =
    List<ContextMenuItem> Function(CalendarDayEntry entry);

/// Wraps [child] in a [ContextMenuRegion] built from [builder] for [entry].
///
/// When [builder] is null or yields no items the [child] is returned unchanged,
/// so callers can thread an optional builder through the widget tree without
/// special-casing every site.
Widget calendarEntryContextMenu({
  required CalendarEntryMenuBuilder? builder,
  required CalendarDayEntry entry,
  required Widget child,
}) {
  if (builder == null) return child;
  final items = builder(entry);
  if (items.isEmpty) return child;
  return ContextMenuRegion(items: items, child: child);
}

// =============================================================================
// CalendarEventTapState — coordinates multi-day animation + popup anchor rect
// =============================================================================

/// Shared mutable state for all event-tap interactions within one calendar
/// page.  Hold an instance in the page state, expose it via
/// [CalendarEventTapScope], and read [tapAnchorRect] before opening a popup.
class CalendarEventTapState extends ChangeNotifier {
  String? _animatingEventId;
  Rect? _tapAnchorRect;

  String? get animatingEventId => _animatingEventId;
  Rect? get tapAnchorRect => _tapAnchorRect;

  /// Called by the tapped [CalendarInteractiveEventTap] segment.  Broadcasts
  /// the event ID so other segments of the same multi-day event animate, and
  /// records [widgetRect] (global screen coordinates) for popup anchoring.
  void notifyEventTap({required String eventId, required Rect widgetRect}) {
    _animatingEventId = eventId;
    _tapAnchorRect = widgetRect;
    notifyListeners();
  }
}

/// Plain [InheritedWidget] that carries [CalendarEventTapState] down the tree.
///
/// Using a plain [InheritedWidget] (not [InheritedNotifier]) means the
/// framework does NOT add its own listener to the notifier, which would
/// otherwise schedule spurious rebuilds and interfere with our synchronous
/// manual listeners.
class CalendarEventTapScope extends InheritedWidget {
  const CalendarEventTapScope({
    super.key,
    required this.tapState,
    required super.child,
  });

  final CalendarEventTapState tapState;

  @override
  bool updateShouldNotify(CalendarEventTapScope oldWidget) =>
      oldWidget.tapState != tapState;

  /// Returns the [CalendarEventTapState] using the O(1) inherited-element
  /// cache — without registering a rebuild dependency.
  static CalendarEventTapState? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<CalendarEventTapScope>()?.tapState;
}

// =============================================================================

List<List<CalendarEvent?>> calendarPackWeekEvents(
  List<DateTime> weekDates,
  List<CalendarEvent> allEvents,
) {
  final weekEvents = allEvents.where((e) {
    return weekDates.any((day) => calendarEventOccursOnDay(e, day));
  }).toList();

  weekEvents.sort((a, b) {
    final aStart = a.start.toLocal();
    final bStart = b.start.toLocal();
    final startCmp = aStart.compareTo(bStart);
    if (startCmp != 0) return startCmp;

    final aDuration = a.end.difference(a.start);
    final bDuration = b.end.difference(b.start);
    return bDuration.compareTo(aDuration);
  });

  final result = List<List<CalendarEvent?>>.generate(7, (_) => []);

  for (final event in weekEvents) {
    int availableRow = 0;
    while (true) {
      bool canFit = true;
      for (int c = 0; c < 7; c++) {
        if (calendarEventOccursOnDay(event, weekDates[c])) {
          if (result[c].length > availableRow &&
              result[c][availableRow] != null) {
            canFit = false;
            break;
          }
        }
      }
      if (canFit) break;
      availableRow++;
    }

    for (int c = 0; c < 7; c++) {
      if (calendarEventOccursOnDay(event, weekDates[c])) {
        while (result[c].length <= availableRow) {
          result[c].add(null);
        }
        result[c][availableRow] = event;
      }
    }
  }
  return result;
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

/// Border opacity for padding-week cells in the full month grid (fainter than text).
const calendarAdjacentMonthBorderOpacity = 0.10;

/// Background fill for the focused week row in month view (in-month days).
const calendarFocusedWeekHighlightOpacity = 0.16;

/// Background fill for focused-week days that fall outside the displayed month.
const calendarFocusedWeekAdjacentHighlightOpacity = 0.06;

/// Background fill for today, when it falls inside the focused week row.
/// Deliberately stronger than [calendarFocusedWeekHighlightOpacity] so today
/// still reads as one cell rather than dissolving into the week's band.
const calendarTodayHighlightOpacity = 0.34;

bool calendarDateInWeek(DateTime date, DateTime weekStart) {
  final start = DateUtils.dateOnly(weekStart);
  final day = DateUtils.dateOnly(date);
  final end = start.add(const Duration(days: 7));
  return !day.isBefore(start) && day.isBefore(end);
}

double calendarFocusedWeekHighlightAlpha({
  required DateTime date,
  required DateTime month,
  required DateTime? weekStart,
  double opacity = 1.0,
}) {
  if (weekStart == null || opacity <= 0) return 0;
  if (!calendarDateInWeek(date, weekStart)) return 0;
  final inMonth = date.month == month.month && date.year == month.year;
  final double base;
  if (DateUtils.isSameDay(date, DateTime.now())) {
    base = calendarTodayHighlightOpacity;
  } else {
    base = inMonth
        ? calendarFocusedWeekHighlightOpacity
        : calendarFocusedWeekAdjacentHighlightOpacity;
  }
  return base * opacity.clamp(0.0, 1.0);
}

/// Fill alpha for month-view event pills (background tint over the cell).
const calendarEventBarFillAlpha = 1.0;

/// Fill alpha for day-view event tiles.
const calendarDayEventTileFillAlpha = 0.48;

/// Corner radius for calendar event pills in month and week views.
const calendarEventCornerRadius = 9.0;

/// [CalendarDayCell]'s own border stroke width — explicit so its content
/// clip can be deflated by the exact same amount the border paints inward.
const _cellBorderWidth = 1.0;

BoxDecoration calendarEventFillDecoration(
  Color base, {
  double alpha = calendarEventBarFillAlpha,
  BorderRadius? borderRadius,
}) {
  return BoxDecoration(
    color: base.withValues(alpha: alpha),
    borderRadius: borderRadius,
  );
}

Color calendarTitleAccentColor(BuildContext context, {Color? accentColor}) =>
    accentColor ?? Theme.of(context).colorScheme.primary;

Color calendarWeekdayAccentColor(BuildContext context, {Color? accentColor}) =>
    Color.lerp(
      accentColor ?? Theme.of(context).colorScheme.primary,
      VoyagerColors.of(context).highlightWash,
      0.5,
    )!;

Color calendarAdjacentMonthColor(BuildContext context) => Theme.of(
  context,
).colorScheme.onSurface.withValues(alpha: calendarAdjacentMonthTextOpacity);

/// Black or white, whichever contrasts better against [background] — used for
/// text/icons painted directly on an arbitrary calendar color.
Color calendarContrastingLabelColor(Color background) =>
    background.computeLuminance() < 0.5 ? Colors.white : Colors.black;

TextStyle calendarWeekdayLabelStyle(
  BuildContext context, {
  double? fontSize,
  Color? accentColor,
}) {
  final size = calendarWeekdayFontSize(context, baseFontSize: fontSize);
  return Theme.of(context).textTheme.labelSmall!.copyWith(
    color: calendarWeekdayAccentColor(context, accentColor: accentColor),
    fontWeight: FontWeight.bold,
    fontSize: size,
    height: 1.0,
  );
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
    this.eventDotSize = 2.5,
    this.borderOpacity = 1,
  });

  final double fontSize;
  final double borderRadius;
  final EdgeInsets cellPadding;
  final EdgeInsets cellMargin;
  final int maxEventLines;
  final double dotSize;
  final double eventFontSize;
  final double eventDotSize;
  final double borderOpacity;

  static const compact = MonthDayCellStyle(
    fontSize: 7,
    borderRadius: 4,
    cellPadding: EdgeInsets.all(1),
    cellMargin: EdgeInsets.all(0.5),
    maxEventLines: 3,
    dotSize: 3.5,
    eventFontSize: 5.5,
    eventDotSize: 2,
    borderOpacity: 0,
  );

  static const full = MonthDayCellStyle(
    fontSize: 15,
    borderRadius: 10,
    cellPadding: EdgeInsets.fromLTRB(3, 5, 3, 3),
    cellMargin: EdgeInsets.all(1),
    maxEventLines: 4,
    dotSize: 7,
    eventFontSize: 9,
  );

  /// Year mini-month tiles use adaptive shrink-to-fit; month/week fill their slot.
  bool get isCompactLayout => fontSize <= 9 && eventFontSize < 8;
}

/// Day-cell density for the week view — also the morph end-state for month↔week.
const weekViewDayCellStyle = MonthDayCellStyle(
  fontSize: 13,
  borderRadius: 12,
  cellPadding: EdgeInsets.all(4),
  cellMargin: EdgeInsets.all(1),
  maxEventLines: 8,
  dotSize: 7,
  eventFontSize: 10,
  borderOpacity: 1,
);

/// Bordered day square shared by year mini-months and the full month grid.
class CalendarDayCell extends StatelessWidget {
  const CalendarDayCell({
    super.key,
    required this.date,
    required this.month,
    required this.events,
    required this.indicators,
    required this.style,
    this.todoMarkers = const [],
    this.showTodoIcons = true,
    this.hasWorkout = false,
    this.onTap,
    this.onEntryTap,
    this.entryMenuBuilder,
    this.isSelected = false,
    this.adjacentTextT,
    this.adjacentBorderT,
    this.hideEntries = false,
    this.entryOpacity = 1,
    this.dayNumberOpacity = 1,
    this.frozenEntryLayoutHeight,
    this.isFirstColumn = false,
    this.isLastColumn = false,
    this.editingEventId,
    this.weekHighlightAlpha = 0,
    this.accentColor,
  });

  final DateTime date;
  final DateTime month;
  final List<CalendarEvent?> events;
  final List<CalendarDayIndicator> indicators;
  final List<CalendarTodoMarker> todoMarkers;
  final MonthDayCellStyle style;
  final VoidCallback? onTap;
  final void Function(CalendarDayEntry entry)? onEntryTap;

  /// Builds the right-click menu for an event/todo entry in this cell. Null
  /// disables the context menu.
  final CalendarEntryMenuBuilder? entryMenuBuilder;
  final bool isSelected;
  final bool isFirstColumn;
  final bool isLastColumn;

  /// When set, the matching event bar in this cell glows while being edited.
  final String? editingEventId;

  /// When false, todo icons are hidden (e.g. during view morph animations).
  final bool showTodoIcons;

  /// Whether a workout was completed on this day. Already gated by the
  /// "show workouts on the calendar" setting by the time it reaches here.
  final bool hasWorkout;

  /// When set, adjacent-month day numbers lerp from muted (0) to active (1).
  final double? adjacentTextT;

  /// When set, adjacent-month borders lerp from muted (0) to active (1).
  final double? adjacentBorderT;

  /// When true, chronological entry stack is omitted (morph overlay paints items).
  final bool hideEntries;

  /// Fades the chronological entry stack (used during month↔week morph).
  final double entryOpacity;

  /// Fades the day number (used during month↔week morph).
  final double dayNumberOpacity;

  /// When set, event bars keep this layout height instead of growing with the cell.
  final double? frozenEntryLayoutHeight;

  /// Accent fill behind the cell for the currently focused week row.
  final double weekHighlightAlpha;

  /// Selected calendar's color; used for the focused-week highlight and the
  /// "today" circle. Falls back to the theme accent when null.
  final Color? accentColor;

  @override
  Widget build(BuildContext context) {
    final inMonth = date.month == month.month;
    final divider = Theme.of(context).dividerColor;
    final isFullLayout = !style.isCompactLayout;
    final accent = Theme.of(context).colorScheme.primary;
    final highlightColor = accentColor ?? accent;

    final Color borderColor;
    final double borderAlpha;
    if (!inMonth && isFullLayout && adjacentBorderT != null) {
      final t = adjacentBorderT!.clamp(0.0, 1.0);
      borderColor = Color.lerp(
        calendarAdjacentMonthColor(context),
        divider,
        t,
      )!;
      borderAlpha = lerpDouble(
        calendarAdjacentMonthBorderOpacity,
        style.borderOpacity,
        t,
      )!;
    } else if (inMonth || !isFullLayout) {
      borderColor = divider;
      borderAlpha = style.borderOpacity;
    } else {
      borderColor = calendarAdjacentMonthColor(context);
      borderAlpha = calendarAdjacentMonthBorderOpacity;
    }

    final cell = Container(
      width: double.infinity,
      height: double.infinity,
      margin: style.cellMargin,
      // Border and clip must trace the same curve. A single
      // Container(decoration: ..., child: ClipRRect(...)) doesn't do that —
      // Container derives its child's padding from BoxDecoration.padding
      // (== border.dimensions), so the ClipRRect ends up inset by the border's
      // full width from the *outer* edge (where Border.all paints its stroke
      // deflated inward, so the stroke's inner face sits one more width in
      // again) — content fell a whole border-width short of the stroke's
      // inner edge, leaving a gap. Painting the border via a sibling
      // DecoratedBox avoids that auto-inset, but content then reaches the
      // *outer* edge and paints over the stroke instead. Explicitly deflating
      // the clip by exactly [_cellBorderWidth] — matching the same deflate
      // Border.all applies internally — lines content up with the stroke's
      // inner face: no gap, no painting over the border.
      child: Stack(
        fit: StackFit.expand,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: weekHighlightAlpha > 0
                  ? highlightColor.withValues(
                      alpha: weekHighlightAlpha.clamp(0.0, 1.0),
                    )
                  : null,
              border: Border.all(
                width: _cellBorderWidth,
                color: borderColor.withValues(
                  alpha: borderAlpha.clamp(0.0, 1.0),
                ),
              ),
              borderRadius: BorderRadius.circular(style.borderRadius),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(_cellBorderWidth),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(
                (style.borderRadius - _cellBorderWidth).clamp(
                  0.0,
                  style.borderRadius,
                ),
              ),
              child: Padding(
                padding: style.cellPadding,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final useCompact =
                        style.isCompactLayout || constraints.maxHeight < 28;
                    return useCompact
                        ? _buildCompactCellContent(inMonth)
                        : _buildFullCellContent(inMonth, constraints.maxHeight);
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );

    if (onTap == null) return cell;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(style.borderRadius),
      canRequestFocus: false,
      child: cell,
    );
  }

  Widget _buildFullCellContent(bool inMonth, double cellHeight) {
    final layoutHeight = frozenEntryLayoutHeight ?? cellHeight;
    final dayNumberHeight = style.fontSize + 8;
    var headerUsed = dayNumberHeight;
    if (indicators.isNotEmpty) {
      headerUsed += 2 + style.dotSize;
    }
    const eventGap = 2.0;
    final eventAreaHeight = (layoutHeight - headerUsed - eventGap).clamp(
      0.0,
      double.infinity,
    );
    final visibleEvents = calendarVisibleEventCount(
      cellHeight: layoutHeight,
      style: style,
      eventCount: events.length,
      hasIndicators: indicators.isNotEmpty,
    );
    final barHeight = visibleEvents > 0
        ? calendarMonthEventBarHeight(
            cellHeight: layoutHeight,
            style: style,
            visibleEventCount: visibleEvents,
            hasIndicators: indicators.isNotEmpty,
          )
        : 0.0;
    final availableHeight = (cellHeight - headerUsed - eventGap).clamp(
      0.0,
      double.infinity,
    );
    final maxEventAreaHeight = visibleEvents >= 4
        ? availableHeight + style.cellPadding.bottom
        : availableHeight;
    final clampedEventAreaHeight = eventAreaHeight.clamp(
      0.0,
      maxEventAreaHeight,
    );

    final showTodos = inMonth && showTodoIcons && todoMarkers.isNotEmpty;

    final packedEvents = events.whereType<CalendarEvent>().toList(
      growable: false,
    );
    final overflowCount = packedEvents.length > style.maxEventLines
        ? packedEvents.length - style.maxEventLines
        : 0;
    final overflowEvents = overflowCount > 0
        ? packedEvents.sublist(style.maxEventLines)
        : const <CalendarEvent>[];
    final displayedEventCount = visibleEvents.clamp(0, style.maxEventLines);

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Opacity(
              opacity: dayNumberOpacity.clamp(0.0, 1.0),
              child: CalendarDayNumber(
                date: date,
                month: month,
                fontSize: style.fontSize,
                mutedWhenAdjacent: !inMonth,
                adjacentTextT: adjacentTextT,
                isSelected: isSelected,
                accentColor: accentColor,
                leading: inMonth && hasWorkout
                    ? CalendarWorkoutIcon(
                        fontSize: style.fontSize,
                        color: accentColor,
                      )
                    : null,
              ),
            ),
            if (indicators.isNotEmpty) ...[
              const SizedBox(height: 2),
              Opacity(
                opacity: entryOpacity.clamp(0.0, 1.0),
                child: CalendarDayIndicatorDots(
                  indicators: indicators,
                  dotSize: style.dotSize,
                ),
              ),
            ],
            if (inMonth && displayedEventCount > 0 && !hideEntries) ...[
              const SizedBox(height: 2),
              Opacity(
                opacity: entryOpacity.clamp(0.0, 1.0),
                child: SizedBox(
                  height: clampedEventAreaHeight,
                  child: OverflowBox(
                    maxHeight: double.infinity,
                    alignment: Alignment.topCenter,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var i = 0; i < displayedEventCount; i++) ...[
                          if (i > 0) const SizedBox(height: 1),
                          SizedBox(
                            height: barHeight,
                            child: i < events.length && events[i] != null
                                ? LayoutBuilder(
                                    builder: (context, constraints) {
                                      final eventFontSize =
                                          calendarMonthEventFontSize(
                                            barHeight: barHeight,
                                            style: style,
                                          );
                                      final event = events[i]!;
                                      final eventEntry = event.isFullDay
                                          ? CalendarDayEntry.allDayEvent(
                                              event,
                                              day: date,
                                            )
                                          : CalendarDayEntry.timedEvent(
                                              event,
                                              day: date,
                                            );
                                      return calendarEntryContextMenu(
                                        builder: entryMenuBuilder,
                                        entry: eventEntry,
                                        child: CalendarDayEventBar(
                                          event: event,
                                          date: date,
                                          fontSize: eventFontSize,
                                          height: barHeight,
                                          isStart: calendarEventBarStartsOnDay(
                                            event,
                                            date,
                                          ),
                                          isEnd: calendarEventBarEndsOnDay(
                                            event,
                                            date,
                                          ),
                                          isFirstColumn: isFirstColumn,
                                          isLastColumn: isLastColumn,
                                          isBottom:
                                              displayedEventCount >= 4 &&
                                              i == displayedEventCount - 1,
                                          cellMargin: style.cellMargin,
                                          cellPadding: style.cellPadding,
                                          highlighted:
                                              editingEventId == event.id,
                                          onTap: onEntryTap == null
                                              ? null
                                              : () => onEntryTap!(eventEntry),
                                        ),
                                      );
                                    },
                                  )
                                : null,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
        if (inMonth && overflowCount > 0 && !hideEntries)
          Positioned(
            top: 0,
            right: 0,
            child: Opacity(
              opacity: entryOpacity.clamp(0.0, 1.0),
              child: _CalendarDayOverflowBadge(
                extraCount: overflowCount,
                onTap: onEntryTap == null
                    ? null
                    : (badgeContext) => _showOverflowEventsPopover(
                        badgeContext: badgeContext,
                        day: date,
                        overflowEvents: overflowEvents,
                        editingEventId: editingEventId,
                        onEntryTap: onEntryTap!,
                        entryMenuBuilder: entryMenuBuilder,
                      ),
              ),
            ),
          ),
        if (showTodos && todoMarkers.isNotEmpty)
          Positioned(
            right: 0,
            bottom: 0,
            child: Opacity(
              opacity: entryOpacity.clamp(0.0, 1.0),
              child: Builder(
                builder: (todoContext) {
                  return GestureDetector(
                    onTap: onEntryTap == null
                        ? null
                        : () {
                            _showTodoPopover(
                              badgeContext: todoContext,
                              day: date,
                              todos: todoMarkers,
                              onEntryTap: onEntryTap!,
                              entryMenuBuilder: entryMenuBuilder,
                            );
                          },
                    behavior: HitTestBehavior.opaque,
                    child: Padding(
                      padding: const EdgeInsets.all(2.0),
                      child: CalendarDayTodoIcons(markers: todoMarkers),
                    ),
                  );
                },
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildCompactCellContent(bool inMonth) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Opacity(
            opacity: dayNumberOpacity.clamp(0.0, 1.0),
            child: CalendarDayNumber(
              date: date,
              month: month,
              fontSize: style.fontSize,
              mutedWhenAdjacent: !inMonth,
              adjacentTextT: adjacentTextT,
              isSelected: isSelected,
              accentColor: accentColor,
            ),
          ),
        ),
        if (inMonth && events.isNotEmpty) ...[
          const SizedBox(height: 1),
          CalendarFadedEventDots(
            events: events
                .where((e) => e != null)
                .cast<CalendarEvent>()
                .toList(),
            dotSize: style.eventDotSize,
            maxDots: style.maxEventLines,
            baseOpacity: entryOpacity,
          ),
        ],
        if (inMonth && showTodoIcons && todoMarkers.isNotEmpty) ...[
          const SizedBox(height: 1),
          Opacity(
            opacity: entryOpacity.clamp(0.0, 1.0),
            child: Builder(
              builder: (todoContext) {
                return GestureDetector(
                  onTap: onEntryTap == null
                      ? null
                      : () {
                          _showTodoPopover(
                            badgeContext: todoContext,
                            day: date,
                            todos: todoMarkers,
                            onEntryTap: onEntryTap!,
                          );
                        },
                  behavior: HitTestBehavior.opaque,
                  child: Padding(
                    padding: const EdgeInsets.all(2.0),
                    child: CalendarDayTodoIcons(markers: todoMarkers),
                  ),
                );
              },
            ),
          ),
        ],
      ],
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
    this.adjacentTextT,
    this.isSelected = false,
    this.accentColor,
    this.leading,
  });

  final DateTime date;
  final DateTime month;
  final double fontSize;
  final bool mutedWhenAdjacent;

  /// Small marker rendered immediately before the number (currently the
  /// worked-out icon). Sits inside the same centred row so the pair stays
  /// visually anchored to the date rather than floating in the cell.
  final Widget? leading;

  /// Lerps adjacent-month text from muted (0) to active (1). Ignored when null.
  final double? adjacentTextT;
  final bool isSelected;

  /// Selected calendar's color; fills the "today" circle. Falls back to the
  /// theme accent when null.
  final Color? accentColor;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final todayColor = accentColor ?? accent;
    final isToday = calendarIsToday(date);
    final muted = mutedWhenAdjacent && date.month != month.month;
    final mutedColor = calendarAdjacentMonthColor(context);
    final onSurface = Theme.of(context).colorScheme.onSurface;
    // Smoothly scale the circle padding based on fontSize (7 = year view, 15 = month view)
    final paddingT = ((fontSize - 7) / (15 - 7)).clamp(0.0, 1.0);
    final padding = 5 + 3 * paddingT;
    final diameter = fontSize + padding;
    final showSelection = isSelected && !isToday && !muted;

    Color textColor;
    if (isToday) {
      textColor = accentColor != null
          ? calendarContrastingLabelColor(todayColor)
          : Theme.of(context).colorScheme.onPrimary;
    } else if (muted && adjacentTextT != null) {
      textColor = Color.lerp(
        mutedColor,
        onSurface,
        adjacentTextT!.clamp(0.0, 1.0),
      )!;
    } else if (muted) {
      textColor = mutedColor;
    } else {
      textColor = onSurface;
    }

    final dayNumber = Container(
      width: diameter,
      height: diameter,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: isToday
            ? todayColor
            : showSelection
            ? todayColor.withValues(alpha: 0.2)
            : null,
        shape: BoxShape.circle,
        border: showSelection ? Border.all(color: todayColor) : null,
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
          color: textColor,
        ),
      ),
    );

    final positioned = (fontSize <= 9) && isToday
        ? Transform.translate(offset: const Offset(0, -0.5), child: dayNumber)
        : dayNumber;

    return Center(
      child: leading == null
          ? positioned
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [leading!, const SizedBox(width: 1), positioned],
            ),
    );
  }
}

/// The worked-out marker shown beside a day's number when the calendar
/// workout setting is on. Deliberately tiny and unlabelled — it is a presence
/// indicator, not a data point.
class CalendarWorkoutIcon extends StatelessWidget {
  const CalendarWorkoutIcon({super.key, required this.fontSize, this.color});

  final double fontSize;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Icon(
      PhosphorIconsFill.barbell,
      size: (fontSize * 0.85).clamp(8.0, 14.0),
      color: color ?? Theme.of(context).colorScheme.primary,
    );
  }
}

/// How many event bars fit in a full-layout month day cell.
int calendarVisibleEventCount({
  required double cellHeight,
  required MonthDayCellStyle style,
  required int eventCount,
  required bool hasIndicators,
}) {
  if (eventCount == 0 || style.maxEventLines <= 0) return 0;

  final dayNumberHeight = style.fontSize + 8;
  var used = dayNumberHeight;

  if (hasIndicators) {
    used += 2 + style.dotSize;
  }

  const eventGap = 2.0;
  const minBarHeight = 8.0;
  final available = cellHeight - used - eventGap;
  if (available < minBarHeight) return 0;

  final fit = (available / minBarHeight).floor();
  return fit.clamp(0, style.maxEventLines).clamp(0, eventCount);
}

/// Per-event bar height matching [CalendarDayCell]'s expanded month layout.
double calendarMonthEventBarHeight({
  required double cellHeight,
  required MonthDayCellStyle style,
  required int visibleEventCount,
  bool hasIndicators = false,
}) {
  if (visibleEventCount <= 0) return 0;

  final dayNumberHeight = style.fontSize + 8;
  var headerUsed = dayNumberHeight;
  if (hasIndicators) {
    headerUsed += 2 + style.dotSize;
  }
  const eventGap = 2.0;
  const betweenEventGap = 1.0;
  final slotCount = style.maxEventLines.clamp(1, style.maxEventLines);
  var eventAreaHeight = (cellHeight - headerUsed - eventGap).clamp(
    0.0,
    double.infinity,
  );
  if (visibleEventCount >= 4) {
    eventAreaHeight += style.cellPadding.bottom;
  }
  final slotGaps = (slotCount - 1) * betweenEventGap;
  return ((eventAreaHeight - slotGaps) / slotCount).clamp(0.0, double.infinity);
}

double calendarMonthEventFontSize({
  required double barHeight,
  required MonthDayCellStyle style,
}) {
  return (barHeight - 4).clamp(6.0, style.eventFontSize).toDouble();
}

int _morphMonthLayoutEventCount({
  required double cellHeight,
  required int eventCount,
}) {
  return calendarVisibleEventCount(
    cellHeight: cellHeight,
    style: MonthDayCellStyle.full,
    eventCount: eventCount,
    hasIndicators: false,
  );
}

/// Event-dot row Y for compact year tiles — matches [CalendarDayCell] column layout.
double _compactYearDotsTop(double cellHeight) {
  final dayHeight = MonthDayCellStyle.compact.fontSize + 5;
  const gap = 1.0;
  const dotHeight = 2.0;
  final blockTop = (cellHeight - dayHeight - gap - dotHeight) / 2;
  return blockTop + dayHeight + gap;
}

/// Inner content height of a full-month morph cell (margin + padding stripped).
double calendarMorphMonthInnerCellHeight(double outerCellHeight) {
  const margin = 1.0 * 2; // MonthDayCellStyle.full.cellMargin.top × 2
  final padding = MonthDayCellStyle.full.cellPadding.vertical;
  return outerCellHeight - margin - padding;
}

/// Day-number layout diameter at full month scale — matches [_MorphCell].
double calendarMorphMonthDayLayoutSize(double innerCellHeight) {
  const fullFontSize = 15.0;
  return (fullFontSize + 8).clamp(0.0, innerCellHeight);
}

/// Pre-computes frozen event metrics for event counts 0…[MorphDayEventStack.maxMonthEvents].
List<MorphDayEventFrozenMetrics> calendarMorphEventFrozenMetrics({
  required double monthCellOuterHeight,
}) {
  final cellHeight = calendarMorphMonthInnerCellHeight(monthCellOuterHeight);
  final layoutDay = calendarMorphMonthDayLayoutSize(cellHeight);
  return List.generate(
    MorphDayEventStack.maxMonthEvents + 1,
    (count) => MorphDayEventFrozenMetrics.fromLayout(
      cellHeight: cellHeight,
      layoutDay: layoutDay,
      eventCount: count,
    ),
  );
}

/// Month-layout metrics for month→year morph.
///
/// Cell height shrinks every animation frame; freezing bar stride/height avoids
/// per-frame layout drift. Values are pre-computed in [CalendarLayoutCache].
class MorphDayEventFrozenMetrics {
  const MorphDayEventFrozenMetrics({
    required this.monthEventsTop,
    required this.barHeight,
    required this.barStride,
    required this.eventFontSize,
    required this.monthLayoutCount,
  });

  final double monthEventsTop;
  final double barHeight;
  final double barStride;
  final double eventFontSize;
  final int monthLayoutCount;

  static MorphDayEventFrozenMetrics fromLayout({
    required double cellHeight,
    required double layoutDay,
    required int eventCount,
  }) {
    final capped = eventCount.clamp(0, MorphDayEventStack.maxMonthEvents);
    final monthLayoutCount = _morphMonthLayoutEventCount(
      cellHeight: cellHeight,
      eventCount: capped,
    );
    final visible = monthLayoutCount.clamp(
      1,
      MorphDayEventStack.maxMonthEvents,
    );
    final barHeight = calendarMonthEventBarHeight(
      cellHeight: cellHeight,
      style: MonthDayCellStyle.full,
      visibleEventCount: visible,
    );
    return MorphDayEventFrozenMetrics(
      monthEventsTop: layoutDay + 2,
      barHeight: barHeight,
      barStride: barHeight + 1,
      eventFontSize: calendarMonthEventFontSize(
        barHeight: barHeight,
        style: MonthDayCellStyle.full,
      ),
      monthLayoutCount: monthLayoutCount,
    );
  }
}

/// Morphs year-view event dots into month-view bars during year↔month zoom.
///
/// Both directions share one [styleT] timeline (0 = year dots, 1 = full month bars):
/// bottom-up in-place shrink/grow per event, then dot-row travel. Year→month runs
/// styleT forward; month→year runs it backward — exact opposites.
class MorphDayEventStack extends StatefulWidget {
  const MorphDayEventStack({
    super.key,
    required this.events,
    required this.date,
    required this.styleT,
    required this.inMonth,
    required this.maxWidth,
    required this.cellHeight,
    required this.dayLayoutSize,
    required this.morphReverse,
    this.layoutDayLayoutSize,
    this.frozenMetrics,
    this.opacity = 1,
  });

  final List<CalendarEvent?> events;
  final DateTime date;
  final double styleT;
  final bool inMonth;
  final double maxWidth;
  final double cellHeight;
  final double dayLayoutSize;
  final bool morphReverse;

  /// Frozen day-number size for month bar/dot layout during month→year morph.
  final double? layoutDayLayoutSize;

  /// Pre-computed from [CalendarLayoutCache] — avoids per-cell work on frame 1.
  final MorphDayEventFrozenMetrics? frozenMetrics;

  /// Fades year dots during chained week↔year zoom transitions.
  final double opacity;

  static const maxYearDots = 3;
  static const maxMonthEvents = 4;
  static const yearDotSize = 2.0; // MonthDayCellStyle.compact.eventDotSize
  /// Each event (bottom-up) shrinks/grows during this styleT span.
  static const reverseSlotSegment = 0.09;

  /// After all slots finish, dots travel between the year row and month rows.
  static const reverseMoveDuration = 0.30;

  /// Month→year hands off to the static year layout only near styleT = 0 so the
  /// day number does not jump while [cellAlignment] is still lerping.
  static const yearLayoutHandoffStyleT = 0.02;

  /// Whether [_MorphCell] should hand off to the static compact year layout.
  static bool yearDotsSettled({
    required bool morphReverse,
    required int eventCount,
    required double styleT,
  }) {
    if (!morphReverse) return false;
    if (styleT >= yearLayoutHandoffStyleT) return false;
    if (eventCount == 0) return true;
    final capped = eventCount.clamp(0, maxMonthEvents);
    return reverseDotMoveT(count: capped, styleT: styleT) >= 1.0;
  }

  /// Eased dot-row travel progress for month→year (0 = month rows, 1 = year row).
  static double reverseDotMoveEased({
    required int count,
    required double styleT,
  }) {
    if (count <= 0) return 0.0;
    return Curves.easeInOutCubic.transform(
      reverseDotMoveT(count: count, styleT: styleT),
    );
  }

  /// Bottom-up morph progress. 0 = full bar, 1 = shrunk to dot / vanished.
  static double reverseSlotShrinkT({
    required int index,
    required int count,
    required double styleT,
  }) {
    if (count <= 0) return 1.0;
    final bottomUpOrder = count - 1 - index;
    final end = 1.0 - bottomUpOrder * reverseSlotSegment;
    final start = end - reverseSlotSegment;
    if (styleT >= end) return 0.0;
    if (styleT <= start) return 1.0;
    return ((end - styleT) / (end - start)).clamp(0.0, 1.0);
  }

  /// 0 = dots at month rows, 1 = dots at year row.
  static double reverseDotMoveT({required int count, required double styleT}) {
    if (count <= 0) return 0.0;
    final shrinkPhaseEnd = 1.0 - count * reverseSlotSegment;
    if (styleT >= shrinkPhaseEnd) return 0.0;
    final moveStart = shrinkPhaseEnd - reverseMoveDuration;
    if (styleT <= moveStart) return 1.0;
    return ((shrinkPhaseEnd - styleT) / reverseMoveDuration).clamp(0.0, 1.0);
  }

  static double _yearDotXOffset(int index, int dotCount, double dotSize) {
    if (dotCount <= 1) return 0;
    final spacing = dotSize + 1;
    return -((dotCount - 1) * spacing) / 2 + index * spacing;
  }

  @override
  State<MorphDayEventStack> createState() => _MorphDayEventStackState();
}

class _MorphDayEventStackState extends State<MorphDayEventStack> {
  int _displayCount() {
    final cappedCount = widget.events.length.clamp(
      0,
      MorphDayEventStack.maxMonthEvents,
    );
    if (cappedCount == 0) return 0;
    if (!widget.inMonth && widget.styleT <= 0) return 0;
    return cappedCount;
  }

  @override
  Widget build(BuildContext context) {
    final cappedCount = widget.events.length.clamp(
      0,
      MorphDayEventStack.maxMonthEvents,
    );
    final count = _displayCount();
    if (count == 0) return const SizedBox.shrink();

    final reverseMove = MorphDayEventStack.reverseDotMoveEased(
      count: cappedCount,
      styleT: widget.styleT,
    );

    final frozen = widget.frozenMetrics;
    final frozenMonthEventsTop =
        frozen?.monthEventsTop ??
        (widget.layoutDayLayoutSize ?? widget.dayLayoutSize) + 2;
    final frozenBarHeight =
        frozen?.barHeight ??
        calendarMonthEventBarHeight(
          cellHeight: widget.cellHeight,
          style: MonthDayCellStyle.full,
          visibleEventCount: cappedCount.clamp(
            1,
            MorphDayEventStack.maxMonthEvents,
          ),
        );
    final frozenBarStride = frozen?.barStride ?? frozenBarHeight + 1;
    final frozenEventFontSize =
        frozen?.eventFontSize ??
        calendarMonthEventFontSize(
          barHeight: frozenBarHeight,
          style: MonthDayCellStyle.full,
        );

    const yearDotSize = MorphDayEventStack.yearDotSize;
    final yearDotCount = widget.inMonth
        ? cappedCount.clamp(0, MorphDayEventStack.maxYearDots)
        : 0;
    final yearEventsTop = _compactYearDotsTop(widget.cellHeight);

    final slotShrinkEased = List<double>.filled(count, 0);
    for (var i = 0; i < count; i++) {
      slotShrinkEased[i] = Curves.easeInOutCubic.transform(
        MorphDayEventStack.reverseSlotShrinkT(
          index: i,
          count: count,
          styleT: widget.styleT,
        ),
      );
    }

    final yearXOffsets = List<double>.filled(MorphDayEventStack.maxYearDots, 0);
    if (widget.inMonth && yearDotCount > 1) {
      for (var i = 0; i < yearDotCount; i++) {
        yearXOffsets[i] = MorphDayEventStack._yearDotXOffset(
          i,
          yearDotCount,
          yearDotSize,
        );
      }
    }

    return Opacity(
      opacity: widget.opacity.clamp(0.0, 1.0),
      child: RepaintBoundary(
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            for (var i = count - 1; i >= MorphDayEventStack.maxYearDots; i--)
              if (widget.events[i] != null)
                _buildEventMarker(
                  event: widget.events[i]!,
                  index: i,
                  dotSize: yearDotSize,
                  reverseMove: reverseMove,
                  yearEventsTop: yearEventsTop,
                  frozenMonthEventsTop: frozenMonthEventsTop,
                  frozenBarStride: frozenBarStride,
                  frozenBarHeight: frozenBarHeight,
                  frozenEventFontSize: frozenEventFontSize,
                  shrinkEased: slotShrinkEased[i],
                  yearX: 0,
                ),
            for (
              var i = 0;
              i < count && i < MorphDayEventStack.maxYearDots;
              i++
            )
              if (widget.events[i] != null)
                _buildEventMarker(
                  event: widget.events[i]!,
                  index: i,
                  dotSize: yearDotSize,
                  reverseMove: reverseMove,
                  yearEventsTop: yearEventsTop,
                  frozenMonthEventsTop: frozenMonthEventsTop,
                  frozenBarStride: frozenBarStride,
                  frozenBarHeight: frozenBarHeight,
                  frozenEventFontSize: frozenEventFontSize,
                  shrinkEased: slotShrinkEased[i],
                  yearX: yearXOffsets[i],
                ),
          ],
        ),
      ),
    );
  }

  Widget _buildEventMarker({
    required CalendarEvent event,
    required int index,
    required double dotSize,
    required double shrinkEased,
    required double yearX,
    required double reverseMove,
    required double yearEventsTop,
    required double frozenMonthEventsTop,
    required double frozenBarStride,
    required double frozenBarHeight,
    required double frozenEventFontSize,
  }) {
    final isDotSlot = index < MorphDayEventStack.maxYearDots;

    final isStart = calendarEventBarStartsOnDay(event, widget.date);
    final isEnd = calendarEventBarEndsOnDay(event, widget.date);
    // isStart/isEnd sides extend into the cell padding to exactly match
    // CalendarDayEventBar (left: -cellPadding.left). Without this the morph
    // layer bar would be narrower than the regular-grid bar at t=0, producing
    // an instant visual snap when the morph takes over.
    final bridgeLeft = isStart
        ? MonthDayCellStyle.full.cellPadding.left
        : MonthDayCellStyle.full.cellMargin.left +
              MonthDayCellStyle.full.cellPadding.left +
              1.0;
    final bridgeRight = isEnd
        ? MonthDayCellStyle.full.cellPadding.right
        : MonthDayCellStyle.full.cellMargin.right +
              MonthDayCellStyle.full.cellPadding.right +
              1.0;
    final currentBridgeLeft = lerpDouble(bridgeLeft, 0, shrinkEased)!;
    final currentBridgeRight = lerpDouble(bridgeRight, 0, shrinkEased)!;

    if (!isDotSlot) {
      final shrinkT = shrinkEased;
      if (shrinkT >= 1.0) return const SizedBox.shrink();
      if (shrinkT <= 0.0) {
        final ownY = frozenMonthEventsTop + index * frozenBarStride;
        final maxTop =
            widget.cellHeight +
            (index >= 3 ? MonthDayCellStyle.full.cellPadding.bottom : 0.0) -
            frozenBarHeight;
        return _eventPill(
          event: event,
          date: widget.date,
          left: -bridgeLeft,
          top: ownY.clamp(0.0, maxTop.clamp(0.0, double.infinity)),
          width: widget.maxWidth + bridgeLeft + bridgeRight,
          height: index >= 3
              ? frozenBarHeight + MonthDayCellStyle.full.cellPadding.bottom
              : frozenBarHeight,
          eventFontSize: frozenEventFontSize,
          expandT: 1.0,
          currentBridgeLeft: bridgeLeft,
          currentBridgeRight: bridgeRight,
          roundLeft: isStart,
          roundRight: isEnd,
        );
      }

      // Only shrink height (not width) so there is no horizontal snap at the
      // start of the month→year transition. Width follows the cell naturally
      // via widget.maxWidth; opacity fades the bar out smoothly.
      final height = lerpDouble(frozenBarHeight, 0, shrinkT)!;
      final ownY = frozenMonthEventsTop + index * frozenBarStride;
      if (height < 0.25) return const SizedBox.shrink();

      final maxTop =
          widget.cellHeight +
          (index >= 3 ? MonthDayCellStyle.full.cellPadding.bottom : 0.0) -
          height;

      final textOpacity = shrinkT > 0.85
          ? 0.0
          : ((1.0 - shrinkT - 0.15) / 0.7).clamp(0.0, 1.0);

      return _eventPill(
        event: event,
        date: widget.date,
        left: -currentBridgeLeft,
        top: (ownY + (frozenBarHeight - height) / 2).clamp(
          0.0,
          maxTop.clamp(0.0, double.infinity),
        ),
        width: widget.maxWidth + currentBridgeLeft + currentBridgeRight,
        height: height,
        textOpacity: textOpacity,
        eventFontSize: frozenEventFontSize,
        expandT: 1.0 - shrinkT,
        opacity: 1.0 - shrinkT,
        showText: isStart && textOpacity > 0,
        currentBridgeLeft: currentBridgeLeft,
        currentBridgeRight: currentBridgeRight,
        roundLeft: isStart,
        roundRight: isEnd,
      );
    }

    final shrinkT = shrinkEased;
    final barY = frozenMonthEventsTop + index * frozenBarStride;

    // Only shrink height (not width) to avoid an instant horizontal snap at
    // the start of the month→year / end of year→month transition. Bar opacity
    // fades out so the switch to _yearEventDot at shrinkT≥1 is seamless.
    final height = lerpDouble(frozenBarHeight, dotSize, shrinkT)!;
    final shrinkTop = barY + (frozenBarHeight - height) / 2;

    final x = lerpDouble(0, yearX, reverseMove)!;
    final y = lerpDouble(shrinkTop, yearEventsTop, reverseMove)!;

    if (height < 0.25) return const SizedBox.shrink();

    if (shrinkT >= 1.0) {
      return _yearEventDot(
        color: Color(event.colorValue),
        left: (widget.maxWidth - dotSize) / 2 + x,
        top: y,
        size: dotSize,
      );
    }

    final textOpacity = shrinkT > 0.85
        ? 0.0
        : ((1.0 - shrinkT - 0.15) / 0.7).clamp(0.0, 1.0);
    final barOpacity = (1.0 - shrinkT).clamp(0.0, 1.0);

    return _eventPill(
      event: event,
      date: widget.date,
      // x is 0 during the bar phase (reverseMove is 0 until shrinkT≥1),
      // so left simplifies to -currentBridgeLeft.
      left: x - currentBridgeLeft,
      top: y.clamp(
        0.0,
        (widget.cellHeight - height).clamp(0.0, widget.cellHeight),
      ),
      width: widget.maxWidth + currentBridgeLeft + currentBridgeRight,
      height: height,
      textOpacity: textOpacity,
      eventFontSize: frozenEventFontSize,
      expandT: 1.0 - shrinkT,
      opacity: barOpacity,
      showText: isStart && textOpacity > 0,
      currentBridgeLeft: currentBridgeLeft,
      currentBridgeRight: currentBridgeRight,
      roundLeft: isStart,
      roundRight: isEnd,
    );
  }

  Widget _yearEventDot({
    required Color color,
    required double left,
    required double top,
    required double size,
  }) {
    return Positioned(
      left: left,
      top: top,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    );
  }

  Widget _eventPill({
    required CalendarEvent event,
    required DateTime date,
    required double left,
    required double top,
    required double width,
    required double height,
    required double eventFontSize,
    required double expandT,
    double textOpacity = 1.0,
    double opacity = 1.0,
    bool showText = true,
    required double currentBridgeLeft,
    required double currentBridgeRight,
    // Whether this side of the bar is a true event boundary (not bridging into
    // a neighbouring cell). Drives corner rounding independently of the bridge
    // pixel extent so that padding-only extensions don't remove rounding.
    bool roundLeft = true,
    bool roundRight = true,
  }) {
    final color = Color(event.colorValue);

    final leftRadius = roundLeft ? calendarEventCornerRadius : 0.0;
    final rightRadius = roundRight ? calendarEventCornerRadius : 0.0;

    Widget content = DecoratedBox(
      decoration: calendarEventFillDecoration(
        color,
        borderRadius: BorderRadius.horizontal(
          left: Radius.circular(leftRadius),
          right: Radius.circular(rightRadius),
        ),
      ),
      child: showText && textOpacity > 0
          ? Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 4 * expandT),
                child: Opacity(
                  opacity: textOpacity,
                  child: Text(
                    event.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppFonts.style(
                      fontSize: eventFontSize * expandT.clamp(0.6, 1.0),
                      height: 1,
                    ),
                  ),
                ),
              ),
            )
          : const SizedBox.shrink(),
    );

    if (opacity < 1.0) {
      content = Opacity(opacity: opacity.clamp(0.0, 1.0), child: content);
    }

    return Positioned(
      left: left,
      top: top,
      width: width,
      height: height,
      child: content,
    );
  }
}

/// Scale pulse on tap.  When [eventId] is provided, all visible segments of
/// the same multi-day event animate simultaneously via [CalendarEventTapScope].
///
/// [isSegmentStart] / [isSegmentEnd] control the scale pivot so that all
/// segments of a multi-day bar squish toward their shared boundaries:
///   • start cap   → pivot at right edge (Alignment.centerRight)
///   • end cap     → pivot at left edge  (Alignment.centerLeft)
///   • bridge      → no scale (pivot is irrelevant, boundaries stay fixed)
///   • single day  → pivot at center     (Alignment.center)
class CalendarInteractiveEventTap extends StatefulWidget {
  const CalendarInteractiveEventTap({
    super.key,
    required this.child,
    required this.eventColor,
    required this.borderRadius,
    this.onTap,
    // Outlines the bar whose event is open in the edit sidebar, matching the
    // focus outline sidebar list rows use.
    this.highlighted = false,
    this.eventId,
    this.isSegmentStart = true,
    this.isSegmentEnd = true,
  });

  final Widget child;
  final Color eventColor;
  final BorderRadius borderRadius;
  final VoidCallback? onTap;
  final bool highlighted;
  final String? eventId;

  /// Whether this segment is the leftmost cap of the event bar.
  final bool isSegmentStart;

  /// Whether this segment is the rightmost cap of the event bar.
  final bool isSegmentEnd;

  @override
  State<CalendarInteractiveEventTap> createState() =>
      _CalendarInteractiveEventTapState();
}

class _CalendarInteractiveEventTapState
    extends State<CalendarInteractiveEventTap>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late Animation<double> _scale;
  CalendarEventTapState? _tapState;
  bool _isTapping = false;
  var _configuredMotion = false;

  /// The scale pivot depends on which cap this segment is:
  ///   start-only  → right edge stays fixed  (Alignment.centerRight)
  ///   end-only    → left edge stays fixed   (Alignment.centerLeft)
  ///   both (single day) → center            (Alignment.center)
  ///   bridge      → doesn't matter; scale is disabled
  Alignment get _scaleAlignment {
    final start = widget.isSegmentStart;
    final end = widget.isSegmentEnd;
    if (start && end) return Alignment.center;
    if (start) return Alignment.centerRight;
    if (end) return Alignment.centerLeft;
    return Alignment.center; // bridge — unused
  }

  /// Bridge segments (neither start nor end) don't scale so they act as a
  /// fixed connection point between the two outer caps.
  bool get _shouldScale => widget.isSegmentStart || widget.isSegmentEnd;

  @override
  void initState() {
    super.initState();
    // duration/curve are finalized in didChangeDependencies — inherited-widget
    // lookups (VoyagerMotion.reduced needs MediaQuery) aren't safe in initState.
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 140),
    );
    _scale = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.92), weight: 45),
      TweenSequenceItem(tween: Tween(begin: 0.92, end: 1.0), weight: 55),
    ]).animate(_controller);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final newState = CalendarEventTapScope.maybeOf(context);
    if (newState != _tapState) {
      _tapState?.removeListener(_onTapStateChanged);
      _tapState = newState;
      _tapState?.addListener(_onTapStateChanged);
    }
    if (!_configuredMotion) {
      _configuredMotion = true;
      final reduced = VoyagerMotion.reduced(context);
      _controller.duration = reduced
          ? Duration.zero
          : const Duration(milliseconds: 140);
      final curved = CurvedAnimation(
        parent: _controller,
        curve: reduced ? Curves.linear : VoyagerSpring.snappyCurve,
      );
      _scale = TweenSequence<double>([
        TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.92), weight: 45),
        TweenSequenceItem(tween: Tween(begin: 0.92, end: 1.0), weight: 55),
      ]).animate(curved);
    }
  }

  @override
  void dispose() {
    _tapState?.removeListener(_onTapStateChanged);
    _controller.dispose();
    super.dispose();
  }

  /// Called when any event is tapped anywhere in the calendar. If the
  /// animating event ID matches ours and this instance didn't initiate the
  /// tap, run the animation without calling [onTap].
  void _onTapStateChanged() {
    if (!mounted || _isTapping) return;
    if (widget.eventId != null &&
        _tapState?.animatingEventId == widget.eventId) {
      _controller.forward(from: 0);
    }
  }

  Future<void> _handleTap() async {
    if (widget.onTap == null || _isTapping) return;
    _isTapping = true;

    // Broadcast the event ID so every other segment of the same multi-day
    // event plays the animation simultaneously, and record the widget rect for
    // popup anchoring.  Always call notifyEventTap even if the render box is
    // unavailable (animation sync still works; popup just falls back to cursor).
    if (widget.eventId != null && _tapState != null) {
      final box = context.findRenderObject() as RenderBox?;
      final rect = box != null
          ? box.localToGlobal(Offset.zero) & box.size
          : Rect.zero;
      _tapState!.notifyEventTap(eventId: widget.eventId!, widgetRect: rect);
    }

    await _controller.forward(from: 0);
    if (!mounted) return;
    _isTapping = false;
    widget.onTap!();
  }

  @override
  Widget build(BuildContext context) {
    final child = widget.highlighted
        ? CustomPaint(
            foregroundPainter: _EventFocusRingPainter(
              color: VoyagerListItemSurface.focusBorderColor(context),
              borderRadius: widget.borderRadius,
              clipLeft: !widget.isSegmentStart,
              clipRight: !widget.isSegmentEnd,
            ),
            child: widget.child,
          )
        : widget.child;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        // Start/end caps squish inward toward the shared inner boundary so
        // the whole bar appears to press as one cohesive unit.
        // Bridge segments keep scale = 1.0 so the boundary never opens up.
        return Transform.scale(
          scale: _shouldScale ? _scale.value : 1.0,
          alignment: _scaleAlignment,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: widget.onTap == null ? null : _handleTap,
              borderRadius: widget.borderRadius,
              splashColor: widget.eventColor.withValues(alpha: 0.2),
              highlightColor: widget.eventColor.withValues(alpha: 0.12),
              canRequestFocus: false,
              child: child,
            ),
          ),
        );
      },
      child: child,
    );
  }
}

/// Focus outline for the event bar whose editor sidebar is open.
///
/// A multi-day event is drawn as one segment per cell, so the sides that meet a
/// neighbouring segment are clipped away — otherwise the ring would read as a
/// row of boxes instead of one outline around the whole bar. The horizontal
/// strokes lose [_strokeWidth] at those seams, which the segments' own overlap
/// paints back over.
class _EventFocusRingPainter extends CustomPainter {
  const _EventFocusRingPainter({
    required this.color,
    required this.borderRadius,
    required this.clipLeft,
    required this.clipRight,
  });

  final Color color;
  final BorderRadius borderRadius;
  final bool clipLeft;
  final bool clipRight;

  static const _strokeWidth = 1.0;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.save();
    canvas.clipRect(
      Rect.fromLTRB(
        clipLeft ? rect.left + _strokeWidth : rect.left,
        rect.top,
        clipRight ? rect.right - _strokeWidth : rect.right,
        rect.bottom,
      ),
    );
    canvas.drawRRect(
      borderRadius.toRRect(rect).deflate(_strokeWidth / 2),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _strokeWidth
        ..color = color,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_EventFocusRingPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.borderRadius != borderRadius ||
      oldDelegate.clipLeft != clipLeft ||
      oldDelegate.clipRight != clipRight;
}

Future<void> _showOverflowEventsPopover({
  required BuildContext badgeContext,
  required List<CalendarEvent> overflowEvents,
  required DateTime day,
  required void Function(CalendarDayEntry entry) onEntryTap,
  String? editingEventId,
  CalendarEntryMenuBuilder? entryMenuBuilder,
}) {
  return showContextualPopover<void>(
    context: badgeContext,
    buttonContext: badgeContext,
    width: 240,
    builder: (popoverContext) {
      return CalendarDayOverflowEventsPopover(
        day: day,
        events: overflowEvents,
        editingEventId: editingEventId,
        entryMenuBuilder: entryMenuBuilder,
        onEventTap: (event) {
          Navigator.of(popoverContext).pop();
          onEntryTap(
            event.isFullDay
                ? CalendarDayEntry.allDayEvent(event, day: day)
                : CalendarDayEntry.timedEvent(event, day: day),
          );
        },
      );
    },
  );
}

Future<void> _showTodoPopover({
  required BuildContext badgeContext,
  required List<CalendarTodoMarker> todos,
  required DateTime day,
  required void Function(CalendarDayEntry entry) onEntryTap,
  CalendarEntryMenuBuilder? entryMenuBuilder,
}) {
  return showContextualPopover<void>(
    context: badgeContext,
    buttonContext: badgeContext,
    width: 240,
    builder: (popoverContext) {
      return CalendarDayTodoPopover(
        day: day,
        todos: todos,
        entryMenuBuilder: entryMenuBuilder,
        onTodoTap: (todo) {
          Navigator.of(popoverContext).pop();
          onEntryTap(CalendarDayEntry.todo(todo, day: day));
        },
      );
    },
  );
}

class CalendarDayTodoPopover extends StatelessWidget {
  const CalendarDayTodoPopover({
    super.key,
    required this.todos,
    required this.onTodoTap,
    required this.day,
    this.entryMenuBuilder,
  });

  /// The day cell this popover belongs to, carried into every entry so a
  /// recurring item stays identifiable as one occurrence.
  final DateTime day;
  final List<CalendarTodoMarker> todos;
  final ValueChanged<CalendarTodoMarker> onTodoTap;
  final CalendarEntryMenuBuilder? entryMenuBuilder;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final todo in todos)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              child: calendarEntryContextMenu(
                builder: entryMenuBuilder,
                entry: CalendarDayEntry.todo(todo, day: day),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: () => onTodoTap(todo),
                    child: Container(
                      height: 24,
                      alignment: Alignment.centerLeft,
                      child: CalendarDayTodoTile(marker: todo),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class CalendarDayOverflowEventsPopover extends StatelessWidget {
  const CalendarDayOverflowEventsPopover({
    super.key,
    required this.events,
    required this.onEventTap,
    required this.day,
    this.editingEventId,
    this.entryMenuBuilder,
  });

  /// The day cell this popover belongs to. See [CalendarDayTodoPopover.day].
  final DateTime day;
  final List<CalendarEvent> events;
  final ValueChanged<CalendarEvent> onEventTap;
  final String? editingEventId;
  final CalendarEntryMenuBuilder? entryMenuBuilder;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final event in events)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              child: calendarEntryContextMenu(
                builder: entryMenuBuilder,
                entry: event.isFullDay
                    ? CalendarDayEntry.allDayEvent(event, day: day)
                    : CalendarDayEntry.timedEvent(event, day: day),
                child: CalendarInteractiveEventTap(
                  eventColor: Color(event.colorValue),
                  borderRadius: BorderRadius.circular(6),
                  highlighted: editingEventId == event.id,
                  onTap: () => onEventTap(event),
                  child: Container(
                    height: 24,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    decoration: calendarEventFillDecoration(
                      Color(event.colorValue),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    alignment: Alignment.centerLeft,
                    child: Text(
                      event.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppFonts.style(fontSize: 11, height: 1),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _CalendarDayOverflowBadge extends StatelessWidget {
  const _CalendarDayOverflowBadge({
    required this.extraCount,
    required this.onTap,
  });

  final int extraCount;
  final void Function(BuildContext badgeContext)? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Builder(
      builder: (badgeContext) {
        return Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap == null ? null : () => onTap!(badgeContext),
            borderRadius: BorderRadius.circular(4),
            canRequestFocus: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 1, 2, 1),
              child: Text(
                '+$extraCount',
                style: AppFonts.style(
                  fontSize: 9,
                  height: 1,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Single-line event pill for month-view day cells.
class CalendarDayEventBar extends StatelessWidget {
  const CalendarDayEventBar({
    super.key,
    required this.event,
    required this.date,
    required this.fontSize,
    this.height,
    this.isStart = true,
    this.isEnd = true,
    this.isFirstColumn = false,
    this.isLastColumn = false,
    this.isBottom = false,
    this.cellMargin = EdgeInsets.zero,
    this.cellPadding = EdgeInsets.zero,
    this.onTap,
    this.highlighted = false,
  });

  final CalendarEvent event;
  final DateTime date;
  final double fontSize;
  final double? height;
  final bool isStart;
  final bool isEnd;
  final bool isFirstColumn;
  final bool isLastColumn;
  final bool isBottom;
  final EdgeInsets cellMargin;
  final EdgeInsets cellPadding;
  final VoidCallback? onTap;
  final bool highlighted;

  static double heightFor(double fontSize) => fontSize + 4;

  @override
  Widget build(BuildContext context) {
    final barHeight = height ?? heightFor(fontSize);
    // isBottom bars sit flush against the cell's own clipped edge, so leaving
    // these corners square lets the enclosing ClipRRect impose the curve —
    // any attempt to match a radius here is one sub-pixel drift away from a gap.
    final bottomRadius = isBottom ? 0.0 : calendarEventCornerRadius;
    final borderRadius = BorderRadius.only(
      topLeft: Radius.circular(isStart ? calendarEventCornerRadius : 0.0),
      topRight: Radius.circular(isEnd ? calendarEventCornerRadius : 0.0),
      bottomLeft: Radius.circular(isStart ? bottomRadius : 0.0),
      bottomRight: Radius.circular(isEnd ? bottomRadius : 0.0),
    );
    final eventColor = Color(event.colorValue);

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(
          top: 0,
          bottom: 0,
          left: isStart
              ? -cellPadding.left
              : isFirstColumn
              ? -cellPadding.left
              : -cellMargin.left - cellPadding.left - 2.0,
          right: isEnd
              ? -cellPadding.right
              : isLastColumn
              ? -cellPadding.right
              : -cellMargin.right - cellPadding.right - 2.0,
          child: CalendarInteractiveEventTap(
            eventColor: eventColor,
            borderRadius: borderRadius,
            highlighted: highlighted,
            onTap: onTap,
            eventId: event.id,
            isSegmentStart: isStart,
            isSegmentEnd: isEnd,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              decoration: calendarEventFillDecoration(
                eventColor,
                borderRadius: borderRadius,
              ),
              alignment: Alignment.centerLeft,
              child: isStart
                  ? Text(
                      event.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppFonts.style(fontSize: fontSize, height: 1),
                    )
                  : null,
            ),
          ),
        ),
      ],
    );
  }
}

/// Opacity for year-tile event dots during chained week↔year zoom morphs.
///
/// Only [CalendarFadedEventDots] listens to this — the year grid widget tree
/// stays cached across animation frames.
class CalendarMorphYearDotsOpacity extends InheritedWidget {
  const CalendarMorphYearDotsOpacity({
    super.key,
    required this.opacity,
    required super.child,
  });

  final double opacity;

  static double morphOpacityOf(BuildContext context) {
    return context
            .dependOnInheritedWidgetOfExactType<CalendarMorphYearDotsOpacity>()
            ?.opacity ??
        1.0;
  }

  @override
  bool updateShouldNotify(CalendarMorphYearDotsOpacity old) =>
      old.opacity != opacity;
}

/// Year-view event dots that fade during chained week↔year zoom morphs.
class CalendarFadedEventDots extends StatelessWidget {
  const CalendarFadedEventDots({
    super.key,
    required this.events,
    required this.dotSize,
    this.maxDots = 3,
    this.baseOpacity = 1,
  });

  final List<CalendarEvent> events;
  final double dotSize;
  final int maxDots;
  final double baseOpacity;

  @override
  Widget build(BuildContext context) {
    final opacity =
        (baseOpacity * CalendarMorphYearDotsOpacity.morphOpacityOf(context))
            .clamp(0.0, 1.0);
    if (opacity <= 0) return const SizedBox.shrink();
    final dots = CalendarDayEventDots(
      events: events,
      dotSize: dotSize,
      maxDots: maxDots,
    );
    if (opacity >= 1) return dots;
    return Opacity(opacity: opacity, child: dots);
  }
}

/// Tiny event markers for year-view day cells.
class CalendarDayEventDots extends StatelessWidget {
  const CalendarDayEventDots({
    super.key,
    required this.events,
    required this.dotSize,
    this.maxDots = 3,
  });

  final List<CalendarEvent> events;
  final double dotSize;
  final int maxDots;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (final event in events.take(maxDots))
          Container(
            width: dotSize,
            height: dotSize,
            margin: const EdgeInsets.symmetric(horizontal: 0.5),
            decoration: BoxDecoration(
              color: Color(event.colorValue),
              shape: BoxShape.circle,
            ),
          ),
      ],
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

/// Gap between weekday labels and the first day-cell row in [MonthDayGrid].
const monthDayGridWeekdayHeaderGap = 8.0;

/// Weekday labels render at [labelSmall] × this scale in month/year views.
const calendarWeekdayFontSizeScale = 1.05;

double calendarWeekdayFontSize(BuildContext context, {double? baseFontSize}) {
  final base =
      baseFontSize ?? Theme.of(context).textTheme.labelSmall!.fontSize ?? 12;
  return base * calendarWeekdayFontSizeScale;
}

/// Weekday label row shown above the month day grid.
class WeekdayHeaderRow extends StatelessWidget {
  const WeekdayHeaderRow({
    super.key,
    required this.weekStartsMonday,
    this.opacity = 1,
    this.useSingleLetterLabels = false,
    this.labelStyle,
  });

  final bool weekStartsMonday;
  final double opacity;
  final bool useSingleLetterLabels;
  final TextStyle? labelStyle;

  /// Text height for a single weekday label row (excludes the gap below).
  ///
  /// Year tiles use single-letter labels — pass [useSingleLetterLabels] so
  /// layout math matches this widget instead of over-estimating with `'Mg'`.
  static double labelHeight(
    TextStyle labelStyle, {
    bool useSingleLetterLabels = false,
  }) {
    final sample = useSingleLetterLabels ? 'M' : 'Mg';
    final painter = TextPainter(
      text: TextSpan(text: sample, style: labelStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    return painter.height;
  }

  /// Row height plus the gap before the day grid.
  static double totalHeight(
    TextStyle labelStyle, {
    bool useSingleLetterLabels = false,
  }) =>
      labelHeight(labelStyle, useSingleLetterLabels: useSingleLetterLabels) +
      monthDayGridWeekdayHeaderGap;

  @override
  Widget build(BuildContext context) {
    final style = labelStyle ?? calendarWeekdayLabelStyle(context);
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
            child: Center(child: Text(label, style: style)),
          ),
      ],
    );
    if (opacity >= 1) return row;
    return Opacity(opacity: opacity.clamp(0.0, 1.0), child: row);
  }
}

/// Pre-measured weekday label metrics for morph animation (computed once).
class WeekdayMorphMetrics {
  const WeekdayMorphMetrics({
    required this.letter,
    required this.fullLabel,
    required this.compactLetterWidth,
    required this.fullLetterWidth,
    required this.compactFullWidth,
    required this.fullFullWidth,
    required this.compactHeight,
    required this.fullHeight,
    required this.suffixCharCompactWidths,
    required this.suffixCharFullWidths,
  });

  final String letter;
  final String fullLabel;
  final double compactLetterWidth;
  final double fullLetterWidth;
  final double compactFullWidth;
  final double fullFullWidth;
  final double compactHeight;
  final double fullHeight;
  final List<double> suffixCharCompactWidths;
  final List<double> suffixCharFullWidths;

  static double _textWidth(String text, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    return painter.width;
  }

  static double measureTextWidth(String text, TextStyle style) =>
      _textWidth(text, style);

  static List<WeekdayMorphMetrics> columnsFor({
    required bool weekStartsMonday,
    required TextStyle compactStyle,
    required TextStyle fullStyle,
  }) {
    final letters = weekStartsMonday
        ? calendarWeekdayLettersMonday
        : calendarWeekdayLettersSunday;
    final labels = weekStartsMonday
        ? calendarWeekdayLabelsMonday
        : calendarWeekdayLabelsSunday;

    return List.generate(letters.length, (i) {
      final letter = letters[i];
      final fullLabel = labels[i];
      final suffix = fullLabel.length > 1 ? fullLabel.substring(1) : '';
      final suffixChars = suffix.split('');
      return WeekdayMorphMetrics(
        letter: letter,
        fullLabel: fullLabel,
        compactLetterWidth: _textWidth(letter, compactStyle),
        fullLetterWidth: _textWidth(letter, fullStyle),
        compactFullWidth: _textWidth(fullLabel, compactStyle),
        fullFullWidth: _textWidth(fullLabel, fullStyle),
        compactHeight: WeekdayHeaderRow.labelHeight(
          compactStyle,
          useSingleLetterLabels: true,
        ),
        fullHeight: WeekdayHeaderRow.labelHeight(fullStyle),
        suffixCharCompactWidths: [
          for (final char in suffixChars) _textWidth(char, compactStyle),
        ],
        suffixCharFullWidths: [
          for (final char in suffixChars) _textWidth(char, fullStyle),
        ],
      );
    });
  }
}

/// Weekday labels that morph during the year↔month transition.
class MorphWeekdayHeader extends StatelessWidget {
  const MorphWeekdayHeader({
    super.key,
    required this.columns,
    required this.styleT,
    required this.compactStyle,
    required this.fullStyle,
  });

  final List<WeekdayMorphMetrics> columns;
  final double styleT;
  final TextStyle compactStyle;
  final TextStyle fullStyle;

  /// Weekday label row bounds above the first day-cell row.
  static Rect rowRectFromDayCells(
    List<Rect> dayCells,
    TextStyle labelStyle, {
    bool useSingleLetterLabels = false,
  }) {
    final labelHeight = WeekdayHeaderRow.labelHeight(
      labelStyle,
      useSingleLetterLabels: useSingleLetterLabels,
    );
    return Rect.fromLTWH(
      dayCells[0].left,
      dayCells[0].top - monthDayGridWeekdayHeaderGap - labelHeight,
      dayCells[6].right - dayCells[0].left,
      labelHeight,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (final metrics in columns)
          Expanded(
            child: _MorphWeekdayColumn(
              metrics: metrics,
              styleT: styleT,
              compactStyle: compactStyle,
              fullStyle: fullStyle,
            ),
          ),
      ],
    );
  }
}

class _MorphWeekdayColumn extends StatelessWidget {
  const _MorphWeekdayColumn({
    required this.metrics,
    required this.styleT,
    required this.compactStyle,
    required this.fullStyle,
  });

  final WeekdayMorphMetrics metrics;
  final double styleT;
  final TextStyle compactStyle;
  final TextStyle fullStyle;

  double _suffixCharT(int index, int total, double styleT) {
    if (total == 0) return 0;
    final start = 0.15 + (index / total) * 0.5;
    final end = start + 0.35;
    return Curves.easeOutCubic.transform(
      ((styleT - start) / (end - start)).clamp(0.0, 1.0),
    );
  }

  // Font advance widths scale linearly with font size for the same typeface, so
  // lerping the two pre-measured endpoint widths is equivalent to measuring the
  // lerped style — without allocating a TextPainter on every animation frame.
  double _blockWidth(List<String> suffixChars, double styleT) {
    if (styleT <= 0) return metrics.compactLetterWidth;
    if (styleT >= 1) return metrics.fullFullWidth;

    var width = lerpDouble(
      metrics.compactLetterWidth,
      metrics.fullLetterWidth,
      styleT,
    )!;
    for (var i = 0; i < suffixChars.length; i++) {
      width +=
          metrics.suffixCharFullWidths[i] *
          _suffixCharT(i, suffixChars.length, styleT);
    }
    return width;
  }

  @override
  Widget build(BuildContext context) {
    final style = TextStyle.lerp(compactStyle, fullStyle, styleT)!;
    final suffixChars = metrics.fullLabel.length > 1
        ? metrics.fullLabel.substring(1).split('')
        : const <String>[];

    final rowHeight =
        metrics.compactHeight +
        (metrics.fullHeight - metrics.compactHeight) * styleT;

    final blockWidth = _blockWidth(suffixChars, styleT);

    return LayoutBuilder(
      builder: (context, constraints) {
        final blockLeft = (constraints.maxWidth - blockWidth) / 2;

        return SizedBox(
          height: rowHeight,
          child: ClipRect(
            child: Stack(
              children: [
                Positioned(
                  left: blockLeft,
                  top: 0,
                  height: rowHeight,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Text(metrics.letter, style: style),
                      for (var i = 0; i < suffixChars.length; i++)
                        SizedBox(
                          width:
                              metrics.suffixCharFullWidths[i] *
                              _suffixCharT(i, suffixChars.length, styleT),
                          child: ClipRect(
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Text(suffixChars[i], style: style),
                            ),
                          ),
                        ),
                    ],
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

/// Shared 6×7 day grid for year mini-months and the month view.
class MonthDayGrid extends StatelessWidget {
  const MonthDayGrid({
    super.key,
    required this.month,
    required this.events,
    required this.indicators,
    required this.weekStartsMonday,
    required this.style,
    this.todoMarkers = const [],
    this.workoutDays = const {},
    this.showTodoIcons = true,
    this.onDayTap,
    this.onEntryTap,
    this.entryMenuBuilder,
    this.editingEventId,
    this.showWeekdayHeader = false,
    this.weekdayHeaderOpacity = 1,
    this.useSingleLetterWeekdays = false,
    this.selectedDay,
    this.hiddenWeekRow,
    this.highlightedWeekStart,
    this.weekHighlightOpacity = 1,
    this.accentColor,
  });

  final DateTime month;
  final List<CalendarEvent> events;
  final List<CalendarDayIndicator> indicators;
  final List<CalendarTodoMarker> todoMarkers;

  /// Local calendar days with a completed workout. Empty when the setting is
  /// off, which is what keeps the year view free of the marker.
  final Set<DateTime> workoutDays;
  final bool weekStartsMonday;
  final MonthDayCellStyle style;
  final void Function(DateTime day)? onDayTap;
  final void Function(CalendarDayEntry entry)? onEntryTap;
  final CalendarEntryMenuBuilder? entryMenuBuilder;
  final String? editingEventId;
  final bool showWeekdayHeader;
  final double weekdayHeaderOpacity;
  final bool useSingleLetterWeekdays;
  final DateTime? selectedDay;

  /// When false, todo icons are hidden (e.g. during view morph animations).
  final bool showTodoIcons;

  /// Row index (0–5) whose cells are omitted — used during month↔week morph.
  final int? hiddenWeekRow;

  /// Week that will open when switching to week view; highlights that row.
  final DateTime? highlightedWeekStart;

  /// Scales the focused-week highlight (fades during month↔week morph).
  final double weekHighlightOpacity;

  /// Selected calendar's color, threaded to each cell's "today" circle and
  /// focused-week highlight.
  final Color? accentColor;

  @override
  Widget build(BuildContext context) {
    final cells = monthGridDates(month, weekStartsMonday: weekStartsMonday);

    // Compact (year-tile) cells only render event dots and filter out null
    // slots anyway — the packed-row layout data is irrelevant. Skip the
    // expensive O(N × 7 × 6) calendarPackWeekEvents call and use a cheap
    // per-day filter instead.
    //
    // Pre-normalize event dates once so [calendarEventOccursOnDayNormalized]
    // can skip the repeated [toLocal()] + [DateUtils.dateOnly()] allocations
    // in the inner 42-cell loop (year view: 12 tiles × 42 cells × N events).
    final List<List<List<CalendarEvent?>>> packedWeeks;
    if (style.isCompactLayout) {
      final normalizedEvents = normalizeCalendarEvents(events);
      packedWeeks = List.generate(6, (row) {
        if (hiddenWeekRow == row) return <List<CalendarEvent?>>[];
        return List.generate(7, (col) {
          final date = cells[row * 7 + col];
          if (date.month != month.month || date.year != month.year) {
            return const <CalendarEvent?>[];
          }
          // Use date-only local once per cell; the normalized struct already
          // holds the pre-computed local start/end dates for each event.
          final localDay = DateUtils.dateOnly(date.toLocal());
          return [
            for (final n in normalizedEvents)
              if (calendarEventOccursOnDayNormalized(n, localDay)) n.event,
          ];
        });
      });
    } else {
      packedWeeks = List.generate(6, (row) {
        if (hiddenWeekRow == row) return <List<CalendarEvent?>>[];
        return calendarPackWeekEvents(
          cells.sublist(row * 7, row * 7 + 7),
          events,
        );
      });
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showWeekdayHeader) ...[
          WeekdayHeaderRow(
            weekStartsMonday: weekStartsMonday,
            opacity: weekdayHeaderOpacity,
            useSingleLetterLabels: useSingleLetterWeekdays,
          ),
          const SizedBox(height: monthDayGridWeekdayHeaderGap),
        ],
        Expanded(
          child: Column(
            children: List.generate(6, (row) {
              if (hiddenWeekRow == row) {
                return const Expanded(child: SizedBox.shrink());
              }
              return Expanded(
                child: Row(
                  children: List.generate(7, (col) {
                    final date = cells[row * 7 + col];
                    final inMonth =
                        date.month == month.month && date.year == month.year;
                    final dayEvents = inMonth
                        ? packedWeeks[row][col]
                        : const <CalendarEvent?>[];
                    final dayIndicators = indicators
                        .where((i) => calendarSameDay(i.day, date))
                        .take(3)
                        .toList();
                    final dayTodos = inMonth
                        ? calendarTodoMarkersForDay(todoMarkers, date)
                        : const <CalendarTodoMarker>[];

                    final isSelected =
                        selectedDay != null &&
                        calendarSameDay(date, selectedDay!);
                    final weekHighlightAlpha =
                        calendarFocusedWeekHighlightAlpha(
                          date: date,
                          month: month,
                          weekStart: highlightedWeekStart,
                          opacity: weekHighlightOpacity,
                        );

                    return Expanded(
                      child: CalendarDayCell(
                        date: date,
                        month: month,
                        events: dayEvents,
                        indicators: dayIndicators,
                        todoMarkers: dayTodos,
                        showTodoIcons: showTodoIcons,
                        hasWorkout:
                            inMonth &&
                            workoutDays.contains(
                              DateUtils.dateOnly(date.toLocal()),
                            ),
                        style: style,
                        isSelected: isSelected,
                        isFirstColumn: col == 0,
                        isLastColumn: col == 6,
                        weekHighlightAlpha: weekHighlightAlpha,
                        onTap: onDayTap == null ? null : () => onDayTap!(date),
                        onEntryTap: onEntryTap,
                        entryMenuBuilder: entryMenuBuilder,
                        editingEventId: editingEventId,
                        accentColor: accentColor,
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

bool calendarIsToday(DateTime date) {
  final now = DateTime.now();
  return calendarSameDay(date, now);
}

bool calendarSameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

bool calendarEventOnDay(CalendarEvent event, DateTime day) =>
    calendarEventOccursOnDay(event, day);

const calendarWeekdayLabelsMonday = [
  'Mon',
  'Tue',
  'Wed',
  'Thu',
  'Fri',
  'Sat',
  'Sun',
];

const calendarWeekdayLettersMonday = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];

const calendarWeekdayLabelsSunday = [
  'Sun',
  'Mon',
  'Tue',
  'Wed',
  'Thu',
  'Fri',
  'Sat',
];

const calendarWeekdayLettersSunday = ['S', 'M', 'T', 'W', 'T', 'F', 'S'];
