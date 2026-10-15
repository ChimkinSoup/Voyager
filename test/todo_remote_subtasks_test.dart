// BUG-251: subtasks another device adds must show here once live sync brings
// them in — in the row's count and in an open edit panel. The page's subtask
// cache is left alone by its own writes, and the panel read its list once, so
// neither saw them until the user switched lists.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/features/todo/todo_edit_panel.dart';
import 'package:voyager/features/todo/todo_page.dart';

import 'fakes/fake_weather_api_client.dart';
import 'support/todo_page_harness.dart';

final _now = DateTime.utc(2026, 1, 1);

TodoTask _subtask(String parentId, String listId, int index) => TodoTask(
  id: 'sub-$index',
  listId: listId,
  parentTaskId: parentId,
  title: 'Step $index',
  sortOrder: index,
  createdAt: _now,
  updatedAt: _now,
);

/// What live sync does with another device's task: writes the row, then
/// refreshes the providers and moves the remote-tasks epoch on.
Future<void> _arriveFromAnotherDevice(
  WidgetTester tester,
  ProviderContainer container,
  DriftTodoRepository repo,
  TodoTask task,
) async {
  await repo.upsertTask(task, recordLocalActivity: false);
  invalidateAllDataProvidersIn(container);
  container.read(remoteTodoTasksEpochProvider.notifier).state++;
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('the row counts a subtask from another device', (tester) async {
    final db = await pumpTodoPage(
      tester,
      active: 2,
      done: 0,
      seedExtra: (repo) =>
          repo.upsertTask(_subtask('task-00000', todoHarnessListId, 0)),
    );
    expect(find.text('0 | 1'), findsOneWidget);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(TodoPage)),
    );
    await _arriveFromAnotherDevice(
      tester,
      container,
      DriftTodoRepository(db),
      _subtask('task-00000', todoHarnessListId, 1),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }

    expect(find.text('0 | 2'), findsOneWidget);
  });

  testWidgets('an open panel lists a subtask from another device', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    final repo = DriftTodoRepository(db);
    final parent = TodoTask(
      id: 't1',
      listId: 'list-1',
      title: 'Move house',
      createdAt: _now,
      updatedAt: _now,
    );
    await repo.upsertTask(parent);
    await repo.upsertTask(_subtask('t1', 'list-1', 0));
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
        weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
      ],
    );
    addTearDown(container.dispose);
    await container.read(settingsProvider.future);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 420,
              height: 900,
              child: TodoEditPanel(
                task: parent,
                listColor: 0xFF3366FF,
                onClose: () {},
                onChanged: () {},
                onToggleCompleted: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Step 0'), findsOneWidget);

    await _arriveFromAnotherDevice(
      tester,
      container,
      repo,
      _subtask('t1', 'list-1', 1),
    );
    await tester.pumpAndSettle();

    expect(find.text('Step 1'), findsOneWidget);
  });
}
