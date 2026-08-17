// Regression tests for the "resolving a conflict seeds the next one" bug.
//
// A journal entry sat permanently in the conflict UI. Its remote op chain held
// 2137 operations, of which exactly three live ones shared a fractional
// position with an earlier op — and validateOpChain rejected any repeated
// position, so SyncConflictDetector quarantined the document on every pull.
// The chain was fine: applyMergedText breaks a position tie on logical clock
// and then client id, and the text it produced was byte-identical to the body
// Firestore already held.
//
// Resolving the conflict could not clear it either, because no resolution path
// removes the colliding operations — and worse, each one rebuilt its editing
// session from the `_remoteCharOps` frozen into the conflict row. That
// snapshot is taken at detection time, so its anchors go stale; a fractional
// index is a pure function of its two anchors, so inserting against stale ones
// regenerates positions the live chain already uses. Resolving a conflict was
// how the next conflict got made.
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/debouncer.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/sync/sync_conflict_detector.dart';
import 'package:voyager/core/sync/sync_engine.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/models/sync_conflict.dart';
import 'package:voyager/domain/services/character_op_session.dart';
import 'package:voyager/domain/services/character_operation.dart';
import 'package:voyager/domain/services/character_sequence_crdt_merger.dart';
import 'package:voyager/domain/services/weather_service.dart';

import 'fakes/fake_weather_api_client.dart';

const _entryId = 'entry-1';

SyncOperation _charOpsSyncOperation(List<CharacterOperation> ops, int sequence) {
  return SyncOperation(
    id: 'device-a_${_entryId}_$sequence',
    documentId: _entryId,
    sequence: sequence,
    payload: CharOpsPayload(charOps: ops).encode(),
    deviceId: 'device-a',
    timestamp: DateTime.now().toUtc(),
  );
}

CharacterOperation _op({
  required String position,
  required int logicalClock,
  required String character,
  String clientId = 'device-a',
}) {
  return CharacterOperation(
    id: '${clientId}_${logicalClock}_$position',
    clientId: clientId,
    logicalClock: logicalClock,
    position: position,
    character: character,
  );
}

