# Gaia — `/btw` Side Questions (HLD)

Status: **Phase 1 built (2026-11-09), except the Gaia page's and the phone's read-only
view (§8.3). Phase 2 built (2026-11-09), §10.3; its live tests in the app are still to
run.** Builds on forking (GAIA_FORKING_HLD.md) and
rewinding (GAIA_REWIND_HLD.md), both done and live-tested, and replaces the plan in
GAIA_NATIVE_COMMANDS.md §8. Claude Code's own `/btw` isn't available headless, and Codex
has none, so this is Gaia's own.

## 1. Summary

`/btw <question>` asks a side question about the chat without it entering the chat. The
answer shows in a btw panel docked under the chat, never in the transcript, and the main
conversation's sessions never see it.

- **It sees the chat as it is now**, and every earlier btw of the same chat that hasn't
  been cleared (§4).
- **It can be asked while a reply streams.** That reply isn't disturbed (§5).
- **It can't act.** No tools of any kind: it only answers (§6).
- **`/btw` alone opens the panel** at the chat's last btw. `/btw <question>` asks and opens
  the panel at that one. In the panel you can move between the chat's btws, and copy or
  fork any of them (§8).
- **Forking a btw continues it as a chat** (§7): a new chat holding the source chat up to
  where the btw was asked, then that btw's question and answer.
- **History is per chat, synced across devices, and can be cleared** with `X` in the panel
  or its button (§4.2).
- **Search finds btws; the memory curator doesn't read them** (§9).

## 2. Where a btw lives

A btw isn't a message. It goes in its own table and collection, **`gaia_btw`**, one doc
per btw.

| Field | |
|---|---|
| `id` | uuid v4 (`newId()`), also sent as the btw prompt's stream-json `uuid` |
| `chatId` | the chat it was asked in |
| `question` | text only (§8.4) |
| `answer` | the reply's text, Markdown; empty while it streams |
| `status` | `streaming` / `complete` / `error` / `cancelled`, as messages |
| `error` | why it failed |
| `anchorSeq` | the chat's last message the btw saw as chat history (§5) |
| `tier`, `model`, `adapter`, `account` | what answered it, as on a reply |
| `deviceId`, `device` | the device answering it, and its name (the beacon's, else the host name), for "Answering on Laptop…" and for ending only this device's streaming btws when its companion restarts |
| `session` | `{sessionKey, sessionId}`: the btw's own CLI session, for forking it (§7). Device-scoped like `agentSessions`: other devices ignore it |
| `createdAt`, `updatedAt`, `version`, `deletedAt` | as every synced table |

**Why not messages with a flag.** Everything that reads messages would need a filter:
handoff, `gaiaUnseenTurns`, `lastSeq`, the curator, chapters, fork and rewind copies, the
message list, notifications and search. Missing one leaks a btw into the main context,
which is the one thing a btw must never do. In its own table, a btw reaches only what is
written to read it.

- **Synced through the normal outbox**, like `gaia_queue`: a new entry in
  `FirestoreCollections`, `OutboxSyncWorker` and `RemoteSyncService`. It follows the
  snapshot path, since a btw is immutable once it stops streaming, apart from soft delete.
- **It isn't live-streamed** to other devices (no `gaia_live` writes). The row syncs as
  `streaming`, then again when it's done. Another device shows "Answering on Laptop…".
- **Size.** A tool-less answer is short. The synced `answer` is cut at the same size a
  message spills at (GAIA_HLD.md §8); the local row keeps all of it.
- **Deleting or purging a chat** takes its btws with it.

Drift: `GaiaBtwTable`, with an index on `(chatId, createdAt)`, a migration, and a
`GaiaBtw` model in `gaia_models.dart`. Repository: `watchBtws(chatId)`, `putBtw`,
`clearBtws(chatId)`, `restoreBtws(ids)`.

## 3. Asking

`/btw <question>` is a new `GaiaBuiltin`, `btw('btw', 'Ask a side question about this
chat')`, which takes the rest of the draft as `/queue` and `/remember` do
(`gaiaBtwText`). `/btw` alone is matched by `gaiaBuiltinIn` and only opens the panel.

On send:

1. The btw row is written (`streaming`) and the panel opens at it. The composer is
   cleared, as after any send.
2. The btw's context is chosen (§5): native fork, or handoff.
3. Its prompt is the btw preamble (§4.1), then the question.
4. It runs as its own run, keyed **`btw:<btw id>`** on the runner (§5.3), with no tools
   (§6).
5. Text events stream into the row's `answer`. When the turn ends, the row is completed
   with `model`, `session`, and so on, or set to `error`.

- **It needs no `runLease`.** A btw doesn't touch the chat's sessions or seqs, so any
  device can ask one while another runs the chat. That device answers it.
- **Several btws can run at once**, each its own run. One asked while another is still
  streaming doesn't see it in its history.
- **Stop.** Esc closes the panel and doesn't stop the btw. The panel's stop button
  (shown while the selected btw streams) stops it: `cancelled`, with the text so far
  kept. The chat's stop button never stops a btw, and a btw's stop never stops the chat.
- **A notification** when a btw is answered or fails, by a reply's rules (`notifyOnDone`,
  §14): a Windows toast while Gaia is hidden or behind other apps, else Gaia's own toast,
  unless the panel is showing that btw. A stopped one raises none. Clicked, it opens
  the btw.

