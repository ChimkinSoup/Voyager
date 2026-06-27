import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/constants/todo_constants.dart';
import 'package:voyager/core/constants/todo_sort_constants.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/utils/time_format.dart';
import 'package:voyager/core/widgets/journal_color_flag.dart';
import 'package:voyager/core/widgets/keep_alive_scroll.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/core/widgets/rounded_dropdown.dart';
import 'package:voyager/core/widgets/voyager_menu_catalog.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/features/shell/shell_page_storage_keys.dart';
import 'package:voyager/features/todo/todo_edit_panel.dart';
import 'package:voyager/features/todo/todo_list_actions.dart';
import 'package:voyager/features/todo/todo_manage_sheet.dart';

const _todoEditPanelWidth = 420.0;
const _todoEditPanelDuration = Duration(milliseconds: 270);

class TodoPage extends ConsumerStatefulWidget {
  const TodoPage({super.key});

  @override
  ConsumerState<TodoPage> createState() => _TodoPageState();
}

class _TodoPageState extends ConsumerState<TodoPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _panelController;
  late final CurvedAnimation _panelAnimation;
  String? _selectedListId;
  String? _selectedTaskId;
  TodoTask? _editPanelTask;
  final _taskController = TextEditingController();
  final _taskFocusNode = FocusNode();
  List<String>? _optimisticActiveTaskOrder;
  final _completionOverrides = <String, bool>{};
  final _taskOverrides = <String, TodoTask>{};
  var _completedExpanded = true;
  var _showAllTasks = false;

  @override
  void initState() {
    super.initState();
    _panelController = AnimationController(
      vsync: this,
      duration: _todoEditPanelDuration,
    );
    _panelAnimation = CurvedAnimation(
      parent: _panelController,
      curve: Curves.easeOutCubic,
    );
    _panelController.addStatusListener((status) {
      if (status == AnimationStatus.dismissed && mounted) {
        setState(() {
          _editPanelTask = null;
          _selectedTaskId = null;
        });
      }
    });
    final savedId =
        ref.read(settingsProvider).valueOrNull?.lastViewedTodoListId;
    if (savedId != null) {
      _selectedListId = savedId;
    }
  }

  Future<void> _persistLastViewedList(String listId) async {
    final settingsRepo = ref.read(settingsRepositoryProvider);
    final settings = await settingsRepo.getSettings();
    if (settings.lastViewedTodoListId == listId) return;
    await settingsRepo.saveSettings(
      settings.copyWith(lastViewedTodoListId: listId),
    );
  }

  void _markListViewed(String listId) {
    unawaited(_persistLastViewedList(listId));
  }

  TodoTask? _panelTaskFor(List<TodoTask> sorted) {
    final panelTask = _editPanelTask;
    if (panelTask == null) return null;
    return sorted.cast<TodoTask?>().firstWhere(
      (task) => task!.id == panelTask.id,
      orElse: () => panelTask,
    );
  }

  void _openEditPanel(TodoTask task) {
    setState(() {
      _editPanelTask = task;
      _selectedTaskId = task.id;
    });
    _panelController.forward();
  }

  void _closeEditPanel() {
    _panelController.reverse();
  }

  String _resolveListId(List<TodoListModel> lists, AppSettings? settings) {
    if (_selectedListId != null &&
        lists.any((list) => list.id == _selectedListId)) {
      return _selectedListId!;
    }
    final savedId = settings?.lastViewedTodoListId;
    if (savedId != null && lists.any((list) => list.id == savedId)) {
      return savedId;
    }
    return lists
        .cast<TodoListModel?>()
        .firstWhere(
          (l) => l!.id == legacyTodoListId,
          orElse: () => lists.first,
        )!
        .id;
  }

  @override
  void dispose() {
    _panelAnimation.dispose();
    _panelController.dispose();
    _taskController.dispose();
    _taskFocusNode.dispose();
    super.dispose();
  }

  Future<void> _ensureDefaultList() async {
    final repo = ref.read(todoRepositoryProvider);
    var lists = await repo.listLists();
    if (!lists.any((list) => list.id == legacyTodoListId)) {
      final now = utcNow();
      final list = TodoListModel(
        id: legacyTodoListId,
        name: 'To-do',
        createdAt: now,
        updatedAt: now,
      );
      await repo.upsertList(list);
      ref.read(remoteSyncServiceProvider).pushTodoList(list);
      lists = await repo.listLists();
    }
    _selectedListId ??= lists
        .cast<TodoListModel?>()
        .firstWhere(
          (l) => l!.id == legacyTodoListId,
          orElse: () => lists.isNotEmpty ? lists.first : null,
        )
        ?.id;
  }

  Future<void> _addTask() async {
    if (_taskController.text.trim().isEmpty) return;
    await _ensureDefaultList();
    final repo = ref.read(todoRepositoryProvider);
    final now = utcNow();
    final sortOrder = await repo.nextSortOrder(_selectedListId!);
    final task = TodoTask(
      id: newId(),
      listId: _selectedListId!,
      title: _taskController.text.trim(),
      sortOrder: sortOrder,
      createdAt: now,
      updatedAt: now,
    );
    await repo.upsertTask(task);
    ref.read(remoteSyncServiceProvider).pushTodoTaskNow(task);
    _taskController.clear();
    _taskFocusNode.requestFocus();
    ref.invalidate(todoTasksProvider(task.listId));
    _invalidateTodoListData();
  }

  Future<void> _toggleTask(TodoTask task, bool? completed) async {
    final value = completed ?? false;
    setState(() {
      _completionOverrides[task.id] = value;
      if (value) {
        _optimisticActiveTaskOrder?.remove(task.id);
        if (_optimisticActiveTaskOrder?.isEmpty ?? false) {
          _optimisticActiveTaskOrder = null;
        }
      }
    });
    unawaited(_persistTaskCompletion(task.copyWith(completed: value)));
  }

  Future<void> _persistTaskCompletion(TodoTask updated) async {
    await ref.read(todoRepositoryProvider).upsertTask(updated);
    if (!mounted) return;
    ref.invalidate(todoTasksProvider(updated.listId));
    _invalidateTodoListData();
    ref.read(remoteSyncServiceProvider).pushTodoTaskNow(updated);
  }

  List<TodoTask> _tasksWithOverrides(List<TodoTask> tasks) {
    if (_completionOverrides.isEmpty && _taskOverrides.isEmpty) return tasks;
    return [
      for (final task in tasks)
        _taskOverrides[task.id] ??
            switch (_completionOverrides[task.id]) {
              null => task,
              final completed => task.copyWith(completed: completed),
            },
    ];
  }

  void _reconcileTaskOverrides(List<TodoTask> tasks) {
    if (_taskOverrides.isEmpty) return;
    final resolvedIds = <String>[
      for (final task in tasks)
        if (_taskOverrides.containsKey(task.id) &&
            _taskOverrideMatches(task, _taskOverrides[task.id]!))
          task.id,
    ];
    if (resolvedIds.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        for (final id in resolvedIds) {
          _taskOverrides.remove(id);
        }
      });
    });
  }

  void _reconcileCompletionOverrides(List<TodoTask> tasks) {
    if (_completionOverrides.isEmpty) return;
    final resolvedIds = <String>[
      for (final task in tasks)
        if (_completionOverrides[task.id] == task.completed) task.id,
    ];
    if (resolvedIds.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        for (final id in resolvedIds) {
          _completionOverrides.remove(id);
        }
      });
    });
  }

  bool _taskOverrideMatches(TodoTask persisted, TodoTask override) {
    return persisted.title == override.title &&
        persisted.notes == override.notes &&
        persisted.dueDate == override.dueDate &&
        persisted.completed == override.completed &&
        persisted.starred == override.starred &&
        persisted.sortOrder == override.sortOrder &&
        persisted.preStarSortOrder == override.preStarSortOrder &&
        persisted.listId == override.listId;
  }

  Future<void> _toggleStar(TodoTask task, List<TodoTask> activeTasks) async {
    final starring = !task.starred;
    final TodoTask updated;
    if (starring) {
      final orders = activeTasks
          .where((t) => t.starred && t.id != task.id)
          .map((t) => _taskOverrides[t.id]?.sortOrder ?? t.sortOrder);
      final minOrder = orders.isEmpty
          ? (activeTasks.isEmpty
                ? task.sortOrder - 1
                : activeTasks
                      .map((t) => _taskOverrides[t.id]?.sortOrder ?? t.sortOrder)
                      .reduce(math.min))
          : orders.reduce(math.min);
      updated = task.copyWith(
        starred: true,
        sortOrder: minOrder - 1,
        preStarSortOrder: normalizeUnstarredSortOrder(task.sortOrder),
      );
    } else {
      updated = task.copyWith(
        starred: false,
        sortOrder: normalizeUnstarredSortOrder(
          task.preStarSortOrder ?? task.sortOrder,
        ),
        clearPreStarSortOrder: true,
      );
    }

    setState(() {
      _taskOverrides[task.id] = updated;
      if (starring) {
        _optimisticActiveTaskOrder = [
          task.id,
          ...activeTasks
              .where((t) => t.id != task.id)
              .map((t) => t.id),
        ];
      } else {
        _optimisticActiveTaskOrder = null;
      }
    });

    unawaited(_persistTaskUpdate(updated));
  }

  Future<void> _persistTaskUpdate(TodoTask updated) async {
    await ref.read(todoRepositoryProvider).upsertTask(updated);
    if (!mounted) return;
    ref.invalidate(todoTasksProvider(updated.listId));
    _invalidateTodoListData();
    ref.read(remoteSyncServiceProvider).pushTodoTaskNow(updated);
  }

  Future<({int completed, int total})> _subtaskStats(String taskId) async {
    final subtasks = await ref
        .read(todoRepositoryProvider)
        .listSubtasks(taskId);
    return (
      completed: subtasks.where((s) => s.completed).length,
      total: subtasks.length,
    );
  }

  void _invalidateTodoListData({String? listId}) {
    if (listId != null) {
      ref.invalidate(todoTasksProvider(listId));
    }
    ref.invalidate(allTodoTasksProvider);
    ref.invalidate(todoListsProvider);
    ref.invalidate(todoListStatsProvider);
  }

  int? _listColorFor(String listId, List<TodoListModel> lists) {
    for (final list in lists) {
      if (list.id == listId) return list.colorValue;
    }
    return null;
  }

  List<TodoTask> _activeInList(List<TodoTask> active, String listId) {
    return active.where((task) => task.listId == listId).toList();
  }

  ({int active, int completed}) _statsForList(
    String listId,
    Map<String, ({int active, int completed})>? stats, {
    required int activeCount,
    required int completedCount,
  }) {
    if (!_showAllTasks && listId == _selectedListId) {
      return (active: activeCount, completed: completedCount);
    }
    return stats?[listId] ?? (active: 0, completed: 0);
  }

  Future<void> _handleListManage(
    String listId,
    VoyagerMenuCatalogEntry action,
    List<TodoListModel> allLists,
    ({int active, int completed}) stat,
  ) async {
    final list = allLists.firstWhere((l) => l.id == listId);
    switch (action) {
      case VoyagerMenuCatalogEntry.rename:
        await renameTodoList(context, ref, list);
      case VoyagerMenuCatalogEntry.changeColor:
        await changeTodoListColor(context, ref, list, allLists);
      case VoyagerMenuCatalogEntry.delete:
        final deleted = await deleteTodoList(
          context,
          ref,
          list: list,
          allLists: allLists,
          activeCount: stat.active,
          completedCount: stat.completed,
        );
        if (deleted && mounted) {
          final updatedLists =
              ref.read(todoListsProvider).valueOrNull ?? allLists;
          setState(() {
            _selectedListId = updatedLists
                .cast<TodoListModel?>()
                .firstWhere(
                  (l) => l!.id == legacyTodoListId,
                  orElse: () => updatedLists.isNotEmpty
                      ? updatedLists.first
                      : null,
                )
                ?.id;
            _optimisticActiveTaskOrder = null;
          });
          _closeEditPanel();
        }
      default:
        break;
    }
  }

  TodoListModel? _selectedList(List<TodoListModel> lists) {
    if (_selectedListId == null) return lists.isNotEmpty ? lists.first : null;
    return lists.cast<TodoListModel?>().firstWhere(
      (l) => l!.id == _selectedListId,
      orElse: () => lists.isNotEmpty ? lists.first : null,
    );
  }

  Future<void> _reorderActiveTasks(
    List<TodoTask> active,
    int oldIndex,
    int newIndex,
  ) async {
    final items = List<TodoTask>.from(active);
    final moved = items.removeAt(oldIndex);
    items.insert(newIndex, moved);
    setState(() {
      _optimisticActiveTaskOrder = items.map((task) => task.id).toList();
    });
    final repo = ref.read(todoRepositoryProvider);
    final remoteSync = ref.read(remoteSyncServiceProvider);
    var starredIndex = 0;
    var unstarredIndex = unstarredSortOrderBase;
    for (var i = 0; i < items.length; i++) {
      final newOrder =
          items[i].starred ? starredIndex++ : unstarredIndex++;
      if (items[i].sortOrder == newOrder) continue;
      final updated = items[i].copyWith(sortOrder: newOrder);
      await repo.upsertTask(updated);
      remoteSync.pushTodoTaskNow(updated);
    }
    ref.invalidate(todoTasksProvider(_selectedListId!));
    _invalidateTodoListData();
  }

  List<TodoTask> _applyOptimisticActiveOrder(List<TodoTask> active) {
    final order = _optimisticActiveTaskOrder;
    if (order == null || order.length != active.length) return active;
    final byId = {for (final task in active) task.id: task};
    if (!order.every(byId.containsKey)) return active;
    return [for (final id in order) byId[id]!];
  }

  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(settingsProvider);
    final settings = settingsAsync.valueOrNull;
    final hideCompleted = settingsAsync.maybeWhen(
      data: (settings) => settings.hideCompletedTasks,
      orElse: () => false,
    );
    final effectiveHideCompleted = hideCompleted && !_showAllTasks;
    final listsAsync = ref.watch(todoListsProvider);
    final statsAsync = ref.watch(todoListStatsProvider);

    return listsAsync.when(
      skipLoadingOnReload: true,
      data: (lists) {
        if (lists.isEmpty) {
          return Center(
            child: FilledButton(
              onPressed: () => showTodoListManageSheet(context, ref),
              child: const Text('Create your first list'),
            ),
          );
        }
        final listId = _resolveListId(lists, settings);
        if (_selectedListId != listId) {
          _selectedListId = listId;
        }
        final currentList = _selectedList(lists);
        final stats = statsAsync.valueOrNull;

        final tasksAsync = _showAllTasks
            ? ref.watch(allTodoTasksProvider)
            : ref.watch(todoTasksProvider(listId));
        return tasksAsync.when(
          skipLoadingOnReload: true,
          data: (tasks) {
            _reconcileCompletionOverrides(tasks);
            _reconcileTaskOverrides(tasks);
            final sorted = sortTodoTasks(_tasksWithOverrides(tasks));
            final active = _applyOptimisticActiveOrder(
              sorted.where((t) => !t.completed).toList(),
            );
            final completed = sorted.where((t) => t.completed).toList();
            final selectedTask = _selectedTaskId == null
                ? null
                : sorted.cast<TodoTask?>().firstWhere(
                    (t) => t!.id == _selectedTaskId,
                    orElse: () => null,
                  );


            final panelTask = _panelTaskFor(sorted);

            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: RoundedDropdown<String>(
                                value: listId,
                                displayLabel:
                                    _showAllTasks ? 'All tasks' : null,
                                labelColor: _showAllTasks
                                    ? Theme.of(context).colorScheme.primary
                                    : currentList?.colorValue == null
                                        ? null
                                        : Color(currentList!.colorValue!),
                                manageMenuEntriesFor: (listId) =>
                                    listId == legacyTodoListId
                                        ? defaultEntityManageMenuEntries
                                        : entityManageMenuEntries,
                                onManage: (listId, action) {
                                  final stat = _statsForList(
                                    listId,
                                    stats,
                                    activeCount: active.length,
                                    completedCount: completed.length,
                                  );
                                  return _handleListManage(
                                    listId,
                                    action,
                                    lists,
                                    stat,
                                  );
                                },
                                items: lists
                                    .map(
                                      (l) => RoundedDropdownItem(
                                        value: l.id,
                                        label: l.name,
                                        leading: JournalBookmarkFlag(
                                          colorValue: l.colorValue ??
                                              Theme.of(context)
                                                  .colorScheme
                                                  .primary
                                                  .toARGB32(),
                                          size: 12,
                                        ),
                                      ),
                                    )
                                    .toList(),
                                onChanged: (v) {
                                  setState(() => _selectedListId = v);
                                  _closeEditPanel();
                                  _markListViewed(v);
                                },
                              ),
                            ),
                            const SizedBox(width: 8),
                            IconButton(
                              tooltip: _showAllTasks
                                  ? 'Show selected list only'
                                  : 'Show all tasks',
                              onPressed: () {
                                if (_showAllTasks) {
                                  final listId = selectedTask?.listId;
                                  setState(() {
                                    if (listId != null &&
                                        lists.any((l) => l.id == listId)) {
                                      _selectedListId = listId;
                                    }
                                    _showAllTasks = false;
                                  });
                                  if (listId != null) {
                                    _markListViewed(listId);
                                  }
                                } else {
                                  setState(() => _showAllTasks = true);
                                }
                              },
                              icon: Icon(
                                PhosphorIconsRegular.listMagnifyingGlass,
                                color: _showAllTasks ? Colors.black : null,
                              ),
                              style: IconButton.styleFrom(
                                backgroundColor: _showAllTasks
                                    ? Theme.of(context).colorScheme.primary
                                    : null,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Expanded(
                          child: KeepAliveSingleChildScrollView(
                            storageKey: ShellPageStorageKeys.todoTaskList,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                if (active.isNotEmpty)
                                  if (_showAllTasks)
                                    ...active.map(
                                      (task) => _TaskRow(
                                        key: ValueKey(task.id),
                                        task: task,
                                        listColor: _listColorFor(
                                          task.listId,
                                          lists,
                                        ),
                                        subtaskStats: _subtaskStats(task.id),
                                        onToggle: (v) => _toggleTask(task, v),
                                        onStar: () => _toggleStar(
                                          task,
                                          _activeInList(active, task.listId),
                                        ),
                                        onEdit: () => _openEditPanel(task),
                                      ),
                                    )
                                  else
                                    ReorderableListView(
                                      shrinkWrap: true,
                                      physics:
                                          const NeverScrollableScrollPhysics(),
                                      buildDefaultDragHandles: false,
                                      onReorderItem: (oldIndex, newIndex) =>
                                          _reorderActiveTasks(
                                            active,
                                            oldIndex,
                                            newIndex,
                                          ),
                                      children: [
                                        for (var i = 0; i < active.length; i++)
                                          ReorderableDragStartListener(
                                            key: ValueKey(active[i].id),
                                            index: i,
                                            child: _TaskRow(
                                              task: active[i],
                                              listColor:
                                                  currentList?.colorValue,
                                              subtaskStats: _subtaskStats(
                                                active[i].id,
                                              ),
                                              onToggle: (v) => _toggleTask(
                                                active[i],
                                                v,
                                              ),
                                              onStar: () => _toggleStar(
                                                active[i],
                                                active,
                                              ),
                                              onEdit: () => _openEditPanel(active[i]),
                                            ),
                                          ),
                                      ],
                                    ),
                                if (!effectiveHideCompleted &&
                                    completed.isNotEmpty) ...[
                                  const Divider(height: 32),
                                  InkWell(
                                    onTap: () => setState(
                                      () => _completedExpanded =
                                          !_completedExpanded,
                                    ),
                                    borderRadius: BorderRadius.circular(14),
                                    child: Padding(
                                      padding: const EdgeInsets.fromLTRB(
                                        12,
                                        8,
                                        8,
                                        8,
                                      ),
                                      child: Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              'Completed (${completed.length})',
                                              style: Theme.of(
                                                context,
                                              ).textTheme.titleSmall,
                                            ),
                                          ),
                                          Icon(
                                            _completedExpanded
                                                ? PhosphorIconsRegular.caretUp
                                                : PhosphorIconsRegular
                                                      .caretDown,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  if (_completedExpanded)
                                    ...completed.map(
                                      (task) => _TaskRow(
                                        key: ValueKey(task.id),
                                        task: task,
                                        listColor: _listColorFor(
                                          task.listId,
                                          lists,
                                        ),
                                        subtaskStats: _subtaskStats(task.id),
                                        onToggle: (v) => _toggleTask(task, v),
                                        onStar: () => _toggleStar(
                                          task,
                                          _activeInList(active, task.listId),
                                        ),
                                        onEdit: () => _openEditPanel(task),
                                      ),
                                    ),
                                ],
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Expanded(
                              child: LabeledTextField(
                                label: '',
                                showLabel: false,
                                controller: _taskController,
                                focusNode: _taskFocusNode,
                                onSubmitted: (_) => _addTask(),
                              ),
                            ),
                            const SizedBox(width: 8),
                            SizedBox(
                              height: 48,
                              child: FilledButton(
                                onPressed: _addTask,
                                style: FilledButton.styleFrom(
                                  backgroundColor: currentList?.colorValue ==
                                          null
                                      ? null
                                      : Color(currentList!.colorValue!),
                                  foregroundColor: currentList?.colorValue ==
                                          null
                                      ? null
                                      : Colors.white,
                                ),
                                child: const Text('Add'),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                ClipRect(
                  child: AnimatedBuilder(
                    animation: _panelAnimation,
                    builder: (context, child) {
                      return Align(
                        alignment: Alignment.centerRight,
                        widthFactor: _panelAnimation.value,
                        child: child,
                      );
                    },
                    child: SizedBox(
                      width: _todoEditPanelWidth,
                      child: panelTask == null
                          ? const SizedBox.shrink()
                          : TodoEditPanel(
                              key: ValueKey(panelTask.id),
                              task: panelTask,
                              listColor: _listColorFor(panelTask.listId, lists),
                              lists: lists,
                              onClose: () {
                                _invalidateTodoListData(
                                  listId: panelTask.listId,
                                );
                                _closeEditPanel();
                              },
                              onChanged: () {
                                _invalidateTodoListData(
                                  listId: panelTask.listId,
                                );
                              },
                              onDeleted: () {
                                _invalidateTodoListData(
                                  listId: panelTask.listId,
                                );
                                _closeEditPanel();
                              },
                              onToggleStar: () => _toggleStar(
                                panelTask,
                                sorted.where((t) => !t.completed).toList(),
                              ),
                              onTaskOptimistic: (task) {
                                _taskOverrides[task.id] = task;
                                final affectsSort =
                                    task.dueDate != panelTask.dueDate ||
                                    task.starred != panelTask.starred ||
                                    task.sortOrder != panelTask.sortOrder ||
                                    task.listId != panelTask.listId;
                                if (affectsSort ||
                                    task.listId != _selectedListId) {
                                  final movedList =
                                      task.listId != _selectedListId;
                                  setState(() {
                                    _editPanelTask = task;
                                    if (movedList) {
                                      _selectedListId = task.listId;
                                      _selectedTaskId = task.id;
                                    }
                                  });
                                  if (movedList) {
                                    _markListViewed(task.listId);
                                  }
                                }
                              },
                            ),
                    ),
                  ),
                ),
              ],
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('$e')),
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('$e')),
    );
  }
}

class _TaskRow extends StatefulWidget {
  const _TaskRow({
    super.key,
    required this.task,
    required this.onToggle,
    required this.onStar,
    required this.onEdit,
    required this.subtaskStats,
    this.listColor,
  });

  final TodoTask task;
  final Future<void> Function(bool?) onToggle;
  final VoidCallback onStar;
  final VoidCallback onEdit;
  final Future<({int completed, int total})> subtaskStats;
  final int? listColor;

  @override
  State<_TaskRow> createState() => _TaskRowState();
}

class _TaskRowState extends State<_TaskRow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animController;
  late final Animation<double> _checkScale;
  late final Animation<double> _strikeProgress;
  var _displayCompleted = false;
  var _animatingComplete = false;

  @override
  void initState() {
    super.initState();
    _displayCompleted = widget.task.completed;
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _checkScale =
        TweenSequence<double>([
          TweenSequenceItem(
            tween: Tween(
              begin: 1.0,
              end: 1.25,
            ).chain(CurveTween(curve: Curves.easeOut)),
            weight: 45,
          ),
          TweenSequenceItem(
            tween: Tween(
              begin: 1.25,
              end: 1.0,
            ).chain(CurveTween(curve: Curves.easeOutBack)),
            weight: 55,
          ),
        ]).animate(
          CurvedAnimation(
            parent: _animController,
            curve: const Interval(0, 0.55, curve: Curves.linear),
          ),
        );
    _strikeProgress = CurvedAnimation(
      parent: _animController,
      curve: const Interval(0.2, 1.0, curve: Curves.easeOut),
    );
    if (widget.task.completed) {
      _animController.value = 1.0;
    }
  }

  @override
  void didUpdateWidget(covariant _TaskRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_animatingComplete) return;
    if (oldWidget.task.completed != widget.task.completed) {
      if (widget.task.completed) {
        _displayCompleted = true;
        _animController.value = 1.0;
      } else {
        _displayCompleted = false;
        _animController.reset();
      }
    }
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  Future<void> _handleToggle(bool? value) async {
    if (_animatingComplete) return;
    if (value == true && !widget.task.completed) {
      setState(() {
        _animatingComplete = true;
        _displayCompleted = true;
      });
      await _animController.forward(from: 0);
      if (!mounted) return;
      unawaited(widget.onToggle(true));
      setState(() => _animatingComplete = false);
    } else if (value == false && widget.task.completed) {
      setState(() => _animatingComplete = true);
      await _animController.reverse(from: 1.0);
      if (!mounted) return;
      setState(() => _displayCompleted = false);
      unawaited(widget.onToggle(false));
      setState(() => _animatingComplete = false);
    }
  }

  String? _formatDue(DateTime? dueDate) {
    if (dueDate == null) return null;
    final local = dueDate.toLocal();
    return '${DateFormat.MMMd().format(local)} · ${formatTime12Hour(dueDate)}';
  }

  List<Widget> _metadataWidgets(
    String? dueLabel,
    ({int completed, int total})? stats,
    bool hasNotes,
    Color? metadataColor,
  ) {
    final widgets = <Widget>[];
    if (dueLabel != null) {
      widgets.add(Text(dueLabel));
    }
    if (stats != null && stats.total > 0) {
      if (widgets.isNotEmpty) widgets.add(const Text(' · '));
      widgets.add(Text('${stats.completed} : ${stats.total}'));
    }
    if (hasNotes) {
      if (widgets.isNotEmpty) widgets.add(const Text(' · '));
      widgets.add(
        Icon(
          PhosphorIconsRegular.note,
          size: 10,
          color: metadataColor,
        ),
      );
    }
    return widgets;
  }

  @override
  Widget build(BuildContext context) {
    final dueLabel = _formatDue(widget.task.dueDate);
    final listColor = widget.listColor == null
        ? null
        : Color(widget.listColor!);
    final strikeColor = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: 0.55);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          ScaleTransition(
            scale: _checkScale,
            child: Checkbox(
              value: _displayCompleted,
              onChanged: _handleToggle,
              activeColor: listColor,
            ),
          ),
          Expanded(
            child: InkWell(
              onTap: widget.onEdit,
              borderRadius: BorderRadius.circular(14),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  vertical: 10,
                  horizontal: 12,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        AnimatedDefaultTextStyle(
                          duration: const Duration(milliseconds: 180),
                          curve: Curves.easeOut,
                          style: Theme.of(context).textTheme.bodyLarge!
                              .copyWith(
                                color: _displayCompleted ? strikeColor : null,
                              ),
                          child: Text(
                            widget.task.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (_displayCompleted)
                          Positioned.fill(
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: AnimatedBuilder(
                                animation: _strikeProgress,
                                builder: (context, _) {
                                  return FractionallySizedBox(
                                    widthFactor: _strikeProgress.value.clamp(
                                      0.0,
                                      1.0,
                                    ),
                                    alignment: Alignment.centerLeft,
                                    child: Container(
                                      height: 1.5,
                                      color: strikeColor,
                                    ),
                                  );
                                },
                              ),
                            ),
                          ),
                      ],
                    ),
                    FutureBuilder(
                      future: widget.subtaskStats,
                      builder: (context, snapshot) {
                        final metadataColor = Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withValues(alpha: 0.72);
                        final metadata = _metadataWidgets(
                          dueLabel,
                          snapshot.data,
                          widget.task.notes?.trim().isNotEmpty == true,
                          metadataColor,
                        );
                        if (metadata.isEmpty) return const SizedBox.shrink();
                        return Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: DefaultTextStyle(
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(
                                  fontSize: 10,
                                  color: metadataColor,
                                ) ??
                                TextStyle(fontSize: 10, color: metadataColor),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: metadata,
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            onPressed: widget.onStar,
            icon: Icon(
              widget.task.starred
                  ? PhosphorIconsFill.star
                  : PhosphorIconsRegular.star,
            ),
            color: widget.task.starred
                ? listColor ?? Theme.of(context).colorScheme.primary
                : null,
          ),
        ],
      ),
    );
  }
}
