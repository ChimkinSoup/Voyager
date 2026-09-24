# On This Day — HLD

A per-journal opt-in that brings back an entry from exactly one month ago, or from this day in any past year. The memory appears as a small portrait card tucked into the right edge of the journal page, with only its left edge showing. Clicking that edge slides the card out, turning it slightly counterclockwise as it comes; any interaction elsewhere tucks it back.

Related: `lib/features/journal/on_this_day.dart` (matching, providers), `lib/features/journal/on_this_day_overlay.dart` (card), `lib/domain/models/journal_models.dart` (`Journal.onThisDayCadence`), `lib/features/journal/journal_settings_dialog.dart`, `lib/features/journal/journal_page.dart`, `lib/core/sync/firestore_document_mapper.dart`, `lib/features/settings/services/backup_collections.dart`.

Status: **implemented** (schema v125).

---

## 1. Goals

- Per-journal switch, off by default, with a cadence: **Off / Yearly / Monthly + yearly**.
- Show matches only on the journal page, as a card that tucks into the right edge rather than vanishing.
- Never lose a memory to calendar gaps. Entries on days that don't exist in the target month (Jan 31 → February, Feb 29 → a non-leap year) appear on that month's last day.
- Respect the journal's existing chrome toggles (mood, weather).
- Sync the setting and carry it through import/export. Dismissals are deliberately **not** synced or persisted (§6.4).

## 2. Non-goals (v1)

- Surfacing anywhere outside the journal page: no nav-rail dot, Inbox item, OS notification or sticky reminder.
- "Reflect on this": linking or quoting a memory into today's entry.
- A global (app-wide) switch. The setting exists only per journal.
- Matching by anything other than `entryDate` (not `createdAt`).
- Memories from further back than one month under the monthly cadence. "Monthly" means **the prior month only**.
- Remembering a dismissal across app restarts or devices.

---

## 3. Product decisions (locked)

| Decision | Choice |
|----------|--------|
| **Where the setting lives** | Per journal only, in Journal settings. No global switch. |
| **Cadence** | `off` (default) / `yearly` / `monthlyAndYearly`. |
| **Yearly** | Same month and day in **every** past year. |
| **Monthly** | Same day in the **immediately prior** month only. Never two or more months back. |
| **Missing days** | On the last day of a month, also show every entry whose day number is greater than today's. Nothing is skipped. |
| **Surface** | Journal page only. |
| **Presentation** | A portrait card. Tucked, it stands upright in the right edge with a 32 px strip showing. Out, it sits by the right edge turned ~4° counterclockwise. Clicking the strip brings it out; any interaction outside the card tucks it back. |
| **Multiple matches** | One card with paging ("1 of 3"), newest first. No stacked cards. The tucked strip shows how far back the first (newest) match is and, with more than one, the count. |
| **Dismiss** | ✕ hides the card, strip included, **for the rest of this run of the app**. It is held in memory only: restarting the app the same day brings the card back, and it slides out again. Not synced, not persisted, not in backups. |
| **Eligible entries** | Not soft-deleted, in a non-deleted journal, and not blank (the title or body has non-whitespace text). |
| **Day boundaries** | Everything is compared in **device-local** calendar days. `entryDate` is stored in UTC and converted with `toLocal()` first. |
| **Chrome toggles** | Mood appears only if that journal's `showMood` is on, and weather only if `showWeather` is on. The card never shows quotes. |
| **All journals view** | Memories from journals with the feature on **and** `includeInAllView` on. Each page is labelled with its journal's name and colour. |

---

## 4. Matching rules

Today is local date `T` (year `Ty`, month `Tm`, day `Td`), and `lastDay(T)` means `Td` is the final day of `Tm`. An eligible entry with local date `D` matches when one of these holds:

**Yearly** (cadence `yearly` or `monthlyAndYearly`)
- `D.year < Ty` and `D.month == Tm`, and
- `D.day == Td`, **or** (`lastDay(T)` and `D.day > Td`).

**Monthly** (cadence `monthlyAndYearly` only)
- `D` falls in the month immediately before `T`, wrapping January to the previous December, and
- `D.day == Td`, **or** (`lastDay(T)` and `D.day > Td`).

Worked examples:

| Today | Yearly shows | Monthly shows |
|-------|--------------|---------------|
| 2026-09-24 | Sep 24 of 2025, 2024, … | 2026-08-24 |
| 2027-02-28 (non-leap) | Feb 28 **and Feb 29** of past years | 2027-01-28, 29, 30, 31 |
| 2026-04-30 | Apr 30 of past years | 2026-03-30, 31 |
| 2026-03-31 | Mar 31 of past years | nothing (February has no 31st; Feb 28/29 were shown on Mar 28/29) |
| 2026-01-15 | Jan 15 of past years | 2025-12-15 |

The two rules can never match the same entry. The monthly match is always in a different month, or in the same month of an earlier year only when `Tm` is January, and yearly requires `D.month == Tm`. The matcher still checks them as `if / else if`.

**Ordering:** newest `D` first, then by `timestamp ?? createdAt` (latest first) within a day, then by id.

**Labels:** "1 month ago", "1 year ago", "N years ago", followed by the entry's own date (e.g. "1 month ago · Jan 31"). The date always appears so the last-day catch-up entries read correctly.

`matchOnThisDay(today, journals, entries, {journalId})` is a **pure function** with no I/O and no clock reads. `journalId` null means the All view. Every row of the table above is a unit test.

---

## 5. The card

### 5.1 States

```
hidden ──(un-dismissed matches exist)──▶ tucked
tucked ──(first time this run, per day + scope, entries loaded, +400 ms)──▶ out
tucked ──(click the strip)──▶ out
out ──(outside tap / key press / Esc / Open / scope change)──▶ tucked
out ──(✕)──▶ hidden until the app restarts
any ──(no un-dismissed matches for the scope)──▶ hidden
```

- **Auto-expand:** the card slides out on its own the **first time in each run of the app**, per `(day, scope)`, that the journal page has un-dismissed matches for that scope. Later visits in the same run start tucked. The memory is recorded only when the card actually slides out, so a scope switch that cancels the pending entrance doesn't use it up. It lives in a plain in-memory provider (`_onThisDayAutoExpandedProvider`), so a restart auto-expands again. That matches the restart behaviour of ✕. The shell keeps pages it has left mounted, with their tickers off (`TickerMode`). The entrance waits until the page is on screen, and a delay that runs out after the page was left is not recorded, so the page gets its entrance when the user comes back.
- **Entrance delay:** 400 ms (`OnThisDayOverlay.entranceDelay`) after the page's entries have loaded (`ready`), so the card doesn't arrive while the list is settling.

### 5.2 What tucks it away

While out, any of these tuck it back:
- A pointer-down anywhere outside the card, via `TapRegion.onTapOutside`. The tap still reaches its target; tucking never swallows it.
- Any key press except a modifier on its own (Shift, Ctrl, Alt, Meta, Caps Lock, Fn), including typing into an already-focused editor. A shortcut such as Ctrl+S still tucks it, because its other key counts. A `HardwareKeyboard` handler is registered only while the card is out. It returns `false`, so the key is reported unhandled and the engine still delivers the typed character. The widget test asserts exactly that.
- `Esc`, from anywhere.
- **Open**, after handing the entry to the page.
- Switching the journal scope or the day. The card jumps straight to tucked, with no slide, so the new scope's memory never plays a slide-in. If the new scope has no matches, the card goes to hidden instead.

Scrolling with the wheel or trackpad does **not** tuck it, since reading while the card is out is fine.

**Mouse-only (v1).** The card is wrapped in `ExcludeFocus`, so nothing in it takes focus and Tab never lands on its buttons, tucked or out. The strip cannot be opened from the keyboard, and it has no semantics label.

### 5.3 Geometry and motion

