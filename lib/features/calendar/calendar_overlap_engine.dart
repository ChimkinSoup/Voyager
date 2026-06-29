import 'dart:math' show max;

import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/features/calendar/calendar_day_entries.dart';
import 'package:voyager/features/calendar/calendar_day_grid.dart';
import 'package:voyager/features/calendar/calendar_todo_markers.dart';

/// Layout slot for one item inside a day column (fractions are 0–1 of column width).
class CalendarOverlapSlot {
  const CalendarOverlapSlot({
    required this.left,
    required this.width,
    required this.top,
    required this.height,
    required this.entry,
  });

  final double left;
  final double width;
  final double top;
  final double height;
  final CalendarDayEntry entry;
}

class _OverlapItem {
  _OverlapItem({
    required this.entry,
    required this.startMinutes,
    required this.endMinutes,
    required this.index,
  });

  final CalendarDayEntry entry;
  final double startMinutes;
  final double endMinutes;
  final int index;

  int column = 0;
  int clusterColumns = 1;
}

double _minutesFromMidnight(DateTime time) =>
    time.hour * 60.0 + time.minute + time.second / 60.0;

double _eventEndMinutes(CalendarEvent event, DateTime day) {
  final localStart = event.start.toLocal();
  final localEnd = event.end.toLocal();
  final dayStart = DateTime(day.year, day.month, day.day);
  final dayEnd = dayStart.add(const Duration(days: 1));

  final effectiveStart = localStart.isBefore(dayStart) ? dayStart : localStart;
  final effectiveEnd = localEnd.isAfter(dayEnd) ? dayEnd : localEnd;
  if (!effectiveEnd.isAfter(effectiveStart)) {
    return _minutesFromMidnight(effectiveStart) + 30;
  }
  return _minutesFromMidnight(effectiveEnd);
}

List<_OverlapItem> _overlapItemsForDay({
  required DateTime day,
  required List<CalendarEvent> events,
  required List<CalendarTodoMarker> todos,
  required double pxPerHour,
  required double taskBarHeight,
}) {
  final taskMinutes = taskBarHeight / pxPerHour * 60.0;
  final items = <_OverlapItem>[];
  var index = 0;

  for (final event in events) {
    if (!calendarEventOnDay(event, day) || event.isFullDay) continue;
    final start = event.start.toLocal();
    items.add(
      _OverlapItem(
        entry: CalendarDayEntry.timedEvent(event),
        startMinutes: _minutesFromMidnight(start),
        endMinutes: _eventEndMinutes(event, day),
        index: index++,
      ),
    );
  }

  for (final marker in todos) {
    if (!calendarTodoOnDay(marker, day)) continue;
    final start = marker.dueDate.toLocal();
    final startMinutes = _minutesFromMidnight(start);
    items.add(
      _OverlapItem(
        entry: CalendarDayEntry.todo(marker),
        startMinutes: startMinutes,
        endMinutes: startMinutes + taskMinutes,
        index: index++,
      ),
    );
  }

  items.sort((a, b) {
    final byStart = a.startMinutes.compareTo(b.startMinutes);
    if (byStart != 0) return byStart;
    return a.index.compareTo(b.index);
  });

  return items;
}

bool _itemsOverlap(_OverlapItem a, _OverlapItem b) =>
    a.startMinutes < b.endMinutes && b.startMinutes < a.endMinutes;

List<List<_OverlapItem>> _buildClusters(List<_OverlapItem> items) {
  final clusters = <List<_OverlapItem>>[];
  final assigned = List<bool>.filled(items.length, false);

  for (var i = 0; i < items.length; i++) {
    if (assigned[i]) continue;
    final cluster = <_OverlapItem>[items[i]];
    assigned[i] = true;
    var expanded = true;
    while (expanded) {
      expanded = false;
      for (var j = 0; j < items.length; j++) {
        if (assigned[j]) continue;
        final overlapsCluster = cluster.any((c) => _itemsOverlap(c, items[j]));
        if (overlapsCluster) {
          cluster.add(items[j]);
          assigned[j] = true;
          expanded = true;
        }
      }
    }
    clusters.add(cluster);
  }

  return clusters;
}

void _layoutCluster(List<_OverlapItem> cluster) {
  cluster.sort((a, b) {
    final byStart = a.startMinutes.compareTo(b.startMinutes);
    if (byStart != 0) return byStart;
    return a.index.compareTo(b.index);
  });

  final columnEnds = <double>[];
  var maxColumns = 0;

  for (final item in cluster) {
    var assigned = -1;
    for (var col = 0; col < columnEnds.length; col++) {
      if (columnEnds[col] <= item.startMinutes) {
        assigned = col;
        break;
      }
    }
    if (assigned == -1) {
      assigned = columnEnds.length;
      columnEnds.add(item.endMinutes);
    } else {
      columnEnds[assigned] = item.endMinutes;
    }
    item.column = assigned;
    maxColumns = max(maxColumns, assigned + 1);
  }

  for (final item in cluster) {
    item.clusterColumns = max(1, maxColumns);
  }
}

/// Assigns side-by-side columns for overlapping timed events and tasks.
List<CalendarOverlapSlot> layoutDayColumn({
  required DateTime day,
  required List<CalendarEvent> events,
  required List<CalendarTodoMarker> todos,
  required double pxPerHour,
  required double taskBarHeight,
}) {
  final items = _overlapItemsForDay(
    day: day,
    events: events,
    todos: todos,
    pxPerHour: pxPerHour,
    taskBarHeight: taskBarHeight,
  );
  if (items.isEmpty) return const [];

  for (final cluster in _buildClusters(items)) {
    _layoutCluster(cluster);
  }

  return [
    for (final item in items)
      CalendarOverlapSlot(
        left: item.column / item.clusterColumns,
        width: 1 / item.clusterColumns,
        top: item.startMinutes / 60.0 * pxPerHour,
        height: item.entry.isTodo
            ? taskBarHeight
            : max(
                taskBarHeight,
                (item.endMinutes - item.startMinutes) / 60.0 * pxPerHour,
              ),
        entry: item.entry,
      ),
  ];
}
