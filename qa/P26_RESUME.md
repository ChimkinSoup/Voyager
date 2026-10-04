# Phase 26 — resume note (Sync, offline, persistence & Dev page)

> **Historical.** Phase 26 was finished in a second session on 2026-10-03. The results, bugs (BUG-217…BUG-223) and remaining gaps are in `qa/TEST_PLAN.md` (Phase 26) and `qa/PROGRESS.md`; read those, not this file. LEAD A below turned out to be harness misuse; LEADs B and C became BUG-217 and BUG-222.

Written 2026-10-03 from the transcript of a QA session that hit its usage limit partway through Phase 26
(`C:\Users\Juno\.claude-2\projects\C--Users-Juno-Code-Voyager\cd428b7d-e20b-4f23-990d-90c781f807aa.jsonl`).
Build under test: `041a1ea` plus Juno's uncommitted Force-offline change (see TEST_PLAN P26 "Force offline is real offline").

**Read first:** `qa/PROGRESS.md` and `qa/TEST_PLAN.md` ("HOW TO RUN A PHASE SESSION" and "Phase 26"), then this file.
Then continue Phase 26 by the usual rules (no app code changes, QA accounts only, `guard.ps1` before anything destructive).

## State the cut-off session left behind

- **Nothing about P26 was written to the QA docs except:** `TEST_PLAN.md` phase table and P26 Status = In Progress, and a placeholder row for qa-026 in `PROGRESS.md` §2 ("(in progress)"). No P26 bug is in `BUGS.md`, no phase-log line, no handoff note. All findings below exist only in this file. **Next bug number: BUG-217.** No P26 checkbox in TEST_PLAN is ticked.
- **Account:** `voyager-qa-026@example.com` (password `qavoyager2026`, uid `btTpexvtw5bxqb6W1D5g9q7VWmm2`). The app was left running and signed into it (session_end was never run). First check: `voy.ps1 status`, then `guard.ps1`. If the app isn't running, `launch.ps1` brings it back signed in (persisted creds).
- **Dev flags left on in qa-026's settings:** `dev_show_cache_status = 1` (the overlay bottom-left hides the "New dream" button, among others; turn it off before UI work) and `dev_show_conflict_document_ids = 1`. `dev_force_conflict_ui` and `dev_disable_cache` were turned back off. Force offline is session-only, so it is off after any restart.
- **Data in qa-026** (all synced, outbox 0 at the last check, 2026-10-03 ~18:16 local):
  - Journal "P26 Journal" (`p26-journal`) with 300 entries `p26-je-000..299` (title "P26 entry NNN", body "P26 bulk body N lorem ipsum dolor sit amet"). `p26-je-000` was merged to `…amet' MERGED26'` (v2). `p26-je-002` has `' OFFEDIT1'` appended (v1, offline edit). `p26-je-003` is soft-deleted (v2, offline). `p26-je-005` holds a 41,430-char body ("… HUGE26 word1 word2 …").
  - To-do list "P26 List" (`p26-list`) with 300 tasks `p26-task-000..299`, all with notes `drain note <id>` (version 2, a few at 1 / 3). `p26-task-000` completed offline. Plus `P26 offline task`, `P26 after toggles`, `P26 dc task` in the default list.
  - Tracker `p26-trk` with 3,000 daily values (`p26-trk_YYYY-MM-DD`). 301 transactions (`p26-tx-*` ×300 + `OffStore` 12.34). Dream `P26 offline dream` / "dream body offline".
  - Non-default synced settings: accent `4289122697`, theme dark, `showQuotes` false, `weekStartsOnMonday` false. Default calendar `__legacy_calendar__` renamed to **"P26 Renamed Cal"** (Firestore doc `legacy-default-calendar`, version 1, updatedAt 21:46:46Z).
  - Cloud counts at the end: journal_entries 300, todo_tasks 303, tracker_values 3,000, transactions 301, dream_entries 1, calendars 1, settings 1 (`app`, 102 fields).
