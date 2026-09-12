# Finance — Breakdown Drill-Down, Tag Colors, Sidebar Menus & Local Prefs — HLD

Spending-breakdown **click-to-focus** (tag co-occurrence + category → all tags), **curated app-wide tag palette** (regenerate existing colors), **Bill Radar / Budget** right-click menus (edit / delete / duplicate / log payment / view expenses), **device-local** persistence of finance chrome prefs, and **live-only tags** in category (and budget) pickers.

Related: `lib/features/finance/finance_analytics_view.dart`, `lib/domain/services/finance_analytics.dart`, `lib/features/finance/finance_page.dart`, `lib/features/finance/finance_bill_radar.dart`, `lib/features/finance/finance_budget_panel.dart`, `lib/core/utils/journal_tags.dart` (`colorForTag`), `lib/core/soft_delete/soft_delete_toast.dart`, tag color table / `tagColorsProvider`.

Status: **design** (not implemented).

---

## 1. Goals

- Let the user **focus** a spending-breakdown slice (legend row or pie segment) to see how that bucket breaks down by related tags — without double-counting in the **unfocused** chart.
- Keep Category vs Tag as the top-level grouping; focus is an overlay on whichever mode is active.
- Replace ugly hash-RGB tag colors with a **fixed curated palette** assigned by stable hash index; **regenerate all** stored tag colors on rollout.
- Add right-click (and long-press parity via existing `ContextMenuRegion` patterns) on **sidebar** bills and budgets.
- Remember finance chrome prefs across app restarts **on this device only**.
- Category (and budget) tag pickers list only tags that still appear on **live** finance transactions.

## 2. Non-goals (v1)

- Free-form / per-tag color picker UI (palette assignment only).
- Separate color namespaces per feature (same tag **string** → same color everywhere; pickers stay feature-scoped by **vocabulary**).
- Text search box for breakdown tags (superseded by click-to-focus).
- Advancing subscription due date from any path other than **Log payment → successful save**.
- Ledger full-text search beyond the budget **View expenses** tag filter.
- Persisting breakdown **focus** (filter chip) across restarts — only the prefs in §7.
- Changing how soft-deleted transactions appear in the ledger/analytics (still excluded by default list APIs).

---

## 3. Product decisions (locked)

| Decision | Choice |
|----------|--------|
| **Unfocused breakdown** | Unchanged: each expense → **exactly one** bucket via **first tag** (tag mode) or that tag’s **category** (category mode). Pie sums to month expenses. |
| **Focus entry** | Click **legend row** or **pie slice**. |
| **Tag-mode focus** | Among txs in that primary-tag bucket, show co-tag breakdown (§4.2). |
| **Category-mode focus** | Among txs in that category bucket, show **every tag** on those txs with **full amount per tag** (budget-style; slice sum may exceed category total) (§4.3). |
| **Focus chrome** | Small text: `Filtering: {label}` (tag without `#` in chart chrome, matching current legend style). **Click text → clear focus** (no separate ✕). |
| **Empty focus / $0** | Still show single-bucket UI with **$0.00** center when focused amount is zero (should be rare if entered via a visible slice). |
| **Tag colors** | Fixed curated palette; `index = hash(tag) % palette.length`; **rewrite all** existing `TagColorRecord`s once on migrate. |
| **Color keying** | Global by tag string (today’s table). Journal `#beach` does **not** appear in finance pickers; if the same string is used in both features, color matches. |
| **Bill menu** | Edit, Delete, Duplicate, Log payment. |
| **Budget menu** | Edit, Delete, View expenses. |
| **Delete** | Soft-delete + `softDeleteWithUndo` toast (both). |
| **Log payment** | Open expense modal prefilled (amount, note = bill name, date = today, tags empty). On **successful save only**, advance bill due (§5.3). Cancel → no advance. |
| **Duplicate bill** | Copy name / amount / period / color / note; new id; **`anchorDueDate = today`** (local calendar date). |
| **View expenses** | Switch to **Ledger**, filter **all-time** expenses that `tags.contains(budget.tag)`; clear control on ledger (§5.4). |
| **Chrome prefs** | Persist Category/Tag, Ledger/Analytics/Goals, cash-flow granularity — **device-local only** (§7). |
| **Cash-flow segments** | Existing enum: **Weekly / Monthly / Yearly** (not a separate Daily mode). |
| **Category / budget tag vocab** | Live transaction tags only (+ currently selected on edit). **No** `tagColors.keys` ghosts (§8). |

