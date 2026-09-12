# Finance — Transaction Origin (Store / Source), Ledger Title & Breakdown — HLD

Optional **origin** on each ledger transaction: **Store** for expenses, **Source** for deposits. Combobox suggestions (Jobs company parity) drawn only from **live** transactions of the matching type. Ledger title becomes `Store - Note` with store emphasis. Notes shrink to a **single-line** “what” field so Enter advances Amount → Store/Source → Note → Tags. Analytics gains **by store** (expenses) and **by source** (income).

Related: `lib/features/finance/finance_transaction_modal.dart`, `lib/features/finance/finance_page.dart`, `lib/features/finance/finance_bill_radar.dart`, `lib/features/finance/finance_analytics_view.dart`, `lib/domain/models/finance_models.dart`, `lib/domain/services/finance_analytics.dart`, `lib/features/jobs/jobs_company_field.dart`, `lib/domain/jobs/job_queries.dart`, Drift `FinancialTransactions` table, `firestore_document_mapper.dart` transaction helpers.

Status: **design** (not implemented).

---

## 1. Goals

- Let the user record **where money went** (store) or **where it came from** (source) without a separate managed entity table.
- Suggest only origins that still appear on **actively tracked** (non–soft-deleted) transactions of the **same type**.
- Show a clear ledger title: bold, slightly larger origin + optional short note.
- Keep the add/edit flow fast: single-line note, Enter advances through fields in a sensible order.
- Break down **spend by store** and **income by source** in Analytics.

## 2. Non-goals (v1)

- Separate Stores / Sources admin table, rename/merge UI, or seeded catalogues (unlike Jobs companies).
- Shared suggestion vocabulary across expense and deposit.
- Ledger filter-by-store chip, global search matching origin, CSV export columns, store color chips, or “prefill store from last same-tag expense”.
- Click-to-focus / co-occurrence drill-down while the breakdown is in Store or Source mode (Category/Tag focus behavior unchanged).
- Origin on subscriptions, goals, assets, or budgets themselves (only on the **transaction** created when logging a bill payment).
- Changing soft-delete / undo semantics beyond “deleted rows leave the suggestion pool immediately”.

---

## 3. Product decisions (locked)

| Decision | Choice |
|----------|--------|
| **Domain field** | One nullable string on `FinancialTransaction`: **`origin`**. |
| **UI labels** | Expense → **Store**; Deposit → **Source**. |
| **Required** | Always optional. |
| **Pre-fill on create** | Empty (never invent an origin). |
| **Suggestion pool** | Distinct non-empty `origin` values from live txs with the **same** `TransactionType` only. |
| **Case** | **Case-sensitive**. `Walmart` and `walmart` are different suggestions and different analytics slices. |
| **Trim** | Trim on save; whitespace-only → `null` (same as note). |
| **Soft-delete** | Soft-deleted txs drop out of suggestions immediately; undo restores them. |
| **Type switch in modal** | Switching Expense ↔ Deposit **clears** the origin field and rebuilds suggestions for the new type. |
| **Edit** | Prefill existing origin. |
| **Duplicate** | Copy origin with the rest of the row. |
| **Log payment draft** | `origin = bill name`, **note empty** (replaces today’s `note = bill name`). |
| **Combobox UX** | Full Jobs company parity: open on focus with recents, typeahead, Tab/Enter accept highlight, click select, free text always allowed, most-recently-used ranking, empty query = recents only (§5). |
| **Note field** | **Single-line**; short “what” (e.g. toothpaste, paycheque). Remove list-editing / multiline behavior from this field. |
| **Enter chain** | Amount → Store/Source → Note → Tags. Note Enter advances to Tags (no longer inserts newline). Tags keep existing tag-suggestion Enter rules; Ctrl+Enter still submits. |
| **Ledger title** | See §6. Both empty → keep `Expense` / `Deposit` fallback. |
| **Long origin in ledger** | Single-line row + `TextOverflow.ellipsis` (no hard character cap on storage). |
| **Analytics** | Spending breakdown: third mode **Store**. Income: parallel **by Source** breakdown (§7). |

