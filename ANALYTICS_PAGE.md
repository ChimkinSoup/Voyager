## 1. Database Schema (SQLite / CRDT Ready)

We need three tables to handle the definitions, the enum options, and the daily entries. Because Voyager is offline-first, these will integrate into your existing SyncEngine pipeline.

**Table: `statistic_definitions**`
Defines *what* the user is tracking and *how* it behaves.

* `id` (TEXT, UUID) - Primary Key.
* `name` (TEXT) - e.g., "Gym", "Weight", "Books Read".
* `data_type` (TEXT) - `BOOLEAN`, `INTEGER`, `ENUM`.
* `tracking_style` (TEXT) - `INDEPENDENT` (Heatmap), `CONSECUTIVE` (Line Graph). *Null for Booleans/Enums.*
* `schedule_type` (TEXT) - `DAILY`, `WEEKLY`, `MONTHLY`, `YEARLY`.
* `schedule_anchor` (INTEGER) - e.g., `1` for Monday, `15` for the 15th of the month.
* `cap_value` (INTEGER) - Optional upper bound (e.g., 10 for Mood).
* `default_int` (INTEGER) - Defaults to 0.
* `default_bool` (INTEGER) - Defaults to 0 (false).
* `is_active` (INTEGER) - Soft-delete/archive flag.

**Table: `statistic_enum_options**`
Stores the choices for Enum stats. Reordering these retroactively changes historical colors.

* `id` (TEXT, UUID) - Primary Key.
* `stat_id` (TEXT, UUID) - Foreign Key to `statistic_definitions`.
* `name` (TEXT) - e.g., "Book A".
* `sort_order` (INTEGER) - Determines its shade of the accent color.

**Table: `statistic_entries**`
The actual data the user inputs.

* `id` (TEXT, UUID) - Primary Key.
* `stat_id` (TEXT, UUID) - Foreign Key to `statistic_definitions`.
* `due_date` (INTEGER, Unix Timestamp) - The specific scheduled date this entry belongs to (critical for weekly/monthly alignment).
* `int_value` (INTEGER) - Nullable.
* `bool_value` (INTEGER) - Nullable.
* `enum_id` (TEXT, UUID) - Nullable.
* `updated_at` (INTEGER) - For CRDT Last-Write-Wins resolution.

---

## 2. State Management & Logic (Riverpod)

To maintain 60fps performance without locking up the UI, the math for maximums and interpolation must be handled efficiently.

### A. The 1-Year Rolling Maximum (Independent Integers)

We do not calculate this on the fly in the UI. We use a local Drift query:

```sql
SELECT MAX(int_value) FROM statistic_entries 
WHERE stat_id = ? AND due_date >= (CURRENT_DATE - 365 DAYS)

```

This value is cached in a Riverpod `Provider`. If the rolling max is 50 pages read, a day with 25 pages gets an opacity of $0.5$ (50%).

### B. Enum Dynamic Color Generation

Instead of random colors, we apply a luminosity shift to your global accent color based on the `sort_order` index.

* Index 0: Base Accent Color.
* Index 1: Base Accent + 15% Brightness.
* Index 2: Base Accent - 15% Brightness.
* Index 3: Base Accent + 30% Brightness.
* This guarantees a cohesive, monochromatic "Lantern" palette that updates dynamically if the user drags "Book C" to Index 0.

### C. Missing Data Interpolation (Consecutive Integers)

When querying `statistic_entries` for a Line Graph, if Tuesday is missing between Monday and Wednesday, we use a **Catmull-Rom Spline** or **Monotone Cubic Interpolation** algorithm inside the Riverpod controller. This passes a perfectly continuous, smoothed data set of `(x: date, y: value)` coordinates to the UI rendering engine, ensuring the graph never visually "drops to zero".

---

## 3. UI / Widget Architecture

### A. The Journal Page Entry Flow

* **Widget:** `StatisticsActionFab` (Floating Action Button).
* **Logic:** A Riverpod listener checks if `statistic_entries` lacks rows for today's active `due_dates`. If missing > 0, wrap the FAB in your `Animate` library with a subtle glowing shader.
* **Interaction:** Clicking it opens a `StatisticsEntryModal`.
* **Time Travel UI:** The modal header contains a `CupertinoDatePicker` (or your custom scrolling wheel). By default, it says "Today". Changing the date instantly repopulates the modal with the entries for that specific past date.

### B. Analytics Page: Default View (The 4 Dashboards)

* **1. Consecutive Sparkline Stack:** A `ListView` of `SizedBox(height: 60)` containing `fl_chart` LineGraphs. They share the same X-axis constraints but hide their grids and labels.
* **2-4. Heatmap Grids:** Built using a `CustomScrollView` with horizontal scrolling.
* **The Divider Logic:** Group the data by `schedule_type`. Render Daily rows, then a `Divider(color: Colors.white.withOpacity(0.1))`, then Weekly, etc.
* **The Grid Size:** Each row is exactly 30 squares long (representing the last 30 `due_dates` for that specific stat).
* **Interaction:** Wrapping each square in a `GestureDetector`. Tapping it opens a small floating popover showing `Date`, `Current Value`, and a `TextField`/`Dropdown` to instantly edit it.



### C. Analytics Page: Calendar View

* **Toggle:** A global "View Mode" toggle switches between `Grid` and `Calendar`.
* **Selection:** The user clicks a specific statistic to focus on.
* **Monthly Calendar (Independent/Enum/Bool):** Uses your existing calendar logic, but paints the day cell with the calculated heatmap color. We overlay the exact raw value (e.g., "8") as text in the center of the cell.
* **Yearly Calendar (Independent/Enum/Bool):** Same as month, but without text.
* **Calendar (Consecutive):** If the user selects a *Consecutive* integer and switches to Calendar mode, the grid completely dissolves. It is replaced by a massive, highly detailed Line Graph spanning the selected month/year.