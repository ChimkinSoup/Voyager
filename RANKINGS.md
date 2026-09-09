# Rankings — High Level Design

Personal ranking tracker for anything with a category → parent → optional child structure (shows/episodes, restaurants/dishes, etc.). Offline-first, fully synced, included in full app import/export. Gallery images via the shared media module.

---

## 1. Purpose

Give the user a modular place to:

- Define **categories** (e.g. Shows, Restaurants) with their own templates, colors, icons, and optional child units
- Track **parent entries** (a show, a restaurant) with overall score, notes, custom scored fields, optional gallery, dates, and tags
- Optionally track **child units** (episodes, dishes) with their own template, overall score, notes, custom fields, and optional gallery
- Keep **queued** and **in-progress** work separate from the **ranked** list until the user assigns an overall parent score
- Analyze category-level stats (count, average score) for ranked items only

---

## 2. Shell & Navigation

- New shell destination labeled **Rankings**
- No preferred default nav order; users reorder destinations as today
- **Category-local search only** — do **not** index rankings in the global Search page (same policy as Jobs)
- Category picker: reorderable sidebar or tab strip; order **syncs** across devices
- Archived categories are hidden from the main picker; open from a **manage categories** affordance in **view-only** mode until unarchived

---

## 3. Page Layout

### 3.1 Category chrome (compact header)

Per active category, always-visible compact header:

| Element | Behavior |
|--------|----------|
| **Ranked count** | Number of parents with an overall score (ranked section only) |
| **Average overall score** | Mean of ranked parents’ overall scores (half-star aware); ranked only |
| **In-progress / queued counts** | Optional small counts for the unranked section |
| **Category search** | Category-local search bar (see §6.1) |

No starred-only filter. No min/max/stddev.

### 3.2 Category body — two sections

Each category shows **two distinct sections** (not one mixed list):

#### A. Unranked (Queue + In progress)

- Parents **without** an overall score
- Sub-order:
  1. **In progress** — always above queued, regardless of manual queue order
  2. **Queued** — manual order among queued items; in-progress trumps queued globally
- **Star** works here: starred parents pin to the **top of the unranked section** (among other stars, sort by the active sort key — default manual queue order / in-progress rules)
- When a parent gains an overall score and moves to ranked, its **star is cleared** (stars are independent per section; ranked section does not inherit unranked stars)

#### B. Ranked

- Parents **with** an overall score
- Default sort: **overall score descending**; ties by **`updatedAt` descending**
- User-chosen alternate sorts (see §6.2)
- **Star** (todo-style): starred parents pin to the **very top** of the ranked section; among multiple stars, sort by the active sort key; un-starring returns the row to its score-based position
- **Quick-rate**: tap/adjust overall score inline on the list row without opening the full editor (ranked section only)

### 3.3 Row affordances (parent)

| Affordance | Notes |
|------------|--------|
| **Title** | Required on create |
| **Overall score** | Shown when ranked; quick-rate when ranked |
| **Subtitle** | **One job** — structured tags if any, else `8/12 scored`, else nothing. See `RANKINGS_PARENT_TAGS_HLD.md` §6.1 |
| **Tag chips** | Up to 2 structured tags + `+N`; click sets the tag filter. Note `#tags` never appear here |
| **Cover images** | Fan preview when gallery enabled (see §7.5) |
| **Status chip** | `Queued` / `In progress` in unranked section |
| **Star** | Pin behavior per §3.2 |

**Not on the row:** the separate `12 episodes` count and the `createdAt` date. Both were dropped when tags took the subtitle — `createdAt` is still editable in the panel and still a sort key.

Row click opens the **todo/Jobs-style side editor panel**; a click on a tag chip filters instead and does not open it.

### 3.4 Editor panel (parent)

**Required to create:** title only

**Status**
- `queued` | `inProgress` | `ranked` (derived: ranked ⇔ overall score present)
- User may manually set **queued** or **in progress** at any time
- Auto **in progress**: any edit except **title** and **tags** (add child, edit notes, add image, change custom field, etc.) promotes `queued` → `inProgress` and moves to top of unranked **in-progress** group. Classifying something you mean to watch is not starting it, so a save that changes only `tags` leaves the status alone; tags changed alongside any other non-title field promote as usual
- Clearing overall score demotes to **in progress** (not queued)

