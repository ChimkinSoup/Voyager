# Audit — Finance transaction origin (+ related fixes)

Review of the uncommitted diff against `FINANCE_TRANSACTION_ORIGIN_HLD.md`, plus the bundled settled/upcoming ledger, DST day-label, and LeetCode `Example:` fixes.

Scope: working-tree finance/leetcode code (not `graphify-out/`, not `FINANCE_HERO_NET_FLOW_CHART_HLD.md`).

---

## Summary

The origin feature largely matches the HLD: domain + Drift 109 + Firestore write, suggestion helpers, combobox, ledger title, Store/Source analytics, prefs migration, log-payment draft, and solid tests. The settled/upcoming work is consistent across hero, budgets, cash flow, breakdowns, and net worth. Independently confirmed defects: Convert keeps origin, `copyWith` cannot clear origin, type switch does not close the overlay, and the modal DST Yesterday hole. Ranking / Firestore `containsKey` are weaker (see notes on those findings).

---

## Findings

### 1. High — Context-menu Convert keeps origin across Expense ↔ Deposit

**Where:** `lib/features/finance/finance_page.dart` (`_convert`)

**Failure mode:** Convert flips only `type`. An expense titled store `Walmart` becomes a deposit still carrying `origin: Walmart`, so it appears under **Income by Source** as “Walmart”. The modal’s Expense/Deposit control clears origin on purpose (HLD §3 / §5.4); Convert does not.

**Evidence:** `_convert` uses `transaction.copyWith(type: flipped, …)` and never clears `origin`. Modal path is `_setType` → `_originController.clear()`.

**Fix direction:** Clear origin on Convert (same vocabulary split as the modal), or open the edit sheet instead of flipping in place.

---

### 2. Low (disputed) — Origin suggestion ranking vs HLD Jobs parity

**Where:** `lib/domain/services/finance_origins.dart` — `filterTransactionOrigins`  
**HLD:** §5.2 — “Ranking: MRU first, then prefix matches, then alphabetical among ties (same shape as Jobs).”

**Failure mode:** Filtering keeps raw MRU order among substring matches. Typing `wa` can highlight `Kowalski` (contains `wa`) ahead of `Walmart` (prefix). Jobs’ `filterJobCompanies` re-ranks prefix before non-prefix, then alpha. `test/finance_origins_test.dart` locks `'WAL'` → `Kowalski`, `Walmart`, `walmart`.

**Counterpoint:** An independent pass argued this is acceptable because the finance pool is MRU-only (no unused catalogue), so preserving MRU among matches matches Jobs’ primary key when ranks are unique. Treat as HLD literal miss / polish unless you want prefix boost.

**Fix direction:** Mirror `filterJobCompanies` sort after the contains filter (MRU rank map + prefix boost + case-insensitive name).

---

### 3. Low (disputed) — `mergeTransactionFromRemote` treats missing `origin` like explicit null

**Where:** `lib/core/sync/firestore_document_mapper.dart` — `mergeTransactionFromRemote`

**Failure mode:** New optional fields elsewhere use `data.containsKey(...)` so a pre-field remote keeps local, while an explicit null clears (see `JobStage.colorValue`, `JobSeason.archivedAt`). Origin uses `data['origin'] as String?`, so a winning remote document with no `origin` key always becomes `null`.

**Counterpoint:** Independent pass filed this as non-issue: HLD §4.2 says missing remote field → null; uploads use `merge: true`; covered by `secondary_collections_sync_test`. Remaining risk is only a local-only origin losing to a newer remote that never had the key.

**Fix direction (defense in depth):**

```dart
origin: data.containsKey('origin')
    ? data['origin'] as String?
    : local?.origin,
```

---

### 4. Medium — Tags Enter saves; HLD says keep prior Tags Enter rules / Ctrl+Enter submits

**Where:** `lib/features/finance/finance_transaction_modal.dart` — Tags `onSubmitted: (_) => _save()`  
**HLD:** §3 Enter chain — “Tags keep existing tag-suggestion Enter rules; Ctrl+Enter still submits.”

**Failure mode:** Previously Tags Enter moved focus to Note. Now bare Enter on Tags (popup closed) saves and closes. Tag popup Enter still accepts a suggestion (tested). This is a product change beyond the HLD, locked in by `finance_enter_chain_test.dart` (“Enter in Tags saves”).

**Open question:** Intentional UX, or should Tags Enter be a no-op / stay on Tags while Ctrl+Enter (and Add) submit?

---

