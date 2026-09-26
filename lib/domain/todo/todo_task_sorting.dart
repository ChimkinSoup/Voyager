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

/// The group a task belongs to, numbered in display order.
///
/// Starred above unstarred, dated above undated within each. This is the same
/// grammar the single-list view enforces piecemeal ([applyReorder] clamps
/// across the starred boundary, [normalizeUnstarredSection] pushes undated back
/// below dated) — naming it lets "All tasks" apply the same one directly.
int todoTaskGroupIndex(TodoTask task) {
  if (task.starred) return task.dueDate != null ? 0 : 1;
  return task.dueDate != null ? 2 : 3;
}

bool _isDatedGroup(int group) => group == 0 || group == 2;

/// The order the "All tasks" view shows: derived in full from the tasks
/// themselves, with nothing persisted and nothing remembered.
///
/// [compareTodoTasks] cannot do this job, because `sortOrder` is only ever
/// assigned *within* one list (see [_reindex]), so two lists' keys say nothing
/// about each other. Merging them and sorting on that field interleaves the two lists'
/// dated and undated sections arbitrarily — dated, then undated, then dated
/// again. The single-list case looks fine only because there is nothing to
/// interleave with, which is why a one-undated-task list survived the merge
/// unscathed.
///
/// So this view deliberately ignores `sortOrder` outright rather than trying to
/// reconcile the lists' independent numbering. It is not reorderable: there is
/// no drag to record and no per-list drag it should inherit, and the same set
/// of tasks always renders in the same order regardless of what was dragged
/// where inside any individual list.
List<TodoTask> resolveGlobalTaskOrder(Iterable<TodoTask> tasks) {
  return tasks.toList()..sort(compareGlobalTasks);
}

