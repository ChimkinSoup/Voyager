import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/sound/app_sounds.dart';
import 'package:voyager/core/constants/todo_constants.dart';
import 'package:voyager/core/theme/palette_color.dart';
import 'package:voyager/core/utils/all_view_destination.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/utils/time_format.dart';
import 'package:voyager/core/widgets/datetime_selector_popover.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/scope_switcher.dart';
import 'package:voyager/core/widgets/selector_pill.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/domain/todo/todo_task_sorting.dart';
import 'package:voyager/features/hotkeys/floaters/floater_app_icon.dart';
import 'package:voyager/features/hotkeys/floaters/floater_controller.dart';
import 'package:voyager/features/hotkeys/quick_capture.dart';

enum _Panel { due, list }

/// Taller than the picker's own size, for the width the bar gives it: the
/// picker spends the extra height on a wider calendar.
final double _datePickerHeight = kDateTimeSelectorPopoverSize.height + 80;

/// The slot under the picker that the "No due date" button is centred in.
/// Fixed rather than the button's own height, which the window is sized for
/// before it is laid out: a taller button scales down to fit instead.
const double _noDueDateHeight = 53;

/// The todo hotkey's Spotlight-style quick-add bar.
///
/// The date and list pickers open inline below the bar, growing the window,
/// rather than as popovers: a popover can't draw outside a window this short.
class TodoFloater extends ConsumerStatefulWidget {
  const TodoFloater({super.key});

  @override
  ConsumerState<TodoFloater> createState() => _TodoFloaterState();
}

class _TodoFloaterState extends ConsumerState<TodoFloater> {
  late final TextEditingController _title;
  final _titleFocus = FocusNode();
  _Panel? _panel;
  var _saving = false;

  /// The open date picker's pick before Done or Enter, kept when the panel is
  /// closed another way, as a dismissed picker keeps it on the Todo page.
  DateTimePick? _pendingDue;

  /// The bar's height: the whole window when no picker is open, measured
  /// rather than taken from the 64 the window is asked for, since the
  /// frameless frame still takes a few pixels of client area. Held while a
  /// picker resizes the window, so the bar doesn't stretch into the room.
  double _barHeight = 60;
  var _resizing = false;

  /// The panel last asked for, which a click toggles against while the
  /// window is still resizing for it; and a count of the asks, so a resize
  /// overtaken by a newer one leaves the panel and [_resizing] to that one.
  _Panel? _wanted;
  var _panelChange = 0;

  /// Read off disk: the Todo page records list touches straight through the
  /// repository, so [settingsProvider] can lag them.
  String? _lastTouchedId;

  late final FloaterController _floaters;

  @override
  void initState() {
    super.initState();
    // A dismiss with the date picker open keeps its pick too.
    _floaters = ref.read(floaterControllerProvider)
      ..registerFlush(_flushPendingDue);
    _title = TextEditingController(
      text: ref.read(todoCaptureDraftProvider).title,
    )..addListener(_keepTitleInDraft);
    ref.read(settingsRepositoryProvider).getSettings().then((settings) {
      if (mounted) {
        setState(() => _lastTouchedId = settings.lastViewedTodoListId);
      }
    });
  }

  @override
  void dispose() {
    _floaters.unregisterFlush(_flushPendingDue);
    _title
      ..removeListener(_keepTitleInDraft)
      ..dispose();
    _titleFocus.dispose();
    super.dispose();
  }

  void _keepTitleInDraft() {
    final notifier = ref.read(todoCaptureDraftProvider.notifier);
    if (notifier.state.title == _title.text) return;
    notifier.state = notifier.state.copyWith(title: _title.text);
  }

  /// The picked list while it still stands (see [TodoCaptureDraft.listIdBasis]),
  /// else the last-touched list.
  static String _targetListId(
    List<TodoListModel> lists,
    String? lastTouchedId,
    TodoCaptureDraft draft,
  ) {
    final picked = draft.listIdBasis == lastTouchedId ? draft.listId : null;
    return resolveNewItemTarget(
          currentId: picked,
          lastViewedId: lastTouchedId,
          legacyId: legacyTodoListId,
          availableIds: [for (final list in lists) list.id],
        ) ??
        legacyTodoListId;
  }

  /// Whether [change] is still the latest panel change once its resize is
  /// done.
  Future<bool> _setExtraHeight(double extraHeight, int change) async {
    _resizing = true;
    await ref.read(floaterControllerProvider).setExtraHeight(extraHeight);
    if (!mounted || change != _panelChange) return false;
    setState(() => _resizing = false);
    return true;
  }

