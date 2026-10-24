// The built-in "To-do" list could never be deleted, so a user whose real
// tasks lived in another list was stuck with it as the place deleted lists'
// tasks went. Now any list but the last can be deleted, and "Move" sends its
// tasks to the default-view list or the oldest one left, as journals do.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/constants/todo_constants.dart';
import 'package:voyager/core/widgets/context_menu.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/features/todo/todo_list_actions.dart';

import 'support/todo_page_harness.dart';

Future<void> _frames(WidgetTester tester, [int count = 8]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Future<void> _openMenuOf(WidgetTester tester, String name) async {
  final row = find.ancestor(
    of: find.text(name).last,
    matching: find.byType(ListTile),
  );
  await tester.tap(
    find.descendant(of: row, matching: find.byType(ContextMenuButton)),
  );
  await _frames(tester);
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('the built-in "To-do" list can be deleted, its tasks moving to '
      'the default-view list', (tester) async {
    final db = await pumpTodoPage(
      tester,
      active: 1,
      done: 0,
      seedSecondList: true,
      defaultTodoListId: todoHarnessSecondListId,
      seedExtra: (repo) async {
        // "Harness" is older than "Second", so it would win on age alone;
        // the default view is what sends the tasks to "Second".
        final then = DateTime.now().toUtc().subtract(const Duration(days: 1));
        await repo.upsertList(
          TodoListModel(
            id: legacyTodoListId,
            name: 'To-do',
            createdAt: then,
            updatedAt: then,
          ),
        );
        await repo.upsertTask(
          TodoTask(
            id: 'test-data',
            listId: legacyTodoListId,
            title: 'Test data',
            sortOrder: 0,
            createdAt: then,
            updatedAt: then,
          ),
        );
      },
    );

    await tester.tap(find.byTooltip('Manage lists'));
    await _frames(tester);
    await _openMenuOf(tester, 'To-do');
    await tester.tap(find.text('Delete').last);
    await _frames(tester);
    await tester.tap(find.text('Move to "$todoHarnessSecondListName"'));
    await _frames(tester);

    final repo = DriftTodoRepository(db);
    expect(
      (await repo.listLists()).map((l) => l.id),
      isNot(contains(legacyTodoListId)),
    );
    expect((await repo.getTask('test-data'))!.listId, todoHarnessSecondListId);

    await tester.tap(find.text('Close'));
    await _frames(tester);
  });

  testWidgets('the last list has no Delete', (tester) async {
    await pumpTodoPage(tester, active: 1, done: 0);

    await tester.tap(find.byTooltip('Manage lists'));
    await _frames(tester);
    await _openMenuOf(tester, 'Harness');

    expect(find.text('Rename'), findsOneWidget);
    expect(find.text('Delete'), findsNothing);

    // On the dialog's title: the menu lets the click through, and outside
    // the dialog it would close the dialog too.
    await tester.tap(find.text('Manage lists').last);
    await _frames(tester);
    await tester.tap(find.text('Close'));
    await _frames(tester);
  });

  group('fallbackTodoListFor', () {
    final t0 = DateTime.utc(2026, 1, 1);
    TodoListModel list(String id, int day, {DateTime? deletedAt}) =>
        TodoListModel(
          id: id,
          name: id,
          createdAt: t0.add(Duration(days: day)),
          updatedAt: t0,
          deletedAt: deletedAt,
        );

    test('prefers the default-view list, else the oldest live one', () {
      final lists = [
        list('gone', 0, deletedAt: t0),
        list('b', 2),
        list('a', 1),
        list('doomed', 0),
      ];
      expect(fallbackTodoListFor(lists, excludingId: 'doomed')!.id, 'a');
      expect(
        fallbackTodoListFor(
          lists,
          excludingId: 'doomed',
          defaultTodoListId: 'b',
        )!.id,
        'b',
      );
    });

    test('is null for the last list', () {
      expect(
        fallbackTodoListFor([list('only', 0)], excludingId: 'only'),
        isNull,
      );
    });
  });
}
