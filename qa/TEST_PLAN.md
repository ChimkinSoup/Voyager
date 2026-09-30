# Voyager QA Audit — Test Plan

## HOW TO RUN A PHASE SESSION

You start with no context. Everything you need is in `qa/PROGRESS.md` (environment, harness, account table, quirks, manual-only list, handoff), this file, and `qa/BUGS.md`.

### RULES (this session and every phase session)

- Test by actually running the app and observing what it does. Harness
  scripts are fine, but writing an automated test suite is not the goal.
- Create whatever test data a flow needs (dozens of todos, edge-case journal
  entries, overlapping events) and record it in PROGRESS.md.
- If a bug blocks later steps, log it, try a workaround, and record what was
  skipped in that phase's section of TEST_PLAN.md.
- Never fix bugs or modify app code.
- Never exercise anything marked MANUAL-ONLY.
- Only one session should run at a time. The app window, input devices, and
  local data are shared, so parallel sessions would interfere with each
  other.

**Account safety rules (added by Juno at setup; they override anything else):**
- Never sign into or modify Juno's real account. Only `voyager-qa-*@example.com` accounts, recorded in PROGRESS.md §2.
- Before any destructive action, run `qa/harness/guard.ps1` and confirm the app is signed into a `voyager-qa-*` account.
- If the app is ever signed into Juno's real account (or any non-QA account) mid-test, **stop immediately and tell Juno**.
- If sign-up ever requires e-mail verification, stop and tell Juno instead of working around it.
- Harness/driver scripts go in `qa/` only. Never edit `lib/` or any other app source.

### SESSION WORKFLOW (for every phase session)

1. Read qa/PROGRESS.md, qa/TEST_PLAN.md, and the last ~20 entries of
   qa/BUGS.md.
2. Pick the first Not Started phase (unless the user names one) and set it
   to In Progress.
3. Run the baseline reset if the phase needs a clean state; otherwise note
   which existing data you're relying on.
4. Work through the phase's checklist across all five dimensions. Tick items
   as you go, and log bugs as you find them rather than at the end.
5. Before finishing: set the phase to Done (or leave it In Progress with a
   note on exactly where you stopped), update PROGRESS.md (phase log, test
   data, quirks, handoff note), and tell the user the next phase and how
   many bugs you logged by severity.

**Session start and end (required):**
- Step 3 always goes through the **SESSION START** procedure in `qa/PROGRESS.md` §1 (`qa/harness/session_start.ps1`). That script is also the baseline reset (use `-SignUp` with a fresh account for a clean state, or reuse a listed account's data). Then check the **standard test configuration** below (Dark + Scatter, Juno's background).
- Step 5 always ends with the **SESSION END** procedure in `qa/PROGRESS.md` §1 (`qa/harness/session_end.ps1`: sign out of the QA account and fully quit Voyager). Run it even if the phase stopped early.

### Standard test configuration (Juno's preference): Juno's background settings
- Do the **majority of testing in the dark theme with Juno's background settings** (everything except the accent colour, which stays at the QA account's default). As of 2026-09-28 these are the **app defaults**, so a fresh QA account already has them: Theme **Dark**, triangle grid scale 15 / intensity 0.67 / glow spread 1.1 / focal point (0.1, 0.5) / variation floor 0.8, and **Scatter** ON (triangles light up at random, lit amount 2.5%) with **Wave** off, plus Juno's pop/shadow/tilt tuning. The light theme's petals (160 petals, fall 38.86, wind 16.88, two minor colours) are Juno's too.
- Nothing to apply after SESSION START; just verify with read-only SQL: `settings_table.theme_mode = 'dark'`, `geometric_wave_scatter_mode = 1`, `geometric_wave_enabled = 0`, `geometric_texture_scale = 15.0`. If an account holds older values (e.g. qa-001, created before the change), use Dev → *Geometric texture tuning* and *Geometric wave tuning* → **Reset to defaults**, and set the petals by hand in Light (or use a fresh account).
- Where the background is irrelevant to what's being tested (data checks, most functional flows), just leave it on and ignore it. Where it matters: text legibility and contrast over lit triangles, glass/translucent panels, popovers and dialogs over the background, and frame pacing while it animates. Note in bug reports that Scatter was on.
- The background animates, so two screenshots of the same state differ in the background. Don't treat background pixel differences as a change.
- **Light theme is a secondary spot-check**: in each phase, switch once to Light, glance over that phase's main screens for contrast/overflow, then switch back to Dark. The full light-theme pass is in Phase 25.

### Practical notes
- Drive the app with `qa/harness/voy.ps1 run <steps file>`. Put scenario step files in `qa/steps/` and screenshots in `qa/shots/` (named `p<phase>-...`). Look at the screenshot after every meaningful action; don't assume.
- Verify data with read-only SQLite queries, not just the UI. "Survives restart" = `stop.ps1`, then `launch.ps1`, then re-check the UI and the DB.
- Check `qa/logs/run-*.log` for `EXCEPTION CAUGHT`, `RenderFlex overflowed`, `Another exception` after each flow. A FlutterError is a bug even if the UI looks fine.
- Read the HLD docs listed for a phase (repo root) to know the *intended* behaviour. A mismatch between the HLD and the app is worth logging.
- Bug severity: **Blocker**: data loss/corruption, crash, or a core flow impossible. **Major**: a feature works wrongly or a main flow is badly impaired, no easy workaround. **Minor**: wrong but a workaround exists, or edge-case only. **Cosmetic**: visual/polish only.

### The five dimensions (every phase covers all of them)

For each phase, besides its specific flows, tick this sweep. Copy it into the phase's checklist as you go, or note "n/a + why":

- **D1 Functional:** every control on the page does what its label says; happy path end to end.
- **D2 Data integrity:** each create/edit/delete is in SQLite (read-only check) and survives `stop.ps1` → `launch.ps1`. The outbox drains (`pending_uploads_table` → 0). A cold re-login of the same account (`session_start.ps1` without `-SignUp`) restores it from the cloud. No duplicates, no orphans, no stray soft-deletes.
- **D3 Visual/layout:** alignment, overflow, truncation (long titles), empty states. Check at maximized (2880×1800) and at minimum size (`place 0 0 1440 1040`) plus one odd size (e.g. `place 0 0 2000 1100`). Mainly in **Dark + Scatter** (standard configuration), plus the light-theme spot-check. Watch for `RenderFlex overflowed` in the run log.
- **D4 Keyboard-only:** reach and operate everything without the mouse (Tab/Shift+Tab focus order, Enter/Space activate, Esc closes, Ctrl+Enter saves forms, Ctrl+Tab/Ctrl+Shift+Tab change section). With **Vim keybindings ON** (Settings) and OFF: typing in the page's text fields, Esc from Insert → Normal vs Esc closing a dialog, page shortcuts (`h`/`l`, Space, grading keys, Ctrl+F) not firing while a text field has focus.
- **D5 Failure cases:** invalid input (empty, whitespace-only, negative/huge numbers, bad dates), very long input (5,000+ chars, 300-char single word, emoji/CJK/RTL; `type` supports only keyboard-typable chars, so put others on the clipboard via PowerShell `Set-Clipboard` and paste), rapid repeated actions (double-click save, 20× fast toggles), interrupting mid-action (navigate away, close to tray, `stop.ps1` mid-edit and relaunch), offline (Dev → Force offline) and empty/no-data states.

---

## Phase list

| # | Phase | Status |
|---|---|---|
| 0 | Setup (environment, harness, plan) | Done |
| 1 | First run, auth & account lifecycle | Done |
| 2 | Shell, navigation, window & tray | Done |
| 3 | Vim modal keybinding system | Done |
| 4 | Text-editing helpers (autocorrect, dictionary, snippets, formatting, images) | Done |
| 5 | Global hotkeys & floaters | Done |
| 6 | Notifications, inbox & reminders | Done |
| 7 | Journal | Not Started |
| 8 | Dream journal | Not Started |
| 9 | To-Do | Not Started |
| 10 | Calendar | Not Started |
| 11 | Search | Not Started |
| 12 | Analytics & trackers | Not Started |
| 13 | Finance A: ledger & transactions | Not Started |
| 14 | Finance B: categories, budgets, subscriptions & finance analytics | Not Started |
| 15 | Finance C: goals, assets & contribution room | Not Started |
| 16 | Life tracker | Not Started |
| 17 | LeetCode A: dashboard, problems & review deck | Not Started |
| 18 | LeetCode B: sessions, cram, scratch pad & cheat sheet | Not Started |
| 19 | Rankings | Not Started |
| 20 | Jobs | Not Started |
| 21 | Study A: library, decks & card editing | Not Started |
| 22 | Study B: sessions, cram & session resume | Not Started |
| 23 | Workout | Not Started |
| 24 | Trash, soft delete & undo | Not Started |
| 25 | Settings, theming & data management | Not Started |
| 26 | Sync, offline, persistence & Dev page | Not Started |
| FV | Fix verification: app changes made during the audit | Not Started |
| 27 | Final Review | Not Started |

Keep this table and each phase's **Status** line in sync.

---

## Phase 0 — Setup
- **Status:** Done (2026-09-27)
- Environment, harness, baseline reset and interaction method verified; see PROGRESS.md.

---

