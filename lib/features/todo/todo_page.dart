import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/icons/voyager_icons.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/utils/time_format.dart';
import 'package:voyager/core/widgets/journal_color_flag.dart';
import 'package:voyager/core/widgets/keep_alive_scroll.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/core/widgets/rounded_dropdown.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/features/shell/shell_page_storage_keys.dart';
import 'package:voyager/features/todo/todo_edit_panel.dart';
import 'package:voyager/features/todo/todo_manage_sheet.dart';

class TodoPage extends ConsumerStatefulWidget {
  const TodoPage({super.key});

  @override
  ConsumerState<TodoPage> createState() => _TodoPageState();
}

class _TodoPageState extends ConsumerState<TodoPage> {
  String? _selectedListId;
  String? _selectedTaskId;
  final _taskController = TextEditingController();
  final _taskFocusNode = FocusNode();
  var _completedExpanded = true;

  @override
  void dispose() {
    _taskController.dispose();
    _taskFocusNode.dispose();
    super.dispose();
  }

  Future<void> _ensureDefaultList() async {
    final repo = ref.read(todoRepositoryProvider);
    final lists = await repo.listLists();
    if (lists.isEmpty) {
      final now = utcNow();
      final list = TodoListModel(
        id: newId(),
        name: 'Inbox',
        createdAt: now,
        updatedAt: now,
      );
      await repo.upsertList(list);
      ref.read(remoteSyncServiceProvider).pushTodoList(list);
      _selectedListId = list.id;
    } else {
      _selectedListId ??= lists.first.id;
    }
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
    ref.invalidate(todoListsProvider);
  }

  Future<void> _toggleTask(TodoTask task, bool? completed) async {
    final updated = task.copyWith(completed: completed ?? false);
    await ref.read(todoRepositoryProvider).upsertTask(updated);
    ref.read(remoteSyncServiceProvider).pushTodoTaskNow(updated);
    ref.invalidate(todoTasksProvider(updated.listId));
    ref.invalidate(todoListsProvider);
  }

  Future<void> _toggleStar(TodoTask task) async {
    final repo = ref.read(todoRepositoryProvider);
    final remoteSync = ref.read(remoteSyncServiceProvider);
    if (task.starred) {
      final updated = task.copyWith(
        starred: false,
        sortOrder: task.preStarSortOrder ?? task.sortOrder,
        clearPreStarSortOrder: true,
      );
      await repo.upsertTask(updated);
      remoteSync.pushTodoTaskNow(updated);
      ref.invalidate(todoTasksProvider(updated.listId));
    } else {
      final updated = task.copyWith(
        starred: true,
        preStarSortOrder: task.sortOrder,
      );
      await repo.upsertTask(updated);
      remoteSync.pushTodoTaskNow(updated);
      ref.invalidate(todoTasksProvider(updated.listId));
    }
    ref.invalidate(todoListsProvider);
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
    final repo = ref.read(todoRepositoryProvider);
    final remoteSync = ref.read(remoteSyncServiceProvider);
    for (var i = 0; i < items.length; i++) {
      if (items[i].sortOrder == i) continue;
      final updated = items[i].copyWith(sortOrder: i);
      await repo.upsertTask(updated);
      remoteSync.pushTodoTaskNow(updated);
    }
    ref.invalidate(todoTasksProvider(_selectedListId!));
  }

  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(settingsProvider);
    final hideCompleted = settingsAsync.maybeWhen(
      data: (settings) => settings.hideCompletedTasks,
      orElse: () => false,
    );
    final listsAsync = ref.watch(todoListsProvider);

