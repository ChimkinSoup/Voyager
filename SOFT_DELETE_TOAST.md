# Soft-delete toast with Undo — HLD

High-level design for a universal post-delete feedback pattern: **`VoyagerToast` + Undo** after every in-scope soft delete.

Status: **implemented** — see §15 for where the built thing differs from this document.

Related: `lib/core/widgets/voyager_toast.dart`, `lib/features/rankings/rankings_actions.dart` (reference implementation), `docs/adr/001-local-first-data-model.md`, `JOBS.md` §7.4 (requires update — see §8).

---

## 1. Problem

Most soft deletes in Voyager end silently after a confirm dialog (where one exists). Only Rankings and Finance transactions give the user a way back. Accidental deletes are common on high-frequency surfaces (todo rows, journal entries, study cards), and the app already tombstones records for 30 days — the UI should match that safety net.

## 2. Goals

- After every **in-scope** soft delete, show a **`VoyagerToast`** with message + **Undo** action.
- **Undo dwell:** 8 seconds globally (`kSoftDeleteUndoDwell`).
- **Standardize** on `VoyagerToast` (migrate Finance `SnackBar`).
- **Shared helper** so call sites do not reimplement overlay/container capture, toast wiring, or restore logic.
- **Restore contract:** snapshot-before-delete + re-upsert on Undo (proven by Finance transactions today). Rankings keeps its dedicated `restore*` APIs; everything else uses the contract unless noted.
- **Do not add** confirm dialogs where none exist today.
- **Keep** existing confirm dialogs where they already exist (toast follows confirm).

## 3. Non-goals (v1)

- Container / cascade deletes (journal list, todo list, calendar list, study deck/folder).
- Study workbench **multi-select** batch delete.
- Finance modal deletes (category, budget, goal, subscription, asset).
- Settings mutations (snippets, quotes, dictionary, petal colors).
- Global media purge (`deleteAssetEverywhere`).
- Dev-tool bulk purges.
- Rankings **archive** toast.
- Jobs metadata deletes (stage, category, company, season).
- Notification inbox **complete task** toast.
- New confirm dialogs on low-friction deletes (subtasks, bucket items, media detach, finance transaction row).
- Redo support.

---

## 4. Scope matrix

| Feature | Action | In v1? | Confirm today? | Notes |
|---|---|---|---|---|
| **Journal** | Delete entry (editor toolbar) | Yes | Yes | + media restore |
| **Journal** | Delete entry (list row / context menu) | Yes | Yes | Same restore path |
| **Dream Journal** | Delete dream | Yes | Yes | |
| **To-Do** | Delete task (row, edit panel, calendar, inbox) | Yes | Row/panel/inbox: yes; calendar: yes | Shared `softDeleteTaskWithSubtasks` path |
| **To-Do** | Delete subtask | Yes | **No** | Toast only |
| **Calendar** | Delete single event | Yes | Yes (non-recurring) | |
| **Calendar** | Delete recurring event | Yes | Recurrence-scope dialog | Toast after scope chosen + writes complete |
| **Calendar** | Delete task marker | Yes | Yes | |
| **Search** | Delete journal entry from results | Yes | Yes | |
| **Study** | Delete single card | Yes | Yes | + media restore |
| **Study** | Delete card from session / cram | Yes | Yes | Advance session after delete; undo restores card |
| **Study** | Multi-select delete (workbench) | **No** | — | Explicitly excluded |
| **LeetCode** | Delete tracked problem | Yes | Yes | |
| **LeetCode** | Delete from session / cram | Yes | Yes | |
| **Rankings** | Delete parent / child / category | Yes (done) | Yes | Refactor onto shared helper |
| **Rankings** | Archive category | No | — | |
| **Jobs** | Delete application | Yes | Yes | **Behavior change** — §7 |
| **Finance** | Delete transaction (ledger row) | Yes (done) | **No** | Migrate `SnackBar` → `VoyagerToast` |
| **Finance** | Delete category / budget / goal / subscription / asset | **No** | — | |
| **Analytics** | Delete custom tracker | Yes | Yes | |
| **Analytics** | Delete logged value (sparkline / editor) | Yes | No / inline | Toast only |
| **Workout** | Delete exercise from library | Yes | Yes | Cascade: plan entries — §6.3 |
| **Workout** | Remove plan entry from day | No | — | |
| **Life Tracker** | Delete bucket list item | Yes | **No** | Toast only |
| **Notifications** | Delete task / event / bill from inbox card | Yes | Yes | Card exit animation unchanged |
| **Notifications** | Delete pinned note | Yes | **No** | Clears empty note or explicit delete |
| **Media** | Remove image from entry (gallery / lightbox) | Yes | **No** | Reference detach, not asset purge |
| **Media** | Delete image everywhere (settings) | No | — | |

