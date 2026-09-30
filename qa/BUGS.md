# Voyager QA Audit — Bugs

<!-- SUMMARY: written by the Final Review phase (counts by severity and by phase). -->

Append-only findings log. Observations only: no proposed fixes, no code.
Number IDs sequentially; check the last ID before adding one. To mark a
duplicate or a status change, add a line to the entry's Notes; never delete entries.

Entry format:

```
### BUG-### [Phase X] Short title
- Severity: Blocker / Major / Minor / Cosmetic
- Found: <date>, Phase <N>
- Steps to reproduce: (start from the baseline state)
- Expected:
- Actual:
- Notes: (screenshots, logs, suspected scope)
```

---

### BUG-001 [Phase 1] Signing in after a signed-out launch leaves sync signed out until restart
- Severity: Blocker
- Found: 2026-09-27, Phase 1 (seen by Juno between sessions, on the real account)
- Steps to reproduce: from the baseline state (signed out, local data wiped), launch Voyager, sign in with e-mail and password on the login page, and leave the app running.
- Expected: the startup pull downloads the account's cloud copy, and Dev page → Sync backlog shows the queue.
- Actual: the app stays empty. Settings → Account shows the right e-mail ("Signed in with email and password"), while Dev page → Sync backlog says "Signed out — nothing is queued." The pull "succeeds" with nothing: the device registration row (written only after the startup pull completes) appeared at 23:01:03, `voyager_errors.log` logged nothing, and the only calendar was the locally created `__legacy_calendar__`. Restarting without signing out brought the data back (46 journals, 122 calendar events, 23 to-do lists, 164 study cards, …).
- Notes: cause: `syncRepositoryProvider` (`lib/app/providers.dart`) watched only `authRepositoryProvider`, which is one object for the app's lifetime. If the provider was built while signed out, it kept `NoOpSyncRepository` after sign-in. The root widget builds it at launch through `connectivityStatusProvider`. Scope: every harness session that signs in with `login.ps1` has run in this state, so any QA account's recorded cloud contents (e.g. qa-001 "Empty") are suspect, and writes made in such a session may never have reached the cloud (not verified). Fixed in the working tree on 2026-09-27; regression test `test/sync_repository_auth_switch_test.dart`.
- Notes (2026-09-27, consequence): **synced settings were reset to defaults.** During the stuck session, the local settings row (all defaults) was saved at 2026-09-28T03:10:05Z (23:10 local). Settings merge last-write-wins on the whole document (`mergeSettingsFromRemote`), so that newer clock beat the real settings (last changed 2026-09-27T01:38:30Z per the 00:57 auto-backup), and the next pull kept the defaults. The following launch (23:08, signed in from the start, so a real repository) probably uploaded the defaults over the cloud copy (not verified; Firestore wasn't read directly). Lost: theme/background (triangle texture and wave tuning), accent color, LeetCode username, and every other synced setting. The pre-wipe auto-backups in `C:\Users\Juno\VoyagerQA-localonly-backup-2026-09-27\backups\` still hold the real values.
- Notes (2026-09-29, Phase 1 re-check): the fix holds. Launched signed out, signed into voyager-qa-002 from the login page onto an empty local DB: its journal entry was pulled within ~12 s, and later writes drained from the outbox. The same passed for qa-003.

### BUG-002 [Phase 1] Full startup pull saturates Firestore: false "offline" badge and a pull that stalls
- Severity: Major
- Found: 2026-09-27, Phase 1 (seen by Juno between sessions, on the real account, restoring from the cloud after the QA wipe)
- Steps to reproduce: wipe local data (`reset.ps1`), launch, and sign in to an account with a large cloud copy (here: 312 journal entries, 494 to-do tasks, 15,421 `sync_operations` docs). Watch the nav rail and `journal_entries_table` during the first startup pull.
- Expected: the pull completes in reasonable time, and the rail shows offline only when the network is actually down.
- Actual: the red no-wifi badge came on and stayed on although the network was fine. Windows logged no Wi-Fi disconnect, the PC reached `firestore.googleapis.com` instantly, and the app kept its one connection to Google up the whole time. The pull stalled: `journal_entries_table` sat at 233 of 312 for minutes, and no `[sync] pullAll took` line was ever printed. The "Journal" journal showed 6 of its 14 entries. Probed through the VM service at ~23:33: a `Source.cache` read answered in 4 ms, but a `Source.server` read of `meta/ping` got no answer for 99 s. Count queries (which bypass the local cache) answered in ~4.5 s. One native thread in the app was at 100% CPU (3.9 s of every 4 s), the process was at ~4.5 cores and 1.2 GB, and the Dart isolates were nearly idle. After `disableNetwork()`/`enableNetwork()` (enable took 23.7 s), the server read succeeded 37 s later, journal entries completed to 312 within a few minutes, and to-do tasks advanced about 1 per second. The single hot thread stayed at 100% throughout, and the badge was still red at 23:41.
- Notes: the connectivity probe (`ConnectivityStatusController`, 8 s timeout, `SyncRepository.ping` = one `Source.server` doc read) can't tell "Firestore is busy" from "offline". It shares the Firestore client with the pull, so the badge follows the pull's load, not the network. No sync read in `remote_sync_service.dart` / `firestore_sync_repository.dart` has a timeout, so a stuck read stalls the pull silently (nothing reaches `voyager_errors.log`). The pull requests every document's operation log up front (`_fetchOperationLogs`, 16 at a time, one `sync_operations where documentId ==` query each). With 15k operation docs, this is the prime suspect for the pegged native thread, but it isn't proven (no native profile taken). It's also unproven whether the pre-toggle stall was a stuck stream or starvation. The pull did resume right after the network toggle. Related: BUG-001 (the same recovery session).
- Notes (2026-09-28, measured): **not a debug-build artifact.** With the local data complete and Firestore's disk cache warm, every watermark was aged 8 days (with Juno's permission) and the app was launched as a **profile** build: `[sync] pullAll took 398838ms: 2880 docs from 58 collections, 58 pulled whole. Slowest: todo_tasks 396782ms (494, full), journal_entries 393455ms (312, full), study_cards 4975ms (164, full)`. The other 56 collections took under 5 s each. The two slow collections are exactly the ones that fetch a per-document operation log (806 `sync_operations where documentId ==` queries), at about 0.5 s per query through the single Firestore worker. Debug probes the night before (VM service, warm cache): a query already run earlier answered in 98 ms, a new one returning 0 docs took 1.5–1.8 s, `whereIn` over 30 ids (657 docs) took 38.5 s, and `orderBy`+`limit(1000)` pages took 60 s and 22 s. Batching or paging doesn't help. The `lib/core/sync/remote_sync_service.dart` comment on `_fetchOperationLogs` records 456 todo tasks taking 81 s before concurrency was added. Amplifier: when the badge flips offline→online, `_resumeSyncAfterReconnect` (`lib/main.dart`) starts another `pullAll`, which can overlap a pull already running.
- Notes (2026-09-28, fixed in the working tree, uncommitted):
  - The offline probe (`FirestoreSyncRepository.ping`) is now an HTTPS `HEAD` to `firestore.googleapis.com` instead of an SDK read.
  - A reconnect pull waits behind the startup pull (`lib/main.dart`).
  - A weekly full pull skips journal entries, dream entries and to-do tasks that this device holds at the listed revision (version, `updatedAt`, `deletedAt`) and whose operation log has no operation since the last full pull minus one day (a single `sync_operations where timestamp >=` query). If that query fails, nothing is skipped. Documents open in an editor are never skipped.
  - Tests: `test/sync_full_pull_skip_test.dart`, `test/firestore_ping_test.dart`. The skip test fails without the fix.
  - Re-measured the same way (profile build, watermarks aged 8 days): `pullAll took 13103ms: 2880 docs from 58 collections, 58 pulled whole`, down from 398838 ms. Journal entries were 131 rows (75 deleted) before and after, the outbox was empty and no errors were logged.
  - Not fixed: a first pull onto an empty device still resolves every log, so a restore still takes minutes.
  - Not observed directly: the badge's colour during the pull.
