# Gaia — AI Companion (HLD)

Gaia is Voyager's AI companion: a hotkey-summoned chat window that floats over
any app, runs the user's own AI agents (Claude, Codex, Gemini) on their own
logins, acts on Voyager data only after the user approves it in an editor, and
keeps one synced chat history across desktop and phone.

Named after ESA's Gaia spacecraft, the star mapper, to fit Voyager's theme.

Status: design draft (2026-10-24), with the first review's decisions folded
in. Phases 0 to 3 are done (Phase 3 checked live 2026-10-26, §19). Phase 4
is split in three: 4A (Gaia tools, reads, question and permission cards) is
done and checked live 2026-10-28; 4B (proposals and the action log) is
checked live 2026-10-29; 4C (a Codex adapter on `app-server`) is done and
checked live 2026-10-30, all but the `exec` fallback (§19). Phase 6 (text,
§9.5) is done and checked live 2026-10-31. Phase 7 (remote use) is built
and checked live 2026-10-31 on a desktop and an Android emulator; the push
notifications' Cloud Function is deployed, and pushes checked live (§19).
Phase 8A (usage) and 8B (accounts) are done; 8B's Claude path is checked live
2026-11-01 across two real logins, its Codex turn on a second account isn't
(§19). Phase 8C (low and exhausted) is done and checked live 2026-11-01 with
forced numbers; no real limit has been hit (§19). Phase 9A (`/this`) is built
and checked live 2026-11-02 (§19). Phase 9B (agent reads) is done and checked live
2026-11-02 (§19). Phase 9C (agent control) is done and checked live 2026-11-02 (§19).
**Gemini is skipped
completely for now** (2026-10-25): no Gemini CLI adapter and no Gemini API
utility model; the Gemini mentions below are the design for when it comes
back (§19). The windowing and process decision is in
`docs/adr/004-floater-windows-and-companion-process.md`, amended 2026-10-24 for
Gaia's data ownership (§3.2). Decisions and remaining questions are in §20.

---

## 1. Goals

- **Always one hotkey away**, over any app including Voyager itself, without
  hiding the app underneath.
- **A full chat client.** Long conversations with the user's agents, so the
  user doesn't need Claude Desktop, ChatGPT or the Gemini app.
- **Agent-agnostic.** Every feature works with any configured agent. Where an
  agent can't support something, Gaia degrades visibly instead of silently.
- **No new logins.** Agents run on credentials the user already has: the
  official `claude`, `codex` and `gemini` CLIs, or an API key where the
  provider offers one.
- **Approve before write, for Voyager data.** Gaia never changes Voyager data
  without the user's sign-off in an editor (§10), and never reads or controls
  the screen through its `os.*` tools without a per-chat grant (§15.6). Coding
  work in workspace chats runs under the user's own CLI permissions, exactly
  as it would in the CLI (§5.2).
- **One history everywhere.** Chats, memories, queues and settings sync
  through Voyager's Firebase project, and a dedicated **Gaia page** in Voyager
  shows them.

Non-goals for v1: push-to-talk (a later phase, §18) and macOS/Linux. Out of
scope entirely: proactive nudges, learned walkthroughs and guided pointing.

---

## 2. Glossary

| Term | Meaning |
|---|---|
| **Agent** | A configured model + adapter + account, e.g. "Opus 5.5 via Claude Code, account B". |
| **Adapter** | Code that drives one backend (Claude Code CLI, Codex CLI, Gemini CLI, Gemini API). |
| **Tier** | One of three user-defined slots that each point at an agent (§7). |
| **Beacon** | A desktop that runs prompts sent from other devices (§12). |
| **Proposal** | A typed draft of a Voyager change that waits in an editor for approval (§10). |
| **Gaia tools** | Gaia's own MCP server, which exposes Voyager actions, memory and OS actions to every agent (§5.3). |

---

## 3. Process and windowing — review of ADR 004

**Correction first:** ADR 004 does not choose `desktop_multi_window`. It
weighs it and picks a **separate companion process** instead: the same
`voyager.exe` launched with `--companion`. Gaia does not need
`desktop_multi_window`. A second process already gives it its own OS window
that can sit next to, or over, Voyager's main window.

### 3.1 What the ADR gets right

- The reasoning holds. Every `desktop_multi_window` window is its own engine
  and isolate, so it brings none of the "shared providers" benefit. It still
  needs IPC, plus per-engine plugin registration that `hotkey_manager`,
  `tray_manager` and `window_manager` handle badly. A second process costs
  about the same IPC and adds crash and stall isolation. A slow agent stream
  or a big image decode in Gaia can't cause jank in Voyager.
- **Same exe, not a second app.** Gaia can reuse Voyager's Dart code directly:
  the Vim engine (`lib/core/vim/`), snippets (`lib/core/snippets/`), theme,
  text widgets, the time selector and notifications. A separate project would
  have to fork all of it.
- Main instance owns hotkeys, Win32 FFI positioning,
  `WDA_EXCLUDEFROMCAPTURE`, and a profile-scoped mutex branch in `main.cpp`.
  All still right.
- `RegularWindowController` is still the long-term option for the floaters.
  The installed SDK has `_window.dart` (private, `@internal`), which matches
  the ADR's description.

I found no better alternative. An Electron or web UI would lose the code
reuse, and a Rust or C++ shell would mean building the UI twice.

### 3.2 What needs amending

1. **Data ownership vs. synced chats.** The ADR says chat history lives "in
   the companion's own storage (e.g. a separate SQLite file)". That was
   written before cross-device sync and the Gaia page were requirements. Now
   chats are Voyager data: the Gaia page lists them, the phone continues them,
   and they need the outbox, soft delete and trash like everything else.
   **Proposal:** Gaia's collections (chats, messages, memories, queue,
   settings) live in Voyager's drift DB and sync through the normal
   repositories. The companion reads and writes them over the named pipe,
   like any other command. This also avoids a second process opening the
   Firestore C++ SDK, whose on-disk cache is single-process.
   **Accepted 2026-10-24** and recorded as an amendment to ADR 004.
2. **Open question: resident or on-demand.** Resident. Background runs (§14)
   and beacon mode (§12) need the companion alive while its window is hidden.
   It hides, never exits, and Voyager's tray can quit it.
3. **Open question: Voyager not running.** Voyager is already tray-resident
   and owns every hotkey, so the hotkey only works while it runs. Launching
   `voyager.exe --companion` directly should start the main instance in the
   background first and then connect. There is no reduced mode.
4. **Who runs the agents.** The companion spawns and owns the agent child
   processes, and streams tokens to the main instance over the pipe for
   persistence and sync. If the companion crashes mid-run, that run is lost
   and its message is marked `interrupted`. That's acceptable for v1.
5. **Region capture needs no second window.** The main instance captures the
   screen first. The companion then grows to cover the monitor, shows the
   frozen frame, and lets the user crop (ShareX-style). The frozen frame also
   removes timing races with menus and tooltips that close when focus moves.
6. **Shell presence.** Covered in §3.3. Floaters are tool windows, kept out of
   Alt+Tab and the taskbar. The Gaia window is a normal app window and appears
   in both.
7. **Exclude-from-capture has a side effect.** `WDA_EXCLUDEFROMCAPTURE` also
   hides Gaia from the user's own screen shares and recordings. nus-desktop
   chose this deliberately. Gaia probably wants it too, but say so in
   settings.
8. **Pipe security.** The main instance creates the named pipe with a DACL
   for the current user's SID only, and checks each client with
   `GetNamedPipeClientProcessId`. It accepts only the companion PID it
   launched or found through the companion mutex. The companion's own pipe
   for the MCP shims (§5.3) accepts only the shim PIDs it spawned. Approval
   tokens (§10) are only as strong as these checks.
9. **Updates.** Both processes run the same exe, so an update restarts both.
   The update flow first asks the companion to drain. If runs are active, the
   user sees "Gaia has 1 run in progress" with Wait and Cancel. The companion
   then exits, the update installs, and both relaunch. A run cut off this way
   is marked `interrupted`, as after a crash.

### 3.3 Window modes

Gaia is floater-first. Its window has three modes:

| Mode | Shape | Topmost | Taskbar / Alt+Tab |
|---|---|---|---|
| **Small floater** | compact panel: composer and the full chat | yes | no (`WS_EX_TOOLWINDOW`) |
| **Large floater** | big centred panel showing the full chat | yes | no |
| **Gaia window** | normal resizable window with a chat sidebar, like Claude Desktop | no | yes (own taskbar button) |

- The Gaia window opens from the floater's expand button, the tray, the Gaia
  page in Voyager, or hotkey G (§15.1). If a floater is showing, it turns into
  the Gaia window rather than opening a second one. Closing it hides it. Runs continue
  (§14), and it never exits.
- **One window at a time** (accepted for v1). The companion is one Flutter engine, so it has
  one OS window, and the modes are states of that window. If the Gaia window
  is open and the user presses A or B, the window becomes that floater over
  the current app, in the same chat. The floater takes the window's place:
  dismissing it hides Gaia and gives the foreground back to the app the user
  was in before the Gaia window, the same as closing the window would. The
  window's placement is kept, so the next G puts it back where it was.
- Showing a floater *and* the Gaia window at once would need a second window:
  a third process, or Flutter's multi-window API once it's stable (ADR 004
  option 3). Not worth it for v1.
- Changing between tool-window and app-window styles needs a hide and re-show
  so the shell picks it up. That happens during the mode transition.
- **Grow first, then lay out.** While a resize call holds the engine's
  thread, the area a grow uncovers shows black until the next frame paints
  it. A transition to a larger mode resizes the window, waits for the frame
  at the new size, and only then builds the bigger layout. Building it in the
  same frame makes that frame slow enough for the black to show. Voyager's
  floaters already do this (`FloaterWindow.resize`, `todo_floater.dart`).
- Floaters open on the monitor under the cursor. Their stored size is in
  logical pixels, and they are re-clamped to the monitor's work area when the
  DPI changes (`WM_DPICHANGED`).

---

## 4. Architecture overview

```
 ┌──────────── voyager.exe (main) ────────────┐      ┌──────── voyager.exe --companion ────────┐
 │ hotkeys · tray · drift DB · Firebase sync  │ pipe │ chat UI · Vim/snippets · editors        │
 │ Gaia repositories (chats, memories, queue) │◄────►│ agent runner (spawns CLIs)              │
 │ action executor (approved proposals only)  │      │ Gaia tools (served to stdio MCP shims)  │
 │ selection/clipboard capture, screen grab   │      │ screenshot annotate · crop overlay      │
 └────────────────────────────────────────────┘      └───────┬─────────────────────────────────┘
          ▲ Firestore (chats, live stream, commands)         │ stdio JSONL
          ▼                                                  ▼
 Voyager Android (Gaia page = full chat client)      claude / codex / gemini CLIs, Gemini API
```

---

## 5. Agents and adapters

### 5.1 Recommendation: CLIs for everything, plus one direct API

Your instinct to wrap Claude Code is right, and it generalises. All three
vendors ship a headless CLI that authenticates through its official login,
streams JSONL, resumes sessions, and speaks MCP:

| Backend | Auth | Headless invocation | Resume |
|---|---|---|---|
| Claude Code | `claude` login (subscription) | `claude -p --input-format stream-json --output-format stream-json --verbose --include-partial-messages --model <m>` | `--resume <session>` |
| Codex | ChatGPT login (`codex login`) or API key | `codex app-server`, JSON-RPC on stdio (Phase 4C); `codex exec --json` with the prompt on stdin as the fallback | `thread/resume`; `codex exec resume <id>` |
| Gemini CLI (skipped for now) | Google login or API key | `gemini -p --output-format stream-json --model <m>` | `--resume <session>` |
| Gemini API (skipped for now) | AI Studio API key | direct HTTPS streaming | Gaia replays history |

Gaia's small internal jobs need fast answers: the tier router (§7.2), chat
titles, image captions for handoffs (§7.4), the memory curator (§11) and
compaction summaries. This **utility
model** is Haiku on the Claude Code CLI, on the same login as Gaia's Claude
chats, so it needs no API key (decided 2026-10-25, replacing the Gemini API
adapter first built for it). Each job is a fresh `claude -p --safe-mode
--tools "" --no-session-persistence` with a fixed system prompt, the job's
instructions and its input in the one message, so no job sees another's.

A CLI cold start takes about a second before the model is asked, so Gaia
starts the next job's process ahead of time when a new chat is opened (and
drops it after 5 idle minutes). A warm route measured 0.65–1.1 s on 2.1.310.
The router waits at most 5 s before the last used tier takes the message;
titles and summaries run after a reply, where a cold start doesn't matter.
With no utility model (Claude Code missing or logged out), Gaia degrades:
no auto-router (the last-used tier applies), titles come from the first line
of the first message, and the curator (§11) is off. The title job runs once,
on the chat's first reply to finish: a failed or stopped one doesn't count, and
a title the user has changed from that first line stays.

Lessons carried over from nus-desktop's `src/ai.js`:
- Strip `ANTHROPIC_API_KEY` (and the equivalent for the others) from the
  child environment, so a stray key never redirects subscription billing.
- On Windows the CLIs are often `.cmd` shims. Spawn through `cmd /c` and kill
  the whole tree with `taskkill /t /f` on cancel.
- Pin `--model` on every call. Never inherit the CLI's default.
- Run the child in a Gaia-owned working directory (`%APPDATA%\Voyager\gaia\ws`),
  so it never picks up an unrelated project's instruction file.

**Process lifecycle.** Each **active** chat has one long-lived process
(`--input-format stream-json` keeps stdin open across turns). It is killed
after 10 minutes idle and `--resume`d on the next message. At most about 4
live at once, with the least recently used evicted. Codex's `app-server`
is one process for every chat (a thread each, a turn per message), killed
after 10 minutes with no turn running. Where a CLI can't keep stdin open
(the `codex exec` fallback), each turn gets its own process.

**CLI output is fragile too.** The `stream-json`/`--json` event shapes change
between CLI releases, and the CLIs update themselves. Adapters get the §6.3
treatment:
- `lib/features/gaia/adapters/<cli>/` with a `// FRAGILE(cli):` header;
- contract tests against recorded fixtures of every known event shape;
- strict parsing;
- a tested version range checked at startup.

Outside the range the chat still runs, with an "untested CLI version" chip. A
parse failure puts the run into `error` and logs the raw line.

**Codex specifics (as built, 0.164.0).** On `app-server` replies stream
(Phase 4C); the `exec` fallback prints each agent message whole, so there
they appear a block at a time. Gaia's Codex home carries over one setting
from the user's config.toml, `[windows] sandbox`. Without it every shell
command is refused.
An elevated sandbox needs a one-time setup per Codex home, behind a Windows
approval prompt, and a headless run that hits the setup hangs on that
prompt. So the setup checklist has a **Set up** step that runs one trivial
sandboxed command while the user is watching. Until that's done, a Codex
turn fails at once and points there.

**Setup.** The Gaia page has a setup checklist. It runs `<cli> --version` and
a cheap auth probe for each CLI, then shows installed / logged in / version
status with the exact command to fix each. An agent can only be added once
its probe passes.

### 5.2 One instruction set: `GAIA.md`

You're right that this works. Each CLI loads its own global instruction file
(`~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`, `~/.gemini/GEMINI.md`), and Gaia
should replace those with its own synced `GAIA.md`, edited on the Gaia page:

- **Claude Code:** `--append-system-prompt` carries GAIA.md. Never
  `--system-prompt`, which replaces Claude Code's own system prompt and loses
  its tool guidance. Limit setting sources so the user's global CLAUDE.md
  isn't loaded.
  *Verified on 2.1.310:* `--setting-sources` does not keep the global
  CLAUDE.md out; `--safe-mode` does (it also drops hooks and plugins), and
  keeps the subscription login, unlike `--bare`. GAIA.md goes in with
  `--append-system-prompt-file`, since `cmd /c` would mangle multi-line text.
  Safe mode also disables MCP servers, `--mcp-config` stdio ones included
  (checked on 2.1.312), but not an `sdk` server that Gaia hosts itself over
  the stream-json control channel. That's how Claude Code gets Gaia's tools
  (§5.3, decided 2026-10-28). The alternative was dropping safe mode for
  `CLAUDE_CODE_DISABLE_CLAUDE_MDS=1`, which does keep CLAUDE.md out, but
  `--setting-sources ""` would also drop the user's permission mode, and
  `user` would bring their hooks and plugins back. Project settings still
  apply under safe mode.
  *Checked on 2.1.314 (2026-10-30):* a `--resume` keeps the system prompt
  the session started with and ignores a changed
  `--append-system-prompt-file`. So a GAIA.md edit reaches new Claude Code
  chats, but not chats resumed after it, even though their idle processes
  restart.
- **Codex:** one Gaia-owned `CODEX_HOME` per account
  (`%APPDATA%\Voyager\gaia\codex\<account>`, §6.1) with its own `AGENTS.md`
  and `config.toml`. `auth.json` is **copied**, not symlinked (symlinks need
  Developer Mode or admin rights on Windows), when the account is linked. It
  is copied again when Gaia sees an auth failure. When an account is removed,
  its server stops and this copy is deleted, on every device as settings reach
  it; the home's sessions stay. Settings with no Codex accounts stored delete
  nothing, as the last account can't be removed.
- **Gemini CLI:** `GEMINI_SYSTEM_MD` / a Gaia-owned settings dir.

**Workspace chats.** A chat can be bound to a project folder, chosen when the
chat is created and shown in its header. It runs with that folder as cwd and
loads what the CLI would load there:
- the project's CLAUDE.md / AGENTS.md / GEMINI.md;
- the user's global instruction file and CLI settings (hooks, permissions,
  plugins).

