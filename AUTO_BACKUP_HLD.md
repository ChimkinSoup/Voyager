# Automatic Backups — HLD

Voyager takes a full backup of itself every day and keeps a small, age-tiered set of them on the device: the last three days, one about a week old, and one about a month old. Each backup is the same ZIP the manual **Export Backup** writes, so any of them can be restored with the existing **Import Backup** path or copied off the device.

Related: `lib/features/settings/services/data_export_service.dart`, `lib/features/settings/services/data_import_service.dart`, `lib/features/settings/services/backup_collections.dart`, `lib/features/settings/settings_page.dart` (Backup & Restore section), `lib/app/voyager_app.dart` (lifecycle), `android/app/src/main/AndroidManifest.xml`, `JOURNAL_DATA_LOSS_POSTMORTEM.md`.

Status: **implemented** (`auto_backup_service.dart`, `auto_backup_retention.dart`, `backup_list_dialog.dart`). Decisions locked 2026-09-24; audited and hardened the same day; remaining questions in §12.

---

## 1. Goals

- Take one backup per local calendar day without the user doing anything.
- Keep backups aged roughly **1, 2 and 3 days**, **~1 week** and **~1 month**.
- Never make things worse. A failed, partial or corrupt backup must not replace a good one, and pruning must never delete anything it didn't create.
- Every retained backup has been proven restorable by this build before any older backup is deleted.
- Make it obvious when backups are *not* happening.

## 2. Non-goals (v1)

- Off-device copies (cloud, NAS, USB). Firestore already covers device loss; this feature covers the cases Firestore can't (§3).
- Point-in-time restore of a single record, or a diff view between backups.
- Incremental or deduplicated backups. Today's archive is ~8 MB (3.3 MB DB, 5 MB media), so full copies are cheap.
- App-level encryption (see §8.3 for why).
- Configurable retention.

---

## 3. What this protects against

This defines what "trustworthy" has to mean. Local backups don't help if the device is lost; Firestore handles that. They cover the failures **sync spreads**:

| Threat | Example | Why Firestore doesn't save you | What saves you |
|---|---|---|---|
| A bug corrupts data | 2026-09-16: a journal body was saved as `''` at a bumped version (`JOURNAL_DATA_LOSS_POSTMORTEM.md`) | The bad write wins and syncs to every device | Yesterday's backup |
| The user deletes or overwrites by mistake | Deleted a list, emptied a note | Same as above | Daily backups |
| Corruption noticed late | A field silently wiped weeks ago | Every daily now holds the bad state | Weekly / monthly backup |
| A restore goes wrong | Restoring the wrong backup reverts today's edits (§7.2) | The restore itself syncs | Pre-restore snapshot (§7.2) |
| The local DB file is damaged | Disk error, crash mid-write | Can re-pull, but unsynced edits are gone | Most recent daily |

A backup that can't be restored is worse than no backup, because it's false reassurance. Most of this design is about making sure that can't happen silently.

---

## 4. Product decisions

| Decision | Choice |
|----------|--------|
| **Toggle** | **Settings → Automatic backups**, default **on**. You only find out a backup was needed after the fact, so an opt-in backup won't exist when you need it. Persisted per device, not synced (§9.1). |
| **Frequency** | At most one automatic backup per local calendar day. |
| **What a backup contains** | Exactly what manual export writes: every `BackupCollection`, settings and cached media blobs, in `formatVersion` 2. |
| **What "yesterday's backup" means** | The backup taken on the first run of day *D* captures the state at the end of day *D−1*. Files are labelled by when they were taken; the UI shows ages. |
| **Retention** | 3 dailies + weekly + monthly, plus up to 2 "rising" backups: 5–7 files (§5). |
| **Platforms** | Windows and Android. |
| **Location** | Private app-support directory, not Documents, with a **Show in folder** button (§8.1). |
| **Restore** | Uses the existing `DataImportService.importFromZip`, after a checksum check and a pre-restore snapshot (§7). |
| **Visibility** | A Settings status row shows the backup count, the total size and a health state, and opens the backup list (§9). Repeated failures post an Inbox notification. |

---

## 5. Retention

### 5.1 The catch with exactly five files

If the only backups on disk are the three dailies, the weekly and the monthly, nothing can ever become the next weekly. Each day the oldest daily (4 days old) drops out, and **no file ever ages from 4 to 7 days**. The only options are to promote that 4-day-old copy early or keep an extra copy while it ages.

