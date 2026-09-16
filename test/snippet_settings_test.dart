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
        snippetsEnabled: false,
        snippetExpandKey: SnippetExpandKey.space,
      );
      await repo.saveSettings(saved);
      await repo.applySnippetEdit(const [], _snippets);
      final read = await repo.getSettings();
      expect(read.snippets, _snippets);
      expect(read.snippetsEnabled, isFalse);
      expect(read.snippetExpandKey, SnippetExpandKey.space);
    });

    test('an emptied list persists as empty rather than reverting', () async {
      await repo.applySnippetEdit(const [], _snippets);
      await repo.applySnippetEdit(_snippets, const []);
      expect((await repo.getSettings()).snippets, isEmpty);
    });
  });

  group('sync and import/export', () {
    // The switch and the expand key travel in the settings document; the list
    // itself travels as records (snippet_records_sync_test.dart).
    test('the settings document carries the switch and the expand key', () {
      final settings = AppSettings(
        snippetsEnabled: false,
        snippetExpandKey: SnippetExpandKey.space,
        updatedAt: DateTime.utc(2026, 8, 16),
      );
      final merged = mergeSettingsFromRemote(
        settingsToFirestore(settings),
        const AppSettings(updatedAt: null),
      );
      expect(merged.snippetsEnabled, isFalse);
      expect(merged.snippetExpandKey, SnippetExpandKey.space);
    });

    test('a remote settings document never touches the local list', () {
      final local = AppSettings(snippets: _snippets);
      final data = settingsToFirestore(
        AppSettings(updatedAt: DateTime.utc(2026, 8, 16)),
      )..['snippets'] = <Object>[];
      expect(mergeSettingsFromRemote(data, local).snippets, _snippets);
    });

    test('a snippet edit does not move the settings clock', () {
      // DriftSettingsRepository.saveSettings compares two of these to move the
      // last-write-wins clock; snippets have their own versions instead.
      expect(
        settingsSyncPayload(const AppSettings()).toString(),
        settingsSyncPayload(AppSettings(snippets: _snippets)).toString(),
      );
    });

    test('an unusable legacy entry is dropped, not the whole list', () async {
      final db = AppDatabase.inMemory();
      addTearDown(db.close);
      final legacy = await DriftSettingsRepository(db).unknownLegacySnippets({
        'snippets': [
          {'trigger': 'no id'},
          for (final snippet in _snippets) snippet.toJson(),
        ],
      });
      expect(legacy.snippets.map((r) => r.item), _snippets);
    });
  });
}
