# Flagged words (HLD)

A personal overlay on the bundled dictionary: flag a word that Voyager currently accepts (`neve`) so later uses squiggle, and optionally remember a replacement so finishing that token rewrites it (`neve` → `never`).

This is a high-level design. It records product decisions and the intended architecture against the existing spell-check, dictionary, and autocorrect stacks. It is not an implementation checklist.

Status: **implemented**.

Related: `DICTIONARY.md` (supersedes the v1 non-goal “no blocklist”), `AUTOCORRECT.md`, `lib/core/spellcheck/`, `lib/features/settings/dictionary_dialog.dart`, `lib/core/widgets/text_field_context_menu.dart`, `lib/core/widgets/flag_word_popover.dart`, `lib/core/widgets/quick_add_snippet.dart`.

---

## 1. Goals

- Let the user tell Voyager that a word it accepts is wrong **for them**, without editing the bundled English list.
- Flag from the field (right-click a word that is not squiggled) and from the Dictionary dialog.
- Squiggle every later use of that exact token, including text already on screen.
- Optionally store a replacement. Automatic rewrite only when they finish typing that token. The occurrence they flagged is offered, never rewritten silently.
- Keep the mapping reversible from the spell menu and from Settings.
- Sync flags and replacements the same way custom words already sync.

### Non-goals

- Editing or deleting `assets/dictionary_en.txt`.
- Guessing a replacement when the cascade is ambiguous, or when the typo is a wrong letter (`then` / `than`). Those stay squiggle-only unless the user chose a pair.
- Rewriting every existing occurrence in already-written documents. Those squiggle. The user replaces them one at a time.
- Stemming, plurals, or phrases. `neve` does not cover `neves`. `form` does not cover `from`.
- A frequency guard. Flagging `the` is allowed. Undo is the Settings list.
- Per-journal or per-field dictionaries.
- Replacing snippets. A snippet trigger that exactly equals the token still wins over a stored replacement.

---

## 2. Decisions locked in

1. **Both halves ship together.** Flagging is the feature. Always-replace is optional on the same record, not a later product.
2. **Entry points are the field menu and the Dictionary dialog.** Settings can add, edit, and remove. The field cannot be the only writer.
3. **The word under the cursor squiggles as soon as the flag is saved.** If a replacement was chosen, the same popover offers to replace **this occurrence**. No is a complete success: the flag stands, the word stays.
4. **Allow wins.** Add to dictionary, or adding the same string as a custom word, clears the flag and its replacement.
5. **No common-word guard.** No confirm dialog, no refuse-list.

### Assumptions (not separately decided)

- Copy says **flag**, not “remove from the dictionary.” The word stays in the bundled list. The user is overriding it.
- Automatic replacement is a user-authored rule. It does **not** follow the `autocorrectEnabled` toggle. That toggle still gates the speculative cascade only. Turning autocorrect off does not forget pairs. Removing the replacement, or the flag, is how they stop the rewrite.
- Case-insensitive, same as the checker today. Flagging `neve` also flags `Neve`.
- Automatic replacement preserves first-letter case (`Neve` → `Never`), same as autocorrect.
- A stored replacement must already be known (`bundled ∪ custom`) and must not itself be flagged. Do not invent a new word as the target.
- Snippet exact-trigger exemption still beats the pair. Spell-check does not otherwise special-case snippet triggers: a flagged trigger still squiggles.

---

## 3. What exists today

A token is correct when it is in `bundled ∪ custom`. `VoyagerSpellCheckService.checkTextSync` skips anything in that set. `neve` is in `assets/dictionary_en.txt`, so it never produces a `SuggestionSpan`.

The right-click menu only offers spell actions when `misspellingAtCursor` finds a span. A known word gets “Add snippet” or no menu.

`DICTIONARY.md` §1 and the bundled row in `dictionary_dialog.dart` say there is no blocklist. Remove only tombstones a custom extra. A bundled word that is also custom stays allowed after the custom row is removed.

Autocorrect (`AUTOCORRECT.md`) never rewrites a known word, and only rewrites an unknown token when one of transpose / delete / insert has exactly one dictionary hit. A wrong letter is not in that model (`then` / `than`).

Flagging a word removes it from `known`, which is the only thing that makes the cascade willing to look at it. What happens next depends on that word, not on a special "flagged" autocorrect mode. See §5.4.

