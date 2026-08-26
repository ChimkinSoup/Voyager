# Dream Journal — Code Audit

Scope: `lib/features/dream_journal/` (page, sticky note, branch painter),
`lib/domain/models/dream_models.dart`, `DreamWriteCoordinator`
(`lib/core/sync/journal_write_coordinator.dart`), the dream paths through
`RemoteSyncService` / `firestore_document_mapper.dart` / `sync_conflict_detector.dart`,
`DriftDreamRepository`, and `dreamLoggedTrackerValues`.

Method: each dream path was diffed against its Journal counterpart, which is the
same architecture with several of these hazards already fixed and documented in
comments. Where the journal carries an explanatory comment about a bug it fixed,
that comment is cited as evidence the dream path still has it.

Findings are ordered by severity.

---

### [Critical] Every dream upload restamps `updatedAt`, so the remote copy always outranks the row it came from

- **Location:** `lib/core/sync/remote_sync_service.dart:2520-2529` (`_uploadDreamEntryNow`)
- **Issue:** The upload payload is built from `entry.copyWith(bumpVersion: bumpVersion)`
  — unconditionally, even on the `bumpVersion: false` autosave path.
  `DreamEntry.copyWith` (`dream_models.dart:34`) has no way to preserve `updatedAt`;
  it always stamps `DateTime.now().toUtc()`. So the published document carries the
  *upload* time, not the *edit* time, while the SQLite row it was built from keeps
  the edit time.

  On the next pull, `mergeDreamEntryFromRemote` calls `remoteVersionWins`. The
  autosave path uploads at an unchanged version, so `remoteVersion == localVersion`
  and the decision falls through to `remoteUpdatedAtWins`
  (`firestore_document_mapper.dart:83`), which returns `!r.isBefore(l)` — remote wins
  on strictly-later *and* on ties. Remote is now always strictly later. Result:
  `metadataRemoteWins == true` on every subsequent pull of that document, and any
  edit made locally after the upload is reverted from under the user.

  This is not speculative — it is the exact bug the journal path documents having
  fixed, at `remote_sync_service.dart:2496-2506`:
  > "calling it purely to leave the version alone used to publish a document whose
  > `updatedAt` was the *upload* time rather than the *edit* time. That made the
  > remote copy unconditionally newer than the row it came from … and resolved
  > every later pull in the remote's favour — reverting offline edits made after
  > the upload."

  `_uploadJournalEntryNow` (2507-2519) was fixed; `_uploadDreamEntryNow`, immediately
  below it, was not.
- **Fix:** Mirror the journal. Only copy when a bump is actually requested:
  ```dart
  Future<void> _uploadDreamEntryNow(
    DreamEntry entry, {
    bool bumpVersion = false,
  }) {
    return _uploadCrdtDocumentNow(
      collection: FirestoreCollections.dreamEntries,
      documentId: entry.id,
      payload: dreamEntryToFirestore(
        bumpVersion ? entry.copyWith(bumpVersion: true) : entry,
      ),
    );
  }
  ```

---

### [Critical] `DriftDreamRepository.softDeleteEntry` does not bump `version`, and the tombstone is pushed from a stale in-memory entry — deleted dreams resurrect

