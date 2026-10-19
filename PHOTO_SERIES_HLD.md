# Photo Series — HLD

A new main page for **recurring photo series**: the user picks a cadence (daily / weekly / monthly / yearly), takes a check-in photo each period from one or more angles, and later browses the series as a grid, plays it back like stop-motion, and compares any two check-ins. Physique progress is the motivating example, but a series can track anything: a plant, a haircut, a room, a drawing.

Photos and notes are encrypted with the existing **Secure Vault** (`SECURE_NOTES_HLD.md`). Series metadata stays plain, so counts, streaks and reminders work while the vault is locked.

Related: `lib/core/secure_vault/secure_vault.dart`, `lib/features/notifications/secure_vault_session.dart`, `lib/features/notifications/secure_vault_dialogs.dart`, `lib/core/media/media_service.dart`, `lib/domain/services/media_ingest.dart`, `lib/core/reminders/reminder_engine.dart`, `lib/domain/models/reminder_models.dart`, `lib/domain/models/notification_models.dart`, `lib/domain/services/periodic_prompt_service.dart`, `lib/features/shell/shell_destinations.dart`, `MEDIA.md`, `SCHEDULED_REMINDERS_HLD.md`, `UNIFIED_NOTIFICATIONS.md`.

Status: **phases 1–6 implemented** (vault media core; series and check-ins; reminders; playback and compare; alignment tool; Android capture). Phase 6's manual device QA pass (§16) is still to do.

---

## 1. Goals

- Any number of **series**, each with a name, a cadence (`TrackerCadence`) and **one or more angles** (minimum 1; the user adds, renames, reorders and removes them).
- A **check-in** per period: one photo per angle (any subset), a date, and an optional note.
- **Capture on Android** with a **ghost overlay** of an earlier photo, so pose and framing line up.
- **Alignment tool** on both Windows and Android: a non-destructive move / zoom / rotate per photo against a reference photo.
- **Grid** of every check-in, with thumbnails **blurred until clicked**.
- **Playback**: stop-motion per angle with speed, loop modes, a scrubber and a date stamp.
- **Compare**: any two check-ins (default first vs. last) in side-by-side, slider-wipe or overlay mode.
- **Streaks and missed periods**, plus **reminders**: an inbox feed row while due, and an OS notification at a chosen time.
- Photos and notes are **encrypted in the Secure Vault** and synced as ciphertext.
- Left out of **Search** and **On This Day**.

## 2. Non-goals (v1)

- Exporting (GIF / MP4 / before-after image). Planned for later.
- Camera capture on Windows. Windows imports by file picker, paste or drag-and-drop.
- Automatic pose detection or automatic alignment.
- Body measurements or other structured numbers per check-in. The note covers this for now.
- Sharing.
- Several photos of the same angle in one check-in.

---

## 3. Product decisions (locked)

| Decision | Choice |
|---|---|
| **Placement** | New main nav destination, not a section of Analytics or Workout |
| **Scope** | General photo series, not physique-specific |
| **Cadence** | `TrackerCadence` (daily / weekly / monthly / yearly), the same periods as trackers |
| **Angles** | Per series, minimum 1, user-managed. The last one can't be removed |
| **Check-in counts when** | It has **at least one** photo. Missing angles show as gaps in that angle's playback |
| **Encrypted** | Photo bytes, thumbnails and check-in notes |
| **Plain** | Series name, cadence, reminder settings, angle names, check-in dates, which angles have a photo |
| **Unlock** | A password prompt **on the page itself**, using the same vault and session as Secure Notes |
| **No vault yet** | The page offers to create one, through the existing setup dialog |
| **Thumbnails** | Blurred until clicked |
| **Reminders** | Inbox feed row while the period is due **plus** an OS notification at the series' reminder time |
| **Search / On This Day** | Excluded |
| **Capture platform** | Android (camera + ghost). Windows imports files and does alignment |

---

## 4. Navigation and page structure