- Notes (2026-09-30, the restore half, fixed in the working tree, uncommitted):
  - A collection's first pull inside `pullAll` (no watermark yet, so an empty or wiped device) no longer runs one `sync_operations where documentId ==` query per document. It reads every operation log in `orderBy(__name__)` pages of 1,000 (`FirestoreSyncRepository.listAllOperations`), shared by journal entries, dream entries and to-do tasks, and groups the operations by document (`RemoteSyncService._operationLogsFor`).
  - That read can't hold an operation written after it answered. After each collection is listed, one `listOperationDocumentIdsSince(newest operation's _serverWrittenAt)` query names those logs, and they're fetched one by one as before. It relies on the operation log being written before the document (see SAVING.md, "Verified as correct").
  - If either read fails or comes from the cache, the collection falls back to one query per document. Every later pull (incremental, weekly full, live) still queries per document.
  - Real account size, read-only REST count on 2026-09-30: 15,786 `sync_operations` docs across ~1,000 document ids. Payload median ~4 KB, largest ~900 KB.
  - Tests: `test/sync_first_pull_operation_logs_test.dart`. It checks one read shared across collections, the same result as one query per document, an operation landing after the read still resolved, and later pulls going back to per-document. The late-operation test fails with the follow-up query removed.
  - **Speed-up not measured in the app.** It removes ~800 queries' fixed cost (a new query that returns nothing took 1.5–1.8 s in the debug probes above). The per-document cost stays: 1,000-doc pages took 22–60 s in those probes, about 22–60 ms per operation. Expect a restore several times faster, not seconds. If a measured restore isn't faster, revert this part. See TEST_PLAN FV-11.
- Notes (2026-09-30, measured on Juno's account with Juno's permission): two cold restores, profile build, local data and Firestore cache wiped before each. Juno ran "Check, then quit" first, and the original local data was backed up and restored afterwards.
  - With the change: `pullAll took 27459ms: 3085 docs … Slowest: todo_tasks 24730ms (503, full), journal_entries 24549ms (317, full), dream_entries 24058ms (11, full)`. No `reading every operation log failed` line.
  - Without it (fix 3 switched off by an early return; the BUG-010/043/044 fixes still in): `pullAll took 62096ms: 3086 docs … Slowest: todo_tasks 59357ms (503, full), journal_entries 46664ms (317, full)`.
  - About 2.3× faster. Journal entries (135 rows), dream entries (5) and to-do tasks (474) came out identical in both runs: same id, title/body, version, deletedAt, completedAt and journalId hash.
  - The 3,086 vs 3,085 docs is one extra document somewhere outside those three collections, presumably written by run A's device. Not investigated.
  - The ~24 s the three collections share is the one read of every log. Everything else finished within ~8 s.
- Notes (2026-09-30, after a code review of the change):
  - The cutoff for the follow-up query was the newest `_serverWrittenAt` among the operations the pages returned. That's unsafe across pages. The pages are read one after another, so an operation written mid-read into a page already passed is missed. A later one in a page still to come lifts the cutoff past it, and the document is applied without it until the next weekly full pull.
  - Fixed: `listAllOperations` now reads the newest operation's write time **before** the first page (`orderBy(_serverWrittenAt, descending).limit(1)`), and the follow-up query starts from that. The in-memory test double reads in one step, so no unit test can reproduce the page race; the "lands after the read" test covers the follow-up.
  - Also from the review: a failed read is now logged once, not once per collection sharing it.
  - The 27.5 s measurement predates this one extra single-document query. Not re-measured.
  - Review points left open:
    - A first pull of one collection (a lost watermark, or a new CRDT collection) still reads every log in the account.
    - The read's result stays in memory until `pullAll` ends.
    - Pages of 1,000 operations have no byte limit.
- Notes (2026-09-30, those three review points fixed):
  - The read of every log is started only by a first pull that lists at least `RemoteSyncService.allOperationsMinDocuments` (200) documents. Once started, any other first-pull collection shares it however few it lists. The threshold comes from the measurement above: ~24 s for the read against ~0.1 s per document one at a time, so the read pays off from about 240 documents. A restore still uses it (317 journal entries, 503 tasks).
  - Each collection takes its logs out of the read's result as it uses them. The rest is dropped when `pullAll` ends, so a timer in its zone can't keep it alive.
  - Pages are sized to ~16 MB of payload (`FirestoreSyncRepository.nextOperationPageSize`). The first page asks for 250; later ones fit what the pages so far averaged, between 50 and 1,000. On the measured account (~12 KB average) that's still 1,000 a page.
  - Tests: `test/sync_first_pull_operation_logs_test.dart` now seeds 200 tasks, and adds tests for a small first pull (no whole read), logs taken out of the result, and page sizing.
  - Not re-measured in the app.

### BUG-003 [Phase 1] Brand-new account: the Journal editor accepts text that is never saved
- Severity: Blocker
- Found: 2026-09-29, Phase 1 (also seen at setup, 2026-09-27)
- Steps to reproduce: sign up a new account (`session_start.ps1 -Email voyager-qa-002@example.com -SignUp`). It lands on Journal, which shows a full editor (Title, Mood, date, "Start writing…", trash can) with an empty entry list and no journal name in the header. Click the body, type "qa probe body text", click Title, type "qa probe title". Wait 8 s, then `stop.ps1` → `launch.ps1`.
- Expected: typing creates an entry (and its default "Journal") and autosaves it, or the page shows an empty state / first-run prompt instead of an editable editor.
- Actual: the text stays on screen and nothing reaches SQLite: `journals_table` and `journal_entries_table` both have 0 rows after 8 s, and the outbox is empty. No error in the run log or `voyager_errors.log`. After the restart the editor is blank again, so the text is silently lost. Clicking "New entry" first works (the entry and the `__legacy__` "Journal" are written straight away).
- Notes: screenshots `qa/shots/p1-journal-typed.png`, `p1-journal-after-restart.png`. In `journal_page.dart`, entries (and the default journal via `_ensureDefaultJournal`) are only created by `_createEntry`, i.e. "New entry"; the editor shown with no entry has nothing to save into. A new user's first action is likely to be typing into that editor. Not yet checked: the same state after deleting the last entry of an existing account (Phase 7).

### BUG-004 [Phase 1] First entry on a new account: its journal and entry stay invisible until restart
- Severity: Major
- Found: 2026-09-29, Phase 1
- Steps to reproduce: new account (0 journals) → Journal page → click "New entry" → type a title and body. Wait, switch to To-Do and back, then open the journal dropdown in the header.
- Expected: the default "Journal" appears in the header and the new entry appears in the entry list.
- Actual: the entry and the `__legacy__` "Journal" row are in SQLite (and the editor shows the entry), but the list on the left stays empty and the header shows only a chevron. The dropdown lists only "All journals 0". It stays this way after switching pages. After `stop.ps1` → `launch.ps1` the header shows "Journal 1" and the entry is listed.
- Notes: screenshots `qa/shots/p1-new-entry-2.png`, `p1-list-after-nav.png`, `p1-journal-dropdown.png`, `p1-list-after-restart.png`. No FlutterError logged. It looks like the journal list or entry list doesn't react to the default journal created during the first "New entry" (suspected, not verified). A new user can't see or navigate to their first entry after leaving it.
- Notes (2026-09-30): likely the same underlying cause as BUG-010 (kept-alive providers that read SQLite once and aren't re-read), triggered here by the page's own first write rather than the startup pull. Not verified for this path. See BUG-010's notes.
- Notes (2026-09-30): **not** fixed by the BUG-010 change, which refreshes the providers only after the startup pull. Expected to still reproduce; re-check in TEST_PLAN.md "Fix verification" FV-2.

### BUG-005 [Phase 1] Signing into a different account keeps the previous account's local data, and an edit uploads it (corrupted) into the new account
- Severity: Blocker
- Found: 2026-09-29, Phase 1
- Steps to reproduce: sign in to account A (voyager-qa-002, which has one journal entry "new entry title" / "new entry body") so its data is pulled. Settings → Account → Sign out. On the login page, sign up or sign in as account B (voyager-qa-003, a new account). Journal shows A's journal and entry. Click the entry body and type " EDITED-BY-003"; wait for the outbox to drain. Then wipe local data and sign into B again on the empty device (cold pull).
- Expected: signing out, or signing in as a different account, doesn't show A's data to B, and B's cloud copy never receives A's rows.
- Actual:
  - Sign-out leaves all of A's rows in the local DB. B (even a brand-new account) sees A's journal and entry in the UI straight after signing in.
  - Merely signing in as B uploads nothing: a cold pull of B without edits came back empty.
  - Once B edits A's entry, the entry goes to B's cloud copy. After the cold pull, B has the entry (same id `bf4bf6fd…`, title "new entry title") but its body is only " EDITED-BY-003": A's original text is missing. Its journal (`__legacy__`) wasn't uploaded, so the entry is an orphan that the Journal page doesn't show.
- Notes: this is a privacy leak between accounts on a shared PC, plus data corruption in the target account (the operation log seems to hold only B's edit, not A's base text; suspected, not verified). No account-switch handling was found in `lib/` (no grep hits for a previous-uid check or local wipe on sign-out). This is also why the QA harness wipes local data at every session end (PROGRESS.md §1), and it matches the risk named there for Juno's real account. Screenshots `qa/shots/p1-qa003-after.png` (B sees A's entry), `p1-qa003-cold.png` (after the cold pull). qa-003's cloud copy now holds this orphan entry.

### BUG-006 [Phase 1] Login page is only partly keyboard-operable: no initial focus, invisible button focus, buttons ignore Enter/Space
- Severity: Minor
- Found: 2026-09-29, Phase 1
- Steps to reproduce: signed out, relaunch → login page. Without touching the mouse: (1) type an e-mail; (2) press Tab, type a password, press Enter; (3) after the error, press Tab repeatedly, watching the focus; (4) with the e-mail field empty, Tab past Password and press Enter, then Space.
- Expected: the Email field has focus on arrival; Tab walks Email → Password → Forgot password? → Sign in → Create account with a visible focus ring; Enter/Space activate the focused button; a failed submit leaves focus in a field.
- Actual: (1) nothing has focus, so the typed e-mail is lost. (2) The first Tab focuses **Email**, so the password lands in the e-mail field in plain text ("qavoyager2026" visible), and Enter shows "Email and password are required." (3) After a failed submit no field has focus. Tab goes Email → Password, then three stops with no visible focus indicator. (4) Enter and Space on the stop after Password do nothing (no "Enter your email to reset…" message; that stop is probably "Forgot password?", which looks faintly highlighted). "Create account" can't be reached or activated without the mouse.
- Notes: `lib/features/auth/login_page.dart` has no `autofocus` and no focus nodes; only the two fields' `onSubmitted`. Signing in by keyboard works once the e-mail field is clicked (Enter in either field submits). Screenshots `qa/shots/p1-kb-sheet.png`, `p1-tab-sheet.png`, `p1-tab-enter.png`, `p1-tab-space.png`. The same button focus/activation behaviour probably applies to the app's other glass buttons; check it in P2/P25.
- Notes (2026-09-29, Phase 2): the app-wide case is logged as BUG-009.

### BUG-007 [Phase 2] Rail clock changes minute up to 30 s late
- Severity: Cosmetic
- Found: 2026-09-29, Phase 2
- Steps to reproduce: any signed-in page. Watch the clock at the top of the nav rail across a minute boundary (here: screenshots every ~4.3 s from 16:23:27 to 16:24:31 by the PC clock).
- Expected: the clock shows the new minute within a second or two of the system clock.
- Actual: it still showed "4:23 PM" at 16:24:18 and first showed "4:24 PM" at 16:24:22, about 22 s late. Earlier in the session the rail showed "4:22 PM" in the same screenshot as a journal entry stamped "4:23 PM" (`qa/shots/p2-state-journal-back.png`).
- Notes: crops in `qa/shots/p2-clock-0..15.png`. `_ClockTextState` (`lib/features/shell/app_shell.dart`) refreshes on a `Timer.periodic(30 s)` started at mount, not aligned to the minute, so the lag is anywhere from 0 to 30 s depending on when the shell was built.

### BUG-008 [Phase 2] No weather location: the rail shows a sunny-weather icon, and the forecast sheet is an empty panel with no way to Settings
- Severity: Cosmetic
- Found: 2026-09-29, Phase 2
- Steps to reproduce: brand-new account (no weather location set). Look at the weather button under the rail clock, then click it.
- Expected: an icon or label that reads as "weather not set up" (not a forecast), and a prompt that leads to Settings → Pages → Weather location.
- Actual: the rail shows a yellow sun with no temperature, which reads as "it is sunny". The Settings tile shows the same sun beside the empty "City" field. Clicking the button opens the full-size forecast sheet (~1,360×1,240 physical px) holding only "Set a weather location in Settings first.", with no link to Settings and no close button (Esc or a click outside closes it).
- Notes: screenshots `qa/shots/p2-start.png` (rail sun), `p2-weather-sheet.png` (empty sheet), `p2-pages-tab.png` (Settings tile). `WeatherIcon` (`lib/core/widgets/weather_icon.dart`) falls back to `PhosphorIcons.sun` for any unknown or null icon. After saving "Chicago, US" the rail showed a cloud and "25°" and the forecast sheet worked (daily cards, day selection, Esc and X close it).

### BUG-009 [Phase 2] Shell and pages can't be driven by Tab: focus is invisible, and with nothing focused Tab goes nowhere
- Severity: Minor
- Found: 2026-09-29, Phase 2
- Steps to reproduce: (a) Rankings page on a new account ("No categories yet" / "Create a category"). Click an empty area, press Tab 6 times, then Enter. After each Tab, read `FocusManager.instance.primaryFocus` over the VM service. (b) To-Do page with 40 tasks: click the "Add task" field, then press Tab 4 times, reading the focus the same way.
- Expected: Tab moves focus to the next control (rail items, weather button, inbox, the page's buttons) with a visible focus indicator; Enter/Space activates the focused control.
- Actual: (a) focus stays on the root `FocusScopeNode` after every Tab; nothing gets focus, nothing is highlighted, and Enter does nothing (no "Create a category" dialog). (b) focus moves to a different `FocusNode` on each Tab and the task list scrolls (so focus is going into the list rows), but no row, checkbox, star or button shows any focus indicator, so the user can't tell where they are.
- Notes: screenshots `qa/shots/p2-tab-1..6.png`, `p2-tab-enter.png`, `p2-tab-todo.png`. The rail's destination buttons are wrapped in `ExcludeFocus` (`lib/features/shell/app_shell.dart`), so they are deliberately out of the Tab order; Ctrl+Tab / Ctrl+Shift+Tab is the only keyboard route between pages (it works, including over hidden/reordered pages). The weather button and inbox bell were not reached by Tab in (a). Same pattern as BUG-006 (login page); this is the app-wide case. Scatter was on.

### BUG-010 [Phase 2] Signing in on an empty device: the Journal page shows no entries until restart, although they were pulled
- Severity: Major
- Found: 2026-09-29, Phase 2
- Steps to reproduce: account with one journal entry in the cloud (voyager-qa-004: journal `__legacy__` "Journal", one entry with body "QA draft body for state check MIDEDIT-TRAY"). With Voyager signed in to it: `guard.ps1` → `reset.ps1 -Force` → `launch.ps1` → `login.ps1 -Email voyager-qa-004@example.com`. Wait 15 s, check SQLite, look at Journal; switch to To-Do and back.
- Expected: once the startup pull has written the entry, the Journal page lists it.
- Actual: SQLite has the journal and the entry (`deleted_at` NULL) within 15 s, and the outbox is empty, but the Journal page header says "Journal 0", the entry list is empty and the editor shows a blank new-entry form ("Start writing…", dated 4:49 PM). Switching pages doesn't change it. After `stop.ps1` → `launch.ps1` the header shows "Journal 1" and the entry is listed and opens with its text.
- Notes: screenshots `qa/shots/p2-cold.png`, `p2-cold-journal2.png` (before restart), `p2-cold-restart-journal.png` (after). No FlutterError in `qa/logs/run-20260929-164924.log`. Probably the same cause as BUG-004 (the Journal page doesn't react to journals/entries written outside it), here hit by the startup pull; not verified. Risk: on a new PC or after a wipe, the user sees an empty journal with an editable blank form, and text typed there is not saved (BUG-003). To-Do tasks (40) were also in SQLite after the pull; the To-Do page wasn't screenshotted before the restart.
- Notes (2026-09-30, cause found in code; seen by Juno on the real account after a full restore): not specific to the Journal page. Almost every page reads its data through a `FutureProvider` with `ref.keepAlive()` in `lib/app/providers.dart` (e.g. `journalEntryCountsProvider`, `allDreamEntriesProvider`, `transactionsProvider`, `leetcodeProblemsProvider`, the study providers, `calendarsProvider`, `workoutPlansProvider`, and the reminder providers of BUG-043). Each reads SQLite once, when first watched, and keeps that result for the session. On an empty device those first reads run before the startup pull has written anything, so they keep an empty result. When `pullAll` returns, `lib/main.dart` (`_warmUpAfterFirstShellFrame`) invalidates only `journalEntriesProvider`, `journalsProvider`, `settingsProvider` and `todoListsProvider`; nothing else is re-read. Live sync starts after the pull and listens only from the new watermarks, so it never revisits what the pull wrote. A restart (or hot restart) rebuilds every provider from the now-full database.
  - Seen on the real account after a restore that finished: the journal dropdown showed 0 for every journal (counts come from `journalEntryCountsProvider`, not invalidated), and "All journals" counted only the open journal. The Finance ledger, Analytics, Dream, LeetCode and Study pages were empty. Calendar and Workout weren't checked, but their providers aren't invalidated either. To-Do worked because `todoListsProvider` is one of the four, which also explains why the to-do feed items appeared in BUG-043.
  - Same cause: BUG-043 (reminders, pinned notes and dismissals after a cold sign-in). Same underlying cause with a different trigger: BUG-004 (a kept journal/entry provider isn't re-read after the page's own first write); not verified for BUG-004.
  - The restart that shows the data also pulls a few hundred documents again; that is a separate issue, BUG-044.
- Notes (2026-09-30, fixed in the working tree, uncommitted): after the startup pull, `lib/main.dart` now calls `invalidateAllDataProvidersFrom(ref)`, the same refresh live sync and backup restore already use, in place of the four hand-picked invalidations. It covers every provider in `_journalEntryProviders`, `_primaryDataProviders`, `_workoutDataProviders` and `_secondaryDataProviders` (journal counts, dreams, LeetCode, study, workout, calendar, trackers, finance, reminders, pinned notes, dismissals, jobs, rankings, settings). Providers that derive from those (Life stats, study deck graph, pending tracker entries) refresh through them. Pages still stay empty *during* the pull; they fill in when it ends.
  - Still not refreshed after the pull (outside every list, a gap live sync and backup restore share): `customQuotesProvider` (and so the quote pool) and `historicalJournalEntriesProvider`.
  - Tests: none cover `main.dart`'s startup path; the full suite passes (3,990). To verify: TEST_PLAN.md "Fix verification" FV-2.

### BUG-011 [Phase 2] After signing in on an empty device, the startup page ignores the account's startup setting
- Severity: Minor
- Found: 2026-09-29, Phase 2
- Steps to reproduce: in Settings, reorder the navigation pages so Jobs is first (Startup page = "First page in navigation order", the default). Restart: Voyager opens on Jobs. Then do a cold re-login as in BUG-010 (wipe local data, sign in).
- Expected: after sign-in, Voyager opens on Jobs, the first page of the pulled navigation order.
- Actual: it opens on Journal (the default first page), although the pulled settings (`nav_page_order_json` starting with `/jobs`, `startup_page_mode` = `first`) were in SQLite and the rail already showed Jobs first. After a restart it opens on Jobs.
- Notes: screenshots `qa/shots/p2-cold.png` (Journal after sign-in, Jobs first on the rail), `p2-relaunch.png` and `p2-cold-restart.png` (Jobs after a restart). The redirect after login seems to be decided from the settings present before the pull (suspected). Phase 1 saw "Last seen → Settings after sign-in", which may be the same effect.

### BUG-012 [Phase 2] Adding the first task creates a hidden empty "To-do" list, which a new device then opens instead of the user's list
- Severity: Minor
- Found: 2026-09-29, Phase 2 (incidental; the To-Do page itself is Phase 9)
- Steps to reproduce: new account → To-Do → "Create your first list" → New list "QA List" → Esc. Manage lists shows only "QA List". Add a task in the composer. Then sign in to the same account on an empty device (cold re-login) and open To-Do.
- Expected: tasks go into "QA List" and only lists the user created exist; on another device To-Do opens on "QA List" (or All tasks).
- Actual: the first task add also created list `__legacy_todo__` "To-do" (created_at 20:22:14.798Z, 12 ms before the first task at 20:22:14.810Z). The tasks went to QA List, so the extra list stayed empty and went unnoticed. After the cold re-login, To-Do opened on "To-do 0 | 0" (an empty page), and the picker lists All tasks 40, QA List 40, To-do 0 (selected). The user has to find their list again on every new device.
- Notes: screenshots `qa/shots/p2-vim-normal.png` (empty "To-do" after the cold pull), `p2-todo-picker.png`. In `lib/features/todo/todo_page.dart`, `_ensureDefaultList` creates the built-in list whenever it's missing, and `_selectedListId` falls back to it; `lastViewedTodoListId` is device-local (PROGRESS.md §1), so a fresh device always lands on the built-in list.

### BUG-013 [Phase 3] Vim `h` wraps onto the previous line, so `dh` at the start of a line deletes the line break
- Severity: Minor
- Found: 2026-09-29, Phase 3
- Steps to reproduce: Settings → Editing → Vim keybindings ON. Journal body with the text "alpha beta gamma delta⏎one two three four five⏎⏎foo(bar, baz); qu.end". Put the caret on the "o" of "one" (column 0 of line 2), press Esc (Normal), then (a) `h`; (b) `dh`; (c) from the "n" of "one", `2h`.
- Expected: as in Vim (`whichwrap` default): `h` stops at column 0, so (a) stays on "o", (b) does nothing, (c) stops on "o". `l` in this build does stop at the end of the line.
- Actual: (a) the caret moves to the last character of the previous line ("a" of "delta", offset 21); (b) the line break is deleted, joining the lines into "…gamma deltaone two three…"; (c) the caret lands on offset 21. `u` restores the text.
- Notes: probed with `qa/harness/vimcase.ps1` (sets the fixture over the VM service, sends real keys, reads the field back); cases `h-bol`, `dh-bol`, `2h-bol` in `qa/steps/p3-cases*.tsv`. The `h` case in `lib/core/vim/vim_session.dart` applies `cursor - count` with no line clamp. `j`, `k`, `0`, `$` and word motions all matched Vim. Scatter was on (irrelevant).
- Notes (same session): **`l` with a count crosses lines too.** A single `l` (or `2l` from "t" of "delta") stops on the last character, apparently only because the landing spot is the line break itself. `5l` from the "t" of "delta" (offset 20) lands on offset 25 in the next line, `9999l` from offset 0 lands on the last character of the whole text (68), and `99999999999999999999h` from the last line goes to offset 0. **`d5l` from the "t" of "delta" deletes "ta⏎on"**, joining lines 1 and 2 ("…gamma dele two three…"). Cases `l-5-at20`, `l-9999`, `h-huge`, `d5l-at20` in `qa/steps/p3-fail*.tsv`. A huge count on `x` (`999x`, `99999999999999999999x`) correctly stops at the end of the line.
- Notes (2026-09-29, follow-up on the commands missing from VIM.md): the line-boundary rules are the reverse of Vim's `whichwrap=b,s` for Space. Normal-mode Space on the last character of a line stays put (Vim moves to the next line), while Backspace does wrap to the previous line's last character (as in Vim). So `h` and Backspace wrap, and Space and a single `l` don't. Cases `space-wrap`, `backspace-wrap`, `l-no-wrap` in `qa/steps/p3x-cases*.tsv`.

### BUG-014 [Phase 3] Vim `/` search with no match still moves the caret to a partial match
- Severity: Minor
- Found: 2026-09-29, Phase 3
- Steps to reproduce: Vim ON, same journal text as BUG-013, caret at the start (offset 0) in Normal mode. Type `/zz` and press Enter. Separately: `/qqq` Enter.
- Expected: as in Vim: "Pattern not found", and the caret stays where `/` was pressed (offset 0).
- Actual: the prompt shows "/zz  no matches", yet the caret sits on the "z" of "baz" (offset 59), and it stays there after Enter. `/qqq` leaves the caret on the "q" of "qu" (offset 63). The caret follows the longest prefix of the pattern that did match; later characters that break the match don't move it back.
- Notes: screenshots `qa/shots/p3-search-zz-bottom.png` (prompt "no matches"), `p3-sheet-search.png` (caret on the "z"). In `_refreshSearchPreview` (`lib/core/vim/vim_session.dart`), the caret is moved only when a match exists (`if (index != null) _setCursor(...)`), so a pattern that stops matching leaves it on the previous preview. Esc does put the caret back, and searches with matches, `n`, `N` and wrap-around all behave.

### BUG-015 [Phase 3] Vim motions split emoji in half: inserting there crashes the app, and `x` on an emoji leaves a "�" that is saved and synced
- Severity: Blocker
- Found: 2026-09-29, Phase 3
- Steps to reproduce: Settings → Editing → Vim keybindings ON. Journal → an entry → click the body. Put "x😀y" on the clipboard (`Set-Clipboard ('x' + [char]::ConvertFromUtf32(0x1F600) + 'y')`), select all, Backspace, Ctrl+V. Then Esc, `0`, `l`, `l`, `i`, type `Z`.
  - Variant (corruption): body "EMOJI a😀b end", Normal mode, caret on the emoji, press `x`.
- Expected: `h`/`l` step over an emoji as one character (as Vim and Flutter's own arrow keys do); `x` deletes the whole emoji; nothing crashes.
- Actual:
  - `l` from "x" lands on offset 1 (the emoji), a second `l` lands on offset 2, **between the two UTF-16 halves** of the emoji (the block caret is drawn before "y"). `h` from "y" also lands mid-emoji. The ZWJ family emoji 👨‍👩‍👧 is split the same way (`l l` from before it → offset 2, `h` from after it → offset 8).
  - `i` then `Z` there: **the app crashes** within about a second: `voyager.exe` exits, the run log ends "Lost connection to device", and Windows logs Application Error 1000 (faulting module `flutter_windows.dll`, exception 0xc0000409, offset 0x1243498). Reproduced twice (17:18:53 and 17:19:53) with the same fault offset. The second time used only real keyboard input (above). What autosave had written before the crash ("x😀y") survived.
  - `x` on the emoji deletes only its first half. The field then draws only "�" for the whole body (the rest of the text vanishes from view) and the run log fills with `ArgumentError: string is not well-formed UTF-16` (painting library, `_NativeParagraphBuilder.addText`), plus "Unable to parse JSON message: The surrogate pair in string is invalid. / Unable to construct method call from message on channel flutter/textinput". The body is saved as "EMOJI a�b end" (bytes `EF BF BD`), and the outbox drained, so the "�" went to the cloud copy too. The ZWJ family emoji likewise loses half of its first code point.
- Notes: the first crash happened in the probe run after the `x` case (`qa/steps/p3-emoji-i.tsv`, `l l iZ` on "a😀b"). Screenshots `qa/shots/p3-emoji-x.png` (body shows only "�"), `p3-sheet-crash.png` (caret mid-emoji before the crash). Logs `qa/logs/run-20260929-170700.log` (12 UTF-16 exceptions, then lost connection), `run-20260929-171921.log` (no Dart error before the native crash). `h`/`l`/`x` in `lib/core/vim/vim_session.dart` move by `cursor ± count` in UTF-16 code units with no grapheme or surrogate handling. With Vim OFF, typing in the field goes through Flutter's own editing, which is surrogate-aware (not re-tested here). CJK text (BMP) behaved correctly (`w`, `x`). Any emoji in any Vim-enabled field is exposed, e.g. entries written on a phone.

### BUG-016 [Phase 3] Vim Normal mode: Enter in a one-line field doesn't submit (it only moves the caret to the start)
- Severity: Minor
- Found: 2026-09-29, Phase 3
- Steps to reproduce: Vim ON. (a) To-Do → "Create your first list" → "+ New list" → type "Vim List" in Name → Esc (NORMAL badge) → Enter. (b) With a list, click the To-Do "Add task" composer, type "task normal enter" → Esc → Enter.
- Expected: per the design note in `lib/core/vim/vim_text_scope.dart` (`_routeEarlyKey`: "A one-line field has no line for Enter to move to, so there it still submits"), Enter submits in Normal mode too: (a) creates the list, (b) adds the task.
- Actual: nothing is submitted; the caret jumps to the first character (Vim's Enter motion: first non-blank of the next line, here the same line). `todo_lists_table` / `todo_tasks_table` stay empty. Pressing `A` then Enter (Insert mode) submits normally ("Vim List" and "task insert enter" were created).
- Notes: screenshots `qa/shots/p3-dlg-enter.png` (dialog still open, caret on "V", NORMAL), `p3-dlg-insert-enter.png`, `p3-composer-normal-enter.png`. Combined with the intended "Esc never closes a dialog from a Vim field", a user in Normal mode has no keyboard way to finish a one-line dialog except returning to Insert first (or Ctrl+Enter where a form supports it; not checked here).

### BUG-017 [Phase 3] Pasting multi-line text into a one-line field keeps an invisible carriage return, which is saved
- Severity: Minor
- Found: 2026-09-29, Phase 3 (not Vim-specific)
- Steps to reproduce: copy two lines from any Windows app (the clipboard then holds "L1⏎L2" with CRLF; here `Set-Clipboard -Value "L1`r`nL2"`). Journal → an entry → click the Title → Ctrl+A → Ctrl+V. Wait for autosave.
- Expected: the line break is dropped or turned into a space ("L1L2" or "L1 L2"), with no control characters in the saved title.
- Actual: the field shows "L1L2", but `journal_entries_table.title` is "L1\rL2" (hex `4C 31 0D 4C 32`): the `\n` is removed and the `\r` kept, invisibly. Same with Vim ON: Ctrl+V in Insert mode gives "…titleL1\rL2"; Ctrl+V in Normal mode gives "…titleL1\r L2" (Vim flattens `\n` to a space and keeps the `\r`). The value synced (outbox drained).
- Notes: screenshots `qa/shots/p3-vimoff-title.png` (Vim OFF), `p3-title-cr-crop.png` (Vim ON). Checked only on the journal Title; probably any one-line field (todo titles, list names, finance fields). Consequences not checked: search, exports, and how the title renders elsewhere (entry list, Search results).

### BUG-018 [Phase 3] Vim `yy` moves the caret to the start of the line; in a one-line field `p` then pastes after the first character
- Severity: Minor
- Found: 2026-09-29, Phase 3
- Steps to reproduce: Vim ON. Journal Title "Vim probe title", caret on "p" (offset 4), Esc → `yy` → `p`.
- Expected: as in Vim, `yy` leaves the caret where it was; in a one-line field the flattened line is put after the caret ("Vim p Vim probe titlerobe title" style) or at least somewhere predictable.
- Actual: after `yy` the caret is at offset 0. `p` then gives "VVim probe title im probe title" (the line plus a space spliced in after the first character). In the multi-line body, `yy` then `p` puts the line below correctly (linewise), so only the caret jump shows there.
- Notes: cases `t-yy-caret`, `t-yyp` in `qa/steps/p3-title*.tsv`.

### BUG-019 [Phase 3] At the minimum window size the Vim `/` prompt covers the journal quote under the editor
- Severity: Cosmetic
- Found: 2026-09-29, Phase 3
- Steps to reproduce: Vim ON, window at the minimum size (`place 0 0 1440 1040`), Journal with quotes shown. Click the body, Esc, type `/o`.
- Expected: the prompt bar and the quote under the editor don't overlap.
- Actual: the prompt ("/o 1|5") is drawn over the first line of the quote ("Your life is your story, and the adventure ahead"), which shows only as fragments above and below the bar. At 2000×1100 and maximized there is room and nothing overlaps.
- Notes: screenshot `qa/shots/p3-min-search.png` (compare `p3-odd-search.png`). Dark + Scatter.

### BUG-020 [Phase 3] Vim `V j J` (line-wise Visual join) joins one line too many
- Severity: Minor
- Found: 2026-09-29, Phase 3 (follow-up: commands missing from VIM.md)
- Steps to reproduce: Vim ON. Journal body "one⏎two⏎three⏎four", caret on "one", Esc → `V` `j` (lines "one" and "two" highlighted) → `J`.
- Expected: as in Vim, the two selected lines are joined: "one two⏎three⏎four".
- Actual: three lines are joined: "one two three⏎four". "three", which wasn't selected, is pulled up too. When the next line is empty (as in the first probe), the blank line silently disappears instead. `2J` and character-wise `v j J` correctly join just two lines.
- Notes: cases `V-j-J`, `v-J`, `J-count-2`, `v-J-charwise` in `qa/steps/p3x-cases*.tsv`. In `_joinLines` (`lib/core/vim/vim_session.dart`) the Visual branch counts the `\n` characters inside the Visual range; a line-wise range includes the last selected line's own newline, so the count is one higher than the number of joins needed. `u` restores the text.

### BUG-021 [Phase 4] Autocorrect rewrites common typos into different wrong words ("littl" → "litt", "peopl" → "peop", "bcause" → "cause")
- Severity: Major
- Found: 2026-09-29, Phase 4
- Steps to reproduce: new account, Vim OFF, autocorrect ON (default). Journal → an entry → click the body. Type each of these words followed by a space: `littl`, `peopl`, `nevr`, `culd`, `shuld`, `wht`, `bcause`, `drw`; and `qux` followed by `.`.
- Expected: per AUTOCORRECT.md §1 ("obvious typos" only, "conservative"), the word becomes the one the user meant (`little`, `people`, `never`, `could`, …), or stays as typed with a squiggle when that's not certain.
- Actual: each is replaced, with no prompt, by a different, wrong word: `litt`, `peop`, `nerv`, `cud`, `shul`, `wth`, `cause`, `dr`, `qu.` (read back from the field). The replaced word is a valid dictionary entry, so it no longer squiggles and the mistake is easy to miss. Backspace right after the correction reverts it (§7.2 works), and `wtih`→`with`, `jsut`→`just`, `knwo`→`know`, `thnig`→`thing` are corrected properly.
- Notes: cases `ac-*` in `qa/steps/p4-ac1.tsv` (run with `qa/harness/vimcase.ps1`; Vim OFF). Two causes combine. (1) The cascade tries transpose and delete before insert (AUTOCORRECT.md §3.1), so a word with one *missing* letter (the most common typo) is corrected by whichever transpose/delete lands on any dictionary entry first. (2) The bundled list (`assets/dictionary_en.txt`, 65,026 lines) is full of fragments and rare words that make those landings likely: 490 one- or two-letter entries (`dr`, `lk`, `bl`, `ll`, `ve`, `qu`, …) and words like `litt`, `peop`, `shul`, `cud`, `wth`, `nerv`. An offline emulation of the cascade over the dictionary (scratch script, same transpose→delete→insert rule): dropping one letter from each of the 3,000 most frequent words (length ≥ 4) gives 6,777 right corrections, 3,428 wrong ones (2,538 via delete, 890 via transpose) and 2,352 left alone. The emulation matched every in-app case tried. Also the lead from Phase 3 ("qux." → "qu."). The Settings → Editing → Autocorrect subtitle itself promises a fix "only when one dictionary word is a single swapped, missing or extra letter away". The right-click suggestions show the same bias: for `littl` they list `litte`, `litt`, then `little` (`qa/shots/p4-rclick2.png`), and the Flag popover for `neve` prefills "Always replace with" as `nave`.

### BUG-022 [Phase 4] Common misspellings are in the bundled dictionary, so they are never flagged or corrected ("teh", "recieve", "seperate", "definately")
- Severity: Minor
- Found: 2026-09-29, Phase 4
- Steps to reproduce: Journal body, type (or paste) `teh recieve seperate definately alot thier untill wich wtiz blorf ok` and wait a second. Also type `teh` followed by a space.
- Expected: the misspellings get the red squiggle and right-click suggestions; `teh` + space autocorrects to `the` (a unique transpose, AUTOCORRECT.md §3.1).
- Actual: only `wtiz` and `blorf` squiggle; the eight misspellings look correct. `teh` + space and `recieve` + space are left as typed.
- Notes: screenshot `qa/shots/p4-squiggle-crop.png`. All of them are lines in `assets/dictionary_en.txt`, e.g. `seperate` (line 45697), `occured` (34985), `untill` (29539), `wich` (36118), `becuase` (51000), `alot` (19283), `thier` (52072), `goverment`, `tommorow`, `truely`, `wierd`, `realy`, `remeber`, `begining`, `millenium`, `publically`, `comming`, `adress`, `beleive`, `teh`, `recieve`, `definately`, `helo`. Workaround: flag each one (Settings → Dictionary), which FLAGGED_WORDS.md exists for. Cases `ac-teh`, `ac-recieve` in `qa/steps/p4-ac1.tsv`.

### BUG-023 [Phase 4] Enter doesn't trigger autocorrect (newline isn't treated as a word boundary)
- Severity: Minor
- Found: 2026-09-29, Phase 4
- Steps to reproduce: Journal body, Vim OFF. Type `wtih` and press Enter. Also: `hello wtih` + Enter; `wtih` + Shift+Enter; in a list (`- a⏎- `) type `wtih` + Enter.
- Expected: AUTOCORRECT.md §2 lists newline as a boundary: `with⏎` (and `- with⏎- ` in the list, per §16.2's note on list continuation).
- Actual: the word stays `wtih` in every case. The same word followed by space, `,`, `.` or `*` is corrected.
- Notes: cases `ac-enter`, `ent-*` in `qa/steps/p4-ac2.tsv`/`p4-ac3.tsv`; also with a 300 ms pause before Enter. So the last word of every line or paragraph is never corrected.

### BUG-024 [Phase 4] Undoing an autocorrect also removes the space, and redo doesn't bring the correction back
- Severity: Minor
- Found: 2026-09-29, Phase 4
- Steps to reproduce: Journal body, empty. Type `wtih`, Space (becomes `with `), wait 0.7 s, Ctrl+Z. Then Ctrl+Y (or Ctrl+Shift+Z).
- Expected: AUTOCORRECT.md §8: undo restores the pre-correction text (`wtih `, with the typed space), and redo restores the correction (`with `).
- Actual: Ctrl+Z gives `wtih` (the space typed after the word is gone too); Ctrl+Y and Ctrl+Shift+Z then do nothing (text stays `wtih`). The immediate-Backspace revert behaves as designed (`wtih`, then suppressed for that field).
- Notes: cases `undo`, `undo-redo`, `undo-shz` in `qa/steps/p4-ac2.tsv`/`p4-ac3.tsv`.

### BUG-025 [Phase 4] Adding a letter to the end of an existing word doesn't autocorrect it
- Severity: Minor
- Found: 2026-09-29, Phase 4
- Steps to reproduce: Journal body with `I went wti⏎more text`. Click at the end of the first line (after `wti`), type `h`, then Space. Same with the caret put there by Home → End.
- Expected: AUTOCORRECT.md §4.3: a token that got at least one inserted keystroke since the caret entered it is eligible → `I went with `.
- Actual: stays `I went wtih ` (read back over the VM service). Inserting a letter inside a word (`wih` → type `t` between `w` and `i`) or returning to the word's end with the Left arrow from the next word does correct it.
- Notes: cases `edit-end`, `edit-end-eol`, `edit-comma` (`p4-ac3.tsv`), `real-end-click` (`p4-ac4.tsv`), and a real mouse click (`qa/shots/p4-click-end.png`).

### BUG-026 [Phase 4] Dictionary dialog: pressing Enter on an invalid word drops keyboard focus from the field
- Severity: Minor
- Found: 2026-09-29, Phase 4
- Steps to reproduce: Settings → Editing → Dictionary. (a) Click "Search or add a word", type `well-known`, press Enter. (b) Search `then`, click the flag icon on its row, type `form` (a flagged word) or `zzqqx` (unknown) in "always replace with", press Enter. In each case, then press Ctrl+A and type something.
- Expected: the error shows under the field and the caret stays in the field, so the user can correct the word from the keyboard.
- Actual: the error line appears ("A dictionary word is one word: letters, and apostrophes inside it." / ""form" is flagged too — pick a word the checker accepts" / "The checker doesn't know "zzqqx" — add it to the dictionary first"), but focus moves to the dialog's focus scope (`FocusManager.primaryFocus` = `_ModalScopeState` scope). Ctrl+A and typing go nowhere; the field shows no focus border. The user has to click back into the field. A valid add (`zorblax` + Enter) keeps focus, with the text selected.
- Notes: screenshots `qa/shots/p4-dict-hyphen.png` (the later typed `voyager2` never arrived), `p4-rep-flagged.png`. The validation messages themselves are right (also "The replacement has to be a different word", ""abc" is already in the dictionary."). Related to the app-wide focus issues (BUG-006, BUG-009).

### BUG-027 [Phase 4] On a list line, Tab indents the line instead of expanding a manual snippet
- Severity: Minor
- Found: 2026-09-29, Phase 4
- Steps to reproduce: Settings → Editing → Text snippets: expand key Tab (default), add snippet `;sig` → `Best regards, Juno` (not automatic). Journal body: type `;sig` then Tab on a plain line → it expands. Now on a list line: `- ;sig` (caret after `;sig`), press Tab. Also `* ;sig`, `1. ;sig`, and `- ;sig x` with the caret right after `;sig`.
- Expected: SNIPPET.md §4.5: with Tab as the expand key, Tab tries tag accept → tabstop advance → **manual snippet expand** → focus, so the trigger before the caret expands: `- Best regards, Juno`. List indent should only apply when no trigger matches.
- Actual: the line is indented and the trigger stays: `  - ;sig`, `  * ;sig`, `  1. ;sig`, `  - ;sig x`. A manual snippet can never be expanded with Tab inside a list, which is where short triggers are most useful in a journal. Auto-expand snippets are unaffected; switching the expand key to Space would avoid it.
- Notes: cases `sn-list-tab` (`qa/steps/p4-sn1.tsv`), `sn-list-mid`, `sn-list-star`, `sn-num-list` (`p4-sn2.tsv`). `- item` + Tab indents as expected (`sn-list-indent`). The test plan named this conflict ("snippet vs list-indent Tab").

### BUG-028 [Phase 4] A `*` inside a word ("2*3") opens italic and pairs with a `*` lines later, restyling everything in between
- Severity: Minor
- Found: 2026-09-29, Phase 4
- Steps to reproduce: Journal body (any multi-line prose field). Paste or type `and 2*3⏎foo**bar**baz`, then click outside the text (end of the body). Also `and 2*3⏎see foo* bar`.
- Expected: EMPHASIS_FORMATTING.md §11: "`2*3` → Literal asterisks unless paired — `*3` is not a valid italic pair." The first line shows `2*3`; the second shows `foo` **bar** `baz`.
- Actual: the `*` of `2*3` is hidden and everything from `3` to the next closing `*` is italic, across the line break: line 1 shows "and 23" with `3` italic, line 2 shows *foobar*`*baz` (the bold is broken, one `*` of it is shown, the other hidden). With `see foo* bar` on line 2, "and 23 / *see foo* bar". In a longer entry (fixture `qa/steps/p4-emph.tsv`), a `2*3` on line 3 italicized lines 4–6 and hid the markers of an unrelated unclosed `**open and *half` line, which on its own correctly stays literal.
- Notes: sheets `qa/shots/p4-emph-sheet4.png` (d2, d5 vs d1/d3/d4, which pair nothing and render correctly), `p4-again-emph.png`. The stored text is unchanged (display only). Isolated `2*3` lines, `2 * 3`, `$x * y$`, backtick code, `**#tag**`, bullets `* item`, nested bold/italic, underline and highlight all render as the HLD says (`p4-emph-hidden.png`, `p4-emph-sheet*.png`). §2.3's flanking rule only checks whitespace, so an intra-word `*` counts as an opener; an ordinary pair can also span a line break (`a *start…⏎…ends* here` is italic across both lines), which is what lets the stray one reach so far.

