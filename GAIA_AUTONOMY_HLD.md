# Gaia — Autonomous PC Control (HLD)

Status: Phase 1 built and checked live, 2026-11-03 (§11.1). Phase 2 built, 2026-11-03 (§11.2). The
rest is proposed. It changes GAIA_HLD.md §5.2, §10.1, §12.2, §15.6, §15.7 and §20; §12 below lists how.

## 1. Summary

Today every mouse or keyboard action Gaia takes stops at a card. Marking three emails
as read took three cards, and paging through an inbox took one per page. The cards
show coordinates nobody can check, so they cost attention and protect little.

This design adds:

1. **An Auto mode on the hand toggle** (Off / Ask / Auto). In Auto, Gaia's OS actions,
   shell commands and file edits run with no cards. Ask is today's behaviour.
2. **A stop model that holds without cards:** Esc ends the whole turn, the target
   window stays fixed for the run, and switching windows yourself stops it.
3. **Brief on-screen flashes** in Gaia's colours that show each click, scroll, key and
   window change, and name what was acted on.
4. **New tools:** `os_open`, `os_windows`, `os_focus`, `os_window`, `os_drag` and
   `os_clipboard`.

**The trade, stated plainly:** GAIA_HLD.md §20 calls the step list "the real boundary"
against text on a page steering an agent. Auto removes that boundary for the chats
it's turned on in (§9).

## 2. Goals and non-goals

Goals:
- "Mark my top 3 emails as read" in Auto raises no cards, and you can see each click.
- A long, tedious task (rank 50 jobs across a 10+ page board) runs to the end unattended.
- Esc, Stop, Revoke and Abort each stop an Auto run promptly, however it's occupied.
- Gaia can open an app and reliably be working in that app afterwards.

Non-goals:
- Making Auto safe against a steered agent. It can't be, with shell access (§9).
- Changing Ask's approval flow, beyond the step preview in §6.4.
- Auto-committing Voyager data. Proposals keep their review card (§10).

## 3. What the code does today

Findings the design relies on, each read from the code:

| Finding | Where | Consequence |
|---|---|---|
| Each `os_*` call is one card. Only `os_steps` groups them. | `gaia_chat_tools.dart` `_control` | Three `os_click` calls are three cards. |
| `os_scroll` exists and needs a card, like `os_key`. | `gaia_mcp.dart` | Haiku choosing PgDn was only a tool choice. Scrolling would have prompted as often. |
| The 20 limit caps **one `os_steps` list**. There's no per-turn total, and reads aren't steps. | `gaia_os_control.dart` `_maxSteps` | The job-board task doesn't hit it (§5.6). |
| The target is whatever is in front when each call plans. | `plan`, `gaiaOsTarget` | Without a card, a click could land in a window you just switched to. |
| Esc is only polled while a step list runs. | `run`'s `escape` timer | Esc does nothing while the agent thinks between calls. |
| After a stop, the agent is only *told* not to continue. | `_control` result text | Nothing enforces it. |
| The foreground right comes from your approval click. | `approveControl`'s `AllowSetForegroundWindow` | With no click, activation can fail as in BUG-337 (§5.4). |
| Both CLIs' permission prompts go through one function. | `GaiaChatTools.permit` | One change covers Claude Code and Codex, with no restart or new flags. |
| Grants are JSON per device, on the chat. | `grants[deviceId]`, `gaia_models.dart:281` | A new mode needs no schema change. |

**Not reproduced:** a window opened from the terminal staying behind. In Phase 1's spike,
Character Map started through `cmd /c start` by a process with no foreground right came to
the front 6 times of 6, under another app or under a stand-in for Gaia. A browser and a real
CLI's shell weren't tried. Nor could I find the transcript of the email test, so what Haiku
did is taken from your description.

## 4. The hand toggle

Three modes per chat and per device:

| Mode | OS actions | CLI shell and edit prompts | Prompt from the phone |
|---|---|---|---|
| **Off** | Refused | Card | No OS actions |
| **Ask** | Card, as today | Card | Waits for the desktop, as today |
| **Auto** | Run with no card | Allowed with no card | Runs, with Stop and Abort on the phone |

Decisions:
- **Stored as** `GaiaGrant.auto`, meaningful only with `canControl`. A build that
  doesn't know the field reads the chat as Ask, the safer of the two.
