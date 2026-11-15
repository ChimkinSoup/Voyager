# Gaia — Composer History (HLD)

Status: **Design (2026-11-14), not built.** Desktop companion composer only.

## 1. Summary

Up arrow in an empty composer brings back what you sent before, newest first, as a
terminal does. Down goes the other way, and Down past the newest entry gives the empty
draft back.

- **One history for every chat**, kept on this desktop only and never synced (§2).
- **Everything you send counts**: messages, slash commands, `/btw`, `/queue`,
  `/remember`, card answers (§3).
- **Capped at 100.** Back-to-back repeats are kept once (§3).
- **Starts only from an empty draft.** There's no prefix search (§4.1).
- **Arrow keys only**, in Vim's Insert and Normal alike. `k`/`j` aren't used (§4.4).
- **Edits to a recalled entry are scratch.** Stepping away discards them, and the history
  itself never changes (§4.3).
- **Not while the `/btw` side questions are open.** Up/Down stay theirs (§4.4).

## 2. Where it lives

`GaiaCommandHistory`, in `lib/features/gaia/companion/gaia_command_history.dart`. It's
built like `GaiaCommandUses`: a JSON file beside Gaia's other files, loaded at companion
start in `gaia_companion_main.dart`, and handed to `GaiaController`. Null file in tests.

File: `<root>/gaia/history.json`, so each dev profile (qa, qac, gaiaqa) has its own.

```json
[
  {"text": "fix the floater resize", "at": "2026-11-14T15:02:11.000Z"},
  {"text": "/new", "at": "2026-11-14T15:03:40.000Z"}
]
```

- **Oldest first**, so appending is cheap and the file reads in order.
- **`text`** is exactly what was recorded (§3), multi-line included.
- **`at`** isn't needed for Up/Down. It's there for a later Ctrl+R search (§7): showing
  when an entry was sent, and ranking matches by recency.
- Writes are chained (`_saved.then(_save)`) as in `GaiaCommandUses`, so an older write
  never lands after a newer one. An unreadable file logs and starts empty.

API:

| Member | |
|---|---|
| `entries` | `List<GaiaHistoryEntry>`, oldest first |
| `load()` | reads the file |
| `add(String text)` | skips text that's blank after trimming, or equal to the newest entry; appends, drops the oldest past 100, saves |

## 3. What's recorded, and when

**The draft as it stood when you pressed Enter**, recorded once the send succeeds.

- **As typed, not as sent.** Inline commands are taken out of the draft before it goes
  (`fix this /deep` sends `fix this`), but history keeps `fix this /deep`. Recalling it
  does the same thing again, as a terminal re-runs a command line.
- **Only sends that happen.** Nothing is recorded when a send is turned away: an unknown
  `/word` held once, a command held while the CLI's commands are read, a declined tier or
  account switch, `/stash` refused while images sync, `readyToSend()` false.
- **Enter mid-reply is the stop button.** It doesn't record anything, and the draft
  stays to be sent later.
- **Palette picks** record the row's command, `/<name>`, for rows that run or send on the
  pick (built-ins, tiers, accounts, standalone and argument-less native commands). A row
  that only fills the draft (`/remember `, a command waiting for arguments) is recorded
  when that draft is sent.
- **Card answers** typed in the composer (question answers, permission rejections with a
  message) are recorded when the card takes them.
- **Images and files aren't kept.** A send with only attachments and no text records
  nothing.
- **Only back-to-back duplicates collapse.** `a, b, a` keeps all three. `a, a` keeps one.

In code: `_send` captures `_text.text` before anything changes it, and a small
`_record(text)` is called at each success point in `_submit` (built-in, `/remember`,
`/queue`, `/btw`, `/stash`, card, the final `controller.send`) and in `_pick`.

## 4. Navigating

### 4.1 Starting

**Up**, with the draft's text empty and nothing above claiming the key (§4.4), puts the
newest entry in the draft with the caret at its end. That starts a **browse**.

- "Empty" is the text only. Attached images and files stay where they are.
- **Down** with an empty draft does nothing.
- A draft you typed yourself never starts a browse, so Up/Down in it behave as they do
  today.

### 4.2 Stepping

A browse is state in `_ComposerState`, not the controller:

| Field | |
|---|---|
| `_browseAt` | the index of the entry in view |
| `_browseText` | the exact text that was put in the draft |
| `_browseChat` | `controller.currentChatId` when the browse started |

An entry is **untouched** while `_text.text == _browseText`, and **edited** otherwise.
Comparing text means anything that changes the draft counts as an edit, whether you typed
it or Gaia did.

| Key | Untouched entry | Edited entry |
|---|---|---|
| Up | one entry older, wherever the caret is | one entry older **if the caret is on the first visual line**; otherwise the caret moves up |
| Down | one entry newer; past the newest, the empty draft and the browse ends | one entry newer **if the caret is on the last visual line**; otherwise the caret moves down |

