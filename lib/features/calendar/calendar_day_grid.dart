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
    maxEventLines: 6,
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

  int _visibleEventCount(double cellHeight) {
    if (events.isEmpty || style.maxEventLines <= 0) return 0;

    final dayNumberHeight = style.fontSize + 8;
    var used = dayNumberHeight;

    if (indicators.isNotEmpty) {
      used += 2 + style.dotSize;
    }

    const eventGap = 2.0;
    final barStride = CalendarDayEventBar.heightFor(style.eventFontSize) + 1;
    final available = cellHeight - used - eventGap;
    if (available < barStride) return 0;

    final fit = (available / barStride).floor();
    return fit.clamp(0, style.maxEventLines).clamp(0, events.length);
  }

  Widget _buildFullCellContent(bool inMonth, double cellHeight) {
    final visibleEvents = _visibleEventCount(cellHeight);

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
            for (final event in events.take(visibleEvents))
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: CalendarDayEventBar(
                  event: event,
                  fontSize: style.eventFontSize,
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
        if (events.isNotEmpty) ...[
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

/// Single-line event pill for month-view day cells.
class CalendarDayEventBar extends StatelessWidget {
  const CalendarDayEventBar({
    super.key,
    required this.event,
    required this.fontSize,
  });

  final CalendarEvent event;
  final double fontSize;

  static double heightFor(double fontSize) => fontSize + 4;

  @override
  Widget build(BuildContext context) {
    final height = heightFor(fontSize);
    return Container(
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: Color(event.colorValue).withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(height / 2),
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
