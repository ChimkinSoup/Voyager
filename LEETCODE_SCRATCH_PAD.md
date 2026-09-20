# LeetCode Study/Cram — Scratch Code Pad

Practice code editor alongside the flashcard during Study and Cram sessions. Users type a solution attempt locally, copy it, open the real LeetCode problem to test, and optionally diff against the saved solution — without polluting the tracked problem record or sync pipeline.

Status: **implemented** 2026-08-31.

---

## Goals

- Optional **scratch code pad** in Study and Cram sessions, toggled by a persisted setting (`Enable scratch code`, default **off**).
- Split layout while collapsed: flashcard on the left, proportional scratch panel on the right; pad stays visible on **both** card faces.
- Click/tap the collapsed panel → **full-page editor** with a top action bar (copy, open LeetCode, clear, strip comments, compare).
- **Session-scoped** scratch storage with **crash recovery** — scratches belong to one Study/Cram run and are wiped on normal exit; device-local spillover only if the session ends abnormally.
- Reuse existing Voyager primitives: `LeetCodeCodeField`, `LeetCodeCommentStripper`, `openLeetCodeDetailView`-style expand animation, `GlassButton`, `showVoyagerToast`, `LeetCodeTrackDraftStore`-style local JSON persistence.

## Non-goals

- Scratch pad on the Review Deck grid, detail view, dashboard, or Track modal.
- Syncing scratch content to Firestore or other devices.
- Writing scratch code into `LeetCodeProblem.solutions` or the SRS schedule.
- Running or compiling code inside Voyager.
- Paste-from-LeetCode / submission import flow.
- Grading or cram swipe while the expanded editor is open.

---

## User decisions (locked)

