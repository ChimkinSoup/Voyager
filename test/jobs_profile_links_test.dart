// The three profile-link settings behind the Jobs header's copy buttons
// (§3.4/§4.7): they survive a local save, they travel through the settings
// document that sync and import/export share, and clearing one propagates
// rather than being read as "unchanged".

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/settings_models.dart';

void main() {
  test('ship unset', () {
    const settings = AppSettings();
    expect(settings.jobProfileLinkedInUrl, isNull);
    expect(settings.jobProfileGitHubUrl, isNull);
    expect(settings.jobProfilePortfolioUrl, isNull);
  });

  test('round-trip through the local database', () async {
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    final repo = DriftSettingsRepository(db);

    await repo.saveSettings(
      (await repo.getSettings()).copyWith(
        jobProfileLinkedInUrl: 'https://linkedin.com/in/juno',
        jobProfileGitHubUrl: 'https://github.com/juno',
        jobProfilePortfolioUrl: 'https://juno.dev',
      ),
    );

    var stored = await repo.getSettings();
    expect(stored.jobProfileLinkedInUrl, 'https://linkedin.com/in/juno');
    expect(stored.jobProfileGitHubUrl, 'https://github.com/juno');
    expect(stored.jobProfilePortfolioUrl, 'https://juno.dev');

    // Clearing a slot is what the Settings dialog does with an emptied field.
    await repo.saveSettings(
      stored.copyWith(clearJobProfileGitHubUrl: true),
    );
    stored = await repo.getSettings();
    expect(stored.jobProfileGitHubUrl, isNull);
    expect(stored.jobProfileLinkedInUrl, 'https://linkedin.com/in/juno');
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

    test('carries all three links', () {
      final merged = roundTrip(
        AppSettings(
          jobProfileLinkedInUrl: 'https://linkedin.com/in/juno',
          jobProfileGitHubUrl: 'https://github.com/juno',
          jobProfilePortfolioUrl: 'https://juno.dev',
          updatedAt: DateTime.utc(2026, 8, 28),
        ),
      );
      expect(merged.jobProfileLinkedInUrl, 'https://linkedin.com/in/juno');
      expect(merged.jobProfileGitHubUrl, 'https://github.com/juno');
      expect(merged.jobProfilePortfolioUrl, 'https://juno.dev');
    });

    test('a slot cleared on another device clears here too', () {
      final merged = roundTrip(
        AppSettings(updatedAt: DateTime.utc(2026, 8, 28)),
        into: const AppSettings(
          jobProfileGitHubUrl: 'https://github.com/juno',
        ),
      );
      expect(merged.jobProfileGitHubUrl, isNull);
    });

    test('a document predating the feature leaves local links alone', () {
      const local = AppSettings(jobProfileGitHubUrl: 'https://github.com/juno');
      final data = settingsToFirestore(
        AppSettings(updatedAt: DateTime.utc(2026, 8, 28)),
      )..remove('jobProfileGitHubUrl');
      expect(
        mergeSettingsFromRemote(data, local).jobProfileGitHubUrl,
        'https://github.com/juno',
      );
    });

    test('a link edit is visible to the last-write-wins clock', () {
      // DriftSettingsRepository.saveSettings compares two of these to decide
      // a synced setting moved; without that the edit never leaves the device.
      const base = AppSettings();
      const edited = AppSettings(
        jobProfileLinkedInUrl: 'https://linkedin.com/in/juno',
      );
      expect(
        settingsSyncPayload(base).toString(),
        isNot(settingsSyncPayload(edited).toString()),
      );
    });
  });
}
