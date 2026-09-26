// To-do sort keys are sparse: placing a task — adding, dragging, un-ticking,
// starring — writes that one row, where dense numbering rewrote and pushed
// every active task in the list. These pin the write counts, the fallbacks,
// and that the order every placement produces is the one dense numbering gave.

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/constants/todo_sort_constants.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/domain/todo/todo_task_sorting.dart';

final _created = DateTime.utc(2026, 1, 1);

TodoTask _task(
  String id, {
  int sortOrder = 0,
  bool starred = false,
  DateTime? dueDate,
  int createdOffset = 0,
}) {
  final created = _created.add(Duration(minutes: createdOffset));
  return TodoTask(
    id: id,
    listId: 'list',
    title: id,
    starred: starred,
    sortOrder: sortOrder,
    dueDate: dueDate,
    createdAt: created,
    updatedAt: created,
  );
}

/// [active] with [batch] written over it.
List<TodoTask> _apply(List<TodoTask> active, TodoSortBatch? batch) {
  final byId = {for (final task in active) task.id: task};
  for (final task in batch?.tasks ?? const <TodoTask>[]) {
    byId[task.id] = task;
  }
  return sortTodoTasks(byId.values);
}

List<String> _ids(List<TodoTask> tasks) => [for (final t in tasks) t.id];

/// Five undated tasks, already sparse.
List<TodoTask> _sparseList() => [
  for (var i = 0; i < 5; i++)
    _task('t$i', sortOrder: (i + 1) * todoSortKeyGap, createdOffset: i),
];

