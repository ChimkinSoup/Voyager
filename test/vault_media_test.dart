import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:voyager/core/secure_vault/secure_vault.dart';
import 'package:voyager/core/secure_vault/vault_media_service.dart';
import 'package:voyager/core/soft_delete/erasure.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/core/sync/local_account_store.dart';
import 'package:voyager/core/sync/note_sync.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/data/services/vault_media_file_store.dart';
import 'package:voyager/features/settings/services/backup_collections.dart';
import 'package:voyager/features/settings/services/data_export_service.dart';
import 'package:voyager/features/settings/services/data_import_service.dart';
import 'package:voyager/domain/models/media_models.dart';
import 'package:voyager/domain/models/photo_series_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/repositories/media_storage.dart';
import 'package:voyager/domain/services/media_ingest.dart';

/// A photo-like JPEG: noisy enough that the encoder can't shrink it to
/// nothing, large enough to be downscaled.
Uint8List jpegOf(int width, int height) {
  final image = img.Image(width: width, height: height);
  for (final pixel in image) {
    pixel
      ..r = (pixel.x * 7) % 256
      ..g = (pixel.y * 3) % 256
      ..b = (pixel.x ^ pixel.y) % 256;
  }
  return img.encodeJpg(image);
}

class _Storage implements MediaStorage {
  final objects = <String, Uint8List>{};
  final mimeTypes = <String, String>{};
  final downloads = <String>[];
  final deletes = <String>[];

  /// When true every delete throws, as one made offline does.
  bool failDeletes = false;

  @override
  String? get currentUid => 'user-1';

  @override
  Future<void> upload(String path, Uint8List bytes, String mimeType) async {
    objects[path] = bytes;
    mimeTypes[path] = mimeType;
  }

  @override
  Future<Uint8List> download(String path) async {
    downloads.add(path);
    final bytes = objects[path];
    if (bytes == null) {
      throw const MediaStoragePermanentFailure('object not found');
    }
    return bytes;
  }

  @override
  Future<void> delete(String path) async {
    if (failDeletes) throw StateError('offline');
    deletes.add(path);
    objects.remove(path);
  }
}

class _Device {
  _Device(this.storage, Directory dir, {required this.settings}) {
    db = AppDatabase.inMemory();
    repository = DriftPhotoSeriesRepository(db);
    files = VaultMediaFileStore(root: dir);
    service = VaultMediaService(
      repository: repository,
      fileStore: files,
      storage: storage,
      readSettings: () async => settings(),
    );
  }

  final _Storage storage;
  final AppSettings Function() settings;
  late final AppDatabase db;
  late final DriftPhotoSeriesRepository repository;
  late final VaultMediaFileStore files;
  late final VaultMediaService service;
}

