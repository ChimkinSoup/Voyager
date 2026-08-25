# Search Page — Code Audit

**Scope:** `lib/features/search/search_page.dart`, `lib/features/search/search_entry_save_helper.dart`,
`lib/domain/services/search_service.dart`, `lib/core/widgets/search_highlight_text.dart`, and the
collaborators they drive: `JournalWriteCoordinator`, `RemoteSyncService.forceOverwriteJournalEntryText`,
`CharacterOpSessionRegistry`, `DriftJournalRepository`, and the journal providers in `lib/app/providers.dart`.

**Clarified during the audit (treated as settled, not filed as bugs):**
- An empty query listing every entry is the intended "browse-all" state.
- Every `#tag` in the query is intended to filter (AND). Filed as **[M-2]**.
- Tag filtering is intended to be case-insensitive, like keyword matching. Filed as **[M-3]**.

**Severity key:** Critical = silent data loss or cross-device corruption · High = incorrect persisted
state or a user-visible stall · Medium = wrong results / stale UI · Low = narrow correctness gap.

---

## Critical

### [Critical] Opening a search result and closing it — with no edit — rewrites the entry and wipes its CRDT history

- **Location:** `lib/features/search/search_page.dart:365-375` (`dispose`), `:388-412` (`_save`), `:344-345`; `lib/features/search/search_entry_save_helper.dart:36-68`
- **Issue:** `dispose()` calls `_save()` whenever `_isSaved` is false, and `_save()` has **no dirty check** — it saves the controller contents unconditionally. The dialog is `barrierDismissible: true` (`voyager_dialog.dart:11`), so a mis-tap on the barrier is enough. Every open/close therefore:
  1. bumps `version` and stamps `updatedAt = now` on a row nothing changed (`JournalEntry.copyWith` always restamps `updatedAt`, `journal_models.dart:138`);
  2. runs `remoteSync.forceOverwriteJournalEntryText`, which **deletes the entry's entire remote `sync_operations` log** and re-seeds it from scratch (`remote_sync_service.dart:499-517`);
  3. re-uploads the whole document.

  It also mutates fields the user never touched. `initState` coerces defaults at `:344-345` — `_mood = _entry.mood ?? kDefaultMood` and `_weatherIcon = _entry.weatherIcon ?? 'sunny'` — and `_save` writes those back. An entry with a null mood (the pre-v85 rows that `journal_models.dart:108-111` explicitly says still exist) silently acquires mood `5` and weather `sunny` just by being viewed. Combined with **[C-3]**, browsing search results is enough to make this device unconditionally outrank every other device on those entries.
- **Fix:** Gate the save on actual dirtiness. Snapshot the baseline in `initState`, compare against it, and make `dispose` (and `_lifecycleFlush`) no-ops when nothing changed.

  ```dart
  // in _SearchEntryDialogState
  late String _baselineTitle;
  late String _baselineBody;
  late int? _baselineMood;
  late String? _baselineWeather;
  late DateTime _baselineEntryDate;
  late String _baselineJournalId;

  @override
  void initState() {
    super.initState();
    // ... existing setup ...
    _baselineTitle = _entry.title;
    _baselineBody = _entry.body;
    _baselineMood = _entry.mood;
    _baselineWeather = _entry.weatherIcon;
    _baselineEntryDate = _entry.entryDate;
    _baselineJournalId = _entry.journalId;
  }

  bool get _isDirty =>
      _titleController.text.trim() != _baselineTitle.trim() ||
      _bodyController.text.trimRight() != _baselineBody.trimRight() ||
      _mood != _baselineMood ||
      _weatherIcon != _baselineWeather ||
      _entry.entryDate != _baselineEntryDate ||
      _entry.journalId != _baselineJournalId;

  Future<void> _save() async {
    if (!_isDirty) return;          // nothing to persist, nothing to publish
    // ... existing body ...
  }
  ```

  Keep `_mood`/`_weatherIcon` coerced for *display* only; a coerced default must not count as an edit. If those defaults have to be persisted, do it in a one-time migration, not on every view.