## Phase 1 — First run, auth & account lifecycle
- **Status:** Done (2026-09-29). Bugs: BUG-003 (Blocker), BUG-004 (Major), BUG-005 (Blocker), BUG-006 (Minor); BUG-001 re-checked fixed.
- **Scope:** login page, sign-up/sign-in, error states, what a brand-new account sees on every page (first-run empty states), startup-page redirect after login, sign-out from Settings → Account, change password on a QA account. **Deferred:** rail/nav mechanics → P2; Settings page in general → P25; per-page empty-state *details* → each page's phase (here only check that nothing crashes and there's a sensible first-run prompt).
- **HLD docs:** PLAN.md, PRODUCT.md, SESSION_RESUME_HLD.md (startup), GAPS.md
- **Flows:**
  - [x] Login page layout; Sign in ↔ Create account toggle: the card re-centres, typed e-mail and password are **kept**, no field is focused afterwards. Sign-up mode buttons: "Sign up" / "Have an account? Sign in".
  - [x] Sign up a new account (happy path) → lands on Journal (startup = first page), no e-mail verification. qa-002 and qa-003 created.
  - [x] Sign-up errors: empty ("Email and password are required."), "notanemail" ("Enter a valid email address."), "abc" ("Password is too weak. Use at least 6 characters."), qa-001 ("An account already exists for this email.").
  - [x] Sign-in errors: wrong password and unknown e-mail both show "Sign in failed. Check your email and password, then try again."; a padded e-mail is trimmed and signs in.
  - [x] Enter in either field submits; loading shows a spinner in place of Sign in and dims the other buttons; double Enter → one sign-in, no error.
  - [x] "Forgot password?" with an empty e-mail → "Enter your email to reset your password." (filled-in path not exercised: MANUAL-ONLY)
  - [x] Google button hidden on Windows.
  - [x] **Lead from setup:** confirmed, BUG-003 (text typed into the editor of an account with no journal is never saved; lost on restart). Follow-on BUG-004 (after "New entry", the journal and entry stay invisible until restart).
  - [x] First visit to every rail page (Journal, Dreams, To-Do, Calendar, Search, Analytics, Finance, Life, LeetCode, Rankings, Jobs, Study, Workout, Settings): no crash, no FlutterError, sensible empty states ("No dreams logged yet.", "Create your first list", "No transactions yet…", "No categories yet / Create a category", "No problems tracked yet", "No applications tracked yet", "Nothing here yet / New folder / New deck", Workout pre-seeded exercise library, Life "Set your birth date in Settings").
  - [x] Settings → Account shows the right e-mail ("Signed in with email and password"); Sign out → login page; sign back in → data pulled back (qa-002 onto an empty local DB). **Sign-out keeps the local data, and another account then sees and can upload it: BUG-005.**
  - [x] Change password (qa-002): empty → "Fill in both passwords."; wrong current → "Could not change password. Check your current password, then try again."; "abc" → "Password is too weak. Use at least 6 characters."; mismatch → "New passwords do not match."; success via Enter in Confirm (dialog closes). Old password then rejected at sign-in, new one (`qavoyager2027`) works; recorded in PROGRESS.md.
  - [x] Startup page: First → Journal after sign-up; Last seen → Finance after a restart and Settings after sign-in; Custom (To-Do) → To-Do after a restart while the last page seen was Finance. DB: `startup_page_mode`, `custom_startup_page`='/todo'.
  - [x] Relaunch while signed in skips the login page; relaunch after sign-out shows it (`vm.ps1 whoami` = SIGNED-OUT).
  - [x] First-run defaults match: dark, scatter on (lit 0.025), wave off, scale 15, intensity 0.67 (UI 67%), glow spread 1.10, focal (0.1, 0.5), floor 0.8, accent #7c9eff; light: 160 petals, fall 39, 2 minor colours.
- **Five-dimension sweep:**
  - D1 functional: flows above.
  - D2 data: new entry in SQLite at once; outbox drained (0) throughout; restart keeps the entry; cold re-login restores qa-002's entry; settings writes checked by SQL.
  - D3 visual: login card at maximized, min (1440×1040) and 2000×1100: no overflow. First-run pages at maximized in Dark + Scatter. Light spot-check: Appearance, Journal, To-Do, Account, login page (login page follows the saved theme): all legible. No `RenderFlex overflowed` in any run log.
  - D4 keyboard: BUG-006 (no initial focus, focus lost after a failed submit, invisible button focus, buttons ignore Enter/Space; Create account unreachable by keyboard). Vim-ON behaviour in the login fields deferred to P3.
  - D5 failures: 300-char e-mail (field scrolls; "Enter a valid email address."), malformed e-mail, weak password, double Enter, wrong current password. Not done: `stop.ps1` mid sign-in.
- **Test data:** qa-002 (1 journal entry; password `qavoyager2027`), qa-003 (orphan entry from BUG-005 in its cloud copy; startup page Custom → To-Do).
- **Skipped/blocked:** Forgot password with an e-mail (MANUAL-ONLY); interrupting a sign-in with `stop.ps1` (not done, low value); Vim ON in the login fields (P3).

## Phase 2 — Shell, navigation, window & tray
- **Status:** Done (2026-09-29). Bugs: BUG-007 (Cosmetic), BUG-008 (Cosmetic), BUG-009 (Minor), BUG-010 (Major), BUG-011 (Minor), BUG-012 (Minor).
- **Scope:** nav rail (order, hidden pages, selection), Ctrl+Tab/Ctrl+Shift+Tab, clock + weather button → forecast sheet, connectivity/sync activity indicators, shortcuts dialog (Ctrl+/), window min size/resize/maximize/restore, close-to-tray, tray menu (Open/Quit), page state kept across switches, the shell back interceptor. **Deferred:** global hotkeys/floaters → P5; inbox bell → P6; nav order/hidden/startup-page *settings dialogs* → P25 (use them here only to see the rail react).
- **HLD docs:** GLOBAL_HOTKEY_FLOATERS_HLD.md §window/tray, AUDIT_TESTING.md, BACKGROUND.md, DESIGN.md
- **Flows:**
  - [x] Every rail item navigates; the selected item is outlined in the accent colour; hover fills the item. The debug build adds a **Demo** item (debug-only, out of scope). Dev is hidden by default.
  - [x] Ctrl+Tab / Ctrl+Shift+Tab: default order Journal → … → Workout → Demo → Settings → Journal (wraps both ways). After moving Jobs to the top and hiding Dreams + Calendar (and showing Dev): Settings → Jobs → Journal → To-Do → Search → … → Dev → Settings; hidden pages skipped. 20 Ctrl+Tabs 40 ms apart landed exactly on the computed page (Rankings), no errors.
  - [x] Ctrl+Tab with a dialog open (Manage lists, shortcuts list): blocked. From a text field (journal body; To-Do composer with Vim ON in both Normal and Insert): **navigates** to the next page, and the typed text is kept on the page. Accepted as intended (the handler is a global `HardwareKeyboard` handler; the plan only asked whether it acts).
  - [x] Page state kept across switches: To-Do scroll position (40 tasks), an unsaved journal body, the To-Do composer draft, the forecast sheet's selected day.
  - [x] Rail at min window (1440×1040 phys): shows ~9 items with a fade at the cut, scrolls to reach every page (top: Jobs…; bottom: …Dev, Settings). The clock/weather and inbox stay fixed.
  - [x] Clock: changes minute up to 30 s late → **BUG-007**. Weather not configured: sunny icon, empty sheet with no route to Settings → **BUG-008**. After "Chicago, US" (Settings → Pages → Weather location; ~15 s to save): rail cloud + 25°, forecast sheet with 5 daily cards; picking a day redraws the chart; Esc and X close it.
  - [x] Offline badge: red no-wifi icon above the inbox 19–28 s after Dev → Force offline; it squeezes the rail list (Settings then needs a scroll). Clears within 9 s after turning it off.
  - [x] Ctrl+/: lists General, Anywhere in Windows, Text editing, Calendar, To-Do, Finance, Study & LeetCode sessions, Image viewer; scrolls; Esc, Close and a second Ctrl+/ close it; reopens. Changing Calendar "previous period" to Y showed "← / →, Y / L" at once (restored to H).
  - [x] Window: min clamps at 1440×1040 (a 1000×700 request stays 1440×1040); 2000×1100 and maximized reflow without overflow; Win+Down restores then minimizes, activate restores; maximize again OK.
  - [x] Close (WM_CLOSE) hides to tray, process stays; tray "Open Voyager" restores the placement (normal 200,100 2000×1100 and maximized both kept). Ctrl+Alt+T while hidden opens the to-do floater (hotkeys stay registered); Esc and the same hotkey don't close it (by design per GLOBAL_HOTKEY_FLOATERS_HLD §2); tray Open brought the main window back maximized. Tray Quit: process exits, outbox was 0, log ends "Lost connection to device".
  - [x] Second launch: the new process exits within 10 s and the running one stays; when the running one is hidden in the tray, the second launch shows it (foreground, maximized).
  - [x] Rapid rail clicking (20 clicks, 60 ms apart) ended on the last clicked page (Life), no errors.
  - [x] Shell back interceptor: n/a on desktop (Android Back only; no desktop key maps to it).
- **Five-dimension sweep:**
  - D1 functional: flows above.
  - D2 data: 40 tasks, 1 journal entry, nav order/hidden pages, weather location, calendar key all in SQLite at once; outbox 0 throughout; tray Quit → relaunch kept everything (and startup "First" opened Jobs, the new first page); cold re-login (wipe + sign in) restored all of it into SQLite, but the Journal page didn't show the pulled entry until a restart (**BUG-010**), the landing page ignored the pulled startup setting (**BUG-011**) and To-Do opened on an empty hidden built-in list (**BUG-012**).
  - D3 visual: maximized, min (1440×1040), 2000×1100 in Dark + Scatter; no `RenderFlex overflowed` / FlutterError in any of this session's run logs (`run-20260929-161755`, `-164745`, `-164850`, `-164924`, `-165102`); `voyager_errors.log` got only APP START lines. Light spot-check (Settings, shortcuts list, forecast, To-Do): legible; lead: the To-Do header "QA List 40 | 0" is pale green on cream (P9/P25).
  - D4 keyboard: Ctrl+Tab/Ctrl+Shift+Tab/Ctrl+/ work; rail buttons are deliberately excluded from the Tab order; Tab from nothing focused goes nowhere and focus is never visible → **BUG-009**. Vim ON: Esc in the To-Do composer → NORMAL badge; Ctrl+Tab still navigates (see above). Vim turned back off.
  - D5 failures: 20× rapid Ctrl+Tab and rail clicks; hide to tray mid-edit (journal body saved and kept); below-min resize; offline badge on/off; weather unset.
- **Test data:** qa-004: list "QA List" (40 tasks "QA task 01".."40"), built-in "To-do" list (empty, BUG-012), journal `__legacy__` with 1 entry (body "QA draft body for state check MIDEDIT-TRAY"), nav order Jobs first, Dreams + Calendar hidden, Dev visible, weather "Chicago, Illinois, US".
- **Skipped/blocked:** hotkey floaters beyond "still registered" (P5); inbox bell (P6); click-outside floater dismissal (needs a probe-owned window, not built); multi-monitor (out of scope).