**Must hold mid-reply.** While a reply streams, send (Enter or the button) is the stop
button. `/btw <question>` must always go as a btw, never be queued or stop the reply: the
composer's `_submit` takes it with `/remember` and `/queue`, before the mid-reply stop.
The button is the reply's stop mid-reply, wired to `stop` rather than `_submit`, so
while the draft is `/btw <question>` it's the send button instead (found live,
2026-11-09: clicking it stopped the reply and took its prompt back). The same goes
for `/queue <text>` and `/remember <text>`, which had the same bug.

## 4. History

### 4.1 What a btw sees

A btw's prompt starts with a preamble of the chat's **earlier, uncleared, complete btws**,
oldest first:

```
Side questions asked earlier in this chat, beside the conversation rather than in it.
You answered each in a separate side thread, so you won't remember them, but these
are your own answers, recorded as you gave them:
Q: …
A: …

Now answer this side question briefly. You have no tools; answer from what you know
and what's in this conversation. It won't be added to the conversation.
<question>
```

- **Capped** at `kGaiaBtwHistoryChars` (start at 8 000). Past that, the oldest go first,
  whole: a btw is never cut in half.
- **Failed and cancelled btws are left out.**
- **The answers are told as the model's own.** Each btw ran on a fork of its own, so
  the next one doesn't remember them. Headed only "not part of the conversation",
  Haiku and Codex took them for made-up claims about their replies and argued with
  them (live, 2026-11-09). Told they're its own, it stops arguing and uses them, but
  still notes it can't see those threads. Adding "recorded by Gaia, not written by
  the user; no caveats" changed nothing: the preamble is in the user's turn, so it's
  read as the user's. Going further would mean moving the history out of that turn.
- **Mid-reply, the reply so far** follows P_live as "Assistant (in progress)". With
  nothing streamed yet, the prompt says the reply has only just started, rather than
  pointing at a reply below that isn't there.
- **While the chat stays put, btws chain instead (Claude Code).** Claude Code's own
  `/btw` sends its earlier btws as real user and assistant turns, so the model owns its
  answers and corrects them ("a correction to my previous answer…"). Gaia gets the same
  by forking the **newest earlier btw's own session** rather than the chat's, when:
  - it has a `session` with this device's key on the routed account;
  - it was asked at this same `anchorSeq`, and the anchor message isn't newer than it
    (no rewind since);
  - every other earlier btw had ended (`updatedAt`) before it was asked, so its
    session already holds them.

  Its session is the chat up to the anchor, then each earlier btw as turns of its own,
  so the prompt has no text preamble and no catch-up. The cut is `forkCut(after: <its
  id>)`, its session's end. A chain the CLI refuses falls back to the chat's fork with
  the preamble, then to handoff, with nothing said. Checked live (2026-11-09, Haiku and
  Sonnet): each btw resumed the previous btw's session. Asked to list its earlier
  answers, it said "I've said: 1… 2…" without caveats. Mid-reply, asked to compare a
  predicted outline with what got written, it said "I predicted X. The essay has Y".