### BUG-029 [Phase 4] Scrolled journal body keeps a top strip that shows the cut-off bottom of the previous line
- Severity: Cosmetic
- Found: 2026-09-29, Phase 4
- Steps to reproduce: window 2000×1100. Journal body with 60 lines (`line N gjpqy`, so every line has descenders and a squiggle). Ctrl+End, then press Up ~25 times so the body is scrolled to the middle. Look at the top edge of the body.
- Expected: MULTILINE_FIELD_SCROLL_INSETS.md "Desired behavior" 1 and 3: once scrolled, text runs flush to the top border and nothing is drawn in a gutter.
- Actual: there is a blank strip of roughly one text-descender height between the border and the first full line, and it shows the lower part of the scrolled-out line above (the descenders of "gjpqy" and a piece of its red squiggle), faint but visible.
- Notes: crop `qa/shots/p4-scroll-topcrop.png` (from `p4-scroll-mid.png`). MULTILINE_FIELD_SCROLL_INSETS.md records this as an open issue ("Issue note only — no fix implemented here"); logged so the audit tracks it. At the bottom of the text (Ctrl+End) the caret and last line stay inside the border (`p4-scroll-a.png`). Dark + Scatter.

### BUG-030 [Phase 4] Journal list preview cuts the first sentence at "1." or "Dr.", showing a meaningless fragment
- Severity: Cosmetic
- Found: 2026-09-29, Phase 4 (incidental; the entry list is Phase 7)
- Steps to reproduce: Journal → an entry. Type the body `1. apple⏎pear` (a numbered list), wait for autosave, and look at the entry card in the list. Then replace the body with `Met Dr. Smith at 3 p.m. today`.
- Expected: the card previews the start of the entry, e.g. "1. apple" / "Met Dr. Smith at 3 p.m. today".
- Actual: the card shows "1." and "Met Dr." respectively. `- apple⏎pear` shows "- apple", and `plain first line⏎second` shows "plain first line", so only a period followed by a space triggers it.
- Notes: crops `qa/shots/p4-sheet.png` (numbered vs dash vs plain; from `p4-prev-num.png`, `p4-prev-dash.png`, `p4-prev-plain.png`) and `p4-crop.png` (from `p4-prev-dr.png`). The preview comes from `firstSentencePreview` (`lib/features/journal/journal_page.dart`), which ends the sentence at the first ". ". Entries that start with a numbered list, an abbreviation, an initial ("J. R. R.") or a time ("9 a.m.") all get a one- or two-word preview. 1440×1040, Dark + Scatter.

