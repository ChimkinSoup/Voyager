import 'dart:math' show max;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/theme/app_fonts.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/features/calendar/calendar_day_grid.dart';

export 'calendar_day_grid.dart'
    show
        CalendarDayIndicator,
        CalendarDayNumber,
        MorphWeekdayHeader,
        MonthDayCellStyle,
        MonthDayGrid,
        WeekdayHeaderRow,
        WeekdayMorphMetrics,
        calendarAdjacentMonthBorderOpacity,
        calendarAdjacentMonthColor,
        calendarTitleAccentColor,
        calendarWeekdayAccentColor,
        calendarWeekdayFontSizeScale,
        calendarWeekdayLabelStyle,
        monthDayGridWeekdayHeaderGap,
        monthGridDates;

/// Reused across all month-name formatting calls to avoid repeated allocation.
final _mmmmFormat = DateFormat.MMMM();

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
    this.monthTileKeyBuilder,
    this.yearTileDayGridKeyBuilder,
    this.hiddenMonth,
    this.monthDayGridKey,
    this.onPreviousMonth,
    this.onNextMonth,
  });

  final CalendarViewMode mode;
  final DateTime focused;
  final List<CalendarEvent> events;
  final List<CalendarDayIndicator> indicators;
  final void Function(DateTime day) onDayTap;
  final void Function(DateTime month) onMonthTap;
  final bool weekStartsMonday;
  final GlobalKey Function(DateTime month)? monthTileKeyBuilder;

  /// Provides a [GlobalKey] for the inner [MonthDayGrid] of each year tile,
  /// used to measure source cell positions for the morph animation.
  final GlobalKey Function(DateTime month)? yearTileDayGridKeyBuilder;

  /// Year-view month to render as an invisible placeholder (the "hole" that
  /// the morph foreground cells fill at t=0).
  final DateTime? hiddenMonth;

  /// [GlobalKey] placed on the [MonthDayGrid] inside the full month view,
  /// used to measure destination cell positions for the morph animation.
  final GlobalKey? monthDayGridKey;
  final VoidCallback? onPreviousMonth;
  final VoidCallback? onNextMonth;

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
        dayGridKey: monthDayGridKey,
        onPreviousMonth: onPreviousMonth,
        onNextMonth: onNextMonth,
      ),
      CalendarViewMode.year => _YearGrid(
        focused: focused,
        events: events,
        indicators: indicators,
        onDayTap: onDayTap,
        onMonthTap: onMonthTap,
        weekStartsMonday: weekStartsMonday,
        monthTileKeyBuilder: monthTileKeyBuilder,
        dayGridKeyBuilder: yearTileDayGridKeyBuilder,
        hiddenMonth: hiddenMonth,
      ),
    };
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
    final dayEvents =
        events.where((e) => calendarSameDay(e.start, day)).toList()
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

/// Compact month title with optional prev/next controls hugging the label.
/// Shared by month view and the year↔month morph overlay.
class MonthTitleHeader extends StatelessWidget {
  const MonthTitleHeader({
    super.key,
    required this.month,
    this.onPreviousMonth,
    this.onNextMonth,
    this.navOpacity = 1.0,
    this.navSpread = 1.0,
    this.showTitle = true,
    this.morphTitleStyle,
    this.navCenterY,
  });

  final DateTime month;
  final VoidCallback? onPreviousMonth;
  final VoidCallback? onNextMonth;

  /// Fades nav controls in/out during the year↔month morph.
  final double navOpacity;

  /// 0 = both arrows stacked on the title centre; 1 = final spread positions.
  final double navSpread;

  /// When false, only navigation controls are painted (morph overlay).
  final bool showTitle;

  /// Lerped title style during morph; uses [titleFontSize] when null.
  final TextStyle? morphTitleStyle;

  /// Y offset from the top of the header row to the vertical centre of the
  /// nav icons. When null, derived from measured title glyph metrics.
  final double? navCenterY;

  static const titleFontSize = 36.0;
  static const navIconSize = 24.0;
  static const navTapSize = 32.0;
  static const navSpacing = 8.0;
  static const cardPadding = 8.0;
  static const titleGap = 8.0;
  // Longest English month name — sets a fixed row width so arrow spacing is
  // identical for every month (June, September, etc.).
  static const _widthReferenceMonth = 'September';
  static const heightReferenceText = 'May';

