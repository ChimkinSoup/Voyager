import 'package:voyager/core/constants/todo_sort_constants.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/domain/models/todo_models.dart';

/// Result of a sort mutation that may touch multiple tasks in the same list.
class TodoSortBatch {
  const TodoSortBatch({required this.tasks});

  final List<TodoTask> tasks;
}

int compareTodoTasks(TodoTask a, TodoTask b) {
  if (a.starred != b.starred) return a.starred ? -1 : 1;

  final order = a.sortOrder.compareTo(b.sortOrder);
  if (order != 0) return order;

  return a.createdAt.compareTo(b.createdAt);
}

List<TodoTask> sortTodoTasks(Iterable<TodoTask> tasks) {
  final sorted = tasks.toList()..sort(compareTodoTasks);
  return sorted;
}

List<TodoTask> activeTopLevelTasks(Iterable<TodoTask> tasks) {
  return tasks.where((t) => !t.completed && !t.isSubtask).toList();
}

/// Earliest due date first; same deadline → most recently dated first.
int compareDueDateChronological(TodoTask a, TodoTask b) {
  final dueCompare = a.dueDate!.compareTo(b.dueDate!);
  if (dueCompare != 0) return dueCompare;

  final aSet = a.dueDateSetAt ?? a.createdAt;
  final bSet = b.dueDateSetAt ?? b.createdAt;
  return bSet.compareTo(aSet);
}

/// Returns the sort order a new undated unstarred task would receive.
int nextNewTaskSortOrder(List<TodoTask> activeTasks) {
  const placeholderId = '__next_new_task__';
  final placeholder = TodoTask(
    id: placeholderId,
    listId: 'placeholder',
    title: placeholderId,
    createdAt: utcNow(),
    updatedAt: utcNow(),
  );
  final batch = applyNewUndatedTask(placeholder, activeTasks);
  return batch.tasks.firstWhere((task) => task.id == placeholderId).sortOrder;
}

/// Inserts a new undated unstarred task at the top of the undated section.
TodoSortBatch applyNewUndatedTask(TodoTask task, List<TodoTask> activeTasks) {
  return applyTaskPlacement(task, activeTasks);
}

/// Places a task into a list using star/due-date group rules.
TodoSortBatch applyTaskPlacement(
  TodoTask task,
  List<TodoTask> activeTasks,
) {
  final others = activeTasks.where((t) => t.id != task.id).toList();
  final starred = others.where((t) => t.starred).toList()
    ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
  final unstarred = others.where((t) => !t.starred).toList()
    ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

  final updates = <TodoTask>[];

  if (task.starred) {
    final orderedStarred = buildStarredOrder(starred, insert: task);
    updates.addAll(
      _reindex(orderedStarred, starred: true, activeTasks: activeTasks),
    );
    updates.addAll(
      _reindex(unstarred, starred: false, activeTasks: activeTasks),
    );
  } else {
    updates.addAll(
      _reindex(starred, starred: true, activeTasks: activeTasks),
    );
    final orderedUnstarred = task.dueDate != null
        ? buildUnstarredOrderForDueDate(unstarred, task)
        : buildUnstarredOrderSnapToTop(unstarred, task);
    updates.addAll(
      _reindex(orderedUnstarred, starred: false, activeTasks: activeTasks),
    );
  }

  return TodoSortBatch(tasks: _uniqueUpdates(updates));
}

/// Re-inserts an active task after it is marked incomplete.
TodoSortBatch applyTaskUncomplete(TodoTask task, List<TodoTask> activeTasks) {
  return applyTaskPlacement(task, activeTasks);
}

/// Places a task into a destination list after a list move.
TodoSortBatch applyTaskListMove(
  TodoTask task,
  List<TodoTask> destActiveTasks,
) {
  return applyTaskPlacement(task, destActiveTasks);
}

/// Returns a batch when unstarred dated/undated sections are out of order.
TodoSortBatch? applyNormalizeUnstarredIfNeeded(List<TodoTask> activeTasks) {
  final unstarred = activeTasks.where((t) => !t.starred).toList()
    ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
  if (!unstarredSectionNeedsNormalize(unstarred)) return null;

  final normalized = normalizeUnstarredSection(unstarred);
  final starred = activeTasks.where((t) => t.starred).toList()
    ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

  final updates = <TodoTask>[];
  updates.addAll(_reindex(starred, starred: true, activeTasks: activeTasks));
  updates.addAll(
    _reindex(normalized, starred: false, activeTasks: activeTasks),
  );
  return updates.isEmpty ? null : TodoSortBatch(tasks: updates);
}

