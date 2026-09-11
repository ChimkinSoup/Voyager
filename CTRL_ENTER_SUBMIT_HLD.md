# Ctrl+Enter Submit + Finance Enter Chains — HLD

Universal **Ctrl/Cmd+Enter** commit shortcut for Voyager forms, plus **finance-only** Enter focus chains so transaction (and other finance) sheets can be filled without the mouse.

Related: `lib/core/widgets/enter_to_submit_scope.dart`, finance modals under `lib/features/finance/`, tag suggestion overlays.

Status: **design** (not implemented).

---

## 1. Goals

- **Ctrl+Enter** (Windows/Linux) / **Cmd+Enter** (macOS) always runs the surface’s primary affirmative action from **any** focused field, including multiline notes.
- **Do not change bare Enter** outside finance (except surfaces that already save on Enter, where Ctrl+Enter becomes an alias).
- **Finance sheets only:** Enter advances through text fields top → bottom; last single-line field Enter commits; last multiline field Enter inserts a newline.
- Tag suggestion UI continues to consume bare Enter first; Ctrl/Cmd+Enter **ignores** suggestions and commits immediately with current field text.
- Prefer one shared keyboard helper so every surface wires the same chord the same way.

## 2. Non-goals

- On-screen “Ctrl+Enter” / “⌘↩” hints near Save buttons.
- Esc-to-dismiss pass (leave existing dismiss behavior alone).
- Rapid-fire finance entry (keep sheet open after Add) — **rejected**; successful save still closes the sheet.
- Changing Enter behavior on non-finance surfaces (jobs track focus chain, study, calendar notes, etc. stay as today).
- Destructive confirm dialogs (`confirm_dialog`) — already bare-Enter confirm; no Ctrl+Enter required.
- Autosave body editors without an affirmative control (main journal / dream journal, rankings edit panel, jobs edit panel).
- Todo edit panel Ctrl+Enter flush+close — **out of scope** for this pass (only rankings Done surfaces).

---

## 3. Shortcut policy

| Chord | Behavior |
|-------|----------|
| **Enter** | Unchanged except **finance sheets** (§5). Elsewhere: keep today’s advance / newline / submit / ignore. |
| **Ctrl+Enter** / **Cmd+Enter** | Always primary affirmative action for that surface (Save / Add / Import / Done / Create / OK as applicable). Fires even while an `EditableText` has focus. |
| **Tag suggestions open** | Bare Enter accepts / navigates suggestion UI first. Ctrl/Cmd+Enter does **not** accept a suggestion; it commits the popup with whatever text is currently in the fields. |

Platform modifier: use the primary shortcut modifier (`control` on Windows/Linux, `meta` on macOS). Match existing `KeyBinding` / platform conventions.

Validation: if Save would be disabled (empty required field, parse error), Ctrl/Cmd+Enter is a no-op or surfaces the same error path as clicking Save — never force-save invalid state.

---

## 4. Shared helper

Extend or parallel `EnterToSubmitScope` with a focused-field-aware chord:

**Proposed:** `lib/core/widgets/ctrl_enter_to_submit_scope.dart` (name flexible)

```text
CtrlEnterToSubmitScope(
  onSubmit: …,  // same callback as Save / Done / Import
  child: …,
)
```

Responsibilities:

- Listen for Ctrl/Cmd+Enter (keydown).
- Invoke `onSubmit` even when an `EditableText` is focused.
- Do **not** handle bare Enter (finance chains and existing `onSubmitted` / `EnterToSubmitScope` stay separate).
- Nest under / beside existing `EnterToSubmitScope` where both exist; no conflict (different chords).

Optional later: merge into one `SubmitKeyboardScope(onEnterWhenUnfocused:, onCtrlEnter:)` — not required for v1 if a thin second widget is clearer.

Surfaces that already use field-level `onSubmitted` for Enter keep that wiring; they only wrap (or additionally register) Ctrl/Cmd+Enter via the shared scope.

---

## 5. Finance Enter focus chains (finance-only Enter change)

