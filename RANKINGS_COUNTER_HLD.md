# Rankings — Repeat Counter HLD

A count of how many times you have had something: rewatched a show, eaten a dish, visited a restaurant. It is switched on per category, separately for entries and for units. Every entry and unit starts at 1. You raise the count with a `+` that shows when you hover over a row, or with a `− N +` stepper in the editor.

Related: `RANKINGS.md` (§3.3 rows, §3.4 panel, §3.5 children, §4 model, §5 scoring), `COUNTER_STATISTIC_HLD.md` (the per-device row design this copies), `lib/domain/models/ranking_models.dart`, `lib/core/sync/firestore_document_mapper.dart`, `lib/features/rankings/rankings_row.dart`, `rankings_child_list.dart`, `rankings_edit_panel.dart`, `rankings_manage_sheet.dart`.

Status: **implemented** (2026-10-10).

Changes from the design below, settled during the build and the review after it:

- **`adjustCount` returns the step it actually applied.** A move past the floor is cut short at 1 rather than refused outright, and the unit editor's Cancel takes back exactly what was applied, not what was asked for.
- **Only a tap that adds a repeat starts the entry.** Taking one back, or the unit editor's Cancel doing so, leaves a queued entry queued.
- **No tap before the device ID loads.** Until startup reads it, every device holds the same placeholder ID, so a row under it would have more than one writer. A tap in that window does nothing, the same as the counter statistic.
- **Cancel waits for taps still being saved** before it takes the dialog's taps back.
- **The repository's tap returns its row with `RETURNING`**, not a read after the write.
- **Editor-only on touch screens.** There is no hover, so the row's `+` never shows there, and the count is changed from the steppers.

---

## 1. Goals

- Count repeats of an **entry** (rewatching a show) and of a **unit** (ordering a dish again). Each has its own toggle on the category.
- One tap from the list: a `+` appears when you hover over a parent row or a unit row.
- Taps are never lost. That includes two devices tapping the same entry while both are offline, and a pull landing in the middle of a burst of taps.

## 2. Non-goals (v1)

- **Dates per occurrence.** There's no "last eaten on" and no history. The count is a number, not a log. `RANKINGS.md` §4.2 already rules out an `experiencedOn` date.
- **Sorting or filtering by count.** This is the obvious follow-up. It isn't needed for the count to be useful.
- **Weighting.** *Average from children* stays a plain mean of the units' scores. A dish you ordered five times counts once, because a score is about quality, not how often you order it.
- **A custom label** ("Rewatches", "Times ordered"). Every surface reads `×N` or "Count".
- **Typing a number.** Only − and +, the same as the counter statistic.

---

## 3. Product decisions

| Topic | Decision |
|---|---|
| Toggles | `parentCountEnabled` and `childCountEnabled` on `RankingCategory`. Both default to off. The unit toggle is only offered, and only takes effect, while child units are enabled. |
| Starting value | 1. Creating an entry means you've had it once. Nothing is stored until the first tap. |
| Row display | `×N` in the category accent, shown only when N ≥ 2, so most rows look the same as before. |
| Quick + | Shown on hover over a parent row or unit row while its toggle is on and the category isn't archived. Touch screens have no hover, so there the count is changed only from the editor. Its width is reserved even when hidden, so hovering never shifts the score column. One tap adds 1. |
| Editor | A `Count  − N +` row in the entry panel, below the tags, and in the unit editor, below the overall score. − is disabled at 1. |
| Floor | The count never goes below 1. − is refused at 1, so it never writes. Two offline devices each taking the last repeat off could leave the stored sum below 1. The display then clamps to 1, and the next + makes up the shortfall as well, so the count shown goes from 1 to 2. |
| Status | Adding a repeat to an entry or any of its units moves a queued entry to in progress, the same as other edits. Taking one back doesn't. You only rewatch or reorder something you've started. |
| `updatedAt` | A tap **doesn't** touch the entry or unit row. The count lives in its own rows (§4), so the entry's field-by-field merge never sees it. This means "Last updated" doesn't move on a tap. |
| Unit editor Cancel | Takes back the taps made in that dialog, the same way Cancel takes back the rest of the dialog's edits. It does this by tapping the other way, not by restoring a snapshot, so taps made elsewhere in the meantime stay. |
| Toggle off | Hides the badge, the + and the stepper. Stored counts are kept, so switching it back on restores them. |
| Delete / undo | Count rows aren't touched by deleting an entry or unit, so an undo or a trash restore brings the count back with it. |
| Archived category | The badge stays. The + and the stepper are hidden or disabled. |

---

## 4. Data model

### 4.1 Why not a field on the entry

Ranking rows merge field by field using wall-clock stamps (`RankingFieldStamps`), and the upload is a blind `set()` of the whole document. A `count` field on the entry would lose taps in two ways:

1. Device A and device B each tap once while offline, starting from 3. Each holds 4, and the merge keeps one of them. The result is 4 where it should be 5.
2. A device that hasn't pulled yet uploads its whole document, and its `set()` overwrites whatever count another device last uploaded.

Splitting the count into per-device slots *inside* the document fixes (1) but not (2). The slots still travel inside a document that someone else's blind `set()` replaces.

### 4.2 One row per device per entry

The same shape as `counter_adjustments` (`COUNTER_STATISTIC_HLD.md` §4.2), without the day:

```
RankingCount (table ranking_counts_table, collection ranking_counts)
  id         String   '${entryId}_${deviceId}'
  entryId    String   a RankingParent id or a RankingChild id (both UUIDs, so one column holds either)
  deviceId   String
  delta      int      this device's net change to the count; can be negative
  createdAt / updatedAt / version / deletedAt
  index idx_ranking_counts_entry (entry_id), for the floor check's one-entry sum
```

