import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:voyager/core/theme/app_fonts.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/domain/services/calendar_recurrence.dart';
import 'package:voyager/features/calendar/calendar_day_entries.dart';
import 'package:voyager/features/calendar/calendar_todo_markers.dart';

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

/// Fill alpha for month-view event pills (background tint over the cell).
const calendarEventBarFillAlpha = 0.58;

/// Fill alpha for day-view event tiles.
const calendarDayEventTileFillAlpha = 0.48;

/// Bottom-right gradient saturation as a fraction of the event color's native saturation.
const calendarEventGradientEndSaturationScale = 0.4;

/// Top-left → bottom-right fill: native saturation fading to 40% of native.
LinearGradient calendarEventFillGradient(
  Color base, {
  double alpha = calendarEventBarFillAlpha,
}) {
  final hsv = HSVColor.fromColor(base);
  final nativeSaturation = hsv.saturation;
  final start = hsv.toColor().withValues(alpha: alpha);
  final end = hsv
      .withSaturation(
        (nativeSaturation * calendarEventGradientEndSaturationScale).clamp(
          0.0,
          nativeSaturation,
        ),
      )
      .toColor()
      .withValues(alpha: alpha);
  return LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [start, end],
  );
}

BoxDecoration calendarEventFillDecoration(
  Color base, {
  double alpha = calendarEventBarFillAlpha,
  BorderRadius? borderRadius,
}) {
  return BoxDecoration(
    gradient: calendarEventFillGradient(base, alpha: alpha),
    borderRadius: borderRadius,
  );
}

Color calendarTitleAccentColor(BuildContext context) =>
    Theme.of(context).colorScheme.primary;

Color calendarWeekdayAccentColor(BuildContext context) => Color.lerp(
  Theme.of(context).colorScheme.primary,
  Colors.white,
  0.5,
)!;

Color calendarAdjacentMonthColor(BuildContext context) =>
    Theme.of(context).colorScheme.onSurface.withValues(
      alpha: calendarAdjacentMonthTextOpacity,
    );

