# Saving & Sync Audit

Audit of the local (Drift/SQLite) and remote (Firestore) save, pull and reconciliation
paths. Dev-only code (`RemoteSyncCompareService`, `out_of_sync_journal_entry_purge`,
`DevFlags`-gated branches, `forceConflictUi`) is out of scope by request.

Findings are ordered by severity. Each entry states the file, the defect, the scenario
that triggers it, and the fix.

---

## 1. Operation-log IDs collide across app restarts

**File Name:** `lib/core/sync/sync_engine.dart` (lines 54, 130, 231)

**Bug Description:** `SyncEngine._sequence` is an in-memory counter initialised to `0`
on every construction and never persisted. Operation document IDs are minted as
`'${_deviceId}_${documentId}_$sequence'`, and `FirestoreSyncRepository.appendOperation`
writes with `.set()` on that ID. After a restart the counter restarts at 1, so the first
sync of a document that was also the first sync of a previous session produces an
identical operation ID and **silently overwrites the earlier operation group**. The
`sequence` field is also the primary sort key in `CrdtDocumentResolver._mergeSyncOperations`
and `FirestoreSyncRepository.listOperations`, so even non-colliding IDs get replayed in
the wrong order after a restart.

**Impacted Scenario:** Open the app, edit journal entry E (writes ops at sequence 1–3).
Close the app. Reopen and edit E again — the new op group takes ID `device_E_1` and
destroys the first session's group. Characters inserted in session 1 disappear from the
CRDT chain; the next pull on any device resolves the document from the damaged chain and
reverts them.

**Proposed Fix:** Persist the sequence counter. Either store a per-device monotonic
counter in the settings row (loaded in the `SyncEngine` constructor, incremented and
saved on use), or make the ID collision-free without persistence by including the wall
clock — e.g. `'${_deviceId}_${documentId}_${timestamp.microsecondsSinceEpoch}_$sequence'`
— and seed `_sequence` from `max(sequence)` of the operations already fetched in
`RemoteSyncService.prepareEditingSession`.

---

## 2. Outbox retries write the document mirror but never the operation log

**File Name:** `lib/core/sync/outbox_sync_worker.dart` (lines 104–128, 145–179, 188–202)

**Bug Description:** `_resolveUpload` rebuilds a plain Firestore payload
(`journalEntryToFirestore`, `todoTaskToFirestore`, …) and the drain commits it with
`batch.set(ref, data, SetOptions(merge: true))`. No `sync_operations` entry is ever
written. But `RemoteSyncService._pullCollection` (line 1484) prefers the CRDT-resolved
payload over the raw document whenever operations exist for that document. So a document
recovered through the outbox has a *newer mirror* and a *stale op-log*, and the op-log
wins on every subsequent pull.

**Impacted Scenario:** Connection drops mid-typing in a journal entry. The debounced
upload fails, `_runRemoteSave` queues it on the outbox. On the next launch the drain
pushes the current body to `journal_entries/E`. The startup `pullAll` then resolves E
from `sync_operations`, which still holds the pre-drop text, and overwrites the recovered
body — on this device and every other one. The user sees their offline edit appear
briefly and then vanish.

**Proposed Fix:** Route outbox retries through the same path as a live save rather than
a raw `batch.set`. Either have the drain call `RemoteSyncService.pushJournalEntryNow` /
`pushTodoTaskNow` (which go through `SyncEngine.syncDocumentImmediately` and carry
char-ops), or, at minimum, have the drain append a full-snapshot operation group for
CRDT-backed collections so the op-log is never older than the mirror.

---

## 3. Pending character operations are consumed before the upload succeeds

**File Name:** `lib/core/sync/remote_sync_service.dart` (lines 1813, 1833, 1970),
`lib/domain/services/character_op_session.dart` (lines 120–127)

