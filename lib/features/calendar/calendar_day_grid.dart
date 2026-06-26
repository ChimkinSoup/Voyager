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

/// Text opacity for day numbers outside the displayed month (padding weeks).
const calendarAdjacentMonthTextOpacity = 0.20;

/// Border opacity for padding-week cells in the full month grid (fainter than text).
const calendarAdjacentMonthBorderOpacity = 0.10;

/// Fill alpha for month-view event pills (background tint over the cell).
const calendarEventBarFillAlpha = 0.45;

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
    maxEventLines: 5,
    dotSize: 7,
    eventFontSize: 9,
  );

  /// Year mini-month tiles use adaptive shrink-to-fit; month/week fill their slot.
  bool get isCompactLayout => fontSize <= 9 && eventFontSize < 8;
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
    this.adjacentTextT,
    this.adjacentBorderT,
  });

  final DateTime date;
  final DateTime month;
  final List<CalendarEvent> events;
  final List<CalendarDayIndicator> indicators;
  final MonthDayCellStyle style;
  final VoidCallback? onTap;
  final bool isSelected;

  /// When set, adjacent-month day numbers lerp from muted (0) to active (1).
  final double? adjacentTextT;

  /// When set, adjacent-month borders lerp from muted (0) to active (1).
  final double? adjacentBorderT;

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
    final dayNumberHeight = style.fontSize + 8;
    var headerUsed = dayNumberHeight;
    if (indicators.isNotEmpty) {
      headerUsed += 2 + style.dotSize;
    }
    const eventGap = 2.0;
    final eventAreaHeight =
        (cellHeight - headerUsed - eventGap).clamp(0.0, double.infinity);
    final visibleEvents = calendarVisibleEventCount(
      cellHeight: cellHeight,
      style: style,
      eventCount: events.length,
      hasIndicators: indicators.isNotEmpty,
    );

    return ClipRect(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CalendarDayNumber(
            date: date,
            month: month,
            fontSize: style.fontSize,
            mutedWhenAdjacent: !inMonth,
            adjacentTextT: adjacentTextT,
            isSelected: isSelected,
          ),
          if (indicators.isNotEmpty) ...[
            const SizedBox(height: 2),
            CalendarDayIndicatorDots(
              indicators: indicators,
              dotSize: style.dotSize,
            ),
          ],
          if (visibleEvents > 0) ...[
            const SizedBox(height: 2),
            SizedBox(
              height: eventAreaHeight,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < visibleEvents; i++) ...[
                    if (i > 0) const SizedBox(height: 1),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final barHeight = constraints.maxHeight;
                          final eventFontSize = calendarMonthEventFontSize(
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
          ],
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
          child: CalendarDayNumber(
            date: date,
            month: month,
            fontSize: style.fontSize,
            mutedWhenAdjacent: !inMonth,
            adjacentTextT: adjacentTextT,
            isSelected: isSelected,
          ),
        ),
        if (inMonth && events.isNotEmpty) ...[
          const SizedBox(height: 1),
          CalendarDayEventDots(
            events: events,
            dotSize: style.eventDotSize,
            maxDots: style.maxEventLines,
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
  final eventAreaHeight =
      (cellHeight - headerUsed - eventGap).clamp(0.0, double.infinity);
  final gaps = (visibleEventCount - 1) * betweenEventGap;
  return ((eventAreaHeight - gaps) / visibleEventCount)
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

/// Morphs year-view event dots into month-view bars during year↔month zoom.
///
/// Year→month (styleT 0→1): stack dots → expand A–C → slide out extras from bottom.
/// Month→year (styleT 1→0): minimize bottom-up (extras vanish); top 3 become dots
/// in place, then dots ease to the year row below the date.
class MorphDayEventStack extends StatelessWidget {
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

  static const maxYearDots = 3;
  static const maxMonthEvents = 5;
  static const stackPhaseEnd = 0.35;
  static const expandPhaseEnd = 0.55;
  static const slideSegment = 0.10;
  static const dotStagger = 0.11;
  /// Month→year: each event (bottom-up) minimizes during this styleT span.
  static const reverseSlotSegment = 0.09;
  /// Month→year: after all slots finish shrinking, dots travel to the year row.
  static const reverseMoveDuration = 0.30;

  /// Freeze month layout metrics for the full month→year morph.
  static double shrinkAnchorStyleT(int eventCount) => 1.0;

  /// Bottom-up minimize progress for month→year. 0 = full bar, 1 = done.
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

  /// 0 = dots at month rows, 1 = dots at year row (month→year final phase).
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

  /// Per-slot morph for A/B/C. When [shrinking] (month→year), bottom slot leads.
  static double dotSlotMorphT(
    int index,
    double globalT, {
    required bool shrinking,
    double stagger = dotStagger,
  }) {
    final order = shrinking ? maxYearDots - 1 - index : index;
    if (shrinking) {
      final end = 1.0 - order * stagger;
      final start = end - stagger;
      if (globalT >= end) return 1.0;
      if (globalT <= start) return 0.0;
      return ((globalT - start) / (end - start)).clamp(0.0, 1.0);
    }
    final start = order * stagger;
    final end = start + stagger;
    if (globalT <= start) return 0.0;
    if (globalT >= end) return 1.0;
    return ((globalT - start) / (end - start)).clamp(0.0, 1.0);
  }

  static double stackProgress(double styleT) =>
      (styleT / stackPhaseEnd).clamp(0.0, 1.0);

  static double expandProgress(double styleT) => styleT <= stackPhaseEnd
      ? 0.0
      : ((styleT - stackPhaseEnd) / (expandPhaseEnd - stackPhaseEnd))
          .clamp(0.0, 1.0);

  /// 0 = hidden below row above; 1 = at own month row.
  static double extraSlideT({
    required int index,
    required int total,
    required double styleT,
    required bool monthToYear,
  }) {
    if (index < maxYearDots) return 1.0;

    if (monthToYear) {
      return reverseSlotShrinkT(index: index, count: total, styleT: styleT);
    }

    final order = index - maxYearDots;
    final start = expandPhaseEnd + order * slideSegment;
    final end = start + slideSegment;
    return ((styleT - start) / (end - start)).clamp(0.0, 1.0);
  }

  /// styleT threshold before A–C begin shrinking (year→month only).
  static double _extrasPhaseEnd(int extraCount, {required bool monthToYear}) {
    if (extraCount <= 0) return 1.0;
    if (monthToYear) return 1.0 - extraCount * reverseSlotSegment;
    return expandPhaseEnd;
  }

  int _displayCount(double collapseEnd) {
    final cappedCount = events.length.clamp(0, maxMonthEvents);
    if (cappedCount == 0) return 0;
    if (!inMonth && styleT <= 0) return 0;

    final monthLayoutCount = _morphMonthLayoutEventCount(
      cellHeight: cellHeight,
      eventCount: cappedCount,
    );

    if (morphReverse) return cappedCount;

    if (styleT >= 1.0) return monthLayoutCount;
    return cappedCount;
  }

  double _yearDotXOffset(int index, int dotCount, double dotSize) {
    if (dotCount <= 1) return 0;
    final spacing = dotSize + 1;
    return -((dotCount - 1) * spacing) / 2 + index * spacing;
  }

  @override
  Widget build(BuildContext context) {
    final cappedCount = events.length.clamp(0, maxMonthEvents);
    final extraCount = (cappedCount - maxYearDots).clamp(0, cappedCount);
    final collapseEnd = _extrasPhaseEnd(extraCount, monthToYear: morphReverse);

    final count = _displayCount(collapseEnd);
    if (count == 0) return const SizedBox.shrink();

    final reverseMove = morphReverse
        ? Curves.easeInOutCubic.transform(
            reverseDotMoveT(count: cappedCount, styleT: styleT),
          )
        : 0.0;

    final dotStyleT = morphReverse ? 1.0 : styleT;

    final barMetricT = morphReverse ? 1.0 : styleT;

    final monthLayoutCount = _morphMonthLayoutEventCount(
      cellHeight: cellHeight,
      eventCount: cappedCount,
    );
    final heightEventCount = morphReverse || styleT >= 1.0
        ? monthLayoutCount
        : count.clamp(1, maxMonthEvents);

    final fullMonthBarHeight = calendarMonthEventBarHeight(
      cellHeight: cellHeight,
      style: MonthDayCellStyle.full,
      visibleEventCount: heightEventCount,
    );
    final fullMonthFontSize = calendarMonthEventFontSize(
      barHeight: fullMonthBarHeight,
      style: MonthDayCellStyle.full,
    );

    final stackT = stackProgress(dotStyleT);
    final expandT = expandProgress(dotStyleT);
    final yearDotSize = MonthDayCellStyle.compact.eventDotSize;

    final yearDotCount =
        inMonth ? cappedCount.clamp(0, maxYearDots) : 0;

    final layoutDay = layoutDayLayoutSize ?? dayLayoutSize;
    final frozenMonthEventsTop = layoutDay + 2;
    final frozenBarHeight = calendarMonthEventBarHeight(
      cellHeight: cellHeight,
      style: MonthDayCellStyle.full,
      visibleEventCount: monthLayoutCount.clamp(1, maxMonthEvents),
    );
    final frozenBarStride = frozenBarHeight + 1;

    final eventFontSize = lerpDouble(5.5, fullMonthFontSize, barMetricT)!;
    final barHeight = lerpDouble(yearDotSize, fullMonthBarHeight, barMetricT)!;
    final dotStride = yearDotSize + 1;
    final barStride = barHeight + 1;

    final minEventTop = dayLayoutSize + 2;

    final yearEventsTop = _compactYearDotsTop(cellHeight);
    final monthEventsTop = minEventTop;
    final dotRowY = lerpDouble(yearEventsTop, monthEventsTop, stackT)!
        .clamp(minEventTop, cellHeight);

    return Stack(
      clipBehavior: Clip.hardEdge,
      children: [
        // Highest-index extras paint first so E slides underneath D.
        for (var i = count - 1; i >= maxYearDots; i--)
          _buildEventMarker(
            event: events[i],
            index: i,
            count: count,
            yearDotCount: yearDotCount,
            dotRowY: dotRowY,
            monthEventsTop: monthEventsTop,
            dotStride: dotStride,
            barStride: barStride,
            stackT: stackT,
            expandT: expandT,
            dotSize: yearDotSize,
            barHeight: barHeight,
            eventFontSize: eventFontSize,
            morphReverse: morphReverse,
            minEventTop: minEventTop,
            reverseMove: reverseMove,
            yearEventsTop: yearEventsTop,
            frozenMonthEventsTop: frozenMonthEventsTop,
            frozenBarStride: frozenBarStride,
            frozenBarHeight: frozenBarHeight,
            frozenEventFontSize: fullMonthFontSize,
          ),
        for (var i = 0; i < count && i < maxYearDots; i++)
          _buildEventMarker(
            event: events[i],
            index: i,
            count: count,
            yearDotCount: yearDotCount,
            dotRowY: dotRowY,
            monthEventsTop: monthEventsTop,
            dotStride: dotStride,
            barStride: barStride,
            stackT: stackT,
            expandT: expandT,
            dotSize: yearDotSize,
            barHeight: barHeight,
            eventFontSize: eventFontSize,
            morphReverse: morphReverse,
            minEventTop: minEventTop,
            reverseMove: reverseMove,
            yearEventsTop: yearEventsTop,
            frozenMonthEventsTop: frozenMonthEventsTop,
            frozenBarStride: frozenBarStride,
            frozenBarHeight: frozenBarHeight,
            frozenEventFontSize: fullMonthFontSize,
          ),
      ],
    );
  }

  Widget _buildEventMarker({
    required CalendarEvent event,
    required int index,
    required int count,
    required int yearDotCount,
    required double dotRowY,
    required double monthEventsTop,
    required double dotStride,
    required double barStride,
    required double stackT,
    required double expandT,
    required double dotSize,
    required double barHeight,
    required double eventFontSize,
    required bool morphReverse,
    required double minEventTop,
    double reverseMove = 0.0,
    double yearEventsTop = 0.0,
    double frozenMonthEventsTop = 0.0,
    double frozenBarStride = 0.0,
    double frozenBarHeight = 0.0,
    double frozenEventFontSize = 9.0,
  }) {
    final isDotSlot = index < maxYearDots;

    double clampEventY(double y, double height) =>
        y.clamp(minEventTop, (cellHeight - height).clamp(minEventTop, cellHeight));

    if (!isDotSlot) {
      if (morphReverse) {
        final shrinkT = Curves.easeInOutCubic.transform(
          extraSlideT(
            index: index,
            total: count,
            styleT: styleT,
            monthToYear: true,
          ),
        );
        if (shrinkT >= 1.0) return const SizedBox.shrink();
        if (shrinkT <= 0.0) {
          final ownY = frozenMonthEventsTop + index * frozenBarStride;
          return _eventPill(
            event: event,
            left: 0,
            top: clampEventY(ownY, frozenBarHeight),
            width: maxWidth,
            height: frozenBarHeight,
            eventFontSize: frozenEventFontSize,
            expandT: 1.0,
          );
        }

        final width = lerpDouble(maxWidth, 0, shrinkT)!;
        final height = lerpDouble(frozenBarHeight, 0, shrinkT)!;
        final ownY = frozenMonthEventsTop + index * frozenBarStride;
        if (width < 0.25 || height < 0.25) {
          return const SizedBox.shrink();
        }

        return _eventPill(
          event: event,
          left: (maxWidth - width) / 2,
          top: clampEventY(ownY + (frozenBarHeight - height) / 2, height),
          width: width,
          height: height,
          eventFontSize: frozenEventFontSize,
          expandT: 1.0 - shrinkT,
          opacity: 1.0 - shrinkT,
        );
      }

      final slideOut = extraSlideT(
        index: index,
        total: count,
        styleT: styleT,
        monthToYear: false,
      );
      if (slideOut <= 0) return const SizedBox.shrink();

      final eventsTop = monthEventsTop;
      final stride = barStride;
      final pillHeight = barHeight;
      final ownY = eventsTop + index * stride;
      final underY = eventsTop + (index - 1) * stride;
      final emergeY = underY + pillHeight;
      final y = clampEventY(lerpDouble(emergeY, ownY, slideOut)!, pillHeight);

      return _eventPill(
        event: event,
        left: 0,
        top: y,
        width: maxWidth,
        height: pillHeight,
        eventFontSize: eventFontSize,
        expandT: 1.0,
        opacity: slideOut,
      );
    }

    // A (top), B, C — month→year: shrink in place, then ease dots to year row.
    if (morphReverse) {
      final shrinkT = Curves.easeInOutCubic.transform(
        reverseSlotShrinkT(index: index, count: count, styleT: styleT),
      );
      final yearX = inMonth
          ? _yearDotXOffset(index, yearDotCount, dotSize)
          : 0.0;
      final barY = frozenMonthEventsTop + index * frozenBarStride;

      final width = lerpDouble(maxWidth, dotSize, shrinkT)!;
      final height = lerpDouble(frozenBarHeight, dotSize, shrinkT)!;
      final shrinkTop = barY + (frozenBarHeight - height) / 2;

      final x = lerpDouble(0, yearX, reverseMove)!;
      final y = lerpDouble(shrinkTop, yearEventsTop, reverseMove)!;

      final textOpacity = shrinkT > 0.85
          ? 0.0
          : ((1.0 - shrinkT - 0.15) / 0.7).clamp(0.0, 1.0);

      if (height < 0.25) return const SizedBox.shrink();

      if (shrinkT >= 1.0) {
        return _yearEventDot(
          event: event,
          left: (maxWidth - dotSize) / 2 + x,
          top: y,
          size: dotSize,
        );
      }

      return _eventPill(
        event: event,
        left: (maxWidth - width) / 2 + x,
        top: y.clamp(0.0, (cellHeight - height).clamp(0.0, cellHeight)),
        width: width,
        height: height,
        textOpacity: textOpacity,
        eventFontSize: frozenEventFontSize,
        expandT: 1.0 - shrinkT,
      );
    }

    final slotStackT = dotSlotMorphT(index, stackT, shrinking: false);
    final slotExpandT = dotSlotMorphT(index, expandT, shrinking: false);

    final yearX = inMonth
        ? _yearDotXOffset(index, yearDotCount, dotSize)
        : 0.0;
    final dotStackY = dotRowY + index * dotStride;
    final barY = monthEventsTop + index * barStride;

    final x = lerpDouble(yearX, 0, slotStackT)!;
    final rawY = lerpDouble(
      lerpDouble(dotRowY, dotStackY, slotStackT)!,
      barY,
      slotExpandT,
    )!;
    final width = lerpDouble(dotSize, maxWidth, slotExpandT)!;
    final height = lerpDouble(dotSize, barHeight, slotExpandT)!;
    final y = clampEventY(rawY, height);
    final textOpacity = ((slotExpandT - 0.3) / 0.7).clamp(0.0, 1.0);

    if (height < 0.25 && slotExpandT <= 0) return const SizedBox.shrink();

    if (!morphReverse && slotExpandT <= 0) {
      return _yearEventDot(
        event: event,
        left: (maxWidth - dotSize) / 2 + x,
        top: y,
        size: dotSize,
      );
    }

    return _eventPill(
      event: event,
      left: (maxWidth - width) / 2 + x,
      top: y,
      width: width,
      height: height,
      textOpacity: textOpacity,
      eventFontSize: eventFontSize,
      expandT: slotExpandT,
    );
  }

  Widget _yearEventDot({
    required CalendarEvent event,
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
          color: Color(event.colorValue),
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
  }) {
    final label = Text(
      event.title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: AppFonts.style(
        fontSize: eventFontSize * expandT.clamp(0.6, 1.0),
        height: 1,
      ),
    );

    Widget content = DecoratedBox(
      decoration: BoxDecoration(
        color: Color(event.colorValue).withValues(alpha: calendarEventBarFillAlpha),
        borderRadius: BorderRadius.circular(height / 2),
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 4 * expandT),
          child: textOpacity < 1.0 ? Opacity(opacity: textOpacity, child: label) : label,
        ),
      ),
    );

    if (opacity < 1.0) {
      content = Opacity(opacity: opacity.clamp(0.0, 1.0), child: content);
    }

    return Positioned(
      left: left.clamp(0.0, maxWidth - width),
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
      decoration: BoxDecoration(
        color: Color(event.colorValue).withValues(alpha: calendarEventBarFillAlpha),
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
    this.onDayTap,
    this.showWeekdayHeader = false,
    this.weekdayHeaderOpacity = 1,
    this.useSingleLetterWeekdays = false,
    this.selectedDay,
    this.hiddenWeekRow,
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
                    final dayEvents = events
                        .where((e) => calendarSameDay(e.start, date))
                        .toList();
                    final dayIndicators = indicators
                        .where((i) => calendarSameDay(i.day, date))
                        .take(3)
                        .toList();

                    final isSelected =
                        selectedDay != null &&
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
