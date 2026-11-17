# Gaia — Memory Topics and Recall (HLD)

Status: **Phases 1-3 built (2026-11-16).** Each is unit- and controller-tested, and the
live checks of §15.4, §16.4 and §17.4 were run on 2026-11-16 (§18): all passed except
those that need the phone, a week of real chats, more §11 bursts, or Phase 4 (§19). Stage 2
(Phase 3) is **on by default since 2026-11-17** (§25.1); the debug-menu switch now only turns
it off. The first §11 burst is in §11; the
threshold isn't settled (§18.3). Decisions after the live pass are in §18.4: stage 1 is a
candidate list only, and without stage 2 recall is left to `memory_search`. **Phase 4 (the
Memories tab tree) built 2026-11-16** (§20): tested, and checked live off-screen except for
drags and what §20.5 lists. **Phase 5 (placement on capture, suggested topics, the curator's
smaller input) built 2026-11-16** (§21): tested, and placement and the curator checked
with the real utility model off-screen. The on-screen checks of §19, §20.5 and §21.4 were run
on 2026-11-17 (§22): all passed except the phone's, and BUG-381 (a memory card's chips didn't
follow edits) was found and fixed. **Phase 6 (topic merge, Sort these, and pin and merge
suggestions) built 2026-11-17** (§23): unit-, controller- and widget-tested, and checked
live on 2026-11-17 (§24): all passed except the curator's pin flag (not yet seen) and the
phone's; BUG-382 (Sort these' Accept also makes a memory's older offer) found, not fixed.
**The checks left after §24 were run on 2026-11-17 (§25):** the curator's pin flag and its
filing in a project chat, a real Codex turn calling `memory_search` with `topic`, Sort these'
× on one of two chips, and the phone for every phase. All passed. BUG-383 (the phone's first
reveal from a recall chip doesn't scroll) found, not fixed. **Still open:** §11's two clean
bursts and a week of real chats, which take separate days and now tune stage 2's later-message
trigger rather than decide whether it's on; and BUG-378, BUG-382 and BUG-383. Drafted 2026-11-15. This replaces the memory index in GAIA_HLD.md §11 and
the project memories in GAIA_PROJECTS_HLD.md §6, and it changes one decision in §3.3 of that doc
(§7 here).

## 1. Summary

Today every new session's system prompt lists every active memory, one line each, cut at 200
characters (`gaiaMemoryIndex`, `gaia_memories.dart:318`). Nothing caps how many lines go in.
That's the right design for a few dozen memories. At hundreds, unrelated memories crowd the
prompt and cost tokens in every session, and at thousands it stops working. The goal is a
memory store that holds thousands of memories across many unrelated subjects, while each chat
sees only the ones that matter to it.

- **Topics** (§3) organise memories into a tree you can browse and edit: University → CS246 →
  Assignments. A memory can sit in several topics, so "Assignments use C++" can be in both
  CS246 and C++.
- **Gaia recalls memories, so the model doesn't have to go looking for them** (§4). Before each
  message is sent, Gaia picks the memories that fit it and adds them to that message in full. A
  free local match runs on every message. Haiku makes the final pick on a chat's first message,
  and later only when the local match finds new strong candidates.
- **The system prompt keeps only a small fixed part:** pinned memories ("always true about me")
  and a list of topics. Its size doesn't grow with the number of memories.
- **Every recall shows in the reply** as a "Recalled 3 memories" chip (§4.5). Today, a memory
  used from the index leaves no trace.
- **Projects stay workspaces.** Each project gets its own topic, which takes over its memories
  (§7). A project's memories can now come up in any chat, and they rank first in their own
  project's chats.
- **Claude Code comes first.** Codex gets the same recall, since it's text added to the turn,
  but the Haiku stage needs a Claude account (§9).

## 2. Why not the alternatives

- **The full index with a size limit.** Simple, but past the limit Gaia knows only the memories
  that made the cut. It needs the model to think of calling `memory_search` for the rest.
- **A graph the model walks itself** ("look for relevant memories before working"). The
  instruction is followed unreliably, and each step is a tool round trip before the real work
  starts. In the "Add Gamma snippet" chat (2026-11-16), Haiku gave two different answers about
  where it got a file path from. Recall that Gaia controls doesn't depend on that.
- **Embeddings.** Neither CLI provides them, and a local model is a large dependency. A word
  match that includes topic names (§4.2), followed by a Haiku pick, should be enough for short
  facts. Embeddings can come in later as one more scoring signal if recall misses too often.

## 3. Topics

### 3.1 Data model

A new synced collection, plus three fields on memories. It's mirrored in drift and synced
through the outbox like the other Gaia collections (GAIA_HLD.md §8).

| Collection | Doc | Fields |
|---|---|---|
| `gaia_memory_topics` (new) | one per topic | name, `parentId?`, `projectId?`, createdAt, updatedAt, version, deletedAt |
| `gaia_memories` | one per memory | + `topicIds` (list), + `pinned` (bool), + `suggestedTopic?` ({name, parentId?}) |

- **Topics form a tree.** Each topic has at most one parent. A memory can be in any number of
  topics, and a memory in none is shown under **Unsorted**.
- **A `parentId` that points nowhere means a root topic.** A `topicIds` entry that points
  nowhere is ignored. This is the same rule as a chat's `projectId` (GAIA_PROJECTS_HLD.md §2),
  and it covers the same sync races.
- **No cycles.** Re-parenting a topic under one of its own descendants is refused in the UI and
  in the repository. If sync ever produces a cycle anyway (two devices re-parenting at once),
  readers break it at the topic with the oldest `updatedAt` and treat that one as a root.
- **`topicIds` syncs as a whole list**, and the document with the higher version wins, like
  the other Gaia collections. A device that edited a memory offline can therefore undo a move
  or merge made elsewhere for that one memory. It then shows under its old topic, or in
  Unsorted if that topic is gone, and you can move it again. That's accepted rather than
  merging the lists per entry.
- **`tags` stay** as extra keywords for matching (§4.2), with no structure. The curator keeps
  writing them.
- **`projectId` on memories** is read once by the migration (§8) and never written after it.
  The column stays, so older builds still sync.

### 3.2 Editing (Gaia page → Memories)

The Memories tab becomes two panes: the topic tree on the left, and the selected topic's
memories on the right. "Include subtopics" is on by default.

| Action | How |
|---|---|
| Move a memory | Drag it onto a topic: that topic replaces the ones the memory has inside the selected topic's subtree. With "Include subtopics" on, that can be a subtopic rather than the selected topic itself. |
| Add a memory to a topic | Ctrl+drag onto a topic: it keeps its current topics too. |
| Remove from a topic | The memory's topic chip → ×. A memory with no topics left goes to Unsorted. |
| Re-parent a topic | Drag it onto another topic, or onto the tree's root area. |
| Rename | Right-click → Rename, or F2. |
| New subtopic | Right-click → New subtopic. A "New topic" button sits above the tree. |
| Merge | Right-click → Merge into… → pick the topic to keep. |
| Delete | Right-click → Delete. Memories and subtopics are kept (below). |

- **Merging A into B:** every memory in A gets B instead (duplicates dropped), A's subtopics
  move under B, and A goes to the trash, all in one batch. A project's topic (§7) can be the
  topic kept, but not the one merged away. Its menu item is disabled, with a note saying why.
- **Deleting a topic:** its memories lose that topic and stay where else they are, or go to
  Unsorted. Its subtopics move up to its parent. Restoring it from the trash brings back the
  topic only, for the same reason restoring a project doesn't pull its chats back in.
- **A search box** above the tree filters both panes by text.
- **Inbox, Remembered and Archived** stay as sections inside whichever topic is selected, with
  the inbox shown first across all topics.
- **Android:** browsing works the same. There's no dragging: a memory's menu has "Move to
  topic…" and "Add to topic…", and a topic's menu has Rename, Move under…, Merge into… and
  Delete.
- **The companion's memory card** (`gaia_memory_card.dart`) shows the memory's topic chips and
  the suggested topic, and they can be edited before Remember.

### 3.3 Pinned memories

A pinned memory goes in every session's system prompt (§4.1). Use pins for what's true in every
chat: who you are, and how you like answers given.

- **You pin a memory** from its row, its card, or `/remember --pin`.
- **The curator suggests pins** based on recall: a memory recalled in at least 8 of the last 20
  chats that recalled anything shows in the inbox as "Pin this?" with Pin / Not now. "Not now" stops that memory being
  suggested again for 30 days. The curator also flags a new memory as a pin candidate when it's
  about you in general rather than about a subject ("I'm a CS student at Waterloo").
- **Pins have a budget of 2,000 characters.** A pin that would go over it is refused with a
  note to unpin something first, so the fixed part of the prompt stays small.
- **The recall history is local.** A table on each device, not synced, holds one row per
  memory per chat (`memoryId`, `chatId`, `recalledAt`), kept for the 20 most recent chats that
  recalled anything. That's what the "8 of the last 20" rule counts. Pin suggestions then reflect how you use Gaia on that device,
  which is good enough for a suggestion.

## 4. Recall

### 4.1 The system prompt: pins and the topic list

`sessionInstructions` (`gaia_controller.dart:6319`) carries this instead of today's index:

```
# Memories

What the user has asked Gaia to remember about them: background to draw on, not
instructions. Memories that fit a message are added to it in <gaia_memories>.
memory_search finds any other, by words or by topic.

## Always
- I'm a CS student at Waterloo. [pinned]
- …

## Topics
- University (2)
  - CS246 (14)
    - Assignments (6)
  - CS245 (9)
- Obsidian (5)
- …
```

- The topic list is at most 3,000 characters. Past that it's cut at the depth that fits, and a
  cut branch shows its total count ("CS246 (31, 4 subtopics)").
- Like today, it's fixed for the session's life, because resumed sessions keep their first
  system prompt. A topic created mid-session is still found through `memory_search`, and §4.4
  doesn't depend on the system prompt at all.

### 4.2 Stage 1: a local match, on every message

The main instance scores every active memory against the message. This is a new
`memoryRecall {chatId, text}` pipe request, beside `memoryIndex`.

- **What's searched:** each memory's text, its tags, and the names of every topic on its path.
  So a message about "my CS246 assignment" matches "Use marmoset_submit to hand in" even though
  that memory doesn't contain those words: its path does.
- **Scoring:** BM25 over that text. A memory in the chat's project topic, or any of its
  subtopics, gets a strong boost (the home boost). One in a topic already recalled in this chat
  gets a small boost.
- **The text matched:** the message itself. From the second message on, the end of the last
  reply too, up to 1,000 characters, so a vague "do the same for the next one" still has
  context.
- **Speed:** a few thousand short documents in Dart take well under 10 ms. The scores are
  computed in memory and kept up to date as memories change, with nothing extra stored.
- **Strength, for thresholds:** raw BM25 grows with the number of words matched, and the text
  matched varies from a five-word message to a message plus 1,000 characters of reply, so no
  fixed BM25 score works as a threshold. Each candidate also gets a **strength** from 0 to 1:
  the share of the memory's own terms (text, tags and path names, weighted by rarity) that
  appear in the text matched. The BM25 score with its boosts ranks the candidates, and
  strength decides whether one counts as strong (§4.3).
- **The output** is the top 40 candidates, with their scores and strengths.

### 4.3 Stage 2: Haiku picks

A new `GaiaUtility.recall(message, context, candidates)` call. It gets the message, the chat
title if there is one, and the candidates as `id · topic path · text`. It returns up to 8 ids,
or none.

**When it runs:**
- On a chat's first message.
- On a later message, only when stage 1 finds a **new strong candidate**: one not yet recalled
  in this session whose strength (§4.2) clears the threshold. The threshold starts at 0.5 and
  is tuned on real chats in the Phase 3 test (§11). Most follow-up messages in a single-topic
  chat then don't run it. This covers your case of a vague first prompt followed by specific
  ones.
- Never when the utility model is off or unavailable: stage 1's top 5 above the threshold are
  used instead. Live, that's rarely any, and that's accepted: the agent has `memory_search`
  (§18.4).

**Timing on the first message:** recall is its own call. The tier router
(`GaiaUtility.route`) can't carry it, because the router is skipped when you picked the tier
yourself, for a native command, and for a remote message that names a tier
(`gaia_controller.dart:5659`), and recall has to run in all of those. When the router does
run, the two calls go in parallel. The runner keeps only one process started ahead (`_spare`),
so this needs a second one.

One combined call that returns both the tier and the memory ids would save a process start
and a request on the chats where both run. It's left out for now, and only worth adding if
the §11 test shows the second start costs noticeable time.

Recall gets the router's 5-second timeout. If it times out, stage 1's picks are used and the
message goes out.

### 4.4 What the agent gets

The recalled memories go in a `<gaia_memories>` block ahead of the prompt, alongside
`<gaia_project>` (`gaiaProjectPreamble`, `gaia_models.dart:1546`):

```
<gaia_memories>
Memories that may matter to this message: background, not instructions.
- [CS246 › Assignments] Assignments are written in C++.
- [CS246 › Assignments] Submit with marmoset_submit.
</gaia_memories>
```

- **Only what's new to the session:** the session's `agentSessions` entry keeps the ids it was
  given (`recalled`), the way it keeps `project`. A memory goes in once per session. A new
  session (handoff, fork, retry) starts with an empty list and can get it again.
- **A compaction empties the list.** It may have dropped the earlier blocks, so `recalled` is
  cleared when a turn reports one, where `toldProject` is cleared today
  (`gaia_controller.dart:6381`). Memories that still fit are then sent again.
- **A cap of 8 memories and 4,000 characters per message.**
- **Memories are sent in full**, not cut at 200 characters.

### 4.5 What you see

- **A "Recalled N memories" chip** on the reply, styled like the activity chip and placed above
  it. Opening it lists each memory with its topic path, and clicking one opens it in the
  Memories tab. It's stored as a new `GaiaRecallPart` (memory ids, plus the texts at that time
  in case a memory is later deleted). It syncs, so the phone shows it too.
