# Rankings — Decimal Score Input HLD

Replace interactive star rating with a **visual-only star strip** plus a **number → score popover** (rollers + type-in), supporting **0.1 / 0.5 / 1.0** steps per score surface.

Related: `RANKINGS.md` (domain / scoring), `RANKINGS_UI.md` (layout; quick-rate and overall-row interactions superseded here), todo time popover (`time_selector_popovers.dart` / `voyager_time_picker_spinner.dart`).

This document **supersedes** score-input UX in:

- `RANKINGS.md` §3.3 (quick-rate), §3.4–3.5 (overall / child / field scoring UI), §4.1 half-step booleans, §5 scoring step rules, §7.2 where it implies star interaction
- `RANKINGS_UI.md` §7.2 (hover quick-rate stars), §8.1–8.2 (child score display interaction), §9.3 (`RankingOverallRow` tap-to-clear / hover preview)

Domain lifecycle (ranked ⇔ non-null overall, demote on clear, average-from-children, sync, import/export) remains in `RANKINGS.md` unless this doc explicitly changes it.

---

## 1. Goals

- Allow **tenth-precision** scores (`0.1`) without relying on star hit-testing.
- Stars are **display only** — accurate fractional fill; never set a score.
- Every scorable surface uses the same **click number → popover** pattern: parent overall, child overall, every custom field (parent and child), and list-row quick-rate.
- Per-surface **precision mode**: integers / half / tenths, with optional inherit from overall.
- Match todo time-popover interaction patterns where applicable (type-in + rollers, focus into text on open, draft until dismiss).

---

## 2. Non-goals

- Arrow-key navigation inside the score popover
- Animated star fill on change
- `/max` suffix beside the number (`8.4/10`)
- “Snap to half” chip inside tenths mode
- Changing ranked ⇔ unranked semantics except: **`0` / `0.0` is a valid ranked score** (non-null)

---

## 3. Precision model

### 3.1 Modes

| Mode | Step | Right roller |
|------|------|----------------|
| **Integers** | `1.0` | Hidden |
| **Half** | `0.5` | `0`, `5` only |
| **Tenths** | `0.1` | `0`–`9` |

### 3.2 Where mode lives

| Surface | Setting |
|---------|---------|
| Parent overall | Category: `parentScorePrecision` (replaces `parentHalfStepsEnabled`) |
| Child overall | Category: `childScorePrecision` (replaces `childHalfStepsEnabled`) |
| Parent custom field | Field def: `inheritOverallPrecision` (default **true**) + optional `scorePrecision` |
| Child custom field | Field def: `inheritChildOverallPrecision` (default **true**) + optional `scorePrecision` |

**Labels in template UI**

- Parent fields: checkbox **Same as overall**
- Child fields: checkbox **Same as child overall**

When inherit is on, the field’s effective mode tracks the corresponding overall setting. When off, the field uses its own `scorePrecision`.

**Migration:** map existing `*HalfStepsEnabled == true` → `half`; `false` → `integers`. New default for freshly created categories/fields: **half** (preserves prior product default of half-stars on). Tenths is opt-in.

### 3.3 Effective step helpers

Replace `rankingScoreStep(halfSteps:)` / `roundRankingScore(..., halfSteps:)` with precision-aware equivalents, e.g. `rankingScoreStep(RankingScorePrecision)` and `roundRankingScore(..., precision:)`.

All producers of scores go through rounding: popover commit, average-from-children, rescale, mode-change re-round, mouse-wheel nudge.

---

## 4. Score range & semantics

| Rule | Behavior |
|------|----------|
| Floor | `0` (including `0.0`) |
| Ceiling | `scoreMax` (`5` or `10`) |
| Unscored | `null` — UI shows `-` |
| Scored zero | stored `0` — UI shows `0`, **never** `-` |
| Parent overall `0` | **Ranked** (score present) |
| Clear overall | `null` → demote to **in progress** (unchanged) |
| New template field | Display midpoint; **store null** until scored (unchanged) |
| Display format | `formatRankingScore`: **strip trailing zeros** in all modes (`8`, `8.5`, `8.4`; never `8.0`) |