**Bug Description:** `_uploadJournalEntryNow`, `_uploadDreamEntryNow` and
`_uploadTodoTaskNow` call `_charOpRegistry.takePendingOps(...)` *before* awaiting
`syncDocumentImmediately`. `takePendingOps` clears `_pendingOpIds` unconditionally. If
the upload then throws (offline, permission, oversize payload), the operations are gone
from the pending set forever — they remain in `_opsById`, so the session's reconstructed
text already contains them and no later `recordTextChange` will re-emit them.

**Impacted Scenario:** User types a paragraph offline. The debounced upload fires and
fails. The ops are already taken. When the connection returns and the user types one more
character, only that character's op is uploaded — the paragraph never reaches
`sync_operations`, and any device resolving the entry from the op-log renders it missing.
Combined with finding #2, this is the main way offline journal text is lost.

**Proposed Fix:** Make the take/clear transactional: peek the pending ops, perform the
upload, and only clear on success. Add `CharacterOpSession.restorePendingOps(List<String> ids)`
(or a `takePendingOps({bool commit})` variant) and wrap the upload in a `try`/`catch`
that restores the pending IDs before rethrowing.

---

## 4. Seventeen collections and the settings document can never be retried

**File Name:** `lib/core/sync/outbox_sync_worker.dart` (lines 255–260, 348–368),
`lib/core/sync/remote_sync_service.dart` (lines 2184–2196, 2620–2627)

**Bug Description:** `OutboxSyncWorker.drainableCollections` contains only
`journal_entries`, `journals`, `todo_tasks`, `todo_lists`. `recordFailure` parks — rather
than queues — anything else, with the reason `'No automatic retry for $collection'`. Every
collection routed through `SyncedWriteNotifier` → `pushRecords` (calendars, calendar
events, trackers, tracker values, all eight finance collections, pinned notes, dismissed
notifications, bucket list, tag colors, custom words) plus `pushSettings` therefore has
**no retry path at all**. Nothing else re-pushes them either: `backfillSyncedCollections`
is version-gated and runs exactly once per device, and a pull never triggers a push.

**Impacted Scenario:** The user adds a transaction, a calendar event or changes their
accent colour while the network is flaky. The write is parked. Local SQLite has it and
wins every future merge (higher `version`, newer `updatedAt`), so no pull ever repairs the
divergence. Firestore — and every other device — stays permanently missing that record,
with no user-visible indication beyond the parked-uploads list.

**Proposed Fix:** Teach `_resolveUpload` to rebuild payloads for the remaining
collections (the mappers already exist in `firestore_document_mapper.dart`, and
`_recordDocument` in `RemoteSyncService` is effectively the same switch) and add them to
`drainableCollections`. For settings, add a `settings` case that re-reads
`_settingsRepository.getSettings()` and writes via `upsertRemoteSettings`. Note that
`pushRecords` keys outbox rows by the *Firestore* document ID while `_runRemoteSave` keys
them by the *local* ID; unify on one before wiring the drain, or encoded-ID collections
(`tag_colors`, `custom_words`, `dismissed_notifications`) will never be cleared.

---

## 5. `maxRetryAge` is defeated by re-enqueueing

**File Name:** `lib/core/sync/outbox_sync_worker.dart` (lines 278–295, 205–235)

**Bug Description:** `_handleUploadFailure` parks a row once
`DateTime.now() - pending.addedAt > maxRetryAge` (7 days). But `enqueue` uses
`insertOnConflictUpdate` with `addedAt: Value(DateTime.now().toUtc())`, resetting the age
on every re-queue. Since `RemoteSyncService._runRemoteSave` calls `recordFailure` →
`enqueue` on every live upload failure for the same document, the row's age is reset
faster than it can ever expire.

**Impacted Scenario:** A journal entry hits an error this code misclassifies as transient
(the classifier defaults everything unrecognised to transient by design). The user keeps
editing it, so each failed debounced upload re-enqueues it with a fresh `addedAt`. The row
retries on every launch indefinitely, and — because the drain processes the queue in
`addedAt` order — it also keeps jumping around the queue instead of ageing out of it.