**Fields**
- Title
- Overall score (5 or 10 scale per category parent settings; optional half-steps per parent toggle)
- **Tags** — structured classification chips, max 10 (`RANKINGS_PARENT_TAGS_HLD.md` §5)
- **Average from children** button: sets parent overall to rounded mean of children’s overall scores; **excludes** children with no overall score; rounds to parent’s allowed half-step rules; user may override manually afterward; does **not** auto-update when children change later
- Notes (markdown, journal-style; `#tags` in notes; vim + snippets enabled)
- Custom template fields (parent template — see §4.3)
- Gallery (when enabled for parent — see §4.2)
- `createdAt` (editable), `updatedAt` (system)

**Actions**
- Set overall score (required to enter ranked section)
- Archive is N/A at parent level (category archive covers hide)
- **Soft delete** with confirm + **undo** (app-wide soft-delete pattern)
- No duplicate-parent action (v1)
- No move to another category (v1)

### 3.5 Editor panel (children)

When the category enables child units:

- Flat list only (no seasons / nested groups in v1)
- **Create:** name required; everything else optional
- New child is always appended to the **bottom** of the list
- User may **drag-reorder** children manually; reorder persists as saved order
- Changing a child’s `createdAt` does **not** change list order
- View-only sort modes (score, or a specific custom field) do **not** overwrite saved manual order
- Per child: overall score, notes (markdown + `#tags`), custom fields (child template), optional gallery
- Child overall half-steps use the **child** half-star toggle (independent of parent)
- Duplicate child names under one parent: **allowed**
- Soft delete with undo; follows parent cascade rules

### 3.6 Category & template management

- **Create category**: name, color, icon; no seeds
- **Parent template** editor: add/rename/reorder/remove custom fields; toggle notes per field; set scale (5 or 10) per field; half-steps inherit from **parent overall** half-star setting
- **Child template** editor (when children enabled): separate template; child-unit label (e.g. “Episode”, “Dish”); enable/disable child gallery; same field/note/scale rules; half-steps inherit from **child overall** half-star setting
- **Orphaned fields**: removing a template field keeps stored values; template editor lists orphaned fields; clicking one **restores** that field to the template (same field id)
- **Reorder** template fields: affects display order for **all** entries (past and future) when opened in the editor
- **Rescale** a field (10↔5): **warn first**; on confirm, rescale values and round half-points; orphaned notes/values preserved if field was only toggled off
- **Archive category**: hide from main nav; entries view-only until unarchive
- **Soft-delete category**: cascade soft-delete all parents and children; **restore category** restores all cascaded entities; 30-day purge per global policy

---

## 4. Domain Model

### 4.1 RankingCategory

| Field | Notes |
|-------|--------|
| `id` | UUID |
| `name` | |
| `color` | Category chrome / picker |
| `icon` | Shell-style icon picker |
| `sortOrder` | User reorder; syncs |
| `childUnitsEnabled` | |
| `childUnitLabel` | e.g. `Episode`, `Dish` |
| `imagesOnParent` | Gallery on parents |
| `imagesOnChild` | Gallery on children (requires children enabled) |
| `parentScoreMax` | `5` or `10` |
| `childScoreMax` | `5` or `10` |
| `parentHalfStepsEnabled` | Parent overall + parent custom fields |
| `childHalfStepsEnabled` | Child overall + child custom fields |
| `parentTemplate` | Ordered field definitions (§4.3) |
| `childTemplate` | Ordered field definitions when children enabled |
| `archivedAt` | Null = active; set = archived (view-only) |
| `deletedAt` | Soft-delete |
| `createdAt` / `updatedAt` | |

No seeded categories.

### 4.2 RankingParent (entry)

