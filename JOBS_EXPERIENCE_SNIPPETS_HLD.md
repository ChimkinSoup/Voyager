# Jobs — Experience Snippets HLD

One-tap clipboard copies of **role / experience descriptions** from the Jobs header, managed in Settings. Same family as the existing LinkedIn / GitHub / Portfolio copy buttons (`JOBS.md` §3.4 / §4.7), but as an **ordered list of named snippets** instead of three fixed URL slots.

Related: `JOBS.md`, `lib/features/jobs/jobs_header.dart`, Settings → Jobs → *Job application profile*, `AppSettings` sync path.

Status: **implemented** (2026-09-10). §7.4's crowding rule was revised at implementation — see the note there.

---

## 1. Problem

When applying to jobs, forms often ask for a **role description** (resume bullets for a past job). Today the user copies from a resume, then manually cleans newlines and formatting for each paste. Profile URL copy on the Jobs page already solves the LinkedIn / GitHub / Portfolio round-trip; role text has no equivalent.

---

## 2. Goals

- Let the user store **named experiences** (e.g. `Acme - SWE Intern`) with a **multi-line role description**.
- On the Jobs page, **one click** copies that description to the clipboard (toast confirmation, same pattern as profile links).
- **Edit only in Settings**; Jobs page is copy-only.
- Warn about non-standard characters / spacing while editing — **never mutate text unless the user presses Clean paste**.
- Persist and **sync** like the existing job profile URL fields (settings document + import/export).

## 3. Non-goals (v1)

- Multiple versions of the same experience (short vs long) — use separate entries instead (`Acme - Backend SWE`, `Acme - Frontend SWE`).
- Auto-normalize on copy, paste, or save (except the explicit **Clean paste** button).
- Inline edit / rename / delete on the Jobs page.
- Hover / tooltip preview of the description on Jobs chips.
- Cover-letter snippets, skills one-liners, pin/favorite, company-list linking, résumé PDF slot.
- Hard cap on total experiences (unlimited list).
- Fetching or parsing a résumé file into snippets.

---

## 4. Product decisions (locked)

| Decision | Choice |
|----------|--------|
| **Edit surface** | Settings only |
| **Copy surface** | Jobs header only |
| **Copied payload** | Role description only (raw, as stored) |
| **Visible label** | User-chosen name, e.g. `Acme - SWE Intern` — not copied |
| **Empty description** | Allowed; copy still writes `""` and shows the usual toast |
| **Empty name** | **Not allowed** — block save if name is blank/whitespace |
| **Formatting on copy** | Never rewrite — user owns normalization |
| **Edit-time warnings** | Immediate, non-blocking banners/chips for suspect characters / spacing |
| **Clean paste** | Explicit button in the editor; only mutates when clicked |
| **Jobs placement** | Compact controls beside existing profile copy icons |
| **Display soft cap** | First **3** (by order) as chips/buttons; remainder behind a **dropdown** |
| **Reorder** | Settings only; order defines which three are visible on Jobs |
| **Delete** | Confirm dialog before delete |
| **Storage / sync** | Same channel as profile links (`AppSettings` → settings doc → import/export) |
| **List size** | Unlimited |
| **Character count** | Shown in the multiline editor; informational only (no hard limit) |

---

## 5. Data model

Not a Jobs table entity. Extends settings the same way as `jobProfileLinkedInUrl` / `jobProfileGitHubUrl` / `jobProfilePortfolioUrl`.

### 5.1 Snippet shape

```
JobExperienceSnippet
  id: String          // stable id (newId), for reorder / edit / delete
  name: String        // visible label; trimmed; required non-empty
  description: String // role body; may be empty; stored exactly as last saved
                      // (Clean paste may have rewritten it only when user opted in)
  // order = position in the AppSettings list (no separate sortOrder field required)
```

### 5.2 Settings field

- `AppSettings.jobExperienceSnippets: List<JobExperienceSnippet>` (default `[]`).
- Persist as a JSON array on the settings row / Firestore settings document (follow existing list-on-settings patterns in the codebase if any; otherwise one JSON string column + mapper encode/decode).
- Sync, import, and export must round-trip the full ordered list.
- Profile URL slots stay unchanged; this is an **additional** Jobs preference group, not a replacement for §4.7.

### 5.3 Validation on save

| Field | Rule |
|-------|------|
| `name` | Trim; reject if empty after trim |
| `description` | Keep as-typed (including leading/trailing newlines/spaces) on normal Save; Clean paste may alter before Save |
| `id` | Assigned on create; immutable |

No uniqueness constraint on `name` (two `Acme - SWE` entries are allowed).

---

## 6. User flows

### 6.1 Create / edit (Settings)

