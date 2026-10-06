// On a cold sign-in To-Do opens before the pull brings in the account's
// "Default view" list, and it only read the setting once, so the first launch
// opened on the built-in list (BUG-228). The page now follows a default that
// arrives later — unless the user has picked a view of their own since.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/features/todo/todo_edit_panel.dart';
import 'package:voyager/features/todo/todo_page.dart';

import 'support/todo_page_harness.dart';

Future<void> _frames(WidgetTester tester, [int count = 8]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

/// What the pull does: a repository write, then the providers re-read.
Future<void> _pullDefault(WidgetTester tester, AppDatabase db) async {
  final repo = DriftSettingsRepository(db);
  await repo.saveSettings(
    (await repo.getSettings()).copyWith(
      defaultTodoListId: todoHarnessSecondListId,
    ),
    recordLocalActivity: false,
  );
  ProviderScope.containerOf(
    tester.element(find.byType(TodoPage)),
  ).invalidate(settingsProvider);
  await _frames(tester);
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('a default view that arrives after the page opened is opened', (
    tester,
  ) async {
    final db = await pumpTodoPage(
      tester,
      active: 2,
      done: 0,
      seedSecondList: true,
    );
    expect(find.text(todoHarnessSecondListName), findsNothing);

    await _pullDefault(tester, db);

    expect(find.text(todoHarnessSecondListName), findsOneWidget);
    expect(find.text('Second Task 1'), findsOneWidget);
  });

  testWidgets('a list the user picked is kept when a default arrives later', (
    tester,
  ) async {
    final db = await pumpTodoPage(
      tester,
      active: 2,
      done: 0,
      seedSecondList: true,
    );
    await tester.tap(find.text('Harness').first);
    await _frames(tester);
    await tester.tap(find.text('Harness').last);
    await _frames(tester);

    await _pullDefault(tester, db);

    expect(find.text(todoHarnessSecondListName), findsNothing);
    expect(find.text('Task 0'), findsOneWidget);
  });

  testWidgets('an open edit panel keeps the page where it is when a default '
      'arrives later', (tester) async {
    final db = await pumpTodoPage(
      tester,
      active: 2,
      done: 0,
      seedSecondList: true,
    );
    await tester.tap(find.text('Task 0'));
    await _frames(tester);
    expect(find.byType(TodoEditPanel), findsOneWidget);

    await _pullDefault(tester, db);

    expect(find.text(todoHarnessSecondListName), findsNothing);
    expect(find.byType(TodoEditPanel), findsOneWidget);
  });

  // A deleted default keeps its id so a restore brings it back (BUG-072);
  // until then it must not stop the page reopening its saved "All tasks" view.
  testWidgets('a default whose list is gone leaves the saved All tasks view', (
    tester,
  ) async {
    await pumpTodoPage(
      tester,
      active: 2,
      done: 0,
      showAllTasks: true,
      defaultTodoListId: 'deleted-list',
    );
    await _frames(tester);

    expect(find.text('All tasks'), findsOneWidget);
  });
}