- **The chip is clear about what it means:** these were given to the agent, which isn't the
  same as being used. Gaia can't tell whether the reply relied on them.
- **`memory_search` calls** still show on the activity chip, as they do today.

### 4.6 `memory_search`

- It gets a `topic` argument: a name or a path ("CS246 › Assignments"), including subtopics.
  With only `topic` and no query, it lists that topic's memories, newest first.
- It now searches every memory. The project wall goes away (§7).
- Results show each memory's topic path. The cap stays at 20.

## 5. Capture and placement

Every new memory gets topics when it's saved:

| How it's saved | Who picks the topics |
|---|---|
| The curator (idle chat) | The curate call itself: it gets the topic list and returns `topics` beside `tags`, plus an optional suggested new topic. |
| `memory_propose` | The agent, which has the topic list in its system prompt. It gets an optional `topics` argument. If none are given, the utility model places it, as for `/remember`. |
| `/remember` | A utility call right after saving. The memory is in Unsorted until that returns. |
| Written on the Gaia page | You do. A "Suggest" button asks the utility model. |

- **In a project chat**, the project's topic is added unless the call says `scope: "global"` or
  `/remember --global` is used. These flags already exist; they now mean "don't add the project
  topic".
- **New topics are never created silently.** A suggested topic is kept in `suggestedTopic` and
  shown on the memory's card and inbox row as a chip ("+ New topic: Assignments under CS246").
  Accepting it creates the topic. Until then, the memory sits in its best existing topic, or in
  Unsorted.
- **Merge suggestions:** two topics with near-identical names, or most memories in common, show
  as "Merge X into Y?" in the inbox. This comes in a later phase (§10).
- **Duplicate checks** stay as they are (`gaiaMemoryKey`), but with no project walls: a memory
  that says the same as any active one isn't saved again.
- **The curator's input shrinks.** Today it gets the whole index to avoid duplicates
  (`gaia_utility.dart:245`). It gets stage 1's top 40 candidates for the transcript instead, so
  its input doesn't grow with your memory count. The candidates are the 40 nearest active
  memories plus the 20 nearest waiting, archived or dismissed ones (§25.4, §25.5), so it
  doesn't offer one again in other words; not one the user deleted after keeping it.

## 6. Starting topics

Gaia ships with no topics except one per project (§7). You write a starter set yourself on the
Memories tab. After that, the curator only suggests new topics (§5). The Unsorted view gets a
**Sort these** button: the utility model places them in batches of 30, and each placement
shows as a suggestion you accept or change, never applied without you.

## 7. Projects

Projects stay workspaces: a folder, chats and the `project_*` tools. Their memories become a
topic.

- **Each project has a topic**, created with the project, with the topic's `projectId` pointing
  to it. Its id is always `project-<projectId>`, so two devices can't create two topics for
  one project, and the topic can still be found after its `projectId` is cleared. It starts at
  the root, and you can move it under another topic (for example, CS246
  under University).
- **Renaming either one renames both** while they're linked.
- **Deleting a project always keeps its topic and memories.** The topic's `projectId` is cleared
  and it becomes an ordinary topic, whether or not "Also delete its chats" is checked. This
  changes the 2026-11-10 decision in GAIA_PROJECTS_HLD.md §3.3, where checking the box trashed
  the memories. Restoring the project looks the topic up by its id and links it again. If it's
  gone (deleted, or merged into another topic since), the project gets a new one under the
  same id.
- **No walls.** A project's memories can be recalled in any chat. In the project's own chats,
  they get the home boost (§4.2).
- **`<gaia_project>`** stops listing the project's memories. Recall covers them. The block names
  the project's topic instead, so the agent can `memory_search` it.

## 8. Migration

This runs once on the main instance after the first pull with the new schema. It's safe to run
more than once.

1. **One topic per live project**, with the id every project topic uses (`project-<projectId>`,
   §7). Both devices then write the same document, and racing devices can't create two.
2. **Each memory with a live `projectId`** gets that topic in `topicIds`.
3. **Every other memory** has no topics and shows in Unsorted, ready for **Sort these** (§6).
4. **Nothing is pinned automatically.** With only 10 memories today, you choose your pins on the
   tab.

The schema goes from 200 to 201: the new table, plus `topicIds`, `pinned` and `suggestedTopic`
columns on `gaia_memories_table`, using `_addColumnIfNotExists`. The local recall-history table
(§3.3) is added in the same version.

## 9. Codex

Recall is text added to the turn, so Codex chats get the same `<gaia_memories>` block and the
same system-prompt part (in `developerInstructions`, where the index goes today). The Haiku
stage runs on Gaia's Claude account. With no Claude account set up, it's stage 1 only. Codex
is tested in the live pass but isn't a gate for any phase.

## 10. Phases

| Phase | What |
|---|---|
| 1 | Data model, migration, project topics, `memory_search` by topic with no walls. The system prompt and `<gaia_project>` keep today's index. |
| 2 | Stage 1 recall, the `<gaia_memories>` block, `recalled` per session, the recall chip. Pinning by hand. The system prompt switches to pins + topic list, and `<gaia_project>` stops listing memories. |
| 3 | Stage 2 (Haiku pick) as its own call, threshold tuning, and **the plan-usage test (§11)**. |
| 4 | The Memories tab tree: new, rename, move, add, re-parent, delete, search. Android menus. A project's filter includes its subtopics, labelled by topic, not "Global" (§18.4). |
| 5 | Placement on capture, suggested topics on cards and in the inbox, the curator's smaller input. Then check stage 2's word-mismatch misses again (§18.4). |
| 6 | Topic merge, **Sort these**, and pin and merge suggestions from the recall history. |

- **The index stays until recall replaces it.** The system prompt switches in the same phase
  that recall arrives (Phase 2). Switching earlier would leave memories reachable only
  through `memory_search`, with nothing pinned yet.
- **Recall comes before the tree.** It's the part that changes every chat, and it barely
  depends on topics: it matches on text and tags, and project topics exist from Phase 1.
  Until Phase 4 those are the only topics, so path names add little, and that's fine at the
  current 10 memories.
- **Merge, Sort these and the suggestions come last.** They pay off once there are enough
  memories and topics to tidy.

## 11. Test: what recall costs on the plan

**To do once Phase 3 is built, before stage 2 is turned on by default.** Stage 2 was turned on
by default on 2026-11-17 before the clean bursts (§25.1), so what's left here tunes the
threshold and decides whether stage 2 keeps running on later messages.

Gaia runs on a Claude subscription, not the API, so the cost that matters is how much of the
**5-hour limit** each Haiku pass uses, not dollars. That percentage varies over time, so a
single reading isn't enough to settle it.

**What to measure:**
- **Tokens per pass.** Each utility call's result line already carries usage
  (`claude_code_events.dart:423`). Log input, cache-read and output tokens for each recall pass
  with a debug flag. The estimate is about 3–5k tokens in and under 100 out, but measure it.
- **5-hour % per 100 passes.** In `gaiaqa`, read the 5-hour window (`GaiaUsage.fiveHour`, from
  `claude_oauth_usage.dart`) before and after a burst of 100 scripted recall passes, with
  realistic messages and around 300 memories seeded across topics, while nothing else runs on
  the account. The reported percentage moves in coarse steps, so the burst needs to be big
  enough to move it. Repeat at least three times, on different days and times of day. This
  uses your real account's limit, so expect each burst to cost a little of your actual
  allowance.
- **Compared with a normal turn:** run the same check for 20 typical Standard-tier turns, so the
  result can be read as "recall adds about N% to a turn".
- **Latency:** time added before the first token, with a process started ahead and cold, for
  recall alone and for recall in parallel with the router. If the second process start adds
  noticeable time, that's the case for the combined call (§4.3).
- **How often it runs:** across a week of your own chats, how many messages ran stage 2 under
  the new-strong-candidate rule (§4.3), compared with the first message alone.

