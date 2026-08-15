// Regression test for the "restart mid-edit corrupts the CRDT op chain" bug:
//
// If a journal entry's character-op history that reached Firestore is
// incomplete relative to the text actually persisted locally (e.g. the app
// was killed after the document write but before the matching
// sync_operations write landed), reopening the entry used to blindly trust
// whatever partial op history was found. Continuing to type would then diff
// against a stale baseline and could compute fractional-index positions
// that collide with ones already used, producing a "Duplicate fractional
// position" conflict (see CharacterSequenceCrdtMerger.validateOpChain).
//
// RemoteSyncService.prepareEditingSession guards against this: after loading
// a persisted op-chain, it checks whether the chain's reconstructed text
// actually matches the current text, and if not, diffs from the stale
// reconstruction to the current text *on the loaded session* — reusing the
// existing op ids for anything unchanged and tombstoning what's gone —
// rather than discarding the session and reseeding brand-new ops for the
// whole document. Reseeding used to leave the old, never-tombstoned ops
// live on the remote, so the next merge combined them with the fresh
// reseeded ops and doubled every character.
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/debouncer.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/sync/sync_engine.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/services/character_op_session.dart';
import 'package:voyager/domain/services/character_operation.dart';
import 'package:voyager/domain/services/character_sequence_crdt_merger.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/services/weather_service.dart';

import 'fakes/fake_weather_api_client.dart';

SyncOperation _charOpsSyncOperation(List<CharacterOperation> ops) {
  return SyncOperation(
    id: 'device-a_entry-1_0',
    documentId: 'entry-1',
    sequence: 0,
    payload: CharOpsPayload(charOps: ops).encode(),
    deviceId: 'device-a',
    timestamp: DateTime.now().toUtc(),
  );
}