- **The button** opens a small menu rather than cycling, so one stray click can't reach
  Auto. Filled hand for Ask, filled hand with an accent mark for Auto.
- **New chats never start in Auto**, even where the new-chat default remembers the hand.
- **Auto needs reading.** A blind agent can't check its own work, so choosing Auto turns
  on *can see screen*, and turning that off drops the chat to Ask.
- **Consent:** the first Auto on each device shows one notice, confirmed with Ctrl+Enter,
  saying you're responsible for what Gaia does and that page text can steer it. After
  that, it's one click.
- **Revoke and Abort** turn everything off, as now. Re-arm restores nothing.
- **The notch** says which mode is on: "Gaia · Auto · {chat}". While a turn is acting it
  adds "Esc to stop".

## 5. The Auto run

### 5.1 Control session

A session belongs to one turn, in the main instance (`GaiaOsControl`). It starts at the
turn's first `os_*` call, read or action, and ends with the turn. It holds the chat, the
pinned target window, and a latch.

**One session at a time.** Another chat's action is refused with "another chat is
controlling the screen", so two agents can't fight over one mouse. Its reads are refused
too, since they'd resolve against someone else's front window.

### 5.2 The pinned target

Replaces "a run stops if the window changes".

- The first `os_*` call pins the target, resolved as `gaiaOsTarget` does now.
- Later calls use the pin rather than whatever is in front. `os_open` and `os_focus`
  move it.
- **A window Gaia caused is adopted.** If the foreground changes within 1.5 s of a step
  Gaia sent (a dialog, a popup, a link opening an app), the new window becomes the
  target. Exclusions and the vault are checked, and the result tells the agent.
- **A window you caused stops the run.** A change outside that 1.5 s is you taking over:
  the turn stops (§5.3).
- **Gaia in front pauses.** Clicking the floater to read progress shouldn't kill a run,
  and carrying on would pull focus out of the composer. Actions wait, the notch says
  "paused", and they resume when the target is back in front. After 5 minutes the run
  stops. Another app coming in front stops it.

**Telling them apart.** Timing alone wasn't enough: with a model round trip of a few
seconds, a good share of a run is within 1.5 s of a step. So a change is adopted only if it
comes within 1.5 s of a Gaia step **and** the user pressed no key or mouse button in those
1.5 s. For the session, low-level keyboard and mouse hooks in the runner
(`gaia_user_input.cpp`) count the user's presses on a thread of their own. Injected input,
Gaia's included, doesn't count, and nor do mouse moves or the wheel, so moving the mouse while
a Gaia click opens a dialog doesn't stop the run. If the hooks can't go in, it falls back to
`GetLastInputInfo` moving since Gaia's last send. That counts any mouse move as input, the safe
way to be wrong, and its ~16 ms tick can't see input in the same tick as a Gaia send. In a
session, `os_type` therefore sends at most every 20 ms, about 10 s for the 2000-character limit
(Ask stays at 1 ms). Exclusions and the vault still apply.

**A dialog that takes longer than 1.5 s to appear stops the run.** Also the safe way to be
wrong, and the first thing to tune if it proves annoying.

**Known gap for Phase 3:** answering `ask_user` mid-run leaves you in Gaia, so the run waits
until you click the target, and stops after 5 minutes. §9 tells agents to ask before
irreversible actions, so answering should resume the run.

### 5.3 Stopping

| Control | Effect in an Auto run |
|---|---|
| **Esc** | New: polled for the whole session, not one step list. Ends the turn. |
| **Stop button** | As today: ends the turn. |
| **Switching window yourself** | New: ends the turn, as Esc does. |
| **Revoke access** | Off for every chat, and the current action stops. The agent keeps running but is refused, and its shell commands fall back to cards. A shell command already running isn't killed. |
| **Abort** | As today: kills every process tree and voids everything. |

Esc and switching windows:
1. Stop input at the next look, and release anything held.
2. Set the latch, so `os_*` calls from that turn are refused however slowly the agent
   stops.
3. Tell the companion, which runs its existing `stop(chatId)`.
4. **Pause drain mode.** Otherwise the next queued prompt carries on autonomously right
   after you pressed Esc.

The session polls Esc only once the turn has touched the OS, so a plain reply in a chat
with the hand on doesn't react to Esc pressed in other apps. The target still receives
the press, as it does today.

### 5.4 Foreground without a click

