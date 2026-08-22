# Journal Feature Audit

**Scope:** `lib/features/journal/*`, `lib/domain/models/journal_models.dart`,
`lib/core/sync/journal_write_coordinator.dart`, the journal paths in
`lib/core/sync/remote_sync_service.dart` / `firestore_document_mapper.dart`,
`DriftJournalRepository`, and the journal providers in `lib/app/providers.dart`.

**Date:** 2026-08-22 · **Findings:** 24 (1 Critical, 7 High, 10 Medium, 6 Low)

Two ambiguities were resolved with the author before writing:
- `JournalEntry.mood == null` means **"not recorded"** and must stay distinct from `5`.
- `'sunny'` **is** the intended default weather — but it must be written deliberately, not as a side effect of typing.

---

## Critical

### [Critical] A new entry exists only in RAM until a network round-trip finishes; killing the app loses it
- **Location:** `lib/features/journal/journal_page.dart:900-978` (`_createEntryOptimistic` / `_finalizeNewEntry`), `lib/core/sync/journal_write_coordinator.dart:47-49`
- **Issue:** `_createEntryOptimistic` never touches SQLite. It registers the entry in the in-memory `_pendingEntries` map, focuses the title, and fires `unawaited(_finalizeNewEntry(...))`. The first — and only — `upsertEntry` happens at `journal_page.dart:967`, *after* two awaits: `ref.read(quotesLoadedProvider.future)` and `weatherService.refreshIfNeeded()`. The latter is not cheap: `weather_service.dart:35-70` hits `_syncRepository.getCurrentWeather()` (Firestore), then may claim a distributed fetch lock and call the weather HTTP API. On a cold start, a slow network, or a captive-portal Wi-Fi, that window is seconds to tens of seconds.

  Three failures fall out of that window:

  1. **Total loss.** If the process dies (kill, crash, OS reclaim) before `_finalizeNewEntry` reaches line 967, the entry has never been written. `_entryBodyDrafts` is a plain in-memory `Map`, so everything typed dies with it.
  2. **Every autosave in the window throws.** `_persistEntryEdits` → `JournalWriteCoordinator.saveEntry` → `getEntry(entryId)` returns `null` → `throw StateError('Journal entry $entryId not found in SQLite')` (`journal_write_coordinator.dart:47`). It is swallowed by the `catch` at `journal_page.dart:1421` and reported through `FlutterError.reportError`, so the user sees nothing, but *no keystroke reaches disk for the whole window.*
  3. **Early return on unmount.** The `if (!mounted) return;` guards at lines 952 and 959 abandon the write entirely if the page is disposed mid-flight — the entry is then never persisted at all, even though the user saw it in the list and typed into it.
- **Fix:** Persist the row synchronously at creation, then patch the async-resolved fields in through the coordinator (which is baseline-safe and will not clobber typed text):
  ```dart
  void _createEntryOptimistic(List<Journal> journals) {
    // ...unchanged up to `final entry = JournalEntry(...)`...
    _registerPendingEntry(entry);
    _suppressAutoSelect = true;
    // Write-through BEFORE anything async, so the row always exists.
    final repo = ref.read(journalRepositoryProvider);
    final seeded = repo.upsertEntry(entry);
    _logJournal('CREATE_ENTRY', entry: entry);
    // ...scroll/focus...
    unawaited(seeded.then((_) => _finalizeNewEntry(entry, settings)));
  }

  Future<void> _finalizeNewEntry(JournalEntry entry, AppSettings settings) async {
    await ref.read(quotesLoadedProvider.future);
    final assignedQuote = ref.read(quoteBankProvider).nextQuote();
    final weather = await weatherService.refreshIfNeeded()
        ?? weatherService.readCachedSnapshot(settings);
    // No `mounted` guard needed and no full-row overwrite: apply a *delta* to
    // whatever the autosave has already written.
    await _writeCoordinatorOrNull()?.saveEntry(
      entryId: entry.id,
      applyDelta: (base) => base.copyWith(
        quoteId: assignedQuote.id,
        customQuote: assignedQuote.text,
        weatherIcon: weather?.icon ?? base.weatherIcon,
        bumpVersion: false,
      ),
      onSuccess: (updated) { /* existing _pendingEntries / _selectedEntry sync */ },
    );
  }
  ```
  Note this also removes the current full-row `upsertEntry(finalized)` at line 967, which was itself capable of reverting a body the user typed during the window (it is built from the pristine `entry` snapshot, not from disk).

---

## High

### [High] A title edit cancels the queued body autosave, then writes a stale body over it
- **Location:** `lib/features/journal/journal_page.dart:1425-1476` (`_saveMetadataForEntry`), `lib/core/sync/remote_sync_service.dart:574-600` (`saveLocalThenScheduleUpload`)
- **Issue:** `saveLocalThenScheduleUpload` implements last-writer-wins by generation:
  ```dart
  final generation = (_localSaveGenerations[key] ?? 0) + 1;
  _localSaveGenerations[key] = generation;
  ...
  .then((_) async {
    if (_localSaveGenerations[key] != generation) return;   // <-- silently dropped
    await saveLocal();
  ```
  That is only safe if every writer on a key persists the **same full snapshot**. The journal has two writers on the same key that persist *disjoint* field sets:
  - `_persistEntryEdits` (body autosave) writes title + body + tags + mood + weather;
  - `_saveMetadataForEntry` writes title + mood + weather, and carries `baseline.body` forward.

  When both 400 ms debouncers land in the same window in the order **body first, title second**, the body save is assigned generation *N*, the metadata save *N+1*, and by the time generation *N*'s turn on the chain comes around `_localSaveGenerations[key]` is already *N+1* — so `saveLocal` never runs. The metadata save then upserts `baseline.copyWith(title:, mood:, weatherIcon:)`, where `baseline` is the pre-edit row, so **the body the user just typed is discarded from SQLite.**

  The reverse order is safe by luck, because `_persistEntryEdits` is a superset of the metadata fields.
