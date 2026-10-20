// Photo Series' rows between two devices, and their lifecycle: cascades,
// a vault reset's retirement, and the blobs a purge releases
// (PHOTO_SERIES_HLD.md §6.7, §14).

import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:voyager/core/secure_vault/secure_vault.dart';
import 'package:voyager/core/secure_vault/vault_media_service.dart';
import 'package:voyager/core/soft_delete/erasure.dart';
import 'package:voyager/core/sync/debouncer.dart';
import 'package:voyager/core/sync/note_sync.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/sync/sync_engine.dart';
import 'package:voyager/core/sync/synced_write_notifier.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/data/services/vault_media_file_store.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/photo_series_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/repositories/media_storage.dart';
import 'package:voyager/features/notifications/secure_vault_session.dart';
import 'package:voyager/features/photo_series/photo_series_service.dart';

Uint8List _jpeg(int width, int height) {
  final image = img.Image(width: width, height: height);
  for (final pixel in image) {
    pixel
      ..r = (pixel.x * 7) % 256
      ..g = (pixel.y * 3) % 256
      ..b = (pixel.x ^ pixel.y) % 256;
  }
  return img.encodeJpg(image);
}

class _NoStorage implements MediaStorage {
  @override
  String? get currentUid => null;

  @override
  Future<void> upload(String path, Uint8List bytes, String mimeType) async {}

  @override
  Future<Uint8List> download(String path) =>
      throw const MediaStoragePermanentFailure('offline');

  @override
  Future<void> delete(String path) async {}
}