Squiggles already redraw when `knownWordsChanged` fires. Custom words already sync as tombstoned rows keyed by the word string. This design reuses both.

---

## 4. Product model

```text
known    = (bundled ∪ custom) − flagged
flagged  = live flagged-word rows
pair     = flagged word whose replacement is non-null
```

`known` is what squiggles, suggestions, and the speculative cascade consult. A flagged word is unknown. It is also not a legal **target** of someone else's correction (`nvee` must not be rewritten to `neve`).

| Kind | Known how | User can |
| --- | --- | --- |
| Bundled, not flagged | bundled | Look up. Flag. Optionally set a replacement. |
| Custom extra, not bundled | custom only | Rename, remove. Flag is the wrong verb — remove already makes it unknown. |
| Bundled and custom | both | Flag tombstones the custom row and writes a flag. Otherwise remove-custom would look like it worked. |
| Flagged | neither, while the flag is live | Edit replacement, stop flagging. |
| Unknown, not flagged | neither | Add to dictionary, as today. |

**Flag** on a custom-only word is not a new row. It is `removeCustomWord`. The dialog and the menu should do that rather than creating a flag that the bundled list does not need.

**Stop flagging** deletes the flag and the replacement. If the word is bundled, it is allowed again. Do not write a custom row for a bundled word (`DICTIONARY.md` already rejects that duplicate).

**Add to dictionary** on a flagged word is the same clear, even if the menu label is “Stop flagging” (below). Allow wins means the flag is gone. It does not mean a redundant custom row for a bundled spelling.

---

## 5. Always-replace

The pair is not the cascade. Once saved, finishing the flagged token applies that replacement and stops. No uniqueness check, no insert/delete/transpose search.

### 5.1 When it rewrites

Same gates as a speculative autocorrect, except “must be unknown” is already true and the cascade is skipped:

| Gate | Rule |
| --- | --- |
| Field | Multiline spell-check fields only. Not search, not code, not single-line. |
| Input | The completed token was modified by at least one insertion keystroke since the caret entered it. Not paste, not programmatic writes, not a chained rewrite. |
| Boundary | Space, newline, and `. , ! ? ; :` and `*` — the existing autocorrect boundaries. |
| Vim | Insert mode only. |
| Markup | Same exclusion zones as autocorrect (`#tag`, paired inline code, `$…$`). |
| ALL CAPS | Token matching `^[A-Z]+$` (length ≥ 3) is not rewritten. It still squiggles. |
| Snippet | If the token exactly equals a snippet trigger, skip the pair. Snippets run first on Space/Tab; if expansion changed the text, stop. |
| Session reject | Immediate backspace reverts, then that lowercase token is suppressed in this field until unfocus. Same as `AUTOCORRECT.md` §7. |
| Autocorrect toggle | Ignored. The pair is not a guess. |

Minimum length is the tokenizer, not the cascade's 3. They chose the pair. `ab` → `abc` is allowed if they set it.

Capitalization: preserve first-letter case of the typed token. Do not invent title case for later letters.

### 5.2 What it does not do

- Does not walk a document replacing every match. Opening a note full of `neve` only squiggles them. The one exception is the occurrence they just flagged, and only if they click **Replace this one**.
- Does not expand a snippet from the replacement, and the replacement is not fed back into the cascade. Same isolation as `AUTOCORRECT.md` §5.2.
- Revert-on-backspace restores the flagged token and leaves it squiggled. A second backspace deletes normally.

### 5.3 Pipeline

On a typed boundary, after the existing snippet step:

```text
1. Snippet matching / expansion
2. If text changed → STOP
3. If token has a live pair and the gates in §5.1 pass → apply pair, STOP
4. Else → existing cascade (unchanged), including for a flagged word with no pair
```

Step 4 is why a flag with no replacement can still rewrite. The cascade does not know about flags. It only sees that the token is not in `known`. If one transpose, delete, or insert is unique, it applies that word. If not, it leaves the squiggle.

Worked cases, assuming the other gates pass and no pair is stored:

| Typed token, flagged, no pair | Cascade | Result |
| --- | --- | --- |
| `form` | Adjacent swap of `o`/`r` is `from`. `ofrm` and `fomr` are not in the bundled list, so transpose has exactly one hit. | Rewrites to `from`. Same as any other unique transpose. |
| `from` | Still known. Flagging `form` does not flag `from`. | Left alone. |
| `neve` | Insert finds both `never` and `nerve`. No unique hit. | Squiggle only. Does not become `never`. |
| `then` | `than` is a different letter, not a swap, delete, or insert. | Squiggle only. Never guessed. |
| `wtih` | Unique transpose to `with`, whether or not it was flagged. It was already unknown. | Rewrites to `with`, as today. |

A stored pair skips that table. `form` → `shape` if that is what they saved, even though the cascade would have picked `from`. `then` → `than` if that is what they saved, which the cascade will never do on its own. Ambiguous steps do not get a frequency tie-break just because the word was flagged.

Undo of an automatic rewrite is one step, same as autocorrect. Redo restores the replacement.

### 5.4 Flash

Any time a pair is applied, the corrected token gets the same brief background flash as a cascade rewrite (`AUTOCORRECT.md` §9, `AutocorrectFlashLayer`).

That includes both:

- the boundary rewrite in §5.3 step 3
- **Replace this one** on the occurrence they just flagged

Both must go through the same apply path that already sets `flashListenable` (`AutocorrectSession._applyCorrection`), not a bare `controller.value` write that would change the word with no highlight. Same fade, same peak opacity, no toast, and the same immediate-backspace revert. A cascade hit on a flagged word with no pair already flashes, because it is an ordinary autocorrect.

Picking a normal suggestion on an unflagged misspelling does not start flashing. That menu apply stays as it is. The flash is for a replacement the session itself just wrote: cascade, stored pair, or the one offered click that applies a pair.

---

## 6. The occurrence they flagged

Right-click a known word, choose **Flag as misspelling…**, which opens a small popover on the field's context (same lifetime rules as `showQuickAddSnippet`: the context menu is torn down; the popover, and any toast, use the field).

The popover:

- Shows the token, read-only.
- **Always replace with** is optional. Empty means flag only. Prefill with the first suggestion from the existing generator against the known set **after** this word is treated as unknown, if that list is non-empty. They can clear it, pick another suggestion, or type a legal token.
- Reject a replacement that is empty-after-trim handled as “no pair,” equals the flagged word, is not a tokenizer word (`[A-Za-z]+(?:'[A-Za-z]+)*`), or is not known once this flag is applied.
- Primary action: **Flag**. Writes the row, invalidates, waits for the checker to see it. The word squiggles. Popover stays long enough for the second question when a replacement was saved.
- If a replacement was saved: **Replace this one?** with Replace / Leave it. Replace applies only to the span they clicked, with first-letter case preserved, and flashes that span the same way a boundary autocorrect does (§5.4). Leave it closes. Dismiss / Escape is Leave it — the flag is already saved. Do not roll the flag back because they dismissed the offer.
- No toast for flag-only. A short toast is fine after a successful “replace this one,” matching other one-shot edits if the field already toasts similar actions; do not toast the flag itself.

If the clicked span is not a single tokenizer word (selection of several words, caret in whitespace), do not offer Flag. Do not flag a multi-word selection.

Right-click a word that is **already** flagged (it squiggles):

- Suggestions, with the stored replacement pinned first and not duplicated in the rest of the list.
- **Stop flagging** instead of **Add to dictionary**. Same clear as allow-wins. “Add to dictionary” is the wrong sentence for a word that is already in the bundled list.
- Changing the replacement is a Settings / row-edit action, not a second item on this menu in v1. The popover is for creating the flag. The dialog is for editing it.

---

## 7. Dictionary dialog

The dialog already searches `bundled ∪ custom` and shows overrides when the query is empty. Flagged words are a third override, listed with custom words when the query is empty — not buried in a 65k dump.

**Empty query**

- Custom extras, then flagged words. Or one list with a kind on each row. Either is fine if flagged vs custom is obvious.
- Empty state copy must mention both: extra words the checker accepts, and words you have told it to flag.
- Settings subtitle on the Dictionary tile counts both, or says `{n} custom, {m} flagged` when either is non-zero. Do not keep “custom words” as the only number once flags exist.

**Bundled row**

- Still not renamed. Gains a flag action (or stops showing the book-only affordance once flagged).
- Flagging from search opens the same replacement field inline or a compact editor on that row. No second dialog required if the row can hold an optional replacement. Saving writes the flag. There is no “this occurrence” here.

