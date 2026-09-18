import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/constants/todo_constants.dart';
import 'package:voyager/core/utils/all_view_destination.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/date_selector_popover.dart';
import 'package:voyager/core/widgets/selector_pill.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/domain/todo/todo_task_sorting.dart';
import 'package:voyager/features/hotkeys/floaters/floater_app_icon.dart';
import 'package:voyager/features/hotkeys/floaters/floater_controller.dart';
import 'package:voyager/features/hotkeys/quick_capture.dart';

enum _Panel { due, list }

/// The picker plus the "No due date" button under it.
const double _datePanelHeight = 430;
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

  /// Read off disk: the Todo page records list touches straight through the
  /// repository, so [settingsProvider] can lag them.
  String? _lastTouchedId;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: ref.read(todoCaptureDraftProvider).title)
      ..addListener(_keepTitleInDraft);
    ref.read(settingsRepositoryProvider).getSettings().then((settings) {
      if (mounted) {
        setState(() => _lastTouchedId = settings.lastViewedTodoListId);
      }
    });
  }

  @override
  void dispose() {
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

  void _togglePanel(_Panel panel, int listCount) {
    final next = _panel == panel ? null : panel;
    setState(() => _panel = next);
    ref
        .read(floaterControllerProvider)
        .setExtraHeight(switch (next) {
          null => 0,
          _Panel.due => _datePanelHeight,
          _Panel.list => (listCount * _listRowHeight + 16).clamp(0, 320),
        });
    if (next == null) _titleFocus.requestFocus();
  }

  void _closePanel() {
    setState(() => _panel = null);
    ref.read(floaterControllerProvider).setExtraHeight(0);
    _titleFocus.requestFocus();
  }

  void _pickDue(DateTime? day) {
    final notifier = ref.read(todoCaptureDraftProvider.notifier);
    notifier.state = day == null
        ? notifier.state.copyWith(clearDueDate: true)
        : notifier.state.copyWith(
            dueDate: DateTime(day.year, day.month, day.day),
          );
    _closePanel();
  }

  void _pickList(String listId) {
    final notifier = ref.read(todoCaptureDraftProvider.notifier);
    final draft = notifier.state;
    notifier.state = TodoCaptureDraft(
      title: draft.title,
      dueDate: draft.dueDate,
      listId: listId,
      listIdBasis: _lastTouchedId,
    );
    _closePanel();
  }

  /// Same create rules as the Todo page's composer.
  Future<void> _save() async {
    if (_saving) return;
    final title = _title.text.trim();
    if (title.isEmpty) return;
    _saving = true;
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
    final lists = ref.watch(todoListsProvider).valueOrNull ?? const [];
    final draft = ref.watch(todoCaptureDraftProvider);
    final targetId = _targetListId(lists, _lastTouchedId, draft);
    final targetName = lists
        .where((list) => list.id == targetId)
        .map((list) => list.name)
        .firstOrNull;
    final due = draft.dueDate;

    // Shorter than the window's 68: the frameless frame still takes a few
    // pixels of client area.
    final bar = SizedBox(
      height: 60,
      child: Padding(
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
                ),
                onSubmitted: (_) => _save(),
              ),
            ),
            const SizedBox(width: 8),
            SelectorPill(
              icon: PhosphorIconsRegular.calendar,
              label: due == null ? 'Due' : DateFormat.MMMd().format(due),
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
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        bar,
        if (_panel == _Panel.due)
          Expanded(
            child: Column(
              children: [
                Expanded(
                  child: Center(
                    child: SizedBox(
                      width: 320,
                      child: DateSelectorPopover(
                        initialStartDate: due ?? DateTime.now(),
                        initialEndDate: due ?? DateTime.now(),
                        singleDateMode: true,
                        inlineMode: true,
                        accentColor: accent,
                        onDateSelected: _pickDue,
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
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
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
  }
}
