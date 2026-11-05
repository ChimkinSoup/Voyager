# Gaia — Autonomous PC Control (HLD)

Status: **Done, 2026-11-05.** Every phase is built and checked live, and no bugs from it are
open. Phases 1 and 2 done, built and checked live 2026-11-03 (§11.1, §11.2). Phases 3 and 4
done, built and checked live 2026-11-04, the phone included (§11.4, §11.5, §11.6). Phase 5 done,
built 2026-11-04 and checked live 2026-11-05 (§11.7). BUG-359 and BUG-360 from it are fixed
(2026-11-05). The follow-ups were run 2026-11-05 (§11.5, §11.6, §11.7); BUG-361 and BUG-362 from
them are fixed and checked in the app (2026-11-05), including the code review's follow-ups. Not
run, by decision: a second monitor. It changes GAIA_HLD.md §5.2, §10.1, §12.2, §15.6,
§15.7 and §20; §12 below lists how.

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
session, `os_type` therefore sends at most every 20 ms. Since BUG-352 it sends one character each
time, in Ask too: about a minute for the 2000-character limit (§11.6). Exclusions and the vault
still apply.

**A dialog that takes longer than 1.5 s to appear stops the run,** unless the pinned window has
closed, the new one is from its process, and the user has pressed nothing since Gaia's last step
began: then it's adopted too, as a splash screen handing over to its main window is (BUG-362,
2026-11-05). Kept to the same process and a closed pin, so neither a window that takes the front
by itself nor another window of the pinned app (an Outlook reminder) is adopted. The hand-over
gets up to 1 s either way round: a main window shown before the splash closes waits for it to
close, and a splash that closes first, leaving another app in front until the main window
shows, waits for that window. Input from the user meanwhile ends the turn at once. Otherwise the
safe way to be wrong, and the first thing to tune if it proves annoying.

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

**Checked against both CLIs in Phase 3** (2026-11-04, Claude Code 2.1.318, Codex 0.166.0;
the "Auto" scenarios in `test/gaia_cli_contract_test.dart` and `test/gaia_codex_contract_test.dart`):
- **Claude Code's settings deny without reaching `permit`.** A `deny` rule refused
  `echo gaia-denied` with `system/permission_denied` and no `permit` call, while an `ask` rule's
  command reached `permit` and ran. That was a project rule, which safe mode reads; a user rule
  goes through the same check. As intended.
- **A command Codex is allowed runs as the signed-in user**, not as the elevated sandbox's own
  account: `whoami` wrote `zephyrusg14\juno`. So GUI launches from it should behave. Not tried:
  an actual GUI launch, which needs the screen on.
- **A stopped turn:** Claude Code's command dies with it (the turn's process tree is killed; it
  was a foreground command, `is_backgrounded: false`). Codex leaves its command going after
  `turn/interrupt`, so on a stop Gaia kills the processes started under the shared app-server
  since that turn began, leaving any that may be another chat's running command (BUG-350).
  Checked in the app (§11.6). Revoke still leaves a running command alone (§5.3).

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
| Drag | A click at the start, the marker trailing to the end and growing on the way, then holding a moment before it fades |
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
- Names resolve through the Start menu, so Store apps work. An exe, by path or by a Start ID
  that's its path, starts with `CreateProcess`, never elevated, so one that needs administrator
  fails and says so. Anything else opens with `ShellExecuteEx`, never `runas`.
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
| **2. Flashes** (done, §11.2) | Native effects; `Flash` channel; Ask's preview | A real click lands through a flash and `rootAt` agrees; capture shows no flash; 95th percentile under 2 ms per frame, nothing when idle; legible on a white and a dark page at 100% and 200% DPI |
| **3. Auto** (done, §11.4, §11.6) | Grant field, menu, notice, notch text; card skip; `permit`; activity card and debounce; the §5.5 rules; `read_after`; phone; the §5.7 checks | "Mark my top 3 emails as read" on Haiku raises 0 cards and shows 3 flashes; a shell command raises none; a phone prompt runs and Stop and Abort work; Ask behaves exactly as before |
| **4. Opening** (done, §11.5, §11.6) | `os_open`, `os_windows`, `os_focus` | Gaia opens an installed app, a Store app, a file and a URL, and the next action lands there each time; an excluded app is refused before launch |
| **5. More tools** (done, §11.7) | `os_window`, `os_drag`, `os_clipboard` | A stopped drag leaves no button down; a password manager's copy is refused on read |

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

**The budget is the 95th percentile, not the worst frame.** Painting is well under 2 ms. Each
layered-window update costs about 0.3 ms with spikes to 1 ms, so the frames where several windows
fade in or out at once go over. Updates are skipped while nothing changes, which is most of each
flash. Starting one costs 2 to 11 ms once at 200%, most for a window outline or a large field.
§11.3 has the figures for the live style.

