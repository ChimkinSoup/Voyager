# Calendar Feature Audit

Scope: `lib/features/calendar/` (page, event panel, todo panel, grid, day grid,
week timeline, overlap engine, todo markers, day entries, list actions, keyboard
shortcuts), `lib/domain/models/calendar_models.dart`,
`lib/domain/services/calendar_recurrence.dart`,
`lib/domain/services/calendar_recurrence_editing.dart`,
`lib/domain/services/recurrence_engine.dart`, `DriftCalendarRepository`, and the
Calendar half of `firestore_document_mapper.dart`.

Findings are ordered by severity. Line numbers are against the working tree at
the time of the audit. **No finding below changes the year↔month or month↔week
morph choreography** — the two fixes that touch animated code
(`_CalendarInteractiveEventTapState`, the week-column layout) are a disposal call
and a date-math correction; neither alters a curve, a duration, or a frame
sequence.

---

## Critical

### [Critical] Every save of an existing event resets its `version` to 0, so the next sync pull silently reverts the edit
- **Location:** `lib/features/calendar/calendar_page.dart:559-582` (`_saveSidebarEvent`,
  the `final edited = CalendarEvent(...)` literal); read back at
  `lib/data/repositories/drift_repositories.dart:957-975` (`upsertEvent` writes
  `version: Value(event.version)` verbatim) and adjudicated at
  `lib/core/sync/firestore_document_mapper.dart:1573-1582`
  (`mergeCalendarEventFromRemote` → `_remoteRecordWins`)
- **Issue:** `_saveSidebarEvent` builds the row with the **`CalendarEvent`
  constructor**, not `copyWith`. `version` is not among the arguments it passes,
  so it falls back to `SoftDeletable`'s default of `0`
  (`lib/domain/models/soft_deletable.dart:8`). Every other write path in the
  feature goes through `copyWith`, which does `version: bumpVersion ? version + 1
  : version` (`calendar_models.dart:133`) — this one path is the exception.

  `upsertEvent` persists whatever the model carries, so after one edit the local
  row sits at version `0` forever, however many times it is saved. Conflict
  resolution is version-first:

  ```dart
  // firestore_document_mapper.dart:90-98
  if (remoteVersion != localVersion) return remoteVersion > localVersion;
  ```

  So any copy of that event on another device — or the copy this device itself
  pushed *before* the regression — sits at version `N > 0` and wins
  unconditionally on the next pull. The user's edit is overwritten with no
  conflict prompt and nothing on screen to explain it.

  Two things make this worse rather than a narrow race:
  1. `calendarEventToFirestore` (`:1551-1571`) ships `'version': event.version`,
     so the `0` is published, not just held locally.
  2. Because the local row can never climb past `0`, this device can never win a
     conflict on that event again. It is a one-way ratchet into "my calendar
     edits don't stick".

  The same literal also drops `deletedAt` — the constructor defaults it to `null`
  and nothing restores it, so editing an event that is sitting in trash silently
  un-deletes it.
- **Fix:** Build from the existing row so the version bump and every field the
  panel does not own survive. Keep the constructor only for the genuinely new
  case:

  ```dart
  final edited = event == null
      ? CalendarEvent(
          id: newId(),
          calendarId: result['calendarId'] as String? ??
              _selectedCalendarId ?? legacyCalendarId,
          title: result['title'] as String,
          start: result['start'] as DateTime,
          end: result['end'] as DateTime,
          isFullDay: result['isFullDay'] as bool,
          colorValue: result['colorValue'] as int,
          notes: result['notes'] as String,
          recurrence: result['recurrence'] as RecurrenceRule? ?? RecurrenceRule.none,
          createdAt: now,
          updatedAt: now,
        )
      : event.copyWith(          // bumps version; keeps deletedAt/source/externalId
          calendarId: result['calendarId'] as String?,
          title: result['title'] as String,
          start: result['start'] as DateTime,
          end: result['end'] as DateTime,
          isFullDay: result['isFullDay'] as bool,
          colorValue: result['colorValue'] as int,
          notes: result['notes'] as String,
          recurrence: result['recurrence'] as RecurrenceRule? ?? RecurrenceRule.none,
        );
  ```

  Note that `editRecurringEvent`'s two `CalendarEvent(...)` literals
  (`calendar_recurrence_editing.dart:120-135`, `:151-172`) are **correct as they
  stand** — those mint brand-new rows with fresh ids, for which version `0` is
  the right starting point.

