# Voyager QA Audit — Progress (shared memory across sessions)

Read this whole file first, then `qa/TEST_PLAN.md`, then the last ~20 entries of `qa/BUGS.md`.

Setup session: 2026-09-27 (Phase 0). App build: `main` @ `e3f10f5`, Flutter debug run on Windows 11 (build 26200), one display 1440×900 logical @ 200% (2880×1800 physical).

---

## 1. Environment

### Storage (where the data lives)

| What | Where | Synced to cloud? |
|---|---|---|
| Main database (Drift/SQLite, ~60 tables) | `%APPDATA%\Voyager\voyager\voyager.sqlite` (+ `-wal`/`-shm`) | Yes. Every user table syncs to Firestore `users/{uid}/…` through the outbox `pending_uploads_table`. |
| Images (content-addressed blobs) | `%APPDATA%\Voyager\voyager\media\` | Yes (Firebase Storage) when "Upload images to the cloud" is on; `media_assets_table.upload_state` says which |
| Auto-backups (zips + `state.json`) | `%APPDATA%\Voyager\voyager\backups\` | **No, local only** |
| Drafts / device prefs | `%APPDATA%\Voyager\voyager\finance_ui_prefs.json`, `quick_journal_entry.json`, `jobs_track_draft.json`, `leetcode_track_draft.json` | **No, local only** |
| Study/LeetCode session checkpoints (resume toast) | `%APPDATA%\Voyager\voyager\session_checkpoints\` | **No, local only** |
| Firestore SDK offline cache | `%LOCALAPPDATA%\firestore\[DEFAULT]\voyager-db9de\` | (cache of the cloud) |
| Persisted Firebase sign-in | Windows Credential Manager, generic creds `voyager-db9de.firebase.auth/[DEFAULT][0..n]` (encrypted; the e-mail can't be read offline) | n/a |
| Logs | `%USERPROFILE%\Documents\voyager_errors.log`, `perf_stall.log` (Juno keeps `perf_stall.enabled` on), `journal_debug.log`, `todo_sort_debug.log`, `sync_compare.log` | No. **Shared with Juno's own use**, so note the file size at session start and read only what was appended |
| Launch at login | `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` value `Voyager` = `"C:\Users\Juno\AppData\Local\Programs\Voyager\voyager.exe" --hidden` (Juno's installed release) | No |
| Flutter run output (FlutterErrors, `[sync]` lines) | `qa/logs/run-<timestamp>.log` | n/a |

**Device-local settings.** These `settings_table` columns are left out of `settingsSyncPayload`: pane widths (journal list, dream split, edit side panel, workout library), `lastSeenNavPage`, `lastViewed{Journal,Todo,Calendar}Id`, `journalShowAllEntries`, `todoShowAllTasks`, `todoCompletedSectionExpanded`, `calendarShowAllCalendars`, LeetCode cheat-sheet tab and collapsed sections, all `dev*` flags (including `devOpenWeatherApiKey`), the weather cache, `deviceId` and `syncBackfillVersion`. Every other setting syncs.

**Local-only data check (done at setup).** Before the first wipe, Juno's local DB had outbox = 0 rows, 0 sync conflicts, and all 32 media assets `uploaded`, so nothing unsynced was lost. The local-only files (auto-backup zips, drafts/prefs JSON, session checkpoints, Documents logs) were copied to **`C:\Users\Juno\VoyagerQA-localonly-backup-2026-09-27\`**, outside the repo. Juno's local data was then wiped, as agreed.

### Harness (`qa/harness/`)

All scripts are Windows PowerShell 5.1. Run them with the **PowerShell tool** by literal path, from the repo root.

| Script | Does |
|---|---|
| `launch.ps1` | `flutter run -d windows --debug` in the background. Log goes to `qa/logs/run-*.log`; waits for the VM service and writes its ws URI to `qa/logs/vm_uri.txt`. ~1 min with a warm build. |
| `stop.ps1` | Kills every `voyager.exe` (the debug run *and* the installed release) plus the `flutter run` tool process. Leaves the Dart LSP alone. |
| `reset.ps1` | **Baseline reset**: stop, delete the Firebase sign-in creds (= sign out), delete `%APPDATA%\Voyager\voyager` and the Firestore cache. Verifies each step. |
| `sync_gate.ps1 -DataDir …` | Called by `reset.ps1` before it stops the app, signs out or deletes anything; `reset.ps1` also refuses while Voyager is still running. Throws unless the app's `sync_check.json` says nothing is unsynced **and** the database hasn't been written since that check. `reset.ps1 -Force` skips it. |
| `login.ps1 -Email voyager-qa-NNN@example.com [-SignUp] [-Password …]` | Types into the login page (maximized coordinates), then checks the account over the VM service. Refuses any non-QA e-mail. |
| `guard.ps1` | Exit 0 only if the running app is signed into `voyager-qa-*@example.com`. **Run before any destructive action.** Exit 3 = signed into another account: STOP. |
| `session_start.ps1 -Email … [-SignUp]` | reset → launch → login → guard |
| `session_end.ps1` | Relaunches Voyager if it crashed or was closed (so the account can be read), runs guard, waits (≤120 s) for the outbox to drain, then reset (with `-Force` only if guard confirmed a QA account) → prints `SIGNED-OUT` |
| `whoami.ps1` | Offline: is *any* Firebase sign-in persisted? (`SIGNED-OUT` / `SIGNED-IN-UNKNOWN-ACCOUNT`) |
| `evalc.ps1 -Lib <lib> -Tag <t> -BodyFile <file> [-VmExe …]` | FV session: runs Dart statements in the running app with `c` = its ProviderContainer, to seed data through the app's own repositories and uploads. Reports `SEED-OK`/`SEED-ERR <tag>` in the run log. Example bodies in `qa/steps/fv-seed*.dart.txt`. QA accounts only; guard first. |
| `fs_snapshot.sh <uid> <out.json>` (Bash) | FV session: read-only REST snapshot of 38 of a QA account's Firestore collections (every document's `_serverWrittenAt`), to diff before/after a re-login. |
| `voy.ps1` | Real input + window capture (below) |
| `vm.ps1 whoami \| shot <png> \| eval <libSuffix> <expr>` | Dart VM service client (wraps `vm.dart`) |
| `vimcase.ps1 <cases.tsv> [-VmExe …]` | Phase 3 field probe: Esc, set the focused field's text + caret over the VM service, send real keys, read back `selection\|mode\|length\|text` (non-ASCII as `\u{hex}`). Works on any focused text field (Vim ON or OFF). Case format in its header. |
| `Probe.cs` | Win32 side of `voy.ps1` (compiled by Add-Type; must stay C# 5: no `=>` members, no `$""`). Since Phase 5, `click`/`move`/`wheel`/`drag` also refuse a point outside Voyager's client area or covered by another window. |
| `OtherApp.cs` | Phase 5: a probe-owned WinForms "other app" (compiled with `Probe.cs` by `voy.ps1`). Verbs: `other-open [x y w h]` (opens topmost, raised by a real click, then not topmost), `other-click [dx dy]` (only if the form is the window under the point), `other-type`, `other-topmost on\|off`, `other-close`, `ostatus` (foreground owner, form text, hotkey hits, open popup menu), `other-grab <chord>` (another process owns a global hotkey), plus `tray-menu` (posted right-click → real tray menu) and `minimize`. The form lives only for one `voy.ps1` run. |

### SESSION START (procedure)

1. `& "C:\Users\Juno\Code\Voyager\qa\harness\session_start.ps1" -Email voyager-qa-NNN@example.com` (add `-SignUp` for a new account; take the next unused number from the account table below and add it there).
   - This fully quits Voyager (including Juno's installed release), signs out whatever account is persisted (Juno signs the real account back in between sessions), wipes all local app data, launches the debug build and signs the QA account in.
   - **Never type Juno's real credentials, never click "Continue with Google", never modify the real account.**
   - If Juno's real account was used since the last session, the reset refuses until Juno has run Dev page → **Check, then quit (before a wipe)** in Voyager. Only that check proves nothing would be lost; an empty outbox doesn't (the 2026-09-27 wipe). Don't bypass it with `-Force`: tell Juno.
2. It must end with `GUARD OK: voyager-qa-NNN@example.com`. Anything else: stop.
3. Reusing an account: its data comes back from its cloud copy through the startup pull. Wait ~10 s, then check the expected rows in SQLite (read-only) before relying on them.
4. Check the **standard test configuration** (TEST_PLAN.md): Juno's background settings are the app defaults since 2026-09-28, so a fresh account already has them. Check `settings_table.theme_mode='dark'`, `geometric_wave_scatter_mode=1`, `geometric_wave_enabled=0`, `geometric_texture_scale=15.0`. An account created before that date holds the old defaults: reset them in Dev → Geometric texture / wave tuning → Reset to defaults (petals by hand), or use a fresh account.
5. Note the current sizes of the `Documents\*.log` files, so you only read what this session appends.
6. If sign-up ever asks for e-mail verification, **stop and tell Juno**. Do not work around it. (At setup it didn't: sign-up lands straight on Journal.)

### SESSION END (procedure). Run it even if the phase stopped early

1. `& "C:\Users\Juno\Code\Voyager\qa\harness\session_end.ps1"`: lets the outbox drain so the QA account's cloud copy is complete, quits Voyager, signs out, wipes local data. It must print `SIGNED-OUT`.
2. Local data is wiped at the end on purpose. The local DB isn't per-account, so leftover QA rows could merge into Juno's real account when they sign back in on this PC.
3. Juno signs back in themselves. Don't do it for them.

### BASELINE RESET (procedure)

`reset.ps1`, then `launch.ps1`, then `login.ps1`; in one go, that's `session_start.ps1`. Tested at setup (2026-09-27), in order: reset from Juno's live state → launch → sign-up qa-001 → session_end → session_start qa-001 (sign-in path) → guard OK → session_end → `SIGNED-OUT`.
"Baseline" = a brand-new account (`-SignUp`) on an empty local DB. A reused account is baseline plus whatever that account put in its cloud copy.

**Mid-session reset without changing account** (e.g. "does it survive a restart?"): `stop.ps1`, then `launch.ps1`. The persisted sign-in and local DB survive. For a cold-cache restart of the same account (a full pull from the cloud), run `session_start.ps1 -Email <same>`.

### Interaction method (verified 2026-09-27, session unlocked)

**Real input into the native window via Win32 (`voy.ps1` + `Probe.cs`), with guards.** No UI Automation: Flutter exposes no semantics tree here. No integration_test either: that is a test suite, not a manual pass.

- `voy.ps1 run <steps.txt>` (preferred) or `voy.ps1 do "step; step; …"` runs a whole scenario in **one process**. Each separate tool call can take focus away from the app, so put a whole scenario in one run. Step verbs: `activate`, `key <chord>`, `type <text>`, `click x y [right] [N]`, `move`, `wheel x y notches`, `drag x1 y1 x2 y2`, `hotkey <chord>`, `wait ms`, `shot <name>`, `status`, `place x y w h`, `maximize`, `restore`, `close`, `tray-open`, `tray-quit`. The header of `voy.ps1` documents them. `do` splits on `;`, so text containing `;` needs `run`.
- **Guards:** every key/click is refused unless the foreground window belongs to `voyager.exe`. `hotkey` is only sent if some process has registered that global hotkey. Screenshots capture only Voyager's client area (`PrintWindow`), never the screen.
- **Coordinates are physical client pixels**, the same as the screenshot PNG (2880×1800 maximized). The image viewer shows these PNGs scaled to 2000×1250, so **multiply displayed coords by 1.44**. Rail items at x=88: Journal y=298, Dreams 418, To-Do 538, Calendar 658, Search 778, Analytics 898, Finance 1018, Life 1138, LeetCode 1258, Rankings 1378, Jobs 1498 (the rest scroll below; inbox tray icon ≈ y 1688).
- **Verified for real at setup:**

| Check | Result |
|---|---|
| Launch (`launch.ps1`) | Worked |
| Click (the login page's "Create account", fields, rail items) | Worked |
| Type (e-mail and password, journal body text) | Worked; real VK presses, shift for `@` |
| App shortcut `Ctrl+/` | Opened the shortcuts dialog |
| `Esc` | Closed the dialog |
| Global hotkey `Ctrl+Alt+T` with main focused | In-app path: navigated to To-Do |
| Resize (`place`) | Worked (clamped to the 1440×1040 min) |
| Maximize | Worked |
| WM_CLOSE | Window hid to the tray |
| Tray "Open Voyager" message | Window back and foreground |
| Screenshot, PrintWindow | Worked |
| Screenshot, VM-service frame grab | Worked, identical output |
| `vm.ps1 whoami` | Worked |

- **VM service** (`vm.ps1`): `whoami`; `shot <png>` renders the Flutter layer tree, so it works when covered or locked; `eval <libSuffix> <expr>` evaluates in one library's scope. Expressions are collapsed to one line; wrap state changes in `Future(() => …)`. GoRouter navigation by eval (see memory notes in AUDIT_TESTING.md) was **not** verified in this harness. Use rail clicks / `Ctrl+Tab`.
- **Data checks:** read-only SQLite from Python: `sqlite3.connect('file:%APPDATA%\\Voyager\\voyager\\voyager.sqlite?mode=ro', uri=True)`. The app has a 5 s busy_timeout, so reads while it runs are safe.

**Limitations**
- If the PC is **locked** (`voy.ps1 status` shows `locked=True`), real input and PrintWindow are unavailable. Don't send input. Fall back to posted messages + `vm.ps1 shot`, see `AUDIT_TESTING.md` "Session 1", or wait for Juno.
- "Another app has focus" scenarios (floater blur/click-outside) need a probe-owned WinForms window (pattern in `AUDIT_TESTING.md` Session 2). Not built into this harness yet.
- Native dialogs (file picker for backup Export/Import) are Win32 common dialogs outside Flutter. Drive them with keyboard (type a full path + Enter) only while their window belongs to voyager.exe; `Probe` guards on process, so this works.
- No admin rights: no firewall-based offline testing. Use **Dev page → Force offline** (session-only flag that makes the connectivity probe fail) for offline states.
- Minimum window is 720×520 logical (1440×1040 physical). The compact/bottom-nav shell (<600 logical wide) is **unreachable on desktop**.
- Multi-monitor / mixed DPI: only one display attached.

---

## 2. QA accounts

Password for all unless noted: `qavoyager2026`. Domain `example.com` (reserved; no mail is delivered). **Next unused number: 016.**

| Account | Created | Contents in its cloud copy | Notes |
|---|---|---|---|
| voyager-qa-001@example.com | 2026-09-27 (setup) | Empty (no journals, no entries). Created before the background defaults changed: holds the **old** defaults (Dark, Wave off, no Scatter). If reused, reset per SESSION START step 4. | Used to verify sign-up/sign-in. Free to reuse or ignore. |
| voyager-qa-002@example.com | 2026-09-29 (Phase 1) | 1 journal "Journal" (`__legacy__`) with 1 entry "new entry title" / "new entry body". New defaults (Dark + Scatter). | **Password `qavoyager2027`** (changed in Phase 1, 2026-09-29 15:49). `login.ps1 -Password qavoyager2027`. |
| voyager-qa-003@example.com | 2026-09-29 (Phase 1) | **Polluted by BUG-005:** one orphan journal entry (id `bf4bf6fd…`, journal `__legacy__` missing, body " EDITED-BY-003"), invisible in the UI. Startup page = Custom → To-Do. Dark + Scatter. | Password `qavoyager2026`. Prefer a fresh account for clean-state phases. |
| voyager-qa-004@example.com | 2026-09-29 (Phase 2) | List "QA List" (40 open tasks "QA task 01".."40") + empty built-in "To-do" list (BUG-012); journal "Journal" (`__legacy__`) with 1 entry (body "QA draft body for state check MIDEDIT-TRAY", mood 5). Nav order: Jobs first; Dreams + Calendar **hidden**; Dev **visible**. Weather location "Chicago, Illinois, US". Dark + Scatter; Vim off. | Password `qavoyager2026`. Unhide Dreams/Calendar (Settings → Appearance → Navigation pages) before using it for those phases, or use a fresh account. |
| voyager-qa-005@example.com | 2026-09-29 (Phase 3) | Journal "Journal" (`__legacy__`) with 1 entry (title "L1\rL2" with a hidden CR, BUG-017; body "alpha beta gamma delta…ENDhjkl dd x"). Lists "Vim List" (1 task "task insert enter") + empty built-in "To-do". Calendar event "hello lll hhh" on 2026-09-29. **Vim ON.** Dark + Scatter. | Password `qavoyager2026`. Turn Vim off (Settings → Editing) if reused for a non-Vim phase. |
| voyager-qa-006@example.com | 2026-09-29 (Phase 4) | Journal "Journal" (`__legacy__`) with 1 entry (body "Met Dr. Smith at 3 p.m. today neve", 8 images). Custom word `littl`; flagged `form`. 6 snippets (`;sig`, `addr` auto, `pp` tabstops, `wtih`, `zz` empty, `lng` 1,000 chars); **expand key Space**. 2 transactions, job "Acme", study deck "Deck A", ranking category "Books". Dark + Scatter; Vim off. | Password `qavoyager2026`. Its snippets/flags change autocorrect and expansion behaviour; use a fresh account for text-editing baselines. |
| voyager-qa-007@example.com | 2026-09-29 (Phase 5) | Journal "Journal" (`__legacy__`): 2 live quick entries dated Sep 29 ("second qje…" 5,349 chars incl. CJK/emoji/Arabic; "after cold login", BUG-038) + 1 deleted. List "To-do" (built-in): "floater task one" + a 5,316-char title. 2 transactions ("Floater Store" $12.34, "KbdStore" $3.21). 4 once-reminder rules on Sep 29 ("floater reminder" 23:00 fired; "past rem" 21:00 and "past rem two" 21:30 created in the past; "kbd reminder" 23:00). Vim off. Dark + Scatter. | Password `qavoyager2026`. |
| voyager-qa-008@example.com | 2026-09-30 (Phase 6) | List "Rem List": "bell task" (completed, due Sep 30 12:50 AM, bell At time), "feed A" and "feed B" (due Sep 30; "feed B" hidden in the Inbox). 28 scheduled rules: 22 "mass 01..22" once 1:28 AM (21 acked, "mass 21" deleted, "mass 22" due), "rule once A" (completed), "rule daily B" (daily 12:33 AM, note), "past rule" (snoozed to Oct 1 00:39), "offline fire" (due), "min size rule" (due), "weekly C" (Mon/Fri 2:00 AM, targeted at the removed device). Event "bell event" (deleted, bell 15 min). 4 pinned notes. Devices: "ZephyrusG14" (current install) + "QA Zephyrus" (removed). Dark + Scatter; Vim off; Dev page visible. | Password `qavoyager2026`. Due stickies will show on sign-in (after a restart, BUG-043). |
| voyager-qa-009@example.com | 2026-09-30 (FV-1/FV-2) | uid `4nA5HubuqiYfnScaqYPfId5Cklm2`. One record on every page, all ids prefixed `fv-`: journals "FV Alpha" (3 entries) and "FV Beta" (2); dream "FV dream"; list "FV List" (3 tasks, "FV task 0" due Sep 30 and hidden in the Inbox); "FV Calendar" with "FV event" (Sep 30 3:08 PM); tracker "FV Pushups" (25 on Sep 30); transaction "FV groceries" $42.50 #fvfood, budget #fvfood $300, goal "FV Trip" $2,000, asset "FV Savings acct" $1,234; bucket item; job "FV Corp"; ranking "FV Movies" › "FV Heat" › "FV Director cut"; LeetCode "FV Two Sum"; deck "FV Deck" (3 cards); workout session with no end time, so the "FV Bench" pill shows on every page; custom quote; pinned note; once-rule "FV reminder" (fired and acked Sep 30 1:34 PM). The default calendar is back to "Calendar" v0 (BUG-045). Dark + Scatter defaults. | Password `qavoyager2026`. Seeded over the VM service (`evalc.ps1`), not through the UI. |
| voyager-qa-010@example.com | 2026-09-30 (FV-2, BUG-004 re-check) | 1 journal "Journal" (`__legacy__`) with 1 entry "fv bug004 title" / "fv bug004 body". | Password `qavoyager2026`. |
| voyager-qa-011@example.com | 2026-09-30 (Phase 7) | Journals "Alpha" (44 live entries: ~20 seeded `p7-seed-*`/`p7-otd-*` 2024–2026 incl. Aug 30/31 2026 and Sep 30 2024/2025 On This Day matches, 10 blank "Untitled" from BUG-053, entries dated 1900-01-01 / 2100-12-31 / 2027-09-30; **On this day = Monthly + yearly**), "Gamma" (2: a 300-char "Txxx…Z" title with a 13,090-char body and 3 dropped images, and the quick entry "QJE line from hotkey"), "Journal" (`__legacy__`, 21 `p7-seed` beta entries moved there), "Beta Renamed" (deleted, in Trash). Custom quotes: "QA quote one" (×2, BUG-059), "two", "three"; **Only my quotes ON**. Dark + Scatter; Vim off. | Password `qavoyager2026`. Only-my-quotes and the OTD cadence change what new entries and the journal page show; turn them off if reused. |
| voyager-qa-012@example.com | 2026-09-30 (Phase 8) | 129 dreams (128 live): 7 made in the UI ("First dream title", "Second dream", a note-only "Untitled", "R1 dream" dated Sep 15, "R2 dream" with 1 image, a pasted CJK/Arabic/emoji dream with `#café #naïve`, a deleted image-only "Untitled"), 120 `p8-seed-*` ("Seed dream 000".."119", Jun 2–Sep 29, every 10th with "seed note N"), `p8-long` (300-char title, 700-word body), `p8-intl` (mojibake title from the seed harness). **77 dreams' notes are copies of their bodies (BUG-061).** One blank "Untitled" journal entry in "Journal" (`__legacy__`, see the P8 leads). **Show dream statistics ON.** Dark + Scatter; Vim off. | Password `qavoyager2026`. Its notes are already corrupted, so use a fresh account to check a BUG-061 fix. |
| voyager-qa-013@example.com | 2026-09-30 (Phase 9) | Lists "Work" (30 open + 2 done: "P9 task 01..32" minus deleted 26 (in Trash) and 32, plus "Z", a 500-char "L500x…", an Intl CJK/Arabic/emoji title, "CRLF line1
line2"; "P9 task 13" starred; "P9 task 29" daily, bell; holds 3 orphaned subtasks of task 30, BUG-066), "To-do" (built-in; "P9 task 30 EDITED" daily 9:30 PM, bell 15 min, notes, 3 subtasks, 4 images), "Home" ("P9 task 31 X" daily), "Perf 200" (200 seeded `p9-perf-*`, 17 completed). 26 completion rows. **Hide completed tasks ON**; default view none (BUG-072). Dark + Scatter; Vim off. | Password `qavoyager2026`. Turn Hide completed off if reused. |
| voyager-qa-014@example.com | 2026-09-30 (Phase 9 follow-up: list delete → move) | Lists "Inbox" (the built-in `__legacy_todo__`, renamed): A1 (daily, 2 subtasks, 1 image), A2 (completed), A3 (restored from trash), A5, A6 (starred), T1, plus stray subtask "s3 of A4" (BUG-066); "Beta": A4; "Alpha" (restored, empty). No default view. Dark + Scatter; Vim off. | Password `qavoyager2026`. |
| voyager-qa-015@example.com | 2026-09-30 (Phase 10) | Calendars "Calendar" (default; came back v0 after re-login, BUG-045) and "Holidays" (green; deleted + restored, 3 "HOL" events; 3 more from an undone import in Trash). ~80 live events Aug 1 to Nov 2 2026: imported set (`qa/steps/p10-import2.json`: overlap OV1-OV6 on Oct 6, multi-day, DST span, 300-char title, "Reminder evt" with a 15-min bell), recurring "Daily walk" (exceptions Oct 12/17, override "Fri16 walk" on Oct 12, BUG-078), "Weekly standup" (ends Oct 18) + "Standup v2" (from Oct 19) + override "Standup Oct12 only", "Monthly rent"; 50 "D50" events on Oct 22; BUG-074 victims "Timed one"/"Repro noon"; "abc" on Aug 1 (harness slip). List "Cal Tasks" with "Cal task A edited" (completed, due Oct 1). **Week starts on Sunday** (Monday off). Dark + Scatter; Vim off. | Password `qavoyager2026`. Turn Week starts on Monday back on if reused. |

---

## 3. Phase log

One line per completed phase.

- Phase 0 (Setup), 2026-09-27: environment, harness, reset procedure, interaction method verified; test plan written. No phase testing done.
- Phase 1 (First run, auth & account lifecycle), 2026-09-29: Done. Accounts qa-002, qa-003. Logged BUG-003 (Blocker: typing into the empty-account Journal editor is never saved), BUG-004 (Major: first journal/entry invisible until restart), BUG-005 (Blocker: sign-out keeps local data; another account sees it, and an edit uploads it corrupted), BUG-006 (Minor: login page keyboard focus). Re-checked BUG-001 fixed.
- Phase 2 (Shell, navigation, window & tray), 2026-09-29: Done. Account qa-004. Logged BUG-007 (Cosmetic: clock up to 30 s late), BUG-008 (Cosmetic: unset weather shows a sun + empty sheet), BUG-009 (Minor: Tab reaches nothing / focus invisible app-wide), BUG-010 (Major: pulled journal entries invisible until restart after sign-in on an empty device), BUG-011 (Minor: post-sign-in landing page ignores pulled startup setting), BUG-012 (Minor: hidden empty built-in "To-do" list created on first task add; new devices open on it).
- Phase 3 (Vim modal keybinding system), 2026-09-29: Done. Account qa-005. Logged BUG-013 (Minor: `h`/counted `l` cross lines, `dh`/`d5l` delete the line break), BUG-014 (Minor: no-match `/` leaves the caret on a partial match), BUG-015 (Blocker: motions split emoji; inserting there crashes the app, `x` saves "�"), BUG-016 (Minor: Enter in Normal doesn't submit one-line fields), BUG-017 (Minor: pasted CRLF leaves a hidden `\r` in one-line fields; not Vim-specific), BUG-018 (Minor: `yy` moves the caret to column 0), BUG-019 (Cosmetic: `/` prompt covers the journal quote at min size).
- Phase 3 follow-up (Juno's request), 2026-09-29: tested every Vim command the code has beyond VIM.md (~125 cases, `qa/steps/p3x-*`), and documented them in VIM.md §9–16. Logged BUG-020 (Minor: `V j J` joins one line too many) and added a note to BUG-013 (Space doesn't wrap, Backspace does).
- Phase 5 (Global hotkeys & floaters), 2026-09-29: Done. Account qa-007. Logged BUG-033 (Minor: carried-over to-do draft arrives fully selected), BUG-034 (Minor: a combo another app owns at launch is silently dead all session), BUG-035 (Minor: reentrant-frame assertions on floater replacement, seen once), BUG-036 (Cosmetic: in-app reminder editor clips at short heights), BUG-037 (Minor: Enter on an empty to-do bar drops focus), BUG-038 (Minor: second quick entry for the day after a wipe + sign-in; HLD out of date). Re-verified AUDIT_TESTING findings 3, 5, 10, 11, 12 fixed; 1, 4 not seen; 7 needs a real tray click.
- Phase 4 (Text-editing helpers), 2026-09-29: Done. Account qa-006. Logged BUG-021 (Major: autocorrect rewrites missing-letter typos into other wrong words, e.g. littl→litt, bcause→cause), BUG-022 (Minor: common misspellings are in the bundled dictionary), BUG-023 (Minor: Enter never autocorrects), BUG-024 (Minor: undoing an autocorrect drops the space; no redo), BUG-025 (Minor: appending a letter at a word's end doesn't autocorrect), BUG-026 (Minor: dictionary dialog drops focus after a rejected Enter), BUG-027 (Minor: Tab on a list line indents instead of expanding a snippet), BUG-028 (Minor: intra-word `*` pairs italic across lines), BUG-029 (Cosmetic: scrolled body top strip), BUG-030 (Cosmetic: entry preview cut at "1."/"Dr."), BUG-031 (Cosmetic: snippets dialog hides rows past the 4th with no scroll cue), BUG-032 (Minor: firebase_storage engine thread error on every upload).
- Phase 6 (Notifications, inbox & reminders), 2026-09-30: Done. Account qa-008. Logged BUG-039 (Minor: past once-reminder saved on, never fires), BUG-040 (Minor: DST day miscounts in the Inbox feed), BUG-041 (Minor: stickies cover the Inbox/dialogs; editor Create hidden at min size), BUG-042 (Cosmetic: light-theme "Show N more" contrast, Acknowledge loses accent), BUG-043 (Major: after sign-in on an empty device reminders/dismissals/pinned notes load only after restart; due reminders never alert). Resolved P1/P2 Devices leads and the P5 past-reminder lead.
- Phase 7 (Journal), 2026-09-30, build `7119be7`: Done. Account qa-011. Logged BUG-047 (Minor: deleting the open journal leaves its trashed entry editable), BUG-048 (Minor: first journal also creates an undeletable "Journal"), BUG-049 (Cosmetic: "1 entries" / ambiguous "Yes"), BUG-050 (Minor: name dialogs say "Title cannot be empty" and drop focus), BUG-051 (Minor: Trash "Restored …" toast never dismisses), BUG-052 (Minor: an emptied quote can't be re-added), BUG-053 (Minor: New entry keeps blank entries; ×10 → 10), BUG-054 (Minor: first entry after "Only my quotes" gets a bundled quote), BUG-055 (Minor: OTD strip covers mood 10 / delete at min size), BUG-056 (Minor: journal order unstable across installs), BUG-057 (Cosmetic: light switcher contrast), BUG-058 (Minor: body swallows Tab/Shift+Tab), BUG-059 (Minor: custom quotes stale after sign-in; dialog empty, duplicates, placeholder quote). Resolved the FV-2 dropdown lead (harness `maximize` race) and the P1 BUG-003 lead (works).
- Phase 8 (Dream journal), 2026-09-30, build `7119be7`: Done. Account qa-012. Logged BUG-061 (**Blocker**: every restart/pull copies a dream's body into its sticky note; the note text is lost; also on a new device), BUG-060 (Minor: no "drafted" indicator; HLD pin removed), BUG-062 (Minor: opening the note doesn't focus it; no keyboard route), BUG-063 (Minor: hashtags stop at the first non-ASCII letter, app-wide pattern), BUG-064 (Cosmetic: RenderFlex overflow while shrinking the window). Notes added to BUG-058 (dream body swallows Tab too) and BUG-051 (dream restore toast sticks).
- Phase 9 (To-Do), 2026-09-30, build `7119be7`: Done. Account qa-013. Logged BUG-066 (Major: a moved task's subtasks stay in the old list and are deleted with it), BUG-065 (Minor: panel shows a stale date after move + complete), BUG-067 (Minor: image paste into Notes attaches; duplicate refs), BUG-068 (Minor: fast row ticks jump the list with a RenderViewport layout-cycle error and hit unrelated tasks), BUG-069 (Minor: Ctrl+/ returns focus with the composer draft selected), BUG-072 (Minor: list restore loses default view), BUG-070 (Cosmetic: panel hides strip/Add subtask at smaller sizes), BUG-071 (Cosmetic: light header 1.4:1). Note added to BUG-017 (composer). Follow-up the same day (qa-014): the list-delete "move tasks" branch works; logged BUG-073 (Cosmetic: dialog names "To-do" after a rename and miscounts), notes on BUG-066/BUG-072. P3 leads resolved (empty search shows tasks; Ctrl+/ selection = BUG-069).
- Phase 10 (Calendar), 2026-09-30, build `7119be7`: Done. Account qa-015. Logged BUG-074 (Major: typing an end time in the time selector pushes the start back, e.g. 11 AM to 12:30p saves 11 PM the day before), BUG-078 (Major: Week view opens the wrong occurrence of a repeating event; "This event only" edits another day), BUG-079 (Minor: calendar colour change doesn't reach its events), BUG-080 (Minor: completing a to-do from the calendar removes its marker), BUG-081 (Minor: Week all-day shelf grows unbounded), BUG-082 (Minor: focus lost after closing the time picker; Ctrl+Enter dead), BUG-083 (Minor: Month unreadable at smaller sizes, "+N" undercounts), BUG-075, BUG-076, BUG-077 (Cosmetic: untitled continuation bars, cell order, hour labels under events). Notes added to BUG-045 (default calendar reset again on re-login), BUG-049, BUG-051.
- Fix verification FV-1 + FV-2 (TEST_PLAN.md "Fix verification"), 2026-09-30, build `f3c7cee`: both passed. Accounts qa-009, qa-010. FV-1: a restore onto a wiped device re-stamped nothing, and the next launch pulled 7 docs, all its own writes. FV-2: every page showed its data straight after a cold sign-in, and a reminder due 22 min later fired without a restart. Logged BUG-045 (Major: a new device's default calendar overwrites a renamed one in the cloud) and BUG-046 (Minor: "All journals" shows the open journal's count). Re-checked: BUG-004 still reproduces; the custom-quote refresh gap confirmed. The rest of FV (FV-3…FV-11) stays after Phase 26.

---

## 4. Test data currently present

- **Local:** none. The last session (Phase 10) ended with `session_end.ps1`: local data wiped, signed out.
- **Harness changes (Phase 10):** none to the harness. Import files `qa/steps/p10-import*.json` (pasted into the calendar's own Import dialog via `Set-Clipboard`; the dialog is the quickest way to make many events). Scratch helpers (recreate if needed): `q.py` (read-only SQLite), `cs.py` (crop several shots side by side).
- **Harness changes (Phase 9):** none to the harness. Step files `qa/steps/p9-*.txt`, seed body `qa/steps/p9-seed200.dart.txt` (list "Perf 200", 200 tasks). Scratch helpers (recreate if needed): `q.py` (read-only SQLite), `setimg.ps1` (PNG clipboard), `cliptxt.ps1` (long / CJK-Arabic-emoji / CRLF text onto the clipboard).
- **Harness changes (Phase 8):** none to the harness. Step files `qa/steps/p8-*.txt`, seed body `qa/steps/p8-seed.dart.txt` (122 dreams). Scratch helpers (recreate if needed): `setimg.ps1` (PNG clipboard, PROGRESS §5), `clipintl.ps1` (CJK/Arabic/emoji text built from char codes onto the clipboard), `kf.ps1` (send one key, then print `primaryFocus` rect via `vm.exe`), `st.ps1` (run one step, then print chosen SQLite rows).
- **Harness changes (Phase 7):** `qa/harness/DragSource.cs` + `qa/harness/dragdrop.ps1` (new: drag files onto a Voyager client point from a probe-owned window; see the quirk below), `qa/harness/wfp.ps1` (new: owner process + hit-test code at screen points, no capture). Step files `qa/steps/p7-*.txt`, seed bodies `qa/steps/p7-seed.dart.txt`, `p7-seed-dates.dart.txt`, `p7-quotebank.dart.txt` (samples the live QuoteBank). Test files `qa/data/anim.gif`, `qa/data/notes.txt`.
- **Harness changes (FV-1/FV-2):** `qa/harness/evalc.ps1` and `qa/harness/fs_snapshot.sh` (new, see the harness table); step files `qa/steps/fv2-*.txt`, seed bodies `qa/steps/fv-seed*.dart.txt` and `fv-rename-default-calendar.dart.txt`.
- **Harness changes (Phase 6):** none to the harness; step files `qa/steps/p6-*.txt` (`p6-mass.txt` creates 22 reminders through Ctrl+Alt+R).
- **Harness changes (Phase 5):** `qa/harness/OtherApp.cs` (new), `voy.ps1` verbs, `Probe.cs` click guard. The scratchpad `startup_probe.ps1` (hold Ctrl+Alt+R in a probe form and press Ctrl+Alt+T every 400 ms for 120 s, started in the background before `launch.ps1`) is described in BUG-034; recreate it if needed.
- **Cloud (QA accounts):** see the account table.
- Juno's real data: only in the cloud; Juno signs in between sessions. Juno's pre-audit local-only files are backed up at `C:\Users\Juno\VoyagerQA-localonly-backup-2026-09-27\`.

---

## 5. Environment quirks

- **Windows PowerShell 5.1:** `.ps1` files must be ASCII (a BOM-less UTF-8 em dash broke parsing). Native stderr + `$ErrorActionPreference='Stop'` throws, which is why `vm.ps1` wraps `dart run`.
- **Shell guard hook (dcg):** `>` redirects need literal paths (not `$var`). No `perl -pi`. Don't invoke scripts through a variable (`& $s`) in multi-line commands. Don't write scripts with Bash heredocs. Write files with the Write tool, then run them by literal path. `git checkout -- <path>` is blocked.
- **Focus:** `activate` sometimes needs its fallbacks (SwitchToThisWindow, then minimize/restore). A minimize/restore can itself trigger window-state handlers, so note it if a test is about window state.
- **Login card re-centres** when toggling Sign in ↔ Create account (fields move down ~56 px). `login.ps1` handles it. **It also moves when an error line appears** (one line: Email y≈696, Password y≈816 in sign-in mode; sign-up mode with one error line: 752/872). `login.ps1` assumes no error is showing: after a failed attempt, click the fields yourself. Dialogs (e.g. Change password) also grow and re-centre when an error appears, so re-measure button positions from a screenshot.
- **Settings reopens on its last tab.** To sign out, click the Account tab (282, 46) first, then Sign out (394, 451). Step file `qa/steps/p1-signout.txt` does the whole thing (rail scroll → Settings → Account → Sign out).
- **Rail when scrolled** (after `wheel 88 1400 -10`): Study ≈ y 1158, Workout ≈ 1280, Settings ≈ 1518, and Search/Analytics/Finance move up (Finance ≈ 569).
- **`vm.ps1` changes the working directory** of the PowerShell session; use absolute paths after calling it.
- **Harness-assisted helpers** (scratchpad, recreate if needed): read-only SQLite query script, and a PIL contact-sheet/crop script to tile several screenshots into one image for review.
- **Mid-session account switch:** `reset.ps1` without `-Force` refuses while Voyager runs. After `guard.ps1` shows a QA account, `reset.ps1 -Force` → `launch.ps1` → `login.ps1` is the allowed cold re-login.
- **Debug build:** first frames and page switches are slower than release. The shell warm-up of hidden pages is **off in debug**, so a first visit builds on arrival. Don't log debug-only slowness as a bug unless it's severe; note "debug build".
- **Documents logs** are shared with Juno's everyday use, and `perf_stall.log` keeps growing during QA. Read only what this session appended.
- **Installed release** (`%LOCALAPPDATA%\Programs\Voyager\voyager.exe`) starts at Windows login with `--hidden` and shares the same data dir. `stop.ps1` kills it too. Never test against it.
- Screenshots are 2880×1800. The viewer downsizes by 1.44; click coordinates are physical. **If you resize a shot yourself (e.g. PIL to 1440×900), the factor is 2, not 1.44** (Phase 10: several misses came from this, one of which saved a stray event by clicking outside the popover).
- `dart run qa/harness/vm.dart` prints "Running build hooks..." (harmless; filtered by `vm.ps1`).
- **Cold re-login of the same account:** `session_start.ps1 -Email <same>` (no `-SignUp`) is refused by the sync gate ("no sync check has been run") unless the Dev page check was run. Use the allowed path instead: app running → `guard.ps1` OK (+ outbox 0) → `reset.ps1 -Force` → `launch.ps1` → `login.ps1 -Email …`.
- **Dev page** is a nav page hidden by default: Settings → Appearance → Navigation pages → eye icon on "Dev" → Save. It then sits above Settings on the rail. Force offline toggle ≈ (2739, 776) maximized.
- **Settings tabs** (maximized, y=46): Account 282, Appearance 487, Editing 685, Pages 841. Weather location is on **Pages**; Vim toggle on Editing ≈ (2739, 258); Theme Dark/Light on Appearance ≈ (2525, 829) / (2707, 829); Navigation pages row ≈ (1500, 1570).
- **Floaters:** a global hotkey sent while the window is hidden turns the main window into the floater. Esc and the same hotkey don't dismiss it (by design); `tray-open` brings the main window back with its placement.
- **Writing to BUGS.md:** the dcg hook can misfire on Python heredocs whose text contains flag-like strings; use the Edit tool for BUGS.md entries.
- **Fast VM probes:** `dart compile exe qa/harness/vm.dart -o <scratchpad>\vm.exe` once per session. Each call then takes ~0.6 s instead of several seconds. Run it from the repo root (it reads `qa/logs/vm_uri.txt`). The VM service truncates string results at ~128 chars, so put short fields first in any expression that returns text.
- **VM-service writes to a text controller** (`controller.value = …`) can log "Build scheduled during frame" into `voyager_errors.log` (stack frame `Eval`). That's the harness, not an app bug.
- **The probe can't type a backtick:** on this PC's keyboard layout (`0409:00060409`), `Probe.cs` `type` sends an `r` for a backtick. Use the clipboard for text containing one.
- **`vimcase.ps1` fixture writes are deferred** (`Future`), so a synchronous write no longer trips the debug `StackFrame` assertion. Put `{wait:1500}` before an edit you plan to undo.
- **Emoji in text fields with Vim ON crash the app** (BUG-015). Don't leave emoji in fixtures you'll edit with Vim motions unless you're testing that.
- **The dcg hook** also blocks Python heredocs whose text contains Markdown backticks ("embedded shell launcher"), and `python … "${var}…"` paths in PowerShell. Use the Edit tool for Markdown, and literal or relative paths for scripts.
- **Don't click the bottom-right corner when maximized.** The Finance "+" FAB (≈2791, 1711) sits under the auto-hidden taskbar's clock; the click opens the Windows notification panel (ShellExperienceHost), which then keeps the foreground, and `activate`, `tray-open` and even a relaunch can't take it back. Use a non-maximized window (`place 200 100 2000 1100`) for bottom-edge controls.
- **Dialogs re-centre as they grow** (dictionary errors, snippet rows): re-measure from a screenshot before each click. The dictionary dialog also drops focus after a rejected Enter (BUG-026), so click the field again before typing.
- **Image clipboard:** Voyager reads only the registered "PNG"/JPEG/WebP/HEIC clipboard formats. `Set-Clipboard -Path` (a file drop) and .NET `SetImage` alone (bitmap) are ignored. Use a DataObject with the image *and* `SetData('PNG', $false, <MemoryStream of the PNG bytes>)`; the Phase 4 helper did exactly that (scratch `setimg.ps1`, recreate if needed). Test images are in `qa/data/`.
- **Programmatic fixture writes don't autosave** (`vimcase.ps1` sets `controller.value`, which fires no `onChanged`): the DB keeps the last *typed* body. Type at least one character if a check depends on the saved value.
- **vimcase keys are space-separated tokens**: a literal space must be `{space}` (`ld** tail` types "ld**tail").
- **At 2000×1100 the rail shows fewer items and the inbox sits lower**; navigate with Ctrl+Tab / Ctrl+Shift+Tab instead of rail coordinates (Journal ↔ Settings wrap).
- **A wrong click coordinate once reached another app** (Phase 5): a point read off a downscaled contact sheet was outside the 1344×239 floater, and the click landed on Juno's IDE window (one left click, no keys; the next `type` was refused). `Probe.cs` now refuses clicks outside Voyager's client area. Measure coordinates on the unscaled shot, and remember floaters are small windows.
- **Probe form vs. foreground:** after `other-open`, `ostatus` often shows `fg=explorer:Shell_TrayWnd` (the taskbar) instead of the form; the floater still opens and dismisses correctly, and focus returns there. With the main window maximized it covers the form: `place 200 100 2000 1100` first, or the guard refuses `other-click`. End a run with `activate` (or leave a window foreground): when the probe process exits while its form is foreground, the foreground becomes empty and `activate` reports `locked=True`.
- **Posted tray clicks can't grant foreground:** `tray-open` sometimes leaves Voyager visible but not foreground, and a tray menu opened by `tray-menu` doesn't close on clicking elsewhere (AUDIT finding 7 can't be judged this way). Close it with `activate; key esc`.
- **Floater coordinates** (client px): to-do bar 1344×127: title (500,62), Due (1075,62), List (1240,62); the date picker grows it to 987 tall, the list picker to 239 (first list row ≈ y 175). Finance 1264×1049: amount (632,286), Add (632,917). Reminder 952×1023: title (475,167), time chip (250,552), Create (865,930) with the validation line showing, (865,929) without. Notepad 744×631: Delete (690,59).
- **Hotkeys are registered once at launch.** If a probe or anything else holds a combo at launch, Voyager never gets it back until restart (BUG-034); `voy.ps1 hotkey` then refuses to send it.
- **Tab focus probe:** `vm.ps1 eval "features/shell/app_shell.dart" "FocusManager.instance.primaryFocus?.toStringShort() ?? 'none'"` shows where keyboard focus is (focus rings are invisible in the app, BUG-009).
- **Verifying OS toasts (P6):** read Windows' notification store read-only: `sqlite3.connect('file:<LOCALAPPDATA>/Microsoft/Windows/Notifications/wpndatabase.db?mode=ro', uri=True)`, join `Notification.HandlerId` → `NotificationHandler.RecordId` where `PrimaryId = 'Voyager.App'`, regex `<text>` out of `Payload`; `ArrivalTime` is a FILETIME. It also holds Juno's own notifications: filter on Voyager only. Windows keeps 20 per app. Toasts are never withdrawn on ack on Windows (by design), and a re-fire of the same source replaces its toast.
- **Toast Undo has an 8 s dwell:** reading a screenshot takes longer, so click Undo in the same `voy.ps1` run, or `move` the mouse onto the toast right away (hover holds it) and read its position from a shot.
- **`key A` sends an unshifted `a`:** for Vim capitals use `type A`, not `key A`.
- **The Inbox popover re-lays out** after every dismiss/add (it's anchored at the bottom and grows upward): re-measure the broom, `+` and row positions from a fresh shot. Clicking a pinned-note row opens its inline editor (Esc commits the edit).
- **Rail scroll persists:** after visiting Dev/Settings the rail may stay scrolled (To-Do at y 538 becomes Finance). `wheel 88 600 10` first.
- **Don't `maximize` right after `launch.ps1`.** The app maximizes itself during startup; a harness `maximize` sent while that runs can leave the window zoomed at the centred restore position (`status` shows `zoomed=True rect=160,100 2906x1826` instead of `-13,-13`). Then a native caption strip appears along the top on hover and swallows clicks there (journal header dropdown, flag, gear): this was FV-2's "dropdown won't open" lead. Seen 1 in 4 with the harness `maximize`, 0 in 6 without. Check `status` after a launch; if the rect is wrong, `restore` then `maximize` fixes it.
- **Drag-and-drop (`dragdrop.ps1 -Files <paths> -X <clientX> -Y <clientY>`):** opens the drag-source form at screen (2380,1400); place Voyager away from it (`place 200 100 2000 1100`). It activates Voyager, presses on the form, glides to the point and releases only if the window there belongs to voyager.exe (once it was Juno's IDE and the drag was cancelled). A 12 s safety timeout closes the form. Output: `owner@target=… effect=Copy|None`.
- **Journal header/journal-row coordinates (maximized):** dropdown (340,55), gear/Manage journals (724,55); Manage dialog rows ⋮ at x≈1820–1832 (rows re-centre as the count changes: re-measure); New entry button (486,1736); editor trash (2791,252), delete confirm (1627,985), toast Undo ≈ (1663,65); OTD tucked strip (2847,500). Journal order in the dropdown isn't stable across installs (BUG-056), so re-read it from a shot.
- **`evalc.ps1` seed bodies must be pure ASCII.** It reads the body with PowerShell 5.1 `Get-Content -Raw` (ANSI), so UTF-8 literals arrive as mojibake. The Write tool turns `\uXXXX` escapes into literal characters, so either build strings with `String.fromCharCodes([...])` in the body or put non-ASCII text on the clipboard and paste it through the UI.
- **Seeding through a repository doesn't refresh open pages.** Dreams seeded with `evalc.ps1` appeared only after a restart (the page's provider isn't invalidated by a raw `upsertEntry`). Harness artifact, not a bug.
- **Dreams page coordinates (maximized, default list width 480 logical):** New dream (662, 1735), rows start y≈175 and step ≈168 (re-measure: the list re-sorts by date), editor trash (2782, 239), delete confirm (1633, 985), toast Undo ≈ (1663, 65), date pill ≈ (1238, 239), sticky-note tab (2782, 1703), note field (2560, 1520), note close (2793, 1371), split divider at x ≈ 1145 at the default width (re-measure from a shot after a drag). With `dream_split_width` 390.5 the New dream button is at (582, 1735).
- **Direct Firestore REST reads (`gcloud` token + curl) were blocked** by the session's permission classifier in Phase 8. `fs_snapshot.sh` may hit the same block; plan checks against the local DB, or ask Juno first.
- **Reminder editor via Ctrl+Alt+R** (in-app) opens centred with fixed positions at maximized: time chip (1188, 937), Create (1837, 1346) with the "Fires in…" line. Typing `h:mm AM` + Enter in the picker's time field sets it and closes the picker; clicking outside the editor discards it silently.

---

## 6. Manual-only / out of scope

| Item | Status | Why |
|---|---|---|
| Juno's real account: signing in, changing anything, "Continue with Google" | **MANUAL-ONLY — do not execute** | Real account / real Google OAuth |
| Login → "Forgot password?" **with an e-mail filled in** | **MANUAL-ONLY — do not execute** | Sends a real password-reset e-mail through Firebase. The empty-e-mail validation message is local and may be tested. |
| LeetCode username sync / stats fetch (`leetcode.com/graphql`) | **MANUAL-ONLY — do not execute** | Real external API. Leave Settings → LeetCode username empty. The "not configured" state may be tested. |
| Dev page → "Use direct OpenWeather" + API key | **MANUAL-ONLY — do not execute** | Calls OpenWeather directly with a real key |
| Links that open the browser (`launchUrl`: LeetCode/NeetCode, job URLs, OpenWeather credit, profile links) | **MANUAL-ONLY — do not click** | Opens Juno's real browser. Checking that the link exists/looks right is fine. |
| Importing any of Juno's real backups (in the local-only backup folder or `Downloads`) | **MANUAL-ONLY — do not execute** | Would copy real personal data into a QA account. Import only exports made by QA sessions. |
| Weather (Cloud Functions `geocodeLocation` / `refreshWeather*` → OpenWeather) | Allowed, low volume | Juno's own backend, read-only. Set at most a couple of test locations per session. |
| Firestore / Firebase Storage sync, device registration, reminders data | Allowed **only for voyager-qa-* accounts** | Isolated per account; this is the audit's isolation boundary |
| Settings → Change password (QA account only) | Allowed | Record the new password in the account table immediately |
| Settings → Start with Windows | Allowed **with restore** | Writes Juno's real HKCU Run entry. Before touching it, note the exact value (above). Afterwards restore it with `Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name Voyager -Value '"C:\Users\Juno\AppData\Local\Programs\Voyager\voyager.exe" --hidden'` and verify. |
| Dev page → Remote purge / out-of-sync purge | Allowed only after `guard.ps1` OK | Deletes from the *current* account's Firestore |
| Demo page (`/demo`, debug-only playground) | Out of scope | Not shipped in release builds |
| Android / compact (<600 dp) layout | Out of scope | No Android SDK; compact width unreachable on desktop |
| Multi-monitor / mixed-DPI floater placement | Out of scope | One display attached |

---

## 7. Handoff note

**Next phase: Phase 11 — Search.** Start with `session_start.ps1 -Email voyager-qa-016@example.com -SignUp` (update the account table), or reuse qa-015 for calendar events in search results (80 events incl. a 300-char title, notes "line one / line two" on "Monthly rent").
- (2026-09-30) Phase 19 is now **19A Rankings core** and **19B Rankings: locations & map** (`RANKINGS_MAP_HLD.md`), with map items added to P24, P25 and P26. 19B is gated on the map feature being merged into `main`, and it needs `launch.ps1` to pass `GEOAPIFY_API_KEY` (never written to `qa/`). Build the map on a separate branch, because `launch.ps1` builds whatever is in the working tree. If `main` has no map yet when you reach Phase 19, run 19A only and leave 19B Blocked.
- (P10) Phase 10 leads are in TEST_PLAN.md's Phase 10 section: undone imports linger in Trash (P24), today's month cell greys its events, panel all-day events end at 01:00 (check how Search/reminders read `end`), raw-row event counts in Manage. Workouts on the calendar weren't tested (P23).
- (P10) To make many calendar events fast, paste JSON into the calendar's own Import dialog (`qa/steps/p10-import*.json`; format in `calendarEventImportPrompt`, `lib/domain/services/calendar_event_import.dart`).
- (P10) In Week view, open recurring occurrences from Month view or the right-click menu: a left-click in Week opens the wrong day (BUG-078).
- (P10) Calendar coordinates (maximized): Week (285,65), Month (415,65), Year (540,65), today/clock (636,65), scope switcher (780,65), Manage gear (1083,65), Import (1151,65), Add event (2707,65); Month header arrows ‹ (927,143) › (1283,143). Event popover from Add event: title autofocused, clock toggle ≈ (2791,243), time chip ≈ (2440,360), Cancel/Save at the popover's bottom corners (re-measure).
- (P9) Phase 9 leads are in TEST_PLAN.md's Phase 9 section (list scroll offset carried across lists, truncated panel date, completion rows for non-repeating tasks: check in P12 whether statistics double-count). To-do task notes survive restart and cold re-login (BUG-061 doesn't reach tasks).
- (P9) The edit panel's × sits under the debug ribbon at (2832, 48) maximized; the panel's checkbox shows a grey tick on hover, so move the pointer away before judging it.
- (P9) Calendar shows to-do due markers (P10): "P9"-style tasks with due dates are a ready source if you reuse qa-013.
- (P8) Phase 8 leads are in TEST_PLAN.md's Phase 8 section: a blank journal entry + "Journal" created by only visiting the Journal page on a journal-less account; the Trash dialog's Journal chip vanishing; slow tray Quit.
- After `launch.ps1`, check `voy.ps1 status` before clicking along the top edge: don't `maximize` during startup (quirk in §5).
- Since FV-2 passed, there's no need to restart after a cold re-login before judging the UI, except: custom quotes (BUG-059) and BUG-004 (a new account's first entry). The journal's "older entries loaded by scrolling" gap doesn't exist: `historicalJournalEntriesProvider` is unused (the list loads every entry).
- Unused code noticed (not touched): `historicalJournalEntriesProvider` in `lib/app/providers.dart`.
- Phase 7 leads (not logged): opening an entry whose stored tags don't match its body's hashtags rewrites them (seed-only so far); the OTD card's once-per-run entrance can be spent behind a modal dialog; the image fan covers the last lines of body text.
- A workout session with no end time shows the "FV Bench" pill at the top of every page for qa-009; that's the seed data, not a bug.

**Added 2026-09-30 (outside a phase session):** fixes were made in the working tree for BUG-010/BUG-043 (every page now refreshes when the startup pull ends) and BUG-044 (a restore onto a wiped device no longer re-uploads what it pulled). A later change the same day speeds up the restore itself: a first pull reads every operation log in one paged read instead of one query per document (BUG-002's 2026-09-30 notes: measured 27.5 s against 62.1 s on Juno's account, with the same rows restored). See those entries' Notes. They're not yet checked in the running app: TEST_PLAN.md has a new **Fix verification (FV)** section covering these and every other fix made during the audit (FV-1…FV-11). Keep restarting after a cold re-login until FV-2 passes. BUG-004 isn't fixed by this change. *(Update, same day: FV-1 and FV-2 passed; see the Phase log and the note above.)*

Leads (not yet logged as bugs):
- (P6) Pinned-note inline edit: Esc commits the edit instead of cancelling it (P25 keyboard pass).
- (P6) Clicking outside the "New reminder" editor discards the typed title/time with no confirm (same as the reminder floater, HLD §7a.2; decide whether the in-app dialog should differ).
- (P6) Reminder History shows raw ISO text for snoozes ("until 2026-09-30T00:44:04.388792") (cosmetic sweep).
- (P6) Dev → Force offline only fails the connectivity probe: the outbox still drained to 0 while the offline badge showed (P26).
- (P6) Entity bell rows stay `enabled` after their task/event is deleted (the engine skips them). In P24 check whether restoring the event/task from Trash re-arms the bell, and whether it fires for an occurrence that passed while deleted.
- (P6) The Inbox feed labels a task "Today" (grey) even when its due time passed minutes ago; overdue red starts the next day. Day-granular by design in the code; judge in P9.
- (P6) Tapping a Windows toast (should focus that sticky) is untested: the toast is outside the app window (MANUAL).
- (P5) Once, a to-do floater opened by a hotkey during app startup did **not** dismiss when another window took the foreground (with its List picker open); it stayed topmost until the next click. Not reproduced with the probe form (pickers open, click outside → dismissed). If it recurs, note whether the floater opened before the first frame.
- (P5) Quit from the tray with the journal notepad open took more than 3 s to exit (the text was flushed). The audit measured <1 s without a floater.
- (P5) In-app Ctrl+Alt+J on a fresh account: the entry list stayed empty while the editor showed the new QJE (same as BUG-004); after restart it lists it.
- (P5) Esc with Vim OFF in a floater field unfocuses it; the floater stays open with nothing focused, so typing goes nowhere until a click. Judge with BUG-037 in mind (P25 keyboard pass).
- (P4) Rankings "New category" dialog: the "Name" field label is clipped at its top at 2000×1100 (P19).
- (P4) The "Image is too large" toast sits over the journal Title label (cosmetic sweep).
- (P4) Numbered list sub-items keep the parent's numbering (`  3. c`) instead of restarting (not re-checked in P7).
- (P4) `p.m.` gets squiggles under `p` and `m` (single letters unknown to the spell checker).
- (P4) Dream and study-card image paste, drag-and-drop and the gallery file picker were not tested; now checklist items in P7 (drag-and-drop + drag helper), P8, P9, P19 and P21.
- (P3) BUG-017 (hidden `\r` from a pasted CRLF) is confirmed on the journal Title, body (P7) and the To-Do composer (P9). Still to check: list names, finance store, and where the value renders in Search (P11/P13).
- (P3, logged in P9) Closing the Ctrl+/ shortcuts list returns focus to the To-Do composer with its text fully selected: BUG-069.
- (P3, resolved in P9) With To-Do search (Ctrl+F) open and empty, the list shows all tasks (Vim on and off); not reproduced.
- (P1, resolved in P7) BUG-003: deleting the last entry of a journal opens a fresh blank entry, and what's typed there saves.
- (P2, resolved in P3) Ctrl+Tab navigates away even from inside a text field, in Vim Normal and Insert modes. No Vim binding uses Ctrl+Tab, so there is no conflict.
- (P2) Life page showed "[ TASKS ] 0" with 40 open tasks and "No journal moods yet" with one entry whose `mood` = 5 in SQLite (the slider's midpoint default; never touched) (Phase 16; also check in P7 whether an untouched slider should store a mood at all). Possibly BUG-010's cause (seen right after a cold sign-in; `lifeTrackerStatsProvider` is kept alive); re-check in FV-2.
- (P2, logged in P9) Light theme: To-Do header list name low contrast: BUG-071.
- (P2) The forecast chart's y-axis shows a single label ("20°") and no rain scale (P25 or cosmetic sweep).
- (P2) Check in P9 whether the To-Do page (not just SQLite) shows pulled tasks right after a cold sign-in, like BUG-010 for Journal. Now part of FV-2.
- (Setup lead, resolved in P2) at minimum window size the rail scrolls and every page is reachable.