- **Surface:** `surfaceContainerHigh` with 16 px corners, elevation 8, and a faint 1 px border in the journal colour at 35 % opacity.
- **Size:** 220 × 300 logical px, or `available − 32` wide if narrower. It is anchored 72 px below the top of the journal content area, with a 16 px gutter from the right edge when out.
- **Tucked:** upright, translated right until only a 32 px strip of its left edge is on screen. The rest is clipped by the overlay's `Stack`. The strip shows the memory icon at the top. Near the bottom, in 9 px text in the journal colour, is how far back the card's first (newest) match is, as `OnThisDayMatch.shortAgo` ("1mo", "1y", "6y"). With 2 or more matches, the count sits below that, in a small round badge tinted with the journal colour so it doesn't read as a distance. Both ends sit 14 px in from the card's top and bottom edges. "1mo" is the widest label and fits the 32 px strip. Hovering the strip nudges the card 6 px further out and shows a click cursor. A removed `MouseRegion` gets no `onExit`, so ✕ and a scope change clear the hover state themselves. Clicking anywhere on the visible strip brings it out.
- **Out:** rotated ~4° (0.07 rad) counterclockwise about its centre, like a card laid on a desk.
- **Motion:** one `AnimationController`, 420 ms. It goes out on `VoyagerSpring.momentumCurve`, whose slight overshoot turns the card a hair past its resting angle before it settles, and comes back on `Curves.easeInOutCubic`. Translation and rotation both follow the same progress.
- **Content fades:** staggered so they never overlap mid-swing. The strip's icon, distance and count fade out over the first third, and the card's contents fade in from 25 % to 100 %.
- **Reduced motion:** no rotation, and a 150 ms (`VoyagerMotion.crossfade`) linear slide. There is no pure-fade equivalent, because the two states are positions, not visibility.
- **Hit-testing:** the transforms are the outermost widgets under the `Positioned`. A render box above them would hit-test against the untransformed layout box, and the tucked strip lies outside it. An early version had exactly that bug: the strip didn't respond to clicks.
- **Stacking:** the card sits above the entry list and editor but below dialogs and toasts. It is mounted over the whole page content, so its right edge is the window's.
- **Editor overlap:** the tucked strip is 32 px wide and the editor's right gutter is 24 px, so the strip reaches ~8 px over the editor's right edge (and its scrollbar) within the card's 300 px band. Out, the card overlaps the editor fully, which is the point of an overlay.

### 5.4 Content

Top to bottom:
- **Header:** memory icon in the journal colour, "On this day", and ✕ (tooltip "Dismiss").
- **Label and date:** e.g. "1 year ago · Sep 24".
- **Journal:** name and colour dot, All view only.
- **Title:** up to 2 lines, "Untitled" when blank.
- **Body preview:** up to 7 lines through `VoyagerProseText`, so `**bold**` and `*italic*` render as they do in the list.
- **Mood and weather:** "Mood N/10" with an icon, and the weather glyph (`weatherIconData`), each per its journal toggle.
- **Footer:** paging (‹ 1 of N ›) when there is more than one match, and **Open**. The paging buttons are shrink-wrapped to 28 px targets, because padded 48 px touch targets don't fit a 220 px card.

**Open** calls the page's `_openMemory`, which opens the entry through `_openEntry` and then scrolls the list to it through the page's existing `_shouldScrollToSelected`, since a memory is usually far below the visible rows. That scroll estimates the row's offset from fixed per-row heights (52 px, or 68 px with a preview). These are now scaled to the list's measured extent, and it measures and jumps again, up to 4 times, if the row still isn't built where it lands. Unscaled, the estimate fell several rows short of a year-old entry. The card then tucks so the entry is readable. The page has no search or tag filter over its list, and neither the single-journal list nor the All list is limited, so the opened entry is always in the list. That resolves the original open point about filtered-out entries.

### 5.5 Compact width

Same behaviour. The card is `available − 32` wide when that is narrower than 220, and it tucks into the same edge. An edge swipe does not open it, because the strip is a tap target only.

---

## 6. Data model

### 6.1 `Journal`

New field `onThisDayCadence`, with enum `OnThisDayCadence { off, yearly, monthlyAndYearly }` in `domain/models/enums.dart`.

- **Model:** constructor default `OnThisDayCadence.off`, plus `copyWith`.
- **Drift:** `TextColumn get onThisDayCadence => text().withDefault(const Constant('off'))();` on `JournalsTable`, stored as the enum `name`, matching how `TrackerCadence` is stored.
- **Migration v125:** adds the column through `_addColumnIfNotExists`, not a bare `addColumn`. The rewind-style migration tests (e.g. `settings_all_view_migration_test.dart`) start from a current database, which already has the column. A bare `addColumn` failed there with "duplicate column". Every existing journal reads `off`.
- **Repository:** row ↔ model mapping in `drift_repositories.dart`, in both the upsert and `_mapJournal`.

