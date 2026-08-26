// LC-02: a LeetCode write made while the upload fails — offline, flaky Wi-Fi,
// an expired token — has to leave a record that it tried. Every mutation on
// the page funnels through `pushLeetCodeProblem`, which fires an unawaited
// upload; without the guard the rejection escaped to the zone, no outbox row
// was created, and nothing ever re-pushed the document. SQLite had it and
// Firestore never would.

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/debouncer.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/outbox_sync_worker.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/sync/sync_engine.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/domain/services/weather_service.dart';

import 'fakes/fake_weather_api_client.dart';

/// The server, but the LeetCode collection is unreachable — the shape of every
/// upload failure this guard exists for.
class _OfflineForLeetCode extends InMemorySyncRepository {
  @override
  Future<void> upsertDocument(
    String collection,
    String id,
    Map<String, dynamic> data,
  ) async {
    if (collection == FirestoreCollections.leetcodeProblems) {
      throw FirebaseException(plugin: 'cloud_firestore', code: 'unavailable');
    }
    return super.upsertDocument(collection, id, data);
  }
}

class _StubAuthRepository implements AuthRepository {
  @override
  String? get currentUserId => 'user-1';

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

LeetCodeProblem _problem() {
  final now = DateTime.utc(2026, 8, 20, 9);
  return LeetCodeProblem(
    id: 'p1',
    createdAt: now,
    updatedAt: now,
    title: 'Two Sum',
    difficulty: LeetCodeDifficulty.easy,
    solutions: const [LeetCodeSolution(algorithm: 'Hash map')],
    solvedAt: now,
  );
}

void main() {
  late AppDatabase db;
  late RemoteSyncService sync;

  setUp(() {
    db = AppDatabase.inMemory();
    final syncRepo = _OfflineForLeetCode();
    OutboxSyncWorker.initialize(
      db,
      FakeFirebaseFirestore(),
      _StubAuthRepository(),
    );
    final settings = DriftSettingsRepository(db);
    sync = RemoteSyncService(
      syncRepository: syncRepo,
      journalRepository: DriftJournalRepository(db),
      dreamRepository: DriftDreamRepository(db),
      todoRepository: DriftTodoRepository(db),
      leetCodeRepository: DriftLeetCodeRepository(db),
      studyRepository: DriftStudyRepository(db),
      workoutRepository: DriftWorkoutRepository(db),
      jobRepository: DriftJobRepository(db),
      calendarRepository: DriftCalendarRepository(db),
      trackerRepository: DriftTrackerRepository(db),
      financeRepository: DriftFinanceRepository(db),
      notificationRepository: DriftNotificationRepository(db),
      bucketListRepository: DriftBucketListRepository(db),
      settingsRepository: settings,
      weatherService: WeatherService(
        settingsRepository: settings,
        syncRepository: syncRepo,
        weatherApiClient: FakeWeatherApiClient(),
        deviceId: 'device-a',
      ),
      syncEngine: SyncEngine(
        syncRepository: syncRepo,
        deviceId: 'device-a',
        debouncer: Debouncer(delay: Duration.zero),
        // Same three attempts as production, without waiting out the backoff
        // between them — the assertion is about what happens once they're up.
        retryPolicy: const SyncRetryPolicy(initialBackoff: Duration.zero),
      ),
      deviceId: 'device-a',
      uploadDebounceDelay: Duration.zero,
    );
  });

  // Each setUp re-initializes the worker against a fresh database, which is
  // what replaces the singleton — there is no reset hook to call here.
  tearDown(() async => db.close());

  test('a failed LeetCode push is queued for retry, not dropped', () async {
    sync.pushLeetCodeProblem(_problem());
    // The push is deliberately unawaited by its caller, so let the rejection
    // land the way it does at runtime.
    await pumpEventQueue();

    final rows = await db.select(db.pendingUploadsTable).get();
    expect(
      rows.map((r) => (r.collectionName, r.documentId)),
      contains((FirestoreCollections.leetcodeProblems, 'p1')),
      reason: 'nothing else ever re-pushes this document',
    );
    // 'unavailable' is transient, so it belongs in the retry queue rather than
    // parked out of it.
    expect(rows.single.failureReason, isNull);
  });

  test('a later success clears the row the failure left behind', () async {
    await OutboxSyncWorker.recordFailure(
      collection: FirestoreCollections.leetcodeProblems,
      documentId: 'p1',
      error: FirebaseException(plugin: 'cloud_firestore', code: 'unavailable'),
    );
    expect(await db.select(db.pendingUploadsTable).get(), hasLength(1));

    await OutboxSyncWorker.recordSuccess(
      collection: FirestoreCollections.leetcodeProblems,
      documentId: 'p1',
    );

    expect(await db.select(db.pendingUploadsTable).get(), isEmpty);
  });
}