- **Location:** `lib/data/repositories/drift_repositories.dart:404-414` (`softDeleteEntry`);
  `lib/features/dream_journal/dream_journal_page.dart:455` (`_deleteEntry`'s push)
- **Issue:** Two defects that compound.

  1. `softDeleteEntry` writes `deletedAt` and `updatedAt` through a raw companion and
     leaves `version` untouched. `DriftJournalRepository.softDeleteEntry`
     (`drift_repositories.dart:256-260`) reads the row and re-saves it via
     `copyWith(deletedAt: ...)`, which bumps the version; the comment at
     `drift_repositories.dart:130` says it "Bumps [version] for the same reason
     [softDeleteEntriesInJournal] does". The dream repository skipped that.
  2. The page pushes `entry.copyWith(deletedAt: utcNow())` where `entry` is the row
     the *list* last loaded, not the row `softDeleteEntry` just wrote. `copyWith`
     bumps to *that snapshot's* version + 1.

  So delete a dream that has been edited since the list was last invalidated: disk
  and Firestore are at version N+5, `entry` in hand is version N, and the tombstone
  goes out at N+1. Every other device reads that tombstone as the loser, ignores the
  delete, and pushes its own higher-versioned live document back — resurrecting the
  dream everywhere, including on the device that deleted it.

  Again the journal documents this exact failure, at `journal_page.dart:1746-1755`:
  > "whenever it lagged the row on disk the tombstone went out at a version Firestore
  > had already passed. The next device to pull then read the tombstone as the loser,
  > ignored the delete, and pushed its own higher-versioned live document back —
  > resurrecting the entry everywhere."
- **Fix:** Both halves.
  ```dart
  // drift_repositories.dart — DriftDreamRepository
  @override
  Future<void> softDeleteEntry(String id) async {
    final current = await getEntry(id);
    if (current == null) return;
    await upsertEntry(current.copyWith(deletedAt: utcNow())); // bumps version
  }
  ```
  ```dart
  // dream_journal_page.dart — _deleteEntry, replacing lines 453-455
  final repo = _repoOrNull();
  if (repo == null) return;
  await repo.softDeleteEntry(entry.id);
  final tombstone = await repo.getEntry(entry.id);
  if (tombstone != null) _syncOrNull()?.pushDreamEntryNow(tombstone);
  ```
  Read the row back rather than reconstructing it, so the pushed tombstone is
  monotonic by construction.

---

### [High] The open dream never reconciles with a remote pull, and the next keystroke reverts it

- **Location:** `lib/features/dream_journal/dream_journal_page.dart:533-567` (`build`),
  `379-393` (`_selectEntry`), `224-269` (`_persistEntryEdits`)
- **Issue:** `_selectedEntry`, `_titleController` and `_DreamBodyEditor._controller`
  are written only at selection time and from a local save's `onSuccess`. Nothing
  reads a freshly-pulled row back into them.

  `LiveSyncController`'s `onChanged` runs `invalidateAllDataProviders`
  (`providers.dart:416`), which includes `allDreamEntriesProvider`
  (`providers.dart:1111`). So the *list* refreshes and the page rebuilds — but
  `build` only re-sorts `entries` for the list; the editor keeps the pre-pull text.

  The `isDocumentEditing` guard in `pullDreamEntries`
  (`remote_sync_service.dart:1740-1752`) does not cover this. That flag is set only
  from `_bodyFocusNode` (`dream_journal_page.dart:1133-1141`), so it is false whenever
  the body is not focused — which includes the entire time the user is typing in the
  sticky note, editing the title, or has the dream open but idle. In that state the
  pull writes the remote body, title and notes straight into SQLite.

  The failure completes on the next local edit: `_persistEntryEdits` compares its
  in-memory text against the freshly-pulled `stored` row, finds them different, and
  writes the *stale in-memory* text through the coordinator — silently reverting the
  remote change. Nothing surfaces the loss.

  The journal page has `_reconcileSelectedEntryFromProvider`
  (`journal_page.dart:1015-1091`) for precisely this, with focus, draft, version and
  `updatedAt` guards so it cannot yank text out from under a live caret.
- **Fix:** Port the reconciler. Call it from `build`'s `data:` branch, before the
  auto-select block:
  ```dart
  void _reconcileSelectedEntryFromProvider(List<DreamEntry> entries) {
    final id = _selectedEntryId;
    if (id == null) return;
    // Never re-seed a field the user is currently in.
    if (_bodyFocusNode.hasFocus ||
        _titleFocusNode.hasFocus ||
        _notesFocusNode.hasFocus) {
      return;
    }
    final fresh = entries.cast<DreamEntry?>().firstWhere(
      (e) => e!.id == id,
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
      setState(() {
        _selectedEntry = fresh;
        _titleController.text = fresh.title;
        _notesController.text = fresh.notes ?? '';
        _lastNotesText = _notesController.text;
        _listTitlePreview.value = fresh.title;
        _listBodyPreview.value = fresh.body;
      });
      _bodyEditorKey.currentState?.setBodyText(fresh.body, recordAsEdit: true);
    });
  }
  ```
  The `recordAsEdit: true` argument does not exist yet — it is the next finding, and
  this reconciler is unsafe without it.

---

### [High] `_DreamBodyEditorState.setBodyText` replaces the text without telling the char-op registry, desynchronising the CRDT session

- **Location:** `lib/features/dream_journal/dream_journal_page.dart:1003-1006`
- **Issue:** `setBodyText` assigns `_controller.text` and moves `_lastText`, and
  records nothing.

  `CharacterOpSession.recordTextChange(before, after)`
  (`character_op_session.dart:46-95`) diffs `before` against `after` but applies the
  resulting indices to `_liveOrderedOps()` — the session's *own* reconstructed
  sequence. The invariant is that `before` must equal the session's current text.
  `_handleKey` (`dream_journal_page.dart:1156-1178`) is careful about this and says so
  in its comment; `setBodyText` breaks it.

  After `setBodyText` runs, `_lastText` is the replacement string but the session's op
  chain still reconstructs the pre-replacement one. The next keystroke calls
  `_handleChanged`, which passes `before: _lastText` — a string the session has never
  seen — and the diff offsets land on the wrong ops: wrong characters tombstoned,
  inserts anchored between the wrong neighbours. On the next merge the two devices
  interleave text.

  The journal's `setBodyText` (`journal_page.dart:3085-3098`) takes a `recordAsEdit`
  flag for exactly this, with a comment spelling out the consequence: "the next
  keystroke is then diffed against the pre-replacement string, producing ops at
  positions that do not exist in the session's log, and the two devices interleave
  characters on the next merge."

  Today `setBodyText` is reached only from `_flushActiveEdits` (line 288) with text
  that did come off the remote chain, so it is latent. It becomes live the moment the
  reconciler above starts calling it with LWW-pulled text.
- **Fix:** Give it the same flag and make the reconciler pass it:
  ```dart
  void setBodyText(String body, {bool recordAsEdit = false}) {
    final before = _controller.text;
    if (before == body) return;
    _controller.text = body;
    if (recordAsEdit) {
      _remoteSync?.recordDreamTextChange(
        entryId: widget.entry.id,
        before: before,
        after: body,
      );
    }
    _lastText = body;
  }
  ```
  `_flushActiveEdits`'s call stays `recordAsEdit: false` (those ops are already in the
  registry); the reconciler passes `recordAsEdit: true`.

