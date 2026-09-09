# Scope Switcher — UI Redesign HLD

Replace the `RoundedDropdown` list / journal / calendar pickers with Rankings-style title triggers + selection-only popovers, and move create / rename / color / settings / delete into Manage dialogs. **North star: Rankings category switcher (`RANKINGS_UI.md` §2.2) + Jobs/Rankings Manage pattern.**

Domain rules, persistence of “all” views, filing targets for new tasks/entries/events, sync, and settings schemas are unchanged unless noted.

---

## 1. Goals

- Make scope switching feel like page identity (a title), not a form control.
- Align Todo, Journal, and Calendar with the Rankings category trigger + `ContextualPopover` pattern.
- Remove nested kebab (`⋮`) menus from the switcher.
- Put create and entity administration behind a gear **Manage** control beside the trigger.
- Delete `RoundedDropdown` once its three call sites are migrated (it has no other production uses).

### Out of scope

- Changing how “all” vs single-scope filters work in data/providers.
- Reorder UI for lists / journals / calendars (none of the manage dialogs gain reorder in this pass).
- Search inside the switcher popover.
- Redesigning `VoyagerDropdownButton` (Analytics, Finance, etc. — separate widget family).
- Rankings / Jobs chrome (already on the target pattern).

---

## 2. Product decisions (locked)

| Decision | Choice |
|----------|--------|
| **Closed trigger** | Rankings-style: name + small caret; **not** a filled full-width capsule |
| **Quiet count (closed)** | **Todo:** `active \| completed` for a list; same format for **All tasks** (sum across lists). **Journal:** entry count for a journal and for **All journals**. **Calendar:** **name only** (no count) |
| **All-scope row** | First row in the popover: **All tasks** / **All journals** / **All calendars**. Remove sibling “all” icon buttons (`listMagnifyingGlass` / `calendarDots`) |
| **Closed accent** | Entity color when a specific list/journal/calendar is selected; **main app accent** when All is selected |
| **Create** | **Manage only** (no Add row in the popover; no empty-state-only create path that bypasses Manage except where Manage *is* the empty CTA) |
| **Manage** | Gear `IconButton` beside the title trigger on all three pages |
| **Todo Manage** | Promote existing `showTodoListManageSheet`; **add Settings** to row actions so nothing is lost vs today’s kebab |
| **Journal / Calendar Manage** | New matching dialogs (`Manage journals` / `Manage calendars`) |
| **Nested kebab in switcher** | **Removed** |
| **Popover search / reorder** | **No** |
| **`RoundedDropdown`** | **Delete** after migration (production uses: Todo, Journal, Calendar only; tests updated) |

---

## 3. Problem summary (current state)

```
[████ RoundedDropdown capsule ████ ▼]  [All icon]
```

- Closed control is a 48px menu-colored capsule spanning the column (or a fixed 360px on Calendar) — reads as a Material select, not Voyager chrome.
- Nested `⋮` on each menu row + accent GlassButton “Add …” mixes administration into daily switching.
- Sibling icon for “All …” is a second, easy-to-miss control for the same scope decision.
- Todo already has a Manage lists dialog, but it is only reached from the empty state and omits **Settings**.
- Journal and Calendar have no Manage dialog; only the nested kebab.

---

## 4. Target chrome

### 4.1 Header cluster (all three pages)

```
[ Name  quietCount ▾ ]  [⚙]
```

| Element | Behavior |
|---------|----------|
| **Trigger** | InkWell / transparent Material; `titleSmall`–weight name in accent; optional quiet count in muted `labelSmall`; small caret |
| **Manage** | `IconButton` with `PhosphorIconsRegular.gear` (or Bold if that matches nearby toolbar icons); tooltip **Manage lists** / **Manage journals** / **Manage calendars** |
| **Layout** | Trigger sizes to content (max width with ellipsis), **not** `Expanded` full bleed. Manage sits immediately to the right with a small gap (~8px). Surrounding page chrome (Todo toolbar icons, Journal all-row siblings, Calendar view mode / today / sync) stays otherwise unchanged |

### 4.2 Selection popover

Opened via `showContextualPopover` anchored to the trigger (same family as Rankings `_CategoryTrigger`).

