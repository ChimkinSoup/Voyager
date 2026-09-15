# Finance — Contribution Room (Registered / Limited Assets) — HLD

Generic **contribution-room** tracking for assets with an annual contribution cap (TFSA today; RRSP / FHSA / similar later). Extends existing `Asset` + `AssetValuation` net-worth tracking with a shared **contribution group**, per-asset contribution/withdrawal flows, ledger linkage, and CRA-accurate same-year withdrawal deferral.

Related: `lib/domain/models/finance_models.dart` (`Asset`, `AssetValuation`, `FinancialTransaction`, `settledTransactions`), `lib/features/finance/finance_asset_modal.dart`, `lib/features/finance/finance_analytics_view.dart` (`_AssetRow`), `lib/features/finance/finance_transaction_modal.dart`, `lib/features/finance/finance_page.dart` (ledger + `ContextMenuRegion`), `lib/data/database/app_database.dart` (`AssetsTable`, `AssetValuationsTable`), sync / soft-delete conventions.

Status: **implemented** (2026-09-14). Deviations from the original draft, decided before implementation:

- **Rollover is derived, not stored.** No `lastRolloverYear`, nothing written on Jan 1. The room keeps only its enable-time baseline; every year is recomputed from it plus events (§8). A late-synced December contribution corrects the next year by itself.
- **Annual limits are per year** (`annualLimits: [{fromYear, cents}]`), so editing the limit changes this year and later without rewriting a year that already rolled.
- **`baselineAsOf` is an instant**, not a day, so a contribution logged earlier the same day isn't subtracted twice.
- **Transfers are two legs with kinds `transferOut` / `transferIn`** sharing a `transferGroupId` (§14.1), so direction is readable per asset.
- **History list** of this year's events (edit / delete with undo) lives in the asset sheet — the only way to correct a transfer, which has no ledger row.
- **Valuation step is inline** in the Contribute / Withdraw / Transfer sheets: the new value tracks `previous ± amount` until the user types in it.
- **Linked ledger rows:** Convert and Duplicate are hidden; the type toggle is locked; amount/date/note edits update the event but not the valuation (a note says so).
- **Deleting an asset keeps its room events** (room math is by `roomId`).

---

## 1. Goals

- Let the user track **how much contribution space remains** for any contribution-limited investment, not TFSA-only.
- Support **one logical limited account across multiple `Asset` rows** (e.g. TFSA at two brokerages) via a shared **contribution room (group)**.
- Record **contributions and withdrawals** with dates; keep room math **CRA-accurate for withdrawals** (same-year withdrawals restore room on the next Jan 1).
- Keep room math on **cash in/out only** — never on market gains/losses.
- Every contribute/withdraw goes through a **short valuation step** so the app distinguishes room events from market revaluations.
- Surface room on the **asset row** as a subtle **progress bar with `X/Y` inside**; no dedicated Finance-page section.
- Initiate contribute/withdraw from the **asset context menu** (not the main deposit UI), still creating a **ledger** row linked to the asset.

## 2. Non-goals (v1)

- Built-in CRA / government annual-limit tables or jurisdiction-specific tax engines.
- RRSP earned-income rules, FHSA / RESP special cases beyond the generic room model.
- Monthly over-contribution **penalty** estimates.
- Prior-year history browser / year selector UI (current calendar year only).
- Crowding the normal expense/deposit modal with “link to asset / contribution” controls.
- Multi-currency or FX conversion (single constant currency unit; treat as CAD-equivalent).
- Alerts, scheduled contributions, tax CSV export, next-year projection UI.
- Changing how plain `AssetValuation` edits work for market marks (unchanged path).

---

## 3. Product decisions (locked)