- **Otherwise, as text.** Once the chat has moved on (a new turn, a rewind), the chain's
  turns would sit before the chat's newer ones, so the btw forks the chat's session and
  gets the preamble above. On Codex, which records no btw session, it's always text.

### 4.2 Clearing

- **Alt+X with the panel open, or its "Clear history" button**, clears **all** of the chat's btws:
  each row gets `deletedAt`, and that syncs. A btw still streaming is stopped first.
- **An "Undo" toast** follows, which restores them (`restoreBtws`). Alt+X is one key away
  from everything else in the panel, and the clear syncs everywhere, so it gets undo
  rather than a confirm dialog.
- **A cleared btw is gone from everything**: the panel, later btws' history, and search.
- `/new` (and `/clear`, `/reset`) starts a new chat, so it starts with no btw history.
  The old chat keeps its btws.
- Rewind and compact don't touch btws. A btw that talks about turns a rewind dropped
  still makes sense as a record of what was asked then.

## 5. The btw's view of the chat

### 5.1 Native fork (Claude Code, and Codex through `thread/fork`)

A btw is a native fork of the chat's session, cut at "now", made on the btw's first and
only turn, with the same `GaiaForkCut` forks use (GAIA_FORKING_HLD.md §5.3):

```
claude --resume <chat's session> --fork-session --resume-session-at <keepAt> …
```

| The chat is | `keepAt` | `anchorSeq` | Also in the preamble |
|---|---|---|---|
| Idle | the session's last entry with a `uuid` | the chat's last message | nothing |
| Mid-reply, prompt P_live | `parentUuid` of P_live's entry | the message before P_live | P_live, and the reply streamed so far, marked as in progress |

- **Mid-reply, the cut goes before P_live** as forking at P_live does
  (GAIA_FORKING_HLD.md §3), not at the live tail. The tail can end between a `tool_use`
  and its result. P_live and the text so far go in the preamble instead, so the btw can
  answer about what Gaia is doing right now. If P_live hasn't reached the session file
  yet, the same few-second wait applies, then handoff.
- **The source session is never touched.** `--fork-session` writes a new file, and the
  btw's run is its own process (§5.3).
- **Same model as the chat's tier.** A fork of the same prefix on the same model should
  hit the prompt cache, so a btw on a long chat costs little to start.
- **Used only when forking's §5.5 conditions hold**: this device has a session for the
  chat whose `lastSeq` reaches `anchorSeq`, the cut entry is found, and the routed
  account's adapter is the session's (copied across accounts with `copySession`, as
  forks are, §5.4 there).
- **The fork check after the turn** (`_checkFork`) runs as for a chat fork. If the cut
  didn't hold, the btw still answered. Its row gets a notice, and forking it (§7) falls
  back to handoff.

### 5.2 Handoff (fallback)

When the native fork can't be used (another device ran the chat, the chat has no session
on this device, the fork is refused before `init`, or the adapter can't fork), the btw
runs as a new session whose prompt carries the chat's transcript, through
`gaiaHandoffPreamble` (`joining: true`), up to `anchorSeq`, then the btw preamble.

- Its context is the rendered transcript (no tool calls or results, a long chat partly
  summarised), as handoff always is.
- A chat with no messages yet just asks the question with the btw preamble.

### 5.3 Runs keyed by btw

Runners key everything by `chatId` (`send`, `isRunning`, `stop`, `_live`). A btw passes
**`btw:<btw id>`** as its `chatId`, so it never shares a process with the chat or blocks
the chat's next send, and `stop(chatId)` for the chat never reaches it.

