# Global Hotkey Floaters — High-Level Design

Replace today’s in-app dialog hotkeys (full `TodoPage` / `JournalPage` embeds) with **real always-on-top OS floater windows** for quick capture, plus **in-app deep links** when Voyager’s main window is focused and visible. Add a **finance** hotkey. Keep the process **tray-resident** so floaters work when the main window is hidden.

North star: Spotlight-style capture without leaving whatever you were doing — unless Voyager is already in front, in which case stay inside the app.

This document locks product decisions from the 2026-09-16 design review.

---

## 1. Goals

- Todo hotkey → centered floating **quick-add bar** (task title + due date + list picker + “open app”).
- Journal hotkey → bottom-right floating **notepad** bound to one **Quick Journal Entry (QJE)** for the local calendar day.
- Finance hotkey → floating **full transaction entry flow** (same as today’s in-app modal).
- When the **main window is focused and visible**, hotkeys do the equivalent **inside the app** (no floater).
- Session drafts for todo title and finance form (memory only; lost on restart).
- Subtle toast on successful todo save (and analogous confirmations where noted).
- Tray icon + Quit so the process can stay alive for global hotkeys / floaters.

### Out of scope

- Editable hotkeys in Settings (values stay read-only / defaults for now).
- macOS / non-Windows global hotkeys.
- Undo for quick-todo.
- Command-palette / `/` commands on the todo bar (later).
- Sound / haptics.
- Non-activating (focus-stealing-free) floater windows — focus grab is accepted.

---

## 2. Product decisions (locked)

| Decision | Choice |
|----------|--------|
| **Platform** | Windows only (existing `HotkeyService` gate) |
| **Floater type** | Real OS windows, always-on-top, above other apps |
| **“App open” gate** | Main window **focused and visible** only → in-app path. Unfocused, minimized, or tray-hidden → floater path |
| **Residency** | **Tray + stay resident** required. Closing the main window hides to tray; does not quit. **Quit** from tray (or explicit quit) flushes, unregisters hotkeys, destroys process |
| **Same hotkey while its floater is open** | **No-op** (already open) |
| **Different hotkey while a floater is open** | **Replace**: dismiss current floater (per its dismiss rules), open the new one |
| **Esc** | **Does not** dismiss floaters (Vim must keep Esc) |
| **Click outside / deactivate** | Dismisses the active floater |
| **Hotkey customization UI** | Not in this work |
| **Todo defaults** | Same create rules as in-app composer (non-empty trimmed title). Due date + list picker on the bar |
| **Todo list default** | Last **touched** todo list: floater saves and in-app creates both count as touches. If the user last saved via floater to list C, next floater defaults to C **until** they create/select a list in the main app (e.g. add on B → next floater is B) |
| **Todo draft** | In-memory until process exit. Dismiss / click-off / Escape-not-used keeps draft; **Enter** saves task and clears draft. Survives floater dismiss, not restart |
| **Todo “Open app”** | Dismiss floater; show/focus main window; navigate to Todo; put draft into the page composer (do not auto-save) |
| **Todo success feedback** | Toast on successful Enter save |
| **Journal QJE model** | At most **one Quick Journal Entry per local calendar day** for the hotkey notepad. Opening the notepad: if today’s QJE exists → bind; else **create immediately** (empty body OK). Reopening the notepad the same day always reuses that entry unless the user deleted it |
| **Journal create timing** | **On notepad open** (not first keystroke). Accidental open may leave an empty QJE — accepted so floater and in-app share one entry identity |
| **Journal body sync** | Live, **debounced**, plus **flush on blur/dismiss**. Notepad is a plain text mirror of the QJE body. Deletes in the notepad delete in the entry. Clearing all text leaves a **blank** entry (does not auto-delete) |
| **Journal formatting** | Plain text only — no forced bullets or timestamps |
| **Journal delete control** | Notepad has a **Delete** control that deletes the linked QJE; next open that day creates a fresh QJE |
| **Journal preview** | Notepad shows a **one-line preview** of the linked entry (title or body snippet) |
| **Journal default journal/list** | Last opened/edited journal — same “last touched” spirit as todo lists |
| **In-app journal hotkey** | Navigate to Journal and open **today’s QJE** (create if missing). Same entry the notepad would bind — not a separate always-new entry |
| **Finance floater** | Full existing transaction modal UI/behavior (type, amount, store, note, tags, date) |
| **Finance draft** | In-memory like todo; kept on click-off dismiss; lost on restart |
| **Finance suggestions** | Last-used store / tags — same as current in-app flow |
| **Default combos** | Todo `Ctrl+Alt+T`, Journal `Ctrl+Alt+J`, Finance `Ctrl+Alt+F` |
| **Offline / sync** | Todo draft is local UI state only (no remote task until Enter). Journal QJE create + keystrokes use normal local DB + existing sync-when-online behavior |
| **Vim** | Supported in floater text fields; Esc is for Vim, not dismiss |

### Interpretation note (journal)

Earlier feedback mixed “create on first keystroke / no entry if never typed,” “one entry per day,” and “always create on open.” **Locked merge:** create-or-bind **on open**, **one QJE per local day**, reuse until deleted; in-app hotkey opens that same QJE. First-keystroke gating is dropped.

