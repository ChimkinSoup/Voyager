// Regressions for the save/sync defects catalogued in SAVING.md.
//
// Each group names the finding it covers and asserts the behaviour that was
// wrong, not the shape of the fix — so a future refactor is free to move the
// code as long as saves keep landing.

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart' show TextEditingValue, TextSelection;
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/dev/perf_stall_logger.dart';
import 'package:voyager/core/sync/debouncer.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/core/sync/pending_text_merge.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/sync/soft_delete_policy.dart';
import 'package:voyager/core/sync/sync_engine.dart';
import 'package:voyager/core/sync/synced_write_notifier.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/domain/models/dream_models.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/ranking_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/domain/services/character_op_session.dart';

/// Counts the reads a pull actually spends, so "the snapshot already carried
/// this document" is an assertion rather than a hope.
class _CountingSyncRepository extends InMemorySyncRepository {
  int documentReads = 0;
  int operationQueries = 0;

  /// When set, the next matching call throws instead of answering.
  String? failGetDocumentFor;

  /// When set, document writes wait for it — a device that has gone offline.
  Completer<void>? holdWrites;

  /// When set, document writes land but are never acknowledged: the write
  /// gate gives up waiting, while Firestore still delivers them.
  bool timeOutWrites = false;

  @override
  Future<void> upsertDocument(
    String collection,
    String id,
    Map<String, dynamic> data,
  ) async {
    await holdWrites?.future;
    await super.upsertDocument(collection, id, data);
    if (timeOutWrites) throw TimeoutException('unacknowledged');
  }

  @override
  Future<Map<String, dynamic>?> getDocument(String collection, String id) {
    documentReads++;
    if (failGetDocumentFor == id) {
      failGetDocumentFor = null;
      throw StateError('read failed');
    }
    return super.getDocument(collection, id);
  }

  @override
  Future<List<SyncOperation>> listOperations(String documentId) {
    operationQueries++;
    return super.listOperations(documentId);
  }
}

/// One device: its own database, wired to the shared server.
class _Device {
  _Device(this.server, this.deviceId) {
    db = AppDatabase.inMemory();
    syncedWrites = SyncedWriteNotifier();
    journals = DriftJournalRepository(db);
    dreams = DriftDreamRepository(db);
    todos = DriftTodoRepository(db);
    calendars = DriftCalendarRepository(db, syncedWrites: syncedWrites);
    settings = DriftSettingsRepository(db, syncedWrites: syncedWrites);

    sync = RemoteSyncService(
      syncRepository: server,
      journalRepository: journals,
      dreamRepository: dreams,
      todoRepository: todos,
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
      settingsRepository: settings,
      syncEngine: SyncEngine(
        syncRepository: server,
        deviceId: deviceId,
        debouncer: Debouncer(delay: Duration.zero),
      ),
      deviceId: deviceId,
      uploadDebounceDelay: Duration.zero,
    );

    syncedWrites.onWrite = (collection, records) =>
        _uploads.add(sync.pushRecords(collection, records));
  }

  final InMemorySyncRepository server;
  final String deviceId;
  late final AppDatabase db;
  late final SyncedWriteNotifier syncedWrites;
  late final DriftJournalRepository journals;
  late final DriftDreamRepository dreams;
  late final DriftTodoRepository todos;
  late final DriftCalendarRepository calendars;
  late final DriftSettingsRepository settings;
  late final RemoteSyncService sync;

  final _uploads = <Future<void>>[];

  Future<void> settle() async {
    while (_uploads.isNotEmpty) {
      final pending = List.of(_uploads);
      _uploads.clear();
      await Future.wait(pending);
    }
  }

  Future<void> close() => db.close();
}

/// A body or notes editor, reduced to what sync sees of it: every keystroke
/// recorded against the character session, and remote changes merged in
/// through the pending-merge listener.
class _Editor {
  _Editor(this.device, this.record, String text)
    : value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );

  final _Device device;
  final void Function(String before, String after) record;
  TextEditingValue value;

  /// Off for an editor that cannot take a remote change as it arrives —
  /// one whose text no longer lines up with it — leaving it for the flush.
  bool takesMerges = true;

  String get text => value.text;

  void type(String insert, {int? at}) {
    final offset = at ?? value.selection.baseOffset;
    final before = text;
    final after = before.replaceRange(offset, offset, insert);
    value = TextEditingValue(
      text: after,
      selection: TextSelection.collapsed(offset: offset + insert.length),
    );
    record(before, after);
  }

  bool onMerge(PendingTextMergeEvent event) {
    if (!takesMerges) return false;
    final merged = event.mergedInto(value);
    if (merged == null) return false;
    value = merged;
    return true;
  }
}

