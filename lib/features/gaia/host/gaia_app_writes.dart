import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/features/gaia/host/gaia_executor.dart';
import 'package:voyager/features/journal/journal_entry_delete.dart';
import 'package:voyager/features/todo/todo_list_actions.dart';

/// The executor's writes (GAIA_HLD.md §10) as Voyager's own pages make
/// them: through the repositories, the uploads they schedule, and the
/// providers the open pages watch.
class GaiaAppWrites implements GaiaVoyagerWrites {
  GaiaAppWrites(this._container);

  final ProviderContainer _container;

  @override
  Future<void> saveTasks(List<TodoTask> tasks) async {
    final repo = _container.read(todoRepositoryProvider);
    final remoteSync = _container.read(remoteSyncServiceProvider);
    for (final task in tasks) {
      await repo.upsertTask(task);
      remoteSync.pushTodoTaskInBackground(task);
    }
    _todosChanged();
  }

  @override
  Future<void> deleteTask(TodoTask task) async {
    await softDeleteTaskWithSubtasks(_container, task);
    _todosChanged();
  }

  void _todosChanged() => _container
    ..invalidate(todoTasksProvider)
    ..invalidate(allTodoTasksProvider)
    ..invalidate(todoListStatsProvider);

  @override
  Future<void> saveEvent(CalendarEvent event) async {
    // Its upload is the repository's own.
    await _container.read(calendarRepositoryProvider).upsertEvent(event);
    _container.invalidate(calendarEventsProvider);
  }

  @override
  Future<void> deleteEvent(String id) async {
    await _container.read(calendarRepositoryProvider).softDeleteEvent(id);
    _container.invalidate(calendarEventsProvider);
  }

  @override
  Future<void> createEntry(JournalEntry entry) async {
    await _container.read(journalRepositoryProvider).upsertEntry(entry);
    // A no-op delta, as the quick journal entry makes: the upload is
    // scheduled and the entry lists refreshed.
    await _container
        .read(journalWriteCoordinatorProvider)
        .saveEntry(entryId: entry.id, applyDelta: (base) => base);
  }

  @override
  Future<void> editEntry(
    String id,
    JournalEntry Function(JournalEntry current) apply,
  ) => _container
      .read(journalWriteCoordinatorProvider)
      .saveEntry(entryId: id, applyDelta: apply);

  @override
  Future<void> deleteEntry(String id) async {
    await softDeleteJournalEntry(_container, id);
  }
}