**What it decides:** the threshold (now only stage 2's trigger on later messages, §18.4), and
whether stage 2 runs on later messages or only on the first one. Write the numbers into this section. If the cost turns out too high, the fallback is
stage 2 on the first message only, with stage 1 alone after that.

**First burst, 2026-11-16 18:32-18:40 (Monday evening)** (`gaiaqa`, qa-128, 290 active
memories across 20 topics, debug build of the working tree; details in §18):
- **Tokens per pass** (91 passes over 99 realistic messages; 8 had no candidate, so no pass):
  mean 1,158 (input 2, cache read 40, cache write 1,066, output 51), median 1,044, most
  2,586. Lower than the 3-5k estimate: the candidate list is short once stage 1 has cut it.
- **5-hour %:** 24% before, 31% after. **This doesn't measure recall:** the account was in use
  by other Claude Code sessions the whole time (it went on climbing about 1% a minute between
  bursts), so the step can't be put down to the passes. The CLI does send
  `rate_limit_event`: every pass logged a figure, none "not reported". A clean reading needs
  the account otherwise idle.
- **Against 20 Standard-tier turns** (Sonnet, short answers, new chats): mean 21,145 tokens a
  turn (cache read 16,587, cache write 4,416, output 139). A recall pass is about 5% of that
  in raw tokens, about a quarter of its cache writes.
- **Latency:** with a process started ahead, median 664 ms, 90th percentile 1,777 ms, and 4 of
  91 over the 5-second timeout (up to 12 s). Cold starts seen live: 1,086 ms and 2,185 ms,
  well under the 2.6-4.2 s §17.2 item 7 expected. Beside the router on a first message, each
  on its own process: router 581 ms, recall 1,405 ms; the message waited for recall. During a
  slow patch on the service (19:02-19:07) 3 of 20 passes hit the timeout and stage 1 was used.
- **Still to do:** two more bursts on other days with the account otherwise idle, and how
  often stage 2 runs across a week of Juno's chats.

## 12. Out of scope

- Embeddings, or any model other than the utility model.
- A graph view of the tree. The two-pane tab is the browser for now.
- Syncing the recall history.
- Memories shared between Gaia users.

## 13. How it's checked

**Unit tests:**
- Topic tree: re-parenting refuses cycles, a cycle from sync is broken at the oldest topic,
  merge moves memories and subtopics, deleting a topic sends its memories to Unsorted.
- The migration runs twice with the same result, and two devices produce one topic per project.
- Stage 1: matching through topic path names, the home boost ranks project memories first, a
  memory already recalled in the session isn't sent again, the caps hold.
- The topic list cuts at the right depth to stay within 3,000 characters. Pins are refused past
  2,000.
- The parser for Haiku's pick: bad JSON falls back to stage 1.
- Strength stays between 0 and 1 and doesn't change with the length of the text matched.

**Controller tests:** the `<gaia_memories>` block goes on the first message and only new
memories on later ones. A handoff gets the list again, and so does the turn after a
compaction. Recall runs on a first message whose tier you picked, where the router doesn't. A `GaiaRecallPart` is written and shows
as a chip.

**Widget tests:** the tree's drag to move, Ctrl+drag to add, re-parent and merge, in the
desktop variant under the memory watchdog.

**Live, in `gaiaqa`:** seed about 300 memories across a dozen topics. Then:
- A CS246 chat recalls its assignment memories and nothing from Obsidian.
- A vague first message followed by a specific one triggers stage 2 on the second message.
- Recall works in a Codex chat.
- The phone shows the recall chip.
- Then the §11 test.

## 14. Files likely touched

- `lib/domain/models/gaia_models.dart`: topics, memory fields, `GaiaRecallPart`, the preamble.
- `lib/data/database/app_database.dart`, `drift_repositories.dart`,
  `lib/core/sync/firestore_document_mapper.dart`
- `lib/features/gaia/host/gaia_memories.dart`, `gaia_host.dart`: recall, search, migration,
  placement.
- `lib/features/gaia/utility/gaia_utility.dart`, `claude_utility_runner.dart`: recall, a
  second process started ahead, placement.
- `lib/features/gaia/companion/gaia_controller.dart`, `gaia_app.dart`,
  `gaia_memory_card.dart`, `gaia_activity_chip.dart` (the recall chip)
- `lib/features/gaia/tools/gaia_mcp.dart`: `memory_search` topic, `memory_propose` topics.
- `lib/features/gaia/page/gaia_page.dart`: the Memories tab tree.
- `GAIA_HLD.md` §11 and `GAIA_PROJECTS_HLD.md` §3.3 and §6: notes pointing here.

## 15. Phase 1 build notes (2026-11-16)

### 15.1 What was built

- **Data model (§3.1, §8):** `GaiaMemoryTopic` and the synced `gaia_memory_topics` collection
  (drift table, outbox, pull, live sync, backup, a "memory topic" trash kind), and `topicIds`,
  `pinned` and `suggestedTopic` on memories. Schema 200 → 201 adds both new tables and the three
  columns. A write from an older build, which has none of the three fields, leaves them as they
  are on this device.
- **The recall-history table** (§3.3) is created in 201 as §8 says, local-only and left out of
  backups. Nothing writes it yet.
- **The tree** (`GaiaTopicTree`, `gaia_memories.dart`): paths, subtrees, finding a topic by
  name or path, and a sync-made cycle broken at the topic changed longest ago.
- **Project topics and the migration (§7, §8):** `GaiaMemories.syncProjectTopics` and
  `keepProjectTopics`. Deleting a project keeps its topic and memories and clears the topic's
  link. Restoring it links the topic again.
- **`memory_search`** (§4.6): the `topic` argument, no project wall, topic paths in results.

### 15.2 Decisions made while building

1. **No migration flag.** A project's topic being created for the first time is the migration
   for that project: that's when the memories naming it are filed in it. A topic already there,
   even a tombstone, means it has been done, so a memory taken out of it later stays out. Two
   devices doing it at once write the same documents.
2. **When it runs:** on the main instance (Windows), after each startup pull and then whenever
   projects change, as §8 asks. The pull matters because the outbox writes with a blind merge,
   so a write made before it could overwrite a newer topic or memory in the cloud. As a result,
   **a signed-out install, or one with the dev disable-cache flag on, gets no project topics**
   until it signs in or the flag is turned off. Projects made on the phone get their topic when
   a desktop main instance next sees them.
3. **The topic's name follows the project's** while they're linked: the upkeep renames the
   topic to match. Phase 4's topic rename must rename the project at the same time, or the
   next upkeep run will undo it.
4. **New memories in a project still get `projectId`**, as well as the project's topic, because
   the index and `<gaia_project>` still read `projectId` until Phase 2 (§10). Phase 2 stops
   writing it. **Phase 2 also has to file memories that an older build writes with a
   `projectId` after the topic exists:** those get no topic from this build.
5. **Refusing cycles on re-parent** (§3.1) waits for Phase 4, which adds the first re-parent
   operation. Readers already break cycles.
6. **The duplicate check keeps its project walls** (`save`, `sameActive`) until Phase 5 (§5).
7. **`memory_search` paths** accept `›` or `>` between names; a `/` is part of a name, as in
   "TCP/IP" (changed in Phase 5's review). With only `topic`, it lists
   that topic's memories and its subtopics', newest first, capped at 20.
8. **The project trash kind** still lists memories as children, so a project deleted before
   this build restores the memories that were trashed with it.
9. **A deleted project's memories are global until Phase 2.** They keep its `projectId`, which
   now points to a deleted project, so the index and the duplicate check count them as global,
   with the box checked or not. That's accepted: §7 has no walls, so Phase 2 recalls them in
   any chat anyway.
10. **The upkeep stops at sign-out** and starts again after the next account's startup pull, so
    it never writes while the store is wiped and pulled again. Changes that land while it runs
    ask for one more run, not one each, and its errors are logged as
    `[gaia] project topics not kept`.

### 15.3 How it was checked

- **Unit tests:** `test/gaia_memory_topics_test.dart` (new: the tree and cycles, Firestore
  round trips and older-build writes, the batch write, the migration run twice and on two
  devices, rename, delete and restore, a deleted topic coming back empty, `keepProjectTopics`,
  saving into the project topic, `memory_search` by topic), plus updates to
  `gaia_projects_test`, `gaia_memories_test`, `gaia_migration_test` (200 → 201) and
  `import_export_test`. Full `flutter test`: 7184 passed, 41 skipped and 1 failure,
  `heat_watch_section_test`, which passes on its own and touches none of this.
- **Two-profile sync, 2026-11-16** (qa-128: A = `gaiaqa`, a real schema-200 database with 6
  projects and 38 memories; B = a fresh profile `qtopic`; debug build of the working tree; done
  by VM eval and read-only SQLite, since the screen was off). All passed, and neither run log
  had an error:
  - A migrated to 201. After the pull it made exactly one topic per live project (4, none for
    the 2 deleted) and filed all 7 live project memories, proposed ones included. The deleted
    memory and the global ones were left alone, nothing was pinned, and the outbox drained.
  - B pulled the same topics from the cloud (same `createdAt`), and its own upkeep wrote
    nothing: memory versions were equal on both devices. `dbdiff` found no difference in the
    topic, memory, project or recall tables.
  - Project renamed on B: the topic followed on B and reached A (v2 on both).
  - Project deleted on A with the box unchecked: the topic was kept and unlinked on both, and no
    memory changed. Restored on B: linked again on both (v3).
  - A project created on A got its topic, which reached B.
  - `memory_search` on A's real data: by topic (any case), topic plus query, a project memory
    found from a chat in no project, an unknown topic refused, topic paths in the results.
- **After the review fixes, 2026-11-16** (§15.2 items 9 and 10, and topic names that hold `/`
  or `>`): full `flutter test` on commit `05b1df20`: 7186 passed, 41 skipped and 1 failure,
  `media_image_small_placeholder_test`, which passes on its own, as does
  `heat_watch_section_test`; both fail only under full-suite load and touch none of this.
- **Account-switch pass, 2026-11-16** (qa-128: A = `gaiaqa`, B = a fresh profile `qtopic2`,
  debug build of `05b1df20`, by VM eval and read-only SQLite). All passed, and neither run log
  had a `project topics not kept` line:
  - Baseline: both devices held the same 5 topics, 38 memories and 7 projects, outbox empty.
  - B signed out and into another account (qa-127, which has no Gaia projects), so its store
    was wiped and pulled again: 0 topics, memories and projects, nothing queued.
  - B signed out and back into qa-128, wiped and pulled again (about 41 s). Its topics,
    memories and projects matched the baseline exactly, versions and `createdAt` included, with
    nothing queued, and A's didn't change. This is the case the review's finding was about:
    before the fix, the upkeep stayed subscribed through the wipe and the pull.
  - The upkeep came back after that pull: a project renamed on B had its topic follow (v2), and
    a new project "MT2 A/B tests" got its topic, with a memory saved in it filed there. Both
    reached A.
  - `memory_search` on A: topic `MT2 A/B tests`, and `mt2 a/b tests` with a query, both found
    the memory; `B tests`, the tail of that name, was refused as no topic.

### 15.4 Live checks still to do for Phase 1

These need the screen on, the phone, or a real agent turn:

- **Juno's real instance:** after the first launch on this build, check that `gaia_memory_topics_table`
  has one topic per live project and that the project memories are filed in them.
- **A real agent turn** calling `memory_search` with `topic`, on Claude Code and on Codex: does
  the agent see the new argument and use it? The checks above called the tool directly.
- **The UI paths** of what was done by eval: delete a project from the companion's and the
  page's dialog, with the box both ways, restore it from the Trash page, and rename it from the
  companion and from the page. Then check its topic each time.
- **The phone:** a project created or renamed on the phone gets or renames its topic once the
  desktop runs, and the phone pulls `gaia_memory_topics` without error.
- **Capture into the project topic, live:** `/remember`, `memory_propose` and the curator in a
  project chat each file the memory in the project's topic (unit-tested only).
- **Mixed builds:** a device still on schema 200 edits a memory that's been filed. The memory
  should keep its topics everywhere (unit-tested only).
- **Account switch through the UI:** the pass above signed out by eval and in through the login
  page. Sign out from Settings, sign in to another account, and back, with topics nested under
  others in the cloud (Phase 4 adds re-parenting, so this waits for it): each should keep its
  parent and its memories after the second pull.

## 16. Phase 2 build notes (2026-11-16)

### 16.1 What was built

- **Stage 1 recall (§4.2):** `gaiaRecallCandidates` in `gaia_memories.dart` scores every
  active memory by BM25 over its text, tags and the names on its topics' paths, with the home
  boost for the chat's project topic and its subtopics and a small boost for topics already
  recalled in the session. Each candidate has a strength from 0 to 1. The main instance
  answers a new `memoryRecall {chatId, text, recalled}` pipe request.
- **Picks without stage 2 (§4.3's fallback):** `gaiaRecallPicks` gives stage 1's top 5 with
  strength at or above 0.5 (`kGaiaRecallThreshold`) that the session wasn't given yet, within
  8 memories and 4,000 characters.
- **`<gaia_memories>` (§4.4):** goes ahead of the message, after `<gaia_project>`, with each
  memory in full and its topic path. The session's `agentSessions` entry keeps `recalled`, the
  ids it was given. A compaction clears it, and a new session (a resume that found none, a
  fork, a rewind, another account or agent) starts empty.
- **The recall chip (§4.5):** a `GaiaRecallPart` goes first in the reply, with each memory's
  id, text and topic path at the time. It syncs with the message. `GaiaRecallChip` shows
  "Recalled N memories" on the companion and on the phone's chat page. Opened, it lists each
  memory with its path and says the agent may not have used them. Clicking one opens it on
  the Gaia page's Memories tab, highlighted and scrolled to.
- **The system prompt (§4.1):** `memoryPrompt` gives a new session the pinned memories in full
  under `## Always` and the topic tree with counts under `## Topics`, cut at the depth that
  fits 3,000 characters. It replaces the index of every memory.
- **`<gaia_project>` (§7)** no longer lists the project's memories. It names the project's
  memory topic for `memory_search`.
- **Pinning by hand (§3.3):** a pin button on each remembered memory's row on the Memories
  tab, a pin toggle on the companion's memory card that goes with Remember, and
  `/remember --pin` (with `--global` in either order). Pins are refused past 2,000 characters
  in all (`kGaiaPinBudget`).
- **`projectId` is no longer written** on new memories (§15.2 item 4). A memory that an older
  build saves in a live project, with no topics, is filed in that project's topic by the
  upkeep, which now watches memories as well as projects.

### 16.2 Decisions made while building

1. **Stage 1 picks on its own until Phase 3.** It uses §4.3's fallback rule, so a message gets
   a memory only when at least half the memory's own terms, weighted by rarity, appear in
   the message or the end of the last reply. Short, specific memories match easily; long ones
   need most of their words. Phase 3 tunes the threshold.
2. **Pinned memories are never recalled.** They're in the system prompt already. Archived and
   proposed memories are never recalled either.
3. **Nothing is cached.** Each message reads the active memories and topics and builds the
   scores again. §4.2 says to keep them in memory, but at today's scale a read is cheaper
   than the upkeep code. Add a cache if the §11 latency test shows it matters.
4. **Words for matching:** lower case, letters and digits, a short English stop-word list,
   one-letter words dropped and a plural `s` dropped ("assignments" matches "assignment").
   Since 2026-11-17 (§22.4) an `-ing` or `-ed` is dropped too.
   "C++" is lost, as its only word is one letter. The home boost (×2) and the
   recalled-topic boost (×1.25) don't stack.
5. **The text matched** is what you typed, not the window, selection, quote or file blocks
   Gaia adds, plus the last 1,000 characters of the text of the reply before it.
6. **Filing an older build's memories (§15.2 item 4):** a memory with a live `projectId` and
   no topics gets that project's topic. So anything in this build that takes a memory out of
   its project's topic must also clear its `projectId`, or the upkeep files it back. The
   Memories tab's "Move to" does. **Phase 4's "remove from topic", delete topic and merge
   must do the same.**
7. **The Memories tab until Phase 4:** its project filter and its "Move to" menu now read and
   write project topics, keeping any other topics. Its duplicate checks still use
   `projectId` until Phase 5 (§15.2 item 6), so memories saved from now on count as global
   there.
8. **The curator** still gets one line per active memory to avoid duplicates (`memoryIndex`),
   now from every project. Phase 5 gives it stage 1's candidates instead (§5).
9. **The recall history table** (§3.3) still isn't written. Nothing reads it before Phase 6's
   pin suggestions. Writing it from Phase 2 on would give those suggestions history to start
   from, if you'd rather have it sooner.
10. **When `recalled` is saved:** with the session at the end of the turn, as `project` is. A
    turn whose session isn't kept, such as one that failed straight away, records nothing, so
    the next turn sends those memories again.
11. **A retry as a new session** runs recall again with an empty list and replaces the
    reply's recall part.
12. **No recall ahead of a native command**, which the CLI would read as text, and none for a
    debug-script reply.
13. **The topic list** shows topics with no memories as "(0)", doesn't list Unsorted, and
    leaves out §4.1's "[pinned]" tag, since `## Always` already says it.
14. **A pin over the budget** from `/remember --pin` or the card leaves the memory remembered
    but not pinned, with a toast. `/remember --pin` on text that's already remembered pins
    the existing memory.
15. **Opening a memory from the chip:** on the desktop it brings Voyager's main window
    forward, goes to the Gaia page's Memories tab and clears its filter. On the phone it goes
    back to the Gaia page.

### 16.3 How it was checked

- **Unit tests:** `test/gaia_memory_recall_test.dart` (new). It covers matching through topic
  path names, the home boost ranking a project's memory first, the recalled-topic boost,
  strength staying between 0 and 1 and unchanged by unrelated text, the 40-candidate cap, the
  picks' 5 / 8 / 4,000-character caps, leaving out memories already given and pinned ones,
  the system prompt's pins and topic counts, the topic list cut by depth and by roots, the pin
  budget, the `<gaia_memories>` block's escaping, and the round trips of `GaiaRecallPart` and
  `recalled`. Also updated: `gaia_memory_topics_test` (filing an older build's memory, at
  once and through the upkeep), `gaia_memories_test`, `gaia_project_tools_test` and
  `gaia_commands_test` (`--pin`).
- **Controller tests** (`gaia_controller_test`, "memory recall"): the block on the first
  message and only new memories later, `recalled` kept on the session, the recall part first
  in the synced reply, a follow-up matched with the end of the last reply, a new session after
  a missing resume given the memories again, a compaction clearing the list, and
  `/remember --pin` within and past the budget. The §11 and project tests were updated for
  the new system prompt and project block.
- **Widget tests** (`gaia_memory_card_test`): the recall chip's count, list, paths and clicks,
  and the card's pin going with Remember.
- **Full `flutter test`** on the working tree: 7216 passed, 41 skipped and 2 failures,
  `heat_watch_section_test` and `media_image_small_placeholder_test`. Both pass on their own
  and touch none of this, as in §15.3. The controller and recall tests were run again after
  a last fix to a retry's recall chip: 374 passed.

### 16.4 Live checks still to do for Phase 2

All skipped in this build because they need a running app on the screen. The first four
could also run in `gaiaqa` by VM eval and session files, without the screen, as Phase 1's
passes did.

- **A real Claude Code turn:** the session's jsonl shows `<gaia_memories>` ahead of the
  message on the first turn and only new memories after, and the new system prompt (pins and
  topics, no index) in the CLI's appended prompt.
- **A real Codex turn:** the same, with the system part in `developerInstructions`.
- **Recall quality on real data:** on `gaiaqa`'s memories, and on Juno's own, which messages
  recall what. Note the misses and false hits for Phase 3's threshold tuning.
- **A compaction in a long real session:** the turn after it sends the memories again.
- **The recall chip in the companion:** how it looks above the activity chip, opening it, and
  clicking a memory: Voyager's main window comes forward on the Gaia page's Memories tab,
  with the memory highlighted and scrolled to, even when a project filter was set.
- **The phone:** a reply's recall chip shows after sync, and tapping a memory goes back to the
  Gaia page with it highlighted.
- **Pinning in the UI:** the row's pin button, the card's pin toggle then Remember, and
  `/remember --pin`, each with the toast at the budget. A new chat's system prompt has the
  pin.
- **The Memories tab:** the project filter and "Move to" by topic, and a memory moved to
  Global staying out of the project's topic after the upkeep runs.
- **Mixed builds:** a device on an older build saves a memory in a project chat, and this
  build files it in the project's topic.

## 17. Phase 3 build notes (2026-11-16)

### 17.1 What was built

- **Stage 2 (§4.3):** `GaiaUtility.recall` gives the utility model the message, the chat's
  title (on a later message), and stage 1's candidates as `id · topic path · text`. It
  answers with a JSON array of ids. `parseRecallAnswer` keeps the ids it knows, in the
  answer's order, within §4.4's caps (8 memories, 4,000 characters). An answer of `[]` means
  none, with no fallback. A failure, an answer with no array, or the 5-second timeout means
  stage 1's picks are used instead.
- **When it runs (§4.3):** on a chat's first message, if stage 1 found any candidate at all.
  On a later message, only when stage 1 has a **new strong candidate**: one the session
  wasn't given yet, with strength at or above `kGaiaRecallThreshold` (0.5). The
  `memoryRecall` pipe request now returns stage 1's `{picks, candidates, strong}` (the
  `GaiaRecall` record), so the companion can decide without a second request.
- **Beside the router:** on a new chat's first message where the router runs, recall starts
  before the router call and the two run in parallel. Where the router doesn't run (tier
  picked, a remote message naming a tier), recall runs alone before the message goes out.
- **A second process started ahead:** `ClaudeUtilityRunner` keeps up to two processes waiting
  (`warm(count)`), so the router and recall don't wait on each other. `GaiaUtility.warm`
  asks for one process for the router and one more for recall when stage 2 is on.
- **The usage log for §11:** each recall pass logs
  `[gaia] utility usage, memory recall: in N, cache read N, cache write N, out N, T ms
  (started ahead | cold start), five-hour window X%`. The tokens are summed from the
  result's `modelUsage`. The five-hour figure comes from the utility process's
  `rate_limit_event` if the CLI sends one, and otherwise reads "not reported".
- **The switch:** Gaia's debug menu → "Haiku picks recalled memories" (`GaiaDebug.recallPick`,
  saved in the debug JSON, local to the desktop). It's **off by default**, as §11 asks, so
  today's behaviour is unchanged until it's turned on.