**Proposed Fix:** Preserve the original `addedAt` on re-enqueue. Do an
`INSERT … ON CONFLICT DO UPDATE SET failureReason = NULL` that leaves `addedAt` alone
(or add a separate `firstQueuedAt` column that `enqueue` only sets when the row is new),
and compare `maxRetryAge` against that column.

---

## 6. Deleting a task from the notification inbox never reaches Firestore

**File Name:** `lib/features/notifications/notification_inbox_popover.dart` (line 712),
`lib/data/repositories/drift_repositories.dart` (line 785)

**Bug Description:** `_deleteTask` calls `todoRepository.softDeleteTask(task.id)` and then
only invalidates providers. `DriftTodoRepository` is not wired to `SyncedWriteNotifier`
(todo tasks push explicitly), and `softDeleteTask` fires neither a notifier nor a
`_syncActivity.recordLocalSave`. Every other soft-delete site in the app follows the
repository call with an explicit push — `journal_page.dart:1599`,
`search_page.dart:83`, `study_actions.dart:234`, `leetcode_actions.dart:95` all do. This
one does not. `_deleteEvent` immediately below it is safe only because
`DriftCalendarRepository.softDeleteEvent` routes through `upsertEvent`, which does notify.

**Impacted Scenario:** User dismisses an overdue task from the notification inbox. It
disappears locally. Firestore still holds the live task, so every other device keeps
showing it, and a reinstall or a fresh device resurrects it. The local tombstone is also
purged after the retention window, at which point the next pull brings the task back on
this device too.

**Proposed Fix:** Mirror the other delete sites — re-read the tombstone and push it:

```dart
await ref.read(todoRepositoryProvider).softDeleteTask(task.id);
final tombstone = await ref.read(todoRepositoryProvider).getTask(task.id);
if (tombstone != null) {
  await ref.read(remoteSyncServiceProvider).pushTodoTaskNow(tombstone);
}
```

Consider moving the push into `softDeleteTask` itself so the next call site cannot repeat
the omission, the way the `SyncedWriteNotifier` collections already do.

---

## 7. Restoring a backup is reverted by the stale operation log

**File Name:** `lib/features/settings/services/data_import_service.dart` (lines 141–145),
`lib/features/settings/services/backup_collections.dart` (lines 74–80)

**Bug Description:** The restore writes records to SQLite and then uploads them with
`_pushRecords` → `RemoteSyncService.pushRecords` → `syncDocumentsImmediately(logOperation: false)`.
`sync_operations` is deliberately excluded from the backup ("a transport detail"), so for
`journal_entries`, `dream_entries` and `todo_tasks` the restore updates the document mirror
while leaving the old CRDT chain intact. `_pullCollection` prefers the CRDT-resolved
payload, so the restored text loses to the op-log on the very next pull.

**Impacted Scenario:** The user restores a backup to recover a journal entry whose body
they accidentally cleared. The entry looks correct until the next startup pull or live-sync
tick, at which point the op-log (which still describes the cleared body) resolves over it
and the recovery is undone.

**Proposed Fix:** For the three CRDT-backed collections, clear the remote operation log for
each restored document before pushing — `RemoteSyncService` already has
`_syncRepository.deleteOperationsForDocument(id)` and does exactly this in
`forceOverwriteJournalEntryText`. Add a restore-aware push (`pushRestoredRecords`) that
deletes the ops, resets the char-op session, and pushes a fresh seed for those collections.

---

## 8. Startup purge runs before the pull, so expired tombstones are recreated every launch

**File Name:** `lib/core/sync/sync_engine.dart` (lines 176–186),
`lib/core/sync/firestore_document_mapper.dart` (line 866 onward)

**Bug Description:** `pullOnStartup` awaits `purgeExpiredDeleted()` *first*, then
`pullFromRemote()`. The purge hard-deletes local rows whose `deletedAt` is older than the
retention window. The pull that follows re-downloads those same tombstones from Firestore
— nothing in `_pullCollection` or the `mergeXFromRemote` functions filters expired
tombstones, and with `local == null` the merge unconditionally materialises the remote
document — so the row is re-inserted with its `deletedAt` intact. Next launch purges it
again.

