# Autocorrect (HLD)

Conservative, dictionary-backed autocorrect for Voyager prose fields: only fix typos that are one insertion, one deletion, or one adjacent transposition away from a known word, and only when the correction is unambiguous within that error class. Snippets, tags, inline code, and explicit user rejection all take precedence.

This is a high-level design. It records product decisions and the intended architecture against the existing spell-check, snippet, and Vim stacks. It is not an implementation checklist.

Status: **implemented** (2026-08-31). This document stays the design of record; §16 lists where the code departs from it and why.

Related: `lib/core/spellcheck/` (especially `spell_check_suggestions.dart`, `voyager_spell_check_service.dart`, `spell_check_tokenizer.dart`), `lib/core/snippets/snippet_session.dart`, `lib/core/vim/vim_session.dart`, `lib/core/widgets/voyager_text_field.dart`, `lib/core/widgets/spell_check_squiggle_layer.dart`, `DICTIONARY.md`, `FLAGGED_WORDS.md` (user-authored replacements, not the cascade), `SNIPPET.md`, `VIM.md`.

---

## 1. Goals

- Auto-fix **obvious typos** at word boundaries without the aggressiveness of platform IME autocorrect.
- Use the **same dictionary** as spell-check (bundled English ∪ custom words).
- Respect **snippets** (triggers may be intentional “misspellings”; expansion must not fight correction).
- Respect **user override** (iOS-style revert on immediate backspace; do not re-offer the same correction in the field after rejection).
- Run only in **plain Insert** when Vim is enabled (`VimMode.insert`); when Vim is off, every keystroke is plain insert.
- Ship with a **global settings toggle**, default **on**.

### Non-goals (v1)

- Substituting one wrong letter for another (`from` → `form`) — excluded from the edit model.
- Edit-distance-2 or frequency-ranked guessing when the transpose → delete → insert cascade is ambiguous.
- Autocorrect in **single-line** fields, **code** fields, or **search** UI.
- Autocorrect inside `#tags`, `` `inline code` ``, or on **ALL CAPS** tokens.
- Syncing rejection / suppression state across devices (local to the field session on this device).
- Replacing the existing squiggle + right-click suggestion flow (ambiguous cases stay squiggle-only).

---

## 2. Product behavior (summary)