### BUG-031 [Phase 4] Snippets dialog hides snippets beyond the fourth with no sign that the list scrolls
- Severity: Cosmetic
- Found: 2026-09-29, Phase 4
- Steps to reproduce: create 6 snippets (here `;sig`, `addr`, `pp`, `wtih`, `zz`, `lng`). Put the window at 2000×1100 (`place 200 100 2000 1100`). Settings → Editing → Text snippets.
- Expected: all snippets visible, or a visible cue (scrollbar, fade, a half-cut row) that more are below.
- Actual: the dialog lists `;sig`, `addr`, `pp`, `wtih`, then "Add snippet", with every row whole and no scrollbar or fade. `zz` and `lng` only appear after scrolling the mouse wheel over the list. The Settings tile says "6 snippets", so the dialog looks like it lost two. Maximized (2880×1800) all six show.
- Notes: screenshots `qa/shots/p4-light-snip-a.png` (before scrolling), `p4-light-snip-b.png` (after), `p4-light-snippets.png`. Seen in Light; the layout is theme-independent. DB: all six live in `snippets_table`.

### BUG-032 [Phase 4] Every image upload logs an engine error: firebase_storage sends channel messages off the platform thread
- Severity: Minor
- Found: 2026-09-29, Phase 4
- Steps to reproduce: "Upload images to the cloud" ON (default). Paste an image into a journal entry (clipboard with the registered "PNG" format, as Snipping Tool gives). Watch the `flutter run` output.
- Expected: no engine errors.
- Actual: each upload prints `[ERROR:flutter/shell/common/shell.cc(1183)] The 'plugins.flutter.io/firebase_storage/taskEvent/<id>' channel sent a message from native to Flutter on a non-platform thread. Platform channel messages must be sent on the platform thread. Failure to do so may result in data loss or crashes, and must be fixed in the plugin or application code creating that channel.` Nine uploads here, nine errors. The uploads themselves finished (`media_assets_table.upload_state = uploaded` for all) and nothing crashed in this session.
- Notes: `qa/logs/run-20260929-182045.log`. The message comes from the Windows firebase_storage plugin's task-event channel, not from Voyager's Dart code; the engine's own warning is the reason for the severity (risk of lost events or a crash during uploads, not observed). Not written to `voyager_errors.log`.

