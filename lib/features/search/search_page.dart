import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/icons/voyager_icons.dart';
import 'package:voyager/core/widgets/confirm_dialog.dart';
import 'package:voyager/core/widgets/context_menu.dart';
import 'package:voyager/features/journal/journal_entry_actions.dart';
import 'package:voyager/core/theme/voyager_menu_theme.dart';
import 'package:voyager/core/utils/journal_tags.dart';
import 'package:voyager/core/utils/time_format.dart';
import 'package:intl/intl.dart';
import 'package:voyager/core/widgets/contextual_popover.dart';
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
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/sync/journal_write_coordinator.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/features/search/search_entry_save_helper.dart';
import 'package:voyager/features/shell/shell_page_storage_keys.dart';
import 'package:voyager/core/sync/pending_flush_registry.dart';
import 'package:voyager/core/tags/tag_suggestions.dart';
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

  @override
  void dispose() {
    _queryDebounce?.cancel();
    _queryController.dispose();
    _queryFocusNode.dispose();
    _resultsController.dispose();
    super.dispose();
  }

  void _onQueryChanged(String _) {
    _queryDebounce?.cancel();
    _queryDebounce = Timer(_queryDebounceDelay, () {
      if (!mounted) return;
      setState(() => _activeQuery = _queryController.text);
      // One ScrollPosition is shared across every result set (the list is kept
      // alive under a constant PageStorageKey), so without this a deep offset
      // from a narrow result set survives into the next one — clearing the
      // query lands the user somewhere arbitrary in the full list instead of
      // at the best matches.
      if (_resultsController.hasClients) _resultsController.jumpTo(0);
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
    final confirmed = await showConfirmDialog(
      context,
      title: 'Delete entry?',
      message: 'This entry will be moved to trash.',
    );
    if (!confirmed || !mounted) return;
    final repo = ref.read(journalRepositoryProvider);
    final remoteSync = ref.read(remoteSyncServiceProvider);
    try {
      // An in-flight save for this entry would otherwise land after the
      // tombstone and republish it as live, which is why journal_page._delete
      // flushes first too.
      await remoteSync.flushDocument(
        FirestoreCollections.journalEntries,
        entry.id,
      );
      await repo.softDeleteEntry(entry.id);
      // The pushed tombstone is read back rather than built from `entry`.
      // `entry` comes from the _localUpdates-merged list, which lags disk
      // whenever an in-flight save hasn't reported back, and softDeleteEntry
      // bumps the version itself — so a tombstone built here went out at a
      // version Firestore had already passed, the next device read it as the
      // loser and pushed its own live document back, resurrecting the entry
      // everywhere. See journal_page._softDeleteAndPushTombstone.
      final tombstone = await repo.getEntry(entry.id);
      if (tombstone != null) remoteSync.pushJournalEntryNow(tombstone);
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
          TagHighlightedTextField(
            controller: _queryController,
            focusNode: _queryFocusNode,
            // Search only ever looks at journal entries (see
            // SearchService.searchEntries), so it completes against theirs.
            tagScope: TagScope.journal,
            cursorColor: accentColor,
            hintText: 'Search keywords or #tag',
            onChanged: _onQueryChanged,
            decoration: const InputDecoration(
              filled: false,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
            ),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: entriesAsync.when(
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
                            onTap: () =>
                                unawaited(_changeEntryJournal(entry, journals)),
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
                            entry.title.isEmpty ? 'Untitled' : entry.title,
                            style: bodyStyle.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                            keywords: keywords,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: searchHighlightedText(
                            searchSnippet(entry.body, keywords: keywords),
                            style: bodyStyle,
                            keywords: keywords,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
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
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => _loadFailure(
                  'Could not load journals.',
                  () => ref.invalidate(journalsProvider),
                ),
              ),
              loading: () => const Center(child: CircularProgressIndicator()),
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
    if (_isDirty) {
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

    _saveChain = _saveChain.then((_) async {
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
    }).catchError((Object error, StackTrace stackTrace) {
      // Keeps the queue moving; SearchEntrySaveHelper already reports what it
      // caught, so this only ever sees something it re-threw.
      if (identical(_baseline, snapshot)) _baseline = previous;
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'SearchPage',
          context: ErrorDescription('while saving entry $entryId from Search'),
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
        () => _entry = _entry.copyWith(
          journalId: journalId,
          bumpVersion: false,
        ),
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

    return EnterToSubmitScope(
      onSubmit: () async {
        if (context.mounted) Navigator.pop(context);
      },
      child: AlertDialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
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
                      contentPadding: const EdgeInsets.fromLTRB(16, 16, 40, 16),
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
                  child: TagHighlightedTextField(
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
              ],
            ),
          ),
        ),
        actions: [
          GlassButton(
            onPressed: () => Navigator.pop(context),
            label: 'Close',
            dense: true,
          ),
          GlassButton(
            onPressed: () {
              unawaited(_save());
              if (context.mounted) Navigator.pop(context);
            },
            label: 'Save',
            color: _accentColor,
            dense: true,
          ),
        ],
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
