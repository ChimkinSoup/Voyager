# LeetCode Cheat Sheet — High-Level Design

An always-reachable reference sheet inside the **LeetCode section**: your own notes on language commands, grouped into tabs and sections, readable at a glance while you are mid-problem and editable when you want to add what you just learned. Syncs across devices; exports as markdown you can paste into an editor and print to PDF.

North star: the thing you keep open beside a LeetCode tab in the browser. Reading it must cost nothing; editing it must never be the default.

This document locks product decisions from the 2026-09-20 design review. It is a high-level design, not an implementation checklist.

Related: `lib/features/leetcode/leetcode_page.dart` (the header the entry point joins), `lib/features/leetcode/leetcode_scratch_pad.dart` (the fullscreen editor's toolbar, and the root-navigator overlay pattern this reuses), `lib/features/leetcode/leetcode_inline_code.dart` (backtick rendering, reused as-is), `lib/features/leetcode/leetcode_code_field.dart` + `leetcode_type_highlight.dart` (per-language highlighting), `SNIPPET.md` (the closest existing synced-list feature), `VOYAGER_SHEET_DISMISS_HLD.md` (the dismiss policy this obeys), `SOFT_DELETE_TOAST.md` (undo), `IMPORT_EXPORT.md` (the backup registry this must join).

Status: **implemented.** Schema 122. `lib/features/leetcode/leetcode_cheat_*.dart`, `lib/domain/models/leetcode_cheat_models.dart`, tests in `test/leetcode_cheat_sheet{,_widget,_migration}_test.dart`.

---

## 1. Goals

- One **cheat sheet** reachable from anywhere inside the LeetCode section, including mid-session and from inside the fullscreen scratch editor.
- **Tabs → sections → entries**, where an entry is a command, what it does, and optionally its complexity.
- Opens in **Viewing** mode, typographically tuned for scanning. **Editing** is a deliberate, separate mode.
- Contents **sync across devices**; the tab you were last on is **device-local**.
- **Click a command to copy it** — the single highest-traffic interaction.
- **Search across every tab**, because "which language did I write that in" is the real question.
- **Export as markdown** to the clipboard, header-form, ready to paste and print.

### Non-goals (v1)

- Any presence outside the LeetCode section. No app-global button, no nav entry, and `Ctrl+Shift+C` is inert everywhere else — including the `/study` flashcard section.
- A global OS hotkey / floater window (the `GLOBAL_HOTKEY_FLOATERS_HLD.md` machinery). In-app only.
- Markdown **import** / round-trip parsing.
- Starred or "frequently used" entries.
- Copying a section from one tab to another.
- Adding to the cheat sheet from the scratch pad's right-click menu.
- Seeded example content — the sheet ships empty, as Snippets does.
- Sub-sections. One level of section headings, full stop.
- CRDT character-level merge of entry text (see §5.3).
- Export to a `.md` file on disk, or direct PDF generation.

---

## 2. Product decisions (locked)

| Decision | Choice |
|----------|--------|
| **Scope** | LeetCode section only. Invisible and inert everywhere else in the app. |
| **Hierarchy** | Tab → Section → Entry. Exactly one level of sections. |
| **Tabs** | **User-created**, each with an optional `languageKey` from `leetCodeCodeLanguages` for syntax highlighting. A tab with no language is legal ("Patterns", "Big-O", "SQL") and renders its commands in plain mono. |
| **Entry fields** | `command` (required), `description` (multi-line, optional), `complexity` (short, optional). |
| **Description content** | Markdown-ish prose: `` `inline code` `` renders via the existing `leetcode_inline_code.dart`, and triple-backtick fenced blocks render as highlighted snippets. Nothing else is parsed. |
| **Ordering** | Manual drag-reorder at all three levels. Fractional `position`, as `SnippetsTable` uses. |
| **Sync granularity** | **One record per tab, per section, per entry.** Three collections. |
| **Concurrent edit of the same entry** | Last-write-wins, per record. Accepted. |
| **Deletes** | Soft delete + `showSoftDeleteUndoToast`. Deleting a section cascades to its entries; deleting a tab cascades to its sections and their entries. Undo restores the whole cascade. |
| **Default mode** | **Viewing**, every single time the sheet opens. |
| **Mode persistence** | Editing survives tab switches *while the sheet stays open*, and resets to Viewing on close. |
| **Entering edit** | Header toggle, or double-click an entry (enters Editing focused on that entry). |
| **Presentation** | Modal overlay on the **root navigator**, with a scrim. Majority of the screen, short of full-bleed. |
| **Dismiss** | ✕ button, the entry-point button toggling it shut, and click-outside — **click-outside is ignored while in Editing mode**. |
| **Escape** | Never dismisses. Escape belongs to Vim, per house rule. |
| **Android back** | Closes the cheat sheet only — never falls through to the scratch editor or session underneath. |
| **Hotkey** | `Ctrl+Shift+C`, LeetCode section only. From Viewing it closes the sheet; from Editing it drops to Viewing, and a second press closes. |
| **Session keyboard** | While the sheet is open, session grading / flip / undo / `C` / cram swipe are all suppressed. |
| **Device-local state** | Last tab, and which sections are collapsed. |
| **Synced state** | Everything else: tabs, sections, entries, order. |
| **Search** | Across **all** tabs, grouped by tab → section. **Viewing mode only**; entering Editing clears the filter. |
| **Copy** | Clicking a command in Viewing mode copies it, with a toast. No click-to-copy in Editing mode (the click places a caret). |
| **Collapse** | Sections collapse individually, plus a "Collapse all" / "Expand all" in the header. |
| **Outline** | A jump-to-section rail on wide windows only. |
| **Export** | Clipboard only. Menu: "Copy this tab" / "Copy everything". Header form. Empty sections and empty tabs are skipped. |
| **Empty state** | Ships with nothing. First open shows a prompt pointing at the Edit toggle. |

---

## 3. Entry points

There is no single floating button. The sheet is reached from whatever chrome the surface already has, plus the chord — which is what makes it feel always-available without inventing a control that fights the Track FAB for the bottom-right corner.

| Surface | Entry point |
|---------|-------------|
| Dashboard / Review Deck (`leetcode_page.dart`) | `GlassButton` on the header row, right-aligned opposite the `Dashboard \| Review Deck` segmented control. Never near the Track FAB. |
| Session page (`leetcode_session_page.dart`) | Icon button in the existing top row, immediately right of the ✕. The row's spacer balance is re-tuned so the counter stays centred. |
| Cram page (`leetcode_cram_page.dart`) | Same treatment as the session page. |
| Fullscreen scratch editor (`_ExpandedCard`) | `GlassButton(dense: true, height: 32)` in the toolbar row, after **Compare**. Same shape as its neighbours. |
| Collapsed scratch pad | **None.** It deliberately has no toolbar; the session page's top-row button and the chord already cover it. |
| Track modal (`leetcode_track_modal.dart`) | Icon button beside the overlaid close ✕. |
| Detail view, flashcard, search popover | None of their own — they inherit the page chrome they sit in. |
| Everywhere else in Voyager | Nothing, and the chord does nothing. |

### 3.1 The chord

`Ctrl+Shift+C`. Free today: `study_keyboard_shortcuts.dart:112` explicitly bails out of its bare-`C` scratch shortcut whenever Control is held, and nothing else in the app binds it.

The handler is mounted by a scope widget wrapping the LeetCode branch, but it **must re-check at key time** that the router's current location is under `/leetcode`. The shell keeps every branch alive and preloads several, so a handler that gates only at mount time would claim the chord while the user is on Journal. `shellTabShortcutsEnabled` in `shell_keyboard_shortcuts.dart` is the existing precedent for a gate of this shape.

The chord fires regardless of what has focus — a text field in the Track form, the scratch editor, the description field in the sheet itself.

---

## 4. The sheet

### 4.1 Frame

A `PageRouteBuilder` on the **root navigator** (`Navigator.of(context, rootNavigator: true)`), matching `openLeetCodeScratchOverlay`. Root navigator is not a stylistic choice: the scratch editor already pushes there, and the sheet has to render **above** it.

Inset from the screen edges so the scrim is a visible, clickable margin — the same idiom as `_kExpandedInset`, but the sheet is larger, because it is being read rather than glanced at.

**Scrim interaction with the scratch editor.** When the sheet opens over the fullscreen scratch editor, two scrims are stacked and both want a tap. The cheat sheet's route is above, so its scrim consumes the tap and the scratch editor never sees it. A tap that dismisses the cheat sheet must **not** also collapse the scratch editor underneath. This is the single most likely regression in the feature and gets a widget test of its own (§10).

`PopScope(canPop: false)` with an explicit close, for the same reason `_ScratchOverlay` does it: a zero-duration route would otherwise vanish rather than close, and the back gesture has to stop here rather than reaching the editor below.

### 4.2 Layout

```
┌──────────┬────────────────────────────────────────────────────────────┐
│ [Java][Python][Patterns][+]   🔍 search   [Collapse all] [Edit]  [✕]  │
├──────────┼────────────────────────────────────────────────────────────┤
│ ArrayList│  ArrayList                                            ▾    │
│ HashMap  │                                                            │
│ Deque    │  new ArrayList<>()                                         │
│ Streams  │  Constructor. Creates an empty list.                       │
│          │                                                            │
│          │  new ArrayList<>(other)                              O(n)  │
│          │  Shallow copy of other.                                    │
│          │                                                            │
│          │  .add(e)                                  O(1) amortized   │
│  outline │  Appends to the back.                                      │
│   rail   │                                                            │
│          │  HashMap                                              ▸    │
└──────────┴────────────────────────────────────────────────────────────┘
```

- **Tab strip** across the top. `SelectorPill`, as the scratch editor's language strip already uses. `+` appears in Editing mode only.
- **Outline rail** on the left, listing the current tab's sections, on windows at or above a wide breakpoint. Below it, the rail is dropped entirely — it is a convenience, not a navigation requirement.
- **Content column** scrolls (`VoyagerScrollView`).

### 4.3 Viewing mode

The whole point of the mode. No field borders, no cursors, no drag handles, no delete affordances.

- **Command**: monospace, syntax-highlighted against the tab's `languageKey` through the existing `leetcode_type_highlight` / `highlight` path. A tab with no language renders plain mono. Hovering shows a subtle copy affordance; clicking copies the command verbatim and toasts ``Copied `.add(e)` ``.
- **Complexity**: a small right-aligned badge on the command's row. Absent when unset — no placeholder, no em dash.
- **Description**: proportional prose, `leetcode_inline_code.dart` handling backticks, fenced blocks rendered as highlighted snippets. Spell-check squiggles are **off** here; this is rendered text, not a field.
- **Section header**: a real heading with a collapse chevron.
- An empty tab shows a one-line prompt pointing at the Edit toggle.

### 4.4 Editing mode

The same layout, gaining chrome rather than changing shape — so toggling modes does not re-flow the document out from under you.

- Drag handles on sections and entries; `+ Add entry` per section; `+ Add section`; `+` on the tab strip; delete on each.
- **Command field**: a code field — highlighting on, spell-check off, snippets off. Squiggling every identifier would make the field unusable.
- **Description field**: a normal `VoyagerTextField` prose field — spell-check, snippets and Vim all on, exactly as every other prose field in the app.
- **Complexity field**: a short plain text field.
- **Saving**: debounced per record (`core/sync/debouncer.dart`), flushed on blur, on mode toggle, on tab switch, and on close. Same contract the scratch pad keeps.
- **Click-outside is ignored.** Per §2 and the reasoning in `VOYAGER_SHEET_DISMISS_HLD.md`: a stray click mid-sentence must not take the sheet away. Nothing is *lost* — the debounce has already written — but your place is.

### 4.5 Search

A filter box in the header, Viewing mode only.

- Matches against `command`, `description` and `complexity`, across **every tab**.
- Results render grouped by tab → section, so a hit in Python is visibly a hit in Python. The existing `search_highlight_text.dart` marks the matched run.
- The tab strip shows a per-tab match count while a filter is active.
- Clicking a result switches to its tab, clears the filter and scrolls it into view.
- Double-clicking a result enters Editing mode on that entry (§2), which also clears the filter — the view holds that entry's scroll position across the transition so the row does not jump.

---

## 5. Data

### 5.1 Tables

Drift, schema **121 → 122**. Every table carries the standard synced-record tail: `createdAt`, `updatedAt`, `version`, `deletedAt`.

```dart
/// One tab of the LeetCode cheat sheet. [languageKey] is a
/// `leetCodeCodeLanguages` key or null — null means "no highlighting",
/// which is what makes a "Patterns" or "Big-O" tab legal.
class LeetCodeCheatTabsTable extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get languageKey => text().nullable()();
  RealColumn get position => real()();
  // + createdAt / updatedAt / version / deletedAt
}

@TableIndex(name: 'idx_leetcode_cheat_sections_tab', columns: {#tabId})
class LeetCodeCheatSectionsTable extends Table {
  TextColumn get id => text()();
  TextColumn get tabId => text()();
  TextColumn get name => text()();
  RealColumn get position => real()();
  // + createdAt / updatedAt / version / deletedAt
}

@TableIndex(name: 'idx_leetcode_cheat_entries_section', columns: {#sectionId})
class LeetCodeCheatEntriesTable extends Table {
  TextColumn get id => text()();
  TextColumn get sectionId => text()();
  TextColumn get command => text()();
  TextColumn get description => text().withDefault(const Constant(''))();

  /// Null, not empty string, when unset — the badge's presence is the flag.
  TextColumn get complexity => text().nullable()();
  RealColumn get position => real()();
  // + createdAt / updatedAt / version / deletedAt
}
```

**Why fractional `position` rather than Rankings' integer `sortOrder`:** a drag should write one row, not renumber the section. `SnippetsTable` already made this call. Positions are renormalized when a gap closes below a threshold, which is a bulk write the user paid for with a drag anyway.

### 5.2 Collections

`leetcode_cheat_tabs`, `leetcode_cheat_sections`, `leetcode_cheat_entries` under `users/{uid}/`, added to `FirestoreCollections.records`.

Firestore rules need **no change** — `firestore.rules` already matches `users/{userId}/{collection}/{document}` with a wildcard.

### 5.3 Sync and conflicts

Standard per-record last-write-wins on `version` then `updatedAt`, as Snippets and Rankings use. No CRDT.

The reasoning, recorded so it is not re-litigated: char-level merging exists in this app (`core/sync/crdt_document_resolver.dart`) but is wired for journal entries and todo tasks, and it is expensive machinery. Splitting the sheet into one record per entry means two devices editing *different* commands — the realistic case by a wide margin — never conflict at all. Two devices editing the *same* command concurrently loses one side's text, which is accepted: this is a single-user reference doc, edited on one device at a time.

**Concurrent reorder** on two devices interleaves positions rather than corrupting anything: every row is independently LWW, the result is a valid ordering, just not necessarily either device's intended one. The next local drag fixes it. Not worth more than this paragraph.

### 5.4 Deletes

`showSoftDeleteUndoToast`, with the cascade recorded in the undo payload:

- **Entry** → tombstone the entry.
- **Section** → tombstone the section and every live entry under it, as one undo unit.
- **Tab** → tombstone the tab, its sections, and their entries, as one undo unit.

Restore goes through `resolveRestoreVersion` and must honour `RestoreSuperseded` (`core/soft_delete/restore_contract.dart`): a pull landing inside the undo window can legitimately bring a row back, and writing the pre-delete snapshot over a newer remote edit is data loss, not undo.

**Orphans.** A section whose tab is tombstoned, or an entry whose section is tombstoned, is filtered out by the read query rather than chased down — the same posture the rest of the app takes. Reads always join through live parents.

### 5.5 Device-local state

Two new `SettingsTable` columns, **deliberately excluded from `settingsSyncPayload`** (`core/sync/firestore_document_mapper.dart:3300`), which is this codebase's existing and only mechanism for a device-local preference:

| Column | Meaning |
|--------|---------|
| `leetCodeCheatLastTabId` (text, nullable) | The tab this device was last on. |
| `leetCodeCheatCollapsedSectionsJson` (text, default `'[]'`) | Section ids collapsed on this device. |

Writing either must **not** bump `AppSettings.updatedAt` — that clock is reserved for synced fields, and letting a tab switch move it would let merely opening the sheet overwrite a preference another device changed more recently.

**Stale ids are expected, not exceptional.** `leetCodeCheatLastTabId` may name a tab deleted on another device or not yet pulled to this one; fall back to the first tab by `position`. Collapsed ids for dead sections are inert and are pruned opportunistically on write.

---

## 6. Export

Clipboard only. A small menu on the header: **Copy this tab** / **Copy everything**.

Header form, since descriptions can be multi-line and can carry fenced code — which a table would have to flatten into `<br>` soup:

```markdown
# Java

## ArrayList

### `new ArrayList<>()`

Constructor. Creates an empty list.

### `.add(e)` — O(1) amortized

Appends to the back.

## HashMap

### `.getOrDefault(k, v)`

Returns `v` when `k` is absent, without inserting it.
```

- Tab → `#`, section → `##`, entry command → `###` in backticks.
- `complexity`, when set, follows the command after an em dash on the heading line.
- `description` is emitted verbatim. It is already markdown-ish; inline backticks and fenced blocks pass straight through.
- **Empty sections are skipped. Tabs with no surviving section are skipped.** "Copy everything" with nothing to say toasts `Nothing to export` and puts nothing on the clipboard.
- A toast confirms what was copied, naming the tab for the single-tab case.

Accepted wart: a description whose line begins with `#` will read as a heading in the pasted document. It is already markdown by contract, so this is the user's text doing what it says.

---

## 7. Interaction with the session pages

While the sheet is open:

- `StudyKeyboardShortcuts` must not act — no flip on space, no grading keys, no undo/redo arrows, no bare `C` focus-scratch.
- The cram page's swipe must not advance.

The session pages already gate on `scratchHasSessionInput` (`leetcode_scratch_host.dart`), which is exactly this kind of "input belongs to something else right now" flag. The cleanest wiring is a provider holding "the cheat sheet is open", folded into the same gate rather than bolted on beside it.

**The Track modal** (§3) stacks: the sheet opens above the Track bottom sheet. The track draft lives in `leetcode_track_draft_store.dart` and is untouched by any of this — closing the cheat sheet returns to the form exactly as it was.

---

## 8. Edge cases

| Case | Behaviour |
|------|-----------|
| First ever open | Empty; a prompt points at the Edit toggle. No seeded content. |
| Last tab was deleted elsewhere | Falls back to the first tab by `position`. |
| No tabs exist at all | Tab strip shows only `+` (in Editing); content area shows the empty prompt. |
| Two entries with the same command | Allowed. No uniqueness constraint anywhere — `.add()` legitimately appears under both ArrayList and HashSet. |
| Tab with a language key the build no longer offers | Renders plain mono, as if unset. Does not error, does not rewrite the record. |
| Very long command | Wraps in mono rather than ellipsising; copy still takes the whole string. |
| Description with an unclosed fenced block | Rendered as literal text to the end of that description. No bleed into the next entry. |
| Copy-on-click with an empty command | No-op, no toast. |
| Offline edit | Normal local write plus outbox; syncs on reconnect like everything else. |
| Sync pulls a change to the visible tab while open | The list rebuilds from the stream. A field being actively edited keeps its local text — the same rule the rest of the app applies to a focused field. |
| Window resized below the outline breakpoint while open | Rail disappears; scroll position is preserved. |
| Android compact width | Tab strip scrolls horizontally, no outline rail, sheet takes effectively the full screen minus a small margin. |
| Sheet open over the scratch editor, user clicks the scrim | Sheet closes. Scratch editor stays open. |
| Android back over the scratch editor | Closes the sheet only. |

---

## 9. What must be registered (the easy-to-forget list)

Adding three synced collections touches more than the feature folder. In order:

1. `lib/data/database/app_database.dart` — three tables, add to `@DriftDatabase(tables: [...])`, bump `schemaVersion` to 122, add the migration step. Regenerate `app_database.g.dart`.
2. `lib/core/sync/firestore_collections.dart` — three names, added to `records`.
3. `lib/core/sync/firestore_document_mapper.dart` — a `…ToFirestore` / `merge…FromRemote` pair per collection, plus the two new device-local settings columns kept **out** of `settingsSyncPayload`.
4. `lib/core/sync/remote_sync_service.dart` — push and pull dispatch cases.
5. `lib/features/settings/services/backup_collections.dart` — three `BackupCollection` entries. **The backup-registry test fails until this is done**, by design (`firestore_collections.dart` says so in as many words).
6. `lib/domain/repositories/repositories.dart` + `lib/data/repositories/drift_repositories.dart` — the repository and its providers.
7. `lib/core/soft_delete/` wiring for the cascade restores.
8. `firestore.rules` — **no change needed**, the wildcard rule already covers them.

---

## 10. Test plan

Success criteria, stated as the check that would prove each one:

- **Sync**: an entry created on device A appears on B; the same entry edited on both resolves by version without disturbing the other two collections. The `secondary_collections_sync_test.dart` pattern.
- **Backup round-trip**: export → wipe → import reproduces all three collections, ordering included. `import_export_test.dart`.
- **Device-local**: switching tabs writes `leetCodeCheatLastTabId` and does **not** move `AppSettings.updatedAt`. This is the assertion that keeps the feature from quietly breaking settings sync.
- **Stale tab id**: a `leetCodeCheatLastTabId` naming a missing tab opens on the first tab instead of erroring.
- **Scrim isolation**: with the fullscreen scratch editor open and the sheet above it, a tap on the sheet's scrim closes the sheet and leaves the editor open.
- **Back**: Android back with both open pops the sheet only.
- **Chord gating**: `Ctrl+Shift+C` opens the sheet on `/leetcode` and does nothing on `/journal` or `/study`, including after the LeetCode branch has been visited and left.
- **Session suppression**: with the sheet open over a session card, space does not flip and grade keys do not grade.
- **Mode**: the sheet opens in Viewing after having been closed from Editing.
- **Dismiss policy**: scrim tap closes from Viewing, is ignored from Editing.
- **Cascade undo**: deleting a section with three entries and pressing Undo restores the section and all three; a pull that already restored one of them surfaces as "Already restored" rather than overwriting it.
- **Export**: a tab with one empty section and one populated section produces the populated section only; "Copy everything" on an empty sheet copies nothing and says so.
- **Highlighting**: a tab with no `languageKey` renders its commands without throwing.

---

## 11. Deferred, with reasons

| Idea | Why not now |
|------|-------------|
| Starred / frequently-used strip | Search plus collapse already answers "find it fast". Revisit if the sheet grows past a few hundred entries. |
| Copy a section into another tab | Tempting for porting Java notes to Python, but it is a bulk-write flow with its own conflict story. |
| Add-to-cheat-sheet from the scratch pad's right-click menu | The `RIGHT_CLICK_SNIPPET.md` precedent makes it cheap later; it is not what makes v1 useful. |
| Markdown import | A parser with many failure modes, for a round-trip nobody has asked to make. |
| Export to file / direct PDF | Clipboard into an editor already reaches PDF. |
| Sub-sections | A second navigation model for no proven need. |
| Global OS hotkey / floater window | A second render tree and a second window lifecycle, for a sheet whose whole premise is that you are already in Voyager's LeetCode section. |
