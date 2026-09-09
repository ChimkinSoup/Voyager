# Rankings — UI/UX Redesign HLD

Visual and interaction redesign for the Rankings page. **North star: the Jobs page** — stats band + toolbar + structured list + side panel. Domain rules, data model, sync, and scoring logic remain in `RANKINGS.md`; this document supersedes `RANKINGS.md` §2 (category picker) and §3 (page layout / chrome) where they conflict.

---

## 1. Goals

- Make Rankings feel as polished and structurally composed as Jobs — not just the same font and palette.
- Adopt shared Voyager surface treatment (`VoyagerListItemSurface`, `ContextMenuRegion`, Jobs panel chrome).
- Preserve per-category accent color throughout chips, stats, stars, and field dividers.
- Fix known bugs in sort/filter popovers, header layout shift, gallery hover, and panel chrome.
- Keep v1 scope boundaries: no duplicate entry, no move-to-category, no global search indexing, no keyboard shortcuts.

---

## 2. Page chrome

### 2.1 Two-tier layout (Jobs pattern)

```
┌─────────────────────────────────────────────────────────────┐
│  STATS BAND  (~76px)                                        │
│  [category switcher]  [hero stats]  [status chips]          │
├─────────────────────────────────────────────────────────────┤
│  TOOLBAR                                                    │
│  [search ─────────────────────]  [Sort] [Filter] [Manage]   │
├─────────────────────────────────────────────────────────────┤
│  LIST (queue + ranked sections)          │  EDIT PANEL      │
│                                          │  (left border)   │
└─────────────────────────────────────────────────────────────┘
```

- **No** dedicated horizontal category strip tier.
- **No** full-width hard `Divider` between chrome and body — separation via spacing and tonal layering only.
- `SyncConflictBanner` at top of page body (same placement as Todo), above stats band.
- `GlassButton` FAB: **Add** entry (unchanged behavior).
- Side panel animation and width (`420px`, 220ms) unchanged.

### 2.2 Category switcher (stats-band)

Replace the reorderable horizontal strip.

| Element | Behavior |
|--------|----------|
| **Trigger** | Left side of stats band: category icon + name, category accent color |
| **Interaction** | Click opens `ContextualPopover` listing all **active** categories (icon, name, entry count) |
| **Selection** | Tap a row to switch category |
| **Reorder** | **Manage sheet only** — not in daily chrome |
| **Create** | Via Manage sheet or empty-state CTA (not a `+` on the strip) |
| **Archived** | Reachable only through Manage; view-only banner unchanged |

Typical use: fewer than five categories — popover is sufficient.

---

## 3. Stats band

### 3.1 Hero stats (left of center)

| Element | Behavior |
|--------|----------|
| **Ranked count** | `headlineMedium`-weight integer — primary anchor (like Jobs lifetime total) |
| **Average score** | Sublabel beneath count; `—` when no ranked items in scope |
| **Scope** | Reflects **current search + all active filters + status chips** (not raw category totals) |
| **Layout** | **Fixed-width slots** for count and average so value changes never shift adjacent chrome |

Half-star rounding for displayed average follows existing `formatRankingScore` / `roundRankingScore` rules.

### 3.2 Status chips (Jobs-style)

| Chip | Role |
|------|------|
| **In progress** | Toggle filter; multi-select like Jobs |
| **Queued** | Toggle filter; multi-select like Jobs |

**Not a chip:** ranked count lives only in the hero block.

| Rule | Behavior |
|------|----------|
| **Toggle** | Tap adds/removes from active chip set; empty set = show all (Jobs semantics) |
| **Counts on chips** | Reflect current **search + filter popover** scope (AND-combined with chip selection) |
| **Zero count** | Show chip at `0` (copy Jobs) |
| **Accent** | Category color for chip border/fill when active |
| **Filtering** | Chips narrow the **unranked** section only; ranked rows always pass status filter |

### 3.3 Right side

Leave empty (no sparkline, no distribution chart).

---

## 4. Toolbar

| Element | Behavior |
|--------|----------|
| **Search** | Slightly taller than today (`~36–40px` field height); **global app accent** on focus/border — not category color |
| **Sort** | `SelectorPill` + `ContextualPopover` (unchanged sort modes from `RANKINGS.md` §6.2) |
| **Filter** | `SelectorPill` + `ContextualPopover` — score range, has images, tag only |
| **Manage** | Icon button → Manage sheet (Jobs toolbar pattern) |

