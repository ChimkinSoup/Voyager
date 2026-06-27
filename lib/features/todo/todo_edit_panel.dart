import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/icons/voyager_icons.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/theme/voyager_menu_theme.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/utils/time_format.dart';
import 'package:voyager/core/widgets/confirm_dialog.dart';
import 'package:voyager/core/widgets/datetime_picker_dialog.dart';
import 'package:voyager/core/widgets/journal_color_flag.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/core/widgets/voyager_popup_menu_item.dart';
import 'package:voyager/domain/models/todo_models.dart';

class TodoEditPanel extends ConsumerStatefulWidget {
  const TodoEditPanel({
    super.key,
    required this.task,
    required this.onClose,
    required this.onChanged,
    required this.onDeleted,
    required this.onToggleStar,
    this.onTaskOptimistic,
    this.listColor,
    this.lists = const [],
  });

  final TodoTask task;
  final VoidCallback onClose;
  final VoidCallback onChanged;
  final VoidCallback onDeleted;
  final VoidCallback onToggleStar;
  final ValueChanged<TodoTask>? onTaskOptimistic;
  final int? listColor;
  final List<TodoListModel> lists;

  @override
  ConsumerState<TodoEditPanel> createState() => _TodoEditPanelState();
}

class _TodoEditPanelState extends ConsumerState<TodoEditPanel> {
  static const _saveDebounce = Duration(milliseconds: 400);

  late final TextEditingController _titleController;
  late final TextEditingController _notesController;
  late final TextEditingController _subtaskController;
  late final FocusNode _notesFocusNode;
  late final FocusNode _subtaskFocusNode;
  DateTime? _dueDate;
  List<TodoTask> _subtasks = [];
  RemoteSyncService? _remoteSync;
  late String _lastNonEmptyTitle;
  Timer? _titleSaveTimer;
  Timer? _notesSaveTimer;

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
    _titleSaveTimer?.cancel();
    _notesSaveTimer?.cancel();
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

  Color? get _accentColor =>
      widget.listColor == null ? null : Color(widget.listColor!);

