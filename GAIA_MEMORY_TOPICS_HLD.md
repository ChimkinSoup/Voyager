# Gaia — Memory Topics and Recall (HLD)

Status: **Phase 1 built (2026-11-16)**, checked by unit tests and a two-profile sync pass; its
live checks still to do are in §15. Phases 2-6 not built. Drafted 2026-11-15. This replaces the memory index in GAIA_HLD.md §11 and
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
  used instead.

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
  its input doesn't grow with your memory count.

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
| 4 | The Memories tab tree: new, rename, move, add, re-parent, delete, search. Android menus. |
| 5 | Placement on capture, suggested topics on cards and in the inbox, the curator's smaller input. |
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

**To do once Phase 3 is built, before stage 2 is turned on by default.**

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

**What it decides:** the threshold, and whether stage 2 runs on later messages or only on the
first one. Write the numbers into this section. If the cost turns out too high, the fallback is
stage 2 on the first message only, with stage 1 alone after that.

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
7. **`memory_search` paths** accept `›`, `>` or `/` between names. With only `topic`, it lists
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
