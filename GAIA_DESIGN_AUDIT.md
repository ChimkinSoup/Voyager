# Gaia design audit

Branch `gaia-design-audit`, 2026-11-15. One commit per group below, in this order (`0bf7e64d` to `45bc3ffc`), so a group can be reviewed or reverted on its own. Each commit analyzes clean on its own.

## Direction

Gaia keeps its own identity: a dark, quiet surface, with the user's accent as the only hue that isn't a status. The audit found the look itself was sound, and that what made it feel unfinished was inconsistency at the edges. The same greys, radii and durations were redefined file by file and had started to drift. Content was cut through the middle of a line wherever it met a panel's edge. Icon-only buttons had no names. A new chat was an empty field of stars.

So the work is three things:

1. **One source for style.** `gaia_style.dart` holds the ink ramp (bright, dim, muted, faint), radii, timings and chrome type. The chrome files now read from it.
2. **Edges fade, they don't cut.** The chat under the header, the pinned prompt and the composer, the `/` palette and the search results all fade out where they carry on.
3. **Everything says what it is.** Tooltips on icon buttons, keyboard focus on Gaia's buttons, a first line for an empty chat, and section headings that read as headings instead of links.

Gaia's companion is dark only, so "both themes" applies to the in-app Gaia page, which follows Voyager's theme. No shared Voyager theme file or token was edited.

## How this was checked

- `flutter analyze lib/features/gaia`: two issues, both in code this branch doesn't touch and both there before it (`gaia_controller.dart:5127` `prefer_if_null_operators`, `gaia_beacon_service.dart:436` `unawaited_return_in_try_block`). Nothing new.
- `flutter test test/gaia_*.dart`: 1,689 passed, 23 skipped (the skips predate this branch). One test file added, none changed.
- Live, in Gaia's standalone dev mode on a throwaway `gaiadev` profile, with scripted replies in dummy mode (no model calls), and in the `gaiaqa` profile for the in-app page.
- Background input can't hover, so **hover-only and focus-only states were not seen live**. Each entry says "Seen live" or "Not seen live".
- The states not seen live were then checked in throwaway widget tests that pump the real `GaiaApp` with real fonts: real hover and Tab/Enter input, assertions on the result, and rendered images inspected by eye. Entries say "Checked in a widget test". Glows and soft shadows don't render in test images, so those were not judged.

---

## Part 1: Changelog, in testing order

### 1. Foundations (shared by every group after it)

**1.1 Shared style tokens**
- **What:** New `gaia_style.dart`: `GaiaInk` (bright / dim / muted / faint, hairline, hover and selected fills), `GaiaRadius` (chip 6, row 8, panel 12), `GaiaMotion` (quick 150 ms, move 250 ms, two curves), `GaiaType` (row 13, label 12, heading 11) and `gaiaFloating()`, the look of what floats over the chat. The notch, menu and side-question files had their own copies of the same greys, sizes and the 150 ms fade; those constants now point at the tokens.
- **Why:** One place to change a grey or a timing. The values are the ones already in use, so nothing moves visually.
- **Where:** `lib/features/gaia/companion/gaia_style.dart`; `gaia_notch.dart:126`, `:137`, `:148`; `gaia_btw.dart:16`.
- **Test:** No visible change. Open the notch menus, the `/` palette and a side question (`/btw`) and confirm they look as before.

**1.2 Gaia's buttons take keyboard focus**
- **What:** `GaiaButton` could only be clicked. It is now reachable with Tab and pressed with Enter or Space, lit as on hover while focused. A round (icon-only) button presses in to 0.94 instead of 0.98, which was too small to see at that size. It also takes an optional `tooltip`.
- **Why:** Keyboard reach, and press feedback you can actually see.
- **Where:** `gaia_button.dart:47` (tooltip), `:174` (focus), `:188` (press scale).
- **Test:** In the Gaia window, Tab from the composer until a header button's ring lights, then press Enter. Click and hold a round header button to see the press. **Not seen live. Checked in a widget test:** Tab reaches the header buttons (Search, then the sidebar toggle), Enter and then Space press the toggle, and the focused button's ring turns accent. The press scale was not checked.

**1.3 A quiet icon button**
- **What:** `GaiaActionIcon` (the icons under a hovered message) gains a `compact` 24 px size and an edge when focused by keyboard, and uses the ink tokens.
- **Why:** It is reused in the sidebar (group 3), where a glowing ring on every row was noise.
- **Where:** `gaia_action_icon.dart:21`, `:70`.
- **Test:** Hover a message: its action icons look as before.