- **Failure scenario:** Type a paragraph in the body, then click into the Title field and type a character, within ~400 ms of each other. `journal_debug.log` shows `PERSIST_ENTRY_SAVED` missing and `METADATA_PERSIST_SAVED` present; the SQLite `body` column still holds the pre-paragraph text. The editor keeps showing the paragraph (it is still in `_controller`), so the loss is invisible until the process is killed before the next commitment point.
- **Fix:** Route metadata saves through `JournalWriteCoordinator.saveEntry` so they become a baseline-delta rather than a full-row snapshot. That makes the two writers commutative, so dropping a superseded generation is harmless:
  ```dart
  Future<void> _saveMetadataForEntry({...}) async {
    final coordinator = _writeCoordinatorOrNull();
    if (coordinator == null) return;
    await coordinator.saveEntry(
      entryId: entryId,
      bumpVersion: true,
      refreshCaches: false,
      applyDelta: (base) => base.copyWith(
        title: title, mood: mood, weatherIcon: weatherIcon, bumpVersion: false,
      ),   // `base.body` is preserved untouched
      onSuccess: (updated) { /* existing preview/setState block */ },
    );
    if (refreshList) _refreshEntryLists(entry.journalId);
  }
  ```

### [High] `_saveMetadataForEntry` reads its baseline outside the serialized queue
- **Location:** `lib/features/journal/journal_page.dart:1437` (`final stored = await repo.getEntry(entryId);`)
- **Issue:** Independently of the generation bug above, the baseline read happens *before* `saveJournalEntryThenScheduleUpload` is called, i.e. outside the per-document `_localSaveChains` critical section. Any write that lands between the read and the queued `saveLocal` — a body autosave, an inbound `pullJournalEntries` merge, `applyPendingJournalEntryTextMerge`, an outbox replay — is overwritten by the stale snapshot.

  `JournalWriteCoordinator.saveEntry` deliberately does the opposite: its `getEntry` is *inside* the `saveLocal` closure (`journal_write_coordinator.dart:45`). This function is the only journal writer that violates that invariant.
- **Failure scenario:** With the entry open but the body unfocused, a live-sync pull applies a remote body edit at T; the metadata debouncer that read its baseline at T−50 ms fires at T+10 ms and writes the pre-pull body back. The remote edit is reverted locally *and* re-uploaded as the local truth.
- **Fix:** The same change as the previous finding — moving to `coordinator.saveEntry` puts the read inside the queue. If the direct-upsert form must be kept, the read has to move into the `saveLocal` closure:
  ```dart
  await remoteSync.saveJournalEntryThenScheduleUpload(
    entryId: entryId,
    saveLocal: () async {
      final baseline = await repo.getEntry(entryId) ?? entry;   // read *here*
      if (baseline.title == title && baseline.mood == mood &&
          baseline.weatherIcon == weatherIcon) return;
      await repo.upsertEntry(baseline.copyWith(
        title: title, mood: mood, weatherIcon: weatherIcon));
      // ...preview/setState block...
    },
  );
  ```

### [High] Moving an entry to another journal discards unsaved body text
- **Location:** `lib/features/journal/journal_page.dart:1819-1858` (`_moveEntryToJournal`), `:1736-1780` (`_moveEntryItemToJournal`)
- **Issue:** Every other selection change in the page is preceded by a flush — `_loadEntry` (line 1246), `_selectJournal` (line 218), `_deleteEntry` (line 1636), `_closeCompactEditor` (line 1173). The two move handlers are the exception. `_moveEntryToJournal` re-reads the entry from disk (line 1823), writes the `journalId` change, and then at lines 1846-1856 calls `_selectEntryFields(displayTarget)` for a *different* entry — with no `_flushActiveEntryEdits` anywhere in the path.

  The consequence chain:
  1. The `journalId` write uses `existing.body` from disk, so the in-flight keystrokes are not in the row.
  2. `setState` rebuilds `_PlainJournalEditor` with a new `entry.id`, so `didUpdateWidget` → `_switchEntryWidget` overwrites `_controller.text` with the new entry's body (line 2985).
  3. The pending `_bodySaveTimer` is never cancelled, so when it fires `_saveBodyDraft` reads `_selectedEntryId` — now the *replacement* entry — and persists that entry's own text (lines 1141-1153). The moved entry's draft is never written.

  `_entryBodyDrafts[movedId]` retains the text for the rest of the session, so re-opening the moved entry appears to recover it — which is exactly what makes the bug hard to spot. Restart the app and it is gone.
- **Fix:** Flush before mutating, in both functions:
  ```dart
  Future<void> _moveEntryToJournal(String journalId) async {
    final entry = _selectedEntry;
    if (entry == null || entry.journalId == journalId) return;
    if (_selectedEntryId == entry.id) {
      await _flushActiveEntryEdits(refreshList: false);
      if (!mounted) return;
    }
    final repo = ref.read(journalRepositoryProvider);
    final existing = await repo.getEntry(entry.id);   // now includes the flushed body
    // ...unchanged...
  ```
  Add the same guard at the top of `_moveEntryItemToJournal` (it already knows whether the entry is selected — reuse the `_selectedEntryId == entry.id` test it performs at line 1747).

