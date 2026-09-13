# Job Tracker Audit

Scope: `lib/features/jobs/**`, `lib/domain/jobs/job_queries.dart`, `lib/domain/models/job_models.dart`, the `DriftJobRepository` (`lib/data/repositories/drift_repositories.dart`), the job providers in `lib/app/providers.dart`, and the job paths through sync (`remote_sync_service.dart`, `firestore_document_mapper.dart`, `outbox_sync_worker.dart`).

Decisions confirmed with the owner during the audit:
- Adding or renaming a stage to a name that already exists must be **rejected**.
- Whole-document last-writer-wins on applications counts as **data loss**. Concurrent field edits have to merge.

Evidence from a copy of the live DB (`~/Documents/voyager.sqlite`, 2026-09-13) is cited where it confirms a finding.

---

### [High] The open edit panel writes a stale copy over newer changes to the same application

- **Location:** `lib/features/jobs/jobs_edit_panel.dart:75`, `:88-101`, `:125-162`
- **Issue:** `_current` is set once in `initState` and only replaced when the panel switches to a *different* id (`didUpdateWidget` returns early when `oldWidget.application.id == widget.application.id`). Every later write is `_current.copyWith(...)`, a whole-document upsert. Anything that changes the open application without going through the panel is therefore reverted on the panel's next save:
  1. With the panel open on application X, change X's status from the table's status capsule or right-click menu (`jobs_page.dart:336-342`), or toggle a season from the row menu (`:378-384`). The DB now holds status B at version V+1. The panel still shows status A (`_statusPill` reads `_current`). The next keystroke in Notes commits `_current.copyWith(notes: …)`, which writes status A back at version V+1. The status change is silently lost, and the timeline records `A → B` while the row sits on A.
  2. A sync pull lands a remote edit to X (version V+1). The panel's next save also writes V+1, with a newer `updatedAt`, so under `remoteVersionWins` it beats the remote edit on every device.
  3. Another device deletes X. The pull removes X from `jobApplicationsProvider`, so `selected` becomes null and the panel unmounts. If a debounce was pending, the dispose flush (`:104-108`) upserts `_current` with `deletedAt: null` at the tombstone's version and a newer `updatedAt`, which resurrects X everywhere.
- **Fix:**
  1. Adopt newer data for the same id, without clobbering fields the user is typing in:
     ```dart
     @override
     void didUpdateWidget(JobsEditPanel oldWidget) {
       super.didUpdateWidget(oldWidget);
       if (oldWidget.application.id != widget.application.id) {
         // ... existing switch-application path ...
         return;
       }
       final incoming = widget.application;
       if (incoming.version <= _current.version &&
           !incoming.updatedAt.isAfter(_current.updatedAt)) {
         return; // our own save echoing back, or older
       }
       void adopt(TextEditingController c, String before, String after) {
         // Only overwrite a field the user has not diverged from.
         if (c.text == before && before != after) c.text = after;
       }
       adopt(_companyController, _current.company, incoming.company);
       adopt(_titleController, _current.title, incoming.title);
       adopt(_urlController, _current.applicationUrl ?? '', incoming.applicationUrl ?? '');
       adopt(_notesController, _current.notes ?? '', incoming.notes ?? '');
       _current = incoming;
     }
     ```
     Because `_save` sets `_current` to the version it wrote, the panel's own echo has an equal version and is ignored.
  2. Never let a save revive a tombstone. In `JobsActions.saveApplication` (`jobs_actions.dart:95`), read disk first and rebase the version:
     ```dart
     final onDisk = await _repository.getApplication(application.id);
     if (onDisk?.deletedAt != null) return; // deleted elsewhere; do not resurrect
     if (onDisk != null && onDisk.version >= application.version) {
       application = application.copyWith(version: onDisk.version + 1);
     }
     ```
  3. Once field-level merge lands (next finding), take the diff against `previous` so that only fields the panel actually changed are stamped.

---

### [High] Seeded stages and companies get random ids on every device, so they duplicate across devices and deletes don't reach the others

