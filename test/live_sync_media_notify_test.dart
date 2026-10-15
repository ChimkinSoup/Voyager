// BUG-260: an image another device adds must reach an entry already open here.
// The media widgets reload when [MediaService] notifies, and a pull writes the
// media rows straight to the repository, so live sync has to say so.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/domain/models/media_models.dart';

import 'fakes/fake_weather_api_client.dart';

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  test(
    'a media reference from another device notifies the media service',
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
}