---

### [High] Concurrent `_flushActiveEdits` runs discard each other's writes

- **Location:** `lib/features/dream_journal/dream_journal_page.dart:273-305`
- **Issue:** `_flushActiveEdits` has no re-entrancy guard, and seven call sites can
  start it: `_lifecycleFlush` (144), `_handleTitleFocusChanged` (148),
  `_handleBodyFocusChanged` (159), `_selectEntry` (381), `_createEntry` (399),
  `_changeEntryDate` (464), `_showEntryStatistics` (500). Three of those are
  `unawaited`.

  Clicking a row in the dream list while the body has focus fires two of them in the
  same gesture: the tap's `onTap` calls `_selectEntry` → `await _flushActiveEdits()`,
  and the focus change calls `_handleBodyFocusChanged` → `unawaited(_flushActiveEdits())`.
  They interleave across the awaits on `applyPendingDreamEntryTextMerge`,
  `_persistEntryEdits` and `flushDocument`.

  That is not merely wasteful. `saveLocalThenScheduleUpload`
  (`remote_sync_service.dart:660-697`) stamps each save with a generation and has the
  queued body bail out if a newer generation has been registered:
  ```dart
  if (_localSaveGenerations[key] != generation) return;
  ```
  Two flushes racing means the second registers generation N+1 while the first is
  still queued behind an in-flight save — and the first is dropped without ever
  running `saveLocal`. The text it was carrying is never written. The same mechanism
  makes the body/title autosave and the notes autosave mutually cancelling whenever
  their two independent 400 ms debounces (`_saveTimer`, `_notesSaveTimer`) land in the
  same window, since both target the same `dreamEntries_<id>` key with different
  deltas.

  Secondary effects: `bumpVersion: true` is applied twice, so one selection change
  consumes two revisions; `flushDocument` uploads twice; and
  `ref.invalidate(allDreamEntriesProvider)` fires twice, re-reading and re-mapping
  every dream row and re-ranking `tagPoolProvider` for each.

  The journal solved this with `_flushInProgress` (`journal_page.dart:1105-1119`), and
  its comment names the same class of loss: "Returning the in-flight future told the
  second caller its work was already done, which lost every keystroke made in that
  window."
- **Fix:** Queue behind the in-flight flush rather than running alongside it, and do
  *not* return the in-flight future — a second pass is cheap because
  `_persistEntryEdits` short-circuits when the text already matches disk.
  ```dart
  Future<void>? _flushInProgress;

  Future<void> _flushActiveEdits({bool refreshList = true}) async {
    final inFlight = _flushInProgress;
    if (inFlight != null) await inFlight.catchError((Object _) {});
    final flush = _flushActiveEditsImpl(refreshList: refreshList);
    _flushInProgress = flush;
    try {
      await flush;
    } finally {
      if (identical(_flushInProgress, flush)) _flushInProgress = null;
    }
  }
  ```
  with the current body renamed to `_flushActiveEditsImpl`. Apply the same guard to
  `_flushNotes`.

---

### [High] A failing body flush skips the notes flush on app termination — sticky-note text is lost

- **Location:** `lib/features/dream_journal/dream_journal_page.dart:142-146` (`_lifecycleFlush`)
- **Issue:**
  ```dart
  await _flushActiveEdits(refreshList: false);
  await _flushNotes();
  ```
  `_flushActiveEdits` ends with `remoteSync.flushDocument(...)`, which reaches
  `SyncRetryPolicy.run` (`sync_engine.dart:359-380`). That retries three times and then
  `Error.throwWithStackTrace(lastError!, ...)` — it rethrows. So a Firestore write that
  fails (offline, permission, oversized payload) throws straight out of
  `_flushActiveEdits`, and the `await _flushNotes()` on the next line never executes.

  `PendingFlushRegistry.flushAll` (`pending_flush_registry.dart:23-27`) catches per
  callback, so the app shuts down cleanly and the debounced note text — its timer
  cancelled, or never fired — is gone. This is the one code path where losing it is
  unrecoverable, because the process is about to exit.

  The same ordering bug appears in `_selectEntry` (381-382), `_createEntry` (399-400)
  and `_deleteEntry` (437-438): a thrown flush aborts the caller before its `setState`,
  so tapping a dream, tapping "New dream" or confirming a delete silently does nothing.