**Impacted Scenario:** Every single launch, for every record ever soft-deleted more than
`softDeleteRetentionDays` ago: N local deletes followed by N local inserts, plus the
Firestore reads to fetch them, forever. The tombstones are never cleaned from Firestore at
all, so the cost grows monotonically with the account's lifetime deletions.

**Proposed Fix:** Two changes. (a) Run `purgeExpiredDeleted` *after* the pull, so the
freshly-downloaded expired tombstones are removed in the same pass. (b) Skip expired
tombstones on the way in — in `_pullCollection`, drop documents whose `deletedAt` is older
than the retention window rather than applying them. Optionally have the purge also delete
the remote document so the tombstone eventually leaves Firestore.

---

## 9. Nothing resumes syncing when the connection comes back

**File Name:** `lib/main.dart` (lines 206–216), `lib/core/sync/connectivity_status.dart`,
`lib/features/shell/app_shell.dart` (line 444)

**Bug Description:** `OutboxSyncWorker.startDraining()` is invoked from exactly one place:
`_onAuthStateChanged(true)`, i.e. app start and sign-in. `startDraining` itself swallows
network errors with the comment "It will resume on next app startup". Meanwhile
`ConnectivityStatusController` detects the offline→online transition on a 10-second probe
— but its only consumer is the offline badge in `app_shell.dart`. No listener restarts the
drain, and nothing re-runs `pullAll` either.

**Impacted Scenario:** The user is on a train, edits for twenty minutes, and comes back
online. The badge clears, but the queued uploads sit in `pending_uploads` and the local
database stays out of step with remote until the app is restarted. Long-lived desktop
sessions (which this app is built for — global hotkeys, window chrome, tray-style usage)
may go days without a restart.

**Proposed Fix:** Have `ConnectivityStatusController` expose the offline→online edge and
wire a listener in `_VoyagerBootstrapState` that calls `OutboxSyncWorker.instance.startDraining()`
(it is already idempotent via `_isDraining`) and, if the offline stretch was long enough,
a `remoteSync.pullAll(skipWeather: true)`. A `didChangeAppLifecycleState(resumed)` hook is
worth adding for the same reason.

---

## 10. Self-echo suppression discards genuine concurrent remote changes

**File Name:** `lib/core/sync/remote_sync_service.dart` (lines 141–153, 1464–1469)

**Bug Description:** `_markSelfEcho` records `collection/documentId → now`, and
`_consumeSelfEcho` returns true (skip) for any change on that key within 15 seconds — with
no check of *what* changed or *who* wrote it. A change from another device that lands
inside that window on the same document is dropped, and because `_consumeSelfEcho` removes
the entry, no retry ever redelivers it. Finding #14 makes this materially worse: the mark
is written after the upload resolves, i.e. after our own echo has already slipped past, so
the mark that remains is positioned precisely to eat the *next* — genuine — change.

**Impacted Scenario:** Two devices editing the same todo list. Device A completes a task
(marks self-echo). Within 15 s device B renames it. A's snapshot listener fires, A
consumes the echo, and B's rename is never applied on A. A keeps showing the old title
until a full pull at the next launch — and if A edits the task again first, A's stale title
is pushed back over B's rename.

**Proposed Fix:** Make the echo test content-aware rather than time-based. Store the
payload hash (or the `version` + `updatedAt` pair) that was uploaded alongside the
timestamp, and in `_pullCollection` skip only when the fetched document matches what was
pushed. That also removes the arbitrary 15-second window and the map's unbounded growth
(entries are currently only removed by a matching pull or by `dispose`).

---

## 11. Self-echo marks are written after the upload, so suppression rarely fires

**File Name:** `lib/core/sync/remote_sync_service.dart` (lines 1826, 1846, 1855, 1864,
1873, 1882, 1891, 1900, 1909, 1918, 1927, 1936, 1945, 1954, 1963, 1983, 1626–1628,
1671–1673, 1737–1739)

