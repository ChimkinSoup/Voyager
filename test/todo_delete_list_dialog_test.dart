// The delete-list dialog called the destination "To-do" after the built-in
// list was renamed, counted subtasks as tasks, and its "Yes" didn't say what
// it does (BUG-073). Deleting the default-view list also cleared the setting,
// so restoring the list from the trash didn't bring it back (BUG-072).

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/constants/todo_constants.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/todo_models.dart';

import 'support/todo_page_harness.dart';

Future<void> _frames(WidgetTester tester, [int count = 8]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('names the renamed default list, counts top-level tasks, and '
      'keeps the default-view setting', (tester) async {
    final db = await pumpTodoPage(
      tester,
      active: 3,
      done: 1,
      defaultTodoListId: todoHarnessListId,
      seedExtra: (repo) async {
        final now = DateTime.now().toUtc();
        await repo.upsertList(
          TodoListModel(
            id: legacyTodoListId,
            name: 'Inbox',
            createdAt: now,
            updatedAt: now,
          ),
        );
        for (var i = 0; i < 2; i++) {
          await repo.upsertTask(
            TodoTask(
              id: 'sub-$i',
              listId: todoHarnessListId,
              parentTaskId: 'task-00000',
              title: 'Sub $i',
              sortOrder: i,
              createdAt: now,
              updatedAt: now,
            ),
          );
        }
      },
    );

    await tester.tap(find.byTooltip('Manage lists'));
    await _frames(tester);
    final row = find.ancestor(
      of: find.text('Harness').last,
      matching: find.byType(ListTile),
    );
    await tester.tap(
      find.descendant(
        of: row,
        matching: find.byWidgetPredicate((w) => w is PopupMenuButton),
      ),
    );
    await _frames(tester);
    await tester.tap(find.text('Delete').last);
    await _frames(tester);

    expect(
      find.text(
        'This list has 4 tasks. Move them to "Inbox", or delete everything.',
      ),
      findsOneWidget,
    );
    expect(find.text('Move to "Inbox"'), findsOneWidget);
    expect(find.text('Yes'), findsNothing);

    await tester.tap(find.text('Delete all tasks'));
    await _frames(tester);

    final repo = DriftTodoRepository(db);
    final deleted = (await repo.listLists(
      includeDeleted: true,
    )).firstWhere((l) => l.id == todoHarnessListId);
    expect(deleted.deletedAt, isNotNull);
    final settings = await DriftSettingsRepository(db).getSettings();
    expect(settings.defaultTodoListId, todoHarnessListId);
  });

  testWidgets('a list holding only a stranded subtask says so and still offers '
      'the move', (tester) async {
    await pumpTodoPage(
      tester,
      active: 1,
      done: 0,
      seedExtra: (repo) async {
        final now = DateTime.now().toUtc();
        await repo.upsertList(
          TodoListModel(
            id: 'strays',
            name: 'Strays',
            createdAt: now,
            updatedAt: now,
          ),
        );
        // Its task is in the harness list, as a move before BUG-066 left it.
        await repo.upsertTask(
          TodoTask(
            id: 'stray',
            listId: 'strays',
            parentTaskId: 'task-00000',
            title: 'Stray',
            sortOrder: 0,
            createdAt: now,
            updatedAt: now,
          ),
        );
      },
    );

    await tester.tap(find.byTooltip('Manage lists'));
    await _frames(tester);
    final row = find.ancestor(
      of: find.text('Strays').last,
      matching: find.byType(ListTile),
    );
    await tester.tap(
      find.descendant(
        of: row,
        matching: find.byWidgetPredicate((w) => w is PopupMenuButton),
      ),
    );
    await _frames(tester);
    await tester.tap(find.text('Delete').last);
    await _frames(tester);

    expect(
      find.text(
        'This list has no tasks, only 1 subtask of a task elsewhere. Move it '
        'to "To-do", or delete everything.',
      ),
      findsOneWidget,
    );
    expect(find.text('Move to "To-do"'), findsOneWidget);
    expect(find.text('Delete all tasks'), findsOneWidget);

    await tester.tap(find.text('Cancel').last);
    await _frames(tester);
  });
}
