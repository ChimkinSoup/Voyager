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

  test('move to bottom sends unstarred undated task below its siblings', () {
    final due = DateTime.utc(2026, 6, 1, 9);
    final active = [
      _task(id: 'a', sortOrder: unstarredSortOrderBase, dueDate: due),
      _task(id: 'b', sortOrder: unstarredSortOrderBase + 1),
      _task(id: 'c', sortOrder: unstarredSortOrderBase + 2),
    ];

    final batch = applyMoveToBottomOfCategory(active[1], active);
    final sorted = _sortedAfterBatch(active, batch);
    expect(sorted.map((t) => t.id).toList(), ['a', 'c', 'b']);
  });

  test('move to bottom keeps unstarred dated task above undated section', () {
    final dueEarly = DateTime.utc(2026, 6, 1, 9);
    final dueLate = DateTime.utc(2026, 6, 3, 9);
    final active = [
      _task(id: 'a', sortOrder: unstarredSortOrderBase, dueDate: dueEarly),
      _task(id: 'b', sortOrder: unstarredSortOrderBase + 1, dueDate: dueLate),
      _task(id: 'c', sortOrder: unstarredSortOrderBase + 2),
    ];

    final batch = applyMoveToBottomOfCategory(active[0], active);
    final sorted = _sortedAfterBatch(active, batch);
    expect(sorted.map((t) => t.id).toList(), ['b', 'a', 'c']);
  });

  test('move to bottom sends starred task below its starred siblings', () {
    final active = [
      _task(id: 'a', starred: true, sortOrder: 0),
      _task(id: 'b', starred: true, sortOrder: 1),
      _task(id: 'c', sortOrder: unstarredSortOrderBase),
    ];

    final batch = applyMoveToBottomOfCategory(active[0], active);
    final sorted = _sortedAfterBatch(active, batch);
    expect(sorted.map((t) => t.id).toList(), ['b', 'a', 'c']);
  });

  test('move to bottom keeps starred dated task above starred undated', () {
    final dueEarly = DateTime.utc(2026, 6, 1, 9);
    final dueLate = DateTime.utc(2026, 6, 3, 9);
    final active = [
      _task(id: 'a', starred: true, sortOrder: 0, dueDate: dueEarly),
      _task(id: 'e', starred: true, sortOrder: 1, dueDate: dueLate),
      _task(id: 'b', starred: true, sortOrder: 2),
      _task(id: 'c', sortOrder: unstarredSortOrderBase),
    ];

    final batch = applyMoveToBottomOfCategory(active[0], active);
    final sorted = _sortedAfterBatch(active, batch);
    expect(sorted.map((t) => t.id).toList(), ['e', 'a', 'b', 'c']);
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

  group('resolveGlobalTaskOrder ("All tasks")', () {
    TodoTask fromList(
      String listId, {
      required String id,
      bool starred = false,
      int sortOrder = unstarredSortOrderBase,
      DateTime? dueDate,
      DateTime? createdAt,
    }) {
      final now = createdAt ?? utcNow();
      return TodoTask(
        id: id,
        listId: listId,
        title: id,
        starred: starred,
        sortOrder: sortOrder,
        dueDate: dueDate,
        dueDateSetAt: dueDate == null ? null : now,
        createdAt: now,
        updatedAt: now,
      );
    }

    test('dated and undated tasks never interleave across lists', () {
      // The reported bug. Both lists number their own tasks from the same
      // base, so sorting the merged set on sortOrder ran dated → undated →
      // dated. Nothing may come between the two sections now.
      final tasks = [
        fromList('a', id: 'a-dated-1',
            sortOrder: unstarredSortOrderBase,
            dueDate: DateTime.utc(2026, 6, 1)),
        fromList('a', id: 'a-undated',
            sortOrder: unstarredSortOrderBase + 1),
        fromList('b', id: 'b-dated',
            sortOrder: unstarredSortOrderBase,
            dueDate: DateTime.utc(2026, 6, 2)),
        fromList('b', id: 'b-undated',
            sortOrder: unstarredSortOrderBase + 1),
        fromList('a', id: 'a-dated-2',
            sortOrder: unstarredSortOrderBase + 2,
            dueDate: DateTime.utc(2026, 6, 3)),
      ];

      final sorted = resolveGlobalTaskOrder(tasks);
      final firstUndated = sorted.indexWhere((t) => t.dueDate == null);
      expect(firstUndated, isNot(-1));
      expect(
        sorted.skip(firstUndated).every((t) => t.dueDate == null),
        isTrue,
        reason: 'a dated task came back after the undated section began',
      );
    });

    test('dated tasks run chronologically regardless of their list', () {
      final tasks = [
        fromList('b', id: 'late', dueDate: DateTime.utc(2026, 6, 9)),
        fromList('a', id: 'early', dueDate: DateTime.utc(2026, 6, 1)),
        fromList('c', id: 'middle', dueDate: DateTime.utc(2026, 6, 4)),
      ];
      expect(
        resolveGlobalTaskOrder(tasks).map((t) => t.id).toList(),
        ['early', 'middle', 'late'],
      );
    });

    test('starred tasks lead, and are themselves dated-then-undated', () {
      final tasks = [
        fromList('a', id: 'plain-dated', dueDate: DateTime.utc(2026, 6, 1)),
        fromList('b', id: 'star-undated', starred: true),
        fromList('a', id: 'plain-undated'),
        fromList('c', id: 'star-dated',
            starred: true, dueDate: DateTime.utc(2026, 6, 5)),
      ];
      expect(
        resolveGlobalTaskOrder(tasks).map((t) => t.id).toList(),
        ['star-dated', 'star-undated', 'plain-dated', 'plain-undated'],
      );
    });

    test('undated tasks run newest-created first', () {
      final tasks = [
        fromList('a', id: 'oldest', createdAt: DateTime.utc(2026, 1, 1)),
        fromList('b', id: 'newest', createdAt: DateTime.utc(2026, 3, 1)),
        fromList('a', id: 'middle', createdAt: DateTime.utc(2026, 2, 1)),
      ];
      expect(
        resolveGlobalTaskOrder(tasks).map((t) => t.id).toList(),
        ['newest', 'middle', 'oldest'],
      );
    });

    test('the order does not depend on the order it was handed', () {
      // The user saw the bug appear only when switching in from certain lists
      // — i.e. it depended on the incoming order. It must not.
      final tasks = [
        fromList('a', id: 'd1',
            dueDate: DateTime.utc(2026, 6, 1),
            createdAt: DateTime.utc(2026, 1, 1)),
        fromList('b', id: 'u1', createdAt: DateTime.utc(2026, 1, 2)),
        fromList('c', id: 'd2',
            dueDate: DateTime.utc(2026, 6, 2),
            createdAt: DateTime.utc(2026, 1, 3)),
        fromList('a', id: 'u2', createdAt: DateTime.utc(2026, 1, 4)),
      ];
      final expected = resolveGlobalTaskOrder(tasks).map((t) => t.id).toList();
      expect(expected, ['d1', 'd2', 'u2', 'u1']);
      expect(
        resolveGlobalTaskOrder(tasks.reversed).map((t) => t.id).toList(),
        expected,
      );
    });

    test('a single undated task from one list is left alone', () {
      // The case that already looked right, and has to keep looking right.
      final only = fromList('a', id: 'solo');
      expect(resolveGlobalTaskOrder([only]).single.id, 'solo');
    });

    test('per-list sortOrder does not affect the order', () {
      // The point of the view: a drag performed inside a list you cannot see
      // from here must not move anything here. sortOrder says a1 leads; the
      // derived order says a2 does, because it was created later.
      final tasks = [
        fromList('a', id: 'a1', sortOrder: unstarredSortOrderBase,
            createdAt: DateTime.utc(2026, 1, 5)),
        fromList('a', id: 'a2', sortOrder: unstarredSortOrderBase + 1,
            createdAt: DateTime.utc(2026, 1, 9)),
        fromList('b', id: 'b1', sortOrder: unstarredSortOrderBase,
            createdAt: DateTime.utc(2026, 1, 7)),
      ];
      expect(
        resolveGlobalTaskOrder(tasks).map((t) => t.id).toList(),
        ['a2', 'b1', 'a1'],
      );
    });

    test('a newly created task leads its section', () {
      // Matches what the single-list view does on add, so the same task does
      // not sit at opposite ends of the two views.
      final existing = [
        fromList('a', id: 'first', createdAt: DateTime.utc(2026, 1, 3)),
        fromList('a', id: 'second', createdAt: DateTime.utc(2026, 1, 2)),
        fromList('b', id: 'third', createdAt: DateTime.utc(2026, 1, 1)),
      ];
      final fresh = fromList('b', id: 'fresh', createdAt: DateTime.utc(2027));
      expect(
        resolveGlobalTaskOrder([...existing, fresh]).map((t) => t.id).toList(),
        ['fresh', 'first', 'second', 'third'],
      );
    });

    test('two tasks alike in every sort key still hold a stable order', () {
      final at = DateTime.utc(2026, 5, 5);
      final tasks = [
        fromList('a', id: 'zzz', createdAt: at),
        fromList('b', id: 'aaa', createdAt: at),
      ];
      expect(
        resolveGlobalTaskOrder(tasks).map((t) => t.id).toList(),
        ['aaa', 'zzz'],
      );
      expect(
        resolveGlobalTaskOrder(tasks.reversed).map((t) => t.id).toList(),
        ['aaa', 'zzz'],
      );
    });
  });

}