---

## 3. Problem (current state)

| Area | Today |
|------|--------|
| Hotkeys | `WindowsHotkeyService` + `Ctrl+Alt+J/T`; opens `QuickJournalPopup` / `QuickTodoPopup` via `showVoyagerDialog` embedding full pages |
| Window | Close destroys the process; no tray residency |
| Focus routing | None — always tries an in-app dialog on the root navigator |
| Finance | No hotkey; `showFinanceTransactionModal` is an in-app sheet only |
| Journal “today” | No QJE concept; each create is a new entry |
| Floaters | No always-on-top secondary OS windows |

---

## 4. Architecture

### 4.1 Process & tray

```
[Tray icon]
  ├─ Open Voyager  → show + focus main window
  └─ Quit          → flush pending edits/sync hooks → unregister hotkeys → destroy

Main window close (X) → hide to tray (keep process + hotkey registration)
```

- Hotkey registration stays alive while the process is resident.
- Floaters are allowed while the main window is hidden.
- “Quit” is the only full teardown path from the tray (plus any existing explicit quit entry points, updated to match).

### 4.2 Focus router

On every hotkey fire:

1. If a floater of **that same kind** is already open → **no-op**.
2. Else if **another** floater is open → **dismiss it** (flush journal / keep drafts as applicable), then continue.
3. If main window is **visible and focused** → **in-app path** for that hotkey.
4. Else → **floater path** (create/show the corresponding always-on-top window).

Detection reuses / extends existing window visibility + focus signals (`window_manager` / lifecycle). Minimized or tray-hidden main window is **not** “open.”

### 4.3 Floater windows

- Separate OS windows (Flutter desktop multi-window or equivalent), `alwaysOnTop`, sized/positioned per feature.
- Activate and focus the floater when shown (focus steal is accepted; avoids non-activating Win32 complexity).
- Deactivate / click outside the floater window → dismiss.
- No Esc-to-close.
- Optional small close affordance is allowed for discoverability but not required if click-outside is reliable.

### 4.4 Session state (process memory)

| Key | Lifetime |
|-----|----------|
| Todo draft title (+ any unsaved due/list UI state if chosen) | Until Enter save clears it, or process exit |
| Finance transaction draft | Until successful save clears it, or process exit |
| Last-touched todo list id | Persist as today if already persisted; floater saves update it |
| Last-touched journal id | Same |
| Today’s QJE id | Prefer durable link (see §6.3) so restart same day still rebinds; entry itself is in DB |

Drafts are **not** synced and must not create remote todos/transactions until explicit save.

---

## 5. Todo floater

### 5.1 UI

Horizontal Spotlight-like bar, centered (or upper-center), always on top:

- Title field (primary, autofocus)
- Due date control (same semantics as in-app)
- List picker (default = last-touched list)
- **Open app** button → §2
- Enter → create task (in-app rules) → toast → clear draft → dismiss bar (or clear field and keep bar — **prefer dismiss after successful save** for capture speed; if product prefers keep-open for rapid multi-add, that can be a follow-up; default here: **dismiss on successful save**)

### 5.2 Dismiss

Click-outside / deactivate: close without creating a task; **keep** draft text and picker selections in session memory.

### 5.3 In-app path (main focused)

- Navigate to Todo page.
- Focus the composer.
- Prefill composer with the session draft (if any).
- Do not auto-create a task.

### 5.4 Open app from floater

Same as in-app path after dismissing the floater and showing/focusing the main window.

---

## 6. Journal notepad floater

### 6.1 UI

Small notepad, **bottom-right**, always on top:

- One-line **preview** of the linked QJE
- Multiline plain text area (Vim-capable)
- **Delete** control for the linked QJE
- No Esc dismiss

### 6.2 Lifecycle

```
Open notepad
  → resolve today’s QJE for hotkey (local calendar day)
  → if missing: create empty QJE in last-touched journal
  → bind notepad ↔ QJE.body
  → show one-line preview

Type / edit
  → debounce write to QJE.body → normal sync pipeline

Dismiss (click outside)
  → flush pending debounce → close window
  → QJE remains (even if body empty)

Delete on notepad
  → delete QJE (same soft-delete / sync rules as in-app)
  → clear binding; close or clear notepad (prefer close)
  → next open that day creates a new QJE
```

### 6.3 Identity: one QJE per day

- Mark or record the QJE so the hotkey system can find “today’s quick entry” (e.g. stable metadata flag, or a small local/settings pointer `quickJournalEntryIdByDate`).
- Multiple normal journal entries per day remain allowed; **only one** is the hotkey QJE.
- Manual delete of that entry (from notepad **or** from the main app) clears the binding; next notepad/in-app hotkey creates a new QJE for that day.

### 6.4 Concurrent edit risk (and mitigation)

**Why editing can be “dangerous”:** the notepad is a live mirror of `QJE.body`. If the main app also edits that same entry while the floater is open, two debounced writers can race and last-write-wins may drop keystrokes.

**Mitigations (accepted approach):**