---

## 5. UX specification

### 5.1 Flow

```
User triggers delete
  → [Existing confirm / scope dialog, if any today]
  → Capture pre-delete snapshot(s)
  → Perform soft delete (+ sync push + provider invalidation, unchanged)
  → Show VoyagerToast:
        message:  'Deleted "<title>"'  (sensible fallback when untitled)
        icon:     PhosphorIconsRegular.trash
        dwell:    8 seconds
        actions:  [ Undo ]
  → On Undo (before toast dismisses):
        Run restore from snapshot
        Re-push restored rows to sync
        Invalidate affected providers
        Dismiss toast
```

### 5.2 Copy rules

| Case | Message pattern |
|---|---|
| Named entity | `Deleted "<name>"` |
| Untitled journal / calendar event | `Deleted entry` / `Deleted event` |
| Untitled todo | `Deleted task` |
| Media detach | `Image removed` |
| Batch (none in v1) | — |

Undo label is always **`Undo`** (not “Restore”).

### 5.3 Confirm dialogs

- **Never add** a new confirm dialog for v1 scope.
- Where a confirm already exists, **keep it**; the toast appears only after the user confirms (or after a recurrence-scope choice).
- Low-friction deletes (subtask, bucket item, media detach, finance transaction swipe) go straight to delete + toast.

### 5.4 Toast lifetime

- Constant: `kSoftDeleteUndoDwell = Duration(seconds: 8)` in the shared module.
- Pointer hover pauses dwell (existing `VoyagerToast` behavior).
- Only **one** soft-delete undo toast at a time per overlay: showing a new one dismisses the previous (same as raising a second toast today).

### 5.5 Widget lifetime

Deleting a row unmounts the widget that initiated the delete. Every call site must capture **before** the async delete:

1. `ProviderContainer` via `ProviderScope.containerOf(context, listen: false)`
2. `OverlayState` via `Overlay.of(context, rootOverlay: true)`

The shared helper takes these up front (pattern from `confirmDeleteRankingParent`).

---

## 6. Architecture

### 6.1 New module

`lib/core/soft_delete/soft_delete_toast.dart` (name flexible; keep colocated helpers together)

**Exports:**

```dart
const kSoftDeleteUndoDwell = Duration(seconds: 8);

/// Runs [delete], shows toast with Undo, calls [restore] on Undo.
Future<void> softDeleteWithUndo({
  required OverlayState overlay,
  required ProviderContainer container,
  required String message,
  required Future<void> Function() delete,
  required Future<void> Function() restore,
});

/// Snapshot helpers — typed wrappers built on the generic contract.
```

`softDeleteWithUndo` responsibilities:

1. Await `delete()`.
2. If delete throws, **do not** show toast (caller handles error UI).
3. Show `showVoyagerToastIn` with trash icon, `kSoftDeleteUndoDwell`, single `VoyagerToastAction(label: 'Undo', ...)`.
4. `onPressed`: await `restore()`, then toast dismisses (existing action behavior).

Optional: `SoftDeleteSnapshot<T>` class holding `T entity`, `DateTime deletedAt`, and side-effect metadata (media collection, child rows).

### 6.2 Restore contract (snapshot-restore)

**Proven path** (Finance transaction row today):

1. **Before delete:** capture immutable snapshot(s) of live row(s) from repository or in-memory model.
2. **Delete:** existing `softDelete*` / `upsert` with `deletedAt: utcNow()` (+ version bump as today).
3. **Undo:** re-upsert from snapshot with:
   - `deletedAt: null` — rebuild full object; do **not** rely on `copyWith(deletedAt: null)` where the model uses `deletedAt ?? this.deletedAt` (journal, todo, study, etc.).
   - `version: snapshot.version + 2` minimum so restore wins over the tombstone on sync (Finance comment: delete wrote `+1`, restore must be `+2`).
   - `updatedAt: utcNow()`.
