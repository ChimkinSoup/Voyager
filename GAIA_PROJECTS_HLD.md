# Gaia — Projects (HLD)

Status: **Designed 2026-11-10, not built.** Decided with the user the same day: projects
group chats, give them a shared folder and shared memories, and let each chat read the
others through tools. There are no shared project instructions. The open questions were
settled the same day (§11), and pinning was changed to pin a chat inside its project (§7.1).

## 1. Summary

A project is a named group of chats around one theme, like a project in Claude desktop.

- **A chat is in at most one project**, or in none, like today's chats. It can be moved in,
  moved to another project, or taken out at any time (§3).
- **Every chat can read the project's other chats** through three Gaia tools:
  `project_chats`, `project_search` and `project_read` (§5). They're on by default, in every
  project chat. Each call shows as a tool call in the chat, and its arguments and result can
  be opened (§5.4).
- **A project can have a folder**, set per device. Every chat in the project gets it as an
  extra directory (`--add-dir`), never as its working directory (§4).
- **A project has its own memories**, alongside the global ones (§6).
- **No project instructions.** GAIA.md is still the only instruction file (decided
  2026-11-10).
- **Deleting a project leaves its chats by default**, as ordinary chats with no project.
  A checkbox in the delete dialog deletes them too (§3.3).
- **Desktop and Android.** Projects sync like chats. The phone can create, rename, delete
  and move between them. Remote prompts to a project chat work as they do today (§7.4).

## 2. Data model

A new synced collection, and three fields on chats and memories. It is mirrored in drift
and synced through the outbox like the other Gaia collections (GAIA_HLD.md §8).
`firestore.rules` already matches any `users/{uid}/{collection}`, so it needs no change.

| Collection | Doc | Fields |
|---|---|---|
| `gaia_projects` (new) | one per project | name, `folders` {deviceId → path}, createdAt, updatedAt, version, deletedAt |
| `gaia_chats` | one per chat | + `projectId?`, + `summary?`, + `summarizedSeq` (default −1) |
| `gaia_memories` | one per memory | + `projectId?` (null = global) |

And on a chat's `agentSessions` entry (`{sessionId, lastSeq}`) one more field, `project`:
the project id the session was last told about (§5.2).

**A `projectId` that points nowhere means no project.** If the project is missing, deleted
or not synced yet, the chat shows and runs as an ordinary chat. This covers the sync races:
a device moving a chat into a project that another device just deleted, or a stale copy
writing an old `projectId` back. Nothing repairs such a chat. It simply has no project
until it's moved.

## 3. Creating, moving and deleting

### 3.1 Creating

- **Sidebar:** a **New project** button at the top of the Projects section asks for a name.
- **Android:** the same, on the Gaia page's chat list.
- A project starts empty, with no folder.

### 3.2 Moving chats

- **Right-click a chat → Move to project ▸** lists the projects and **New project…**, and,
  for a chat already in a project, **Remove from project**. The same menu is on the phone.
- **New chat in a project:** the **+** on a project's sidebar row, or its right-click menu.
  The new-chat composer shows a project chip (like the tier chip) that can be changed
  before the first send. Ctrl+N still starts a chat with no project.
- **Forks inherit the project** of the chat they're forked from. Moving a fork later moves
  only that fork.
- A chat can be moved while it's replying. The next turn picks the change up (§5.2).

### 3.3 Deleting

**Delete project…** opens a dialog:

> Delete "Trip to Japan"?
> Its 7 chats will stay, as chats with no project.
> ☐ Also delete its 7 chats

- **Unchecked (the default):** the project goes to the trash and each of its chats has its
  `projectId` cleared, in one batch. The chats stay where they are, in the main Chats list.
- **Checked:** the project and its chats go to the trash together. Restoring the project
  restores those chats with it, still in the project.
- **Restoring a project** whose chats were let go brings it back empty. Its old chats aren't
  pulled back in, because the user may have moved them since.
- The project's **memories follow the checkbox** (decided 2026-11-10). Unchecked, they
  become global (`projectId` cleared, in the same batch as the chats). Checked, they go to
  the trash with the project and come back with it.
- The folder on disk is never touched. Only the binding goes.

## 4. The project folder

- **Set per device**, like a workspace binding (GAIA_HLD.md §5.2), since paths differ
  between machines: **Set folder…** in the project's menu opens the folder picker and
  stores `folders[thisDevice]`. The phone shows which desktops have one, but can't set one.
