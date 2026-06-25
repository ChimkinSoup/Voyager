# Calendar Morph Animation — Full Pipeline

This document traces the complete lifecycle of the year↔month morph animation from app startup through the user's first tap, covering every caching layer and every rendering stage.

---

## 1. What the animation actually is

The transition between year view and month view is a **bifurcated render architecture** with two independent layers running on a single `AnimationController` (0→1 over 600 ms, `easeInOutCubic`):

| Layer | Role | Technique |
|---|---|---|
| **Background** | The other 11 months fly outward | `Matrix4` camera push via `Transform` |
| **Foreground** | 42 day-cells of the tapped month morph | `CustomMultiChildLayout` + per-cell lerp |

There are no crossfades. Every property is a hard mathematical interpolation.

---

## 2. The two caches

### 2a. GPU Shader Cache — `CalendarMorphWarmup`

**When**: Immediately at login, inside `AppShell`, before the user has ever opened the calendar.

**What it does**: Forces the graphics pipeline to compile all shader programs for the morph animation by rendering a real `_MorphAnimationLayer` at `opacity = 1/255` (invisible but actually painted).

**Why it matters**: Impeller and Skia compile shaders lazily on first draw. Without warmup, the first frame of the real animation takes several milliseconds to compile shaders, causing a visible stutter.

**The 4-frame sequence**:

```
Frame 0: controller = 0.1, morphReverse = false  →  GPU compiles forward lerp shaders
Frame 1: controller = 0.1, morphReverse = false  →  GPU rasterises forward path (second pass)
Frame 2: controller = 0.1, morphReverse = true   →  GPU compiles INVERTED lerps + reverse Matrix4Tween
Frame 3: controller = 0.1, morphReverse = true   →  GPU rasterises reverse path (second pass)
Frame 4: _done = true  →  widget collapses to SizedBox.shrink
```

Frames 1 and 2 are triggered by `_CalendarMorphWarmupState._advanceWarmup` advancing `_step` with `addPostFrameCallback`. When `_step == 2` the state flips `_morphReverse = true`, which causes `_MorphAnimationLayer` to be replaced entirely (via `ValueKey(_morphReverse)`) so its `initState` re-runs with swapped source/dest roles and the inverted `Matrix4Tween` (`zoomed → identity` instead of `identity → zoomed`).

The `WeatherChartTransitionWarmup` has an 800 ms start delay so it never competes with these 4 frames for rasteriser time.

### 2b. Layout Geometry Cache — `CalendarLayoutCache`

**When**: On the very first layout pass of the calendar area, via a `LayoutBuilder` wrapping the expanded calendar column. Runs whether the page opens in year view or month view. Recomputes only when `constraints.biggest` changes (window resize).

**What it stores** (all coordinates in calendar-area-local space):

```dart
class CalendarLayoutCache {
  final Size areaSize;              // cache key — invalidated on resize
  final List<Rect> tileBounds;      // 12 outer Rect for each year-grid tile
  final List<List<Rect>> tileSourceRects; // 42 cell Rects inside each tile's MonthDayGrid
  final List<Matrix4> tileZoomMatrices;   // zoom Matrix4 (tile → full area) per tile
  final List<Rect> destRects;       // 42 cell Rects for the full month view
}
```

**How it is computed** — pure math, zero widget mounting, zero render-object reads:

```
Year-grid tile layout (mirrors _YearGrid constants exactly):
  crossAxisCount = 3, rowCount = 4
  crossAxisSpacing = 8.0, mainAxisSpacing = 6.0

  tileWidth  = (areaW − 8 × 2) / 3
  tileHeight = (areaH − 6 × 3) / 4

  tile[i].left = (i % 3) × (tileWidth + 8)
  tile[i].top  = (i ÷ 3) × (tileHeight + 6)

Source cells per tile (_calendarWarmupSourceRects):
  gridLeft = tile.left + 6           (Card padding)
  gridTop  = tile.top  + 6           (Card padding)
           + titleHeight             (TextPainter measurement)
           + titleGap (8)
           + WeekdayHeaderRow.totalHeight  (includes the 8px gap after the row)
  cellW = (tileWidth − 12) / 7
  cellH = (remaining height) / 6

Zoom matrix per tile:
  sx = areaW / tileWidth
  sy = areaH / tileHeight
  M  = identity
     .translate(−tile.left × sx, −tile.top × sy)
     .scale(sx, sy)

Destination cells (MonthTitleHeader.dayCellRects):
  gridTop = cardPadding + titleHeight + titleGap + weekdayBlockHeight + cardPadding
  cellW   = (areaW − cardPadding × 2) / 7
  cellH   = (remaining height) / 6
```

