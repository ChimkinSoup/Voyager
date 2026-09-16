// The experience snippets behind the Jobs header's copy chips
// (JOBS_EXPERIENCE_SNIPPETS_HLD.md §5, §11): they survive a local save in
// order and byte-for-byte, and travel as records of their own — no longer
// inside the settings document, whose single clock let a stale device's list
// overwrite newer edits (DATA_INTEGRITY_AUDIT_REPORT.md P1-1).

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/settings_models.dart';

const _acme = JobExperienceSnippet(
  id: 'a',
  name: 'Acme - SWE Intern',
  // Leading/trailing whitespace and a blank line: stored exactly as typed.
  description: '  - Built the billing API.\n\n- Cut p99 by 40%.  \n',
);
const _globex = JobExperienceSnippet(
  id: 'g',
  name: 'Globex - Backend',
  description: '',
);
const _initech = JobExperienceSnippet(
  id: 'i',
  name: 'Initech – “TPS”',
  description: 'Reports…',
);

void main() {
  test('ship empty', () {
    expect(const AppSettings().jobExperienceSnippets, isEmpty);
  });

  test('round-trip through the local database, order and text intact', () async {
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    final repo = DriftSettingsRepository(db);

    await repo.applyJobExperienceSnippetEdit(const [], const [
      _initech,
      _acme,
      _globex,
    ]);
    var stored = await repo.getSettings();
    expect(stored.jobExperienceSnippets, const [_initech, _acme, _globex]);

    await repo.applyJobExperienceSnippetEdit(const [
      _initech,
      _acme,
      _globex,
    ], const [_acme, _globex, _initech]);
    stored = await repo.getSettings();
    expect(stored.jobExperienceSnippets, const [_acme, _globex, _initech]);

    await repo.applyJobExperienceSnippetEdit(
      stored.jobExperienceSnippets,
      const [],
    );
    stored = await repo.getSettings();
    expect(stored.jobExperienceSnippets, isEmpty);
  });

  group('sync and import/export', () {
    test('a record round-trips text and position byte-for-byte', () {
      final record = SyncedListItem(
        item: _acme,
        position: 2.5,
        createdAt: DateTime.utc(2026, 9, 10),
        updatedAt: DateTime.utc(2026, 9, 11),
        version: 2,
      );
      final merged = mergeJobExperienceSnippetFromRemote(
        jobExperienceSnippetToFirestore(record),
        'a',
      )!;
      expect(merged.item, _acme);
      expect(merged.position, 2.5);
    });

    test('a malformed legacy entry is dropped without losing the rest',
        () async {
      final db = AppDatabase.inMemory();
      addTearDown(db.close);
      final legacy = await DriftSettingsRepository(db).unknownLegacySnippets({
        'jobExperienceSnippets': [
          _acme.toJson(),
          {'id': 'x', 'name': '   '},
          'junk',
          {'id': 'y', 'name': 'No body'},
        ],
      });
      expect(legacy.jobExperienceSnippets.map((r) => r.item), const [
        _acme,
        JobExperienceSnippet(id: 'y', name: 'No body', description: ''),
      ]);
    });

    test('the settings document no longer carries the list', () {
      expect(
        settingsSyncPayload(
          const AppSettings(jobExperienceSnippets: [_acme]),
        ).containsKey('jobExperienceSnippets'),
        isFalse,
      );
    });
  });
}
