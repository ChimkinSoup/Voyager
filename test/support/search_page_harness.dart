// Shared setup for tests that drive the real [SearchPage] against an in-memory
// database, mirroring journal_page_harness.dart.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/features/search/search_page.dart';

import '../fakes/fake_weather_api_client.dart';

const searchHarnessJournalId = 'harness-journal';

/// Pumps a real [SearchPage] over an in-memory database holding one journal and
/// [entries], and returns the database so callers can assert what was written.
Future<AppDatabase> pumpSearchPage(
  WidgetTester tester, {
  required List<JournalEntry> Function(DateTime now) entries,
}) async {
  final db = AppDatabase.inMemory();
  addTearDown(db.close);
  final repo = DriftJournalRepository(db);
  final now = DateTime.now().toUtc();
  await repo.upsertJournal(
    Journal(
      id: searchHarnessJournalId,
      name: 'Harness',
      colorValue: 0xFF3366FF,
      createdAt: now,
      updatedAt: now,
    ),
  );
  for (final entry in entries(now)) {
    await repo.upsertEntry(entry);
  }

  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
      // remoteSyncServiceProvider reaches the weather service, whose real
      // client wants a Firebase app.
      weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      // A tall window: the results list and the entry dialog both need room,
      // and the dialog's body field alone is 480 logical pixels.
      child: const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(size: Size(1200, 1400)),
          child: Scaffold(body: SearchPage()),
        ),
      ),
    ),
  );
  await settle(tester);
  return db;
}

/// Pumps a few frames without `pumpAndSettle`, which never completes here: the
/// dialog's entrance is spring-shaped and the shell keeps animations alive.
Future<void> settle(WidgetTester tester, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

/// Unmounts the page and drains the work its dispose kicks off — the same
/// reason [disposeJournalPage] exists.
Future<void> disposeSearchPage(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await settle(tester, frames: 4);
}
