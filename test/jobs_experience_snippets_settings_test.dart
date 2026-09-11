// The experience snippets behind the Jobs header's copy chips
// (JOBS_EXPERIENCE_SNIPPETS_HLD.md §5, §11): they survive a local save in
// order and byte-for-byte, they travel through the settings document that
// sync and import/export share, and "deleted them all" is not mistaken for
// "this document predates the feature".

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

    await repo.saveSettings(
      (await repo.getSettings()).copyWith(
        jobExperienceSnippets: const [_initech, _acme, _globex],
      ),
    );
    var stored = await repo.getSettings();
    expect(stored.jobExperienceSnippets, const [_initech, _acme, _globex]);

    await repo.saveSettings(stored.copyWith(jobExperienceSnippets: const []));
    stored = await repo.getSettings();
    expect(stored.jobExperienceSnippets, isEmpty);
  });

  group('sync and import/export', () {
    // Both the Firestore document and the backup zip go out through
    // settingsToFirestore and come back through mergeSettingsFromRemote.
    AppSettings roundTrip(AppSettings settings, {AppSettings? into}) {
      return mergeSettingsFromRemote(
        settingsToFirestore(settings),
        into ?? const AppSettings(updatedAt: null),
      );
    }

    test('carries the whole ordered list', () {
      final merged = roundTrip(
        AppSettings(
          jobExperienceSnippets: const [_globex, _initech, _acme],
          updatedAt: DateTime.utc(2026, 9, 10),
        ),
      );
      expect(merged.jobExperienceSnippets, const [_globex, _initech, _acme]);
    });

    test('an emptied list on another device empties it here', () {
      final merged = roundTrip(
        AppSettings(updatedAt: DateTime.utc(2026, 9, 10)),
        into: const AppSettings(jobExperienceSnippets: [_acme]),
      );
      expect(merged.jobExperienceSnippets, isEmpty);
    });

    test('a document predating the feature leaves the local list alone', () {
      const local = AppSettings(jobExperienceSnippets: [_acme]);
      final data = settingsToFirestore(
        AppSettings(updatedAt: DateTime.utc(2026, 9, 10)),
      )..remove('jobExperienceSnippets');
      expect(
        mergeSettingsFromRemote(data, local).jobExperienceSnippets,
        const [_acme],
      );
    });

    test('a malformed entry is dropped without losing the rest', () {
      final data = settingsToFirestore(
        AppSettings(updatedAt: DateTime.utc(2026, 9, 10)),
      );
      data['jobExperienceSnippets'] = [
        _acme.toJson(),
        {'id': 'x', 'name': '   '},
        'junk',
        {'id': 'y', 'name': 'No body'},
      ];
      final merged = mergeSettingsFromRemote(data, const AppSettings());
      expect(merged.jobExperienceSnippets, const [
        _acme,
        JobExperienceSnippet(id: 'y', name: 'No body', description: ''),
      ]);
    });

    test('an edit or a reorder is visible to the last-write-wins clock', () {
      // DriftSettingsRepository.saveSettings compares two of these to decide
      // a synced setting moved; without that the edit never leaves the device.
      String payload(List<JobExperienceSnippet> list) => settingsSyncPayload(
        AppSettings(jobExperienceSnippets: list),
      ).toString();
      expect(payload(const [_acme, _globex]), isNot(payload(const [])));
      expect(
        payload(const [_acme, _globex]),
        isNot(payload(const [_globex, _acme])),
      );
      expect(
        payload(const [_acme]),
        isNot(payload([_acme.copyWith(description: 'changed')])),
      );
    });
  });
}
