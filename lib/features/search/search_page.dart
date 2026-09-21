import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/text/list_text_editing.dart';
import 'package:voyager/core/vim/vim_enabled_scope.dart';
import 'package:voyager/core/text/prose_text_span.dart';
import 'package:voyager/core/icons/voyager_icons.dart';
import 'package:voyager/core/media/widgets/media_drop_target.dart';
import 'package:voyager/core/media/widgets/media_fan_stack.dart';
import 'package:voyager/core/media/widgets/media_paste_scope.dart';
import 'package:voyager/core/widgets/confirm_dialog.dart';
import 'package:voyager/core/widgets/context_menu.dart';
import 'package:voyager/features/journal/journal_entry_actions.dart';
import 'package:voyager/core/theme/voyager_menu_theme.dart';
import 'package:voyager/core/utils/journal_tags.dart';
import 'package:voyager/core/utils/time_format.dart';
import 'package:intl/intl.dart';
import 'package:voyager/core/widgets/contextual_popover.dart';
import 'package:voyager/core/widgets/ctrl_enter_to_submit_scope.dart';
import 'package:voyager/core/widgets/date_selector_popover.dart';
import 'package:voyager/core/widgets/datetime_selector_popover.dart';
import 'package:voyager/core/widgets/time_selector_popovers.dart';
import 'package:voyager/core/widgets/datetime_picker_dialog.dart';
import 'package:voyager/core/widgets/journal_color_flag.dart';
import 'package:voyager/core/widgets/selector_pill.dart';
import 'package:voyager/core/widgets/enter_to_submit_scope.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/keep_alive_scroll.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/core/widgets/mood_gradient_slider.dart';
import 'package:voyager/core/widgets/search_highlight_text.dart';
import 'package:voyager/core/widgets/tag_highlighted_text_field.dart';
import 'package:voyager/core/widgets/voyager_dialog.dart';
import 'package:voyager/core/widgets/voyager_menu_catalog.dart';
import 'package:voyager/core/widgets/voyager_popup_menu_item.dart';
import 'package:voyager/core/widgets/weather_icon.dart';
import 'package:voyager/domain/models/dream_models.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/features/dream_journal/dream_journal_page.dart';
import 'package:voyager/features/dream_journal/dream_sticky_note.dart';
import 'package:voyager/features/journal/journal_entry_delete.dart';
import 'package:voyager/features/search/dream_search.dart';
import 'package:voyager/features/search/search_dream_save_helper.dart';
import 'package:voyager/core/soft_delete/soft_delete_toast.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/sync/journal_write_coordinator.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/features/search/search_entry_save_helper.dart';
import 'package:voyager/features/shell/shell_page_storage_keys.dart';
import 'package:voyager/core/sync/pending_flush_registry.dart';
import 'package:voyager/core/tags/tag_suggestions.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';

