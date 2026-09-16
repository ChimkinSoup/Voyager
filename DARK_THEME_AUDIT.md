# Dark Theme Audit — Parity with Light Theme

**Date:** 2026-09-15  
**Scope:** Full-app dark appearance vs the cream/paper light theme  
**Sources:** `lib/core/theme/voyager_theme.dart`, `DESIGN.md`, settings/background pipeline, chrome widgets, feature surfaces, tests

## Verdict

Dark theme is **architecturally first-class** at the token layer (`VoyagerPalette.dark`, `VoyagerTheme.forMode`, `VoyagerColors`, shared `ThemeData` body). It is **not at parity** with light in product polish: light got paper + petals + Settings controls + blur-free glass plates; dark still relies on Dev-only geometric tuning, semi-transparent list chrome that lets the **animated grid** bleed through, and several leftover hard-coded white/black paths that look muddy or wrong on graphite.

**Appearance & theming score (audit frame): 2/4** — tokens exist and both modes share one theme builder; usage is inconsistent, and several dark surfaces look busier or cheaper than their light counterparts.

---

## What already matches (do not regress)

- Dual palettes and one `_build` path in `lib/core/theme/voyager_theme.dart` (scaffold → appBar → card → field, blended accent lines, shadows, scrim, `highlightWash`).
- Background split in `lib/app/voyager_app.dart`: geometric grid (dark) vs paper + petals (light).
- Settings theme toggle (`AppThemeMode.dark` | `light`) — no system/follow-device (by design).
- `GlassButton` dark plate: graphite `PaperTexture` ~82%, no `BackdropFilter` (aligned with `DESIGN.md`).
- Balanced branches in weather icons, LeetCode code themes, prose underlines, rankings field editor, tag resolve-on-light storage model.

---

## Must change

Items below are ordered by severity. **Must** = required for dark to feel as deliberate and clean as light.

### P0 — Fix before treating dark as “done”

| # | What must change | Where | Why it looks messy in dark |
|---|------------------|-------|----------------------------|
| 1 | **Stop forcing `Colors.black87` on grade `GlassButton`s** | `lib/features/study/study_grading_row.dart` (~127–129) | Light wants dark ink on pastel fills; dark `GlassButton` defaults to bone/`onSurface`. Hard-coded black ink fights the dark glass plate and pale accents. Use luminance / `VoyagerColors.onAccent` / omit `textColor` so `GlassButton` can pick per theme. |
| 2 | **Badge text must follow accent luminance** | `lib/core/media/widgets/media_fan_stack.dart` `_FanCount` (~238–244) | `Colors.white` on user accent fails for pale accents (white-on-white). Light often “gets away with it”; dark + custom accent does not. Use `VoyagerColors.of(context).onAccent` (or the same luminance rule as the theme). |
| 3 | **Chart vertical grid must use theme tokens** | `lib/features/analytics/analytics_page.dart` (~1101–1108) | Vertical lines use `Colors.grey @ 0.15`; horizontals use `colorScheme.outline`. Grey reads ashy on Midnight Graphite and fights `VoyagerColors.chartGrid` used elsewhere on the same page. Use `VoyagerColors.chartGrid` (or outline) for **both** axes. |

### P1 — High priority (noticeable dark mess / parity gaps)