  Future<void> _save({
    String? title,
    String? notes,
    DateTime? dueDate,
    bool clearDueDate = false,
    String? listId,
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
      listId: listId,
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

  void _scheduleTitleSave(String value) {
    _titleSaveTimer?.cancel();
    _titleSaveTimer = Timer(_saveDebounce, () {
      if (!mounted) return;
      unawaited(_onTitleChanged(value));
    });
  }

  void _scheduleNotesSave(String value) {
    _notesSaveTimer?.cancel();
    _notesSaveTimer = Timer(_saveDebounce, () {
      if (!mounted) return;
      unawaited(_onNotesChanged(value));
    });
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
    final title = value.trim();
    if (title.isEmpty) return;
    _titleSaveTimer?.cancel();
    final updated = widget.task.copyWith(title: title);
    widget.onTaskOptimistic?.call(updated);
    unawaited(_save(title: title));
    if (mounted) FocusScope.of(context).unfocus();
  }

  Future<void> _moveToList(String listId) async {
    if (listId == widget.task.listId) return;
    final updated = widget.task.copyWith(listId: listId);
    widget.onTaskOptimistic?.call(updated);
    unawaited(_save(listId: listId));
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
    _notesSaveTimer?.cancel();
    FocusManager.instance.primaryFocus?.unfocus();
    unawaited(_save());
  }

  Future<void> _pickDueDateTime() async {
    final picked = await showDateTimePickerDialog(
      context,
      initialDateTime: (_dueDate ?? DateTime.now()).toLocal(),
    );
    if (picked == null || !mounted) return;
    final due = picked.hour == 0 && picked.minute == 0
        ? DateUtils.dateOnly(picked).toUtc()
        : picked.toUtc();
    setState(() => _dueDate = due);
    widget.onTaskOptimistic?.call(
      widget.task.copyWith(dueDate: due),
    );
    unawaited(_save(dueDate: due));
  }

  Future<void> _clearDueDate() async {
    setState(() => _dueDate = null);
    widget.onTaskOptimistic?.call(
      widget.task.copyWith(clearDueDate: true),
    );
    unawaited(_save(clearDueDate: true));
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
    widget.onDeleted();
    final deleted = widget.task.copyWith(deletedAt: utcNow());
    unawaited(() async {
      await ref.read(todoRepositoryProvider).upsertTask(deleted);
      await ref.read(remoteSyncServiceProvider).pushTodoTaskNow(deleted);
    }());
  }

  String _formatDue(DateTime dateTime) {
    final local = dateTime.toLocal();
    if (local.hour == 0 && local.minute == 0) {
      return DateFormat.MMMd().format(local);
    }
    return '${DateFormat.MMMd().format(local)} · ${formatTime12Hour(dateTime)}';
  }

  int _listFlagColor(TodoListModel list) =>
      list.colorValue ?? Theme.of(context).colorScheme.primary.toARGB32();

  static const _compactIconButtonStyle = ButtonStyle(
    visualDensity: VisualDensity.compact,
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    padding: WidgetStatePropertyAll(EdgeInsets.zero),
    minimumSize: WidgetStatePropertyAll(Size(32, 32)),
    fixedSize: WidgetStatePropertyAll(Size(32, 32)),
  );

  Widget _buildHeader(BuildContext context, ThemeData theme, Color? listColor) {
    Widget starButton() => IconButton(
      style: _compactIconButtonStyle,
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
    );

    Widget deleteButton() => IconButton(
      style: _compactIconButtonStyle,
      onPressed: _deleteTask,
      icon: const Icon(PhosphorIconsRegular.trash),
      tooltip: 'Delete task',
    );

    Widget closeButton() => IconButton(
      style: _compactIconButtonStyle,
      onPressed: _close,
      icon: const Icon(PhosphorIconsRegular.x),
      tooltip: 'Close',
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final title = Text(
          'Edit task',
          style: theme.textTheme.titleMedium,
          overflow: TextOverflow.ellipsis,
        );
        final useOverflowMenu = constraints.maxWidth < 128;

        if (useOverflowMenu) {
          return Row(
            children: [
              Expanded(child: title),
              PopupMenuButton<_HeaderAction>(
                padding: EdgeInsets.zero,
                iconSize: 20,
                tooltip: 'Task actions',
                onSelected: (action) {
                  switch (action) {
                    case _HeaderAction.star:
                      widget.onToggleStar();
                    case _HeaderAction.delete:
                      _deleteTask();
                    case _HeaderAction.close:
                      _close();
                  }
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: _HeaderAction.star,
                    child: Text(
                      widget.task.starred ? 'Unstar task' : 'Star task',
                    ),
                  ),
                  const PopupMenuItem(
                    value: _HeaderAction.delete,
                    child: Text('Delete task'),
                  ),
                  const PopupMenuItem(
                    value: _HeaderAction.close,
                    child: Text('Close'),
                  ),
                ],
              ),
            ],
          );
        }

        return Row(
          children: [
            Expanded(child: title),
            starButton(),
            deleteButton(),
            closeButton(),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    _remoteSync = ref.read(remoteSyncServiceProvider);
    final theme = Theme.of(context);
    final listColor = _accentColor;
    return Material(
      elevation: 0,
      color: theme.colorScheme.surface,
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: theme.dividerColor)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(context, theme, listColor),
            const SizedBox(height: 12),
            Stack(
              clipBehavior: Clip.none,
              children: [
                LabeledTextField(
                  label: 'Title',
                  controller: _titleController,
                  textInputAction: TextInputAction.done,
                  onSubmitted: _onTitleSubmitted,
                  onChanged: _scheduleTitleSave,
                  accentColor: listColor,
                  contentPadding: const EdgeInsets.fromLTRB(16, 16, 56, 16),
                ),
                if (widget.lists.isNotEmpty)
                  Positioned(
                    top: 10,
                    right: 10,
                    child: JournalTitleCornerFlag(
                      colorValue: widget.listColor ??
                          theme.colorScheme.primary.toARGB32(),
                      onSelected: _moveToList,
                      menuEntries: (_) => [
                        for (var i = 0; i < widget.lists.length; i++)
                          VoyagerPopupMenuItem<String>(
                            value: widget.lists[i].id,
                            position: VoyagerMenuTheme.positionFor(
                              i,
                              widget.lists.length,
                            ),
                            child: Row(
                              children: [
                                JournalBookmarkFlag(
                                  colorValue: _listFlagColor(widget.lists[i]),
                                  size: 12,
                                ),
                                const SizedBox(width: 8),
                                Expanded(child: Text(widget.lists[i].name)),
                                if (widget.lists[i].id == widget.task.listId)
                                  Icon(
                                    PhosphorIconsRegular.check,
                                    size: 18,
                                    color: theme.colorScheme.primary,
                                  ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
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
                    _dueDate == null ? 'Set due date' : _formatDue(_dueDate!),
                  ),
                ),
                if (_dueDate != null)
                  TextButton(
                    onPressed: _clearDueDate,
                    style: TextButton.styleFrom(foregroundColor: listColor),
                    child: const Text('Reset due date'),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 120,
              child: LabeledTextField(
                label: 'Notes',
                controller: _notesController,
                focusNode: _notesFocusNode,
                expands: true,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                accentColor: listColor,
                onChanged: (value) {
                  final notes = value.trim();
                  widget.onTaskOptimistic?.call(
                    notes.isEmpty
                        ? widget.task.copyWith(clearNotes: true)
                        : widget.task.copyWith(notes: notes),
                  );
                  _scheduleNotesSave(value);
                },
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Subtasks',
              style: theme.textTheme.titleSmall?.copyWith(color: listColor),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: LabeledTextField(
                    label: '',
                    showLabel: false,
                    hintText: 'Add subtask',
                    controller: _subtaskController,
                    focusNode: _subtaskFocusNode,
                    accentColor: listColor,
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
                      (subtask) => _SubtaskRow(
                        subtask: subtask,
                        listColor: listColor,
                        onToggle: (completed) =>
                            _toggleSubtask(subtask, completed),
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
              onPressed: _close,
              style: FilledButton.styleFrom(
                backgroundColor: listColor,
                foregroundColor: listColor == null ? null : Colors.white,
              ),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SubtaskRow extends StatefulWidget {
  const _SubtaskRow({
    required this.subtask,
    required this.onToggle,
    this.listColor,
  });

  final TodoTask subtask;
  final ValueChanged<bool> onToggle;
  final Color? listColor;

  @override
  State<_SubtaskRow> createState() => _SubtaskRowState();
}

class _SubtaskRowState extends State<_SubtaskRow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _strikeProgress;
  var _displayCompleted = false;
  var _animating = false;
  double _textWidth = 0;
  double _textHeight = 0;

  @override
  void initState() {
    super.initState();
    _displayCompleted = widget.subtask.completed;
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _strikeProgress = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.2, 1.0, curve: Curves.easeOut),
    );
    if (widget.subtask.completed) _controller.value = 1.0;
  }

  @override
  void didUpdateWidget(covariant _SubtaskRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_animating) return;
    if (oldWidget.subtask.completed != widget.subtask.completed) {
      _displayCompleted = widget.subtask.completed;
      _controller.value = widget.subtask.completed ? 1.0 : 0.0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _measureText(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyMedium;
    final painter = TextPainter(
      text: TextSpan(text: widget.subtask.title, style: style),
      textDirection: Directionality.of(context),
      maxLines: null,
    )..layout(maxWidth: MediaQuery.sizeOf(context).width - 120);
    _textWidth = painter.size.width;
    _textHeight = painter.size.height;
  }

  Future<void> _handleToggle(bool? value) async {
    if (_animating) return;
    if (value == true && !widget.subtask.completed) {
      setState(() {
        _animating = true;
        _displayCompleted = true;
      });
      await _controller.forward(from: 0);
      if (!mounted) return;
      widget.onToggle(true);
      setState(() => _animating = false);
    } else if (value == false && widget.subtask.completed) {
      setState(() => _animating = true);
      await _controller.reverse(from: 1.0);
      if (!mounted) return;
      setState(() => _displayCompleted = false);
      widget.onToggle(false);
      setState(() => _animating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    _measureText(context);
    final strikeColor = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: 0.55);
    final textStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(
      color: _displayCompleted ? strikeColor : null,
    );

    return CheckboxListTile(
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      activeColor: widget.listColor,
      value: _displayCompleted,
      onChanged: _handleToggle,
      title: Stack(
        clipBehavior: Clip.none,
        children: [
          Text(widget.subtask.title, style: textStyle),
          if (_displayCompleted)
            Positioned(
              left: 0,
              top: 0,
              width: _textWidth,
              height: _textHeight,
              child: AnimatedBuilder(
                animation: _strikeProgress,
                builder: (context, _) {
                  return CustomPaint(
                    painter: _MultilineStrikePainter(
                      text: widget.subtask.title,
                      style: textStyle ?? const TextStyle(),
                      progress: _strikeProgress.value.clamp(0.0, 1.0),
                      color: strikeColor,
                      textDirection: Directionality.of(context),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

enum _HeaderAction { star, delete, close }

class _MultilineStrikePainter extends CustomPainter {
  _MultilineStrikePainter({
    required this.text,
    required this.style,
    required this.progress,
    required this.color,
    required this.textDirection,
  });

  final String text;
  final TextStyle style;
  final double progress;
  final Color color;
  final TextDirection textDirection;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: textDirection,
      maxLines: null,
    )..layout(maxWidth: size.width);

    final metrics = painter.computeLineMetrics();
    if (metrics.isEmpty) return;

    final totalLength = metrics.fold<double>(
      0,
      (sum, line) => sum + line.width,
    );
    var remaining = totalLength * progress;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5;

    for (final line in metrics) {
      if (remaining <= 0) break;
      final drawWidth = remaining < line.width ? remaining : line.width;
      final y = line.baseline - (line.ascent * 0.35);
      canvas.drawLine(
        Offset(0, y),
        Offset(drawWidth, y),
        paint,
      );
      remaining -= line.width;
    }
  }

  @override
  bool shouldRepaint(covariant _MultilineStrikePainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.text != text ||
        oldDelegate.color != color;
  }
}