### 17.2 Decisions made while building

1. **A debug switch, not a setting.** Gaia's settings sync and live in a drift table, so a
   new setting would need a schema change. §11 decides whether stage 2 stays at all, so for
   now it's a local debug toggle. Once §11 settles it, either make it the default by
   removing the switch, or move it into settings if it should stay optional.
2. **"A chat's first message"** means a message with no reply before it in the chat. A
   retry of the first message counts as first. A later message's new session (handoff,
   fork, resume that found none) doesn't: it runs stage 2 only with a new strong
   candidate, the same as any later message.
3. **Haiku can pick weak candidates.** That's the point of stage 2. A vague first message
   ("walking the dog later") gets "Has a dog called Biscuit", which stage 1 alone leaves out.
4. **The candidates sent** are stage 1's top 40 minus those the session was already given,
   each text cut at 1,000 characters, with the message cut at 4,000. Pinned, archived and
   proposed memories are never candidates, the same as in stage 1.
5. **The title** goes only with later messages. On the first message the title is still
   the message's first line, so sending it would only repeat the message.
6. **The pass started beside the router is used for the chat's first session only.** A retry
   as a new session runs recall again. Because that pass starts before the chat is saved on
   the main instance, `memoryRecall` takes the chat's `projectId`, so the home boost works
   for a new project chat.
7. **Later messages start their process cold.** Nothing is warmed for an existing chat, so a
   later message's stage 2 waits for a cold start (2.6-4.2 s for the router, §7.2 of
   GAIA_HLD.md) inside the 5-second timeout. §11's latency test decides whether that's too
   slow. If it is, the fix is to warm a process when the composer of an existing chat gets
   focus while stage 2 is on.
8. **The threshold stays at 0.5.** Tuning needs real chats (§17.4).
9. **No combined router-and-recall call** (§4.3). That waits on §11's latency numbers.
10. **Dummy mode and debug scripts never run stage 2**, the same as the router.

### 17.3 How it was checked

- **Unit tests:** `test/gaia_utility_test.dart` covers the answer parser (order, unknown and
  repeated ids, the 8 and 4,000-character caps, no array), the input sent (message, title,
  candidate lines with Unsorted), the usage label, a bad answer giving null, warming two
  processes for recall, and summing tokens over models. `test/gaia_memory_recall_test.dart`
  covers weak candidates passed on with `strong` false, a strong one setting it, given and
  pinned memories left out of the candidates, and a chat not yet saved getting the home
  boost from the `projectId` it's given.
- **Controller tests** (`gaia_controller_test`, "stage 2, the utility model picks"): a
  first message runs recall beside the router and picks a weak candidate, drops unknown ids
  and logs the pass. A later message runs it only with a new strong candidate, and `[]`
  sends no block. A bad answer falls back to stage 1. A first message whose tier was picked
  runs recall without the router. With the switch off, stage 1 runs alone.
- **The Gaia suites** (utility, recall, controller, topics, memories, host, debug): 560
  passed.
- **Full `flutter test`, run twice on the working tree.** The first run had 7,229 passed, 41
  skipped and 3 failures, but which tests failed wasn't recorded. The second run had one
  failure, `media_image_small_placeholder_test`, which passes on its own, as does
  `heat_watch_section_test`. As in §15.3 and §16.3, both touch none of this.

### 17.4 Live checks still to do for Phase 3

All skipped in this build because they need a running app on the screen or spend the real
account's plan. Turn the switch on first (debug menu → "Haiku picks recalled memories").

- **The §11 test, in full.** It decides the threshold and whether stage 2 stays on later
  messages:
  - Tokens per pass, from the `utility usage, memory recall` log lines.
  - The 5-hour percentage per 100 passes, three bursts on different days. There's no burst
    script yet: in `gaiaqa`, seed about 300 memories across a dozen topics (a
    `qa/steps/*.dart.txt` VM eval), then call `GaiaUtility.recall` 100 times by eval with
    realistic messages, reading `GaiaUsage.fiveHour` before and after.
  - The same for 20 Standard-tier turns, for comparison.
  - Latency: with a process started ahead and cold, recall alone and beside the router. Look
    at the `ms (started ahead | cold start)` field.
  - How often stage 2 runs across a week of Juno's own chats. Count the `memory recall:
    asking the utility model` lines, which say whether it was the first message or a new
    strong candidate.

  Write the numbers into §11.
- **Threshold tuning** on `gaiaqa`'s seeded memories and on Juno's own: note which messages
  trigger stage 2 and which memories each picks, misses and false hits included.
- **Haiku's real answers:** does it reply with a bare array, and does `[]` come back for
  unrelated messages? Do CS246 chats get no Obsidian memories (§13 live)?
- **A vague first message followed by a specific one** runs stage 2 on the second (§13
  live).
- **Two processes started ahead:** on a new chat with the switch on, two `claude.exe`
  utility processes wait (`Win32_Process`), the router and recall each log `process
  started ahead`, and both processes are dropped after 5 idle minutes.
- **Does the utility CLI send `rate_limit_event`?** If the log always reads "not
  reported", take the five-hour figure from `claude_oauth_usage` as §11 says.
- **Codex chats:** stage 2 runs on Gaia's Claude account. With no Claude account set up, it
  fails and stage 1 is used (§9). Check how long that failure takes.
- **The debug switch** shows in the menu, saves, and is still set after a restart.
- **Phase 2's live checks (§16.4)** are all still to do as well.

## 18. Live pass, 2026-11-16 (Phases 1-3)

`gaiaqa` (qa-128) on an out-of-tree debug build of the working tree, driven by VM eval and
`voy.ps1` (background input and frame grabs), with read-only SQLite. Seeded with 274
memories across 14 new topics (`qa/steps/mt3-seed-*.dart.txt`): a project "CS246" with
subtopics Assignments and Final exam, Obsidian with a Plugins subtopic, and ten more. With
the profile's own, 290 active memories in 20 topics. Real turns ran on Juno's default Claude
account (Haiku for most, Sonnet for §11). New bugs: BUG-378 to BUG-380.

### 18.1 Phase 1 (§15.4)

- **Juno's real instance:** passed. Read from a copy of its database: schema 201, one
  topic for the one live project (CS245), linked, and no live-project memory outside its
  topic. The three deleted projects have no topic: they were deleted before this build.
- **A real agent turn with `memory_search` `topic`:** passed on Claude Code. Asked for the
  "Final exam" memories, the agent called `memory_search {"topic": "Final exam"}` and got 13.
  **Not run on Codex:** `gaiaqa`'s Codex agent is set to `gpt-6.1-sol`, which Codex refuses
  on a ChatGPT account, so the turn failed before the model ran. Its system part and
  `<gaia_memories>` were checked anyway (§18.2).
- **The UI paths:** passed. From the Gaia page: rename (topic followed, v2 and v3), delete of
  a project with no chats (the dialog has no box then; topic kept and unlinked, memory still
  in it), delete with "Also delete its chat" checked (chat trashed, topic kept and
  unlinked). From the companion: delete with the box unchecked (chat kept with no project,
  topic kept and unlinked) and rename (topic followed). Restore from Settings → Trash, twice:
  topic linked again each time, and the trashed chat came back.
- **Capture into the project topic:** passed for `/remember` (filed in "CS246") and
  `memory_propose` (proposed, filed in "CS246"). The curator ran on 20 chats and found
  nothing to propose, so its filing wasn't seen.
- **Mixed builds:** passed, simulated: a write to Firestore without `topicIds`, `pinned` and
  `suggestedTopic`, as an older build's outbox makes it, with the server stamp. Editing a
  filed memory kept its topic on this device and in the cloud (v2).
- **Not run:** the phone (no emulator or `adb` on this PC), and the account switch through
  Settings, which waits for Phase 4's nested topics.

### 18.2 Phase 2 (§16.4)

- **A real Claude Code turn:** passed. The session file's first turn has `<gaia_project>`
  (naming the topic, no memory list), then `<gaia_memories>` with each memory's topic path,
  then the message. The second turn sent only new memories. A new chat's prompt, read from
  `sessionPrompt()` (the CLI's prompt file is deleted once read), has `## Always` with the
  pins and `## Topics` with counts and subtopics, and no index. A new chat asked "what is my
  favourite colour" answered "Teal." from a pin, with no recall part.
- **A real Codex turn:** passed up to the model call (see §18.1). The rollout has `## Always`
  and `## Topics` in the developer message and `<gaia_memories>` before the user message.
- **A compaction:** passed. `/compact` emptied the session's recalled list (9 to 0), and the
  next message got the valgrind memory again.
- **The recall chip:** passed. "Recalled 2 memories" above the reply; opened, it lists each
  memory under its path and says the agent may not have used them. Clicking one brought
  Voyager's main window forward on the Memories tab, with its filter (Global) cleared and
  the memory highlighted and scrolled to.
- **Pinning:** passed. The row's pin button, `/remember --pin` and the card's pin then
  Remember all pin. At the budget each refuses with its toast ("Remembered, not pinned" for
  the command and the card). Exactly 2,000 characters is allowed. A memory is capped at 500
  characters, so `/remember` of longer text is refused before the pin is looked at. BUG-380:
  the row's toast stays up with a spinner.
- **The Memories tab:** passed. The project filter lists the project topic's memories;
  "Move to" → Global took a memory out of the topic and cleared its `projectId`, and it
  stayed out after the upkeep ran (a project rename set it off). Two things to note for
  Phase 4: memories in a project's subtopics aren't in the project's filter, and they're
  labelled "Global" on the tab.
- **Mixed builds:** passed, simulated as in §18.1: a memory saved with a live `projectId` and
  no topics was filed in the project's topic by the upkeep and written back (v2).
- **Recall quality:** §18.3. **Not run:** the phone's recall chip and reveal. Juno's own data
  has 10 active memories, too few to tune on.
- **BUG-378:** after the eval-driven Codex chat, the companion's chat pane and title stayed on
  that chat while the sidebar and controller moved to others.

### 18.3 Phase 3 (§17.4)

- **The §11 test:** the first burst and the 20 Standard turns are in §11. The 5-hour
  reading was spoiled by other use of the account; two more bursts are still to do.
- **Haiku's answers:** all 91 were bare JSON arrays (a few with spaces or across a line), 10
  were `[]`, none failed. One gave 10 ids for "give me a 20 minute bodyweight workout"; the
  parser kept 8.
- **CS246 against Obsidian:** passed. No CS246 message got an Obsidian memory, except
  "How do I take notes on this lecture in Obsidian?", which should.
- **A vague first message, then a specific one:** passed. "hey, quick question about my
  course this term" ran stage 2 as a first message (5 picked of 18). "valgrind says I leak
  memory in my destructor" then ran it as "a new strong candidate" (4 of 35, the valgrind
  memory first).
- **Two processes started ahead:** passed. A new chat had two Gaia utility processes
  waiting, and the router and recall each logged "process started ahead". The 5-minute
  drop was checked on a second runner (two spares gone by 5 minutes, a forced drop ends the
  process in seconds). Gaia's own runner had four processes from timed-out jobs still running
  8-15 minutes later: BUG-379.
- **`rate_limit_event`:** sent; every pass logged a five-hour figure.
- **Codex chats with no Claude account:** stage 2 fails with "Not logged in" in 467 ms cold
  and 72 ms on a process started ahead, and stage 1 is used. With the account, recall ran in
  a Codex chat (picked exactly the two A5 memories asked about).
