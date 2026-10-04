# Counter Statistic — HLD

A new kind of statistic on the analytics page. Its value carries over from day to day, and you change it only with − and + buttons, never by typing a number. The analytics page shows it as a sparkline, and it keeps a day-by-day log of every change. Changes can be made on past days, and a change to a past day shifts every later day by the same amount.

Related: `lib/domain/models/analytics_models.dart` (`StatisticTracker`, `TrackerValue`, the derived "Streak" / "Word Count" series), `lib/features/analytics/analytics_page.dart` (`_SparklineRow`, `_StatisticDetailPopup`, `_TrackerDialog`), `lib/features/analytics/tracker_entry_row.dart`, `lib/features/notifications/notification_inbox_popover.dart`, `lib/core/sync/remote_sync_service.dart` (weekly re-anchoring), `lib/app/providers.dart` (`pendingStatEntriesProvider`, `deviceIdProvider`).

Status: **design**. Decisions locked 2026-10-03. Remaining questions are in §12.

---

## 1. Goals

- You can change a counter with one tap from the analytics card. Nothing has to open first.
- The current value is the sum of every change ever made, so a change on a past day shifts every later day.
- There is a log with one row per day, showing that day's net change, and you can erase any row.
- Two devices that tap the same counter on the same day while offline never lose each other's taps.
- The counter is drawn as a smooth sparkline, one point per cadence period.

## 2. Non-goals (v1)

- **Setting a value directly.** There's no "set this day to 7", on today or on a past day. Only − and +.
- **Limits.** There's no lower or upper limit, and the value can go negative.
- **Notes on changes.**
- **Converting a tracker.** An existing tracker can't become a counter, and a counter can't become another type. The type is fixed when the tracker is created, as it is for every tracker today.
- **Step size.** Every tap is ±1.
- **A separate entry for each tap.** The log is one net change per day. One tap and a hundred taps both make a single row.

---

## 3. Product decisions

| Topic | Decision |
|---|---|
| Changing past days | − and + only. Allowed on any past day, including days before the counter was created. Not allowed on future days. |
| Log | One row per day: the date and that day's net change (for example `+3`). It doesn't show when the taps happened or a running total. Days whose net change is 0 are hidden. |
| Undo | Erasing a row removes that day's change entirely and every later day shifts back. The erase itself isn't logged. |
| Starting value | Chosen in the create dialog (default 0). It's stored as a change on the creation day, so it appears in the log, merged with any other taps that day. |
| Cadence | Sets only the sparkline's resolution (one point per day, week, month or year). Changes are always stored per day. |
| Card | Shows the current value with − and + buttons. They change **today**. |
| Notification popover | The row reads `[−] value [+]`, where the value is the current total. Each tap is saved immediately. Counters never add to the pending badge. |
| Sparkline | Same smooth curve as the other line-style trackers. |
| Which day a tap counts for | The device's local day at the moment of the tap. |
| Day cells in the detail calendar | Show the day's net change and the running total. |

---

## 4. Data model

### 4.1 Tracker

Add `TrackerType.counter`. The `StatisticTracker` fields used are `name`, `cadence`, `colorValue`, `starred`, `sortOrder` and `showOnCalendar`. The integer, boolean and enum fields (`integerCap`, `defaultInt`, `defaultBool`, `enumOptions`, `defaultEnumOption`, `trackingStyle`) are ignored and left at their defaults.

`effectiveTrackingStyle` returns `TrackerStyle.consecutive` for a counter, so it sorts into the sparkline group on the grid (`analytics_page.dart:629`) without any change there.

### 4.2 Changes: a new table, one row per device per day

```
CounterAdjustment {
  id          String    '${trackerId}_${yyyy-MM-dd}_${deviceId}'
  trackerId   String
  day         DateTime  local midnight, stored the same way as TrackerValue.periodStart
  deviceId    String
  delta       int       this device's net change on this day
  createdAt, updatedAt, version, deletedAt     (SoftDeletable)
}
```