## Phase 3 — Vim modal keybinding system
- **Status:** Done (2026-09-29). Bugs: BUG-013 (Minor), BUG-014 (Minor), BUG-015 (Blocker), BUG-016 (Minor), BUG-017 (Minor), BUG-018 (Minor), BUG-019 (Cosmetic), BUG-020 (Minor, follow-up).
- **Scope:** the Vim-lite engine in text fields (`lib/core/vim/`) across field types: single-line, multi-line journal body, dialogs, floater fields. Mode badge/caret, every command in VIM.md, conflicts with app shortcuts, Esc semantics. **Deferred:** floater-specific focus → P5; page-specific keys (calendar h/l, SRS keys) are checked per page under D4.
- **HLD docs:** VIM.md, CAPS_LOCK.md (overlay/caret), CTRL_ENTER_SUBMIT_HLD.md, TEXTBOX_WIDGET.md
- **Method:** `qa/harness/vimcase.ps1 <cases.tsv> -VmExe <vm.exe>` sets the focused field's text + caret over the VM service, sends real keys, and reads back selection|mode|length|text. Case files: `qa/steps/p3-*.tsv` (~110 cases). Compile `vm.dart` once (`dart compile exe qa/harness/vm.dart -o <scratchpad>\vm.exe`) for 0.6 s probes. Undo cases need `{wait:1500}` after the fixture write, or it coalesces with the first edit.
- **Flows (Settings → Vim keybindings ON; type with `voy.ps1 type`/`key`, real VK presses):**
  - [x] Esc Insert→Normal: the caret steps back one, a block caret appears, and a "NORMAL" badge sits bottom-right of the field (right edge in one-line fields). `i I a A o O` enter Insert at the right spot. Fields start in Insert on every focus (by design); Insert shows no badge.
  - [x] Motions `h j k l w b e 0 $ gg G`: column memory across an empty line, `w` stops at punctuation, `G` → first non-blank of the last line. Counts: `3w`, `2j`, `100w`, `999x` (count capped at 100000). **`h` wraps to the previous line and counted `l` crosses lines; `dh`/`d5l` delete the line break → BUG-013.**
  - [x] `f F t T` plus `;` `,`; `.` repeats `x`, `dw` and `ciw…Esc`.
  - [x] `d c y` with motions, `dd cc yy`, `D`, `dj`, Visual `v`/`V` (+ `d`, `y`), `x`/`3x`, `r`, `~`, `p` (charwise and linewise), Ctrl+V, `u`, Ctrl+R. **`yy` moves the caret to column 0 → BUG-018.**
  - [x] `/` search bar (bottom-left under the field, shows "n|total"): incremental preview, highlights, `n`/`N`; Esc restores the caret. **A pattern with no match leaves the caret on a partial match → BUG-014.**
  - [x] Pending state cleared by Esc: `d Esc l` and `f Esc l` move one right. The HUD shows "NORMAL 2d" while pending.
  - [x] Single-line fields (journal Title, New list name, To-Do composer): `o`/`O` act as `A`/`I`, `j`/`k` do nothing, `dd` clears, multi-line Ctrl+V is flattened. **Enter in Normal doesn't submit → BUG-016.** Enter in Insert does; Ctrl+Enter from Normal saved a calendar event.
  - [x] Esc in a dialog's field (New list, calendar event popover): the first Esc → Normal; further presses are swallowed, never close the dialog, and the typed text is kept. Intended per `vim_session.dart`; consistent in both dialogs tried.
  - [x] App shortcuts from Normal and Insert: Ctrl+/ opens the shortcuts list, Ctrl+F opens To-Do search, Ctrl+Enter saves the event form, Ctrl+Tab navigates (P2). Calendar `h`/`l` don't change the month while typing in the event title (Insert or Normal).
  - [x] Clipboard (by design the register is **not** the OS clipboard): `yiw`/`yy` leave the OS clipboard untouched; `p` pastes the register; Ctrl+V pastes the OS clipboard in Normal (after the caret) and in Insert; Visual + Ctrl+C copies to the OS clipboard and drops to Normal.
  - [x] Vim OFF: letters type normally, Esc does nothing to the text, no badge.
  - [x] Toggling: n/a while a field is focused (the toggle is on the Settings page, so the field loses focus). After Ctrl+Tab away and back, no field has focus; clicking back in starts in Insert.
  - [x] Caps Lock in Normal: `x` acts as `X` and `g` as `G`, same as real Vim. The Caps Lock mark shows in Normal and Insert; it sits over the next characters, by design per CAPS_LOCK.md.
- **Failure cases:**
  - 508-char line: `$`, `100w`, `0`, `j` and a missed `f` are all correct.
  - Multi-line text with empty lines: correct. CJK: `w` and `x` correct.
  - **Emoji: `l`/`h` land between the surrogate halves; `x` leaves "�" (saved and synced); inserting there crashes the app → BUG-015.**
  - Rapid bursts (10×`w`, 20×`x`, `dw` + 8×`.`, typed 25 ms apart): processed in order, nothing dropped.
  - Huge counts: `99999999999999999999x` stops at the line end.
- **Five-dimension sweep:**
  - D1 functional: flows above.
  - D2 data: every edit autosaved to `journal_entries_table` (checked by SQL); outbox 0 throughout. `stop.ps1` → `launch.ps1` kept `vim_mode_enabled=1`, theme dark, 2 lists / 1 task / 1 event / 1 entry. The crash (BUG-015) lost nothing that had already been autosaved. Cold re-login not done; the Vim setting is a synced setting, and its sync belongs to P25/P26.
  - D3 visual: badge, pending HUD, Visual/V-line highlights and `/` prompt checked at maximized, 2000×1100 and 1440×1040. **At minimum size the prompt overlaps the quote → BUG-019.** Light spot-check (search, Visual, pending HUD): legible. No `RenderFlex overflowed`. The only FlutterErrors came from BUG-015 (UTF-16), plus two "Build scheduled during frame" entries in `voyager_errors.log` caused by the harness's VM-service fixture writes (stack frame `Eval`; not an app bug).
  - D4 keyboard: covered by this whole phase. Normal mode doesn't swallow Tab, so focus traversal still works (per code).
  - D5 failures: see Failure cases. The crash was reproduced twice (17:18:53, 17:19:53).
- **Test data:** qa-005:
  - Journal `__legacy__` with 1 entry (title "L1\rL2"; body "alpha beta gamma delta / one two three four five / / foo(bar, baz); qu.end ENDhjkl dd x").
  - List "Vim List" plus the built-in "To-do" (BUG-012); task "task insert enter".
  - Calendar event "hello lll hhh" (Sep 29). Vim ON.
