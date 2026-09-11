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
| **Profile copy buttons** | One-tap clipboard copies of the user's own profile links (§3.4) |
| **Experience copy chips** | One-tap clipboard copies of the user's role descriptions (§3.5) |
| **30-day sparkline** | New applications per day for the last 30 days (see §8) |

An **Include archived** control (toggle/chip) affects the sparkline and the main list filter set — not the lifetime total. When off (default), archived apps are hidden from the list and excluded from the sparkline. When on, they appear in the list and are included in it. Lifetime total always counts everything.

### 3.2 Main surface — flat table

- Flat list/table (not kanban)
- Default columns: **color**, **company**, **title**, **status**, **date applied**, **season**, **notes**
- The **status** capsule is drawn in that stage's colour (§4.3), so the pipeline reads the same in the table as it does in the header chips. The **color** gutter is a different axis: it carries the company's category colour (§4.5)
- The **season** column names the season an application is filed under, or `—` for none. Whether that season is retired is carried by the archive marker at the end of the row, not repeated here
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
- **Delete** — soft delete with confirm dialog, then an undo toast (§7.4)

**Status timeline**
- Panel shows a chronological status-change history for that application (§4.2)

### 3.4 Profile quick-copy

Applying to a job means pasting the same three links over and over. The header carries them so they never have to be hunted for.

- Three fixed slots — **LinkedIn**, **GitHub**, **Portfolio** — held in app settings (§4.7)
- One icon button per slot, sitting between the status chips and the 30-day sparkline
- Icon-only, with the slot name in a tooltip. The header row is a fixed height and the sparkline already claims half its width; labelled buttons would take that width off the status chips
- Tap copies the URL to the clipboard and confirms with a snackbar naming the slot ("LinkedIn copied")
- An unset slot has no button. With all three unset the group is not rendered at all — the Jobs page shows no empty state and no prompt to fill them in
- The Jobs page never *edits* these. They are read-only here; Settings is the only place they are written (§4.7)

Copy is the whole interaction. No long-press, no open-in-browser, no per-application or per-company overrides.

### 3.5 Experience quick-copy

Forms ask for a description of each past role; the header carries those too. Full design: `JOBS_EXPERIENCE_SNIPPETS_HLD.md`.

- An ordered list of named snippets held in app settings (§4.8). Only the **description** is copied; the name is the chip label and the toast ("Acme - SWE Intern copied")
- Compact text chips, between the profile icons and the sparkline, 12px apart. Long names ellipsize on the chip (cap 160px); the tooltip carries the name only, never the body
- The first **three** in Settings order are chips; the rest sit behind a **caret menu** that lists full names and copies on pick
- When the header's half is too narrow, chips that cannot show at least ~90px move into the caret menu rather than squeezing the sparkline below **140px**. Order is still the priority: it is always the leading snippets that stay chips
- An empty description still copies (as `""`) with the usual toast. Copy never rewrites the text
- No snippets, no group — its spacing included. The Jobs page never edits these

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

- User-managed list: **add**, **rename**, **reorder**, **recolour**
- **No fixed order** for valid transitions; order is display order only
- **Seed stages** on first use: `Applied`, `Online Assessment`, `Interview`, `Accepted`, `Rejected`
- Withdrawn / Ghosted are **not** first-class stages — fold into Rejected and/or notes
- Deleting a stage that still has applications: **allowed**; apps keep orphan status strings
- Renaming does not rewrite history entries
- **Colour** is optional and per-stage, set from the app palette in Manage jobs. A stage with no colour of its own falls back to a hue derived from its position in the list — which is what every stage showed before colours existed, so adding the field changes nothing on screen until one is picked. Two stages may share a colour; nothing depends on them being distinct
- The stage's colour is what the header chips and the table's status capsules are drawn in. It is a display property of the pipeline: recolouring a stage writes nothing to the applications sitting on it, and an orphan status (no stage by that name any more) keeps the muted fallback that marks it apart

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

### 4.7 Application profile links

Not a Jobs entity — three optional strings on `AppSettings`, sitting beside the page's other Jobs prefs (column visibility, include-archived):

| Field | Example |
|-------|---------|
| `jobProfileLinkedInUrl` | `https://linkedin.com/in/…` |
| `jobProfileGitHubUrl` | `https://github.com/…` |
| `jobProfilePortfolioUrl` | `https://…` |