| Decision | Choice |
|----------|--------|
| **Model shape** | Generic contribution room; not TFSA-branded in the domain. |
| **Asset tie-in** | Extend `Asset` with optional `contributionRoomId`. |
| **Multi-asset** | Many assets → one `ContributionRoom`. Room is shared. |
| **Room formula** | `remaining = yearCapacity − settledContributionsInYear` across **all** member assets. Not derived from valuations or `max(asset value)`. |
| **Limits input** | Manual `annualLimitCents` + on-enable `initialRemainingCents`. No government presets. |
| **Withdrawals** | Tracked; **do not** restore room until **Jan 1** of the following calendar year. |
| **Valuation** | Contribute/withdraw flow always creates/updates valuation via an explicit step (prefilled `latest ± amount`, user-editable). |
| **Over-contribution** | Soft warn only; show remaining **or** over-by amount. No hard block. No penalty math. |
| **Year boundary** | Auto-roll **Jan 1** (calendar year) for every room. |
| **Enable** | User enters **current remaining room** (+ annual limit + room name). No full history backfill. |
| **Ledger entry point** | Asset **context menu** only (right-click / long-press parity). Not the global deposit button. |
| **Ledger types** | Contribution → `TransactionType.deposit`. Withdrawal → `TransactionType.expense`. Both linked to the asset/event. |
| **UI chrome** | Subtle progress bar on asset row/detail; `X/Y` text inside bar; **current year only**. |
| **Currency** | Single non-FX unit (constant); no cross-currency room math. |
| **Post-dated events** | Count toward room only when the calendar date **arrives** (same settled-day rule as the ledger). |
| **Internal transfers** | First-class **room-neutral** move between two assets in the **same** room (pitfall avoidance). |

### 3.1 Contribution groups — confirmation

Yes: a **`ContributionRoom`** (contribution group) is the right abstraction.

- Room holds the **shared** annual limit + year baseline / remaining math.
- Each limited `Asset` points at one room (or none).
- Contributions to **any** member asset reduce the **same** remaining.
- Valuations and net-worth stay **per asset**.

**Not** “take the max asset value and subtract.” Valuations are wealth; room is contribution headroom. The “cap” is the room’s **year capacity**, and usage is the **sum of settled contribution events** on members.

---

## 4. Domain model

### 4.1 `ContributionRoom`

Soft-deletable entity (same id / version / deletedAt conventions as other finance models).

| Field | Role |
|-------|------|
| `id` | UUID |
| `name` | User label (e.g. “TFSA”, “FHSA”) |
| `annualLimitCents` | Manual yearly add-on used at Jan 1 rollover and for copy into year state |
| `baselineRemainingCents` | Remaining room as of `baselineAsOf` (set on enable and on each Jan 1 roll) |
| `baselineAsOf` | Calendar date the baseline was established |
| `lastRolloverYear` | Calendar year of last successful auto-roll (null until first Jan 1 after enable) |

Optional note/color later; not required for v1.

### 4.2 `Asset` extension

| Field | Role |
|-------|------|
| `contributionRoomId` | Nullable FK → `ContributionRoom`. Null = no room tracking. |

Joining a room does not change valuations. Leaving a room keeps historical events but stops showing the bar (see §10).

### 4.3 `AssetRoomEvent`

Append-only style history (soft-deletable), analogous to `GoalAllocation` but richer.

| Field | Role |
|-------|------|
| `id` | UUID |
| `assetId` | Asset the cash hit |
| `roomId` | Denormalized room id at write time (stable if asset later unlinked) |
| `kind` | `contribution` \| `withdrawal` \| `transfer` |
| `amountCents` | Always **≥ 0** magnitude |
| `occurredAt` | Local wall-clock date/time; day drives settled vs upcoming |
| `transactionId` | Nullable FK → ledger `FinancialTransaction` (required for contribution/withdrawal; null for transfer) |
| `valuationId` | FK → `AssetValuation` created/updated by this flow |
| `counterAssetId` | For `transfer` only: the other leg’s asset |
| `transferGroupId` | For `transfer`: shared id pairing the two legs (or single row with from/to — see §7.3) |
| `note` | Optional |

**Kind semantics**

| Kind | Room impact | Valuation | Ledger |
|------|-------------|-----------|--------|
| `contribution` | Uses room when settled | Prefill `latest + amount` (editable) | Deposit, linked |
| `withdrawal` | No same-year restore; add-back next Jan 1 | Prefill `latest − amount` (editable) | Expense, linked |
| `transfer` | **None** | −amount on source, +amount on dest (each editable in flow) | **None** (not a cash-flow event) |

### 4.4 Year capacity & remaining (canonical math)