**Invalidation**: `_refreshLayoutCache(Size)` is a no-op when `_layoutCache?.areaSize == areaSize`. It runs synchronously inside the `LayoutBuilder` on every layout pass but only recomputes when the area size changes.

---

## 3. Forward animation: year → month (`_onMonthTapped`)

```
User taps month tile
        │
        ▼
_onMonthTapped(month)
  1. Read from _layoutCache (must already exist from LayoutBuilder):
       morphTileRect  = cache.tileBounds[month−1]
       sourceRects    = cache.tileSourceRects[month−1]   (42 Rects inside tile)
       zoomMatrixEnd  = cache.tileZoomMatrices[month−1]
       destRects      = cache.destRects                  (42 full-view Rects)
  2. Build Matrix4Tween(begin: identity, end: zoomMatrixEnd)
  3. _prepareMorphSession() — increments generation, stops+resets controller
  4. setState() — commits all morph state to _CalendarPageState fields
  5. _startMorphAnimation(generation, onComplete)
       └─ addPostFrameCallback:
            controller.forward(from: 0)      ← animation fires next frame
```

**No measurement frames. No Offstage widgets. No RenderBox reads. The animation starts on the very next frame after the tap.**

---

## 4. Reverse animation: month → year (`_onReverseToYear`)

Both source and destination geometry come entirely from `CalendarLayoutCache` — the same analytical math as the forward path, with roles swapped.

```
User clicks Year (or Back)
        │
        ▼
_onReverseToYear()
  1. Read from _layoutCache:
       sourceRects   = cache.destRects                  (full month view at t=0)
       destRects     = cache.tileSourceRects[month−1]   (year tile at t=1)
       morphTileRect = cache.tileBounds[month−1]
       yearTween     = Matrix4Tween(begin: cache.tileZoomMatrices[month−1], end: identity)
  2. setState() + _startMorphAnimation()   ← starts on next frame
```

**No Offstage measurement frame. No RenderBox reads. Identical latency to the forward path.**

---

## 5. The `_MorphAnimationLayer` render loop

Once `controller.forward()` fires, every frame executes this path:

```
AnimationController tick (raw value 0→1)
        │
        ▼  AnimatedBuilder
_MorphAnimationLayerState.build(context)
  raw = controller.value
  t   = Curves.easeInOutCubic.transform(raw)   ← eased progress

  ┌─ styleT (visual progress) ───────────────────────────────────────┐
  │  forward:  styleT = t        (compact → full styling)           │
  │  reverse:  styleT = 1 − t   (full → compact styling)           │
  └──────────────────────────────────────────────────────────────────┘

  ① Background layer
     _applyYearTransform(t):  lerps 16 floats in-place, reusing the
                              same Matrix4 storage every frame
     Transform(matrix: _yearTransform, child: yearGrid)
       yearGrid = live CalendarGrid(year, hiddenMonth: morphMonth)
       The tapped month tile is an invisible SizedBox — its hole expands
       as the camera pushes in, while the other 11 tiles fly outward.

  ② Background card (the white surface that fills the hole)
     bgRect = Rect.lerp(tileRect, fullAreaRect, t)   [or reversed]
     Positioned(left/top/width/height = bgRect)

  ③ 42 MorphCells (via CustomMultiChildLayout)
     _MorphLayoutDelegate.performLayout(t):
       for each cell i:
         rect = Rect.lerp(sourceRects[i], destRects[i], t)
         layoutChild(i, BoxConstraints.tight(rect.size))
         positionChild(i, rect.topLeft)

     Each _MorphCell reads styleT from _MorphProgress (InheritedWidget):
       textScale   = compactSize/fullSize + (1 − ratio) × styleT
       cellMargin  = lerp(compactMargin, fullMargin, styleT)
       borderAlpha = lerp(compactOpacity, fullOpacity, styleT)
       alignment   = lerp(Alignment.center, Alignment.topCenter, styleT)
       borderRadius = lerp(compact, full, styleT)

     Theme colors (dividerColor, adjacentColor) are computed ONCE per
     frame inside AnimatedBuilder and threaded down via _MorphProgress —
     prevents 42× Theme.of calls per animation tick.

  ④ Month title overlay
     titleRect = Rect.lerp(sourceTitleRect, destTitleRect, t)
     MorphMonthTitle: font size and nav-arrow spread both lerp with styleT
     Nav arrows fade and spread out from the title centre as styleT → 1

  ⑤ Weekday header
     weekdayRect = Rect.lerp(sourceWeekdayRect, destWeekdayRect, t)
     MorphWeekdayHeader: letter labels expand to full labels with styleT
```

