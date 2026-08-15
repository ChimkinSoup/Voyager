import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/constants/todo_constants.dart';
import 'package:voyager/core/dev/dev_flags.dart';
import 'package:voyager/core/dev/todo_sort_debug_logger.dart';
import 'package:voyager/core/effects/confetti.dart';
import 'package:voyager/core/motion/motion.dart';
import 'package:voyager/core/sync/pending_flush_registry.dart';
import 'package:voyager/core/sync/scroll_activity_gate.dart';
import 'package:voyager/core/theme/voyager_list_item_surface.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/utils/all_view_destination.dart';
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
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/todo/todo_task_sorting.dart';
import 'package:voyager/features/shell/reveal_request.dart';
import 'package:voyager/features/shell/shell_page_storage_keys.dart';
import 'package:voyager/features/sync/sync_conflict_banner.dart';
import 'package:voyager/features/todo/todo_edit_panel.dart';
import 'package:voyager/features/todo/todo_list_actions.dart';
import 'package:voyager/features/todo/todo_manage_sheet.dart';

const _todoEditPanelWidth = 420.0;
const _todoEditPanelDuration = Duration(milliseconds: 270);
// How long a completion toggle's write is held so it doesn't fire during the
// row's move + confetti. Toggles landing inside the window batch together.
const _todoCompletionSaveDelay = Duration(milliseconds: 900);

/// Everything that affects what a `_TaskRow` actually renders. Used to decide
/// whether a cached row widget instance (see `_TodoPageState._rowFor`) can be
/// reused as-is — deliberately excludes fields like `sortOrder` that only
/// affect the row's *position*, which the parent controls, not its content.
typedef _RowSignature = ({
  String listId,
  String title,
  String? notes,
  DateTime? dueDate,
  bool completed,
  bool starred,
  bool isSelected,
  int? listColor,
  bool animateIn,
  bool forceCollapsed,
  // Drops a context-menu entry when false, so a cached row built in one view
  // isn't reused in the other.
  bool canMoveToBottom,
  String listsKey,
  int subtaskEpoch,
  ({int completed, int total})? subtaskStatsData,
});

/// A [ScrollController] that can be told to hold whatever the view is
/// currently showing steady for a short window, even as content grows in
/// *above* it during that window (see [armStableView]).
///
/// Used only when uncompleting a task: the row it grows into lands at the
/// top of the active list — the very start of the whole scrollable — so its
/// growth pushes down everything the user is currently looking at, including
/// when they're scrolled all the way to the top themselves. Completing never
/// needs this: its regrown row lands in the completed section, which is
/// always *after* wherever the user is looking at active tasks, so it never
/// disturbs anything already on screen — same reasoning as why completing
/// the very top task has always been jump-free, generalized to any
/// position. Reacting to the growth after the fact — e.g. jumping to
/// `maxScrollExtent` once it settles, or even every frame via
/// `addPostFrameCallback` — always lags the actual layout by one frame,
/// since `addPostFrameCallback` fires after that frame has already painted.
/// Under any jank (slow frames), that lag is long enough to see as a
/// stutter or a snap after the animation looks like it's finished.
///
/// [_StableViewScrollPosition.correctForNewDimensions] instead corrects the
/// offset synchronously, inside the same layout pass that first discovers
/// the content grew — before that frame paints — which is the mechanism
/// `ScrollPosition` itself documents for exactly this purpose.
class _StableViewScrollController extends ScrollController {
  bool _armed = false;

  /// Holds whatever the view is currently showing steady for [duration],
  /// correcting for any growth above it during that window.
  void armStableView(Duration duration) {
    _armed = true;
    if (DevFlags.verboseSync) {
      debugPrint('[scroll] armStableView for ${duration.inMilliseconds}ms');
    }
    Future.delayed(duration, () {
      _armed = false;
      if (DevFlags.verboseSync) {
        debugPrint('[scroll] armStableView expired');
      }
    });
  }

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) {
    return _StableViewScrollPosition(
      physics: physics,
      context: context,
      oldPosition: oldPosition,
      isArmed: () => _armed,
    );
  }
}

class _StableViewScrollPosition extends ScrollPositionWithSingleContext {
  _StableViewScrollPosition({
    required super.physics,
    required super.context,
    super.oldPosition,
    required this.isArmed,
  });

  final bool Function() isArmed;

  @override
  bool correctForNewDimensions(
    ScrollMetrics oldPosition,
    ScrollMetrics newPosition,
  ) {
    final grew = newPosition.maxScrollExtent - oldPosition.maxScrollExtent;
    // Only ever armed for uncompleting (see _TaskRowState._handleToggle),
    // whose regrown row lands at the very top of the whole scrollable. That
    // growth always displaces whatever the user currently sees at the
    // viewport's top edge — including when pixels is already 0: the
    // previously-topmost visible row still gets pushed down to make room for
    // the entering row growing in ahead of it, the same as it would at any
    // other scroll position. There is no "already at the top so nothing can
    // grow above me" case to special-case here; growth at position 0 is
    // always before-or-at the viewport's current top, so it always needs
    // correcting for. (correctPixels is always able to increase pixels to
    // compensate, even from 0 — maxScrollExtent grows by at least as much in
    // the same tick, so it's never asked to exceed the new bounds.)
    final willCorrect = isArmed() && grew > 0;
    // The toggle is really two animations in sequence: the row's old slot
    // (in the completed section) collapses to nothing first, THEN its new
    // slot (at the top of the active section) grows in. During that first,
    // shrinking half, maxScrollExtent can dip below the user's current
    // `pixels` — even though the row shrinking away is well after wherever
    // they're scrolled — because total content genuinely got shorter for a
    // moment. Left alone, ScrollPosition's default dimension-change handling
    // clamps `pixels` down to the new, temporarily-smaller maxScrollExtent to
    // keep it in bounds. That clamp is only supposed to be transient — the
    // very next frame's growth is supposed to add back on top of wherever
    // the user actually was — but it permanently corrupts the baseline: the
    // growth correction above computes `pixels + grew` using this
    // already-clamped `pixels`, so the user ends up measurably offset from
    // where they started instead of back at it. Holding `pixels` steady
    // through the shrink (instead of letting it clamp) keeps that baseline
    // intact for the growth correction to build on.
    final willHoldThroughShrink =
        isArmed() && grew < 0 && newPosition.maxScrollExtent < pixels;
    if (DevFlags.verboseSync) {
      debugPrint(
        '[scroll] correctForNewDimensions armed=${isArmed()} '
        'oldMax=${oldPosition.maxScrollExtent} newMax=${newPosition.maxScrollExtent} '
        'grew=$grew pixels=$pixels willCorrect=$willCorrect '
        'willHoldThroughShrink=$willHoldThroughShrink '
        'oldViewport=${oldPosition.viewportDimension} '
        'newViewport=${newPosition.viewportDimension}',
      );
    }
    if (willCorrect) {
      correctPixels(pixels + grew);
      return false;
    }
    if (willHoldThroughShrink) {
      correctPixels(pixels);
      return false;
    }
    return super.correctForNewDimensions(oldPosition, newPosition);
  }
}

class TodoPage extends ConsumerStatefulWidget {
  const TodoPage({super.key});

  @override
  ConsumerState<TodoPage> createState() => _TodoPageState();
}

