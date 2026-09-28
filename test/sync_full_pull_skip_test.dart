// BUG-002: the weekly full pull resolved every journal entry's and todo
// task's operation log, one Firestore query each, which took minutes on
// Windows. A full pull now leaves a document alone when this device already
// holds it at the listed revision and its log has gained nothing since the
// last full pull; anything else still resolves from its log.

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
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/services/character_operation.dart';

const _entryId = 'entry-1';

/// Records which operation logs a pull reads, how often it asks for recent
/// operations and lists journal entries, and can fail the recent-ops query.
class _RecordingSyncRepository extends InMemorySyncRepository {
  final logsRead = <String>[];
  var recentOperationQueries = 0;
  var journalListings = 0;
  bool failRecentOperations = false;

  @override
  Future<
    ({
      List<({String id, Map<String, dynamic> data})> documents,
      DateTime? newestWrite,
      bool fromServer,
    })
  >
  listChangedDocuments(String collection, {DateTime? since}) {
    if (collection == FirestoreCollections.journalEntries) journalListings++;
    return super.listChangedDocuments(collection, since: since);
  }

  @override
  Future<List<SyncOperation>> listOperations(String documentId) {
    logsRead.add(documentId);
    return super.listOperations(documentId);
  }

  @override
  Future<Set<String>> listOperationDocumentIdsSince(DateTime since) {
    recentOperationQueries++;
    if (failRecentOperations) throw StateError('unavailable');
    return super.listOperationDocumentIdsSince(since);
  }
}

void main() {
  final written = DateTime.utc(2026, 9, 20, 12);
  late _RecordingSyncRepository server;
  late AppDatabase db;
  late DriftJournalRepository journals;
  late MemorySyncWatermarkStore watermarks;
  late RemoteSyncService sync;

  Future<void> writeEntry({int version = 1, String body = 'Hello'}) =>
      server.upsertDocument(
        FirestoreCollections.journalEntries,
        _entryId,
        journalEntryToFirestore(
          JournalEntry(
            id: _entryId,
            journalId: 'journal-1',
            title: '',
            body: body,
            entryDate: written,
            createdAt: written,
            updatedAt: written.add(Duration(minutes: version)),
            version: version,
          ),
        ),
      );

  /// Makes the next pull of [collection] a weekly full one.
  void ageLastFullPull([
    String collection = FirestoreCollections.journalEntries,
  ]) {
    final mark = watermarks.watermarks[collection]!;
    watermarks.watermarks[collection] = SyncWatermark(
      changedSince: mark.changedSince,
      lastFullPullAt: DateTime.now().toUtc().subtract(const Duration(days: 8)),
    );
  }

  setUp(() async {
    server = _RecordingSyncRepository();
    db = AppDatabase.inMemory();
    journals = DriftJournalRepository(db);
    watermarks = MemorySyncWatermarkStore();
    sync = RemoteSyncService(
      syncRepository: server,
      journalRepository: journals,
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
      watermarkStore: watermarks,
      deviceId: 'device-b',
      uploadDebounceDelay: Duration.zero,
    );
    await writeEntry();
    await sync.pullJournalEntries();
    expect(server.logsRead, contains(_entryId), reason: 'first pull resolves');
    expect((await journals.getEntry(_entryId))?.body, 'Hello');
    server.logsRead.clear();
  });

  tearDown(() => db.close());

  test('a weekly full pull skips a document held at the listed revision '
      'whose log has not moved', () async {
    ageLastFullPull();
    await sync.pullJournalEntries();

    expect(server.logsRead, isEmpty);
    expect((await journals.getEntry(_entryId))?.body, 'Hello');
    expect(
      watermarks.watermarks[FirestoreCollections.journalEntries]!.lastFullPullAt
          .isAfter(DateTime.now().toUtc().subtract(const Duration(minutes: 1))),
      isTrue,
      reason: 'a pull that skipped documents still counts as full',
    );
  });

  test('a document at a newer revision is still applied', () async {
    await writeEntry(version: 2, body: 'Hello there');
    ageLastFullPull();
    await sync.pullJournalEntries();

    expect(server.logsRead, contains(_entryId));
    expect((await journals.getEntry(_entryId))?.body, 'Hello there');
  });

  test('a log that moved without its document is still resolved', () async {
    await server.appendOperation(
      SyncOperation(
        id: 'device-a_${_entryId}_0',
        documentId: _entryId,
        sequence: 0,
        payload: CharOpsPayload(
          charOps: const [
            CharacterOperation(
              id: 'a-1',
              clientId: 'device-a',
              logicalClock: 1,
              position: 'a0',
              character: 'x',
            ),
          ],
        ).encode(),
        deviceId: 'device-a',
        timestamp: DateTime.now().toUtc(),
      ),
    );
    ageLastFullPull();
    await sync.pullJournalEntries();

    expect(server.logsRead, contains(_entryId));
  });

  test('an operation queued offline for days counts from when it '
      'reached the server', () async {
    // Stamped by the writer's clock ten days back — before the last full
    // pull — but only uploaded now.
    await server.appendOperation(
      SyncOperation(
        id: 'device-a_${_entryId}_0',
        documentId: _entryId,
        sequence: 0,
        payload: CharOpsPayload(
          charOps: const [
            CharacterOperation(
              id: 'a-1',
              clientId: 'device-a',
              logicalClock: 1,
              position: 'a0',
              character: 'x',
            ),
          ],
        ).encode(),
        deviceId: 'device-a',
        timestamp: DateTime.now().toUtc().subtract(const Duration(days: 10)),
      ),
    );
    ageLastFullPull();

    await sync.pullJournalEntries();

    expect(server.logsRead, contains(_entryId));
  });

  test('pullAll asks for recent operations once, not per collection', () async {
    await sync.pullAll();
    ageLastFullPull(FirestoreCollections.journalEntries);
    ageLastFullPull(FirestoreCollections.dreamEntries);
    ageLastFullPull(FirestoreCollections.todoTasks);
    server.recentOperationQueries = 0;

    await sync.pullAll();

    expect(server.recentOperationQueries, 1);
  });

  test('a pullAll made while one runs waits for it, then pulls once more '
      'for every caller that waited', () async {
    server.journalListings = 0;
    final first = sync.pullAll();
    final second = sync.pullAll();
    final third = sync.pullAll();
    expect(identical(second, third), isTrue);

    await Future.wait([first, second, third]);

    expect(server.journalListings, 2);
  });

  test(
    'pullAll reports every listed document, skipped ones included',
    () async {
      ageLastFullPull();
      final reports = <(int, int)>[];
      await sync.pullAll(
        onProgress: (done, total) => reports.add((done, total)),
      );

      expect(reports, isNotEmpty);
      final (done, total) = reports.last;
      expect(total, greaterThanOrEqualTo(1));
      expect(done, total, reason: 'the count ends where the listing did');
      expect(server.logsRead, isNot(contains(_entryId)));
    },
  );

  test('nothing is skipped when the recent-operations query fails', () async {
    server.failRecentOperations = true;
    ageLastFullPull();
    await sync.pullJournalEntries();

    expect(server.logsRead, contains(_entryId));
  });
}