    return listsAsync.when(
      data: (lists) {
        if (lists.isEmpty) {
          return Center(
            child: FilledButton(
              onPressed: () => showTodoListManageSheet(context, ref),
              child: const Text('Create your first list'),
            ),
          );
        }
        _selectedListId ??= lists.first.id;
        final currentList = _selectedList(lists);

        final tasksAsync = ref.watch(todoTasksProvider(_selectedListId!));
        return tasksAsync.when(
          data: (tasks) {
            final sorted = sortTodoTasks(tasks);
            final active = sorted.where((t) => !t.completed).toList();
            final completed = sorted.where((t) => t.completed).toList();
            final selectedTask = _selectedTaskId == null
                ? null
                : sorted.cast<TodoTask?>().firstWhere(
                    (t) => t!.id == _selectedTaskId,
                    orElse: () => null,
                  );

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
                            if (currentList?.colorValue != null) ...[
                              ColorCornerFlag(
                                colorValue: currentList!.colorValue!,
                                size: 16,
                              ),
                              const SizedBox(width: 8),
                            ],
                            Expanded(
                              child: RoundedDropdown<String>(
                                value: _selectedListId!,
                                items: lists
                                    .map(
                                      (l) => RoundedDropdownItem(
                                        value: l.id,
                                        label: l.name,
                                      ),
                                    )
                                    .toList(),
                                onChanged: (v) => setState(() {
                                  _selectedListId = v;
                                  _selectedTaskId = null;
                                }),
                              ),
                            ),
                            const SizedBox(width: 8),
                            IconButton(
                              onPressed: () async {
                                final createdId = await showTodoListManageSheet(
                                  context,
                                  ref,
                                );
                                if (createdId != null) {
                                  setState(() => _selectedListId = createdId);
                                }
                              },
                              icon: const Icon(
                                VoyagerIcons.manage,
                              ),
                              tooltip: 'Manage lists',
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
                                  ReorderableListView(
                                    shrinkWrap: true,
                                    physics: const NeverScrollableScrollPhysics(),
                                    buildDefaultDragHandles: false,
                                    onReorderItem: (oldIndex, newIndex) =>
                                        _reorderActiveTasks(
                                          active,
                                          oldIndex,
                                          newIndex,
                                        ),
                                    children: [
                                      for (var i = 0; i < active.length; i++)
                                        ReorderableDelayedDragStartListener(
                                          key: ValueKey(active[i].id),
                                          index: i,
                                          child: _TaskRow(
                                            task: active[i],
                                            subtaskStats: _subtaskStats(
                                              active[i].id,
                                            ),
                                            onToggle: (v) =>
                                                _toggleTask(active[i], v),
                                            onStar: () =>
                                                _toggleStar(active[i]),
                                            onEdit: () => setState(
                                              () => _selectedTaskId =
                                                  active[i].id,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                if (!hideCompleted && completed.isNotEmpty) ...[
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
                                        subtaskStats: _subtaskStats(task.id),
                                        onToggle: (v) => _toggleTask(task, v),
                                        onStar: () => _toggleStar(task),
                                        onEdit: () => setState(
                                          () => _selectedTaskId = task.id,
                                        ),
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
                                child: const Text('Add'),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                if (selectedTask != null)
                  TodoEditPanel(
                    task: selectedTask,
                    onClose: () => setState(() => _selectedTaskId = null),
                    onChanged: () {
                      ref.invalidate(todoTasksProvider(selectedTask.listId));
                      ref.invalidate(todoListsProvider);
                    },
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
  });

  final TodoTask task;
  final ValueChanged<bool?> onToggle;
  final VoidCallback onStar;
  final VoidCallback onEdit;
  final Future<({int completed, int total})> subtaskStats;

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
      duration: const Duration(milliseconds: 400),
    );
    _checkScale = TweenSequence<double>([
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
      widget.onToggle(true);
      setState(() => _animatingComplete = false);
    } else if (value == false) {
      _animController.reset();
      setState(() => _displayCompleted = false);
      widget.onToggle(false);
    }
  }

  String? _formatDue(DateTime? dueDate) {
    if (dueDate == null) return null;
    final local = dueDate.toLocal();
    return '${DateFormat.MMMd().format(local)} · ${formatTime12Hour(dueDate)}';
  }

  String? _metadataLabel(
    String? dueLabel,
    ({int completed, int total})? stats,
  ) {
    final parts = <String>[];
    if (dueLabel != null) parts.add(dueLabel);
    if (stats != null && stats.total > 0) {
      parts.add('${stats.completed} : ${stats.total}');
    }
    if (parts.isEmpty) return null;
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final dueLabel = _formatDue(widget.task.dueDate);
    final strikeColor = Theme.of(context).colorScheme.onSurface.withValues(
      alpha: 0.55,
    );
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
                        final metadata = _metadataLabel(
                          dueLabel,
                          snapshot.data,
                        );
                        if (metadata == null) return const SizedBox.shrink();
                        return Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            metadata,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(
                                  fontSize: 10,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurface
                                      .withValues(alpha: 0.72),
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
                ? Theme.of(context).colorScheme.primary
                : null,
          ),
        ],
      ),
    );
  }
}