- **Fix:** Isolate the two halves so one cannot suppress the other:
  ```dart
  Future<void> _lifecycleFlush() async {
    // Nothing is left on screen to refresh for; just get the bytes down, and
    // do not let either half's remote write suppress the other's local one.
    try {
      await _flushActiveEdits(refreshList: false);
    } catch (_) {}
    try {
      await _flushNotes();
    } catch (_) {}
  }
  ```
  They must stay sequential — both contend for the same document key in the
  coordinator's chain. Apply the same treatment at the other three call sites, or
  better, make `_flushActiveEdits` swallow the remote half's failure internally: the
  local SQLite write has already succeeded by then and the outbox will retry the
  upload, so a network error should never be able to abort a selection change.

---

### [High] "New dream" persists and syncs an empty entry immediately, leaving phantom dreams and a false "Dream Logged" day

- **Location:** `lib/features/dream_journal/dream_journal_page.dart:395-426` (`_createEntry`);
  `lib/domain/models/analytics_models.dart:237-257` (`dreamLoggedTrackerValues`)
- **Issue:** `_createEntry` builds a `DreamEntry` with `title: ''`, `body: ''`, writes
  it with `repo.upsertEntry`, and immediately calls `remoteSync.pushDreamEntryNow(entry)`.
  Tapping "New dream" and navigating away therefore leaves a permanent blank row in
  the dream list, propagated to every other device, with no way to remove it but an
  explicit delete.

  It also corrupts the virtual tracker. `dreamLoggedTrackerValues` folds *any* entry
  into a `boolValue: true` for its calendar day, with no content test — so an
  abandoned "New dream" marks that day "Dream Logged" on the analytics heatmap, and
  a delete does not take it back until the provider chain re-runs.

  The journal page does not do this: `_createEntry` registers the entry in
  `_pendingEntries` (`journal_page.dart:784-793`) and merges it into the displayed
  list (`journal_page.dart:814-819`) without touching SQLite until it has content.
- **Fix:** Adopt the pending-entry pattern.
  1. Add `DreamEntry? _pendingEntry;`. `_createEntry` populates it and sets
     `_selectedEntryId`/`_selectedEntry` from it, with no `upsertEntry` and no
     `pushDreamEntryNow`.
  2. In `build`'s `data:` branch, merge it into the sorted list:
     ```dart
     final sorted = sortDreamEntriesNewestFirst([
       if (_pendingEntry != null) _pendingEntry!,
       ...visible,
     ]);
     ```
  3. In `_persistEntryEdits`, when `entry.id == _pendingEntry?.id` and
     `title.isNotEmpty || body.isNotEmpty`, promote first —
     `await repo.upsertEntry(entry); _pendingEntry = null;
     ref.invalidate(allDreamEntriesProvider);` — then fall through to the normal
     coordinator save (which requires the row to exist, see
     `journal_write_coordinator.dart:80-82`). Do the same in `_saveNotes`.
  4. In `_selectEntry`, `_deleteEntry` and `dispose`, drop `_pendingEntry` if it is
     still empty.

  As defence in depth for entries that already exist, add the content test to the
  tracker:
  ```dart
  for (final entry in entries) {
    if (entry.title.trim().isEmpty && entry.body.trim().isEmpty) continue;
    final d = entry.entryDate;
    days.add(DateTime(d.year, d.month, d.day));
  }
  ```

---

### [Medium] `_persistEntryEdits`'s `onSuccess` writes to `ValueNotifier`s after dispose

- **Location:** `lib/features/dream_journal/dream_journal_page.dart:253-259`
- **Issue:**
  ```dart
  onSuccess: (updated) {
    if (_selectedEntryId == entry.id) {
      _listTitlePreview.value = updated.title;
      _listBodyPreview.value = updated.body;
      if (mounted) setState(() => _selectedEntry = updated);
    }
  },
  ```
  The `mounted` check guards `setState` but not the two notifier writes above it, and
  both notifiers are disposed in `dispose` (lines 175-176). `_coordinatorOrNull()`
  checks `mounted` at the *start* of `_persistEntryEdits`, but the method then awaits
  `repo.getEntry` and `coordinator.saveEntry` — the callback can fire long after.

  The reachable path is ordinary: navigating away from the page unfocuses the body,
  `_handleBodyFocusChanged` fires `unawaited(_flushActiveEdits())`, the route pops and
  the state disposes while the coordinator save and the Firestore write are still in
  flight. `ChangeNotifier.notifyListeners` after `dispose` asserts in debug and
  dereferences a null listener list in release.

  `_saveNotes`'s `onSuccess` (line 358) has the check in the right place —
  `if (_selectedEntryId == entry.id && mounted)` — so the two are inconsistent.
