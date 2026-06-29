import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/theme/app_fonts.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/features/calendar/calendar_day_grid.dart';

/// A calendar-visible todo task with list color resolved for rendering.
class CalendarTodoMarker {
  const CalendarTodoMarker({
    required this.taskId,
    required this.listId,
    required this.colorValue,
    required this.dueDate,
    required this.sortKey,
    this.title,
    this.hasNotes = false,
    this.completedSubtaskCount = 0,
    this.totalSubtaskCount = 0,
    this.completed = false,
  });

  final String taskId;
  final String listId;
  final int colorValue;
  final DateTime dueDate;
  final DateTime sortKey;
  final String? title;
  final bool hasNotes;
  final int completedSubtaskCount;
  final int totalSubtaskCount;
  final bool completed;
}

const calendarTodoIconSize = 12.0;

/// Horizontal offset between overlapping todo icons (newer icons shift left).
const calendarTodoIconOverlapStep = 5.0;

const calendarMaxTodoIconsPerDay = 8;

/// Fixed visual height for todo bars in the week timeline.
const calendarWeekTaskBarHeight = 18.0;

/// Week timeline scale — one hour in pixels.
const calendarWeekPxPerHour = 60.0;

/// Minimum pinned all-day shelf height in the week timeline.
const calendarWeekAllDayShelfHeight = 24.0;

/// Height of one all-day event row in the pinned shelf.
const calendarWeekAllDayEventRowHeight = 22.0;

/// Extra inset below weekday labels before bordered day columns begin.
const calendarWeekDayColumnTopInset = 6.0;

/// Inset above the panel bottom before bordered day columns end.
const calendarWeekDayColumnBottomInset = 8.0;

/// Left time-label gutter width in the week timeline.
const calendarWeekTimeGutterWidth = 52.0;

/// Horizontal inset for the week grid — matches month-view [MonthTitleHeader.cardPadding].
const calendarWeekHorizontalPadding = 8.0;

/// Gap below weekday labels in the week timeline.
const calendarWeekHeaderGap = 8.0;

/// Padding above weekday labels — sized with [calendarWeekHeaderGap] + inset for vertical balance.
const calendarWeekHeaderTopPadding = 14.0;

/// Weekday label font size in the week timeline (smaller than month view).
const calendarWeekWeekdayFontSize = 11.0;

/// Top/bottom padding inside the scrollable timeline so hour labels are not clipped.
const calendarWeekTimelineScrollPadding = 24.0;

/// Total scrollable timeline height for a 24-hour day.
const calendarWeekTimelineHeight = calendarWeekPxPerHour * 24.0;

/// Scroll content height including top/bottom label padding.
double calendarWeekTimelineScrollContentHeight() =>
    calendarWeekTimelineHeight + calendarWeekTimelineScrollPadding * 2;

/// Default scroll offset for the week timeline — 7:30 AM in the timed grid.
double calendarWeekDefaultScrollOffset() {
  return calendarWeekTimelineScrollPadding + 7.5 * calendarWeekPxPerHour;
}

/// Pinned all-day shelf height for the visible week (shows every full-day event).
double calendarWeekAllDayShelfHeightFor({
  required List<CalendarEvent> events,
  required List<DateTime> weekDays,
}) {
  var maxCount = 0;
  for (final day in weekDays) {
    final count = events
        .where((e) => calendarEventOnDay(e, day) && e.isFullDay)
        .length;
    if (count > maxCount) maxCount = count;
  }
  if (maxCount == 0) return calendarWeekAllDayShelfHeight;
  return maxCount * calendarWeekAllDayEventRowHeight;
}

/// Last attached offset, or [lastKnownOffset] when detached or multiply attached.
double calendarWeekEffectiveScrollOffset(
  ScrollController controller,
  double lastKnownOffset,
) {
  if (!controller.hasClients || controller.positions.length != 1) {
    return lastKnownOffset;
  }
  return controller.offset;
}

/// Visual progress for todo icons during year↔month morph (0 = hidden, 1 = full).
double calendarMorphTodoIconProgress({
  required bool morphReverse,
  required double styleT,
}) {
  final t = styleT.clamp(0.0, 1.0);
  if (morphReverse) {
    return Curves.easeOut.transform(t);
  }
  return Curves.easeIn.transform(t);
}

