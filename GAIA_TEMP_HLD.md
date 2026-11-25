# Gaia — `/temp` Temporary Chats (HLD)

Status: **Built (2026-11-24).** The open questions were settled with the user the same day
(§10).

## 1. Summary

`/temp` makes the chat in view temporary. Temporary means two things:

- **It's off the chat lists once you leave it.** While it's the chat in view it stays where it
  is in the sidebar, marked as temporary. As soon as another chat is in view, it's in
  Archived (§4).
- **The memory curator never reads it.** Memories the curator already suggested from it and
  that still wait in the inbox are thrown out (§5, §6).

Other rules:

- **It works at any point:** in a new chat before the first message, partway through a chat,
  or while a reply streams (§3).
- **It can be undone.** `/temp` again, or Unarchive, makes it an ordinary chat. The curator
  then reads only what's said after that (§3.3).
- **It's still stored, synced and searchable**, like any archived chat. "Temporary" is about
  the sidebar and memory. The chat isn't deleted.

## 2. Data model

A new synced field on `GaiaChat`:

| Field | |
|---|---|
| `temporaryAt` | when `/temp` made it temporary; null for an ordinary chat |

`bool get temporary => temporaryAt != null;` and `archived` becomes
`temporary || <today's rule>`.

**Why not just set `archivedAt`.** The `archived` getter (`gaia_models.dart`, `GaiaChat`)
brings a chat back as soon as a message lands after `archivedAt`. The only exception is a chat
archived as it was made (`archivedAt == createdAt`), which is how Ask Gaia chats stay put
(GAIA_SETTINGS_HLD.md §7.2). A chat made temporary partway through would come back to the
list on its next message, including a prompt sent from the phone. A separate field also
gives the curator something to check that a plain archive doesn't change.

Drift: a nullable `temporaryAt` column on `GaiaChatsTable` plus a migration. It's also added
to the Firestore mapping and `copyWith` (`clearTemporaryAt`). Making a chat temporary also
clears `pinned` and `order`, as `gaiaArchived` does.

## 3. The command

`GaiaBuiltin.temp('temp', 'Make this chat temporary: archived when you leave, never read for
memories', aliases: {'temporary'})`, in `gaia_commands.dart`. It takes no arguments.
`/temporary` does the same (§10.4).

### 3.1 In a chat with messages

1. The controller writes `temporaryAt` through a new `setTemporary {chatId, temporary}` pipe
   request. `GaiaChatStore` handles it as it does `setArchived`.
2. The chat's `_curateSoon` timer is cancelled.
3. The host throws out the chat's waiting suggestions (§6) in the same request, and returns
   how many there were.
4. A toast: *"Temporary chat. It's archived when you leave, and nothing in it becomes a
   memory."* When suggestions were thrown out, it adds *"2 suggested memories from it were
   thrown out."* The toast has **Undo**, which turns temporary off and restores those
   suggestions.

### 3.2 In a new chat (no messages yet)

There's no chat row yet. As with Ask Gaia's `_askRefs` (`gaia_controller.dart`), the
controller remembers that the pending chat id should be temporary. The first send creates
the chat with `temporaryAt` already set. A marker in the composer shows it before then.
`/new` or switching away forgets it.

### 3.3 Turning it off

`/temp` in a temporary chat, Unarchive from the Archived section, or Undo on the toast clears
`temporaryAt` (and `archivedAt`). It also sets `curatedSeq` to the chat's last seq, so the
curator never reads the temporary part. Only messages after that are read.

Undo on the toast also restores the thrown-out suggestions. The other two ways don't: once
the toast is gone, those suggestions stay gone.

### 3.4 Mid-reply

`/temp` has to be taken by `_submit` before the mid-reply stop, as `/btw`, `/queue` and
`/remember` are. The send button has to send it rather than stop the reply
(GAIA_BTW_HLD.md §3, "Must hold mid-reply"). The reply carries on. A curator run already in
progress for this chat is handled by the host-side check in §5.

## 4. Leaving: the chat lists

The chat is archived from the moment it's made temporary, and every chat list makes one
exception: **the chat in view stays where it would be if it weren't archived**, with a
temporary marker (an hourglass icon, and the title dimmed). Once another chat is in view, the
list puts it in Archived.

So leaving the chat writes nothing. That means there's no "leave" event to define (switching
chats, `/new`, closing Gaia, a crash), and nothing to get wrong when one is missed.

- **Companion sidebar:** `gaiaChatSections` gets an optional `inView` chat id that it sorts
  as unarchived.
- **Recent-chats title menu** (`gaia_app.dart`, `recent`): this already leaves out the
  current chat and archived ones, so nothing changes.
- **Gaia page and phone:** they use their own open chat as `inView`. On a device that
  doesn't have the chat open, it's simply archived.
- **Header:** a "Temporary" chip next to the title while the chat is in view. Clicking it
  turns temporary off, the same as `/temp`.

