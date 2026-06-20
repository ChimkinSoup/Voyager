import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/utils/ids.dart';
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
  DateTime? _dueDate;
  List<TodoTask> _subtasks = [];

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.task.title);
    _notesController = TextEditingController(text: widget.task.notes ?? '');
    _subtaskController = TextEditingController();
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

  Future<void> _pickDueDateTime() async {
    final initial = (_dueDate ?? DateTime.now()).toLocal();
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (pickedDate == null || !mounted) return;
    final pickedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (pickedTime == null) return;
    setState(() {
      _dueDate = DateTime(
        pickedDate.year,
        pickedDate.month,
        pickedDate.day,
        pickedTime.hour,
        pickedTime.minute,
      ).toUtc();
    });
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
    final date = DateFormat.MMMd().format(local);
    final time = DateFormat.jm().format(local);
    return '$date · $time';
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
              onSubmitted: (_) => _save(),
              onChanged: _onTitleChanged,
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: _pickDueDateTime,
                icon: const Icon(PhosphorIconsRegular.calendar, size: 18),
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
            Expanded(
              child: LabeledTextField(
                label: 'Notes',
                controller: _notesController,
                expands: true,
                onChanged: (_) {},
              ),
            ),
            const SizedBox(height: 12),
            Text('Subtasks', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            ..._subtasks.map(
              (subtask) => CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: subtask.completed,
                onChanged: (v) => _toggleSubtask(subtask, v ?? false),
                title: Text(subtask.title),
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _subtaskController,
                    decoration: const InputDecoration(hintText: 'Add subtask'),
                    onSubmitted: (_) => _addSubtask(),
                  ),
                ),
                IconButton(onPressed: _addSubtask, icon: const Icon(PhosphorIconsRegular.plus)),
              ],
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