### [Critical] `_isSaved` is a one-way latch — a lifecycle flush makes every later edit unsavable

- **Location:** `lib/features/search/search_page.dart:307`, `:366-369`, `:389`, `:414-416`
- **Issue:** `_save()` sets `_isSaved = true` on its first line and **nothing ever resets it**. `dispose()` only saves `if (!_isSaved)`. `_lifecycleFlush()` calls `_save()`, and it is invoked by `PendingFlushRegistry.flushAll()` from two very ordinary triggers:
  - `voyager_app.dart:69-78` — `AppLifecycleState.inactive`, which on Windows desktop fires **every time the window loses focus** (alt-tab, clicking another app);
  - `app_shell.dart:253-257` — any shell branch change.

  Reproduction: open a search result → alt-tab away and back (`_isSaved` becomes `true`) → type a paragraph → press Escape or **Close**. `dispose()` sees `_isSaved == true`, skips the save, and the paragraph is gone. Neither Close nor Escape has any other save path, so the loss is silent and total.
- **Fix:** The flag conflates "a save has ever run" with "the current buffer is persisted". Delete it and derive from `_isDirty` (see **[C-1]**), refreshing the baselines after each successful save so a later edit re-arms:

  ```dart
  Future<void> _save() async {
    if (!_isDirty) return;
    // ... existing save ...
    if (updated != null) {
      _baselineTitle = updated.title;
      _baselineBody = updated.body;
      _baselineMood = updated.mood;
      _baselineWeather = updated.weatherIcon;
      _baselineEntryDate = updated.entryDate;
      _baselineJournalId = updated.journalId;
      if (mounted) setState(() => _entry = updated);
      widget.onSaved(updated);
    }
  }

  @override
  void dispose() {
    PendingFlushRegistry.instance.unregister(_lifecycleFlushCallback);
    if (_isDirty) unawaited(_save());     // was: if (!_isSaved)
    // ...
  }
  ```

  If a flag is still wanted as an in-flight guard, it must be reset in the save future's `whenComplete`, never left latched.

### [Critical] `forceOverwriteJournalEntryText` publishes a version the local row never receives

- **Location:** `lib/core/sync/remote_sync_service.dart:499-517` (specifically `:513`), reached from `lib/features/search/search_entry_save_helper.dart:62-68`
- **Issue:** The last step is `_uploadJournalEntryNow(entry, bumpVersion: true)`, which uploads `entry.copyWith(bumpVersion: true)` — version `N+1` — but **never writes that row back to SQLite**. The local row stays at `N`. This is precisely the failure mode documented on that method at `remote_sync_service.dart:2398-2408`: a remote copy that unconditionally outranks the row it came from, so `remoteVersionWins` (`firestore_document_mapper.dart:96`) resolves every subsequent pull in the remote's favour.

  Concrete loss: save an entry from Search (local `N`, remote `N+1`) → go offline → edit that entry in the journal editor, whose autosave path uploads at an *unchanged* version (`_uploadJournalEntryNow(latest)` with `bumpVersion: false`, `remote_sync_service.dart:620-624`) so the local row is still `N` → reconnect. The pull sees remote `N+1 > N`, `metadataRemoteWins` is true, and the offline title / mood / `entryDate` / `journalId` are reverted (`firestore_document_mapper.dart:1162-1185`). Because **[C-1]** fires this path on a mere open/close, the desync is created by browsing, not just by editing.