| Topic | Decision |
| --- | --- |
| Scope | Study and Cram sessions only |
| Setting | Toggle **Enable scratch code** in existing **Study & Cram** popover; default **off** for new and existing users |
| Collapsed layout | Proportional **35/65** split (scratch / card); narrow viewports stack vertically with scroll |
| Expanded layout | Editor fills the page; top action bar only |
| Collapse expanded | Click outside **or** close button — **not** Escape (reserved for Vim) |
| Persistence model | Session-scoped + crash recovery (see [Storage](#storage)) |
| Per-problem within session | Yes — advance, undo, redo, and session-complete undo all restore the right scratch |
| Language default | First pad on a problem: language of **first solution** on that problem; thereafter remember last language picked **in the scratch pad for this session** |
| Starter template | Yes — best-effort derivation from first solution's code (see [Starter template](#starter-template)) |
| Focused scratch pad | No session keybinds reach the card (Space types space; cram arrows / grading disabled) |
| Expanded editor | Grading and cram swipe **explicitly blocked** until collapsed |
| Copy | Copies what the user typed; empty string if pad is empty |
| Open LeetCode | New browser tab; button stays visible but styled **destructive/disabled** when `leetcodeUrl` is null |
| Hide solution code | Independent — scratch pad unaffected by card hide toggles |
| Pad visibility | Always present when setting is on (front and back of card) |
| Vim | Required — full `LeetCodeCodeField` behavior including syntax highlighting and language pill |
| Autosave | Debounced device-local write during session |
| Clear pad | Toolbar action in expanded view |
| Focus shortcut | **`C`** focuses / expands scratch pad |
| Compare | Expands pad, then GitHub-style side-by-side diff (scratch left, saved solution right) with **linked vertical scroll** |
| Remember expanded | Within session only — undo back to a problem restores expanded/collapsed state for that problem |
| Detail view scratch | **No** — session-scoped storage keeps detail view out of scope |

---

## Entry points

| Surface | Behavior |
| --- | --- |
| Review Deck → Study | If `leetCodeEnableScratchCode`, session layout includes scratch pad |
| Review Deck → Cram | Same |
| Study & Cram settings popover | New row: **Enable scratch code** (checkbox, same pattern as hide toggles) |
| Normal session exit (`Back to deck`, close `×`, session complete → done) | Wipe session scratch bucket |
| Abnormal exit (crash, force-kill) | Orphan session file may remain → recovery toast on next Study/Cram entry |

---

## Architecture

### New / touched modules

| File | Role |
| --- | --- |
| `lib/domain/models/settings_models.dart` | `leetCodeEnableScratchCode` (default `false`), sync via `settingsSyncPayload` |
| `lib/data/database/app_database.dart` + mapper | Settings column migration |
| `lib/features/leetcode/leetcode_review_deck.dart` | `_hideToggles` → extend with scratch toggle row |
| `lib/features/leetcode/leetcode_scratch_draft.dart` | DTO: per-problem `{ code, language, expanded }` + session metadata |
| `lib/features/leetcode/leetcode_scratch_draft_store.dart` | Device-local JSON read/write (pattern: `leetcode_track_draft_store.dart`) |
| `lib/features/leetcode/leetcode_scratch_session.dart` | `LeetCodeScratchSessionController` — the map, the debounce, the file's lifecycle |
| `lib/features/leetcode/leetcode_scratch_host.dart` | `LeetCodeScratchHost` mixin: split layout, expand overlay, recovery toast — shared by both pages |
| `lib/features/leetcode/leetcode_scratch_pad.dart` | Collapsed panel, expanded overlay, toolbar, compare view |
| `lib/features/leetcode/leetcode_scratch_starter.dart` | Derive starter template from solution code + language fallbacks |
| `lib/features/leetcode/leetcode_scratch_diff.dart` | LCS line alignment behind the compare panes |
| `lib/features/leetcode/leetcode_code_field.dart` | New `LeetCodeCodeSurface` — the editor chrome `LeetCodeCodeInput`/`LeetCodeCodeView` already shared, now reused by the pad |
| `lib/features/study/study_keyboard_shortcuts.dart` | `onFocusScratch` — the `C` binding |
| `lib/features/leetcode/leetcode_session_page.dart` | Wire split layout + session scratch state |
| `lib/features/leetcode/leetcode_cram_page.dart` | Same |
| `test/leetcode_scratch_*` | Setting/sync, store, starter, diff, session integration, keyboard focus guards |

### Session scratch controller

Owned by the active session page (`LeetCodeSessionPage` / `LeetCodeCramPage`), not a global provider — mirrors cram bucket state living in the page.

```text
LeetCodeScratchSession
├── sessionId: String (UUID, created at session open)
├── problemIds: Set<String> (snapshot from widget.problemIds)
├── startedAt: DateTime (UTC)
├── lastLanguage: String? (session-wide language memory)
├── scratches: Map<problemId, LeetCodeScratchEntry>
└── expandedProblemId: String? (which problem's editor is fullscreen, if any)

LeetCodeScratchEntry
├── code: String
├── language: String
├── expanded: bool (per-problem expanded state for undo restore)
└── templateInitialized: bool (starter applied once)
```

On problem first visit in session:

1. If `scratches[problemId]` exists (undo / revisit) → restore it.
2. Else create entry with `language = lastLanguage ?? firstSolution.codeLanguage ?? 'python'`, `code = deriveStarterTemplate(...)`, `templateInitialized = true`.

On every edit: update in-memory map, debounce flush to disk.

On normal dispose / `Back to deck`: `scratchDraftStore.clearSession(sessionId)`.

---

## Storage

### Model: session-scoped + crash recovery

- **Primary contract:** scratch belongs to **this** Study/Cram session. Normal exit deletes all scratches for that session.
- **Within session:** each problem has its own entry; advancing keeps it; undo/redo restores prior entries; session-complete undo still has access.
- **Crash recovery:** debounced writes to a single local file (e.g. `leetcode_scratch_session.json`) containing the active `LeetCodeScratchSession` blob.
- **Fresh session:** always start with empty scratches — never silently preload from a previous day's work.
- **Recovery UX:** when Study or Cram opens, if the store contains an **orphaned** session (file exists, `endedNormally != true`, and optionally overlapping `problemIds`), show a toast:

  > *Resume scratch work from your last session?*  
  > Actions: **Restore** (hydrate map into new session — see below) / **Discard** (delete file)

  **Restore semantics:** start a new `sessionId` but copy `scratches` and `lastLanguage` from the orphan. Do not replay queue position — only scratch content carries over.

- **Not synced** — same tier as `LeetCodeTrackDraft`.

### File shape (v1)

```json
{
  "version": 1,
  "sessionId": "uuid",
  "problemIds": ["id1", "id2"],
  "startedAt": "2026-08-31T16:00:00.000Z",
  "endedNormally": false,
  "lastLanguage": "python",
  "scratches": {
    "id1": {
      "code": "class Solution:\n    def solve(self):\n        pass",
      "language": "python",
      "expanded": false
    }
  }
}
```

On normal exit set `endedNormally: true` then delete the file (or delete outright — implementation choice; file must not be offered for recovery after clean exit).

### Autosave

- Debounce: **400 ms** (match Track draft).
- Chain writes like `FileLeetCodeTrackDraftStore` so flush-on-dispose cannot race debounce.
- Flush on: debounce, expanded close, problem advance, app lifecycle pause (if hook exists elsewhere).

---

## UI

### Settings toggle

Add to `_hideToggles` list in `leetcode_review_deck.dart` (or a sibling list in the same popover section):

- Label: **Enable scratch code**
- Field: `leetCodeEnableScratchCode`
- Persists through `settingsProvider` / Firestore sync like other Study & Cram display prefs.

When off, session pages render exactly as today (centered card only).

### Collapsed session layout

```text
┌────────────────────────────────────────────────────────────┐
│ [×]              counter / title               [↩] [↪]   │
├─────────────────────────────┬──────────────────────────────┤
│                             │  Scratch pad (collapsed)     │
│  LeetCodeFlashcard          │  LeetCodeCodeField preview   │
│  flip front/back            │  ~35% width                  │
│  ~65% width                 │  click → expand              │
├─────────────────────────────┴──────────────────────────────┤
│  StudyGradingRow / Cram buttons                            │
└────────────────────────────────────────────────────────────┘
```

- Card max dimensions stay capped (~760×720) but the **row** uses available width; scratch panel takes **~35%** of the session content area (card ~65%).
- **Narrow breakpoint** (suggest `< 720` logical px width): `Column` with card on top, scratch below; wrap in `VoyagerScrollView` so user can scroll to see both.
- Collapsed pad shows a clipped preview of code (monospace, syntax highlighted) + subtle "Click to expand" affordance; entire panel is tappable.
- Pad sits **outside** `StudyFlipCard` — only the left pane flips.

### Expanded overlay

Same animation contract as `openLeetCodeDetailView` / `_LeetCodeActivityOverlay`:

- `Rect.lerp` from collapsed panel rect → full screen.
- Semi-transparent scrim behind (dismiss on tap outside).
- Top bar (`GlassButton` row):

  | Control | Behavior |
  | --- | --- |
  | Close | Collapse overlay |
  | Copy solution | `Clipboard.setData` user code; toast *Code copied* (even if empty) |
  | Open on LeetCode | `launchUrl(problem.leetcodeUrl, webOnlyWindowName: '_blank')`; if URL null → `GlassButton` with error/destructive color, `onPressed: null`, tooltip explains |
  | Clear pad | Wipes code to starter template for current language (confirm if non-empty?) — **no confirm v1** unless product asks; prefer single tap + undo via retyping |
  | Strip comments | `stripLeetCodeComments` + trailing blank line strip (same as Track) |
  | Compare | Enters compare mode (below) |

- Body: full `LeetCodeCodeField` with Vim, language pill, line numbers.
- **While expanded:** disable `StudyKeyboardShortcuts` grading/cram handlers and swipe-to-grade on the card behind the overlay (modal barrier + `IgnorePointer` on session chrome as needed).

### Compare mode

Triggered from expanded toolbar **Compare**:

1. Expand if not already expanded.
2. Replace single editor with **two-pane** layout:
   - **Left:** user's scratch (`LeetCodeCodeView` or read-only `LeetCodeCodeField`).
   - **Right:** first non-empty saved solution code on the problem (same selection rule as **Copy code** in context menu). If no solution code → right pane shows muted *No saved solution*.
3. **Linked scroll:** one `ScrollController` drives both panes (GitHub merge-conflict style).
4. Optional: line-level diff highlighting (v2). **v1:** side-by-side with synchronized scroll only; no inline diff markers required for first ship unless cheap with existing widgets.
5. Exit compare via toolbar toggle or close.

Compare is available regardless of **Hide solution code** on the card — it is an explicit user action in the scratch workflow.

### Keyboard

| Key | Context | Action |
| --- | --- | --- |
| `C` | Session shortcuts enabled, scratch pad **not** focused | Focus scratch pad (collapsed: focus editor; if already focused, no-op or expand — pick: **focus + expand**) |
| `Ctrl+Enter` (`Cmd+Enter` on macOS) | Scratch focused, collapsed **or** expanded | Copy the pad **and** open the problem on LeetCode, in that order; toast says which happened. No `leetcodeUrl` → still copies, toast says there is no link |
| `Space` | Scratch focused | Types space in editor |
| `Space` | Scratch not focused | Flip card (unchanged) |
| Grading / cram arrows | Scratch focused | **Disabled** |
| Grading / cram arrows | Expanded overlay open | **Disabled** |
| Vim bindings | Scratch focused | Normal Vim (`Escape` is Vim, not close) |

Implement by extending session keyboard guards:

- `StudyKeyboardShortcuts._enabled()` already returns false when `isTextInputFocused()` — preserves M/N.
- Cram page `_handleArrowKey` must also bail when scratch focused or expanded.
- Add `C` handler at session level when scratch enabled and not text-focused.

---

## Starter template

Best-effort derivation from the **first solution's code** on the problem (first non-empty code block, same rule as `_firstCodeOf`).

### Algorithm (v1)

1. Take first non-empty `solution.code` for the problem.
2. Run `stripLeetCodeComments` (and trailing blank line strip).
3. Language-aware skeleton extraction:
   - **Python:** keep `class Solution:` and top-level `def` lines; replace bodies with `pass` (or single `...`).
   - **Java / C# / C++:** keep `class` + method signatures; replace bodies with `{}` or `;` as appropriate.
   - **JavaScript / TypeScript / Go / Rust:** keep exported/type declarations and function signatures; empty bodies.
   - Helper callables are filtered out, keeping only the entry shape — see [Entry methods vs helpers](LEETCODE_SCRATCH_STARTER_HELPERS.md).
4. If extraction yields nothing usable → language default:

   ```python
   # python
   class Solution:
       def solve(self):
           pass
   ```

   ```java
   // java
   class Solution {
   }
   ```

   (Provide minimal stubs per `leetCodeCodeLanguages`.)

5. Set `templateInitialized` so clearing pad can reset to the same starter.

**Limitation (document in UI copy if needed):** custom or heavily refactored saved solutions may produce imperfect stubs; user can edit freely. A helper the user marked `public` (or, in Python, one that happens to carry the problem's name) is indistinguishable from the entry method and stays in the starter.

---

## Interaction with existing session behavior

### Study (`LeetCodeSessionPage`)

- Queue sync, grading, undo/redo unchanged except scratch map travels with session state.
- On `_grade` / `_replay`: persist current problem's scratch before advancing; restore target problem's scratch after undo/redo.
- `_SessionComplete`: scratches remain in memory until route pop; undo from complete screen still works (V).

### Cram (`LeetCodeCramPage`)

- Bucket logic unchanged.
- Horizontal swipe on card disabled while scratch focused or expanded (only left card pane receives drag).
- `_decide` blocked while expanded.

### Live problem updates

- If problem edited mid-session (`refreshFromLive`), scratch keyed by `problem.id` stays attached to that id.
- If problem deleted, drop its scratch entry; recovery store prunes on next flush.

---

## Edge cases

| Case | Behavior |
| --- | --- |
| Toggle turned off mid-session | Not supported live — setting applies next session open (simplest). Document: finish session or reopen. |
| Problem with no solutions | Starter = language default; language = `lastLanguage ?? 'python'` |
| Multiple solutions | Template from first non-empty code; compare uses same |
| `leetcodeUrl` null | Open button visible, red/disabled styling |
| Empty copy | Copy `""`, still toast |
| Crash mid-expand | Recovery restores `expanded` per problem |
| Very small window | Vertical stack + scroll |
| Reduced motion | Expand uses crossfade / shortened motion per `VoyagerMotion.reduced` (match detail view) |
| High contrast | Glass surfaces follow existing card/editor tokens |

---

## Testing

| Area | Cases |
| --- | --- |
| Settings | Toggle persists; default off; sync payload includes field |
| Store | Round-trip JSON; corrupt file → empty; chained writes; normal exit clears; orphan detection |
| Starter | Python/Java/JS signatures; fallback when code empty; comment stripping |
| Session | Advance preserves per-problem code; undo restores; cram blocked when expanded |
| Keyboard | `C` focuses; Space flips only when editor unfocused; no grade when focused |
| Compare | Linked scroll; empty solution pane |
| Recovery toast | Restore / Discard paths |

Follow patterns in `test/leetcode_track_draft_test.dart`, `test/leetcode_session_test.dart`, `test/leetcode_session_hides_test.dart`.

---

## Implementation order

1. Settings flag + DB migration + popover row  
2. `LeetCodeScratchDraft` + store + starter helper  
3. `LeetCodeScratchPad` widget (collapsed + expanded)  
4. Wire into `LeetCodeSessionPage`  
5. Wire into `LeetCodeCramPage` + cram keyboard/swipe guards  
6. Compare mode + toolbar actions  
7. Crash recovery toast on session entry  
8. Tests  

After code lands: `graphify update .`

---

## What shipped differently from this spec

Written down because each of these resolves something the spec above left
contradictory or open — the spec text is kept as-is so the two can be compared.

- **Expanded editor is inset, not full-bleed.** "Editor fills the page" and
  "collapse by clicking outside" cannot both hold; a full-bleed panel has no
  outside. The panel takes 92% of the window over a scrim, and that margin is
  the click target. Escape stays with Vim, as locked.
- **The collapsed pad's text area is a live editor.** "Entire panel is
  tappable → expand" would make the pad impossible to type in, while the
  keyboard table requires a *focused* collapsed pad (Space types a space). The
  header strip is the expand affordance instead; `C` still does focus+expand.
- **Compare ships with line diff highlighting.** The spec deferred it to v2
  "unless cheap with existing widgets" — an LCS line alignment turned out to be
  a small pure helper (`leetcode_scratch_diff.dart`), and side-by-side without
  markers is most of the value gone.
- **Starter derivation covers Python and the brace languages only.** Go and
  Rust declare themselves in shapes (receivers, `impl` blocks, lifetimes) where
  a line heuristic reliably emits a stub that does not parse, so they take the
  language default. Derivation also requires the saved solution's language to
  *match* the pad's — a Python `def` extracted into a Java pad is neither
  language.
- **`C` yields to a user-bound grading key.** The four grades are
  user-configurable and one of them could be `C`. Grading is checked first, so
  on the back of the card a `C` bound to a grade still grades; on the front it
  opens the pad. A binding the user chose is never silently taken away.
- **The new session claims the recovery file at open.** Otherwise the live
  session autosaves over the orphan before the user answers the toast. The
  orphan is read into memory first, so an ignored toast resolves to *discard* —
  which is what "a fresh session never silently preloads" already required.
- **`endedNormally` is written but the clean exit deletes the file.** Disposal
  *is* the normal exit — the ×, Back to deck, and a system back all pop the
  route — and a crash never reaches it. So file-exists is the orphan signal;
  the flag is honoured on read for forward compatibility.
- **No `templateInitialized` flag.** The starter is a pure function of the
  problem and the language, so Clear recomputes it rather than storing one.
  An entry that already exists is never re-derived, which is what protects
  typing.
- **Clear pad confirm:** v1 single-tap clear, as specced; add a confirm if user
  testing shows accidental clears.
- **Ctrl+Enter is the handoff, not a submit.** `CTRL_ENTER_SUBMIT_HLD.md` §6.6
  keeps code editors out as *submit* targets, and that still holds — the pad has
  nothing to save. The chord instead runs Copy and Open together, because going
  to run an attempt always means both, and the collapsed pad has no toolbar to
  click either of them in. It reuses `CtrlEnterToSubmitScope` so the chord is
  claimed (an unhandled Enter would type a newline into the code being copied)
  and so macOS gets `Cmd+Enter` for free.
