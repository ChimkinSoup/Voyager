// BUG-260: an image another device adds must reach an entry already open here.
// The media widgets reload when [MediaService] notifies, and a pull writes the
// media rows straight to the repository, so live sync has to say so.

import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/data/services/media_file_store.dart';
import 'package:voyager/domain/models/media_models.dart';
import 'package:voyager/domain/models/settings_models.dart';

import 'fakes/fake_weather_api_client.dart';
import 'media_transfer_test.dart' show FakeMediaStorage;

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  test(
    'a media reference from another device notifies the media service',
    () async {
      final db = AppDatabase.inMemory();
      addTearDown(db.close);
      final temp = await Directory.systemTemp.createTemp('voyager_notify');
      addTearDown(() => temp.delete(recursive: true));
      final server = InMemorySyncRepository();
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          syncRepositoryProvider.overrideWithValue(server),
          weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
          // The change also wakes the prefetch (BUG-263), which reaches for
          // these.
          mediaStorageProvider.overrideWithValue(FakeMediaStorage()),
          mediaFileStoreProvider.overrideWithValue(
            MediaFileStore(root: Directory('${temp.path}/media')),
          ),
        ],
      );
      addTearDown(container.dispose);
      // Off, so no prefetch outlives the test.
      await DriftSettingsRepository(db).saveSettings(
        const AppSettings(mediaBackgroundPrefetchEnabled: false),
      );
      var notified = 0;
      container.read(mediaServiceProvider).addListener(() => notified++);
      container.read(liveSyncProvider).start();

      final now = DateTime.utc(2026, 10, 1);
      await server.upsertDocument(
        FirestoreCollections.mediaReferences,
        'ref-1',
        mediaReferenceToFirestore(
          MediaReference(
            id: 'ref-1',
            mediaId: 'asset-1',
            collection: FirestoreCollections.journalEntries,
            documentId: 'entry-1',
            createdAt: now,
            updatedAt: now,
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(notified, greaterThan(0));
    },
  );

  test('with prefetch on, an image another device adds while this one runs is '
      'downloaded without being shown (BUG-263)', () async {
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    final temp = await Directory.systemTemp.createTemp('voyager_prefetch');
    addTearDown(() => temp.delete(recursive: true));
    final server = InMemorySyncRepository();
    final storage = FakeMediaStorage();
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        syncRepositoryProvider.overrideWithValue(server),
        weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
        mediaStorageProvider.overrideWithValue(storage),
        mediaFileStoreProvider.overrideWithValue(
          MediaFileStore(root: Directory('${temp.path}/media')),
        ),
      ],
    );
    addTearDown(container.dispose);
    await DriftSettingsRepository(
      db,
    ).saveSettings(const AppSettings(mediaBackgroundPrefetchEnabled: true));
    container.read(liveSyncProvider).start();

    final now = DateTime.utc(2026, 10, 1);
    await server.upsertDocument(
      FirestoreCollections.mediaReferences,
      'ref-1',
      mediaReferenceToFirestore(
        MediaReference(
          id: 'ref-1',
          mediaId: 'asset-1',
          collection: FirestoreCollections.journalEntries,
          documentId: 'entry-1',
          createdAt: now,
          updatedAt: now,
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await server.upsertDocument(
      FirestoreCollections.mediaAssets,
      'asset-1',
      mediaAssetToFirestore(
        MediaAsset(
          id: 'asset-1',
          contentHash: 'hash-1',
          byteSize: 10,
          mimeType: 'image/png',
          width: 1,
          height: 1,
          uploadState: MediaUploadState.uploaded,
          createdAt: now,
          updatedAt: now,
        ),
      ),
    );
    // The prefetch first asks the OS for free disk space, which takes a
    // moment.
    for (var i = 0; i < 100 && storage.downloads.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    expect(storage.downloads, ['users/user-1/media/hash-1']);
  });
}
