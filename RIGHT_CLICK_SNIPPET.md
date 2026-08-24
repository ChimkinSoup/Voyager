# Right-click Add Snippet — High-Level Design

Status: implemented (2026-08-24). See
`lib/core/widgets/spell_check_field_support.dart` (trigger resolution and the
shared `contextMenuBuilder`), `lib/core/widgets/text_field_context_menu.dart`
(the menu itself), `lib/core/widgets/quick_add_snippet.dart` (the popover),
`lib/core/widgets/snippet_editor.dart` (the form, shared with settings),
`lib/core/snippets/snippet_settings_launcher.dart`, and
`test/snippet_quick_add_test.dart`.

---

## Goal

Let the user create a text snippet from any eligible prose text field without opening Settings. Right-click (or long-press) a word or selection → choose **Add snippet** → fill the same create form used in Settings (without the existing-snippet list) → save into the shared snippets store.

## Non-goals (v1)

- Editing an existing snippet from the context menu
- Prefilling replacement from the selection
- Showing the `${…}` unsupported-placeholder warning in this flow
- Offering this menu on code text boxes (`leetcode_code_field` and any field with `snippetsAllowed: false`)

---

## User flow

1. User right-clicks or long-presses in an eligible text field.
2. The app resolves a **trigger candidate** (see Trigger resolution).
3. If the candidate is empty/junk → **no context menu** (same as today when there is nothing useful to show).
4. Otherwise a context menu appears near the pointer:
   - If the cursor/selection is on a **misspelled** word: existing spellcheck UI (suggestions, then **Add to dictionary**), then **Add snippet** at the bottom.
   - If not misspelled: a menu containing **Add snippet** only (when snippets are enabled).
5. User taps **Add snippet**.
6. An **Add snippet** editor panel opens **near the click**, visually matching the Settings “new snippet” editor row:
   - Trigger (prefilled; editable)
   - Replacement
   - Expand automatically (default **off**)
   - Only at word boundaries (default **off**)
   - Cancel / Save
   - **Manage all snippets…** action
7. Focus lands on **Replacement** on open.
8. Save runs the **same validation as Settings** (non-empty trigger; unique trigger). On failure, block save and show the same style of inline error; keep the panel open.
9. On success: persist snippet, dismiss panel, brief toast (e.g. “Snippet saved”), restore focus to the **original text field**.
10. Cancel / dismiss without save: discard draft, restore focus to the original text field.
11. **Manage all snippets…**: dismiss the quick-add panel without saving the draft, then open the existing full Settings snippets dialog (`showSnippetsDialog`).

---

## Trigger resolution

Priority:

1. If the field already has a **non-collapsed selection** with non-whitespace content → use that full selection as the trigger (multi-word / partial-word allowed).
2. Else use the word selected by the existing secondary-tap / long-press word-select behavior (same path spellcheck already relies on).

**Junk / no menu:** after resolution, if the candidate is empty or whitespace-only → show no context menu (and do not show Add snippet alone). Spellcheck-only menus are unchanged: if there is a misspelling span but no usable trigger candidate, continue to show the spellcheck popup as today; omit Add snippet in that case.

---

## When “Add snippet” is shown

| Condition | Add snippet item |
| --- | --- |
| Global **Enable snippets** is off | Hidden. Spellcheck menu still works when applicable; correct words still show nothing. |
| Field is a **code** field / `snippetsAllowed: false` | Never show Add snippet (and do not introduce a snippet context menu on those fields). |
| Trigger candidate empty / whitespace-only | Hidden (see above). |
| Otherwise, on any field where snippets would expand | Shown. |

Interpretation of “do not allow when snippets disabled”: hide the **Add snippet** affordance only; do **not** remove misspelling suggestions / Add to dictionary.

---

## Field scope

**Include:** all prose text fields where snippets can expand today — single-line and multiline — via the shared field stack (`VoyagerTextField`, `LabeledTextField`, `TagHighlightedTextField`, and any other call sites that already wire Voyager spellcheck / snippet sessions), as long as `snippetsAllowed` is effectively true and snippets are globally enabled.

**Exclude:** code editors (`leetcode_code_field` already forces `snippetsAllowed: false`), snippet/dictionary settings editors that opt out, and any other field that opts out of snippets.

**Implication:** single-line fields that today swallow right-click with an empty `contextMenuBuilder` must gain the same secondary-tap/long-press → context-menu path used for this feature when snippets are enabled and a valid trigger candidate exists. Spellcheck squiggles remain multiline-only as today; this feature is independent of spellcheck being on.

---

## UI / presentation

### Context menu

- Reuse the existing Voyager context-menu look (`ContextMenuPanel` / spellcheck popup styling).
- Label: **Add snippet** (parallel placement to **Add to dictionary**, always **last** among spellcheck-related items).
- Long-press on touch: same menu and follow-on editor as right-click.