### [High] A stale body draft survives the "no changes" fast path and later resurrects itself over a remote merge
- **Location:** `lib/features/journal/journal_page.dart:1365-1375` (early return in `_persistEntryEdits`) vs `:1395` (`_entryBodyDrafts.remove`)
- **Issue:** `_entryBodyDrafts[id]` is removed in exactly one place — the coordinator's `onSuccess` at line 1395. The early return at line 1365 ("No changes detected against DB baseline") leaves the draft in the map forever. That is reachable any time the editor text round-trips back to what is already on disk (type and undo, autocorrect revert, list-editing helpers that rewrite then restore, or a flush racing an autosave that already wrote the same text).

  A lingering draft is harmless while it matches disk. It stops matching the moment a *remote* edit changes the row — and `_entryWithDraftBody` (line 1308) unconditionally prefers the draft over the fresh entry whenever `_prepareSelectedEntry` runs.
- **Failure scenario:**
  1. Device A: body is `"abc"`. User types `"abcd"`, then backspaces to `"abc"`. Autosave finds no diff → logs `PERSIST_ENTRY_SKIPPED`, leaves `_entryBodyDrafts[id] = "abc"`.
  2. Device B appends `" def"`. Device A pulls; SQLite body becomes `"abc def"`.
  3. On A, the user clicks another entry and clicks back. `_prepareSelectedEntry` → `_entryWithDraftBody` overlays the stale `"abc"`; the editor shows `"abc"`.
  4. The next flush persists `"abc"` and pushes it. **Device B's paragraph is destroyed on both devices.**
- **Fix:** Clear the draft on the skip path too — the whole point of the branch is that the draft and disk now agree:
  ```dart
  if (baseline.title == title && baseline.body == body && /* ... */) {
    _entryBodyDrafts.remove(entry.id);      // <-- add
    _logJournal('PERSIST_ENTRY_SKIPPED', /* ... */);
    return;
  }
  ```
  Also drop the draft in the `ref.listen` reconciliation (see next finding), which currently replaces `_controller.text` without touching the map.

### [High] The `ref.listen` reconciler overwrites the editor and title with none of `_reconcileSelectedEntryFromProvider`'s guards
- **Location:** `lib/features/journal/journal_page.dart:1925-1950`
- **Issue:** The page has two independent mechanisms for pulling provider updates into the open editor, and they disagree about when that is safe.

  `_reconcileSelectedEntryFromProvider` (line 979) is careful: it bails on `_pendingEntries`, on `_editorKey.currentState?.hasFocus`, on `_metadataDirty`, and it has a dedicated branch that accepts metadata while preserving an in-memory body draft.

  The `ref.listen` registered inside `build` checks only `updated.updatedAt.isAfter(...) || updated.version > ...` and then unconditionally does:
  ```dart
  _titleController.text = updated.title;   // clobbers a half-typed title
  _mood = updated.mood;
  _weatherIcon = updated.weatherIcon;      // note: no `?? 'sunny'`, unlike _selectEntryFields
  _editorKey.currentState?.setBodyText(updated.body);   // clobbers the editor, focused or not
  ```
  No focus check, no `_metadataDirty` check, no draft check, and no `_entryBodyDrafts.remove` — so it also *creates* the stale-draft condition described in the previous finding.
- **Failure scenario:** Entry open, cursor in the Title field, user is mid-word. A live-sync pull lands (the body is unfocused so `isDocumentEditing` is false and `pullJournalEntries` writes straight through at `remote_sync_service.dart:1587`). The listener fires, `_titleController.text = updated.title` replaces the half-typed title and drops the IME composing region; `_metadataDirty` is still `true`, so the pending debounce then writes the *replaced* title back as if the user had typed it.
- **Fix:** Delete the `ref.listen` block and let `_reconcileSelectedEntryFromProvider` — which already runs on every build from `_buildJournalContent:1898` and covers the same provider — be the single reconciliation path. If the listener is kept for the version-regression case it does not cover, give it the same guards:
  ```dart
  if (_pendingEntries.containsKey(_selectedEntryId)) return;
  if (_editorKey.currentState?.hasFocus ?? false) return;
  if (_titleFocusNode.hasFocus || _metadataDirty) return;
  if (_entryBodyDrafts.containsKey(updated.id)) return;
  ```
  and mirror `_selectEntryFields`' `?? 'sunny'` normalization so the two paths cannot leave `_weatherIcon` in different states for the same row.

### [High] `setBodyText` desynchronizes the CRDT character-op session
- **Location:** `lib/features/journal/journal_page.dart:2873-2877` (`setBodyText`), called from `:1945` and `:1108`
- **Issue:** `_handleBodyKey` carries an explicit warning about this invariant (line 3040): *"recordJournalTextChange assumes `before` always matches the session's actual current text; skipping it here would silently desync the session and corrupt the next real edit's diff."*

  `setBodyText` breaks exactly that invariant:
  ```dart
  void setBodyText(String body) {
    _controller.text = body;
    _lastText = body;
    _tags = extractTags(body);
  }
  ```
  It moves `_lastText` to the new text without telling `_charOpRegistry` anything. The next keystroke calls `recordJournalTextChange(before: _lastText, after: ...)`, and the registry diffs against a session whose text is still the *pre-replacement* string. The resulting ops describe an edit that never happened, at positions that do not exist in the session's log.

  The call at line 1108 (`_flushActiveEntryEditsImpl`, after `applyPendingJournalEntryTextMerge`) is defensible — those ops came from the remote chain and are already in the registry. **The call at line 1945 is not**: it feeds arbitrary SQLite text (a non-CRDT LWW pull, an outbox replay, an import) straight into the controller.
- **Failure scenario:** Non-CRDT pull replaces the body while the entry is open and unfocused → listener calls `setBodyText` → user clicks into the body and types one character → the char-op emitted is a diff against the old text → on the next merge the two devices interleave characters (the doubling failure that `prepareEditingSession:764-780` was specifically written to prevent).
- **Fix:** Make `setBodyText` re-anchor the session instead of silently reassigning `_lastText`:
  ```dart
  void setBodyText(String body, {bool recordAsEdit = false}) {
    final before = _controller.text;
    _controller.text = body;
    if (recordAsEdit && before != body) {
      final id = widget.entry?.id;
      if (id != null) {
        _remoteSync?.recordJournalTextChange(entryId: id, before: before, after: body);
      }
    }
    _lastText = body;
    _tags = extractTags(body);
  }
  ```
  Pass `recordAsEdit: true` from the `ref.listen` path (line 1945) and leave the post-merge call at line 1108 as-is.