**1.4 Edge-fade widget**
- **What:** New `GaiaScrollFade`: a list's top and bottom edges fade out while there is more past them.
- **Why:** Used by the palette (group 5) and search (group 6).
- **Where:** `lib/features/gaia/companion/gaia_scroll_fade.dart`.

### 2. Header and window chrome

**2.1 Header is opaque**
- **What:** Stars drifted behind the title bar, so one could sit in the title like a stray full stop. The header now has the surface colour, as the sidebar does.
- **Where:** `gaia_app.dart:678`. **Seen live.**
- **Test:** Gaia window, any chat. Watch the title row for a minute: no stars cross it.

**2.2 Tooltips on every header and window button**
- **What:** Sidebar toggle ("Show sidebar" / "Hide sidebar"), new chat ("New chat (Ctrl+N)", plus the Shift+click hint), "Open in the Gaia window", Close ("Close (Esc)" in a floater), Minimize, Maximize / Restore / Leave full screen.
- **Why:** They were icons with no names; the Shift+click behaviour of New chat was undiscoverable.
- **Where:** `gaia_app.dart:637`, `:688`, `:772`, `:781`, `:1092`.
- **Test:** Hover each for about half a second. **Not seen live. Checked in a widget test:** all six tooltips (sidebar toggle, Search, New chat, Close, Minimize, Maximize) fade in on hover.

**2.3 CLI warning chip**
- **What:** The "not found" warning in the header was a default Material `Chip`, the only one in Gaia. It is now a rose label with a warning icon, in the shape of Gaia's other chips.
- **Where:** `gaia_app.dart:742`.
- **Test:** Needs a missing CLI (rename `claude` off the PATH in a QA profile, restart Gaia). **Not seen live. Checked in a widget test** with no CLI found: a rose "Claude Code not found" label in the header.

### 3. Sidebar and chat list

**3.1 Rows use Gaia's typeface**
- **What:** Chat and project rows were drawn in the system's proportional font, because their animated text style didn't inherit the theme's. They now use the same typeface as the rest of Gaia.
- **Why:** Two typefaces side by side in one window. **This is the most visible change in the branch**: titles are slightly wider, so a few more of them truncate.
- **Where:** `gaia_app.dart:1981`. **Seen live.**
- **Test:** Open the Gaia window with the sidebar showing and compare row text with the header title.

**3.2 Section headings read as headings**
- **What:** "Projects", "Pinned", "Chats" were accent-coloured 12 px text, which looked clickable. Now 11 px, spaced, in the faint ink. The search panel's headings use the same style.
- **Where:** `gaia_app.dart:2038`, `gaia_style.dart:81`. **Seen live.**

**3.3 Project actions appear on hover**
- **What:** Every project row carried a ringed "+" button, so the sidebar had a column of glowing circles. The "+" is now a quiet icon that shows only on the row under the cursor (or when tabbed to). Its space is always kept, so titles don't shift. The Projects heading's "+" is the same quiet icon. Both have tooltips ("New chat in <project>", "New project").
- **Where:** `gaia_app.dart:1603`, `:1834`, `:1912`. Resting state **seen live**; the hover reveal **not seen live. Checked in a widget test:** hidden at rest, shown on hover, its tooltip shows, and a click starts a new chat in that project.
- **Test:** Hover a project row: a "+" fades in at its right. Click it: a new chat opens in that project.

**3.4 Tooltips**
- **What:** Search ("Search chats (Ctrl+F)") and the New chat button.
- **Where:** `gaia_app.dart:1793`. **Not seen live. Checked in a widget test** (with 2.2).

### 4. Chat body

**4.1 Content fades under the header and pinned prompt**
- **What:** Scrolled text was sliced through mid-line at the header's edge, and showed through around the pinned prompt. A 16 px fade now sits at the top, with a solid band behind the pinned prompt while it shows.
- **Why:** A gradient over the list, not a mask on it, so scrolling doesn't recomposite the chat.
- **Where:** `gaia_app.dart:3019` (`_TopFade`). **Seen live** (small floater, long reply, scrolled up).
- **Test:** Send a long reply, scroll up a little, and look at the top edge and behind the pinned prompt.

**4.2 Content fades into the composer**
- **What:** The same at the foot: the last visible line was cut hard at the composer's top edge.
- **Where:** `gaia_app.dart:2877`. **Seen live.**
- **Test:** As 4.1, looking at the line just above the composer.