- **Skipped/blocked:**
  - Floater fields (P5).
  - Visual mode + text objects beyond `ciw`: not covered exhaustively.
  - ~~`>`/`<`, `J`, `%`, `{`/`}` exist in the code but aren't in VIM.md; not tested.~~ Done in a follow-up session (2026-09-29): about 125 cases in `qa/steps/p3x-*.tsv` (generators `p3x-gen*.py`) cover every command the code has beyond VIM.md; VIM.md now documents them (sections 9–16). New bug: BUG-020 (Minor: `V j J` joins one line too many). BUG-013 got a note (Space doesn't wrap, Backspace does). Untested: the backtick text object (the harness types `r` for a backtick on this PC's layout `0409:00060409`) and Esc clearing the search highlights.
  - Cold re-login.
- **Leads:**
  - (P4) Autocorrect turned "qux." into "qu.", because "qu" is in `assets/dictionary_en.txt`.
  - (P9) Closing the Ctrl+/ list returns focus to the composer with its text fully selected.
  - (P9) With To-Do search open and empty, the list shows no tasks.

## Phase 4 — Text-editing helpers
- **Status:** Done (2026-09-29). Bugs: BUG-021 (Major), BUG-022, BUG-023, BUG-024, BUG-025, BUG-026, BUG-027, BUG-028, BUG-032 (Minor), BUG-029, BUG-030, BUG-031 (Cosmetic).
- **Scope:** autocorrect, spell check + suggestions, custom dictionary and flagged words (Settings → Dictionary), text snippets (Tab/Space expansion; Settings → Text snippets), Caps Lock indicator, emphasis formatting (bold/italic markers), list indent/outdent (Tab/Shift+Tab), right-click snippet menu, Ctrl+Enter submit, image paste (Ctrl+V) + lightbox (←/→/Esc), multiline scroll insets. **Deferred:** Vim → P3.
- **HLD docs:** AUTOCORRECT.md, DICTIONARY.md, FLAGGED_WORDS.md, SNIPPET.md, RIGHT_CLICK_SNIPPET.md, CAPS_LOCK.md, EMPHASIS_FORMATTING.md, MULTILINE_FIELD_SCROLL_INSETS.md, MEDIA.md, CTRL_ENTER_SUBMIT_HLD.md
- **Flows:**
  - [x] Autocorrect (Vim OFF, journal body; cases `qa/steps/p4-ac*.tsv` via `vimcase.ps1`): `wtih`→`with` on Space `,` `.` `*`; first-letter case kept; ALL CAPS, `#tag`, unclosed backtick, `-`, digit, possessive, 2-letter words and single-line Title all left alone; flash visible (`p4-flash-sheet.png`); immediate Backspace reverts + suppresses; toggle off in Settings stops it (setting 0 in SQL). **Wrong-word rewrites → BUG-021 (Major); misspellings in the bundled dictionary → BUG-022; Enter never corrects → BUG-023; undo drops the space, redo does nothing → BUG-024; appending a letter at a word's end doesn't correct → BUG-025.** Vim ON: works in Insert.
  - [x] Squiggles, right-click suggestions (apply `with`), Add to dictionary (`littl` in `custom_words_table`), Flag as misspelling… popover (`neve` → `never`, Replace this one, pair rewrite with autocorrect OFF, `Neve`→`Never`, `NEVE` kept, Backspace revert). Dictionary dialog: bundled search ranking, add by Enter, "already in the dictionary", shape errors, rename onto a bundled word ("Removed … already in the dictionary"), allow-wins on a flagged word, flag from search with/without replacement, replacement errors (flagged / unknown / same word). Flagged `form` with no pair cascades to `from` as designed. **Focus lost after a rejected Enter → BUG-026.**
  - [x] Snippets: dialog create (empty-trigger and duplicate errors), edit (tick auto-expand), Ctrl+Enter saves a row; right-click → Add snippet popover (trigger prefilled, focus on Replacement, focus returns to the field). Expansion: Tab (manual), auto, inside a word, tabstops `($0)$1` + Tab advance, undo restores trigger (manual and auto), no expansion on programmatic write or delete-join, Title field too, autocorrect skips a trigger word. Space key: expands without inserting a space; Tab then inert; empty body; 1,000-char body. Vim Normal doesn't expand. **List line: Tab indents instead of expanding → BUG-027.** Manual expansion inside an active tabstop isn't possible (Tab advances first, per SNIPPET.md §4.5; not logged). Keyboard: Tab from Replacement → Space didn't tick the checkbox (app-wide BUG-009).
  - [x] Caps Lock mark: body, Title, hidden with a selection and when off; flips left of the caret at the right edge (`p4-caps-*.png`).
  - [x] Emphasis: bold/italic/underline/highlight, nesting, `**#tag**` pill, code/LaTeX/`2 * 3`/bullets/unclosed literal, `__` inside words literal; reveal on caret/selection; survives restart (SQL keeps markers; editor and list preview render bold). **Intra-word `*` pairs across lines → BUG-028.**
  - [x] Lists (`qa/steps/p4-list*.tsv`): Enter continues `-`, `*`, `1.` lines (typed or pasted); Enter on an empty item exits the list; Tab indents / Shift+Tab outdents; Shift+Tab at top level does nothing. A numbered sub-item keeps counting (`  3. c`) rather than restarting at 1 (noted, not logged). A programmatic single-line fixture doesn't continue on Enter (harness artifact; paste and typing do).
  - [x] Ctrl+Enter: works on Finance new transaction (saves from Amount; does nothing on an empty form; the Enter chain is Amount → Store → Note → Tags → save), Rankings new category, Jobs track modal (Enter = newline in Notes, Ctrl+Enter saves), Study new deck, snippet editor row; calendar event form in P3. Not tried: study card editor, search entry dialog, quote dialog, bucket list.
  - [x] Images (journal): clipboard with the registered "PNG" format pastes into the body → fan in the corner, stored as JPEG, uploaded; lightbox opens on image 1, ←/→ move (no wrap at the ends), Remove asks to confirm and keeps the file 30 days (`unreferenced_at`), Esc closes; oversize (34.4 MB) rejected with a toast; text+image clipboard pastes both; image-only into the Title is a no-op; Settings → Data → Image storage lists every file with use counts. A bitmap-only clipboard (`CF_DIB`, e.g. .NET `SetImage`) is ignored silently: only PNG/JPEG/WebP/HEIC formats are read (noted). 9 pastes 150 ms apart kept 7 (a paste arriving while the previous is decoding is dropped by design; not humanly reachable). **Every upload logs an engine thread error → BUG-032.** Dream/study image paste not done.
  - [x] Multiline scroll insets: scrolled body keeps a top strip showing the previous line's descenders → BUG-029 (open issue in MULTILINE_FIELD_SCROLL_INSETS.md). Bottom edge OK.
- **Failure cases:** huge image, non-image clipboard, 10 fast pastes, empty-body and 1,000-char snippets: covered above.
- **Five-dimension sweep:**
  - D1 functional: flows above.
  - D2 data: custom/flagged words, snippets (6), settings (`autocorrect_enabled`, `snippet_expand_key`, `vim_mode_enabled`), entry body with markers, transactions, job, deck, ranking category, media rows all in SQLite at once; outbox 0 throughout. `stop.ps1` → `launch.ps1` kept all of it. Cold re-login (reset -Force → launch → login) restored custom words, flags (with tombstones), 6 snippets, settings, the entry and all 8 live images (downloaded, `present`).
  - D3 visual: maximized, 2000×1100 and 1440×1040 in Dark + Scatter; light spot-check of Editing, snippets dialog, dictionary dialog, journal. Found BUG-029, BUG-031; entry preview BUG-030. No `RenderFlex overflowed` / FlutterError in `run-20260929-174952`, `-175135`, `-182045`, `-220439`; `voyager_errors.log` got only APP START lines. Leads: the Rankings "New category" dialog's "Name" label is clipped at the top at 2000×1100 (P19); the "image too large" toast covers the Title label (cosmetic).
  - D4 keyboard: Ctrl+Enter above; Vim ON gates autocorrect and snippets to Insert. BUG-026 (focus lost after a rejected Enter in the dictionary dialog). Snippet editor: Tab reaches Replacement, but Space doesn't tick the checkboxes (BUG-009). The dictionary search field isn't focused when the dialog opens.
  - D5 failures: see Failure cases; rapid pastes; interrupted by the notification panel (see Skipped).
- **Test data:** qa-006: journal `__legacy__` with 1 entry (title "Long title words …" ×12; body "Met Dr. Smith at 3 p.m. today neve"; 8 images); custom word `littl`; flagged `form` (no replacement); snippets `;sig`, `addr` (auto), `pp` (`($0)$1`), `wtih`, `zz` (empty), `lng` (1,000 chars); expand key **Space**; transactions $12.34 (Shop, #food) and $5.00; job "Acme"/"x"; study deck "Deck A"; ranking category "Books". Test images in `qa/data/` (`img01..10.png`, `huge-noise.png`).
- **Skipped/blocked:** image paste into dreams and study cards; drag-and-drop and the gallery file picker (native dialog), moved to the P7 (drag-and-drop), P8 (dream paste), P9, P19 and P21 (file picker, galleries, card faces) checklists; Ctrl+Enter on the remaining inventory surfaces; the backtick autocorrect case needs clipboard input (typed via fixture instead). At 18:22 the session stalled for ~3 h: a click on the Finance "+" FAB at maximized hit the auto-hidden taskbar clock and the Windows notification panel held the foreground until Juno closed it (quirk in PROGRESS.md §5).

## Phase 5 — Global hotkeys & floaters
- **Status:** Done (2026-09-29). Account qa-007. Bugs: BUG-033 (Minor), BUG-034 (Minor), BUG-035 (Minor), BUG-036 (Cosmetic), BUG-037 (Minor), BUG-038 (Minor).
- **Scope:** Ctrl+Alt+J/T/F/R (journal notepad, quick to-do, quick transaction, quick reminder) from (a) main focused (in-app path), (b) another app focused (floater window), (c) main hidden in tray, (d) main minimized; floater save/close/draft retention, replacement between floaters, Esc behaviour, click-outside dismiss, Open app; rebinding in Settings (key binding dialog), conflicts/duplicates. **Deferred:** the resulting data's page behaviour → P7/P9/P13/P6.
- **HLD docs:** GLOBAL_HOTKEY_FLOATERS_HLD.md, AUDIT_TESTING.md (what was already covered and the open findings 1–12; re-verify those rather than rediscover them), AUDIT.md (empty now)
- **Harness added:** `qa/harness/OtherApp.cs` (probe-owned WinForms "other app", compiled by `voy.ps1`): verbs `other-open`, `other-click`, `other-type`, `other-topmost`, `other-close`, `ostatus`, `other-grab`, `tray-menu`, `minimize`. Step files `qa/steps/p5-*.txt`.
- **Flows:**
  - [x] Each hotkey from each of states (a)–(d): (a) in-app T → To-Do + composer focused (+ draft), J → Journal + today's QJE, F → Finance + transaction sheet (+ draft), R → "New reminder" over the current page; (b) floaters take the foreground and are topmost: to-do bar 680×68 upper-centre, notepad 380×320 bottom-right, finance 640×529 centre, reminder centre; first field focused; (c) from the tray: floater shown, main stays hidden after dismiss; (d) minimized: floater shown, main minimized again after dismiss. Placement restored after dismiss at 2000×1100, maximized and 1440×1040.
  - [x] Save from each floater → row in DB, confirmation ("Added to To-do", "Transaction added", "Reminder added", "Quick entry deleted"), draft cleared, outbox drained; main app shows it. Enter saves the to-do; Ctrl+Enter saves finance and reminder; Tab walks amount → store → note. Focus returns to the previous app after save/dismiss.
  - [x] Click-outside keeps the to-do and finance drafts (reminder deliberately discards, HLD §7a.2); drafts gone after restart; the QJE rebinds after restart (pointer file) but **not** after a wipe + sign-in (BUG-038). Open app moves the draft to the composer (arrives selected, BUG-033).
  - [x] Hotkey A while floater B is open → replaced (T→F→J→R, all orders); same hotkey twice → no-op. Spam: 10× same key, 16-key mixed bursts at 0–300 ms gaps, in-app bursts: final state correct; once, reentrant-frame assertions on replacement (BUG-035, not reproduced in 6 retries).
  - [x] Quick reminder floater: empty/spaces title → "Give the reminder a title"; time picker (date grid + time text) accepts "9:00 PM"; a past time shows "That time has already passed" but Create still saves an enabled once-rule (lead for P6); the 23:00 rule fired (sticky + OS toast logged) while a to-do floater was open, without disturbing it. In-app editor clips at short heights (BUG-036).
  - [x] Rebinding: n/a. Settings → Editing lists the four combos read-only (HLD §1/§8: no editor in this work). Conflict: a combo another process owns at launch is silently never registered and never retried (BUG-034).
  - [x] Vim in floater fields (ON): Normal badge, `0x`, `A`, `G o`, `0 dw`, `b D` all correct in bar, notepad, finance store, reminder title; Esc never closes a floater, Vim ON or OFF (OFF: Esc unfocuses the field, floater stays).
  - [x] Re-verified AUDIT_TESTING findings: 1 (dismiss reflow errors) not seen in any dismiss (BUG-035 is a different path); 3 (WM_CLOSE on a focused floater) fixed: window returns to its prior minimized state; 4 (hero null check on replacement) not seen; 5 (two finance sheets) fixed; 7 (tray menu stays open after clicking elsewhere) still happens **with a posted tray click**, but the app now calls `popUpContextMenu(bringAppToFront: true)`, and a posted click can't grant foreground, so needs a real icon click (manual); 10 (main left topmost after dismissing into a topmost window) fixed; 11 (focus on a FocusScope) fixed, though the draft arrives selected (BUG-033); 12 (sheets left over Journal) fixed.
  - [x] "Another app focused" window built (`OtherApp.cs`).
- **Five dimensions:** D1 above. D2: every save checked in SQLite, outbox 0; restart (stop/launch) and cold re-login (reset -Force → launch → login) restored the to-dos, transactions, reminder rules and QJEs; 5,300-char titles/bodies with CJK, emoji and Arabic saved intact. D3: floaters at 2000×1100, maximized and 1440×1040 main placements; light-theme spot-check of all four floaters (fine); BUG-036 for the in-app reminder editor. D4: Enter/Ctrl+Enter/Tab as above, BUG-037 (empty Enter drops focus). D5: empty/whitespace/0/huge/negative/letters in finance amount (rejected or filtered correctly), long input, spam, hotkey during startup (193 presses from launch on: a to-do floater opened, no errors), quit from the tray with the notepad open (text flushed; exit took >3 s), other process owning a combo.
- **Failure cases:** hotkey spam (10× quickly), hotkey during app startup, floater open while the app quits from tray.
- **Skipped/blocked:** multi-monitor (out of scope). Force offline (Dev page hidden; floater saves go through the same local DB + outbox as in-app saves, covered in P26). QJE rollover across local midnight (not run; would need a notepad left open across 00:00). A real tray-icon click for finding 7 (the taskbar icon isn't reachable by the probe; MANUAL).

## Phase 6 — Notifications, inbox & reminders
- **Status:** Done (2026-09-30). Account qa-008. Bugs: BUG-043 (Major), BUG-039, BUG-040, BUG-041 (Minor), BUG-042 (Cosmetic).
- **Scope:** notification bell + inbox popover (sections, hide/restore, dismiss), reminder bell buttons on todos/events (entity reminders), reminder sticky stack, scheduled reminder rules (Settings), OS toast notifications (flutter_local_notifications), Settings → Devices, unified notifications. **Deferred:** creating the todos/events themselves → P9/P10.
- **HLD docs:** INBOX_POPOVER_HLD.md, INBOX_HIDDEN_RESTORE_HLD.md, SCHEDULED_REMINDERS_HLD.md (its header still says "design (not implemented)"; it is implemented), UNIFIED_NOTIFICATIONS.md
- **Method:** OS toasts verified read-only in Windows' notification store `%LOCALAPPDATA%\Microsoft\Windows\Notifications\wpndatabase.db` (handler `Voyager.App`; scratch `wpn.py`, see PROGRESS.md §5), plus `reminder_delivery_logs_table` (`stickyShown`/`osFired`). Step files `qa/steps/p6-*.txt`.
- **Flows:**
  - [x] Inbox empty state ("All caught up / Pin a reminder above…", no Hidden footer); a task due today shows in Notifications with an urgency dot, the rail icon gets the pulsing accent dot, header "N items need attention" + broom. Due-today tasks only (undated tasks don't appear). Feed labels are day-granular ("Today" for a task 9 min overdue; red only from the next day), by design in the code.
  - [x] Dismiss (hover ✕) → eye-slash toast `Hidden "bell task"` + Undo, Show-hidden eye in the header, Hidden (N) footer; Hidden expanded shows Restore all, selecting a row switches it to Restore (1); restore writes a synced tombstone. Undo within the 8 s dwell restores (hover holds the toast). Dismiss then Clear all → one toast rewritten to "Hidden 2 items"; Undo restores both. Pinned-note delete → `Deleted "…"` + trash icon + Undo (restored). Esc closes the Inbox (Vim OFF); Vim ON: NORMAL badge in the pinned-note field, `0x` works, extra Esc is swallowed (popover stays), as in P3.
  - [x] Scheduled rule CRUD: Once/Daily/Weekly, note, time chip picker (type "12:32 AM" + Enter), device chips; validation "Give the reminder a title", "Pick at least one day", "Pick at least one device"; row menu Edit / Turn off / History / Delete (Deleted toast + Undo); list caps at 4 rows + "Show N more"; due rows highlighted. Fires to the second (`stickyShown`/`osFired` at hh:mm:00.0x) with a sticky (Snooze 10 min / Tomorrow / Acknowledge) and a Windows toast (title + note). Ack of a once-rule disables it ("Completed"); editing it to a future time + On re-arms it. Snooze 10 min returned exactly at +10:00 (new OS toast); Tomorrow = next day at the press time (Oct 1 00:39:30). History dialog lists shown / notification / snoozed / acked.
  - [x] Entity bells: to-do bell disabled until a due date is set; presets No reminder / At time / 15 min / 1 h / 1 day / Custom…; changing the due time moved the fire (12:52 → 12:50 fired at 12:50:00); event bell "15 minutes before" 1:30 event fired at 1:15 ("Starts 1:30 AM", occurrence keyed on the start). Sticky title deep-links to the task (To-Do, panel open). Completing the task from the Inbox checkbox cleared its sticky; deleting the event (confirm → Deleted + Undo) cleared its sticky (the bell row stays, the engine skips deleted entities). A rule deleted while snoozed did not fire at its snooze end.
  - [x] Fires while hidden to tray (snooze return at 12:44:04) and while minimized (to-do bell 12:50); both sticky + OS toast.
  - [x] Devices: this device listed ("· This device", platform, last seen, notification permission row); rename (empty + Enter = silent cancel; "QA Zephyrus" saved + synced); last seen refreshes at most once an hour by design (`kDeviceLastSeenRefresh`), seen updating 12:26 → 1:27; after a wipe + sign-in a second row appears (HLD §4.1 by design); removing the stale row asks to confirm and soft-deletes it. P1/P2 leads resolved as intended behaviour.
- **Failure cases:** past once-rule → saved enabled, never fires (**BUG-039**; also the P5 lead). 22 rules at the same minute: all 22 stickies + 22 OS toasts within 0.24 s (Action Center keeps 20, Windows' per-app cap); stack shows 3 + "+19 more"; 19 rapid Acknowledge clicks 150 ms apart acked exactly 19 in order. Force offline: a rule fired normally, ack/snooze worked (outbox still drained to 0: Force offline only fails the probe; P26). DST: task urgency and feed labels miscount across a 23-hour day (**BUG-040**, evaluated in the app isolate); scheduled-rule math uses calendar-day arithmetic and UTC-based labels, reasoned OK. Midnight: the session ran from 00:25, so every fire was just past midnight; no issue. Restart with a due sticky: it came back, no duplicate OS toast (a second `stickyShown` row per restart, by design of the per-run log).
- **Five-dimension sweep:**
  - D1 functional: flows above.
  - D2 data: every rule/state/log/bell/pinned note/dismissal/device write in SQLite at once; outbox 0 throughout. Restart (stop/launch) kept all. Cold re-login restored identical row counts, **but the app didn't load reminders, delivery states, pinned notes or dismissals until restart → BUG-043 (Major)**.
  - D3 visual: maximized, 2000×1100 and 1440×1040 in Dark + Scatter. **Stickies draw over the Inbox and dialogs; at min size they hide the editor's Create button → BUG-041.** Light spot-check: Inbox, editor, stickies; **"Show N more" 1.2:1 contrast, Acknowledge loses its accent → BUG-042.** No FlutterError / overflow in `run-20260930-002518`, `-003942`, `-020051`, `-020458`; `voyager_errors.log` got only APP START lines. Clock lag (BUG-007) seen repeatedly.
  - D4 keyboard: Enter adds a pinned note; Enter commits the time field; Ctrl+Enter creates from the editor (the workaround for BUG-041); Esc closes the Inbox; Vim ON as above. Tab traversal not re-tested (BUG-009 app-wide).
  - D5 failures: see Failure cases.
- **Test data:** qa-008 (see PROGRESS.md §2).
- **Skipped/blocked:** clicking an OS toast (tap → app focuses that sticky) — the toast is outside Voyager's window, which the probe guard refuses; MANUAL. Natural-occurrence-supersedes-snooze and same-rule coalescing need a daily rule to cross a day; reasoned from `evaluateReminder` (a newer occurrence key wins over a snooze/unacked state), not observed. Real multi-device ack sync (one PC). Custom… lead-time dialog not exercised. Stale OS toasts: on Windows, acknowledging/deleting doesn't withdraw a shown toast from Action Center (`dismiss` is a deliberate no-op for an unpackaged app); a re-fire of the same source replaces its toast. Noted, not logged.

## Phase 7 — Journal
- **Status:** Not Started
- **Scope:** journals (create/rename/delete, manage sheet, journal settings dialog), entries (new, edit title/body/mood/date-time/weather icon/tags, delete + undo), entry list (all entries vs one journal, ordering, list width drag), quotes on entries + custom quotes randomizer, guided prompts, On This Day overlay, quick-journal-entry (QJE) interplay, geometric texture background. **Deferred:** Vim → P3; images/snippets/autocorrect → P4; search → P11; trash → P24.
- **HLD docs:** JOURNAL_DATA_LOSS_POSTMORTEM.md (known risk areas), SAVING.md, ON_THIS_DAY_HLD.md, SESSION_RESUME_HLD.md, UNDO.md, DRAFT.md, SOFT_DELETE_TOAST.md
- **Flows:**
  - [ ] Create a journal; create entries in it; switch journals; "all entries" view
  - [ ] Autosave: type, wait, check DB; type then immediately navigate/close to tray/`stop.ps1` → is the text there after relaunch? (data-loss focus)
  - [ ] Edit title, mood slider, date/time picker (past/future dates), weather icon, tags
  - [ ] Delete entry → toast undo → restored exactly; delete without undo → Trash
  - [ ] Journal rename/delete (what happens to its entries?), manage sheet reorder
  - [ ] Quotes toggle; custom quotes dialog CRUD; randomizer doesn't repeat immediately
  - [ ] On This Day: seed entries dated 1 month / 1+ years ago → overlay appears per the cadence setting
  - [ ] Entry list sorting with many entries (seed 50+ across dates), scroll performance, list-width drag persists
  - [ ] (from P4) Drag-and-drop an image file onto the journal body → joins the fan. Needs a probe-owned drag-source window under `qa/harness/` (never drag from Explorer); build it here and reuse it in P9/P21. Also drop a non-image file and a GIF (should be refused, MEDIA.md: no GIF).
- **Failure cases:** 10,000-char body, a 300-char unbroken title, empty entry (created at all?), rapid New entry ×10, two entries same timestamp, date far in the past (1900) / future (2100).
- **Test data:** 2 journals, ~50 entries across 2 years (script via the UI or step files; record in PROGRESS.md).
- **Skipped/blocked:** —

## Phase 8 — Dream journal
- **Status:** Not Started
- **Scope:** dream entries (title/note, sticky notes, branch painter visuals), split pane width, dream search, dream images, delete + undo, dream stats (to Analytics, if enabled). **Deferred:** images mechanics → P4; Search page → P11.
- **HLD docs:** DREAM_JOURNAL.md
- **Flows:**
  - [ ] Create/edit/delete dreams; autosave + restart; switch entries mid-typing (no cross-contamination)
  - [ ] Title submit moves focus to the note; tab focus between fields
  - [ ] Dream search within the page; split-width drag persists (device-local)
  - [ ] Delete → undo; delete → Trash
  - [ ] "Show dream statistics in analytics" reflects in P12 (quick check)
  - [ ] (from P4) Image paste into a dream (Ctrl+V with the registered "PNG" clipboard format; see PROGRESS.md §5 "Image clipboard"): into an existing dream and into a brand-new unsaved one (the scope writes the row first, `onBeforeAttach`); thumbnails/lightbox; remove; row in `media_references_table` with collection for dreams; delete the dream → its references soft-deleted
- **Failure cases:** very long dreams, many dreams (100+) scrolling, rapid switching while typing.
- **Skipped/blocked:** —

## Phase 9 — To-Do
- **Status:** Not Started
- **Scope:** lists (create/rename/delete/reorder, manage sheet, settings dialog), tasks (add via composer, edit side panel: notes, due date/time, recurrence?, reminder bell, tags), complete/uncomplete, completed section collapse, hide completed, sort order, list search (Ctrl+F, Enter/Shift+Enter, Esc), "all tasks" view, statistics tiles. **Deferred:** reminders firing → P6; calendar markers → P10.
- **HLD docs:** TODO_EDIT_PANEL_UI.md, TODO_LIST_SEARCH_HLD.md, SOFT_DELETE_TOAST.md, UNDO.md
- **Flows:**
  - [ ] First list creation; add 30+ tasks quickly via the composer (Enter keeps focus?)
  - [ ] Edit panel: every field; open/close panel; panel width drag
  - [ ] Complete/uncomplete (completion records); the completed section; hide completed toggle
  - [ ] Reorder tasks and lists; sorting stable after restart
  - [ ] Ctrl+F search: matches, next/prev, Esc; search with no matches
  - [ ] Delete task/list → undo; list delete with tasks
  - [ ] (from P4) Edit panel gallery strip (MEDIA.md): paste an image onto the panel (not into notes; image-only into notes/title is a no-op), attach via the file picker (native dialog: type a full path from `qa/data/` + Enter), drag-and-drop (P7's drag helper), reorder by drag, remove; rows in `media_references_table`
  - [ ] "All tasks" view across lists; last-viewed list restored on relaunch
- **Failure cases:** 500-char task title, emoji titles, 200 tasks in one list (perf), rapid check/uncheck ×20, delete while the edit panel is open.
- **Skipped/blocked:** —

## Phase 10 — Calendar
- **Status:** Not Started
- **Scope:** week/month/year views and morph transitions, navigation (←/→, configured prev/next keys, today), calendars (create/colour/hide, manage sheet, show all), events (create/edit/delete, all-day vs timed, multi-day, recurring + delete occurrence vs series), overlap layout, event panel, todo markers + todo panel, calendar overlay dialog, import dialog (paste text / copy prompt), workouts on calendar, last-viewed calendar/page. **Deferred:** reminders firing → P6.
- **HLD docs:** WEEKLY_CALENDAR.md, CALENDAR_OVERLAY_HLD.md, TIME_SELECTOR.md
- **Flows:**
  - [ ] Each view; switch views; navigate periods by mouse and keys; Vim off/on (keys must not fire while typing)
  - [ ] Event CRUD in each view; drag/resize if supported; time selector spinner
  - [ ] Overlapping events (3–6 at the same time) layout; all-day + timed on the same day; multi-day across a week/month boundary
  - [ ] Recurring events: create, edit one vs all, delete occurrence
  - [ ] Calendars: hide/show changes the grid; colour change; delete a calendar with events
  - [ ] Todo markers from dated tasks; the todo popover live-updates when the task changes
  - [ ] Import dialog: valid paste, malformed paste, undo import
  - [ ] Week starts on Monday setting; year view density
- **Failure cases:** event ending before it starts, zero-length event, event spanning DST, 50 events in one day, very long titles.
- **Skipped/blocked:** —

## Phase 11 — Search
- **Status:** Not Started
- **Scope:** global Search page: query across journal/dreams (and whatever else it covers: find out), result list, opening/editing results in place (search entry save helpers), filters, empty/no-result states. **Deferred:** per-page search (To-Do/Finance Ctrl+F) → their phases.
- **Flows:**
  - [ ] Seed distinctive words in several entity types; each is found; result snippets highlight
  - [ ] Edit an entry from search results → saved; the original page reflects it
  - [ ] No results; single-char query; special characters (`"`, `%`, `_`, regex chars); case/diacritics
  - [ ] Deleted items don't appear; restored items reappear
  - [ ] Performance with 500+ entries
- **Skipped/blocked:** —

## Phase 12 — Analytics & trackers
- **Status:** Not Started
- **Scope:** analytics page: stat tiles (entries, words, best streak, dream/workout today, tasks), heatmap calendar (modes: all/mood/studying/writing/custom) + popover, mood trend card, sparklines, trackers (create integer/boolean/enum, daily/weekly/monthly/yearly cadence, independent/consecutive style, colour, default grid trackers setting), tracker entry rows, derived stat trackers, grid vs list view. **Deferred:** the finance analytics tab → P14.
- **HLD docs:** ANALYTICS_PAGE.md, ANALYTICS_EXPLANATION.md, ANALYTICS_FEEDBACK.md, LIFE_TRACKER.md
- **Flows:**
  - [ ] Empty account state; after seeding journal/todo/study data, numbers match hand counts (verify with SQL)
  - [ ] Streak logic across gaps and today/yesterday boundaries
  - [ ] Heatmap modes and popover; month navigation
  - [ ] Tracker CRUD for each type × cadence; log values; edit/delete values; statistics view
  - [ ] Delete a tracker with values → undo
- **Failure cases:** huge integer values, negative, enum with 20 options / empty option, 5 years of daily values (perf).
- **Skipped/blocked:** —

## Phase 13 — Finance A: ledger & transactions
- **Status:** Not Started
- **Scope:** Finance page Ledger tab: transaction modal (expense/deposit, amount, date, store/origin field, category, tags, note), duplicate, delete + undo (finance soft delete), ledger grouping by day, net-flow hero (ranges month/7/30/90/YTD), net-flow chart and calendar, ledger search + filters (tag/category/store, Ctrl+F/Esc), finance UI prefs (device-local tab memory). **Deferred:** categories/budgets/subscriptions → P14; goals/assets/room → P15; quick-transaction floater → P5.
- **HLD docs:** FINANCIAL_TRACKER.md, FINANCE_BREAKDOWN_AND_LEDGER_UX_HLD.md, FINANCE_HERO_NET_FLOW_CHART_HLD.md, FINANCE_TRANSACTION_ORIGIN_HLD.md
- **Flows:**
  - [ ] Add expense and deposit; hero totals and chart update correctly (verify sums with SQL)
  - [ ] Edit amount/date moves the row to the right day and updates totals
  - [ ] Duplicate; delete → undo; delete → Trash
  - [ ] Each hero range; chart tooltips; the net-flow calendar
  - [ ] Search and each filter kind; combined filters; clear
  - [ ] Tab memory (Ledger/Analytics/Goals) after restart
- **Failure cases:** amount 0, negative, 1e12, 3+ decimals, comma vs dot, pasted "$1,234.50", future-dated and 10-year-old transactions, 1,000 transactions (perf), rapid Save ×5 (duplicates?).
- **Skipped/blocked:** —

## Phase 14 — Finance B: categories, budgets, subscriptions & finance analytics
- **Status:** Not Started
- **Scope:** category modal CRUD, budget modal + budget panel (progress, over-budget), subscription modal (billing periods weekly→yearly), bill radar, annualized subscription cost setting, Analytics tab (breakdown by category/tag/store, spending vs income charts). **Deferred:** ledger basics → P13.
- **HLD docs:** FINANCE_BREAKDOWN_AND_LEDGER_UX_HLD.md, FINANCIAL_TRACKER.md
- **Flows:**
  - [ ] Category create/rename/recolour/delete (what happens to its transactions?)
  - [ ] Budget per category/month; spent vs budget math; over-budget visuals; month rollover
  - [ ] Subscriptions each period; next-bill dates; bill radar ordering; annualized toggle
  - [ ] Breakdown modes and charts match SQL sums; empty-data state
- **Failure cases:** budget 0, subscription billed on the 31st / Feb 29, deleted category still referenced.
- **Skipped/blocked:** —

## Phase 15 — Finance C: goals, assets & contribution room
- **Status:** Not Started
- **Scope:** Goals tab: savings goals (goal modal, allocate modal, allocations, progress ring), assets (asset modal, valuations, asset value chart), contribution rooms (create/join mode, room bar, room events, room history). **Deferred:** —
- **HLD docs:** FINANCE_CONTRIBUTION_ROOM_HLD.md
- **Flows:**
  - [ ] Goal CRUD; allocate/unallocate; over-allocation; completion
  - [ ] Asset CRUD; add valuations over time; chart; delete a valuation
  - [ ] Contribution room create + join modes; events; history; room math vs HLD (verify with hand calc)
- **Failure cases:** negative allocations, allocation > available, year boundaries for room.
- **Skipped/blocked:** —

## Phase 16 — Life tracker
- **Status:** Not Started
- **Scope:** life tree canvas (figure, leaves, blossoms), stats (birth date setting drives them), blossom stat popup, stat leader labels, tree popover, bucket list popup (CRUD, complete, delete + undo). **Deferred:** birth-date setting UI → P25 (use it here).
- **HLD docs:** LIFE_TRACKER.md
- **Flows:**
  - [ ] No birth date set → empty/prompt state; set one → stats correct (hand-calc ages/weeks)
  - [ ] Hover/click leaves and blossoms; popovers position at window edges
  - [ ] Bucket list CRUD; complete → reflected on the tree?; delete → undo
- **Failure cases:** birth date in the future, today, 120 years ago; 100 bucket items.
- **Skipped/blocked:** —

## Phase 17 — LeetCode A: dashboard, problems & review deck
- **Status:** Not Started
- **Scope:** dashboard (progress rings, activity calendar/chart/bubble, recent completions, tag matrix), track modal (+ device-local draft), problem detail view, review deck view, search popover, NeetCode 150 view (Settings), type highlighting. **MANUAL-ONLY:** LeetCode username sync; clicking out-links. **Deferred:** sessions/cram/scratch/cheat sheet → P18.
- **HLD docs:** LEETCODE_TRACKER.md, NEETCODE150.md, LEETCODE_TYPE_HIGHLIGHT_HLD.md
- **Flows:**
  - [ ] Empty state; track problems (each difficulty, tags, notes); edit; delete → undo
  - [ ] Track modal draft survives close/reopen and restart
  - [ ] Dashboard numbers vs SQL; activity calendar after tracking on several dates
  - [ ] Review deck lists due problems per the SRS rules
  - [ ] Search popover finds problems
- **Failure cases:** duplicate problem, huge notes with code, invalid URL field.
- **Skipped/blocked:** username sync (MANUAL-ONLY).

## Phase 18 — LeetCode B: sessions, cram, scratch pad & cheat sheet
- **Status:** Not Started
- **Scope:** session page (flip Space, grading keys, U/R history, C focuses scratch), cram page (←/→), flashcards, scratch pad (code editor, starter helpers, diff view, draft persistence), cheat sheet (Ctrl+Shift+C only on LeetCode; tabs/sections/entries CRUD, search, export, collapsed state), session resume toast/checkpoints. **Deferred:** Study sessions → P22.
- **HLD docs:** LEETCODE_CHEAT_SHEET_HLD.md, LEETCODE_SCRATCH_PAD.md, LEETCODE_SCRATCH_STARTER_HELPERS.md, SESSION_RESUME_HLD.md
- **Flows:**
  - [ ] Full review session with each grade key (and custom grade keys from Settings); SRS due dates update in DB
  - [ ] Keys don't fire while typing in the scratch pad; C focuses it; Esc leaves it
  - [ ] Cram mode ←/→
  - [ ] Interrupt a session (navigate away / stop.ps1) → resume toast on return/relaunch; resume state correct
  - [ ] Scratch pad: type code, draft survives restart, diff view, starters
  - [ ] Cheat sheet: Ctrl+Shift+C on LeetCode only (not on other pages); CRUD at 3 levels; search; export; last tab and collapsed sections remembered
- **Failure cases:** 2,000-line scratch code, tab characters, session with 0 due cards, 100 due cards.
- **Skipped/blocked:** —

## Phase 19 — Rankings
- **Status:** Not Started
- **Scope:** categories (category dialog, manage sheet tabs: settings/parent template/child template), parents & children (rows, child list, edit panel, field editor per template, score input + stars, tags field, parent tags), gallery and media grid (images), sorting. **Deferred:** image mechanics → P4.
- **HLD docs:** RANKINGS.md, RANKINGS_UI.md, RANKINGS_PARENT_TAGS_HLD.md, RANKINGS_SCORE_INPUT_HLD.md
- **Flows:**
  - [ ] Category CRUD; template fields of each type; template change on existing items
  - [ ] Parent/child CRUD; scores (bounds, decimals, stars); ordering by score; ties
  - [ ] Tags on parents/children; filtering
  - [ ] Gallery with images; delete item with images
  - [ ] (from P4) Gallery attach by paste and by the file picker (type a full path from `qa/data/` + Enter); reorder and remove
- **Failure cases:** score out of range / non-numeric, 200 items, very long names, delete a category with items → undo.
- **Skipped/blocked:** —

## Phase 20 — Jobs
- **Status:** Not Started
- **Scope:** jobs table (applications), track modal (+ smart paste from clipboard: title/URL parsing, device-local draft), edit panel, stages/categories/seasons (manage sheet), status events, header stats/charts, company field autocomplete, experience snippets (Settings dialog + in header), job application profile (Settings). **MANUAL-ONLY:** opening job URLs.
- **HLD docs:** JOBS.md, JOBS_SMART_PASTE_HLD.md, JOBS_EXPERIENCE_SNIPPETS_HLD.md
- **Flows:**
  - [ ] Add applications manually and via smart paste (clipboard fixtures from JOBS_SMART_PASTE_HLD.md examples)
  - [ ] Move through stages; status events history; charts update
  - [ ] Manage stages/categories/seasons: add/rename/reorder/delete in-use ones
  - [ ] Experience snippets: copy to clipboard, CRUD
  - [ ] Draft survives restart
- **Failure cases:** malformed pasted text, 300 applications, duplicate company names/case.
- **Skipped/blocked:** URL opening (MANUAL-ONLY).

## Phase 21 — Study A: library, decks & card editing
- **Status:** Not Started
- **Scope:** folders/decks tree, breadcrumb, name modal, move modal / move destination, deck workbench page, card editor modal (rich text, math via flutter_math, images), card tiles, import text modal, deck links (link deck modal, linked deck actions), debug generator (dev only). **Deferred:** sessions/cram → P22.
- **HLD docs:** STUDY.md, STUDY_DECK_LINKS_HLD.md, STUDY_IMAGES.md
- **Flows:**
  - [ ] Folder/deck CRUD, nesting, move (including into its own descendant: should be refused)
  - [ ] Card CRUD with plain text, formatting, LaTeX, images
  - [ ] (from P4) Card-face images: paste goes to the face whose field is focused (front vs back facet), file picker per face, drag-and-drop (P7's drag helper); face browsing with arrows/dots in the editor preview
  - [ ] Import text: valid, malformed, large (500 cards)
  - [ ] Deck links: link/unlink; cycles; delete a linked deck
  - [ ] Delete folder with decks → undo
- **Failure cases:** invalid LaTeX, empty card faces, 1,000-card deck scroll perf.
- **Skipped/blocked:** —

## Phase 22 — Study B: sessions, cram & session resume
- **Status:** Not Started
- **Scope:** study session page (Space flip, grade keys fail/hard/good/easy, U/R), study cram page, grading row, history controls, keyboard shortcuts, SRS scheduling results, session resume toast/checkpoints (device-local).
- **HLD docs:** STUDY.md, SESSION_RESUME_HLD.md
- **Flows:**
  - [ ] Full session with each grade; due dates in DB follow the SRS rules
  - [ ] Custom grade keys from Settings take effect; conflicts (two grades on the same key)
  - [ ] Interrupt → resume toast → resume/discard; after restart
  - [ ] Cram ←/→; linked-deck study/cram actions
- **Failure cases:** a deck edited while a session is open, 0 due cards, rapid key mashing.
- **Skipped/blocked:** —

## Phase 23 — Workout
- **Status:** Not Started
- **Scope:** plans (weekly vs cycle mode), day columns, exercise library (picker, detail view, library width), prescriptions (inherit/custom, target editor, segment fields), active workout view (sets inline edit, rest timer & length, island/overlay), history (list/log/session views), weight unit lb/kg, show workouts on calendar. **Deferred:** the calendar display → quick check only (P10 did the calendar).
- **HLD docs:** WORKOUT_TRACKER.md
- **Flows:**
  - [ ] Plan CRUD in both modes; add exercises to days; reorder
  - [ ] Start a workout; log sets; rest timer; finish; history entries match
  - [ ] Unit switch converts displays (not data?); consistent everywhere
  - [ ] Active workout survives navigation, close to tray and restart (island/overlay)
- **Failure cases:** 0/negative reps, weight 10,000, abandoning a workout mid-way, two workouts on the same day.
- **Skipped/blocked:** —

## Phase 24 — Trash, soft delete & undo
- **Status:** Not Started
- **Scope:** cross-cutting soft delete: the undo toast for every deletable kind, Settings → Trash dialog (list by kind, item detail, restore, permanent delete, empty trash), 30-day purge, restore contracts (restoring a child whose parent is deleted), erasure. **Deferred:** —
- **HLD docs:** TRASH_HLD.md, SOFT_DELETE_TOAST.md, UNDO.md
- **Flows:**
  - [ ] For each kind in `trash_kinds.dart`: delete → toast → undo; delete → Trash shows it → restore → back exactly (verify fields in SQL); permanent delete → gone locally and remotely (after the outbox drains)
  - [ ] Restore a child whose parent is also in the trash
  - [ ] Two deletes in quick succession: which toast/undo wins
  - [ ] Purge of items older than 30 days: backdate `deleted_at` in SQLite. Editing local data is allowed; only app *code* is off-limits. Run `stop.ps1` first, and remember the startup pull may bring the cloud value back. Note which value won.
- **Failure cases:** restore after a cold re-login, trash with 500 items, undo after navigating away.
- **Skipped/blocked:** —

## Phase 25 — Settings, theming & data management
- **Status:** Not Started
- **Scope:** every Settings tile not covered elsewhere: accent colour, theme dark/light, colour palette section (tag palette), petal field + geometric texture/wave settings, navigation pages dialog (order/hide), startup page dialog, week start, birth date, default trackers, weight unit/rest timer (persist only), image upload/download/background toggles, image storage dialog, automatic backups (retention, backup list dialog, save a backup as), Export Backup / Import Backup (file pickers; **only QA exports**), Start with Windows (**restore the Run value after**), About (copy build info), weather location tile, custom quotes, snippets/dictionary launchers (details in P4/P7). **Deferred:** hotkeys → P5; Vim → P3; account → P1.
- **HLD docs:** AUTO_BACKUP_HLD.md, IMPORT_EXPORT.md, DARK_THEME_AUDIT.md, WHITE_THEME.md, ON_COLOR_LABEL.md, GLASS_BUTTON.md, SCOPE_SWITCHER_HLD.md, BACKGROUND.md
- **Flows:**
  - [ ] Every toggle/choice persists across restart and (for synced settings) a cold re-login; device-local ones don't sync (PROGRESS.md list)
  - [ ] Theme switch: walk every page in light theme for contrast/legibility (DARK_THEME_AUDIT.md for expectations). This is the one full light-theme pass; the other phases only spot-check.
  - [ ] Dark background controls: Grid intensity, Glow spread, and the **Wave** / **Scatter** switches (mutually exclusive: turning one on turns the other off; both can be off for a static grid). Each keeps animating across page switches, dialogs and restore-from-tray, and the choice survives a restart. Leave it on Dark + Scatter (Wave off) at the end
  - [ ] Accent colour and palette changes propagate everywhere, including tags
  - [ ] Export → file written; wipe (new account) → Import → data identical (count rows per table with SQL); import a corrupt/foreign zip
  - [ ] Auto-backup runs/rotates per retention; backup list dialog actions
  - [ ] Media storage dialog: list, delete one, delete all
  - [ ] Nav pages dialog: hide all but one, reorder, cancel vs save
- **Failure cases:** import while offline, export to a read-only path, cancel the file dialogs.
- **Skipped/blocked:** —

## Phase 26 — Sync, offline, persistence & Dev page
- **Status:** Not Started
- **Scope:** outbox behaviour, offline (Dev → Force offline) → queued writes → reconnect drain, startup pull (cold re-login), live sync (two sessions of one account aren't possible on one PC; simulate a "remote change" by editing in a second login only if feasible, else document), sync conflict banner, CRDT text merge sanity, media upload/download toggles, sync activity indicator, the Dev page's tiles (cache status, error log, perf stall log, sync backlog, sync compare, FPS counter, verbose sync, disable cache, remote purge on the QA account only). **Deferred:** —
- **HLD docs:** SAVING.md, DATA_INTEGRITY_AUDIT_REPORT.md, JOURNAL_DATA_LOSS_POSTMORTEM.md, MEDIA.md
- **Flows:**
  - [ ] Offline: create/edit/delete across 5 kinds → outbox rows → online → drains → cold re-login shows all
  - [ ] Kill (`stop.ps1`) with a non-empty outbox → relaunch → it drains, nothing lost
  - [ ] Dev → Disable cache on/off semantics (no startup pull while on); restore it to off
  - [ ] Sync compare / backlog tiles on a clean account show consistency
  - [ ] Conflict banner (Dev "force conflict UI" if present) renders and dismisses
- **Failure cases:** toggle offline 10× quickly, a huge entry while offline, `stop.ps1` during a drain.
- **Skipped/blocked:** true multi-device live sync (only one PC). Note what could not be tested.

## Fix verification (FV) — app changes made during the audit
- **Status:** Not Started
- **Why this section exists:** phase sessions never change app code, but Juno fixed bugs while the audit was running. This section re-tests each of those changes in the running app. The phases that found them are Done and don't re-test them. Run it after Phase 26, or earlier if Juno asks. The rules above still apply: no app code changes, QA accounts only, `guard.ps1` before anything destructive.
- **Build:** some fixes may still be uncommitted in the working tree; `launch.ps1` builds whatever is on disk. Note `git log -1 --oneline` and `git status --short lib/` in the session log so it's clear what was tested.
- **Unit tests:** `flutter test` must pass before starting (3,998 tests on 2026-09-30). Each item names its own tests; a test is evidence, not a substitute for the app check.
- **Where a check reads Firestore:** use read-only REST GETs (`curl -s -G "https://firestore.googleapis.com/v1/projects/voyager-db9de/databases/%28default%29/documents/users/<uid>/<collection>?pageSize=300&mask.fieldPaths=_serverWrittenAt" -H "Authorization: Bearer $(gcloud auth print-access-token)" -H "x-goog-user-project: voyager-db9de"`), and only against the QA account's uid. Find the uid by matching a collection's document count (`.../users?showMissing=true&pageSize=50&mask.fieldPaths=x` lists them). `.claude/settings.local.json` allows exactly this and denies curl `-X`/`-d`/`--data*`, so put query parameters in the URL.
- **Test data:** use a fresh account for FV-1 and FV-2 (`session_start.ps1 -Email voyager-qa-0NN@example.com -SignUp`, next free number, recorded in PROGRESS.md §2), with at least one record on every page: 2 journals with entries in each, a dream, a to-do list with tasks, a calendar event, a tracker with values, a transaction, a budget, a savings goal, an asset, a scheduled reminder due a few minutes after the re-login, a pinned note, a hidden inbox item, a bucket-list item, a job application, a ranking category with items, a LeetCode problem, a study deck with cards, a workout session, a custom quote.

### FV-1 — BUG-044: a restore onto a wiped device re-uploaded everything it pulled
- **Change (2026-09-30, uncommitted):** a new database starts with the one-time backfill marked done (`DriftSettingsRepository.getSettings` writes the first settings row with `syncBackfillVersion` = `FirestoreCollections.syncBackfillVersion`). An upgraded database still runs it.
- **Tests:** `test/secondary_collections_sync_test.dart`, group "backfill".
- **Flows:**
  - [ ] Cold re-login of the FV account (`guard.ps1` → outbox 0 → `reset.ps1 -Force` → `launch.ps1` → `login.ps1`), wait for the startup pull. Read-only SQL: `settings_table.sync_backfill_version` = 2.
  - [ ] Firestore: `_serverWrittenAt` of calendar_events, tracker_values, transactions, tag_colors, custom_words and scheduled_reminder_rules is **older** than the re-login (none stamped during it). Before the fix, all of them were stamped within ~10 s of the restore.
  - [ ] `stop.ps1` → `launch.ps1` without editing anything: the second `[sync] pullAll took …` line lists about 0 docs ("0 pulled whole"). Before the fix it listed nearly the whole account (qa-008: 158 then 160).
  - [ ] An edit made during the re-login session (e.g. a new transaction) still uploads: it's in Firestore, and the outbox drains to 0.
- **Failure cases:** `stop.ps1` halfway through the startup pull, relaunch: the pull finishes and nothing is re-uploaded (the Firestore times stay older).
- **Not covered in the app:** the upgrade path (a database from before the backfill existed); the unit tests cover it.

### FV-2 — BUG-010, BUG-043 (and BUG-004 still open): pages empty after a cold sign-in until restart
- **Change (2026-09-30, uncommitted):** after the startup pull, `lib/main.dart` refreshes every data provider (`invalidateAllDataProvidersFrom`), not just journals, journal entries, settings and to-do lists.
- **Tests:** none for the startup path (it lives in `main.dart`); the full suite must still pass.
- **Flows (right after the FV-1 re-login, without restarting):**
  - [ ] Journal: the entry list shows the entries; the journal dropdown shows the right count for each journal and for "All journals".
  - [ ] Dreams, To-Do (lists and tasks), Calendar, Analytics/trackers, Finance (ledger, budgets, goals, assets), Life stats, LeetCode, Rankings, Jobs, Study (library and deck graph), Workout all show the pulled data.
  - [ ] Inbox: the Scheduled section lists the rules, pinned notes show, the hidden item stays under Hidden (N).
  - [ ] The reminder that falls due after the re-login fires (sticky + OS toast, `stickyShown`/`osFired` rows from the new device id) without a restart.
  - [ ] Pages are still empty *while* the pull runs and fill in when it ends. That's expected; note how long it took.
  - [ ] Known gaps, check and record: custom quotes in the quote randomizer, and older journal entries loaded by scrolling (`historicalJournalEntriesProvider`), aren't refreshed by this change.
  - [ ] BUG-004 (new account → "New entry": the journal and entry stay invisible) is **not** fixed by this change. Re-run its steps and add the result to its Notes.
  - [ ] A normal launch (not a cold sign-in): pages don't flash empty or jump when the startup pull ends (every provider is now re-read once at that point).
- **Failure cases:** navigate between pages during the pull; open an entry in the editor during the pull and type: nothing typed is lost or overwritten when the refresh lands.

### FV-3 — BUG-001: signing in after a signed-out launch left sync signed out
- **Change:** commit `9c05738` (2026-09-28). Already re-checked in Phase 1 (fix holds); repeat once as a regression check.
- **Flows:**
  - [ ] Launch signed out → sign in to a QA account from the login page → its data is pulled, and Dev → Sync backlog shows the queue (not "Signed out — nothing is queued").

### FV-4 — BUG-002: the full startup pull saturated Firestore (false offline badge, stalled pull)
- **Change:** commit `9c05738` (2026-09-28). The offline probe is an HTTPS `HEAD` instead of an SDK read, a reconnect pull waits behind the startup pull, and a weekly full pull skips journal/dream/to-do documents that are unchanged since the last one.
- **Tests:** `test/sync_full_pull_skip_test.dart`, `test/firestore_ping_test.dart`.
- **Flows:**
  - [ ] During the FV-1 cold re-login, watch the rail: no red no-wifi badge while the network is up.
  - [ ] Dev → Force offline on, then off, during a pull: the badge follows the toggle, and the pull finishes.
  - [ ] Weekly full-pull skip: only if a QA account with a few hundred journal entries/tasks exists. Age its watermarks past 7 days as in BUG-002's notes and compare the `pullAll took` line with the unchanged-document count. Otherwise note "unit tests only".
- **Not fixed (by design of that change):** a restore onto an empty device still fetched every document's operation log, so it still took minutes on a large account. The 2026-09-30 follow-up for that is FV-11.

### FV-5 — Reminder engine: repeats, snoozes and restarts
- **Change:** commit `3dceca9` (2026-09-30, after the Phase 6 runs). A sticky's appearance and its OS alert are logged once per device across restarts. A snooze that had run out is logged as replaced when a newer occurrence arrives, including after a restart. Synced states from a device ahead (another timezone, clock skew of up to a few days) don't resurrect or silence the wrong occurrence.
- **Tests:** `test/reminder_engine_test.dart`, `test/reminder_schedule_test.dart`.
- **Flows:**
  - [ ] Restart with a due, unacknowledged sticky: it comes back, with **no** second `stickyShown` row and no second OS toast. Phase 6 saw a second `stickyShown` row per restart; this change should remove it.
  - [ ] Daily rule: snooze it past the next natural occurrence (or set the rule's time so the next occurrence arrives while snoozed): the newer occurrence shows once, and History shows the older one as replaced. Restart and check it isn't logged again.
  - [ ] Acknowledge a to-do bell, then move the task's due date earlier than the acknowledged one: the bell is due again.
- **Not testable here:** a second device in another timezone (unit tests only).

### FV-6 — Sync gate: Dev → "Check, then quit (before a wipe)"
- **Change:** commits `37db0b0` (2026-09-28, the whole-account check, `lib/core/dev/full_sync_check.dart`; `qa/harness/sync_gate.ps1` reads its report) and `3dceca9` (untouched seeded job records, version 0, aren't reported as gaps; edited ones are).
- **Tests:** `test/full_sync_check_test.dart`.
- **Flows:**
  - [ ] QA account with the default job seeds untouched: the check reports safe to wipe, `sync_check.json` has `safeToWipe: true`, and `reset.ps1` (without `-Force`) passes the gate.
  - [ ] Edit one seeded job record (e.g. rename a stage), then check again before it uploads (Dev → Force offline): expected to be reported as not in the cloud, and `reset.ps1` refuses. Go back online, let the outbox drain, check again: safe.
  - [ ] Any write after a passing check (type in an entry): `reset.ps1` refuses with "the database changed after the check".

### FV-7 — Floaters put the main window back at its old depth
- **Change:** commit `99eb2d8` (2026-09-29). When a floater closes, the main window goes back under the window that was directly above it, not just under the one in front.
- **Flows:**
  - [ ] Main window behind two other windows (`other-open` twice; stack: other B, other A, Voyager). Open a floater from other B (Ctrl+Alt+T), dismiss it: the order is back to B, A, Voyager (check with `ostatus`/screenshots). Repeat with save instead of dismiss, and for each floater (T, J, F, R).
  - [ ] Nothing above the main window (Voyager was frontmost): after dismiss it stays frontmost.

### FV-8 — Time picker: Enter and Ctrl+Enter
- **Change:** commit `64c678b` (2026-09-29). Ctrl+Enter in the date-time/time selectors commits, and Enter on a cleared optional time returns the date alone.
- **Tests:** `test/reminder_time_picker_enter_test.dart`.
- **Flows:**
  - [ ] Reminder editor and a to-do due date: type a time + Enter commits it; Ctrl+Enter commits it; clear an optional time field + Enter leaves the date with no time.

### FV-9 — Security gap fixes (links and media)
- **Change:** commit `394ed2c` (2026-09-28).
- **Tests:** `test/job_clipboard_parser_test.dart`, `test/jobs_page_test.dart`, `test/media_transfer_test.dart`.
- **Flows:**
  - [ ] Jobs: paste a posting whose markdown has a non-web link (`[x](file:///C:/Windows)`, `[y](javascript:alert(1))`): only the title is kept. A job row's menu offers no Open for a URL that isn't http(s) with a host.
  - [ ] Media: an image used by two entries, delete one entry (and "delete everywhere" from Trash): the image still shows in the other entry.

### FV-10 — Backup restore audit fixes
- **Change:** commit `259c414` (2026-09-28). Overlaps Phase 25's backup checks; tick here what Phase 25 doesn't cover.
- **Tests:** `test/auto_backup_service_test.dart`, `test/backup_list_dialog_test.dart`, `test/import_export_test.dart`, `test/restore_field_stamps_test.dart`, `test/restore_open_editor_test.dart`.
- **Flows:**
  - [ ] Restore a backup with a journal entry open in the editor: the open page doesn't save its old text over the restored entry.
  - [ ] Undo a restore: records it brought back that didn't exist before are deleted again; a record deleted forever since the backup stays deleted.

### FV-11 — BUG-002 (restore half): a first pull reads every operation log at once
- **Change (2026-09-30, uncommitted):** when `pullAll` pulls journal entries, dream entries or to-do tasks for the first time on this device (no watermark), it reads the whole `sync_operations` collection in pages of 1,000, instead of one query per document. The three collections share that read. Operations written after it are picked up by one follow-up query and fetched one by one. If the read fails, the pull falls back to one query per document. Later pulls are unchanged. Only a first pull listing at least 200 documents starts the read (others then share it); pages are sized to ~16 MB.
- **Tests:** `test/sync_first_pull_operation_logs_test.dart`.
- **Flows:**
  - [ ] During the FV-1 cold re-login (under 200 documents per collection, so it takes the one-query-per-document path; that's expected), the log has no `[sync] reading every operation log failed` line, and the journal entry text, dream text and to-do titles match what was written before the wipe (spot-check 3 of each, including one edited several times).
  - [x] Speed: measured 2026-09-30 on Juno's account (profile build, cold restore): 27.5 s with the change against 62.1 s without it, with identical journal, dream and to-do rows. See BUG-002's notes. It was measured before the review fixes (one extra single-document query ahead of the read, the 200-document threshold, ~16 MB pages); those shouldn't change a restore of that account, but it hasn't been re-measured.
  - [ ] After that restore, `stop.ps1` → `launch.ps1`: the second pull is incremental and reads no whole log (no long pause on journal_entries/todo_tasks).
- **Failure cases:**
  - Edit a journal entry from a second session of the same account (the harness VM via `vm.ps1`, if it's set up) while the re-login's pull is running: the edit shows up after the pull or on the next one, and isn't lost.
  - Force offline partway through the pull: it falls back or retries, and completes once back online, with no text missing.

- **Five-dimension sweep:** D2 is the heart of FV-1/FV-2 (SQL + Firestore + restart). D3: the pages in FV-2 at maximized only. D4/D5: as listed per item; otherwise n/a (covered by each feature's phase).
- **Skipped/blocked:** —

## Phase 27 — Final Review
- **Status:** Not Started
- **Scope:** no new testing except re-checks.
- **Checklist:**
  - [ ] Re-check every Blocker/Major bug in BUGS.md for exact duplicates (same root behaviour logged twice); mark duplicates in Notes ("Duplicate of BUG-###"). BUGS.md is append-only, so don't delete entries.
  - [ ] Confirm every phase 1–26 and FV is Done or has documented skips in its "Skipped/blocked"
  - [ ] Write the summary at the top of BUGS.md: counts by severity, counts by phase (a severity × phase table), and a list of all Blockers
  - [ ] Final PROGRESS.md update; final SESSION END
- **Skipped/blocked:** —