| Field | Notes |
|-------|--------|
| `id` | UUID |
| `categoryId` | Immutable after create |
| `title` | Required |
| `overallScore` | Null = unranked; set = ranked |
| `notes` | Markdown |
| `tags` | Structured classification tags, no leading `#`, lowercase, max 10, user order. Distinct from note `#tags` |
| `fieldValues` | Map `fieldId → { score?, notes? }` per parent template |
| `status` | `queued` \| `inProgress` (ranked is derived from `overallScore`) |
| `starred` | Ranked-section pin only; cleared when entering ranked from unranked |
| `unrankedStarred` | Pin within unranked section (implementation may use one `starred` + section context; behavior as §3.2) |
| `queueSortOrder` | Manual order among queued (in-progress uses in-progress rules) |
| `createdAt` | Editable; display date |
| `updatedAt` | |
| `deletedAt` | Soft-delete |

**Explicitly no** `experiencedOn` / visit date in v1.

### 4.3 Template field definition (parent & child templates)

| Field | Notes |
|-------|--------|
| `id` | Stable UUID |
| `label` | Rename = display only |
| `sortOrder` | |
| `scoreMax` | `5` or `10` per field |
| `notesEnabled` | When false, UI hides notes; stored notes kept as orphaned |
| `removedAt` | Soft-remove from template; values orphaned |

**Defaults for new field on existing entries:** score = **midpoint** of field scale; notes = `""`.

**Zero custom fields** allowed on both templates (overall + notes + optional gallery only).

### 4.4 RankingChild (unit)

| Field | Notes |
|-------|--------|
| `id` | UUID |
| `parentId` | |
| `name` | Required on create |
| `overallScore` | Optional |
| `notes` | Markdown |
| `fieldValues` | Per child template |
| `sortOrder` | Manual order |
| `createdAt` / `updatedAt` | `createdAt` editable; new children append bottom |
| `deletedAt` | Soft-delete |

### 4.5 Tags (two systems, both category-scoped)

**Structured tags** — `RankingParent.tags`, the classification system:

- Stored on the parent; hyphenated tokens (`rom-com`), lowercase, max 10, no children in v1
- The only tags that appear as **row chips** and in the **filter popover**
- Searchable
- **Category-local only** — not visible to Journal or global Search
- Soft-deleted entry’s tags disappear from the filter vocabulary until restore

**Note `#tags`** — freeform annotation:

- Parsed from `#tags` in parent or child markdown notes
- **Searchable**, and nothing else: no row chip, no entry in the filter list, and they do **not** satisfy the structured tag filter
- Never auto-promoted into structured tags

Full rules in `RANKINGS_PARENT_TAGS_HLD.md` §4.3.

### 4.6 Media

- Gallery only (no inline embeds in notes) per `MEDIA.md`
- `collection`: `rankings`
- `documentId`: parent id or child id
- `facet`: `gallery`
- Respect `imagesOnParent` / `imagesOnChild`
- Soft-delete parent/child → detach refs; GC per media module (30-day purge)

---

## 5. Scoring Rules

| Rule | Behavior |
|------|----------|
| Parent overall | Manual; optional **average from children** button |
| Child overall | **In v1.** User sets manually (optional). No auto-average-from-custom-fields button (unlike parent’s average-from-children button) |
| Unranked parent | No overall score; lives in unranked section |
| Promote to ranked | Must set parent overall score |
| Demote | Clear overall score → **in progress** in unranked section |
| Average button | Mean of children with overall score; round to parent half-step rules |
| Custom field default | Midpoint when field added to template |
| Custom field half-steps | Inherit parent or child overall half-star toggle |
| Divergence | Parent overall may differ from children; **no UI warning** |
| Sort by custom field | Parents missing that field’s score are **excluded** from the ranked list while that sort is active |

---

## 6. Search, Sort & Filters

### 6.1 Category-local search

- Scope: current category only
- Fields: parent **title**, parent **notes**, parent **structured tags**, child **names**, child **notes**, and note `#tags` wherever they are written
- A name held in both systems (structured `thai` and `#thai` in notes) is still **one** hit
- Match: case-insensitive **substring**; multi-token **AND** across searchable fields (Jobs-style)
- Does **not** search global Search page
- When sorting ranked list by a custom field, parents **without** that field score are omitted from the ranked view (not the same as search — applies to sort mode)

