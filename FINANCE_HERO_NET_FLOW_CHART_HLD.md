# Finance — Hero Net-Flow Line Chart & Expand Overlay — HLD

Replace the finance page hero’s **cumulative, single-color sparkline** with a **signed daily-net line chart** (segment-colored by sign, fill to the zero axis), keep the hero **calendar-month** summary number, add a **vs last-period delta**, and add a **LeetCode-style camera-zoom expand** with a larger chart, day hover, income/expense dual series, range chips, category filter, year heatmap, and jump-to-ledger-day.

Related: `lib/features/finance/finance_page.dart` (`_HeroSection`, `_SparklinePainter`, `_sparklineSeries`), `lib/features/finance/finance_ui_prefs.dart`, `lib/domain/models/finance_models.dart` (`signedCents`, `TransactionType`), `lib/features/leetcode/leetcode_activity_card.dart` (`openLeetCodeActivityView`, overlay zoom), `lib/features/leetcode/leetcode_activity_chart.dart`, `lib/features/leetcode/leetcode_activity_calendar.dart`, `lib/core/widgets/chart_hover_bubble.dart`, `kIncomeGreen` / theme `colorScheme.primary`.

Status: **design** (not implemented).

---

## 1. Goals

- Show **how the month is going day by day** as a signed line: net up = earning, net down = spending, with **per-segment color** (green vs main accent) and **fill to the zero axis**.
- Keep the hero a **glance** surface: month net + delta + line shape; **no day hover / no day tap** on the compact card.
- Grow the same card into a **LeetCode-parity expand overlay** for study: axes, hover, range, category filter, dual income/expense series, year heatmap, jump to ledger day.
- Persist **expand range** device-locally with the existing finance chrome prefs.

## 2. Non-goals (v1)

- Day-level hover or hit-testing on the **compact** hero (expand only).
- Goal progress or budget pace in the hero.
- Changing Analytics tab charts (cash-flow bars, breakdown pie, net worth) — those stay as they are.
- A new `TransactionType.transfer` (does not exist today). Expense + deposit via `signedCents` is the whole daily net.
- Syncing expand range (or other new chrome) through AppSettings / Firestore — **device-local only**.
- Editing transactions from the expand overlay.
- Multi-category filter (single category or All).

---

## 3. Product decisions (locked)

| Decision | Choice |
|----------|--------|
| **Y-axis** | **Signed daily net** (deposits positive, expenses negative). Not absolute-value-with-color-only. |
| **Series (compact)** | One line: **daily net** for the active window. |
| **Compact window** | **Current calendar month**, from month start through **today** inclusive. No future days of the month. |
| **Hero number** | Calendar-month net (unchanged meaning); color **≥ 0 → green**, else accent. |
| **Vs last period** | Under the hero number: **MTD vs prior MTD** (§5.2). |
| **Zero / empty day** | Daily net `0` (no txs, or income = expense) → **green** (`>= 0`). |
| **Sign-change segment** | **Split at the zero crossing**; each half painted with its side’s color + fill. |
| **Fill** | Soft gradient **from the line down/up to the zero (x) axis**, green or accent matching that segment. |
| **Compact interaction** | **No** day hover, **no** day tap. Whole card is tappable → **open expand** (LeetCode activity card pattern: hover outline + expand icon). |
| **Ledger tag filter** | Does **not** affect hero or expand data (hero/expand always unfiltered by ledger tag). Category filter inside expand is separate (§7.3). |
| **Soft-deleted txs** | Excluded (existing live list APIs). |
| **Future-dated txs** | Included only when their **calendar day is inside the active window**; window never extends past **today**, so dates after today do not appear until that day. |
| **Sparse history** | Still draw **month start → today** (or range start → today). Days with no txs are **0**, not gaps. Do **not** invent days after today. |
| **Expand shell** | Copy LeetCode: `PageRouteBuilder` + camera zoom from hero rect → inset card, scrim tap / Escape / close to shrink back. Prefer reusing shared zoom helpers where they already exist (`leetCodeZoomRect`, motion curves). |
| **Expand content** | Larger signed net chart + day hover bubble + income/expense dual series + range chips + category filter + year calendar heatmap + jump to ledger day. |
| **Persist** | Expand **range** preference in `FinanceUiPrefs` (device-local). |

