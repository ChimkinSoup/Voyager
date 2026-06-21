import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/icons/voyager_icons.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/utils/time_format.dart';
import 'package:voyager/core/widgets/datetime_picker_dialog.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/domain/models/todo_models.dart';

class TodoEditPanel extends ConsumerStatefulWidget {
  const TodoEditPanel({
    super.key,
    required this.task,
    required this.onClose,
    required this.onChanged,
  });

  final TodoTask task;
  final VoidCallback onClose;
  final VoidCallback onChanged;

  @override
  ConsumerState<TodoEditPanel> createState() => _TodoEditPanelState();
}

class _TodoEditPanelState extends ConsumerState<TodoEditPanel> {
  late final TextEditingController _titleController;
  late final TextEditingController _notesController;
  late final TextEditingController _subtaskController;
  late final FocusNode _subtaskFocusNode;
  DateTime? _dueDate;
  List<TodoTask> _subtasks = [];

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.task.title);
    _notesController = TextEditingController(text: widget.task.notes ?? '');
    _subtaskController = TextEditingController();
    _subtaskFocusNode = FocusNode();
    _dueDate = widget.task.dueDate;
    _loadSubtasks();
  }

  @override
  void didUpdateWidget(covariant TodoEditPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.task.id != widget.task.id) {
      _titleController.text = widget.task.title;
      _notesController.text = widget.task.notes ?? '';
      _dueDate = widget.task.dueDate;
      _loadSubtasks();
    }
  }

  Future<void> _loadSubtasks() async {
    final subtasks = await ref
        .read(todoRepositoryProvider)
        .listSubtasks(widget.task.id);
    if (mounted) setState(() => _subtasks = subtasks);
  }

  @override
  void dispose() {
    _titleController.dispose();
    _notesController.dispose();
    _subtaskController.dispose();
    _subtaskFocusNode.dispose();
    super.dispose();
  }

  Future<void> _save({
    String? title,
    String? notes,
    DateTime? dueDate,
    bool clearDueDate = false,
  }) async {
    final repo = ref.read(todoRepositoryProvider);
    final updated = widget.task.copyWith(
      title: title ?? _titleController.text.trim(),
      notes: (notes ?? _notesController.text.trim()).isEmpty
          ? null
          : (notes ?? _notesController.text.trim()),
      dueDate: dueDate,
      clearDueDate: clearDueDate,
    );
    if (updated.title.isEmpty) return;
    await repo.upsertTask(updated);
    ref.read(remoteSyncServiceProvider).pushTodoTaskNow(updated);
    widget.onChanged();
  }

  Future<void> _onTitleChanged(String value) async {
    final title = value.trim();
    if (title.isEmpty) return;
    final updated = widget.task.copyWith(title: title);
    await ref.read(todoRepositoryProvider).upsertTask(updated);
    ref.read(remoteSyncServiceProvider).pushTodoTaskTitleDebounced(updated);
  }

  Future<void> _onTitleSubmitted(String value) async {
    final title = value.trim();
    if (title.isEmpty) {
      await _promptEmptyTitle();
      return;
    }
    await _save(title: title);
  }

  Future<void> _promptEmptyTitle() async {
    final delete = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete task?'),
        content: const Text(
          'The title is empty. Do you want to delete this task?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('No'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Yes, delete'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (delete == true) {
      final now = utcNow();
      await ref.read(todoRepositoryProvider).softDeleteTask(widget.task.id);
      ref.read(remoteSyncServiceProvider).pushTodoTaskNow(
        widget.task.copyWith(deletedAt: now),
      );
      widget.onChanged();
      widget.onClose();
    } else {
      _titleController.text = widget.task.title;
    }
  }

  Future<void> _pickDueDateTime() async {
    final picked = await showDateTimePickerDialog(
      context,
      initialDateTime: (_dueDate ?? DateTime.now()).toLocal(),
    );
    if (picked == null || !mounted) return;
    setState(() => _dueDate = picked.toUtc());
    await _save(dueDate: _dueDate);
  }

  Future<void> _clearDueDate() async {
    setState(() => _dueDate = null);
    await _save(clearDueDate: true);
  }

  Future<void> _addSubtask() async {
    final title = _subtaskController.text.trim();
    if (title.isEmpty) return;
    final now = utcNow();
    final subtask = TodoTask(
      id: newId(),
      listId: widget.task.listId,
      parentTaskId: widget.task.id,
      title: title,
      sortOrder: _subtasks.length,
      createdAt: now,
      updatedAt: now,
    );
    await ref.read(todoRepositoryProvider).upsertTask(subtask);
    ref.read(remoteSyncServiceProvider).pushTodoTaskNow(subtask);
    _subtaskController.clear();
    await _loadSubtasks();
    widget.onChanged();
    _subtaskFocusNode.requestFocus();
  }

  Future<void> _toggleSubtask(TodoTask subtask, bool completed) async {
    final updated = subtask.copyWith(completed: completed);
    await ref.read(todoRepositoryProvider).upsertTask(updated);
    ref.read(remoteSyncServiceProvider).pushTodoTaskNow(updated);
    await _loadSubtasks();
    widget.onChanged();
  }

  String _formatDue(DateTime dateTime) {
    final local = dateTime.toLocal();
    return '${DateFormat.MMMd().format(local)} · ${formatTime12Hour(dateTime)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      elevation: 0,
      color: theme.colorScheme.surface,
      child: Container(
        width: 420,
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: theme.dividerColor)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('Edit task', style: theme.textTheme.titleMedium),
                ),
                IconButton(
                  onPressed: widget.onClose,
                  icon: const Icon(PhosphorIconsRegular.x),
                ),
              ],
            ),
            const SizedBox(height: 12),
            LabeledTextField(
              label: 'Title',
              controller: _titleController,
              onSubmitted: _onTitleSubmitted,
              onChanged: _onTitleChanged,
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: _pickDueDateTime,
                icon: const Icon(VoyagerIcons.calendar, size: 18),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                ),
                label: Text(
                  _dueDate == null
                      ? 'Add due date & time'
                      : _formatDue(_dueDate!),
                ),
              ),
            ),
            if (_dueDate != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: _clearDueDate,
                  child: const Text('Clear due date'),
                ),
              ),
            const SizedBox(height: 8),
            SizedBox(
              height: 120,
              child: LabeledTextField(
                label: 'Notes',
                controller: _notesController,
                expands: true,
                onSubmitted: (_) => _save(),
              ),
            ),
            const SizedBox(height: 12),
            Text('Subtasks', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _subtaskController,
                    focusNode: _subtaskFocusNode,
                    decoration: const InputDecoration(hintText: 'Add subtask'),
                    onSubmitted: (_) => _addSubtask(),
                  ),
                ),
                IconButton(
                  onPressed: _addSubtask,
                  icon: const Icon(PhosphorIconsRegular.plus),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Expanded(
              child: ListView(
                children: _subtasks
                    .map(
                      (subtask) => CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        value: subtask.completed,
                        onChanged: (v) => _toggleSubtask(subtask, v ?? false),
                        title: Text(subtask.title),
                      ),
                    )
                    .toList(),
              ),
            ),
            const Divider(height: 24),
            Text(
              'Created ${DateFormat.yMMMd().add_jm().format(widget.task.createdAt.toLocal())}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: () async {
                await _save();
                widget.onClose();
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }
}
