# Folder Backups — HLD

Voyager can back up any folder on the device, such as an Obsidian vault, on a schedule the user picks. Each run copies the folder into a verified ZIP in a destination the user chooses, and keeps the same age-tiered set as Voyager's own automatic backups: the last three days, one about a week old and one about a month old. If the folder shrinks sharply, Voyager warns the user and stops deleting old backups until they confirm the shrink was intended. It does the same when a backup can't be made or verified.

Related: `AUTO_BACKUP_HLD.md` (the design this one reuses), `lib/features/settings/services/auto_backup_retention.dart`, `lib/features/settings/services/auto_backup_service.dart`, `lib/features/notifications/notification_inbox_popover.dart`, `lib/core/reminders/reminder_os_notifier.dart`.

Status: **implemented** (`folder_backup_service.dart`, `folder_backup_archive.dart`, `folder_backup_retention.dart`, `streaming_zip.dart`, `folder_backup_section.dart` and its two dialogs, `windows_folder_picker.dart`). Decisions locked 2026-10-03; spike outcomes in §10.3; remaining questions in §12.

---

## 1. Goals

- Back up any number of user-chosen folders without the user doing anything after setup.
- Keep one backup per day for each of the last **3 days that changed**, plus backups aged **~1 week** and **~1 month**. The rotation is identical to Voyager's (`AUTO_BACKUP_HLD.md` §5).
- Every retained backup has been proven to hold exactly the files that were read, byte for byte, before any older backup is deleted.
- Make it obvious when the folder has lost a lot of content, and make sure the rotation can't push the good copies out while the user hasn't seen the warning.
- Make it obvious when backups aren't happening or a backup is bad.

## 2. Non-goals (v1)

- **Android.** Reading an arbitrary folder there needs the Storage Access Framework or the all-files-access permission. The feature is Windows only. The Settings section is hidden elsewhere.
- **Syncing.** Sources, settings and status are device-local. Nothing goes to Firestore or into Voyager's own export. A source is a path on this machine, and on another device that path means nothing.
- **Configurable retention.** It's fixed at Voyager's rule. There's a size warning instead (§9.4).
- **Restoring in place.** Restore means extracting to a new folder (§7). Voyager never writes into a source folder.
- **Incremental or deduplicated backups, and encryption.** The reasoning is the same as `AUTO_BACKUP_HLD.md` §2 and §8.3.
- **Editable excludes.** The defaults in §4 are fixed.

---

## 3. What this protects against

| Threat | Example | What saves you |
|---|---|---|
| A sync tool or plugin wipes or clobbers the folder | Obsidian Sync or a Git plugin replaces the vault with an old or empty copy | Size-drop alert and pruning hold (§8), then yesterday's backup |
| The user deletes or overwrites by mistake | Deleted a folder of notes | The most recent backup before it |
| Damage noticed late | A note emptied weeks ago | Weekly or monthly backup |
| The source disk fails | SSD dies | A backup on a **different** drive (§9.4 warns when the destination shares a drive with the source) |

The second threat is the main reason for the size-drop alert. A daily rotation that keeps backing up a wiped folder replaces every good daily within three runs, and the weekly and monthly ones within weeks.

---

## 4. Product decisions

