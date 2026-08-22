# Jobs — High Level Design

Job application tracker as a first-class Voyager page: pipeline board data in a flat table, company suggestions, season archives, and a compact analytics header.

---

## 1. Purpose

Give the user a single place to add, search, update, archive, and analyze job applications across custom pipeline stages — offline-first, synced across devices on the same account.

---

## 2. Shell & Navigation

- New shell destination labeled **Jobs**
- No preferred default nav order; users reorder destinations as they do today
- Jobs search is **page-local only** — do not index applications in the existing global Search page
- Calendar / todo / LeetCode / Study cross-links are **out of scope** for this design (do not implement or mention in follow-on scopes)

---

## 3. Page Layout

### 3.1 Always-visible header (compact)

Small header at the top of the page containing:

| Element | Behavior |
|--------|----------|
| **Lifetime total** | Count of all applications ever (includes archived). Plain integer — not a composite score |
| **Per-status counts** | Counts for **active (non-archived) only**, broken down by current status |
| **30-day sparkline** | New applications per day for the last 30 days (see §8) |
| **Sankey** | Conversion visualization from current statuses (see §8) |

An **Include archived** control (toggle/chip) affects sparkline, Sankey, and the main list filter set — not the lifetime total. When off (default), archived apps are hidden from the list and excluded from sparkline + Sankey. When on, they appear in the list and are included in sparkline + Sankey. Lifetime total always counts everything.

### 3.2 Main surface — flat table

- Flat list/table (not kanban)
- Default columns: **color**, **company**, **title**, **status**, **date applied**, **notes**
- Column visibility is user-togglable via a small dropdown; preference should persist locally (and sync if other UI prefs for this page sync — follow existing shell/page preference patterns)
- Notes column shows a truncated preview; full markdown lives in the editor panel
- Rows with an exact duplicate (same company + same title as another row, case-insensitive company match for the pair identity — see §7.3) show a **soft visual warning** in the table only. Warning is informational; no block on create/edit
- Row click / edit affordance opens a **todo-style side editor panel**

### 3.3 Editor panel (todo-page pattern)

Create and edit use the same panel pattern as the todo edit panel:

**Required to create**
- Company
- Title

**Defaults**
- Date applied → today (editable at create and later)
- Status → first seed stage, or the user’s preferred default if one is introduced later; initially the first stage in the user’s ordered stage list (seed: Applied)

**Fields**
- Company (smart suggestion dropdown — §5)
- Title
- Status (dropdown of user’s stages; free move to any stage, including Accepted ↔ Rejected ↔ earlier stages — never locked)
- Date applied
- Application URL (single)
- Notes (markdown, journal-style — tags may live as `#tags` inside notes; no separate tag entity for Jobs)

**Actions**
- Save / autosave per existing Voyager edit-panel conventions for similar entities
- **Duplicate application** — creates a new application copying all fields; new id; user can then edit. Date applied may remain copied (user can change); do not auto-clear fields
- **Archive / move to season** — assign to a user-named season bucket (§6)
- **Delete** — hard delete with confirm dialog (§7.4)

**Status timeline**
- Panel shows a chronological status-change history for that application (§4.2)

---

## 4. Domain Model

### 4.1 Job application

| Field | Notes |
|-------|--------|
| `id` | UUID |
| `company` | Free string as stored on the application (survives company-list deletion) |
| `title` | Free string |
| `status` | String matching a stage id/name at time of set; may become an **orphan** if stage is deleted |
| `dateApplied` | Date; sparkline buckets by this field |
| `applicationUrl` | Optional single URL |
| `notes` | Markdown string |
| `seasonId` | Null = active; set = archived into that season |
| `createdAt` / `updatedAt` | Standard metadata |
| Status history | Separate ordered records (§4.2) |

**Explicitly deferred fields** (do not add in v1): location, remote/hybrid, salary, referral, job type, source, deadlines, next-action, recruiter/contact, offer comparison.

**Duplicates allowed**: same company + title may exist as separate rows (e.g. re-apply next year). Soft table warning only (§7.3).

### 4.2 Status-change history

- Every status change appends a timeline entry: `{ fromStatus, toStatus, changedAt, optional label/note if needed later }`
- On **stage rename**: timeline keeps the **old display strings** as recorded; only the stage list label changes for future selections
- On **stage delete**: applications may keep the old status string (orphan). Timeline unchanged. UI should still render orphan statuses readably (e.g. show the string even if not in the stage list)
- Moving freely between any stages always records history; no validation that transitions are “forward”
- **Multiple interviews**: no dedicated multi-interview feature — users stay on Interview (or move away and back); timeline reflects status changes only. Extra interview detail belongs in notes if desired

