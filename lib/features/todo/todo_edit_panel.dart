import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/icons/voyager_icons.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/utils/time_format.dart';
import 'package:voyager/core/widgets/confirm_dialog.dart';
import 'package:voyager/core/widgets/datetime_picker_dialog.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/domain/models/todo_models.dart';

class TodoEditPanel extends ConsumerStatefulWidget {
  const TodoEditPanel({
    super.key,
    required this.task,
    required this.onClose,
    required this.onChanged,
    required this.onDeleted,
    required this.onToggleStar,
    this.listColor,
  });

  final TodoTask task;
  final VoidCallback onClose;
  final VoidCallback onChanged;
  final VoidCallback onDeleted;
  final VoidCallback onToggleStar;
  final int? listColor;

  @override
  ConsumerState<TodoEditPanel> createState() => _TodoEditPanelState();
}

class _TodoEditPanelState extends ConsumerState<TodoEditPanel> {
  late final TextEditingController _titleController;
  late final TextEditingController _notesController;
  late final TextEditingController _subtaskController;
  late final FocusNode _notesFocusNode;
  late final FocusNode _subtaskFocusNode;
  DateTime? _dueDate;
  List<TodoTask> _subtasks = [];
  RemoteSyncService? _remoteSync;
  late String _lastNonEmptyTitle;

  @override
  void initState() {
    super.initState();
    _lastNonEmptyTitle = widget.task.title;
    _titleController = TextEditingController(text: widget.task.title);
    _notesController = TextEditingController(text: widget.task.notes ?? '');
    _notesFocusNode = FocusNode();
    _notesFocusNode.onKeyEvent = _handleNotesKey;
    _subtaskController = TextEditingController();
    _subtaskFocusNode = FocusNode();
    _dueDate = widget.task.dueDate;
    _loadSubtasks();
  }

  @override
  void didUpdateWidget(covariant TodoEditPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.task.id != widget.task.id) {
      _lastNonEmptyTitle = widget.task.title;
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
    final remoteSync = _remoteSync;
    if (remoteSync != null) {
      unawaited(
        remoteSync.flushDocument(
          FirestoreCollections.todoTasks,
          widget.task.id,
        ),
      );
    }
    _titleController.dispose();
    _notesController.dispose();
    _notesFocusNode.dispose();
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
    final remoteSync = ref.read(remoteSyncServiceProvider);
    final notesText = notes ?? _notesController.text.trim();
    var titleText = title ?? _titleController.text.trim();
    if (titleText.isEmpty) {
      titleText = _lastNonEmptyTitle;
      _titleController.text = titleText;
    }

    final updated = widget.task.copyWith(
      title: titleText,
      notes: notesText.isEmpty ? null : notesText,
      clearNotes: notesText.isEmpty,
      dueDate: clearDueDate ? null : (dueDate ?? _dueDate),
      clearDueDate: clearDueDate,
    );
    await repo.upsertTask(updated);
    await remoteSync.flushDocument(
      FirestoreCollections.todoTasks,
      widget.task.id,
    );
    await remoteSync.pushTodoTaskNow(updated);
    widget.onChanged();
  }

  Future<void> _close() async {
    if (mounted) widget.onClose();
    unawaited(_save());
  }

  Future<void> _onNotesChanged(String value) async {
    final notes = value.trim();
    final updated = notes.isEmpty
        ? widget.task.copyWith(clearNotes: true)
        : widget.task.copyWith(notes: notes);
    await ref
        .read(remoteSyncServiceProvider)
        .saveTodoTaskThenScheduleUpload(updated);
  }

  Future<void> _onTitleChanged(String value) async {
    final title = value.trim();
    if (title.isNotEmpty) {
      _lastNonEmptyTitle = title;
    }
    if (title.isEmpty) return;
    final updated = widget.task.copyWith(title: title);
    await ref
        .read(remoteSyncServiceProvider)
        .saveTodoTaskThenScheduleUpload(updated);
  }

  Future<void> _onTitleSubmitted(String value) async {
    await _save(title: value.trim());
    if (mounted) FocusScope.of(context).unfocus();
  }

