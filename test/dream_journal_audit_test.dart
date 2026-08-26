// Regressions for the Dream Journal defects catalogued in AUDIT.md.
//
// Each test asserts the behaviour that was wrong rather than the shape of the
// fix, so a later refactor is free to move the code as long as dreams keep
// landing, staying deleted, and not inventing days on the heatmap.

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
import 'package:voyager/domain/models/analytics_models.dart';
import 'package:voyager/domain/models/dream_models.dart';
import 'package:voyager/domain/services/weather_service.dart';

import 'fakes/fake_weather_api_client.dart';

DreamEntry _dream({
  required String id,
  String title = 'Flight',
  String body = 'I was flying.',
  DateTime? entryDate,
  DateTime? stamp,
  int version = 0,
}) {
  final now = stamp ?? DateTime.utc(2026, 3, 1, 12);
  return DreamEntry(
    id: id,
    title: title,
    body: body,
    entryDate: entryDate ?? now,
    createdAt: now,
    updatedAt: now,
    version: version,
  );
}

void main() {
  late AppDatabase db;
  late DriftDreamRepository dreamRepo;
  late InMemorySyncRepository syncRepo;
  late SyncEngine engine;
  late RemoteSyncService sync;

  setUp(() {
    db = AppDatabase.inMemory();
    dreamRepo = DriftDreamRepository(db);
    syncRepo = InMemorySyncRepository();
    engine = SyncEngine(
      syncRepository: syncRepo,
      deviceId: 'device-a',
      debouncer: Debouncer(delay: Duration.zero),
    );
    sync = RemoteSyncService(
      syncRepository: syncRepo,
      journalRepository: DriftJournalRepository(db),
      dreamRepository: dreamRepo,
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
      settingsRepository: DriftSettingsRepository(db),
      weatherService: WeatherService(
        settingsRepository: DriftSettingsRepository(db),
        syncRepository: syncRepo,
        weatherApiClient: FakeWeatherApiClient(),
        deviceId: 'device-a',
      ),
      syncEngine: engine,
      uploadDebounceDelay: Duration.zero,
    );
  });

  tearDown(() async {
    engine.dispose();
    await db.close();
  });

  test('an autosave upload publishes the edit time, not the upload time',
      () async {
    // Restamping updatedAt made the remote copy unconditionally newer than the
    // row it came from. Since the autosave path uploads at an unchanged
    // version, remoteVersionWins falls through to the updatedAt tie-break —
    // and every later pull then resolved in the remote's favour, reverting
    // edits made locally after the upload.
    final entry = _dream(id: newId(), stamp: DateTime.utc(2026, 3, 1, 9));
    await dreamRepo.upsertEntry(entry);

    sync.pushDreamEntryNow(entry);
    await pumpEventQueue();

    final document = await syncRepo.getDocument(
      FirestoreCollections.dreamEntries,
      entry.id,
    );
    expect(document, isNotNull);
    expect(parseFirestoreDate(document!['updatedAt']), entry.updatedAt);
    expect(document['version'], entry.version);
  });

  test('soft deleting a dream bumps its version', () async {
    // A tombstone that does not outrank the remote copy is read as the loser
    // by the next device to pull, which then pushes its own live row back and
    // resurrects the dream everywhere.
    final entry = _dream(id: newId(), version: 4);
    await dreamRepo.upsertEntry(entry);

    await dreamRepo.softDeleteEntry(entry.id);

    final tombstone = await dreamRepo.getEntry(entry.id);
    expect(tombstone, isNotNull);
    expect(tombstone!.deletedAt, isNotNull);
    expect(tombstone.version, greaterThan(entry.version));
    // The rest of the row survives, so the tombstone is still a valid entry.
    expect(tombstone.title, entry.title);
  });

  test('the "Dream Logged" tracker ignores an abandoned "New dream"', () async {
    final day = DateTime(2026, 3, 4, 21);
    final values = dreamLoggedTrackerValues([
      _dream(id: 'blank', title: '', body: '   ', entryDate: day),
      _dream(id: 'real', entryDate: DateTime(2026, 3, 5, 8)),
    ]);

    expect(values.map((value) => value.periodStart), [DateTime(2026, 3, 5)]);
  });
}