Checked while building: neither runner looks a `chatId` up as a real chat. Rewind maps
and `takeBack` are only ever keyed by the chat's own sends. Claude Code names a file
after the key only for a session's own instructions (`sessions/<chatId>.md`), which a btw
never has (and `:` can't be in a Windows file name).

## 6. No tools

A btw only answers.

- **Claude Code:** no `--mcp-config` (none of Gaia's host tools) and `--tools ""`, which
  leaves none of the CLI's own (its `init` lists `tools: []`, checked on 2.1.319, through
  `cmd /c` as the runner starts it). A `toolless` flag on `send` says so, and the btw's
  process is killed once its turn ends.
- **Codex:** `thread/start` with `approvalPolicy: "never"`, `sandbox: "read-only"`, no
  `dynamicTools`, and `environments: []`. With no environment the thread has no shell:
  asked to run a command, it says it can't (checked on 0.166.0; without `environments`
  it ran it). The `codex exec` fallback can't run without its shell, so a btw there
  fails rather than running with one.
- Tools are set per process, not per session, so a btw's session that is later continued
  as a chat (§7) gets the chat's tools back.

## 7. Forking a btw (continue as a chat)

"Fork" on a btw makes a new chat that carries on from it. It holds:

1. the source chat's messages up to the btw's `anchorSeq`, copied as a chat fork copies
   them (GAIA_FORKING_HLD.md §2: new ids, `origin` set, same seqs);
2. the btw's question, as a user message at `anchorSeq + 1`;
3. its answer, as a reply at `anchorSeq + 2`.

Only that one btw. Other btws aren't copied, and the new chat has no btw history of its
own.

- **The btw's own session is already this chat.** It holds the source up to `keepAt`,
  then the btw's prompt and answer. When the btw's `session` is this device's (its
  `sessionKey` matches), the fork gets a `fork` record on it, cut at its end
  (`forkCut(after: <btw id>)`) with `lastSeq` at the answer's seq. The first send forks
  it natively, with the chat's tools, so forking one btw twice gives two sessions, not
  one shared. A cut that can't be found makes it a handoff fork.
- **Otherwise it's a handoff fork** (option 1): the copied messages and no session.
- `forkOf` is the source chat (or its root), so it's listed under it like any fork.
  Title: "<source title> (btw)". It opens straight away, and the panel closes.
- Mid-reply btws: the fork's messages stop at `anchorSeq`, before P_live. P_live was in
  the btw's preamble, so the session knows of it but the fork doesn't show it. That's
  acceptable: the fork is about the side question.
- Forking a btw that's `streaming` isn't offered. A failed or stopped one forks as a
  handoff, never on its own session, its reply carrying the partial answer and its error,
  so the question can be retried as a chat.

## 8. UI (companion)

### 8.1 The panel

Floating over the bottom of the chat, its foot on the composer's field and as wide as the
composer, so nothing moves as it opens or closes; the chip (§8.2) and any other context
over the field sit under it meanwhile. Its top edge is an accent line, curving down at
the rounded corners, which parts it from the chat. No barrier: the chat stays in view
above it. The answer shows whole up to 420px tall, however many btws the list above it
holds, and scrolls past that, with no scrollbar. In a window too short for that, the
panel stops at the chat's top, under the header. Two parts stacked to fit the
companion's width:

- **The list:** with more than one, the chat's btws, newest first, five rows tall before
  it scrolls, keeping the selected one in view; each its question on one line, with a
  spinner while streaming and the device's name when another device is answering. The
  selected row is tinted in the accent, and a row lights under the mouse.
- **The answer:** in an inset card under the list, headed by the selected btw's question
  in bold accent, then its answer, in `GaiaMarkdown`, streaming in place. A key hint line
  runs along the panel's foot.

| Key | Does |
|---|---|
| Up / Down | Select the previous / next btw |
| Alt+C | Copy the selected answer |
| Alt+F | Fork the selected btw (§7) |
| Alt+X | Clear the chat's btw history (§4.2) |
| Esc | Close (a streaming btw carries on) |

