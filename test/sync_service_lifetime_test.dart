// RemoteSyncService holds state that exists nowhere else: the character
// operations typed since the last upload, the debounced uploads not yet sent,
// and the per-document save chains that keep local writes in order. These pin
// that an ordinary settings change does not throw that state away.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  late AppDatabase db;
  late ProviderContainer container;

  setUp(() async {
    db = AppDatabase.inMemory();
    // The dev OpenWeather client is the one weather client that needs no
    // Firebase app, which lets the real provider run here.
    final settingsRepo = DriftSettingsRepository(db);
    await settingsRepo.saveSettings(
      (await settingsRepo.getSettings()).copyWith(
        devUseDirectOpenWeather: true,
        devOpenWeatherApiKey: 'test-key',
      ),
    );
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
        // The weather client is deliberately not overridden: its provider is
        // part of what the sync service is rebuilt from.
      ],
    );
    await container.read(settingsProvider.future);
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  Future<void> changeAnUnrelatedSetting() async {
    final settings = await container.read(settingsProvider.future);
    await container
        .read(settingsProvider.notifier)
        .saveSettings(settings.copyWith(journalEntryListWidth: 321));
  }

  test('a settings change keeps unsent character operations', () async {
    final service = container.read(remoteSyncServiceProvider);
    service.recordJournalTextChange(
      entryId: 'entry-1',
      before: 'Hello',
      after: 'Hello world',
    );

    await changeAnUnrelatedSetting();

    final current = container.read(remoteSyncServiceProvider);
    expect(
      current.charOpRegistry.takePendingOps(
        FirestoreCollections.journalEntries,
        'entry-1',
      ),
      isNotEmpty,
    );
  });

  test('a settings change keeps live sync listening', () async {
    final liveSync = container.read(liveSyncProvider);
    container.listen(liveSyncProvider, (_, __) {});

    await changeAnUnrelatedSetting();

    expect(identical(container.read(liveSyncProvider), liveSync), isTrue);
  });

  test('live sync started at launch still applies remote changes', () async {
    final syncRepo =
        container.read(syncRepositoryProvider) as InMemorySyncRepository;
    // VoyagerBootstrap._warmUpAfterFirstShellFrame, in order.
    final liveSync = container.read(liveSyncProvider);
    liveSync.start();
    container.invalidate(settingsProvider);
    await container.read(settingsProvider.future);
    await Future<void>.delayed(Duration.zero);

    final now = DateTime.now().toUtc().toIso8601String();
    await syncRepo.upsertDocument(FirestoreCollections.journals, 'journal-9', {
      'id': 'journal-9',
      'name': 'From another device',
      'createdAt': now,
      'updatedAt': now,
      'version': 1,
    });
    await Future<void>.delayed(const Duration(milliseconds: 200));

    final journal = await container
        .read(journalRepositoryProvider)
        .getJournal('journal-9');
    expect(journal?.name, 'From another device');
  });
}