List<CalendarTodoMarker> buildCalendarTodoMarkers(
  Iterable<TodoTask> tasks,
  Map<String, int?> listColors, {
  required int fallbackColorValue,
}) {
  final taskList = tasks.toList();
  final subtasksByParent = <String, List<TodoTask>>{};
  for (final task in taskList) {
    final parentId = task.parentTaskId;
    if (parentId != null) {
      subtasksByParent.putIfAbsent(parentId, () => []).add(task);
    }
  }

  final markers = <CalendarTodoMarker>[];
  for (final task in taskList) {
    if (task.completed || task.isSubtask || task.dueDate == null) continue;
    final subs = subtasksByParent[task.id] ?? const <TodoTask>[];
    markers.add(
      CalendarTodoMarker(
        taskId: task.id,
        listId: task.listId,
        colorValue: listColors[task.listId] ?? fallbackColorValue,
        dueDate: task.dueDate!,
        sortKey: task.dueDateSetAt ?? task.createdAt,
        title: task.title,
        hasNotes: task.notes != null && task.notes!.trim().isNotEmpty,
        completedSubtaskCount: subs.where((s) => s.completed).length,
        totalSubtaskCount: subs.length,
        completed: task.completed,
      ),
    );
  }
  return markers;
}

bool calendarTodoOnDay(CalendarTodoMarker marker, DateTime day) {
  final due = marker.dueDate.toLocal();
  return due.year == day.year && due.month == day.month && due.day == day.day;
}

List<CalendarTodoMarker> calendarTodoMarkersForDay(
  Iterable<CalendarTodoMarker> markers,
  DateTime day,
) {
  return markers
      .where((marker) => calendarTodoOnDay(marker, day))
      .toList()
    ..sort((a, b) => a.dueDate.compareTo(b.dueDate));
}

/// Overlapping check-fat icons for month/week day cells (bottom-right).
class CalendarDayTodoIcons extends StatelessWidget {
  const CalendarDayTodoIcons({
    super.key,
    required this.markers,
    this.iconSize = calendarTodoIconSize,
    this.maxIcons = calendarMaxTodoIconsPerDay,
    this.overlapStep = calendarTodoIconOverlapStep,
  });

  final List<CalendarTodoMarker> markers;
  final double iconSize;
  final int maxIcons;
  final double overlapStep;

  @override
  Widget build(BuildContext context) {
    if (markers.isEmpty) return const SizedBox.shrink();

    final visible = markers.take(maxIcons).toList();
    final count = visible.length;
    final width = iconSize + (count - 1) * overlapStep;

    return SizedBox(
      width: width,
      height: iconSize,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (var i = 0; i < count; i++)
            Positioned(
              right: (count - 1 - i) * overlapStep,
              bottom: 0,
              child: Icon(
                PhosphorIconsFill.checkFat,
                size: iconSize,
                color: Color(visible[i].colorValue),
              ),
            ),
        ],
      ),
    );
  }
}

/// Thin todo row for month cells and week timeline bars.
class CalendarDayTodoBar extends StatelessWidget {
  const CalendarDayTodoBar({
    super.key,
    required this.marker,
    required this.fontSize,
    this.height,
    this.compact = false,
  });

