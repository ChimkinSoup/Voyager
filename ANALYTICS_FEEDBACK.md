### 1. The Sparklines (Consecutive Trackers)
- **Gradient Wash:** Underneath the line, apply a gradient fill that starts with the tracker's custom color at 30% opacity at the line, fading down to pure transparent (`#1B1B22` with 0% opacity) at the baseline. This gives the data visual weight.
- Add padding between the X-axis and the marked dates. Clearly differentiate between which values correlate to marks on the Y axis, and on the X-axis (Currently the starting values in the Y and X axis are too close to each other). Additonally fix scaling in the Y-axis, for large popup views (When focused on a specific statistic), show 6 grid lines on the Y axis (e.g. "0, 1, 2, 3, 4, 5" or "5, 10, 15, 20, 25, 30"), and for regular default grid view show only 3 grid lines (e.g. "0, 5, 10" or "5, 10, 15").

### 2. The Heatmap Grid

- **The "Container Glow":** Instead of just changing the opacity of a flat color to represent intensity, use a very subtle `BoxShadow` that matches the cell's color for high-intensity periods. A "capped" or highly active day should literally look like an LED glowing slightly against the dark geometric background.

### 3. Calendar View
- Remove this view option entirely. The user should be able to press onto a specific statistic in the default view (Which is the grid view), and they will be shown effectively what is currently being shown in the calendar view, except it will be a very large popup overlayed on top of the grid view.
