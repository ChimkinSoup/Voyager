// BUG-261 … BUG-265: images whose bytes are not (or no longer) in Storage.
//
// The asset document says whether the bytes are in the cloud, written only by
// a device holding them; a device without them shows "On another device"
// instead of a failed download, and fetches the image once it is uploaded.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/media/media_service.dart';
import 'package:voyager/core/media/media_transfer_worker.dart';
import 'package:voyager/core/sync/debouncer.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/sync/sync_engine.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/data/services/media_file_store.dart';
import 'package:voyager/domain/models/media_models.dart';
import 'package:voyager/domain/models/settings_models.dart';

import 'media_transfer_test.dart' show FakeMediaStorage, pngOf;

class _Publisher implements MediaSyncPublisher {
  final assets = <MediaAsset>[];

  @override
  void publishAsset(MediaAsset asset) => assets.add(asset);

  @override
  void publishReference(MediaReference reference) {}
}

/// One device: its own database, files and worker, sharing [storage] with the
/// others as devices share a bucket.
class _Device {
  _Device(this.storage, Directory root, {AppSettings? settings})
    : settings = settings ?? const AppSettings() {
    repository = DriftMediaRepository(db);
    service = MediaService(
      repository: repository,
      fileStore: MediaFileStore(root: root),
      readSettings: () async => this.settings,
    )..publisher = publisher;
    worker = MediaTransferWorker(
      repository: repository,
      service: service,
      storage: storage,
      readSettings: () async => this.settings,
    );
  }

  final FakeMediaStorage storage;
  AppSettings settings;
  final db = AppDatabase.inMemory();
  final publisher = _Publisher();
  late final DriftMediaRepository repository;
  late final MediaService service;
  late final MediaTransferWorker worker;

  Future<MediaAsset> attach({String documentId = 'entry-1'}) async {
    final reference = await service.attachBytes(
      bytes: pngOf(60, 40),
      collection: FirestoreCollections.journalEntries,
      documentId: documentId,
    );
    return (await repository.getAsset(reference.mediaId))!;
  }

  /// Pulls [document], and gives it a reference so it is something shown.
  Future<MediaAsset> receive(
    Map<String, dynamic> document, {
    String referenceId = 'ref-1',
  }) async {
    final id = document['id'] as String;
    await _sync(
      db,
    ).pullMediaAssets(documentIds: {id}, documentData: {id: document});
    final now = DateTime.utc(2026, 10, 1);
    await repository.upsertReference(
      MediaReference(
        id: referenceId,
        mediaId: id,
        collection: FirestoreCollections.journalEntries,
        documentId: 'entry-1',
        createdAt: now,
        updatedAt: now,
      ),
      recordLocalActivity: false,
    );
    return (await repository.getAsset(id))!;
  }

  Map<String, dynamic> lastPublished() =>
      mediaAssetToFirestore(publisher.assets.last);
}

RemoteSyncService _sync(AppDatabase db) {
  final server = InMemorySyncRepository();
  return RemoteSyncService(
    syncRepository: server,
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
    syncEngine: SyncEngine(
      syncRepository: server,
      deviceId: 'device-b',
      debouncer: Debouncer(delay: Duration.zero),
    ),
    deviceId: 'device-b',
    uploadDebounceDelay: Duration.zero,
  );
}