Each has a Gaia button too, at the panel's foot: Copy, Fork, Clear history and Close.
The panel takes the focus on opening and on a click inside, and gives it up on a click
outside, as into the composer. The actions take Alt so a letter typed with the panel
focused still goes to the composer, as anywhere else in Gaia. All the keys work from the
composer too, but Up and Down move the caret when the draft takes more than one line on
screen, wrapped or broken, and Esc goes to Vim first when it has a use for it: from
Insert it goes to Normal, and the next Esc closes the panel. Ctrl isn't used, as Ctrl+C
and Ctrl+X copy and cut the draft and Ctrl+F searches. Showing another chat closes it.

### 8.2 Opening it

- `/btw <question>`: opens at that btw.
- `/btw`: opens at the chat's last btw. With none, it opens empty: "No side questions in
  this chat yet. Ask one with /btw <question>."
- A search hit on a btw (§9): opens the chat, then the panel at that btw.
- **A btw chip** on the chat (in the header or above the composer, by the activity chip)
  shows while the chat has btws, with a count. A click opens the panel. It spins while a
  btw streams with the panel closed. Like everything above the composer's field (the
  queue, window, `/this`, quote and attachment chips), it floats over the chat's foot
  rather than pushing the chat up: the chat's list keeps that much room at its end, so
  scrolled to the bottom the last message clears the top chip by the same 12px it clears
  the composer with none, and scrolled up the text runs on under them. Scrolled up, a chip
  coming or going doesn't move the text.

### 8.3 Other devices

The Gaia page and the phone show synced btws read-only in the same panel, without Fork
(which needs local sessions and runs on the desktop). Asking a btw from the phone isn't
in this design (§11).

### 8.4 What a btw takes

Text only. Attachments, `/this` and `$CLIPBOARD`-style expansion aren't applied. If the
draft has attachments, they stay in the composer for the next real send.

## 9. Search and memory

- **Search finds btws.** A second FTS5 table, `gaia_btw_search`, over question and
  answer, kept in step with `gaia_btw` as `gaia_message_search` is with messages, cleared
  rows left out. `searchMessages` adds btw hits; `GaiaSearchHit` gets a nullable `btwId`,
  and the search panel shows a btw hit with a "btw" mark under its chat.
- **The curator doesn't read btws.** It reads messages, and btws aren't messages, so
  nothing changes there. `curatedSeq` is untouched by btws.
- **Handoff, chapters, autonomy and notifications** don't see btws either, for the same
  reason.

## 10. Phases

### 10.1 Phase 1: btw by handoff, everywhere

- `GaiaBtwTable`, migration, model, repository, sync (`gaia_btw`).
- `GaiaBuiltin.btw`, `gaiaBtwText`, sending mid-reply (§3).
- Every btw by handoff (§5.2), keyed `btw:<id>` (§5.3), with no tools (§6).
- The btw preamble and history cap (§4.1); clear and undo (§4.2).
- The panel, its keys, the chip (§8).
- Fork as a handoff fork (§7, without session reuse).
- Search (§9).

It works on every adapter and device, at the cost of context quality and no prompt
cache. That's enough to check the UX before the sessions work.

### 10.2 Phase 2: native

- The native fork for a btw on Claude Code and Codex (§5.1), including the mid-reply cut.
- The btw's `session` recorded, and forking a btw by reusing it (§7).

### 10.3 Phase 2 as built (2026-11-09)

**What changed:**

- **The native fork.** `askBtw` asks `_btwFork` for a fork record, through the same
  `_forkRecordOn` a chat fork uses, at the btw's anchor message, on the adapter the btw
  runs on. That gives §5.1's table: idle, the cut is the session's end; mid-reply, the
  anchor is the message before P_live, so the cut is P_live's `parentUuid`, and P_live
  is waited for (5 s) when it was just sent here. A fork not sent in yet, a take-back's
  pending cut, and passed-over prompts from other devices all work as for a chat fork.
  `quiet` keeps it from showing "Forking…" on the anchor. On another account of the
  adapter, the source is copied first (`_forkSourceOn`, split out of `_forkFor`).