Let `today` be the local calendar day. An event is **settled** iff its `occurredAt` calendar day is **≤ today** (same rule as `settledTransactions`: exclude post-dated until the day arrives).

For room `R` in calendar year `Y`:

```
yearCapacity(R, Y) =
  if baselineAsOf is in Y:
    baselineRemainingCents
      + sum(settled contributions in Y with occurredAt < baselineAsOf)
        // normally 0 — v1 does not backfill pre-enable history
  else:
    // should not happen if rollover kept baseline in current year
    recompute via rollover (§8)

settledContributions(R, Y) =
  sum(amountCents of settled events where
      roomId = R, kind = contribution, year(occurredAt) = Y)

settledWithdrawals(R, Y) =
  sum(amountCents of settled events where
      roomId = R, kind = withdrawal, year(occurredAt) = Y)

remaining(R, Y) = yearCapacity(R, Y) − settledContributions(R, Y)

used(R, Y) = settledContributions(R, Y)
```

- **Transfers** never enter these sums.
- **Withdrawals** never increase `remaining` in year `Y`.
- **Over**: `remaining < 0`; UI shows over-by `|remaining|`. Soft warn on save when the new contribution would make `remaining < 0` (still allow save).

**Progress bar `X/Y`**

- `X = used(R, currentYear)`
- `Y = yearCapacity(R, currentYear)`
- Fill fraction = `clamp(X / Y, 0, 1)` when `Y > 0`; if `Y == 0` and `X == 0`, empty bar; if over, bar full + over styling.
- Label inside bar: `formatCents(X)/formatCents(Y)` (compact), with over state e.g. full bar + over-by text adjacent or in the same label.

Every asset row linked to `R` shows the **same** shared `X/Y` (not per-asset contribution share) in v1.

### 4.5 Enable / attach flow

When enabling room tracking on an asset (create room or join existing):

1. **Create room:** name, `annualLimitCents`, `initialRemainingCents` (= current remaining). Set `baselineRemainingCents = initialRemainingCents`, `baselineAsOf = today`.
2. **Join existing room:** pick room; asset gets `contributionRoomId`. No second baseline.
3. Pre-enable CRA history is **not** entered; `initialRemainingCents` is the source of truth for “what’s left now.”

---

## 5. Valuation vs room (pitfalls)

| Pitfall | v1 behavior |
|---------|-------------|
| Valuation ↑ mistaken for contribution | Only `AssetRoomEvent` kind `contribution` uses room. Plain valuation edits in the asset modal never touch room. |
| Same-year withdrawal frees room | Withdrawals deferred to next Jan 1 add-back (§8). |
| Per-asset room with multiple TFSAs | Forbidden for shared accounts: use one `ContributionRoom`. |
| Ignoring carry-forward | Captured inside `initialRemainingCents` / baseline; Jan 1 adds unused remaining + limit + withdrawal add-backs. |
| Internal TFSA→TFSA transfer counted twice | `transfer` kind is room-neutral (§7.3). |
| Post-dated contributions | Unsettled until calendar day arrives; excluded from `used` / `remaining` until then. Upcoming may show in event lists later; not required on the bar in v1. |

**Contribute / withdraw short flow (required)**

1. Amount, date, optional note (deposit-like fields; origin/tags optional — prefer sensible defaults: origin = asset or room name).
2. **Valuation step:** show previous value, proposed new value (`± amount`), editable field. Copy explains this records the cash move, not a market mark.
3. On save (atomic from UX perspective):
   - upsert `AssetRoomEvent`
   - upsert linked `FinancialTransaction` (deposit or expense)
   - upsert `AssetValuation` (`asOf` = event day; same-day replace pattern as today’s asset modal)
   - soft-warn if contribution leaves `remaining < 0`

Market-only updates: existing asset valuation UI, unchanged.

---

## 6. Ledger linkage

### 6.1 Entry points

On `_AssetRow` (and asset detail if present), `ContextMenuRegion` items when `contributionRoomId != null`:

- **Contribute…**
- **Withdraw…**
- **Transfer…** (only if ≥ 2 live assets share this room)
- **Edit contribution room…** / **Detach from room…** (can live under asset edit modal instead)