---

## 4. Spending breakdown focus

### 4.1 Shared UX

- Month window unchanged: current calendar month `[from, to)`.
- Deposits never appear.
- Unfocused: keep `spendingBreakdown(..., groupByCategory: …)` as today.
- Focused: replace the multi-slice “share of month” chart with the **focused** series for that bucket (§4.2 / §4.3).
- **Filter affordance:** above or beside the chart, muted text `Filtering: {label}`. Entire text is tappable → clears focus, restores unfocused series for the current Category/Tag mode. No separate ✕ — same pattern as the ledger tag filter chip.
- Switching **Category ↔ Tag** clears focus.
- Switching finance tab away and back may keep focus in memory for the session; **do not** persist focus to disk.
- Legend under the chart lists the **focused** slices (same take-top-N behavior as today unless the focused set is small — show all focused slices up to a reasonable cap, e.g. 12; overflow “Other” only if needed).
- Pie center: **focused parent total** (sum of expenses in the parent bucket), formatted with `formatCents`, not the sum of child slices when those can double-count (category focus).

### 4.2 Tag mode — co-tag drill-down

**Parent bucket:** expenses this month whose **primary tag** (first tag) equals the focused tag `P` (case rules: match existing tag comparisons; prefer the same normalization used when storing tags).

**Child slices (exclusive, sums to parent):** for each such transaction:

1. Let `others = tags.where((t) => t != P)` preserving order.
2. If `others` is empty → attribute full `amountCents` to slice **`P`** (the “just this tag” portion).
3. If `others` is non-empty → attribute full `amountCents` to slice **`others.first`** (first co-tag).

Colors: each child label uses `tagColors[label]`, fallback `kBreakdownFallbackColor`.

**Further clicks while focused:** clicking a child slice **re-roots** focus to that tag name (same rules as focusing from the unfocused tag pie). Filter text updates to the new tag. No multi-level breadcrumb in v1.

**Why exclusive secondary:** the unfocused chart already hid co-tags to avoid double-count; the drill-down answers “of the money parked under `#food`, how much was only food vs carried `#thai` / `#drink` as an extra tag,” and the focused pie still reads as a true partition of the parent total.

### 4.3 Category mode — all tags in category

**Parent bucket:** expenses this month whose primary tag falls in focused category `C` (same `containsTag(primaryTag)` rule as unfocused category grouping). Untagged / uncategorized slices remain unfocused-only entry points; focusing **Uncategorized** / **Untagged** is allowed if those slices are clicked:

- **Uncategorized:** primary tag present but in no category → child slices = all tags on those txs (budget-style).
- **Untagged:** no tags → focused view is a **single** grey slice / solid pie with parent total (nothing to subdivide). Filter text `Filtering: Untagged`; click to clear.

**Child slices (budget-style, may exceed parent):** for each expense in the parent bucket, for **each** tag on the transaction, add full `amountCents` to that tag’s slice. A `$30` `#food #thai` expense adds $30 to `food` and $30 to `thai`.

Center label / hover total = **parent category total** (exclusive). Optional subtle hint is unnecessary in v1 if the legend amounts can sum higher than center — implementers should use center as source of truth for “spent in this category.”

**Further clicks:** clicking a tag child slice switches the segmented control to **Tag** mode and focuses that tag (§4.2). Clears category focus in favor of tag focus.

### 4.4 Analytics helpers

Extend `lib/domain/services/finance_analytics.dart` (names flexible):

```text
List<BreakdownSlice> spendingBreakdownFocusedByTag(
  txs, { from, to, required String tag, required Map tagColors })

List<BreakdownSlice> spendingBreakdownFocusedByCategory(
  txs, { from, to, required FinanceCategory category, required Map tagColors })
```

Keep unfocused `spendingBreakdown` behavior and tests; add unit tests for:

- Primary-only vs co-tag exclusive split (§4.2).
- Multi-tag full count under category (§4.3).
- Empty month / empty focus → empty list or zero-total single slice as UI expects.

### 4.5 Widget state

Replace ephemeral-only `_groupByCategoryProvider` wiring with persisted Category/Tag (§7). Add in-memory focus state, e.g.:

```text
sealed class BreakdownFocus {}
class BreakdownFocusNone
class BreakdownFocusTag({ required String tag })
class BreakdownFocusCategory({ required String categoryId }) // or name+id
```