- All nullable, empty by default, and stored trimmed. No normalization beyond that — trailing slashes and `www` are left exactly as typed
- Written only from Settings → **Jobs** → *Job application profile*, a single dialog holding all three fields. One save, so clearing a slot and setting another travel together
- Persist locally like every other setting and sync through the settings document, which also carries them into import/export
- Fixed three slots: no custom links, no résumé slot, no reordering

### 4.8 Experience snippets

Also not a Jobs entity: `AppSettings.jobExperienceSnippets`, a list of `{ id, name, description }` whose order is the header's order (§3.5).

- `name` is trimmed and required; duplicates allowed. `description` is stored exactly as saved — leading/trailing whitespace and blank lines included — and may be empty
- Written only from Settings → **Jobs** → *Experience snippets*: add, edit, delete (always confirmed), drag to reorder. Every change persists immediately
- The editor warns — never blocks — on double spaces, line-edge whitespace, tabs, odd or zero-width spaces, curly quotes, en/em dashes and ellipses, bullet glyphs, and any other non-ASCII. **Clean paste** is the only rewrite and runs only when pressed; Cancel still discards it. Autocorrect is off in the description field for the same reason
- One JSON column locally (`job_experience_snippets_json`, schema 106); a native array in the settings document, so sync and import/export carry the whole ordered list. An absent field (older document) leaves the local list alone; an empty array clears it
- Unlimited length and count

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

- **Soft delete**, like every other entity in the app: `deletedAt` is stamped and the row is purged after the 30-day retention window
- Always show a **confirm dialog** — "moved to trash", not "cannot be undone"
- After the confirm, a `VoyagerToast` offers **Undo** for 8 seconds (see `SOFT_DELETE_TOAST.md`). Undo restores the application and its status history together
- Deleting an application tombstones its status history with it; the events keep their `fromStatus` / `toStatus`, so a restore brings the timeline back intact
- Does not remove the company from the suggestion list automatically

### 7.5 Stage orphaning

- UI must not crash or hide apps whose `status` is not in the current stage list
- Header chips: orphan statuses appear as their own chip, ordered after the user’s ordered stages, marked as orphaned and drawn in the muted fallback colour

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

### 8.4 Sankey — removed

The header once carried a single-hop Sankey beside the sparkline. It was built from each application's *current* status with the timeline never consulted, so it had no real stage-to-stage edges to draw and said nothing the per-status chips did not already say more legibly. Removed; the sparkline has the width it freed. The per-status chips (§8.2) remain the pipeline breakdown.

---

## 9. Data, Sync & Architecture

Align with existing Voyager local-first stack:

- **Local**: Drift / SQLite tables for applications, status history, stages, company suggestions, categories, seasons, and Jobs UI prefs (column visibility, etc.)
- **Remote**: Firestore documents via existing sync / CRDT / outbox patterns used by other features
- **IDs**: UUIDs for all entities
- **Company list & categories & stages & seasons**: user-scoped, sync across devices
- **Jobs delete**: a tombstone, the same as every other collection. `watchCollection` drops Firestore document removals, so an actually-deleted document would be invisible to the other devices and pushed back by the first one still holding it
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
- A browsable recycle bin for applications (deletes are undoable for 8 seconds via the toast, not restorable afterwards)

---

## 11. Acceptance Criteria (summary)

1. User can create an application with only company + title; date defaults to today and is editable
2. Custom stages: add / rename / reorder; free status moves; seed stages present for new users
3. Status history timeline on each application; renames do not rewrite past events; stage delete allows orphans
4. Company typeahead: seed + user-added, substring match, syncs; deleting a suggestion leaves apps intact
5. Categories popup: one category per company, color on category, neutral default otherwise
6. Flat table with toggleable columns; todo-like editor; duplicate action; soft duplicate warning in table
7. Search contains-match on title/company/notes/status; status filter; seasons archive with include-archived toggle
8. Soft delete with confirm, then an 8-second undo toast that restores the application and its timeline
9. Header: lifetime total (all), per-status counts (active), 30-day sparkline by `dateApplied`
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
| Stage colour | Optional, per stage; falls back to a position-derived hue |
| Header | Always visible, compact |
| Nav | Jobs destination |
| Archive | User-named seasons; hidden by default; in lifetime; not in the sparkline unless Include archived |
| Categories | One per company; color on category; small popup |
| Columns | Color, company, title, status, date applied, notes — user toggleable |
| Multi-interview feature | Not added |
| Duplicate warning | Soft, table-only, after duplicate exists |
