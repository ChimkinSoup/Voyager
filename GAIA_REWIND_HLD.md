# Gaia — Rewinding a Chat (HLD)

Status: **Phase 1 built and live-tested (2026-11-06). Every §10.1 check passed; one bug found (BUG-371) and fixed. Results at the end of §10.1.**
Built as designed, except: each `rewinds` range also names the device that made it (`by`),
so only that device moves a late reply (§5.1); rewind isn't offered at the chat's last
message (nothing to drop) nor at a prompt whose reply is streaming here (§4 step 0); and
draining is paused whenever it's on, not only while a turn runs, since an idle rewound
chat would otherwise drain at once. Builds on forking
(GAIA_FORKING_HLD.md), which is done and live-tested, and on take-back (GAIA_HLD.md §9.6).
Nothing new in either CLI is relied on: the Claude Code path is the native fork Phase 2
already uses, and Codex hands over (§6).

## 1. Summary

A rewind takes a chat back to an earlier message, so the conversation can carry on from
there. It works like Claude Code's rewind, but nothing is lost: **the messages after the
rewind point go into an automatic fork**, listed under the chat, and the chat carries on
without them.

- **Rewinding at a prompt P** keeps the messages before P. P goes back in the composer, as
  Edit & resend puts a message there, so it can be changed and sent again.
- **Rewinding at a reply R** keeps the messages up to and including R. The composer is left
  as it is.
- **The chat keeps its id**, place, pin, tier, draft and title. The auto-fork is the new
  chat, titled "<title> (before rewind)" (§7).
- **Rewind undoes the conversation, not what was done in it.** Voyager writes the user
  approved, OS actions, saved memories and files the CLI changed all stay (§8).

## 2. The idea: swap, then fork

A rewind is a fork with the two chats' roles swapped:

| | Holds | Agent sessions |
|---|---|---|
| **Auto-fork** (new id) | A copy of **every** message, as a fork at the last message copies them (GAIA_FORKING_HLD.md §2): new ids, `origin` set, same seqs | **All** of the chat's `agentSessions`, every device's, moved over unchanged. It's the chat as it was, so every session still matches it exactly. |
| **The chat** (same id) | Its messages before the rewind point. The rest are erased. | **None of its own.** On this device, a fork record (GAIA_FORKING_HLD.md §5.3) cut at the rewind point, made from the session that just moved to the auto-fork. |

Why this way round, rather than cutting the chat's own session in place:

- **The chat's next send is a native fork**, `--fork-session --resume-session-at <keepAt>`,
  which Phase 2 built and live-tested, including its fallback to handoff. Take-back's
  in-place cut (`--resume-drops-turn`) only allows dropping one turn. Cutting several
  turns in place would need a new, unchecked use of an undocumented flag.
- **Nothing on disk changes.** The source session file is never cut. It now belongs to the
  auto-fork, which carries on from it with a plain `--resume`.
- **Codex needs nothing new.** Its thread moves to the auto-fork, and the chat hands over
  (§6). `thread/revert` would need every turn's id stored, which Gaia doesn't do (§10.2).
- **The rule from §9.6 holds by construction:** the chat never drops a message an agent
  session of its own still remembers, because it keeps no session that saw the erased
  messages. Other devices are the one gap, and §5 closes it.

## 3. Where a rewind is offered

"Rewind to here" in the message's right-click menu, after "Fork from here". It's offered
whatever state the chat is in (running here, running on another device, or with messages
queued), on every message except two. It's left out, not greyed out, as the menu leaves
items out:

- **a reply that is still streaming;**
- **a prompt with no reply yet.** That's the chat's last message, and its reply is
  starting here or running on another device. A streaming reply from another device doesn't
  show here until it ends (GAIA_FORKING_HLD.md §10.6), so its prompt looks unanswered.

Rewinding to any earlier message is still offered while either of those is at the end of
the chat. §4 step 0 covers a turn running here, and §5.1 one running elsewhere.

**A copy that would hold an image still being attached** is refused, with the fork's own
toast ("Try again in a moment").

There's no confirm dialog, since nothing is lost. The toast says where the later messages
went (§7).

## 4. Making the rewind

Steps 1 to 3 happen on the main instance, in one serial write, as `forkChat` is
(`GaiaChatStore.forkChat`). Call the rewind point K: the last message the chat keeps.
That's the message before P for a prompt, or R itself for a reply.