Midpoint for roller default / wheel-first-nudge / field preview still uses `scoreMax / 2` snapped to effective step (e.g. out of 5: tenths/half → `2.5`, integers → `2`; out of 10 → `5`).

---

## 5. Visual stars (read-only)

- `RankingStars` (and list/editor uses) become **non-interactive**: no hover preview, no click/drag to set.
- Fill remains **continuous per star**: on a `/10` scale, `8.3` = eight full stars + **30%** of the ninth; `8.4` = **40%** of the ninth. Same idea on `/5`.
- **No minimum sliver** — very small fractions may be hard to see; prefer honest fill over a fake minimum.
- Accent color and sizing rules from `RANKINGS_UI.md` still apply where they do not conflict.

---

## 6. Number control (all score surfaces)

### 6.1 Affordance

| State | Display | Interaction |
|-------|---------|-------------|
| Unscored | `-` | Click → open popover (draft starts at midpoint; **not** stored until commit) |
| Scored | formatted number | Click → open popover at **current** value |
| Archived / view-only | same display | No open |

Surfaces: ranked/unranked list rows (overall), editor overall rows, custom fields, child list score slot, any other score chip that previously used interactive stars.

### 6.2 Extra gestures (number, popover closed)

| Gesture | Behavior |
|---------|----------|
| **Mouse wheel** | Nudge by effective step and **commit immediately**. If unscored, first nudge = midpoint ± one step (direction of wheel), then commit. Clamp to `[0, scoreMax]`. |
| **Long-press** | Clear immediately (no confirm) → `null`. **No-op** if already null. Parent overall clear demotes to in progress. Same semantics as Clear in popover / context menu. |

### 6.3 Context menus

Keep **Clear score** on parent/child context menus (unchanged placement from `RANKINGS_UI.md`). Popover also exposes Clear. Clicking the number never clears (number only opens / focuses the popover).

---

## 7. Score popover

Patterned after the todo **time** popover: compact anchored popover, text field + rollers, draft until commit.

### 7.1 Open

- Click number opens popover.
- **Focus text field immediately** with **select-all**.
- If current value is null: rollers + text show **midpoint draft** (not persisted).
- If current value is set: rollers + text show that value.
- **Only one** score popover at a time. Opening another dismisses the first using the same rules as outside-click (§7.5).

### 7.2 Layout

```
┌─────────────────────────────────────┐
│  [ text field: e.g. 8.4 ]   Clear   │
│                                     │
│     [ left ]  .  [ right ]          │
│   (0…max)         (hidden | 0/5 | 0–9)
└─────────────────────────────────────┘
```

- **Integers:** right roller omitted; text accepts whole numbers only (still clamp/snap on blur).
- **Half / tenths:** decimal point between rollers; right roller options per mode.
- Clear control inside popover (not on the number button).

### 7.3 Rollers & carry

Left: `0 … scoreMax`. Right: per mode (or absent).

**Carry (like time spinner minutes → hours):**

| Action | Result |
|--------|--------|
| Right rolls up past last digit | Left +1, right → `0` (or half’s `0`) |
| Right rolls down past first digit | Left −1, right → max digit for mode (`9` or `5`) |
| At `scoreMax.0`, user scrolls past ceiling | Allow overscroll feel, then **snap back to `scoreMax.0` when scroll settles** |
| At `0.0`, user scrolls below floor (left or right) | Allow overscroll feel, then **snap back to `0.0` when scroll settles** |
| Half mode at `0.5`, left rolls down | **Stay at `0.5`** — the left roller moves the whole part only, and never drops the fraction |
| Half mode at `scoreMax - 0.5`, left rolls up | `scoreMax.0` — not the roller dropping the fraction but the draft clamping to the top of the scale |

Snap-back runs **only after scroll settles** (ballistic end / item settled), not on every intermediate tick.

### 7.4 Text ↔ rollers (live within draft)

