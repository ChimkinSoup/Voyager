# Global Hotkey Floaters — Test Methodology & Coverage

Companion to [AUDIT.md](AUDIT.md). Records how the branch was exercised, what has already been covered (no need to repeat), and what is still open.

## Setup

- `flutter analyze lib test` — no issues in files touched by the branch.
- `flutter test test/quick_journal_entry_test.dart` — 4/4 pass.
- `flutter build windows --debug` — builds.
- App run with `flutter run -d windows --debug`, stdout captured to a log so `FlutterError`s are visible.
- Test data: every row created against the real account was labelled `claude floater test…` and soft-deleted in the app afterwards; `pending_uploads_table` (sync outbox) checked empty.

## Probe tooling (session scratchpad, not in the repo)

- `Probe.cs` / `probe.ps1` — Win32 helpers. Finds Voyager's `FLUTTER_RUNNER_WIN32_WINDOW`; reports visible/iconic/foreground/topmost/rect. Guards: real keystrokes/clicks only when a foreground window exists and Voyager (or the probe's own form) is it; `Ctrl+Alt+<key>` only sent when the hotkey is already registered (checked via `RegisterHotKey` failing), so it can't reach another app; captures only Voyager's own window.
- Posted input — `WM_HOTKEY` (wParam = hotkey_manager id: journal 1, todo 2, finance 3), `WM_KEYDOWN/UP`, mouse messages to the `FLUTTERVIEW` child, tray callback `WM_USER+1` with `WM_LBUTTONUP`/`WM_RBUTTONUP`, then `VK_UP`+`VK_RETURN` to pick "Quit" in the real tray menu.
- `vm.py` — Dart VM service client: `eval` expressions in app libraries, and `shot` (renders `renderViews.first.debugLayer` to PNG — works even when the session is locked).
- `mark.sh` — prints `=== MARK <label> primary=<focus>` into the flutter log and resets `FlutterError` counting so the next error prints in full.
- A persistent frame callback installed via eval logs `=== FH active=… media=… mainSize=…` whenever `FloaterHost` state changes (finding 1).
- `inapp.sh` — calls `FloaterController._openInApp(kind)` inside `Future(...)`, i.e. the in-app hotkey path without the foreground gate.
- Data checks: read-only SQLite (`~/Documents/voyager.sqlite`, `mode=ro`).

## Session 1 — 2026-09-17, Windows session locked

The PC was locked (no foreground window), so real input, focus changes and OS captures were unavailable; everything was driven by posted messages and VM-service frame grabs.

### Covered — passed

| Flow | Result |
|------|--------|
| Close (X / `WM_CLOSE`) → hide to tray | Window hidden, process alive, all three hotkeys still registered |
| Tray left-click → Open Voyager | Main window shown at its previous (maximized) placement |
| Tray right-click → real context menu → Quit (twice, two launches) | Items "Open Voyager / — / Quit"; process exits <1s; all hotkeys released; no errors at shutdown; outbox empty |
| Finance hotkey with main unfocused → floater | 460×640 topmost floater centered; amount autofocused on first open |
| Finance floater close (X) keeps draft | Reopen restored amount/store/note |
| Finance floater save | "Transaction added" confirmation, dismissed, exactly one DB row, draft cleared, ledger shows it under Today |
| Todo hotkey from tray-hidden → quick-add bar | Upper-center bar, list pill shows last-touched list |
| Different hotkey replaces floater (todo → journal → todo) | Replaced; todo title draft survived; journal notepad flushed |
| Journal notepad | Creates today's QJE on open (pointer file written), debounced body save reaches DB, reopen reuses same entry, Delete soft-deletes it |
| Todo Enter save | "Added to Todo", task in last-touched list, `lastViewedTodoListId` unchanged/consistent |
| Todo "Open app" | Main shown, navigated to To-Do, composer holds the draft title |
| In-app todo path (via `inapp.sh`) | To-Do page, a text field focused |
| In-app journal path, QJE already exists | Opens that entry within 2s |
| Journal page ignores `richBodyJson` for editing | Notepad writing `body` only is safe |

### Covered — failed (see AUDIT.md)

- Dismiss reflow / focus corruption → finding 1 (FH log + errors, reproduced every dismiss).
- In-app journal, first press when QJE is created → finding 2 (reproduced twice).
- `WM_CLOSE` with floater open (locked, so no blur) → finding 3.
- Replacement null check → finding 4.
- In-app finance twice → two sheets mounted → finding 5.

### Probe artifacts (not app bugs)

- `'picture != null'` assertion — a VM frame grab landing mid-paint.
- `Tried to modify a provider while the widget tree was building` — VM `evaluate` interrupting a build; fixed by wrapping in `Future(...)`.

### Not covered in session 1 (most now covered in session 2 — see "Still not covered" at the end)

