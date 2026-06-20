import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/keep_alive_scroll.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/core/widgets/rounded_dropdown.dart';
import 'package:voyager/features/shell/shell_page_storage_keys.dart';
import 'package:voyager/domain/models/todo_models.dart';

class TodoPage extends ConsumerStatefulWidget {
  const TodoPage({super.key});

  @override
  ConsumerState<TodoPage> createState() => _TodoPageState();
}

class _TodoPageState extends ConsumerState<TodoPage> {
  String? _selectedListId;
  final _taskController = TextEditingController();
  var _completedExpanded = true;

  @override
  void dispose() {
    _taskController.dispose();
    super.dispose();
  }

  Future<void> _ensureDefaultList() async {
    final repo = ref.read(todoRepositoryProvider);
    final lists = await repo.listLists();
    if (lists.isEmpty) {
      final now = utcNow();
      final list = TodoListModel(id: newId(), name: 'Inbox', createdAt: now, updatedAt: now);
      await repo.upsertList(list);
      _selectedListId = list.id;
    } else {
      _selectedListId ??= lists.first.id;
    }
  }

  Future<void> _createList() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New list'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'List name'),
          onSubmitted: (_) => Navigator.pop(context, controller.text),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Create')),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    final now = utcNow();
    final list = TodoListModel(id: newId(), name: name.trim(), createdAt: now, updatedAt: now);
    await ref.read(todoRepositoryProvider).upsertList(list);
    ref.invalidate(todoListsProvider);
    setState(() => _selectedListId = list.id);
  }

  Future<void> _addTask() async {
    if (_taskController.text.trim().isEmpty) return;
    await _ensureDefaultList();
    final now = utcNow();
    final task = TodoTask(
      id: newId(),
      listId: _selectedListId!,
      title: _taskController.text.trim(),
      createdAt: now,
      updatedAt: now,
    );
    await ref.read(todoRepositoryProvider).upsertTask(task);
    await ref.read(syncRepositoryProvider).upsertDocument('todo_tasks', task.id, {
      'id': task.id,
      'listId': task.listId,
      'title': task.title,
      'completed': false,
      'updatedAt': now.toIso8601String(),
    });
    _taskController.clear();
    ref.invalidate(todoListsProvider);
  }

  Future<void> _toggleTask(TodoTask task, bool? completed) async {
    final now = utcNow();
    await ref.read(todoRepositoryProvider).upsertTask(task.copyWith(completed: completed ?? false));
    await ref.read(syncRepositoryProvider).upsertDocument('todo_tasks', task.id, {
      'id': task.id,
      'completed': completed ?? false,
      'updatedAt': now.toIso8601String(),
    });
  }

  Future<void> _editTask(TodoTask task) async {
    final titleController = TextEditingController(text: task.title);
    final notesController = TextEditingController(text: task.notes ?? '');
    DateTime? dueDate = task.dueDate;
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Edit task'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: titleController,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'Task name'),
                  onSubmitted: (_) => Navigator.pop(context, true),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: notesController,
                  maxLines: 4,
                  decoration: const InputDecoration(labelText: 'Notes'),
                ),
                const SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(dueDate == null ? 'No due date' : DateFormat.yMMMd().format(dueDate!)),
                  trailing: const Icon(Icons.calendar_today),
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: dueDate ?? DateTime.now(),
                      firstDate: DateTime(2000),
                      lastDate: DateTime(2100),
                    );
                    if (picked != null) setDialogState(() => dueDate = picked);
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
          ],
        ),
      ),
    );
    final title = titleController.text.trim();
    final notes = notesController.text.trim();
    titleController.dispose();
    notesController.dispose();
    if (saved != true || title.isEmpty) return;
    final updated = task.copyWith(
      title: title,
      notes: notes.isEmpty ? null : notes,
      dueDate: dueDate,
    );
    await ref.read(todoRepositoryProvider).upsertTask(updated);
    await ref.read(syncRepositoryProvider).upsertDocument('todo_tasks', task.id, {
      'id': task.id,
      'title': updated.title,
      'notes': updated.notes,
      'dueDate': updated.dueDate?.toIso8601String(),
      'updatedAt': utcNow().toIso8601String(),
    });
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
            child: FilledButton(onPressed: _createList, child: const Text('Create your first list')),
          );
        }
        _selectedListId ??= lists.first.id;

        final tasksAsync = ref.watch(todoTasksProvider(_selectedListId!));
        return tasksAsync.when(
          data: (tasks) {
            final active = tasks.where((t) => !t.completed).toList();
            final completed = tasks.where((t) => t.completed).toList();

            return Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: RoundedDropdown<String>(
                          value: _selectedListId!,
                          items: lists.map((l) => RoundedDropdownItem(value: l.id, label: l.name)).toList(),
                          onChanged: (v) => setState(() => _selectedListId = v),
                        ),
                      ),
                      IconButton(onPressed: _createList, icon: const Icon(Icons.add), tooltip: 'New list'),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: KeepAliveScrollView(
                      storageKey: ShellPageStorageKeys.todoTaskList,
                      children: [
                        ...active.map((task) => _TaskRow(
                              task: task,
                              onToggle: (v) => _toggleTask(task, v),
                              onEdit: () => _editTask(task),
                              subtitle: _taskSubtitle(task),
                            )),
                        if (!hideCompleted && completed.isNotEmpty) ...[
                          const Divider(height: 32),
                          InkWell(
                            onTap: () => setState(() => _completedExpanded = !_completedExpanded),
                            borderRadius: BorderRadius.circular(14),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: Row(
                                children: [
                                  Expanded(child: Text('Completed (${completed.length})', style: Theme.of(context).textTheme.titleSmall)),
                                  Icon(_completedExpanded ? Icons.expand_less : Icons.expand_more),
                                ],
                              ),
                            ),
                          ),
                          if (_completedExpanded)
                            ...completed.map(
                              (task) => _TaskRow(
                                task: task,
                                completedStyle: true,
                                onToggle: (v) => _toggleTask(task, v),
                                onEdit: () => _editTask(task),
                                subtitle: _taskSubtitle(task),
                              ),
                            ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: LabeledTextField(
                          label: 'New task',
                          controller: _taskController,
                          onSubmitted: (_) => _addTask(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(onPressed: _addTask, child: const Text('Add')),
                    ],
                  ),
                ],
              ),
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

  Widget? _taskSubtitle(TodoTask task) {
    final parts = <String>[];
    if (task.notes != null && task.notes!.isNotEmpty) parts.add(task.notes!);
    if (task.dueDate != null) parts.add('Due ${DateFormat.MMMd().format(task.dueDate!)}');
    if (parts.isEmpty) return null;
    return Text(parts.join(' · '));
  }
}

class _TaskRow extends StatelessWidget {
  const _TaskRow({
    required this.task,
    required this.onToggle,
    required this.onEdit,
    this.subtitle,
    this.completedStyle = false,
  });

  final TodoTask task;
  final ValueChanged<bool?> onToggle;
  final VoidCallback onEdit;
  final Widget? subtitle;
  final bool completedStyle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Checkbox(value: task.completed, onChanged: onToggle),
          Expanded(
            child: InkWell(
              onTap: onEdit,
              borderRadius: BorderRadius.circular(14),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      task.title,
                      style: completedStyle ? const TextStyle(decoration: TextDecoration.lineThrough) : null,
                    ),
                    ?subtitle,
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