**4.3 An empty chat says something**
- **What:** A new chat was only stars. It now shows "What can I help with?" and three key hints: `/` commands, `Ctrl+V` paste an image, and the send key (read from your keybind, `Ctrl+Enter` by default). Hidden when the chat area is under 200 px tall. It ignores the pointer.
- **Why:** The send key isn't Enter, which a new user can't guess; the palette and image paste are Gaia's two fastest paths.
- **Where:** `gaia_app.dart:2902`, `:3071` (`_EmptyChat`). **Seen live** in the window and the small floater.
- **Test:** Ctrl+N. Then rebind Send in the Gaia page's Settings and check the hint follows.

**4.4 Jump-to-latest button and chapter list match the menus**
- **What:** The round "to bottom" button was a Material elevation in the pinned prompt's blue-grey; the chapter list was a default Material surface. Both now use `gaiaFloating()`: the dark panel, hairline edge and soft shadow of Gaia's menus. The button has a tooltip ("Jump to latest").
- **Where:** `gaia_app.dart:3134`, `:3581`. Button **seen live**; chapter list **not seen live. Checked in a widget test:** hovering the rail opens the list on the floating panel, with the current chapter lit.
- **Test:** Scroll up in a long chat for the button. For the list, use a chat with chapters and hover the rail at the left.

### 5. Composer: the `/` palette

**5.1 Arrow keys scroll the palette**
- **What:** A real bug. With more commands than fit (about 7), Down moved the highlight off the bottom of the panel and the list stayed put, so you were choosing blind. The highlighted row now scrolls into view, clear of the edge fade.
- **Where:** `gaia_menu.dart:310`. **Seen live** (8 × Down, then 7 × Up).
- **Test:** Type `/` in an empty composer and hold Down past the last visible row, then Up back to the top.

**5.2 The palette's edges fade**
- **What:** The last row was cut through its text at the panel's edge. The edge now fades while there are more rows that way.
- **Where:** `gaia_menu.dart:358`. **Seen live.**

### 6. Search

**6.1 Results fade at the edge; headings match the sidebar**
- **What:** The same clipped last row as the palette, fixed the same way. "Chats" / "Messages" headings use the shared heading style (were 11 px semibold with tighter spacing).
- **Where:** `gaia_search.dart:320`, `:425`. Headings **seen live**; the fade needs more results than fit, which the test data didn't have, so **not seen live. Checked in a widget test** with 32 chats: the bottom edge fades at rest, both edges after scrolling.
- **Test:** Ctrl+F, type a common word with 15+ matches, look at the bottom edge, scroll.

### 7. Toasts