- **Fix:** Move the guard to cover the whole callback:
  ```dart
  onSuccess: (updated) {
    if (!mounted || _selectedEntryId != entry.id) return;
    _listTitlePreview.value = updated.title;
    _listBodyPreview.value = updated.body;
    setState(() => _selectedEntry = updated);
  },
  ```

---

### [Medium] `_saveNotes` has no error handling, so a failed notes save aborts selection changes and page navigation

- **Location:** `lib/features/dream_journal/dream_journal_page.dart:343-365`
- **Issue:** `_persistEntryEdits` wraps its coordinator call in `try`/`catch` with a
  `FlutterError.reportError` (lines 244-268). `_saveNotes` does not.

  `DreamWriteCoordinator.saveEntry` throws `StateError('Dream entry $entryId not found
  in SQLite')` when the row is gone (`journal_write_coordinator.dart:80-82`) —
  reachable via `purgeExpiredDeleted`, `purgeDreamEntryEverywhere`, or a restore/import
  that rewrites the table. `repo.getEntry` and `upsertEntry` can also throw on a locked
  or corrupt database.

  Because `_flushNotes` is `await`ed rather than `unawaited` in `_selectEntry` (382),
  `_createEntry` (400), `_deleteEntry` (438) and `_closeCompactEditor` (via
  `_lifecycleFlush`), any such throw aborts the caller *before* its `setState`. The
  user-visible symptom is that tapping a dream, tapping "New dream", confirming a
  delete, or pressing Back on the phone shell all do nothing at all, with no error
  shown. From `_scheduleNotesSave` (line 337) the same throw becomes an unhandled
  async error.
- **Fix:** Match `_persistEntryEdits`:
  ```dart
  try {
    await coordinator.saveEntry(
      entryId: entry.id,
      bumpVersion: bumpVersion,
      applyDelta: (base) => base.copyWith(notes: notesText, bumpVersion: false),
      onSuccess: (updated) {
        if (_selectedEntryId == entry.id && mounted) {
          setState(() => _selectedEntry = updated);
        }
      },
    );
  } catch (error, stackTrace) {
    FlutterError.reportError(FlutterErrorDetails(
      exception: error,
      stack: stackTrace,
      library: 'DreamJournalPage',
      context: ErrorDescription('while persisting dream notes'),
    ));
  }
  ```

---

### [Medium] `_changeEntryDate` writes around the coordinator, so a concurrent notes save can drop the date change

- **Location:** `lib/features/dream_journal/dream_journal_page.dart:461-495`
- **Issue:** The method awaits `_flushActiveEdits()` (464) but never `_flushNotes()`,
  and then writes directly:
  ```dart
  final existing = await repo.getEntry(entry.id);
  final updated = existing.copyWith(entryDate: picked.toUtc());
  await repo.upsertEntry(updated);
  ```
  `DreamWriteCoordinator` exists specifically so that every write reads the latest row
  and applies a field delta inside a strictly ordered per-document queue
  (`journal_write_coordinator.dart:10-13`). This write is outside that queue entirely,
  so it is not ordered against anything in it.

  Concretely: the `_notesSaveTimer` set while the sticky note was open stays armed
  across the popover's lifetime. If `_saveNotes` has already read its baseline when
  `upsertEntry(updated)` lands, its own `upsertEntry` writes last — with the *old*
  `entryDate` — and the date change is silently discarded. Because `entryDate` is the
  primary sort key (`compareDreamEntriesNewestFirst`, `dream_models.dart:76`), the row
  visibly snaps back to its old position in the list.

  `_deleteEntry`'s `repo.softDeleteEntry` (453) and `_createEntry`'s `repo.upsertEntry`
  (411) sit outside the same queue for the same reason.
- **Fix:** Route the date change through the coordinator like every other field edit,
  and flush notes first:
  ```dart
  await _flushActiveEdits();
  await _flushNotes();
  ...
  await coordinator.saveEntry(
    entryId: entry.id,
    bumpVersion: true,
    applyDelta: (base) =>
        base.copyWith(entryDate: picked.toUtc(), bumpVersion: false),
    onSuccess: (updated) {
      if (!mounted || _selectedEntryId != entry.id) return;
      setState(() => _selectedEntry = updated);
    },
  );
  ref.invalidate(allDreamEntriesProvider);
  ```
  The coordinator's `saveRemote` already re-reads and uploads the row
  (`remote_sync_service.dart:724-729`), so the explicit `pushDreamEntryNow` can go.

---

### [Medium] Keystrokes typed during a flush's awaits are written to the wrong dream

- **Location:** `lib/features/dream_journal/dream_journal_page.dart:379-393` (`_selectEntry`),
  `189-194` (`_scheduleBodySave`), `196-206` (`_saveDraft`)