GAIA.md is still appended. So a workspace chat behaves like the CLI in that
repo, plus Gaia. **Permissions are the user's own:** the CLI's permission
settings and mode (Claude Code's Auto mode included) apply unchanged. File
edits, commands and launching the app run as they would in the CLI, from the
desktop or a remote prompt (§12.2). Only what the CLI itself would ask about
reaches Gaia, as a permission card through the permission-prompt tool (§5.3).
In a chat in Auto, Gaia allows it with no card and lists it on the turn's activity
card (GAIA_AUTONOMY_HLD.md §5.7).
Approve-before-write covers Voyager data (§10), not coding work.

A workspace binding stores a folder path **per device**, since paths differ
between machines. A device with no path for that chat refuses to run it, with
a message naming the device that has one.

`voyager.*` read tools are **off by default in workspace chats**, with a
per-chat toggle (§5.3).

### 5.3 Gaia tools: the agent-agnostic integration layer

Gaia's tools are one MCP server (`gaia`) with two transports, both handing
each JSON-RPC message to the same Dart handler (`lib/features/gaia/tools/`):

- **Claude Code:** in-process. Gaia is the process's SDK host. An `sdk`
  server in `--mcp-config` registers it through an `initialize` control
  request, and the CLI sends `mcp_message` requests on stdout that Gaia
  answers on stdin. Its permission prompts arrive on the same channel as
  `can_use_tool` requests (`--permission-prompt-tool stdio`). This is the
  Agent SDK's own protocol, undocumented, so it's FRAGILE with a fixture
  (`control.jsonl`) and a contract scenario like the event shapes (§5.1).
- **Codex:** client-hosted tools on `app-server` (Phase 4C): each thread
  is started with Gaia's tools as `dynamicTools`, and Codex sends each call
  as an `item/tool/call` request on the same stdio the companion already
  owns, so the call is bound to its run by which process and thread it came
  from. FRAGILE, with recorded fixtures and a contract scenario.
- **Codex on the `exec` fallback:** stdio. Its MCP config launches
  `voyager.exe --gaia-mcp`, a native byte relay (no engine, no window)
  between its stdio and the
  companion's tool pipe (`windows/runner/gaia_tool_pipe.cpp`), which is
  current-user only and rejects remote clients. Each shim is accepted only
  when a process the companion launched for a run is among its ancestors,
  and its calls are bound to that run. The shim takes no `--chat`/`--run`
  arguments, since an argument could be forged and the ancestry can't. The
  shim checks that the pipe's server is its own exe.

Nothing listens on a localhost port, so other local processes can't call
the tools, and every call is bound to its chat and run. Grants, Abort and
cards rely on that binding. Everything Gaia-specific is a tool, so every
agent gets the same capabilities without per-vendor code. Tool names carry
no dots (`ask_user`, `voyager_todos`), since the Messages API allows only
letters, digits, `_` and `-`:

- `voyager.*` — read tools (today's todos, a journal day, calendar range,
  workouts…) and **propose** tools (`propose_calendar_event`,
  `propose_todo`, `propose_workout_change`…). Propose tools never write
  (§10).
- `memory.search`, `memory.propose` (§11).
- `os.*` — screenshot, click, scroll, type, focused window (§15).
- `queue.*` (§13).
- **Permission prompts:** Claude Code's `--permission-prompt-tool` can point
  at a Gaia tool, so the CLI's own Bash/edit permission requests become Gaia
  UI approvals instead of silently failing in headless mode. Codex and Gemini
  get the closest equivalent their sandbox/approval settings offer.

All Gaia tools refuse with `aborted` while Abort is engaged (§15.7).

Voyager data returned by read tools is wrapped as **reference data, not
instructions** (nus-desktop's `profile-context.js` pattern), so a journal
entry that happens to contain "ignore previous instructions" is less likely
to steer the agent. This is a **mitigation, not a boundary**. Read tools have
no approval step, so an agent that has Bash or web access as well as
`voyager.*` reads could send Voyager data anywhere. That's why reads are off
by default in workspace chats (§5.2). The real boundary is that writes only
happen through approved proposals (§10).

Read tools never return content protected by `secure_vault`. They report that
it exists ("3 locked entries"), so the agent can say it can't see them.
Decrypted vault content never lands in synced chats.

---

## 6. Accounts and usage

### 6.1 Accounts

A Claude account is a `CLAUDE_CONFIG_DIR`. (Your Claude Code memory already
lives under `.claude-2`, so you probably run this setup today.) Gaia's agent
config gets an ordered list of **accounts**, the first being the default, and
the adapter sets the account's config dir per spawn. Gaia uses the account's
existing `CLAUDE_CONFIG_DIR`, with setting sources limited as in §5.2. Codex
gets a Gaia-owned `CODEX_HOME` per account (§5.2), and Gemini works the same
way.

The list lives in `gaia_settings`, synced, and is edited on the Setup tab: an
account's name, order and removal. Its folder is fixed once added, since its
sessions and a Codex account's home belong to that login: changing one means
adding the new folder and removing the old. Folders are set only on Gaia's own
spawns, so the user's terminal setup is untouched. The utility model follows
the current Claude account.

An adapter with none stored has one implied account, id `default`. Claude's
takes its folder from the older `claudeConfigDir` setting, which Phase 8B
replaces on the Setup tab and keeps only for this. Empty, Gaia uses whatever
Voyager was started with.

### 6.2 Usage sources

No vendor documents an API for subscription usage. Each provider gets a
`UsageSource` that produces one normalized shape, so the rest of Gaia never
knows which vendor it is looking at:

```
UsageWindow { kind: session | weekly | weeklyModel | daily,
              usedFraction, resetsAt?, observedAt }
```

| Provider | Source | Windows |
|---|---|---|
| Claude | `GET api.anthropic.com/api/oauth/usage` with the account's OAuth token from `<config dir>/.credentials.json` (undocumented) | 5-hour, weekly, weekly per model |
| Codex | `account/rateLimits/read` on `codex app-server` (confirmed in Phase 8A on 0.166.0: costs no tokens and works idle), plus `account/rateLimits/updated` during a turn. Both undocumented as a usage API. Gaia handles no token: the server calls on its home's login | by duration: 300 min (5-hour), 10080 min (weekly) |
| Gemini CLI (Google login) | the quota data behind `/stats` (an internal Code Assist endpoint, undocumented; confirm the call at phase start) | daily requests |
| Gemini API key | No usage endpoint exists. Gaia counts its own requests against the published free-tier limits, and a `429 RESOURCE_EXHAUSTED` marks the key exhausted. Shown as "estimate" in the UI. | daily / per-minute requests |

None of these costs tokens. Polling: Claude and Codex every 10 minutes per
account and after each run, only for an adapter that has an agent and an
installed CLI, and not while aborted. An account the last read called signed out
is read again as soon as its login check on the Setup tab finds a login. Gemini
after each run. A Codex read uses
the process turns use, so the home's login has one owner; a process started
just for a read goes straight after it, so idle polling leaves no server
running.

**Usage rings under the composer.** The row under the composer shows the
chat's context, then a small usage ring per account, then the tier picker.
Each ring fills to the account's 5-hour window, and its tooltip lists every
window with its reset. The rings are for the next message's agent: one per
account that agent's adapter has, in account order. The account the next
message runs on is drawn at full strength; the others are dulled, so a
glance shows which account is in use and whether another has headroom.
Clicking a dulled ring switches to that account, the same as the account item
in the composer's notch (§6.5).

As of Phase 2 there is one account per adapter, so there is one ring, for
Claude only. It reads the `rate_limit_event` Claude Code prints during a
run (`unifiedWindows.five_hour` / `seven_day`, observed on 2.1.310), kept in
memory per adapter and cleared when the config dir changes. Phase 8A adds a
Codex ring (§19). Phase 8B adds a ring per account, the dulled inactive ones fed by the polled
sources above (a passive source only covers the account that just ran). An
inactive account with no numbers keeps a dulled empty ring whose tooltip says
why. The active one with none says "Usage untracked", as before.

Because the Phase 2 ring only fills from a run, it's missing until the first
message after the companion starts. **Phase 8A must fix this:** the Claude
`oauth/usage` source above is read when the companion starts and every 10
minutes, so the ring shows from launch. It follows §6.3 (fixtures, strict
parsing) and §6.4 (endpoint broken vs. signed out) like any other source.

### 6.3 Fragile endpoints in code

- Every undocumented source lives in one folder,
  `lib/features/gaia/usage/sources/`, one file per source. Each file opens
  with a `// FRAGILE(usage):` header stating what the source is, that it is
  undocumented, the date its shape was last observed, and every response
  shape it parses. Claude's, for example, has had both flat
  `five_hour`/`seven_day` keys and a newer `limits` array.
- URLs and headers are constants. There is **no setting, env var or dev flag
  to override them**. The only fix for a changed endpoint is a Gaia update.
- Parsing is strict. A missing field, wrong type or unknown structure is a
  schema failure, never a silent zero.
- Each source has contract tests against recorded fixtures of every known
  shape, plus an unknown-shape fixture that must classify as
  `endpointChanged`.

### 6.4 Endpoint broken vs. account problem

Every read ends in one state, shown on the Gaia page beside that account:

| State | Trigger | User sees |
|---|---|---|
| `ok` | parsed | the usage bars |
| `endpointChanged` | 404/410, non-JSON, schema failure; or 401/403 while the same account's agent runs are succeeding | "Gaia's Claude usage reader no longer matches Anthropic's endpoint. This is a Gaia issue, not your account: your account is working. Claude usage isn't tracked until Gaia is updated." |
| `signedOut` | 401/403 **and** the account's agent runs also fail auth | "Account B is signed out. Log in to `claude` for that account." |
| `stale` | token expired on an account that hasn't run lately | "Not checked since 2:14 PM. Refreshes next time this account runs." |
| `offline` | network error | quiet retry, "offline" chip |

Two details:
- The account-vs-endpoint call is made by comparing with the account's own
  agent runs. A usage endpoint returning 401 while `claude -p` on the same
  token works means the endpoint changed (e.g. a new required header), not
  the login.
- `endpointChanged` writes the response's *shape* (keys and types only, never
  the token or values) to the Gaia log, so the fix is quick.

While a source isn't `ok`, the chat says that account's usage is
**untracked** rather than showing old numbers as current. §6.5 then relies on
run errors alone: a rate-limit error still marks the account exhausted.

Decided in Phase 8A, where the table leaves it open:
- A 401/403 with no run to compare with (none since the companion started) is
  `stale`: nothing yet says which side is wrong.
- A run that worked counts as the comparison for an hour. Past that there's
  no run to compare with, since the login may have lapsed since.
- A 429 or 5xx is `offline`, since neither says the endpoint changed.
- An `offline` read keeps numbers under 30 minutes old on the ring, with no
  chip. A blip, or the endpoint's own rate limit, shouldn't take the ring away.
- Gaia never refreshes a Claude token, since the CLI owns it. An expired one
  makes no call and is `stale` until the account's next run writes a new one.

### 6.5 Low and exhausted

**Gaia never switches accounts or models automatically.** It warns and
offers what the user has configured, and the user decides. The cards present
these as the user's configured alternatives, not as a way around a
provider's limits.

An account is **low** when any window crosses its floor:
- weekly remaining < `weeklyFloor` (default 5%)
- session remaining < `sessionFloor` (default 10%) **and** its reset is more
  than `minWait` (default 45 min) away
- daily remaining < `dailyFloor` (default 10%)

It is **exhausted** when a window reads 100%, or a run fails with the
provider's rate-limit error.

**Low:** a non-blocking banner in every chat using that agent: "Sonnet 5.5
(account A) is low: 7% of the 5-hour limit left, resets 4:10 PM." If the
agent has another account that isn't low, the banner has a **Switch to
account B** button.

**Exhausted:** the composer is replaced by a decision card. The partial
answer of an interrupted run is kept and marked. The card offers the first
case that applies:
1. **Another account for the same agent** with headroom: "Switch to account B".
2. Otherwise, **every other tier whose provider differs** from this agent's
   and isn't exhausted. With Quick = Gemini, Standard = Sonnet, Deep = Opus
   and Sonnet out, only Quick (Gemini) is offered. Opus is the same provider
   and isn't.
3. Otherwise (all tiers on one provider, or the alternatives are out too):
   "Usage has run out", with each of this provider's accounts that's out on a
   line of its own, soonest reset first ("Account A resets at 6:40 PM"). Case 2
   lists them the same way when no account is left. With one account, it's that
   account's reset.

The first option is highlighted. **Ctrl+Enter accepts it**, a click picks any
option, and Esc dismisses. The card carries the context size and cache
warning from §7.5, since an account switch loses the prompt cache too, so it
replaces that confirmation rather than adding a second one. A "resend my last
message" checkbox, on by default, resubmits the prompt the interrupted run was
answering.

**Context across an account switch:** Claude Code stores each session as
JSONL under `<config dir>/projects/<cwd-slug>/<session>.jsonl`. Gaia copies
that file into the other account's config dir and `--resume`s it there. Codex
sessions (`<CODEX_HOME>/sessions`) are copied the same way. The chat shows a
"switched to account B" divider before the prompt whose reply moved.

**The manual switch (Phase 8B, decided 2026-11-01).** The current account is
**per adapter and sticky**, not per chat: `currentAccounts` in `gaia_settings`,
synced. New chats start on it, and other chats move on their next message,
each with its own copy and divider. So one switch gets every chat off a low
account, and 8C's banner and card need no per-chat state. The cost is that a
chat the user didn't touch loses its prompt cache on its next message, which
the confirmation says. It's picked from an account item beside the tier in the
composer's notch, shown once the adapter has two accounts, or by clicking the
account's usage ring. Either item opens one panel, the accounts above the tiers,
side by side when there are two and listed when there are more, and a pick
closes it. It asks first when
the current chat has a reply, with the §7.5 wording. A run already going
finishes on the account it started on.

---

## 7. Tiers and routing

### 7.1 Naming

The tiers are **Quick / Standard / Deep**, with commands `/quick`, `/std` and
`/deep`. The name describes how much model you want, not how hard the prompt
is.

Each tier points at an agent (model + adapter + account). Your setup, for
example: Quick = Gemini 3.6 Flash, Standard = Sonnet 5.5, Deep = Opus 5.5.

### 7.2 Which tier answers

Precedence, highest first:
1. **Inline command** (`/deep` typed anywhere in the box).
2. **Tier picker** clicked for this message.
3. **The chat's current tier.** A chat keeps the tier it last used.
4. **Auto-router**, only for the first message of a new chat when auto is on.
   The utility model classifies the prompt in about a second, using a GAIA-owned
   rubric the user can edit. The picker shows this as **Auto** (also offered in
   its menu, to undo a pick): its glyph runs through the tiers, faster once
   sent, then settles into the tier the router picked as the notch flashes.
5. **Last used tier globally** (new chat, auto off).

Why the router only picks the first message and doesn't re-route every
message: switching models mid-chat throws away the prompt cache, and a
**cross-vendor** switch needs a handoff (§7.4). Per-message routing would make
long chats slower, more expensive and jumpy. **After the first message, Gaia
never changes a chat's tier on its own.** Only the user does, through §7.3 or
the picker, and usage cards only offer (§6.5).

### 7.3 Inline tier commands

When `/quick`, `/std` or `/deep` appears as a whole token (start of text or
after whitespace), it is removed and the tier switches with a brief chip
flash. One adjustment to "immediately": fire when the token is **completed**
(the next space, or Enter) rather than on the last letter. Otherwise `/deep`
would fire inside `/deeplearning/notes.txt`. Tokens inside backticks or code
fences never fire. This runs on the same trigger machinery as snippets (§9.2).

Before the chat's first reply, the switch is silent. After it, the switch goes
through the confirmation in §7.5. The command works at any point in the chat.

### 7.4 Same vendor vs. cross vendor

- **Same CLI** (Sonnet → Opus): `--resume` the same session with a different
  `--model`. Full fidelity.
- **Cross vendor** (Gemini → Claude): the new agent gets a **handoff
  preamble**. That's a Gaia-rendered transcript of recent turns plus a
  utility-model summary of older ones. Tool-call internals of the other vendor
  don't carry over, which is lossy but honest, and Gaia shows a divider before
  the prompt whose reply moved.
  Images don't go in as images. Each goes as a utility-model caption plus
  the path of its local file, which the agent opens with its own file or
  image tool when the caption isn't enough (Phase 3 as built, §19).
  Each chat tracks native sessions per device, adapter and account
  (`agentSessions` in §8), so switching back resumes the original session.
  The default account's key stays `<device>/<adapter>`, and another's is
  `<device>/<adapter>/<account>`, so entries from before accounts need no
  migration and an older build still reads them.
- **Catching a session up.** A native session lives on the machine that ran
  it, and only knows the turns it took part in. Every resume compares the
  session's `lastSeq` with the chat's head. Turns in between come from:
  - another vendor,
  - the phone's API-key turns, or
  - another device.

  They are injected as a **delta preamble**, rendered the same way as the
  handoff. A device with no session for that adapter and account starts a new
  native session from a full handoff preamble.

### 7.5 Switch confirmation

Any tier change after a chat's first reply (`/deep `, the tier picker,
regenerate-on-another-tier) asks first:

> Switch from **Standard** (Sonnet 5.5) to **Deep** (Opus 5.5)?
> The prompt cache is lost, so the next message re-reads the whole context and
> uses extra tokens.
> Current context: **142k** tokens (auto-compact at 200k).

A cross-vendor switch adds: "Only a transcript and summary carry over to
Claude. Gemini's tool history doesn't." Ctrl+Enter confirms. Esc cancels and
keeps the current tier. The `/deep` token is removed from the draft either way.
The §6.5 exhausted card includes this same information and replaces this
dialog, so the user never sees two.

---

## 8. Data model and sync

All collections are under `users/{uid}/`, mirrored in drift, and synced
through the normal outbox. Messages are **immutable once complete**, apart
from soft delete, and need no op-log CRDT. They follow the snapshot path.
Branches (§18) are sibling messages sharing a `parentId`, and the chat's
`activeLeafId` picks which one is shown.

| Collection | Doc | Key fields |
|---|---|---|
| `gaia_chats` | one per chat | title, tier, workspace? {deviceId → path}, `agentSessions` {deviceId+adapter+account → {sessionId, lastSeq}}, `runLease` {deviceId, runId, expiresAt}?, activeLeafId, grants {deviceId → {seeScreen, canControl, at}}, drain, approvalMode, voyagerReads, pinned, lastMessageAt, deletedAt |
| `gaia_messages` | one per message | chatId, seq, parentId, role, `parts[]`, agent, model, account, usage {in, out, cacheRead}, status (`streaming`/`complete`/`error`/`cancelled`/`interrupted`/`aborted`), needsInput, compactionBoundary? |
| `gaia_message_chunks` | overflow only | messageId, n, text |
| `gaia_live` | one per chat while streaming | messageId, text so far, seq, updatedAt |
| `gaia_commands` | remote → beacon | type, chatId, payload, fromDevice, targetDevice?, signature, claimedBy, status |
| `gaia_beacons` | one per desktop | deviceId, heartbeatAt, accounts, capabilities, beaconMode, watchers [{deviceId, chatId, expiresAt}] |
| `gaia_devices` | one per paired device | deviceId, publicKey, fcmToken?, pairedAt, revokedAt? |
| `gaia_revoked` | one per revoked key, only ever added to | publicKey, revokedAt |
| `gaia_notify` | one per notification | chatId, kind (`done`/`question`/`card`), text, createdAt |
| `gaia_queue` | queued prompt | chatId (null = global), text, order, consumedAt |
| `gaia_memories` | one per memory | text, tags, links, sourceChatId, status (`proposed`/`active`/`archived`) |
| `gaia_settings` | singleton | tiers, agents, accounts, currentAccounts {adapter → account id}, GAIA.md, commands, keybinds, auto-compact, thresholds |

**Your doc-size concern:** one document per message, linked by `chatId` +
`seq`, which is what you suggested. A message over about 800 KB (≈200k
tokens of text, which is rare outside tool output) spills into
`gaia_message_chunks`. **Images never go in documents.** They become media
assets through Voyager's media module (`users/{uid}/media/{hash}` in
Storage, which `storage.rules` already allows), and a part holds the asset
id. That reuses the module's dedupe and GC with no rule change. Large tool
outputs are truncated in the synced copy, with the full text kept in the local
CLI session.

**Fields worth spelling out:**
- **`runLease`.** Only one device runs a chat at a time. The lease is taken
  in a transaction and renewed with the heartbeat. A send from another device
  goes into the chat's queue (§13) with a "running on Laptop" chip. Only the
  lease holder assigns `seq`.
- **`grants`.** Grants sync, but only apply on the device that gave them, so a
  phone can't grant screen control on the laptop. Each device's entry merges on
  its own, newest `at` first, and a revoked one is kept, off: the chat's document
  is last-write-wins as a whole, so a stale copy would otherwise turn a revoked
  grant back on.
- **Cards** (proposals, questions, permissions; §10) are a message part
  `card {kind, payload, state: open|accepted|rejected|voided|expired,
  decidedBy}`. So they survive a companion restart and render on the phone.

**Cleanup.** A chat purged from the trash (30 days) drops its media
references, and media GC collects the blobs. Each device deletes its own
local CLI session files for that chat on its next sync. The Gaia page shows
local session disk use (§17).

### 8.1 Live streaming: Firestore, not Realtime Database