void main() {
  late AppDatabase db;
  late InMemorySyncRepository syncRepo;
  late RemoteSyncService remoteSync;
  late SyncEngine engine;

  setUp(() {
    db = AppDatabase.inMemory();
    syncRepo = InMemorySyncRepository();
    engine = SyncEngine(
      syncRepository: syncRepo,
      deviceId: 'device-a',
      debouncer: Debouncer(delay: Duration.zero),
    );
    remoteSync = RemoteSyncService(
      syncRepository: syncRepo,
      journalRepository: DriftJournalRepository(db),
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

  test(
    'a stale/incomplete persisted op-chain reconstructs the wrong text '
    '(demonstrates the underlying hazard)',
    () {
      // Only the ops for "Hello" made it to the remote op-log, e.g. because
      // the app was killed before the ops for the rest of the edit synced,
      // even though the full "Hello world" was already saved locally.
      final fullSession = CharacterOpSession(clientId: 'device-a');
      fullSession.recordTextChange('', 'Hello world');
      final allOps = fullSession.takePendingOps();
      final partialOps = allOps.sublist(0, 'Hello'.length);

      final reloaded = CharacterOpSession(
        clientId: 'device-a',
        initialOperations: partialOps,
      );

      expect(reloaded.text, 'Hello');
      expect(reloaded.text, isNot('Hello world'));
    },
  );

  test(
    'prepareEditingSession diffs a stale op-chain in place instead of '
    'reseeding',
    () async {
      const entryId = 'entry-1';
      const trueCurrentText = 'Hello world';

      final fullSession = CharacterOpSession(clientId: 'device-a');
      fullSession.recordTextChange('', trueCurrentText);
      final allOps = fullSession.takePendingOps();
      final partialOps = allOps.sublist(0, 'Hello'.length);

      // Seed the fake remote with only the incomplete op-chain.
      await syncRepo.appendOperation(_charOpsSyncOperation(partialOps));

      await remoteSync.prepareEditingSession(
        collection: FirestoreCollections.journalEntries,
        documentId: entryId,
        initialText: trueCurrentText,
      );

      final session = remoteSync.charOpRegistry.session(
        FirestoreCollections.journalEntries,
        entryId,
      );
      expect(session, isNotNull);
      // The guard should have detected the mismatch against the stale
      // 5-character reconstruction and caught the session up to the real
      // text by diffing, not reseeding.
      expect(session!.text, trueCurrentText);

      // The reconciling diff (" world") is pending, same as any other edit —
      // it hasn't reached the remote yet, unlike the original 5 "Hello" ops
      // which are already there (seeded above) and must NOT be resent.
      final reconcileOps = remoteSync.charOpRegistry.takePendingOps(
        FirestoreCollections.journalEntries,
        entryId,
      );
      expect(reconcileOps, hasLength('Hello world'.length - 'Hello'.length));

      // Further edits on the reconciled session must merge and validate
      // cleanly (no colliding fractional positions) against what's actually
      // on the remote.
      remoteSync.recordJournalTextChange(
        entryId: entryId,
        before: trueCurrentText,
        after: '$trueCurrentText!',
      );
      final newOps = remoteSync.charOpRegistry.takePendingOps(
        FirestoreCollections.journalEntries,
        entryId,
      );

      final merger = CharacterSequenceCrdtMerger();
      final merged = merger.mergeOperations(
        [_charOpsSyncOperation(reconcileOps + newOps)],
        [_charOpsSyncOperation(partialOps)],
      );
      expect(() => merger.validateOpChain(merged), returnsNormally);
      expect(merger.applyMergedText(merged), '$trueCurrentText!');
    },
  );

  test(
    'race path does not upload seed ops — only the edit delta is pending',
    () async {
      // Simulates the race condition where a second device (or an app restart)
      // starts typing before prepareEditingSession has finished loading the
      // remote op chain.  The session is created via ensureSession (the race
      // path, markSeedsAsPending = false), so the full document text seeded as
      // initial state must NOT appear in takePendingOps.  Only the actual edit
      // should be pending.
      const text = 'Hello World';
      final session = CharacterOpSession(
        clientId: 'device-b',
        initialText: text,
        seedAsPending: false,  // race path — seeds must not be uploaded
      );

      // No pending ops yet: the seed is internal state only.
      expect(session.takePendingOps(), isEmpty);

      // Now record a real edit (append '!').
      session.recordTextChange(text, '$text!');
      final pending = session.takePendingOps();

      // Only the single inserted character is pending — not the 11 seed ops.
      expect(pending, hasLength(1));
      expect(pending.first.character, '!');
    },
  );

  test(
    'race-path ops merged with existing remote chain have no duplicate positions',
    () {
      // Device A uploaded a full op chain for "Hello World" previously.
      // Device B opens the same entry, races before the fetch completes, and
      // creates a seed session (seeds NOT pending) then appends '!'.  Only
      // the '!' op should reach Firestore.  Merging it with Device A's chain
      // must produce no duplicate fractional positions.
      const text = 'Hello World';

      // Simulate Device A's original chain (full seed, all pending).
      final deviceASession = CharacterOpSession(
        clientId: 'device-a',
        initialText: text,
        seedAsPending: true,
      );
      final deviceAOps = deviceASession.takePendingOps();
      expect(deviceAOps, hasLength(text.length));

      // Device B races: seeds from same text (NOT pending) then edits.
      final deviceBSession = CharacterOpSession(
        clientId: 'device-b',
        initialText: text,
        seedAsPending: false,
      );
      deviceBSession.recordTextChange(text, '$text!');
      final deviceBOps = deviceBSession.takePendingOps();
      expect(deviceBOps, hasLength(1));

      // Merge Device A's full chain with Device B's single-char delta.
      final merger = CharacterSequenceCrdtMerger();
      final merged = merger.mergeOperations(
        [_charOpsSyncOperation(deviceAOps)],
        [_charOpsSyncOperation(deviceBOps)],
      );

      expect(() => merger.validateOpChain(merged), returnsNormally);
      expect(merger.applyMergedText(merged), '$text!');
    },
  );
}
