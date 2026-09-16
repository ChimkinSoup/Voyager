import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';
import 'package:intl/intl.dart';
import 'package:voyager/core/widgets/voyager_prose_text.dart';
import 'package:voyager/core/widgets/contextual_popover.dart';
import 'package:voyager/core/widgets/datetime_selector_popover.dart';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/dev/dev_flags.dart';
import 'package:voyager/core/dev/journal_debug_logger.dart';
import 'package:voyager/core/layout/window_size_class.dart';
import 'package:voyager/core/motion/motion.dart';
import 'package:voyager/core/widgets/compact_back_bar.dart';
import 'package:voyager/features/shell/shell_back_interceptor.dart';
import 'package:voyager/core/constants/journal_constants.dart';
import 'package:voyager/core/media/widgets/media_drop_target.dart';
import 'package:voyager/core/media/widgets/media_fan_stack.dart';
import 'package:voyager/core/media/widgets/media_paste_scope.dart';
import 'package:voyager/core/soft_delete/soft_delete_toast.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/pending_text_merge.dart';
import 'package:voyager/core/sync/journal_write_coordinator.dart';
import 'package:voyager/core/sync/pending_flush_registry.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/sync/text_delta_injector.dart';
import 'package:voyager/core/text/list_text_editing.dart';
import 'package:voyager/core/widgets/context_menu.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/voyager_dialog.dart';
import 'package:voyager/core/theme/voyager_menu_theme.dart';
import 'package:voyager/core/theme/voyager_list_item_surface.dart';
import 'package:voyager/core/theme/voyager_spacing.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:voyager/core/widgets/confirm_dialog.dart';
import 'package:voyager/core/widgets/voyager_popup_menu_item.dart';

import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/utils/journal_tags.dart';
import 'package:voyager/core/utils/time_format.dart';
import 'package:voyager/core/widgets/tag_highlighted_text_field.dart';
import 'package:voyager/core/widgets/ctrl_enter_to_submit_scope.dart';
import 'package:voyager/core/widgets/enter_to_submit_scope.dart';
import 'package:voyager/core/widgets/keep_alive_scroll.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/core/widgets/mood_gradient_slider.dart';
import 'package:voyager/core/widgets/resizable_pane_divider.dart';
import 'package:voyager/core/widgets/scope_switcher.dart';
import 'package:voyager/core/widgets/selector_pill.dart';
import 'package:voyager/core/widgets/voyager_menu_catalog.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/core/widgets/journal_color_flag.dart';
import 'package:voyager/core/widgets/weather_icon.dart';
import 'package:voyager/features/journal/journal_entry_actions.dart';
import 'package:voyager/features/journal/journal_entry_delete.dart';
import 'package:voyager/features/journal/journal_manage_sheet.dart';
import 'package:voyager/features/shell/shell_page_storage_keys.dart';
import 'package:voyager/features/sync/sync_conflict_banner.dart';
import 'package:voyager/core/tags/tag_suggestions.dart';
import 'package:voyager/core/utils/all_view_destination.dart';
import 'package:voyager/core/widgets/search_highlight_text.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';

/// Everything that affects what a `_JournalEntryListTile` renders (outside
/// of the live title/body preview, which is driven separately by
/// `titlePreview`/`bodyPreview`). Used to decide whether a cached row widget
/// instance (see `_JournalPageState._rowFor`) can be reused as-is.
typedef _JournalRowSignature = ({
  String title,
  String body,
  DateTime entryDate,
  bool isSelected,
});

/// Below this the editor's metadata row stacks the mood bar above its
/// controls. The controls (weather, date pill, trash and the dev remote-pull
/// button) take ~335px and the "Mood" label another ~60, so this leaves the
/// slider about 120px before it gets a line to itself.
const double _journalMetadataRowMinWidth = 520;

/// The date/time pill's floor width, so the metadata row doesn't shift when the
/// selection moves between entries whose labels are spelled at different
/// lengths ("Sep 1, 2026 at 4:20 AM" against "May 10, 2026 at 10:00 AM"). 200
/// clears the widest label the formatter can produce — measured at 183.3px in
/// `labelLarge` — plus the pill's own 8px of horizontal padding a side.
const double _journalDatePillMinWidth = 200;

class JournalPage extends ConsumerStatefulWidget {
  const JournalPage({super.key});

  @override
  ConsumerState<JournalPage> createState() => _JournalPageState();
}

class _JournalPageState extends ConsumerState<JournalPage> {
  static const _localSaveDebounce = Duration(milliseconds: 400);
  static const _entryListHeaderPadding = 12.0;
  static const _entryListHeaderHeight = 72.0;
  static const _entryListFooterHeight = 72.0;

  String _journalFilter = legacyJournalId;
  var _viewAllJournals = false;
  final _optimisticallyHiddenEntryIds = <String>{};
  final _pendingEntries = <String, JournalEntry>{};
  final _pendingEntryIds = <String>[];
  final _entryListScrollController = ScrollController();
  String? _selectedEntryId;
  JournalEntry? _selectedEntry;
  final _selectedEntryKey = GlobalKey();
  bool _shouldScrollToSelected = false;
  final _titleController = TextEditingController();
  final _titleFocusNode = FocusNode();
  final _bodyFocusNode = FocusNode();
  final _editorKey = GlobalKey<_PlainJournalEditorState>();
  final _listTitlePreview = ValueNotifier<String>('');
  final _listBodyPreview = ValueNotifier<String>('');
  final _entryBodyDrafts = <String, String>{};
  // Reuses the same _JournalEntryListTile widget instance across rebuilds
  // for entries whose _JournalRowSignature hasn't changed, so Flutter's
  // element reconciliation skips rebuilding them entirely — _persistEntryEdits
  // invalidates journalListEntriesProvider unconditionally on every
  // ~400ms-debounced autosave while typing, which would otherwise
  // reconstruct, and thus rebuild, every mounted+cached row, not just the
  // entry being edited (which already has its own live-preview mechanism
  // via titlePreview/bodyPreview). Keyed by entry id; pruned to the ids
  // actually displayed at the end of every build.
  final _rowWidgetCache = <String, _JournalEntryListTile>{};
  final _rowSignatureCache = <String, _JournalRowSignature>{};
  Timer? _metadataSaveTimer;
  Timer? _bodySaveTimer;
  Future<void>? _flushInProgress;
  var _metadataDirty = false;
  var _suppressAutoSelect = false;
  var _appliedSavedPreferences = false;

  /// The journal [_applySavedPreferencesIfReady] is about to restore into,
  /// held only for the frame between deciding it and the post-frame setState
  /// that commits it. See that method for why the gap matters.
  String? _pendingRestoreJournalId;
  int? _mood;
  String? _weatherIcon;
  RemoteSyncService? _remoteSync;
  JournalRepository? _journalRepository;
  JournalWriteCoordinator? _journalWriteCoordinator;
  void Function()? _invalidateJournalCaches;
  JournalDebugLogger? _journalDebugLogger;
  double? _entryListWidth;
  double? _entryListDragStartWidth;
  var _entryListDragging = false;
  DateTime? _lastEntryCreatedAt;

  /// Phone shell only: whether the editor is covering the entry list.
  ///
  /// Deliberately separate from [_selectedEntryId], which keeps meaning "the
  /// entry the editor is bound to" on both shells. Opening the phone editor is
  /// a navigation event, not a selection change — so the list can arrive with
  /// an entry already selected (the desktop shell's auto-select) without that
  /// selection dragging the user straight into the editor.
  var _compactShowingEditor = false;
  VoidCallback? _removeBackInterceptor;

  late final Future<void> Function() _lifecycleFlushCallback;