  double _panelHeight(_Panel panel, int listCount) => switch (panel) {
    // Room for the "No due date" button only when it shows, so the picker
    // above it is the same size either way.
    _Panel.due =>
      1 +
          _datePickerHeight +
          (ref.read(todoCaptureDraftProvider).dueDate == null
              ? 0
              : _noDueDateHeight),
    _Panel.list => ScopeMenu.heightFor(context, listCount) + 16,
  };

  Future<void> _togglePanel(_Panel panel, int listCount) async {
    _keepPendingDue();
    final next = _wanted == panel ? null : panel;
    if (next == null) {
      _closePanel();
      return;
    }
    _wanted = next;
    final change = ++_panelChange;
    final height = _panelHeight(next, listCount);
    if (_panel != null) {
      // From one panel to the other: swapped at once, each laid out at its
      // own height from the top, so the resize after only moves the bottom
      // edge — the old panel isn't squashed or re-centred into the new size.
      _resizing = true;
      setState(() => _panel = next);
      await _setExtraHeight(height, change);
      return;
    }
    // The window grows first and the panel comes after, into a window already
    // painted at the new size: built in the frame the window grows in, the
    // panel made that frame slow enough for the uncovered area to show black.
    if (await _setExtraHeight(height, change)) setState(() => _panel = next);
  }

  Future<void> _flushPendingDue() async => _keepPendingDue();

  void _keepPendingDue() {
    final due = _pendingDue;
    if (due == null) return;
    _pendingDue = null;
    final notifier = ref.read(todoCaptureDraftProvider.notifier);
    notifier.state = notifier.state.copyWith(
      dueDate: due.dateTime,
      dueHasTime: due.hasTime,
    );
  }

  void _closePanel() {
    // Flagged before the rebuild below, which would otherwise measure the
    // window before it has shrunk.
    _resizing = true;
    _wanted = null;
    setState(() => _panel = null);
    unawaited(_setExtraHeight(0, ++_panelChange));
    _titleFocus.requestFocus();
  }

  void _pickDue(DateTimePick? due) {
    _pendingDue = null;
    final notifier = ref.read(todoCaptureDraftProvider.notifier);
    notifier.state = due == null
        ? notifier.state.copyWith(clearDueDate: true)
        : notifier.state.copyWith(
            dueDate: due.dateTime,
            dueHasTime: due.hasTime,
          );
    _closePanel();
  }

  void _pickList(String listId) {
    final notifier = ref.read(todoCaptureDraftProvider.notifier);
    final draft = notifier.state;
    notifier.state = TodoCaptureDraft(
      title: draft.title,
      dueDate: draft.dueDate,
      dueHasTime: draft.dueHasTime,
      listId: listId,
      listIdBasis: _lastTouchedId,
    );
    _closePanel();
  }