### [High] `_jumpToTarget` can spin a post-frame callback loop forever
- **Location:** `lib/features/journal/journal_page.dart:1600-1626`
- **Issue:**
  ```dart
  if (target > pos.maxScrollExtent && pos.maxScrollExtent > 0) {
    pos.jumpTo(pos.maxScrollExtent);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _jumpToTarget(target);   // no attempt counter, no other exit
    });
  }
  ```
  The only termination condition is `target <= maxScrollExtent`. `target` comes from an estimate built at lines 1584-1592 with hardcoded per-row heights (`68.0` with a preview, `52.0` without). The real row is a `dense` `ListTile` with `VisualDensity(vertical: VoyagerSpacing.compactListVerticalDensity)`, `VoyagerSpacing.xs` vertical content padding and a two- or three-line subtitle — so the estimate is not tied to the rendered height at all, and any theme, text-scale or density change makes it drift further.

  When the estimate overshoots the fully-materialized extent, the callback re-arms every single frame: one `jumpTo` per vsync, forever, pinning the list at the bottom. It is not a hang (the UI still paints), which is why it would present as "the entry list is stuck at the bottom and the app is warm/janky", not as a crash. `mounted` is the only escape.
- **Failure scenario:** Change the date of an entry (`_changeEntryDateAndTime` sets `_shouldScrollToSelected = true` at line 1552) so it sorts near the end of a long list, with a text scale factor above 1.0 so rows are taller than 68 px. The estimate exceeds `maxScrollExtent` and the loop never exits.
- **Fix:** Bound the retries and fall back to the extent:
  ```dart
  void _jumpToTarget(double target, {int attempt = 0}) {
    if (!mounted || !_entryListScrollController.hasClients) return;
    final pos = _entryListScrollController.position;
    if (attempt < 8 && target > pos.maxScrollExtent && pos.maxScrollExtent > 0) {
      pos.jumpTo(pos.maxScrollExtent);
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _jumpToTarget(target, attempt: attempt + 1));
      return;
    }
    pos.jumpTo(math.min(target, pos.maxScrollExtent));
    WidgetsBinding.instance.addPostFrameCallback((_) { /* ensureVisible, unchanged */ });
  }
  ```
  Better still, drop the estimate and retry `ensureVisible` on the real element once a jump has materialized it, since an exact-height estimate for a themed `ListTile` is unmaintainable.

### [High] The delete tombstone is pushed from a stale in-memory snapshot and can regress the remote version
- **Location:** `lib/features/journal/journal_page.dart:1637-1640` and `:1721-1724`, `lib/data/repositories/drift_repositories.dart:234-246`
- **Issue:** Two mismatches on the same operation:
  1. `softDeleteEntry` writes `deletedAt` and `updatedAt` but **not** `version`, so the local row stays at version *N*.
  2. The push uses `entry.copyWith(deletedAt: utcNow())` where `entry` is `_selectedEntry` — an in-memory snapshot, not the row on disk — and `copyWith` bumps to `entry.version + 1`.

  When `_selectedEntry` is behind the DB row (it is refreshed only via `onSuccess` callbacks and the reconcilers, all of which have bail-out paths), the pushed tombstone carries a version *lower* than what Firestore already holds. On the next pull elsewhere, `remoteVersionWins` (`firestore_document_mapper.dart:96`) returns false for the lower version, `mergeDeletedAtFromRemote` is called with `remoteWins: false` and returns `localDeletedAt` — i.e. **the delete is ignored on that device**, which then pushes its own higher-versioned, non-deleted document back and resurrects the entry everywhere.
- **Fix:** Read the row back after the soft delete and push *that*, so the tombstone is always monotonic:
  ```dart
  await ref.read(journalRepositoryProvider).softDeleteEntry(entry.id);
  final tombstone = await ref.read(journalRepositoryProvider).getEntry(entry.id);
  if (tombstone != null) {
    ref.read(remoteSyncServiceProvider).pushJournalEntryNow(tombstone);
  }
  ```
  and bump the version inside `softDeleteEntry` so the local row and the pushed doc agree:
  ```dart
  Future<void> softDeleteEntry(String id) async {
    final current = await getEntry(id);
    if (current == null) return;
    await upsertEntry(current.copyWith(deletedAt: utcNow()));   // bumps version, sets updatedAt
  }
  ```
  The same stale-snapshot push exists in `_syncJournalDeleteRemote` (`journal_list_actions.dart:137-150`), which pushes `entriesBeforeDelete` snapshots rather than re-reading the rows `softDeleteEntriesInJournal` / `reassignEntriesJournal` just wrote — and neither of those repository methods bumps `version` either.

---

## Medium

### [Medium] A concurrent flush request is answered with the in-flight flush and silently drops newer text
- **Location:** `lib/features/journal/journal_page.dart:1060-1065`
- **Issue:**
  ```dart
  if (_flushInProgress != null) {
    await _flushInProgress;
    return;                  // <-- the caller's newer state is never captured
  }
  ```
  `_flushActiveEntryEditsImpl` snapshots `_titleController.text`, `_mood`, `_weatherIcon` and `currentBodyText` at its *start* (lines 1084-1092), then awaits `applyPendingJournalEntryTextMerge`, `_persistEntryEdits` and — crucially — `remoteSync.flushDocument`, which does a Firestore write. Anything typed during those awaits is invisible to that flush, and a second caller arriving in the window is told the work is already done.