Pie hit-testing / legend `InkWell` / chart touch callback sets focus; filter text clears it.

---

## 5. Sidebar context menus (Ledger insights)

Target: **Bill Radar** tiles and **Budget** tiles in `_InsightsSidebar` (wide) / stacked insights (narrow) — not ledger transaction rows (those already have convert / duplicate / delete).

Use the same `ContextMenuRegion` + `ContextMenuItem` pattern as `_TransactionRow`.

### 5.1 Bills / subscriptions

| Item | Behavior |
|------|----------|
| **Edit** | `showSubscriptionModal(..., existing: sub)` (same as tap). |
| **Delete** | Soft-delete + undo toast; invalidate `subscriptionsProvider`. Message via `deletedMessage(sub.name, fallback: 'bill')` (or equivalent). |
| **Duplicate** | Upsert new `Subscription`: new id, `createdAt`/`updatedAt` now, `version: 0`, copy name/amount/period/color/note, **`anchorDueDate` = today’s local date** (time normalized like other finance dates). |
| **Log payment** | §5.3. |

### 5.2 Budgets

| Item | Behavior |
|------|----------|
| **Edit** | `showBudgetModal(..., existing: budget)` (same as tap). |
| **Delete** | Soft-delete + undo toast; invalidate `budgetsProvider`. |
| **View expenses** | §5.4. |

Restore paths mirror transaction undo: rebuild entity clearing `deletedAt`, `restoreVersionFrom`, invalidate providers. Prefer extracting small helpers next to existing modal delete buttons so modal delete and menu delete share one undo path (modal can switch to toast undo for consistency, or menu-only toast in v1 — **prefer toast undo everywhere** for these two types when touched).

### 5.3 Log payment

1. Open expense `showFinanceTransactionModal` with a **create draft** (extend API):  
   - `type: expense`  
   - `amountCents: subscription.amountCents`  
   - `note: subscription.name`  
   - `occurredAt: today`  
   - `tags: []`  
   User may edit before save.
2. If the user **cancels** / dismisses without save → **no** subscription write.
3. If save **succeeds** → advance due date:

```text
paidDue = subscription.nextDue(now)
newAnchor = nextDueDate(paidDue, subscription.period, dayAfter(paidDue))
```

i.e. roll the paid occurrence forward by one billing period so the radar’s next due is the following cycle. Upsert subscription with `anchorDueDate: newAnchor`, bump `updatedAt` / `version`. Invalidate `subscriptionsProvider`.

Do **not** invent tags for the expense. Do **not** auto-save without the modal.

### 5.4 View expenses (budget → ledger filter)

1. Set finance view mode to **Ledger** (persisted pref updates).
2. Set device-session (and optionally persisted — **session-only in v1**) ledger filter: `expenseTagFilter = budget.tag`.
3. Ledger list shows only expenses (`TransactionType.expense`) whose `tags` contain that tag (**all time**, any month). Deposits hidden while filter active. Day headers with no remaining rows omit.
4. **Clear filter:** chip or text in the ledger header area, e.g. `Expenses tagged #dining_out` (whole control tappable — **no** separate ✕), always visible while filter ≠ null. Clearing restores full ledger.

Filter is independent of breakdown focus. Leaving Ledger for Analytics/Goals may keep the filter so returning to Ledger still filtered; clearing is explicit. **Do not** sync this filter.

---

## 6. Tag colors — curated palette

### 6.1 Assignment

Replace raw `colorForTag` RGB mash:

```text
// journal_tags.dart (or dedicated tag_palette.dart)
const kTagPalette = <int>[ /* 12–24 hand-picked ARGB colors, WCAG-friendly on light/dark chips */ ];

int colorForTag(String tag) =>
    kTagPalette[tag.hashCode.abs() % kTagPalette.length];
```

Keep the function name so call sites (finance persist, journal persist, suggestions, etc.) stay stable.

Palette rules: distinct hues, avoid near-black / near-white, readable at chip alpha overlays. Not derived from accent (accent changes must not reshuffle tags).

### 6.2 Migration / regenerate all

On first launch after this feature (version flag or “palette generation” int on a local stamp / one-shot migration):

1. Load all `TagColorRecord`s.
2. For each tag, `setTagColor` / upsert with `colorForTag(tag)` (new palette), bump `updatedAt` / `version` so **sync** propagates the refresh to other devices.
3. Mark migration done so it does not loop.

