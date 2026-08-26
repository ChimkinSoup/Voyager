import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/journal_write_coordinator.dart';
import 'package:voyager/core/sync/pending_flush_registry.dart';
import 'package:voyager/core/sync/pending_text_merge.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/sync/text_delta_injector.dart';
import 'package:voyager/core/layout/window_size_class.dart';
import 'package:voyager/core/motion/motion.dart';
import 'package:voyager/core/tags/tag_suggestions.dart';
import 'package:voyager/core/text/list_text_editing.dart';
import 'package:voyager/core/theme/voyager_list_item_surface.dart';
import 'package:voyager/core/theme/voyager_spacing.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/features/shell/shell_back_interceptor.dart';
import 'package:voyager/core/utils/journal_tags.dart';
import 'package:voyager/core/utils/time_format.dart';
import 'package:voyager/core/widgets/compact_back_bar.dart';
import 'package:voyager/core/widgets/confirm_dialog.dart';
import 'package:voyager/core/widgets/context_menu.dart';
import 'package:voyager/core/widgets/contextual_popover.dart';
import 'package:voyager/core/widgets/datetime_selector_popover.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/core/widgets/resizable_pane_divider.dart';
import 'package:voyager/core/widgets/selector_pill.dart';
import 'package:voyager/core/widgets/tag_chip.dart';
import 'package:voyager/core/widgets/tag_highlighted_text_field.dart';
import 'package:voyager/core/widgets/voyager_dialog.dart';
import 'package:voyager/domain/models/dream_models.dart';
import 'package:voyager/domain/models/journal_models.dart'
    show firstSentencePreview;
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/features/dream_journal/dream_branch_painter.dart';
import 'package:voyager/features/dream_journal/dream_sticky_note.dart';

/// Layout math for the 35/65 split pane, mirroring
/// [JournalEntryListLayout]'s shape but tuned for Dream Journal's default
/// proportions.
class DreamSplitLayout {
  DreamSplitLayout._();

  static const dividerWidth = 12.0;
  static const minListWidth = 240.0;
  static const maxListWidth = 620.0;
  static const minEditorWidth = 380.0;

  static double defaultListWidth(double totalWidth) {
    return (totalWidth * 0.35).clamp(minListWidth, 480.0);
  }

  static double _maxAllowed(double totalWidth) =>
      (totalWidth - minEditorWidth - dividerWidth).clamp(
        minListWidth,
        maxListWidth,
      );

  static double clampListWidth(double width, double totalWidth) {
    return width.clamp(minListWidth, _maxAllowed(totalWidth));
  }

  /// Soft-bounded version of [clampListWidth] for use while a drag is live.
  static double dragClampListWidth(double width, double totalWidth) {
    return resizePaneRubberBand(
      width: width,
      totalWidth: totalWidth,
      minWidth: minListWidth,
      maxWidth: _maxAllowed(totalWidth),
    );
  }

  static const editorPadding = EdgeInsets.fromLTRB(28, 40, 28, 24);
}

class DreamJournalPage extends ConsumerStatefulWidget {
  const DreamJournalPage({super.key});

  @override
  ConsumerState<DreamJournalPage> createState() => _DreamJournalPageState();
}

class _DreamJournalPageState extends ConsumerState<DreamJournalPage> {
  static const _localSaveDebounce = Duration(milliseconds: 400);

  String? _selectedEntryId;
  DreamEntry? _selectedEntry;

  /// Dreams deleted here that the entries provider may still be handing back,
  /// each mapped to the `updatedAt` this page's own soft delete stamped.
  ///
  /// A soft delete doesn't reach [allDreamEntriesProvider] until its refresh
  /// lands, so without this the auto-select in [build] sees the entry still
  /// sitting at the head of the list and re-opens it — putting the title and
  /// body you just deleted straight back on screen, where they stick, because
  /// `_selectedEntryId` is no longer null for auto-select to try again.
  ///
  /// Releasing an id on absence alone is wrong in the other direction:
  /// `mergeDeletedAtFromRemote` supports un-delete, so a dream restored on
  /// another device is handed back by the provider and would stay filtered out
  /// here for the life of the page. The stamp is the positive signal instead —
  /// the id is released once the row is gone, or once a revision newer than
  /// the tombstone arrives.
  final _deletedEntryStamps = <String, DateTime>{};

  /// The "New dream" row, held in memory until it has content.
  ///
  /// Writing it to SQLite on creation left a permanent blank row in the list —
  /// and on every other device, and on the "Dream Logged" heatmap — for anyone
  /// who tapped New dream and navigated away. It reaches disk from
  /// [_promotePendingEntry], the first time it has something in it.
  DreamEntry? _pendingEntry;

  /// Whether [_pendingEntry] has since been promoted. It stays merged into the
  /// displayed list until [allDreamEntriesProvider] hands the row back, so the
  /// row does not flicker out between the write and the refresh.
  var _pendingEntryOnDisk = false;

  /// Tail of this page's serialized local writes — see [_queueWrite].
  Future<void>? _writeQueue;
  var _pendingWrites = 0;
  final _titleController = TextEditingController();
  final _titleFocusNode = FocusNode();
  final _bodyFocusNode = FocusNode();
  final _bodyEditorKey = GlobalKey<_DreamBodyEditorState>();
  final _notesController = TextEditingController();
  final _notesFocusNode = FocusNode();
  var _lastNotesText = '';
  final _listTitlePreview = ValueNotifier<String>('');
  final _listBodyPreview = ValueNotifier<String>('');
  Timer? _saveTimer;
  Timer? _notesSaveTimer;
  double? _splitWidth;
  double? _dragStartWidth;
  var _splitDragging = false;
  var _appliedSavedWidth = false;

  /// Phone shell only: whether the zen editor is covering the dream list.
  /// Kept apart from [_selectedEntryId] so this page's auto-select of the
  /// newest dream does not count as the user asking to open it.
  var _compactShowingEditor = false;
  var _isDatePickerOpen = false;
  VoidCallback? _removeBackInterceptor;
  late final Future<void> Function() _lifecycleFlushCallback;