0. **A turn running here is stopped first**, and the rewind waits for it to end. Every
   running turn is after K, since rewinding to its prompt or reply isn't offered. The stop:
   - **never gives the message back** (GAIA_HLD.md §9.6). It's stopped the way an abort
     keeps its message, so no take-back runs. The prompt and the stopped reply both go to
     the auto-fork as an ordinary stopped turn. A fork at a stopped reply was fixed for this
     (BUG-368).
   - **pauses draining** (`setDrain(false)`). The queue stays with the chat, and nothing in
     it is sent by itself into the rewound chat, since it was written for the turns that
     were just dropped. The user sends or clears it. **To check while building:** what the
     queue holds per chat, and that pausing is enough.

   A turn that is still starting (`_cancelSend`) is cancelled the same way.
1. **The fork record for the chat.** `_forkRecord(chat, K, …)`, exactly as a fork at K
   works it out, **before** the sessions move. It reads the chat's own sessions, and
   handles a pending take-back cut and a prompt still being written. If it finds no cut, the
   chat has no record and hands over (§6).
2. **The auto-fork.** Copy every message, as `_forkChat` does at the last message:
   - new ids, `origin`, new card ids (BUG-367);
   - shared media (`GaiaMedia.share`);
   - `forkOf` = the chat's `forkOf ?? id`;
   - `curatedSeq` = the chat's (§9);
   - the chat's `rewinds` list (§5);
   - **plus all of the chat's `agentSessions`.**

   That last item is the one difference from a fork. A fork copies no sessions.
3. **The chat.**
   - Erase its messages after K, as take-back erases (§9.6, "Delete forever"), so the erase
     syncs.
   - Clear `agentSessions`.
   - Set the fork record from step 1.
   - Add the dropped range to `rewinds` (§5).
4. **This device's runners.** After step 0, any live process held for the chat's id is idle
   and runs a session that is now the auto-fork's. Release it, as an idle timeout would. BUG-366's fix already
   stops it being reused for a different session, so this is tidiness, not correctness.
   **To check while building:** take-back's pending cut in `claude-rewinds.json` and
   `_stopped` are keyed by chat id. A pending cut has to move to the auto-fork's id with its
   session.
5. **The composer**, for a rewind at P: P's text, files, quotes and window replace the
   draft, through `editMessage`. Images don't come back, as with Edit & resend. This happens
   only if the composer is empty (`draftEmpty`), as §9.6 gives a message back. Otherwise
   the draft stays, and the toast says P is still in the auto-fork.

The chat stays open. The auto-fork isn't opened.

## 5. Other devices and seqs

Two facts from the sync layer shape this section:

- **`agentSessions` merge per device key, and a missing key isn't a removal**
  (`firestore_document_mapper.dart`, the merge of `agentSessions`). Clearing the chat's
  sessions on this device doesn't clear another device's key. That device would then
  `--resume` a session that remembers the erased messages.
- **A send takes `list.last.seq + 1`** (`gaia_controller.dart`, the send). After the erase,
  that reuses the erased messages' seqs. Another device that hasn't had the erase yet would
  show two messages at one seq, and any session's `lastSeq` would become ambiguous.

**Design:**

- **Seqs are never reused.** The chat gains `rewinds`, a synced list of dropped ranges
  `(from, to, forkId)`: the first and last seq each rewind erased, and its auto-fork
  (§5.1). A new message's seq is one past
  the larger of the last message's seq and the highest `to`. That leaves gaps, which
  `gaiaUnseenTurns` handles already, since it works by `seq > lastSeq`. **To check while
  building:** every other place a seq is made, and anything that assumes seqs have no gaps.
- **Sessions inside a dropped range are stale.** Whenever a device picks its own session
  for a chat, it treats one whose `lastSeq` falls inside any range in `rewinds` as gone. It
  drops its own key and hands over (§6). This test is exact:
  - A session with `lastSeq` below a range never saw that range's messages.
  - A session with `lastSeq` above a range's `to` was recorded after that rewind, since
    those seqs didn't exist before it. So it saw only the kept branch.
- **Merging `rewinds` is a union**, so two devices rewinding the same chat both count.
- **The auto-fork copies `rewinds` but not the new range.** Its sessions saw the old
  branch, which is its own history.

