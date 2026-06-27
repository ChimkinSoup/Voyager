import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/constants/todo_sort_constants.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/domain/todo/todo_task_sorting.dart';

TodoTask _task({
  required String id,
  bool starred = false,
  int sortOrder = unstarredSortOrderBase,
  DateTime? dueDate,
  DateTime? dueDateSetAt,
  int? preStarSortOrder,
  DateTime? createdAt,
}) {
  final now = createdAt ?? utcNow();
  return TodoTask(
    id: id,
    listId: 'list-1',
    title: id,
    starred: starred,
    sortOrder: sortOrder,
    dueDate: dueDate,
    dueDateSetAt: dueDateSetAt,
    preStarSortOrder: preStarSortOrder,
    createdAt: now,
    updatedAt: now,
  );
}

List<TodoTask> _sortedAfterBatch(
  List<TodoTask> active,
  TodoSortBatch batch,
) {
  final byId = {for (final task in active) task.id: task};
  for (final task in batch.tasks) {
    byId[task.id] = task;
  }
  return sortTodoTasks(byId.values);
}

void main() {
  test('starring undated task places it below starred due tasks', () {
    final dueEarly = DateTime.utc(2026, 6, 1, 9);
    final dueLate = DateTime.utc(2026, 6, 2, 9);
    final active = [
      _task(id: 'a', starred: true, sortOrder: 0, dueDate: dueEarly),
      _task(id: 'b', starred: true, sortOrder: 1, dueDate: dueLate),
      _task(id: 'c', sortOrder: unstarredSortOrderBase),
    ];

    final batch = applyStarToggle(active[2], active);
    final sorted = _sortedAfterBatch(active, batch);

    expect(sorted.map((t) => t.id).toList(), ['a', 'b', 'c']);
    expect(sorted[2].starred, isTrue);
    expect(sorted[2].preStarSortOrder, unstarredSortOrderBase);
  });

  test('starring due task inserts chronologically among starred', () {
    final dueEarly = DateTime.utc(2026, 6, 1, 9);
    final dueLate = DateTime.utc(2026, 6, 3, 9);
    final dueMiddle = DateTime.utc(2026, 6, 2, 9);
    final active = [
      _task(id: 'a', starred: true, sortOrder: 0, dueDate: dueEarly),
      _task(id: 'b', starred: true, sortOrder: 1, dueDate: dueLate),
      _task(
        id: 'c',
        sortOrder: unstarredSortOrderBase,
        dueDate: dueMiddle,
        dueDateSetAt: utcNow(),
      ),
    ];

    final batch = applyStarToggle(active[2], active);
    final sorted = _sortedAfterBatch(active, batch);

    expect(sorted.map((t) => t.id).toList(), ['a', 'c', 'b']);
  });

  test('unstarring dated task inserts chronologically among unstarred dated',
      () {
    final dueEarly = DateTime.utc(2026, 6, 1, 9);
    final dueLate = DateTime.utc(2026, 6, 3, 9);
    final dueMiddle = DateTime.utc(2026, 6, 2, 9);
    final active = [
      _task(id: 'a', sortOrder: unstarredSortOrderBase, dueDate: dueEarly),
      _task(id: 'b', sortOrder: unstarredSortOrderBase + 1, dueDate: dueLate),
      _task(
        id: 'c',
        starred: true,
        sortOrder: 0,
        dueDate: dueMiddle,
        dueDateSetAt: utcNow(),
        preStarSortOrder: unstarredSortOrderBase + 2,
      ),
    ];

    final batch = applyStarToggle(active[2], active);
    final sorted = _sortedAfterBatch(active, batch);

    expect(sorted.map((t) => t.id).toList(), ['a', 'c', 'b']);
  });

  test('unstarring undated task moves to top of undated section', () {
    final due = DateTime.utc(2026, 6, 1, 9);
    final active = [
      _task(id: 'a', starred: true, sortOrder: 0),
      _task(id: 'b', sortOrder: unstarredSortOrderBase, dueDate: due),
      _task(id: 'c', sortOrder: unstarredSortOrderBase + 1),
    ];

    final batch = applyStarToggle(
      active[0].copyWith(
        starred: true,
        preStarSortOrder: unstarredSortOrderBase + 2,
      ),
      active,
    );
    final sorted = _sortedAfterBatch(active, batch);

    final unstarred = sorted.where((t) => !t.starred).toList();
    expect(unstarred.first.id, 'b');
    expect(unstarred.first.dueDate, isNotNull);
    expect(unstarred[1].id, 'a');
    expect(unstarred[1].dueDate, isNull);
  });

  test('unstarring undated task stays below all dated tasks', () {
    final due = DateTime.utc(2026, 6, 1, 9);
    final active = [
      _task(id: 'a', sortOrder: unstarredSortOrderBase, dueDate: due),
      _task(id: 'b', sortOrder: unstarredSortOrderBase + 5),
      _task(
        id: 'c',
        starred: true,
        sortOrder: 0,
        preStarSortOrder: unstarredSortOrderBase + 10,
      ),
    ];

    final batch = applyStarToggle(active[2], active);
    final sorted = _sortedAfterBatch(active, batch);

    expect(sorted.map((t) => t.id).toList(), ['a', 'c', 'b']);
  });

  test('dragging dated unstarred into starred snaps to top of unstarred group',
      () {
    final dueEarly = DateTime.utc(2026, 6, 1, 9);
    final dueLate = DateTime.utc(2026, 6, 3, 9);
    final active = [
      _task(id: 'a', starred: true, sortOrder: 0),
      _task(id: 'b', sortOrder: unstarredSortOrderBase, dueDate: dueEarly),
      _task(
        id: 'c',
        sortOrder: unstarredSortOrderBase + 1,
        dueDate: dueLate,
      ),
    ];

    final batch = applyReorder(active, 2, 0);
    expect(batch, isNotNull);
    final sorted = _sortedAfterBatch(active, batch!);
    expect(sorted.map((t) => t.id).toList(), ['a', 'c', 'b']);
  });

  test('dragging undated unstarred into starred snaps below due-dated tasks',
      () {
    final due = DateTime.utc(2026, 6, 1, 9);
    final active = [
      _task(id: 'a', starred: true, sortOrder: 0),
      _task(id: 'b', sortOrder: unstarredSortOrderBase, dueDate: due),
      _task(id: 'c', sortOrder: unstarredSortOrderBase + 2),
    ];

    final batch = applyReorder(active, 2, 0);
    expect(batch, isNotNull);
    final sorted = _sortedAfterBatch(active, batch!);

    final unstarred = sorted.where((t) => !t.starred).toList();
    expect(unstarred.map((t) => t.id).toList(), ['b', 'c']);
    expect(unstarred.last.dueDate, isNull);
  });

  test('dragging undated unstarred above dated snaps to top of undated section',
      () {
    final due = DateTime.utc(2026, 6, 1, 9);
    final active = [
      _task(id: 'a', sortOrder: unstarredSortOrderBase, dueDate: due),
      _task(id: 'b', sortOrder: unstarredSortOrderBase + 1),
      _task(id: 'c', sortOrder: unstarredSortOrderBase + 2),
    ];

    final batch = applyReorder(active, 2, 0);
    expect(batch, isNotNull);
    final sorted = _sortedAfterBatch(active, batch!);

    expect(sorted.map((t) => t.id).toList(), ['a', 'c', 'b']);
  });

  test('reorder clamps starred task above unstarred section', () {
    final active = [
      _task(id: 'a', starred: true, sortOrder: 0),
      _task(id: 'b', starred: true, sortOrder: 1),
      _task(id: 'c', sortOrder: unstarredSortOrderBase),
    ];

    final batch = applyReorder(active, 0, 2);
    expect(batch, isNotNull);
    final sorted = _sortedAfterBatch(active, batch!);
    expect(sorted.map((t) => t.id).toList(), ['b', 'a', 'c']);
  });

  test('setting due date inserts chronologically among unstarred dated tasks', () {
    final dueEarly = DateTime.utc(2026, 6, 1, 9);
    final dueLate = DateTime.utc(2026, 6, 3, 9);
    final dueMiddle = DateTime.utc(2026, 6, 2, 9);
    final active = [
      _task(id: 'a', sortOrder: unstarredSortOrderBase, dueDate: dueEarly),
      _task(id: 'b', sortOrder: unstarredSortOrderBase + 1, dueDate: dueLate),
      _task(id: 'c', sortOrder: unstarredSortOrderBase + 2),
    ];

    final batch = applyDueDateChange(
      active[2],
      active,
      dueDate: dueMiddle,
      clearDueDate: false,
    );
    final sorted = _sortedAfterBatch(active, batch);

    expect(sorted.map((t) => t.id).toList(), ['a', 'c', 'b']);
  });

  test('same due date orders by most recently dated first', () {
    final due = DateTime.utc(2026, 6, 1, 9);
    final older = DateTime.utc(2026, 1, 1);
    final newer = DateTime.utc(2026, 2, 1);
    final active = [
      _task(
        id: 'a',
        sortOrder: unstarredSortOrderBase,
        dueDate: due,
        dueDateSetAt: older,
      ),
      _task(id: 'b', sortOrder: unstarredSortOrderBase + 1),
    ];

    final batch = applyDueDateChange(
      active[1],
      active,
      dueDate: due,
      clearDueDate: false,
    );
    final sorted = _sortedAfterBatch(active, batch);

    expect(sorted.map((t) => t.id).toList(), ['b', 'a']);
  });

  test('clearing due date moves task to top of undated section', () {
    final due = DateTime.utc(2026, 6, 1, 9);
    final active = [
      _task(id: 'a', sortOrder: unstarredSortOrderBase, dueDate: due),
      _task(id: 'b', sortOrder: unstarredSortOrderBase + 1, dueDate: due),
      _task(id: 'c', sortOrder: unstarredSortOrderBase + 2),
    ];

    final batch = applyDueDateChange(
      active[1],
      active,
      dueDate: null,
      clearDueDate: true,
    );
    final sorted = _sortedAfterBatch(active, batch);

    expect(sorted.map((t) => t.id).toList(), ['a', 'b', 'c']);
    expect(sorted[1].dueDate, isNull);
  });

  test('new undated task stays below dated tasks', () {
    final due = DateTime.utc(2026, 6, 1, 9);
    final active = [
      _task(id: 'a', sortOrder: unstarredSortOrderBase, dueDate: due),
      _task(id: 'b', sortOrder: unstarredSortOrderBase + 5),
    ];
    final batch = applyNewUndatedTask(_task(id: 'new'), active);
    final sorted = _sortedAfterBatch(active, batch);
    expect(sorted.map((t) => t.id).toList(), ['a', 'new', 'b']);
  });

  test('nextNewTaskSortOrder matches applyNewUndatedTask placement', () {
    final due = DateTime.utc(2026, 6, 1, 9);
    final active = [
      _task(id: 'a', sortOrder: unstarredSortOrderBase, dueDate: due),
      _task(id: 'b', sortOrder: unstarredSortOrderBase + 2),
    ];

    expect(nextNewTaskSortOrder(active), unstarredSortOrderBase + 1);
  });

  test('dragging dated below undated normalizes back into dated section', () {
    final due = DateTime.utc(2026, 6, 1, 9);
    final active = sortTodoTasks([
      _task(id: 'b', sortOrder: unstarredSortOrderBase),
      _task(id: 'c', sortOrder: unstarredSortOrderBase + 1),
      _task(
        id: 'a',
        sortOrder: unstarredSortOrderBase + 2,
        dueDate: due,
      ),
    ]);

    final batch = applyReorder(active, 2, 0);
    expect(batch, isNotNull);
    final sorted = _sortedAfterBatch(active, batch!);
    expect(sorted.map((t) => t.id).toList(), ['a', 'b', 'c']);
  });

  test('normalize fixes legacy undated sort orders above dated tasks', () {
    final due = DateTime.utc(2026, 6, 1, 9);
    final active = [
      _task(id: 'a', sortOrder: unstarredSortOrderBase),
      _task(id: 'b', sortOrder: unstarredSortOrderBase + 1, dueDate: due),
    ];

    expect(unstarredSectionNeedsNormalize(active), isTrue);
    final batch = applyNormalizeUnstarredIfNeeded(active);
    expect(batch, isNotNull);
    final sorted = _sortedAfterBatch(active, batch!);
    expect(sorted.map((t) => t.id).toList(), ['b', 'a']);
  });

  test('uncompleting dated task inserts chronologically', () {
    final dueEarly = DateTime.utc(2026, 6, 1, 9);
    final dueLate = DateTime.utc(2026, 6, 3, 9);
    final dueMiddle = DateTime.utc(2026, 6, 2, 9);
    final active = [
      _task(id: 'a', sortOrder: unstarredSortOrderBase, dueDate: dueEarly),
      _task(id: 'b', sortOrder: unstarredSortOrderBase + 1, dueDate: dueLate),
    ];
    final restored = _task(
      id: 'c',
      sortOrder: unstarredSortOrderBase + 99,
      dueDate: dueMiddle,
      dueDateSetAt: utcNow(),
    );

    final batch = applyTaskUncomplete(restored, active);
    final sorted = _sortedAfterBatch([...active, restored], batch);
    expect(sorted.map((t) => t.id).toList(), ['a', 'c', 'b']);
  });

  test('uncompleting undated task goes to top of undated section', () {
    final due = DateTime.utc(2026, 6, 1, 9);
    final active = [
      _task(id: 'a', sortOrder: unstarredSortOrderBase, dueDate: due),
      _task(id: 'b', sortOrder: unstarredSortOrderBase + 2),
    ];
    final restored = _task(id: 'c', sortOrder: unstarredSortOrderBase + 99);

    final batch = applyTaskUncomplete(restored, active);
    final sorted = _sortedAfterBatch([...active, restored], batch);
    expect(sorted.map((t) => t.id).toList(), ['a', 'c', 'b']);
  });

  test('moving dated task to another list inserts chronologically', () {
    final dueEarly = DateTime.utc(2026, 6, 1, 9);
    final dueLate = DateTime.utc(2026, 6, 3, 9);
    final dueMiddle = DateTime.utc(2026, 6, 2, 9);
    final dest = [
      _task(id: 'a', sortOrder: unstarredSortOrderBase, dueDate: dueEarly),
      _task(id: 'b', sortOrder: unstarredSortOrderBase + 1, dueDate: dueLate),
    ];
    final moved = _task(
      id: 'c',
      sortOrder: 0,
      dueDate: dueMiddle,
      dueDateSetAt: utcNow(),
    );

    final batch = applyTaskListMove(moved, dest);
    final sorted = _sortedAfterBatch([...dest, moved], batch);
    expect(sorted.map((t) => t.id).toList(), ['a', 'c', 'b']);
  });

  test('moving undated task to another list goes to top of undated section', () {
    final due = DateTime.utc(2026, 6, 1, 9);
    final dest = [
      _task(id: 'a', sortOrder: unstarredSortOrderBase, dueDate: due),
      _task(id: 'b', sortOrder: unstarredSortOrderBase + 2),
    ];
    final moved = _task(id: 'c', sortOrder: 0);

    final batch = applyTaskListMove(moved, dest);
    final sorted = _sortedAfterBatch([...dest, moved], batch);
    expect(sorted.map((t) => t.id).toList(), ['a', 'c', 'b']);
  });

  test('setting the same due date again does not reorder', () {
    final due = DateTime.utc(2026, 6, 1, 9);
    final task = _task(
      id: 'a',
      sortOrder: unstarredSortOrderBase,
      dueDate: due,
      dueDateSetAt: utcNow(),
    );
    final batch = applyDueDateChange(
      task,
      [task],
      dueDate: due,
      clearDueDate: false,
    );
    expect(batch.tasks, [task]);
  });
}
