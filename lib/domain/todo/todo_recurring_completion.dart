import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/domain/services/recurrence_engine.dart';
import 'package:voyager/domain/todo/todo_task_sorting.dart';

/// What ticking a task's checkbox actually did.
///
/// A repeating task is never *finished* by a completion: it moves on to its
/// next occurrence and stays live. Callers that animate a row out of an active
/// list need to know which of the two happened, and every caller needs the
/// lists to invalidate.
class TodoCompletionOutcome {
  const TodoCompletionOutcome({
    required this.rolledForward,
    required this.listId,
    required this.writes,
  });

  /// True when the task repeats and now carries its next due date, false when
  /// it was written as plainly completed.
  final bool rolledForward;

  /// The list the task ended up in — its own; nothing here moves a task.
  final String listId;

  /// Every row written, the task included. A roll-forward rewrites its
  /// siblings' sort orders too.
  final List<TodoTask> writes;
}

/// Completes [taskId], rolling a repeating task forward instead.
///
/// The one place the app decides what "tick a repeating task" means, so the
/// To-Do list, the calendar's task panel and the notification inbox cannot
/// drift apart: a repeat that is ticked anywhere comes back at its next due
/// date rather than dropping into the completed section for good.
///
/// The task is re-read from [repo] rather than taken from the caller's copy:
/// the row may have been renamed, rescheduled or had its repeat cleared while
/// a completion animation played, and all three change what should be written.
///
/// A repeat with no due date, no anchor or no further occurrence is honoured as
/// the plain completion the user actually saw — returning without writing
/// would strand a row that is already showing its check.
Future<TodoCompletionOutcome?> completeTodoTask({
  required TodoRepository repo,
  required RemoteSyncService sync,
  required String taskId,
  DateTime? now,
}) async {
  final latest = await repo.getTask(taskId);
  if (latest == null) return null;

  Future<TodoCompletionOutcome> plainlyCompleted() async {
    final completed = latest.copyWith(completed: true);
    await repo.upsertTask(completed);
    // Background, not awaited: the row is on disk, and a push that throws
    // here aborted the caller after the write — leaving the To-Do page's
    // optimistic check stuck and the calendar's roll-forward never run.
    sync.pushTodoTaskInBackground(completed);
    await recordTodoCompletionChange(
      repo: repo,
      sync: sync,
      before: latest,
      after: completed,
    );
    return TodoCompletionOutcome(
      rolledForward: false,
      listId: completed.listId,
      writes: [completed],
    );
  }

  final due = latest.dueDate;
  final anchor = latest.effectiveRecurrenceAnchor;
  if (due == null || anchor == null || !latest.recurrence.repeats) {
    return plainlyCompleted();
  }

  final next = nextTaskDueDate(
    dueDate: due,
    anchor: anchor,
    rule: latest.recurrence,
    now: now ?? DateTime.now(),
  );
  if (next == null) return plainlyCompleted();

  // Through the same placement path every other due-date change uses. Writing
  // dueDate alone leaves sortOrder at the value the task held for its *old*
  // date, so a task that just moved from today to next month still renders at
  // the top of its list's dated run.
  final siblings = await repo.listTasks(latest.listId);
  final active = activeTopLevelTasks(siblings);
  final batch = applyDueDateChange(
    latest.copyWith(completed: false),
    active,
    dueDate: next.toUtc(),
    clearDueDate: false,
  );
  await repo.upsertTasksBatch(batch.tasks);
  await sync.pushTodoTasksBatch(batch.tasks);
  // Logged against the ticked state, which is never written: the row goes
  // straight from live to its next occurrence. A row already completed was
  // ticked by a caller that logged it (the calendar saves the tick first).
  await recordTodoCompletionChange(
    repo: repo,
    sync: sync,
    before: latest,
    after: latest.copyWith(completed: true),
  );
  final rolled = batch.tasks.firstWhere(
    (t) => t.id == taskId,
    orElse: () => latest.copyWith(completed: false, dueDate: next.toUtc()),
  );
  return TodoCompletionOutcome(
    rolledForward: true,
    listId: rolled.listId,
    writes: batch.tasks,
  );
}

/// Keeps the completion log in step with a write that took [before] to
/// [after]: a tick logs the occurrence's [TodoTaskCompletion], an un-tick
/// tombstones it, and anything else writes nothing.
///
/// Call it once per user action, after the task itself is on disk, with
/// [before] as it was on disk.
Future<void> recordTodoCompletionChange({
  required TodoRepository repo,
  required RemoteSyncService sync,
  required TodoTask before,
  required TodoTask after,
}) async {
  Future<void> write(TodoTaskCompletion completion) async {
    await repo.logCompletion(completion);
    sync.pushTodoTaskCompletion(completion);
  }

  if (!before.completed && after.completed) {
    final id = todoTaskCompletionId(after.id, after.dueDate);
    final existing = await repo.getCompletion(id);
    // Already counted: this occurrence was ticked before and never taken back.
    if (existing != null && existing.deletedAt == null) return;
    await write(
      TodoTaskCompletion(
        id: id,
        taskId: after.id,
        completedAt: after.completedAt ?? utcNow(),
        dueDate: after.dueDate,
        version: existing == null ? 0 : existing.version + 1,
      ),
    );
  } else if (before.completed && !after.completed) {
    final completedAt = before.completedAt;
    // Completed before completedAt existed, so no row was ever logged.
    if (completedAt == null) return;
    // By the moment first: it still finds the row after the task's due date
    // was changed while it sat completed.
    final byMoment = await repo.findCompletion(before.id, completedAt);
    if (byMoment != null) return write(byMoment.deleted());
    // Then by occurrence: the tick may be another device's, logged at its own
    // moment, or not synced in yet — in which case the tombstone goes first
    // and outranks the row when it lands.
    final id = todoTaskCompletionId(before.id, before.dueDate);
    final existing = await repo.getCompletion(id);
    if (existing != null && existing.deletedAt != null) return;
    await write(
      existing?.deleted() ??
          TodoTaskCompletion(
            id: id,
            taskId: before.id,
            completedAt: completedAt,
            dueDate: before.dueDate,
            version: 1,
            deletedAt: utcNow(),
          ),
    );
  }
}