Applies to **all** finance create/edit sheets listed below. Non-text controls (segmented type toggles, date pills, billing dropdown, color chips, suggestion chips) are **skipped** — chain is text fields only, in visual top-to-bottom order.

### 5.1 Rules

1. Enter on a **non-last** text field → move focus to the next text field in the chain.
2. Enter on the **last** text field:
   - If **multiline** → insert newline (no save).
   - If **single-line** → same as Save / Add (and close sheet on success).
3. Ctrl/Cmd+Enter anywhere → Save / Add (and close sheet on success), subject to validation.
4. Successful save **closes** the sheet (Add and edit). No stay-open rapid-fire mode.
5. If tag suggestions are open on a tags/tag field, bare Enter is handled by suggestion UI first (§3).

### 5.2 Per-sheet chains

| Sheet | Text-field chain | Last field Enter |
|-------|------------------|------------------|
| **Transaction** | Amount → Tags → Note | Note is multiline (`maxLines: 2`) → **newline**; save only via button / Ctrl+Enter |
| **Allocate** | Amount → Note | Note single-line → **save** |
| **Budget** | Tag → Monthly limit *(Tag disabled when editing existing → chain is Limit only)* | Limit → **save** |
| **Asset** | Asset name → Current value → Note | Note single-line → **save** |
| **Goal** | Goal → Target amount → Note | Note single-line → **save** |
| **Subscription** | Name → Amount → Note *(Billing dropdown skipped)* | Note single-line → **save** |
| **Category** | Category name | Name → **save** |

**Transaction delta vs today:** Amount `onSubmitted` currently calls `_save()`. Change it to focus Tags. Tags get `onSubmitted` → focus Note. Note keeps newline on Enter.

Other sheets: replace any existing “Enter on amount/limit → save” with advance-or-final-save per the table (e.g. Allocate Amount and Budget Limit currently submit early).

---

## 6. Ctrl/Cmd+Enter inventory

Primary action is whatever the main affirmative button already does. Enter behavior column notes only intentional Enter changes or existing Enter-save kept as-is.

### 6.1 Finance

| Surface | Action | Enter | Ctrl/Cmd+Enter |
|---------|--------|-------|----------------|
| `finance_transaction_modal.dart` | Add / Save | Chain §5.2 | Save |
| `finance_allocate_modal.dart` | Add funds / Withdraw | Chain §5.2 | Save |
| `finance_budget_modal.dart` | Add / Save | Chain §5.2 | Save |
| `finance_asset_modal.dart` | Add / Save | Chain §5.2 | Save |
| `finance_goal_modal.dart` | Add / Save | Chain §5.2 | Save |
| `finance_subscription_modal.dart` | Add / Save | Chain §5.2 | Save |
| `finance_category_modal.dart` | Add / Save | Chain §5.2 | Save |

### 6.2 Multiline / track forms (Enter unchanged)

| Surface | Action | Notes |
|---------|--------|-------|
| `jobs_track_modal.dart` | Save | Existing company→title→URL Enter chain kept; Notes stay newline |
| `leetcode_track_modal.dart` | Save / Save changes | Many multiline fields; Enter stays newline/code |
| `study_card_editor_modal.dart` | Save | Front/Back multiline |
| `study_import_text_modal.dart` | Import N cards | Bulk paste multiline |
| `calendar_event_panel.dart` | Save | Notes multiline; existing title Enter + `EnterToSubmitScope` kept |
| `calendar_todo_panel.dart` | Save | Same as event panel |
| `search_page.dart` journal entry dialog | Save | Body multiline; Ctrl+Enter → **Save** (not Close) |
| `journal_page.dart` quote dialog | Save | Quote multiline |
| `bucket_list_popup.dart` completion note | Save | Reflection multiline |
| `job_experience_snippets_dialog.dart` inner editor | Save | Description multiline |

### 6.3 Enter already saves — add Ctrl/Cmd+Enter alias