**Bug Description:** Every `_uploadXNow` and every batch push calls `_markSelfEcho` *after*
awaiting the Firestore write. `DocumentReference.set()` resolves on server acknowledgement,
whereas Firestore's snapshot listener fires from the local write cache almost immediately.
`LiveSyncController` therefore reaches `_consumeSelfEcho` before the mark exists, the echo
is not suppressed, and the pull proceeds to re-`get()` the document, CRDT-merge it,
re-upsert it into SQLite and call `_onChanged()` → `invalidateAllDataProviders(ref)`.
`pushRecords` (line 2168) gets this right by marking before the upload; the ~19 other call
sites do not.

**Impacted Scenario:** Every single save of a journal entry, dream entry, todo task, study
card, workout set log, exercise, LeetCode problem or quote. Each one costs an extra
Firestore document read, an extra `listOperations` query, an extra SQLite write and a
full-app provider invalidation — exactly the work the self-echo mechanism was written to
avoid. This is the largest source of avoidable reads and rebuilds in the app.

**Proposed Fix:** Move `_markSelfEcho(...)` above the `await` in every upload method (and
above the `syncDocumentsImmediately` call in the three batch pushes), matching what
`pushRecords` already does. If a write ultimately fails the stale mark is harmless once
finding #10's content-aware check is in place.

---

## 12. Live sync refetches documents the snapshot listener already delivered

**File Name:** `lib/data/remote/firestore_sync_repository.dart` (lines 40–47),
`lib/core/sync/remote_sync_service.dart` (lines 1460–1474)

**Bug Description:** `watchCollection` maps each `QuerySnapshot` down to a `Set<String>`
of document IDs and throws away `change.doc.data()` — which Firestore has already
delivered and already billed for. `_pullCollection` then issues a separate
`getDocument(collection, firestoreDocId)` per changed ID, one round trip each, defaulting
to `Source.serverAndCache` (i.e. a billed server read).

**Impacted Scenario:** Any multi-document change: completing a task that renumbers 40
siblings, a `pushTodoTasksBatch`, a `pushWorkoutSetLogsBatch` when a session is
materialised, or another device's bulk edit. One snapshot carrying 40 documents becomes 40
additional document reads, serialised, each awaiting `ScrollActivityGate`. On a metered
Firestore plan this roughly doubles read cost for every live-sync tick.

**Proposed Fix:** Change `watchCollection` to emit
`Stream<List<({String id, Map<String, dynamic> data})>>` (or a `Set<String>` plus a data
map) and have `_pullCollection` accept the already-fetched payloads, falling back to
`getDocument` only for IDs it was given without data. The `snapshotOnly` collections then
need no network call at all on a live tick.

---

## 13. Operation-log entries are written for collections that have no collaborative text

**File Name:** `lib/core/sync/sync_engine.dart` (lines 203–298),
`lib/core/sync/firestore_collections.dart` (lines 95–113),
`lib/core/sync/remote_sync_service.dart` (lines 1849–1964)

**Bug Description:** `_syncDocument` skips the operation log only when
`logOperation: false` is passed, which happens solely from `pushRecords` for the
`snapshotOnly` set. Journals, todo lists, LeetCode problems, study folders/decks/cards/
review log, exercises, workout plans/plan entries/sessions/set logs and custom quotes are
in neither set: they carry no collaborative text, yet every `_uploadXNow` writes a
full-snapshot `sync_operations` entry alongside the document. Their pulls likewise use the
default `resolveCrdt: true`, spending one indexed `listOperations` query per document. And
because `compactOperationLog` is only ever triggered from `prepareEditingSession` — which
only runs for journal/dream/todo text editors — these logs are **never compacted** and grow
without bound.

**Impacted Scenario:** A user who has logged workouts for a year has thousands of
`sync_operations` documents for set logs that will never be read as anything but a
snapshot. Every save costs two writes instead of one; every full `pullAll` costs one extra
indexed query per document across ~16 collections; startup pull time degrades permanently.