This needs no timestamps or epochs on sessions. It does need a column for `rewinds` on
`GaiaChatsTable` (a migration) and the Firestore field.

### 5.1 A reply still coming from another device

The chat ends on a prompt P_live whose reply runs on device B, and this device rewinds to
an earlier message. P_live is in the dropped range and goes to the auto-fork. B's reply
hasn't been written yet. When it is, it's saved under the chat's id.

- **The range reserves the reply's seq.** When the chat ends on a prompt with no reply, the
  range's `to` is that prompt's seq + 1, the seq its reply will take. **To check while
  building:** that a reply's seq is always its prompt's + 1.
- **Each range names its auto-fork**: `(from, to, forkId)`.
- **A message in a dropped range is never shown in the chat**, never handed over and never
  curated there, on any device. That takes care of B's reply until it's moved.
- **The device that made the rewind moves it.** When B's reply reaches it through sync, it
  copies the message into the range's auto-fork (new id, `origin`, as §4 step 2 copies) and
  erases it from the chat. Only that device moves it, so no two devices make two copies. If
  it's offline, the reply waits, hidden, until it's back.
- **It waits 24 hours** from the rewind (`kGaiaLateReplyWait`, timed from the auto-fork's
  `createdAt`). A reply later than that stays hidden in the chat and isn't moved, so a
  prompt that's never answered doesn't keep the device checking (decided 2026-11-07).
- **B's session** records its `lastSeq` inside the range, so it's stale for the chat (§5).
  In the auto-fork, B's session is the one moved there at the rewind, from before P_live. So
  B's next send in the auto-fork catches up P_live and its reply, which that session already
  holds. That's a duplicate in its context, not a lost or wrong one. It's accepted as a
  known limit, rather than having B re-home its session record too.

## 6. When the chat hands over

The chat's next send falls back to the transcript handoff (GAIA_FORKING_HLD.md §6) when:

| Case | Why |
|---|---|
| Codex, always | Its thread went to the auto-fork, and Codex has no native fork here |
| No Claude Code session on this device reaches K, or `_forkRecord` finds no cut | No record is made (as for a fork, §5.5 there) |
| The native fork is refused, or its first turn fails with nothing shown | Phase 2's fallback, as built (§10.4, §10.5 there) |
| Any other device | Its session was stale (§5), or it never had one |

Handoff gives the agent the kept messages as a transcript, without tool results. That's
the same cost forks already accept.

## 7. UI

- **Menu:** "Rewind to here", after "Fork from here" (`gaia_app.dart`). It goes only in the
  companion, which is where forking lives. The Gaia page and the phone don't get it in this
  design.
- **Auto-fork title:** "<title> (before rewind)". As with " (fork)", a set title stops the
  utility model retitling it.
- **Auto-fork placement:** listed under the chat's original, as forks are
  (GAIA_FORKING_HLD.md §7). Its `lastMessageAt` is the chat's old one, so it sits among
  forks by when its conversation last moved. It doesn't jump to the top of the group.
- **Toast:** "Rewound. The later messages are in '<title> (before rewind)'". If the
  draft was kept: "…P is there too; your draft was kept". If Gaia's toasts can carry an
  action, add "Show", which opens the auto-fork.
- **The chat's own title** doesn't change, even if it was made from the first prompt and
  that prompt was dropped.

## 8. What a rewind doesn't undo

| Effect | What happens |
|---|---|
| Voyager writes the user approved through cards (todos, events, journal) | Stay. The cards move to the auto-fork, as answered cards. |
| Open cards in the dropped range | Move to the auto-fork with new ids, still open there |
| OS actions (windows, keys, clipboard, opened apps) | Stay |
| Memories already saved by the curator | Stay (§9) |
| Files the CLI changed in its working folder | Stay. See §10.3. |
| Usage | Already spent |

The menu item's tooltip, or the toast, says "Rewinds the conversation, not what was done".

## 9. Memories

- **The chat:** `curatedSeq` stays as it was. New messages get seqs past every dropped
  range (§5), so they're above it and get curated, and the kept ones aren't curated twice.
  No change to the curatedSeq merge, which only moves forward, is needed.
- **The auto-fork:** `curatedSeq` is copied, as in a fork, so already-curated turns aren't
  read again (BUG-369).