| # | What must change | Where | Why |
|---|------------------|-------|-----|
| 4 | **Raise list-row fill opacity in dark (or solidify)** | `lib/core/theme/voyager_list_item_surface.dart` (resting α 0.25, selected 0.65, hover 0.75) | Comments assume calm paper showing through. On dark, the **moving triangle grid** shows through journal/todo/rankings sidebars → shifting, busy tints. Nav selected fill is already ~92% (`shell_nav_theme.dart`). Dark list rows must approach that solidity (theme-branched alphas or near-opaque `card`/`field`). |
| 5 | **Align shell selected fill policy with lists** | `lib/features/shell/shell_nav_theme.dart` + list surface | Same product family (68×56 nav vs sidebar rows) currently disagree on how much background shows through. Pick one dark policy and share it. |
| 6 | **Expose dark background controls in Settings** | `lib/features/settings/settings_page.dart` (light-only `_PetalSettings`); params already in settings + `geometricTexture*` / `geometricWave*` providers | Light users tune petals in Appearance. Dark users only get Dev geometric panels. Mirror a **simplified** `_GeometricSettings` (intensity / focal / optional wave enable) when `themeMode == dark`. |
| 7 | **Retire dark `BackdropFilter` on LeetCode flashcards** | `lib/features/leetcode/leetcode_flashcard.dart` `_glassContainer` (~104–132) | Light was rewritten to opaque white `PaperTexture` because blur over busy canvas smears. Dark still blurs the **live grid** every frame (smear + GPU). Match `GlassButton` / DESIGN: graphite paper plate, no backdrop blur; shadows via `VoyagerColors` / `VoyagerShadows`. |
| 8 | **Default dialog barriers to `VoyagerColors.scrim`** | `lib/core/widgets/voyager_dialog.dart` (`barrierColor: Colors.black54`); many call sites omit override | Theme scrim is tuned (dark ~55%, light ~28%). Fixed `black54` fights the Dark Scrim Rule and makes modal stacks feel uneven vs paths that already use `VoyagerColors.scrim` (e.g. analytics ~4070). |
| 9 | **Hero expand scrims → `VoyagerColors.scrim`** | `finance_net_flow_hero.dart`, `leetcode_activity_card.dart`, `leetcode_detail_view.dart`, `exercise_detail_view.dart`, `leetcode_scratch_pad.dart` | Hard-coded `Colors.black @ 0.5 * t` (or 0.55) ignores theme scrim alphas. |

### P2 — Should change (polish / consistency)

| # | What must change | Where | Why |
|---|------------------|-------|-----|
| 10 | **Mood slider low end should not always be pure white** | `lib/core/widgets/mood_gradient_slider.dart` (~35–40) | Comment fixed light cream wash → black-looking ramp. On dark, white→accent is a harsh band vs `highlightWash` elsewhere. Branch: keep white (or near-white) for light; use low-alpha white or a dark-end wash for dark. |
| 11 | **Replace hard-coded card/media shadows** | `leetcode_flashcard.dart`, `media_fan_stack.dart`, `dream_sticky_note.dart` | `Colors.black @ 0.22–0.35` ignore `VoyagerShadows` blur scale / slate-vs-black rule. |
| 12 | **Drop `Colors.grey` midtone lerps in time/date UI** | `time_selector_popovers.dart`, `datetime_selector_popover.dart` | Material grey goes cold/ashy on graphite; prefer `outlineVariant` / `chartGrid` / accent blends. |
| 13 | **Journal flag highlight toward `highlightWash`** | `lib/core/widgets/journal_color_flag.dart` | Always lerps toward `Colors.white`; wrong on pale stored colors under dark chrome. |
| 14 | **GlassButton light label → Ink Slate / `onSurface`** | `lib/core/widgets/glass_button.dart` | DESIGN says ink-slate; code uses `Colors.black87`. Small cross-theme drift when comparing themes. |
| 15 | **Centralize dark glass plate color** | `glass_button.dart` (`fillColor` vs `surface`) | Dual sources can disagree with neighboring fields/cards. Prefer `VoyagerPalette.field` / input fill consistently. |
| 16 | **Optional: dark-aware desktop title bar** | `desktop_window_title_bar.dart` + transparent shell | Opaque `surface` band over animated grid reads as a hard cut. Consider hairline + slight translucency or matching shell chrome. |

### P3 — Product / intentional (document, don’t “auto-darken”)

| # | Decision | Where | Note |
|---|----------|-------|------|
| 17 | ~~**Life Tracker cream island**~~ — **resolved 2026-09-15** | `life_tracker_page.dart`, `life_tree_canvas.dart` | The premise was wrong: the canvas never painted its own paper. It is transparent and composites onto the app background, so light got cream + petals for free and dark got the washes stacking straight over the live triangle grid (near-black ink on near-black, canopy as one lit slab). Dark now paints its own toned stock (`_nightPaperColor`) with bone ink, a wash ramp tuned for a ground that lightens rather than darkens under layers, and brighter per-week specks — an authored night scene, framed as before. Light is byte-for-byte unchanged. |
| 18 | **Media lightbox always black chrome** | `media_lightbox.dart` | Intentional cinema overlay; same in light. |
| 19 | **Tag storage = dark ramp, remap on light** | `journal_tags.dart`, `palette_color.dart` | Sync design; dark is canonical. Ensure all paint sites call `resolveTagColor` (finance analytics store charts still pass raw tags in places — primarily a light bug). |
| 20 | **No `AppThemeMode.system`** | `enums.dart` | By design (two authored worlds). Only add if product wants follow-device. |

