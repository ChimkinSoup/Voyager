- Implement a lite version of VIM with all the standard operations, excluding complicated ones such as macros and registers. Here are some operations you should include:
#### 1. Mode Switching (The State Anchors)
- `<Esc>` - Returns to Normal Mode from Insert, Visual, or Search modes. Clears any pending states (like an unfinished `d` or `f`).
- `v` - Enters **Visual Mode** (Character-wise). Anchors `baseOffset` and lets motions update `extentOffset`.
- `V` (Shift+v) - Enters **Visual Mode** (Line-wise). Anchors to the start/end of the current line and expands line-by-line.
#### 2. Insert Mode Triggers (Drops control to Flutter)
Executing these in Normal/Visual mode performs a cursor jump/text manipulation and instantly changes `mode = VimMode.insert`.
- `i` - Insert before cursor
- `I` (Shift+i) - Insert at the beginning of the line
- `a` - Append after cursor
- `A` (Shift+a) - Append at the end of the line
- `o` - Open a new line below and insert
- `O` (Shift+o) - Open a new line above and insert
#### 3. Immediate Motions (Standard Jumps)
If preceded by a verb (like `d` or `y`), they dictate the range. If in Visual mode, they expand the selection.
- `h`, `j`, `k`, `l` - Left, Down, Up, Right
- `w` - Jump forward to the start of the next word
- `b` - Jump backward to the start of the previous word
- `e` - Jump forward to the end of the current word
- `0` (Zero) - Jump to the absolute start of the line
- `$` - Jump to the absolute end of the line
- `g` - Requires a second `g` (`gg`) to jump to the very top of the document
- `G` (Shift+g) - Jump to the very bottom of the document
#### 4. Transient Motions (The "Find" state)
These force the state machine to wait for the very next character typed, execute the jump, and save the action to `LastCharSearch`.
- `f` - Find character forward (inclusive)
- `F` (Shift+f) - Find character backward (inclusive)
- `t` - "Till" character forward (exclusive - stops one space before)
- `T` (Shift+t) - "Till" character backward (exclusive)
#### 5. Memory State Triggers (Fast Repetition)
These execute instantly based on stored variables.
- `;` - Repeat the last `f`, `F`, `t`, or `T` search in the same direction
- `,` - Repeat the last `f`, `F`, `t`, or `T` search in the opposite direction
- `.` - Repeat the last mutating action (reads from `LastAction`)
#### 6. Verbs / Operators (The "Pending" state)
When pressed in Normal mode, they wait for a Motion (Category 3 or 4). If pressed twice (e.g., `dd`), they act on the whole line. **If pressed in Visual Mode (`v` or `V`), they instantly apply to the highlighted text and drop you back to Normal mode.**
- `d` - Delete (cuts to system clipboard/unnamed register)
- `c` - Change (deletes to clipboard, then instantly enters Insert mode)
- `y` - Yank (copies to system clipboard/unnamed register)
#### 7. Instant Actions (No motions required)
These modify text/state immediately based on the current cursor position.
- `x` - Delete the single character under the cursor (or the whole selection if in Visual mode)
- `p` - Paste the contents of the clipboard after the cursor
- `<C-v>` (Ctrl+v) - Standard OS Paste. Handled exactly like `p` in Normal mode; ignored by VimController in Insert mode.
- `u` - Undo (Triggers Flutter's native undo history or CRDT rollback)
- `<C-r>` (Ctrl+r) - Redo
#### 8. Search State
- `/` - Opens your custom minimalist search bar at the bottom. Absorbs typing until `<Enter>` is pressed.
- `n` - Jump to the next search match
- `N` (Shift+n) - Jump to the previous search match

---
The sections below list commands the implementation (`lib/core/vim/`) supports beyond the list above. Each was checked in the running app on 2026-09-29 (QA Phase 3, `qa/steps/p3x-*.tsv`) unless marked *untested*. Known deviations are logged in `qa/BUGS.md` (BUG-013, BUG-014, BUG-015, BUG-016, BUG-018, BUG-020; all fixed on 2026-10-05).
#### 9. More Motions
All take a count and work after an operator or in Visual mode.
- `W`, `B`, `E` - WORD versions of `w`, `b`, `e`: a WORD is any run of non-blank characters, so `alpha-beta` is one WORD but three words
- `^` - Jump to the first non-blank character of the line (`0` goes to column 0)
- `g_` - Jump to the last non-blank character of the line (`$` goes to the last character, even a trailing space)
- `{` / `}` - Jump to the previous / next blank line (paragraph boundary)
- `%` - Jump to the matching bracket: `()`, `[]`, `{}`. If the caret isn't on a bracket, the first bracket ahead on the line is used
- `|` - Jump to a column: `5|` goes to column 5 of the current line
- `+` / `<Enter>` - Jump to the first non-blank of the next line; `-` - Jump to the first non-blank of the previous line
- `<Space>` - Same as `l`, but wraps onto the next line (not after an operator: `d<Space>` on the last character deletes just that character)
- `NG` / `Ngg` - Jump to line N (`3G`, `2gg`); `N$` - Jump to the end of the line N−1 lines below
- `gj` / `gk` - Move down / up by *display* line inside a soft-wrapped line (`j`/`k` move by real lines)
- `<C-d>` / `<C-u>` - Move down / up 10 lines, keeping the column
- Arrow keys, `<Home>`, `<End>`, `<PageUp>` / `<PageDown>` (20 lines), `<Backspace>` (moves left, wrapping to the end of the previous line) - Work as motions in Normal and Visual mode; `<Delete>` deletes the character under the caret
#### 10. More Operators
- `>` / `<` - Indent / outdent by one shift width (2 spaces; code fields use their own tab width). `>>` / `<<` act on the current line, `>j` or `2>>` on two lines, and `>` / `<` in Visual mode on the selected lines. `.` repeats.
- `gu` / `gU` / `g~` - Lowercase / uppercase / toggle the case over a motion or text object (`guiw`, `gUw`). Doubled (`guu`, `gUU`, `g~~`) they act on the whole line.
#### 11. More Instant Actions
- `X` - Delete the character before the caret (`3X` deletes three); does nothing at the start of a line
- `D` - Delete to the end of the line; `C` - Change to the end of the line (delete, then Insert)
- `s` - Delete the character under the caret and enter Insert (`3s` three characters); `S` - Empty the line (`2S` two lines) and enter Insert
- `Y` - Yank the whole line (`2Y` two lines); same as `yy`
- `r{char}` - Replace the character under the caret with {char} without leaving Normal mode; `3rx` replaces three characters
- `~` - Toggle the case of the character under the caret and move right; `4~` toggles four
- `J` - Join the next line onto this one: the next line's leading whitespace is removed and one space goes between them (trailing whitespace on this line is collapsed into that one space). `3J` joins three lines; in Visual mode `J` joins the selected lines.
- `P` - Paste before the caret (a yanked line goes above the current line); counts work for both `p` and `P` (`2P`)
- `U` - Does nothing in Normal mode (there is no line-undo); in Visual mode it uppercases the selection
#### 12. Text Objects
After an operator (`d`, `c`, `y`, `>`, `<`, `gu`, `gU`, `g~`) or in Visual mode. `i` = inner (contents only), `a` = around (includes the delimiters, or for words and paragraphs the trailing whitespace / blank line).
- `iw` / `aw` - word; `iW` / `aW` - WORD
- `ip` / `ap` - paragraph (a block of non-blank lines)
- `i"` / `a"`, `i'` / `a'` - quoted string; `` i` `` / `` a` `` - backtick string (*untested*: the QA harness can't type a backtick on this PC's keyboard layout)
- `i(` / `a(` (also `i)`, `ib`), `i{` / `a{` (also `i}`, `iB`), `i[` / `a[`, `i<` / `a<` - bracket pairs
- If the caret isn't inside the object, nothing happens and the pending operator is cancelled.
#### 13. Visual Mode Extras
- `o` - Swap which end of the selection moves
- `u` / `U` / `~` - Lowercase / uppercase / toggle the case of the selection (also `gu`, `gU`, `g~`)
- `J` - Join the selected lines; `s` - Change the selection; `x` / `X` - Delete the selection
- `iw`, `i(`, … - Select a text object (see section 12)
- `<C-c>` (Ctrl+c) - Copy the selection to the OS clipboard and return to Normal mode
#### 14. More Control Keys
- `<C-[>` (Ctrl+[) - Same as `<Esc>`: leaves Insert or Visual mode, or cancels a pending command
- `<C-a>` (Ctrl+a) - Select the whole text (enters line-wise Visual mode)
#### 15. More Search Keys
- `?` - Open the search bar searching backward; after it, `n` keeps going backward and `N` goes forward
- The search is incremental: the caret previews the first match while you type, and every match is highlighted. `<Esc>` in Normal mode clears the highlights (*untested*, per the code).
- Inside the search bar: `<Backspace>` deletes a character (on an empty bar it closes the bar); `<C-w>` deletes the last word; `<C-u>` clears the pattern; `<C-v>` pastes the first line of the OS clipboard; `<Esc>` or `<Tab>` cancels the search and puts the caret back.
#### 16. Behaviour Notes
- Every field starts in Insert mode when it gets focus; the mode badge only appears outside Insert.
- `y`, `d`, `c`, `x` and `p` use Vim's own register, shared by all fields. It is **not** the OS clipboard: yanking doesn't change what Ctrl+V pastes elsewhere. Use `<C-v>` to paste the OS clipboard and Visual `<C-c>` to copy to it.
- A focused Vim field keeps `<Esc>` for itself, so pressing Esc in Normal mode never closes the dialog the field is in; use the dialog's buttons or `<C-Enter>` where the form supports it.
- In one-line fields, `o` / `O` act like `A` / `I`, `j` / `k` do nothing, `<Enter>` in Normal mode submits the field (as in Insert), and pasted line breaks are flattened to spaces.
- Counts are capped at 100000.