---

## 4. Data model & sync

### 4.1 Domain

```dart
class FinancialTransaction {
  // …
  final String? origin; // store (expense) or source (deposit); null if unset
  final String? note;   // short “what”; still optional
}
```

- `FinanceTransactionDraft` gains optional `origin` (used by Log payment).
- `copyWith` / equality / tests updated accordingly.

### 4.2 Persistence

- Drift: nullable `origin` text column on the financial transactions table; schema migration.
- Firestore mapper: read/write `'origin'`; missing remote field → `null` (backward compatible).
- No new table. Origins are **derived** at query time from live transactions.

### 4.3 Suggestion query

```
liveOrigins(type) =
  distinct origin
  from live transactions
  where type == type
    and origin != null
    and origin.trim() != ''
  ordered by most recent occurredAt (then updatedAt) among txs carrying that exact origin string
```

- Exact string match for “same” origin (case-sensitive).
- Cap overlay list length like Jobs (`_maxSuggestions = 8`).
- Prefer extracting ranking/filter helpers next to finance analytics/queries (mirror `jobRecentCompanyKeys` / `filterJobCompanies`), not a permanent stores repository.

---

## 5. Transaction modal UX

### 5.1 Field order

1. Type (Expense / Deposit)
2. Amount
3. **Store** or **Source** (label follows type) — combobox
4. **Note** — single-line text
5. Tags
6. Date
7. Add / Save

### 5.2 Combobox (Jobs parity)

Reuse the interaction contract of `JobsCompanyField` (extract a shared free-text combobox **or** a finance-specific twin — implementation choice; behavior must match):

- Opens on **focus** with MRU origins for the current type (if any).
- Typing filters case-**sensitive** substring? **No — filter matching should stay practical:** suggestion **identity** is case-sensitive (two entries can coexist), but **filtering** uses case-insensitive contains so typing `wal` still finds `Walmart`. Ranking: MRU first, then prefix matches, then alphabetical among ties (same shape as Jobs).
- Tab / Enter with list open → fill highlighted suggestion (first Enter fills; second Enter advances — Jobs contract).
- Click → fill and keep focus or advance consistently with Jobs.
- Unknown string is always allowed on save.

### 5.3 Note as single-line

- `maxLines: 1`; Enter → focus Tags.
- Drop note-field list tab / backspace / `applyListEditing` wiring (those exist for multiline prose lists and fight this UX).
- Hint examples: expense `Toothpaste`; deposit `Paycheque`.

### 5.4 Type switch

On Expense ↔ Deposit:

1. Clear origin controller text.
2. Close suggestion overlay if open.
3. Relabel field Store ↔ Source.
4. Reload suggestion list for the new type.

Amount, note, tags, date unchanged.

### 5.5 Save

- `origin`: trim; empty → `null`.
- `note`: trim; empty → `null` (unchanged rule).
- Validation unchanged: amount required and > 0.

### 5.6 Log payment (Bill Radar)

```dart
FinanceTransactionDraft(
  type: expense,
  amountCents: sub.amountCents,
  origin: sub.name,  // was note
  note: null,        // was sub.name
  occurredAt: today,
  tags: const [],
)
```

---

## 6. Ledger title

Build a display model (pure function, unit-testable), e.g. `ledgerTransactionTitle(origin, note, type)`:

| origin | note | Title |
|--------|------|--------|
| set | set | `{origin} - {note}` |
| set | empty | `{origin}` |
| empty | set | `{note}` |
| empty | empty | `Deposit` or `Expense` |

**Typography** (one `Text.rich` / `TextSpan`s; still `maxLines: 1`, `ellipsis`):

- Origin span: ~`bodyMedium` + **one step larger** (e.g. `titleSmall` / `bodyLarge` — match nearby ledger chrome) and **`FontWeight.w600`–`w700`**.
- Separator ` - ` and note span: current ledger note style (`bodyMedium`, regular weight).
- Fallback `Expense`/`Deposit`: same as today’s plain note style (no fake bold).