  @override
  void initState() {
    super.initState();
    _lifecycleFlushCallback = _lifecycleFlush;
    PendingFlushRegistry.instance.register(_lifecycleFlushCallback);
    _removeBackInterceptor = ShellBackInterceptors.instance.register(
      _handleSystemBack,
    );
    _titleFocusNode.addListener(_handleTitleFocusChanged);
    _bodyFocusNode.addListener(_handleBodyFocusChanged);
    _notesFocusNode.onKeyEvent = _handleNotesKey;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(ref.read(allDreamEntriesProvider.future));
    });
  }

  Future<void> _lifecycleFlush() async {
    // Nothing is left on screen to refresh for; just get the bytes down, and
    // do not let either half's remote write suppress the other's local one:
    // both end in a Firestore write, and SyncRetryPolicy rethrows after its
    // last retry, so an offline or rejected body upload used to throw straight
    // past `_flushNotes` — losing the debounced sticky-note text on the one
    // path where it is unrecoverable, because the process is about to exit.
    //
    // They must stay sequential: both contend for the same document key.
    try {
      await _flushActiveEdits(refreshList: false);
    } catch (_) {}
    try {
      await _flushNotes();
    } catch (_) {}
  }

  void _handleTitleFocusChanged() {
    if (!_titleFocusNode.hasFocus) {
      unawaited(_flushActiveEdits());
    }
  }

  /// Leaving the body is a commitment point, the same as it is on the journal
  /// page. Without this the dream list — and the tag pool and "dream logged"
  /// tracker built off it — would stay stale until the user happened to switch
  /// dreams, since the autosave deliberately no longer reloads them.
  void _handleBodyFocusChanged() {
    if (!_bodyFocusNode.hasFocus) {
      unawaited(_flushActiveEdits());
    }
  }

  @override
  void dispose() {
    PendingFlushRegistry.instance.unregister(_lifecycleFlushCallback);
    _removeBackInterceptor?.call();
    _titleFocusNode.removeListener(_handleTitleFocusChanged);
    _bodyFocusNode.removeListener(_handleBodyFocusChanged);
    _saveTimer?.cancel();
    _notesSaveTimer?.cancel();
    _titleController.dispose();
    _titleFocusNode.dispose();
    _bodyFocusNode.dispose();
    _notesController.dispose();
    _notesFocusNode.dispose();
    _listTitlePreview.dispose();
    _listBodyPreview.dispose();
    super.dispose();
  }

  DreamWriteCoordinator? _coordinatorOrNull() =>
      mounted ? ref.read(dreamWriteCoordinatorProvider) : null;
  DreamRepository? _repoOrNull() =>
      mounted ? ref.read(dreamRepositoryProvider) : null;
  RemoteSyncService? _syncOrNull() =>
      mounted ? ref.read(remoteSyncServiceProvider) : null;

  /// Runs [action] after every write this page has already started.
  ///
  /// Every local write here targets the same `dreamEntries_<id>` key, and
  /// [RemoteSyncService.saveLocalThenScheduleUpload] supersedes an older save
  /// generation *before* it calls `saveLocal` — right for two successive body
  /// autosaves, where the later carries the earlier's text, and wrong for two
  /// different deltas. The body/title autosave and the sticky note's autosave
  /// carry different fields on independent 400ms debounces, and seven call
  /// sites can start a flush (three of them unawaited) — clicking a row while
  /// the body has focus starts two in the same gesture. Whenever two of those
  /// overlapped, one was dropped without ever reaching `saveLocal` and the
  /// text it carried was never written.
  ///
  /// Queueing rather than returning the in-flight future matters: the flush
  /// snapshots the editor at its start, so a caller answered with someone
  /// else's in-flight run is told work was done that never saw its keystrokes.
  /// The extra pass is cheap — [_persistEntryEdits] short-circuits when the
  /// text already matches disk.
  Future<void> _queueWrite(Future<void> Function() action) {
    _pendingWrites++;
    final previous = _writeQueue ?? Future<void>.value();
    final next = previous.catchError((Object _) {}).then((_) => action());
    final tracked = next.whenComplete(() => _pendingWrites--);
    _writeQueue = tracked.catchError((Object _) {});
    return tracked;
  }

  void _scheduleBodySave() {
    // Bound to the dream the editor is actually showing. [_saveDraft] reads
    // `_selectedEntry` and the editor's text fresh at fire time, so a timer
    // re-armed by a keystroke during a selection change's flush would
    // otherwise write the outgoing dream's characters into the incoming one.
    final entryId = _selectedEntry?.id;
    _saveTimer?.cancel();
    _saveTimer = Timer(_localSaveDebounce, () {
      if (_selectedEntry?.id != entryId) return;
      // Re-checked inside the queue too: [_saveDraft] reads `_selectedEntry`
      // and the editor's text at *its* start, and the queue can hold it past
      // a selection change that started before the timer fired.
      unawaited(
        _queueWrite(() async {
          if (_selectedEntry?.id != entryId) return;
          await _saveDraft(bumpVersion: false);
        }),
      );
    });
  }

  Future<void> _saveDraft({required bool bumpVersion}) async {
    final entry = _selectedEntry;
    if (entry == null) return;
    final body = _bodyEditorKey.currentState?.currentBodyText ?? entry.body;
    await _persistEntryEdits(
      entry: entry,
      title: _titleController.text,
      body: body,
      bumpVersion: bumpVersion,
    );
  }

  /// Writes the editor's current text, or does nothing if it already matches
  /// disk.
  ///
  /// Deliberately has no say in reloading [allDreamEntriesProvider]: it is
  /// reached both from the ~400ms autosave, which must not reload at all, and
  /// from [_flushActiveEdits], which must reload whether or not this found
  /// anything to write. By the time a flush runs the autosave has usually
  /// already persisted the same text, so hanging the reload off a successful
  /// write here would silently skip it and leave the list stale for good.
  ///
  /// The reload is worth avoiding per keystroke burst because that provider
  /// re-reads and re-maps every dream row, and fans out further —
  /// `tagPoolProvider` re-ranks every dream's tags off it, and so does the
  /// "dream logged" tracker. None of that can change from editing one dream's
  /// text, and the list row on screen is updated directly below through
  /// [_listTitlePreview]/[_listBodyPreview].
  Future<void> _persistEntryEdits({
    required DreamEntry entry,
    required String title,
    required String body,
    bool bumpVersion = false,
  }) async {
    final tags = extractTags(body);
    final coordinator = _coordinatorOrNull();
    final repo = _repoOrNull();
    if (coordinator == null || repo == null) return;

    final stored = await repo.getEntry(entry.id);
    final baseline = stored ?? entry;
    if (baseline.title == title &&
        baseline.body == body &&
        _sameTags(baseline.tags, tags)) {
      return;
    }

    final promoted = await _promotePendingEntry(
      entry.id,
      hasContent: title.trim().isNotEmpty || body.trim().isNotEmpty,
    );
    if (!promoted) return;

    try {
      await coordinator.saveEntry(
        entryId: entry.id,
        bumpVersion: bumpVersion,
        applyDelta: (base) => base.copyWith(
          title: title,
          body: body,
          tags: tags,
          bumpVersion: false,
        ),
        onSuccess: (updated) {
          // `mounted` has to cover the notifier writes too, not just the
          // setState: both notifiers are disposed with the page, and this
          // callback can fire long after it went — leaving the page unfocuses
          // the body, which flushes unawaited while the route pops.
          if (!mounted || _selectedEntryId != entry.id) return;
          _listTitlePreview.value = updated.title;
          _listBodyPreview.value = updated.body;
          // `build` reads `_selectedEntry` only for its id and its entryDate,
          // neither of which a text edit touches. Rebuilding on every ~400ms
          // autosave re-sorted every dream and repainted the branch overlay —
          // exactly what the preview notifiers above exist to avoid.
          final needsRebuild = _selectedEntry?.entryDate != updated.entryDate;
          _selectedEntry = updated;
          if (needsRebuild) setState(() {});
        },
      );
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'DreamJournalPage',
          context: ErrorDescription('while persisting dream entry edits'),
        ),
      );
    }
  }

  /// Writes the held [_pendingEntry] to SQLite the first time it has content.
  ///
  /// Returns false when there is nothing to promote and the row is still not
  /// on disk — the caller must then skip its coordinator save, which throws
  /// when the row is missing.
  Future<bool> _promotePendingEntry(
    String entryId, {
    required bool hasContent,
  }) async {
    final pending = _pendingEntry;
    if (pending == null || pending.id != entryId || _pendingEntryOnDisk) {
      return true;
    }
    if (!hasContent) return false;
    final repo = _repoOrNull();
    if (repo == null) return false;
    // Claimed before the await so a body save and a notes save landing
    // together cannot both write this empty row, the second one on top of the
    // first's coordinator save.
    _pendingEntryOnDisk = true;
    await repo.upsertEntry(pending);
    if (mounted) ref.invalidate(allDreamEntriesProvider);
    return true;
  }

  /// Discards an unpromoted "New dream" that was never given content.
  void _dropPendingEntryIfEmpty() {
    if (_pendingEntry == null || _pendingEntryOnDisk) return;
    _pendingEntry = null;
  }

  /// Commits the editor's text, queued behind this page's other writes.
  ///
  /// [entry] is passed by callers that have already moved `_selectedEntryId`
  /// on to the incoming dream — the flush still belongs to the outgoing one.
  Future<void> _flushActiveEdits({
    bool refreshList = true,
    DreamEntry? entry,
  }) {
    return _queueWrite(
      () => _flushActiveEditsImpl(refreshList: refreshList, entry: entry),
    );
  }

  Future<void> _flushActiveEditsImpl({
    required bool refreshList,
    DreamEntry? entry,
  }) async {
    _saveTimer?.cancel();
    final target = entry ?? _selectedEntry;
    if (target == null) return;
    final entryId = target.id;
    final remoteSync = _syncOrNull();
    if (remoteSync == null) return;

    final currentBody =
        _bodyEditorKey.currentState?.currentBodyText ?? target.body;
    final pendingApplied = await remoteSync.applyPendingDreamEntryTextMerge(
      entryId: entryId,
      currentLocalText: currentBody,
    );
    if (pendingApplied != null && mounted) {
      // recordAsEdit stays false: these ops came off the remote chain and are
      // already in the character-op registry.
      _bodyEditorKey.currentState?.setBodyText(pendingApplied.body);
    }

    await _persistEntryEdits(
      entry: target,
      title: _titleController.text,
      body:
          _bodyEditorKey.currentState?.currentBodyText ??
          pendingApplied?.body ??
          target.body,
      bumpVersion: true,
    );

    // The local write above has already landed and the outbox retries the
    // upload, so a network failure here must not abort the caller — most of
    // them are selection changes and teardowns whose setState would never run.
    try {
      await remoteSync.flushDocument(
        FirestoreCollections.dreamEntries,
        entryId,
      );
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'DreamJournalPage',
          context: ErrorDescription('while uploading dream entry edits'),
        ),
      );
    }

    // Unconditional, not hung off the write above — see [_persistEntryEdits].
    if (refreshList && mounted) ref.invalidate(allDreamEntriesProvider);
  }

  void _scheduleNotesSave() {
    // Bound to the showing dream for the same reason as [_scheduleBodySave].
    final entryId = _selectedEntry?.id;
    _notesSaveTimer?.cancel();
    _notesSaveTimer = Timer(_localSaveDebounce, () {
      if (_selectedEntry?.id != entryId) return;
      unawaited(
        _queueWrite(() async {
          if (_selectedEntry?.id != entryId) return;
          await _saveNotes(bumpVersion: false);
        }),
      );
    });
  }

  void _handleNotesChanged(String value) {
    applyListEditing(
      controller: _notesController,
      previousText: _lastNotesText,
    );
    _lastNotesText = _notesController.text;
    _scheduleNotesSave();
  }

  KeyEventResult _handleNotesKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.tab) {
      final outdent = HardwareKeyboard.instance.isShiftPressed;
      if (handleListTab(controller: _notesController, outdent: outdent)) {
        // Route through the same handler typing uses so the edit gets
        // saved and _lastNotesText stays in sync for the next keystroke.
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

  Future<void> _saveNotes({
    required bool bumpVersion,
    DreamEntry? entry,
  }) async {
    final target = entry ?? _selectedEntry;
    final coordinator = _coordinatorOrNull();
    final repo = _repoOrNull();
    if (target == null || coordinator == null || repo == null) return;

    final notesText = _notesController.text;
    final stored = await repo.getEntry(target.id);
    final baseline = stored ?? target;
    if ((baseline.notes ?? '') == notesText) return;

    final promoted = await _promotePendingEntry(
      target.id,
      hasContent: notesText.trim().isNotEmpty,
    );
    if (!promoted) return;

    // [DreamWriteCoordinator.saveEntry] throws when the row is gone (a purge,
    // a restore, an import that rewrites the table), and the repository can
    // throw on a locked database. Every caller awaits this, so an escaping
    // error aborted the selection change, the create, the delete or the Back
    // gesture that started it, *before* its setState — the page simply did
    // nothing, with nothing shown to the user.
    try {
      await coordinator.saveEntry(
        entryId: target.id,
        bumpVersion: bumpVersion,
        applyDelta: (base) =>
            base.copyWith(notes: notesText, bumpVersion: false),
        onSuccess: (updated) {
          if (!mounted || _selectedEntryId != target.id) return;
          setState(() => _selectedEntry = updated);
        },
      );
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'DreamJournalPage',
          context: ErrorDescription('while persisting dream notes'),
        ),
      );
    }
  }

  Future<void> _flushNotes({DreamEntry? entry}) {
    _notesSaveTimer?.cancel();
    return _queueWrite(() => _saveNotes(bumpVersion: true, entry: entry));
  }

  bool _sameTags(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<void> _selectEntry(DreamEntry entry) async {
    if (_selectedEntryId == entry.id) return;
    // Claimed before the awaits below, which include a Firestore round-trip.
    // Leaving `_selectedEntryId` null for that whole window let the
    // auto-select in [build] and a user tap on another row both pass their
    // `== null` guard, so the last setState to land won — which could be the
    // auto-select, discarding the row the user actually tapped.
    final outgoing = _selectedEntry;
    final claimed = entry.id;
    _selectedEntryId = claimed;
    await _flushActiveEdits(entry: outgoing);
    await _flushNotes(entry: outgoing);
    if (!mounted || _selectedEntryId != claimed) return;
    _saveTimer?.cancel();
    _notesSaveTimer?.cancel();
    setState(() {
      _dropPendingEntryIfEmpty();
      _selectedEntry = entry;
      _titleController.text = entry.title;
      _notesController.text = entry.notes ?? '';
      _lastNotesText = _notesController.text;
      _listTitlePreview.value = entry.title;
      _listBodyPreview.value = entry.body;
    });
  }

  Future<void> _createEntry() async {
    final outgoing = _selectedEntry;
    await _flushActiveEdits(entry: outgoing);
    await _flushNotes(entry: outgoing);
    if (!mounted) return;

    final now = utcNow();
    final entry = DreamEntry(
      id: newId(),
      title: '',
      body: '',
      entryDate: now,
      createdAt: now,
      updatedAt: now,
    );
    // Held in memory rather than written — see [_pendingEntry]. Persisting and
    // pushing it here left a blank dream on every device, and a false "Dream
    // Logged" day on the analytics heatmap, for anyone who tapped New dream
    // and navigated away.
    setState(() {
      _dropPendingEntryIfEmpty();
      _pendingEntry = entry;
      _pendingEntryOnDisk = false;
      _selectedEntryId = entry.id;
      _selectedEntry = entry;
      _titleController.text = '';
      _notesController.text = '';
      _lastNotesText = '';
      _listTitlePreview.value = '';
      _listBodyPreview.value = '';
    });
    _titleFocusNode.requestFocus();
  }

  Future<void> _deleteEntry(DreamEntry entry) async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Delete dream?',
      message: 'This dream will be moved to trash.',
    );
    if (!confirmed || !mounted) return;

    if (_selectedEntryId == entry.id) {
      await _flushActiveEdits();
      await _flushNotes();
      if (!mounted) return;
    }
    // A "New dream" that never got content was never written, so there is
    // nothing to soft-delete and no tombstone to push.
    final wasPending = _pendingEntry?.id == entry.id && !_pendingEntryOnDisk;
    setState(() {
      if (_pendingEntry?.id == entry.id) {
        _pendingEntry = null;
        _pendingEntryOnDisk = false;
      }
      if (!wasPending) _deletedEntryStamps[entry.id] = utcNow();
      if (_selectedEntryId == entry.id) {
        _selectedEntryId = null;
        _selectedEntry = null;
        _titleController.clear();
        _notesController.clear();
        _lastNotesText = '';
        _listTitlePreview.value = '';
        _listBodyPreview.value = '';
      }
    });

    if (wasPending) return;
    final repo = _repoOrNull();
    if (repo == null) return;
    // Push the row the delete actually produced, not one rebuilt from the
    // list's snapshot: `copyWith` bumps *that snapshot's* version, and
    // whenever it lagged disk the tombstone went out at a version Firestore
    // had already passed. The next device to pull read the tombstone as the
    // loser, ignored the delete, and pushed its own higher-versioned live
    // document back — resurrecting the dream everywhere. Reading the row back
    // after [DreamRepository.softDeleteEntry] (which now bumps the version
    // itself) keeps the pushed tombstone monotonic by construction.
    await repo.softDeleteEntry(entry.id);
    final tombstone = await repo.getEntry(entry.id);
    if (tombstone != null) {
      _deletedEntryStamps[entry.id] = tombstone.updatedAt;
      _syncOrNull()?.pushDreamEntryNow(tombstone);
    }
    if (mounted) ref.invalidate(allDreamEntriesProvider);
  }

  Future<void> _changeEntryDate(BuildContext buttonContext) async {
    final entry = _selectedEntry;
    if (entry == null) return;
    await _flushActiveEdits();
    // The sticky note's debounce stays armed across the popover's lifetime, so
    // without this its save could read its baseline before the date write and
    // land after it, writing the *old* entryDate back. entryDate is the list's
    // primary sort key, so the row visibly snapped back into its old place.
    await _flushNotes();
    if (!mounted || !buttonContext.mounted) return;

    final accent = Theme.of(context).colorScheme.primary;
    setState(() => _isDatePickerOpen = true);
    DateTime? picked;
    try {
      picked = await showContextualPopover<DateTime>(
        context: context,
        buttonContext: buttonContext,
        width: 500,
        height: 380,
        accentColor: accent,
        builder: (ctx) => DateTimeSelectorPopover(
          initialDateTime: entry.entryDate.toLocal(),
          accentColor: accent,
        ),
      );
    } finally {
      // Left set by a throwing builder or route, the date pill would render in
      // its active state for the life of the page.
      if (mounted) setState(() => _isDatePickerOpen = false);
    }
    final chosen = picked;
    if (!mounted || chosen == null) return;

    // A "New dream" that is still held in memory keeps its date there too;
    // the coordinator save below needs the row to exist in SQLite.
    if (_pendingEntry?.id == entry.id && !_pendingEntryOnDisk) {
      final moved = _pendingEntry!.copyWith(
        entryDate: chosen.toUtc(),
        bumpVersion: false,
      );
      setState(() {
        _pendingEntry = moved;
        if (_selectedEntryId == entry.id) _selectedEntry = moved;
      });
      return;
    }

    // Routed through the coordinator like every other field edit, so it is
    // ordered against the page's other writes instead of racing them.
    // `saveRemote` re-reads and uploads the row, so no explicit push is needed.
    final coordinator = _coordinatorOrNull();
    if (coordinator == null) return;
    try {
      await _queueWrite(
        () => coordinator.saveEntry(
          entryId: entry.id,
          bumpVersion: true,
          applyDelta: (base) =>
              base.copyWith(entryDate: chosen.toUtc(), bumpVersion: false),
          onSuccess: (updated) {
            if (!mounted || _selectedEntryId != entry.id) return;
            setState(() => _selectedEntry = updated);
          },
        ),
      );
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'DreamJournalPage',
          context: ErrorDescription('while changing the dream entry date'),
        ),
      );
    }
    if (mounted) ref.invalidate(allDreamEntriesProvider);
  }

  Future<void> _showEntryStatistics(DreamEntry entry) async {
    // The row hands over whatever the list last loaded, and the title, body
    // and notes boxes all save on a debounce — so opening statistics straight
    // after typing showed the previous text. Flush what is on screen, then
    // re-read the stored entry, and the dialog reports what the user sees.
    if (_selectedEntryId == entry.id) {
      await _flushNotes();
      await _flushActiveEdits();
      if (!mounted) return;
    }
    final fresh = await _repoOrNull()?.getEntry(entry.id) ?? entry;
    if (!mounted) return;

    final wordCount = ref.read(analyticsServiceProvider).countWords(fresh.body);
    unawaited(
      showVoyagerDialog<void>(
        context: context,
        builder: (context) =>
            DreamStatisticsDialog(entry: fresh, wordCount: wordCount),
      ),
    );
  }

  Future<void> _persistSplitWidth(double? width) async {
    final settingsRepo = ref.read(settingsRepositoryProvider);
    final settings = await settingsRepo.getSettings();
    if (settings.dreamSplitWidth == width) return;
    await settingsRepo.saveSettings(
      width == null
          ? settings.copyWith(clearDreamSplitWidth: true)
          : settings.copyWith(dreamSplitWidth: width),
    );
    ref.invalidate(settingsProvider);
  }

  /// Re-seeds the open dream from a freshly-pulled row.
  ///
  /// A live-sync pull writes the remote body, title and notes straight into
  /// SQLite whenever `isDocumentEditing` is false — and that flag is driven by
  /// `_bodyFocusNode` alone, so it is false the entire time the user is in the
  /// sticky note, in the title, or simply has the dream open and idle. Nothing
  /// read that row back into the controllers, so the editor kept its pre-pull
  /// text and the next keystroke wrote it over the remote change through
  /// [_persistEntryEdits] — silently reverting it, with nothing surfaced.
  void _reconcileSelectedEntryFromProvider(List<DreamEntry> entries) {
    final id = _selectedEntryId;
    if (id == null) return;
    // A held "New dream" has no row to reconcile against.
    if (_pendingEntry?.id == id) return;
    // Never re-seed a field the user is currently in, and never race a write
    // this page has already started or has queued behind a debounce.
    if (_bodyFocusNode.hasFocus ||
        _titleFocusNode.hasFocus ||
        _notesFocusNode.hasFocus) {
      return;
    }
    if (_pendingWrites > 0 ||
        (_saveTimer?.isActive ?? false) ||
        (_notesSaveTimer?.isActive ?? false)) {
      return;
    }

    final fresh = entries.cast<DreamEntry?>().firstWhere(
      (entry) => entry!.id == id,
      orElse: () => null,
    );
    final current = _selectedEntry;
    if (fresh == null || current == null) return;

    // Older, or equal-but-not-newer, revisions are ignored.
    if (fresh.version < current.version) return;
    if (fresh.version == current.version &&
        !fresh.updatedAt.isAfter(current.updatedAt)) {
      return;
    }
    if (fresh.title == current.title &&
        fresh.body == current.body &&
        (fresh.notes ?? '') == (current.notes ?? '') &&
        fresh.entryDate == current.entryDate) {
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _selectedEntryId != id) return;
      if (_bodyFocusNode.hasFocus ||
          _titleFocusNode.hasFocus ||
          _notesFocusNode.hasFocus) {
        return;
      }
      setState(() {
        _selectedEntry = fresh;
        _titleController.text = fresh.title;
        _notesController.text = fresh.notes ?? '';
        _lastNotesText = _notesController.text;
        _listTitlePreview.value = fresh.title;
        _listBodyPreview.value = fresh.body;
      });
      // recordAsEdit, because this text reaches the editor by a route the
      // character-op session knows nothing about — a non-CRDT LWW pull, an
      // outbox replay, an import.
      _bodyEditorKey.currentState?.setBodyText(fresh.body, recordAsEdit: true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final entriesAsync = ref.watch(allDreamEntriesProvider);
    final settings = ref.watch(settingsProvider).valueOrNull;
    if (!_appliedSavedWidth && settings != null) {
      _splitWidth = settings.dreamSplitWidth;
      _appliedSavedWidth = true;
    }
    final accent = Theme.of(context).colorScheme.primary;
    final petalColor = Color(settings?.petalColor ?? 0xFFE6A4B4);
    final minorPetalColors = (settings?.minorPetalColors ?? const <int>[])
        .map(Color.new)
        .toList();

    return Stack(
      children: [
        Positioned.fill(
          child: DreamBranchOverlay(
            color: petalColor,
            minorColors: minorPetalColors,
          ),
        ),
        entriesAsync.when(
          data: (entries) {
            // Drop anything deleted here that the provider hasn't caught up
            // with yet, and let go of ids it has — see [_deletedEntryStamps].
            _deletedEntryStamps.removeWhere((id, stamp) {
              final row = entries.cast<DreamEntry?>().firstWhere(
                (entry) => entry!.id == id,
                orElse: () => null,
              );
              // Gone (the delete landed), or a revision newer than the
              // tombstone came back (restored on another device) — either way
              // this page has nothing left to hide.
              return row == null || row.updatedAt.isAfter(stamp);
            });

            // The unpromoted "New dream" is merged in here rather than being
            // written to SQLite; once it has been promoted it stays merged
            // until the provider hands the row back, so it doesn't flicker out
            // between the write and the refresh.
            final pending = _pendingEntry;
            final pendingPersisted =
                pending != null &&
                entries.any((entry) => entry.id == pending.id);
            if (pendingPersisted) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted || _pendingEntry?.id != pending.id) return;
                setState(() {
                  _pendingEntry = null;
                  _pendingEntryOnDisk = false;
                });
              });
            }

            final sorted = sortDreamEntriesNewestFirst([
              if (pending != null && !pendingPersisted) pending,
              ...(_deletedEntryStamps.isEmpty
                  ? entries
                  : entries.where(
                      (entry) => !_deletedEntryStamps.containsKey(entry.id),
                    )),
            ]);

            _reconcileSelectedEntryFromProvider(entries);

            if (_selectedEntryId == null && sorted.isNotEmpty) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted && _selectedEntryId == null) {
                  unawaited(_selectEntry(sorted.first));
                }
              });
            }
            return LayoutBuilder(
              builder: (context, constraints) {
                final totalWidth = constraints.maxWidth;
                final storedListWidth =
                    _splitWidth ??
                    DreamSplitLayout.defaultListWidth(totalWidth);
                // While dragging, storedListWidth is already soft-bounded
                // (see onDragUpdate below) — re-clamping here would cancel
                // the rubber-band out before it ever reaches the screen.
                final listWidth = _splitDragging
                    ? storedListWidth
                    : DreamSplitLayout.clampListWidth(
                        storedListWidth,
                        totalWidth,
                      );
                // Side by side in the desktop window; one at a time on a
                // phone, where the 35/65 split would leave the zen editor
                // about 230dp wide.
                final compact = context.isCompactWidth;
                final showList = !compact || !_compactShowingEditor;
                final showEditor = !compact || _compactShowingEditor;

                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (showList)
                      AnimatedContainer(
                        duration: _splitDragging
                            ? Duration.zero
                            : const Duration(milliseconds: 260),
                        curve: VoyagerMotion.reduced(context)
                            ? Curves.easeOut
                            : VoyagerSpring.moveCurve,
                        width: compact ? totalWidth : listWidth,
                        child: _buildEntryList(sorted),
                      ),
                    if (!compact)
                      ResizablePaneDivider(
                        onDragStart: () {
                          _dragStartWidth =
                              _splitWidth ??
                              DreamSplitLayout.defaultListWidth(totalWidth);
                          setState(() => _splitDragging = true);
                        },
                        onDragUpdate: (totalDelta) {
                          final start =
                              _dragStartWidth ??
                              DreamSplitLayout.defaultListWidth(totalWidth);
                          setState(() {
                            // Soft-bounded while the drag is live — tracks the
                            // pointer 1:1 but resists past the real bounds
                            // instead of stopping dead.
                            _splitWidth = DreamSplitLayout.dragClampListWidth(
                              start + totalDelta,
                              totalWidth,
                            );
                          });
                        },
                        onDragEnd: () {
                          // Hard-clamp back to the real bound now that the drag
                          // has ended; the spring-curved AnimatedContainer
                          // around the pane carries the visual snap-back from
                          // wherever the rubber-band left it.
                          final width = _splitWidth;
                          final settled = width == null
                              ? null
                              : DreamSplitLayout.clampListWidth(
                                  width,
                                  totalWidth,
                                );
                          setState(() {
                            _splitWidth = settled;
                            _splitDragging = false;
                          });
                          unawaited(_persistSplitWidth(settled));
                        },
                        onDoubleTapReset: () {
                          setState(() => _splitWidth = null);
                          unawaited(_persistSplitWidth(null));
                        },
                      ),
                    if (showEditor)
                      Expanded(
                        child: _buildEditorArea(
                          accent: accent,
                          compact: compact,
                        ),
                      ),
                  ],
                );
              },
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('$e')),
        ),
      ],
    );
  }

  void _revealCompactEditor() {
    if (!mounted || !context.isCompactWidth || _compactShowingEditor) return;
    setState(() => _compactShowingEditor = true);
  }

  /// Returns to the dream list on the phone shell, committing in-flight edits
  /// first so leaving the editor is no more lossy than switching dreams.
  Future<void> _closeCompactEditor() async {
    await _lifecycleFlush();
    if (!mounted) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _compactShowingEditor = false);
  }

  /// Android Back, offered here before the shell treats it as leaving the
  /// section. Declines unless this page is both on screen and covering its
  /// list — it stays mounted while other sections are showing.
  bool _handleSystemBack() {
    if (!mounted || !_compactShowingEditor) return false;
    // The flag survives a resize past the breakpoint, where both panes are
    // visible again and there is nothing to go back from.
    if (!context.isCompactWidth) return false;
    if (!TickerMode.getValuesNotifier(context).value.enabled) return false;
    unawaited(_closeCompactEditor());
    return true;
  }

  Widget _buildEntryList(List<DreamEntry> entries) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Dreams',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        ),
        Expanded(
          child: entries.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'No dreams logged yet.',
                      style: Theme.of(context).textTheme.bodyMedium,
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 16),
                  itemCount: entries.length,
                  itemBuilder: (context, index) {
                    final entry = entries[index];
                    return ContextMenuRegion(
                      items: [
                        ContextMenuItem(
                          label: 'See statistics',
                          icon: PhosphorIconsRegular.chartBar,
                          onTap: () => unawaited(_showEntryStatistics(entry)),
                        ),
                        ContextMenuItem(
                          label: 'Delete',
                          icon: PhosphorIconsRegular.trash,
                          isDestructive: true,
                          onTap: () => unawaited(_deleteEntry(entry)),
                        ),
                      ],
                      child: _DreamEntryListTile(
                        entry: entry,
                        isSelected: entry.id == _selectedEntryId,
                        titlePreview: _listTitlePreview,
                        bodyPreview: _listBodyPreview,
                        onTap: () {
                          _revealCompactEditor();
                          unawaited(_selectEntry(entry));
                        },
                      ),
                    );
                  },
                ),
        ),
        // Bottom-anchored, matching the Journal page's "New entry" button —
        // the list's own action belongs at the end of the list, not stacked
        // beside its heading.
        Padding(
          padding: const EdgeInsets.all(12),
          child: GlassButton(
            onPressed: () {
              _revealCompactEditor();
              unawaited(_createEntry());
            },
            label: 'New dream',
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      ],
    );
  }

  Widget _buildEditorArea({required Color accent, required bool compact}) {
    final entry = _selectedEntry;
    if (entry == null) {
      return Center(
        child: Text(
          'Select or create a dream to begin.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      );
    }

    final local = entry.entryDate.toLocal();
    final editorColumn = Padding(
      padding: DreamSplitLayout.editorPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (compact)
            CompactBackBar(
              label: 'Dreams',
              onBack: () => unawaited(_closeCompactEditor()),
            ),
          Focus(
            onKeyEvent: (node, event) {
              if (event is! KeyDownEvent) return KeyEventResult.ignored;
              if (event.logicalKey == LogicalKeyboardKey.tab &&
                  !HardwareKeyboard.instance.isShiftPressed) {
                _bodyFocusNode.requestFocus();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: LabeledTextField(
              label: 'Title',
              controller: _titleController,
              focusNode: _titleFocusNode,
              textInputAction: TextInputAction.next,
              accentColor: accent,
              onChanged: (_) => _scheduleBodySave(),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Builder(
                builder: (buttonContext) => SelectorPill(
                  dense: false,
                  ellipsize: false,
                  isActive: _isDatePickerOpen,
                  label:
                      '${MaterialLocalizations.of(context).formatShortDate(local)}'
                      ' at ${formatTime12Hour(local)}',
                  accentColor: accent,
                  onTap: () => unawaited(_changeEntryDate(buttonContext)),
                ),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Delete dream',
                onPressed: () => unawaited(_deleteEntry(entry)),
                icon: Icon(
                  PhosphorIconsRegular.trash,
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: _DreamBodyEditor(
              key: _bodyEditorKey,
              entry: entry,
              focusNode: _bodyFocusNode,
              accentColor: accent,
              onScheduleBodySave: _scheduleBodySave,
            ),
          ),
        ],
      ),
    );

    return Stack(
      children: [
        editorColumn,
        DreamStickyNote(
          controller: _notesController,
          focusNode: _notesFocusNode,
          accentColor: accent,
          onChanged: _handleNotesChanged,
        ),
      ],
    );
  }
}

class _DreamEntryListTile extends StatelessWidget {
  const _DreamEntryListTile({
    required this.entry,
    required this.isSelected,
    required this.titlePreview,
    required this.bodyPreview,
    required this.onTap,
  });

  final DreamEntry entry;
  final bool isSelected;
  final ValueNotifier<String> titlePreview;
  final ValueNotifier<String> bodyPreview;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final local = entry.entryDate.toLocal();
    final dateLabel = MaterialLocalizations.of(context).formatShortDate(local);
    final timeLabel = formatTime12Hour(local);
    final theme = Theme.of(context);
    final titleStyle = theme.textTheme.titleSmall;
    final previewStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.78),
    );
    final dateStyle = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: VoyagerSpacing.sm,
        vertical: VoyagerSpacing.xxs,
      ),
      child: ListTile(
        dense: true,
        // Outlines the dream currently open in the reading pane.
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
                builder: (context, title, _) => Text(
                  title.isEmpty ? 'Untitled' : title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: titleStyle,
                ),
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
            else
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
            Text('$dateLabel · $timeLabel', style: dateStyle),
          ],
        ),
        onTap: onTap,
      ),
    );
  }
}