When `contributionRoomId == null`:

- **Track contribution room…** → create or join.

Do **not** add contribution toggles to the global add-expense/deposit chrome.

### 6.2 Ledger appearance

- Contribution → deposit row; amount positive; appears in ledger / income analytics like other deposits.
- Withdrawal → expense row; appears like other expenses.
- Both store a link: prefer `transactionId` on the event **and** optional `assetId` / `roomEventId` on the transaction if the schema can accept a nullable FK without crowding the normal modal (normal modal leaves them null).

### 6.3 Edit / delete consistency

| Action | Behavior |
|--------|----------|
| Soft-delete room event | Soft-delete linked ledger tx (if any); do **not** auto-delete valuations (history matters). Remaining recalculates. |
| Soft-delete linked ledger tx | Soft-delete the room event. Same recalculation. |
| Undo soft-delete | Restore both sides when paired. |
| Edit event amount/date | Update paired ledger fields; re-run valuation step or offer “adjust valuation”; recalc room. |
| Edit ledger amount on a linked tx | Update paired event amount; same valuation offer. |

Net worth uses latest valuation; deleting an event does not rewind valuations automatically (user can correct via asset modal). Document this in UI copy if needed.

---

## 7. Flows

### 7.1 Contribute

Asset menu → Contribute → amount/date/note → valuation confirm → save → deposit + event + valuation. Soft-warn if over.

### 7.2 Withdraw

Asset menu → Withdraw → amount/date/note → valuation confirm (`latest − amount`) → save → expense + event + valuation. Room unchanged this year; withdrawal queued for Jan 1 add-back.

### 7.3 Transfer (same room)

Asset menu → Transfer → pick destination asset (same room) → amount/date → two valuation confirmations (source −, dest +) → save **two** linked `transfer` legs (shared `transferGroupId`) **or** one event with `assetId` + `counterAssetId` (implementation choice; prefer two legs if valuations are per-asset).

- No ledger rows.
- No room change.
- Block transfers across different rooms or to assets with no room.

### 7.4 Detach / delete room

- **Detach asset:** clear `contributionRoomId`; past events remain for audit but asset bar hides; room math still counts events whose `roomId` matches until we explicitly exclude detached assets — **v1 rule:** room sums by `roomId` on events (not by current asset membership), so historical contributions still count. New events require membership.
- **Soft-delete room:** detach all member assets; hide bars; keep events for sync/audit; remaining UI gone.

---

## 8. January 1 auto-rollover

> **As implemented:** nothing is written. `roomYearSummary` (in `contribution_room_models.dart`) rolls forward from the baseline year on every read, using the same formula per year with `annualLimitFor(Y+1)`. The stored-rollover design below is kept for the record.

Applies to all rooms (generic model uses **calendar year**, matching TFSA). ~~Run lazily on first finance read/write on/after Jan 1 when `lastRolloverYear < currentYear` (and `baselineAsOf.year < currentYear`).~~

For each room, when rolling from year `Y` → `Y+1`:

```
endRemaining = remaining(room, Y)           // may be negative (over)
addBack     = settledWithdrawals(room, Y) // CRA: prior-year withdrawals
capacity(Y+1) = endRemaining + annualLimitFor(Y+1) + addBack
```

- Re-entering "remaining right now" in the room sheet re-baselines to that figure as of now.
- Device offline across New Year, or events syncing late: the figures are recomputed from events on every read, so they are always current.
- No UI year picker in v1; in a new year the bar shows `X = 0` until new contributions settle.

---

## 9. UI

### 9.1 Asset row progress

- Only if asset has `contributionRoomId`.
- Subtle bar under name/value (or inline with value column): fill by `used/capacity`, label `X/Y` centered or leading inside the bar.
- Over: full fill + distinct color; show over-by near the bar (e.g. `Over by $Z` muted).
- Remaining tooltip / semantics: `Remaining $R` or over-by; do not show penalty copy.
- All members of a room show the **identical** shared bar values.

### 9.2 Asset / room editors

- Asset modal: section “Contribution room” — None / Create / Join existing; fields for limit + remaining when creating.
- Room edit: rename, edit `annualLimitCents` (affects **future** Jan 1 rolls; does not rewrite current `baselineRemainingCents` unless user also edits remaining explicitly).

