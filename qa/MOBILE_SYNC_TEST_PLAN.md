# Voyager QA, Mobile Sync Test Plan (desktop + Android)

Written 2026-11-22, on `349e49df` plus the uncommitted Gaia settings work. Read after `qa/MOBILE_TEST_PLAN.md` (whose rules, harness and phone safety apply here) and `qa/MULTI_DEVICE_SYNC_TEST_PLAN.md` (the desktop two-profile run, MD-0 … MD-18, 2026-10-12 to 2026-10-20). Run it after mobile Phase M22.

**Device (2026-11-22): P is Juno's OnePlus 12R over USB, not the emulator.** Read `MOBILE_TEST_PLAN.md`'s DEVICE section first. It covers the USB mode ("Charging this device"; ask Juno to switch to "File transfer" if adb misbehaves), Do Not Disturb on for the session and restored after, screen-lock-dependent checks deferred to PROGRESS.md §6b, restoring **Juno's** settings at the end, and no `adb emu` commands. Wherever this plan says "emulator", read "the phone".

## Why this run exists, and why it's smaller than the desktop one

The sync engine is shared Dart, with no platform branches in `lib/core/sync`, and MD-0 … MD-18 already took its logic apart. Running all of that again would mostly find the same bugs. This plan tests what is **different** when one of the devices is a phone:

1. **Different SDKs underneath.** On Windows, Firestore runs on the C++ SDK and media goes through `FirebaseRestMediaStorage` (`providers.dart:281`). On Android, both run on the native Android SDKs, and weather goes through the `cloud_functions` plugin. Offline caching, listener re-attachment, write queuing, transactions offline and upload retries can all behave differently below the same Dart.
2. **Android's lifecycle.** The desktop app never stops running. A phone app is paused, frozen in Doze, killed in the background, and resumed hours later. MD-9 (offline) and MD-10 (startup pull) assumed a process that stays alive.
3. **Real per-device network loss.** On one PC the only per-instance offline switch was Dev → Force offline (MD §1.4). The phone has its own network, so it can go truly offline (airplane mode) while the desktop stays online, and the reverse.
4. **A second clock and timezone**, if M0 finds a way to set them on the phone (on the emulator, `cmd alarm set-timezone` / `set-time` worked without root). Cross-timezone cases were unit-test only (FV-5, MD §1.4).
5. **Platform-specific records:** Android device registration, Android-scheduled reminder alarms, phone-captured Photos, the phone as a Gaia remote client.
6. **Changes since MD-18:** sync performance work (`c26c586f`), the Firebase SDK update (`f0892ff4`), default journal/list/calendar switching (`79f5c468`), timezone handling (`42b6efda`), the startup-pull toast wording (`d4c21377`), and the whole of Gaia's synced data (9 `gaia_*` collections now in `FirestoreCollections.records`, plus Gaia's remote-control collections outside it).
7. **Re-checking the MD bugs** from the phone side: the fixes were verified desktop ↔ desktop (§6).

The rules from `TEST_PLAN.md`, `MULTI_DEVICE_SYNC_TEST_PLAN.md` §1 and `MOBILE_TEST_PLAN.md` all apply: no app code changes, `voyager-qa-*` accounts only, `guard.ps1` on the desktop and `phone.ps1 check` on the phone before anything destructive, bugs logged in `qa/BUGS.md` as found (**next ID: BUG-384**, or whatever the mobile run has reached; **next free account: qa-129** or later), and a SESSION END on **both** devices.

---

## 0. Status

| Part | Section | Status |
|---|---|---|
| Rig sanity | MS-0 | Not Started |
| Phone joins an account with data; desktop joins a phone-made account | MS-1 | Not Started |
| Live propagation, every collection, both directions | MS-2 | Not Started |
| Collaborative text across SDKs (CRDT) | MS-3 | Not Started |
| Snapshot records, panels, field merges, settings | MS-4 | Not Started |
| Deletes, Trash, erase, tombstones | MS-5 | Not Started |
| Phone lifecycle vs sync | MS-6 | Not Started |
| Real per-device offline | MS-7 | Not Started |
| Reminders, devices, notifications across platforms | MS-8 | Not Started |
| Startup pull vs live sync on the phone | MS-9 | Not Started |
| Media across SDKs | MS-10 | Not Started |
| Account lifecycle across devices | MS-11 | Not Started |
| Backup, restore & import across devices | MS-12 | Not Started |
| Photos and vault across devices | MS-13 | Not Started |
| Gaia data across devices | MS-14 | Not Started |
| Shared locks (weather) | MS-15 | Not Started |
| Seeds and built-in records | MS-16 | Not Started |
| Soak | MS-17 | Not Started |
| Three devices (optional) | MS-18 | Not Started |

---

## 1. Setup

### 1.1 Topology