### 4.1 Filter popover contents

- Score range slider
- Has images checkbox
- Tag list — **structured tags only**, rendered bare (`rom-com`, no `#`), single-select. Note `#tags` are deliberately absent: the list is the same vocabulary the rows print, and a filter with no chip anywhere to answer it cannot be reasoned about
- **Clear filters** action at bottom when any popover filter is active — clears score range, has images, and tag only

**Removed from filter popover:** status checkboxes (replaced by stats-band chips).

**No Clear button in the toolbar row** — avoids layout shift when filters activate.

Search is cleared by editing the field; no dedicated toolbar Clear for search (differs from Jobs — intentional, to keep toolbar stable).

### 4.2 Sort / filter popover bugs (must fix)

Popovers must **rebuild reactively** when the underlying category sort or filter state changes:

- Toggling Ascending ↔ Descending updates the label immediately without closing.
- Selecting a different sort key (Score, Created, Updated, custom field) shows the correct selected checkmark immediately.
- Filter popover reflects current slider/checkbox/tag state on every rebuild while open.

---

## 5. Filtering & search (combined logic)

All narrowing is **AND-combined:**

```
visible parents = category parents
  ∩ search match
  ∩ filter popover (score range, has images, tag)
  ∩ status chips (unranked only)
  ∩ custom-field sort exclusion (ranked section only, unchanged)
```

### 5.1 Score range + queue

When **any** score-range constraint is active (not the full default range):

- **Hide the entire Queue section** — including its header and collapse chevron.
- Only the **Ranked** section is shown (subject to other filters).

Rationale: unranked parents have no overall score; hiding the queue avoids ambiguity.

When score range returns to default (full range), queue section reappears if it has visible rows.

### 5.2 Stats and chips under filters

Hero ranked count, average, and chip counts all recompute against the **search + filter popover** scope. Chip active/inactive state is independent (user toggles); counts on chips update as search/filters narrow the pool.

---

## 6. List sections

### 6.1 Queue

| Element | Behavior |
|--------|----------|
| **Header** | Sentence case: `Queue` + count `(N)` in muted `labelSmall` |
| **Collapse** | Chevron on header toggles section body visibility |
| **Persistence** | Collapsed state **per category**, stored in app settings and **synced** across devices (follow Jobs/Todo page-pref patterns) |
| **Default** | Expanded |
| **Rows** | Unranked parents (in progress above queued — unchanged sort rules) |
| **Empty** | Hide section header entirely when zero visible rows (filter/search/chip) |

### 6.2 Ranked

| Element | Behavior |
|--------|----------|
| **Header** | Sentence case: `Ranked` + optional count |
| **Rows** | Ranked parents with `VoyagerListItemSurface` treatment |
| **Empty** | Hide section header when zero visible rows; calm inline hint when queue has items but ranked does not (existing copy, refined placement) |
| **Rank numbers** | See §6.3 |

### 6.3 Rank numbers (overall-score sort only)

Display `#N` beside ranked rows **only when** `sortMode == overallScore`.

**Density ranking with ties** — rank reflects score tier, not visual list position:

| Scores (desc) | Display ranks |
|---------------|---------------|
| 10, 10, 10, 9, 8 | 1, —, —, 4, 5 |

Rules:

- First row of each score tier gets the tier's ordinal rank (1-based by descending score).
- Subsequent rows at the same score show no number (`—` or blank).
- **Starred rows** pinned to the top still display rank by **score tier**, not list index (a starred 5 among 10s shows `5` or `—` per tier rules, not `1`).

When sort mode is not overall score, hide rank numbers entirely.

Internal sort tie-breaking (`updatedAt`, title) is unchanged; rank display is independent.

### 6.4 Section header styling

- Sentence case (not uppercase tracking).
- Muted `onSurfaceVariant` — not category accent on the label itself.
- Extra vertical padding between Queue and Ranked blocks.

---

## 7. Parent list rows

### 7.1 Surface treatment

Use `VoyagerListItemSurface` (same family as Todo):

| State | Treatment |
|-------|-------------|
| **Resting** | Translucent surface, 14–16px radius |
| **Hover** | `_RowHoverSurface` pattern (150ms ease-out) — same as Todo |
| **Selected** (panel open) | Neutral selected surface + **category-accent focus border** — not accent-filled background |
| **Separator** | Subtle hairline or spacing between rows; no Jobs-style table columns (freeform list) |

