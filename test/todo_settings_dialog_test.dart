// The per-list settings sheet reached from the todo dropdown's ⋮ menu. Both
// switches write through immediately, so the assertions read the database
// straight after the tap rather than looking for a Save button.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/features/todo/todo_settings_dialog.dart';

import 'fakes/fake_weather_api_client.dart';

const _firstId = 'list-one';
const _secondId = 'list-two';

/// Pumps a page holding one "open" button per list, over an in-memory database
/// with two lists in it. Both buttons share a container, so a setting written
/// from one list's sheet is visible from the other's.
Future<AppDatabase> pumpSettingsLauncher(WidgetTester tester) async {
  final db = AppDatabase.inMemory();
  addTearDown(db.close);
  final repo = DriftTodoRepository(db);
  final now = utcNow();
  for (final entry in const [(_firstId, 'First'), (_secondId, 'Second')]) {
    await repo.upsertList(
      TodoListModel(
        id: entry.$1,
        name: entry.$2,
        colorValue: 0xFF3366FF,
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
      weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
    ],
  );
  addTearDown(container.dispose);
  await container.read(todoListsProvider.future);
  await container.read(settingsProvider.future);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Consumer(
          builder: (context, ref, _) => Scaffold(
            body: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (final id in const [_firstId, _secondId])
                  ElevatedButton(
                    onPressed: () => showTodoListSettingsDialog(
                      context,
                      ref,
                      ref
                          .read(todoListsProvider)
                          .value!
                          .firstWhere((l) => l.id == id),
                    ),
                    child: Text('open $id'),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  return db;
}

Future<void> openSettings(WidgetTester tester, String listId) async {
  await tester.tap(find.text('open $listId'));
  await tester.pumpAndSettle();
}

Future<void> closeSettings(WidgetTester tester) async {
  await tester.tap(find.text('Close'));
  await tester.pumpAndSettle();
}

Future<void> toggle(WidgetTester tester, String label) async {
  await tester.tap(find.widgetWithText(SwitchListTile, label));
  await tester.pumpAndSettle();
}

Future<TodoListModel> readList(AppDatabase db, String id) async {
  final lists = await DriftTodoRepository(db).listLists();
  return lists.firstWhere((l) => l.id == id);
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('the sheet carries exactly the two list toggles', (tester) async {
    await pumpSettingsLauncher(tester);
    await openSettings(tester, _firstId);

    expect(find.text('First settings'), findsOneWidget);
    expect(find.byType(SwitchListTile), findsNWidgets(2));
    // The journal's editor-chrome toggles have no todo equivalent.
    for (final absent in ['Mood bar', 'Weather', 'Quotes']) {
      expect(find.widgetWithText(SwitchListTile, absent), findsNothing);
    }
    final tiles = tester
        .widgetList<SwitchListTile>(find.byType(SwitchListTile))
        .toList();
    expect(tiles.first.value, isTrue);
    expect(tiles.last.value, isFalse);
  });

  testWidgets('opting out of the all-tasks view writes through immediately', (
    tester,
  ) async {
    final db = await pumpSettingsLauncher(tester);
    await openSettings(tester, _firstId);

    await toggle(tester, 'Include in "All tasks"');

    expect((await readList(db, _firstId)).includeInAllView, isFalse);
    // The other list is untouched — these are per-list, not global.
    expect((await readList(db, _secondId)).includeInAllView, isTrue);
  });

  testWidgets('the default-view toggle records the list in settings', (
    tester,
  ) async {
    final db = await pumpSettingsLauncher(tester);
    await openSettings(tester, _firstId);

    await toggle(tester, 'Default view');

    final settings = await DriftSettingsRepository(db).getSettings();
    expect(settings.defaultTodoListId, _firstId);
    expect(find.text('The to-do page always opens here.'), findsOneWidget);
  });

  testWidgets('turning the default view off clears it', (tester) async {
    final db = await pumpSettingsLauncher(tester);
    await openSettings(tester, _firstId);

    await toggle(tester, 'Default view');
    await toggle(tester, 'Default view');

    expect(
      (await DriftSettingsRepository(db).getSettings()).defaultTodoListId,
      isNull,
    );
  });

  testWidgets('another list names whichever one currently holds the default', (
    tester,
  ) async {
    final db = await pumpSettingsLauncher(tester);
    await openSettings(tester, _firstId);
    await toggle(tester, 'Default view');
    await closeSettings(tester);

    await openSettings(tester, _secondId);

    expect(find.text('Currently: First'), findsOneWidget);
    // Claiming it moves it wholesale — one field, so no second list can hold
    // it at the same time.
    await toggle(tester, 'Default view');
    expect(
      (await DriftSettingsRepository(db).getSettings()).defaultTodoListId,
      _secondId,
    );
  });
}
