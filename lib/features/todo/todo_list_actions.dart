import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/constants/todo_constants.dart';
import 'package:voyager/core/soft_delete/soft_delete_toast.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/confirm_dialog.dart';
import 'package:voyager/core/widgets/create_name_color_dialog.dart';
import 'package:voyager/core/widgets/palette_color_picker.dart';
import 'package:voyager/core/widgets/prompt_name_dialog.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/domain/todo/todo_task_sorting.dart';

Future<String?> promptTodoListName(
  BuildContext context,
  String title, {
  String? initial,
}) {
  return showPromptNameDialog(context, title: title, initial: initial);
}

Future<void> renameTodoList(
  BuildContext context,
  WidgetRef ref,
  TodoListModel list,
) async {
  final name = await promptTodoListName(
    context,
    'Rename list',
    initial: list.name,
  );
  if (name == null || name.trim().isEmpty || name.trim() == list.name) return;
  final updated = list.copyWith(name: name.trim());
  await ref.read(todoRepositoryProvider).upsertList(updated);
  ref.read(remoteSyncServiceProvider).pushTodoList(updated);
  ref.invalidate(todoListsProvider);
  await ref.read(todoListsProvider.future);
}

Future<void> changeTodoListColor(
  BuildContext context,
  WidgetRef ref,
  TodoListModel list,
  List<TodoListModel> allLists,
) async {
  final color = await pickPaletteColorWithRef(
    ref,
    context,
    current: list.colorValue,
    usedColors: allLists
        .where((item) => item.id != list.id && item.colorValue != null)
        .map((item) => item.colorValue!)
        .toSet(),
  );
  if (color == null) return;
  final updated = list.copyWith(colorValue: color);
  await ref.read(todoRepositoryProvider).upsertList(updated);
  ref.read(remoteSyncServiceProvider).pushTodoList(updated);
  ref.invalidate(todoListsProvider);
  await ref.read(todoListsProvider.future);
}

/// A task and its subtasks as they stood the instant before a delete, plus the
/// instant each row's images were detached at — everything
/// [restoreTaskWithSubtasks] needs.
class TodoTaskDeletion {
  const TodoTaskDeletion({required this.tasks, required this.mediaStamps});

  /// The pre-delete rows, parent first.
  final List<TodoTask> tasks;

  /// Detach instants keyed by task id, for the rows that had images. See
  /// [detachMediaForTasks] on why the instant is carried rather than inferred.
  final Map<String, DateTime> mediaStamps;
}

/// Soft-deletes [task] together with its subtasks, and returns what it takes
/// to put them back.
///
/// Subtasks are separate rows joined by `parentTaskId`, and the only reader is
/// `listSubtasks()`, reached exclusively through the parent's edit panel. Left
/// behind, they keep `deletedAt == null` — so `purgeExpiredDeleted` never
/// removes them — are excluded from every list view (`listTasks` is
/// top-level-only by default), and keep syncing forever; if the parent is ever
/// restored or arrives fresh from a remote pull, they reappear with it.
///
/// Takes a [ProviderContainer] rather than a `WidgetRef` because the undo the
/// toast offers is pressed seconds after the row it deleted has unmounted, and
/// a `WidgetRef` throws once its widget is gone.
Future<TodoTaskDeletion> softDeleteTaskWithSubtasks(
  ProviderContainer container,
  TodoTask task,
) async {
  final repo = container.read(todoRepositoryProvider);
  final remoteSync = container.read(remoteSyncServiceProvider);
  final now = utcNow();
  final subtasks = await repo.listSubtasks(task.id);
  final snapshots = [
    task,
    for (final subtask in subtasks)
      if (subtask.deletedAt == null) subtask,
  ];
  final rows = [for (final row in snapshots) row.copyWith(deletedAt: now)];
  await repo.upsertTasksBatch(rows);
  await remoteSync.pushTodoTasksBatch(rows);
  // Images follow the task onto the same 30-day clock. Only main tasks can
  // carry a gallery, so the subtasks have nothing to detach — but they are
  // passed through anyway rather than special-cased, because a subtask
  // promoted to a main task earlier in its life may well have one.
  final mediaStamps = await detachMediaForTasks(container, rows);
  return TodoTaskDeletion(tasks: snapshots, mediaStamps: mediaStamps);
}