- **Fix:** Persist exactly what is published. Bump once, write it locally, then upload without a second bump:

  ```dart
  Future<JournalEntry> forceOverwriteJournalEntryText(JournalEntry entry) async {
    final published = entry.copyWith(bumpVersion: true);
    await _journalRepository.upsertEntry(published, recordLocalActivity: false);

    await _syncRepository.deleteOperationsForDocument(published.id);
    _charOpRegistry.resetSession(
      collection: FirestoreCollections.journalEntries,
      documentId: published.id,
      clientId: deviceId,
      text: '',
    );
    _charOpRegistry.recordTextChange(
      collection: FirestoreCollections.journalEntries,
      documentId: published.id,
      clientId: deviceId,
      before: '',
      after: published.body,
    );
    await _uploadJournalEntryNow(published);   // no second bump
    _charOpRegistry.removeSession(FirestoreCollections.journalEntries, published.id);
    return published;
  }
  ```

  Return `published` so `SearchEntrySaveHelper.saveEntry` hands the *published* row to `onSaved`, keeping `_localUpdates` and the row on disk on the same version.

### [Critical] The overwrite destroys a concurrent editing session's un-uploaded char-ops

- **Location:** `lib/core/sync/remote_sync_service.dart:501-516`; `lib/domain/services/character_op_session.dart:290-302`
- **Issue:** `resetSession` **unconditionally replaces** whatever session exists for that document (`_sessions[k] = CharacterOpSession(...)`, `:296-297`) — it does not check for one, unlike `ensureSession`'s `putIfAbsent` at `:231`. If the same entry is open in the journal editor, that editor's live session (seeded by `prepareEditingSession`, including the sequence-counter lift described at `remote_sync_service.dart:700-716`) is thrown away along with **all of its pending, not-yet-uploaded operations**: `_uploadCrdtDocumentNow`'s `takePendingOps` at `:2383` then drains the *blank* replacement session, so those ops are never uploaded and never restored. The trailing `removeSession` at `:514-517` deletes the session entirely, so the editor's next `recordTextChange` re-creates a fresh chain via `ensureSession` with no history and a sequence counter restarting at 0 — sorting its ops *before* the surviving chain on replay.
- **Fix:** Refuse to force-overwrite a document that has a live session, and route the wholesale rewrite through the existing rebase path instead:

  ```dart
  Future<JournalEntry> forceOverwriteJournalEntryText(JournalEntry entry) async {
    final live = _charOpRegistry.session(FirestoreCollections.journalEntries, entry.id);
    if (live != null) {
      // Another surface owns this document's chain — rebase onto it rather
      // than wiping it, exactly as conflict resolution does.
      final published = entry.copyWith(bumpVersion: true);
      await _journalRepository.upsertEntry(published, recordLocalActivity: false);
      await _rebaseCharOpsOnLiveChain(
        collection: FirestoreCollections.journalEntries,
        documentId: published.id,
        target: published.body,
      );
      await _uploadJournalEntryNow(published);
      return published;
    }
    // ... wipe-and-reseed path (see [C-3]) ...
  }
  ```

  At minimum, guard the trailing `removeSession` so it only removes a session this call created.

---

## High

### [High] Delete pushes a tombstone built from a stale in-memory snapshot — entries resurrect

- **Location:** `lib/features/search/search_page.dart:83-86`
- **Issue:** This is the exact bug already diagnosed and fixed on the journal page; see the comment at `journal_page.dart:1744-1755`. `softDeleteEntry` reads the current row and bumps its version (`drift_repositories.dart:254-259`), but the pushed tombstone is built independently from the widget's `entry`:

  ```dart
  await ref.read(journalRepositoryProvider).softDeleteEntry(entry.id);
  ref.read(remoteSyncServiceProvider)
     .pushJournalEntryNow(entry.copyWith(deletedAt: utcNow()));
  ```

  `entry` comes from the `_localUpdates`-merged provider list (`:160-172`), which lags disk whenever an in-flight save hasn't reported back — and after **[M-5]** it can silently never report back. When it lags, the tombstone goes out at a version Firestore has already passed, the next device to pull reads it as the loser, and pushes its own higher-versioned live document back, **resurrecting the entry on every device**. The pushed payload also still carries the full title and body, contrary to the content-wiped-tombstone rule the rest of the sync layer follows.
