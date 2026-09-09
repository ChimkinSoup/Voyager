# Todo — Edit Panel UI Alignment HLD

Visual and interaction alignment for the Todo page's right-hand edit panel. **North star: the Jobs and Rankings editor panels** — transparent chrome, close-only header, autosave-only commit, shared field metrics. Domain rules, data model, sync, sorting, and recurrence logic are unchanged.

This document captures product decisions from the 2026-08-31 design review. Implementation should follow existing Voyager patterns in `jobs_edit_panel.dart` and `rankings_edit_panel.dart` unless noted below.

---

## 1. Goals

- Make the Todo edit panel feel like the same surface family as Jobs and Rankings — not a separate opaque card.
- Adopt shared panel chrome (transparent fill, soft left border, compact header, `VoyagerScrollView` body).
- Preserve Todo-specific behavior that Jobs/Rankings do not have: subtask reorder, recurrence, media gallery, list-move corner flag, enter-to-close, and a read-only created-date footer.
- Add an in-panel completion toggle (the one new feature in scope).
- Apply two small cross-panel consistency fixes: Jobs notes height → 120px; Jobs notes typography → `bodySmall`.

### Out of scope

- Page-level chrome redesign (stats band, toolbar, etc.).
- Task history / activity timeline.
- Duplicate task, tag filtering, calendar linking, archive/snooze, or other feature suggestions from the review.
- Rankings notes layout changes (stays `minLines: 4`, `maxLines: 14`).

---

## 2. Panel chrome

### 2.1 Background and border

Replace the current `Material(color: theme.colorScheme.surface)` wrapper with the Jobs/Rankings pattern:

```dart
Container(
  decoration: BoxDecoration(
    border: Border(
      left: BorderSide(
        color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
      ),
    ),
  ),
  child: …,
)
```

| Rule | Behavior |
|------|----------|
| **Background** | No panel fill — content floats on the same page backdrop as the task list |
| **Left border** | `outlineVariant` at 50% opacity (not `theme.dividerColor`) |
| **Width** | Unchanged: `420px` (`_todoEditPanelWidth`) |
| **Elevation** | None |

### 2.2 Padding

| Region | Padding |
|--------|---------|
| **Header** | `EdgeInsets.fromLTRB(8, 8, 8, 0)` — match `_PanelHeader` in Jobs/Rankings |
| **Scroll body** | `EdgeInsets.fromLTRB(16, 12, 16, 16)` — top inset clears the title field's floating label (same rationale as Rankings §9.1) |
| **Footer** | Created-date block sits below the scroll body with existing divider spacing |

Remove the current uniform `20px` panel padding.

---

## 3. Header

### 3.1 Close only

Match `JobsEditPanel._PanelHeader` / `RankingsEditPanel._PanelHeader`:

- Single compact `×` `IconButton` on the **right** (`iconSize: 16`, `VisualDensity.compact`).
- **No** panel title (`"Edit task"` is removed).
- **No** star button in the header.
- **No** delete button in the header.

Star and delete remain available on the **row context menu** (already present today). Removing them from the panel header is a relocation, not a feature removal.

### 3.2 Shared header widget (optional)

Extracting a shared `EditPanelHeader` in `lib/core/widgets/` is acceptable but not required — duplicating the 15-line `_PanelHeader` inline is fine if scope stays small.

---

## 4. Body layout

### 4.1 Structure

```
┌──────────────────────────────┐
│                        [×]   │  ← header (fixed)
├──────────────────────────────┤
│  [scrollable fields …]       │
│                              │  ← VoyagerScrollView (or hybrid, §4.2)
│  ─────────────────────────   │
│  Created Aug 31, 2026 …      │  ← footer (fixed)
└──────────────────────────────┘
```

Top level:

```dart
Column(
  children: [
    _PanelHeader(onClose: …),
    Expanded(child: /* body */),
    /* footer: Divider + created text */,
  ],
)
```

### 4.2 Scroll vs. subtask list

The panel has a `ReorderableListView` for subtasks that needs meaningful vertical space. Use a **hybrid** layout rather than putting subtasks inside an unbounded scroll:

```
Expanded(
  child: Column(
    children: [
      Expanded(
        flex: 0, // or Flexible — top section sizes to content up to a cap
        child: VoyagerScrollView(
          child: Column(/* title, completion, due/repeat, notes, media, add-subtask */),
        ),
      ),
      Expanded(
        child: ReorderableListView(/* subtasks */),
      ),
    ],
  ),
)
```

Practical approach for implementation:

1. **Top block** (`VoyagerScrollView`): title, completion toggle, due/repeat row, notes (120px), media strip, add-subtask field.
2. **Bottom block** (`Expanded`): subtask `ReorderableListView` (unchanged reorder/drag behavior).
3. **Footer** (outside `Expanded`): `Divider` + created-date text.