class _TodoPageState extends ConsumerState<TodoPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _panelController;
  late CurvedAnimation _panelAnimation;
  var _configuredPanelMotion = false;
  String? _selectedListId;
  String? _selectedTaskId;
  TodoTask? _editPanelTask;
  // The hovered row's task id, tracked here rather than in _TaskRowState so
  // it survives the Element churn described where the active list's
  // SliverReorderableList is built: a completion shifts every row below it,
  // and Flutter destroys and recreates each shifted row's Element in the same
  // frame, which detaches and reattaches its MouseRegion out from under a
  // stationary cursor. Clearing hover is deferred a frame (see
  // _setRowHovered) so that detach/reattach pair cancels out before either
  // side ever paints, instead of flashing.
  //
  // A ValueNotifier rather than plain state + setState: hover changes far more
  // often than anything else on this page — every row the pointer crosses
  // while skimming, and (because rows slide under a stationary cursor) once
  // per frame all the way through a scroll — and rebuilding the whole page for
  // it meant repaying the page's entire fixed cost (the "Add task" field's
  // TextField/EditableText subtree, the list dropdown, and re-running every
  // mounted sliver child's builder) for a change that only ever alters one
  // row's background colour. Only [_RowHoverSurface] listens, and only the two
  // rows whose hovered-ness actually flipped rebuild — see its doc comment.
  final ValueNotifier<String?> _hoveredTaskId = ValueNotifier(null);
  String? _pendingUnhoverTaskId;

  void _setRowHovered(String taskId, bool hovered) {
    if (hovered) {
      _pendingUnhoverTaskId = null;
      _hoveredTaskId.value = taskId;
      return;
    }
    if (_hoveredTaskId.value != taskId) return;
    _pendingUnhoverTaskId = taskId;
    // A genuine mouse-leave doesn't otherwise need a new frame — nothing else
    // is dirty — so without this the callback below could sit pending
    // indefinitely instead of running at the next vsync.
    SchedulerBinding.instance.ensureVisualUpdate();
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _pendingUnhoverTaskId != taskId) return;
      _pendingUnhoverTaskId = null;
      if (_hoveredTaskId.value == taskId) {
        _hoveredTaskId.value = null;
      }
    });
  }

  // Whether the task list should actually be narrowed to make room for the
  // panel right now. Flipped straight to true the instant opening starts
  // (see _openEditPanel) — before the reveal animation's first tick — and
  // straight back to false the instant closing starts (see
  // _closeEditPanel), also before that animation's first tick. Both flips
  // land at a moment when the change is visually a no-op: on open, nothing
  // has been drawn into that space yet, so narrowing the list first and
  // then letting the panel reveal into the now-stable gap costs nothing
  // extra; on close, the panel is still sitting at full width right on top
  // of that space, so the list snapping back underneath it is invisible
  // until the panel actually starts sliding away. Either way the task
  // list's width only ever changes at instants when the framework doesn't
  // have to paint the transition, and the animation itself (see the
  // Positioned pair below) never touches the list's constraints.
  bool _panelSqueezed = false;
  final _taskController = TextEditingController();
  final _taskFocusNode = FocusNode();
  final _taskScrollController = _StableViewScrollController();
  // Timestamp of the last _taskScrollController position change. Used
  // instead of ScrollPosition.isScrollingNotifier, which reflects Flutter's
  // internal ScrollActivity state machine and can briefly flip back to
  // "idle" between individual wheel/trackpad delta events even during what
  // the user experiences as one continuous scroll — which would have caused
  // _refreshOrDeferWhileScrolling to misfire an immediate rebuild right in
  // the middle of a gesture. A short rolling window of "was there a scroll
  // event recently" is more robust across input devices.
  DateTime? _lastScrollActivityAt;
  Timer? _scrollIdleTimer;
  Timer? _coalescedRefreshTimer;
  bool _taskRefreshPending = false;
  static const _scrollIdleGrace = Duration(milliseconds: 200);
  /// Forced order for the single-list view, held until the write it belongs to
  /// comes back. The "All tasks" view never uses one — its order is derived
  /// from task fields, and [_taskOverrides] already carries those optimistically
  /// (see [_applyOptimisticActiveOrder]).
  List<String>? _optimisticActiveTaskOrder;
  // Ids that just completed but are still counted in the active list's
  // rendering for one extra frame (see the SliverReorderableList item-count
  // computation below). Their row is already collapsed to nothing by the
  // time this happens, so keeping them counted costs nothing visually — it
  // exists only so the item count and everything else about that toggle
  // don't change in the very same frame, since SliverReorderableList can't
  // cleanly reconcile a removal it wasn't told about the way findChildIndexCallback
  // lets a plain SliverList do (see the "show all tasks" list above, which
  // doesn't need any of this). Cleared one frame later in _toggleTask.
  final _lingeringActiveIds = <String>{};
  final _completionOverrides = <String, bool>{};
  final _taskOverrides = <String, TodoTask>{};
  final GlobalKey _taskListKey = GlobalKey();
  // Marks the top of the completed section (see _viewportPastActiveSection).
  final GlobalKey _completedSectionKey = GlobalKey();
  // Local override for the completed-section expand state. Null means "use the
  // persisted setting"; a non-null value reflects a toggle in this session for
  // immediate responsiveness before the settings stream updates. The persisted
  // value lives device-locally in settings (see [_persistCompletedExpanded]).
  bool? _completedExpandedOverride;
  var _showAllTasks = false;
  // settingsProvider can still be loading when initState reads it, so the
  // restore of _showAllTasks is retried once from build (see
  // _applySavedShowAllTasks) — the same late recovery _resolveListId performs
  // for the selected list id.
  var _appliedSavedShowAllTasks = false;
  // Cache subtask stats futures by task ID to avoid re-querying the DB on
  // every rebuild (e.g. during drag-to-scroll), which would cause
  // FutureBuilder to restart and create visible jank.
  final _subtaskStatsCache = <String, Future<({int completed, int total})>>{};
  // Stores the last resolved result so FutureBuilders can use it as
  // initialData — preventing a blank frame on widget remount after reorder.
  final _subtaskResultsCache = <String, ({int completed, int total})>{};
  // A task that was just toggled. Its row — in the completed section for a
  // completion, at the top of the active list for an uncomplete — grows
  // itself in instead of appearing at full height (see [_toggleTask]). Live
  // for exactly one build.
  String? _enteringTaskId;
  // Completion toggles whose writes are still waiting out the row's animation
  // (see [_schedulePersistTaskCompletion]). Keyed by task id, so a task toggled
  // twice inside the window only writes the state it ended on.
  final _pendingCompletionSaves = <String, TodoTask>{};
  Timer? _completionSaveTimer;
  // Captured up front so pending writes can still be flushed from dispose(),
  // where `ref` is already off limits.
  late final ProviderContainer _container;
  // The active list computed by the last successful build. Row actions read
  // siblings from here instead of closing over the `active` list at row
  // construction time — a closure would go stale once cached row widgets
  // (see _rowFor) can outlive the frame that built them, and unlike
  // _writeCompletionBatch's disk re-read, _persistSortBatch writes whatever
  // sibling snapshot it's handed without re-verifying it.
  List<TodoTask> _lastActiveAll = const [];
  // Bumped whenever _invalidateTodoListData clears the subtask caches, so a
  // cached row (see _rowFor) that would otherwise look unchanged still picks
  // up fresh subtask data instead of serving stale futures indefinitely.
  int _subtaskCacheEpoch = 0;
  // Reuses the same _TaskRow widget instance across rebuilds for rows whose
  // _RowSignature hasn't changed, so Flutter's element reconciliation skips
  // rebuilding them entirely (it only ever skips a child when the new widget
  // is `identical()` to the old one — a completion toggle that invalidates a
  // shared provider would otherwise reconstruct, and thus rebuild, every
  // mounted row, not just the one that changed). Keyed by task id; pruned to
  // the ids actually on screen at the end of every build.
  final _rowWidgetCache = <String, _TaskRow>{};
  final _rowSignatureCache = <String, _RowSignature>{};

  @override
  void initState() {
    super.initState();
    _container = ProviderScope.containerOf(context, listen: false);
    _taskScrollController.addListener(_onTaskScrollActivity);
    // Deferred toggles must reach disk before the window closes.
    PendingFlushRegistry.instance.register(_flushPendingCompletionSaves);
    _panelController = AnimationController(
      vsync: this,
      duration: _todoEditPanelDuration,
    );
    // Finalized in didChangeDependencies — inherited-widget lookups
    // (VoyagerMotion.reduced needs MediaQuery) aren't safe in initState.
    _panelAnimation = CurvedAnimation(
      parent: _panelController,
      curve: Curves.linear,
    );
    _panelController.addStatusListener((status) {
      if (!mounted) return;
      if (status == AnimationStatus.dismissed) {
        // Captured before clearing _editPanelTask below: onClose used to
        // invalidate immediately, in the very same frame the reverse
        // animation started — bumping _subtaskCacheEpoch and busting every
        // cached row's widget (see _rowFor) right as the panel began
        // sliding shut. Waiting for the animation to actually finish here
        // means that rebuild lands after the panel is already gone instead
        // of competing with it for frame budget.
        final closedListId = _editPanelTask?.listId;
        setState(() {
          _editPanelTask = null;
          _selectedTaskId = null;
        });
        if (closedListId != null) {
          _invalidateTodoListData(listId: closedListId);
        }
      }
    });
    final savedSettings = ref.read(settingsProvider).valueOrNull;
    final savedId = savedSettings?.lastViewedTodoListId;
    if (savedId != null) {
      _selectedListId = savedId;
    }
    // Both, not one or the other: reopening into the all-view still needs the
    // concrete list, since that is where new tasks are filed.
    _showAllTasks = savedSettings?.todoShowAllTasks ?? false;
    _appliedSavedShowAllTasks = savedSettings != null;
  }

  void _applySavedShowAllTasks(AppSettings? settings) {
    if (_appliedSavedShowAllTasks || settings == null) return;
    _appliedSavedShowAllTasks = true;
    if (settings.todoShowAllTasks == _showAllTasks) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _showAllTasks = settings.todoShowAllTasks);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_configuredPanelMotion) return;
    _configuredPanelMotion = true;
    _panelAnimation = CurvedAnimation(
      parent: _panelController,
      curve: VoyagerMotion.reduced(context)
          ? Curves.easeOut
          : VoyagerSpring.drawerCurve,
    );
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

  Future<void> _persistShowAllTasks(bool showAll) async {
    final settingsRepo = ref.read(settingsRepositoryProvider);
    final settings = await settingsRepo.getSettings();
    if (settings.todoShowAllTasks == showAll) return;
    await settingsRepo.saveSettings(
      settings.copyWith(todoShowAllTasks: showAll),
    );
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

  // Read live (not cached at construction) so toggling the dev flag takes
  // effect on the very next open/close, without needing to leave and
  // re-enter the todo page.
  Duration get _panelAnimationDuration => DevFlags.slowTodoEditPanelAnimation
      ? _todoEditPanelDuration * 10
      : _todoEditPanelDuration;

  void _openEditPanel(TodoTask task) {
    // Squeeze synchronously, before the reveal animation's first tick —
    // nothing has been drawn into the reserved space yet, so the list
    // narrowing here costs nothing visually. The panel then reveals into
    // that already-stable gap instead of the list narrowing underneath it
    // partway through (or after) the reveal.
    setState(() {
      _editPanelTask = task;
      _selectedTaskId = task.id;
      _panelSqueezed = true;
    });
    _panelController.duration = _panelAnimationDuration;
    _panelController.forward();
  }

  void _closeEditPanel() {
    // Unsqueeze synchronously, before the reverse animation's first tick —
    // the panel is still at its full resting width at this exact instant, so
    // the task list snapping back to full width underneath it is invisible
    // (still covered). It only becomes visible as the panel actually slides
    // away over the next frames, by which point the list is already at its
    // final width and never has to move again.
    setState(() => _panelSqueezed = false);
    _panelController.duration = _panelAnimationDuration;
    _panelController.reverse();
  }

  /// The list being viewed, and — while "All tasks" is on, where there is no
  /// single list on screen — the list a new task belongs to. Shares
  /// [resolveNewItemTarget] with the journal page's `_journalIdForNewEntry` so
  /// the two views answer this the same way.
  String _resolveListId(List<TodoListModel> lists, AppSettings? settings) {
    return resolveNewItemTarget(
          currentId: _selectedListId,
          lastViewedId: settings?.lastViewedTodoListId,
          legacyId: legacyTodoListId,
          availableIds: [for (final list in lists) list.id],
        ) ??
        legacyTodoListId;
  }

  @override
  void dispose() {
    // Don't strand a deferred toggle: it hasn't been written yet, and the
    // providers it refreshes are kept alive app-wide (the calendar reads task
    // markers off allTodoTasksProvider), so both would outlive this page.
    PendingFlushRegistry.instance.unregister(_flushPendingCompletionSaves);
    unawaited(_flushPendingCompletionSaves());
    _scrollIdleTimer?.cancel();
    _coalescedRefreshTimer?.cancel();
    _taskScrollController.removeListener(_onTaskScrollActivity);
    _hoveredTaskId.dispose();
    _panelAnimation.dispose();
    _panelController.dispose();
    _taskController.dispose();
    _taskFocusNode.dispose();
    _taskScrollController.dispose();
    super.dispose();
  }

  /// Creates the built-in list if it is missing, and returns the current lists
  /// straight from the repository — the caller needs a set that is guaranteed
  /// to include anything just created, which the provider may not have yet.
  Future<List<TodoListModel>> _ensureDefaultList() async {
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
    return lists;
  }

  /// The list a new task belongs to. While "All tasks" is on this is the list
  /// last actually opened — see [resolveNewItemTarget], which the journal
  /// page's `_journalIdForNewEntry` also calls so the two views agree.
  String _listIdForNewTask(List<TodoListModel> lists) {
    return resolveNewItemTarget(
          currentId: _selectedListId,
          lastViewedId: ref
              .read(settingsProvider)
              .valueOrNull
              ?.lastViewedTodoListId,
          legacyId: legacyTodoListId,
          availableIds: [for (final list in lists) list.id],
        ) ??
        legacyTodoListId;
  }

  Future<void> _addTask() async {
    if (_taskController.text.trim().isEmpty) return;
    final lists = await _ensureDefaultList();
    final repo = ref.read(todoRepositoryProvider);
    final remoteSync = ref.read(remoteSyncServiceProvider);
    final now = utcNow();
    final listId = _listIdForNewTask(lists);
    final task = TodoTask(
      id: newId(),
      listId: listId,
      title: _taskController.text.trim(),
      createdAt: now,
      updatedAt: now,
    );
    final siblings = await repo.listTasks(listId);
    final active = activeTopLevelTasks(siblings);
    final batch = applyNewUndatedTask(task, active);
    for (final updated in batch.tasks) {
      await repo.upsertTask(updated);
      remoteSync.pushTodoTaskNow(updated);
    }
    final placed = batch.tasks.firstWhere((t) => t.id == task.id);
    setState(() {
      _applySortBatchOptimistic(batch, [...active, task]);
    });
    logTodoSortDebug(
      ref.read(todoSortDebugLoggerProvider),
      'NEW_TASK',
      task: placed,
      details: 'listId=${task.listId} sortOrder: 0 → ${placed.sortOrder}',
    );
    _taskController.clear();
    _taskFocusNode.requestFocus();
    ref.invalidate(todoTasksProvider(task.listId));
    _invalidateTodoListData();
  }

  /// Commits a toggle after its row has already played its own shrink
  /// animation (see [_TaskRowState._handleToggle], which awaits that before
  /// calling this). Both directions reach this point the same way — the row
  /// that just collapsed to nothing is about to disappear from the section
  /// it was in and reappear, growing in, in the other one — so there is
  /// nothing left here that differs by direction beyond which override flips
  /// and which sort placement applies.
  Future<void> _toggleTask(TodoTask task, bool? completed) async {
    final value = completed ?? false;
    final activeInList = _activeInList(_lastActiveAll, task.listId);
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
        // See _lingeringActiveIds: keeps this id counted in the active
        // section's rendering for one more frame than the data otherwise
        // would, so SliverReorderableList doesn't have to reconcile a
        // removal in the same frame everything else about this toggle
        // changes. Cleared below once that extra frame has rendered.
        _lingeringActiveIds.add(task.id);
        _optimisticActiveTaskOrder?.remove(task.id);
        if (_optimisticActiveTaskOrder?.isEmpty ?? false) {
          _optimisticActiveTaskOrder = null;
        }
        // A task added this session leaves a lingering entry in _taskOverrides
        // with completed:false. Once the deferred write lands and the completion
        // override is reconciled away, that stale override — which _tasksWithOverrides
        // applies — would flip the task straight back to active. Keep it in sync
        // with the completion so it reconciles cleanly instead.
        final lingering = _taskOverrides[task.id];
        if (lingering != null) {
          _taskOverrides[task.id] = lingering.copyWith(completed: true);
        }
      } else if (placement != null) {
        _applySortBatchOptimistic(placement, activeInList);
        logTodoSortDebug(
          ref.read(todoSortDebugLoggerProvider),
          'UNCOMPLETE_OPTIMISTIC',
          task: task,
          details:
              'activeInListIds=${activeInList.map((t) => t.id).join(",")} '
              'placementIds=${placement.tasks.map((t) => t.id).join(",")} '
              'optimisticOrder=${_optimisticActiveTaskOrder?.join(",")}',
        );
      }
    });
    // Consumed by the row built for this task in its new section during the
    // build this setState schedules. Cleared straight after so the row
    // doesn't replay the animation every time it is rebuilt (scrolling it out
    // of the cache extent and back would otherwise re-run it). No setState:
    // nothing on screen reads this outside of row construction.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _enteringTaskId != task.id) return;
      _enteringTaskId = null;
    });
    if (value) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() => _lingeringActiveIds.remove(task.id));
      });
    }
    // Reached only after the row's own exit collapse
    // (_TaskRowState._exitDuration) has already played out — same for both
    // directions now — so the save it schedules is already held that long
    // past the tap.
    _schedulePersistTaskCompletion(task.copyWith(completed: value));
  }

  /// Holds a toggle's writes until the completion animation has settled.
  ///
  /// Everything this defers costs the UI isolate time it doesn't have while the
  /// row animates and the confetti burst paints over the top: the local write
  /// and the Firestore push both marshal the task off this isolate, and the
  /// provider refresh that follows re-reads every list and rebuilds the page
  /// around it. Nothing on screen is waiting for any of it — [_toggleTask]'s
  /// entry in [_completionOverrides] already shows the task on the correct side
  /// until the fresh data arrives and drops it.
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

    final callStart = DevFlags.verboseSync ? DateTime.now() : null;
    final touchedLists = await _writeCompletionBatch(pending);
    if (callStart != null) {
      final elapsed = DateTime.now().difference(callStart).inMilliseconds;
      debugPrint(
        '[sync] todo completion batch (${pending.length} task(s)) took ${elapsed}ms',
      );
    }
    if (touchedLists.isEmpty) return;

    // One refresh for the whole batch. Refreshing per task would re-read every
    // list and rebuild the page once for each. Read through the kept-alive
    // container, not `ref`: a flush from dispose() outlives the widget.
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
  /// rewrites and re-pushes every row in the list once per uncompleted task.
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
      logTodoSortDebug(
        _container.read(todoSortDebugLoggerProvider),
        'UNCOMPLETE_PERSISTED',
        task: task,
        details:
            'diskActiveIds=${active.values.map((t) => t.id).join(",")} '
            'batchIds=${batch.tasks.map((t) => t.id).join(",")}',
      );
      for (final row in batch.tasks) {
        final toSave = row.id == task.id ? row.copyWith(completed: false) : row;
        writes[toSave.id] = toSave;
        active[toSave.id] = toSave;
      }
      touchedLists.add(task.listId);
    }

    // Only the tasks the user actually toggled need an immediate, individual
    // push — that's what makes a checkbox tap show up promptly on another
    // device. Everything else in `writes` is a pure sort-order cascade (every
    // row an uncomplete shifted past to make room at the top of its section),
    // which doesn't need per-row urgency. Firing all of those as their own
    // concurrent immediate pushes was flooding the UI isolate with dozens of
    // Firestore round-trips right as the local save landed — long enough to
    // stall other Timer-driven work sharing the isolate, like the background
    // animation. Batch them into one round-trip instead.
    final directIds = resolved.map((task) => task.id).toSet();
    final cascadeRows = <TodoTask>[];

    void requeueForRetry(List<TodoTask> tasks, Object error) {
      for (final task in tasks) {
        logTodoSortDebug(
          _container.read(todoSortDebugLoggerProvider),
          'REMOTE_PUSH_FAILED',
          task: task,
          details: 'error=$error',
        );
        _pendingCompletionSaves[task.id] = task;
      }
      _completionSaveTimer?.cancel();
      _completionSaveTimer = Timer(
        _todoCompletionSaveDelay,
        () => unawaited(_flushPendingCompletionSaves()),
      );
    }

    // One batched transaction for the whole write set instead of N sequential
    // upserts: an uncomplete's renumbering routinely touches the whole active
    // list, and running that as N awaited round-trips (even with a yield
    // between each) was the dominant cost behind uncompleting feeling
    // slower than completing, which only ever writes a single row.
    final rowsToWrite = writes.values.toList();
    final batchStart = DevFlags.verboseSync ? DateTime.now() : null;
    await repo.upsertTasksBatch(rowsToWrite);
    if (batchStart != null) {
      final elapsed = DateTime.now().difference(batchStart).inMilliseconds;
      debugPrint(
        '[sync] local upsertTasksBatch (${rowsToWrite.length} task(s)) took ${elapsed}ms',
      );
    }

    for (final task in rowsToWrite) {
      if (directIds.contains(task.id)) {
        // Deliberately not awaited: holding the isolate for N sequential
        // Firestore round-trips (2N writes, since each push does an op-log
        // append then a document upsert) is long enough to drop frames on
        // its own. But a fire-and-forget call swallows failures silently —
        // catch it instead: log it and put the task back in the queue so the
        // next flush retries it.
        unawaited(
          remoteSync
              .pushTodoTaskNow(task)
              .catchError((Object error) => requeueForRetry([task], error)),
        );
      } else {
        cascadeRows.add(task);
      }
    }

    if (cascadeRows.isNotEmpty) {
      unawaited(
        remoteSync
            .pushTodoTasksBatch(cascadeRows)
            .catchError((Object error) => requeueForRetry(cascadeRows, error)),
      );
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
      // Hand the isolate back between rows, same reasoning as
      // _writeCompletionBatch: a reorder or normalize pass routinely touches
      // the whole list.
      await Future<void>.delayed(Duration.zero);
    }
    // One batched push for the whole reorder/normalize pass instead of one
    // immediate Firestore round-trip per row — see _writeCompletionBatch's
    // cascadeRows comment for why firing N concurrent pushes here stalls
    // other Timer-driven work sharing the UI isolate.
    unawaited(remoteSync.pushTodoTasksBatch(batch.tasks));
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

  Future<void> _toggleStar(TodoTask task) async {
    final activeTasks = _activeInList(_lastActiveAll, task.listId);
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

  /// Sends a task to the bottom of its own category (starred/unstarred
  /// crossed with dated/undated) from the right-click menu.
  Future<void> _moveTaskToBottom(TodoTask task) async {
    final activeTasks = _activeInList(_lastActiveAll, task.listId);
    final batch = applyMoveToBottomOfCategory(task, activeTasks);
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
      'MOVE_TO_BOTTOM',
      task: updated,
      details:
          'right-click move to bottom of category, '
          'sortOrder: ${task.sortOrder} → ${updated.sortOrder}',
    );
  }

  /// Sets (or replaces) a task's due date from the right-click menu. [localDue]
  /// is a local wall-clock time; a date-only selection arrives as local
  /// midnight (hour/minute == 0), matching the edit panel's picker contract.
  Future<void> _setTaskDueDate(TodoTask task, DateTime localDue) async {
    final activeInList = _activeInList(_lastActiveAll, task.listId);
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
  Future<void> _clearTaskDueDate(TodoTask task) async {
    final activeInList = _activeInList(_lastActiveAll, task.listId);
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
    remoteSync.pushTodoTaskNow(deleted);
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

  /// Kicks off (or reuses, via `_subtaskStats`'s own `putIfAbsent`) every
  /// task's subtask-stats future up front, rather than waiting for `_rowFor`
  /// to request it while building that task's row. See the call site for
  /// why this matters specifically for the active section.
  void _warmSubtaskStatsCache(List<TodoTask> tasks) {
    for (final task in tasks) {
      _subtaskStats(task.id);
    }
  }

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
      _subtaskCacheEpoch++;
    }
  }

  int? _listColorFor(String listId, List<TodoListModel> lists) {
    for (final list in lists) {
      if (list.id == listId) return list.colorValue;
    }
    return null;
  }

  /// Canonical rendering key for [lists], used in every row's [_RowSignature].
  ///
  /// `lists` is a fresh List instance (new identity, same content) any time
  /// todoListsProvider re-fetches — including on every remote sync landing,
  /// which invalidates it unconditionally even when only tasks changed (see
  /// liveSyncProvider.onChanged). Comparing it by reference in the signature
  /// would bust every row's cache on every sync round-trip; reducing it to the
  /// fields that actually affect rendering (name/color, not the List object)
  /// means the cache only busts when a list actually changed.
  ///
  /// Memoized on the List's identity so this is built once per build rather
  /// than once per row, and — more importantly — so consecutive builds share
  /// one String instance, which lets the signature's `==` settle on identity
  /// instead of comparing the characters for every mounted row.
  String _listsKeyFor(List<TodoListModel> lists) {
    if (identical(lists, _listsKeySource)) return _listsKey!;
    final key = lists
        .map((l) => '${l.id}:${l.name}:${l.colorValue}')
        .join(String.fromCharCode(0));
    _listsKeySource = lists;
    // Reuse the previous instance when the content is unchanged, so a
    // re-fetch that didn't actually alter any list can't bust the row cache.
    _listsKey = key == _listsKey ? _listsKey : key;
    return _listsKey!;
  }

  List<TodoListModel>? _listsKeySource;
  String? _listsKey;

  List<TodoTask> _activeInList(List<TodoTask> active, String listId) {
    return active.where((task) => task.listId == listId).toList();
  }

  /// The active section's total rendered height, measured against the
  /// completed section's marker widget (`_completedSectionKey`) via
  /// `RenderAbstractViewport.getOffsetToReveal` — i.e. the scroll offset at
  /// which the completed section's top edge would align with the viewport's
  /// leading edge, which is exactly the active section's height since
  /// nothing else precedes the completed section. Null if the marker isn't
  /// currently laid out (completed section hidden, or not yet attached).
  double? _activeSectionHeight() {
    if (!_taskScrollController.hasClients) return null;
    final box =
        _completedSectionKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return null;
    final viewport = RenderAbstractViewport.maybeOf(box);
    if (viewport == null) return null;
    return viewport.getOffsetToReveal(box, 0.0).offset;
  }

  /// Whether the viewport's top edge is already scrolled past the entire
  /// active section (i.e. the user is looking at the completed section).
  bool _viewportPastActiveSection() {
    final sectionStart = _activeSectionHeight();
    if (sectionStart == null) return false;
    return _taskScrollController.position.pixels >= sectionStart;
  }

  /// Whether uncompleting [task] right now would grow content above the
  /// user's current viewport — i.e. whether `_StableViewScrollController`'s
  /// offset-correction should be armed to keep the visible content steady.
  ///
  /// The entering row always lands somewhere in the active section (see
  /// `applyTaskUncomplete`), which is always rendered above the completed
  /// section as a whole — so if the viewport is already scrolled past the
  /// active section entirely (`_viewportPastActiveSection`), the growth is
  /// unconditionally above it, no matter where in the active section it
  /// lands. Otherwise — viewport still within the active section itself —
  /// whether it needs correcting depends on whether the insertion index sits
  /// above or below wherever the user is currently scrolled. Row heights
  /// vary (notes, due dates, subtasks), so the insertion index's position is
  /// approximated as a uniform fraction of the measured active-section
  /// height rather than computed exactly; that's still far closer than
  /// treating every mid-list landing as never needing correction, which
  /// under-armed exactly this case: an unstarred, undated task landing well
  /// inside the active section (behind other starred/dated tasks) while the
  /// user was scrolled deep enough into it that the insertion point was
  /// still above their viewport.
  bool _uncompleteGrowsAboveViewport(TodoTask task) {
    // Starred tasks always land in the starred section — the topmost segment
    // of the active list, always above the completed section.
    if (task.starred) return true;

    final activeInList = _activeInList(_lastActiveAll, task.listId);
    final placement = applyTaskUncomplete(
      task.copyWith(completed: false),
      activeInList,
    );
    final placedTask = placement.tasks.firstWhere(
      (t) => t.id == task.id,
      orElse: () => task.copyWith(completed: false),
    );
    final placementById = {for (final t in placement.tasks) t.id: t};
    final projected = [
      for (final t in _lastActiveAll) placementById[t.id] ?? t,
    ];
    final resorted = sortTodoTasks([...projected, placedTask]);
    final insertIndex = resorted.indexWhere((t) => t.id == task.id);
    if (insertIndex <= 0) return true;

    if (_viewportPastActiveSection()) return true;

    final sectionHeight = _activeSectionHeight();
    if (sectionHeight == null || resorted.isEmpty) return false;
    final avgRowHeight = sectionHeight / resorted.length;
    final estimatedOffset = insertIndex * avgRowHeight;
    final pixels = _taskScrollController.hasClients
        ? _taskScrollController.position.pixels
        : 0.0;
    final growsAboveViewport = estimatedOffset < pixels;
    if (DevFlags.verboseSync) {
      debugPrint(
        '[scroll] uncompleteGrowsAboveViewport task=${task.id.substring(0, 8)} '
        'insertIndex=$insertIndex total=${resorted.length} '
        'avgRowHeight=$avgRowHeight estimatedOffset=$estimatedOffset '
        'pixels=$pixels result=$growsAboveViewport',
      );
    }
    return growsAboveViewport;
  }

  /// Returns a `_TaskRow` for [task], reusing the previous frame's widget
  /// instance when nothing that affects its rendering has changed. See
  /// `_rowWidgetCache` for why that matters.
  _TaskRow _rowFor(
    TodoTask task, {
    required bool isSelected,
    required int? listColor,
    required List<TodoListModel> lists,
    bool forceCollapsed = false,
  }) {
    final animateIn = task.id == _enteringTaskId;
    final listsKey = _listsKeyFor(lists);
    final subtaskStatsData = _subtaskStatsData(task.id);
    final signature = (
      listId: task.listId,
      title: task.title,
      notes: task.notes,
      dueDate: task.dueDate,
      completed: task.completed,
      starred: task.starred,
      isSelected: isSelected,
      listColor: listColor,
      animateIn: animateIn,
      forceCollapsed: forceCollapsed,
      canMoveToBottom: !_showAllTasks,
      listsKey: listsKey,
      subtaskEpoch: _subtaskCacheEpoch,
      // Without this, a row built before its subtask query resolves keeps
      // returning that same cached widget instance forever afterward — none
      // of the other fields above ever change just because the async data
      // arrived — freezing `subtaskStatsData` at null even after
      // `_subtaskResultsCache` has the real answer. Then any time that row's
      // Element gets torn down and recreated (e.g. an index shift elsewhere
      // in the list), FutureBuilder mounts fresh with that frozen (null)
      // initialData and has to wait a real frame for its already-resolved
      // Future to notify it via a microtask — that wait is the blank frame.
      // Including the resolved data here means a resolution invalidates the
      // cached widget, so the next build recaptures it.
      subtaskStatsData: subtaskStatsData,
    );
    if (!DevFlags.disableCache) {
      final cached = _rowWidgetCache[task.id];
      if (cached != null && _rowSignatureCache[task.id] == signature) {
        return cached;
      }
    }
    final row = _TaskRow(
      key: ValueKey(task.id),
      task: task,
      animateIn: animateIn,
      forceCollapsed: forceCollapsed,
      isSelected: isSelected,
      hoveredTaskId: _hoveredTaskId,
      listColor: listColor,
      lists: lists,
      subtaskStats: _subtaskStats(task.id),
      subtaskStatsData: subtaskStatsData,
      onToggle: (v) => _toggleTask(task, v),
      onHoverChanged: (h) => _setRowHovered(task.id, h),
      onStar: () => _toggleStar(task),
      // "Send to bottom" writes the task's per-list `sortOrder`, which the
      // "All tasks" view ignores entirely — offering it there would look like
      // it silently did nothing. See [resolveGlobalTaskOrder].
      onMoveToBottom: _showAllTasks ? null : () => _moveTaskToBottom(task),
      onSetDueDate: (due) => _setTaskDueDate(task, due),
      onClearDueDate: () => _clearTaskDueDate(task),
      onMoveToList: (destId) => _moveTaskToList(task, destId),
      onDelete: () => _deleteTaskFromRow(task),
      onEdit: () => _openEditPanel(task),
      onArmScrollStability: () {
        if (!_uncompleteGrowsAboveViewport(task)) return;
        _taskScrollController.armStableView(
          _TaskRowState._exitDuration * 2 + const Duration(milliseconds: 50),
        );
      },
    );
    if (!DevFlags.disableCache) {
      _rowWidgetCache[task.id] = row;
      _rowSignatureCache[task.id] = signature;
    }
    return row;
  }

  /// The "Add task" field and its button, cached on the one thing they
  /// actually depend on.
  ///
  /// Same reasoning as `_rowFor`'s widget cache, for the other end of the
  /// page: a `LabeledTextField` expands to a TextField/EditableText subtree of
  /// well over a hundred widgets — on its own the single most expensive thing
  /// in this build — and none of it has anything to say about the task list.
  /// Returning the identical instance lets the framework skip the whole
  /// subtree (`Element.updateChild` reuses a child outright when the new
  /// widget is `identical` to the old one), so a rebuild triggered by task
  /// data stops paying for the composer.
  Widget _composerBar(Color accent, String hintText) {
    final cached = _composerBarCache;
    if (cached != null &&
        _composerBarColor == accent &&
        _composerBarHint == hintText) {
      return cached;
    }
    final bar = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: LabeledTextField(
            label: '',
            showLabel: false,
            hintText: hintText,
            controller: _taskController,
            focusNode: _taskFocusNode,
            accentColor: accent,
            onSubmitted: (_) => _addTask(),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          height: 48,
          child: GlassButton(
            onPressed: _addTask,
            label: 'Add',
            height: 48,
            color: accent,
          ),
        ),
      ],
    );
    _composerBarCache = bar;
    _composerBarColor = accent;
    _composerBarHint = hintText;
    return bar;
  }

  Widget? _composerBarCache;
  Color? _composerBarColor;
  String? _composerBarHint;

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
    unawaited(_persistShowAllTasks(false));
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
          // The all-tasks view is left as it was; only the list that new tasks
          // land in has moved, so record it (matching the journal page).
          final fallbackId = _selectedListId;
          if (fallbackId != null) {
            _markListViewed(fallbackId);
          }
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

  /// Reorders the single-list view. Only ever reached from there: "All tasks"
  /// derives its order and renders a plain, non-reorderable list.
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
    if (order == null) return active;
    // A forced order is only ever built for the single-list view: it sorts on
    // `sortOrder`, which says nothing about where a task belongs among another
    // list's. "All tasks" doesn't want one anyway — it derives its order from
    // fields that `_taskOverrides` has already updated optimistically, so it
    // repositions a starred or newly-dated task without any help here.
    if (_showAllTasks) return active;
    if (order.length != active.length) {
      logTodoSortDebug(
        ref.read(todoSortDebugLoggerProvider),
        'OPTIMISTIC_ORDER_LENGTH_MISMATCH',
        details:
            'forcedCount=${order.length} actualCount=${active.length} '
            'forcedIds=${order.join(",")} '
            'actualIds=${active.map((t) => t.id).join(",")}',
      );
      return active;
    }
    final byId = {for (final task in active) task.id: task};
    if (!order.every(byId.containsKey)) {
      logTodoSortDebug(
        ref.read(todoSortDebugLoggerProvider),
        'OPTIMISTIC_ORDER_ID_MISMATCH',
        details:
            'forcedIds=${order.join(",")} '
            'actualIds=${active.map((t) => t.id).join(",")}',
      );
      return active;
    }
    return [for (final id in order) byId[id]!];
  }

  bool get _isTaskListScrolling {
    final last = _lastScrollActivityAt;
    return last != null && DateTime.now().difference(last) < _scrollIdleGrace;
  }

  // Fires on every _taskScrollController position change — i.e. any actual
  // scroll movement, regardless of input device. Also feeds
  // ScrollActivityGate so pending remote sync calls (which can hold the UI
  // isolate for their full round trip — see ScrollActivityGate) wait for
  // the gesture to settle instead of firing mid-scroll.
  void _onTaskScrollActivity() {
    _lastScrollActivityAt = DateTime.now();
    ScrollActivityGate.instance.noteActivity();
    if (_taskRefreshPending) {
      _armScrollIdleTimer();
    }
  }

  void _armScrollIdleTimer() {
    _scrollIdleTimer?.cancel();
    _scrollIdleTimer = Timer(_scrollIdleGrace, () {
      _scrollIdleTimer = null;
      if (_taskRefreshPending) {
        _taskRefreshPending = false;
        if (mounted) setState(() {});
      }
    });
  }

  /// Rebuilds immediately, unless the task list is actively being scrolled —
  /// in which case the rebuild (which re-lays-out every row within the
  /// sliver's cache extent) is deferred until the gesture ends. A save
  /// landing mid-scroll — this device's own debounced write, or a remote
  /// change pulled in live — would otherwise invalidate todoTasksProvider /
  /// todoListStatsProvider right as the user is dragging, stalling the
  /// scroll for a frame or more.
  void _refreshOrDeferWhileScrolling() {
    if (!mounted) return;
    if (!_isTaskListScrolling) {
      _scheduleCoalescedRefresh();
      return;
    }
    _taskRefreshPending = true;
    _armScrollIdleTimer();
  }

  // A single completion save invalidates todoTasksProvider(listId) and
  // todoListStatsProvider together, and each has its own ref.listen above —
  // when the two futures resolve a frame apart (they're independent async
  // chains) this fired setState twice, paying the full row-rebuild cost of
  // this same toggle twice in a row. A zero-duration timer coalesces any
  // refreshes requested in the same burst into a single rebuild.
  void _scheduleCoalescedRefresh() {
    if (_coalescedRefreshTimer != null) return;
    _coalescedRefreshTimer = Timer(Duration.zero, () {
      _coalescedRefreshTimer = null;
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(settingsProvider);
    final settings = settingsAsync.valueOrNull;
    _applySavedShowAllTasks(settings);
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
    ref.listen<AsyncValue<Map<String, ({int active, int completed})>>>(
      todoListStatsProvider,
      (previous, next) => _refreshOrDeferWhileScrolling(),
    );
    // Handles "Show in To-Do" from the notification popover: jump to the
    // task's list and open its edit panel, then consume the request.
    ref.listen<RevealRequest?>(revealRequestProvider, (previous, next) {
      if (next == null || next.type != RevealTargetType.task) return;
      final task = next.task!;
      ref.read(revealRequestProvider.notifier).state = null;
      setState(() => _selectedListId = task.listId);
      // Recorded, not just set: this moves the list new tasks are filed under
      // while the all-tasks view stays on, and the persisted id has to agree
      // with that or a restart would silently move it back.
      _markListViewed(task.listId);
      _openEditPanel(task);
    });
    final statsAsync = ref.read(todoListStatsProvider);

    return listsAsync.when(
      skipLoadingOnReload: true,
      data: (lists) {
        if (lists.isEmpty) {
          return Center(
            child: GlassButton(
              onPressed: () => showTodoListManageSheet(context, ref),
              label: 'Create your first list',
            ),
          );
        }
        final listId = _resolveListId(lists, settings);
        if (_selectedListId != listId) {
          _selectedListId = listId;
        }
        final currentList = _selectedList(lists);
        // The shade the task bar is keyed to: the list being viewed, or the
        // plain accent while "All tasks" is on — that view spans every list
        // and so has no colour of its own. Worn by the list dropdown.
        final taskBarColor = Color(
          (_showAllTasks ? null : currentList?.colorValue) ??
              Theme.of(context).colorScheme.primary.toARGB32(),
        );
        // The composer at the other end of the page answers a different
        // question — not "what am I looking at?" but "where does this go?" —
        // and in the all-tasks view those diverge. It names and wears the
        // destination list so the answer isn't invisible as you type.
        final destinationList = lists.cast<TodoListModel?>().firstWhere(
          (l) => l!.id == _listIdForNewTask(lists),
          orElse: () => null,
        );
        final composerColor = _showAllTasks && destinationList != null
            ? Color(
                destinationList.colorValue ??
                    Theme.of(context).colorScheme.primary.toARGB32(),
              )
            : taskBarColor;
        final composerHint = _showAllTasks && destinationList != null
            ? 'Add task to ${shortDestinationName(destinationList.name)}'
            : 'Add task';
        final stats = statsAsync.valueOrNull;

        ref.listen<AsyncValue<List<TodoTask>>>(
          _showAllTasks ? allTodoTasksProvider : todoTasksProvider(listId),
          (previous, next) => _refreshOrDeferWhileScrolling(),
        );
        final tasksAsync = _showAllTasks
            ? ref.read(allTodoTasksProvider)
            : ref.read(todoTasksProvider(listId));
        return tasksAsync.when(
          skipLoadingOnReload: true,
          data: (tasks) {
            final prepStart = DevFlags.verboseSync ? DateTime.now() : null;
            _reconcileCompletionOverrides(tasks);
            _reconcileTaskOverrides(tasks);
            _maybeNormalizeListSort(tasks, listId);
            final withOverrides = _tasksWithOverrides(
              tasks,
              viewingListId: listId,
              showAllTasks: _showAllTasks,
            );
            // "All tasks" merges lists whose sortOrders are independent of one
            // another, so it ignores that field and derives an order from the
            // tasks themselves instead — see [resolveGlobalTaskOrder].
            final sorted = _showAllTasks
                ? resolveGlobalTaskOrder(withOverrides)
                : sortTodoTasks(withOverrides);
            final active = _applyOptimisticActiveOrder(
              sorted.where((t) => !t.completed).toList(),
            );
            _lastActiveAll = active;
            // SliverReorderableList (used below for the active section)
            // wraps every item's key with its current index baked in
            // (Flutter's own `_ReorderableItemGlobalKey`), so completing or
            // uncompleting any task but the last one shifts somebody's
            // index — which changes that wrapped key's value and forces the
            // framework to destroy and recreate that row's whole State,
            // bypassing findChildIndexCallback entirely (that callback only
            // helps the delegate decide what to move; it can't override the
            // key-equality check that actually gates State reuse). A fresh
            // State means a fresh FutureBuilder with no initialData unless
            // `_subtaskResultsCache` already has this task's answer —
            // normally guaranteed by `_rowFor` calling `_subtaskStats`
            // whenever it builds a row, but a row can be torn down and
            // rebuilt in the very same frame its own toggle input its
            // shift, before `_rowFor` has had a chance to run for it again.
            // Warming every active task's stats here — independent of
            // whether `_rowFor` happens to touch it this frame — closes
            // that gap. Scoped to `active` only (not the completed list,
            // which can hold a list's entire history): the completed
            // section's plain SliverList keys rows with a bare ValueKey, so
            // its findChildIndexCallback isn't undermined this way and
            // doesn't need this.
            _warmSubtaskStatsCache(active);
            if (DevFlags.verboseSync) {
              final dated = active.where((t) => t.dueDate != null).toList();
              debugPrint(
                '[sort] dated active order: '
                '${dated.map((t) => '${t.id.substring(0, 8)}'
                    '(due=${t.dueDate!.toIso8601String().substring(0, 10)},'
                    'sort=${t.sortOrder},star=${t.starred})').join(" | ")}',
              );
            }
            // Rendering-only view for the drag-reorderable active list (see
            // _lingeringActiveIds): pads `active` back out with any task
            // that just completed, so SliverReorderableList's item count
            // doesn't drop in the same frame the rest of that toggle
            // commits. Never used for anything but that list's item
            // count/builder — sort placement, stats, and _lastActiveAll all
            // keep using the real `active` above.
            final reorderableActive = _lingeringActiveIds.isEmpty
                ? active
                : [
                    ...active,
                    for (final t in sorted)
                      if (_lingeringActiveIds.contains(t.id) &&
                          !active.any((a) => a.id == t.id))
                        t,
                  ];
            final completed = sorted.where((t) => t.completed).toList();
            // A toggled task's row has already fully played its exit
            // collapse by the time it moves between sections (see
            // _TaskRowState._handleToggle), so there's no leftover row to
            // keep rendering here — completed and active both just reflect
            // the current data.
            final completedForDisplay = completed;
            // Drop cached row widgets for tasks no longer displayed, so
            // deleted/moved-away tasks don't leak entries indefinitely.
            final liveRowIds = {
              for (final t in active) t.id,
              for (final t in completedForDisplay) t.id,
            };
            _rowWidgetCache.removeWhere((id, _) => !liveRowIds.contains(id));
            _rowSignatureCache.removeWhere((id, _) => !liveRowIds.contains(id));
            // Id → index for each section, so the findChildIndexCallbacks
            // below are a map lookup rather than a linear scan. The framework
            // calls those once per mounted child whenever indices shift — a
            // scan made that quadratic in the section's length, which is the
            // one part of reconciling a completion that got worse the longer
            // the list got.
            final activeIndexById = {
              for (var i = 0; i < active.length; i++) active[i].id: i,
            };
            final reorderableIndexById = identical(reorderableActive, active)
                ? activeIndexById
                : {
                    for (var i = 0; i < reorderableActive.length; i++)
                      reorderableActive[i].id: i,
                  };
            final completedIndexById = {
              for (var i = 0; i < completedForDisplay.length; i++)
                completedForDisplay[i].id: i,
            };
            final selectedTask = _selectedTaskId == null
                ? null
                : sorted.cast<TodoTask?>().firstWhere(
                    (t) => t!.id == _selectedTaskId,
                    orElse: () => null,
                  );

            final panelTask = _panelTaskFor(sorted);
            if (prepStart != null) {
              final elapsed = DateTime.now()
                  .difference(prepStart)
                  .inMicroseconds;
              debugPrint(
                '[jank] todo build prep (sort/reconcile) took '
                '${elapsed / 1000}ms for ${tasks.length} task(s)',
              );
            }

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SyncConflictBanner(),
                Expanded(
                  // A Stack, not a Row: the task list's Positioned right
                  // inset is driven by _panelSqueezed, not by
                  // _panelAnimation.value directly, so it only changes once
                  // per open/close (see _panelSqueezed's declaration for why).
                  // The list is already narrowed by the time the panel's
                  // reveal animation plays on open, and already back to full
                  // width (still hidden under the panel) by the time its
                  // reverse animation plays on close — either way the panel,
                  // itself a separate, always-real-size Positioned unlike
                  // the SizedOverflowBox this replaced, is the only thing
                  // moving during the animation, and stays properly
                  // clickable throughout since its hit-test bounds always
                  // match what's actually visible.
                  child: Stack(
                    children: [
                      Positioned(
                        left: 0,
                        top: 0,
                        bottom: 0,
                        right: _panelSqueezed ? _todoEditPanelWidth : 0,
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: RoundedDropdown<String?>(
                                      // Null while "All tasks" is on: no
                                      // single list is being viewed, so no row
                                      // in the menu should wear the selection
                                      // border.
                                      value: _showAllTasks ? null : listId,
                                      displayLabel: _showAllTasks
                                          ? 'All tasks'
                                          : null,
                                      labelColor: taskBarColor,
                                      closedTrailing: _showAllTasks
                                          ? null
                                          : '${active.length} | ${completed.length}',
                                      onAddList: () =>
                                          unawaited(_createListFromDropdown()),
                                      manageMenuEntriesFor: (listId) =>
                                          listId == legacyTodoListId
                                          ? defaultEntityManageMenuEntries
                                          : entityManageMenuEntries,
                                      onManage: (listId, action) async {
                                        if (listId == null) return;
                                        final stat = _statsForList(
                                          listId,
                                          stats,
                                          activeCount: active.length,
                                          completedCount: completed.length,
                                        );
                                        await _handleListManage(
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
                                        return RoundedDropdownItem<String?>(
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
                                        if (v == null) return;
                                        setState(() {
                                          _selectedListId = v;
                                          // Picking a specific list is an
                                          // explicit request to view *that*
                                          // list, so it also leaves the
                                          // all-tasks view.
                                          _showAllTasks = false;
                                          _optimisticActiveTaskOrder = null;
                                        });
                                        _closeEditPanel();
                                        _markListViewed(v);
                                        unawaited(_persistShowAllTasks(false));
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
                                        unawaited(
                                          _persistShowAllTasks(false),
                                        );
                                      } else {
                                        setState(() => _showAllTasks = true);
                                        // Only the view flag is written here:
                                        // _selectedListId deliberately stays
                                        // on the list that was open, and it is
                                        // what new tasks created from this
                                        // view are filed under.
                                        unawaited(_persistShowAllTasks(true));
                                      }
                                    },
                                    icon: Icon(
                                      PhosphorIconsRegular.listMagnifyingGlass,
                                      color: _showAllTasks
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
                                  controller: _taskScrollController,
                                  // Was 10000.0 — that forces layout of dozens of
                                  // off-screen rows on every rebuild, including
                                  // the full-page rebuild the deferred
                                  // completion write triggers ~900ms after each
                                  // toggle (see _flushPendingCompletionSaves).
                                  // 2000 still keeps several screens' worth of
                                  // rows warm for keep-alive scrolling without
                                  // paying to lay out the whole list every time.
                                  cacheExtent: 2000.0,
                                  slivers: [
                                    if (active.isNotEmpty)
                                      // Deliberately a plain SliverList: "All
                                      // tasks" is not reorderable. Its order is
                                      // derived from the tasks themselves (see
                                      // resolveGlobalTaskOrder), so there is no
                                      // manual order for a drag to write to —
                                      // one would either be discarded on the
                                      // next rebuild or have to invent a
                                      // cross-list ordering key that every
                                      // per-list drag then had to keep in sync.
                                      // "Send to bottom" is dropped from the
                                      // row context menu here for the same
                                      // reason (see _rowFor).
                                      if (_showAllTasks)
                                        SliverList(
                                          // A list delegate here (instead of a
                                          // builder) would construct a
                                          // _TaskRow for every active task on
                                          // every rebuild regardless of what's
                                          // on screen — the deferred rebuild a
                                          // completion write triggers (see
                                          // _flushPendingCompletionSaves) then
                                          // pays for the entire dataset instead
                                          // of just the visible rows.
                                          delegate: SliverChildBuilderDelegate(
                                            (context, index) {
                                              final task = active[index];
                                              return _rowFor(
                                                task,
                                                isSelected:
                                                    task.id == _selectedTaskId,
                                                listColor: _listColorFor(
                                                  task.listId,
                                                  lists,
                                                ),
                                                lists: lists,
                                              );
                                            },
                                            childCount: active.length,
                                            // Without this, a completion
                                            // that removes a task from the
                                            // middle of this list shifts
                                            // every task below it down one
                                            // index — and since this
                                            // delegate has no way to match a
                                            // shifted key back to its old
                                            // Element, the framework treats
                                            // every shifted slot as a brand
                                            // new child (destroy + recreate,
                                            // forcing a real build() on each
                                            // one) even though `_rowFor`
                                            // returns the exact same cached
                                            // widget instance for it. This
                                            // callback lets the framework
                                            // find and reuse the existing
                                            // Element by key instead.
                                            findChildIndexCallback: (key) =>
                                                activeIndexById[(key
                                                        as ValueKey<String>)
                                                    .value],
                                          ),
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
                                          itemCount: reorderableActive.length,
                                          itemBuilder: (context, i) {
                                            final task = reorderableActive[i];
                                            return ReorderableDragStartListener(
                                              key: ValueKey(task.id),
                                              index: i,
                                              child: _rowFor(
                                                task,
                                                isSelected:
                                                    task.id == _selectedTaskId,
                                                listColor:
                                                    currentList?.colorValue,
                                                lists: lists,
                                                forceCollapsed:
                                                    _lingeringActiveIds
                                                        .contains(task.id),
                                              ),
                                            );
                                          },
                                          // KNOWN LIMITATION — unlike the plain
                                          // SliverList's findChildIndexCallback
                                          // above, this one CANNOT stop
                                          // SliverReorderableList from
                                          // destroying and recreating a row's
                                          // Element (and therefore its
                                          // _TaskRowState — fresh
                                          // AnimationControllers, fresh
                                          // FutureBuilder subscriptions, etc.)
                                          // whenever that row's index shifts —
                                          // which completing or uncompleting
                                          // any task but the last one in this
                                          // list does, for every row below the
                                          // shift point, all in the same
                                          // frame.
                                          //
                                          // Root cause (see
                                          // package:flutter's
                                          // src/widgets/reorderable_list.dart,
                                          // `_SliverReorderableListState._itemBuilder`):
                                          // every item is internally rewrapped
                                          // as
                                          // `_ReorderableItemGlobalKey(child.key!, index, this)`,
                                          // whose `==`/`hashCode` include
                                          // `index`. So the *effective* key
                                          // Flutter sees for a row changes
                                          // value the moment its index moves,
                                          // even though the ValueKey(task.id)
                                          // we gave ReorderableDragStartListener
                                          // below didn't change. Element reuse
                                          // (`Widget.canUpdate`) requires key
                                          // equality, so a changed index always
                                          // fails that check — old Element
                                          // destroyed, brand new one built at
                                          // the new index. findChildIndexCallback
                                          // only tells the delegate which old
                                          // slot a key used to occupy; it has
                                          // no way to override the key-equality
                                          // check that actually gates whether
                                          // the framework can reuse that slot's
                                          // Element, so it's structurally
                                          // unable to prevent this — kept here
                                          // anyway because it's harmless and
                                          // this callback still unwraps
                                          // correctly (see below).
                                          //
                                          // Debugging hook: `_TaskRowState`
                                          // logs `[jank] _TaskRow builds this
                                          // frame: N` and `[jank] _TaskRow
                                          // initState (fresh State) task=...`
                                          // under DevFlags.verboseSync — a
                                          // spike in N matching most of the
                                          // active list's size, right when a
                                          // completion/uncompletion commits, is
                                          // this. If it's ever a measurable
                                          // bottleneck (vs. today, where it's
                                          // absorbed within one frame budget on
                                          // typical list sizes), the real fix
                                          // is dropping this widget's built-in
                                          // drag-reorder for a hand-rolled one
                                          // over a plain SliverList — proven
                                          // elsewhere in this file (the
                                          // "show all tasks" list above, and
                                          // the completed list below) to
                                          // reconcile shifted ValueKeys
                                          // correctly via
                                          // findChildIndexCallback, since
                                          // neither wraps keys with the index
                                          // baked in.
                                          //
                                          // Separately: SliverReorderableList
                                          // doesn't hand this callback the
                                          // ValueKey we gave
                                          // ReorderableDragStartListener
                                          // directly — it hands us the
                                          // GlobalObjectKey wrapper described
                                          // above, so the key this callback
                                          // receives has to be unwrapped one
                                          // layer first.
                                          findChildIndexCallback: (key) {
                                            final wrapped =
                                                key as GlobalObjectKey;
                                            final id =
                                                (wrapped.value
                                                        as ValueKey<String>)
                                                    .value;
                                            return reorderableIndexById[id];
                                          },
                                        ),
                                    if (!effectiveHideCompleted)
                                      SliverToBoxAdapter(
                                        // Animated so the header + divider
                                        // collapsing away (last completed
                                        // task removed) or appearing (first
                                        // one added) doesn't snap in a single
                                        // frame.
                                        child: AnimatedSize(
                                          key: _completedSectionKey,
                                          duration: _TaskRowState._exitDuration,
                                          curve: Curves.easeInCubic,
                                          alignment: Alignment.topCenter,
                                          child: completedForDisplay.isEmpty
                                              ? const SizedBox(
                                                  width: double.infinity,
                                                )
                                              : Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment
                                                          .stretch,
                                                  children: [
                                                    const Divider(height: 32),
                                                    InkWell(
                                                      onTap: () {
                                                        final next =
                                                            !completedExpanded;
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
                                                          BorderRadius.circular(
                                                            14,
                                                          ),
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
                                      ),
                                    if (!effectiveHideCompleted &&
                                        completedForDisplay.isNotEmpty &&
                                        completedExpanded)
                                      SliverList(
                                        // Same lazy-builder rationale as the
                                        // "all tasks" active section above —
                                        // this section can hold every
                                        // completed task ever created, and a
                                        // list delegate would eagerly build a
                                        // _TaskRow for all of them on every
                                        // rebuild.
                                        delegate: SliverChildBuilderDelegate(
                                          (context, index) {
                                            final task =
                                                completedForDisplay[index];
                                            return _rowFor(
                                              task,
                                              isSelected:
                                                  task.id == _selectedTaskId,
                                              listColor: _listColorFor(
                                                task.listId,
                                                lists,
                                              ),
                                              lists: lists,
                                            );
                                          },
                                          childCount:
                                              completedForDisplay.length,
                                          // See the matching comment on the
                                          // active-list delegate above — an
                                          // uncompletion (or a newly-completed
                                          // task entering here) shifts every
                                          // row below it to a new index, and
                                          // without this callback the
                                          // framework can't match a shifted
                                          // key back to its old Element, so it
                                          // destroys and recreates every one
                                          // of them instead of reusing
                                          // `_rowFor`'s cached widget.
                                          findChildIndexCallback: (key) =>
                                              completedIndexById[(key
                                                      as ValueKey<String>)
                                                  .value],
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 12),
                              _composerBar(composerColor, composerHint),
                            ],
                          ),
                        ),
                      ),
                      // A plain Positioned (no left/width) so the child
                      // determines its own width — same loose-width/
                      // tight-height contract a non-flex Row child used to
                      // get, which the Align below relies on for
                      // widthFactor to size it smaller than 420. Docked to
                      // the right edge always, at whatever width the reveal
                      // animation currently reports (0 to _todoEditPanelWidth).
                      // On open the list beside it (above in this list) has
                      // already made room, so there's nothing underneath to
                      // paint over; on close the list has already snapped
                      // back to full width, so this does paint over it for
                      // the length of the reverse animation (Stack paints
                      // later children on top) until the panel finishes
                      // sliding away.
                      Positioned(
                        top: 0,
                        bottom: 0,
                        right: 0,
                        child: ClipRect(
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
                                      onClose: _closeEditPanel,
                                      onChanged: () {
                                        _invalidateTodoListData();
                                      },
                                      onDeleted: () {
                                        _invalidateTodoListData(
                                          listId: panelTask.listId,
                                        );
                                        _closeEditPanel();
                                      },
                                      onToggleStar: () =>
                                          _toggleStar(panelTask),
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
    required this.hoveredTaskId,
    required this.onToggle,
    required this.onHoverChanged,
    required this.onStar,
    required this.onMoveToBottom,
    required this.onEdit,
    required this.onSetDueDate,
    required this.onClearDueDate,
    required this.onMoveToList,
    required this.onDelete,
    required this.onArmScrollStability,
    required this.lists,
    required this.subtaskStats,
    this.subtaskStatsData,
    this.listColor,
    this.animateIn = false,
    this.forceCollapsed = false,
  });

  final TodoTask task;
  final bool isSelected;

  /// Which row the pointer is currently over, if any. Owned by _TodoPageState
  /// (see _setRowHovered) rather than tracked locally, so the highlight
  /// survives this row's Element being torn down and recreated when a
  /// completion shifts its index in the active list's SliverReorderableList.
  ///
  /// Held as a notifier rather than a resolved bool so a hover change doesn't
  /// have to travel back through the page's build to reach the one row it
  /// affects — see [_RowHoverSurface], the only thing that reads it.
  final ValueListenable<String?> hoveredTaskId;
  final Future<void> Function(bool?) onToggle;

  /// Reports this row's own hover-enter/exit up to _TodoPageState.
  final ValueChanged<bool> onHoverChanged;
  final VoidCallback onStar;

  /// Sends the task to the bottom of its own category (see
  /// [applyMoveToBottomOfCategory]). Null in the "All tasks" view, which has no
  /// manual order to send it to the bottom of — the entry is then left out of
  /// the context menu entirely.
  final VoidCallback? onMoveToBottom;
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

  /// Called right before this row starts shrinking away, but only when it's
  /// uncompleting. The row it grows into afterwards lands at the top of the
  /// active list, above wherever the user is scrolled, unless something
  /// holds the view steady through it — see
  /// _TodoPageState._StableViewScrollController. Completing never calls
  /// this: its regrown row lands in the completed section, always after
  /// wherever the user is looking at active tasks, so it never needs this.
  final VoidCallback onArmScrollStability;

  /// Lists available as move-to targets in the right-click submenu.
  final List<TodoListModel> lists;

  final Future<({int completed, int total})> subtaskStats;

  /// Last known resolved value for [subtaskStats]. Passed as [FutureBuilder.initialData]
  /// so remounted rows never show a blank frame while awaiting the future.
  final ({int completed, int total})? subtaskStatsData;
  final int? listColor;

  /// True when this row is the far half of a toggle the user just made — it is
  /// being inserted where the task landed, so it grows itself in rather than
  /// letting the section below jump down by a full row in one frame.
  final bool animateIn;

  /// True for a task that just left the active list (completed) but is
  /// still being counted in its old section's item list for one extra
  /// frame, so SliverReorderableList's item count doesn't change in the
  /// same frame its data does (see _TodoPageState._lingeringActiveIds).
  /// This row already finished collapsing before that happened, so it's
  /// already invisible — this only suppresses didUpdateWidget's normal
  /// "un-collapse a row that survived" safety net, which would otherwise
  /// spring it back open since, as far as it can tell, it's a normal row
  /// that happens to still be here.
  final bool forceCollapsed;

  @override
  State<_TaskRow> createState() => _TaskRowState();
}

class _TaskRowState extends State<_TaskRow> with TickerProviderStateMixin {
  static const _exitDuration = Duration(milliseconds: 160);

  // Counts how many _TaskRow builds land in the same frame, to check whether
  // a jank spike is proportional to how many rows the sliver's cacheExtent
  // keeps mounted (and therefore rebuilt on every setState) rather than to
  // how many rows are actually on screen.
  static var _rowBuildsThisFrame = 0;
  static var _rowBuildFlushScheduled = false;

  static void _noteRowBuild() {
    if (!DevFlags.verboseSync) return;
    _rowBuildsThisFrame++;
    if (_rowBuildFlushScheduled) return;
    _rowBuildFlushScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      debugPrint('[jank] _TaskRow builds this frame: $_rowBuildsThisFrame');
      _rowBuildsThisFrame = 0;
      _rowBuildFlushScheduled = false;
    });
  }

  late final AnimationController _animController;
  late Animation<double> _checkScale;
  var _configuredCheckMotion = false;

  // Drives the row between "full height" (0.0) and "collapsed to nothing"
  // (1.0). Run forward it collapses the row out of its section before the
  // toggle is committed; run in reverse it grows the row back in where the task
  // landed, so neither side of the move happens in a single frame.
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
    if (DevFlags.verboseSync) {
      debugPrint(
        '[jank] _TaskRow initState (fresh State) task=${widget.task.id.substring(0, 8)} '
        'hasCachedStats=${_cachedStats != null} '
        'hasInitialData=${widget.subtaskStatsData != null}',
      );
    }
    _displayCompleted = widget.task.completed;
    // Finalized in didChangeDependencies — inherited-widget lookups
    // (VoyagerMotion.reduced needs MediaQuery) aren't safe in initState.
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _checkScale = _animController;

    if (widget.task.completed) {
      _animController.value = 1.0;
    }

    _exitController = AnimationController(vsync: this, duration: _exitDuration);
    _exitSize = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(parent: _exitController, curve: Curves.easeInCubic),
    );
    // Deliberately the exact same animation as _exitSize, not a separately
    // curved one: SizeTransition clips its child to whatever height
    // sizeFactor currently allows, from the top down, so a row's due
    // date/notes/subtask line — sitting below the title — clips out before
    // the title does on the way down, and clips back in after it on the way
    // up. An earlier version gave fade its own lead/lag curve to try to
    // keep the whole row invisible until it was too squashed to look
    // clipped, but that only bounded the *row's* clip point, not the
    // metadata line's, which sits at a different fraction of the row's
    // height than the curves assumed — so the subtext still flashed in and
    // out out of sync with its own clip. Tying opacity to the identical
    // value as size instead guarantees the two can never disagree: whatever
    // fraction of the row's height is visible is exactly its opacity too,
    // for every part of the row, at every instant.
    _exitFade = _exitSize;

    // This row is the far half of a toggle the user just made: it is being
    // inserted where the task landed, so grow it in rather than letting the
    // section below it jump down by a full row in one frame.
    if (widget.animateIn) {
      _exitController.value = 1.0;
      _exitController.reverse();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_configuredCheckMotion) return;
    _configuredCheckMotion = true;
    final reducedMotion = VoyagerMotion.reduced(context);
    _animController.duration = reducedMotion
        ? VoyagerMotion.crossfade
        : const Duration(milliseconds: 200);
    // Reduced motion drops the pop-overshoot entirely, matching
    // VoyagerCheckbox's treatment of the same interaction.
    _checkScale = reducedMotion
        ? const AlwaysStoppedAnimation<double>(1.0)
        : TweenSequence<double>([
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
  }

  @override
  void didUpdateWidget(covariant _TaskRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    // This row collapsed for a toggle but survived the commit's rebuild rather
    // than being disposed (e.g. the completed section is hidden, or the toggle
    // didn't take). Un-collapse it so it isn't stranded at zero height. Gated on
    // isCompleted so an unrelated rebuild mid-collapse can't cut the animation
    // short — only a fully collapsed, superseded row is restored here. Also
    // skipped while forceCollapsed: that means it's deliberately still here
    // for one more frame (see _TodoPageState._lingeringActiveIds), not
    // stranded, and un-collapsing it now would be exactly the harmful
    // spring-back this check exists to prevent.
    if (_isShifting && _exitController.isCompleted && !widget.forceCollapsed) {
      _isShifting = false;
      _exitController.value = 0;
    }
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
    final target = value ?? false;
    // Every tap counts and the latest one wins: bump the generation so any
    // toggle already in flight bows out at its next checkpoint.
    final currentGen = ++_toggleGeneration;

    // A superseded toggle may have left the row mid-collapse. Restore it to full
    // height first so this toggle animates from a known state — and so a row can
    // never be stranded collapsed to nothing (and thus untappable) when taps
    // land faster than the animation.
    if (_isShifting) {
      _isShifting = false;
      _exitController.value = 0;
    }

    setState(() {
      _displayCompleted = target;
    });

    if (target) {
      _celebrate();
      await _animController.forward();
    } else {
      await _animController.reverse();
    }

    if (!mounted || _toggleGeneration != currentGen) return;

    // Only uncompleting needs this: its regrown row lands at the very top
    // of the active list, above wherever the user is scrolled. Completing's
    // regrown row lands in the completed section — after wherever the user
    // is looking at active tasks — so it never needs correction, the same
    // way completing the very top task never has. Armed before the shrink
    // starts, not after: by the time widget.onToggle's caller could arm it,
    // this row would already have played its shrink — though that part is
    // never explicitly corrected either way (see
    // _StableViewScrollPosition.correctForNewDimensions).
    if (!target) {
      widget.onArmScrollStability();
    }

    // Shrink the row away in place first, in whichever section it's
    // currently in, before committing. Committing moves the task to the
    // other section on the very next build, so without this the rows left
    // behind would jump into the gap in a single frame instead of the gap
    // closing smoothly underneath a row that's already gone.
    //
    // Leave the row collapsed once this finishes. The commit rebuilds it
    // into the other section as a fresh State and disposes this one, so
    // restoring its height here is both unnecessary and harmful: it would
    // run in the frame before that rebuild lands, briefly re-expanding the
    // outgoing row to full height while the incoming row is already full
    // height — the whole list shudders down then up. A row that survives
    // the commit instead (its section is hidden, or the toggle didn't take)
    // is un-collapsed in didUpdateWidget.
    _isShifting = true;
    await _exitController.forward();
    if (!mounted || _toggleGeneration != currentGen) return;
    unawaited(widget.onToggle(target));
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
            color: Color.lerp(accent, VoyagerColors.of(context).onAccent, p)!,
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
      if (widget.onMoveToBottom case final onMoveToBottom?)
        ContextMenuItem(
          label: 'Send to bottom',
          icon: PhosphorIconsRegular.arrowDown,
          onTap: onMoveToBottom,
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
    _noteRowBuild();
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
          child: MouseRegion(
            onEnter: (_) => widget.onHoverChanged(true),
            onExit: (_) => widget.onHoverChanged(false),
            child: ContextMenuRegion(
              itemsBuilder: () => _buildContextMenuItems(listColor),
              child: _RowHoverSurface(
                taskId: widget.task.id,
                hoveredTaskId: widget.hoveredTaskId,
                selected: widget.isSelected,
                child: InkWell(
                  onTap: widget.onEdit,
                  borderRadius: BorderRadius.circular(14),
                  // The hover tint is painted by _RowHoverSurface above (from
                  // _TodoPageState._setRowHovered) instead of this InkWell's
                  // own ephemeral hover state, so it survives this row's
                  // Element being torn down and recreated whenever a
                  // completion shifts its index in the active list's
                  // SliverReorderableList — see the KNOWN LIMITATION comment
                  // where that list is built. Left as its own overlay here,
                  // this would blink off and back on for a frame every time
                  // that happens, even though the pointer never moved.
                  hoverColor: Colors.transparent,
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

/// The rounded surface a task row sits on, and the only part of the row whose
/// appearance depends on hover.
///
/// It listens to the page-wide "which row is hovered" notifier directly and
/// rebuilds itself only when *this* row's answer flips, so crossing a row
/// costs two of these tiny rebuilds instead of one rebuild of the whole page.
/// [child] is passed in already-built and handed straight back through, so the
/// row's actual contents — checkbox, title, metadata, star — are never
/// rebuilt by a hover at all.
///
/// A ValueListenableBuilder would be the obvious spelling, but it rebuilds on
/// every notification, which here means every mounted row reacting to a change
/// that concerns two of them.
class _RowHoverSurface extends StatefulWidget {
  const _RowHoverSurface({
    required this.taskId,
    required this.hoveredTaskId,
    required this.selected,
    required this.child,
  });

  final String taskId;
  final ValueListenable<String?> hoveredTaskId;
  final bool selected;
  final Widget child;

  @override
  State<_RowHoverSurface> createState() => _RowHoverSurfaceState();
}

class _RowHoverSurfaceState extends State<_RowHoverSurface> {
  late bool _hovered;

  @override
  void initState() {
    super.initState();
    // Read rather than assume false: this row's Element may have just been
    // recreated under a stationary cursor (see _TaskRow.hoveredTaskId), in
    // which case it is already the hovered one and must paint that way on its
    // very first frame.
    _hovered = widget.hoveredTaskId.value == widget.taskId;
    widget.hoveredTaskId.addListener(_onHoverChanged);
  }

  @override
  void didUpdateWidget(covariant _RowHoverSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.hoveredTaskId != widget.hoveredTaskId) {
      oldWidget.hoveredTaskId.removeListener(_onHoverChanged);
      widget.hoveredTaskId.addListener(_onHoverChanged);
    }
    if (oldWidget.taskId != widget.taskId) {
      _hovered = widget.hoveredTaskId.value == widget.taskId;
    }
  }

  @override
  void dispose() {
    widget.hoveredTaskId.removeListener(_onHoverChanged);
    super.dispose();
  }

  void _onHoverChanged() {
    final hovered = widget.hoveredTaskId.value == widget.taskId;
    if (hovered == _hovered) return;
    setState(() => _hovered = hovered);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
      decoration: VoyagerListItemSurface.decoration(
        context,
        selected: widget.selected,
        hovered: _hovered,
        borderRadius: 14,
      ),
      child: widget.child,
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