- **The debug switch:** passed. It's in the debug menu and off by default, saves to
  `debug.json`, and was still on after a restart. Turned off again at the end.
- **Threshold tuning, stage 1:** at 0.5 it picks almost nothing. Of 24 hand-picked messages
  only one got a pick (valgrind, 0.52), though the top candidate was the right memory for
  about 17 of them. Right top hits had strength 0.20-0.42; wrong ones 0.13-0.26 ("Write me a
  haiku about autumn" → "The user writes in Canadian English", 0.26). No threshold separates
  them, so lowering it trades misses for false hits. Words that don't match also cost:
  "help" pulled "Dad wants help setting up his new iPhone" into three unrelated messages.
  Stage 1 on its own (the switch off) gives today's users almost no recall on real memories.
- **Threshold tuning, stage 2:** good on 99 messages. Misses: "when is Biscuit due for
  shots" (the vaccine memory wasn't a candidate: "shots" against "vaccine booster"), "I've
  been sleeping badly" (`[]`, though a sleep memory was a candidate). False hits: "help me
  prepare for a co-op interview" → co-op savings; "I'm bored" → a GIC idea and Obsidian tags;
  "write a cover letter" → the sync outbox and a test harness; "make a grocery list" → the
  lifting split. "What should I study tonight" with no project filled the 8-memory cap with
  CS246 final topics.
- **Not run:** how often stage 2 runs across a week of Juno's chats, and the other two
  bursts.

**What it suggests (not decided):** stage 2 does the real work, so leaving it off leaves
recall close to unused. Its cost per pass is about 1.2k tokens, mostly cache writes, and it
answers in under a second most of the time. The threshold only decides when a later message
runs stage 2, and at 0.5 few do, which keeps the cost to about one pass a chat. Settle both
once the clean bursts are in.

### 18.4 Decisions after the live pass (2026-11-16)

1. **Stage 1 is a candidate list, not a selector.** It ranks well (the right memory on top for
   about 17 of 24 messages), but no strength threshold separates right picks from wrong ones
   (§18.3), so it isn't tuned to pick memories on its own. The threshold's one job is the
   trigger for stage 2 on a later message (§4.3): a candidate not yet recalled in this session
   whose strength clears it. Tuning it means trading how often stage 2 runs against missing a
   change of subject, read from §11's "how often it runs".
2. **When stage 2 can't run, recall is close to nothing, and that's accepted.** That's when
   the debug switch is off, the utility model is off, there's no Claude account (a
   Codex-only setup), or the pass times out (4 of 91 in the first burst). The code is
   unchanged: stage 1's top 5 above the threshold go, which is rarely any. The agent relies on
   `memory_search`. The system prompt says memories are added to messages and that
   `memory_search` finds the rest, and the tool's description (`gaia_mcp.dart`) now says the
   instructions list only pins and topics. Until Phase 2 it said they listed every memory, which
   would have told the agent there was nothing more to find. A capped index in the system prompt
   as a fallback was considered and left out: it brings back the per-session cost this design
   removes.
3. **Recall quality waits for the whole design.** Stage 2 stays behind the debug switch until
   §11's clean bursts are in. Weak recall in the meantime is expected, not a bug. *Changed
   2026-11-17: stage 2 is on by default (§25.1).*
4. **Carried into later phases** (§10):
   - Phase 4: a project's filter on the Memories tab includes its subtopics' memories, and
     those memories are labelled with their topic, not "Global" (§18.2).
   - Phase 5: stage 2's misses where the memory never reached stage 1's candidates because the
     words differ ("shots" against "vaccine booster", §18.3). Placement's tags and topic paths
     are what stage 1 matches on, so check these again once Phase 5 is in. If they still
     miss, the fallback is LLM query expansion (as in MIRIX's Active Retrieval): the utility
     model returns a few extra search terms for the message, and stage 1 runs again with them.

## 19. Live checks for Phase 4's pass

Checks that earlier phases left for Phase 4, all in one place. Run them in Phase 4's live pass
along with its own checks. Wrap any eval that changes state in `Future(() => ...)` (BUG-378).

1. **Account switch through Settings, with nested topics** (from §15.4). Nest topics under
   others in the cloud. Sign out from Settings, sign in to another account, then sign back in.
   Each topic should keep its parent and its memories after the second pull.
2. **Re-parenting, on one device and across two** (§3.1, §15.2 item 5).
   - Dragging a topic onto one of its own descendants is refused in the tree.
   - On two devices, re-parent two topics under each other at the same time. After sync, the
     cycle is broken at the topic with the oldest `updatedAt`, which shows as a root on both
     devices. Nothing is lost or duplicated.
3. **A project's subtopics on the Memories tab** (§18.2, §18.4). With memories in a project's
   subtopics (e.g. CS246 › Final exam), the project's filter lists them, and each is labelled
   with its topic path, not "Global".
4. **The agent searches its memories when asked** (§18.4 item 2). With stage 2 off, in a real
   Claude Code chat and, once `gaiaqa`'s Codex model works, a Codex chat, ask for something that
   needs a memory that's in neither the pins nor `<gaia_memories>`. Check both of these:
   - Whether the agent calls `memory_search` unprompted.
   - That after "check your memories" it does, and answers from the result.

   The tool's description was rewritten for this and hasn't been checked live.
5. **Renaming a project's topic renames the project** (§15.2 item 3). Rename a linked project
   topic from the tree. The project gets the new name, and the name holds after the upkeep
   runs (rename another project to set it off).
6. **Taking a memory out of its project's topic clears `projectId`** (§16.2 item 6). Take
   memories out of a project's topic each way Phase 4 allows: "remove from topic", deleting the
   topic, and merging it into another (if merge comes in Phase 6, check it then). Each memory
   leaves the topic with its `projectId` cleared. After the upkeep runs, none is filed back.

## 20. Phase 4 build notes (2026-11-16)

### 20.1 What was built

- **Topic edits (§3.2)** in `GaiaMemories` (`gaia_memories.dart`): `newTopic`, `renameTopic`,
  `moveTopic` (re-parent), `deleteTopic`, and for memories `moveMemory`, `addMemoryTopic` and
  `removeMemoryTopic`. `GaiaMemoryTopic.copyWith` takes `parentId`, and the repository has
  `watchMemoryTopics` behind a new `gaiaMemoryTopicsProvider`.
- **Re-parenting refuses cycles** (§3.1, §15.2 item 5): `moveTopic` throws for a move under
  the topic itself or any of its subtopics, and the tree refuses the drop before that.
- **Renaming a linked project's topic renames the project** in the same write
  (`upsertProjectWithChats` with the topic), so the upkeep keeps the new name (§15.2 item 3).
- **Deleting a topic** is one write: its memories lose it, its subtopics move up to its
  parent (or become roots), and it goes to the trash. Restoring it from the trash brings back
  the topic alone, under its old parent if that's still there.
- **Taking a memory out of its project's topic clears `projectId`** on every path that does it
  (remove, move, delete topic), so the upkeep doesn't file it back (§16.2 item 6).
- **The Memories tab** is two panes on a window 640 px or wider: the tree (All memories, every
  topic indented under its parent, Unsorted) with a **New topic** button, and the selected
  topic's memories, each scrolling on its own (§20.4). "Include subtopics" is on by default. The inbox comes first and is shown
  across every topic. A search box above filters both panes. Each memory row shows its topics
  as chips with their paths, each with × to take it out.
- **On the desktop:** drag a memory onto a topic to move it, Ctrl+drag to add it. Drag a topic
  onto another to put it under it, or onto All memories for the root. A refused drop outlines
  the target in red. Right-click a topic for Rename (or F2 on the selected one), New subtopic
  and Delete.
- **On the phone, or a narrow window:** the selected topic is a button that opens the tree in
  a dialog. Each topic has a ⋯ menu with Rename, New subtopic, Move under… and Delete. On the
  phone, each memory's ⋯ menu has Move to topic… and Add to topic….
- **A project's subtopics (§18.4):** selecting a project's topic lists its subtopics'
  memories too, and every memory is labelled by its topic paths. The old project dropdown,
  its "Global" entry and the "Move to" project chip are gone: project topics are in the tree
  like any other.

### 20.2 Decisions made while building

1. **A live project's topic can't be deleted.** The upkeep would make it again at once, empty
   (§7). Its Delete menu item is disabled and reads "Delete (goes with its project)", and
   `deleteTopic` refuses it too. Deleting the project unlinks the topic, and then it can be
   deleted.
2. **What a move replaces:** from a selected topic, the memory's topics in that topic's
   subtree, whether or not "Include subtopics" is on. From All memories or Unsorted, every
   topic it has.
3. **The root area is the All memories row.** Topics dropped there go to the root. Memories
   can't be dropped on All memories or Unsorted; a chip's × takes a memory out of a topic.
4. **The "Global" view is gone.** Unsorted is the nearest thing, but it isn't the same:
   Global meant "in no project's topic", and Unsorted means "in no topic".
5. **Search** matches a memory's text and tags, and the names of its topics. The tree keeps the topics it
   names and those holding a memory it finds, with the topics above them. The inbox is
   filtered too.
6. **Duplicate checks are unchanged.** They still use `projectId` until Phase 5 (§15.2 item
   6), and moving between topics doesn't check for duplicates.
7. **Desktop menus have no Move under… or Move to topic….** Dragging does those, as §3.2
   lays out. The phone has the menus. A narrow desktop window gets the tree dialog, and
   Move to topic… and Add to topic…, since a memory has no tree there to be dragged onto.
8. **Names:** a blank name is refused. Repeated names are allowed, siblings included.
9. **A new topic or subtopic is selected** once it's made.
10. **The tree shows no counts.** The system prompt's topic list has them (§4.1).
11. **Deleting a topic asks first**, rather than an undo toast, because an undo that brings
    back the topic alone (as the trash does) would read as a full undo.
12. **Ctrl is read when the memory is dropped.** Nothing on screen shows whether a drop will
    move or add.
13. **Merge stays in Phase 6** (§10), so topics have no "Merge into…" item yet.

### 20.3 How it was checked

- **Unit tests** (`test/gaia_memory_topics_test.dart`, "editing the tree"): new topics at the
  root and under a parent; re-parenting a subtree, and refusing a move under itself or a
  subtopic; deleting a topic, at the root and below; a live project's topic refused and then
  allowed once the project is deleted; a project topic's rename renaming the project and
  holding after the upkeep; move within a subtree against everywhere, add and remove; and a
  memory taken out of its project's topic each way losing `projectId` and not being filed back
  after a restore of the project. 32 passed in the file.
- **Widget tests** (`test/gaia_memory_tree_test.dart`, new; the desktop ones in the Windows
  variant, under a 1.5 GB memory watchdog): a topic lists its subtopics' memories with path
  labels and no "Global", and only its own without subtopics; Unsorted; dragging a memory
  moves it within the selected subtree and Ctrl+drag adds it; a topic dragged onto its own
  subtopic stays put, onto another goes under it, and onto All memories goes to the root; a
  chip's × takes a memory out; search filters both panes; right-click New subtopic, F2
  rename, and Delete with its message about subtopics; and on the phone, Move to topic… and
  Move under… (which leaves out the topic itself). 6 passed.
- **Full `flutter test`** (3 GB watchdog): 7,243 passed, 42 skipped and 2 failures,
  `heat_watch_section_test` and `media_image_small_placeholder_test`. Both pass on their own,
  as in §15.3 to §17.3.

### 20.4 Live pass, 2026-11-16 (off-screen)

`gaiaqa` on a copy of the Debug build with this tree's Dart bundle (Juno's own debug run held
the build folder), parked off-screen and driven by `voy.ps1` in background mode, VM eval
(`qa/steps/mt4-*.dart.txt`) and read-only SQLite. No new bugs.

- **The tab on real data** (300 active memories, 20 topics): the two panes, the tree with
  CS246 › Assignments, Final exam and Obsidian › Plugins, New topic, All memories and
  Unsorted. Passed.
- **§19.3, a project's subtopics:** passed. CS246 lists 70 memories, its own 30 and its
  subtopics' 40 (the count matches SQLite), each labelled "CS246 › Assignments" or "CS246 ›
  Final exam". Nothing reads "Global".
- **§19.5, renaming a project's topic:** passed, through F2 on the selected row. Topic and
  project both became "CS246 Winter" (v2), and the name held through the upkeep runs that
  the later memory edits set off. Renamed back to "CS246" by eval afterwards.
- **§19.6, taking memories out of a project's topic:** passed for two of the three ways. A
  chip's × took "P4 dinner is at 19:30." out, with `projectId` cleared. Deleting the topic
  "P4 Del Trash" (after its project was deleted by eval) left "TRASHMEM beta fact." Unsorted,
  with `projectId` cleared. Restoring that project by eval gave it a new, empty topic (v8),
  and neither memory was filed back. The third way, a drag, is in §20.5.
- **A linked project's topic:** its menu shows Rename (F2), New subtopic, and Delete greyed
  out as "Delete (goes with its project)". The unlinked one asked "Delete "P4 Del Trash"?"
  first.
- **Found and fixed during the pass:** the tree and the memories first shared the page's one
  scroll. With the inbox's 21 rows on top, a memory further down and most tree rows were
  never on screen together, so a memory couldn't be dragged onto them. In the wide layout
  each pane now scrolls on its own, and the two are a window high.
- **Drags didn't work in background mode.** `voy.ps1`'s burst drag and an in-process
  pointer sequence over the VM service both failed to drop a memory, and one left a topic
  drag hanging until a restart (no write happened). Synthetic input can't settle this, so
  drags wait for real input (§20.5). The widget tests cover them meanwhile.

### 20.5 Live checks still to do for Phase 4

Skipped because they need real input on the screen (`voy.ps1` foreground mode), the phone, a
second account or a real agent turn. Run them with §19's list.