| Situation | Autocorrect? |
| --- | --- |
| User types a word (≥3 chars) and presses a **boundary** key (space, newline, `. , ! ? ; :`, `*` etc.) | Maybe — if all gates pass |
| User clicks into an old paragraph, **edits** a word with keystrokes, presses boundary | **Yes** — see §4.3 |
| User **selects** a word and types over it | **No** |
| Paste, sync pull, `controller.value = …`, snippet expansion text | **No** |
| IME composing range active | **No** |
| Word is ALL CAPS | **No** |
| Word is a **custom dictionary** entry or bundled known word | **No** |
| Word exactly matches a **snippet trigger** | **No** |
| Token inside `#tag` or `` `inline code` `` | **No** |
| Cascade finds no unique hit per step | **No** — squiggle only |
| User rejected autocorrect (revert) for this typo in this field | **No** — until field unfocused |
| Token sits after an unclosed `` ` `` | **No** — inline code runs to end of document |
| Autocorrect disabled in settings / field opts out | **No** |

**Boundary keys (v1):** space, newline, and punctuation `. , ! ? ; :`. **Not** boundaries: `-`, `_` (do not split tokens; tokenizer unchanged).

**Minimum length:** 3 characters before autocorrect is considered.

**Capitalization:** preserve first-letter case of the typo (`Wtih` → `With`).

---

## 3. Correction algorithm

Reuse the Norvig-style generator in `spell_check_suggestions.dart`, but **split candidates by operation** and apply a strict cascade. **Replace** (wrong letter) is never an allowed autocorrect path.

### 3.1 Cascade (per-step uniqueness)

For the completed token `T` (lowercased for lookup):

1. **Transpose** — every adjacent swap of `T`. If **exactly one** result ∈ `known`, use it.
2. **Delete** — delete one character from `T`. If **exactly one** result ∈ `known`, use it.
3. **Insert** — insert `a`–`z` at each position. If **exactly one** result ∈ `known`, use it.
4. Otherwise → **no autocorrect** (squiggle + right-click suggestions unchanged).

No frequency tiebreaker in v1.

### 3.2 Applying the correction

- Replace the token span in the controller with the chosen word, applying first-letter case preservation.
- Record the edit as a **single undo step** (one `TextEditingValue` assignment).
- Show a **brief low-opacity background highlight** on the corrected word (see §9).
- Mark the correction in session state for revert / suppression (see §7).

---

## 4. Eligibility gates

All gates must pass before the cascade runs.

### 4.1 Field and mode

- **Multiline spell-check fields only** — same predicate as `SpellCheckSquiggleLayer` today (`isMultilineField`).
- **Explicit opt-out** on search UI fields and code fields (`autocorrectAllowed: false` or equivalent, alongside existing `snippetsAllowed: false` on code).
- **Vim:** only when `VimMode.insert`. Normal / Visual / Visual-line: no autocorrect.
- **Settings:** `autocorrectEnabled` (name TBD) global toggle, default `true`. Independent of `snippetsEnabled` but both can be on.

### 4.2 Typed input only

Share the same “was this real typing?” predicate as `SnippetSession` (`_wasTyped`, single-character insert, not mid-composition, hardware keyboard rules on desktop):

- **No** paste (multi-char insert).
- **No** programmatic writes (sync, redo of non-typing origin, snippet `_applyValue`, etc.).
- **No** autocorrect chained from a previous autocorrect in the same mutation.

The **boundary keystroke** itself must also be typed (not simulated).

`*` joined the boundary characters on 2026-09-02, because it closes emphasis
(EMPHASIS_FORMATTING.md §6.2). `_` and `=` did not and cannot — `snake_case`
and `x = 5` would autocorrect their first halves — so `__` and `==` finish a
word only on their **second** character, which is the one case where the word
being typed survives the caret leaving it.

### 4.3 “User typed this word” (token eligibility)

This is **not** “the whole token was typed from scratch.” It **is**:

> The token completed by this boundary event was modified by at least one **insertion** keystroke since the caret last entered the token.

Consequences:

| Action | Autocorrect on next boundary? |
| --- | --- |
| Type new word at end of line + space | Yes |
| Click into `width`, change one letter to `wtih`, space | Yes |
| Click into word, **only delete** letters, space (no insertions) | **No** |
| Select word, type replacement | Yes — the keystroke that *replaces* the selection does not count (it is not a single insert), but typing on into the new token does. The prose rule above is the normative one; see §16.2 |
| Delete entire word, retype `wtih`, space | Yes |
| After reject + delete, retype same typo `wtih`, space | **No** (suppression list — §7.3) |

**Caret entry:** when the caret moves from outside the token’s character span to inside it, clear the “has insertion in token” flag. Each subsequent insertion inside the span sets the flag.

### 4.4 Exclusion spans

Extend tokenization (for autocorrect **and ideally squiggles**) beyond `#tags`:

| Span | Rule |
| --- | --- |
| `#tags` | Existing `journalTagPattern` exclusion |
| `` `inline code` `` | Paired backticks — exclude tokens inside. **Unclosed** backtick: exclude from opening backtick to **end of document** (same line is insufficient if the backtick can wrap; use end of text for consistency with “end of document”) |
| `$…$` LaTeX | Added 2026-09-02 with emphasis formatting. Paired `$`, no unclosed rule — an unpaired `$` is a price, not the start of an equation |

Words in these spans are never autocorrected.

**Since 2026-09-02 these are `ProseMarkup`'s exclusion zones**
(EMPHASIS_FORMATTING.md §2.3), not predicates of autocorrect's own, so a code
span ends in the same place here as it does for the formatting parser. The
squiggles use the same zones with one deliberate difference — an unclosed
backtick still leaves the rest of the entry spellchecked, since taking the
marks off everything below one stray character is a louder failure than a
squiggle inside half-written code (EMPHASIS_FORMATTING.md §6.1).

### 4.5 Dictionary and triggers