  KeyEventResult _handleNotesKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey != LogicalKeyboardKey.enter) {
      return KeyEventResult.ignored;
    }
    if (HardwareKeyboard.instance.isShiftPressed) {
      return KeyEventResult.ignored;
    }
    _saveNotesAndUnfocus();
    return KeyEventResult.handled;
  }

  void _saveNotesAndUnfocus() {
    FocusManager.instance.primaryFocus?.unfocus();
    unawaited(_save());
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

  Future<void> _pickDueDay() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: (_dueDate ?? DateTime.now()).toLocal(),
      firstDate: DateTime(1970),
      lastDate: DateTime(2100),
    );
    if (picked == null || !mounted) return;
    setState(() => _dueDate = DateUtils.dateOnly(picked).toUtc());
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

  Future<void> _deleteTask() async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Delete task?',
      message: 'Delete "${widget.task.title}"?',
    );
    if (!confirmed) return;
    final deleted = widget.task.copyWith(deletedAt: utcNow());
    await ref.read(todoRepositoryProvider).upsertTask(deleted);
    await ref.read(remoteSyncServiceProvider).pushTodoTaskNow(deleted);
    widget.onDeleted();
  }

  String _formatDue(DateTime dateTime) {
    final local = dateTime.toLocal();
    if (local.hour == 0 && local.minute == 0) {
      return DateFormat.MMMd().format(local);
    }
    return '${DateFormat.MMMd().format(local)} · ${formatTime12Hour(dateTime)}';
  }

  @override
  Widget build(BuildContext context) {
    _remoteSync = ref.read(remoteSyncServiceProvider);
    final theme = Theme.of(context);
    final listColor = widget.listColor == null
        ? null
        : Color(widget.listColor!);
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
                  onPressed: widget.onToggleStar,
                  icon: Icon(
                    widget.task.starred
                        ? PhosphorIconsFill.star
                        : PhosphorIconsRegular.star,
                  ),
                  color: widget.task.starred
                      ? listColor ?? theme.colorScheme.primary
                      : null,
                  tooltip: widget.task.starred ? 'Unstar task' : 'Star task',
                ),
                IconButton(
                  onPressed: _deleteTask,
                  icon: const Icon(PhosphorIconsRegular.trash),
                  tooltip: 'Delete task',
                ),
                IconButton(
                  onPressed: _close,
                  icon: const Icon(PhosphorIconsRegular.x),
                ),
              ],
            ),
            const SizedBox(height: 12),
            LabeledTextField(
              label: 'Title',
              controller: _titleController,
              textInputAction: TextInputAction.done,
              onSubmitted: _onTitleSubmitted,
              onChanged: _onTitleChanged,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                OutlinedButton.icon(
                  onPressed: _pickDueDateTime,
                  icon: const Icon(VoyagerIcons.calendar, size: 18),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: listColor,
                    side: listColor == null
                        ? null
                        : BorderSide(color: listColor.withValues(alpha: 0.7)),
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
                OutlinedButton.icon(
                  onPressed: _pickDueDay,
                  icon: const Icon(
                    PhosphorIconsRegular.calendarBlank,
                    size: 18,
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: listColor,
                    side: listColor == null
                        ? null
                        : BorderSide(color: listColor.withValues(alpha: 0.7)),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                  ),
                  label: const Text('Add due day'),
                ),
                if (_dueDate != null)
                  TextButton(
                    onPressed: _clearDueDate,
                    child: const Text('Clear due date'),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 120,
              child: LabeledTextField(
                label: 'Notes',
                controller: _notesController,
                focusNode: _notesFocusNode,
                expands: true,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                onChanged: _onNotesChanged,
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
                        controlAffinity: ListTileControlAffinity.leading,
                        activeColor: listColor,
                        value: subtask.completed,
                        onChanged: (v) => _toggleSubtask(subtask, v ?? false),
                        title: AnimatedDefaultTextStyle(
                          duration: const Duration(milliseconds: 200),
                          curve: Curves.easeOut,
                          style: theme.textTheme.bodyMedium!.copyWith(
                            decoration: subtask.completed
                                ? TextDecoration.lineThrough
                                : TextDecoration.none,
                            color: subtask.completed
                                ? theme.colorScheme.onSurface.withValues(
                                    alpha: 0.55,
                                  )
                                : null,
                          ),
                          child: Text(subtask.title),
                        ),
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
            FilledButton(onPressed: _close, child: const Text('Save')),
          ],
        ),
      ),
    );
  }
}
