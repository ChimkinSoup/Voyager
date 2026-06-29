import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/features/calendar/calendar_day_grid.dart';
import 'package:voyager/features/calendar/calendar_todo_markers.dart';

/// A single chronological row in a month day cell or week timeline column.
enum CalendarDayEntryKind { allDayEvent, timedEvent, todo }

class CalendarDayEntry {
  const CalendarDayEntry._({
    required this.kind,
    this.event,
    this.todo,
    required this.sortTime,
  });

  factory CalendarDayEntry.allDayEvent(CalendarEvent event) {
    return CalendarDayEntry._(
      kind: CalendarDayEntryKind.allDayEvent,
      event: event,
      sortTime: event.start.toLocal(),
    );
  }

  factory CalendarDayEntry.timedEvent(CalendarEvent event) {
    return CalendarDayEntry._(
      kind: CalendarDayEntryKind.timedEvent,
      event: event,
      sortTime: event.start.toLocal(),
    );
  }

  factory CalendarDayEntry.todo(CalendarTodoMarker marker) {
    return CalendarDayEntry._(
      kind: CalendarDayEntryKind.todo,
      todo: marker,
      sortTime: marker.dueDate.toLocal(),
    );
  }

  final CalendarDayEntryKind kind;
  final CalendarEvent? event;
  final CalendarTodoMarker? todo;
  final DateTime sortTime;

  bool get isAllDay => kind == CalendarDayEntryKind.allDayEvent;
  bool get isTodo => kind == CalendarDayEntryKind.todo;
  bool get isTimed => kind == CalendarDayEntryKind.timedEvent;

  String get title {
    if (event != null) return event!.title;
    return todo?.title ?? 'Task';
  }

  int get colorValue {
    if (event != null) return event!.colorValue;
    return todo!.colorValue;
  }
}

/// Builds a single chronological stack for [day]: all-day events first, then
/// timed events and todos sorted by start/due time.
List<CalendarDayEntry> calendarDayEntriesForDay({
  required Iterable<CalendarEvent> events,
  required Iterable<CalendarTodoMarker> todos,
  required DateTime day,
}) {
  final allDay = <CalendarDayEntry>[];
  final timed = <CalendarDayEntry>[];

  for (final event in events) {
    if (!calendarEventOnDay(event, day)) continue;
    if (event.isFullDay) {
      allDay.add(CalendarDayEntry.allDayEvent(event));
    } else {
      timed.add(CalendarDayEntry.timedEvent(event));
    }
  }

  for (final marker in todos) {
    if (!calendarTodoOnDay(marker, day)) continue;
    timed.add(CalendarDayEntry.todo(marker));
  }

  allDay.sort((a, b) => a.sortTime.compareTo(b.sortTime));
  timed.sort((a, b) => a.sortTime.compareTo(b.sortTime));

  return [...allDay, ...timed];
}

/// How many unified entries fit in a full-layout month day cell.
int calendarVisibleEntryCount({
  required double cellHeight,
  required MonthDayCellStyle style,
  required int entryCount,
  required bool hasIndicators,
}) {
  if (entryCount == 0 || style.maxEventLines <= 0) return 0;

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
  return fit.clamp(0, style.maxEventLines).clamp(0, entryCount);
}
