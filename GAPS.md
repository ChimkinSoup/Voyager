# Gaps Review (Desktop)

Missing elements and features. These aren't bugs: correctness issues already tracked
in `AUDIT.md` (Workout) are not repeated here.

Scope: every nav page except Dev, Demo and Android. Covers feature gaps, cross-cutting
UX, data safety and sync, and ship readiness.

Method: a code pass over models, repositories, pages and settings, then a live pass
on 2026-09-24. I ran a fresh debug build against your real database and navigated to
every page over the VM service, capturing frames (no synthetic input). The live pass
was read-only: I didn't start a workout or create or edit anything, so interactive
flows are covered only by the code pass. Findings from the live pass are under
**Seen in the live pass**.

Priority: **P1** = would surprise you in daily use or risks data; **P2** = clear gap
worth closing before "complete"; **P3** = nice-to-have, or a PLAN.md item that was
never built.

---

## P1

### ~~No trash, but 18 delete dialogs promise one~~
**Done (2026-09-25):** Settings → Trash lists everything deleted in the last 30 days,
with Restore, Delete forever and Empty trash; the Journal, To-Do, Calendar, Jobs and
Rankings manage sheets open it filtered to their page. See `TRASH_HLD.md`.

Delete confirmations say "This entry will be moved to trash." (journal, dreams, todo,
study, finance, bills, …), and PLAN.md asks for a 30-day recycle bin. The only
recovery path is the Undo toast, which lasts 8 s (`lib/core/soft_delete/soft_delete_toast.dart:16`).
After that the tombstone sits in SQLite with no UI to reach it. Either add a Trash
view (per-feature or global: list `deletedAt != null`, Restore / Delete forever), or
change the copy to "Deleted (Undo for 8 s)".

### ~~Todo tasks don't record when they were completed~~
**Done (2026-09-25):** tasks carry `completedAt` (stamped and cleared with `completed`),
and every tick, repeats and subtasks included, records a synced `todo_task_completions`
row (task, time, due date ticked). There's one row per task and due date, so an
un-tick takes it back and a re-tick brings it back, on any device. A task's
completions keep counting while it's in the trash, and go when it's deleted forever
or purged. It's recorded only for now, with no UI. Tasks completed before v128 have
no timestamp.

`TodoTasksTable` has `completed` but no `completedAt` (`lib/data/database/app_database.dart:178-202`),
and a recurring task re-arms without leaving any trace. That rules out a "completed
today/this week" count, completion history, a done list, and the "tasks completed"
statistic PLAN.md asks for in Analytics. Settings shows only a lifetime total. The
column is cheap to add now; the history lost before it exists can't be recovered.

### ~~Errors in a release build vanish~~
**Done (2026-09-25):** `lib/core/dev/error_logger.dart` writes every uncaught or
reported error, with its stack and build, to `Documents/voyager_errors.log` (Dev page
→ Error log), and key swallowed failures in sync, media, undo and session checkpoints
record there too.

The only `FlutterError.onError` hook is the keyboard workaround
(`lib/core/platform/windows_keyboard_workaround.dart:18`), and there is no
`PlatformDispatcher.instance.onError` or `runZonedGuarded`. In a release build with no
console, uncaught errors leave no record. Before the bug-hunting session, add a rolling
`Documents/voyager_errors.log`, or a Dev page view of recent errors. Otherwise the
session will surface symptoms without stack traces.

---

## P2: Cross-cutting

### ~~Can't hide nav pages~~
**Done (2026-09-25):** Settings → Navigation pages has an eye toggle per page (all but
Settings). Hidden pages leave the rail, Ctrl+Tab and the startup choices, keep their
place in the order, and sync like the order does. Dev starts hidden (the error log is
one toggle away). Demo isn't in release builds at all.

There are 16 destinations and "Reorder navigation pages" can't hide any. Dev and Demo
ship in every build with no `kReleaseMode` gate (`shell_destinations.dart:128,134`). For
you: hide pages you're not using this season (e.g. Jobs). For a second user: Dev and
Demo shouldn't be visible.

### ~~Inbox doesn't know about spaced repetition~~
**Done (2026-09-25):** the inbox shows a "Study · N cards due" and a "LeetCode · N
problems due" row whenever anything is due. They're counted the way the Study button
and the Review Deck count them. Clicking a row opens its page. Hiding one lasts until
tomorrow. They don't light the bell, and a page hidden from the rail gets no row.

The inbox covers `task`, `event` and `bill` only (`lib/domain/models/notification_models.dart:10`).
Due study cards and due LeetCode reviews never surface. Those are the SRS features
that most need a daily nudge. A "N cards due" row in the inbox, or a badge on the nav
icon, would cover it.

### ~~Dream entries can't hold images~~
**Done (2026-09-26):** dreams take images by paste and drop on the Dream Journal
page and in Search's dream popup. The fan sits just left of the sticky note. An image
dropped on a blank "New dream" saves it. Deleting a dream takes its images with it
into the trash, and Undo or Trash → Restore brings them back. The quick-journal
floater takes images for today's quick entry the same way.

Journal entries take images by paste and drop, shown as a fan stack
(`_withImages`, `journal_page.dart:3580` and `search_page.dart:1413`). Dream entries
don't: the dream editor has no `MediaPasteScope` / `MediaDropTarget` / `MediaFanStack`.
Neither does the quick-journal hotkey floater, so a screenshot can't be pasted there
either. Minor; the same three widgets would cover both.

