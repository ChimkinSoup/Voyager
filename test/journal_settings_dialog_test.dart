// The per-journal settings sheet reached from the journal dropdown's ⋮ menu.
// Every switch writes through immediately, so the assertions read the database
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
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/features/journal/journal_settings_dialog.dart';

import 'fakes/fake_weather_api_client.dart';

const _firstId = 'journal-one';
const _secondId = 'journal-two';

/// Pumps a page holding one "open" button per journal, over an in-memory
/// database with two journals in it. Both buttons share a container, so a
/// setting written from one journal's sheet is visible from the other's.
Future<AppDatabase> pumpSettingsLauncher(WidgetTester tester) async {
  // Tall enough for all five switch rows: the sheet scrolls when it has to,
  // and a row parked below the fold is one `tester.tap` cannot reach.
  tester.view.physicalSize = const Size(1200, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final db = AppDatabase.inMemory();
  addTearDown(db.close);
  final repo = DriftJournalRepository(db);
  final now = utcNow();
  for (final entry in const [(_firstId, 'First'), (_secondId, 'Second')]) {
    await repo.upsertJournal(
      Journal(
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
  await container.read(journalsProvider.future);
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
                    onPressed: () => showJournalSettingsDialog(
                      context,
                      ref,
                      ref
                          .read(journalsProvider)
                          .value!
                          .firstWhere((j) => j.id == id),
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

Future<void> openSettings(WidgetTester tester, String journalId) async {
  await tester.tap(find.text('open $journalId'));
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

Future<Journal> readJournal(AppDatabase db, String id) async {
  final journals = await DriftJournalRepository(db).listJournals();
  return journals.firstWhere((j) => j.id == id);
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('the four journal toggles start on and default view starts off', (
    tester,
  ) async {
    await pumpSettingsLauncher(tester);
    await openSettings(tester, _firstId);

    expect(find.text('First settings'), findsOneWidget);
    for (final label in [
      'Mood bar',
      'Weather',
      'Quotes',
      'Include in "All journals"',
      'Default view',
    ]) {
      expect(find.widgetWithText(SwitchListTile, label), findsOneWidget);
    }
    final tiles = tester
        .widgetList<SwitchListTile>(find.byType(SwitchListTile))
        .toList();
    expect(tiles.take(4).map((t) => t.value), everyElement(isTrue));
    expect(tiles.last.value, isFalse);
  });

  testWidgets('toggling the mood bar off writes through immediately', (
    tester,
  ) async {
    final db = await pumpSettingsLauncher(tester);
    await openSettings(tester, _firstId);

    await toggle(tester, 'Mood bar');

    expect((await readJournal(db, _firstId)).showMood, isFalse);
    // The other journal is untouched — these are per-journal, not global.
    expect((await readJournal(db, _secondId)).showMood, isTrue);
  });

  testWidgets('opting out of the all-journals view writes through', (
    tester,
  ) async {
    final db = await pumpSettingsLauncher(tester);
    await openSettings(tester, _firstId);

    await toggle(tester, 'Include in "All journals"');

    expect((await readJournal(db, _firstId)).includeInAllView, isFalse);
  });

  testWidgets('the default-view toggle records the journal in settings', (
    tester,
  ) async {
    final db = await pumpSettingsLauncher(tester);
    await openSettings(tester, _firstId);

    await toggle(tester, 'Default view');

    final settings = await DriftSettingsRepository(db).getSettings();
    expect(settings.defaultJournalId, _firstId);
    expect(find.text('The journal page always opens here.'), findsOneWidget);
  });

  testWidgets('turning the default view off clears it', (tester) async {
    final db = await pumpSettingsLauncher(tester);
    await openSettings(tester, _firstId);

    await toggle(tester, 'Default view');
    await toggle(tester, 'Default view');

    expect(
      (await DriftSettingsRepository(db).getSettings()).defaultJournalId,
      isNull,
    );
  });

  testWidgets('another journal names whichever one currently holds the '
      'default', (tester) async {
    final db = await pumpSettingsLauncher(tester);
    await openSettings(tester, _firstId);
    await toggle(tester, 'Default view');
    await closeSettings(tester);

    await openSettings(tester, _secondId);

    expect(find.text('Currently: First'), findsOneWidget);
    // Claiming it moves it wholesale — one field, so no second journal can
    // hold it at the same time.
    await toggle(tester, 'Default view');
    expect(
      (await DriftSettingsRepository(db).getSettings()).defaultJournalId,
      _secondId,
    );
  });
}
