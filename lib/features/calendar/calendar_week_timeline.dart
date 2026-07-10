import 'dart:ui' show lerpDouble;

import 'dart:math' show max;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:voyager/core/theme/app_fonts.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/features/calendar/calendar_day_grid.dart';
import 'package:voyager/features/calendar/calendar_overlap_engine.dart';
import 'package:voyager/features/calendar/calendar_todo_markers.dart';

final _weekDayDateLabelFormat = DateFormat('MMM d');

const _weekDayDateLabelPaddingH = 10.0;
const _weekDayDateLabelPaddingV = 6.0;

TextStyle _weekDayDateLabelTextStyle(TextStyle weekdayStyle) {
  return weekdayStyle.copyWith(
    fontSize: calendarWeekDayDateLabelFontSize,
    fontWeight: FontWeight.w500,
    height: 1,
  );
}

/// Diameter for today's date pill — sized from the widest typical label.
double calendarWeekDayDateLabelTodayDiameter(TextStyle weekdayStyle) {
  final painter = TextPainter(
    text: TextSpan(text: 'Sep 30', style: _weekDayDateLabelTextStyle(weekdayStyle)),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout();
  return max(
    painter.width + _weekDayDateLabelPaddingH,
    painter.height + _weekDayDateLabelPaddingV,
  );
}

double _weekDayDateLabelPlainHeight(TextStyle weekdayStyle) {
  final painter = TextPainter(
    text: TextSpan(text: 'Sep 30', style: _weekDayDateLabelTextStyle(weekdayStyle)),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout();
  return painter.height;
}

/// Layout height for one week-view date label (accounts for today pill).
double calendarWeekDayDateLabelRowHeight(TextStyle weekdayStyle) {
  return max(
    calendarWeekDayDateLabelTodayDiameter(weekdayStyle),
    _weekDayDateLabelPlainHeight(weekdayStyle),
  );
}

/// Space reserved below bordered day columns for the date label row.
double calendarWeekDayDateLabelReservedHeight(TextStyle weekdayStyle) =>
    calendarWeekDayDateLabelGap + calendarWeekDayDateLabelRowHeight(weekdayStyle);

/// Weekday header block height above the day area — matches [CalendarWeekTimeline].
double calendarWeekTimelineHeaderBlockHeight(TextStyle weekdayStyle) =>
    calendarWeekHeaderTopPadding +
    WeekdayHeaderRow.labelHeight(weekdayStyle) +
    calendarWeekHeaderGap;

/// Absolute Y of the date-label row in calendar-area coordinates — matches the
/// live week timeline layout (not month-view card padding).
double calendarWeekDayDateLabelRowTopInArea(
  Size areaSize,
  TextStyle weekdayStyle,
) {
  final headerBlock = calendarWeekTimelineHeaderBlockHeight(weekdayStyle);
  final margin = weekViewDayCellStyle.cellMargin.left;
  final reserved = calendarWeekDayDateLabelReservedHeight(weekdayStyle);
  final dayAreaHeight = areaSize.height - headerBlock;
  final columnBottom =
      dayAreaHeight - margin - calendarWeekDayColumnBottomInset - reserved;
  return headerBlock + columnBottom + calendarWeekDayDateLabelGap;
}

/// "MMM d" label pinned below a week day column (today gets a primary circle).
class CalendarWeekDayDateLabel extends StatelessWidget {
  const CalendarWeekDayDateLabel({super.key, required this.date});

  final DateTime date;

  @override
  Widget build(BuildContext context) {
    const fontSize = calendarWeekDayDateLabelFontSize;
    final theme = Theme.of(context);
    final isToday = calendarIsToday(date);
    final accent = theme.colorScheme.primary;
    final textColor =
        isToday ? theme.colorScheme.onPrimary : theme.colorScheme.onSurfaceVariant;
    final labelText = _weekDayDateLabelFormat.format(date);

    final label = Text(
      labelText,
      maxLines: 1,
      softWrap: false,
      textAlign: TextAlign.center,
      textHeightBehavior: const TextHeightBehavior(
        applyHeightToFirstAscent: false,
        applyHeightToLastDescent: false,
      ),
      style: AppFonts.style(
        fontSize: fontSize,
        fontWeight: FontWeight.w500,
        height: 1,
        color: textColor,
      ),
    );

    if (!isToday) return label;

    final textStyle = AppFonts.style(
      fontSize: fontSize,
      fontWeight: FontWeight.w500,
      height: 1,
      color: textColor,
    );
    final painter = TextPainter(
      text: TextSpan(text: labelText, style: textStyle),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final diameter = max(
      painter.width + _weekDayDateLabelPaddingH,
      painter.height + _weekDayDateLabelPaddingV,
    );

    return Container(
      width: diameter,
      height: diameter,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
      child: label,
    );
  }
}

/// Layout metrics shared by the week timeline and morph geometry.
class CalendarWeekLayoutMetrics {
  const CalendarWeekLayoutMetrics({
    required this.weekdayHeaderHeight,
    required this.allDayShelfHeight,
    required this.timeGutterWidth,
    required this.horizontalPadding,
    required this.columnRects,
    required this.dayColumnRects,
    required this.timelineTop,
    required this.timelineViewportHeight,
    required this.allDayAreaTop,
  });

  final double weekdayHeaderHeight;
  final double allDayShelfHeight;
  final double timeGutterWidth;
  final double horizontalPadding;
  final List<Rect> columnRects;
  final List<Rect> dayColumnRects;
  final double timelineTop;
  final double timelineViewportHeight;

  /// Top Y of the pinned all-day shelf (above bordered timed columns).
  final double allDayAreaTop;

  /// Timeline content area inside a day column's bordered rectangle.
  Rect innerColumnRect(int dayIndex) {
    final outer = columnRects[dayIndex];
    final margin = weekViewDayCellStyle.cellMargin.left;
    return Rect.fromLTRB(
      outer.left + margin,
      outer.top,
      outer.right - margin,
      outer.bottom,
    );
  }

  /// Bordered day column shell (all-day shelf + timeline).
  Rect borderedDayColumnRect(int dayIndex) {
    final outer = dayColumnRects[dayIndex];
    final margin = weekViewDayCellStyle.cellMargin.left;
    return Rect.fromLTRB(
      outer.left + margin,
      outer.top + margin,
      outer.right - margin,
      outer.bottom - margin,
    );
  }

  static CalendarWeekLayoutMetrics compute({
    required Size areaSize,
    required TextStyle weekdayStyle,
    double horizontalPadding = calendarWeekHorizontalPadding,
    double? allDayShelfHeight,
  }) {
    final shelfHeight = allDayShelfHeight ?? calendarWeekAllDayShelfHeight;
    final weekdayHeaderHeight = WeekdayHeaderRow.labelHeight(weekdayStyle);
    final dayAreaTop = calendarWeekHeaderTopPadding +
        weekdayHeaderHeight +
        calendarWeekHeaderGap +
        calendarWeekDayColumnTopInset;
    final dateLabelReserved =
        calendarWeekDayDateLabelReservedHeight(weekdayStyle);
    final dayColumnBottom =
        areaSize.height - calendarWeekDayColumnBottomInset - dateLabelReserved;
    final allDayAreaTop = dayAreaTop;
    final timedAreaTop = dayAreaTop + shelfHeight;
    final timedAreaHeight = dayColumnBottom - timedAreaTop;
    final timelineViewportHeight = max(0.0, timedAreaHeight);
    final gridLeft = horizontalPadding;
    final gridWidth = areaSize.width - horizontalPadding * 2;
    final cellW = gridWidth / 7;
    final columnRects = List.generate(
      7,
      (i) => Rect.fromLTWH(
        gridLeft + i * cellW,
        timedAreaTop,
        cellW,
        timelineViewportHeight,
      ),
    );
    final dayColumnRects = List.generate(
      7,
      (i) => Rect.fromLTWH(
        gridLeft + i * cellW,
        timedAreaTop,
        cellW,
        timedAreaHeight,
      ),
    );
    return CalendarWeekLayoutMetrics(
      weekdayHeaderHeight: weekdayHeaderHeight,
      allDayShelfHeight: shelfHeight,
      timeGutterWidth: calendarWeekTimeGutterWidth,
      horizontalPadding: horizontalPadding,
      columnRects: columnRects,
      dayColumnRects: dayColumnRects,
      timelineTop: timedAreaTop,
      timelineViewportHeight: timelineViewportHeight,
      allDayAreaTop: allDayAreaTop,
    );
  }
}

typedef CalendarWeekEventTap = void Function(CalendarEvent event);
typedef CalendarWeekTodoTap = void Function(CalendarTodoMarker marker);
typedef CalendarWeekSlotTap = void Function(DateTime day, DateTime time);

class CalendarWeekTimeline extends StatefulWidget {
  const CalendarWeekTimeline({
    super.key,
    required this.weekStart,
    required this.events,
    required this.todoMarkers,
    required this.weekStartsMonday,
    required this.onEventTap,
    required this.onTodoTap,
    required this.onSlotTap,
    this.interactive = true,
    this.initialScrollOffset,
    this.scrollController,
    this.showWeekdayHeader = true,
    this.showDayDateLabels = true,
    this.entryFadeEnabled = true,
    this.editingEventId,
  });

  final DateTime weekStart;
  final List<CalendarEvent> events;
  final List<CalendarTodoMarker> todoMarkers;
  final bool weekStartsMonday;
  final CalendarWeekEventTap onEventTap;
  final CalendarWeekTodoTap onTodoTap;
  final CalendarWeekSlotTap onSlotTap;
  final bool interactive;
  final double? initialScrollOffset;
  final ScrollController? scrollController;
  final bool showWeekdayHeader;
  final bool showDayDateLabels;
  final bool entryFadeEnabled;
  final String? editingEventId;

  @override
  State<CalendarWeekTimeline> createState() => _CalendarWeekTimelineState();
}

class _CalendarWeekTimelineState extends State<CalendarWeekTimeline>
    with SingleTickerProviderStateMixin {
  late final ScrollController _scrollController;
  late final bool _ownsScrollController;
  AnimationController? _entryFadeController;
  late Animation<double> _entryFade;

  // Formats an hour (0-24) as "12 AM", "1 AM", "12 PM", etc. — no ":00".
  static String _hourLabel(int hour) => calendarWeekHourLabel(hour);

  @override
  void initState() {
    super.initState();
    if (widget.entryFadeEnabled) {
      _entryFadeController = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 300),
      )..forward();
      _entryFade = _entryFadeController!;
    } else {
      _entryFade = const AlwaysStoppedAnimation(1.0);
    }
    if (widget.scrollController != null) {
      _scrollController = widget.scrollController!;
      _ownsScrollController = false;
    } else {
      final maxContent = calendarWeekTimelineScrollContentHeight();
      final offset = (widget.initialScrollOffset ?? calendarWeekDefaultScrollOffset())
          .clamp(0.0, maxContent);
      _scrollController = ScrollController(initialScrollOffset: offset);
      _ownsScrollController = true;
    }
  }

  @override
  void didUpdateWidget(CalendarWeekTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.entryFadeEnabled &&
        oldWidget.weekStart != widget.weekStart &&
        _entryFadeController != null) {
      _entryFadeController!
        ..value = 0
        ..forward();
    }
  }

  @override
  void dispose() {
    _entryFadeController?.dispose();
    if (_ownsScrollController) {
      _scrollController.dispose();
    }
    super.dispose();
  }

  void _handleBackgroundTap(
    Offset localPosition,
    List<Rect> timelineColumnRects,
  ) {
    if (!widget.interactive) return;

    final dayIndex = timelineColumnRects.indexWhere(
      (rect) => localPosition.dx >= rect.left && localPosition.dx < rect.right,
    );
    if (dayIndex < 0) return;

    // localPosition is relative to the timed scroll content (includes top padding).
    final timelineY = localPosition.dy - calendarWeekTimelineScrollPadding;
    if (timelineY < 0 || timelineY > calendarWeekTimelineHeight) return;

    final minutes = (timelineY / calendarWeekPxPerHour * 60).floor();
    final clampedMinutes = minutes.clamp(0, 24 * 60 - 1);
    final day = widget.weekStart.add(Duration(days: dayIndex));
    final time = DateTime(
      day.year,
      day.month,
      day.day,
      clampedMinutes ~/ 60,
      clampedMinutes % 60,
    );
    widget.onSlotTap(day, time);
  }

  @override
  Widget build(BuildContext context) {
    final divider = Theme.of(context).dividerColor;
    final onSurfaceVariant = Theme.of(context).colorScheme.onSurfaceVariant;
    final accentColor = Theme.of(context).colorScheme.primary;
    final scrollContentHeight = calendarWeekTimelineScrollContentHeight();

    return LayoutBuilder(
      builder: (context, constraints) {
        final weekdayStyle = calendarWeekdayLabelStyle(
          context,
          fontSize: calendarWeekWeekdayFontSize,
        );
        final metrics = CalendarWeekLayoutMetrics.compute(
          areaSize: Size(constraints.maxWidth, constraints.maxHeight),
          weekdayStyle: weekdayStyle,
        );
        final weekDays = List.generate(
          7,
          (i) => widget.weekStart.add(Duration(days: i)),
        );
        final today = DateTime.now();
        final todayIndex = weekDays.indexWhere((d) => calendarSameDay(d, today));
        
        final allDayShelfHeight = calendarWeekAllDayShelfHeightFor(
          events: widget.events,
          weekDays: weekDays,
        );
        final packedAllDayShelf = calendarPackWeekAllDayShelf(
          events: widget.events,
          weekDays: weekDays,
        );
        final allDayShelfRowCount =
            calendarWeekAllDayShelfRowCount(packedAllDayShelf);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Always reserve the header space so that day-column layout is
            // stable regardless of showWeekdayHeader. The morph animation
            // hides the header via showWeekdayHeader: false while keeping a
            // separate sliding header in the morph layer above.
            Visibility(
              visible: widget.showWeekdayHeader,
              maintainState: true,
              maintainSize: true,
              maintainAnimation: true,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: calendarWeekHeaderTopPadding),
                  Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: metrics.horizontalPadding,
                    ),
                    child: WeekdayHeaderRow(
                      weekStartsMonday: widget.weekStartsMonday,
                      labelStyle: weekdayStyle,
                    ),
                  ),
                  const SizedBox(height: calendarWeekHeaderGap),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: metrics.horizontalPadding),
                child: LayoutBuilder(
                  builder: (context, dayAreaConstraints) {
                    final dayAreaSize = Size(
                      dayAreaConstraints.maxWidth,
                      dayAreaConstraints.maxHeight,
                    );
                    final cellW = dayAreaSize.width / 7;
                    final margin = weekViewDayCellStyle.cellMargin.left;
                    final borderRadius = weekViewDayCellStyle.borderRadius;
                    final allDayAreaTop = margin + calendarWeekDayColumnTopInset;
                    final timedAreaTop = allDayAreaTop + allDayShelfHeight;
                    final dateLabelRowHeight =
                        calendarWeekDayDateLabelRowHeight(weekdayStyle);
                    final dateLabelReserved =
                        calendarWeekDayDateLabelGap + dateLabelRowHeight;
                    final columnBottom =
                        dayAreaSize.height -
                        margin -
                        calendarWeekDayColumnBottomInset -
                        dateLabelReserved;
                    final dateLabelRowTop =
                        columnBottom + calendarWeekDayDateLabelGap;

                    final borderedDayRects = List.generate(7, (i) {
                      return Rect.fromLTRB(
                        i * cellW + margin,
                        timedAreaTop,
                        (i + 1) * cellW - margin,
                        columnBottom,
                      );
                    });

                    final timelineViewportHeight = max(
                      0.0,
                      columnBottom - timedAreaTop,
                    );

                    final timedViewportColumnRects = borderedDayRects
                        .map(
                          (r) => Rect.fromLTRB(
                            r.left,
                            0,
                            r.right,
                            timelineViewportHeight,
                          ),
                        )
                        .toList();

                    // x-bounds for hit-testing within the timed scroll content.
                    final timelineColumnRects = borderedDayRects
                        .map(
                          (r) => Rect.fromLTWH(
                            r.left,
                            0,
                            r.width,
                            calendarWeekTimelineHeight,
                          ),
                        )
                        .toList();

                    return Stack(
                      clipBehavior: Clip.hardEdge,
                      children: [
                        // ── Bordered day-column rectangles (fixed background) ──
                        Positioned.fill(
                          child: IgnorePointer(
                            child: CustomPaint(
                              painter: CalendarWeekDayColumnBorderPainter(
                                borderedRects: borderedDayRects,
                                color: divider,
                                borderRadius: borderRadius,
                                todayIndex: todayIndex >= 0 ? todayIndex : null,
                                todayFillColor: accentColor.withValues(
                                  alpha: 0.28,
                                ),
                              ),
                            ),
                          ),
                        ),

                        FadeTransition(
                          opacity: _entryFade,
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              // ── Pinned all-day shelf (above bordered timed columns) ──
                              for (var i = 0; i < 7; i++)
                                Positioned(
                                  left: i * cellW + margin,
                                  top: allDayAreaTop,
                                  width: cellW - margin * 2,
                                  height: allDayShelfHeight,
                                  child: _AllDayShelfColumn(
                                    day: weekDays[i],
                                    columnEvents: packedAllDayShelf[i],
                                    rowCount: allDayShelfRowCount,
                                    margin: margin,
                                    isFirstColumn: i == 0,
                                    isLastColumn: i == 6,
                                    onEventTap: widget.onEventTap,
                                    editingEventId: widget.editingEventId,
                                  ),
                                ),

                              // ── Scrollable timed grid (12 AM – 12 AM) ──
                              Positioned(
                                left: 0,
                                top: timedAreaTop,
                                right: 0,
                                height: timelineViewportHeight,
                                child: ClipPath(
                                  clipper: _WeekTimedViewportClipper(
                                    columnRects: timedViewportColumnRects,
                                    borderRadius: borderRadius,
                                  ),
                                  child: SingleChildScrollView(
                                    controller: _scrollController,
                                    child: SizedBox(
                                      height: scrollContentHeight,
                                      width: dayAreaSize.width,
                                      child: Stack(
                                        clipBehavior: Clip.none,
                                        children: [
                                          Positioned.fill(
                                            child: GestureDetector(
                                              behavior: HitTestBehavior.translucent,
                                              onTapDown: widget.interactive
                                                  ? (d) => _handleBackgroundTap(
                                                        d.localPosition,
                                                        timelineColumnRects,
                                                      )
                                                  : null,
                                              child: const SizedBox.expand(),
                                            ),
                                          ),
                                          for (var i = 0; i < 7; i++)
                                            _DayTimedColumn(
                                              day: weekDays[i],
                                              columnRect: timelineColumnRects[i],
                                              events: widget.events,
                                              todoMarkers: widget.todoMarkers,
                                              onEventTap: widget.onEventTap,
                                              onTodoTap: widget.onTodoTap,
                                              interactive: widget.interactive,
                                              editingEventId: widget.editingEventId,
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),

                        // ── Date labels (MMM d) — chrome, not part of event fade ──
                        if (widget.showDayDateLabels)
                          for (var i = 0; i < 7; i++)
                            Positioned(
                              left: i * cellW,
                              width: cellW,
                              top: dateLabelRowTop,
                              height: dateLabelRowHeight,
                              child: Center(
                                child: CalendarWeekDayDateLabel(
                                  date: weekDays[i],
                                ),
                              ),
                            ),

                        // ── Hour-line grid ──
                        Positioned(
                          left: 0,
                          top: timedAreaTop,
                          right: 0,
                          height: timelineViewportHeight,
                          child: IgnorePointer(
                            child: AnimatedBuilder(
                              animation: _scrollController,
                              builder: (context, _) {
                                return CustomPaint(
                                  painter: CalendarWeekTimeGridPainter(
                                    scrollOffset: calendarWeekEffectiveScrollOffset(
                                      _scrollController,
                                      widget.initialScrollOffset ??
                                          _scrollController.initialScrollOffset,
                                    ),
                                    allDayShelfHeight: 0,
                                    borderedClipRects: timedViewportColumnRects,
                                    borderRadius: borderRadius,
                                    lineColor: divider.withValues(alpha: 0.45),
                                    labelColor: onSurfaceVariant,
                                    hourLabelBuilder: _hourLabel,
                                    timelineScrollPadding:
                                        calendarWeekTimelineScrollPadding,
                                  ),
                                );
                              },
                            ),
                          ),
                        ),

                      ],
                    );
                  },
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _AllDayShelfColumn extends StatelessWidget {
  const _AllDayShelfColumn({
    required this.day,
    required this.columnEvents,
    required this.rowCount,
    required this.margin,
    required this.isFirstColumn,
    required this.isLastColumn,
    required this.onEventTap,
    this.editingEventId,
  });

  final DateTime day;
  final List<CalendarEvent?> columnEvents;
  final int rowCount;
  final double margin;
  final bool isFirstColumn;
  final bool isLastColumn;
  final CalendarWeekEventTap onEventTap;
  final String? editingEventId;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < rowCount; i++)
          SizedBox(
            height: calendarWeekAllDayEventRowHeight,
            child: i < columnEvents.length && columnEvents[i] != null
                ? CalendarWeekEventBlock(
                    key: ValueKey('allday-${columnEvents[i]!.id}-$i'),
                    event: columnEvents[i]!,
                    day: day,
                    margin: margin,
                    isFirstColumn: isFirstColumn,
                    isLastColumn: isLastColumn,
                    highlighted: editingEventId == columnEvents[i]!.id,
                    onTap: () => onEventTap(columnEvents[i]!),
                  )
                : const SizedBox.shrink(),
          ),
      ],
    );
  }
}

class _DayTimedColumn extends StatelessWidget {
  const _DayTimedColumn({
    required this.day,
    required this.columnRect,
    required this.events,
    required this.todoMarkers,
    required this.onEventTap,
    required this.onTodoTap,
    required this.interactive,
    this.editingEventId,
  });

  final DateTime day;
  /// x-bounds of this column within the timed scroll content.
  final Rect columnRect;
  final List<CalendarEvent> events;
  final List<CalendarTodoMarker> todoMarkers;
  final CalendarWeekEventTap onEventTap;
  final CalendarWeekTodoTap onTodoTap;
  final bool interactive;
  final String? editingEventId;

  @override
  Widget build(BuildContext context) {
    final slots = layoutDayColumn(
      day: day,
      events: events,
      todos: calendarTodoMarkersForDay(todoMarkers, day),
      pxPerHour: calendarWeekPxPerHour,
      taskBarHeight: calendarWeekTaskBarHeight,
    );

    return Positioned(
      left: columnRect.left,
      top: 0,
      width: columnRect.width,
      height: calendarWeekTimelineScrollContentHeight(),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (final slot in slots)
            Positioned(
              left: slot.left * columnRect.width,
              top: slot.top + calendarWeekTimelineScrollPadding,
              width: slot.width * columnRect.width,
              height: slot.height,
              child: IgnorePointer(
                ignoring: !interactive,
                child: slot.entry.isTodo
                    ? CalendarWeekTaskBar(
                        key: ValueKey('todo-${slot.entry.todo!.taskId}'),
                        marker: slot.entry.todo!,
                        onTap: () => onTodoTap(slot.entry.todo!),
                      )
                    : CalendarWeekEventBlock(
                        key: ValueKey('event-${slot.entry.event!.id}'),
                        event: slot.entry.event!,
                        highlighted: editingEventId == slot.entry.event!.id,
                        onTap: () => onEventTap(slot.entry.event!),
                      ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Clips the timed scroll viewport per day column so rounded corners stay
/// visible at the top and bottom while scrolling.
class _WeekTimedViewportClipper extends CustomClipper<Path> {
  const _WeekTimedViewportClipper({
    required this.columnRects,
    required this.borderRadius,
  });

  final List<Rect> columnRects;
  final double borderRadius;

  @override
  Path getClip(Size size) {
    final path = Path();
    for (final rect in columnRects) {
      path.addRRect(
        RRect.fromRectAndRadius(rect, Radius.circular(borderRadius)),
      );
    }
    return path;
  }

  @override
  bool shouldReclip(_WeekTimedViewportClipper old) =>
      old.columnRects != columnRects || old.borderRadius != borderRadius;
}

// ─────────────────────────────────────────────────────────────────────────────

/// Bordered day-column shells matching month-view cell spacing.
class CalendarWeekDayColumnBorderPainter extends CustomPainter {
  const CalendarWeekDayColumnBorderPainter({
    required this.borderedRects,
    required this.color,
    required this.borderRadius,
    this.todayIndex,
    this.todayFillColor,
  });

  final List<Rect> borderedRects;
  final Color color;
  final double borderRadius;
  final int? todayIndex;
  final Color? todayFillColor;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    if (todayIndex != null && todayFillColor != null && todayIndex! >= 0 && todayIndex! < borderedRects.length) {
      final fillPaint = Paint()
        ..color = todayFillColor!
        ..style = PaintingStyle.fill;
      canvas.drawRRect(
        RRect.fromRectAndRadius(borderedRects[todayIndex!], Radius.circular(borderRadius)),
        fillPaint,
      );
    }

    for (final rect in borderedRects) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, Radius.circular(borderRadius)),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(CalendarWeekDayColumnBorderPainter old) =>
      old.color != color ||
      old.borderRadius != borderRadius ||
      old.borderedRects != borderedRects ||
      old.todayIndex != todayIndex ||
      old.todayFillColor != todayFillColor;
}

/// Insets [outerRects] by [margin] on each side.
List<Rect> calendarWeekBorderedDayColumnRects({
  required List<Rect> outerRects,
  required double margin,
}) {
  return outerRects
      .map(
        (outer) => Rect.fromLTRB(
          outer.left + margin,
          outer.top + margin,
          outer.right - margin,
          outer.bottom - margin,
        ),
      )
      .toList();
}

/// Bordered rects for month↔week morph cells as they lerp between layouts.
List<Rect> calendarWeekMorphBorderedDayColumnRects({
  required List<Rect> monthRowRects,
  required List<Rect> weekColumnRects,
  required double t,
}) {
  final margin = lerpDouble(
    MonthDayCellStyle.full.cellMargin.left,
    weekViewDayCellStyle.cellMargin.left,
    t,
  )!;

  return List.generate(7, (i) {
    final outer = Rect.lerp(monthRowRects[i], weekColumnRects[i], t)!;
    return Rect.fromLTRB(
      outer.left + margin,
      outer.top + margin,
      outer.right - margin,
      outer.bottom - margin,
    );
  });
}

double calendarWeekMorphBorderRadius(double t) =>
    lerpDouble(
      MonthDayCellStyle.full.borderRadius,
      weekViewDayCellStyle.borderRadius,
      t,
    )!;

/// Formats an hour (0-24) as "12 AM", "1 AM", "12 PM", etc.
String calendarWeekHourLabel(int hour) {
  final h = hour % 12 == 0 ? 12 : hour % 12;
  final suffix = hour % 24 < 12 ? 'AM' : 'PM';
  return '$h $suffix';
}

/// Clip path for hour lines: one outer rounded shell spanning all day columns so
/// lines stay solid across the gaps between days.
Path calendarWeekHourLineClipPath({
  required List<Rect> borderedDayRects,
  required double borderRadius,
}) {
  if (borderedDayRects.isEmpty) return Path();

  return Path()
    ..addRRect(
      RRect.fromRectAndCorners(
        Rect.fromLTRB(
          borderedDayRects.first.left,
          borderedDayRects.first.top,
          borderedDayRects.last.right,
          borderedDayRects.last.bottom,
        ),
        topLeft: Radius.circular(borderRadius),
        topRight: Radius.circular(borderRadius),
        bottomLeft: Radius.circular(borderRadius),
        bottomRight: Radius.circular(borderRadius),
      ),
    );
}

/// Fixed-viewport hour-line + label overlay.
class CalendarWeekTimeGridPainter extends CustomPainter {
  const CalendarWeekTimeGridPainter({
    required this.scrollOffset,
    required this.allDayShelfHeight,
    required this.borderedClipRects,
    required this.borderRadius,
    required this.lineColor,
    required this.labelColor,
    required this.hourLabelBuilder,
    this.lineOpacity = 1,
    this.timelineScrollPadding = calendarWeekTimelineScrollPadding,
  });

  final double scrollOffset;
  final double allDayShelfHeight;
  final List<Rect> borderedClipRects;
  final double borderRadius;
  final Color lineColor;
  final Color labelColor;
  final String Function(int hour) hourLabelBuilder;
  final double lineOpacity;
  final double timelineScrollPadding;

  @override
  void paint(Canvas canvas, Size size) {
    if (lineOpacity <= 0 || borderedClipRects.isEmpty) return;

    canvas.save();
    canvas.clipPath(
      calendarWeekHourLineClipPath(
        borderedDayRects: borderedClipRects,
        borderRadius: borderRadius,
      ),
    );

    final linePaint = Paint()
      ..color = lineColor.withValues(alpha: lineColor.a * lineOpacity)
      ..strokeWidth = 1;

    final textStyle = AppFonts.style(
      fontSize: 10,
      color: labelColor.withValues(alpha: labelColor.a * lineOpacity),
      height: 1,
    );
    const leftLineWidth = 18.0;
    const labelGap = 4.0;
    const labelLeft = leftLineWidth + labelGap;

    for (var hour = 0; hour <= 24; hour++) {
      final y = allDayShelfHeight +
          timelineScrollPadding +
          hour * calendarWeekPxPerHour -
          scrollOffset;
      if (y < 0 || y > size.height) continue;

      final label = hourLabelBuilder(hour);
      final painter = TextPainter(
        text: TextSpan(text: label, style: textStyle),
        textDirection: TextDirection.ltr,
      )..layout();

      final labelY = y - painter.height / 2;
      final labelRight = labelLeft + painter.width;

      canvas.drawLine(Offset(0, y), Offset(leftLineWidth, y), linePaint);
      canvas.drawLine(
        Offset(labelRight + labelGap, y),
        Offset(size.width, y),
        linePaint,
      );
      painter.paint(canvas, Offset(labelLeft, labelY));
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(CalendarWeekTimeGridPainter old) =>
      old.scrollOffset != scrollOffset ||
      old.allDayShelfHeight != allDayShelfHeight ||
      old.borderedClipRects != borderedClipRects ||
      old.borderRadius != borderRadius ||
      old.lineColor != lineColor ||
      old.lineOpacity != lineOpacity ||
      old.timelineScrollPadding != timelineScrollPadding;
}