- **"Before" snapshot** for the cold-re-login-with-edits test: `qa/exports/p26-fs-before-cold.json` (output of `fs_snapshot.sh`, taken 22:16Z after all of the above). The settings document and calendar values above are the "before" values (re-read them from Firestore REST if you need the full docs: `…/users/<uid>/settings/app` and `…/calendars/legacy-default-calendar`).
- **Timing reference:** a warm-start `pullAll` with ~3,600 docs took **47.9 s** (journal_entries 46 s, todo_tasks 46 s, tracker_values 25.5 s), logged as `[sync] startup sync took 48305ms`. That was with Force conflict UI on, so a plain cold re-login may differ; measure one before the "during the pull" tests.
- **Helpers I preserved** (the old session's scratchpad is not reachable from a new session): `qa/steps/p26-tl.ps1` (eval a body file in the running app and wait for `SEED-OK <tag>`; set `VM_EXE` to a compiled `vm.dart` first, `-Lib features/dev/dev_page.dart` imports the dev providers), `qa/steps/p26-q.py` (read-only SQLite: `python p26-q.py "select …"` or `counts`), `qa/steps/p26-ob.py` (poll the outbox until empty: `python p26-ob.py 180 5`). Seed/step bodies already in `qa/steps/`: `p26-seed.dart.txt`, `p26-seed-tx.dart.txt`, `p26-repush-tasks.dart.txt`, `p26-task-notes.dart.txt`, `p26-off.dart.txt`, `p26-on.dart.txt` (the last two set `DevFlags.forceOffline`, the provider, and call `firestore.disableNetwork()` / `enableNetwork()`, matching the Dev toggle). Screenshots: `qa/shots/p26-*.png` (40).
- Shell gotchas hit: `dcg` blocks bash `for … $(…)` loops with command substitution (write a Python poller instead); a PowerShell `Substring(0, 60000)` on a shorter string threw but the clipboard paste still ran with the 41,430-char text.

## What was DONE (with results)

Everything here passed unless marked **LEAD** (a suspicious observation that was not yet confirmed or logged as a bug).

| # | What | Result |
|---|---|---|
| 1 | Fresh account qa-026 via `session_start.ps1 -SignUp`; standard config check (dark, scatter 1, wave 0, scale 15) | OK, `GUARD OK` |
| 2 | Bulk seed through the app's repositories: 300 entries, 300 tasks, 3,000 tracker values, renamed default calendar, non-default settings (accent, quotes, week start). Outbox drain + Firestore REST counts | Journal 300/300 and tracker 3,000/3,000 reached the cloud. See LEAD A for tasks |
| 3 | 2,921 `upload failed … Sync paused: 50 writes are still waiting for the server (limit 50)` lines during the seed | Known write-gate overflow (P13 saw it); outbox still drained to 0 |
| 4 | Outbox drain rate for to-do tasks | ~1.2 rows/s (250 rows in ~3.5 min). Transactions drain much faster (93 → 0 in 10 s) |
| 5 | **Dev page walk (partial):** scrolled the whole page; **Show cache status** on: overlay bottom-left, "14/14 cached" | Works. Overlay covers parts of the page (see LEAD D) |
| 6 | **Dev → Check every collection against the cloud** on the freshly drained account | Reported `safeToWipe: false`, 2 unsynced: the built-in plans `workout_plan_weekly` / `workout_plan_cycle` "(not in cloud)". See LEAD B |
| 7 | **Conflict banner** (Force conflict UI + Show conflict document IDs on, restart): banner appears after the startup pull; the resolve dialog shows local / remote and a manual-merge box; **Esc** closes it and the banner stays; typing into the merge box + **Use merged text** saves v2, clears the banner and uploads | Pass. (Only the "merged text" path was exercised: see NOT done) |
| 8 | **Offline writes through the UI** (Force offline on, via `p26-off.dart.txt`): edit a journal entry, delete a journal entry, add a to-do task (Ctrl+Alt+T), complete a task, add a transaction (Ctrl+Alt+F), create a dream. That is journal, to-do, finance and dream = 4 kinds (+ the task-completion row) | All saved locally and queued: 9 outbox rows (journal_entries ×3, todo_lists, todo_task_completions, todo_tasks ×2, dream_entries, transactions) |
| 9 | **`stop.ps1` with the outbox non-empty** (9 rows, Force offline still on) → `launch.ps1` | Outbox drained within 10 s of relaunch; Firestore has the edit, the soft-delete (`deletedAt` set, version 2) and the 41,430-char body (length matches local exactly) |
| 10 | **Huge entry offline:** ~41 k chars pasted into an entry while offline | Saved, queued, drained, cloud length = local length |
| 11 | **Force offline toggled 10× quickly** (Dev switch, 120 ms apart) | Ended in the off state; a new task created right after reached Firestore (`_serverWrittenAt` 22:07:40Z), outbox 0 |
| 12 | **`stop.ps1` during a drain:** 300 task-note edits queued, killed at 163 queued, relaunched | Drained to 0 in ~75 s; all 300 notes are in Firestore (299 at version 2, 2 at 1, 1 at 3, i.e. nothing lost or duplicated) |
| 13 | **Dev → Disable caching entirely** on / restart / uploads / off: cache status reads "0/0 cached (0%)" (flag active); a task created while it was on uploaded at once (outbox 0); turned back off | Partly: see LEAD C (startup pull ran on 1 of 2 restarts) |

## LEADS found but not yet logged as bugs (confirm, then add to BUGS.md)

- **A. 264 of 300 to-do tasks never uploaded after the bulk seed, with an empty outbox and no failure lines.** The seed (`qa/steps/p26-seed.dart.txt`) did `upsertTask` + `r.pushTodoTaskNow(t)` without awaiting; only 36 tasks (and `todo_lists/p26-list` hit a write-gate failure) reached Firestore; the rest left **no outbox row**, so the device showed "synced" while the cloud lacked them. Re-pushing via `pushTodoTaskInBackground` (`p26-repush-tasks.dart.txt`) queued 250 rows that then drained. Same family as BUG-097 (a push that fails leaves no outbox row). Decide: harness misuse (an un-awaited `…Now` push dropped by the write gate) or app bug (a throwing/blocked `pushTodoTaskNow` leaves nothing queued). The code comment at `lib/core/sync/remote_sync_service.dart:4255-4290` says callers that can't await it should use `pushTodoTaskInBackground`; check whether any real UI path calls `pushTodoTaskNow` while the gate is full (e.g. a cascade or a quick run of task edits).
- **B. "Check every collection against the cloud" flags the 2 built-in workout plans as unsynced on an account that never opened Workout.** Both rows are untouched seeds (`version 0`, deleted_at null), and `lib/core/dev/full_sync_check.dart` ~L137 says an untouched seed is exempt ("every device seeds the same document for itself"). The exemption evidently isn't covering plans. Effect: `safeToWipe: false`, so `session_start.ps1` / the wipe gate would refuse a reset on a clean account. Related: BUG-204 and BUG-210 (seed rows). Confirm by reading the exemption code and `sync_check.json` (`%APPDATA%\Voyager\voyager\sync_check.json`).
- **C. Disable-cache flag: the startup pull still ran on the first restart** (`[sync] startup sync took 7202ms`, 163 docs), although `main.dart` returns early from the warm-up when `DevFlags.disableCache` is true. A second restart skipped it. Suspected race: the flag is read from settings (`main.dart` ~L304) after the post-auth warm-up (`_schedulePostAuthWarmup`, `_onAuthStateChanged`) may already have started. Needs a few more restarts to know how often.
- **D. (cosmetic)** With "Show cache status" on, the overlay hides most of the Dreams "New dream" button and part of the Dev page; a click on the error-log row landed on a cache row instead (the list grew when the toggle turned on).
- **E. (observation)** Offline write with Force offline on reached the outbox only after the write gate's 45 s timeout (expected per the change note); no row appears at once. The offline-edit session above worked because the app was killed ≥45 s later.

## What was NOT done (do these)

Tick the matching boxes in `TEST_PLAN.md` Phase 26 as you go. Account qa-026 already holds the data for most of them.

### Plan flows

- [ ] **Offline: all 5 kinds → outbox → go online *without restarting* → drains → cold re-login shows all.** Kinds done offline: journal, to-do, finance, dream. Not offline: a 5th kind (calendar event, tracker value, bucket-list, rankings, jobs, study, workout, …). The "back online" step was only ever done by relaunching; **toggle Force offline off in the Dev page with rows queued and watch the drain.** The cold re-login (sign out → in, wipe local) after the offline writes was never done: check every offline row, the soft-delete and the 41 k body survive it.
- [ ] **Deleting / editing offline while another kind is also queued** — only a delete of a journal entry was tried. Also try an offline delete + restore (Trash) and an erase of journal / dream / task text offline (the CRDT op-log wipe, TRASH_HLD §13.5; a P24 lead).
- [ ] **Dev → Disable cache on/off semantics:** repeat the restart 3–4 more times to measure how often the startup pull runs (LEAD C), and check that turning it off makes the next launch pull again. It was left off.
- [ ] **Sync compare / backlog tiles on a clean account show consistency.** Only "Check every collection against the cloud" was run (and it flagged LEAD B). Not run: **Sync backlog tile** (Unsent writes N / limit, Outbox N queued / M parked, read it while a drain is running and with a parked row), **Compare all journal entries**, **Compare all todo lists**, **Compare todo list with remote**, the compare log's view / copy / clear, **Check, then quit (before a wipe)** (only on a QA account after `guard.ps1`; BUG-204 says it skips starter exercises by name). Re-run "Check every collection" after the workout plans are created (open Workout once) to see whether `safeToWipe` turns true.
- [ ] **Conflict banner, other paths:** "use local" / "use remote" (whatever the dialog offers) and what a second launch shows once resolved. Only Esc and "Use merged text" were tried.
- [ ] **(P19B) Branch merge** (RANKINGS_MAP_HLD.md §5.4, AC 10, §10), all four cases, with the "other device" simulated by `evalc.ps1` writing the cloud copy through `syncRepositoryProvider`: X added here while Y removed there (both survive); X renamed here, X removed there later (gone); the reverse order (record who wins vs. the HLD); check `loc:<id>` stamps in SQLite and Firestore after each case. **Not started.**
- [ ] **(P19B) Offline map** with Force offline: pins still draw, cached tiles draw, uncached tiles don't, search shows "Search needs a connection", short links fail, a branch added offline queues in the outbox and uploads on reconnect. **Not started.**

### "Edits during a long startup download" (all 8 boxes untried)

Setup is done: qa-026 holds the 300/300/3,000 data, a renamed default calendar and non-default settings, and the before-snapshot (`qa/exports/p26-fs-before-cold.json`). Do one cold re-login first (`session_end.ps1` / `reset.ps1`-style sign-out + wipe, then sign back in; qa-026 must be signed in at `launch.ps1` for a plain restart) and time the pull. Then:
- [ ] During the pull: create a journal entry, a to-do task and a transaction. They survive the page refresh when the pull ends, are still there after a restart, and are in Firestore; all pulled rows are present.
- [ ] During the pull: change a synced setting (accent) before the settings are pulled. After the pull the other cloud settings (quotes off, week-start Monday off, dark theme) must NOT reset to defaults (BUG-001's consequence). Compare `settings/app` in Firestore before and after (current "before" values above).
- [ ] During the pull: rename the default calendar. Record which name wins (cloud "P26 Renamed Cal" vs. the local rename); compare BUG-045.
- [ ] During the pull: use each floater (Ctrl+Alt+T / J / F / R); entry, task, transaction, reminder all survive and upload.
- [ ] During the pull: navigate between pages. No errors in `voyager_errors.log` or the run log, and each page fills in when the pull ends.
- [ ] `stop.ps1` halfway through the pull, `launch.ps1`: the pull finishes next launch, nothing is missing, nothing is re-uploaded (diff `fs_snapshot.sh` before/after; the only new write times should be this device's registration and your own edits). FV-1's untried failure case.
- [ ] Normal launch (data already local): with a journal entry open and being typed into, have that entry change "on another device" before the startup pull (write the cloud copy through `syncRepositoryProvider` with `evalc.ps1`, then relaunch and keep typing through the pull). Nothing typed is lost; the other change is merged, not dropped.

### Dev page tiles not exercised

Seen only by scrolling (screenshots `qa/shots/p26-dev1..10.png`); no interaction beyond Show cache status, Force offline, Force conflict UI, Show conflict document IDs, Disable caching, and Check every collection:
- [ ] **Error log:** View error log, Copy to clipboard, Clear (the one click meant for "View error log" missed).
- [ ] **Perf stall log:** View / Copy / Clear. Careful: `Documents\perf_stall.log` is Juno's own file; don't clear it. Read only what this session appended.
- [ ] **Show FPS counter** (and that it doesn't leak into other pages).
- [ ] **Verbose sync logging** (payloads print to the debug console, i.e. the run log).
- [ ] **Show local save / Show upload / Show download** (the sync activity indicator): do they flash for a save, an upload and a pull; do they behave during an offline drain.
- [ ] **Show journal remote pull button** (what it pulls, and how that behaves with a dirty open entry).
- [ ] **Force reload local data**, **Device ID** (matches `settings_table.device_id` and the `device_registrations` doc), **Firebase Auth UID** (matches uid above).
- [ ] **Remote purge / Out-of-sync purge** (QA account only, `guard.ps1` first: they delete from the current account's Firestore; use a throwaway account or end of the session); **Purge soft-deleted items**, **Delete all journal entries / calendar events / Reset all journals** (confirm dialogs: cancel and confirm paths).
- [ ] Remaining toggles in the list are cosmetic/debug (Disable petal field, Life Tracker colors, time-selector hitboxes, slow animations, journal/todo-sort debug logs, leaf gallery, texture/wave tuning, Simulate failing backups): glance only if time allows. **Do not use** "Direct OpenWeather API" + key (MANUAL-ONLY).

### Plan items listed in the scope line that were not touched

- [ ] **Media upload/download toggles** (Settings → Data → Image storage; `MEDIA.md`): an image attached, upload off → queued/"not uploaded" state, back on → uploaded; download off + cold re-login → "Download disabled" placeholders (BUG-216 context); Force offline blocks media upload/download/delete per the change note.
- [ ] **Sync activity indicator / offline badge** behaviour (the badge appeared with Force offline; no screenshot-level check of it was recorded).
- [ ] **CRDT text merge sanity:** two edits to the same journal entry / task note merged (one "remote" edit written with `evalc.ps1` + one local); also the 60 k-char case at its real size (the paste above was 41 k) and typing while a remote op lands. `JOURNAL_DATA_LOSS_POSTMORTEM.md` and `SAVING.md` list the failure modes worth targeting (§1 op-log ID collisions across restarts, §2/§3 pending char ops consumed before upload, §10 self-echo suppression).
- [ ] **Remote-change simulation / live sync:** the plan says to simulate a remote change in a second login only if feasible, else document. Not tried; at least document that live sync between two devices can't run on one PC and do the `syncRepositoryProvider` simulation for one collection (live listener, not just the startup pull).
- [ ] **Failure case:** the cloud-write gate itself (50 unsent writes): what the user sees at the limit and that nothing is lost once it clears.
- [ ] **Leads inherited from earlier phases for P26** (PROGRESS.md §7 handoff): BUG-210 default rows (`__legacy_calendar__`, "Journal", "To-do") with a backup that holds them and a device that doesn't; BUG-097 (record whose payload can't be JSON-encoded leaves no outbox row; LEAD A is the same class); BUG-106 (UTC `occurred_at` after a pull, a Dec 31 / last-evening-of-month row); the settings merge with `qa/exports/p25-qa025.zip`; an offline backup restore with a real network cut; two-device edits can't be done (document); "erase while offline" (P24); BUG-198 workout-with-no-end-time on qa-009 (don't sign into qa-009 unless needed).

## Finishing the phase

1. Log confirmed bugs from the LEADS (and anything new) in `BUGS.md` from **BUG-217**; add Notes to BUG-097 / BUG-204 / BUG-210 / BUG-045 / BUG-001 where re-checked.
2. Tick `TEST_PLAN.md` P26 boxes, fill in "Covered" and "Skipped/blocked", set Status to Done (and the phase table row).
3. Update `PROGRESS.md`: replace the qa-026 account row's "(in progress)" with what the account holds, add the phase-log line, quirks (the DCG note, the cache-status overlay), and the handoff note for FV (FV-3…FV-11 still pending) and Phase 27.
4. Run `session_end.ps1`, then tell Juno the next phase and the bug counts by severity.
