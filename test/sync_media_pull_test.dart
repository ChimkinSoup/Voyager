// Media assets and references reach a device that did not create them.
//
// They were pushed like any other record but never pulled: the full pull and
// the live listeners both left the two collections out, so a device restored
// from the cloud lost every image. The coverage checks keep the next
// collection added to [FirestoreCollections.records] from slipping the same
// way.

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/debouncer.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/sync/sync_engine.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/media_models.dart';

/// Records which collections the service lists and watches.
class _RecordingSyncRepository extends InMemorySyncRepository {
  final listed = <String>{};
  final watched = <String>{};

  @override
  Future<
    ({
      List<({String id, Map<String, dynamic> data})> documents,
      DateTime? newestWrite,
      bool fromServer,
    })
  >
  listChangedDocuments(String collection, {DateTime? since}) {
    listed.add(collection);
    return super.listChangedDocuments(collection, since: since);
  }

  @override
  Stream<Map<String, Map<String, dynamic>>> watchCollection(
    String collection, {
    DateTime? changedSince,
  }) {
    watched.add(collection);
    return super.watchCollection(collection, changedSince: changedSince);
  }
}

RemoteSyncService _service(AppDatabase db, InMemorySyncRepository server) =>
    RemoteSyncService(
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
      settingsRepository: DriftSettingsRepository(db),
      syncEngine: SyncEngine(
        syncRepository: server,
        deviceId: 'device-b',
        debouncer: Debouncer(delay: Duration.zero),
      ),
      deviceId: 'device-b',
      uploadDebounceDelay: Duration.zero,
    );

void main() {
  late _RecordingSyncRepository server;
  late AppDatabase db;
  late RemoteSyncService sync;

  setUp(() {
    server = _RecordingSyncRepository();
    db = AppDatabase.inMemory();
    sync = _service(db, server);
  });

  tearDown(() => db.close());

  final now = DateTime.utc(2026, 9, 1, 12);

  test('a full pull brings down media assets and references', () async {
    final asset = MediaAsset(
      id: 'asset-1',
      contentHash: 'abc123',
      byteSize: 42,
      mimeType: 'image/jpeg',
      width: 10,
      height: 20,
      createdAt: now,
      updatedAt: now,
    );
    final reference = MediaReference(
      id: 'ref-1',
      mediaId: 'asset-1',
      collection: FirestoreCollections.journalEntries,
      documentId: 'entry-1',
      createdAt: now,
      updatedAt: now,
    );
    await server.upsertDocument(
      FirestoreCollections.mediaAssets,
      asset.id,
      mediaAssetToFirestore(asset),
    );
    await server.upsertDocument(
      FirestoreCollections.mediaReferences,
      reference.id,
      mediaReferenceToFirestore(reference),
    );

    await sync.pullAll();

    final media = DriftMediaRepository(db);
    final pulledAsset = await media.getAsset('asset-1');
    expect(pulledAsset?.contentHash, 'abc123');
    // Known to exist, not yet on this device: the download queue fetches it.
    expect(pulledAsset?.downloadState, MediaDownloadState.missing);
    final pulledReference = await media.getReference('ref-1');
    expect(pulledReference?.mediaId, 'asset-1');
    expect(pulledReference?.documentId, 'entry-1');
  });

  test('a full pull lists every synced collection', () async {
    await sync.pullAll();

    expect(
      FirestoreCollections.records.difference(server.listed),
      isEmpty,
    );
  });

  test('live sync watches every synced collection', () {
    final live = LiveSyncController(
      remoteSync: sync,
      syncRepository: server,
      onChanged: () {},
    )..start();
    addTearDown(live.dispose);

    expect(
      FirestoreCollections.records.difference(server.watched),
      isEmpty,
    );
  });
}
