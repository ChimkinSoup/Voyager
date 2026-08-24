import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:voyager/core/vim/vim_enabled_scope.dart';
import 'package:voyager/core/vim/vim_text_overlay.dart';
import 'package:voyager/core/vim/vim_text_scope.dart';
import 'package:flutter/services.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/dev/todo_sort_debug_logger.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/pending_text_merge.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/sync/text_delta_injector.dart';
import 'package:voyager/core/sync/pending_flush_registry.dart';
import 'package:voyager/core/text/list_text_editing.dart';
import 'package:voyager/core/theme/voyager_menu_theme.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/utils/time_format.dart';
import 'package:voyager/domain/todo/todo_task_sorting.dart';
import 'package:voyager/core/widgets/confirm_dialog.dart';
import 'package:voyager/core/widgets/contextual_popover.dart';
import 'package:voyager/core/widgets/datetime_selector_popover.dart';
import 'package:voyager/core/widgets/datetime_picker_dialog.dart';
import 'package:voyager/core/widgets/selector_pill.dart';
import 'package:voyager/core/widgets/journal_color_flag.dart';
import 'package:voyager/core/widgets/enter_to_submit_scope.dart';
import 'package:voyager/core/widgets/field_scroll_padding.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/core/widgets/repeat_selector_popover.dart';
import 'package:voyager/domain/models/recurrence_rule.dart';
import 'package:voyager/core/widgets/clamp_to_target_bounds.dart';
import 'package:voyager/core/widgets/voyager_popup_menu_item.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/domain/services/recurrence_engine.dart';
import 'package:voyager/features/todo/todo_list_actions.dart';

class TodoEditPanel extends ConsumerStatefulWidget {
  const TodoEditPanel({
    super.key,
    required this.task,
    required this.onClose,
    required this.onChanged,
    required this.onDeleted,
    required this.onToggleStar,
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
  final GlobalKey _subtaskListKey = GlobalKey();
  DateTime? _dueDate;
  late RecurrenceRule _recurrence;
  bool _isRepeatPickerOpen = false;
  List<TodoTask> _subtasks = [];
  RemoteSyncService? _remoteSync;
  PendingTextMergeListener? _pendingTextMergeListener;
  late String _lastNonEmptyTitle;
  Timer? _titleSaveTimer;
  Timer? _notesSaveTimer;
  var _lastNotesText = '';

  late final Future<void> Function() _lifecycleFlushCallback;
  // Captured up front so a pending text edit can still be flushed from
  // dispose(), where `ref` is already off limits. Same pattern as
  // _TodoPageState's completion queue.
  late final ProviderContainer _container;

  @override
  void initState() {
    super.initState();
    _container = ProviderScope.containerOf(context, listen: false);
    _lifecycleFlushCallback = _lifecycleFlush;
    PendingFlushRegistry.instance.register(_lifecycleFlushCallback);
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
    _subtaskFocusNode.onKeyEvent = _handleSubtaskKey;
    _dueDate = widget.task.dueDate;
    _recurrence = widget.task.recurrence;
    _loadSubtasks();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _remoteSync = ref.read(remoteSyncServiceProvider);
      _registerPendingNotesListener(widget.task.id);
      _setNotesEditingFlag(_notesFocusNode.hasFocus);
      _beginEditingSession(_remoteSync!);
    });
  }

  /// Preloads the remote character-op chain for this task's notes. Best effort:
  /// if it never lands (offline, permission denied) the notes field still edits
  /// against a locally seeded session, so this must never gate the UI.
  void _beginEditingSession(RemoteSyncService remoteSync) {
    unawaited(
      remoteSync
          .prepareEditingSession(
            collection: FirestoreCollections.todoTasks,
            documentId: widget.task.id,
            initialText: _notesController.text,
          )
          .catchError((Object error) {
            debugPrint('Todo notes editing session failed to prepare: $error');
          }),
    );
  }