- **Count** = `max(1, 1 + Σ delta)` over the live rows for the entry.
- **One writer per row.** A device only ever writes its own row, so a blind `set()` of that document can't touch another device's taps. This fixes failure (2).
- Rows are never soft-deleted in v1. `deletedAt` exists only because every synced record carries it.

### 4.3 Writes

**A tap** is one SQL statement, like `adjustCounter`:

```sql
INSERT INTO ranking_counts_table (id, entry_id, device_id, delta, created_at, updated_at, version)
VALUES (?, ?, ?, ±1, now, now, 1)
ON CONFLICT (id) DO UPDATE SET delta = delta + excluded.delta,
                               version = version + 1,
                               updated_at = excluded.updated_at
```

Taps faster than a round trip can't each read the same `delta` and overwrite each other. The action that wraps the tap runs on the entry's write queue (`_serialized('count:<entryId>')`). This lets the floor check (§3) read the sum and write in order, so two quick − taps at 2 can't both pass.

**A pull or a restore** writes only if it is newer:

```sql
INSERT ... ON CONFLICT (id) DO UPDATE SET ... WHERE excluded.version > version
```

A device's own row comes back to it as an echo or in a full pull. Without this guard, a pull that read the row at version 5, then lost a race with a tap that wrote version 6, would write version 5 back and drop the tap. Because each row has one writer, a higher version is always newer content, and an equal version is always the same content.

### 4.4 Category fields

`RankingCategory` gains `parentCountEnabled` and `childCountEnabled` (bool columns, default false; Firestore fields with the same names), plus a getter `showsChildCount => childCountEnabled && childUnitsEnabled`, the same pattern as `showsProgress`.

---

## 5. Sync

- **Collection** `ranking_counts`, registered everywhere `counter_adjustments` is: `FirestoreCollections` (constant and the full list), the pull switch, `pullSecondaryData` (after `pullRankingChildren`), the watched collections, `_recordDocument`, the outbox re-read, and the backup collections.
- **Merge** is `mergeRankingCountFromRemote`, version-wins (`_remoteRecordWins`), the same as `mergeCounterAdjustmentFromRemote`. The repository's version guard (§4.3) backs it up at the write.
- **Upload** is debounced by a second per row, through the same path as `pushCounterAdjustments`. A burst of ten taps is one write to the server.
- **Older builds** don't know the collection and ignore it. They also don't write the two category fields, so if a category is edited on an old build, a device installed fresh later reads them as off. A device that already has them keeps its local value. **Update every device before turning counts on.**

## 6. UI

### 6.1 Parent row (`rankings_row.dart`)

The slot goes right before the quick-rate score: `×N` (only when N ≥ 2), then the hover `+`. The row reads its own total with `ref.watch(rankingCountsProvider.select(...))`, so a tap rebuilds only that row. The `+` consumes its tap, so it never opens the panel.

### 6.2 Unit row (`rankings_child_list.dart`)

The same slot, right before the score number.

### 6.3 Entry panel and unit editor

The stepper row is labelled **Count**, with `−`, the number and `+`. In the unit editor, Cancel takes back that dialog's net taps (§3).

### 6.4 Manage sheet

- **Count repeats**: "How many times you have watched, visited or had an entry." Always shown.
- **Count repeats of {unit}s**: shown under the child units block, next to **Track progress**.

## 7. Edge cases

| Case | Behaviour |
|---|---|
| Two devices tap the same entry while offline | Each taps its own row. Both survive. |
| A pull lands in the middle of a burst of taps | The version guard keeps the newer local row. No tap is lost. |
| A device's ID changes (reinstall, cleared settings) | Its old row stays and still counts. New taps go to a new row. |
| An entry is erased permanently from Trash | Its count rows stay as orphans. A few bytes each. They are still summed into the totals map and backed up, but nothing shows them. |
| Toggle turned on for a category with history | Every entry reads 1. Nothing to migrate. |
| A backup is restored over newer data | The version guard keeps the newer rows, so a restore can't lower a count. |

## 8. Implementation steps

1. `ranking_models.dart`: add the `RankingCount` model, `rankingCountId`, `rankingCountTotal`, and the category fields, `copyWith` and `showsChildCount`.
2. `app_database.dart`: add `RankingCountsTable`, the two category columns, and schema 143 (create the table and index, add the columns).
3. `repositories.dart` / `drift_repositories.dart`: add `sumCountsByEntry`, `getCount`, `getAllCounts`, `upsertCount` (version-guarded) and `adjustCount` (one statement), and map the category fields.
4. Mapper: category fields, `rankingCountToFirestore`, `mergeRankingCountFromRemote`.
5. Sync registration (§5) and backup.
6. `providers.dart`: add `rankingCountsProvider` (entry id → Σ delta) to `_rankingDataProviders`.
7. `rankings_actions.dart`: `adjustCount(entryId, parentId, delta)` with the floor, the write queue, the debounced push and `markInProgress`.
8. UI: the count slot on both rows, the steppers, Cancel in the unit editor, and the toggles.

## 9. Tests

- **Repository**: a burst of concurrent taps loses none. An older or equal-version upsert doesn't lower a row, and a newer one applies. The sum groups by entry and skips deleted rows.
- **Actions**: − at 1 writes nothing. Two quick − taps at 2 end at 1. A tap moves a queued entry to in progress, and it does this for a unit too; taking one back doesn't. Nothing is written while the device ID is the placeholder.
- **Sync**: two devices' rows both survive a merge. The mapper round-trips. The category fields round-trip, and a payload without them keeps the local values. Import and export round-trip the collection.
- **Migration**: a schema-142 database upgrades with the table and columns.