- **Fix:** Read the row back after the delete and push what the write actually produced, mirroring `_softDeleteAndPushTombstone`:

  ```dart
  final repo = ref.read(journalRepositoryProvider);
  final remoteSync = ref.read(remoteSyncServiceProvider);
  await repo.softDeleteEntry(entry.id);
  final tombstone = await repo.getEntry(entry.id);
  if (tombstone != null) remoteSync.pushJournalEntryNow(tombstone);
  ```

### [High] `_changeEntryJournal` is a read-modify-write outside the write queue — lost update

- **Location:** `lib/features/search/search_page.dart:109-117`
- **Issue:** It does `repo.getEntry` → `copyWith(journalId:)` → `repo.upsertEntry` directly, bypassing `JournalWriteCoordinator`, whose entire purpose is to serialise writes per document (`journal_write_coordinator.dart:8-10`, backed by `_localSaveChains` / `_localSaveGenerations` at `remote_sync_service.dart:574-600`). Because it is outside that queue, it interleaves freely with an in-flight coordinator save for the same entry — easy to hit, since `_saveAndClose` and the Save button both fire `unawaited(_save())` and pop immediately (`:420-423`, `:641-649`), leaving the save running while the user right-clicks the row.

  Interleaving: the coordinator reads baseline `B` → `_changeEntryJournal` reads `B`, writes `B + journalId` at version `N+1` → the coordinator writes `applyDelta(B)` at version `N+1`, carrying the **old** `journalId`. The move is silently lost, at a version that now looks authoritative. The same hazard applies to `_deleteEntry` (**[H-1]**), whose `softDeleteEntry` is likewise unqueued.
- **Fix:** Route it through the coordinator so it joins the per-document chain and re-reads its baseline under the queue:

  ```dart
  final coordinator = ref.read(journalWriteCoordinatorProvider);
  JournalEntry? moved;
  await coordinator.saveEntry(
    entryId: entry.id,
    bumpVersion: true,
    applyDelta: (base) =>
        base.copyWith(journalId: targetJournalId, bumpVersion: false),
    onSuccess: (saved) => moved = saved,
  );
  if (moved == null || !mounted) return;
  ref.read(remoteSyncServiceProvider).pushJournalEntryNow(moved!);
  setState(() => _localUpdates[moved!.id] = moved!);
  _invalidateEntryCaches();
  ```

  Do the same for the delete: `await remoteSync.flushDocument(FirestoreCollections.journalEntries, entry.id)` before `softDeleteEntry`, the way `journal_page._deleteEntry` calls `_flushActiveEntryEdits` first.

### [High] Offline, the op-log wipe silently does nothing — and the reseed then corrupts the chain

- **Location:** `lib/data/remote/firestore_sync_repository.dart:335-352`, called from `lib/core/sync/remote_sync_service.dart:500`
- **Issue:** `deleteOperationsForDocument` starts with `.where('documentId', isEqualTo: ...).get()` at the default `Source.serverAndCache`. Per the contract documented at `repositories.dart:619-627`, Firestore answers reads from the local cache while offline and never fails — so with a cold or evicted cache the query returns **zero docs and the method returns 0**, leaving the remote op log fully intact. `forceOverwriteJournalEntryText` proceeds anyway: it resets the session to `''` and records one insert of the entire body, which is uploaded on top of the surviving chain. The result is exactly the duplicated/garbled text that `search_entry_save_helper.dart:57-61` claims this path exists to prevent, and the failure is invisible because the return value is discarded.
- **Fix:** Make the wipe verifiable and refuse to reseed when it isn't. Force a server read so an offline call throws rather than lying:

  ```dart
  final query = await _collection('sync_operations')
      .where('documentId', isEqualTo: documentId)
      .get(const GetOptions(source: Source.server));
  ```

  and in `forceOverwriteJournalEntryText`, wrap the wipe so a failure falls back to `_rebaseCharOpsOnLiveChain` (which composes with the existing chain instead of assuming an empty one) rather than reseeding from `''`.

### [High] Every keystroke re-scans and re-lowercases the entire corpus on the UI isolate

