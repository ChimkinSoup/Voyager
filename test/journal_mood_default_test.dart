// Mood is no longer a tri-state: an entry is created at the midpoint rather
// than unrecorded, and the v85 migration gave the entries that predated that
// default the same value.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/widgets/mood_gradient_slider.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/journal_models.dart';

import 'support/journal_page_harness.dart';

Future<void> settle(WidgetTester tester, {int frames = 12}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

JournalEntry _entry(
  String id, {
  int? mood,
  DateTime? deletedAt,
  int version = 0,
}) {
  final now = DateTime.utc(2026, 8, 1);
  return JournalEntry(
    id: id,
    journalId: journalHarnessId,
    title: '',
    body: '',
    entryDate: now,
    createdAt: now,
    updatedAt: now,
    version: version,
    deletedAt: deletedAt,
    mood: mood,
  );
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('a new entry is created at the midpoint mood', (tester) async {
    final db = await pumpJournalPage(tester);

    await tester.tap(find.text('New entry'));
    await settle(tester, frames: 20);

    final stored = await DriftJournalRepository(
      db,
    ).listEntries(journalId: journalHarnessId);
    final created = stored.firstWhere((e) => e.id != 'harness-entry');
    expect(created.mood, kDefaultMood);

    await disposeJournalPage(tester);
  });

  testWidgets('the new entry\'s slider reads as recorded, not hollow', (
    tester,
  ) async {
    await pumpJournalPage(tester);

    await tester.tap(find.text('New entry'));
    await settle(tester, frames: 20);

    final slider = tester.widget<MoodGradientSlider>(
      find.byType(MoodGradientSlider),
    );
    expect(slider.value, kDefaultMood);

    await disposeJournalPage(tester);
  });

  group('kJournalMoodBackfillSql', () {
    late AppDatabase db;
    late DriftJournalRepository repo;

    setUp(() async {
      db = AppDatabase.inMemory();
      addTearDown(db.close);
      repo = DriftJournalRepository(db);
    });

    test(
      'gives unrecorded entries the midpoint and bumps their version',
      () async {
        await repo.upsertEntry(_entry('unrecorded', version: 3));
        await db.customStatement(kJournalMoodBackfillSql);

        final stored = (await repo.listEntries()).single;
        expect(stored.mood, kDefaultMood);
        // Without the bump the remote copy — same version, null mood — would
        // re-win on the next pull and read as a hard metadata collision.
        expect(stored.version, 4);
      },
    );

    test('leaves a recorded mood and its version alone', () async {
      await repo.upsertEntry(_entry('recorded', mood: 9, version: 2));
      await db.customStatement(kJournalMoodBackfillSql);

      final stored = (await repo.listEntries()).single;
      expect(stored.mood, 9);
      expect(stored.version, 2);
    });

    test('does not write a mood back onto a tombstone', () async {
      await repo.upsertEntry(
        _entry('tombstone', deletedAt: DateTime.utc(2026, 8, 2), version: 1),
      );
      await db.customStatement(kJournalMoodBackfillSql);

      final stored = (await repo.listEntries(includeDeleted: true)).single;
      expect(stored.mood, isNull);
      expect(stored.version, 1);
    });
  });
}