- **The dropped turns that weren't curated yet stay uncurated. This is the intended
  behaviour** (decided 2026-11-06). A rewind says the conversation after K isn't the one to
  keep, so nothing is learned from it unless the auto-fork is carried on, and its curator
  then reads them as usual. The curation timer pending for the chat (`_curateSoon`) stays
  with the chat and finds nothing new. A late reply moved into the auto-fork (§5.1) isn't
  curated either.

## 10. Phases

| Phase | Work | Done when |
|---|---|---|
| **1. Rewind** | §3 to §9 on both CLIs: native for Claude Code through the fork record, handoff for Codex | See §10.1 |
| **2. Codex native (optional)** | §10.2 | A Codex rewind's next reply recalls a tool result from a kept turn |
| **3. Files (not planned)** | §10.3 | n/a |

### 10.1 Phase 1

**Work:**
- **Model.** Add `rewinds` to `GaiaChat`, with a column, migration and Firestore field, and
  union merging. Add the stale-session test wherever a device picks its own session.
- **Seq allocation.** Make it skip past `rewinds` everywhere a seq is made.
- **The rewind.** Add `GaiaController.rewindChat(message)` (§4), and a store operation,
  `GaiaChatStore.rewindChat`, that writes the auto-fork, its copies, the erase and the chat
  change in one serial write, over a new pipe request.
- **A turn running here** (§4 step 0): stop it without a give-back, and pause draining.
- **Late replies** (§5.1): hide messages in a dropped range, and have the rewinding device
  move them into the range's auto-fork.
- **Runners.** Release the old live process. Move any pending take-back cut to the
  auto-fork.
- **UI** (§3, §7).

**Done when:**
- **Claude Code, native.** Rewind at an earlier prompt, after a tool result that no reply
  repeated (use the forking doc's random-number check, §10.4 #1 there). Then:
  - The chat's next send is `--fork-session` cut at K.
  - Its reply recalls the number if K is after that turn.
  - It doesn't know anything said after K.
  - The auto-fork's next send is a plain `--resume` of the old session. It knows
    everything, including the dropped turns.
- **Codex.** Same shape. The chat hands over and doesn't know the dropped turns. The
  auto-fork resumes the old thread.
- **The prompt comes back.** Rewinding at P with an empty composer puts P's text in it.
  With a draft typed, the draft stays.
- **Seqs.** After a rewind and a send, the new prompt's seq is past the dropped range.
  Rewinding twice gives two ranges.
- **Second device.**
  - Its stale session isn't resumed, and its first send there is a handoff that doesn't
    know the dropped turns.
  - The auto-fork shows there with every message and image.
  - Sending in the auto-fork there resumes that device's session.
- **Offered where §3 says.** It's offered while running and with a queue, but not on a
  streaming reply or a prompt with no reply.
- **Rewinding while a turn runs here** stops it without giving the message back. The
  prompt and the stopped reply are in the auto-fork, and the queue isn't drained into the
  chat.
- **Rewinding while a reply runs on another device:** that reply never shows in the chat.
  Once it ends, it's in the auto-fork, once only, and the chat's next send doesn't know it.
- **Memories:** the dropped turns that weren't curated aren't curated, in the chat or in the
  auto-fork (until it has a turn of its own).
- **Take-back** inside the rewound chat and inside the auto-fork still passes GAIA_HLD.md
  §9.6's checks. The existing forking tests pass.

**Tests:** in `test/gaia_controller_test.dart`, a "rewinding" group covering:
- at a prompt and at a reply;
- the sessions move, and the record is cut at K;
- the composer, empty and with a draft;
- seq skipping;
- stale sessions inside and outside a range;
- what's not offered.

In `test/gaia_migration_test.dart`, the new column. In the sync mapper tests, the `rewinds`
union.

#### Live test results (2026-11-06)

Run on `gaiaqa`, from a debug build of the working tree copied aside, with Claude Code
2.1.319 (Haiku, Quick) and Codex 0.166 (Deep), and `qb` as the second device. Native forks
were confirmed from the CLI's command line, sessions and seqs from the companion and the
database.

| Check | Result |
|---|---|
| Claude Code, native | Pass. Three turns: a Bash tool printed a number only its result held, then BANANA, then KIWI. Rewound at the KIWI prompt (it came back in the empty composer). The chat's next send was `--resume <old> --fork-session --resume-session-at <keepAt>`; it gave the number, didn't know KIWI, and took seqs 6 and 7 past the range 4–5. The auto-fork's send was a plain `--resume` of the old session and knew KIWI. The chat's old idle process was gone. |
| Codex | Pass. ALPHA then ZULU, rewound at the first reply. The chat started a new thread with a `<gaia_transcript>` holding ALPHA and not ZULU, and answered ALPHA. The auto-fork resumed the old thread and answered ALPHA, ZULU. |
| The prompt comes back | Pass, empty composer (above). With a draft typed, the draft stayed. |
| Seqs | Pass. Two rewinds of one chat gave two ranges; every new message took a seq past both. |
| While a turn runs here | Pass after BUG-371. A long reply stopped at 911 characters; the prompt and the cancelled reply (1,107 characters by then) are in the auto-fork; no take-back cut was made (`claude-rewinds.json` `{}`); drain was paused and the queued prompt still waited 25 s later. The first run drained the queue into the rewound chat: BUG-371, fixed. |
| Not offered where §3 says | Pass (`canRewind` read live): not at a streaming reply, its prompt, a prompt last in the chat, or the last reply. |
| Second device | Pass. `qb` set CEDAR in a chat started on `gaiaqa`, which then sent an image. On `gaiaqa`, rewound to the first reply. `qb`'s session (its `lastSeq` inside the range) wasn't resumed: its send there was a `--session-id` handoff that answered NONE. The auto-fork showed on `qb` with all its messages and the image file, and a send in it resumed `qb`'s own session (`--resume`) and knew CEDAR and ONYX. `qb`'s write brought `gaiaqa`'s old session key back into the chat (a missing key isn't a removal); `gaiaqa` treated it as stale and still forked natively from the record. |
| A reply running on another device | Pass. `qb` was streaming a long reply (prompt setting ONYX) when `gaiaqa` rewound; the range ran to the reply's seq. The 11,374-character reply never showed in the chat on either device, and once it ended it was in the auto-fork once, still once 20 s later. The chat's next sends didn't know ONYX. |
| Memories | Pass. A chat stated a favourite tree, then a hobby, and was rewound to drop the hobby turn. After the 10-minute curator: the tree was proposed, the hobby not; the chat's `curatedSeq` is 1; the auto-fork, with no turn of its own, stayed at -1. Auto-forks that did get a turn were then curated, as §9 says. |
| Take-back | Pass in both. In an auto-fork and in a rewound chat (on its native fork), a quick stop gave the message back, a real cut was recorded in the rewound chat, and the next turn didn't know the stopped message. The Gaia tests (forking and take-back included) pass. |

