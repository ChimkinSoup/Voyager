import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/domain/services/calendar_recurrence.dart';
import 'package:voyager/features/gaia/host/gaia_executor.dart';
import 'package:voyager/features/gaia/host/gaia_voyager_reads.dart';
import 'package:voyager/features/gaia/tools/gaia_proposals.dart';

import 'fakes/gaia_fakes.dart';

/// The main instance's action executor (GAIA_HLD.md §10), against an
/// in-memory database: what a `propose_*` call becomes, what an accepted
/// card writes, and how the action log takes it back.
void main() {
  late AppDatabase db;
  late DriftTodoRepository todos;
  late DriftCalendarRepository calendar;
  late DriftJournalRepository journal;
  late GaiaExecutor executor;
  final at = DateTime.utc(2026, 10, 1);
  var ids = 0;
  late DateTime clock;

  setUp(() async {
    db = AppDatabase.inMemory();
    todos = DriftTodoRepository(db);
    calendar = DriftCalendarRepository(db);
    journal = DriftJournalRepository(db);
    ids = 0;
    clock = DateTime(2026, 10, 28, 9);
    executor = GaiaExecutor(
      todos: todos,
      calendar: calendar,
      journal: journal,
      settings: DriftSettingsRepository(db),
      writes: DirectGaiaWrites(todos, calendar, journal),
      now: () => clock,
      newRowId: () => 'new${ids++}',
    );
    for (final (id, name) in [('l1', 'Inbox'), ('l2', 'Work')]) {
      await todos.upsertList(
        TodoListModel(id: id, createdAt: at, updatedAt: at, name: name),
      );
    }
    await calendar.upsertCalendar(
      Calendar(id: 'c1', createdAt: at, updatedAt: at, name: 'Personal'),
    );
    await journal.upsertJournal(
      Journal(id: 'j1', createdAt: at, updatedAt: at, name: 'Daily'),
    );
  });

  tearDown(() => db.close());

  Future<GaiaCommitted> accept(
    String cardId,
    GaiaProposal proposal, [
    Map<String, Object?> edits = const {},
  ]) => executor.commit(cardId, gaiaApprovalToken(), {
    ...proposal.fields,
    ...edits,
  });

  group('todo', () {
    test('a new task, in the named list, as the user edited it', () async {
      final proposal = await executor.prepare('card', 'propose_todo', {
        'title': 'Call the dentist',
        'list': 'work',
        'due': '2026-10-30',
      });
      expect(proposal.isEdit, isFalse);
      expect(proposal.fields, {
        'list': 'l2',
        'title': 'Call the dentist',
        'notes': '',
        'due': '2026-10-30',
        'starred': false,
        'completed': false,
      });
      expect(proposal.choices.map((c) => c.name), ['Inbox', 'Work']);
      final committed = await accept('card', proposal, {
        'due': '2026-10-30T14:00',
      });
      final task = (await todos.getTask('new0'))!;
      expect(task.title, 'Call the dentist');
      expect(task.listId, 'l2');
      expect(task.dueHasTime, isTrue);
      expect(task.dueDate!.toLocal(), DateTime(2026, 10, 30, 14));
      expect(task.origin, kGaiaOrigin);
      expect(committed.record, {
        'entity': 'todo',
        'id': 'new0',
        'version': task.version,
      });
      expect(committed.text, contains('Saved a new task (id new0)'));
      expect(
        committed.text,
        contains(
          '- Due: Fri 30 Oct 2026 14:00 (changed by the user; you proposed '
          'Fri 30 Oct 2026)',
        ),
      );
      expect(committed.text, contains('- Title: Call the dentist\n'));
    });

    test('a change: only the fields named, from the task as it is, and it '
        'keeps its origin', () async {
      await todos.upsertTask(
        TodoTask(
          id: 't1',
          createdAt: at,
          updatedAt: at,
          listId: 'l1',
          title: 'Buy milk',
          notes: 'oat',
        ),
      );
      final proposal = await executor.prepare('card', 'propose_todo', {
        'id': 't1',
        'completed': true,
      });
      expect(proposal.targetId, 't1');
      expect(proposal.before!['completed'], isFalse);
      expect(gaiaProposalChanged(proposal, proposal.fields), ['completed']);
      final committed = await accept('card', proposal);
      final task = (await todos.getTask('t1'))!;
      expect(task.completed, isTrue);
      expect(task.notes, 'oat');
      expect(task.origin, isNull);
      expect(committed.record['before'], proposal.before);
      expect(committed.text, endsWith('- Done: yes'));
      expect(committed.text, isNot(contains('Title')));
    });

    test('a change the user took back in the editor is still told, as '
        'theirs', () async {
      await todos.upsertTask(
        TodoTask(
          id: 't1',
          createdAt: at,
          updatedAt: at,
          listId: 'l1',
          title: 'Buy milk',
        ),
      );
      final proposal = await executor.prepare('card', 'propose_todo', {
        'id': 't1',
        'title': 'Buy oat milk',
      });
      final committed = await accept('card', proposal, {
        'title': 'Buy milk',
        'starred': true,
      });
      expect(
        committed.text,
        contains(
          '- Title: Buy milk (changed by the user; you proposed Buy oat milk)',
        ),
      );
      expect(
        committed.text,
        contains('- Starred: yes (changed by the user; you proposed no)'),
      );
    });

    test("a change that changes nothing isn't proposed", () async {
      await todos.upsertTask(
        TodoTask(
          id: 't1',
          createdAt: at,
          updatedAt: at,
          listId: 'l1',
          title: 'Buy milk',
        ),
      );
      await expectLater(
        executor.prepare('card', 'propose_todo', {
          'id': 't1',
          'title': 'Buy milk',
        }),
        throwsA(isA<GaiaReadException>()),
      );
    });

    test('a list or id that does not exist is the agent\'s to fix', () async {
      await expectLater(
        executor.prepare('card', 'propose_todo', {'list': 'Nope'}),
        throwsA(
          isA<GaiaReadException>().having(
            (e) => e.message,
            'message',
            contains('There are: Inbox, Work'),
          ),
        ),
      );
      await expectLater(
        executor.prepare('card', 'propose_todo', {'id': 'missing'}),
        throwsA(isA<GaiaReadException>()),
      );
    });

    test('a new title on an open task is saved, and undone', () async {
      await todos.upsertTask(
        TodoTask(
          id: 't1',
          createdAt: at,
          updatedAt: at,
          listId: 'l1',
          title: 'Buy milk',
        ),
      );
      final proposal = await executor.prepare('card', 'propose_todo', {
        'id': 't1',
        'title': 'Buy oat milk',
      });
      final committed = await accept('card', proposal);
      expect((await todos.getTask('t1'))!.title, 'Buy oat milk');
      await executor.undo(committed.record);
      expect((await todos.getTask('t1'))!.title, 'Buy milk');
    });

    test("a repeating task the user ticked in the editor isn't ticked "
        'off', () async {
      await todos.upsertTask(
        TodoTask(
          id: 't1',
          createdAt: at,
          updatedAt: at,
          listId: 'l1',
          title: 'Water plants',
          dueDate: DateTime.utc(2026, 10, 30),
          recurrence: const RecurrenceRule(frequency: EventRecurrence.daily),
        ),
      );
      final proposal = await executor.prepare('card', 'propose_todo', {
        'id': 't1',
        'title': 'Water the plants',
      });
      await expectLater(
        accept('card', proposal, {'completed': true}),
        throwsA(isA<GaiaReadException>()),
      );
      expect((await todos.getTask('t1'))!.completed, isFalse);
    });

    test('a task changed since it was proposed is not overwritten', () async {
      final task = TodoTask(
        id: 't1',
        createdAt: at,
        updatedAt: at,
        listId: 'l1',
        title: 'Buy milk',
      );
      await todos.upsertTask(task);
      final proposal = await executor.prepare('card', 'propose_todo', {
        'id': 't1',
        'title': 'Buy oat milk',
      });
      await todos.upsertTask(task.copyWith(title: 'Buy almond milk'));
      await expectLater(
        accept('card', proposal),
        throwsA(isA<GaiaReadException>()),
      );
      expect((await todos.getTask('t1'))!.title, 'Buy almond milk');
    });
  });

  group('commit', () {
    test('needs a token, and happens once per card', () async {
      final proposal = await executor.prepare('card', 'propose_todo', {
        'title': 'One',
      });
      await expectLater(
        executor.commit('card', 'not a token', proposal.fields),
        throwsA(isA<GaiaReadException>()),
      );
      // The refused try didn't use it up: the card can still be accepted.
      await accept('card', proposal);
      await expectLater(
        accept('card', proposal),
        throwsA(isA<GaiaReadException>()),
      );
      expect(await todos.listTasks('l1'), hasLength(1));
    });

    test('never for a card it did not prepare, or one dropped', () async {
      final proposal = await executor.prepare('card', 'propose_todo', {
        'title': 'One',
      });
      await expectLater(
        accept('other', proposal),
        throwsA(isA<GaiaReadException>()),
      );
      executor.drop('card');
      await expectLater(
        accept('card', proposal),
        throwsA(isA<GaiaReadException>()),
      );
      expect(await todos.listTasks('l1'), isEmpty);
    });

    test('forgets one never dropped once its card is past waiting', () async {
      final kept = await executor.prepare('kept', 'propose_todo', {
        'title': 'Kept',
      });
      final stale = await executor.prepare('stale', 'propose_todo', {
        'title': 'Stale',
      });
      clock = clock.add(const Duration(hours: 1));
      final late = await executor.prepare('late', 'propose_todo', {
        'title': 'Late',
      });
      await accept('kept', kept);
      clock = clock.add(const Duration(minutes: 10));
      await executor.prepare('next', 'propose_todo', {'title': 'Next'});
      await expectLater(
        accept('stale', stale),
        throwsA(isA<GaiaReadException>()),
      );
      await accept('late', late);
    });

    test('checks the fields again, whatever the companion sent', () async {
      final proposal = await executor.prepare('card', 'propose_todo', {
        'title': 'One',
      });
      await expectLater(
        accept('card', proposal, {'title': '  '}),
        throwsA(
          isA<GaiaReadException>().having(
            (e) => e.message,
            'message',
            'A task needs a title.',
          ),
        ),
      );
    });
  });

  group('calendar', () {
    test('a timed event lasts an hour unless it says; an all-day one, its '
        'day', () async {
      final timed = await executor.prepare('a', 'propose_calendar_event', {
        'title': 'Dentist',
        'start': '2026-10-30T14:00',
      });
      expect(timed.fields['allDay'], isFalse);
      expect(timed.fields['end'], '2026-10-30T15:00');
      expect(timed.fields['calendar'], 'c1');
      await accept('a', timed);
      final event = (await calendar.getEvent('new0'))!;
      expect(event.start, DateTime(2026, 10, 30, 14));
      expect(event.end, DateTime(2026, 10, 30, 15));
      expect(event.isFullDay, isFalse);
      expect(event.origin, kGaiaOrigin);

      final allDay = await executor.prepare('b', 'propose_calendar_event', {
        'title': 'Holiday',
        'start': '2026-11-02',
        'end': '2026-11-04',
      });
      expect(allDay.fields['allDay'], isTrue);
      await accept('b', allDay);
      final holiday = (await calendar.getEvent('new1'))!;
      expect(holiday.isFullDay, isTrue);
      expect(calendarEventOccursOnDay(holiday, DateTime(2026, 11, 4)), isTrue);
      expect(calendarEventOccursOnDay(holiday, DateTime(2026, 11, 5)), isFalse);
    });

    test('a moved event keeps its length', () async {
      await calendar.upsertEvent(
        CalendarEvent(
          id: 'e1',
          createdAt: at,
          updatedAt: at,
          calendarId: 'c1',
          title: 'Workshop',
          start: DateTime(2026, 10, 30, 10),
          end: DateTime(2026, 10, 30, 13),
          isFullDay: false,
        ),
      );
      final timed = await executor.prepare('a', 'propose_calendar_event', {
        'id': 'e1',
        'start': '2026-10-30T15:00',
      });
      expect(timed.fields['end'], '2026-10-30T18:00');

      await calendar.upsertEvent(
        CalendarEvent(
          id: 'e2',
          createdAt: at,
          updatedAt: at,
          calendarId: 'c1',
          title: 'Trip',
          start: DateTime(2026, 10, 30),
          end: DateTime(2026, 11, 1, 1),
          isFullDay: true,
        ),
      );
      final allDay = await executor.prepare('b', 'propose_calendar_event', {
        'id': 'e2',
        'start': '2026-11-05',
      });
      expect(allDay.fields['end'], '2026-11-07');
    });

    test('a repeating event is not changed from Gaia', () async {
      await calendar.upsertEvent(
        CalendarEvent(
          id: 'e1',
          createdAt: at,
          updatedAt: at,
          calendarId: 'c1',
          title: 'Gym',
          start: DateTime(2026, 10, 1, 7),
          end: DateTime(2026, 10, 1, 8),
          isFullDay: false,
          recurrence: const RecurrenceRule(frequency: EventRecurrence.daily),
        ),
      );
      await expectLater(
        executor.prepare('card', 'propose_calendar_event', {
          'id': 'e1',
          'title': 'Run',
        }),
        throwsA(
          isA<GaiaReadException>().having(
            (e) => e.message,
            'message',
            contains('repeats'),
          ),
        ),
      );
    });
  });

  group('journal', () {
    test(
      'a new entry is written now, at the default mood, with its tags',
      () async {
        final proposal = await executor.prepare(
          'card',
          'propose_journal_entry',
          {'body': 'A good day at the #beach.'},
        );
        expect(proposal.fields['date'], '2026-10-28T09:00');
        expect(proposal.fields['mood'], kDefaultMood);
        expect(proposal.fields['journal'], 'j1');
        final committed = await accept('card', proposal, {'mood': 8});
        expect(committed.text, isNot(contains('- Entry:')));
        final entry = (await journal.getEntry('new0'))!;
        expect(entry.body, 'A good day at the #beach.');
        expect(entry.tags, ['beach']);
        expect(entry.mood, 8);
        expect(entry.entryDate.toLocal(), DateTime(2026, 10, 28, 9));
        expect(entry.origin, kGaiaOrigin);
      },
    );

    test("a new entry's text the user rewrote is told, without repeating "
        'the proposal', () async {
      final proposal = await executor.prepare('card', 'propose_journal_entry', {
        'body': 'A good day.',
      });
      final committed = await accept('card', proposal, {
        'body': 'A great day.',
      });
      expect(
        committed.text,
        contains('- Entry: A great day. (changed by the user)'),
      );
    });

    test("a change that doesn't move the entry keeps its time and "
        'offset', () async {
      final written = DateTime(2026, 10, 27, 14, 3, 27);
      await journal.upsertEntry(
        JournalEntry(
          id: 'j-e1',
          createdAt: at,
          updatedAt: at,
          journalId: 'j1',
          title: '',
          body: 'Before.',
          entryDate: written,
          utcOffsetMinutes: written.timeZoneOffset.inMinutes,
          mood: 4,
        ),
      );
      final stored = (await journal.getEntry('j-e1'))!;
      final proposal = await executor.prepare('card', 'propose_journal_entry', {
        'id': 'j-e1',
        'body': 'After.',
      });
      await accept('card', proposal);
      final entry = (await journal.getEntry('j-e1'))!;
      expect(entry.body, 'After.');
      expect(entry.entryDate, stored.entryDate);
      expect(entry.utcOffsetMinutes, stored.utcOffsetMinutes);
    });

    test('a day alone is written at noon', () async {
      final proposal = await executor.prepare('card', 'propose_journal_entry', {
        'body': 'Back then.',
        'date': '2026-10-20',
      });
      expect(proposal.fields['date'], '2026-10-20T12:00');
    });
  });

  group('undo', () {
    test('takes a new row to the trash', () async {
      final proposal = await executor.prepare('card', 'propose_todo', {
        'title': 'One',
      });
      final committed = await accept('card', proposal);
      await executor.undo(committed.record);
      expect((await todos.getTask('new0'))!.deletedAt, isNotNull);
    });

    test('puts a change back', () async {
      await journal.upsertEntry(
        JournalEntry(
          id: 'j-e1',
          createdAt: at,
          updatedAt: at,
          journalId: 'j1',
          title: '',
          body: 'Before.',
          entryDate: DateTime(2026, 10, 27, 21),
          mood: 4,
        ),
      );
      final proposal = await executor.prepare('card', 'propose_journal_entry', {
        'id': 'j-e1',
        'body': 'After.',
        'mood': 7,
      });
      final committed = await accept('card', proposal);
      expect((await journal.getEntry('j-e1'))!.body, 'After.');
      await executor.undo(committed.record);
      final entry = (await journal.getEntry('j-e1'))!;
      expect(entry.body, 'Before.');
      expect(entry.mood, 4);
      expect(entry.entryDate.toLocal(), DateTime(2026, 10, 27, 21));
    });

    test("won't undo over a change made since", () async {
      final proposal = await executor.prepare('card', 'propose_todo', {
        'title': 'One',
      });
      final committed = await accept('card', proposal);
      final task = (await todos.getTask('new0'))!;
      await todos.upsertTask(task.copyWith(title: 'One, edited'));
      await expectLater(
        executor.undo(committed.record),
        throwsA(isA<GaiaReadException>()),
      );
      expect((await todos.getTask('new0'))!.deletedAt, isNull);
    });
  });
}
