import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/debouncer.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/sync/sync_engine.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/services/character_op_session.dart';
import 'package:voyager/domain/services/character_operation.dart';
import 'package:voyager/domain/services/character_sequence_crdt_merger.dart';
import 'package:voyager/domain/services/weather_service.dart';

import 'fakes/fake_weather_api_client.dart';

void main() {
  late AppDatabase db;
  late InMemorySyncRepository syncRepo;
  late SyncEngine engine;
  late RemoteSyncService service;

  setUp(() {
    db = AppDatabase.inMemory();
    syncRepo = InMemorySyncRepository();
    engine = SyncEngine(
      syncRepository: syncRepo,
      deviceId: 'device-a',
      debouncer: Debouncer(delay: Duration.zero),
    );
    service = RemoteSyncService(
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
      settingsRepository: DriftSettingsRepository(db),
      weatherService: WeatherService(
        settingsRepository: DriftSettingsRepository(db),
        syncRepository: syncRepo,
        weatherApiClient: FakeWeatherApiClient(),
        deviceId: 'device-a',
      ),
      syncEngine: engine,
      deviceId: 'device-a',
      uploadDebounceDelay: Duration.zero,
    );
  });

  tearDown(() async {
    engine.dispose();
    await db.close();
  });

  /// Replays [saves] single-character edits into the log the way real editing
  /// would, one operation document per save.
  Future<String> seedOperationLog({
    required int saves,
    String deviceId = 'device-a',
    DateTime? timestamp,
  }) async {
    final session = CharacterOpSession(clientId: deviceId, initialText: '');
    var text = '';
    for (var i = 0; i < saves; i++) {
      final next = '$text${String.fromCharCode(97 + i % 26)}';
      session.recordTextChange(text, next);
      text = next;
      await syncRepo.appendOperation(
        SyncOperation(
          id: '${deviceId}_doc-1_$i',
          documentId: 'doc-1',
          sequence: i + 1,
          payload: CharOpsPayload(
            charOps: session.takePendingOps(),
            snapshot: {'body': next},
          ).encode(),
          deviceId: deviceId,
          timestamp:
              timestamp ??
              DateTime.now().toUtc().subtract(const Duration(days: 3)),
        ),
      );
    }
    return text;
  }

  Future<String> resolvedBody() async {
    final ops = await syncRepo.listOperations('doc-1');
    final merged = CharacterSequenceCrdtMerger().applyMergedPayload(ops);
    return (jsonDecode(merged) as Map)['body'] as String;
  }

  test('collapses a long log while preserving the resolved text', () async {
    final text = await seedOperationLog(
      saves: RemoteSyncService.operationLogCompactionThreshold + 50,
    );
    expect(await resolvedBody(), text);

    final compacted = await service.compactOperationLog('doc-1');

    expect(compacted, isTrue);
    expect(await syncRepo.listOperations('doc-1'), hasLength(1));
    expect(await resolvedBody(), text);
  });

  test('leaves a short log alone', () async {
    await seedOperationLog(
      saves: RemoteSyncService.operationLogCompactionThreshold - 1,
    );
    final before = (await syncRepo.listOperations('doc-1')).length;

    expect(await service.compactOperationLog('doc-1'), isFalse);
    expect(await syncRepo.listOperations('doc-1'), hasLength(before));
  });

  test('drops tombstones for text that was deleted', () async {
    // Type past the threshold, then delete most of it. The tombstoned
    // characters are what compaction is meant to shed.
    final typed = await seedOperationLog(
      saves: RemoteSyncService.operationLogCompactionThreshold + 20,
    );
    final session = CharacterOpSession(
      clientId: 'device-a',
      initialOperations: CharacterSequenceCrdtMerger().mergeOperations(
        const [],
        await syncRepo.listOperations('doc-1'),
      ),
    );
    session.recordTextChange(typed, 'short');
    await syncRepo.appendOperation(
      SyncOperation(
        id: 'device-a_doc-1_trim',
        documentId: 'doc-1',
        sequence: 100000,
        payload: CharOpsPayload(
          charOps: session.takePendingOps(),
          snapshot: {'body': 'short'},
        ).encode(),
        deviceId: 'device-a',
        timestamp: DateTime.now().toUtc().subtract(const Duration(days: 3)),
      ),
    );
    expect(await resolvedBody(), 'short');

    expect(await service.compactOperationLog('doc-1'), isTrue);

    final remaining = await syncRepo.listOperations('doc-1');
    expect(remaining, hasLength(1));
    expect(await resolvedBody(), 'short');
    final payload = CharOpsPayload.tryParse(remaining.single.payload)!;
    expect(payload.charOps, hasLength('short'.length));
    expect(payload.charOps.any((op) => op.deleted), isFalse);
  });

  test('backs off while another device is still writing', () async {
    await seedOperationLog(
      saves: RemoteSyncService.operationLogCompactionThreshold + 10,
    );
    await syncRepo.appendOperation(
      SyncOperation(
        id: 'device-b_doc-1_recent',
        documentId: 'doc-1',
        sequence: 99999,
        payload: CharOpsPayload(
          charOps: const [],
          snapshot: {'body': 'from b'},
        ).encode(),
        deviceId: 'device-b',
        timestamp: DateTime.now().toUtc(),
      ),
    );
    final before = (await syncRepo.listOperations('doc-1')).length;

    expect(await service.compactOperationLog('doc-1'), isFalse);
    expect(await syncRepo.listOperations('doc-1'), hasLength(before));
  });

  test('compacts once another device has gone quiet', () async {
    final text = await seedOperationLog(
      saves: RemoteSyncService.operationLogCompactionThreshold + 10,
    );
    await syncRepo.appendOperation(
      SyncOperation(
        id: 'device-b_doc-1_old',
        documentId: 'doc-1',
        sequence: 99999,
        payload: CharOpsPayload(
          charOps: const [],
          snapshot: {'body': text},
        ).encode(),
        deviceId: 'device-b',
        timestamp: DateTime.now().toUtc().subtract(const Duration(days: 5)),
      ),
    );

    expect(await service.compactOperationLog('doc-1'), isTrue);
    expect(await syncRepo.listOperations('doc-1'), hasLength(1));
    expect(await resolvedBody(), text);
  });
}
