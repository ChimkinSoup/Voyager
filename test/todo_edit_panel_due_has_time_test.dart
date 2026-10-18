// Adding 12:00 AM to a date-only due date leaves the instant where it was, so
// the panel's save took it for "nothing changed": the page had already handed
// the panel its optimistic copy, carrying the new flag, before the save
// compared against it. The time showed until the next reload, then was gone.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/widgets/selector_pill.dart';
import 'package:voyager/core/widgets/time_entry_field.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/features/todo/todo_edit_panel.dart';

import 'fakes/fake_weather_api_client.dart';

/// Slow as a background-isolate database can be: the page's rebuild with the
/// optimistic copy lands before the panel's read of the stored row returns.
class _SlowReadRepository extends DriftTodoRepository {
  _SlowReadRepository(super.db);

  @override
  Future<TodoTask?> getTask(String id) async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    return super.getTask(id);
  }
}

void main() {
  testWidgets('12:00 AM added to a date-only due date is saved', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    final settingsRepo = DriftSettingsRepository(db);
    await settingsRepo.saveSettings(await settingsRepo.getSettings());
    final repo = DriftTodoRepository(db);
    final created = DateTime.utc(2026, 1, 1);
    var task = TodoTask(
      id: 't1',
      listId: 'list-1',
      title: 'Take out the bins',
      dueDate: DateTime(2026, 10, 19).toUtc(),
      createdAt: created,
      updatedAt: created,
    );
    await repo.upsertTask(task);

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
        weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
        todoRepositoryProvider.overrideWithValue(_SlowReadRepository(db)),
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
                height: 800,
                // Hands the panel the optimistic copy straight back, as the
                // Todo page does.
                child: StatefulBuilder(
                  builder: (context, setState) => TodoEditPanel(
                    task: task,
                    listColor: 0xFF3366FF,
                    onClose: () {},
                    onChanged: () {},
                    onToggleCompleted: (_) {},
                    onTaskOptimistic: (updated) =>
                        setState(() => task = updated),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byType(SelectorPill).first);
    await tester.pumpAndSettle();
    final timeField = find.descendant(
      of: find.byType(TimeEntryField),
      matching: find.byType(EditableText),
    );
    await tester.tap(timeField);
    await tester.enterText(timeField, '12:00 AM');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    // The picker closes after the next frame, and the page's rebuild with
    // the optimistic copy takes one more; only then does the read return.
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();

    final saved = await repo.getTask('t1');
    expect(saved!.dueHasTime, isTrue);
    expect(saved.dueDate!.toLocal(), DateTime(2026, 10, 19));
  });
}