| Element | Behavior |
|---------|----------|
| **Width** | ~240–280px (Rankings uses 240); not forced to match trigger width |
| **Max height** | Scroll if needed (~320px like Rankings) |
| **Row 0** | **All tasks** / **All journals** / **All calendars** — selected when all-scope is on; wears main accent in the closed trigger only (row can use primary check / highlight) |
| **Following rows** | One per entity: name; Todo/Journal also show the same quiet count format as closed state; Calendar rows are **name only** |
| **Selection** | Tap row → apply scope, close popover. Checkmark or accent treatment on the active row |
| **No** | Nested `⋮`, Add button, reorder handles, search field |

Accent border on the popover: entity color when a specific scope is selected; main accent when All is selected (matches Rankings / `ContextualPopover` accent usage).

### 4.3 Per-page placement

| Page | Where |
|------|--------|
| **Todo** | Replaces `RoundedDropdown` + all-tasks `IconButton` in the list column header row |
| **Journal** | Replaces `RoundedDropdown` + all-journals `IconButton` in the entry-list header bar |
| **Calendar** | Replaces the 360px `RoundedDropdown` + all-calendars toggle in the top toolbar row (after view mode / go-to-today) |

---

## 5. Behavior preserved

### 5.1 Todo

- Choosing a list leaves all-tasks view and persists that choice as today.
- Choosing **All tasks** sets the all-tasks flag; **`_selectedListId` stays** as the filing target for new tasks (existing comment/contract).
- Closed count for a list: scoped `active \| completed` as today.
- Closed count for All tasks: sum of active and completed across lists, same `a \| c` format.
- Empty lists state: CTA still opens Manage (`showTodoListManageSheet`).

### 5.2 Journal

- Choosing a journal routes through existing `_selectJournal` (flush / fresh entry rules unchanged).
- Choosing **All journals** uses existing `_toggleViewAllJournals` / `_viewAllJournals` persistence semantics (implement via explicit select-all path rather than the old icon toggle).
- Closed / popover counts: entry counts as today (`entryCounts` / filtered length for All).

### 5.3 Calendar

- Choosing a calendar sets `_selectedCalendarId` and updates `_lastSpecificCalendarId`.
- Choosing **All calendars** sets `_selectedCalendarId = null` while keeping `_lastSpecificCalendarId` for restore / new-event defaults as today.
- Closed trigger shows **All calendars** when all-scope is on (addresses `FEEDBACK.md`: all-calendar view should be reflected in the switcher label).
- **No** quiet counts on closed trigger or popover rows.

---

## 6. Manage dialogs

### 6.1 Shared shape (Jobs / existing Todo manage)

Dialog title + scrollable list of entities + actions:

| Action | Todo | Journal | Calendar |
|--------|------|---------|----------|
| **New …** | New list | New journal | New calendar |
| **Rename** | ✓ | ✓ | ✓ |
| **Change color** | ✓ | ✓ | ✓ |
| **Settings** | ✓ (add to sheet) | ✓ | ✗ (calendars have no settings sheet) |
| **Delete** | ✓ (not for legacy default) | ✓ (not for legacy default) | ✓ (not for legacy default) |

Reuse existing action helpers (`todo_list_actions`, journal list actions, `calendar_list_actions`) — do not fork delete/rename/color logic.

Row presentation: color swatch + name + optional subtitle counts (Todo already shows open/done; Journal may show entry count; Calendar name-only or event count optional inside Manage only — **not** required for switcher).

### 6.2 Todo — promote + Settings

- Wire header gear → `showTodoListManageSheet`.
- Extend row `PopupMenuButton` / catalog entries to include **Settings** → `showTodoListSettingsDialog` (same as today’s kebab `configurableManageMenuEntries` / `defaultConfigurableManageMenuEntries`).
- Keep legacy list non-deletable rules.
- After create from Manage, optional: select the new list and leave all-tasks (match previous dropdown create behavior when returning a created id).

### 6.3 Journal — new dialog

- Add `showJournalManageSheet` (or equivalent) mirroring Todo’s dialog structure.
- Header gear + empty-state CTA (if any) open it.
- Create uses existing `createJournalList`; on success, prefer selecting the new journal via `_selectJournal` when invoked from the page (same contract as `_createJournalFromDropdown`).

### 6.4 Calendar — new dialog