### 6.2 Sort modes (ranked section)

| Sort | Behavior |
|------|----------|
| Overall score (default) | Desc; ties `updatedAt` desc |
| `updatedAt` | Desc |
| `createdAt` | User choice asc/desc |
| Custom field X | By that field’s score; parents missing value **excluded** |
| Starred | Pinned top; then active sort among stars |

User preference per category may persist and sync (follow existing page-prefs patterns).

### 6.3 Filters (ranked and/or unranked as noted)

- Score range (overall)
- Status: queued / in progress (unranked section)
- Has images
- Tag — **structured tags only**, category-local, one active at a time. A parent with only `#thai` in its notes does not pass a `thai` filter; search is the way to find those
- Combine with search (AND)

### 6.4 Child list (within parent)

- **Saved order**: manual `sortOrder`; new child at bottom
- **View sort** (non-destructive): by overall score, or by a specific custom field score, or by name — does not write `sortOrder`

---

## 7. Behaviors & Edge Cases

### 7.1 Queue / in-progress / ranked lifecycle

```
queued ──(non-title edit)──► inProgress ──(set overall score)──► ranked
   ▲                              │                                    │
   │                              │                                    │
   └────────(manual set queued)───┘                                    │
   ▲                                                                     │
   └──────────────────(manual set queued)──────────────────────────────┘
                                                                        │
                           (clear overall score)                        │
                                    ▼                                   │
                              inProgress ◄──────────────────────────────┘
```

- Manual **queued** from in progress: allowed; uses normal queue ordering (not auto top)
- In progress always sorts above queued in unranked section
- User may manually reorder **queued** items; in-progress block stays above

### 7.2 Stars

| Section | Behavior |
|---------|----------|
| Unranked | Star pins to top of unranked (among stars: current sort key) |
| Ranked | Star pins to top of ranked (among stars: current sort key) |
| Promote to ranked | Clear unranked star |
| Demote to unranked | Star does not auto-restore |

### 7.3 Template changes

| Change | Behavior |
|--------|----------|
| Add field | All entries get midpoint + empty notes |
| Remove field | Orphan values; restorable from template editor |
| Rename field | Display only; id unchanged |
| Reorder fields | All entries show new order in editor |
| Rescale field | Confirm dialog; rescale + round half-points |
| Toggle notes off | Hide UI; keep stored notes |
| Toggle child units off | Hide children in UI; data retained until category delete |

### 7.4 Category archive vs delete

| Action | Behavior |
|--------|----------|
| Archive | Hidden from main picker; **view-only** until unarchive; data syncs |
| Soft-delete | Cascade soft-delete parents + children; restore category restores all |
| Purge | 30-day global soft-delete retention |

### 7.5 Images (gallery)

- Paste, drag-and-drop, file picker on gallery surfaces
- **Fan preview** on list row when multiple images: show up to **5** fanned; single image shows alone
- Click fan → **scrollable grid** of all images → click one → **lightbox** with left/right navigation and **peek** of adjacent images on edges
- Full lightbox behavior per `MEDIA.md` where applicable
- Parent/child gallery independently gated by category flags

### 7.6 Delete & undo

- Soft delete parents and children (align with app default, not Jobs hard-delete)
- Confirm dialog
- **Undo** snackbar/action per existing Voyager undo pattern
- Media GC follows `MEDIA.md` refcount + 30-day purge

### 7.7 Empty states

- No categories: hint to create first category
- Empty category: hint to add first entry or queue something
- No ranked yet: calm empty ranked section copy
- Archived category: view-only banner

### 7.8 Text editing

- All markdown text fields: **vim** + **snippets** enabled (journal/todo parity)
- Note `#tags` are freeform annotation in the markdown fields; the structured classification tags are a separate field on the parent (§4.5)

---

## 8. Data, Sync & Architecture

Align with existing Voyager local-first stack:

- **Local**: Drift tables for categories, parents, children, template field defs (embedded JSON or normalized), page prefs, tag index (derived)
- **Remote**: Firestore via existing sync / CRDT / outbox patterns
- **IDs**: UUIDs
- **Soft delete**: 30-day retention; cascade on category delete; restore cascade on category restore
- **Conflicts**: last-write-wins per document
- **Feature module**: `lib/features/rankings/` + domain models, repositories, providers — same layering as jobs / todo
- **Media**: shared module; `collection = rankings`; gallery only