---

## P2: Per feature

### Workout (explicitly tested)
The planner, live session and exercise detail work well together. Gaps:
- **No session history.** A finished session can't be seen as a whole, edited or
  deleted. Only per-exercise history exists (exercise detail sparkline and heatmap).
  A mis-logged set from last week can't be fixed.
- **Can't log a past workout.** Every start records today (by design, see AUDIT.md
  business rules), so a workout done without the app can't be backfilled.
- **Can't change the session while it's live.** The controller supports
  focus/update/complete/uncomplete/set count/drops
  (`workout_session_controller.dart:376-671`), but not adding an unplanned exercise,
  skipping one, or reordering.
- **Weight × reps only.** No timed sets (plank), distance/cardio, or "bodyweight +
  added weight". `WorkoutSetLog` has only `weightKg` and `reps`.
- **No notes or effort.** No session note, per-set note, or RPE/RIR. `WorkoutSession`
  has no free-text field.
- **No PRs.** Nothing flags a new best weight, reps-at-weight or estimated 1RM, and
  there's no progression suggestion (for example, "all sets hit target, so +2.5 lb
  next time").
- **Exactly two plans.** One weekly plan and one split (`workout_page.dart:133-139`).
  Switching programs means rebuilding the plan. That's fine for now; worth noting.
- **Sets prefill from the plan target, not from last time.** Showing "last: 185×8"
  beside each set is the most useful number mid-workout.

### Todo
- ~~No completion timestamp (P1 above).~~ Done; a "done this week" count or done
  list can now be built on the completion log.

### Analytics / trackers
- Tracker types are integer, boolean and enum (`lib/domain/models/enums.dart:1`).
  There's no **decimal/duration** type, so "hours slept = 7.5" can't be logged, though
  PLAN.md names hours slept and hours studied.
- No note per logged value (e.g. *why* energy was 3).

### Finance
- The ledger filters by tag only, with no text or amount search.

### Journal
- No export of a journal or entry range to Markdown or PDF. The only export is the full
  JSON backup.

### Study / LeetCode
- ~~No due count in the inbox (above).~~ Done.
- Study has no retention or forecast stats

### Settings
- ~~About has no version number (`settings_page.dart:639`), and `pubspec.yaml` is still
  `0.1.0+1`. You'll want the version in bug reports.~~ **Done (2026-09-25):** About
  shows version, commit and build date (tap to copy), set by
  `scripts/build_release.ps1`; backups record it too.
- The signed-in account isn't shown anywhere, only "Sign out".
- A "Statistics" block (total journals, tasks) sits inside Settings. It probably
  belongs in Analytics.
- It's one long scroll of ~15 sections. A section index or filter would help.

---

## P2: Ship readiness (desktop)

- **No launch-at-login.** Global hotkeys only work while Voyager is running (it closes
  to the tray, `lib/core/platform/desktop_window.dart:38`). After a reboot they're dead
  until you open the app by hand. Add a "Start with Windows" toggle (Run key or
  `launch_at_startup`) that starts hidden in the tray.
- **No installer or update path.** There's no MSIX or Inno config and no updater.
  Even for yourself, a repeatable release build plus installer beats copying
  `build/…/Release`.
- **Database lives in `Documents`** (`app_database.dart:4037`). Documents is often
  OneDrive-redirected on other people's machines, and cloud-syncing a live SQLite file
  corrupts it. `%APPDATA%\Voyager` is safer. It's fine on your machine today.
- **`dev_disable_cache = 1` on your live DB** skips the startup pull and live sync
  entirely. Turn it off before the bug-hunting session, or sync bugs will be invisible.

---

## Seen in the live pass

- **Search results have no date or journal.** Each hit shows title and snippet only,
  so there's no way to tell which day "Fun Day" was without opening it. Cheap fix,
  separate from the parked search-scope item.
- **The rail doesn't reveal the current page.** At the default window height the rail
  ends at LeetCode. Rankings, Jobs, Study and Workout sit below the fold, and when one
  is opened (Ctrl+Tab, a notification jump) the highlighted item stays scrolled out of
  view. Scroll the selected destination into view on change. Hiding unused pages would
  also help (see above).
- **Study's due count lives only on the Study page** ("Study 65 due"). This confirms the
  inbox gap above.
- **One small display bugs** (not gaps, noted in passing):
  - Analytics sparkline x-axis: the last label collides with its neighbour
    ("Sep 8" / "Sep 24" overprint at the right edge of the monthly tracker).
  - The Calendar month header reads "September" with no year, so a month view in

---

## P3: PLAN.md items not built
- **Timed surveys** (weekly, monthly or yearly question sets): nothing in the code.
- **Study timer / hours studied / productivity score**: Study became flashcards. There
  is no timer anywhere.
- **Life timeline of milestones** (line with achievements left and right): the life
  tree and bucket list replaced it. There's no way to record a milestone.
- **Account linking** (Google + email/password): listed under Future Additions.

---

## Suggested order before the bug hunt
1. ~~Error log (P1). It makes the bug hunt productive.~~ Done.
2. Turn off `dev_disable_cache`.
3. ~~`completedAt` on tasks (P1). Starts collecting history now.~~ Done.
4. ~~Trash view or honest delete copy (P1).~~ Done.
5. Launch at login, plus auto-backup with a pre-migration snapshot.
6. Then pick from P2 by taste. My pick: workout session history.