### 5. Medium — Transaction modal date chip still uses 24h Yesterday (DST hole)

**Where:** `lib/features/finance/finance_transaction_modal.dart` — `_formatDate`

**Failure mode:** The ledger’s day headers were fixed to calendar-day math (`DateTime(y, m, d - 1)`), but the modal’s date chip still does `today.subtract(const Duration(days: 1))`. Around DST spring-forward / fall-back, that can miss yesterday’s midnight day key, so the chip shows a full date instead of **Yesterday**.

**Evidence:**

```dart
// finance_page.dart — fixed
if (day == DateTime(today.year, today.month, today.day - 1)) return 'YESTERDAY';

// finance_transaction_modal.dart — still Duration
if (d == today.subtract(const Duration(days: 1))) return 'Yesterday';
```

**Fix direction:** Same calendar-day comparison as the ledger (optional: add Tomorrow for consistency).

---

### 6. Low — Type switch does not explicitly close the origin overlay

**Where:** `_TransactionModalState._setType` + `FinanceOriginField.didUpdateWidget`  
**HLD:** §5.4 step 2 — “Close suggestion overlay if open.”

**Failure mode:** Switching type clears the controller and refreshes an open list for the new type’s origins instead of closing it. Usually fine; if the new type has suggestions, the overlay stays open under the new label.

**Fix direction:** Clear origin via a field callback that calls the same path as Escape (`_removeOverlay`), or close whenever `label` / type pool changes.

---

### 7. Medium — `FinancialTransaction.copyWith` cannot clear `origin` (or `note`) to null

**Where:** `lib/domain/models/finance_models.dart`

**Failure mode:** `origin: origin ?? this.origin` means `copyWith(origin: null)` is a no-op. Restore already rebuilds a full `FinancialTransaction` because the same pattern blocks clearing `deletedAt`. Modal save builds a fresh instance, so today’s UI is fine; fixing Convert (finding 1) via `copyWith(origin: null)` will silently keep the old store/source.

**Fix direction:** Optional `clearOrigin` / `Value` wrapper, or reconstruct like restore when clearing.

---

### 8. Low — HLD doc status still says unimplemented

**Where:** `FINANCE_TRANSACTION_ORIGIN_HLD.md` line 7 — `Status: **design** (not implemented).`

**Fix direction:** Flip to implemented / shipped-with-deltas once this lands.

---

### 9. Info — Ledger note still renders prose; HLD §6 called plain text optional

`LedgerTitleText` runs `proseReadRanges` on the note span. HLD said highlighters were not required for v1. Not a bug — keep if you want `**floss**` in notes; otherwise simplify.

---

### 10. Info — Store mode still shows “Manage categories”

Spending breakdown trailing control stays visible in Store mode. Harmless; slightly odd chrome.

---

## Related fixes (non-origin)

| Change | Notes |
|--------|--------|
| `settledTransactions` + Upcoming header | Used on hero net, budgets, cash flow, spending/income breakdowns, net worth. Future rows stay visible under Upcoming / TOMORROW. |
| Ledger Yesterday / Tomorrow via calendar day | Correct DST fix on the ledger. Modal chip still broken — see finding 5. |
| LeetCode `Example:` / line-anchored heading | Matches bare `Example:`; `For example:` prose excluded. Tests cover both. |

---

## Open questions (for author)

1. **Tags Enter → save** — Keep as shipped, or revert to “Enter does not submit; Ctrl+Enter / button does” per HLD?
2. **Convert type** — Should Convert clear origin the same way the modal type switch does?
3. **Suggestion ranking** — Is MRU-only among substring hits intentional, or should prefix-first Jobs ranking land before ship?
4. **Future-dated origins** — Should Upcoming / post-dated rows contribute to Store/Source suggestions, or only settled live rows?
5. **Sync `containsKey('origin')`** — Agree this should match JobStage/JobSeason optional-field merge, or accept missing-key → null given merge uploads?

---

## Not treated as bugs

- Prefs migration from `financeBreakdownGroupByCategory` → `FinanceBreakdownMode` (tested).
- Soft-delete / undo restores `origin` via full reconstruct.
- Duplicate copies `origin`; log payment sets `origin: sub.name`, `note: null`.
- Income chart via title dropdown (not a fourth spending segment) matches HLD §7.2.
- Store mode clears focus and disables slice drill-down.
- Case-sensitive origin identity + case-insensitive filter matching.
- Drift migration 109 nullable `origin` with no note→origin backfill (correct).
