# LeetCode Page — Audit

Scope: `lib/features/leetcode/**` (28 files, ~9,300 lines) plus its controllers,
services and models — `lib/domain/models/leetcode_models.dart`,
`lib/domain/services/leetcode_srs_engine.dart`,
`lib/data/remote/leetcode_api_client.dart`, `lib/data/remote/leetcode_content.dart`,
`DriftLeetCodeRepository`, and the LeetCode paths through
`firestore_document_mapper.dart` / `remote_sync_service.dart`.

Three findings (LC-01, LC-05, LC-07) were reproduced with throwaway widget tests
before being written up; the probes were deleted afterwards and their output is
quoted inline.

**Note on CRDT:** `leetcode_problems` is not a CRDT collection — it is absent
from `crdt_document_resolver`'s tables and is pushed with `logOperation: false`
as a whole-document snapshot. Conflict resolution is version-first
last-write-wins (`remoteVersionWins`), so the sequence-merge failure modes named
in the brief don't apply here. The equivalent risks — stale-snapshot lost updates
and tombstone ranking — are covered by LC-04 and LC-08.

---

### [Critical] LC-01 — Flashcard crashes with a duplicate GlobalKey under reduced motion

- **Location:** `lib/features/leetcode/leetcode_flashcard.dart:47`, passed at `:65` and `:70`, attached at `:210` and `:322`; triggered by `lib/features/study/study_flip_card.dart:205`

- **Issue:** `_LeetCodeFlashcardState` owns a single `_titleKey` and hands the
  *same* `GlobalKey` to both `_CardFront` and `_CardBack`. That is safe on the
  normal flip path, where `StudyFlipCard` renders
  `showBack ? widget.back : widget.front` — exactly one face is ever in the
  tree. But when `MediaQueryData.disableAnimations` is set, the builder takes
  the reduced-motion branch at `study_flip_card.dart:205` and returns a `Stack`
  holding **both** `widget.front` and `widget.back` at once. Two live widgets
  then carry one `GlobalKey`, and the framework throws while finalizing the
  tree.

  This is not a debug-only nicety: `GlobalKey` reparenting silently moves the
  key's element from one face to the other, so in release the front card's title
  subtree is torn out of its parent on every frame the key is re-registered.

  Reproduced — pumping `LeetCodeFlashcard` inside
  `MediaQuery(data: MediaQueryData(disableAnimations: true))`:

  ```
  Duplicate GlobalKey detected in widget tree.
  The key [GlobalKey#80706] was used by multiple widgets. The parents of those widgets were:
  - Column(... crossAxisAlignment: stretch ...)                    <- _CardFront
  - Column(... mainAxisSize: min, crossAxisAlignment: start ...)   <- _CardBack
  ```

  The blast radius is the whole session surface: `LeetCodeFlashcard` is the card
  in `LeetCodeSessionPage` (`:318`) and `LeetCodeCramPage` (`:424`). Any user
  with "Show animations in Windows" turned off cannot Study or Cram at all. The
  crash disappears only when `leetCodeHideQuestionName` is on, since that is the
  one setting under which neither face attaches the key.

- **Fix:** Give each face its own key and measure whichever one is mounted. The
  rect only seeds the detail view's zoom, so either key serves — but they must
  be distinct objects.

  ```dart
  class _LeetCodeFlashcardState extends State<LeetCodeFlashcard> {
    final _frontTitleKey = GlobalKey();
    final _backTitleKey = GlobalKey();

    void _openDetail() {
      // Under reduced motion both faces are mounted; the front's rect is the
      // one the tile grew from, so it wins when both are available.
      final box = (_frontTitleKey.currentContext ?? _backTitleKey.currentContext)
          ?.findRenderObject() as RenderBox?;
      final rect = box == null
          ? Offset.zero & MediaQuery.sizeOf(context)
          : box.localToGlobal(Offset.zero) & box.size;
      openLeetCodeDetailView(context, widget.problem, rect);
    }

    @override
    Widget build(BuildContext context) => StudyFlipCard(
          controller: widget.controller,
          onFlipChanged: widget.onFlipChanged,
          notifyFlipOnStart: widget.notifyFlipOnStart,
          front: _CardFront(
            problem: widget.problem,
            titleKey: _frontTitleKey,
            onTitleTap: _openDetail,
          ),
          back: _CardBack(
            problem: widget.problem,
            titleKey: _backTitleKey,
            onTitleTap: _openDetail,
          ),
        );
  }
  ```

  Worth adding a regression test that pumps the card under
  `disableAnimations: true` and asserts `tester.takeException()` is null — the
  ordinary-motion path will never catch this.

