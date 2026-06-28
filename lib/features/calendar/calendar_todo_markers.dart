import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/domain/models/todo_models.dart';

/// A calendar-visible todo task with list color resolved for rendering.
class CalendarTodoMarker {
  const CalendarTodoMarker({
    required this.taskId,
    required this.listId,
    required this.colorValue,
    required this.dueDate,
    required this.sortKey,
    this.title,
  });

  final String taskId;
  final String listId;
  final int colorValue;
  final DateTime dueDate;
  final DateTime sortKey;
  final String? title;
}

const calendarTodoIconSize = 12.0;

/// Horizontal offset between overlapping todo icons (newer icons shift left).
const calendarTodoIconOverlapStep = 5.0;

const calendarMaxTodoIconsPerDay = 8;

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
  final markers = <CalendarTodoMarker>[];
  for (final task in tasks) {
    if (task.completed || task.isSubtask || task.dueDate == null) continue;
    markers.add(
      CalendarTodoMarker(
        taskId: task.id,
        listId: task.listId,
        colorValue:
            listColors[task.listId] ?? fallbackColorValue,
        dueDate: task.dueDate!,
        sortKey: task.dueDateSetAt ?? task.createdAt,
        title: task.title,
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
    ..sort((a, b) => a.sortKey.compareTo(b.sortKey));
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

/// Day-view row for a single due todo.
class CalendarDayTodoTile extends StatelessWidget {
  const CalendarDayTodoTile({super.key, required this.marker});

  final CalendarTodoMarker marker;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          Icon(
            PhosphorIconsFill.checkFat,
            size: calendarTodoIconSize,
            color: Color(marker.colorValue),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              marker.title ?? 'Task',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
