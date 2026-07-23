import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/constants/todo_constants.dart';
import 'package:voyager/core/dev/todo_sort_debug_logger.dart';
import 'package:voyager/core/effects/confetti.dart';
import 'package:voyager/core/sync/pending_flush_registry.dart';
import 'package:voyager/core/theme/voyager_list_item_surface.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/utils/time_format.dart';
import 'package:voyager/core/widgets/keep_alive_scroll.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/core/widgets/clamp_to_target_bounds.dart';
import 'package:voyager/core/widgets/rounded_dropdown.dart';
import 'package:voyager/core/widgets/voyager_menu_catalog.dart';
import 'package:voyager/core/widgets/context_menu.dart';
import 'package:voyager/core/widgets/confirm_dialog.dart';
import 'package:voyager/core/widgets/contextual_popover.dart';
import 'package:voyager/core/widgets/datetime_selector_popover.dart';
import 'package:voyager/core/widgets/journal_color_flag.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/todo/todo_task_sorting.dart';
import 'package:voyager/features/shell/shell_page_storage_keys.dart';
import 'package:voyager/features/sync/sync_conflict_banner.dart';
import 'package:voyager/features/todo/todo_edit_panel.dart';
import 'package:voyager/features/todo/todo_list_actions.dart';
import 'package:voyager/features/todo/todo_manage_sheet.dart';

const _todoEditPanelWidth = 420.0;
const _todoEditPanelDuration = Duration(milliseconds: 270);

