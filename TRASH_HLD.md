# Trash — HLD

One app-wide Trash screen that lists everything the user deleted in the last 30 days. Each item can be restored or deleted forever, and there is an Empty trash action. It opens from a row in Settings and from a "Recently deleted" link on each feature page, which opens it already filtered to that feature.

Related: `SOFT_DELETE_TOAST.md` (the 8-second undo this extends), `GAPS.md` P1 "No trash, but 18 delete dialogs promise one", `docs/adr/001-local-first-data-model.md` (30-day retention), `docs/adr/002-sync-protocol.md` (Jobs amendment: why a row can't simply be deleted), `lib/core/sync/soft_delete_policy.dart`, `lib/core/soft_delete/restore_contract.dart`, `lib/core/sync/sync_engine.dart` (`purgeExpiredDeleted`), `lib/core/media/media_service.dart`.

Status: **implemented** — see §13 for where the built thing differs from this document.

---

## 1. Problem

Every user-facing delete in Voyager is a soft delete. The row gets a `deletedAt` stamp, syncs as a tombstone, and is purged locally 30 days later (`softDeleteRetentionDays`). Eighteen confirm dialogs tell the user the item "will be moved to trash". Once the 8-second undo toast is gone, though, nothing in the UI can reach those rows. The data still exists, but the user has no way back to it.

## 2. Goals

- One **global** Trash screen for every in-scope type (§4), with **filter chips per feature**.
- **Restore**: puts the item back where it was, on every device.
- **Delete forever** (per item) and **Empty trash** (bulk). Both ask for confirmation, and both remove the item from every device's Trash and wipe its content.
- **Container deletes as one grouped row**, e.g. a whole journal, to-do list, calendar, study deck or folder. Restoring one brings back the container together with exactly the children that were deleted *with* it.
- **Entry points**: a "Trash" row in Settings, plus a "Recently deleted" link on each feature page that opens Trash pre-filtered.
- Makes the existing "moved to trash" copy true, so no dialog text has to change.

## 3. Non-goals (v1)

- Text search inside Trash. Filter chips and newest-first order are enough for 30 days of deletes.
- Restoring a single child out of a grouped container row. The group restores as a whole.
- Undo for Delete forever or Empty trash. They have a confirm instead.
- Showing tombstones that are plumbing rather than content (§4.2).
- Calendar "this event only" and "this and following" deletes. They rewrite the series master instead of tombstoning a row, so there is nothing to list.
- Anything done by the Dev page's purge tools (`dev_remote_purge_tile.dart`, `out_of_sync_journal_entry_purge.dart`). Those hard-delete.
- Changing the 30-day retention.
- Migrating the undo toast onto the Trash restore path. That becomes possible afterwards (§11) but isn't part of this work.

---

## 4. Scope

### 4.1 In Trash

"Group" means the row stands for a container plus the children tombstoned with it (§6.3).

| Feature | Row | Group / cascade on restore | Notes |
|---|---|---|---|
| Journal | Entry | Media references | Title, or a prose-stripped body preview if untitled |
| Journal | Journal (container) | Entries deleted with it, plus their media | Only the "delete everything" choice. "Move to default" leaves nothing in Trash except the empty journal |
| Dream Journal | Dream | Media references | |
| To-Do | Task | Subtasks deleted with it, plus media | |
| To-Do | Subtask (deleted on its own) | None | Subtitle names the parent task |
| To-Do | List (container) | Tasks and subtasks deleted with it, plus media | |
| Calendar | Event (one-off, or a whole series) | None | |
| Calendar | Calendar (container) | Events deleted with it | |
| Study | Card | Media references | |
| Study | Deck (container) | Cards deleted with it, plus media and deck links | |
| Study | Folder (container) | Subfolders, decks and cards deleted with it, plus media and deck links | Nested, handled as one group |
| LeetCode | Problem | Whatever `softDeleteProblem` cascades today | |
| LeetCode | Cheat-sheet entry / section / tab | As the existing `deleteCheat*WithUndo` | |
| Rankings | Entry (parent) | Units deleted with it | `restoreParent` already exists |
| Rankings | Unit (child, deleted on its own) | None | `restoreChild` already exists |
| Rankings | Category (container) | Entries and units deleted with it | |
| Jobs | Application | Status events deleted with it | |
| Finance | Transaction, subscription, budget, category, asset, savings goal | Whatever each soft delete cascades today | |
| Analytics | Tracker | None. Its logged values are never tombstoned; they are hidden only because the tracker is gone | Restore is the tracker row alone |
| Workout | Exercise | Plan entries deleted with it | |
| Life Tracker | Bucket-list item | None | |

### 4.2 Left out (plumbing)

Study and LeetCode review logs, workout sessions and set logs, a plan entry removed on its own, deck links on their own, media references and assets (they follow their parent), tracker values on their own, finance valuations, goal allocations, contribution-room rows and room events, reminders, inbox dismissals and pins, and settings lists (snippets, job experience snippets, dictionary words, custom quotes, petal colours). Also left out are Jobs stages, companies, categories and seasons.

These keep their current 30-day tombstone behaviour and just never appear in Trash.

---

## 5. UX

### 5.1 Entry points

- **Settings**: a "Trash" row, placed next to "Backup & Restore" (`settings_page.dart`), showing a count, e.g. "Trash · 12 items". It opens the Trash screen with no filter.
- **Feature pages**: a "Recently deleted" item in each page's existing overflow or manage menu. It opens Trash with that feature's chip already selected. A page with no such menu gets none in v1. The exact menu on each page is settled during implementation (§10, phase 4).
- The route is `/settings/trash?feature=<key>`, nested under the Settings destination so the shell keeps Settings highlighted.

### 5.2 Screen

```
┌ Trash ─────────────────────────────── [Empty trash] ┐
│ (All) (Journal 4) (To-Do 6) (Study 1) (Finance 1)   │   ← chips only for features with items
│                                                      │
│ ▣ "Trip to Banff"                         [Restore] ⋯│
│   Journal · deleted 2 days ago · 28 days left        │
│ ▣ To-do list "Groceries" · 14 tasks        [Restore] ⋯│
│   To-Do · deleted 5 days ago · 25 days left          │
│ …                                                    │
└──────────────────────────────────────────────────────┘
```

- Sorted newest-deleted first. Each row shows the feature icon, the title (the same capping as `deletedMessage`, prose-stripped where the field is multiline), the feature label, "deleted X ago" and "N days left".
- A group row shows a child count ("· 14 tasks").
- **Restore** is the primary action. The `⋯` menu holds **Delete forever**. On compact width, Restore moves into `⋯` as well, so the row is text plus one icon.
- **Empty trash** applies to the current filter. With a chip selected it reads "Empty Journal trash".
- Empty state: "Nothing in Trash. Deleted items stay here for 30 days."
- The list is live. A delete made elsewhere, or a restore or tombstone pulled from another device, shows up without reopening the screen.

### 5.3 Restore feedback

- `VoyagerToast`: `Restored "<name>"`, with no action button.
- If the row was already live on disk (another device restored it first), `RestoreSuperseded` becomes "Already restored", the same as the toast path does today.
- **Parent gone.** An item always goes back into its own container when that container is live. That covers the toast's Undo, restoring a group, and restoring a lone item whose container was never deleted. The fallback applies only when the container is *itself* in Trash at the moment of restore. For example: entry X is deleted from journal A, later A is deleted too, then X is restored on its own. X then goes into the feature's default container ("Journal", "To-do", "Calendar", or the study root), and the toast says so: `Restored "<name>" to Journal`. This follows the "move to default" choice the container dialogs already offer. The alternative would be to bring back the deleted container as an empty shell, which isn't what the user asked for. Restoring A first and then X puts X back in A.

### 5.4 Destructive confirms

- Delete forever: "Delete "<name>" forever? This can't be undone." For a group: "Delete to-do list "Groceries" and its 14 tasks forever?"
- Empty trash: "Permanently delete 12 items? This can't be undone."
- Neither shows an undo toast.

---

## 6. Architecture

### 6.1 Module

```
lib/core/trash/
  trash_item.dart        TrashItem value type
  trash_adapter.dart     TrashAdapter interface
  trash_providers.dart   registry + combined list provider + count provider
lib/features/trash/
  trash_page.dart        the screen
lib/features/<feature>/<feature>_trash_adapter.dart   one per feature
```

```dart
class TrashItem {
  final String feature;      // 'journal', 'todo', … : chip key and ?feature=
  final String kind;         // 'entry', 'journal', 'task', 'list', …
  final String id;
  final String? title;
  final String fallbackNoun; // as deletedMessage's fallback
  final DateTime deletedAt;
  final int childCount;      // 0 unless a group row
}

abstract class TrashAdapter {
  String get feature;
  /// Every in-scope row with deletedAt > cutoff, collapsed into groups (§6.3).
  Future<List<TrashItem>> list(DateTime cutoff);
  Future<void> restore(TrashItem item);
  Future<void> deleteForever(TrashItem item);
}
```

Each adapter is the only code that knows its feature's tables, cascades, media and pushes. The page talks only to the registry. `cutoff` comes from `SoftDeletePolicy.purgeCutoff(now)`, so Trash and the purge use one rule. A row old enough to be purged is never shown.

### 6.2 Restore reads from disk, not from a snapshot

The undo toast restores from a snapshot taken before the delete. After 8 seconds that snapshot no longer exists. The tombstone on disk *is* the latest state, though: soft deletes only stamp `deletedAt`, bump the version and leave the content alone (Jobs included, since the change recorded in `deleteApplication`). So a Trash restore:

1. Reads the row from disk. Missing → nothing to do. Untombstoned → `RestoreSuperseded`.
2. Rebuilds it field by field with `deletedAt: null`. `copyWith` can't clear a tombstone.
3. Sets `version = disk.version + 1` and `updatedAt = utcNow()`. This is `restoreVersionFrom(preDeleteVersion: disk.version, currentVersion: disk.version)`.
4. Upserts, pushes through the feature's existing `remoteSync.push*`, and invalidates the feature's providers from a `ProviderContainer` (the page can unmount mid-restore, same reasoning as `restoreTaskWithSubtasks`).

Rankings already does this in its repository (`restoreParent`, `restoreChild`). Where a feature needs the same, the adapter adds a repository `restore*(id)` in that style instead of rebuilding rows in widget code.

### 6.3 Grouping: one stamp per delete

**Rule:** a cascade delete stamps the container and every child it takes with **one shared `deletedAt`**. A group is the container plus its children (by the feature's foreign key) whose `deletedAt` equals the container's. The media layer already uses this idiom: `restoreReferencesForOwner` brings back only the references whose stamp matches.

This separates "deleted with the container" from "deleted earlier on its own" without a new column or a schema change. `deleteApplication` (application plus status events) and `softDeleteTaskWithSubtasks` already follow it. These do not:

| Path | Today | Change |
|---|---|---|
| `deleteTodoList` → `softDeleteTasksInList` + `softDeleteList` | Two `utcNow()` calls | Pass one `now` to both |
| `deleteJournalList` → `softDeleteEntriesInJournal` + `softDeleteJournal` | Two `utcNow()` calls. **Also** re-stamps entries that were already deleted (the `UPDATE` has no `deleted_at IS NULL` filter), which moves their 30-day clock and would sweep them into the group | One shared `now`, and add `AND deleted_at IS NULL` |
| `deleteCalendarList` → `softDeleteEventsInCalendar` + `softDeleteCalendar` | Two stamps | One shared `now` |
| `deleteStudyDeck` / `deleteStudyFolder` → per-card `softDeleteCard`, `softDeleteDeck`, `softDeleteFolder`, deck links | One stamp per row | Thread one `now` through the whole cascade |
| Rankings category, workout exercise, LeetCode problem, finance cascades | Check each | Same rule wherever they cascade |

Repository methods that take part gain an optional `DateTime? at` parameter, defaulting to `utcNow()`, so their other callers are unchanged. Media detach keeps its own stamp. It already matches on its own per-parent stamp, so it doesn't need to share the container's.

**Tombstones from before this ships** have mismatched stamps. Their children show as individual rows. Restoring one of them hits "parent gone" (§5.3) unless the container was restored first. The container shows as a group with a count of 0. All of these age out within 30 days of release, so there is no migration.

**Firestore round-trip:** `deletedAt` travels as `toIso8601String()` (microseconds) and parses back exactly. So a group deleted on device A still groups on device B. Covered by a test (§9).

### 6.4 Delete forever

A row can't just be deleted. `watchCollection` drops Firestore document removals, so other devices would never learn of it, and the first one still holding the row would push it back (ADR 002, Jobs amendment). `permanentlyDeleteFromRemote` is one-way for the same reason.

Delete forever therefore **erases**: it writes a final tombstone that every device keeps as a guard for 30 days and then purges.

1. **Wipe content.** Blank every user-content field (title, body, notes, amounts, and so on), as the old Jobs wipe did. Firestore keeps tombstone documents indefinitely (only local rows are purged), so without this the text would stay in the cloud.
2. **Mark as erased.** Set `deletedAt` to the Unix epoch (`kErasedAt`). Trash lists only `deletedAt > cutoff`, so the row disappears from Trash on every device as soon as it arrives there. An `isErased` getter (`deletedAt == kErasedAt`) is how the rest of the code recognises one (§6.5). No new column is needed.
3. **Outrank everything.** Set `version = disk.version + kEraseVersionStep`, where `kEraseVersionStep` is `1 << 20`, not `+ 1`. An erase is final and can't be restored, so it should beat an edit made concurrently on another device, even one offline for a long run of version-bumping saves. With `+ 1` it would lose to any such edit and the item would come back (§7).
4. **Push** as usual. A device that pulls the erase adopts it (it outranks every local copy) and, through `mergeDeletedAtFromRemote`, the epoch `deletedAt` with it.
5. **Keep the row for 30 days, everywhere.** The purge rule gains one condition (§6.5, M1). The erased tombstone then outlives the erase by the normal retention instead of vanishing on the next purge, and it keeps rejecting stale copies in the meantime.
6. **Groups:** steps 1–4 apply to the container and every member of the group.
7. **Media:** mark the owner's detached references (the ones matching its detach stamp) as erased too. `MediaService.purgeExpired` then drops the blob once no live reference is left, which is the rule it already applies.
8. **CRDT-backed collections** (`journalEntries`, `dreamEntries`, `todoTasks`, per `FirestoreCollections.crdtBacked`): their text also lives in `sync_operations`, which a snapshot wipe doesn't touch. After the tombstone's upload succeeds, delete that document's operation log (§6.5, M4). **The tombstone document stays.**

**Empty trash** runs the erase over the filtered list in one pass, batching the pushes the way `pushTodoTasksBatch` and `pushStudyCardsBatch` do and notifying once.

### 6.5 Writes that arrive after an erase

The erase itself is straightforward. The harder part is other devices that are still writing. Three facts from the sync layer determine what can go wrong:

- `FirestoreSyncRepository.upsertDocument` is an unconditional `set(..., SetOptions(merge: true))`. Firestore doesn't compare versions; the last write wins in the cloud. Versions are compared only on the pulling device (`remoteVersionWins`).
- The journal, dream and todo save coordinators (`journal_write_coordinator.dart`) read the current row from SQLite and apply the editor's change on top. `copyWith` keeps `deletedAt`, so an autosave onto a tombstone writes the editor's text *into* the tombstone and uploads it, along with new character operations.
- Only Jobs and Rankings push a local row back when it beats an incoming copy (`if (result.localWon) push…`). Journal, dream and todo pulls just keep the local row and leave Firestore stale.

Here is what that means when device A erases an entry that device B has open:

| # | What happens on B | Result without mitigation |
|---|---|---|
| R1 | B autosaves **before** pulling the erase | B's full text overwrites the wiped document in Firestore as a *live* row at B's lower version. Devices still holding the tombstone ignore it. A device without the row (a fresh install, or any device after it purged) adopts it: **the item comes back.** |
| R2 | B pulls the erase, but its editor is still open and autosaves | The editor's text is written into the tombstone and uploaded. The row stays deleted, but **the wiped content is back in Firestore** and in `sync_operations`. |
| R3 | B has char ops queued that upload after A wiped the log | **Orphaned operations** in `sync_operations` spell out the old text. (This was the open risk in the first draft.) |

**Mitigations:**

- **M1: erased tombstones keep guarding for 30 days.** The purge condition becomes `deletedAt <= cutoff AND updatedAt <= cutoff`, applied in `SoftDeletePolicy.isExpired` and in each repository's `purgeExpiredDeleted` statement. An erase stamps `updatedAt = now`, so the row stays for the full retention. An ordinary tombstone has `updatedAt` equal to its delete time, so its purge date doesn't change. Every device holding the tombstone keeps rejecting stale copies (R1) for 30 days, as it does for ordinary deletes today.
- **M2: holders repair Firestore.** In the pull handlers for in-scope collections, when the local row `isErased` and the incoming copy loses, push the local tombstone back. This is the Jobs/Rankings `localWon` pattern, limited to erased rows so ordinary pull behaviour doesn't change. After R1, the first device holding the tombstone to pull B's write restores the wiped document in Firestore. Because the erase's version outranks B's, B then adopts it on its next pull.
- **M3: nothing writes onto an erased row.** The three save coordinators, and the outbox pusher that re-reads the row, drop a save whose baseline `isErased`. They discard the document's char-op session and pending merge buffer (`removeSession`, `clearDocument`), and the open editor closes the same way it does when an entry is deleted locally. This closes R2 at the source.
- **M4: the op-log wipe retries and runs again after a repair.** `deleteOperationsForDocument` refuses to run from cache, so it fails offline. The erase records `(collection, documentId)` in a small **local-only** table, `pending_op_wipes`. `OutboxSyncWorker` drains that table once the tombstone's own upload has cleared `_notOwedUpload`, and M2 adds a row again whenever it repairs a CRDT document. Ops that B uploaded late (R3) are therefore removed by the next wipe. A device that never holds the row can't queue a wipe, which is fine: it can't have an open session on the document either.

**Remaining exposure:** a device that stays offline for more than 30 days after the erase, then comes back with unsynced edits to the erased item. By then every guard has been purged, so its write lands as a live row, which is the same as for an ordinary soft delete today. It needs both a 30-day absence and edits to that exact item, so v1 accepts it.

Separately, R1 also applies to ordinary soft deletes of journal, dream and todo rows today: a stale save can leave a live copy in Firestore, which surfaces 30 days later on devices that purged. This HLD extends M2 only to erased rows. Extending it to every tombstone is a one-line change per pull handler, but it changes existing sync behaviour, so it belongs in its own change.

### 6.6 Live list

`trashItemsProvider` combines every adapter's `list(cutoff)`. It is invalidated by the same signals the feature pages already watch: a local write through the repositories and `SyncedWriteNotifier` / `SyncActivityController` for pulls. The Settings count watches the same provider. With about 20 small indexed queries on `deletedAt`, it only runs while Trash or Settings is on screen.

---

## 7. Sync and versioning summary

| Action | `deletedAt` | `version` | Content | Firestore doc | Op log |
|---|---|---|---|---|---|
| Soft delete (today) | `now` (shared across a group, §6.3) | +1 | kept | tombstone | kept |
| Restore | `null` | disk + 1 | kept | live again | kept |
| Delete forever (erase) | epoch | disk + `kEraseVersionStep` | wiped | wiped tombstone, kept; repaired by holders (M2) | deleted, retried (M4) |
| 30-day purge | — | — | — | untouched | untouched |

The purge now needs `deletedAt <= cutoff AND updatedAt <= cutoff` (M1). For ordinary tombstones nothing changes; an erased row is kept for 30 days after the erase.

A restore still races a concurrent edit under the normal version-first rule, the same as today. An erase doesn't race: its version step outranks any realistic concurrent edit, so it wins.

---

## 8. Risks

- **Writes from other devices after an erase** (an open editor, queued ops, a stale autosave). Analysed and mitigated in §6.5 (M1–M4). What remains is a device offline for more than 30 days with edits to the erased item, the same exposure an ordinary soft delete has today.
- **The version jump.** `kEraseVersionStep` makes erased rows' versions large. Nothing compares versions except to order them, and an erased row is never restored or edited again (M3), so the jump stays confined to rows on their way out. A test pins this (§9).
- **"Parent gone" into a default container that was itself deleted.** The default container ids (`legacyJournalId`, `legacyTodoListId`, `legacyCalendarId`) can't be deleted: every container-delete path returns early for them. So a restore always has somewhere to go.
- **A misclick on Empty trash.** Mitigated by the confirm with an item count and by scoping it to the active filter. Deliberately no undo, per the product decision.
- **Scope creep in adapters.** Every feature restores a little differently (trackers have no cascade, study folders nest). The adapter boundary keeps that out of the page, but finance and study need the most care.

---

## 9. Testing

- **Grouping:** for each container path in §6.3, the container and its children share one `deletedAt`, and a child deleted earlier keeps its own. Journal regression: an already-deleted entry isn't re-stamped by a later journal delete.
- **Restore:** a restored row has `deletedAt == null` and `version == disk + 1`, and it is pushed. A group restore brings back exactly its members. `RestoreSuperseded` fires on a row that is already live. A child whose parent is gone lands in the default container.
- **Delete forever:** the row is content-wiped, has `deletedAt == kErasedAt` and `version == disk + kEraseVersionStep`, and is absent from `list()`. It survives `purgeExpiredDeleted` until 30 days after the erase, and an ordinary tombstone's purge date is unchanged. For CRDT collections, the op wipe is queued in `pending_op_wipes` and drained once the upload clears. Media references are erased with it.
- **After an erase (§6.5):** R1: a lower-version live copy pulled onto a device holding the erase is rejected, and that device pushes the tombstone back (M2). R2: a coordinator save whose baseline `isErased` writes nothing and uploads nothing (M3). R3: a repair queues another op wipe (M4). An erase beats a concurrent edit whose version is several bumps ahead.
- **Round-trip:** map a group's tombstones through `firestore_document_mapper` and back, and check that the stamps still compare equal.
- **Adapter lists:** plumbing tombstones (§4.2) never appear, and rows past the cutoff never appear.
- **Widget:** filter chips, the "Empty <Feature> trash" label, confirm dialogs, compact layout, and the live update when a tombstone arrives.

Extend the existing `*_delete_undo_test.dart` files where they already build the feature's repositories.

---

## 10. Implementation phases

1. **Grouping fixes.** The shared-stamp changes and the journal `deleted_at IS NULL` fix (§6.3). These are small, fix a real bug on their own, and need to land first so groups exist by the time Trash ships.
2. **Foundation plus two adapters.** `lib/core/trash/`, the Trash page, the Settings row and route, and the **Journal** and **To-Do** adapters (restore only, including the container groups and "parent gone").
3. **Delete forever and Empty trash** for those two, with M1–M4 (§6.5): the purge condition, `localWon`-style repair for erased rows, the coordinator guard, and `pending_op_wipes` drained by the outbox worker. Journal and To-Do are both CRDT-backed, so this phase covers the hardest case first.
4. **Remaining adapters**, in order: Dreams, Calendar, Study, LeetCode, Rankings, Jobs, Workout, Analytics, Life Tracker, Finance. Add each feature's "Recently deleted" menu link along with its adapter.
5. **Update docs.** Move `GAPS.md` P1 to done, point `SOFT_DELETE_TOAST.md` §3 at this doc for container restores, and note Delete forever in ADR 002.

## 11. Follow-ups (not v1)

- Make the undo toast call `TrashAdapter.restore` instead of its own snapshot restores. This would remove most of the per-feature `restore*` helpers. Container deletes could then offer undo too.
- Search in Trash.
- Expanding a group to restore individual children.

## 12. Files touched (expected)

New: `lib/core/trash/{trash_item,trash_adapter,trash_providers}.dart`, `lib/features/trash/trash_page.dart`, one `*_trash_adapter.dart` per feature, tests.

Changed: `lib/features/settings/settings_page.dart` (row), `lib/routing/app_router.dart` (route), `lib/data/repositories/drift_repositories.dart` and `lib/domain/repositories/repositories.dart` (optional `at` on cascade soft deletes, journal filter fix, `restore*` where missing), `lib/features/{todo/todo_list_actions,journal/journal_list_actions,calendar/calendar_list_actions,study/study_actions}.dart` (shared stamp), each feature page's overflow menu, `lib/core/sync/soft_delete_policy.dart` and every `purgeExpiredDeleted` (M1), `lib/core/sync/remote_sync_service.dart` (repair for erased rows in pull handlers, M2), `lib/core/sync/journal_write_coordinator.dart` (M3), `lib/core/sync/outbox_sync_worker.dart` and `lib/data/database/app_database.dart` (local-only `pending_op_wipes` table and its drain, M4; schema bump), and the docs listed in phase 5.

---

## 13. Implementation notes (deviations from this document)

Written after the fact. Where the code and the sections above disagree, the code is right and this section says why.

### 13.1 One generic service instead of per-feature adapters (§6.1)

The backup registry (`lib/features/settings/services/backup_collections.dart`) can already read every synced collection out as Firestore payloads, tombstones included, and write any payload back through that collection's own deserializer. A restore is a payload with `deletedAt: null` and `version + 1`; an erase is one with its content blanked, `deletedAt: kErasedAt` and `version + kEraseVersionStep`. Both go through the same serializers that sync and backups use, as `ColorReplacementService` already does. Each type is therefore a declarative `TrashKind` in `lib/features/trash/trash_kinds.dart` (collection, title, fields to wipe, children, parents, media owner), and `TrashService` (`lib/features/trash/trash_service.dart`) does the rest. Twelve adapters would have repeated the same read, rewrite and push with only the field names changing.

It lives under `lib/features/trash/`, not `lib/core/trash/`, because it depends on the registry in `features/settings` and `core/` must not import features (ADR 003).

Registry writes happen with `recordLocalActivity: false`, like an import. The service uploads through `RemoteSyncService.pushTrashRecords` after the transaction commits, and the dialog invalidates every data provider afterwards, as a restore from backup does.

### 13.2 Trash is a dialog; the Settings row has no count (§5.1, §5.2)

The screen is `showTrashDialog(context, feature:)`, like the other Settings screens (backups, snippets, dictionary), not a `/settings/trash` route. A page's link then opens it over that page instead of switching the shell to Settings.

The Settings row shows no item count. The Settings branch stays mounted, so a count on it would go stale after every delete made elsewhere.

### 13.3 "Recently deleted" is in five manage sheets (§5.1)

Journal, To-Do, Calendar, Jobs and Rankings each have a manage sheet, and the button sits in its actions. Dreams, Study, LeetCode, Finance, Analytics, Workout and Life have no overflow or manage menu, so, as §5.1 allowed, they have no link in v1. Their items are in Trash under their chip.

### 13.4 Images are restored by time, and not erased (§6.4 step 7)

The trash has no record of the stamp the media detach used; only the toast's snapshot held it. `MediaService.restoreReferencesDetachedSince` brings back every reference on the owner that was detached at or after the owner's own `deletedAt`. A deleted row can't be edited, so anything detached from it after that moment went with the delete.

An erase leaves the images alone. Their references are already tombstoned by the delete, and the blob is purged on the existing clock once nothing references it. Marking the references erased as well would, under M1, only have kept them 30 days *longer*.

### 13.5 No new table for the op-log wipe (§6.5 M4)

An erased journal entry, dream or task is published by `RemoteSyncService._publishErasure`, which drops the local session and buffered text, wipes the operation log and uploads the emptied document without a log entry. If the wipe fails offline, the ordinary outbox row is enough: `pushOutboxDocument` sends any erased row back to `_publishErasure`, and so does `_uploadCrdtDocumentNow` if any other path reaches it with one. No schema change.

### 13.6 The repair covers every tombstone, in one place (§6.5 M2)

Decided with the user: M2 applies to every tombstone, not just erased rows, which also fixes R1 for ordinary deletes. Instead of a hook in each of ~55 pull handlers, `_pullCollection` checks everything it just applied, reading this device's copies through `OutboxSyncWorker.localPayloadsFor`. A local tombstone that still differs from the pulled copy, and is not behind it, has beaten it, so it is queued with `recordOwedUpload` and the drain is started. This costs one extra local read per pulled document.

The three CRDT pull handlers also short-circuit before conflict detection. An incoming erase is adopted outright, dropping any editor session. A copy arriving for a row already erased here is not applied at all, and the post-pull check puts the erase back.

### 13.7 Erased rows are never purged (replaces §6.5 M1)

The first build made the purge wait on `updatedAt` as well, which kept an erased row for 30 days after the erase. That still let a device that stayed offline longer bring the item back. Now the purge skips erased rows altogether (`deletedAt > kErasedAt` in every `purgeExpiredDeleted`, and `SoftDeletePolicy.isExpired`), and `updatedAt` plays no part in it. An erased row holds no content, and Firestore kept its tombstone forever anyway. The cost is one id-and-timestamps row per erased item on each device, and that row is what rejects a stale copy however late it arrives.

### 13.8 Stamps are only as fine as the clock

Grouping compares `deletedAt` exactly. On Windows the wall clock can tick in whole milliseconds, so two *separate* deletes made inside one tick look like one delete. A person can't do that; a test can, and the trash tests pause between deletes.

### 13.9 Erases win field-by-field merges whole

Rankings entries and units, and job applications, merge field by field. In the first build, a field edited offline *after* an erase won that field when its copy reached a device holding the erase, which put text back into the tombstone. The three resolvers (`resolveRankingParentFromRemote`, `resolveRankingChildFromRemote`, `resolveJobApplicationFromRemote`) now keep an erased local row whole, and the post-pull repair puts the erase back on the server.

### 13.10 A device back after a long absence pulls before it uploads

Ordinary tombstones are still purged locally on the 30-day clock, but the Firestore tombstone document is never removed. What let a device offline for longer than that bring a deleted item back was the order of things on its return: the outbox drain starts the moment sign-in resolves, ahead of the startup pull, so its queued offline edits overwrote the cloud tombstone before the device had seen it, and no other device still held the row to repair it.

`OutboxSyncWorker` now runs a `beforeDrain` hook, `RemoteSyncService.catchUpIfAway`. When any collection's last full pull is older than the retention window (a syncing device pulls each one whole at least every 7 days), it runs `pullAll` first. The tombstone then meets the offline edits on this device under the usual rules: the delete wins on version, or the text conflict comes up for the user to resolve. If the pull fails, that drain sends nothing and the next one tries again. No tombstone has to be kept forever for this.

Uploads outside the outbox wait for it too. While the catch-up runs, `_runInDocumentChains` (every chained save, batch and record push) and the three unchained entry points (`pushTodoTaskNow` and the Search text overwrites) hold until it finishes. They are held before joining a document's upload chain, and the catch-up's own uploads run in a marked zone and aren't held, so neither can wait on the other. An edit made in the first moments back online therefore reaches the server only after the pull. If it still carries the stale content, this device now holds the tombstone, and its next pull puts the deletion back (§13.6).