- **Known words** (`bundled ∪ custom`) are never corrected away from.
- **Snippet trigger exemption:** if the completed token (case-insensitive) **exactly equals** any registered snippet trigger, skip autocorrect — even when snippet expansion did not fire on this boundary.

### 4.6 ALL CAPS

If the token matches `^[A-Z]+$` (length ≥ 3), skip autocorrect (acronyms).

---

## 5. Snippet integration

Snippets and autocorrect share a boundary pipeline on **Space** and **Tab** (when Tab is the configured snippet expand key). **Auto-expand snippets** (last trigger character, no boundary) are unchanged.

### 5.1 Order on boundary key (Space or Tab)

On a typed boundary key:

```text
1. Snippet matching / expansion (existing SnippetSession logic)
2. If text changed → STOP (no autocorrect this keystroke)
3. Else → run autocorrect on the word before the boundary
```

Rationale: snippet triggers may be intentional non-words; expansion must see the trigger literal first.

### 5.2 Isolation rules

| Rule | Reason |
| --- | --- |
| Autocorrect output must **not** be snippet-expanded | Corrected word might match a trigger |
| Snippet expansion text must **not** be autocorrected | Programmatic insert |
| Snippet expansion must **not** run as a consequence of autocorrect | Same |
| Use the same microtask ordering as today: snippet expansion microtask completes **before** autocorrect microtask on the same key | Avoid double `controller.value` races |

### 5.3 Punctuation boundaries

For `. , ! ? ; :` and newline, **only autocorrect runs** (snippets do not expand on those keys in v1). Pipeline: typed boundary → autocorrect gate → cascade.

### 5.4 Additional safeguards

- Reuse `SnippetSession._applying` / equivalent guard so autocorrect never runs during snippet apply.
- Reuse single-char insert detection so a pasted boundary does not fire either system.
- Snippet trigger exemption (§4.5) covers the case where expansion is manual or failed but the token is still a deliberate trigger.

---

## 6. Vim

- Autocorrect only in **Insert** mode, same gate as snippet auto-expand (`isInsertMode()`).
- **No special Vim hooks** for rejection suppression: suppression is keyed on the **typo string** in field session state (§7.3). Deleting the word with `dw`, `x`, or backspace does not clear suppression; retyping the same typo still will not autocorrect until unfocus.
- Vim **put** / bulk insert: ineligible (not single-char typing).
- Dot repeat: out of scope for v1; autocorrect does not need to integrate with `_DotRecord`.

---

## 7. Rejection, revert, and suppression

### 7.1 Scope

- **Local only** — per device, not synced.
- **Per field until unfocus** — clearing on `FocusNode` blur / dispose.

### 7.2 iOS-style revert (immediate backspace)

After autocorrect `typo` → `correction`:

- If the **next** keystroke is Backspace, before any other edit (insertion elsewhere, second autocorrect, snippet expansion, paste, etc.), it does **both** halves of "no, I meant that" in one mutation: the boundary character it would have deleted goes, **and** the word reverts to `typo`. The caret lands where the backspace left it, at the end of the restored typo.
- The autocorrect layer claims the key, so the field never sees it. A **second** backspace deletes normally.
- Reverted typo is **squiggle-flagged** (invalid word again).
- Add `typo` (lowercased) to the field’s **suppression set** (§7.3).

“Immediate” means: autocorrect was the **most recent** document mutation; cursor movement alone does not cancel revert eligibility.

### 7.3 Suppression set

- Set of lowercase typo strings that must **not** be autocorrected again in this field session.
- Populated when user triggers iOS revert (§7.2).
- Also blocks the scenario: reject → delete word entirely (any method, including Vim) → retype same typo → boundary. **No Vim-specific tracking required.**

### 7.4 Add to dictionary from rejection

After revert, the squiggle is visible. The existing spell-check context menu **Add to dictionary** remains available so the user can promote the typo to a custom word if they meant it.

---

## 8. Undo / redo

- Each autocorrect is **one undo step**.
- Undo restores the pre-correction text and selection.
- Redo restores the corrected form.
- Snippet expansion and autocorrect on the same boundary key are **not** one combined step (only one should run per key per §5.1).

---

## 9. Visual feedback