- **Catch-up.** Turns between the record's `lastSeq` and the anchor (a prompt from another
  device, a reply cut short) go in a catch-up `<gaia_transcript>` (`joining: false`); with
  none, the prompt is just the btw preamble. By handoff it's the joining transcript, as
  in Phase 1.
- **Fallback.** A fork refused before `init`, or one that fails with nothing to show (not a
  usage limit or login), is asked again by handoff in the same turn, with nothing shown,
  as a fork's first turn is (GAIA_FORKING_HLD.md §10.5).
- **A cut that didn't hold** (`result.notice`, from `_checkFork`): the btw completes with
  the notice in `error`, which the panel shows under the answer, and no `session`.
- **`session`** (`GaiaBtwSession`: `sessionKey`, `sessionId`) is a new nullable
  `gaia_btw_table.session_json` (schema 192), and syncs; other devices' keys don't
  match theirs. It's recorded for a complete Claude Code btw, native or handoff: either
  session holds the chat up to the anchor, then the btw. **Not for Codex**: Codex records
  which threads have Gaia's tools, and a tool-less one, forked or not, isn't one, so
  resuming it as a chat would be refused. Its turn's `environments: []` also sticks to
  the thread, which would leave a chat there with no shell.
- **Forking a btw** with a `session` whose key is one of this device's accounts puts it
  in the fork's `agentSessions` at `lastSeq` `anchorSeq + 2`: the first send resumes it,
  with the chat's tools, and hands nothing over. Otherwise it's Phase 1's handoff fork.
