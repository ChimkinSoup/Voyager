// Shared setup for tests that drive the real [TodoPage] against an in-memory
// database. Used by todo_page_interaction_test.dart (behaviour) and
// todo_page_perf_test.dart (rebuild counts).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/features/todo/todo_page.dart';

import '../fakes/fake_weather_api_client.dart';

const todoHarnessListId = 'harness-list';

/// Seeds [active] incomplete then [done] completed tasks titled `Task 0..n`,
/// already in normalized sort order so the page's normalize pass has nothing
/// to write back mid-test.
Future<void> seedTodoTasks(
  AppDatabase db, {
  required int active,
  required int done,
}) async {
  final repo = DriftTodoRepository(db);
  final now = DateTime.now().toUtc();
  await repo.upsertList(
    TodoListModel(
      id: todoHarnessListId,
      name: 'Harness',
      createdAt: now,
      updatedAt: now,
      colorValue: 0xFF3366FF,
    ),
  );
  for (var i = 0; i < active + done; i++) {
    await repo.upsertTask(
      TodoTask(
        id: 'task-${i.toString().padLeft(5, '0')}',
        listId: todoHarnessListId,
        title: 'Task $i',
        completed: i >= active,
        sortOrder: 1000000 + (i >= active ? i - active : i),
        createdAt: now.add(Duration(seconds: i)),
        updatedAt: now,
      ),
    );
  }
}

/// Pumps a real [TodoPage] over a seeded in-memory database and settles it.
///
/// Returns the database so callers can assert against what was actually
/// written. Pass [showAllTasks] to start the page in the "All tasks" view the
/// way a restart into that view would.
Future<AppDatabase> pumpTodoPage(
  WidgetTester tester, {
  required int active,
  required int done,
  bool completedExpanded = true,
  bool showAllTasks = false,
}) async {
  final db = AppDatabase.inMemory();
  addTearDown(db.close);
  await seedTodoTasks(db, active: active, done: done);
  final settingsRepo = DriftSettingsRepository(db);
  await settingsRepo.saveSettings(
    (await settingsRepo.getSettings()).copyWith(
      todoCompletedSectionExpanded: completedExpanded,
      lastViewedTodoListId: todoHarnessListId,
      todoShowAllTasks: showAllTasks,
    ),
  );

  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
      weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: TodoPage())),
    ),
  );
  // Not pumpAndSettle: the page keeps animations alive, so settling never
  // completes. Six frames is enough for the providers to resolve and the
  // list to lay out.
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
  expect(find.textContaining('Task '), findsWidgets);
  return db;
}