All geometry is pre-snapped in `_MorphAnimationLayerState.initState` — the `build` method does only arithmetic, no measurement, no theme lookups beyond a single `Theme.of` per frame.

---

## 6. Full runtime timeline

```
Login
  │
  ├─ ms 0:    AppShell renders, CalendarMorphWarmup begins
  ├─ frame 1: GPU compiles forward morph shaders (opacity 1/255)
  ├─ frame 2: GPU rasterises forward path
  ├─ frame 3: GPU compiles reverse morph shaders (morphReverse=true)
  ├─ frame 4: GPU rasterises reverse path → warmup done, widget removed
  └─ ms 800:  WeatherChartTransitionWarmup begins (separate shader set)

User navigates to Calendar
  │
  └─ frame 1 (first layout pass, year or month view):
               LayoutBuilder → _refreshLayoutCache(constraints.biggest)
               CalendarLayoutCache.compute():
                 12 tile Rects  (arithmetic)
                 12 × 42 source-cell Rects  (arithmetic + TextPainter)
                 12 Matrix4s  (arithmetic)
                 42 dest-cell Rects  (arithmetic + TextPainter)
               → all geometry stored in _layoutCache before any tap is possible

User taps "June"
  │
  └─ same frame as tap:
       _onMonthTapped reads 4 values from _layoutCache (~0 µs)
       setState() commits morph state
       addPostFrameCallback schedules controller.forward()
     next frame:
       controller.forward(from: 0) fires
       _MorphAnimationLayer renders at t=0
     600 ms later:
       animation completes → _isZooming = false → month view steady state

User clicks Year (Back)
  │
  └─ same frame as tap:
       _onReverseToYear reads all geometry from _layoutCache (~0 µs)
       setState() + addPostFrameCallback
     next frame:
       controller.forward(from: 0) fires
       _MorphAnimationLayer renders at t=0 (morphReverse=true)
     600 ms later:
       animation completes → _mode = year
```

---

## 7. Data flow diagram

```
CalendarLayoutCache (computed on first LayoutBuilder pass)
  ┌──────────────────────────────────────────────────────┐
  │  areaSize: Size                                      │
  │  tileBounds[0..11]: Rect    ─────────────────────────┼─▶ morphTileRect
  │  tileSourceRects[0..11]: List<Rect>  ────────────────┼─▶ sourceRects (forward)
  │                                       ────────────────┼─▶ destRects (reverse)
  │  tileZoomMatrices[0..11]: Matrix4   ─────────────────┼─▶ yearMatrixTween
  │  destRects: List<Rect>  ─────────────────────────────┼─▶ destRects (forward)
  │                                       ────────────────┼─▶ sourceRects (reverse)
  └──────────────────────────────────────────────────────┘

_CalendarPageState morph fields (snapshot at tap time)
  _morphSourceRects, _morphDestRects, _morphTileRect,
  _morphAreaSize, _yearMatrixTween, _morphMonth,
  _morphEvents, _morphIndicators
        │
        ▼
  _MorphAnimationLayer(controller, yearTween, sourceRects, destRects, ...)
        │
        ▼  per-frame (AnimatedBuilder, t = easeInOutCubic)
  ┌─────────────────────────────────────────────────────────┐
  │  Transform(matrix lerped 16 floats) → yearGrid          │
  │  Positioned(bgRect lerped)          → Card              │
  │  CustomMultiChildLayout(42 Rects lerped) → _MorphCells  │
  │  Positioned(titleRect lerped)       → MorphMonthTitle   │
  │  Positioned(weekdayRect lerped)     → MorphWeekdayHeader│
  └─────────────────────────────────────────────────────────┘
```

---

## 8. Key source files

| File | Responsibility |
|---|---|
| `lib/features/calendar/calendar_page.dart` | All animation state, `CalendarLayoutCache`, `CalendarMorphWarmup`, `_MorphAnimationLayer`, `_MorphCell`, `_MorphLayoutDelegate` |
| `lib/features/calendar/calendar_grid.dart` | `MonthTitleHeader.dayCellRects`, `_YearGrid` layout constants |
| `lib/features/calendar/calendar_day_grid.dart` | `WeekdayHeaderRow.totalHeight`, `MonthDayCellStyle`, `monthDayGridWeekdayHeaderGap` |
| `lib/features/shell/app_shell.dart` | Hosts `CalendarMorphWarmup` and `WeatherChartTransitionWarmup` at login |
| `lib/features/shell/weather_chart_transition_warmup.dart` | Weather chart shader warmup (delayed 800 ms) |