**Proposed Fix:** Extend `FirestoreCollections.snapshotOnly` to cover every collection
without collaborative text (everything except `journal_entries`, `dream_entries`,
`todo_tasks`), have `_uploadXNow` pass `logOperation: false` for them, and pass
`resolveCrdt: false` in their `_pullCollection` calls. Ship a one-time cleanup that deletes
the orphaned `sync_operations` rows for those collections, keyed off a bumped
`syncBackfillVersion`.

---

## 14. Weather persistence writes back a stale whole-settings snapshot

**File Name:** `lib/domain/services/weather_service.dart` (lines 35–44, 70–82, 183–233,
287–315)

**Bug Description:** `refreshIfNeeded` and `fetchForecastIfNeeded` read
`await _settingsRepository.getSettings()` once at the top, then perform network I/O
(`claimWeatherFetchLock`, `refreshWeather`, `refreshForecast` — seconds), then call
`_persistCache(settings, …)` / `_persistForecast(settings, …)`, which do
`saveSettings(settings.copyWith(weather…))`. `saveSettings` writes the **entire** settings
row via `insertOnConflictUpdate`, so any field the user changed during the network call is
reverted to the stale snapshot. Worse, `saveSettings` then compares the reverted value
against the current row, sees a synced field differ, bumps `updatedAt` and notifies
`SyncedWriteNotifier` — pushing the revert to Firestore as an authoritative new setting.

**Impacted Scenario:** The user opens Settings and changes the accent colour (or theme, or
any synced preference) while a weather refresh is in flight — which happens on launch and
every minute thereafter via `_refreshWeatherIfStale`. The colour snaps back, and because
whole-document LWW applies to settings, the reverted value propagates to every other
device.

**Proposed Fix:** Re-read settings immediately before persisting, and pass
`recordLocalActivity: false` since weather fields are device-local cache:

```dart
Future<void> _persistCache(WeatherSnapshot snapshot) async {
  final current = await _settingsRepository.getSettings();
  await _settingsRepository.saveSettings(
    current.copyWith(weatherIcon: snapshot.icon, /* … */),
    recordLocalActivity: false,
  );
}
```

Do the same in `_persistForecast`, `syncLocationFromRemote` and `saveLocation`.

---

## 15. Live-sync drops queued document IDs when a pull throws

**File Name:** `lib/core/sync/remote_sync_service.dart` (lines 2842–2893)

**Bug Description:** `_handleRemoteChange` copies `_queuedIdsByCollection` into `pending`
and clears the queue *before* pulling. If `pullForCollection` throws, the `catch` reports
the error and moves on — the IDs in that batch are already gone from the queue and are
never retried. Firestore will not re-emit them, since a `docChange` is delivered once.

**Impacted Scenario:** A transient failure (a dropped connection mid-pull, a malformed
document, a `ScrollActivityGate` timeout cascading into a Firestore error) during a live
tick permanently loses those documents' updates on this device until the next full
`pullAll` at launch.

**Proposed Fix:** On failure, put the IDs back:

```dart
} catch (error, stackTrace) {
  _queuedIdsByCollection
      .putIfAbsent(entry.key, () => <String>{})
      .addAll(entry.value);
  FlutterError.reportError(/* … */);
}
```

Pair it with a bounded retry/backoff so a permanently-failing document cannot spin the
`while` loop.

---

## 16. `permanentlyDeleteFromRemote` deletes operations under the wrong document ID

**File Name:** `lib/core/sync/remote_sync_service.dart` (lines 470–491)

**Bug Description:** The method computes `firestoreDocId = firestoreDocumentIdForLocal(collection, documentId)`
for the document delete, but then calls
`_syncRepository.deleteOperationsForDocument(documentId)` with the **local** ID. For
`journals` and `todo_lists` those differ (`journalDocumentIdForFirestore` /
`todoListDocumentIdForFirestore` map legacy IDs), and `_uploadJournalNow` /
`_uploadTodoListNow` store operations under the *Firestore* ID. The operations are
therefore never deleted, and the returned count is wrong.

**Impacted Scenario:** Permanently deleting a legacy-ID journal or todo list leaves its
entire `sync_operations` history orphaned in Firestore forever. If the ID is ever reused,
`_pullCollection`'s CRDT resolution will resurrect the deleted document's content over the
new one.