I'd drop Realtime Database for now. **FlutterFire's `firebase_database` has
no Windows support** (only core, auth, firestore and storage got the Windows
C++ SDK). You'd be driving RTDB's REST/SSE API by hand. Firestore handles this
fine:

- The streaming device writes `gaia_live/{chatId}` **only while another
  device is watching that chat**. Watchers register in the beacon's
  `watchers` list with an `expiresAt` 60 s out, and renew it while the chat is
  visible. The streaming side ignores expired entries, so a killed phone app
  stops live writes within a minute. Nobody watching means zero live writes.
  A device that starts watching mid-run gets one catch-up write with all the
  text so far, then increments.
- On completion, the final message lands in `gaia_messages` and the live doc
  is deleted.

**Long agent turns.** A coding turn can run for an hour, mostly tool calls.
Live writes are driven by events, not by the clock:
- **Only the agent's text and one status line stream.** Tool calls, commands
  and their output never go into the live doc.
- **Text:** while a text block is being written, writes are throttled to at
  most one per second. A short block is 1–3 writes, and nothing is written
  between blocks.
- **Status line:** "Working · 37 tool calls · 12 min" plus the current tool's
  name (`Bash`, `Edit`). It updates at most every 30 s while tools run, so a
  phone watching a long tool phase isn't silent for 20 minutes, without
  showing any command content. A setting turns it off for completely silent
  tool phases.
- **Final message:** the text blocks in order. Each run of tool calls between
  them is collapsed into an **activity part**: "Ran 14 commands, edited 3
  files", with tool names and one-line labels (a command cut at 120
  characters), never outputs. Hour-long turns stay far below 1 MB, and the
  history on the phone reads like the conversation. The full tool log stays
  in the CLI session on the machine that ran it, where Gaia can expand an
  activity part into full detail.

An hour-long coding turn watched the whole time costs about 20 text blocks ×
5 writes plus 120 status updates, ≈ **220 writes**. A flat one write per
second would be 3,600.

RTDB via REST stays a fallback if live costs ever matter.

### 8.2 Cost estimate

Free quota, per day: 50k reads, 20k writes, 20k deletes, 1 GiB stored, plus
10 GiB/month outbound. Above it, Standard edition costs roughly $0.09–0.18 per
100k writes and $0.03–0.06 per 100k reads, depending on location. The figures
below use the high end.

A heavy day:

| Item | Writes/day | Reads/day |
|---|---|---|
| Live streaming: 150 chat answers × 40 s, every one watched from another device | 6,000 | 6,000 (the watcher) |
| Coding runs: 8 hours of agent turns, all watched (§8.1 filtering) | ~1,800 | ~1,800 |
| Final messages and chat updates | ~450 | ~450 per other device |
| Beacon heartbeats: 2 beacons, every 2 min | 1,440 | only while the phone has the Gaia page open |
| Commands, queue, memories, settings | ~200 | ~400 |
| **Gaia total** | **≈10k** | **≈9k** |

That's about half the free write quota on a heavy day. Without §8.1's
filtering, the 8 coding hours alone would be ~29k writes, which is over the
free tier by itself. Most days nothing is
watched remotely, so live writes are zero. Voyager's existing sync shares the
same quota. Even if the two together ran 15k writes/day *over* the free tier
every day, the bill would be 450k × $0.18/100k ≈ **$0.80/month**.

Reaching $10/month would take about 5.5M billable writes a month, around 185k
a day: roughly 50 hours of watched streaming per day.

Storage: message text is a few MB a month. Screenshots go to Cloud Storage
(~300 KB each, so 20 a day ≈ 180 MB/month). That fits the free 5 GB for about
two years, then costs ~$0.03/GB-month.

**Expected: $0. Ceiling: about $1.** The real risk is a bug, such as a write
loop or a listener re-attaching every frame, not normal use. So:
- set a GCP budget alert at $2 and $5;
- the companion counts Gaia's writes per day and stops live streaming past
  15k. Final messages still sync, and a chip says live view is paused.

---

## 9. Composer

### 9.1 Keys and Vim

The composer is a Voyager text field, so it can reuse **Voyager's existing
Vim engine and snippets** (the same-exe payoff from §3.1). Keybinds are
customizable on the Gaia page. Defaults: Ctrl+Enter sends, Enter/Shift+Enter
make a newline (matching `CTRL_ENTER_SUBMIT_HLD.md`), Esc in Vim insert mode
drops to Normal, and Esc in Normal hides Gaia.

**Correction (2026-10-31): Vim and snippets didn't work in the composer
until Phase 6**, which wired it to both engines (§9.5, §19).

**Changed (2026-10-31): a text box eats Esc.** In the composer (or any other
text box) Esc never hides a floater: in Insert it drops to Normal, in Normal it
stays there, and without Vim it does nothing. Esc hides a floater only with no
text box focused.

As built in Phase 2: Send (Ctrl+Enter by default, decided 2026-10-25 over
Phase 1's Enter) and the A, B, G and Abort hotkeys are rebindable on the
Gaia page and sync with Gaia's settings. A global hotkey needs Ctrl, Alt or
Win, so it never takes over plain typing, and two keys can't share a combo.
The main instance re-registers a hotkey as soon as it changes.

### 9.2 Custom commands — two kinds

- **Snippets** (expand instantly as you type). These are already built
  (`SNIPPET.md`). Gaia just honours the user's existing snippets, plus an
  optional Gaia-only scope.
- **Slash commands** (expand on send). `/name args` becomes a stored template
  with `$ARGUMENTS`, `$1`, `$CLIPBOARD`, `$SELECTION`, `$DATE`. A command
  marked *standalone* sends immediately when picked from the palette.

Built-ins: `/quick /std /deep`, `/new`, `/compact`, `/account`, `/remember`,
`/queue`, `/queue-pop`, `/stop`, `/this` (§15.5). Typing `/` opens a fuzzy palette.

As built in Phase 2: `/quick /std /deep`, `/new` and `/stop`, which still
works while a reply is running. The other built-ins arrive with their
phases. A message is stored as its expansion, since that's what the agent
saw. Phase 3 added `$SELECTION`: the text selected where Gaia was last
summoned from, read through UI Automation at the summon (§15.2).

As built (2026-10-28): the palette follows the caret, so a `/word` anywhere
in the draft (a whole token, not in code) opens it. Built-ins and tiers can
be picked there, the `/word` taken out of the draft; the user's commands
only when the `/word` is the whole draft, since they take the rest as
arguments. `/new` takes what's left of the draft into the new chat, as
Ctrl+Shift+N does (§9.3).

As built (2026-11-01): an account can have an alias, set on the Setup tab, and
`/alias` switches to it through the same flow as the picker (§6.5), asking
first once the chat has a reply. It works like a tier command: from the palette
anywhere in the draft, or inline once completed. Inline it always asks, since a
user-chosen name can be ordinary text (`/tmp`): it comes out of the draft only
on a yes, a word turned down isn't asked about again while the draft holds it,
and the alias of the account already current stays as written. Aliases share one
namespace across adapters, with the built-ins and the user's commands, and name
an account whichever adapter the next message is on. An alias for another
adapter switches that adapter and leaves this chat's next message where it is,
which the dialog says, without the cache warning; the palette names each alias's
CLI. A name typed in full comes first in the palette, so a short alias isn't
lost under a longer command.

### 9.3 Attachments and the "[image N]" question

**Does placement matter?** Somewhat. The Messages API takes an **ordered**
list of content blocks, so text and images can interleave and the model sees
that order. Claude Desktop just doesn't expose it. The bigger win, though, is
**labels**: "compare [image 1] with [image 2]" is unambiguous even when both
images come first.

So Gaia stores a message as ordered `parts`, shows each attachment as an
inline chip `[image 1]` where it was pasted (with the thumbnail strip above),
and each adapter sends it the best way it can:
- Claude Code stream-json input accepts content blocks, so parts go
  **interleaved**, each image preceded by its label text.
- Codex (`-i` files) and Gemini CLI (`@path`) attach separately, and the text
  keeps the `[image N]` labels so references still resolve.

As built (2026-10-27): the composer's **+** (a notch like the tier picker's,
opening rightwards) adds files or a folder. A picked image joins as an
image; anything else, PDFs included, goes **by path**, shown as a card with
its name and type beside the images. Files get no `[file N]` token: the
user names one as they would to a person, by its name. Nothing is copied or
synced, so a file is only readable on the device it was attached from. The
agent gets an `<attached_files>` list of paths after the message and reads
them with its own tools. Claude Code is started with `--add-dir` for each
file's folder in the chat (outside reads are refused in `-p` under the
default permission mode); a new one restarts the process, resuming the
session. Codex's sandboxes read anywhere already. The grant is the whole
folder, for the rest of the chat: attaching `Downloads\invoice.pdf` lets the
agent read all of Downloads. Accepted (2026-10-27): the user pointed Gaia
there, and a copy per chat would cut the agent off from the file itself.
Only PNG, JPEG and WebP join as images; GIF, BMP and HEIC go by path, as
ingest refuses the first two and Windows may not decode the third.
A part from a newer build is kept unshown and written back as it came
(`GaiaUnknownPart`), so an older build that captions the message doesn't
strip it.

As built (2026-10-28): right-clicking a message offers **Attach as
context**, which puts it on the draft as a quote chip beside the window's
(§15.4). Several can be attached, from any chat; they stay on the draft
when the chat changes. Each is copied into the message as a `quote` part
(its text and who wrote it, not its images), shown as a chip on the sent
message, and goes to the agent as a `<quoted_message>` block ahead of the
prompt, framed as context (§5.3). Handoffs carry it as a `Quoted (…)` line.
**Copy code** copies a message's fenced ```` ``` ```` blocks, a blank line
between them; it appears only when there are some. Messages are shown as
plain text, so there is no per-block copy button yet, and inline code isn't
counted. Phase 6 added the per-block copy button and inline code with
Markdown rendering (§9.5); Copy code stays in the menu.

As built (2026-10-28): **each chat has its own draft**: its text (caret
included), images and files are put away when another chat comes into view
and come back with it, and "New chat" has one of its own. A send that fails
after the user has moved on goes back in its own chat's draft. Ctrl+N starts
a new chat; **Ctrl+Shift+N, or Shift-clicking New chat, moves the draft in
view into it**, after New chat's own draft, its images renumbered on from
that draft's (not while any are still syncing). The quote
chips and the window chip stay with the composer, as above, and aren't kept.
Drafts carry across the floaters and the Gaia window, and are **kept and
synced**: the companion saves a changed draft at most once a second through
the main instance into `gaia_drafts` (one record per chat, `new` for "New
chat"), which syncs and backs up like any other collection. The last save
wins: a draft another device saved replaces this one's unless this one has
changed since. A draft image is taken into the media module when attached,
not when sent, and is referenced by its draft (owner `gaia_drafts`), so it
uploads and syncs; a draft holds its asset id, `[image N]` and edits, and a
device without the bytes downloads them, waiting up to two minutes before
letting that image go: it stays in the kept draft, for the device that has
it, but isn't shown, and its `[image N]` comes out of the text when the
draft is sent from here. A chat's draft is deleted with it and restored with
it, and a draft saved empty is kept deleted. Meanwhile the composer shows it as a placeholder tile
with a "Syncing" spinner and its `[image N]`, which can be removed, and a send
is held with a toast naming the images still on their way. Files and folders sync as paths, which only mean
something on the device that attached them. After a restart the drafts and
their images come back from the store.

### 9.4 Annotation

Clicking a thumbnail opens an editor with pen, line, arrow, rectangle,
ellipse, highlighter (multiply blend), blur/redact box, crop and undo, all
drawn as vector ops over the image. The PNG is flattened on send, and the
original is kept so it can be re-edited.

### 9.5 Text: Markdown, spellcheck, Vim and snippets (Phase 6)

- **Markdown rendering.** Messages render as Markdown, with syntax
  highlighting in fenced code blocks, a copy button per block, and inline
  code styled (§9.3). Desktop, the Gaia page and the phone client (Phase 7)
  share one renderer, so a message looks the same everywhere.
- **Selection survives rendering.** Part of a rendered message can be
  selected and copied, across paragraphs and code blocks, not just whole
  messages or whole blocks.
- **Streaming.** A reply renders as Markdown while it streams. An unclosed
  fence or list shows sensibly until it closes, and a chunk doesn't rebuild
  the whole message (the per-chunk stutter fixed 2026-10-29, §19).
- **Links.** A URL or file path in a message is clickable. URLs open in the
  default browser (http and https only, since the text comes from the
  agent). A folder opens in Explorer. A file opens in its default app only if
  its type is on a list that runs nothing when opened; any other file,
  programs and scripts included, is shown selected in Explorer instead. A path
  that doesn't exist on this device, such as a desktop path seen on the
  phone, isn't a link.
- **Spellcheck and autocorrect** in the composer reuse Voyager's
  (`lib/core/spellcheck/`). They skip code spans and fences, `/commands`,
  `[image N]` labels, file paths and URLs.
- **Vim and snippets** in the composer reuse Voyager's engines (§9.1).
- **Settings reach the companion.** The composer runs in the companion
  process (§3), so the user's dictionary words, snippets, and the Vim and
  autocorrect toggles have to get there from the main instance and stay
  current when they change.

### 9.6 Stop gives the message back (added 2026-11-05)

Stop before anything shows takes the message back: it and its empty reply
come off the chat, and its text, images, files, quotes and window go back
in the composer, as other chat apps do. A new chat with only that message
goes with it. That happens only when nothing showed (no text, tool or card),
and only when the composer is still empty, so nothing typed since is
overwritten. Otherwise the message stays in the chat with a cancelled
reply, as before. A message sent from the phone, an abort or an update
drain keep it too.

The agent's session already has the message by then, so it's taken out of
the session first (`GaiaAgentRunner.takeBack`). If that can't be done, the
message stays in the chat, with a toast saying why. It runs once the chat
has stopped, so Stop doesn't wait on it; a send to the chat meanwhile waits
for it. If something was typed or sent meanwhile, the message stays in the
chat with a toast saying the session no longer has it. The chat and the
session never disagree in the direction that matters: the chat never drops
a message the agent still remembers. A new session that was never saved
for the chat needs nothing taken out. The main instance erases both
messages, and a new chat, as the trash's "Delete forever" does (§8), so
nothing lands in the trash.

- **Claude Code** has no documented way to drop a turn. Gaia uses two flags
  `claude --help` hides, found in the CLI's own source and checked on
  2.1.318. `--resume-session-at <entry uuid>` resumes the session only up to
  that JSONL entry, so the next prompt branches from it, and later plain
  resumes follow the branch. `--resume-drops-turn <prompt uuid>` makes that
  resume refuse (an error result, then exit) unless all it cuts is that
  prompt's turn. Gaia gives each prompt a `uuid` on stdin, finds it in the
  session JSONL after the stop, and cuts at its `parentUuid`. Since the
  flags are undocumented, each step is checked rather than trusted:
  - Before the message goes back, a resume with the flags is started and
    must answer `initialize`. A CLI that doesn't know the flags fails at once
    (`unknown option`), and so does one whose guard refuses. Either way the
    message stays, with the CLI's own words in the toast. A prompt saved
    under some other id fails the same way.
  - The cut is kept on disk (`claude-rewinds.json` beside GAIA.md) until the
    chat's next Claude Code turn has its prompt in the session JSONL, so a
    companion restart, or a turn stopped before its prompt was saved, doesn't
    lose it.
  - If that turn's resume gets no session (the cut refused, say as the
    session changed elsewhere since it was checked), the cut is dropped and
    the turn runs once more as a plain resume, with a toast that Claude Code
    may still remember the stopped message.
  - After that turn, its prompt's JSONL entry must hang off the kept entry.
    If it doesn't, a toast says Claude Code may still remember the stopped
    message, because the undocumented flag didn't behave as expected.

  `gaia_cli_contract_test.dart` checks all of this against the installed
  CLI (`qa/harness/gaia_cli_check.ps1`).
- **Codex** uses `thread/revert {threadId, beforeTurnId}` on `app-server`,
  in its published (experimental) schema. It's sent once the interrupted
  turn's `turn/completed` arrives. A refusal keeps the message. A turn that
  went to the `codex exec` fallback can't be reverted, so it stays.

---

## 10. Blocking cards: proposals and questions

Flow for "schedule a meeting with my dentist for 2 PM Thursday":

1. The agent calls `voyager.propose_calendar_event({...})`.
2. The tool call **blocks** while Gaia renders a **proposal card** inline in
   the chat. It's a real editor (the same field widgets Voyager uses), with
   lookups such as calendars or workout plans fetched over the pipe.
3. The user either:
   - presses **Ctrl+Enter** to accept as-is or after editing fields, and the
     main instance commits it through the normal repository (outbox, sync,
     live UI); or
   - **types a correction** in the composer ("make it 3 PM"). The tool returns
     `rejected: user wants changes: …` and the agent re-proposes, replacing
     the card; or
   - presses **Esc / Reject**.
4. The tool result tells the agent exactly what was committed, including the
   user's edits, so its next reply is accurate.

Rules:
- There is no write tool. Only `propose_*` exists, and the executor in the
  main instance accepts only proposals carrying an approval token issued by
  the companion UI.
- **Approving from the phone.** The phone writes an `answer` command with the
  card id and the edited payload. The beacon's companion validates it, issues
  the token, and the main instance commits. The phone never commits a
  proposal directly. If the beacon is offline, the card shows "waiting for
  Laptop" and stays open.
- Every Gaia-committed row gets `origin: gaia` (precedent:
  `FINANCE_TRANSACTION_ORIGIN_HLD.md`), so the trash, undo and the Gaia
  page's action log can show and reverse it.
- Several proposals in one turn stack as cards, each with its own Ctrl+Enter,
  plus "accept all".
- Long-blocking tools need the CLI's MCP tool timeout raised (Claude Code:
  `MCP_TOOL_TIMEOUT`). Past that, the tool returns `pending:<id>` and the
  decision arrives as the next user turn.
- On the phone, the same cards appear in Voyager's Gaia page, including for
  proposals a beacon run produced.

### 10.1 Agent questions

Agents stop to ask in three ways, and Gaia handles each for every vendor.

**1. Structured: `gaia.ask_user`.** This is a Gaia tool (§5.3), so it works the
same in Claude, Codex and Gemini. Its input is the question, optional options
(single or multi-select, with an optional recommended one), and whether free
text is allowed. It renders as a **question card** using the same blocking
mechanism as proposals: number keys pick an option, typing gives a free
answer, and Ctrl+Enter submits. The answer is the tool result, so the agent
continues in the same turn with its working state intact.
- Claude Code's built-in `AskUserQuestion` is disabled (`--disallowedTools`),
  so it can't misbehave in headless mode. Plain `-p` leaves it out anyway,
  but as an SDK host Gaia is offered it, so the flag is needed (checked on
  2.1.312). GAIA.md tells every agent to use
  `gaia.ask_user` when it needs a decision. Codex and Gemini have no built-in
  equivalent in headless mode, so this is their only structured path.
- **Waiting a long time:** the tool holds the agent for up to **1 hour** (a
  setting). The prompt cache will usually have expired by the time you
  answer, so the next step re-reads the context at full price. That's
  accepted. Each CLI's MCP tool timeout is raised past the hold for Gaia's
  server: Claude Code `MCP_TOOL_TIMEOUT`, and the per-server timeout in
  Codex's and Gemini's MCP config. After the hour, the tool returns `pending:<id>` with an instruction to end
  the turn. The card stays open, and the answer arrives later as the next user
  message on the resumed session. So an hour-long beacon run can stop for a
  question while you're out without holding a process open indefinitely.

