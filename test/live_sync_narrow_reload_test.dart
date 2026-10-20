// BUG-281: a journal entry arriving from another device reloaded every data
// provider in the app, so a steady trickle of them kept the receiver busy in
// proportion to the whole account. It reloads the journal's providers only.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/domain/models/analytics_models.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/photo_series_models.dart';

import 'fakes/fake_weather_api_client.dart';
import 'support/counting_journal_repository.dart';

JournalEntry _entry(String id) {
  final now = DateTime.utc(2026, 10, 14);
  return JournalEntry(
    id: id,
    journalId: 'journal-1',
    title: 'From B',
    body: 'body',
    entryDate: now,
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  test(
    'a remote journal entry reloads the journal lists and nothing else',
    () async {
      final db = AppDatabase.inMemory();
      addTearDown(db.close);
      final server = InMemorySyncRepository();
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          syncRepositoryProvider.overrideWithValue(server),
          weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
        ],
      );
      addTearDown(container.dispose);
      final entries = container.listen(
        journalListEntriesProvider(allJournalEntriesScope),
        (_, _) {},
      );
      var todoReloads = 0;
      container.listen(todoListsProvider, (_, _) => todoReloads++);
      await container.read(todoListsProvider.future);
      await container.read(
        journalListEntriesProvider(allJournalEntriesScope).future,
      );
      todoReloads = 0;
      container.read(liveSyncProvider).start();

      final now = DateTime.utc(2026, 10, 14);
      await server.upsertDocument(
        FirestoreCollections.journalEntries,
        'entry-1',
        journalEntryToFirestore(
          JournalEntry(
            id: 'entry-1',
            journalId: 'journal-1',
            title: 'From B',
            body: 'body',
            entryDate: now,
            createdAt: now,
            updatedAt: now,
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await container.read(
        journalListEntriesProvider(allJournalEntriesScope).future,
      );

      expect(entries.read().value?.map((e) => e.id), ['entry-1']);
      expect(todoReloads, 0);
    },
  );

  // BUG-312: Photo Series' pages read a stream of the database, so its rows
  // arriving reloaded the rest of the app for nothing, twice per check-in.
  test('a remote photo check-in reloads no data provider of another '
      'page', () async {
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    final server = InMemorySyncRepository();
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        syncRepositoryProvider.overrideWithValue(server),
        weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
      ],
    );
    addTearDown(container.dispose);
    var todoReloads = 0;
    container.listen(todoListsProvider, (_, _) => todoReloads++);
    await container.read(todoListsProvider.future);
    todoReloads = 0;
    container.read(liveSyncProvider).start();

    final now = DateTime.utc(2026, 10, 20);
    await server.upsertDocument(
      FirestoreCollections.photoCheckIns,
      'check-in-1',
      photoCheckInToFirestore(
        PhotoCheckIn(
          id: 'check-in-1',
          seriesId: 'series-1',
          takenOn: now,
          createdAt: now,
          updatedAt: now,
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(
      await DriftPhotoSeriesRepository(db).getCheckIn('check-in-1'),
      isNotNull,
    );
    expect(todoReloads, 0);
  });

  test('a remote journal entry reads the entries table once, not once per '
      'provider', () async {
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    final server = InMemorySyncRepository();
    final repo = CountingJournalRepository(DriftJournalRepository(db));
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        syncRepositoryProvider.overrideWithValue(server),
        weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
        journalRepositoryProvider.overrideWithValue(repo),
      ],
    );
    addTearDown(container.dispose);
    // What the journal page and the analytics trackers keep alive.
    final watched = <ProviderListenable<AsyncValue<Object?>>>[
      journalListEntriesProvider(allJournalEntriesScope),
      allJournalEntriesProvider,
      journalAllEntryIdsProvider,
      trackerValuesProvider(kJournalEntriesTrackerId),
    ];
    for (final p in watched) {
      container.listen(p, (_, _) {});
    }
    await container.read(
      trackerValuesProvider(kJournalEntriesTrackerId).future,
    );
    await container.read(journalAllEntryIdsProvider.future);
    container.read(liveSyncProvider).start();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    repo.resetCounts();

    await server.upsertDocument(
      FirestoreCollections.journalEntries,
      'entry-1',
      journalEntryToFirestore(_entry('entry-1')),
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final days = await container.read(
      trackerValuesProvider(kJournalEntriesTrackerId).future,
    );

    expect(days, hasLength(1));
    expect(await container.read(journalAllEntryIdsProvider.future), {
      'entry-1',
    });
    expect(repo.unlimitedListEntriesCalls, 1);
    expect(repo.getAllEntriesCalls, 0);
  });
}