bool unstarredSectionNeedsNormalize(List<TodoTask> unstarred) {
  final sorted = [...unstarred]..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
  var seenUndated = false;
  for (final task in sorted) {
    if (task.dueDate == null) {
      seenUndated = true;
    } else if (seenUndated) {
      return true;
    }
  }
  return false;
}

List<TodoTask> normalizeUnstarredSection(List<TodoTask> unstarred) {
  final dated = <TodoTask>[];
  final undated = <TodoTask>[];
  for (final task in unstarred) {
    if (task.dueDate != null) {
      dated.add(task);
    } else {
      undated.add(task);
    }
  }
  return [...dated, ...undated];
}

TodoSortBatch applyStarToggle(TodoTask task, List<TodoTask> activeTasks) {
  if (task.starred) {
    return _applyUnstar(task, activeTasks);
  }
  return _applyStar(task, activeTasks);
}

TodoSortBatch applyDueDateChange(
  TodoTask task,
  List<TodoTask> activeTasks, {
  required DateTime? dueDate,
  required bool clearDueDate,
}) {
  if (!clearDueDate &&
      dueDate != null &&
      task.dueDate != null &&
      task.dueDate == dueDate) {
    return TodoSortBatch(tasks: [task]);
  }

  final now = utcNow();
  if (clearDueDate) {
    final cleared = task.copyWith(clearDueDate: true, clearDueDateSetAt: true);
    if (task.starred) {
      return _batchFromOrder(
        activeTasks,
        buildStarredOrder(
          activeTasks.where((t) => t.starred).toList(),
          insert: cleared,
        ),
        starredSegment: true,
      );
    }
    return _batchFromOrder(
      activeTasks,
      buildUnstarredOrderAfterClearDueDate(
        activeTasks.where((t) => !t.starred).toList(),
        cleared,
      ),
      starredSegment: false,
    );
  }

  if (dueDate == null) {
    return TodoSortBatch(tasks: [task]);
  }

  final dated = task.copyWith(
    dueDate: dueDate,
    dueDateSetAt: now,
  );

  if (task.starred) {
    return _batchFromOrder(
      activeTasks,
      buildStarredOrder(
        activeTasks.where((t) => t.starred).toList(),
        insert: dated,
      ),
      starredSegment: true,
    );
  }

  return _batchFromOrder(
    activeTasks,
    buildUnstarredOrderForDueDate(
      activeTasks.where((t) => !t.starred).toList(),
      dated,
    ),
    starredSegment: false,
  );
}

/// When an unstarred task is dragged into the starred group, snap it to the top
/// of the unstarred section (top of the undated subsection when undated).
List<TodoTask> buildUnstarredOrderSnapToTop(
  List<TodoTask> unstarred,
  TodoTask task,
) {
  final others = unstarred.where((t) => t.id != task.id).toList()
    ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

  if (task.dueDate == null) {
    final dated = others.where((t) => t.dueDate != null).toList();
    final undated = others.where((t) => t.dueDate == null).toList();
    return [...dated, task, ...undated];
  }

  return [task, ...others];
}

TodoSortBatch? applyReorder(
  List<TodoTask> active,
  int oldIndex,
  int newIndex,
) {
  if (oldIndex == newIndex) return null;

  final moved = active[oldIndex];
  final starredCount = active.where((t) => t.starred).length;

  if (moved.starred) {
    if (newIndex >= starredCount) {
      newIndex = starredCount - 1;
    }
  } else if (newIndex < starredCount) {
    final starred = active.where((t) => t.starred).toList()
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    final unstarred = active.where((t) => !t.starred).toList();
    final snapped = buildUnstarredOrderSnapToTop(unstarred, moved);

    final updates = <TodoTask>[];
    updates.addAll(_reindex(starred, starred: true, activeTasks: active));
    updates.addAll(_reindex(snapped, starred: false, activeTasks: active));
    return updates.isEmpty ? null : TodoSortBatch(tasks: updates);
  }

  final items = List<TodoTask>.from(active);
  items.removeAt(oldIndex);
  items.insert(newIndex, moved);

  final starred = items.take(starredCount).toList();
  final unstarred = normalizeUnstarredSection(items.skip(starredCount).toList());

  final updates = <TodoTask>[];
  updates.addAll(_reindex(starred, starred: true, activeTasks: active));
  updates.addAll(_reindex(unstarred, starred: false, activeTasks: active));
  return updates.isEmpty ? null : TodoSortBatch(tasks: updates);
}