### 6.2 Sync

`firestore_document_mapper.dart`:
- `journalToFirestore` writes `'onThisDayCadence': journal.onThisDayCadence.name`.
- `mergeJournalFromRemote` reads it with `_enumFromName`, falling back to `local?.onThisDayCadence` and then `off`. A document written by an older build has no field and keeps the local value, the same as `includeInAllView`.

### 6.3 Import / export

`backup_collections.dart` already serialises journals through `journalToFirestore` / `mergeJournalFromRemote`, so the field comes along with no extra code. It is covered by tests (§9):
- An export contains `onThisDayCadence`, and a restore keeps `yearly` and `monthlyAndYearly`.
- Importing a backup made before this change yields `off`.

### 6.4 Dismissals (in memory only)

- **Storage:** `onThisDayDismissedProvider`, a `StateProvider<Set<String>>` in `on_this_day.dart`, holds the dismissed keys for the current run of the app. There are no database rows, no outbox entries, no Firestore documents and no backup records.
- **Key:** `<entryId>|<yyyy-MM-dd of T>`. There is one key per matched entry per day, so a dismissal holds whichever view it's made from: one journal or All.
- **✕** adds a key for **every** match currently on the card, then tucks it.
- **Filtering:** the overlay watches the set and filters matches synchronously before deciding its state, so the card disappears in the same frame. There is no optimistic local copy to reconcile.
- **Why in memory:** the user wants a dismissed card to come back after a restart even on the same day. That also means a dismissal on one device doesn't hide the card on another.
- **Leftover rows:** builds from before this change wrote `onthisday|…` rows to `dismissed_notifications_table`. Nothing reads them any more, and the Inbox ignores keys that belong to none of its feed items, so they are inert.

---

## 7. Providers and data flow

```
journalsProvider ───────────┐
                            ├─▶ onThisDayProvider((day, journalId))   matchOnThisDay, §4
allJournalEntriesProvider ──┘            │
                                         ▼
onThisDayDismissedProvider ──▶ OnThisDayOverlay (journal_page.dart)   filter, card state machine, §5
```

- `onThisDayProvider` is `autoDispose`, so a (day, scope) pair's matches are dropped once no overlay watches them.
- `onThisDayProvider` short-circuits to `[]` when every journal is `off`, the default. In that case it never loads the entries.
- **Invalidation:** entries come from `allJournalEntriesProvider`, which is in the journal entry cache group. Autosaves do **not** invalidate it. The page refreshes it only at commit points (`_refreshEntryLists`): the editor losing focus, switching entry or journal, and the create, delete, restore, date-change and move paths (`_invalidateJournalEntryCaches`). So each commit point, not each keystroke burst, costs one full entry read once any journal is opted in, and an edit to a memory reaches the card at the next commit point. That's acceptable for a personal journal. If it ever isn't, the fallback is a repository query over the computed local-day windows converted to UTC. A cadence or toggle change invalidates `journalsProvider`.
- **Today:** the page computes it (local midnight) on every build of the page content. If the app stays open across midnight, the next rebuild picks up the new day. There is no live midnight tick.
- **Scope:** a single journal id, or null for All. For All, only journals with `includeInAllView` are kept.
- **Mount:** `_buildJournalContent` binds the page's `Column` to a local and returns `Stack([content, Positioned.fill(OnThisDayOverlay(...))])`. The overlay therefore spans the sync banner, the list and the editor. Only the card takes hits.

---

## 8. Settings UI

`journal_settings_dialog.dart` has an **On this day** row after the Quotes toggle: a title and the subtitle "Resurface entries from this day in past years, or from one month ago.", then a full-width `SegmentedButton` with **Off · Yearly · Monthly + yearly**.
- **Layout:** segments split the width evenly (~140 px each in the 420 px dialog). The default padding wrapped "Monthly + yearly" onto two lines, so the button's horizontal padding is 4 px and that label is `softWrap: false`.
- **Writes:** a selection writes through `_saveJournal` with `copyWith`, like the other toggles, and the card reacts right away.