---

### [High] LC-02 — Every LeetCode write made offline is dropped from sync, permanently and silently

- **Location:** `lib/core/sync/remote_sync_service.dart:2015` (`pushLeetCodeProblem`), `:2447` (`_uploadRecordNow`), `:3491` (`backfillSyncedCollections`)

- **Issue:** Every mutation on this page — grade (`leetcode_actions.dart:20`),
  reset, delete, the Track modal's save, and session undo/redo
  (`leetcode_session_page.dart:218`) — funnels through:

  ```dart
  void pushLeetCodeProblem(LeetCodeProblem problem) {
    cancelDocument(FirestoreCollections.leetcodeProblems, problem.id);
    unawaited(_uploadLeetCodeProblemNow(problem));   // no catch anywhere below
  }
  ```

  `_uploadLeetCodeProblemNow` → `_uploadRecordNow` → `syncDocumentImmediately`,
  and none of them catches. The service already has the guard this needs, and
  documents this precise hazard at `:2409`:

  > *"These uploads are deliberately not awaited by their callers, so without
  > this an exception would escape to the zone as an unhandled error and the
  > document would simply stay unsynced with nothing recording that it had
  > tried."*

  …but `_runRemoteSave` is only wired into the debounced path (`:2404`).
  `pushLeetCodeProblem` bypasses it. So when the upload fails — offline, flaky
  Wi-Fi, an expired token — three things happen: the future rejects into the
  zone, **no outbox row is created**, and nothing else ever re-pushes the
  document.

  There is no second recovery path. `backfillSyncedCollections` (`:3491`) does
  not list `leetcodeProblems` at all, and is in any case a one-shot
  version-gated migration
  (`if (settings.syncBackfillVersion >= syncBackfillVersion) return;`).
  A pull never triggers a push. The outbox *could* handle it —
  `leetcodeProblems` is in both `_watchedCollections` (`:3643`) and
  `OutboxSyncWorker.drainableCollections` — but nothing ever queues a row for it.

  Net effect: solve a problem on a plane, grade a review on a dead connection,
  delete a duplicate in a tunnel — SQLite has it, Firestore never will, and the
  other device never sees it. The data is not lost locally (the local row's
  higher `version` correctly beats the stale remote copy on the next pull), so
  nothing looks wrong until the user checks their other machine.

- **Fix:** Route the push through the guard that already exists, the way the
  debounced saves do:

  ```dart
  void pushLeetCodeProblem(LeetCodeProblem problem) {
    cancelDocument(FirestoreCollections.leetcodeProblems, problem.id);
    unawaited(_runRemoteSave(
      FirestoreCollections.leetcodeProblems,
      problem.id,
      () => _uploadLeetCodeProblemNow(problem),
    ));
  }
  ```

  The same one-line change is owed to the other `push*` methods at `:2010`–`:2200`
  (journals, custom quotes, study folders/decks/cards, exercises, the workout
  tables, job applications) — they share the defect verbatim. Fixing only the
  LeetCode one is correct for this audit's scope but leaves the same hole open
  next door.

---

### [High] LC-03 — A failed save latches the Track modal's Save button off forever

- **Location:** `lib/features/leetcode/leetcode_track_modal.dart:845-892` (`_save`), read at `:898`

- **Issue:** `_save` sets `_saving = true` at `:849` and has no `try`/`catch`
  and no `finally`:

  ```dart
  setState(() => _saving = true);
  ...
  await repo.upsertProblem(problem);                 // :879 — can throw
  ref.read(remoteSyncServiceProvider).pushLeetCodeProblem(problem);
  ref.invalidate(leetcodeProblemsProvider);
  ...
  if (mounted) Navigator.of(context).pop(true);      // :891
  ```

  If `upsertProblem` throws — a locked database, a full disk, a JSON encode
  failure on a pathological solution list — the exception escapes to the zone,
  `_saving` stays `true` for the life of the sheet, and `canSave = !_saving`
  (`:898`) hands `null` to the Save button's `onPressed`. The button is dead,
  and there is no other way to commit.

  Create mode degrades acceptably: the local draft is untouched (`_draftClosed`
  is only set at `:886`, after the write), so closing the sheet preserves the
  typing. **Edit mode has no draft at all** — `showLeetCodeTrackModal` forces
  `draft: null` for an edit at `:82`. The user's changes to an existing problem
  are then unrecoverable: they can only close the sheet and lose them.

  Nothing explains it, either. The button simply stops responding.

