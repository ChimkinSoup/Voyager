import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/constants/calendar_constants.dart';
import 'package:voyager/core/constants/journal_constants.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/domain/models/job_models.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/todo_models.dart';

void main() {
  test('remote journal entry merge prefers newer version', () {
    final older = DateTime.utc(2024, 1, 1);
    final newer = DateTime.utc(2024, 2, 1);
    final local = JournalEntry(
      id: 'entry-1',
      journalId: 'journal-1',
      title: 'Local title',
      body: 'Local body',
      entryDate: older,
      createdAt: older,
      updatedAt: newer,
      version: 2,
    );

    final merged = mergeJournalEntryFromRemote(
      {
        'journalId': 'journal-1',
        'title': 'Remote title',
        'body': 'Remote body',
        'entryDate': older.toIso8601String(),
        'updatedAt': newer.toIso8601String(),
        'version': 1,
      },
      'entry-1',
      local: local,
    );

    expect(merged.title, 'Local title');
    expect(merged.body, 'Local body');
    expect(merged.version, 2);
  });

  test('CRDT body merge applies even when local metadata version is newer', () {
    final now = utcNow();
    final local = JournalEntry(
      id: 'entry-1',
      journalId: 'journal-1',
      title: 'Local title',
      body: 'Local body',
      entryDate: now,
      createdAt: now,
      updatedAt: now,
      version: 5,
    );

    final merged = mergeJournalEntryFromRemote(
      {
        'journalId': 'journal-1',
        'title': 'Remote title',
        'body': 'Remote body',
        'entryDate': now.toIso8601String(),
        'updatedAt': now.subtract(const Duration(hours: 1)).toIso8601String(),
        'version': 2,
      },
      'entry-1',
      local: local,
      crdtText: const CrdtTextFields(body: 'CRDT body', tags: ['remote']),
    );

    expect(merged.title, 'Local title');
    expect(merged.body, 'CRDT body');
    expect(merged.tags, ['remote']);
    expect(merged.version, 5);
  });

  test(
    'remote journal entry merge prefers newer updatedAt when versions tie',
    () {
      final older = DateTime.utc(2024, 1, 1);
      final newer = DateTime.utc(2024, 2, 1);
      final local = JournalEntry(
        id: 'entry-1',
        journalId: 'journal-1',
        title: 'Local title',
        body: 'Local body',
        entryDate: older,
        createdAt: older,
        updatedAt: newer,
      );

      final merged = mergeJournalEntryFromRemote(
        {
          'journalId': 'journal-1',
          'title': 'Remote title',
          'body': 'Remote body',
          'entryDate': older.toIso8601String(),
          'updatedAt': older.toIso8601String(),
        },
        'entry-1',
        local: local,
      );

      expect(merged.title, 'Local title');
      expect(merged.body, 'Local body');
    },
  );

  test('remote journal entry merge applies remote delete', () {
    final now = utcNow();
    final deletedAt = now.add(const Duration(hours: 1));
    final merged = mergeJournalEntryFromRemote({
      'journalId': 'journal-1',
      'title': 'Deleted entry',
      'body': '',
      'entryDate': now.toIso8601String(),
      'updatedAt': deletedAt.toIso8601String(),
      'deletedAt': deletedAt.toIso8601String(),
    }, 'entry-1');

    expect(merged.deletedAt, deletedAt);
  });

  test('journal entry firestore round trip keeps rich fields', () {
    final now = utcNow();
    final entry = JournalEntry(
      id: 'entry-1',
      journalId: 'journal-1',
      title: 'Title',
      body: 'Body',
      richBodyJson: '{"ops":[]}',
      entryDate: now,
      timestamp: now,
      tags: const ['work'],
      mood: 4,
      quoteId: 'quote-1',
      customQuote: 'Quote',
      weatherIcon: 'cloudy',
      guidedPrompt: 'Prompt',
      createdAt: now,
      updatedAt: now,
    );

    final restored = mergeJournalEntryFromRemote(
      journalEntryToFirestore(entry),
      entry.id,
    );

    expect(restored.richBodyJson, entry.richBodyJson);
    expect(restored.tags, entry.tags);
    expect(restored.mood, entry.mood);
    expect(restored.quoteId, entry.quoteId);
    expect(restored.customQuote, entry.customQuote);
    expect(restored.weatherIcon, entry.weatherIcon);
    expect(restored.guidedPrompt, entry.guidedPrompt);
  });

  test('todo task firestore round trip keeps star and subtask fields', () {
    final now = utcNow();
    final task = TodoTask(
      id: 'task-1',
      listId: 'list-1',
      title: 'Task',
      notes: 'Notes',
      dueDate: now,
      completed: true,
      starred: true,
      sortOrder: 3,
      parentTaskId: 'parent-1',
      createdAt: now,
      updatedAt: now,
    );

    final restored = mergeTodoTaskFromRemote(
      todoTaskToFirestore(task),
      task.id,
    );

    expect(restored.notes, task.notes);
    expect(restored.starred, isTrue);
    expect(restored.parentTaskId, 'parent-1');
  });

  test('legacy journal id maps to a firestore-safe document id', () {
    final now = utcNow();
    final journal = Journal(
      id: legacyJournalId,
      name: 'Journal',
      createdAt: now,
      updatedAt: now,
    );
    final entry = JournalEntry(
      id: 'entry-1',
      journalId: legacyJournalId,
      title: 'Title',
      body: 'Body',
      entryDate: now,
      createdAt: now,
      updatedAt: now,
    );

    final journalPayload = journalToFirestore(journal);
    final entryPayload = journalEntryToFirestore(entry);

    expect(journalPayload['id'], legacyJournalFirestoreId);
    expect(entryPayload['journalId'], legacyJournalFirestoreId);

    final restoredJournal = mergeJournalFromRemote(
      journalPayload,
      legacyJournalId,
    );
    final restoredEntry = mergeJournalEntryFromRemote(entryPayload, entry.id);

    expect(restoredJournal.id, legacyJournalId);
    expect(restoredEntry.journalId, legacyJournalId);
  });

  test('legacy calendar id maps to a firestore-safe document id', () {
    // Calendars were local-only when their default id was chosen, so it was
    // spelled with the reserved `__` segments Firestore rejects. Once they
    // started syncing, every upload of the default calendar came back
    // `invalid-argument` and was parked on the outbox.
    final now = utcNow();
    final calendar = Calendar(
      id: legacyCalendarId,
      name: 'Calendar',
      createdAt: now,
      updatedAt: now,
    );
    final event = CalendarEvent(
      id: 'event-1',
      calendarId: legacyCalendarId,
      title: 'Standup',
      start: now,
      end: now,
      createdAt: now,
      updatedAt: now,
    );

    final calendarPayload = calendarToFirestore(calendar);
    final eventPayload = calendarEventToFirestore(event);

    expect(calendarPayload['id'], legacyCalendarFirestoreId);
    expect(eventPayload['calendarId'], legacyCalendarFirestoreId);
    expect(
      firestoreDocumentIdForLocal(
        FirestoreCollections.calendars,
        legacyCalendarId,
      ),
      legacyCalendarFirestoreId,
    );

    final restoredCalendar = mergeCalendarFromRemote(
      calendarPayload,
      legacyCalendarId,
    );
    final restoredEvent = mergeCalendarEventFromRemote(eventPayload, event.id);

    expect(restoredCalendar.id, legacyCalendarId);
    expect(restoredEvent.calendarId, legacyCalendarId);
  });

  test('an event synced before the alias keeps resolving', () {
    // `calendarId` is a field value, not a document id, so it was never
    // rejected — events already on the server carry the raw local id. The
    // reverse mapper passes anything it does not recognise straight through,
    // which is what keeps both spellings working.
    final now = utcNow();
    final restored = mergeCalendarEventFromRemote({
      'id': 'event-2',
      'calendarId': legacyCalendarId,
      'title': 'Older event',
      'start': now.toIso8601String(),
      'end': now.toIso8601String(),
      'updatedAt': now.toIso8601String(),
      'version': 1,
    }, 'event-2');

    expect(restored.calendarId, legacyCalendarId);
  });

  // A record the remote has already outranked is adopted whole, including the
  // absence of a tombstone. Keeping the local `deletedAt` here made a delete a
  // one-way trapdoor: `softDelete` could set one but no later revision from
  // anywhere could lift it, so a record restored on one device stayed
  // invisible on every other one forever.
  test('mergeJournalFromRemote lets a newer remote lift a local tombstone', () {
    final now = utcNow();
    final deletedAt = now.subtract(const Duration(days: 1));
    final local = Journal(
      id: 'journal-deleted',
      name: 'Old name',
      createdAt: now,
      updatedAt: deletedAt,
      deletedAt: deletedAt,
    );
    final remote = {
      'name': 'Remote rename',
      'updatedAt': now.toIso8601String(),
    };

    final merged = mergeJournalFromRemote(remote, local.id, local: local);

    expect(merged.deletedAt, isNull);
    expect(merged.name, 'Remote rename');
  });

  // The other half of the same rule, and the reason lifting is safe: a remote
  // copy that loses the version comparison never reaches the deletedAt merge
  // at all, so a device that hasn't seen the delete yet cannot resurrect it.
  test(
    'mergeJournalFromRemote keeps a local tombstone against a stale remote',
    () {
      final now = utcNow();
      final deletedAt = now;
      final local = Journal(
        id: 'journal-deleted',
        name: 'Local name',
        createdAt: now.subtract(const Duration(days: 2)),
        updatedAt: deletedAt,
        version: 4,
        deletedAt: deletedAt,
      );
      final remote = {
        'name': 'Stale rename',
        'updatedAt': now.subtract(const Duration(days: 1)).toIso8601String(),
        'version': 3,
      };

      final merged = mergeJournalFromRemote(remote, local.id, local: local);

      expect(merged.deletedAt, deletedAt);
      expect(merged.name, 'Local name');
    },
  );

  group('job application seasons', () {
    final now = DateTime.utc(2026, 8, 20);

    test('a document from a device that still writes seasonId reads as a '
        'one-entry list', () {
      // Back-compat: the other device has not been updated yet, and its
      // documents carry the single `seasonId` this field replaced.
      final merged = mergeJobApplicationFromRemote({
        'company': 'Tesla',
        'title': 'SWE Intern',
        'status': 'Applied',
        'dateApplied': now.toIso8601String(),
        'seasonId': 'fall',
        'createdAt': now.toIso8601String(),
        'updatedAt': now.toIso8601String(),
        'version': 1,
      }, 'app-1');

      expect(merged.seasonIds, ['fall']);
    });

    test('seasonIds wins when a document carries both', () {
      final merged = mergeJobApplicationFromRemote({
        'company': 'Tesla',
        'title': 'SWE Intern',
        'status': 'Applied',
        'dateApplied': now.toIso8601String(),
        'seasonId': 'fall',
        'seasonIds': ['fall', 'spring'],
        'createdAt': now.toIso8601String(),
        'updatedAt': now.toIso8601String(),
        'version': 1,
      }, 'app-1');

      expect(merged.seasonIds, ['fall', 'spring']);
    });

    test('an empty list is taken as written, not inherited from local', () {
      // Taking an application out of every season is expressed as the list
      // going empty; falling back to the local value would make it impossible
      // to sync.
      final local = JobApplication(
        id: 'app-1',
        company: 'Tesla',
        title: 'SWE Intern',
        status: 'Applied',
        dateApplied: now,
        seasonIds: const ['fall'],
        createdAt: now,
        updatedAt: now,
        version: 1,
      );
      final merged = mergeJobApplicationFromRemote(
        {
          'company': 'Tesla',
          'title': 'SWE Intern',
          'status': 'Applied',
          'dateApplied': now.toIso8601String(),
          'seasonIds': const <String>[],
          'createdAt': now.toIso8601String(),
          'updatedAt': DateTime.utc(2026, 9).toIso8601String(),
          'version': 2,
        },
        'app-1',
        local: local,
      );

      expect(merged.seasonIds, isEmpty);
    });

    test('the list round-trips through the write side', () {
      final application = JobApplication(
        id: 'app-1',
        company: 'Tesla',
        title: 'SWE Intern',
        status: 'Applied',
        dateApplied: now,
        seasonIds: const ['fall', 'spring'],
        createdAt: now,
        updatedAt: now,
      );
      final document = jobApplicationToFirestore(application);
      expect(document['seasonIds'], ['fall', 'spring']);
      expect(mergeJobApplicationFromRemote(document, 'app-1').seasonIds, [
        'fall',
        'spring',
      ]);
    });
  });
}