### 4.3 Pipeline stages

- User-managed list: **add**, **rename**, **reorder**
- **No fixed order** for valid transitions; order is display/Sankey order only
- **Seed stages** on first use: `Applied`, `Online Assessment`, `Interview`, `Accepted`, `Rejected`
- Withdrawn / Ghosted are **not** first-class stages — fold into Rejected and/or notes
- Deleting a stage that still has applications: **allowed**; apps keep orphan status strings
- Renaming does not rewrite history entries

### 4.4 Company suggestions (global list)

- Purpose: **typing suggestions only**, not a hard FK
- Contents: **seed common companies** + **user-added** entries
- When the user commits a company name that is not already on the list (after matching rules), add it to the global suggestion list for future dropdowns
- **Sync**: global company list syncs across devices for the same user account
- **Delete suggestion**: removing a company from the suggestion list does **not** mutate past applications; their `company` strings remain as stored
- Matching in the dropdown: **case-insensitive substring** — typing `visa` surfaces `Visa Inc.`, `US Visa`, etc., so the user picks an existing suggestion instead of creating near-duplicates

### 4.5 Company categories (colors)

- Categories: user-named groups with a **single color** each
- **One category per company** (suggestion-list company → at most one category)
- Color lives on the **category**; all applications whose company string resolves to a categorized company show that color in the table
- Uncategorized / unrecognized company → **neutral default color**
- Management UI: **small popup** (not a full settings page) to create categories, pick colors, and assign companies
- Deleting a category: companies in it become uncategorized (neutral color); applications unchanged otherwise

### 4.6 Seasons (archives)

- User-named buckets (e.g. `Fall 2025`)
- Archiving an application sets `seasonId`; un-archiving clears it (back to active list)
- Default list view: archived hidden
- Analytics rules: see §8

---

## 5. Company Dropdown UX

- Combobox / typeahead over seed + user companies
- Filter: case-insensitive contains
- Selecting a suggestion fills the field with that canonical string
- Free-typing a new name on commit adds it to the global list
- Category color may optionally appear as a swatch beside suggestions when categorized (nice-to-have; not required for v1 if it complicates the popup)

---

## 6. Search & Filters

### 6.1 Search

- Scope: **title, company, notes, status**
- Match: **substring / contains** (case-insensitive). Example: query `dog` matches company/title/notes/status containing `datadog`
- Multi-token: if the user enters multiple space-separated terms, require **all** terms to match somewhere across the searchable fields (AND). A single term uses contains as above
- Does not search global Search page corpora

### 6.2 Status filter

- Optional filter by one or more statuses (chips/dropdown)
- Combines with search (AND)
- Orphan statuses remain filterable by their string value

### 6.3 Include archived

- Toggle described in §3.1
- When off: list excludes archived
- When on: list includes archived (season label visible somewhere in row or panel)

---

## 7. Behaviors & Edge Cases

### 7.1 Create / edit

- Minimum create: company + title
- Date applied defaults to today; changing it (including to a past day) updates sparkline bucketing by that date
- Status can change freely forever; Accepted/Rejected never lock

### 7.2 Duplicate application (action)

- Explicit “Duplicate” copies all fields into a new application record
- New UUID; appears as its own row
- If the copy shares exact company + title with existing rows, soft duplicate warning applies in the table

### 7.3 Duplicate warning (table)

- Soft warning only, **table view only**
- Trigger: another application exists with the **exact same title** and **exact same company** (normalize company comparison case-insensitively; title exact per stored string unless we normalize trim — trim whitespace on save)
- Shown after the duplicate already exists (including after Duplicate action or manual re-entry)
- Does not block create/edit; no modal required for the warning itself

### 7.4 Delete

- **Hard delete** (immediate removal from local DB + sync deletion) — exception to the app-wide soft-delete default, per product choice for Jobs
- Always show a **confirm dialog**
- Deleting an application removes its status history with it
- Does not remove the company from the suggestion list automatically

### 7.5 Stage orphaning

- UI must not crash or hide apps whose `status` is not in the current stage list
- Sankey: orphan statuses appear as their own node(s), ordered after the user’s ordered stages (or grouped under an “Other” node — prefer **show orphan label as its own node** for honesty)

---

## 8. Macro Analytics

### 8.1 Lifetime total

- `COUNT(all applications)` including archived
- Not weighted; no interview-rate composite

### 8.2 Per-status counts (header)

- Active applications only (`seasonId == null`)
- Grouped by current `status` string

### 8.3 30-day sparkline

- Series: for each of the last 30 calendar days, count of applications whose **`dateApplied`** falls on that day
- Editing `dateApplied` to yesterday (etc.) moves the count to that day
- Default: **exclude archived**
- With **Include archived** on: include those applications in the daily counts
- Visual: minimalistic (match existing Voyager sparkline language — e.g. finance / leetcode activity sparklines)