- Click-outside / blur dismiss, and focus returning to the previous app.
- Real foreground gate (`FloaterWindow.mainWindowOpen`) choosing in-app vs floater from real `Ctrl+Alt+T/J/F`.
- Floater taking foreground from another app (focus steal after `WM_HOTKEY`).
- Esc not closing floaters; Vim in floater fields.
- `WM_CLOSE` on a focused floater with blur active (finding 3 in a real session).
- Tray menu click-away (finding 7); real tray icon click.
- Floater over a minimized main window — placement restored on dismiss.
- Multi-monitor / per-monitor DPI placement — only one display (1440×900 logical @200%) is attached.
- Second instance (finding 6) and mid-save blur race (finding 8) — not attempted (risk to data / timing).

## Session 2 — 2026-09-17, Windows session unlocked

Real keyboard/mouse (`keybd_event`/`SendInput`/`mouse_event`) with the guards above; the PC was left untouched while scripts ran. Each scenario ran as a single PowerShell script so no tool call could steal focus mid-scenario.

"Another app" is a small WinForms window created by the probe (`FocusOtherPlain`: raised by a real click, then dropped out of the topmost band so it behaves like an ordinary app). Its first version stayed topmost, which is what exposed finding 10.

Vim mode was already enabled in settings. One display only (1440×900 logical @200%).

### Covered — passed

| Flow | Result |
|------|--------|
| Real `Ctrl+Alt+T` with another app focused → floater takes foreground | Floater foreground + topmost; title field focused |
| Same hotkey while its floater is open | No-op (size/position/text unchanged) |
| Esc in todo bar, finance form, journal notepad | Never closes the floater; in fields it enters Vim NORMAL mode |
| Vim in the todo bar (real VK keys) | `Esc`, `0`, `x` deleted the first char; `A`, `z` appended; NORMAL badge shown |
| Click outside (real click on another window) dismisses | Floater gone, other window foreground, main window back to its maximized placement and *not* topmost (ordinary window case) |
| Draft kept across click-outside dismiss | Todo title restored on reopen, field focused |
| Different real hotkey replaces floater (todo → finance) | Replaced, amount focused |
| In-app path gate: real `Ctrl+Alt+T/F/J` with main focused | No floater; window stays maximized, not topmost; navigates to To-Do / Finance (+sheet) / Journal |
| In-app journal with real hotkey from Finance page | Created today's QJE and selected it |
| Journal notepad via real hotkey: Esc, click-outside dismiss, reopen, Delete | Stays open on Esc; dismiss flushes (`active=null`); Delete soft-deletes the QJE |
| Floater over a minimized main window | Floater shown; after dismiss main is minimized again; `SC_RESTORE` brings it back maximized |
| "Open app" from the todo bar (another app focused, main on Finance) | Main window foreground, maximized, To-Do page, composer focused |
| Tray Quit (third launch) | Process exits, hotkeys released |

### Covered — failed (see AUDIT.md)

- Finding 1 — reflow frames at 452×635.5 / 672×63.5 on dismiss (B3, V5); `Invalid argument(s): 0.0`, RenderFlex overflow 163px, `Looking up a deactivated widget's ancestor` (G).
- Finding 3 — `WM_CLOSE` on a focused floater brought the full main window back maximized and focused.
- Finding 4 — null check in `NavigatorState._updateHeroController` on todo → finance replacement (A6).
- Finding 5 — two real `Ctrl+Alt+F` presses → 2 `_TransactionModal`s mounted.
- Finding 7 — tray menu still open after clicking another window; closed only by Esc.
- Finding 10 (new) — dismissing into a topmost window left the main window topmost (12s later still set).
- Finding 11 (new) — in-app `Ctrl+Alt+T` from Journal: draft in composer, focus on a `FocusScope`.
- Finding 12 (new) — `Ctrl+Alt+J` with two finance sheets open: Journal selected underneath, sheets still on top.

### Attempted, not reproduced

- Finding 8 — Add then click outside ~360ms later: save completed first (one row, draft cleared).

### Probe artifacts (not app bugs)

- Typing via `SendInput` Unicode packets (`KEYEVENTF_UNICODE`) bypasses Vim's key handling, so NORMAL-mode commands appear to insert text. Real virtual-key presses behave correctly.
- Esc on an in-app finance sheet with the amount field focused does not close it — Vim takes Esc in fields; not an HLD requirement.

### Test data (S2)

`claude race test` transaction, QJE `ff1f8452…` — both soft-deleted in the app; the todo composer text carried over by the in-app path was cleared without adding; outbox empty. Voyager quit via the tray at the end, as it was before testing.

## Still not covered

- Physical click on the notification-area tray icon — the Windows 11 taskbar exposes no icon elements to the managed UI Automation client, so the icon was driven through the plugin's callback message. Untested: that a real icon click grants Voyager foreground for "Open Voyager".
- Multi-monitor and mixed-DPI floater placement — one display attached.
- Focus steal from fullscreen/exclusive apps (games).
- Second instance while tray-resident (finding 6) — skipped to avoid two processes on the real database.
- A narrower mid-save blur window (finding 8) — needs an artificially slow write to hit reliably.
- Behaviour across local midnight (QJE day rollover while a notepad is open) and after sign-out/in.
