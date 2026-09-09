import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/services/media_file_store.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/repositories/media_storage.dart';
import 'package:voyager/domain/repositories/repositories.dart';

class _NoopRemoteSync implements RemoteSyncService {
  @override
  noSuchMethod(Invocation invocation) => null;
}

/// Signed out, so a drain parks immediately — this test is about reaching the
/// worker at all, not about what it then does.
class _SignedOutStorage implements MediaStorage {
  @override
  String? get currentUid => null;

  @override
  noSuchMethod(Invocation invocation) => null;
}

/// Keeps the settings row off the database, whose lifetime a test controls
/// and the sync activity controller's own start-up read does not.
class _StubSettingsRepository implements SettingsRepository {
  @override
  Future<AppSettings> getSettings() async => const AppSettings();

  @override
  noSuchMethod(Invocation invocation) => null;
}

Uint8List pngOf(int width, int height) {
  final image = img.Image(width: width, height: height, numChannels: 3);
  img.fill(image, color: img.ColorRgb8(200, 30, 60));
  return img.encodePng(image);
}

void main() {
  late Directory tempDir;
  late AppDatabase db;
  late ProviderContainer container;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('voyager_media_wiring');
    db = AppDatabase.inMemory();
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        settingsRepositoryProvider.overrideWithValue(_StubSettingsRepository()),
        remoteSyncServiceProvider.overrideWithValue(_NoopRemoteSync()),
        mediaStorageProvider.overrideWithValue(_SignedOutStorage()),
        mediaFileStoreProvider.overrideWithValue(
          MediaFileStore(root: Directory('${tempDir.path}/media')),
        ),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await db.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test(
    'an attach can wake the upload queue without tripping a cycle',
    () async {
      // The service's upload scheduler reads the worker, and the worker reads
      // the service back. Watching in either direction makes that an edge
      // Riverpod refuses, and since uploads are on by default the refusal
      // landed on every single attach.
      final service = container.read(mediaServiceProvider);

      final reference = await service.attachBytes(
        bytes: pngOf(8, 8),
        collection: FirestoreCollections.todoTasks,
        documentId: 'task-1',
      );

      expect(reference.documentId, 'task-1');
      expect(
        await service.referencesFor(FirestoreCollections.todoTasks, 'task-1'),
        hasLength(1),
      );
    },
  );

  test('a media change does not throw the worker away mid-drain', () {
    final worker = container.read(mediaTransferWorkerProvider);

    // What every attach, removal and reorder ends with. The worker holds the
    // queue's re-entrancy guards and attempt counts, so being rebuilt here
    // would let a second drain start on an asset already in flight.
    container.read(mediaServiceProvider).notifyChanged();

    expect(container.read(mediaTransferWorkerProvider), same(worker));
  });
}
