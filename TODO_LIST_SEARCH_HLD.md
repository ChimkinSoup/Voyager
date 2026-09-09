# Todo List Search — High-Level Design

Ephemeral in-page search for the Todo page. Filters the **currently viewed task list** (single list or All tasks view) without a permanent search box. Intended for infrequent use; zero layout clutter when inactive.

---

## Goals

- Find tasks in the **current view** quickly (title, notes, subtasks).
- Avoid a dedicated always-visible search field.
- Support **Ctrl+F / Cmd+F** and a **`/search` composer command** as entry points.
- Keep behavior predictable with the existing list UI (sections, edit panel, reorder, All tasks view).

## Non-goals

- Global cross-app search (the separate Search tab remains journal-focused).
- Search modifiers / query language (`is:starred`, `due:today`, etc.).
- Persisting search state across sessions.
- Mobile-specific chrome beyond the composer command (no header search button for now).

---

## Entry points

| Trigger | Context | Behavior |
|---|---|---|
| **Ctrl+F / Cmd+F** | Anywhere on the Todo page, including when the composer or edit-panel fields are focused | Open/focus the ephemeral search bar. If a filter is already active, focus the bar and select existing query text. |
| **`/search` in composer** | Add-task composer only | Immediate handoff (see [Composer `/search` handoff](#composer-search-handoff)). |
| **Mobile / touch** | Composer only | No Ctrl+F equivalent. `/search` command is the sole entry point on touch devices. |

**Not included:** pressing `/` while focus is on the list (without a text field). List search is Ctrl+F or composer `/search` only.

---

## Ephemeral search bar

### Placement

- **Floating overlay** at the top of the task list area (Vim-style).
- Does **not** shift list layout when it appears or disappears.
- Sits above the scrollable task list, below the list dropdown header row (or visually anchored to the list viewport top).

*As built:* the bar itself never shifts the list — but once a query is actually applied, the list reserves the bar's height at its top. Without that, the auto-scroll to the first match would park that match underneath the floating bar. The reservation appears and disappears with the *filter*, not the bar, so it only ever lands in the same frame the list's contents change completely anyway.

### Contents

- Single-line text field (autofocus on open).
- **Match count** label (e.g. `3 matches`, `0 matches`, `1 match`).
- Optional **×** clear/dismiss control (in addition to Esc).

### Lifecycle

| Action | Result |
|---|---|
| Open (Ctrl+F or `/search` handoff) | Bar appears, search field focused |
| Type in search field | Live filter (debounced ~150ms, same spirit as journal Search page) |
| **Esc** (one step) | Clear query **and** close bar |
| **×** button | Same as Esc |
| Switch list or toggle All tasks view | Clear filter and close bar |
| Navigate away from Todo page | Clear filter and close bar |
| Close bar with empty query | No filter applied |

Filter is **never** left active while the bar is closed.

---

## Composer `/search` handoff

### Recognition

Trigger when the composer text matches:

```
^/search($| )
```

- `/search` alone → hand off immediately with an **empty** query.
- `/search ` → hand off with an **empty** query (trailing space consumed).
- `/search buy milk` → hand off with query **`buy milk`**.
- `/searchmilk` → **does not** trigger; treated as a normal task title prefix.

Recognition is **case-sensitive** for the command token (`/search` only).

### Handoff steps (atomic, same frame)

1. Parse query = text after `/search`, trimmed of leading space.
2. **Clear the composer** entirely (nothing is submitted as a task).
3. **Unfocus** the composer (`_taskFocusNode`).
4. Open the ephemeral search bar with the parsed query pre-filled.
5. **Focus** the search field; place caret at end of query.

### Live typing after `/search`

Handoff happens as soon as `/search` is recognized (word boundary). Any characters typed **after** that moment go into the **search bar**, not the composer, because focus has moved.

Example flow:

1. User types `/search` → handoff, empty search, focus on search bar.
2. User types ` buy milk` → query becomes `buy milk` in the search bar.

---

## Search scope

Search the tasks in the **current view** (respecting All-tasks exclusions for lists opted out of the combined view).

| Field | Searchable | Notes |
|---|---|---|
| Task **title** | Yes | Top-level tasks only in list; subtasks are not separate rows |
| Task **notes** | Yes | Notes are not fully shown on the row (icon only); match still surfaces the parent task |
| **Subtask titles** | Yes | Subtask is not listed independently; **parent task row** is shown when any subtask matches |
| List name | No | Not part of query matching |

### Matching rules

- **Case-insensitive** substring match.
- **Multi-word queries:** every whitespace-separated token must match somewhere in the task’s searchable corpus (title, notes, or any subtask title). Same AND semantics as journal search.
- A task matches if **any** of its subtasks match (parent row shown once).

### Subtask-only matches

When only a subtask (or notes) matches and the title does not:

- Parent row is still shown.
- **Title highlight** applies only to title tokens that match; subtask/notes-only matches do not fabricate title highlights.
- No notes snippet row (out of scope). The row’s existing metadata icons (note icon, subtask count) remain as-is.

---

## Completed tasks

- **Respect `hideCompletedTasks`** setting.
- In single-list view with hide-completed enabled: completed tasks are excluded from search entirely.
- In All tasks view: hide-completed does not apply today (`effectiveHideCompleted = hideCompleted && !_showAllTasks`); completed tasks remain searchable there per current page rules.
- When completed tasks are visible: search both active and completed sections; only matching rows appear in each section.

---

## Filtered list behavior

### Display

- Filter applies **after** existing sort (`sortTodoTasks` / `resolveGlobalTaskOrder`).
- Preserve **active** vs **completed** section structure; each section only shows matching tasks.
- Non-matching tasks are **hidden**, not dimmed.

### All tasks view

- Matching rows show **list name / color badge** (visual indicator of which list the task belongs to). This is display-only, not query scope.

### Highlights & navigation

| Feature | Behavior |
|---|---|
| **Title highlight** | Matching substrings in task titles use `searchHighlightedText` styling |
| **Match count** | Shown in the search bar (`N matches`) |
| **Auto-scroll** | On query change (after debounce), scroll list to the **first match** |
| **Next / previous match** | **Enter** → next match; **Shift+Enter** → previous match. Wraps at list ends. Current match receives a distinct “active match” scroll target / selection emphasis beyond title highlight. |

### Empty results

- Task list area shows an explicit **empty state** (e.g. “No tasks match”).
- Search bar still shows `0 matches`.

### Drag-reorder

- **Disabled** while any non-empty filter is active.
- Re-enable when filter is cleared.

### Add task while filtered

- Newly created tasks appear **only if they match** the current filter.
- Composer remains available; adding a non-matching task succeeds in the DB but does not appear until the filter is cleared.

### Edit panel

- Search filters the list behind the panel.
- If the open edit-panel task **no longer matches** the filter, **close the edit panel** (same as explicit close: clear selection, run panel close animation).
- Opening a task from a filtered list behaves normally.

---

## Keyboard summary

| Key | Search bar focused | Elsewhere on Todo page |
|---|---|---|
| **Ctrl+F / Cmd+F** | Focus search bar, select all text | Open search bar |
| **Esc** | Clear + close | — |
| **Enter** | Jump to next match | — |
| **Shift+Enter** | Jump to previous match | — |

**Conflict note:** Ctrl+F anywhere on the page **includes** edit-panel title/notes fields and the composer. It intentionally steals focus to list search rather than browser-style find-in-field.

**Vim `/` in edit-panel notes:** Unaffected when the user is in Vim-enabled notes editing **unless** they press Ctrl+F. Vim `/` remains field-local search.

---

## State model (page-local)

```text
_listSearchBarOpen: bool
_listSearchQuery: String          // debounced active filter
_listSearchQueryController       // immediate input
_listSearchMatchIds: List<String> // ordered match ids in display order
_listSearchActiveMatchIndex: int // for Enter / Shift+Enter navigation
```

- State lives on `_TodoPageState`; not persisted to settings or providers.
- Subtask text for matching: resolve per parent via existing subtask queries (batch/warm similarly to `_subtaskStats` where practical to avoid N+1 jank on large lists).

---

## UI wireframe (conceptual)

```text
┌─────────────────────────────────────────────────────────┐
│  [List dropdown ▼]                    [All tasks] [...]  │
├─────────────────────────────────────────────────────────┤
│ ┌─ floating search bar ─────────────────────────────┐   │
│ │ 🔍  buy milk                              3 matches ×│   │
│ └────────────────────────────────────────────────────┘   │
│                                                          │
│  ○ Buy milk for brunch        ← highlight on "milk"      │
│  ○ Buy almond milk                                     │
│  ...                                                     │
│                                                          │
│  ── Completed ──                                         │
│  ○ Bought oat milk                                       │
├─────────────────────────────────────────────────────────┤
│  [ Add task...                              ] [ Add ]    │
└─────────────────────────────────────────────────────────┘
```

When inactive, the floating bar is not in the tree.

---

## Implementation touchpoints

| Area | Change |
|---|---|
| `lib/features/todo/todo_page.dart` | Search state, filter pipeline, overlay widget, Ctrl+F shortcut, composer listener, filtered list builders, empty state, reorder guard, edit-panel close on filter mismatch, match navigation |
| `lib/core/widgets/search_highlight_text.dart` | Reuse for title highlights |
| `lib/features/todo/todo_edit_panel.dart` | No direct changes expected; panel close driven from page state |
| Tests | Composer `/search` parsing & handoff, filter logic (title/notes/subtasks, AND tokens), completed visibility, edit-panel close, reorder disabled, Ctrl+F opens bar |

---

## Edge cases checklist

| Case | Expected behavior |
|---|---|
| `/search` then Esc | Bar closes; composer empty; no filter |
| `/searchmilk` in composer | Normal task title; no handoff |
| `/Search` (wrong case) | Normal task title |
| Ctrl+F with bar already open | Refocus bar, select query |
| Filter active → switch list | Filter cleared, bar closed |
| Filter active → All tasks toggle | Filter cleared, bar closed |
| Filter hides selected task | Edit panel closes |
| Complete task while filtered | Row animates out if no longer matches (or section rules apply) |
| Subtask match, title doesn’t | Parent row visible; title not falsely highlighted |
| Hide completed + match only in completed | Empty state (completed not searched) |
| All tasks + list badge | Badge shown on matching rows |
| Drag attempt while filtered | No-op / reorder disabled |
| Add non-matching task while filtered | Task saved; row not shown until filter cleared |

---

## Decisions log

Captured from design review (2026-09-02):

1. **Triggers:** Ctrl+F / Cmd+F (anywhere on page) + composer `/search`; no `/` on list focus.
2. **Scope:** Title + notes + subtask titles → parent row.
3. **Completed:** Respect hide-completed (per existing page rules).
4. **Persistence:** Clear on Esc/×, list switch, All tasks toggle, leaving page.
5. **Placement:** Floating overlay, top of list area.
6. **Composer:** Immediate handoff at `/search` word boundary; transfer trailing query.
7. **Esc:** One step clears and closes.
8. **No results:** Empty-state message.
9. **Reorder:** Disabled while filtering.
10. **Extras:** Title highlight, match count, auto-scroll to first match, Enter/Shift+Enter navigation, list badge in All tasks view.
11. **Edit panel:** Close when open task doesn’t match filter.
12. **New task:** Visible only if it matches active filter.
13. **Mobile:** Composer `/search` only.

---

## Future considerations (explicitly deferred)

- Search icon in header for mobile discoverability.
- Notes-match snippet on row when title doesn’t match.
- Query modifiers (`starred:`, `due:`).
- `/` shortcut when list has focus (without Ctrl+F).
- Persisting last query when returning to the page.