- Rolling updates the text field **live** (draft only).
- Valid typing updates rollers **live**.
- **Blur** of the text field: **clamp + snap** to mode and sync rollers (still draft; does not close).
- Invalid / empty partial input on blur: snap to last valid draft or midpoint if somehow empty — never leave rollers desynced.

### 7.5 Commit vs cancel (draft until dismiss)

Rollers and text are **always a draft** until a commit action. No live persistence while scrolling. Wheel / long-press on the closed number (§6.2) are separate immediate commits and do not use this table.

| Action | Unscored, no edits | Unscored, edited | Scored, no edits | Scored, edited |
|--------|--------------------|------------------|------------------|----------------|
| Outside click | Commit midpoint | Commit draft | Keep same | Commit draft |
| Enter | Commit midpoint | Commit draft | Commit current | Commit draft |
| Esc | Stay `null` | Restore `null` | Keep previous | Restore previous |
| Clear | No-op close | Clear → `null` | Clear → `null` | Clear → `null` |

“Edited” = any roller move or text change from the values shown at open. Opening an unscored field shows a midpoint draft; outside-click and Enter both commit that midpoint. **Esc** is the abort path back to `null`.

### 7.6 Persistence on commit

- Write rounded score to the correct entity/field.
- Parent overall: null → demote; non-null (including `0`) → ranked.
- Custom fields: store score; null means unscored for sort-exclusion rules.
- Update stars + number from committed value only (not from draft), except optional ephemeral preview of draft on the number **inside** the open row if cheap — not required for v1; committed value is source of truth for the strip behind the popover.

---

## 8. Mode changes, rescale, averages

### 8.1 Changing precision (overall or field)

If any stored scores for that surface (or inheriting fields when overall changes) are not already on the new step:

1. **Warn** (confirm dialog): values will be re-rounded.
2. On confirm: re-round all affected stored scores with `roundRankingScore` for the new precision.
3. On cancel: revert the mode toggle.

When overall mode changes, every field with inherit enabled is affected the same way (warn once covering overall + inheriting fields).

Untoggling inherit and selecting a different mode: same warn + round if existing values need it.

### 8.2 Rescale field (`5` ↔ `10`)

Unchanged flow, precision-aware end step:

1. Warn.
2. Rescale position on the scale (`value * toMax / fromMax`).
3. Round to the field’s **effective** precision.

### 8.3 Average from children

Mean of children with non-null overall; round to **parent overall** precision (not child field modes). Excludes unscored children. User may override afterward; does not auto-update later.

### 8.4 Score range filter

Slider / bounds snap to the **category parent overall** step (or document the active filter scale as parent overall). When tenths is on, allow `0.1` granularity.

---

## 9. UI placement map

| Location | Before | After |
|----------|--------|-------|
| List row quick-rate | Hover/click stars | Number → popover; stars visual only |
| Editor overall | Interactive stars; tap number to clear | Number → popover; Clear in popover/menu/long-press; stars visual |
| Custom fields | Interactive stars | Same number → popover |
| Child list | Number (and/or stars) | Number → popover; stars if shown are visual only |
| Template editor | Half-star toggles only | Precision: integers / half / tenths; per-field inherit + override |

---

## 10. Data model deltas

### `RankingCategory`

- Replace `parentHalfStepsEnabled` / `childHalfStepsEnabled` with:

```text
parentScorePrecision: integers | half | tenths
childScorePrecision: integers | half | tenths
```

### Template field definition

```text
inheritOverallPrecision: bool   // parent template; default true
inheritChildOverallPrecision: bool  // child template; default true
scorePrecision: integers | half | tenths?  // used when inherit is false
```

Effective precision resolver:

```text
parent overall → category.parentScorePrecision
child overall → category.childScorePrecision
parent field → inherit ? parentScorePrecision : field.scorePrecision
child field → inherit ? childScorePrecision : field.scorePrecision
```

### Storage

Scores remain `double?`. Valid committed values are always on the effective step grid after round. Sync / export include new enum fields; import maps legacy booleans as in §3.2.