4. **Sync:** push restored document(s) the same way the delete path pushes tombstones.
5. **Invalidate** the same providers the delete path invalidates.

**Rankings exception:** keep `RankingsActions.restore*` + `restoreReferencesForOwner` — already correct. Refactor call sites to use `softDeleteWithUndo` for toast wiring only, or thin wrapper `confirmDeleteRanking*` that delegates restore to existing methods.

**Media side-effect:** when delete detaches references (`removeReferencesForOwner`), snapshot must record `deletedAt` stamped on detach and call `MediaService.restoreReferencesForOwner(collection, documentId, deletedAt)` on Undo. Applies to journal entries and study cards.

### 6.3 Cascade snapshots (in-scope only)

| Delete | Snapshot bundle |
|---|---|
| Workout library exercise | `Exercise` + all `WorkoutPlanEntry` rows tombstoned with it |
| Jobs application (after §7) | `JobApplication` + all `JobStatusEvent` rows for that application |
| Todo task with subtasks | Parent task + subtasks deleted by `softDeleteTaskWithSubtasks` |

Finance asset + valuations explicitly **out of scope**.

### 6.4 Repository restore helpers (incremental)

v1 does **not** require new `restore*` methods on every repository. Implement restore as **upsert-from-snapshot** in feature action layers.

**Follow-up (optional hardening):** add `clearDeletedAt` to domain `copyWith` methods that still use `deletedAt ?? this.deletedAt`, starting with types touched in v1. Not blocking — full-object rebuild works.

---

## 7. Jobs application delete — behavior change

**Decision:** Option B — normal soft delete, not content wipe.

### 7.1 Today

`DriftJobRepository.deleteApplication` blanks `company`, `title`, `status`, notes, URL, season; sets `deletedAt`; tombstones status events. UI copy: “permanently deleted / cannot be undone.” `JOBS.md` documents hard delete.

### 7.2 Target

- `deleteApplication` sets `deletedAt` on the application **without clearing fields**.
- Status events: set `deletedAt` on each event (keep `fromStatus` / `toStatus` intact).
- Sync pushes tombstones as today.
- Confirm dialog copy updated to match app-wide soft delete: e.g. “will be moved to trash.”
- Toast: `Deleted "<title> at <company>"` + Undo.
- Undo: upsert application snapshot + event snapshots with `deletedAt: null`, version bumps, push sync.

### 7.3 Doc / spec updates required

- `JOBS.md` §7.4: change “hard delete” → soft delete with undo toast.
- Remove “exception to app-wide soft-delete default” language.
- Acceptance checklist item 8 updated.

---

## 8. Call-site migration map

Each row: wire through `softDeleteWithUndo` (or rankings wrapper).

| File | Handler | Snapshot notes |
|---|---|---|
| `lib/features/journal/journal_page.dart` | `_deleteEntry`, `_deleteEntryItem` | Entry + `restoreReferencesForOwner(journalEntries, id, deletedAt)` |
| `lib/features/dream_journal/dream_journal_page.dart` | `_deleteEntry` | Dream entry |
| `lib/features/todo/todo_page.dart` | `_deleteTaskFromRow` | Task (+ subtasks via existing helper) |
| `lib/features/todo/todo_edit_panel.dart` | `_deleteTask`, `_deleteSubtask` | Task / subtask |
| `lib/features/calendar/calendar_page.dart` | `_deleteEvent`, `_deleteTodoTask` | Event or todo task; recurring = snapshot master + written rows |
| `lib/features/search/search_page.dart` | `_deleteEntry` | Journal entry |
| `lib/features/study/study_actions.dart` | `deleteStudyCard` | Card + study media restore |
| `lib/features/study/study_card_editor_modal.dart` | `_delete` | Card + media |
| `lib/features/study/study_session_page.dart` | `_deleteAndAdvance` | Card + media; session advance unchanged |
| `lib/features/study/study_cram_page.dart` | `_deleteCurrent` | Same |
| `lib/features/leetcode/leetcode_actions.dart` | `deleteLeetCodeProblem` | Problem |
| `lib/features/leetcode/leetcode_session_page.dart` | `_deleteAndAdvance` | Problem |
| `lib/features/leetcode/leetcode_cram_page.dart` | `_deleteCurrent` | Problem |
| `lib/features/rankings/rankings_actions.dart` | `confirmDeleteRanking*` | Refactor; keep `restore*` |
| `lib/features/jobs/jobs_page.dart` | `_confirmDelete` | After repository change — application + events |
| `lib/features/jobs/jobs_actions.dart` | `deleteApplication` | Implement soft delete (§7) |
| `lib/features/finance/finance_page.dart` | `_TransactionRow._delete` | Replace `SnackBar` with shared helper; keep rebuild restore |
| `lib/features/analytics/analytics_page.dart` | `_deleteTracker`, value `_delete` | Tracker / `TrackerValue` |
| `lib/features/workout/workout_exercise_panel.dart` | `_delete` | Exercise + plan entries |
| `lib/features/life_tracker/bucket_list_popup.dart` | `_deleteItem` | `BucketListItem` |
| `lib/features/notifications/notification_inbox_popover.dart` | `_deleteTask`, `_deleteEvent`, `_deleteBill`, `_deleteNote` | Respective entity |
| `lib/core/media/widgets/media_gallery_strip.dart` | `_remove` | `MediaReference` snapshot + `restoreReferencesForOwner` or re-attach reference |