---

## 4. Compact hero

### 4.1 Layout

Keep the existing hero chrome (surface tint, radius, border). Structure:

1. Label: `Net flow · {MMMM}` (current month).
2. Large signed month-net amount (existing `formatCents(..., signed: true)`), green / accent by sign.
3. **Delta row** under the amount (§5.2).
4. Line chart on the right (wider than today’s 180×56 if needed so month day-count remains readable; still glance-scale, not Analytics-scale).
5. Small expand affordance (e.g. `arrowsOut`) that strengthens on hover, matching LeetCode.

### 4.2 Compact chart rules

- Points: one per calendar day in `[monthStart, today]`.
- Value: sum of `signedCents` for live txs on that local calendar day.
- Polyline with **zero baseline** implied by fill-to-axis (baseline may be drawn as a hairline if it stays quiet).
- Segment coloring + zero-split + dual-tone fill (§6).
- **IgnorePointer** (or equivalent) over the plot so the card’s tap opens expand and fl_chart / custom painter does not steal hits — same lesson as LeetCode compact chart.

### 4.3 Data vs ledger filter

Hero (and expand) always aggregate from the **full** live transaction list for the window. The ledger tag chip continues to narrow **only** the ledger list, as today.

---

## 5. Hero number & vs last period

### 5.1 Month net

Unchanged formula: sum `signedCents` for txs with `occurredAt` in `[monthStart, nextMonth)`.

Note: the **number** can include future-dated txs still inside this calendar month, while the **compact line** stops at today. That is intentional: the number answers “what have I booked this month”; the line answers “how have the days so far gone.” Call this out in UI only if it becomes confusing; v1 does not add a footnote.

### 5.2 Delta (MTD vs prior MTD)

- **Current MTD:** sum of daily nets from `monthStart` through `today` (same window as the compact line).
- **Prior MTD:** same **day-of-month span** in the previous calendar month: from previous month’s start through `min(today.day, lastDayOfPrevMonth)` on that month.
- Show a short line under the hero amount, e.g. `+\$120 vs last month` / `−\$45 vs last month`, using green/accent by delta sign; `0` → green.
- If prior window has no activity and current is also zero, still show `\$0.00 vs last month` (or equivalent) rather than hiding the row — keeps layout stable.

---

## 6. Segment color, zero-split, and fill

Colors:

- **Net ≥ 0:** `kIncomeGreen` (same green as today’s positive month net).
- **Net < 0:** `Theme.of(context).colorScheme.primary` (main accent).

Geometry:

1. Build points `(dayIndex, dailyNet)`.
2. For each consecutive pair `(y0, y1)`:
   - If both on the same side of zero (including zeros as non-negative): one segment, one color, fill that trapezoid to `y = 0`.
   - If they **straddle** zero: interpolate `t = y0 / (y0 - y1)`, split at that x; first half uses color/fill of `y0`’s side, second half uses `y1`’s side.
3. Fill is a **soft vertical gradient** from the segment’s line color (low alpha) toward transparent at the zero axis — same spirit as today’s sparkline fill, but **per segment** and **toward zero**, not toward the bottom of the widget.

Implementation note: today’s `_SparklinePainter` is a single-path CustomPainter. v1 may stay CustomPainter (multi-path) or move to `fl_chart` `LineChart` with multiple `LineChartBarData` clips; prefer whichever reuses expand hover more cleanly. Expand will almost certainly want `fl_chart` + `ChartHoverBubble` like Analytics / LeetCode.

---

## 7. Expand overlay

### 7.1 Shell (copy LeetCode)

- Tap hero → capture `RenderBox` rect → `openFinanceNetFlowView(context, anchorRect)` (name flexible).
- Opaque-false route, zero-duration page transition; **animation owned by overlay** (`AnimationController` ~300ms, spring curve, reduced-motion → fade only).
- Scrim tap, Escape, system back, and close button all **reverse then pop** (guard against double-close).
- Card laid out at final size and **scaled/translated** from the hero rect so chart + year calendar do not reflow through intermediate widths (same comment as LeetCode).

### 7.2 Layout inside the card

Top → bottom:

1. Title row + close.
2. **Range chips** + **category filter** control.
3. Series **legend** (Net / Income / Expense) — LeetCode capsule pattern: tap one to solo; tap again to clear → all on.
4. Expanded chart (~160px+ height band; must clear hover bubble).
5. **Year calendar heatmap** takes remaining height (responsive month-tile columns like LeetCode activity calendar).

### 7.3 Range chips

| Chip | Window |
|------|--------|
| **Month** | `[monthStart, today]` (matches compact hero). |
| **7d** | Last 7 calendar days through today. |
| **30d** | Last 30 calendar days through today. |
| **90d** | Last 90 calendar days through today. |
| **YTD** | `[Jan 1 of current year, today]`. |

- Default when no pref stored: **Month**.
- Changing chip updates chart points immediately; heatmap still shows the **full year** but day intensities / empties follow the same aggregation rules (days outside the selected range remain visible as calendar chrome but are **non-emphasized** or show as empty-of-range — prefer: still show full year grid; days outside range use adjacent-month / muted empty styling; days inside range use net coloring. Tapping a day outside range still allowed for jump-to-ledger if that day has data / exists.)
- Persist selection as `FinanceUiPrefs.heroExpandRange` (enum), device-local, same file/store as existing prefs.

### 7.4 Category filter

- Control: **All** (default) or one `FinanceCategory`.
- Match rule: include a transaction if **any** of its tags is in that category’s tag set (existing `FinanceCategory` membership helper / case rules).
- When filtered, **income, expense, and net** daily buckets only sum matching txs. Deposits with no tags in the category drop out of income for that filter.
- Session-only (do **not** persist category filter in v1).
- Clearing / switching category does not clear range.

### 7.5 Chart series (expand)

Daily buckets for the selected range (+ category filter):

- **Net** — signed daily net; **segment-colored** + zero-split fill (same rules as compact).
- **Income** — sum of deposit `amountCents` that day (always plotted as **≥ 0**).
- **Expense** — sum of expense `amountCents` that day (always plotted as **≥ 0**).

Legend behavior (LeetCode-like):

- `null` selection → all three visible.
- Solo Net / Income / Expense → only that series.
- Heatmap follows the **solo series** when one is selected; when all are shown, heatmap uses **Net** (§7.6).

Hover (expand only):

- Nearest day; `ChartHoverBubble` (or LeetCode bubble pattern) showing **date**, **income**, **expense**, **net** for that day (filtered amounts when a category is active).
- Compact hero never shows this.

Zero baseline / light horizontal grid: **expand only**.

### 7.6 Year calendar heatmap

- Reuse calendar grid primitives (`calendar_day_grid` / LeetCode activity calendar structure).
- Each day cell encodes the day’s value with **hue + intensity**:
  - Net mode (default): green if `net >= 0`, accent if `net < 0`; alpha/scale by `|net|` relative to the year’s busiest `|net|` in the active filter (same “rebase on busiest” idea as LeetCode).
  - Income solo: green intensity by income.
  - Expense solo: accent intensity by expense.
- Empty / zero days: very light green tint (consistent with `>= 0 → green`), not accent.
- Hover on a day: bubble with the same income / expense / net breakdown.
- **Tap day → jump to ledger** (§7.7). Chart day tap / bubble action may offer the same jump (at least calendar tap is required).

### 7.7 Jump to ledger day

1. Close the expand overlay (animated reverse).
2. Ensure finance **view mode = Ledger** (`financeUiPrefsProvider.setViewMode`).
3. Scroll the ledger so that day’s header is visible (reuse / extend whatever scroll plumbing the ledger sliver already has; if none, add a one-shot scroll-to-day request on `_FinanceViewState`).
4. If that day has no ledger rows, still scroll to where the day header would sit / nearest neighboring day — prefer showing the day header with empty state rather than failing silently.

Do **not** apply a sticky tag filter as part of this jump.

---

## 8. Prefs

Extend `FinanceUiPrefs` + JSON file:

| Field | Type | Default | Notes |
|-------|------|---------|-------|
| `heroExpandRange` | enum `month / d7 / d30 / d90 / ytd` | `month` | Device-local only. |

Unrecognized values → default (same resilient `fromJson` style as today).