### [Critical] Editing or deleting a task from the calendar leaves the stale task on screen — and on the todo page
- **Location:** `lib/features/calendar/calendar_page.dart:518-524`
  (`_showTodoPopup`'s `onSave`) and `:804-809` (`_deleteTodoTask`); provider
  contract at `lib/app/providers.dart:715-728`
- **Issue:** Both paths write the task and then invalidate exactly two providers:

  ```dart
  ref.invalidate(calendarTodoMarkersProvider);
  ref.invalidate(allTodoTasksProvider);
  ```

  `allTodoTasksProvider` does not query the repository. It is an aggregate over
  the per-list family, and the comment on it spells out the consequence:

  ```dart
  // providers.dart:715-728 — "invalidating this provider alone … no longer
  // forces a re-query of every list's tasks, only the ones whose own
  // todoTasksProvider(listId) was actually invalidated."
  all.addAll(await ref.watch(todoTasksProvider(list.id).future));
  ```

  `todoTasksProvider` calls `ref.keepAlive()`, so invalidating only the aggregate
  re-runs its body and reads the **cached** per-list value straight back. The
  repository is never touched. Verified with a `ProviderContainer` probe: after
  mutating the source and invalidating only the aggregate, the aggregate still
  returned the pre-edit list; invalidating the family member as well returned the
  new one.

  So retitling a task, moving it to another list, rescheduling it, ticking it
  complete, or deleting it from the calendar all write to SQLite and push to
  Firestore, and then the calendar keeps drawing the old marker — and the todo
  page, which reads the same family provider, keeps showing the old row — until
  something unrelated invalidates that list. `_TodoPageState` never re-reads on
  its own; it is preloaded and stays mounted, so a tab switch does not clear it
  either. The user's edit looks lost.

  `todo_page.dart` never makes this mistake: every one of its call sites pairs
  the two (`:663-664`, `:860-861`, `:909-911`, `:1467-1469`, `:1530-1538`).
- **Fix:** Invalidate the family member the write actually touched, in both
  paths, and cover the move-between-lists case:

  ```dart
  onSave: (updatedTask) async {
    if (Navigator.of(ctx).canPop()) Navigator.of(ctx).pop();
    await ref.read(todoRepositoryProvider).upsertTask(updatedTask);
    ref.read(remoteSyncServiceProvider).pushTodoTaskNow(updatedTask);
    ref.invalidate(todoTasksProvider(task.listId));            // source list
    if (updatedTask.listId != task.listId) {
      ref.invalidate(todoTasksProvider(updatedTask.listId));   // destination
    }
    ref.invalidate(allTodoTasksProvider);
    ref.invalidate(calendarTodoMarkersProvider);
  },
  ```

  and in `_deleteTodoTask`, after the upsert:

  ```dart
  ref.invalidate(todoTasksProvider(deleted.listId));
  ref.invalidate(allTodoTasksProvider);
  ref.invalidate(calendarTodoMarkersProvider);
  ```

---

## High

### [High] Every occurrence of a recurring timed event after the first renders as an 18 px stub in week view
- **Location:** `lib/features/calendar/calendar_overlap_engine.dart:46-58`
  (`_eventEndMinutes`), consumed at `:74-81` and `:196-202`
- **Issue:** `_eventEndMinutes` clamps the event's own absolute `start`/`end`
  against the day being laid out:

  ```dart
  final effectiveStart = localStart.isBefore(dayStart) ? dayStart : localStart;
  final effectiveEnd   = localEnd.isAfter(dayEnd)     ? dayEnd   : localEnd;
  if (!effectiveEnd.isAfter(effectiveStart)) {
    return _minutesFromMidnight(effectiveStart) + 30;
  }
  ```

  For a **recurring** event the stored `start`/`end` are the *anchor's* instants,
  not the occurrence's. On any later occurrence day `localStart` is before
  `dayStart`, so `effectiveStart` collapses to midnight; `localEnd` is before
  that again, so the guard fires and the function returns `30`. Meanwhile
  `startMinutes` is taken from the raw `event.start` (`:77`) and is correct. The
  slot therefore has `startMinutes = 600`, `endMinutes = 30` — an inverted
  interval.

  Two visible consequences:
  1. `height: max(taskBarHeight, (endMinutes - startMinutes) / 60 * pxPerHour)`
     (`:199-202`) resolves to `taskBarHeight`. A weekly 2-hour meeting draws
     120 px on the week it was created and **18 px every week after**.
  2. `_itemsOverlap` (`:107-108`) is `a.start < b.end && b.start < a.end`. With
     an inverted interval that is essentially never true, so a recurring event
     never joins a cluster: it always claims the full column width and is drawn
     straight over whatever it actually collides with.

  Confirmed by probe against `layoutDayColumn` — a weekly 10:00→12:00 event
  measured `top=600.0 h=120.0` on its anchor day and `top=600.0 h=18.0` seven
  days later.
- **Fix:** Resolve the occurrence onto the day being laid out before measuring.
  The existing helper already answers that question:

  ```dart
  double _eventEndMinutes(CalendarEvent event, DateTime day) {
    final occurrenceStart = calendarOccurrenceStartOn(event, day);
    if (occurrenceStart == null) {
      return _minutesFromMidnight(event.start.toLocal()) + 30;
    }
    // Shift the anchor's instants onto the occurrence that covers [day].
    final shift = epochDay(occurrenceStart) -
        epochDay(DateUtils.dateOnly(event.start.toLocal()));
    final localStart = addDays(event.start.toLocal(), shift);
    final localEnd   = addDays(event.end.toLocal(),   shift);
    final dayStart = DateTime(day.year, day.month, day.day);
    final dayEnd   = addDays(dayStart, 1);
    final effectiveStart = localStart.isBefore(dayStart) ? dayStart : localStart;
    final effectiveEnd   = localEnd.isAfter(dayEnd)     ? dayEnd   : localEnd;
    if (!effectiveEnd.isAfter(effectiveStart)) {
      return _minutesFromMidnight(effectiveStart) + 30;
    }
    return _minutesFromMidnight(effectiveEnd);
  }
  ```

  `addDays` rather than `add(Duration(days:))`, for the reason
  `recurrence_engine.dart:28-35` documents. This is a pure arithmetic fix inside
  the layout function — the week timeline's entry fade and the month↔week morph
  read the resulting `CalendarOverlapSlot` list unchanged.

### [High] Tapping a week-view time slot creates an all-day event, discarding the slot the user picked
- **Location:** `lib/features/calendar/calendar_week_timeline.dart:396-424`
  (`_handleBackgroundTap`) → `lib/features/calendar/calendar_page.dart:532-534`
  (`_openWeekSlotSidebar`) → `lib/features/calendar/calendar_event_panel.dart:154`
- **Issue:** `_handleBackgroundTap` converts the tap's y into minutes, rounds to
  the nearest half hour, clamps it into the day, and hands the exact `DateTime`
  through as `onSlotTap(day, time)`. `_openWeekSlotSidebar` forwards it as
  `_openEventSidebar(day: time)`, and the panel seeds `_start` from it correctly
  (`calendar_event_panel.dart:155-162`).

  Then `initState` runs `_isFullDay = e?.isFullDay ?? true;` — unconditionally
  `true` for a new event, whatever entry point opened it. Saving produces an
  all-day row, which `calendarWeekAllDayShelfEvent`
  (`calendar_todo_markers.dart:96-100`) routes to the pinned shelf. The user taps
  2:30 PM on Wednesday and gets a banner across the top of the day.

  The whole rounding block in `_handleBackgroundTap` — including the
  `roundedMinutes >= 24 * 60` guard — is unreachable in its effect: nothing
  downstream can observe the time it computed.
- **Fix:** Let the caller state the intent rather than having the panel guess.
  Thread a flag through `_openEventSidebar`:

  ```dart
  // calendar_page.dart
  void _openWeekSlotSidebar(DateTime day, DateTime time) {
    _openEventSidebar(day: time, timedByDefault: true);
  }
  ```

  pass it into `CalendarEventPanel` as `initialIsFullDay`, and seed from it:

  ```dart
  // calendar_event_panel.dart:154, and the matching line at :196
  _isFullDay = e?.isFullDay ?? widget.initialIsFullDay;
  ```

  with `initialIsFullDay` defaulting to `true`, so every existing call site — the
  month day-cell tap, the toolbar button, `_revealCalendarEvent` — keeps its
  current behaviour.

### [High] Dismissing an event popup rewrites and re-pushes the event even when nothing was edited
- **Location:** `lib/features/calendar/calendar_page.dart:587-595`
  (`_saveSidebarEvent`'s single-row branch), with the guard that exists only for
  the recurring branch at `:598-602`; triggered from
  `lib/features/calendar/calendar_event_panel.dart:245-254` (`_handleDismissPop`)
- **Issue:** Clicking outside the popup is a save by design — `_handleDismissPop`
  calls `_trySave(showValidationErrors: false)`. For a **repeating** event the
  page then guards against a no-op:

  ```dart
  if (!_eventContentChanged(occurrenceView(event, occurrenceDay), edited)) {
    if (mounted) _resetSidebar();
    return;
  }
  ```

  The single-row branch above it has no such guard. It runs
  `await repo.upsertEvent(edited)` unconditionally, so merely **opening an event
  to look at it and clicking away** produces:
  - a full-row SQLite write,
  - a `_syncedWrites.notifyOne(FirestoreCollections.calendarEvents, ...)`
    (`drift_repositories.dart:984-986`) — i.e. a Firestore push,
  - a fresh `updatedAt`, so the row jumps to the top of any recency ordering,
  - and, until the Critical above is fixed, a `version` reset.

  On a page where the popup opens on every event tap, that is a write and a
  network round trip per glance, and it manufactures sync conflicts out of
  read-only interactions.
- **Fix:** Move the existing guard above the branch so it covers both shapes:

  ```dart
  if (event != null &&
      !_eventContentChanged(
        occurrenceDay == null ? event : occurrenceView(event, occurrenceDay),
        edited,
      )) {
    if (mounted) _resetSidebar();
    return;
  }

  if (event == null || !event.recurrence.repeats ||
      event.isRecurrenceOverride || occurrenceDay == null) {
    await repo.upsertEvent(edited);
    ...
  }
  ```

### [High] Rescheduling a task from the calendar leaves a repeating task's anchor stale and its list order wrong
- **Location:** `lib/features/calendar/calendar_todo_panel.dart:155-177`
  (`_trySave`), consumed at `lib/features/calendar/calendar_page.dart:518-524`;
  contrast the policy in `lib/domain/services/recurrence_engine.dart:279-285`
  (`rescheduledRecurrenceAnchor`), applied at
  `lib/features/todo/todo_edit_panel.dart:409-428`
- **Issue:** `_trySave` writes `widget.task.copyWith(..., dueDate: _dueDate,
  clearDueDate: _dueDate == null)` and nothing else. Two invariants the todo
  feature maintains are skipped:

  1. **Recurrence anchor.** The documented rule is that the anchor is frozen when
     the repeat is set and *only moves when the user reschedules by hand*
     (`recurrence_engine.dart:266-278`). A calendar reschedule is exactly that,
     but `recurrenceAnchor` is left untouched, so a "monthly on the 3rd" task
     dragged to the 20th from the calendar still rolls forward to the **3rd**.
     Clearing the due date leaves a stale anchor behind, which silently revives
     the old pattern the next time any date is set — the failure mode
     `rescheduledRecurrenceAnchor`'s doc comment exists to prevent.
  2. **Placement.** `sortOrder` is per-list and is only kept chronological within
     the dated run by `buildUnstarredOrderForDueDate` at insertion time. Writing
     `dueDate` without running `applyDueDateChange` parks the task at its old
     position in the todo list. `unstarredSectionNeedsNormalize` only checks that
     dated tasks precede undated ones, so `_maybeNormalizeListSort` will not
     repair it either.

  Moving the task to a different list (`listId: _listId`) has the same problem
  from the other side: it arrives in the destination carrying the source list's
  numbering.
- **Fix:** Route the calendar's save through the same helpers the todo feature
  uses, in `_showTodoPopup`'s `onSave` rather than in the panel (the panel should
  keep reporting intent, not owning placement):

  ```dart
  onSave: (updatedTask) async {
    if (Navigator.of(ctx).canPop()) Navigator.of(ctx).pop();
    final repo = ref.read(todoRepositoryProvider);
    var next = updatedTask;
    if (next.dueDate != task.dueDate) {
      next = next.copyWith(
        recurrenceAnchor: rescheduledRecurrenceAnchor(
          rule: next.recurrence, newDue: next.dueDate),
        clearRecurrenceAnchor: next.dueDate == null,
      );
    }
    final active = activeTopLevelTasks(await repo.listTasks(next.listId));
    final batch = applyDueDateChange(next, active,
        dueDate: next.dueDate, clearDueDate: next.dueDate == null);
    await repo.upsertTasksBatch(batch.tasks);
    await ref.read(remoteSyncServiceProvider).pushTodoTasksBatch(batch.tasks);
    // …plus the family invalidation from the Critical finding above.
  },
  ```

---

## Medium

### [Medium] `calendarPackWeekEvents` re-normalizes every event on every membership test — the month view's hot path
- **Location:** `lib/features/calendar/calendar_day_grid.dart:88-136`
  (`calendarPackWeekEvents`), called at `:2620` (full month layout),
  `lib/features/calendar/calendar_page.dart:3220` and `:3916` (both morph
  layers), and `lib/features/calendar/calendar_todo_markers.dart:120`
- **Issue:** `calendar_recurrence.dart:55-63` exists precisely to hoist this
  work: `normalizeCalendarEvents` pre-computes each event's local date-only
  start/end and its exception set once, and
  `calendarEventOccursOnDayNormalized` reads those instead of recomputing.
  `MonthDayGrid.build` uses it — but **only on the compact (year-tile) branch**
  (`calendar_day_grid.dart:2600-2615`). The full month branch falls through to
  `calendarPackWeekEvents`, which calls the un-normalized
  `calendarEventOccursOnDay` throughout; every one of those calls allocates a
  fresh `NormalizedCalendarEvent` — a `toLocal()`, two `DateUtils.dateOnly()`
  calls, and a `Set<int>` built from the parsed exception list — before doing any
  work.

  The call count is not small. Per week row, for `E` events: 7·E in the
  membership filter, then for each event ≥7 per attempted row in the
  `while (true)` packing loop plus 7 more in the placement loop — ≥21·E
  normalizations per row, ~126·E per month-view build. During a month↔week morph
  `_buildInactiveMonthRows` builds a second full `MonthDayGrid` (another 6 rows)
  alongside the live one, and `_MonthWeekMorphLayer.initState` adds one more.

  For weekly rules each of those also runs `latestOccurrenceOnOrBefore`'s bounded
  backward scan (`recurrence_engine.dart:141-147`), up to `7·interval + 7`
  iterations.
- **Fix:** Normalize once at the top and index a membership matrix. The
  signature can stay as it is:

  ```dart
  List<List<CalendarEvent?>> calendarPackWeekEvents(
    List<DateTime> weekDates,
    List<CalendarEvent> allEvents,
  ) {
    final localDays = [for (final d in weekDates) DateUtils.dateOnly(d.toLocal())];
    final onDay = <String, List<bool>>{};
    final weekEvents = <CalendarEvent>[];
    for (final n in normalizeCalendarEvents(allEvents)) {
      final row = [
        for (final day in localDays) calendarEventOccursOnDayNormalized(n, day),
      ];
      if (row.contains(true)) {
        onDay[n.event.id] = row;
        weekEvents.add(n.event);
      }
    }
    // …sort and pack exactly as today, replacing every
    // `calendarEventOccursOnDay(event, weekDates[c])` with `onDay[event.id]![c]`.
  }
  ```

  Output and geometry are identical, so the morph layers that call it from
  `initState` are unaffected.

### [Medium] A multi-day event's caps and title are wrong on every occurrence after the first
- **Location:** `lib/features/calendar/calendar_todo_markers.dart:501-514`
  (`CalendarWeekEventBlock.build`)
- **Issue:** The block decides which end caps to round and where to draw the
  title by comparing the day it is rendering against the event's **anchor**
  dates:

  ```dart
  final startDay = DateUtils.dateOnly(event.start.toLocal());
  final endDay   = DateUtils.dateOnly(event.end.toLocal());
  final currentDay = DateUtils.dateOnly(day!);
  final totalDays = endDay.difference(startDay).inDays + 1;
  if (totalDays > 1) {
    isStart = currentDay.isAtSameMomentAs(startDay);
    final isEnd = currentDay.isAtSameMomentAs(endDay);
    bridgeLeft  = !isStart && !isFirstColumn;
    bridgeRight = !isEnd   && !isLastColumn;
  }
  ```

  For a repeating multi-day event, `currentDay` never equals `startDay` or
  `endDay` on any occurrence past the first, so `bridgeLeft` and `bridgeRight`
  are both true for every interior column. The bar renders with square caps on
  both ends as if it continued past the visible week, and
  `showText = !bridgeLeft` (`:531`) is false in every column — **the event's
  title never appears** on any occurrence after the first.

  Separately, `endDay.difference(startDay).inDays` is the DST-unsafe form the
  codebase documents against in `calendar_days.dart:1-18` and
  `recurrence_engine.dart:19-26`: across a fall-back transition a genuinely
  3-day event measures 2, so `totalDays > 1` can even collapse a 2-day event to
  a single-day block.
- **Fix:** Resolve the occurrence that covers `day`, and use `epochDay` for the
  span:

  ```dart
  if (day != null) {
    final occurrenceStart = calendarOccurrenceStartOn(event, day!);
    if (occurrenceStart != null) {
      final span = epochDay(DateUtils.dateOnly(event.end.toLocal())) -
                   epochDay(DateUtils.dateOnly(event.start.toLocal()));
      final currentDay = DateUtils.dateOnly(day!);
      if (span > 0) {
        isStart = currentDay == occurrenceStart;
        final isEnd = currentDay == addDays(occurrenceStart, span);
        bridgeLeft  = !isStart && !isFirstColumn;
        bridgeRight = !isEnd   && !isLastColumn;
      }
    }
  }
  ```

  `calendarEventBarsBridge` (`calendar_recurrence.dart:145-163`) already answers
  this correctly for the month view; this is the week view's copy having drifted
  from it.

### [Medium] Moving a series with "all events" leaves its deleted occurrences behind on the old dates
- **Location:** `lib/domain/services/calendar_recurrence_editing.dart:215-235`
  (`rebaseToAnchor`), reached from
  `lib/features/calendar/calendar_page.dart:616-618`
- **Issue:** `rebaseToAnchor` shifts `start` and `end` by the number of days the
  user moved the occurrence, so the whole series slides. It does not touch
  `exceptionDates`, and `editRecurringEvent`'s `allEvents` branch (`:114-115`)
  upserts `edited` — which `_saveSidebarEvent` populated with
  `exceptionDates: event?.exceptionDates` (`calendar_page.dart:574`), i.e. the
  master's originals.

  An exception identifies an occurrence in the pattern ("the one on Mar 14"), so
  once the pattern moves by N days the stored dates no longer land on any
  occurrence. `_coveringOccurrenceStart` (`calendar_recurrence.dart:97-104`) then
  matches none of them and every previously-deleted occurrence **reappears**.
  Detached override rows are worse: their `recurrenceDate` still points at the
  old date, so they orphan — the master no longer excludes that day, and both the
  series occurrence and the override render on top of each other.
- **Fix:** Shift the exception dates and the child overrides by the same delta.
  In `rebaseToAnchor`:

  ```dart
  final shift = epochDay(editedStart) - epochDay(occurrence);
  ...
  return edited.copyWith(
    start: _onDateKeepingTime(newStartDate, edited.start),
    end: _onDateKeepingTime(addDays(newStartDate, span), edited.end),
    exceptionDates: [
      for (final d in edited.exceptionDates)
        addDays(DateUtils.dateOnly(d.toLocal()), shift),
    ],
    bumpVersion: false,
  );
  ```

  and, in `_saveSidebarEvent`'s `allEvents` path, re-point the overrides before
  writing (they are reachable the same way `_orphanedOverrideIds` finds them):

  ```dart
  for (final child in await _overridesOf(event)) {
    final d = child.recurrenceDate;
    if (d == null) continue;
    await repo.upsertEvent(child.copyWith(
      recurrenceDate: addDays(DateUtils.dateOnly(d.toLocal()), shift),
      start: addDays(child.start.toLocal(), shift),
      end:   addDays(child.end.toLocal(),   shift),
    ));
  }
  ```

### [Medium] The date pill can persist an event whose end precedes its start
- **Location:** `lib/features/calendar/calendar_event_panel.dart:551-573`
  (the `DateSelectorPopover` result handler)
- **Issue:** The handler reassembles both endpoints by pinning the picked dates
  to the *existing* wall-clock times:

  ```dart
  _start = DateTime(dateRange.start.year, …, _start.hour, _start.minute);
  _end   = DateTime(dateRange.end.year,   …, _end.hour,   _end.minute);
  ```

  That is correct while the range stays multi-day, but collapsing a multi-day
  event to a single day carries both times onto the same date with no ordering
  check. An event running `Mar 1 14:00 → Mar 3 09:00`, re-pointed at `Mar 5`,
  becomes `Mar 5 14:00 → Mar 5 09:00`.

  Nothing downstream rejects it. `_trySave` validates only the title
  (`:238-245`). `TimeRangePopover` does keep end > start
  (`time_selector_popovers.dart:211-215`), so this is the one route that produces
  the inversion — and the panel then displays "2:00 PM → 9:00 AM", which is what
  the user sees and saves. The row is written and pushed to Firestore in that
  state. The week column degrades gracefully (`_eventEndMinutes` returns
  `start + 30`), so this shows up as a wrong label and a wrong-length bar rather
  than a crash, which is why it survives.
- **Fix:** Re-derive the end from the start when the range collapses, preserving
  the event's duration:

  ```dart
  if (dateRange != null) {
    setState(() {
      final duration = _end.difference(_start);
      _start = DateTime(dateRange.start.year, dateRange.start.month,
          dateRange.start.day, _start.hour, _start.minute);
      var end = DateTime(dateRange.end.year, dateRange.end.month,
          dateRange.end.day, _end.hour, _end.minute);
      if (!end.isAfter(_start)) {
        end = _start.add(
            duration > Duration.zero ? duration : const Duration(hours: 1));
      }
      _end = end;
    });
  }
  ```

### [Medium] `_orphanedOverrideIds` misses any override the user moved to another calendar
- **Location:** `lib/features/calendar/calendar_page.dart:773-790`
- **Issue:** The sweep that cleans up detached occurrences when a series is
  deleted scopes its query to the master's calendar:

  ```dart
  final all = await ref.read(calendarRepositoryProvider)
      .listEvents(calendarId: master.calendarId);
  ```

  But an override row is minted with `calendarId: edited.calendarId`
  (`calendar_recurrence_editing.dart:124`) — the calendar the user picked in the
  panel's corner flag while editing that one occurrence. Moving a single
  occurrence to a different calendar is a supported action, and it takes the row
  out of this query's reach.

  Deleting the series then leaves that override behind as a stray one-off event
  with a `recurrenceParentId` pointing at a soft-deleted row. It renders forever
  with no series to explain it — exactly the failure the function's own doc
  comment says it exists to prevent.

  The same scoping breaks the reverse case: `reassignEventsCalendar` moving a
  calendar's events elsewhere silently splits a series from its overrides.
- **Fix:** Query across all calendars and filter on the parent link, which is the
  actual relationship:

  ```dart
  final all = await ref.read(calendarRepositoryProvider).listEvents();
  return [
    for (final candidate in all)
      if (candidate.recurrenceParentId == master.id &&
          (scope == RecurrenceEditScope.allEvents ||
              !(candidate.recurrenceDate ?? candidate.start).isBefore(occurrence)))
        candidate.id,
  ];
  ```

### [Medium] `_handleTap` can leave an event bar permanently untappable
- **Location:** `lib/features/calendar/calendar_day_grid.dart:1686-1706`
- **Issue:** The press animation gates re-entry on `_isTapping` and only clears
  it after awaiting the controller:

  ```dart
  if (widget.onTap == null || _isTapping) return;
  _isTapping = true;
  ...
  await _controller.forward(from: 0);
  if (!mounted) return;
  _isTapping = false;
  widget.onTap!();
  ```

  `AnimationController.forward()` returns a `TickerFuture` that completes when
  the animation *finishes*. If the controller is stopped or restarted before
  then, that future never completes — it does not throw, it simply never
  resolves. The `await` therefore hangs, `_isTapping` stays `true` for the life
  of the `State`, and `widget.onTap!()` is never called: the bar keeps painting
  and keeps swallowing taps.

  The 140 ms window is short but the controller is genuinely restartable —
  `_onTapStateChanged` (`:1678-1684`) calls `forward(from: 0)` on every segment
  whose `eventId` matches the broadcast, and its `_isTapping` guard only protects
  the segment that *initiated* the tap. Tapping segment A of a multi-day bar and
  then, inside the same 140 ms, tapping segment B leaves A's future dangling.

  Two smaller issues on the same path: the tap's side effect (opening the popup)
  is delayed a full animation length behind the press, and `_isTapping` is never
  reset on the `!mounted` early return.
- **Fix:** Do not tie the callback's lifetime to the animation's. Fire the
  animation and release the latch on a delay that cannot be cancelled out from
  under it:

  ```dart
  Future<void> _handleTap() async {
    if (widget.onTap == null || _isTapping) return;
    _isTapping = true;
    if (widget.eventId != null && _tapState != null) {
      final box = context.findRenderObject() as RenderBox?;
      _tapState!.notifyEventTap(
        eventId: widget.eventId!,
        widgetRect: box != null ? box.localToGlobal(Offset.zero) & box.size : Rect.zero,
      );
    }
    unawaited(_controller.forward(from: 0));
    await Future<void>.delayed(_controller.duration ?? Duration.zero);
    if (!mounted) return;
    _isTapping = false;
    widget.onTap!();
  }
  ```

  The press animation itself is untouched — same controller, same curve, same
  duration; only the latch stops depending on the ticker future resolving.

### [Medium] `deleteCalendarList` reads `Theme.of(context)` after an await with no mounted check
- **Location:** `lib/features/calendar/calendar_list_actions.dart:152-167`, after
  the `await` at `:134`; caller at
  `lib/features/calendar/calendar_page.dart:998-1013`
- **Issue:** The `orElse` closure that fabricates a replacement default calendar
  calls `Theme.of(context).colorScheme.primary.toARGB32()` (`:159`). It runs
  after `await showDeleteContainerDialog(context, …)`, and neither
  `deleteCalendarList` nor its caller has a `context.mounted` guard across that
  gap. If the page went away while the dialog was up, this throws on a dead
  `BuildContext` — inside a `try` whose `catch` reports the error and returns
  `false`, so the calendar is left undeleted and its events half-reassigned.

  `_handleCalendarManage` has the same gap one level up: it awaits
  `listEvents(calendarId: …)` at `:1000-1002` and then passes `context` into the
  dialog with no check.

  `reassignEventsCalendar` (`drift_repositories.dart:906-917`) also passes
  `includeDeleted: true`, so soft-deleted events are dragged into the default
  calendar along with the live ones.
- **Fix:** Hoist the colour out of the async gap and guard after each await:

  ```dart
  // calendar_list_actions.dart
  final fallbackColor = Theme.of(context).colorScheme.primary.toARGB32();
  final choice = await showDeleteContainerDialog(context, …);
  if (!context.mounted || choice == DeleteContainerChoice.cancel) return false;
  // …use fallbackColor inside orElse
  ```

  ```dart
  // calendar_page.dart:1000
  final eventsForCalendar = await ref.read(calendarRepositoryProvider)
      .listEvents(calendarId: calendarId);
  if (!mounted) return;
  ```

---

## Low

### [Low] The `CurvedAnimation` built in `didChangeDependencies` is never disposed
- **Location:** `lib/features/calendar/calendar_day_grid.dart:1657-1664`;
  `dispose()` at `:1668-1673` disposes only `_controller`
- **Issue:** `_CalendarInteractiveEventTapState` builds a `CurvedAnimation`
  parented to `_controller` once motion settings are readable, and drives
  `_scale` from it. `dispose()` never calls `_curved.dispose()`, so Flutter's
  animation leak tracking flags one leaked `CurvedAnimation` **per event bar** —
  and the month view can hold dozens, recreated on every navigation to a new
  month.
- **Fix:** Hold a reference and dispose it. This does not change the animation:

  ```dart
  CurvedAnimation? _curved;
  ...
  _curved?.dispose();
  _curved = CurvedAnimation(
    parent: _controller,
    curve: reduced ? Curves.linear : VoyagerSpring.snappyCurve,
  );
  _scale = TweenSequence<double>([...]).animate(_curved!);
  ...
  @override
  void dispose() {
    _tapState?.removeListener(_onTapStateChanged);
    _curved?.dispose();          // <-- add
    _controller.dispose();
    super.dispose();
  }
  ```

### [Low] The week→month fallback branch reads `_mode` after overwriting it
- **Location:** `lib/features/calendar/calendar_page.dart:1711-1718`
- **Issue:**

  ```dart
  _mode = next;
  if (next == CalendarViewMode.year) {
    _focused = DateTime(_focused.year, 1, 1);
  } else if (next == CalendarViewMode.month) {
    _focused = _mode == CalendarViewMode.week      // always false — _mode is now `next`
        ? _monthTargetForWeekReturn()
        : _monthTargetForYear(_focused.year);
  }
  ```

  `_mode` was assigned `next` on the line above, so inside the `next == month`
  branch `_mode == CalendarViewMode.week` can never hold. The week→month arm is
  dead and every switch resolves through `_monthTargetForYear`.
  `_monthTargetForWeekReturn` has the same `_mode` test internally (`:254-256`),
  so even if it were reached it would take its own fallback path.

  This branch is only reached when a morph is already in flight (the guarded
  handlers above it catch the normal case), and the two targets usually agree
  because `_shiftFocus` keeps `_lastViewedMonth` in step. They diverge when the
  focused week and `_lastViewedMonth` sit in different years — the switch then
  lands on January instead of the week's own month.
- **Fix:** Capture the previous mode before overwriting it:

  ```dart
  final previousMode = _mode;
  _mode = next;
  if (next == CalendarViewMode.year) {
    _focused = DateTime(_focused.year, 1, 1);
  } else if (next == CalendarViewMode.month) {
    _focused = previousMode == CalendarViewMode.week
        ? DateTime(_focused.year, _focused.month, 1)
        : _monthTargetForYear(_focused.year);
  }
  ```

### [Low] `calendarDateInWeek` counts eight days across a spring-forward
- **Location:** `lib/features/calendar/calendar_day_grid.dart:191-196`
- **Issue:**

  ```dart
  final end = start.add(const Duration(days: 7));
  return !day.isBefore(start) && day.isBefore(end);
  ```

  `Duration(days: 7)` is 168 absolute hours, which the file's own neighbours go
  out of their way to avoid (`monthGridDates` and `_weekStart` both use field
  arithmetic, and `recurrence_engine.dart:28-35` documents why). In a week
  containing a spring-forward the local day is 23 hours, so `end` lands at 01:00
  on the *eighth* day — and that eighth day's local midnight still satisfies
  `isBefore(end)`.

  The one caller is `_isOnCurrentPeriod` (`calendar_page.dart:826-829`), which
  gates the "This week" button. Twice a year the button stays disabled for a
  week after the user has already navigated away from the current one.
- **Fix:**

  ```dart
  final end = DateTime(start.year, start.month, start.day + 7);
  ```

### [Low] "Add event" from the toolbar lands on January 1 in year view
- **Location:** `lib/features/calendar/calendar_page.dart:2530-2540`, which
  passes `day: _focused`
- **Issue:** `_focused` is normalized per mode: the 1st of the month in month
  view, the week start in week view, and **January 1** in year view
  (`:1613-1628`, `:1747`, `:1959`). The toolbar's "Add event" button always seeds
  the panel from it, so pressing it while looking at 2026 opens a new event dated
  1 January 2026 with no indication that the date was chosen for the user.
- **Fix:** Fall back to today when it lies inside the focused period, which is
  what the user almost always means:

  ```dart
  DateTime _defaultNewEventDate() {
    final now = DateTime.now();
    return switch (_mode) {
      CalendarViewMode.year =>
        _focused.year == now.year ? DateUtils.dateOnly(now) : _focused,
      CalendarViewMode.month =>
        _focused.year == now.year && _focused.month == now.month
            ? DateUtils.dateOnly(now)
            : _focused,
      CalendarViewMode.week => _focused,
    };
  }
  ```

### [Low] `Enter` inside an open sub-popover pops the sub-popover but latches the panel as "saved"
- **Location:** `lib/features/calendar/calendar_event_panel.dart:238-254`, with
  the popup's `onSave` at `lib/features/calendar/calendar_page.dart:544-548`
- **Issue:** `EnterToSubmitScope` wraps the whole panel, so pressing Enter while
  the date, time, or repeat popover is open still runs `_submit()` →
  `_trySave()` → `_closingAfterSave = true` → `widget.onSave(...)`. `onSave`
  calls `Navigator.of(ctx).pop()`, which pops the **topmost** route — the
  sub-popover — not the event panel.

  The panel stays open with `_closingAfterSave` stuck at `true`. Every later
  dismissal then takes the `_intentionalDiscard || _closingAfterSave` branch at
  `:246-249` and pops without saving, so any edit the user makes after that point
  is silently discarded when they click away.
- **Fix:** Suppress submit while a sub-popover owns the top of the stack:

  ```dart
  void _submit() {
    if (_isDatePopoverOpen || _isTimePopoverOpen || _isRepeatPopoverOpen) return;
    _trySave();
  }
  ```

### [Low] A detached occurrence can be given its own repeat rule
- **Location:** `lib/features/calendar/calendar_page.dart:587-595` (the
  `event.isRecurrenceOverride` short-circuit) with the always-visible
  `RepeatIconButton` at `lib/features/calendar/calendar_event_panel.dart:631-639`
- **Issue:** A "this event only" edit produces a row carrying
  `recurrenceParentId` and `recurrenceDate`. The panel still shows the repeat
  control for it, and `_saveSidebarEvent` writes overrides through the no-prompt
  single-row branch, so the rule is persisted. The result is a row that is
  simultaneously one detached occurrence of series A and a series of its own — it
  renders on many days, none of which series A's `exceptionDates` cover, and
  deleting series A with "all events" takes the whole second series down with it
  via `_orphanedOverrideIds`.
- **Fix:** Hide the control for a detached row, which is what the model already
  says it is (`calendar_recurrence_editing.dart:118-119`: *"it is one occurrence
  now, not a series of its own"*):

  ```dart
  if (widget.event?.isRecurrenceOverride != true)
    Builder(builder: (buttonContext) => RepeatIconButton(...)),
  ```

---

## Notes (not bugs)

- **`DayHourGrid` is unreachable.** `_dayViewDate` (`calendar_page.dart:51`) is
  only ever assigned a non-null value from `_goToToday` (`:856-857`),
  `_shiftFocus` (`:1050-1053`) and `DayHourGrid.onDayChanged` (`:2122-2125`) —
  all three of which require it to already be non-null. Nothing sets it from
  null, so the day view at `calendar_grid.dart:246-350` never renders and the
  `_dayViewDate != null` arms threaded through ~15 sites on the page are dead.
  Two latent bugs live in there and would surface the moment an entry point is
  added: the hour-slot filter (`calendar_grid.dart:317-323`) matches on
  `event.start`'s absolute date, so recurring timed events would be invisible in
  every hour row; and the prev/next day buttons use
  `add`/`subtract(Duration(days: 1))` (`:280`, `:294`), which skips or repeats a
  day across a DST transition. Flagging, not deleting — the intent to reach it
  may still be live.
- **`CalendarTodoMarker.completed` is always false.**
  `buildCalendarTodoMarkers` skips completed tasks entirely
  (`calendar_todo_markers.dart:184`), so the field, the `marker.completed` guard
  in `calendarTodoOnDay` (`:205`), and the line-through / reduced-alpha styling
  in `CalendarDayTodoBar` (`:288-291`, `:322-324`) and `CalendarWeekTaskBar`
  (`:392`, `:435-438`) are unreachable. Either surface completed tasks on the
  calendar or drop the field — currently it is paid for and never seen.
- **The morph machinery is sound.** The `_prepareMorphSession` /
  `_prepareWeekMorphSession` generation counters correctly invalidate in-flight
  post-frame callbacks and status listeners; both controllers, the week scroll
  controller and `_eventTapState` are disposed; `_MorphAnimationLayer` and
  `_MonthWeekMorphLayer` build their cell children once in `initState` and pass
  the expensive subtrees as `AnimatedBuilder`'s `child`, so nothing heavy is
  rebuilt per frame; `_MorphProgress` hoists `Theme.of` and colour allocation out
  of the 42-cell loop. No finding above touches any of it.
