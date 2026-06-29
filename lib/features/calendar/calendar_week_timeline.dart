import 'dart:ui' show lerpDouble;

import 'dart:math' show max;

import 'package:flutter/material.dart';
import 'package:voyager/core/theme/app_fonts.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/features/calendar/calendar_day_grid.dart';
import 'package:voyager/features/calendar/calendar_overlap_engine.dart';
import 'package:voyager/features/calendar/calendar_todo_markers.dart';

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
  });

  final double weekdayHeaderHeight;
  final double allDayShelfHeight;
  final double timeGutterWidth;
  final double horizontalPadding;
  final List<Rect> columnRects;
  final List<Rect> dayColumnRects;
  final double timelineTop;
  final double timelineViewportHeight;

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
    final dayColumnBottom = areaSize.height - calendarWeekDayColumnBottomInset;
    final dayColumnHeight = dayColumnBottom - dayAreaTop;
    final timelineTop = dayAreaTop + shelfHeight;
    final timelineViewportHeight = dayColumnBottom - timelineTop;
    final gridLeft = horizontalPadding;
    final gridWidth = areaSize.width - horizontalPadding * 2;
    final cellW = gridWidth / 7;
    final columnRects = List.generate(
      7,
      (i) => Rect.fromLTWH(
        gridLeft + i * cellW,
        timelineTop,
        cellW,
        timelineViewportHeight,
      ),
    );
    final dayColumnRects = List.generate(
      7,
      (i) => Rect.fromLTWH(
        gridLeft + i * cellW,
        dayAreaTop,
        cellW,
        dayColumnHeight,
      ),
    );
    return CalendarWeekLayoutMetrics(
      weekdayHeaderHeight: weekdayHeaderHeight,
      allDayShelfHeight: shelfHeight,
      timeGutterWidth: calendarWeekTimeGutterWidth,
      horizontalPadding: horizontalPadding,
      columnRects: columnRects,
      dayColumnRects: dayColumnRects,
      timelineTop: timelineTop,
      timelineViewportHeight: timelineViewportHeight,
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
    this.entryFadeEnabled = true,
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
  final bool entryFadeEnabled;

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
        final allDayShelfHeight = calendarWeekAllDayShelfHeightFor(
          events: widget.events,
          weekDays: weekDays,
        );

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.showWeekdayHeader) ...[
              const SizedBox(height: calendarWeekHeaderTopPadding),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: metrics.horizontalPadding),
                child: WeekdayHeaderRow(
                  weekStartsMonday: widget.weekStartsMonday,
                  labelStyle: weekdayStyle,
                ),
              ),
              const SizedBox(height: calendarWeekHeaderGap),
            ],
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
                    final columnTop = margin + calendarWeekDayColumnTopInset;
                    final columnBottom =
                        dayAreaSize.height - margin - calendarWeekDayColumnBottomInset;

                    final borderedDayRects = List.generate(7, (i) {
                      return Rect.fromLTRB(
                        i * cellW + margin,
                        columnTop,
                        (i + 1) * cellW - margin,
                        columnBottom,
                      );
                    });

                    // x-bounds for hit-testing within the timed area.
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

                    final timelineViewportHeight = max(
                      0.0,
                      columnBottom - columnTop - allDayShelfHeight,
                    );

                    return Stack(
                      clipBehavior: Clip.hardEdge,
                      children: [
                        // ── Pinned all-day shelf (always visible) ──
                        for (var i = 0; i < 7; i++)
                          Positioned(
                            left: borderedDayRects[i].left,
                            top: columnTop,
                            width: borderedDayRects[i].width,
                            height: allDayShelfHeight,
                            child: ClipRRect(
                              borderRadius: BorderRadius.only(
                                topLeft: Radius.circular(borderRadius),
                                topRight: Radius.circular(borderRadius),
                              ),
                              child: _AllDayShelfColumn(
                                day: weekDays[i],
                                events: widget.events,
                                onEventTap: widget.onEventTap,
                                entryFade: _entryFade,
                              ),
                            ),
                          ),

                        // ── Scrollable timed grid (12 AM – 12 AM) ──
                        Positioned(
                          left: 0,
                          top: columnTop + allDayShelfHeight,
                          right: 0,
                          height: timelineViewportHeight,
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
                                      borderRadius: borderRadius,
                                      entryFade: _entryFade,
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),

                        // ── Hour-line grid (fixed viewport overlay) ──
                        Positioned(
                          left: 0,
                          top: columnTop + allDayShelfHeight,
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
                                    borderedClipRects: borderedDayRects
                                        .map(
                                          (rect) => Rect.fromLTRB(
                                            rect.left,
                                            0,
                                            rect.right,
                                            timelineViewportHeight,
                                          ),
                                        )
                                        .toList(),
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

                        // ── Bordered day-column rectangles (fixed overlay) ──
                        Positioned.fill(
                          child: IgnorePointer(
                            child: CustomPaint(
                              painter: CalendarWeekDayColumnBorderPainter(
                                borderedRects: borderedDayRects,
                                color: divider,
                                borderRadius: borderRadius,
                              ),
                            ),
                          ),
                        ),

                        // ── All-day shelf accent line (flush below pinned events) ──
                        Positioned(
                          left: borderedDayRects.first.left,
                          width:
                              borderedDayRects.last.right -
                              borderedDayRects.first.left,
                          top: columnTop + allDayShelfHeight,
                          child: IgnorePointer(
                            child: DecoratedBox(
                              decoration: BoxDecoration(color: accentColor),
                              child: const SizedBox(height: 1),
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
    required this.events,
    required this.onEventTap,
    required this.entryFade,
  });

  final DateTime day;
  final List<CalendarEvent> events;
  final CalendarWeekEventTap onEventTap;
  final Animation<double> entryFade;

  @override
  Widget build(BuildContext context) {
    final allDay = events
        .where((e) => calendarEventOnDay(e, day) && e.isFullDay)
        .toList()
      ..sort((a, b) => a.start.compareTo(b.start));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < allDay.length; i++)
          SizedBox(
            height: calendarWeekAllDayEventRowHeight,
            child: Padding(
              padding: EdgeInsets.only(
                bottom: i < allDay.length - 1 ? 2 : 0,
              ),
              child: FadeTransition(
                opacity: entryFade,
                child: CalendarWeekEventBlock(
                  key: ValueKey('allday-${allDay[i].id}'),
                  event: allDay[i],
                  onTap: () => onEventTap(allDay[i]),
                ),
              ),
            ),
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
    required this.borderRadius,
    required this.entryFade,
  });

  final DateTime day;
  /// x-bounds of this column within the timed scroll content.
  final Rect columnRect;
  final List<CalendarEvent> events;
  final List<CalendarTodoMarker> todoMarkers;
  final CalendarWeekEventTap onEventTap;
  final CalendarWeekTodoTap onTodoTap;
  final bool interactive;
  final double borderRadius;
  final Animation<double> entryFade;

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
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            for (final slot in slots)
              Positioned(
                left: slot.left * columnRect.width,
                top: slot.top + calendarWeekTimelineScrollPadding,
                width: slot.width * columnRect.width,
                height: slot.height,
                child: IgnorePointer(
                  ignoring: !interactive,
                  child: FadeTransition(
                    opacity: entryFade,
                    child: slot.entry.isTodo
                        ? CalendarWeekTaskBar(
                            key: ValueKey('todo-${slot.entry.todo!.taskId}'),
                            marker: slot.entry.todo!,
                            onTap: () => onTodoTap(slot.entry.todo!),
                          )
                        : CalendarWeekEventBlock(
                            key: ValueKey('event-${slot.entry.event!.id}'),
                            event: slot.entry.event!,
                            onTap: () => onEventTap(slot.entry.event!),
                          ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

/// Bordered day-column shells matching month-view cell spacing.
class CalendarWeekDayColumnBorderPainter extends CustomPainter {
  const CalendarWeekDayColumnBorderPainter({
    required this.borderedRects,
    required this.color,
    required this.borderRadius,
  });

  final List<Rect> borderedRects;
  final Color color;
  final double borderRadius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

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
      old.borderedRects != borderedRects;
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
