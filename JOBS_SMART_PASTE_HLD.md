# Jobs Smart Paste — High-Level Design

Clipboard sniff + smart paste for the Jobs **Track application** flow. Goal: one copy on the posting, one switch to Voyager, fields mostly filled, then back to applying.

Related: `JOBS.md` (§3.3 editor / track fields), `lib/features/jobs/jobs_track_modal.dart`, `jobs_track_draft.dart`.

Status: **implemented** (2026-09-04). See `lib/features/jobs/job_clipboard_parser.dart` and the sniff/paste wiring in `jobs_track_modal.dart`; §16 records where the built thing resolved a choice this document left open.

---

## 1. Problem

Adding an application today means shuttling between the browser and Voyager to copy **title** and **URL** separately. The natural loop is:

1. Read posting, check date / fit  
2. Switch to Voyager and log it  
3. Return to the browser and finish applying  

Two clipboard round-trips break that loop. Users should copy **once**, open Track, and land with URL and/or title already filled.

---

## 2. Goals

- Accept a **single clipboard string** (sniff on open, or paste into the form) and split it into **title** and/or **application URL**.
- Support the four intentional shapes below, plus the locked edge cases in §6.
- Prefill **only empty** fields — never clobber user edits or a restored draft’s existing values.
- Make mistaken prefills cheap to dismiss (“From clipboard” chip / clear).
- Keep company, stage, date, season, and notes on the existing Track form; this feature does not replace the form.

## 3. Non-goals (v1)

- Clipboard **history** / last-N copies (OS clipboard is one slot).
- Fetching the live page for `<title>` / `og:title`.
- Host-based **company** extraction (Greenhouse/Lever path segments, etc.).
- Browser extension / bookmarklet / OS share target.
- Parsing full job-description dumps into notes.
- Changing required-to-create rules (still **company + title** per `JOBS.md`).
- Smart paste on the edit panel for existing rows (Track modal only in v1; same parser may be reused later).
- Stripping tracking query params (`utm_*`) — optional later.

---

## 4. Product decisions (locked)

| Decision | Choice |
|----------|--------|
| **Input model** | One string at a time — current clipboard or a single paste |
| **Fields touched** | `title`, `applicationUrl` only |
| **Company** | Untouched by sniff/paste in v1 (suggestions dropdown unchanged) |
| **Overwrite policy** | Fill **empty fields only** |
| **URL without scheme** | Accept URL-shaped tokens; normalize with `https://` on apply/save |
| **Emails** | Never treat `name@host` as a URL |
| **Multiple URLs** | Use the **first** URL-shaped token; remainder (minus that token) is title |
| **Markdown links** | Support `[Title](url)` → title + URL |
| **Separators** | Spaces **and** newlines are equivalent separators |
| **Huge clipboard** | Cap parse input (see §6) so a full JD does not become the title |
| **Non-text clipboard** | Ignore sniff |
| **Wrong sniff** | Dismissible “From clipboard” affordance clears sniff-filled values |
| **Duplicate URL** | Soft informational hint if another application already has the same URL (do not block save) |

---

## 5. User flows

### 5.1 Happy path (clipboard sniff)

```
Browser                         Voyager
───────                         ───────
Skim posting
Copy once (URL, title, or
  "title URL" / "URL title")
         ── alt-tab ──►
                                Open Track application
                                Sniff clipboard (text only)
                                Prefill empty title / URL
                                Show “From clipboard” chip
                                User confirms company (+ fixes)
                                Save
         ◄── alt-tab ──
Continue applying
```

### 5.2 Manual smart paste

User opens Track with an empty or unhelpful clipboard, focuses Title, URL, or a dedicated paste target, and pastes once. The **same parser** runs as sniff. Results apply under the empty-field rule.

### 5.3 Draft restore

If Track opens on a saved draft:

- Empty title/URL may still receive sniff/paste fills.
- Non-empty draft fields are left alone.
- Discarding the draft and starting over re-enables sniff against the current clipboard (same as a fresh open).

---

## 6. Parse algorithm

Pure function: `parseJobClipboard(raw: String) → { title?, url? }`.

No I/O. Used by clipboard sniff and by paste handlers.

### 6.1 Preprocess

1. If `raw` is null/empty after trim → return empty result.  
2. Truncate to a **parse budget** before analysis: keep at most the first **500** characters, or the first **line that contains a URL-shaped token** plus that token’s line neighbors if shorter — whichever policy is simpler to implement; document the constant next to the parser. Intent: ignore giant JD pastes.  
3. Trim; strip a single layer of wrapping `"`, `'`, or `<>` around the whole string.

### 6.2 Markdown shortcut