**Flagged row**

- Shows the word and the replacement if any (`neve` → `never`, or `neve` with no arrow).
- Edit: change or clear the replacement. Clearing keeps the flag.
- Trash / stop flagging: removes the flag. Bundled words become allowed again. Confirm is not required (custom remove does not confirm).

**Search**

- A flagged bundled word is a flagged row, not a faint “in the built-in dictionary” row. One row, one state.
- Adding a custom word that is currently flagged clears the flag (allow wins) and then follows the existing bundled-duplicate rule: if it is bundled, the result is “unflagged, already in the dictionary,” not a new custom row.

Do not let the dialog's own field fight this. It already opts out of spellcheck.

---

## 8. Field menu details

`voyagerTextContextMenuBuilder` today returns nothing when there is no misspelling and no snippet trigger. A known word with neither still needs a menu if Flag is offered.

Resolve the token at the cursor with the same word-pick autocorrect already uses (letter/apostrophe span), not only `misspellingAtCursor`. Then:

| Under the cursor | Menu |
| --- | --- |
| Unknown, not flagged | Suggestions, **Add to dictionary**. Unchanged. |
| Known, not flagged | **Flag as misspelling…** Then snippet item if any. |
| Flagged | Suggestions (pair pinned), **Stop flagging**. Snippet item if any. |
| No token | Snippet only, or nothing. Unchanged. |

Flag is not offered in fields that opt out of spellcheck (code, search, the dictionary field itself).

“Add snippet” stays last, and stays available on a word you are also flagging. Creating a snippet whose trigger equals a flagged word is allowed. Expansion still wins; the squiggle can still show. Do not refuse one because the other exists.

---

## 9. Spell-check live update

No new paint path. After flag, edit replacement, or stop flagging:

1. Repository write and sync notify.
2. Invalidate the flagged-words provider (and custom-words, when a custom row was tombstoned in the same action). Await if the popover or dialog must show the new state before the next question.
3. The service applies `known = (bundled ∪ custom) − flagged` and bumps `generation`.
4. `SpellCheckSquiggleLayer` already listens to `knownWordsChanged`.

Do not poke individual `EditableTextState`s. Open fields pick up the squiggle on that generation bump. The suggestion cache clears with the generation, same as `updateCustomWords`.

`knownWords` used by autocorrect must be this subtracted set, or the cascade can still treat `neve` as a landing site for other typos.

---

## 10. Data, sync, backup

New collection, parallel to custom words. Do not overload `custom_words`: that row means “allow,” and a tombstone there already means “stop allowing this extra,” not “deny a bundled word.”

| Field | Notes |
| --- | --- |
| `word` | Primary key and Firestore document id. Trimmed, lowercased. Tokenizer shape. |
| `replacement` | Optional lowercase tokenizer word, or absent. Not equal to `word`. |
| `createdAt`, `updatedAt`, `version`, `deletedAt` | Same tombstone shape as `CustomWord`. |

| Change | Needed? |
| --- | --- |
| New Drift table + schema version | Yes |
| New Firestore collection (e.g. `flagged_words`) | Yes |
| `SettingsRepository` flag / update replacement / unflag | Yes |
| Backup / import | Yes, same pattern as `backup_collections.dart` custom words |
| Bundled asset | No |

Rename of the flagged word itself is not a feature. They stop flagging and flag the other spelling. Editing the replacement is an in-place update on the same id.

Flagging a bundled word that also has a live custom row: tombstone the custom row and upsert the flag in one local transaction, two sync notifies. Other devices may see those documents in either order; the live flag is what the checker trusts once both have landed. Until the custom tombstone arrives, `known` still subtracts the flag, so the word stays unknown. That is the safe order.

**Replacement that later becomes flagged.** If they flag `never` while `neve` → `never` exists, clear that pair's replacement (keep the `neve` flag) or refuse the new flag until the pair is edited. Prefer **refuse the new flag** with a short error naming the pair. Silent clearing hides a rule they wrote. Settings can list which flags point at a word before they flag the target.

**Sync of rejection / suppression** stays local to the field session, same as autocorrect. The pair itself syncs. “I reverted this once in this note” does not.

---

## 11. Edge cases