  @override
  void initState() {
    super.initState();
    _invalidateJournalCaches = ref.read(journalEntryCacheInvalidatorProvider);
    _lifecycleFlushCallback = _lifecycleFlush;
    PendingFlushRegistry.instance.register(_lifecycleFlushCallback);
    _removeBackInterceptor = ShellBackInterceptors.instance.register(
      _handleSystemBack,
    );
    _titleFocusNode.addListener(_handleTitleFocusChanged);
    _bodyFocusNode.addListener(_handleBodyFocusChanged);
    _restoreFromSettings(ref.read(settingsProvider).valueOrNull);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _prefetchInitialJournalEntries(),
    );
  }

  Future<void> _lifecycleFlush() async {
    await _flushActiveEntryEdits(refreshList: false);
    await _flushMetadataSave(refreshList: false);
  }

  // Losing focus is a commitment point, so both of these refresh the lists —
  // it costs one reload per focus change rather than one per typing burst,
  // which is what makes it affordable. See [_refreshEntryLists].
  void _handleBodyFocusChanged() {
    if (!_bodyFocusNode.hasFocus) {
      unawaited(_flushActiveEntryEdits(refreshList: true));
    }
  }

  void _handleTitleFocusChanged() {
    if (!_titleFocusNode.hasFocus && _metadataDirty) {
      unawaited(_flushMetadataSave(refreshList: true));
    }
  }

  void _prefetchInitialJournalEntries() {
    if (!mounted) return;
    if (_viewAllJournals) {
      unawaited(
        ref.read(journalListEntriesProvider(allJournalEntriesScope).future),
      );
      return;
    }
    unawaited(ref.read(journalListEntriesProvider(_journalFilter).future));
  }

  Future<void> _selectJournal(String journalId) async {
    _logJournal('SELECT_JOURNAL', details: 'journalId=$journalId');
    final entries = await ref.read(
      journalListEntriesProvider(journalId).future,
    );
    if (!mounted) return;

    // Keep the current selection only if it already belongs to the target
    // journal (e.g. picking the same journal from the dropdown while viewing
    // all journals). Otherwise we swap to the target journal's latest entry.
    final keepCurrent =
        _selectedEntry != null && _selectedEntry!.journalId == journalId;

    // Persist any in-progress edits on the outgoing entry before switching, so
    // nothing is lost — this mirrors what an in-journal entry switch does.
    if (!keepCurrent && _selectedEntryId != null) {
      await _flushActiveEntryEdits(refreshList: true);
      if (!mounted) return;
    }

    // No awaits past this point: compute the target entry and apply the journal
    // filter + selection together in a single setState. Selecting the new
    // journal's latest entry in the same frame (instead of clearing the
    // selection and letting a post-frame callback re-select it) keeps the
    // editor mounted, so it simply swaps its text/colors in place rather than
    // flashing the whole editing screen.
    _optimisticallyHiddenEntryIds.clear();

    JournalEntry? displayTarget;
    if (!keepCurrent) {
      final scoped = _buildDisplayEntries(
        entries,
      ).where((entry) => entry.journalId == journalId).toList();
      if (scoped.isNotEmpty) {
        displayTarget = _prepareSelectedEntry(scoped.first);
      }
    }

    setState(() {
      _journalFilter = journalId;
      _viewAllJournals = false;
      if (!keepCurrent) {
        if (displayTarget != null) {
          _selectEntryFields(displayTarget);
        } else {
          _clearEntryFields();
        }
      }
    });
    unawaited(_persistLastViewedJournal(journalId));
    unawaited(_persistShowAllJournals(false));

    if (!keepCurrent &&
        displayTarget == null &&
        journalId != allJournalEntriesScope) {
      unawaited(_createEntry());
    }
  }

  /// Turns the all-journals view on.
  ///
  /// The reverse trip is a journal row in the same popover, which goes through
  /// [_selectJournal]; there is no toggle to press twice any more.
  ///
  /// Only the view flag is written here: [_journalFilter] deliberately stays on
  /// the journal that was open, and it is what new entries created from this
  /// view are filed under.
  Future<void> _selectAllJournals() async {
    _logJournal('SELECT_ALL_JOURNALS');
    if (_viewAllJournals) return;
    await ref.read(journalListEntriesProvider(allJournalEntriesScope).future);
    if (!mounted) return;
    setState(() {
      _optimisticallyHiddenEntryIds.clear();
      _viewAllJournals = true;
    });
    unawaited(_persistShowAllJournals(true));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _writeEntryListScrollStorage(0);
      _scrollEntryListToTop();
    });
  }

  void _restoreFromSettings(AppSettings? settings) {
    // A default journal replaces the whole "reopen where you left off" restore
    // — both the id and the all-view flag — rather than layering on top of it.
    final defaultId = settings?.defaultJournalId;
    if (defaultId != null) {
      _journalFilter = defaultId;
      _viewAllJournals = false;
      _entryListWidth ??= settings?.journalEntryListWidth;
      return;
    }
    if (settings?.journalShowAllEntries ?? false) {
      _viewAllJournals = true;
    }
    final savedId = settings?.lastViewedJournalId;
    if (savedId != null) {
      _journalFilter = savedId;
    }
    _entryListWidth ??= settings?.journalEntryListWidth;
  }

  void _applySavedPreferencesIfReady(
    AppSettings? settings,
    List<Journal> journals,
  ) {
    if (_appliedSavedPreferences || settings == null) return;
    _appliedSavedPreferences = true;

    // Same precedence as [_restoreFromSettings], re-applied here because that
    // one runs before the journal list has loaded and can't tell whether the
    // id still exists. A default that has since been deleted falls back to the
    // ordinary last-viewed restore.
    final defaultId = settings.defaultJournalId;
    final defaultJournalId =
        defaultId != null && journals.any((journal) => journal.id == defaultId)
        ? defaultId
        : null;
    final savedId = settings.lastViewedJournalId;
    final isAll = defaultJournalId == null && settings.journalShowAllEntries;
    final restoredJournalId =
        defaultJournalId ??
        (savedId != null && journals.any((journal) => journal.id == savedId)
            ? savedId
            : null);

    if (!isAll &&
        restoredJournalId == null &&
        settings.journalEntryListWidth == null) {
      return;
    }

    // Published before the post-frame callback so [_buildJournalContent],
    // which runs later in this same build, tests the restore target rather
    // than the stale filter. Otherwise it decides the stale id names no live
    // journal, queues its own fallback to the first journal in the list, and
    // — being registered second — that fallback lands last and undoes the
    // restore. Only visible when the restored id isn't the first journal,
    // which is exactly the case a default journal creates.
    _pendingRestoreJournalId = restoredJournalId;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _pendingRestoreJournalId = null;
        // Both, not one or the other: reopening into the all-view still needs
        // the concrete journal, since that is where new entries are filed.
        if (isAll) {
          _viewAllJournals = true;
        } else if (defaultJournalId != null) {
          _viewAllJournals = false;
        }
        if (restoredJournalId != null) {
          _journalFilter = restoredJournalId;
        }
        _entryListWidth ??= settings.journalEntryListWidth;
      });
    });
  }

  @override
  void dispose() {
    _metadataSaveTimer?.cancel();
    _bodySaveTimer?.cancel();
    PendingFlushRegistry.instance.unregister(_lifecycleFlushCallback);
    _removeBackInterceptor?.call();
    _pinFlushDependencies();
    _titleFocusNode.removeListener(_handleTitleFocusChanged);
    _bodyFocusNode.removeListener(_handleBodyFocusChanged);
    _listTitlePreview.dispose();
    _listBodyPreview.dispose();
    _logJournal(
      'PAGE_DISPOSE',
      details: 'Flushing active edits before dispose.',
    );
    unawaited(_flushActiveEntryEdits(refreshList: false));
    _titleController.dispose();
    _titleFocusNode.dispose();
    _bodyFocusNode.dispose();
    _entryListScrollController.dispose();
    super.dispose();
  }

  JournalPageDebugSnapshot _debugSnapshot() {
    final entryId = _selectedEntryId;
    return JournalPageDebugSnapshot(
      selectedEntryId: entryId,
      titleText: _titleController.text,
      // Deliberately the raw controller text rather than
      // [_PlainJournalEditorState.bodyTextFor]: this snapshot exists to report
      // what the editor is actually holding, so a buffer belonging to the
      // previous entry must show up here rather than be quietly corrected.
      bodyText:
          _editorKey.currentState?.rawBodyTextForDebug ??
          (entryId == null
              ? ''
              : (_entryBodyDrafts[entryId] ?? _selectedEntry?.body ?? '')),
      metadataDirty: _metadataDirty,
      bodyFocused: _bodyFocusNode.hasFocus,
      titleFocused: _titleFocusNode.hasFocus,
      journalFilter: _journalFilter,
      viewAllJournals: _viewAllJournals,
      bodyDraftEntryIds: _entryBodyDrafts.keys.toList(),
    );
  }

  void _logJournal(String event, {JournalEntry? entry, String? details}) {
    logJournalDebug(
      _journalDebugLogger,
      event,
      page: _debugSnapshot(),
      entry: entry ?? _selectedEntry,
      details: details,
    );
  }

  void _invalidateJournalEntryCaches() {
    _invalidateJournalCaches?.call();
  }

  /// Reloads only the entry lists that can show [journalId]'s rows.
  ///
  /// Called at the page's commitment points — switching entry, switching
  /// journal, leaving the editor — and never from the ~400ms autosave. An
  /// autosave can only change an existing row's title and body, and the row on
  /// screen is already following both live through [_listTitlePreview] and
  /// [_listBodyPreview]; nothing else it touches (the `entryDate` the list
  /// sorts on, the per-journal counts, the id set) moves on an edit.
  ///
  /// Deliberately narrower than [_invalidateJournalEntryCaches], which stays
  /// for the paths that really do restructure the list (create, delete, move
  /// between journals). That sweep invalidates the whole
  /// [journalListEntriesProvider] family plus [journalEntryCountsProvider] and
  /// [journalAllEntryIdsProvider] — and since those are all `keepAlive` and
  /// actively watched, each one immediately re-reads and re-maps every entry
  /// row in the database, deleted ones included. Running that per autosave was
  /// what dropped frames while typing.
  ///
  /// [allJournalEntriesProvider] is included because it feeds `tagPoolProvider`
  /// (the `#tag` completion pool) and the analytics page: a newly typed tag has
  /// to reach both eventually. Once per commitment point is enough — it was
  /// re-ranking every entry's tags on every keystroke burst before.
  void _refreshEntryLists(String journalId) {
    if (!mounted) return;
    ref.invalidate(journalListEntriesProvider(allJournalEntriesScope));
    if (journalId != allJournalEntriesScope) {
      ref.invalidate(journalListEntriesProvider(journalId));
    }
    final filter = _journalFilter;
    if (filter != allJournalEntriesScope && filter != journalId) {
      ref.invalidate(journalListEntriesProvider(filter));
    }
    ref.invalidate(allJournalEntriesProvider);
  }

  RemoteSyncService? _syncServiceOrNull() {
    if (_remoteSync != null) return _remoteSync;
    if (!mounted) return null;
    return ref.read(remoteSyncServiceProvider);
  }

  JournalRepository? _journalRepoOrNull() {
    if (_journalRepository != null) return _journalRepository;
    if (!mounted) return null;
    return ref.read(journalRepositoryProvider);
  }

  JournalWriteCoordinator? _writeCoordinatorOrNull() {
    if (_journalWriteCoordinator != null) return _journalWriteCoordinator;
    if (!mounted) return null;
    return ref.read(journalWriteCoordinatorProvider);
  }

  void _pinFlushDependencies() {
    _remoteSync ??= ref.read(remoteSyncServiceProvider);
    _journalRepository ??= ref.read(journalRepositoryProvider);
    _journalWriteCoordinator ??= ref.read(journalWriteCoordinatorProvider);
    _invalidateJournalCaches ??= ref.read(journalEntryCacheInvalidatorProvider);
  }

  String _entryListScope(List<Journal>? journals) {
    if (_viewAllJournals) return allJournalEntriesScope;
    if (journals != null &&
        !journals.any((journal) => journal.id == _journalFilter)) {
      if (journals.isEmpty) return allJournalEntriesScope;
      return journals.first.id;
    }
    return _journalFilter;
  }

  Future<void> _ensureDefaultJournal() async {
    final repo = ref.read(journalRepositoryProvider);
    final journals = await repo.listJournals();
    if (journals.any((journal) => journal.id == legacyJournalId)) return;

    final now = utcNow();
    final settings = await ref.read(settingsRepositoryProvider).getSettings();
    final defaultJournal = Journal(
      id: legacyJournalId,
      name: 'Journal',
      colorValue: settings.accentColor,
      createdAt: now,
      updatedAt: now,
    );
    await repo.upsertJournal(defaultJournal);
    ref.read(remoteSyncServiceProvider).pushJournal(defaultJournal);
  }

  /// The journal a new entry belongs to. While "All journals" is on this is
  /// the journal last actually opened — see [resolveNewItemTarget], which the
  /// todo page's `_listIdForNewTask` also calls so the two views agree.
  String _journalIdForNewEntry(List<Journal> journals) {
    return resolveNewItemTarget(
          currentId: _journalFilter,
          lastViewedId: ref
              .read(settingsProvider)
              .valueOrNull
              ?.lastViewedJournalId,
          legacyId: legacyJournalId,
          availableIds: [for (final j in journals) j.id],
        ) ??
        legacyJournalId;
  }

  Future<void> _persistLastViewedJournal(String journalId) async {
    final settingsRepo = ref.read(settingsRepositoryProvider);
    final settings = await settingsRepo.getSettings();
    if (settings.lastViewedJournalId == journalId) return;
    await settingsRepo.saveSettings(
      settings.copyWith(lastViewedJournalId: journalId),
    );
  }

  Future<void> _persistShowAllJournals(bool showAll) async {
    final settingsRepo = ref.read(settingsRepositoryProvider);
    final settings = await settingsRepo.getSettings();
    if (settings.journalShowAllEntries == showAll) return;
    await settingsRepo.saveSettings(
      settings.copyWith(journalShowAllEntries: showAll),
    );
  }

  Future<void> _persistEntryListWidth(double? width) async {
    final settingsRepo = ref.read(settingsRepositoryProvider);
    final settings = await settingsRepo.getSettings();
    if (settings.journalEntryListWidth == width) return;
    await settingsRepo.saveSettings(
      width == null
          ? settings.copyWith(clearJournalEntryListWidth: true)
          : settings.copyWith(journalEntryListWidth: width),
    );
  }

  void _resetEntryListWidth() {
    setState(() => _entryListWidth = null);
    unawaited(_persistEntryListWidth(null));
  }

  void _onEntryListDragStart(double totalWidth) {
    _entryListDragStartWidth =
        _entryListWidth ?? JournalEntryListLayout.defaultListWidth(totalWidth);
    setState(() => _entryListDragging = true);
  }

  void _onEntryListDragUpdate(double totalDelta, double totalWidth) {
    final startWidth = _entryListDragStartWidth;
    if (startWidth == null) return;
    // Tracks the pointer 1:1 and stops dead at the bounds, so neither pane is
    // ever dragged past the width it stays readable at.
    setState(
      () => _entryListWidth = JournalEntryListLayout.clampListWidth(
        startWidth + totalDelta,
        totalWidth,
      ),
    );
  }

  void _onEntryListDragEnd(double totalWidth) {
    final width = _entryListWidth;
    _entryListDragStartWidth = null;
    // Hard-clamp back to the real bound now that the drag has ended; the
    // spring-curved AnimatedContainer around the pane carries the visual
    // snap-back from wherever the rubber-band left it.
    final settled = width == null
        ? null
        : JournalEntryListLayout.clampListWidth(width, totalWidth);
    setState(() {
      _entryListWidth = settled;
      _entryListDragging = false;
    });
    unawaited(_persistEntryListWidth(settled));
  }

  /// The gear beside the switcher: create, rename, recolour, configure and
  /// delete journals, all in one dialog rather than a menu nested in the
  /// picker.
  Future<void> _openJournalManageSheet() async {
    final createdId = await showJournalManageSheet(context, ref);
    if (!mounted) return;
    final journals = await ref.read(journalsProvider.future);
    if (!mounted) return;
    if (createdId != null) {
      // Routed through [_selectJournal] rather than setting the filter here:
      // a brand-new journal is empty, and only that path flushes the outgoing
      // entry, clears the editor and opens a fresh entry in the journal now on
      // screen. Setting the filter alone left the previous journal's entry
      // sitting in the editor under the new journal's name.
      await _selectJournal(createdId);
      return;
    }
    // A journal may have been deleted out from under the page. Fall back to a
    // concrete journal and leave the all-view alone, matching the todo page's
    // list deletion — switching the view mode out from under a delete is a
    // second, unasked-for change of context.
    final live = journals.where((j) => j.deletedAt == null).toList();
    if (live.any((j) => j.id == _journalFilter)) return;
    final fallback =
        live
            .cast<Journal?>()
            .firstWhere(
              (j) => j!.id == legacyJournalId,
              orElse: () => live.isNotEmpty ? live.first : null,
            )
            ?.id ??
        legacyJournalId;
    final liveIds = {for (final journal in live) journal.id};
    setState(() {
      _pendingEntries.removeWhere(
        (_, entry) => !liveIds.contains(entry.journalId),
      );
      _pendingEntryIds.removeWhere((id) => !_pendingEntries.containsKey(id));
    });
    await _selectJournal(fallback);
  }

  List<Journal> _displayJournals(List<Journal> journals) {
    return journals.where((journal) => journal.deletedAt == null).toList();
  }

  /// Evicts entries from [_pendingEntries] that have been confirmed saved to the
  /// database — including entries that were soft-deleted (e.g. by an import).
  /// [allDbIds] must include deleted entry IDs so that stale pending entries
  /// whose rows were imported with [deletedAt] set are also evicted, preventing
  /// them from inflating the journal badge count.
  void _reconcilePendingEntries(Set<String> allDbIds) {
    if (_pendingEntries.isEmpty) return;
    final toEvict = _pendingEntryIds
        .where((id) => allDbIds.contains(id))
        .toList();
    if (toEvict.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        for (final id in toEvict) {
          _pendingEntries.remove(id);
          _pendingEntryIds.remove(id);
        }
      });
    });
  }

  DateTime _nextEntryTimestamp() {
    final now = utcNow();
    final last = _lastEntryCreatedAt;
    final next = last != null && !now.isAfter(last)
        ? last.add(const Duration(milliseconds: 1))
        : now;
    _lastEntryCreatedAt = next;
    return next;
  }

  void _registerPendingEntry(JournalEntry entry) {
    _pendingEntries[entry.id] = entry;
    _pendingEntryIds.remove(entry.id);
    _pendingEntryIds.insert(0, entry.id);
  }

  void _removePendingEntry(String id) {
    _pendingEntries.remove(id);
    _pendingEntryIds.remove(id);
  }

  PageStorageKey<String> _entryListStorageKey() {
    return _viewAllJournals
        ? ShellPageStorageKeys.journalEntryListAll
        : ShellPageStorageKeys.journalEntryList;
  }

  void _writeEntryListScrollStorage(double offset) {
    if (!mounted) return;
    PageStorage.of(
      context,
    ).writeState(context, offset, identifier: _entryListStorageKey());
  }

  List<JournalEntry> _buildDisplayEntries(List<JournalEntry> entries) {
    final persisted = entries.where(
      (entry) =>
          !_pendingEntries.containsKey(entry.id) &&
          !_optimisticallyHiddenEntryIds.contains(entry.id),
    );
    final pending = [
      for (final id in _pendingEntryIds)
        if (_pendingEntries.containsKey(id)) _pendingEntries[id]!,
    ];
    return sortJournalEntriesNewestFirst([...pending, ...persisted]);
  }

  bool _entriesMatchScope(List<JournalEntry> entries, String entryListScope) {
    if (entryListScope == allJournalEntriesScope) return true;
    if (entries.isEmpty) return true;
    return entries.every((entry) => entry.journalId == entryListScope);
  }

  List<JournalEntry> _resolveScopedEntries(
    AsyncValue<List<JournalEntry>> entriesAsync,
    String entryListScope,
  ) {
    final raw = entriesAsync.valueOrNull ?? const <JournalEntry>[];
    if (!_entriesMatchScope(raw, entryListScope)) {
      return const [];
    }
    return raw;
  }

  bool _resolveEntriesLoading(
    AsyncValue<List<JournalEntry>> entriesAsync,
    String entryListScope,
  ) {
    final raw = entriesAsync.valueOrNull;
    if (raw != null && !_entriesMatchScope(raw, entryListScope)) {
      return true;
    }
    return entriesAsync.isLoading && raw == null;
  }

  int _scopedEntryCount(List<JournalEntry> displayEntries, String journalId) {
    return displayEntries.where((entry) => entry.journalId == journalId).length;
  }

  int _entryCountForJournal(
    String journalId, {
    required Map<String, int>? persistedCounts,
    required String entryListScope,
    required List<JournalEntry> displayEntries,
    required Set<String> dbEntryIds,
  }) {
    // If database counts are loaded, they are our source of truth
    if (persistedCounts != null) {
      final dbCount = persistedCounts[journalId] ?? 0;
      // Only count pending entries that are genuinely not yet in the DB.
      // Stale entries that were already persisted (but not yet evicted by
      // _reconcilePendingEntries) are excluded here so counts are accurate
      // immediately after deletion, without waiting for the next frame.
      final pendingCount = _pendingEntryIds
          .where(
            (id) =>
                _pendingEntries[id]?.journalId == journalId &&
                !dbEntryIds.contains(id),
          )
          .length;
      return dbCount + pendingCount;
    }

    // Fallback if database counts are still loading:
    if (entryListScope == journalId) {
      return _scopedEntryCount(displayEntries, journalId);
    }
    if (entryListScope == allJournalEntriesScope) {
      return displayEntries
          .where((entry) => entry.journalId == journalId)
          .length;
    }
    return 0;
  }

  void _scrollEntryListToTop() {
    if (!_entryListScrollController.hasClients) return;
    _entryListScrollController.jumpTo(0);
  }

  Future<void> _createEntry() async {
    if (!mounted) return;

    final journals = ref.read(journalsProvider).value;
    if (journals == null) {
      await _createEntryWhenReady();
      return;
    }
    _createEntryOptimistic(journals);
  }

  Future<void> _createEntryWhenReady() async {
    await _ensureDefaultJournal();
    if (!mounted) return;
    final journals = await ref.read(journalRepositoryProvider).listJournals();
    if (!mounted || journals.isEmpty) return;
    _createEntryOptimistic(journals);
  }

  void _createEntryOptimistic(List<Journal> journals) {
    if (!mounted) return;

    final settings = ref.read(settingsProvider).value ?? const AppSettings();
    final weatherService = ref.read(weatherServiceProvider);
    final weather = weatherService.readCachedSnapshot(settings);
    final journalId = journals.isEmpty
        ? legacyJournalId
        : _journalIdForNewEntry(journals);
    if (journals.isEmpty) {
      unawaited(_ensureDefaultJournal());
    }
    final now = _nextEntryTimestamp();

    // Drawn here, synchronously, whenever the bank is already loaded — which
    // it is from the startup warm-up onwards. Leaving it to
    // [_finalizeNewEntry] meant the entry painted one frame with no quote,
    // the editor stretched over the space it would take, and then jumped as
    // the quote landed. The async pass below still covers the cold case.
    final quote = ref.read(quotesLoadedProvider).hasValue
        ? ref.read(quoteBankProvider).nextQuote()
        : null;

    final entry = JournalEntry(
      id: newId(),
      journalId: journalId,
      title: '',
      body: '',
      entryDate: now,
      // The default is stamped here, once, where choosing it is the deliberate
      // act of creating an entry — not on every selection, which used to write
      // 'sunny' onto any legacy or imported row merely because the user opened
      // it and typed a character.
      weatherIcon: weather?.icon ?? 'sunny',
      // Same reasoning as the weather default above: stamped once at creation,
      // so an entry opens at the neutral midpoint instead of unrecorded.
      mood: kDefaultMood,
      quoteId: quote?.id,
      customQuote: quote?.text,
      timestamp: now,
      createdAt: now,
      updatedAt: now,
    );

    _registerPendingEntry(entry);
    _suppressAutoSelect = true;
    // Write-through before anything async. [_finalizeNewEntry] has to wait on
    // the quote bank and on a weather refresh that can reach Firestore and the
    // weather API, which on a cold start or a bad network is seconds to tens of
    // seconds — and until this row exists, the entry lives only in
    // [_pendingEntries] and [_entryBodyDrafts]. Killing the app inside that
    // window lost everything typed, and every autosave in it threw out of
    // [JournalWriteCoordinator.saveEntry] with no baseline row to read.
    final seeded = ref.read(journalRepositoryProvider).upsertEntry(entry);
    _logJournal('CREATE_ENTRY', entry: entry);
    _writeEntryListScrollStorage(0);
    unawaited(_loadEntry(entry));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _writeEntryListScrollStorage(0);
      _scrollEntryListToTop();
      _titleFocusNode.requestFocus();
    });

    unawaited(seeded.then((_) => _finalizeNewEntry(entry, settings)));
  }

  /// Fills in the fields a new entry can only learn asynchronously.
  ///
  /// Applied as a delta against whatever is on disk by the time the awaits
  /// finish, and deliberately without a `mounted` guard around the write:
  /// the row already exists (see [_createEntryOptimistic]), the user may well
  /// have typed into it during the wait, and the previous full-row
  /// `upsertEntry` of the pristine snapshot would have reverted that text —
  /// or, if the page had been disposed, skipped the write altogether.
  Future<void> _finalizeNewEntry(
    JournalEntry entry,
    AppSettings settings,
  ) async {
    // Two passes, not one. The quote only waits on the bundled asset load,
    // while the weather refresh below reaches Firestore and the weather API —
    // seconds to tens of seconds on a cold start or a bad network. Writing
    // both together left the new entry blank at the bottom for that whole
    // window, so the quote only turned up once the entry had been reopened.

    // Assigned even when quotes are hidden — globally or for this journal —
    // so turning them back on shows a quote on entries written while they were
    // off, rather than a run of blanks. Only when [_createEntryOptimistic]
    // could not draw one itself: with the bank already loaded it stamps the
    // quote at creation, so the entry never paints without it.
    Quote? assignedQuote;
    if (entry.customQuote == null) {
      await ref.read(quotesLoadedProvider.future);
      assignedQuote = ref.read(quoteBankProvider).nextQuote();
    }
    // Runs even with nothing to change. The seeding write in
    // [_createEntryOptimistic] goes straight at the repository, which neither
    // schedules the entry's Firestore upload nor refreshes the entry caches —
    // both of which this pass used to carry as a side effect of writing the
    // quote. Without it a new entry that is never typed into stays on this
    // device, and its id never reaches [journalAllEntryIdsProvider], so
    // [_reconcilePendingEntries] never evicts it from [_pendingEntries] and
    // [_suppressAutoSelect] stays on for good.
    await _saveNewEntryDelta(entry.id, (base) {
      final quote = assignedQuote;
      if (quote == null) return base;
      return base.copyWith(
        quoteId: quote.id,
        customQuote: quote.text,
        bumpVersion: false,
      );
    });

    final weatherService = ref.read(weatherServiceProvider);
    final weather =
        await weatherService.refreshIfNeeded() ??
        weatherService.readCachedSnapshot(settings);
    // [_createEntryOptimistic] already stamped the cached icon, so there is
    // nothing left to write when the refresh comes back empty.
    if (weather == null) return;
    await _saveNewEntryDelta(
      entry.id,
      (base) => base.copyWith(weatherIcon: weather.icon, bumpVersion: false),
    );
  }

  /// One [_finalizeNewEntry] pass: a field delta against the row on disk, with
  /// the pending snapshot and the selection brought along with it.
  Future<void> _saveNewEntryDelta(
    String entryId,
    JournalEntry Function(JournalEntry base) applyDelta,
  ) async {
    final coordinator = _writeCoordinatorOrNull();
    if (coordinator == null) return;
    await coordinator.saveEntry(
      entryId: entryId,
      applyDelta: applyDelta,
      onSuccess: (finalized) {
        if (_pendingEntries.containsKey(finalized.id)) {
          _pendingEntries[finalized.id] = finalized;
        }
        if (_selectedEntryId == finalized.id && mounted) {
          setState(() => _selectedEntry = finalized);
        }
      },
    );
  }

  void _reconcileSelectedEntryFromProvider(List<JournalEntry> entries) {
    final id = _selectedEntryId;
    if (id == null || _pendingEntries.containsKey(id)) return;
    if (_editorKey.currentState?.hasFocus ?? false) return;

    final fresh = entries.cast<JournalEntry?>().firstWhere(
      (entry) => entry!.id == id,
      orElse: () => null,
    );
    if (fresh == null) return;

    final current = _selectedEntry;
    if (current != null && fresh.version < current.version) {
      return;
    }
    if (current != null &&
        fresh.version == current.version &&
        fresh.updatedAt.isBefore(current.updatedAt)) {
      return;
    }

    final hasBodyDraft = _entryBodyDrafts.containsKey(id);
    if (hasBodyDraft) {
      // Accept metadata updates while preserving the in-memory body draft.
      if (current == null ||
          (current.title == fresh.title &&
              current.journalId == fresh.journalId &&
              current.mood == fresh.mood &&
              current.customQuote == fresh.customQuote &&
              current.weatherIcon == fresh.weatherIcon &&
              current.entryDate == fresh.entryDate)) {
        return;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _selectedEntryId != id) return;
        setState(() {
          _selectedEntry = current.copyWith(
            title: fresh.title,
            journalId: fresh.journalId,
            mood: fresh.mood,
            customQuote: fresh.customQuote,
            weatherIcon: fresh.weatherIcon,
            entryDate: fresh.entryDate,
            version: fresh.version,
            bumpVersion: false,
          );
          _titleController.text = fresh.title;
          _mood = fresh.mood;
          _weatherIcon = fresh.weatherIcon;
        });
        _listTitlePreview.value = fresh.title;
      });
      return;
    }

    if (_metadataDirty) return;

    if (current == null ||
        (current.title == fresh.title &&
            current.body == fresh.body &&
            current.journalId == fresh.journalId &&
            current.mood == fresh.mood &&
            current.customQuote == fresh.customQuote &&
            current.weatherIcon == fresh.weatherIcon &&
            current.entryDate == fresh.entryDate)) {
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _selectedEntryId != id) return;
      _logJournal(
        'RECONCILE_LOAD_ENTRY',
        entry: fresh,
        details: 'Provider entry differs from in-memory selection.',
      );
      unawaited(_loadEntry(fresh));
    });
  }

  /// Runs a flush, queueing behind one already in flight rather than being
  /// answered with it.
  ///
  /// [_flushActiveEntryEditsImpl] snapshots the title, mood, weather and body
  /// at its start and then awaits a pending-merge apply, a local save and a
  /// Firestore write — so anything typed during those awaits is invisible to
  /// it. Returning the in-flight future told the second caller its work was
  /// already done, which lost every keystroke made in that window whenever the
  /// second caller was a teardown (back button, entry switch, dispose). The
  /// extra pass is cheap: [_persistEntryEdits] short-circuits when the text
  /// already matches disk.
  Future<void> _flushActiveEntryEdits({required bool refreshList}) async {
    final inFlight = _flushInProgress;
    if (inFlight != null) {
      await inFlight.catchError((Object _) {});
    }

    final flush = _flushActiveEntryEditsImpl(refreshList: refreshList);
    _flushInProgress = flush;
    try {
      await flush;
    } finally {
      if (identical(_flushInProgress, flush)) {
        _flushInProgress = null;
      }
    }
  }

  Future<void> _flushActiveEntryEditsImpl({required bool refreshList}) async {
    _logJournal('FLUSH_ACTIVE_EDITS', details: 'refreshList=$refreshList');
    final entryId = _selectedEntryId;
    final entry = _selectedEntry;
    if (entryId == null || entry == null) return;

    _metadataSaveTimer?.cancel();
    // The body autosave's debounce is owned by the page, not the editor. It
    // used to survive the flush, so a queued [_saveBodyDraft] could fire after
    // the flush finished and the selection had already moved on, writing
    // against whatever entry was selected by then.
    _bodySaveTimer?.cancel();

    final title = _titleController.text;
    final mood = _mood;
    final weatherIcon = _weatherIcon;

    // Asked for [entryId]'s text specifically. The editor reseeds its
    // controller in [_PlainJournalEditorState._switchEntryWidget], which awaits
    // *this* flush first — so during a switch the page already names the
    // incoming entry while the controller still holds the outgoing one. Reading
    // the controller unconditionally wrote the outgoing body, under the
    // incoming id and title, with the version bumped: title and image intact,
    // body gone, no tombstone for undo to work from. The drafts and the row are
    // both entry-keyed, so falling through to them is always safe.
    var body =
        _editorKey.currentState?.bodyTextFor(entryId) ??
        _entryBodyDrafts[entryId] ??
        entry.body;

    final remoteSync = _syncServiceOrNull();
    if (remoteSync == null) return;

    final pendingApplied = await remoteSync.applyPendingJournalEntryTextMerge(
      entryId: entryId,
      currentLocalText: body,
    );
    if (pendingApplied != null) {
      body = pendingApplied.body;
      _updateBodyDraft(entryId, body);
      _logJournal(
        'PENDING_TEXT_MERGE_APPLIED',
        entry: pendingApplied,
        details: 'Merged buffered remote body before flush.',
      );
      if (_editorKey.currentState != null && mounted) {
        _editorKey.currentState!.setBodyText(body);
      }
    }

    await _persistEntryEdits(
      entry: entry,
      title: title,
      body: body,
      mood: mood,
      weatherIcon: weatherIcon,
      bumpVersion: true,
    );

    // Local only, deliberately: the entry's Firestore upload is started here
    // but never waited on. Every entry switch runs this flush and queues behind
    // [_flushInProgress], and a brand-new entry always has an upload pending
    // (see [_finalizeNewEntry]) — so any wait on that round-trip is a wait the
    // user spends unable to switch entries. With offline persistence it is
    // unbounded, which made the list permanently unclickable; bounding it only
    // shortened the freeze to the deadline. The local write above is the part
    // that makes switching safe, and app teardown pushes anything still unsent
    // through `flushAllPending` (see `VoyagerApp._flushAllPendingEdits`).
    await remoteSync.flushDocumentLocal(
      FirestoreCollections.journalEntries,
      entryId,
    );

    // Unconditional, not hung off the write above: the autosave has usually
    // already persisted this exact text, so there is nothing left to save but
    // the lists still have to catch up. See [_refreshEntryLists].
    if (refreshList) _refreshEntryLists(entry.journalId);
  }

  void _scheduleBodySave() {
    _bodySaveTimer?.cancel();
    _bodySaveTimer = Timer(_localSaveDebounce, () {
      unawaited(_saveBodyDraft(bumpVersion: false));
    });
  }

  Future<void> _saveBodyDraft({required bool bumpVersion}) async {
    final entryId = _selectedEntryId;
    final entry = _selectedEntry;
    if (entryId == null || entry == null) return;

    final body =
        _editorKey.currentState?.bodyTextFor(entryId) ??
        _entryBodyDrafts[entryId] ??
        entry.body;

    await _persistEntryEdits(
      entry: entry,
      title: _titleController.text,
      body: body,
      mood: _mood,
      weatherIcon: _weatherIcon,
      bumpVersion: bumpVersion,
    );
  }

  /// Loads the entry with [id] fresh from disk before selecting it, rather
  /// than trusting a caller's possibly-stale snapshot. A cached list row
  /// (see `_rowFor`) can outlive the entry data it was built from — if a
  /// field the row's own signature doesn't render (mood, weatherIcon, tags)
  /// changed remotely in the meantime, tapping through the cached row's
  /// `entry` object would load stale metadata into the editor, and a later
  /// autosave could silently revert that field.
  Future<void> _loadEntryById(String id) async {
    final repo = ref.read(journalRepositoryProvider);
    final current = await repo.getEntry(id);
    if (current == null || !mounted) return;
    await _loadEntry(current);
  }

  /// Opens an entry from the list. On the desktop shell this is exactly the
  /// old behaviour — the editor is already on screen beside the list — and on
  /// a phone it also brings the editor forward over it.
  Future<void> _openEntry(String id) async {
    _revealCompactEditor();
    await _loadEntryById(id);
  }

  void _revealCompactEditor() {
    if (!mounted || !context.isCompactWidth || _compactShowingEditor) return;
    setState(() => _compactShowingEditor = true);
  }

  /// Returns to the entry list on the phone shell, persisting whatever was
  /// typed on the way out — leaving the editor is the same commitment point
  /// as switching entries, and is handled the same way.
  Future<void> _closeCompactEditor() async {
    await _flushActiveEntryEdits(refreshList: true);
    if (!mounted) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _compactShowingEditor = false);
  }

  /// Android Back, offered to this page before the shell acts on it.
  ///
  /// Only claims the gesture when the journal is both the section on screen
  /// and actually covering its list with the editor; the page stays mounted
  /// while other sections are showing, so it must not answer for them.
  bool _handleSystemBack() {
    if (!mounted || !_compactShowingEditor) return false;
    // The flag survives a resize past the breakpoint, where both panes are
    // visible again and there is nothing to go back from.
    if (!context.isCompactWidth) return false;
    if (!TickerMode.getValuesNotifier(context).value.enabled) return false;
    unawaited(_closeCompactEditor());
    return true;
  }

  /// Returns a `_JournalEntryListTile` for [entry], reusing the previous
  /// frame's widget instance when nothing that affects its rendering has
  /// changed. See `_rowWidgetCache` for why that matters.
  _JournalEntryListTile _rowFor(
    JournalEntry entry, {
    required bool isSelected,
  }) {
    final signature = (
      title: entry.title,
      body: entry.body,
      entryDate: entry.entryDate,
      isSelected: isSelected,
    );
    final cached = _rowWidgetCache[entry.id];
    if (cached != null && _rowSignatureCache[entry.id] == signature) {
      return cached;
    }
    final tile = _JournalEntryListTile(
      key: ValueKey(entry.id),
      entry: entry,
      isSelected: isSelected,
      titlePreview: _listTitlePreview,
      bodyPreview: _listBodyPreview,
      onTap: () => unawaited(_openEntry(entry.id)),
    );
    _rowWidgetCache[entry.id] = tile;
    _rowSignatureCache[entry.id] = signature;
    return tile;
  }

  Future<void> _loadEntry(JournalEntry entry) async {
    if (_selectedEntryId != null && _selectedEntryId != entry.id) {
      _logJournal(
        'SWITCH_ENTRY',
        entry: entry,
        details: 'from=${_selectedEntryId} to=${entry.id}',
      );
      await _flushActiveEntryEdits(refreshList: true);
      if (!mounted) return;
    }

    final displayEntry = _prepareSelectedEntry(entry);
    setState(() {
      _selectEntryFields(displayEntry);
    });

    unawaited(_persistLastViewedJournal(displayEntry.journalId));
  }

  /// Resolves [entry] to the version that should be shown (applying any local
  /// draft body) and updates the list preview notifiers. Returns the resolved
  /// entry; call [_selectEntryFields] inside a setState to actually select it.
  JournalEntry _prepareSelectedEntry(JournalEntry entry) {
    final displayEntry = _entryWithDraftBody(entry);
    final draftBody = _entryBodyDrafts[displayEntry.id] ?? displayEntry.body;
    _listTitlePreview.value = displayEntry.title;
    _listBodyPreview.value = draftBody;
    return displayEntry;
  }

  /// Applies the selection state for [displayEntry]. Must be called inside a
  /// setState so the change is painted in a single frame.
  void _selectEntryFields(JournalEntry displayEntry) {
    _selectedEntryId = displayEntry.id;
    _selectedEntry = displayEntry;
    _titleController.text = displayEntry.title;
    _mood = displayEntry.mood;
    // Not defaulted to 'sunny' here. Both save paths write `_weatherIcon`
    // back, so normalizing on selection stamped the default onto every entry
    // with no icon of its own — anything written before the weather feature,
    // imported, or created while the cache was cold — as a side effect of
    // opening it and typing one character, bumping the version and pushing the
    // row. The default belongs at creation, where choosing it is deliberate
    // (see [_createEntryOptimistic]); the icon button renders a fallback glyph
    // through `weatherIconData(null)` either way, so the placeholder is still
    // visible without being persisted.
    _weatherIcon = displayEntry.weatherIcon;
    _metadataDirty = false;
  }

  /// The inverse of [_selectEntryFields]: nothing is selected, and every field
  /// the metadata row shows goes back to what a brand-new entry would carry.
  ///
  /// The row itself stays on screen when the journal empties out (see the
  /// editor column in [build]) — so leaving the just-deleted entry's mood and
  /// weather sitting in it would read as if that entry were still open. Must
  /// be called inside a setState, for the same reason [_selectEntryFields] is.
  void _clearEntryFields() {
    _selectedEntryId = null;
    _selectedEntry = null;
    _titleController.clear();
    _mood = null;
    _weatherIcon = null;
    _metadataDirty = false;
  }

  void _updateBodyDraft(String entryId, String body) {
    _entryBodyDrafts[entryId] = body;
    if (entryId == _selectedEntryId) {
      _listBodyPreview.value = body;
    }
  }

  JournalEntry _entryWithDraftBody(JournalEntry entry) {
    final draftBody = _entryBodyDrafts[entry.id];
    if (draftBody == null) return entry;
    return JournalEntry(
      id: entry.id,
      journalId: entry.journalId,
      title: entry.title,
      body: draftBody,
      entryDate: entry.entryDate,
      richBodyJson: entry.richBodyJson,
      timestamp: entry.timestamp,
      tags: entry.tags,
      mood: entry.mood,
      quoteId: entry.quoteId,
      customQuote: entry.customQuote,
      weatherIcon: entry.weatherIcon,
      guidedPrompt: entry.guidedPrompt,
      createdAt: entry.createdAt,
      updatedAt: entry.updatedAt,
      version: entry.version,
      deletedAt: entry.deletedAt,
    );
  }

  bool _sameTags(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Writes the editor's current text, or does nothing if it already matches
  /// disk.
  ///
  /// Deliberately has no say in refreshing the entry lists. It is reached both
  /// from the autosave, which must not refresh at all, and from
  /// [_flushActiveEntryEditsImpl], which must refresh whether or not this found
  /// anything to write — by the time a flush runs, the autosave has usually
  /// already persisted the same text, so hanging the refresh off a successful
  /// write here would silently skip it and leave the lists stale for good.
  Future<void> _persistEntryEdits({
    required JournalEntry entry,
    required String title,
    required String body,
    required int? mood,
    required String? weatherIcon,
    bool bumpVersion = false,
  }) async {
    final tags = extractTags(body);
    final coordinator = _writeCoordinatorOrNull();
    final repo = _journalRepoOrNull();
    if (coordinator == null || repo == null) return;

    final stored = await repo.getEntry(entry.id);
    final baseline = stored ?? entry;

    if (baseline.title == title &&
        baseline.body == body &&
        baseline.mood == mood &&
        baseline.weatherIcon == weatherIcon &&
        _sameTags(baseline.tags, tags)) {
      // Dropped here as well as on a successful save — the whole point of this
      // branch is that the draft and disk now agree, and a draft left behind
      // stops agreeing the moment a *remote* edit changes the row.
      // [_entryWithDraftBody] prefers the draft unconditionally, so the stale
      // copy would be laid back over the pulled body the next time the entry
      // was reselected, and then persisted and pushed as the local truth.
      _entryBodyDrafts.remove(entry.id);
      _logJournal(
        'PERSIST_ENTRY_SKIPPED',
        entry: baseline,
        details: 'No changes detected against DB baseline.',
      );
      return;
    }

    try {
      await coordinator.saveEntry(
        entryId: entry.id,
        bumpVersion: bumpVersion,
        // This page refreshes its own lists through [_refreshEntryLists], which
        // is narrower than the coordinator's app-wide sweep and correct for an
        // edit: nothing but the row's own text can change here.
        refreshCaches: false,
        applyDelta: (base) => base.copyWith(
          title: title,
          body: body,
          tags: tags,
          mood: mood,
          weatherIcon: weatherIcon,
          bumpVersion: false,
        ),
        onSuccess: (updated) {
          _entryBodyDrafts.remove(entry.id);
          _logJournal(
            'PERSIST_ENTRY_SAVED',
            entry: updated,
            details: 'v=${updated.version} bodyLen=${updated.body.length}',
          );
          // `mounted` gates the notifier writes too, not just the setState:
          // [dispose] disposes both notifiers and only then starts its final
          // flush, and `_selectedEntryId` is still set when this callback runs,
          // so assigning to them asserted `used after being disposed` on every
          // teardown with pending edits — inside an unawaited future, where it
          // surfaced as an unhandled async error rather than at the call site.
          if (_selectedEntryId == entry.id && mounted) {
            _listTitlePreview.value = updated.title;
            _listBodyPreview.value = updated.body;
            setState(() {
              _selectedEntry = updated;
              _metadataDirty = false;
            });
          }
        },
      );
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'JournalPage',
          context: ErrorDescription('while persisting journal entry edits'),
        ),
      );
    }
  }

  /// Writes the metadata row's fields as a delta, through the same coordinator
  /// [_persistEntryEdits] uses.
  ///
  /// It used to build a finished `baseline.copyWith(...)` from a snapshot read
  /// *before* `saveJournalEntryThenScheduleUpload` was called — outside the
  /// per-document queue — and hand that whole row to the save. Two things fell
  /// out of that, both of which the delta form fixes:
  ///
  /// The queue drops a save whose generation has been superseded, which is only
  /// safe when every writer on the key persists the same snapshot. This one and
  /// the body autosave persist *disjoint* field sets, so a body save followed
  /// inside the same debounce window by a title edit had its turn skipped and
  /// was then overwritten by this function's pre-edit `baseline.body` — losing
  /// whatever had just been typed.
  ///
  /// And reading the baseline outside the critical section meant anything that
  /// landed between the read and the queued write — an autosave, an inbound
  /// pull, a pending-text merge, an outbox replay — was reverted by the stale
  /// snapshot and re-uploaded as the local truth.
  ///
  /// The read below survives only as a skip test: deciding not to queue a
  /// no-op can't overwrite anything.
  Future<void> _saveMetadataForEntry({
    required String entryId,
    required JournalEntry entry,
    required String title,
    required int? mood,
    required String? weatherIcon,
    bool refreshList = false,
  }) async {
    final coordinator = _writeCoordinatorOrNull();
    final repo = _journalRepoOrNull();
    if (coordinator == null || repo == null) return;

    final stored = await repo.getEntry(entryId);
    final baseline = stored ?? entry;

    if (baseline.title == title &&
        baseline.mood == mood &&
        baseline.weatherIcon == weatherIcon) {
      _logJournal(
        'METADATA_PERSIST_SKIPPED',
        entry: baseline,
        details: 'No metadata changes detected.',
      );
      // Still refresh: a debounced save may already have written this exact
      // metadata, and the commitment point that asked for a refresh needs one
      // either way.
      if (refreshList) _refreshEntryLists(baseline.journalId);
      return;
    }

    try {
      await coordinator.saveEntry(
        entryId: entryId,
        bumpVersion: true,
        // This page refreshes its own lists through [_refreshEntryLists],
        // narrower than the coordinator's app-wide sweep. Same call as
        // [_persistEntryEdits] makes, for the same reason.
        refreshCaches: false,
        // `base.body` is carried through untouched, which is what makes this
        // writer commutative with the body autosave.
        applyDelta: (base) => base.copyWith(
          title: title,
          mood: mood,
          weatherIcon: weatherIcon,
          bumpVersion: false,
        ),
        onSuccess: (updated) {
          _logJournal(
            'METADATA_PERSIST_SAVED',
            entry: updated,
            details: 'v=${updated.version}',
          );
          // Guarded for the same reason as [_persistEntryEdits]' callback:
          // the notifiers are disposed before the teardown flush runs.
          if (_selectedEntryId == entryId && mounted) {
            _listTitlePreview.value = updated.title;
            setState(() {
              _selectedEntry = updated;
              _metadataDirty = false;
            });
          }
        },
      );
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'JournalPage',
          context: ErrorDescription('while persisting journal entry metadata'),
        ),
      );
    }
    // Same reasoning as [_persistEntryEdits]: the only metadata the list shows
    // is the title, and the row on screen already followed it through
    // [_listTitlePreview] inside the save above. See [_refreshEntryLists].
    if (refreshList) _refreshEntryLists(baseline.journalId);
  }

  Future<void> _saveMetadata({bool refreshList = false}) async {
    final entryId = _selectedEntryId;
    final entry = _selectedEntry;
    if (entryId == null || entry == null || entry.id != entryId) return;

    await _saveMetadataForEntry(
      entryId: entryId,
      entry: entry,
      title: _titleController.text,
      mood: _mood,
      weatherIcon: _weatherIcon,
      refreshList: refreshList,
    );
  }

  bool _isDatePickerOpen = false;

  void _scheduleMetadataSave() {
    _metadataSaveTimer?.cancel();
    _metadataSaveTimer = Timer(_localSaveDebounce, () {
      unawaited(_saveMetadata());
    });
  }

  Future<void> _flushMetadataSave({bool refreshList = false}) {
    _metadataSaveTimer?.cancel();
    return _saveMetadata(refreshList: refreshList);
  }

  /// Enter/Tab out of the title: save it once, then move on to the body.
  ///
  /// Focus staying inside the same entry is deliberately *not* a commitment
  /// point. Marking the metadata dirty here used to make the blur that follows
  /// [FocusNode.requestFocus] fire [_handleTitleFocusChanged], so a single
  /// keystroke started a second, concurrent flush of the same title *and* swept
  /// every entry list with it — four keepAlive providers re-reading and
  /// re-mapping the whole entry table, plus the tag pool refolding over it,
  /// on the frame the key went down. That is the stutter Enter used to cause.
  ///
  /// Nothing that sweep reloads can have moved: a title-only save leaves the
  /// list's sort (`entryDate`), the per-journal counts and the id set alone,
  /// and tags come from the body, not the title. The row on screen is already
  /// following the new title live through [_listTitlePreview], and the body's
  /// own blur is the commitment point that refreshes the lists — it re-persists
  /// the title on the way past. See [_refreshEntryLists].
  void _submitTitleAndFocusBody() {
    _metadataDirty = false;
    unawaited(_flushMetadataSave());
    _bodyFocusNode.requestFocus();
  }

  Future<void> _changeEntryDateAndTime(BuildContext buttonContext) async {
    final entry = _selectedEntry;
    if (entry == null) return;
    // Raised here rather than just before the popover: the flush and the
    // journal read below run with nothing on screen, and a second press
    // landing in that gap would stack a second picker on the first.
    if (_isDatePickerOpen) return;
    setState(() => _isDatePickerOpen = true);

    final repo = ref.read(journalRepositoryProvider);
    DateTime? pickedDt;
    try {
      _metadataSaveTimer?.cancel();
      await _flushMetadataSave();
      if (!mounted) return;

      final journal = await repo.getJournal(entry.journalId);
      final accentColor = Color(
        journal != null
            ? _journalFlagColor(journal)
            : Theme.of(context).colorScheme.primary.toARGB32(),
      );

      pickedDt = await showContextualPopover<DateTime>(
        context: context,
        buttonContext: buttonContext,
        width: 500,
        height: 380,
        accentColor: accentColor,
        builder: (ctx) => DateTimeSelectorPopover(
          initialDateTime: entry.entryDate.toLocal(),
          accentColor: accentColor,
        ),
      );
    } finally {
      // Left set by a throwing read or route, the date pill would render in
      // its active state for the life of the page — and the button would
      // never open again.
      if (mounted) setState(() => _isDatePickerOpen = false);
    }
    if (pickedDt == null) return;

    if (!mounted) return;

    final existing = await repo.getEntry(entry.id);
    if (existing == null) return;

    final updated = existing.copyWith(entryDate: pickedDt.toUtc());
    await repo.upsertEntry(updated);
    ref.read(remoteSyncServiceProvider).pushJournalEntryNow(updated);
    if (!mounted) return;
    setState(() {
      _selectedEntry = updated;
      _shouldScrollToSelected = true;
    });
    _invalidateJournalEntryCaches();
  }

  void _scrollToSelectedEntry(List<JournalEntry> filtered) {
    if (!mounted || _selectedEntryId == null) return;

    if (_selectedEntryKey.currentContext != null) {
      Scrollable.ensureVisible(
        _selectedEntryKey.currentContext!,
        alignment: 0.5,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
      return;
    }

    final index = filtered.indexWhere((e) => e.id == _selectedEntryId);
    if (index == -1) return;

    double estimatedOffset = 0.0;
    for (int i = 0; i < index; i++) {
      final entry = filtered[i];
      final hasPreview = firstSentencePreview(entry.body).isNotEmpty;
      estimatedOffset += hasPreview ? 68.0 : 52.0;
    }

    if (!_entryListScrollController.hasClients) return;

    final viewport = _entryListScrollController.position.viewportDimension;
    final target = math.max(0.0, estimatedOffset - viewport / 2 + 34.0);

    _jumpToTarget(target);
  }

  /// Walks the list down towards [target], materializing rows as it goes.
  ///
  /// [attempt] is what stops it. `target` is an estimate built from hardcoded
  /// per-row heights that are not tied to the rendered `ListTile` at all, so a
  /// theme, density or text-scale change can push it past the real
  /// `maxScrollExtent` of a fully materialized list — and the retry, whose only
  /// exit was `target <= maxScrollExtent`, then re-armed itself every frame:
  /// one `jumpTo` per vsync forever, pinning the list at the bottom. Not a
  /// hang, which is why it would present as a janky list stuck at the end.
  void _jumpToTarget(double target, {int attempt = 0}) {
    if (!mounted || !_entryListScrollController.hasClients) return;
    final pos = _entryListScrollController.position;

    if (attempt < 8 &&
        target > pos.maxScrollExtent &&
        pos.maxScrollExtent > 0) {
      // Force layout by jumping to current max extent, then repeat next frame
      pos.jumpTo(pos.maxScrollExtent);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _jumpToTarget(target, attempt: attempt + 1);
      });
    } else {
      // We reached the target area, or hit the absolute end
      pos.jumpTo(math.min(target, pos.maxScrollExtent));
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_selectedEntryKey.currentContext != null) {
          Scrollable.ensureVisible(
            _selectedEntryKey.currentContext!,
            alignment: 0.5,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
          );
        }
      });
    }
  }

  /// Soft-deletes [entryId] and pushes the row that write actually produced.
  ///
  /// The push used to be built from the in-memory `_selectedEntry` with
  /// `copyWith(deletedAt: ...)`, which bumps to *that snapshot's* version + 1.
  /// `_selectedEntry` is refreshed only through `onSuccess` callbacks and the
  /// reconcilers, all of which have bail-out paths, so whenever it lagged the
  /// row on disk the tombstone went out at a version Firestore had already
  /// passed. The next device to pull then read the tombstone as the loser,
  /// ignored the delete, and pushed its own higher-versioned live document
  /// back — resurrecting the entry everywhere. Reading the row back after
  /// [JournalRepository.softDeleteEntry] (which now bumps the version itself)
  /// keeps the pushed tombstone monotonic.
  Future<JournalEntryDeletion?> _softDeleteAndPushTombstone(String entryId) {
    // Shared with Search, which deletes the same rows and has to restore the
    // same three things — see [softDeleteJournalEntry].
    return softDeleteJournalEntry(
      ProviderScope.containerOf(context, listen: false),
      entryId,
    );
  }

  /// Brings back an entry the toast's Undo was pressed for, and opens it.
  ///
  /// The database restore is only half of it. The list hides a deleted entry
  /// optimistically ([_optimisticallyHiddenEntryIds]) so the row goes the
  /// instant it is confirmed rather than a provider refresh later — and that
  /// hide would outlive the restore, leaving the entry back on disk but still
  /// invisible here.
  ///
  /// Opening it is the point of the undo: the delete moved the selection onto
  /// whatever row took its place (see [_selectReplacementForRemovedEntry]), so
  /// restoring without re-selecting would put the entry back into the list and
  /// leave the editor on the wrong one.
  Future<void> _undoEntryDelete(
    ProviderContainer container,
    JournalEntryDeletion deletion,
  ) async {
    try {
      await restoreJournalEntry(container, deletion);
    } finally {
      // In a `finally` because the hide has to go however the restore ended.
      // The build-time reconciliation only drops ids the provider has stopped
      // returning, so an id left here for a row that *is* back is preserved
      // deliberately — the entry would sit on disk, synced to every device,
      // and invisible on this page until the next journal switch. Cleared
      // unconditionally the list simply re-derives: back if the write landed,
      // still gone if it did not.
      if (mounted) {
        setState(() => _optimisticallyHiddenEntryIds.remove(deletion.entry.id));
        _invalidateJournalEntryCaches();
      }
    }
    if (!mounted) return;
    // Waited on before the entry is opened. [build]'s auto-select takes the
    // selection over whenever the selected entry is not among the rows on
    // screen, and the restored entry is not back among them until this future
    // resolves — so selecting it any sooner is immediately undone, and the
    // editor lands back on the replacement the delete had moved it to.
    final scope = _entryListScope(ref.read(journalsProvider).valueOrNull);
    await ref.read(journalListEntriesProvider(scope).future);
    if (!mounted) return;
    await _openEntry(deletion.entry.id);
  }

  Future<void> _deleteEntry() async {
    final entry = _selectedEntry;
    if (entry == null) return;
    // Captured while this widget is certainly mounted: the toast that offers
    // the undo outlives the row, and a `WidgetRef` would not.
    final container = ProviderScope.containerOf(context, listen: false);
    final overlay = Overlay.of(context, rootOverlay: true);

    final confirmed = await showConfirmDialog(
      context,
      title: 'Delete entry?',
      message: 'This entry will be moved to trash.',
    );
    if (!confirmed || !mounted) return;
    _logJournal('DELETE_ENTRY', details: 'id=${entry.id}');
    await _flushActiveEntryEdits(refreshList: false);
    if (!mounted) return;
    final deletion = await _softDeleteAndPushTombstone(entry.id);
    if (!mounted) return;
    final emptied = _selectReplacementForRemovedEntry(entry);
    _removePendingEntry(entry.id);
    _invalidateJournalEntryCaches();
    if (emptied) _replaceEmptiedJournalEntry(entry);
    if (deletion == null) return;
    showSoftDeleteUndoToast(
      overlay: overlay,
      message: deletedMessage(entry.title, fallback: 'entry'),
      restore: () => _undoEntryDelete(container, deletion),
    );
  }

  /// Hides [entry] from the list up front and moves the selection onto whatever
  /// entry takes its place, all in one setState. Returns true when nothing was
  /// left to move onto — see [_replaceEmptiedJournalEntry].
  ///
  /// Clearing the selection and leaving the replacement to the build's
  /// post-frame auto-select goes wrong twice over. The list that auto-select
  /// picks `first` from still contains the entry we just removed — the provider
  /// refresh lands a frame or more later — so it re-opens the deleted entry
  /// with its old title and body. And for the frame in between,
  /// `_selectedEntryId == null` collapses the mood/date/weather/delete row,
  /// letting the body box jump up into the space it vacated.
  ///
  /// Mirrors what [_moveEntryItemToJournal] does when an entry leaves the
  /// journal on screen.
  bool _selectReplacementForRemovedEntry(JournalEntry entry) {
    _optimisticallyHiddenEntryIds.add(entry.id);
    final scope = _viewAllJournals ? allJournalEntriesScope : entry.journalId;
    final scopedEntries =
        ref.read(journalListEntriesProvider(scope)).valueOrNull ??
        const <JournalEntry>[];
    final remaining = _buildDisplayEntries(scopedEntries)
        .where(
          (e) =>
              e.id != entry.id &&
              (_viewAllJournals || e.journalId == entry.journalId),
        )
        .toList();

    final displayTarget = remaining.isEmpty
        ? null
        : _prepareSelectedEntry(remaining.first);
    setState(() {
      if (displayTarget != null) {
        _selectEntryFields(displayTarget);
      } else {
        _clearEntryFields();
      }
    });
    return displayTarget == null;
  }

  /// Opens a blank entry when a delete has just emptied the journal on screen.
  ///
  /// The alternative is the editor collapsing to nothing, which is a state the
  /// journal never otherwise shows: picking an empty journal from the dropdown
  /// creates an entry to write in ([_selectJournal]), so arriving at the same
  /// empty journal by deleting its last entry should land in the same place.
  ///
  /// Only while a single journal is on screen. In the all-journals view the
  /// list is not scoped to the entry's own journal, so emptying that journal
  /// leaves plenty still listed and a blank entry appearing would be a
  /// non-sequitur — which is also why switching into that view never creates
  /// one.
  void _replaceEmptiedJournalEntry(JournalEntry entry) {
    if (_viewAllJournals) return;
    if (entry.journalId == allJournalEntriesScope) return;
    unawaited(_createEntry());
  }

  Future<void> _deleteEntryItem(JournalEntry entry) async {
    // See [_deleteEntry] on why both are captured before the delete.
    final container = ProviderScope.containerOf(context, listen: false);
    final overlay = Overlay.of(context, rootOverlay: true);

    final confirmed = await showConfirmDialog(
      context,
      title: 'Delete entry?',
      message: 'This entry will be moved to trash.',
    );
    if (!confirmed || !mounted) return;
    _logJournal('DELETE_ENTRY', details: 'id=${entry.id}');
    final wasSelected = _selectedEntryId == entry.id;
    if (wasSelected) {
      await _flushActiveEntryEdits(refreshList: false);
      if (!mounted) return;
    }
    final deletion = await _softDeleteAndPushTombstone(entry.id);
    if (!mounted) return;
    var emptied = false;
    if (wasSelected) {
      emptied = _selectReplacementForRemovedEntry(entry);
    } else {
      setState(() => _optimisticallyHiddenEntryIds.add(entry.id));
    }
    _removePendingEntry(entry.id);
    _invalidateJournalEntryCaches();
    if (emptied) _replaceEmptiedJournalEntry(entry);
    if (deletion == null) return;
    showSoftDeleteUndoToast(
      overlay: overlay,
      message: deletedMessage(entry.title, fallback: 'entry'),
      restore: () => _undoEntryDelete(container, deletion),
    );
  }

  Future<void> _moveEntryItemToJournal(
    JournalEntry entry,
    String journalId,
  ) async {
    if (entry.journalId == journalId) return;
    // Every other selection change on this page flushes first; the two move
    // handlers were the exception. Without it the `journalId` write below
    // carries `existing.body` from disk (missing the in-flight keystrokes),
    // the rebuild swaps the editor onto the replacement entry, and the pending
    // body debounce — which re-reads `_selectedEntryId` when it fires — then
    // persists the *replacement's* text. The moved entry's draft survives in
    // `_entryBodyDrafts` for the rest of the session, which is what makes the
    // loss invisible until the app is restarted.
    if (_selectedEntryId == entry.id) {
      await _flushActiveEntryEdits(refreshList: false);
      if (!mounted) return;
    }
    final repo = ref.read(journalRepositoryProvider);
    final existing = await repo.getEntry(entry.id);
    if (existing == null) return;
    final updated = existing.copyWith(journalId: journalId);
    await repo.upsertEntry(updated);
    ref.read(remoteSyncServiceProvider).pushJournalEntryNow(updated);
    if (!mounted) return;

    if (_selectedEntryId == entry.id) {
      setState(() => _selectedEntry = updated);
    }

    if (_viewAllJournals) {
      _invalidateJournalEntryCaches();
      return;
    }

    if (_selectedEntryId == entry.id) {
      _optimisticallyHiddenEntryIds.add(entry.id);
      final scope = entry.journalId;
      final scopedEntries =
          ref.read(journalListEntriesProvider(scope)).valueOrNull ??
          const <JournalEntry>[];
      final remaining = _buildDisplayEntries(
        scopedEntries,
      ).where((e) => e.journalId == scope && e.id != entry.id).toList();

      final displayTarget = remaining.isEmpty
          ? null
          : _prepareSelectedEntry(remaining.first);
      setState(() {
        if (displayTarget != null) {
          _selectEntryFields(displayTarget);
        } else {
          _selectedEntryId = null;
          _selectedEntry = null;
          _titleController.clear();
        }
      });
    }
    _invalidateJournalEntryCaches();
  }

  void _showEntryStatistics(JournalEntry entry) {
    showJournalEntryStatisticsDialog(context, ref, entry);
  }

  Future<void> _showChangeJournalDialog(
    JournalEntry entry,
    List<Journal> journals,
  ) async {
    final targetJournalId = await showMoveToJournalDialog(
      context,
      journals: journals,
      currentJournalId: entry.journalId,
    );
    if (targetJournalId != null && mounted) {
      await _moveEntryItemToJournal(entry, targetJournalId);
    }
  }

  Future<void> _editQuote() async {
    final entry = _selectedEntry;
    if (entry == null) return;
    final quote = await showVoyagerDialog<String?>(
      context: context,
      builder: (dialogContext) =>
          _EditQuoteDialog(initialQuote: entry.customQuote ?? ''),
    );
    if (quote == null) return;
    // Through the coordinator, like every other field edit: this dialog is
    // modal and can sit open for minutes while autosaves, remote pulls and
    // pending-merge writes land underneath it. Building the write from the
    // in-memory `_selectedEntry` reverted `body`, `title`, `mood`, `tags` and
    // `entryDate` to whatever they were when it opened, and pushed the
    // reverted row — and it bypassed the per-document save queue entirely, so
    // it could interleave with a queued save rather than ordering behind it.
    await _writeCoordinatorOrNull()?.saveEntry(
      entryId: entry.id,
      bumpVersion: true,
      applyDelta: (base) =>
          base.copyWith(customQuote: quote.trim(), bumpVersion: false),
      onSuccess: (updated) {
        if (mounted) setState(() => _selectedEntry = updated);
      },
    );
  }

  Future<void> _moveEntryToJournal(String journalId) async {
    final entry = _selectedEntry;
    if (entry == null || entry.journalId == journalId) return;
    // See [_moveEntryItemToJournal]: the re-read below has to include whatever
    // is still sitting unsaved in the editor.
    if (_selectedEntryId == entry.id) {
      await _flushActiveEntryEdits(refreshList: false);
      if (!mounted) return;
    }
    final repo = ref.read(journalRepositoryProvider);
    final existing = await repo.getEntry(entry.id);
    if (existing == null) return;
    final updated = existing.copyWith(journalId: journalId);
    await repo.upsertEntry(updated);
    ref.read(remoteSyncServiceProvider).pushJournalEntryNow(updated);
    if (!mounted) return;

    if (_viewAllJournals) {
      setState(() => _selectedEntry = updated);
      _invalidateJournalEntryCaches();
      return;
    }

    // Non-view-all: the moved entry leaves the journal we're currently viewing.
    // Hide it and pick the next entry to show up front, then apply everything in
    // a single setState. Selecting the replacement entry in the same frame
    // (instead of clearing the selection and letting a post-frame callback
    // re-select) keeps the editor mounted, so the metadata row and body just
    // swap their contents in place rather than flashing away and back.
    _optimisticallyHiddenEntryIds.add(entry.id);
    final scope = entry.journalId;
    final scopedEntries =
        ref.read(journalListEntriesProvider(scope)).valueOrNull ??
        const <JournalEntry>[];
    final remaining = _buildDisplayEntries(
      scopedEntries,
    ).where((e) => e.journalId == scope && e.id != entry.id).toList();

    final displayTarget = remaining.isEmpty
        ? null
        : _prepareSelectedEntry(remaining.first);
    setState(() {
      if (displayTarget != null) {
        _selectEntryFields(displayTarget);
      } else {
        _clearEntryFields();
      }
    });
    _invalidateJournalEntryCaches();
  }

  int _journalFlagColor(Journal journal) =>
      journal.colorValue ?? Theme.of(context).colorScheme.primary.toARGB32();

  Widget? _journalFlagForEntry(JournalEntry entry, List<Journal> journals) {
    final journal = journals.cast<Journal?>().firstWhere(
      (j) => j!.id == entry.journalId,
      orElse: () => null,
    );
    final color = journal != null
        ? _journalFlagColor(journal)
        : Theme.of(context).colorScheme.primary.toARGB32();
    return JournalTitleCornerFlag(
      colorValue: color,
      onSelected: _moveEntryToJournal,
      menuEntries: (_) => [
        for (var i = 0; i < journals.length; i++)
          VoyagerPopupMenuItem<String>(
            value: journals[i].id,
            position: VoyagerMenuTheme.positionFor(i, journals.length),
            child: Row(
              children: [
                JournalBookmarkFlag(
                  colorValue: _journalFlagColor(journals[i]),
                  size: 12,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    journals[i].name,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (journals[i].id == entry.journalId)
                  Icon(
                    PhosphorIconsRegular.check,
                    size: 18,
                    color: Theme.of(context).colorScheme.primary,
                  ),
              ],
            ),
          ),
      ],
    );
  }

  IconData _weatherData(String? icon) => weatherIconData(icon);

  @override
  Widget build(BuildContext context) {
    _remoteSync = ref.read(remoteSyncServiceProvider);
    _journalRepository = ref.read(journalRepositoryProvider);
    _journalWriteCoordinator = ref.read(journalWriteCoordinatorProvider);
    _journalDebugLogger = ref.read(journalDebugLoggerProvider);
    final journalsAsync = ref.watch(journalsProvider);
    final settings = ref.watch(settingsProvider).valueOrNull;
    final entryListScope = _entryListScope(journalsAsync.valueOrNull);
    final entriesScope = _viewAllJournals
        ? allJournalEntriesScope
        : entryListScope;
    final entriesAsync = ref.watch(journalListEntriesProvider(entriesScope));

    // The second of the page's two paths from the provider into the open
    // editor. [_reconcileSelectedEntryFromProvider] covers the same provider
    // but cannot push a changed body into a *mounted* editor — the editor only
    // re-reads `entry.body` when the entry id changes — so this one stays for
    // live-sync pulls that land while the entry is open.
    //
    // It now carries the same guards as that reconciler, which it had none of.
    // Without them it clobbered a half-typed title (dropping the IME composing
    // region, and leaving `_metadataDirty` set so the pending debounce wrote
    // the *replaced* title back as if the user had typed it), overwrote a
    // focused editor, and left `_entryBodyDrafts` untouched — manufacturing
    // the stale-draft state that resurrects old text over a remote merge.
    ref.listen(journalListEntriesProvider(entriesScope), (previous, next) {
      if (!mounted) return;
      final entries = next.valueOrNull;
      final selectedId = _selectedEntryId;
      if (entries == null || selectedId == null) return;
      if (_pendingEntries.containsKey(selectedId)) return;
      if (_editorKey.currentState?.hasFocus ?? false) return;
      if (_titleFocusNode.hasFocus || _metadataDirty) return;
      if (_entryBodyDrafts.containsKey(selectedId)) return;

      final updated = entries.where((e) => e.id == selectedId).firstOrNull;
      final current = _selectedEntry;
      if (updated == null || current == null) return;
      if (!updated.updatedAt.isAfter(current.updatedAt) &&
          updated.version <= current.version) {
        return;
      }

      setState(() {
        _selectedEntry = updated;
        if (_titleController.text != updated.title) {
          _titleController.text = updated.title;
        }
        _listTitlePreview.value = updated.title;
        _listBodyPreview.value = updated.body;
        _mood = updated.mood;
        _weatherIcon = updated.weatherIcon;
      });
      // recordAsEdit, because this text arrives from SQLite by a route the
      // character-op session knows nothing about — a non-CRDT LWW pull, an
      // outbox replay, an import. See [_PlainJournalEditorState.setBodyText].
      _editorKey.currentState?.setBodyText(updated.body, recordAsEdit: true);
    });

    return journalsAsync.when(
      skipLoadingOnReload: true,
      data: (journals) {
        _applySavedPreferencesIfReady(settings, journals);
        if (entriesAsync.hasError && entriesAsync.valueOrNull == null) {
          return Center(child: Text('${entriesAsync.error}'));
        }
        final entries = _resolveScopedEntries(entriesAsync, entriesScope);
        final entriesLoading = _resolveEntriesLoading(
          entriesAsync,
          entriesScope,
        );
        return _buildJournalContent(
          journals: journals,
          entries: entries,
          entriesLoading: entriesLoading,
          settings: settings,
          entryListScope: entryListScope,
          entriesScope: entriesScope,
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('$e')),
    );
  }

  Widget _buildJournalContent({
    required List<Journal> journals,
    required List<JournalEntry> entries,
    required bool entriesLoading,
    required AppSettings? settings,
    required String entryListScope,
    required String entriesScope,
  }) {
    final entryCountsAsync = ref.watch(journalEntryCountsProvider);
    final allEntryIdsAsync = ref.watch(journalAllEntryIdsProvider);
    _reconcilePendingEntries(allEntryIdsAsync.valueOrNull ?? const {});
    final displayEntries = _buildDisplayEntries(entries);
    _reconcileSelectedEntryFromProvider(entries);
    final displayJournals = _displayJournals(journals);
    final desiredFilter = _pendingRestoreJournalId ?? _journalFilter;
    final journalFilter = displayJournals.any((j) => j.id == desiredFilter)
        ? desiredFilter
        : displayJournals.isNotEmpty
        ? displayJournals.first.id
        : legacyJournalId;
    if (journalFilter != _journalFilter) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() => _journalFilter = journalFilter);
      });
    }
    // Journals opted out of the combined list are dropped here rather than in
    // the provider: the provider's per-scope cache is shared with the counts
    // and the tag pool, which the opt-out deliberately doesn't touch.
    final excludedFromAllView = {
      for (final journal in displayJournals)
        if (!journal.includeInAllView) journal.id,
    };
    var filtered = _viewAllJournals
        ? displayEntries
              .where((e) => !excludedFromAllView.contains(e.journalId))
              .toList()
        : displayEntries.where((e) => e.journalId == entryListScope).toList();

    if (_shouldScrollToSelected) {
      final index = filtered.indexWhere((e) => e.id == _selectedEntryId);
      if (index != -1) {
        final dbSeconds =
            filtered[index].entryDate.millisecondsSinceEpoch ~/ 1000;
        final selectedSeconds =
            (_selectedEntry?.entryDate.millisecondsSinceEpoch ?? 0) ~/ 1000;
        if (dbSeconds == selectedSeconds) {
          _shouldScrollToSelected = false;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _scrollToSelectedEntry(filtered);
          });
        }
      }
    }
    final accentJournal = _selectedEntry == null
        ? null
        : displayJournals.cast<Journal?>().firstWhere(
            (j) => j!.id == _selectedEntry!.journalId,
            orElse: () => null,
          );
    final accentColor = Color(
      accentJournal != null
          ? _journalFlagColor(accentJournal)
          : Theme.of(context).colorScheme.primary.toARGB32(),
    );
    // Which journal's per-journal toggles the editor chrome obeys. In the
    // all-journals view the rows come from several journals at once, so it
    // follows the entry actually open; with nothing selected it falls back to
    // the journal a new entry would be filed under.
    final chromeJournal =
        accentJournal ??
        displayJournals.cast<Journal?>().firstWhere(
          (j) => j!.id == journalFilter,
          orElse: () => null,
        );
    final showMoodBar = chromeJournal?.showMood ?? true;
    final showWeatherPicker = chromeJournal?.showWeather ?? true;
    final showEntryQuote =
        (settings?.showQuotes ?? true) && (chromeJournal?.showQuotes ?? true);
    final selectedVisible = filtered.any(
      (entry) => entry.id == _selectedEntryId,
    );
    final shouldSelectLatest =
        filtered.isNotEmpty &&
        !_suppressAutoSelect &&
        (_selectedEntryId == null ||
            (!_viewAllJournals &&
                (_selectedEntry?.journalId != entryListScope ||
                    !selectedVisible)));
    if (shouldSelectLatest) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || filtered.isEmpty) return;
        final latest = filtered.first;
        if (_selectedEntryId != latest.id) {
          unawaited(_loadEntry(latest));
        }
      });
    }
    if (selectedVisible &&
        (_selectedEntryId == null ||
            !_pendingEntries.containsKey(_selectedEntryId))) {
      _suppressAutoSelect = false;
    }

    final countsByJournal = entryCountsAsync.valueOrNull;
    // Use all DB IDs (including deleted) to filter pending entries:
    // a pending entry is only "extra" if it's genuinely not yet in the DB
    // at all — not if it's already there but soft-deleted.
    final dbEntryIds =
        allEntryIdsAsync.valueOrNull ?? {for (final e in entries) e.id};
    final entryCounts = {
      for (final journal in displayJournals)
        journal.id: _entryCountForJournal(
          journal.id,
          persistedCounts: countsByJournal,
          entryListScope: entriesScope,
          displayEntries: displayEntries,
          dbEntryIds: dbEntryIds,
        ),
    };
    final selectedJournal = displayJournals.cast<Journal?>().firstWhere(
      (j) => j!.id == journalFilter,
      orElse: () => null,
    );
    // The shade the entry-list bar is keyed to: the journal being viewed, or
    // the plain accent while "All journals" is on (which has no colour of its
    // own). Worn by the journal dropdown at the top of the bar.
    final journalBarColor = Color(
      _viewAllJournals || selectedJournal == null
          ? Theme.of(context).colorScheme.primary.toARGB32()
          : _journalFlagColor(selectedJournal),
    );
    // The "New entry" button at the other end of the bar answers a different
    // question — not "what am I looking at?" but "where does this go?" — and
    // in the all-view those diverge. It names and wears the destination
    // journal so the answer isn't invisible at the moment of writing.
    final destinationJournal = displayJournals.cast<Journal?>().firstWhere(
      (j) => j!.id == _journalIdForNewEntry(displayJournals),
      orElse: () => null,
    );
    final composerColor = _viewAllJournals && destinationJournal != null
        ? Color(_journalFlagColor(destinationJournal))
        : journalBarColor;
    final composerLabel = _viewAllJournals && destinationJournal != null
        ? 'New entry in ${shortDestinationName(destinationJournal.name)}'
        : 'New entry';

    // Drop cached row widgets for entries no longer displayed, so
    // deleted/filtered-out entries don't leak entries indefinitely.
    final liveRowIds = {for (final e in filtered) e.id};
    _rowWidgetCache.removeWhere((id, _) => !liveRowIds.contains(id));
    _rowSignatureCache.removeWhere((id, _) => !liveRowIds.contains(id));

    // And the same for the optimistic-hide set. Once the provider has stopped
    // returning an id, the hide it was standing in for has landed and holding
    // the id does nothing but cost a `contains` per entry per build — the set
    // was otherwise only ever cleared wholesale on a journal switch, so a
    // session spent deleting inside one journal grew it without bound. Skipped
    // while the scope's entries are still loading, when an empty list would
    // otherwise unhide everything for a frame.
    if (!entriesLoading && _optimisticallyHiddenEntryIds.isNotEmpty) {
      final knownIds = {for (final e in entries) e.id};
      _optimisticallyHiddenEntryIds.removeWhere((id) => !knownIds.contains(id));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SyncConflictBanner(),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final totalWidth = constraints.maxWidth;
              final storedListWidth =
                  _entryListWidth ??
                  JournalEntryListLayout.defaultListWidth(totalWidth);
              // While dragging, storedListWidth is already soft-bounded (see
              // _onEntryListDragUpdate) — re-clamping here would cancel the
              // rubber-band out before it ever reaches the screen.
              final listWidth = _entryListDragging
                  ? storedListWidth
                  : JournalEntryListLayout.clampListWidth(
                      storedListWidth,
                      totalWidth,
                    );
              // Two compositions of the same two panes. Side by side in the
              // desktop window with a draggable divider between them; one at a
              // time on a phone, where splitting 360dp would leave neither the
              // list nor the editor usable.
              final compact = context.isCompactWidth;
              final showList = !compact || !_compactShowingEditor;
              final showEditor = !compact || _compactShowingEditor;

              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (showList)
                    AnimatedContainer(
                      duration: _entryListDragging
                          ? Duration.zero
                          : const Duration(milliseconds: 260),
                      curve: VoyagerMotion.reduced(context)
                          ? Curves.easeOut
                          : VoyagerSpring.moveCurve,
                      width: compact ? totalWidth : listWidth,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Positioned(
                            top: _entryListHeaderHeight,
                            left: 0,
                            right: 0,
                            bottom: _entryListFooterHeight,
                            child: entriesLoading
                                ? const Center(
                                    child: CircularProgressIndicator(),
                                  )
                                : Material(
                                    type: MaterialType.transparency,
                                    color: Colors.transparent,
                                    child: KeepAliveScrollList(
                                      storageKey: _entryListStorageKey(),
                                      controller: _entryListScrollController,
                                      itemCount: filtered.length,
                                      // An entry created/deleted anywhere shifts
                                      // every entry after it to a new index;
                                      // without this, the framework can't match
                                      // a row's ValueKey back to its old
                                      // Element when that happens, so it
                                      // destroys and recreates every shifted
                                      // row instead of reusing `_rowFor`'s
                                      // cached widget.
                                      findChildIndexCallback: (key) {
                                        if (key is! ValueKey<String>) {
                                          return null;
                                        }
                                        final index = filtered.indexWhere(
                                          (e) => e.id == key.value,
                                        );
                                        return index == -1 ? null : index;
                                      },
                                      itemBuilder: (_, i) {
                                        final entry = filtered[i];
                                        final isSelected =
                                            entry.id == _selectedEntryId;
                                        return KeyedSubtree(
                                          key: ValueKey(entry.id),
                                          child: Builder(
                                            key: isSelected
                                                ? _selectedEntryKey
                                                : null,
                                            builder: (context) =>
                                                ContextMenuRegion(
                                                  items: [
                                                    ContextMenuItem(
                                                      label: 'Statistics',
                                                      icon: PhosphorIconsRegular
                                                          .chartBar,
                                                      onTap: () =>
                                                          _showEntryStatistics(
                                                            entry,
                                                          ),
                                                    ),
                                                    ContextMenuItem(
                                                      label: 'Change Journal',
                                                      icon: PhosphorIconsRegular
                                                          .folder,
                                                      onTap: () =>
                                                          _showChangeJournalDialog(
                                                            entry,
                                                            displayJournals,
                                                          ),
                                                    ),
                                                    ContextMenuItem(
                                                      label: 'Delete',
                                                      icon: PhosphorIconsRegular
                                                          .trash,
                                                      isDestructive: true,
                                                      onTap: () =>
                                                          _deleteEntryItem(
                                                            entry,
                                                          ),
                                                    ),
                                                  ],
                                                  child: _rowFor(
                                                    entry,
                                                    isSelected: isSelected,
                                                  ),
                                                ),
                                          ),
                                        );
                                      },
                                    ),
                                  ),
                          ),
                          Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            child: _JournalBarBackdrop(
                              child: Padding(
                                padding: const EdgeInsets.all(
                                  _entryListHeaderPadding,
                                ),
                                child: _JournalScopeHeader(
                                  journals: displayJournals,
                                  entryCounts: entryCounts,
                                  allEntriesCount: filtered.length,
                                  selectedJournalId: journalFilter,
                                  viewAllJournals: _viewAllJournals,
                                  accent: journalBarColor,
                                  flagColorOf: _journalFlagColor,
                                  onSelectJournal: (id) =>
                                      unawaited(_selectJournal(id)),
                                  onSelectAllJournals: () =>
                                      unawaited(_selectAllJournals()),
                                  onManage: () =>
                                      unawaited(_openJournalManageSheet()),
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            bottom: 0,
                            left: 0,
                            right: 0,
                            child: _JournalBarBackdrop(
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: GlassButton(
                                  onPressed: () {
                                    _revealCompactEditor();
                                    unawaited(_createEntry());
                                  },
                                  label: composerLabel,
                                  color: composerColor,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (!compact)
                    ResizablePaneDivider(
                      onDragStart: () => _onEntryListDragStart(totalWidth),
                      onDragUpdate: (totalDelta) =>
                          _onEntryListDragUpdate(totalDelta, totalWidth),
                      onDragEnd: () => _onEntryListDragEnd(totalWidth),
                      onDoubleTapReset: _resetEntryListWidth,
                    ),
                  if (showEditor)
                    Expanded(
                      child: Padding(
                        padding: JournalEntryListLayout.editorPadding,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (compact)
                              CompactBackBar(
                                label: 'Entries',
                                onBack: () => unawaited(_closeCompactEditor()),
                              ),
                            Padding(
                              padding: const EdgeInsets.only(
                                top: 8,
                                bottom: 12,
                              ),
                              child: Stack(
                                clipBehavior: Clip.none,
                                alignment: Alignment.centerRight,
                                children: [
                                  Focus(
                                    onKeyEvent: (node, event) {
                                      if (event is! KeyDownEvent) {
                                        return KeyEventResult.ignored;
                                      }
                                      if (event.logicalKey ==
                                              LogicalKeyboardKey.tab &&
                                          !HardwareKeyboard
                                              .instance
                                              .isShiftPressed) {
                                        _submitTitleAndFocusBody();
                                        return KeyEventResult.handled;
                                      }
                                      return KeyEventResult.ignored;
                                    },
                                    child: LabeledTextField(
                                      label: 'Title',
                                      controller: _titleController,
                                      focusNode: _titleFocusNode,
                                      textInputAction: TextInputAction.next,
                                      accentColor: accentColor,
                                      contentPadding: const EdgeInsets.fromLTRB(
                                        16,
                                        16,
                                        40,
                                        16,
                                      ),
                                      onChanged: (value) {
                                        _metadataDirty = true;
                                        _listTitlePreview.value = value;
                                        _scheduleMetadataSave();
                                      },
                                      onSubmitted: (_) =>
                                          _submitTitleAndFocusBody(),
                                    ),
                                  ),
                                  if (_selectedEntry != null)
                                    Positioned(
                                      top: 0,
                                      right: 10,
                                      child: _journalFlagForEntry(
                                        _selectedEntry!,
                                        displayJournals,
                                      )!,
                                    ),
                                ],
                              ),
                            ),
                            // Always on screen, even with nothing selected.
                            // Deleting the last entry in a journal used to
                            // take the whole row with it, so the mood bar,
                            // weather, date and trash vanished and the body
                            // box grew into the gap; now it stays put showing
                            // the defaults a new entry would carry.
                            // [_deleteEntry] and [_changeEntryDateAndTime]
                            // both return early with no selection, so the two
                            // live controls simply do nothing there.
                            // Pinned to the mood slider's own height. The
                            // slider is 48 tall and ignores visual density,
                            // while every other control in the row is an
                            // icon button that does not: on desktop those
                            // shrink to 40, so hiding the mood bar took 8px
                            // out of the row and slid the body box up with
                            // it. The floor holds the row still whichever
                            // toggles are off.
                            LayoutBuilder(
                              builder: (context, constraints) {
                                final moodBar = <Widget>[
                                  Text(
                                    'Mood',
                                    style: TextStyle(color: accentColor),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: MoodGradientSlider(
                                      value: _mood,
                                      accent: accentColor,
                                      onChanged: (value) {
                                        setState(() {
                                          _mood = value;
                                          _metadataDirty = true;
                                        });
                                        _scheduleMetadataSave();
                                      },
                                    ),
                                  ),
                                ];
                                final controls = <Widget>[
                                  if (showWeatherPicker) ...[
                                    PopupMenuButton<VoyagerMenuCatalogEntry>(
                                      tooltip: 'Weather',
                                      icon: Icon(
                                        _weatherData(_weatherIcon),
                                        color: accentColor,
                                      ),
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(
                                        minWidth: 40,
                                        minHeight: 40,
                                      ),
                                      onSelected: (entry) {
                                        setState(() {
                                          _weatherIcon = entry.weatherIconValue;
                                          _metadataDirty = true;
                                        });
                                        _scheduleMetadataSave();
                                      },
                                      itemBuilder: (context) =>
                                          buildCatalogMenu(
                                            context,
                                            from: weatherMenuEntries,
                                          ),
                                    ),
                                    const SizedBox(width: 8),
                                  ],
                                  Builder(
                                    builder: (ctx) {
                                      // Now, with nothing selected: the date a
                                      // new entry would be filed under.
                                      final date =
                                          _selectedEntry?.entryDate.toLocal() ??
                                          DateTime.now();
                                      final label =
                                          '${DateFormat.yMMMd().format(date)} at ${formatTime12Hour(date)}';
                                      // A floor rather than a fixed width: it
                                      // holds the row still across every label
                                      // the formatter can produce, and a label
                                      // pushed past it by text scaling still
                                      // gets the room instead of overflowing.
                                      return ConstrainedBox(
                                        constraints: const BoxConstraints(
                                          minWidth: _journalDatePillMinWidth,
                                        ),
                                        child: SelectorPill(
                                          dense: false,
                                          ellipsize: false,
                                          isActive: _isDatePickerOpen,
                                          label: label,
                                          accentColor: accentColor,
                                          onTap: () =>
                                              _changeEntryDateAndTime(ctx),
                                        ),
                                      );
                                    },
                                  ),
                                  const SizedBox(width: 8),
                                  if (_selectedEntry != null &&
                                      ref
                                          .watch(devSettingsProvider)
                                          .showJournalRemotePullButton) ...[
                                    IconButton(
                                      tooltip: 'Compare remote DB value',
                                      onPressed: () =>
                                          _pullAndCompareRemoteValue(
                                            _selectedEntry!,
                                          ),
                                      icon: const Icon(
                                        PhosphorIconsRegular.cloudArrowDown,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                  ],
                                  IconButton(
                                    tooltip: 'Delete entry',
                                    onPressed: _deleteEntry,
                                    icon: Icon(
                                      PhosphorIconsRegular.trash,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.error,
                                    ),
                                  ),
                                ];
                                Widget line(List<Widget> children) =>
                                    ConstrainedBox(
                                      constraints: const BoxConstraints(
                                        minHeight: kMinInteractiveDimension,
                                      ),
                                      child: Row(children: children),
                                    );
                                // Too narrow to share a line (a half-screen
                                // window beside a wide entry list): the
                                // controls cannot shrink, so the slider was
                                // squeezed to nothing and the row still
                                // overflowed. It takes a line of its own.
                                if (showMoodBar &&
                                    constraints.maxWidth <
                                        _journalMetadataRowMinWidth) {
                                  return Column(
                                    children: [
                                      line(moodBar),
                                      line([const Spacer(), ...controls]),
                                    ],
                                  );
                                }
                                // With the mood bar hidden the slider's
                                // Expanded goes with it, so a Spacer takes
                                // over its stretch — otherwise the date pill
                                // and trash slide left into the empty space
                                // instead of staying where they always are.
                                return line([
                                  if (showMoodBar) ...[
                                    ...moodBar,
                                    const SizedBox(width: 12),
                                  ] else
                                    const Spacer(),
                                  ...controls,
                                ]);
                              },
                            ),
                            const SizedBox(height: 12),
                            Expanded(
                              child: _PlainJournalEditor(
                                key: _editorKey,
                                entry: _selectedEntry,
                                focusNode: _bodyFocusNode,
                                accentColor: accentColor,
                                onDraftChanged: _updateBodyDraft,
                                onScheduleBodySave: _scheduleBodySave,
                                waitForFlush: () => _flushInProgress,
                                onDebugLog: (event, {details}) =>
                                    _logJournal(event, details: details),
                              ),
                            ),
                            if (showEntryQuote && _selectedEntry != null)
                              _EntryQuote(
                                quote: _selectedEntry!.customQuote,
                                onTap: _editQuote,
                              ),
                          ],
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _PlainJournalEditor extends ConsumerStatefulWidget {
  const _PlainJournalEditor({
    super.key,
    required this.entry,
    required this.focusNode,
    required this.onDraftChanged,
    required this.onScheduleBodySave,
    required this.accentColor,
    this.waitForFlush,
    this.onDebugLog,
  });

  final JournalEntry? entry;
  final FocusNode focusNode;
  final Color accentColor;
  final void Function(String entryId, String body) onDraftChanged;
  final VoidCallback onScheduleBodySave;
  final Future<void>? Function()? waitForFlush;
  final void Function(String event, {String? details})? onDebugLog;

  @override
  ConsumerState<_PlainJournalEditor> createState() =>
      _PlainJournalEditorState();
}

class _EditQuoteDialog extends StatefulWidget {
  const _EditQuoteDialog({required this.initialQuote});

  final String initialQuote;

  @override
  State<_EditQuoteDialog> createState() => _EditQuoteDialogState();
}

/// Picks one quote out of the whole pool — bundled plus the user's own.
///
/// Opened from the edit dialog rather than replacing it: the entry's quote is
/// free text that happens to *start* as a pooled one, so browsing hands the
/// chosen text back to the editor to keep or amend rather than committing it.
class _BrowseQuotesDialog extends ConsumerStatefulWidget {
  const _BrowseQuotesDialog();

  @override
  ConsumerState<_BrowseQuotesDialog> createState() =>
      _BrowseQuotesDialogState();
}

class _BrowseQuotesDialogState extends ConsumerState<_BrowseQuotesDialog> {
  final _searchController = TextEditingController();
  var _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final poolAsync = ref.watch(quotePoolProvider);
    final needle = _query.trim().toLowerCase();

    return AlertDialog(
      title: const Text('Choose a quote'),
      content: SizedBox(
        width: 720,
        height: 480,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LabeledTextField(
              label: '',
              showLabel: false,
              hintText: 'Search quotes',
              controller: _searchController,
              autofocus: true,
              dense: true,
              borderRadius: 12,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 15,
                vertical: 8,
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: poolAsync.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (error, _) =>
                    Center(child: Text('Could not load quotes: $error')),
                data: (pool) {
                  final matches = needle.isEmpty
                      ? pool
                      : pool
                            .where((q) => q.text.toLowerCase().contains(needle))
                            .toList();
                  if (matches.isEmpty) {
                    return Center(
                      child: Text(
                        'No quotes match "$_query".',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    );
                  }
                  return ListView.builder(
                    itemCount: matches.length,
                    itemBuilder: (context, index) {
                      final quote = matches[index];
                      return ListTile(
                        dense: true,
                        // The filter above matches the query as one phrase, so
                        // the highlight takes it as one too rather than
                        // lighting up each word wherever it happens to appear.
                        title: keywordHighlightedText(
                          quote.text,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontStyle: FontStyle.italic,
                          ),
                          keywords: [needle],
                        ),
                        onTap: () => Navigator.pop(context, quote.text),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        GlassButton(
          dense: true,
          onPressed: () => Navigator.pop(context),
          label: 'Cancel',
        ),
      ],
    );
  }
}

class _EditQuoteDialogState extends State<_EditQuoteDialog> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialQuote);
    _focusNode = FocusNode();
    _focusNode.onKeyEvent = (node, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      if (event.logicalKey == LogicalKeyboardKey.enter &&
          !HardwareKeyboard.instance.isShiftPressed) {
        _save();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _save() => Navigator.pop(context, _controller.text);

  void _cancel() => Navigator.pop(context);

  Future<void> _browse() async {
    final picked = await showVoyagerDialog<String>(
      context: context,
      builder: (_) => const _BrowseQuotesDialog(),
    );
    if (picked == null || !mounted) return;
    // Straight into the field rather than out of the dialog: the chosen quote
    // is a starting point the user can still edit before saving.
    _controller.text = picked;
    _controller.selection = TextSelection.collapsed(offset: picked.length);
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final dialog = PopScope<String?>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        // Dismissed via the barrier or Escape: save the current text
        // instead of discarding it.
        _save();
      },
      child: EnterToSubmitScope(
        onSubmit: _save,
        child: AlertDialog(
          title: const Text('Edit quote'),
          content: SizedBox(
            width: 720,
            child: LabeledTextField(
              label: 'Quote',
              controller: _controller,
              focusNode: _focusNode,
              autofocus: true,
              minLines: 8,
              maxLines: 16,
            ),
          ),
          actions: [
            GlassButton(
              onPressed: _browse,
              label: 'Browse quotes',
              icon: const Icon(PhosphorIconsRegular.books),
              dense: true,
            ),
            GlassButton(onPressed: _cancel, label: 'Cancel', dense: true),
            GlassButton(onPressed: _save, label: 'Save', dense: true),
          ],
        ),
      ),
    );
    return CtrlEnterToSubmitScope(onSubmit: _save, child: dialog);
  }
}

class _EntryQuote extends StatelessWidget {
  const _EntryQuote({required this.quote, required this.onTap});

  final String? quote;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = quote;
    if (text == null || text.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Align(
        alignment: Alignment.centerRight,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: VoyagerProseText(
                text,
                textAlign: TextAlign.right,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontStyle: FontStyle.italic,
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PlainJournalEditorState extends ConsumerState<_PlainJournalEditor> {
  late final TextEditingController _controller;
  Timer? _tagTimer;
  var _tags = const <String>[];
  var _lastText = '';
  var _dirty = false;
  RemoteSyncService? _remoteSync;
  SettingsRepository? _settingsRepo;
  PendingTextMergeListener? _pendingTextMergeListener;

  /// The document id this state currently holds a pending-text-merge listener
  /// and an editing flag for. Tracked rather than derived from `widget.entry`,
  /// because during an entry switch the widget has already moved on while the
  /// registrations still belong to the outgoing entry.
  String? _attachedEntryId;

  /// The entry [_controller]'s text actually belongs to.
  ///
  /// Not the same thing as `widget.entry`, which during a switch already names
  /// the incoming entry while the controller still holds the outgoing one —
  /// [_switchEntryWidget] awaits the page's in-flight flush before it reseeds
  /// the text. Anything pairing the controller's text with an entry id must
  /// read it from here, or it files one entry's body under another's. That is
  /// how a finished entry lost its body on 2026-09-16; see
  /// JOURNAL_DATA_LOSS_POSTMORTEM.md.
  ///
  /// Distinct from [_attachedEntryId], which tracks the *sync* registration and
  /// is deliberately left alone when there is no sync service to register with.
  String? _bodyEntryId;

  bool get hasFocus => widget.focusNode.hasFocus;

  /// Replaces the editor's text.
  ///
  /// [recordAsEdit] re-anchors the character-op session on the way past. The
  /// session assumes the `before` text handed to `recordJournalTextChange`
  /// always matches its own current text — the invariant `_handleBodyKey` is
  /// careful to preserve — and moving [_lastText] to the new string without
  /// telling the registry breaks it: the next keystroke is then diffed against
  /// the pre-replacement string, producing ops at positions that do not exist
  /// in the session's log, and the two devices interleave characters on the
  /// next merge.
  ///
  /// Pass it whenever [body] came from somewhere the registry has not seen
  /// (an LWW pull, an outbox replay, an import). The post-merge call in
  /// [_JournalPageState._flushActiveEntryEditsImpl] leaves it false: those ops
  /// came off the remote chain and are already in the registry.
  void setBodyText(String body, {bool recordAsEdit = false}) {
    final before = _controller.text;
    _controller.text = body;
    if (recordAsEdit && before != body) {
      final entryId = widget.entry?.id;
      if (entryId != null) {
        _remoteSync?.recordJournalTextChange(
          entryId: entryId,
          before: before,
          after: body,
        );
      }
    }
    _lastText = body;
    _tags = extractTags(body);
  }

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.entry?.body ?? '');
    widget.focusNode.addListener(_handleFocusChanged);
    // _handleBodyKey is installed by TagHighlightedTextField (see its
    // onKeyEvent param) rather than assigned here: the tag completion popup
    // owns focusNode.onKeyEvent so it can claim the arrow keys, and chains
    // through to this handler for everything it doesn't use.
    _lastText = _controller.text;
    _bodyEntryId = widget.entry?.id;
    _tags = widget.entry?.tags ?? extractTags(_controller.text);
    final entry = widget.entry;
    if (entry != null) {
      final remoteSync = ref.read(remoteSyncServiceProvider);
      _remoteSync = remoteSync;
      remoteSync.prepareEditingSession(
        collection: FirestoreCollections.journalEntries,
        documentId: entry.id,
        initialText: _controller.text,
      );
      remoteSync.setDocumentEditing(
        collection: FirestoreCollections.journalEntries,
        documentId: entry.id,
        isEditing: widget.focusNode.hasFocus,
      );
      _pendingTextMergeListener = (event) => _handlePendingTextMerge(event);
      remoteSync.addPendingTextMergeListener(
        collection: FirestoreCollections.journalEntries,
        documentId: entry.id,
        listener: _pendingTextMergeListener!,
      );
      _attachedEntryId = entry.id;
    }
  }

  /// Removes the pending-text-merge listener and clears the editing flag for
  /// [entryId].
  ///
  /// Both used to be undone after the awaited flush in [_switchEntryWidget],
  /// so a state disposed during that await short-circuited past them: the old
  /// registration outlived the state (retaining it, its controller and the
  /// entry's whole body, and firing a listener on an unmounted state for every
  /// later merge on that document), and the old id stayed in
  /// `_activelyEditedDocuments` — which makes `pullJournalEntries` buffer every
  /// future remote body change for it instead of applying one, with nothing
  /// left to drain the buffer. [dispose] could not clean up after it either,
  /// because by then `widget.entry` named the *new* entry.
  void _detachEntry(String? entryId) {
    if (entryId == null) return;
    final remoteSync = _remoteSync;
    if (remoteSync == null) return;
    final listener = _pendingTextMergeListener;
    if (listener != null) {
      remoteSync.removePendingTextMergeListener(
        collection: FirestoreCollections.journalEntries,
        documentId: entryId,
        listener: listener,
      );
    }
    remoteSync.setDocumentEditing(
      collection: FirestoreCollections.journalEntries,
      documentId: entryId,
      isEditing: false,
    );
    if (_attachedEntryId == entryId) _attachedEntryId = null;
  }

  void _handlePendingTextMerge(PendingTextMergeEvent event) {
    if (!mounted || widget.entry?.id != event.documentId) return;
    if (!widget.focusNode.hasFocus) return;

    final before = _controller.text;
    final merged = TextDeltaInjector.injectRemoteDelta(
      localText: before,
      oldRemoteText: event.previousRemoteText,
      newRemoteText: event.remoteText,
    );
    if (merged == before) return;

    widget.onDebugLog?.call(
      'EDITOR_PENDING_TEXT_MERGE',
      details:
          'previousRemoteLen=${event.previousRemoteText.length} '
          'remoteLen=${event.remoteText.length}',
    );
    final selection = _controller.selection;
    _controller.value = TextEditingValue(
      text: merged,
      selection: TextSelection.collapsed(
        offset: TextDeltaInjector.adjustedSelection(
          selection: selection.baseOffset,
          before: before,
          after: merged,
        ),
      ),
    );
    _lastText = merged;
    _tags = event.remoteTags.isNotEmpty
        ? event.remoteTags
        : extractTags(merged);
    _dirty = true;
    widget.onDraftChanged.call(event.documentId, merged);
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant _PlainJournalEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry?.id == widget.entry?.id) return;
    widget.onDebugLog?.call(
      'EDITOR_ENTRY_WIDGET_SWITCH',
      details: 'from=${oldWidget.entry?.id} to=${widget.entry?.id}',
    );
    unawaited(_switchEntryWidget(oldWidget));
  }

  Future<void> _switchEntryWidget(_PlainJournalEditor oldWidget) async {
    // Detached before the await, not after it, so a dispose landing inside the
    // flush cannot strand the outgoing entry's registrations. See [_detachEntry].
    _detachEntry(oldWidget.entry?.id);

    final pendingFlush = widget.waitForFlush?.call();
    if (pendingFlush != null) {
      await pendingFlush;
    }

    if (!mounted) return;
    final remoteSync = _remoteSync;
    _tagTimer?.cancel();
    _controller.text = widget.entry?.body ?? '';
    _lastText = _controller.text;
    // Unconditional, unlike [_attachedEntryId] below: the controller holds this
    // entry's text whether or not there is a sync service to register it with,
    // and a stale id here is what mislabels a save.
    _bodyEntryId = widget.entry?.id;
    _dirty = false;
    _tags = widget.entry?.tags ?? extractTags(_controller.text);
    _setEditingFlag(widget.entry, widget.focusNode.hasFocus);
    final entry = widget.entry;
    if (entry != null && remoteSync != null) {
      _pendingTextMergeListener ??= (event) => _handlePendingTextMerge(event);
      remoteSync.addPendingTextMergeListener(
        collection: FirestoreCollections.journalEntries,
        documentId: entry.id,
        listener: _pendingTextMergeListener!,
      );
      remoteSync.prepareEditingSession(
        collection: FirestoreCollections.journalEntries,
        documentId: entry.id,
        initialText: _controller.text,
      );
      _attachedEntryId = entry.id;
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _tagTimer?.cancel();
    // Keyed off what is actually registered rather than `widget.entry`, which
    // during a switch already names the incoming entry.
    _detachEntry(_attachedEntryId);
    widget.focusNode.removeListener(_handleFocusChanged);
    _controller.dispose();
    super.dispose();
  }

  void _handleFocusChanged() {
    if (!mounted) return;
    _setEditingFlag(widget.entry, widget.focusNode.hasFocus);
  }

  /// The live body text, but only when it is [entryId]'s.
  ///
  /// Returns null during the switch window described on [_bodyEntryId], which
  /// lets callers fall through to the page's own entry-keyed draft instead of
  /// saving the outgoing entry's text against the incoming entry.
  String? bodyTextFor(String entryId) {
    if (_bodyEntryId == entryId) return _controller.text;
    // Rare by construction, and silent before this: the caller simply wrote
    // whatever the controller held. Logging the rejection is what turns a
    // recurrence into a line in journal_debug.log instead of a body that
    // quietly goes missing — the 2026-09-16 loss left no trace at all.
    widget.onDebugLog?.call(
      'BODY_BUFFER_ENTRY_MISMATCH',
      details:
          'asked for $entryId, controller holds ${_bodyEntryId ?? "(none)"}; '
          'falling back to the entry-keyed draft.',
    );
    return null;
  }

  /// The controller's text with no regard for whose it is.
  ///
  /// Only for the debug snapshot, which exists to report what is actually in
  /// the editor — qualifying it would hide the very mismatch it is there to
  /// catch. Everything that *writes* goes through [bodyTextFor].
  String get rawBodyTextForDebug => _controller.text;

  void _setEditingFlag(JournalEntry? entry, bool isEditing) {
    if (entry == null) return;
    final remoteSync = _remoteSync;
    if (remoteSync == null) return;
    remoteSync.setDocumentEditing(
      collection: FirestoreCollections.journalEntries,
      documentId: entry.id,
      isEditing: isEditing,
    );
  }

  void _handlePointerDown() {
    final entry = widget.entry;
    final remoteSync = _remoteSync;
    if (entry == null || remoteSync == null) return;
    remoteSync.setDocumentEditing(
      collection: FirestoreCollections.journalEntries,
      documentId: entry.id,
      isEditing: true,
    );
  }

  Future<void> _persistTagColors(List<String> tags) async {
    final settingsRepo = _settingsRepo;
    if (settingsRepo == null) return;
    final colors = await settingsRepo.getTagColors();
    for (final tag in tags) {
      if (!colors.containsKey(tag)) {
        await settingsRepo.setTagColor(tag, colorForTag(tag));
      }
    }
  }

  void _handleChanged(String value) {
    applyListEditing(controller: _controller, previousText: _lastText);

    final before = _lastText;
    _lastText = _controller.text;
    // [_bodyEntryId], not `widget.entry?.id`: a keystroke landing inside the
    // switch window would otherwise file the outgoing entry's text under the
    // incoming entry's draft — poisoning the very fallback [bodyTextFor] leans
    // on — and record that text against the wrong CRDT document.
    final entryId = _bodyEntryId;
    if (entryId != null) {
      widget.onDraftChanged(entryId, _controller.text);
      _remoteSync?.recordJournalTextChange(
        entryId: entryId,
        before: before,
        after: _controller.text,
      );
    }
    _dirty = true;
    widget.onScheduleBodySave();

    _tagTimer?.cancel();
    _tagTimer = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      final nextTags = extractTags(_controller.text);
      if (_sameTags(_tags, nextTags)) return;
      _tags = nextTags;
      unawaited(_persistTagColors(nextTags));
    });
  }

  KeyEventResult _handleBodyKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.tab) {
      final outdent = HardwareKeyboard.instance.isShiftPressed;
      if (handleListTab(controller: _controller, outdent: outdent)) {
        // Tab/Backspace mutate the controller directly, bypassing
        // TextField.onChanged — route through the same handler typing uses
        // so the edit gets saved and the CRDT character-op session stays in
        // sync (recordJournalTextChange assumes `before` always matches the
        // session's actual current text; skipping it here would silently
        // desync the session and corrupt the next real edit's diff).
        _handleChanged(_controller.text);
        return KeyEventResult.handled;
      }
    }
    if (event.logicalKey == LogicalKeyboardKey.backspace) {
      if (handleListBackspace(controller: _controller)) {
        _handleChanged(_controller.text);
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    _remoteSync = ref.read(remoteSyncServiceProvider);
    _settingsRepo = ref.read(settingsRepositoryProvider);

    return _withImages(
      Listener(
        onPointerDown: (_) => _handlePointerDown(),
        child: TagHighlightedTextField(
          controller: _controller,
          focusNode: widget.focusNode,
          tagScope: TagScope.journal,
          onKeyEvent: _handleBodyKey,
          readOnly: false,
          expands: true,
          keyboardType: TextInputType.multiline,
          cursorColor: widget.accentColor,
          onChanged: _handleChanged,
          hintText: 'Start writing...',
          // Vertical contentPadding frames the field's internal scrollable
          // viewport rather than scrolling away with the text inside it, so a
          // large value (the previous default of 16) left a permanent blank
          // strip at the top/bottom whenever the body was scrolled, with the
          // first/last visible line clipped right at its edge. Top and bottom
          // are set apart rather than symmetrically: the top carries the
          // breathing room the first line needs below the border, while the
          // bottom stays small so the strip under a scrolled body remains
          // imperceptible. Horizontal padding is unaffected since it isn't
          // part of the scrollable axis.
          contentPadding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
          decoration: const InputDecoration(
            filled: false,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
          ),
        ),
      ),
    );
  }

  /// Wraps the writing area in this entry's images.
  ///
  /// The images belong to the entry, not to its text: they are reference rows
  /// on the entry, and the fan in the corner is where they are seen. Pasting
  /// and dropping are what puts them there — the journal offers no file
  /// picker, per MEDIA.md.
  ///
  /// An entry that has not been created yet (no selection, hence no id to own
  /// anything) gets the same wrappers around the same field, holding a null
  /// owner: the editor is built before the page has picked an entry, so
  /// handing back the bare field there and the wrapped one a frame later
  /// re-inflates everything below — a new [EditableText], a new
  /// `TagSuggestionPortal`, and a body that has quietly lost the caret's
  /// input connection and its key handling. Only the fan is conditional, and
  /// it is the last child of the [Stack] so adding it leaves the field's own
  /// element where it was.
  Widget _withImages(Widget field) {
    final entryId = widget.entry?.id;
    return MediaPasteScope(
      collection: FirestoreCollections.journalEntries,
      documentId: entryId,
      // The body is image-capable, so a clipboard holding both a screenshot
      // and its caption pastes both rather than dropping the picture.
      fieldTakesBoth: true,
      child: MediaDropTarget(
        collection: FirestoreCollections.journalEntries,
        documentId: entryId,
        child: Stack(
          children: [
            Positioned.fill(child: field),
            // Floating over the text rather than reserving a band under it:
            // Flutter cannot wrap a paragraph around a corner, so the only
            // alternative would be padding the full width of every entry,
            // images or not. A long entry's last lines pass beneath the fan.
            if (entryId != null)
              Positioned(
                right: 8,
                bottom: 8,
                child: MediaFanStack(
                  collection: FirestoreCollections.journalEntries,
                  documentId: entryId,
                  accentColor: widget.accentColor,
                ),
              ),
          ],
        ),
      ),
    );
  }

  bool _sameTags(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Guards the dev-only "compare remote" button: the Firestore read below runs
/// with nothing on screen, so a second press landing in that gap would stack a
/// second dialog on the first. Released the moment the dialog goes up, whose
/// own barrier covers the button from there. Module level because an extension
/// cannot hold state.
bool _remoteCompareOpen = false;

extension on _JournalPageState {
  Future<void> _pullAndCompareRemoteValue(JournalEntry entry) async {
    if (_remoteCompareOpen) return;
    _remoteCompareOpen = true;
    final scaffoldMsg = ScaffoldMessenger.of(context);
    try {
      final userId = FirebaseAuth.instance.currentUser?.uid;
      if (userId == null) {
        scaffoldMsg.showSnackBar(
          const SnackBar(content: Text('Not signed in')),
        );
        return;
      }
      final doc = await FirebaseFirestore.instance
          .collection('users/$userId/${FirestoreCollections.journalEntries}')
          .doc(entry.id)
          .get();
      if (!mounted) return;

      final remoteData = doc.data();
      final remoteText = remoteData?['body'] as String? ?? '';

      final currentLocalText =
          _editorKey.currentState?.bodyTextFor(entry.id) ?? entry.body;

      _remoteCompareOpen = false;
      await showVoyagerDialog<void>(
        context: this.context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Remote Value Comparison'),
          content: VoyagerScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Local (Current UI):',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.grey.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(currentLocalText),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Remote (Firestore):',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.grey.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(remoteText),
                ),
                const SizedBox(height: 16),
                Text(
                  'Matches: ${currentLocalText == remoteText}',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: currentLocalText == remoteText
                        ? Colors.green
                        : Colors.red,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            GlassButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              label: 'Close',
              dense: true,
            ),
          ],
        ),
      );
    } catch (e) {
      scaffoldMsg.showSnackBar(
        SnackBar(content: Text('Failed to pull remote value: $e')),
      );
    } finally {
      // Already cleared on the path that reaches the dialog; this catches the
      // early returns and the throw.
      _remoteCompareOpen = false;
    }
  }
}

class _JournalEntryListTile extends StatelessWidget {
  const _JournalEntryListTile({
    super.key,
    required this.entry,
    required this.isSelected,
    required this.titlePreview,
    required this.bodyPreview,
    required this.onTap,
  });

  final JournalEntry entry;
  final bool isSelected;
  final ValueNotifier<String> titlePreview;
  final ValueNotifier<String> bodyPreview;
  final VoidCallback onTap;

  // Counts how many _JournalEntryListTile builds land in the same frame, to
  // check whether the row cache (see _JournalPageState._rowFor) is actually
  // holding — mirrors _TaskRowState's counter in todo_page.dart.
  static var _rowBuildsThisFrame = 0;
  static var _rowBuildFlushScheduled = false;

  static void _noteRowBuild() {
    if (!DevFlags.verboseSync) return;
    _rowBuildsThisFrame++;
    if (_rowBuildFlushScheduled) return;
    _rowBuildFlushScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      debugPrint(
        '[jank] _JournalEntryListTile builds this frame: $_rowBuildsThisFrame',
      );
      _rowBuildsThisFrame = 0;
      _rowBuildFlushScheduled = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    _noteRowBuild();
    final local = entry.entryDate.toLocal();
    final dateLabel = MaterialLocalizations.of(context).formatShortDate(local);
    final timeLabel = formatTime12Hour(local);
    final titleStyle = Theme.of(context).textTheme.titleSmall;
    final previewStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.78),
    );
    final dateStyle = Theme.of(context).textTheme.labelSmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.65),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: VoyagerSpacing.sm,
        vertical: VoyagerSpacing.xxs,
      ),
      child: ListTile(
        dense: true,
        // Outlines the entry currently open in the editor.
        shape: VoyagerListItemSurface.focusShape(context, focused: isSelected),
        visualDensity: const VisualDensity(
          vertical: VoyagerSpacing.compactListVerticalDensity,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: VoyagerSpacing.md,
          vertical: VoyagerSpacing.xs,
        ),
        tileColor: VoyagerListItemSurface.restingColor(context),
        selectedTileColor: VoyagerListItemSurface.selectedColor(context),
        selected: isSelected,
        title: isSelected
            ? ValueListenableBuilder<String>(
                valueListenable: titlePreview,
                builder: (context, title, _) {
                  return Text(
                    title.isEmpty ? 'Untitled' : title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: titleStyle,
                  );
                },
              )
            : Text(
                entry.title.isEmpty ? 'Untitled' : entry.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: titleStyle,
              ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (isSelected)
              ValueListenableBuilder<String>(
                valueListenable: bodyPreview,
                builder: (context, body, _) {
                  final preview = firstSentencePreview(body);
                  if (preview.isEmpty) return const SizedBox.shrink();
                  return VoyagerProseText(
                    preview,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: previewStyle,
                  );
                },
              )
            else ...[
              Builder(
                builder: (context) {
                  final preview = firstSentencePreview(entry.body);
                  if (preview.isEmpty) return const SizedBox.shrink();
                  return VoyagerProseText(
                    preview,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: previewStyle,
                  );
                },
              ),
            ],
            Text('$dateLabel · $timeLabel', style: dateStyle),
          ],
        ),
        onTap: onTap,
      ),
    );
  }
}

/// The entry list's title: which journal is open, how many entries it holds,
/// and the way into Manage.
///
/// The all-journals view used to be a second control beside the picker — an
/// icon for the same scope decision the dropdown was already making. It is the
/// first row of the popover now, so there is one place to answer "what am I
/// looking at?" and one gear beside it for everything else.
class _JournalScopeHeader extends StatelessWidget {
  const _JournalScopeHeader({
    required this.journals,
    required this.entryCounts,
    required this.allEntriesCount,
    required this.selectedJournalId,
    required this.viewAllJournals,
    required this.accent,
    required this.flagColorOf,
    required this.onSelectJournal,
    required this.onSelectAllJournals,
    required this.onManage,
  });

  final List<Journal> journals;
  final Map<String, int> entryCounts;
  final int allEntriesCount;
  final String selectedJournalId;
  final bool viewAllJournals;
  final Color accent;
  final int Function(Journal journal) flagColorOf;
  final ValueChanged<String> onSelectJournal;
  final VoidCallback onSelectAllJournals;
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        // The switcher takes the whole leftover width so the gear stays
        // pinned to the row's right edge; the name itself still sits
        // left at its natural width, whichever scope is selected.
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: ScopeSwitcher<String?>(
              // Null while "All journals" is on: no single journal is being
              // viewed.
              selectedValue: viewAllJournals ? null : selectedJournalId,
              accent: accent,
              onSelected: (value) {
                if (value == null) {
                  onSelectAllJournals();
                } else {
                  onSelectJournal(value);
                }
              },
              items: [
                ScopeSwitcherItem<String?>(
                  value: null,
                  label: 'All journals',
                  count: '$allEntriesCount',
                ),
                for (final journal in journals)
                  ScopeSwitcherItem<String?>(
                    value: journal.id,
                    label: journal.name,
                    count: '${entryCounts[journal.id] ?? 0}',
                    color: Color(flagColorOf(journal)),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        IconButton(
          tooltip: 'Manage journals',
          iconSize: 18,
          visualDensity: VisualDensity.compact,
          onPressed: onManage,
          icon: const Icon(PhosphorIconsRegular.gear),
        ),
      ],
    );
  }
}

class _JournalBarBackdrop extends StatelessWidget {
  const _JournalBarBackdrop({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Material(type: MaterialType.transparency, child: child);
  }
}
