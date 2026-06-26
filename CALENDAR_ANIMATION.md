Here is the precise Low-Level Design (LLD) for the segment-triggered Month $\leftrightarrow$ Week morph animation.

Since the user no longer taps a specific date to trigger the transition, the engine must intelligently anchor the animation to the currently active data state.

### **I. State & Trigger Logic (The Anchor)**

When the user clicks "Week" in the segment control, the app needs to know *which* week to zoom into.

**The Anchor:** You must use the currently selected date (e.g., `_selectedDate`) or, if none is selected, the first day of the currently visible month.
**The Index:** 1. Find the anchor date's index (0 to 41) in the current 42-cell month grid.
2. Calculate the row index: `rowIndex = index ~/ 7`.
3. The 7 cells to morph are exactly `(rowIndex * 7)` through `(rowIndex * 7 + 6)`.

### **II. The Geometry Cache (`CalendarLayoutCache`)**

Expand your existing geometric cache to include Week View coordinates. Calculate these using pure math on startup (zero widget mounting):

* **`monthCellRects` (List of 42):** The standard month day cells.
* **`weekColumnRects` (List of 7):** The tall, screen-height columns for the week view.
* **`monthCardRect` vs `weekAreaRect`:** The bounding box of the Month's background Card vs the flat boundaries of the Week grid.
* **`monthHeaderY` & `weekHeaderY`:** The vertical Y-offsets for the weekday labels (Mon, Tue, Wed...).

### **III. Animation Orchestration**

Use a dedicated `AnimationController` (e.g., 500ms, `easeInOutCubic`). Progress is defined as $t$ ($0.0 = \text{Month}$, $1.0 = \text{Week}$).

**Properties to Interpolate (`lerp`):**

1. **Cell Geometry:** `Rect.lerp(monthCellRects[i], weekColumnRects[i], t)`. As the `top` and `bottom` stretch to the screen edges, the horizontal borders naturally slide off-screen/fade out, and the vertical borders elongate into the Week view's column dividers.
2. **Card Background:** The Month view has a Card; the Week view is flat. Crossfade the Card opacity: `1.0 - t`.
3. **Weekday Headers:** `lerpDouble(monthHeaderY, weekHeaderY, t)`. The text physically slides up/down.
4. **Text Visibility:** For dates outside the current month (e.g., Sept 28-30), interpolate their color from the muted Month-style color at $t=0$ to the bright, active Week-style color at $t=1$.

### **IV. The Bifurcated Widget Tree**

During the 500ms transition, intercept the mode switch, set `_isWeekMorphing = true` (blocking all pointer input), and render this specific `Stack`:

```text
Stack
├── [Background Layer: The Fading UI]
│    ├── Opacity (1.0 - t): Month Card Background & Inactive Rows (The 5 rows NOT selected)
│    └── Opacity (t): Week View Background elements
│
├── [Morphing Layer: The Active Week]
│    └── CustomMultiChildLayout (MorphWeekDelegate)
│         ├── Cell 0 (Mon): lerps Rect, cell padding (8px -> 6px), and text styles
│         ├── Cell 1 (Tue): ...
│         └── Cell 6 (Sun): ...
│
├── [Header Layer: Shifting Weekdays]
│    └── Transform.translate (Y = lerped header offset)
│         └── Row (Mon, Tue, Wed...)
│
└── [Title Layer: Crossfade]
     └── Stack
          ├── Opacity (1.0 - t): Text("October")
          └── Opacity (t): Text("Week of Sep 28")

```

### **V. Execution Flow**

**Month $\rightarrow$ Week (Zoom In):**

1. User clicks "Week" in the segment control.
2. Determine `rowIndex` using the currently selected date.
3. Lock input (`_isWeekMorphing = true`).
4. `controller.forward()`. The target row stretches vertically. The other 5 rows and the Month Card dissolve. Weekday headers slide up.
5. On complete, set `_mode = week`, unlock input, and swap to the real `_WeekGrid` widget.

**Week $\rightarrow$ Month (Zoom Out):**

1. User clicks "Month" in the segment control.
2. The current week's dates are known. Find their corresponding `rowIndex` in the target month.
3. Lock input.
4. `controller.reverse()`. The 7 tall columns compress into their specific row slot. The Month Card and 5 inactive rows fade back in.
5. On complete, set `_mode = month`, unlock input, and swap to the real `_MonthGrid` widget.