Then in the running app, after §11.3: a debug build in `gaiaqa`, real Haiku turns, and a WinForms
target. The display is at 200%.

| Check | Result |
|---|---|
| All nine flash kinds through the channel, from the main instance; a mark from the companion | Pass |
| Auto, one `os_steps` with two clicks: the flash comes first and both clicks land | Pass; flash about 144 ms ahead |
| The second click's `rootAt` check, with the first flash still over that point | Pass |
| Ask: opening the card pulses each step's marker in order | Pass; about 290 ms apart |
| Ask: hovering a step shows its marker on its control, and hovering again replays it | Pass, with a real cursor |
| Ask: Run all plays the click and typing flashes, and both actions land | Pass |
| A screen grab during a click and a window flash, as shipped | 0 pixels differ |
| The same grabs with capture allowed in-process, each kind on each page | Thousands of pixels differ; legible |
| Astral at 100% on white and dark | Legible; the same source rendered in memory at 96 DPI |
| Flash windows once finished | All hidden |

**Not checked:**
- A second monitor at a different scale. Each flash takes the scale of the monitor it starts on.
- Live frame times in the running app. The figures are from the native benchmarks.
- 100% on a real display, as the render above bypasses the monitor's scale.

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

### 11.4 Phase 3 results (2026-11-04)

Built:
- **The grant.** `GaiaGrant.auto`, written only when on, so older builds read Ask. Auto counts
  only with *can control* and *can see screen* (`GaiaGrant.isAuto`). The store's `setAuto` turns
  both on with it; *can see screen* off drops it, *can control* off drops it, and turning either
  back on gives Ask, never Auto. Revoke and Abort clear it with the rest. `forceAuto` and
  `GAIA_FORCE_AUTO` are gone.
- **The hand** is a menu: Off, Ask, Auto (`GaiaHand`). A new chat isn't offered Auto. The first
  Auto on a device shows the notice, confirmed with the send key (Ctrl+Enter unless rebound),
  and the main instance refuses Auto until then (`gaia_auto_consent` beside the Abort flag).
  Auto's icon is the filled hand with a gold dot.
- **The notch** names a chat in Auto "Gaia · Auto · {chat}", and adds "Esc to stop" while a
  session is open, or "Paused" while Gaia is in front. Ask's label is unchanged. Switching a
  chat from Auto to Ask mid-turn ends its session, so its next action is a card.
- **`permit`** asks the main instance (`isAuto`) at each prompt, after Abort's refusal. In Auto it
  allows with no card and lists the command in the activity card.
- **The activity card** (§7): one per turn, `GaiaCardKind.control` with `tool: 'activity'`,
  `input.activity`, the latest 200 labels and the `total`, answered as a list that ran in full
  for the action log and older builds. A stop is a "Stopped: …" row. Its updates are saved with
  the reply's next save (at most a second apart) and at the turn's end, rather than each.
- **§5.5:** the Windows key in Auto, alone or in a chord; Start and Search adopt as windows Gaia
  caused, while the taskbar and desktop still don't (by window class). `os_click` takes
  `anywhere` in Auto, for a point alone: what's there is checked against the exclusion list and
  the vault, and Gaia's windows and the notch's button are refused.
- **`read_after`** on every action tool: the result, then "The screen now:" and the read.
- **Answering `ask_user`** resumes a paused session (`osResume`), closing §5.2's known gap: the
  next step brings the target back. The 5-minute pause limit still runs while the question
  waits.
- **Phone prompts** need nothing of their own: a turn started from the phone runs in Auto like
  any other, with no card for the phone to refuse. Stop and Abort are the existing paths.
- Tool descriptions say "runs at once or after a card, depending on the chat's mode", and ask
  for `ask_user` before anything irreversible.