| Case | Behavior |
| --- | --- |
| `neve` flagged, no pair | Squiggle. Right-click shows normal suggestions. No automatic rewrite, including because `never` and `nerve` both match insert. |
| `form` flagged, no pair | Cascade treats it as an unknown typo. Unique transpose is `from`, so a typed boundary rewrites it to `from` and flashes. Already-written `form` only squiggles. |
| `neve` → `never` | Pair wins over the cascade. Boundary rewrite to `never`, with the same flash. Suggest `never` first on already-written `neve`. |
| `form` → `from` | Pair applies `from` and flashes, even though the cascade would have chosen the same word. Revert and suppression are the pair path, not a second cascade guess. |
| `then` → `than` | Pair applies `than` and flashes. Without the pair, flagging `then` only squiggles. |
| `Neve` / `NEVE` | Both squiggle. `Neve` may auto-replace to `Never`. `NEVE` squiggles and is not auto-replaced (ALL CAPS). “Replace this one” still applies, with first-letter case, if they click a suggestion. |
| Name they actually meant | Stop flagging. There is no per-occurrence exception. |
| `neves`, `neved` | Not flagged. Separate tokens. |
| Hyphen / digits | Not a tokenizer word. Cannot flag `well-known` or `voyager2` as one entry. Same validation as custom words. |
| Flag `the` | Allowed. Squiggles everywhere. Undo in Settings. No confirm. |
| Add to dictionary / custom add of a flagged word | Clear the flag and the pair. Bundled: stop there. Not bundled: custom row, existing rules. |
| Flag a custom-only word | Remove the custom word. No flag row. |
| Flag a bundled+custom word | Tombstone custom, write flag. |
| Stop flagging | Flag and pair gone. Bundled word allowed again. |
| Pair target equals flagged word | Reject. |
| Pair target unknown or itself flagged | Reject. They add the target as a custom word first if it is not English. |
| Flag the current target of another pair | Refuse, name the existing pair. |
| Snippet trigger `neve` and pair `neve` → `never` | Snippet wins on Space/Tab. Word still squiggles when left unexpanded. |
| Paste, sync pull, Vim put | No rewrite. Squiggle if the token is flagged. |
| Click into an old `neve` and press space without inserting | No rewrite (`AUTOCORRECT.md` §4.3). Squiggle remains. |
| Immediate backspace after a pair rewrite | Revert to the flagged token, squiggle, suppress that token in this field until unfocus. |
| Two devices | Last write to that word id wins, tombstones included. Same conflict shape as custom words. |
| Dictionary not loaded yet | Checker flags nothing today. Do not apply pairs until `dictionaryLoaded`, so a half-loaded set cannot rewrite a real word toward a custom name. |

---

## 12. Files (when implementing)

- `lib/core/spellcheck/voyager_spell_check_service.dart` — subtract flagged from `known`; bump generation; exclude flagged from suggestion targets.
- `lib/core/spellcheck/autocorrect_session.dart` — pair step before the cascade; both pair applies set `flashListenable` through `_applyCorrection`; same revert / suppression.
- `lib/core/widgets/spell_check_field_support.dart` + `text_field_context_menu.dart` — token-at-cursor for known words; Flag / Stop flagging.
- New flag popover, modeled on `quick_add_snippet.dart`.
- `lib/features/settings/dictionary_dialog.dart` — flagged rows, flag action on bundled rows, allow-wins on add.
- `lib/domain/models/settings_models.dart`, Drift, `SettingsRepository`, Firestore mapper, backup collections, `providers.dart`.
- `DICTIONARY.md` — the “no blocklist” non-goal points here once this ships. Until then this document is the override.
- Tests: known-set subtraction; flag bundled vs remove custom-only; allow-wins; pair applied only on eligible boundaries and flashes via `flashListenable`; `form` flagged with no pair cascades to `from`; `neve` does not cascade to `never` without a pair; `then` does not cascade to `than`; a pair wins over a unique cascade hit; ALL CAPS not rewritten; snippet trigger beats pair; revert suppresses; replacement rejected when unknown or circular; dialog row states.

---

## 13. Copy

- Menu: **Flag as misspelling…**
- Popover title: the token. Field label: **Always replace with** (optional).
- Buttons: **Flag**, then **Replace this one** / **Leave it**.
- Menu on a flagged word: **Stop flagging**
- Settings: **Flagged** on the row; arrow only when a replacement exists.
- Do not say “Removed from dictionary” or “Deleted `neve`.” The English list did not change.