/// Undoes [softDeleteTaskWithSubtasks] from the snapshot it returned.
///
/// The rows are rebuilt field by field rather than `copyWith`'d, because
/// `copyWith` reads `deletedAt ?? this.deletedAt` and so cannot clear a
/// tombstone.
///
/// Invalidates the task providers itself rather than leaving it to the caller.
/// Every caller is a widget that the delete is free to unmount — closing the
/// edit panel is the most likely thing to happen during an eight-second undo
/// window — and each of them gated its invalidation on `mounted`. The
/// providers are `keepAlive`, so a skipped invalidation never heals: the row
/// sits on disk, absent from the list and uncounted in its parent's subtask
/// total, until some unrelated write happens to invalidate the same family
/// key.
Future<void> restoreTaskWithSubtasks(
  ProviderContainer container,
  TodoTaskDeletion deletion,
) async {
  final repo = container.read(todoRepositoryProvider);
  // The versions are resolved against disk rather than against the snapshot —
  // see [restoreVersionFrom].
  final onDisk = <String, TodoTask?>{
    for (final task in deletion.tasks) task.id: await repo.getTask(task.id),
  };
  final head = deletion.tasks.first;
  abortIfAlreadyRestored(
    found: onDisk[head.id] != null,
    deletedAt: onDisk[head.id]?.deletedAt,
  );
  final rows = [
    for (final task in deletion.tasks)
      TodoTask(
        id: task.id,
        createdAt: task.createdAt,
        updatedAt: utcNow(),
        version: restoreVersionFrom(
          preDeleteVersion: task.version,
          currentVersion: onDisk[task.id]?.version,
        ),
        listId: task.listId,
        title: task.title,
        notes: task.notes,
        dueDate: task.dueDate,
        completed: task.completed,
        completedAt: task.completedAt,
        starred: task.starred,
        sortOrder: task.sortOrder,
        dueDateSetAt: task.dueDateSetAt,
        parentTaskId: task.parentTaskId,
        recurrence: task.recurrence,
        recurrenceAnchor: task.recurrenceAnchor,
      ),
  ];
  await repo.upsertTasksBatch(rows);
  await container.read(remoteSyncServiceProvider).pushTodoTasksBatch(rows);

  // Both in a `finally`, and both through the container rather than a
  // `WidgetRef`: re-attaching images failing is not the rows failing to come
  // back, and the invalidation is app-scoped work that must not depend on the
  // widget that asked for the delete still being on screen.
  try {
    final media = container.read(mediaServiceProvider);
    for (final entry in deletion.mediaStamps.entries) {
      await media.restoreReferencesForOwner(
        FirestoreCollections.todoTasks,
        entry.key,
        entry.value,
      );
    }
  } finally {
    invalidateTodoTaskProvidersIn(container, {
      for (final row in rows) row.listId,
    });
  }
}

/// Re-fetches every provider a task write can change, for each list in
/// [listIds].
///
/// [allTodoTasksProvider] is an aggregate over the per-list family and reuses
/// its cache, so invalidating it alone re-runs its body against the *stale*
/// per-list values — the family member the write landed in has to go too.
void invalidateTodoTaskProvidersIn(
  ProviderContainer container,
  Set<String> listIds,
) {
  for (final listId in listIds) {
    container.invalidate(todoTasksProvider(listId));
  }
  container
    ..invalidate(allTodoTasksProvider)
    ..invalidate(todoListStatsProvider)
    ..invalidate(calendarTodoMarkersProvider);
}