- **Location:** `lib/data/repositories/drift_repositories.dart:4589-4624` (`ensureSeeded`), `lib/app/providers.dart:1280-1283`
- **Issue:** Each device seeds 5 stages and ~150 companies with `newId()` and `recordLocalActivity: false`. Nothing pushes them, and nothing ties one device's "Applied" to another's.
  - On a second device, `jobSeedProvider` usually runs before the first pull, so it seeds its own 5 stages. When device A later pushes any stage (a rename, a colour, or a reorder, since `pushJobStagesBatch` sends every moved stage), B pulls it under A's id. B then has two "Applied" or "Interview" stages, and the header double-counts them (see the duplicate-name finding).
  - If B's first pull does land first, `stageRows.isEmpty` is false. B then gets only the stages A happened to have pushed, which can be a single renamed stage, and never seeds the rest.
  - Deleting a seeded company or stage on A pushes a tombstone under A's id. B's copy has a different id and never learns about the delete.
- **Fix:**
  1. Derive seed ids deterministically, and give seeds a fixed creation time so identical seeds merge as the same document:
     ```dart
     String jobSeedStageId(String name) => 'seed-stage-${jobCompanyKey(name).replaceAll(RegExp(r'[^a-z0-9]+'), '-')}';
     String jobSeedCompanyId(String name) => 'seed-company-${jobCompanyKey(name).replaceAll(RegExp(r'[^a-z0-9]+'), '-')}';
     final seedEpoch = DateTime.utc(2025, 1, 1);
     // JobStage(id: jobSeedStageId(name), createdAt: seedEpoch, updatedAt: seedEpoch, version: 0, ...)
     ```
     A seed at version 0 loses to any real edit (version ≥ 1). Two untouched seeds are byte-identical, so the tie-break does no harm.
  2. Seed each missing seed id individually (`insertOrIgnore`) rather than gating on "table is empty". Tombstoned seed rows then still count as present, and a partial pull can no longer suppress the rest.
  3. Add a guarded migration (see the memory note on idempotent `addColumn`) that re-keys existing seed rows to the deterministic id: rows at `version == 0` whose name is in `jobSeedStages` / `jobSeedCompanies`. Stages and companies are referenced by name, never by id, so re-keying is safe. The same pass collapses live duplicates by name that are still at version 0.

---

### [High] Concurrent edits to one application on two devices lose all but one side (whole-document last-writer-wins)

- **Location:** `lib/core/sync/firestore_document_mapper.dart:1093-1134` (`mergeJobApplicationFromRemote`), `lib/core/sync/remote_sync_service.dart:1444-1462`, `lib/domain/models/job_models.dart:49-79`
- **Issue:** The merge compares `version` and then `updatedAt`, and whichever document wins replaces every field. Example: device A (offline) edits Notes, going V→V+1. Device B moves the status Interview→Offer, also V→V+1. When they reconcile, the later `updatedAt` wins and the other edit disappears with no conflict record. Status events sync independently (append-only, `pullJobStatusEvents`), so both timeline entries survive while the `status` field keeps only one. The timeline and the status then disagree: the history can end in `Interview → Offer` while the row reads Interview. This was confirmed as a bug, not intended behaviour.
- **Fix:** Mirror the Rankings per-field stamp design (see the memory note on per-field stamps, `resolveRankingParentFromRemote` at `firestore_document_mapper.dart:3343`):
  1. Add `Map<String, DateTime> fieldUpdatedAt` to `JobApplication` for `company, title, status, dateApplied, applicationUrl, notes, seasonIds`. Store it as `field_updated_at_json` (guarded `addColumn` migration, backfilled from `updatedAt`) and include it in `jobApplicationToFirestore`.
  2. `saveApplication` stamps only the fields that differ from `previous`.
  3. Merge picks each field from whichever side has the newer stamp. If the result differs from both inputs, write it at `max(local.version, remote.version) + 1` and push it back so the other device converges (see the memory note that equal `updatedAt` means the remote wins).
  4. For `status`, prefer the `toStatus` of the newest non-deleted `JobStatusEvent` by `changedAt` when the stamps tie, so the row always matches the end of its timeline.
  5. Keep `deletedAt` document-level, as now.

---

### [Medium] Soft deletes of stages, companies, categories and seasons don't bump the local version, so devices can diverge permanently

