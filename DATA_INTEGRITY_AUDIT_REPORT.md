# Voyager data-integrity & sync audit — 2026-09-16

Scope: every path that can lose, corrupt, silently overwrite or strand user data
in the Drift/SQLite + Firestore + outbox + character-CRDT stack, re-verifying
the fixes claimed in `JOURNAL_DATA_LOSS_POSTMORTEM.md` (Workstream A) and
hunting app-wide for anything else (Workstream B).

Audited at commit `de96fab` ("Data loss outage issue fix").

**Bottom line: sync is not safe yet.** Most of the postmortem's fixes hold, but
the audit found four P0 paths, each reproduced by a failing test, that lose or
corrupt journal, dream and to-do text in ordinary use:

- **Offline or refused edits get reverted.** A pull writes older text from the
  operation log over newer local text.
- **Another device's typing gets doubled.** An open editor re-records pulled
  text as its own edit.
- **Live sync stops at launch.** The sync service is torn down whenever a
  setting changes, which also drops unsent edits.
- **Another device's text gets deleted.** Opening an entry before this device
  has pulled deletes that text everywhere.

One more P1 wipes user-authored settings content across devices. A verified
prototype fix exists for everything except that settings item, which needs a
product decision (§8).

> **Update, same day: the fixes are now applied to the working tree** — the
> prototype, settings options A and C (§8), and the fixes this report had only
> recommended. §9 is the per-finding status, including the three low-severity
> items deliberately left unchanged and the risks that remain.

---

## 0. What was run

| | |
|---|---|
| Baseline full suite at `de96fab` | Pre-existing suite passes apart from 1 unrelated failure (`jobs_toolbar_alignment_test`). The **16 new audit tests all fail** on `de96fab`; 15 of them pass with the prototype (the settings test needs §8). |
| Postmortem-cited test files (9 files) | 77/77 pass |
| Mutation checks on postmortem guards (13 mutations) | 7 caught, **6 survive** (§2) |
| Prototype fix (detached worktree, not applied to your tree) | Full suite: 3088 passed, 17 skipped, 2 failed — the settings test (not prototyped, §8) and the pre-existing `jobs_toolbar_alignment_test`. Analyzer output for all 11 touched files identical to HEAD. `git apply --check` clean against `de96fab`. |

New test files (untracked, in `test/`; they fail on `de96fab` by design):

- `test/sync_pending_char_ops_durability_test.dart`: P0-1, P0-2, P0-4, P1-1 and the two concurrent-edit guard tests
- `test/sync_service_lifetime_test.dart`: P0-3 (runs the real provider graph)
- `test/sync_outbox_media_drain_test.dart`: P1-2
- `test/sync_stale_retry_regression_test.dart`: P1-3, P2-1
- `test/text_delta_injector_fallback_test.dart`: P1-6

Prototype patch: `DATA_INTEGRITY_AUDIT_PROTOTYPE.diff` (lib only, 11 files,
+716/−84). It is a verified *proposal*, not reviewed production code. See §5
for what it does and does not cover.

---

## 1. Executive summary — worst first