No approval click means no `AllowSetForegroundWindow` handed over. What the spike and real
turns found (2026-11-03):

| Way | Result |
|---|---|
| `SetForegroundWindow` alone | Refused, whatever is in front |
| `AllowSetForegroundWindow` from the window in front | Works, even 5 s later, but any key press cancels it |
| `AttachThreadInput` | Works, but joins another thread's input queue, which hung a test run before |
| Tap F24, then `SetForegroundWindow` | Works, 15 of 15, with nothing left held |

**Built:** ask, and if refused, tap F24 (an unbound key) so this process had the last input,
and ask again. Send hands nothing over, as this also covers phone prompts and later switches.

**Windows can agree and do nothing.** In real turns, 5 of 8 asks returned true and left nothing
in front, with every window answering, for as long as anyone waited. Tapping and asking again
fixed it at once, so while the switch hasn't landed, it taps and asks again every 250 ms. With
that, the same batch went 8 of 8. Why Windows does this wasn't established: 40 switches in a tight
loop with no turn running never showed it.

**If Windows still refuses,** the tool returns the refusal and the agent can tell you. Nothing is
sent anywhere else.

### 5.5 Rules that change in Auto

Ask keeps today's rules.

| Today | In Auto |
|---|---|
| Windows key refused | Allowed. The Start menu or a Win+R box adopts as a window Gaia caused. |
| Run stops when the window changes | Pin and adopt (§5.2) |
| Clicks only inside the target | `os_click` gets `anywhere: true`, for coordinates only: the taskbar, the tray, another window. The window at that point is checked against exclusions and the vault, Gaia's and the notch are still refused, and the click adopts. Without the flag, a window covering the target still refuses. |
| Later in a run, Gaia in front is a stop | Pause (§5.2) |

**Stays everywhere:**
- Password, card and one-time code fields are never read or typed into.
- The exclusion list.
- Nothing touches Voyager's windows while the vault is unlocked.
- Gaia's own windows are never a target.
- Input to elevated windows still silently fails (UIPI). A UAC prompt is on the secure
  desktop, out of reach, so the agent has to ask you.
- 20 steps per `os_steps` list, and 2000 characters per `os_type`.

### 5.6 Long tasks and the step limit

The limit is per list, so it isn't a budget. Ranking jobs across a 10-page board might be:

```
os_scroll (read_after) × ~5 per page  →  each is one list of one step
os_click "Next"                       →  one list of one step
× 10 pages                            →  ~60 calls, 0 cards, limit not involved
```

The limit stays as it is, and **a turn has no total action limit**, in line with Auto
meaning no cards. The Fibonacci-style checkpoints suggested during design aren't needed
for this. If a run-length check-in turns out to be wanted, it would be a separate per-turn
budget, and it's easy to add later.

**`read_after: true`** on an action returns the fresh `os_read_screen` text with its
result, so scroll-then-read costs one model round trip instead of two. It needs *can see
screen*. It's the one addition aimed at the tedious-task case, where that round trip is
most of the time and cost. A long run is still expensive in tokens, and the `region`
argument can trim it.

**Pacing.** At least 250 ms from one step's start to the next, plus the flash's lead-in
(§6.2). This is what makes the flashes readable and leaves a moment to react. It adds
little to a real run, where the model's round trip dominates.

### 5.7 CLI permissions

`GaiaChatTools.permit` reads the chat's mode **at the moment of the call** and answers
allow in Auto. Revoking mid-turn therefore applies to the next command.

The command still shows in the activity row (§7). Abort's refusal stays first.

**To verify against both CLIs, in Phase 3:**
- Whether Claude Code's own classifier or settings can deny without reaching `permit`.
  User-settings denials would still apply, and I think that's right.
- Whether a command Codex is allowed still runs inside its Windows sandbox. If so, GUI
  launches from it may not behave, which is one more reason `os_open` is the supported way.
- What a stopped turn does to a shell command mid-flight.

## 6. Flashes

### 6.1 Why native

They draw over other apps, so they can't be Flutter. They extend
`gaia_control_border.cpp`'s approach: small layered windows that are topmost,
non-activating, click-through and excluded from capture.

They run in **Ask and Auto**, and no agent ever sees them in a screenshot.

### 6.2 Effects

About 400–600 ms each, in Gaia's accent drifting into the Astral gold, over the border's
dark falloff so they read on a white page.

