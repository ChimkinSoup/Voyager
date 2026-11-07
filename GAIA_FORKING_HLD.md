# Gaia — Forking a Chat (HLD)

Status: **Phases 1 and 2 built, with follow-ups (2026-11-06); in-app live tests run
(2026-11-06, §10.6), and the four bugs they found (BUG-366 to BUG-369) fixed. Every live
test has passed, including the compaction case and the right-click menu. Done.**
It's built in two phases (§10): first forking by transcript handoff everywhere, then Claude
Code's native fork. What Phase 1 built, and the live tests it still needs, are in §10.3;
Phase 2's are in §10.4, and the follow-ups' in §10.5. The results of those live tests are in §10.6. The Claude Code behaviour it relies on was checked on 2.1.318 (§4), and Phase 2's
contract check passed live on that version and on 2.1.319. Nothing in Codex was checked, since Codex
doesn't fork natively under this design.

## 1. Summary

A fork copies a chat up to a chosen message into a new chat, which then goes its own way.
The source chat is left as it was, and the two chats don't stay linked.

- **Any message can be forked except a reply that is still streaming.** The source chat
  can be mid-reply while it is forked.
- **The fork ends on the message forked at.** Forking at a user prompt, answered or still
  being answered, gives a fork that ends on that prompt, unanswered. Forking at a reply
  gives a fork that ends on that reply.
- **Claude Code forks natively** (§5): the fork gets its own copy of the CLI session, cut
  at the fork point, so it keeps tool calls, tool results and thinking.
- **Option 1 is the fallback** (§6): a new chat with no session, which gets the copied
  transcript through the existing handoff (GAIA_HLD.md §7.4). Claude Code falls back to it
  whenever the native fork can't be made, and Codex always uses it.

## 2. What a fork copies

