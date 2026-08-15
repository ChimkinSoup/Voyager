import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/domain/models/todo_models.dart';

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
  });

  final String id;
  final NotificationItemType type;
  final NotificationUrgency urgency;
  final DateTime dueAt;

  final TodoTask? task;
  final CalendarEvent? event;
  final Subscription? bill;

  /// Key used by the dismissal table — tied to the current urgency tier so a
  /// dismissal only suppresses this item until it escalates to a new tier.
  String get dismissalKey => '$id|${urgency.name}';
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

/// Classifies a calendar event's urgency: important if it starts within the
/// next hour, semi-important if within the next 24 hours, otherwise not
/// shown. Events that have already ended are never shown.
NotificationUrgency? evaluateEventUrgency(CalendarEvent event, DateTime now) {
  if (event.deletedAt != null) return null;
  if (event.end.isBefore(now)) return null;
  final untilStart = event.start.difference(now);
  if (untilStart.isNegative || untilStart <= const Duration(hours: 1)) {
    return NotificationUrgency.important;
  }
  if (untilStart <= const Duration(hours: 24)) return NotificationUrgency.semi;
  return null;
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
    final urgency = evaluateEventUrgency(event, now);
    if (urgency == null) continue;
    items.add(
      NotificationFeedItem(
        id: event.id,
        type: NotificationItemType.event,
        urgency: urgency,
        dueAt: event.start,
        event: event,
      ),
    );
  }

  for (final bill in bills) {
    final urgency = evaluateBillUrgency(bill, now);
    if (urgency == null) continue;
    items.add(
      NotificationFeedItem(
        id: bill.id,
        type: NotificationItemType.bill,
        urgency: urgency,
        dueAt: bill.nextDue(now),
        bill: bill,
      ),
    );
  }

  items.sort((a, b) => a.dueAt.compareTo(b.dueAt));
  return items;
}