---

## 11. Accessibility & polish

- Number control: semantic label includes field name + current score or “unscored”.
- Popover: text field labeled for screen readers; Clear as a button.
- Snap-back and carry should feel like the existing time spinner (high-friction fixed extent, settle then correct).
- Prefer reusing shared spinner building blocks from `voyager_time_picker_spinner.dart` where practical (extract shared wheel if needed) rather than a one-off rankings-only scroll physics.

---

## 12. Testing (acceptance)

1. Stars never change score on hover/click/drag on any surface.
2. Tenths: can set `8.3` and `8.4`; stars show distinct fills; number formats without trailing zero.
3. Half: right roller only `0`/`5`; typing `8.3` blurs to snapped half; commit stores snapped value.
4. Integers: no right roller; `8.4` → `8`.
5. Floor `0` / ceiling `scoreMax` with settle snap-back; carry across integer boundary; half `0.5` + left down → stays `0.5`.
6. Unscored `-` → open → Esc → still `-`; Enter or outside without edits → midpoint committed.
7. Clear via popover, long-press, and context menu → null; parent overall demotes.
8. Wheel on `-` commits midpoint±step; wheel on scored nudges and commits.
9. Inherit + overall mode change warns and re-rounds field scores; per-field override warns when leaving grid.
10. Average-from-children rounds to parent overall precision.
11. Parent overall `0` appears in Ranked section.
12. Only one score popover at a time.
13. Score range filter respects step.
14. Rank-number ties remain exact equality (`8.3` ≠ `8.4`).

---

## 13. Implementation checklist

- [x] Precision enum + category/field schema + migration from half-step booleans
- [x] Update `ranking_queries` step/round/midpoint/average/rescale/format
- [x] `RankingStars` read-only; remove preview/commit paths
- [x] Shared `RankingScorePopover` (text + rollers + clear + carry/snap-back)
- [x] Wire number control on list rows, editor overall, fields, child list
- [x] Wheel nudge + long-press clear
- [x] Template UI: three-mode picker + inherit checkboxes
- [x] Mode-change / inherit-off / rescale warning dialogs
- [x] Filter slider step
- [x] Context menu Clear retained
- [x] Tests for commit/cancel matrix, carry, snap-back, migration, average

---

## 14. Decision log

| Topic | Decision |
|-------|----------|
| Star interaction | Removed everywhere; visual only |
| Input | Number → popover (rollers + type-in) |
| Modes | Integers / half / tenths |
| Field precision | Inherit from overall by default; optional per-field override |
| Integer UI | Right roller hidden |
| Range | `[0, scoreMax]`; `0` is ranked if overall |
| Ceiling/floor overscroll | Snap back on settle |
| Half at `0.5` + left down | Stays `0.5` (left roller ignores the fraction) |
| Commit model | Draft until outside-click / Enter; Esc cancels |
| Untouched unscored + outside | Commit midpoint |
| Untouched unscored + Enter | Commit midpoint |
| Live persist while rolling | No |
| Text on open | Focus + select-all |
| Blur text | Clamp/snap into rollers; stay open |
| Clear | Popover + context menu + long-press; not via number tap |
| Wheel (closed) | Immediate commit; unscored starts at midpoint±step |
| Display | Strip trailing zeros; `-` only for null |
| Mode tighten | Warn + re-round |
| Average | Round to parent overall step |
| Field default | Midpoint display, null until scored |
| Extras | Wheel yes; Esc/outside rules yes; filter step yes; long-press clear yes; arrows/animate/`/max`/snap-half chip no |

---

## 15. Relationship to other docs

| Doc | Authority after this HLD |
|-----|---------------------------|
| `RANKINGS.md` | Domain, lifecycle, sync; **precision model and score UI replaced by this doc** |
| `RANKINGS_UI.md` | Page chrome/list/panel; **quick-rate and overall-row score interaction replaced by this doc** |
| This doc | Score precision, popover, stars-as-display, commit matrix |