- **Issue:** `_selectEntry` awaits `_flushActiveEdits()` and `_flushNotes()` before
  swapping the selection. `_flushActiveEdits` starts by cancelling `_saveTimer`, then
  awaits a pending-merge apply, a SQLite read, a coordinator save and a *Firestore
  write*. The editor stays on screen and interactive for that whole window.

  Anything typed in it re-arms `_saveTimer` via `_scheduleBodySave`. When `_selectEntry`
  finally lands, `_selectedEntry` is the new dream — and the re-armed timer fires
  afterwards into `_saveDraft`, which reads `_selectedEntry` and
  `_bodyEditorKey.currentState.currentBodyText` fresh at fire time. Both now belong to
  the *new* dream. The characters typed into the old one are simply gone: they were
  typed after `_flushActiveEdits` snapshotted the body, and the debounce that would
  have caught them now points at a different entry.

  The journal documents the identical hazard for its move handler at
  `journal_page.dart:1874-1881`, noting the loss "survives … for the rest of the
  session, which is what makes the loss invisible until the app is restarted."
- **Fix:** Bind the debounce to the entry that armed it, so a stale timer cannot write
  into the new selection:
  ```dart
  void _scheduleBodySave() {
    final entryId = _selectedEntryId;
    _saveTimer?.cancel();
    _saveTimer = Timer(_localSaveDebounce, () {
      if (_selectedEntryId != entryId) return;
      unawaited(_saveDraft(bumpVersion: false));
    });
  }
  ```
  and cancel `_saveTimer` again inside the `setState` that swaps the selection. To
  close the window entirely, make the outgoing editor non-interactive while the flush
  is in flight (an `AbsorbPointer` / `Focus(canRequestFocus: false)` keyed off a
  `_switching` flag) so no keystroke can be orphaned in the first place.

---

### [Medium] `DreamBranchOverlay` repaints on every page rebuild

- **Location:** `lib/features/dream_journal/dream_branch_painter.dart:106-109`
  (`shouldRepaint`); `lib/features/dream_journal/dream_journal_page.dart:541-543`