**7.1 "Gaia is done" shows plain text**
- **What:** The toast showed the reply's first line as raw markdown, for example `**Short command** (Bash):`. Heading, quote and list markers, emphasis and code marks are now removed and a link shows as its text. The Windows toast gets the same line.
- **Where:** `gaia_controller.dart:7009`, `:7478` (`gaiaPlainLine`); `test/gaia_plain_line_test.dart`.
- **Test:** Start a reply that opens with bold text, switch to another chat, wait for the toast. **Not seen live** (an in-app toast needs the window in the foreground, which the background harness doesn't have). Covered by the new unit test, and checked through the controller: `/msg1`'s reply, which opens with `# A heading`, toasts as "/msg1: A heading".

### 8. In-app Gaia page and usage bars

**8.1 The page keeps to a column**
- **What:** On a wide window every row stretched edge to edge, so a chat's pin / move / delete icons were a full screen away from its title, and "Open Gaia" sat in the far corner. Content now keeps to 1,200 px at the left; the whole width still scrolls the list. Narrower windows and Android are unchanged.
- **Where:** `gaia_page.dart:67`, `:164`. **Seen live** (dark; 1,200 was chosen because 960 and 1,100 pushed the Settings tab off the row).
- **Test:** Maximise Voyager, open Gaia in the nav rail, check each tab.

**8.2 Usage bar is visible on the light theme**
- **What:** The bar's track was white at 15%, invisible on light paper, so a 36% bar looked like a short stray line. The track now uses the text colour at 15%.
- **Where:** `gaia_usage_bar.dart:67`. **Seen live** in light and dark.
- **Test:** Light theme → Gaia → Setup → the 5-hour and Weekly bars under an account. Also the usage ring's tooltip in the companion.

### Outside the UI layer, and things that could surprise you

- **`gaia_controller.dart`:** one line changed in `_reportDone` and one pure function added (`gaiaPlainLine`), for 7.1. Nothing else outside widgets.
- **Sidebar typeface (3.1)** changes how every row looks. If the proportional font was deliberate, revert the sidebar commit's `_ChatTile` style hunk.
- **Project "+" (3.3)** is no longer visible at rest.
- **Formatting noise:** `dart format` on the touched files reflowed one unrelated expression in `gaia_app.dart` (`_ComposerState`, a `TextPosition(...)`), and re-indented the body of `GaiaPage.build` because it is now inside a `LayoutBuilder`. The `gaia_page.dart` diff is mostly indentation; view it with whitespace ignored.
- **Recent UX choices** (scroll restore, reordering, caret fade, stash, zoom, image editing) are untouched.
- **Profiles:** the standalone runs used a dev profile, `%APPDATA%\Voyager\voyager-profile-gaiadev`, which has been moved to the Recycle Bin. Its error log held four errors, all caused by the session's own VM evals: three "Build scheduled during frame" errors, where an eval called `newChat()` while the app was mid-layout (the eval frame sits on top of `performLayout` in each stack), and one null check inside an eval closure. None comes from the branch's code. The `gaiaqa` profile was switched to the light theme for one screenshot and put back to dark.

---

## Part 2: Suggested, not done

| # | Suggestion | Why | Size |
|---|---|---|---|
| 1 | Search snippets show raw markdown (`**bold**`, `# heading`, code fences) | Same problem as the toast, but the match highlighting depends on offsets into the raw text, so it needs the index or the highlighter to work on plain text | M |
| 2 | Finish the token migration | About 13 hard-coded 150 ms durations, and dozens of literal radii and white-alpha fills remain across the cards, text field, tier picker, toast and pinned prompt. Mechanical, but it touches every surface and should be reviewed with screenshots per file | M |
| 3 | The palette remembers Esc too well | After Esc on `/`, typing `/` again shows nothing until Esc is pressed on different text. It reads as the palette being broken. Suggest forgetting it when the draft is emptied. Behaviour change, so your call | S |
| 4 | In-app page rows | Dense `ListTile`s with three always-visible icons per chat. Hover-revealed actions and a single overflow menu would calm the list, as in the sidebar | M |
| 5 | In-app tab row on narrow windows | It scrolls sideways with no sign that it does. A fade at the edge, or icon-only tabs below a width | S |
| 6 | An error reply has no action | The rose "Error: …" line ends the turn with nothing to click. A "Retry" beside it would save retyping. Needs a controller entry point | M |
| 7 | A light theme for the companion | Its colours assume a dark surface throughout. Worth doing only if you want it; it would start by turning `GaiaInk` into a theme extension | L |
| 8 | Empty chat could offer more | Recent chats, or the two or three commands you use most (the recency data exists). Subjective; the current one is deliberately minimal | S–M |
| 9 | Tool chips' yellow | "Used Bash" in yellow is the loudest thing in a finished reply although it is the least important. A muted ink with the icon keeping the colour would rank it properly. Subjective | S |
| 10 | Tooltip timing and look | Gaia uses Voyager's tooltip theme. Its own (darker, hairline edge, about 400 ms wait) would match the menus. Needs a Gaia-side theme override, not a shared-file edit | S |

---

## Part 3: Bigger ideas

1. **Guard `--gaia-dev`.** Started without `VOYAGER_PROFILE`, it runs against the real Gaia folder with an empty in-memory database, and its startup prune then deletes every stored tool result and the drafts folder. That is how the earlier session lost yours. It should refuse to start without a dev profile, or use a temp root. Small, and it protects real data.
2. **Screenshot tests for the companion.** The scripted replies (`/msg1`, `/tools`, `/card1`, `/error`, `/propose1` …) already produce every message type without a model. A golden test per script, at the three window sizes, would catch regressions like the sidebar font or a clipped row without a manual pass, and make the token migration in Part 2 safe.
3. **A toast preview in the debug menu.** In-app toasts only appear when the window is in front and the chat isn't in view, which makes them the hardest surface to look at. A "show a sample toast" entry (done, question, error) would make them testable in seconds.
4. **Carry plain text beside markdown.** Toasts, search snippets, chat titles and the Windows notification all want a reply's text without its markup. Storing or deriving one plain-text form in one place would replace the ad-hoc stripping (including the function added here).
5. **Standalone dev mode loses its chat list on hot restart.** After a hot restart the sidebar stayed empty while messages still showed, and I had to relaunch. Dev-only, but it costs time on every UI session.
6. **Keyboard-first pass.** With buttons now focusable, a full Tab order review (sidebar → header → messages → composer), visible focus on rows, and arrow-key movement in the chat list would make Gaia usable without the mouse, which suits a hotkey-summoned tool.