- **Failure scenario:** Blur the body (flush 1 starts, snapshot taken). While the network write is in flight, click back into the entry, type, and hit the phone back button → `_closeCompactEditor` → `_flushActiveEntryEdits` → returns as soon as flush 1 finishes, without persisting the new keystrokes. The page then unmounts.
- **Fix:** Chain a fresh flush instead of aliasing the in-flight one:
  ```dart
  Future<void> _flushActiveEntryEdits({required bool refreshList}) async {
    final inFlight = _flushInProgress;
    if (inFlight != null) await inFlight.catchError((_) {});
    if (!mounted) return;
    final flush = _flushActiveEntryEditsImpl(refreshList: refreshList);
    _flushInProgress = flush;
    try { await flush; } finally {
      if (identical(_flushInProgress, flush)) _flushInProgress = null;
    }
  }
  ```
  The second pass is cheap: `_persistEntryEdits` short-circuits on the no-diff branch when nothing actually changed.

### [Medium] The dispose-time flush writes to already-disposed `ValueNotifier`s
- **Location:** `lib/features/journal/journal_page.dart:383-400` (`dispose`), writing to `:1402-1403` and `:1471`
- **Issue:** `dispose()` disposes `_listTitlePreview` and `_listBodyPreview` (lines 392-393) and only then starts the flush (line 398, `unawaited`). The flush's success callbacks assign to both notifiers:
  ```dart
  if (_selectedEntryId == entry.id) {
    _listTitlePreview.value = updated.title;    // notifier already disposed
    _listBodyPreview.value = updated.body;
    if (mounted) { setState(/* ... */); }       // only the setState is guarded
  }
  ```
  `_selectedEntryId` is still set at that point, so the branch is taken. `ChangeNotifier.notifyListeners` asserts `_debugAssertNotDisposed()`, so in debug/profile this throws `A ValueNotifier<String> was used after being disposed` on every page teardown that has pending edits — inside an unawaited future, so it surfaces as an unhandled async error rather than at the call site.
- **Fix:** Guard the notifier writes with the same `mounted` test the `setState` already uses, in both `_persistEntryEdits` (line 1400) and `_saveMetadataForEntry` (line 1469):
  ```dart
  if (_selectedEntryId == entry.id && mounted) {
    _listTitlePreview.value = updated.title;
    _listBodyPreview.value = updated.body;
    setState(() { _selectedEntry = updated; _metadataDirty = false; });
  }
  ```
  Reordering `dispose()` is *not* sufficient — the flush is asynchronous, so it will always outlive the method — the `mounted` guard is the fix.