| Device | How | Role |
|---|---|---|
| **D** (desktop) | dev profile `qa` (`-Profile qa`), debug build of the working tree | Windows: C++ Firestore SDK, REST media |
| **P** (phone) | Juno's OnePlus 12R (Android 16) over USB, debug APK of the **same commit** | Android: native Firestore and Storage SDKs |
| **B** (optional) | dev profile `qb` | A second desktop, for MS-18 only |
| Juno's install | the normal instance | **Never touched**, as in MD §1.1 |

Both D and P must run the same commit. Record `git log -1 --oneline` and `git status --short lib/` once, plus both `deviceId`s and both log names.

### 1.2 Bring-up (per session)

1. **D:** `session_start.ps1 -Email voyager-qa-0NN@example.com [-SignUp] -Profile qa` → `GUARD OK`. Park it (`voy.ps1 -Profile qa do "park"`) so it never takes Juno's screen.
2. **P:** the phone SESSION START from `MOBILE_TEST_PLAN.md` M0, on the **same** account. Add the account's UID to `qa/harness/phone_accounts.txt` first. `phone.ps1 check` must print that UID.
3. **Every call names its device:** `-Profile qa` for D, `phone.ps1` / `-Profile phone` (M0's VM-service wrapper) for P. Never a bare `stop.ps1`.
4. Turn on **Dev → Verbose sync** on both (device-local).
5. Set the standard phone configuration (portrait, airplane off, font scale 1.0, Do Not Disturb on) at the start. At the end, restore Juno's own values (PROGRESS.md §1b).

### 1.3 Oracles

As MD §1.3, adapted for the phone:

- **O1 Row diff D↔P.** `dbdiff.py <D's db path> <P's pulled db dir>`. P's DB is pulled with its WAL (M0's `phone_db.ps1`) **right before** the diff; a stale pull is a false diff. `dbdiff.py` takes paths already. Check that its device-local column list still matches `settingsSyncPayload` (Gaia and the default-page settings were added after MD).
- **O2 Firestore.** `fs_snapshot.sh <uid>`. **Extend it first:** at MD time it covered 62 collections plus `settings`; `FirestoreCollections.records` now also has `gaia_chats`, `gaia_messages`, `gaia_settings`, `gaia_drafts`, `gaia_memories`, `gaia_queue`, `gaia_btw`, `gaia_projects`, `gaia_memory_topics` (check the file for any more at session start). The remote-control collections (`gaia_devices`, `gaia_commands`, `gaia_live`, `gaia_beacons`, `gaia_notify`, …) are outside `records`; read them separately when MS-14 needs them.
- **O3 Outbox drained** on both (`pending_uploads_table` = 0, queued and parked).
- **O4 In-app check.** Dev → "Check every collection against the cloud" on **both** reports safe; the journal / to-do compare tiles report no mismatch. Dev is reachable on the phone through the nav settings (More sheet).
- **O5 UI without a restart.** The receiving device shows the change without a restart. On the phone that means without a force-stop **and** without leaving the page. A change that shows only after the phone is backgrounded and resumed is noted as such: it's not a pass for live sync, but it may be the designed behaviour for a paused app (MS-6).
- **O6 Clean logs.** D's run log and `voyager_errors.log`; P's `flutter` log and `adb logcat` (no `FATAL`, no `ANR`, no FlutterError).
- **O7 Latency.** From the writer's save to the receiver's row change. On D, `wait_row.py` polls the DB. On P, polling by repeated `adb` pulls is too slow (a pull takes about a second); poll the row by VM eval on P instead (a `wait_row_phone.ps1` built on M0's `vm.ps1 -Profile phone eval`). Record a median of 3 and the worst case per MS-2 row, and compare with MD-2's desktop ↔ desktop numbers.
- **O8 Lifecycle state.** For every MS-6/MS-7 step, record P's state when the change landed (foreground, paused, Doze, killed, offline) and when it was observed.

### 1.4 What this rig newly allows

- **Real offline on one device only:** airplane mode on P while D stays online, and D's Force offline while P stays online. MD-9's cases with a real outage, and with sign-in and weather cut too.
- **A flaky link on one device:** a Wi-Fi/data/airplane toggle loop. A *slow* link (`adb emu network speed`) was emulator-only; on the phone it goes on PROGRESS.md §6b's list.
- **A second timezone, maybe a second clock:** only if M0 found a way (root image or settings route). If not, these stay unit-test only, as MD §1.4 said; state that in the results.
- **A device that gets frozen and killed by the OS,** and alarms that fire without the app running.

### 1.5 What it still can't do (state in results, don't work around)

- Two **phones**: one phone only (the emulator could be a second one, but it costs 5.4 GB of RAM and heats the laptop; only if Juno asks).
- Real-hardware lifecycle: covered now, since P is a real OnePlus. Record what OxygenOS's background killing does to sync, and judge whether it's a Voyager bug or a platform limit.
- Exact-millisecond collisions and time-based expiry: as MD §1.4 (craft stamps with `evalc`, age rows with the app stopped, and label them simulated).
- Clicking a Windows toast (MANUAL-ONLY, as before). Tapping a phone notification **is** allowed (Voyager's own notifications, through `phone.ps1`; never another app's).

---

## 2. Gaps this plan closes

| Where | Gap | Test here |
|---|---|---|
| MD §1.4, FV-5 | A second device in another timezone | MS-8.6, MS-4.7 (if M0 can set the zone) |
| MD §1.4, P25, P26 | A real network cut on one device (Force offline left sign-in and weather up) | MS-7 |
| MD-9, MD-10 | Offline and startup-pull behaviour of a process that the OS pauses, freezes and kills | MS-6, MS-9 |
| P6 Skipped, MD-8 | Reminders delivered by a different OS mechanism (scheduled Android alarms) while another device acks or edits the rule | MS-8 |
| MD-11, MD-18 | Media written by one Storage implementation (native) and read by another (REST), both ways | MS-10, MS-13 |
| PHOTO_SERIES_HLD §16, P28A out of scope | A check-in **captured on the phone** reaching the desktop | MS-13 |
| GAIA_REMAINING_TESTS §D, BUG-363 | Gaia history on the phone; messages written while one device was signed out | MS-14 |
| After MD-18 | Default journal/list/calendar switching, sync performance work, Firebase SDK update, Gaia collections | MS-2, MS-4, MS-14 |
| MD bugs (§6) | Every Major/Blocker sync fix re-checked with one side on the native SDK | §6 |

---

## 3. Tests

Conventions: as MD §3. **D** and **P** are on the same account. Run every two-way test **in both directions** (D→P, then P→D). A failure in one direction only is a finding in itself, and here it may point at one SDK. Unless a test says otherwise it passes when O1 shows no difference after both outboxes drain (O3), O5 holds on the receiver, and O6 is clean. Writes on the phone go **through the UI by touch** where the test is about user behaviour; where the test is about the data path, a VM eval through the app's repositories (MD-2's method) is allowed and is labelled.