| Decision | Choice |
|---|---|
| **Platforms** | Windows only. |
| **Sources** | Any number. Each has a name, a source folder, a destination folder, an interval, a size-drop threshold and an on/off toggle. |
| **Source folder** | Fixed when the source is created. A different folder means a new source, which starts its own rotation and its own size history. |
| **Destination** | Can be changed. Voyager moves the existing backups to the new destination, and the rotation and size history carry on (§9.5). |
| **Removing a source** | Its backups are always kept. They become **retired backups**: still listed, still counted toward storage, and deleted only when the user asks (§9.6). |
| **Interval** | Presets of 1h, 3h, 6h, 12h, 1 day (default), 2 days, 3 days and 7 days. Below 1 hour a large folder could spend most of its time zipping. Above 7 days the weekly tier stops meaning anything. |
| **Unchanged folder** | No backup is written. The rotation holds distinct states (§5). |
| **Excludes** | Fixed: `.obsidian/workspace.json`, `.obsidian/workspace-mobile.json`, `.trash/`, `.git/`. Hidden files are otherwise included, since `.obsidian/` config is worth keeping. Symlinks and junctions are not followed. |
| **A file can't be read** | The whole run fails (§6.2). A backup that silently lacks a file is false reassurance. |
| **Retention** | Voyager's rule, applied to the newest backup of each local day (§5). |
| **Size drop** | Default **20%**, editable per source from 5% to 90%. Total bytes and file count are each checked against the last backup and the weekly backup (§8). |
| **On a size drop** | The backup is still taken, but **nothing is deleted** until the user acknowledges it. Settings, the Inbox and an OS notification all show it. |
| **Pinning** | Any backup can be pinned. Pinned backups are outside the rotation and are never deleted automatically. |
| **Restore** | **Extract to folder…** into an empty folder the user picks. |

---

## 5. Retention

The rule is `backupsToKeep` from `auto_backup_retention.dart`, **unchanged**, fed the newest backup of each local calendar day:

```
keep = backupsToKeep(newestPerLocalDay(rotation), todayLocal)
```

- **Daily interval:** each day has at most one backup, so this is exactly Voyager's behaviour: 5–7 files, with the week slot aged 7–13 days and the month slot aged 30–51.
- **Sub-daily interval:** a later backup of the same day replaces the earlier ones. The three dailies stay three *days* apart instead of collapsing into the last few hours. Today's newest is always kept, since it's the newest of its day.
- **Unchanged folder:** no file is written (§6.1), so the dailies are the newest of the three most recent days the folder *changed*. Nothing pushes a distinct state out while the folder sits idle.

What the rule doesn't touch:

- **Future-dated backups** (the clock went backwards). These are handled the same way as `AUTO_BACKUP_HLD.md` §5.3.
- **Pinned backups.** They have their own file-name pattern (§6.4), so the rotation never sees them.
- **Anything during a pruning hold** (§8.3). The rule isn't run at all.
- **Anything whose name isn't exactly ours.** The destination subfolder may hold the user's own files, and those are never touched.

Retention is still a pure function of the directory and today's date. It survives gaps, crashes, files deleted by hand and a destination drive that was away for a week.

---

## 6. Taking a backup

### 6.1 When

- **Check tick:** 30 s after startup, then every **15 minutes** while the app runs. A tick is coarser than the shortest interval (1h) would allow, but fine enough that a 1h interval doesn't drift by most of an hour.
- **Due:** a source is due when it's on and `now − lastCheckedAt ≥ interval`. `lastCheckedAt` is the end of the last *successful* check, whether or not that check wrote a file. A failed run is retried on the next tick after it.
- **One at a time:** sources are run in turn, never in parallel, so two large folders don't fight over the disk. Voyager's own backup is a separate service and can overlap. It's ~8 MB, so that's fine.
- **Change check:** before zipping, Voyager walks the folder and builds a **fingerprint**: a SHA-256 over the sorted list of `(relative path, size, last-modified)` for every included file. If it matches the fingerprint in the newest backup's manifest, the run stops there. It records a successful check ("unchanged") and writes nothing. Reading metadata only keeps an idle hourly check cheap on a large vault.
- **Back up now:** a button in Settings that runs the check immediately, ignoring the interval. It still skips if nothing changed.

### 6.2 Pipeline

```
preflight ─► walk + fingerprint ─► [unchanged? stop] ─► size check ─► space ─► write .partial ─► verify ─► rename ─► re-check retained ─► prune ─► record
    │                                                                    │           │             │         │              │             │
    └─ fail ─────────────────────────────────────────────────────────────┴───────────┴─────────────┴─────────┴──────────────┴─────────────┴─► delete .partial, record failure
```