**Proposed Fix:** Use `firestoreDocId` for both calls:

```dart
final operationsDeleted =
    await _syncRepository.deleteOperationsForDocument(firestoreDocId);
```

---

## 17. `purgeExpiredDeleted` loads every row of every table on every launch

**File Name:** `lib/data/repositories/drift_repositories.dart` (lines 247–264, 400,
534, 795–812, 1005, 1178, 1374, 1478, 2028, and the equivalent in every other repository)

**Bug Description:** Each implementation does `await _db.select(table).get()` — a full
table materialisation into Dart objects — then loops in Dart and issues one
`DELETE … WHERE id = ?` per expired row. The predicate is `deletedAt != null && isExpired`,
which SQLite can evaluate directly. `BackgroundSyncOrchestrator.purgeExpiredDeleted` runs
all ~12 of these in parallel on every startup.

**Impacted Scenario:** Startup on an account with a large history: every journal entry,
todo task, calendar event, set log, tracker value and transaction is read out of SQLite,
decoded (including `jsonDecode` of tags/JSON columns in the `_map*` helpers), and thrown
away. This runs before the pull, on the UI isolate, in the app's first seconds.

**Proposed Fix:** Replace each with a single statement:

```dart
final cutoff = now.subtract(const Duration(days: softDeleteRetentionDays));
await (_db.delete(_db.journalEntriesTable)
      ..where((t) => t.deletedAt.isNotNull() & t.deletedAt.isSmallerOrEqualValue(cutoff)))
    .go();
```

Combine with finding #8 so the purge also runs at the right point in the startup sequence.

---

## 18. `TodoWriteCoordinator` scans every list and every task twice per save

**File Name:** `lib/core/sync/journal_write_coordinator.dart` (lines 134–147, 115, 126)

**Bug Description:** `TodoWriteCoordinator._findTask` enumerates
`listLists(includeDeleted: true)` and then `listTasks(list.id, includeDeleted: true, topLevelOnly: false)`
for every list, mapping every row into a `TodoTask`, just to find one ID. It is called
twice per save — once in `saveLocal` and once in `saveRemote`. `DriftTodoRepository.getTask(id)`
(drift_repositories.dart:824) already does this as a single indexed lookup, and
`RemoteSyncService._findTodoTask` (line 1757) uses it.

**Impacted Scenario:** Every keystroke burst in the todo edit panel's title or notes field
(400 ms debounce) triggers two full scans of the task table. On a list with a few thousand
tasks this is the dominant cost of typing, and it runs on the UI isolate.

**Proposed Fix:** Replace the body of `_findTask` with `_todoRepository.getTask(taskId)`.
The same fix applies to `RemoteSyncService._loadTaskIndex` (line 1565) where it is used to
resolve single documents.

---

## 19. Every settings save reads the settings row twice

**File Name:** `lib/data/repositories/drift_repositories.dart` (lines 2275–2315)

**Bug Description:** `saveSettings` calls `_readSettings()`, which performs a `select` on
the settings table, discards the result, and calls `getSettings()` — which performs the
same `select` again and maps ~100 columns. So each save costs two full row reads plus two
`jsonDecode` calls before writing.

**Impacted Scenario:** Settings are written far more often than the name suggests: every
weather refresh (`_persistCache`, `_persistForecast`), every forecast prune at midnight,
`getSettings()`'s own default-row insert, page-position bookkeeping (`lastSeenNavPage`,
`lastViewedJournalId`), and `SyncActivityController`. The minute-tick weather timer alone
makes this hot.

**Proposed Fix:** Have `_readSettings` map the row it already fetched — extract the
row→`AppSettings` mapping in `getSettings` into a private `_mapSettings(SettingsTableData row)`
and call it from both:

```dart
Future<AppSettings?> _readSettings() async {
  final row = await (_db.select(_db.settingsTable)..where((t) => t.id.equals(1)))
      .getSingleOrNull();
  return row == null ? null : _mapSettings(row);
}
```