---

## Where dark looks messy vs light (visual map)

```
Light world                         Dark world (problem)
─────────────────                   ────────────────────
Static paper grain                  Animated triangle grid
  ↓                                   ↓
Semi-transparent lists              Same alphas → grid shimmer through rows  ← MUST #4–5
Calm petal Settings                 Geometric knobs only in Dev              ← MUST #6
GlassButton: thin wafer             GlassButton: paper plate (OK)
Flashcard: opaque paper card        Flashcard: BackdropFilter over grid      ← MUST #7
Scrim via VoyagerColors (often)     black54 / black@0.5 heroes               ← MUST #8–9
Charts use outline/chartGrid        grey vertical grid                       ← MUST #3
```

Worst “messy” screens in dark today:

1. **Any sidebar with many `VoyagerListItemSurface` rows** (journal, todo, rankings) — grid bleed.
2. **LeetCode flashcard / session** — blur smear + hard shadow.
3. **Study grading row** — black labels on dark glass.
4. ~~**Life Tracker**~~ — fixed; see P3 #17.
5. **Analytics charts** — mixed grey vs outline gridlines.

---

## Test / automation gaps (support parity)

Light recently gained targeted coverage; dark is still the default harness for many suites, but **product-specific** dark polish is under-tested:

| Gap | Action |
|-----|--------|
| No Settings UI test for dark geometric appearance controls | Add once `_GeometricSettings` ships |
| `glass_reduced_transparency_test.dart` covers GlassButton both themes; GlassSurface high-contrast not pinned to `VoyagerTheme.dark()` | Pin real palette |
| Jobs stage / tag WCAG audits emphasize light cards | Add dark-card contrast cases |
| Tracker row / menu semantics tests use `VoyagerTheme.light()` only | Mirror under dark |
| No goldens for either theme | Optional; dual-theme widget asserts on glass + list opacity are higher ROI |

---

## Recommended fix order

1. **P0 contrast bugs** — grading row, fan badge, analytics grid.  
2. **Dark list/nav opacity** — kill grid bleed through content chrome.  
3. **Flashcard dark surface** — paper plate, drop blur (match GlassButton doctrine).  
4. **Scrim token wiring** — `showVoyagerDialog` + hero overlays.  
5. **Settings `_GeometricSettings`** — parity with petals.  
6. **P2 token cleanup** — mood slider, shadows, grey lerps, glass label.  
7. ~~**Life Tracker framing**~~ — done.  
8. **Tests** for the above.

---

## Out of scope / not broken

- Mask-only `Colors.white` / `Colors.black` in `ShaderMask` (`app_shell`, number/spinner wheels).
- Confetti, SRS/LeetCode difficulty colors, weather icon pairs (semantic or balanced).
- Default accent `#7C9EFF` as theme parameter (user-replaceable).

---

## Summary checklist (must)

- [ ] `study_grading_row.dart` — theme-aware grade label color  
- [ ] `media_fan_stack.dart` — `onAccent` for `+N` badge  
- [ ] `analytics_page.dart` — themed vertical gridlines  
- [ ] `voyager_list_item_surface.dart` (+ nav) — dark solid fills  
- [ ] Settings Appearance — geometric controls for dark  
- [ ] `leetcode_flashcard.dart` — no dark `BackdropFilter`; graphite paper plate  
- [ ] `voyager_dialog.dart` + hero routes — `VoyagerColors.scrim`  
- [ ] Mood slider / shadows / grey midtones — token pass (P2)

When these are done, dark will match light’s **support quality**: authored background, Settings ownership, blur-free instrument glass, and semantic chrome that does not fight the canvas.
