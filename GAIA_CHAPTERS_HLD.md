# Gaia — Chapters (HLD)

Status: **Designed and built 2026-11-07.** Decided with the user the same day: only the user
marks chapters (no agent tool), the utility model names them, chapters show three ways (a
divider, a chapter rail and the pinned prompt bar), and they travel with forks and rewinds.
Changed after the first build, at the user's request: the header's chapters button became
the chapter rail in the chat's top left (§6.3), after Claude desktop's.

## 1. Summary

"Pin as chapter" marks a message as the start of a section of a long chat, so the chat can be
read and navigated by section. It works like Claude desktop's "Pin as chapter", without its
agent tool.

- **Right-click a message, "Pin as chapter".** The chapter appears at once under the
  message's first line. A moment later the utility model gives it a short title (§4).
- **Chapters show three ways** (§6): a titled divider above the message, a chapter rail in
  the chat's top left, and the current chapter's title in the pinned prompt bar.
- **A chapter is a field on its message** (§3). Forks, rewinds, take-back and erasing all
  move or drop chapters along with their messages, with nothing extra to do (§5).
- **The agent never sees chapters.** They aren't in the agent's prompt or a handoff
  transcript, and the curator doesn't read them.

## 2. What Claude desktop does, and what Gaia keeps

In Claude desktop, a right-click on a message offers "Pin as chapter" and asks for a title.
The session also has an agent tool, `mark_chapter`, so the model can mark chapters itself.
Pinned chapters are meant to be listed for jumping between sections. Public bug reports say
that list hasn't been reliably visible
([#57628](https://github.com/anthropics/claude-code/issues/57628)), so this design doesn't
copy its look. It takes the idea: named marks on messages, used to move around.

| Claude desktop | Gaia |
|---|---|
| Right-click, "Pin as chapter" | Same |
| Title typed in a dialog | First line at once, then the utility model's title (decided). Renamed from the chapter's menu |
| `mark_chapter` agent tool | **Left out** (decided). Only the user marks chapters |
| A chapter index | A chapter rail, a divider and the pinned prompt bar (§6) |

## 3. Data

**`GaiaMessage.chapter`: `String?`.** The chapter's title, or null for no chapter. An empty
title is never stored. Clearing the field is "Unpin chapter".

Why on the message rather than a list on the chat:

- **It travels with its message.** `_copiesInto` copies a message through
  `toJson`/`fromJson`, so a fork's copies and a rewind's auto-fork carry their chapters with
  no new code (§5). A list on the chat would have to be split and remapped at every fork,
  rewind and late-reply move.
- **The chat record is the busy one.** Each turn rewrites `lastMessageAt`, `agentSessions` and
  `curatedSeq`, and the chat merges by version. A chapter list there could lose a pin to any
  concurrent turn on another device. A message is rarely written once it's done.
- **Erase and take-back already drop the message**, so its chapter goes too.

**Storage and sync:**
- A nullable `chapter` column on `GaiaMessagesTable`, with a migration (schema 189 to 190),
  and the Drift repository's mapping.
- `chapter` in `toJson`/`fromJson`, `copyWith` (with `clearChapter`), and
  `gaiaMessageToFirestore`.
- **Merging:** `mergeGaiaMessageFromRemote` takes the remote's `chapter` when the payload
  has the key, null included, and keeps the local one when it doesn't. That's the rule
  `tier` follows on the chat. A message written by a build from before chapters doesn't
  unpin anything, and an unpin still syncs as an explicit null.
- **To check while building:** that erasing a message (`isErasedPayload`, the take-back
  erase) blanks `chapter` along with its parts. A title is content.

### 3.1 One writer: `setChapter`

The companion writes whole messages (`GaiaChatStore.putMessage`), and its copy of a message
can be older than what's stored. Task ticks have the same problem: `putMessage` keeps the
stored ticks, and only `toggleCheck` changes them. Chapters follow that rule:

- **`putMessage` keeps the stored `chapter`**, whatever the companion's copy says.
- **A new store write, `setChapter(messageId, chapter, {from})`**, over a new pipe request,
  is the only thing that changes it. It's serial, like every store write. It writes nothing
  if the message is gone or deleted, or if `from` is given and the stored chapter isn't
  `from`. That's the compare-and-set `setTitle` uses, so the utility model's title never
  overwrites a rename (§4).
- **`GaiaController.setChapter(message, chapter)`** updates the controller's list at once,
  then sends the request, as `renameChat` does.

## 4. Naming a chapter

The utility model names the chapter, the way a chat's first exchange titles the chat
(`_retitle`):

1. **At once:** the chapter is set to the message's first line, through `_pinnedLabel`'s
   rules (the text the pinned prompt bar shows), cut to 60 characters. The divider and the
   menus show it straight away.
2. **Then:** `GaiaUtility.chapterTitle(message, partner)` asks for a title of at most five
   words for the part of the conversation that starts here. The input is the pinned message
   and the other half of its turn, each cut to 2,000 characters as `title` cuts them:
   - at a prompt, its reply, if that reply has finished;
   - at a reply, its prompt.
   
   A prompt whose reply is still streaming is named from the prompt alone. The answer goes
   through `cleanTitle`.
3. **Written with `from` = the first-line title.** If the chapter was renamed or unpinned
   meanwhile, the stored chapter isn't `from` and nothing is written.

**With no utility model** (it fails, times out after 15 s, or there's no Claude account),
the first-line title stays. A message with no text (only images or files) is titled
"Chapter" at step 1.

**Renaming:** "Rename chapter" in the divider's and the message's menus edits the title in
place in the divider, as the sidebar renames a chat (`_startRename`/`_endRename`). Enter or
leaving the field keeps it, and Esc cancels. An empty title cancels; it doesn't unpin.

**Cost:** one utility call per pin, on the same Haiku runner as chat titles.

## 5. Chapters and the rest of Gaia

| Event | What happens to chapters |
|---|---|
| Fork at M | The copies up to M keep their chapters (`_copiesInto`) |
| Rewind at K | The chat keeps the chapters up to K. The auto-fork's copies keep all of them, the dropped range's included |
| A late reply moved into an auto-fork (GAIA_REWIND_HLD.md §5.1) | None to move: a streaming reply can't be pinned (§6.1) |
| Take-back, erase, delete forever | Gone with the message |
| Edit & resend | The chapter stays on the original message. The resent one has none |
| Delete chat, restore | Chapters come back with the messages |
| Handoff transcript, the agent's prompt, the curator | Never included |
| Utility title pending while the chat is forked | The fork copies the first-line title and keeps it. The utility model's title goes only to the original message. Rename it in the fork if wanted |

## 6. UI

Only in the companion, as forking and rewinding are. The Gaia page and the phone sync
chapters and keep them (§3), but don't show them in this design.

### 6.1 Menu items

In the message's right-click menu (`_MessageView._menu`), after "Rewind to here":

- **"Pin as chapter"** (`Icons.bookmark_add_outlined`) on a message with no chapter, unless
  it's a reply still streaming. Its text can still change, and another device streaming it
  would overwrite the field.
- **"Rename chapter"** (`Icons.edit_outlined`) and **"Unpin chapter"**
  (`Icons.bookmark_remove_outlined`) on a message with one.

Unpinning has no confirm dialog and no undo toast. Pinning again is one click, and the
utility model names it again.

### 6.2 The divider

A titled divider above a pinned message, in the look of `_VendorDivider`, but with the
chapter title in the accent colour and a bookmark glyph. If the message also has a vendor
divider, the chapter divider goes above it, since it heads the section.

- It's part of the message's `_Placed` column, so `_reveal(id)` brings the divider into view
  along with the message's top.
- Right-click: "Rename chapter", "Unpin chapter".

### 6.3 The chapter rail

As in Claude desktop: faint horizontal lines down the chat's top left (`_ChapterRail`), shown
only when the open chat has at least one chapter, in the main window and the floaters. One
line per chapter in seq order, led by one for "Start of chat" while no chapter heads it.

- **The current chapter** (§6.4) has the longer line, in the accent. Scrolling into another
  chapter eases the old line short and the new one long.
- **Hovered,** the lines open into a list of the titles, each row with its dash and the
  current one highlighted. Clicking a row glides there with `_reveal(id)`; leaving closes it.
- It lives in `_Messages`' stack, so it reaches `_reveal` directly. The pinned bar keeps clear
  of it where the gutter is narrower than the rail.

### 6.4 The pinned prompt bar

`GaiaPinnedPrompt` shows the first line of the turn's prompt once that prompt has scrolled off
above. It gains the **current chapter**: the last chapter whose message's seq is at or
before the message across the list's top. `_cutOff` already finds that message. Scrolled
to the very bottom, it's the last chapter whose divider is on screen instead, so one too
near the end to reach the top still gets marked.

- **The bar shows** when the prompt or the current chapter's divider has scrolled off above.
- **The layout:** the chapter title first, in the accent colour, then " · " and the prompt's
  line. Either half can be absent. Each half is its own tap target and glides to its own
  message.
- **Crossfade:** as for prompts, only the text crossfades from one chapter to the next. The
  box stays.

## 7. Conflicts and limits

- **"Pinned" means three things now:** a pinned chat in the sidebar, the pinned prompt bar,
  and "Pin as chapter". The menu keeps Claude desktop's words. The code says `chapter`
  throughout and never `pin`, so `pinned` stays the chat's field and `_pinned` the bar's.
- **Concurrent writes of one message on two devices.** A message merges by version, so a
  chapter set on one device at the same moment another answers a card in that message, or
  ticks a task, can lose to it. Ticks have the same exposure today. It's accepted, since a
  done message is rarely written.
- **The utility title doesn't reach a fork made while it was pending** (§5).
- **No keyboard navigation between chapters.** Not proposed. See §10.

## 8. Phases

One phase.

**Work:**
- **Model and sync** (§3): the field, column, migration, Firestore field and merge.
  `putMessage` keeps the stored chapter. Add `setChapter` to the store, the pipe and the
  controller.
- **Naming** (§4): `GaiaUtility.chapterTitle`, the first-line title, and the compare-and-set
  write.
- **UI** (§6): the menu items, the divider and its rename, the chapter rail, and the bar.

**Done when:**
- **Pinning.** "Pin as chapter" on a prompt and on a reply shows the divider with the first
  line at once, and the utility model's title within seconds. With the utility model failing
  (no Claude account), the first line stays.
- **Rename and unpin.** A rename made before the utility title lands is kept. Unpin removes
  the divider, the menu row and the bar's title.
- **Navigation.** In a chat of 30 or more turns with three chapters, the rail lists
  them in order with the current one marked, and each row glides to its chapter, including
  one far above that isn't built yet. The bar shows the current chapter while scrolling, and
  both of its halves go where they say.
- **Not offered** on a streaming reply.
- **Forks and rewinds.** A fork after two chapters has both. A rewind between them keeps the
  first in the chat. The auto-fork has both.
- **Second device.** A chapter pinned, renamed and unpinned on one device shows each change on
  the other after sync. A reply finishing on device B doesn't drop a chapter pinned on A on
  its prompt.
- **Stale companion copy.** A whole-message write from the companion (answering a card in a
  pinned reply) keeps the chapter.
- **The agent** doesn't know chapter titles: ask it "what chapters does this chat have?"
  after pinning one.
- The Gaia tests, forking and rewinding included, pass.

**Tests:**
- `test/gaia_controller_test.dart`, a "chapters" group: pin, rename and unpin. The utility
  title is written over the first line, and not over a rename or an unpin. A fork and a rewind
  carry chapters. What's offered.
- `test/gaia_migration_test.dart`: the new column.
- The sync mapper tests: a payload with `chapter`, with an explicit null, and without the key.
- The chat store: `putMessage` keeps the stored chapter, and `setChapter` honours `from`.

## 9. Files likely touched

- `lib/domain/models/gaia_models.dart`: `GaiaMessage.chapter`.
- `lib/data/database/app_database.dart`, `lib/data/repositories/drift_repositories.dart`:
  the column, the migration and the mapping.
- `lib/core/sync/firestore_document_mapper.dart`: the field and its merge.
- `lib/features/gaia/host/gaia_chat_store.dart`, `lib/features/gaia/host/gaia_host.dart`:
  `setChapter`, its pipe request, and `putMessage` keeping the field.
- `lib/features/gaia/utility/gaia_utility.dart`: `chapterTitle`.
- `lib/features/gaia/companion/gaia_controller.dart`: `setChapter`, `pinChapter` (the first
  line, then the utility title).
- `lib/features/gaia/companion/gaia_app.dart`: the menu items, the divider, the chapter rail,
  and the bar's current chapter.
- `lib/features/gaia/companion/gaia_pinned_prompt.dart`: the chapter half of the bar.

## 10. Open questions

- **Chapters on the Gaia page and the phone:** synced but not shown, as fork and rewind are
  left out there.
- **A keyboard shortcut** for the next or previous chapter: none proposed. If wanted, it
  belongs in `gaia_keybinds.dart` and must stay clear of the composer's Vim keys.
- **Chapters in the sidebar**, under the chat as forks are: not chosen. The chapter rail covers
  navigation inside an open chat.
