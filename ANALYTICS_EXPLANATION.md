# Voyager Analytics Page: Comprehensive Technical Architecture & Edge Cases

This document provides a full-detail technical breakdown of the Voyager Analytics page, explaining its features, components, state management, and the extensive array of edge cases it handles to ensure a robust, performant offline-first tracking experience.

---

## 1. Core Purpose & Overview
The Analytics page in Voyager allows users to visualize and edit tracked statistics over time. It supports two primary visualization modes:
1. **Grid View**: A high-level dashboard displaying:
   * **Consecutive Trackers**: Rendered as interactive Sparklines showing numerical trends.
   * **Heatmap Trackers**: Displays recent entries (the last 30 periods) in a chronological grid of shaded squares, grouped by cadence (Daily, Weekly, Monthly, Yearly) and starred status.
2. **Calendar View**: A focused look at a single statistic in a calendar layout, adapting to its cadence (Monthly grids, Yearly grids, 10-Year views, or week-block lists).

---

## 2. Database Models & Schema Integration
Voyager uses an offline-first database. The analytics page interacts with two primary models defined in the domain layer:
* **`StatisticTracker`**: Defines the metadata for a tracker (e.g., name, type, cadence, color, cap values, default value, custom sorting index, and starred status).
* **`TrackerValue`**: Represents a single entry. The `periodStart` date serves as the canonical timestamp.

