# App-wide dictionary (HLD)

A Settings dialog for the spell-check dictionary: search the bundled word list, type in extra words, rename custom words, and remove custom words so they are flagged again.

This is a high-level design. It records product decisions and the intended architecture against the existing spell-check / custom-word stack. It is not an implementation checklist.

Status: **shipped**. One design point changed on contact with the asset — see §4.

Related: `lib/core/spellcheck/`, `lib/core/widgets/spell_check_popup.dart`, `CustomWord` in `lib/domain/models/settings_models.dart`, `addCustomWord` / `removeCustomWord` in the settings repository, `lib/features/settings/custom_quotes_dialog.dart` (closest UI analog).

---

## 1. Goals

- Give the user one **app-wide** place to see and change which extra words the spell checker accepts.
- Let them **type a word in** without first misspelling it in a field and using **Add to dictionary**.
- Let them **rename** a custom word (fix a typo in the dictionary itself).
- Let them **remove** a custom word so that spelling is flagged again.
- Let them **search the bundled English list** (~65k words already loaded at startup), not only their overrides.

### Non-goals (v1)

- A **blocklist** for words that are already in the bundled dictionary. Bundled words stay allowed. "Remove" does not mean “flag `colour` even though it is English.”
- Editing or deleting bundled words.
- Per-field / per-journal dictionaries.
- Stemming, plurals, or “add all forms of this word.” Each token is its own entry, matching how the tokenizer works today.
- Bulk paste / import of a word list (backup already round-trips custom words).
- Replacing the misspelling popup’s **Add to dictionary** action.

---

## 2. What exists today

The checker is `VoyagerSpellCheckService`: a bundled set union a user set.

| Layer | Behavior |
| --- | --- |
| Bundled list | `assets/dictionary_en.txt` (~65k lines). Loaded once via `dictionaryProvider` / `loadDictionaryFromAssets`, kept alive, warmed at shell start. |
| Custom words | `CustomWord` rows. The **word string is the primary key** and the Firestore document id. |
| Add | `addCustomWord` — trim, lowercase, upsert. Called only from the spell-check popup. |
| Remove | `removeCustomWord` — tombstones the row so the removal syncs. **No UI calls it.** |
| Rename | Does not exist. Quotes were given a stable `id` specifically because quote text is editable; custom words were keyed on the string because the string *is* the identity. |
| Sync | `upsertCustomWord` notifies `FirestoreCollections.customWords`. Popup add does not call a separate `pushCustom*` helper. |
| Live update | `customWordsProvider` → `service.updateCustomWords` → `generation` bump → squiggle layer redraws. |

`providers.dart` still comments custom words as “local-only (never synced).” That is stale; they sync. Fix the comment when this ships.

---

## 3. Product model

There is still only an **allowlist overlay** on the bundled dictionary. A token is known if it is in the bundled set **or** in the non-tombstoned custom set.

```text
known = bundled ∪ custom
```

Three kinds of string the dialog can show:

| Kind | In bundled? | In custom? | User can |
| --- | --- | --- | --- |
| Bundled | yes | irrelevant | Look up. Not editable, not removable. |
| Custom extra | no | yes | Rename, remove (then it is flagged again). |
| Unknown | no | no | Add. |

Adding a word that is already bundled is rejected (“Already in the dictionary”), the same way custom quotes refuse a quote already in the pool. A redundant custom row for a bundled word would not change spellcheck and would make “remove” look like it did something when it did not.

**Allow / remove** in this design:

- **Allow** = add to the custom set (only useful when the word is not already bundled).
- **Remove** = remove from the custom set. The word is flagged again *only if* it is not in the bundled list.

---

## 4. Why the full bundled list is in scope

The worry with listing ~65k words is load cost. That cost is already paid: `dictionaryProvider` is `keepAlive` and is awaited in `shellDataWarmupProvider`. The dialog must **reuse that set**, not re-read the asset.

What would actually be expensive is mounting 65k list rows. The dialog never does that:

- **Empty search** lists **custom words only** (usually dozens, not thousands).
- **Non-empty search** filters `bundled ∪ custom` in memory (~65k string compares; fine on the UI isolate) and shows a **capped** result list via `ListView.builder`.
- A one-character query like `s` would otherwise return thousands of hits. Cap at **100**, ranked **exact match → prefix → contains**, and **always include matching custom words** even if that nudges past the cap. Hint: “Type more to narrow.”

Fallback if search is still janky in practice: keep empty-search = custom only, and require at least **2 characters** before querying the bundled set. Do not drop bundled search from the product without measuring.

**As built — the list is not alphabetical.** `assets/dictionary_en.txt` is ordered by descending frequency (`you`, `i`, `the` … `emese`, `xerxos`), and `loadDictionaryFromAssets` builds a `LinkedHashSet`, so that order is already in memory. `searchDictionary` ranks by it instead of sorting:

- `s` answers with `so`, `she`, `some` rather than the alphabetically first `sa`, `saab`, `saag` — a far better answer to "is this word in here?"
- No sort. Sorting the 65k set measured **32 ms**, which is a dropped frame on the dialog's open animation.
- The scan **stops as soon as the cap is full of prefix matches** — nothing found later can outrank them — so a short query reads a few hundred entries, not 65k. A full pass measured 1.8–3.7 ms, and only a query too rare to fill the cap pays it.
- That rare query's result is *complete*, so it is handed back as `candidates` and every longer query typed after it narrows that list instead of rescanning. Typing `strawberry` costs one scan, not ten.
- The exact match is a direct set lookup, not something the scan has to reach: a rare word can sit below a cap's worth of commoner words sharing its prefix, and "yes, that exact word is known" is the one answer that must never be the thing left out.

Custom words are still sorted A–Z — they have no frequency to rank by.

The order is load-bearing rather than incidental, so it is documented at `loadDictionaryFromAssets` as well: sorting there, or swapping in an unordered set, would quietly make search both worse and slower.

---

## 5. UI

### 5.1 Settings entry

A `ListTile` on the Settings page, next to **Custom quotes** / **Text snippets**.

- Title: `Dictionary`
- Subtitle: `Add extra words the spell checker should accept` when empty; otherwise `{n} custom word(s)`.
- Opens `showDictionaryDialog` via `showVoyagerDialog`, same shell as quotes and snippets.

### 5.2 Dialog

Layout, density, and chrome follow `custom_quotes_dialog.dart`: title, short explanation, input row, scrollable list, **Done**.

**Input row** — one field, two jobs:

1. Filters the list as the user types.
2. If the normalized query is a legal word and not already known, a plus button (and Enter) **adds** it. Same control quotes use for “Add a quote.”

Do not ship a second “add” field. Search-then-add is how you look up “is `voyager` in here?” and add it if not.

**Empty query**

- List custom extras, A–Z.
- Empty state: “You haven’t added any extra words yet. Search the dictionary or type a word to add it.”
- Bundled words are not listed.

**Non-empty query**

- Matching custom extras first (editable / removable).
- Then matching bundled words (read-only, faint “In dictionary” / book icon).
- If the query itself is unknown, the add control is enabled; if it is already known, the add control is disabled and the matching row is enough.

**Custom row**

- Tap or pencil: inline rename, same pattern as `_QuoteEditor` (own controller so list rebuilds from sync do not eat in-progress text). Enter saves; ✕ cancels. Escape stays with Vim if a session is live in the field.
- Trash: remove.
- No confirmation dialog for a single-word remove (quotes do not confirm either).

**Bundled row**

- Not tappable for edit. No trash. The word is already allowed and cannot be removed in v1.

**Normalization and validation** (add and rename)

- Trim, lowercase (same as `addCustomWord` today).
- Must match the spell-check tokenizer: `[A-Za-z]+(?:'[A-Za-z]+)*` so `don't` is legal, `hello world`, `voyager2`, and `well-known` are not. Reject with a short error rather than silently taking the first token.
- Reject empty.
- Reject if the result is already in `bundled ∪ custom` (rename may match *itself*).
- Rename onto a bundled word: do not create a custom row; just remove the old custom word. The new spelling is already allowed. Tell the user that, e.g. “Removed — ‘the’ is already in the dictionary.”