- **Fix:** Wrap the persistence and release the latch on the failure path,
  reporting it through the toast the modal already uses for its other failures.

  ```dart
  setState(() => _saving = true);

  final problem = LeetCodeProblem(/* … unchanged … */);

  try {
    final repo = ref.read(leetCodeRepositoryProvider);
    await repo.upsertProblem(problem);
    ref.read(remoteSyncServiceProvider).pushLeetCodeProblem(problem);
    ref.invalidate(leetcodeProblemsProvider);
  } catch (_) {
    if (mounted) setState(() => _saving = false);
    _reportRetrackFailure("Couldn't save — your changes are still here");
    return;
  }

  // Only once the write has actually landed is there nothing left to recover.
  if (_isCreate) {
    _draftClosed = true;
    _draftTimer?.cancel();
    unawaited(_draftStore.clear());
  }
  if (mounted) Navigator.of(context).pop(true);
  ```

  The ordering matters: the `return` in the catch is what keeps a failed save
  from clearing the draft that is now the only copy of the work.

---

### [High] LC-04 — Editing a problem overwrites its review state from a stale snapshot

- **Location:** `lib/features/leetcode/leetcode_track_modal.dart:852-877` (`_save`); `lib/data/repositories/drift_repositories.dart:486-529` (`upsertProblem`)

- **Issue:** In edit mode `_save` builds a whole new row out of `widget.existing`
  — the copy captured when the sheet opened — and never re-reads the database:

  ```dart
  version: existing == null ? 0 : existing.version + 1,
  ...
  solvedAt:    existing?.solvedAt ?? now,
  interval:    existing?.interval ?? 0,
  ease:        existing?.ease ?? 2.5,
  dueAt:       existing?.dueAt,
  reviewCount: existing?.reviewCount ?? 0,
  ```

  `upsertProblem` then does `insertOnConflictUpdate` with every column set — a
  full-row overwrite, not a partial update. So anything that changed the row
  while the sheet was open is destroyed:

  - **Lost review progress.** A `pullLeetCodeProblems` tick
    (`remote_sync_service.dart:1282`) lands a grade made on another device while
    the modal is open. That write advances the row to version *M*. Saving the
    modal writes `existing.version + 1` carrying the *pre-pull*
    `interval`/`ease`/`dueAt`/`reviewCount`, rolling the schedule back to where
    it stood minutes ago.

  - **A version number that goes backwards.** When *M* > `existing.version + 1`,
    the local row's version *decreases*. Because `remoteVersionWins`
    (`firestore_document_mapper.dart:96`) is version-first, the remote copy now
    outranks the local one, and the very edit that was just saved gets reverted
    by the next pull.

  The window is not theoretical. `leetCodeProblemMenuItems` offers "Edit…" from
  the session card (`leetcode_session_page.dart:309`), the cram card
  (`leetcode_cram_page.dart:414`), the deck tiles and the dashboard feed — all
  places where a sync tick can land underneath an open sheet. The session page
  is careful about exactly this everywhere else (`refreshFromLive` at `:93`
  refuses to roll back a newer version); the modal is the one write that isn't.

- **Fix:** Re-read the row inside `_save` and rebase onto it, keeping the user's
  edits for the fields the form owns and the database's values for the fields it
  doesn't. The split is already spelled out in `restoreLeetCodeProblemSrs` — SRS
  fields belong to the deck, content fields to the form.

  ```dart
  final repo = ref.read(leetCodeRepositoryProvider);

  // Whatever the row holds *now*, not what it held when the sheet opened.
  final current = existing == null ? null : await repo.getProblem(existing.id);
  final base = current ?? existing;

  final problem = LeetCodeProblem(
    id: base?.id ?? newId(),
    createdAt: base?.createdAt ?? now,
    updatedAt: now,
    version: base == null ? 0 : base.version + 1,
    deletedAt: base?.deletedAt,
    // …content fields read from the form, unchanged…
    // SRS + solvedAt come off the live row, never the captured snapshot:
    solvedAt: base?.solvedAt ?? now,
    interval: base?.interval ?? 0,
    ease: base?.ease ?? 2.5,
    dueAt: base?.dueAt,
    reviewCount: base?.reviewCount ?? 0,
  );
  ```

  `deletedAt: base?.deletedAt` also closes a smaller bug in the same expression:
  the current constructor omits `deletedAt` entirely, so saving an edit
  resurrects a problem that was tombstoned while the sheet was open.