### 10.2 Phase 2: Codex native (optional)

Two possible ways, neither checked:
- **`thread/fork`, if the app server has it.** Use it the way §2 uses Claude Code's fork:
  the auto-fork keeps the thread, and the chat forks it at K.
- **`thread/revert {beforeTurnId}`** on a copy of the thread. This needs each message to
  store its Codex turn id (a new column), since today only the running turn's id is kept
  (`codex_app_server.dart`).

Look at `codex app-server generate-json-schema --experimental` before choosing.

### 10.3 Files (not planned)

Claude Code's own rewind can restore files it edited. Whether that is reachable from
stream-json mode, and whether Codex's `thread/revert` touches files, hasn't been checked.
Gaia's CLIs mostly act through Gaia's tools rather than by editing files, so this is left
out. If it's wanted, start with a contract check in `gaia_cli_contract_test.dart`.

## 11. Open questions

- **Rewind on the Gaia page and the phone:** left out, as fork is today.
- **A keyboard shortcut**, like Claude Code's Esc Esc: none proposed, since Esc is busy in
  the composer (Vim, stop).

## 12. Files likely touched

- `lib/features/gaia/companion/gaia_controller.dart`: `rewindChat`, seq allocation, the
  stale-session test where a session is picked.
- `lib/features/gaia/companion/gaia_app.dart`: the menu item.
- `lib/features/gaia/host/gaia_chat_store.dart`, and the pipe: the rewind write.
- `lib/domain/models/gaia_models.dart`, `lib/data/database/app_database.dart`: `rewinds`,
  its column and migration.
- `lib/core/sync/firestore_document_mapper.dart`: `rewinds` and its union merge.
- `lib/features/gaia/adapters/claude_code/claude_code_runner.dart`: moving a pending
  take-back cut, and releasing the old live process.