class _DreamBodyEditor extends ConsumerStatefulWidget {
  const _DreamBodyEditor({
    super.key,
    required this.entry,
    required this.focusNode,
    required this.accentColor,
    required this.onScheduleBodySave,
  });

  final DreamEntry entry;
  final FocusNode focusNode;
  final Color accentColor;
  final VoidCallback onScheduleBodySave;

  @override
  ConsumerState<_DreamBodyEditor> createState() => _DreamBodyEditorState();
}

class _DreamBodyEditorState extends ConsumerState<_DreamBodyEditor> {
  late final TextEditingController _controller;
  var _lastText = '';
  RemoteSyncService? _remoteSync;
  PendingTextMergeListener? _pendingTextMergeListener;

  String get currentBodyText => _controller.text;

  /// Replaces the body with text the user did not type.
  ///
  /// [CharacterOpSession.recordTextChange] diffs `before` against `after` but
  /// applies the resulting indices to its *own* reconstructed sequence, so
  /// `before` must equal the session's current text. Moving [_lastText] to the
  /// replacement without telling the registry breaks that: the next keystroke
  /// is then diffed against the pre-replacement string, producing ops at
  /// positions that do not exist in the session's log, and the two devices
  /// interleave characters on the next merge.
  ///
  /// Pass [recordAsEdit] whenever [body] came from somewhere the registry has
  /// not seen (an LWW pull, an outbox replay, an import). The post-merge call
  /// in [_DreamJournalPageState._flushActiveEditsImpl] leaves it false: those
  /// ops came off the remote chain and are already in the registry.
  void setBodyText(String body, {bool recordAsEdit = false}) {
    final before = _controller.text;
    if (before == body) return;
    // Assigning `_controller.text` resets the selection to offset -1 — no
    // caret at all. This runs mid-focus from the date picker and the
    // statistics dialog, where the next keystroke would land at offset 0.
    final baseOffset = _controller.selection.baseOffset;
    _controller.value = TextEditingValue(
      text: body,
      selection: TextSelection.collapsed(
        offset: TextDeltaInjector.adjustedSelection(
          selection: baseOffset,
          before: before,
          after: body,
        ),
      ),
    );
    if (recordAsEdit) {
      _remoteSync?.recordDreamTextChange(
        entryId: widget.entry.id,
        before: before,
        after: body,
      );
    }
    _lastText = body;
  }

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.entry.body);
    _lastText = _controller.text;
    widget.focusNode.addListener(_handleFocusChanged);
    // _handleKey is installed by TagHighlightedTextField (see its onKeyEvent
    // param) rather than assigned here: the tag completion popup owns
    // focusNode.onKeyEvent so it can claim the arrow keys, and chains through
    // to this handler for everything it doesn't use.
    final remoteSync = ref.read(remoteSyncServiceProvider);
    _remoteSync = remoteSync;
    // Dropping this future left the character-op session unseeded while the
    // editor was already taking keystrokes: `recordDreamTextChange` then opens
    // a fresh session from the on-screen text, which re-seeds ops at the same
    // fractional positions with different ids — the collision that doubles
    // every character on merge. Surface the failure rather than losing it in
    // the zone.
    unawaited(
      remoteSync
          .prepareEditingSession(
            collection: FirestoreCollections.dreamEntries,
            documentId: widget.entry.id,
            initialText: _controller.text,
          )
          .catchError((Object error, StackTrace stack) {
            FlutterError.reportError(
              FlutterErrorDetails(
                exception: error,
                stack: stack,
                library: 'DreamJournalPage',
                context: ErrorDescription(
                  'while preparing the dream editing session',
                ),
              ),
            );
          }),
    );
    remoteSync.setDocumentEditing(
      collection: FirestoreCollections.dreamEntries,
      documentId: widget.entry.id,
      isEditing: widget.focusNode.hasFocus,
    );
    _pendingTextMergeListener = _handlePendingTextMerge;
    remoteSync.addPendingTextMergeListener(
      collection: FirestoreCollections.dreamEntries,
      documentId: widget.entry.id,
      listener: _pendingTextMergeListener!,
    );
  }

  void _handlePendingTextMerge(PendingTextMergeEvent event) {
    if (!mounted || widget.entry.id != event.documentId) return;
    if (!widget.focusNode.hasFocus) return;

    final before = _controller.text;
    final merged = TextDeltaInjector.injectRemoteDelta(
      localText: before,
      oldRemoteText: event.previousRemoteText,
      newRemoteText: event.remoteText,
    );
    if (merged == before) return;

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
    widget.onScheduleBodySave();
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant _DreamBodyEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry.id == widget.entry.id) return;

    final remoteSync = _remoteSync;
    if (remoteSync != null) {
      if (_pendingTextMergeListener != null) {
        remoteSync.removePendingTextMergeListener(
          collection: FirestoreCollections.dreamEntries,
          documentId: oldWidget.entry.id,
          listener: _pendingTextMergeListener!,
        );
      }
      remoteSync.setDocumentEditing(
        collection: FirestoreCollections.dreamEntries,
        documentId: oldWidget.entry.id,
        isEditing: false,
      );
    }

    _controller.text = widget.entry.body;
    _lastText = _controller.text;

    if (remoteSync != null) {
      _pendingTextMergeListener = _handlePendingTextMerge;
      remoteSync.addPendingTextMergeListener(
        collection: FirestoreCollections.dreamEntries,
        documentId: widget.entry.id,
        listener: _pendingTextMergeListener!,
      );
      unawaited(
        remoteSync
            .prepareEditingSession(
              collection: FirestoreCollections.dreamEntries,
              documentId: widget.entry.id,
              initialText: _controller.text,
            )
            .catchError((Object error, StackTrace stack) {
              FlutterError.reportError(
                FlutterErrorDetails(
                  exception: error,
                  stack: stack,
                  library: 'DreamJournalPage',
                  context: ErrorDescription(
                    'while preparing the dream editing session',
                  ),
                ),
              );
            }),
      );
      remoteSync.setDocumentEditing(
        collection: FirestoreCollections.dreamEntries,
        documentId: widget.entry.id,
        isEditing: widget.focusNode.hasFocus,
      );
    }
    setState(() {});
  }

  @override
  void dispose() {
    final remoteSync = _remoteSync;
    if (remoteSync != null) {
      if (_pendingTextMergeListener != null) {
        remoteSync.removePendingTextMergeListener(
          collection: FirestoreCollections.dreamEntries,
          documentId: widget.entry.id,
          listener: _pendingTextMergeListener!,
        );
      }
      remoteSync.setDocumentEditing(
        collection: FirestoreCollections.dreamEntries,
        documentId: widget.entry.id,
        isEditing: false,
      );
    }
    widget.focusNode.removeListener(_handleFocusChanged);
    _controller.dispose();
    super.dispose();
  }

  void _handleFocusChanged() {
    final remoteSync = _remoteSync;
    if (remoteSync == null) return;
    remoteSync.setDocumentEditing(
      collection: FirestoreCollections.dreamEntries,
      documentId: widget.entry.id,
      isEditing: widget.focusNode.hasFocus,
    );
  }

  void _handleChanged(String value) {
    applyListEditing(controller: _controller, previousText: _lastText);

    final before = _lastText;
    _lastText = _controller.text;
    _remoteSync?.recordDreamTextChange(
      entryId: widget.entry.id,
      before: before,
      after: _controller.text,
    );
    widget.onScheduleBodySave();
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.tab) {
      final outdent = HardwareKeyboard.instance.isShiftPressed;
      if (handleListTab(controller: _controller, outdent: outdent)) {
        // Tab/Backspace mutate the controller directly, bypassing
        // TextField.onChanged — route through the same handler typing uses
        // so the edit gets saved and the CRDT character-op session (which
        // assumes `before` always matches its actual current text) doesn't
        // silently desync.
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
    return TagHighlightedTextField(
      controller: _controller,
      focusNode: widget.focusNode,
      tagScope: TagScope.dream,
      onKeyEvent: _handleKey,
      expands: true,
      keyboardType: TextInputType.multiline,
      cursorColor: widget.accentColor,
      onChanged: _handleChanged,
      hintText: 'Describe your dream... use #tags to mark themes',
      decoration: const InputDecoration(
        filled: false,
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
      ),
    );
  }
}