- **Destination:** `/photo-series`, label **"Photos"**, icon `PhosphorIconsRegular.images`. One `ShellDestination` entry plus its route in `app_router.dart`. It respects `hiddenNavPages` like every other page.
- **Series list** (page root): one card per series showing:
  - name and cadence;
  - check-in count;
  - current streak;
  - due / done for the current period;
  - a cover thumbnail (the latest check-in's first angle), blurred.

  The list ends with a "New series" card.
- **Series detail** (pushed route inside the branch):
  - Header: name, cadence, stats (§8) and a **Check in** button.
  - **Period strip**: one mark per period from the series' first period to now (§8). Clicking a mark scrolls the grid to that period's check-in.
  - Three views: **Grid | Playback | Compare**.
  - An overflow menu: edit series (name, cadence, angles, reminder), delete series.

### 4.1 Locked state

While the vault is locked, everything plain still renders: the list, stats, the period strip, and the grid's layout with dates and per-angle presence dots. Thumbnails show neutral placeholders, since nothing can be decrypted.

A single **unlock card** sits above the grid. It holds a password field plus a "Reset vault" link, and reuses the widgets in `secure_vault_dialogs.dart`. If no vault exists, the card reads "Set up a vault to store photos" and opens the existing setup dialog.

Playback, Compare, the alignment tool and **Check in** are disabled while locked. Pressing them focuses the unlock card.

---

## 5. Domain model

The schema bumps from 156. Every table follows the usual conventions: `createdAt`, `updatedAt`, `version` and `deletedAt` (soft delete, 30-day purge).

### 5.1 `PhotoSeries`

| Field | Notes |
|---|---|
| `id` | |
| `name` | Plain |
| `cadence` | `TrackerCadence` |
| `reminderEnabled` | Default true |
| `reminderMinutes` | Minutes after local midnight. Default 09:00 |
| `reminderWeekday` | Weekly only, 1–7. Default Monday |
| `reminderMonthDay` | Monthly and yearly, 1–31, clamped to the month's length. Default 1 |
| `reminderMonth` | Yearly only, 1–12. Default the month the series was created |
| `playbackFps` | Last speed used, so playback reopens at it. Default 4 |
| `sortOrder` | Order in the series list |

### 5.2 `PhotoSeriesAngle`

| Field | Notes |
|---|---|
| `id`, `seriesId` | |
| `name` | e.g. "Front". A new series starts with one angle named "Photo" |
| `sortOrder` | Order in the capture stepper and in the pickers |
| `referenceImageId` | The photo drawn under the alignment editor, and the ghost's alternative source (§9, §10). Null means the angle's first photo |
| `frameAspect` | Width ÷ height of the angle's reference frame (§10). Set from the angle's first photo and never changed, so picking another reference moves nothing |

Removing an angle soft-deletes it and its images. The UI blocks removing the last live angle.

### 5.3 `PhotoCheckIn`

| Field | Notes |
|---|---|
| `id`, `seriesId` | |
| `takenOn` | Local calendar date. Editable, so imports can be backdated |
| `noteCiphertext`, `noteNonce` | Null when there's no note |
| `vaultId` | The vault the note was sealed under |

A period can hold more than one check-in, for example a backdated import alongside a live one. Streaks only ask whether a period has any check-in with a photo.

### 5.4 `PhotoCheckInImage`

| Field | Notes |
|---|---|
| `id`, `checkInId`, `angleId` | At most one live image per (check-in, angle). Replacing soft-deletes the old one |
| `blobId` | → `VaultBlob` |
| `alignScale`, `alignRotation`, `alignDx`, `alignDy` | Non-destructive transform (§10). Offsets are fractions of the reference frame's size. Identity by default |

### 5.5 `VaultBlob` — encrypted image storage

A new encrypted counterpart to `MediaAsset`, **not** a reuse of it:
- `MediaAsset` deduplicates by content hash and stores in Storage at `users/{uid}/media/{hash}`. A hash of plaintext reveals which photos are the same.
- `MediaService` keeps plaintext files on disk.

| Field | Notes |
|---|---|
| `id` | Random UUID. Also the Storage name |
| `vaultId` | |
| `width`, `height` | After ingest |
| `byteSize`, `thumbByteSize` | Ciphertext sizes |
| `uploadState`, `downloadState`, `thumbDownloadState` | The same state machines as `MediaAsset`. One upload state covers both files; the thumbnail downloads on its own (§14) |

No paths are stored. The files are derived from `id`: `<app data>/vault_media/{id}` and `{id}.thumb` locally, `users/{uid}/vault_media/{id}` and `{id}.thumb` in Storage.

Each file is `nonce (12 B) ‖ ciphertext ‖ GCM tag`, so a blob stands alone without its row.

**Thumbnail:** 384 px on the long edge, encrypted separately. The grid and the period strip decrypt only thumbnails, never full images.

---

## 6. Encryption and the vault

1. **Bytes API.** Add `SecureVault.encryptBytes(key, vaultId, Uint8List)` and `decryptBytes(...)` next to the string versions. They use the same AES-256-GCM with the same authenticated data (`vaultId` only). Images are encrypted and decrypted with `Isolate.run`, because a 2048 px JPEG takes several frames on a phone.
2. **Ingest.** Reuse `MediaIngestPipeline` (HEIC→JPEG, downscale to `maxIngestEdgePx`, re-encode), then generate the thumbnail, then encrypt both. Plaintext exists only in memory.
3. **Nothing plain on disk:**
   - The `camera` plugin writes each capture to a temp `XFile`. Read its bytes and **delete the file immediately**, before ingest.
   - The decrypted-image cache is memory only. It is an LRU of decoded `ui.Image`s and is cleared on lock.
   - No `Image.file` or `FileImage` on vault content. Use a `MemoryImage`-style provider over the decrypted bytes.
4. **Shared session.** `secureVaultSessionProvider` is reused as-is, so unlocking on the page also unlocks Secure Notes in the inbox, and vice versa.
   - Pointer and key activity on the Photos page calls `touch()`, so the 5-minute idle lock runs from the last activity on either surface.
   - **Change to existing behaviour:** closing the inbox popover today locks the vault. With two surfaces sharing the session, that lock now applies only when the Photos page isn't the visible branch. Otherwise, glancing at the inbox would lock the photos you're looking at.
5. **Lock** additionally clears the decrypted-image cache, the per-thumbnail reveal state (§7.1) and any open viewer, playback, compare or alignment session.
6. **Password change:** re-wraps the key only, so photos are untouched (unchanged from Secure Notes).
7. **Vault reset:** deletes every `VaultBlob` and every encrypted check-in note sealed under the retired vault, the same rule as Secure Notes. Their `PhotoCheckInImage` rows go too. A check-in left with no images is deleted, so streaks and missed marks recompute honestly.
8. **Android `FLAG_SECURE`.** Set it while the vault is unlocked, which covers every screen a decrypted photo can be on (grid with a reveal, viewer, playback, compare, alignment, capture). This keeps photos out of screenshots and out of the recent-apps thumbnail.

---

## 7. Grid, viewer and check-ins

### 7.1 Grid

- Newest first, grouped by period. Each tile is one check-in, showing the first angle that has a photo, with dots for which angles are present, plus the date.
- **Blur:** thumbnails render through an `ImageFilter.blur` until clicked.
  - The **first click** reveals that tile.
  - A **second click** opens the viewer.
  - Reveals last until the page is left or the vault locks.
- Right-click (desktop) or long-press (Android): edit date, edit note, align, delete check-in.

### 7.2 Viewer

Full-screen, reusing the lightbox's zoom and swipe. It shows one check-in at a time:
- **left / right:** neighbouring check-ins;
- **up / down:** angles.

The note shows underneath. Photos render with their alignment applied.

### 7.3 Creating a check-in

**Check in** opens a stepper over the series' angles in `sortOrder`:
- **Android:** the capture screen (§9) for each angle, with **Skip** and **Retake**, then a review screen (thumbnails, date, note) and **Save**.
- **Windows:** each angle step accepts the file picker, paste or drag-and-drop (the same intake rules as `MEDIA.md`), then the same review screen.
- **Date:**
  - Live capture defaults to today.
  - An imported file defaults to its EXIF `DateTimeOriginal` (read with `image`), then the file's modified date, then today.
  - The date is always editable.
- Saving with zero photos is blocked.
- An existing check-in can gain or replace an angle's photo later, from its context menu.

---

## 8. Periods, streaks and missed marks

- **Periods:**
  - `PeriodicPromptService.trackerPeriodStartFor`, so weeks start on Monday as they do for trackers.
  - A check-in belongs to the period containing `takenOn`.
- **Done period:** has at least one live check-in with at least one live image.
- **First period:** the earlier of the series' creation period and its earliest check-in's period. A backdated import extends the strip backwards.
- **Current period:** shown as *due* until done. It never counts as missed while it's still running.
- **Missed:** every past period from the first period up to the one before now that isn't done.
- **Current streak:** consecutive done periods ending at the current period if it's done, otherwise at the previous one. A running, not-yet-done period doesn't break it.
- **Best streak:** the longest run ever.
- **Header stats:** check-ins, photos, current streak, best streak, missed periods, and first and latest dates.
- **Period strip marks:**
  - filled = done;
  - hollow with the error tint = missed;
  - accent ring = current (due or done).

The strip collapses to a scrollable row when there are many periods.

All of this is computed from plain fields, so it works while locked.

---

## 9. Capture with ghost overlay (Android)

- **Package:** add `camera` (Android only in v1). Add the camera permission to `AndroidManifest.xml`. A denied permission shows an explanation with an "Open settings" action.
- **Screen:** full-bleed `CameraPreview` with:
  - the angle name and step count at the top;
  - the shutter, a front/rear switch and a ghost control at the bottom.
- **Ghost:**
  - **Source:** by default the **latest previous photo of the same angle**, drawn with its alignment transform so the ghost sits where the aligned series sits. A toggle switches to the angle's **reference photo** instead.
  - **Look:** opacity slider from 0–70%, default 35%. Tap the ghost button to hide or show it.
  - **Preview mirroring:** the front camera's preview is mirrored, so the ghost is mirrored to match. The saved photo is not mirrored.
  - **First photo:** an angle with no earlier photo shows no ghost, only a faint rule-of-thirds grid.
- Requires an unlocked vault, both to decrypt the ghost and to encrypt the result. The 5-minute idle clock is touched by camera-screen activity.

---

## 10. Alignment tool (Windows and Android)

- **Purpose:** photos never line up perfectly. Each image stores a transform (`scale`, `rotation`, `dx`, `dy`) that maps it onto its angle's **reference frame**. Originals are never modified.
- **Frame:** the angle's `frameAspect`, fixed from its first photo. Transforms are relative to the frame.
- **Reference:** the photo drawn underneath in the editor, by default the angle's first photo. Any photo can be made the reference from its context menu. Changing the reference doesn't touch any transforms or the frame.
- **Editor:**
  - The reference is drawn underneath and the photo being aligned on top at 50% (slider).
  - **Gestures:**
    - drag to move;
    - wheel or pinch to zoom around the cursor or fingers;
    - a rotation slider, or two-finger rotate;
    - arrow keys nudge (Shift for larger steps).
  - **Actions:** "Copy from previous" (start from the previous photo's transform), "Reset", "Done".
- **Rendering:** playback, compare and the viewer draw every photo of an angle with its transform, clipped to the reference frame's aspect ratio, so the series reads as one steady shot.
- **Sync:** transforms are plain fields on `PhotoCheckInImage` and sync as later-save-wins. They reveal nothing about the content.

---

## 11. Playback

- **Controls:**
  - angle picker;
  - play / pause (Space);
  - previous / next frame (← / →);
  - a scrubber with tick marks at each check-in and the hovered date shown;
  - a speed slider from 1–30 fps, remembered in `playbackFps`;
  - loop mode: **once**, **loop** or **ping-pong**.
- **Overlay:** a date stamp in the corner (toggle), plus the elapsed time since the first frame ("+14 weeks").
- **Frames:** the angle's check-ins in date order. Check-ins without that angle are skipped.
- **Memory:** frames are decrypted and decoded **at viewport size** (`ui.instantiateImageCodec` with a target width), into a sliding window of about 30 frames ahead and 10 behind, filled in the background. Playback waits on a frame that isn't ready rather than skipping it.

## 12. Compare

- **Pickers:** two check-in pickers (A and B), defaulting to **first** vs **latest**.
- **Quick picks for A:** First, Previous, ~1 month ago, ~1 year ago. "~" means the nearest check-in to that date.
- **Angle picker**, shared by both sides.
- **Modes:**
  - **Side by side:** the two photos next to each other (stacked on narrow widths).
  - **Slider:** B drawn over A with a draggable vertical divider, with arrow-key control.
  - **Overlay:** B over A with an opacity slider.
- **Labels:** each side shows its date, and the elapsed time between them sits in the middle. Notes appear under the images.
- Both photos are drawn with their alignment transforms.

---

## 13. Reminders and the inbox

### 13.1 OS notification (Scheduled Reminders rails)

- Add `ReminderSourceKind.photoSeries`. `ReminderEngine` builds one `ReminderSourceView` per series with `reminderEnabled`.
- **Fire time:** the reminder day within the current period at `reminderMinutes`, device-local:
  - daily: every day;
  - weekly: `reminderWeekday`;
  - monthly: `reminderMonthDay`, clamped;
  - yearly: `reminderMonth` / `reminderMonthDay`.
- **Auto-acknowledge:** once the current period is done (§8), the occurrence is treated as acknowledged. A check-in made before the reminder time cancels that period's OS alert.
- **Existing rules unchanged:** snooze (10 min, tomorrow), coalescing, cross-device acknowledge and the sticky toast all work as `SCHEDULED_REMINDERS_HLD.md` describes. Every registered device is targeted.
- **Hidden page:** hiding `/photo-series` doesn't silence the sticky or OS alert, as with todo and calendar bells; turning the series' reminder off does. Only the inbox row is suppressed (§13.2).
- **Text:** "{series name} — check-in due". Tapping it opens the series detail. On Android, if the vault is unlocked, it goes straight into the capture stepper.
- The series name appears on the lock screen. This follows from keeping names plain (§3).

### 13.2 Inbox feed row

- Add `NotificationItemType.photoSeries`. `buildNotificationFeed` emits one row per series whose current period isn't done **and** whose reminder time this period has passed.
- **Urgency:** `semi`, rising to `important` on the period's last day for weekly, monthly and yearly series. Daily series stay `semi`.
- **Row:** a camera icon, the series name and "due · {time left in period}". Clicking it opens the series. Dismissing it uses the existing dismissal keys.
- **Hidden page:** if `/photo-series` is in `hiddenNavPages`, no rows are emitted. This matches how Study and LeetCode are handled in `notificationFeedProvider`.

---

## 14. Sync, storage and lifecycle

- **Firestore collections:**
  - `photo_series`
  - `photo_series_angles`
  - `photo_check_ins`
  - `photo_check_in_images`
  - `vault_blobs` (metadata only)

  Each gets a `FirestoreCollections` constant, mapper functions, pull and push. Merges are later-save-wins by `version`, like the other non-text entities. Check-in notes are short, so they don't get Secure Notes' fork-on-conflict.
- **Storage:**
  - Ciphertext uploads to `users/{uid}/vault_media/{id}` and `{id}.thumb`, through a `VaultMediaService` that mirrors `MediaService`'s upload and download queue and respects its remote-I/O settings.
  - `storage.rules` needs the new path; Firestore rules already cover `users/{uid}/{collection}`.
- **Download order:** thumbnails are fetched eagerly, so the grid works offline. Full images follow the existing prefetch setting.
- **Trash:**
  - Add `TrashFeature.photoSeries` ("Photos").
  - Deleting a series cascades to its angles, check-ins and images with one `deletedAt`, and restores together.
  - Deleting a check-in shows the undo toast.
  - The 30-day purge deletes blobs locally and in Storage.
- **Backups:** add every table plus the ciphertext blobs to `buildBackupCollections`, as ciphertext only, like Secure Notes. Exporting decrypted photos is part of the later export work.
- **Account switch / sign-out:** the new tables and the vault media folder are covered by the existing per-account teardown. Check this alongside the Secure Notes tables.
- **Search / On This Day:** they read only journal entries and dreams today, so leaving photo series out needs no code. A test pins this (§16).

---

## 15. Implementation phases

1. **Vault media core** — **done (2026-10-18)**:
   - `encryptBytes` / `decryptBytes`;
   - `VaultBlob` table and `VaultMediaService` (ingest → thumbnail → encrypt → local file → upload, and download → decrypt into memory);
   - Storage rules.
2. **Series and check-ins** — **done (2026-10-19)**:
   - the remaining tables, sync, trash and backups;
   - the nav destination, series list and detail;
   - locked and unlocked states, and the session change to popover-close locking;
   - Windows import check-ins;
   - the grid with blur, and the viewer;
   - periods, streaks, missed marks and the period strip.
3. **Reminders** — **done (2026-10-19)**:
   - `ReminderSourceKind.photoSeries`, the inbox feed row and auto-acknowledge;
   - the reminder settings in the series dialog (on/off, time, and the weekday, day or month and day);
   - an occurrence never predates the series, so one made after today's reminder time waits for the next;
   - the OS notification opens the series. Going straight into capture waits for phase 6.
4. **Playback and Compare** — **done (2026-10-19)**:
   - Grid | Playback | Compare on the series detail; locking drops back to the grid;
   - Playback's frame window (30 ahead in the direction of play, 10 behind), decoded no larger than drawn; a frame that won't open is stepped past, and the thumbnail stands in for a full image not yet downloaded;
   - Compare's quick picks are relative to B ("~1 month ago" = nearest to a month before B);
   - elapsed time reads in days under 2 weeks, weeks under 26, months under 24, then years;
   - Playback and Compare draw each photo with its transform: fitted inside the frame, then moved, rotated and zoomed about the frame's centre. The viewer does too since phase 5.
5. **Alignment tool** — **done (2026-10-19)**:
   - opened from a tile's context menu ("Align", per angle when the series has several), as a dialog; saved on Done, dropped on Cancel or a lock;
   - the reference is drawn with its own transform, so the photo lines up with the aligned series; aligning the reference itself shows nothing underneath;
   - zoom is 20–800% and rotation ±45° (a sideways photo is turned at ingest); arrow keys nudge 1 px, Shift 10 px;
   - "Use as reference" on a tile's context menu, disabled on the angle's current reference; replacing the reference photo makes the new photo the reference;
   - the viewer draws photos aligned and clipped to the frame.
6. **Android capture** — **built (2026-10-19), device QA pending**:
   - `camera` (CameraX on Android); the camera permission in the manifest, and the plugin's microphone permission removed from it, since nothing records;
   - on Android, **Check in** opens a full-screen capture route, an angle at a time (**Skip**, then **Retake** or **Use photo**), and the dialog opens at its review with what was taken. Each angle step of the dialog also has a **Camera** button, which is how one angle is retaken from the review, and how a check-in's photo is added or replaced from its context menu;
   - the ghost: the angle's latest photo, or its reference with the **Latest | Reference** toggle, which shows only when the two differ. It is drawn with its transform in the angle's frame, laid out around the preview the way a new photo is fitted into it, and mirrored with the front camera. An angle's first photo gets the thirds grid;
   - each capture's temp file is deleted before its bytes are used;
   - a denied permission shows an explanation and **Open settings**; coming back retries;
   - `FLAG_SECURE` is set whenever the vault is unlocked, on any page, which is broader than "while a photo is on screen". One listener on the vault session covers every photo surface, the camera and check-in included, with no gap before the first frame. The cost is that screenshots elsewhere in the app are blocked too while the vault is open;
   - the OS notification, tapped on Android with the vault open, opens the series' check-in, so the camera.

Each phase can ship on its own. The ghost overlay is the most important capture feature, but it needs phases 1–2 (storage) and benefits from 5 (aligned ghost).

## 16. Testing

- **Crypto:** a bytes round trip; tampered bytes are rejected; nonces are unique; a blob sealed under another vault is rejected.
- **No plaintext on disk:** after ingest and after a capture, the app's media, vault and temp folders contain no decodable JPEG/PNG from the session, and the camera's temp file is gone.
- **Periods and streaks** (pure functions): every cadence, Monday weeks, month-length clamping, a running period not counting as missed, backdated imports filling a missed period, multiple check-ins in one period.
- **Reminders:** fire-time computation per cadence; a check-in before the fire time cancels the alert; auto-acknowledge on period done; no inbox row when the page is hidden.
- **Locked page (widget):** stats and the strip render; thumbnails are placeholders; Check in, Playback and Compare are disabled; locking clears revealed tiles and closes the viewer.
- **Session:** closing the inbox while Photos is the visible branch doesn't lock; closing it on another branch does.
- **Exclusion:** the search service returns nothing for a check-in note's text. Notes are ciphertext anyway; the test guards against a future plain index.
- **Sync:** two databases, as in the Secure Notes tests. Check-ins, images and alignment changes round trip; a series delete cascades on the other device.
- **Android:** a manual QA pass covering capture, the ghost at several opacities, front-camera mirroring, permission denied, and `FLAG_SECURE` (blank recent-apps thumbnail).

## 17. Risks

- **Android verification.** The Android SDK is installed (`android/local.properties`), so phase 6 can be built here. Camera, ghost and `FLAG_SECURE` still need a real device for the manual QA pass. Watch for two things there: whether CameraX saves front-camera photos mirrored (the HLD wants them unmirrored), and whether the still's aspect matches the preview's at `ResolutionPreset.veryHigh` (the ghost assumes it does).
- **Memory in playback.** Long daily series could mean hundreds of frames. The viewport-size decode and sliding window (§11) are required, not optional.
- **Vault password friction.** Every check-in on the phone needs an unlocked vault. If unlocking every time becomes a nuisance, the fix is a separate, longer idle timeout for the Photos page. Not done in v1.
- **Storage cost.** Photos are at most ~1 MB each after ingest. A daily three-angle series grows by about 1 GB a year.

## 18. Defaults assumed (say if any are wrong)

1. Nav label **"Photos"** with the `images` icon.
2. A new series starts with one angle named **"Photo"**.
3. Reminder defaults: **09:00**, Monday for weekly series, the 1st for monthly ones.
4. Ghost defaults to the **previous** photo at **35%** opacity.
5. Playback defaults to **4 fps**.
6. Reveals last until you leave the page or the vault locks.
7. Closing the inbox doesn't lock the vault while Photos is the visible page.
8. Android `FLAG_SECURE` while the vault is unlocked, set through a method channel in `MainActivity` (no package).
9. A **self-timer** (3 / 10 s) on the capture screen is *not* in v1, though it would help when shooting yourself with the rear camera.
