Here is the High-Level Design (HLD) for Voyager’s Weekly Calendar View, incorporating the new overlap logic, the integrated Todo tasks, and the click-to-edit interactions.

---

### High-Level Design: Voyager Weekly Calendar View

#### I. System Overview

The Weekly Calendar View is a highly interactive, layered UI component responsible for displaying a 7-day timeline. It unifies user schedule data by rendering both time-bound Events and Todo Tasks within a strict spatial grid. The view ensures data clarity through z-index layering, automated spatial clustering for overlapping items, and direct touch-to-edit capabilities.

#### II. Visual Layout & Z-Index Stack

To maintain the visual hierarchy you specified, the view will be composed of stacked rendering layers (from bottom to top):

1. **Base Layer (Background):** The global app background (e.g., your geometric patterns).
2. **Item Layer (Events & Tasks):** The dynamically positioned colored blocks for events and thin bars for tasks.
3. **Grid Layer (Time Markers):** The horizontal, faint white lines. Rendering these *above* the events ensures the user can always read the time, even over brightly colored blocks.
* **Inline Labels:** The left side of the time grid will feature a small gap in the line containing the text (e.g., `--- 9:00 -----------`).


4. **Header Layer (All-Day Shelf):** A fixed vertical space at the top of the day column, before the hour lines begin, dedicated strictly to events marked "All Day."

#### III. The Overlap Engine (Column Splitting)

To handle overlapping time blocks gracefully, the rendering engine will group items into "clusters" and calculate horizontal widths dynamically.

* **Clustering:** Any events or tasks that share intersecting timeframes are grouped into a single cluster.
* **Width Calculation:** The total width of the day column is divided evenly by the maximum number of concurrent items in that cluster. If three events overlap at 10:00 AM, each gets 33% of the column width.
* **Positioning:** Items are assigned a horizontal offset (left, center, right) so they sit perfectly side-by-side without occluding one another.

#### IV. Data Entity Specifications

Here is how the two primary data types will manifest visually in the grid:

| Feature | Calendar Events | Todo Tasks |
| --- | --- | --- |
| **Shape & Size** | Large, filled rectangle spanning the exact vertical height of its duration (e.g., 2 hours = 2 time blocks). | Thin, fixed-height horizontal bar placed at its designated start time or deadline. |
| **Coloring** | Solid fill using the user's assigned event color. | Solid fill or bordered (depending on completion state), matching the task category color. |
| **Iconography** | None required (unless explicitly added by user). | Left-aligned "check-fat" icon indicating the actionable state. |
| **Typography** | Bold title, optional location or time text. | Standard title next to the check icon. |
| **Metadata Indicators** | None. | Right-aligned icons for Notes (e.g., a small document icon) and Subtask counts (e.g., "2/5"). |

#### V. User Interaction Flow

Frictionless editing is critical for a life-tracking app. The calendar will be fully interactive rather than just a static view.

* **Tap-to-Edit:** Tapping any Event block or Task bar immediately triggers an edit state. Depending on your overarching UI patterns, this should open either a modal dialog, a bottom sheet, or route to a dedicated edit screen, allowing the user to update titles, times, or mark tasks as complete.
* **Creation Prompt:** When the user taps an empty space or hits a "+" FAB to create an entry, they will be prompted for a time range. If they untoggle "All day event," the UI will immediately expand to require specific start and end times, which then dictate the exact vertical coordinates for the new block.

---


# Todo Task Logic
Here is exactly how you handle zero-duration tasks within your layout and overlap engine.

### The Zero-Duration Task Layout Logic

Since events derive their height from their duration (e.g., 60 minutes = 60 pixels), tasks sitting at a specific timestamp require a slightly different mathematical approach so they remain usable and readable.

**1. The Fixed-Height Rule**
Even though a task has no time duration, it must have a fixed UI height to be readable and tappable. Standard mobile UI guidelines dictate a minimum touch target.

* Your task will be a thin horizontal bar with a fixed height (e.g., `40px` or `48px`).
* The vertical `Y-coordinate` of the task's **top edge** will map exactly to its timestamp. For example, a task set for 2:00 PM will have its top edge sitting exactly on the faint white 2:00 PM grid line, extending downwards for 40px.

**2. Handling Collisions with Tasks**
Because tasks now have a fixed visual height rather than a time-based height, your Overlap Engine needs to calculate collisions based on the *visual bounding box* rather than just the timestamps.

* **Task vs. Event:** If a user has a "Team Meeting" event from 1:00 PM to 3:00 PM, and a "Submit Report" task due at 2:00 PM.
* At 2:00 PM, the engine detects a collision.
* The column splits in half. The Event takes the left 50% (spanning the whole 2 hours), and the Task takes the right 50% (sitting at the 2:00 PM line, but only 40px tall).
* *Result:* The task looks like a neat little card resting on top of the event's timeline.


* **Task vs. Task:** If two tasks are due at exactly 2:00 PM, the column splits 50/50, and they sit side-by-side as two short bars.
* **The "Stacking" Edge Case:** If Task A is at 2:00 PM and Task B is at 2:05 PM, their 40px visual heights will likely overlap on the screen. The engine will detect this UI collision and split the column for them, preventing the 2:05 PM task from hiding the 2:00 PM task.

**3. The Visual Anatomy of the Task Bar**
To ensure the task bar fits its data inside a potentially split column, the internal layout should use a standard Row with text truncation:

* **Left:** The `check-fat` icon (indicating completion status).
* **Center:** The Task Title (using `TextOverflow.ellipsis` so it doesn't break the UI if the column is squeezed by overlapping events).
* **Right:** A compact Row of metadata icons (a small document icon for notes, and a tiny `2/5` text for subtasks) aligned to the end.

By treating tasks as fixed-height floating cards anchored to a specific Y-coordinate, you maintain the strict spatial grid you want while keeping the UI completely predictable for the user.