TextStyle calendarWeekdayLabelStyle(
  BuildContext context, {
  double? fontSize,
}) {
  final size = calendarWeekdayFontSize(context, baseFontSize: fontSize);
  return Theme.of(context).textTheme.labelSmall!.copyWith(
    color: calendarWeekdayAccentColor(context),
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
    this.onTap,
    this.onEntryTap,
    this.isSelected = false,
    this.adjacentTextT,
    this.adjacentBorderT,
    this.hideEntries = false,
    this.entryOpacity = 1,
    this.dayNumberOpacity = 1,
    this.frozenEntryLayoutHeight,
  });

  final DateTime date;
  final DateTime month;
  final List<CalendarEvent> events;
  final List<CalendarDayIndicator> indicators;
  final List<CalendarTodoMarker> todoMarkers;
  final MonthDayCellStyle style;
  final VoidCallback? onTap;
  final void Function(CalendarDayEntry entry)? onEntryTap;
  final bool isSelected;

  /// When false, todo icons are hidden (e.g. during view morph animations).
  final bool showTodoIcons;

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

  @override
  Widget build(BuildContext context) {
    final inMonth = date.month == month.month;
    final divider = Theme.of(context).dividerColor;
    final isFullLayout = !style.isCompactLayout;

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
      padding: style.cellPadding,
      decoration: BoxDecoration(
        border: Border.all(
          color: borderColor.withValues(
            alpha: borderAlpha.clamp(0.0, 1.0),
          ),
        ),
        borderRadius: BorderRadius.circular(style.borderRadius),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final useCompact =
              style.isCompactLayout || constraints.maxHeight < 28;
          return useCompact
              ? _buildCompactCellContent(inMonth)
              : _buildFullCellContent(inMonth, constraints.maxHeight);
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

  Widget _buildFullCellContent(bool inMonth, double cellHeight) {
    final layoutHeight = frozenEntryLayoutHeight ?? cellHeight;
    final dayNumberHeight = style.fontSize + 8;
    var headerUsed = dayNumberHeight;
    if (indicators.isNotEmpty) {
      headerUsed += 2 + style.dotSize;
    }
    const eventGap = 2.0;
    final eventAreaHeight =
        (layoutHeight - headerUsed - eventGap).clamp(0.0, double.infinity);
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
    final availableHeight =
        (cellHeight - headerUsed - eventGap).clamp(0.0, double.infinity);
    final clampedEventAreaHeight =
        eventAreaHeight.clamp(0.0, availableHeight);

    final showTodos =
        inMonth && showTodoIcons && todoMarkers.isNotEmpty;

    return ClipRect(
      child: Stack(
        clipBehavior: Clip.hardEdge,
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
              if (inMonth && visibleEvents > 0 && !hideEntries) ...[
                const SizedBox(height: 2),
                Opacity(
                  opacity: entryOpacity.clamp(0.0, 1.0),
                  child: SizedBox(
                    height: clampedEventAreaHeight,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var i = 0; i < visibleEvents; i++) ...[
                          if (i > 0) const SizedBox(height: 1),
                          SizedBox(
                            height: barHeight,
                            child: LayoutBuilder(
                              builder: (context, constraints) {
                                final eventFontSize =
                                    calendarMonthEventFontSize(
                                  barHeight: barHeight,
                                  style: style,
                                );
                                return CalendarDayEventBar(
                                  event: events[i],
                                  fontSize: eventFontSize,
                                  height: barHeight,
                                );
                              },
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
          if (showTodos)
            Positioned(
              right: 0,
              bottom: 0,
              child: Opacity(
                opacity: entryOpacity.clamp(0.0, 1.0),
                child: CalendarDayTodoIcons(markers: todoMarkers),
              ),
            ),
        ],
      ),
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
            ),
          ),
        ),
        if (inMonth && events.isNotEmpty) ...[
          const SizedBox(height: 1),
          CalendarFadedEventDots(
            events: events,
            dotSize: style.eventDotSize,
            maxDots: style.maxEventLines,
            baseOpacity: entryOpacity,
          ),
        ],
        if (inMonth && showTodoIcons && todoMarkers.isNotEmpty) ...[
          const SizedBox(height: 1),
          Opacity(
            opacity: entryOpacity.clamp(0.0, 1.0),
            child: CalendarDayTodoIcons(markers: todoMarkers),
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
  });

  final DateTime date;
  final DateTime month;
  final double fontSize;
  final bool mutedWhenAdjacent;

  /// Lerps adjacent-month text from muted (0) to active (1). Ignored when null.
  final double? adjacentTextT;
  final bool isSelected;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final isToday = calendarIsToday(date);
    final muted = mutedWhenAdjacent && date.month != month.month;
    final mutedColor = calendarAdjacentMonthColor(context);
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final isCompact = fontSize <= 9;
    final diameter = fontSize + (isCompact ? 5 : 8);
    final showSelection = isSelected && !isToday && !muted;

    Color textColor;
    if (isToday) {
      textColor = Theme.of(context).colorScheme.onPrimary;
    } else if (muted && adjacentTextT != null) {
      textColor = Color.lerp(mutedColor, onSurface, adjacentTextT!.clamp(0.0, 1.0))!;
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
          color: textColor,
        ),
      ),
    );

    return Center(
      child: isCompact && isToday
          ? Transform.translate(
              offset: const Offset(0, -0.5),
              child: dayNumber,
            )
          : dayNumber,
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
  final eventAreaHeight =
      (cellHeight - headerUsed - eventGap).clamp(0.0, double.infinity);
  final slotGaps = (slotCount - 1) * betweenEventGap;
  return ((eventAreaHeight - slotGaps) / slotCount)
      .clamp(0.0, double.infinity);
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
    final visible = monthLayoutCount.clamp(1, MorphDayEventStack.maxMonthEvents);
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

  final List<CalendarEvent> events;
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
  static double reverseDotMoveT({
    required int count,
    required double styleT,
  }) {
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
    final cappedCount =
        widget.events.length.clamp(0, MorphDayEventStack.maxMonthEvents);
    if (cappedCount == 0) return 0;
    if (!widget.inMonth && widget.styleT <= 0) return 0;
    return cappedCount;
  }

  @override
  Widget build(BuildContext context) {
    final cappedCount =
        widget.events.length.clamp(0, MorphDayEventStack.maxMonthEvents);
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
    final frozenBarHeight = frozen?.barHeight ??
        calendarMonthEventBarHeight(
          cellHeight: widget.cellHeight,
          style: MonthDayCellStyle.full,
          visibleEventCount: cappedCount.clamp(1, MorphDayEventStack.maxMonthEvents),
        );
    final frozenBarStride = frozen?.barStride ?? frozenBarHeight + 1;
    final frozenEventFontSize = frozen?.eventFontSize ??
        calendarMonthEventFontSize(
          barHeight: frozenBarHeight,
          style: MonthDayCellStyle.full,
        );

    const yearDotSize = MorphDayEventStack.yearDotSize;
    final yearDotCount =
        widget.inMonth ? cappedCount.clamp(0, MorphDayEventStack.maxYearDots) : 0;
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
          clipBehavior: Clip.hardEdge,
          children: [
            for (var i = count - 1; i >= MorphDayEventStack.maxYearDots; i--)
            _buildEventMarker(
              event: widget.events[i],
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
          for (var i = 0; i < count && i < MorphDayEventStack.maxYearDots; i++)
            _buildEventMarker(
              event: widget.events[i],
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

    if (!isDotSlot) {
      final shrinkT = shrinkEased;
      if (shrinkT >= 1.0) return const SizedBox.shrink();
      if (shrinkT <= 0.0) {
        final ownY = frozenMonthEventsTop + index * frozenBarStride;
        return _eventPill(
          event: event,
          left: 0,
          top: ownY.clamp(
            0.0,
            (widget.cellHeight - frozenBarHeight)
                .clamp(0.0, widget.cellHeight),
          ),
          width: widget.maxWidth,
          height: frozenBarHeight,
          eventFontSize: frozenEventFontSize,
          expandT: 1.0,
        );
      }

      final width = lerpDouble(widget.maxWidth, 0, shrinkT)!;
      final height = lerpDouble(frozenBarHeight, 0, shrinkT)!;
      final ownY = frozenMonthEventsTop + index * frozenBarStride;
      if (width < 0.25 || height < 0.25) {
        return const SizedBox.shrink();
      }

      return _eventPill(
        event: event,
        left: (widget.maxWidth - width) / 2,
        top: (ownY + (frozenBarHeight - height) / 2).clamp(
          0.0,
          (widget.cellHeight - height).clamp(0.0, widget.cellHeight),
        ),
        width: width,
        height: height,
        eventFontSize: frozenEventFontSize,
        expandT: 1.0 - shrinkT,
        opacity: 1.0 - shrinkT,
        showText: false,
      );
    }

    final shrinkT = shrinkEased;
    final barY = frozenMonthEventsTop + index * frozenBarStride;

    final width = lerpDouble(widget.maxWidth, dotSize, shrinkT)!;
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

    return _eventPill(
      event: event,
      left: (widget.maxWidth - width) / 2 + x,
      top: y.clamp(
        0.0,
        (widget.cellHeight - height).clamp(0.0, widget.cellHeight),
      ),
      width: width,
      height: height,
      textOpacity: textOpacity,
      eventFontSize: frozenEventFontSize,
      expandT: 1.0 - shrinkT,
      showText: textOpacity > 0,
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
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
        ),
      ),
    );
  }

  Widget _eventPill({
    required CalendarEvent event,
    required double left,
    required double top,
    required double width,
    required double height,
    required double eventFontSize,
    required double expandT,
    double textOpacity = 1.0,
    double opacity = 1.0,
    bool showText = true,
  }) {
    final color = Color(event.colorValue);
    Widget content = DecoratedBox(
      decoration: calendarEventFillDecoration(
        color,
        borderRadius: BorderRadius.circular(height / 2),
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
      left: left.clamp(0.0, widget.maxWidth - width),
      top: top,
      width: width,
      height: height,
      child: content,
    );
  }
}

/// Single-line event pill for month-view day cells.
class CalendarDayEventBar extends StatelessWidget {
  const CalendarDayEventBar({
    super.key,
    required this.event,
    required this.fontSize,
    this.height,
  });

  final CalendarEvent event;
  final double fontSize;
  final double? height;

  static double heightFor(double fontSize) => fontSize + 4;

  @override
  Widget build(BuildContext context) {
    final barHeight = height ?? heightFor(fontSize);
    return Container(
      height: barHeight,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: calendarEventFillDecoration(
        Color(event.colorValue),
        borderRadius: BorderRadius.circular(barHeight / 2),
      ),
      alignment: Alignment.centerLeft,
      child: Text(
        event.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppFonts.style(fontSize: fontSize, height: 1),
      ),
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

double calendarWeekdayFontSize(
  BuildContext context, {
  double? baseFontSize,
}) {
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
                              _suffixCharT(
                                i,
                                suffixChars.length,
                                styleT,
                              ),
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
    this.showTodoIcons = true,
    this.onDayTap,
    this.onEntryTap,
    this.showWeekdayHeader = false,
    this.weekdayHeaderOpacity = 1,
    this.useSingleLetterWeekdays = false,
    this.selectedDay,
    this.hiddenWeekRow,
  });

  final DateTime month;
  final List<CalendarEvent> events;
  final List<CalendarDayIndicator> indicators;
  final List<CalendarTodoMarker> todoMarkers;
  final bool weekStartsMonday;
  final MonthDayCellStyle style;
  final void Function(DateTime day)? onDayTap;
  final void Function(CalendarDayEntry entry)? onEntryTap;
  final bool showWeekdayHeader;
  final double weekdayHeaderOpacity;
  final bool useSingleLetterWeekdays;
  final DateTime? selectedDay;

  /// When false, todo icons are hidden (e.g. during view morph animations).
  final bool showTodoIcons;

  /// Row index (0–5) whose cells are omitted — used during month↔week morph.
  final int? hiddenWeekRow;

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
                        ? events
                            .where((e) => calendarEventOnDay(e, date))
                            .toList()
                        : const <CalendarEvent>[];
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

                    return Expanded(
                      child: CalendarDayCell(
                        date: date,
                        month: month,
                        events: dayEvents,
                        indicators: dayIndicators,
                        todoMarkers: dayTodos,
                        showTodoIcons: showTodoIcons,
                        style: style,
                        isSelected: isSelected,
                        onTap: onDayTap == null ? null : () => onDayTap!(date),
                        onEntryTap: onEntryTap,
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