Up at the oldest entry does nothing.

**The edge rule is the way out of an edited multi-line entry.** Moving the caret to the
top line and pressing Up again steps to the next entry; pressing Down on the bottom line
steps back. This is how zsh and Claude Code behave. "Visual line" counts wrapped lines,
measured from caret rects as `_draftRunsOver` already does.

**An untouched entry steps whatever its size**, so a long recalled message doesn't make
you move the caret through every line before reaching the next entry.

### 4.3 Edits are scratch

Stepping away from an edited entry discards the edit. The next entry comes in as it was
recorded, and stepping back to the edited one shows it as recorded too. The history file
only changes through `add` (§3).

### 4.4 Who gets Up/Down first

In `_paletteKey` / `_listKey`, in this order:

1. **The browse, while the entry is untouched.** A recalled `/new` would otherwise open
   the palette, and the next Up would move its highlight instead of stepping. So
   recalling sets `_paletteClosedFor` to the entry's text: the palette stays shut for it,
   and Enter sends it as typed, the way a terminal re-runs a line. Editing the entry
   changes the draft, so the palette comes back as it always does.
2. **The `/` palette**, as today.
3. **The `/btw` side questions.** While they're open, history is unreachable: no browse
   starts, and an ongoing one stops stepping. This check is on the dock being open, not
   on `dock.move` returning false at the end of its list.
4. **Caret movement** in a draft that runs over lines, as today.
5. **History**: the start rule (§4.1) and the edge rule (§4.2).

No modifiers: Shift/Ctrl/Alt/Meta+arrow keep their usual meaning. The composer's focus
node sees keys before Vim does, so arrow keys browse in Normal mode too. `k`/`j` are
Vim's own.

### 4.5 Ending a browse

A browse ends, with `_browse*` cleared, when:

- the draft is sent, whether or not it was edited;
- the draft's text becomes empty, by Down past the newest, select-all and delete, or
  undo. The next Up starts from the newest again;
- the chat in view changes (`currentChatId != _browseChat`). Whatever was recalled stays
  as that chat's draft, as any typed draft would.

Esc does nothing for history: Vim needs it, and so do the dock and the palette.

## 5. Known limits

- **A recalled entry is the chat's draft**, so it's saved and synced like typed text.
  Rapid Up presses each change the draft. Check that the draft save path coalesces;
  if it doesn't, debounce the recall writes.
- **An edited single-line entry has only one line**, so any Up or Down steps away and
  discards the edit. This follows from §4.3 and is the same in zsh.
- **Gaia refilling the draft mid-browse** (a returned queue item appended, a failed send
  restored) counts as an edit, and stepping away discards that text too. It's rare,
  because those refills mostly fire on an empty draft.
- **Undo** treats each recall as a draft change. Ctrl+Z walks back through recalled
  entries, and reaching empty ends the browse (§4.5). Not special-cased.
- **Plain-text file.** Secrets pasted into a message stay in `history.json` until 100
  later sends push them out. Accepted: they've already gone to the agent.

## 6. Testing

- **`test/gaia_command_history_test.dart`** (unit tests): the cap at 100, back-to-back
  dedup and non-adjacent keep, blank skipped, load/save round trip, unreadable file starts
  empty, writes stay in order.
- **Composer widget tests** (beside `gaia_composer_text_test.dart`):
  - Up from empty recalls newest, caret at end; Down past newest empties.
  - An untouched multi-line entry steps on Up/Down from any caret line.
  - An edited multi-line entry moves the caret until the top/bottom visual line, then
    steps. Wrapped lines count.
  - Edits are discarded on stepping away and back.
  - Recalled `/new`: the palette doesn't open, and Enter sends it.
  - btw dock open: Up/Down never browse.
  - Typed (non-recalled) draft: no browse.
  - A turned-away send records nothing. A palette pick that runs records `/<name>`.
    `fix this /deep` records as typed.
  - A chat switch ends the browse.
- **Live in qa** (voy.ps1 bg mode): send a few, including a multi-line one, then Up
  through them, edit, step off the edge, and check the btw dock blocks it.

## 7. Later: Ctrl+R

Not built now. The shape in §2 is enough: a substring scan over 100 entries, newest
first, with `at` for display. Nothing needs indexing.

## 8. Files likely touched

| File | Change |
|---|---|
| `lib/features/gaia/companion/gaia_command_history.dart` | new: `GaiaCommandHistory`, `GaiaHistoryEntry` |
| `lib/features/gaia/companion/gaia_companion_main.dart` | load `gaia/history.json`, pass it in |
| `lib/features/gaia/companion/gaia_controller.dart` | `history` constructor param and field, as `commandUses` |
| `lib/features/gaia/companion/gaia_app.dart` | `_ComposerState`: capture at `_send`, `_record` at success points, browse state, key handling in `_paletteKey`/`_listKey` |
| `test/gaia_command_history_test.dart` | new |
| composer widget test file | new cases (§6) |