**Explicitly not wired:** `study_deck_workbench_page.dart` multi-select `_delete`, all finance `*_modal.dart` `_delete` methods.

---

## 9. Sync and versioning

- Undo must produce a **monotonic version** strictly newer than the tombstone (see `journal_page._softDeleteAndPushTombstone` comments on cross-device resurrection).
- Restore paths push via the **same explicit push** the delete path uses (`pushJournalEntryNow`, `pushTodoTaskNow`, `pushLeetCodeProblem`, etc.). Do not assume `SyncedWriteNotifier` covers a collection.
- If delete flushes pending text merges first (search, journal), restore does **not** need to re-flush unless an edit landed during the 8s window — out of scope; standard version bump is sufficient.

---

## 10. Error handling

| Case | Behavior |
|---|---|
| Delete throws | No toast; existing error reporting |
| Delete succeeds, toast shown, restore throws | Log error; toast still dismisses on Undo press; user sees item still deleted — acceptable v1 edge case |
| User navigates away | Overlay + container captured at delete time; undo still works for 8s |
| Second delete before undo expires | New toast replaces old; **first undo is lost** — acceptable v1 |

---

## 11. Implementation phases

### Phase 1 — Foundation

1. Add `lib/core/soft_delete/soft_delete_toast.dart` with `kSoftDeleteUndoDwell` and `softDeleteWithUndo`.
2. Add unit tests for snapshot version bump helper (pure Dart).
3. Migrate Finance transaction row from `SnackBar` to `VoyagerToast` via helper (parity test).

### Phase 2 — Jobs behavior change

1. Change `deleteApplication` to soft delete (§7).
2. Update confirm copy in `jobs_page.dart`.
3. Add toast + undo.
4. Update `JOBS.md` and `test/job_repository_test.dart` (or equivalent).

### Phase 3 — High-traffic surfaces

Journal, dream journal, todo (task + subtask), calendar, search.

### Phase 4 — Study, LeetCode, notifications, media detach

Include media restore for journal + study.

### Phase 5 — Analytics, workout, bucket list

Workout exercise cascade snapshot.

### Phase 6 — Rankings refactor

Refactor existing rankings confirm helpers to shared module without behavior change. Remove duplicated `_undoDwell` local constant.

---

## 12. Testing plan

### Widget / integration tests (representative)

| Test | Assert |
|---|---|
| Finance transaction delete | `VoyagerToast` visible, `SnackBar` absent; Undo restores row |
| Todo subtask delete | No `AlertDialog`; toast + undo restores subtask |
| Journal entry delete | After confirm, toast; undo restores entry in list |
| Jobs application delete | New soft-delete tombstone retains fields; undo restores title + timeline |
| Media gallery remove | Undo reattaches reference |
| Bucket list item | Toast without prior dialog |

### Repository tests

- `deleteApplication` no longer clears `company` / `title` / `status`.
- Restored application round-trips with `deletedAt == null` and higher version.

### Manual smoke

- Delete from session/cram (study + LeetCode): session advances; undo brings card back (may need to navigate back to see it).
- Recurring calendar delete (this / future / all): toast appears once; undo restores expected rows for chosen scope.
- Notification inbox: card animates out; undo brings task/event back.

---

## 13. Constants and API surface