Do **not** persist: category filter, legend solo, hover state, overlay open.

---

## 9. Domain / pure helpers

Add pure functions (prefer `lib/domain/services/finance_analytics.dart` or a small sibling) so UI and tests share one definition:

- `dailyNetSeries({transactions, from, to})` → `List<{DateTime day, int netCents, int incomeCents, int expenseCents}>` for each calendar day in range (zeros for quiet days).
- `monthToDateNet` / `priorMonthToDateNet` for the hero delta.
- Heatmap max-abs helper for intensity scale.

Use **local calendar midnights** and the same UTC-differencing caution already documented on `_sparklineSeries` (DST-safe day indexing).

---

## 10. Implementation sketch

1. **Pure series + tests** — daily buckets, zero-split segment geometry (unit-test straddling cases), MTD delta.
2. **Compact painter / chart** — replace `_SparklinePainter` cumulative path; wire month window; IgnorePointer; expand icon + tap.
3. **Hero delta UI** under the month net.
4. **Prefs** — `heroExpandRange` plumb through store/notifier.
5. **Expand overlay** — clone LeetCode activity overlay shell; finance-specific detail card body.
6. **Expand chart** — fl_chart + legend + hover bubble + baseline.
7. **Heatmap calendar** — net/income/expense coloring; hover; tap → jump.
8. **Jump-to-ledger** — close + viewMode + scroll coordination.
9. **graphify update .`** after code lands.

Primary files: `finance_page.dart`, new `finance_net_flow_*.dart` widgets (keep page thinner), `finance_ui_prefs.dart`, `finance_analytics.dart` (+ tests), mirror patterns from `leetcode_activity_card.dart` / `leetcode_activity_chart.dart` / `leetcode_activity_calendar.dart`.

---

## 11. Edge cases (accepted)

| Case | Behavior |
|------|----------|
| Today is the 1st | Compact line is a single point — draw a dot / short flat mark; expand still useful via heatmap + ranges. |
| All days zero | Flat zero line in green with light green fill (degenerate fill ok). |
| Huge single-day spike | Autoscale Y to visible days’ min/max; zero axis may sit off vertical center. |
| Category filter empties a day | That day nets to 0 (green) inside the filtered series. |
| Soft-delete while expand open | Live providers rebuild; chart/heatmap update; no special lock. |
| Locale / midnight | Bucket by local Y/M/D of `occurredAt`, consistent with ledger day headers. |
| “Transfer” | N/A — only expense/deposit; both already in `signedCents`. |

---

## 12. Optional features (this pass)

| ID | Feature | Verdict |
|----|---------|---------|
| A | Expand year net heatmap | **Include** |
| B | Expand hover bubble (income / expense / net) | **Include** |
| C | Tap day → scroll ledger | **Include** |
| D | Expand range chips | **Include** |
| E | Zero baseline (expand) | **Include** |
| F | Vs last period under hero number | **Include** |
| G | Dual income/expense series in expand | **Include** |
| H | Goal progress in hero | **Skip** |
| I | Budget pace in hero | **Skip** |
| J | Persist expand range device-locally | **Include** |

---

## 13. Open implementation details (non-blocking)

These do not need product re-litigation; implementer picks the smallest fit:

- CustomPainter vs fl_chart for the **compact** hero (expand should use fl_chart for hover parity).
- Exact chip labels (`Month` vs `This month`, `7D` vs `7 days`).
- Whether days outside the selected range on the year heatmap are muted empty or still show true net but non-interactive — prefer **muted / outside-range styling**, tap still jumps to ledger.
- Shared extraction of LeetCode zoom overlay into a core helper vs copy-paste with finance names — prefer extract if it stays thin; otherwise copy with comments pointing at the LeetCode source of truth.

---

## 14. Success criteria

- Compact hero shows **signed daily net** for **month start → today**, segment colors flip across zero correctly, fill meets the axis.
- Month net number + **MTD vs prior MTD** delta render and color correctly.
- Compact card opens a **LeetCode-style** expand; no day tooling on the compact plot.
- Expand supports range chips, category filter, Net/Income/Expense legend, hover breakdown, year heatmap, jump-to-ledger.
- Expand range survives app restart on that device only.
- Ledger tag filter never changes hero/expand totals.