- **Day net change** = the sum of `delta` across the live rows for (tracker, day), which is one row per device.
- **Value on day D** = the sum of `delta` across the live rows with `day ≤ D`.
- **Current value** = the sum of every live row. No row can be dated in the future (§3).

**Why per device.** A row is mostly written by one device. Sync keeps whichever copy has the higher version (`remoteVersionWins`), so two devices that each wrote a single shared daily row while offline would overwrite each other's taps. With one row per device, each device only ever adds to its own row, and two devices' taps never land on the same row. Erasing a day keeps to this too (§5.3).

**Why not reuse `tracker_values`.** Everything that reads that table assumes at most one value per (tracker, period):
- the heatmap and sparkline indexes (`_TrackerValueIndex`)
- `pendingStatEntriesProvider`
- the weekly re-anchoring (`remote_sync_service.dart:5723`, `app_database.dart:4223`), which would move a weekly counter's daily rows onto Mondays and drop any that collided
- the popover's staged save

Several rows per day would quietly break each of these. A separate table keeps counters out of all of them. The cost is a new table, Firestore collection, mapper, outbox entry, backup collection and trash purge. All of these copy the `trackerValues` versions.

### 4.3 Schema

Add the drift table `counter_adjustments` and raise `schemaVersion` from 137 to 138. Index it on `(tracker_id, day)`. Add a Firestore collection `counterAdjustments` alongside `trackerValues` in `firestore_collections.dart`.

---

## 5. Writes

### 5.1 A tap

A tap on day `D` adds ±1 to this device's row for (tracker, D), in **one SQL statement**:

```sql
INSERT INTO counter_adjustments (id, tracker_id, day, device_id, delta, created_at, updated_at, version, deleted_at)
VALUES (?, ?, ?, ?, ?, ?, ?, 1, NULL)
ON CONFLICT(id) DO UPDATE SET
  delta      = CASE WHEN deleted_at IS NULL THEN delta + excluded.delta ELSE excluded.delta END,
  deleted_at = NULL,
  version    = version + 1,
  updated_at = excluded.updated_at;
```

- **Atomic.** Reading the row in Dart, adding to it and writing it back, as `tracker_entry_row.dart` does, would lose taps when they come faster than the round-trip. One SQL statement can't.
- **Reviving an erased row resets it.** If the row was erased, the next tap starts again from the tap's ±1 instead of bringing back the erased amount.
- After the write, the repository reads the row back and queues it for upload like any other record.