/// Per-dream facts, shown from the entry list's right-click menu: when it was
/// logged, how much was written, and which themes it was tagged with.
class DreamStatisticsDialog extends StatelessWidget {
  const DreamStatisticsDialog({
    super.key,
    required this.entry,
    required this.wordCount,
  });

  final DreamEntry entry;
  final int wordCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final local = entry.entryDate.toLocal();
    final logged =
        '${MaterialLocalizations.of(context).formatFullDate(local)}'
        ' at ${formatTime12Hour(local)}';

    return AlertDialog(
      title: Text(entry.title.isEmpty ? 'Untitled' : entry.title),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _StatLine(label: 'Logged', value: logged),
            _StatLine(label: 'Words', value: '$wordCount'),
            _StatLine(
              label: 'Characters',
              value: '${entry.body.characters.length}',
            ),
            _StatLine(
              label: 'Notes',
              value: (entry.notes ?? '').trim().isEmpty
                  ? 'None'
                  : entry.notes!.trim(),
            ),
            const SizedBox(height: 12),
            Text('Themes', style: theme.textTheme.labelMedium),
            const SizedBox(height: 6),
            if (entry.tags.isEmpty)
              Text(
                'No #tags in this dream yet.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              )
            else
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [for (final tag in entry.tags) TagChip(tag: tag)],
              ),
          ],
        ),
      ),
      actions: [
        GlassButton(
          onPressed: () => Navigator.of(context).pop(),
          label: 'Close',
          dense: true,
        ),
      ],
    );
  }
}

class _StatLine extends StatelessWidget {
  const _StatLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
              ),
            ),
          ),
          Expanded(child: Text(value, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}
