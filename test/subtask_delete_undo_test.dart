// Deleting a subtask has never asked for confirmation — it is a one-line row —
// and SOFT_DELETE_TOAST.md §5.3 forbids adding a dialog now. The undo toast is
// what makes that safe, and the panel holds its own [_subtasks] list rather
// than re-reading, so the restore has to put the row back into it at the
// position it held.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/features/todo/todo_edit_panel.dart';

import 'fakes/fake_weather_api_client.dart';

const _listId = 'list-1';
const _taskId = 't1';

final _now = DateTime.utc(2026, 1, 1);

TodoTask _parent() => TodoTask(
  id: _taskId,
  listId: _listId,
  title: 'Move house',
  createdAt: _now,
  updatedAt: _now,
);

TodoTask _subtask(int index) => TodoTask(
  id: 'sub-$index',
  listId: _listId,
  parentTaskId: _taskId,
  title: 'Step $index',
  sortOrder: index,
  createdAt: _now,
  updatedAt: _now,
);

Future<DriftTodoRepository> pumpPanel(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1200, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final db = AppDatabase.inMemory();
  addTearDown(db.close);
  final settingsRepo = DriftSettingsRepository(db);
  await settingsRepo.saveSettings(await settingsRepo.getSettings());
  final repo = DriftTodoRepository(db);
  await repo.upsertTask(_parent());
  for (var i = 0; i < 3; i++) {
    await repo.upsertTask(_subtask(i));
  }

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
          body: Center(
            child: SizedBox(
              width: 420,
              height: 900,
              child: TodoEditPanel(
                task: _parent(),
                listColor: 0xFF3366FF,
                onClose: () {},
                onChanged: () {},
                onToggleCompleted: (_) {},
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return repo;
}

/// The titles the panel is currently showing, in the order it shows them.
List<String> visibleSubtasks(WidgetTester tester) => [
  for (var i = 0; i < 3; i++)
    if (find.text('Step $i').evaluate().isNotEmpty) 'Step $i',
];

void main() {
  testWidgets('deleting a subtask toasts without asking first', (tester) async {
    final repo = await pumpPanel(tester);
    expect(visibleSubtasks(tester), ['Step 0', 'Step 1', 'Step 2']);

    await tester.tap(
      find
          .descendant(
            of: find
                .ancestor(of: find.text('Step 1'), matching: find.byType(Row))
                .last,
            matching: find.byIcon(PhosphorIconsBold.dotsThreeVertical),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete subtask'));
    await tester.pumpAndSettle();

    expect(
      find.byType(AlertDialog),
      findsNothing,
      reason: 'a one-line row must not grow a confirm dialog',
    );
    expect(find.text('Deleted "Step 1"'), findsOneWidget);
    expect(visibleSubtasks(tester), ['Step 0', 'Step 2']);
    expect(
      (await repo.listSubtasks(_taskId)).map((t) => t.title),
      isNot(contains('Step 1')),
    );

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();

    final restored = (await repo.listSubtasks(
      _taskId,
    )).where((t) => t.title == 'Step 1');
    expect(restored, hasLength(1));
    expect(restored.single.deletedAt, isNull);
    expect(
      restored.single.version,
      greaterThan(1),
      reason: 'the restore has to outrank the tombstone on the next sync',
    );
    // Back where it was, not appended: the panel orders on sortOrder, and a
    // restored row landing at the bottom would reorder a list nobody touched.
    expect(visibleSubtasks(tester), ['Step 0', 'Step 1', 'Step 2']);
  });
}