void main() {
  late Directory temp;
  late FakeMediaStorage storage;
  final devices = <_Device>[];

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('voyager_media_presence');
    storage = FakeMediaStorage();
  });

  tearDown(() async {
    for (final device in devices) {
      device.worker.dispose();
      await device.db.close();
    }
    devices.clear();
    await temp.delete(recursive: true);
  });

  _Device device(String name, {AppSettings? settings}) {
    final created = _Device(
      storage,
      Directory('${temp.path}/$name'),
      settings: settings,
    );
    devices.add(created);
    return created;
  }

  test('an image kept local on its device shows as on another device, and '
      'nothing tries to fetch it (BUG-261)', () async {
    final a = device(
      'a',
      settings: const AppSettings(mediaRemoteUploadsEnabled: false),
    );
    final b = device('b');
    await a.attach();
    expect(a.lastPublished()['inCloud'], isFalse);

    var asset = await b.receive(a.lastPublished());
    expect(asset.isOnlyElsewhere, isTrue);

    await b.service.requestDownload(asset);
    await b.worker.prefetchMissing();
    await b.worker.requeueFailedDownloads();
    asset = (await b.repository.getAsset(asset.id))!;
    expect(storage.downloads, isEmpty);
    expect(asset.downloadState, MediaDownloadState.missing);
  });

  test('a device without the bytes leaves inCloud to the one holding them '
      '(BUG-261)', () async {
    final a = device('a');
    final b = device('b');
    await a.attach();
    final received = await b.receive(a.lastPublished());

    expect(mediaAssetToFirestore(received).containsKey('inCloud'), isFalse);
  });

  test('once uploaded, the asset document says so, and a download parked on '
      'the missing object is fetched (BUG-261, BUG-262)', () async {
    final a = device(
      'a',
      settings: const AppSettings(mediaRemoteUploadsEnabled: false),
    );
    final b = device('b');
    await a.attach();
    // Parked the way a build without the flag left it.
    var asset = await b.receive({...a.lastPublished()}..remove('inCloud'));
    await b.repository.updateAssetTransferState(
      asset.id,
      downloadState: MediaDownloadState.failed,
      failureReason: 'object not found',
    );

    a.settings = const AppSettings();
    expect(await a.service.queueLocalOnlyUploads(), 1);
    await a.worker.drainUploads();
    expect(a.lastPublished()['inCloud'], isTrue);

    asset = await b.receive(a.lastPublished());
    expect(asset.uploadState, MediaUploadState.uploaded);
    expect(asset.downloadState, MediaDownloadState.missing);
    await b.worker.prefetchMissing();
    expect(
      (await b.repository.getAsset(asset.id))!.downloadState,
      MediaDownloadState.present,
    );
  });

  test('only images whose bytes are here are queued when uploads come on '
      '(BUG-262)', () async {
    final a = device(
      'a',
      settings: const AppSettings(mediaRemoteUploadsEnabled: false),
    );
    final b = device('b');
    await a.attach();
    await b.receive(a.lastPublished());

    expect(await b.service.queueLocalOnlyUploads(), 0);
  });

  test('re-attaching an image whose 30-day clock had started uploads it '
      'again: another device may have purged the object (BUG-265)', () async {
    final b = device('b');
    final first = await b.attach();
    await b.worker.drainUploads();
    final reference = (await b.service.referencesFor(
      FirestoreCollections.journalEntries,
      'entry-1',
    )).single;
    await b.service.removeReference(reference.id);
    // Another device's purge.
    storage.objects.clear();

    final again = await b.attach(documentId: 'entry-2');
    expect(again.id, first.id);
    expect(again.uploadState, MediaUploadState.pending);
    expect(b.lastPublished()['inCloud'], isFalse);
    await b.worker.drainUploads();
    expect(storage.objects, contains(first.remotePath('user-1')));
    expect(b.lastPublished()['inCloud'], isTrue);
  });

  test('re-attaching an image still in use elsewhere does not upload it '
      'again', () async {
    final b = device('b');
    await b.attach();
    await b.worker.drainUploads();
    storage.uploads.clear();

    final again = await b.attach(documentId: 'entry-2');
    expect(again.uploadState, MediaUploadState.uploaded);
    await b.worker.drainUploads();
    expect(storage.uploads, isEmpty);
  });

  test('an upload a brief outage failed is sent again on the worker clock, '
      'with no reconnect seen (BUG-264)', () async {
    final a = device('a');
    final worker = MediaTransferWorker(
      repository: a.repository,
      service: a.service,
      storage: storage,
      readSettings: () async => a.settings,
      retryDelay: const Duration(milliseconds: 200),
    );
    addTearDown(worker.dispose);
    final asset = await a.attach();
    storage.failuresRemaining = 1;
    await worker.drainUploads();
    expect(storage.uploads, isEmpty);

    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(storage.uploads, [asset.remotePath('user-1')]);
  });

  test('the retry clock gives a parked asset two rounds, then leaves it to '
      'the reconnect', () async {
    final a = device('a');
    final worker = MediaTransferWorker(
      repository: a.repository,
      service: a.service,
      storage: storage,
      readSettings: () async => a.settings,
      maxAttempts: 1,
      retryDelay: const Duration(milliseconds: 50),
    );
    addTearDown(worker.dispose);
    final asset = await a.attach();
    storage.failuresRemaining = 1000;
    await worker.drainUploads();

    // The first attempt, then one per timer round: 50ms, 100ms, then a third
    // round at 200ms that skips it.
    await Future<void>.delayed(const Duration(milliseconds: 800));
    expect(1000 - storage.failuresRemaining, 3);
    expect(
      (await a.repository.getAsset(asset.id))!.uploadState,
      MediaUploadState.failed,
    );

    storage.failuresRemaining = 0;
    await worker.resumeAfterReconnect();
    expect(storage.uploads, [asset.remotePath('user-1')]);
  });
}