- **Location:** `lib/data/repositories/drift_repositories.dart:4754-4764`, `:4817-4827`, `:4875-4885`, `:4955-4962`; `lib/features/jobs/jobs_actions.dart:314-320`, `:343-347`, `:378-384`, `:435-441`
- **Issue:** The repository tombstones with a bare SQL `UPDATE deletedAt, updatedAt`, which leaves `version` at V on disk. The action then pushes `stage.copyWith(deletedAt: utcNow())`, which is V+1 and built from the UI's in-memory copy. Scenario: device B renames stage S (V→V+1) while device A deletes S (disk still V, Firestore gets V+1). If A's tombstone reaches Firestore last, B pulls V+1 vs its own V+1, `updatedAt` breaks the tie, and B ends up deleted. A then pulls B's rename at V+1 against its local V, and remote wins on version, so A ends up **undeleted**. Firestore says deleted, A says live, and neither side changes again. The outbox worker also re-reads disk (`outbox_sync_worker.dart:337-354`), so a retried push sends version V with the tombstone. That payload differs from the V+1 that was already sent.
- **Fix:** Make the repository produce the tombstone and have the action push exactly what was written:
  ```dart
  @override
  Future<JobStage?> softDeleteStage(String id) async {
    final current = (await listStages(includeDeleted: true))
        .where((s) => s.id == id)
        .firstOrNull;
    if (current == null || current.deletedAt != null) return null;
    final tombstone = current.copyWith(deletedAt: utcNow()); // bumps version
    await upsertStage(tombstone);
    return tombstone;
  }

  // JobsActions.deleteStage
  final tombstone = await _repository.softDeleteStage(stage.id);
  if (tombstone != null) _sync.pushJobStage(tombstone);
  ```
  Apply the same change to `softDeleteCompany`, `softDeleteCategory` and `softDeleteSeason`, and update the `JobRepository` interface signatures.

---

### [Medium] New stages, seasons and categories reuse an existing `sortOrder` after a delete, so their order becomes arbitrary

- **Location:** `lib/features/jobs/jobs_actions.dart:275`, `:358`, `:394`; `lib/data/repositories/drift_repositories.dart:4731-4732`, `:4852-4853`, `:4906-4907`
- **Issue:** New rows get `sortOrder: list.length`, where the list excludes tombstones. Deleting never compacts the survivors, so after a delete `length` can equal a `sortOrder` that is still in use. `listStages`/`listSeasons`/`listCategories` order by `sortOrder` only, and SQLite does not define the order of ties. The two rows can swap places between reads, and the picker order (seasons) and position-derived stage colours (`JobStageColors.derivedColor`) move with them. **This has already happened in the live data:** the live seasons "Fall 2026" and "Winter 2027" both have `sort_order = 2`.
- **Fix:**
  ```dart
  sortOrder: stages.isEmpty
      ? 0
      : stages.map((s) => s.sortOrder).reduce(math.max) + 1,
  ```
  Use the same pattern for seasons and categories. Add a deterministic tie-break to the three queries: `..orderBy([(t) => OrderingTerm.asc(t.sortOrder), (t) => OrderingTerm.asc(t.createdAt)])`. Repair existing ties once by calling `reorderSeasons` (and `reorderStages`) with the current display order. `copyWith` bumps the version and `updatedAt`, so the repair survives the next pull.

---

### [Medium] Stages can share a name, which double-counts that status

- **Location:** `lib/features/jobs/jobs_actions.dart:267-298` (`addStage`, `renameStage`); `lib/domain/jobs/job_queries.dart:125-135` (`jobStatusDisplayOrder`); `lib/features/jobs/jobs_stage_colors.dart:14-17`; `lib/features/jobs/jobs_manage_sheet.dart:244-258`
- **Issue:** Neither `addStage` nor `renameStage` checks for an existing name. `status` is a plain string, so two stages named "Interview" both match the same applications. `jobStatusDisplayOrder` pushes every stage name without de-duping, so `jobStatusCounts` emits two "Interview" chips with the full count each. The status pickers list the name twice, and `JobStageColors` keeps whichever duplicate came last. Sync can also create duplicates (see the seeding finding), so the display has to be robust even once input is validated. Agreed behaviour: **reject** the duplicate.
- **Fix:**
  1. Validate on input (case-insensitive, trimmed, excluding the stage being renamed) and report the result to the UI:
     ```dart
     /// False when another live stage already has this name.
     Future<bool> renameStage(JobStage stage, String name) async {
       final trimmed = name.trim();
       if (trimmed.isEmpty || trimmed == stage.name) return true;
       final stages = await _read(jobStagesProvider.future);
       final key = jobCompanyKey(trimmed);
       if (stages.any((s) => s.id != stage.id && jobCompanyKey(s.name) == key)) {
         return false;
       }
       // ... existing write ...
       return true;
     }
     ```
     `addStage` gets the same check without the id exclusion. In `_StagesTab._add` / `_rename`, show a toast such as `A stage named "$name" already exists` when the result is `false`.
  2. De-dupe the display order anyway:
     ```dart
     final ordered = <String>[];
     final known = <String>{};
     for (final stage in stages) {
       if (known.add(stage.name)) ordered.add(stage.name);
     }
     ```
     Also de-dupe the option lists built in `jobs_page.dart:352-357`, `jobs_edit_panel.dart:295-300` and `jobs_track_modal.dart:794-796`.

