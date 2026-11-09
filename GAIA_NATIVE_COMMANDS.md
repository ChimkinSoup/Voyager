# Gaia — CLI-Native `/` Commands (HLD)

Status: **Built 2026-11-08, with unit tests and live checks of both runners and the
companion's UI (§9).**
The CLI behaviour it relies on was checked on Claude Code 2.1.319 and Codex 0.166.0. Both
are FRAGILE(cli): re-check §3 to §6 when a CLI version moves.

## 1. Summary

Gaia's `/` palette lists Gaia's own commands: built-ins, tiers, account aliases and the user's
commands (GAIA_HLD.md §9.2). It now also lists the commands of the CLI the next message runs
on, and runs them there.

- **Claude Code: pass-through.** A message that starts with one of its commands goes to the
  CLI as typed, and the CLI runs it. Gaia keeps out a fixed list of commands that would put it
  out of step with the session, change settings or cost money (§4).
- **Codex: mapped.** Codex's app-server runs no `/` commands from text, so Gaia maps two
  kinds: `/compact` becomes `thread/compact/start`, and a skill goes as a skill input (§6).
- **`/compact` is the CLI's, on both.** Gaia never got its own `/compact` (GAIA_HLD.md §9.2
  and §16 listed one). It goes to the CLI.
- **An unknown `/word` isn't sent** on the first try (§7). It stays in the draft with a line
  saying so and suggesting the closest command. Tab takes the suggestion, and sending again
  unchanged sends it as typed.
- **Gaia's own commands win any name clash.** For example, Claude Code's `/new` is an
  alias of its `/clear`, but `/new` stays Gaia's. `/clear` and `/reset` are aliases of Gaia's
  `/new` too, so they never reach the CLI from the composer.

## 2. Decisions at a glance

| Decision | Choice | Why |
|---|---|---|
| Which Claude commands to offer | Everything the CLI lists, minus a blocklist (§4) | The list changes with versions and skills. A fixed allowlist would go stale |
| Where the Claude list comes from | The `initialize` control response (§3) | It arrives before any message, with descriptions and argument hints |
| What a Claude command carries | The typed text only: no window context, quotes, files, images or handoff (§5) | The CLI reads a command only when it starts the message |
| A command with attachments | Refused, with the draft kept (§5) | Sending the attachments as arguments would break the command |
| Catching up a new session | A command refuses to run (§5) | The handoff text would go ahead of the command |
| Output of commands the CLI runs itself | Shown as the reply text (§5) | They stream no text deltas, so Gaia would show an empty reply |
| Codex `/compact` | `thread/compact/start` (§6) | Sent as text, the model just claims it compacted |
| Codex skills | `skills/list`, then a `skill` input plus the typed text (§6) | That's how Codex attaches a skill's instructions |
| Unknown `/word` | Held once, with a suggestion; sent as typed on a second send (§7) | It catches typos without blocking a draft that happens to start with a slash |
| `/btw` | Build Gaia's own (§8) | Claude Code's isn't available headless, and Codex has none |

## 3. Discovery

**Claude Code.** Gaia already sends an `initialize` control request when each process starts
(claude_code_runner.dart). Its response lists every command as
`{name, description, argumentHint, aliases?, builtin}`, before any message is sent.
`ClaudeCodeRunner.nativeCommands` starts a process just to hear this response, then kills it.
That takes about 0.7 s and calls no model. No message goes, so no session file is made
(checked). The result is cached per config dir for the companion's lifetime, and an empty
read is retried after a minute. A read that throws counts as empty, so it's retried too.

**Safe mode limits the list.** Gaia runs Claude Code with `--safe-mode`, which leaves out
plugins and the user's own commands and skills. Only Claude Code's bundled commands and
skills are listed: 53 on 2.1.319, 25 after the blocklist. A custom command in
`~/.claude/commands` or a project's `.claude/commands` isn't available in Gaia. The CLI
confirms it: "custom skills are disabled in safe mode". Lifting this would mean revisiting
why Gaia runs in safe mode (GAIA_HLD.md §5.2).

The `system/init` event also lists `slash_commands` and `skills`, but only after a message,
and without descriptions. It isn't used.

