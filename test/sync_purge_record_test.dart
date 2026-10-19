import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/debouncer.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/sync/sync_engine.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/services/character_op_session.dart';

/// A device's listener while its own upload to a document is pending: the
/// document is out of its query, so the purge never reaches it as a removal.
/// Only the purge records get through.
class _PendingUploadHidesRemovals extends InMemorySyncRepository {
  Completer<void>? pendingWrites;

  @override
  Future<void> waitForPendingWrites() async => pendingWrites?.future;

  @override
  Stream<Map<String, Map<String, dynamic>>> watchCollection(
    String collection, {
    DateTime? changedSince,
  }) => collection == FirestoreCollections.purges
      ? super.watchCollection(collection, changedSince: changedSince)
      : const Stream.empty();
}

void main() {
  late AppDatabase db;
  late _PendingUploadHidesRemovals syncRepo;
  late CharacterOpRegistry registryA;
  late CharacterOpRegistry registryB;
  late RemoteSyncService deviceA;
  late RemoteSyncService deviceB;
  late LiveSyncController liveB;
  const collection = FirestoreCollections.journalEntries;
  const entryId = 'entry-purged';

  RemoteSyncService device(String id, CharacterOpRegistry registry) =>
      RemoteSyncService(
        syncRepository: syncRepo,
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
        settingsRepository: DriftSettingsRepository(db),
        syncEngine: SyncEngine(
          syncRepository: syncRepo,
          deviceId: id,
          debouncer: Debouncer(delay: Duration.zero),
        ),
        charOpRegistry: registry,
        uploadDebounceDelay: Duration.zero,
        deviceId: id,
      );

  setUp(() async {
    db = AppDatabase.inMemory();
    syncRepo = _PendingUploadHidesRemovals();
    registryA = CharacterOpRegistry();
    registryB = CharacterOpRegistry();
    deviceA = device('device-a', registryA);
    deviceB = device('device-b', registryB);
    liveB = LiveSyncController(
      remoteSync: deviceB,
      syncRepository: syncRepo,
      onChanged: (_) {},
    );

    final now = utcNow();
    final entry = JournalEntry(
      id: entryId,
      journalId: 'journal-1',
      title: 'Open on B',
      body: 'Typed on B',
      entryDate: now,
      createdAt: now,
      updatedAt: now,
    );
    await DriftJournalRepository(db).upsertEntry(entry);
    await syncRepo.upsertDocument(
      collection,
      entryId,
      journalEntryToFirestore(entry),
    );
    await deviceB.prepareEditingSession(
      collection: collection,
      documentId: entryId,
      initialText: 'Typed on B',
    );
  });

  tearDown(() async {
    liveB.dispose();
    await db.close();
  });

  test(
    'a purge rebuilds the session of a device that missed the removal',
    () async {
      final before = registryB.session(collection, entryId);
      liveB.start();

      await deviceA.permanentlyDeleteFromRemote(
        collection: collection,
        documentId: entryId,
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));

      final after = registryB.session(collection, entryId);
      expect(after, isNot(same(before)));
      expect(after?.text, 'Typed on B');
      expect(after?.hasPendingOps, isTrue);
    },
  );

  test('the rebuild waits for the device\'s own pending writes', () async {
    final before = registryB.session(collection, entryId);
    syncRepo.pendingWrites = Completer<void>();
    liveB.start();

    await deviceA.permanentlyDeleteFromRemote(
      collection: collection,
      documentId: entryId,
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(registryB.session(collection, entryId), same(before));

    syncRepo.pendingWrites!.complete();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(registryB.session(collection, entryId), isNot(same(before)));
  });

  test('a device ignores the record of its own purge', () async {
    final before = registryB.session(collection, entryId);

    await deviceB.forgetPurgedDocument({
      'collection': collection,
      'documentId': entryId,
      'deviceId': 'device-b',
    });

    expect(registryB.session(collection, entryId), same(before));
  });
}