```dart
// lib/core/soft_delete/soft_delete_toast.dart

const kSoftDeleteUndoDwell = Duration(seconds: 8);

Future<void> softDeleteWithUndo({ ... });

/// Bumps version for restore-after-tombstone.
int restoreVersion(int preDeleteVersion) => preDeleteVersion + 2;
```

Rankings may import `kSoftDeleteUndoDwell` and delete local `_undoDwell`.

---

## 14. Open questions (resolved)

| # | Question | Resolution |
|---|---|---|
| 1 | Jobs scope | Application delete only |
| 2 | Jobs restore | Option B: normal soft delete |
| 3 | Workout | Library exercise delete only |
| 4 | Life tracker | Bucket list items only |
| 5 | Study multi-select | Excluded |
| 6 | Finance asset cascade | Excluded |
| 7 | Restore contract | Snapshot-restore |
| 8 | New confirms | Do not add |

No outstanding blockers for implementation.

---

## 15. Implementation notes (deviations from this document)

Written after the fact. Where the code and the sections above disagree, the code is right and this section says why.

### 15.1 `softDeleteWithUndo` has no `container` parameter (§6.1, §13)

The two closures already capture whatever they need to reach the repository and the providers. A container passed into the helper would only be handed straight back out, so it was dropped. `restoreVersion` lives in `lib/core/soft_delete/restore_contract.dart` — Flutter-free, so the media layer can follow the same rule without importing widgets — and `soft_delete_toast.dart` re-exports it, so a call site still writes one import.

`showSoftDeleteUndoToast(overlay:, message:, restore:)` was added alongside it, for the call sites that have to do work *between* the delete and the toast (journal, dream, calendar, the notification inbox) and cannot express that as a single `delete` closure.

### 15.2 The media detach has to report its own stamp (§6.2)

§6.2 said the snapshot should "record `deletedAt` stamped on detach". There was no way to read it: `MediaService.removeReferencesForOwner` returned void, and the only stamp available to a caller was the *parent's* `deletedAt` — a different `utcNow()` a few hundred microseconds earlier.

`restoreReferencesForOwner` matches `deletedAt` **exactly**, and rows are stored to microsecond precision. So the Rankings undo this document cites as "already correct" was in fact restoring **zero** references: every undone delete quietly left its images detached. `removeReferencesForOwner` now returns the instant it stamped (null when there was nothing to detach), each cascade carries one instant *per row* (`MediaDetachStamps`), and the Rankings restore signatures changed to take that map instead of a `DateTime`. Pinned by `media_module_test.dart`.

`MediaService.restoreReference` was added for the gallery strip, which detaches a single reference rather than a whole owner's worth.

### 15.3 One standing offer per overlay is new behaviour (§5.4)

§5.4 says a second toast dismisses the first, "same as raising a second toast today". It was not: `showVoyagerToastIn` inserts an independent overlay entry, and two toasts are positioned identically — a second delete inside the dwell drew its card straight over the first. The soft-delete module now tracks the standing offer per overlay (an `Expando`) and dismisses it before raising the next. `VoyagerToast` itself is unchanged.

### 15.4 Media detach already had a confirm dialog (§4)

The scope matrix lists "Remove image from entry" as having no confirm today. `media_gallery_strip._remove` does show one. §5.3 wins: the dialog stays and the toast follows it.

### 15.5 Two paths deliberately left without a toast

Both are edits that happen to tombstone a row, and a toast raised mid-typing would be noise:

- `notification_inbox_popover._commitNote` clearing a note to empty. The explicit delete button toasts; emptying the field does not.
- The analytics value editor's `_save` with the number field left blank. The explicit delete button toasts.

### 15.6 Restores also unwind optimistic hiding

Not mentioned above, and undo does not work without it. Journal, Search, Dream Journal, the To-Do page and the to-do edit panel all hide a deleted row in local `State` rather than waiting for a provider refresh. Restoring the row on disk alone leaves it back in the database and still invisible, so each restore clears its page's hide-list too. Pinned by `todo_delete_undo_test.dart` and `journal_delete_undo_test.dart`.

### 15.7 Todo deletes were routed onto the shared path

§4 already describes the calendar and the notification inbox as using `softDeleteTaskWithSubtasks`; they were each doing their own `upsertTask` / `softDeleteTask` instead, so a task deleted from either surface left its subtasks and its images behind. Both now go through the shared path. Todo restores re-attach media, which §6.2 only specified for journal and study.
