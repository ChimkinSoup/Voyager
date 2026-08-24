import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/create_name_color_dialog.dart';
import 'package:voyager/core/widgets/palette_color_picker.dart';
import 'package:voyager/core/widgets/prompt_name_dialog.dart';
import 'package:voyager/core/widgets/voyager_dialog.dart';
import 'package:voyager/core/widgets/voyager_menu_catalog.dart';
import 'package:voyager/core/constants/todo_constants.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/features/todo/todo_list_actions.dart';

Future<String?> showTodoListManageSheet(
  BuildContext context,
  WidgetRef ref,
) async {
  final createdId = await showVoyagerDialog<String?>(
    context: context,
    builder: (context) => const _TodoListManageDialog(),
  );
  ref.invalidate(todoListsProvider);
  ref.invalidate(todoTasksProvider);
  ref.invalidate(allTodoTasksProvider);
  return createdId;
}

class _TodoListManageDialog extends ConsumerStatefulWidget {
  const _TodoListManageDialog();

  @override
  ConsumerState<_TodoListManageDialog> createState() =>
      _TodoListManageDialogState();
}

class _TodoListManageDialogState extends ConsumerState<_TodoListManageDialog> {
  var _loading = true;
  List<TodoListModel> _lists = [];
  Map<String, ({int active, int completed})> _stats = {};
  String? _createdListId;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    final repo = ref.read(todoRepositoryProvider);
    final lists = await repo.listLists();
    final stats = <String, ({int active, int completed})>{};
    for (final list in lists) {
      final tasks = await repo.listTasks(list.id);
      stats[list.id] = (
        active: tasks.where((t) => !t.completed).length,
        completed: tasks.where((t) => t.completed).length,
      );
    }
    if (!mounted) return;
    setState(() {
      _lists = lists;
      _stats = stats;
      _loading = false;
    });
  }

  Future<void> _createList() async {
    final palette = ref.read(colorPaletteProvider);
    final assigner = paletteFromItems(_lists.map((l) => l.colorValue), palette);
    final initialColor = assigner.nextColor();
    final result = await showCreateNameColorDialog(
      context,
      title: 'New list',
      palette: palette,
      initialColor: initialColor,
      usedColors: _lists
          .where((list) => list.colorValue != null)
          .map((list) => list.colorValue!)
          .toSet(),
    );
    if (result == null) return;
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
    _createdListId = list.id;
    await _reload();
  }

  Future<void> _renameList(TodoListModel list) async {
    final name = await _promptName('Rename list', initial: list.name);
    if (name == null || name.trim().isEmpty || name.trim() == list.name) return;
    final updated = list.copyWith(name: name.trim());
    await ref.read(todoRepositoryProvider).upsertList(updated);
    ref.read(remoteSyncServiceProvider).pushTodoList(updated);
    await _reload();
  }

  Future<void> _pickColor(TodoListModel list) async {
    final color = await pickPaletteColorWithRef(
      ref,
      context,
      current: list.colorValue,
      usedColors: _lists
          .where((item) => item.id != list.id && item.colorValue != null)
          .map((item) => item.colorValue!)
          .toSet(),
    );
    if (color == null) return;
    final updated = list.copyWith(colorValue: color);
    await ref.read(todoRepositoryProvider).upsertList(updated);
    ref.read(remoteSyncServiceProvider).pushTodoList(updated);
    ref.invalidate(todoListsProvider);
    await _reload();
  }

  Future<void> _deleteList(TodoListModel list) async {
    // Shared with the todo page's list dropdown. This used to be a second copy
    // of that body and had already drifted — it never cleared a stale
    // defaultTodoListId, leaving the setting pointing at a deleted list.
    final deleted = await deleteTodoList(
      context,
      ref,
      list: list,
      allLists: _lists,
    );
    if (!deleted || !mounted) return;
    await _reload();
  }

  Future<String?> _promptName(String title, {String? initial}) {
    return showPromptNameDialog(context, title: title, initial: initial);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Manage lists'),
      content: SizedBox(
        width: 480,
        child: _loading
            ? const SizedBox(
                height: 120,
                child: Center(child: CircularProgressIndicator()),
              )
            : ListView.separated(
                shrinkWrap: true,
                itemCount: _lists.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final list = _lists[index];
                  final stat = _stats[list.id];
                  return ListTile(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    tileColor: Theme.of(context).colorScheme.surface,
                    leading: CircleAvatar(
                      backgroundColor: Color(list.colorValue ?? 0xFF7C9EFF),
                    ),
                    title: Text(list.name),
                    subtitle: Text(
                      '${stat?.active ?? 0} open · ${stat?.completed ?? 0} done',
                    ),
                    trailing: PopupMenuButton<VoyagerMenuCatalogEntry>(
                      onSelected: (action) async {
                        switch (action) {
                          case VoyagerMenuCatalogEntry.rename:
                            await _renameList(list);
                          case VoyagerMenuCatalogEntry.changeColor:
                            await _pickColor(list);
                          case VoyagerMenuCatalogEntry.delete:
                            await _deleteList(list);
                          default:
                            break;
                        }
                      },
                      itemBuilder: (context) => buildCatalogMenu(
                        context,
                        from: list.id == legacyTodoListId
                            ? entityManageMenuEntries.where(
                                (entry) =>
                                    entry != VoyagerMenuCatalogEntry.delete,
                              )
                            : entityManageMenuEntries,
                      ),
                    ),
                  );
                },
              ),
      ),
      actions: [
        GlassButton(
          dense: true,
          onPressed: () => Navigator.pop(context, _createdListId),
          label: 'Close',
        ),
        GlassButton(
          dense: true,
          onPressed: _createList,
          icon: const Icon(PhosphorIconsRegular.plus),
          label: 'New list',
        ),
      ],
    );
  }
}