New tags continue to persist color on first use (existing `_persistTagColors` paths) using the new `colorForTag`.

### 6.3 Scope reminder

- **Storage:** one global map (unchanged).
- **Pickers / suggestions:** finance lists finance live tags only; journal lists journal tags only — `#beach` from journal never appears in the category modal unless a **live finance** transaction also uses it.

---

## 7. Device-local chrome prefs

Persist across process death / app restart, **never** via synced `AppSettings` / Firestore.

| Key | Values | Default (first install) |
|-----|--------|-------------------------|
| `financeViewMode` | `ledger` / `analytics` / `goals` | `ledger` |
| `financeBreakdownGroupByCategory` | `true` / `false` | `true` (Category) |
| `financeCashFlowGranularity` | `weekly` / `monthly` / `yearly` | `monthly` |

**Storage:** small JSON file under application documents (same family as `FileLeetCodeScratchDraftStore` / jobs track drafts), e.g. `finance_ui_prefs.json`. Provider loads once at finance entry (or app start); writes debounce on change.

Wire:

- `_financeViewModeProvider` ← hydrate from store; write on segment change.
- `_groupByCategoryProvider` ← hydrate; write on Category/Tag change.
- `_granularityProvider` ← hydrate; write on Weekly/Monthly/Yearly change.

Invalid / missing file → defaults above.

---

## 8. Live tags only (category + budget pickers)

### 8.1 Bug

`FinanceCategoryModal._knownTags()` unions transaction tags **and** `tagColors.keys`. Colors outlive soft-deleted / purged transactions, so deleted tags still appear when building categories.

Budget modal `_suggestedTags()` has the same `colorOnly` ghost path.

### 8.2 Fix

- **Category modal:** known tags = tags on **live** transactions from `transactionsProvider` (already non-deleted) ∪ `_selectedTags` (so editing a category does not strip tags that are selected but temporarily unused). **Do not** add `colors.keys`.
- **Budget suggestions:** usage-ranked tags from live transactions only; drop `colorOnly` / `colors.keys` branch. Typing a brand-new tag remains allowed via the text field.

Optional follow-up (out of scope): GC unused `TagColorRecord`s — not required for v1.

---

## 9. Implementation sketch

| Area | Touch |
|------|--------|
| Analytics math | `finance_analytics.dart` + tests |
| Breakdown UI | `finance_analytics_view.dart` — focus state, filter text, slice/legend onTap |
| Prefs store | New `finance_ui_prefs_store.dart` (file JSON) + providers |
| Tag palette | `journal_tags.dart` (+ migration one-shot near settings/tag bootstrap) |
| Category / budget pickers | `finance_category_modal.dart`, `finance_budget_modal.dart` |
| Bill / budget menus | `finance_bill_radar.dart`, `finance_budget_panel.dart` |
| Log payment | Extend `showFinanceTransactionModal` draft API; advance subscription after save |
| Ledger filter | `finance_page.dart` — filter provider, header clear chip, row filtering |
| Soft delete | Shared undo helpers for subscription/budget |

---

## 10. Test plan

- [ ] Unfocused tag/category pies still partition month total (existing cases).
- [ ] Focus tag with only primary-tagged txs → single child slice = parent.
- [ ] Focus tag with `#food` + `#food #thai` txs → exclusive split food vs thai; sums to parent.
- [ ] Focus category with multi-tag txs → each tag gets full amount; center = category exclusive total.
- [ ] Filter text clears focus; Category↔Tag clears focus.
- [ ] Click category child tag → Tag mode + that tag focused.
- [ ] Prefs survive restart; not present in settings sync / export payload.
- [ ] Palette migration rewrites all tag colors; new tags use palette.
- [ ] Category modal omits tags only present in `tagColors` after txs deleted.
- [ ] Bill: duplicate gets anchor = today; delete undo restores; log payment cancel does not advance; save advances next due one period.
- [ ] Budget: view expenses filters ledger all-time; clear restores; delete undo works.

---

## 11. Open follow-ups (explicitly out of v1)

- Breadcrumb for multi-step drill (`food › thai`).
- Persisting ledger tag filter or breakdown focus.
- Accent-linked tag shades / user color picker.
- Auto-tagging log-payment expenses from bill name.
- Purging orphan tag color rows.