- **Always `--add-dir`, never the cwd** (decided 2026-11-10). The chat keeps Gaia's own
  working directory, so no project instruction file (CLAUDE.md, AGENTS.md) or project
  settings in the folder are loaded.
- **Built on the existing path:** `gaia_controller.dart` already builds a `directories`
  set for each turn from the chat's attached files and passes each one to Claude Code as
  `--add-dir`. The project folder joins that set when it exists on this device. A new or
  changed folder restarts the chat's process on its next turn and resumes the session, as
  a newly attached file's folder already does.
- **Agents can write in the folder** (decided 2026-11-10), not just read it. Claude Code's
  `--add-dir` already allows edits there.
- **Codex** reads anywhere already. Writes need the folder as a writable root on its
  sandbox. *Verify on app-server* that a thread can take extra writable roots, and how.
- **A device with no path for the folder still runs the chat** (decided 2026-11-10). The
  agent is told the folder isn't on this device (§5.2), and the chat header's project chip
  shows "no folder here". This differs from workspace chats, which refuse to run.
- **Permissions are the CLI's own.** Edits in the folder go through the same permission
  cards as any other edit, and through Auto where the chat is in Auto.

## 5. Reading the project's other chats

### 5.1 The tools

Three Gaia tools, served by the one `gaia` MCP handler (GAIA_HLD.md §5.3), so Claude Code
and Codex both get them with no per-vendor code. They're answered by the main instance
over the pipe, like the `voyager_*` reads, since it holds drift and the search index.

| Tool | Arguments | Returns |
|---|---|---|
| `project_chats` | none | Each chat in the project: id, title, last activity, message count and summary (§5.5). The current chat is marked. |
| `project_search` | `query`, `limit?` (default 10, max 30) | Matches from the FTS index, limited to the project's chats: chat id and title, `seq`, role and a snippet. |
| `project_read` | `chatId`, `from?`, `to?` (seqs) | That chat's messages in the range. With no range, its last 30. |

- **Registered in every chat**, not just project chats. Codex fixes a thread's tools when the
  thread starts, and Claude Code's sdk server lists them at `initialize`, so registering
  them per project would mean a restart on every move. A chat with no project gets the
  answer "This chat isn't in a project."
- **Scope is the chat's project only**: never project-less chats or another project's
  chats. A `chatId` outside the project is refused.
- **Under Abort they refuse, like every Gaia tool** (GAIA_HLD.md §15.7).

### 5.2 How the agent knows it's in a project

There are no project instructions, but the agent still needs to know the project exists.
Gaia adds a short context block ahead of the prompt, the way `<attached_files>` and quotes
are added. It goes on a session's first turn and on the first turn after the chat's
project changes (the session's `project` field differs from the chat's `projectId`):

```
<gaia_project name="Trip to Japan" chats="7" folder="D:\Notes\Japan">
Other chats in this project can be read with project_chats, project_search and project_read.
Project memories:
- Flights are booked for 3–17 April, arriving at Haneda.
- …
</gaia_project>
```

- `folder="not on this device"` when this device has no path for it.
- Taken out of a project, the next turn gets `<gaia_project removed/>` instead, so the
  agent knows the tools and folder are gone.
- It's per-turn context, not system prompt, because resumed sessions keep their first
  system prompt (GAIA_HLD.md §5.2, checked on 2.1.314). That way a move works mid-session.
- Cross-vendor handoffs and forks start a new session, so they get the block on their
  first turn.

### 5.3 What a read returns

`project_read` returns what a person sees in the chat, not the agent's session:

- Message text, quotes, file names, `[image N]` placeholders (not the images) and cards
  as one line each ("Proposal: todo 'Book ryokan', accepted").
- Tool calls by name only. No tool output and no thinking. This keeps a coding chat's
  reads short.
- Never rewound, deleted or btw messages, and never a reply that's still streaming (it
  shows as "still replying").
- Capped at about 24k characters. A longer range is cut at a message boundary, with the
  `seq` to continue from.
- It's wrapped as reference data, not instructions, like `voyager_*` reads
  (`<project_chat id="…" title="…">`). That's a mitigation, not a boundary (§5.6).

### 5.4 Shown as tool calls