### [Medium] The editor leaks its pending-text-merge listener when disposed during an entry switch
- **Location:** `lib/features/journal/journal_page.dart:2962-2996` (`_switchEntryWidget`) and `:3004-3026` (`dispose`)
- **Issue:** `_switchEntryWidget` awaits the in-flight flush, then removes the listener registered for `oldWidget.entry!.id`. If the widget is disposed during that await, the `if (!mounted) return;` at line 2967 short-circuits **before** the removal. `dispose()` then removes the listener for `widget.entry` — the *new* entry, which never had one registered — so the old registration stays in `_pendingTextMergeBuffer` forever, holding a closure over the dead `State`.

  Two consequences: the retained `_PlainJournalEditorState` (and through it the `TextEditingController` and the entry's full body) is never collected, and every subsequent remote merge on the old document invokes a listener on an unmounted state. The `if (!mounted) return;` inside `_handlePendingTextMerge` (line 2911) makes it a silent leak rather than a crash.

  The same path also skips `_setEditingFlag(oldWidget.entry, false)` (line 2977), so the old document stays in `_activelyEditedDocuments` permanently — which makes `pullJournalEntries` buffer every future remote body change for that entry instead of applying it (`remote_sync_service.dart:1565`), and nothing will ever drain the buffer.
- **Fix:** Detach the old entry's registrations *before* the await, and key `dispose`'s cleanup off what is actually registered:
  ```dart
  Future<void> _switchEntryWidget(_PlainJournalEditor oldWidget) async {
    _detachEntry(oldWidget.entry);        // remove listener + clear editing flag, synchronously
    final pendingFlush = widget.waitForFlush?.call();
    if (pendingFlush != null) await pendingFlush;
    if (!mounted) return;
    // ...unchanged...
  }
  ```
  with the attached id tracked in a field so `dispose()` calls `_detachEntry` for the id it actually registered.

### [Medium] Rapid toggling in the journal settings dialog silently reverts the previous toggle
- **Location:** `lib/features/journal/journal_settings_dialog.dart:30-35` (`_saveJournal`) and its five call sites at `:110-155`
- **Issue:** Every switch does `_saveJournal(ref, journal.copyWith(showMood: v))`, where `journal` is the value captured from `ref.watch(journalsProvider)` when the frame was built. `_saveJournal` performs a **full-row** `upsertJournal` and only then invalidates and awaits the provider. The rebuild is one microtask-plus-a-DB-round-trip away, so a second toggle flipped before the refetch completes still holds the pre-first-toggle `journal` object and writes it back verbatim except for its own field.
- **Failure scenario:** Turn "Mood bar" off, then immediately turn "Weather" off. The second write is `journal{showMood: true}.copyWith(showWeather: false)` → mood is silently re-enabled, and the switch flips back on screen a moment later. Reproducible at normal tapping speed. `includeInAllView` and `showQuotes` have the same exposure, and each lost update also bumps `version` and pushes to Firestore.
- **Fix:** Read the current row inside the write, and pass a delta rather than a finished object:
  ```dart
  Future<void> _saveJournal(WidgetRef ref, Journal Function(Journal) apply) async {
    final repo = ref.read(journalRepositoryProvider);
    final current = await repo.getJournal(journalId);
    if (current == null) return;
    final updated = apply(current);
    await repo.upsertJournal(updated);
    ref.read(remoteSyncServiceProvider).pushJournal(updated);
    ref.invalidate(journalsProvider);
    await ref.read(journalsProvider.future);
  }
  // call site:
  onChanged: (v) => _saveJournal(ref, (j) => j.copyWith(showMood: v)),
  ```
  The dialog should also hold optimistic local state for the switch positions, since today the thumb does not move until the provider round-trips.

### [Medium] Mood cannot be cleared, and the slider shows `5` for "not recorded"
- **Location:** `lib/domain/models/journal_models.dart:96-132` (`JournalEntry.copyWith`), `lib/features/journal/journal_page.dart:2471` (`value: _mood ?? 5`), `lib/app/providers.dart:1314`
- **Issue:** Confirmed with the author that `mood == null` means *not recorded* and must stay distinct from `5`. Two things break that:
  1. **Display.** `MoodGradientSlider(value: _mood ?? 5)` renders an unset mood identically to a deliberate 5, and the slider has no null state (`final int value`). A user reading an old entry sees a neutral mood that the analytics average (`.where((e) => e.mood != null)`) is deliberately excluding — the page and the chart disagree about the same entry.
  2. **One-way door.** `copyWith` uses `mood: mood ?? this.mood`, so passing `null` is indistinguishable from "don't change". Once any value is written there is no code path anywhere that can restore `null`. `_clearEntryFields` sets `_mood = null` locally, but the next save is a no-op for that field.
- **Fix:** Add an explicit clear flag to the model and a null-aware slider:
  ```dart
  // journal_models.dart
  JournalEntry copyWith({/* ... */ int? mood, bool clearMood = false, /* ... */}) =>
    JournalEntry(
      // ...
      mood: clearMood ? null : (mood ?? this.mood),
      // ...
    );
  ```
  ```dart
  // mood_gradient_slider.dart
  final int? value;                  // null == not recorded
  final VoidCallback? onCleared;     // e.g. long-press, or a small "×" affordance
  // render an outlined, un-filled thumb at the midpoint when value == null,
  // and label it '—' rather than '5'.
  ```
  Then thread it through the `applyDelta` in `_persistEntryEdits` / `_saveMetadataForEntry`:
  `base.copyWith(mood: mood, clearMood: mood == null && _moodExplicitlyCleared, /* ... */)`.
  The same `?? this.x` one-way door applies to `weatherIcon`, `quoteId`, `customQuote`, `guidedPrompt`, `richBodyJson` and `timestamp` on this model — none of them can be unset once written.

### [Medium] `'sunny'` is stamped onto legacy entries as a side effect of typing
- **Location:** `lib/features/journal/journal_page.dart:1281` (`_selectEntryFields`), consumed at `:1152` and `:1418`
- **Issue:** Confirmed that `'sunny'` is the intended default — but it is currently applied at the wrong moment. `_selectEntryFields` does `_weatherIcon = displayEntry.weatherIcon ?? 'sunny'`, and both save paths write `_weatherIcon` back unconditionally. So for any entry whose `weatherIcon` is `null` — anything written before the weather feature, imported, or created while the weather cache was cold — merely *opening it and typing one character* writes `weatherIcon: 'sunny'`, bumps `version`, and pushes the row to Firestore.

  This shows up as a wave of spurious version bumps and uploads whenever a user browses old entries, and it makes the field's history unreliable: `'sunny'` stops meaning "it was sunny" and starts meaning "this entry was opened after the default was introduced". Note `ref.listen` at line 1944 assigns `_weatherIcon = updated.weatherIcon` *without* the `?? 'sunny'`, so the two paths can leave the same row in different states.
- **Fix:** Apply the default once, at creation, where the intent is explicit — `_createEntryOptimistic` already reads a cached snapshot at line 905:
  ```dart
  weatherIcon: weather?.icon ?? 'sunny',
  ```
  and stop normalizing on selection so saves carry only what the entry actually holds:
  ```dart
  void _selectEntryFields(JournalEntry displayEntry) {
    // ...
    _weatherIcon = displayEntry.weatherIcon;   // no `?? 'sunny'`
  }
  ```
  The icon button already renders a fallback glyph through `weatherIconData(null)`, so the placeholder stays visible without being persisted.

### [Medium] `cancelPendingPersist()` is an empty method and the body timer survives a flush
- **Location:** `lib/features/journal/journal_page.dart:3032` (`void cancelPendingPersist() {}`), called from `:1083`
- **Issue:** `_flushActiveEntryEditsImpl` cancels `_metadataSaveTimer` and then calls `_editorKey.currentState?.cancelPendingPersist()`, whose entire body is `{}`. `_bodySaveTimer` — the actual pending body persist, owned by the page at line 121 — is never cancelled anywhere except `dispose()`. The flush therefore does not do what its call site says it does: a debounced `_saveBodyDraft` can fire *after* the flush completed and after the selection moved on, writing against the new `_selectedEntryId`.

  Today the damage is bounded (`_saveBodyDraft` re-reads `_selectedEntryId`/`_selectedEntry`, and `_persistEntryEdits` short-circuits on no-diff), so this is a latent hole rather than an active loss — but it is load-bearing for the move-entry bug above, where the stale timer is what persists the *wrong* entry's text.
- **Fix:** Cancel the real timer in the flush:
  ```dart
  _metadataSaveTimer?.cancel();
  _bodySaveTimer?.cancel();          // <-- what the call below was meant to do
  ```
  and either delete `cancelPendingPersist` (plus its now-unused call site) or give it a body if the editor is ever meant to own a debounce of its own.

### [Medium] Every upload rewrites `updatedAt` to "now", so the remote copy always looks newer than the local row
- **Location:** `lib/core/sync/remote_sync_service.dart:2398-2406` (`_uploadJournalEntryNow`), `lib/domain/models/journal_models.dart:107` (`updatedAt: DateTime.now().toUtc()`)
- **Issue:** `JournalEntry.copyWith` unconditionally sets `updatedAt: DateTime.now().toUtc()` — there is no way to produce a copy that preserves it. `_uploadJournalEntryNow` calls `journalEntryToFirestore(entry.copyWith(bumpVersion: bumpVersion))` purely to control the version, and in doing so stamps the payload with the *upload* time rather than the *edit* time.

  The document in Firestore therefore always carries an `updatedAt` strictly greater than the SQLite row it was uploaded from. `remoteVersionWins` falls through to `remoteUpdatedAtWins` whenever the versions are equal — which is the common case, since the body autosave uses `bumpVersion: false`. So after any upload, a subsequent pull resolves in the remote's favour even when the local row is the one that changed last.

  `_markSelfEcho` masks this for the immediate round-trip, but the echo is single-use and windowed (`_selfEchoWindow`), so it does not cover a pull arriving after the window, after an app restart, or after the outbox replays.
- **Failure scenario:** Autosave writes locally at T (version 4, `updatedAt` T). Upload fires at T+2s, stamping the remote doc `updatedAt` T+2s, version 4. The user edits again offline at T+1s — also version 4, `updatedAt` T+1s. On reconnect, the pull sees remote T+2s > local T+1s at equal versions and overwrites the offline edit.
- **Fix:** Stop mutating `updatedAt` on the upload path. Either add a preserving flag to the model:
  ```dart
  JournalEntry copyWith({/* ... */ bool preserveUpdatedAt = false}) => JournalEntry(
    // ...
    updatedAt: preserveUpdatedAt ? updatedAt : DateTime.now().toUtc(),
  );
  ```
  and use `entry.copyWith(bumpVersion: bumpVersion, preserveUpdatedAt: true)`, or skip `copyWith` entirely when `bumpVersion == false` (the overwhelmingly common case):
  ```dart
  payload: journalEntryToFirestore(
    bumpVersion ? entry.copyWith(bumpVersion: true) : entry,
  ),
  ```

### [Medium] The deleted journal flashes back into the dropdown
- **Location:** `lib/features/journal/journal_page.dart:672-680` (`_handleJournalManage`, delete case)
- **Issue:**
  ```dart
  if (deleted && mounted) {
    _optimisticallyHiddenJournalIds.remove(journalId);   // no setState
  }
  ```
  The optimistic hide is dropped the instant `deleteJournalList` returns. But that function only calls `ref.invalidate(...)` (`journal_list_actions.dart:117-124`) — invalidation is synchronous, the *refetch* is not, and `journalsProvider` is a `keepAlive` `FutureProvider` whose consumer uses `skipLoadingOnReload: true`, so the previous value (still containing the deleted journal) is served for at least one more frame. `_displayJournals` filters on `deletedAt == null` from that stale list, so the journal reappears until the refetch lands.

  The missing `setState` makes it worse rather than better: the removal is not painted until some other rebuild happens, so the number of frames the deleted journal stays visible depends on unrelated activity.
- **Fix:** Keep the optimistic hide until the provider has actually produced a list without the journal:
  ```dart
  if (deleted && mounted) {
    final journals = await ref.read(journalsProvider.future);
    if (!mounted) return;
    if (!journals.any((j) => j.id == journalId && j.deletedAt == null)) {
      setState(() => _optimisticallyHiddenJournalIds.remove(journalId));
    }
  }
  ```

### [Medium] `_editQuote` writes a full stale row instead of a delta
- **Location:** `lib/features/journal/journal_page.dart:1802-1817`
- **Issue:** Unlike `_moveEntryToJournal` (line 1823) and `_changeEntryDateAndTime` (line 1546), which both re-read the row from disk first, `_editQuote` builds its write from the in-memory `_selectedEntry`:
  ```dart
  final updated = entry.copyWith(customQuote: quote.trim());
  await ref.read(journalRepositoryProvider).upsertEntry(updated);
  ```
  `_selectedEntry` is only as fresh as the last `onSuccess`/reconcile that touched it, and the dialog is modal — it can sit open for minutes while autosaves, remote pulls and pending-merge writes land underneath. The `upsertEntry` then reverts `body`, `title`, `mood`, `tags` and `entryDate` to whatever they were when the dialog opened, and `pushJournalEntryNow` propagates the reverted row.

  It also bypasses the per-document save queue entirely (no `saveJournalEntryThenScheduleUpload`), so it can interleave with a queued save rather than ordering behind it.
- **Fix:** Route it through the coordinator like every other field edit:
  ```dart
  await _writeCoordinatorOrNull()?.saveEntry(
    entryId: entry.id,
    bumpVersion: true,
    applyDelta: (base) => base.copyWith(customQuote: quote.trim(), bumpVersion: false),
    onSuccess: (updated) {
      if (mounted) setState(() => _selectedEntry = updated);
    },
  );
  ```

---

## Low

### [Low] New journals created from the dropdown ignore the palette assigner
- **Location:** `lib/features/journal/journal_list_actions.dart:70-79`
- **Issue:** `createJournalList` builds `final assigner = paletteFromItems(...)` and then never reads it, passing `initialColor: defaultColor` (the theme accent) instead. The sibling implementation in `journal_manage_sheet.dart:78-84` does `initialColor: assigner.nextColor()`. Every journal created from the dropdown therefore opens the picker pre-set to the same accent colour rather than the next unused palette slot, defeating the `usedColors` logic sitting right beside it.
- **Fix:** `initialColor: assigner.nextColor(),` — `defaultColor` is still needed for the legacy-journal fallback at line 101, so keep the local.

### [Low] `deleteJournalList` uses `BuildContext` across async gaps
- **Location:** `lib/features/journal/journal_list_actions.dart:186-196`
- **Issue:** Inside the `moveToDefault` branch, the `firstWhere` `orElse` closure calls `Theme.of(context).colorScheme.primary.toARGB32()`. That runs after `await showDeleteContainerDialog` and `await repo.listEntries(...)`, with no `context.mounted` check. If the page is torn down mid-delete (navigation, window close, hot restart) this throws inside the `try`, which routes to `onLocalDeleteFailed` and reports a delete failure that never actually failed — leaving the journal half-deleted (entries reassigned, journal not soft-deleted).
- **Fix:** Capture the colour before the first await:
  ```dart
  final fallbackColor = Theme.of(context).colorScheme.primary.toARGB32();
  final choice = await showDeleteContainerDialog(/* ... */);
  // ...use `fallbackColor` in the orElse closure
  ```

### [Low] `journal_manage_sheet.dart` is unreachable and has diverged
- **Location:** `lib/features/journal/journal_manage_sheet.dart` (whole file, 310 lines)
- **Issue:** `showJournalManageSheet` has no callers anywhere in `lib/` or `test/` — the dropdown's per-journal menu (`_handleJournalManage`) replaced it. The file still carries its own copies of create/rename/recolour/delete that have since diverged from `journal_list_actions.dart` (it uses the palette assigner, `journal_list_actions` does not — see above), plus an `if (_journals.isEmpty)` branch at lines 94-111 whose two arms are byte-identical. Dead code that looks live is a maintenance trap: a future fix applied here would silently do nothing.
- **Fix:** Delete the file, or wire the dropdown's manage affordance back to it and retire the duplicated helpers in `journal_list_actions.dart`. Flagged rather than removed, per the "don't delete pre-existing dead code unasked" rule.

### [Low] `firstSentencePreview` is unbounded on its regex path
- **Location:** `lib/domain/models/journal_models.dart:200-210`
- **Issue:** The fallback path caps the result at 120 characters, but the regex path returns `match.group(1)` whole. An entry whose first sentence is a 40 KB paragraph with a single trailing period returns all 40 KB, which is then laid out by a `maxLines: 1` `Text` in every list row (`journal_page.dart:3300` / `:3315`) — the ellipsis hides it, but the text layout cost is paid in full, per row, per rebuild.
- **Fix:** Apply the same cap to both paths:
  ```dart
  String firstSentencePreview(String body) {
    final trimmed = body.trim();
    if (trimmed.isEmpty) return '';
    final match = _firstSentenceExp.firstMatch(trimmed);
    final raw = match != null
        ? match.group(1)!.trim()
        : trimmed.split('\n').first.trim();
    return raw.length <= 120 ? raw : '${raw.substring(0, 117)}...';
  }
  ```

### [Low] `_optimisticallyHiddenEntryIds` grows without bound
- **Location:** `lib/features/journal/journal_page.dart:94`, added at `:1670`, `:1727`, `:1758`, `:1834`
- **Issue:** Ids are added on every delete and every move-out, and the set is only ever cleared wholesale on a journal switch (line 230) or when entering the all-view (line 285). A session spent in one journal deleting entries accumulates ids indefinitely, and `_buildDisplayEntries` runs a `contains` against it for every entry on every build.
- **Fix:** Prune ids that are no longer in the provider's list, at the same place the row caches are pruned (`journal_page.dart:2128`):
  ```dart
  final knownIds = {for (final e in entries) e.id};
  _optimisticallyHiddenEntryIds.removeWhere((id) => !knownIds.contains(id));
  ```

### [Low] `_entryCountForJournal` takes an `entriesLoading` argument it never reads
- **Location:** `lib/features/journal/journal_page.dart:846-882`, called at `:2091`
- **Issue:** `required bool entriesLoading` is declared and passed but never referenced in the body — the loading case is handled by the `persistedCounts != null` test instead. Harmless, but it reads as though loading state is being considered when it is not, which is the kind of thing that makes a future counting bug hard to reason about.
- **Fix:** Drop the parameter and the argument at the call site.

---

## Notes on things checked and found sound

- `_reconcileSelectedEntryFromProvider`'s post-frame `setState` loops all terminate: each branch converges to the equality test that guards it. Verified for the draft branch (the `copyWith` moves `updatedAt` past `fresh.updatedAt` at equal versions, hitting the line-994 early return) and the no-draft branch.
- `compareJournalEntriesNewestFirst` (`journal_models.dart:186`) matches `DriftJournalRepository.listEntries`' SQL `ORDER BY entryDate DESC, createdAt DESC, id DESC` exactly, so the optimistic in-memory merge in `_buildDisplayEntries` cannot reorder rows relative to a refetch.
- `_nextEntryTimestamp` (`journal_page.dart:749`) correctly guarantees strictly increasing `entryDate`s for rapid consecutive creates, so the sort is stable under a create burst.
- `mergeDeletedAtFromRemote` makes deletes sticky (a remote payload without `deletedAt` never resurrects a locally deleted row), which is the right default once the version-regression bug above is fixed.
- `PendingFlushRegistry`, `ShellBackInterceptors` and both focus-node listeners are unregistered in `_JournalPageState.dispose`; the only listener leak is the editor's (see the Medium finding).
- `_rowWidgetCache` / `_rowSignatureCache` are pruned to `filtered` on every build (`journal_page.dart:2128-2130`), so the row-reuse optimization does not retain deleted entries.
- `_handleBodyKey`'s Tab/Backspace paths correctly route through `_handleChanged`, keeping the CRDT session's `before` text in sync — the invariant `setBodyText` violates.