### BUG-033 [Phase 5] The to-do draft carried into the composer arrives fully selected, so the first keystroke erases it
- Severity: Minor
- Found: 2026-09-29, Phase 5
- Steps to reproduce: Vim OFF. With another app focused, press Ctrl+Alt+T, type `draft x`, click the other app (floater dismissed, draft kept). Focus Voyager on Journal and press Ctrl+Alt+T (in-app path). Type `y`.
- Expected: GLOBAL_HOTKEY_FLOATERS_HLD.md §5.3: "Prefill composer with the session draft" so the user can continue the capture; the caret at the end of the draft.
- Actual: the composer holds `draft x` with the whole text selected (`qa/shots/p5-f11.png`); typing `y` replaces it, leaving `y` (`p5-f11-type.png`). Ctrl+Z brings `draft x` back.
- Notes: step file `qa/steps/p5-f11.txt`. The composer is focused correctly (AUDIT_TESTING finding 11's focus problem is gone). Same select-all as the Phase 3 lead (closing the Ctrl+/ list selects the composer's text). The floater's "Open app" icon does the same: `open app draft` arrives fully selected (`qa/shots/p5-openapp.png`).

### BUG-034 [Phase 5] A global hotkey another app already owns at launch is silently dead for the whole session
- Severity: Minor
- Found: 2026-09-29, Phase 5
- Steps to reproduce: Quit Voyager. In another process, register Ctrl+Alt+R as a global hotkey (the harness's probe form, `RegisterHotKey`). Launch Voyager (signed in). Press Ctrl+Alt+R. Then close the other process and press Ctrl+Alt+R again.
- Expected: some sign that the reminder hotkey couldn't be registered (Settings shows the combo as unavailable, or an error/notice), and the hotkey working once the combo is free, or at least after re-checking.
- Actual: the first press goes to the other process (its hotkey counter went up; Voyager didn't react). After that process exits, nobody owns Ctrl+Alt+R (`RegisterHotKey` succeeds for the probe), so Voyager never registered it and doesn't retry: the combo does nothing until Voyager restarts. No FlutterError, nothing in `voyager_errors.log` (the bootstrap catch "while registering global hotkeys" never fires), and Settings → Editing still lists "Reminder hotkey Ctrl+Alt+R". The other three hotkeys worked.
- Notes: probe script `startup_probe.ps1` (scratchpad; the grab is `voy.ps1 other-grab ctrl+alt+r`), log `qa/logs/run-20260929-224237.log`. Hotkeys are registered once, in `_bootstrap` (`lib/main.dart`). The HLD has no rebinding UI, so there is no in-app way around it.

### BUG-035 [Phase 5] Replacing one floater with another can re-enter the frame pipeline (scheduler assertions from `SetWindowPlacement`)
- Severity: Minor
- Found: 2026-09-29, Phase 5
- Steps to reproduce: not reliably reproducible. Seen once, at 22:38:34–22:38:35, while floaters were being opened and replaced from another app during the Vim/spam runs (the exact keypresses at that instant are not known). Two pairs of errors, 0.5 s apart.
- Expected: no FlutterErrors when a hotkey replaces an open floater.
- Actual: `Failed assertion: line 1253 pos 12: 'schedulerPhase == SchedulerPhase.idle'` from `SchedulerBinding.handleBeginFrame`, called synchronously from `SetWindowPlacement` in `FloaterWindow._place` (`floater_window.dart:529`) ← `FloaterWindow.show` ← `FloaterController.onHotkey` replacement branch (`floater_controller.dart:124`), each followed by `'_schedulerPhase == SchedulerPhase.midFrameMicrotasks'` from `handleDrawFrame`. Unhandled (dart_vm_initializer), also in `voyager_errors.log`. The UI looked fine afterwards.
- Notes: the Win32 call resizes the window from inside Dart code, and the engine began a frame inside that call. In release builds the asserts are off, so the effect there would be a frame running re-entrantly rather than an error. Six later attempts (T/F/J/R bursts at 0/50/100/200/300 ms gaps and 1.5 s gaps, from another app and in-app, 10× the same hotkey) produced no errors (`qa/steps/p5-spam.txt`, `p5-spam2.txt`).

### BUG-036 [Phase 5] Reminder editor opened in-app at a short window height clips the Title label and the "On" row
- Severity: Cosmetic
- Found: 2026-09-29, Phase 5
- Steps to reproduce: window at 2000×1100 physical (`place 200 100 2000 1100`), Dark + Scatter. Focus Voyager and press Ctrl+Alt+R (in-app path: "New reminder" over the current page).
- Expected: the form's floating "Title" label and the last row fully visible, or clearly scrollable.
- Actual: the dialog's content scrolls inside a viewport that cuts the top half of the "Title" label and half of the "On" row and its switch above Cancel/Create (`qa/shots/p5-a-r.png`, crop `p5-crop.png` at the time). The floater version (Ctrl+Alt+R from another app) shows both fully.
- Notes: same symptom as the Phase 4 lead "Rankings New category dialog: Name label clipped at its top at 2000×1100": a scrolling dialog body clips the first field's floating label. At the minimum window size (1440×1040) it's worse: the "On" row and its switch are scrolled out of view entirely, with no scroll cue (`qa/shots/p5-min-r.png`).

### BUG-037 [Phase 5] Enter on an empty (or spaces-only) quick to-do bar drops keyboard focus; what's typed next is lost
- Severity: Minor
- Found: 2026-09-29, Phase 5
- Steps to reproduce: another app focused, Ctrl+Alt+T. With the title field empty (or holding only spaces), press Enter, then type `abc`. Tried with Vim ON (Insert) and Vim OFF.
- Expected: nothing is created (the in-app create rules need a non-empty trimmed title) and the field keeps focus, so typing continues, as it does in the in-app To-Do composer (Enter on an empty composer, then `abc`: the composer shows `abc`, `qa/shots/p5-inapp-enter.png`).
- Actual: nothing is created and the floater stays open, but the title field loses focus (border goes grey, no caret; primary focus is the `_ModalScopeState` focus scope over the VM service). `abc` goes nowhere (`qa/shots/p5-t-ws2.png`, `p5-t-ws3.png`, `p5-t-sp2.png`, `p5-t-sp3.png`, `p5-vo-t-enter.png`). The user has to click the field.
- Notes: a quick-capture bar is used keyboard-only, so a stray Enter swallows the next words typed.

### BUG-038 [Phase 5] After signing in on a fresh local install, the journal hotkey starts a second quick entry for the same day (and the notepad no longer creates its entry on open)
- Severity: Minor
- Found: 2026-09-29, Phase 5
- Steps to reproduce: qa-007 has today's quick entry (`853c77b2…`, body "second qje…", created from the notepad). Cold re-login: `guard.ps1` OK, outbox 0, `reset.ps1 -Force`, `launch.ps1`, `login.ps1`. The pulled entry is in SQLite. With another app focused press Ctrl+Alt+J, type `after cold login`, click away. Then Ctrl+Alt+J with the main window focused.
- Expected: GLOBAL_HOTKEY_FLOATERS_HLD.md §2/§6.3: "At most one Quick Journal Entry per local calendar day"; the notepad and the in-app hotkey reuse that entry "unless the user deleted it"; §6.2: the QJE is created "on notepad open".
- Actual: the notepad opens empty ("Quick entry · today", `qa/shots/p5-cold-j.png`) and binds a new entry: `e5a1b919…` "after cold login" is created at 23:06 next to `853c77b2…` from 22:35, both Sep 29, both live. The in-app hotkey opens the new one (`p5-cold-inapp-j.png`, list "Journal 2"). Also, opening the notepad creates no row at all until something is typed (no `quick_journal_entry.json`, no new entry after the first open); the HLD's "create on open" is no longer what the app does.
- Notes: by design in the code: `quick_journal_entry.dart` says the day→entry pointer is "Device-local on purpose … so two devices never race to claim one day", and `findQuickJournalEntry` "only creates it once something is written". So the HLD is out of date on both points, and every wipe, reinstall, sign-out/in or second device splits a day's quick notes across entries. Logged as a mismatch; which one is right is Juno's call.

### BUG-039 [Phase 6] A one-time reminder set in the past is created switched on, listed as "Passed", and can never fire
- Severity: Minor
- Found: 2026-09-30, Phase 6
- Steps to reproduce: Inbox → Scheduled → "+". Title `past rule`, Repeats Once, time chip → today 12:00 AM (at 12:34 AM). The editor shows "That time has already passed" under the chip. Press Create.
- Expected: either Create is refused until the time is in the future, or the reminder is delivered at once (SCHEDULED_REMINDERS_HLD.md §3: "Missed / late open: Still show; carry until resolved"). A rule that can never fire shouldn't look armed.
- Actual: the rule is saved `enabled = 1` (`once_local_date` today, `local_time_minutes` 0, `armed_at` = the creation time), the Inbox row keeps the active bell icon and reads "Once · Sep 30, 12:00 AM · Passed", and nothing is ever delivered: no delivery state, no sticky, no OS toast, no history. `latestRuleOccurrence`/`nextRuleFire` (`lib/domain/services/reminder_schedule.dart`) drop any occurrence before `armedAt`, so a rule armed after its only occurrence has none. The hint text is the only warning. Phase 5 saw the same from the reminder floater ("Reminder added" toast, rules "past rem"/"past rem two" on qa-007 never fired).
- Notes: editing the time to a future one re-arms it and it fires (`past rule` → 12:38 AM fired on time). A typo in AM/PM, or a date left on today after the time has passed, silently yields a dead reminder. Screenshot `qa/shots/p6-past-created.png`.

### BUG-040 [Phase 6] Around a daylight-saving change the inbox calls tomorrow's task "Today" (important, pulsing dot) and yesterday's "Today" instead of overdue
- Severity: Minor
- Found: 2026-09-30, Phase 6 (by reasoning + evaluation in the running app; the clock wasn't moved)
- Steps to reproduce: timezone with DST (this PC: Eastern). On Sun Mar 14 2027 (clocks spring forward at 2:00 AM) have a task due Mon Mar 15 and open the Inbox. Separately, on Mon Mar 15 look at a task that was due Sun Mar 14.
- Expected: Mar 15 task: "Tomorrow", semi-important (muted dot). Mar 14 task viewed on Mar 15: "1d overdue".
- Actual: both compute a day count of 0. `evaluateTaskUrgency` (`lib/domain/models/notification_models.dart`) and `_dueLabel` (`notification_inbox_popover.dart`) take `DateTime(local midnight).difference(local midnight).inDays`, and the 23-hour day truncates to 0. Evaluated in the app isolate: `DateTime(2027,3,15).difference(DateTime(2027,3,14)).inDays` = 0 (fall-back Nov 1→2 2026 = 1); `DateTime(2027,3,14).difference(DateTime(2027,3,15)).inDays` = 0. So on that day the next day's task is "important" (accent pulsing rail dot, "needs attention") and labelled "Today", and yesterday's is labelled "Today" (in the error colour, since `_isOverdueItem` uses `isBefore`). Every later "in Nd" label across the change is one day short, and the dismissal key's tier (`<id>|important`) can differ from the real one.
- Notes: the finance code already fixed exactly this (`Subscription.daysUntilDue` comment: "differencing two local wall-clock midnights across a DST transition yields 23h or 25h … truncates a bill due tomorrow to 'Due today'", counted in UTC), and `reminder_labels.dart` uses UTC too. The task path and the feed label were missed.

### BUG-041 [Phase 6] Due reminder stickies draw over everything, including the Inbox and the reminder editor; at the minimum window size they hide the editor's Create button
- Severity: Minor
- Found: 2026-09-30, Phase 6
- Steps to reproduce: have two scheduled reminders due and unacknowledged (here "mass 22" and "offline fire"). Window at the minimum size (`place 0 0 1440 1040`, Dark + Scatter). Open the Inbox, then Scheduled → "+".
- Expected: SCHEDULED_REMINDERS_HLD.md §3/§5.3: the sticky is "a small sliver, not a full-screen modal"; "only the toast surface intercepts pointers; rest of the app remains usable". Popovers and dialogs the user opens on purpose should stay usable.
- Actual: the stack (two cards, about 720×390 logical) is painted above the Inbox popover and above modal dialogs. At the minimum size it covers the right half of the Inbox (the "rule daily B" row is cut through, `qa/shots/p6-min-inbox.png`), and in the "New reminder" editor it hides the On switch and the Cancel/Create buttons (`p6-min-editor.png`), so the form can't be submitted by mouse until the stickies are acknowledged or snoozed (Ctrl+Enter still creates it). On the To-Do page it covers the composer's Add button and the lower edit panel (`p6-min.png`). At maximized it sits over the Dev page's right-hand toggles and the Navigation pages dialog edge (`p6-navpages.png`), and with 3+ due the stack is ~590 logical px tall.
- Notes: nothing collapses or moves the stack; the only way to uncover what's under it is to act on each reminder. With 22 due the stack shows three cards plus "+19 more" (`p6-mass-fired.png`).

### BUG-042 [Phase 6] Light theme: the Inbox "Show N more" button is accent text on a mid-grey pill (contrast 1.2:1), and the sticky's Acknowledge loses its accent fill
- Severity: Cosmetic
- Found: 2026-09-30, Phase 6
- Steps to reproduce: more than four scheduled reminders. Settings → Appearance → Light. Open the Inbox; look at the button under the Scheduled rows. Have a reminder due and look at its sticky.
- Expected: legible text (WCAG 4.5:1 for body text); the sticky's primary action styled as primary, as in dark.
- Actual: "Show 23 more" is `#7c9eff` on a `#949291` pill: contrast 1.21:1, barely readable (`qa/shots/p6-light-inbox.png`, crop `p6-crop.png` at the time). The mouse wasn't over it. In dark the same button is accent text on a near-black pill and reads fine. On the stickies, Acknowledge is the filled accent button in dark but in light all three buttons are the same pale outline, so the primary action isn't distinguished.
- Notes: accent is the default `#7c9eff`.

### BUG-043 [Phase 6] After signing in on an empty device, scheduled reminders don't load until restart: due reminders never show or alert, the Inbox's Scheduled section is empty, and hidden items come back
- Severity: Major
- Found: 2026-09-30, Phase 6
- Steps to reproduce: qa-008 with 27 scheduled rules in its cloud copy, three of them due and unacknowledged ("mass 22" 1:28 AM, "offline fire" 1:34 AM, "min size rule" 2:00 AM), 2 pinned notes, and feed item "feed B" hidden. Cold re-login: `guard.ps1` OK, outbox 0, `reset.ps1 -Force`, `launch.ps1`, `login.ps1`. Wait 15 s, then 70 s more.
- Expected: after the startup pull, the three due reminders show as stickies (HLD §3 "Missed / late open: still show; carry until resolved"; §13 "opening the app always surfaces sticky toast(s) until ack/snooze"), the Inbox lists the rules, and "feed B" stays hidden (INBOX_HIDDEN_RESTORE_HLD: dismissals sync).
- Actual: SQLite has everything within 15 s (28 rules, 24 delivery states, 89 history rows, 2 bells, pinned notes, the live dismissal; row counts identical to before the wipe). But the app shows no stickies and raises no OS notification for 4+ minutes (no `stickyShown`/`osFired` rows from the new device id); the Inbox shows the Scheduled empty-state text "Daily, weekly or one-time reminders at a set time.", no pinned notes, and "feed B" back in the live feed with its urgency dot (`qa/shots/p6-relogin-inbox.png`, `p6-relogin-70s.png`). Adding a pinned note made the pinned list re-query and show all four notes, but Scheduled stayed empty and "feed B" stayed visible (`p6-relogin-write.png`). After `stop.ps1` → `launch.ps1` all of it appears at once: 3 stickies, 3 OS toasts, 27 rules, "feed B" under Hidden (1) (`p6-relogin-restart-inbox.png`).
- Notes: the reminder engine is fed from `scheduledReminderRulesProvider`, `reminderDeliveryStatesProvider` and friends (`reminder_engine.dart`); with an empty rules list it has nothing to deliver, so any reminder due in that session is silently missed until the app restarts, and the user sees an empty Scheduled list (and might re-create reminders, duplicating them). Same shape as BUG-010 (pulled journal entries invisible until restart). The to-do feed items did appear, so not every provider is affected.
- Notes (2026-09-30): same cause as BUG-010. The reminder providers are kept-alive `FutureProvider`s that read SQLite once, before the pull has written anything, and aren't among the four providers `lib/main.dart` invalidates after the startup pull. See BUG-010's notes.
- Notes (2026-09-30, fixed in the working tree, uncommitted, with BUG-010): the startup pull now refreshes every data provider, including `scheduledReminderRulesProvider`, `reminderDeliveryStatesProvider`, `entityRemindersProvider`, `pinnedNotesProvider` and `notificationDismissalsProvider`, so the reminder engine sees the pulled rules once the pull ends. To verify: TEST_PLAN.md "Fix verification" FV-2.

### BUG-044 [Phase 6] Every restore onto a wiped device re-uploads the backfilled collections, so the next launch pulls them all again
- Severity: Minor
- Found: 2026-09-30, after Phase 6 (seen by Juno on the real account: a restart after a full restore pulled another ~700 items; confirmed in the qa-008 logs)
- Steps to reproduce: account with data in the backfilled collections (calendars, calendar events, trackers, tracker values, finance, pinned notes, dismissed notifications, device registrations, reminders, bucket list, tag colors, custom/flagged words, snippets). `guard.ps1` → `reset.ps1 -Force` → `launch.ps1` → `login.ps1`. Wait for the startup pull, make no edits, then `stop.ps1` → `launch.ps1`. Compare the two `[sync] pullAll took …` lines.
- Expected: the second launch's incremental pull lists only what changed since the restore (about nothing).
- Actual: the second launch lists nearly the whole account again. qa-008: restore `qa/logs/run-20260930-020051.log` "158 docs from 60 collections, 60 pulled whole" (scheduled_reminder_rules 28, reminder_delivery_logs 89, dismissed_notifications 3, pinned_notes 3). Restart ~4 min later `run-20260930-020458.log` "160 docs from 60 collections, 0 pulled whole" (scheduled_reminder_rules 28, pinned_notes 4, dismissed_notifications 3, calendars 1). The session in between added one pinned note (BUG-043). Real account: ~700 extra items on the first restart after a restore.
- Notes: suspected cause, from the code. `RemoteSyncService.backfillSyncedCollections` runs at the end of every `pullAll` until `settings.syncBackfillVersion` reaches `syncBackfillVersion` (2). That column is device-local (`app_database.dart`, kept out of `settingsSyncPayload`), so a wiped device starts at 0 and `_backfillVersion1` plus the v2 snippet step `pushRecords` every row it has just pulled for those collections. Each push stamps `_serverWrittenAt` with the server's time (`FirestoreSyncRepository.stamped`), after the watermark the pull just stored, so the next incremental pull lists them all again. Journal entries, dream entries and to-do tasks aren't in the backfill; the logged lists fit that. Not verified: the `_serverWrittenAt` values in Firestore (reading the account's documents needs permission). Cost: a restore uploads a write per row in those collections, and the next launch downloads them all again. Scope, suspected: a push does no version comparison, so an edit another device makes between this device's pull and its backfill could be overwritten by the just-pulled copy.
- Notes (2026-09-30, verified in Firestore on the real account with read-only REST calls): every document in the backfilled collections has `_serverWrittenAt` within one 11-second window, 2026-09-30 06:32:29–06:32:40Z (the restore), in `_backfillVersion1`'s order: calendar_events 124 docs 06:32:29.1–30.3, tracker_values 135 docs 06:32:30.7–33.2, transactions 70, tag_colors 105, then custom_words 156 docs 06:32:38.4–39.8; scheduled_reminder_rules 15. Collections outside the backfill kept their older times: journal_entries' newest cluster is 2026-09-25/27, and to-do tasks only have 2 docs from 06:4x on 09-30 (real edits). So the cause above is confirmed: the backfill re-stamps the rows it has just pulled, and the next incremental pull lists them.
- Notes (2026-09-30, fixed in the working tree, uncommitted): a new database now starts with the backfill already done. `DriftSettingsRepository.getSettings` writes the first settings row (which only happens on a new database) with `syncBackfillVersion` = the current version, so `backfillSyncedCollections` returns at once. A database upgraded from an older build keeps its existing row and still runs the backfill. The version constant moved from `RemoteSyncService` to `FirestoreCollections.syncBackfillVersion` (the data layer can't import the sync service). The app has no signed-out mode, so a new database can't hold rows written before this device synced.
  - Tests (`test/secondary_collections_sync_test.dart`, group "backfill"): "a new database starts at the current version" and "a restore onto a new database uploads nothing back" (pulls a calendar onto a fresh device, runs the backfill, checks the server lists nothing written since). Both fail without the fix. The two existing backfill tests now start from an upgraded database (settings row at version 0). Full suite: 3,990 pass.
  - Not yet checked in the running app; see TEST_PLAN.md "Fix verification" FV-1.

<!-- Last ID: BUG-044. -->
