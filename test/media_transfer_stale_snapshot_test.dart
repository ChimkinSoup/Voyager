import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/media/media_service.dart';
import 'package:voyager/core/media/media_transfer_worker.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/data/services/media_file_store.dart';
import 'package:voyager/domain/models/media_models.dart';
import 'package:voyager/domain/models/settings_models.dart';

import 'media_transfer_test.dart' show FakeMediaStorage, pngOf;

/// Holds every upload open until [release], so a test can edit the asset
/// while its transfer is in flight.
class _GatedStorage extends FakeMediaStorage {
  final _gate = Completer<void>();
  final started = Completer<void>();

  void release() => _gate.complete();

  @override
  Future<void> upload(String path, Uint8List bytes, String mimeType) async {
    if (!started.isCompleted) started.complete();
    await _gate.future;
    await super.upload(path, bytes, mimeType);
  }
}

void main() {
  late Directory tempDir;
  late AppDatabase db;
  late DriftMediaRepository repository;
  late MediaService service;
  late _GatedStorage storage;
  late MediaTransferWorker worker;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('voyager_media_stale');
    db = AppDatabase.inMemory();
    repository = DriftMediaRepository(db);
    service = MediaService(
      repository: repository,
      fileStore: MediaFileStore(root: Directory('${tempDir.path}/media')),
      readSettings: () async => const AppSettings(),
    );
    storage = _GatedStorage();
    worker = MediaTransferWorker(
      repository: repository,
      service: service,
      storage: storage,
      readSettings: () async => const AppSettings(),
    );
  });

  tearDown(() async {
    await db.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('attaching an image while its upload is in flight survives the upload '
      'finishing', () async {
    final ingested = await service.ingestBytes(pngOf(60, 40));
    expect(ingested.unreferencedAt, isNotNull);

    final drain = worker.drainUploads();
    await storage.started.future;
    await service.addReference(
      mediaId: ingested.id,
      collection: FirestoreCollections.journalEntries,
      documentId: 'entry-1',
    );
    final attached = (await repository.getAsset(ingested.id))!;
    storage.release();
    await drain;

    final after = (await repository.getAsset(ingested.id))!;
    expect(after.uploadState, MediaUploadState.uploaded);
    expect(
      after.unreferencedAt,
      isNull,
      reason: 'the upload must not put back the pre-attach retention clock',
    );
    expect(after.version, attached.version);
  });

  test('the purge keeps an image that is still in use, even with a stale '
      'unreferenced stamp', () async {
    final reference = await service.attachBytes(
      bytes: pngOf(60, 40),
      collection: FirestoreCollections.journalEntries,
      documentId: 'entry-1',
    );
    final asset = (await repository.getAsset(reference.mediaId))!;
    await repository.upsertAsset(
      asset.copyWith(unreferencedAt: DateTime.utc(2026, 1, 1)),
    );

    await service.purgeExpired(DateTime.utc(2026, 6, 1), storage: storage);

    expect(await repository.getAsset(asset.id), isNotNull);
    expect(storage.deletes, isEmpty);
  });

  test('reconcileRefcounts repairs clocks in both directions', () async {
    final inUse = await service.attachBytes(
      bytes: pngOf(60, 40, r: 10),
      collection: FirestoreCollections.journalEntries,
      documentId: 'entry-1',
    );
    final inUseAsset = (await repository.getAsset(inUse.mediaId))!;
    await repository.upsertAsset(
      inUseAsset.copyWith(unreferencedAt: DateTime.utc(2026, 1, 1)),
    );

    final detached = await service.ingestBytes(pngOf(60, 40, r: 90));
    await repository.upsertAsset(detached.copyWith(clearUnreferencedAt: true));

    await service.reconcileRefcounts();

    expect((await repository.getAsset(inUseAsset.id))!.unreferencedAt, isNull);
    final marked = (await repository.getAsset(detached.id))!;
    expect(marked.unreferencedAt, isNotNull);
    expect(marked.version, greaterThan(detached.version));
  });

  test('rendering a parked download does not retry it', () async {
    final asset = await service.ingestBytes(pngOf(60, 40));
    await repository.updateAssetTransferState(
      asset.id,
      downloadState: MediaDownloadState.failed,
      failureReason: 'No object exists at the desired reference.',
    );
    final parked = (await repository.getAsset(asset.id))!;

    await service.requestDownload(parked);

    final after = (await repository.getAsset(asset.id))!;
    expect(after.downloadState, MediaDownloadState.failed);
    expect(after.failureReason, isNotNull);
  });

  test('upsertAsset writing back an older copy keeps the transfer state a '
      'transfer set since', () async {
    final asset = await service.ingestBytes(pngOf(60, 40));
    expect(asset.uploadState, MediaUploadState.pending);
    await repository.updateAssetTransferState(
      asset.id,
      uploadState: MediaUploadState.uploaded,
    );

    // The refcount, a pull or a restore holding the copy read before.
    await repository.upsertAsset(asset.copyWith(bumpVersion: true));

    final after = (await repository.getAsset(asset.id))!;
    expect(after.uploadState, MediaUploadState.uploaded);
    expect(after.version, asset.version + 1);
  });

  test('a parked download is retried once on the next launch', () async {
    final asset = await service.ingestBytes(pngOf(60, 40));
    final bytes = (await service.fileStore.readBytes(asset))!;
    await service.fileStore.deleteBytesForAsset(asset);
    await repository.updateAssetTransferState(
      asset.id,
      downloadState: MediaDownloadState.failed,
      failureReason: 'object not found',
    );
    // The other device's upload has finished since.
    storage.objects[asset.remotePath('user-1')] = bytes;

    expect(await worker.requeueFailedDownloads(), 1);

    final after = (await repository.getAsset(asset.id))!;
    expect(after.downloadState, MediaDownloadState.present);
    expect(after.failureReason, isNull);
  });
}
