// Nav pages can be hidden from the rail. Dev starts hidden; Settings can't be
// hidden; the hidden set follows the user between devices like the order does.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/features/shell/shell_destinations.dart';

List<String> _visiblePaths(AppSettings settings) =>
    getVisibleDestinations(settings).map((d) => d.dest.path).toList();

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  test('Dev is out of the rail until it is shown', () {
    expect(_visiblePaths(const AppSettings()), isNot(contains('/dev')));
    expect(
      _visiblePaths(const AppSettings(hiddenNavPages: [])),
      contains('/dev'),
    );
  });

  test('hidden pages leave the rail and keep their place in the order', () {
    const settings = AppSettings(
      navPageOrder: ['/todo', '/jobs', '/journal'],
      hiddenNavPages: ['/jobs'],
    );
    final visible = _visiblePaths(settings);
    expect(visible, isNot(contains('/jobs')));
    expect(visible.take(2), ['/todo', '/journal']);

    final all = getOrderedDestinations(settings, shellDestinations);
    expect(all.map((d) => d.dest.path).take(3), [
      '/todo',
      '/jobs',
      '/journal',
    ]);
  });

  test('startup lands on the rail\'s first page when the preferred one is '
      'hidden or missing', () {
    const settings = AppSettings(
      navPageOrder: ['/jobs', '/todo'],
      hiddenNavPages: ['/jobs'],
    );
    expect(startupPathFor(settings, '/journal'), '/journal');
    expect(startupPathFor(settings, '/jobs'), '/todo');
    expect(startupPathFor(settings, '/no-such-page'), '/todo');
    expect(startupPathFor(settings, null), '/todo');
  });

  test('the hidden set survives a round trip through the database', () async {
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    final repo = DriftSettingsRepository(db);

    final fresh = await repo.getSettings();
    expect(fresh.hiddenNavPages, defaultHiddenNavPages);

    // Empty is its own answer, not "use the default".
    await repo.saveSettings(fresh.copyWith(hiddenNavPages: []));
    expect((await repo.getSettings()).hiddenNavPages, isEmpty);

    await repo.saveSettings(
      fresh.copyWith(hiddenNavPages: ['/jobs', '/rankings']),
    );
    expect((await repo.getSettings()).hiddenNavPages, ['/jobs', '/rankings']);
  });

  test('the hidden set syncs, and an older device leaves it alone', () {
    final remote = AppSettings(
      hiddenNavPages: const ['/jobs'],
      updatedAt: DateTime.utc(2026, 9, 25, 12),
    );
    final local = AppSettings(updatedAt: DateTime.utc(2026, 9, 25, 11));

    final merged = mergeSettingsFromRemote(settingsToFirestore(remote), local);
    expect(merged.hiddenNavPages, ['/jobs']);

    // A build from before this setting doesn't send the key at all.
    final fromOldBuild = settingsToFirestore(remote)..remove('hiddenNavPages');
    final kept = mergeSettingsFromRemote(
      fromOldBuild,
      local.copyWith(hiddenNavPages: ['/study']),
    );
    expect(kept.hiddenNavPages, ['/study']);
  });
}