On successful autocorrect:

- Brief **background highlight** on the corrected token (low opacity; theme-aware).
- Fade out over ~300–500 ms without blocking typing.
- No toast in v1.

---

## 10. Settings

| Setting | Default | Notes |
| --- | --- | --- |
| `autocorrectEnabled` | `true` | Master switch in Settings; mirrors `snippetsEnabled` pattern. **Narrowed by `FLAGGED_WORDS.md` §5.1:** it gates the speculative cascade only. A stored flagged-word pair is a rule the user wrote, so it still applies with this off, and the session is now built for every eligible prose field rather than only while this is on. |
| (existing) `snippetsEnabled` | `true` | Unchanged |
| (existing) `snippetExpandKey` | user choice | Tab and Space both use §5.1 pipeline |

Persist in `AppSettings` / sync like other toggles.

---

## 11. Architecture (intended)

### 11.1 New module

`lib/core/spellcheck/autocorrect_session.dart` (name TBD) — one instance per eligible field, owned beside `SnippetSession` in `VimTextScope`:

- Listens to `TextEditingController` changes (or shares snippet’s listener ordering).
- Holds per-field session state: suppression set, last autocorrect metadata (for revert), token insertion flags, last mutation kind.
- Calls into `AutocorrectEngine` (pure functions) for cascade + case preservation.

### 11.2 Pure engine

`lib/core/spellcheck/autocorrect_engine.dart`:

- `AutocorrectResult? suggest(String token, Set<String> known)` — cascade only.
- `String applyCase(String typo, String correction)` — first-letter preservation.
- Split `_edits1` into transpose / delete / insert lists (or filter replace out).

### 11.3 Token spans

Extend `spell_check_tokenizer.dart` (or sibling) with `tokenizeWordsExcludingInlineCode` used by autocorrect and optionally squiggles.

### 11.4 Field wiring

- `VoyagerTextField` / `TagHighlightedTextField` / `LabeledTextField`: pass `autocorrectAllowed` (default true where spell-check multiline applies).
- Search page fields: `autocorrectAllowed: false`.
- LeetCode code field: already excluded.

### 11.5 Highlight overlay

Lightweight listener on controller (or hook in squiggle layer) to paint the flash behind the corrected range for one animation.

### 11.6 Ordering with SnippetSession

Document in code: **SnippetSession listener runs first**; autocorrect session runs after on the same notification, or autocorrect is scheduled in a second microtask that snippet’s expansion microtask precedes.

---

## 12. Delete-only edits (confirmed)

Clicking into an existing word and **only deleting** characters (no insertions) before pressing a boundary does **not** trigger autocorrect. The “at least one insertion since caret entry” rule (§4.3) is intentional: autocorrect requires the user to have **typed something into** the token, not merely shortened it.

---

## 13. Edge cases checklist

| Case | Expected |
| --- | --- |
| `wtih` + space | `with` (transpose unique) |
| `wtih` + space, snippet trigger `wtih` exists | No correct (trigger exemption) |
| `sig` + space, snippet expands | Expansion only; no autocorrect on `sig` |
| `hello wtih` + space after `wtih` | Snippet pass on `wtih` fails; autocorrect `wtih` → `with` |
| Autocorrect `with` matches snippet trigger | No expansion |
| IME composition | Wait until committed |
| Custom word `mybrand` typed | Known — no correct |
| `WTIH` | ALL CAPS skip |
| `donwt` + space | Apostrophe words use existing tokenizer |
| Undo autocorrect | Restores typo |
| Redo | Restores correction |
| Field blur | Clear suppression + revert state |
| Sync replaces body | No autocorrect on pulled text |
| Autocorrect disabled in settings | Gate off everywhere |

---

## 14. Testing (intended)

