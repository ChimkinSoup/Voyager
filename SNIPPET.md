# Text Snippets (HLD)

Text expansion shortcuts inspired by [Obsidian Latex Suite](https://github.com/artisticat1/obsidian-latex-suite), available in every free-text field that is eligible for Vim — **independent of whether Vim is currently enabled**.

This document is a high-level design. It records product decisions and the intended architecture against Voyager’s existing text / Vim stack. It is not an implementation checklist.

---

## 1. Goals

- Let the user define **plain-string triggers** that expand into replacement text with **tabstops** (`$0`, `$1`, …).
- Support **auto-expand** and **manual expand** (expand key: Tab or Space, user-configurable).
- Optional **word-boundary** gating (Latex Suite `w`).
- Snippet **tabstop sessions** that compete correctly with tag suggestions and focus traversal for Tab.
- Visual **dotted caret marks** at every remaining tabstop.
- Persist snippets in **settings**, sync remotely, and include them in **import/export**.
- Ship with an **empty** snippet list.

### Non-goals (v1)

- Regex triggers, visual/selection wrap snippets, placeholders (`${1:text}`), mirrored tabstops.
- Math/code mode flags from Latex Suite (`m`, `t`, `c`, …) — irrelevant for Voyager prose fields.
- Snippets inside the **LeetCode code editor** widget.
- Mobile-only chrome for tabstops (no floating “next stop” button in v1).

---

## 2. Product model

### 2.1 Snippet record

```text
Snippet {
  id:            string          // stable id for sync / list identity
  trigger:       string          // plain text, unique among all snippets
  replacement:   string          // may contain $0, $1, … tabstops
  autoExpand:    bool            // true = Latex Suite "A"; false = wait for expand key
  wordBoundary:  bool            // true = Latex Suite "w"
  // reserved / later: priority, placeholders, regex, description
}
```

**Uniqueness:** No two snippets may share the same `trigger` string. Enforced in the Settings UI (and at write time).

### 2.2 Global settings (alongside the list)

| Setting | Meaning | Default |
| --- | --- | --- |
| `snippetsEnabled` | Master switch | `true` (or `false` — product choice at implement time; list can still be edited when off) |
| `snippetExpandKey` | Key used to expand **non-auto** snippets: `tab` \| `space` | `tab` |

Vim’s `vimModeEnabled` does **not** gate snippets.

### 2.3 Where snippets run

**Eligible fields:** Same suitability rule as Vim’s free-text gate (`vimSuitsField`): not obscured, not read-only, not formatter-constrained, not non-text keyboards — i.e. fields that *could* get Vim.

**Explicit exclusion:** `LeetCodeCodeField` (the code editor) never runs snippets, even though it uses `VimTextScope`. Inline backticks / prose in other LeetCode fields **do** run snippets.

**Platforms:** Desktop and mobile.

**Mode:** Expansion only while the field is in **Insert** behavior:

- Vim off → always “insert” (normal typing).
- Vim on → only when `VimMode.insert`. Normal / Visual / search prompt do not expand.

---

## 3. Trigger & expansion rules

### 3.1 When expansion may fire

Expansion is considered **only** when the user **types the last character of a trigger** (or, for manual snippets, types the full trigger and then presses the expand key).

Does **not** expand on:

- Paste (even if the pasted text ends with a trigger)
- Deleting characters so that a trigger suddenly appears (e.g. `e e` → delete space → `ee`)
- Programmatic `controller` writes, sync pulls, undo/redo application
- IME composition mid-string (evaluate on composition **end** / committed character only)

Implementation implication: drive matching from the **input key / composing path**, not from a blind `TextEditingController` listener.

### 3.2 Auto vs manual

| Kind | Behavior |
| --- | --- |
| `autoExpand: true` | As soon as the typed suffix equals `trigger` and gates pass, replace immediately. |
| `autoExpand: false` | After the trigger is present immediately before the caret, pressing `snippetExpandKey` expands. If the expand key is Space and expansion occurs, **do not** also insert a space. If nothing matches, the key behaves normally (Space inserts; Tab continues the Tab priority chain). |

### 3.3 Word boundary (`wordBoundary: true`)

Follow Latex Suite `w`: the trigger must be preceded **and** followed by a word delimiter (for auto-expand, “followed by” is satisfied by the fact that the caret is at the end of the trigger and the next character is not yet a word character — i.e. the match is checked with a delimiter **before** the trigger and end-of-match at the caret).

**Delimiters** (v1, align with Latex Suite spirit):

- Whitespace (space, tab, newline)
- Punctuation / non-word characters (anything outside letters, digits, underscore — same spirit as `\W` / start-end of buffer)
- Start and end of the field

Exact character class should be locked to Latex Suite’s definition during implementation (port or mirror their `isWordDelimiter` equivalent) rather than inventing a one-off list.

### 3.4 Competing triggers

Triggers are unique, so identical-string collisions cannot occur.

**Shorter auto triggers win by chronology:** if `e` is auto-expand, typing the first `e` expands immediately; `ee` can never form unless the user recreates `ee` without typing the second `e` as a fresh suffix (see 3.1). Document this in the Settings UI near auto-expand.

Manual (non-auto) snippets are only considered when the expand key is pressed; matching uses the text immediately before the caret.

If multiple manual triggers could match as suffixes (e.g. `e` and `ee` both manual), prefer the **longest** matching suffix. (Auto path does not need this once shorter autos have already fired.)

### 3.5 Replacement & tabstop syntax

Latex Suite–compatible parsing:

- `$` followed by one or more digits → tabstop index (`$0`, `$1`, …).
- Any other `$` → literal `$`.
- Example: `($0)$1` → `(`, tabstop 0, `)`, tabstop 1.
- Example: `$$0$` → literal `$`, tabstop 0, literal `$` (inline-math style).

**Literal `$` + digits that must not be a tabstop** (rare in v1): escape as `\$` then digits (e.g. `\$0` → characters `$` `0`). Bare `$$` is **not** used as an escape — that would break the natural `$$0$` pattern Latex Suite uses.

Tabstop visit order: ascending numeric order — land on the lowest index first (`$0`, then `$1`, …). Missing indices are skipped. Expansion with **no** tabstops just replaces text and leaves the caret after the replacement; no tabstop session is created.

Placeholders and mirrored indices: **later**.

---

## 4. Tabstop sessions

### 4.1 Session stack (nesting)

Nested expansion is allowed.

- Each expansion that contains tabstops **pushes** a session onto a per-field stack.
- Tab advances tabstops of the **innermost** (top) session first.
- When that session is exhausted, it is popped; Tab then serves the outer session, and so on.
- Outer sessions remain until completed or invalidated.

### 4.2 Region & validity

Each session owns a **region**: a closed character offset range covering the expanded replacement, updated as the user inserts/deletes **inside** the range (sticky span: start fixed unless deleted through; end moves with inner edits).

**Clear / invalidate a session when:**

- Focus leaves the field
- Caret moves outside that session’s region (mouse click, arrow keys, Vim motions in Normal mode, etc.)
- Undo that reverts the expansion (see §5)
- The session’s tabstops are fully consumed

**Do not clear merely because:**

- User presses Esc / enters Normal mode, **as long as the caret stays inside the region**
- User types inside the region (including nested expansions)

If the caret leaves the **innermost** region but remains inside an outer region, pop/clear only the sessions whose regions no longer contain the caret (innermost first).

### 4.3 Tab key priority (global for a focused field)

When Tab is pressed:

1. **Tag suggestion popup** (if open) — accept suggestion  
2. Else if an active snippet session has a **next** tabstop **and** caret is inside that session’s region — advance  
3. Else — **focus traversal** (next field)

Shift+Tab: **always reverse focus traversal**. It never goes to the previous tabstop in v1.

### 4.4 Exhaustion

When Tab advances past the last remaining tabstop of the innermost session:

- Move caret to that final tabstop (if not already there), clear/pop that session.
- If the stack is empty after that, **the same Tab does not also move focus** — it only completes the session. A subsequent Tab falls through to focus traversal (step 3).

*(HLD default; easy to change to “last Tab also focuses next” if preferred later.)*

### 4.5 Expand key vs tabstops

If `snippetExpandKey == tab`:

- Tab first tries tag accept, then tabstop advance, then **manual snippet expand** (if a non-auto trigger suffix matches), then focus.

If `snippetExpandKey == space`:

- Space tries manual expand when applicable; otherwise inserts a space.
- Tab never expands manual snippets; it only does tags → tabstops → focus.

### 4.6 Visual: dotted tabstop marks

While any session is active, paint a **faint dotted vertical marker** (or small dotted caret stub) at every **remaining** tabstop position in the stack (all sessions), not only the next one.

- Reuse the same overlay measurement approach as `VimTextOverlay` (caret rects from `RenderEditable`).
- Marks update on text change, layout, and scroll.
- Next tabstop may use a slightly stronger opacity than later ones (optional polish).
- No marks when the stack is empty.

---

## 5. Undo

A successful expansion must be a **single undo atom**:

- Before: text contains the trigger (e.g. `…ee…`)
- After: replacement with caret on `$0` (e.g. `…()…`)
- One Undo → trigger restored, caret after the trigger, **all tabstop sessions created by that expansion cleared** (nested sessions spawned after that expansion are also cleared if they depended on it — simplest rule: clear the entire stack on undo that touches snippet state, or clear from the undone session upward)

Use `EditableTextState.userUpdateTextEditingValue` (same path as Vim mutations) so formatters, `onChanged`, spellcheck, and undo history stay consistent.

---

## 6. Architecture (how this sits in the repo)

### 6.1 Layering

```text
Settings (AppSettings)
    └── snippetsEnabled, snippetExpandKey, List<Snippet>
            │ sync / import-export (existing settings pipeline)
            ▼
SnippetEnabledScope (InheritedWidget, app root — parallel to VimEnabledScope)
            ▼
Eligible text field wrappers
  VoyagerTextField / LabeledTextField / TagHighlightedTextField / …
            ▼
VimTextScope (existing)          SnippetTextScope (new, sibling or child)
  · Normal/Visual/Insert         · Insert-only expand + tabstop stack
  · ignores Tab today            · claims Tab when session/manual expand needs it
            ▼
TextField / EditableText
            ▼
Overlays: VimTextOverlay · SnippetTabstopOverlay (dotted marks) · tag portal
```

**Recommended ownership:**

| Concern | Owner |
| --- | --- |
| Snippet list + flags | `AppSettings` + settings UI section |
| Per-field runtime | `SnippetSession` (stack, regions, match-on-type) |
| Key arbitration with Vim | `VimTextScope` Insert path **ignores** Tab/Space when snippets claim them; or `SnippetTextScope` sits on the same ancestor `Focus` and runs **before** focus traversal, coordinated with Vim’s `_handleKey` |
| Opt-out for code editor | `LeetCodeCodeField` passes `snippetsEnabled: false` into the scope (hard opt-out) |
| Painting | `SnippetTabstopOverlay` next to `VimTextOverlay` |

Snippets must not require a live `VimSession`. When Vim is off, the field still mounts `SnippetTextScope` if the field is eligible and `snippetsEnabled` is on.

### 6.2 Key arbitration (critical path)

Today (`VimSession.handleKey`):

- Insert: only Esc is handled; everything else ignored (including Tab).
- All modes: Tab explicitly ignored for focus traversal.

New behavior for eligible fields:

```text
KeyEvent (Tab / Space / printable)
  → TagSuggestionPortal (existing focusNode.onKeyEvent)   // first refusal
  → SnippetTextScope                                      // expand / tabstops
  → VimTextScope / VimSession                             // Esc, Normal, …
  → DefaultTextEditingShortcuts / focus traversal
```

`SnippetTextScope` returns `KeyEventResult.handled` when it expands or advances a tabstop; otherwise `ignored`.

### 6.3 Detecting “typed last character”

Prefer listening to committed insert events (after IME), comparing:

- previous selection was collapsed
- exactly one character (or the final character of the trigger) was inserted at the caret
- new text immediately before caret ends with a candidate trigger

Reject multi-character inserts (paste), deletions, and replacements.

### 6.4 Persistence & sync

- Store the snippet list and global flags on `AppSettings`.
- Extend `settingsToFirestore` / `settingsSyncPayload` / `mergeSettingsFromRemote` / import-export the same way other settings fields are handled.
- Merge policy: follow existing settings merge (typically last-write / field-level); snippet list treated as one atomic settings field unless a smarter merge is already patterned elsewhere.
- Backup zip already dumps settings JSON — snippets ride along once on `AppSettings`.

### 6.5 Settings UI

- Section under Settings (near Vim toggle): master enable, expand-key dropdown (Tab / Space), list of snippets.
- Row editor: trigger, replacement (with short syntax help for `$0`), toggles for auto-expand and word-boundary.
- Validation: non-empty trigger, unique trigger, well-formed `$` escapes / tabstop indices (warn on `${…}` in v1 as unsupported).
- Empty state copy: no default pack.

---

## 7. Edge cases (normative)

| Case | Behavior |
| --- | --- |
| Vim Normal mode, caret still in region | Tabstops remain; Tab still advances if not eaten elsewhere; no new expansions |
| Vim motion leaves region | Clear affected sessions |
| Tag popup open | Tab accepts tag; does not advance tabstops |
| Manual expand key = Space, no match | Insert space |
| Auto `e` and manual `ee` | Auto `e` always consumes the first `e` |
| Expansion with no tabstops | Replace only; no session; no dotted marks |
| Nested expand inside `$0` | Push inner session; inner tabstops first |
| Undo expansion | Restore trigger; clear sessions from that expansion upward |
| Focus next field | Reset snippet state for the field that lost focus (same spirit as Vim session reset) |
| App background / focus park | Mirror Vim: do not clear solely because the app backgrounded if focus is restored to the same field (implementation can share lifecycle notes with `VimTextScope`) |
| Read-only / password / numeric | No snippets (`vimSuitsField` false) |
| LeetCode code editor | Hard off |
| Mobile soft keyboard without Tab | Auto-expand still works; tabstops advance only when a Tab key event exists (external keyboard / some IMEs). No extra UI in v1 |

---

## 8. Testing plan (high level)

- Unit: trigger matching (auto/manual, word boundary, longest manual suffix), replacement parser (`$0`, literal `$`, `\$0`), region update on insert/delete, session stack push/pop.
- Widget: Tab priority vs tag portal vs focus; Undo restores trigger; paste does not expand; delete-join does not expand; Vim Esc keeps session; caret leave clears; overlay marks at offsets.
- Settings: uniqueness validation; sync round-trip; import/export contains snippets.
- Regression: `LeetCodeCodeField` Tab still indents; Vim Normal Tab still focuses when no snippet session.

---

## 9. Decisions log

| # | Decision |
| --- | --- |
| 1 | Snippets independent of Vim enablement; same field eligibility as Vim, minus LeetCode code editor |
| 2 | Auto and manual expand; global expand key Tab or Space |
| 3 | Plain-string triggers only; unique triggers |
| 4 | Word-boundary per Latex Suite `w` |
| 5 | Expand only on typing the last trigger character (not paste / delete-join) |
| 6 | Tabstops `$0`, `$1`, …; Latex Suite `$` parsing; `\$` for literal `$`+digits |
| 7 | Tab advances tabstops while caret in region; leave region → clear |
| 8 | Invalidateators: leave field, click/caret outside region, undo — **not** Esc/Normal alone |
| 9 | Shift+Tab = reverse focus only |
| 10 | Tab order: tags → snippet tabstops → (manual expand if expand key is Tab) → focus |
| 11 | Expand only in Insert; keep tabstops across Normal if caret stays in region |
| 12 | Undo restores the trigger in one step |
| 13 | Settings list + sync + import/export; ship empty |
| 14 | Nested expansions; inner tabstops first |
| 15 | No visual-mode snippets |
| 16 | Dotted marks for all remaining tabstops |
| 17 | *(HLD default)* Final Tab of a session clears it but does not also move focus |
| 18 | *(HLD default)* Expand key is a **global** setting, not per-snippet |

---

## 10. Open polish (non-blocking)

- Exact Latex Suite delimiter character class — port during implementation.
- Whether `snippetsEnabled` defaults to on or off for first ship.
- Slightly stronger style for the *next* tabstop mark vs later ones.
- Later: regex triggers, placeholders, mirrored tabstops, per-snippet expand key.