| ID | Sev | What happens to the user | Confidence |
|---|---|---|---|
| P0-1 | P0 | Journal, dream or to-do text edited while offline, or while the write gate is refusing writes, is **reverted in SQLite by the next pull**. After a restart or hot restart it is gone for good; the outbox replay then publishes the reverted text. | **Confirmed** (3 tests) |
| P0-2 | P0 | With an entry open but unfocused on one device, another device's typing comes back **doubled** (`Hello  tthheerree`). If the entry is focused, the merge produces garbage (`HeHlleo tlhelre!o there`). | **Confirmed** (2 tests) |
| P0-3 | P0 | Any settings save rebuilds `RemoteSyncService`. That discards unsent character operations, drops pending uploads without an outbox row, and **kills live sync**. The startup warm-up does this every launch, right after starting live sync. | **Confirmed** (3 tests on the real provider graph) |
| P0-4 | P0 | Opening an entry whose remote operation log is ahead of SQLite (another device edited, this device hasn't pulled, which P0-3 makes the normal state) **deletes the other device's text everywhere** on the next save. | **Confirmed** (1 test) |
| P1-1 | P1 | Navigating pages writes a synced settings field, so a device with stale settings re-uploads the whole settings document. That **wipes another device's newer snippets, job-experience snippets, profile URLs and palette**. | **Confirmed** (1 test) — needs a product decision |
| P1-2 | P1 | Image metadata (media assets and references) that failed to upload is **silently deleted from the outbox** and never re-sent. | **Confirmed** (1 test) |
| P1-3 | P1 | An older upload acknowledged late **clears the outbox row** that a newer, refused upload of the same document queued. The newer edit is owed to nobody. | **Confirmed** (1 test) |
| P1-4 | P1 | Several upload paths bypass the outbox. The teardown / alt-tab flush, the to-do panel close, most batch pushes, journal deletion and workout set logs all lose the failure (unhandled error, nothing queued). | High (code-level; mutation M9) |
| P1-5 | P1 | Awaited network pushes inside multi-step local operations abort them halfway: a list delete that never deletes the list, a folder delete that stops after one deck, a repeating task that never rolls forward. | High |
| P1-6 | P1 | `TextDeltaInjector`'s fallback **appends the whole remote document** to a focused editor, and autosave publishes the doubled text. | **Confirmed** (1 test) |

The P0s share one systemic cause (§4, X1–X2). The operation log is treated as
the authority for text, but what goes into it lives only in memory and never
catches up with remote operations once loaded. Around that, a provider graph
keeps tearing down the memory holding it (X5).

**Ship-order warning:** fixing P0-3 on its own brings live sync back, which
makes P0-2 (the doubling) far more frequent. P0-2 is currently masked because
live sync is dead. Land P0-2 and P0-3 together.

---

## 2. Workstream A — postmortem claims

"Mutation" means the guard was removed in place, the cited tests were run, and
the file was restored (checksums verified afterwards).

| # | Claim | Status | Notes / gaps |
|---|---|---|---|
| A1 | `FirestoreWriteGate` bounds in-flight writes (50, 10 until startup drain); refusals go to the outbox | **Pass with gaps** | Startup limit pinned (M11 caught). Gap: it counts *commits*, not mutations. One `batch.commit` of 40 is one slot, so the real ceiling is 50×40 = 2000 queued writes plus operation-log entries (P2-7). Gap: several upload paths don't route refusals to the outbox (P1-4). |
| A2 | Write timeout + stall latch; reopens via `waitForPendingWrites()`; stall arms its own probe | **Pass** (tests pinned: M3, M4 caught) | Gap: a *rejected* probe counts as "drained" (`firestore_write_gate.dart:246`). The SDK rejects outstanding `waitForPendingWrites` on a user change, so sign-out/sign-in, or auth restoring after the gate is built, lifts both latches over a backlog that never drained (P2-6, medium). |
| A3 | Batches chunk at 40 everywhere | **Partial** | `upsertDocumentsBatch`, `appendOperationsBatch`, both delete paths and the outbox all chunk. `appendOperationGroup` is one unbounded batch by design, but its comment still says "splitting at 500" and a very large reseed or compaction can exceed Firestore's 10 MiB request cap (P3-1). **Not pinned:** 40→500 passes every test (M5); unchunked op batches pass (M12). |
| A4 | `compactOperationLog` stands down on unsent backlog | **Pass** (M6 caught) | The guard reads `hasStartupBacklog || isPaused`, which starts pessimistic every launch, so it is durable across restarts. Inherits A2's probe-rejection gap. |
| A5 | Entry switch uses `flushDocumentLocal` (journal + dream) | **Pass** (M1, M2 caught) | Siblings not converted: the to-do edit panel still calls `flushDocument` three times (`todo_edit_panel.dart:234,361,643`), and `VoyagerApp._flushAllPendingEdits` uses the raw `flushAllPending`. Neither blocks the UI (unawaited or bounded), but both run the upload **outside `_runRemoteSave`** (P1-4). |
| A6 | Body buffer identity (`bodyTextFor` / `_bodyEntryId`) | **Partial** | Write sites use `bodyTextFor`, and `_handleChanged` files drafts by `_bodyEntryId`. Remaining unqualified sites: journal `setBodyText(recordAsEdit)` records against `widget.entry?.id`; the flush writes `setBodyText(body)` into whatever the controller holds (`journal_page.dart:1123`) (P3-7). **Not pinned:** an unqualified `bodyTextFor` passes every test (M10), as the postmortem acknowledges. The mismatch log is still present. |
| A7 | To-do fire-and-forget uses `pushTodoTaskInBackground` | **Partial** | The 12 sites are converted. Siblings with the same defect remain: `pushTodoTasksBatch` and all non-ranking batch pushes, `completeTodoTask` awaiting a raw `pushTodoTaskNow`, `todo_page.dart:1602`, workout `_pushSetLogs`, `pushJournalById` (P1-4, P1-5). **The claimed coverage does not exist:** the "write gate stalls" group only tests the gate, and reverting `pushTodoTaskInBackground` to a raw push passes every test (M9). |
| A8 | `OutboxSyncWorker` writes through the shared gate; a paused gate stops the drain | **Partial** | Code is correct: the shared provider is used (`providers.dart:401`, `main.dart:134`). **Not pinned:** bypassing the gate (M13) and removing the `isPaused` break (M7) both pass. The per-row CRDT pusher loop doesn't re-check `isPaused`. Refusals and timeouts count toward the 7-day park, and parked rows are never drained again (P2-2). |
| A9 | Drain resumes when the gate reopens | **Pass** (M8 caught) | — |
| A10 | Calendar legacy-id alias | **Pass** | Two mapper tests exist; not mutation-checked. The three copies of the local↔remote id mapping the postmortem flagged are still three. |
| A11 | Cited tests still exist and fail if the guard is removed | **7 of 13 pinned** | M5, M7, M9, M10, M12, M13 survive. Tests reference constants symbolically (`firestoreWriteChunkSize`) or assert outcomes the unguarded code also produces. |

---

## 3. Findings catalog

Format per finding: **Evidence** (file:line, symbol, scenario) · **Impact** ·
**Confidence** · **Fix** · **Test**.

### 3.1 Character CRDT, pulls and editors

#### P0-1 — Pull reverts text this device never managed to upload

- **Evidence.**
  - `mergeJournalEntryFromRemote` (`firestore_document_mapper.dart:1485`) takes `crdtText.body` unconditionally. The same holds for dream entries (`:1749`) and to-do notes, bypassing the version comparison every other field goes through.
  - `CharacterSequenceCrdtMerger._pickBody` prefers the text rebuilt from character operations over the newest snapshot.
  - The operations that would carry the local text exist only in `CharacterOpRegistry` (memory). `restorePendingOps` puts refused ones back *in memory* only.
- **Scenarios** (all three reproduced):
  1. Edit while writes are refused (gate paused or stalled, offline error), then restart or hot restart, then the startup pull → SQLite body reverted.
  2. Same as 1, but the outbox drain runs first (it does at launch: `_onAuthStateChanged` starts the drain before the 900 ms warm-up). `pushOutboxDocument` uploads a snapshot with no character operations, `_pickBody` still prefers the old operations, and the pull reverts.
  3. No restart. The offline→online pull (`main.dart:104`) runs concurrently with the drain and lands first, reverting SQLite while the operations are still pending. If the entry is open, P0-2 then turns the revert into permanent tombstones.
- **Impact.** Silent text loss in SQLite, then propagated. Writes Firestore *accepted* into its persistent cache are safe (queries see them). The exposure is writes **refused by the gate** (common while wedged: limit 10 at startup, 0 while stalled), operations still inside the 1 s debounce at process death, and every P0-3 rebuild. **The gate fix raised this exposure.** Before it, writes queued in Firestore's cache; now they are refused into memory.
- **Confidence:** confirmed.
- **Fix** (prototyped):
  - On pull, fold remote operations into any live session (`CharacterOpSession.absorbRemote`). If the session has pending operations, write `session.text`.
  - With no session, keep the local text when the row outranks the resolved snapshot and disagrees with it, and queue the document (`OutboxSyncWorker.recordOwedUpload`).
  - Also keep local text while a conflict is quarantined for the document. "Keep mine" resolves from the row, so overwriting it would publish the other side.
  - On replay with no session, re-derive the missing operations by diffing the log text to the row (`_recoverLostOperations`). If that diff would delete another client's characters, quarantine a conflict instead of deleting.
- **Test:** `sync_pending_char_ops_durability_test.dart` — "offline text edits…" ×3, plus "both devices wrote while one of them was offline" ×2 (guards against the fix deleting the *other* device's text).

#### P0-2 — Remote text entering an open editor is re-recorded as a local edit

- **Evidence.**
  - `CharacterOpSession` is loaded once, in `prepareEditingSession`, and never absorbs remote operations afterwards. Every route that puts remote text into a mounted editor then desyncs it:
    - `journal_page.dart:2195` / `dream_journal_page.dart:947` call `setBodyText(updated.body, recordAsEdit: true)`. That diffs the editor's old text against the pulled text, inserting the other device's characters as this device's own. `FractionalIndex` is deterministic, so they land at *identical positions*.
    - The focused path injects the delta (`_handlePendingTextMerge`, `applyPending…TextMerge`) without recording. The next keystroke's `before` no longer matches the session, and `recordTextChange` falls through to `resetFromText` (`character_op_session.dart:145`). That re-seeds every character under new ids while the old ones stay live in the log.
    - To-do: `_handlePendingNotesMerge` and `_applyPendingNotesMerge` never update `_lastNotesText`, so the next keystroke diffs the remote change back up as a local edit.
  - The comment "these ops came off the remote chain and are already in the registry" is false.
- **Impact.** Text corruption on every device, silently, whenever two devices touch the same entry.
- **Confidence:** confirmed (journal). Dream and to-do follow by identical construction (high).
- **Fix** (prototyped):
  - `absorbRemote` at pull time.
  - `reanchorEditorText` diffs from the session's own text (usually a no-op). The pages call it instead of `recordX(before, after)`.
  - `_recordTextChange` treats "editor catching up to the session" as no edit. A real keystroke against a desynced session is re-applied onto the session's text (`_rebaseEdit`) instead of reseeding.
  - To-do panel keeps `_lastNotesText` in step.
- **Test:** "a pulled body pushed into an open editor", "a remote edit merged into a focused editor".

#### P0-4 — Opening an entry while the log is ahead deletes the other device's text

- **Evidence.** `prepareEditingSession` (`remote_sync_service.dart:885`) diffs `loaded.text → initialText` whenever they differ, treating SQLite as the truth. The comment covers the case where the log is *behind* (lost operations). When the log is *ahead* (another device edited, this device hasn't pulled), the diff tombstones that text. The tombstones sit pending and go out on the next save of the entry.
- **Impact.** Another device's edits deleted everywhere. The characters survive only as tombstones in `sync_operations` until compaction drops them (after 24 h of foreign quiet).
- **Likelihood.** Launch auto-opens the last entry before the startup pull, and P0-3 means no live sync all session.
- **Confidence:** confirmed.
- **Fix** (prototyped): only record the diff if every character it would tombstone is this device's (`opsReplacedBy`). Otherwise leave the session on the log and trigger a scoped pull, which updates SQLite, and the editor re-anchors through P0-2's path. Keystrokes typed before the pull lands are re-applied onto the session text, not diffed destructively.
- **Test:** "opening an entry whose remote log is ahead of this device".

#### P1-6 — `TextDeltaInjector` fallback appends the remote document

- **Evidence.** `text_delta_injector.dart:116` returns `'$localText\n$newRemoteText'` when neither prefix nor suffix align and the local text doesn't contain the old remote text. Example: both ends edited locally while the middle changed remotely.
- **Impact.** A focused editor shows and autosaves the document plus a full second copy.
- **Confidence:** confirmed.
- **Fix** (prototyped): return `localText`. The remote change is still in the log and arrives with the next pull. Existing `text_delta_injector_test` still passes.
- **Test:** `text_delta_injector_fallback_test.dart`.

#### P2-8 — Rebasing onto the live chain throws away an open editor's pending operations

- **Evidence.** `_rebaseCharOpsOnLiveChain` (`:287`) calls `loadSession`, which *replaces* the session. It is used by the Search save (`forceOverwriteJournalEntryText` session branch, `:535`) and all three conflict resolutions. The journal editor's unsent operations are dropped and its next keystroke is desynced. Before the fix that meant a reseed and duplication.
- **Impact.** The editor's last unsent keystrokes are lost when Search or conflict resolution touches the same entry. With the prototype's `_rebaseEdit` it no longer duplicates.
- **Confidence:** medium-high.
- **Fix:** `absorbRemote(ops)` then diff `session.text → target`, instead of `loadSession`.
- **Test:** open entry, type (pending), `resolveConflictKeepRemote`, type again, assert no doubling and the first keystrokes present.

#### P3-7 — Remaining unqualified buffer writes (journal)

- **Evidence.** The flush's `setBodyText(body)` (`journal_page.dart:1123`) writes `entryId`'s merged body into a controller that may hold another entry during the switch window. `setBodyText(recordAsEdit)` keys the record by `widget.entry?.id` (fixed to `_bodyEntryId` in the prototype).
- **Impact.** The same window as the postmortem's defect, but it only matters when a pending merge exists for the incoming entry.
- **Confidence:** medium.
- **Fix:** `setBodyTextFor(entryId, body)` that no-ops unless `_bodyEntryId == entryId`.

#### P3-10 — `applyPending{Journal,Dream}…TextMerge` write outside the save chain

- **Evidence.** These call `upsertEntry` directly, not through `saveLocalThenScheduleUpload`, and replace tags with the *remote* tags although the body is a merge.
- **Impact.** Stale tags until the next save; possible interleaving with a queued save.
- **Confidence:** medium.

#### P3-11 — `prepareEditingSession` futures dropped on the journal page

- **Evidence.** `journal_page.dart:3188,3319`, unawaited with no `catchError`. The dream page fixed this.
- **Impact.** Unhandled async errors, e.g. `permission-denied`.
- **Confidence:** high.

#### P3-14 — To-do notes: session text untrimmed, row trimmed

- **Evidence.** `_handleNotesChanged` records the untrimmed controller text; saves store `trim()`. Reopening diffs the log's untrimmed text against the trimmed row.
- **Impact.** Whitespace tombstone churn, no content loss.
- **Confidence:** medium.

### 3.2 Provider lifetime and startup

#### P0-3 — `RemoteSyncService` is rebuilt, and live sync killed, by settings saves

- **Evidence.**
  - `remoteSyncServiceProvider` does `ref.watch(settingsProvider)` (`providers.dart:489`). It also watches `weatherServiceProvider`, whose client provider watches the whole settings row (`:454`).
  - Any notifier `saveSettings` or `ref.invalidate(settingsProvider)` rebuilds the service. Callers include the startup warm-up (`main.dart:253`), quote/dream/journal settings dialogs, the dream split width and weather tiles.
  - `RemoteSyncService.dispose` (`:3246`):
    - clears `_charOpRegistry`: unsent operations are gone, and the text is never re-emitted (P0-1);
    - clears `_pendingRemoteSaves`: debounced uploads are dropped with no outbox row;
    - clears `_activelyEditedDocuments`: pulls stop buffering for the focused editor.
  - `liveSyncProvider` is rebuilt from the new service. The old controller is disposed and its subscriptions cancelled, and the new one is never `start()`ed. The warm-up calls `liveSync.start()` (`main.dart:236`) and then invalidates settings, so **live sync is dead from the first seconds of every launch**.
  - `VoyagerApp` also caches the old service (`voyager_app.dart:102`), so the exit flush runs against a disposed instance.
- **Impact.**
  - Unsent text lost (P0-1).
  - No live pulls for the whole session, so every edit is made against stale local rows. That feeds P0-4, and for snapshot collections plain last-writer-wins silently overwrites the other device's edits.
  - Stranded uploads.
- **Confidence:** confirmed with the real provider graph. The control run without the invalidate passes.
- **Fix** (prototyped):
  - `ref.read` settings in `remoteSyncServiceProvider`; the existing listener already updates `forceConflictUi`.
  - `select` only the two dev fields in `weatherApiClientProvider`.
  - A `charOpRegistryProvider` so the registry outlives the service; the service doesn't clear a registry it doesn't own.
  - `dispose` hands pending uploads on instead of dropping them.
  - `VoyagerApp` reads the current service at flush time.
- **Refinement recommended beyond the prototype:** `dispose` should *queue* pending documents on the outbox (`recordOwedUpload`) rather than run them. A rebuild caused by sign-out would otherwise run uploads through the previous user's repository.
- **Test:** `sync_service_lifetime_test.dart` ×3.

#### P3-16 — Live sync is not restarted after sign-out → sign-in in the same process

- **Evidence.** `_postAuthWarmupStarted` (`main.dart:202`) is never reset, and the warm-up is the only `liveSync.start()`.
- **Confidence:** high.
- **Fix:** start live sync from an auth listener, or `ref.listen(liveSyncProvider, (_, c) => c.start())` once warm-up has run.

#### P3-5 — `SyncedWriteNotifier` silently drops the oldest writes past 500

- **Evidence.** `synced_write_notifier.dart:51`. Writes buffer while `onWrite == null`, which also happens between a provider dispose and the next read of `remoteSyncServiceProvider`.
- **Impact.** A large import or backfill during that gap loses uploads with no outbox row.
- **Confidence:** low-medium.
- **Fix:** past the cap, record `OutboxSyncWorker.recordOwedUpload` per record instead of dropping.

#### P3-3 — `OutboxSyncWorker.recordFailure` / `recordCrdtOverwrite` are no-ops before `initialize`

- **Evidence.** `outbox_sync_worker.dart:802,830`. Initialization happens post-frame in `_bootstrap`.
- **Impact.** A failure in the first frame isn't queued.
- **Confidence:** low.

### 3.3 Outbox, write gate and upload paths

#### P1-2 — Media rows on the outbox are cleared as orphans

- **Evidence.** `drainableCollections` includes `media_assets` and `media_references` (they are in `records`), so `recordFailure` *enqueues* them. `_payloadsFor` has no case for either (`default: return const {}`, `outbox_sync_worker.dart:579`). The drain treats the row as "entity gone" and deletes it. The `every synced collection is retryable` test checks the set, not the switch.
- **Impact.** An image attached on a flaky connection never appears on other devices.
- **Confidence:** confirmed.
- **Fix** (prototyped): `getAsset` / `getReference` cases. Add a test iterating `records` that asserts `_payloadsFor` resolves a stored row for each.
- **Test:** `sync_outbox_media_drain_test.dart`.

#### P1-3 — An older upload's late success clears a newer failure's outbox row

- **Evidence.** `_runRemoteSave` (`remote_sync_service.dart:2977`) runs uploads of the same document concurrently. Save A is in flight; save B is refused and `enqueue`s a row; A is acknowledged and `recordSuccess` → `clearFor` deletes the row. The drain's own `_clearPending` has the same shape (a row re-queued during a round is deleted after the round commits).
- **Impact.** The newest edit is owed to nobody. For CRDT documents it combines with P0-1. This happens exactly when the gate is full.
- **Confidence:** confirmed.
- **Fix** (prototyped): serialize uploads per document key in `_runRemoteSave`. For the drain, clear only rows whose `addedAt` / generation matches what the round read, or skip keys re-enqueued during the round (not prototyped).
- **Test:** `sync_stale_retry_regression_test.dart` "an older upload landing late…". It asserts the invariant: on the server or owed.

#### P1-4 — Upload paths that lose the failure (not routed through `_runRemoteSave`)

| Site | Shape |
|---|---|
| `flushPending` (`remote_sync_service.dart:758`) → `flushAllPending` | Runs `remoteSave()` bare. Called by `VoyagerApp._flushAllPendingEdits` on every `inactive` / `paused` (every alt-tab on Windows) and on window close; the pending save has already been removed from the map. |
| `todo_edit_panel.dart:234,361,643` | `unawaited(flushDocument(...))`: the same raw path, fire-and-forget. |
| `pushStudyCardsBatch`, `pushWorkoutSetLogsBatch`, `pushJobApplicationsBatch`, `pushJobStatusEventsBatch`, `pushJobStagesBatch`, `pushJobCompaniesBatch`, `pushJobSeasonsBatch`, `pushTodoTasksBatch` | Call `syncDocumentsImmediately` directly. Ranking batches already use `_runRemoteBatchSave`. |
| `todo_page.dart:1602` `_persistSortBatch` | `unawaited(pushTodoTasksBatch(...))`, no catch. |
| `workout_session_controller.dart:412` `_pushSetLogs` | Unawaited batch, no catch. |
| `todo_page.dart:1456` `_requeueRemotePush` | Retries in memory only, with the *captured snapshot* (see P2-1); never reaches the outbox. |
| `pushJournalById` (`:2903`, used by journal delete) | Raw upload. The caller catches and reports, but the journal tombstone is never queued. |
| `forceOverwriteJournalEntryText` (`:601`) | After a successful log wipe, a failed re-seed upload leaves no outbox row. The log is gone, the seed is only in memory, and a restart loses the rewrite (P1-7). |

- **Impact.** Rows written locally, never uploaded, nothing recording it. Local rows then outrank every later pull, so it is never repaired.
- **Confidence:** high (M9 demonstrates the class is unpinned).
- **Fix:** prototyped for `flushPending`, all the batches (`_runRemoteBatchSave` gains `logOperation`), `pushJournalById` and `forceOverwrite`. `_requeueRemotePush` becomes unreachable for batch failures and should be removed.

#### P1-5 — Awaited pushes abort multi-step local operations after the local commit

| Site | Result when the push throws (offline, gate refusal) |
|---|---|
| `completeTodoTask` (`todo_recurring_completion.dart:58,93`) | Throws after writing. To-Do page: `_finishRollForward` never runs, the optimistic check stays. Calendar (`calendar_page.dart:661`): the edit push throws first, so the cascade push **and the repeating task's roll-forward** are skipped, and the task stays completed. Notification inbox: invalidation skipped. |
| `deleteTodoList` (`todo_list_actions.dart:307`, `:381`) | Tasks tombstoned or moved, **list never deleted**, settings default not cleared, list tombstone not pushed. |
| `deleteStudyFolder` / `deleteStudyDeck` (`study_actions.dart:556,490`) | The folder loop stops after the first deck; subfolders and the folder stay alive (partial delete). |
| `StudyMoveModal._selectDeck` (`study_move_modal.dart:55`) | Cards moved, error shown, user retries. |
| `JobsActions.deleteApplication` / `_writeApplication` (`jobs_actions.dart:224,171`) | Delete done but no snapshot returned (no undo offered); save done but reported as failed. |

- **Confidence:** high.
- **Fix:** make background pushes non-throwing. Prototyped for the batch methods and for `completeTodoTask` / calendar, which now use `pushTodoTaskInBackground`. `pushTodoTaskNow` stays throwing for `TodoWriteCoordinator`, which needs it.

#### P2-1 — A retried older snapshot regresses the server copy

- **Evidence.** `push*Now(entity)` / `_runRemoteSave(() => _uploadXNow(entity))` capture the payload at call time. `SyncRetryPolicy` retries a transient failure (including `SyncBackpressureException`) 250–750 ms later, which can be after a newer push of the same document landed.
- **Impact.** The server holds the older content at a lower version. This device's pulls keep local (higher version) and never re-push, so other devices keep the old content indefinitely.
- **Confidence:** confirmed.
- **Fix** (prototyped): per-document serialization (same change as P1-3). `pushRecords` (finance and other notifier-driven collections) has the same shape and is not prototyped; serialize by record id there too.
- **Test:** "a retried older upload does not overwrite a newer one".

#### P2-2 — Refusals and timeouts count toward the 7-day park; parked rows are never drained

- **Evidence.** `_handleUploadFailure` (`outbox_sync_worker.dart:628`). Rows keep their original `addedAt`, and `park` excludes them from every later drain.
- **Impact.** A queue wedged for a week (the postmortem's shape, across restarts) parks everything. Those documents never sync unless each one is edited again.
- **Confidence:** high.
- **Fix** (prototyped): don't age-park on `SyncBackpressureException` or `TimeoutException`; pause-check inside the CRDT pusher loop. Also consider a Dev-tile "retry parked" action.

#### P2-6 — A rejected `waitForPendingWrites` probe counts as "drained"

- **Evidence.** `firestore_write_gate.dart:246`. The Firestore SDK rejects outstanding calls on a credential change. A sign-out/sign-in, or auth restoring after `firestoreWriteGateProvider` is first read, lifts `_startupBacklogCleared` and `_stalled` together.
- **Confidence:** medium (SDK behaviour not exercised here).
- **Fix:** on rejection, re-arm the probe (bounded retries) rather than clearing. Clear only on a successful completion.

#### P2-7 — The gate counts commits, not mutations

- **Evidence.** `writeGate.run(batch.commit)` holds one slot for up to 40 document writes, plus op-log batches.
- **Impact.** The effective queued-write ceiling is ~2000, not 50. Whether that is below the backend's "maximum allowed queued writes" is unverified.
- **Confidence:** medium.
- **Fix:** `run(write, weight: n)`, counting mutations.

#### P3-1 — `appendOperationGroup` is one unbounded batch

- **Evidence.** `firestore_sync_repository.dart:299`. Each chunk is up to ~900 KB, so a reseed or compaction of roughly 80k+ characters exceeds the 10 MiB request limit, is permanently rejected and parked.
- **Confidence:** medium.
- **Fix:** cap total bytes per commit and fix the stale comment.

#### P3-2 — `_rowKeys ??= await …` race

- **Evidence.** `outbox_sync_worker.dart:681`. Two first callers can each load the set; the later assignment loses the other's key, so `clearFor` skips deleting.
- **Impact.** Leftover rows and false "parked" reports.
- **Confidence:** medium.

#### P3-4 — A throwing mapper in `_payloadsFor` aborts every drain (poison pill)

- **Confidence:** low.
- **Fix:** catch per collection and park its rows.

#### P3-15 — Live sync drops a collection batch after 3 failed applies

- **Evidence.** `_maxRequeueAttempts = 3`.
- **Impact.** Those documents wait for the next full pull.
- **Confidence:** high.

### 3.4 Settings document

#### P1-1 — Whole-document last-writer-wins carries user content, and navigation moves its clock

- **Evidence.**
  - `settingsSyncPayload` (`firestore_document_mapper.dart:2866`) includes `snippets`, `jobExperienceSnippets`, `jobProfile*Url`, `colorPalette`, `navPageOrder` and more.
  - It also includes `lastSeenNavPage` (written on **every page switch**, `app_shell.dart:264`), `lastViewedJournalId` / `lastViewedTodoListId` (every journal or list switch) and `todoCompletedSectionExpanded`.
  - Any change to a synced field bumps `settingsUpdatedAt` and pushes the whole payload. `mergeSettingsFromRemote` applies the whole document when the remote clock is newer.
- **Scenario.** Device B adds a job-experience snippet. Device A, stale (P0-3 makes this the norm), switches pages. A's older snippet list overwrites B's everywhere.
- **Impact.** Silent loss of user-authored content across devices.
- **Confidence:** confirmed.
- **Fix:** needs a product decision (§8).
- **Test:** "the settings document…".

### 3.5 Journal, dream and to-do pages (non-CRDT)

#### P2-4 — To-do subtask writes build from the panel's snapshot

- **Evidence.** `_toggleSubtask`, `_renameSubtask`, `_deleteSubtask` and `_reorderSubtasks` (`todo_edit_panel.dart:841–980`) do `subtask.copyWith(...)` on `_subtasks` loaded when the panel opened. This is the exact pattern the journal delete path documents as resurrecting entries: a full-row overwrite of concurrent changes, and a tombstone at a stale version that loses to the remote and comes back.
- **Confidence:** high.
- **Fix:** re-read the subtask row before each write.

#### P2-5 — To-do uploads restamp `updatedAt`

- **Evidence.** `_uploadTodoTaskNow` always calls `task.copyWith(bumpVersion: …)` (`remote_sync_service.dart:3242`), and `pushTodoTasksBatch` does `copyWith(bumpVersion: false)` (`:2881`). `copyWith` stamps `updatedAt = now`. The journal and dream uploads were fixed for exactly this ("reverting offline edits made after the upload"); to-do was not.
- **Impact.** The remote copy looks newer than the row at the same version, so tie-breaks go to the remote and can revert non-bumping local changes.
- **Confidence:** high.
- **Fix:** mirror `_uploadJournalEntryNow` (copy only when bumping) and send `task` as-is in the batch.

#### P3-6 — `_addSubtask` defers the write 50 ms behind a `mounted` check

- **Evidence.** `todo_edit_panel.dart:831`. The field is already cleared; closing the panel within 50 ms drops the subtask silently.
- **Confidence:** high (narrow window).

#### P3-8 — Undo snapshot read before the save chain settles

- **Evidence.** `softDeleteJournalEntry` reads `snapshot` (`journal_entry_delete.dart:44`) *before* `settleLocalWrites`. Callers that didn't flush (Search) can restore the pre-last-save body on undo.
- **Confidence:** medium.
- **Fix:** read after settle.

#### P3-12 — Dream page `dispose` doesn't flush the ≤400 ms body/notes debounce

- **Evidence.** `dream_journal_page.dart:206`. The shell keeps pages mounted, so this is rare.
- **Confidence:** medium.

### 3.6 Finance and other modals

#### P2-3 — Full rows built from the snapshot captured when the sheet opened

- **Evidence.** `finance_goal_modal.dart:153`, `finance_category_modal.dart:112`, `finance_subscription_modal.dart:177`, `finance_transaction_modal.dart:256` (also `leetcode_track_modal.dart:879`, `study_deck_link_actions.dart:56`) build a complete record from `widget.existing` with `version: existing.version + 1`. The asset modal re-reads first and says why. If the row changed while the sheet was open (a pull, a room attach, a bill advance), the save reverts it. If disk had already passed `existing.version + 1`, the push regresses the server version and the devices diverge: each keeps its own.
- **Confidence:** high.
- **Fix:** re-read the row on save; `version: max(disk.version, existing.version) + 1`; carry through fields the sheet doesn't edit (`roomEventId`, `paidThroughDate`, `contributionRoomId`) from disk.

### 3.7 Deletes, purge and multi-step actions

#### P2-9 — `softDeleteJournal` doesn't bump version

- **Evidence.** `drift_repositories.dart:94`, unlike `softDeleteEntry`. The tombstone wins only on the `updatedAt` tie-break, so clock skew or a concurrent rename resurrects the journal.
- **Confidence:** medium.
- **Fix:** bump, as the entries path does.

#### P3-9 — Purge can delete a tombstone that never uploaded

- **Evidence.** `purgeExpiredDeleted` runs after the startup pull on a 30-day clock with no check against the outbox. A delete parked by P2-2 is purged locally, then the next pull resurrects the item.
- **Confidence:** medium.

#### P3-13 — Hard deletes don't propagate

- **Evidence.** `permanentlyDeleteFromRemote` (dev purge tile, `purgeJournalEntryEverywhere`) removes the document and log but leaves other devices' rows. Their next edit re-creates the document.
- **Confidence:** high (dev-only surface).

---

## 4. Cross-cutting systemic issues

**X1 — Text bypasses version gates, but its inputs are volatile.** Collaborative
text always comes from the operation log on pull, regardless of which side is
newer. What reaches that log depends on in-memory state (pending ops, sessions,
debounce timers) that restarts, hot restarts, provider rebuilds and gate
refusals all destroy. *Rule to adopt:* a pull may never replace local text the
log cannot account for. Either the log has absorbed it, or it stays and is
queued. (P0-1, P1-7)

**X2 — The editor session is a one-shot snapshot of the log.** Nothing absorbs
remote operations after load, so every route that brings remote text to the
screen has to re-record it, and re-recording duplicates. Sessions must absorb
on every pull, and anything replacing editor text must diff from the
*session's* text. (P0-2, P0-4, P2-8)

**X3 — Uploads reachable outside `_runRemoteSave` / `_runRemoteBatchSave`.** The
postmortem rule is right, but compliance is per call site. Any method that
reaches `syncDocumentImmediately(ies)` or a bare `remoteSave()` can violate it.
Make the non-throwing form the default and give the throwing form a name that
says so (as `pushTodoTaskNow` vs `pushTodoTaskInBackground` already does). (P1-4,
P1-5)

**X4 — Payloads captured early, written late.** `push*Now(entity)` snapshots,
modal `widget.existing`, panel `_subtasks`, the `_requeueRemotePush` snapshots,
retry loops. The journal code has repeatedly moved to "re-read at write time";
most other surfaces haven't. (P2-1, P2-3, P2-4)

**X5 — Long-lived stateful services under `ref.watch` of volatile providers.**
`RemoteSyncService` owns irreplaceable in-memory state but is rebuilt like a
pure value. Anything holding pending work should `ref.read` its volatile inputs,
or keep that work in a provider that outlives it. (P0-3)

**X6 — Aggregate documents merged whole.** The settings document mixes device
navigation state, preferences and user-authored lists under one clock. (P1-1)

**X7 — Network pushes awaited inside local multi-step operations.** A network
failure aborts local work. Local operations should complete locally, with sync
queued. (P1-5)

**X8 — Tests that pin symbols or interleavings rather than invariants.**
`firestoreWriteChunkSize` compared against itself; a paused-gate test that passes
without the break; coverage claimed for the to-do fix that doesn't exercise it.
Two of this audit's own first-draft tests had to be rewritten from "this
interleaving happens" to "the edit is either on the server or owed" before they
meant anything.

---

## 5. Proposed fixes, in priority order

Status: **P** = prototyped and verified in `DATA_INTEGRITY_AUDIT_PROTOTYPE.diff`
(the full suite passes apart from the pre-existing jobs toolbar test and the
settings test); **R** = recommended, not prototyped.

| # | Fixes | Change | Status |
|---|---|---|---|
| 1 | P0-3 (+P1-8) | `ref.read` settings in `remoteSyncServiceProvider`; `select` dev fields in `weatherApiClientProvider`; `charOpRegistryProvider` (registry outlives the service; not cleared unless owned); `dispose` hands pending uploads on; `VoyagerApp` reads the current service at flush. **Refine:** `dispose` should queue pending docs on the outbox rather than run them (sign-out case). Also start live sync from a listener (P3-16). | P (+R) |
| 2 | P0-2, P0-4, P2-8 | `CharacterOpSession.absorbRemote`, `hasPendingOps`, `opsReplacedBy`; registry `absorbRemote`; absorb in the three CRDT pulls; `RemoteSyncService.reanchorEditorText`; `_recordTextChange` with `_rebaseEdit` instead of reseed; `prepareEditingSession` foreign-tombstone guard with a scoped catch-up pull; pages call `reanchorEditorText` keyed by `_bodyEntryId`; to-do panel keeps `_lastNotesText`. **R:** replace `loadSession` in `_rebaseCharOpsOnLiveChain` with absorb + diff (P2-8). | P (+R) |
| 3 | P0-1, P1-7 | `_textOwedByThisDevice` in the three pulls (session pending → session text; no session + local newer → keep and queue; quarantined conflict → keep); `OutboxSyncWorker.recordOwedUpload`; `_recoverLostOperations` in `pushOutboxDocument` (re-derive from row; quarantine rather than delete foreign text); `forceOverwrite` queues the rewrite when the post-wipe upload fails. | P |
| 4 | P1-2 | Outbox `_payloadsFor` media cases. | P |
| 5 | P1-3, P2-1 | Per-document serialization in `_runRemoteSave`. **R:** the same for `pushRecords`; drain clears only unchanged rows. | P (+R) |
| 6 | P1-4, P1-5 | `flushPending` via `_runRemoteSave`; all batch pushes via `_runRemoteBatchSave(logOperation:)`; `pushJournalById` via `_runRemoteSave`; `completeTodoTask` and calendar use `pushTodoTaskInBackground`. **R:** delete `_requeueRemotePush`; make `_pushSetLogs` / `_persistSortBatch` explicitly non-throwing (already are after the batch change). | P (+R) |
| 7 | P1-6 | `TextDeltaInjector` fallback returns local text. | P |
| 8 | P2-2 | No age-park on refusal/timeout; pause check in the CRDT pusher loop. | P |
| 9 | P1-1 | Settings — see §8. | Decision |
| 10 | P2-3 | Finance and other modals re-read on save; version from disk. | R |
| 11 | P2-4, P3-6 | To-do subtask writes re-read rows; drop the 50 ms deferred write. | R |
| 12 | P2-5 | To-do uploads stop restamping `updatedAt`. | R |
| 13 | P2-6, P2-7 | Gate: re-arm a rejected probe; weight `run` by mutation count. | R |
| 14 | P2-9, P3-8, P3-9, P3-12 | Bump version on journal soft delete; undo snapshot after settle; skip purging tombstones with outbox rows; dream dispose flush. | R |
| 15 | P3-1, P3-2, P3-4, P3-5 | Byte-capped operation groups; `_rowKeys` load-once future; per-collection try in the drain; notifier overflow to the outbox. | R |

Notes on the prototype:

- The `_rebaseEdit` transform never deletes text it cannot locate exactly. An
  insertion inside a span where the editor and session disagree lands at the
  start of that span. This is deliberately "keep both" rather than "guess".
- A conflict quarantined by `_recoverLostOperations` uses
  `SyncConflictReason.hardMetadataCollision`, the closest existing reason. A
  dedicated reason (e.g. `unsentEditsDiverged`) would make the conflict UI
  explain it better.
- The test builders previously omitted `syncConflictRepository`. With it null,
  `_quarantineConflict` is a silent no-op, which is fine for tests but worth an
  assert in debug builds.

---

## 6. Test gaps and recommended harnesses

**Pin what the postmortem claims but doesn't test** (each maps to a surviving mutation):

- M5: `expect(firestoreWriteChunkSize, lessThanOrEqualTo(50))`, and assert the widest batch in the import test is ≤ 50 as a literal.
- M7: a paused gate with queued rows → drain returns with **zero** `run` calls attempted (count calls on a spy gate), not merely "rows remain".
- M9: a `SyncRepository` that throws `unavailable` → `pushTodoTaskInBackground` leaves an outbox row and no zone error (`runZonedGuarded` capture).
- M10: widget test with the lever from the postmortem — an instrumented `JournalRepository` whose `softDeleteEntry` stalls on a completer while body focus is dropped — asserting no write carries one entry's id with another's body.
- M12: `appendOperationsBatch` with 100 operations → ≥3 commits.
- M13: outbox drain on a gate at its limit → `batch.commit` is never called.

**Harnesses worth adding** (the audit tests contain first versions):

- **Flaky / stalled `SyncRepository`**: `_FlakySyncRepository` (offline switch), `_RefuseOnceSyncRepository`, `_HoldThenRefuseSyncRepository` (completer-held acknowledgement). Promote to `test/fakes/`.
- **Two-device rig**: two `AppDatabase`s, two services, one shared `InMemorySyncRepository`. Most multi-device findings here were one-screen tests with it.
- **Restart simulation**: `service.dispose()` + a new service on the same DB and repository. This is exactly what a hot restart does to in-memory sync state.
- **Real provider graph**: `ProviderContainer` with only DB and sync repository overridden, and the dev OpenWeather settings so the real weather provider builds without Firebase. The fake weather-client override hid the second rebuild trigger until it was removed.
- **Fake write gate**: `FirestoreWriteGate(waitForPendingWrites: () => completer.future)` driven by `fakeAsync` for timeout, latch and probe-rejection cases (P2-6).
- **Invariant assertions over interleavings**: "on the server or owed on the outbox", "neither device's words missing from both row and log".

**Not yet covered by any test:** P1-4 teardown flush, P1-5 partial deletes (todo
list, study folder), P2-2, P2-3, P2-4, P2-5, P2-6, P2-7, P2-8, P2-9, all P3s.

---

## 7. What was audited, and what was not fully covered

**Read in full:**

- Sync core: `firestore_write_gate`, `outbox_sync_worker`, `pending_flush_registry`, `sync_engine`, `firestore_sync_repository`, `in_memory_sync`, `sync_error_classification`, `firestore_collections`, `synced_write_notifier`, `soft_delete_policy`, `crdt_document_resolver`, `sync_conflict_detector`, `pending_text_merge`, `text_delta_injector`, `journal_write_coordinator`.
- CRDT: `character_op_session`, `character_sequence_crdt_merger`, `character_operation` (head), `fractional_index` (head).
- `RemoteSyncService`: save chain, flushes, sessions, conflict resolution, pulls for journal/dream/todo/secondary/settings, push methods, outbox replay, compaction, `pushRecords` / backfill, `LiveSyncController`.
- `main.dart`, `voyager_app.dart` lifecycle, the providers relevant to sync.
- Journal page: save, flush, switch, delete, move, date, provider listeners, editor state. `journal_entry_delete`, journal list actions (delete).
- Dream journal page: all write paths and the editor.
- To-do edit panel (all write paths), to-do page completion / sort / move / delete paths, `todo_list_actions` delete, `todo_recurring_completion`.
- Search page delete / move / save and `SearchEntrySaveHelper`.
- Finance modals: allocate, asset, budget, category, goal, subscription, transaction save/delete.
- Study delete / move actions; jobs `_writeApplication` / `deleteApplication`; workout set-log push; calendar task edit; `app_shell` page switch; settings sync payload / merge / `saveSettings`.
- Drift repositories: journal / dream / todo upsert, soft delete, purge; list of every repository write method.

**Covered by pattern pass only** (grep for raw pushes, awaited batch pushes, snapshot-built rows, `flushDocument`, `clearPersistence`, direct Firestore writes):

- calendar event panel / page (beyond the todo edit), life tracker page and canvas, bucket list, notification inbox and bell, rankings (actions use `_runRemoteBatchSave`), jobs pages beyond the two actions, leetcode (only `leetcode_track_modal` flagged), workout pages beyond the controller, study card editor / session pages, custom quotes dialog, dev page tiles.
- None of these write Firestore directly: every Firestore write in `lib` goes through the repository, outbox or gate (grep-verified), and `clearPersistence` is not called anywhere.

**Not audited:**

- Import / export and restore (`DataImportService`, `pushRestoredRecords` beyond reading it).
- Media blob transfer (`MediaTransferWorker`).
- Google Calendar / weather lock transactions.
- `analytics_page` (6.3k lines, read-only by pattern).
- Drift migrations in `app_database.dart`.
- Security rules.
- Firestore SDK internals: P2-6 and P2-7 rest on documented SDK behaviour, not a local reproduction.
- The actual on-device timing of P0-4 at launch (auto-select vs. startup pull) was reasoned from code, not observed.

**Housekeeping during the audit:**

- Mutations were applied and reverted in place with byte-level restore verification. HEAD `de96fab` was confirmed identical to the restored files.
- Prototypes ran in detached git worktrees under the session scratchpad, never in your working tree.
- Creating the first worktree triggered the repo's graphify post-checkout hook, which launched a background graph rebuild (log: `~/.cache/graphify-rebuild.log`).

---

## 8. Decision needed — the settings document (P1-1)

The correct fix depends on what should follow the user between devices:

**Option A — keep one document, fix the clock.** Make `lastSeenNavPage`,
`lastViewedJournalId`, `lastViewedTodoListId`, `lastViewedCalendarId`,
`todoCompletedSectionExpanded` and the `*ShowAll*` flags device-local, or at
least exclude them from the change comparison that moves `settingsUpdatedAt`.

- *Forces:* a small change; navigation stops overwriting other devices.
- *Forbids:* the "reopen where you left off on another device" behaviour those fields give today.
- *Leaves:* two devices each changing a *real* preference still overwrite each other's unrelated preferences.

**Option B — per-field clocks.** Store `{value, updatedAt}` per synced field (or
a `fieldUpdatedAt` map) and merge field by field.

- *Forces:* a payload format change plus migration of the existing document.
- *Forbids:* nothing user-visible; concurrent edits to different preferences both survive.

**Option C — move user-authored lists out of settings.** `snippets` and
`jobExperienceSnippets` become record collections like `custom_quotes`, with
version/tombstone merge; settings keeps only scalar preferences under Option A
or B.

- *Forces:* the most work (new tables, collections, backup registry).
- *Forbids:* losing a snippet to any settings write, ever.

Recommendation: **A now** (it removes the high-frequency trigger in one small
change), and **C for snippets** before relying on them across devices.

---

## 9. Implementation status (applied to the working tree)

Decision taken for §8: **A** (navigation state is device-local) and **C**
(snippets and experience snippets are records of their own).

Legend: **Fixed** = changed, with a test that fails when the fix is reverted
(mutation-checked). **Fixed (no test)** = changed, covered only by the existing
suite. **Unchanged** = deliberately left, with the reason.

| ID | Status | What changed |
|---|---|---|
| P0-1 | Fixed | Prototype as described in §3.1. |
| P0-2 | Fixed | Prototype. |
| P0-3 | Fixed | Prototype, plus the refinement: `dispose` queues pending uploads on the outbox instead of running them through the repository being replaced (a signed-out no-op that reported success). |
| P0-4 | Fixed | Prototype. |
| P1-1 | Fixed | **A:** `lastSeenNavPage`, `lastViewed{Journal,TodoList,Calendar}Id`, the three `*ShowAll*` scopes and `todoCompletedSectionExpanded` left `settingsSyncPayload` and the merge. **C:** schema v115 adds `snippets_table` / `job_experience_snippets_table` (migrating the JSON columns), Firestore collections `snippets` / `job_experience_snippets`, per-record version merge, fractional positions so a reorder rewrites only the moved item, delta-based edits (`applySnippetEdit`) so a stale list never deletes, outbox / live sync / backup / purge wiring, a versioned backfill that uploads only the new collections, adoption of lists an older build still writes into the settings document (checked against the record first, never uploaded blind), and adoption from older backups. Tests: `snippet_records_sync_test.dart`, the settings test in `sync_pending_char_ops_durability_test.dart`. |
| P1-2 | Fixed | Prototype. |
| P1-3 | Fixed | Single saves (prototype), and now batches and `pushRecords` share the same per-document chains; the drain no longer clears a row re-queued while its round was sending it. |
| P1-4 | Fixed | Prototype, plus the to-do page's direct pushes go through `pushTodoTaskInBackground` and its in-memory `_requeueRemotePush` (which re-sent captured snapshots) is removed. |
| P1-5 | Fixed | Prototype (batch pushes no longer throw; recurring completion and calendar use background pushes). Verified the study and jobs sites only use the now non-throwing batch methods. |
| P1-6 | Fixed | Prototype. |
| P2-1 | Fixed | Single saves (prototype), batches and `pushRecords` (this pass). |
| P2-2 | Fixed | Prototype. |
| P2-3 | Fixed (no test) | Goal, category, subscription and transaction sheets re-read the row on save, take the version and untouched fields (`roomEventId`, `paidThroughDate` for an unedited series, `deletedAt`) from disk. **Correction:** `leetcode_track_modal` and `study_deck_link_actions` already re-read before writing; they were listed in error. |
| P2-4 | Fixed (no test) | Subtask toggle, rename, delete and reorder apply their change to the row read at write time. |
| P2-5 | Fixed | To-do uploads send the row as-is unless a bump is asked for; the batch no longer `copyWith`s. |
| P2-6 | Fixed | A rejected `waitForPendingWrites` probe is re-armed (up to 5 times, 2 s apart) instead of lifting both latches. |
| P2-7 | Fixed | `FirestoreWriteGate.run(weight:)`; every batch commit passes its document count. A batch heavier than the allowance is admitted only when nothing else is in flight. |
| P2-8 | Fixed (no test) | `_rebaseCharOpsOnLiveChain` absorbs into an open session instead of replacing it. |
| P2-9 | Fixed | `softDeleteJournal` bumps version. Same defect found and fixed in `softDeleteAsset`, `softDeleteReference` (media) and `softDeleteCustomQuote`; the quotes dialog now pushes the tombstone read back from disk. |
| P3-1 | Fixed | `appendOperationGroup` splits at 8 MiB per commit; readers already ignore a group until all its chunks exist. |
| P3-2 | Fixed (no test) | Row keys load once through a shared future. |
| P3-3 | Fixed (no test) | Records made before `OutboxSyncWorker.initialize` are held and replayed in order — only in the app (`holdRecordsUntilInitialized` in `main`), so tests that never initialize don't accumulate them. |
| P3-4 | Fixed (no test) | A collection whose rows can't be resolved is skipped for the round instead of aborting the drain. |
| P3-5 | Fixed | `SyncedWriteNotifier` no longer drops buffered writes; it groups them by collection. |
| P3-6 | Fixed (no test) | A new subtask is written immediately, not behind a 50 ms `mounted` check. |
| P3-7 | Fixed (no test) | The flush writes a merged body only into an editor still holding that entry. |
| P3-8 | Fixed (no test) | The undo snapshot is read after the save chain settles. |
| P3-9 | Fixed | Every purge statement skips rows with an outbox row (queued or parked). |
| P3-10 | Fixed (no test) | Pending merges wait for the entry's save chain and derive tags from the merged body. |
| P3-11 | Fixed (no test) | Journal editor surfaces `prepareEditingSession` failures. |
| P3-12 | **Unchanged** | The dream page's flush reads its body through a child editor that is already torn down during `dispose`, so a flush there would fall back to the stale snapshot and could write *older* text. The shell keeps the page mounted; app exit is covered by `PendingFlushRegistry`. Fixing it needs the journal page's draft-buffer approach — a larger change than the risk warrants. |
| P3-13 | **Unchanged** | Dev-tile hard deletes only. |
| P3-14 | **Unchanged** | Whitespace-only tombstone churn in to-do notes; no content loss. Fixing it changes what notes store. |
| P3-15 | Fixed (no test) | Live sync keeps a batch that exhausted its retries and re-reads it on the next change instead of dropping it. |
| P3-16 | Fixed (no test) | `main` starts every rebuilt live-sync controller (`listenManual`). |

**Verification**

- New tests: `snippet_records_sync_test.dart` (13) and
  `sync_integrity_followups_test.dart` (11), on top of the 16 audit tests. All
  audit tests pass, including the settings test. Five of the follow-up
  fixes, and two of the snippet guards, were mutation-checked: reverting each
  fails its test.
- Full suite on the working tree: 3,125 passed, 17 skipped, 29 failed: the pre-existing
  `jobs_toolbar_alignment_test`, and 28 migration tests (including this pass's
  v115 test, which passed before) that all fail with `duplicate column name:
  prescription_mode`. That comes from a **v116 migration added concurrently by
  other in-progress work** (workout drop sets), which uses plain `addColumn`;
  the rewind-and-reopen migration tests re-run it against columns that already
  exist. Using `_addColumnIfNotExists` there, as the other steps do, should
  clear all 28.
- `dart analyze lib`: no errors; no new warnings in the files touched here.

**Remaining risks after these changes**

- **Mixed app versions.** A device still on an older build keeps reading and
  writing snippets in the settings document. New builds stop writing it, so the
  old device sees a frozen list; anything it adds is adopted by new builds.
  Update every device.
- **Snippets diverged before migration.** Each device migrates its own list;
  the union survives. A snippet deleted on one device before it updated can
  come back from another device's copy. Nothing is lost.
- **Navigation no longer follows you.** Option A's trade-off: "reopen where you
  left off" is per device.
- **Same-snippet concurrent edits** still resolve last-writer-wins per record.
- **UI-level fixes without widget tests** (P2-3, P2-4, P3-6, P3-7, P3-8) rely on
  the existing suite plus review.
- The prototype diff `DATA_INTEGRITY_AUDIT_PROTOTYPE.diff` is superseded by the
  working tree.