### Suggested entities (logical)

```
RankingCategory
RankingParent
RankingChild
RankingPagePrefs          // per-category sort, filters, column prefs if any
// MediaReference rows point at parent/child ids
```

### Import / export

- Included in **full app** export/import (categories, parents, children, templates, media binaries)
- **No** per-category-only export in v1

---

## 9. Explicitly Out of Scope (v1)

- Global Search page integration
- Move entry between categories
- Duplicate parent
- Nested child groups (seasons → episodes)
- Category-only export/import
- Compare mode (side-by-side)
- Import from external lists (Letterboxd, etc.)
- Recommendations
- URLs / links on parents
- Revisit logs (multiple visits)
- Weighted overall from custom fields (manual + average-from-children only)
- Public / private sharing
- Hide score until hover
- Bulk edit
- Min / max / stddev stats
- `experiencedOn` / last-visited date
- Child search within parent
- Cross-category tags
- Journal / todo / calendar cross-links

---

## 10. Acceptance Criteria (summary)

1. User creates categories (no seeds) with color, icon, reorderable synced list
2. Parent template + optional child template with per-field 5/10, optional notes, reorder, orphan restore
3. Parent entries: title-only create; queued / in-progress / ranked sections behave per lifecycle diagram
4. Auto in-progress on non-title edits; manual status changes; overall score required for ranked
5. Children optional per category; flat list; new at bottom; manual reorder; view-only sort
6. Parent average-from-children button with correct rounding and exclusion rules
7. Half-star toggles independent for parent vs child overall (and inherited by custom fields)
8. Stars pin in unranked and ranked sections; cleared on promote to ranked
9. Category-local search; filters; ranked sort modes including custom-field sort with exclusion
10. Gallery images per MEDIA.md; fan cap 5; grid picker; lightbox with peek
11. Markdown notes with category-scoped `#tags`; vim + snippets
12. Compact per-category stats (count, average) for ranked only
13. Child count + scored progress on parent rows; quick-rate on ranked list
14. Archive (view-only) vs soft-delete cascade + restore
15. Full app import/export includes rankings + media
16. **Rankings** shell destination; not in global Search

---

## 11. Decision Log (from product review)

| Topic | Decision |
|-------|----------|
| Hierarchy | Category → Parent entry → Child unit (optional) |
| Child units | Optional per category; user-defined label |
| Images | Category flags: parent and/or child; gallery only |
| Score scale | 5 or 10 per field; half-stars on parent/child overall (inherited by fields) |
| Parent overall | Manual + average-from-children button; stale after child edits |
| Unranked vs ranked | Separate sections; no overall score = unranked |
| Queue vs in progress | Separate ordering; in-progress always above queued |
| Auto in-progress | Any non-title edit |
| Promote | Requires parent overall score |
| Demote | Clear score → in progress |
| Templates | Two: parent + child |
| Template orphans | Keep values; restore from template editor |
| Template reorder | Applies to all entries in editor |
| Rescale field | Warn; rescale values |
| Move category | Not allowed |
| Tags | Two systems: structured `parent.tags` (chips + filter) and note `#tags` (search only); both category-scoped |
| Dates | `createdAt` editable; `updatedAt` system; no experiencedOn |
| Child order | New at bottom; manual reorder; createdAt doesn’t reorder |
| Search | Category-local only |
| Global Search | Excluded |
| Sort default | Overall desc; ties updatedAt |
| Sort by field | Exclude parents missing that field |
| Child view sort | Non-destructive |
| Stars | Both sections; cleared on promote |
| Archive category | View-only until unarchive |
| Delete category | Soft cascade; restore restores all |
| Stats | Ranked only; compact header |
| Export | Full app only |
| Media | Shared module; fan 5; grid + lightbox peek |
| Text | Markdown; vim + snippets |
| Undo | Soft-delete undo |
| Seeds | None |
