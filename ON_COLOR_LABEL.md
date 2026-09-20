# On-color labels for chromatic fills

Proposal to make automatic foreground selection the default for every solid
(or effectively solid) user-picked color — accent, calendar events, toast
actions, Save/Add buttons, chips, badges — so labels stay readable and related
to the fill, without per-widget “is this too light?” special cases.

**Status:** implemented (`onColorLabel`, `test/on_color_label_test.dart`).  
**Related:** `lib/core/theme/voyager_theme.dart` (`onColorLabel`, `VoyagerColors.onAccent`),
`DESIGN.md` (Blended Line Rule / `onAccent`), calendar event chrome,
`DARK_THEME_AUDIT.md` (accent-luminance badge notes).

---

## Problem

User accent `#b7bdf8` (and similar pastels) looks light, but the current
luminance gate keeps **white** text. White on that fill is roughly **1.8:1** —
hard to read — while a dark ink would be roughly **9.4:1**.

The failure is a **threshold cliff**, not a missing product idea.

## Current behavior

```dart
Color onColorLabel(Color background, {Color light = Colors.white}) =>
    background.computeLuminance() > 0.55 ? const Color(0xFF1B1B22) : light;
```

| Aspect | Today |
|--------|--------|
| Rule | Binary: luminance `> 0.55` → fixed Ink Slate `#1B1B22`, else white |
| Theme wiring | `ColorScheme.onPrimary` / `VoyagerColors.onAccent` from `onColorLabel(accent)` |
| Call sites | Calendar event titles, todo markers, selector pills, color picker checks, charts, some toasts/panels, glass buttons (dark + tinted, after alpha-blend), etc. |
| Calendar “connection” | Same helper — not a hue-tinted ink path yet. Pale events feel related because dark ink sits on a soft wash. |

Approx for `#b7bdf8`: luminance **~0.53** (just under 0.55) → white wins incorrectly.

## Goal

1. **One shared helper** decides label color from the fill for all chromatic chrome.
2. Labels stay **readable** for any user-picked hue/luminance (light and dark themes).
3. Preserve a **family link** between fill and ink via hue-linked darkening (first pass).
4. Do **not** recolor body text on cards/fields/lists — only text/icons painted *on* a chromatic fill.

---

## Decisions

| # | Topic | Decision |
|---|--------|----------|
| 1 | Hue-linked ink | **In first pass** — not deferred. Light fills get ink derived from the fill; dark fills get a light label. |
| 2 | Dark-side fallback / theme ink | When a neutral dark label is needed as a candidate or clamp, use the **theme `onSurface`** (dark theme bone / light theme Ink Slate `#2B303B`), not hardcoded `#1B1B22`. |
| 3 | Contrast floor | **4.5:1 target.** Pick the better of the light vs dark candidates; if either meets ≥4.5:1, prefer a candidate that meets it. If neither does (pathological neon), still pick the higher ratio. One policy for all chrome — no separate 3:1 path. |
| 4 | Translucent fills | **Blend first, then decide.** If the painted fill has alpha &lt; 1, composite onto the real backdrop, then run `onColorLabel` on that effective color. Opaque fills (`alpha == 1`, including calendar bars today) pass through unchanged. |
| 5 | Accent picker preview | **No** live on-color sample text in the picker. |
| 6 | Hardcoded whites | **In first pass** — audit and fix call sites that paint labels/icons on chromatic fills with a literal `Colors.white` (or always-light ink) instead of the helper. Not a wholesale replace of every white in the app. |

---

## Approach (single first pass)

Replace the luminance cliff with one helper that:

1. Builds **two label candidates** against the (effective) fill:
   - **Light label:** white, or a lightly fill-tinted white if that still clears contrast.
   - **Dark label:** **hue-linked** — darken / desaturate the fill into readable ink. If that ink fails contrast, fall back toward theme `onSurface` (still preferably with a hint of the fill if contrast allows).
2. Chooses by **contrast-max**, with a **4.5:1** preference as above.
3. Is wired so theme `onAccent` / `onPrimary` rebuild from the new helper (signature will need `BuildContext` or an explicit `Color onSurface` / brightness argument so theme ink can match).

Theme rebuild already sets `onAccent` from `onColorLabel(accent)`, so primary filled controls that honor `onPrimary` / `onAccent` pick up the change once the helper and its call signature are updated.

### Call-site hygiene (same first pass)

Find widgets that still hardcode `Colors.white` (or always-white icon colors) *on top of* an accent/event fill and route them through `onColorLabel` / `VoyagerColors.onAccent`. Correct call sites improve as soon as the helper changes; hardcoded ones are fixed in the same pass so pale accents don’t leave stragglers.

