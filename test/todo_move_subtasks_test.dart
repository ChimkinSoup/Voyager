// Moving a task to another list used to rewrite only the parent's list, so its
// subtasks stayed in the old one, and deleting that list with "delete all
// tasks" then deleted them from under the moved task (BUG-066).

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/widgets/journal_color_flag.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/features/todo/todo_edit_panel.dart';

import 'support/todo_page_harness.dart';

const _parentTitle = 'Parent with subtasks';
const _parentId = 'parent';

Future<void> _pump(WidgetTester tester, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

/// Picks [listName] from the open edit panel's list flag.
Future<void> _moveWithFlag(WidgetTester tester, String listName) async {
  await tester.tap(
    find.descendant(
      of: find.byType(TodoEditPanel),
      matching: find.byType(JournalTitleCornerFlag),
    ),
  );
  await _pump(tester);
  await tester.tap(find.text(listName).last);
  // One frame first, so the page rebuilds the panel with its optimistic copy
  // before the save behind the move gets to read the row (see
  // [_SlowReadTodoRepository]).
  await tester.pump();
  await _pump(tester);
}

/// Reads a task slower than a frame, as the app's database does, so the page
/// rebuilds the panel in the middle of a save.
class _SlowReadTodoRepository extends DriftTodoRepository {
  _SlowReadTodoRepository(super.db);

  @override
  Future<TodoTask?> getTask(String id) async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    return super.getTask(id);
  }
}

Future<AppDatabase> _pumpWithParent(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  return pumpTodoPage(
    tester,
    active: 1,
    done: 0,
    seedSecondList: true,
    extraOverrides: [
      todoRepositoryProvider.overrideWith(
        (ref) => _SlowReadTodoRepository(ref.watch(databaseProvider)),
      ),
    ],
    seedExtra: (repo) async {
      final now = DateTime.now().toUtc();
      await repo.upsertTask(
        TodoTask(
          id: _parentId,
          listId: todoHarnessListId,
          title: _parentTitle,
          createdAt: now,
          updatedAt: now,
          sortOrder: -1000000,
        ),
      );
      for (var i = 0; i < 3; i++) {
        await repo.upsertTask(
          TodoTask(
            id: 'sub-$i',
            listId: todoHarnessListId,
            parentTaskId: _parentId,
            title: 'sub $i',
            createdAt: now,
            updatedAt: now,
            sortOrder: i * 1000,
          ),
        );
      }
    },
  );
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('subtasks follow their parent moved from the edit panel', (
    tester,
  ) async {
    final db = await _pumpWithParent(tester);

    await tester.tap(find.text(_parentTitle));
    await _pump(tester);
    await _moveWithFlag(tester, todoHarnessSecondListName);

    final repo = DriftTodoRepository(db);
    expect((await repo.getTask(_parentId))!.listId, todoHarnessSecondListId);
    final subtasks = await repo.listSubtasks(_parentId);
    expect(subtasks, hasLength(3));
    expect(
      subtasks.map((s) => s.listId),
      everyElement(todoHarnessSecondListId),
    );
    // The old list no longer holds them, so deleting it can't reach them.
    final oldList = await repo.listTasks(
      todoHarnessListId,
      topLevelOnly: false,
    );
    expect(oldList.where((t) => t.parentTaskId == _parentId), isEmpty);
  });

  // The panel stays open on the moved task while the page stays on the old
  // list. Moving it back there used to be decided against the panel's own
  // copy, which by then already carried the destination, so nothing was
  // written (BUG-227).
  testWidgets('moving a task back into the list on screen is saved', (
    tester,
  ) async {
    final db = await _pumpWithParent(tester);
    final repo = DriftTodoRepository(db);

    await tester.tap(find.text(_parentTitle));
    await _pump(tester);
    await _moveWithFlag(tester, todoHarnessSecondListName);
    expect((await repo.getTask(_parentId))!.listId, todoHarnessSecondListId);

    await _moveWithFlag(tester, 'Harness');

    expect((await repo.getTask(_parentId))!.listId, todoHarnessListId);
    expect(
      (await repo.listSubtasks(_parentId)).map((s) => s.listId),
      everyElement(todoHarnessListId),
    );
  });
}