1. **Preflight.** The source exists, is a folder and is readable. The destination drive and folder exist. The source isn't inside the destination subfolder, and the destination isn't inside the source (rechecked each run, because junctions can change). Each failure has its own reason: "Folder not found", "Destination not found", and so on.
2. **Walk.** List every file, applying the §4 excludes, without following links. Total the bytes and count the files. **An empty folder (0 included files) fails the run** with "Folder is empty" and is never backed up. An unplugged drive, a renamed vault and a cloud folder that hasn't downloaded yet all look like this, and none of them may enter the rotation.
3. **Fingerprint.** Compare it with the newest backup's manifest. If they match, record "unchanged" and stop.
4. **Size check** (§8). If it trips, the run continues, but this run and every later one skip pruning until the user acknowledges.
5. **Space.** Free space at the destination must be at least 2× the newest backup's size. For the first backup, it must be at least 1.1× the walked bytes. Old backups are never deleted to make room.
6. **Write** `<slug>_<stamp>.zip.partial`, streaming each file into the archive and hashing the bytes as they're read. A file whose size or modified time changed between the walk and the read is re-read once. If it's still changing, or can't be opened (locked, access denied, path too long), **the run fails** and names the file, e.g. "Couldn't read Daily/2026-10-03.md: in use". Obsidian rewrites files in place, so a single retry clears a save that was in progress. Something actually stuck fails, and the next tick tries again. The manifest (§6.3) is written last.
7. **Verify from disk.** Re-open the file, decode every entry, and check each entry's SHA-256 and the entry count against the manifest. This runs in a background isolate. Streaming matters here: `verifyBackupFile`'s `readAsBytes()` would load a multi-gigabyte vault into memory, so this path never uses it.
8. **Rename** to `.zip`. As in `AUTO_BACKUP_HLD.md` §6.2 step 5, an existing target fails the run rather than being replaced.
9. **Re-check the retained rotation** before pruning, **at most once per local day per source**. It runs on the day's first successful check, whether or not that check wrote a file, so an idle folder's backups are still checked for bit rot. Later runs that day prune using that day's results. A file that was found damaged has already been renamed out of the rotation. The re-check has the same four outcomes as `AUTO_BACKUP_HLD.md` §6.2 step 6. A **damaged** backup is renamed to `.damaged`. An **unsupported** manifest version is renamed to `.unsupported`. One that's **unreadable right now** is left alone and out of pruning. A **verified** one stays. Pinned backups are re-checked the same way: damage to a pinned backup is still damage.
10. **Prune** (§5), unless a hold is active (§8.3).
11. **Record** the outcome in the source's `state.json` (§10.1), written through a temp file and rename and serialised, as in Voyager.

On startup, leftover `.partial` files matching our name pattern are deleted from every reachable destination subfolder.

**Performance.** Walking, zipping, verifying and re-checking all run off the UI isolate. Re-checking means reading roughly 7× the archive size and is the expensive part on a large folder. The once-a-day cap keeps that cost the same at any interval. A new backup is always verified itself (step 7), whatever the interval.

### 6.3 Archive format

A normal ZIP that any tool can open. Entries are stored under their path relative to the source folder, with forward slashes. One extra entry at the root, `.voyager-folder-backup.json`, holds:

```json
{
  "formatVersion": 1,
  "sourceId": "…", "sourceName": "Obsidian", "sourcePath": "C:\\Users\\Juno\\Vault",
  "capturedAt": "2026-10-03T14:02:11Z",
  "fileCount": 1834, "totalBytes": 412093551,
  "fingerprint": "sha256…",
  "files": { "Daily/2026-10-03.md": { "size": 2210, "modified": "…", "sha256": "…" }, … }
}
```

The size check and the list's "1,834 files · 393 MB" both read this file alone, through the ZIP's central directory, as `readBackupManifest` already does. A user file with the same name is unlikely. If one exists, the run fails and names it rather than overwriting it.