- **Location:** `lib/features/search/search_page.dart:145`, `:173-180`; `lib/domain/services/search_service.dart:23-26`
- **Issue:** Three costs compound per keystroke, all synchronous on the UI isolate, with no debounce anywhere:
  1. `onChanged: (_) => setState(() {})` rebuilds the whole page, including both `.when` branches and the `TagHighlightedTextField`;
  2. `mergedEntries` allocates a new `List` over **every** entry (`:160-172`) — a full pass with a map lookup per element;
  3. `searchEntries` allocates `'${entry.title} ${entry.body}'.toLowerCase()` for **every entry** (`search_service.dart:24`) — one full-body concat plus one full-body lowercase, per entry, per keystroke.

  With "browse-all" confirmed as intended, the source list is `repo.listEntries()` with no `limit` (`providers.dart:684`) — every journal entry in the database. On a few thousand entries this is megabytes of transient string allocation per character typed, and it is the dominant cost of typing in this field.
- **Fix:** Debounce the query and precompute the folded haystack once per entry-list identity, not once per keystroke.

  ```dart
  // _SearchPageState
  Timer? _queryDebounce;
  String _activeQuery = '';

  void _onQueryChanged(String _) {
    _queryDebounce?.cancel();
    _queryDebounce = Timer(const Duration(milliseconds: 150), () {
      if (mounted) setState(() => _activeQuery = _queryController.text);
    });
  }

  @override
  void dispose() {
    _queryDebounce?.cancel();   // see [M-4]
    // ...
  }
  ```

  Drive `_parseSearchQuery(_activeQuery)` from `_activeQuery`, and cache the folded text so it is rebuilt only when the entry list actually changes:

  ```dart
  List<JournalEntry>? _haystackSource;
  final Map<String, String> _haystack = {};   // entry.id -> folded "title body"

  void _rebuildHaystack(List<JournalEntry> merged) {
    if (identical(_haystackSource, merged)) return;
    _haystack
      ..clear()
      ..addEntries(merged.map(
        (e) => MapEntry(e.id, '${e.title} ${e.body}'.toLowerCase()),
      ));
    _haystackSource = merged;
  }
  ```

  Pass that map into `SearchService.searchEntries` (or move the fold into the service behind an `id -> folded` cache) so the per-keystroke work is a `contains` over precomputed strings.

---

## Medium

### [Medium] `_invalidateEntryCaches` misses two providers — the tag pool and analytics stay stale all session

- **Location:** `lib/features/search/search_page.dart:70-74`, and the duplicated inline copy at `:243-245`
- **Issue:** Both invalidate only `journalEntriesProvider`, `journalListEntriesProvider`, and `journalEntryCountsProvider`. They omit `allJournalEntriesProvider` and `journalAllEntryIdsProvider`, even though `invalidateJournalEntryProviders(ref)` exists at `providers.dart:654-658` for exactly this set, and `journal_page._refreshEntryLists` explains at `:456-459` why `allJournalEntriesProvider` must be included. Every one of these is `keepAlive`, so an un-invalidated one is stale for the rest of the app session:
  - `tagPoolProvider` folds over `allJournalEntriesProvider` (`tag_suggestions.dart:141`), so a `#tag` typed in the search dialog never enters the completion pool — **including in the search page's own query field**, which is a `TagScope.journal` field (`search_page.dart:137-143`). The user can create a tag and then be unable to autocomplete it.
  - The analytics page (`analytics_page.dart:92`) keeps showing entries deleted from Search and pre-edit bodies.
- **Fix:** Use the shared helper in both places and delete the inline copy:

  ```dart
  void _invalidateEntryCaches() => invalidateJournalEntryProviders(ref);
  ```

  and at `:243-245`, replace the three `ref.invalidate(...)` lines with `_invalidateEntryCaches();`.

### [Medium] Only the first `#tag` filters; later ones are matched as literal text