  final CalendarTodoMarker marker;
  final double fontSize;
  final double? height;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final barHeight = height ?? (compact ? fontSize + 2 : fontSize + 4);
    final color = Color(marker.colorValue);
    return Container(
      height: barHeight,
      padding: EdgeInsets.symmetric(horizontal: compact ? 2 : 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: marker.completed ? 0.25 : 0.55),
        borderRadius: BorderRadius.circular(barHeight / 2),
        border: Border.all(
          color: color.withValues(alpha: marker.completed ? 0.5 : 0.85),
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final iconSize = fontSize.clamp(8, 14).toDouble();
          if (width < iconSize) {
            return const SizedBox.shrink();
          }

          final showText = width >= iconSize + (compact ? 4 : 8);
          final showMeta =
              !compact && width >= iconSize + 48;

          return Row(
            children: [
              Icon(
                PhosphorIconsFill.checkFat,
                size: iconSize,
                color: color,
              ),
              if (showText) ...[
                SizedBox(width: compact ? 2 : 4),
                Expanded(
                  child: Text(
                    marker.title ?? 'Task',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppFonts.style(
                      fontSize: fontSize,
                      height: 1,
                      decoration:
                          marker.completed ? TextDecoration.lineThrough : null,
                    ),
                  ),
                ),
              ],
              if (showMeta && marker.hasNotes) ...[
                const SizedBox(width: 4),
                Icon(
                  PhosphorIconsFill.note,
                  size: fontSize.clamp(8, 12),
                  color: color,
                ),
              ],
              if (showMeta && marker.totalSubtaskCount > 0) ...[
                const SizedBox(width: 4),
                Text(
                  '${marker.completedSubtaskCount} | ${marker.totalSubtaskCount}',
                  style: AppFonts.style(fontSize: fontSize - 1, height: 1),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// Day-view row for a single due todo.
class CalendarDayTodoTile extends StatelessWidget {
  const CalendarDayTodoTile({super.key, required this.marker});

  final CalendarTodoMarker marker;

  @override
  Widget build(BuildContext context) {
    return CalendarDayTodoBar(
      marker: marker,
      fontSize: 12,
      compact: true,
    );
  }
}

/// Week-timeline task bar with metadata.
class CalendarWeekTaskBar extends StatelessWidget {
  const CalendarWeekTaskBar({
    super.key,
    required this.marker,
    required this.onTap,
  });

  final CalendarTodoMarker marker;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = Color(marker.colorValue);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final height = constraints.maxHeight;
            final decoration = BoxDecoration(
              color: color.withValues(alpha: marker.completed ? 0.25 : 0.58),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: color.withValues(alpha: 0.85)),
            );

            if (width < 18) {
              return DecoratedBox(
                decoration: decoration,
                child: const SizedBox.expand(),
              );
            }

            final compact = width < 40 || height < 22;
            final showMeta = width >= 72 && height >= 22;
            final hPad = compact ? 2.0 : 4.0;
            final iconSize = compact ? 8.0 : 10.0;
            final gap = compact ? 2.0 : 4.0;
            final showText = width >= iconSize + gap + 8;

            return Container(
              padding: EdgeInsets.symmetric(horizontal: hPad),
              decoration: decoration,
              child: Row(
                children: [
                  Icon(
                    PhosphorIconsFill.checkFat,
                    size: iconSize,
                    color: color,
                  ),
                  if (showText) ...[
                    SizedBox(width: gap),
                    Expanded(
                      child: Text(
                        marker.title ?? 'Task',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppFonts.style(
                          fontSize: compact ? 9 : 10,
                          fontWeight: FontWeight.w500,
                          height: 1.0,
                          decoration: marker.completed
                              ? TextDecoration.lineThrough
                              : null,
                        ),
                      ),
                    ),
                  ],
                  if (showMeta && marker.hasNotes) ...[
                    const SizedBox(width: 4),
                    Icon(
                      PhosphorIconsFill.note,
                      size: 11,
                      color: color,
                    ),
                  ],
                  if (showMeta && marker.totalSubtaskCount > 0) ...[
                    const SizedBox(width: 4),
                    Text(
                      '${marker.completedSubtaskCount} | ${marker.totalSubtaskCount}',
                      style: AppFonts.style(fontSize: 10, height: 1),
                    ),
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Week-timeline event block.
class CalendarWeekEventBlock extends StatelessWidget {
  const CalendarWeekEventBlock({
    super.key,
    required this.event,
    required this.onTap,
  });

  final CalendarEvent event;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = Color(event.colorValue);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final showText = constraints.maxWidth >= 12;
            return Container(
              padding: EdgeInsets.symmetric(
                horizontal: constraints.maxWidth < 24 ? 2 : 6,
                vertical: 4,
              ),
              decoration: calendarEventFillDecoration(
                color,
                alpha: calendarEventBarFillAlpha,
                borderRadius: BorderRadius.circular(6),
              ),
              child: showText
                  ? Text(
                      event.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppFonts.style(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        height: 1.1,
                      ),
                    )
                  : const SizedBox.shrink(),
            );
          },
        ),
      ),
    );
  }
}
