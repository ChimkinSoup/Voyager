# Rankings — Parent Tags & List Subtitle HLD

Structured classification tags on ranking **parents** (genre, cuisine, etc.), shown on the main parent list, plus a quieter list subtitle so tags do not make rows feel crowded.

Related: `RANKINGS.md` (§3.3 rows, §3.4 editor, §4.2 parent model, §4.5 note-derived tags, §6 filters/search, §7 lifecycle), `RANKINGS_UI.md` (§4 filter popover, §7 parent rows), Finance tags / `TagChip` (list pattern only — **not** Finance tag colors).

This document **extends / supersedes** UX and product rules in:

- `RANKINGS.md` §3.3 (row subtitle contents), §3.4 (editor field order + tag editing vs auto in-progress), §4.2 (add `tags`), §4.5 (dual tag systems), §6.1 / §6.3 (search + filter vocab), decision log “Tags” row
- `RANKINGS_UI.md` §7.1 row content (subtitle / chips)

Domain lifecycle, sync, and soft-delete remain in `RANKINGS.md` except where this doc explicitly carves out tag edits.

Status: **implemented** (2026-09-06).

Departures from the design below, both settled during the build:

- **Chip text carries no `#`** — on the row and in the filter list alike. The hash is what a note tag looks like, and these are deliberately the other system; the filter popover's `#$tag` rendering was changed to match.
- **The cap hint stands rather than fires.** §4.2 offers a hint after a refused eleventh tag; the field instead closes its input at ten and prints `Maximum 10 tags` under it for as long as the list is full, so the box explains why it is dead instead of only reacting to a keystroke that was already thrown away.

One rule cost no code: §5.3's carve-out. `_promotesToInProgress` in `ranking_queries.dart` promotes on `notes`, `fieldValues` and `createdAt` only, so `tags` sitting outside that set gives the exception for free — pinned by a test rather than a branch.

---

## 1. Goals

- Let users tag parents for classification (`rom-com`, `thai`, `horror`) without stuffing that into notes.
- Show those tags on the **main dashboard parent list**.
- Keep note `#tags` as freeform annotation (searchable); do not paint them on the row.
- Quiet the list subtitle so progress + tags do not compete.
- Filter by one structured tag (v1), including by clicking a row chip.
- Stay category-local and visually tied to Rankings chrome (category accent / neutral — not Finance rainbow).

## 2. Non-goals (v1)

- Structured tags on **children**
- True multi-word tags with spaces (`rom com`) — hyphenated tokens only (`rom-com`)
- Multi-tag filter (AND/OR of several tags)
- Auto-promoting note `#tags` into structured tags
- Cross-category / Journal / Finance tag pools
- Per-tag color picker or `tagColorsProvider` on Rankings
- Rename / merge tags across the category
- Stats / sort / group-by tag
- Bulk retag
- Fixed category taxonomies / preset genre lists
- Clicking `+N` to filter or expand inline (tooltip only)

---

## 3. Product decisions (locked)

| Decision | Choice |
|----------|--------|
| **Storage** | `RankingParent.tags: List<String>` (no leading `#`) |
| **Panel order** | Title → Overall score → **Tags** → (status pills if unranked) → custom fields → notes → … |
| **Token shape** | Hyphen convention only: same family as journal tags — `\w+(?:-\w+)*` after stripping `#` |
| **Cap** | Max **10** tags per parent |
| **Row display** | Max **2** chips + `+N` when more; empty list → **no** chips / no placeholder |
| **Subtitle job** | **One job:** tags **or** condensed progress — never both at full length |
| **Condensed progress** | `y/x scored` (drop the separate `x episodes` token and `createdAt`) |
| **Hover when tags show** | Tooltip reveals condensed progress (`y/x scored`) when children exist |
| **Filter vocab** | **Structured tags only** (category-local) |
| **Filter arity** | Single active tag (existing filter popover behavior) |
| **Row chip click** | Sets that tag as the active filter; if already active, **leave it on** (no toggle-off) |
| **Clear filter** | Existing filter-popover **Clear filters** (and any existing clear path) — not by re-clicking the row chip |
| **Note `#tags`** | Remain in notes; searchable; **not** on the row; **not** in filter chip list |
| **Dual match** | Same name in structured + notes → **one** search/filter match; only structured shows on the row |
| **Auto in-progress** | Tag-only edits do **not** promote `queued` → `inProgress` |
| **Chip look** | Category accent / neutral Rankings chips — **not** Finance `tagColors` |
| **Suggestions** | Category-local structured tags from other parents, usage-ranked |
| **Migration** | Existing parents get `tags: []`; no backfill from notes |

