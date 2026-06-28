import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/icons/voyager_icons.dart';
import 'package:voyager/core/dev/todo_sort_debug_logger.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/pending_text_merge.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/sync/text_delta_injector.dart';
import 'package:voyager/core/theme/voyager_menu_theme.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/utils/time_format.dart';
import 'package:voyager/domain/todo/todo_task_sorting.dart';
import 'package:voyager/core/widgets/confirm_dialog.dart';
import 'package:voyager/core/widgets/datetime_picker_dialog.dart';
import 'package:voyager/core/widgets/journal_color_flag.dart';
import 'package:voyager/core/widgets/enter_to_submit_scope.dart';
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
    required     this.onToggleStar,
    this.onTaskOptimistic,
    this.onSortBatchApplied,
    this.listColor,
    this.lists = const [],
  });

  final TodoTask task;
  final VoidCallback onClose;
  final VoidCallback onChanged;
  final VoidCallback onDeleted;
  final VoidCallback onToggleStar;
  final ValueChanged<TodoTask>? onTaskOptimistic;
  final ValueChanged<TodoSortBatch>? onSortBatchApplied;
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
  late final FocusNode _titleFocusNode;
  late final FocusNode _notesFocusNode;
  late final FocusNode _subtaskFocusNode;
  DateTime? _dueDate;
  List<TodoTask> _subtasks = [];
  RemoteSyncService? _remoteSync;
  PendingTextMergeListener? _pendingTextMergeListener;
  late String _lastNonEmptyTitle;
  Timer? _titleSaveTimer;
  Timer? _notesSaveTimer;
  var _lastNotesText = '';

  @override
  void initState() {
    super.initState();
    _lastNonEmptyTitle = widget.task.title;
    _titleController = TextEditingController(text: widget.task.title);
    _notesController = TextEditingController(text: widget.task.notes ?? '');
    _lastNotesText = _notesController.text;
    _titleFocusNode = FocusNode();
    _titleFocusNode.onKeyEvent = _handleTitleKey;
    _notesFocusNode = FocusNode();
    _notesFocusNode.addListener(_handleNotesFocusChanged);
    _notesFocusNode.onKeyEvent = _handleNotesKey;
    _subtaskController = TextEditingController();
    _subtaskFocusNode = FocusNode();
    _dueDate = widget.task.dueDate;
    _loadSubtasks();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _remoteSync = ref.read(remoteSyncServiceProvider);
      _registerPendingNotesListener(widget.task.id);
      _setNotesEditingFlag(_notesFocusNode.hasFocus);
    });
  }

  @override
  void didUpdateWidget(covariant TodoEditPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.task.id != widget.task.id) {
      _unregisterPendingNotesListener(oldWidget.task.id);
      _lastNonEmptyTitle = widget.task.title;
      _titleController.text = widget.task.title;
      _notesController.text = widget.task.notes ?? '';
      _lastNotesText = _notesController.text;
      _dueDate = widget.task.dueDate;
      _loadSubtasks();
      _registerPendingNotesListener(widget.task.id);
    }
  }

  void _registerPendingNotesListener(String taskId) {
    final RemoteSyncService remoteSync =
        _remoteSync ?? ref.read(remoteSyncServiceProvider);
    _remoteSync = remoteSync;
    _pendingTextMergeListener ??= _handlePendingNotesMerge;
    remoteSync.addPendingTextMergeListener(
      collection: FirestoreCollections.todoTasks,
      documentId: taskId,
      listener: _pendingTextMergeListener!,
    );
  }

  void _unregisterPendingNotesListener(String taskId) {
    final remoteSync = _remoteSync;
    if (remoteSync == null || _pendingTextMergeListener == null) return;
    remoteSync.removePendingTextMergeListener(
      collection: FirestoreCollections.todoTasks,
      documentId: taskId,
      listener: _pendingTextMergeListener!,
    );
  }

  void _setNotesEditingFlag(bool isEditing) {
    final remoteSync = _remoteSync;
    if (remoteSync == null) return;
    remoteSync.setDocumentEditing(
      collection: FirestoreCollections.todoTasks,
      documentId: widget.task.id,
      isEditing: isEditing,
    );
  }

  void _handleNotesFocusChanged() {
    if (!mounted) return;
    _setNotesEditingFlag(_notesFocusNode.hasFocus);
    if (!_notesFocusNode.hasFocus) {
      unawaited(_applyPendingNotesMerge());
    }
  }

  void _handlePendingNotesMerge(PendingTextMergeEvent event) {
    if (!mounted || widget.task.id != event.documentId) return;
    if (!_notesFocusNode.hasFocus) return;

    final before = _notesController.text;
    final merged = TextDeltaInjector.injectRemoteDelta(
      localText: before,
      oldRemoteText: event.previousRemoteText,
      newRemoteText: event.remoteText,
    );
    if (merged == before) return;

    final selection = _notesController.selection;
    _notesController.value = TextEditingValue(
      text: merged,
      selection: TextSelection.collapsed(
        offset: TextDeltaInjector.adjustedSelection(
          selection: selection.baseOffset,
          before: before,
          after: merged,
        ),
      ),
    );
  }

  Future<void> _applyPendingNotesMerge() async {
    final remoteSync = _remoteSync;
    if (remoteSync == null) return;
    final merged = await remoteSync.applyPendingTodoTaskNotesMerge(
      taskId: widget.task.id,
      currentLocalNotes: _notesController.text,
    );
    if (merged != null && mounted) {
      _notesController.text = merged.notes ?? '';
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
    _unregisterPendingNotesListener(widget.task.id);
    _setNotesEditingFlag(false);
    _notesFocusNode.removeListener(_handleNotesFocusChanged);
    final remoteSync = _remoteSync;
    if (remoteSync != null) {
      unawaited(
        _applyPendingNotesMerge().then((_) async {
          await remoteSync.flushDocument(
            FirestoreCollections.todoTasks,
            widget.task.id,
          );
        }),
      );
    }
    _titleController.dispose();
    _notesController.dispose();
    _titleFocusNode.dispose();
    _notesFocusNode.dispose();
    _subtaskController.dispose();
    _subtaskFocusNode.dispose();
    super.dispose();
  }

  Color get _listAccentColor {
    final theme = Theme.of(context);
    return widget.listColor == null
        ? theme.colorScheme.primary
        : Color(widget.listColor!);
  }

  KeyEventResult _handleTitleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.tab &&
        !HardwareKeyboard.instance.isShiftPressed) {
      _notesFocusNode.requestFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _handleNotesKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.tab &&
        !HardwareKeyboard.instance.isShiftPressed) {
      _subtaskFocusNode.requestFocus();
      return KeyEventResult.handled;
    }
    if (event.logicalKey != LogicalKeyboardKey.enter) {
      return KeyEventResult.ignored;
    }
    if (HardwareKeyboard.instance.isShiftPressed) {
      return KeyEventResult.ignored;
    }
    _saveNotesAndUnfocus();
    return KeyEventResult.handled;
  }

  Future<void> _save({
    String? title,
    String? notes,
    DateTime? dueDate,
    bool clearDueDate = false,
    String? listId,
    bool reorderDueDate = false,
  }) async {
    await _applyPendingNotesMerge();
    final repo = ref.read(todoRepositoryProvider);
    final remoteSync = ref.read(remoteSyncServiceProvider);
    final notesText = notes ?? _notesController.text.trim();
    var titleText = title ?? _titleController.text.trim();
    if (titleText.isEmpty) {
      titleText = _lastNonEmptyTitle;
      _titleController.text = titleText;
    }

    final effectiveDue = clearDueDate ? null : (dueDate ?? _dueDate);
    final listMoved = listId != null && listId != widget.task.listId;
    final dueSortChanged = !widget.task.isSubtask &&
        (reorderDueDate ||
            clearDueDate ||
            effectiveDue != widget.task.dueDate);

    final baseUpdate = widget.task.copyWith(
      title: titleText,
      listId: listId,
      notes: notesText.isEmpty ? null : notesText,
      clearNotes: notesText.isEmpty,
      dueDate: effectiveDue,
      clearDueDate: clearDueDate,
    );

    if (listMoved) {
      final sourceListId = widget.task.listId;
      final destSiblings = await repo.listTasks(listId);
      final destActive = activeTopLevelTasks(destSiblings);
      final batch = applyTaskListMove(baseUpdate, destActive);
      TodoTask? savedTask;
      for (final task in batch.tasks) {
        final toSave = task.id == widget.task.id
            ? task.copyWith(
                title: baseUpdate.title,
                listId: baseUpdate.listId,
                notes: baseUpdate.notes,
                clearNotes: baseUpdate.notes == null,
                dueDate: baseUpdate.dueDate,
                clearDueDate: clearDueDate,
                dueDateSetAt: baseUpdate.dueDateSetAt,
                clearDueDateSetAt: clearDueDate,
              )
            : task;
        if (toSave.id == widget.task.id) {
          savedTask = toSave;
        }
        await repo.upsertTask(toSave);
        remoteSync.pushTodoTaskNow(toSave);
      }
      ref.invalidate(todoTasksProvider);
      ref.invalidate(todoTasksProvider(sourceListId));
      ref.invalidate(todoTasksProvider(listId));
      ref.invalidate(allTodoTasksProvider);
      if (savedTask != null) {
        widget.onTaskOptimistic?.call(savedTask);
      }
      widget.onSortBatchApplied?.call(batch);
      logTodoSortDebug(
        ref.read(todoSortDebugLoggerProvider),
        'LIST_MOVE',
        task: savedTask,
        details: 'from $sourceListId to $listId',
      );
    } else if (dueSortChanged) {
      final siblings = await repo.listTasks(widget.task.listId);
      final active = activeTopLevelTasks(siblings);
      final batch = applyDueDateChange(
        widget.task,
        active,
        dueDate: effectiveDue,
        clearDueDate: clearDueDate,
      );
      TodoTask? savedTask;
      for (final task in batch.tasks) {
        final toSave = task.id == widget.task.id
            ? task.copyWith(
                title: baseUpdate.title,
                listId: baseUpdate.listId,
                notes: baseUpdate.notes,
                clearNotes: baseUpdate.notes == null,
              )
            : task;
        if (toSave.id == widget.task.id) {
          savedTask = toSave;
        }
        await repo.upsertTask(toSave);
        remoteSync.pushTodoTaskNow(toSave);
      }
      widget.onSortBatchApplied?.call(batch);
      logTodoSortDebug(
        ref.read(todoSortDebugLoggerProvider),
        clearDueDate ? 'DUE_DATE_CLEARED' : 'DUE_DATE_CHANGED',
        task: savedTask ?? baseUpdate,
        details: _dueDateChangeDetails(
          previous: widget.task,
          next: savedTask ?? baseUpdate,
          clearDueDate: clearDueDate,
        ),
      );
    } else {
      await repo.upsertTask(baseUpdate);
      await remoteSync.flushDocument(
        FirestoreCollections.todoTasks,
        widget.task.id,
      );
      await remoteSync.pushTodoTaskNow(baseUpdate);
    }
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
    final remoteSync = ref.read(remoteSyncServiceProvider);
    final repo = ref.read(todoRepositoryProvider);
    final notes = value.trim();
    final storedLists = await repo.listLists(includeDeleted: true);
    TodoTask? baseline;
    for (final list in storedLists) {
      final tasks = await repo.listTasks(
        list.id,
        includeDeleted: true,
        topLevelOnly: false,
      );
      for (final task in tasks) {
        if (task.id == widget.task.id) {
          baseline = task;
          break;
        }
      }
      if (baseline != null) break;
    }
    if (baseline == null) return;

    final updated = baseline.copyWith(
      notes: notes.isEmpty ? null : notes,
      clearNotes: notes.isEmpty,
      bumpVersion: false,
    );
    await remoteSync.saveTodoTaskThenScheduleUpload(updated);
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
    final previousDue = widget.task.dueDate;
    setState(() => _dueDate = due);
    widget.onTaskOptimistic?.call(
      widget.task.copyWith(dueDate: due, dueDateSetAt: utcNow()),
    );
    unawaited(_save(dueDate: due, reorderDueDate: previousDue != due));
  }

  Future<void> _clearDueDate() async {
    final hadDueDate = widget.task.dueDate != null;
    setState(() => _dueDate = null);
    widget.onTaskOptimistic?.call(
      widget.task.copyWith(clearDueDate: true),
    );
    unawaited(_save(clearDueDate: true, reorderDueDate: hadDueDate));
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

  Future<void> _renameSubtask(TodoTask subtask, String title) async {
    final trimmed = title.trim();
    if (trimmed.isEmpty || trimmed == subtask.title) return;
    final updated = subtask.copyWith(title: trimmed);
    await ref.read(todoRepositoryProvider).upsertTask(updated);
    ref.read(remoteSyncServiceProvider).pushTodoTaskNow(updated);
    await _loadSubtasks();
    widget.onChanged();
  }

  Future<void> _deleteSubtask(TodoTask subtask) async {
    final deleted = subtask.copyWith(deletedAt: utcNow());
    await ref.read(todoRepositoryProvider).upsertTask(deleted);
    ref.read(remoteSyncServiceProvider).pushTodoTaskNow(deleted);
    await _loadSubtasks();
    widget.onChanged();
  }

  Future<void> _reorderSubtasks(int oldIndex, int newIndex) async {
    final batch = applyReorder(_subtasks, oldIndex, newIndex);
    if (batch == null) return;

    setState(() => _subtasks = batch.tasks);
    final repo = ref.read(todoRepositoryProvider);
    final remoteSync = ref.read(remoteSyncServiceProvider);
    for (final task in batch.tasks) {
      await repo.upsertTask(task);
      remoteSync.pushTodoTaskNow(task);
    }
    widget.onChanged();
  }

  Future<void> _promoteSubtask(TodoTask subtask) async {
    final repo = ref.read(todoRepositoryProvider);
    final remoteSync = ref.read(remoteSyncServiceProvider);
    final now = utcNow();
    final task = TodoTask(
      id: newId(),
      listId: widget.task.listId,
      title: subtask.title,
      completed: subtask.completed,
      createdAt: now,
      updatedAt: now,
    );
    final siblings = await repo.listTasks(widget.task.listId);
    final active = activeTopLevelTasks(siblings);
    final batch = applyNewUndatedTask(task, active);
    for (final updated in batch.tasks) {
      await repo.upsertTask(updated);
      remoteSync.pushTodoTaskNow(updated);
    }
    await _deleteSubtask(subtask);
    widget.onChanged();
    final placed = batch.tasks.firstWhere((t) => t.id == task.id);
    logTodoSortDebug(
      ref.read(todoSortDebugLoggerProvider),
      'PROMOTE_SUBTASK',
      task: placed,
      details:
          'promoted subtask "${subtask.title}" (${subtask.id}) '
          'from parent ${widget.task.id} (${widget.task.title})',
    );
  }

  String _dueDateChangeDetails({
    required TodoTask previous,
    required TodoTask next,
    required bool clearDueDate,
  }) {
    if (clearDueDate) {
      final was = previous.dueDate?.toUtc().toIso8601String() ?? 'null';
      return 'cleared due date (was $was), sortOrder: ${previous.sortOrder} → ${next.sortOrder}';
    }
    final before = previous.dueDate?.toUtc().toIso8601String() ?? 'null';
    final after = next.dueDate?.toUtc().toIso8601String() ?? 'null';
    return 'due date: $before → $after, sortOrder: ${previous.sortOrder} → ${next.sortOrder}';
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

  Widget _buildHeader(BuildContext context, ThemeData theme, Color listColor) {
    Widget starButton() => IconButton(
      style: _compactIconButtonStyle,
      onPressed: widget.onToggleStar,
      icon: Icon(
        widget.task.starred
            ? PhosphorIconsFill.star
            : PhosphorIconsRegular.star,
      ),
      color: widget.task.starred ? listColor : null,
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
    final listColor = _listAccentColor;
    return EnterToSubmitScope(
      onSubmit: () => unawaited(_close()),
      child: Material(
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
                  focusNode: _titleFocusNode,
                  textInputAction: TextInputAction.next,
                  onSubmitted: _onTitleSubmitted,
                  onChanged: _scheduleTitleSave,
                  accentColor: listColor,
                  contentPadding: const EdgeInsets.fromLTRB(16, 16, 56, 16),
                ),
                if (widget.lists.isNotEmpty)
                  Positioned(
                    top: 0,
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
                    side: BorderSide(color: listColor.withValues(alpha: 0.7)),
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
              child: Listener(
                onPointerDown: (_) => _setNotesEditingFlag(true),
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
                  ref.read(remoteSyncServiceProvider).recordTodoNotesChange(
                        taskId: widget.task.id,
                        before: _lastNotesText,
                        after: value,
                      );
                  _lastNotesText = value;
                  _scheduleNotesSave(value);
                },
              ),
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
              child: ReorderableListView(
                buildDefaultDragHandles: false,
                onReorderItem: _reorderSubtasks,
                children: [
                  for (var i = 0; i < _subtasks.length; i++)
                    ReorderableDragStartListener(
                      key: ValueKey(_subtasks[i].id),
                      index: i,
                      child: _SubtaskRow(
                        subtask: _subtasks[i],
                        listColor: listColor,
                        onToggle: (completed) =>
                            _toggleSubtask(_subtasks[i], completed),
                        onRename: (title) =>
                            _renameSubtask(_subtasks[i], title),
                        onDelete: () => _deleteSubtask(_subtasks[i]),
                        onPromote: () => _promoteSubtask(_subtasks[i]),
                      ),
                    ),
                ],
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
                foregroundColor: Colors.white,
              ),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    ),
    );
  }
}

class _SubtaskRow extends StatefulWidget {
  const _SubtaskRow({
    required this.subtask,
    required this.onToggle,
    required this.onRename,
    required this.onDelete,
    required this.onPromote,
    required this.listColor,
  });

  final TodoTask subtask;
  final ValueChanged<bool> onToggle;
  final ValueChanged<String> onRename;
  final VoidCallback onDelete;
  final VoidCallback onPromote;
  final Color listColor;

  @override
  State<_SubtaskRow> createState() => _SubtaskRowState();
}

class _SubtaskRowState extends State<_SubtaskRow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _strikeProgress;
  late final TextEditingController _editController;
  late final FocusNode _editFocusNode;
  var _displayCompleted = false;
  var _animating = false;
  var _editing = false;

  @override
  void initState() {
    super.initState();
    _displayCompleted = widget.subtask.completed;
    _editController = TextEditingController(text: widget.subtask.title);
    _editFocusNode = FocusNode();
    _editFocusNode.addListener(_handleEditFocusChanged);
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
    if (_animating || _editing) return;
    if (oldWidget.subtask.title != widget.subtask.title) {
      _editController.text = widget.subtask.title;
    }
    if (oldWidget.subtask.completed != widget.subtask.completed) {
      _displayCompleted = widget.subtask.completed;
      _controller.value = widget.subtask.completed ? 1.0 : 0.0;
    }
  }

  @override
  void dispose() {
    _editFocusNode.removeListener(_handleEditFocusChanged);
    _editFocusNode.dispose();
    _editController.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _handleEditFocusChanged() {
    if (!_editFocusNode.hasFocus && _editing) {
      _finishEditing();
    }
  }

  void _startEditing() {
    setState(() {
      _editing = true;
      _editController.text = widget.subtask.title;
    });
    _editFocusNode.requestFocus();
  }

  void _finishEditing() {
    if (!_editing) return;
    setState(() => _editing = false);
    widget.onRename(_editController.text);
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
    final strikeColor = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: 0.55);
    final textStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(
      color: _displayCompleted ? strikeColor : null,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Checkbox(
            value: _displayCompleted,
            activeColor: widget.listColor,
            onChanged: _handleToggle,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final hoverColor = Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.06);
                return Stack(
                  clipBehavior: Clip.none,
                  children: [
                    if (_editing)
                      TextField(
                        controller: _editController,
                        focusNode: _editFocusNode,
                        style: textStyle,
                        maxLines: null,
                        decoration: const InputDecoration(
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(
                            vertical: 12,
                            horizontal: 12,
                          ),
                          border: InputBorder.none,
                        ),
                        onSubmitted: (_) => _finishEditing(),
                      )
                    else
                      Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: _startEditing,
                          borderRadius: BorderRadius.circular(14),
                          hoverColor: hoverColor,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              vertical: 12,
                              horizontal: 12,
                            ),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                widget.subtask.title,
                                style: textStyle,
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (_displayCompleted)
                      Positioned.fill(
                        child: IgnorePointer(
                          child: AnimatedBuilder(
                            animation: _strikeProgress,
                            builder: (context, _) {
                              return CustomPaint(
                                painter: _MultilineStrikePainter(
                                  text: widget.subtask.title,
                                  style: textStyle ?? const TextStyle(),
                                  progress:
                                      _strikeProgress.value.clamp(0.0, 1.0),
                                  color: strikeColor,
                                  textDirection: Directionality.of(context),
                                  maxWidth: constraints.maxWidth,
                                  textPadding: const EdgeInsets.symmetric(
                                    vertical: 12,
                                    horizontal: 12,
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
          PopupMenuButton<_SubtaskAction>(
            padding: EdgeInsets.zero,
            icon: Icon(
              PhosphorIconsBold.dotsThreeVertical,
              size: 18,
              color: Theme.of(context)
                  .colorScheme
                  .onSurface
                  .withValues(alpha: 0.72),
            ),
            onSelected: (action) {
              switch (action) {
                case _SubtaskAction.promote:
                  widget.onPromote();
                case _SubtaskAction.delete:
                  widget.onDelete();
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: _SubtaskAction.promote,
                child: Text('Promote to task'),
              ),
              PopupMenuItem(
                value: _SubtaskAction.delete,
                child: Text('Delete subtask'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

enum _SubtaskAction { promote, delete }

enum _HeaderAction { star, delete, close }

class _MultilineStrikePainter extends CustomPainter {
  _MultilineStrikePainter({
    required this.text,
    required this.style,
    required this.progress,
    required this.color,
    required this.textDirection,
    required this.maxWidth,
    this.textPadding = EdgeInsets.zero,
  });

  final String text;
  final TextStyle style;
  final double progress;
  final Color color;
  final TextDirection textDirection;
  final double maxWidth;
  final EdgeInsets textPadding;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: textDirection,
      maxLines: null,
    )..layout(maxWidth: maxWidth);

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
      final y = textPadding.top +
          line.baseline -
          line.ascent +
          line.height / 2;
      canvas.drawLine(
        Offset(line.left, y),
        Offset(line.left + drawWidth, y),
        paint,
      );
      remaining -= line.width;
    }
  }

  @override
  bool shouldRepaint(covariant _MultilineStrikePainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.text != text ||
        oldDelegate.color != color ||
        oldDelegate.maxWidth != maxWidth;
  }
}