---

## Scope

### In scope (use auto on-color)

- Filled accent / primary actions (Save, Add, confirm)
- Toast action buttons on accent
- Selected chips, pills, segmented controls on accent
- Calendar event bars/chips and similar entity-color fills
- Solid badges, checkmarks on swatches, count badges on accent
- Any other **opaque or near-opaque** user-picked chromatic plate

### Out of scope (keep theme `onSurface` / role colors)

- Body and secondary text on scaffold, cards, dialogs, fields
- Outlined / ghost / hairline-only controls with no solid chromatic fill
- Decorative accents that are not a label background (dots, underlines, blended lines — still Blended Line Rule)
- Accent picker UI showing resolved label samples

### Conditional (blend first, then decide)

- Translucent glass / wafer buttons — keep compositing tint onto surface before `onColorLabel` (dark tinted `GlassButton` already does this)
- Any future translucent event/chrome fills — composite, then resolve (calendar `calendarEventBarFillAlpha` is `1.0` today, so no behavior change until alpha drops)

---

## Design rules (once implemented)

1. **Single source of truth** — chromatic-fill chrome calls `onColorLabel` or reads `VoyagerColors.onAccent` / `ColorScheme.onPrimary`. No local luminance thresholds.
2. **Decide from the painted fill** — translucent → composite onto backdrop first.
3. **Icons match labels** on that fill unless a deliberate dual-tone pattern already exists.
4. **Disabled** — dim the resolved on-color (alpha), do not re-run a different contrast rule.
5. **Do not** use on-color for page text or for meaning that must survive any accent (shape/weight/edge still carry state — see `DESIGN.md`).

---

## Edge cases

| Case | Notes |
|------|--------|
| Mid-pastel accents (`#b7bdf8`, soft yellow, mint) | Contrast-max + hue-linked dark ink should choose a darkened fill (or theme `onSurface` fallback). |
| Pure / neon mid-luminance (lime, gold, cyan) | Hue-linked darken helps; if still weak, fall toward `onSurface` while keeping best contrast. |
| Near-black / near-white user colors | Prefer the higher-contrast candidate; avoid muddy mid-gray labels. |
| Light vs dark app theme | Fill-relative choice; theme `onSurface` only as the neutral dark/light candidate / clamp so light mode doesn’t use dark-theme slate. |
| Translucent event bars | If alpha &lt; 1 later, must composite; today alpha is 1.0. |
| Glass / alpha wafers | Blended effective color only. |
| Gradients / multi-stop fills | Out of scope until a real gradient chrome need exists. |
| Forced `textColor` overrides | Intentional bypass only when the label is *not* on a chromatic fill, or when contrast is deliberately custom. Chromatic-fill overrides that force white are in-scope for the first-pass audit. |
| High contrast / a11y mode | Surfaces near-solid → blend paths simplify; same helper on effective fill. |

---

## Suggested rollout

1. ~~Agree open product questions~~ (done — see Decisions).
2. Implement new `onColorLabel` (hue-linked + contrast-max + theme `onSurface`) with unit tests: `#b7bdf8`, dark navy, pure yellow, near-white, near-black, both theme `onSurface` values.
3. Update call sites that need the new signature (`BuildContext` or explicit `onSurface`).
4. Audit and fix hardcoded whites / always-light ink on chromatic fills (Decision 6).
5. Spot-check calendar events, toasts, selector pills, glass tinted buttons, and any audited call sites (both themes) with a pale accent such as `#b7bdf8`.
6. One-line note in `DESIGN.md` under Do’s: prefer `onColorLabel` / `onAccent` for labels on chromatic fills; mention hue-linked ink + contrast-max.

---

## Non-goals

- Recoloring all UI text from the accent
- Per-feature contrast helpers
- Changing the accent picker ramp or stored palette values (paint-time resolve only, same as tags)
- Replacing the Blended Line Rule for hairlines/outlines
- Live on-color preview in the accent picker

---

## Decision 6 — hardcoded white audit (in first pass)

Some widgets already do the right thing:

```dart
color: onColorLabel(eventColor)
// or
color: VoyagerColors.of(context).onAccent
```

Those pick up the new helper automatically.

Others may still do something like:

```dart
// Label sitting on an accent / event fill, but locked to white
color: Colors.white
```

Those **ignore** the helper and can still show white-on-pastel after the helper lands. The first implementation pass includes finding and migrating them.

**In audit scope:** whites (or always-light ink) used as **foreground on a user-picked chromatic fill** (accent, event/list/category color, solid badge on those fills).

**Out of audit scope:** page text, scrims, shadows, hairlines, intentional light-on-dark chrome that is *not* sitting on a user-picked fill.