**2. Plain text: the agent ends its turn with a question.** Nothing breaks,
because it's a chat and the reply is just the next message. Gaia only changes
the signal: a turn whose last paragraph ends in a question is marked
`needsInput`, and the toast or push says "Gaia has a question" instead of
"done".

**3. Permission prompts** (may I run this command / edit this file):
- Claude Code: `--permission-prompt-tool` routes them to a Gaia approval card
  (§5.3).
- Codex: `codex app-server` sends them as requests Gaia answers (Phase 4C,
  §19), under the `on-request` approval policy, as permission cards. The
  `exec` fallback can't surface approvals.
- Gemini CLI: headless mode can't ask. Each chat sets an approval mode up
  front (ask nothing / auto-edit / full auto), and anything outside it fails
  instead of prompting.

Question and permission cards show on the phone with a push, and answering
there sends an `answer` command to the beacon. Drain mode pauses on any open
card, and Abort voids them all.

In a chat in Auto, permission prompts raise no card (GAIA_AUTONOMY_HLD.md §5.7).
Questions and Voyager data proposals still do.

---

## 11. Memory ("global graphify")

Feasible as you described. It's essentially Claude Code's memory pattern,
shared by every agent:

- **Store:** `gaia_memories`, with short self-contained facts, tags, optional
  `[[links]]`, and the source chat.
- **Recall:** a compact **index** (one line per memory) rides in every system
  prompt, and `memory.search` returns full bodies. The index is taken when a
  session starts and kept for that session's life, so a new memory never
  invalidates a running chat's prompt cache. It can't be refreshed later
  (at a compaction or a restart either): both CLIs keep a session's first
  system prompt when it's resumed (§19, Phase 5). Memories added mid-chat
  are reachable through `memory.search` only. Embeddings aren't needed
  until there are hundreds of memories. Start with tag + keyword search.
- **Capture, three ways:**
  1. `/remember <text>`, or "remember that…": saved as active.
  2. The agent calls `memory.propose` when it learns something durable.
  3. **The curator:** when a chat goes idle for 10 minutes, the utility model
     reads the new turns and proposes 0–3 memories. Only the device that held
     the chat's last `runLease` runs the curator and title jobs for it, so
     several devices never duplicate proposals. The title is written once,
     guarded by `title == null` in a transaction.
- Proposed memories land in an **inbox on the Gaia page** (approve / edit /
  dismiss), with a setting to auto-accept curator output. This keeps the
  approve-before-write principle, and curator noise is the main failure mode
  of auto-memory.
- Graph view later: the links already form one, and Voyager's Rankings map
  code shows the rendering path.

---

## 12. Remote use and beacon mode

### 12.1 The options you listed

**Beacon on the laptop** works and keeps everything: local files, OS actions,
CLI logins. Windows specifics:
- `SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED)` keeps the
  system awake while letting the display turn off.
- It **does not stop lid-close sleep.** Beacon mode would temporarily set the
  lid action to "do nothing" (`powercfg /setacvalueindex … LIDACTION 0`) and
  restore the original value on exit, crash or next start. This is the
  **AC value only**. On battery the lid still sleeps the laptop, and beacon
  mode says "will sleep on lid close" while unplugged. There is no
  on-battery override, which avoids a closed laptop running hot in a bag.
- Some laptops use Modern Standby (`powercfg /a`), which changes how sleep and
  network behave. Test on the actual machine.

**Agents on Android via Termux + Node** I'd skip. None of the CLIs supports
Android officially. A Flutter app can't easily exec binaries in another app's
sandbox. It drains the battery. And it still can't reach the laptop's files.

### 12.2 Recommended: beacon is a role, not a device

- **Any desktop Gaia can be a beacon.** It heartbeats `gaia_beacons/{device}`
  every 2 minutes, counts as offline after 5 minutes without one, and the
  phone shows "Laptop · online · accounts A/B".
- **Phone → beacon:** the phone writes a `gaia_commands` doc (`prompt`,
  `answer`, `cancel`, `queue_pop`, `sleep`, `shutdown`, `abort`, `rearm`). The
  beacon claims it in a transaction, runs it, and streams back via §8.1.
  Proposal, question and permission cards show on the phone.
- **Targeting.** `targetDevice` is required for workspace chats (§5.2) and
  for any chat whose `runLease` or native session lives on a specific device.
  Otherwise it's optional, and any online beacon can claim the command.
- **Paired devices only.** Each phone is paired once on a desktop: a QR code
  carries a device key, and its public half goes into `gaia_devices`. Every
  command is signed, and beacons reject unsigned commands and commands from
  revoked devices. So a stolen Firebase session alone can't run anything on
  the laptop. A lost phone is revoked from any desktop's Gaia page.
- **Remote runs keep the chat's permissions.** A prompt from the phone runs
  under the same permission mode as on the desktop (Claude Code's Auto mode
  included, §5.2). Only what the CLI would ask about becomes a permission
  card on the phone. Pairing is what protects remote use, not extra
  approvals.
- **A phone prompt acts in Auto (amended 2026-11-04).** In a chat in Auto, a
  prompt from the phone runs OS actions and commands with no card, and Stop and
  Abort work from the phone (GAIA_AUTONOMY_HLD.md §11.4).
- **No beacon online:** the phone can still chat directly with **API-key
  agents** (Gemini API). It's the same history, so the chat carries on, and
  the tier picker greys out CLI-only agents.
- **Always-on beacon:** any cheap always-on Windows box can run Voyager in
  beacon mode with the CLIs logged in. It loses the laptop's screen and files but keeps the chats. This
  is the real fix for "my laptop went to sleep".
- **Remote power:** `sleep` and `shutdown` commands run with a 30s
  cancellable countdown. **This is one-way.** Once the laptop sleeps, the
  phone can't wake it (Wake-on-LAN over the internet on Wi-Fi isn't
  practical), and the phone UI should say so before confirming.
- Until this ships, Claude Code's own Remote Control covers the Claude case.

---

## 13. Prompt queue

- Queues per chat and one global queue, editable on desktop and phone (drag
  to reorder, tap to copy).
- `/queue <text>` (or Ctrl+Q in the composer) adds the current text without
  sending. `/queue-pop` loads the next item into the composer for review, and
  `/queue-pop!` sends it straight away.
- **Drain mode** (per chat, opt-in): when a response finishes, send the next
  item automatically. It stops on error, on any open card (proposal, question,
  permission), when the queue empties, or on Abort, which also turns drain
  mode off. Combined with a beacon, the phone can feed a long run of prompts
  while the laptop does the work.

---

## 14. Background runs and notifications

- Closing or hiding Gaia never cancels a run. Runs belong to the resident
  companion.
- On completion while hidden, a Windows toast (via the existing
  `flutter_local_notifications` / `UNIFIED_NOTIFICATIONS.md`) shows the first
  line. Clicking it opens that chat. A pending proposal, question or permission request also raises a toast.
- The tray and the Gaia page show runs in progress, with Stop.
- On the phone, beacon completions come in as push notifications. This needs:
  - `firebase_messaging`, which is new and Android only;
  - FCM tokens registered in `gaia_devices`;
  - the Android 13 notification permission;
  - a Cloud Function triggered on `gaia_notify` docs.

  The beacon writes a `gaia_notify` doc on completion, on a question and on a
  new card. Triggering on `gaia_notify` rather than on `gaia_messages` writes
  keeps function invocations to one per notification.

---

## 15. Context capture and OS actions

### 15.1 Hotkeys

All rebindable on the Gaia page, all registered by the main instance. A combo
another Gaia key or one of Voyager's own global hotkeys already holds is refused:

| | Gaia hidden | Gaia open |
|---|---|---|
| **A — small floater** | open small floater | small floater showing: hide. Otherwise: switch to small floater |
| **B — large floater** | open large floater | switch to large floater (no-op if already large) |
| **G — Gaia window** | open Gaia window | switch to Gaia window (unbound by default) |
| **Full screen** (Ctrl+Alt+Enter) | open Gaia window covering the monitor under the cursor, taskbar included, on the chat last in view | same; full screen and in front: hide. The Restore button leaves it for where the window was; it holds until then, across hides and floaters |
| **Split** (Ctrl+Alt+Shift+Enter) | move the focused window to one half of its monitor's work area, open Gaia window on the other | same, moving the app window under Gaia when Gaia has the focus. Gaia on the left by default; a setting on the Gaia page swaps the sides. Nothing to move, as over the desktop: Gaia still takes its half. A half narrower than the Gaia window's minimum: Gaia keeps its minimum, the other window gets the rest |
| **C — region** | open + crop overlay | crop overlay, attach to current draft and copy to the clipboard |
| **D — full screen** | capture screen, open, focus composer | capture screen, attach |
| **E — selection** | copy selection, open with it quoted | append selection to draft |
| **F — pick-up** | (§15.3) | hide, arm selection pick-up |
| **Abort** | kill switch (§15.7) | kill switch (§15.7) |

Gaia is excluded from capture, so D never captures the Gaia window itself and
there's no need to hide it first.

### 15.2 Selection capture

The main instance receives the hotkey while the source app still has focus.
It reads the selection through **UI Automation `TextPattern`** first, which
leaves the clipboard alone and works in most editors and browsers. It falls
back to a synthetic Ctrl+C with the clipboard saved and restored. Text arrives
as a quoted block with its source ("from Chrome — <tab title>").

The fallback has three guards:
- **Never in a console.** Ctrl+C in a console sends SIGINT. There is no
  fallback when the foreground window is a console host (`ConsoleWindowClass`,
  or Windows Terminal's `CASCADIA_HOSTING_WINDOW_CLASS`). Windows Terminal
  supports TextPattern anyway.
- **Every clipboard format is restored**, not just text.
- **Win+V history is untouched.** The temporary clipboard contents carry
  `ExcludeClipboardContentFromMonitorProcessing`.

All UIA calls (this one, §15.4 and §15.5) run on a dedicated worker isolate
with a **250 ms budget**. Cross-process UIA can block for seconds against a
hung app. On timeout the chip is simply absent. A summon never waits on UIA.

### 15.3 Pick-up mode

Press F while Gaia is open: it hides and shows a small "selecting…"
indicator. Select text anywhere and press F again: Gaia comes back with the
selection added. Esc cancels.

### 15.4 Focused-window metadata — worth it

Yes. It's about 30–60 tokens and often removes a whole round trip ("what are
you looking at?"). Each message gets a context line: app name, window title,
and for browsers the URL (via UIA on the address bar, which nus-desktop's
`probe.ps1` already does). Rules:
- Captured at summon time, so it describes the app *under* Gaia, not Gaia.
- Shown as a removable chip on the draft, so the user always sees what goes.
- Off for apps on a user exclusion list (password managers, banking).
- Settings toggle. Default on.

### 15.5 `/this` — ask about a control

nus-desktop does this as a hotkey: point at a control, press Ctrl+Shift+T,
then type a question. The pointing has to happen *before* Gaia takes focus, so
Gaia splits it in two:
- Every summon also records the UI Automation element under the cursor
  (name, type, value, bounds) and a crop around it. The element is one UIA call.
  The crop is cut from a print of that window alone, with its sensitive fields
  blacked out, as `os.screenshot` is (§15.6), so nothing beside the control or
  over the window gets in. That takes a scan of its tree, in the background,
  and `/this` waits for it. With no scan or print, the chip comes with no crop.
  All of it is discarded unless used.
- Typing `/this` in the composer attaches it as a chip: "Button · Submit
  assignment · in Chrome".

So it's a typed command, as long as the cursor was on the control when Gaia
was summoned. Sensitive fields are refused (§15.6), and so is a window on the
exclusion list (§15.4): the window under the cursor, which may not be the one
in front. As with the `os.*` tools, so is a window whose app or browser address
can't be read to check against the list, and Voyager's own while its vault is
unlocked.

### 15.6 OS actions: reading and controlling

Reading the screen is an OS action, in two forms:
- `os.read_screen`: the UI Automation tree of the foreground window or a
  region, giving every control's name, type, text and bounds as structured
  text. It's cheaper than an image, gives exact text, and shows the agent
  what's clickable. This is what nus-desktop's probe does.
- `os.screenshot`: pixels, for what UIA can't describe (canvases, images,
  games, some Electron apps).

Agents are told to try `os.read_screen` first. `os.focused_window` says which
window that is.

Acting: `os.click` (by UIA control first, coordinates as a fallback),
`os.scroll`, `os.type`, `os.key`, and `os_open` and `os_focus`, with `os_windows`
to list what's open, and `os_window`, `os_drag` and `os_clipboard` (GAIA_AUTONOMY_HLD.md
§8). An `os_clipboard` read is a read, needing *can see screen*; its write is an action.

**Three modes (amended 2026-11-04):** the hand is Off, Ask or Auto, per chat
(GAIA_AUTONOMY_HLD.md §4). In Ask, what follows holds as written. In Auto there are
no step-list cards, the turn's target stays pinned, and the stop model below it is
Esc, switching windows yourself, and the rest of §5.3 there. The refusals don't
change.

**Direct actions and background runs (amended 2026-11-08, GAIA_AUTONOMY_HLD.md §13):**
a named control's plain click or typing, and any scroll, first go through UI
Automation's patterns, with no input sent and no need for the window in front.
That holds in Ask and Auto alike. The other actions, and any step no pattern can
do, still need the front. In Auto, a step that needs the front waits for a 2 s
pause in the user's own work before bringing the pinned window up, and is refused
after 30 s. Switching windows yourself no longer ends an Auto run. A press in the
pinned window while it's in front does, and so does Esc while that window or Gaia
is in front. A new window of the pinned window's app, or one it owns, is adopted
within 1.5 s of a step even if it opens behind. Flashes play only where the user
can see them. The sensitive-field, exclusion and vault refusals apply to direct
calls as to input.

**The target window is never Gaia (decided 2026-11-01).** In Ask, every `os.*` call
works out its target when it runs; in Auto, it's the session's pinned window
(GAIA_AUTONOMY_HLD.md §5.2). If the foreground window is one of Gaia's,
the target is the next visible, non-minimized top-level window in Z-order that
isn't Gaia's. Voyager's main window isn't Gaia's, so it can be a target. An
action that needs its target in front activates it first.

