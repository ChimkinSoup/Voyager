// A dream with no detailed log looked the same in the list as a finished one;
// DREAM_JOURNAL.md asks for a subtle sign that it's drafted (BUG-060).

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/dream_models.dart';
import 'package:voyager/features/dream_journal/dream_journal_page.dart';

import 'fakes/fake_weather_api_client.dart';

Future<void> _pump(WidgetTester tester, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Finder _draftOn(String title) => find.descendant(
  of: find.ancestor(of: find.text(title), matching: find.byType(ListTile)),
  matching: find.text('Draft'),
);

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('a dream without a body is marked Draft until one is typed', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    final now = DateTime.now().toUtc();
    // The newest is opened, so the draft is the one in the reading pane.
    for (final (i, (title, body)) in [
      ('Note only', ''),
      ('Logged', 'I flew over the sea.'),
    ].indexed) {
      await DriftDreamRepository(db).upsertEntry(
        DreamEntry(
          id: 'dream-$i',
          title: title,
          body: body,
          entryDate: now.subtract(Duration(hours: i)),
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
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: DreamJournalPage())),
      ),
    );
    await _pump(tester, frames: 12);

    expect(_draftOn('Note only'), findsOneWidget);
    expect(_draftOn('Logged'), findsNothing);

    final body = find.widgetWithText(
      TextField,
      'Describe your dream... use #tags to mark themes',
    );
    await tester.enterText(body, 'Now it has a log.');
    await _pump(tester, frames: 20);

    expect(_draftOn('Note only'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await _pump(tester, frames: 20);
  });
}