| Copied | Not copied |
|---|---|
| Messages with `seq` ≤ the fork point, as new records with new ids and the **same seqs** | The reply that is streaming |
| `tier` | Draft, queue, drain, grants |
| `title`, marked as a fork | `agentSessions` (only the native fork's own session goes in, §5.3) |

- **Soft-deleted messages are skipped**, as handoff already skips them.
- **`curatedSeq` becomes the fork point.** The copied turns are the source's curator's,
  read there yet or not. Otherwise each fork's curator would read them again and save their
  memories once per fork (GAIA_HLD.md §11, BUG-369).
- **Seqs stay the same** because `lastSeq` and `gaiaUnseenTurns` both work by seq. With
  the same seqs, the fork's session and its messages line up with no remapping.

## 3. Forking while a reply streams

The source chat has a prompt **P_live** whose reply **R_live** is streaming.

- **R_live can't be forked.** It's left out of every fork.
- **Forking at P_live** copies P_live, and the fork ends on it, unanswered. The session is
  cut just before P_live (§5.1). P_live stays above the session's `lastSeq`, so the fork's
  next send passes it to Claude in the catch-up preamble (`gaiaUnseenTurns`). Claude sees
  it, and the session never holds two user turns in a row.
- **Forking at any earlier message** works the same as on an idle chat.
- **The source turn isn't disturbed.** The fork's process is separate (runs are keyed by
  chat id), `--fork-session` writes a new file, and it never touches the source's (§4).

## 4. What was checked (Claude Code 2.1.318, Windows, 2026-11-05)

The test scripts started a source session, gave it three turns that each set a code word,
then started a long turn that sets a new code word and runs a 100 s tool call. While that
turn ran, they forked the session at different points and asked each fork for the code
word. They ran the way Gaia runs Claude Code: stream-json on stdin, with a `uuid` on the
user message.

| Check | Result |
|---|---|
| `--resume <src> --fork-session --resume-session-at <uuid>` | Works. It answers from the session as it stood at `<uuid>`, in a new session with a new id. |
| Fork cut just before the live prompt, while that turn ran | Answered with the previous code word. It never saw the live prompt. |
| Fork at an earlier turn, while the live turn ran | Answered with that turn's code word |
| The live turn while forks ran | Unaffected; it finished normally |
| Source session afterwards | No fork prompts got into it, and its next turn was correct |
| Reading the source JSONL while the live process writes it | Repeated reads with no errors. Node opens files with full sharing. |
| Fork's first prompt `parentUuid` | Equals the cut uuid, so a `_checkCut`-style check works |
| The stream-json `uuid` sent with the fork's prompt | Becomes the prompt's entry uuid in the fork's JSONL |
| Source entry uuids in the fork | Kept the same, so a fork of a fork can be cut at uuids Gaia already knows |
| A cut uuid the session doesn't have | Exits 1 within about 1.4 s: `No message found with message.uuid of: <uuid>` |
| Time to fork and answer | About 3 s |
| `<id>/tool-results/` side folder | **Not copied.** The fork's history refers to large tool outputs by absolute path inside the source session's folder (§8). |

**Not a CLI fault:** the first test run hung for 4 minutes in `-p` mode because the script
left stdin open. With stdin closed, it took 3 s. Gaia sends prompts over stream-json, so
this doesn't apply to it.

**`session-owner` entries in the JSONL** record which account owns the session. They
aren't a lock.

## 5. Option 2: native fork (Claude Code)

### 5.1 Matching messages to session entries

Today each prompt goes to Claude Code with a fresh random uuid
(`claude_code_runner.dart`, `_ClaudeProcess.turn`), and nothing keeps it. **Change: send
the user message's own id as the stream-json `uuid`.** Message ids are already uuid v4s
(`newId()`), so every user message then names its own entry in the session file.

- **Messages sent before this change** have no entry under their id. Forks that need one
  use option 1.
- **To verify while building:** whether the same message can be sent twice to the same
  session (a retry, say). Two entries with the same uuid in one session must not happen.
  If they can, the uuid is stored on the message instead.
- **Take-back still works.** It finds the stopped prompt by the uuid it was sent with,
  which becomes the message id.

### 5.2 The cut point

The cut point (`keepAt`) is the last session entry the fork keeps. It is worked out
**when the fork is made**, by reading the source session's JSONL; no process is started.

| Fork at | `keepAt` | Fork's `lastSeq` |
|---|---|---|
| User prompt P, answered or live | `parentUuid` of P's entry | seq of the message before P |
| Reply R, followed by user prompt N | `parentUuid` of N's entry | R's seq |
| Reply R, the chat's last message, nothing streaming | the session's last entry with a `uuid` | R's seq |

- **The fork can be made while P_live hasn't reached the file yet.** This happens just
  after a send, before the CLI has read the prompt. In that case Gaia waits a few seconds
  for P_live's entry to appear. If it doesn't appear, the fork uses option 1.
- **Forking at P_live and at the reply before it give the same `keepAt`.** They differ
  only in whether Gaia copies P_live.

### 5.3 Making the fork

Gaia records the fork on the new chat, then makes the native session lazily, on the fork's
first send:

```
claude --resume <source session> --fork-session --resume-session-at <keepAt> …
```

- **The fork record is device-scoped.** It holds `(session key, source session id,
  keepAt, lastSeq)`, where the session key is this device, the Claude Code adapter and the
  account (`gaiaSessionKey`). Other devices ignore it, and they reach the fork through
  handoff like any chat they didn't run.
- **It's stored on the chat, not in `agentSessions`.** If the fork record were lost and
  the source session id sat in `agentSessions`, a plain `--resume` would add the fork's
  turns to the source chat's session. Storing it separately needs a nullable column on
  `GaiaChatsTable` and a migration.
- **The controller has to know about the fork**, so that it passes `lastSeq` from the
  record rather than -1. Otherwise handoff would send the whole transcript on top of the
  native session. `GaiaAgentRunner.send` gets an optional fork parameter
  `(sourceSessionId, keepAt)`, which only the Claude Code runner acts on.
- **On success**, the CLI's new session id goes into `agentSessions` under the session key,
  with `lastSeq` from the record, and the fork record is cleared. From then on it's an
  ordinary chat.
- **After the first turn**, the new prompt's `parentUuid` must equal `keepAt`, checked as
  `_checkCut` checks a take-back. If it doesn't, the user is told the fork may hold more
  of the source chat than it shows. By then the turn has run, so there's nothing to fall
  back to.

### 5.4 Account

The source session lives under one account's config dir.

- **If the fork's first send routes to the same account**, it forks in place.
- **If it routes to another account of the same adapter**, Gaia copies the source session
  over with `copySession` first, then forks, as `_followSession` does.
- **If it routes to another adapter**, the fork uses option 1. *As built (§10.4), that
  send is a handoff but the fork record is kept, so a later Claude Code send still forks
  natively and catches up the other adapter's turns.*

### 5.5 When the native fork is used

Gaia uses the native fork only when all of these hold:

- the adapter is Claude Code;
- this device has a Claude Code session for the source chat whose `lastSeq` reaches the
  fork point. If other devices or adapters took turns since, the session doesn't have
  them;
- the entry `keepAt` depends on was found (§5.1, §5.2).

Otherwise the fork uses option 1 from the start.

## 6. Option 1: transcript handoff (fallback, and Codex)

The fork gets the copied messages and **no session**. On its first send there's no
session, so `lastSeq` is -1, and the existing handoff preamble (`gaiaHandoffPreamble`,
`joining: true`) passes on the transcript: recent turns word for word, up to
`kGaiaHandoffChars`, with older turns summarised.

- **No new adapter code is needed.** It works on every adapter and every device.
- **The cost is context quality.** The agent gets a rendered transcript, not its own
  history: tool calls and their results are left out, and a long chat is partly
  summarised.

**When option 1 is used:**

| Case | When it's decided |
|---|---|
| Codex, always | At fork time |
| Claude Code, conditions in §5.5 not met | At fork time |
| Claude Code, the fork's first send refuses (bad cut uuid, missing source file, any early exit before `init`) | First send: the fork record is dropped, and the same prompt goes again to a new session with `lastSeq` -1 |

The refusal is quick (about 1.4 s for a bad uuid, §4), and it comes before the prompt
reaches the model. That makes it safe to retry, as take-back's check already relies on
(GAIA_HLD.md §9.6).

**Codex** has `thread/start`, `thread/resume` and `thread/revert` in use. Whether its app
server can fork a thread wasn't looked into. If it can, Codex could get a native fork
later, the same way as §5.

## 7. UI

Decided while building Phase 1; see §10.3's UI decisions. In short: "Fork from here" in
the message's right-click menu, left out on a streaming reply; the title is the source's
with " (fork)"; the fork opens straight away.

**Forks listed under their original.** A fork stores `forkOf`, the id of the chat at the
root (a fork of a fork names the original), and it syncs. In the companion's sidebar and
on the Gaia page, a fork is listed under its original, with a bracket, newest first.
The group sits where the original's own activity puts it. When the original is pinned or
unpinned, its forks move with it. A pinned fork is listed on its own at the top, and
when it's unpinned it goes back under the original. A fork whose original is deleted, and
forks made before `forkOf` existed, are listed on their own. A chevron after the
original's title hides its forks. The companion keeps what's hidden in `sidebar.json`;
the Gaia page keeps it only while it's open. A new fork shows its group again. A search
on the Gaia page lists its matches without grouping them.

## 8. Known limits

- **Large tool outputs are shared with the source session.** `--fork-session` doesn't copy
  `<id>/tool-results/`, so the fork refers to files in the source session's folder by
  absolute path. That's fine while Gaia never deletes Claude Code session files, which it
  doesn't today. If session cleanup is ever added, or a fork's session is carried to
  another machine, Gaia should copy the folder at fork time, as `copySession` does.
- **The native fork only exists on the device and account that made it.** Elsewhere the
  fork works by handoff, like any chat.
- **Forks of chats from before §5.1 use option 1**, unless the fork point comes after the
  change.

## 9. Files likely touched

- `lib/features/gaia/adapters/claude_code/claude_code_runner.dart`: send the message id as
  the prompt uuid; resolve `keepAt`; build the fork arguments; check after the first turn.
- `lib/features/gaia/adapters/gaia_agent_runner.dart`: an optional fork parameter on `send`.
- `lib/features/gaia/companion/gaia_controller.dart`: create the fork chat and its message
  copies; choose option 2 or option 1; fall back on refusal.
- `lib/domain/models/gaia_models.dart`, `lib/data/database/app_database.dart`: the fork
  record on `GaiaChat`, with its column and migration.
- The message UI, for the fork action.

## 10. Phases

| Phase | Work | Done when |
|---|---|---|
| **1. Forking by handoff** (§10.1) | The prompt-id change (§5.1); the fork action; option 1 for every fork, on every adapter | A fork made mid-reply ends on the right message, and its first reply knows the copied turns, on both CLIs; a new prompt's JSONL entry uuid is its message id |
| **2. Native fork** (§10.2) | The fork record; `keepAt`; the native fork on first send; falling back to option 1 | A Claude Code fork recalls something only a copied tool result held; a refused fork falls back and still answers |

### 10.1 Phase 1: forking by handoff, and prompt ids

Every fork uses option 1 (§6). This phase also includes the prompt-id change. It doesn't
change how forks behave yet, but every chat used from this phase on gets session entries
that Phase 2 can find (§8, last point).

**Work:**
- **Prompt ids (§5.1).** `GaiaAgentRunner.send` takes the user message's id. The Claude Code
  runner sends it as the stream-json `uuid` in place of a random one. Take-back keeps
  finding a stopped prompt by the uuid it was sent with. Codex ignores the id.
- **Repeat sends.** Check whether one message can be sent twice to the same session (a
  retry, a re-send after an error). If it can, store the uuid on the message instead (§5.1).
- **The fork.** A controller action that makes the new chat and copies its messages, as §2
  describes. The new chat has no `agentSessions` and no fork record, so its first send
  passes on the transcript through handoff.
- **Streaming.** The fork leaves out a reply that is streaming, and the action is disabled
  on that reply (§3).
- **UI** (§7). Where the action sits, the fork's title, and whether the fork opens straight
  away.

**Done when:**
- **Forking at P_live while R_live streams** gives a chat that ends on P_live, unanswered.
  R_live finishes in the source chat as it would have. The fork's first send puts P_live in
  the preamble, and the reply answers with knowledge of the copied turns. Checked on Claude
  Code and on Codex.
- **Forking at an earlier reply, and at an earlier prompt,** gives exactly the messages up
  to that point, with the same seqs.
- **The memory curator** doesn't save memories from the copied turns a second time.
- **The fork reaches a second device through sync**, and a send there works by handoff.
- **A new prompt's entry in the Claude Code JSONL** has its Gaia message id as its `uuid`.
- **Take-back** passes its GAIA_HLD.md §9.6 checks unchanged, and the existing tests pass.

### 10.2 Phase 2: native fork on Claude Code

A Claude Code fork gets its own copy of the CLI session (§5). It falls back to option 1
whenever the native fork can't be made. Codex is unchanged and keeps using option 1.

**Work:**
- **The fork record (§5.3).** A nullable column on `GaiaChatsTable` and its migration, and
  the field on `GaiaChat`.
- **`keepAt` (§5.2).** Read from the source session's JSONL when the fork is made,
  including the short wait for P_live's entry to appear.
- **The choice (§5.5).** Gaia makes a fork record only when the conditions in §5.5 hold.
  Otherwise the fork is the same as in Phase 1.
- **The first send.** `send` takes the optional fork parameter, and the Claude Code runner
  resumes with `--fork-session --resume-session-at <keepAt>`. On success, Gaia saves the
  new session id and the record's `lastSeq` to `agentSessions` and clears the record.
- **Account (§5.4).** If the first send goes to another account, Gaia runs `copySession`
  before forking. If it goes to another adapter, the fork falls back to option 1.
- **Fallback (§6).** If the CLI exits before `init`, Gaia drops the record and sends the
  same prompt again to a new session, with `lastSeq` -1.
- **After the first turn (§5.3).** A `_checkCut`-style check confirms the new prompt hangs
  off `keepAt`, and tells the user if it doesn't.

**Done when:**
- **A fork has the source session's real context.** Fork at an earlier turn while the
  source is mid-reply. The fork's first reply recalls something only a copied tool result
  held, never stated in any message's text. Handoff doesn't pass tool results on, so this
  only passes if the fork is native.
- **Forking at P_live:** the fork's session doesn't hold P_live, the first send's preamble
  does, and the new prompt's `parentUuid` is `keepAt`.
- **The source chat is untouched.** Its live turn finishes normally, its session holds
  none of the fork's turns, and its next turn is correct.
- **A refused fork falls back.** Give the record a bad `keepAt`, or delete the source
  session file, and the fork still answers by handoff with no error shown to the user.
- **A fork whose first send goes to another account** forks after `copySession`.
- **Option 1 is still used where it should be:**
  - a chat whose fork-point entries predate Phase 1;
  - a chat with no Claude Code session on this device;
  - any Codex chat.
- **A fork of a fork** is native too.

### 10.3 Phase 1 as built (2026-11-05)

**What changed:**

- **Prompt ids.** `GaiaAgentRunner.send` takes an optional `promptId`. The controller passes
  the user message's id on both sends of a turn (the first, and the retry as a new session
  when a resume finds none). `ClaudeCodeRunner` sends it as the stream-json `uuid`
  (`_ClaudeProcess.turn`), and a random one only when none is given (the contract tests'
  `sendRaw`). The Codex runners accept it and ignore it. Take-back is unchanged: it still
  finds the stopped prompt by the uuid it was sent with, which is now the message id.