- **Issue:**
  ```dart
  bool shouldRepaint(covariant _DreamBranchPainter oldDelegate) {
    return oldDelegate.color != color || oldDelegate.minorColors != minorColors;
  }
  ```
  `List` does not override `==` in Dart, so `minorColors != minorColors` is an identity
  comparison. `build` constructs a fresh list every time:
  ```dart
  final minorPetalColors = (settings?.minorPetalColors ?? const <int>[])
      .map(Color.new)
      .toList();
  ```
  so the comparison is `true` on every rebuild and the painter always repaints,
  defeating the guard entirely. The comment at line 70 ("Fixed seed so the branch shape
  is stable across rebuilds instead of reshuffling every repaint") shows repaint
  avoidance was the intent.

  The cost is not trivial: the painter is `Positioned.fill` with `Size.infinite` under
  an `Opacity(0.14)`, which forces a `saveLayer` over the full page bounds, and it
  draws ~8 blossom clusters of 4-6 circles each plus three stroked paths. It is not
  behind a `RepaintBoundary`, so it repaints with the enclosing `Stack`. Every autosave
  `setState` (next finding) and every frame of a split-pane drag pays for it.
- **Fix:** Compare by value and isolate the layer:
  ```dart
  bool shouldRepaint(covariant _DreamBranchPainter oldDelegate) {
    return oldDelegate.color != color ||
        !listEquals(oldDelegate.minorColors, minorColors);
  }
  ```
  (`listEquals` from `package:flutter/foundation.dart`), and wrap the `CustomPaint` in
  a `RepaintBoundary` inside `DreamBranchOverlay`. Replacing the `Opacity` widget with
  the per-`Paint` alpha already applied in `_paintBlossomCluster` would also drop the
  full-page `saveLayer`.

---

### [Medium] Every autosave rebuilds and re-sorts the whole page, defeating the preview-notifier design

- **Location:** `lib/features/dream_journal/dream_journal_page.dart:257` and `359`
  (`setState(() => _selectedEntry = updated)`); `553-567` (`build`)
- **Issue:** Both save paths call `setState` on every successful write — including the
  ~400 ms autosave, which fires once per typing burst. That rebuilds `build`, which on
  every pass:
  - runs `_deletedEntryIds.removeWhere` over all entries (558),
  - allocates a filtered list and runs `sortDreamEntriesNewestFirst` over every dream (562),
  - rebuilds `LayoutBuilder`, the `AnimatedContainer`, the `ListView.builder` and the
    entire editor column,
  - rebuilds `DreamBranchOverlay` with a fresh `minorPetalColors` list, forcing a full
    repaint (previous finding).

  This is directly at odds with the architecture the file documents.
  `_persistEntryEdits`'s doc comment (lines 209-223) explains at length that the
  autosave deliberately does *not* invalidate `allDreamEntriesProvider` because "that
  provider re-reads and re-maps every dream row, and fans out further", and that "the
  list row on screen is updated directly below through
  `_listTitlePreview`/`_listBodyPreview`". The `ValueListenableBuilder`s in
  `_DreamEntryListTile` (923-933, 942-954) exist so the row can update without a page
  rebuild — and then the `setState` two lines above rebuilds the page anyway.
  `test/dream_autosave_provider_refetch_test.dart` counts table scans, so it does not
  catch this.
- **Fix:** `_selectedEntry` is read during build only for `entry.entryDate` (the date
  pill and the list tile) and `entry.id`. An autosave changes neither. Assign without a
  rebuild when only text changed:
  ```dart
  onSuccess: (updated) {
    if (!mounted || _selectedEntryId != entry.id) return;
    _listTitlePreview.value = updated.title;
    _listBodyPreview.value = updated.body;
    final needsRebuild = _selectedEntry?.entryDate != updated.entryDate;
    _selectedEntry = updated;
    if (needsRebuild) setState(() {});
  },
  ```
  Verify by counting rebuilds, not wall-clock: typing a burst into the body should
  produce zero `_DreamJournalPageState.build` calls.

---

### [Low] The auto-select post-frame callback can override an explicit user selection

- **Location:** `lib/features/dream_journal/dream_journal_page.dart:568-574`
- **Issue:**
  ```dart
  if (_selectedEntryId == null && sorted.isNotEmpty) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _selectedEntryId == null) {
        unawaited(_selectEntry(sorted.first));
      }
    });
  }
  ```
  `_selectEntry` does not set `_selectedEntryId` synchronously — it awaits
  `_flushActiveEdits()` and `_flushNotes()` first (lines 381-382), which include a
  Firestore round-trip. The guard therefore stays `null` for the whole flush window,
  so a second post-frame callback, or a user tap on a different row, sees `null` too.
  Both `_selectEntry` calls proceed, and the last `setState` to complete wins — which
  can be the auto-select, discarding the row the user actually tapped.

  On a cold start this is easy to hit: the callback is scheduled on the first frame
  that has data, and the user can tap a row before the flush resolves.
- **Fix:** Claim the selection synchronously, before any await:
  ```dart
  Future<void> _selectEntry(DreamEntry entry) async {
    if (_selectedEntryId == entry.id) return;
    final outgoing = _selectedEntry;
    final claimed = entry.id;
    _selectedEntryId = claimed;          // claim before awaiting
    await _flushActiveEdits(entry: outgoing);
    await _flushNotes(entry: outgoing);
    if (!mounted || _selectedEntryId != claimed) return;
    setState(() { ... });
  }
  ```
  The flushes must then take the outgoing entry explicitly rather than reading
  `_selectedEntryId`, since that field now moves first.

---

### [Low] `_flushActiveEdits` destroys the caret when it applies a pending remote merge mid-focus

- **Location:** `lib/features/dream_journal/dream_journal_page.dart:283-289`, `1003-1006`
- **Issue:** When `applyPendingDreamEntryTextMerge` returns non-null, the flush calls
  `_bodyEditorKey.currentState?.setBodyText(pendingApplied.body)`, which does
  `_controller.text = body`. `TextEditingController`'s `text` setter resets the
  selection to `TextSelection.collapsed(offset: -1)` — no caret at all.

  On the focus-loss path this is invisible. But `_flushActiveEdits` is also called from
  `_changeEntryDate` (464) and `_showEntryStatistics` (501), both of which run while
  the body can still hold focus. The user opens the date picker or the statistics
  dialog, a buffered remote merge is applied, and on return the caret is gone and the
  next keystroke lands at offset 0.

  `_handlePendingTextMerge` (1038-1062) already does this correctly for the live path,
  preserving the offset through `TextDeltaInjector.adjustedSelection`.
- **Fix:** Preserve the offset in `setBodyText` the same way:
  ```dart
  _controller.value = TextEditingValue(
    text: body,
    selection: TextSelection.collapsed(
      offset: TextDeltaInjector.adjustedSelection(
        selection: _controller.selection.baseOffset,
        before: before,
        after: body,
      ),
    ),
  );
  ```

---

### [Low] `_isDatePickerOpen` is never cleared if the popover throws

- **Location:** `lib/features/dream_journal/dream_journal_page.dart:468-476`
- **Issue:** `setState(() => _isDatePickerOpen = true)` is set before
  `await showContextualPopover(...)` and cleared only on the normal return path. If the
  popover's builder or route throws, the flag stays `true` for the life of the page and
  the date `SelectorPill` renders permanently in its active state
  (`isActive: _isDatePickerOpen`, line 828).
- **Fix:** Clear it in a `finally`:
  ```dart
  setState(() => _isDatePickerOpen = true);
  DateTime? picked;
  try {
    picked = await showContextualPopover<DateTime>(...);
  } finally {
    if (mounted) setState(() => _isDatePickerOpen = false);
  }
  if (!mounted || picked == null) return;
  ```

---

### [Low] A dream restored on another device stays hidden for the life of the page

- **Location:** `lib/features/dream_journal/dream_journal_page.dart:94-104`, `556-567`
- **Issue:** `_deletedEntryIds` is pruned by
  `removeWhere((id) => !entries.any((entry) => entry.id == id))` — an id is released
  only once the provider stops returning it. That is correct for the case the comment
  describes (the delete's refresh has not landed yet).

  It is wrong for the reverse. `mergeDeletedAtFromRemote`
  (`firestore_document_mapper.dart:100-116`) explicitly supports un-delete: "a record
  restored on another device un-deletes here." When that happens the id is present in
  `entries` again, so `removeWhere` keeps it in the set and the restored dream stays
  filtered out of the list until the page is torn down and rebuilt.
- **Fix:** Release the id on a positive signal that the delete has landed, rather than
  on absence alone. Record the `updatedAt` the tombstone was written with and drop the
  id once the row moves past it:
  ```dart
  // id -> the updatedAt this page's own soft delete stamped
  final _deletedEntryStamps = <String, DateTime>{};
  ...
  _deletedEntryStamps.removeWhere((id, stamp) {
    final entry = entries.cast<DreamEntry?>().firstWhere(
      (e) => e!.id == id,
      orElse: () => null,
    );
    // Gone (the delete landed), or a newer revision came back (restored
    // elsewhere) — either way this page has nothing left to hide.
    return entry == null || entry.updatedAt.isAfter(stamp);
  });
  ```

---

### [Low] `prepareEditingSession`'s future is dropped, so a failure to load the op-log is silent

- **Location:** `lib/features/dream_journal/dream_journal_page.dart:1017-1021`, `1088-1092`
- **Issue:** `RemoteSyncService.prepareEditingSession` is `async` — it reads the whole
  operation log (`_syncRepository.listOperations`), lifts the sequence counter, merges
  and loads the session, and kicks off background compaction. Both call sites invoke it
  bare, neither `await`ing nor `unawaited`ing it.

  If it throws, the error escapes into the zone with no context — and, more importantly,
  the session is left unseeded while the editor is already accepting keystrokes.
  `recordDreamTextChange` then opens a fresh session from the on-screen text via
  `ensureSession`, which `prepareEditingSession`'s own comment
  (`remote_sync_service.dart:847-857`) identifies as the case that must not re-seed:
  "re-seeding would create a second set of ops at the same fractional positions with
  different IDs — exactly the collision that doubles every character on merge."
- **Fix:** At minimum make the failure visible:
  ```dart
  unawaited(
    remoteSync
        .prepareEditingSession(
          collection: FirestoreCollections.dreamEntries,
          documentId: widget.entry.id,
          initialText: _controller.text,
        )
        .catchError((Object error, StackTrace stack) {
          FlutterError.reportError(FlutterErrorDetails(
            exception: error,
            stack: stack,
            library: 'DreamJournalPage',
            context: ErrorDescription('while preparing the dream editing session'),
          ));
        }),
  );
  ```

---

## Checked and found correct

Recorded so a later audit does not re-derive them.

- **`dreamLoggedTrackerValues` day bucketing.** `DateTime(d.year, d.month, d.day)` on
  `entry.entryDate` looks like it would bucket by UTC components. It does not: drift is
  configured with `storeDateTimeAsText` and the on-disk format is local wall time plus
  an offset, so every value read back through `DriftDreamRepository._mapEntry` is a
  local `DateTime`. The tracker's days line up with the `.toLocal()` labels the list
  tile renders. (The tracker's *content* test is still missing — see the "New dream"
  finding.)
- **`DreamSplitLayout.clampListWidth`.** `_maxAllowed` clamps into
  `[minListWidth, maxListWidth]` before being used as `clamp`'s upper bound, so the
  upper bound can never fall below the lower one and `clamp` cannot throw on a narrow
  window.
- **`_DreamBodyEditorState` listener lifecycle.** `didUpdateWidget` removes the
  outgoing id's pending-merge listener and clears its editing flag before registering
  the new one, and `dispose` uses `widget.entry.id`, which is current by then. Dart
  canonicalises instance-method tear-offs per receiver, so `_pendingTextMergeListener`
  removes the same closure it added. No leak.
- **`_handlePendingTextMerge` not recording into the char-op registry.** Matches the
  journal's deliberate `recordAsEdit: false` on the same path — those ops came off the
  remote chain and are already in the registry. Only `setBodyText` needs the flag.
- **`.when`'s loading branch.** `AsyncValue.when` defaults to
  `skipLoadingOnRefresh: true`, so `ref.invalidate(allDreamEntriesProvider)` keeps the
  previous list on screen rather than flashing the `CircularProgressIndicator`. No
  infinite-loading path found.
- **Notes as last-writer-wins.** `CrdtTextFields.fromDreamPayload`
  (`firestore_document_mapper.dart:159-161`) carries only `body`, so `notes` is LWW by
  design and a local notes save legitimately overwrites a concurrent remote one. The
  real exposure while the sticky note has focus is that `isDocumentEditing` stays
  false and the *body* is left unguarded — covered by the reconciler finding.