Checked by unit and widget tests (all 1100+ Gaia tests pass, Ask's unchanged), and against the
real CLIs for §5.7 (above).

**Checked live with the display on** (2026-11-04, a debug build of the working tree on `gaiaqa`,
real Haiku and Codex Sol turns, nobody at the PC). The bugs named in this pass and the next are
as found then; all are since fixed (§11.6):
- `test/tool/gaia_os_control_live_test.dart`: 8 of 8, three runs. Its Alt+Tab test pressed at a
  fixed 60 ms, inside the 250 ms pace after the click that set it up, so nothing had been typed;
  it now waits for the typing to start.
- "Mark my top 3 emails as read", on a local mock inbox in a scratch Chrome profile rather than
  real mail: no approval cards, 3 click flashes 250 ms apart, the first three marked read, and the
  activity card lists the 3 clicks.
- Win+R: Run adopted; the typing and Enter went into it and Character Map opened. Start: the
  Windows key's Search window adopted, then typing and Enter opened Calculator. Its search box
  sits under the floater, so the aimed typing was refused as covered and the agent typed into
  what had focus.
- An `anywhere` click on the taskbar's clock opened the Notification Center, adopted; Esc closed
  it. The taskbar here auto-hides, so the agent needed a click on its bottom row first.
- The hand menu by a real click (Off, Ask, Auto; Auto only once the chat has a message), the
  notice, confirmed with a real Ctrl+Enter, and Auto's icon with the gold dot. The menu's labels
  are underlined in yellow: BUG-354.
- The notch: "Gaia · Auto · 88 chats" (this profile has 88 chats with *can control* on), then
  "· Esc to stop" while a session is open, "· Paused" with Gaia clicked to the front mid-run,
  nothing sent in the 16 s it stayed there, and the run carrying on once the inbox was clicked.
- A GUI launch from a shell command, on both CLIs: `cmd /c start charmap` from Codex and from
  Claude Code's Bash each opened Character Map **behind** the window in front, not in front, so
  §3's "not reproduced" does reproduce with a real CLI's shell; the agent needs `os_focus` after.
  A second Codex run reported success but left no Character Map running; not looked into.
- Neither CLI's command reached `permit`, so no "Allowed …" row: Codex's sandbox allowed it, and
  this machine's Claude Code user settings have `defaultMode: auto`, whose classifier allowed it.
  Such a command raises no card in Ask either.

**Checked from the phone** (2026-11-04, later the same day: a fresh debug build of the working
tree on `gaiaqa`, qa-128, Haiku; the Android emulator on the 16:51 APK, signed in to qa-128 and
paired with `gaiaqa`, codes matching), all in the Auto chat from the pass above:
- A phone prompt runs in Auto: each reply had only the activity card, with no approval card.
  "Open Calculator, then press 1 to 9 with `os_click`" opened Calculator and clicked in turn. The
  first prompt's `os_open` of Character Map failed before launch: BUG-356.
- Stop from the phone, mid-run: the reply was cancelled 2 s after the tap, with 7 of the 9
  clicks done, and Calculator read 1,234,567, so nothing ran after it.
- Abort from the phone's Status tab, mid-run: the reply ended `aborted`, the companion was killed
  and relaunched, the desktop showed "Aborted", and the last click (1) never ran (98,765,432).
  It took about 11 s from the tap, against Stop's 2 s, so some clicks may have landed in that
  time. That didn't reproduce: 1.0 to 1.6 s in 10 later trials (§11.6). Rearm from the phone
  cleared it.
- On the way, due reminder stickies showed on the login page of a signed-out phone: BUG-355.

### 11.5 Phase 4 results (2026-11-04)

Built:
- **`os_open {target}`**, an action: a card in Ask, immediate in Auto. A target with a scheme of two
  or more letters is a URL (`https:`, `mailto:`, `ms-settings:`); an absolute path must exist;
  anything else is a Start menu name, matched exactly, else as the one name containing it, and
  several or none are refused with the names. It launches on an isolate of its own, as §8.1 says.
- **Exclusions before launch,** at plan and again at run: against the Start name, the exe in the
  app's id (a desktop app's id is often its path), a path's `.exe` or `.lnk` name, a URL's host,
  and the exes that would open it, so a URL whose browser is excluded never launches. Then against the window, and the vault, as for any target.
- **Finding the window, strictly:** only a window shown to be what launched counts. One that opens
  by chance during the wait is passed over, even in front. A window is the launch's if it is from:
  - the launched process, or a process started under it (a launcher stub);
  - an exe that opens the target: the path's exe, a Start shortcut's target exe, or the handler
    of the file's extension or the URL's scheme (`AssocQueryString`); a folder is Explorer;
  - or it carries the target's app ID: the Start ID, or the handler's, on the window itself, as
    Store apps' frames and Chrome carry, or on its process's package, as Windows 11's Notepad has.

  Top-level windows are listed before the launch and every 100 ms after, for up to 10 s. A new one
  that's the launch's wins, the launched process's own first. Then one of its that came in front.
  Then, once the launched process has exited (a single-instance app handing over) or the wait is
  up, one of its that was already open. Otherwise it says it couldn't tell and points at
  `os_windows`. `Microsoft.AutoGenerated.{…}` Start IDs are shortcuts whose windows carry no ID;
  their target comes from the shell (`System.Link.TargetParsingPath`).
- **Then,** for `os_open` and `os_focus` alike: restore if minimized, pin (in Auto), bring it up
  with the F24 tap (§5.4) from behind any window, flash its outline, and tell the agent
  "{app}: "{title}" is in front, and later calls act on it." In Ask nothing is pinned, and the next
  card targets it because it's in front, or right under Gaia once you click the card.