**Codex.** `CodexAppServerRunner.nativeCommands` calls `skills/list` for Gaia's working
directory on the account's app-server, and returns `/compact` plus the enabled skills. These
come from the account's Gaia-owned Codex home and `~/.agents/skills`, with their short
descriptions. No other Codex commands exist over the app-server. There's no request for
custom prompts, which Codex seems to have folded into skills.

**In the controller.** `GaiaController.nativeCommands` is the list for the agent and account
the next message runs on (`agentFor(nextTier)`, `currentAccount`). It's null while being read,
and empty for a runner without `GaiaNativeCommander`. The palette shows these after Gaia's
rows, skipping any name Gaia already uses. Sending reads the list only for a draft that
starts with `/`, so an ordinary first message starts no extra process.

## 4. Claude Code blocklist

`kClaudeBlockedCommands` in claude_code_runner.dart holds each blocked command, aliases
included, with its reason. Blocked commands never appear in the palette. The runner also
refuses one typed past the palette, with the reason as the error reply.

The blocklist came from running every command headless with Gaia's flags (2026-11-08,
2.1.319). Settings files were snapshotted before each run and diffed after. What each one
did:

| Command | Headless result | Decision |
|---|---|---|
| `/compact [focus]` | Compacts; emits `compact_boundary` with token counts; result text empty | **Allowed**, shown as "Compacted: X → Y tokens." |
| `/context` | Local table of context use | Allowed |
| `/usage` (`/cost`, `/stats`) | Local plan usage | Allowed |
| `/recap` | Local one-line recap | Allowed |
| `/skill-doctor`, `/reload-skills` | Local reports | Allowed |
| `/list-agents` (`/peers`) | Lists other Claude sessions on the machine | Allowed |
| `/doctor`, `/insights`, `/team-onboarding`, `/security-review`, `/debug`, `/schedule` | Run through the model, with tools behind Gaia's permission cards | Allowed |
| Bundled skills (`/code-review`, `/simplify`, `/dataviz`, …) | Expanded into the prompt; the model runs them | Allowed |
| `/clear` (`/reset`, `/new`) | Emits `conversation_reset` with a **new session id**; the next `--resume` of the old id carries on the old conversation | **Blocked**: Gaia would keep resuming the old session. Typed in the composer, `/clear` and `/reset` are Gaia's `/new` |
| `/model <x>`, `/effort <x>` | "for this session only"; Gaia passes `--model`/`--effort` on every process start | **Blocked**: undone silently at the next restart. Tiers own these |
| `/advisor` | Session setting | Blocked, for the same reason |
| `/fast` | "not available in the Agent SDK" | Blocked: does nothing |
| `/focus`, `/color` | "isn't available here" / colours the terminal | Blocked: does nothing |
| `/rename` (`/name`) | Renames the CLI session; every later turn emits `session_title_changed` | Blocked: Gaia names its own chats |
| `/config` (`/settings`) `key=value`, `/output-style <x>`, `/autocompact <n>` | Write Claude Code settings | Blocked: they'd change every Gaia chat |
| `/mcp disable …` | Turns MCP servers off | Blocked: it could turn off Gaia's own tools |
| `/init` | Writes a CLAUDE.md to the working directory | Blocked: Gaia's workspace is shared by every chat |
| `/import` | Copies other agents' settings into Claude Code's | Blocked |
| `/design*`, `/usage-credits`, `/extra-usage` | Account consent and billing | Blocked |
| `/ultrareview` | Paid cloud review | Blocked (not run) |
| `/loop` | Recurs inside the process | Blocked: it dies with Gaia's 10-minute idle kill (not run) |
| `/goal` | Keeps working until a condition holds | Blocked: runs past Gaia's turn model (untested with a condition) |
| `/auto-mode-setup` | Configures permission auto mode | Blocked: Gaia answers permission prompts itself |
| `/heapdump`, `/agents`, `/reload-plugins`, `/__remote-workflow`, `/workflow-launch-exec` | Debug-only, removed, no plugins in safe mode, cloud-only | Blocked |

`terminal_slash_commands` in `init` (`doctor`, `color`, `focus`, `reload-plugins`) isn't the
list of commands that don't work: `/doctor` and `/reload-plugins` both ran. Gaia's blocklist
is its own.

## 5. Claude Code: sending a command

