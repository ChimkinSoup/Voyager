import 'package:voyager/core/utils/calendar_days.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/domain/models/recurrence_rule.dart';
import 'package:voyager/domain/models/soft_deletable.dart';

class TodoListModel extends SoftDeletable {
  const TodoListModel({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.version,
    super.deletedAt,
    required this.name,
    this.colorValue,
    this.includeInAllView = true,
  });

  final String name;
  final int? colorValue;

  /// Whether this list's tasks appear in the combined "All tasks" list.
  /// Opting out hides them from that view only; the tasks stay in search,
  /// the calendar's due-date markers and their own list.
  final bool includeInAllView;

  TodoListModel copyWith({
    String? name,
    int? colorValue,
    bool? includeInAllView,
    DateTime? deletedAt,
    bool bumpVersion = true,
  }) {
    return TodoListModel(
      id: id,
      createdAt: createdAt,
      updatedAt: DateTime.now().toUtc(),
      version: bumpVersion ? version + 1 : version,
      deletedAt: deletedAt ?? this.deletedAt,
      name: name ?? this.name,
      colorValue: colorValue ?? this.colorValue,
      includeInAllView: includeInAllView ?? this.includeInAllView,
    );
  }
}

class TodoTask extends SoftDeletable {
  const TodoTask({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.version,
    super.deletedAt,
    required this.listId,
    required this.title,
    this.notes,
    this.dueDate,
    this.dueHasTime = false,
    this.completed = false,
    this.completedAt,
    this.completedUtcOffsetMinutes,
    this.starred = false,
    this.sortOrder = 0,
    this.dueDateSetAt,
    this.parentTaskId,
    this.recurrence = RecurrenceRule.none,
    this.recurrenceAnchor,
  });

  final String listId;
  final String title;
  final String? notes;
  final DateTime? dueDate;

  /// Whether [dueDate] carries a time of day. Without one it names the day
  /// alone, stored as that day's local midnight; with one, midnight is a real
  /// 12:00 AM.
  final bool dueHasTime;
  final bool completed;

  /// When [completed] last went true; null while the task is open, and on
  /// tasks completed before the field existed. A repeating task never holds
  /// one — its ticks are [TodoTaskCompletion] rows.
  final DateTime? completedAt;

  /// The ticking device's UTC offset at [completedAt], so the day it was
  /// done in can be read where it was done (`recordedWallClock`). Null with
  /// [completedAt], and on ticks from before it was kept.
  final int? completedUtcOffsetMinutes;
  final bool starred;
  final int sortOrder;
  final DateTime? dueDateSetAt;
  final String? parentTaskId;

  /// How this task repeats. [dueDate] is the anchor: ticking off a repeating
  /// task advances the due date to the next occurrence instead of completing
  /// it, so the task stays live and there is only ever one row per series.
  final RecurrenceRule recurrence;

  /// The due date [recurrence] is measured from, frozen when the repeat was
  /// set. Null on tasks that predate the field; callers fall back to [dueDate].
  final DateTime? recurrenceAnchor;

  /// The date the pattern counts from.
  DateTime? get effectiveRecurrenceAnchor => recurrenceAnchor ?? dueDate;

  bool get repeats => recurrence.repeats && dueDate != null;

  bool get isSubtask => parentTaskId != null;

