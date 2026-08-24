import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/constants/todo_constants.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/confirm_dialog.dart';
import 'package:voyager/core/widgets/create_name_color_dialog.dart';
import 'package:voyager/core/widgets/palette_color_picker.dart';
import 'package:voyager/core/widgets/prompt_name_dialog.dart';
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

/// Soft-deletes [task] together with its subtasks.
///
/// Subtasks are separate rows joined by `parentTaskId`, and the only reader is
/// `listSubtasks()`, reached exclusively through the parent's edit panel. Left
/// behind, they keep `deletedAt == null` — so `purgeExpiredDeleted` never
/// removes them — are excluded from every list view (`listTasks` is
/// top-level-only by default), and keep syncing forever; if the parent is ever
/// restored or arrives fresh from a remote pull, they reappear with it.
Future<void> softDeleteTaskWithSubtasks(WidgetRef ref, TodoTask task) async {
  final repo = ref.read(todoRepositoryProvider);
  final remoteSync = ref.read(remoteSyncServiceProvider);
  final now = utcNow();
  final subtasks = await repo.listSubtasks(task.id);
  final rows = [
    task.copyWith(deletedAt: now),
    for (final subtask in subtasks)
      if (subtask.deletedAt == null) subtask.copyWith(deletedAt: now),
  ];
  await repo.upsertTasksBatch(rows);
  await remoteSync.pushTodoTasksBatch(rows);
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
    final deleted = await repo.softDeleteTasksInList(list.id);
    await remoteSync.pushTodoTasksBatch(deleted);
  }

  await repo.softDeleteList(list.id);
  // A deleted list can't stay the one the page opens into; leaving the id
  // behind would make the todo page fall back silently and look as if the
  // setting had been forgotten.
  final settingsRepo = ref.read(settingsRepositoryProvider);
  final settings = await settingsRepo.getSettings();
  if (settings.defaultTodoListId == list.id) {
    await settingsRepo.saveSettings(
      settings.copyWith(clearDefaultTodoListId: true),
    );
    ref.invalidate(settingsProvider);
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

  var destActive = activeTopLevelTasks(
    await repo.listTasks(legacyTodoListId),
  );
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
  final assigner = paletteFromItems(
    allLists.map((l) => l.colorValue),
    palette,
  );
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