  static const _titleTextHeightBehavior = TextHeightBehavior(
    applyHeightToFirstAscent: true,
    applyHeightToLastDescent: true,
  );

  static const titleTextHeightBehavior = _titleTextHeightBehavior;

  /// Measures the laid-out bounds of [text] for nav alignment.
  static Size measureTitleText(TextStyle titleStyle, String text) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: titleStyle),
      textDirection: TextDirection.ltr,
      textHeightBehavior: _titleTextHeightBehavior,
    )..layout();
    return Size(painter.width, painter.height);
  }

  /// Distance from the top of the laid-out [text] to its cap-height centre.
  static double textVisualCenterDy(TextStyle titleStyle, String text) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: titleStyle),
      textDirection: TextDirection.ltr,
      textHeightBehavior: _titleTextHeightBehavior,
    )..layout();
    final baseline = painter.computeDistanceToActualBaseline(
      TextBaseline.alphabetic,
    );
    final fontSize = titleStyle.fontSize ?? 14;
    return baseline - fontSize * 0.35;
  }

  static TextStyle yearTileMonthNameStyle(BuildContext context) {
    return Theme.of(context).textTheme.titleSmall!.copyWith(
      color: calendarTitleAccentColor(context),
    );
  }

  static TextStyle resolveTitleStyle(
    BuildContext context, {
    TextStyle? morphTitleStyle,
  }) {
    return morphTitleStyle ??
        Theme.of(context).textTheme.titleSmall!.copyWith(
          fontSize: titleFontSize,
          color: calendarTitleAccentColor(context),
        );
  }

  /// Fixed width of the title + nav row for [titleStyle].
  static double titleRowWidth(TextStyle titleStyle) {
    final painter = TextPainter(
      text: TextSpan(text: _widthReferenceMonth, style: titleStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    return navTapSize + navSpacing + painter.width + navSpacing + navTapSize;
  }

  /// Matches the laid-out height of the title row in [_MonthGrid].
  static double preferredHeight(TextStyle titleStyle) {
    final painter = TextPainter(
      text: TextSpan(text: heightReferenceText, style: titleStyle),
      textDirection: TextDirection.ltr,
      textHeightBehavior: _titleTextHeightBehavior,
    )..layout();
    return max(navTapSize, painter.height);
  }

  /// Computes the 42 month-view day-cell [Rect]s analytically from [areaSize],
  /// mirroring [_MonthGrid]'s card padding, title row, weekday row, and 6×7 grid.
  static List<Rect> dayCellRects(
    Size areaSize,
    TextStyle titleStyle, {
    TextStyle? weekdayLabelStyle,
  }) {
    final titleHeight = preferredHeight(titleStyle);
    final weekdayStyle = weekdayLabelStyle ?? titleStyle;
    final weekdayBlock = WeekdayHeaderRow.totalHeight(weekdayStyle);
    final gridLeft = cardPadding;
    final gridTop = cardPadding + titleHeight + titleGap + weekdayBlock;
    final gridWidth = areaSize.width - cardPadding * 2;
    final gridHeight = areaSize.height - gridTop - cardPadding;
    final cellW = gridWidth / 7;
    final cellH = gridHeight / 6;

    return List.generate(
      42,
      (i) => Rect.fromLTWH(
        gridLeft + (i % 7) * cellW,
        gridTop + (i ~/ 7) * cellH,
        cellW,
        cellH,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final opacity = navOpacity.clamp(0.0, 1.0);
    final spread = navSpread.clamp(0.0, 1.0);
    final showNav =
        onPreviousMonth != null ||
        onNextMonth != null ||
        spread > 0 ||
        opacity > 0;
    final titleStyle = resolveTitleStyle(
      context,
      morphTitleStyle: morphTitleStyle,
    );
    final monthName = _mmmmFormat.format(month);
    final textSize = measureTitleText(titleStyle, monthName);
    final rowWidth = titleRowWidth(titleStyle);
    final rowHeight = preferredHeight(titleStyle);
    final textLeft = (rowWidth - textSize.width) / 2;
    final textTop = (rowHeight - textSize.height) / 2;
    final textCenterX = textLeft + textSize.width / 2;
    final iconCenterY =
        navCenterY ?? textTop + textVisualCenterDy(titleStyle, monthName);
    final navTop = iconCenterY - navTapSize / 2;
    final leftFinal = 0.0;
    final rightFinal = rowWidth - navTapSize;
    final collapsedLeft = textCenterX - navTapSize / 2;
    final leftPos = collapsedLeft + (leftFinal - collapsedLeft) * spread;
    final rightPos = collapsedLeft + (rightFinal - collapsedLeft) * spread;

    return Center(
      child: SizedBox(
        width: rowWidth,
        height: rowHeight,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            if (showTitle)
              Positioned(
                left: textLeft,
                top: textTop,
                width: textSize.width,
                child: Text(
                  monthName,
                  style: titleStyle,
                  textAlign: TextAlign.center,
                  textHeightBehavior: _titleTextHeightBehavior,
                ),
              ),
            if (showNav) ...[
              Positioned(
                left: leftPos,
                top: navTop,
                width: navTapSize,
                height: navTapSize,
                child: _navControl(
                  icon: PhosphorIconsRegular.caretLeft,
                  onPressed: onPreviousMonth,
                  opacity: opacity,
                ),
              ),
              Positioned(
                left: rightPos,
                top: navTop,
                width: navTapSize,
                height: navTapSize,
                child: _navControl(
                  icon: PhosphorIconsRegular.caretRight,
                  onPressed: onNextMonth,
                  opacity: opacity,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _navControl({
    required IconData icon,
    required VoidCallback? onPressed,
    required double opacity,
  }) {
    final iconChild = Opacity(
      opacity: opacity,
      child: Icon(icon, size: navIconSize),
    );
    if (onPressed != null && opacity >= 1) {
      return IconButton(
        onPressed: onPressed,
        icon: iconChild,
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(
          width: navTapSize,
          height: navTapSize,
        ),
      );
    }
    return Center(child: iconChild);
  }
}

/// Month title that morphs between year-tile and full month styles.
class MorphMonthTitle extends StatelessWidget {
  const MorphMonthTitle({
    super.key,
    required this.month,
    required this.monthName,
    required this.styleT,
    required this.yearTitleStyle,
    required this.monthTitleStyle,
    this.navOpacity = 0,
    this.navSpread = 0,
    this.navCenterY,
  });

  final DateTime month;
  final String monthName;
  final double styleT;
  final TextStyle yearTitleStyle;
  final TextStyle monthTitleStyle;
  final double navOpacity;
  final double navSpread;

  /// Pre-lerped nav icon vertical centre (distance from top of the title rect).
  /// When provided, [MonthTitleHeader.textVisualCenterDy] is not called on each
  /// build, saving one [TextPainter] per animation frame.
  final double? navCenterY;

  @override
  Widget build(BuildContext context) {
    final titleStyle = TextStyle.lerp(yearTitleStyle, monthTitleStyle, styleT)!;
    final opacity = navOpacity.clamp(0.0, 1.0);
    final spread = navSpread.clamp(0.0, 1.0);
    final showNav = opacity > 0.01;
    final effectiveNavCenterY =
        navCenterY ??
        MonthTitleHeader.textVisualCenterDy(titleStyle, monthName);

    return Stack(
      clipBehavior: Clip.none,
      fit: StackFit.expand,
      children: [
        Align(
          alignment: Alignment.topCenter,
          child: Text(
            monthName,
            style: titleStyle,
            textAlign: TextAlign.center,
            maxLines: 1,
            textHeightBehavior: MonthTitleHeader.titleTextHeightBehavior,
          ),
        ),
        if (showNav)
          MonthTitleHeader(
            month: month,
            navOpacity: opacity,
            navSpread: spread,
            showTitle: false,
            morphTitleStyle: titleStyle,
            navCenterY: effectiveNavCenterY,
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
    this.dayGridKey,
    this.onPreviousMonth,
    this.onNextMonth,
  });

  final DateTime focused;
  final List<CalendarEvent> events;
  final List<CalendarDayIndicator> indicators;
  final void Function(DateTime day) onDayTap;
  final bool weekStartsMonday;

  /// Optional key placed on the inner [MonthDayGrid] for measurement.
  final GlobalKey? dayGridKey;
  final VoidCallback? onPreviousMonth;
  final VoidCallback? onNextMonth;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            MonthTitleHeader(
              month: focused,
              onPreviousMonth: onPreviousMonth,
              onNextMonth: onNextMonth,
            ),
            const SizedBox(height: MonthTitleHeader.titleGap),
            WeekdayHeaderRow(weekStartsMonday: weekStartsMonday),
            const SizedBox(height: monthDayGridWeekdayHeaderGap),
            Expanded(
              child: MonthDayGrid(
                key: dayGridKey,
                month: focused,
                events: events,
                indicators: indicators,
                weekStartsMonday: weekStartsMonday,
                style: MonthDayCellStyle.full,
                onDayTap: onDayTap,
              ),
            ),
          ],
        ),
      ),
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

class _YearGrid extends StatelessWidget {
  const _YearGrid({
    required this.focused,
    required this.events,
    required this.indicators,
    required this.onDayTap,
    required this.onMonthTap,
    required this.weekStartsMonday,
    this.monthTileKeyBuilder,
    this.dayGridKeyBuilder,
    this.hiddenMonth,
  });

  final DateTime focused;
  final List<CalendarEvent> events;
  final List<CalendarDayIndicator> indicators;
  final void Function(DateTime day) onDayTap;
  final void Function(DateTime month) onMonthTap;
  final bool weekStartsMonday;
  final GlobalKey Function(DateTime month)? monthTileKeyBuilder;

  /// Provides a key for each tile's inner [MonthDayGrid] (for measurement).
  final GlobalKey Function(DateTime month)? dayGridKeyBuilder;

  /// Month to replace with an invisible placeholder — the "hole" that expands
  /// as the background zooms during the morph animation.
  final DateTime? hiddenMonth;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const crossAxisCount = 3;
        const rowCount = 4;
        const crossAxisSpacing = 8.0;
        const mainAxisSpacing = 6.0;

        final cellWidth =
            (constraints.maxWidth - crossAxisSpacing * (crossAxisCount - 1)) /
            crossAxisCount;
        final cellHeight =
            (constraints.maxHeight - mainAxisSpacing * (rowCount - 1)) /
            rowCount;
        final childAspectRatio = cellWidth / cellHeight;

        return GridView.builder(
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            childAspectRatio: childAspectRatio,
            mainAxisSpacing: mainAxisSpacing,
            crossAxisSpacing: crossAxisSpacing,
          ),
          itemCount: 12,
          itemBuilder: (_, i) => _buildMonthTile(context, i),
        );
      },
    );
  }

  Widget _buildMonthTile(BuildContext context, int i) {
    final monthDate = DateTime(focused.year, i + 1);
    final tileKey = monthTileKeyBuilder?.call(monthDate);

    // Render an invisible placeholder so the grid slot stays occupied
    // but the morph foreground cells can fill the visual hole at t=0.
    final isHidden =
        hiddenMonth != null &&
        monthDate.year == hiddenMonth!.year &&
        monthDate.month == hiddenMonth!.month;
    if (isHidden) {
      return KeyedSubtree(key: tileKey, child: const SizedBox.expand());
    }

    final dayGridKey = dayGridKeyBuilder?.call(monthDate);

    return KeyedSubtree(
      key: tileKey,
      child: InkWell(
        onTap: () => onMonthTap(monthDate),
        borderRadius: BorderRadius.circular(18),
        child: Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  _mmmmFormat.format(monthDate),
                  style: MonthTitleHeader.yearTileMonthNameStyle(context),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textHeightBehavior: MonthTitleHeader.titleTextHeightBehavior,
                ),
                const SizedBox(height: MonthTitleHeader.titleGap),
                WeekdayHeaderRow(
                  weekStartsMonday: weekStartsMonday,
                  useSingleLetterLabels: true,
                  labelStyle: calendarWeekdayLabelStyle(
                    context,
                    fontSize: MonthDayCellStyle.compact.fontSize,
                  ),
                ),
                const SizedBox(height: monthDayGridWeekdayHeaderGap),
                Expanded(
                  child: MonthDayGrid(
                    key: dayGridKey,
                    month: monthDate,
                    events: events,
                    indicators: indicators,
                    weekStartsMonday: weekStartsMonday,
                    style: MonthDayCellStyle.compact,
                  ),
                ),
              ],
            ),
          ),
        ),
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

DateTime _weekStart(DateTime date, bool weekStartsMonday) {
  final weekday = date.weekday;
  final offset = weekStartsMonday ? weekday - DateTime.monday : weekday % 7;
  return DateTime(
    date.year,
    date.month,
    date.day,
  ).subtract(Duration(days: offset));
}