Prose / markup highlighters are **not** required on this title unless the note field later regains rich text; v1 is plain text.

Empty origin/note means null or whitespace-only after the same trim rules as save.

---

## 7. Analytics — Store / Source breakdown

### 7.1 Spending breakdown (expenses)

Extend the Category / Tag control to a **three-way** mode (replace boolean `breakdownGroupByCategory` with an enum in finance UI prefs), e.g.:

`Category | Tag | Store`

- **Store mode:** each expense in the month window attributes its full `amountCents` to bucket = `origin` if non-empty, else **`No store`** (constant label, fallback color like Untagged).
- Case-sensitive keys: `Walmart` ≠ `walmart`.
- Deposits still excluded.
- Pie still exclusive (one bucket per expense) → slices sum to month expenses.
- Colors: no per-store palette in v1 → `kBreakdownFallbackColor` (or a stable hash into the curated tag palette if already rolled out — prefer one consistent fallback unless tag-palette reuse is trivial).
- **Focus:** entering Store mode **clears** any Category/Tag focus. Clicks on Store slices do **not** open focus drill-down in v1 (non-goal). Switching away from Store restores prior Category/Tag behavior.

### 7.2 Income by source (deposits)

Add a sibling breakdown (same month window, deposit-only):

- Control or section title: **Source** (or “Income by source”).
- Bucket = `origin` if set, else **`No source`**.
- Same exclusivity / sorting / color rules as Store mode.
- No focus drill-down in v1.

Placement: directly under or beside the existing spending breakdown so Category/Tag/Store stays on the expense chart and Source stays on the income chart — do **not** overload one segmented control with both expense and deposit semantics.

### 7.3 Prefs

Persist the spending breakdown mode (Category / Tag / Store) in existing device-local finance UI prefs. Income-by-source needs no extra mode toggle if it is a dedicated chart.

---

## 8. Behaviors & edge cases

| Case | Behavior |
|------|----------|
| Last Costco expense soft-deleted | Costco disappears from Store suggestions until undo/restore or a new Costco expense exists. |
| Deposit with origin `Payroll`, expense with `Payroll` | Each list only sees its own type’s rows; both can exist independently. |
| Clear origin on the only Walmart row | Walmart leaves the suggestion pool. |
| Edit origin Walmart → Target | Suggestions update to Target; Walmart gone if unused. |
| Very long origin | Stored in full; ledger and chart labels ellipsize. |
| Duplicate then delete original | Duplicate keeps origin; suggestions still include it via the copy. |
| Modal open while another tx soft-deleted | Suggestion list should watch live data (provider/stream) so it updates if practical; acceptable to refresh on next focus if live watch is costly — prefer live. |

---

## 9. Testing

- Pure title helper: all four origin/note combinations + whitespace-only + fallback by type.
- Origin suggestion ranking / distinct / type-split / soft-delete exclusion (case-sensitive distinct).
- Modal: field order Enter chain; type switch clears origin; save trim → null.
- Log payment draft: origin = bill name, note null.
- Analytics: store buckets sum to expenses; source buckets sum to deposits; empty → No store / No source; case-sensitive split.
- Mapper / Drift: origin round-trip; missing Firestore field → null.
- Regression: single-line note no longer inserts list markers on Tab.

---

## 10. Implementation sketch (ordered)

1. Domain + Drift migration + Firestore mapper + repository mapping.
2. `ledgerTransactionTitle` + ledger row `Text.rich`.
3. Origin suggestion helpers + combobox in transaction modal; reorder fields; single-line note; Enter chain; type-switch clear.
4. Wire draft / duplicate / log payment.
5. Analytics enum + Store spending mode + Income-by-source chart + prefs migration from old boolean.
6. Tests above; `graphify update .` after code lands.

---

## 11. Open implementation choices (non-blocking)

- Extract shared `FreeTextCombobox` from Jobs vs finance-local copy of `JobsCompanyField` behavior.
- Exact text style tokens for origin vs note (stay within existing theme sizes).
- Whether Store-mode slice colors hash into the curated palette or stay gray fallback.

No further product questions required to implement v1 as specified.