Each call appears on the turn's activity card like other Gaia tools (`project_search`,
with no `mcp__gaia__` prefix). Opening it shows the arguments and the result text the
agent got. The result is kept the way `os_*` reads are kept today, in `GaiaToolResultStore`
(one file per call, on the device that ran it), and **never synced** (decided 2026-11-10).
Another device, the phone included, shows the call and its arguments, but not the result.

### 5.5 Chat summaries

`project_chats` is only useful if it says what each chat is about. So:

- When a project chat goes idle (the same 10-minute idle as the curator, GAIA_HLD.md §11),
  the utility model writes a 1–2 sentence summary if there are turns since `summarizedSeq`.
  Only the device that ran the chat's last turn does this, the curator's rule, so devices
  don't duplicate it.
- A chat moved into a project with no summary is summarized by the device that moved it.
- Chats with no project are never summarized, so projects cost nothing for chats outside
  them.
- With no utility model, the summary falls back to the first line of the first message.

### 5.6 Risk

On by default, as decided. Worth writing down: a chat with Bash or web tools plus
`project_read` could send another chat's content anywhere, the same exposure §5.3 of
GAIA_HLD.md accepts for `voyager_*` reads. Limiting reads to the chat's own project, and
showing every call on the activity card, are what bounds it.

## 6. Project memories

- **A memory with a `projectId` belongs to that project.** Global memories (null) work as
  today.
- **Recall:** the system-prompt index stays global only. A project's memory index goes in
  the `<gaia_project>` block (§5.2), so it's right even for a chat moved in mid-session.
  `memory_search` searches global memories plus the chat's project's memories, never
  another project's.
- **Capture:**
  - `memory_propose` gets an optional `scope` (`global` / `project`, default `project` in
    a project chat).
  - The curator proposes for a project chat with the project as the default scope.
  - `/remember` in a project chat saves to the project. `/remember --global` saves global.
- **Inbox and Memories page:** each memory shows a project chip. Its scope can be changed
  (move to global, or to another project). The Memories list filters by project.
- A memory added mid-session reaches running chats through `memory_search` only, as global
  ones already do.

## 7. UI

### 7.1 Sidebar (companion)

```
 Pinned
   ★ Haiku about rain
 Projects                           +
 ▾ Trip to Japan                    +
   ★ Itinerary
     Ryokan options
     └ Ryokan options (fork)
     Rail pass maths
 ▸ Voyager ideas            12 chats
 Chats
   Weekly review
   …
```

- **Pinning a chat in a project pins it to the top of its project** (decided 2026-11-10),
  not to the top-level Pinned section. The top-level **Pinned** section holds only pinned
  chats with no project.
- The pin is the chat's existing `pinned` field, so nothing new is stored. Where a pinned
  chat shows depends only on its project: moved out of a project, it shows in the top-level
  Pinned section; moved into one, it shows at the top of that project. A project folded
  shut hides its pinned chats with the rest.
- **Projects**, sorted by their most recent chat. Each row folds open to its chats, with
  forks nested and foldable as now. Which projects are open is kept in the sidebar's local
  file (`GaiaSidebar`), next to `collapsed`, and isn't synced.
- **Chats**: chats with no project, as today.
- A project's right-click menu: New chat, Rename, Set folder…, Delete project….
- Search (`gaia_search.dart`) shows each result's project, and gets a "This project" filter
  when the chat in view is in one.

### 7.2 Chat header

A chat in a project shows a project chip in its header. Clicking it opens the project's
menu. It shows "no folder here" when the project has a folder but not on this device.

### 7.3 Gaia page (desktop)

The Chats tab groups by project the same way. The Memories tab gets the project filter
(§6).

### 7.4 Android and remote

- The phone's chat list is grouped the same way, with create, rename, delete and move.
- A prompt sent from the phone runs on the beacon as today. The beacon uses its own folder
  path, or tells the agent there's none (§5.2). The cross-chat tools read the beacon's
  synced copy, so they work the same.

## 8. How it meets the rest of Gaia

- **Forks:** inherit the project (§3.2). **Rewinds:** no change. Rewound messages are left
  out of reads (§5.3).
- **btw:** no tools, so no project tools. A btw doesn't get the project block either.
- **Compaction:** the block was in the turns before the compaction, so the next turn after
  a compaction boundary sends it again (it counts as "not yet told").
- **Account switches / handoffs:** a new session is a new `agentSessions` entry, so it's
  told about the project on its first turn.