If the top block's intrinsic height is small on short viewports, the scroll view still absorbs overflow; the subtask list always receives the remaining height.

### 4.3 Footer (unchanged purpose)

Keep the existing footer pattern:

| Element | Behavior |
|---------|----------|
| **Divider** | `Divider(height: 24)` above metadata |
| **Created text** | `Created {formatted createdAt}` in `bodySmall`, muted `onSurface` at ~60% |
| **Not a pill** | Creation date is read-only; unlike Rankings `createdAt`, it is not editable and should not become a `SelectorPill` |

**Remove** the bottom `GlassButton` labeled `"Save"`.

---

## 5. Fields and typography

### 5.1 Shared field padding

Align Todo panel fields to `jobsFieldContentPadding`:

```dart
const EdgeInsets.symmetric(horizontal: 14, vertical: 14);
```

Apply to `LabeledTextField` instances in the Todo panel (title, add-subtask). Notes use the same horizontal inset via `TagHighlightedTextField` content padding if configurable; otherwise match visually.

Remove Todo-specific `borderRadius: 12` overrides unless needed for a field that does not use the shared notched border — prefer default field chrome.

### 5.2 Title field

| Rule | Behavior |
|------|----------|
| **Height** | `allowShortHeight: true` on `LabeledTextField` (Rankings pattern) |
| **Rationale** | Panel opens on the title; default min height wastes vertical space |

### 5.3 Notes field

| Panel | Before | After |
|-------|--------|-------|
| **Todo** | `LabeledTextField`, default body size, 120px tall | `TagHighlightedTextField`, `bodySmall`, **120px** tall (`SizedBox(height: 120)`) |
| **Jobs** | `TagHighlightedTextField`, default size, 180px tall | `TagHighlightedTextField`, `bodySmall`, **120px** tall |
| **Rankings** | `TagHighlightedTextField`, `bodySmall`, flexible lines | **Unchanged** (`minLines: 4`, `maxLines: 14`) |

Todo notes retain existing CRDT / remote-sync wiring (`_handleNotesChanged`, `PendingTextMergeListener`, etc.) — only the widget and style change.

### 5.4 Everything else

Due date pill, repeat icon button, list corner flag, media gallery strip, and subtask rows: **unchanged** in behavior. Subtask checkboxes keep list accent color.

---

## 6. Save and close behavior

### 6.1 Autosave only

| Rule | Behavior |
|------|----------|
| **Debounce** | Keep `_saveDebounce = 400ms` for title and notes |
| **Explicit Save button** | **Removed** — no `GlassButton(label: 'Save')` in footer |
| **Close** | Close button and dispose/lifecycle flush still persist pending text (existing behavior) |
| **Picker saves** | Due date, repeat, list move: immediate save (unchanged) |

### 6.2 Enter to close — keep

| Rule | Behavior |
|------|----------|
| **`EnterToSubmitScope`** | Keep wrapping the panel |
| **Enter in notes** | Close panel when Enter pressed and not on a list line (unchanged) |
| **Enter in title** | Focus notes (unchanged via `onSubmitted`) |

---

## 7. New feature: completion toggle in panel

### 7.1 Placement

Add a completion control in the scrollable top block, **directly below the title field** (above due/repeat row).

Suggested UI: checkbox + label row matching the subtask row checkbox styling (`activeColor: listAccentColor`, compact density). Label: `"Completed"` or empty (checkbox alone is sufficient if space is tight).

### 7.2 Behavior

| Rule | Behavior |
|------|----------|
| **Action** | Toggle `task.completed` via the same code path as the list row checkbox (`_toggleTask` / completion queue on `TodoPage`) |
| **Optimistic UI** | Panel checkbox reflects `widget.task.completed`; page passes updated task via `onTaskOptimistic` or panel watches refreshed task on `didUpdateWidget` |
| **Subtasks** | N/A — completion toggle applies to the **parent task** only |
| **Animation** | Reuse row completion animation semantics where practical (strike-through is row-only; panel checkbox can be instant) |
| **Context menu** | Keep existing "Mark as completed / Mark as incomplete" menu items on the row |

### 7.3 API changes

`TodoEditPanel` gains something like:

```dart
final ValueChanged<bool> onToggleCompleted;
```

Remove `onToggleStar` from the panel — star is context-menu-only after this change.

---

## 8. List row selection (panel open)

When the edit panel is open on a task, the corresponding list row should use an **accent-colored selection border**, matching Rankings §7.1:

```dart
// In _RowHoverSurface or equivalent:
if (selected) {
  return base.copyWith(
    border: Border.all(color: listAccentColor.withValues(alpha: 0.7)),
  );
}
```