A draft that starts with `/name` (a space or the end after it) for a CLI row the palette
offers is a native command (`gaiaNativeIn`). A name Gaia also uses (a user command, tier or
alias) stays Gaia's, as in the palette. Then:

- **It goes as typed, alone.** The CLI recognises a command only at the start of the
  message, so Gaia's preambles can't go ahead of it:
  - The summon's window context isn't sent, and it isn't used up: it stays for the next
    message.
  - Quotes, a `/this` control, files or images refuse the send. The draft and attachments go
    back, with a note to send them with the next message.
  - A turn that would need the session caught up (a new session for a chat with history, as
    after an account or agent switch) fails with "… hasn't caught up on this chat yet. Send
    a message first." Sending the command anyway would put the handoff text ahead of it.
- **The router is skipped** in a new chat. The command belongs to the CLI whose palette row
  it came from.
- **The prompt keeps its uuid.** The `uuid` Gaia sends becomes the uuid of the command's
  own session entry (checked). Rewind, fork and take-back still find it. The entry reads
  `<command-name>/x</command-name><command-args>…</command-args>`, with the expansion as a
  following `isMeta` entry.
- **The output becomes reply text.** Commands the CLI runs itself reply with a synthetic
  assistant message and the `result` text. No `stream_event` deltas come, and Gaia only reads
  text from deltas. When a successful turn whose prompt starts with `/` streamed no text, the
  runner emits the result's text as the reply (`claudeCommandOutput`). The `/` check keeps an
  ordinary tools-only turn that auto-compacted from showing a "Compacted" reply. For `/compact`, which has an empty result, it
  shows the `compact_boundary` token counts. The messages `/compact` replays after compacting
  are whole messages, so Gaia already ignores them.
- **The stored message is the typed text.** A user command is stored as its expansion
  (§9.2), but here the expansion happens in the CLI, so the chat shows `/usage`.

## 6. Codex: mapped commands

- **`/compact`** → `thread/compact/start {threadId}` (`CodexAppServerClient.send(compact:
  true)`). It runs as a turn: `turn/started`, then a `contextCompaction` item, then
  `turn/completed`. The turn id comes from `turn/started`, since the request returns `{}`. The
  reply shows "Compacted.". Codex's compact takes no instructions, so `/compact <text>` is
  refused. With no thread yet there's nothing to compact, and it says so. The `codex exec`
  fallback can't compact, and says so.
- **Skills** → `turn/start` with `{type: skill, name, path}` before the text input. The text
  keeps the `/name …` as typed. Live, the model followed the skill's instructions. The runner
  sends by the skill list its last `nativeCommands` read. Before that, a skill goes as plain
  text, and Codex may still pick it by its description.
- **Why not pass-through:** sent as text, `/compact` got the reply "Context compacted." with
  no compaction done. That's the harm pass-through would do on Codex.

## 7. Unknown `/word`

Before this, a draft like `/quee fix the tests` went to the agent as a real turn. It used up
quota, the CLI tried to make sense of `/quee`, and the queue never got the text.

- **What counts:** a draft whose first token is `/word`: letters, digits, `_` or `-`, then a
  space or the end (`gaiaUnknownCommand`). It's unknown when no palette row has that name:
  Gaia's built-ins, tiers, aliases, user commands, and the CLI's own. `/usr/bin` and
  `/etc/hosts` don't count, since the second slash ends the match. `look in /etc` doesn't
  count either, since the slash isn't first. `/etc is weird` does count, and the second send
  lets it through.
- **What happens:** `_submit` doesn't send. A line above the field reads "Unknown command
  /quee. Did you mean /queue? Tab uses it; send again to send as typed." The suggestion is the
  palette's own top fuzzy match, or failing that, the name at most two edits away (`/usgae` →
  `/usage`). With neither, the line says only that the command is unknown.
- **Overriding:** sending again with the draft unchanged sends it. Any edit clears the line
  and arms the check again.
- **While loading, held:** while the CLI's list is still being read
  (`nativeCommands == null`), a `/word` none of Gaia's own rows name isn't sent. Sent then, a
  valid `/compact` would go as text behind the window context, and the CLI wouldn't run it.
  A line reads "Reading Claude Code's commands. Send again in a moment." It goes once the
  list is in or the draft changes, and the next send then runs the normal check. Gaia's own
  commands and ordinary text are never held. Mid-reply neither check runs, since send is
  then the stop button.