### Quick-add editor

- Same fields and controls as Settings’ `_SnippetEditor` create row (trigger, replacement, two checkboxes, cancel, save).
- **Not** embedded in the full snippets list dialog: no prior snippets, no Enable snippets toggle, no Expand key control, no `${…}` warning.
- Anchored **near the click** (popover/overlay), not a centered Settings-style modal — still large enough to edit comfortably.
- Editor text fields must use `snippetsAllowed: false` (same rule as Settings: typing a trigger must not expand while editing snippets).

### Toast

- Brief success confirmation after a successful save only.

### Manage all snippets

- Text/button in the quick-add panel.
- Closes quick-add without saving, then opens `showSnippetsDialog`.

---

## Data & validation

- Persist through the existing settings snippets list (`settingsProvider` / same write path Settings uses).
- New snippet: generate id via existing `newId()`, trigger trimmed, replacement as typed, flags from checkboxes.
- Validation (match Settings):
  - Empty trigger → block save with existing message (“Give the snippet a trigger.”).
  - Duplicate trigger (another snippet’s trigger equals this one) → block save with existing message.
- Empty replacement remains legal (same as Settings).
- Sync/backup: no new collection; snippets already sync with settings.

---

## Architecture (implementation sketch)

No code in this doc — intended shape for implementers:

1. **Shared create-snippet UI**  
   Extract or reuse the Settings new-snippet editor so Settings and the right-click flow share one form (draft model: trigger, replacement, autoExpand, wordBoundary).

2. **Context menu builder**  
   Extend the shared text-field context-menu path (today: `voyagerSpellCheckContextMenuBuilder` + `SpellCheckPopup`):
   - Resolve trigger candidate from selection or word under cursor.
   - Append **Add snippet** when allowed.
   - For non-misspelled eligible words, return a small menu with only that item instead of `SizedBox.shrink()`.

3. **Show quick-add**  
   On item tap: hide toolbar/menu, open anchored quick-add with prefilled trigger, remember the originating `FocusNode` / field to restore focus later.

4. **Save**  
   Validate → append snippet → save settings → toast → focus restore.

5. **Gating**  
   Read global snippets enabled (settings / `SnippetEnabledScope`) and field `snippetsAllowed` before showing the item.

6. **Single-line coverage**  
   Ensure eligible single-line fields participate in secondary-tap word select + context menu when this feature applies (today secondary-tap wrap is largely spellcheck/multiline-tied).

---

## Edge-case summary

| Case | Behavior |
| --- | --- |
| Misspelled word, snippets on | Suggestions → Add to dictionary → **Add snippet** |
| Correct word, snippets on, valid candidate | Menu with **Add snippet** only |
| Snippets off | No Add snippet; spellcheck unchanged |
| Empty / whitespace target | No menu (unless misspelling UI still applies without Add snippet) |
| Multi-word selection | Entire selection becomes prefilled trigger |
| Duplicate trigger on save | Inline error; stay open |
| Code field | No Add snippet menu |
| After save / cancel | Focus returns to original field |
| Manage all snippets | Discard draft; open full snippets dialog |

---

## Decisions log (from product)

1. Small context item first; not an immediate editor. Same pattern as Add to dictionary; Add snippet sits below all dictionary/spellcheck options.
2. Shown alongside existing spellcheck popup when misspelled.
3. Prefer existing non-collapsed selection as trigger; else the clicked word.
4. Empty/junk → no right-click menu for this feature (unchanged emptiness when there is nothing to show).
5. Same validation as Settings; block save on failure.
6. If Enable snippets is off → do not allow create; do not show the Add snippet menu item (spellcheck menus remain).
7. Quick-add UI near the click.
8. Focus Replacement on open; restore original field focus after save (and after cancel/dismiss).
9. All snippet-eligible text fields (single- and multiline); never code boxes.
10. Long-press same as right-click.
11. Auto-expand and word-boundary default **off**.
12. Related: keep dictionary + suggestions; skip Edit snippet; brief toast; include Manage all snippets; skip `${…}` warning; no “use selection as replacement.”

---

## Acceptance criteria

- Right-click/long-press a normal word in a journal/todo/etc. field with snippets enabled → **Add snippet** appears; save creates a working snippet.
- Misspelled word → suggestions and Add to dictionary still appear; **Add snippet** is last.
- Snippets disabled → no Add snippet item anywhere.
- Code field → no Add snippet item.
- Prefill uses selection when present, else the word under the pointer; user can edit trigger before save.
- Duplicate / empty trigger cannot save; error visible in the panel.
- Save shows a short toast and returns caret/focus to the field that was edited.
- Manage all snippets opens the existing Settings snippets UI without leaving a half-saved draft behind.