  bool _subtaskCreating = false;
  bool _isDatePickerOpen = false;

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
    _recurrence = widget.task.recurrence;
      _loadSubtasks();
      _registerPendingNotesListener(widget.task.id);
      _beginEditingSession(ref.read(remoteSyncServiceProvider));
    } else if (oldWidget.task.dueDate != widget.task.dueDate) {
      // Same task, but its due date changed externally (e.g. via the row's
      // right-click menu while this panel is open). Sync the locally-held
      // _dueDate so the pill updates instantly instead of only after the user
      // reselects the task.
      _dueDate = widget.task.dueDate;
    _recurrence = widget.task.recurrence;
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
    PendingFlushRegistry.instance.unregister(_lifecycleFlushCallback);
    // Flush, don't drop. Title and notes are debounced by _saveDebounce, and
    // _close() is only one of the ways this panel goes away: the page also
    // calls _closeEditPanel() when the list dropdown changes, when a list is
    // created or deleted, and when the task is deleted. Those start the 270ms
    // reverse animation and unmount this State at the end of it — under the
    // 400ms debounce — so cancelling here lost the edit outright. Typing a
    // title and immediately switching lists lost it every time.
    //
    // PendingFlushRegistry doesn't cover this: it only fires on app/window
    // lifecycle, and the shell keeps every page mounted, so nothing else runs.
    final hasPendingText =
        (_titleSaveTimer?.isActive ?? false) ||
        (_notesSaveTimer?.isActive ?? false);
    _titleSaveTimer?.cancel();
    _notesSaveTimer?.cancel();
    if (hasPendingText) {
      // Snapshot now — the controllers are disposed further down this method.
      unawaited(
        _savePendingText(
          taskId: widget.task.id,
          title: _titleController.text.trim(),
          notes: _notesController.text.trim(),
        ),
      );
    }
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

  void _handleNotesChanged(String value) {
    applyListEditing(
      controller: _notesController,
      previousText: _lastNotesText,
    );
    final updated = _notesController.text;
    final notes = updated.trim();
    widget.onTaskOptimistic?.call(
      notes.isEmpty
          ? widget.task.copyWith(clearNotes: true)
          : widget.task.copyWith(notes: notes),
    );
    ref
        .read(remoteSyncServiceProvider)
        .recordTodoNotesChange(
          taskId: widget.task.id,
          before: _lastNotesText,
          after: updated,
        );
    _lastNotesText = updated;
    _scheduleNotesSave(updated);
  }

  KeyEventResult _handleNotesKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.tab) {
      final outdent = HardwareKeyboard.instance.isShiftPressed;
      if (handleListTab(controller: _notesController, outdent: outdent)) {
        // Tab/Backspace mutate the controller directly, bypassing
        // TextField.onChanged — route through the same handler typing uses
        // so the edit gets saved and the CRDT character-op session (which
        // assumes `before` always matches its actual current text) doesn't
        // silently desync.
        _handleNotesChanged(_notesController.text);
        return KeyEventResult.handled;
      }
      if (!outdent) {
        _subtaskFocusNode.requestFocus();
        return KeyEventResult.handled;
      }
      // Nothing left to outdent. Swallow it rather than letting default
      // traversal run — backwards from here is whatever widget happens to sit
      // above the field, so Shift+Tab would kick the caret out of the notes
      // and onto the "Reset due date" button mid-edit.
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.backspace) {
      if (handleListBackspace(controller: _notesController)) {
        _handleNotesChanged(_notesController.text);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (event.logicalKey != LogicalKeyboardKey.enter) {
      return KeyEventResult.ignored;
    }
    if (HardwareKeyboard.instance.isShiftPressed) {
      return KeyEventResult.ignored;
    }
    if (isOnListLine(_notesController)) {
      // Let the newline through so list-continuation/clean-exit (wired via
      // onChanged) handles it, instead of closing the panel.
      return KeyEventResult.ignored;
    }
    unawaited(_close());
    return KeyEventResult.handled;
  }

  KeyEventResult _handleSubtaskKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.enter &&
        !HardwareKeyboard.instance.isShiftPressed) {
      _addSubtask();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _lifecycleFlush() async {
    await _save();
  }

  Future<void> _save({
    String? title,
    String? notes,
    DateTime? dueDate,
    RecurrenceRule? recurrence,
    bool clearDueDate = false,
    String? listId,
    bool reorderDueDate = false,
    // _close() passes false: the parent already re-invalidates the task
    // list itself once the close animation's dismissed status fires (see
    // TodoPage's _panelController status listener), so onChanged here would
    // just be a second, redundant full-list invalidation — one that, unlike
    // the deferred one, lands while the close animation is still playing
    // and competes with it for frame budget.
    bool notifyChanged = true,
  }) async {
    // Everything `_save` needs is read before the first await. _close() calls
    // this with unawaited() while starting a 270ms animation that ends in this
    // State being disposed, and _applyPendingNotesMerge is a network-backed
    // merge — slowest on exactly the offline/slow connections where it is most
    // likely to outlive the close. Afterwards `ref` would throw and the
    // controllers would be disposed.
    final repo = ref.read(todoRepositoryProvider);
    final remoteSync = ref.read(remoteSyncServiceProvider);
    final rawTitle = title ?? _titleController.text.trim();
    final rawNotes = notes ?? _notesController.text.trim();
    await _applyPendingNotesMerge();
    // The merge above may have rewritten the notes field; prefer its result
    // when this State is still alive to read it.
    final notesText = notes ?? (mounted ? _notesController.text.trim() : rawNotes);
    var titleText = rawTitle;
    if (titleText.isEmpty) {
      titleText = _lastNonEmptyTitle;
      if (mounted) _titleController.text = titleText;
    }

    // Rebase on the stored row rather than the page's snapshot. widget.task
    // can be arbitrarily stale — the page skips rebuilding the panel when a
    // change isn't sort-relevant — so a full-document write built from it
    // reverts whatever else landed while the panel was open.
    final stored = await repo.getTask(widget.task.id);
    // A missing row means the task was hard-deleted; writing would resurrect it.
    if (stored == null) return;

    final effectiveDue = clearDueDate ? null : (dueDate ?? _dueDate);
    final listMoved = listId != null && listId != widget.task.listId;
    final dueSortChanged =
        !widget.task.isSubtask &&
        (reorderDueDate || clearDueDate || effectiveDue != widget.task.dueDate);

    final effectiveRule = recurrence ?? _recurrence;
    // A manual reschedule re-anchors; an incidental save (a rename, a repeat
    // change) leaves the frozen anchor where it is. The reschedule half of that
    // policy is shared with the row's context menu — see
    // [rescheduledRecurrenceAnchor] for why the anchor may not simply follow
    // the due date.
    final rescheduled = dueDate != null || clearDueDate;
    final anchor = rescheduled
        ? rescheduledRecurrenceAnchor(rule: effectiveRule, newDue: effectiveDue)
        : (effectiveRule.repeats
              ? (stored.recurrenceAnchor ?? effectiveDue)
              : null);

    final baseUpdate = stored.copyWith(
      title: titleText,
      listId: listId,
      notes: notesText.isEmpty ? null : notesText,
      clearNotes: notesText.isEmpty,
      dueDate: effectiveDue,
      clearDueDate: clearDueDate,
      recurrence: effectiveRule,
      recurrenceAnchor: anchor,
      clearRecurrenceAnchor: anchor == null,
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
      // _close() calls _save() with no arguments on every close, including
      // ones where nothing was actually edited (just opening a task to look
      // at it) — without this check that unconditionally cost a local DB
      // write plus a Firestore push, right as the close animation started
      // playing, on every single close.
      final unchanged =
          titleText == widget.task.title &&
          (notesText.isEmpty
              ? widget.task.notes == null
              : notesText == widget.task.notes) &&
          effectiveDue == widget.task.dueDate &&
          effectiveRule == widget.task.recurrence &&
          anchor == widget.task.recurrenceAnchor;
      if (!unchanged) {
        await repo.upsertTask(baseUpdate);
        unawaited(
          remoteSync.flushDocument(
            FirestoreCollections.todoTasks,
            widget.task.id,
          ),
        );
        remoteSync.pushTodoTaskNow(baseUpdate);
      }
    }
    if (notifyChanged) widget.onChanged();
  }

  Future<void> _close() async {
    if (mounted) widget.onClose();
    // _save() writes both fields from the live controllers, so the debounced
    // timers have nothing left to contribute — retiring them here keeps
    // dispose() from issuing a second, redundant write for the same text.
    _titleSaveTimer?.cancel();
    _notesSaveTimer?.cancel();
    unawaited(_save(notifyChanged: false));
  }

  /// Writes debounced title/notes text that never made it to its timer.
  ///
  /// Reads through [_container] rather than `ref`, and re-reads the row before
  /// writing so this only ever changes the two fields it owns — a full-document
  /// write built from [widget.task] would undo anything else that landed while
  /// the panel was open.
  Future<void> _savePendingText({
    required String taskId,
    required String title,
    required String notes,
  }) async {
    final latest = await _container.read(todoRepositoryProvider).getTask(taskId);
    if (latest == null) return;
    final updated = latest.copyWith(
      title: title.isEmpty ? _lastNonEmptyTitle : title,
      notes: notes.isEmpty ? null : notes,
      clearNotes: notes.isEmpty,
    );
    await _container
        .read(remoteSyncServiceProvider)
        .saveTodoTaskThenScheduleUpload(updated);
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
    // One indexed lookup by primary key. This used to walk every list and
    // linear-scan its tasks — a query per list plus a scan, every 400ms while
    // the user types, to fetch a single row.
    final baseline = await repo.getTask(widget.task.id);
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
    // Re-read rather than building a full-document write from widget.task.
    // Notes are saved through _taskOverrides, and onTaskOptimistic's non-sort
    // branch deliberately skips setState when nothing sort-relevant changed —
    // so widget.task can hold pre-edit notes indefinitely, and writing it back
    // reverted notes the user had typed moments earlier.
    final latest = await ref.read(todoRepositoryProvider).getTask(widget.task.id);
    if (latest == null) return;
    await ref
        .read(remoteSyncServiceProvider)
        .saveTodoTaskThenScheduleUpload(latest.copyWith(title: title));
  }

  Future<void> _onTitleSubmitted(String value) async {
    if (mounted) _notesFocusNode.requestFocus();
    final title = value.trim();
    if (title.isEmpty) return;
    _titleSaveTimer?.cancel();
    final updated = widget.task.copyWith(title: title);
    widget.onTaskOptimistic?.call(updated);
    unawaited(_save(title: title));
  }

  Future<void> _moveToList(String listId) async {
    if (listId == widget.task.listId) return;
    final updated = widget.task.copyWith(listId: listId);
    widget.onTaskOptimistic?.call(updated);
    unawaited(_save(listId: listId));
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

  Future<void> _openRepeatPicker(BuildContext buttonContext) async {
    setState(() => _isRepeatPickerOpen = true);
    final rule = await showContextualPopover<RecurrenceRule>(
      context: context,
      buttonContext: buttonContext,
      width: kRepeatPopoverWidth,
      accentColor: _listAccentColor,
      builder: (ctx) => RepeatSelectorPopover(
        initialRule: _recurrence,
        anchor: (_dueDate ?? DateTime.now()).toLocal(),
        accentColor: _listAccentColor,
      ),
    );
    if (!mounted) return;
    setState(() {
      _isRepeatPickerOpen = false;
      if (rule != null) _recurrence = rule;
    });
    if (rule != null) {
      widget.onTaskOptimistic?.call(
        widget.task.copyWith(recurrence: rule),
      );
      unawaited(_save(recurrence: rule));
    }
  }

  Future<void> _clearDueDate() async {
    final hadDueDate = widget.task.dueDate != null;
    setState(() => _dueDate = null);
    widget.onTaskOptimistic?.call(widget.task.copyWith(clearDueDate: true));
    unawaited(_save(clearDueDate: true, reorderDueDate: hadDueDate));
  }

  Future<void> _addSubtask() async {
    final title = _subtaskController.text.trim();
    if (title.isEmpty) {
      _subtaskFocusNode.requestFocus();
      return;
    }
    _subtaskController.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _subtaskFocusNode.requestFocus();
    });

    final minSortOrder = _subtasks.isEmpty
        ? 0
        : _subtasks.map((e) => e.sortOrder).reduce(math.min);

    final now = utcNow();
    final subtask = TodoTask(
      id: newId(),
      listId: widget.task.listId,
      parentTaskId: widget.task.id,
      title: title,
      sortOrder: minSortOrder - 1,
      createdAt: now,
      updatedAt: now,
    );
    Future.delayed(const Duration(milliseconds: 50), () {
      if (!mounted) return;
      setState(() => _subtasks = [subtask, ..._subtasks]);
      ref.read(todoRepositoryProvider).upsertTask(subtask).then((_) {
        ref.read(remoteSyncServiceProvider).pushTodoTaskNow(subtask);
        widget.onChanged();
      });
    });
  }

  Future<void> _toggleSubtask(TodoTask subtask, bool completed) async {
    final updated = subtask.copyWith(completed: completed);
    setState(() {
      final index = _subtasks.indexWhere((s) => s.id == subtask.id);
      if (index != -1) _subtasks[index] = updated;
    });
    ref.read(todoRepositoryProvider).upsertTask(updated).then((_) {
      ref.read(remoteSyncServiceProvider).pushTodoTaskNow(updated);
      widget.onChanged();
    });
  }

  Future<void> _renameSubtask(TodoTask subtask, String title) async {
    final trimmed = title.trim();
    if (trimmed.isEmpty || trimmed == subtask.title) return;
    final updated = subtask.copyWith(title: title);
    setState(() {
      final index = _subtasks.indexWhere((s) => s.id == subtask.id);
      if (index != -1) _subtasks[index] = updated;
    });
    ref.read(todoRepositoryProvider).upsertTask(updated).then((_) {
      ref.read(remoteSyncServiceProvider).pushTodoTaskNow(updated);
      widget.onChanged();
    });
  }

  Future<void> _deleteSubtask(TodoTask subtask) async {
    final deleted = subtask.copyWith(deletedAt: utcNow());
    setState(() {
      _subtasks.removeWhere((s) => s.id == subtask.id);
    });
    ref.read(todoRepositoryProvider).upsertTask(deleted).then((_) {
      ref.read(remoteSyncServiceProvider).pushTodoTaskNow(deleted);
      widget.onChanged();
    });
  }

  void _reorderSubtasks(int oldIndex, int newIndex) {
    // onReorderItem already adjusts newIndex for the removed item at oldIndex,
    // so no manual correction is needed here (unlike the old onReorder API).
    if (oldIndex == newIndex) return;

    final subtasks = List<TodoTask>.from(_subtasks);
    final item = subtasks.removeAt(oldIndex);
    subtasks.insert(newIndex, item);

    final updates = <TodoTask>[];
    for (int i = 0; i < subtasks.length; i++) {
      if (subtasks[i].sortOrder != i) {
        updates.add(subtasks[i].copyWith(sortOrder: i));
        subtasks[i] = subtasks[i].copyWith(sortOrder: i);
      }
    }

    setState(() => _subtasks = subtasks);

    // Yield to the event loop so the UI updates immediately before we do
    // potentially blocking database operations.
    unawaited(
      Future.delayed(Duration.zero, () async {
        final repo = ref.read(todoRepositoryProvider);
        final remoteSync = ref.read(remoteSyncServiceProvider);
        for (final task in updates) {
          await repo.upsertTask(task);
          remoteSync.pushTodoTaskNow(task);
        }
        widget.onChanged();
      }),
    );
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
    unawaited(softDeleteTaskWithSubtasks(ref, widget.task));
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

  Widget _buildHeader(BuildContext context, ThemeData theme, Color listColor) {
    Widget starButton() => IconButton(
      onPressed: widget.onToggleStar,
      icon: Icon(
        widget.task.starred
            ? PhosphorIconsFill.star
            : PhosphorIconsRegular.star,
        color: widget.task.starred ? listColor : null,
      ),
      tooltip: widget.task.starred ? 'Unstar task' : 'Star task',
    );

    Widget deleteButton() => IconButton(
      onPressed: _deleteTask,
      icon: Icon(PhosphorIconsRegular.trash, color: theme.colorScheme.error),
      tooltip: 'Delete task',
    );

    Widget closeButton() => IconButton(
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
                    dense: true,
                    borderRadius: 12,
                    contentPadding: const EdgeInsets.fromLTRB(15, 15, 40, 15),
                  ),
                  if (widget.lists.isNotEmpty)
                    Positioned(
                      top: 0,
                      right: 10,
                      child: JournalTitleCornerFlag(
                        colorValue:
                            widget.listColor ??
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
              // The pill and the repeat toggle group on the left; "Reset due
              // date" is pushed to the right edge by the Expanded, so it reads
              // as the row's escape hatch rather than as a third setting.
              Row(
                children: [
                  Expanded(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Builder(
                            builder: (context) {
                              final localDue = _dueDate?.toLocal();
                              final hasTime =
                                  localDue != null &&
                                  (localDue.hour != 0 || localDue.minute != 0);
                              final label = localDue == null
                                  ? 'Set date & time'
                                  : DateFormat(
                                          'EEE, MMM d',
                                        ).format(_dueDate!.toLocal()) +
                                        (hasTime
                                            ? ' at ${formatTime12Hour(_dueDate!.toLocal())}'
                                            : '');

                              return SelectorPill(
                                dense: false,
                                isActive: _isDatePickerOpen,
                                label: label,
                                accentColor: listColor,
                                onTap: () async {
                                  setState(() => _isDatePickerOpen = true);

                                  final initialDt = _dueDate != null && hasTime
                                      ? _dueDate!.toLocal()
                                      : (_dueDate != null
                                            ? _dueDate!.toLocal().copyWith(
                                                hour: 12,
                                                minute: 0,
                                              ) // default time 12:00 PM if none
                                            : DateTime.now().toLocal());

                                  final pickedDt =
                                      await showContextualPopover<DateTime>(
                                        context: context,
                                        buttonContext: context,
                                        width: 500,
                                        height: 380,
                                        accentColor: listColor,
                                        builder: (ctx) => DateTimeSelectorPopover(
                                          initialDateTime: initialDt,
                                          accentColor: listColor,
                                          optionalTime: true,
                                          initialHasTime: hasTime,
                                        ),
                                      );

                                  if (mounted)
                                    setState(() => _isDatePickerOpen = false);

                                  if (pickedDt != null) {
                                    final newDue = pickedDt.toUtc();
                                    final previousDue = widget.task.dueDate;
                                    setState(() => _dueDate = newDue);
                                    widget.onTaskOptimistic?.call(
                                      widget.task.copyWith(
                                        dueDate: newDue,
                                        dueDateSetAt: utcNow(),
                                      ),
                                    );
                                    unawaited(
                                      _save(
                                        dueDate: newDue,
                                        reorderDueDate: previousDue != newDue,
                                      ),
                                    );
                                  }
                                },
                              );
                            },
                          ),
                        ),
                        const SizedBox(width: 4),
                        Builder(
                          builder: (buttonContext) => RepeatIconButton(
                            rule: _recurrence,
                            anchor: (_dueDate ?? DateTime.now()).toLocal(),
                            accentColor: listColor,
                            isOpen: _isRepeatPickerOpen,
                            // A repeat is measured from the due date, so
                            // without one there is nothing to repeat. The rule
                            // itself is left alone: clearing a due date parks
                            // the repeat rather than throwing it away, and
                            // setting a due date again lights it back up.
                            enabled: _dueDate != null,
                            disabledTooltip: 'Set a due date to repeat',
                            onPressed: () => _openRepeatPicker(buttonContext),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_dueDate != null) ...[
                    const SizedBox(width: 8),
                    GlassButton(
                      dense: true,
                      onPressed: _clearDueDate,
                      label: 'Reset due date',
                      textColor: listColor,
                    ),
                  ],
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
                    dense: true,
                    borderRadius: 12,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 15,
                      vertical: 15,
                    ),
                    onChanged: _handleNotesChanged,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Subtasks',
                style: theme.textTheme.titleSmall?.copyWith(color: listColor),
              ),
              const SizedBox(height: 8),
              // IntrinsicHeight so the "+" is exactly as tall as the field
              // rather than approximately so: the two have unrelated padding
              // rules, and stretch makes the shorter one follow the taller.
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: LabeledTextField(
                        label: '',
                        showLabel: false,
                        hintText: 'Add subtask',
                        controller: _subtaskController,
                        focusNode: _subtaskFocusNode,
                        accentColor: listColor,
                        dense: true,
                        borderRadius: 12,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 15,
                          vertical: 8,
                        ),
                        onSubmitted: (_) => _addSubtask(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    GlassButton(
                      dense: true,
                      onPressed: _addSubtask,
                      color: listColor,
                      iconColor: listColor,
                      icon: const Icon(PhosphorIconsRegular.plus),
                      tooltip: 'Add subtask',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Expanded(
                child: ReorderableListView(
                  key: _subtaskListKey,
                  cacheExtent: 10000.0,
                  buildDefaultDragHandles: false,
                  proxyDecorator: (child, index, animation) {
                    return ClampToTargetBounds(
                      targetKey: _subtaskListKey,
                      child: Material(
                        color: Colors.transparent,
                        borderRadius: BorderRadius.circular(14),
                        clipBehavior: Clip.antiAlias,
                        child: child,
                      ),
                    );
                  },
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
                          onSubmitRename: () {
                            _subtaskFocusNode.requestFocus();
                          },
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
              GlassButton(onPressed: _close, label: 'Save', color: listColor),
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
    required this.onSubmitRename,
    required this.listColor,
  });

  final TodoTask subtask;
  final ValueChanged<bool> onToggle;
  final ValueChanged<String> onRename;
  final VoidCallback onDelete;
  final VoidCallback onPromote;
  final VoidCallback onSubmitRename;
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
  var _editing = false;

  @override
  void initState() {
    super.initState();
    _displayCompleted = widget.subtask.completed;
    _editController = TextEditingController(text: widget.subtask.title);
    _editFocusNode = FocusNode();
    _editFocusNode.addListener(_handleEditFocusChanged);
    _editFocusNode.onKeyEvent = _handleEditKey;
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
    if (_editing) return;
    if (oldWidget.subtask.title != widget.subtask.title) {
      _editController.text = widget.subtask.title;
    }
    if (oldWidget.subtask.completed != widget.subtask.completed) {
      if (widget.subtask.completed != _displayCompleted) {
        _displayCompleted = widget.subtask.completed;
        _controller.value = widget.subtask.completed ? 1.0 : 0.0;
      }
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

  KeyEventResult _handleEditKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.enter &&
        !HardwareKeyboard.instance.isShiftPressed) {
      _finishEditing(focusNext: true);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _startEditing() {
    setState(() {
      _editing = true;
      _editController.text = widget.subtask.title;
      _editController.selection = TextSelection.collapsed(
        offset: widget.subtask.title.length,
      );
    });
    _editFocusNode.requestFocus();
  }

  void _finishEditing({bool focusNext = false}) {
    if (!_editing) return;
    setState(() => _editing = false);
    _editFocusNode.unfocus();
    if (focusNext) {
      widget.onSubmitRename();
      Future.delayed(const Duration(milliseconds: 150), () {
        if (mounted) widget.onRename(_editController.text);
      });
    } else {
      widget.onRename(_editController.text);
    }
  }

  void _handleToggle(bool? value) {
    if (value == null) return;
    if (value == _displayCompleted) return;

    setState(() {
      _displayCompleted = value;
    });
    widget.onToggle(value);

    if (value) {
      _controller.forward();
    } else {
      _controller.reverse();
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
          const SizedBox(width: 8),
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
                final hoverColor = Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.06);
                return Stack(
                  clipBehavior: Clip.none,
                  children: [
                    if (_editing)
                      VimTextScope(
                        enabled: VimEnabledScope.of(context) && vimSuitsField(),
                        controller: _editController,
                        multiline: false,
                        builder: (context, vim) {
                          final theme = Theme.of(context);
                          final fieldStyle = textStyle ?? const TextStyle();
                          const contentPadding = EdgeInsets.symmetric(
                            vertical: 12,
                            horizontal: 12,
                          );
                          return VimOverlayHost(
                            session: vim.session,
              snippetSession: vim.snippetSession,
                            overlayPaintsSelection: vim.overlayPaintsSelection,
                            controller: _editController,
                            focusNode: _editFocusNode,
                            style: fieldStyle,
                            accentColor: theme.colorScheme.primary,
                            overlayPadding: vimOverlayPadding(
                              contentPadding: contentPadding,
                              density: theme.visualDensity,
                              cursorWidth: vim.overlayCaretWidth,
                              outlineGap: true,
                              outlineCenter: true,
                            ),
                            child: TextField(
                              contextMenuBuilder:
                                  (context, editableTextState) =>
                                      const SizedBox.shrink(),
                              controller: _editController,
                              focusNode: _editFocusNode,
                              autofocus: true,
                              style: fieldStyle,
                              cursorColor: vim.overlayCaretColor(
                                theme.colorScheme.primary,
                              ),
                              cursorWidth: vim.overlayCaretWidth,
                              undoController: vim.undoController,
                              textInputAction: TextInputAction.done,
                              scrollPadding: kVoyagerFieldScrollPadding,
                              decoration: const InputDecoration(
                                isDense: true,
                                contentPadding: contentPadding,
                                border: InputBorder.none,
                              ),
                              onSubmitted: (_) =>
                                  _finishEditing(focusNext: true),
                            ),
                          );
                        },
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
                    if (_displayCompleted && !_editing)
                      Positioned.fill(
                        child: IgnorePointer(
                          child: AnimatedBuilder(
                            animation: _strikeProgress,
                            builder: (context, _) {
                              return CustomPaint(
                                painter: _MultilineStrikePainter(
                                  text: widget.subtask.title,
                                  style: textStyle ?? const TextStyle(),
                                  progress: _strikeProgress.value.clamp(
                                    0.0,
                                    1.0,
                                  ),
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
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.72),
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

    final layoutWidth = maxWidth - textPadding.horizontal;
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: textDirection,
      maxLines: null,
    )..layout(maxWidth: layoutWidth > 0 ? layoutWidth : 0);

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
      final y = textPadding.top + line.baseline - line.ascent + line.height / 2;
      canvas.drawLine(
        Offset(line.left + textPadding.left, y),
        Offset(line.left + textPadding.left + drawWidth, y),
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
