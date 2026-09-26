import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/constants/journal_constants.dart';
import 'package:voyager/core/soft_delete/erasure.dart';
import 'package:voyager/core/soft_delete/restore_contract.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/study_models.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/features/settings/services/backup_collections.dart';
import 'package:voyager/features/trash/trash_dialog.dart';
import 'package:voyager/features/trash/trash_kinds.dart';
import 'package:voyager/features/trash/trash_service.dart';

class _RecordingUploader {
  final Map<String, List<Object>> records = {};

  Future<void> push(String collection, List<Object> pushed) async {
    (records[collection] ??= []).addAll(pushed);
  }
}

class _MediaCall {
  const _MediaCall(this.owner, this.id, this.since);

  final String owner;
  final String id;
  final DateTime since;
}

List<BackupCollection> _collectionsFor(AppDatabase db) =>
    buildBackupCollections(
      journalRepository: DriftJournalRepository(db),
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
    );

void main() {
  late AppDatabase db;
  late DriftJournalRepository journals;
  late DriftTodoRepository todos;
  late DriftStudyRepository study;
  late DriftCalendarRepository calendars;
  late _RecordingUploader uploader;
  late List<_MediaCall> mediaCalls;
  late TrashService trash;

  final created = DateTime.utc(2026, 9, 1);

  setUp(() {
    db = AppDatabase.inMemory();
    journals = DriftJournalRepository(db);
    todos = DriftTodoRepository(db);
    study = DriftStudyRepository(db);
    calendars = DriftCalendarRepository(db);
    uploader = _RecordingUploader();
    mediaCalls = [];
    trash = TrashService(
      db: db,
      collections: _collectionsFor(db),
      push: uploader.push,
      restoreMedia: (owner, id, since) async =>
          mediaCalls.add(_MediaCall(owner, id, since)),
    );
  });

  tearDown(() async => db.close());

  Future<void> addJournal(String id, String name) => journals.upsertJournal(
    Journal(id: id, name: name, createdAt: created, updatedAt: created),
  );

  Future<void> addEntry(String id, String journalId, String title) =>
      journals.upsertEntry(
        JournalEntry(
          id: id,
          journalId: journalId,
          title: title,
          body: 'Body of $title',
          entryDate: created,
          createdAt: created,
          updatedAt: created,
        ),
      );

  /// What `deleteJournalList` does with "delete everything": one instant for
  /// the journal and its entries.
  ///
  /// Waits a moment first. The clock here can tick in whole milliseconds, and
  /// a delete made in the same tick as an earlier one carries its stamp — which
  /// is what marks rows as deleted together. A person can't delete twice
  /// within a millisecond; a test can.
  Future<DateTime> deleteJournalWithEntries(String id) async {
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final at = utcNow();
    await journals.softDeleteEntriesInJournal(id, at: at);
    await journals.softDeleteJournal(id, at: at);
    return at;
  }

  group('grouping', () {
    test('a journal delete stamps the journal and its entries alike, and '
        'leaves an entry already in the trash alone', () async {
      await addJournal('j', 'Work');
      await addEntry('e1', 'j', 'Standup');
      await addEntry('e2', 'j', 'Retro');
      await journals.softDeleteEntry('e2');
      final earlier = (await journals.getEntry('e2'))!.deletedAt!;
      final earlierVersion = (await journals.getEntry('e2'))!.version;

      final at = await deleteJournalWithEntries('j');

      expect((await journals.getJournal('j'))!.deletedAt, at);
      expect((await journals.getEntry('e1'))!.deletedAt, at);
      // Re-stamping it moved its 30-day clock and swept it into the group.
      final e2 = (await journals.getEntry('e2'))!;
      expect(e2.deletedAt, earlier);
      expect(e2.version, earlierVersion);
    });

    test('the journal is one row that counts its own entries; an entry '
        'deleted earlier is its own row', () async {
      await addJournal('j', 'Work');
      await addEntry('e1', 'j', 'Standup');
      await addEntry('e2', 'j', 'Retro');
      await journals.softDeleteEntry('e2');
      await deleteJournalWithEntries('j');

      final items = await trash.list();

      expect(items.map(trashItemLabel), ['Journal "Work"', '"Retro"']);
      expect(items.first.summary, '1 entry');
    });

    test('a to-do list counts its tasks and subtasks; a task counts its '
        'subtasks', () async {
      await todos.upsertList(
        TodoListModel(
          id: 'l',
          name: 'Groceries',
          createdAt: created,
          updatedAt: created,
        ),
      );
      for (final (id, parent) in [('t1', null), ('t2', null), ('s1', 't1')]) {
        await todos.upsertTask(
          TodoTask(
            id: id,
            listId: 'l',
            title: id,
            parentTaskId: parent,
            createdAt: created,
            updatedAt: created,
          ),
        );
      }
      final at = utcNow();
      await todos.softDeleteTasksInList('l', at: at);
      await todos.softDeleteList('l', at: at);

      final items = await trash.list();

      expect(items, hasLength(1));
      expect(trashItemLabel(items.single), 'To-do list "Groceries"');
      expect(items.single.summary, '3 tasks');
    });

    test('a study folder takes its subfolders, decks and cards', () async {
      await study.upsertFolder(
        StudyFolder(
          id: 'f',
          name: 'Bio',
          createdAt: created,
          updatedAt: created,
        ),
      );
      await study.upsertFolder(
        StudyFolder(
          id: 'f2',
          name: 'Cells',
          parentFolderId: 'f',
          createdAt: created,
          updatedAt: created,
        ),
      );
      await study.upsertDeck(
        StudyDeck(
          id: 'd',
          name: 'Mitosis',
          parentFolderId: 'f2',
          createdAt: created,
          updatedAt: created,
        ),
      );
      for (final id in ['c1', 'c2']) {
        await study.upsertCard(
          StudyCard(
            id: id,
            deckId: 'd',
            frontText: 'Q $id',
            backText: 'A',
            dueAt: created,
            createdAt: created,
            updatedAt: created,
          ),
        );
      }
      final at = utcNow();
      for (final id in ['c1', 'c2']) {
        await study.softDeleteCard(id, at: at);
      }
      await study.softDeleteDeck('d', at: at);
      await study.softDeleteFolder('f2', at: at);
      await study.softDeleteFolder('f', at: at);

      final items = await trash.list();

      expect(items, hasLength(1));
      expect(items.single.summary, '1 folder · 1 deck · 2 cards');
    });

    test('a group\'s stamps survive the trip through Firestore', () async {
      await addJournal('j', 'Work');
      await addEntry('e1', 'j', 'Standup');
      await deleteJournalWithEntries('j');

      final journal = (await journals.getJournal('j'))!;
      final entry = (await journals.getEntry('e1'))!;
      final pulledJournal = mergeJournalFromRemote(
        journalToFirestore(journal),
        'j',
      );
      final pulledEntry = mergeJournalEntryFromRemote(
        journalEntryToFirestore(entry),
        'e1',
      );

      expect(
        pulledEntry.deletedAt!.isAtSameMomentAs(pulledJournal.deletedAt!),
        isTrue,
      );
    });
  });

  group('list', () {
    test('rows past the retention window are not listed', () async {
      await addEntry('e', legacyJournalId, 'Old');
      await journals.softDeleteEntry('e');

      expect(await trash.list(), hasLength(1));
      expect(
        await trash.list(now: utcNow().add(const Duration(days: 31))),
        isEmpty,
      );
    });

    test('rows that are never shown on their own stay out', () async {
      await calendars.upsertEvent(
        CalendarEvent(
          id: 'ev',
          calendarId: 'cal',
          title: 'Dentist',
          start: created,
          end: created,
          createdAt: created,
          updatedAt: created,
        ),
      );
      await calendars.softDeleteEvent('ev');
      await DriftStudyRepository(db).upsertDeckLink(
        StudyDeckLink(
          id: 'link',
          parentDeckId: 'a',
          childDeckId: 'b',
          createdAt: created,
          updatedAt: created,
          deletedAt: utcNow(),
        ),
      );

      final items = await trash.list();

      expect(items.map((item) => item.kind.collection), [
        FirestoreCollections.calendarEvents,
      ]);
    });
  });

  group('restore', () {
    test(
      'brings a journal back with exactly the entries deleted with it',
      () async {
        await addJournal('j', 'Work');
        await addEntry('e1', 'j', 'Standup');
        await addEntry('e2', 'j', 'Retro');
        await journals.softDeleteEntry('e2');
        await deleteJournalWithEntries('j');
        final before = (await journals.getEntry('e1'))!.version;

        final item = (await trash.list()).firstWhere((i) => i.id == 'j');
        final movedTo = await trash.restore(item);

        expect(movedTo, isNull);
        expect((await journals.getJournal('j'))!.deletedAt, isNull);
        final e1 = (await journals.getEntry('e1'))!;
        expect(e1.deletedAt, isNull);
        expect(e1.version, before + 1);
        expect((await journals.getEntry('e2'))!.deletedAt, isNotNull);
        await trash.uploads;
        expect(uploader.records[FirestoreCollections.journals], hasLength(1));
        expect(
          uploader.records[FirestoreCollections.journalEntries],
          hasLength(1),
        );
        expect(mediaCalls.map((c) => c.id), ['e1']);
      },
    );

    test('an entry whose journal is in the trash too goes to the default '
        'journal', () async {
      await addJournal('j', 'Work');
      await addEntry('e', 'j', 'Standup');
      await journals.softDeleteEntry('e');
      await deleteJournalWithEntries('j');

      final item = (await trash.list()).firstWhere((i) => i.id == 'e');
      final movedTo = await trash.restore(item);

      expect(movedTo, 'Journal');
      final entry = (await journals.getEntry('e'))!;
      expect(entry.deletedAt, isNull);
      expect(entry.journalId, legacyJournalId);
      expect((await journals.getJournal('j'))!.deletedAt, isNotNull);
    });

    test('an entry whose journal is live goes back into it', () async {
      await addJournal('j', 'Work');
      await addEntry('e', 'j', 'Standup');
      await journals.softDeleteEntry('e');

      final movedTo = await trash.restore((await trash.list()).single);

      expect(movedTo, isNull);
      expect((await journals.getEntry('e'))!.journalId, 'j');
    });

    test('a card whose deck is gone has nowhere to go', () async {
      await study.upsertDeck(
        StudyDeck(
          id: 'd',
          name: 'Mitosis',
          createdAt: created,
          updatedAt: created,
        ),
      );
      await study.upsertCard(
        StudyCard(
          id: 'c',
          deckId: 'd',
          frontText: 'Q',
          backText: 'A',
          dueAt: created,
          createdAt: created,
          updatedAt: created,
        ),
      );
      await study.softDeleteCard('c');
      // See [deleteJournalWithEntries] on why the pause.
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await study.softDeleteDeck('d');

      final card = (await trash.list()).firstWhere((i) => i.id == 'c');

      await expectLater(
        trash.restore(card),
        throwsA(
          isA<TrashRestoreBlocked>()
              .having((b) => b.parentNoun, 'noun', 'deck')
              .having((b) => b.parentTitle, 'title', 'Mitosis'),
        ),
      );
      expect((await study.getCard('c'))!.deletedAt, isNotNull);
    });

    test('a row already back is reported, not rewritten', () async {
      await addEntry('e', legacyJournalId, 'Standup');
      await journals.softDeleteEntry('e');
      final item = (await trash.list()).single;
      await trash.restore(item);

      await expectLater(trash.restore(item), throwsA(isA<RestoreSuperseded>()));
    });
  });

  group('erase', () {
    test('empties the row and everything deleted with it, for good', () async {
      await addJournal('j', 'Work');
      await addEntry('e1', 'j', 'Standup');
      await deleteJournalWithEntries('j');
      final before = (await journals.getEntry('e1'))!.version;

      await trash.erase(await trash.list());

      final journal = (await journals.getJournal('j'))!;
      final entry = (await journals.getEntry('e1'))!;
      expect(isErasedAt(journal.deletedAt), isTrue);
      expect(journal.name, isEmpty);
      expect(isErasedAt(entry.deletedAt), isTrue);
      expect(entry.title, isEmpty);
      expect(entry.body, isEmpty);
      expect(entry.version, before + kEraseVersionStep);
      expect(await trash.list(), isEmpty);
      await trash.uploads;
      expect(
        uploader.records[FirestoreCollections.journalEntries],
        hasLength(1),
      );
    });

    test('an erased row is never purged; an ordinary tombstone is, once the '
        'retention window has passed', () async {
      // Both deleted 20 days ago.
      final deletedAt = utcNow().subtract(const Duration(days: 20));
      for (final id in ['erased', 'deleted']) {
        await journals.upsertEntry(
          JournalEntry(
            id: id,
            journalId: legacyJournalId,
            title: id,
            body: 'text',
            entryDate: created,
            createdAt: created,
            updatedAt: deletedAt,
            deletedAt: deletedAt,
          ),
        );
      }
      await trash.erase([
        (await trash.list()).firstWhere((i) => i.id == 'erased'),
      ]);

      // 31 days after the delete.
      await journals.purgeExpiredDeleted(
        utcNow().add(const Duration(days: 11)),
      );
      expect(await journals.getEntry('deleted'), isNull);
      expect(await journals.getEntry('erased'), isNotNull);

      // A device back after a year still meets the erase.
      await journals.purgeExpiredDeleted(
        utcNow().add(const Duration(days: 365)),
      );
      expect(await journals.getEntry('erased'), isNotNull);
    });

    test('an erased row is not listed or erased again', () async {
      await addEntry('e', legacyJournalId, 'Gone');
      await journals.softDeleteEntry('e');
      final item = (await trash.list()).single;
      await trash.erase([item]);
      final version = (await journals.getEntry('e'))!.version;

      await trash.erase([item]);

      expect((await journals.getEntry('e'))!.version, version);
      expect(trashKinds[FirestoreCollections.journalEntries]!.listed, isTrue);
    });
  });
}
