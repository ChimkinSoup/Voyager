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