class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final _queryController = TextEditingController();
  final _queryFocusNode = FocusNode();
  final _resultsController = ScrollController();

  final Map<String, JournalEntry> _localUpdates = {};

  /// Entries deleted from the search results this session, hidden immediately
  /// so the list doesn't wait for the provider to refresh.
  final Set<String> _deletedIds = {};

  /// Bumped by every mutation of [_localUpdates] or [_deletedIds], so the
  /// folded-text cache can tell a merged list apart from the previous one
  /// without comparing its contents.
  int _localRevision = 0;

  /// The query the results are actually computed from. Trails the controller
  /// by [_queryDebounceDelay] so a burst of keystrokes costs one pass over the
  /// corpus rather than one per character.
  String _activeQuery = '';
  Timer? _queryDebounce;
  static const _queryDebounceDelay = Duration(milliseconds: 150);

  /// `entry.id -> lowercased "title body"`, rebuilt only when the merged list
  /// changes. Folding per keystroke allocated a full-body concat and a
  /// full-body lowercase for every entry in the database — the dominant cost
  /// of typing in this field, all of it on the UI isolate.
  final Map<String, String> _haystack = {};
  List<JournalEntry>? _haystackEntries;
  int _haystackRevision = -1;

  /// Whether the query field is searching dreams rather than journal entries.
  /// Entered by typing [dreamSearchCommand], left through the scope chip, Esc,
  /// or Backspace on an empty query.
  bool _dreamScope = false;

  /// [_localUpdates] and [_deletedIds] for the dream scope, pruned the same
  /// way by [_mergeAndPruneDreams]. Its own list needs its own ScrollPosition
  /// too: the two result sets are unrelated, so an offset from one must not
  /// carry into the other.
  final Map<String, DreamEntry> _dreamUpdates = {};
  final Set<String> _deletedDreamIds = {};
  final _dreamResultsController = ScrollController();

  /// Whether a Vim session owns the query field, and with it Escape.
  ///
  /// Read here rather than in [_handleQueryKey]: `VimEnabledScope.of`
  /// registers an inherited dependency, and that callback runs from a key
  /// dispatch rather than a build — the same reason the Todo page reads
  /// [TickerMode] through its notifier.
  bool _vimOwnsEscape = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _vimOwnsEscape = VimEnabledScope.of(context);
  }

  @override
  void dispose() {
    _queryDebounce?.cancel();
    _queryController.dispose();
    _queryFocusNode.dispose();
    _resultsController.dispose();
    _dreamResultsController.dispose();
    super.dispose();
  }

  /// Switches the field to dreams, carrying whatever followed the command over
  /// as the query — the same handoff the Todo composer's `/search` performs.
  ///
  /// Applied immediately rather than through [_queryDebounce]: the command
  /// text leaving the field is the user's confirmation that it was recognised,
  /// and a debounced apply would leave `/dream` on screen for a frame first.
  void _enterDreamScope(String query) {
    _queryDebounce?.cancel();
    _queryController.value = TextEditingValue(
      text: query,
      selection: TextSelection.collapsed(offset: query.length),
    );
    setState(() {
      _dreamScope = true;
      _activeQuery = query;
    });
    if (_resultsController.hasClients) _resultsController.jumpTo(0);
  }

  void _exitDreamScope() {
    _queryDebounce?.cancel();
    _queryController.clear();
    setState(() {
      _dreamScope = false;
      _activeQuery = '';
    });
    if (_dreamResultsController.hasClients) _dreamResultsController.jumpTo(0);
    _queryFocusNode.requestFocus();
  }

  /// Escape and a Backspace on an empty query both leave the dream scope —
  /// the chip is the only thing left to delete at that point, so Backspace
  /// deleting it is what the field already looks like it would do.
  ///
  /// Escape is given up entirely while Vim is on. This callback is installed
  /// through `TagHighlightedTextField.onKeyEvent`, which lands in the focus
  /// node's slot — and [VimTextScope] deliberately sits *above* the field so
  /// that slot stays free, so claiming Escape here takes it before Vim ever
  /// sees it. That breaks the invariant Vim is written around: Escape leaves
  /// Insert and never leaves the field. Backspace is still taken, because the
  /// query is empty by then and Normal mode's `h` has nothing to move over;
  /// it and the chip's own button are the exits a Vim user is left with.
  KeyEventResult _handleQueryKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || !_dreamScope) return KeyEventResult.ignored;
    if ((event.logicalKey == LogicalKeyboardKey.escape && !_vimOwnsEscape) ||
        (event.logicalKey == LogicalKeyboardKey.backspace &&
            _queryController.text.isEmpty)) {
      _exitDreamScope();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _onQueryChanged(String value) {
    if (!_dreamScope) {
      final handoff = dreamSearchCommandQuery(value);
      if (handoff != null) {
        _enterDreamScope(handoff);
        return;
      }
    }
    _queryDebounce?.cancel();
    _queryDebounce = Timer(_queryDebounceDelay, () {
      if (!mounted) return;
      setState(() => _activeQuery = _queryController.text);
      // One ScrollPosition is shared across every result set (the list is kept
      // alive under a constant PageStorageKey), so without this a deep offset
      // from a narrow result set survives into the next one — clearing the
      // query lands the user somewhere arbitrary in the full list instead of
      // at the best matches.
      final results = _dreamScope
          ? _dreamResultsController
          : _resultsController;
      if (results.hasClients) results.jumpTo(0);
    });
  }

  /// The app-scoped invalidator, so every journal entry provider is refreshed
  /// rather than the three this page used to name. `allJournalEntriesProvider`
  /// and `journalAllEntryIdsProvider` were missing, and both are keepAlive:
  /// `tagPoolProvider` folds over the former, so a `#tag` created here never
  /// entered the completion pool — including in this page's own query field —
  /// and the analytics page kept showing entries deleted from Search.
  void _invalidateEntryCaches() =>
      ref.read(journalEntryCacheInvalidatorProvider)();

  /// Drops the optimistic state the provider data has caught up with, then
  /// applies what's left.
  ///
  /// Neither collection used to be pruned and this page never unmounts — it is
  /// a shell branch root — so `_localUpdates` retained a full body per entry
  /// edited all session, and `_deletedIds` was a permanent hide-list: a delete
  /// undone by a pull or a trash restore stayed invisible in Search until the
  /// app restarted.
  List<JournalEntry> _mergeAndPrune(List<JournalEntry> entries) {
    final entryIndex = {for (final e in entries) e.id: e};
    final before = _localUpdates.length + _deletedIds.length;
    _localUpdates.removeWhere((id, local) {
      final live = entryIndex[id];
      return live == null ||
          live.version > local.version ||
          (live.version == local.version &&
              !live.updatedAt.isBefore(local.updatedAt));
    });
    // Retires the optimistic hide once the delete has actually landed — i.e.
    // once the provider itself stops returning the id.
    _deletedIds.removeWhere((id) => !entryIndex.containsKey(id));
    if (_localUpdates.length + _deletedIds.length != before) _localRevision++;

    // Every survivor of the prune is strictly newer than the row beside it, so
    // the merge is just a lookup.
    return [
      for (final e in entries)
        if (!_deletedIds.contains(e.id)) _localUpdates[e.id] ?? e,
    ];
  }

  /// [_mergeAndPrune] for the dream scope.
  ///
  /// No revision counter beside it: nothing here is cached against the merged
  /// list, so a change only has to reach the next build — which the setState
  /// that mutated either collection already does.
  List<DreamEntry> _mergeAndPruneDreams(List<DreamEntry> entries) {
    final entryIndex = {for (final e in entries) e.id: e};
    _dreamUpdates.removeWhere((id, local) {
      final live = entryIndex[id];
      return live == null ||
          live.version > local.version ||
          (live.version == local.version &&
              !live.updatedAt.isBefore(local.updatedAt));
    });
    _deletedDreamIds.removeWhere((id) => !entryIndex.containsKey(id));

    return [
      for (final e in entries)
        if (!_deletedDreamIds.contains(e.id)) _dreamUpdates[e.id] ?? e,
    ];
  }

  Map<String, String> _foldedText(
    List<JournalEntry> source,
    List<JournalEntry> merged,
  ) {
    if (identical(_haystackEntries, source) &&
        _haystackRevision == _localRevision) {
      return _haystack;
    }
    _haystack
      ..clear()
      ..addEntries(
        merged.map((e) => MapEntry(e.id, '${e.title} ${e.body}'.toLowerCase())),
      );
    _haystackEntries = source;
    _haystackRevision = _localRevision;
    return _haystack;
  }

  void _reportActionFailure(
    Object error,
    StackTrace stackTrace,
    String what,
    String message,
  ) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'SearchPage',
        context: ErrorDescription(what),
      ),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _deleteEntry(JournalEntry entry) async {
    // Captured while this widget is certainly mounted: the toast that offers
    // the undo outlives the row it deleted, and a `WidgetRef` would not.
    final container = ProviderScope.containerOf(context, listen: false);
    final overlay = Overlay.of(context, rootOverlay: true);

    final confirmed = await showConfirmDialog(
      context,
      title: 'Delete entry?',
      message: 'This entry will be moved to trash.',
    );
    if (!confirmed || !mounted) return;
    final JournalEntryDeletion? deletion;
    try {
      // Shared with the Journal page, which deletes the same rows — see
      // [softDeleteJournalEntry]. It settles and cancels this entry's pending
      // save itself, so an in-flight one can no longer land after the tombstone
      // and republish the entry as live; waiting on the upload here did the
      // same job, but hung whenever the server was unreachable.
      deletion = await softDeleteJournalEntry(container, entry.id);
    } catch (error, stackTrace) {
      // Never hide a row that still exists: the confirm dialog has already
      // closed, and leaving the row in place with nothing said reads as "the
      // delete was rejected".
      _reportActionFailure(
        error,
        stackTrace,
        'while deleting entry from Search',
        'Could not delete entry.',
      );
      return;
    }
    if (!mounted) return;
    setState(() {
      _deletedIds.add(entry.id);
      _localUpdates.remove(entry.id);
      _localRevision++;
    });
    _invalidateEntryCaches();
    if (deletion == null) return;
    showSoftDeleteUndoToast(
      overlay: overlay,
      message: deletedMessage(entry.title, fallback: 'entry'),
      restore: () => _undoEntryDelete(container, deletion!),
    );
  }

  /// Brings back an entry the toast's Undo was pressed for.
  ///
  /// The database restore is only half of it: this page hides a deleted row
  /// through [_deletedIds] rather than waiting on a provider refresh, and that
  /// hide would outlive the restore — leaving the entry back on disk but still
  /// missing from the results.
  Future<void> _undoEntryDelete(
    ProviderContainer container,
    JournalEntryDeletion deletion,
  ) async {
    // In a `finally` because the hide has to go however the restore ended —
    // otherwise a throw part-way through leaves the entry back on disk and
    // still missing from the results. Cleared unconditionally the list
    // re-derives either way: back if the write landed, still gone if it did
    // not.
    try {
      await restoreJournalEntry(container, deletion);
    } finally {
      if (mounted) {
        setState(() {
          _deletedIds.remove(deletion.entry.id);
          _localRevision++;
        });
        _invalidateEntryCaches();
      }
    }
  }

  Future<void> _changeEntryJournal(
    JournalEntry entry,
    List<Journal> journals,
  ) async {
    final targetJournalId = await showMoveToJournalDialog(
      context,
      journals: journals,
      currentJournalId: entry.journalId,
    );
    if (targetJournalId == null ||
        targetJournalId == entry.journalId ||
        !mounted) {
      return;
    }
    // Through the coordinator rather than a bare read-modify-write: it
    // serialises writes per document, and outside that queue this interleaved
    // freely with an in-flight save for the same entry — the save had already
    // re-read its baseline, so its write carried the old journalId and the
    // move was silently lost at a version that then looked authoritative.
    // Easy to hit, since the dialog's Save and Enter both fire the save and
    // pop immediately.
    final coordinator = ref.read(journalWriteCoordinatorProvider);
    JournalEntry? moved;
    try {
      await coordinator.saveEntry(
        entryId: entry.id,
        bumpVersion: true,
        applyDelta: (base) =>
            base.copyWith(journalId: targetJournalId, bumpVersion: false),
        onSuccess: (saved) => moved = saved,
      );
    } catch (error, stackTrace) {
      _reportActionFailure(
        error,
        stackTrace,
        'while moving an entry to another journal from Search',
        'Could not move entry.',
      );
      return;
    }
    final saved = moved;
    if (saved == null || !mounted) return;
    ref.read(remoteSyncServiceProvider).pushJournalEntryNow(saved);
    setState(() {
      _localUpdates[saved.id] = saved;
      _localRevision++;
    });
    _invalidateEntryCaches();
  }

  /// [_deleteEntry] for a dream.
  ///
  /// Written out here rather than shared with the Dream Journal page's own
  /// delete: that one is bound up with the page's selection, its pending "New
  /// dream" row and its editor flushes, none of which exist here. What is
  /// shared is the part that has to be exact — soft-delete, re-read, push the
  /// tombstone the delete actually produced.
  Future<void> _deleteDream(DreamEntry entry) async {
    // Captured while this widget is certainly mounted: the toast that offers
    // the undo outlives the row it deleted, and a `WidgetRef` would not.
    final container = ProviderScope.containerOf(context, listen: false);
    final overlay = Overlay.of(context, rootOverlay: true);

    final confirmed = await showConfirmDialog(
      context,
      title: 'Delete dream?',
      message: 'This dream will be moved to trash.',
    );
    if (!confirmed || !mounted) return;

    final repository = container.read(dreamRepositoryProvider);
    final DreamEntry snapshot;
    try {
      // Read off disk rather than taken from `entry`: the list this came from
      // lags an in-flight save, and restoring from a stale snapshot would
      // quietly roll the last edit back with the undo.
      snapshot = await repository.getEntry(entry.id) ?? entry;
      await repository.softDeleteEntry(entry.id);
      // The row the delete produced, not one rebuilt from the list's
      // snapshot — see the note on the Dream Journal page's delete: a
      // tombstone pushed at a version Firestore has already passed loses the
      // next pull and the dream comes back everywhere.
      final tombstone = await repository.getEntry(entry.id);
      if (tombstone != null) {
        container.read(remoteSyncServiceProvider).pushDreamEntryNow(tombstone);
      }
    } catch (error, stackTrace) {
      _reportActionFailure(
        error,
        stackTrace,
        'while deleting a dream from Search',
        'Could not delete dream.',
      );
      return;
    }
    if (!mounted) return;
    setState(() {
      _deletedDreamIds.add(entry.id);
      _dreamUpdates.remove(entry.id);
    });
    container.invalidate(allDreamEntriesProvider);

    showSoftDeleteUndoToast(
      overlay: overlay,
      message: deletedMessage(snapshot.title, fallback: 'dream'),
      restore: () => _undoDreamDelete(container, snapshot),
    );
  }

  /// Brings back a dream the toast's Undo was pressed for.
  ///
  /// Rebuilt field by field rather than `copyWith`'d, because `copyWith` reads
  /// `deletedAt ?? this.deletedAt` and so cannot clear a tombstone.
  Future<void> _undoDreamDelete(
    ProviderContainer container,
    DreamEntry snapshot,
  ) async {
    final repository = container.read(dreamRepositoryProvider);
    // Resolved against disk rather than the snapshot: an eight-second offer is
    // long enough for a pull to land a newer revision, and a restore written
    // under it loses the next pull and deletes the dream again.
    final current = await repository.getEntry(snapshot.id);
    abortIfAlreadyRestored(
      found: current != null,
      deletedAt: current?.deletedAt,
    );
    final restored = DreamEntry(
      id: snapshot.id,
      createdAt: snapshot.createdAt,
      updatedAt: utcNow(),
      version: restoreVersionFrom(
        preDeleteVersion: snapshot.version,
        currentVersion: current?.version,
      ),
      title: snapshot.title,
      body: snapshot.body,
      notes: snapshot.notes,
      entryDate: snapshot.entryDate,
      tags: snapshot.tags,
    );
    try {
      await repository.upsertEntry(restored);
      container.read(remoteSyncServiceProvider).pushDreamEntryNow(restored);
    } finally {
      // In a `finally` because the hide has to go however the restore ended:
      // the results re-derive either way — back if the write landed, still
      // gone if it did not.
      container.invalidate(allDreamEntriesProvider);
      if (mounted) {
        setState(() => _deletedDreamIds.remove(restored.id));
      }
    }
  }

  Future<void> _showDreamStatistics(DreamEntry entry) async {
    final wordCount = ref.read(analyticsServiceProvider).countWords(entry.body);
    await showVoyagerDialog<void>(
      context: context,
      builder: (context) =>
          DreamStatisticsDialog(entry: entry, wordCount: wordCount),
    );
  }

  /// Both providers this page reads are `keepAlive`, so a failed future is
  /// cached and nothing in the page can re-request it — a transient database
  /// lock at startup left the search tab showing a raw exception string until
  /// the app was restarted.
  Widget _loadFailure(String message, VoidCallback onRetry) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final entriesAsync = ref.watch(
      journalListEntriesProvider(allJournalEntriesScope),
    );
    final journalsAsync = ref.watch(journalsProvider);
    final search = ref.watch(searchServiceProvider);
    final theme = Theme.of(context);
    final settings = ref.watch(settingsProvider).valueOrNull;
    final accentColor = Color(
      settings?.accentColor ?? theme.colorScheme.primary.toARGB32(),
    );

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Row(
            children: [
              if (_dreamScope) ...[
                _DreamScopeChip(
                  accentColor: accentColor,
                  onRemove: _exitDreamScope,
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: TagHighlightedTextField(
                  controller: _queryController,
                  focusNode: _queryFocusNode,
                  // Completion follows the scope: the field filters journal
                  // entries (see SearchService.searchEntries) or dreams (see
                  // filterDreamEntries), and each has its own tag pool.
                  tagScope: _dreamScope ? TagScope.dream : TagScope.journal,
                  onKeyEvent: _handleQueryKey,
                  cursorColor: accentColor,
                  hintText: _dreamScope
                      ? 'Search dreams or #tag'
                      : 'Search keywords or #tag',
                  onChanged: _onQueryChanged,
                  decoration: const InputDecoration(
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: _dreamScope
                ? _dreamResults(theme, accentColor)
                : entriesAsync.when(
                    skipLoadingOnReload: true,
                    data: (entries) => journalsAsync.when(
                      skipLoadingOnReload: true,
                      data: (journals) {
                        final mergedEntries = _mergeAndPrune(entries);
                        final parsedQuery = _parseSearchQuery(_activeQuery);
                        final results = search.searchEntries(
                          entries: mergedEntries,
                          query: parsedQuery.keywords,
                          tagFilter: parsedQuery.tags.isEmpty
                              ? null
                              : parsedQuery.tags,
                          foldedText: _foldedText(entries, mergedEntries),
                        );
                        final keywords = parsedQuery.keywords
                            .split(RegExp(r'\s+'))
                            .where((k) => k.isNotEmpty)
                            .toList();
                        return KeepAliveScrollList(
                          storageKey: ShellPageStorageKeys.searchResults,
                          controller: _resultsController,
                          itemCount: results.length,
                          itemBuilder: (_, i) {
                            final entry = results[i];
                            final bodyStyle = theme.textTheme.bodyMedium!;
                            // Results show stored prose, so the markers render the
                            // same way they do in the editor (§10).
                            final emphasisTheme = ProseEmphasisTheme.of(
                              theme.colorScheme,
                              theme.colorScheme.primary,
                            );
                            return ContextMenuRegion(
                              items: [
                                ContextMenuItem(
                                  label: 'Statistics',
                                  icon: PhosphorIconsRegular.chartBar,
                                  onTap: () => showJournalEntryStatisticsDialog(
                                    context,
                                    ref,
                                    entry,
                                  ),
                                ),
                                ContextMenuItem(
                                  label: 'Change Journal',
                                  icon: PhosphorIconsRegular.folder,
                                  onTap: () => unawaited(
                                    _changeEntryJournal(entry, journals),
                                  ),
                                ),
                                ContextMenuItem(
                                  label: 'Delete',
                                  icon: PhosphorIconsRegular.trash,
                                  isDestructive: true,
                                  onTap: () => unawaited(_deleteEntry(entry)),
                                ),
                              ],
                              child: ListTile(
                                title: searchHighlightedText(
                                  entry.title.isEmpty
                                      ? 'Untitled'
                                      : entry.title,
                                  style: bodyStyle.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                                  keywords: keywords,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  emphasisTheme: emphasisTheme,
                                  brightness: theme.brightness,
                                ),
                                subtitle: searchHighlightedText(
                                  searchSnippet(entry.body, keywords: keywords),
                                  style: bodyStyle,
                                  keywords: keywords,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  emphasisTheme: emphasisTheme,
                                  brightness: theme.brightness,
                                ),
                                onTap: () async {
                                  await showVoyagerDialog<void>(
                                    context: context,
                                    builder: (context) => _SearchEntryDialog(
                                      entry: entry,
                                      journals: journals,
                                      onSaved: (updatedEntry) {
                                        if (mounted) {
                                          setState(() {
                                            _localUpdates[updatedEntry.id] =
                                                updatedEntry;
                                            _localRevision++;
                                          });
                                          _invalidateEntryCaches();
                                        }
                                      },
                                    ),
                                  );
                                },
                              ),
                            );
                          },
                        );
                      },
                      loading: () =>
                          const Center(child: CircularProgressIndicator()),
                      error: (e, _) => _loadFailure(
                        'Could not load journals.',
                        () => ref.invalidate(journalsProvider),
                      ),
                    ),
                    loading: () =>
                        const Center(child: CircularProgressIndicator()),
                    error: (e, _) => _loadFailure(
                      'Could not load entries.',
                      () => ref.invalidate(
                        journalListEntriesProvider(allJournalEntriesScope),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  /// The results list for the dream scope.
  ///
  /// Watched here rather than beside the journal providers in [build] so a
  /// user who never types [dreamSearchCommand] never pays for reading every
  /// dream row off disk.
  Widget _dreamResults(ThemeData theme, Color accentColor) {
    final dreamsAsync = ref.watch(allDreamEntriesProvider);
    return dreamsAsync.when(
      skipLoadingOnReload: true,
      data: (dreams) {
        final merged = _mergeAndPruneDreams(
          sortDreamEntriesNewestFirst(dreams),
        );
        final parsedQuery = _parseSearchQuery(_activeQuery);
        final results = filterDreamEntries(
          entries: merged,
          query: parsedQuery.keywords,
          tagFilter: parsedQuery.tags.isEmpty ? null : parsedQuery.tags,
        );
        final keywords = parsedQuery.keywords
            .split(RegExp(r'\s+'))
            .where((k) => k.isNotEmpty)
            .toList();
        final bodyStyle = theme.textTheme.bodyMedium!;
        final emphasisTheme = ProseEmphasisTheme.of(
          theme.colorScheme,
          theme.colorScheme.primary,
        );
        return KeepAliveScrollList(
          storageKey: ShellPageStorageKeys.searchDreamResults,
          controller: _dreamResultsController,
          itemCount: results.length,
          itemBuilder: (_, i) {
            final entry = results[i];
            return ContextMenuRegion(
              items: [
                ContextMenuItem(
                  label: 'Statistics',
                  icon: PhosphorIconsRegular.chartBar,
                  onTap: () => unawaited(_showDreamStatistics(entry)),
                ),
                ContextMenuItem(
                  label: 'Delete',
                  icon: PhosphorIconsRegular.trash,
                  isDestructive: true,
                  onTap: () => unawaited(_deleteDream(entry)),
                ),
              ],
              child: ListTile(
                title: searchHighlightedText(
                  entry.title.isEmpty ? 'Untitled' : entry.title,
                  style: bodyStyle.copyWith(fontWeight: FontWeight.w600),
                  keywords: keywords,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  emphasisTheme: emphasisTheme,
                  brightness: theme.brightness,
                ),
                subtitle: searchHighlightedText(
                  searchSnippet(entry.body, keywords: keywords),
                  style: bodyStyle,
                  keywords: keywords,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  emphasisTheme: emphasisTheme,
                  brightness: theme.brightness,
                ),
                trailing: Text(
                  DateFormat.yMMMd().format(entry.entryDate.toLocal()),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
                onTap: () async {
                  await showVoyagerDialog<void>(
                    context: context,
                    builder: (context) => _SearchDreamDialog(
                      entry: entry,
                      accentColor: accentColor,
                      onSaved: (updated) {
                        if (!mounted) return;
                        setState(() => _dreamUpdates[updated.id] = updated);
                        ref.invalidate(allDreamEntriesProvider);
                      },
                    ),
                  );
                },
              ),
            );
          },
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => _loadFailure(
        'Could not load dreams.',
        () => ref.invalidate(allDreamEntriesProvider),
      ),
    );
  }
}

/// The scope indicator the query field grows when [dreamSearchCommand] is
/// typed: the command itself leaves the field, and this stands in its place
/// until it is removed.
class _DreamScopeChip extends StatelessWidget {
  const _DreamScopeChip({required this.accentColor, required this.onRemove});

  final Color accentColor;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.only(left: 10, right: 4),
      decoration: BoxDecoration(
        color: accentColor.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(VoyagerTheme.fieldRadius),
        border: Border.all(color: accentColor.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(PhosphorIconsRegular.moon, size: 14, color: accentColor),
          const SizedBox(width: 6),
          Text(
            'Dream journals',
            style: theme.textTheme.labelMedium?.copyWith(color: accentColor),
          ),
          IconButton(
            tooltip: 'Search journal entries',
            iconSize: 14,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            padding: EdgeInsets.zero,
            color: accentColor,
            onPressed: onRemove,
            icon: const Icon(PhosphorIconsRegular.x),
          ),
        ],
      ),
    );
  }
}

/// Splits a raw query into its `#tag` filters and its plain keywords.
///
/// Every `#token` filters, not just the first. The single-tag version dropped
/// later ones into `keywords`, where `#urgent` was matched as literal body
/// text — which happened to work for inline tags, failed for any tag that
/// reached `tags` by another route (an import, a remote merge), and put spurious
/// keyword highlighting on the `#urgent` literal.
({List<String> tags, String keywords}) _parseSearchQuery(String rawQuery) {
  final parts = rawQuery.trim().split(RegExp(r'\s+'));
  final tags = <String>[];
  final keywords = <String>[];
  for (final part in parts) {
    if (part.isEmpty) continue;
    if (part.startsWith('#') && part.length > 1) {
      tags.add(part.substring(1));
    } else {
      keywords.add(part);
    }
  }
  return (tags: tags, keywords: keywords.join(' '));
}

class _SearchEntryDialog extends ConsumerStatefulWidget {
  const _SearchEntryDialog({
    required this.entry,
    required this.journals,
    required this.onSaved,
  });

  final JournalEntry entry;
  final List<Journal> journals;
  final void Function(JournalEntry) onSaved;

  @override
  ConsumerState<_SearchEntryDialog> createState() => _SearchEntryDialogState();
}

class _SearchEntryDialogState extends ConsumerState<_SearchEntryDialog> {
  late final TextEditingController _titleController;
  late final TextEditingController _bodyController;
  late final FocusNode _titleFocusNode;
  late final FocusNode _bodyFocusNode;
  late JournalEntry _entry;
  late int? _mood;
  late String _weatherIcon;

  /// What the last save published (or, until then, what the entry was opened
  /// with). [_isDirty] is the difference between it and the live buffer.
  late _EntryBaseline _baseline;

  /// Serialises this dialog's saves. Each one wipes and re-seeds the entry's
  /// remote operation log, which two overlapping calls must never interleave.
  Future<void> _saveChain = Future<void>.value();

  late final Future<void> Function() _lifecycleFlushCallback;

  @override
  void initState() {
    super.initState();
    _lifecycleFlushCallback = _lifecycleFlush;
    PendingFlushRegistry.instance.register(_lifecycleFlushCallback);
    _entry = widget.entry;
    _titleController = TextEditingController(text: _entry.title);
    _bodyController = TextEditingController(text: _entry.body);

    _titleFocusNode = FocusNode();
    _titleFocusNode.onKeyEvent = (node, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      if (event.logicalKey == LogicalKeyboardKey.tab &&
          !HardwareKeyboard.instance.isShiftPressed) {
        _bodyFocusNode.requestFocus();
        return KeyEventResult.handled;
      }
      // Enter commits from the title too, not just the body — Tab is what
      // moves between the two fields.
      if (event.logicalKey == LogicalKeyboardKey.enter &&
          !HardwareKeyboard.instance.isShiftPressed) {
        _saveAndClose();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };

    // _handleBodyKey is installed by TagHighlightedTextField (see its
    // onKeyEvent param) rather than assigned here: the tag completion popup
    // owns focusNode.onKeyEvent so it can take Enter while it's open, and
    // chains through to this handler otherwise.
    _bodyFocusNode = FocusNode();

    _mood = _entry.mood ?? kDefaultMood;
    _weatherIcon = _entry.weatherIcon ?? 'sunny';
    // The *coerced* values are the baseline, not `_entry.mood` /
    // `_entry.weatherIcon`. These defaults exist so the slider and the icon
    // have something to show for the rows that predate them (see
    // JournalEntry.mood); treating the coercion itself as an edit is what made
    // merely viewing an entry stamp mood 5 and weather 'sunny' onto it. They
    // still ride along once something else is genuinely edited, which is the
    // only time this dialog writes at all.
    _baseline = _EntryBaseline(
      title: _entry.title,
      body: _entry.body,
      mood: _mood,
      weatherIcon: _weatherIcon,
      entryDate: _entry.entryDate,
      journalId: _entry.journalId,
    );
  }

  /// Whether the live buffer differs from what was last persisted.
  ///
  /// Trimmed the same way [_save] trims before writing, so a trailing newline
  /// the save would drop never counts as an edit.
  bool get _isDirty {
    final b = _baseline;
    return _titleController.text.trim() != b.title.trim() ||
        _bodyController.text.trimRight() != b.body.trimRight() ||
        _mood != b.mood ||
        _weatherIcon != b.weatherIcon ||
        _entry.entryDate != b.entryDate ||
        _entry.journalId != b.journalId;
  }

  KeyEventResult _handleBodyKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.enter &&
        !HardwareKeyboard.instance.isShiftPressed) {
      _saveAndClose();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  JournalWriteCoordinator? _coordinator;
  RemoteSyncService? _remoteSync;
  JournalRepository? _journalRepository;

  bool _isDatePickerOpen = false;

  /// Set by the two gestures that mean *throw this away*: the Close button and
  /// Escape. Everything else that ends the dialog — Save, Enter, a click on
  /// the backdrop, a lifecycle flush — still writes the buffer.
  bool _discarded = false;

  @override
  void dispose() {
    PendingFlushRegistry.instance.unregister(_lifecycleFlushCallback);
    // Was `if (!_isSaved)`, a flag set on the first line of _save and never
    // reset. It conflated "a save has ever run" with "the buffer is
    // persisted", so any lifecycle flush — alt-tabbing away on desktop is one,
    // a shell branch change is another — latched it, and every edit made
    // afterwards was silently dropped by Close and Escape alike. Dirtiness is
    // the real question, and _save answers it again on its own first line so
    // an unconditional close can't queue a duplicate write either.
    if (_isDirty && !_discarded) {
      unawaited(_save());
    }
    _titleController.dispose();
    _bodyController.dispose();
    _titleFocusNode.dispose();
    _bodyFocusNode.dispose();
    super.dispose();
  }

  Journal? get _journal {
    for (final journal in widget.journals) {
      if (journal.id == _entry.journalId) return journal;
    }
    return null;
  }

  Color get _accentColor => Color(
    _journal?.colorValue ?? Theme.of(context).colorScheme.primary.toARGB32(),
  );

  /// Persists the buffer if it differs from [_baseline], and publishes it.
  ///
  /// Saving unconditionally was not free: it bumped `version`, restamped
  /// `updatedAt` and re-uploaded a document nothing had changed, and every one
  /// of those uploads deleted the entry's entire remote operation log and
  /// re-seeded it. Since the dialog is barrier-dismissible, a mis-tap was
  /// enough to do all of that to an untouched entry.
  Future<void> _save() {
    if (!_isDirty) return _saveChain;

    // Read synchronously, before anything is awaited, so the snapshot and the
    // dirty flag can't disagree with each other.
    final title = _titleController.text.trim();
    final body = _bodyController.text.trimRight();
    final snapshot = _EntryBaseline(
      title: title,
      body: body,
      mood: _mood,
      weatherIcon: _weatherIcon,
      entryDate: _entry.entryDate,
      journalId: _entry.journalId,
    );
    // The baseline moves now rather than when the write lands: dispose runs
    // immediately after the `unawaited(_save())` that Save and Enter fire, and
    // it has to see a clean buffer instead of queueing the same text twice.
    // Anything typed after this point makes the dialog dirty again and earns
    // its own save.
    final previous = _baseline;
    _baseline = snapshot;

    // Cached references, so nothing calls ref.read() during dispose().
    final helper = SearchEntrySaveHelper(
      coordinator: _coordinator ?? ref.read(journalWriteCoordinatorProvider),
      remoteSync: _remoteSync ?? ref.read(remoteSyncServiceProvider),
      journalRepository:
          _journalRepository ?? ref.read(journalRepositoryProvider),
    );
    final entryId = _entry.id;

    _saveChain = _saveChain
        .then((_) async {
          // Re-read rather than closing over `_entry`: an earlier link in the
          // chain may have replaced it with the row it published.
          final updated = await helper.saveEntry(
            baseline: _entry,
            title: snapshot.title,
            body: snapshot.body,
            mood: snapshot.mood,
            weatherIcon: snapshot.weatherIcon,
            journalId: snapshot.journalId,
            entryDate: snapshot.entryDate,
          );
          if (updated == null) {
            // Nothing reached disk. Re-arm so a later close retries instead of
            // dropping the edit on the floor — unless the user has typed since,
            // in which case a newer snapshot already owns the baseline.
            if (identical(_baseline, snapshot)) _baseline = previous;
            return;
          }
          if (mounted) setState(() => _entry = updated);
          widget.onSaved(updated);
        })
        .catchError((Object error, StackTrace stackTrace) {
          // Keeps the queue moving; SearchEntrySaveHelper already reports what it
          // caught, so this only ever sees something it re-threw.
          if (identical(_baseline, snapshot)) _baseline = previous;
          FlutterError.reportError(
            FlutterErrorDetails(
              exception: error,
              stack: stackTrace,
              library: 'SearchPage',
              context: ErrorDescription(
                'while saving entry $entryId from Search',
              ),
            ),
          );
        });
    return _saveChain;
  }

  Future<void> _lifecycleFlush() => _save();

  /// Closes first, then saves: the popup disappearing is the user's
  /// confirmation that Enter landed, so it must not wait on the write.
  void _saveAndClose() {
    unawaited(_save());
    if (mounted) Navigator.pop(context);
  }

  /// Leaves without writing: the buffer is dropped and the entry stays as it
  /// was on disk. [dispose] is what would otherwise persist it, so the flag has
  /// to be set before the pop rather than passed out of it.
  void _discardAndClose() {
    _discarded = true;
    if (mounted) Navigator.pop(context);
  }

  Future<void> _changeEntryDateAndTime(BuildContext buttonContext) async {
    final journal = widget.journals.cast<Journal?>().firstWhere(
      (j) => j?.id == _entry.journalId,
      orElse: () => null,
    );
    final accentColor = Color(
      journal?.colorValue ?? Theme.of(context).colorScheme.primary.toARGB32(),
    );

    setState(() => _isDatePickerOpen = true);
    final pickedDt = await showContextualPopover<DateTime>(
      context: context,
      buttonContext: buttonContext,
      width: 500,
      height: 380,
      accentColor: accentColor,
      builder: (ctx) => DateTimeSelectorPopover(
        initialDateTime: _entry.entryDate.toLocal(),
        accentColor: accentColor,
      ),
    );
    if (mounted) setState(() => _isDatePickerOpen = false);
    if (pickedDt == null) return;

    // Show it immediately, then let _save notice the difference. No version
    // bump here: this copy has not been written anywhere, and claiming a
    // version the disk doesn't have would outrank the row it came from.
    final updatedImmediate = _entry.copyWith(
      entryDate: pickedDt.toUtc(),
      bumpVersion: false,
    );
    if (mounted) {
      setState(() => _entry = updatedImmediate);
      widget.onSaved(updatedImmediate);
    }
    // Through _save so this joins the same per-dialog queue as everything
    // else: two overlapping full-text overwrites of one entry would otherwise
    // race each other's operation-log reseed.
    await _save();
  }

  Future<void> _moveToJournal(String journalId) async {
    if (journalId == _entry.journalId) return;
    if (mounted) {
      setState(
        () =>
            _entry = _entry.copyWith(journalId: journalId, bumpVersion: false),
      );
    }
    await _save();
  }

  @override
  Widget build(BuildContext context) {
    _coordinator = ref.watch(journalWriteCoordinatorProvider);
    _remoteSync = ref.watch(remoteSyncServiceProvider);
    _journalRepository = ref.watch(journalRepositoryProvider);

    final dialogWidth = math.min(920.0, MediaQuery.sizeOf(context).width - 48);

    final dialog = EnterToSubmitScope(
      onSubmit: () async {
        if (context.mounted) Navigator.pop(context);
      },
      // Escape reads as Close, not as a second Save. The route installs its own
      // DismissIntent action for the same key; this one sits below it, so the
      // lookup that starts at the focused field finds it first. Nothing here
      // touches the barrier, which keeps saving — a stray click outside is not
      // a decision to discard.
      child: Actions(
        actions: <Type, Action<Intent>>{
          DismissIntent: CallbackAction<DismissIntent>(
            onInvoke: (_) {
              _discardAndClose();
              return null;
            },
          ),
        },
        child: AlertDialog(
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 24,
            vertical: 24,
          ),
          title: const Text('Journal entry'),
          content: SizedBox(
            width: dialogWidth,
            child: VoyagerScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      LabeledTextField(
                        label: 'Title',
                        controller: _titleController,
                        focusNode: _titleFocusNode,
                        textInputAction: TextInputAction.done,
                        accentColor: _accentColor,
                        contentPadding: const EdgeInsets.fromLTRB(
                          16,
                          16,
                          40,
                          16,
                        ),
                        onSubmitted: (_) => _saveAndClose(),
                      ),
                      Positioned(
                        top: 0,
                        right: 10,
                        child: JournalTitleCornerFlag(
                          colorValue: _accentColor.toARGB32(),
                          onSelected: _moveToJournal,
                          menuEntries: (_) => [
                            for (var i = 0; i < widget.journals.length; i++)
                              VoyagerPopupMenuItem<String>(
                                value: widget.journals[i].id,
                                position: VoyagerMenuTheme.positionFor(
                                  i,
                                  widget.journals.length,
                                ),
                                child: Row(
                                  children: [
                                    JournalBookmarkFlag(
                                      colorValue:
                                          widget.journals[i].colorValue ??
                                          _accentColor.toARGB32(),
                                      size: 12,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(widget.journals[i].name),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Text('Mood', style: TextStyle(color: _accentColor)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: MoodGradientSlider(
                          value: _mood,
                          accent: _accentColor,
                          onChanged: (value) => setState(() => _mood = value),
                        ),
                      ),
                      const SizedBox(width: 12),
                      PopupMenuButton<VoyagerMenuCatalogEntry>(
                        tooltip: 'Weather',
                        icon: Icon(
                          weatherIconData(_weatherIcon),
                          color: _accentColor,
                        ),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 40,
                          minHeight: 40,
                        ),
                        onSelected: (entry) => setState(
                          () => _weatherIcon = entry.weatherIconValue!,
                        ),
                        itemBuilder: (context) =>
                            buildCatalogMenu(context, from: weatherMenuEntries),
                      ),
                      const SizedBox(width: 8),
                      Builder(
                        builder: (ctx) {
                          final label =
                              '${DateFormat.yMMMd().format(_entry.entryDate.toLocal())} at ${formatTime12Hour(_entry.entryDate.toLocal())}';
                          return SelectorPill(
                            dense: false,
                            ellipsize: false,
                            isActive: _isDatePickerOpen,
                            label: label,
                            accentColor: _accentColor,
                            onTap: () => _changeEntryDateAndTime(ctx),
                          );
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 480,
                    child: _withImages(
                      TagHighlightedTextField(
                        controller: _bodyController,
                        focusNode: _bodyFocusNode,
                        tagScope: TagScope.journal,
                        onKeyEvent: _handleBodyKey,
                        cursorColor: _accentColor,
                        expands: true,
                        hintText: 'Start writing...',
                        decoration: const InputDecoration(
                          filled: false,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            GlassButton(
              onPressed: _discardAndClose,
              label: 'Close',
              dense: true,
            ),
            GlassButton(
              onPressed: _saveAndClose,
              label: 'Save',
              color: _accentColor,
              dense: true,
            ),
          ],
        ),
      ),
    );
    // Save, not the Close that unfocused Enter maps to above: the chord is an
    // explicit commit wherever the focus is.
    return CtrlEnterToSubmitScope(onSubmit: _saveAndClose, child: dialog);
  }

  /// Wraps the dialog's writing area in this entry's images.
  ///
  /// The same three pieces the journal body carries (see `_withImages` in
  /// journal_page.dart): the entry owns the images as reference rows, the
  /// corner fan is where they are seen, and paste and drop are what puts them
  /// there. An entry opened from search is the same entry, so it behaves the
  /// same way here — otherwise the same picture could be attached on one page
  /// and not the other.
  Widget _withImages(Widget field) {
    return MediaPasteScope(
      collection: FirestoreCollections.journalEntries,
      documentId: _entry.id,
      // The body is image-capable, so a clipboard holding both a screenshot
      // and its caption pastes both rather than dropping the picture.
      fieldTakesBoth: true,
      child: MediaDropTarget(
        collection: FirestoreCollections.journalEntries,
        documentId: _entry.id,
        child: Stack(
          children: [
            Positioned.fill(child: field),
            // Floating over the text rather than reserving a band under it:
            // Flutter cannot wrap a paragraph around a corner, so the only
            // alternative would be padding the full width of the field,
            // images or not.
            Positioned(
              right: 8,
              bottom: 8,
              child: MediaFanStack(
                collection: FirestoreCollections.journalEntries,
                documentId: _entry.id,
                accentColor: _accentColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// What [_SearchEntryDialogState] last persisted, for the dirty check.
///
/// A class rather than a record so a snapshot can be compared by identity: a
/// failed save only re-arms the baseline it set itself, leaving a newer one
/// from a keystroke that landed meanwhile alone.
class _EntryBaseline {
  const _EntryBaseline({
    required this.title,
    required this.body,
    required this.mood,
    required this.weatherIcon,
    required this.entryDate,
    required this.journalId,
  });

  final String title;
  final String body;
  final int? mood;
  final String weatherIcon;
  final DateTime entryDate;
  final String journalId;
}

/// [_SearchEntryDialog] for a dream: the same popup editor, without the
/// journal, mood, weather and image rows a dream does not have, and with the
/// Dream Journal page's corner scratchpad so the dream's notes are editable
/// from here too.
class _SearchDreamDialog extends ConsumerStatefulWidget {
  const _SearchDreamDialog({
    required this.entry,
    required this.accentColor,
    required this.onSaved,
  });

  final DreamEntry entry;
  final Color accentColor;
  final void Function(DreamEntry) onSaved;

  @override
  ConsumerState<_SearchDreamDialog> createState() => _SearchDreamDialogState();
}

class _SearchDreamDialogState extends ConsumerState<_SearchDreamDialog> {
  late final TextEditingController _titleController;
  late final TextEditingController _bodyController;
  late final TextEditingController _notesController;
  late final FocusNode _titleFocusNode;
  late final FocusNode _bodyFocusNode;
  late final FocusNode _notesFocusNode;
  late DreamEntry _entry;
  String _lastNotesText = '';

  /// What the last save published (or, until then, what the dream was opened
  /// with). [_isDirty] is the difference between it and the live buffer.
  late _DreamBaseline _baseline;

  /// Serialises this dialog's saves, for the same reason the journal one does:
  /// each wipes and re-seeds the dream's remote operation log, which two
  /// overlapping calls must never interleave.
  Future<void> _saveChain = Future<void>.value();

  late final Future<void> Function() _lifecycleFlushCallback;

  DreamWriteCoordinator? _coordinator;
  RemoteSyncService? _remoteSync;

  bool _isDatePickerOpen = false;

  /// Set by the two gestures that mean *throw this away*: the Close button and
  /// Escape. Everything else that ends the dialog still writes the buffer.
  bool _discarded = false;

  @override
  void initState() {
    super.initState();
    _lifecycleFlushCallback = _lifecycleFlush;
    PendingFlushRegistry.instance.register(_lifecycleFlushCallback);
    _entry = widget.entry;
    _titleController = TextEditingController(text: _entry.title);
    _bodyController = TextEditingController(text: _entry.body);
    _notesController = TextEditingController(text: _entry.notes ?? '');
    _lastNotesText = _notesController.text;

    _titleFocusNode = FocusNode();
    _titleFocusNode.onKeyEvent = (node, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      if (event.logicalKey == LogicalKeyboardKey.tab &&
          !HardwareKeyboard.instance.isShiftPressed) {
        _bodyFocusNode.requestFocus();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.enter &&
          !HardwareKeyboard.instance.isShiftPressed) {
        _saveAndClose();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };

    // Installed by TagHighlightedTextField rather than assigned here — see
    // the note in [_SearchEntryDialogState.initState].
    _bodyFocusNode = FocusNode();
    // The scratchpad has no completion popup to share the slot with, so this
    // one is assigned directly, exactly as the Dream Journal page does it.
    _notesFocusNode = FocusNode();
    _notesFocusNode.onKeyEvent = _handleNotesKey;

    _baseline = _DreamBaseline(
      title: _entry.title,
      body: _entry.body,
      notes: _notesController.text,
      entryDate: _entry.entryDate,
    );
  }

  @override
  void dispose() {
    PendingFlushRegistry.instance.unregister(_lifecycleFlushCallback);
    if (_isDirty && !_discarded) {
      unawaited(_save());
    }
    _titleController.dispose();
    _bodyController.dispose();
    _notesController.dispose();
    _titleFocusNode.dispose();
    _bodyFocusNode.dispose();
    _notesFocusNode.dispose();
    super.dispose();
  }

  /// Whether the live buffer differs from what was last persisted, trimmed the
  /// same way [_save] trims before writing.
  bool get _isDirty {
    final b = _baseline;
    return _titleController.text.trim() != b.title.trim() ||
        _bodyController.text.trimRight() != b.body.trimRight() ||
        _notesController.text.trimRight() != b.notes.trimRight() ||
        _entry.entryDate != b.entryDate;
  }

  KeyEventResult _handleBodyKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.enter &&
        !HardwareKeyboard.instance.isShiftPressed) {
      _saveAndClose();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// The scratchpad continues lists as it does on the Dream Journal page. No
  /// save is scheduled off it: this dialog writes on close, not on a debounce.
  void _handleNotesChanged(String _) {
    applyListEditing(
      controller: _notesController,
      previousText: _lastNotesText,
    );
    _lastNotesText = _notesController.text;
  }

  /// The other half of the scratchpad's list editing — the part
  /// [_handleNotesChanged] can't see, because neither key changes the text on
  /// its own. Without it Tab fell through to focus traversal and left the note
  /// entirely, and Backspace behind a bare marker deleted one character of it
  /// instead of the marker.
  KeyEventResult _handleNotesKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.tab) {
      final outdent = HardwareKeyboard.instance.isShiftPressed;
      if (handleListTab(controller: _notesController, outdent: outdent)) {
        // Routed through the handler typing uses so _lastNotesText stays in
        // step for the next keystroke.
        _handleNotesChanged(_notesController.text);
        return KeyEventResult.handled;
      }
    }
    if (event.logicalKey == LogicalKeyboardKey.backspace) {
      if (handleListBackspace(controller: _notesController)) {
        _handleNotesChanged(_notesController.text);
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  /// Persists the buffer if it differs from [_baseline], and publishes it.
  ///
  /// The same shape as [_SearchEntryDialogState._save], including why the
  /// baseline moves before the write lands and why a failed write re-arms it.
  Future<void> _save() {
    if (!_isDirty) return _saveChain;

    // Read synchronously, before anything is awaited, so the snapshot and the
    // dirty flag can't disagree with each other.
    final title = _titleController.text.trim();
    final body = _bodyController.text.trimRight();
    final notes = _notesController.text.trimRight();
    final snapshot = _DreamBaseline(
      title: title,
      body: body,
      notes: notes,
      entryDate: _entry.entryDate,
    );
    final previous = _baseline;
    _baseline = snapshot;

    // Cached references, so nothing calls ref.read() during dispose().
    final helper = SearchDreamSaveHelper(
      coordinator: _coordinator ?? ref.read(dreamWriteCoordinatorProvider),
      remoteSync: _remoteSync ?? ref.read(remoteSyncServiceProvider),
    );
    final entryId = _entry.id;

    _saveChain = _saveChain
        .then((_) async {
          final updated = await helper.saveEntry(
            // Re-read rather than closing over a captured row: an earlier link in
            // the chain may have replaced it with the one it published.
            baseline: _entry,
            title: snapshot.title,
            body: snapshot.body,
            notes: snapshot.notes,
            entryDate: snapshot.entryDate,
          );
          if (updated == null) {
            // Nothing reached disk. Re-arm so a later close retries instead of
            // dropping the edit — unless the user has typed since, in which case a
            // newer snapshot already owns the baseline.
            if (identical(_baseline, snapshot)) _baseline = previous;
            return;
          }
          if (mounted) setState(() => _entry = updated);
          widget.onSaved(updated);
        })
        .catchError((Object error, StackTrace stackTrace) {
          if (identical(_baseline, snapshot)) _baseline = previous;
          FlutterError.reportError(
            FlutterErrorDetails(
              exception: error,
              stack: stackTrace,
              library: 'SearchPage',
              context: ErrorDescription(
                'while saving dream $entryId from Search',
              ),
            ),
          );
        });
    return _saveChain;
  }

  Future<void> _lifecycleFlush() => _save();

  /// Closes first, then saves: the popup disappearing is the user's
  /// confirmation that Enter landed, so it must not wait on the write.
  void _saveAndClose() {
    unawaited(_save());
    if (mounted) Navigator.pop(context);
  }

  /// Leaves without writing: the buffer is dropped and the dream stays as it
  /// was on disk. [dispose] is what would otherwise persist it, so the flag
  /// has to be set before the pop rather than passed out of it.
  void _discardAndClose() {
    _discarded = true;
    if (mounted) Navigator.pop(context);
  }

  Future<void> _changeEntryDateAndTime(BuildContext buttonContext) async {
    setState(() => _isDatePickerOpen = true);
    final pickedDt = await showContextualPopover<DateTime>(
      context: context,
      buttonContext: buttonContext,
      width: 500,
      height: 380,
      accentColor: widget.accentColor,
      builder: (ctx) => DateTimeSelectorPopover(
        initialDateTime: _entry.entryDate.toLocal(),
        accentColor: widget.accentColor,
      ),
    );
    if (mounted) setState(() => _isDatePickerOpen = false);
    if (pickedDt == null) return;

    // Shown immediately, then left for _save to notice. No version bump here:
    // this copy has not been written anywhere, and claiming a version the disk
    // doesn't have would outrank the row it came from.
    final updatedImmediate = _entry.copyWith(
      entryDate: pickedDt.toUtc(),
      bumpVersion: false,
    );
    if (mounted) {
      setState(() => _entry = updatedImmediate);
      widget.onSaved(updatedImmediate);
    }
    // Through _save so this joins the same per-dialog queue as everything
    // else.
    await _save();
  }

  @override
  Widget build(BuildContext context) {
    _coordinator = ref.watch(dreamWriteCoordinatorProvider);
    _remoteSync = ref.watch(remoteSyncServiceProvider);

    final accent = widget.accentColor;
    final dialogWidth = math.min(920.0, MediaQuery.sizeOf(context).width - 48);

    final dialog = EnterToSubmitScope(
      onSubmit: () async {
        if (context.mounted) Navigator.pop(context);
      },
      // Escape reads as Close, not as a second Save — see the journal dialog.
      child: Actions(
        actions: <Type, Action<Intent>>{
          DismissIntent: CallbackAction<DismissIntent>(
            onInvoke: (_) {
              _discardAndClose();
              return null;
            },
          ),
        },
        child: AlertDialog(
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 24,
            vertical: 24,
          ),
          title: const Text('Dream'),
          content: SizedBox(
            width: dialogWidth,
            child: VoyagerScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  LabeledTextField(
                    label: 'Title',
                    controller: _titleController,
                    focusNode: _titleFocusNode,
                    textInputAction: TextInputAction.done,
                    accentColor: accent,
                    onSubmitted: (_) => _saveAndClose(),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Builder(
                        builder: (ctx) {
                          final local = _entry.entryDate.toLocal();
                          return SelectorPill(
                            dense: false,
                            ellipsize: false,
                            isActive: _isDatePickerOpen,
                            label:
                                '${DateFormat.yMMMd().format(local)}'
                                ' at ${formatTime12Hour(local)}',
                            accentColor: accent,
                            onTap: () => _changeEntryDateAndTime(ctx),
                          );
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 480,
                    // The scratchpad floats over the body the way it does on
                    // the Dream Journal page — [DreamStickyNote] is a
                    // [Positioned], so it needs this Stack to sit in.
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: TagHighlightedTextField(
                            controller: _bodyController,
                            focusNode: _bodyFocusNode,
                            tagScope: TagScope.dream,
                            onKeyEvent: _handleBodyKey,
                            cursorColor: accent,
                            expands: true,
                            hintText: 'Describe your dream...',
                            decoration: const InputDecoration(
                              filled: false,
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                            ),
                          ),
                        ),
                        DreamStickyNote(
                          controller: _notesController,
                          focusNode: _notesFocusNode,
                          accentColor: accent,
                          onChanged: _handleNotesChanged,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            GlassButton(
              onPressed: _discardAndClose,
              label: 'Close',
              dense: true,
            ),
            GlassButton(
              onPressed: _saveAndClose,
              label: 'Save',
              color: accent,
              dense: true,
            ),
          ],
        ),
      ),
    );
    // Save, not the Close that unfocused Enter maps to above: the chord is an
    // explicit commit wherever the focus is.
    return CtrlEnterToSubmitScope(onSubmit: _saveAndClose, child: dialog);
  }
}

/// What [_SearchDreamDialogState] last persisted, for the dirty check. A class
/// for the same identity-comparison reason as [_EntryBaseline].
class _DreamBaseline {
  const _DreamBaseline({
    required this.title,
    required this.body,
    required this.notes,
    required this.entryDate,
  });

  final String title;
  final String body;
  final String notes;
  final DateTime entryDate;
}