- **Repeat sends (§5.1): a message never reaches one session twice**, so the uuid isn't
  stored on the message. Every send, Edit & resend and the limit card's resend included,
  makes a new message with a new id. One message is sent twice in only two places, and
  neither gives a session two entries with its id:
  - the controller's retry when a resume finds no session goes to a *new* session;
  - the runner's retry when a take-back's cut is refused goes to the same session, but only
    when the first attempt never started (no `init`), so the CLI never saved the prompt.
- **The fork.** `GaiaController.forkChat(message)` copies the chat as §2 describes, saves it
  with one new pipe request, `forkChat` (`GaiaChatStore.forkChat`: the chat and all its
  copies in one serial write), and opens the fork. The fork has no `agentSessions`, so its
  first send hands the transcript over (§6). `curatedSeq` is
  the fork point (BUG-369).
- **Images.** Not in §2, but needed: `GaiaMedia.share` gives the fork its own media
  references to the copied images, so deleting the source chat doesn't take the fork's
  images onto the 30-day clock. An image whose asset isn't on this device yet is skipped,
  as `keepDraft` skips one; it then stays the source chat's only.
- **Streaming.** The action isn't offered on a streaming reply, and `forkChat` refuses one.
  A fork whose copies hold an image still being attached is refused with a toast ("Try
  again in a moment"), since the copy would keep the placeholder media id.

**UI decisions (§7):**

- **Where:** "Fork from here" in the message's right-click menu, after Edit & resend, on
  every message that isn't a streaming reply. Left out rather than greyed out, as the menu's
  other conditional items are.
- **Title:** the source's title with " (fork)" after it. It's not the first-line title, so the
  utility model doesn't retitle the fork after its first reply.
- **Opens straight away:** yes. It goes to the top of the list (`lastMessageAt` is the fork
  time).

**Tests added:** in `test/gaia_controller_test.dart`, group "forking": copies at an earlier
reply and prompt (new ids, same seqs, stored, source untouched); soft-deleted messages
skipped; `curatedSeq` capped; forking at P_live while R_live streams (not at R_live itself;
the fork ends on P_live; R_live finishes in the source; the fork's first send is a handoff
naming P_live); each prompt goes with its message id. In `test/gaia_cli_contract_test.dart`,
a live check that a prompt's JSONL entry uuid is the id it was sent with (runs only with
`GAIA_CLI_CHECK=1`). All Gaia tests pass (1245, contract tests skipped).