/// Detaches every image hanging off [tasks], and reports the instant each
/// detach stamped.
///
/// Shared by the single-task delete above and the whole-list delete below so
/// that neither can be the one that forgets — an orphaned reference would
/// keep its asset off the retention clock forever, and the blob would never
/// be purged.
///
/// Each row's detach calls `utcNow()` for itself and
/// [MediaService.restoreReferencesForOwner] matches that stamp exactly, so
/// there is one instant to remember per row — the task's own `deletedAt` is a
/// different `utcNow()` and would match nothing.
Future<Map<String, DateTime>> detachMediaForTasks(
  ProviderContainer container,
  List<TodoTask> tasks,
) async {
  if (tasks.isEmpty) return const {};
  final media = container.read(mediaServiceProvider);
  final stamps = <String, DateTime>{};
  for (final task in tasks) {
    final stamp = await media.removeReferencesForOwner(
      FirestoreCollections.todoTasks,
      task.id,
    );
    if (stamp != null) stamps[task.id] = stamp;
  }
  return stamps;
}

/// Prompts for, and carries out, the deletion of [list].
///
/// Shared by the list dropdown's manage menu and the manage sheet, which used
/// to keep near-identical copies of this body and had already drifted apart
/// (the sheet's copy never cleared a stale `defaultTodoListId`).
///
/// [allLists] is only used to find — or fabricate — the built-in fallback list;
/// the task count driving the dialog and both branches is read from the
/// repository here rather than taken from the caller. A caller-supplied count
/// is not trustworthy for a destructive decision: the page sources it from a
/// `FutureProvider` it only `read`s, which reports zero for every non-selected
/// list while unresolved. A wrong zero skipped both branches and left every
/// task in the list with `deletedAt == null` pointing at a deleted list —
/// invisible in every view, absent from trash, and never purged.
Future<bool> deleteTodoList(
  BuildContext context,
  WidgetRef ref, {
  required TodoListModel list,
  required List<TodoListModel> allLists,
}) async {
  if (list.id == legacyTodoListId) return false;

  final repo = ref.read(todoRepositoryProvider);
  final remoteSync = ref.read(remoteSyncServiceProvider);
  // Resolved before the dialog, so the media detach below is not reaching
  // through a BuildContext across an async gap.
  final container = ProviderScope.containerOf(context, listen: false);
  final tasks = await repo.listTasks(list.id, topLevelOnly: false);
  final total = tasks.length;
  if (!context.mounted) return false;

  // Hoisted out of the async gap below: the orElse closure that fabricates a
  // replacement list used to read Theme.of(context) after the dialog awaited.
  final fallbackColor = Theme.of(context).colorScheme.primary.toARGB32();
  final choice = await showDeleteContainerDialog(
    context,
    title: 'Delete "${list.name}"?',
    message: total == 0
        ? 'This list has no tasks and will be removed.'
        : 'This list has $total tasks. Move them to the default "To-do" list, or delete everything.',
    deleteAllLabel: 'Yes (delete all tasks)',
  );
  if (!context.mounted || choice == DeleteContainerChoice.cancel) return false;

  // One instant for the list and the tasks it takes with it — see
  // [deleteJournalList].
  final deletedAt = utcNow();
  if (choice == DeleteContainerChoice.moveToDefault && tasks.isNotEmpty) {
    final fallback = allLists.firstWhere(
      (item) => item.id == legacyTodoListId,
      orElse: () {
        final now = utcNow();
        return TodoListModel(
          id: legacyTodoListId,
          name: 'To-do',
          colorValue: fallbackColor,
          createdAt: now,
          updatedAt: now,
        );
      },
    );
    if (!allLists.any((item) => item.id == legacyTodoListId)) {
      await repo.upsertList(fallback);
      remoteSync.pushTodoList(fallback);
    }
    await _moveTasksToDefaultList(repo, remoteSync, tasks);
  } else if (choice == DeleteContainerChoice.deleteAll && tasks.isNotEmpty) {
    // Push exactly the rows the repository wrote. Re-`copyWith`-ing the local
    // snapshots instead — which is what this used to do — sent the remote a
    // version the local row never reached, leaving the two permanently out of
    // step on every deleted task.
    final deleted = await repo.softDeleteTasksInList(list.id, at: deletedAt);
    await remoteSync.pushTodoTasksBatch(deleted);
    await detachMediaForTasks(container, deleted);
  }

  await repo.softDeleteList(list.id, at: deletedAt);
  // A deleted list can't stay the one the page opens into; leaving the id
  // behind would make the todo page fall back silently and look as if the
  // setting had been forgotten.
  final settingsRepo = ref.read(settingsRepositoryProvider);
  final settings = await settingsRepo.getSettings();
  if (settings.defaultTodoListId == list.id) {
    await ref
        .read(settingsProvider.notifier)
        .saveSettings(settings.copyWith(clearDefaultTodoListId: true));
  }
  final deletedList = (await repo.listLists(
    includeDeleted: true,
  )).firstWhere((item) => item.id == list.id);
  remoteSync.pushTodoList(deletedList);
  ref.invalidate(todoListsProvider);
  ref.invalidate(todoTasksProvider(list.id));
  if (choice == DeleteContainerChoice.moveToDefault && tasks.isNotEmpty) {
    ref.invalidate(todoTasksProvider(legacyTodoListId));
  }
  ref.invalidate(allTodoTasksProvider);
  ref.invalidate(todoListStatsProvider);
  return true;
}