| Rule | Behavior |
|------|----------|
| **Accent source** | The task's list color (`listColor` / `_listColorFor`) |
| **Resting surface** | Keep `VoyagerListItemSurface` selected state underneath |
| **Hover** | Unchanged `_RowHoverSurface` behavior |

Applies in active, completed, and all-tasks views wherever `_TaskRow` receives `isSelected: true`.

---

## 9. Panel animation

| Setting | Before | After |
|---------|--------|-------|
| **Duration** | `270ms` (`_todoEditPanelDuration`) | **`220ms`** — match Jobs (`jobs_page.dart`) and Rankings (`RANKINGS_UI.md` §2.1) |
| **Curve** | Existing `CurvedAnimation` curve | Unchanged unless it feels mismatched at 220ms — reassess during implementation |
| **Dev flag** | `DevFlags.slowTodoEditPanelAnimation` | Keep; still multiplies the base duration |

---

## 10. Files to touch

| File | Changes |
|------|---------|
| `lib/features/todo/todo_edit_panel.dart` | Chrome, header, layout, fields, remove Save, completion toggle, remove `onToggleStar` |
| `lib/features/todo/todo_page.dart` | Animation duration, accent selection border, wire `onToggleCompleted`, remove `onToggleStar` from panel |
| `lib/features/jobs/jobs_edit_panel.dart` | Notes `height: 120`, `style: bodySmall` |
| `test/todo_*` | Update any tests asserting Save button, header actions, or panel surface |
| `test/jobs_editor_layout_test.dart` | Update if notes height is asserted |

### Optional extraction

| File | Changes |
|------|---------|
| `lib/core/widgets/edit_panel_header.dart` | Shared close-only header (if worth deduplicating) |

---

## 11. Acceptance criteria

### Panel chrome
- [ ] No opaque `surface` fill behind the panel
- [ ] Left border uses `outlineVariant @ 50%`
- [ ] Header is close-only; no title, star, or delete
- [ ] Padding matches Jobs/Rankings header + scroll insets

### Layout and fields
- [ ] Top fields scroll; subtask list fills remaining height
- [ ] Title uses `allowShortHeight: true`
- [ ] Notes use `TagHighlightedTextField` at 120px with `bodySmall`
- [ ] Field content padding aligned to `jobsFieldContentPadding`
- [ ] Footer keeps `Divider` + read-only `Created …` text
- [ ] No Save button

### Behavior
- [ ] Autosave unchanged; close/dispose still flushes pending edits
- [ ] Enter-to-close still works from notes
- [ ] Completion toggle in panel marks task complete/incomplete
- [ ] Star and delete reachable from row context menu only
- [ ] Panel animation is 220ms

### List
- [ ] Selected row (panel open) shows list-accent border at 70% opacity

### Cross-panel (Jobs)
- [ ] Jobs notes box is 120px tall with `bodySmall` typography

### Regression
- [ ] Subtask reorder, recurrence, media paste, list-move flag, remote notes sync all still work
- [ ] Panel close animation does not lose debounced title/notes (existing dispose flush)

---

## 12. Decision log

| # | Decision | Rationale |
|---|----------|-----------|
| 1 | Transparent panel background | Matches Jobs/Rankings; list and panel read as one page |
| 2 | Softer left border | Hairline separator, not a hard divider |
| 3 | Reduced padding | Less visual weight |
| 4–6 | Close-only header | Panel edits what's already selected; actions live on the row |
| 5 | Star/delete → context menu | Already on row menu; header was redundant |
| 7 | `VoyagerScrollView` + subtask `Expanded` | Scroll fields without breaking reorder list |
| 8 | Notes 120px (Todo + Jobs); Rankings unchanged | Todo height is canonical for fixed notes; Rankings flexible layout stays |
| 9, 16 | Created footer text, not pill | Read-only metadata; pill implies editability |
| 10–11 | `TagHighlightedTextField` + `bodySmall` | Journal/Jobs notes parity |
| 12–13 | Shared padding + compact title | Visual consistency across editor panels |
| 14 | Remove Save button | Autosave-only commit model |
| 15 | Keep enter-to-close | Todo-specific affordance worth preserving |
| 17 | No history section | Deferred |
| 18 | 220ms animation | Match Jobs/Rankings timing |
| 19 | Accent selection border | Clear panel↔row link, Rankings pattern |
| F1 | Completion toggle in panel | Quick mark-done without closing panel or opening context menu |

---

## 13. Explicitly out of scope

- Duplicate task
- Task activity / history timeline
- Tag-based list filtering
- Calendar event linking
- Archive / snooze
- Panel read-only mode for completed tasks
- Rankings editor changes beyond what is already shipped
- Todo page-level layout redesign (dropdown, composer, sections)