**For Phase 2 to settle:** a fork's copies get new ids (§2), but a native fork's session
keeps the *source's* entry uuids (§4). So the fork's own message ids won't be found in its
session, and a fork of a fork can't find `keepAt` by message id. Phase 2 needs either a
mapping from copy to original id (a field on the copy, or in the fork record), or to keep
the original ids' entries findable some other way.

**Live tests still to run** (none were run: the PC was unattended). Run each on Claude Code
and on Codex unless it says otherwise.

1. **Contract:** `qa/harness/gaia_cli_check.ps1` (or `GAIA_CLI_CHECK=1 flutter test
   test/gaia_cli_contract_test.dart`). The new "prompt's entry … has the message id" test
   must pass, and the existing take-back test must still pass now that prompts carry message
   ids.
2. **JSONL by hand (Claude Code):** send a message in a chat, then open
   `<config dir>/projects/<slug>/<session>.jsonl` and confirm the user entry's `uuid` is the
   message's id in the Gaia database (`gaia_messages_table.id`).
3. **Fork mid-reply at P_live:** send a prompt that takes a while (a long poem). While it
   streams, right-click the prompt → Fork from here. Check: the menu on the streaming reply
   has no Fork item; the fork opens, ends on the prompt, unanswered; the source reply keeps
   streaming and finishes normally (switch back to watch it). Then send in the fork; the
   reply should show it knows the earlier turns and the unanswered prompt.