void main() {
  test('adding a task writes only that task', () {
    final active = _sparseList();
    final batch = applyNewUndatedTask(_task('new', createdOffset: 9), active);

    expect(_ids(batch.tasks), ['new']);
    expect(_ids(_apply(active, batch)), ['new', 't0', 't1', 't2', 't3', 't4']);
  });

  test('adding below dated tasks writes only that task', () {
    final due = DateTime.utc(2026, 6, 1);
    final active = [
      _task('dated', sortOrder: todoSortKeyGap, dueDate: due),
      ..._sparseList().map(
        (t) => t.copyWith(sortOrder: t.sortOrder + todoSortKeyGap),
      ),
    ];
    final batch = applyNewUndatedTask(_task('new', createdOffset: 9), active);

    expect(_ids(batch.tasks), ['new']);
    expect(_ids(_apply(active, batch)).take(3), ['dated', 'new', 't0']);
  });

  test('dragging a task writes only that task', () {
    final active = _sparseList();
    final batch = applyReorder(active, 4, 1);

    expect(_ids(batch!.tasks), ['t4']);
    expect(_ids(_apply(active, batch)), ['t0', 't4', 't1', 't2', 't3']);
  });

  test('un-ticking a task writes only that task', () {
    final active = _sparseList();
    final done = _task('done', sortOrder: 3 * todoSortKeyGap, createdOffset: 7);
    final batch = applyTaskUncomplete(done, active);

    expect(_ids(batch.tasks), ['done']);
    expect(_ids(_apply(active, batch)).first, 'done');
  });

  test('starring a task writes only that task', () {
    final active = _sparseList();
    final batch = applyStarToggle(active[3], active);

    expect(_ids(batch.tasks), ['t3']);
    expect(_ids(_apply(active, batch)).first, 't3');
  });

  test('a list still densely numbered is respaced once, then left alone', () {
    final due = DateTime.utc(2026, 6, 1);
    // What older builds wrote: consecutive keys, dated above undated.
    var active = [
      _task('dated', sortOrder: 1000, dueDate: due),
      _task('a', sortOrder: 1001),
      _task('b', sortOrder: 1002),
    ];

    // No room between 1000 and 1001: the section is renumbered.
    final first = applyNewUndatedTask(_task('n1', createdOffset: 1), active);
    expect(first.tasks, hasLength(4));
    active = _apply(active, first);
    expect(_ids(active), ['dated', 'n1', 'a', 'b']);

    final second = applyNewUndatedTask(_task('n2', createdOffset: 2), active);
    expect(_ids(second.tasks), ['n2']);
    expect(_ids(_apply(active, second)), ['dated', 'n2', 'n1', 'a', 'b']);
  });

  test('a gap that runs out is respaced, and the order holds', () {
    final due = DateTime.utc(2026, 6, 1);
    // Every new task lands between the dated task and the undated ones,
    // halving that gap each time.
    var active = [
      _task('dated', sortOrder: todoSortKeyGap, dueDate: due),
      _task('last', sortOrder: 2 * todoSortKeyGap),
    ];
    final expected = ['last'];
    var respaced = 0;
    for (var i = 0; i < 80; i++) {
      final batch = applyNewUndatedTask(
        _task('n$i', createdOffset: i + 1),
        active,
      );
      if (batch.tasks.length > 1) respaced++;
      active = _apply(active, batch);
      expected.insert(0, 'n$i');
      expect(_ids(active), ['dated', ...expected]);
    }
    expect(respaced, inInclusiveRange(1, 4));
  });

  test('tasks sharing a key are separated', () {
    // Two devices placing into the same gap at once.
    final active = [
      _task('a', sortOrder: todoSortKeyGap, createdOffset: 0),
      _task('b', sortOrder: todoSortKeyGap, createdOffset: 1),
      _task('c', sortOrder: 2 * todoSortKeyGap, createdOffset: 2),
    ];
    final batch = applyReorder(sortTodoTasks(active), 2, 0);
    final after = _apply(active, batch);

    expect(_ids(after), ['c', 'a', 'b']);
    expect(after.map((t) => t.sortOrder).toSet(), hasLength(3));
  });

  test('every placement orders tasks as dense numbering did', () {
    // Sparse keys change which rows are written, never the order: run the
    // same operations over a copy renumbered densely before each one, the
    // way the old scheme left every list, and compare.
    final random = Random(7);
    final due = [
      null,
      null,
      DateTime.utc(2026, 6, 1),
      DateTime.utc(2026, 6, 3),
      DateTime.utc(2026, 6, 2),
    ];
    var sparse = <TodoTask>[];
    var dense = <TodoTask>[];
    var nextId = 0;

    List<TodoTask> densify(List<TodoTask> tasks) {
      final sorted = sortTodoTasks(tasks);
      var starred = 0;
      var unstarred = 1000;
      return [
        for (final t in sorted)
          t.copyWith(sortOrder: t.starred ? starred++ : unstarred++),
      ];
    }

    for (var step = 0; step < 400; step++) {
      dense = densify(dense);
      final op = sparse.length < 3 ? 0 : random.nextInt(5);
      TodoSortBatch? onSparse;
      TodoSortBatch? onDense;
      switch (op) {
        case 0:
          final task = _task(
            'n${nextId++}',
            dueDate: due[random.nextInt(due.length)],
            createdOffset: step,
          );
          onSparse = applyTaskPlacement(task, sparse);
          onDense = applyTaskPlacement(task, dense);
        case 1:
          final from = random.nextInt(sparse.length);
          final to = random.nextInt(sparse.length);
          final sortedSparse = sortTodoTasks(sparse);
          final sortedDense = sortTodoTasks(dense);
          expect(_ids(sortedSparse), _ids(sortedDense));
          onSparse = applyReorder(sortedSparse, from, to);
          onDense = applyReorder(sortedDense, from, to);
        case 2:
          final id = sparse[random.nextInt(sparse.length)].id;
          onSparse = applyStarToggle(
            sparse.firstWhere((t) => t.id == id),
            sparse,
          );
          onDense = applyStarToggle(dense.firstWhere((t) => t.id == id), dense);
        case 3:
          final id = sparse[random.nextInt(sparse.length)].id;
          onSparse = applyMoveToBottomOfCategory(
            sparse.firstWhere((t) => t.id == id),
            sparse,
          );
          onDense = applyMoveToBottomOfCategory(
            dense.firstWhere((t) => t.id == id),
            dense,
          );
        case 4:
          // Tick one off, then bring it straight back.
          final id = sparse[random.nextInt(sparse.length)].id;
          final ticked = sparse.firstWhere((t) => t.id == id);
          sparse = sparse.where((t) => t.id != id).toList();
          dense = dense.where((t) => t.id != id).toList();
          onSparse = applyTaskUncomplete(ticked, sparse);
          onDense = applyTaskUncomplete(ticked, dense);
      }
      sparse = _apply(sparse, onSparse);
      dense = _apply(dense, onDense);
      expect(_ids(sparse), _ids(dense), reason: 'step $step, op $op');
    }
    expect(nextId, greaterThan(20));
  });
}