If the (truncated) string matches `[title](url)` (optional surrounding whitespace):

- `title` ← bracket text (trimmed)  
- `url` ← paren text, then run through URL normalize (§6.5)  
- Return.

### 6.3 URL token detection

Scan for **URL-shaped tokens**. A token is URL-shaped if either:

- It starts with the **address-bar prefix** `https?://` plus an optional `www.`, **and** what remains after that prefix is still a host — dotted with a two-letter-or-longer last label, or `localhost` — optionally with a port, or  
- It has **no spaces**, contains at least one `.`, looks like `host[/path…]`, and is **not** an email (`@` present → reject as URL).

Examples accepted: `https://…`, `http://…`, `boards.greenhouse.io/acme/jobs/123`, `linkedin.com/jobs/view/123`.  
Examples rejected: `engineer`, `Senior`, `name@acme.com`, `C++`, `https://Software`, `https://www.Data`, `www.Data`.

A token rejected this way keeps its place in the title, but **not the prefix**: text pasted through an address bar comes back with the bar's `https://`, and its omnibox `www.`, glued to the first word after it. So

| Clipboard | Title | URL |
|-----------|-------|-----|
| `https://Software Engineer en.wikipedia.org/wiki/Shark` | `Software Engineer` | `https://en.wikipedia.org/wiki/Shark` |
| `https://www.Data Engineer Intern coinbase.com/en-ca/careers/positions/8175459` | `Data Engineer Intern` | `https://coinbase.com/en-ca/careers/positions/8175459` |

The dot left behind is what decides: `Data` has none once the prefix is off, `coinbase.com/…` still does. A token that is nothing but the prefix is dropped. A *second real link* is untouched by any of this and keeps its scheme in the title, and a `www.` that belongs to a genuine host stays in the stored URL — the prefix is only ever removed to **test** a token, never to rewrite a link.

If **multiple** URL-shaped tokens exist, keep the **first**; treat later ones as ordinary text (they remain in the title remainder unless identical to the chosen token).

### 6.4 Cases (maps to product rules)

| Clipboard shape | Result |
|-----------------|--------|
| **URL only** | `url` set; `title` unset |
| **Text + URL** (any order; space or newline separated) | `url` ← URL token; `title` ← remaining text, trimmed, collapsed internal whitespace to single spaces (preserve intentional single spaces in the title) |
| **URL + text** | Same as above (order-independent) |
| **Text only** | `title` ← full string; `url` unset |

Remainder extraction: remove the chosen URL token from the string (and surrounding whitespace/newlines), then trim. Do **not** use “everything after the last space” alone — titles like `Senior Engineer (Backend) https://…` must keep the parenthetical in the title.

### 6.5 URL normalize

When applying a detected URL to the field / on save:

- If scheme missing → prepend `https://`.  
- Trim trailing punctuation commonly stuck from prose: `.,);]` if they are not part of a real path (strip trailing `.` `,` `;` `)` when present at end of token).

### 6.6 Apply to form

```
for each of { title, url } in parse result:
  if value non-empty AND corresponding form field is empty:
    write value
    mark field as sniff/paste-sourced (for chip / dismiss)
```

Company, status, date, season, notes: never written by this feature.

---

## 7. Clipboard sniff

### 7.1 When

Run once when the Track modal **opens** (including open-on-draft), after controllers are initialized from draft/defaults.

### 7.2 Guards

Skip sniff if:

- Clipboard read fails or is unavailable  
- Clipboard is not plain text  
- Parsed result is empty  
- Both title and URL fields are already non-empty (nothing to fill)

### 7.3 UX

- On successful fill of at least one field, show a compact **“From clipboard”** chip (or equivalent) on the form.  
- Activating dismiss/clear: revert **only** the fields that this sniff filled (not manual edits after sniff). If the user edited a sniff-filled field, that field is no longer “sniff-owned.”  
- Do not show a blocking dialog for sniff.

### 7.4 Privacy / surprise

Sniff reads clipboard only in response to opening Track — not on a background timer, not on every Jobs page focus.

---

## 8. Manual paste integration

| Surface | Behavior |
|---------|----------|
| **Title field** | On paste: run parser on pasted text. If URL detected, put URL into empty URL field and title remainder into Title (if Title was empty or the paste replaced selection of all/empty). Prefer: if paste replaces the entire field contents (or field was empty), run smart split; if paste inserts into middle of existing title, insert raw text (no split). |
| **URL field** | Same policy: whole-field / empty → smart split; mid-field insert → raw. |
| **Optional dedicated “Paste job” control** | Not required for v1 if Title/URL paste + sniff cover the flows. Add later only if discoverability is weak. |

Paste and sniff share `parseJobClipboard`.

