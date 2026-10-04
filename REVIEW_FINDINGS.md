# Review findings — counter statistic and folder backup

From `/code-review` on the uncommitted working tree, 2026-10-03, and from what I found while building the counter statistic. The reviewer didn't run a separate check on each finding. Line numbers are approximate, because the tree hasn't been committed.

Most severe first within each section.

---

## Counter statistic (`COUNTER_STATISTIC_HLD.md`)

### C1. Erasing a counter day can't be undone
- **Where:** `lib/features/analytics/analytics_page.dart`, `_CounterDetailState._erase` and the "Erase this day" button (~5198)
- **Problem:** The erase has no confirmation. The comment and HLD §5.3 / §7.3 say the rows "go to the trash", but no trash entry type covers `counter_adjustments` (`trash_kinds.dart` registers only `trackers` for analytics). Tracker values never appear in the Trash either.
- **Failure:** A mis-click on the trash icon soft-deletes every device's rows for that day and syncs the deletions out. Nothing in the Trash dialog can restore them, and `purgeExpiredDeleted` later deletes them for good.
- **Fix (decision needed):** Either an undo toast through the existing `softDeleteWithUndo` (restore = re-upsert the erased rows with `deletedAt: null`, version + 1), or a confirmation dialog. Update the HLD and the code comment to match.

### C2. The statistics section counts derived points, not real changes
- **Where:** `analytics_page.dart`, `_DetailStatisticsSection._buildStats` (`case TrackerType.integer: case TrackerType.counter:`, ~4560); `_TrackerStatisticsDialog._buildStats` has the same problem.
- **Problem:** `counterSeriesValues` gives every period since creation a value, so "Entries logged", "Current streak" and "Longest streak" count graph points. Average, Highest and Lowest are taken over running totals.
- **Failure:** A daily counter created 200 days ago and tapped on 3 days shows "Entries logged: 200" and a 200-day streak.
- **Fix:** Special-case counters the way `kWordCountTrackerId` is special-cased: drop the count and streak rows, and keep Average, Highest and Lowest of the running total, or show statistics based on the real changes (days changed, total change).

### C3. Creating a counter can write under the placeholder device id
- **Where:** `analytics_page.dart`, `_createTracker` (~292)
- **Problem:** `ref.read(deviceIdProvider)` is passed to `createCounter` without the `kUnresolvedDeviceId` check that `counterStepProvider` does.
- **Failure:** Creating a counter with a starting value right after launch, before the device id has resolved, writes the starting value under the shared `'local-device'` id. That is the row sharing that per-device rows exist to prevent.
- **Fix:** Disable Create while the id is unresolved (watch `deviceIdProvider`), or skip the starting-value row in that case.

### C4. Duplicated date-string helpers
- **Where:** `lib/core/sync/firestore_document_mapper.dart`, `_counterDayToFirestore` / `_counterDayFromFirestore` (~2591)
- **Problem:** These re-implement the existing `yyyy-MM-dd` round trip (`calendarDateKey` / `parseCalendarDateKey`, or `reminderLocalDateToString` / `parseReminderLocalDate`).
- **Fix:** Use the existing helpers. Keep the wire format `yyyy-MM-dd`.

### C5. The detail calendar recomputes every running total from scratch
- **Where:** `analytics_page.dart`, `_CounterDetailState.build` (~5118)
- **Problem:** `counterTotalThrough(adjustments, day)` runs once per calendar cell (42) plus once for the stepper. Each call scans every row, so each rebuild costs O(43·N).
- **Fix:** Build one running sum over the sorted `counterDailyChanges` keys and look up each cell's total from it.

### C6. Minor notes (no fix required)
- **The card's "today" is computed at build time.** After midnight the current period updates on the next refresh, not exactly at midnight. A tap always uses the time of the tap, so no tap is miscounted.
- **Other devices must be on the new version.** Per HLD §8.1, every device has to be updated before anyone creates a counter; nothing in the app enforces this. Put it in the release notes.
- **Rows are uploaded before the transaction commits.** `createCounter` notifies `SyncedWriteNotifier` inside its transaction, so a rollback could still queue an upload of rows that were never saved. Unlikely in practice. `eraseCounterDay` already notifies after the commit.

---

## Folder backup (`FOLDER_BACKUP_HLD.md`)