- Add `showCalendarManageSheet` mirroring Todo, **without** Settings.
- Header gear opens it; create uses `createCalendarList` and selects the new calendar as `_createCalendarFromDropdown` does today.

### 6.5 Reorder

Not in this pass. If lists/journals/calendars later gain reorder, it lives only in Manage — never in the switcher popover.

---

## 7. Shared implementation (recommended)

Extract a small shared widget (name TBD, e.g. `ScopeSwitcherTrigger`) used by Todo / Journal / Calendar / optionally aligned with Rankings’ trigger later:

- Closed: `label`, optional `trailingCount`, `Color accent`, `onOpen` / builds popover contents.
- Avoid three divergent copies of padding, caret size, and ellipsis rules.

Popover row list can stay page-local (different count formats and All labels) or take a simple `List<ScopeSwitcherItem>`.

Manage dialogs may share a thin shell, but Todo’s existing dialog is a fine template to copy for Journal/Calendar rather than a forced abstraction.

---

## 8. Deleting `RoundedDropdown`

### 8.1 Production inventory

| Location | Action |
|----------|--------|
| `lib/features/todo/todo_page.dart` | Replace with scope switcher + Manage |
| `lib/features/journal/journal_page.dart` | Same |
| `lib/features/calendar/calendar_page.dart` | Same |
| `lib/core/widgets/rounded_dropdown.dart` | **Delete file** |

**Not the same widget:** `VoyagerDropdownButton` (`lib/core/widgets/voyager_dropdown_button.dart`) used by Analytics / Finance — **keep**.

### 8.2 Tests

| Test | Action |
|------|--------|
| `test/journal_new_journal_opens_fresh_entry_test.dart` | Stop tapping `RoundedDropdown`; target the new trigger / Manage create path |
| `test/voyager_menu_semantics_test.dart` | Rewrite against Manage catalog / remaining menu surfaces, or drop if it only covered dropdown kebabs |
| Any page harness finding the old control | Update finders |

After deletion, `graphify update .` so the graph drops the widget community.

---

## 9. Visual / motion notes

- Trigger: no fill, no 18px capsule; Rankings-like transparent hit target (`BorderRadius` ~10).
- Quiet count: muted (~0.52–0.58 alpha), same optical size family as today’s dropdown trailing (`~10–12sp`), not competing with the name.
- Motion: existing `ContextualPopover` open/close; no new celebration motion.
- Honor reduced-motion / existing popover behavior.

---

## 10. Acceptance checklist

### Chrome
- [ ] Todo / Journal / Calendar use title trigger + gear; no `RoundedDropdown`
- [ ] Sibling All icons removed; All is first popover row
- [ ] Closed accents: entity color vs main accent for All
- [ ] Quiet counts: Todo `a \| c` (incl. All); Journal entry counts; Calendar none

### Manage
- [ ] Todo Manage reachable from gear; includes Settings; create still works
- [ ] Journal Manage dialog exists with create / rename / color / settings / delete
- [ ] Calendar Manage dialog exists with create / rename / color / delete
- [ ] No nested kebab on switcher rows

### Behavior
- [ ] All-scope persistence and filing-target rules unchanged
- [ ] Journal select / create still opens fresh entry correctly
- [ ] Calendar all-view closed label shows **All calendars**
- [ ] Empty Todo still offers create via Manage

### Cleanup
- [ ] `rounded_dropdown.dart` removed
- [ ] Tests updated; `voyager_dropdown_button` untouched
- [ ] `FEEDBACK.md` calendar all-view label item marked done when verified

---

## 11. References

| Doc / code | Role |
|------------|------|
| `RANKINGS_UI.md` §2.2 | Category trigger + popover north star |
| `lib/features/rankings/rankings_header.dart` (`_CategoryTrigger`) | Concrete interaction reference |
| `lib/features/todo/todo_manage_sheet.dart` | Todo Manage template to promote + extend |
| `lib/core/widgets/voyager_menu_catalog.dart` | Settings vs calendar-without-settings catalog split |
| `lib/core/widgets/voyager_dropdown_button.dart` | Unrelated; do not delete |
| `DESIGN.md` | Instrument chrome vs canvas; anti-Material select |
| `FEEDBACK.md` | All-calendars view should match switcher label |