### 6.4 Names and layout

```
<destination>/
  Obsidian_3f9a2c1b/                         ← per-source subfolder: <slug>_<first 8 of id>
    Obsidian_2026-10-03_14-02-11-0400.zip     ← in the rotation
    Obsidian_pinned_2026-09-01_09-00-00-0400.zip
    Obsidian_2026-09-12_08-00-00-0400.zip.damaged
```

- The slug comes from the source's name at creation and is stored with the source, so renaming the source doesn't orphan its files. The stamp is Voyager's `backupTimestamp`.
- The file name carries the source name so a ZIP still says what it is after being copied somewhere else.
- **Pinning renames** the file to the `_pinned_` pattern, and unpinning renames it back. Whether a backup is pinned is therefore part of the directory, like everything else retention reads. If `state.json` is lost, pins survive. If the user unpins a file, the next prune may delete it, and the unpin dialog says so.

---

## 7. Restoring

**Extract to folder…** on any backup in the list:

1. Pick a folder. It must be empty, or a new one Voyager creates (`Obsidian restored 2026-10-03`). It must not be inside the source or the destination subfolder.
2. Verify the backup (§6.2 step 7). If it fails, nothing is written.
3. Extract every entry, checking each one's hash as it's written. Member names are untrusted: an absolute path, a drive letter or a `..` component fails the extract before anything is written (zip-slip).
4. Open the folder in Explorer when it finishes.

The user moves files back into the vault themselves. That keeps Voyager out of a folder Obsidian has open, and means a wrong restore can't destroy anything.

The list also offers **Show in folder** and **Delete…** (confirmed). Deleting a rotation file is safe: retention fills the gap from what's left.

---

## 8. Size-drop alert

### 8.1 What is compared

Two numbers from the walk, **total bytes** and **file count**, are compared against two references:

- the **last backup**: the newest backup in the rotation; and
- the **weekly backup**: the youngest backup aged ≥ 7 days, the tier holder from §5.

A drop of more than the threshold in **either** number against **either** reference trips the alert. File count matters because attachments dominate a vault's bytes: losing 40% of the notes can be a 2% byte drop. The weekly comparison catches slow losses that never trip the day-to-day check.

References come from manifests (§6.3), not from ZIP sizes, so compression doesn't skew them. With no reference available (the first backup, or no backup a week old yet), that comparison is skipped.

### 8.2 Accepted baseline

Once the user acknowledges a drop, the weekly comparison would otherwise trip again on every run for the next week. So acknowledging stores `acceptedFrom` = the capture time of the backup that tripped it, and **references older than `acceptedFrom` are ignored**. The baseline moves forward to the state the user accepted, and the weekly comparison resumes once a backup taken after it is a week old.

### 8.3 Pruning hold

When the alert trips:

- The new backup is written and verified as usual. It's a real state, and the user may want it.
- `state.json` records `hold: { since, captured, reason }`, e.g. "File count fell 38% since the last backup (1,834 → 1,137)". **No prune runs for this source** while the hold is set. Backups keep accumulating at the interval.
- The Settings row turns **Review** (§9.3). An Inbox row and an OS notification are posted once per hold, not once per run.

The hold has two outcomes, both on the Inbox row and on the source's backup list:

- **"This was intentional"** sets `acceptedFrom`, clears the hold, and runs a check immediately, which prunes.
- **"Show backups"** opens the list so the user can extract or pin a pre-drop backup. The hold stays until the user acknowledges it.

A further drop during a hold updates the reason but doesn't post again. The hold is the only thing in this feature that lets disk use grow without bound, so the Settings row shows the growing count and size (§9.2).

### 8.4 Damaged and failed backups

The user asked to be warned about a bad backup. Here's how each case maps to an alert:

| Event | Settings | Inbox | OS notification |
|---|---|---|---|
| Size drop | Review | Immediately | Immediately |
| The new backup failed verification, or a retained one was set aside as damaged | Attention | Immediately | — |
| An operational failure: folder or destination missing, a locked file, no space | Attention | When the source has had no successful check for **max(2 × interval, 24 h)** | — |

Verification failures are rare and mean something is wrong with the disk or the code, so they surface at once. Operational failures are often transient, like a laptop away from its backup drive, so they wait out a grace period, like Voyager's two-day rule.

---

## 9. Settings UI

### 9.1 Section

**Settings → Backup & Restore → Folder backups**, below Voyager's automatic backups. It's Windows only. It shows one row per source and an **Add folder…** button.

### 9.2 Source row

```
┌────────────────────────────────────────────────────────────┐
│ 📁 Obsidian · 6 backups + 1 pinned · 2.4 GB      ● Healthy  │
│    Last checked 14:02, unchanged since yesterday 23:00   ›  │
└────────────────────────────────────────────────────────────┘
```

Tapping the row opens the source's backup list. The list has: age labels as in Voyager ("Yesterday", "Weekly · 9 days ago", "Pinned · 1 Sep"); size; file count from the manifest; and Pin/Unpin, Extract to folder…, Show in folder and Delete… for each backup. Its header has **Back up now**, **Edit…** and the on/off switch.

### 9.3 Health states

Evaluated in order; the first match wins:

| State | When | Second line |
|---|---|---|
| **Backing up…** | This source is running | "Backing up 1,834 files" |
| **Review** (red) | A size-drop hold is active | The hold's reason |
| **Off** | Toggle off | "Folder backups are off · last backup 3 days ago" |
| **Attention** (amber) | The last check failed, a backup was damaged or couldn't be re-checked, or the source is overdue by more than one interval | The recorded reason |
| **Not yet backed up** | No check has succeeded yet | "First backup runs shortly" |
| **Healthy** (green) | The last check succeeded within the interval and every retained file passed its last re-check | "Last checked 14:02, unchanged since yesterday 23:00" or "Last backup 14:02, verified" |

Health keys off `lastCheckedAt`, not the newest file's age, because an unchanged folder legitimately has old newest files.

**Turning a source off** stops checks and pruning. The files stay listed. **Removing a source** retires its backups (§9.6). It never deletes them.

### 9.4 Add and edit dialog

- **Add:** pick the folder (`file_picker`'s directory picker), then the name (defaults to the folder's name), the destination, the interval (default 1 day) and the threshold (default 20%).
- **Edit:** the name, destination, interval, threshold and toggle can change. The source folder is shown but fixed (§4). A new destination starts a move (§9.5).
- **Size warning:** after the folder is picked, a background walk shows *"About 393 MB · a full rotation takes about 2.8 GB (7 × the folder)"*. It turns amber when that's more than half of the destination's free space. The Settings row shows the same warning later if the rotation and pins grow past half the free space, which is how a long hold surfaces.
- **Same drive:** if the destination is on the source's drive, the dialog shows a hint: "This won't protect against that drive failing."
- **Refused at save:** the destination is inside the source, or the source is inside the destination. The source overlaps an existing source's source. The destination subfolder already exists, which covers one belonging to another source or a retired one.

### 9.5 Moving the destination

The move carries over every file in the source's subfolder that has one of our names: rotation, pinned, `.damaged` and `.unsupported` files. Moving the files, rather than starting over, keeps the size-drop references (§8.1) and the weekly and monthly tiers intact. While a move runs, the source doesn't back up and its row shows **Moving backups…** with a progress count.

1. **Check** that the old subfolder and the new destination are both reachable. The new destination must pass §9.4's checks. There must be free space for the subfolder's total size.
2. **Same drive:** rename the subfolder into the new destination. That's one atomic step, and the move is done.
3. **Different drive:**
   1. Copy each file into `<new destination>/<slug>_<id8>.moving/`.
   2. Check each copy's size and SHA-256 against the original.
   3. When every file matches, rename `.moving` to `<slug>_<id8>`.
   4. Point the source at the new destination in `sources.json`.
   5. Delete the originals (our names only), then the old subfolder if it's empty.