  /// Same create rules as the Todo page's composer.
  Future<void> _save() async {
    if (_saving) return;
    final title = _title.text.trim();
    if (title.isEmpty) {
      // Enter let go of the keyboard before this ran; the bar is driven by
      // keyboard alone, so what's typed next would go nowhere.
      _titleFocus.requestFocus();
      return;
    }
    _saving = true;
    _keepPendingDue();
    final container = ProviderScope.containerOf(context, listen: false);
    final draft = ref.read(todoCaptureDraftProvider);
    try {
      final repo = container.read(todoRepositoryProvider);
      final remoteSync = container.read(remoteSyncServiceProvider);
      var lists = await repo.listLists();
      if (lists.isEmpty) {
        final now = utcNow();
        final list = TodoListModel(
          id: legacyTodoListId,
          name: 'To-do',
          createdAt: now,
          updatedAt: now,
        );
        await repo.upsertList(list);
        remoteSync.pushTodoList(list);
        lists = await repo.listLists();
      }
      final settingsRepo = container.read(settingsRepositoryProvider);
      final settings = await settingsRepo.getSettings();
      final listId = _targetListId(lists, settings.lastViewedTodoListId, draft);
      final now = utcNow();
      final due = draft.dueDate?.toUtc();
      final task = TodoTask(
        id: newId(),
        listId: listId,
        title: title,
        dueDate: due,
        dueHasTime: due != null && draft.dueHasTime,
        dueDateSetAt: due == null ? null : now,
        createdAt: now,
        updatedAt: now,
      );
      final siblings = await repo.listTasks(listId);
      final batch = applyTaskPlacement(task, activeTopLevelTasks(siblings));
      for (final updated in batch.tasks) {
        await repo.upsertTask(updated);
        remoteSync.pushTodoTaskInBackground(updated);
      }
      // A save is a touch: the next bar, and the Todo page, default here.
      if (settings.lastViewedTodoListId != listId) {
        await container
            .read(settingsProvider.notifier)
            .saveSettings(settings.copyWith(lastViewedTodoListId: listId));
      }
      container
        ..invalidate(todoTasksProvider)
        ..invalidate(allTodoTasksProvider)
        ..invalidate(todoListsProvider)
        ..invalidate(todoListStatsProvider);
      container.read(todoCaptureDraftProvider.notifier).state =
          const TodoCaptureDraft();
      final listName = lists
          .firstWhere((list) => list.id == listId, orElse: () => lists.first)
          .name;
      container.read(appSoundsProvider).play(AppSound.saved);
      await container
          .read(floaterControllerProvider)
          .completeWith('Added to $listName');
    } catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'TodoFloater',
          context: ErrorDescription('while adding a quick task'),
        ),
      );
    } finally {
      _saving = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final lists = ref.watch(todoListsProvider.settled).valueOrNull ?? const [];
    final stats = ref.watch(todoListStatsProvider).valueOrNull;
    final draft = ref.watch(todoCaptureDraftProvider);
    final targetId = _targetListId(lists, _lastTouchedId, draft);
    final targetName = lists
        .where((list) => list.id == targetId)
        .map((list) => list.name)
        .firstOrNull;
    final due = draft.dueDate;
    final hasTime = due != null && draft.dueHasTime;

    final bar = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: Row(
        children: [
          const FloaterAppIcon(PhosphorIconsRegular.checkCircle, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: VoyagerTextField(
              controller: _title,
              focusNode: _titleFocus,
              autofocus: true,
              accentColor: accent,
              style: theme.textTheme.titleMedium,
              decoration: const InputDecoration(
                hintText: 'Add a task',
                isDense: true,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
              ),
              onSubmitted: (_) => _save(),
            ),
          ),
          const SizedBox(width: 8),
          SelectorPill(
            icon: PhosphorIconsRegular.calendar,
            label: due == null
                ? 'Due'
                : DateFormat.MMMd().format(due) +
                      (hasTime ? ' at ${formatTime12Hour(due)}' : ''),
            isActive: _panel == _Panel.due,
            accentColor: accent,
            onTap: () => _togglePanel(_Panel.due, lists.length),
          ),
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 150),
            child: SelectorPill(
              icon: PhosphorIconsRegular.listBullets,
              label: targetName ?? 'List',
              isActive: _panel == _Panel.list,
              accentColor: accent,
              onTap: () => _togglePanel(_Panel.list, lists.length),
            ),
          ),
        ],
      ),
    );

    final panel = _panel;
    return LayoutBuilder(
      builder: (context, constraints) {
        if (panel == null && !_resizing) _barHeight = constraints.maxHeight;
        // Laid out at its own height whatever the window's, which only
        // catches up a frame or two later: the window's bottom edge then
        // reveals or trims it, and nothing in it moves.
        return ClipRect(
          child: OverflowBox(
            alignment: Alignment.topCenter,
            maxHeight: double.infinity,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(height: _barHeight, child: bar),
                if (panel != null)
                  SizedBox(
                    height: _panelHeight(panel, lists.length),
                    child: _panelFor(
                      panel,
                      due: due,
                      hasTime: hasTime,
                      lists: lists,
                      stats: stats,
                      targetId: targetId,
                      accent: accent,
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _panelFor(
    _Panel panel, {
    required DateTime? due,
    required bool hasTime,
    required List<TodoListModel> lists,
    required Map<String, ({int active, int completed})>? stats,
    required String targetId,
    required Color accent,
  }) {
    return switch (panel) {
      _Panel.due => Column(
        children: [
          // Edge to edge under the bar, so the panel reads as the bar opening
          // up rather than a picker set on the window's background.
          const Divider(height: 1),
          Expanded(
            child: DateTimeSelectorPopover(
              initialDateTime: due ?? DateTime.now(),
              accentColor: accent,
              optionalTime: true,
              initialHasTime: hasTime,
              onSubmitted: _pickDue,
              onChanged: (due) => _pendingDue = due,
            ),
          ),
          if (due != null)
            SizedBox(
              height: _noDueDateHeight,
              child: Center(
                child: GlassButton(
                  dense: true,
                  onPressed: () => _pickDue(null),
                  label: 'No due date',
                  color: accent,
                ),
              ),
            ),
        ],
      ),
      _Panel.list => Padding(
        padding: const EdgeInsets.all(8),
        // The Todo page's list menu, minus its All tasks row: a task can't be
        // filed under that.
        child: ScopeMenu<String>(
          items: [
            for (final list in lists)
              ScopeSwitcherItem<String>(
                value: list.id,
                label: list.name,
                count: () {
                  final stat = stats?[list.id];
                  return '${stat?.active ?? 0} | ${stat?.completed ?? 0}';
                }(),
                color: paletteColor(
                  list.colorValue ?? accent.toARGB32(),
                  context,
                ),
              ),
          ],
          selectedValue: targetId,
          onSelected: _pickList,
          appAccent: accent,
        ),
      ),
    };
  }
}