| Action | Effect |
|---|---|
| Click | Target ring contracts onto the point (lead-in), then a ripple on contact |
| Double click | Two ripples |
| Right click | Ripple with a small menu-corner tick |
| Scroll | Three chevrons sliding in the direction, more for a bigger amount |
| Type | Soft outline on the field, then a shimmer along it while typing |
| Key or chord | Keycap pill near the target window's top ("Ctrl+S") |
| Drag | Dot at the start, a trail, a ripple at the end |
| Open, focus, adopt | Brief outline around the whole window, with its name |
| Move, resize, close, minimize | The same outline, at the window's old position |

**Name pill.** When the target is a named control, a small pill shows the name ("Mark as
read") beside the effect. This is the direct answer to coordinates meaning nothing.
Typed text is never shown in the pill.

**Timing.** The lead-in starts about 120 ms before the input, so your eye gets there
first, and the rest plays after. `_step` awaits only the lead-in. The action's pass/fail
doesn't wait on the animation.

### 6.3 Mechanics

- A new `Flash(kind, rect, direction, label)` beside `Show` and `Hide`, on the border's
  channel, fire and forget.
- A small pool of windows, sized to the effect, on a ~16 ms timer on the platform thread.
  No timer and no cost when idle, keeping the border's "costs nothing at rest" property.
- Per-monitor DPI, as coordinates are already physical pixels.

**Hazard to test first:** the flash sits exactly where the click lands. Real input and
`rootAt`'s `WindowFromPoint` must both pass through it, or Gaia refuses its own clicks as
"another window is covering". `WS_EX_TRANSPARENT` should do this, as it does for the
border's strips, but the strips were never under a click target.

### 6.4 Ask's step preview

A card's coordinates stay meaningless in Ask, so the same machinery fixes them: hovering a
step on the card shows its marker and name pill on the target, and opening the card pulses
them. A small addition that fixes the complaint for the mode that keeps cards.

## 7. Showing what ran

In Auto the `control` card isn't blocking, so it becomes an activity row:

- **One card per turn**, not per call: "Clicked 'Mark as read' · Scrolled · …", collapsed
  to "12 actions in Gmail" and expandable. It covers shell commands too.
- **Same card kind** (`GaiaCardKind.control`, state `accepted`), so the action log, the
  phone and older builds work unchanged. No Undo, as today.
- **Sync is debounced**, about every 2 s and when the turn ends. Today's one-write-per-state
  pattern would mean a Firestore write for each of hundreds of steps.
- **The step list is capped** to the latest 200 in the synced card, with the count kept. A
  long run shouldn't produce a huge message.
- Typed text syncs with the card, as it does now. Worth knowing in the context of a long
  run, but not a change.

## 8. New tools

Every tool below refuses under Abort, without the right grant, and on excluded apps and the
unlocked vault. Each is a card in Ask and immediate in Auto. Tool names and descriptions are
one static list, so the wording has to fit both modes: "Runs at once or after a card,
depending on the chat's mode".

Changing the tool list makes existing Codex threads hand over once (`sessionFound: false`).
That's the existing handover working, not a failure.

### 8.1 `os_open {target}`

The answer to "new tool or auto-focus". A launch from the terminal can't be reliably tied to
Gaia: `start` hands off to the shell, and a browser's new window belongs to a process that
already existed. Auto-focusing anything new would also steal focus for unrelated windows.

- `target` is an installed app's name, a file or folder path, or a URL.
- Names resolve through `shell:AppsFolder`, so Store apps work. Launching is `ShellExecuteEx`,
  never `runas`.
- Exclusions are checked **before** launching, against the name or URL, and again against the
  window.
- It takes a snapshot of top-level windows, launches, then waits up to 10 s for a new window.
  A single-instance app may show no new one, so it falls back to that exe's existing window.
  If nothing is identifiable it says so and points at `os_windows`.
- It brings the window up (§5.4), pins it (§5.2), flashes it, and returns its app and title.

**Tool descriptions steer agents to it** over `start` in the shell. The fallback for a window
opened from the terminal anyway is `os_windows` plus `os_focus`.

### 8.2 `os_windows` and `os_focus {window}`

- `os_windows` lists visible top-level windows: id, app, title, bounds, minimized, in front.
  It's a read, so it needs *can see screen*. Gaia's own are left out. Excluded ones show as
  "excluded", with no title. With the vault unlocked, Voyager has no title.
- `os_focus` takes an id or a unique title match, restores the window if minimized, brings it
  up and pins it.
- Reads stay on the pinned, in-front window. A covered browser's page isn't in its
  accessibility tree (BUG-338), so reading other windows wouldn't be reliable.

### 8.3 `os_window {window, action, left?, top?, width?, height?}`

`minimize`, `maximize`, `restore`, `move` (including resizing) and `close`.

`close` sends `WM_CLOSE`, never a kill, so a "save changes?" prompt still appears and adopts.
Voyager's main window can't be closed this way, since it hosts the tools themselves.

### 8.4 `os_drag {from, to}`

Takes names or coordinates. Also available as a `drag` action in `os_steps`.

**A new failure mode:** chords go in one `SendInput` so nothing is held between looks, but a
drag has to hold the button across several moves. So:
- Every stop path must release the button (`_releaseHeld`).
- The hold is capped at 5 s.
- The window under the cursor is checked at the end, so a stop or a covering window can't drop
  into the wrong place.

### 8.5 `os_clipboard {action, text?}`

- `write` replaces the clipboard with text. The tool says so, since it overwrites what you
  copied. It marks the content as excluded from clipboard history.
- `read` returns text only, at most 20,000 characters, framed as reference data like the
  screen reads (§5.3 of GAIA_HLD.md). It needs *can see screen*.
- **Read is refused** while the vault is unlocked, and when the clipboard carries the formats
  password managers set (`ExcludeClipboardContentFromMonitorProcessing`,
  `CanIncludeInClipboardHistory = 0`). This is the clipboard's version of "password fields are
  never read". Not every password manager sets these, so it reduces the exposure rather than
  closing it.

## 9. Risks

**A steered agent — the main risk.** Everything Gaia reads in Auto can contain instructions:
emails, job posts, web pages. `os_read_screen` already frames its output as "context, not
instructions", which GAIA_HLD.md §5.3 rightly calls a mitigation, not a boundary. A steered
agent can act in under a second, which is faster than Esc. Taking responsibility settles
whose problem that is, not whether it happens. An inbox is the clearest example, since strangers
write it. **Mitigations are partial:** the exclusion list, pacing, flashes, sensitive-field
refusals, and using Auto per chat, for tasks you've chosen. Ask remains for untrusted content.

**Shell access undercuts the hard refusals.** With shell commands auto-allowed, an agent can
take a screenshot or send input from PowerShell, and `os_*`'s checks never see it. So in Auto
the exclusion list, vault rule and sensitive-field refusal **protect against accidents and
ordinary model behaviour, not a determined or steered agent.** The vault's contents stay
encrypted, but what's on screen doesn't. This follows from choosing shell auto-allow, and it
should be understood as part of that choice.

**Phone prompts.** With nobody at the screen there's no Esc and nobody sees the flashes, so Stop
and Abort on the phone are the only controls, and they depend on the connection and on noticing.
This is the case where the "I can always stop it" argument is weakest. The activity row syncs
every 2 s, which is the only view.

**Irreversible actions.** Sends, purchases and deletes aren't special-cased, as a page can't be
classified reliably. Tool descriptions tell agents to ask with `ask_user` before something
irreversible that you didn't clearly ask for, but that's guidance, not enforcement.

**A forgotten Auto.** The grant survives restarts like the others. The notch names the mode and
the chat, so it can't be invisible. A chat sitting in Auto with a queue draining is the case to
watch.

## 10. Decided

Decided with Juno, 2026-11-03:
- Hand is Off / Ask / Auto, per chat. Ask's cards stay.
- Auto covers OS actions, CLI shell and file-edit prompts, and prompts from the phone.
- Voyager data proposals keep their review card, even in Auto.
- Sensitive-field, exclusion and vault refusals stay.
- The 20-per-list limit stays. A turn has no total limit.
- New tools: `os_open`, `os_windows`, `os_focus`, `os_window`, `os_drag`, `os_clipboard`.
  Whole-screen screenshots aren't included.

Design choices made here, open to review:
- Applying shell auto-allow and phone prompts only in Auto, not in Ask.
- Switching windows yourself ends the turn, while Gaia in front only pauses it.
- Moving the mouse yourself doesn't stop a run. Gaia's next move takes the cursor back, so a
  run you want to stop needs Esc. A cursor-moved check would be cheap (compare to where Gaia
  left it) if this proves annoying.
- Auto needs *can see screen*.
- Pacing of 250 ms and the 1.5 s adoption window. Both are starting values to tune.

## 11. Phases

The native border work uncommitted in the working tree (notch, Revoke) comes first, since
§4 and §6 build on it.

| Phase | Work | Done when |
|---|---|---|
| **1. Session** (done, §11.1) | Foreground spike (§5.4); confirm the terminal-launch behaviour; control session, pin, adoption, pause, latch; Esc for the session | With a forced Auto flag: an action after no click reaches a window behind Gaia on both CLIs; Esc between calls ends the turn; Alt+Tab mid-run stops it with nothing sent to the new window |
| **2. Flashes** | Native effects; `Flash` channel; Ask's preview | A real click lands through a flash and `rootAt` agrees; capture shows no flash; under 2 ms per frame, nothing when idle; legible on a white and a dark page at 100% and 200% DPI |
| **3. Auto** | Grant field, menu, notice, notch text; card skip; `permit`; activity card and debounce; the §5.5 rules; `read_after`; phone; the §5.7 checks | "Mark my top 3 emails as read" on Haiku raises 0 cards and shows 3 flashes; a shell command raises none; a phone prompt runs and Stop and Abort work; Ask behaves exactly as before |
| **4. Opening** | `os_open`, `os_windows`, `os_focus` | Gaia opens an installed app, a Store app, a file and a URL, and the next action lands there each time; an excluded app is refused before launch |
| **5. More tools** | `os_window`, `os_drag`, `os_clipboard` | A stopped drag leaves no button down; a password manager's copy is refused on read |

### 11.1 Phase 1 results (2026-11-03)

Forced Auto is `GaiaHost.forceAuto`, or `--dart-define=GAIA_FORCE_AUTO=true`. It applies to every
chat with *can control*, and Phase 3's grant replaces it. Only OS actions skip their card: CLI
permission prompts and the activity row are still Phase 3. Pacing came with Phase 2's flashes.

Real turns in `gaiaqa`, target behind the real Gaia window, nobody clicking:

| Check | Claude Code (Haiku) | Codex (Sol) |
|---|---|---|
| An action reaches the window behind Gaia, no open card | Pass | Pass |
| Esc between calls: turn cancelled, Save never clicked | Pass, 8 of 8, under 1 s; drain off | Pass; drain off |
| Alt+Tab mid-run: turn cancelled, nothing sent to the new window | Pass | Pass |
| Gaia in front for 25 s: nothing sent; target back: it carries on | Pass | Pass |

`test/tool/gaia_os_control_live_test.dart` adds Esc, Alt+Tab and a click mid-text, a real dialog
adopted and handed back, the agent's own Esc, and activation from behind another process. The
existing Ask tests pass unchanged.

**Not checked:**
- How often the 1.5 s rule misfires in real use. The design asked for a measure of how often a
  switch of yours gets adopted. The input check replaces most of that question, and what's left
  needs real use.
- The 5-minute pause limit at its real length; a unit test covers it at 300 ms.
- A real app as the target. These runs used WinForms probes.
- One real CLI's shell launching a window (§3).
- Prompts from the phone.

### 11.2 Phase 2 results (2026-11-03)

Built: `GaiaFlashes` in `gaia_control_border.cpp`, played by `flash` on the border's channel
(`gaia_flash.dart`). `GaiaOsControl` flashes each step, waits the 120 ms lead-in before its input,
paces Auto steps 250 ms apart, and flashes an adopted window. Each step on a card carries its
marker, which shows when hovered and pulses once in order when the card opens, in Ask only. The
companion runs the same runner, so it plays the preview itself.

Changes from §6:
- **Outlines are drawn once.** Redrawing a field-sized window every frame took 20 ms at 200%. A
  field's outline is four strips, drawn when it starts and then only faded; typing's shimmer is
  a small spark window that runs round it.
- A mark round a control (the preview) holds steady rather than pulsing, as pulsing meant four
  window updates a frame. A mark at a point still pulses.
- Typing with nothing aimed has no field to outline, so it shows a "Typing" pill near the window's
  top, as a key does.

Checked by a native harness built from the same source (not committed), and the unit tests:

| Check | Result |
|---|---|
| A real click lands through a flash and through a name pill | Pass |
| `WindowFromPoint` passes through the flash, the pill and both outlines, on its own thread and another | Pass |
| A screen grab shows no flash; the same grab with capture allowed differs in ~21,000 pixels | Pass |
| Painting a frame of any effect | Under 1 ms at 100% and 200% |
| A whole frame, window updates included, one flash at a time at 200% | Mean 0.1 to 1.5 ms; worst 1.0 to 5.4 ms |
| Six playing at once at 200% | Mean 3.8 ms, worst 5.3 ms |
| Nothing when idle: timer stopped, windows hidden and pooled | Pass |
| Legible on white and dark at 100% and 200% | Rendered and looked at; reads on both |

**Under 2 ms isn't met at the worst frame.** Painting is well under. Each layered-window update
costs about 0.3 ms with spikes to 1 ms, so the frames where several windows fade in or out at once
go over. Updates are skipped while nothing changes, which is most of each flash. Starting one costs
2 to 11 ms once at 200%, most for a window outline or a large field.

**Not checked:**
- A flash from the running app. The runner builds, but `ParseFlash` and the Dart channel weren't
  driven end to end, nor the card's hover and pulse.
- A second monitor at a different scale. Each flash takes the scale of the monitor it starts on.

### 11.3 Astral Trace + Bloom against the frame budget (2026-11-03)

Astral with the Trace + Bloom click is the live style. As first built it took 4.6 ms a frame on a
click at 200%, and up to 11 ms on typing, keys and windows, which redrew every outline, pill and
corner each 32 ms to trace them round. Changes:
- Outlines, pills and window corners no longer trace round or bloom. They are drawn whole once
  and only faded, as in §11.2.
- A click's square is 64 rather than 96 logical pixels, and each pixel's distances and angles
  are worked out once per scale and kept. Scroll paints only round each chevron, in a 136-pixel
  square rather than 320. Both draw the same as before, within one level of rounding.
- Faded pieces get at most four updates a frame, so a window's nine pieces take turns. Finished
  windows are hidden three a frame, in one batch, rather than all in the frame they end.

Whole frames, window updates included, one flash at a time (native benchmark, 4 runs each):

| | 100% mean / p95 / worst | 200% mean / p95 / worst |
|---|---|---|
| Click (Trace + Bloom) | 0.6 / 1.4 / 2.1 ms | 1.0 / 1.8 / 2.3 ms |
| Double, right, point mark | 0.5–0.6 / ≤1.0 / ≤2.1 ms | 0.9–1.0 / ≤1.8 / ≤2.6 ms |
| Scroll | 0.6 / 1.1 / 2.4 ms | 1.0 / 1.6 / 1.9 ms |
| Typing, mark round a field | 0.4 / ≤1.6 / ≤2.9 ms | 0.4–0.5 / ≤1.7 / ≤3.1 ms |
| Key, window | 0.2–0.5 / ≤1.7 / ≤2.4 ms | 0.2–0.5 / ≤1.7 / ≤3.8 ms |

Every case's 95th percentile is under 2 ms. A few frames per flash still go over, from window
updates as in §11.2. Starting a flash is unchanged: 2 to 15 ms once, most for a window.

**Not checked:** several flashes at once, since the budget for faded pieces is per flash.

**End-to-end check after 4:** the job-board task, or a scratch version of it, runs 10+ pages with
no cards, and a press of Esc at a random moment stops it within one step each time.

**Regression guards:** `test/tool/gaia_os_control_live_test.dart` extends to pin, adoption and
Esc between calls. Existing Ask tests should pass unchanged, which is what shows Ask didn't move.
Long-lived probes should follow the existing memory notes on background input and focus, with
Phase 1 specifically testing a real foreground switch.

## 12. Changes to GAIA_HLD.md when built

- **§5.2, §10.1:** in Auto, CLI prompts are answered without a card.
- **§12.2:** phone prompts act in Auto.
- **§15.6:** three modes; the step list is the boundary only in Ask; new tools; the target rule
  for Auto.
- **§15.7:** Esc's reach; add the latch and paused drain.
- **Phase 9C notes:** "Approving takes someone at the screen" stays true of Ask only.
- **§20:** the 2026-11-01 decisions on screen text and the phone get a dated amendment rather than
  a rewrite, keeping the reasoning for why Ask exists.