  TodoTask copyWith({
    DateTime? updatedAt,
    String? listId,
    String? title,
    String? notes,
    DateTime? dueDate,
    bool? dueHasTime,
    bool clearDueDate = false,
    bool clearNotes = false,
    bool? completed,
    DateTime? completedAt,
    int? completedUtcOffsetMinutes,
    bool? starred,
    int? sortOrder,
    DateTime? dueDateSetAt,
    bool clearDueDateSetAt = false,
    String? parentTaskId,
    bool clearParentTaskId = false,
    RecurrenceRule? recurrence,
    DateTime? recurrenceAnchor,
    bool clearRecurrenceAnchor = false,
    DateTime? deletedAt,
    int? version,
    bool bumpVersion = true,
  }) {
    return TodoTask(
      id: id,
      createdAt: createdAt,
      updatedAt: updatedAt ?? DateTime.now().toUtc(),
      version: version ?? (bumpVersion ? this.version + 1 : this.version),
      deletedAt: deletedAt ?? this.deletedAt,
      listId: listId ?? this.listId,
      title: title ?? this.title,
      notes: clearNotes ? null : (notes ?? this.notes),
      dueDate: clearDueDate ? null : (dueDate ?? this.dueDate),
      dueHasTime: clearDueDate ? false : (dueHasTime ?? this.dueHasTime),
      completed: completed ?? this.completed,
      // Follows [completed]: stamped when it turns true, cleared when it turns
      // false, and left alone otherwise — so every path that ticks a task
      // records the moment without having to remember to. A stamp passed in
      // is used in place of now, for a tick recorded earlier than it's applied.
      completedAt: completed == null || completed == this.completed
          ? this.completedAt
          : (completed ? completedAt ?? DateTime.now().toUtc() : null),
      completedUtcOffsetMinutes:
          completed == null || completed == this.completed
          ? this.completedUtcOffsetMinutes
          : (completed
                ? completedUtcOffsetMinutes ??
                      DateTime.now().timeZoneOffset.inMinutes
                : null),
      starred: starred ?? this.starred,
      sortOrder: sortOrder ?? this.sortOrder,
      dueDateSetAt: clearDueDateSetAt
          ? null
          : (dueDateSetAt ?? this.dueDateSetAt),
      parentTaskId: clearParentTaskId
          ? null
          : (parentTaskId ?? this.parentTaskId),
      recurrence: recurrence ?? this.recurrence,
      recurrenceAnchor: clearRecurrenceAnchor
          ? null
          : (recurrenceAnchor ?? this.recurrenceAnchor),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'version': version,
    'deletedAt': deletedAt?.toUtc().toIso8601String(),
    'listId': listId,
    'title': title,
    'notes': notes,
    'dueDate': dueDate?.toUtc().toIso8601String(),
    'dueHasTime': dueHasTime,
    'completed': completed,
    'completedAt': completedAt?.toUtc().toIso8601String(),
    'completedUtcOffsetMinutes': completedUtcOffsetMinutes,
    'starred': starred,
    'sortOrder': sortOrder,
    'dueDateSetAt': dueDateSetAt?.toUtc().toIso8601String(),
    'parentTaskId': parentTaskId,
    'recurrence': recurrence.toStorage(),
    'recurrenceAnchor': recurrenceAnchor?.toUtc().toIso8601String(),
  };

  factory TodoTask.fromJson(Map<String, dynamic> json) {
    final dueDate = json['dueDate'] != null
        ? DateTime.parse(json['dueDate'] as String).toUtc()
        : null;
    return TodoTask(
      id: json['id'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String).toUtc(),
      updatedAt: DateTime.parse(json['updatedAt'] as String).toUtc(),
      version: json['version'] as int? ?? 0,
      deletedAt: json['deletedAt'] != null
          ? DateTime.parse(json['deletedAt'] as String).toUtc()
          : null,
      listId: json['listId'] as String,
      title: json['title'] as String,
      notes: json['notes'] as String?,
      dueDate: dueDate,
      dueHasTime: json['dueHasTime'] as bool? ?? legacyDueHasTime(dueDate),
      completed: json['completed'] as bool? ?? false,
      completedAt: json['completedAt'] != null
          ? DateTime.parse(json['completedAt'] as String).toUtc()
          : null,
      completedUtcOffsetMinutes: json['completedUtcOffsetMinutes'] as int?,
      starred: json['starred'] as bool? ?? false,
      sortOrder: json['sortOrder'] as int? ?? 0,
      dueDateSetAt: json['dueDateSetAt'] != null
          ? DateTime.parse(json['dueDateSetAt'] as String).toUtc()
          : null,
      parentTaskId: json['parentTaskId'] as String?,
      recurrence: RecurrenceRule.parse(json['recurrence'] as String?),
      recurrenceAnchor: json['recurrenceAnchor'] != null
          ? DateTime.parse(json['recurrenceAnchor'] as String).toUtc()
          : null,
    );
  }
}

/// Whether a due date written before [TodoTask.dueHasTime] existed carries a
/// time. Those writers stored a date alone as local midnight, so midnight
/// reads as no time.
bool legacyDueHasTime(DateTime? due) {
  final local = due?.toLocal();
  return local != null && (local.hour != 0 || local.minute != 0);
}

/// A task's [TodoTask.dueDate] or [TodoTask.recurrenceAnchor] in the form it
/// is stored and synced in: a date-only due day as UTC midnight (see
/// [storedCalendarDay]), a timed one as the instant it is.
DateTime? taskDateForStorage(DateTime? value, {required bool hasTime}) =>
    value == null || hasTime ? value : storedCalendarDay(value);

/// The reverse of [taskDateForStorage]: a date-only due day back at local
/// midnight, so it names the same day in every zone.
DateTime? taskDateFromStorage(DateTime? value, {required bool hasTime}) =>
    value == null || hasTime ? value : calendarDayOf(value);

/// The id of [taskId]'s completion against [dueDate]: one row per occurrence.
///
/// Derived rather than random so every device addresses the same row. Two
/// devices ticking the same task offline write one row, not two, and an
/// un-tick can tombstone the row before the tick itself has synced in.
///
/// Keyed on the due date's stored form ([taskDateForStorage]): a day alone as
/// UTC midnight, the same instant in every zone. Its local midnight is a
/// different instant in each one, which gave one occurrence a different id
/// on every device.
String todoTaskCompletionId(
  String taskId,
  DateTime? dueDate, {
  required bool dueHasTime,
}) {
  final key = taskDateForStorage(dueDate, hasTime: dueHasTime);
  return '${taskId}_${key?.microsecondsSinceEpoch ?? 'undated'}';
}

/// The id builds before UTC-midnight due days gave the occurrence on
/// [dueDate]: keyed on this device's local midnight for a day alone. Looked up
/// as well, so a tick logged before the change is still found.
String legacyTodoTaskCompletionId(String taskId, DateTime? dueDate) =>
    '${taskId}_${dueDate?.microsecondsSinceEpoch ?? 'undated'}';

/// One tick of a task's checkbox — the history [TodoTask.completedAt] can't
/// hold, since a repeating task moves on to its next occurrence instead of
/// staying completed.
///
/// One row per occurrence (see [todoTaskCompletionId]). Un-ticking
/// soft-deletes the row, so a tick taken back stops being counted, and
/// ticking the same occurrence again brings it back with a new
/// [completedAt]. [version] is what carries both across devices — conflict
/// resolution is version-first, and each write goes one version above the
/// row it replaces.
class TodoTaskCompletion {
  const TodoTaskCompletion({
    required this.id,
    required this.taskId,
    required this.completedAt,
    this.utcOffsetMinutes,
    this.dueDate,
    this.version = 0,
    this.deletedAt,
  });

  final String id;
  final String taskId;

  /// UTC. Equal to the task's [TodoTask.completedAt] for a one-off, which is
  /// how an un-tick finds the row after the task's due date has changed.
  final DateTime completedAt;

  /// The ticking device's UTC offset at [completedAt]; null on ticks from
  /// before it was kept. See [TodoTask.completedUtcOffsetMinutes].
  final int? utcOffsetMinutes;

  /// The due date the tick was against — for a repeating task, the occurrence
  /// that was done, which its row forgets as soon as it rolls forward.
  final DateTime? dueDate;
  final int version;
  final DateTime? deletedAt;

  /// The tombstone for this row, one version above it.
  TodoTaskCompletion deleted() => TodoTaskCompletion(
    id: id,
    taskId: taskId,
    completedAt: completedAt,
    utcOffsetMinutes: utcOffsetMinutes,
    dueDate: dueDate,
    version: version + 1,
    deletedAt: utcNow(),
  );
}