- **Codex's tool-less fork (§6).** `thread/fork` takes no `environments` or
  `dynamicTools`, so a btw's fork is `thread/fork` with `approvalPolicy: "never"` and
  `sandbox: "read-only"`, then `turn/start` with `environments: []` (also sent now on a
  tool-less thread's turn). The fork keeps the source's `dynamicTools`; with no turn
  tools, every call to one is refused ("No Gaia run is active").

**Checked live while building (2026-11-09):**

- **Claude Code 2.1.321:** a session ran a Bash command whose output it didn't repeat;
  `--resume <id> --fork-session --resume-session-at <last entry> --tools ""` answered with
  the command's number. A tool-less process accepts a history holding `tool_use` and
  `tool_result`. (Without Gaia's `--safe-mode`, `init` still listed the claude.ai
  connectors' MCP tools; Gaia passes `--safe-mode`, and §6's check found none.)
- **Codex 0.166.0** (a script on `codex app-server`): `thread/fork` as above, then
  `turn/start` with `environments: []`, asked to run `echo` and recall a code word from
  the source: no `commandExecution` item ("no execution environment is available"), and
  it gave the code word. Recalling a *tool result* through a fork was checked before
  (GAIA_REWIND_HLD.md §10.2); here the script's own shell returned no output, so only the
  text was checked.

**Tests added:** in `test/gaia_btw_test.dart`, "the companion, natively": idle (the cut
asked at the session's end, the fork sent tool-less with nothing handed over, the btw's
own session kept, the chat's untouched); mid-reply (cut before P_live, waited for, no
"Forking…", P_live in the prompt); a refused fork asked again by handoff, nothing said;
a cut that didn't hold (notice, no session, its fork hands over). The fork test now
checks session reuse (no new fork, `lastSeq` 3, the first send resumes it with nothing
handed over, with tools). The sync round trip carries `session`. In
`test/gaia_migration_test.dart`: 191→192. In `test/gaia_codex_app_server_test.dart`: a
tool-less fork's `thread/fork` and `turn/start` params.

**Live tests still to run** (in the app; §12's companion list, plus):

1. **Native, idle.** In a Claude Code chat, have Gaia run a command whose output no reply
   repeats, then `/btw what number did the command print?`. It answers with the number.
   Its CLI command line has `--fork-session` and `--tools ""`; the btw's row has
   `session_json`; the chat's JSONL has no btw prompt.
2. **Native, mid-reply.** Start a long reply, and ask a btw at once (within a second, so
   P_live hasn't reached the file). The btw knows the earlier turns and what's being
   answered; the reply carries on untouched; the anchor shows no "Forking…".
3. **Fork the btw, then send.** The fork's `agent_sessions_json` names the btw's session;
   the first send resumes it (`--resume`, no `--fork-session`), has tools again, and
   remembers the tool's number and the btw.
4. **Refused.** Ask a btw on a chat whose session was compacted, or with its JSONL moved
   away: it answers by handoff with nothing shown.
5. **Codex.** The same as 1 and 2 on a Codex tier, with a command run by Codex's shell:
   the btw recalls its output and runs no command; forking it is a handoff fork.
6. **Another account.** A chat whose session is on account A, with the btw routed to B:
   the source is copied to B, and the btw is native there.

## 11. Known limits

- **Each btw leaves a CLI session file behind.** No cleanup for now. Gaia never deletes
  session files, so the btw sessions forking relies on stay valid.
- **A btw's session exists only on the device and account that answered it.** Elsewhere,
  forking it is a handoff fork.
- **A Codex btw is never carried on natively** (§10.3): forking it is a handoff fork.
  Nor do Codex btws chain (§4.1): their history is always the text preamble.
- **A chain isn't capped.** `kGaiaBtwHistoryChars` caps only the text preamble. A
  chain grows with each btw at the same anchor, which a new chat turn ends.
- **A Codex btw's fork still lists Gaia's tools.** Each call is refused, but the model may
  try one before answering.
- **Btws aren't live-streamed** to other devices; they see the answer when it's done.
- **No asking from the phone.** It would go through `gaia_commands` to a beacon like a
  send. Left for later.

## 12. Testing

- **Unit:** `gaiaBtwText` and `/btw` alone; the palette lists `/btw` and a CLI's own
  `/btw` never wins; the preamble (order, cap, whole btws only, failed and cleared left
  out, P_live mid-reply); `btw:` keys never reach the chat's stop; clear and restore; the
  table's sync round trip; search hits for btws, none once cleared; forking a btw (seqs,
  `origin`, `forkOf`, and session reuse only when the session key matches).
- **Live, companion:** ask idle and mid-reply (the reply carries on untouched, and its
  next turn doesn't know of the btw); several btws, each seeing the earlier ones; `X`
  then Undo; `/btw` alone with and without history; Copy; Fork, then send in the fork
  and check it remembers the btw (Phase 2: no new fork made); a btw synced to a second
  device; search to a btw; Claude Code and Codex.

## 13. Files likely touched

- `lib/data/database/app_database.dart`: `GaiaBtwTable`, `gaia_btw_search`, migration.
- `lib/domain/models/gaia_models.dart`: `GaiaBtw`; `GaiaSearchHit.btwId`.
- `lib/domain/repositories/repositories.dart`,
  `lib/data/repositories/drift_repositories.dart`: btw reads and writes, search.
- `lib/core/sync/firestore_collections.dart`, `outbox_sync_worker.dart`,
  `remote_sync_service.dart`: the `gaia_btw` collection.
- `lib/features/gaia/companion/gaia_commands.dart`: `GaiaBuiltin.btw`, `gaiaBtwText`.
- `lib/features/gaia/companion/gaia_controller.dart`: asking, the preamble, runs, clear,
  forking a btw.
- `lib/features/gaia/adapters/gaia_agent_runner.dart`,
  `claude_code/claude_code_runner.dart`, `codex/codex_runner.dart`: tool-less turns;
  `btw:` keys.
- `lib/features/gaia/host/gaia_host.dart`, `gaia_chat_store.dart`, `gaia_pipe.dart`: the
  pipe requests the companion needs.
- A new `lib/features/gaia/companion/gaia_btw.dart`: the panel and chip.
- `lib/features/gaia/companion/gaia_search.dart`: btw hits.
- `GAIA_NATIVE_COMMANDS.md` §8: point here.