void main() {
  group('validateOpChain', () {
    final merger = CharacterSequenceCrdtMerger();

    test('accepts a position tie that logical clock resolves', () {
      // The shape found in the stuck entry: a later insert landed on a
      // position an earlier op already held. The order is still determined.
      final ops = [
        _op(position: 'a0', logicalClock: 1, character: 'h'),
        _op(position: 'cMV', logicalClock: 5159, character: '\n'),
        _op(position: 'cMV', logicalClock: 8058, character: 'S'),
        _op(position: 'cMc', logicalClock: 5161, character: 'o'),
      ];

      expect(() => merger.validateOpChain(ops), returnsNormally);
      expect(merger.applyMergedText(ops), 'h\nSo');
    });

    test('still rejects a tie on position, clock and client id', () {
      final ops = [
        _op(position: 'a0', logicalClock: 1, character: 'x'),
        CharacterOperation(
          id: 'other-id',
          clientId: 'device-a',
          logicalClock: 1,
          position: 'a0',
          character: 'y',
        ),
      ];

      expect(() => merger.validateOpChain(ops), throwsFormatException);
    });

    test('ignores tombstones, which may legally reuse a live position', () {
      final ops = [
        _op(position: 'a0', logicalClock: 1, character: 'x'),
        CharacterOperation(
          id: 'device-a_2_a0',
          clientId: 'device-a',
          logicalClock: 2,
          position: 'a0',
          character: 'y',
          deleted: true,
        ),
      ];

      expect(() => merger.validateOpChain(ops), returnsNormally);
      expect(merger.applyMergedText(ops), 'x');
    });
  });

  test('the detector does not quarantine a chain that resolves cleanly', () {
    final detection = SyncConflictDetector().detectJournalEntryConflict(
      local: null,
      remoteData: const {'title': '', 'body': '\nS'},
      remoteCharOps: [
        _op(position: 'cMV', logicalClock: 5159, character: '\n'),
        _op(position: 'cMV', logicalClock: 8058, character: 'S'),
      ],
    );

    expect(detection.isConflict, isFalse);
  });

  test(
    'diffing from a frozen snapshot collides (demonstrates the hazard)',
    () {
      final authoring = CharacterOpSession(clientId: 'device-a');
      authoring.recordTextChange('', 'Hello');
      final firstOps = authoring.takePendingOps();
      authoring.recordTextChange('Hello', 'Hello!!');
      final laterOps = authoring.takePendingOps();

      // What every resolveConflict* path used to do: seed from the operations
      // frozen in the conflict row, then diff the chosen text onto them.
      final stale = CharacterOpSession(
        clientId: 'device-a',
        initialOperations: firstOps,
      );
      stale.recordTextChange('Hello', 'Hello!!?');

      final positions = [
        for (final op in [...firstOps, ...laterOps, ...stale.takePendingOps()])
          op.position,
      ];
      expect(
        positions.toSet(),
        isNot(hasLength(positions.length)),
        reason: 'the stale anchors should regenerate positions already in use',
      );
    },
  );

  group('conflict resolution', () {
    late AppDatabase db;
    late InMemorySyncRepository syncRepo;
    late DriftJournalRepository journalRepo;
    late RemoteSyncService remoteSync;
    late SyncEngine engine;

    setUp(() {
      db = AppDatabase.inMemory();
      syncRepo = InMemorySyncRepository();
      journalRepo = DriftJournalRepository(db);
      engine = SyncEngine(
        syncRepository: syncRepo,
        deviceId: 'device-a',
        debouncer: Debouncer(delay: Duration.zero),
      );
      remoteSync = RemoteSyncService(
        syncRepository: syncRepo,
        journalRepository: journalRepo,
        dreamRepository: DriftDreamRepository(db),
        todoRepository: DriftTodoRepository(db),
        leetCodeRepository: DriftLeetCodeRepository(db),
        studyRepository: DriftStudyRepository(db),
        workoutRepository: DriftWorkoutRepository(db),
        calendarRepository: DriftCalendarRepository(db),
        trackerRepository: DriftTrackerRepository(db),
        financeRepository: DriftFinanceRepository(db),
        notificationRepository: DriftNotificationRepository(db),
        bucketListRepository: DriftBucketListRepository(db),
        settingsRepository: DriftSettingsRepository(db),
        syncConflictRepository: DriftSyncConflictRepository(db),
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

    test('a quarantined document records why it was quarantined', () async {
      final now = DateTime.utc(2026, 8, 12);
      final remote = JournalEntry(
        id: _entryId,
        journalId: 'journal-1',
        title: '',
        body: 'xy',
        entryDate: now,
        createdAt: now,
        updatedAt: now,
      );
      await syncRepo.upsertDocument(
        FirestoreCollections.journalEntries,
        _entryId,
        journalEntryToFirestore(remote),
      );
      // Two live operations that tie on position, logical clock and client id
      // — the one shape whose ordering really is undetermined.
      await syncRepo.appendOperation(
        _charOpsSyncOperation([
          _op(position: 'a0', logicalClock: 1, character: 'x'),
          const CharacterOperation(
            id: 'a-second-id',
            clientId: 'device-a',
            logicalClock: 1,
            position: 'a0',
            character: 'y',
          ),
        ], 0),
      );

      await remoteSync.pullJournalEntries();

      final conflict = (await remoteSync.listConflicts()).single;
      expect(conflict.reason, SyncConflictReason.corruptedOpChain);

      // And it survives the round trip through SQLite, not just the in-memory
      // object the quarantine built.
      final reread = await DriftSyncConflictRepository(db).getConflict(
        conflict.id,
      );
      expect(reread?.reason, SyncConflictReason.corruptedOpChain);
    });

    test('a reason from a newer build reads back as null, not a crash',
        () async {
      final now = DateTime.utc(2026, 8, 12);
      final repo = DriftSyncConflictRepository(db);
      await db
          .into(db.syncConflictsTable)
          .insert(
            SyncConflictsTableCompanion.insert(
              id: 'c1',
              collection: FirestoreCollections.journalEntries,
              documentId: _entryId,
              localPayloadJson: '{}',
              remotePayloadJson: '{}',
              detectedAt: now,
              reason: const Value('a_reason_invented_later'),
            ),
          );

      expect((await repo.getConflict('c1'))?.reason, isNull);
    });

    test('keeping local rebases on the live chain, not the frozen snapshot',
        () async {
      // The chain on the remote: "Hello" was authored, then "!!" appended.
      final authoring = CharacterOpSession(clientId: 'device-a');
      authoring.recordTextChange('', 'Hello');
      final firstOps = authoring.takePendingOps();
      authoring.recordTextChange('Hello', 'Hello!!');
      final laterOps = authoring.takePendingOps();
      await syncRepo.appendOperation(_charOpsSyncOperation(firstOps, 0));
      await syncRepo.appendOperation(_charOpsSyncOperation(laterOps, 1));

      final now = DateTime.utc(2026, 8, 12);
      final local = JournalEntry(
        id: _entryId,
        journalId: 'journal-1',
        title: '',
        body: 'Hello!!?',
        entryDate: now,
        createdAt: now,
        updatedAt: now,
      );
      await journalRepo.upsertEntry(local, recordLocalActivity: false);

      // The conflict was detected back when the chain still ended at "Hello",
      // so that is what its payload froze — the anchors in it are two
      // characters behind the log.
      await DriftSyncConflictRepository(db).upsertConflict(
        SyncConflict(
          id: '${FirestoreCollections.journalEntries}_$_entryId',
          collection: FirestoreCollections.journalEntries,
          documentId: _entryId,
          localPayloadJson: jsonEncode(journalEntryToFirestore(local)),
          remotePayloadJson: jsonEncode({
            'body': 'Hello',
            '_remoteCharOps': [for (final op in firstOps) op.toJson()],
          }),
          remoteText: 'Hello',
          localText: local.body,
          detectedAt: now,
        ),
      );

      final conflict = (await remoteSync.listConflicts()).single;
      await remoteSync.resolveConflictKeepLocal(conflict);

      final merger = CharacterSequenceCrdtMerger();
      final merged = merger.mergeOperations(
        const [],
        await syncRepo.listOperations(_entryId),
      );
      final live = merged.where((op) => !op.deleted).toList();

      // Diffing from the stale snapshot's "Hello" would have re-inserted "!!"
      // at the positions the log already holds for them.
      expect(
        live.map((op) => op.position).toSet(),
        hasLength(live.length),
        reason: 'resolution minted a position the live chain already used',
      );
      expect(merger.applyMergedText(merged), 'Hello!!?');
      expect(await remoteSync.listConflicts(), isEmpty);
    });
  });
}
