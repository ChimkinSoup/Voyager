# ADR 004: Floater Windows and the AI Companion Process

## Status
Accepted (2026-10-24). The companion is not yet designed in detail; this
records the windowing and process decision only.

## Context
Hotkey floaters (todo, journal, finance, reminder, calendar) currently borrow
the main window: `FloaterWindow` saves its placement, shrinks it to the
floater's size, makes it topmost, and restores it on dismiss, while
`FloaterHost` keeps the app mounted but offstage. Flutter on stable Windows
gives one OS window per engine, which is why it works this way.

A planned AI companion changes the requirements. It is opened by a global
hotkey over any app, including Voyager itself, stays open alongside the main
window, and carries a lot of its own behaviour: screenshots, long chats,
persistent state.

## Options weighed

**1. Keep borrowing the main window.** Works today, and the hard parts are
solved (maximized/minimized/tray round trips, DWM cloaking, z-order, focus
return). It cannot host the companion: the main window can't float over
itself, and the app is hidden for as long as the floater is up.

**2. `desktop_multi_window`.** A real second OS window, but each window is a
separate engine and Dart isolate. For the floaters that is a net cost: they
reuse Voyager's own forms, providers and drafts, so moving them means a
messaging layer between isolates just to stay where they are, plus a second
drift connection whose writes the main window's streams would not see, and
plugin registration per engine (`hotkey_manager`, `tray_manager` and
`window_manager` assume one window). For the companion it would be workable.

**3. Flutter's built-in windowing API (`RegularWindowController`).** Several
OS windows on one engine, so the floaters could keep their widgets and
providers as they are. This is the right long-term home for the floaters, but
as of Flutter 3.44.6 it is master-only behind `--enable-windowing`, `@internal`,
and has open Windows bugs. Forking the Dart side is cheap; engine fixes would
mean carrying a Windows engine build.

**4. A separate companion process.** The same exe launched in companion mode,
talking to Voyager over IPC. Fullest isolation: a companion crash or stall
can't take down or slow Voyager, no shared engine or plugin registration, and
the companion can outlive Voyager's main window. It costs more IPC
plumbing than option 2.

## Decision
- **Floaters stay on the borrowed main window.** They work, and moving them
  to a separate window doesn't help the companion. Revisit when Flutter's
  windowing API reaches stable, which suits them better than option 2.
- **The companion runs as a second process.**

## Companion process shape
- **Launch.** The same `voyager.exe` with a `--companion` argument.
  `windows/runner/main.cpp` must branch on it before the single-instance
  mutex and take its own (profile-scoped) mutex, so the companion is single
  instance itself without being handed off to the main instance.
- **Hotkey.** The main instance keeps every global hotkey registration and
  starts or signals the companion; the companion registers none.
- **Data ownership.** The main instance owns Voyager's drift DB, Firebase and
  sync. The companion never opens them. It sends a narrow set of commands
  (e.g. create a todo, read a day's journal, open something in the main app)
  over a named pipe, and the main instance runs them through the normal
  repositories, so the outbox, sync and live UI updates keep working.
- **Its own state.** Chat history and other companion state live in the
  companion's own storage (e.g. a separate SQLite file).
- **Window.** Positioning and topmost go through Win32 FFI on its HWND, as
  `FloaterWindow` already does. `SetWindowDisplayAffinity(hwnd,
  WDA_EXCLUDEFROMCAPTURE)` keeps it out of its own screenshots.
- **Screenshots.** Win32 / `Windows.Graphics.Capture` through FFI, separate
  from the window choice.

## Consequences
- Two windowing mechanisms coexist: borrowed-window floaters and a
  companion process.
- An IPC protocol between the two processes has to be designed, versioned
  with the app, and handle Voyager's main instance not running or still
  starting.
- Voyager's data reaches the companion only through that protocol, which
  limits what the companion can see to what it is explicitly given.

## Open questions
- What happens to the companion hotkey when Voyager isn't running: does the
  companion start Voyager, or work in a reduced mode?
- The command set the companion needs from Voyager.
- Whether the companion starts on demand or stays resident for instant
  opening.

## Amendment: Gaia's data lives in Voyager's DB (2026-10-24)

### Context
The companion now has a design (`GAIA_HLD.md`). Its chats must sync across
devices, continue on Android, and appear on a Gaia page inside Voyager. That
makes them Voyager data, needing the outbox, soft delete and trash. Keeping
them in a companion-owned SQLite file would need a second sync client. On
desktop that means a second process opening the Firestore C++ SDK, whose
on-disk cache is single-process.

### Decision
- Gaia's collections (chats, messages, memories, prompt queue, settings) live
  in Voyager's drift DB and sync through the normal repositories. The
  companion still never opens the DB or Firebase. It reads and writes these
  collections over the named pipe, like any other command. This replaces
  "Its own state" above.
- The companion is **resident**: it hides rather than exits, because
  background runs and beacon mode need it while its window is closed.
- Launching `voyager.exe --companion` without a running main instance starts
  the main instance first. There is no reduced mode.
- The companion spawns and owns the agent CLI processes. Region capture uses
  a frozen frame inside the companion's own window, so it needs no extra
  window.
- Gaia's tools reach the agent CLIs through `voyager.exe --gaia-mcp`. This is
  a windowless stdio MCP shim, one per agent spawn, that relays calls to the
  companion over the pipe. Nothing listens on a localhost port. Like
  `--companion`, `main.cpp` branches on it before the single-instance mutex.
  It takes no mutex and runs no Flutter engine.
- The named pipe is created with a DACL for the current user only. Each
  client is checked with `GetNamedPipeClientProcessId` against the companion
  PID (or a shim the companion spawned).
- An app update drains the companion first: active runs are waited on or
  cancelled, then both processes exit and relaunch.

### Consequences
- The IPC protocol carries chat persistence and token streaming as well as
  Voyager commands.
- A companion crash loses an in-flight run, which is recorded as
  `interrupted`. Persisted history is unaffected.
- All three open questions above are answered. Voyager not running and
  resident vs. on-demand are settled here, and the command set is specified in
  `GAIA_HLD.md` §5.3 and §10.