---

### [Medium] The 30-day sparkline shows zero for every day before a DST change

- **Location:** `lib/domain/jobs/job_queries.dart:186-192` (`jobDailyCounts`)
- **Issue:** `today` is a local midnight, and `today.subtract(Duration(days: i))` subtracts exact 24-hour periods. Across a DST change the result lands at 23:00 or 01:00 instead of midnight, so it never equals a `jobDayKey` bucket and `counts[...]` misses. For the 30 days after each change (early November and mid-March in `America/Toronto`), every day before the change plots as 0 however many applications went out.
- **Fix:** Step by calendar day (see the memory note on duration vs calendar days):
  ```dart
  return [
    for (var i = days - 1; i >= 0; i--)
      () {
        final day = DateTime(today.year, today.month, today.day - i);
        return (day: day, count: counts[day] ?? 0);
      }(),
  ];
  ```
  Add a unit test with `now` just after a DST change and an application dated before it.

---

### [Medium] Date applied shows a different day on a device in another time zone

- **Location:** `lib/features/jobs/jobs_edit_panel.dart:352-356`, `lib/features/jobs/jobs_track_modal.dart:830-832`, `lib/features/jobs/jobs_actions.dart:77`, `lib/core/sync/firestore_document_mapper.dart:1069`, `:1119-1122`; display at `lib/features/jobs/jobs_table.dart:340`, `jobs_edit_panel.dart:318`; bucketing at `job_queries.dart:167-170`
- **Issue:** `dateApplied` is documented as a date-only field but is stored as the instant of *local* midnight, so it syncs as `…T04:00:00.000Z` (the live DB rows read `2026-08-26T04:00:00.000Z`). Suppose a device west of the writer, such as a laptop in Vancouver or the same laptop while travelling, reads that value. `jobDayKey` and `DateFormat(...toLocal())` both convert to local time, giving `Aug 25 21:00`. The table, the editor and the sparkline then all show the previous day. Sorting (`compareJobApplications`) also interleaves rows from different devices by instant rather than by calendar day.
- **Fix:** Represent the calendar day in a way that doesn't depend on time zone:
  1. Write it as UTC midnight of the picked day: `DateTime.utc(picked.year, picked.month, picked.day)`. For the default, use `final n = DateTime.now(); DateTime.utc(n.year, n.month, n.day)`.
  2. Read calendar parts without converting:
     ```dart
     DateTime jobDayKey(DateTime date) => DateTime(date.year, date.month, date.day);
     // callers pass dateApplied as stored (UTC midnight); do not call toLocal()
     ```
     Format with `DateFormat.yMMMd().format(DateTime(d.year, d.month, d.day))` instead of `d.toLocal()`.
  3. Migration: convert each existing row's local-midnight instant with `final l = old.toLocal(); DateTime.utc(l.year, l.month, l.day)`. Write through the typed API (see the memory note on Drift date storage) and bump `version`/`updatedAt` so the repaired value wins the next pull.

---

### [Medium] Toggling a second column (or Include archived) undoes the first toggle

- **Location:** `lib/features/jobs/jobs_page.dart:172-173`, `:192-193`, `:450-468`, `:579-586`
- **Issue:** `onToggleColumn` closes over the `settings` and `hiddenColumns` from the build in which the Columns popover was opened. `showContextualPopover` pushes a route and never rebuilds with new props (see the memory note on stale popover state). Tick column A, then column B in the same open menu: the second call computes `{...hiddenColumnsAtOpen} ± B` and saves `settingsAtOpen.copyWith(...)`, so A's change is reverted. The checkboxes still show both as toggled, because `_ColumnMenu` keeps its own `_hidden`. The same stale-`settings` pattern applies to `_saveIncludeArchived`. It also overwrites any other settings field written since that build.
- **Fix:** Read settings when the click happens. `SettingsNotifier.saveSettings` sets `state` synchronously (`providers.dart:686-689`), so each click sees the previous click's result:
  ```dart
  Future<void> _toggleColumn(JobColumn column) async {
    final settings = ref.read(settingsProvider).valueOrNull;
    if (settings == null || jobRequiredColumns.contains(column)) return;
    final next = settings.jobsHiddenColumns.toSet();
    if (!next.remove(column.id)) next.add(column.id);
    await ref
        .read(settingsProvider.notifier)
        .saveSettings(settings.copyWith(jobsHiddenColumns: next.toList()));
  }

  Future<void> _saveIncludeArchived(bool value) async {
    final settings = ref.read(settingsProvider).valueOrNull;
    if (settings == null) return;
    await ref
        .read(settingsProvider.notifier)
        .saveSettings(settings.copyWith(jobsIncludeArchived: value));
  }
  ```
  Pass `onToggleColumn: _toggleColumn` and `onIncludeArchivedChanged: _saveIncludeArchived`.