---

## 4. Domain model

### 4.1 `RankingParent`

| Field | Notes |
|-------|--------|
| `tags` | `List<String>`, default `[]`. Ordered as the user added them. Max 10. |

Not on `RankingChild` in v1. Not on `RankingCategory` (no fixed taxonomy).

### 4.2 Normalization

On add / save / import:

1. Trim; strip leading `#` characters.
2. Reject empty tokens.
3. Accept only `^[A-Za-z0-9_]+(?:-[A-Za-z0-9_]+)*$` (journal-style hyphenated words; no spaces, no leading/trailing hyphen).
4. Equality is **case-insensitive**; store a single canonical form (prefer **lowercase** for stability across devices).
5. Dedupe within the parent (case-insensitive).
6. If adding would exceed 10, keep the first 10 after dedupe; ignore the rest (panel may toast or silently drop — prefer a short inline hint: “Maximum 10 tags”).

Invalid paste fragments (spaces, punctuation) are dropped, not auto-joined with hyphens.

### 4.3 Dual systems (structured vs notes)

| | Structured `parent.tags` | Note `#tags` |
|--|--------------------------|--------------|
| Stored on | Parent field | Markdown in `notes` (parent/child) |
| Row chips | Yes | No |
| Filter popover list | Yes | No |
| Search haystack | Yes | Yes (unchanged) |
| Filter match | Yes | **No** for the dedicated tag filter in v1 (structured-only) |

**Search:** a query token that matches a structured tag name or a note `#tag` still surfaces the parent (existing substring / multi-token rules). If both systems contain `thai`, that is still one parent hit.

**Tag filter (popover or row chip):** matches parents whose **structured** `tags` contain the selected tag only. A parent with only `#thai` in notes does **not** pass a structured `thai` filter. (Search remains the way to find note-only tags.)

Rationale: filter chips are the same vocabulary as row chips; note-only tags must not appear “filterable but invisible on the row.”

---

## 5. Editor panel

### 5.1 Placement

```
Title
Overall score   (+ clear)
Tags            ← new
[Queued | In progress]   ← unranked only
Custom fields…
Notes
Gallery…
Children…
```

### 5.2 Input UX

- Compact tags control under overall score (Finance-like field or chip + text entry).
- User types a token; commit on **Enter**, **comma**, or blur of a completed token.
- Optional leading `#` is stripped on commit.
- Suggestions popover: structured tags already used by parents in **this category**, ranked by usage; filter as the user types.
- Remove via chip × or backspace on the last chip (match existing Voyager chip-field patterns where present).
- Read-only when the category is archived (same as other panel fields).

### 5.3 Lifecycle carve-out

Today, any non-title edit promotes `queued` → `inProgress`. **Exception:**

- Saves that change **only** `tags` (and `updatedAt` / version / sync bookkeeping) **must not** change `status`.
- Mixing tag edits with any other non-title field in the same save **does** promote (normal rule).

Tag edits still bump `updatedAt` and sync like any other parent mutation.

---

## 6. Parent list row

### 6.1 Subtitle — one job

| Condition | Subtitle |
|-----------|----------|
| `tags` non-empty | Up to **2** chips + `+N` if `tags.length > 2` |
| `tags` empty **and** children enabled **and** `total > 0` | Condensed progress: `y/x scored` |
| Otherwise | No subtitle line |

**Removed from the list row (always):**

- Separate `x episodes` / `x dishes` token
- `createdAt` date string

`createdAt` remains editable in the panel and available to sort/search as today.

### 6.2 Chips

- Visual: small chips using **category accent** at low alpha (or neutral on-surface variant) — same family as Rankings status chips, not Finance colored tags.
- Max two full chips in document order; then a `+N` overflow marker where `N = tags.length - 2`.
- `+N` hover/tooltip: remaining tag names (comma- or middot-separated). Click on `+N` does **not** set a filter (v1).
- Empty tags: render nothing (no “Add tags” ghost chip on the row).

### 6.3 Hover progress when tags are showing

When the subtitle is tags **and** the category has child units with `total > 0`:

- Hovering the **subtitle / chip row** (or the tag strip) shows a tooltip: `y/x scored`.
- If there are no children, no progress tooltip.

### 6.4 Chip → filter

- Clicking a **tag chip** on a row sets the category’s active tag filter to that tag (same state as the filter popover).
- If that tag is **already** the active filter, leave it active (idempotent; not a toggle).
- Clearing the tag filter is only via the filter UI’s clear path.
- Chip click must not open the edit panel (stop propagation from the row `onTap`).
- Archived / view-only categories: chips remain visible; click-to-filter still OK (filter is view state); editing tags remains blocked in the panel.