A day can end with a net change of 0, and its row stays in the table with `delta = 0` (it's harmless). The log hides it.

### 5.2 Creation

Saving a new counter with starting value `N ≠ 0` writes this device's row for the creation day with `delta = N`, in the same transaction as the tracker. If `N = 0`, no row is written.

### 5.3 Erasing a log row

Erasing day `D` adds the negation of D's net change, as this device sees it, to this device's own row for D, through the same single statement as a tap (§5.1). Other devices' rows are never written, so an erase can't collide with another device's unsynced taps. If the net change is already 0, nothing is written. An undo toast is offered, the same as other soft deletes (`softDeleteWithUndo`). The undo adds the erased amount back to this device's row, so any taps made since the erase still stand. Nothing appears in the Trash dialog.

### 5.4 Deleting the counter

This works the same as deleting any tracker today. The tracker is soft-deleted and its rows go with it. Restoring the tracker from the trash restores the rows that were deleted at the same moment, following how `_deleteTracker` handles values today.

---

## 6. Reading: the derived series

Counters reuse the sparkline, its hover popup and the detail charts by building a list of `TrackerValue`s from the change rows. The virtual "Streak" and "Word Count" trackers do the same (`streakTrackerValues`, `wordCountTrackerValues`).

```
counterSeriesValues(tracker, adjustments, today) -> List<TrackerValue>
```

- There is one value per cadence period, from the period containing `min(earliest row day, creation day)` through the period containing today. Every period gets a value, so the curve never interpolates across a gap.
- A period's value is the running total at its **last day**, or at today for the current period. Periods are anchored with the existing helpers (weekly periods start on Monday, `weeklyTrackerStorageAnchor`).
- The IDs are synthetic (`'${trackerId}:${period}'`) and are never written, the same as the derived trackers.

The sparkline's hover popup shows the period's running total and, beside it, the period's net change.

The sum is recomputed from all rows each time the provider rebuilds. A counter used every day for ten years has about 3,650 rows per device. That's trivial, so nothing is cached.

---

## 7. UI

### 7.1 Create / edit dialog (`_TrackerDialog`)

- Add **Counter** to the type picker. It's only available when creating a tracker. When editing, the type is fixed, as it is now.
- When Counter is selected, hide the limits, default value and tracking-style controls, and show a **Starting value** integer field (default 0, negatives allowed). It's only shown when creating, because after that the starting value is just the creation day's log row.
- The cadence label reads "Graph resolution" for counters. The option list stays the same.

### 7.2 Analytics card (`_SparklineRow`)

- The current value is shown in large text, with − on its left and + on its right. The buttons change **today** (§5.1).
- The buttons take the tap themselves, so tapping them doesn't open the detail popup or start dragging the card to reorder it. Tapping anywhere else on the card still opens the detail popup.
- On desktop, holding a button doesn't repeat. Each click is one step.
- The hover popup is read-only for counters (§6). It doesn't open the edit popup (`_HoverEditPopover`), because that sets values.

### 7.3 Detail popup (`_StatisticDetailPopup`)

- **Calendar**: a daily month calendar no matter what the cadence is, because changes are stored per day. Each day cell shows the net change (`+2`) and the running total. A selected day (today or any past day) gets − and + buttons, which is how past days are changed. Future days can't be selected.
- **History**: the log. It has one row per day with a non-zero net change, newest first, showing the date and the signed change. Each row has an erase action (§5.3). It doesn't ask for confirmation, because the erase offers an undo.
- The statistics section shows only Average, Highest and Lowest of the derived running totals (§6). Counts and streaks would count derived periods rather than changes, so they are left out.

### 7.4 Notification popover

- `TrackerEntryRow` gets a counter version laid out `[−] total [+]`. Each tap writes immediately (§5.1). It doesn't wait for the popover's staged `commit` / `_saveAll`, matching the card.
- Counters are listed whatever their cadence, because for a counter cadence only sets the graph's resolution. The popover's filter at `notification_inbox_popover.dart:2243` lets counters through in addition to daily trackers.
- `pendingStatEntriesProvider` skips counters.

---

## 8. Sync

- **Collection.** `counterAdjustments` is pulled, pushed and live-synced the same way as `trackerValues`: version comparison, the outbox, and the conflict quarantine. The mapper adds `deviceId`, `day` and `delta`.
- **Re-anchoring.** Counter rows are in their own table, so the weekly Monday re-anchoring never sees them. Add a test that a weekly counter's daily rows survive a pull and a migration unchanged.
- **Burst uploads.** Ten quick taps make ten local writes to one row. Before building, check whether the outbox collapses repeated writes to the same document ID into one pending upload (§10.3). If it doesn't, delay the counter's upload by about 1 s after the last tap.

### 8.1 Edge cases

| Case | Result |
|---|---|
| A and B both tap day D while offline | Two separate rows. Both survive and the day's net change is their sum. |
| B erases day D, and A has unsynced taps on D | B offsets only what it can see, in its own row. A's unsynced taps arrive later and day D shows only those. This is accepted: the erase removed everything B could see. |
| A device's ID changes (reinstall, cleared settings) | Its old rows stay valid. New taps go to a new row for the same day, and the sum is unaffected. |
| A device running an older app version | The mapper doesn't recognise `counter` and falls back to the local type or `integer` (`firestore_document_mapper.dart:2481`). That device shows an empty integer tracker, ignores the new collection, and if the tracker is edited there it would push `type: integer` back to every device. **Update every device before creating a counter.** The release notes need to say this, because nothing in the app enforces it. |
| A tap close to midnight, or the clock or time zone changes | The day is taken at the moment of the tap. A tap at 23:59:59 counts for that day even if the write lands after midnight. While the app stays open, the card's "today" rolls over with the existing day-change handling. |
| A change dated before the counter was created | Allowed. The series simply starts earlier (§6). |

---

## 9. Backup and import

Add `counterAdjustments` to `backup_collections.dart` so export, import and automatic backups include it. When importing an older backup that doesn't have the collection, counters come in with a starting value of 0 and no changes, which is correct because no older backup can contain a counter.

---

## 10. Implementation outline

### 10.1 Changes

1. `enums.dart`: add `TrackerType.counter`.
2. `analytics_models.dart`: add the `CounterAdjustment` model, `effectiveTrackingStyle` for counters, and `counterSeriesValues`.
3. `app_database.dart`: add the table and index, migrate schema 137 → 138, and run codegen.
4. `repositories.dart` / `drift_repositories.dart`: add `listAdjustments(trackerId)`, `adjust(trackerId, day, ±1)` (the single statement in §5.1), `eraseDay(trackerId, day, deviceId)`, and include the table in the trash purge and tracker delete/restore.
5. Sync: `firestore_collections.dart`, `firestore_document_mapper.dart`, `remote_sync_service.dart` (pull, push, live listener) and `outbox_sync_worker.dart`.
6. `providers.dart`: `counterAdjustmentsProvider(trackerId)` and the derived series provider, and make `pendingStatEntriesProvider` skip counters.
7. `analytics_page.dart`: dialog (§7.1), card (§7.2) and detail popup (§7.3).
8. `tracker_entry_row.dart` and `notification_inbox_popover.dart`: §7.4.
9. `backup_collections.dart`: §9.

### 10.2 Order

Build the model, table and repository with their tests first, then sync, then the UI. A counter can be fully tested before any widget exists.

### 10.3 Checks before building

- Whether the outbox collapses repeated writes to the same document ID (§8).
- Whether `_SparklineRow`'s tap and reorder-drag handlers let a child button keep its tap. That decides how much of §7.2 is new code.

---

## 11. Testing

- **Model**: `counterSeriesValues` for each cadence. Cover changes before creation, a period with no changes carrying the previous total forward, negative totals, and the current period ending today.
- **Repository**: a burst of concurrent `adjust` calls loses no taps. A tap on an erased row starts again from ±1. `eraseDay` brings the day to 0 through this device's row and leaves other devices' rows alone. A starting value of N writes the creation-day row, and 0 writes nothing.
- **Sync**: two devices tapping the same day while offline both survive the merge. Another device's erase and this device's offline tap both hold after a pull. A weekly counter's rows are never re-anchored. Import and export round-trip the collection.
- **Widgets**: the card's − and + change the total and don't open the detail popup. The popover row writes immediately and the pending badge stays the same. The log hides days with no net change and erasing a row updates the totals. Watch for the AppShell hang when dialogs close in desktop-variant tests: run them under the memory watchdog.

---

## 12. Open questions

1. **Changing past days through the detail calendar.** You asked for − and + on past days, but not where. This design puts them in the detail popup's daily calendar (§7.3) and makes the sparkline's hover popup read-only, because at weekly or monthly resolution a point on the sparkline doesn't identify a single day. Is that where you want them?
2. **"Show on calendar".** Nothing outside the tracker dialog seems to read `showOnCalendar` (`grep` finds it only in `analytics_page.dart` and the storage and sync code). This design applies "net change and running total" to the detail popup's calendar. If you meant the main calendar page, that's a separate feature that doesn't exist yet for any tracker.