---

### [High] LC-05 — "Fetching your latest submission…" can get stuck on screen forever

- **Location:** `lib/features/leetcode/leetcode_loading_toast.dart:44-69` and `:103-114`

- **Issue:** `showLeetCodeToast` inserts an `OverlayEntry` and returns a
  `dismiss` that flips a `ValueNotifier`:

  ```dart
  final dismissRequested = ValueNotifier<bool>(false);
  void dismiss() {
    if (dismissed) return;
    dismissed = true;
    dismissRequested.value = true;
  }
  ...
  overlay.insert(entry);        // :67 — the entry builds on the *next* frame
  ```

  Removal is driven entirely by `_LeetCodeToastState`, which subscribes in
  `initState` (`:109`) and only reacts to *changes*:

  ```dart
  void _handleDismissRequested() {
    if (!widget.dismissRequested.value) return;
    _controller.reverse().whenCompleteOrCancel(widget.onDismissed);   // entry.remove()
  }
  ```

  `initState` never checks the notifier's current value. So if `dismiss()` runs
  before the entry's first build, the flag is already `true` when the listener
  attaches, `_handleDismissRequested` never fires, and **`entry.remove()` is
  never called**. The toast is pinned on screen for the rest of the app's life,
  and because a spinner toast has no actions it is wrapped in `IgnorePointer`
  (`:233`) — the user cannot click it away.

  The reachable trigger is `startLeetCodeTrackFlow` (`leetcode_actions.dart:52-66`),
  which shows the toast and dismisses it the moment the fetch settles. With no
  network, `http.post` rejects on a host-lookup failure in single-digit
  milliseconds — inside the same ~16 ms frame gap the overlay insert is waiting
  on. The same show-then-dismiss shape is in `_fetchLatestSubmission`
  (`leetcode_track_modal.dart:697`) and `_fetchByTypedTitle` (`:725`).

  Reproduced — show and dismiss within one frame gap, then pump 1 s:

  ```
  Expected: no matching candidates
    Actual: _TextWidgetFinder:<Found 1 widget with text "Fetching…">
  ```

  `pumpAndSettle` also times out against it, since the orphaned
  `CircularProgressIndicator` animates forever — a useful second signal that the
  entry is genuinely still live rather than merely painted.

- **Fix:** Handle the not-yet-built case in `dismiss` itself, where the entry is
  in scope. `OverlayEntry.mounted` is exactly this signal.

  ```dart
  void dismiss() {
    if (dismissed) return;
    dismissed = true;
    // Dismissed before the toast ever built: there is no State to hear the
    // notifier, so take the entry out directly instead of animating it out.
    if (!entry.mounted) {
      entry.remove();
      return;
    }
    dismissRequested.value = true;
  }
  ```

  Belt-and-braces, also make `initState` honour a flag that is already set —
  off a post-frame callback, since `onDismissed` removes the entry and must not
  run during build:

  ```dart
  widget.dismissRequested.addListener(_handleDismissRequested);
  if (widget.dismissRequested.value) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _handleDismissRequested());
  }
  ```

  `dismissRequested` is also never disposed; dispose it from `onDismissed`
  alongside `entry.remove()`.

---

### [High] LC-06 — No timeout on any LeetCode API call, so the Track flow can hang indefinitely

- **Location:** `lib/data/remote/leetcode_api_client.dart:196-226` (`_post`), `:13-16`

- **Issue:** `_post` calls `_http.post(...)` with no `.timeout(...)`, and
  `LeetCodeApiClient` is constructed with a bare `http.Client()` (`:14`), which
  carries no default deadline. A connection that opens and then stalls — a
  captive portal, a hung proxy, a half-open socket after a laptop wakes from
  sleep — leaves the future pending forever.

  Every caller is blocked behind it:

  - `startLeetCodeTrackFlow` (`leetcode_actions.dart:59`) `await`s the fetch
    *before* opening the modal. A hang means the Track button appears to do
    nothing at all, with an undismissable spinner toast over the app (the same
    visible symptom as LC-05, but a different cause and a different fix).
  - `_fetchLatestSubmission` / `_fetchByTypedTitle` leave `_retracking` true, so
    Retrack stays disabled for the life of the sheet.
  - `_SearchPopoverContentState._search` (`leetcode_search_popover.dart:54`)
    leaves `_searching` true — a permanent spinner in the popover.
  - `leetcodeQuestionCountsProvider` never resolves, so the progress rings show
    bare counts with no denominators.

  `fetchMostRecentAcceptedSubmission` is worse than one hang: it awaits
  `fetchBySlug` (`:72`) after its own request, so it can stall on either of two
  unbounded round-trips.