4. **Recovering from a crash**, using `state.json`'s `move` record:
   - Interrupted **before the switch**: the `.moving` folder is deleted on startup, and the source still points at the intact old subfolder.
   - Interrupted **after the switch**: the remaining originals are deleted on startup.

   Nothing exists in only one place at any point.

**Old destination unreachable.** If the old drive has died or isn't plugged in, the move is refused with "Connect <old path> to move its backups". The dialog then offers **Change without moving**. That points the source at the new destination with an empty rotation and retires the old subfolder (§9.6). Retiring keeps it listed and counted, and its backups can be extracted once the drive is back. The size history restarts, since its references are on the old drive.

### 9.6 Retired backups

A removed source and a destination left behind by **Change without moving** both become retired backups. Voyager stops managing them but keeps track of them:

- They're listed under the sources as **"Obsidian (removed) · 7 backups · 2.4 GB"**, with the path and the date they were retired.
- Their size counts toward the section's total storage. It's read from a directory listing whenever the drive is reachable. Otherwise the row shows the last known size and "drive not connected".
- Their list opens read-only: **Extract to folder…**, **Show in folder** and **Delete…** for each backup, plus **Delete all…** in the header. There's no pinning, backing up or pruning.
- Nothing is re-checked and nothing posts alerts. They're kept as they were left.
- Deleting removes only files with our names, then the subfolder if it's empty. Once nothing of ours is left, the entry disappears.

---

## 10. Implementation outline

### 10.1 Storage

| What | Where |
|---|---|
| Source registry | `<app support>/folder_backups/sources.json`: for each source, its id, name, slug, source path, destination, interval, threshold and enabled flag. For each retired entry (§9.6), its name, subfolder path, retired-at time and last known size. |
| Per-source status | `<app support>/folder_backups/<id>/state.json`: lastCheckedAt, last outcome and reason, first failure time, lastRecheckAt and its results, hold, acceptedFrom, and any move in progress (§9.5) |
| Backups | `<destination>/<slug>_<id8>/` (§6.4) |

State lives in app support, not in the destination, so a missing drive can still be reported. Neither file syncs, and neither is in `AppSettings` or Voyager's export.

### 10.2 Changes

| Area | Change |
|---|---|
| `auto_backup_retention.dart` | Expose a `backupNamePattern(prefix)` built from the private `_stamp`, so folder backups can match their own names. No behaviour change. |
| New `folder_backup_retention.dart` | `newestPerLocalDay`, the rotation and pinned name patterns, and `toKeep` = `backupsToKeep(newestPerLocalDay(…))`. |
| New `folder_backup_archive.dart` | Isolate entry points: walk and fingerprint, streaming write with per-entry hashing and the manifest, streaming verify, extract with the zip-slip guard, and manifest-only read. |
| New `folder_backup_service.dart` | The registry, the 15-minute tick, one-at-a-time runs, the pipeline (§6.2), size check and hold (§8), destination moves and their crash recovery (§9.5), retired entries (§9.6), state files and health (§9.3). A `ChangeNotifier` like `AutoBackupService`. |
| `providers.dart`, `voyager_app.dart` | Provider. Started on Windows only, after `autoBackupServiceProvider`. |
| `settings_page.dart` + new `folder_backup_source_dialog.dart`, `folder_backup_list_dialog.dart` | §9. |
| `notification_inbox_popover.dart` | One row per source in Review or failing (§8.4), with actions. |
| OS notification | Shown through the existing `flutter_local_notifications` setup in `reminder_os_notifier.dart`. Clicking it opens the Settings section. |

`AutoBackupService` itself is not changed.

### 10.3 Spikes before building