---

## 9. Duplicate URL hint

When the URL field becomes non-empty (sniff, paste, or type) and another non-deleted application has the same normalized URL:

- Show a **soft** warning near the URL field (informational).  
- Do **not** block Save (same spirit as company+title duplicate warning in `JOBS.md` §7.3).

Normalization for compare: trim, lowercase scheme/host if easy, ensure scheme present — keep comparison simple and deterministic.

---

## 10. UI sketch (Track modal)

No layout redesign. Additive only:

```
┌─ Track application ─────────────────────────┐
│  [From clipboard ✕]     ← only if sniff filled │
│  Company   […………▼]                          │
│  Title     [Software Engineer        ]       │
│  URL       [https://boards.green…    ]       │
│  … status, date, season, notes …             │
│                              [Save]          │
└─────────────────────────────────────────────┘
```

Existing draft banner / discard controls unchanged.

---

## 11. Domain & persistence

- No new persisted fields on `JobApplication`.  
- Sniff/paste is **UI-only** prefill before Save.  
- Draft store continues to persist whatever is in the form; if sniff filled title/URL and the user leaves, draft save includes those values as today.  
- No sync protocol changes.

---

## 12. Testing (acceptance)

| Case | Expect |
|------|--------|
| `https://example.com/job/1` | URL only |
| `boards.greenhouse.io/acme/jobs/1` | URL with `https://` normalize; title empty |
| `Software Engineer https://example.com/x` | title + URL |
| `https://example.com/x Software Engineer` | title + URL |
| `Software Engineer\nhttps://example.com/x` | title + URL |
| `Senior Engineer (Backend) https://example.com/x` | title keeps `(Backend)` |
| `[Backend Eng](https://example.com/x)` | title + URL |
| `Just a title` | title only |
| `name@acme.com` | title only (not URL) |
| Two URLs in one string | first URL wins; rest in title |
| 10k-char JD paste | truncated; does not dump full text into title |
| Draft with title set, clipboard is URL | URL fills; title unchanged |
| Sniff then dismiss chip | sniff-filled fields clear; manually typed fields stay |
| Existing app with same URL | soft hint; Save still works |
| Image on clipboard | sniff no-ops |

Unit-test the parser heavily; widget-test sniff/paste apply rules on the Track modal.

---

## 13. Implementation sketch (for later)

Suggested shape when coding (not part of design lock):

- `lib/features/jobs/job_clipboard_parser.dart` — pure `parseJobClipboard` + normalize  
- Wire sniff in `jobs_track_modal.dart` open path  
- Shared paste path on title/URL fields (or a thin wrapper around those fields)  
- Tests: `test/job_clipboard_parser_test.dart` (+ modal apply tests as needed)

---

## 14. Future (explicitly deferred)

- Page-title / Open Graph fetch from URL when online.  
- Company from known ATS host paths.  
- `utm_*` and tracking-param stripping.  
- Smart paste on the side edit panel.  
- Browser extension / bookmarklet one-click send.  
- Page-title patterns like `Role - Company | LinkedIn` → split company + title.

---

## 15. Summary

**v1:** one-string parse → title and/or URL; clipboard sniff on Track open; paste uses the same parser; empty-field-only writes; dismissible “From clipboard”; soft duplicate-URL hint; no company inference, no network fetch, no clipboard history.

That is enough to turn “copy title, switch, copy URL, switch” into “copy once, switch, save, continue applying.”

---

## 16. As built

Three points §6 and §8 left to the implementation, and how they were settled:

- **Parse budget.** The first of the two policies: the first `500` characters
  (`kJobClipboardParseBudget`), cut back to the last whitespace so the budget can
  never end halfway through a link and hand the URL field one that goes nowhere.
  No line analysis, and a title plus a link never come close to the cap.
- **Chip scope.** The “From clipboard” chip marks *any* field this feature wrote
  — sniff or smart paste — not just a sniff. A paste into Title that lands a URL
  in the URL box is exactly as surprising as a sniff is, and one dismiss covers
  both. A field the user has since typed in is no longer the clipboard's, so the
  chip never takes back an edit.
- **A paste with nothing for the box it landed in.** Only a *URL* ever moves to
  the other field. Text with no link in it, pasted into the URL box, stays there
  literally rather than jumping to Title: the user aimed at that box, and a link
  this parser does not recognise is likelier than a title pasted into the wrong
  place. Title-box pastes are unaffected — a bare URL pasted there still goes to
  the URL field.

One known miss, kept because the chip makes it cheap: a title token shaped
exactly like a host (`Node.js Developer`) reads as a link. Distinguishing the two
needs a TLD list, which buys less than it costs.