### 7.2 Row content

Title, subtitle, fan stack, quick-rate / status chip, star — per `RANKINGS.md` §3.3.

**Subtitle does one job** (`RANKINGS_PARENT_TAGS_HLD.md` §6): structured tag chips when the entry has any, otherwise the condensed `8/12 scored`, otherwise nothing. The separate `12 episodes` token and the created date are gone from the row; two competing lines of small grey text under every title read as noise, and the date was the least of what a ranking row has to say.

**Tag chips:** at most two, in the order they were added, then a `+N` whose tooltip names the rest. Category accent at low alpha — the same family as the status chip, **not** the per-tag colours finance gives its tags, which on this page would be a second colour system arguing with the category's own. A chip click sets the tag filter (never toggles it off) and does not open the panel; `+N` is a tooltip only.

**Progress on hover:** when chips take the subtitle and the entry has children, hovering the strip reveals `8/12 scored`.

**Quick-rate:** keep hover-to-activate stars on list rows; no extra discoverability chrome.

**Live score on hover:** while hovering the quick-rate strip, the numeric score updates to preview the hovered value (matches editor behavior in §9.4).

### 7.3 Parent context menu (`ContextMenuRegion`)

Jobs menu look-and-feel via shared `ContextMenuItem` / `ContextMenuRegion`.

| Item | When shown |
|------|------------|
| **Pin / Unpin** | Always (label reflects state) |
| **Status ▸** | Unranked only — Queued / In progress (radio, check on current) |
| **Clear score** | Ranked only — demotes to in progress |
| **Open gallery** | When `imagesOnParent` or any child has images under `imagesOnChild` |
| **Delete** | Always (destructive; confirm + undo) |

**Dropped:** Open, Copy title/notes, score submenus (Set/Change score).

**Open gallery** behavior — see §10.

Read-only archived category: menu items that mutate are absent/disabled.

---

## 8. Child rows (editor panel)

### 8.1 List polish (low density)

| Change | Detail |
|--------|--------|
| **Surface** | `VoyagerListItemSurface` at 10–12px radius, tighter vertical padding (~6px) |
| **Score display** | **Number only** in list — remove star strip from child rows |
| **Unscored** | Muted `—` in fixed-width score slot (column alignment) |
| **Drag handle** | Visible on **hover only** when manual sort order is active |
| **Separators** | Hairline between children, not card borders |

### 8.2 Child context menu

| Item | When shown |
|------|------------|
| **Clear score** | When child has overall score |
| **Delete** | Always (confirm + undo) |

### 8.3 Add-child field

Increase vertical height of the **Add \<unit\>** `LabeledTextField` in the panel.

---

## 9. Editor panel

### 9.1 Panel chrome (match Jobs)

Replace `Material(color: surface)` wrapper with Jobs pattern:

```dart
Container(
  decoration: BoxDecoration(
    border: Border(left: BorderSide(color: outlineVariant @ 50%)),
  ),
  child: …,
)
```

- **No** custom panel background — content floats on the same page backdrop as the list.
- **Header:** close `×` on the **right** only (match `JobsEditPanel`).
- **Remove** trash icon from panel header — delete via context menu only.

### 9.2 Average-from-children control

| Before | After |
|--------|-------|
| Text button near parent overall score | **Calculator icon** (`PhosphorIconsRegular.calculator` or equivalent) |
| Placement | Adjacent to the child-unit section header (e.g. `Episodes` label row in `RankingsChildList`) |
| Tooltip | `Average from N scored episodes` (dynamic unit label + count) |
| Behavior | Unchanged — sets parent overall to rounded mean of scored children |

### 9.3 Overall score row (`RankingOverallRow`)

| Rule | Behavior |
|------|----------|
| **Layout** | Score **number left**, star strip **right** (full row width for stars) |
| **5 vs 10 scale** | **Same physical star size** as 10-point layout; 5-point scales have more whitespace |
| **Hover preview** | Number updates live while hovering/dragging stars |
| **Clear** | Tap the **number** to clear score (remove separate `×` button) |
| **Read-only** | Archived category — no clear, stars inactive |

### 9.4 Custom template fields (`rankings_field_editor`)

| Before | After |
|--------|-------|
| Faint tinted `BoxDecoration` per field | **No background boxes** |
| — | **Category-accent hairline** (`Divider` or 1px line) between fields |

### 9.5 Notes field

Decrease font size in the parent editor Notes `TagHighlightedTextField` (e.g. `bodySmall` or one step below current).

