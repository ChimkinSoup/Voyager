// A pull asks the server only for what changed since the last one, keeps the
// mark it got to in the database, and falls back to a whole collection when
// it has no mark, the mark is a week old, or the answer came from the cache.

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/debouncer.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/sync/sync_engine.dart';
import 'package:voyager/core/sync/sync_watermark_store.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/calendar_models.dart';

/// Records what each listing asked for, and can answer as if from the cache.
class _RecordingSyncRepository extends InMemorySyncRepository {
  final requests = <({String collection, DateTime? since})>[];
  bool answerFromCache = false;

  @override
  Future<
    ({
      List<({String id, Map<String, dynamic> data})> documents,
      DateTime? newestWrite,
      bool fromServer,
    })
  >
  listChangedDocuments(String collection, {DateTime? since}) async {
    requests.add((collection: collection, since: since));
    final listed = await super.listChangedDocuments(collection, since: since);
    if (!answerFromCache) return listed;
    return (
      documents: listed.documents,
      newestWrite: listed.newestWrite,
      fromServer: false,
    );
  }

  DateTime? lastSince(String collection) =>
      requests.lastWhere((r) => r.collection == collection).since;
}

void main() {
  final now = DateTime.utc(2026, 9, 24, 12);
  late _RecordingSyncRepository server;
  late AppDatabase db;
  late DriftCalendarRepository calendars;
  late MemorySyncWatermarkStore watermarks;
  late RemoteSyncService sync;

  RemoteSyncService device() => RemoteSyncService(
    syncRepository: server,
    journalRepository: DriftJournalRepository(db),
    dreamRepository: DriftDreamRepository(db),
    todoRepository: DriftTodoRepository(db),
    leetCodeRepository: DriftLeetCodeRepository(db),
    studyRepository: DriftStudyRepository(db),
    workoutRepository: DriftWorkoutRepository(db),
    jobRepository: DriftJobRepository(db),
    rankingRepository: DriftRankingRepository(db),
    calendarRepository: calendars,
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
    watermarkStore: watermarks,
    deviceId: 'device-b',
    uploadDebounceDelay: Duration.zero,
  );

  Future<void> writeCalendar(String id, String name) => server.upsertDocument(
    FirestoreCollections.calendars,
    id,
    calendarToFirestore(
      Calendar(id: id, name: name, createdAt: now, updatedAt: now),
    ),
  );

  setUp(() {
    server = _RecordingSyncRepository();
    db = AppDatabase.inMemory();
    calendars = DriftCalendarRepository(db);
    watermarks = MemorySyncWatermarkStore();
    sync = device();
  });

  tearDown(() => db.close());

  test(
    'the first pull is whole, the next asks only for what changed',
    () async {
      await writeCalendar('cal-1', 'Work');
      await sync.pullCalendars();

      expect(server.lastSince(FirestoreCollections.calendars), isNull);
      expect((await calendars.getCalendar('cal-1'))?.name, 'Work');

      await writeCalendar('cal-2', 'Home');
      final listedBefore = server.requests.length;
      await sync.pullCalendars();

      final since = server.lastSince(FirestoreCollections.calendars);
      expect(since, isNotNull);
      final changed = await server.listChangedDocuments(
        FirestoreCollections.calendars,
        since: since,
      );
      expect(
        changed.documents.map((d) => d.id),
        ['cal-2'],
        reason: 'cal-1 was already pulled and has not changed since',
      );
      expect(server.requests.length, listedBefore + 2);
      expect((await calendars.getCalendar('cal-2'))?.name, 'Home');
    },
  );

  test('live sync listens from where the pull left off', () async {
    expect(sync.changedSinceFor(FirestoreCollections.calendars), isNull);

    await writeCalendar('cal-1', 'Work');
    await sync.pullCalendars();

    expect(
      sync.changedSinceFor(FirestoreCollections.calendars),
      watermarks.watermarks[FirestoreCollections.calendars]!.changedSince,
    );
  });

  test('a listing from the cache does not move the mark', () async {
    await writeCalendar('cal-1', 'Work');
    server.answerFromCache = true;
    await sync.pullCalendars();

    expect(watermarks.watermarks, isEmpty);
    expect(
      (await calendars.getCalendar('cal-1'))?.name,
      'Work',
      reason: 'what the cache had is still applied',
    );

    server.answerFromCache = false;
    await sync.pullCalendars();
    expect(server.lastSince(FirestoreCollections.calendars), isNull);
  });

  test('a collection is pulled whole again once its last full pull is a '
      'week old', () async {
    final stale = DateTime.now().toUtc().subtract(const Duration(days: 8));
    watermarks.watermarks[FirestoreCollections.calendars] = SyncWatermark(
      changedSince: stale,
      lastFullPullAt: stale,
    );
    await sync.pullCalendars();

    expect(server.lastSince(FirestoreCollections.calendars), isNull);
    expect(
      watermarks.watermarks[FirestoreCollections.calendars]!.lastFullPullAt
          .isAfter(stale),
      isTrue,
    );
  });

  test(
    'a full pull with nothing stamped falls back behind the clock',
    () async {
      final before = DateTime.now().toUtc();
      await sync.pullCalendars();

      final mark = watermarks.watermarks[FirestoreCollections.calendars]!;
      expect(mark.changedSince.isBefore(before), isTrue);
      expect(
        before.difference(mark.changedSince),
        greaterThanOrEqualTo(const Duration(minutes: 59)),
      );
    },
  );

  test('pullAll pulls every chain and records the marks', () async {
    await writeCalendar('cal-1', 'Work');
    await sync.pullAll();

    expect((await calendars.getCalendar('cal-1'))?.name, 'Work');
    expect(
      watermarks.watermarks.keys,
      containsAll([
        FirestoreCollections.calendars,
        FirestoreCollections.journals,
        FirestoreCollections.studyCards,
        FirestoreCollections.jobStatusEvents,
      ]),
    );
  });

  test('the drift store keeps marks per account', () async {
    final mark = SyncWatermark(
      changedSince: DateTime.utc(2026, 9, 1, 8, 30, 0, 123, 456),
      lastFullPullAt: DateTime.utc(2026, 9, 20),
    );
    final alice = DriftSyncWatermarkStore(db, 'alice');
    final bob = DriftSyncWatermarkStore(db, 'bob');

    await alice.write(FirestoreCollections.calendars, mark);

    final read = await alice.read(FirestoreCollections.calendars);
    expect(read?.changedSince, mark.changedSince);
    expect(read?.lastFullPullAt, mark.lastFullPullAt);
    expect(await bob.read(FirestoreCollections.calendars), isNull);
  });
}
