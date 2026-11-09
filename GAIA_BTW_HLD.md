# Gaia — `/btw` Side Questions (HLD)

Status: **Draft (2026-11-09). Not built.** Builds on forking (GAIA_FORKING_HLD.md) and
rewinding (GAIA_REWIND_HLD.md), both done and live-tested, and replaces the plan in
GAIA_NATIVE_COMMANDS.md §8. Claude Code's own `/btw` isn't available headless, and Codex
has none, so this is Gaia's own.

## 1. Summary

`/btw <question>` asks a side question about the chat without it entering the chat. The
answer shows in a btw panel over the chat, never in the transcript, and the main
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
- **No notification** when a btw finishes (`notifyOnDone` is for chat replies).

**Must hold mid-reply.** Today, while a reply streams, send is the stop button and Enter
queues. `/btw <question>` must always go as a btw, never be queued or stop the reply.
*To verify while building: the exact path Enter takes mid-reply, and that `/btw` is
caught before it.*

## 4. History

### 4.1 What a btw sees

A btw's prompt starts with a preamble of the chat's **earlier, uncleared, complete btws**,
oldest first:

```
Side questions asked earlier in this chat (not part of the conversation):
Q: …
A: …

Now answer this side question briefly. You have no tools; answer from what you know
and what's in this conversation. It won't be added to the conversation.
<question>
```

- **Capped** at `kGaiaBtwHistoryChars` (start at 8 000). Past that, the oldest go first,
  whole: a btw is never cut in half.
- **Failed and cancelled btws are left out.**
- **The btws are replayed as text every time**, not kept in a long-lived side session.
  A side session would go stale as the main chat moves on, and keeping it in step would
  mean feeding it the main chat's new turns. A fresh fork each time sees the main chat
  exactly, and btw history is short text, cheap to replay.

### 4.2 Clearing

- **`X` in the panel, or its "Clear history" button**, clears **all** of the chat's btws:
  each row gets `deletedAt`, and that syncs. A btw still streaming is stopped first.
- **An "Undo" toast** follows, which restores them (`restoreBtws`). `X` is one key away
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

*To verify while building:* that nothing in either runner looks a `chatId` up as a real
chat (rewind maps, account follow, `takeBack`). Anything that does is skipped for a
`btw:` key.

## 6. No tools

A btw only answers.

- **Claude Code:** no `--mcp-config` (none of Gaia's host tools) and every built-in tool
  in `--disallowedTools`. A new `GaiaTurnTools.none` (or a `toolless` flag on `send`)
  says so.
- **Codex:** read-only sandbox and approval `never`. *To verify:* whether Codex can be
  run with no shell at all. If not, a btw on Codex can read files but not change them.
  That's a known limit (§11).
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
  `sessionKey` matches), it goes straight into the fork's `agentSessions` with `lastSeq`
  at the answer's seq. No new CLI fork is made, and the first send there just resumes it,
  with the chat's tools.
- **Otherwise it's a handoff fork** (option 1): the copied messages and no session.
- `forkOf` is the source chat (or its root), so it's listed under it like any fork.
  Title: "<source title> (btw)". It opens straight away, and the panel closes.
- Mid-reply btws: the fork's messages stop at `anchorSeq`, before P_live. P_live was in
  the btw's preamble, so the session knows of it but the fork doesn't show it. That's
  acceptable: the fork is about the side question.
- Forking a btw that's `streaming`, `error` or `cancelled` isn't offered.

## 8. UI (companion)

### 8.1 The panel

A `GaiaPanel` over the chat, like search's, with two parts stacked to fit the companion's
width:

- **The list:** the chat's btws, newest first, each its question on one line, with a
  spinner while streaming and the device's name when another device is answering.
- **The answer:** the selected btw's question and its answer, in `GaiaMarkdown`,
  streaming in place.

| Key | Does |
|---|---|
| Up / Down | Select the previous / next btw |
| `C` | Copy the selected answer |
| `F` | Fork the selected btw (§7) |
| `X` | Clear the chat's btw history (§4.2) |
| Esc, or a click outside | Close (a streaming btw carries on) |

Each has a button too: Copy and Fork beside the answer, "Clear history" at the panel's
foot. Single-letter keys work because the panel has no text field.

### 8.2 Opening it

- `/btw <question>`: opens at that btw.
- `/btw`: opens at the chat's last btw. With none, it opens empty: "No side questions in
  this chat yet. Ask one with /btw <question>."
- A search hit on a btw (§9): opens the chat, then the panel at that btw.
- **A btw chip** on the chat (in the header or above the composer, by the activity chip)
  shows while the chat has btws, with a count. A click opens the panel. It spins while a
  btw streams with the panel closed.

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

## 11. Known limits

- **Each btw leaves a CLI session file behind.** No cleanup for now. Gaia never deletes
  session files, so the btw sessions forking relies on stay valid.
- **A btw's session exists only on the device and account that answered it.** Elsewhere,
  forking it is a handoff fork.
- **A btw on Codex may be able to read files** if Codex can't be run without a shell
  (§6).
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