The dialog’s text field should opt out of spellcheck (and snippets, the way the snippets dialog does) so typing a not-yet-added word is not a fight with squiggles.

### 5.3 Misspelling popup

Unchanged: **Add to dictionary** still adds and invalidates `customWordsProvider`. After this ships, that word appears in the Settings list and can be renamed or removed there.

No “Manage dictionary…” item on the popup in v1.

---

## 6. Rename without changing the primary key

Do **not** migrate `CustomWordsTable` to a UUID `id`. For this collection the word string is the identity: spellcheck, the tokenizer, and Firestore doc ids all key on it. Quotes needed a stable id because the *text* was not the identity.

Rename is **tombstone the old word + upsert the new word**, in one repository method:

```text
renameCustomWord(from, to)
  normalize both
  validate `to` (shape, not empty, not equal to `from`)
  if `to` is already a live custom word → no-op / error (duplicate)
  removeCustomWord(from)          // tombstone, version++, sync notify
  if `to` is not in the bundled set:
    addCustomWord(to)             // insert or un-tombstone, sync notify
```

Both notifies go through the existing `_syncedWrites?.notifyOne(FirestoreCollections.customWords, word)` path. Other devices pull a deleted old doc and a live new doc. That is the correct sync shape for “this spelling is gone, this spelling is present.”

A transaction around the two writes keeps a crash from leaving only one side applied locally. Sync can still deliver the two documents in either order; that is already true of add-then-remove.

`CustomWord.copyWith` is not required for the UI if rename goes through this helper. Add it if the mapper / tests want it; quotes have one because they edit in place on a stable id.

---

## 7. Spell-check live update

No new pipeline. After add / remove / rename:

1. Repository write (and sync notify, as today).
2. `ref.invalidate(customWordsProvider)` (and await `.future` if the dialog should reflect the write before the next frame — the popup already does this).
3. Existing `ref.listen` on `customWordsProvider` calls `VoyagerSpellCheckService.updateCustomWords`.
4. `generation` bumps; `SpellCheckSquiggleLayer` already listens to `knownWordsChanged` and re-paints.

Open text fields do not need a special rebuild. Do not have the dialog poke individual `EditableTextState`s.

---

## 8. Data, sync, backup

| Change | Needed? |
| --- | --- |
| New table / column / schema version | No |
| `SettingsRepository.renameCustomWord` | Yes |
| New Firestore collection | No |
| Backup / import of custom words | Already in `backup_collections.dart` |
| `customWordsProvider` | Keep (the `Set<String>` the checker uses) |
| Extra provider for full `CustomWord` records | No, unless the UI later shows dates |

Keep using the outbox / `notifyOne` path, not a quotes-style explicit `pushCustomWord` from the dialog. The popup already relies on the repository to mark the collection dirty.

---

## 9. Files (when implementing)

- `lib/features/settings/dictionary_dialog.dart` — new dialog.
- `lib/features/settings/settings_page.dart` — Dictionary tile.
- `lib/domain/repositories/repositories.dart` + `lib/data/repositories/drift_repositories.dart` — `renameCustomWord`.
- `lib/app/providers.dart` — fix the “never synced” comment; optional subtitle count can keep using `customWordsProvider`.
- Tests: extend `test/custom_words_repository_test.dart` (rename, rename-onto-bundled, duplicate). Widget test for the dialog (add, reject bundled duplicate, edit, remove). Existing squiggle / service tests already cover generation bumps when the custom set changes.

---

## 10. Decisions locked in

1. **Remove** = remove a custom extra, not a blocklist on bundled words.
2. **Search the bundled list** if cheap — it is, because the set is already in memory. Empty search still shows overrides only; search results are capped, and ranked by the asset's own frequency order rather than alphabetically (§4).
3. **Edit** = rename the spelling and remove. Bundled rows stay read-only.
4. **Home** = Settings, same class of dialog as quotes and snippets. Popup add stays.