class _Device {
  _Device(InMemorySyncRepository server, String deviceId, Directory dir) {
    db = AppDatabase.inMemory();
    final syncedWrites = SyncedWriteNotifier();
    notes = DriftNotificationRepository(db, syncedWrites: syncedWrites);
    photos = DriftPhotoSeriesRepository(db, syncedWrites: syncedWrites);
    media = VaultMediaService(
      repository: photos,
      fileStore: VaultMediaFileStore(root: dir),
      storage: _NoStorage(),
      readSettings: () async =>
          const AppSettings().copyWith(mediaRemoteUploadsEnabled: false),
    );
    service = PhotoSeriesService(repository: photos, media: media);
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
  late final VaultMediaService media;
  late final PhotoSeriesService service;
  late final RemoteSyncService sync;
  final _uploads = <Future<void>>[];

  Future<void> settle() async {
    while (_uploads.isNotEmpty) {
      final pending = List.of(_uploads);
      _uploads.clear();
      await Future.wait(pending);
    }
  }

  Future<void> pullAll() async {
    await sync.pullVaultBlobs();
    await sync.pullPhotoSeries();
    await sync.pullPhotoSeriesAngles();
    await sync.pullPhotoCheckIns();
    await sync.pullPhotoCheckInImages();
  }
}

void main() {
  late Directory temp;
  late InMemorySyncRepository server;
  late _Device a;
  late _Device b;
  final session = SecureVaultSession(
    key: SecretKey(List.filled(32, 7)),
    vaultId: 'vault-1',
  );

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('voyager_photo_series');
    server = InMemorySyncRepository();
    a = _Device(server, 'device-a', Directory('${temp.path}/a'));
    b = _Device(server, 'device-b', Directory('${temp.path}/b'));
  });

  tearDown(() async {
    await a.settle();
    await b.settle();
    await a.db.close();
    await b.db.close();
    await temp.delete(recursive: true);
  });

  Future<(PhotoSeries, List<PhotoSeriesAngle>)> newSeries() async {
    final series = await a.service.createSeries(
      name: 'Progress',
      cadence: TrackerCadence.weekly,
      sortOrder: 0,
      angleNames: ['Front', 'Side'],
    );
    final angles = await a.photos.listAngles();
    return (series, angles);
  }

  test(
    'a check-in, its sealed note and photos reach the other device',
    () async {
      final (series, angles) = await newSeries();
      await a.service.createCheckIn(
        session: session,
        series: series,
        takenOn: DateTime(2026, 10, 18),
        photos: {angles.first.id: _jpeg(300, 400)},
        note: '82.4 kg',
      );
      await a.settle();

      await b.pullAll();
      final snapshot = await b.photos.loadSnapshot();
      expect(snapshot.series.single.name, 'Progress');
      expect(
        [for (final angle in snapshot.angles) angle.name],
        ['Front', 'Side'],
      );
      // The first photo fixes its angle's frame.
      expect(snapshot.angles.first.frameAspect, closeTo(0.75, 0.01));
      expect(snapshot.angles.last.frameAspect, isNull);
      final checkIn = snapshot.checkIns.single;
      expect(checkIn.takenOn, DateTime(2026, 10, 18));
      expect(checkIn.noteCiphertext, isNot(contains('82.4')));
      expect(await PhotoSeriesService.openNote(session, checkIn), '82.4 kg');
      final image = snapshot.images.single;
      expect(image.angleId, angles.first.id);
      expect((await b.photos.getBlob(image.blobId))?.vaultId, 'vault-1');
    },
  );

  test('alignment changes round trip, later save winning', () async {
    final (series, angles) = await newSeries();
    await a.service.createCheckIn(
      session: session,
      series: series,
      takenOn: DateTime(2026, 10, 18),
      photos: {angles.first.id: _jpeg(300, 400)},
    );
    await a.settle();
    await b.pullAll();

    final image = (await a.photos.listImages()).single;
    await a.photos.upsertImage(
      PhotoCheckInImage(
        id: image.id,
        checkInId: image.checkInId,
        angleId: image.angleId,
        blobId: image.blobId,
        alignScale: 1.2,
        alignRotation: 0.05,
        alignDx: -0.1,
        alignDy: 0.02,
        createdAt: image.createdAt,
        updatedAt: DateTime.now().toUtc(),
        version: image.version + 1,
      ),
    );
    await a.settle();
    await b.sync.pullPhotoCheckInImages();

    final pulled = (await b.photos.getImage(image.id))!;
    expect(pulled.alignScale, 1.2);
    expect(pulled.alignRotation, 0.05);
    expect(pulled.alignDx, -0.1);
    expect(pulled.alignDy, 0.02);
  });

  test(
    'deleting a series cascades on the other device under one stamp',
    () async {
      final (series, angles) = await newSeries();
      await a.service.createCheckIn(
        session: session,
        series: series,
        takenOn: DateTime(2026, 10, 18),
        photos: {
          angles.first.id: _jpeg(300, 400),
          angles.last.id: _jpeg(40, 40),
        },
      );
      await a.settle();
      await b.pullAll();

      await a.service.deleteSeries((await a.photos.getSeries(series.id))!);
      await a.settle();
      await b.pullAll();

      final live = await b.photos.loadSnapshot();
      expect(live.series, isEmpty);
      expect(live.angles, isEmpty);
      expect(live.checkIns, isEmpty);
      expect(live.images, isEmpty);
      final stamps = {
        for (final row in [
          ...await b.photos.listSeries(includeDeleted: true),
          ...await b.photos.listAngles(includeDeleted: true),
          ...await b.photos.listCheckIns(includeDeleted: true),
          ...await b.photos.listImages(includeDeleted: true),
        ])
          row.deletedAt!.toUtc(),
      };
      expect(stamps, hasLength(1));
    },
  );

  test('a removed angle takes its photos; the last angle stays', () async {
    final (series, angles) = await newSeries();
    await a.service.createCheckIn(
      session: session,
      series: series,
      takenOn: DateTime(2026, 10, 18),
      photos: {angles.first.id: _jpeg(30, 40), angles.last.id: _jpeg(40, 40)},
    );

    await a.service.saveAngles(series, [
      (id: angles.last.id, name: 'Profile'),
      (id: null, name: 'Back'),
    ]);
    final live = await a.photos.loadSnapshot();
    expect([for (final angle in live.angles) angle.name], ['Profile', 'Back']);
    expect(live.images.single.angleId, angles.last.id);

    await expectLater(
      a.service.saveAngles(series, const []),
      throwsA(isA<PhotoSeriesException>()),
    );
  });

  test('deleting a check-in can be undone, its photos with it', () async {
    final (series, angles) = await newSeries();
    final checkIn = await a.service.createCheckIn(
      session: session,
      series: series,
      takenOn: DateTime(2026, 10, 18),
      photos: {angles.first.id: _jpeg(30, 40)},
    );
    final stamp = await a.service.deleteCheckIn(checkIn);
    expect((await a.photos.loadSnapshot()).checkIns, isEmpty);

    await a.service.restoreCheckIn(checkIn.id, stamp);
    final live = await a.photos.loadSnapshot();
    expect(live.checkIns.single.id, checkIn.id);
    expect(live.images, hasLength(1));
  });

  test(
    "a vault reset retires the old vault's photos, notes and emptied check-ins",
    () async {
      final (series, angles) = await newSeries();
      final old = await a.service.createCheckIn(
        session: session,
        series: series,
        takenOn: DateTime(2026, 10, 11),
        photos: {angles.first.id: _jpeg(30, 40)},
        note: 'old',
      );
      final next = SecureVaultSession(
        key: SecretKey(List.filled(32, 9)),
        vaultId: 'vault-2',
      );
      final kept = await a.service.createCheckIn(
        session: next,
        series: series,
        takenOn: DateTime(2026, 10, 18),
        photos: {angles.first.id: _jpeg(30, 40)},
      );
      // A note sealed under the old vault on a check-in whose photo is new.
      await a.service.setNote(session, kept, 'stale');
      final header = (await SecureVault.create(
        'new',
        vaultId: 'vault-2',
        now: DateTime.utc(2026, 10, 18),
        headerVersion: 2,
        retiredVaultIds: ['vault-1'],
      )).header;
      await a.notes.saveSecureVaultHeader(
        header.toJson(),
        vaultId: header.vaultId,
        headerVersion: header.headerVersion,
      );

      expect(await retireVaultBlobs(a.notes, a.photos), greaterThan(0));
      final live = await a.photos.loadSnapshot();
      expect([for (final c in live.checkIns) c.id], [kept.id]);
      expect(live.checkIns.single.hasNote, isFalse);
      expect(live.images, hasLength(1));
      expect((await a.photos.getCheckIn(old.id))!.deletedAt, isNotNull);
      expect(await retireVaultBlobs(a.notes, a.photos), 0);
    },
  );

  // The trash offered them back, with a photo that could never open.
  test('BUG-296: a reset erases the check-ins it empties, and those a delete '
      'left in the trash', () async {
    final (series, angles) = await newSeries();
    final emptied = await a.service.createCheckIn(
      session: session,
      series: series,
      takenOn: DateTime(2026, 10, 11),
      photos: {angles.first.id: _jpeg(30, 40)},
    );
    final deleted = await a.service.createCheckIn(
      session: session,
      series: series,
      takenOn: DateTime(2026, 10, 12),
      photos: {angles.first.id: _jpeg(30, 40)},
    );
    await a.service.deleteCheckIn(deleted);
    final header = (await SecureVault.create(
      'new',
      vaultId: 'vault-2',
      now: DateTime.utc(2026, 10, 18),
      headerVersion: 2,
      retiredVaultIds: [session.vaultId],
    )).header;
    await a.notes.saveSecureVaultHeader(
      header.toJson(),
      vaultId: header.vaultId,
      headerVersion: header.headerVersion,
    );

    expect(await retireVaultBlobs(a.notes, a.photos), greaterThan(0));
    for (final checkIn in [emptied, deleted]) {
      expect(
        isErasedAt((await a.photos.getCheckIn(checkIn.id))!.deletedAt),
        isTrue,
      );
    }
    for (final image in await a.photos.listImages(includeDeleted: true)) {
      expect(isErasedAt(image.deletedAt), isTrue);
    }
    expect(await retireVaultBlobs(a.notes, a.photos), 0);
  });

  group('releasing blobs', () {
    final now = DateTime.utc(2026, 10, 18);

    Future<VaultBlob> blob({required DateTime createdAt}) async {
      final blob = await a.media.ingest(
        _jpeg(20, 20),
        key: session.key,
        vaultId: session.vaultId,
      );
      final aged = VaultBlob(
        id: blob.id,
        vaultId: blob.vaultId,
        width: blob.width,
        height: blob.height,
        byteSize: blob.byteSize,
        thumbByteSize: blob.thumbByteSize,
        createdAt: createdAt,
        updatedAt: createdAt,
      );
      await a.photos.upsertBlob(aged);
      return aged;
    }

    PhotoCheckInImage image(String blobId, {DateTime? deletedAt}) =>
        PhotoCheckInImage(
          id: 'image-$blobId',
          checkInId: 'c',
          angleId: 'a',
          blobId: blobId,
          createdAt: now,
          updatedAt: now,
          deletedAt: deletedAt,
        );

    test('only blobs no image can bring back are let go', () async {
      final shown = await blob(createdAt: now);
      final inTrash = await blob(createdAt: now);
      final erased = await blob(createdAt: now);
      final fresh = await blob(createdAt: now);
      final orphan = await blob(createdAt: DateTime.utc(2026, 8, 1));
      await a.photos.saveAll(
        images: [
          image(shown.id),
          image(inTrash.id, deletedAt: now),
          image(erased.id, deletedAt: kErasedAt),
        ],
      );

      expect(await a.photos.releaseBlobs(now), 2);
      Future<bool> released(VaultBlob blob) async =>
          (await a.photos.getBlob(blob.id))!.deletedAt != null;
      expect(await released(shown), isFalse);
      expect(await released(inTrash), isFalse);
      expect(await released(erased), isTrue);
      // An image row may still be on its way for a new one.
      expect(await released(fresh), isFalse);
      expect(await released(orphan), isTrue);
    });
  });
}
