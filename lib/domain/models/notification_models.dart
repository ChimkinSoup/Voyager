import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/domain/services/calendar_recurrence.dart';

/// How urgently a notification feed item should be surfaced. Drives both the
/// nav-rail bell's dot color/animation and the feed's sort order.
enum NotificationUrgency { semi, important }

enum NotificationItemType { task, event, bill }

/// A single row in the unified notification feed, derived from a real task,
/// event, or bill rather than being its own persisted record. [id] is the
/// source object's id (used as the dismissal key alongside [urgency]).
class NotificationFeedItem {
  const NotificationFeedItem({
    required this.id,
    required this.type,
    required this.urgency,
    required this.dueAt,
    this.task,
    this.event,
    this.bill,
    this.occurrenceDate,
  });

  final String id;
  final NotificationItemType type;
  final NotificationUrgency urgency;
  final DateTime dueAt;

  final TodoTask? task;
  final CalendarEvent? event;
  final Subscription? bill;

  /// For something that happens more than once — an occurrence of a repeating
  /// event, a month's instance of a bill — the local date-only day this row
  /// stands for. Null when [id] already names a single dated thing.
  ///
  /// [event] and [bill] stay the *stored* row, times and all: the row's menu
  /// writes through them, so handing it an occurrence-shifted copy would move
  /// the series anchor onto today the first time someone recoloured it.
  final DateTime? occurrenceDate;

  /// Key used by the dismissal table — tied to the current urgency tier so a
  /// dismissal only suppresses this item until it escalates to a new tier,
  /// and to [occurrenceDate] so dismissing tonight's occurrence of a repeating
  /// event does not bury every future one behind the same key.
  String get dismissalKey {
    final occurrence = occurrenceDate;
    if (occurrence == null) return '$id|${urgency.name}';
    return '$id@${_dayKey(occurrence)}|${urgency.name}';
  }
}

/// A short freeform quick-capture reminder shown in the notification
/// popover's "Pinned Canvas" section.
class PinnedNote {
  const PinnedNote({
    required this.id,
    required this.text,
    required this.createdAt,
    required this.updatedAt,
    this.version = 0,
    this.deletedAt,
  });

  final String id;
  final String text;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int version;

  /// Set when the note is unpinned. Kept as a tombstone rather than deleted so
  /// the unpin reaches the user's other devices.
  final DateTime? deletedAt;

  PinnedNote copyWith({
    String? text,
    DateTime? updatedAt,
    int? version,
    DateTime? deletedAt,
    bool clearDeletedAt = false,
  }) {
    return PinnedNote(
      id: id,
      text: text ?? this.text,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      version: version ?? this.version,
      deletedAt: clearDeletedAt ? null : (deletedAt ?? this.deletedAt),
    );
  }
}

/// A feed item the user dismissed, keyed by [NotificationFeedItem.dismissalKey].
///
/// Un-dismissing sets [deletedAt] instead of dropping the row: a pull only ever
/// sees the documents that exist, so a hard delete would leave the item
/// dismissed forever on every other device.
class DismissedNotification {
  const DismissedNotification({
    required this.key,
    required this.dismissedAt,
    required this.updatedAt,
    this.version = 0,
    this.deletedAt,
  });

  final String key;
  final DateTime dismissedAt;
  final DateTime updatedAt;
  final int version;
  final DateTime? deletedAt;

  bool get isDismissed => deletedAt == null;
}

