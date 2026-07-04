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
// RemoteSyncService.prepareEditingSession now guards against this: after
// loading a persisted op-chain, it checks whether the chain's reconstructed
// text actually matches the current text, and reseeds from the current text
// if not.
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
      todoRepository: DriftTodoRepository(db),
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
    'prepareEditingSession reseeds instead of trusting a stale op-chain',
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
      // 5-character reconstruction and reseeded from the real text.
      expect(session!.text, trueCurrentText);

      // Further edits on the reseeded session must merge and validate
      // cleanly (no colliding fractional positions).
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
        [_charOpsSyncOperation(newOps)],
        [],
      );
      expect(() => merger.validateOpChain(merged), returnsNormally);
      expect(merger.applyMergedText(merged), '$trueCurrentText!');
    },
  );
}