```
Settings → Jobs → Experience snippets
  → list (ordered), Add, reorder handles, Edit, Delete
  → Edit / Add opens dialog:
       Name (single-line)
       Description (multi-line)
       Character count (live)
       Warning strip (live, if any issues)
       [Clean paste]  [Cancel]  [Save]
```

- **Save** writes the list (create inserts at end, or replace in place on edit).
- **Delete** → confirm (`Delete “Acme - SWE Intern”?`) → remove from list → persist.
- **Reorder** (drag handles or up/down) updates list order immediately or on an explicit Done — prefer **immediate persist on drop**, matching other Jobs prefs where possible.

### 6.2 Copy (Jobs page)

```
Jobs header → experience chip / dropdown item
  → Clipboard.setData(description)   // may be ""
  → toast: "<name> copied"           // same toast family as "LinkedIn copied"
```

No confirmation, no preview, no secondary click action.

### 6.3 Empty list

- Settings: empty-state copy + Add.
- Jobs: no experience chips and no overflow dropdown (same “disappear including spacing” rule as unset profile links).

---

## 7. Jobs header UI

### 7.1 Layout

Keep the existing profile copy group (`_ProfileCopyButtons`). Add an **experience copy group** immediately beside it (same half-row as the sparkline):

```
[ LinkedIn ] [ GitHub ] [ Portfolio ]  |  [ Exp1 ] [ Exp2 ] [ Exp3 ] [ ▾ ]
                                         ↑ only if snippets non-empty
```

- Experiences use **compact text chips** (truncated name), not icons — names are not iconographic.
- Profile links stay icon-only (unchanged).
- If both groups exist, a small gap separates them; if only one exists, the other collapses with its spacing.

### 7.2 Soft cap (3 + overflow)

| Count | Jobs chrome |
|-------|-------------|
| 0 | Hidden |
| 1–3 | That many chips only |
| 4+ | Chips for list indices `0..2`; overflow control opens a menu of `3..n-1` |

- Overflow menu items show the full `name`; activating an item copies that snippet’s description (same toast).
- Reordering in Settings is the only way to promote a snippet into the top three.

### 7.3 Chip behavior

- Single tap → copy description (including empty).
- No tooltip with description preview (tooltips for accessibility name only are optional and must not show body text).
- Long names: ellipsize on the chip; full name in overflow menu rows.

### 7.4 Header density

The header is a fixed **76px** row today. Experience chips must stay vertically centered and must **not** steal width from status chips preferentially — follow the same flex rules as profile buttons (chart yields first via `Flexible`).

If many wide names crowd the row, ellipsize chip labels aggressively; do not wrap to a second header line in v1.

> **Revised at implementation (2026-09-10).** "Chart yields first" would have erased the sparkline at ~1280–1500px windows once three chips were set. Instead the chart keeps a **140px floor**; chips that cannot show at least ~90px move into the overflow menu (leading snippets stay chips, so order is still the priority). With room, it is exactly §7.2's 3 + overflow. Chip cap is 160px.

---

## 8. Settings UI

### 8.1 Entry point

Settings → **Jobs** section, new tile near *Job application profile*:

| Tile | Summary example |
|------|-----------------|
| **Experience snippets** | `3 set` / `Not set — no copy chips on the Jobs page` |

Optional: keep profile URLs and experiences as **two tiles** (clearer than one overloaded dialog).

### 8.2 List screen / dialog

- Ordered list of `name` rows (description preview truncated to one line, optional).
- Affordance: Add, Edit (row tap or icon), Delete, Reorder.
- Delete always confirms.

### 8.3 Editor dialog

| Control | Detail |
|---------|--------|
| **Name** | Single-line `TextField`; required |
| **Description** | Multi-line `TextField` / Voyager multiline field; min ~4–6 lines visible; scroll for longer |
| **Character count** | e.g. `1248 characters` under the description; updates live; no max |
| **Warning strip** | Appears immediately when any warning rule matches current description (and optionally name); clears when issues are gone |
| **Clean paste** | Secondary button; runs the cleaner on the **description** only, then leaves the result in the field for the user to review before Save |
| **Save / Cancel** | Standard |

Warnings are **advisory only** — Save remains enabled even with warnings (as long as name is non-empty).

---

## 9. Warnings & Clean paste

### 9.1 Principles

- Warnings **never** rewrite text.
- Clean paste **only** runs on explicit button press.
- Copy path never runs Clean paste or warnings.

### 9.2 Warning rules (description, live)

Fire a compact warning (list or chips) when any of the following are present:

| Rule | Detect |
|------|--------|
| **Double spaces** | Two or more consecutive ASCII spaces |
| **Leading / trailing line whitespace** | Space/tab at start or end of any line |
| **Tabs** | `\t` |
| **Non-breaking / odd spaces** | `\u00A0`, `\u2007`, `\u202F`, etc. |
| **Fancy quotes** | `‘’“”` and similar |
| **Dashes / ellipsis** | `–` `—` `…` (vs `-` / `...`) |
| **Bullet glyphs** | `•` `‣` `●` etc. (ASCII `-` / `*` alone do not warn) |
| **Other non-ASCII** | Any remaining code point outside printable ASCII (plus normal newlines `\n` / `\r\n`) |

Presentation: one short summary is enough, e.g. `Non-standard characters or spacing detected` with an optional expandable detail listing which categories hit. Do not block typing.

Name field: optional lighter check (trim warning only); description is the main surface.

### 9.3 Clean paste (explicit)

Applies to **description** text in the editor when the user presses the button. Conservative ASCII-oriented normalize aligned with the warning table:

1. Replace NBSP / odd spaces → ASCII space  
2. Replace fancy quotes → `'` / `"`  
3. Replace `–` `—` → `-` ; `…` → `...`  
4. Replace common bullet glyphs → `-`  
5. Replace tabs → single space  
6. Collapse runs of ASCII spaces to one space **per run** (does **not** join across newlines)  
7. Strip trailing whitespace on each line; strip leading whitespace on each line  
8. Normalize newlines to `\n`  
9. Trim a single trailing newline at end of text (optional; document in implementation) — **do not** collapse the whole block to one line

**Does not:** remove blank lines between paragraphs, rewrite wording, or run on Save/copy automatically.

After Clean paste, warnings should recompute; ideally most clear. User still hits Save.

---

## 10. Clipboard & toast

Mirror `_ProfileCopyButton`:

1. Capture `Overlay` before `await` (header may rebuild).
2. `Clipboard.setData(ClipboardData(text: description))` — use `''` when empty.
3. `showVoyagerToastIn(..., message: '$name copied', icon: check, dwell: 2s)`.

No special empty-description toast.

---

## 11. Sync, import / export, migrations

> **Superseded (2026-09-16, schema v115).** Experience snippets are records of
> their own (`job_experience_snippets_table`, Firestore
> `job_experience_snippets`), ordered by a fractional `position`, rather than a
> list in the settings document — see `SNIPPET.md` §6.4 and
> `DATA_INTEGRITY_AUDIT_REPORT.md` P1-1. Backups carry them as their own
> collection; an older backup's list is adopted on import.

- New settings field ships with schema migration if the Drift `AppSettings` table needs a column (JSON text or dedicated blob — match project convention).
- Firestore settings mapper: read/write the list; remote clear / merge semantics follow other settings list fields.
- Import/export: include snippets in the settings payload so a backup restores order and bodies.
- Default for existing users: empty list (no Jobs chrome change until they add snippets).

---

## 12. Testing (acceptance)

| # | Case |
|---|------|
| 1 | Create snippet with name + multiline description → appears in Settings list and Jobs (if in top 3) |
| 2 | Click chip → clipboard equals exact description; toast shows name |
| 3 | Empty description → clipboard `""`; toast still `"Name copied"` |
| 4 | Save with blank name → blocked |
| 5 | 4+ snippets → first 3 as chips; 4th+ only in overflow; copy from menu works |
| 6 | Reorder in Settings so former 4th is first → Jobs chips update without restart |
| 7 | Delete with confirm cancels → unchanged; confirm accepts → removed from Jobs |
| 8 | Warnings appear immediately for double spaces / smart quotes; Save still works |
| 9 | Clean paste rewrites description per §9.3; Cancel discards if not saved |
| 10 | Copy never changes stored text |
| 11 | Snippets sync / round-trip import-export with order preserved |
| 12 | Zero snippets → no experience chrome on Jobs (spacing collapsed) |

---

## 13. Implementation sketch (non-binding)

Likely touch points:

- `AppSettings` + Drift settings table + `firestore_document_mapper` + import/export
- Settings Jobs section: list + editor dialog (multiline, warnings, Clean paste, char count)
- `jobs_header.dart`: experience chip row + overflow menu beside `_ProfileCopyButtons`
- `jobs_page.dart`: pass snippets from settings provider (same as profile URLs)
- Unit tests: warning detector, Clean paste pure functions, order → top-3 selection
- Widget tests: header chip count / overflow, copy toast with empty description

Update `JOBS.md` §3.1 / §3.4 / §4.7 (or add §4.8) when implementing so the living Jobs design stays authoritative.

---

## 14. Open implementation details (safe defaults)

These were not product-critical; implementers may choose without further product review:

| Topic | Default |
|-------|---------|
| Chip max width | ~120–160px ellipsis |
| Overflow control | Icon button `▾` / “More” with menu |
| Reorder UX | Drag handles if cheap; else up/down buttons |
| Warning UI | Single amber line + optional “Details” |
| Storage encoding | JSON array on settings |

No further product questions blocked on this HLD.
