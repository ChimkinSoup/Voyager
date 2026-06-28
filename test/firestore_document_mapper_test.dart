import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/constants/journal_constants.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/core/utils/ids.dart';
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

  test('remote journal entry merge prefers newer updatedAt when versions tie', () {
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
  });

  test('remote journal entry merge applies remote delete', () {
    final now = utcNow();
    final deletedAt = now.add(const Duration(hours: 1));
    final merged = mergeJournalEntryFromRemote(
      {
        'journalId': 'journal-1',
        'title': 'Deleted entry',
        'body': '',
        'entryDate': now.toIso8601String(),
        'updatedAt': deletedAt.toIso8601String(),
        'deletedAt': deletedAt.toIso8601String(),
      },
      'entry-1',
    );

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
      preStarSortOrder: 1,
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
    expect(restored.preStarSortOrder, 1);
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
    final restoredEntry = mergeJournalEntryFromRemote(
      entryPayload,
      entry.id,
    );

    expect(restoredJournal.id, legacyJournalId);
    expect(restoredEntry.journalId, legacyJournalId);
  });

  test(
    'mergeJournalFromRemote preserves local tombstone when remote omits deletedAt',
    () {
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

      final merged = mergeJournalFromRemote(
        remote,
        local.id,
        local: local,
      );

      expect(merged.deletedAt, deletedAt);
      expect(merged.name, 'Remote rename');
    },
  );
}
