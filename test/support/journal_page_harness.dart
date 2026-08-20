// Shared setup for tests that drive the real [JournalPage] against an
// in-memory database, mirroring todo_page_harness.dart.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/features/journal/journal_page.dart';

import '../fakes/fake_weather_api_client.dart';

const journalHarnessId = 'harness-journal';
const journalHarnessName = 'Harness';
const journalHarnessSecondId = 'harness-journal-2';
const journalHarnessSecondName = 'Second';

/// Pumps a real [JournalPage] over an in-memory database holding a single
/// non-default journal with one entry in it.
///
/// Returns the database so callers can assert against what was written. Pass
/// [showAllJournals] to start the page in the "All journals" view the way a
/// restart into that view would. [extraOverrides] is handed the harness
/// database so a caller can swap in an instrumented repository.
///
/// [configureJournal] rewrites the seeded journal before it is saved, which is
/// how per-journal settings tests flip the toggles. [seedSecondJournal] adds a
/// second journal with one entry, so a test can tell the two apart in the
/// all-journals list. [defaultJournalId] seeds the journal the page is
/// supposed to open into regardless of what was last viewed.
Future<AppDatabase> pumpJournalPage(
  WidgetTester tester, {
  bool showAllJournals = false,
  Journal Function(Journal journal)? configureJournal,
  bool seedSecondJournal = false,
  String? defaultJournalId,
  List<Override> Function(AppDatabase db)? extraOverrides,
}) async {
  final db = AppDatabase.inMemory();
  addTearDown(db.close);
  final repo = DriftJournalRepository(db);
  final now = DateTime.now().toUtc();
  final harnessJournal = Journal(
    id: journalHarnessId,
    name: journalHarnessName,
    colorValue: 0xFF3366FF,
    createdAt: now,
    updatedAt: now,
  );
  await repo.upsertJournal(
    configureJournal == null
        ? harnessJournal
        : configureJournal(harnessJournal),
  );
  if (seedSecondJournal) {
    await repo.upsertJournal(
      Journal(
        id: journalHarnessSecondId,
        name: journalHarnessSecondName,
        colorValue: 0xFFFF6633,
        createdAt: now,
        updatedAt: now,
      ),
    );
    await repo.upsertEntry(
      JournalEntry(
        id: 'harness-entry-2',
        journalId: journalHarnessSecondId,
        title: 'Second journal entry',
        body: '',
        entryDate: now,
        timestamp: now,
        createdAt: now,
        updatedAt: now,
      ),
    );
  }
  await repo.upsertEntry(
    JournalEntry(
      id: 'harness-entry',
      journalId: journalHarnessId,
      title: 'Seeded entry',
      body: '',
      entryDate: now,
      timestamp: now,
      createdAt: now,
      updatedAt: now,
    ),
  );

  final settingsRepo = DriftSettingsRepository(db);
  await settingsRepo.saveSettings(
    (await settingsRepo.getSettings()).copyWith(
      lastViewedJournalId: journalHarnessId,
      journalShowAllEntries: showAllJournals,
      defaultJournalId: defaultJournalId,
    ),
  );

  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
      weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
      ...?extraOverrides?.call(db),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: JournalPage())),
    ),
  );
  // Not pumpAndSettle: the page keeps animations alive, so settling never
  // completes.
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
  return db;
}

/// Unmounts the page and drains the work its dispose kicks off.
///
/// [JournalPage.dispose] flushes pending entry edits, which invalidates
/// providers, which schedules a zero-duration timer. Left until teardown that
/// timer outlives the widget tree and trips the pending-timer invariant, so
/// tests take the page down while the binding is still pumping.
Future<void> disposeJournalPage(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}