## 5. The curator

The curator never reads a temporary chat. There are three checks, so a race can't get past
them:

- **`_idle`** returns early for a temporary chat, which skips both `_curate` and the project
  `_summarize` (§7).
- **`_curateMissed`** skips temporary chats at startup.
- **Host `GaiaMemories.curated`** drops what it's given for a chat that's temporary *now*,
  and doesn't mark it read. This catches a curator run that started before `/temp` and
  finished after it. That's what makes "works partway through" hold.

## 6. Throwing out suggestions

`/temp` throws out memories with `sourceChatId == chatId` and `status == proposed`: the
curator's suggestions still waiting in the inbox. They're deleted as Decline in the inbox
deletes them, so they're soft-deleted, can be restored, and go to the trash with that
memory's usual rules. Undo on the toast restores them (§3.1).

What isn't thrown out (§10.1, §10.2):

- **Active memories from the chat**: ones you accepted, `/remember`ed, or that auto-accept
  let straight in. `GaiaMemory` has no field recording where a memory came from, so an
  auto-accepted curator memory can't be told apart from a `/remember`.
- **Memory cards in the chat** (`memory_propose`): you decide those yourself in the chat.

## 7. How it meets the rest of Gaia

| Feature | In a temporary chat |
|---|---|
| Forks, rewind auto-forks | A fork of a temporary chat is temporary. Its copies are the temporary chat's turns. |
| `/btw` | Unchanged. The curator already skips btws. |
| Project summary (`_summarize`) | Not written: the summary is the chat as other chats see it. |
| `project_chats` / `project_search` / `project_read` | Left out of all three, so other chats in the project can't see it (§10.3). |
| `/project`, `/move` | Allowed. The chat stays temporary. |
| Search (Gaia page, companion) | Found, like any archived chat. |
| Titles | Written as usual. |
| Queue, drain, remote prompts | Unchanged. A remote prompt doesn't bring it back to the list (§2). |
| Delete, trash, restore | Unchanged. `temporaryAt` goes with the row. |

## 8. Phases

One phase. In order: the field and migration, the command, the list exception, the curator
checks, throwing out suggestions, the header chip, then the Gaia page and phone lists.

## 9. Testing

- **Unit (models):** `archived` is true for a temporary chat after a later message.
  `gaiaChatSections` with `inView` places a temporary chat normally, and without it puts the
  chat in Archived. A fork inherits `temporaryAt`.
- **Unit (memories):** `curated` for a temporary chat saves nothing and leaves `curatedSeq`
  as it was. Throwing out removes only `proposed` memories from that chat. Undo restores
  them.
- **Controller:** `/temp` cancels the idle timer. Turning it off sets `curatedSeq` to the
  last seq. `/temp` in a new chat creates the chat temporary on its first send. `/temp`
  mid-reply doesn't stop the reply.
- **Live (qa profile):** a chat with an inbox suggestion, then `/temp`: the suggestion is gone
  and the toast shows the count. Switch chats: it's in Archived. A phone prompt to it: it
  stays archived. Wait out `kGaiaCurateAfter`: no new suggestions. `/temp` while a curator
  run is going (shorten `_curateAfter` in qa): nothing lands.

## 10. Decisions (2026-11-24)

1. **Active memories from the chat are left alone.** Only waiting suggestions are thrown
   out (§6). Auto-accepted curator memories stay too, so `GaiaMemory` needs no `origin`
   field. One that shouldn't stay can be archived from the Memories tab.
2. **The agent can still offer memories.** `memory_propose` stays available in a temporary
   chat, since a card saves nothing until the user clicks it. `/remember` works there too.
3. **Other project chats can't read a temporary chat.** `project_chats`, `project_search`
   and `project_read` all leave it out, and `project_read` refuses its id. Like the curator
   check (§5), the check is on the chat as it is when the tool runs.
4. **`/temporary` is an alias of `/temp`**, as `/move` is of `/project` (§3).

## 11. Files likely touched

- `lib/data/database/app_database.dart` (+ migration), `lib/domain/models/gaia_models.dart`
  (`temporaryAt`, `archived`, `gaiaChatSections`, fork copies)
- `lib/data/repositories/drift_repositories.dart`, the Firestore chat mapping
- `lib/features/gaia/host/gaia_host.dart` (`setTemporary`), `gaia_chat_store.dart`,
  `gaia_memories.dart` (`curated` check, throwing out and restoring suggestions)
- `lib/features/gaia/companion/gaia_commands.dart`, `gaia_controller.dart` (command, pending
  new chat, curator checks, `_summarize`), `gaia_app.dart` (sidebar, header chip, composer
  marker, `_submit` mid-reply)
- `lib/features/gaia/page/gaia_page.dart`, the phone chat list
- `lib/features/gaia/host/gaia_project_reads.dart` (leaving temporary chats out, §10.3)