- Pure unit tests: cascade uniqueness, case preservation, ALL CAPS skip, trigger exemption.
- Engine tests: exclusion spans (`#tag`, `` `code `` unclosed).
- Widget / integration: snippet-before-autocorrect order, no expansion after correct, revert on immediate backspace, suppression after reject + delete + retype.
- Vim insert-only gate.
- Search field opt-out.

---

## 15. Decision log

| Date | Decision |
| --- | --- |
| 2026-08-31 | Transpose → delete → insert cascade with per-step uniqueness; no frequency fallback. |
| 2026-08-31 | Snippet expansion before autocorrect on Space/Tab; mutual isolation after. |
| 2026-08-31 | iOS revert on immediate backspace; suppression per typo string per field until unfocus. |
| 2026-08-31 | Global toggle default on; visual flash; search fields excluded; inline code excluded. |
| 2026-08-31 | Editing existing words via keystrokes + boundary **does** autocorrect; select-overwrite does not. |
| 2026-08-31 | After reject, retyping same typo (even after Vim delete) stays suppressed — no Vim-specific state. |
| 2026-08-31 | Delete-only edits before a boundary do not trigger autocorrect (insertion required since caret entered token). |
| 2026-08-31 | Backspace after a correction deletes the boundary character **and** reverts the word, in one mutation — rather than reverting without deleting. Reverting alone would leave §7.2 reachable only by a keystroke that does nothing visible on its first press. |
| 2026-08-31 | Inline-code exclusion applies to **autocorrect only**, not to squiggles: one stray backtick would otherwise take the squiggles off everything below it in a long entry, which is a change to spell-check that autocorrect has no business making. |
| 2026-09-16 | A word run holding a **digit** is out of spell-check entirely — no squiggle, no correction. Scanning for letters alone read `3D` as the word `D` and `XM6's` as `XM` and `s`, three squiggles under a model number; the dictionary cannot hold an alphanumeric either, so there was no way to dismiss them. The cost is that a typo with a digit stuck to it (`wtih2`) goes unflagged. |
| 2026-09-16 | A **possessive** leans on its base word: `dog's` is known when `dog` is (`isKnownWord`). The bundled list has no possessives, so they squiggled — and `dogs` is one deletion away, so the cascade was rewriting the apostrophe out of them. |
| 2026-08-31 | Tab is **not** an autocorrect boundary (§2's list wins over §5.1's "Space or Tab"). Tab inserts no character in Voyager's fields — it advances a tabstop, indents a list line or moves focus — so there is no boundary keystroke to gate on. |

---

## 16. As built

Implemented 2026-08-31. Where the code differs from the design above, this is why.

### 16.1 Files

| File | Role |
| --- | --- |
| `lib/core/spellcheck/autocorrect_engine.dart` | Pure: the cascade, case preservation, ALL-CAPS test, token spans, exclusion spans, and the edit-diff/re-anchor helpers the session and the flash layer share. |
| `lib/core/spellcheck/autocorrect_session.dart` | Per-field runtime: gates, tracking, the correction write, revert, undo, suppression. |
| `lib/core/spellcheck/autocorrect_enabled_scope.dart` | Publishes the setting and the dictionary to every field, beside `SnippetEnabledScope`. |
| `lib/core/widgets/autocorrect_flash_layer.dart` | The fade behind a corrected word (§9). |
| `test/autocorrect_engine_test.dart`, `test/autocorrect_session_test.dart` | §14. |

### 16.2 Departures from §11

- **Exclusion spans are in the engine, not the tokenizer** (§11.3). The decision above keeps inline code out of spell-check, so there was nothing for `spell_check_tokenizer.dart` to learn. `#tag` exclusion is answered by walking back from the token rather than by scanning the document for every tag in it — the same answer `tokenizeWords` gives, at O(token) instead of O(document) per boundary keystroke.
- **The "user typed this word" rule needs no caret-entry hook** (§4.3). Setting the tracked span on every typed word character, re-anchoring it across other edits and dropping it when the caret leaves gives every case in the table at once. What it did *not* give for free: a snippet expansion that replaces exactly the tracked token used to re-anchor as "an edit inside the token" and inherit its flag, which would have autocorrected the expansion's own text on the next space (§5.2). An edit reaching into the token now keeps the flag only when it is one typed character or a deletion.
- **Ordering with the snippet layer is asked twice, not assumed** (§11.6). Listener registration order is not fixed — settings changes create and destroy the snippet session over a field's life — so the autocorrect session asks `SnippetSession.hasPendingExpansion` rather than relying on which controller listener runs first. One poll is not enough: `hasPendingExpansion` only becomes true *inside* the snippet session's own listener, so a poll from the autocorrect listener is answered correctly only while the snippet listener happens to be registered first. The synchronous poll stays as a cheap early-out for that order; the poll that is actually sound runs inside the queued microtask, which drains only after every listener for that notification has run. Without it, a trigger ending in a boundary character (`h.`, `eg.`) lost its expansion to a correction whenever the snippet session outlived the autocorrect one's creation.
- **A correction survives the field's own `onChanged`.** Every list-aware field calls `applyListEditing` from `onChanged`, which writes the continuation marker back after an Enter — a second controller notification from one keystroke, arriving before the correction's microtask drains. The microtask re-anchors the token span across that edit and verifies it still reads as exactly the typo, rather than dropping the correction; otherwise §2's newline boundary silently never fired inside a list line. When it re-anchors, the recorded boundary offset is discarded: the newline is no longer the character the reverting Backspace would delete, so that Backspace is spent entirely on putting the typo back and the list line is left intact.
- **Revert and undo compare text, not the whole value** (§7.2). `TextEditingValue.==` includes the selection, so comparing it made any caret movement cancel revert eligibility — which §7.2 explicitly says it must not, and which mattered most for Ctrl+Z, where clicking away first is ordinary. The mode gate that replaces it was previously holding by accident: it was only Vim's `Esc` stepping the caret back one character that stopped a Normal-mode Backspace (a left motion) from being claimed here. `isInsertMode()` now gates the keys too, matching §4.1's gate on the correction itself.
- **"The dictionary has loaded" is asked of the bundled dictionary.** `knownWords` is `bundled ∪ custom`, filled by two independent listeners, and the local custom-word read usually settles first — so a non-empty set can hold nothing but the user's own added words, in which case every real English word reads as unknown and the only correction targets are those names. The session is handed an empty set until `VoyagerSpellCheckService.dictionaryLoaded`.
- **A snippet write identifies itself** (§5.2, §5.4). "Was this typed?" works off the shape of the diff, and an expansion one character longer than its trigger and sharing its prefix (`sig` → `sign`) is shaped exactly like one typed character at the caret. On the platforms with no hardware keyboard the diff test's last resort waves every write through, so the session polls `SnippetSession.isApplying` instead of inferring it — the guard §5.4 asked for.
- **The flash lays its geometry out once.** The fade drives the painter directly through `CustomPainter.repaint` and caches the boxes, rather than rebuilding the `CustomPaint` per tick with a new colour: that made `shouldRepaint` true every frame, and `paint` laid a `TextPainter` out over the whole field text ~27 times per fade, on the keystroke after a correction.
- **An ASCII fragment of a longer word is not corrected.** `_isLetter` is ASCII-only, so `caféwtih` presents `wtih` as a whole token — the same split `wordTokenPattern` makes, so the squiggle already treats it that way. Underlining a fragment and silently rewriting one are not the same thing, so autocorrect declines when the character beside the token is a letter it cannot read. The same guard now covers a digit beside the token — `enc` in `x264enc`, `D` in `3D` — because `tokenizeWords` drops a run holding a digit whole and a correction must not reach into what carries no squiggle (`isInAlphanumericRun`).
- **The correction is deferred by a microtask**, like snippet expansion and for the same reason: writing inside the controller notification that found it would re-enter `EditableTextState` mid-dispatch. It still lands before the next frame, so the typo is never painted.
- **Ctrl+Z is claimed** (§8). Flutter's `UndoHistory` pushes on a 500ms trailing throttle, so the correction coalesces with the keystrokes that produced it and its own undo would jump back past the whole word. Same fix as `SnippetSession.undoLastExpansion`.

### 16.3 Where it is switched off

`VimTextScope.autocorrectAllowed`, plus the multiline rule, which is the field's own `isMultilineField` answer — so every single-line composer, rename box and the search query field are excluded by construction rather than by an opt-out list. Explicit opt-outs: the LeetCode code editor, the snippet editor, and the dictionary editor, where the whole point of the word being typed is that it is not in the dictionary yet.