---

## 9. Testing

| File | Covers |
|------|--------|
| `test/journal_on_this_day_match_test.dart` | Every row of the §4 table. Feb 29 → Feb 28 in non-leap years only. December → January wrap. A 23:30-local entry matches its local day. Yearly cadence drops the month-ago entry. Soft-deleted, blank, deleted-journal, `off`-journal and orphaned entries excluded. The All scope drops `includeInAllView == false`, but the journal's own scope keeps it. Ordering, labels and short distances ("1mo", "1y", "3y"), dismissal key format. |
| `test/journal_on_this_day_card_test.dart` | Mounts the overlay over a stand-in list and text field (a bare `MaterialApp`, not AppShell). Auto-expands once. A list tap tucks it **and** selects the row. Typing tucks it, reaches the field, and is reported unhandled. Esc tucks it. The strip brings it out. The tucked strip shows the newest match's distance ("1y") and the count. A second visit the same run starts tucked. ✕ writes nothing to the database, stays closed for the run, comes back after a simulated restart (a fresh `ProviderContainer`), and the next day shows its own matches. **Open** hands over the entry id and tucks the card. Paging. Mood and weather per toggles. A lone modifier leaves it out, and Ctrl+S tucks it. Tab never focuses anything inside the card. A scope change while out goes straight to tucked. Off screen (`TickerMode` off), the entrance waits for the page to come back. ✕ under the mouse leaves no hover nudge. |
| `test/journal_on_this_day_open_scroll_test.dart` | The real page, in All journals and in one journal: 60 recent rows of mixed heights over a year-old memory. **Open** leaves the memory's row on screen. |
| `test/journal_on_this_day_data_test.dart` | 124 → 125 migration gives `off` and keeps the journal. The repository and mapper round-trip every cadence. A remote document without the field keeps the local value, or `off` with no local. |
| `test/import_export_test.dart` (group "On this day cadence in backups") | The export carries the cadence and a restore keeps it. A pre-change backup restores as `off`. |
| `test/journal_settings_dialog_test.dart` | The control starts at Off, and each choice writes through per journal. |

The existing journal-page tests mount the real page with the overlay in it, and all cadences there are `off`. They caught a bug where the overlay's `late final` animation controller was first created inside `dispose()`, looking up `TickerMode` on a deactivated element. It is now created in `initState`.

The visual design (tucked, mid-swing, out; the one-line setting) was checked with throwaway goldens using real fonts, `VoyagerTheme.dark()`, the Windows variant and `debugDisableShadows = false`.

---

## 10. Open points

1. **No undo for ✕.** Tucking is the safety net, since an outside click only tucks. A restart also restores a dismissed card. If accidental dismissals happen, add an Undo toast.
2. **Entry read per commit point** (focus loss, entry or journal switch, create, delete) once any journal is opted in (§7). Move to a date-window repository query if it shows up in profiles.
3. **The tucked strip overlaps the editor's right edge by ~8 px** (§5.3). If it gets in the way of the scrollbar, narrow the peek to the 24 px gutter.
4. **Midnight rollover** is picked up on the next page rebuild, not live.

---

## 11. Files touched

| File | Change |
|------|--------|
| `lib/domain/models/enums.dart` | `OnThisDayCadence` |
| `lib/domain/models/journal_models.dart` | field + `copyWith` |
| `lib/data/database/app_database.dart` (+ `.g.dart`) | column, schema v125, migration |
| `lib/data/repositories/drift_repositories.dart` | row ↔ model |
| `lib/core/sync/firestore_document_mapper.dart` | to/from Firestore |
| `lib/features/journal/on_this_day.dart` (new) | pure matcher, labels, `onThisDayProvider`, `onThisDayDismissedProvider` |
| `lib/features/journal/on_this_day_overlay.dart` (new) | card, tucked strip, motion, state machine |
| `lib/features/journal/journal_page.dart` | mount the overlay, wire Open to `_openMemory` (open and scroll to it) |
| `lib/features/journal/journal_settings_dialog.dart` | cadence control |
| `test/journal_on_this_day_{match,card,data}_test.dart` (new), `test/import_export_test.dart`, `test/journal_settings_dialog_test.dart` | §9 |