void main() {
  late Directory temp;
  late _Storage storage;
  late AppSettings settings;
  late _Device a;
  late _Device b;
  late SecretKey key;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('voyager_vault_media');
    storage = _Storage();
    settings = const AppSettings();
    a = _Device(storage, Directory('${temp.path}/a'), settings: () => settings);
    b = _Device(storage, Directory('${temp.path}/b'), settings: () => settings);
    key = (await SecureVault.create(
      'correct horse',
      vaultId: 'vault-1',
      now: DateTime.utc(2026, 10, 18),
    )).key;
  });

  tearDown(() async {
    // Ingest starts an upload it doesn't wait for.
    await a.service.drain();
    await b.service.drain();
    await a.db.close();
    await b.db.close();
    await temp.delete(recursive: true);
  });

  /// [a]'s blob as [b] learns of it from the synced document.
  Future<VaultBlob> pullInto(_Device device, VaultBlob blob) async {
    final current = (await a.repository.getBlob(blob.id))!;
    final merged = mergeVaultBlobFromRemote(
      vaultBlobToFirestore(current),
      blob.id,
    );
    await device.repository.upsertBlob(merged, recordLocalActivity: false);
    return merged;
  }

  test('ingest seals the image and a 384 px thumbnail', () async {
    settings = settings.copyWith(mediaRemoteUploadsEnabled: false);
    final blob = await a.service.ingest(
      jpegOf(3000, 2000),
      key: key,
      vaultId: 'vault-1',
    );
    expect((blob.width, blob.height), (maxIngestEdgePx, 1365));
    expect(blob.uploadState, MediaUploadState.localOnly);

    final full = await a.service.open(blob, key, thumb: false);
    final thumb = await a.service.open(blob, key, thumb: true);
    final decodedFull = img.decodeImage(full!)!;
    final decodedThumb = img.decodeImage(thumb!)!;
    expect((decodedFull.width, decodedFull.height), (2048, 1365));
    expect((decodedThumb.width, decodedThumb.height), (384, 256));
  });

  test('nothing decodable is left on disk', () async {
    final blob = await a.service.ingest(
      jpegOf(800, 600),
      key: key,
      vaultId: 'vault-1',
    );
    final onDisk = [
      for (final entity in await Directory(
        '${temp.path}/a',
      ).list(recursive: true).toList())
        if (entity is File) entity,
    ];
    expect(onDisk.map((f) => f.uri.pathSegments.last), {
      blob.id,
      '${blob.id}.thumb',
    });
    for (final file in onDisk) {
      final bytes = await file.readAsBytes();
      expect(sniffImageFormat(bytes), SniffedImageFormat.unknown);
      expect(img.decodeImage(bytes), isNull);
    }
    expect(await File('${temp.path}/a/${blob.id}').length(), blob.byteSize);
  });

  test('a blob opens only under its own vault key', () async {
    final blob = await a.service.ingest(
      jpegOf(200, 200),
      key: key,
      vaultId: 'vault-1',
    );
    final other = (await SecureVault.create(
      'x',
      vaultId: 'vault-1',
      now: DateTime.utc(2026, 10, 18),
    )).key;
    expect(await a.service.open(blob, other, thumb: true), isNull);
  });

  test(
    'uploads both files as opaque bytes and says so to other devices',
    () async {
      final blob = await a.service.ingest(
        jpegOf(400, 300),
        key: key,
        vaultId: 'vault-1',
      );
      await a.service.drainUploads();

      expect(storage.objects.keys, {
        'users/user-1/vault_media/${blob.id}',
        'users/user-1/vault_media/${blob.id}.thumb',
      });
      expect(storage.mimeTypes.values.toSet(), {vaultBlobMimeType});
      final uploaded = (await a.repository.getBlob(blob.id))!;
      expect(uploaded.uploadState, MediaUploadState.uploaded);
      expect(uploaded.version, blob.version + 1);
      expect(vaultBlobToFirestore(uploaded)['inCloud'], isTrue);
    },
  );

  test('another device fetches thumbnails eagerly, full images on prefetch '
      'or when opened', () async {
    final blob = await a.service.ingest(
      jpegOf(400, 300),
      key: key,
      vaultId: 'vault-1',
    );
    await a.service.drainUploads();

    settings = settings.copyWith(mediaBackgroundPrefetchEnabled: false);
    final learned = await pullInto(b, blob);
    expect(learned.downloadState, MediaDownloadState.missing);
    expect(learned.thumbDownloadState, MediaDownloadState.missing);

    await b.service.drainDownloads();
    var here = (await b.repository.getBlob(blob.id))!;
    expect(here.thumbDownloadState, MediaDownloadState.present);
    expect(here.downloadState, MediaDownloadState.missing);
    expect(await b.service.open(here, key, thumb: true), isNotNull);

    final full = await b.service.open(here, key, thumb: false);
    expect(img.decodeImage(full!)!.width, 400);
    here = (await b.repository.getBlob(blob.id))!;
    expect(here.downloadState, MediaDownloadState.present);
  });

  test('a download of the wrong size parks the blob', () async {
    final blob = await a.service.ingest(
      jpegOf(400, 300),
      key: key,
      vaultId: 'vault-1',
    );
    await a.service.drainUploads();
    await pullInto(b, blob);
    storage.objects['users/user-1/vault_media/${blob.id}.thumb'] = Uint8List(
      10,
    );

    await b.service.drainDownloads();
    final here = (await b.repository.getBlob(blob.id))!;
    expect(here.thumbDownloadState, MediaDownloadState.failed);
    expect(here.downloadState, MediaDownloadState.present);
  });

  test('a blob only on another device is not fetched', () async {
    settings = settings.copyWith(mediaRemoteUploadsEnabled: false);
    final blob = await a.service.ingest(
      jpegOf(100, 100),
      key: key,
      vaultId: 'vault-1',
    );
    final learned = await pullInto(b, blob);
    expect(learned.isOnlyElsewhere, isTrue);
    expect(await b.service.open(learned, key, thumb: true), isNull);
  });

  test('uploads turned on later send what was kept local', () async {
    settings = settings.copyWith(mediaRemoteUploadsEnabled: false);
    final blob = await a.service.ingest(
      jpegOf(100, 100),
      key: key,
      vaultId: 'vault-1',
    );
    expect(storage.objects, isEmpty);
    settings = settings.copyWith(mediaRemoteUploadsEnabled: true);
    await a.service.queueLocalOnlyUploads();
    expect(
      (await a.repository.getBlob(blob.id))!.uploadState,
      MediaUploadState.uploaded,
    );
    expect(storage.objects, hasLength(2));
  });

  test('the purge deletes expired blobs here and in Storage', () async {
    final blob = await a.service.ingest(
      jpegOf(100, 100),
      key: key,
      vaultId: 'vault-1',
    );
    await a.service.drainUploads();
    final now = DateTime.now().toUtc();
    await a.service.softDelete(blob.id, now.subtract(const Duration(days: 31)));

    await a.service.purgeExpired(now);
    expect(await a.repository.getBlob(blob.id), isNull);
    expect(await a.files.read(blob.id, thumb: false), isNull);
    expect(await a.files.read(blob.id, thumb: true), isNull);
    expect(storage.objects, isEmpty);
  });

  test('a recent tombstone survives the purge', () async {
    final blob = await a.service.ingest(
      jpegOf(100, 100),
      key: key,
      vaultId: 'vault-1',
    );
    final now = DateTime.now().toUtc();
    await a.service.softDelete(blob.id, now);
    await a.service.purgeExpired(now);
    expect(await a.repository.getBlob(blob.id), isNotNull);
    expect(await a.files.read(blob.id, thumb: true), isNotNull);
  });

  test('a purge that cannot reach Storage owes the deletes', () async {
    final blob = await a.service.ingest(
      jpegOf(100, 100),
      key: key,
      vaultId: 'vault-1',
    );
    await a.service.drainUploads();
    final now = DateTime.now().toUtc();
    await a.service.softDelete(blob.id, now.subtract(const Duration(days: 31)));

    storage.failDeletes = true;
    await a.service.purgeExpired(now);
    expect(await a.repository.getBlob(blob.id), isNull);
    expect(storage.objects, hasLength(2));
    expect(await a.repository.listPendingRemoteDeletes(), hasLength(2));

    storage.failDeletes = false;
    await a.service.drain();
    expect(storage.objects, isEmpty);
    expect(await a.repository.listPendingRemoteDeletes(), isEmpty);
  });

  test('retry brings a parked photo back', () async {
    final blob = await a.service.ingest(
      jpegOf(400, 300),
      key: key,
      vaultId: 'vault-1',
    );
    await a.service.drainUploads();
    await pullInto(b, blob);
    final thumbPath = 'users/user-1/vault_media/${blob.id}.thumb';
    final thumbBytes = storage.objects[thumbPath]!;
    storage.objects[thumbPath] = Uint8List(10);
    await b.service.drainDownloads();
    final parked = (await b.repository.getBlob(blob.id))!;
    expect(parked.thumbDownloadState, MediaDownloadState.failed);

    storage.objects[thumbPath] = thumbBytes;
    await b.service.retry(parked);
    expect(
      (await b.repository.getBlob(blob.id))!.thumbDownloadState,
      MediaDownloadState.present,
    );
    expect(await b.service.open(parked, key, thumb: true), isNotNull);
  });

  test('a restored blob new to this device is not fetched', () async {
    final blob = await a.service.ingest(
      jpegOf(100, 100),
      key: key,
      vaultId: 'vault-1',
    );
    await a.service.drainUploads();
    final collection = _collections(
      b.db,
    ).singleWhere((c) => c.name == FirestoreCollections.vaultBlobs);
    final record =
        (await _collections(a.db)
                .singleWhere((c) => c.name == FirestoreCollections.vaultBlobs)
                .read())
            .single;
    await collection.restore(record.id, record.data);

    final restored = (await b.repository.getBlob(blob.id))!;
    expect(restored.uploadState, MediaUploadState.localOnly);
    expect(restored.isOnlyElsewhere, isTrue);
    await b.service.drainDownloads();
    expect(storage.downloads, isEmpty);
  });

  test('a thumbnail is never larger than its image', () async {
    settings = settings.copyWith(mediaRemoteUploadsEnabled: false);
    final blob = await a.service.ingest(
      jpegOf(200, 150),
      key: key,
      vaultId: 'vault-1',
    );
    final thumb = img.decodeImage(
      (await a.service.open(blob, key, thumb: true))!,
    )!;
    expect((thumb.width, thumb.height), (200, 150));
  });

  test('a purge mid-ingest leaves the new files alone', () async {
    late final VaultMediaService service;
    var purged = false;
    service = VaultMediaService(
      repository: a.repository,
      fileStore: a.files,
      storage: storage,
      // Ingest reads the settings between writing its files and its row.
      readSettings: () async {
        if (!purged) {
          purged = true;
          await service.purgeExpired(DateTime.now().toUtc());
        }
        return settings;
      },
    );
    final blob = await service.ingest(
      jpegOf(100, 100),
      key: key,
      vaultId: 'vault-1',
    );
    await service.drain();
    expect(await a.files.read(blob.id, thumb: false), isNotNull);
    expect(await a.files.read(blob.id, thumb: true), isNotNull);
    expect(storage.objects, hasLength(2));
  });

  test(
    "this device's blob with its files lost is not marked uploaded",
    () async {
      settings = settings.copyWith(mediaRemoteUploadsEnabled: false);
      final blob = await a.service.ingest(
        jpegOf(100, 100),
        key: key,
        vaultId: 'vault-1',
      );
      await a.files.delete(blob.id);
      settings = settings.copyWith(mediaRemoteUploadsEnabled: true);
      await a.service.queueLocalOnlyUploads();

      final after = (await a.repository.getBlob(blob.id))!;
      expect(after.uploadState, MediaUploadState.failed);
      expect(vaultBlobToFirestore(after)['inCloud'], isFalse);
      expect(storage.objects, isEmpty);
    },
  );

  test("a reset retires the old vault's blobs", () async {
    final old = await a.service.ingest(
      jpegOf(100, 100),
      key: key,
      vaultId: 'vault-1',
    );
    final kept = await a.service.ingest(
      jpegOf(100, 100),
      key: key,
      vaultId: 'vault-2',
    );
    final notes = DriftNotificationRepository(a.db);
    final header = (await SecureVault.create(
      'new',
      vaultId: 'vault-2',
      now: DateTime.utc(2026, 10, 18),
      headerVersion: 2,
      retiredVaultIds: ['vault-1'],
    )).header;
    await notes.saveSecureVaultHeader(
      header.toJson(),
      vaultId: header.vaultId,
      headerVersion: header.headerVersion,
    );

    expect(await retireVaultBlobs(notes, a.repository), 1);
    expect((await a.repository.getBlob(old.id))!.deletedAt, isNotNull);
    expect((await a.repository.getBlob(kept.id))!.deletedAt, isNull);
    expect(await retireVaultBlobs(notes, a.repository), 0);
  });

  test('a purge deletes the thumbnail a failed upload left', () async {
    final blob = await a.service.ingest(
      jpegOf(100, 100),
      key: key,
      vaultId: 'vault-1',
    );
    await a.service.drainUploads();
    // The thumbnail went up, the full image didn't, and the upload parked.
    storage.objects.remove('users/user-1/vault_media/${blob.id}');
    await a.repository.updateBlobTransferState(
      blob.id,
      uploadState: MediaUploadState.failed,
    );
    final now = DateTime.now().toUtc();
    await a.service.softDelete(blob.id, now.subtract(const Duration(days: 31)));

    await a.service.purgeExpired(now);
    expect(storage.objects, isEmpty);
    expect(await a.repository.listPendingRemoteDeletes(), isEmpty);
  });

  test('a file recorded as here but lost from disk is fetched again', () async {
    final blob = await a.service.ingest(
      jpegOf(400, 300),
      key: key,
      vaultId: 'vault-1',
    );
    await a.service.drainUploads();
    await pullInto(b, blob);
    await b.service.drainDownloads();
    await b.files.delete(blob.id);

    final here = (await b.repository.getBlob(blob.id))!;
    expect(here.thumbDownloadState, MediaDownloadState.present);
    expect(await b.service.open(here, key, thumb: true), isNotNull);
  });

  test('photos not yet in Storage count as unsynced for a wipe', () async {
    settings = settings.copyWith(mediaRemoteUploadsEnabled: false);
    await a.service.ingest(jpegOf(100, 100), key: key, vaultId: 'vault-1');
    final store = LocalAccountStore(
      a.db,
      dataDirectory: () async => temp,
      backupsRoot: () async => temp,
    );
    // The blob row's own outbox entry, and its files.
    final queued = await a.db.select(a.db.pendingUploadsTable).get();
    expect(await store.unsyncedChanges(), queued.length + 1);
  });

  group('backups', () {
    Future<File> export(_Device device, String name) async {
      final contents = await DataExportService(
        db: device.db,
        collections: _collections(device.db),
        settingsRepository: DriftSettingsRepository(device.db),
        vaultMedia: device.service,
      ).buildArchiveContents();
      return File('${temp.path}/$name.zip')
        ..writeAsBytesSync(generateBackupZipIsolate(contents));
    }

    DataImportService importer(
      _Device device, {
      Map<String, List<Object>>? pushed,
      Map<String, List<Object>>? dropped,
    }) => DataImportService(
      db: device.db,
      collections: _collections(device.db),
      settingsRepository: DriftSettingsRepository(device.db),
      pushRecords: (collection, records) async =>
          pushed?.putIfAbsent(collection, () => []).addAll(records),
      pushSettings: (_) async {},
      dropRecords: (collection, records) async =>
          dropped?.putIfAbsent(collection, () => []).addAll(records),
      vaultMedia: device.service,
    );

    // The ZIP held the rows only, so on another account every photo was
    // an empty frame for good.
    test('BUG-295: a backup carries the photos, and a restore on another '
        'account sends them to its Storage', () async {
      settings = settings.copyWith(mediaRemoteUploadsEnabled: false);
      final blob = await a.service.ingest(
        jpegOf(100, 100),
        key: key,
        vaultId: 'vault-1',
      );
      final pushed = <String, List<Object>>{};
      await importer(b, pushed: pushed).importFromZip(await export(a, 'a'));

      final restored = (await b.repository.getBlob(blob.id))!;
      expect(restored.hasLocalBytes, isTrue);
      expect(restored.hasLocalThumb, isTrue);
      expect(restored.uploadState, MediaUploadState.localOnly);
      expect(await b.service.open(restored, key, thumb: false), isNotNull);
      // Published as here, so the restore doesn't ask the server about it.
      final published =
          pushed[FirestoreCollections.vaultBlobs]!.single as VaultBlob;
      expect(published.hasLocalBytes, isTrue);

      settings = settings.copyWith(mediaRemoteUploadsEnabled: true);
      await b.service.queueLocalOnlyUploads();
      expect(storage.objects.keys, {
        'users/user-1/vault_media/${blob.id}',
        'users/user-1/vault_media/${blob.id}.thumb',
      });
    });

    // The account was left with a vault, and a password, it never had.
    test('BUG-297: undoing an import takes back the vault it brought, unless '
        'a photo is sealed under it since', () async {
      final notes = DriftNotificationRepository(a.db);
      final header = (await SecureVault.create(
        'correct horse',
        vaultId: 'vault-1',
        now: DateTime.utc(2026, 10, 18),
      )).header;
      await notes.saveSecureVaultHeader(
        header.toJson(),
        vaultId: header.vaultId,
        headerVersion: header.headerVersion,
      );
      await a.service.ingest(jpegOf(100, 100), key: key, vaultId: 'vault-1');
      final backup = await export(a, 'a');
      final before = await export(b, 'b-before');
      final bNotes = DriftNotificationRepository(b.db);

      final summary = await importer(b).importFromZip(backup);
      expect(await bNotes.getSecureVaultHeader(), isNotNull);

      // A photo taken under the imported vault since keeps it.
      final kept = await b.service.ingest(
        jpegOf(100, 100),
        key: key,
        vaultId: 'vault-1',
      );
      final dropped = <String, List<Object>>{};
      await importer(
        b,
        dropped: dropped,
      ).importFromZip(before, deleteCreated: summary.created);
      expect(await bNotes.getSecureVaultHeader(), isNotNull);
      expect(dropped, isEmpty);

      // In the trash it keeps it too: restored, it must still open.
      await b.service.softDelete(kept.id, DateTime.now().toUtc());
      await importer(
        b,
        dropped: dropped,
      ).importFromZip(before, deleteCreated: summary.created);
      expect(await bNotes.getSecureVaultHeader(), isNotNull);
      expect(dropped, isEmpty);

      // Deleted forever, nothing needs it.
      await b.repository.upsertBlob(
        (await b.repository.getBlob(kept.id))!.copyWith(deletedAt: kErasedAt),
      );
      await importer(
        b,
        dropped: dropped,
      ).importFromZip(before, deleteCreated: summary.created);
      expect(await bNotes.getSecureVaultHeader(), isNull);
      expect(
        (dropped[FirestoreCollections.secureVault]!.single as Map)['vaultId'],
        'vault-1',
      );
    });

    test('BUG-297: undoing an import leaves a vault reset since', () async {
      final notes = DriftNotificationRepository(a.db);
      final header = (await SecureVault.create(
        'correct horse',
        vaultId: 'vault-1',
        now: DateTime.utc(2026, 10, 18),
      )).header;
      await notes.saveSecureVaultHeader(
        header.toJson(),
        vaultId: header.vaultId,
        headerVersion: header.headerVersion,
      );
      final backup = await export(a, 'a');
      final before = await export(b, 'b-before');
      final bNotes = DriftNotificationRepository(b.db);
      final summary = await importer(b).importFromZip(backup);

      // Reset since, with nothing sealed under the new vault yet.
      final reset = (await SecureVault.create(
        'battery staple',
        vaultId: 'vault-2',
        now: DateTime.utc(2026, 10, 19),
      )).header;
      await bNotes.saveSecureVaultHeader(
        reset.toJson(),
        vaultId: reset.vaultId,
        headerVersion: reset.headerVersion,
      );
      final dropped = <String, List<Object>>{};
      await importer(
        b,
        dropped: dropped,
      ).importFromZip(before, deleteCreated: summary.created);
      expect((await bNotes.getSecureVaultHeader())!['vaultId'], 'vault-2');
      expect(dropped, isEmpty);
    });
  });
}

List<BackupCollection> _collections(AppDatabase db) => buildBackupCollections(
  journalRepository: DriftJournalRepository(db),
  dreamRepository: DriftDreamRepository(db),
  todoRepository: DriftTodoRepository(db),
  leetCodeRepository: DriftLeetCodeRepository(db),
  studyRepository: DriftStudyRepository(db),
  workoutRepository: DriftWorkoutRepository(db),
  jobRepository: DriftJobRepository(db),
  rankingRepository: DriftRankingRepository(db),
  calendarRepository: DriftCalendarRepository(db),
  trackerRepository: DriftTrackerRepository(db),
  financeRepository: DriftFinanceRepository(db),
  notificationRepository: DriftNotificationRepository(db),
  reminderRepository: DriftReminderRepository(db),
  bucketListRepository: DriftBucketListRepository(db),
  mediaRepository: DriftMediaRepository(db),
  photoSeriesRepository: DriftPhotoSeriesRepository(db),
  gaiaRepository: DriftGaiaRepository(db),
  settingsRepository: DriftSettingsRepository(db),
);