4. **Fork at an earlier reply, and at an earlier prompt**, in a chat of 3+ exchanges: the
   fork holds exactly the messages up to that point, in order; the sidebar shows
   "<title> (fork)" at the top. Its first reply should recall something said only in the
   copied turns.
5. **Take-back still works (GAIA_HLD.md §9.6):** stop a reply before any text shows; the
   message goes back to the composer; the next send's reply doesn't know the stopped
   message. Repeat once in a chat with a resumed session (after the 10-minute idle
   timeout, or a companion restart).
6. **Memory curator:** in a chat whose memories were already curated, fork at the last
   message and send a turn in the fork. After the curator runs (`kGaiaCurateAfter`), no
   memory from the copied turns is saved twice; memories from the fork's new turn are.
7. **Second device:** after sync, the fork shows on another device (the Gaia page, or the
   phone) with all its messages and images. Send in it there: it works by handoff.
8. **Images:** fork a chat whose copied messages have images. The fork shows them; the
   fork's first send hands them over (captions and file paths in the preamble). Then delete
   the *source* chat: the fork's images still show, and still show after restarting Voyager.
   Also try forking right after sending a message with an image, while it uploads: the
   toast should say to try again.
9. **Odd cases:** fork a fork; fork at a reply that ended in an error or was stopped; fork
   a chat with an open question card (answering the card in the fork should go to the
   fork, not the source); fork while another device runs the source chat (its reply is
   streaming there, so it isn't offered).

### 10.4 Phase 2 as built (2026-11-05)

**What changed:**

- **The fork record (§5.3).** `GaiaForkRecord` (`sessionKey`, `sourceSessionId`, `keepAt`,
  `lastSeq`) is `GaiaChat.fork`, stored in a new nullable `gaia_chats_table.fork_json`
  (schema 187). It isn't written to Firestore, and a merge from Firestore keeps the local
  one (`mergeGaiaChatFromRemote`), so it never leaves this device. The companion clears it
  with a new pipe request, `dropFork` (`GaiaChatStore.dropFork`), which doesn't mark the
  chat for upload.
- **Copies remember their original (settles §10.3's open point).** A copy gets
  `GaiaMessage.origin`: the id of the message it was first copied from (a copy of a copy
  keeps the first one's). It's a new nullable `gaia_messages_table.origin` column, and it
  syncs. `GaiaMessage.entryId` (`origin ?? id`) is the uuid a message's entry has in a
  Claude Code session, and every session lookup uses it. That's how a fork of a fork finds
  its cut.
- **`keepAt` (§5.2).** `GaiaSessionForker.forkCut`, which `ClaudeCodeRunner` implements,
  reads the source JSONL. The controller (`_forkRecord`) passes it:
  - `after`: the last prompt with seq ≤ the fork's `lastSeq`. It must be in the session,
    or there's no native fork. This is what rules out chats from before Phase 1.
  - `next`: every later prompt, in order. The cut is the `parentUuid` of the first one the
    session has. Prompts it doesn't have (another device's, another adapter's) are passed
    over.
  - With none of them in the session, the cut is the session's last `user`/`assistant`
    entry. If a take-back's cut is still pending for that session, the cut is the
    take-back's `keepAt`, since the file's last entries are then the dropped turn.
  - `awaiting`: the prompt of a turn running *here*, on that adapter and account, when it
    comes after the fork's `lastSeq`. It's waited for up to 5 s (`_forkWait`), checking
    every 250 ms. If it still isn't there, there's no native fork.
- **The choice (§5.5).** The controller picks this device's Claude Code session for the
  source with the highest `lastSeq`, and only if that is ≥ the fork's `lastSeq`. A record is
  made only if `forkCut` finds a cut. The source's tier isn't checked: a record made for a
  chat that then runs on Codex just waits (see Account below).
- **The first send.** `GaiaAgentRunner.send` takes `GaiaForkCut? fork` (Codex ignores it).
  With no session, `ClaudeCodeRunner` starts a process of its own with
  `--resume <source> --fork-session --resume-session-at <keepAt>`. It takes the new session
  id from `init`, so take-back works on a fork's later turns. The controller passes the
  record's `lastSeq` to `gaiaUnseenTurns`, so a fork at P_live gets P_live in a catch-up
  preamble rather than a joining handoff. It sends no memory index, since a forked session
  keeps its source's system prompt (as a resume does). Once a turn's session is kept, the
  usual `recordSession` saves it with the reply's seq, and the record is dropped. A first
  turn that fails is handed over instead (§10.5); only a stopped one keeps the record, for
  the next send to fork again.
- **Account (§5.4).** `_forkFor` finds the account the record's session key names. On
  another account of the same adapter it runs `copySession` first; if the copy fails, the
  record is dropped and the chat is handed over. On another adapter the record is left as it
  is: that send is a normal handoff, and a later Claude Code send still forks, catching up
  the other adapter's turns from `lastSeq`. This differs from §5.4's "uses option 1": it
  needs no extra code, and it gives better context.
- **Fallback (§6).** A fork process that ends before `init`, not by a stop, reports
  `sessionFound: false`, whether the CLI printed an error result or just exited. The
  controller then drops the record and sends again with `lastSeq` -1, through the same
  retry a missing session uses, with nothing shown. On 2.1.318 a bad cut gives an
  `error_during_execution` result with no `init`, in well under a second.
- **After the first turn (§5.3).** `_checkFork` checks the prompt's entry in the new
  session hangs off `keepAt`. If it doesn't, the user gets an error toast, "This fork may
  not match what it shows".

**Known limits added:**

- **Deleted messages: not a limit today.** Gaia has no way to delete a single message. The
  only messages that end up soft-deleted are ones a stop took back (GAIA_HLD.md §9.6), and
  the cut already leaves them out. If the session never got one, there's nothing to leave
  out. If it did, its turn is a dead branch, which the cut steps around: the next prompt
  hangs off the take-back's `keepAt`, and a take-back still to be made gives its own
  `keepAt` as the cut. **If per-message delete is ever added**, a native fork would still
  remember a deleted message in its copied range, since §2 only skips it in the copies.
- **The cut is only as good as the prompts' ids.** A wrong cut that the CLI accepts isn't
  caught. `_checkFork` only confirms the CLI cut where it was told to. Every everyday path
  gives the right cut. The weakest is when no later prompt exists and the cut is the
  session file's last entry: a half-written last line puts the cut one entry early, losing
  the tail of an interrupted reply.
- **A session compacted after the fork point falls back to handoff.** Checked 2026-11-06 on
  2.1.319, with a manual `/compact` (§10.6). After a compaction, the CLI only knows the
  session's post-compaction view: the `compact_boundary`, its summary and the exchange
  compaction kept. `--resume-session-at` at an older entry is refused before `init` with
  "No message found", like a bad uuid, so the fork is handed over with nothing shown. The
  copied turns reach it word for word, so the agent does know them; what's lost is their tool
  results, as with any handoff. A cut after the boundary is native and carries the compacted
  context, just as the source has it. A cut at the kept exchange (the last turn before the
  compaction) is accepted, but the fork gets the summary plus that exchange, not the full
  history.

**Tests added:** in `test/gaia_controller_test.dart`, group "native forks": the record and
its cut inputs; the first send forks with nothing handed over, then resumes normally; a fork
at a prompt names it in the catch-up preamble; a refused fork falls back silently; no record
without a cut, without a session here, or from a session that stops short of the fork; a
send on another account copies the session first, and a failed copy hands over; a fork of a
fork finds copies by origin; forking at a prompt running here waits for it; a fork that
didn't hold is reported. In `test/gaia_claude_fork_cut_test.dart`: `forkCut` against JSONL
files on disk (next prompt, passed-over prompts, end of session, missing prompt or file,
first prompt, a prompt arriving late, a prompt that never comes, a half-written line). In
`test/gaia_migration_test.dart`: 186→187. In `test/gaia_cli_contract_test.dart`: a live fork
check, **run and passed on 2.1.318**. It cuts before a later prompt; the fork knows only the
earlier turn, in a new session, hanging off the cut; the source still knows both; a bad cut
is refused before `init`. All Gaia tests pass (1266, contract tests skipped).

**Live tests still to run** (on Claude Code unless it says otherwise; the PC was
unattended, so none of the UI ones were run). Together they cover §10.2's Done-when lines.
To check a fork is native, look for `--fork-session` in the CLI's command line
(`Get-CimInstance Win32_Process | ? CommandLine -match fork-session`), or for a new JSONL
whose early entries repeat the source's uuids.

1. **Real context from a tool result.** In a chat, ask Gaia to run a command whose output
   no reply repeats: "Use Bash to print a random 8-digit number; don't tell me it, reply
   only OK". Add another exchange. Then start a long reply ("write a 600-word poem") and,
   while it streams, fork at the first reply. In the fork, ask "what number did the command
   print?". It must give the number. Also check: the fork's first CLI process had
   `--fork-session`; afterwards the fork's `gaia_chats_table.fork_json` is NULL and its
   `agent_sessions_json` has this device's entry.
2. **Forking at P_live.** While a reply streams, fork at its prompt. Before sending, read
   `fork_json`: its `lastSeq` is the prompt's seq − 1. Send in the fork. The new JSONL
   doesn't hold the prompt from the source; its first user entry has P_live in a
   `<gaia_transcript>` catch-up (not "joining a chat"); that entry's `parentUuid` equals the
   record's `keepAt`. No "This fork may not match" toast.
3. **Forking right after a send.** Send a prompt and fork at it within a second, before the
   CLI has written it. The fork should still be native (the 5 s wait). Then fork at a prompt
   sent while its process is still starting (a cold chat). The fork must either be native
   with the right cut or fall back to a handoff. It must never cut in the wrong place.
4. **The source is untouched.** After 1 and 2, the source's streaming reply finished
   normally. Its JSONL has none of the fork's prompts, and its next turn answers correctly
   about its own history.
5. **A refused fork falls back.** Fork a chat. Before sending in the fork, either set
   `fork_json`'s `keepAt` to a random uuid (sqlite, Voyager closed) or move the source's
   JSONL away. Send in the fork: the reply comes by handoff ("joining a chat" in the
   prompt), with no error or toast, and `fork_json` is NULL afterwards.
6. **Another account.** With two Claude Code accounts, fork a chat whose session is on A,
   switch to B, and send in the fork. The source session is copied into B's config dir, the
   fork is native there (ask check 1's question), and B's dir has the fork's JSONL.
7. **Option 1 where it should be:**
   - (a) fork a chat that last ran before Phase 1 (its prompts' entries have random uuids);
   - (b) fork on a device or account with no Claude Code session for the chat (one only
     run on the other PC);
   - (c) fork a Codex chat.

   In all three, `fork_json` is NULL from the start and the first send is a handoff.
   - (d) fork a Claude Code chat, then send in it on a Codex tier. The Codex send is a
     handoff and `fork_json` stays. Switch back to a Claude Code tier and send: that send
     is native and catches up the Codex turns.
8. **A fork of a fork.** After a native fork has had a turn of its own, fork it twice: at a
   copied message, and at one of its own. Both should be native (`--fork-session` against
   the first fork's session), and check 1's recall should still work. The CLI side of this
   passed live (§10.5); this checks the app's side.
9. **Take-back in a native fork.** In a fork whose session is made, stop a reply before any
   text shows. The message goes back to the composer, and the next send doesn't know it
   (GAIA_HLD.md §9.6). Also stop a fork's *first* send early: the message goes back, and
   the next send forks again (`fork_json` stays set until a turn is kept).
10. **Fork at the end after a take-back.** In the source, stop a message so it's taken
    back, then straight away fork at the last reply. The fork must not know the taken-back
    message, because the cut is the take-back's `keepAt`.
11. **Sync.** On the second device the fork shows as usual and works by handoff. Its
    `fork_json` stays NULL there, and its messages carry `origin`.
12. **Contract after CLI updates.** `qa/harness/gaia_cli_check.ps1` now includes the fork
    check. Rerun it whenever Claude Code updates: `--fork-session` with
    `--resume-session-at` is an undocumented pairing.

### 10.5 Follow-ups (2026-11-06)

**What changed:**

- **A fork not sent in yet forks natively too.** Before, a fork of a fork that had no
  session yet was a handoff. Now `_forkRecord` falls back to the first fork's own pending
  record: it treats that record's source session as the session, and uses the record's
  `lastSeq` as how far that session goes. The cut is worked out against that source session
  by the copies' `origin` ids, as any cut is. `forkCut` takes a new `endAt`: when none of
  the later prompts is in the session, the cut is `endAt` (the pending record's `keepAt`)
  instead of the file's end. The source chat has moved on past that end since. A real
  Claude Code session on the first fork wins over its record. A fork's own first turn
  running at that moment isn't waited for, since it runs on a session of its own.
- **A fork can't get stuck forking into a failure.** Before, a fork's first turn that
  started and then failed with nothing shown (a cut from before a compaction might do this)
  left the record, so every later send forked again and failed the same way. Now:
  - an error result with nothing streamed is retried at once by handoff, and the record is
    dropped, the same as a refusal;
  - a first turn that throws (the CLI dying) drops the record, so the next send hands over;
  - a stop keeps the record, and the next send forks again.
  - so does a usage-limit or login failure, which isn't the cut's doing: it isn't retried by
    handoff, and the next send forks again.
- **Fork of a fork, checked live.** The contract check now forks the fork twice: at a turn
  it copied, found by the source's uuids, and at a turn of its own. It **passed on
  2.1.318**. In both, the new prompt hung off the cut, and each fork knew exactly the words
  up to its cut.

**Tests added:** in "native forks": a fork whose first turn fails with nothing to show
hands over in the same send; one whose first turn dies forks no more, and one stopped still
does; a fork not sent in yet forks from its source session with `endAt` at its own cut, and
at its very end gets that cut; a fork that has a session forks from the session, not its
record. In `test/gaia_claude_fork_cut_test.dart`: `endAt` is used only when no later
prompt is found. All Gaia tests pass (1271, contract tests skipped).

**Live tests still to run** (after §10.4's):

13. **Fork an unsent fork.** Fork a chat (native, as in check 1), and without sending in
    it, fork it again at an earlier copied reply. Send in the second fork. It should be
    native (`--fork-session` against the *original* chat's session), know the turns up to
    its cut, and recall check 1's number if the cut is after that turn. Then send in the
    first fork: it still forks natively, unaffected.
14. **A fork's first turn that fails.** Make a fork's first turn fail after `init`. Either
    set an account's login to an expired one (the "Not logged in" path), or fork a long
    chat that has compacted at a point before the compaction (if one exists; its JSONL has a
    `compact_boundary` entry). The same send should be retried by handoff, and `fork_json`
    should be NULL afterwards. The next send must not fork again. Note whether the
    compaction case refuses, works or fails, and record it in §10.4's known limits.

### 10.6 Live test results (2026-11-06)

Run on `gaiaqa` (qa-128), with a debug build of the working tree copied aside, Claude Code
2.1.318 (Haiku, Quick) and Codex 0.166 (Deep), and `qb` as the second device. A fork was
taken as native when its first CLI process had `--fork-session`, checked against the JSONL
files and the database.

| Test | Result |
|---|---|
| §10.3 #1, §10.4 #12: contract | Pass, 12 of 12. Rerun after the fixes below: pass. Gaia tests: 1272 pass. |
| §10.3 #2: prompt entry uuid is the message id | Pass, handoff and fallback prompts included |
| §10.3 #3, #4 / §10.4 #4: fork mid-reply, at earlier turns; source untouched | Pass. `forkChat` refuses a streaming reply, and the menu hides the item (`gaia_app.dart`, checked in code, not by right-click). The source reply finished normally, its JSONL holds no fork prompts, and its next turn answered correctly. |
| §10.3 #5: take-back, fresh and resumed sessions | Pass |
| §10.3 #6: memory curator, curated source | Pass. A fork of a curated chat copied `curatedSeq` 1. After its curator ran, no memory from the copied turns was saved again; the new turn's fact was saved once (proposed by the agent in the turn; the curator didn't add it again). |
| §10.3 #7 / §10.4 #11: second device | Pass. On `qb` the forks have all messages, `origin` and images, `fork_json` NULL; a send there is a handoff. A reply streaming on `qb` doesn't show here until it ends, so it can't be offered. |
| §10.3 #8: images | Pass. Toast while uploading; native and Codex handoff both see the image; it survives deleting the source and a restart. |
| §10.3 #9: odd cases | Pass for a fork of a fork and a fork at an errored or stopped reply (but see BUG-368). An open question card failed: **BUG-367**, fixed. |
| §10.4 #1: real context from a tool result | Pass. The fork recalled the tool's number. |
| §10.4 #2: forking at P_live | Pass. `lastSeq` is the prompt's seq − 1; the first entry is a `<gaia_transcript>` catch-up hanging off `keepAt`; no toast. |
| §10.4 #3: forking right after a send, warm and cold | Pass, native with the right cut both times |
| §10.4 #5: refused fork | Pass. Handoff in under 1 s, no toast, `fork_json` NULL. |
| §10.4 #6: another account | Pass. The session was copied to the second account's config dir, and the fork was native there. |
| §10.4 #7 (a)–(d): option 1 where it should be | Pass |
| §10.4 #8: fork of a fork | Pass, native at a copied message and at one of its own |
| §10.4 #9: take-back in a native fork | Pass. A stopped first send keeps the record and forks again. |
| §10.4 #10: fork at the end after a take-back | Pass, cut at the take-back's `keepAt` |
| §10.5 #13: fork of an unsent fork | Pass. Native against the original session; at the very end it used `endAt`; the first fork was unaffected. |
| §10.5 #14: a fork's first turn that fails | Failed: **BUG-366**, fixed. The compaction case was run later; see the follow-up checks below. |

**Found:**

- **BUG-366 (fixed):** a fork's first turn that failed after `init` hung "streaming". The
  handoff retry took the failed fork's live process from `_live`, as nothing in the reuse
  check killed it. Now a live process is reused only for the session it runs. Live retest on
  an account with no login: the fork process, then a `--session-id` process a second later,
  the turn ended with the CLI's "Not logged in" in under 3 s, `fork_json` NULL; the next
  send, on the default account, was a handoff.
- **BUG-367 (fixed):** answering a copied open question card in a fork marked the source's
  card answered, since the copy kept its card id. A fork's cards now get new ids. Live
  retest: the fork's card was stored as answered and the source's stayed open.
- **BUG-368 (fixed 2026-11-06):** a native fork at a stopped reply holds the CLI's "No response
  requested." placeholder, not the partial text the user saw, and nothing catches it up.
- **BUG-369 (fixed 2026-11-06):** a fork made before its source was curated copies `curatedSeq` -1, so
  each such fork's curator saves the copied turns' memories again. One fact was proposed four
  times from four forks. This misses §10.1's Done-when line on memories, though §10.3 #6
  covers only a curated source.

**Follow-up checks (2026-11-06, later):** the same setup, Claude Code 2.1.319, from a debug
build of `f3e9f6e4`. All three passed:

| Test | Result |
|---|---|
| Contract on 2.1.319 (§10.4 #12) | Pass, 12 of 12 |
| Right-click menu | Pass. Right-clicking a reply still streaming (with text: Select all, Copy message, Attach as context) shows no Fork from here. With no text yet, no menu opens, since nothing is left to offer. Right-clicking that reply's prompt offers Fork from here; tapping it opened "<title> (fork)", ending on the prompt, unanswered. |
| Compaction | Pass: a refused cut falls back. First checked against a scratch CLI session with `/compact` sent by `claude -p --resume <id>` (the CLI's own `-p` result is a JSON array of events on 2.1.319). Then in the app: two exchanges and a poem in a Haiku chat; Gaia's CLI process stopped; `/compact` run on its session from the workspace folder. A fork at the first reply (cut before the boundary): `--fork-session` refused, a `--session-id` handoff 0.6 s later, `fork_json` NULL, no toast, and it answered with the one code word the fork holds. A fork at the last reply (cut at the "Compacted" entry after the boundary) was native, hanging off `keepAt`, and knew only what the summary kept. Recorded in §10.4's known limits. |
| Forking at a prompt whose reply streams on another device | Pass. A prompt is uploaded when sent; only a streaming reply waits (`upsertMessage`). So `qb`'s prompt showed on `gaiaqa` within 2 s while its reply streamed there. Forked at it on `gaiaqa`: the fork ended on that prompt, unanswered, with a native record (`lastSeq` the seq before it, cut at this device's session end, passing over the prompt the session never had). Its first send was native, with `qb`'s prompt in a catch-up `<gaia_transcript>` hanging off `keepAt`, and it answered with the code word that prompt set. `qb`'s reply finished normally (12k characters), and reached the source on `gaiaqa` but not the fork. |

Every live test in §10.3 to §10.5 has now been run.
