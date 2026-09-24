// Schema 125 adds a journal's On this day cadence (ON_THIS_DAY_HLD.md §6).
// An existing database gains it as 'off', and sync carries it both ways
// without an older build's documents resetting it.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/journal_models.dart';

final _now = DateTime.utc(2026, 9, 24, 12);

Journal _journal({OnThisDayCadence cadence = OnThisDayCadence.off}) => Journal(
  id: 'journal-1',
  name: 'Diary',
  createdAt: _now,
  updatedAt: _now,
  onThisDayCadence: cadence,
);

void main() {
  test('124→125 adds the cadence as off and keeps the journal', () async {
    final dir = Directory.systemTemp.createTempSync('voyager_otd_migration');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/voyager.sqlite');

    final seed = AppDatabase(NativeDatabase(file));
    await DriftJournalRepository(seed).upsertJournal(_journal());
    await seed.customStatement(
      'ALTER TABLE journals_table DROP COLUMN on_this_day_cadence',
    );
    await seed.customStatement('PRAGMA user_version = 124');
    await seed.close();

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final journals = await DriftJournalRepository(db).listJournals();
    expect(journals.single.name, 'Diary');
    expect(journals.single.onThisDayCadence, OnThisDayCadence.off);
  });

  test('the repository round-trips every cadence', () async {
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    final repo = DriftJournalRepository(db);
    for (final cadence in OnThisDayCadence.values) {
      await repo.upsertJournal(_journal(cadence: cadence));
      expect((await repo.getJournal('journal-1'))!.onThisDayCadence, cadence);
    }
  });

  test('the mapper round-trips every cadence', () {
    for (final cadence in OnThisDayCadence.values) {
      final payload = journalToFirestore(_journal(cadence: cadence));
      expect(payload['onThisDayCadence'], cadence.name);
      expect(
        mergeJournalFromRemote(payload, 'journal-1').onThisDayCadence,
        cadence,
      );
    }
  });

  test('a document from an older build keeps the local cadence', () {
    final local = _journal(cadence: OnThisDayCadence.yearly);
    final remote = journalToFirestore(local.copyWith(name: 'Renamed elsewhere'))
      ..remove('onThisDayCadence');

    final merged = mergeJournalFromRemote(remote, local.id, local: local);

    expect(merged.name, 'Renamed elsewhere');
    expect(merged.onThisDayCadence, OnThisDayCadence.yearly);
    expect(
      mergeJournalFromRemote(remote, local.id).onThisDayCadence,
      OnThisDayCadence.off,
    );
  });
}
