import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/constants/todo_constants.dart';
import 'package:voyager/core/utils/all_view_destination.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/utils/time_format.dart';
import 'package:voyager/core/widgets/datetime_selector_popover.dart';
import 'package:voyager/core/widgets/selector_pill.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/domain/todo/todo_task_sorting.dart';
import 'package:voyager/features/hotkeys/floaters/floater_app_icon.dart';
import 'package:voyager/features/hotkeys/floaters/floater_controller.dart';
import 'package:voyager/features/hotkeys/quick_capture.dart';

enum _Panel { due, list }

/// The picker plus the "No due date" button under it.
final double _datePanelHeight = kDateTimeSelectorPopoverSize.height + 50;
const double _listRowHeight = 40;

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

  Future<void> _setExtraHeight(double extraHeight) async {
    _resizing = true;
    await ref.read(floaterControllerProvider).setExtraHeight(extraHeight);
    if (mounted) setState(() => _resizing = false);
  }

  Future<void> _togglePanel(_Panel panel, int listCount) async {
    _keepPendingDue();
    final next = _panel == panel ? null : panel;
    if (next == null) {
      _closePanel();
      return;
    }
    // The window grows first and the panel comes after, into a window already
    // painted at the new size: built in the frame the window grows in, the
    // panel made that frame slow enough for the uncovered area to show black.
    await _setExtraHeight(switch (next) {
      _Panel.due => _datePanelHeight,
      _Panel.list => (listCount * _listRowHeight + 16).clamp(0, 320),
    });
    if (mounted) setState(() => _panel = next);
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
    setState(() => _panel = null);
    unawaited(_setExtraHeight(0));
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

    return LayoutBuilder(
      builder: (context, constraints) {
        if (_panel == null && !_resizing) _barHeight = constraints.maxHeight;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(height: _barHeight, child: bar),
            if (_panel == _Panel.due)
              Expanded(
                child: Column(
                  children: [
                    Expanded(
                      child: Center(
                        child: SizedBox.fromSize(
                          size: kDateTimeSelectorPopoverSize,
                          child: DateTimeSelectorPopover(
                            initialDateTime: due ?? DateTime.now(),
                            accentColor: accent,
                            optionalTime: true,
                            initialHasTime: hasTime,
                            onSubmitted: _pickDue,
                            onChanged: (due) => _pendingDue = due,
                          ),
                        ),
                      ),
                    ),
                    if (due != null)
                      TextButton(
                        onPressed: () => _pickDue(null),
                        child: const Text('No due date'),
                      ),
                  ],
                ),
              ),
            if (_panel == _Panel.list)
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 8,
                  ),
                  children: [
                    for (final list in lists)
                      SizedBox(
                        height: _listRowHeight,
                        child: ListTile(
                          dense: true,
                          selected: list.id == targetId,
                          selectedColor: accent,
                          title: Text(list.name),
                          onTap: () => _pickList(list.id),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}