---

## 7. Search, sort, filters

### 7.1 Search (`RANKINGS.md` §6.1)

Extend the parent haystack with structured tag names (joined or as separate searchable strings). Note `#tags` behavior unchanged. Multi-token AND rules unchanged.

### 7.2 Filter popover

- Tag list = sorted unique structured tags among **non-deleted** parents in the category.
- Soft-deleted parents’ tags disappear from the vocab until restore (same spirit as today’s note-tag filter).
- Single-select tag filter; AND with score range, has-images, search, status chips.
- **Clear filters** clears the tag selection along with other popover filters.

### 7.3 Sort

No sort-by-tag in v1.

---

## 8. Sync, import/export, persistence

- Include `tags` on parent documents in Drift / Firestore mapper / remote sync / full-app import-export.
- Missing field on old payloads → `[]`.
- Soft-delete / restore: tags travel with the parent; vocab membership follows delete state (§7.2).
- No new Firestore collection; tags are a field on the parent record.

---

## 9. Behaviors & edge cases

| Case | Behavior |
|------|----------|
| Duplicate tag on one parent | Ignored (case-insensitive) |
| `Thai` vs `thai` across parents | One vocab entry; stored lowercase |
| `rom com` typed | Rejected / not committed (space illegal); user must use `rom-com` |
| `#thai` committed in tags field | Stored as `thai` |
| Only `#thai` in notes, filter = `thai` | Parent **excluded** (structured-only filter) |
| Structured `thai` + note `#thai` | One search hit; one filter hit; one row chip |
| 11th tag | Not added; hint at max 10 |
| Tag-only edit while queued | Stays queued |
| Tag edit + notes edit while queued | Promotes to in progress |
| Soft-deleted parent | Chips gone from list; tags out of filter vocab |
| Restore parent | Tags and vocab membership return |
| Zero children | No `y/x scored` subtitle; tags still show if present |
| Children enabled, 0 children | No progress subtitle |
| Click chip then Clear filters | Tag filter cleared; list widens again |
| Click chip A then chip B | Active filter becomes B |
| Click chip A twice | Filter remains A |

---

## 10. Acceptance criteria

1. Parent panel order is Title → Overall → Tags → rest.
2. User can add/remove up to 10 hyphenated structured tags; invalid tokens never persist.
3. List shows ≤2 chips + `+N`; empty tags show no chip UI.
4. Subtitle is either tags **or** `y/x scored`, never the old triple (`episodes · scored · date`).
5. `createdAt` is not shown on the list row.
6. When tags are showing and children exist, hover reveals `y/x scored`.
7. Filter popover lists structured tags only; one active tag.
8. Row chip click sets that filter; re-click leaves it on; clear only via filter clear.
9. Note `#tags` never appear as row chips or filter-list entries; search still finds them.
10. Tag-only saves do not promote queued → in progress.
11. Chips use Rankings category accent / neutral styling (not Finance tag colors).
12. Sync + import/export round-trip `tags`; legacy docs load as `[]`.

---

## 11. Implementation sketch (non-binding)

| Area | Likely touchpoints |
|------|--------------------|
| Model | `ranking_models.dart` (`RankingParent`) |
| DB / sync / I-O | Drift schema + mapper, Firestore document mapper, import/export |
| Queries | `ranking_queries.dart` — tag vocab, filter match, search haystack; carve tag-only out of promote helpers if centralized |
| Panel | `rankings_edit_panel.dart` — tags control after overall |
| Row | `rankings_row.dart` — subtitle rewrite, chips, tooltip, chip tap → filter |
| Header / filters | `rankings_header.dart` — structured-only tag list |
| Actions | `rankings_actions.dart` — save path that skips status promote on tag-only diffs |
| Tests | Model normalize, filter/search dual-tag cases, promote carve-out, row subtitle cases |

---

## 12. Decision log (this feature)

| Topic | Decision |
|-------|----------|
| Structured vs notes | Both kept; row + filter = structured only |
| Multi-word | Hyphen only (`rom-com`); no spaces |
| Cap | 10 stored; 2 + `+N` on row |
| Subtitle | One job; progress = `y/x scored`; drop episodes token + list `createdAt` |
| Progress + tags | Tooltip on hover when tags win the subtitle |
| Promote on tag edit | **No** |
| Chip re-click | Leave filter on |
| Chip colors | Category accent / neutral |
| Children tags | Out of scope v1 |
| Note → structured migrate | No |