These are separate from what the user attaches. Hotkeys C/D and `/this` are
the user's choice. These tools are the agent asking to look or act. C and D
capture while the vault is unlocked (revised 2026-11-07, over refusing wherever
Voyager's windows were): Voyager's main window keeps itself out of every capture
then, with `WDA_EXCLUDEFROMCAPTURE` (`secure_window.dart`), so the shot shows
what's behind it. This hides it from the user's own screenshots and screen shares
too, until the vault locks.

Safety, partly borrowed from nus-desktop:
- **Two grants per chat, both off by default:** *can see screen* (the read
  tools) and *can control* (the action tools). While *can control* is on, a
  persistent "Gaia is in control" border shows. Esc stops the current
  OS-control run, and Abort (§15.7) stops everything.
- **Sensitive-field refusal enforced locally**, not by prompt (port of
  `guide/sensitive.js`): never type into or read password, card or OTP
  fields.
- **The exclusion list (§15.4) applies (decided 2026-11-01).** No `os.*` tool
  reads or acts on an excluded app or site, as the summon-time context doesn't.
  A browser is checked against its URL too.
- **Voyager's vault (decided 2026-11-01).** No `os.*` tool reads or acts on
  Voyager's own windows while its vault is unlocked.
- **Turning on *can see screen* shows a one-line warning (decided 2026-11-01)**,
  each time and in every chat, beside the toggle: an agent with its CLI's shell
  or web tools could send screen text elsewhere, or be steered by it. The grant
  stays one click.
- In Ask, each action batch shows as a step list, approved once or step-by-step, the
  OS-level equivalent of §10. **Approving once needs every step's target shown
  (decided 2026-11-01):** its window and resolved control, or its coordinates.
  A run stops if the window changes.
- Prefer UIA targeting over pixel coordinates. It survives DPI and layout
  changes, and a model can name a control far more reliably than a pixel
  location.

### 15.7 Abort (kill switch)

One rebindable hotkey, **Ctrl+Alt+Backspace** by default, registered by the
main instance. Gaia stays running and
visible; it just stops doing anything until the user re-arms it. Pressing it,
from any state:
- **Runs:** every Gaia-spawned agent process tree is killed (`taskkill /t /f`),
  API streams are cancelled, and utility jobs (router, titles, curator,
  compaction) stop. Interrupted messages are saved and marked `aborted`. The
  user's own CLI sessions outside Gaia are untouched.
- **OS access:** every chat's *can see screen* and *can control* grants are
  revoked. Synthetic input stops mid-sequence, and Gaia sends key-ups for any
  key it was holding, so Ctrl or Shift is never left stuck down.
- **Capture:** hotkeys C, D, E, F and `/this` refuse with "Gaia is aborted". So
  does Split, which moves nothing.
- **Cards:** open proposal, question and permission cards are voided. The main instance's action
  executor checks the abort flag itself before any commit; it doesn't trust
  the companion to have stopped.
- **Remote:** the beacon claims no commands except `rearm`, and every chat's
  drain mode is turned off.
- **What remains:** chats can be read and scrolled. The composer is replaced by
  "Gaia is aborted · Re-arm".

The main instance persists the `aborted` flag, so a restart comes back
aborted, and then tells the companion. If the companion doesn't confirm within
one second, the main instance kills the companion's process tree and relaunches
it in the aborted state. A hung companion can't ignore the switch.

**Re-arm** is deliberate: the button in Gaia or on the Gaia page, confirmed
with Ctrl+Enter. It restores chats and runs. It does **not** restore OS grants
or drain modes; those are turned back on per chat. The phone can trigger Abort
("Abort laptop" on the Gaia page) and can re-arm, which is safe because grants
stay off after any re-arm.

**In Auto (amended 2026-11-04).** Esc is polled for the whole session rather than
one step list, and ends the turn. Esc or switching windows also sets a latch, so
that turn's `os_*` calls are refused however slowly its agent stops, and turns the
chat's drain mode off, so the next queued prompt doesn't carry on
(GAIA_AUTONOMY_HLD.md §5.3).

**Esc's reach in Auto (amended 2026-11-08, GAIA_AUTONOMY_HLD.md §13.5).** Esc ends
an Auto turn only while the pinned window or Gaia is in front: Esc in the user's
own app, closing a menu there, is theirs. Switching windows no longer stops a run;
a press in the pinned window while it's in front does, with the same latch. The
Stop button, Revoke and Abort are unchanged, and the Stop button is the stop while
the user is in another app.

---

## 16. Compaction

- Setting: auto-compact at N tokens, capped at **900k** (default 200k, which
  is cheaper and faster).
- **CLI adapters compact themselves.** Gaia maps its setting onto each CLI's
  knob where one exists (*verify Claude Code's current auto-compact override
  env var*), and records the CLI's compaction event as a
  `compactionBoundary` divider in the synced history.
- **API adapters:** Gaia compacts itself. The utility model summarizes turns
  before the boundary, and the summary replaces them in the replayed context.
- The full uncompacted history always stays in Firestore. Compaction only
  changes what the model sees.
- `/compact [focus]` compacts on demand.

---

## 17. The Gaia page in Voyager

Desktop and Android:
- **Chats:** search (hooks into Voyager's search; message text is indexed in
  a local drift FTS table on each device), pinned, recents, open and
  continue. On Android this is the full Gaia client.
- **Setup:** the CLI checklist (§5.1).
- **Status:** beacons online, runs in progress, the active account per vendor,
  paired devices with Revoke, and local CLI session disk use.
- **Usage:** per-account bars for every window (5-hour, weekly, daily) with
  reset times, each source's health state (§6.4), and tokens and estimated
  cost per day, chat and tier.
- **Memories:** list, edit, the proposed inbox (§11).
- **Queue** (§13).
- **Action log:** every committed proposal and OS action, with undo where the
  entity supports it.
- **Settings:** agents, tiers, router rubric, accounts and thresholds,
  GAIA.md editor, commands, keybinds and hotkeys, context-capture exclusions,
  auto-compact.

---

## 18. Additional features

Adopted from nus-desktop (`companion/`):
- **Screen reading through UI Automation** (nus's `win/probe.ps1`), as
  `os.read_screen` (§15.6) and the summon-time capture behind §15.4 and
  `/this`. Ported to Dart FFI rather than a PowerShell sidecar.
- **`/this`** (§15.5): nus's Ctrl+Shift+T, as a typed command.
- **Sensitive-field refusal enforced in code** (port of `guide/sensitive.js`,
  §15.6).
- **Untrusted-data framing** for every piece of injected context (§5.3).
- **Abort** (§15.7) in place of nus's panic hide. Gaia stays visible and
  running; it only stops acting.
- **Local push-to-talk. Later phase.** Hold a rebindable key and speak.
  whisper.cpp transcribes on the machine, so no audio leaves it, and the text
  lands in the composer for review rather than being sent. It works in Gaia's
  window and from any app via the main instance's hotkey.

Not adopted: learned walkthroughs, guided pointing, proactive nudges.

Other additions:
- **Edit & resend / regenerate on another tier** ("try this on Deep"), with
  the alternatives kept as branches. Regenerating on another tier goes
  through §7.5.
- **Rewind to a message** (right-click a message): everything after it comes
  off the chat, with an undo toast as chat delete has. Rewound messages are
  soft-deleted. Their images go onto the media module's 30-day clock, and undo
  brings them back. Messages don't keep a `referenceId`, so the main instance
  finds each image's reference on the chat by its media id. The chat's
  `agentSessions` are cleared for every device and adapter, since each
  session still holds the rewound turns. The next message
  starts a new session, which gets the chat so far through the handoff
  (§7.4): older turns summarised, recent ones verbatim, images as captions.
  A running reply is stopped first. Not undone: files the agent changed on
  disk, which the menu row says. Smaller than fork: one host request, no
  copying.
- **Fork from a message**: a new chat holding copies of the messages up to
  and including it (new ids, same `seq`s and `[image N]` labels), titled
  "<title> (fork)", opened at once. The main instance copies the messages and
  adds a media reference for each image under the new chat, so deleting
  either chat leaves the other's images. The fork has no sessions, so its
  first message hands over as above. Its tier is the original's. A fork
  remembers where it came from (`forkedFrom`: chat id and seq), shown as a
  link at its top. This is also how Edit & resend's branches can be kept: a
  resend on an earlier message forks rather than overwriting.
  - Both lean on the handoff rather than the CLI's own session: Claude Code's
    `--fork-session` forks only at a session's end, and cutting one at a
    message would mean rewriting its undocumented JSONL. The cost is
    fidelity: a new session sees a summary of older turns, not the original
    session's tool results.
- **Chapters**: pin a message as a chapter (right-click, "Pin as chapter",
  with an optional name defaulting to its first line). A chat's chapters
  are listed in a strip at the top of the large floater and the Gaia
  window, and clicking one scrolls to its message. They're a `chapters` list
  on the chat (message id and name), synced with it. A rewound or deleted
  message's chapter goes with it, and a fork keeps the chapters in its copied
  range. They're for navigation only: the agent doesn't see them.
- **@-mentions for Voyager context:** `@today`, `@todo`, `@journal:yesterday`,
  `@workout:plan`. These are explicit, visible context instead of hoping the
  agent calls a read tool.
- **Context packs** (from nus's `context-pack.js`): user-maintained markdown
  files (e.g. "CS 136 course info"), re-read when they change and attachable
  to a chat. They're lighter than memories for big reference material.
- **Auto chat titles** from the utility model.
- **Per-run limits** (max turns, max tool calls, wall-clock) alongside Stop,
  so a runaway agent loop can't burn a 5-hour window.
- **Send to Voyager:** save a reply as a journal entry, todo or study note
  (through a proposal, naturally).
- **Offline composer:** prompts written while no agent is reachable go to the
  chat's queue, never lost.
- **Secrets** (API keys) stay on each device, never in synced settings. On
  Windows they're encrypted to the user's account with DPAPI (decided
  2026-10-25, over the Secure Notes vault, which would leave utility jobs
  off whenever the vault is locked). Android gets Keystore storage with the
  phone client (Phase 7). No API key is used yet: the DPAPI store was built
  for the Gemini key and removed with it, to come back with the first
  API-key provider.

---

## 19. Phasing

| Phase | Status | Scope |
|---|---|---|
| 0 | Done | `--companion` launch + mutex, IPC pipe (with DACL and client check), window modes (small/large floater, Gaia window; §3.3), exclude-from-capture, Claude Code adapter (with fixtures and version range), chat via the main instance, Abort (runs) |
| 1 | Done | Gaia drift tables + sync, Gaia page (chats, settings, setup checklist), GAIA.md, notifications/background runs, update drain |
| 2 | Done | Agents/tiers/router, Codex adapter, Haiku utility model on Claude Code, cross-vendor handoff, commands, keybinds. **Gemini skipped** (below) |
| 3 | Done | Screenshots (C/D), crop overlay, annotation, `[image N]` parts, selection capture + pick-up, focused-window context |
| 4A | Done | Gaia tools (Claude Code's control channel, Codex's stdio shim), `voyager_*` reads, the card system, `ask_user` question cards, Claude Code permission cards |
| 4B | Done | `propose_*` tools (todo, calendar event, journal entry; new and changed) + editor cards + approval tokens + the main instance's executor + `origin: gaia` + action log; Codex `app-server` evaluated |
| 4C | Done | Codex adapter on `app-server` (recorded fixtures + contract scenario): permission cards and `ask_user` for Codex, client-hosted tools replacing the `--gaia-mcp` shim, one long-lived process with threads and turns; `exec` stays as the fallback. The trash shows `origin: gaia` (left from 4B) |
| 5 | Done | Memory + curator + inbox (below; checked live in the app 2026-10-30) |
| 6 | Done | Text (§9.5): Markdown rendering of messages, streamed, one renderer for desktop and phone, with code highlighting, the per-block copy button and inline code from §9.3; partial selection and copy; clickable URLs and file paths; spellcheck + autocorrect in the composer, skipping code, commands, labels, paths and URLs; Voyager's Vim engine and snippets in the composer (§9.1); the user's dictionary, snippets and toggles synced to the companion |
| 7 | Done | Beacon, device pairing + signed commands, run lease + session catch-up, phone client, FCM, live streaming, commands, queue + drain, remote power |
| 8A | Done | Usage reading on today's single accounts: `UsageSource` for Claude and Codex with fragile-endpoint fixtures and strict parsing (§6.3), health states (§6.4), a composer usage ring polled from launch rather than the first run (§6.2), and a Codex ring (checked live 2026-11-01, except the Codex passive update during a turn: its shape is tested from the recorded fixture) |
| 8B | Done | Accounts: the ordered account list and per-spawn config (§6.1), native sessions tracked per account (§7.4), account-switch session copy and `--resume`, a manual switch with its divider (§6.5), a ring per account with inactive ones dulled (§6.2). Claude checked live 2026-11-01 across two logins; a Codex turn on a second account is not (below) |
| 8C | Done | Low and exhausted (§6.5): floors, the low banner, the exhausted decision card and its three cases, the interrupted run's partial answer kept and marked, the resend checkbox, the card replacing the §7.5 confirmation. Checked live 2026-11-01 with forced numbers across two logins; the limit errors themselves come from the CLIs' binaries, not a real limit (below) |
| 9A | Done | `/this` (§15.5): the summon-time capture of the element under the cursor, the chip, the refusal while aborted, and the sensitive-field refusal in code (§15.6). Checked live 2026-11-02 with a real summon, on Chrome and Electron too; BUG-339 and BUG-340 fixed and re-run in the app (below) |
| 9B | Done | Agent reads (§15.6): per-chat, per-device grants, the target window rule, `os.read_screen`, `os.screenshot`, `os.focused_window`, and Abort revoking grants, with Re-arm leaving them off (§15.7). Checked live 2026-11-02 with real turns on both CLIs; BUG-338 and BUG-341 fixed, first shots re-checked live (below) |
| 9C | Done | Agent control (§15.6): `os.click`, `os.scroll`, `os.type`, `os.key`, step-list approval, the "Gaia is in control" border, Esc to stop, Abort stopping input mid-sequence with key-ups (§15.7), the action log. Checked live 2026-11-02 with real turns on both CLIs, the border and the phone; BUG-337 and BUG-343 fixed and re-run in the app (below) |
| Later | | Push-to-talk (§18) |

Each phase ends with something usable. Phase 0–1 alone is already a Claude
Desktop replacement.

**Phase 8 is split in three (decided 2026-11-01)**, built in order, so the
risky session change is tested apart from the read-only usage work and the
card logic on top of both.
- **8A** changes no session behaviour. Its Codex source is confirmed:
  `account/rateLimits/read` on `app-server` replaces both `rate_limits` from
  `exec --json` and the idle-account call (§6.2, §20). On the `exec` fallback
  there is no source, so Codex reads as `offline`.
- **8B** is the risky part. Session keys are only device and adapter today,
  and they're stored in synced chats, so existing entries need a compatible
  migration. The Claude runner holds one config dir and the Codex runner one
  home, with one `app-server` process and its `gaia-threads.json` in that
  home. The utility model and session catch-up are affected too. The terms
  re-check in §20 came first: checked by Juno, green light given (2026-11-01).
- **8C** needs 8A's numbers and 8B's switch.

**Phase 9 is split in three (decided 2026-11-01)**, built in order, because
the risk rises with each part: a bug in 9A gives a bad chip, one in 9B sends
screen contents to an agent, and one in 9C puts real input in the wrong app.
Abort ships with the part it protects rather than as a step of its own.
- **9A** is the user's choice of what to attach, so it adds no agent tools.
  It builds on the UI Automation code from Phase 3. Its sensitive-field
  refusal is what 9B's reads rely on.
- **9B** sends no input. Its grants are new: stored on the chat, synced, and
  applied only on the device that gave them (§8), so it needs a migration.
  The questions §20 marked for 9B and 9C are settled (§15.6).
- **9C** needs 9B's grants and its UI Automation tree for targeting. It's the
  one part that has to be checked live with a real foreground window, not
  with background input or while locked.

Push-to-talk is out of Phase 9. It shares nothing with the OS work and needs
whisper.cpp and audio capture of its own.

Gemini's usage sources (§6.2) are out of scope while Gemini stays skipped
(below), and come back with its adapter.

**Gemini skipped completely for now (2026-10-25).** Neither the Google
login nor an API key works with the installed Gemini CLI (0.65.0), so no
real `stream-json` fixtures can be recorded and the CLI adapter can't be
built to §5.1's standard. The Gemini API utility model was built, then
removed for Haiku on Claude Code (§5.1), which needs no key. Gemini comes
back once a login works: record fixtures, then add the CLI adapter beside
the Codex one.

Phase 4A as built (2026-10-28):
- **Transports** as in §5.3. Codex gets the shim through `-c
  mcp_servers.gaia.*` on each turn: `command` (this exe), `args`
  (`--gaia-mcp`), `tool_timeout_sec`, and `default_tools_approval_mode =
  'approve'`, without which `exec`'s "never" policy refuses every MCP
  call. In a dev profile it also gets `env = {VOYAGER_PROFILE = …}`,
  because Codex starts MCP servers with only a few environment variables.
  Claude Code gets `MCP_TOOL_TIMEOUT` past the hold. A 75 s held call
  works on both (2.1.312, 0.164.0).
- **Tools.** `ask_user` (a question, up to 9 options, multi-select, a
  recommended one), plus five reads answered by the main instance:
  `voyager_todos` (open tasks by list with subtasks, by due date or list),
  `voyager_calendar` (up to 62 days, repeating events on each day they
  occur, moved occurrences in their place), `voyager_journal` (up to 31
  days), `voyager_workouts` (up to 62 days, sets per exercise) and
  `voyager_trackers` (up to 366 days, the user's own analytics trackers
  with each reading; not the built-in derived ones). Each
  read is plain text in a `<voyager_data>` block framed as reference, not
  instructions, with today's date. None of them reads secure notes. Reads
  are on in every chat: the workspace toggle (§5.2) waits for workspace
  chats, which don't exist yet. Claude Code's activity chip names Gaia's
  tools without their `mcp__gaia__` prefix; Codex reports them as "MCP".
- **Cards** are a `card` part on the reply (§8), saved as soon as each is
  raised or decided. A raised card toasts like a finished run when its
  chat isn't in view. While the current chat's latest reply has an open
  card, the composer answers it:
  - a question: the picked options (keys 1–9 while the draft is empty, or
    a click) plus anything typed, sent with the send key;
  - a permission: the send key on an empty draft allows, and typed text
    denies with that text as the reason.

  The card's own buttons (Dismiss, Deny, Allow) do the same. A question
  unanswered for the hour stays open, the agent is told to end its turn,
  and the reply is marked `needsInput`. Answering later marks the card and
  sends `Re: <question>` with the answer as the next message. A permission
  unanswered for the hour expires, denied. Stop, Abort, or a run that dies
  voids its chat's open cards, and the reply keeps them voided. While
  aborted, every tool refuses. The Gaia page shows cards as a record only;
  answering from the phone comes with Phase 7.
- **Checked live (2026-10-28)** on the `qa` profile with the debug build:
  - Codex (gpt-6.1-sol) called `voyager_todos` and `ask_user` through the
    shim, and answering the card in the controller reached it.
  - The same through Claude Code (Haiku).
  - The contract check's new scenario: an `ask_user` call and a permission
    prompt forced by a project `ask` rule, on Opus.

  Not checked live: a permission card from the user's own Auto mode
  (rarely asked), the hour's expiry (unit-tested with a short hold), and
  the shim's connection being dropped for a process Gaia didn't start.

Phase 4B as built (2026-10-28):
- **Tools.** `propose_todo`, `propose_calendar_event` and
  `propose_journal_entry` each make a new row, or, given an `id`, change
  one (decided 2026-10-28), with only the fields that change. The reads
  now show each row's id for that. A change can't tick off a repeating
  task, or touch a repeating event or a Google one; the tool says so and
  the agent tells the user to do it in Voyager. A journal entry's new body
  replaces the whole entry.
- **Prepare, accept, commit.** A call goes to the main instance's executor
  (`host/gaia_executor.dart`), which resolves names to ids (list, calendar,
  journal, else the default, as a new item's own default), fills in the
  rest, and keeps the result by card id. A change also records the row's
  current values and version. The card holds that proposal in an editor:
  - title and text fields, a picker for the list, calendar or journal;
  - date and time pickers, and switches for all day, starred and done;
  - mood on a slider;
  - on a change, under each field it alters, what it was.

  The send key on an empty draft accepts, as do the card's Save and, with
  several open, Save all. Typed text turns it down with that text as the
  correction, and the agent is told to re-propose with it. Accepting issues
  an approval token. The executor commits only a card it prepared, once,
  with a token. It uses its own kept copy of what's written where, takes
  only the fields from the card, and checks them again. It refuses a row
  that changed since it was proposed. The main instance refuses every
  commit and undo while aborted, whatever the companion does. The token
  binds one acceptance to one commit; it isn't a signature, since the pipe
  is already the user's own.
- **Writes** go through the same paths Voyager's pages use, so each one
  syncs and the open pages show it: tasks through the repository with an
  upload, placed in their list's order; events through the repository;
  entries through the journal's write coordinator. Every row Gaia
  creates gets `origin: gaia` (a column on todo tasks, calendar events and
  journal entries, schema 179, synced). Firestore merges take either
  side's, since it never changes after creation. A change keeps the row's
  own origin: `origin` says who made the row, and the action log says what
  Gaia changed.
- **The agent is told** exactly what was saved, field by field, and the
  new row's id. Each field the user changed in the editor is marked with
  what the agent proposed (`(changed by the user; you proposed …)`; an
  entry's text only as changed), since a small model left to compare the
  two misreported an edited title (added 2026-10-29).
- **Unlike §10**, a proposal unanswered for the hour expires with nothing
  written, as a permission does, rather than staying open as `pending:`.
  The executor keeps prepared proposals in memory, so a later accept would
  need re-preparing, which wasn't worth it yet.
- **The action log** is the Gaia page's Actions tab: every accepted
  proposal in a live chat, newest first, read from the cards themselves
  (each keeps what it committed), so it needs no collection of its own.
  Undo puts a new row in the trash or a change back, and is refused if the
  row changed since; the card is marked undone. Undo runs through the
  desktop's executor, so the phone shows the log without it.
- **Permission prompts for Gaia's own tools** (Claude Code outside Auto
  mode) are allowed without a card: a proposal is its own card.
- **A turn that ends with a call still held** (Codex `exec` stops waiting
  on a tool after about 30 s and ends its turn) voids its proposals and
  permissions, with nothing written; a question stays open and, answered
  later, goes as the next message. So on Codex a proposal has to be decided
  within about 30 s on `exec`. Phase 4C's `app-server` adapter holds a
  call as long as the card does (a 75 s hold checked on 0.164.0).
- **Not done:** the trash doesn't show `origin: gaia` yet; moved to 4C.
- **Checked live (2026-10-29)** on the `qa` profile with the debug build,
  on Claude Code (Haiku) and Codex (gpt-6.1-sol):
  - a new task, event and journal entry, each accepted as proposed or
    edited in the card first, written with `origin: gaia` and synced to
    Firestore; times across the 1 November DST change land right;
  - a change to a task and a journal entry's whole body, with the card's
    "was" values; the row keeps its own origin;
  - a repeating event's change refused by the tool;
  - turned down with a correction (from the card and from the composer),
    then re-proposed and accepted with the send key on an empty draft;
  - a row changed between proposing and accepting: refused, nothing
    written, and the agent re-read it and proposed again;
  - the Actions tab: Undo trashes new rows and puts a change back, both
    synced, and refuses a row changed since;
  - Abort voids an open proposal, refuses a late accept, and refuses Undo.

  That check found and fixed: a Codex turn ending with a proposal held left
  the card waiting, so a later accept wrote the row with the card still
  open (out of the action log, and the agent never told); and a new task's
  editor showing the whole summary where the hidden Done switch goes, with
  a decided card showing none. Claude Code runs its tool calls one at a
  time, so its proposals come one card at a time and Save all doesn't show.
  Not checked live: Save all (Codex only), the hour's expiry (unit-tested),
  and the phone's action log.

Codex `app-server` evaluated (2026-10-28, 0.164.0, still marked
experimental): it can ask. Its JSON-RPC protocol (`codex app-server
generate-json-schema`) sends the client `item/commandExecution/requestApproval`,
`item/fileChange/requestApproval` and `item/permissions/requestApproval`,
answered `accept`, `acceptForSession` or `decline`. So Codex can get
permission cards. It also has `item/tool/call`, client-hosted tools, which
could replace the `--gaia-mcp` shim, and `item/tool/requestUserInput`.
Threads (`thread/start`, `thread/resume`) and turns (`turn/start`,
`turn/interrupt`) on one long-lived process would also give Codex the
process lifecycle Claude Code has (§5.1). Building it is a new adapter with
its own recorded fixtures and contract scenario, so it's Phase 4C; until
then Codex runs on `exec` and can't ask.

Phase 4C as built (2026-10-30, codex-cli 0.164.0):
- **Adapter.** `adapters/codex/codex_app_server.dart`: one `codex app-server`
  process, started on the first Codex message with the same Codex home,
  login copy and `[windows] sandbox` as `exec`, and `initialize`d with
  `experimentalApi`, which `dynamicTools` needs. Each chat is a thread
  (`thread/start`, or `thread/resume` the first time this process sees it)
  and each message a `turn/start` with the turn's model, so a tier change
  needs no restart. Images go as `localImage` inputs after the text, with
  the line naming their labels, as on `exec`. The process is killed after
  10 minutes with no turn running, and on a GAIA.md change once its turns
  end, since a thread reads AGENTS.md when it's loaded. Stop sends
  `turn/interrupt` and fails the turn at once.
- **Streaming.** `item/agentMessage/delta` streams the reply, where `exec`
  gave a block at a time. A message's trailing whitespace is held back, so
  a block doesn't end in a blank line. `thread/tokenUsage/updated` gives
  the context size (`last.totalTokens`).
- **Gaia's tools** are the thread's `dynamicTools`, answered through the
  same handler as the other transports (`gaiaMcpAnswer`). The activity chip
  names them (`ask_user`), where `exec` said "MCP". A held call waits as
  long as its card: no 30 s limit.
- **Permission cards.** Threads run under `on-request` in Codex's default
  read-only sandbox. A command, a file change or a permissions request
  outside it becomes a card: Shell (the command and its folder), Edit (the
  paths and diff) or Permissions. Allow answers `accept`, or grants the
  permissions for the turn; Deny answers `decline`. Codex's answer has no
  reason field, so a reason typed in the composer reaches the card but not
  the agent.
- **Old threads are handed over** (decided 2026-10-30). A thread keeps the
  tools it was started with, and nothing changes them later (checked: they
  survive a resume in a new process). Gaia records each thread's tool-set
  hash in the Codex home (`gaia-threads.json`). A chat whose thread isn't
  recorded with the current hash (an `exec` thread, or one from before
  Gaia's tools changed) reports its session as not found, and the
  controller hands it over to a new thread with the chat summarised (§7.4).
  So each old chat loses fidelity once, then has the current tools.
- **Fallback.** When `app-server` can't start or `initialize` (30 s), every
  Codex turn for the rest of the session goes to `codex exec`, which keeps
  its Gaia tools through the `--gaia-mcp` shim (kept for that, decided
  2026-10-30). Other server requests (`item/tool/requestUserInput`, MCP
  elicitations, token refresh) are refused with a JSON-RPC error.
- **The trash** shows "made by Gaia" in a task's, event's or journal
  entry's detail line when its `origin` is `gaia` (a transaction's `origin`
  is its store, so it never does).
- **Checked** with the contract check (`GAIA_CLI_CHECK=1 flutter test
  test/gaia_codex_contract_test.dart`) on the real CLI: `ask_user` and a
  denied shell command in one streamed turn, a second turn on the same
  process, a resume in a new process that remembers the first turn, an
  unknown model, and a missing thread. Its transcripts are the fixtures in
  `test/fixtures/gaia/codex_app_server/`, replayed by
  `gaia_codex_app_server_test.dart`. Probed by hand: a 75 s held tool
  call, and `turn/interrupt`.

  Checked live in the app on the `qa` profile (2026-10-30): a question
  card answered after a minute; a proposal accepted after more than 30 s,
  committed with `origin: gaia` and shown in the trash as made by Gaia; a
  Shell card allowed (the file was written) and one denied with a reason
  (the file stayed); Stop mid-stream, after which the next turn on the
  thread still answered; an `exec`-era chat handed over to a new thread
  with its transcript; the process killed between turns (the next send
  started one and resumed the thread) and mid-turn (the reply ended in an
  error, "Codex exited (code -1)", with its text kept); a GAIA.md change
  stopping the idle process, the next turn following the new text. Not
  forced live: the fallback to `exec` when `app-server` can't start.

Phase 9C as built (2026-11-01):
- **Where it lives.** The tools are `os_click`, `os_scroll`, `os_type`, `os_key`,
  and `os_steps` for a list of them, at most 20; each of the four is a list of one.
  The main instance resolves and sends them (`host/gaia_os_control.dart`), and
  holds the plan, so the companion only says "next" or "the rest". It checks Abort
  and this device's grant itself before every step.
- **The card** is a new `control` kind (`gaia_card_view.dart`): the window, then
  each step with its target. Run all, Next step, Deny; send with an empty composer
  runs all when it can, otherwise the next step, and a typed reason denies. A
  control named but not on screen yet, as in a menu an earlier step opens, shows
  so, and then Run all isn't offered: that's §15.6's rule. Each step is resolved
  again before it's offered, and again as it's sent. **An older build can't read
  this kind**, so a phone needs updating before it opens a chat with one.
- **Targets.** By name, and type if given, as `os_read_screen` shows them, from the
  same scan (`gaiaScanWindow`'s `find`), on-screen controls only. Several of a name
  need a point inside the one meant. Coordinates must be inside the window. The
  click itself is always real mouse input at the control's middle, not UI
  Automation's Invoke, which can block on a modal dialog and can't be stopped.
- **Each step, before it's sent:** the check above; Esc; no modifier held; the same
  window in front; the same process behind that hwnd; the exclusion list, with a
  browser's address read again; the vault; and for a click or scroll, that the
  window at the point is the target, so nothing covering it, Gaia's floater
  included, takes the click. **A held modifier waits, up to 3 s**: approving with
  Ctrl+Enter leaves Ctrl down, which would turn the first click into a Ctrl+click.
- **The window changing.** The target is an hwnd, so a step that opens a dialog ends
  the run, and the agent reads again and sends the rest as a new list. Gaia in front
  is fine for the first step of a run, and for every step-by-step one, where the
  user has just clicked it. It passes on its right to the foreground as it approves
  (`AllowSetForegroundWindow`), and the switch is watched for up to 2 s, as Windows
  makes it a moment after agreeing to. Later in a run, Gaia in front is the window
  changing.
- **Typing** goes as Unicode, so no layout or Caps Lock changes it, one character
  at a time, 20 ms apart, with a look between them, at most 2000, which takes about a
  minute (BUG-352). Enter and Tab are real keys.
  Focus is checked for a sensitive field before a step types, not between its
  characters; the window in front is checked throughout. Not knowing what has focus
  is a refusal. **UI Automation's focused element proves nothing about a sleeping
  page** (BUG-343): its first answer is an unnamed Pane that doesn't hold the focus. So
  a page is asked through its tree, by `HasKeyboardFocus`, once that shows the page
  (`gaiaSettleFocus`); elsewhere, an answer that doesn't hold focus is asked again, and
  then the tree is. On a page, a container holding the focus isn't an answer: Firefox's
  Document holds it for a field focused before its tree woke, whichever field that is
  (BUG-344). Nor is a field with no name, which could be any field. Still not knowing refuses if the window has a sensitive field. Keys that type, Ctrl+V among them, are refused in a sensitive field;
  Tab, Enter and Esc there go. **The Windows key is refused**: it acts on Windows,
  not the window, and Win+R's dialog would be out of the list's sight.
- **Key-ups.** A chord's presses and releases go in one `SendInput`, so Abort can't
  land between them and nothing is held between calls. Only a short count from
  Windows can leave a key down, and the run's end lets go of those.
- **Esc** is polled with `GetAsyncKeyState` every 20 ms during a run, not a global
  hotkey, which would take Esc from every app, and the target gets the press too. A
  chord Gaia sends can't trip it, being up again before the next look.
- **Stopping.** Esc, Abort, Stop, the grant turned off, the chat deleted and the
  companion going away all end the run at the next look. The agent is told how far
  it got, and that the user stopped it. A result of "sent" says the input went, not
  that it worked: the tool's text tells the agent to read the screen.
- **The border** is native (`gaia_control_border.cpp`), in the main instance: four
  glowing strips per monitor, in Gaia's accent drifting into the Astral gold over a
  dark falloff that keeps it readable on a white page, and a notch on the primary,
  all topmost and left out of captures, and click-through but for the notch's button
  (a window of its own, at alpha 1). Strips rather than
  one window with a hole, since a topmost window the size of a monitor reads as a
  full screen app. It shows while any chat here has the grant, across hides and
  restarts, as §15.6 says. **The label names the chat (decided 2026-11-01)**, or how
  many, or a forgotten grant would leave a border nothing explains. It goes with
  Abort. The notch's text is Gaia's Iosevka Aile, loaded from the bundled asset and
  drawn with GDI+, and its button is a still `GaiaButton`, with nothing animated, so
  it costs nothing until the cursor is over it. **The notch's Revoke access
  (2026-11-02)** turns off both grants on every
  chat on this device, as Abort does, and stops a run, but agents keep running and
  Gaia isn't aborted, so a grant can go straight back on. Pressing it doesn't
  activate the window. A step aimed under the button is refused, as anything covering
  the target is; one aimed under the rest of the notch goes through, as the user's
  click does (decided 2026-11-03: a dead area for as long as the grant is on costs
  more than a click reaching something the notch hides).
- **The toggle** is the hand beside the eye, per chat. The grants are separate: with
  only *can control*, the agent can act but not read, and gets the eye's refusal if
  it tries to. Turning it on shows no warning: the step list and the border are the
  boundary.
- **The phone can deny, not approve (decided 2026-11-01).** Approving takes someone
  at the screen, who can see the border and press Esc. A prompt from the phone that
  reaches a step list waits for the desktop. This holds in Ask; Auto has no step
  list to approve (§12.2).
- **The action log** lists a step list that sent anything, however it ended, as "Ran
  2 of 3 steps in Notepad", with no Undo. The card in the chat has the steps. A
  card's labels sync with its message, window title, control names and typed text
  included, as the §15.4 chip's do.
- **Limits.** Windows blocks input to an elevated window without saying so (UIPI), so
  such a run reports "sent" and nothing happens; reading the screen shows it. A
  Codex turn that stops waiting on a tool (Phase 4C's 30 s) would leave a held card
  voided, as for a proposal.
- **Checked live (2026-11-01)**, with real input through the real Win32 backend,
  against a probe-owned WinForms window on a 200% display, three runs in a row
  (`test/tool/gaia_os_control_live_test.dart`): lookup by name and type, a wrong type
  not found, the password field marked sensitive; a named field clicked, then text
  with a line break and an emoji typed; Ctrl+A received as a chord; a named button
  clicked; typing into the password field refused, by name and by focus, with it
  still empty; `stop()` and a real Esc each ending 1500 characters partway, with no
  modifier left down; another window in front stopping a run with nothing sent. **A
  probe must be DPI aware as the app's manifest makes it:** `flutter_tester` isn't,
  so UI Automation's bounds came back scaled against the physical frame, and the run
  refused the click as outside the window. Windows can refuse a test the foreground,
  which then fails before sending anything. The native border compiles and links in
  a profile build. **Not checked live:** the probe starts with its window in front,
  so a target brought up from behind Gaia isn't. Nor an app other than the probe, the
  border on screen, the toggle and
  card on screen, `AllowSetForegroundWindow` from a real approval, or a real agent
  turn through them on either CLI. All of these were run on 2026-11-02 (next).
- **Checked live (2026-11-02)**, unlocked, on real main and companion instances at
  schema 185, with a probe, a scratch Chrome, Firefox and Electron app, and an
  Android emulator. **Works:** a real turn on Claude Code and Codex to a card, the
  run, and the result; Run all, Next step, Deny and a typed reason; a control not on
  screen yet; a dialog ending the run; a held modifier waiting, and refused past
  3 s; Esc, Abort, Stop, the grant off, the chat deleted, the companion killed and
  another window in front all stopping 1500 characters partway with no key left
  down; a floater covering the target; an exclusion or a site added between plan and
  run; sensitive fields by name and focus, on the web too; Ctrl+V refused in one,
  Tab allowed; the Windows key; the vault; the border's strips, label (the chat, or
  "2 chats"), click-through and capture exclusion, across hides and restarts, and
  gone with Abort; the action log; on the phone, Deny only, with "Waiting for approval
  at the desktop", and Abort and Rearm. `test/tool/gaia_os_control_live_test.dart`
  passes three in a row with Gaia hidden and its window raised by a real click. **Fails:
  BUG-337**, the one real approval path: from Gaia, 5 of 5 stop with "Windows
  wouldn't bring it to the front". So every run above started with the target in
  front, approved by `approveControl`. **Not checked live:** a run after a real
  activation (BUG-337), an elevated target, several monitors, an unlocked vault other
  than by forcing its flag, an empty send on the phone with a card open (by the code,
  it does nothing), and Codex's 30 s wait voiding a card. **BUG-337 fixed
  2026-11-02:** the live test now brings a real target up from behind another
  process's window and clicks it, and in the app a real card's Run, Ctrl+Enter and
  Next step each brought up a target behind Gaia and sent. **BUG-343 fixed 2026-11-02:**
  typing into what has focus reached a password field on a sleeping page, on Chrome and
  Firefox; re-run in the app with real cards, refused on the password field and typed
  into Notes on both. Still not checked live are the items above, an Electron app's
  sensitive field, and a Codex card since these fixes (those cards ran on the quick tier).

Phase 9B as built (2026-11-01):
- **Where it lives.** The tools are `os_focused_window`, `os_read_screen` and
  `os_screenshot`. The main instance answers them (`host/gaia_os_reads.dart`) and
  checks for itself, whatever the companion did: Abort and this device's grant,
  before the read and again after it, so Abort or the toggle mid-read keeps what
  it got from the agent. The results aren't synced: a message keeps only the
  tool's name.
- **The target** is `gaiaOsTarget`: the window in front, or with Gaia's or the
  shell's in front, the next app window under it. An always-on-top window isn't
  one. Nothing in front, as on a locked session, is a refusal.
- **Refusals, failing closed.** An app that can't be named can't be checked
  against the list, so it's refused. Nor is a browser read if its address can't
  be and the list has a site on it, which means an entry with a dot; an app's name
  has none, and without a site the address can't matter. So by default Firefox and
  a new tab are read, and with a site on the list they aren't: Firefox's address
  bar didn't show in UI Automation in two reads.
- **The tree** is one fetch of the window's subtree through a cache request
  (`gaiaScanWindow`), at most 60k characters: under 100 ms on most windows tried,
  about 300 ms on Firefox and 1 s at worst, for a first read of one app. Sensitive
  fields are decided first (§15.5's rule), from cached name and id, with the value
  never in the cache: a field's value is asked for only once it has passed, and a
  sensitive field's children aren't looked into, since a web field's text can be
  one. A leaf with a TextPattern and no value gives its text, as a terminal's. A
  document with children doesn't, as its text would hold the fields'. Names and
  values go as JSON strings, so a page can't fake a line. Over 8 s, or while an
  earlier read is stuck, is a refusal to try again.
- **The screenshot** is `PrintWindow` of that window alone, not the screen, so an
  excluded app on top of it can't get in. A window with a display affinity is
  refused, as `PrintWindow` wouldn't honour one. Sensitive fields are blacked out
  first, and with no tree there's no screenshot. **One read isn't enough**
  (`gaiaSettleScan`): a Chromium page enters the tree about 300 ms after the first
  read, and not at all while its tab is hidden. So it takes two reads that agree, and
  for a browser or a window with a Chromium page, one with a Document, up to about
  4 s, after which it's refused. **`PrintWindow`
  draws an app that isn't per-monitor aware at its own DPI**, in the bitmap's top
  left, while UI Automation's bounds are physical, so `gaiaWindowPrintScale` maps
  them: without it, the bars missed the fields on a 200% display (found live, which
  no test here could). At most 1568 px on the long side, a PNG, or a JPEG past
  3.5 MB; the text gives its place and scale on screen, for 9C.
- **Images in tool results.** `GaiaToolResult` carries one, as an MCP `image` item
  or Codex's `inputImage`. Both have a contract scenario against the real CLIs.
  **Codex runs Gaia's tools from a script** (code mode), where the result is a
  string ending in the data URL, not an image the model sees; it had to be told to
  pass that line to `image()`, in `os_screenshot`'s description. Without that it
  answered "none", or retyped the data wrong. A script that prints the result puts
  the base64 in its context as text instead. The `exec` fallback's images are
  untested.
- **The toggle** is the eye under the composer, per chat, one click. Turning it on
  shows the warning beside it until the next message, in the words "Agent tools
  could leak or obey screen text", to fit one line at the small floater's width; the
  tooltip has the full sentence. On a new chat it waits for the first message and
  goes with it. There's none on the phone. A prompt sent from the phone runs on the
  laptop under the laptop's grant.
- **Abort** revokes through `revokeGrants`, chats in the trash too; a flag found at
  startup revokes again, for a crash between the two. A backup's restore drops
  grants.
- **Voyager's own windows and the vault (decided 2026-11-01).** While this
  instance's vault is unlocked, every `os_*` tool refuses a window of Voyager's
  process, checked before the read and after it, since they can show decrypted notes
  and photos (§5.3). It refuses rather than moving on to the next window. Another
  profile's instance has its own vault, which this one can't see (confirmed live
  2026-11-05: its window reads while its vault is unlocked; dev profiles only).
- **Checked live (2026-11-01)**, with the session locked: the real scan against
  probe-owned WinForms windows, one DPI-unaware and one per-monitor aware (no
  secret value in the tree, both fields found and blacked out, in the picture by
  eye); scans and shots of the app windows open at the time, Chrome, Firefox and
  Obsidian among them, by counts only; images reaching the model on Claude Code 2.1.316
  and Codex 0.166.0; and on a real main instance and companion over the pipe, at
  schema 185: refused with the grant off, on and stored, refused as aborted,
  stored off by Abort, turning it on refused while aborted, still off after Re-arm,
  and on again by hand. **Not checked live:** `gaiaOsTarget` with a real foreground
  window (it's 0 while locked, so the reads ended at "no window"), a real agent turn
  through them, and the toggle on screen beyond a rendered test frame. All were run
  on 2026-11-02 (next).
- **Checked live (2026-11-02)**, unlocked. **Works:** all three tools in a real turn
  on Claude Code and Codex, with no secret in either session's file; the target with
  Gaia, an always-on-top window or the taskbar in front; refused with the grant off,
  and with only *can control*; the eye, its warning until the next message, a new
  chat's grant going with its first message; a prompt from the phone reading under the
  laptop's grant, with no eye there; a DPI-unaware window's bars, by eye; a region;
  an app, exe or site excluded, and Firefox refused with a site on the list; a display
  affinity refusing the picture (`os_read_screen` still reads that window, as built);
  the vault, by forcing its flag; a hung window refused at 8 s, a stuck read refusing
  the next, and recovery (since 2026-11-02 the guard is per window, with up to 4
  windows' reads at once: past that, a healthy window is told another window's read
  is stuck); the grant off and Abort mid-read keeping the answer from
  the agent; Abort, chats in the trash too, Re-arm leaving them off, from the phone
  too, and a flag found at startup revoking. No screen text is in stored messages.
  **Fails: BUG-338**, a first `os_screenshot` of a browser whose tree is asleep has
  no bars: a card number went out in clear on Chrome. **BUG-341**, the eye takes the
  focus from the composer. **Not checked live:** a real vault unlock, Firefox's page
  fields (its welcome dialog covered them), and the `exec` fallback's images.
  **BUG-338 and BUG-341 fixed 2026-11-02.** First shots of fresh scratch windows:
  Chrome and Firefox with both fields barred, a hidden Chrome tab refused, and Electron
  (Cursor) not refused, with no sensitive field to bar.

Phase 9A as built (2026-11-01):
- **The read.** Every hotkey but Abort, with Gaia not in front, starts it, and
  the summon doesn't wait on it (`_sendPointedControl` in `gaia_host.dart`). One
  `ElementFromPoint` on its own worker isolate, under §15.2's 250 ms budget, or 8 s
  for a page, which may have to wake its tree (BUG-346), gives the control's type,
  name, value and bounds, and for a browser the URL. A later
  summon replaces a read still going. Aborted, nothing is read.
- **Which window.** The one under the cursor, not the one in front, since they
  can differ: the exclusion list is checked against it, by exe and app before any
  UI Automation call and by URL after. Under the cursor being Gaia's own says
  nothing. A summon from Gaia's own window keeps what the companion has.
- **Sensitive fields.** `gaiaSensitiveControl` in `gaia_window_context.dart`,
  a port of `guide/sensitive.js`: UI Automation's password flag, or an edit or
  combo box named for a password, card, one-time code or identity number. It goes
  by name and id and is decided before the value is touched, so a refused field's
  value is never read, its name doesn't leave the worker, and it has no crop. 9B's
  reads are to use the same rule.
- **The crop** is the control's bounds and 48 px around them, kept to its monitor,
  at most 1000 x 700 around the cursor for a control the size of a page. It goes to
  the captures folder, swept with the others, and is deleted when the next summon
  replaces it unused. It comes from `_printWindow`, as `os_screenshot` does, so a
  sensitive field beside the control is blacked out (decided 2026-11-02).
- **The chip.** `/this` alone, from the palette or sent, or `/this <question>`,
  which sends at once. It's a new `element` part on the message (no schema change;
  older builds keep it as an unknown part), with a `<pointed_control>` block ahead
  of the prompt, framed as reference. The crop joins the draft as an ordinary
  `[image N]`, so it uploads and syncs like any other and can be removed apart from
  the chip. Name and value are capped (200 and 500 characters), since parts sync.
  Used once: pointing again takes another summon.
- **Refusals** are toasts, and `/this <question>` stays in the draft unsent: Gaia is
  aborted; a sensitive field; an excluded app or site; nothing under the cursor.
- **win32 5.15's `currentBoundingRectangle` is a use-after-free**: it returns a view
  of memory it has freed, which gave random bounds. `_boundsOf` reads through its
  own buffer. 9B and 9C's tree walks must use it too.
- **Checked live (2026-11-01)**, with the session locked: the real read against a
  probe-owned window's button, edit, password field and card field, at known
  coordinates. Type, name and bounds right, a long value capped, both sensitive
  fields refused with no value read, 40 to 60 ms for a first read and about 6 ms
  after. **Not checked live:** a real hotkey summon, `gaiaCursorTarget`, the crop
  and the chip on screen, which all need an unlocked session (`GetCursorPos` and
  `BitBlt` fail while locked). A locked read gives no control or no crop, and the
  chip without an image. Nor Chrome's or Electron's trees, whose first read may
  show less while their accessibility tree wakes. All were run on 2026-11-02 (next).
- **Checked live (2026-11-02)**, unlocked, with the real hotkey on combos of the QA
  profile's own. **Works:** a summon in 100 to 200 ms, and about 320 ms over a
  suspended window, whose read then gives nothing and recovers; the chip and crop;
  `/this` from the palette, alone or with a question; password, card and one-time
  code refused, on the web too, with the question left unsent; the value capped;
  chip and image removed apart; used once; an unused crop replaced by the next
  summon; the cursor over Gaia giving nothing, and a summon from Gaia keeping what it
  had; the window under the cursor, not in front, deciding the exclusion, by app,
  exe and site; aborted, nothing read and `/this` refused; `<pointed_control>`
  reaching the CLI. **First reads, as feared:** Chrome gives an unnamed Pane and
  Electron an unnamed Document, the next read the real button, and a page-sized
  control's crop stays under 1000 x 700. So a first `/this` in a browser is a large
  crop. **A neighbour's value did get out** in that build: a one-time code beside
  the field went to the agent in the crop, and into the image's synced caption. Crops
  now black it out, seen on Electron, Chrome and Firefox, first reads too.
  **BUG-339 and BUG-340 fixed 2026-11-02** and re-run in the app. A first read of a
  sleeping page now wakes the tree and reads again, and a page still not in it gives no
  control and no crop (BUG-343), so a sensitive field can't pass as a big unnamed Pane.
  The same goes for the other answers a page gives before it's in the tree, which are
  a `Window`, "Chrome Legacy Window" and anything of no size (BUG-346). On a page, a
  field with no name can't be judged, so no tool reads its value (BUG-345), `/this`
  gives no control or crop of it, and images black it out.

Phase 8C as built (2026-11-01):
- **Where it lives.** The rules and the CLIs' wording are in
  `usage/gaia_usage_limits.dart`; the state is the controller's (`lowUsage`,
  `limitCard`); the banner and card are in `gaia_app.dart`, the card standing in
  for the composer as `_Draining` and `_Aborted` do.
- **Floors are constants** (decided 2026-11-01), the §6.5 defaults, not the
  `thresholds` setting §8 lists: nothing asks to change them yet, and a setting
  needs a schema change and a Setup row. There's no daily floor until Gemini.
- **A per-model window** limits only its own model: Opus out leaves Sonnet on
  that account alone, so the same account can be out for one tier and not
  another.
- **A limit error** is recognised by the CLI's words (`FRAGILE(usage)`), as
  observed in the binaries of Claude Code 2.1.316 and Codex 0.166.0. A transient
  429 doesn't count: it's an ordinary error, and says nothing of the account's
  limits. The account stays out until its soonest reset, or with no numbers
  until a run on it works. This is in memory only: after a restart, only the
  numbers say.
- **The mark** is the error status the reply already had, shown as "Stopped at
  the usage limit: …" under what it wrote. So failure toasts, the phone and the
  drain, which stops at an unclean reply, carry on as for any error, and the
  resend finds its prompt from the saved reply.
- **Case 1** lists every other account that isn't out or signed out: those
  known to have headroom, then those with no numbers, then the low. The banner's
  button skips the low. **Case 2** goes by each tier's current account, so a
  provider whose other account has headroom isn't offered while its current one
  is out.
- **Resend** adds the prompt as a new message with its images, files, quotes and
  window, unexpanded, leaving the draft alone. It doesn't replace the stopped
  reply, which stays in the chat. Unticked, or with no interrupted reply in this
  chat, nothing is sent.
- **Dismissed** lasts for the account until it recovers or hits a limit again.
  The next message goes, and fails if the account is still out.
- **Focus.** The card takes the focus when it appears, on a summon, and when the
  window regains it: one raised while the user is in another app otherwise has
  no keys on their return.
- **Only the desktop composer** shows these. The phone sees the failed reply and
  its error, with no banner or card.
- **Live check** (profile gaiaqa, Haiku, Juno's and Darren's logins, usage and
  the failed reply forced by eval): the banner with its button, the card, Esc,
  and Ctrl+Enter resending a prompt that a real session copied to the other
  login answered, with its divider. **Not run live:** a real limit error, since
  no account was out; that path has tests quoting the CLIs' words. Case 2 and 3
  on screen (widget tests only). Ctrl+Enter after regaining the window: posted
  Ctrl chords don't land on a window without the foreground, so Esc checked the
  focus live and a widget test the chord.

Phase 8B as built (2026-11-01):
- **Runners.** A turn is told its account. Claude Code's runner restarts a
  chat's process when its config dir differs, as for a model change. Codex gets
  `CodexAccountRunners`: per account, its own `CodexAppServerRunner` with a home
  at `gaia/codex/<account id>`, process and `gaia-threads.json`. `default` is
  the home from before, so its threads carry on. The login is copied from the
  account's folder; the Windows sandbox setting always comes from the user's
  own Codex config, since a second folder may hold only a login. Each home
  needs its own sandbox setup, behind one Windows approval.
- **Session copy.** On a turn with no session on this account, the chat's newest
  session on another of the adapter's accounts on this device is copied in and
  resumed, with `lastSeq` carried so the delta preamble covers what it missed.
  No session, or a failed copy, is the §7.4 full handoff. An account the chat
  already has a session on resumes that one, caught up, rather than copying
  again.
- **Claude Code** finds `<id>.jsonl` under `projects/*` rather than working out
  the slug, and takes the `<id>/` folder beside it too. Checked on 2.1.316:
  resuming a copy on another login works, thinking signatures included, in both
  directions.
- **Codex** copies the rollout to the same path under `sessions` and adds the
  thread to the target's `gaia-threads.json`, without which it would read as
  another set of tools and be handed over. Checked on 0.166.0, on one login in
  two homes: `thread/resume` finds a copied rollout, even on a server already
  running. Across two real Codex logins it's unchecked, since only one exists.
- **Usage** is keyed per account (`<adapter>` for the default, as before), each
  with its own polling, health and run-auth comparison.
- **Replies** record their account (`gaia_messages.account`, schema 183), which
  places the divider on any device.
- **Live check** (profile gaiaqa, Haiku): Juno's and Darren's logins, a codeword
  given on the first was answered from a copied session on the second; back on
  the first, its original session answered with one given in between, from the
  catch-up. All four accounts read their own usage, and the composer and Setup
  tab were seen working. **Not run live:** a Codex turn on a second account,
  which needs a Windows sandbox approval.

Phase 7 as built (2026-10-31):
- **Where it lives.** `features/gaia/remote/`: `gaia_remote.dart` (the
  documents and the signed command), `gaia_device_keys.dart` (keys, the
  trust store), `gaia_beacon_service.dart` (the desktop's half, in the main
  instance), `gaia_remote_client.dart` (the phone's), `gaia_push.dart`,
  `gaia_power.dart`. The Gaia page gains Queue and Status tabs, and on
  Android a chat opens in `page/gaia_remote_chat.dart`, a full client, in
  place of the read-only transcript.
- **Remote documents are Firestore only**, never mirrored in drift:
  `gaia_beacons`, `gaia_devices`, `gaia_commands`, `gaia_live`, and three
  the table in §8 doesn't have: `gaia_watch/{deviceId}` (who watches which
  chat, in place of a `watchers` list on each beacon doc, so a phone needn't
  know which beacon streams), `gaia_leases/{chatId}` (in place of a
  `runLease` field on the chat: the outbox writes the whole chat, which
  would land over a lease taken in a transaction) and `gaia_notify`. The
  queue is a synced drift table (`gaia_queue`, schema 182, in backups), as
  is the chat's new `drain` column.
- **Pairing, per desktop (decided 2026-10-31, deviating from §12.2's "once
  on a desktop").** Firestore can't be the trust anchor: anyone who can
  write `gaia_devices` could add or swap a key, which is what pairing is
  meant to stop. So the phone makes an Ed25519 key (kept in its app data,
  not Keystore: no API key is stored yet), writes a request with its public
  key, and shows a 16-character code, 80 bits of the key's hash, too long
  for someone who can write there to find a key showing the same one (six
  digits were, until 2026-10-31). Each desktop that
  should take its commands shows the same code under Status; the user
  checks they match and pairs, and that desktop pins the key in a local
  file (`gaia_trusted_devices.json`), never synced. A second desktop is
  paired the same way. Revoke on any desktop writes `revokedAt` and adds the
  key to `gaia_revoked`, and every desktop drops the pinned key for good, so a
  document written back without `revokedAt` doesn't restore it. The list
  outlasts the device's document, so a desktop that was off hears of it even
  after a Remove or a new pairing, and a beacon reads it from the server
  before it claims a command. Pairing again after a revoke makes a new
  key. No QR code: comparing codes needs no camera or scanner package.
- **Commands** are signed over a canonical JSON of their id, type, chat,
  payload, sender, target and time, so a copy under another id doesn't
  verify. The phone always names its target: the beacon running the chat,
  else the one picked in the chat's menu, else the one whose session ran it
  last (`gaiaBeaconFor`). A beacon refuses a command not signed by a key it
  pinned, or older than 10 minutes, or already in its local log of commands
  run, and claims the rest in a transaction, so each runs once. `prompt`, `answer`, `cancel` and `queuePop` run in the
  companion (launched first if it's down); `abort`, `rearm`, `sleep`,
  `shutdown` and `cancelPower` in the main instance. The phone follows each
  command to `done`, `failed` (with why) or `rejected`, then deletes it.
- **A remote prompt** runs as the desktop's own send would, on the chat by
  the phone's id (a new chat made with it), without touching the draft, the
  chat in view, quotes or window context, on the phone's tier or the
  chat's. A new chat with no tier picked goes through the router.
- **Run lease.** The companion asks the main instance for the chat's lease
  before each run; it's taken in a transaction, renewed every minute, and
  lets go when the run ends (3 minutes if the holder dies). Offline or
  signed out, the run goes ahead. Held elsewhere, a message (text only)
  goes into the chat's queue with a "Queued: running on Laptop" toast;
  one with images or files goes back in the draft. Catch-up is §7.4's
  handoff, unchanged.
- **Live streaming** as §8.1: written only while a device watches the chat
  (registered for 60 s, renewed every 30 s), one catch-up write when a
  watcher arrives mid-run, text at most once a second, the status line
  alone at most every 30 s, deleted when the reply ends. **Unlike §8.1, open
  cards ride along** (written at once): a streaming reply syncs only once it
  ends, so without them the phone never saw the card a tool call waits on.
  The phone answers them there: options and Allow, Deny and Dismiss on the
  card, a typed answer or reason in the composer. A proposal is accepted as
  proposed; the phone has no editor. Writes are counted per day; past 15k
  live text stops and the beacon says "live view paused".
- **Queue and drain** (§13): `/queue <text>` and Ctrl+Q queue the draft for
  the chat in view, `/queue-pop` loads the next into the composer,
  `/queue-pop!` sends it, `/drain` toggles drain mode; a chip above the
  composer shows the count. A popped prompt is marked consumed (kept, not
  deleted) so no other device sends it again; one that then doesn't start
  goes back at the front of the queue as a new item. Drain sends the next prompt
  when a reply finishes cleanly (not after an error, a stop or with a card
  open), and also when drain is switched on, or a prompt queued, from
  another device while the chat is idle, and when a desktop starts. Abort
  turns drain off everywhere. A phone message to a chat that's running waits
  in its queue ("Queued: it goes after this reply"); the phone's chat shows
  the queue with Send next, and with no desktop online its composer queues
  instead (an existing chat only). The Queue tab lists every chat's queue
  and the global one: drag to reorder, tap to copy, edit, delete, and each
  chat's drain switch.
- **Push notifications** (§14): `firebase_messaging` 16.4.1 (held: 16.4.2+
  doesn't compile against our firebase_core_platform_interface 7.x). The
  phone asks for the notification permission only once it has asked to
  pair, and keeps its FCM token on its device document. A beacon writes a
  `gaia_notify` document for chats a phone drove (its last prompt, answer or
  queue-pop came from it): once per new open card, and once when the reply
  ends, unless that chat is being watched. `functions/src/gaia_notify.ts`
  sends it to the device's token and deletes it, dropping tokens FCM says
  are gone. A tapped notification opens the chat. A phone that dies or loses
  signal never deletes its watch, so a one-minute check notifies its open
  cards, and a reply that ended under it, once the watch runs out unrenewed.
  Deployed 2026-10-31 on its own (Node 24), leaving the weather functions on
  Node 20 for now, though `package.json` now says 24 for the next deploy of
  them.
- **Remote power** (§12.2): `sleep` and `shutdown` count down 30 s, shown
  on the phone and in the desktop's tray with Cancel, and cancellable from
  the phone; the phone's confirm says it can't wake the desktop again.
  Beacon mode (Status → This desktop) keeps the system awake with the
  display allowed off, and sets the lid's AC action to do nothing, saving
  the old value to put back when it's turned off or Voyager quits, and at
  the next start after a crash (`gaia_beacon_mode.json`). The heartbeat says
  whether it's on battery, where the lid still sleeps it. **A dev profile
  never sleeps, shuts down or changes the power plan**: it logs what it
  would do.
- **Also fixed:** the phone's More sheet overflowed on a 1080×2400 phone,
  leaving Gaia (and Settings) unreachable; it now scrolls.
- **Checked** with tests (`gaia_remote_test.dart`: signing, pairing, trust,
  revoke, claims, staleness, live text and cards, leases, notifications,
  power; `gaia_controller_test.dart`: remote prompts, leases, queue, drain;
  the 181→182 migration; the backup round trip), and live (2026-10-31,
  profile qa, account qa-124, with an Android 17 emulator signed into the
  same account): pairing with matching codes; a new chat started from the
  phone (routed to Quick, retitled); live text and the status line while
  tools ran; Stop from the phone; a permission allowed and a question
  answered from the phone, each reaching the run; Abort and Rearm from the
  phone; a message queued behind a running reply and sent with Send next;
  drain switched on from the phone's Queue tab, its prompt sent when the
  desktop restarted; a sleep counted down and run (logged only), and one
  cancelled from the phone; beacon mode shown on the phone; the phone's FCM
  token stored. That pass found the cards gap above and the More sheet.

  Retested end to end (2026-10-31, two desktop profiles and the emulator,
  account qa-125), which found and fixed BUG-321 to BUG-329 (`qa/BUGS.md`).
  Pairing and revoke across two desktops; forged, tampered, copied, stale and
  future-dated commands; every card kind from the phone with the desktop
  looking elsewhere; a contended lease, and one taken over once a killed
  holder's ran out; Abort and Rearm; sleep and shutdown countdowns (logged);
  beacon mode reading this laptop's hidden lid setting, restored after a
  crash; offline queueing; the composer's queue commands; `gaia_notify`
  documents, and `functions/src/gaia_notify.ts` run locally with Firebase
  mocked. **Drain now takes the lease before it pops**, and when idle goes
  by the chat's last message as saved: two desktops send each prompt once,
  and neither goes on after a reply another stopped.

  Not checked live: real sleep, shutdown and lid changes (dev profiles
  don't).

  The tray's Cancel item, checked live 2026-11-01 (profile p7a, account
  qa-127, the emulator): a shutdown sent from the phone put "Cancel
  shutdown (asked from your phone)" at the top of the real tray menu
  (opened by a posted tray message); picking it ended the countdown, the
  phone's row went back to "Online", and nothing ran when the 30 s were
  up. Cards past the day's write budget have their own test now
  (`gaia_remote_test.dart`, which fails on the old `if (livePaused)
  return`).

  **Pushes and the security follow-up, live the same day** (real FCM through
  the deployed function to an Android emulator with Play services): a reply
  and a question delivered with their text; a tap opening the chat from the
  background and from a killed process, its card answerable; none while
  watching; none to a revoked device; an uninstalled app's token dropped; a
  phone losing signal while watching a card or mid-reply told once its watch
  ran out and it reconnected. A pushed message that arrives while the app is
  in front isn't shown. The pairing code is now 80 bits (above). A beacon
  notes each command's id in `gaia_commands_run.log`, flushed before it runs,
  so a copy put back after a restart is refused: checked with a real command,
  68 s after it was sent.

Phase 6 as built (2026-10-31):
- **One renderer.** `companion/gaia_markdown.dart` parses with the
  `markdown` package (GitHub-flavoured, added for this) and builds
  Flutter widgets itself: headings, emphasis, strikethrough, inline code,
  nested lists, task boxes, quotes, rules, tables with column alignment,
  and fenced code highlighted by its language (`highlight`, Atom One), with
  the language and a copy button above it and long lines scrolling
  sideways. The companion and the Gaia page both use it, and the phone
  will. Gaia's replies render; the user's own messages stay as typed.
- **Streaming.** A reply is cut into top-level blocks (at a blank line
  before an unindented line outside a fence; a list kept whole), and each
  block's widget is kept by its text, so a chunk rebuilds only the last
  block. An unclosed fence shows as code until it closes.
- **Selection.** Each message is one `SelectionArea`, so part of it can be
  selected across paragraphs, lists and code and copied, a line between
  blocks (Flutter runs them together). Its texts are ordered as built, not
  as laid out: screen order needs every text laid out, which a reply
  streaming while kept alive out of view isn't, and it asserted. The
  message's actions stay in the selection's right-click menu.
- **Links.** http and https URLs, in a Markdown link or bare, and Windows
  paths that exist on this device (checked once each; a `:line` suffix
  allowed), in prose or a code span. They open in the default browser,
  the default app, or Explorer. Anything else stays text.
- **The composer** mounts Voyager's own Vim, snippet and autocorrect
  sessions (`VimTextScope`), the squiggle and autocorrect-flash layers and
  Vim's overlay, as Voyager's fields do. Spellcheck and autocorrect skip
  inline code, fences (an unclosed one to the end), `[image N]`, and any
  run with a slash in it, which takes in `/commands`, paths and URLs, plus
  a bare `www.` address (`gaia_composer_text.dart`, through a `skipZones`
  hook on the shared `VoyagerSpellCheckService`, set only by the
  companion's). The `/` palette's keys are the field's own, so Enter, Tab,
  arrows and Esc reach the palette before Vim. Right-clicking a misspelled
  word offers its corrections and Add to dictionary; Voyager's Flag and
  Add snippet popovers need its database, so they stay in Voyager.
- **Settings reach the companion.** The main instance sends
  `GaiaTextSettings` (Vim and autocorrect toggles, snippets and their
  expand key, custom and flagged words) in `hello` and as `text` on every
  change. The companion checks against its own copy of the bundled
  dictionary. Add to dictionary is the pipe's `addWord`, which the main
  instance writes as its own menu does (unflagging first), so it syncs and
  comes back as `text`.
- **Checked** with unit and widget tests (`gaia_markdown_test.dart`,
  `gaia_composer_text_test.dart`, host tests), and live on the `qa`
  profile (2026-10-31, account qa-123), from a copy of the debug build:
  - the debug scripts' Markdown and code replies rendered in the Gaia
    window, copy icons and all;
  - Vim and a snippet turned on in the main instance reached the open
    companion, as did turning them off;
  - a word added from the companion came back from qa's dictionary;
  - squiggles in the composer only under the misspelled prose, not the
    command, path or label, nor the added word.

  Not checked live: typing in Vim's Normal mode (bg input also types the
  characters), clicking a link.

  The phone, checked live 2026-11-01 (profile p7a from a copy of the debug
  build, account qa-127, Android emulator): `/msg1` and `/msg3` sent from
  the phone rendered while streaming (from `gaia_live`) and once saved:
  headings, emphasis, strikethrough, inline code, a link, nested, numbered
  and task lists, a quote, a table with right-aligned cells, highlighted
  code with its language and copy button, an unclosed fence shown as code.
  A long code line scrolls sideways, and its copy button put the line on
  the phone's clipboard.

Phase 5 as built (2026-10-30):
- **Store.** `gaia_memories` (schema 181, synced, in backups): text (at
  most 500 characters), tags (lower case, no `#`, a space inside kept as
  `-`, so `#tea-time` rather than `#tea time`), `sourceChatId`, and
  status `proposed`, `active` or `archived`. A memory that says what an
  active or proposed one already says, case and spacing aside, isn't saved
  twice. Nor is a proposal (the curator's or `memory_propose`'s) of one the
  user archived, dismissed or deleted, so what they set aside isn't offered
  again; `/remember` can still save it. `[[links]]` aren't built; they wait for the graph view.
- **The index** is one line per active memory (cut at 200 characters, its
  tags after it) under a `# Memories` heading that frames them as
  background, not instructions, and points at `memory_search` and
  `memory_propose`. It goes in the session's system prompt (decided
  2026-10-30, over a block ahead of the first message, so it survives the
  CLI's own compaction):
  - Claude Code: GAIA.md and the index in the chat's own file
    (`gaia/sessions/<chatId>.md`) for `--append-system-prompt-file`,
    deleted after the process's first turn: the session keeps what it
    read, and no copy of the memories is left on disk.
  - Codex `app-server`: the thread's `developerInstructions` on
    `thread/start`.
  - Codex `exec` (the fallback): GAIA.md alone; `memory_search` still works.

  The companion sends the index only when a session starts (a new chat, a
  handoff, a session not found), and none on a resume: both CLIs keep the
  system prompt a session started with and ignore new text given on a
  resume (Claude Code 2.1.314's `--resume` with a changed file, Codex
  0.164.0's `thread/resume` with new `developerInstructions`; checked
  2026-10-30, live and with a standalone repro). So a session keeps its
  first index for good, across companion restarts and compaction, and a
  memory saved since is reached through `memory_search`. Until 2026-10-30
  the companion resent the index on a resume and restarted a Claude Code
  process over it, which changed nothing.
- **Tools.** `memory_search {query?, tags?}` returns active memories in
  full, ranked by how many of the query's words each has, at most 20, in a
  `<memories>` block framed as reference. `memory_propose {text, tags?}`
  puts one in the inbox. Both are answered by the main instance (pipe
  `memoryTool`), refuse while aborted, and change Codex's tool-set hash,
  so each `app-server` thread from before is handed over once (§19, 4C).
- **Capture.** `/remember <text>` (a built-in, in the palette, run even
  mid-reply or with a card open) saves an active memory at once with a
  toast, and never reaches the agent. While aborted the main instance
  refuses it, whatever the companion sends (an active memory steers every
  chat after it, §15.7): the toast says to rearm, and the text goes back in
  the draft. **Unlike §11**, an agent's `memory_propose` always lands in
  the inbox, even when the user said "remember that…" (decided 2026-10-30): the index is in every new
  chat's system prompt, so a memory an injected instruction planted (a
  journal entry, a web page) would steer every chat after it. The tool's
  result tells the agent it waits for the user's approval.
- **The curator.** A chat whose turn finished here is curated after 10
  minutes with no new turn: the utility model gets the turns since the
  chat's `curatedSeq` (a synced column on `gaia_chats`) and the current
  index, and answers a JSON array of at most three `{text, tags}`, each one
  fact in the first person as the user would put it ("My sister lives in
  Lisbon"), like what `/remember` saves; `memory_propose` asks for the same.
  They go
  to the inbox, or straight in with **Keep what Gaia notices without
  asking** on (`autoAcceptCurator`, synced, off by default), and the chat
  is marked read up to its last turn. A failed run marks nothing, so the
  next idle reads the turns again; so does one the main instance refuses
  while aborted. Only the device that ran the chat's
  last turn sets the timer, which stands in for the run lease until Phase
  6. The timer lives in the companion, so at start the companion looks
  for chats whose wait a quit or restart cut short: last messaged within
  7 days, last run by this device (its session's `lastSeq` is the
  chat's highest), with turns past `curatedSeq`. Those already 10 minutes
  quiet are curated one at a time, and the rest get a timer for what's
  left of their wait. Older turns are left unread.
- **The Memories tab** on the Gaia page (desktop and phone): the inbox
  (Remember, edit, Dismiss), the remembered ones (edit, Archive, Delete)
  and the archived ones (Remember again, Delete), each showing its tags,
  source chat and date. Dismiss and Delete tombstone it with Undo. The
  tab's label counts the inbox.
- **Checked** with the contract checks on the real CLIs (2026-10-30): a
  session's index in its system prompt answered from, then kept by a
  resume in a new process that gives none, on Claude Code (2.1.314) and on
  Codex `app-server` (0.164.0). Unit tests cover the store, the index and
  search, the migration, `/remember` (refused while aborted), tags, a
  resume carrying no index, and the curator's wait, read and later read.
- **Checked live in the app** (2026-10-30, profiles qa + qb, account
  qa-123): `/remember` (duplicates, empty, over the limit, mid-reply);
  the index answered from on Claude Code (Haiku) and Codex `app-server`,
  a memory saved mid-chat kept out of it, also across a killed
  `app-server`; `memory_search` and `memory_propose` (a duplicate refused);
  every Memories tab action, with Undo; memories, tombstones and
  `curatedSeq` synced to a second device; nine curator runs on time, from
  timers and at start after a quit (one overdue, one with time left),
  auto-accept on, and a timer that outlived an Abort; the 180 → 181
  migration on a real database (qa-122's 23 chats). That pass found the
  resume behaviour above, the `GaiaPipeException:` prefix on pipe errors
  (now sent as the message alone), `/remember` saving while aborted,
  third-person curator text and tags with spaces.

  Those fixes checked live (2026-10-31, profile qa): `/remember` while
  aborted refused with "Gaia is aborted. Rearm to save memories." (no
  prefix), nothing saved, and the text back in the draft for after
  Rearm; a Claude Code `memory_propose` with tags `Tea Time` and
  `#Afternoon Drinks` stored as `tea-time` and `afternoon-drinks`; a
  curator run on its timer saving first-person facts ("I am allergic to
  peanuts."). It also showed that duplicates are only caught word for
  word: the curator saved "I drink oolong tea every afternoon." beside a
  proposed "I drink oolong every afternoon". Every `/remember` toast is
  previewed in the debug menu's Remember toasts.

Phase 3 as built:
- **Images.** A user message keeps its whole text, `[image N]` tokens
  included, in one text part, with an image part per attachment after it
  (media id, label, size). The tokens say where each image goes, so search,
  titles and handoffs read the text as it was written. Labels count across
  the chat, so a later message's image 1 never means an earlier one's; a
  draft's images are renumbered from the chat's on send, and a token the
  user deleted goes back at the end. Paste (Ctrl+V with an image and no
  text) adds one. Each image is one media reference owned by its **chat**,
  not its message, so a chat's delete puts its images on the chat's 30-day
  clock and Undo or a trash restore brings them back. Ingest stores them
  as it stores every image (2048 px on the long edge, JPEG unless
  transparent), and that stored file is what the agent gets. Claude Code
  takes base64 image blocks over stream-json and Codex takes
  `--image=<path>` per image plus a line naming the labels in order; both
  verified on 2.1.310 and 0.164.0.
- **Images in a handoff** (added 2026-10-26). A transcript lists each
  image under its message as `[image N] (<local file>): <caption>`.
  Images from summarised turns are listed after the summary, and the
  summariser gets the captions too. An image whose bytes aren't on this
  device says "file not on this device". The caption is the utility
  model's description (under 80 words), covering text in the image and
  what any marks point at. It's written when the message is sent, in the
  background, and stored on the image part (`caption`), so it syncs and
  is written once. A handoff waits up to 20 s for captions it still lacks,
  three messages at a time; that covers images sent before captions
  existed. Past that it goes with paths alone, and the captions keep going
  for the next handoff. An image whose captioning failed isn't tried again
  until Gaia restarts, so a broken utility model holds up one handoff, not
  every one. Neither CLI
  needed new permissions for the paths: Claude Code in safe mode reads an
  image outside its working directory with Read, and Codex opens one with
  its image viewer (both checked on 2.1.310 / 0.164.0, 2026-10-26).
  Re-sending the images themselves was rejected, because it costs about
  1.5k tokens per image on every handoff.
- **Captures.** The main instance grabs the monitor under the cursor with
  GDI (BitBlt with CAPTUREBLT) on a worker isolate, as a 32-bit BMP in
  `gaia/captures`, swept after an hour, and sends the companion its path
  and the monitor's frame. D attaches it whole. C turns the window into a
  borderless overlay over that monitor showing the frame at 1:1: drag
  crops, Enter takes the whole screen, Esc or any Gaia hotkey cancels. A
  BMP or an edited image is rendered to PNG by the companion on send,
  since the media module takes only PNG, JPEG, WebP and HEIC.
- **Annotation.** Clicking a draft thumbnail opens the editor (on the
  large floater when it was the small one): pen, highlighter (multiply),
  line, arrow, rectangle, ellipse, blur, redact (a solid box, since a blur
  can leak what's under it), crop, three widths, six colours, undo and
  redo. Marks are kept in image pixels over the untouched original and
  flattened on send.
- **Window context.** Every summon reads the foreground window with Win32
  at once (app name from the exe's version resource, title), then the
  browser address bar (first Edit or ComboBox, not on the page: BUG-347) and the focused control's
  selection through UI Automation within 250 ms, and sends them after the
  summon as a removable chip. The chip goes with the next message only, as
  a context part and a framed `<focused_window>` block ahead of the prompt.
  Settings: on by default, and an exclusion list matching an app name, exe
  name or site host (password managers by default). An excluded window
  sends neither context nor selection.
- **Selection.** E reads the selection through UI Automation and falls
  back to Ctrl+C once the hotkey's modifiers are released, never into a
  console and never from an excluded app or site. The copy is the source app's, so it still lands in Win+V
  history; only the restore of the user's clipboard carries the exclusion
  marker. The quote goes at the end of the draft as `From App — Title:`
  and `>` lines. F hides Gaia behind a non-activating "selecting" pill at
  the top of the screen; F again quotes the selection and puts Gaia back
  where it was, and Esc (a global hotkey only while armed) or the pill's
  button cancels. Default keys: C Ctrl+Alt+S, D Ctrl+Alt+Shift+S, E
  Ctrl+Alt+Q, F Ctrl+Alt+Shift+Q. Aborted, all four refuse.
- **Checked live (2026-10-26)** on one 2880×1800 monitor, over Notepad and
  Chrome: the GDI capture, the crop overlay at 1:1, annotation, a send with
  an edited image to Claude Code, window context with a browser's URL,
  E through UI Automation (Notepad) and through Ctrl+C (Chrome, which
  exposes no TextPattern) with the clipboard put back, F and its Esc,
  paste (PNG and bare CF_DIB), and the aborted refusals. That check found
  and fixed: F crashing the main instance (the Esc hotkey's null modifier
  list aborts the Windows hotkey plugin), the address-bar read crashing it
  on any browser (the UIA condition passed by its slot, not itself), the
  overlay's frame scaled by its window's resize borders, bare-`\r` line
  breaks in quotes (RichEdit's), a draft thumbnail ignoring its edits, and
  a blur over a small box letting the sharp image show through. Not
  checked live: Win+V history around the clipboard restore, the exclusion
  list, several monitors, the capture sweep and images on Codex.

Phase 2 as built: a native session that missed turns gets them as a
Gaia-rendered transcript before the user's message, newest 60k characters
verbatim and older ones summarised by the utility model (or noted as left
out). That covers a vendor switch, a switch back (only what it missed) and
a device with no session yet. A message that ends in `/deep` waits for the
§7.5 confirmation, and a turned-down switch keeps the message in the
composer. The context size in that dialog comes from Claude Code's
per-request usage. Codex reports only whole-turn totals, so after a Codex
reply the dialog leaves the size out.

Phase 1 as built: the drift tables are `gaia_chats`, `gaia_messages` and
`gaia_settings`, plus an FTS5 table for search. A message uploads once it
stops streaming. A chat continued on another device starts a new native
session there, which since Phase 2 gets the earlier turns as a handoff
preamble (§7.4); the run lease came with Phase 7.
A message whose parts encode to over 800 KB uploads them as JSON pieces in
`gaia_message_chunks` (`{messageId}_{n}`), written before the message, which
keeps only `partChunks`. An erase deletes the chunks. The update drain runs
on every quit, and `scripts/build_release.ps1` waits while the companion
drains. Hotkeys were fixed until Phase 2 made them rebindable.

---

## 20. Decisions and open questions

Decided in review (2026-10-24):
- Gaia's data lives in Voyager's drift DB and syncs normally (ADR 004
  amendment).
- `desktop_multi_window` is not used.
- Chats can bind to a workspace folder and load that repo's instruction files
  (§5.2).
- Tiers are Quick / Standard / Deep. The router picks only the first message,
  and nothing switches automatically after that (§6.5, §7).
- Cross-vendor handoff loss is acceptable, behind the §7.5 confirmation.
- Multiple accounts per provider are fine. Anthropic's terms allow one person
  several accounts and prohibit only using them to evade bans or policy.
- Live streaming uses Firestore, not Realtime Database (§8.1–8.2).
- An always-on beacon machine is in scope (§12.2).
- Focused-window context ships, on by default (§15.4).
- Abort replaces panic (§15.7), on Ctrl+Alt+Backspace. Walkthroughs and
  nudges are out. Push-to-talk is a later phase.
- Gaia is floater-first: small and large floaters stay out of Alt+Tab, and
  the dedicated Gaia window appears in it (§3.3).
- Live streaming carries only agent text and a status line, never tool
  activity (§8.1).

- One window at a time for v1 (§3.3). A floater hotkey turns the Gaia window
  into the floater, and opening the Gaia window turns a floater into it.
- A structured question holds the agent for up to an hour before it falls
  back to a turn-ending pending question (§10.1). Cache expiry is accepted.

Decided in the second review (2026-10-24):
- Approve-before-write covers Voyager data. Workspace chats run under the
  user's own CLI permissions, Auto mode included, locally and remotely
  (§1, §5.2, §12.2).
- Remote commands come only from paired devices and are signed (§12.2).
- Gaia tools are served over a stdio MCP shim, with no localhost port (§5.3).
  The pipe is restricted to the user and checked by PID (§3.2).
- The utility model is Haiku on Claude Code, on the user's own login, so
  no API key or third-party data terms are involved (§5.1, revised
  2026-10-25).
- `voyager.*` reads are off by default in workspace chats. Vault content is
  never returned (§5.3).
- Native sessions are tracked per device and caught up with a delta preamble
  (§7.4). A run lease serialises runs across devices (§8).
- Images go through the media module (§8).

Decided for Phase 9 (2026-11-01):
- The Phase 9 split (§19).
- `os.*` tools never target Gaia. If Gaia is in the foreground, they use the
  next window in Z-order (§15.6).
- The focused-window exclusion list (§15.4) applies to `os.*`, so an agent can't
  read a window the summon-time context refuses to touch (§15.6).
- Screen text as prompt injection. With *can control* on, text on a web page can
  steer an agent that can click, and §5.3's framing is only a mitigation, so the
  step list is the real boundary. A batch can be approved once only if it shows
  each step's window and resolved control, or its coordinates, and a run stops if
  the window changes (§15.6).
- `os_*` tools refuse Voyager's own windows while its vault is unlocked (§19).
- Turning on *can see screen* shows a one-line warning, each time and in every
  chat, since no chat is kept from its CLI's shell or web tools: workspace chats
  don't exist yet, so §5.3's default-off doesn't apply here (§15.6).
- A phone can deny a step list but not approve one, and the border's label names
  the chat (§19).

Amended 2026-11-04 (GAIA_AUTONOMY_HLD.md §9): the two decisions above on screen
text and the phone hold for Ask, which exists for the reason they give. A chat in
Auto gives up the step list as a boundary, by the user's choice per chat and after
a notice: text on a page can steer its agent, and a prompt from the phone acts with
no one at the screen.

To verify against current CLI versions at the start of the phase that needs
them: Claude Code's
auto-compact override, and the usage call for
Gemini CLI (§6.2). Codex's usage call was confirmed in Phase 8A. Codex
`app-server` vs `exec` was evaluated in Phase 4B and built on in 4C (§19).

Checked before Phase 8B: each provider's consumer terms on switching between
one person's accounts when one runs low (§6.5), not just on owning several.
Juno checked them and gave the green light (2026-11-01).
