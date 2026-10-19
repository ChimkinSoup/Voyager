// Photo Series' encrypted blobs between two devices (PHOTO_SERIES_HLD.md
// Â§14). Two databases share one InMemorySyncRepository, as in
// pinned_note_conflict_test.dart.

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/secure_vault/secure_vault.dart';
import 'package:voyager/core/sync/debouncer.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/sync/sync_engine.dart';
import 'package:voyager/core/sync/synced_write_notifier.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/media_models.dart';
import 'package:voyager/domain/models/photo_series_models.dart';

/// Writes as Firestore's `SetOptions(merge: true)` does, keeping fields an
/// upload leaves out — `inCloud` from a device without the files.
class _MergingServer extends InMemorySyncRepository {
  @override
  Future<void> upsertDocument(
    String collection,
    String id,
    Map<String, dynamic> data,
  ) async => super.upsertDocument(collection, id, {
    ...?await getDocument(collection, id),
    ...data,
  });
}

class _Device {
  _Device(InMemorySyncRepository server, String deviceId) {
    db = AppDatabase.inMemory();
    final syncedWrites = SyncedWriteNotifier();
    notes = DriftNotificationRepository(db, syncedWrites: syncedWrites);
    photos = DriftPhotoSeriesRepository(db, syncedWrites: syncedWrites);
    sync = RemoteSyncService(
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
      notificationRepository: notes,
      reminderRepository: DriftReminderRepository(db),
      bucketListRepository: DriftBucketListRepository(db),
      mediaRepository: DriftMediaRepository(db),
      photoSeriesRepository: photos,
      settingsRepository: DriftSettingsRepository(db),
      syncEngine: SyncEngine(
        syncRepository: server,
        deviceId: deviceId,
        debouncer: Debouncer(delay: Duration.zero),
      ),
      deviceId: deviceId,
      uploadDebounceDelay: Duration.zero,
    );
    syncedWrites.onWrite = (collection, records) =>
        _uploads.add(sync.pushRecords(collection, records));
  }

  late final AppDatabase db;
  late final DriftNotificationRepository notes;
  late final DriftPhotoSeriesRepository photos;
  late final RemoteSyncService sync;
  final _uploads = <Future<void>>[];

  Future<void> settle() async {
    while (_uploads.isNotEmpty) {
      final pending = List.of(_uploads);
      _uploads.clear();
      await Future.wait(pending);
    }
  }
}

void main() {
  late InMemorySyncRepository server;
  late _Device a;
  late _Device b;
  final created = DateTime.utc(2026, 10, 18, 9);

  VaultBlob blob(String id, {String vaultId = 'vault-1'}) => VaultBlob(
    id: id,
    vaultId: vaultId,
    width: 2048,
    height: 1536,
    byteSize: 900000,
    thumbByteSize: 30000,
    uploadState: MediaUploadState.uploaded,
    createdAt: created,
    updatedAt: created,
  );

  setUp(() {
    server = _MergingServer();
    a = _Device(server, 'device-a');
    b = _Device(server, 'device-b');
  });

  tearDown(() async {
    await a.settle();
    await b.settle();
    await a.db.close();
    await b.db.close();
  });

  test('a blob reaches the other device without its files', () async {
    await a.photos.upsertBlob(blob('p1'));
    await a.settle();

    await b.sync.pullVaultBlobs();
    final here = (await b.photos.getBlob('p1'))!;
    expect(here.vaultId, 'vault-1');
    expect((here.width, here.height), (2048, 1536));
    expect((here.byteSize, here.thumbByteSize), (900000, 30000));
    expect(here.uploadState, MediaUploadState.uploaded);
    expect(here.downloadState, MediaDownloadState.missing);
    expect(here.thumbDownloadState, MediaDownloadState.missing);
  });

  test('a delete reaches the other device', () async {
    await a.photos.upsertBlob(blob('p1'));
    await a.settle();
    await b.sync.pullVaultBlobs();

    final live = (await a.photos.getBlob('p1'))!;
    await a.photos.upsertBlob(
      live.copyWith(deletedAt: created, bumpVersion: true),
    );
    await a.settle();
    await b.sync.pullVaultBlobs();
    expect((await b.photos.getBlob('p1'))!.deletedAt, isNotNull);
    expect(await b.photos.listBlobs(), isEmpty);
  });

  test('a pull retires blobs of a vault reset elsewhere', () async {
    final header = (await SecureVault.create(
      'pw',
      vaultId: 'vault-2',
      now: created,
      headerVersion: 2,
      retiredVaultIds: ['vault-1'],
    )).header;
    await server.writeAfterReading(
      FirestoreCollections.secureVault,
      FirestoreCollections.secureVaultHeaderId,
      (_) => header.toJson(),
    );
    await b.photos.upsertBlob(blob('old'));
    await b.photos.upsertBlob(blob('new', vaultId: 'vault-2'));

    // The header alone is enough: it is what live sync pulls on a reset.
    await b.sync.pullSecureVaultHeader();
    expect((await b.photos.getBlob('old'))!.deletedAt, isNotNull);
    await b.sync.pullVaultBlobs();
    expect((await b.photos.getBlob('new'))!.deletedAt, isNull);

    // And the tombstone travels.
    await b.settle();
    await a.sync.pullVaultBlobs();
    expect((await a.photos.getBlob('old'))!.deletedAt, isNotNull);
  });

  /// [backedUp] as a restore writes it onto a device that never held it: the
  /// backup's metadata, nothing to say its files are in Storage.
  Future<VaultBlob> restoreInto(_Device device, VaultBlob backedUp) async {
    final restored = mergeVaultBlobFromRemote({
      ...vaultBlobToFirestore(backedUp)..remove('inCloud'),
      'inCloud': false,
      'version': backedUp.version + 1,
    }, backedUp.id);
    await device.photos.upsertBlob(restored, recordLocalActivity: false);
    return restored;
  }

  test('a restored blob whose files are in Storage is fetched', () async {
    await a.photos.upsertBlob(blob('p1'));
    await a.settle();

    final restored = await restoreInto(b, blob('p1'));
    expect(restored.isOnlyElsewhere, isTrue);
    await b.sync.pushRestoredRecords(FirestoreCollections.vaultBlobs, [
      restored,
    ]);
    final here = (await b.photos.getBlob('p1'))!;
    expect(here.isOnlyElsewhere, isFalse);
    expect(here.uploadState, MediaUploadState.uploaded);
    expect(here.thumbDownloadState, MediaDownloadState.missing);
  });

  test('a restored blob the server has never had stays waiting', () async {
    final restored = await restoreInto(b, blob('p1'));
    await b.sync.pushRestoredRecords(FirestoreCollections.vaultBlobs, [
      restored,
    ]);
    expect((await b.photos.getBlob('p1'))!.isOnlyElsewhere, isTrue);
  });
}