### F1. "This was intentional" can be undone by a running backup
- **Where:** `lib/features/settings/services/folder_backup_service.dart`, `acceptDrop` (~657) vs. `_pipeline` (~749–797)
- **Problem:** `acceptDrop` clears the hold outside the run queue. A pipeline already running then saves `s['hold'] = hold`, the copy it read before the click, so the hold the user cleared is written back to `state.json`.
- **Failure:** Clicking "This was intentional" during a scheduled or Back-up-now run (the button stays enabled) leaves the source in Review. The queued `backUpNow` then sees an unchanged fingerprint, keeps `previousHold` and never prunes. The inbox alert stays until the user clicks again.
- **Fix:** Run `acceptDrop` through the run queue, or have `_pipeline` re-read the hold and `acceptedFrom` just before saving.

### F2. A pinned backup can be deleted during a cross-drive move
- **Where:** `folder_backup_service.dart`, `pin` / `unpin` / `deleteBackup` (~941–969) and `_finishMove` (~1127)
- **Problem:** Pin, unpin and delete aren't put in the run queue, so they can rename files in the middle of a move. `_finishMove` then deletes every file of ours in the old subfolder (`_ourFiles(from)`), including a pinned file that was never copied.
- **Failure:** During a slow move the user pins backup X after X was already copied as `slug_<stamp>.zip`. The rename creates `slug_pinned_<stamp>.zip` in the old folder, and `_finishMove` deletes it. At the new destination only the unpinned copy exists, so the next prune can delete the backup the user just pinned.
- **Fix:** Put pin, unpin and delete in the run queue, or disable those menu items while a move is in progress.

### F3. A destination inside another source's folder isn't rejected
- **Where:** `folder_backup_service.dart`, `checkPlacement` (~555)
- **Problem:** `checkPlacement` checks a new source's folder against other sources' folders, but not whether the destination lies inside another source's folder.
- **Failure:** Source A backs up `D:\Vault`; source B's destination is `D:\Vault\Backups`. Each of B's zips changes A's fingerprint, so A re-zips its whole folder, including B's archives, on every interval and storage keeps growing. When B's rotation prunes, A's file count and size drop, which falsely triggers A's "shrank" hold and notification.
- **Fix:** Also reject a destination equal to or inside any source folder (and a source folder inside any destination).

### F4. The status can stay on "Backing up…" after a run ends
- **Where:** `folder_backup_service.dart`, `refreshStatus` (~1265)
- **Problem:** Refreshes from the UI, from `_run` and from file actions overlap, and whichever finishes last sets `_status`.
- **Failure:** Settings opens while a run is active. Its refresh reads `_runningId == source.id`, then waits on slow I/O for another source's network destination. Meanwhile the run ends and its final refresh completes first. The slow refresh then overwrites `_status` with `backingUp`: "Back up now" stays disabled and the row keeps spinning until something else refreshes (`runDue` only refreshes when a source is due).
- **Fix:** Tag each refresh with a generation counter and drop results from older refreshes, or chain refreshes so they finish in order.

### F5. A refused destination change still saves the other edits
- **Where:** `lib/features/settings/folder_backup_source_dialog.dart` (~135)
- **Problem:** When editing with a new destination, `updateSource` saves the name, interval, threshold and on/off switch before `_changeDestination` runs `checkPlacement`.
- **Failure:** The user renames the source, turns it off and picks a destination that already holds the subfolder. The check throws and the dialog shows an error. The user clicks Cancel thinking nothing changed, but the rename and the disable were already written to `sources.json`.
- **Fix:** Run `checkPlacement` before saving anything, or save everything only once the destination change succeeds.

### F6. Copied date helpers
- **Where:** `folder_backup_service.dart`, `_dayKey` / `_parse` / `_ago`
- **Problem:** They are byte-for-byte copies of the private helpers in `auto_backup_service.dart`, so a fix to one copy won't reach the other.
- **Fix:** Make the auto-backup helpers public, or move them to a shared file, and use them from both.

---

## Unrelated test failures seen during the full run

These fail consistently. Neither touches the counter code, and I haven't checked them against a clean tree.

- `test/calendar_overlay_page_test.dart`, "reveal opens beside the revealed event, not the last one clicked": the popup lands at x=1008 instead of ~1188. There are uncommitted edits in `lib/features/shell/reveal_request.dart`.
- `test/finance_net_flow_view_test.dart`, "the placeholder is laid out while the view is still closing".
