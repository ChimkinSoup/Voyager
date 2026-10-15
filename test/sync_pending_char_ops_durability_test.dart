import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/debouncer.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/sync/sync_engine.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/settings_models.dart';

/// An [InMemorySyncRepository] whose writes can be switched off, standing in
/// for an unreachable or wedged Firestore.
class _FlakySyncRepository extends InMemorySyncRepository {
  bool offline = false;

  void _check() {
    if (offline) {
      throw FirebaseException(plugin: 'cloud_firestore', code: 'unavailable');
    }
  }

  @override
  Future<void> appendOperation(SyncOperation operation) async {
    _check();
    return super.appendOperation(operation);
  }

  @override
  Future<void> appendOperationGroup(List<SyncOperation> operations) async {
    _check();
    return super.appendOperationGroup(operations);
  }

  @override
  Future<void> upsertDocument(
    String collection,
    String id,
    Map<String, dynamic> data,
  ) async {
    _check();
    return super.upsertDocument(collection, id, data);
  }
}

void main() {
  late AppDatabase db;
  late _FlakySyncRepository syncRepo;
  late DriftJournalRepository journalRepo;

  RemoteSyncService buildService({
    AppDatabase? database,
    String deviceId = 'device-a',
    Duration uploadDebounceDelay = Duration.zero,
  }) {
    final db0 = database ?? db;
    final engine = SyncEngine(
      syncRepository: syncRepo,
      deviceId: deviceId,
      debouncer: Debouncer(delay: Duration.zero),
      retryPolicy: const SyncRetryPolicy(maxAttempts: 1),
    );
    return RemoteSyncService(
      syncRepository: syncRepo,
      journalRepository: database == null
          ? journalRepo
          : DriftJournalRepository(db0),
      dreamRepository: DriftDreamRepository(db0),
      todoRepository: DriftTodoRepository(db0),
      leetCodeRepository: DriftLeetCodeRepository(db0),
      studyRepository: DriftStudyRepository(db0),
      workoutRepository: DriftWorkoutRepository(db0),
      jobRepository: DriftJobRepository(db0),
      rankingRepository: DriftRankingRepository(db0),
      calendarRepository: DriftCalendarRepository(db0),
      trackerRepository: DriftTrackerRepository(db0),
      financeRepository: DriftFinanceRepository(db0),
      notificationRepository: DriftNotificationRepository(db0),
      reminderRepository: DriftReminderRepository(db0),
      bucketListRepository: DriftBucketListRepository(db0),
      mediaRepository: DriftMediaRepository(db0),
      settingsRepository: DriftSettingsRepository(db0),
      syncEngine: engine,
      syncConflictRepository: DriftSyncConflictRepository(db0),
      deviceId: deviceId,
      uploadDebounceDelay: uploadDebounceDelay,
    );
  }

  setUp(() {
    db = AppDatabase.inMemory();
    syncRepo = _FlakySyncRepository();
    journalRepo = DriftJournalRepository(db);
  });

  tearDown(() async => db.close());

  /// Types [after] over [before] the way the journal editor does: record the
  /// character delta, persist the row, then flush without waiting on the
  /// network.
  Future<void> typeAndSave(
    RemoteSyncService service,
    String entryId, {
    required String before,
    required String after,
  }) async {
    service.recordJournalTextChange(
      entryId: entryId,
      before: before,
      after: after,
    );
    await service.saveJournalEntryThenScheduleUpload(
      entryId: entryId,
      saveLocal: () async {
        final current = await journalRepo.getEntry(entryId);
        await journalRepo.upsertEntry(current!.copyWith(body: after));
      },
    );
    await service.flushDocumentLocal(
      FirestoreCollections.journalEntries,
      entryId,
    );
    // Let the background upload started by the local flush settle.
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }

  Future<String> seedSyncedEntry(RemoteSyncService service) async {
    final now = utcNow();
    final entry = JournalEntry(
      id: 'entry-1',
      journalId: 'journal-1',
      title: 'Title',
      body: 'Hello',
      entryDate: now,
      createdAt: now,
      updatedAt: now,
    );
    await journalRepo.upsertEntry(entry);
    await service.prepareEditingSession(
      collection: FirestoreCollections.journalEntries,
      documentId: entry.id,
      initialText: entry.body,
    );
    await service.flushDocument(FirestoreCollections.journalEntries, entry.id);
    service.pushJournalEntryNow((await journalRepo.getEntry(entry.id))!);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(await syncRepo.listOperations(entry.id), isNotEmpty);
    return entry.id;
  }

  group('offline text edits whose operations never left memory', () {
    test('survive a restart followed by the startup pull', () async {
      final before = buildService();
      final id = await seedSyncedEntry(before);

      syncRepo.offline = true;
      await typeAndSave(before, id, before: 'Hello', after: 'Hello world');
      expect((await journalRepo.getEntry(id))!.body, 'Hello world');

      // Restart: the pending character operations lived only in the old
      // service's registry.
      before.dispose();
      syncRepo.offline = false;
      final after = buildService();

      await after.pullJournalEntries();

      expect((await journalRepo.getEntry(id))!.body, 'Hello world');
    });

    test('survive a restart, the outbox replay, then the pull', () async {
      final before = buildService();
      final id = await seedSyncedEntry(before);

      syncRepo.offline = true;
      await typeAndSave(before, id, before: 'Hello', after: 'Hello world');

      before.dispose();
      syncRepo.offline = false;
      final after = buildService();

      // What OutboxSyncWorker.startDraining does for a crdt-backed row.
      await after.pushOutboxDocument(FirestoreCollections.journalEntries, id);
      await after.pullJournalEntries();

      expect((await journalRepo.getEntry(id))!.body, 'Hello world');
    });

    test('survive a reconnect pull while the entry is not open', () async {
      final service = buildService();
      final id = await seedSyncedEntry(service);

      syncRepo.offline = true;
      await typeAndSave(service, id, before: 'Hello', after: 'Hello world');

      // Back online. `_resumeSyncAfterReconnect` pulls concurrently with the
      // drain; here the pull simply lands first.
      syncRepo.offline = false;
      await service.pullJournalEntries();

      expect((await journalRepo.getEntry(id))!.body, 'Hello world');
    });
  });

  // BUG-238: typed and saved here, killed before the upload, and the other
  // device edits the entry before this one restarts. The startup pull found
  // the cloud newer and took its text over the row.
  group('characters saved but never sent, then moved on elsewhere', () {
    Future<(RemoteSyncService, DriftJournalRepository)> deviceB(
      String id,
    ) async {
      final dbB = AppDatabase.inMemory();
      addTearDown(dbB.close);
      final repoB = DriftJournalRepository(dbB);
      final b = buildService(database: dbB, deviceId: 'device-b');
      await b.pullJournalEntries();
      return (b, repoB);
    }

    Future<void> appendOnB(
      RemoteSyncService b,
      DriftJournalRepository repoB,
      String id,
      String after,
    ) async {
      final before = (await repoB.getEntry(id))!.body;
      await b.prepareEditingSession(
        collection: FirestoreCollections.journalEntries,
        documentId: id,
        initialText: before,
      );
      b.recordJournalTextChange(entryId: id, before: before, after: after);
      await b.saveJournalEntryThenScheduleUpload(
        entryId: id,
        saveLocal: () async {
          final current = await repoB.getEntry(id);
          await repoB.upsertEntry(current!.copyWith(body: after));
        },
      );
      await b.flushDocument(FirestoreCollections.journalEntries, id);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    test('are kept and sent after the restart', () async {
      final a = buildService();
      final id = await seedSyncedEntry(a);
      final (b, repoB) = await deviceB(id);

      // A's autosave lands; the upload never does.
      final row = (await journalRepo.getEntry(id))!;
      await journalRepo.upsertEntry(
        row.copyWith(body: 'Hello world', bumpVersion: false),
      );
      a.dispose();

      await appendOnB(b, repoB, id, 'Hello. B more');

      final restarted = buildService();
      await restarted.pullJournalEntries();
      expect((await journalRepo.getEntry(id))!.body, 'Hello world. B more');

      // Sent by the pull itself, with nothing else saved or drained.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await b.pullJournalEntries();
      expect((await repoB.getEntry(id))!.body, 'Hello world. B more');
    });

    // In the app the journal page reopens the entry at launch, and its
    // editor loads the log before the pull: a session with nothing pending.
    test('are kept and sent when the editor reopened the entry first', () async {
      final a = buildService();
      final id = await seedSyncedEntry(a);
      final (b, repoB) = await deviceB(id);

      final row = (await journalRepo.getEntry(id))!;
      await journalRepo.upsertEntry(
        row.copyWith(body: 'Hello world', bumpVersion: false),
      );
      a.dispose();

      await appendOnB(b, repoB, id, 'Hello. B more');

      final restarted = buildService();
      await restarted.prepareEditingSession(
        collection: FirestoreCollections.journalEntries,
        documentId: id,
        initialText: 'Hello world',
      );
      await restarted.pullJournalEntries();
      expect((await journalRepo.getEntry(id))!.body, 'Hello world. B more');

      await Future<void>.delayed(const Duration(milliseconds: 100));
      await b.pullJournalEntries();
      expect((await repoB.getEntry(id))!.body, 'Hello world. B more');
    });

    // The other shape seen in the app: the reopened editor re-anchors its
    // session as a seed of the row's text, which then shows in the resolved
    // text too. Uploading that seed would double the entry (BUG-220).
    test('are kept and sent, once, when the editor holds a seed of the row', () async {
      final a = buildService();
      final id = await seedSyncedEntry(a);
      final (b, repoB) = await deviceB(id);

      final row = (await journalRepo.getEntry(id))!;
      await journalRepo.upsertEntry(
        row.copyWith(body: 'Hello world', bumpVersion: false),
      );
      a.dispose();

      await appendOnB(b, repoB, id, 'Hello. B more');

      final restarted = buildService();
      restarted.charOpRegistry.ensureSession(
        collection: FirestoreCollections.journalEntries,
        documentId: id,
        clientId: 'device-a',
        initialText: 'Hello world',
        markSeedsAsPending: true,
      );
      await restarted.pullJournalEntries();
      expect((await journalRepo.getEntry(id))!.body, 'Hello world. B more');

      await Future<void>.delayed(const Duration(milliseconds: 100));
      await b.pullJournalEntries();
      expect((await repoB.getEntry(id))!.body, 'Hello world. B more');
    });

    // A save already queued is left to run: each pull replaced it, restarting
    // its debounce for as long as the other device kept editing.
    test('a queued upload is not put off by pulls while the other device '
        'keeps editing', () async {
      final a = buildService(uploadDebounceDelay: const Duration(seconds: 1));
      final id = await seedSyncedEntry(a);
      final (b, repoB) = await deviceB(id);

      final clock = Stopwatch()..start();
      Future<void> until(int ms) =>
          Future<void>.delayed(Duration(milliseconds: ms) - clock.elapsed);
      a.recordJournalTextChange(
        entryId: id,
        before: 'Hello',
        after: 'Hello world',
      );
      await a.saveJournalEntryThenScheduleUpload(
        entryId: id,
        saveLocal: () async {
          final current = await journalRepo.getEntry(id);
          await journalRepo.upsertEntry(current!.copyWith(body: 'Hello world'));
        },
      );

      await appendOnB(b, repoB, id, 'Hello. B');
      await until(300);
      await a.pullJournalEntries();
      await appendOnB(b, repoB, id, 'Hello. B more');
      await until(700);
      await a.pullJournalEntries();
      expect(clock.elapsed, lessThan(const Duration(seconds: 1)));

      // Due at 1s from the save; a debounce restarted at 700ms isn't.
      await until(1400);
      await b.pullJournalEntries();
      expect((await repoB.getEntry(id))!.body, contains('world'));
    });

    test('text the other device deleted is not brought back', () async {
      final a = buildService();
      final id = await seedSyncedEntry(a);
      final (b, repoB) = await deviceB(id);
      a.dispose();

      // A never changed anything; B deletes "llo".
      await appendOnB(b, repoB, id, 'He');

      final restarted = buildService();
      await restarted.pullJournalEntries();
      expect((await journalRepo.getEntry(id))!.body, 'He');
    });
  });

  group('text written to the row outside any editing session', () {
    test(
      'survives a pull after the row is published without its operations',
      () async {
        final before = buildService();
        final id = await seedSyncedEntry(before);
        before.dispose();

        // A recovery writes the text straight to SQLite, so no character
        // operation ever records it.
        final seeded = (await journalRepo.getEntry(id))!;
        await journalRepo.upsertEntry(
          seeded.copyWith(body: 'Hello world', bumpVersion: true),
        );

        // Any later save publishes the row as it stands: a snapshot at the
        // row's own revision, beside a log that still spells 'Hello'.
        final after = buildService();
        after.pushJournalEntryNow((await journalRepo.getEntry(id))!);
        await Future<void>.delayed(const Duration(milliseconds: 50));

        await after.pullJournalEntries();
        expect((await journalRepo.getEntry(id))!.body, 'Hello world');

        // What the drain does with the upload the pull found owed.
        await after.pushOutboxDocument(FirestoreCollections.journalEntries, id);
        final dbB = AppDatabase.inMemory();
        addTearDown(dbB.close);
        final b = buildService(database: dbB, deviceId: 'device-b');
        await b.pullJournalEntries();
        expect(
          (await DriftJournalRepository(dbB).getEntry(id))!.body,
          'Hello world',
        );
      },
    );

    test(
      "a stale row republished at its revision still takes the log's text",
      () async {
        final a = buildService();
        final id = await seedSyncedEntry(a);
        a.dispose();

        final dbB = AppDatabase.inMemory();
        addTearDown(dbB.close);
        final repoB = DriftJournalRepository(dbB);
        final b = buildService(database: dbB, deviceId: 'device-b');
        await b.pullJournalEntries();
        await b.prepareEditingSession(
          collection: FirestoreCollections.journalEntries,
          documentId: id,
          initialText: 'Hello',
        );
        b.recordJournalTextChange(
          entryId: id,
          before: 'Hello',
          after: 'Hello there',
        );
        await b.saveJournalEntryThenScheduleUpload(
          entryId: id,
          saveLocal: () async {
            final current = await repoB.getEntry(id);
            await repoB.upsertEntry(current!.copyWith(body: 'Hello there'));
          },
        );
        await b.flushDocument(FirestoreCollections.journalEntries, id);

        // A has not pulled B's edit and changes the mood, publishing its stale
        // 'Hello' as the newest revision.
        await Future<void>.delayed(const Duration(milliseconds: 5));
        final stale = (await journalRepo.getEntry(id))!.copyWith(mood: 3);
        await journalRepo.upsertEntry(stale);
        final a2 = buildService();
        a2.pushJournalEntryNow(stale);
        await Future<void>.delayed(const Duration(milliseconds: 50));

        await a2.pullJournalEntries();
        expect((await journalRepo.getEntry(id))!.body, 'Hello there');
      },
    );
  });

  group('a pulled body pushed into an open editor', () {
    test("does not duplicate the other device's insertion", () async {
      final a = buildService();
      final id = await seedSyncedEntry(a);

      // Device B, its own database, pulls the entry and appends to it.
      final dbB = AppDatabase.inMemory();
      addTearDown(dbB.close);
      final repoB = DriftJournalRepository(dbB);
      final b = buildService(database: dbB, deviceId: 'device-b');
      await b.pullJournalEntries();
      expect((await repoB.getEntry(id))!.body, 'Hello');
      await b.prepareEditingSession(
        collection: FirestoreCollections.journalEntries,
        documentId: id,
        initialText: 'Hello',
      );
      b.recordJournalTextChange(
        entryId: id,
        before: 'Hello',
        after: 'Hello there',
      );
      await b.saveJournalEntryThenScheduleUpload(
        entryId: id,
        saveLocal: () async {
          final current = await repoB.getEntry(id);
          await repoB.upsertEntry(current!.copyWith(body: 'Hello there'));
        },
      );
      await b.flushDocument(FirestoreCollections.journalEntries, id);

      // Device A has the entry open but unfocused; live sync pulls B's edit.
      await a.pullJournalEntries();
      final pulled = (await journalRepo.getEntry(id))!.body;
      expect(pulled, 'Hello there');

      // JournalPage's provider listener: setBodyText(updated.body,
      // recordAsEdit: true) on the mounted editor, whose text was 'Hello'.
      a.recordJournalTextChange(entryId: id, before: 'Hello', after: pulled);
      // The next save of the entry on A (any keystroke, a metadata change).
      await a.saveJournalEntryThenScheduleUpload(
        entryId: id,
        saveLocal: () async {
          final current = await journalRepo.getEntry(id);
          await journalRepo.upsertEntry(current!.copyWith(title: 'Renamed'));
        },
      );
      await a.flushDocument(FirestoreCollections.journalEntries, id);

      await b.pullJournalEntries();
      expect((await repoB.getEntry(id))!.body, 'Hello there');
    });
  });

  group('a remote edit merged into a focused editor', () {
    test('keeps both texts intact once the next keystroke uploads', () async {
      final a = buildService();
      final id = await seedSyncedEntry(a);
      // A has seen its own text come back, so the buffer knows the baseline.
      await a.pullJournalEntries();

      final dbB = AppDatabase.inMemory();
      addTearDown(dbB.close);
      final repoB = DriftJournalRepository(dbB);
      final b = buildService(database: dbB, deviceId: 'device-b');
      await b.pullJournalEntries();
      await b.prepareEditingSession(
        collection: FirestoreCollections.journalEntries,
        documentId: id,
        initialText: 'Hello',
      );
      b.recordJournalTextChange(
        entryId: id,
        before: 'Hello',
        after: 'Hello there',
      );
      await b.saveJournalEntryThenScheduleUpload(
        entryId: id,
        saveLocal: () async {
          final current = await repoB.getEntry(id);
          await repoB.upsertEntry(current!.copyWith(body: 'Hello there'));
        },
      );
      await b.flushDocument(FirestoreCollections.journalEntries, id);

      // A is typing in the entry, so the pull buffers B's text instead.
      a.setDocumentEditing(
        collection: FirestoreCollections.journalEntries,
        documentId: id,
        isEditing: true,
      );
      await a.pullJournalEntries();
      // The page's flush: merge the buffered delta into the editor text
      // ('Hello'), then setBodyText(merged) with recordAsEdit false.
      final merged = await a.applyPendingJournalEntryTextMerge(
        entryId: id,
        currentLocalText: 'Hello',
      );
      expect(merged!.body, 'Hello there');

      // The next keystroke, diffed from the editor's text.
      await typeAndSave(a, id, before: 'Hello there', after: 'Hello there!');
      await a.flushDocument(FirestoreCollections.journalEntries, id);

      await b.pullJournalEntries();
      expect((await repoB.getEntry(id))!.body, 'Hello there!');
    });
  });

  group('opening an entry whose remote log is ahead of this device', () {
    test("keeps the other device's text when this one edits", () async {
      final a = buildService();
      final id = await seedSyncedEntry(a);
      // A closes the entry (a restart, or the service being rebuilt).
      a.dispose();

      final dbB = AppDatabase.inMemory();
      addTearDown(dbB.close);
      final repoB = DriftJournalRepository(dbB);
      final b = buildService(database: dbB, deviceId: 'device-b');
      await b.pullJournalEntries();
      await b.prepareEditingSession(
        collection: FirestoreCollections.journalEntries,
        documentId: id,
        initialText: 'Hello',
      );
      b.recordJournalTextChange(
        entryId: id,
        before: 'Hello',
        after: 'Hello there',
      );
      await b.saveJournalEntryThenScheduleUpload(
        entryId: id,
        saveLocal: () async {
          final current = await repoB.getEntry(id);
          await repoB.upsertEntry(current!.copyWith(body: 'Hello there'));
        },
      );
      await b.flushDocument(FirestoreCollections.journalEntries, id);

      // A has not pulled B's edit yet (no live sync, or before the startup
      // pull) and opens the entry from its own SQLite row.
      final a2 = buildService();
      await a2.prepareEditingSession(
        collection: FirestoreCollections.journalEntries,
        documentId: id,
        initialText: 'Hello',
      );
      await typeAndSave(a2, id, before: 'Hello', after: 'Hello!');
      await a2.flushDocument(FirestoreCollections.journalEntries, id);

      await b.pullJournalEntries();
      expect((await repoB.getEntry(id))!.body, contains('there'));
    });
  });

  // BUG-258: an entry opened at launch shows the row from before the pull.
  // Typing there was rebased onto the session, which had the other device's
  // text, but the editor never showed it and its saves kept it out of the row.
  group('an editor opened on a row behind the log', () {
    /// Seeds "Hello" from A, then has B add " there" while A is closed.
    Future<RemoteSyncService> extendOnB(String id) async {
      final dbB = AppDatabase.inMemory();
      addTearDown(dbB.close);
      final repoB = DriftJournalRepository(dbB);
      final b = buildService(database: dbB, deviceId: 'device-b');
      await b.pullJournalEntries();
      await b.prepareEditingSession(
        collection: FirestoreCollections.journalEntries,
        documentId: id,
        initialText: 'Hello',
      );
      b.recordJournalTextChange(
        entryId: id,
        before: 'Hello',
        after: 'Hello there',
      );
      await b.saveJournalEntryThenScheduleUpload(
        entryId: id,
        saveLocal: () async {
          final current = await repoB.getEntry(id);
          await repoB.upsertEntry(current!.copyWith(body: 'Hello there'));
        },
      );
      await b.flushDocument(FirestoreCollections.journalEntries, id);
      return b;
    }

    /// An open, focused editor on [service] showing "Hello", as the Journal
    /// page registers one; the returned list holds what it shows.
    List<String> openEditor(RemoteSyncService service, String id) {
      final shown = ['Hello'];
      service.addPendingTextMergeListener(
        collection: FirestoreCollections.journalEntries,
        documentId: id,
        listener: (event) {
          final value = event.mergedInto(TextEditingValue(text: shown[0]));
          if (value == null) return false;
          shown[0] = value.text;
          return true;
        },
      );
      service.setDocumentEditing(
        collection: FirestoreCollections.journalEntries,
        documentId: id,
        isEditing: true,
      );
      return shown;
    }

    test("takes the log's text when it opens", () async {
      final a = buildService();
      final id = await seedSyncedEntry(a);
      a.dispose();
      await extendOnB(id);

      final a2 = buildService();
      final editor = openEditor(a2, id);
      await a2.prepareEditingSession(
        collection: FirestoreCollections.journalEntries,
        documentId: id,
        initialText: 'Hello',
      );

      expect(editor[0], 'Hello there');
    });

    test('is brought up by a keystroke rebased onto the session', () async {
      final a = buildService();
      final id = await seedSyncedEntry(a);
      a.dispose();
      final b = await extendOnB(id);

      final a2 = buildService();
      // Registered after the open, so only the keystroke can reach it.
      await a2.prepareEditingSession(
        collection: FirestoreCollections.journalEntries,
        documentId: id,
        initialText: 'Hello',
      );
      final editor = openEditor(a2, id);
      editor[0] = 'Hello!';
      await typeAndSave(a2, id, before: 'Hello', after: 'Hello!');
      // The page saves what its editor took.
      await journalRepo.upsertEntry(
        (await journalRepo.getEntry(id))!.copyWith(body: editor[0]),
      );
      await a2.pullJournalEntries();

      expect(editor[0], 'Hello! there');
      expect((await journalRepo.getEntry(id))!.body, 'Hello! there');
      await a2.flushDocument(FirestoreCollections.journalEntries, id);
      await b.pullJournalEntries();
    });
  });

  group('the settings document', () {
    test(
      "navigating on one device keeps another device's newer profile edit",
      () async {
        final a = buildService();
        final repoA = DriftSettingsRepository(db);
        final dbB = AppDatabase.inMemory();
        addTearDown(dbB.close);
        final repoB = DriftSettingsRepository(dbB);
        final b = buildService(database: dbB, deviceId: 'device-b');

        // Both devices start in step.
        await b.pushSettings(await repoB.getSettings());
        await a.pullSettings();

        // B records something the user typed.
        await Future<void>.delayed(const Duration(milliseconds: 5));
        await repoB.saveSettings(
          (await repoB.getSettings()).copyWith(
            jobProfileGitHubUrl: 'https://github.com/me',
          ),
        );
        await b.pushSettings(await repoB.getSettings());

        // A has not pulled since, and the user moves to another page on it.
        await Future<void>.delayed(const Duration(milliseconds: 5));
        await repoA.saveSettings(
          (await repoA.getSettings()).copyWith(lastSeenNavPage: '/finance'),
        );
        await a.pushSettings(await repoA.getSettings());

        await b.pullSettings();
        expect(
          (await repoB.getSettings()).jobProfileGitHubUrl,
          'https://github.com/me',
        );
      },
    );
  });

  group('both devices wrote while one of them was offline', () {
    test('a reconnect pull keeps both edits in this device\'s row', () async {
      final a = buildService();
      final id = await seedSyncedEntry(a);

      final dbB = AppDatabase.inMemory();
      addTearDown(dbB.close);
      final repoB = DriftJournalRepository(dbB);
      final b = buildService(database: dbB, deviceId: 'device-b');
      await b.pullJournalEntries();
      await b.prepareEditingSession(
        collection: FirestoreCollections.journalEntries,
        documentId: id,
        initialText: 'Hello',
      );

      // A goes offline and appends; its operations stay pending in memory.
      syncRepo.offline = true;
      await typeAndSave(a, id, before: 'Hello', after: 'Hello world');
      syncRepo.offline = false;

      // Meanwhile B prepends.
      b.recordJournalTextChange(
        entryId: id,
        before: 'Hello',
        after: 'Oh. Hello',
      );
      await b.saveJournalEntryThenScheduleUpload(
        entryId: id,
        saveLocal: () async {
          final current = await repoB.getEntry(id);
          await repoB.upsertEntry(current!.copyWith(body: 'Oh. Hello'));
        },
      );
      await b.flushDocument(FirestoreCollections.journalEntries, id);

      await a.pullJournalEntries();
      final body = (await journalRepo.getEntry(id))!.body;
      expect(body, contains('world'));
      expect(body, contains('Oh.'));
    });

    test(
      'a replay after a restart never deletes the other device\'s text',
      () async {
        final a = buildService();
        final id = await seedSyncedEntry(a);

        final dbB = AppDatabase.inMemory();
        addTearDown(dbB.close);
        final repoB = DriftJournalRepository(dbB);
        final b = buildService(database: dbB, deviceId: 'device-b');
        await b.pullJournalEntries();
        await b.prepareEditingSession(
          collection: FirestoreCollections.journalEntries,
          documentId: id,
          initialText: 'Hello',
        );

        syncRepo.offline = true;
        await typeAndSave(a, id, before: 'Hello', after: 'Hello world');
        a.dispose(); // restart: A's pending operations are gone
        syncRepo.offline = false;

        b.recordJournalTextChange(
          entryId: id,
          before: 'Hello',
          after: 'Oh. Hello',
        );
        await b.saveJournalEntryThenScheduleUpload(
          entryId: id,
          saveLocal: () async {
            final current = await repoB.getEntry(id);
            await repoB.upsertEntry(current!.copyWith(body: 'Oh. Hello'));
          },
        );
        await b.flushDocument(FirestoreCollections.journalEntries, id);

        final a2 = buildService();
        await a2.pushOutboxDocument(FirestoreCollections.journalEntries, id);
        await a2.pullJournalEntries();

        // Neither device's words may be gone from both the row and the log.
        await b.pullJournalEntries();
        final onB = (await repoB.getEntry(id))!.body;
        final onA = (await journalRepo.getEntry(id))!.body;
        expect('$onA|$onB', contains('world'));
        expect(onB, contains('Oh.'));
      },
    );
  });
}