- **`os_windows`**, a read: the windows Alt+Tab would show, front first, minimized and topmost
  included, Gaia's left out. Each is `id: app "title" [bounds]` or `minimized`, and the target is
  marked "the os_ tools work on this" rather than "in front", since Gaia is usually what's in front.
  Excluded windows are `id: excluded`; Voyager's has no title while the vault is unlocked. Ids are
  window handles.
- **`os_focus {window}`**: an id, else an exact title, else the one window whose title contains
  the words or whose app is them. Excluded windows, and Voyager's with the vault unlocked, are
  matched by id alone, then refused, so their titles never show in a "2 windows match" error.
- **A session can start with no pin.** `os_open`, `os_focus` and `os_windows` don't need a window
  behind Gaia, and work after the pinned window closed. Any other action then says to use
  `os_open` or `os_focus`.
- While `os_open` waits, each poll counts as a Gaia step, so the window it opens coming up by
  itself is adopted (§5.2), and a click or key of yours in that time still stops the run.

Decisions made here:
- **Start names come from `Get-StartApps`** in a PowerShell child (about 0.6–0.8 s per `os_open`
  by name), not from enumerating `shell:AppsFolder` over COM: the win32 package has no
  `IEnumShellItems` or `StrRetToStr`. It covers Store and desktop apps alike.
- **Never elevated.** An exe starts with `CreateProcess`, which fails for one that needs admin,
  and the agent is told the user can open it. `ShellExecuteEx`, used for everything else, could
  still raise UAC for what it opens. Gaia never asks for `runas`, and the prompt is on the secure
  desktop, so it can only be you who approves it.
- After opening a URL, the site isn't checked against the window's address bar, which is often
  still loading. The URL was checked before launch, and the next read or action checks the
  address as always.

Checked by unit tests (all 1135 Gaia tests pass, among them a window opening by chance being passed
over, and nothing but such a window giving "couldn't tell"), and against real Win32 with the
display off (throwaway probes, not committed):
- The window list and `os_windows` text; "Character Map" and "Calculator" resolving through
  `Get-StartApps` in 0.6 s.
- The identity lookups on this machine: To Do's frame carries `Microsoft.Todos_8wekyb3d8bbwe!App`,
  Chrome's windows `Chrome` and Firefox's its Start ID; `https` and `.pdf` open in Chrome, `.txt`
  in Notepad, `ms-settings` in the Settings app ID; Git Bash's and Event Viewer's AutoGenerated
  IDs resolve to `git-bash.exe` and `eventvwr.msc`.
- Real launches, each window found by strict matching: Character Map (0.8 s), Notepad by its
  package's app ID (1.2 s), Event Viewer through shortcut → `.msc` → `mmc` (1.6 s), a folder as
  Explorer (0.3 s). A `.txt` with Notepad already open went into a tab of that window, so there
  was no new window and it was found only at the 10 s limit.

Each then stopped at bringing up with "Windows refused the input": with the display off, nothing
is in front and `SendInput` is refused, as in §11.4.

**Checked live with the display on** (2026-11-04, the same pass as §11.4's):
- The Done-when, in one Auto turn on Haiku with Gaia in front: Character Map, then Select (`!` in
  its box); Calculator, then Seven (7); a `.txt`, opened in Notepad, then Ctrl+End; and
  `https://example.com`, opened in Chrome, then Learn more (it navigated). Each window was
  brought up from behind Gaia and flashed. The typing after Ctrl+End came out garbled: BUG-352,
  Windows 11 Notepad and four characters per `SendInput`.
- `os_focus` on a real window: Character Map, minimized, restored, brought up and flashed, then
  Alt+F4 closed it. A minimized Calculator stops the turn as the user's switch: BUG-351.
- A `.txt` opening as a tab in Notepad already open, with Gaia in front: still the full 10 s, as
  with the display off. Notepad doesn't come in front and its launched process never exits:
  BUG-353.

**Still not checked:**
- An app with a splash screen. The splash would be pinned, and once it closes the next call says
  the window closed, so the agent would need `os_windows` and `os_focus`. Worth seeing how often
  it happens.
- Strict matching's misses: an app whose window comes from a process that isn't the launched one's
  descendant, isn't the exe that opens it and carries no app ID (some game launchers, apps started
  through a service). They now give "couldn't tell", and the agent needs `os_windows` and
  `os_focus`. How often that happens.
- An unrelated window from the same app during the wait (another Chrome window while a URL
  opens) can still be picked, as it's the right app. Seen in §11.6 with two Chrome profiles: the
  URL opened as a tab in the default profile, and the other profile's window was pinned. The
  agent saw the page hadn't changed and said so.
- A real Codex or Claude Code turn choosing `os_open` over `start` in the shell.

