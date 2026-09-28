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
| `voy.ps1` | Real input + window capture (below) |
| `vm.ps1 whoami \| shot <png> \| eval <libSuffix> <expr>` | Dart VM service client (wraps `vm.dart`) |
| `Probe.cs` | Win32 side of `voy.ps1` (compiled by Add-Type; must stay C# 5: no `=>` members, no `$""`) |

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

Password for all unless noted: `qavoyager2026`. Domain `example.com` (reserved; no mail is delivered). **Next unused number: 002.**

| Account | Created | Contents in its cloud copy | Notes |
|---|---|---|---|
| voyager-qa-001@example.com | 2026-09-27 (setup) | Empty (no journals, no entries). Created before the background defaults changed: holds the **old** defaults (Dark, Wave off, no Scatter). If reused, reset per SESSION START step 4. | Used to verify sign-up/sign-in. Free to reuse or ignore. |

---

## 3. Phase log

One line per completed phase.

- Phase 0 (Setup), 2026-09-27: environment, harness, reset procedure, interaction method verified; test plan written. No phase testing done.

---

## 4. Test data currently present

- **Local:** none. The last session ended with `session_end.ps1`: local data wiped, signed out.
- **Cloud (QA accounts):** see the account table.
- Juno's real data: only in the cloud; Juno signs in between sessions. Juno's pre-audit local-only files are backed up at `C:\Users\Juno\VoyagerQA-localonly-backup-2026-09-27\`.

---

## 5. Environment quirks

- **Windows PowerShell 5.1:** `.ps1` files must be ASCII (a BOM-less UTF-8 em dash broke parsing). Native stderr + `$ErrorActionPreference='Stop'` throws, which is why `vm.ps1` wraps `dart run`.
- **Shell guard hook (dcg):** `>` redirects need literal paths (not `$var`). No `perl -pi`. Don't invoke scripts through a variable (`& $s`) in multi-line commands. Don't write scripts with Bash heredocs. Write files with the Write tool, then run them by literal path. `git checkout -- <path>` is blocked.
- **Focus:** `activate` sometimes needs its fallbacks (SwitchToThisWindow, then minimize/restore). A minimize/restore can itself trigger window-state handlers, so note it if a test is about window state.
- **Login card re-centres** when toggling Sign in ↔ Create account (fields move down ~56 px). `login.ps1` handles it.
- **Debug build:** first frames and page switches are slower than release. The shell warm-up of hidden pages is **off in debug**, so a first visit builds on arrival. Don't log debug-only slowness as a bug unless it's severe; note "debug build".
- **Documents logs** are shared with Juno's everyday use, and `perf_stall.log` keeps growing during QA. Read only what this session appended.
- **Installed release** (`%LOCALAPPDATA%\Programs\Voyager\voyager.exe`) starts at Windows login with `--hidden` and shares the same data dir. `stop.ps1` kills it too. Never test against it.
- Screenshots are 2880×1800. The viewer downsizes by 1.44; click coordinates are physical.
- `dart run qa/harness/vm.dart` prints "Running build hooks..." (harmless; filtered by `vm.ps1`).

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

**Next phase: Phase 1 — First run, auth & account lifecycle.** Start with `session_start.ps1 -Email voyager-qa-002@example.com -SignUp` (update the account table).

Leads from setup to confirm in Phase 1 (not yet logged as bugs):
- On a brand-new account (0 journals), the Journal page shows an editor ("Title", Mood, date, "Start writing…"). Text typed into its body ("qa probe text") **never reached SQLite**: `journal_entries_table` and `journals_table` both stayed empty after 8 s and after navigating to To-Do and back, though the text stayed on screen. The entry list on the left stayed empty. Check whether it persists across a restart, and whether it's lost.
- At the minimum window size (1440×1040 physical), the nav rail shows only Journal…Search, then the inbox icon. Check whether the remaining pages can still be reached (scroll/overflow). This belongs to Phase 2.
