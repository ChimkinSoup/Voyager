import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:voyager/core/media/media_service.dart';
import 'package:voyager/core/media/media_transfer_worker.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/data/services/media_file_store.dart';
import 'package:voyager/domain/models/media_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/repositories/media_storage.dart';

Uint8List pngOf(int width, int height, {int r = 200}) {
  final image = img.Image(width: width, height: height, numChannels: 3);
  img.fill(image, color: img.ColorRgb8(r, 30, 60));
  return img.encodePng(image);
}

/// An in-memory Storage bucket that records what it was asked to do.
class FakeMediaStorage implements MediaStorage {
  FakeMediaStorage({this.uid = 'user-1'});

  final String? uid;
  final objects = <String, Uint8List>{};
  final uploads = <String>[];
  final downloads = <String>[];
  final deletes = <String>[];

  /// Set to make the next N transfers throw. Counts down, so a test can make
  /// a transfer fail twice and then succeed.
  int failuresRemaining = 0;

  /// When true the failures are permanent rather than transient.
  bool failPermanently = false;

  @override
  String? get currentUid => uid;

  void _maybeFail() {
    if (failuresRemaining <= 0) return;
    failuresRemaining--;
    if (failPermanently) {
      throw const MediaStoragePermanentFailure('nope');
    }
    throw StateError('transient network failure');
  }

  @override
  Future<void> upload(String path, Uint8List bytes, String mimeType) async {
    _maybeFail();
    uploads.add(path);
    objects[path] = bytes;
  }

  @override
  Future<Uint8List> download(String path) async {
    _maybeFail();
    downloads.add(path);
    final bytes = objects[path];
    if (bytes == null) {
      throw const MediaStoragePermanentFailure('object not found');
    }
    return bytes;
  }

  @override
  Future<void> delete(String path) async {
    deletes.add(path);
    objects.remove(path);
  }
}

