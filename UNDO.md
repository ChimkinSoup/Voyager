# Snippet undo vs Vim `u`

Design note for making Normal-mode Vim `u` revert a snippet expansion the same way Ctrl/Cmd+Z already does.

Related: `SNIPPET.md` §5 and §11.2, `lib/core/snippets/snippet_session.dart` (`undoLastExpansion`), `lib/core/vim/vim_session.dart` (Normal `u`).

Status: **proposed** — not implemented yet.

---

## 1. Desired product behavior

After a successful snippet expansion, **one undo** should:

1. Restore the pre-expansion text (the trigger still present, caret after it).
2. Clear tabstop sessions created by that expansion (entire stack is fine).

That matches `SNIPPET.md` §5 (“single undo atom”).

---

## 2. What works today

### 2.1 Ctrl/Cmd+Z

`SnippetSession.handleKey` claims Ctrl/Cmd+Z while the field text and selection still match the post-expansion value it recorded. It calls `undoLastExpansion()`, which applies the saved `before` value and clears the session stack.

Any edit after the expansion invalidates the record and hands the key back to Flutter.

Covered by `test/snippet_expansion_test.dart` (`undo` group).

### 2.2 Why the field undo stack alone is not enough

Flutter’s `UndoHistory` pushes on a **500 ms trailing throttle**. The last typed character of a trigger and the expansion it causes usually coalesce into **one** stack entry. Native undo then jumps **past** the trigger instead of restoring it.

So the snippet layer owns “undo expansion,” not `UndoHistory`.

---

## 3. What does not work today

### 3.1 Vim Normal `u`

`VimSession` handles Normal-mode `u` by calling `UndoHistoryController.undo` (with list-editing suppression). It does **not** call `undoLastExpansion()`.

Visual-mode `u` means lowercase over the selection — leave that alone.

### 3.2 Why `u` was left out

Not a technical blocker. Deliberate omission:

- Snippet undo was wired only for the OS shortcut in `SnippetSession`.
- Bare `u` cannot be claimed there: in Insert, `u` must type the letter.
- §11.2 assumed leaving Insert often clears snippet state so field undo was “good enough.” That assumption is weak: Esc alone does **not** clear sessions if the caret stays in the region (`SNIPPET.md` §4.2 / decision 8), and `_lastExpansion` can still be valid after Esc.

---

## 4. Proposed change

Make Normal-mode `u` prefer the same path as Ctrl/Cmd+Z.

### 4.1 Behavior

On Normal `u`:

1. Try `SnippetSession.undoLastExpansion()` (same guards as Ctrl+Z).
2. If it returns `false`, fall through to today’s `undoController.undo`.

No second undo model. Same “text still equals post-expansion `after`” rule.

### 4.2 Wiring

`VimTextScope` already owns both `VimSession` and `SnippetSession`. Prefer a **live callback** into `VimSession` (e.g. “try snippet undo”) rather than storing a `SnippetSession` reference — the snippet session can be recreated when settings sync.

Do **not** intercept bare `u` in `SnippetSession.handleKey`.

### 4.3 Caveat (already accepted for Ctrl+Z)

After a custom restore, Flutter’s undo stack may be slightly out of sync for a **follow-up** `u`. Same tradeoff as today’s Ctrl+Z path; reusing it does not invent a new problem.

### 4.4 Effort

**Small / easy:** hook + one branch in Normal `u` + widget test(s) + a short update to `SNIPPET.md` §11.2. Roughly on the order of an hour, not an architecture change.

---

## 5. Test plan

- Expand a snippet with Vim on → Esc (caret still in region) → `u` → trigger restored, caret after trigger, no leftover tabstops.
- Expand → type something else → Esc → `u` → does **not** restore the stale trigger (falls through to field undo).
- Visual `u` still lowercases; Insert typing `u` still inserts `u`.

---

## 6. Out of scope (for this change)

- Forcing Flutter’s throttle to emit separate undo atoms for trigger vs expansion.
- Changing Ctrl+Z behavior.
- Redo (`Ctrl+R` / Vim redo) mirroring.
- Mobile / soft-keyboard undo chrome.