---

### [Low] A failed save partway through creation can leave a half-written application, and pressing Save again creates a duplicate

- **Location:** `lib/features/jobs/jobs_actions.dart:60-90`; `lib/features/jobs/jobs_track_modal.dart:501-519`
- **Issue:** `createApplication` makes three separate writes: the application, then the status event, then the company. If a later step throws, the application row already exists (and has been pushed) with no timeline entry. The modal's `catch (_)` re-enables Save without telling the user anything, so the natural retry creates a second application. The same applies to `duplicateApplication` and `restoreApplication`, which upserts events in a loop.
- **Fix:** Wrap the local writes in one Drift transaction and push only after it commits. Add a repository method such as `createApplicationWithEvent(application, event, companyName)` that runs `_db.transaction(() async { ... })` and returns the written rows; the action then calls `pushJobApplication` / `pushJobStatusEvent` / `pushJobCompany`. In the modal's `catch`, show an error toast (`Could not save the application`) so a failed save isn't silent.

---

### [Low] The 30-day purge brings back stages and companies the user deleted

- **Location:** `lib/data/repositories/drift_repositories.dart:4592-4611` and `:4996-5001`
- **Issue:** `ensureSeeded` treats tombstones as "present" precisely so that clearing the list isn't undone (per its comment). But `purgeExpiredDeleted` hard-deletes those tombstones after the retention window. If the user deletes every stage (or every seeded company), the next launch after the purge sees an empty table and re-seeds the full list.
- **Fix:** Record the seeding in a one-time flag rather than inferring it from row count, e.g. a `jobsSeededAt` setting or a `job_seed_state` row, and check that flag in `ensureSeeded`. With the deterministic seed ids from the seeding finding, an alternative is to skip purging seed-id tombstones.

---

### [Low] A resumed draft keeps a stage that has since been renamed or deleted

- **Location:** `lib/features/jobs/jobs_track_modal.dart:214`, `:551-562`, `:794-796`
- **Issue:** On restore, draft seasons are checked against the live season list, but `_status` is not checked against the live stages. If the stage named in the draft was renamed or deleted while the draft sat on disk, the pill shows a name the picker doesn't offer. Save then silently creates the application on an orphan status.
- **Fix:** Clamp the status in `build` next to the season clamp, once stages have loaded:
  ```dart
  final stagesAsync = ref.watch(jobStagesProvider);
  if (stagesAsync.hasValue && _status.isNotEmpty &&
      !stagesAsync.requireValue.any((s) => s.name == _status)) {
    _status = ''; // falls back to the first stage, as a fresh form does
  }
  ```

---

### [Low] "Start over" doesn't re-read the clipboard, contrary to JOBS_SMART_PASTE_HLD §5.3

- **Location:** `lib/features/jobs/jobs_track_modal.dart:284-305`
- **Issue:** §5.3 says discarding the draft "re-enables sniff against the current clipboard (same as a fresh open)". `_discardDraft` clears the form and the slot but never calls `_sniffClipboard`, so Start over leaves Title and URL empty even when a posting is on the clipboard.
- **Fix:** At the end of `_discardDraft`, after `_baseline = _snapshot();` and the clear, add `if (mounted) unawaited(_sniffClipboard());`.

---

### [Low] URL clean-up strips a closing parenthesis that belongs to the link

- **Location:** `lib/features/jobs/job_clipboard_parser.dart:73`, `:167-173`
- **Issue:** `_trimTrailingPunctuation` always removes a trailing `)`. HLD §6.5 limits this to punctuation "not part of a real path". A link such as `https://en.wikipedia.org/wiki/Mercury_(planet)` is stored as `…/Mercury_(planet`, a broken URL. It also changes the duplicate-URL key.
- **Fix:** Strip `)` only when it is unbalanced:
  ```dart
  String _trimTrailingPunctuation(String token) {
    var end = token.length;
    while (end > 0 && _trailingPunctuation.contains(token[end - 1])) {
      final c = token[end - 1];
      if (c == ')') {
        final s = token.substring(0, end);
        if ('('.allMatches(s).length >= ')'.allMatches(s).length) break;
      }
      end--;
    }
    return token.substring(0, end);
  }
  ```