- **Aliases aren't known:** Claude Code's `/cost` is an alias of `/usage`, but the palette
  only has names, so `/cost` gets the unknown line. Sending again works, since the CLI knows
  the alias. Gaia's own aliases are known: `/clear` and `/reset` are its `/new`.

## 8. `/btw`

Claude Code's `/btw` (a side question that doesn't enter the conversation) isn't in the
headless command list. Sent anyway, it replies "/btw isn't available in this environment."
Codex has no equivalent request. **Build Gaia's own `/btw`**, as planned. No blocklist entry
is needed: the CLI doesn't list it, and a Gaia built-in wins a clash anyway if a later
version adds it. Gaia's native fork (GAIA_FORKING_HLD.md) is a natural base: fork the
session, ask there, and throw the fork away.

## 9. Testing

- **Unit tests:** test/gaia_commands_test.dart (palette clash rule, `gaiaNativeIn`, the
  unknown check with paths and typos); test/gaia_claude_code_events_test.dart (a new real
  fixture, `native_commands.jsonl`: the `initialize` command list, a local command streaming
  nothing, `/compact`'s boundary, the blocklist); test/gaia_codex_app_server_test.dart
  (compact as its own turn, `skills/list` parsing). The fixture's account block is redacted.
  All 1400 Gaia tests pass.
- **Live, Claude Code runner** (throwaway test, 2026-11-08): discovery returned 25 commands
  in 689 ms with none blocked; `/reload-skills` came back as reply text; `/clear` was refused
  with its reason; `/compact` showed "Compacted: 21.1k → 3.6k tokens."
- **Live, Codex app-server** (Python over stdio, 0.166.0): `skills/list`, a skill input, text
  `/compact` faked, and `thread/compact/start` compacted. Gaia's `CodexAppServerRunner` path
  itself isn't tested live.
- **Live in the companion** (2026-11-08, `gaiaqa`, debug build of the working tree, bg input):
  all passed.
  - Palette: `/co` lists `/code-review`, `/compact`, `/context` and others with descriptions;
    clicking `/compact` inserts `/compact `.
  - Claude: `/usage` as a new chat's first message came back as the reply. `/compact` showed
    "Compacted: 22.1k → 3.8k tokens.", and the next turn still knew the topic.
  - Codex: `/compact` showed "Compacted." and the rollout has a `compacted` item.
    `/apple-design …` went as a `skill` input with the `<skill>` body injected, and the model
    answered from it.
  - Unknown: `/usgae` held with "Did you mean /usage?"; Tab took it. `/zzqx …` held without
    a suggestion, then went as typed on the second send.
  - `/clear` shows the `/new` row and starts a new chat; `/reset` does the same.
  - Hold: with the list forced to "being read", `/compact` showed "Reading Claude Code's
    commands." and wasn't sent.
  - A command with a file attached was refused ("Send /usage on its own"), with the draft
    and file given back. Tried with a file, not a quote: the same check covers both.
  - Catch-up: tried after an agent switch (a Claude chat moved to Deep), not an account
    switch; `/compact` failed with "Codex Sol hasn't caught up on this chat yet…".
  - **A harness artefact, not a bug:** with the window parked off-screen, the header, sidebar,
    Stop button and message list sometimes kept old state after a turn or a chat switch. On
    a visible window they updated at once, whether Gaia was focused or not, after a turn
    and after a chat switch.

## 10. Open items

- **User and project commands in Claude Code:** blocked by safe mode (§3).
- **Arguments and attachments:** a skill that would take a file has to get the path as typed
  text. Attachments are refused rather than sent after the command.
- **Remote sends** (paired devices) aren't checked for native commands. A Claude command
  from Android still runs, since the text goes through unchanged, but without the
  window-context rules in §5.
- **Rewind or fork at a Codex `/compact`:** `thread/compact/start` takes no
  `clientUserMessageId`, so `turnOf` can't find that turn. Rewind or fork there falls back to
  handing the chat over. Left as is: it's safe, and forking right at a compaction is rare.
  Saving the compaction's turn id against the message would fix it.
- **Aliases** (§7) and **argument hints** in the palette: names only; hints are shown in the
  description.