1. QJE is a normal `JournalEntry`; floater and app share one row.
2. While the notepad floater is bound and open, treat the **floater as the active editor** for that entry: on floater open, reload body from DB; debounced writes + dismiss flush from the floater.
3. If the user focuses the main app and edits the same entry anyway, existing flush-on-blur plus floater debounce → **last write wins** (document as known limitation; no merge UI in v1).
4. In-app journal hotkey opens the QJE in the main editor only when **not** using the floater path (main already focused) — so the common case does not dual-edit.

This is simpler than append-only sections or CRDT merge and matches “plain paste into body.”

### 6.5 In-app path (main focused)

- Navigate to Journal (last-touched journal context as needed).
- Open today’s QJE (create if missing).
- Focus the entry body for editing.
- If a notepad floater somehow existed, replace/dismiss rules still apply before in-app handling when switching modes via another hotkey; same journal hotkey while notepad open is **no-op** (already open).

---

## 7. Finance floater

### 7.1 UI

Always-on-top window hosting the **full** existing transaction entry flow (`showFinanceTransactionModal` field set and validation): expense/deposit, amount, store/source, note, tags, date; last-used store/tag suggestions unchanged in spirit.

### 7.2 Draft & dismiss

- Click-outside: dismiss, **keep** in-memory draft for next open.
- Successful save: clear draft, toast (subtle confirm), dismiss.
- Restart: draft gone.

### 7.3 In-app path (main focused)

- Navigate to Finance.
- Open the new-transaction flow with the session draft if any.

---

## 8. Hotkeys

| Action | Default | Floater | In-app (main focused) |
|--------|---------|---------|------------------------|
| Todo | `Ctrl+Alt+T` | Quick-add bar | Todo page + focus composer (+ draft) |
| Journal | `Ctrl+Alt+J` | Bottom-right notepad | Journal page + today’s QJE |
| Finance | `Ctrl+Alt+F` | Full transaction floater | Finance page + transaction flow |

Settings continue to **display** combos as read-only on Windows; no editor in this work. Persist `financeHotkey` alongside existing journal/todo settings fields.

---

## 9. Feedback & UX details

- **Toast** on successful quick-todo save; subtle confirm on successful finance save from floater; journal relies on live sync (optional subtle “Saved” is nice-to-have, not required if debounce is invisible).
- **No undo** stack for quick-todo.
- **Vim** in floater fields; Esc never closes the window.
- Day boundary for QJE: **local calendar date** of “now” when opening/creating.

---

## 10. Component sketch (implementation guide)

Not binding to file names, but expected seams:

| Concern | Likely home |
|---------|-------------|
| Hotkey register + finance default | `hotkey_service.dart`, `hotkey_defaults.dart`, settings model |
| Focus router | Bootstrap / hotkey owner (replace `_openQuickPopup` dialog path) |
| Tray + close-to-tray | `desktop_window.dart` / `voyager_app.dart` close handling |
| Floater windows | New `lib/features/hotkeys/floaters/` (todo bar, journal notepad, finance host) |
| Session drafts | In-memory provider/service scoped to process |
| QJE resolve/create | Journal repository helpers + date key / metadata |
| Reuse | Todo create path, finance modal content, journal upsert/sync, toast helper |

Remove or retire `QuickTodoPopup` / `QuickJournalPopup` full-page embeds once floaters ship.

---

## 11. Risks & constraints

| Risk | Handling |
|------|----------|
| Flutter secondary windows + shared Riverpod/DB | Design floaters to call into the same isolates/services carefully; prefer one DB owner in the main isolate with messages if required |
| Accidental journal opens create empty QJEs | Accepted; Delete on notepad + normal journal delete clean up |
| Focus steal in games/fullscreen | Accepted for v1 |
| Click-outside detection on always-on-top | Use window blur/deactivate; verify against multi-monitor |
| Tray vs current destroy-on-close | Behavior change: document in PRODUCT if needed; ensure flush still runs on Quit |

---

## 12. Acceptance checklist

- [ ] Main focused: T/J/F perform in-app navigation + focus/flows described above
- [ ] Main unfocused / tray-hidden: T/J/F open always-on-top floaters
- [ ] Same hotkey while floater open: no-op
- [ ] Other hotkey: replaces floater
- [ ] Todo: Enter saves + toast; click-off keeps draft; Open app moves draft to composer
- [ ] Todo list default follows last-touched across app and floater
- [ ] Journal: one QJE per local day; reuse; delete then recreate; live debounce + flush
- [ ] Journal notepad Delete removes QJE
- [ ] In-app J opens same QJE as notepad for that day
- [ ] Finance: full flow + draft on dismiss; suggestions parity
- [ ] Esc does not close floaters; Vim works
- [ ] Close main → tray; Quit from tray ends process; hotkeys work while tray-resident
- [ ] Drafts do not survive restart; QJE rows in DB do

---

## 13. Follow-ups (explicitly later)

- Customizable hotkeys in Settings
- Command palette on the todo bar
- Undo for quick-todo
- Non-activating floater windows
- Richer journal “Saved” chrome if debounce feedback is unclear
