// A repeat picked in the to-do edit panel has to reach the database.
//
// The panel's save path short-circuits when nothing changed, and for a long
// while "changed" only meant title, notes or due date — so every repeat the
// user set was dropped on the floor while the button stayed lit off local
// state. Nothing downstream (the roll-forward on completion) can fire if the
// rule never lands, so it is pinned here at the storage boundary.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/widgets/repeat_selector_popover.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/recurrence_rule.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/features/todo/todo_edit_panel.dart';

import 'fakes/fake_weather_api_client.dart';

const _listId = 'list-1';
const _taskId = 't1';

final _due = DateTime(2026, 3, 2, 9, 30).toUtc();

TodoTask _task({DateTime? dueDate, RecurrenceRule? recurrence}) {
  final now = DateTime.utc(2026, 1, 1);
  return TodoTask(
    id: _taskId,
    listId: _listId,
    title: 'Water the plants',
    createdAt: now,
    updatedAt: now,
    dueDate: dueDate,
    recurrence: recurrence ?? RecurrenceRule.none,
  );
}

/// Pumps the panel over a real database already holding [task].
Future<DriftTodoRepository> _pumpPanel(
  WidgetTester tester,
  TodoTask task,
) async {
  final db = AppDatabase.inMemory();
  addTearDown(db.close);
  final settingsRepo = DriftSettingsRepository(db);
  await settingsRepo.saveSettings(await settingsRepo.getSettings());
  final repo = DriftTodoRepository(db);
  await repo.upsertTask(task);

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
              height: 800,
              child: TodoEditPanel(
                task: task,
                listColor: 0xFF3366FF,
                onClose: () {},
                onChanged: () {},
                onDeleted: () {},
                onToggleStar: () {},
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return repo;
}

void main() {
  testWidgets('picking a repeat writes the rule and its anchor', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final repo = await _pumpPanel(tester, _task(dueDate: _due));

    await tester.tap(find.byIcon(PhosphorIconsRegular.repeat));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Every day'));
    await tester.pumpAndSettle();

    final saved = await repo.getTask(_taskId);
    expect(saved!.recurrence.frequency, EventRecurrence.daily);
    // The anchor is what the roll-forward measures the next due date from.
    expect(saved.recurrenceAnchor, _due);
    expect(saved.repeats, isTrue);
  });

  testWidgets('the repeat toggle is dead while the task has no due date', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _pumpPanel(
      tester,
      // A rule parked by an earlier due-date reset: still stored, still inert.
      _task(recurrence: const RecurrenceRule(frequency: EventRecurrence.weekly)),
    );

    final button = tester.widget<RepeatIconButton>(
      find.byType(RepeatIconButton),
    );
    expect(button.enabled, isFalse);
    expect(
      tester
          .widget<IconButton>(
            find.descendant(
              of: find.byType(RepeatIconButton),
              matching: find.byType(IconButton),
            ),
          )
          .onPressed,
      isNull,
    );

    // Dim, not accented: it must not read as "repeating" when it cannot be.
    final icon = tester.widget<Icon>(
      find.byIcon(PhosphorIconsRegular.repeat),
    );
    expect(icon.color, isNot(const Color(0xFF3366FF)));

    await tester.tap(
      find.byIcon(PhosphorIconsRegular.repeat),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
    expect(find.byType(RepeatSelectorPopover), findsNothing);
  });
}