### 8.4 Sankey

- Built from **current status only** (not full path history). An app that went OA → Accepted counts only as Accepted
- Node order follows the user’s **custom stage order**; orphans after
- Default: exclude archived; include when **Include archived** is on
- Valid with a single populated stage (degenerate Sankey / single-node empty-flow state — still render a calm empty/minimal state rather than erroring)
- Flows: interpret as distribution of applications across stages (source can be an implicit “Applications” node feeding into stage nodes, or stage-to-terminal grouping — implementation should favor a readable conversion picture: e.g. all apps → current stage buckets). Prefer a simple **Applications → {stages}** Sankey unless a clearer mid-pipeline encoding is trivial; do not invent fake multi-hop paths without history-based edges

---

## 9. Data, Sync & Architecture

Align with existing Voyager local-first stack:

- **Local**: Drift / SQLite tables for applications, status history, stages, company suggestions, categories, seasons, and Jobs UI prefs (column visibility, etc.)
- **Remote**: Firestore documents via existing sync / CRDT / outbox patterns used by other features
- **IDs**: UUIDs for all entities
- **Company list & categories & stages & seasons**: user-scoped, sync across devices
- **Jobs hard delete**: sync must propagate true deletes (tombstone or explicit delete op — follow whichever pattern the sync layer uses for hard removal if one exists; otherwise add a clear delete operation for this entity type). Document the choice at implementation time against `docs/adr/002-sync-protocol.md`
- **UI**: custom Voyager inputs (not stock Material fields) where the rest of the app already wraps fields; reuse confirm dialog, color picker, markdown notes patterns from journal/todo
- **Feature module**: `lib/features/jobs/` plus domain models, Drift tables, repository wiring, providers — same layering as todo / finance / leetcode

### Suggested entities (logical)

```
JobApplication
JobStatusEvent
JobStage          // ordered list, seedable
JobCompany        // suggestion list entry
JobCategory       // name + color
JobCompanyCategoryAssignment  // companyId → categoryId (1:1)
JobSeason         // named archive bucket
JobPagePrefs      // column visibility, include-archived default, etc.
```

---

## 10. Explicitly Out of Scope (v1)

- Next-action / follow-up reminders
- Export CSV / import
- Offer comparison
- Recruiter / contact fields
- Extra application metadata (location, salary, source, …)
- Global Search page integration
- Calendar or todo integration
- LeetCode / Study cross-links
- Dedicated multi-interview recording UI
- Soft-delete / recycle bin for applications (hard delete only)

---

## 11. Acceptance Criteria (summary)

1. User can create an application with only company + title; date defaults to today and is editable
2. Custom stages: add / rename / reorder; free status moves; seed stages present for new users
3. Status history timeline on each application; renames do not rewrite past events; stage delete allows orphans
4. Company typeahead: seed + user-added, substring match, syncs; deleting a suggestion leaves apps intact
5. Categories popup: one category per company, color on category, neutral default otherwise
6. Flat table with toggleable columns; todo-like editor; duplicate action; soft duplicate warning in table
7. Search contains-match on title/company/notes/status; status filter; seasons archive with include-archived toggle
8. Hard delete with confirm
9. Header: lifetime total (all), per-status counts (active), 30-day sparkline by `dateApplied`, Sankey by current status + stage order
10. New **Jobs** shell destination; no global search / calendar coupling

---

## 12. Decision Log (from product review)

| Topic | Decision |
|-------|----------|
| Stage model | Fully custom; no fixed transition order |
| Terminal lock | Never |
| Withdrawn/Ghosted | Notes / Rejected only |
| Min create | Company + title |
| History | Yes, status-change timeline |
| Same company+title rows | Allowed + soft table warning |
| URL / notes | One URL; markdown notes |
| Extra fields | Deferred |
| Companies | Seed + user; substring suggest; delete suggestion ≠ mutate apps |
| Company sync | Yes, account-wide |
| Search | Contains on title/company/notes/status |
| Layout | Flat table + todo-style panel |
| Delete | Hard + confirm |
| Lifetime metric | Total applications only |
| Sparkline | New apps / day by `dateApplied` |
| Sankey | Current status; user stage order |
| Header | Always visible, compact |
| Nav | Jobs destination |
| Archive | User-named seasons; hidden by default; in lifetime; not in Sankey/sparkline unless Include archived |
| Categories | One per company; color on category; small popup |
| Columns | Color, company, title, status, date applied, notes — user toggleable |
| Multi-interview feature | Not added |
| Duplicate warning | Soft, table-only, after duplicate exists |
