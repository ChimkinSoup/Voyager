import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';
import 'package:intl/intl.dart';
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
import 'package:voyager/core/widgets/enter_to_submit_scope.dart';
import 'package:voyager/core/widgets/keep_alive_scroll.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/core/widgets/mood_gradient_slider.dart';
import 'package:voyager/core/widgets/resizable_pane_divider.dart';
import 'package:voyager/core/widgets/rounded_dropdown.dart';
import 'package:voyager/core/widgets/selector_pill.dart';
import 'package:voyager/core/widgets/voyager_menu_catalog.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/core/widgets/journal_color_flag.dart';
import 'package:voyager/core/widgets/weather_icon.dart';
import 'package:voyager/features/journal/journal_entry_actions.dart';
import 'package:voyager/features/journal/journal_list_actions.dart';
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
  final _optimisticallyHiddenJournalIds = <String>{};
  final _optimisticallyHiddenEntryIds = <String>{};
  Journal? _pendingJournal;
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

  Future<void> _toggleViewAllJournals(List<Journal> displayJournals) async {
    _logJournal(
      'TOGGLE_VIEW_ALL',
      details: 'currentlyViewAll=$_viewAllJournals',
    );
    if (_viewAllJournals) {
      final journalId = _selectedEntry?.journalId;
      if (journalId != null && displayJournals.any((j) => j.id == journalId)) {
        await ref.read(journalListEntriesProvider(journalId).future);
        if (!mounted) return;
      }
      setState(() {
        if (journalId != null &&
            displayJournals.any((j) => j.id == journalId)) {
          _journalFilter = journalId;
        }
        _viewAllJournals = false;
      });
      unawaited(_persistShowAllJournals(false));
      if (journalId != null && displayJournals.any((j) => j.id == journalId)) {
        unawaited(_persistLastViewedJournal(journalId));
      }
      return;
    }

    await ref.read(journalListEntriesProvider(allJournalEntriesScope).future);
    if (!mounted) return;
    setState(() {
      _optimisticallyHiddenEntryIds.clear();
      _viewAllJournals = true;
    });
    // Only the view flag is written here: _journalFilter deliberately stays on
    // the journal that was open, and it is what new entries created from this
    // view are filed under.
    unawaited(_persistShowAllJournals(true));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _writeEntryListScrollStorage(0);
      _scrollEntryListToTop();
    });
  }

  void _restoreFromSettings(AppSettings? settings) {
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

    final savedId = settings.lastViewedJournalId;
    final isAll = settings.journalShowAllEntries;
    final restoredJournalId =
        savedId != null && journals.any((journal) => journal.id == savedId)
        ? savedId
        : null;

    if (!isAll &&
        restoredJournalId == null &&
        settings.journalEntryListWidth == null) {
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        // Both, not one or the other: reopening into the all-view still needs
        // the concrete journal, since that is where new entries are filed.
        if (isAll) {
          _viewAllJournals = true;
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
      bodyText:
          _editorKey.currentState?.currentBodyText ??
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
    // Soft-bounded while the drag is live — tracks the pointer 1:1 but
    // resists past the real bounds instead of stopping dead.
    setState(
      () => _entryListWidth = JournalEntryListLayout.dragClampListWidth(
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

  void _applyJournalDeletedUiState(
    String journalId,
    List<Journal> allJournals,
  ) {
    _optimisticallyHiddenJournalIds.add(journalId);
    if (_pendingJournal?.id == journalId) {
      _pendingJournal = null;
    }
    _pendingEntries.removeWhere((_, entry) => entry.journalId == journalId);
    _pendingEntryIds.removeWhere((id) => !_pendingEntries.containsKey(id));
    final remaining = allJournals.where((j) => j.id != journalId).toList();
    // Falls back to a concrete journal and leaves the all-view alone, matching
    // the todo page's list deletion. Switching the view mode out from under a
    // delete is a second, unasked-for change of context.
    _journalFilter =
        remaining
            .cast<Journal?>()
            .firstWhere(
              (j) => j!.id == legacyJournalId,
              orElse: () => remaining.isNotEmpty ? remaining.first : null,
            )
            ?.id ??
        legacyJournalId;
    unawaited(_persistLastViewedJournal(_journalFilter));
    _clearEntryFields();
  }

  void _revertJournalDeletedUiState(String journalId) {
    _optimisticallyHiddenJournalIds.remove(journalId);
  }

  Future<void> _createJournalFromDropdown() async {
    final created = await createJournalList(context, ref);
    if (!mounted || created == null) return;
    await ref.read(journalsProvider.future);
    if (!mounted) return;
    setState(() {
      _journalFilter = created.id;
      _viewAllJournals = false;
    });
    unawaited(_persistLastViewedJournal(created.id));
    unawaited(_persistShowAllJournals(false));
  }

  Future<void> _handleJournalManage(
    String journalId,
    VoyagerMenuCatalogEntry action,
    List<Journal> allJournals,
    Map<String, int> entryCounts,
  ) async {
    final journal = allJournals.firstWhere((j) => j.id == journalId);
    switch (action) {
      case VoyagerMenuCatalogEntry.rename:
        await renameJournalList(context, ref, journal);
        await _refreshPendingJournal(journalId);
      case VoyagerMenuCatalogEntry.changeColor:
        await changeJournalListColor(context, ref, journal, allJournals);
        await _refreshPendingJournal(journalId);
      case VoyagerMenuCatalogEntry.delete:
        final deleted = await deleteJournalList(
          context,
          ref,
          journal: journal,
          allJournals: allJournals,
          entryCount: entryCounts[journalId] ?? 0,
          onConfirmed: () {
            if (!mounted) return;
            setState(() => _applyJournalDeletedUiState(journalId, allJournals));
          },
          onLocalDeleteFailed: () {
            if (!mounted) return;
            setState(() => _revertJournalDeletedUiState(journalId));
          },
        );
        if (deleted && mounted) {
          _optimisticallyHiddenJournalIds.remove(journalId);
        }
      default:
        break;
    }
  }

  Future<void> _refreshPendingJournal(String journalId) async {
    if (!mounted) return;
    final journals = await ref.read(journalsProvider.future);
    if (!mounted) return;
    final updated = journals.cast<Journal?>().firstWhere(
      (j) => j!.id == journalId,
      orElse: () => null,
    );
    if (updated == null) return;
    setState(() => _pendingJournal = updated);
  }

  List<Journal> _displayJournals(List<Journal> journals) {
    final active = journals
        .where(
          (journal) =>
              journal.deletedAt == null &&
              !_optimisticallyHiddenJournalIds.contains(journal.id),
        )
        .toList();
    final pending = _pendingJournal;
    if (pending == null || pending.deletedAt != null) return active;
    if (!active.any((journal) => journal.id == pending.id)) {
      return [...active, pending];
    }
    return [
      for (final journal in active)
        journal.id == pending.id ? pending : journal,
    ];
  }

  void _reconcilePendingJournal(List<Journal> journals) {
    final pending = _pendingJournal;
    if (pending == null) return;
    if (!journals.any((journal) => journal.id == pending.id)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _pendingJournal = null);
    });
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
          !_optimisticallyHiddenEntryIds.contains(entry.id) &&
          !_optimisticallyHiddenJournalIds.contains(entry.journalId),
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
    required bool entriesLoading,
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

    final entry = JournalEntry(
      id: newId(),
      journalId: journalId,
      title: '',
      body: '',
      entryDate: now,
      timestamp: now,
      weatherIcon: weather?.icon,
      createdAt: now,
      updatedAt: now,
    );

    _registerPendingEntry(entry);
    _suppressAutoSelect = true;
    _logJournal('CREATE_ENTRY', entry: entry);
    _writeEntryListScrollStorage(0);
    unawaited(_loadEntry(entry));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _writeEntryListScrollStorage(0);
      _scrollEntryListToTop();
      _titleFocusNode.requestFocus();
    });

    unawaited(_finalizeNewEntry(entry, settings));
  }

  Future<void> _finalizeNewEntry(
    JournalEntry entry,
    AppSettings settings,
  ) async {
    final journalRepo = ref.read(journalRepositoryProvider);
    final remoteSync = ref.read(remoteSyncServiceProvider);
    final weatherService = ref.read(weatherServiceProvider);

    Quote? assignedQuote;
    if (settings.showQuotes) {
      await ref.read(quotesLoadedProvider.future);
      if (!mounted) return;
      assignedQuote = ref.read(quoteBankProvider).nextQuote();
    }

    final weather =
        await weatherService.refreshIfNeeded() ??
        weatherService.readCachedSnapshot(settings);
    if (!mounted) return;

    final finalized = entry.copyWith(
      quoteId: assignedQuote?.id,
      customQuote: assignedQuote?.text,
      weatherIcon: weather?.icon ?? entry.weatherIcon,
    );

    await journalRepo.upsertEntry(finalized);
    remoteSync.pushJournalEntryNow(finalized);
    if (!mounted) return;

    _invalidateJournalEntryCaches();

    if (_pendingEntries.containsKey(finalized.id)) {
      _pendingEntries[finalized.id] = finalized;
    }
    if (_selectedEntryId == finalized.id) {
      setState(() => _selectedEntry = finalized);
    }
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
          _weatherIcon = fresh.weatherIcon ?? 'sunny';
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

  Future<void> _flushActiveEntryEdits({required bool refreshList}) async {
    if (_flushInProgress != null) {
      await _flushInProgress;
      return;
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
    _editorKey.currentState?.cancelPendingPersist();

    final title = _titleController.text;
    final mood = _mood;
    final weatherIcon = _weatherIcon;

    var body =
        _editorKey.currentState?.currentBodyText ??
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

    await remoteSync.flushDocument(
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
        _editorKey.currentState?.currentBodyText ??
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
    _weatherIcon = displayEntry.weatherIcon ?? 'sunny';
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
          if (_selectedEntryId == entry.id) {
            _listTitlePreview.value = updated.title;
            _listBodyPreview.value = updated.body;
            if (mounted) {
              setState(() {
                _selectedEntry = updated;
                _metadataDirty = false;
              });
            }
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

  Future<void> _saveMetadataForEntry({
    required String entryId,
    required JournalEntry entry,
    required String title,
    required int? mood,
    required String? weatherIcon,
    bool refreshList = false,
  }) async {
    final repo = _journalRepoOrNull();
    final remoteSync = _syncServiceOrNull();
    if (repo == null || remoteSync == null) return;

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

    final updated = baseline.copyWith(
      title: title,
      mood: mood,
      weatherIcon: weatherIcon,
    );

    await remoteSync.saveJournalEntryThenScheduleUpload(
      entryId: entryId,
      saveLocal: () async {
        await repo.upsertEntry(updated);
        _logJournal(
          'METADATA_PERSIST_SAVED',
          entry: updated,
          details: 'v=${updated.version}',
        );
        if (_selectedEntryId == entryId) {
          _listTitlePreview.value = updated.title;
          if (mounted) {
            setState(() {
              _selectedEntry = updated;
              _metadataDirty = false;
            });
          }
        }
      },
    );
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

  void _submitTitleAndFocusBody() {
    _metadataDirty = true;
    unawaited(_flushMetadataSave());
    _bodyFocusNode.requestFocus();
  }

  Future<void> _changeEntryDateAndTime(BuildContext buttonContext) async {
    final entry = _selectedEntry;
    if (entry == null) return;

    _metadataSaveTimer?.cancel();
    await _flushMetadataSave();
    if (!mounted) return;

    final repo = ref.read(journalRepositoryProvider);
    final journal = await repo.getJournal(entry.journalId);
    final accentColor = Color(
      journal != null
          ? _journalFlagColor(journal)
          : Theme.of(context).colorScheme.primary.toARGB32(),
    );

    setState(() => _isDatePickerOpen = true);
    final pickedDt = await showContextualPopover<DateTime>(
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
    if (mounted) setState(() => _isDatePickerOpen = false);
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

  void _jumpToTarget(double target) {
    if (!mounted || !_entryListScrollController.hasClients) return;
    final pos = _entryListScrollController.position;

    if (target > pos.maxScrollExtent && pos.maxScrollExtent > 0) {
      // Force layout by jumping to current max extent, then repeat next frame
      pos.jumpTo(pos.maxScrollExtent);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _jumpToTarget(target);
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

  Future<void> _deleteEntry() async {
    final entry = _selectedEntry;
    if (entry == null) return;
    final confirmed = await showConfirmDialog(
      context,
      title: 'Delete entry?',
      message: 'This entry will be moved to trash.',
    );
    if (!confirmed || !mounted) return;
    _logJournal('DELETE_ENTRY', details: 'id=${entry.id}');
    await _flushActiveEntryEdits(refreshList: false);
    if (!mounted) return;
    await ref.read(journalRepositoryProvider).softDeleteEntry(entry.id);
    ref
        .read(remoteSyncServiceProvider)
        .pushJournalEntryNow(entry.copyWith(deletedAt: utcNow()));
    final emptied = _selectReplacementForRemovedEntry(entry);
    _removePendingEntry(entry.id);
    _invalidateJournalEntryCaches();
    if (emptied) _replaceEmptiedJournalEntry(entry);
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
    await ref.read(journalRepositoryProvider).softDeleteEntry(entry.id);
    ref
        .read(remoteSyncServiceProvider)
        .pushJournalEntryNow(entry.copyWith(deletedAt: utcNow()));
    var emptied = false;
    if (wasSelected) {
      emptied = _selectReplacementForRemovedEntry(entry);
    } else {
      setState(() => _optimisticallyHiddenEntryIds.add(entry.id));
    }
    _removePendingEntry(entry.id);
    _invalidateJournalEntryCaches();
    if (emptied) _replaceEmptiedJournalEntry(entry);
  }

  Future<void> _moveEntryItemToJournal(
    JournalEntry entry,
    String journalId,
  ) async {
    if (entry.journalId == journalId) return;
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
    final updated = entry.copyWith(customQuote: quote.trim());
    await ref.read(journalRepositoryProvider).upsertEntry(updated);
    ref.read(remoteSyncServiceProvider).pushJournalEntryNow(updated);
    if (!mounted) return;
    setState(() => _selectedEntry = updated);
    _invalidateJournalEntryCaches();
  }

  Future<void> _moveEntryToJournal(String journalId) async {
    final entry = _selectedEntry;
    if (entry == null || entry.journalId == journalId) return;
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

    ref.listen(journalListEntriesProvider(entriesScope), (previous, next) {
      final entries = next.valueOrNull;
      if (entries != null && _selectedEntryId != null) {
        final updated = entries
            .where((e) => e.id == _selectedEntryId)
            .firstOrNull;
        if (updated != null && _selectedEntry != null) {
          if (updated.updatedAt.isAfter(_selectedEntry!.updatedAt) ||
              updated.version > _selectedEntry!.version) {
            if (mounted) {
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
              _editorKey.currentState?.setBodyText(updated.body);
            }
          }
        }
      }
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
    _reconcilePendingJournal(journals);
    _reconcilePendingEntries(allEntryIdsAsync.valueOrNull ?? const {});
    final displayEntries = _buildDisplayEntries(entries);
    _reconcileSelectedEntryFromProvider(entries);
    final displayJournals = _displayJournals(journals);
    final journalFilter = displayJournals.any((j) => j.id == _journalFilter)
        ? _journalFilter
        : displayJournals.isNotEmpty
        ? displayJournals.first.id
        : legacyJournalId;
    if (journalFilter != _journalFilter) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() => _journalFilter = journalFilter);
      });
    }
    var filtered = _viewAllJournals
        ? List<JournalEntry>.from(displayEntries)
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
          entriesLoading: entriesLoading,
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
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: RoundedDropdown<String?>(
                                        value: _viewAllJournals
                                            ? null
                                            : journalFilter,
                                        displayLabel: _viewAllJournals
                                            ? 'All journals'
                                            : null,
                                        labelColor: journalBarColor,
                                        closedTrailing: _viewAllJournals
                                            ? '${filtered.length}'
                                            : '${entryCounts[journalFilter] ?? 0}',
                                        onAddList: () => unawaited(
                                          _createJournalFromDropdown(),
                                        ),
                                        addListLabel: 'Add journal',
                                        manageMenuEntriesFor: (journalId) =>
                                            journalId == legacyJournalId
                                            ? defaultEntityManageMenuEntries
                                            : entityManageMenuEntries,
                                        onManage: (journalId, action) =>
                                            _handleJournalManage(
                                              journalId!,
                                              action,
                                              displayJournals,
                                              entryCounts,
                                            ),
                                        items: displayJournals
                                            .map(
                                              (j) => RoundedDropdownItem(
                                                value: j.id,
                                                label: j.name,
                                                labelColor: Color(
                                                  _journalFlagColor(j),
                                                ),
                                                trailing:
                                                    '${entryCounts[j.id] ?? 0}',
                                              ),
                                            )
                                            .toList(),
                                        onChanged: displayJournals.isEmpty
                                            ? null
                                            : (v) {
                                                if (v != null)
                                                  unawaited(_selectJournal(v));
                                              },
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    IconButton(
                                      tooltip: _viewAllJournals
                                          ? 'Show selected journal only'
                                          : 'Show all journals',
                                      onPressed: displayJournals.isEmpty
                                          ? null
                                          : () => unawaited(
                                              _toggleViewAllJournals(
                                                displayJournals,
                                              ),
                                            ),
                                      icon: Icon(
                                        PhosphorIconsRegular
                                            .listMagnifyingGlass,
                                        color: _viewAllJournals
                                            ? Theme.of(
                                                context,
                                              ).colorScheme.primary
                                            : null,
                                      ),
                                    ),
                                  ],
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
                            Row(
                              children: [
                                Text(
                                  'Mood',
                                  style: TextStyle(color: accentColor),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: MoodGradientSlider(
                                    value: _mood ?? 5,
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
                                const SizedBox(width: 12),
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
                                  itemBuilder: (context) => buildCatalogMenu(
                                    context,
                                    from: weatherMenuEntries,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Builder(
                                  builder: (ctx) {
                                    // Now, with nothing selected: the date a
                                    // new entry would be filed under.
                                    final date =
                                        _selectedEntry?.entryDate.toLocal() ??
                                        DateTime.now();
                                    final label =
                                        '${DateFormat.yMMMd().format(date)} at ${formatTime12Hour(date)}';
                                    return SelectorPill(
                                      dense: false,
                                      ellipsize: false,
                                      isActive: _isDatePickerOpen,
                                      label: label,
                                      accentColor: accentColor,
                                      onTap: () => _changeEntryDateAndTime(ctx),
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
                                    onPressed: () => _pullAndCompareRemoteValue(
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
                                    color: Theme.of(context).colorScheme.error,
                                  ),
                                ),
                              ],
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
                            if (settings?.showQuotes == true &&
                                _selectedEntry != null)
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
                loading: () =>
                    const Center(child: CircularProgressIndicator()),
                error: (error, _) => Center(
                  child: Text('Could not load quotes: $error'),
                ),
                data: (pool) {
                  final matches = needle.isEmpty
                      ? pool
                      : pool
                            .where(
                              (q) => q.text.toLowerCase().contains(needle),
                            )
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
    return PopScope<String?>(
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
              child: Text(
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

  bool get hasFocus => widget.focusNode.hasFocus;

  void setBodyText(String body) {
    _controller.text = body;
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
    }
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
    final pendingFlush = widget.waitForFlush?.call();
    if (pendingFlush != null) {
      await pendingFlush;
    }

    if (!mounted) return;
    final remoteSync = _remoteSync;
    if (oldWidget.entry != null &&
        remoteSync != null &&
        _pendingTextMergeListener != null) {
      remoteSync.removePendingTextMergeListener(
        collection: FirestoreCollections.journalEntries,
        documentId: oldWidget.entry!.id,
        listener: _pendingTextMergeListener!,
      );
    }
    _setEditingFlag(oldWidget.entry, false);
    _tagTimer?.cancel();
    _controller.text = widget.entry?.body ?? '';
    _lastText = _controller.text;
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
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _tagTimer?.cancel();
    final entry = widget.entry;
    final remoteSync = _remoteSync;
    if (entry != null && remoteSync != null) {
      if (_pendingTextMergeListener != null) {
        remoteSync.removePendingTextMergeListener(
          collection: FirestoreCollections.journalEntries,
          documentId: entry.id,
          listener: _pendingTextMergeListener!,
        );
      }
      remoteSync.setDocumentEditing(
        collection: FirestoreCollections.journalEntries,
        documentId: entry.id,
        isEditing: false,
      );
    }
    widget.focusNode.removeListener(_handleFocusChanged);
    _controller.dispose();
    super.dispose();
  }

  void _handleFocusChanged() {
    if (!mounted) return;
    _setEditingFlag(widget.entry, widget.focusNode.hasFocus);
  }

  void cancelPendingPersist() {}

  String get currentBodyText => _controller.text;

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
    final entryId = widget.entry?.id;
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

    return Listener(
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
        // are set apart rather than symmetrically: the top carries the breathing
        // room the first line needs below the border, while the bottom stays
        // small so the strip under a scrolled body remains imperceptible.
        // Horizontal padding is unaffected since it isn't part of the
        // scrollable axis.
        contentPadding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
        decoration: const InputDecoration(
          filled: false,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
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

extension on _JournalPageState {
  Future<void> _pullAndCompareRemoteValue(JournalEntry entry) async {
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
          _editorKey.currentState?.currentBodyText ?? entry.body;

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
                  return Text(
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
                  return Text(
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

class _JournalBarBackdrop extends StatelessWidget {
  const _JournalBarBackdrop({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Material(type: MaterialType.transparency, child: child);
  }
}