### 9.6 Text autosave, vim, snippets

Unchanged from `RANKINGS.md` §3.4 / §7.8.

---

## 10. Open gallery (context menu)

Aggregated read-only gallery for one parent entry.

### 10.1 Image order

1. Parent gallery images (facet order within parent)
2. Children in **saved list order** (`sortOrder`), each child's gallery images in facet order

### 10.2 Lightbox captions

Each image shows a small caption beneath it in the lightbox:

| Source | Caption |
|--------|---------|
| Parent gallery | Parent **title** |
| Child gallery | Child **name** (e.g. both images on `"ep 1"` show `"ep 1"`) |

### 10.3 Implementation notes

- Extend shared lightbox (`media_lightbox.dart`) with optional per-slide caption support — reusable beyond Rankings.
- View-only in this flow: no delete/reorder from aggregated lightbox.
- Entry from row fan stack / grid remains parent-only; context menu is the **combined** parent + children view.

---

## 11. Global media fix

### 11.1 Gallery "Add images" hover gap

**Bug:** `InkWell` on `_AddButton` in `media_gallery_strip.dart` — splash/hover highlight inset from the border, leaving an unhighlighted ring.

**Fix:** In the shared module so all consumers benefit (Rankings, Study, Todo, etc.):

- Align ink/splash bounds with the bordered container (e.g. `Material` + `InkWell` with matching `borderRadius`, or `Ink` decoration on the `Container` itself).
- Verify on empty add tile and thumbnail tiles.

---

## 12. Archived category

Unchanged from `RANKINGS.md` §7.4:

- View-only banner
- No FAB, no mutating controls, no drag-reorder
- Readable context menus only where applicable

---

## 13. Settings & persistence

| Preference | Storage |
|------------|---------|
| Queue section collapsed | Per category ID, in `AppSettings` (or rankings-specific settings map), **synced** |
| Category sort mode / direction | Existing category fields (synced) |
| Category order | Manage sheet (synced) |

Add settings fields following the `jobsIncludeArchived` / `jobsHiddenColumns` pattern.

---

## 14. Explicitly out of scope

- Duplicate parent entry
- Move entry to another category
- Global Search indexing
- Keyboard shortcuts
- Starred-only filter chip
- "Has unscored children" filter
- Category score distribution chart
- Score submenus in context menu (Set/Change score)
- **Open** action in context menu
- Rank numbers when sort ≠ overall score

---

## 15. Implementation checklist

### Layout & chrome
- [ ] Stats band + toolbar split
- [ ] Category popover switcher
- [ ] Remove category strip + hard divider
- [ ] `SyncConflictBanner`
- [ ] Fixed-width hero stat slots

### List
- [ ] `VoyagerListItemSurface` + hover on parent rows
- [ ] Queue collapse chevron + persisted state
- [ ] Section headers (sentence case, counts, hide when empty)
- [ ] Rank numbers (overall-score sort, tie density)
- [ ] Score-range-active → hide queue

### Menus
- [ ] Parent `ContextMenuRegion`
- [ ] Child `ContextMenuRegion`
- [ ] Aggregated gallery lightbox + captions

### Editor
- [ ] Jobs-style panel border (no surface fill)
- [ ] Panel header: close right, no trash
- [ ] Calculator icon by child-unit header
- [ ] `RankingOverallRow` layout + live preview + tap-to-clear
- [ ] Field divider lines (no tinted boxes)
- [ ] Taller add-child field, smaller notes font
- [ ] Child row polish (number only, hover handle)

### Bugs
- [ ] Sort popover stale state
- [ ] Filter popover stale state
- [ ] Clear filters inside filter popover only
- [ ] Gallery add-tile hover (global)

### Tests
- [ ] Stats scope under search/filter
- [ ] Queue hidden when score range constrained
- [ ] Rank number tie display
- [ ] Chip toggle + count updates
- [ ] Collapse persistence
- [ ] Context menu actions
- [ ] Popover reactive state

---

## 16. Relationship to `RANKINGS.md`

| Topic | Authority |
|-------|-----------|
| Domain model, scoring, sync, import/export | `RANKINGS.md` |
| Page layout, chrome, surfaces, menus, editor polish | **This document** |
| Category picker | **This document** (popover, not strip) |
| §3.1 header stats scope | **This document** (filter-aware) |
| §6.3 filters — status | **This document** (chips only) |