- **Location:** `lib/features/search/search_page.dart:269-282`
- **Issue:** `_parseSearchQuery` returns a single `String? tag` and its loop guard is `if (tag == null && part.startsWith('#'))`, so the second `#tag` onward falls into `keywords` and is matched with `haystack.contains('#urgent')` against title+body. `SearchService.searchEntries` already accepts `List<String>? tagFilter` and ANDs it with `.every` (`search_service.dart:10-14`), so the multi-tag capability exists and is simply never reached. Confirmed as a bug. Today `#work #urgent` returns only entries tagged `work` whose *body text* also literally contains the string `#urgent` — which coincidentally works for inline tags but silently fails for any tag that reached `tags` by another route (an import, a remote merge), and it produces spurious keyword highlighting on the `#urgent` literal.
- **Fix:** Collect every `#token`:

  ```dart
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
  ```

  and at the call site: `tagFilter: parsedQuery.tags.isEmpty ? null : parsedQuery.tags`.

### [Medium] Tag filtering is case-sensitive while keyword matching is not

- **Location:** `lib/domain/services/search_service.dart:12`
- **Issue:** `e.tags.contains(tag)` is an exact `String ==` against tags stored verbatim by `extractTags` (`journal_tags.dart:10-13`, which preserves the author's casing), whereas keyword matching folds both sides at `:16-24`. Searching `#work` therefore returns nothing for an entry tagged `#Work`, with no indication why — and the query field's own tag autocomplete will happily suggest `Work` while the filter that consumes it rejects it. Confirmed as a bug.
- **Fix:** Fold both sides at the filter site:

  ```dart
  if (tagFilter != null && tagFilter.isNotEmpty) {
    final needles = tagFilter.map((t) => t.toLowerCase()).toList();
    candidates = candidates.where((e) {
      final own = e.tags.map((t) => t.toLowerCase()).toSet();
      return needles.every(own.contains);
    }).toList();
  }
  ```

  Once **[H-4]**'s cache exists, fold the tag set into the same per-entry cache so this is not recomputed per keystroke.

### [Medium] `_deletedIds` and `_localUpdates` are never pruned and the page never unmounts

- **Location:** `lib/features/search/search_page.dart:57`, `:61`; `dispose` at `:63-68`
- **Issue:** `SearchPage` is a `StatefulShellBranch` root (`app_router.dart:33-47`), so `_SearchPageState` lives for the entire authenticated session. Neither collection is ever cleared, and `dispose` doesn't touch them.
  - `_localUpdates` retains a full `JournalEntry` — including its complete `body` — for every entry edited this session, long after the providers have caught up and the two copies are identical.
  - `_deletedIds` is a permanent hide-list. If a delete is later undone (a pull from another device that resolves in favour of the live row, or a trash restore), the entry is **invisible in Search until the app restarts**, even though it is present in the provider data.
- **Fix:** Prune both against the provider data during the merge, and cancel the debounce timer from **[H-4]** in `dispose`:

  ```dart
  final entryIndex = {for (final e in entries) e.id: e};

  _localUpdates.removeWhere((id, local) {
    final live = entryIndex[id];
    return live == null ||
        live.version > local.version ||
        (live.version == local.version && !live.updatedAt.isBefore(local.updatedAt));
  });
  _deletedIds.removeWhere((id) => !entryIndex.containsKey(id));
  ```

  Both maps are read-only for the rest of the build, so pruning here is safe; move it to a post-frame callback if you prefer not to mutate during `build`. The `_deletedIds` line also retires the optimistic hide once the provider itself stops returning the id — i.e. once the delete has actually landed.

### [Medium] Save failures are swallowed — the list keeps showing pre-edit text after a successful local write

- **Location:** `lib/features/search/search_entry_save_helper.dart:62-80`; consumed at `lib/features/search/search_page.dart:408-411`
- **Issue:** `saveEntry` returns `result` only after `forceOverwriteJournalEntryText` completes, and the `catch` at `:70-80` converts *any* throw into `return null`. But the local SQLite write already succeeded inside `coordinator.saveEntry` before that line — so when the remote step throws (network, permissions, the batch commit at `firestore_sync_repository.dart:349`), the caller sees `null`, skips `setState(() => _entry = updated)`, and **never calls `widget.onSaved`**. No `_localUpdates` entry, no provider invalidation: the search list keeps rendering the pre-edit title and body until something else refreshes it. The user's edit is on disk but invisible, which reads as "my edit was lost" — and it directly feeds **[H-1]**, where that stale `entry` is used to build a tombstone.
- **Fix:** Separate the local outcome from the remote outcome. Return the saved row as soon as the local write lands, and report the publish failure without discarding it:

  ```dart
  JournalEntry? result;
  try {
    await coordinator.saveEntry(
      entryId: baseline.id,
      bumpVersion: true,
      applyDelta: (base) => /* ... unchanged ... */,
      onSuccess: (saved) => result = saved,
    );
  } catch (error, stackTrace) {
    FlutterError.reportError(FlutterErrorDetails(
      exception: error, stack: stackTrace, library: 'SearchEntrySaveHelper',
      context: ErrorDescription('while saving entry from Search'),
    ));
    return null;   // the local write itself failed — nothing to show
  }
  if (result == null) return null;

  try {
    remoteSync.cancelDocument(FirestoreCollections.journalEntries, baseline.id);
    return await remoteSync.forceOverwriteJournalEntryText(result!);
  } catch (error, stackTrace) {
    FlutterError.reportError(FlutterErrorDetails(
      exception: error, stack: stackTrace, library: 'SearchEntrySaveHelper',
      context: ErrorDescription('while publishing entry from Search'),
    ));
    return result;   // local write succeeded; the UI must reflect it either way
  }
  ```

  The narrowed outer `try` still covers `coordinator.saveEntry`'s `StateError` for a missing row (`journal_write_coordinator.dart:47-49`), which is the one case where `null` is the right answer.

### [Medium] Context-menu actions drop their Futures — failures surface as unhandled async errors

- **Location:** `lib/features/search/search_page.dart:196-212`
- **Issue:** `ContextMenuItem.onTap` is a `VoidCallback`, so `() => _changeEntryJournal(entry, journals)` and `() => _deleteEntry(entry)` return `Future`s that nobody holds. If `softDeleteEntry`, `getEntry`, or `upsertEntry` throws — a locked database, a failed migration — the error escapes as an unhandled async exception with **no user-facing feedback at all**: the confirm dialog closes, the row stays in the list, and the user reasonably concludes the delete was rejected and tries again. There is no `try`/`catch` and no snackbar on either path.
- **Fix:** Wrap both bodies and surface the failure, and make sure a failed delete does not enter `_deletedIds`:

  ```dart
  Future<void> _deleteEntry(JournalEntry entry) async {
    // ... confirm ...
    try {
      await repo.softDeleteEntry(entry.id);
      final tombstone = await repo.getEntry(entry.id);   // see [H-1]
      if (tombstone != null) remoteSync.pushJournalEntryNow(tombstone);
    } catch (error, stackTrace) {
      FlutterError.reportError(FlutterErrorDetails(
        exception: error, stack: stackTrace, library: 'SearchPage',
        context: ErrorDescription('while deleting entry from Search'),
      ));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not delete entry.')),
        );
      }
      return;                       // do not hide a row that still exists
    }
    if (!mounted) return;
    setState(() {
      _deletedIds.add(entry.id);
      _localUpdates.remove(entry.id);
    });
    _invalidateEntryCaches();
  }
  ```

---

## Low

### [Low] `toLowerCase()` can change string length, desyncing highlight offsets from the source text

- **Location:** `lib/core/widgets/search_highlight_text.dart:172` and `:179-208`; same pattern at `:32-37`
- **Issue:** `keywordSpans` computes `final lower = text.toLowerCase();` and then applies indices found in `lower` to `text` (`text.substring(index, next)`, `text.substring(hitAt, hitAt + hitLen)`). That assumes `lower.length == text.length`, which Dart does not guarantee: `toLowerCase` applies full Unicode case mapping, and `'İ'` (U+0130) lowercases to two UTF-16 units (`i` + U+0307). One such character anywhere in a title or body shifts every subsequent index by one, so highlights land on the wrong characters — and because `lower` is *longer* than `text`, `_nextPatternIndex` can return an index at or past `text.length`, making `text.substring(...)` throw a `RangeError` that takes down the whole result list. `searchSnippet` has the same defect at `:32-37`, where `hit` is found in `collapsed.toLowerCase()` and then used to slice `collapsed`.
- **Fix:** Bail out to plain text when the fold is not length-preserving — the highlight is decoration, the crash is not:

  ```dart
  final lower = text.toLowerCase();
  // Full Unicode lowercasing is not length-preserving (U+0130 -> 2 units), so
  // offsets found in `lower` are only valid against `text` when lengths agree.
  if (lower.length != text.length) {
    return [TextSpan(text: text, style: style)];
  }
  ```

  Apply the same guard in `searchSnippet` (fall back to `start = 0`). If highlighting must survive those inputs, build an explicit `lower index -> text index` map while folding rather than assuming a 1:1 correspondence.

### [Low] Keyword matches inside a `#tag` pill are never emphasised

- **Location:** `lib/core/widgets/search_highlight_text.dart:62-85`
- **Issue:** Text *between* tag matches goes through `keywordSpans`, but the tag itself is rendered as `Text(tagText, style: style)` inside the pill's `WidgetSpan` (`:81`) — keywords are never applied to it. Once **[M-2]** lands and stray `#tokens` stop leaking into `keywords`, this is the remaining case: a plain keyword that occurs inside a tag name (searching `proj` against `#project-alpha`) matches the entry but shows no emphasis on the part that matched, so the result reads as a false positive.
- **Fix:** Build the pill's child from `keywordSpans` too:

  ```dart
  child: Text.rich(
    TextSpan(children: keywordSpans(tagText, style, keywords)),
  ),
  ```

### [Low] One scroll position is shared across every result set

- **Location:** `lib/features/search/search_page.dart:185-187`; `lib/core/widgets/keep_alive_scroll.dart:77-95`
- **Issue:** `KeepAliveScrollList` passes a single constant `PageStorageKey` (`ShellPageStorageKeys.searchResults`) as the `ListView`'s key, and `wantKeepAlive` holds the element across query changes, so one `ScrollPosition` is reused for every result set. Scroll deep into a narrow result set, then clear the query: the offset is retained and the user lands at an unrelated position in the full list rather than at the top. Narrowing the query similarly leaves the view clamped to the bottom of the shrunken list rather than showing the best matches.
- **Fix:** Jump to the top whenever the effective query changes. With the debounce from **[H-4]** in place:

  ```dart
  final _resultsController = ScrollController();

  void _onQueryChanged(String _) {
    _queryDebounce?.cancel();
    _queryDebounce = Timer(const Duration(milliseconds: 150), () {
      if (!mounted) return;
      setState(() => _activeQuery = _queryController.text);
      if (_resultsController.hasClients) _resultsController.jumpTo(0);
    });
  }
  ```

  Pass `controller: _resultsController` to `KeepAliveScrollList` and dispose it alongside the others.

### [Low] A failed entry or journal load is a terminal state with no retry

- **Location:** `lib/features/search/search_page.dart:256-261`
- **Issue:** Both `error` branches render `Center(child: Text('$e'))` — a raw exception string with no retry affordance. `journalListEntriesProvider` and `journalsProvider` are both `keepAlive` (`providers.dart:682`, `:626-629`), so the failed future is cached and **nothing in the page can ever re-request it**: the search tab shows a raw error string until the app is restarted. A transient database lock during startup is enough to trigger it.
- **Fix:** Give the error state a retry that invalidates the failed provider:

  ```dart
  error: (e, _) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('Could not load entries.'),
        TextButton(
          onPressed: () =>
              ref.invalidate(journalListEntriesProvider(allJournalEntriesScope)),
          child: const Text('Retry'),
        ),
      ],
    ),
  ),
  ```

  and the equivalent for `journalsProvider` in the inner `.when`.