void main() {
  late Directory tempDir;
  late AppDatabase db;
  late DriftMediaRepository repository;
  late MediaFileStore fileStore;
  late MediaService service;
  late FakeMediaStorage storage;
  late MediaTransferWorker worker;
  late AppSettings settings;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('voyager_media_transfer');
    db = AppDatabase.inMemory();
    repository = DriftMediaRepository(db);
    fileStore = MediaFileStore(root: Directory('${tempDir.path}/media'));
    settings = const AppSettings();
    storage = FakeMediaStorage();
    service = MediaService(
      repository: repository,
      fileStore: fileStore,
      readSettings: () async => settings,
    );
    worker = MediaTransferWorker(
      repository: repository,
      service: service,
      storage: storage,
      readSettings: () async => settings,
    );
    // Deliberately not wired to the service's schedulers: these tests drive
    // the worker themselves so that each drain is one observable step, rather
    // than racing an unawaited one that `attachBytes` kicked off.
  });

  tearDown(() async {
    await db.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<MediaAsset> attach({int r = 200}) async {
    final reference = await service.attachBytes(
      bytes: pngOf(60, 40, r: r),
      collection: FirestoreCollections.todoTasks,
      documentId: 'task-1',
    );
    return (await repository.getAsset(reference.mediaId))!;
  }

  group('upload queue', () {
    test('uploads a pending asset to its content-addressed path', () async {
      final asset = await attach();
      await worker.drainUploads();

      expect(storage.uploads, [asset.remotePath('user-1')]);
      expect(
        (await repository.getAsset(asset.id))!.uploadState,
        MediaUploadState.uploaded,
      );
    });

    test('does nothing at all while uploads are disabled', () async {
      settings = const AppSettings(mediaRemoteUploadsEnabled: false);
      await attach();
      await worker.drainUploads();
      expect(storage.uploads, isEmpty);
    });

    test('does nothing while signed out', () async {
      storage = FakeMediaStorage(uid: null);
      worker = MediaTransferWorker(
        repository: repository,
        service: service,
        storage: storage,
        readSettings: () async => settings,
      );
      await attach();
      await worker.drainUploads();
      expect(storage.uploads, isEmpty);
    });

    test('re-queues a transient failure and succeeds on a later drain', () async {
      final asset = await attach();
      storage.failuresRemaining = 1;

      await worker.drainUploads();
      expect(
        (await repository.getAsset(asset.id))!.uploadState,
        MediaUploadState.pending,
        reason: 'a transient failure goes back on the queue',
      );

      await worker.drainUploads();
      expect(
        (await repository.getAsset(asset.id))!.uploadState,
        MediaUploadState.uploaded,
      );
    });

    test('parks a permanent failure immediately, with a reason', () async {
      final asset = await attach();
      storage
        ..failuresRemaining = 1
        ..failPermanently = true;

      await worker.drainUploads();

      final parked = (await repository.getAsset(asset.id))!;
      expect(parked.uploadState, MediaUploadState.failed);
      expect(parked.failureReason, isNotNull);
    });

    test('parks after maxAttempts of transient failures', () async {
      final asset = await attach();
      storage.failuresRemaining = 99;

      for (var i = 0; i < 4; i++) {
        await worker.drainUploads();
      }

      expect(
        (await repository.getAsset(asset.id))!.uploadState,
        MediaUploadState.failed,
      );
    });

    test('requeueFailedUploads revives everything a rules refusal parked',
        () async {
      final first = await attach(r: 10);
      final second = await attach(r: 20);
      storage
        ..failuresRemaining = 99
        ..failPermanently = true;
      await worker.drainUploads();

      expect(
        (await repository.getAsset(first.id))!.uploadState,
        MediaUploadState.failed,
      );
      expect(
        (await repository.getAsset(second.id))!.uploadState,
        MediaUploadState.failed,
      );
      expect(storage.uploads, isEmpty);

      // The rules deploy that fixes the refusal.
      storage
        ..failuresRemaining = 0
        ..failPermanently = false;

      expect(await worker.requeueFailedUploads(), 2);

      for (final asset in [first, second]) {
        final revived = (await repository.getAsset(asset.id))!;
        expect(revived.uploadState, MediaUploadState.uploaded);
        expect(revived.failureReason, isNull);
      }
      expect(storage.uploads, hasLength(2));
    });

    test('requeueFailedUploads leaves a still-broken blob parked', () async {
      final asset = await attach();
      storage
        ..failuresRemaining = 99
        ..failPermanently = true;
      await worker.drainUploads();

      // Still refused, so the requeue drains straight back to `failed`
      // rather than leaving it pending forever.
      expect(await worker.requeueFailedUploads(), 1);
      expect(
        (await repository.getAsset(asset.id))!.uploadState,
        MediaUploadState.failed,
      );
    });

    test('requeueFailedUploads does nothing while uploads are disabled',
        () async {
      final asset = await attach();
      storage
        ..failuresRemaining = 99
        ..failPermanently = true;
      await worker.drainUploads();

      settings = const AppSettings(mediaRemoteUploadsEnabled: false);
      expect(await worker.requeueFailedUploads(), 0);
      expect(
        (await repository.getAsset(asset.id))!.uploadState,
        MediaUploadState.failed,
      );
    });

    test('retry puts a parked asset back on the queue', () async {
      final asset = await attach();
      storage
        ..failuresRemaining = 1
        ..failPermanently = true;
      await worker.drainUploads();
      expect(
        (await repository.getAsset(asset.id))!.uploadState,
        MediaUploadState.failed,
      );

      storage.failPermanently = false;
      await worker.retry((await repository.getAsset(asset.id))!);

      final recovered = (await repository.getAsset(asset.id))!;
      expect(recovered.uploadState, MediaUploadState.uploaded);
      expect(recovered.failureReason, isNull);
    });
  });

  group('download queue', () {
    /// An asset this device knows about but has no bytes for — what a pull
    /// from another device leaves behind.
    Future<MediaAsset> remoteOnlyAsset() async {
      final bytes = pngOf(30, 30, r: 90);
      final now = DateTime.now().toUtc();
      final asset = MediaAsset(
        id: 'remote-1',
        contentHash: 'remotehash',
        byteSize: bytes.length,
        mimeType: 'image/jpeg',
        width: 30,
        height: 30,
        uploadState: MediaUploadState.uploaded,
        downloadState: MediaDownloadState.missing,
        createdAt: now,
        updatedAt: now,
      );
      await repository.upsertAsset(asset);
      storage.objects[asset.remotePath('user-1')] = bytes;
      return asset;
    }

    test('prefetch fetches every missing asset', () async {
      final asset = await remoteOnlyAsset();
      await worker.prefetchMissing();

      expect(storage.downloads, [asset.remotePath('user-1')]);
      final updated = (await repository.getAsset(asset.id))!;
      expect(updated.downloadState, MediaDownloadState.present);
      expect(await fileStore.hasBytes(updated), isTrue);
    });

    test('prefetch does nothing while it is switched off', () async {
      settings = const AppSettings(mediaBackgroundPrefetchEnabled: false);
      await remoteOnlyAsset();
      await worker.prefetchMissing();
      expect(storage.downloads, isEmpty);
    });

    test('prefetch does nothing while downloads are off', () async {
      settings = const AppSettings(mediaRemoteDownloadsEnabled: false);
      await remoteOnlyAsset();
      await worker.prefetchMissing();
      expect(storage.downloads, isEmpty);
    });

    test('an on-demand read fetches bytes and returns them', () async {
      // The one case that genuinely goes through the service's scheduler:
      // `bytesFor` queues the download and waits for the drain it wakes.
      service.downloadScheduler = worker.drainDownloads;
      final asset = await remoteOnlyAsset();
      final bytes = await service.bytesFor(asset);
      expect(bytes, isNotNull);
      expect(storage.downloads, hasLength(1));
    });

    test('a missing remote object parks rather than retrying forever', () async {
      final asset = await remoteOnlyAsset();
      storage.objects.remove(asset.remotePath('user-1'));

      await worker.prefetchMissing();

      expect(
        (await repository.getAsset(asset.id))!.downloadState,
        MediaDownloadState.failed,
      );
    });

    test('an upload of an asset with no local bytes is not a failure', () async {
      final asset = await remoteOnlyAsset();
      await repository.upsertAsset(
        asset.copyWith(uploadState: MediaUploadState.pending),
      );

      await worker.drainUploads();

      expect(storage.uploads, isEmpty);
      expect(
        (await repository.getAsset(asset.id))!.uploadState,
        MediaUploadState.localOnly,
        reason: 'the download queue owns this asset, not the upload queue',
      );
    });
  });

  group('purge reaches cloud storage', () {
    test('deletes the object for an asset that was uploaded', () async {
      final asset = await attach();
      await worker.drainUploads();
      final path = asset.remotePath('user-1');
      expect(storage.objects, contains(path));

      final references = await repository.listReferencesForAsset(asset.id);
      await service.removeReference(references.single.id);
      await service.purgeExpired(
        DateTime.now().toUtc().add(const Duration(days: 31)),
        storage: storage,
      );

      expect(storage.deletes, contains(path));
      expect(storage.objects, isNot(contains(path)));
    });

    test('leaves cloud storage alone for a local-only asset', () async {
      settings = const AppSettings(mediaRemoteUploadsEnabled: false);
      final asset = await attach();
      final references = await repository.listReferencesForAsset(asset.id);
      await service.removeReference(references.single.id);

      await service.purgeExpired(
        DateTime.now().toUtc().add(const Duration(days: 31)),
        storage: storage,
      );

      expect(storage.deletes, isEmpty);
    });
  });
}