### MS-0 Rig sanity
- [ ] D and P on the same account: `guard.ps1 -Profile qa` OK, `phone.ps1 check` prints the same UID.
- [ ] Different `deviceId`s. Settings → Devices on both lists `ZephyrusG14 [qa]` and the phone (platform Android), each marking itself "This device".
- [ ] A journal-entry title typed on D reaches P (O7), and one typed on P reaches D. `dbdiff` → SAME; `fs_snapshot` reads every collection, including the new Gaia ones.
- [ ] Juno's install untouched (MD-0's checks). The phone's install holds no other account (`phone.ps1 check`).

### MS-1 Joining an account
Before: D on a **fresh** account seeded as MD-1 (one record on every page, renamed default calendar, non-default synced settings including nav order, hidden pages and **default journal / list / calendar**, custom quote, two journals, starters used, a renamed job stage), plus a Gaia chat with messages, a project and a memory, and a Photos series with check-ins. Outbox 0, O4 safe.

- [ ] **1.1** P signs in **while D keeps running**. P's startup pull completes; time it (compare with D's own cold re-login). O1 D = P; O2 shows nothing re-stamped by P except its device registration (BUG-044's regression check, now with a native-SDK joiner).
- [ ] **1.2** P lands on the startup page the pulled settings name (BUG-011), its bottom bar follows the pulled nav order and hidden pages, and its default journal/list/calendar follow D's (`79f5c468`, BUG-228's class).
- [ ] **1.3** Every page on P shows D's data without a restart (BUG-010/043's class), including Photos (locked until the vault password) and Gaia chats.
- [ ] **1.4** The reverse: sign up a fresh account **on P**, seed it on P (by touch for a few records, by eval for the rest), then sign D in. The same checks. A phone-first account is the realistic case for a new user and was never tested. Built-ins and seeds: MS-16.
- [ ] **1.5** P joins with **Home pressed mid-pull** and comes back after 30 s; and with `am kill` mid-pull, then relaunch. The pull resumes or restarts and completes; nothing pulled twice (MD-10's kill case on Android).

### MS-2 Live propagation of every synced collection

For each row in MD-2's table (Journal, Dreams, To-Do, Calendar, Analytics/trackers incl. counter adjustments, Finance, Life, LeetCode incl. cheat sheet, Rankings incl. repeat counts and location branches, Jobs, Study, Workout, Inbox, Text tools, Devices), **create → edit → delete on the writer, observe on the receiver**, both directions. Media → MS-10, Settings → MS-4, Photos → MS-13, Gaia → MS-14.

- Writes on P: by touch for at least one action per row; the rest by eval (labelled).
- Record O7 per row in a table beside MD-2's numbers. A row that's much slower in one direction is a finding (SDK).
- [ ] **2.1** Every row, D → P, with P **in the foreground on that page**.
- [ ] **2.2** Every row, P → D, with D parked on that page.
- [ ] **2.3** The page open on P while the change lands keeps P's scroll position, selection and open sheet (MD-2.1, now with the compact layouts: Journal's editor alone on screen, To-Do's panel as a phone surface).
- [ ] **2.4** Pages P has never opened this run, and pages behind the More sheet: correct when first shown (MD-2.3).
- [ ] **2.5** Search on P finds text D just added and stops finding text D removed (MD-2.5).
- [ ] **2.6** Derived views on P (Analytics tiles, Finance hero and charts, Life stats) recompute after D's change (MD-2.6).
- [ ] **2.7** The counter statistic and the rankings repeat counter (new pages in the mobile plan, M10/M14): + on D and + on P within the same second → both counted (counts are additive per HLD, `counter_adjustments` / `ranking_counts`); − and + across devices; one device offline (MS-7 pattern).

### MS-3 Collaborative text across SDKs (CRDT)

The journal body, dream body and task notes (`FirestoreCollections.crdtBacked`). MD-3 found the worst bugs of the desktop run here. The phone types through Gboard's **composing region** (the in-progress underlined word), which edits text differently from a hardware keyboard: a word can be replaced as a whole when Gboard autocorrects it, and the app's own autocorrect acts on soft-keyboard input on Android (`MOBILE_TEST_PLAN.md` §0.1). That makes different character ops from anything MD-3 produced.

- [ ] **3.1** P types a paragraph by soft keyboard (with Gboard autocorrect and suggestions on) into a journal body that D has open: D shows exactly P's final text, with no doubled or lost letters. Repeat with a swipe-typed word and with a suggestion-strip pick. Check the ops with `fs_ops.py --ops`.
- [ ] **3.2** D types into a body that P has open in the compact editor: P shows it live, the caret stays where P left it, and P's next keystroke doesn't revert D's text (**BUG-220**).
- [ ] **3.3** Both type at the same spot at the same time (MD-3's `together.ps1` pattern, with a phone-side runner from M0): converge, with no letter-by-letter interleaving (**BUG-235**). Then at different spots.
- [ ] **3.4** Task notes: D's notes edit arrives in P's open task panel, P types again, P selects another task: the field shows the other task's notes (**BUG-236**, Blocker).
- [ ] **3.5** Undo on P after D's text arrived (with a hardware keyboard Ctrl+Z, and through whatever soft-keyboard undo route M3 found): undoes P's own edit, not D's (**BUG-237**).
- [ ] **3.6** P types, then is killed (`am kill` within 1 s of typing) before upload; D edits the same body; P relaunches: P's text is kept and merged, not overwritten by the startup pull (**BUG-238**). Repeat with Home → Doze instead of a kill.
- [ ] **3.7** The title changed on D while P is typing in the body: P's title field picks it up and P's body save doesn't revert it (**BUG-240**).
- [ ] **3.8** Concurrent edits with P **offline** (airplane mode) for 5 minutes and D online, both typing in the same body; P reconnects: one merged text, both contributions present (MD-3.15 with a real outage).
- [ ] **3.9** Large text: a 41k-char body edited on both sides; a 5,000-char paste on P while D types elsewhere in the body.
- [ ] **3.10** A journal entry seeded on one device and typed into on the other right away (MD-3.8, the seed-meets-ops case).

### MS-4 Snapshot records, panels, field merges, settings
- [ ] **4.1** Stale panels on the phone: open a record's sheet on P (to-do panel, transaction sheet, event panel, job panel, Study card editor), change the same record on D, then save P's sheet after changing an **unrelated** field. Does P revert D's change (**BUG-233**)? And the reverse (D's panel, P's change). Also close P's sheet by **drag** and by **Back**, which desktop couldn't do: does either save the stale copy?
- [ ] **4.2** Event times: an event made on D at 3–4 PM opens on P at 3–4 PM, and one made on P opens right on D (**BUG-234**, UTC display of pulled times).
- [ ] **4.3** Overlapping edits to the same snapshot record within ~50 ms online and while one side is offline: compare with **BUG-241**'s documented behaviour (it may be by design now; check its BUGS.md status first).
- [ ] **4.4** **Settings:** every synced setting changed on D reaches P live, and the reverse, including theme, accent, nav order and hidden pages (P's bottom bar and More sheet update in place), startup page, week start, Vim, autocorrect, snippet expand key, sounds, weather location, and the default journal/list/calendar. **Device-local** settings (PROGRESS.md list, plus anything Android-only, such as pane widths that mean nothing in compact) stay local on both. Check with O1's settings filter.
- [ ] **4.5** A setting changed on P while P is offline, and a different one on D meanwhile: both survive (settings use `runTransaction`, SECURE_NOTES_HLD; a transaction fails offline, so P's goes to the outbox).
- [ ] **4.6** Rankings location branches edited on both (MD-4.6, P19B AC 10), with P adding a branch by a long-press pin.
- [ ] **4.7** Timezone (only if M0 can set P's zone): P in a zone east of UTC, D in Toronto. A transaction in P's evening, an all-day event, a to-do due date, a journal entry date: each shows on the right day on both (desktop BUG-106's untested half, FV-5).

### MS-5 Deletes, Trash, erase and tombstones
- [ ] **5.1** Delete on D → gone on P live; Undo on D within the toast → back on P. The same from P.
- [ ] **5.2** Delete a task on D while P types in its notes (**BUG-245**): one outcome on both and in the cloud.
- [ ] **5.3** "Delete from Firestore permanently" (Dev, QA account only) on D, then P's next keystrokes in that entry (**BUG-247**).
- [ ] **5.4** "Delete forever" in Trash on D while P has the task panel open (**BUG-248**).
- [ ] **5.5** Restore from Trash on P → reappears on D with its children (restore contracts across devices).
- [ ] **5.6** Delete on P while P is **offline**, D edits the record meanwhile, P reconnects: the result matches TRASH_HLD (MD-5's erase-vs-edit rules).
- [ ] **5.7** A delete on P followed by `am kill` before upload: the delete still reaches D after relaunch.

### MS-6 Phone lifecycle vs sync (new)

Record O8 for every step. "Lands" = the change reaches Firestore; "shows" = P's UI shows it.

- [ ] **6.1** P backgrounded (Home) for 1 min, 10 min and 60 min while D makes changes on 3 pages. On resume, P shows all of them: how fast, and through what (live listeners re-attaching, or the catch-up pull, `catchUpIfAway`)? Was anything applied twice?
- [ ] **6.2** P in **Doze** (`force-idle`) while D changes things; then unforce and open P. The same checks.
- [ ] **6.3** P **killed in the background** (`am kill`) while D changes things; reopen from Recents. The startup pull brings everything; P's restored page shows it.
- [ ] **6.4** **App Standby** (`am set-inactive true`) and "Don't keep activities": the same checks.
- [ ] **6.5** P makes an edit and immediately goes to Home. Does the upload finish while backgrounded (D shows it within the latency budget), or only when P is next opened? Record the time Android allows. Repeat with the screen turned off instead of Home, and with Home followed by Doze within 5 s.
- [ ] **6.6** P makes 50 edits offline, goes to Home, comes back online **while still backgrounded**: does the outbox drain in the background, or wait for the foreground?
- [ ] **6.7** Overnight-style gap: P backgrounded for several hours (or Doze for 1 h with maintenance windows) while D edits heavily (100+ changes over many collections). Resume: convergence, time to converge, and no UI freeze on P while it applies the batch (watch frames, as MD-9.5 did).
- [ ] **6.8** Rotation on P while a live change arrives on the open page: no lost change, no duplicate, state kept.
- [ ] **6.9** P rebooted (`adb reboot`) with a non-empty outbox: after boot and app open, the outbox drains.
- [ ] **6.10** `am force-stop` with a non-empty outbox → relaunch → drains (MD-9.6's kill on Android), with D watching for duplicates.

### MS-7 Real per-device offline (new)
- [ ] **7.1** P in airplane mode makes 20 mixed edits over 5 kinds; D, online, edits **other** records of the same kinds; P back online → converge, and D gets P's edits live (MD-9.1 with a real outage). Record when P's writes reached `pending_uploads_table` (immediately, or after the 45 s write gate).
- [ ] **7.2** The same on the **same** records (MD-9.2; compare with BUG-241's status).
- [ ] **7.3** P offline while D edits a record 10 times, then P edits it offline and reconnects (**BUG-256**): P's edit isn't lost and versions are monotonic on both.
- [ ] **7.4** P offline while D creates, edits and deletes X; P reconnects: P never shows X, or shows it tombstoned (MD-9.3).
- [ ] **7.5** P offline for 2 hours with edits on both sides across many collections (Juno keeps working; the phone sits on USB): reconnect, converge, nothing lost. Then the reverse with D's Force offline for 2 hours and P online.
- [ ] **7.6** P on a flaky link (`network speed edge`, `network delay gprs`, or airplane toggled every 5 s) during a 300-write drain from P: no loss, no duplicates on D.
- [ ] **7.7** Wi-Fi → mobile data switch on P mid-drain (`svc wifi disable` with data on, then back).
- [ ] **7.8** Airplane mode toggled 10× on P while D writes continuously (MD-9.4): P's live sync recovers and has no stuck ids.
- [ ] **7.9** LeetCode cheat-sheet entries saved several times on P while offline: every save reaches D after reconnecting (**BUG-279**).
- [ ] **7.10** Sign-in on P while offline (fresh install) → a clear error; sign in online, then go offline straight after the pull starts.

### MS-8 Reminders, devices and notifications across platforms
On D the app raises due alerts itself while running; on P, Android alarms fire with the app closed (`reminder_os_notifier.dart`). Delivery states sync per device.

- [ ] **8.1** A scheduled rule created on D, targeting **both** devices, while P's app is **closed** (backgrounded, then killed with `am kill`; not force-stopped, since Android drops a force-stopped app's alarms by design). **Expected (Juno, 2026-11-22): it rings on P at its time without P's app being opened.** If it doesn't ring, that's a bug (Major: a reminder silently missed). Check `dumpsys alarm` / `dumpsys notification` on P before and after the fire time. The code as of this plan schedules alarms only from inside the running app, so expect this to fail; log it with the evidence. Then open P once and close it: the alarm is scheduled and fires (the fallback that works today).
- [ ] **8.2** The rule fires on both. Acknowledge on D → P's sticky clears live (if open), and P's OS notification is withdrawn? (P is closed: does anything withdraw it?) Acknowledge on P → D's sticky clears.
- [ ] **8.3** Snooze on P → D shows the snooze; the snoozed alert fires on P at +10 with P killed in between. Does D re-alert too, per the HLD's per-device rules?
- [ ] **8.4** Device chips: a rule for **P only** doesn't alert D, and a rule for D only doesn't schedule on P. Rename P on D's Devices list → P shows the new name.
- [ ] **8.5** Same expectation as 8.1 for changes: a rule **edited** on D (time moved) while P is closed rings on P at the **new** time, not the old one; a rule **deleted or turned off** on D doesn't ring on P. Either failing with P closed is a bug (part of 8.1's bug, or its own entry if the cause differs). Also record what happens on P's next open, and whether tapping a stale notification for a deleted rule opens gracefully.
- [ ] **8.6** Timezone (if settable): P in another zone. A daily rule at 9:00 fires at 9:00 local on each device (or at the same instant, per the HLD; record which and compare with SCHEDULED_REMINDERS_HLD).
- [ ] **8.7** Entity bells, with the same expectation as 8.1 while P is closed: a bell added on D to a task or event rings on P; the due time changed on D rings at the new time; a task completed or an event deleted on D doesn't ring on P.
- [ ] **8.8** Inbox dismissals, hidden/restore and pinned notes across devices (MD-8's inbox rows, from the phone's inbox).
- [ ] **8.9** Secure Notes: unlock on P doesn't unlock D; a note edited on D shows on P after P unlocks; a conflicting edit (both edit the same pinned note) → the conflict detection SECURE_NOTES_HLD Phase 1 describes.

### MS-9 Startup pull vs live sync on the phone
- [ ] **9.1** A cold re-login on P (sign out → `pm clear` → sign in) of a big account (qa-026's size, or seed one): time it, and edit on P during the pull (journal, to-do, transaction), as P26 did on desktop. Re-check **BUG-221** (the to-do lost during a pull).
- [ ] **9.2** D edits during P's startup pull: P ends with D's edits (MD-10.2 with a native-SDK puller).
- [ ] **9.3** P types into the journal entry that opens by itself at launch while the startup pull runs and D adds text to the same entry (**BUG-258**).
- [ ] **9.4** The pull toast's wording on P ("sync" unless the device never synced, `d4c21377`).
- [ ] **9.5** P's pull interrupted by Home, rotation and a kill (MS-1.5 on a reused account).

### MS-10 Media across SDKs
- [ ] **10.1** An image added on P (native Storage) shows on D (REST download), and one added on D (REST upload) shows on P. Check `media_assets_table.upload_state` and Storage on both sides.
- [ ] **10.2** Two images added on P within a second, then two on D (the C++ SDK deadlock that made Windows use REST shouldn't apply to P; record it).
- [ ] **10.3** An image added on P offline uploads on reconnect, and D gets it (**BUG-223** with a native uploader).
- [ ] **10.4** Download off on P → placeholders for D's images; on → they download. Upload off on P → P's image stays `localOnly` and D sees what the HLD says (MEDIA.md).
- [ ] **10.5** Remove an image on D → P's copy is unreferenced and kept 30 days, per MEDIA.md.
- [ ] **10.6** A 10 MB image from P on a slow link (`network speed edge`): progress, no ANR, D gets it complete.
- [ ] **10.7** Re-check MD-11's bugs (BUG-260 … BUG-265, all Minor) from the phone side where the fix touched shared code.

### MS-11 Account lifecycle across devices
- [ ] **11.1** Sign out on P while its outbox drains, then sign back in (**BUG-267**): sync works both ways without a restart.
- [ ] **11.2** P signs into another QA account and discards unsynced changes; later the first account signs in on P again: the discarded changes don't come back (**BUG-268**). Note: the native SDK's own offline write queue is where they came back from on desktop.
- [ ] **11.3** P edits offline less than 45 s before switching accounts: the "Discard unsynced changes?" warning appears (**BUG-269**).
- [ ] **11.4** Password changed on D: what happens to P's session (it may stay valid until a token refresh; record and compare with the HLD/auth expectations).
- [ ] **11.5** Sign out on D while P stays signed in and live: P is unaffected.

### MS-12 Backup, restore & import across devices
- [ ] **12.1** Restore a backup on D while P is live on the same account; then P types in a restored journal entry (**BUG-270**, Blocker): P keeps the restored text and adds to it, and D's text isn't wiped.
- [ ] **12.2** An entry open in P's editor during D's restore (**BUG-271**): P's next keystroke doesn't put the pre-restore text back.
- [ ] **12.3** P typing in the entry while D restores (**BUG-272**): the devices end up agreeing.
- [ ] **12.4** The reverse: restore on **P** (from P's automatic backups list, and from an imported ZIP) while D is live. D follows.
- [ ] **12.5** Import on P while P is offline (real airplane mode), then reconnect: D gets everything.

### MS-13 Photos and vault across devices
Run with MD-18's notes open; P28A/B and M18 cover each side alone.

- [ ] **13.1** A check-in **captured on P's camera** (with the ghost) appears on D after D unlocks: the images decrypt and the angles, date and note match. Ciphertext blobs in Storage only (no plaintext anywhere).
- [ ] **13.2** A check-in made on D (file picker) appears on P after P unlocks.
- [ ] **13.3** Vault: set up on D → P asks for the same password; change the password on P → D needs the new one, and every photo still opens on both; reset the vault on one device → the other's state per the HLD.
- [ ] **13.4** Alignment on P (touch) → D shows the aligned frames; "Use as reference" on D → P's ghost uses it.
- [ ] **13.5** Series deleted on D → cascades on P (series, angles, check-ins, images, blobs); restore from Trash on P → back on D.
- [ ] **13.6** Series reminders: a series reminder fires on P (Android notification) and on D (if it targets both); a check-in on D before P's fire time → P's alert is cancelled on next open, or auto-acknowledges (§13).
- [ ] **13.7** P captures offline; reconnect: blobs upload, D gets the check-in.

### MS-14 Gaia data across devices
This is the **data sync** of Gaia's records (`gaia_chats`, `gaia_messages`, `gaia_message_chunks` if synced, `gaia_drafts`, `gaia_memories`, `gaia_memory_topics`, `gaia_queue`, `gaia_btw`, `gaia_projects`, `gaia_settings`). The phone's remote control of the beacon is mobile Phase M19. D must not be running a real model turn here: use the dummy replies.

- [ ] **14.1** A chat and its messages from D appear on P, and a chat started on P appears on D (O1 over the Gaia tables).
- [ ] **14.2** **Drafts:** typing in a chat's composer on D appears as a draft on P, and the reverse (`d5e2e64d`); both typing in the same draft.
- [ ] **14.3** Projects, memories and topics created, renamed, moved and deleted on one device → the other (the GAIA_PROJECTS / MEMORY_TOPICS sync passes ran desktop ↔ desktop; now with the phone).
- [ ] **14.4** Queue: add and reorder on P → D; pop on D → P.
- [ ] **14.5** Messages written on D while D is **signed out** (**BUG-363**, open, Major): do they reach P after D signs back in? (GAIA_REMAINING_TESTS §D.)
- [ ] **14.6** P offline while D's chat grows by 50 messages; P reconnects: the chat is complete and in order on P, with no duplicates.
- [ ] **14.7** Delete a chat or project on P → trash on both; restore on D → back on P.

### MS-15 Shared locks (weather)
- [ ] **15.1** Weather location set on P (through the `cloud_functions` plugin) → D shows the same location and forecast; the `sync_locks/weather_fetch` lock is respected across devices (MD-14's `fs_watch.py` method): only one fetch per window, whichever device asks first.
- [ ] **15.2** P offline at the refresh time; D refreshes; P reconnects and shows the cached forecast from the cloud.

### MS-16 Seeds and built-in records
- [ ] **16.1** Phone-first account (MS-1.4): the starters P seeds at sign-up (exercises, stages, companies, plans) aren't doubled when D signs in and seeds its own (MD-16, FV-38). The default calendar made on P isn't overwritten by D's sign-in (**BUG-045**'s class, reversed).
- [ ] **16.2** Built-ins renamed on P (default calendar, To-do list, "Journal") → D keeps the renames after its own cold re-login.

### MS-17 Soak
- [ ] **17.1** 30 minutes of mixed use on both (scripted writes across many collections on D, touch use on P), with P backgrounded and resumed every few minutes, one airplane-mode minute on P and one Force-offline minute on D. End: both outboxes 0, O1 SAME, O4 safe on both, no memory growth on P (`dumpsys meminfo` before/after), no ANR.

### MS-18 Three devices (optional)
- [ ] **18.1** D, B (`qb`) and P on one account. P offline while D and B edit the same records; P reconnects; all three converge. Then B offline while D and P edit.
- [ ] **18.2** A record open in an editor on all three while one types: the other two follow live.

---

## 4. Out of scope (state in the results)

- Two physical phones; iOS (not a target platform, `platform_info.dart` folds it into "other").
- OEM battery killers on phones other than Juno's OnePlus.
- Real model turns and remote power actions in Gaia (M19's rules).
- Anything MANUAL-ONLY in PROGRESS.md §6 or `MOBILE_TEST_PLAN.md` §0.4.

## 5. Running it

- **Harness to add before MS-0** (on top of `MOBILE_TEST_PLAN.md` M0's phone scripts):
  - `fs_snapshot.sh`: the Gaia collections (O2);
  - `dbdiff.py`: check its device-local list against the current `settingsSyncPayload`, and that it reads a pulled phone DB directory with its WAL;
  - `wait_row_phone.ps1`: O7 on the phone by VM eval;
  - a phone side for `together.ps1` (MS-3.3): release a `phone.ps1` input run and a `voy.ps1` run at the same instant. The `adb` round trip is slower than posted Windows input, so record the release skew it achieves.
- **Order:** MS-0, MS-1, MS-2 first (they shake out the rig and give the latency baseline). Then MS-3, MS-6, MS-7 (the most likely new bugs). Then the rest in any order.
- **Per session:** as MD §5. Both devices up and checked, Verbose sync on both, record commits and IDs, log bugs as found, and SESSION END on both: D with `session_end.ps1 -Profile qa` → `SIGNED-OUT`; P with the phone SESSION END → `phone.ps1 check` says `signed out`, Juno's settings, Do Not Disturb and `stayon` restored.

---

## 6. MD bugs to re-check from the phone side

The Major and Blocker bugs from the desktop multi-device run, plus the sync bugs from P26 and Gaia. Check each one's status in BUGS.md first. For a fixed bug, re-run it with the phone as **each** side, and add a note to its BUGS.md entry. For an open one, confirm it reproduces with the phone, and add a note saying whether the phone makes it better or worse.

| Bug | Severity | Short | Re-checked in |
|---|---|---|---|
| BUG-220 | Major | Remote body change into an open journal editor dropped | MS-3.2 |
| BUG-221 | Minor (listed because it loses data) | To-do typed during a cold sign-in's pull lost | MS-9.1 |
| BUG-223 | Major | Image that failed offline stays pending for good | MS-10.3 |
| BUG-233 | Major | Open sheet/panel writes its stale copy back on save | MS-4.1 |
| BUG-234 | Major | Pulled event times shown in UTC | MS-4.2 |
| BUG-235 | Major | Concurrent typing at one spot interleaves letters | MS-3.3 |
| BUG-236 | Blocker | Task notes field keeps the first task's notes after switching | MS-3.4 |
| BUG-237 | Major | Undo undoes the other device's text | MS-3.5 |
| BUG-238 | Major | Text typed before a kill lost if the other device edits first | MS-3.6 |
| BUG-240 | Major | Title change reverted by the other device's body save | MS-3.7 |
| BUG-241 | Major | Offline / near-simultaneous edits to one record diverge for good | MS-4.3, MS-7.2 |
| BUG-245 | Major | Delete while the other device types in notes: deleted on one, live on the other | MS-5.2 |
| BUG-247 | Major | Permanent remote delete undone by the other device's keystrokes | MS-5.3 |
| BUG-248 | Major | Delete forever undone by an open panel on the other device | MS-5.4 |
| BUG-256 | Major | Offline edit lost to the other device's older edits | MS-7.3 |
| BUG-258 | Major | Typing at launch during the pull loses the other device's text | MS-9.3 |
| BUG-267 | Major | Sign out mid-drain, sign back in: sync dead until restart | MS-11.1 |
| BUG-268 | Major | Discarded changes come back on the next sign-in | MS-11.2 |
| BUG-269 | Major | Offline edits under 45 s old wiped without the warning on account switch | MS-11.3 |
| BUG-270 | Blocker | Restored journal text wiped when another device types | MS-12.1 |
| BUG-271 | Major | Entry open elsewhere during a restore puts the old text back | MS-12.2 |
| BUG-272 | Major | Restore while the other device types: devices disagree for good | MS-12.3 |
| BUG-276 | Major | Both devices quarantine one entry; resolving on one leaves the other stale | MS-4.3 (run the MD-15 steps with P as one side) |
| BUG-279 | Major | Cheat-sheet entries saved several times offline lose all but the first | MS-7.9 |
| BUG-363 | Major (open) | Gaia messages written while signed out never upload | MS-14.5 |
