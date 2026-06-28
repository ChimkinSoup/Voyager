import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/dev/journal_debug_logger.dart';
import 'package:voyager/core/constants/journal_constants.dart';
import 'package:voyager/core/icons/voyager_icons.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/pending_text_merge.dart';
import 'package:voyager/core/sync/journal_write_coordinator.dart';
import 'package:voyager/core/sync/pending_flush_registry.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/sync/text_delta_injector.dart';
import 'package:voyager/core/theme/voyager_menu_theme.dart';
import 'package:voyager/core/theme/voyager_spacing.dart';
import 'package:voyager/core/widgets/confirm_dialog.dart';
import 'package:voyager/core/widgets/voyager_popup_menu_item.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/utils/journal_tags.dart';
import 'package:voyager/core/utils/time_format.dart';
import 'package:voyager/core/widgets/tag_highlighted_text_field.dart';
import 'package:voyager/core/widgets/datetime_picker_dialog.dart';
import 'package:voyager/core/widgets/enter_to_submit_scope.dart';
import 'package:voyager/core/widgets/keep_alive_scroll.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/core/widgets/mood_gradient_slider.dart';
import 'package:voyager/core/widgets/resizable_pane_divider.dart';
import 'package:voyager/core/widgets/rounded_dropdown.dart';
import 'package:voyager/core/widgets/voyager_menu_catalog.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/core/widgets/journal_color_flag.dart';
import 'package:voyager/core/widgets/weather_icon.dart';
import 'package:voyager/features/journal/journal_list_actions.dart';
import 'package:voyager/features/shell/shell_page_storage_keys.dart';
import 'package:voyager/features/sync/sync_conflict_banner.dart';

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
  String? _lastViewedJournalId;
  final _optimisticallyHiddenJournalIds = <String>{};
  Journal? _pendingJournal;
  final _pendingEntries = <String, JournalEntry>{};
  final _pendingEntryIds = <String>[];
  final _entryListScrollController = ScrollController();
  String? _selectedEntryId;
  JournalEntry? _selectedEntry;
  final _titleController = TextEditingController();
  final _titleFocusNode = FocusNode();
  final _bodyFocusNode = FocusNode();
  final _editorKey = GlobalKey<_PlainJournalEditorState>();
  final _listTitlePreview = ValueNotifier<String>('');
  final _listBodyPreview = ValueNotifier<String>('');
  final _entryBodyDrafts = <String, String>{};
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
  DateTime? _lastEntryCreatedAt;

  late final Future<void> Function() _lifecycleFlushCallback;

  @override
  void initState() {
    super.initState();
    _invalidateJournalCaches = ref.read(journalEntryCacheInvalidatorProvider);
    _lifecycleFlushCallback = _lifecycleFlush;
    PendingFlushRegistry.instance.register(_lifecycleFlushCallback);
    _titleFocusNode.addListener(_handleTitleFocusChanged);
    _bodyFocusNode.addListener(_handleBodyFocusChanged);
    _restoreFromSettings(ref.read(settingsProvider).valueOrNull);
    WidgetsBinding.instance.addPostFrameCallback((_) => _prefetchInitialJournalEntries());
  }

  Future<void> _lifecycleFlush() async {
    await _flushActiveEntryEdits(refreshList: false);
    await _flushMetadataSave(refreshList: false);
  }

  void _handleBodyFocusChanged() {
    if (!_bodyFocusNode.hasFocus) {
      unawaited(_flushActiveEntryEdits(refreshList: false));
    }
  }

  void _handleTitleFocusChanged() {
    if (!_titleFocusNode.hasFocus && _metadataDirty) {
      unawaited(_flushMetadataSave());
    }
  }

  void _prefetchInitialJournalEntries() {
    if (!mounted) return;
    if (_viewAllJournals) {
      unawaited(ref.read(journalListEntriesProvider(allJournalEntriesScope).future));
      return;
    }
    unawaited(ref.read(journalListEntriesProvider(_journalFilter).future));
  }

  Future<void> _selectJournal(String journalId) async {
    _logJournal('SELECT_JOURNAL', details: 'journalId=$journalId');
    await ref.read(journalListEntriesProvider(journalId).future);
    if (!mounted) return;
    setState(() {
      _journalFilter = journalId;
      _lastViewedJournalId = journalId;
      _viewAllJournals = false;
    });
    unawaited(_persistLastViewedJournal(journalId));
  }

  Future<void> _toggleViewAllJournals(List<Journal> displayJournals) async {
    _logJournal(
      'TOGGLE_VIEW_ALL',
      details: 'currentlyViewAll=$_viewAllJournals',
    );
    if (_viewAllJournals) {
      final journalId = _selectedEntry?.journalId;
      if (journalId != null &&
          displayJournals.any((j) => j.id == journalId)) {
        await ref.read(journalListEntriesProvider(journalId).future);
        if (!mounted) return;
      }
      setState(() {
        if (journalId != null &&
            displayJournals.any((j) => j.id == journalId)) {
          _journalFilter = journalId;
          _lastViewedJournalId = journalId;
        }
        _viewAllJournals = false;
      });
      if (journalId != null &&
          displayJournals.any((j) => j.id == journalId)) {
        unawaited(_persistLastViewedJournal(journalId));
      }
      return;
    }

    await ref.read(journalListEntriesProvider(allJournalEntriesScope).future);
    if (!mounted) return;
    setState(() => _viewAllJournals = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _writeEntryListScrollStorage(0);
      _scrollEntryListToTop();
    });
  }

  void _restoreFromSettings(AppSettings? settings) {
    final savedId = settings?.lastViewedJournalId;
    if (savedId != null) {
      _journalFilter = savedId;
      _lastViewedJournalId = savedId;
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
    final restoredJournalId = savedId != null &&
            journals.any((journal) => journal.id == savedId)
        ? savedId
        : null;
    if (restoredJournalId == null &&
        settings.journalEntryListWidth == null) {
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        if (restoredJournalId != null) {
          _journalFilter = restoredJournalId;
          _lastViewedJournalId = restoredJournalId;
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
    _pinFlushDependencies();
    _titleFocusNode.removeListener(_handleTitleFocusChanged);
    _bodyFocusNode.removeListener(_handleBodyFocusChanged);
    _listTitlePreview.dispose();
    _listBodyPreview.dispose();
    _logJournal('PAGE_DISPOSE', details: 'Flushing active edits before dispose.');
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
      bodyText: _editorKey.currentState?.currentBodyText ??
          (entryId == null ? '' : (_entryBodyDrafts[entryId] ?? _selectedEntry?.body ?? '')),
      metadataDirty: _metadataDirty,
      bodyFocused: _bodyFocusNode.hasFocus,
      titleFocused: _titleFocusNode.hasFocus,
      journalFilter: _journalFilter,
      viewAllJournals: _viewAllJournals,
      bodyDraftEntryIds: _entryBodyDrafts.keys.toList(),
    );
  }

  void _logJournal(
    String event, {
    JournalEntry? entry,
    String? details,
  }) {
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

  String _journalIdForNewEntry(List<Journal> journals) {
    if (journals.any((j) => j.id == _journalFilter)) return _journalFilter;

    if (_lastViewedJournalId != null &&
        journals.any((j) => j.id == _lastViewedJournalId)) {
      return _lastViewedJournalId!;
    }

    final selectedJournalId = _selectedEntry?.journalId;
    if (selectedJournalId != null &&
        journals.any((j) => j.id == selectedJournalId)) {
      return selectedJournalId;
    }

    return journals.first.id;
  }

  Future<void> _persistLastViewedJournal(String journalId) async {
    final settingsRepo = ref.read(settingsRepositoryProvider);
    final settings = await settingsRepo.getSettings();
    if (settings.lastViewedJournalId == journalId) return;
    await settingsRepo.saveSettings(
      settings.copyWith(lastViewedJournalId: journalId),
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
  }

  void _onEntryListDragUpdate(double totalDelta, double totalWidth) {
    final startWidth = _entryListDragStartWidth;
    if (startWidth == null) return;
    setState(
      () => _entryListWidth = JournalEntryListLayout.clampListWidth(
        startWidth + totalDelta,
        totalWidth,
      ),
    );
  }

  void _onEntryListDragEnd() {
    final width = _entryListWidth;
    _entryListDragStartWidth = null;
    unawaited(_persistEntryListWidth(width));
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
    _viewAllJournals = true;
    _journalFilter = remaining
            .cast<Journal?>()
            .firstWhere(
              (j) => j!.id == legacyJournalId,
              orElse: () => remaining.isNotEmpty ? remaining.first : null,
            )
            ?.id ??
        legacyJournalId;
    _selectedEntryId = null;
    _selectedEntry = null;
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
      _lastViewedJournalId = created.id;
      _viewAllJournals = false;
    });
    unawaited(_persistLastViewedJournal(created.id));
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
    PageStorage.of(context).writeState(
      context,
      offset,
      identifier: _entryListStorageKey(),
    );
  }

  List<JournalEntry> _buildDisplayEntries(List<JournalEntry> entries) {
    final persisted = sortJournalEntriesNewestFirst(
      entries.where((entry) => !_pendingEntries.containsKey(entry.id)),
    );
    final pending = [
      for (final id in _pendingEntryIds)
        if (_pendingEntries.containsKey(id)) _pendingEntries[id]!,
    ];
    return [...pending, ...persisted];
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

  int _scopedEntryCount(
    List<JournalEntry> displayEntries,
    String journalId,
  ) {
    return displayEntries.where((entry) => entry.journalId == journalId).length;
  }

  int _entryCountForJournal(
    String journalId, {
    required Map<String, int>? persistedCounts,
    required String entryListScope,
    required List<JournalEntry> displayEntries,
    required bool entriesLoading,
  }) {
    if (entryListScope == journalId) {
      if (entriesLoading) {
        return persistedCounts?[journalId] ?? 0;
      }
      return _scopedEntryCount(displayEntries, journalId);
    }
    if (entryListScope == allJournalEntriesScope) {
      return persistedCounts?[journalId] ??
          displayEntries.where((entry) => entry.journalId == journalId).length;
    }
    return persistedCounts?[journalId] ?? 0;
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

    final settings =
        ref.read(settingsProvider).value ?? const AppSettings();
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
      _bodyFocusNode.requestFocus();
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
    _logJournal(
      'FLUSH_ACTIVE_EDITS',
      details: 'refreshList=$refreshList',
    );
    final entryId = _selectedEntryId;
    final entry = _selectedEntry;
    if (entryId == null || entry == null) return;

    _metadataSaveTimer?.cancel();
    _editorKey.currentState?.cancelPendingPersist();

    var body = _editorKey.currentState?.currentBodyText ??
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
      title: _titleController.text,
      body: body,
      mood: _mood,
      weatherIcon: _weatherIcon,
      refreshList: refreshList,
      bumpVersion: true,
    );

    await remoteSync.flushDocument(
      FirestoreCollections.journalEntries,
      entryId,
    );
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

    final body = _editorKey.currentState?.currentBodyText ??
        _entryBodyDrafts[entryId] ??
        entry.body;

    await _persistEntryEdits(
      entry: entry,
      title: _titleController.text,
      body: body,
      mood: _mood,
      weatherIcon: _weatherIcon,
      refreshList: false,
      bumpVersion: bumpVersion,
    );
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

    final displayEntry = _entryWithDraftBody(entry);
    final draftBody = _entryBodyDrafts[displayEntry.id] ?? displayEntry.body;
    _listTitlePreview.value = displayEntry.title;
    _listBodyPreview.value = draftBody;
    setState(() {
      _selectedEntryId = displayEntry.id;
      _selectedEntry = displayEntry;
      _titleController.text = displayEntry.title;
      _mood = displayEntry.mood;
      _weatherIcon = displayEntry.weatherIcon ?? 'sunny';
      _metadataDirty = false;
      _lastViewedJournalId = displayEntry.journalId;
    });

    unawaited(_persistLastViewedJournal(displayEntry.journalId));
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

  Future<void> _persistEntryEdits({
    required JournalEntry entry,
    required String title,
    required String body,
    required int? mood,
    required String? weatherIcon,
    bool refreshList = false,
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
    _invalidateJournalEntryCaches();
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

  Future<void> _changeEntryDate() async {
    final entry = _selectedEntry;
    if (entry == null) return;

    _metadataSaveTimer?.cancel();
    await _flushMetadataSave();
    if (!mounted) return;

    final nextLocal = await showDateTimePickerDialog(
      context,
      initialDateTime: entry.entryDate.toLocal(),
    );
    if (nextLocal == null) return;
    if (!mounted) return;

    final repo = ref.read(journalRepositoryProvider);
    final existing = await repo.getEntry(entry.id);
    if (existing == null) return;

    final updated = existing.copyWith(entryDate: nextLocal.toUtc());
    await repo.upsertEntry(updated);
    ref.read(remoteSyncServiceProvider).pushJournalEntryNow(updated);
    if (!mounted) return;
    setState(() => _selectedEntry = updated);
    _invalidateJournalEntryCaches();
  }

  String _entryDateTimeLabel(BuildContext context, DateTime dateTime) {
    final local = dateTime.toLocal();
    final materialLocalizations = MaterialLocalizations.of(context);
    final date = materialLocalizations.formatShortDate(local);
    final time = formatTime12Hour(local);
    return '$date $time';
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
    setState(() {
      _selectedEntryId = null;
      _selectedEntry = null;
      _titleController.clear();
    });
    _removePendingEntry(entry.id);
    _invalidateJournalEntryCaches();
  }

  Future<void> _editQuote() async {
    final entry = _selectedEntry;
    if (entry == null) return;
    final controller = TextEditingController(text: entry.customQuote ?? '');
    final quote = await showDialog<String?>(
      context: context,
      builder: (context) => EnterToSubmitScope(
        onSubmit: () => Navigator.pop(context, controller.text),
        child: AlertDialog(
        title: const Text('Edit quote'),
        content: SizedBox(
          width: 720,
          child: LabeledTextField(
            label: 'Quote',
            controller: controller,
            autofocus: true,
            minLines: 8,
            maxLines: 16,
            onSubmitted: (_) =>
                Navigator.pop(context, controller.text),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
      ),
    );
    controller.dispose();
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
    setState(() => _selectedEntry = updated);
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
    final entriesScope =
        _viewAllJournals ? allJournalEntriesScope : entryListScope;
    final entriesAsync =
        ref.watch(journalListEntriesProvider(entriesScope));

    return journalsAsync.when(
        skipLoadingOnReload: true,
        data: (journals) {
          _applySavedPreferencesIfReady(settings, journals);
          if (entriesAsync.hasError && entriesAsync.valueOrNull == null) {
            return Center(child: Text('${entriesAsync.error}'));
          }
          final entries = _resolveScopedEntries(entriesAsync, entriesScope);
          final entriesLoading =
              _resolveEntriesLoading(entriesAsync, entriesScope);
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
          _reconcilePendingJournal(journals);
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
              : displayEntries
                  .where((e) => e.journalId == entryListScope)
                  .toList();
          final selectedId = _selectedEntryId;
          final selected = _selectedEntry;
          if (_viewAllJournals &&
              selectedId != null &&
              selected != null &&
              !filtered.any((entry) => entry.id == selectedId)) {
            filtered = sortJournalEntriesNewestFirst([
              _entryWithDraftBody(selected),
              ...filtered,
            ]);
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
          final shouldSelectLatest = filtered.isNotEmpty &&
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
          final entryCounts = {
            for (final journal in displayJournals)
              journal.id: _entryCountForJournal(
                journal.id,
                persistedCounts: countsByJournal,
                entryListScope: entriesScope,
                displayEntries: displayEntries,
                entriesLoading: entriesLoading,
              ),
          };
          final selectedJournal = displayJournals.cast<Journal?>().firstWhere(
                (j) => j!.id == journalFilter,
                orElse: () => null,
              );

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
              final listWidth = JournalEntryListLayout.clampListWidth(
                storedListWidth,
                totalWidth,
              );
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: listWidth,
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
                                  itemBuilder: (_, i) {
                                    final entry = filtered[i];
                                    final isSelected =
                                        entry.id == _selectedEntryId;
                                    return KeyedSubtree(
                                      key: ValueKey(entry.id),
                                      child: _JournalEntryListTile(
                                        entry: entry,
                                        isSelected: isSelected,
                                        titlePreview: _listTitlePreview,
                                        bodyPreview: _listBodyPreview,
                                        onTap: () => unawaited(_loadEntry(entry)),
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
                                    child: RoundedDropdown<String>(
                                      value: journalFilter,
                                      displayLabel: _viewAllJournals
                                          ? 'All journals'
                                          : null,
                                      labelColor: Color(
                                        _viewAllJournals
                                            ? Theme.of(context)
                                                .colorScheme
                                                .primary
                                                .toARGB32()
                                            : selectedJournal == null
                                                ? Theme.of(context)
                                                    .colorScheme
                                                    .primary
                                                    .toARGB32()
                                                : _journalFlagColor(
                                                    selectedJournal,
                                                  ),
                                      ),
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
                                            journalId,
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
                                          : (v) =>
                                              unawaited(_selectJournal(v)),
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
                                      PhosphorIconsRegular.listMagnifyingGlass,
                                      color: _viewAllJournals
                                          ? Colors.black
                                          : null,
                                    ),
                                    style: IconButton.styleFrom(
                                      backgroundColor: _viewAllJournals
                                          ? Theme.of(context)
                                              .colorScheme
                                              .primary
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
                              child: MouseRegion(
                                cursor: SystemMouseCursors.click,
                                child: FilledButton(
                                  onPressed: _createEntry,
                                  child: const Text('New entry'),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  ResizablePaneDivider(
                    onDragStart: () => _onEntryListDragStart(totalWidth),
                    onDragUpdate: (totalDelta) =>
                        _onEntryListDragUpdate(totalDelta, totalWidth),
                    onDragEnd: _onEntryListDragEnd,
                    onDoubleTapReset: _resetEntryListWidth,
                  ),
                  Expanded(
                    child: Padding(
                      padding: JournalEntryListLayout.editorPadding,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 8, bottom: 12),
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
                                    showLabel: false,
                                    controller: _titleController,
                                    focusNode: _titleFocusNode,
                                    textInputAction: TextInputAction.next,
                                    accentColor: accentColor,
                                    contentPadding: const EdgeInsets.fromLTRB(
                                      16,
                                      16,
                                      56,
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
                          if (_selectedEntryId != null) ...[
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
                                Flexible(
                                  child: OutlinedButton.icon(
                                    onPressed: _changeEntryDate,
                                    icon: Icon(
                                      VoyagerIcons.calendar,
                                      size: 18,
                                      color: accentColor,
                                    ),
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: accentColor,
                                      side: BorderSide(
                                        color: accentColor.withValues(
                                          alpha: 0.7,
                                        ),
                                      ),
                                    ),
                                    label: Text(
                                      _entryDateTimeLabel(
                                        context,
                                        _selectedEntry!.entryDate,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                      maxLines: 1,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                IconButton(
                                  tooltip: 'Delete entry',
                                  onPressed: _deleteEntry,
                                  icon: const Icon(PhosphorIconsRegular.trash),
                                  visualDensity: VisualDensity.compact,
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                          ],
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
  var _applyingListShortcut = false;
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
    _lastText = _controller.text;
    _tags = widget.entry?.tags ?? extractTags(_controller.text);
    final entry = widget.entry;
    if (entry != null) {
      final remoteSync = ref.read(remoteSyncServiceProvider);
      _remoteSync = remoteSync;
      remoteSync.charOpRegistry.ensureSession(
        collection: FirestoreCollections.journalEntries,
        documentId: entry.id,
        clientId: remoteSync.deviceId,
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
    _tags = event.remoteTags.isNotEmpty ? event.remoteTags : extractTags(merged);
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
      remoteSync.charOpRegistry.ensureSession(
        collection: FirestoreCollections.journalEntries,
        documentId: entry.id,
        clientId: remoteSync.deviceId,
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
    if (!_applyingListShortcut) {
      _applyListContinuation();
    }

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

  void _applyListContinuation() {
    final text = _controller.text;
    final selection = _controller.selection;
    if (!selection.isCollapsed || selection.baseOffset <= 0) return;
    if (text.length != _lastText.length + 1) return;

    final newlineOffset = selection.baseOffset - 1;
    if (newlineOffset < 0 ||
        newlineOffset >= text.length ||
        text[newlineOffset] != '\n') {
      return;
    }

    final previousLineStart = text.lastIndexOf('\n', newlineOffset - 1) + 1;
    final previousLine = text.substring(previousLineStart, newlineOffset);
    final bulletMatch = RegExp(r'^(\s*)-\s+(.*)$').firstMatch(previousLine);
    final numberMatch = RegExp(
      r'^(\s*)(\d+)\.\s+(.*)$',
    ).firstMatch(previousLine);
    if (bulletMatch == null && numberMatch == null) return;

    final indent = bulletMatch?.group(1) ?? numberMatch?.group(1) ?? '';
    final content = bulletMatch?.group(2) ?? numberMatch?.group(3) ?? '';
    final nextNumber = (int.tryParse(numberMatch?.group(2) ?? '') ?? 0) + 1;
    final insert = content.isEmpty
        ? ''
        : bulletMatch != null
        ? '$indent- '
        : '$indent$nextNumber. ';
    final replacementStart = content.isEmpty
        ? previousLineStart
        : selection.baseOffset;
    final replacementEnd = selection.baseOffset;
    final nextText = text.replaceRange(
      replacementStart,
      replacementEnd,
      insert,
    );
    final nextOffset = replacementStart + insert.length;

    _applyingListShortcut = true;
    _controller.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: nextOffset),
    );
    _applyingListShortcut = false;
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
        expands: true,
        keyboardType: TextInputType.multiline,
        cursorColor: widget.accentColor,
        onChanged: _handleChanged,
        hintText: 'Start writing...',
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

class _JournalEntryListTile extends StatelessWidget {
  const _JournalEntryListTile({
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

  @override
  Widget build(BuildContext context) {
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
        visualDensity: const VisualDensity(
          vertical: VoyagerSpacing.compactListVerticalDensity,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: VoyagerSpacing.md,
          vertical: VoyagerSpacing.xs,
        ),
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

/// Semi-transparent frosted bar over the geometric texture background.
class _JournalBarBackdrop extends StatelessWidget {
  const _JournalBarBackdrop({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).scaffoldBackgroundColor.withValues(
      alpha: 0.8,
    );

    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 4, sigmaY: 4),
        child: Material(color: color, child: child),
      ),
    );
  }
}