### Cadences & Date Anchoring
To prevent cross-cadence data pollution and ensure consistency between views, all entries are snapped to a canonical start date for their period:
* **Daily**: Snaps to `00:00:00.000` of the calendar day.
* **Weekly**: Snaps to the start of the week (determined by the user's `weekStartsOnMonday` setting).
* **Monthly**: Snaps to the 1st of the month (`YYYY-MM-01`).
* **Yearly**: Snaps to January 1st (`YYYY-01-01`).

*Edge Case Handled:* When matching values, matching is performed strictly against the full canonical `periodStart` (year, month, and day) rather than just the year or month. If a tracker's cadence is changed, this prevents daily entries from being incorrectly aggregated or overwritten as monthly/yearly entries.

---

## 3. Detailed Component Breakdown & Edge Cases

### A. The Grid View & Sparkline Stack
Consecutive trackers are visualized using `fl_chart` line graphs.
* **Anchor Spots**: For empty or sparse charts, an invisible baseline (`barIndex 0` with `Colors.transparent` and 0 width) is generated for every period in the window.
  * *Edge Case Handled:* Without anchor spots, `fl_chart` cannot register taps on empty chart regions. These anchors ensure a user can tap anywhere on an empty sparkline to prompt the popover editor.
* **Dynamic Grid Intervals**: Bottom labels and vertical grid lines adjust dynamically depending on the cadence:
  * **Daily**: Ticks every 10 days, grid lines every 5 days.
  * **Weekly**: Ticks every 70 days, grid lines every 35 days.
  * **Monthly**: Ticks every 300 days, grid lines every 150 days.
  * **Yearly**: Ticks every 3650 days, grid lines every 1825 days.
* **Interpolation**: Consecutive charts use the `interpolateConsecutive` algorithm.
  * *Edge Case Handled:* If data is missing for intermediate periods, the graph would normally plunge to zero. The interpolation algorithm fills in missing data using smoothed curves, preventing visual drop-offs while maintaining the integrity of recorded points.

### B. The Heatmap Bucket & Reordering System
Heatmap rows are grouped into buckets: virtual default trackers first, then starred trackers, followed by cadence-grouped categories.
* **Bucket Isolation**: Each bucket owns its own `ReorderableListView`.
  * *Edge Case Handled:* Users can drag-reorder trackers *within* their bucket, but cannot drag a tracker out of its bucket (e.g., dragging a weekly tracker into a daily bucket).
* **Optimistic Local State**: The `_HeatmapBucket` widget maintains local item order state and asynchronously persists changes to the repository.
  * *Edge Case Handled:* During a drag-reorder, external rebuilds of the widget tree (due to asynchronous database writes or state invalidation) could interrupt the user's drag. Using `didUpdateWidget` comparison keying protects the active drag state from being overwritten.
* **Hover Suppression**: When a reorder drag is active, `_heatmapDraggingProvider` is set to `true`.
  * *Edge Case Handled:* Hover tooltips are suppressed globally during dragging to prevent stray popups from appearing as the dragged element passes over other squares.

### C. Virtual Default Trackers
Voyager includes built-in read-only trackers (like `Journal Entries` with `kJournalEntriesTrackerId`).
* *Edge Case Handled:* Virtual trackers do not exist as editable rows in the database. The UI checks `isDefault` and hides editing controls (no editing modals, no star button, no drag handles, and no write capabilities in the tooltip). The tooltip displays text labels like `Journaled` or `Not journaled` instead of completed/not completed.

### D. The Calendar Views
When switching to **Calendar View**, the layout adapts to the selected tracker:
* **Consecutive Charts**: Renders a wide line chart spanning a fixed window (e.g., 180 days for Daily, 343 days for Weekly, 720 days for Monthly, and 5475 days for Yearly).
* **Monthly Heatmap Calendar**: Renders a traditional Sun-Sat grid.
* **Yearly Heatmap Calendar**: Renders a 4x3 grid of month tiles.
  * *Edge Case Handled (Weekly Cadence in Year Tiles):* For weekly trackers in a yearly grid, rendering individual daily cells would be confusing. Instead, the UI merges the week into a single block (`_HeatmapWeekBlock`). If a week spans across months, the spilling days are rendered as greyed-out segments within the same week block to preserve continuity.
* **Monthly Grid (24-Box)**: Shows a 2-year rolling window (12 boxes/months per row).
* **Yearly Grid (10-Box)**: Shows a 10-year rolling window in a single row.

---

## 4. Popover & Morphing Editor
Tapping any heatmap square or line chart spot launches the editor. This is designed with a premium, physics-based morph transition.

```
+--------------------------+          +-----------------------------------+
|      Hover Tooltip       |  TAPPED  |           Morph Popover           |
|  [ Date ]        [ - ]   | -------> |  [ Tracker Name ]        [ Date ] |
+--------------------------+          |  [====== Slider / Input ======= ] |
                                      |  [ Delete ]     [ Save ] [Cancel] |
                                      +-----------------------------------+
```

### A. Hover Tooltip Overlay
Hovering over a square spawns a transient `OverlayEntry` positioned relative to the target using a `LayerLink` and `CompositedTransformFollower`.
* *Edge Case Handled:* The overlay is linked to the cell's transform target. If the parent list scrolls, the tooltip scrolls in lockstep rather than staying statically floating on screen.
* *Edge Case Handled (Menu Animating Overlap):* Tooltips are suppressed if the toolbar's statistic selector dropdown menu is open/animating (`_calendarMenuOpenProvider` is true). Once the menu closes, the deferred tooltip is shown.

### B. Morph Route Transition
To prevent element tree corruption (which occurred when interactive text fields were injected straight into transient overlays under `go_router`), the editor is opened as a true `PageRouteBuilder` route, but with `transitionDuration: Duration.zero`. 
1. **Measurement Phase**: Upon tapping, the tooltip is dismissed, and its final screen coordinates (`anchorRect`) and date text coordinates (`anchorDateRect`) are passed to the popover. The new popover renders the editor content off-screen to measure its natural size (`_cardKey` and `_cardRect`).
2. **Expansion Animation**: Once measured, a `DecoratedBox` representing the card frame animate-expands from `anchorRect` to `_cardRect`.
3. **Clip Reveal**: The editor content is clipped via `ClipRect` using a custom `_RevealClipper` matching the morph's progress. This prevents the form's text fields from reflowing or squishing as the boundaries expand.
4. **Date Slide**: The date text is rendered in a separate floating layer. It uses `TextStyle.lerp` and `Offset.lerp` to slide smoothly from the tooltip's date location to the editor's date location.
   * *Edge Case Handled (Flicker/Pop Prevention):* To prevent the date from flashing or appearing out of place for one frame before the layout measurements settle, the popover uses the tapped tooltip's pre-measured `anchorDateRect` to immediately seed the starting position.

### C. Adaptive Input Elements & Autosave
* **Integer**: Shows a `Slider` if `integerCap` is defined, along with a `digitsOnly` text field.
* **Boolean**: Renders a `SwitchListTile`.
* **Enum**: Renders a dropdown menu.
* **Button Contrasts**: The save button checks the custom tracker color brightness using `ThemeData.estimateBrightnessForColor` to dynamically set white or black text.
* **Autosave**: Tapping outside the card or pressing escape triggers a save callback (`_handleOutsideTap`) rather than discarding the user's progress.

---

## 5. Summary of Key Technical Edge Cases

| Area | Edge Case Scenario | Solution / Handling |
| :--- | :--- | :--- |
| **Data Integrity** | Cadence switches polluting entries. | Snap and validate entries strictly to canonical dates (e.g., 1st of month for Monthly). |
| **Grid Interaction** | Sparklines with no values cannot be tapped. | Generate invisible anchor lines at zero-height to capture touches across the entire X-axis. |
| **Drag & Drop** | List animations flickering / resetting mid-drag. | lock local bucket lists during dragging using `_heatmapDraggingProvider` and compare ID memberships. |
| **Rendering** | Graph plunges to zero on missing dates. | Run consecutive values through a smoothing/interpolation filter before plotting. |
| **UX & Aesthetics** | Hover tooltips drifting away during scroll. | Anchor tooltips using `CompositedTransformFollower` mapping to the parent cell's `LayerLink`. |
| **Tree Stability** | GoRouter crash when overlays gain focus. | open the editor as a full route with zero duration, morphing the visual frame manually. |
| **Text Contrast** | Dark text on dark custom colors (or vice versa). | Perform runtime brightness estimation on the color to toggle white vs. black foreground text. |