- **Auto mode:** the project tools are reads, so they never raise a card.
- **Queue and drain:** unchanged.
- **Trash:** projects go to the trash for 30 days like chats, and purge after that.
- **Account wipe:** `gaia_projects` is a drift table in `allTables`, so it's emptied with
  everything else.

## 9. Workspace chats in projects

Workspace chats (GAIA_HLD.md §5.2) are designed but **not built yet**. Nothing has to
change today to let them live in projects. When they're built, these are the points that
matter:

- **Two folders, two roles:** the workspace is the cwd (loads CLAUDE.md, hooks and user
  settings), and the project folder is only `--add-dir`. Both are per device. A workspace
  chat still refuses to run where its workspace has no path, and the project folder stays
  optional.
- **Safe mode:** workspace chats run without `--safe-mode`. Gaia's tools reach Claude Code
  as an in-process `sdk` server, which works either way, so the project tools are
  unaffected.
- **Read size:** coding chats are mostly tool calls. §5.3 already cuts reads to names, not
  output, which is what keeps them usable.
- **Risk:** a coding chat has Bash, so §5.6 applies in full. The planned `voyager_*` reads
  toggle for workspace chats doesn't cover project reads, since the user wants these on.

So: no major downside, and no extra code beyond keeping §4's "never the cwd" rule.

## 10. Phases

Built in order. Each phase ends with something usable.

| Phase | Scope |
|---|---|
| 1 | `gaia_projects` table + sync, `projectId` on chats, the sidebar sections, the move menu, the new-chat project chip, forks inheriting, the delete dialog and trash, the Gaia page and phone lists. |
| 2 | The three tools, the `<gaia_project>` block and the session `project` field, chat summaries, read results kept for the activity card's detail view. |
| 3 | Project folder: per-device binding, `--add-dir`, the Codex writable root, the header chip's "no folder here". |
| 4 | Project memories: `projectId` on memories, scoped search, `memory_propose` scope, the curator default, `/remember --global`, inbox and Memories page chips and filter. |

## 11. Decisions (2026-11-10)

1. **Agents can write in the project folder**, under the CLI's permission cards (§4). Still
   to verify: how Codex's app-server takes the folder as a writable root.
2. **A device with no path for the folder runs the chat anyway**, and the agent is told the
   folder isn't there (§4, §5.2).
3. **Project memories follow the delete dialog's checkbox:** global when it's unchecked,
   trashed with the project when it's checked (§3.3).
4. **Project tool results aren't synced.** They stay on the device that ran the call, and
   other devices show only the arguments (§5.4).
5. **Pinning a chat in a project pins it to the top of that project** (§7.1).

## 12. Testing

- **Unit:** the `projectId`-points-nowhere rule. Delete with and without the checkbox, then
  restore, checking where the chats and the project's memories end up. Fork inheritance.
  Where a pinned chat shows as it moves into and out of a project. `project_read` exclusions (rewound, deleted, btw, streaming)
  and its cap and continue `seq`. `project_search` scoping. Refusal for a `chatId` outside
  the project. The block sent on the first turn, after a move, after removal and after a
  compaction, and not otherwise.
- **Controller:** the project folder joins `directories` only when it exists on this
  device.
- **Sync:** delete on one device while another moves a chat in.
- **Live (qa profile):** a Claude Code and a Codex chat in one project, each searching and
  reading the other. The activity card detail. The folder on one device and not the other.
  A phone prompt to a project chat. Moving a chat mid-session.

## 13. Files likely touched

- `lib/data/database/app_database.dart` (+ migration), `lib/domain/models/gaia_models.dart`
- `lib/core/sync/firestore_collections.dart`, `lib/data/repositories/drift_repositories.dart`
- `lib/features/gaia/host/gaia_host.dart`, `gaia_chat_store.dart`, `gaia_memories.dart`
- `lib/features/gaia/tools/gaia_mcp.dart`
- `lib/features/gaia/companion/gaia_controller.dart` (directories, the block, summaries),
  `gaia_sidebar.dart`, `gaia_menu.dart`, `gaia_search.dart`, `gaia_tool_results.dart`,
  `gaia_commands.dart` (`/remember --global`)
- `lib/features/gaia/adapters/codex/codex_app_server.dart` (writable root)
- `lib/features/gaia/utility/gaia_utility.dart` (summary job)
- `lib/features/gaia/page/gaia_page.dart`, `gaia_remote_chat.dart`