List<TodoTask> buildStarredOrder(
  List<TodoTask> starred, {
  TodoTask? insert,
}) {
  final others = insert == null
      ? starred
      : starred.where((t) => t.id != insert.id).toList();

  final dated = others.where((t) => t.dueDate != null).toList()
    ..sort(compareDueDateChronological);
  final undated = others.where((t) => t.dueDate == null).toList()
    ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

  if (insert == null) return [...dated, ...undated];

  if (insert.dueDate != null) {
    final datedWithInsert = [...dated];
    var index = 0;
    while (index < datedWithInsert.length &&
        compareDueDateChronological(insert, datedWithInsert[index]) > 0) {
      index++;
    }
    datedWithInsert.insert(index, insert);
    return [...datedWithInsert, ...undated];
  }

  return [...dated, insert, ...undated];
}

List<TodoTask> buildUnstarredOrderForDueDate(
  List<TodoTask> unstarred,
  TodoTask task,
) {
  final others = unstarred.where((t) => t.id != task.id).toList();
  final dated = others.where((t) => t.dueDate != null).toList()
    ..sort(compareDueDateChronological);
  final undated = others.where((t) => t.dueDate == null).toList()
    ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

  final datedWithInsert = [...dated];
  var index = 0;
  while (index < datedWithInsert.length &&
      compareDueDateChronological(task, datedWithInsert[index]) > 0) {
    index++;
  }
  datedWithInsert.insert(index, task);
  return [...datedWithInsert, ...undated];
}

List<TodoTask> buildUnstarredOrderAfterClearDueDate(
  List<TodoTask> unstarred,
  TodoTask clearedTask,
) {
  final others = unstarred.where((t) => t.id != clearedTask.id).toList();
  final dated = others.where((t) => t.dueDate != null).toList()
    ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
  final undated = others.where((t) => t.dueDate == null).toList()
    ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
  return [...dated, clearedTask, ...undated];
}

TodoSortBatch _applyStar(TodoTask task, List<TodoTask> activeTasks) {
  final preStarSortOrder = normalizeUnstarredSortOrder(task.sortOrder);
  final starred = task.copyWith(
    starred: true,
    preStarSortOrder: preStarSortOrder,
  );

  return _batchFromOrder(
    activeTasks,
    buildStarredOrder(
      activeTasks.where((t) => t.starred).toList(),
      insert: starred,
    ),
    starredSegment: true,
  );
}

TodoSortBatch _applyUnstar(TodoTask task, List<TodoTask> activeTasks) {
  final remainingStarred = activeTasks
      .where((t) => t.starred && t.id != task.id)
      .toList()
    ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

  final unstarred = task.copyWith(
    starred: false,
    clearPreStarSortOrder: true,
  );

  final updates = <TodoTask>[];
  updates.addAll(
    _reindex(remainingStarred, starred: true, activeTasks: activeTasks),
  );

  if (task.dueDate != null) {
    final otherUnstarred =
        activeTasks.where((t) => !t.starred && t.id != task.id).toList();
    final ordered = buildUnstarredOrderForDueDate(otherUnstarred, unstarred);
    updates.addAll(
      _reindex(ordered, starred: false, activeTasks: activeTasks),
    );
  } else {
    final otherUnstarred =
        activeTasks.where((t) => !t.starred && t.id != task.id).toList();
    final ordered = buildUnstarredOrderSnapToTop(otherUnstarred, unstarred);
    updates.addAll(
      _reindex(ordered, starred: false, activeTasks: activeTasks),
    );
  }

  return TodoSortBatch(tasks: _uniqueUpdates(updates));
}

TodoSortBatch _batchFromOrder(
  List<TodoTask> activeTasks,
  List<TodoTask> orderedSegment, {
  required bool starredSegment,
}) {
  final updates = _reindex(
    orderedSegment,
    starred: starredSegment,
    activeTasks: activeTasks,
  );
  return TodoSortBatch(tasks: updates);
}

List<TodoTask> _reindex(
  List<TodoTask> ordered, {
  required bool starred,
  required List<TodoTask> activeTasks,
}) {
  final base = starred ? 0 : unstarredSortOrderBase;
  final previousById = {for (final task in activeTasks) task.id: task};
  final updates = <TodoTask>[];

  for (var i = 0; i < ordered.length; i++) {
    final next = ordered[i].copyWith(sortOrder: base + i);
    final previous = previousById[next.id];
    if (previous == null ||
        previous.sortOrder != next.sortOrder ||
        previous.starred != next.starred ||
        previous.preStarSortOrder != next.preStarSortOrder ||
        previous.dueDate != next.dueDate ||
        previous.dueDateSetAt != next.dueDateSetAt) {
      updates.add(next);
    }
  }

  return updates;
}

List<TodoTask> _uniqueUpdates(List<TodoTask> updates) {
  final byId = <String, TodoTask>{};
  for (final task in updates) {
    byId[task.id] = task;
  }
  return byId.values.toList();
}