- **Fix:** Bound every request at the one place they all pass through.

  ```dart
  class LeetCodeApiClient {
    LeetCodeApiClient({http.Client? httpClient, Duration? timeout})
      : _http = httpClient ?? http.Client(),
        _timeout = timeout ?? const Duration(seconds: 12);

    final Duration _timeout;

    Future<Map<String, dynamic>> _post(
      String query,
      Map<String, dynamic> variables,
    ) async {
      final response = await _http
          .post(
            _endpoint,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'query': query, 'variables': variables}),
          )
          .timeout(
            _timeout,
            onTimeout: () => throw Exception('LeetCode API timed out.'),
          );
      // …unchanged…
    }

    void close() => _http.close();
  }
  ```

  Every call site already treats a thrown request as "no result" — the empty
  form, the draft fallback, the `catch (_)` in `_openSearch` — so a timeout needs
  no new handling anywhere, only a deadline to throw at.

  Separately, the `http.Client` at `:14` is never closed:
  `leetCodeApiClientProvider` (`lib/app/providers.dart:792`) is a plain
  `Provider` with no `ref.onDispose`. Add `ref.onDispose(client.close)` there
  alongside the `close()` above.

---

### [Medium] LC-07 — "Clear filters" clears the filter but not the search box

- **Location:** `lib/features/leetcode/leetcode_review_deck.dart:146-158` (`onClearFilters`); `:308-318` (the field)

- **Issue:** The Review Deck's search field is uncontrolled — `_ControlBar`
  builds it with only an `onChanged` and no `controller`:

  ```dart
  VoyagerTextField(
    onChanged: (v) => ref.read(leetCodeDeckSearchQueryProvider.notifier).state = v,
    decoration: const InputDecoration(hintText: 'Search problems', …),
  )
  ```

  The provider is therefore write-only from the field's point of view: it can
  push text out, but nothing pushes text back in. `_EmptyDeck`'s "Clear filters"
  (`:148-157`) sets the provider to `''`, so the grid un-filters — while the box
  goes on displaying the query that emptied it.

  Reproduced — type a non-matching query, tap "Clear filters", read the field:

  ```
  Expected: ''
    Actual: 'zzzznomatch'
  ```

  The user is left looking at a populated search box over an unfiltered grid,
  and their next keystroke appends to the invisible-but-live stale text, so the
  grid snaps back to "No matches" on a single character. The difficulty pills
  and the tag filter clear correctly — they read their state from the provider
  on every build — which makes the search box the odd one out and the
  inconsistency harder to attribute.

- **Fix:** Give the deck a controller so the field is a view of the provider
  rather than a one-way writer. `_ControlBar` has to become stateful to own it.

  ```dart
  class _ControlBarState extends ConsumerState<_ControlBar> {
    late final TextEditingController _search = TextEditingController(
      text: ref.read(leetCodeDeckSearchQueryProvider),
    );

    @override
    void dispose() {
      _search.dispose();
      super.dispose();
    }

    @override
    Widget build(BuildContext context) {
      // Adopt any change made from outside the field — "Clear filters" is the
      // only one today, but a saved-search restore would land here too.
      ref.listen<String>(leetCodeDeckSearchQueryProvider, (_, next) {
        if (_search.text != next) _search.text = next;
      });
      return VoyagerTextField(
        controller: _search,
        onChanged: (v) =>
            ref.read(leetCodeDeckSearchQueryProvider.notifier).state = v,
        …
      );
    }
  }
  ```

  The `_search.text != next` guard is what keeps the field's own `onChanged`
  from bouncing back through the listener and resetting the caret mid-word.

---

### [Medium] LC-08 — Soft-deleting a problem is the one mutation that doesn't bump its version

- **Location:** `lib/data/repositories/drift_repositories.dart:533-544` (`softDeleteProblem`)

