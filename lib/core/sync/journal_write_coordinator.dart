import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';

/// Serializes local SQLite writes through a strictly ordered per-document queue.
///
/// Every write fetches the latest row from SQLite before applying a field delta.
class JournalWriteCoordinator {
  JournalWriteCoordinator({
    required JournalRepository journalRepository,
    required RemoteSyncService remoteSync,
    this.onEntrySaved,
  }) : _journalRepository = journalRepository,
       _remoteSync = remoteSync;

  final JournalRepository _journalRepository;
  final RemoteSyncService _remoteSync;
  final void Function()? onEntrySaved;

  Future<void> saveEntry({
    required String entryId,
    required JournalEntry Function(JournalEntry baseline) applyDelta,
    bool bumpVersion = false,
    void Function(JournalEntry saved)? onSuccess,
  }) {
    return _remoteSync.saveJournalEntryThenScheduleUpload(
      entryId: entryId,
      saveLocal: () async {
        final baseline = await _journalRepository.getEntry(entryId);
        if (baseline == null) {
          throw StateError('Journal entry $entryId not found in SQLite');
        }
        final updated = applyDelta(baseline).copyWith(bumpVersion: bumpVersion);
        await _journalRepository.upsertEntry(updated);
        onEntrySaved?.call();
        onSuccess?.call(updated);
      },
    );
  }
}

/// Same baseline-then-delta pattern for todo task notes/title saves.
class TodoWriteCoordinator {
  TodoWriteCoordinator({
    required TodoRepository todoRepository,
    required RemoteSyncService remoteSync,
  }) : _todoRepository = todoRepository,
       _remoteSync = remoteSync;

  final TodoRepository _todoRepository;
  final RemoteSyncService _remoteSync;

  Future<void> saveTask({
    required String taskId,
    required Future<TodoTask?> Function(TodoTask baseline) applyDelta,
    bool bumpVersion = false,
    void Function(TodoTask saved)? onSuccess,
  }) async {
    await _remoteSync.saveLocalThenScheduleUpload(
      collection: FirestoreCollections.todoTasks,
      documentId: taskId,
      saveLocal: () async {
        final baseline = await _findTask(taskId);
        if (baseline == null) {
          throw StateError('Todo task $taskId not found in SQLite');
        }
        final updated = await applyDelta(baseline);
        if (updated == null) return;
        final toSave = updated.copyWith(bumpVersion: bumpVersion);
        await _todoRepository.upsertTask(toSave);
        onSuccess?.call(toSave);
      },
      saveRemote: () async {
        final latest = await _findTask(taskId);
        if (latest != null) {
          await _remoteSync.pushTodoTaskNow(latest);
        }
      },
    );
  }

  Future<TodoTask?> _findTask(String taskId) async {
    final lists = await _todoRepository.listLists(includeDeleted: true);
    for (final list in lists) {
      final tasks = await _todoRepository.listTasks(
        list.id,
        includeDeleted: true,
        topLevelOnly: false,
      );
      for (final task in tasks) {
        if (task.id == taskId) return task;
      }
    }
    return null;
  }
}