---

## 20. Exercise detail fields lose pending edits when the window is closed

**File Name:** `lib/features/workout/exercise_detail_view.dart` (lines 190–216, 377–427)

**Bug Description:** Both `_FormCuesSection` and `_TargetSectionState` debounce their saves
(600 ms) and flush only from `dispose()`. Neither registers with
`PendingFlushRegistry.instance`, unlike `journal_page.dart:154`,
`dream_journal_page.dart:130` and `todo_edit_panel.dart:91`. `VoyagerApp.onWindowClose`
runs `PendingFlushRegistry.flushAll()` and then `windowManager.destroy()` — the widget is
never disposed, so the pending edit is discarded.

**Impacted Scenario:** The user edits an exercise's form cues or target sets/reps/weight
and closes the window (or alt-F4s) within 600 ms of the last keystroke. The edit is lost
entirely — it never reached SQLite, let alone Firestore.

**Proposed Fix:** Register a lifecycle flush callback in `initState` and unregister it in
`dispose`, following the pattern in `todo_edit_panel.dart`:

```dart
late final Future<void> Function() _lifecycleFlushCallback = () async => _flushCues();
// initState:  PendingFlushRegistry.instance.register(_lifecycleFlushCallback);
// dispose:    PendingFlushRegistry.instance.unregister(_lifecycleFlushCallback);
```

---

## 21. `_selfEchoAt` grows without bound

**File Name:** `lib/core/sync/remote_sync_service.dart` (lines 141–153)

**Bug Description:** Entries are added by `_markSelfEcho` on every upload and removed only
by a matching `_consumeSelfEcho` or by `dispose()`. Nothing prunes entries older than
`_selfEchoWindow`. When the sync repository is a `NoOpSyncRepository` (signed out) or
`LiveSyncController` has not started, no pull ever consumes them.

**Impacted Scenario:** A signed-out or long-running session accumulates one map entry per
document ever written, for the process lifetime. Small in absolute terms, but it also
means a mark can survive for hours and then swallow a legitimate remote change when live
sync eventually starts — see finding #10.

**Proposed Fix:** Prune on write: in `_markSelfEcho`, drop entries older than
`_selfEchoWindow` (`_selfEchoAt.removeWhere((_, at) => now.difference(at) >= _selfEchoWindow)`),
or replace the map with the content-hash scheme proposed in finding #10 and clear it in
`LiveSyncController.start()`.

---

## Verified as correct

Worth recording so these are not re-audited:

- **Write ordering in `SyncEngine._syncDocument`** — operation log before document mirror,
  each with its own retry scope, is the right order and the reasoning in the comment holds.
- **Compaction safety** — `compactOperationLog` writes the baseline before deleting
  superseded operations, guards re-entry with `_compactingDocuments`, and requires a 24 h
  foreign-write cool-off.
- **`onWindowClose` flush** — `configureDesktopWindow` calls `setPreventClose(true)`
  (`desktop_window.dart:29`), so the `await _flushAllPendingEdits()` before
  `windowManager.destroy()` genuinely completes.
- **Controller reads during dispose** — both `journal_page.dispose` and
  `todo_edit_panel.dispose` read their `TextEditingController`s synchronously before the
  first `await`, so the unawaited flush cannot touch a disposed controller.
- **`saveSettings` clock gating** — `_sameSyncedSettings` correctly prevents device-local
  writes (weather cache, dev flags, `lastSeenNavPage`, `syncBackfillVersion`) from bumping
  the LWW clock or reaching the sync layer.
- **`backfillSyncedCollections` ordering** — running after the pull, and recording the
  version only on a clean run, is correct.
- **Restore transaction hygiene** — `backup_collections.dart` restores with
  `recordLocalActivity: false`, so `SyncedWriteNotifier` does not fire uploads from inside
  the import's write transaction.
- **`saveLocalThenScheduleUpload` generation guard** — coalescing superseded local saves is
  safe because each `applyDelta` re-reads its baseline from SQLite.