---

### [Low] Two quick drags in the reorder lists: the second one undoes the first

- **Location:** `lib/features/jobs/jobs_manage_sheet.dart:161-165`, `:800-804`
- **Issue:** `onReorderItem` builds the id order from the `stages` / `seasons` list captured at build time and fires `reorderStages` without awaiting it. Until the provider reloads, the list snaps back to its old order. A second drag in that window is computed against the pre-first-drag order and overwrites the first drag. The snap-back itself also shows as a visible flicker on every drag.
- **Fix:** Keep an optimistic local order in the tab's state. Apply the move to it synchronously with `setState`, build `ids` from that local list, and clear it once the provider delivers a list whose order matches. Alternatively, chain the reorders through a single `Future` so each one starts from the previous result.

---

### [Low] Stage colours skip the light-theme palette swap

- **Location:** `lib/features/jobs/jobs_stage_colors.dart:26-27`
- **Issue:** Stage colours come from the same palette picker as category colours (`jobs_manage_sheet.dart:269`), and those values are stored on the dark ramp. Categories are painted through `resolvePaletteColor(value, brightness)` (`jobs_page.dart:509`), but `JobStageColors.of` returns `Color(explicit)` raw. In light theme, a coloured stage's capsule and header chip use the pastel dark-ramp tint, which `palette_color.dart` documents as ~1.4:1 contrast on a light surface.
- **Fix:** Pass `brightness` into `JobStageColors` and return `Color(resolvePaletteColor(explicit, brightness))`. Update the three construction sites (`jobs_page.dart:118`, `jobs_manage_sheet.dart:134`).

---

### [Low] The sparkline's "today" doesn't move past midnight while the page stays open

- **Location:** `lib/features/jobs/jobs_page.dart:163-169`
- **Issue:** `jobDailyCounts(..., now: DateTime.now())` is evaluated only when the page rebuilds. Shell branches stay mounted (see the memory note on shell branches), so a Jobs page left open overnight keeps yesterday as the last bucket. Applications dated today are dropped from the chart until something else triggers a rebuild.
- **Fix:** Schedule a one-shot `Timer` to the next local midnight in `initState` (`DateTime(n.year, n.month, n.day + 1).difference(n)`) that calls `setState` and reschedules itself. Cancel it in `dispose`.

---

### [Low] Each opened application's timeline stays cached for the rest of the session

- **Location:** `lib/app/providers.dart:1318-1321`
- **Issue:** `jobStatusEventsProvider` is a plain `FutureProvider.family` with no auto-dispose, so every application ever opened in the editor keeps its event list in memory until the app exits. `invalidateSecondaryDataProviders` also re-runs the query for every one of those entries on every sync tick, although only one panel can show a timeline at a time.
- **Fix:** Make it `FutureProvider.autoDispose.family`. The only consumer, `_StatusTimeline`, watches it while the panel is mounted.

---

### [Low] Every search keystroke rebuilds the whole page and re-sorts the full list twice

- **Location:** `lib/features/jobs/jobs_page.dart:94`, `:136-143`, `:303-305`; `lib/features/jobs/jobs_company_field.dart:107-113`
- **Issue:** `jobSearchQueryProvider` is watched at the top of `JobsPage.build`, so each keystroke re-runs the entire derivation: filter, `sort(compareJobApplications)`, `jobDuplicateIds`, `jobStatusCounts`, `jobDailyCounts`, and `jobRecentCompanyKeys(applications)`, a second full copy and sort. It also rebuilds the header, both `LayoutBuilder`s, and the open `JobsEditPanel`. The panel then reruns `didUpdateWidget` in `JobsCompanyField`, whose `listEquals` walks the full company list (~175 rows in the live DB). At ~100 applications this costs little, but the work grows with the size of the history on every keystroke.
- **Fix:** Move the counts and chart inputs, which don't depend on `query` or `statusFilter`, into a derived provider keyed on `jobApplicationsProvider` + `jobStagesProvider` + `jobSeasonsProvider` + `includeArchived`. Move `jobRecentCompanyKeys` into its own provider so it is computed once per data change. Watch `query`/`statusFilter` only in a small widget that owns the table body.