/// `yyyy-MM-dd` for a local date, the occurrence half of a [dismissalKey].
String _dayKey(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

/// Classifies a task's urgency, or null if it shouldn't appear in the feed.
/// Overdue or due-today tasks are important; due-tomorrow tasks are
/// semi-important; anything further out (or with no due date) isn't shown.
NotificationUrgency? evaluateTaskUrgency(TodoTask task, DateTime now) {
  if (task.completed || task.deletedAt != null) return null;
  final dueDate = task.dueDate;
  if (dueDate == null) return null;
  final today = DateTime(now.year, now.month, now.day);
  final due = DateTime(dueDate.year, dueDate.month, dueDate.day);
  final daysUntil = due.difference(today).inDays;
  if (daysUntil <= 0) return NotificationUrgency.important;
  if (daysUntil == 1) return NotificationUrgency.semi;
  return null;
}

/// The occurrence of [event] the feed should judge: the one running now, or
/// the next one due. Null once the event is deleted or has no occurrence left.
///
/// A repeating event is never judged on its own [CalendarEvent.start] — that
/// is the anchor, which for any series that has been running a while sits in
/// the past, and reading it directly is what used to keep every repeating
/// event out of the feed entirely.
({DateTime start, DateTime end})? notifiableEventOccurrence(
  CalendarEvent event,
  DateTime now,
) {
  if (event.deletedAt != null) return null;
  return nextCalendarOccurrence(event, now);
}

/// Classifies an occurrence starting at [start]: important if it starts within
/// the next hour (or is already under way), semi-important if within the next
/// 24 hours, otherwise not shown.
NotificationUrgency? _urgencyForStart(DateTime start, DateTime now) {
  final untilStart = start.difference(now);
  if (untilStart.isNegative || untilStart <= const Duration(hours: 1)) {
    return NotificationUrgency.important;
  }
  if (untilStart <= const Duration(hours: 24)) return NotificationUrgency.semi;
  return null;
}

/// Classifies a calendar event's urgency from its current-or-next occurrence.
/// Occurrences that have already ended are never shown.
NotificationUrgency? evaluateEventUrgency(CalendarEvent event, DateTime now) {
  final occurrence = notifiableEventOccurrence(event, now);
  if (occurrence == null) return null;
  return _urgencyForStart(occurrence.start, now);
}

/// Classifies a subscription/bill's urgency: important if due today or
/// overdue, semi-important if due within the next 3 days, otherwise not
/// shown.
NotificationUrgency? evaluateBillUrgency(Subscription bill, DateTime now) {
  if (bill.deletedAt != null) return null;
  final days = bill.daysUntilDue(now);
  if (days <= 0) return NotificationUrgency.important;
  if (days <= 3) return NotificationUrgency.semi;
  return null;
}

/// Folds tasks/events/bills into a single feed sorted by soonest-due,
/// mixing item types together rather than grouping by category.
List<NotificationFeedItem> buildNotificationFeed({
  required List<TodoTask> tasks,
  required List<CalendarEvent> events,
  required List<Subscription> bills,
  required DateTime now,
}) {
  final items = <NotificationFeedItem>[];

  for (final task in tasks) {
    final urgency = evaluateTaskUrgency(task, now);
    if (urgency == null) continue;
    items.add(
      NotificationFeedItem(
        id: task.id,
        type: NotificationItemType.task,
        urgency: urgency,
        dueAt: task.dueDate!,
        task: task,
      ),
    );
  }

  for (final event in events) {
    final occurrence = notifiableEventOccurrence(event, now);
    if (occurrence == null) continue;
    final urgency = _urgencyForStart(occurrence.start, now);
    if (urgency == null) continue;
    final start = occurrence.start;
    items.add(
      NotificationFeedItem(
        id: event.id,
        type: NotificationItemType.event,
        urgency: urgency,
        dueAt: start,
        event: event,
        occurrenceDate: event.recurrence.repeats
            ? DateTime(start.year, start.month, start.day)
            : null,
      ),
    );
  }

  for (final bill in bills) {
    final urgency = evaluateBillUrgency(bill, now);
    if (urgency == null) continue;
    final due = bill.nextDue(now);
    items.add(
      NotificationFeedItem(
        id: bill.id,
        type: NotificationItemType.bill,
        urgency: urgency,
        dueAt: due,
        bill: bill,
        // A subscription bills again every period, so its dismissal has to be
        // scoped to the instalment the way a repeating event's is.
        occurrenceDate: DateTime(due.year, due.month, due.day),
      ),
    );
  }

  items.sort((a, b) => a.dueAt.compareTo(b.dueAt));
  return items;
}