/// How long a completion toggle's writes wait before running.
///
/// Measured from the moment the toggle commits, which is already 360ms into the
/// animation (the checkbox pop, then [_TaskRowState._exitDuration] collapsing
/// the row out). What's left to clear is the confetti: [ConfettiEffect.duration]
/// runs 1100ms from the click, so ~740ms remains, and the burst is at its most
/// fragile at the end where every particle is still being painted and faded.
/// This waits that out with slack to spare.
const _todoCompletionSaveDelay = Duration(milliseconds: 900);

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
  final GlobalKey _taskListKey = GlobalKey();
  // Local override for the completed-section expand state. Null means "use the
  // persisted setting"; a non-null value reflects a toggle in this session for
  // immediate responsiveness before the settings stream updates. The persisted
  // value lives device-locally in settings (see [_persistCompletedExpanded]).
  bool? _completedExpandedOverride;
  var _showAllTasks = false;
  // Cache subtask stats futures by task ID to avoid re-querying the DB on
  // every rebuild (e.g. during drag-to-scroll), which would cause
  // FutureBuilder to restart and create visible jank.
  final _subtaskStatsCache = <String, Future<({int completed, int total})>>{};
  // Stores the last resolved result so FutureBuilders can use it as
  // initialData — preventing a blank frame on widget remount after reorder.
  final _subtaskResultsCache = <String, ({int completed, int total})>{};
  // The task whose completion was just toggled. Its row in the section it moved
  // into grows itself in instead of appearing at full height. Live for exactly
  // one build (see [_toggleTask]).
  String? _enteringTaskId;
  // Completion toggles whose writes are still waiting out the row's move
  // animation (see [_schedulePersistTaskCompletion]). Keyed by task id, so a
  // task toggled twice inside the window only writes the state it ended on.
  final _pendingCompletionSaves = <String, TodoTask>{};
  Timer? _completionSaveTimer;
  // Captured up front so pending writes can still be flushed from dispose(),
  // where `ref` is already off limits.
  late final ProviderContainer _container;

  @override
  void initState() {
    super.initState();
    _container = ProviderScope.containerOf(context, listen: false);
    // Deferred toggles must reach disk before the window closes.
    PendingFlushRegistry.instance.register(_flushPendingCompletionSaves);
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
    final savedId = ref
        .read(settingsProvider)
        .valueOrNull
        ?.lastViewedTodoListId;
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

  Future<void> _persistCompletedExpanded(bool expanded) async {
    final settingsRepo = ref.read(settingsRepositoryProvider);
    final settings = await settingsRepo.getSettings();
    if (settings.todoCompletedSectionExpanded == expanded) return;
    await settingsRepo.saveSettings(
      settings.copyWith(todoCompletedSectionExpanded: expanded),
    );
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
    // Don't strand a deferred toggle: it hasn't been written yet, and the
    // providers it refreshes are kept alive app-wide (the calendar reads task
    // markers off allTodoTasksProvider), so both would outlive this page.
    PendingFlushRegistry.instance.unregister(_flushPendingCompletionSaves);
    unawaited(_flushPendingCompletionSaves());
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
    final remoteSync = ref.read(remoteSyncServiceProvider);
    final now = utcNow();
    final task = TodoTask(
      id: newId(),
      listId: _selectedListId!,
      title: _taskController.text.trim(),
      createdAt: now,
      updatedAt: now,
    );
    final siblings = await repo.listTasks(_selectedListId!);
    final active = activeTopLevelTasks(siblings);
    final batch = applyNewUndatedTask(task, active);
    final placed = batch.tasks.firstWhere((t) => t.id == task.id);

    // Paint the optimistic result and clear the input immediately, before
    // touching the database. A new undated task snaps to the top of the undated
    // section, so applyNewUndatedTask reindexes every active task — the batch
    // grows with the list. Persisting it up-front made every keystroke wait on
    // all those writes, which is what made rapid adds lag. The exact same
    // upserts + remote pushes still run below, one frame later.
    setState(() {
      _applySortBatchOptimistic(batch, [...active, task]);
    });
    _taskController.clear();
    _taskFocusNode.requestFocus();

    logTodoSortDebug(
      ref.read(todoSortDebugLoggerProvider),
      'NEW_TASK',
      task: placed,
      details: 'listId=${task.listId} sortOrder: 0 → ${placed.sortOrder}',
    );

    // Yield to the event loop so the optimistic frame renders before we hit the
    // database (mirrors _reorderActiveTasks).
    await Future<void>.delayed(Duration.zero);
    for (final updated in batch.tasks) {
      await repo.upsertTask(updated);
      remoteSync.pushTodoTaskNow(updated);
    }
    if (!mounted) return;
    // Targeted invalidation (mirrors _persistSortBatch / _persistTaskCompletion)
    // instead of the broad _invalidateTodoListData(): adding a task only changes
    // this list's ordering and the list counts. Do NOT invalidate
    // todoListsProvider (list metadata is unchanged) and do NOT clear the
    // subtask cache — a new task has no subtasks and existing tasks' subtask
    // counts are untouched, so preserving it stops every visible row from
    // restarting its FutureBuilder (and re-querying the DB) on each add.
    ref.invalidate(todoTasksProvider(task.listId));
    ref.invalidate(allTodoTasksProvider);
    ref.invalidate(todoListStatsProvider);
  }

  Future<void> _toggleTask(
    TodoTask task,
    bool? completed,
    List<TodoTask> activeInList,
  ) async {
    final value = completed ?? false;
    // Uncompleting snaps the task back to the top of its section, renumbering
    // everything below it. With the write deferred, the row would otherwise
    // re-enter at the stale sort order it carried into the completed section
    // and only jump into place when the write lands — so place it optimistically
    // now, the same way the star and due-date menus do.
    final placement = value
        ? null
        : applyTaskUncomplete(task.copyWith(completed: false), activeInList);
    setState(() {
      _enteringTaskId = task.id;
      _completionOverrides[task.id] = value;
      if (value) {
        _optimisticActiveTaskOrder?.remove(task.id);
        if (_optimisticActiveTaskOrder?.isEmpty ?? false) {
          _optimisticActiveTaskOrder = null;
        }
      } else if (placement != null) {
        _applySortBatchOptimistic(placement, activeInList);
      }
    });
    // Consumed by the row built for this task in the section it just moved to,
    // during the build this setState schedules. Cleared straight after so the
    // row doesn't replay the animation every time it is rebuilt (scrolling it
    // out of the cache extent and back would otherwise re-run it). No setState:
    // nothing on screen reads this outside of row construction.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _enteringTaskId != task.id) return;
      _enteringTaskId = null;
    });
    _schedulePersistTaskCompletion(task.copyWith(completed: value));
  }

  /// Holds a toggle's writes until the completion animation has settled.
  ///
  /// Everything this defers costs the UI isolate time it doesn't have while the
  /// row is collapsing out of one section and growing into the other with the
  /// confetti burst painting over the top: the local write and the Firestore
  /// push both marshal the task off this isolate, and the provider refresh that
  /// follows re-reads every list and rebuilds the page around it. Nothing on
  /// screen is waiting for any of it — [_toggleTask]'s entry in
  /// [_completionOverrides] already shows the task on the correct side until the
  /// fresh data arrives and [_reconcileCompletionOverrides] drops it.
  ///
  /// Toggles landing during the wait extend it and flush together. The queue is
  /// also drained on dispose and, through [PendingFlushRegistry], before the
  /// window closes, so no more than [_todoCompletionSaveDelay] of toggles is
  /// ever unwritten.
  void _schedulePersistTaskCompletion(TodoTask updated) {
    _pendingCompletionSaves[updated.id] = updated;
    _completionSaveTimer?.cancel();
    _completionSaveTimer = Timer(
      _todoCompletionSaveDelay,
      () => unawaited(_flushPendingCompletionSaves()),
    );
  }

  Future<void> _flushPendingCompletionSaves() async {
    _completionSaveTimer?.cancel();
    _completionSaveTimer = null;
    if (_pendingCompletionSaves.isEmpty) return;
    final pending = _pendingCompletionSaves.values.toList();
    _pendingCompletionSaves.clear();

    final touchedLists = await _writeCompletionBatch(pending);
    if (touchedLists.isEmpty) return;

    // One refresh for the whole batch. Refreshing per task would re-read every
    // list and rebuild the page once for each one — completing two tasks back
    // to back paid for all of that twice.
    //
    // Completing/uncompleting a task only moves it between the active and
    // completed sections and shifts list counts — it never changes any task's
    // notes, due date, or subtask totals. Do a minimal, targeted invalidation
    // (mirroring _persistSortBatch) instead of the broad _invalidateTodoListData():
    // reloading todoListsProvider rebuilds the whole page, and clearing the
    // subtask cache restarts the FutureBuilders — both make the surviving rows
    // flash their subtext away for a frame. Keep allTodoTasksProvider fresh for
    // the "All tasks" view and calendar markers; the current single-list view
    // doesn't watch it, so that invalidation can't flicker it.
    for (final listId in touchedLists) {
      _container.invalidate(todoTasksProvider(listId));
    }
    _container.invalidate(allTodoTasksProvider);
    _container.invalidate(todoListStatsProvider);
  }

  /// Writes a batch of queued toggles, returning the lists they touched.
  ///
  /// Resolves the whole batch to its final shape before writing anything, so
  /// every row is written exactly once no matter how many toggles are in it.
  /// That matters for uncompleting: each one snaps its task back to the top of
  /// its section and renumbers everything below, so handling them one at a time
  /// — re-reading the list and recomputing the placement per task — rewrites and
  /// re-pushes every row in the list once per uncompleted task. Two of them back
  /// to back was two full-list write storms, which is what stuttered.
  Future<Set<String>> _writeCompletionBatch(List<TodoTask> pending) async {
    // Read through the container, not `ref`: a flush from dispose() outlives
    // the widget.
    final repo = _container.read(todoRepositoryProvider);
    final remoteSync = _container.read(remoteSyncServiceProvider);

    // Anything else that wrote these tasks while the toggles were waiting (a
    // rename or a star from the context menu) is already on disk, and the
    // snapshots taken back at toggle time would undo it. Re-read and carry over
    // only the completion. A missing row means the task was hard-deleted in the
    // meantime — writing would resurrect it.
    final resolved = <TodoTask>[];
    for (final task in pending) {
      final latest = await repo.getTask(task.id);
      if (latest == null) continue;
      resolved.add(latest.copyWith(completed: task.completed));
    }
    if (resolved.isEmpty) return const {};

    final touchedLists = <String>{};
    // Final state per row. Keyed by id so the placement passes below can revise
    // a row without queueing a second write for it.
    final writes = <String, TodoTask>{};

    // Completions are flag-only — they don't disturb the active ordering.
    final completedIds = <String>{};
    for (final task in resolved.where((task) => task.completed)) {
      writes[task.id] = task;
      completedIds.add(task.id);
      touchedLists.add(task.listId);
    }

    // Uncompletions have to be composed against one evolving picture of each
    // list rather than against disk, so a run of them lands as a single
    // renumbering instead of one per task.
    final activeByList = <String, Map<String, TodoTask>>{};
    for (final task in resolved.where((task) => !task.completed)) {
      var active = activeByList[task.listId];
      if (active == null) {
        final siblings = await repo.listTasks(task.listId);
        active = {
          for (final sibling in activeTopLevelTasks(siblings))
            // Tasks this same batch is completing are on their way out of the
            // active section; placing around them would renumber against a
            // picture that is about to be wrong.
            if (!completedIds.contains(sibling.id)) sibling.id: sibling,
        };
        activeByList[task.listId] = active;
      }
      final batch = applyTaskUncomplete(task, active.values.toList());
      for (final row in batch.tasks) {
        final toSave = row.id == task.id
            ? row.copyWith(completed: false)
            : row;
        writes[toSave.id] = toSave;
        active[toSave.id] = toSave;
      }
      touchedLists.add(task.listId);
    }

    for (final task in writes.values) {
      await repo.upsertTask(task);
      remoteSync.pushTodoTaskNow(task);
      // Hand the isolate back between rows: a placement batch is routinely the
      // whole list, and run as one chain it holds the isolate through N writes
      // and 2N Firestore pushes — long enough to drop frames on its own,
      // whatever else is on screen.
      await Future<void>.delayed(Duration.zero);
    }

    return touchedLists;
  }

  void _maybeNormalizeListSort(List<TodoTask> tasks, String listId) {
    if (_showAllTasks) return;
    final active = activeTopLevelTasks(
      _tasksWithOverrides(tasks, viewingListId: listId),
    );
    final batch = applyNormalizeUnstarredIfNeeded(active);
    if (batch == null) return;
    unawaited(_persistSortBatch(batch, listId));
  }

  List<TodoTask> _tasksWithOverrides(
    List<TodoTask> tasks, {
    String? viewingListId,
    bool showAllTasks = false,
  }) {
    if (_completionOverrides.isEmpty && _taskOverrides.isEmpty) {
      return tasks;
    }

    final byId = <String, TodoTask>{for (final task in tasks) task.id: task};

    for (final entry in _taskOverrides.entries) {
      if (byId.containsKey(entry.key)) {
        byId[entry.key] = entry.value;
      }
    }

    if (!showAllTasks && viewingListId != null) {
      byId.removeWhere((_, task) => task.listId != viewingListId);

      for (final override in _taskOverrides.values) {
        if (byId.containsKey(override.id)) continue;
        if (override.isSubtask) continue;
        if (override.listId == viewingListId) {
          byId[override.id] = override;
        }
      }
    } else if (showAllTasks) {
      for (final override in _taskOverrides.values) {
        if (byId.containsKey(override.id)) continue;
        if (override.isSubtask) continue;
        byId[override.id] = override;
      }
    }

    return [
      for (final task in byId.values)
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
        persisted.dueDateSetAt == override.dueDateSetAt &&
        persisted.completed == override.completed &&
        persisted.starred == override.starred &&
        persisted.sortOrder == override.sortOrder &&
        persisted.preStarSortOrder == override.preStarSortOrder &&
        persisted.listId == override.listId;
  }

  Future<void> _persistSortBatch(TodoSortBatch batch, String listId) async {
    if (batch.tasks.isEmpty) return;
    final repo = ref.read(todoRepositoryProvider);
    final remoteSync = ref.read(remoteSyncServiceProvider);
    for (final task in batch.tasks) {
      await repo.upsertTask(task);
      remoteSync.pushTodoTaskNow(task);
    }
    if (!mounted) return;
    // A sort batch only changes sortOrder within one list — do a minimal,
    // targeted invalidation. Do NOT invalidate todoListsProvider or
    // allTodoTasksProvider; those trigger broad provider reloads that cause
    // unrelated task rows to flicker their subtext.
    ref.invalidate(todoTasksProvider(listId));
    ref.invalidate(todoListStatsProvider);
    // Subtask cache is unaffected by a reorder — keep it so FutureBuilders
    // don't restart and flash the subtask count badge.
  }

  void _applySortBatchOptimistic(
    TodoSortBatch batch,
    List<TodoTask> activeTasks,
  ) {
    final byId = {for (final task in activeTasks) task.id: task};
    for (final task in batch.tasks) {
      byId[task.id] = task;
      _taskOverrides[task.id] = task;
    }
    _optimisticActiveTaskOrder = sortTodoTasks(
      byId.values,
    ).map((task) => task.id).toList();
  }

  Future<void> _applyPersistedSortBatchToUi(
    TodoSortBatch batch, {
    required String reason,
    TodoTask? focusTask,
  }) async {
    if (batch.tasks.isEmpty) return;
    final listId = batch.tasks.first.listId;
    final repo = ref.read(todoRepositoryProvider);
    final siblings = await repo.listTasks(listId);
    final active = activeTopLevelTasks(siblings);
    if (!mounted) return;

    final naturalOrder = sortTodoTasks(active).map((task) => task.id).toList();
    final staleOrder = _optimisticActiveTaskOrder;
    final hadStaleForcedOrder =
        staleOrder != null &&
        staleOrder.length == active.length &&
        staleOrder.every(naturalOrder.contains) &&
        !_orderIdsMatchSortOrder(staleOrder, active);

    setState(() {
      _optimisticActiveTaskOrder = null;
      _applySortBatchOptimistic(batch, active);
      if (focusTask != null) {
        final updated = batch.tasks.cast<TodoTask?>().firstWhere(
          (task) => task!.id == focusTask.id,
          orElse: () => null,
        );
        if (updated != null) {
          _editPanelTask = updated.copyWith(
            title: focusTask.title,
            notes: focusTask.notes,
          );
        }
      }
    });

    if (hadStaleForcedOrder) {
      logTodoSortDebug(
        ref.read(todoSortDebugLoggerProvider),
        'UI_ORDER_MISMATCH',
        task: focusTask,
        details:
            '$reason: cleared stale forced order '
            '(was ${staleOrder.join(", ")}, '
            'natural ${naturalOrder.join(", ")})',
      );
    }
    logTodoSortDebug(
      ref.read(todoSortDebugLoggerProvider),
      'UI_SORT_APPLIED',
      task: focusTask,
      details: '$reason listId=$listId',
    );
  }

  bool _orderIdsMatchSortOrder(List<String> order, List<TodoTask> tasks) {
    final natural = sortTodoTasks(tasks).map((task) => task.id).toList();
    if (order.length != natural.length) return false;
    for (var i = 0; i < order.length; i++) {
      if (order[i] != natural[i]) return false;
    }
    return true;
  }

  Future<void> _toggleStar(TodoTask task, List<TodoTask> activeTasks) async {
    final batch = applyStarToggle(task, activeTasks);
    setState(() {
      _applySortBatchOptimistic(batch, activeTasks);
    });
    final updated = batch.tasks.firstWhere(
      (t) => t.id == task.id,
      orElse: () => task,
    );
    await _persistSortBatch(batch, task.listId);
    logTodoSortDebug(
      ref.read(todoSortDebugLoggerProvider),
      'STAR_TOGGLE',
      task: updated,
      details:
          'starred: ${task.starred} → ${updated.starred}, '
          'sortOrder: ${task.sortOrder} → ${updated.sortOrder}',
    );
  }

  /// Sets (or replaces) a task's due date from the right-click menu. [localDue]
  /// is a local wall-clock time; a date-only selection arrives as local
  /// midnight (hour/minute == 0), matching the edit panel's picker contract.
  Future<void> _setTaskDueDate(
    TodoTask task,
    DateTime localDue,
    List<TodoTask> activeInList,
  ) async {
    final due = localDue.toUtc();
    if (task.dueDate == due) return;
    final batch = applyDueDateChange(
      task,
      activeInList,
      dueDate: due,
      clearDueDate: false,
    );
    setState(() {
      _applySortBatchOptimistic(batch, activeInList);
      if (_editPanelTask?.id == task.id) {
        _editPanelTask = batch.tasks.cast<TodoTask?>().firstWhere(
          (t) => t!.id == task.id,
          orElse: () => _editPanelTask,
        );
      }
    });
    await _persistSortBatch(batch, task.listId);
    final updated = batch.tasks.firstWhere(
      (t) => t.id == task.id,
      orElse: () => task,
    );
    logTodoSortDebug(
      ref.read(todoSortDebugLoggerProvider),
      'DUE_DATE_CHANGED',
      task: updated,
      details: 'right-click set due ${due.toIso8601String()}',
    );
  }

  /// Clears a task's due date from the right-click menu, re-slotting it into the
  /// undated ordering (mirrors the edit panel's "Reset due date").
  Future<void> _clearTaskDueDate(
    TodoTask task,
    List<TodoTask> activeInList,
  ) async {
    if (task.dueDate == null) return;
    final batch = applyDueDateChange(
      task,
      activeInList,
      dueDate: null,
      clearDueDate: true,
    );
    setState(() {
      _applySortBatchOptimistic(batch, activeInList);
      if (_editPanelTask?.id == task.id) {
        _editPanelTask = batch.tasks.cast<TodoTask?>().firstWhere(
          (t) => t!.id == task.id,
          orElse: () => _editPanelTask,
        );
      }
    });
    await _persistSortBatch(batch, task.listId);
    final updated = batch.tasks.firstWhere(
      (t) => t.id == task.id,
      orElse: () => task,
    );
    logTodoSortDebug(
      ref.read(todoSortDebugLoggerProvider),
      'DUE_DATE_CLEARED',
      task: updated,
      details: 'right-click cleared due date',
    );
  }

  /// Moves a task to another list from the right-click menu, placing it into the
  /// destination list's star/due ordering. The current view is left as-is; the
  /// task simply leaves the source list.
  Future<void> _moveTaskToList(TodoTask task, String destListId) async {
    if (destListId == task.listId) return;
    final repo = ref.read(todoRepositoryProvider);
    final remoteSync = ref.read(remoteSyncServiceProvider);
    final sourceListId = task.listId;
    final destSiblings = await repo.listTasks(destListId);
    final destActive = activeTopLevelTasks(destSiblings);
    if (!mounted) return;

    final moved = task.copyWith(listId: destListId);
    final batch = applyTaskListMove(moved, destActive);
    final placed = batch.tasks.firstWhere(
      (t) => t.id == task.id,
      orElse: () => moved,
    );

    setState(() {
      _optimisticActiveTaskOrder = null;
      _applySortBatchOptimistic(batch, [...destActive, moved]);
      _taskOverrides[task.id] = placed;
      if (_editPanelTask?.id == task.id) {
        _editPanelTask = placed;
      }
    });

    for (final t in batch.tasks) {
      await repo.upsertTask(t);
      remoteSync.pushTodoTaskNow(t);
    }
    if (!mounted) return;
    ref.invalidate(todoTasksProvider(sourceListId));
    ref.invalidate(todoTasksProvider(destListId));
    ref.invalidate(allTodoTasksProvider);
    ref.invalidate(todoListStatsProvider);
    logTodoSortDebug(
      ref.read(todoSortDebugLoggerProvider),
      'LIST_MOVE',
      task: placed,
      details: 'right-click move from $sourceListId to $destListId',
    );
  }

  /// Soft-deletes a task from the right-click menu after a confirmation dialog,
  /// matching the delete flow used by the edit panel and journal entries.
  Future<void> _deleteTaskFromRow(TodoTask task) async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Delete task?',
      message: '"${task.title}" will be moved to trash.',
    );
    if (!confirmed || !mounted) return;
    final deleted = task.copyWith(deletedAt: utcNow());
    final repo = ref.read(todoRepositoryProvider);
    final remoteSync = ref.read(remoteSyncServiceProvider);
    setState(() {
      _optimisticActiveTaskOrder?.remove(task.id);
      _taskOverrides.remove(task.id);
      _completionOverrides.remove(task.id);
      if (_editPanelTask?.id == task.id) {
        _closeEditPanel();
      }
    });
    await repo.upsertTask(deleted);
    await remoteSync.pushTodoTaskNow(deleted);
    if (!mounted) return;
    _invalidateTodoListData(listId: task.listId);
  }

  Future<({int completed, int total})> _subtaskStats(String taskId) {
    return _subtaskStatsCache.putIfAbsent(taskId, () async {
      final subtasks = await ref
          .read(todoRepositoryProvider)
          .listSubtasks(taskId);
      final result = (
        completed: subtasks.where((s) => s.completed).length,
        total: subtasks.length,
      );
      // Store the result so it can be used as FutureBuilder.initialData,
      // preventing a blank frame when _TaskRow is remounted after a reorder.
      _subtaskResultsCache[taskId] = result;
      return result;
    });
  }

  ({int completed, int total})? _subtaskStatsData(String taskId) =>
      _subtaskResultsCache[taskId];

  void _invalidateTodoListData({
    String? listId,
    bool preserveSubtaskCache = false,
  }) {
    ref.invalidate(todoTasksProvider);
    if (listId != null) {
      ref.invalidate(todoTasksProvider(listId));
    }
    ref.invalidate(allTodoTasksProvider);
    ref.invalidate(todoListsProvider);
    ref.invalidate(todoListStatsProvider);
    if (!preserveSubtaskCache) {
      // Subtask counts may have changed; clear the cached futures so the next
      // build fetches fresh data.
      _subtaskStatsCache.clear();
      _subtaskResultsCache.clear();
    }
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

  Future<void> _createListFromDropdown() async {
    final created = await createTodoList(context, ref);
    if (!mounted || created == null) return;
    await ref.read(todoListsProvider.future);
    if (!mounted) return;
    setState(() {
      _selectedListId = created.id;
      _showAllTasks = false;
    });
    _closeEditPanel();
    _markListViewed(created.id);
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
                  orElse: () =>
                      updatedLists.isNotEmpty ? updatedLists.first : null,
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

  Future<void> _applyListMoveOptimistic({
    required TodoTask task,
    required TodoTask panelTask,
    required List<TodoTask> active,
  }) async {
    final repo = ref.read(todoRepositoryProvider);
    final destSiblings = await repo.listTasks(task.listId);
    final destActive = activeTopLevelTasks(destSiblings);
    if (!mounted) return;

    final batch = applyTaskListMove(
      panelTask.copyWith(
        listId: task.listId,
        dueDate: task.dueDate ?? panelTask.dueDate,
        dueDateSetAt: task.dueDateSetAt ?? panelTask.dueDateSetAt,
        starred: task.starred,
      ),
      destActive,
    );
    final sortedTask = batch.tasks.firstWhere(
      (updated) => updated.id == task.id,
      orElse: () => task,
    );
    final merged = sortedTask.copyWith(
      title: task.title,
      notes: task.notes,
      listId: task.listId,
    );
    setState(() {
      _optimisticActiveTaskOrder = null;
      _applySortBatchOptimistic(batch, [...destActive, panelTask]);
      _taskOverrides[task.id] = merged;
      _editPanelTask = merged;
      _selectedTaskId = task.id;
    });
  }

  Future<void> _reorderActiveTasks(
    List<TodoTask> active,
    int oldIndex,
    int newIndex,
  ) async {
    final batch = applyReorder(active, oldIndex, newIndex);
    if (batch == null) return;

    final moved = active[oldIndex];
    setState(() {
      _applySortBatchOptimistic(batch, active);
    });
    // Yield to the event loop so the optimistic UI updates render first,
    // before we hit the database and potentially block the frame.
    unawaited(
      Future.delayed(Duration.zero, () async {
        await _persistSortBatch(batch, _selectedListId!);
        final updated = batch.tasks.firstWhere(
          (t) => t.id == moved.id,
          orElse: () => moved,
        );
        logTodoSortDebug(
          ref.read(todoSortDebugLoggerProvider),
          'MANUAL_REORDER',
          task: updated,
          details:
              'listId=${_selectedListId!} oldIndex=$oldIndex newIndex=$newIndex, '
              'sortOrder: ${moved.sortOrder} → ${updated.sortOrder}',
        );
      }),
    );
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
    final completedExpanded =
        _completedExpandedOverride ??
        settings?.todoCompletedSectionExpanded ??
        true;
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
            _maybeNormalizeListSort(tasks, listId);
            final sorted = sortTodoTasks(
              _tasksWithOverrides(
                tasks,
                viewingListId: listId,
                showAllTasks: _showAllTasks,
              ),
            );
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

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SyncConflictBanner(),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: RoundedDropdown<String>(
                                      value: listId,
                                      displayLabel: _showAllTasks
                                          ? 'All tasks'
                                          : null,
                                      labelColor: Color(
                                        _showAllTasks
                                            ? Theme.of(
                                                context,
                                              ).colorScheme.primary.toARGB32()
                                            : currentList?.colorValue ??
                                                  Theme.of(context)
                                                      .colorScheme
                                                      .primary
                                                      .toARGB32(),
                                      ),
                                      closedTrailing: _showAllTasks
                                          ? null
                                          : '${active.length} | ${completed.length}',
                                      onAddList: () =>
                                          unawaited(_createListFromDropdown()),
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
                                      items: lists.map((l) {
                                        final stat = _statsForList(
                                          l.id,
                                          stats,
                                          activeCount: active.length,
                                          completedCount: completed.length,
                                        );
                                        return RoundedDropdownItem(
                                          value: l.id,
                                          label: l.name,
                                          labelColor: Color(
                                            l.colorValue ??
                                                Theme.of(context)
                                                    .colorScheme
                                                    .primary
                                                    .toARGB32(),
                                          ),
                                          trailing:
                                              '${stat.active} | ${stat.completed}',
                                        );
                                      }).toList(),
                                      onChanged: (v) {
                                        setState(() {
                                          _selectedListId = v;
                                          _optimisticActiveTaskOrder = null;
                                        });
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
                                              lists.any(
                                                (l) => l.id == listId,
                                              )) {
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
                                      color: _showAllTasks
                                          ? Colors.black
                                          : null,
                                    ),
                                    style: IconButton.styleFrom(
                                      backgroundColor: _showAllTasks
                                          ? Theme.of(
                                              context,
                                            ).colorScheme.primary
                                          : null,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Expanded(
                                child: KeepAliveCustomScrollView(
                                  storageKey: ShellPageStorageKeys.todoTaskList,
                                  cacheExtent: 10000.0,
                                  slivers: [
                                    if (active.isNotEmpty)
                                      if (_showAllTasks)
                                        SliverList(
                                          delegate: SliverChildListDelegate([
                                            for (final task in active)
                                              _TaskRow(
                                                key: ValueKey(task.id),
                                                task: task,
                                                animateIn:
                                                    task.id == _enteringTaskId,
                                                isSelected:
                                                    task.id == _selectedTaskId,
                                                listColor: _listColorFor(
                                                  task.listId,
                                                  lists,
                                                ),
                                                lists: lists,
                                                subtaskStats: _subtaskStats(
                                                  task.id,
                                                ),
                                                subtaskStatsData:
                                                    _subtaskStatsData(task.id),
                                                onToggle: (v) => _toggleTask(
                                                  task,
                                                  v,
                                                  _activeInList(
                                                    active,
                                                    task.listId,
                                                  ),
                                                ),
                                                onStar: () => _toggleStar(
                                                  task,
                                                  _activeInList(
                                                    active,
                                                    task.listId,
                                                  ),
                                                ),
                                                onSetDueDate: (due) =>
                                                    _setTaskDueDate(
                                                      task,
                                                      due,
                                                      _activeInList(
                                                        active,
                                                        task.listId,
                                                      ),
                                                    ),
                                                onClearDueDate: () =>
                                                    _clearTaskDueDate(
                                                      task,
                                                      _activeInList(
                                                        active,
                                                        task.listId,
                                                      ),
                                                    ),
                                                onMoveToList: (destId) =>
                                                    _moveTaskToList(
                                                      task,
                                                      destId,
                                                    ),
                                                onDelete: () =>
                                                    _deleteTaskFromRow(task),
                                                onEdit: () =>
                                                    _openEditPanel(task),
                                              ),
                                          ]),
                                        )
                                      else
                                        SliverReorderableList(
                                          key: _taskListKey,
                                          proxyDecorator:
                                              (child, index, animation) {
                                                return ClampToTargetBounds(
                                                  targetKey: _taskListKey,
                                                  child: Material(
                                                    type: MaterialType
                                                        .transparency,
                                                    child: child,
                                                  ),
                                                );
                                              },
                                          onReorderItem: (oldIndex, newIndex) {
                                            _reorderActiveTasks(
                                              active,
                                              oldIndex,
                                              newIndex,
                                            );
                                          },
                                          itemCount: active.length,
                                          itemBuilder: (context, i) {
                                            return ReorderableDragStartListener(
                                              key: ValueKey(active[i].id),
                                              index: i,
                                              child: _TaskRow(
                                                task: active[i],
                                                animateIn:
                                                    active[i].id ==
                                                    _enteringTaskId,
                                                isSelected:
                                                    active[i].id ==
                                                    _selectedTaskId,
                                                listColor:
                                                    currentList?.colorValue,
                                                lists: lists,
                                                subtaskStats: _subtaskStats(
                                                  active[i].id,
                                                ),
                                                subtaskStatsData:
                                                    _subtaskStatsData(
                                                      active[i].id,
                                                    ),
                                                onToggle: (v) => _toggleTask(
                                                  active[i],
                                                  v,
                                                  active,
                                                ),
                                                onStar: () => _toggleStar(
                                                  active[i],
                                                  active,
                                                ),
                                                onSetDueDate: (due) =>
                                                    _setTaskDueDate(
                                                      active[i],
                                                      due,
                                                      active,
                                                    ),
                                                onClearDueDate: () =>
                                                    _clearTaskDueDate(
                                                      active[i],
                                                      active,
                                                    ),
                                                onMoveToList: (destId) =>
                                                    _moveTaskToList(
                                                      active[i],
                                                      destId,
                                                    ),
                                                onDelete: () =>
                                                    _deleteTaskFromRow(
                                                      active[i],
                                                    ),
                                                onEdit: () =>
                                                    _openEditPanel(active[i]),
                                              ),
                                            );
                                          },
                                        ),
                                    if (!effectiveHideCompleted &&
                                        completed.isNotEmpty)
                                      SliverToBoxAdapter(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.stretch,
                                          children: [
                                            const Divider(height: 32),
                                            InkWell(
                                              onTap: () {
                                                final next = !completedExpanded;
                                                setState(
                                                  () =>
                                                      _completedExpandedOverride =
                                                          next,
                                                );
                                                unawaited(
                                                  _persistCompletedExpanded(
                                                    next,
                                                  ),
                                                );
                                              },
                                              borderRadius:
                                                  BorderRadius.circular(14),
                                              child: Padding(
                                                padding:
                                                    const EdgeInsets.fromLTRB(
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
                                                      completedExpanded
                                                          ? PhosphorIconsRegular
                                                                .caretUp
                                                          : PhosphorIconsRegular
                                                                .caretDown,
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    if (!effectiveHideCompleted &&
                                        completed.isNotEmpty &&
                                        completedExpanded)
                                      SliverList(
                                        delegate: SliverChildListDelegate([
                                          for (final task in completed)
                                            _TaskRow(
                                              key: ValueKey(task.id),
                                              task: task,
                                              animateIn:
                                                  task.id == _enteringTaskId,
                                              isSelected:
                                                  task.id == _selectedTaskId,
                                              listColor: _listColorFor(
                                                task.listId,
                                                lists,
                                              ),
                                              lists: lists,
                                              subtaskStats: _subtaskStats(
                                                task.id,
                                              ),
                                              subtaskStatsData:
                                                  _subtaskStatsData(task.id),
                                              onToggle: (v) => _toggleTask(
                                                task,
                                                v,
                                                _activeInList(
                                                  active,
                                                  task.listId,
                                                ),
                                              ),
                                              onStar: () => _toggleStar(
                                                task,
                                                _activeInList(
                                                  active,
                                                  task.listId,
                                                ),
                                              ),
                                              onSetDueDate: (due) =>
                                                  _setTaskDueDate(
                                                    task,
                                                    due,
                                                    _activeInList(
                                                      active,
                                                      task.listId,
                                                    ),
                                                  ),
                                              onClearDueDate: () =>
                                                  _clearTaskDueDate(
                                                    task,
                                                    _activeInList(
                                                      active,
                                                      task.listId,
                                                    ),
                                                  ),
                                              onMoveToList: (destId) =>
                                                  _moveTaskToList(task, destId),
                                              onDelete: () =>
                                                  _deleteTaskFromRow(task),
                                              onEdit: () =>
                                                  _openEditPanel(task),
                                            ),
                                        ]),
                                      ),
                                  ],
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
                                      hintText: 'Add task',
                                      controller: _taskController,
                                      focusNode: _taskFocusNode,
                                      accentColor: Color(
                                        currentList?.colorValue ??
                                            Theme.of(
                                              context,
                                            ).colorScheme.primary.toARGB32(),
                                      ),
                                      onSubmitted: (_) => _addTask(),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  SizedBox(
                                    height: 48,
                                    child: FilledButton(
                                      onPressed: _addTask,
                                      style: FilledButton.styleFrom(
                                        backgroundColor:
                                            currentList?.colorValue == null
                                            ? null
                                            : Color(currentList!.colorValue!),
                                        foregroundColor:
                                            currentList?.colorValue == null
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
                                    listColor: _listColorFor(
                                      panelTask.listId,
                                      lists,
                                    ),
                                    lists: lists,
                                    onClose: () {
                                      _invalidateTodoListData(
                                        listId: panelTask.listId,
                                      );
                                      _closeEditPanel();
                                    },
                                    onChanged: () {
                                      _invalidateTodoListData();
                                    },
                                    onDeleted: () {
                                      _invalidateTodoListData(
                                        listId: panelTask.listId,
                                      );
                                      _closeEditPanel();
                                    },
                                    onToggleStar: () => _toggleStar(
                                      panelTask,
                                      sorted
                                          .where((t) => !t.completed)
                                          .toList(),
                                    ),
                                    onSortBatchApplied: (batch) {
                                      unawaited(
                                        _applyPersistedSortBatchToUi(
                                          batch,
                                          reason: 'persisted_sort_batch',
                                          focusTask: panelTask,
                                        ),
                                      );
                                    },
                                    onTaskOptimistic: (task) {
                                      final active = sorted
                                          .where((t) => !t.completed)
                                          .toList();
                                      final dueDateChanged =
                                          task.dueDate != panelTask.dueDate ||
                                          task.dueDateSetAt !=
                                              panelTask.dueDateSetAt;
                                      final movedList =
                                          task.listId != panelTask.listId;

                                      if (movedList && !task.isSubtask) {
                                        unawaited(
                                          _applyListMoveOptimistic(
                                            task: task,
                                            panelTask: panelTask,
                                            active: active,
                                          ),
                                        );
                                        return;
                                      }

                                      if (dueDateChanged && !task.isSubtask) {
                                        final batch = applyDueDateChange(
                                          panelTask,
                                          active,
                                          dueDate: task.dueDate,
                                          clearDueDate:
                                              task.dueDate == null &&
                                              panelTask.dueDate != null,
                                        );
                                        final sortedTask = batch.tasks
                                            .firstWhere(
                                              (updated) =>
                                                  updated.id == task.id,
                                              orElse: () => task,
                                            );
                                        final merged = sortedTask.copyWith(
                                          title: task.title,
                                          notes: task.notes,
                                          listId: task.listId,
                                        );
                                        setState(() {
                                          _applySortBatchOptimistic(
                                            batch,
                                            active,
                                          );
                                          _taskOverrides[task.id] = merged;
                                          _editPanelTask = merged;
                                        });
                                        return;
                                      }

                                      _taskOverrides[task.id] = task;
                                      final affectsSort =
                                          task.starred != panelTask.starred ||
                                          task.sortOrder !=
                                              panelTask.sortOrder ||
                                          movedList;
                                      if (affectsSort || movedList) {
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
    required this.isSelected,
    required this.onToggle,
    required this.onStar,
    required this.onEdit,
    required this.onSetDueDate,
    required this.onClearDueDate,
    required this.onMoveToList,
    required this.onDelete,
    required this.lists,
    required this.subtaskStats,
    this.subtaskStatsData,
    this.listColor,
    this.animateIn = false,
  });

  final TodoTask task;
  final bool isSelected;

  /// True only for the row rebuilt in the section a just-toggled task moved
  /// into, so it can grow in instead of appearing at full height in one frame.
  /// Read once, when the row's [State] is created.
  final bool animateIn;
  final Future<void> Function(bool?) onToggle;
  final VoidCallback onStar;
  final VoidCallback onEdit;

  /// Applies a due date picked from the right-click menu. The value is a local
  /// wall-clock time (date-only selections arrive as local midnight).
  final ValueChanged<DateTime> onSetDueDate;

  /// Clears the task's due date (resets it to nothing).
  final VoidCallback onClearDueDate;

  /// Moves the task to the list with the given id.
  final ValueChanged<String> onMoveToList;

  /// Deletes the task (shows its own confirmation dialog).
  final Future<void> Function() onDelete;

  /// Lists available as move-to targets in the right-click submenu.
  final List<TodoListModel> lists;

  final Future<({int completed, int total})> subtaskStats;

  /// Last known resolved value for [subtaskStats]. Passed as [FutureBuilder.initialData]
  /// so remounted rows never show a blank frame while awaiting the future.
  final ({int completed, int total})? subtaskStatsData;
  final int? listColor;

  @override
  State<_TaskRow> createState() => _TaskRowState();
}

class _TaskRowState extends State<_TaskRow> with TickerProviderStateMixin {
  static const _exitDuration = Duration(milliseconds: 160);

  late final AnimationController _animController;
  late final Animation<double> _checkScale;

  // Drives the row between "collapsed to nothing" (1.0) and "full height" (0.0).
  // Run forward it collapses the row out of its section before the toggle is
  // committed; run in reverse it grows the row back in where the task landed,
  // so neither side of the move happens in a single frame.
  late final AnimationController _exitController;
  late final Animation<double> _exitSize;
  late final Animation<double> _exitFade;

  // True while the row is collapsing out of its section. Only guards input — it
  // is deliberately not read during build, so turning it on can't restyle the
  // row mid-animation.
  bool _isShifting = false;

  var _displayCompleted = false;
  int _toggleGeneration = 0;
  // True while the pointer is over the checkbox hitbox specifically — drives the
  // outline "preview" check without coloring in the box.
  bool _checkHovered = false;
  // Anchors the confetti burst to the checkbox the user actually clicked.
  final GlobalKey _checkboxKey = GlobalKey();

  ({int completed, int total})? _cachedStats;

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

    if (widget.task.completed) {
      _animController.value = 1.0;
    }

    _exitController = AnimationController(vsync: this, duration: _exitDuration);
    _exitSize = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(parent: _exitController, curve: Curves.easeInCubic),
    );
    // Fade out ahead of the collapse so the row is already gone by the time it
    // is squashed thin enough to look clipped.
    //
    // Entry needs its own curve rather than this one played backwards.
    // CurvedAnimation transforms the controller's value whichever way it is
    // running, so reversing a lead becomes a lag: the row would grow to ~90% of
    // its height while still fully transparent, then flash its content into an
    // already-open gap. This makes the fade lead the growth on the way in too —
    // opaque by 70% through, when the row is ~95% open.
    _exitFade = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(
        parent: _exitController,
        curve: const Interval(0, 0.7, curve: Curves.easeOut),
        reverseCurve: const Interval(0.3, 1, curve: Curves.easeIn),
      ),
    );

    // This row is the far half of a toggle the user just made: it is being
    // inserted where the task landed, so grow it in rather than letting the
    // section below it jump down by a full row in one frame.
    if (widget.animateIn) {
      _exitController.value = 1.0;
      _exitController.reverse();
    }
  }

  @override
  void didUpdateWidget(covariant _TaskRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_animController.isAnimating) return;
    if (oldWidget.task.completed != widget.task.completed) {
      if (widget.task.completed) {
        _displayCompleted = true;
        _animController.value = 1.0;
      } else {
        _displayCompleted = false;
        _animController.value = 0.0;
      }
    }
  }

  @override
  void dispose() {
    _animController.dispose();
    _exitController.dispose();
    super.dispose();
  }

  Future<void> _handleToggle(bool? value) async {
    if (_isShifting) return;
    final target = value ?? false;
    setState(() {
      _displayCompleted = target;
    });

    final currentGen = ++_toggleGeneration;

    if (target) {
      _celebrate();
      await _animController.forward();
    } else {
      await _animController.reverse();
    }

    if (!mounted || _toggleGeneration != currentGen) return;

    // Shrink the row away first: committing the toggle moves the task to the
    // other section on the very next build, so without this the surrounding
    // rows jump into the gap in a single frame.
    _isShifting = true;
    await _exitController.forward();
    if (!mounted || _toggleGeneration != currentGen) return;

    unawaited(widget.onToggle(target));

    // The row is normally rebuilt into the other section (a fresh State that
    // grows itself in) and this one is disposed. If it survives instead — the
    // completed section is hidden and it stays put, or the toggle didn't take —
    // don't leave it collapsed to nothing.
    await SchedulerBinding.instance.endOfFrame;
    if (!mounted || _toggleGeneration != currentGen) return;
    _exitController.value = 0;
    _isShifting = false;
  }

  /// Fires a confetti burst from the checkbox's center to celebrate completing
  /// a task. Reuses the shared [ConfettiOverlay] engine so the effect floats
  /// above the list and survives the row animating away.
  void _celebrate() {
    final box = _checkboxKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    ConfettiOverlay.burst(
      context,
      globalPosition: box.localToGlobal(box.size.center(Offset.zero)),
    );
  }

  /// The task's checkbox. Uses a custom visual (not Material [Checkbox]) so it
  /// can show an outline preview check while hovered, keep the completion pop
  /// animation, and not occlude the row-wide hover highlight.
  Widget _buildCheckbox(Color? listColor) {
    final theme = Theme.of(context);
    final accent = listColor ?? theme.colorScheme.primary;
    return MouseRegion(
      // opaque:false so the row-wide InkWell hover keeps showing while the
      // pointer is over the checkbox.
      opaque: false,
      cursor: SystemMouseCursors.click,
      onEnter: (_) {
        if (!_checkHovered) setState(() => _checkHovered = true);
      },
      onExit: (_) {
        if (_checkHovered) setState(() => _checkHovered = false);
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => unawaited(_handleToggle(!_displayCompleted)),
        child: Padding(
          key: _checkboxKey,
          padding: const EdgeInsets.all(10),
          child: AnimatedBuilder(
            animation: _animController,
            builder: (context, _) => Transform.scale(
              scale: _checkScale.value,
              child: _checkboxVisual(
                theme: theme,
                accent: accent,
                progress: _animController.value,
                hovered: _checkHovered,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _checkboxVisual({
    required ThemeData theme,
    required Color accent,
    required double progress,
    required bool hovered,
  }) {
    final p = progress.clamp(0.0, 1.0);
    final borderRest = theme.colorScheme.onSurface.withValues(alpha: 0.5);
    // Show a faint preview check on hover; once completing, the check tracks the
    // fill so there's no flicker. The box itself is only colored by [p].
    final checkOpacity = hovered ? (p < 0.5 ? 0.5 : p) : p;
    return Container(
      width: 20,
      height: 20,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: accent.withValues(alpha: p),
        borderRadius: BorderRadius.circular(2),
        border: Border.all(
          color: Color.lerp(borderRest, accent, p)!,
          width: 1.5,
        ),
      ),
      child: Opacity(
        opacity: checkOpacity,
        child: CustomPaint(
          size: const Size(14, 14),
          painter: _CheckMarkPainter(
            color: Color.lerp(accent, Colors.white, p)!,
          ),
        ),
      ),
    );
  }

  /// The star toggle. A plain tappable icon (not [IconButton]) so its mouse
  /// region doesn't punch a hole in the row-wide hover highlight.
  Widget _buildStar(Color? listColor) {
    final starred = widget.task.starred;
    return MouseRegion(
      opaque: false,
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onStar,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(
            starred ? PhosphorIconsFill.star : PhosphorIconsRegular.star,
            size: 24,
            color: starred
                ? (listColor ?? Theme.of(context).colorScheme.primary)
                : null,
          ),
        ),
      ),
    );
  }

  String? _formatDue(DateTime? dueDate) {
    if (dueDate == null) return null;
    final local = dueDate.toLocal();
    // Midnight is the app-wide sentinel for "date only" (see the edit panel and
    // _isDueDatePast); don't render a spurious "12:00 AM" for those.
    if (local.hour == 0 && local.minute == 0) {
      return DateFormat.MMMd().format(local);
    }
    return '${DateFormat.MMMd().format(local)} · ${formatTime12Hour(dueDate)}';
  }

  bool _isDueDatePast(DateTime dueDate) {
    final local = dueDate.toLocal();
    final now = DateTime.now();
    if (local.hour == 0 && local.minute == 0) {
      return DateUtils.dateOnly(local).isBefore(DateUtils.dateOnly(now));
    }
    return local.isBefore(now);
  }

  List<ContextMenuItem> _buildContextMenuItems(Color? listColor) {
    final task = widget.task;
    final theme = Theme.of(context);
    final accent = listColor ?? theme.colorScheme.primary;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final tomorrow = today.add(const Duration(days: 1));

    return [
      ContextMenuItem(
        label: task.starred ? 'Unstar' : 'Star',
        icon: task.starred ? PhosphorIconsFill.star : PhosphorIconsRegular.star,
        onTap: widget.onStar,
      ),
      ContextMenuItem(
        label: task.completed ? 'Mark as incomplete' : 'Mark as completed',
        icon: task.completed
            ? PhosphorIconsRegular.arrowCounterClockwise
            : PhosphorIconsRegular.checkCircle,
        onTap: () => unawaited(_handleToggle(!task.completed)),
      ),
      ContextMenuItem(
        label: 'Due today',
        icon: PhosphorIconsRegular.calendarDot,
        onTap: () => widget.onSetDueDate(today),
      ),
      ContextMenuItem(
        label: 'Due tomorrow',
        icon: PhosphorIconsRegular.calendarPlus,
        onTap: () => widget.onSetDueDate(tomorrow),
      ),
      ContextMenuItem(
        label: 'Pick a date',
        icon: PhosphorIconsRegular.calendarBlank,
        onTap: _openDatePicker,
      ),
      if (task.dueDate != null)
        ContextMenuItem(
          label: 'Reset due date',
          icon: PhosphorIconsRegular.calendarX,
          onTap: widget.onClearDueDate,
        ),
      if (widget.lists.isNotEmpty)
        ContextMenuItem(
          label: 'Move task to',
          icon: PhosphorIconsRegular.folder,
          children: [
            for (final list in widget.lists)
              ContextMenuItem(
                label: list.name,
                leading: JournalBookmarkFlag(
                  colorValue:
                      list.colorValue ?? theme.colorScheme.primary.toARGB32(),
                  size: 14,
                ),
                trailing: list.id == task.listId
                    ? Icon(PhosphorIconsRegular.check, size: 16, color: accent)
                    : null,
                onTap: list.id == task.listId
                    ? null
                    : () => widget.onMoveToList(list.id),
              ),
          ],
        ),
      ContextMenuItem(
        label: 'Delete task',
        icon: PhosphorIconsRegular.trash,
        isDestructive: true,
        onTap: () => unawaited(widget.onDelete()),
      ),
    ];
  }

  /// Opens the same date/time picker the edit panel uses (date-only by default;
  /// a time is only attached if the user touches the time field).
  Future<void> _openDatePicker() async {
    final task = widget.task;
    final listColor = widget.listColor == null
        ? null
        : Color(widget.listColor!);
    final localDue = task.dueDate?.toLocal();
    final hasTime =
        localDue != null && (localDue.hour != 0 || localDue.minute != 0);
    final initialDt = task.dueDate != null && hasTime
        ? task.dueDate!.toLocal()
        : (task.dueDate != null
              ? task.dueDate!.toLocal().copyWith(hour: 12, minute: 0)
              : DateTime.now());

    final picked = await showContextualPopover<DateTime>(
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
    if (picked == null || !mounted) return;
    widget.onSetDueDate(picked);
  }

  @override
  Widget build(BuildContext context) {
    final dueLabel = _formatDue(widget.task.dueDate);
    final dueDatePast =
        widget.task.dueDate != null && _isDueDatePast(widget.task.dueDate!);
    final listColor = widget.listColor == null
        ? null
        : Color(widget.listColor!);
    final strikeColor = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: 0.55);
    return SizeTransition(
      sizeFactor: _exitSize,
      alignment: AlignmentDirectional.topStart,
      child: FadeTransition(
        opacity: _exitFade,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: ContextMenuRegion(
            items: _buildContextMenuItems(listColor),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              curve: Curves.easeOut,
              decoration: VoyagerListItemSurface.decoration(
                context,
                selected: widget.isSelected,
                borderRadius: 14,
              ),
              // Own ink surface. Without it the InkWell's hover highlight is
              // painted onto the page's Material, above this subtree — so it
              // ignores the fade and stays fully grey until the row is removed,
              // flashing at the end of the animation.
              child: Material(
                type: MaterialType.transparency,
                child: InkWell(
                  // Guarded rather than disabled/IgnorePointer'd while the row
                  // shifts: an InkWell that stops being hoverable drops its
                  // highlight in 50ms, blinking the grey off under a row that
                  // is still most of the way visible. Staying hoverable lets
                  // the highlight fade out with the rest of the row instead.
                  onTap: () {
                    if (_isShifting) return;
                    widget.onEdit();
                  },
                  // Default hover fade is 50ms — next to the row's own motion
                  // that reads as a flash rather than a transition, both on
                  // the row leaving and on the row that slides up under the
                  // cursor behind it.
                  hoverDuration: _exitDuration,
                  borderRadius: BorderRadius.circular(14),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(left: 8.0),
                        child: _buildCheckbox(listColor),
                      ),
                      Expanded(
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
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyLarge!
                                        .copyWith(
                                          color: _displayCompleted
                                              ? strikeColor
                                              : null,
                                          decoration: _displayCompleted
                                              ? TextDecoration.lineThrough
                                              : null,
                                        ),
                                    child: Text(
                                      widget.task.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                              Builder(
                                builder: (context) {
                                  final metadataColor = Theme.of(context)
                                      .colorScheme
                                      .onSurface
                                      .withValues(alpha: 0.72);
                                  final overdueColor = Theme.of(
                                    context,
                                  ).colorScheme.error;
                                  final textStyle =
                                      Theme.of(
                                        context,
                                      ).textTheme.labelSmall?.copyWith(
                                        fontSize: 10,
                                        color: metadataColor,
                                      ) ??
                                      TextStyle(
                                        fontSize: 10,
                                        color: metadataColor,
                                      );

                                  // Stable metadata: never depends on the Future.
                                  final stableWidgets = <Widget>[];
                                  if (dueLabel != null) {
                                    stableWidgets.add(
                                      Text(
                                        dueLabel,
                                        style: dueDatePast
                                            ? TextStyle(color: overdueColor)
                                            : null,
                                      ),
                                    );
                                  }
                                  final hasNotes =
                                      widget.task.notes?.trim().isNotEmpty ==
                                      true;
                                  if (hasNotes) {
                                    if (stableWidgets.isNotEmpty) {
                                      stableWidgets.add(const Text(' · '));
                                    }
                                    stableWidgets.add(
                                      Icon(
                                        PhosphorIconsRegular.note,
                                        size: 10,
                                        color: metadataColor,
                                      ),
                                    );
                                  }

                                  // Subtask count: depends on the Future; never hides
                                  // stable widgets when it's loading.
                                  final subtaskWidget = FutureBuilder(
                                    future: widget.subtaskStats,
                                    initialData: widget.subtaskStatsData,
                                    builder: (context, snapshot) {
                                      if (snapshot.hasData) {
                                        _cachedStats = snapshot.data;
                                      }
                                      final stats = snapshot.hasData
                                          ? snapshot.data
                                          : _cachedStats;
                                      if (stats == null || stats.total == 0) {
                                        return const SizedBox.shrink();
                                      }
                                      final needsSep = stableWidgets.isNotEmpty;
                                      return Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          if (needsSep) const Text(' · '),
                                          Text(
                                            '${stats.completed} | ${stats.total}',
                                          ),
                                        ],
                                      );
                                    },
                                  );

                                  final hasStable = stableWidgets.isNotEmpty;
                                  // Always show the row if there's any stable content.
                                  // Subtask badge sits alongside it.
                                  if (!hasStable) {
                                    // Only subtask badge; still need to show it.
                                    return FutureBuilder(
                                      future: widget.subtaskStats,
                                      initialData: widget.subtaskStatsData,
                                      builder: (context, snapshot) {
                                        if (snapshot.hasData) {
                                          _cachedStats = snapshot.data;
                                        }
                                        final stats = snapshot.hasData
                                            ? snapshot.data
                                            : _cachedStats;
                                        if (stats == null || stats.total == 0) {
                                          return const SizedBox.shrink();
                                        }
                                        return Padding(
                                          padding: const EdgeInsets.only(
                                            top: 2,
                                          ),
                                          child: DefaultTextStyle(
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: textStyle,
                                            child: Text(
                                              '${stats.completed} | ${stats.total}',
                                            ),
                                          ),
                                        );
                                      },
                                    );
                                  }

                                  return Padding(
                                    padding: const EdgeInsets.only(top: 2),
                                    child: DefaultTextStyle(
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: textStyle,
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          ...stableWidgets,
                                          subtaskWidget,
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ],
                          ),
                        ),
                      ),
                      _buildStar(listColor),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Draws the same checkmark shape Material's [Checkbox] uses — the classic
/// three-point polyline (start → mid → end) at the same relative positions and
/// 2px stroke — so the custom checkbox reads identically to the stock one.
class _CheckMarkPainter extends CustomPainter {
  _CheckMarkPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    final start = Offset(w * 0.15, w * 0.45);
    final mid = Offset(w * 0.4, w * 0.7);
    final end = Offset(w * 0.85, w * 0.25);
    final path = Path()
      ..moveTo(start.dx, start.dy)
      ..lineTo(mid.dx, mid.dy)
      ..lineTo(end.dx, end.dy);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _CheckMarkPainter oldDelegate) =>
      oldDelegate.color != color;
}