| Surface | Action |
|---------|--------|
| `study_name_modal.dart` | Save |
| `workout_name_modal.dart` | Save |
| `workout_target_editor.dart` | Save |
| `prompt_name_dialog.dart` | OK |
| `create_name_color_dialog.dart` | Create / configured submit |
| Analytics tracker create/edit dialog | Create / Save |
| `rankings_category_dialog.dart` | Create / Save *(also: name-focused Enter should submit — today only unfocused `EnterToSubmitScope` works; fix Enter-on-name as part of alias work)* |
| Settings dictionary / custom quotes / snippets row editors | Save active row |
| `flag_word_popover.dart` | Flag *(optional consistency; same pattern as row save)* |

### 6.4 Done / close (flush + dismiss)

| Surface | Action |
|---------|--------|
| Rankings child editor dialog | **Done** (flush debounced edits + close) |
| `rankings_manage_sheet.dart` | **Done** (flush + close sheet) |

### 6.5 Other Save surfaces

| Surface | Action |
|---------|--------|
| Analytics day-value popover | Save |
| Notification inbox daily trackers | Save dirty tracker rows (“Save all” / equivalent) |
| `calendar_overlay_dialog.dart` | Save |

### 6.6 Explicitly out of scope

- Todo edit panel
- Jobs / rankings / journal autosave panels without Save
- Confirm / delete dialogs
- Login
- Study move / link deck pickers
- Manage sheets that only Close / open nested creates
- Code editors (LeetCode code field, scratch pad) as standalone submit targets — covered only via parent track modal Ctrl+Enter → Save
- Shell / study session grading shortcuts

---

## 7. Tag suggestions interaction

Wherever tag suggestion overlay is active:

1. **Enter** → existing suggestion accept / highlight behavior (unchanged).
2. **Ctrl/Cmd+Enter** → bypass overlay; commit parent form with current controllers’ text (including partial tag strings as today’s save parser already handles).

Implement so suggestion key handlers do not mark Ctrl/Cmd+Enter as handled unless they intentionally no-op and let the submit scope see it — prefer submit scope winning on the chord.

---

## 8. Implementation sketch

1. Add `CtrlEnterToSubmitScope` (platform primary modifier + Enter).
2. Finance: add focus nodes + `onSubmitted` chains per §5.2; wrap each sheet with Ctrl+Enter → `_save`.
3. Wrap / register remaining inventory surfaces (§6) with the same scope → existing save/done callbacks.
4. Rankings category: ensure name field Enter submits (parity with other name dialogs) **and** Ctrl+Enter.
5. Search journal dialog: Ctrl+Enter → save path specifically (do not wire to Close).
6. Inbox: Ctrl+Enter → save dirty daily tracker rows when that block is relevant.
7. Verify tag suggestion + Ctrl+Enter on finance transaction Tags (and any other tagged Save forms in scope).
8. Tests: finance Amount Enter focuses Tags (does not save); Tags Enter focuses Note; Note Enter does not save; Ctrl+Enter saves from Amount and from Note; one smoke test that shared scope fires while `EditableText` focused.

---

## 9. Acceptance criteria

- From finance **new transaction**: autofocus Amount → Enter → Tags → Enter → Note → Enter inserts newline → Ctrl+Enter saves and closes.
- Ctrl+Enter from Amount on an empty invalid form does not close / does not persist garbage (same as disabled Save).
- Jobs track Notes: Enter still newline; Ctrl+Enter saves.
- Study card editor: Ctrl+Enter saves; Enter still newline on Front/Back.
- Name dialogs that already Enter-save also Ctrl+Enter-save.
- Rankings child Done and manage sheet Done: Ctrl+Enter closes (after flush).
- Inbox: Ctrl+Enter saves dirty daily trackers.
- macOS uses Cmd+Enter; Windows uses Ctrl+Enter.
- No new Save hint chrome in the UI.

---

## 10. Open follow-ups (not this HLD)

- Todo edit panel Ctrl+Enter → flush + close
- Esc consistency pass
- Rapid-fire finance Add (stay open) if ever revisited
- Merging `EnterToSubmitScope` + CtrlEnter into one widget