**Checked 2026-11-05** (debug build of `4433a197`, Auto, scratch WinForms apps):
- A splash screen (3 s, then the main window): the turn ended `cancelled` as "The user switched to
  another window", 3 of 3, not as described above (BUG-362). Fixed: past `_adoptWithin`, a window
  from the pinned window's process, with no user input since Gaia's last step, adopts (§5.2); any
  other window still stops. Then 3 of 3 `complete`, typing into the main window. A splash from a
  separate exe would still stop. After code review the pin must also have closed, with up to 1 s
  for the hand-over either way round (§5.2): both splash orders 6 of 6 `complete`, and a second
  window of the same app beside its open main window still ends the turn.
- A launcher that starts its window's exe through `explorer.exe` and exits: "couldn't tell", as
  expected, but the same result also adopts the window that came in front, so the agent typed into
  it with no `os_focus`. Haiku called the result contradictory ("Stopped after 0 of 1 step… Nothing
  more was sent" beside "later calls act on it").
- A URL opened with the scratch Chrome profile also on the board: the window that got the tab
  (the default profile's) was pinned, 1 of 1.
- "Open Character Map for me": Haiku and Codex each used `os_open`, not the shell.

**End-to-end check after 4:** the job-board task, or a scratch version of it, runs 10+ pages with
no cards, and a press of Esc at a random moment stops it within one step each time.

**Regression guards:** `test/tool/gaia_os_control_live_test.dart` extends to pin, adoption and
Esc between calls. Existing Ask tests should pass unchanged, which is what shows Ask didn't move.
Long-lived probes should follow the existing memory notes on background input and focus, with
Phase 1 specifically testing a real foreground switch.

### 11.6 Second live pass (2026-11-04)

Run after BUG-350 to BUG-356 were fixed: a debug build of commit `39893543` on `gaiaqa`, with real
Haiku and Codex Sol turns, and a scratch job board (15 local pages). A later round on the same
evening, with BUG-357 fixed, is at the end of this section.

**A mistake in how this was run:** the board was opened in a scratch Chrome profile, but `os_open`
of a URL goes to the default browser, so those runs opened board tabs in Juno's own Chrome, and
some runs clicked there rather than in the scratch window. Only board pages were touched, and
the stop results hold in either window. Use `os_focus` on a scratch window for this check, or
make a scratch browser the default.

**Typing is slower, in Ask too.** The fix for BUG-352 sends each character on its own, 20 ms apart,
which is about 31 ms on the default timer. The 2000-character limit now takes about a minute,
against about 15 s in a session before, and Ask was faster still (1 ms between chunks of four).
This is the one way Ask has moved from "behaves exactly as before". It stays under the CLIs' tool
timeout (`kGaiaMcpToolTimeout`, 1 h 5 min), and the flash lasts as long as the typing
(`_typingTime`), though that estimate counts 20 ms a character, not the 31.

**Re-run after the fixes:** `test/tool/gaia_os_control_live_test.dart` 8 of 8, Alt+Tab mid-text
included, and the 60 `test/gaia*_test.dart` files, 1161 passed, with `GAIA_CLI_CHECK=1`, so the
real-CLI contract scenarios ran too.

**The end-to-end check, on Haiku:**
- Four runs left alone each reached all 15 pages in 82 to 91 s, in the right order, and listed
  them correctly. Each had one activity card and no approval card.
- A real Esc at a random moment, sent only with the board in front: 10 of 10 ended `cancelled`
  with no page load after the press. The status read as ended within 298 to 333 ms, about the
  polling interval. Two more runs don't count: one had finished before the press, and one
  stopped with no press (BUG-358).
- Most of those stops fell between calls and left no "Stopped:" row (BUG-357, since fixed).

**An excluded app is refused before launch,** in real Auto turns, each with "The user has excluded
that app or site, so Gaia can't open it.":
- Character Map by name: no `charmap.exe` started.
- A site (`127.0.0.1`) and a browser (`chrome`) for a URL: the server saw no request either time.
- `notepad` for a `.txt`: no `notepad.exe` started.
- The control, with the list back to its defaults, opened Character Map. A refused `os_open` adds
  no row to the activity card.

**A shell command raises no card, this time through `permit`:**
- Claude Code, with a temporary project `ask` rule in Gaia's working folder: in Auto, no card and
  "Allowed Bash: echo gaia-permit-auto". In Ask, a permission card, and the command ran once it
  was allowed.
- Codex in Auto: its commands reached `permit` with no rule, each with an "Allowed Shell" row, one
  of them writing outside the working folder. Not tried in Ask.

**BUG-350 in the app,** with a Codex Sol turn in Auto running a 25 s command that writes a file at
its end. Left alone, it wrote the file (three times, two of those window-switch trials whose click
the script's own guard refused). The real Stop button (2 of 2), Esc (1 of 1) and a real click on
another window (1 of 1) each ended the turn, with the command gone 3 s later and no file.

**The later round, with BUG-357 fixed:**
- A stop between calls now has its row: a real Esc after a run of clicks gave "Stopped: The user
  pressed Esc.", and a scripted Alt+Tab gave "Stopped: The user switched to another window."
- **BUG-358 is put down to Juno's two Alt+Tabs,** nobody touching the PC after: 40 unattended
  turns and no stop with no cause. Of those, 28 were Haiku, the last 8 of them five clicks each
  through `os_focus`. The earlier Haiku turns often stopped by themselves on the problem above.
  The 12 Codex turns are weak evidence: in 11, `os_focus` left no row, and the one session read
  shows it refused as "2 windows match", as the board was open in both Chromes. They went on to
  read and run `echo`.
- A scripted Alt+Tab within 1.5 s of a Gaia step doesn't stop the run, and is adopted: 1 of 2 did
  this. Injected keys don't reach the input hook (§5.2), so it looks like Gaia's own doing. A
  real key does count, by design. That couldn't be run with nobody at the PC, so it rests on the
  hook and Juno's two presses.
- **Abort from the phone, timed from the tap to `_aborted` set on the desktop:** 1.0 to 1.6 s in
  10 of 10, with 5 on the phone already running, 3 straight after a cold start (with its sync
  going), and 2 on a run the phone itself started, as §11.4 did. Of those, 9 had no page load
  after the tap, and 1 had one at +736 ms, before the flag was set. The companion confirmed each
  time, unlike the 11 s case, where it was killed and relaunched. So the 11 s didn't reproduce,
  and its cause isn't known; no code changed. This is on the current build and the 16:51 APK.
- `test/tool/gaia_os_control_live_test.dart` needs foreground rights: with another app in front
  and none given, its first two window tests fail on `GetForegroundWindow`, as they did here. Run
  from a window brought up with an F24 tap that calls `AllowSetForegroundWindow(-1)`: 8 of 8,
  twice. All 60 `test/gaia*_test.dart` files: 1163 passed.

**Still not run:** the job board on Codex, and Esc on Codex more than once. **Run 2026-11-05
(debug build of `4433a197`):** the job board on Codex in Auto read and clicked "Next page" 15
times in 21 s with no card. Esc on Codex at random points: 4 of 4 `cancelled`, 297 to 336 ms after
the press, no page load after it, each with "Stopped: The user pressed Esc.".

### 11.7 Phase 5 results (2026-11-04)

Built with the display off, so nothing here has run in the app. What's left is
`qa/GAIA_REMAINING_TESTS.md` §I.

Built:
- **`os_window {window, action, left?, top?, width?, height?}`**, an action: a card in Ask,
  immediate in Auto. It finds its window as `os_focus` does (`_windowOf`, shared now), so
  excluded windows, excluded sites and Voyager's with the vault unlocked are matched by id
  alone and refused. `minimize`, `maximize` and `restore` are `ShowWindowAsync`; `close` posts
  `WM_CLOSE`, refused for Voyager's own window; `move` takes left and top, width and height, or
  all four, in the frame `os_windows` reports. It restores a maximized or minimized window first
  without activating it, adds back the invisible borders the frame leaves out, and is
  `SWP_ASYNCWINDOWPOS`, so a hung window can't hold Gaia up. The outline flash plays at the
  window's old place, unless it was minimized.
- **In a session:** what comes in front after counts as Gaia's doing, so a "save changes?"
  prompt after `close`, or the next window after `minimize`, adopts (§5.2). `restore` and
  `maximize` pin the window first, as `os_focus` does since BUG-351. `minimize` or `close` of the
  pinned window leaves no pin and clears "engaged", so Gaia in front after isn't a pause that
  would wait 5 minutes for a window that's gone, and the next action says to `os_open` or
  `os_focus` one.
- **`os_drag {from, to}`**, and a `drag` action in `os_steps`. Each end is a name (with its
  type) or x and y, found and checked like a click's target, inside the window. The button goes
  down at `from`, the cursor moves to `to` in 10 steps 30 ms apart, each also sent as a zero mouse
  move so the app sees input, and the button comes up at `to` only if the target is still the
  window there. A swapped mouse uses its right button, as clicks do.
- **No button stays down.** The drag is noted on the run before the press is sent. Every stop
  path (Esc, Stop, Abort, Revoke, a switch of window, the window covered, Windows refusing input,
  the 5 s hold limit) ends in `run`'s `finally`, whose `_releaseHeld` moves the cursor back to
  `from` and lets go there, which most apps take as no drag. That's a choice over letting go in
  place, which could drop onto whatever is now under the cursor. The move back is sent as input,
  and the button comes up 50 ms later: let go at once, an app takes it where the drag had reached
  (BUG-359). The stop's result then says the drag had begun and where Gaia let go.

  The exception is when the user has moved the mouse. Then the cursor isn't where the drag last
  put it, and Gaia lets go where it is, rather than pulling the pointer out of the user's hand.
  The in-app test for this is `integration_test/gaia_flash_stop_test.dart`.
- **Its cost** was measured in-app by `integration_test/gaia_drag_cost_test.dart` on a
  2880×1800 screen:
  - At first, a full-screen diagonal drag held Flutter's thread up by 45–90 ms at a time for the
    second it plays, because each frame cleared, swept and repainted the whole window spanning
    both ends.
  - Now a frame touches only what it draws:
    - it clears what the last frame drew;
    - the trail sweeps only its band of each row;
    - Windows is sent only the changed rectangle (`UpdateLayeredWindowIndirect`).

    A temporary check found no lit pixel outside that area in any style or direction, so nothing
    goes stale.
  - Painting a frame is now the remaining cost. Presenting it costs at most about 2 ms, even full
    screen.
  - In a profile build (optimised, like release), a frame takes:
    - a short drag: 2–4 ms;
    - a full-width or full-screen diagonal drag: 7–15 ms, plus about 2 ms to present, so about a
      frame at worst.

    Debug builds are about twice as slow, with worst hold-ups of 32–54 ms.
- **Its flash** is one native `drag` effect, played the lead-in ahead of the press, once both ends
  are found. It runs as long as the moves (330 ms) and has three parts:
  - **Taking hold:** the style's click at `from`.
  - **Travel:** the style's marker moves to `to` with a trail behind it, growing as it goes until
    it reaches the click's halo size.
  - **Letting go:** the marker holds there lit (300 ms), then fades (250 ms).

  If a drag is stopped partway, `_releaseHeld` ends its trail along with the button. It calls
  `stopFlashes` on `voyager/gaia_border`, which hides every flash playing in one batch. That's
  every flash, not just the drag's: Gaia runs one step at a time, so nothing else of its own is
  playing then, and ending a single flash isn't supported.

  The in-app test is `integration_test/gaia_flash_stop_test.dart`.
- **`os_clipboard {action, text?}`**. `read` is a read, like `os_windows`: no card, *can see
  screen*, answered by `GaiaOsReads`, framed as `<clipboard_data>` reference data, at most 20,000
  characters with a note when cut. `write` is an action, as §8 says of every tool there: a card
  in Ask naming the text (cut at 200 characters, since the card syncs), immediate in Auto, and
  *can control*. It sets `CanIncludeInClipboardHistory` and `CanUploadToCloudClipboard` to 0.
  It needs no window, and in Auto its row doesn't change the window the activity card names.
- **Read is refused** while the vault is unlocked (before and after), when the clipboard carries
  `ExcludeClipboardContentFromMonitorProcessing`, `Clipboard Viewer Ignore` (KeePass's older
  marking) or `CanIncludeInClipboardHistory = 0`, unless that's Gaia's own write (by the
  clipboard's sequence number), and by the app that put it there (`GetClipboardOwner`): an
  excluded app, an app Gaia can't name, or a browser while a site is excluded, as `os_windows`
  treats a browser it can't check. With no owner, as some apps leave it, or one that has since
  closed, only the markings apply, but only while nothing is excluded. With any exclusion set,
  such a read is refused, since it may have come from an excluded app. Gaia's own write is never
  refused this way.

Decisions made here:
- `os_clipboard` read follows `os_windows` rather than §8's "each is a card in Ask": reading
  is what *can see screen* grants, and a card per read would make no sense beside
  `os_read_screen`. The owner check covers the exclusion list, which a read of the clipboard
  would otherwise go round.
- A clipboard write overwrites what the user copied with no backup. The tool's description
  tells the agent to say so.
- A copy whose app has since exited (`clip.exe`, `Set-Clipboard`) stays refused while anything
  is excluded, and the default list never is (2026-11-05). Reading it would let an excluded app's
  copy through once that app closes.

Checked by unit tests (all 1176 Gaia tests pass; 30 new in `gaia_os_control_test.dart`,
`gaia_os_reads_test.dart` and `gaia_tools_test.dart`), and with the display off against real
Win32 (`test/tool/gaia_more_tools_live_test.dart`, run by path):
- Gaia's write reads back as written, with both DWORDs at 0. Another process's plain copy reads.
  A copy from another process marked either way, as a password manager does, is refused, and
  one with `CanIncludeInClipboardHistory = 1` isn't. The clipboard's text was put back after.
- `os_window` on a WinForms probe: moved and resized to exactly 300,220 900x400 by its DWM
  frame, minimized, maximized, moved out of maximized (restored first), and closed, its
  `FormClosed` firing.
- The two drag tests, on a real TrackBar, stopped at `os_focus` with "Windows refused the
  input", as §11.5's did with the display off. They need running with it on.

**Not checked with the display off:** everything in the app, the Done-when included. The drag's
10 moves were a guess at what apps need to see a drag, Explorer's OLE drag included. Real
password managers' markings weren't seen; the probe set them from PowerShell. The live pass below
covers these.

**Live pass (2026-11-05),** display on, `gaiaqa`, debug build of `27b6d2df`, real Haiku and Codex
turns; item by item in `qa/GAIA_REMAINING_TESTS.md` §I.
- **A stopped drag leaves no button down: met.** Esc (3 of 3), Alt+Tab (3 of 3), phone Stop
  (3 of 3) and a covered end all let go. But the drag isn't undone: a trackbar stays where the
  drag reached, and the result says nothing was sent (BUG-359). Moving back to `from` and letting
  go at once doesn't give the app the move; a 40 ms wait between them does.
- **A password manager's copy is refused on read: met** (run later by Juno). A password copied
  from KeePass portable was refused as from an excluded app. That's the owner check: KeePass is
  on the default exclusion list, so whether it sets the private markings wasn't seen.
- `os_window` in Ask and Auto, `os_drag` in Ask, Auto and `os_steps`, an Explorer file drag (the
  10 moves are enough), and `os_clipboard`'s write, read-back, history, browser, and vault
  refusals all passed. Neither CLI picked write plus Ctrl+V over typing 1,488 characters.
- The live test: the drag stop test fails as BUG-359; the `os_window` test failed 2 of 5
  (BUG-360).
- Not run: an elevated window, a second monitor, `minimize` with the floater next behind.

**Fixes (2026-11-05):**
- **BUG-359:** `_releaseHeld` sends the move back, waits 50 ms, then lets go, and the result says
  the drag had begun. The live test's "stopped mid-drag" passed 6 of 6, the trackbar back at its
  start. Esc, Alt+Tab, phone Stop and a covered end weren't re-run in the app.
- **BUG-360:** `gaiaListWindows` walked the z-order with `GetWindow(GW_HWNDNEXT)`, describing each
  window as it went, so a window raised meanwhile (by a maximize) was skipped. It now takes the
  handles with `EnumWindows` first. The live `os_window` test passed 20 of 20 (the old code failed
  3 of 20). In the app, on Haiku in Auto, 3 of 3 turns ran `os_window` by id through maximize,
  move, maximize, minimize, move and close.

**Follow-ups (2026-11-05, later),** `gaiaqa`, debug build of `4433a197`, real Haiku and Codex turns:
- **BUG-359 in the app:** Esc (3 of 3), phone Stop (3 of 3, two of them in a later drag of a
  10-drag `os_steps`) and a covered end (1 of 1) each put the trackbar back where its drag started
  before the button came up. After Alt+Tab (3 of 3) it stays where the drag reached: losing the
  foreground ends the app's drag there, which a script with no Gaia shows too, so nothing can
  undo it. The result still said it was probably undone (BUG-361). Fixed: a drag whose window
  has lost the front at the release says part of it may have taken effect. Alt+Tab 3 of 3 with
  that text in the app; Esc unchanged.
- **`minimize` of the pinned window:** with Gaia's window next behind, it comes in front, nothing
  pauses, and the next `os_key` is refused with "There is no window to act on yet. os_open or
  os_focus one." in a turn of about 5 s. The floater, a topmost tool window, is never what Windows
  brings forward: the next app window is, and it adopts as Gaia's doing (here the emulator, which
  got the key).
- **An elevated window:** `os_focus` brings it in front, but `move` and `close` do nothing (UIPI)
  while each returns "Sent the step". The agent only learns by reading the screen.
- **The clipboard's browser rule** (as changed after review), 127.0.0.1 excluded: page text from
  127.0.0.1 with localhost showing, page text from localhost with 127.0.0.1 showing, and an
  address-bar copy of 127.0.0.1 with localhost showing were refused; page text and an address-bar
  copy from localhost were read. A copy from a text field carries no page, so it's refused while
  any site is excluded, even on an allowed site.
- Not run: a second monitor (skipped by decision).

## 12. Changes to GAIA_HLD.md when built

Applied for Phases 3 and 4, 2026-11-04, and §15.6's list of tools for Phase 5.

- **§5.2, §10.1:** in Auto, CLI prompts are answered without a card.
- **§12.2:** phone prompts act in Auto.
- **§15.6:** three modes; the step list is the boundary only in Ask; new tools; the target rule
  for Auto.
- **§15.7:** Esc's reach; add the latch and paused drain.
- **Phase 9C notes:** "Approving takes someone at the screen" stays true of Ask only.
- **§20:** the 2026-11-01 decisions on screen text and the phone get a dated amendment rather than
  a rewrite, keeping the reasoning for why Ask exists.
