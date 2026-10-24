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
