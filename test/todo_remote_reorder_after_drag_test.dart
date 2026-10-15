// BUG-249: after this device drags a task, a reorder that arrives from another
// device must still show. The drag's forced order used to outlive the write it
// stood for, so the page kept drawing its own order over the database's.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/features/todo/todo_page.dart';

import 'support/todo_page_harness.dart';

/// The active rows' titles, top to bottom as drawn.
List<String> _drawnOrder(WidgetTester tester, int count) {
  final titles = [for (var i = 0; i < count; i++) 'Task $i'];
  final placed = [
    for (final title in titles)
      (title, tester.getTopLeft(find.text(title).first).dy),
  ]..sort((a, b) => a.$2.compareTo(b.$2));
  return [for (final p in placed) p.$1];
}

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('a remote reorder shows after this device dragged (BUG-249)', (
    tester,
  ) async {
    final db = await pumpTodoPage(tester, active: 4, done: 0);
    expect(_drawnOrder(tester, 4), ['Task 0', 'Task 1', 'Task 2', 'Task 3']);

    // This device drags Task 0 to the bottom, through the list's own callback.
    final list = tester.widget<SliverReorderableList>(
      find.byType(SliverReorderableList),
    );
    await tester.runAsync(() async {
      list.onReorderItem!(0, 3);
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await _frames(tester);
    expect(_drawnOrder(tester, 4), ['Task 1', 'Task 2', 'Task 3', 'Task 0']);

    // Another device then moves Task 3 to the top; live sync writes its rows
    // and refreshes the list.
    final repo = DriftTodoRepository(db);
    await tester.runAsync(() async {
      final tasks = await repo.listTasks(todoHarnessListId);
      final top = tasks.map((t) => t.sortOrder).reduce((a, b) => a < b ? a : b);
      final task3 = tasks.firstWhere((t) => t.title == 'Task 3');
      await repo.upsertTask(
        task3.copyWith(sortOrder: top - 1000),
        recordLocalActivity: false,
      );
    });
    final container = ProviderScope.containerOf(
      tester.element(find.byType(TodoPage)),
    );
    container.invalidate(todoTasksProvider(todoHarnessListId));
    await _frames(tester);

    expect(_drawnOrder(tester, 4), ['Task 3', 'Task 1', 'Task 2', 'Task 0']);
  });
}
