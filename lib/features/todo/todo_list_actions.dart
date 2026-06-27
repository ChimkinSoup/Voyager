import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/constants/todo_constants.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/confirm_dialog.dart';
import 'package:voyager/core/widgets/create_name_color_dialog.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/core/widgets/palette_color_picker.dart';
import 'package:voyager/domain/models/todo_models.dart';

Future<String?> promptTodoListName(
  BuildContext context,
  String title, {
  String? initial,
}) async {
  final controller = TextEditingController(text: initial ?? '');
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: LabeledTextField(
        label: title,
        controller: controller,
        autofocus: true,
        onSubmitted: (_) => Navigator.pop(context, controller.text),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text),
          child: const Text('OK'),
        ),
      ],
    ),
  );
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

Future<bool> deleteTodoList(
  BuildContext context,
  WidgetRef ref, {
  required TodoListModel list,
  required List<TodoListModel> allLists,
  required int activeCount,
  required int completedCount,
}) async {
  if (list.id == legacyTodoListId) return false;

  final total = activeCount + completedCount;
  final choice = await showDeleteContainerDialog(
    context,
    title: 'Delete "${list.name}"?',
    message: total == 0
        ? 'This list has no tasks and will be removed.'
        : 'This list has $total tasks. Move them to the default "To-do" list, or delete everything.',
    deleteAllLabel: 'Yes (delete all tasks)',
  );
  if (choice == DeleteContainerChoice.cancel) return false;

  final repo = ref.read(todoRepositoryProvider);
  final remoteSync = ref.read(remoteSyncServiceProvider);

  if (choice == DeleteContainerChoice.moveToDefault && total > 0) {
    final fallback = allLists.firstWhere(
      (item) => item.id == legacyTodoListId,
      orElse: () {
        final now = utcNow();
        return TodoListModel(
          id: legacyTodoListId,
          name: 'To-do',
          colorValue: Theme.of(context).colorScheme.primary.toARGB32(),
          createdAt: now,
          updatedAt: now,
        );
      },
    );
    if (!allLists.any((item) => item.id == legacyTodoListId)) {
      await repo.upsertList(fallback);
      remoteSync.pushTodoList(fallback);
    }
    final tasks = await repo.listTasks(list.id, topLevelOnly: false);
    await repo.reassignTasksList(list.id, legacyTodoListId);
    for (final task in tasks) {
      remoteSync.pushTodoTaskNow(task.copyWith(listId: legacyTodoListId));
    }
  } else if (choice == DeleteContainerChoice.deleteAll && total > 0) {
    final tasks = await repo.listTasks(list.id, topLevelOnly: false);
    await repo.softDeleteTasksInList(list.id);
    final now = utcNow();
    for (final task in tasks) {
      remoteSync.pushTodoTaskNow(task.copyWith(deletedAt: now));
    }
  }

  await repo.softDeleteList(list.id);
  final deleted =
      (await repo.listLists(includeDeleted: true))
          .firstWhere((item) => item.id == list.id);
  remoteSync.pushTodoList(deleted);
  ref.invalidate(todoListsProvider);
  ref.invalidate(todoTasksProvider(list.id));
  if (choice == DeleteContainerChoice.moveToDefault && total > 0) {
    ref.invalidate(todoTasksProvider(legacyTodoListId));
  }
  ref.invalidate(allTodoTasksProvider);
  ref.invalidate(todoListStatsProvider);
  return true;
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