- **Issue:** The delete is a raw column write that sets the tombstone and the
  timestamp but leaves `version` alone:

  ```dart
  await (_db.update(_db.leetCodeProblemsTable)..where((t) => t.id.equals(id)))
      .write(LeetCodeProblemsTableCompanion(
        deletedAt: Value(utcNow()),
        updatedAt: Value(utcNow()),
      ));
  ```

  Every other mutation on this table goes through `LeetCodeProblem.copyWith` (or
  the modal's explicit `version + 1`) and does bump. So the tombstone is the only
  revision that has to win on `updatedAt` alone — and `remoteUpdatedAtWins`
  (`firestore_document_mapper.dart:83`) compares two client wall-clocks, not a
  server timestamp.

  A device whose clock runs a few minutes fast can therefore keep a live copy
  alive against a delete made after it: A deletes at 10:00 (version 5), B had
  edited at what its clock called 10:03 (version 6), B's push wins on version and
  the problem comes back on both devices. A bumped tombstone would at least make
  the delete competitive on the ranking that is checked first.

  Two sibling repositories in this same file already do it the careful way, and
  one carries a comment about exactly this class of bug (`:249-259`):

  ```dart
  // DriftJournalRepository.softDeleteEntry  (:256)
  final current = await getEntry(id);
  if (current == null) return;
  await upsertEntry(current.copyWith(deletedAt: utcNow()));

  // DriftFinanceRepository.softDeleteTransaction  (:1540)
  await upsertTransaction(transaction.copyWith(
    updatedAt: utcNow(), version: transaction.version + 1, deletedAt: utcNow(),
  ));
  ```

  To be precise about what is *not* broken: `deleteLeetCodeProblem`
  (`leetcode_actions.dart:112-125`) re-reads the row before pushing, so the local
  row and the pushed document do agree on the version — the specific divergence
  the journal comment warns about is avoided here. The ranking weakness is what
  remains.

- **Fix:** Match the sibling repositories — read, bump, upsert:

  ```dart
  @override
  Future<void> softDeleteProblem(String id) async {
    final current = await getProblem(id);
    if (current == null) return;
    // copyWith bumps version and stamps updatedAt.
    await upsertProblem(current.copyWith(deletedAt: utcNow()));
  }
  ```

  `upsertProblem` already calls `_syncActivity?.recordLocalSave(...)`, so the
  explicit call at `:543` comes out with it. `deleteLeetCodeProblem`'s
  re-read-then-push works unchanged.

---

### [Medium] LC-09 — Rapid toggling in the session-display menu silently discards a toggle

- **Location:** `lib/features/leetcode/leetcode_review_deck.dart:460-513` (`_SessionDisplayList`)

- **Issue:** The menu captures settings once per build and every row writes a
  delta against that captured value:

  ```dart
  final settings = ref.watch(settingsProvider).valueOrNull;      // :466
  ...
  onTap: () => ref.read(settingsProvider.notifier)
      .saveSettings(toggle.apply(settings, !toggle.value)),      // :485-487
  ```

  `saveSettings` (`lib/app/providers.dart:549`) awaits the repository write
  *before* publishing the new state, so the popover does not rebuild until the
  database round-trip completes. Two taps inside that window both read the same
  stale `settings`:

  1. Tap "Hide tags" → writes `{hideTags: true, hideCode: false}`.
  2. Tap "Hide solution code" before the first write lands → `settings` is still
     the original → writes `{hideTags: false, hideCode: true}`.

  The second write wins wholesale and "Hide tags" is silently back off — its
  checkbox even flickers on and then off again as the two states publish. The
  same-row variant is quieter and more likely: double-tapping one checkbox
  computes `!toggle.value` from the same stale snapshot twice, so the second tap
  writes the value that is already being written and appears to do nothing at
  all.

  This is the "two deltas on one document key cancel each other" shape — each tap
  is a delta computed against a base the other tap has already moved.

- **Fix:** Compute the delta against the notifier's current value at tap time
  rather than against the build-time capture:

  ```dart
  onTap: () {
    final notifier = ref.read(settingsProvider.notifier);
    final live = ref.read(settingsProvider).valueOrNull;
    if (live == null) return;
    // Read the flag off the live row too — the captured `toggle.value` is
    // exactly as stale as the settings it came from.
    final current = _hideToggles(live).firstWhere((t) => t.label == toggle.label);
    notifier.saveSettings(current.apply(live, !current.value));
  },
  ```

  That narrows the window to the notifier's own state, which `saveSettings`
  updates synchronously after its await. If taps faster than a disk write are a
  concern, serialize them through a single-slot queue in `SettingsNotifier` so
  each delta applies to the outcome of the previous one.

---

### [Medium] LC-10 — One failed count fetch blanks the progress-ring denominators for the whole session

- **Location:** `lib/app/providers.dart:1142-1148` (`leetcodeQuestionCountsProvider`); consumed at `lib/features/leetcode/leetcode_progress_rings.dart:23`

- **Issue:**

  ```dart
  final leetcodeQuestionCountsProvider = FutureProvider<LeetCodeQuestionCounts>((ref) {
    ref.keepAlive();
    return ref.watch(leetCodeApiClientProvider).fetchQuestionCounts();
  });
  ```

  `keepAlive()` means the provider is never disposed, and a `FutureProvider` that
  has settled into an error state never re-runs on its own. Since this is usually
  first read while the dashboard is painting — often in the app's first seconds,
  before Wi-Fi has associated — a single failure there is permanent for the
  process.

  The rings degrade without crashing (`counts == null` falls back to
  `'$totalSolved solved'` at `:52`), but the progress arcs are pinned at 0
  (`:46-48`, `:90-92`) and the per-difficulty labels lose their `/total`. Nothing
  on screen says the fetch failed, and there is no control to retry — the user
  has to restart the app.

  This is distinct from LC-06: adding a timeout makes the failure prompt rather
  than eventual, but it still latches.

- **Fix:** Let a failed fetch expire so the next read retries, while still
  caching a success for the session:

  ```dart
  final leetcodeQuestionCountsProvider =
      FutureProvider<LeetCodeQuestionCounts>((ref) async {
    // Hold a *successful* answer — the published counts move a handful of times
    // a week. A failure is not worth caching at all.
    final link = ref.keepAlive();
    try {
      return await ref.watch(leetCodeApiClientProvider).fetchQuestionCounts();
    } catch (_) {
      link.close();
      rethrow;
    }
  });
  ```

  Then have the main ring's tap offer a retry when `countsAsync.hasError`
  (`leetcode_progress_rings.dart:44-56`) instead of only launching the problemset
  URL — the ring is already the tap target and already knows the error state.

---

### [Low] LC-11 — A hand-flipped tile inverts when the search starts matching only its back

- **Location:** `lib/features/leetcode/leetcode_review_deck.dart:45` and `:169-184`

- **Issue:** `_flipped` records the difference from the search-derived baseline
  rather than the face itself:

  ```dart
  final backOnly = leetCodeMatchesBackOnly(problem, keywords);
  return LeetCodeMiniFlashcard(
    showBack: backOnly != _flipped.contains(problem.id),
    onFlipped: (showingBack) => setState(() {
      if (showingBack == backOnly) _flipped.remove(problem.id);
      else _flipped.add(problem.id);
    }),
  );
  ```

  That is the right shape, but `_flipped` is never reconciled when `backOnly`
  changes underneath it. With no query, flipping tile X by hand records
  `_flipped = {X}` (because `true != false`). Now type a query that matches X
  only on its back: `backOnly` becomes `true`, so
  `showBack = (true != true) = false` and the tile turns to its **front** — the
  exact opposite of what the back-only match exists to do, and precisely the
  inversion the comment at `:165-168` says it is guarding against.

  Cosmetic and self-correcting on the next tap, hence Low — but it makes the
  back-only search affordance unreliable for any tile the user has already
  touched.

- **Fix:** Record *which* baseline the override was made against, so the entry
  retires itself once the search moves that baseline.

  ```dart
  /// Problems the user turned over by hand, mapped to the baseline face that
  /// was in force when they did it. An override only stands while that baseline
  /// still holds — once the search re-answers the question the flip was
  /// answering, the search wins.
  final Map<String, bool> _flipped = {};
  ```

  ```dart
  final backOnly = leetCodeMatchesBackOnly(problem, keywords);
  final baseline = _flipped[problem.id];
  final overridden = baseline != null && baseline == backOnly;
  return LeetCodeMiniFlashcard(
    key: ValueKey(problem.id),
    problem: problem,
    keywords: keywords,
    showBack: backOnly != overridden,
    onFlipped: (showingBack) => setState(() {
      if (showingBack == backOnly) {
        _flipped.remove(problem.id);
      } else {
        _flipped[problem.id] = backOnly;
      }
    }),
  );
  ```

  Walking the bug case through: no query → `baseline == null`, `overridden` false,
  front shown. User flips → `_flipped[X] = false`, so `overridden` is true and the
  back shows. Back-only query arrives → `backOnly` is now `true` but the recorded
  baseline is `false`, so `overridden` is false and `showBack = true` — the back
  stays up, which is what the match asked for. Clearing the query restores the
  user's manual flip rather than discarding it.

---

### [Low] LC-12 — Search re-derives and re-lowercases every problem's text on every keystroke, twice

- **Location:** `lib/features/leetcode/leetcode_review_deck.dart:63-71` and `:169-172`; `lib/features/leetcode/leetcode_mini_flashcard.dart:17-52`

- **Issue:** The filter runs per problem, per keystroke:

  ```dart
  return leetCodeFrontSearchText(p).toLowerCase().contains(needle) ||
      leetCodeBackSearchText(p).toLowerCase().contains(needle);
  ```

  `leetCodeFrontSearchText` builds a fresh list and `join(' ')`s the id, title,
  full description and every tag; `leetCodeBackSearchText` does the same across
  the algorithm, both complexity strings and the full explanation of *every*
  solution. Both results are then `toLowerCase()`d — allocating a second copy of
  each — and thrown away.

  The grid's `itemBuilder` then calls `leetCodeMatchesBackOnly` (`:169`) for each
  visible tile, which computes **both strings again** for a third and fourth
  allocation. So a library of 400 problems with paragraph-length descriptions
  allocates on the order of a megabyte of transient strings per character typed,
  on top of a full `sortLeetCodeProblemsByMastery` and a rebuilt sorted tag set
  in `_TagFilterButton` (`:359`).

  It is not visibly janky at current library sizes, which is why this is Low —
  but it is all avoidable, and it scales linearly with a collection that only
  grows.

- **Fix:** Fold the case once, at the source, and memoise per library revision. A
  small derived provider keyed off `leetcodeProblemsProvider` is the natural
  home, since it invalidates exactly when the library changes:

  ```dart
  /// Lowercased front/back haystacks per problem id, rebuilt only when the
  /// library itself changes rather than on every keystroke.
  final _deckSearchIndexProvider =
      Provider<Map<String, ({String front, String back})>>((ref) {
    final problems = ref.watch(leetcodeProblemsProvider).valueOrNull ?? const [];
    return {
      for (final p in problems)
        p.id: (
          front: leetCodeFrontSearchText(p).toLowerCase(),
          back: leetCodeBackSearchText(p).toLowerCase(),
        ),
    };
  });
  ```

  The filter then becomes two `contains` calls on cached strings, and
  `leetCodeMatchesBackOnly` can take that pair instead of recomputing — keeping
  the pure helpers in `leetcode_mini_flashcard.dart` as testable as they are
  today.

---

## Verified clean

Checked closely and found sound. Recorded so a later pass doesn't re-litigate
them:

- **SRS arithmetic.** `gradeLeetCodeProblem` / `restoreLeetCodeProblemSrs` /
  `resetLeetCodeProblemSrs` are correct, and `restoreLeetCodeProblemSrs`
  deliberately builds the object longhand because `copyWith` cannot restore a
  null `dueAt` — the comment at `leetcode_srs_engine.dart:38-43` is accurate, not
  aspirational.
- **Session undo/redo.** The snapshot-the-queue-either-side design in `_GradeStep`
  handles the re-queue of a failed problem correctly, and `refreshFromLive`'s
  `fresh.version > entry.version` guard is what stops a half-refetched provider
  from rolling a just-saved grade back.
- **Cram bucket invariants.** `_applyDecision` can never orphan an id, and
  `_syncProblems` prunes deleted ids out of the buckets *and* out of every history
  snapshot (`_CramStep.retainOnly`), so undo cannot resurrect a deleted problem.
- **`_solutionEditors` can never be empty.** Remove is only rendered when
  `number != null`, i.e. `length > 1`, so `_addSolution`'s `_solutionEditors.last`
  at `:583` cannot throw.
- **`monthGridDates` always returns 42.** `_MonthTile`'s `cells[row * 7 + col]`
  over 6×7 is in range for every month, including a 28-day February starting on
  the first day of the week.
- **`niceAxisStep` bounds the chart.** `step >= dataMax / (lines - 1)` holds by
  construction, so `maxY = yStep * 3` never clips a curve.
- **NeetCode 150 list.** Exactly 150 entries, no case-insensitive duplicates, and
  `countNeetCode150Matches` dedupes — the ring cannot read over 150/150.
- **`GeometricProgressRing` clamps.** A library with duplicates tracked can push
  `totalSolved / counts.total` past 1.0, but the arc clamps at
  `geometric_progress_ring.dart:85`; only the numeric label goes over, which is
  truthful reporting rather than a bug.
