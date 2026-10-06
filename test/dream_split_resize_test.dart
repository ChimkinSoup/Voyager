// Shrinking the window animated the dream list from its old width, so for
// 260 ms the editor got whatever was left and its date row overflowed
// (BUG-064).

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

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('the list snaps to the new bound when the window shrinks', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(2000, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    final now = DateTime.now().toUtc();
    await DriftDreamRepository(db).upsertEntry(
      DreamEntry(
        id: 'dream-0',
        title: 'A dream',
        body: 'I flew over the sea.',
        entryDate: now,
        createdAt: now,
        updatedAt: now,
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
        child: const MaterialApp(home: Scaffold(body: DreamJournalPage())),
      ),
    );
    await _pump(tester, frames: 12);

    final list = find
        .ancestor(
          of: find.text('A dream').first,
          matching: find.byType(AnimatedContainer),
        )
        .first;
    final wideWidth = tester.getSize(list).width;

    // At 700 the list's bound is below its 2000-wide default, so it narrows.
    tester.view.physicalSize = const Size(700, 1000);
    await tester.pump();
    expect(tester.takeException(), isNull);
    final firstFrame = tester.getSize(list).width;
    expect(firstFrame, lessThan(wideWidth));
    await _pump(tester);
    expect(tester.getSize(list).width, firstFrame);

    await tester.pumpWidget(const SizedBox.shrink());
    await _pump(tester, frames: 20);
  });
}