/// Reassigns [tasks] to the built-in list, placing each one into that list's
/// ordering as it arrives.
///
/// A bare `UPDATE ... SET listId` is not enough: `sortOrder` is per-list and
/// every list restarts from the same bases, so the incoming tasks would land
/// carrying the source list's numbering and collide one-for-one with what is
/// already there, leaving `compareTodoTasks` to break every tie on `createdAt`.
Future<void> _moveTasksToDefaultList(
  TodoRepository repo,
  RemoteSyncService remoteSync,
  List<TodoTask> tasks,
) async {
  // Already-deleted rows stay where they are rather than being dragged into
  // the default list's trash.
  final live = tasks.where((task) => task.deletedAt == null).toList();
  if (live.isEmpty) return;

  var destActive = activeTopLevelTasks(await repo.listTasks(legacyTodoListId));
  final writes = <String, TodoTask>{};

  // Subtasks and completed tasks carry no placement of their own; they just
  // follow their list.
  for (final task in live) {
    final moved = task.copyWith(listId: legacyTodoListId);
    if (task.completed || task.isSubtask) {
      writes[moved.id] = moved;
      continue;
    }
    final batch = applyTaskListMove(moved, destActive);
    for (final row in batch.tasks) {
      writes[row.id] = row;
    }
    writes.putIfAbsent(moved.id, () => moved);
    destActive = {
      for (final t in destActive) t.id: t,
      for (final t in batch.tasks) t.id: t,
      moved.id: writes[moved.id]!,
    }.values.toList();
  }

  final rows = writes.values.toList();
  await repo.upsertTasksBatch(rows);
  await remoteSync.pushTodoTasksBatch(rows);
}

Future<TodoListModel?> createTodoList(
  BuildContext context,
  WidgetRef ref,
) async {
  final allLists = ref.read(todoListsProvider).valueOrNull ?? [];
  final palette = ref.read(colorPaletteProvider);
  final assigner = paletteFromItems(allLists.map((l) => l.colorValue), palette);
  final result = await showCreateNameColorDialog(
    context,
    title: 'New list',
    palette: palette,
    initialColor: assigner.nextColor(),
    usedColors: allLists
        .where((list) => list.colorValue != null)
        .map((list) => list.colorValue!)
        .toSet(),
  );
  if (result == null) return null;

  final now = utcNow();
  final list = TodoListModel(
    id: newId(),
    name: result.name,
    colorValue: result.color,
    createdAt: now,
    updatedAt: now,
  );
  await ref.read(todoRepositoryProvider).upsertList(list);
  ref.read(remoteSyncServiceProvider).pushTodoList(list);
  ref.invalidate(todoListsProvider);
  ref.invalidate(todoListStatsProvider);
  return list;
}
