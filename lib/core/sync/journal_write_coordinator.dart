import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/domain/models/dream_models.dart';
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

  /// Saves a delta against the current SQLite row.
  ///
  /// [refreshCaches] drives [onEntrySaved], which invalidates the app-wide
  /// journal providers. It defaults to true because a one-shot save (the search
  /// popup, a metadata edit, a create) is the only way anything watching those
  /// providers can learn the entry changed. The journal editor's ~400ms
  /// autosave passes false: it fires once per typing burst, and every provider
  /// in that set re-reads the *entire* entry table when invalidated — including
  /// the deleted rows, through `journalAllEntryIdsProvider`, and every entry's
  /// tags again, through `tagPoolProvider`. Nothing an autosave changes is
  /// visible through any of them anyway; the row on screen follows the edit
  /// live through the page's title/body preview notifiers, and the page
  /// refreshes them properly at its commitment points.
  Future<void> saveEntry({
    required String entryId,
    required JournalEntry Function(JournalEntry baseline) applyDelta,
    bool bumpVersion = false,
    bool refreshCaches = true,
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
        if (refreshCaches) onEntrySaved?.call();
        onSuccess?.call(updated);
      },
    );
  }
}

/// Same baseline-then-delta pattern for dream entry saves.
class DreamWriteCoordinator {
  DreamWriteCoordinator({
    required DreamRepository dreamRepository,
    required RemoteSyncService remoteSync,
    this.onEntrySaved,
  }) : _dreamRepository = dreamRepository,
       _remoteSync = remoteSync;

  final DreamRepository _dreamRepository;
  final RemoteSyncService _remoteSync;
  final void Function()? onEntrySaved;

  Future<void> saveEntry({
    required String entryId,
    required DreamEntry Function(DreamEntry baseline) applyDelta,
    bool bumpVersion = false,
    void Function(DreamEntry saved)? onSuccess,
  }) {
    return _remoteSync.saveDreamEntryThenScheduleUpload(
      entryId: entryId,
      saveLocal: () async {
        final baseline = await _dreamRepository.getEntry(entryId);
        if (baseline == null) {
          throw StateError('Dream entry $entryId not found in SQLite');
        }
        final updated = applyDelta(baseline).copyWith(bumpVersion: bumpVersion);
        await _dreamRepository.upsertEntry(updated);
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

  /// A single indexed lookup, not a walk of every task in every list.
  ///
  /// This runs twice per save — once for the local write, once for the remote
  /// one — behind a 400 ms debounce, so on a list of a few thousand tasks the
  /// old scan was the dominant cost of typing in the edit panel, on the UI
  /// isolate.
  Future<TodoTask?> _findTask(String taskId) {
    return _todoRepository.getTask(taskId);
  }
}