/// The total order behind [resolveGlobalTaskOrder]: [todoTaskGroupIndex] first,
/// then due date among the dated groups and newest-created-first among the
/// undated ones.
///
/// Newest first for the undated matches what the per-list view does when you
/// add one, which is to snap it to the top of the undated run (see
/// [buildUnstarredOrderSnapToTop]) — so a task you just made surfaces at the
/// top of its section in both views instead of flipping between them.
int compareGlobalTasks(TodoTask a, TodoTask b) {
  final group = todoTaskGroupIndex(a);
  final byGroup = group.compareTo(todoTaskGroupIndex(b));
  if (byGroup != 0) return byGroup;

  if (_isDatedGroup(group)) {
    final byDue = compareDueDateChronological(a, b);
    if (byDue != 0) return byDue;
  } else {
    final byCreated = b.createdAt.compareTo(a.createdAt);
    if (byCreated != 0) return byCreated;
  }

  // Ids only to keep the sort total, so two tasks that tie on everything above
  // don't swap places between rebuilds.
  return a.id.compareTo(b.id);
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
TodoSortBatch applyTaskPlacement(TodoTask task, List<TodoTask> activeTasks) {
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
    updates.addAll(_reindex(starred, starred: true, activeTasks: activeTasks));
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
TodoSortBatch applyTaskListMove(TodoTask task, List<TodoTask> destActiveTasks) {
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
  final sorted = [...unstarred]
    ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
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

/// Moves [task] to the bottom of its own category — starred/unstarred
/// crossed with dated/undated — leaving every other task's relative order
/// untouched. Dated tasks stay above undated ones within the same
/// starred-ness, matching [buildStarredOrder]/[buildUnstarredOrderForDueDate].
TodoSortBatch applyMoveToBottomOfCategory(
  TodoTask task,
  List<TodoTask> activeTasks,
) {
  final sameCategory =
      activeTasks
          .where((t) => t.id != task.id && t.starred == task.starred)
          .toList()
        ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
  final dated = sameCategory.where((t) => t.dueDate != null).toList();
  final undated = sameCategory.where((t) => t.dueDate == null).toList();

  final ordered = task.dueDate != null
      ? [...dated, task, ...undated]
      : [...dated, ...undated, task];

  return _batchFromOrder(activeTasks, ordered, starredSegment: task.starred);
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

  final dated = task.copyWith(dueDate: dueDate, dueDateSetAt: now);

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

TodoSortBatch? applyReorder(List<TodoTask> active, int oldIndex, int newIndex) {
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
  final unstarred = normalizeUnstarredSection(
    items.skip(starredCount).toList(),
  );

  final updates = <TodoTask>[];
  updates.addAll(_reindex(starred, starred: true, activeTasks: active));
  updates.addAll(_reindex(unstarred, starred: false, activeTasks: active));
  return updates.isEmpty ? null : TodoSortBatch(tasks: updates);
}

List<TodoTask> buildStarredOrder(List<TodoTask> starred, {TodoTask? insert}) {
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
  final starred = task.copyWith(starred: true);

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
  final remainingStarred =
      activeTasks.where((t) => t.starred && t.id != task.id).toList()
        ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

  final unstarred = task.copyWith(starred: false);

  final updates = <TodoTask>[];
  updates.addAll(
    _reindex(remainingStarred, starred: true, activeTasks: activeTasks),
  );

  if (task.dueDate != null) {
    final otherUnstarred = activeTasks
        .where((t) => !t.starred && t.id != task.id)
        .toList();
    final ordered = buildUnstarredOrderForDueDate(otherUnstarred, unstarred);
    updates.addAll(_reindex(ordered, starred: false, activeTasks: activeTasks));
  } else {
    final otherUnstarred = activeTasks
        .where((t) => !t.starred && t.id != task.id)
        .toList();
    final ordered = buildUnstarredOrderSnapToTop(otherUnstarred, unstarred);
    updates.addAll(_reindex(ordered, starred: false, activeTasks: activeTasks));
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

/// Gives [ordered] — one segment, starred or unstarred, in the order it should
/// show — sort keys, and returns the tasks whose row has to be written.
///
/// Keys are sparse, so placing one task writes one row: see [_sparseKeys].
/// Numbering the segment densely instead rewrote, and pushed, every task in
/// the list whenever one was added, dragged or un-ticked.
List<TodoTask> _reindex(
  List<TodoTask> ordered, {
  required bool starred,
  required List<TodoTask> activeTasks,
}) {
  final previousById = {for (final task in activeTasks) task.id: task};
  final keys = _sparseKeys([
    for (final task in ordered)
      // A task arriving from the other segment brings a key that means
      // nothing here.
      switch (previousById[task.id]) {
        final previous? when previous.starred == starred => previous.sortOrder,
        _ => null,
      },
  ]);
  final updates = <TodoTask>[];

  for (var i = 0; i < ordered.length; i++) {
    final next = ordered[i].copyWith(sortOrder: keys[i]);
    final previous = previousById[next.id];
    if (previous == null ||
        previous.sortOrder != next.sortOrder ||
        previous.starred != next.starred ||
        previous.dueDate != next.dueDate ||
        previous.dueDateSetAt != next.dueDateSetAt) {
      updates.add(next);
    }
  }

  return updates;
}

/// Keys stay within ±2^52, where every one is also exact as a double.
const _maxSortKey = 1 << 52;

/// Keys for one segment in display order, given the key each task already
/// holds in it (null for one arriving from elsewhere).
///
/// Keeps as many existing keys as can stay — the longest run of them already
/// in increasing order — and places only the rest, in the gaps their kept
/// neighbours leave. The whole segment is renumbered only when a gap has run
/// out, which a list still carrying the dense numbering older builds wrote
/// does on its first placement between two neighbours.
List<int> _sparseKeys(List<int?> existing) {
  final kept = _longestIncreasing(existing);
  final keys = [
    for (var i = 0; i < existing.length; i++)
      kept.contains(i) ? existing[i] : null,
  ];
  var i = 0;
  while (i < keys.length) {
    if (keys[i] != null) {
      i++;
      continue;
    }
    final start = i;
    while (i < keys.length && keys[i] == null) {
      i++;
    }
    final placed = _keysBetween(
      start > 0 ? keys[start - 1] : null,
      i < keys.length ? keys[i] : null,
      i - start,
    );
    if (placed == null) {
      return [for (var k = 0; k < keys.length; k++) (k + 1) * todoSortKeyGap];
    }
    keys.setRange(start, i, placed);
  }
  return keys.cast<int>();
}

/// [count] increasing keys strictly between [lower] and [upper] (either open),
/// or null when there is no room.
List<int>? _keysBetween(int? lower, int? upper, int count) {
  if (lower == null && upper == null) {
    return [for (var k = 0; k < count; k++) (k + 1) * todoSortKeyGap];
  }
  if (upper == null) {
    if (lower! + count * todoSortKeyGap > _maxSortKey) return null;
    return [for (var k = 0; k < count; k++) lower + (k + 1) * todoSortKeyGap];
  }
  if (lower == null) {
    final first = upper - count * todoSortKeyGap;
    if (first < -_maxSortKey) return null;
    return [for (var k = 0; k < count; k++) first + k * todoSortKeyGap];
  }
  final step = (upper - lower) ~/ (count + 1);
  if (step == 0) return null;
  return [for (var k = 0; k < count; k++) lower + (k + 1) * step];
}

/// Indexes of the longest strictly increasing run of non-null [keys].
///
/// Quadratic, which is fine at the size of one list's active tasks. Two keys
/// tied — two devices having placed tasks into the same gap — can't both stay,
/// so one of them is placed afresh.
Set<int> _longestIncreasing(List<int?> keys) {
  final length = List<int>.filled(keys.length, 0);
  final previous = List<int>.filled(keys.length, -1);
  var best = -1;
  for (var i = 0; i < keys.length; i++) {
    final key = keys[i];
    if (key == null) continue;
    length[i] = 1;
    for (var j = 0; j < i; j++) {
      final other = keys[j];
      if (other != null && other < key && length[j] + 1 > length[i]) {
        length[i] = length[j] + 1;
        previous[i] = j;
      }
    }
    if (best == -1 || length[i] > length[best]) best = i;
  }
  return {for (var i = best; i != -1; i = previous[i]) i};
}

List<TodoTask> _uniqueUpdates(List<TodoTask> updates) {
  final byId = <String, TodoTask>{};
  for (final task in updates) {
    byId[task.id] = task;
  }
  return byId.values.toList();
}