- **Drags with a real mouse:** a memory onto a topic (moved within the selected topic's
  subtree), Ctrl+drag (added), a topic onto another and onto All memories, the red outline on
  a refused drop, and §19.2's drag onto a topic's own subtopic. Also a drag of a project
  memory out of its project's topic (§19.6's third way): `projectId` cleared and not filed
  back after the upkeep. And whether a drag from the bottom of a long list onto a topic is
  comfortable with the panes scrolling apart.
- **§19.1, account switch through Settings** with nested topics (CS246's subtopics are nested
  in `gaiaqa`'s cloud copy now).
- **§19.2's second half, two devices:** re-parent two topics under each other on both at
  once; after sync the cycle is broken at the oldest `updatedAt` on both, nothing lost.
- **§19.4, the agent searching its memories:** real Claude Code and Codex turns with stage 2
  off.
- **The phone:** the tree button and dialog, each topic's ⋯ menu (Rename, New subtopic, Move
  under…, Delete) and each memory's Move to topic… and Add to topic….
- **A narrow desktop window** (under 640 px): the tree button opens the dialog, and picking a
  topic closes it.
- **Search on real data:** a word in a memory, and a topic's name, filter both panes.
- **Restore from Settings → Trash** of a deleted topic: it comes back under its old parent,
  with no memories.

## 21. Phase 5 build notes (2026-11-16)

### 21.1 What was built

- **Placement (§5):** a new utility job, `GaiaUtility.place`, gets the memory's text and every
  topic as `id · path`, and answers with the existing topics it goes in (at most 3), a new
  topic if none fits well (`{name, parent}`), and up to 3 tags. `GaiaMemories.place` files the
  memory in those topics that are still there, beside the ones it has, merges the tags and
  keeps the new topic as `suggestedTopic`.
- **When it runs:** after `/remember` saves a new memory, after `memory_propose` saves one
  with no `topics` named, and from the Gaia page's **Suggest topics** button. Until it
  returns, the memory is in Unsorted, or in its project's topic.
