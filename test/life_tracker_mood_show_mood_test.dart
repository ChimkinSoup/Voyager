// The Life Tracker's lifetime mood average follows each journal's mood bar:
// a journal with `showMood` off keeps its stored moods but stops contributing
// them, and toggling the bar back on re-includes the same values untouched.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/journal_models.dart';

const _journalA = 'journal-a';
const _journalB = 'journal-b';

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  late AppDatabase db;
  late DriftJournalRepository repo;
  late ProviderContainer container;

  setUp(() async {
    db = AppDatabase.inMemory();
    addTearDown(db.close);
    repo = DriftJournalRepository(db);
    final now = utcNow();

    for (final journal in const [(_journalA, true), (_journalB, false)]) {
      await repo.upsertJournal(
        Journal(
          id: journal.$1,
          name: journal.$1,
          createdAt: now,
          updatedAt: now,
          showMood: journal.$2,
        ),
      );
    }
    // A: 4 and 6 (average 5). B: 10, which would pull the average to 20/3.
    for (final entry in const [
      ('a1', _journalA, 4),
      ('a2', _journalA, 6),
      ('b1', _journalB, 10),
    ]) {
      await repo.upsertEntry(
        JournalEntry(
          id: entry.$1,
          createdAt: now,
          updatedAt: now,
          journalId: entry.$2,
          title: '',
          body: '',
          entryDate: now,
          mood: entry.$3,
        ),
      );
    }

    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
      ],
    );
    addTearDown(container.dispose);
  });

  Future<double?> readMood() async {
    final stats = await container.read(lifeTrackerStatsProvider.future);
    return stats.lifetimeMood;
  }

  /// Mirrors the settings sheet: write the journal, then invalidate the list
  /// the stats provider watches.
  Future<void> setShowMood(String journalId, bool value) async {
    final journal = await repo.getJournal(journalId);
    await repo.upsertJournal(journal!.copyWith(showMood: value));
    container.invalidate(journalsProvider);
    await container.read(journalsProvider.future);
  }

  test('only journals with the mood bar on feed the average', () async {
    expect(await readMood(), 5.0);
  });

  test(
    'flipping a journal on re-includes its moods, off drops them again',
    () async {
      expect(await readMood(), 5.0);

      await setShowMood(_journalB, true);
      expect(await readMood(), closeTo(20 / 3, 1e-9));

      await setShowMood(_journalB, false);
      expect(await readMood(), 5.0);

      // Storage never moved: B's entry still carries the mood it was given.
      final entries = await repo.getAllEntries();
      expect(entries.firstWhere((e) => e.id == 'b1').mood, 10);
    },
  );

  test('lifetime mood is null when no journal with moods qualifies', () async {
    await setShowMood(_journalA, false);
    expect(await readMood(), isNull);
  });
}
