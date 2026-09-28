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
| 1 | First run, auth & account lifecycle | Not Started |
| 2 | Shell, navigation, window & tray | Not Started |
| 3 | Vim modal keybinding system | Not Started |
| 4 | Text-editing helpers (autocorrect, dictionary, snippets, formatting, images) | Not Started |
| 5 | Global hotkeys & floaters | Not Started |
| 6 | Notifications, inbox & reminders | Not Started |
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
| 27 | Final Review | Not Started |

Keep this table and each phase's **Status** line in sync.

---

## Phase 0 — Setup
- **Status:** Done (2026-09-27)
- Environment, harness, baseline reset and interaction method verified; see PROGRESS.md.

---

## Phase 1 — First run, auth & account lifecycle
- **Status:** Not Started
- **Scope:** login page, sign-up/sign-in, error states, what a brand-new account sees on every page (first-run empty states), startup-page redirect after login, sign-out from Settings → Account, change password on a QA account. **Deferred:** rail/nav mechanics → P2; Settings page in general → P25; per-page empty-state *details* → each page's phase (here only check that nothing crashes and there's a sensible first-run prompt).
- **HLD docs:** PLAN.md, PRODUCT.md, SESSION_RESUME_HLD.md (startup), GAPS.md
- **Flows:**
  - [ ] Login page layout; Sign in ↔ Create account toggle (card re-centres, fields keep or clear their text?)
  - [ ] Sign up a new account (happy path) → lands on the startup page
  - [ ] Sign-up errors: empty e-mail/password ("Email and password are required."), invalid e-mail format, weak password (<6 chars), e-mail already in use (reuse qa-001)
  - [ ] Sign-in errors: wrong password, unknown e-mail, whitespace around the e-mail (it is trimmed)
  - [ ] Enter in either field submits; the loading state disables the buttons; double Enter doesn't double-submit
  - [ ] "Forgot password?" with an **empty** e-mail shows "Enter your email…" (with an e-mail filled in it's **MANUAL-ONLY**)
  - [ ] Google button hidden on Windows unless OAuth configured (don't click it)
  - [ ] **Lead from setup:** new account, Journal page, type into the body → does an entry/journal get created and persisted? Survives restart? (PROGRESS.md §7)
  - [ ] First visit to every rail page on an empty account: no crash, no FlutterError, a sensible empty state or first-run prompt ("Create your first list", etc.)
  - [ ] Settings → Account shows the right e-mail; Sign out → login page; sign back in → data still there (pulled back)
  - [ ] Change password (QA account only): wrong current password error, too-short new password, success (then sign out/in with the new one; **record it in PROGRESS.md**)
  - [ ] Startup page after login honours Settings → Startup page (first/last seen/custom) (the settings detail is in P25)
  - [ ] Relaunch while signed in skips the login page; relaunch after sign-out shows it
  - [ ] Record the first-run defaults (expected: Dark, Scatter on, Wave off, Juno's background values; see the standard configuration) and confirm they match
- **Test data:** 1–2 fresh QA accounts.
- **Skipped/blocked:** —

## Phase 2 — Shell, navigation, window & tray
- **Status:** Not Started
- **Scope:** nav rail (order, hidden pages, selection), Ctrl+Tab/Ctrl+Shift+Tab, clock + weather button → forecast sheet, connectivity/sync activity indicators, shortcuts dialog (Ctrl+/), window min size/resize/maximize/restore, close-to-tray, tray menu (Open/Quit), page state kept across switches, the shell back interceptor. **Deferred:** global hotkeys/floaters → P5; inbox bell → P6; nav order/hidden/startup-page *settings dialogs* → P25 (use them here only to see the rail react).
- **HLD docs:** GLOBAL_HOTKEY_FLOATERS_HLD.md §window/tray, AUDIT_TESTING.md, BACKGROUND.md, DESIGN.md
- **Flows:**
  - [ ] Every rail item navigates; selected state correct; hover/press visuals
  - [ ] Ctrl+Tab / Ctrl+Shift+Tab cycle in *rail order* (including after reordering and hiding pages), wrap around, skip hidden pages
  - [ ] Ctrl+Tab while a text field / dialog has focus (should it act?)
  - [ ] Page state kept when switching away and back (scroll position, open panel, typed draft)
  - [ ] Rail at min window height: can all pages be reached? (setup lead) Rail with every page visible vs several hidden
  - [ ] Clock updates across a minute boundary; weather button opens the forecast sheet; weather not configured → sensible state (setting a location is **low-volume only**)
  - [ ] Offline badge appears with Dev → Force offline, clears when turned off
  - [ ] Ctrl+/ shortcuts dialog: content matches the actual bindings (custom calendar/grading keys reflected), scrolls, closes with Esc/Close, reopens
  - [ ] Window: resize to min (clamped at 1440×1040 phys), odd sizes, maximize/restore, minimize/restore; layout reflows without overflow
  - [ ] Close (X / WM_CLOSE) hides to tray; process stays; hotkeys still registered; tray "Open Voyager" restores placement; tray Quit exits cleanly (outbox drained? check)
  - [ ] Second launch while one is running (single-instance behaviour?)
  - [ ] Rapid rail clicking (20× across pages) → no errors, ends on the last clicked page
- **Test data:** a little data on several pages so page state is observable.
- **Skipped/blocked:** —

## Phase 3 — Vim modal keybinding system
- **Status:** Not Started
- **Scope:** the Vim-lite engine in text fields (`lib/core/vim/`) across field types: single-line, multi-line journal body, dialogs, floater fields. Mode badge/caret, every command in VIM.md, conflicts with app shortcuts, Esc semantics. **Deferred:** floater-specific focus → P5; page-specific keys (calendar h/l, SRS keys) are checked per page under D4.
- **HLD docs:** VIM.md, CAPS_LOCK.md (overlay/caret), CTRL_ENTER_SUBMIT_HLD.md, TEXTBOX_WIDGET.md
- **Flows (Settings → Vim keybindings ON; type with `voy.ps1 type`/`key`, real VK presses):**
  - [ ] Esc Insert→Normal; mode indicator shown/positioned correctly; `i I a A o O` enter Insert at the right spot
  - [ ] Motions `h j k l w b e 0 $ gg G`; counts, if supported
  - [ ] `f F t T` plus `;` `,` repeat; `.` repeats the last change
  - [ ] Operators `d c y` with motions, doubled (`dd cc yy`), and in Visual `v`/`V`; `x`, `p`, Ctrl+V in Normal; `u` undo, Ctrl+R redo
  - [ ] `/` search bar, `n`/`N`, Esc cancels search
  - [ ] Pending state cleared by Esc (`d` then Esc then `l` moves, doesn't delete)
  - [ ] Single-line fields: `j/k/o/O` behaviour sensible; Enter in Normal mode submits or not?
  - [ ] Esc in a dialog's text field: first Esc → Normal, second Esc → closes the dialog? Consistent across dialogs
  - [ ] App shortcuts vs Normal mode: Ctrl+Tab, Ctrl+/, Ctrl+Enter, Ctrl+F while in Normal/Insert; page letter-shortcuts (calendar `h/l`, study Space) must not fire while typing
  - [ ] Clipboard: `y` then paste elsewhere with Ctrl+V; `p` pastes system clipboard
  - [ ] Vim OFF: all keys type normally, Esc behaves as plain Esc, no mode badge
  - [ ] Toggling Vim while a field is focused; state after navigating away and back
  - [ ] Caps Lock on in Normal mode (uppercase commands `A`/`G` vs lowercase)
- **Failure cases:** long lines (500+ chars), multi-line with empty lines, emoji (surrogate pairs) under `x`/`h`/`l`, rapid key bursts.
- **Test data:** a journal entry with multi-paragraph text; a todo title; a dialog field (e.g. new list name).
- **Skipped/blocked:** —

## Phase 4 — Text-editing helpers
- **Status:** Not Started
- **Scope:** autocorrect, spell check + suggestions, custom dictionary and flagged words (Settings → Dictionary), text snippets (Tab/Space expansion; Settings → Text snippets), Caps Lock indicator, emphasis formatting (bold/italic markers), list indent/outdent (Tab/Shift+Tab), right-click snippet menu, Ctrl+Enter submit, image paste (Ctrl+V) + lightbox (←/→/Esc), multiline scroll insets. **Deferred:** Vim → P3.
- **HLD docs:** AUTOCORRECT.md, DICTIONARY.md, FLAGGED_WORDS.md, SNIPPET.md, RIGHT_CLICK_SNIPPET.md, CAPS_LOCK.md, EMPHASIS_FORMATTING.md, MULTILINE_FIELD_SCROLL_INSETS.md, MEDIA.md, CTRL_ENTER_SUBMIT_HLD.md
- **Flows:**
  - [ ] Autocorrect common typos on space/punctuation; undo an autocorrect; toggle off in Settings
  - [ ] Misspelling underline, right-click suggestions, add to dictionary, flag a word; dictionary dialog search/remove
  - [ ] Snippet create/edit/delete; expand with the configured key (Tab vs Space); snippet vs list-indent Tab conflict; expansion inside words
  - [ ] Caps Lock indicator appears/disappears (caret chip), in single- and multi-line fields
  - [ ] Emphasis formatting renders and round-trips after restart
  - [ ] Bullet/numbered list indent/outdent
  - [ ] Ctrl+Enter saves the open form on each form type (list which forms it works on)
  - [ ] Paste image (Set-Clipboard -Path an image in qa/) into journal/dream/study; thumbnail; lightbox navigation; delete image; media storage dialog shows it
- **Failure cases:** a huge pasted image, a non-image clipboard, paste 10 images fast, snippet with an empty body, a 1,000-char snippet.
- **Test data:** snippets `;sig`, `addr`; custom words; a test PNG/JPG in `qa/data/`.
- **Skipped/blocked:** —

## Phase 5 — Global hotkeys & floaters
- **Status:** Not Started
- **Scope:** Ctrl+Alt+J/T/F/R (journal notepad, quick to-do, quick transaction, quick reminder) from (a) main focused (in-app path), (b) another app focused (floater window), (c) main hidden in tray, (d) main minimized; floater save/close/draft retention, replacement between floaters, Esc behaviour, click-outside dismiss, Open app; rebinding in Settings (key binding dialog), conflicts/duplicates. **Deferred:** the resulting data's page behaviour → P7/P9/P13/P6.
- **HLD docs:** GLOBAL_HOTKEY_FLOATERS_HLD.md, AUDIT_TESTING.md (what was already covered and the open findings 1–12; re-verify those rather than rediscover them), AUDIT.md (empty now)
- **Flows:**
  - [ ] Each hotkey from each of states (a)–(d); floater size/position/topmost; field autofocus
  - [ ] Save from each floater → row in DB, confirmation, draft cleared; the main app shows it
  - [ ] Close/dismiss keeps the draft; reopen restores it
  - [ ] Hotkey A while floater B is open (replacement); same hotkey twice (no-op)
  - [ ] Quick reminder floater (new since AUDIT_TESTING): create reminder, time parsing, validation
  - [ ] Rebind a hotkey (Settings); a conflicting/duplicate binding; one already owned by another app; the old binding released
  - [ ] Vim in floater fields; Esc never closes a floater (as designed?)
  - [ ] Re-verify AUDIT_TESTING.md findings 1, 3, 4, 5, 7, 10, 11, 12 (still present? log each still-present one as a bug referencing the finding)
  - [ ] "Another app focused" needs a probe-owned WinForms window (pattern: AUDIT_TESTING.md Session 2). Build it under `qa/harness/` if needed.
- **Failure cases:** hotkey spam (10× quickly), hotkey during app startup, floater open while the app quits from tray.
- **Skipped/blocked:** multi-monitor (out of scope).

## Phase 6 — Notifications, inbox & reminders
- **Status:** Not Started
- **Scope:** notification bell + inbox popover (sections, hide/restore, dismiss), reminder bell buttons on todos/events (entity reminders), reminder sticky stack, scheduled reminder rules (Settings), OS toast notifications (flutter_local_notifications), Settings → Devices, unified notifications. **Deferred:** creating the todos/events themselves → P9/P10.
- **HLD docs:** INBOX_POPOVER_HLD.md, INBOX_HIDDEN_RESTORE_HLD.md, SCHEDULED_REMINDERS_HLD.md, UNIFIED_NOTIFICATIONS.md
- **Flows:**
  - [ ] Inbox empty state; items appear from each source; badge count correct
  - [ ] Hide an item → hidden section → restore; dismiss; persistence across restart and across a cold re-login (dismissed notifications sync)
  - [ ] Scheduled reminder rule CRUD; fires at the time (set 2–3 min ahead) → OS toast + in-app; snooze/complete if offered
  - [ ] Entity reminder on a todo and an event; changing the due time updates it; deleting the entity removes the reminder
  - [ ] Reminder fires while the app is hidden to tray; while minimized
  - [ ] Devices section lists this device; last-seen updates
- **Failure cases:** reminder in the past, many (20+) simultaneous reminders, midnight/DST boundaries (reason about them if not reproducible), offline when a reminder fires.
- **Skipped/blocked:** —

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

## Phase 27 — Final Review
- **Status:** Not Started
- **Scope:** no new testing except re-checks.
- **Checklist:**
  - [ ] Re-check every Blocker/Major bug in BUGS.md for exact duplicates (same root behaviour logged twice); mark duplicates in Notes ("Duplicate of BUG-###"). BUGS.md is append-only, so don't delete entries.
  - [ ] Confirm every phase 1–26 is Done or has documented skips in its "Skipped/blocked"
  - [ ] Write the summary at the top of BUGS.md: counts by severity, counts by phase (a severity × phase table), and a list of all Blockers
  - [ ] Final PROGRESS.md update; final SESSION END
- **Skipped/blocked:** —