1. **Archive limits.** Confirm `archive` 3.6's `ZipFileEncoder` writes Zip64, for archives over 4 GB or more than 65,535 entries, and that its decoder reads it back. If it doesn't, cap a source at those limits with a clear failure, or change libraries.
2. **Streaming verify memory.** Confirm that decoding an entry via `InputFileStream` doesn't hold the whole entry in memory. Test a folder containing a single 1 GB video. If it does, hash entries with a streaming inflater instead.
3. **Long paths.** Confirm `dart:io` reads paths over 260 characters on this machine. If it can't, they're an ordinary "couldn't read" failure that names the file.

**Outcomes (2026-10-03).**

1. `archive` 3.6 writes and reads Zip64, but spike 2 failed: `ZipEncoder` deflates each entry as one buffer, and reading an entry inflates it whole. Folder backups therefore use their own `streaming_zip.dart`, a Zip64 writer and reader over dart:io's raw zlib, a megabyte at a time. Writing and then verifying a 1 GB entry raised peak memory by about 46 MB. An archive with 70,007 entries, a 4.5 GB entry and offsets past 4 GB reads back correctly, and Python's `zipfile.testzip()` accepts it. Voyager's own export still uses `archive`.
2. Opening and reading a long path works, but listing a directory past 260 characters fails. The walk, the write and the extract therefore go through the `\\?\` form, and long paths back up and restore like any other.
3. `file_picker`'s directory picker crashes the app on Windows (see the Export Backup tile), so both pickers are `windows_folder_picker.dart`: the same IFileOpenDialog, on an isolate with its own COM apartment.

---

## 11. Testing

- **Retention:** run the 500-day simulation from `AUTO_BACKUP_HLD.md` §11 with intervals of 1h, 6h, 1 day and 7 days, and with "unchanged" days mixed in. Under a daily interval it must give the same results as Voyager's. Dailies must always be on distinct days. Pinned, future-dated and foreign files must never be deleted.
- **Pipeline:** inject a failure at each step and assert the retained set is unchanged and no `.partial` file remains. Further cases:
  - A locked file fails the run and names the file.
  - A file modified between walk and read is re-read once.
  - An empty source and a missing destination each fail without writing anything.
- **Verify:** a flipped byte in any entry fails verification, and so does a missing entry.
- **Unchanged:** a second check with no edits writes nothing and records success. Touching one file's modified time triggers a backup.
- **Size drop:** each combination of bytes or count against last or weekly trips the alert, and a 19% drop doesn't.
  - During a hold, nothing is pruned across several runs.
  - Acknowledging clears the hold, sets the baseline, prunes, and doesn't re-trip on the weekly comparison next run.
  - The OS notification is posted once per hold.
- **Extract:** a round trip reproduces the folder byte for byte. A `..` or absolute member is refused before anything is written. A non-empty target is refused.
- **Health and alerts:** one test per §9.3 row, plus the §8.4 timing (immediate versus grace period).
- **Overlap guards:** each refused combination in §9.4 is refused.
- **Re-check cap:** several runs in one local day re-check the rotation once. An unchanged folder's rotation is still re-checked once a day. A file corrupted between days is caught the next day.
- **Move:** a same-drive move and a different-drive move both bring over every file of ours and none of the user's. After the move, the rotation and size history carry on: no size-drop alert on the next run, and the weekly tier is unchanged. Further cases:
  - A crash at each step leaves every backup in exactly one complete place, and startup finishes or undoes the move.
  - An unreachable old destination refuses the move, and **Change without moving** retires the old subfolder.
- **Retired:** removing a source deletes nothing and lists its backups as retired, with their size in the section's total. **Delete all** removes only our files.

---

## 12. Open questions

Resolved 2026-10-03: the destination can be moved (§9.5); a removed source's backups are kept and tracked (§9.6); re-checks are capped at once a day (§6.2 step 9).

1. **Android later.** If folder backups come to Android, it would mean a Storage Access Framework tree URI per source and a separate access layer. Nothing in this design blocks that, but nothing prepares for it either.