void main() {
  final now = DateTime.utc(2026, 8, 14, 12);

  JournalEntry entry({String id = 'entry-1', String body = 'hello'}) =>
      JournalEntry(
        id: id,
        journalId: 'journal-1',
        title: 'Title',
        body: body,
        entryDate: now,
        createdAt: now,
        updatedAt: now,
      );

  DreamEntry dream(String body) => DreamEntry(
    id: 'doc-1',
    title: 'Title',
    body: body,
    entryDate: now,
    createdAt: now,
    updatedAt: now,
  );

  TodoTask task(String notes) => TodoTask(
    id: 'doc-1',
    listId: 'list-1',
    title: 'Title',
    notes: notes,
    createdAt: now,
    updatedAt: now,
  );

  group('self-echo suppression (findings #10, #11)', () {
    late _CountingSyncRepository server;
    late _Device device;

    setUp(() {
      server = _CountingSyncRepository();
      device = _Device(server, 'device-a');
    });

    tearDown(() => device.close());

    /// Writes a calendar and waits for the upload that mark accompanies.
    Future<Map<String, dynamic>> pushCalendar(
      String name, {
      String id = 'cal-1',
    }) async {
      await device.calendars.upsertCalendar(
        Calendar(id: id, name: name, createdAt: now, updatedAt: now),
      );
      await device.settle();
      return (await server.getDocument(FirestoreCollections.calendars, id))!;
    }

    test('our own write coming back is not applied again', () async {
      final stored = await pushCalendar('Work');
      final readsBefore = server.documentReads;

      // What the snapshot listener delivers: the document we just wrote.
      final applied = await device.sync.pullForCollection(
        FirestoreCollections.calendars,
        documentIds: {'cal-1'},
        documentData: {'cal-1': stored},
      );

      expect(
        applied,
        isFalse,
        reason: 'the echo of our own write should not count as a change',
      );
      expect(
        server.documentReads,
        readsBefore,
        reason: 'a suppressed echo must not spend a read either',
      );
    });

    test(
      'another device changing the same document inside the window still lands',
      () async {
        final stored = await pushCalendar('Work');

        // Device B renames it immediately afterwards — inside the old
        // fifteen-second blanket window, which swallowed this entirely and
        // left the two devices diverged with nothing to redeliver it.
        final applied = await device.sync.pullForCollection(
          FirestoreCollections.calendars,
          documentIds: {'cal-1'},
          documentData: {
            'cal-1': {...stored, 'name': 'Home', 'version': 99},
          },
        );

        expect(applied, isTrue);
        expect((await device.calendars.getCalendar('cal-1'))?.name, 'Home');
      },
    );

    test('a journal save suppresses its own echo too', () async {
      // The path finding #11 called the largest source of avoidable reads:
      // every journal, dream, todo, study, workout and LeetCode save marked
      // itself only *after* awaiting the write, by which time the snapshot
      // listener had already been and gone.
      await device.journals.upsertEntry(entry());
      device.sync.pushJournalEntryNow(entry());
      await pumpEventQueue();

      final stored = (await server.getDocument(
        FirestoreCollections.journalEntries,
        'entry-1',
      ))!;
      final opsBefore = server.operationQueries;

      final applied = await device.sync.pullForCollection(
        FirestoreCollections.journalEntries,
        documentIds: {'entry-1'},
        documentData: {'entry-1': stored},
      );

      expect(applied, isFalse);
      expect(
        server.operationQueries,
        opsBefore,
        reason: 'a suppressed echo must not spend the CRDT query either',
      );
    });

    test('the server confirming our write is still our echo', () async {
      final stored = await pushCalendar('Work');

      // Firestore delivers one write twice: from the local cache, then again
      // once the server has filled in its write time — same content both times.
      for (final delivery in ['local cache', 'server confirmation']) {
        final applied = await device.sync.pullForCollection(
          FirestoreCollections.calendars,
          documentIds: {'cal-1'},
          documentData: {'cal-1': stored},
        );
        expect(applied, isFalse, reason: 'the $delivery delivery');
      }
    });

    test('an echo is ours whatever order its nested keys come back in', () async {
      // Firestore returns every map sorted by key. A ranking entry nests two —
      // its field values, and field stamps kept in the order they were set —
      // so its echo never matched, and every score save reloaded the app twice.
      final parent = RankingParent(
        id: 'parent-1',
        categoryId: 'category-1',
        title: 'Show',
        overallScore: 8,
        fieldValues: const {'field-1': RankingFieldValue(score: 3, notes: 'x')},
        fieldUpdatedAt: {
          'title': now,
          'overallScore': now,
          'fv:field-1:score': now,
        },
        createdAt: now,
        updatedAt: now,
      );
      await DriftRankingRepository(device.db).upsertParent(parent);
      device.sync.pushRankingParent(parent);
      await pumpEventQueue();
      final stored = (await server.getDocument(
        FirestoreCollections.rankingParents,
        'parent-1',
      ))!;

      Object? sortedKeys(Object? value) => switch (value) {
        Map() => {
          for (final key in value.keys.cast<String>().toList()..sort())
            key: sortedKeys(value[key]),
        },
        List() => [for (final item in value) sortedKeys(item)],
        _ => value,
      };

      final applied = await device.sync.pullForCollection(
        FirestoreCollections.rankingParents,
        documentIds: {'parent-1'},
        documentData: {'parent-1': sortedKeys(stored)! as Map<String, dynamic>},
      );
      expect(applied, isFalse);
    });

    test(
      'an earlier write confirmed after the next one is marked is still ours',
      () async {
        // Back-to-back uploads on a slow network: the server's confirmation of
        // the first write arrives once the second has already been marked.
        // Compared against only the newest mark, it read as a foreign edit,
        // dropped the mark, and the second write's own echo then reloaded
        // every provider too.
        final first = await pushCalendar('Work');
        final second = await pushCalendar('Home');

        for (final (label, stored) in [
          ('the earlier write', first),
          ('the later write', second),
        ]) {
          final applied = await device.sync.pullForCollection(
            FirestoreCollections.calendars,
            documentIds: {'cal-1'},
            documentData: {'cal-1': stored},
          );
          expect(applied, isFalse, reason: '$label is our own echo');
        }
        expect((await device.calendars.getCalendar('cal-1'))?.name, 'Home');
      },
    );

    test(
      'content of an older write arriving after a newer echo is not ours',
      () async {
        // Another device writing back what our first push said — re-uploading
        // what it pulled, or toggling back — once our second push has been
        // confirmed. Matched against the stale first mark, it was skipped and
        // the devices diverged.
        final first = await pushCalendar('Work');
        final second = await pushCalendar('Home');

        await device.sync.pullForCollection(
          FirestoreCollections.calendars,
          documentIds: {'cal-1'},
          documentData: {'cal-1': second},
        );
        final applied = await device.sync.pullForCollection(
          FirestoreCollections.calendars,
          documentIds: {'cal-1'},
          documentData: {'cal-1': first},
        );

        expect(applied, isTrue);
      },
    );

    test(
      'a delivery matching two pushes clears the marks between them',
      () async {
        // Done, undone, done again while a pull was running: the listener
        // keeps only the newest copy, so only the last push is delivered. Taken
        // as the first push, the undone mark between them survived and
        // swallowed another device undoing it for real.
        final first = await pushCalendar('Work');
        final undone = await pushCalendar('Home');
        final last = await pushCalendar('Work');
        expect(last, first, reason: 'the two pushes carry the same content');

        final echoed = await device.sync.pullForCollection(
          FirestoreCollections.calendars,
          documentIds: {'cal-1'},
          documentData: {'cal-1': last},
        );
        expect(echoed, isFalse);

        final applied = await device.sync.pullForCollection(
          FirestoreCollections.calendars,
          documentIds: {'cal-1'},
          documentData: {'cal-1': undone},
        );
        expect(applied, isTrue);
      },
    );

    test(
      'a foreign edit clears our marks, so reverting to our content lands',
      () async {
        // Another device edits, then undoes back to what we pushed. The leftover
        // mark matched the undo and skipped it, leaving us on the edit.
        final stored = await pushCalendar('Work');

        final edited = await device.sync.pullForCollection(
          FirestoreCollections.calendars,
          documentIds: {'cal-1'},
          documentData: {
            'cal-1': {...stored, 'name': 'Home', 'version': 99},
          },
        );
        expect(edited, isTrue);

        final reverted = await device.sync.pullForCollection(
          FirestoreCollections.calendars,
          documentIds: {'cal-1'},
          documentData: {'cal-1': stored},
        );
        expect(reverted, isTrue);
      },
    );

    test('a mark kept after its echo does not eat the next change', () async {
      final stored = await pushCalendar('Work');

      await device.sync.pullForCollection(
        FirestoreCollections.calendars,
        documentIds: {'cal-1'},
        documentData: {'cal-1': stored},
      );

      // The mark outlives its echo, for the server's redelivery of the same
      // content, but a different document after it is still not ours.
      final applied = await device.sync.pullForCollection(
        FirestoreCollections.calendars,
        documentIds: {'cal-1'},
        documentData: {
          'cal-1': {...stored, 'name': 'Home', 'version': 99},
        },
      );

      expect(applied, isTrue);
      expect((await device.calendars.getCalendar('cal-1'))?.name, 'Home');
    });

    test(
      'an expired mark is not an echo, even before a sweep drops it',
      () async {
        var at = Duration.zero;
        device.sync.echoClock = () => at;
        final stored = await pushCalendar('Work');

        // No write since, so no sweep has run: the pull ages the mark itself.
        at = const Duration(seconds: 16);
        final applied = await device.sync.pullForCollection(
          FirestoreCollections.calendars,
          documentIds: {'cal-1'},
          documentData: {'cal-1': stored},
        );

        expect(applied, isTrue);
      },
    );

    test(
      'a write held offline past the window is still ours once confirmed',
      () async {
        // Wi-Fi off while typing: Firestore holds the write until the network
        // is back and confirms it then. Aged from the mark, the confirmation
        // read as another device's edit, and an entry open in the editor had
        // that "edit" injected into text that already held it — doubled.
        var at = Duration.zero;
        device.sync.echoClock = () => at;
        server.holdWrites = Completer<void>();
        final pushed = pushCalendar('Work');
        await pumpEventQueue();
        expect(device.sync.selfEchoMarkCount, 1, reason: 'marked, write held');

        at = const Duration(minutes: 5);
        server.holdWrites!.complete();
        final stored = await pushed;

        at += const Duration(seconds: 14);
        final applied = await device.sync.pullForCollection(
          FirestoreCollections.calendars,
          documentIds: {'cal-1'},
          documentData: {'cal-1': stored},
        );
        expect(applied, isFalse);
      },
    );

    test('a write that timed out is still ours once confirmed', () async {
      // Offline past the write gate's timeout: it stops waiting, but Firestore
      // keeps the write and confirms it when the network is back.
      var at = Duration.zero;
      device.sync.echoClock = () => at;
      server.timeOutWrites = true;
      try {
        await pushCalendar('Work');
      } on TimeoutException {
        // What the gate throws; the write is still queued.
      }
      server.timeOutWrites = false;
      final stored = (await server.getDocument(
        FirestoreCollections.calendars,
        'cal-1',
      ))!;

      at = const Duration(minutes: 5);
      final applied = await device.sync.pullForCollection(
        FirestoreCollections.calendars,
        documentIds: {'cal-1'},
        documentData: {'cal-1': stored},
      );
      expect(applied, isFalse);
    });

    test('expired marks are swept at most once a window', () async {
      // Marks for documents that are never pulled back — a signed-out session —
      // are only ever dropped by the sweep a write runs.
      var at = Duration.zero;
      device.sync.echoClock = () => at;
      Future<void> pushAt(int seconds, String id) {
        at = Duration(seconds: seconds);
        return pushCalendar('Work', id: id);
      }

      await pushAt(0, 'cal-a');
      await pushAt(1, 'cal-b');
      await pushAt(15, 'cal-c');
      expect(device.sync.selfEchoMarkCount, 2, reason: 'cal-a swept at 15s');

      await pushAt(20, 'cal-d');
      expect(
        device.sync.selfEchoMarkCount,
        3,
        reason: 'cal-b expired at 16s, but the last sweep was only 5s ago',
      );

      await pushAt(30, 'cal-e');
      expect(
        device.sync.selfEchoMarkCount,
        2,
        reason: 'cal-b and cal-c swept at 30s',
      );
    });

    group('with the perf stall log on', () {
      final logger = PerfStallLogger.instance;
      final defaultDirectory = PerfStallLogger.directory;

      setUpAll(TestWidgetsFlutterBinding.ensureInitialized);

      setUp(() {
        final dir = Directory.systemTemp.createTempSync('echo_breadcrumbs');
        PerfStallLogger.directory = () async => dir.path;
        addTearDown(() async {
          await logger.setEnabled(false);
          // Let the queued "stopped" line land before the directory goes.
          await logger.readLog();
          PerfStallLogger.directory = defaultDirectory;
          dir.deleteSync(recursive: true);
        });
      });

      Future<String> mismatchBreadcrumb(Map<String, dynamic> stored) async {
        await device.sync.pullForCollection(
          FirestoreCollections.calendars,
          documentIds: {'cal-1'},
          documentData: {
            'cal-1': {...stored, 'name': 'Home', 'version': 99},
          },
        );
        return logger.breadcrumbMessages.singleWhere(
          (message) => message.startsWith('echo MISMATCH'),
        );
      }

      test('a change after our marks expired says so', () async {
        await logger.setEnabled(true);
        var at = Duration.zero;
        device.sync.echoClock = () => at;
        final stored = await pushCalendar('Work');

        at = const Duration(seconds: 16);
        await device.sync.pullForCollection(
          FirestoreCollections.calendars,
          documentIds: {'cal-1'},
          documentData: {'cal-1': stored},
        );

        expect(
          logger.breadcrumbMessages,
          contains(startsWith('remote change after our echo marks expired')),
        );
      });

      test('a mismatch names the fields that differ', () async {
        await logger.setEnabled(true);
        final stored = await pushCalendar('Work');

        expect(
          await mismatchBreadcrumb(stored),
          contains('name: pushed "Work" (String), got "Home" (String)'),
        );
      });

      test(
        'a mark made before logging was on still logs its mismatch',
        () async {
          final stored = await pushCalendar('Work');
          await logger.setEnabled(true);

          expect(
            await mismatchBreadcrumb(stored),
            contains('marked before logging was on'),
          );
        },
      );
    });
  });

  group('live sync reuses the snapshot payload (finding #12)', () {
    test('a pull given the document spends no extra read', () async {
      final server = _CountingSyncRepository();
      final device = _Device(server, 'device-a');
      addTearDown(device.close);

      await device.calendars.upsertCalendar(
        Calendar(id: 'cal-1', name: 'Work', createdAt: now, updatedAt: now),
      );
      await device.settle();

      final stored = await server.getDocument(
        FirestoreCollections.calendars,
        'cal-1',
      );
      final readsBefore = server.documentReads;

      // A different device's edit, delivered with its payload.
      await device.sync.pullForCollection(
        FirestoreCollections.calendars,
        documentIds: {'cal-1'},
        documentData: {
          'cal-1': {...stored!, 'name': 'Home', 'version': 9},
        },
      );

      expect(server.documentReads, readsBefore);
      final local = await device.calendars.getCalendar('cal-1');
      expect(local?.name, 'Home');
    });
  });

  group('operation log is only kept where it is read (finding #13)', () {
    test('a journal entry still writes one', () async {
      final server = _CountingSyncRepository();
      final device = _Device(server, 'device-a');
      addTearDown(device.close);

      await device.journals.upsertEntry(entry());
      device.sync.pushJournalEntryNow(entry());
      await pumpEventQueue();

      expect(await server.listOperations('entry-1'), isNotEmpty);
    });

    test('a plain record writes none', () async {
      final server = _CountingSyncRepository();
      final device = _Device(server, 'device-a');
      addTearDown(device.close);

      await device.journals.upsertJournal(
        Journal(id: 'journal-1', name: 'Diary', createdAt: now, updatedAt: now),
      );
      device.sync.pushJournal(
        Journal(id: 'journal-1', name: 'Diary', createdAt: now, updatedAt: now),
      );
      await pumpEventQueue();

      expect(
        await server.listOperations('journal-1'),
        isEmpty,
        reason: 'journals carry no collaborative text',
      );
    });

    test('every collection is classified one way or the other', () {
      expect(
        FirestoreCollections.snapshotOnly.intersection(
          FirestoreCollections.crdtBacked,
        ),
        isEmpty,
      );
      expect({
        ...FirestoreCollections.snapshotOnly,
        ...FirestoreCollections.crdtBacked,
      }, FirestoreCollections.records);
    });
  });

  group(
    'pending character operations survive a failed upload (finding #3)',
    () {
      test('they are still pending after the write throws', () {
        final session = CharacterOpSession(clientId: 'device-a');
        session.recordTextChange('', 'hi');

        final taken = session.takePendingOps();
        expect(taken, isNotEmpty);
        expect(session.takePendingOps(), isEmpty);

        session.restorePendingOps(taken);
        expect(
          session.takePendingOps().map((op) => op.id),
          taken.map((op) => op.id),
        );
      });

      test('operations recorded during the failed upload still follow', () {
        final session = CharacterOpSession(clientId: 'device-a');
        session.recordTextChange('', 'ab');
        final inFlight = session.takePendingOps();

        // The user kept typing while the upload was in the air.
        session.recordTextChange('ab', 'abc');

        session.restorePendingOps(inFlight);
        final pending = session.takePendingOps();

        expect(pending.length, 3);
        expect(
          pending.take(2).map((op) => op.id),
          inFlight.map((op) => op.id),
          reason: 'the restored operations must come first',
        );
      });
    },
  );

  group('startup purge runs after the pull (finding #8)', () {
    test(
      'an expired tombstone pulled in is removed in the same pass',
      () async {
        final server = InMemorySyncRepository();
        final device = _Device(server, 'device-a');
        addTearDown(device.close);

        final policy = const SoftDeletePolicy();
        final longGone = policy
            .purgeCutoff(DateTime.now().toUtc())
            .subtract(const Duration(days: 5));

        // Another device deleted this months ago; the tombstone is still on the
        // server and the pull will faithfully bring it back.
        await server.upsertDocument(
          FirestoreCollections.journalEntries,
          'entry-old',
          journalEntryToFirestore(
            entry(id: 'entry-old').copyWith(deletedAt: longGone),
          ),
        );

        var purgeRan = false;
        await SyncEngine(
          syncRepository: server,
          deviceId: 'device-a',
          debouncer: Debouncer(delay: Duration.zero),
        ).pullOnStartup(
          pullFromRemote: () => device.sync.pullJournalEntries(),
          purgeExpiredDeleted: () async {
            purgeRan = true;
            await device.journals.purgeExpiredDeleted(DateTime.now().toUtc());
          },
          localRefresh: () async {},
        );

        expect(purgeRan, isTrue);
        expect(
          await device.journals.getEntry('entry-old'),
          isNull,
          reason:
              'purging before the pull left the row to be re-inserted and sit '
              'there until the next launch',
        );
      },
    );
  });

  group('a restore outranks the old operation log (finding #7)', () {
    test('pushing restored records clears the document log', () async {
      final server = InMemorySyncRepository();
      final device = _Device(server, 'device-a');
      addTearDown(device.close);

      // The text as it was before the accident, with a log describing it.
      await device.journals.upsertEntry(entry(body: 'the original body'));
      device.sync.recordJournalTextChange(
        entryId: 'entry-1',
        before: '',
        after: 'the original body',
      );
      device.sync.pushJournalEntryNow(entry(body: 'the original body'));
      await pumpEventQueue();
      expect(await server.listOperations('entry-1'), isNotEmpty);

      // The restore writes the recovered row and uploads it.
      final restored = entry(body: 'recovered from backup');
      await device.journals.upsertEntry(restored, recordLocalActivity: false);
      await device.sync.pushRestoredRecords(
        FirestoreCollections.journalEntries,
        [restored],
      );

      expect(
        await server.listOperations('entry-1'),
        isEmpty,
        reason: 'the log still described the body the restore replaced',
      );

      // The pull that used to undo the recovery.
      await device.sync.pullJournalEntries();
      expect(
        (await device.journals.getEntry('entry-1'))?.body,
        'recovered from backup',
      );
    });
  });

  group('permanent delete clears the right operations (finding #16)', () {
    test('a legacy-id journal deletes its own log', () async {
      final server = InMemorySyncRepository();
      final device = _Device(server, 'device-a');
      addTearDown(device.close);

      // Operations are filed under the Firestore id, which for this collection
      // is not the local id.
      const localId = 'journal-1';
      final firestoreId = firestoreDocumentIdForLocal(
        FirestoreCollections.journals,
        localId,
      );
      await server.appendOperation(
        SyncOperation(
          id: 'op-1',
          documentId: firestoreId,
          sequence: 1,
          payload: '{}',
          deviceId: 'device-a',
          timestamp: now,
        ),
      );

      final deleted = await device.sync.permanentlyDeleteFromRemote(
        collection: FirestoreCollections.journals,
        documentId: localId,
      );

      expect(deleted, 1);
      expect(await server.listOperations(firestoreId), isEmpty);
    });
  });

  group('an open editor merges remote text through its session', () {
    late _CountingSyncRepository server;
    late _Device a;
    late _Device b;

    setUp(() {
      server = _CountingSyncRepository();
      a = _Device(server, 'device-a');
      b = _Device(server, 'device-b');
    });

    tearDown(() async {
      await a.close();
      await b.close();
    });

    /// Every kind of text two devices edit together, as its editor and its
    /// saves reach sync. The document is always `doc-1`.
    final kinds = [
      _TextKind(
        name: 'journal body',
        collection: FirestoreCollections.journalEntries,
        saveLocally: (device, text) =>
            device.journals.upsertEntry(entry(id: 'doc-1', body: text)),
        upload: (device, text) async =>
            device.sync.pushJournalEntryNow(entry(id: 'doc-1', body: text)),
        record: (device, before, after) => device.sync.recordJournalTextChange(
          entryId: 'doc-1',
          before: before,
          after: after,
        ),
      ),
      _TextKind(
        name: 'dream body',
        collection: FirestoreCollections.dreamEntries,
        saveLocally: (device, text) => device.dreams.upsertEntry(dream(text)),
        upload: (device, text) async =>
            device.sync.pushDreamEntryNow(dream(text)),
        record: (device, before, after) => device.sync.recordDreamTextChange(
          entryId: 'doc-1',
          before: before,
          after: after,
        ),
      ),
      _TextKind(
        name: 'todo notes',
        collection: FirestoreCollections.todoTasks,
        saveLocally: (device, text) => device.todos.upsertTask(task(text)),
        upload: (device, text) => device.sync.pushTodoTaskNow(task(text)),
        record: (device, before, after) => device.sync.recordTodoNotesChange(
          taskId: 'doc-1',
          before: before,
          after: after,
        ),
      ),
    ];
    final journal = kinds.first;

    /// Opens doc-1 on [device] the way its page does.
    Future<_Editor> openEditor(
      _Device device,
      _TextKind kind,
      String text,
    ) async {
      await kind.saveLocally(device, text);
      await device.sync.prepareEditingSession(
        collection: kind.collection,
        documentId: 'doc-1',
        initialText: text,
      );
      device.sync.setDocumentEditing(
        collection: kind.collection,
        documentId: 'doc-1',
        isEditing: true,
      );
      final editor = _Editor(
        device,
        (before, after) => kind.record(device, before, after),
        text,
      );
      device.sync.addPendingTextMergeListener(
        collection: kind.collection,
        documentId: 'doc-1',
        listener: editor.onMerge,
      );
      return editor;
    }

    /// Saves and uploads what [editor] shows, as an autosave would.
    Future<void> save(_Editor editor, _TextKind kind) async {
      await kind.saveLocally(editor.device, editor.text);
      await kind.upload(editor.device, editor.text);
      await pumpEventQueue();
    }

    /// What the snapshot listener hands [device] for doc-1.
    Future<bool> deliver(_Device device, String collection) async =>
        device.sync.pullForCollection(
          collection,
          documentIds: {'doc-1'},
          documentData: {
            'doc-1': (await server.getDocument(collection, 'doc-1'))!,
          },
        );

    for (final kind in kinds) {
      test(
        '${kind.name}: our own write coming back unrecognised does not double '
        'the text',
        () async {
          // Wi-Fi off, or a restart in between: the confirmation of our own
          // upload arrives with no echo mark to recognise it by.
          var at = Duration.zero;
          a.sync.echoClock = () => at;
          final editor = await openEditor(a, kind, 'hello');
          await save(editor, kind);
          at = const Duration(hours: 1);
          // Leaves "hello" as the last remote text seen.
          await deliver(a, kind.collection);

          editor.type(' world');
          await save(editor, kind);
          editor.type('!!'); // Typed after that upload, not sent yet.

          at = const Duration(hours: 2);
          await deliver(a, kind.collection);

          expect(editor.text, 'hello world!!');
        },
      );
    }

    test("another device's text lands once, and the caret stays put", () async {
      final editor = await openEditor(a, journal, 'hello world');
      await save(editor, journal);
      editor.value = const TextEditingValue(
        text: 'hello world',
        selection: TextSelection.collapsed(offset: 5),
      );

      final other = await openEditor(b, journal, 'hello world');
      other.type('Hi, ', at: 0);
      other.type(', friend', at: other.text.length);
      await save(other, journal);

      await deliver(a, journal.collection);

      expect(editor.text, 'Hi, hello world, friend');
      expect(
        editor.value.selection,
        const TextSelection.collapsed(offset: 9),
        reason: 'still after "hello": moved by the insert before it only',
      );
      expect(
        await a.sync.applyPendingJournalEntryTextMerge(
          entryId: 'doc-1',
          currentLocalText: editor.text,
        ),
        isNull,
        reason: 'applied live, so the final flush must not apply it again',
      );
    });

    test('changes left for the flush all land, not just the last', () async {
      final editor = await openEditor(a, journal, 'hello world');
      await save(editor, journal);
      editor.takesMerges = false;

      final other = await openEditor(b, journal, 'hello world');
      other.type('Hi, ', at: 0);
      await save(other, journal);
      await deliver(a, journal.collection);
      other.type(', friend', at: other.text.length);
      await save(other, journal);
      await deliver(a, journal.collection);

      expect(
        (await a.sync.applyPendingJournalEntryTextMerge(
          entryId: 'doc-1',
          currentLocalText: editor.text,
        ))?.body,
        'Hi, hello world, friend',
      );
    });

    test(
      'a caret after our character stays there when theirs shares its spot',
      () async {
        // Both devices type after "hello" at once: the two characters get the
        // same fractional position, told apart only by id.
        final editor = await openEditor(a, journal, 'hello world');
        await save(editor, journal);
        final other = await openEditor(b, journal, 'hello world');

        editor.type('!', at: 5);
        other.type('?', at: 5);
        await save(other, journal);

        await deliver(a, journal.collection);

        expect(editor.text, anyOf('hello!? world', 'hello?! world'));
        final caret = editor.value.selection.baseOffset;
        expect(editor.text[caret - 1], '!');
      },
    );

    test('a change the editor already shows is not merged again', () async {
      // No session, and our own typing back with a stale baseline: the
      // editor already shows it, so nothing is left for the final flush.
      await journal.saveLocally(a, 'hello');
      a.sync.setDocumentEditing(
        collection: journal.collection,
        documentId: 'doc-1',
        isEditing: true,
      );
      final editor = _Editor(a, (_, _) {}, 'hello');
      a.sync.addPendingTextMergeListener(
        collection: journal.collection,
        documentId: 'doc-1',
        listener: editor.onMerge,
      );
      await server.upsertDocument(
        journal.collection,
        'doc-1',
        journalEntryToFirestore(entry(id: 'doc-1', body: 'hello')),
      );
      await deliver(a, journal.collection);

      editor.type(' world');
      await server.upsertDocument(
        journal.collection,
        'doc-1',
        journalEntryToFirestore(
          entry(id: 'doc-1', body: 'hello world').copyWith(version: 5),
        ),
      );
      await deliver(a, journal.collection);
      editor.type('!');

      final flushed = await a.sync.applyPendingJournalEntryTextMerge(
        entryId: 'doc-1',
        currentLocalText: editor.text,
      );
      expect(flushed?.body ?? editor.text, 'hello world!');
    });

    test('an open editor nobody is typing in still shows the change', () async {
      // Focus in the title: the body is open but not being edited, so the
      // pull stores the change itself. The body kept the old text, and the
      // next keystroke there dropped the change on this device only.
      final editor = await openEditor(a, journal, 'hello world');
      await save(editor, journal);
      a.sync.setDocumentEditing(
        collection: journal.collection,
        documentId: 'doc-1',
        isEditing: false,
      );

      final other = await openEditor(b, journal, 'hello world');
      other.type('Hi, ', at: 0);
      await save(other, journal);
      await deliver(a, journal.collection);

      expect(editor.text, 'Hi, hello world');
      expect(editor.value.selection, const TextSelection.collapsed(offset: 15));

      editor.type('!');
      await save(editor, journal);
      await deliver(b, journal.collection);
      expect((await a.journals.getEntry('doc-1'))?.body, 'Hi, hello world!');
      expect(other.text, 'Hi, hello world!');
    });

    test('a document with no operation log merges its snapshot', () async {
      // The session is open, but nothing has been uploaded with operations:
      // the text is the snapshot's alone, which the session never sees.
      final editor = await openEditor(a, journal, 'hello');
      await server.upsertDocument(
        journal.collection,
        'doc-1',
        journalEntryToFirestore(entry(id: 'doc-1', body: 'hello')),
      );
      await deliver(a, journal.collection);
      await server.upsertDocument(
        journal.collection,
        'doc-1',
        journalEntryToFirestore(
          entry(id: 'doc-1', body: 'hello there').copyWith(version: 5),
        ),
      );

      await deliver(a, journal.collection);

      expect(editor.text, 'hello there');
    });

    test('with no session yet, the text diff still merges', () async {
      // Opened, but the operation log has not loaded: there is no session to
      // fold into, so the last remote text seen stays the baseline.
      await journal.saveLocally(a, 'hello');
      a.sync.setDocumentEditing(
        collection: journal.collection,
        documentId: 'doc-1',
        isEditing: true,
      );
      final editor = _Editor(a, (_, _) {}, 'hello');
      a.sync.addPendingTextMergeListener(
        collection: journal.collection,
        documentId: 'doc-1',
        listener: editor.onMerge,
      );
      await server.upsertDocument(
        journal.collection,
        'doc-1',
        journalEntryToFirestore(entry(id: 'doc-1', body: 'hello')),
      );
      await deliver(a, journal.collection);
      await server.upsertDocument(
        journal.collection,
        'doc-1',
        journalEntryToFirestore(
          entry(id: 'doc-1', body: 'hello there').copyWith(version: 5),
        ),
      );

      await deliver(a, journal.collection);

      expect(editor.text, 'hello there');
    });
  });
}

/// One kind of collaboratively edited text — see the open-editor group.
class _TextKind {
  const _TextKind({
    required this.name,
    required this.collection,
    required this.saveLocally,
    required this.upload,
    required this.record,
  });

  final String name;
  final String collection;
  final Future<void> Function(_Device device, String text) saveLocally;
  final Future<void> Function(_Device device, String text) upload;
  final void Function(_Device device, String before, String after) record;
}
