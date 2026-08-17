import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/settings_models.dart';

const _snippets = [
  Snippet(id: 'a', trigger: 'ee', replacement: r'($0)$1', autoExpand: true),
  Snippet(id: 'b', trigger: 'dm', replacement: r'$$0$', wordBoundary: true),
];

void main() {
  group('settings defaults', () {
    test('ships enabled, with Tab as the expand key and an empty list', () {
      const settings = AppSettings();
      expect(settings.snippetsEnabled, isTrue);
      expect(settings.snippetExpandKey, SnippetExpandKey.tab);
      expect(settings.snippets, isEmpty);
    });
  });

  group('local persistence', () {
    late AppDatabase db;
    late DriftSettingsRepository repo;

    setUp(() {
      db = AppDatabase.inMemory();
      repo = DriftSettingsRepository(db);
    });

    tearDown(() => db.close());

    test('a fresh row reads back the defaults', () async {
      final settings = await repo.getSettings();
      expect(settings.snippetsEnabled, isTrue);
      expect(settings.snippetExpandKey, SnippetExpandKey.tab);
      expect(settings.snippets, isEmpty);
    });

    test('round-trips the list and both flags', () async {
      final saved = (await repo.getSettings()).copyWith(
        snippets: _snippets,
        snippetsEnabled: false,
        snippetExpandKey: SnippetExpandKey.space,
      );
      await repo.saveSettings(saved);
      final read = await repo.getSettings();
      expect(read.snippets, _snippets);
      expect(read.snippetsEnabled, isFalse);
      expect(read.snippetExpandKey, SnippetExpandKey.space);
    });

    test('an emptied list persists as empty rather than reverting', () async {
      var settings = (await repo.getSettings()).copyWith(snippets: _snippets);
      await repo.saveSettings(settings);
      settings = (await repo.getSettings()).copyWith(snippets: const []);
      await repo.saveSettings(settings);
      expect((await repo.getSettings()).snippets, isEmpty);
    });
  });

  group('sync and import/export', () {
    // Both the Firestore document and the backup zip are written by
    // settingsToFirestore and read back by mergeSettingsFromRemote, so this
    // covers the round trip for each.
    AppSettings roundTrip(AppSettings settings, {AppSettings? into}) {
      return mergeSettingsFromRemote(
        settingsToFirestore(settings),
        into ?? const AppSettings(updatedAt: null),
      );
    }

    test('carries the list, the switch and the expand key', () {
      final settings = AppSettings(
        snippets: _snippets,
        snippetsEnabled: false,
        snippetExpandKey: SnippetExpandKey.space,
        updatedAt: DateTime.utc(2026, 8, 16),
      );
      final merged = roundTrip(settings);
      expect(merged.snippets, _snippets);
      expect(merged.snippetsEnabled, isFalse);
      expect(merged.snippetExpandKey, SnippetExpandKey.space);
    });

    test('an empty remote list clears the local one', () {
      final local = AppSettings(snippets: _snippets);
      final merged = roundTrip(
        AppSettings(updatedAt: DateTime.utc(2026, 8, 16)),
        into: local,
      );
      expect(merged.snippets, isEmpty);
    });

    test('a document predating snippets leaves the local list alone', () {
      final local = AppSettings(snippets: _snippets);
      final data = settingsToFirestore(
        AppSettings(updatedAt: DateTime.utc(2026, 8, 16)),
      )..remove('snippets');
      final merged = mergeSettingsFromRemote(data, local);
      expect(merged.snippets, _snippets);
    });

    test('the payload is what decides a synced setting changed', () {
      // DriftSettingsRepository.saveSettings compares two of these to move the
      // last-write-wins clock, so a snippet edit has to show up here.
      const base = AppSettings();
      final withSnippets = AppSettings(snippets: _snippets);
      expect(
        settingsSyncPayload(base).toString(),
        isNot(settingsSyncPayload(withSnippets).toString()),
      );
    });

    test('an unusable remote row is dropped, not the whole list', () {
      final data = settingsToFirestore(
        AppSettings(snippets: _snippets, updatedAt: DateTime.utc(2026, 8, 16)),
      );
      (data['snippets'] as List).insert(0, {'trigger': 'no id'});
      final merged = mergeSettingsFromRemote(data, const AppSettings());
      expect(merged.snippets, _snippets);
    });
  });
}