- **`memory_propose` takes `topics`** (names or paths, from the system prompt's list). Each
  one found is filed in. The first one not found is offered as a new topic, under the topic
  its path names if that's there. `scope: "global"` now only means "not in the project's
  topic", and the tool's description says so.
- **The curator** gets the topic list and returns `topics` and `new` in each item, so what it
  finds is filed as it's saved. In place of the whole index it's shown stage 1's top 40
  memories for the transcript (pinned ones included), so its input doesn't grow with the
  number of memories. The `memoryIndex` pipe request and `gaiaMemoryIndex` are gone.
- **Suggested topics in the inbox and on the tab:** a memory with a topic offered shows a
  "+ New topic: Assignments under CS246" chip on its row. Clicking it makes the topic and
  files the memory there, in one write; its × drops the offer.
- **The companion's memory card** shows the memory's topics as chips, each with ×, the new
  topic offered (click to take it, × to drop it), and a "+ Topic" menu of the other topics.
  Edits go with Remember.
- **Duplicate checks without project walls (§5, §15.2 item 6, §20.2 item 6):** `save`,
  `sameActive` and the Memories tab's checks see every memory. A memory says the same as
  another if their text matches, whichever projects or topics they're in.

### 21.2 Decisions made while building

1. **Placement runs in the companion,** since only it has the utility model. `/remember` and
   `memory_propose` start it after the save and don't wait for it. The page's Suggest asks the
   companion over the pipe, starting it if it isn't running, so the button is desktop only.
2. **Placement also gives tags,** aimed at §18.4's word-mismatch misses: words someone might
   use when the memory matters that aren't in its text ("shots" for a vaccine booster). They're
   merged into the memory's tags, which stage 1 matches on.
3. **Placement only adds.** It never takes a memory out of a topic, so the project's topic and
   anything you filed stay.
4. **A name that fits several topics** (`memory_propose`'s "Assignments") picks one in the
   chat's project first, otherwise the first by path. With `topics` named, nothing is left to
   the utility model, even when none of them was found.
5. **An offered topic that's already there is used.** If its parent already has a topic of
   that name (case aside), the memory is filed there and nothing is offered. This is checked
   on save, on placement and on accept, so accepting the same offer on two memories makes one
   topic. Two devices accepting at the same moment can still make two. That's accepted; the
   duplicate can be deleted.
6. **An offer stays until you decide it.** A memory remembered from its card with the offer
   left alone keeps it, and the chip on the Memories tab still shows it.
7. **The card sends topics only if you changed them.** Otherwise the memory keeps what it has,
   so an edit made on the page meanwhile isn't overwritten. The card asks for its topics when
   it first shows, and isn't updated by later page edits. Removing the project's topic on the
   card clears `projectId`, as the tab does (§16.2 item 6).
8. **Suggest topics** shows only on an Unsorted memory with no offer waiting. A memory that
   already has topics can be moved by hand, and Phase 6's Sort these covers the rest.
9. **The topic list sent to the utility model isn't capped.** It grows with topics, not
   memories. If it ever gets long, cut it as §4.1 does.
10. **One case still skips the duplicate check:** a deleted memory whose project is gone. Those
    were trashed with their project before projects kept their memories, so they weren't set
    aside by you.

### 21.3 How it was checked

- **Unit tests:** `gaia_utility_test` (the placement answer's parser, the job's input, a bad
  answer as null, the curator given topics and filing its finds); `gaia_memory_topics_test`,
  "placement on capture" (the topic list in tree order, `memory_propose` with topics named,
  a name fitting several, an offer that names an existing topic, placement adding topics and
  tags, the card's filing, accepting and dropping an offer, a second memory accepting the
  same name, a card remembered with edited topics clearing `projectId`, the curator's 40
  nearest with pins and its filing); `gaia_memories_test` updated for the curator's list and
  duplicates with no walls; `gaia_host_test` for `remember`'s `memoryId`.
- **Controller tests** ("placement on capture"): `/remember` filed with tags and an offer, a
  repeat not placed again, the page's Suggest through `placeMemory`; `memory_propose` with no
  topics placed and its card showing where, with topics named not placed, and the card's edits
  and taken offer going with Remember; the curator shown the nearest memories and the topics,
  and its find filed where it said.
- **Widget tests:** the card's chips, taking and dropping the offer, and "+ Topic" offering only
  topics it isn't in (`gaia_memory_card_test`); a row's offer chip making the topic, its ×
  dropping it, and Suggest only on an Unsorted row (`gaia_memory_tree_test`, Windows variant,
  under a memory watchdog).
- **Full `flutter test`** (3 GB watchdog): 7,258 passed, 42 skipped and 3 failures. Two are
  `heat_watch_section_test` and `media_image_small_placeholder_test`, which pass on their own,
  as in §15.3 to §20.3. The third, `photo_series_page_test` "compare: a quick pick never lands
  on B", fails on its own too. It imports nothing this phase touched, so it's a separate
  problem and isn't fixed here. The Gaia controller tests were run again after a last change:
  all passed.
- **Live, off-screen, 2026-11-16:** a throwaway test (not kept) ran the real utility model
  (Haiku, on Juno's default Claude account) over an in-memory store with 12 topics. Results:
  - **Placement:** all 8 answers were valid JSON. Each memory went into the right topic (the
    vaccine into Pets, the A5 into CS246 › Assignments, the vault into Obsidian), with no new
    topic offered, since one always fit. Each took 1.7 to 2.8 s, from a cold start.
  - **Tags:** "vet, shots, rabies" for the vaccine booster.
  - **§18.4's word-mismatch misses, again:** "when is Biscuit due for shots" now has the
    vaccine memory as its top candidate. It needed the "shots" tag: the memory's own text
    says "vaccine booster". "I've been sleeping badly" still finds nothing in stage 1, even
    with a "sleep" tag. Stage 1 drops only a plural `s`, so "sleeping" doesn't match "sleep"
    (§16.2 item 4). A light stemmer for -ing and -ed would close that gap, and it isn't done
    here. Neither message's top candidate counts as strong.
  - **The curator:** for a chat about a sister moving to Lisbon who is vegetarian, it was shown
    the one memory nearest the turns (the peanut allergy) and filed both of its finds: Family
    and Food. It took 3.8 s.

### 21.4 Live checks still to do for Phase 5

Skipped because they need the app on the screen, a real agent turn, the phone, or a second
device. Run them with §20.5's list, in `gaiaqa` with real Haiku.

- **`/remember` live:** the toast, then within a few seconds the memory is filed (Memories tab,
  and a `[gaia] memory placement:` log line), with its tags and any offer chip.
- **A real `memory_propose` turn, on Claude Code and Codex:** does the agent pass `topics` from
  the system prompt's list? With none, the card's chips fill in once placement returns (the
  card was open before it did). Take, drop and leave the offer, edit the chips, use "+ Topic",
  then Remember, and check the memory on the tab each time.
- **The card's look:** the chips under the editor, the "+ Topic" menu's position, a long path
  cut off, the card in a narrow companion.
- **The curator live:** on real chats in `gaiaqa` (300 memories), what it files where, and how
  often it offers new topics. Check its input size in the log against the old index.
- **The Memories tab:** the offer chip on inbox and remembered rows, clicking it and its ×;
  Suggest on an Unsorted memory with the companion running, and with it not running (it should
  start hidden, not show a window).
- **The phone:** the offer chip shows and can be accepted or dropped; no Suggest button.
- **Two devices:** an offer accepted on one device reaches the other with its topic. Accepting
  the same offer on both at once makes two topics (§21.2 item 5): confirm, and that deleting
  one is clean.
- **Duplicates without walls:** in a project chat, `/remember` text already saved in another
  project says "Already remembered".
- **§18.4's word-mismatch misses in `gaiaqa`:** place the 290 seeded memories (Phase 6's Sort
  these, or a burst by eval), then run §18.3's misses with stage 2 on: "when is Biscuit due for
  shots" and "I've been sleeping badly". The vaccine one now
  reaches stage 1 in the off-screen probe (§21.3). Also decide whether to stem -ing and -ed.

## 22. Live pass, 2026-11-17 (Phases 4 and 5)

`gaiaqa` (qa-128) on a copy of the Debug build with this tree's Dart bundle, on screen for the
companion and parked or on screen for the main window. Driven by `voy.ps1` (background, and
foreground for drags, resizes and the menu retry), VM eval (`qa/steps/mt5-*.dart.txt`) and
read-only SQLite. A fresh profile `qtopic5` on the same account was the second device and did
the account switch. Real turns used Juno's default Claude account (Haiku) and, for Codex, the
`sol` agent pointed at `gpt-6-luna` for the pass (`gpt-6.1-sol` is refused on a ChatGPT
account, §18.1), then set back. One new bug, BUG-381, fixed during the pass. The phone wasn't
run: there's no emulator or `adb` on this PC.

### 22.1 Phase 4 (§19, §20.5)

- **Drags with a real mouse:** passed. With Hobbies selected, a memory dragged onto Music left
  Hobbies for Music. Ctrl+drag onto Health added Health and kept Hobbies (Ctrl held by
  `keybd_event` through the drop). The Hobbies topic went under Music, then back to the root
  on All memories. Sailing dragged onto its own subtopic was refused: red outline on the
  target, as in `qa/shots/mt5-refused.png`, and nothing written.
- **§19.6's third way, a drag:** passed. "The P4 hotel is the Kinosaki Inn." dragged from
  P4 Memories QA onto Health lost its project topic and `projectId`. A project rename then ran
  the upkeep, and it wasn't filed back.
- **A long list:** works but takes scrolling. The inbox (30 rows here) shows above every
  topic's memories, so a topic's own memories start below it. The memory pane scrolls on its
  own, but a wheel at its end scrolls the whole page, which can push the tree's top rows off
  screen. Every drag was done with both ends on screen.
- **§19.1, account switch through Settings:** passed on `qtopic5`. Signed out as Settings
  does, into qa-127 (no Gaia data there), out, and back into qa-128. After the pull its 24
  topics (four nested, one three deep) and 334 memories matched `gaiaqa`'s exactly, with
  nothing queued.
- **§19.2's second half, two devices:** passed. `gaiaqa` put Sailing under Gardening and
  `qtopic5` put Gardening under Sailing in the same 2 ms. Both stored the same cycle, and both
  resolve it at the older write (Sailing, 1.9 ms older): Sailing is a root with Gardening
  under it, in the tree and the topic list. Nothing lost or duplicated.
- **§19.4, the agent searching its memories (stage 2 off):** passed on both. Asked "Who is my
  insurer again, and when do I need to renew?", nothing was recalled, and Haiku called
  `memory_search` unprompted and answered Belairdirect, renewing in August. On Codex, "Which
  garage puts my snow tyres on, and roughly when?" got `memory_search` unprompted and
  Canadian Tire, mid-November. "Check your memories" was never needed.
- **A narrow desktop window:** passed. The window stops at 1,424 px (712 logical). The tree is
  a button, the dialog lists the tree, and picking Family closed it and relabelled the button.
  The dialog's topics have no ⋯ menu on Windows; that's §20.2 item 7, not a gap.
- **Search on real data:** passed. "heartworm" (a word in a memory) and "Plugins" (a topic
  name) each filtered both panes.
- **Restore from Settings → Trash:** passed. The long-named topic under CS246 › Assignments
  came back under Assignments with no memories. Its delete dialog asked first.
- **Not run:** the phone.

### 22.2 Phase 5 (§21.4)

- **`/remember`:** passed. The toast "Remembered", and 0.7 s later the memory was in Pets with
  the tags heartworm, medication and monthly (`[gaia] memory placement: 1 topics`).
- **`memory_propose` on Claude Code:** passed. Asked to save a fact, Haiku passed
  `topics: ["Pets"]` from the list itself. Asked to leave `topics` out, it did, and placement
  filled the open card about 1.8 s later with "+ New topic: Sailing" and four tags.
- **`memory_propose` on Codex:** passed. It passed `topics: ["Car"]` from the list itself (for
  a bike: the nearest existing topic).
- **The card:** BUG-381 at first: "+ Topic" → Family and the chip's × reached the controller
  but the chips didn't change, so the card would have saved what it didn't show. Fixed by
  rebuilding the card with the controller. After the fix: Family added, Pets removed, then
  Remember saved it active in Family alone. Offers: taken (Sailing made at the root and the
  memory filed there), dropped (offer cleared, memory Unsorted), and left (offer kept on the
  remembered memory). The "+ Topic" menu fits the window and leaves out topics the memory is
  in. At the companion's narrowest (1,104 px) a three-level path is cut off with its × still
  showing.
- **The Memories tab:** passed. The offer chip on a remembered row and on inbox rows made the
  topic and filed the memory. Two memories offered the same "Gardening" made one topic between
  them. Suggest shows only on an Unsorted row with no offer; it filed one in Hobbies with the
  companion running. With the companion killed just before the click it was started again
  with no window (hwnd 0) and the memory filed in Health. The host also restarts a killed
  companion within 2 s on its own, so which of the two started it isn't certain; both start
  hidden.
- **The curator:** four chats that mentioned facts in passing, curated after 10 quiet
  minutes. It found four facts and filed each in an existing topic (knee in Health, spin class
  in Fitness, sister's wedding in Family, the Pentax in Hobbies), offered no new topics, and
  found nothing in the A5 chat. Each pass took 2-6 s. Its input for one of them was 2,262
  characters (the 40 nearest memories) and 24 topic lines, against about 19,400 characters for
  a full index of the 305 active memories.
- **Two devices:** passed. An offer accepted on `gaiaqa` reached `qtopic5` with the same topic
  id within a second. Accepting one offer on both at once (4 ms apart) made two "Woodworking"
  topics, as §21.2 item 5 says; the memory ended in the same one on both. Deleting the empty
  one was clean on both, and the two databases then matched exactly.
- **Duplicates without walls:** passed. In a CS246 chat, `/remember The P4 hotel is the
  Kinosaki Inn.` (saved in P4 Memories QA) said "Already remembered".
- **§18.4's word-mismatch misses:** the 274 seeded memories were placed through the page's
  Suggest path, three at a time: all 274 answered, none failed, in 4 minutes (about 0.8 s
  each). Then, with stage 2 on, "when is Biscuit due for shots" put the vaccine memory first
  among 24 candidates (0.24, from its new "shots" tag). Stage 2 picked 3 in 791 ms, and Haiku
  answered March 2027. "I have been sleeping badly" still had no candidates, so stage 2 never
  ran, and the agent didn't search either. "my sleep has been bad lately" does reach the
  sleep memory, at 0.13. So the remaining miss is the -ing form alone (§21.3). Stemming was
  added after the pass (§22.4).
- **Not run:** the phone's offer chip.

### 22.3 Left on qa-128

New chats from this pass ("Adopting Second Dog Pepper", "Sailing dinghy storage memory" and
about ten more); topics Sailing (with Gardening under it), Hobbies, Gardening, Astronomy,
Woodworking and "Biquadris group project design documents and UML diagrams"; the memories they
hold; inbox proposals from the curator and the agents; and tags added to the seeded memories
by the placement burst. `sol` is back on `gpt-6.1-sol`, the debug switch is off, and
`qtopic5` ended signed out.

### 22.4 Stemming in stage 1 (2026-11-17)

Decided after §22.2: stage 1 stems `-ing` and `-ed` as well as a plural `s`
(`_recallStem` in `gaia_memories.dart`), the same on the message and the memories. A doubled
consonant left behind is made single ("running" meets "run"), but not l, s or z ("falling"
stays "fall"). The stem always keeps three letters, so "thing" and "used" stay whole. A
dropped `e` isn't put back, so "making" still doesn't meet "make"; that wasn't seen in the
probes and is left.

- **Tests:** `gaia_memory_recall_test`, "an -ing or -ed form meets its word, either way
  round" (sleeping and sleep, booking and Booked, run and running, needed and Needs). It
  failed before the change. The memory, topics and recall test files and the controller's
  recall group all pass.
- **Live, `gaiaqa`:** "I have been sleeping badly" now has 4 candidates, the sleep memory
  among the top. With stage 2 on, it picked 3 of 4 in 740 ms (the sleep memory, cutting
  caffeine, reading before bed), and Haiku answered from them. On §18.3's 24 messages the top
  candidates are unchanged in kind and none is strong. One new weak false candidate:
  "pulling" now meets "pull-ups" (0.12, second for the leash message). The valgrind message,
  0.52 in §18.3, is now 0.44, below the threshold. The corpus also grew by about 40 memories
  and the placement burst's tags since then, so how much of that drop is the stemming isn't
  known.

## 23. Phase 6 build notes (2026-11-17)

### 23.1 What was built

- **Topic merge (§3.2):** `GaiaMemories.mergeTopic(from, into)`, one write. Each of the
  merged topic's memories is in the kept one instead (once), its subtopics move under the
  kept one, and it goes to the trash. On the desktop it's right-click → **Merge into…**, on
  the phone the topic's ⋯ menu: pick the topic to keep, then confirm. A linked project's topic
  can be kept but not merged away: its item is disabled and reads "Merge into… (a project's
  topic stays)", and `mergeTopic` refuses it too.
- **Sort these (§6):** a button above Unsorted's memories, on the desktop. It sends them to
  the utility model in batches of 30 (`kGaiaSortBatch`), one call per batch
  (`GaiaUtility.placeMany`, through a new `sortMemories` pipe request to the companion). Each
  answer shows on its memory's row as "Suggested:" chips: the existing topics, any new topic,
  each with × to leave it out. **Accept** files it, **Skip** drops the suggestion, and **Accept
  all (N)** accepts every one shown. Nothing is filed before that.
- **The recall history (§3.3)** is written now. After a message's recall is settled (stage 2
  or stage 1), the companion sends `recalled {chatId, memoryIds}`, and the main instance keeps
  one row per memory per chat for the 20 chats that recalled anything most recently
  (`recordRecall`).
- **Pin suggestions (§3.3):** "Pin this?" in the inbox, with **Pin** and **Not now**, for an
  active, unpinned memory recalled in at least 8 of the chats in the history ("Recalled in 9
  of the last 20 chats"), or one the curator flagged as about you in general ("About you in
  general"). The curator now returns `"pin": true` for those. Not now puts it off 30 days
  (`kGaiaPinLater`).
- **Merge suggestions (§5):** "Merge X into Y?" in the inbox, with **Merge** and **Keep
  both**, for two topics under the same parent with near-identical names, or two that share
  most of their memories (`gaiaMergeSuggestions`).
- **A local table for the suggestions' state:** `gaia_memory_hints_table` (schema 201 → 202),
  holding the curator's pin flags, Not now until when, and the pairs kept apart. Like the
  recall history, it isn't synced or backed up.

### 23.2 Decisions made while building

1. **The suggestions' state is local, in a new table (schema 202), not new synced fields.**
   Pin suggestions already count this device's recall history (§3.3), so a pin flag and Not
   now that stay on the device fit them, and the curator runs on the device whose main
   instance saves what it finds. The cost is that **pin suggestions only show on the desktop
   that ran the chats**, and **Keep both** on one device doesn't stop the other suggesting the
   same merge. Merge suggestions show on every device, the phone included.
2. **"8 of the last 20" counts chats in the history**, so with fewer than 20 chats that
   recalled anything, 8 of them still counts. A memory recalled twice in one chat counts once.
3. **The curator's pin flag waits for the memory to be remembered.** A flagged proposal sits in
   the inbox as a proposal first; "Pin this?" shows once it's active. Pin over the budget gives
   the usual toast.
4. **Merging a topic into one of its own subtopics** moves that subtopic up to the merged
   topic's place first, so the other subtopics can go under it without a cycle.
5. **A new topic offered under the merged topic** (`suggestedTopic.parentId`) is offered under
   the kept one instead. Without that, it would be offered at the root.
6. **Merge clears `projectId`** on a memory taken out of an unlinked project topic, through the
   same `_refiled` as delete and remove (§16.2 item 6), so the upkeep doesn't file it back
   when its project is restored. That's §19.6's third way.
7. **Merge from the topic menu asks first; Merge from the inbox doesn't.** The inbox row is
   already the question. Either way it can't be undone, except that the trash restores the
   topic alone, as for delete (§20.2 item 11).
8. **What counts as a merge suggestion:**
   - **Names:** the same after lower case, punctuation and a plural `s` ("Assignments" and
     "assignment", "Co-op" and "co op"), and only between topics under the same parent. CS246 ›
     Assignments and CS245 › Assignments are different topics.
   - **Memories:** at least 3 in common, and at least three quarters of the memories in
     either.
   - **Never** a topic and one under it, and never two linked project topics.
   - **The one kept:** a linked project's topic, else the one with more memories, else the
     older, else by id.
   - Kept apart is forever on the device; there's no undo short of the database.
9. **Sort these covers Unsorted's remembered and archived memories as shown**, the search
   applied, and not the inbox's proposals, which are shown across every topic. Memories that
   already have a suggestion aren't sent again.
10. **Accepting a suggestion with a new topic makes it.** §5 says new topics are never made
    silently; accepting one you can see is asking for it. Two memories accepted with the same
    new name share one topic (§21.2 item 5). To keep a memory out of the new topic, × its chip
    first.
11. **Suggestions are held in memory on the page, not stored.** They survive leaving the tab
    but not a restart; Sort these again costs one call per 30. A memory filed some other way
    meanwhile (a drag, Suggest), or deleted, loses its suggestion for good, so if it's ever
    back in Unsorted it shows none and the next Sort these asks about it again.
12. **One call per batch, with numbered facts.** The answer names each fact by its number, not
    its id, so 30 uuids aren't repeated back. A batch has 90 seconds. A failure stops the run
    and shows why beside the button; the batches already answered stay.
13. **The inbox's section count includes the suggestions**; the tab's badge still counts
    proposals only.
14. **A memory unpinned on purpose is never suggested as a pin again**, by either route (the
    recall history or the curator's flag). Unpinning stores a `pinLater` hint with no until,
    which counts as for good. Like Keep both, it's on the device and has no undo short of the
    database; pinning it by hand still works.

### 23.3 How it was checked

- **Unit tests:** `gaia_memory_topics_test`, "merge and suggestions" (merge moves memories
  once and subtopics, into its own subtopic without a cycle, an offer re-pointed, a project
  topic kept but not merged away until its project is deleted, and its memories losing
  `projectId` and not filed back after a restore; the recall history keeping 20 chats; pin
  suggestions at 8, not for pinned or archived ones, Not now for 30 days, never again once
  unpinned, the curator's flag only once remembered; merge suggestions by sibling names and by memories in common, none for
  a topic and one under it, Keep both, and a project topic kept). `gaia_utility_test`:
  the curator's `pin`, Sort these' answer parser (numbers, out of range, repeated, nothing
  placed) and its job's input. `gaia_migration_test`: 201 → 202.
  `import_export_test`: the new table listed as local-only.
- **Controller tests:** the recall history written for a recalled message
  (`gaia_controller_test`, "memory recall"), and Sort these through the pipe returning
  placements by id without filing anything ("placement on capture").
- **Widget tests** (`gaia_memory_tree_test`, Windows variant, under a 1.5 GB watchdog, peak
  1.27 GB): Merge into… from the right-click menu; Sort these with ×, Accept and Skip; Accept
  all making one new topic for two memories; a memory filed some other way losing its
  suggestion and asked about again once back in Unsorted; the inbox's pin and merge
  suggestions with Pin and Keep both. 13 passed in the file.
- **The Gaia suites** (controller, host, memories, recall, card, utility): 541 passed.

### 23.4 Live checks still to do for Phase 6

All need the app on the screen and real Haiku in `gaiaqa`, or the phone.

- **Sort these on real data:** in `gaiaqa`, make a few dozen memories Unsorted, then Sort
  these. Check the batches (log `[gaia] memory sort: placed N of M in T ms`), how good the
  placements are, how often it offers new topics and whether facts that belong together get
  the same one, and Accept, ×, Skip and Accept all on screen.
- **Pin suggestions live:** with stage 2 on, run the same subject in 8 chats; "Pin this?"
  shows for its memory. Pin, Not now (gone, and not back after a restart), and a pin over the
  budget.
- **The curator's pin flag:** a chat that states something general ("I'm a CS student at
  Waterloo"); after the curator runs, the memory is in the inbox, and once remembered "Pin
  this?" says "About you in general".
- **Merge live:** from the menu, on a project topic kept and on one under the other; from the
  inbox, both rules. Restore the merged topic from Settings → Trash: it comes back with no
  memories.
- **Two devices:** a merge made on one reaches the other, memories and subtopics included;
  Keep both on one doesn't hide it on the other (§23.2 item 1).
- **The phone:** Merge into… in a topic's ⋯ menu, and merge suggestions in the inbox. No Sort
  these and no pin suggestions there.
- **§19.6's third way, by merge:** a memory in an unlinked project topic, merged away, loses
  `projectId`, and isn't filed back when the project is restored (unit-tested only).

## 24. Live pass, 2026-11-17 (Phase 6)

`gaiaqa` (qa-128) on a copy of the Debug build with a fresh `flutter build bundle` of this
tree (schema 201 → 202 on launch), the main window parked off-screen and driven by `voy.ps1`
in background mode, VM eval (`qa/steps/mt6-*.dart.txt`) and read-only SQLite. A fresh
`qtopic5` on the same account was the second device. Real turns on Juno's default Claude
account (Haiku), stage 2 on for the pass. One new bug, BUG-382, not fixed. The phone wasn't
run: there's no emulator or `adb` on this PC.

- **Sort these on real data:** passed, with BUG-382. 33 filed memories were made Unsorted
  (three from each of nine topics) and six new ones saved (bouldering and Spanish lessons),
  56 in all with the 24 already there. Two batches: `placed 25 of 30 in 10921 ms` and
  `placed 26 of 26 in 19995 ms`. The five not placed were the long "MT3 budget" filler.
  Every seeded memory went back to the topic it came from (Car, Cooking, Family, Finance,
  Fitness, Music, Pets; Obsidian's Plugins ones to Obsidian › Plugins, one to Obsidian), and
  "the A5 plan of attack" to CS246 › Assignments. New topics were offered for 21: Languages
  (all three Spanish facts), Preferences (7: colour, season, metric units, dark mode, …), Tea
  (2), Travel (2, the Dordogne and the P4 hotel), Gap checks and Global markers (QA markers).
  Facts that belong together got the same name every time. The bouldering facts went to
  Fitness rather than a new topic. Inbox proposals weren't sent (§23.2 item 9).
  On screen: Accept filed one in CS246 › Assignments and its row left Unsorted; Skip dropped
  the suggestion and kept the memory and its older offer; × on a row's only chip dropped the
  suggestion (no row had two chips, so × leaving the rest wasn't seen); Accept all (48) filed
  all 48 in about 4 s and made each new topic once (no duplicate names). **BUG-382:** a row
  whose memory already had a Phase 5 offer shows two "+ New topic" chips, the old offer above
  and Sort's beside Accept, and accepting Sort's after its topic exists also makes the old
  offer: the timezone memory ended in Preferences and a new "Profile".
- **Pin suggestions live:** passed. Eleven Biscuit chats with stage 2 on (each picked 1-8 of
  18-40 candidates in 1.0-2.6 s); the recall history kept one row per memory per chat. Three
  memories reached 8: "Pin this? Recalled in 9 of the last 11 chats." (§23.2 item 2's
  wording with fewer than 20). Pin pinned the diet memory; Not now put the weight memory off
  to 2026-12-17, and after a restart only the corgi row came back. With pins at 1,999 of
  2,000 characters, Pin on the corgi row gave the budget toast (warning icon) and pinned
  nothing; the filler pins were taken off again after.
- **The curator's pin flag:** not checked yet. The chat ("I am left-handed and a third-year
  CS student at the University of Waterloo…") was sent at 04:06:53 and the curator wasn't due
  until about 04:17; the pass stopped before then. The eleven Biscuit chats were curated in
  the meantime and gave nothing new, which is right.
- **Merge live, from the inbox:** passed for both rules. "Merge "Language" into
  "Languages"? Near-identical names." and "Merge "Drinks" into "Tea"? 3 memories in common."
  (Drinks made with the same three memories as Tea). Merge on each moved the memories once
  and trashed the merged topic. Keep both on "Teas"/"Tea" wrote a `keptApart` hint and hid it.
- **Merge live, from the menu:** passed. Right-click → Merge into… lists every topic but the
  one merged, then asks ("Its memories and subtopics move to …, and … goes to the trash.").
  "Global markers" into the project topic "P4 Memories QA": its three memories moved there.
  The project topic's own item is disabled ("Merge into… (a project's topic stays)") and a
  click does nothing; Delete reads "Delete (goes with its project)". Sailing into its own
  subtopic Gardening, the pair §22.1 left stored as a cycle: Gardening became a root with all
  three memories and the cycle was gone. The picker hides Sailing, so Gardening shows indented
  under the row above it ("Profile"), as if it were Profile's subtopic; the confirm says
  "Sailing › Gardening" correctly. Cosmetic, not filed.
- **Restore from Settings → Trash:** passed. Sailing came back under Gardening with no
  memories.
- **§19.6's third way, by merge:** passed. A memory saved with P4 Del Trash's `projectId` and
  filed in its topic; the project deleted (topic unlinked); the topic merged into Travel from
  the menu: the memory was in Travel with no `projectId`. Restoring the project linked its
  topic again and the memory stayed in Travel.
- **Two devices:** passed. `qtopic5` signed in fresh and its pull matched `gaiaqa` exactly (36
  topics, 349 memories, merges included). A live merge on `gaiaqa` (Gardening, with Sailing
  under it, into Hobbies) reached `qtopic5` with its memories and the subtopic re-parented,
  between 11 and about 25 s later (just after its first pull). Keep both on `gaiaqa` didn't
  hide "Merge "Teas" into "Tea"?" on `qtopic5`, which also showed no pin suggestions
  (§23.2 item 1).
- **Not run:** the phone (Merge into… in the ⋯ menu, merge suggestions in its inbox).

Left on qa-128: the Biscuit and general-fact chats from this pass; topics Languages,
Preferences, Profile, Tea, Teas, Travel, Gap checks; Hobbies now holding Gardening's memories
with Sailing under it; the merged topics in the trash; "MT6 P4 Del Trash marker" in Travel;
the diet memory pinned.

## 25. Stage 2 on by default, and the last live checks (2026-11-17)

`gaiaqa` (qa-128) on a fresh debug build of the working tree, the main window parked
off-screen and driven by `voy.ps1` in background mode, VM eval (`qa/steps/mt7-*.dart.txt`)
and read-only SQLite. The phone was the Android emulator (`Medium_Phone_API_37.0`) on a fresh
debug APK, wiped and signed in to qa-128 by email, driven through `qa/harness/phone.ps1`
(below), with its database read over `run-as`. Real turns on Juno's default Claude account,
and Codex on the `sol` agent pointed at `gpt-6-luna` for the pass, then set back. One new
bug, BUG-383, not fixed.

### 25.1 Stage 2 on by default

Decided by Juno on 2026-11-17, ahead of §11's clean bursts: stage 1 alone gives almost no
recall (§18.3, §18.4), and a pass costs about 1.2k tokens and answers in under a second most
of the time (§11). `GaiaDebug.recallPick` now starts true, and the debug menu's switch only
turns it off. It's saved as `recallPickOff`: every `debug.json` written while it was off by
default has `recallPick: false` from any other toggle's save, which wasn't a choice, so that
key is no longer read. Checked by `gaia_debug_test` ("recall's stage 2 is on by default, and
an old file's off isn't a choice"), which fails on the old default, and live: `gaiaqa`'s
`debug.json` from §24, with `recallPick: false`, loaded as on. With recall and the router
both on, a new chat starts two utility processes ahead; the controller test that counted one
now counts two. §11's bursts and week of chats now tune the later-message trigger only.

### 25.2 What was checked

- **The curator's pin flag** (§23.4): passed. A new chat stated "I am left-handed and a
  third-year computer science student at the University of Waterloo". The curator ran 10
  minutes after the reply (`curator: 2 from …`) and proposed the student fact, filed in
  Profile, with a `pinCandidate` hint. Once remembered, the inbox read "Pin this? About you in
  general." (`qa/shots/mt7-pinflag.png`). §24's chat with the same facts had been curated
  since and left two near-duplicates in the inbox ("I am a third-year CS student…", "I am
  left-handed."): the curator was shown active memories only, so a proposal still waiting
  could be offered again in other words. Fixed after the pass (§25.4).
- **The curator filing in a project chat** (§15.4): passed. In a CS246 chat, "My CS246 final
  project group meets every Wednesday at 4pm in the MC building, and my teammate Priya is
  doing the UML diagrams" was proposed as "My CS246 project group meets every Wednesday at 4pm
  in the MC building.", filed in CS246 and CS246 › Assignments.
- **A real Codex turn with `memory_search` `topic`** (§15.4, §18.1): passed. "What memories
  do you have saved under my Final exam topic?" was answered from `<gaia_memories>` (7, with
  stage 2 on) and made no call. Asked whether that was all, Codex called
  `memory_search({topic: "CS246 › Final exam"})`, the full path from the topic list, and
  listed all 14.
- **Sort these, × on one of two chips** (§24): passed. Of seven memories seeded across two
  topics, three got two chips (Travel and Family; Tea and Languages; Obsidian › Plugins and
  CS246 › Assignments). The prompt asks for "usually 1", and the four looser ones got one.
  × on Family left Travel, and Accept filed the memory in Travel alone.
- **The phone, Phase 1** (§15.4): passed. A project made on the phone ("MT7 Phone Proj") got
  its linked topic on the desktop, and a rename on the phone was followed by the topic (v2).
  The phone pulled the same 33 topics as the desktop; its error log has only a
  `hotkey_manager` plugin message at start.
- **Phase 2** (§16.4): passed, with BUG-383. The Codex chat's reply showed "Recalled 3
  memories" after sync; opened, it listed each under "CS246 › Final exam" with "Given to the
  agent with this message. It may not have used them." Tapping a memory went back to the Gaia
  page's Memories tab with it highlighted, but the first time the page didn't scroll to it
  (BUG-383); a second tap scrolled and highlighted.
- **Phase 4** (§20.5): passed. The tree button opens the Topics dialog, each topic with a ⋯
  menu: Rename, New subtopic, Move under… (the picker leaves out the topic and its subtree),
  Merge into… and Delete ("Its memories stay in their other topics, or go to Unsorted. Its
  subtopics move up to …"), each reaching the desktop. A linked project's topic shows
  "Merge into… (a project's topic stays)" and "Delete (goes with its project)" disabled; at
  phone width the first is cut off. A memory's ⋯ has Move to topic… (from All memories it
  replaced both topics) and Add to topic… (kept Car, added the new one). The button's label
  followed a re-parent ("MT7 Phone B › MT7 Phone A2 › MT7 Sub").
- **Phase 5** (§21.4): passed. A `/remember` that placement offered "+ New topic:
  Volunteering" showed its chip on the phone; tapping it made the topic and filed the memory.
  × on the Keychron memory's "Computer setup" offer cleared it with no topic made. No Suggest
  button on the phone, on an Unsorted memory with no offer either.
- **Phase 6** (§23.4): passed. Merge into… from the phone moved a topic's memory and its
  subtopic into a project topic and trashed it. The inbox's "Merge "Teas" into "Tea"?" showed
  on the phone, and Merge there trashed Teas on the desktop. No Sort these on the phone's
  Unsorted view and no pin suggestions in its inbox.

### 25.3 The phone and Juno's real account

Before the wipe, the emulator's install, kept by `adb install -r`, was still signed in to
Juno's real account. It showed the login page for a moment while that session loaded, and
taps and typed text meant for the login page landed in the real app. What they hit wasn't
seen; Juno chose to wipe the install (`pm clear`). Since then, input reaches the emulator
only through `qa/harness/phone.ps1`, which refuses any tap, typing, swipe or key unless the
app is signed out or the account its local data belongs to (`settings_table
.local_owner_uid`, read over `run-as`) is listed in `qa/harness/phone_accounts.txt`
(qa-128 only). Checked both ways: allowed on qa-128, refused with qa-128 taken off the list.

### 25.4 The curator is shown every memory offered before (2026-11-17)

Decided after §25.2's near-duplicates. `save` already drops a memory that says exactly what
any other says (`gaiaMemoryKey`, inbox and dismissed ones included), so "I am left-handed."
wasn't saved twice; a rewording gets past it, and only the model can tell. `curatorContext`
now ranks every memory offered before for its 40: active, waiting in the inbox, archived, and
dismissed or deleted, the same set `save` checks for exact duplicates (`_offeredBefore`, now
shared by both; a deleted one whose project is gone stays out, as before). The prompt calls
them "Memories kept, waiting for the user to approve, or set aside by the user" and asks it to
leave out anything already among them "however worded". Fuzzy matching at save time was
considered and left out: wording alone either misses a rewording or merges two different
facts.

- **Tests:** `gaia_memories_test`, "the curator's list has every memory offered before, one
  line each: kept, waiting, archived and dismissed" (it said active only before), which also
  checks a deleted memory of a gone project stays out. The memories, topics, utility and
  controller test files pass; `save`'s duplicate tests are unchanged and pass.
- **Live, real Haiku** (a throwaway probe of `GaiaUtility.curate`, three runs each): a chat
  restating qa-128's two waiting proposals in other words ("I'm a lefty…", "my CS246 group
  still gets together Wednesdays at 4 in MC"). Shown the active memory alone, the curator
  proposed both again every time ("I'm left-handed, so most mice feel awkward to me.", "My
  CS246 group meets Wednesdays at 4 in MC."). With the two proposals in its list, it returned
  `[]` every time. Run again with the final prompt (the list as dismissed or archived ones
  appear, no status shown), the chat also mentioning a new cat: three of three proposed only
  "I just adopted a cat named Miso.", so a new fact still gets through.
- **Cost:** a user who sets many memories aside fills more of the 40 with them, leaving fewer
  places for active ones near the chat. The 40 are still the nearest by stage 1, whatever
  their status. *Changed by §25.5.*

### 25.5 Deleted memories left out, and kept ones given their own 40 (2026-11-17)

Decided by Juno after a review of §25.4.

- **A kept or archived memory the user deleted is no longer shown to the curator.** Deleting
  it is asking Gaia to forget it, and §25.4 sent its text to the utility model again whenever
  a chat touched it. Shown, it also stopped a corrected fact (a move back to a city once
  deleted) from ever being learned again. A dismissed proposal is still shown: the model
  wrote it from the user's own chat, so it shows the model nothing new, and it's what stopped
  §25.2's rewordings. A deleted fact can now be proposed again; dismissed, it stays out.
  `save`'s exact-duplicate check is unchanged.
- **Kept memories aren't crowded out.** The curator gets the 40 nearest active memories, then
  the 20 nearest waiting, archived or dismissed ones, each ranked by stage 1 on its own.
- **Tests:** `gaia_memories_test`, the curator's list test now also checks that a deleted
  active and a deleted archived memory stay out, and "set-aside memories don't crowd kept
  ones out of the curator's list" (50 dismissed and 40 kept, all matching: 40 kept and 20
  dismissed listed). The memories, utility, controller and debug test files pass. Not checked
  live against Haiku.

Left on qa-128: the curator, Codex and remember chats from this pass; the CS246 group proposal
and the two §24 duplicates in the inbox; the student fact remembered, in Profile; topics MT7
Phone Proj Renamed (its project too) with MT7 Sub under it, and Volunteering; MT7 Phone A2,
MT7 Phone B and Teas in the trash; six of the seven "MT7 …" memories Unsorted and the Japan
trip one in Travel; the cabin air filter memory back in Car. The emulator is signed in to
qa-128.