### 9.3 Warnings

- On contribute save if post-save `remaining < 0`: non-blocking banner/dialog “This puts the room over by $Z.”
- Optional muted over state on the bar always when `remaining < 0`.

---

## 10. Persistence & sync

- New Drift tables: `contribution_rooms_table`, `asset_room_events_table`.
- `assets_table.contribution_room_id` nullable text FK.
- Optional `financial_transactions_table.room_event_id` (or `asset_id`) nullable for reverse lookup.
- Soft delete + version + Firestore collection mapping consistent with ADR 001 / existing finance sync.
- Migration: additive; existing assets unaffected (`contributionRoomId = null`).

Repository APIs (sketch):

- `watchContributionRooms`, `upsertContributionRoom`, `softDeleteContributionRoom`
- `watchAssetRoomEvents({roomId?, assetId?})`, `upsertAssetRoomEvent`, …
- `contributeToAsset` / `withdrawFromAsset` / `transferBetweenAssets` — orchestration helpers that write event + tx + valuation together
- `ensureContributionRoomRollover(now)` — idempotent Jan 1 roll

Domain helpers (pure, testable):

- `settledRoomEvents(events, now)`
- `roomYearCapacity`, `roomUsedCents`, `roomRemainingCents`
- `withdrawalAddBackCents(events, year)`
- `rolloverBaseline(...)`

---

## 11. Analytics / net worth interaction

- Net worth continues to use **latest `AssetValuation` per asset** — unchanged formula.
- Contribute/withdraw change wealth only through the valuation written in the flow (and later manual marks).
- Ledger deposit/expense from these flows **do** affect net cash-flow / income / spending charts like any other tx. Acceptable in v1; transfers intentionally omitted from ledger to avoid fake cash flow.
- Budgets: withdrawal expenses may hit budgets if tagged; default tags empty unless user sets them in the flow.

---

## 12. Testing plan (acceptance)

- Enable room with remaining `R`, limit `L`; bar shows `0/R`; contribute `C` settled → `C/R`, remaining `R−C`.
- Two assets one room: contribute on A and B; both bars show summed used.
- Withdraw `W` same year: remaining unchanged; valuation prefill decreases; next Jan 1 remaining increases by `W` (+ `L` + prior remaining).
- Post-dated contribution: excluded until its day; then included without re-entry.
- Transfer A→B same room: valuations move; remaining unchanged; no ledger rows.
- Over-contribute: save succeeds; soft warn; bar over state.
- Plain valuation edit: room unchanged.
- Soft-delete contribution: ledger tx soft-deleted; remaining restores.
- Rollover idempotent across multiple app opens on Jan 1.
- Asset without room: no bar; no contribute menu (only “Track contribution room”).

---

## 13. Implementation sketch (ordered)

1. Domain models + pure room math + unit tests (incl. rollover + settled-day).
2. Drift tables + migration + repository + sync collection mapping.
3. Orchestration: contribute / withdraw / transfer writers.
4. Asset modal: attach/create/join room.
5. Asset row: progress bar + context menu flows (reuse transaction modal patterns / slim variant).
6. Lazy rollover hook on finance providers.
7. Widget / integration tests for bar + menu + delete pairing.

---

## 14. Open implementation choices (non-blocking)

These do not change product behavior; pick during implementation:

1. Single `transfer` row with `counterAssetId` vs two legs + `transferGroupId`.
2. Whether linked ledger txs store `assetId`, `roomEventId`, or both.
3. Exact progress-bar styling tokens (reuse budget/goal bar patterns if any).
4. Whether room edit of `annualLimitCents` offers an optional “also set remaining” field.

---

## 15. Summary formula (cheat sheet)

```
remaining = baselineRemaining(year) − settledContributions(year)
yearCapacity (Y in bar) = baselineRemaining(year)
used (X in bar)         = settledContributions(year)

Jan 1:
  baseline' = remaining(year) + annualLimit + settledWithdrawals(year)
```

Market value ≠ contributions. Transfers ≠ contributions. Withdrawals restore **next** calendar year only.