I simulated both over 500 days, with daily use and with the app opened only 60% of days:

| Scheme | Files on disk | "Week" slot age | "Month" slot age |
|---|---|---|---|
| **A. Strict 5, promote on drop-out** | 5 | **3–16 days** | **11–68 days** |
| **B. 5 + 2 rising (chosen)** | 5–7 | **7–13 days** | **30–51 days** |

Under A the "week-old" backup is sometimes 3 days old, which just duplicates a daily, and the "month-old" one is sometimes 11 days old. That's exactly the late-noticed corruption case in §3. B costs two extra archives (~16 MB today) and makes the ages actually hold.

### 5.2 Rule

Retention is a **pure function** from the set of backups on disk plus today's date to the set to keep. It doesn't keep separate slot state, so it recovers correctly from gaps, crashes, reinstalls or a user deleting files by hand.

With `age` = today's local date minus the backup's capture date, in whole days:

1. Keep the **3 newest** backups (the dailies).
2. For each tier `T ∈ {7, 30}`:
   - keep the **youngest backup with `age ≥ T`** (the tier's holder), and
   - keep the **oldest backup with `age < T`** (the next one to become holder).
3. Delete everything else.

The rules can overlap (a rising backup may also be a daily), so the count is 5–7. Each "rising" backup ages into its tier and takes over the moment it crosses `T`. The old holder is then released, or kept as the next tier's rising backup.

If the app hasn't been opened for a while, the rule keeps what it has and doesn't invent backups. After a 10-day gap the dailies are just the three newest files, whatever their dates.

### 5.3 Guards

- A backup dated **in the future** (the clock went backwards) is never deleted and is left out of the age maths until the clock catches up.
- Pruning runs **only after the new backup has passed verification** (§6). If verification fails, nothing is deleted that day.
- Pruning only touches files in the backups directory whose names **exactly match** the automatic-backup pattern (§6.2). Manual exports, pre-restore snapshots and anything the user put there are never deleted by retention.

---

## 6. Taking a backup

### 6.1 When

- **Trigger:** on startup (deferred about 30 s so it doesn't compete with first paint and the initial pull), then an hourly check while the app runs. Each check asks one question: *is there a verified automatic backup captured on today's local date?* If not, it runs. The hourly check covers a desktop left open past midnight, sleep and hibernate, and time-zone changes without any midnight-timer logic.
- **Single flight:** an in-process guard stops overlapping runs. Windows already enforces one instance (`Local\Voyager.SingleInstance` in `windows/runner/main.cpp`). On Android, one engine means one process.
- **Android:** runs only while the app is in the foreground: the timers stop when the app is paused and restart on resume, so a run never starts just before the OS freezes the process and a day in the background doesn't count as a day the app was open. No WorkManager in v1: a background isolate would need its own DB connection and sync stack, which would be a bigger and riskier change than this feature. On days the app isn't opened, there's no backup, which is also true on desktop.

### 6.2 Pipeline

```
snapshot ─► write .partial ─► flush ─► verify from disk ─► rename ─► re-check retained ─► prune ─► record status
   │              │                         │                │               │                 │
   └─ fail ───────┴─────────────────────────┴────────────────┴───────────────┴─────────────────┴─► delete .partial, record failure
```

Success is recorded only at the end, so a failure in any step, including re-check or prune, shows as a failed attempt. If today's backup already exists but the run that took it failed afterwards, the next check re-runs only re-check and prune rather than taking a second backup (which would push an older day out of the three dailies).

1. **Consistent snapshot.** `buildArchiveContents` currently reads one collection per `await`, so a sync pull that lands mid-export can leave, say, an entry without its journal. The collection and settings reads move inside a single Drift transaction so the export is one point in time. Media blobs are read afterwards; they're content-addressed and immutable, so this is safe. The transaction blocks writes for the read duration (a few hundred ms at today's size), which is fine once a day.
2. **Checksums.** The manifest gains `checksums: {memberName: sha256}` for every archive member. This is additive, so `formatVersion` stays 2 and older builds ignore the field.
3. **Write to a temp name** `voyager_auto_<yyyy-MM-dd_HH-mm-ss±HHmm>.zip.partial` (local time to the second plus the UTC offset, e.g. `voyager_auto_2026-09-24_18-25-30-0400.zip`) with `flush: true`. Backups with the earlier UTC names (`voyager_auto_20260924T222530Z.zip`) are renamed on startup.
4. **Verify from disk.** Re-read the file, run the existing `extractBackupIsolate`, which is the restore path's own parser, check every checksum, and confirm that per-collection record counts match the manifest. This proves the file is restorable by this build, not just that bytes were written.
5. **Rename** to `.zip`. A rename silently replaces an existing file, on Windows too (Dart uses `MOVEFILE_REPLACE_EXISTING`). Names are unique to the second, and the target is checked first: a clash fails the run rather than replacing a backup.
6. **Re-check the retained set** *before* pruning. Re-verify every other retained automatic backup (about 60 MB of hashing at today's size, once a day), so a bad file is out of the retention input and its tier refills from the next good file. Each file lands in one of four outcomes:
   - **Verified:** stays in the rotation.
   - **Damaged** (the ZIP won't decode, or a checksum or record count doesn't match): renamed to `<name>.damaged`, which takes it out of the list and the rotation *without deleting it*, in case the check was wrong. Health goes to *Attention*.
   - **Unsupported format** (made by a build that reads a different `formatVersion`): renamed to `<name>.unsupported`. It's kept for the build that made it and hidden from this one. That's not damage, so health is unaffected. Without this, the first build after a format bump would have treated every v2 backup as corrupt.
   - **Unreadable right now** (held open by a virus scanner or ZIP tool, out of memory): left alone and out of that day's pruning. Health goes to *Attention* ("could not be re-checked").
7. **Prune** (§5).
8. **Record status** (last outcome, last success, last failure and reason, last re-check result) in `backups/state.json`. The UI reads this file; retention never relies on it. Updates are serialised and written via a temp file plus rename, so two updates never lose each other's change and a crash never leaves a truncated file.

On startup, leftover `.partial` files from a crash are deleted.

### 6.3 Space

Before writing, check free space against about 2× the previous backup's size. If there isn't enough, skip and record a failure. **Old backups are never deleted to make room.** Doing that would trade known-good backups for an unverified one.

---

## 7. Restoring

### 7.1 Flow

Settings → Backup & Restore → **Automatic backups** lists each file with its age label ("Yesterday", "3 days ago", "Weekly · 9 days ago", "Monthly · 34 days ago"), capture time, size and record counts from the manifest. Actions:

- **Restore…** Confirm dialog, then checksum check, then pre-restore snapshot, then `importFromZip`, then `invalidateAllDataProvidersFrom(ref)`.
- **Save a copy…** Copies the file to a user-chosen location. This is how a backup leaves the device.
- **Show in folder** (desktop).

`importFromZip` also verifies manifest checksums when present, so a manually imported archive gets the same check.

### 7.2 Pre-restore snapshot

**Why it's needed.** `importFromZip` is a merge, but a merge in which **the backup wins**. Every record whose content differs is rewritten at `max(local, backup).version + 1` and then pushed to Firestore. So restoring yesterday's backup **reverts every record edited today, on every device**. That's correct when you want to undo a bad edit, and a disaster when you picked the wrong file.

**How it works.** Restoring backup *X*, whether an automatic backup or a manually imported ZIP:

1. Verify *X*'s checksums. If *X* is bad, stop; nothing has been touched.
2. Take a normal backup of the current state, through the same pipeline and with the same verification as §6.2, named `voyager_prerestore_<timestamp>.zip`. **If this fails, the restore is refused.** An undo point is a precondition, not a best effort.
3. Run `importFromZip(X)`.

The snapshot appears at the top of the backup list as **"Before restore · today 14:02"**. Restoring it undoes the restore:

- Every record *X* changed is back in the snapshot in its pre-restore form, so the snapshot wins it back. That includes a record *X* un-deleted: `deletedAt` is content, so the tombstone returns.
- Records *X* didn't touch are the same in both, so they're skipped.
- Records created after *X* was taken were never in *X*, so the restore left them alone, and the undo does too.
- The one loss: an edit made **between** the restore and the undo, to a record the snapshot also holds, is reverted. The sooner you undo, the less that matters.

Restoring the snapshot is itself a restore, so it takes its own snapshot first. An undo can be undone.

**Lifetime.** Pre-restore snapshots sit outside the §5 rotation, so they never count as or displace a daily, weekly or monthly backup. Each one is deleted 7 days after it was taken, checked hourly whether or not automatic backups are on. They're taken even when automatic backups are off, because protecting a restore is a separate concern from scheduled backups.

Only one restore runs at a time; a second is refused while the first is in progress.

The confirmation dialog has to say this in plain words: *"Anything changed since <capture time> will be replaced on all your devices. A snapshot of the current state is saved first, so you can undo this."*

---

## 8. Security

### 8.1 Location

| Platform | Directory | Notes |
|---|---|---|
| Windows | `getApplicationSupportDirectory()/backups` (under `%APPDATA%`) | **Not** Documents. Documents is often redirected to OneDrive by Known Folder Move, which would silently upload journal and finance data to a third party. (It isn't redirected on this machine, but that can't be assumed.) Protected by the user-profile ACL. |
| Android | `getApplicationSupportDirectory()/backups` (app-private `files/`) | Sandboxed from other apps. **Wiped on uninstall**, so local backups don't survive a reinstall. Firestore does. |

Documents would be easier to find, but AppData is private and never cloud-synced by accident. The **Show in folder** button (§9.2) and **Save a copy…** make up for it being hidden.

### 8.2 Android Auto Backup

`AndroidManifest.xml` sets no `allowBackup`, so it defaults to `true` and Android uploads app files to Google Drive, capped at 25 MB. Seven archives would exceed that cap, and **Android stops backing up the app entirely once the quota is exceeded**. They would also put a second, unmanaged copy of the data in Drive. Exclude `files/backups/` via `dataExtractionRules` (API 31+) and `fullBackupContent` (older).

This is worth a separate look for `voyager.sqlite` too, which falls under the same defaults. That is out of scope here.

### 8.3 Encryption: not in v1

A backup has exactly the same exposure as `voyager.sqlite`: same user, same device, same OS protection, and the DB is plaintext. Encrypting only the backups wouldn't reduce what an attacker with file access can read. It would add a way to lose data: a key held in DPAPI or Android Keystore dies with the OS profile or app install, which makes the backup unrestorable exactly when it's needed. Revisit if the DB itself is ever encrypted, or when backups leave the device (a "Save a copy…" with a passphrase would be the natural place).

### 8.4 Integrity, honestly stated

The SHA-256 checksums detect **corruption** (bit rot, truncated writes, a half-copied file). They are **not** tamper-proofing: anyone who can edit a backup can recompute its checksums. On a single-user device that's the right trade-off. Signing would need a key, which runs into the same problems as §8.3.

### 8.5 Restoring untrusted archives

`_restoreMediaBlobs` writes files under names derived from asset rows' `contentHash`, never from archive member names. Those rows are restored from the same archive, though, so `contentHash` is untrusted. Two guards cover it:
- `MediaFileStore.fileFor` refuses anything that isn't a bare name (`^[A-Za-z0-9_-]+$`), so a value like `../x` can't write or delete outside the cache. This also covers the sync and download paths.
- The restore writes a blob only if its bytes hash to the asset's `contentHash`.

The format version is checked before anything is written. The whole DB restore, including the read of current local state it compares against, is one transaction, so a sync pull can't land in between. The remaining gap is memory: the whole ZIP is decoded in memory, so a hostile "zip bomb" could OOM the app. That's acceptable for self-made backups. Add a size cap if restoring shared files ever becomes a feature.

---

## 9. Settings UI and health

### 9.1 Toggle

**Automatic backups**, a switch in Backup & Restore, default on.

- Persisted in `backups/state.json`, the same device-local file as the status. It isn't in `AppSettings`: a phone with little free space shouldn't be able to turn off backups on the desktop. It's stored next to the backups on purpose. If the file or folder is lost, the toggle falls back to **on**, which is the safe direction.
- **Turning it off** stops scheduled backups and stops pruning. Existing backups are kept, listed and restorable; nothing is deleted behind the user's back. Pre-restore snapshots still happen.
- **Turning it on** runs the §6.1 check immediately rather than waiting for the next hourly tick.

### 9.2 Status row

A single row under the toggle:

```
┌────────────────────────────────────────────────────────────┐
│ 🛡  7 backups · 16.2 MB                          ● Healthy  │
│     Last backup today 09:14, verified                   ›  │
└────────────────────────────────────────────────────────────┘
```

- **Count:** automatic backups plus any pre-restore snapshots, e.g. "7 backups + 1 restore snapshot".
- **Size:** the total of those files, from a directory listing (no archive is opened).
- **Health:** a coloured dot and a word (§9.3). The second line gives the reason whenever the state isn't *Healthy*.
- **Tap** opens the backup list (§7.1), which has **Show in folder** in its header.

The row refreshes when Settings opens and whenever a backup, prune or restore finishes. It reads the directory and `state.json`; it never computes health on its own.

### 9.3 Health states

Evaluated in this order; the first match wins:

| State | When | Second line |
|---|---|---|
| **Backing up…** (neutral, spinner) | A run is in progress | "Taking today's backup" |
| **Off** (neutral) | Toggle is off | "Automatic backups are off · last backup 3 days ago" |
| **Attention** (amber) | The last attempt failed, **or** a retained file was damaged or could not be re-checked (§6.2 step 6), **or** the newest verified backup is more than 1 local day old even though the app has been opened since then | The recorded reason, e.g. "Not enough free space (needs 18 MB)" |
| **Not yet backed up** (neutral) | No automatic backup has ever succeeded on this device and no attempt has failed | "First backup runs shortly after startup" |
| **Due** (neutral) | The newest backup is older than yesterday, but the app hasn't been open since, so today's run just hasn't happened yet | "Today's backup runs shortly" |
| **Healthy** (green) | A backup captured today or yesterday passed verification, the last attempt succeeded and every retained file passed its last re-check | "Last backup today 09:14, verified" |

"Healthy" is a claim that restoring would work, which is why it depends on the re-check and not just on files existing.

### 9.4 Inbox notification

If there has been no successful automatic backup for **2 consecutive local days on which the app was opened**, post an Inbox notification (unified notifications) with the reason and a **Retry** action. One failed hourly check isn't news; two days in a row is. Failures are recorded, not thrown into the UI, and the hourly check retries automatically.

---

## 10. Implementation outline

| Area | Change |
|---|---|
| `data_export_service.dart` | Read collections and settings in one transaction. Add `checksums` to the manifest. `flush: true` on write. |
| `data_import_service.dart` | Verify `checksums` when present. Expose a verify-only entry point (reuses `extractBackupIsolate`). |
| New `auto_backup_retention.dart` | Pure `Set<Backup> keep(Set<Backup> all, DateTime todayLocal)`. |
| New `auto_backup_service.dart` | Trigger, single-flight guard, pipeline (§6.2), daily re-check, `state.json` (status + toggle), pre-restore snapshot. Exposes a stream of the status-row model (count, bytes, health). |
| `providers.dart` | Provider for the service. Start it from `voyager_app.dart` after DB open. |
| `settings_page.dart` | Toggle and status row (§9). New `backup_list_dialog.dart` with Restore, Save a copy and Show in folder. |
| `AndroidManifest.xml` + `res/xml/` | Exclude `backups/` from Auto Backup. |
| Notifications | "Backups failing" Inbox item. |

## 11. Testing

- **Retention (pure, fast):** port the simulation to Dart tests. Over 500 simulated days with daily use and with 60% of days opened: the file count stays ≤ 7; once history allows, some backup is always aged 7–13 and some aged 30–51 days; the 3 newest are always kept; a future-dated file is never deleted; a non-matching file name is never touched.
- **Pipeline:** inject a failure at each step (snapshot, write, verify, rename) and assert the directory's retained set is unchanged and no `.partial` file remains. A corrupted byte in the written file fails verification.
- **Round trip:** export, then auto-verify, then import into an empty in-memory DB, and assert every collection matches.
- **Consistency:** a write that lands during export shows up either entirely or not at all.
- **Restore:** confirm a pre-restore snapshot exists before `importFromZip` runs, that restoring it reverts the restore (including an un-delete), and that a failed snapshot blocks the restore.
- **Health:** one test per §9.3 row, including the precedence order and a corrupted retained file producing *Attention*.
- **Toggle:** off stops runs and pruning but keeps files; a missing `state.json` reads as on.

---

## 12. Open questions

1. **Toggle scope:** per device (proposed), or synced so one switch controls every device?
2. **Delete all backups:** when automatic backups are off, should the backup list offer a "Delete all backups" button, or should cleanup be manual (via Show in folder)?
