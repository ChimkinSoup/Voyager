---
version: 1
slug: "gaia-companion-gaia-control-showcase-dart-71e75557"
primary_target: "lib/features/gaia/companion/gaia_control_showcase.dart"
related_targets: ["windows/runner/gaia_control_border.cpp","windows/runner/gaia_control_border.h"]
---

# Gaia control effect studies

Scope: Gaia's live Windows OS-control feedback and its debug comparison showcase.
Trace + Bloom is the approved live default. The showcase compares native effects
on a mock window without sending input; Current remains a debug baseline.

## Direction contract

THESIS: Use the approved Trace + Bloom vocabulary consistently across live action feedback. Clicks trace white/gold halos over a soft core bloom; double-click gives two core beats in one continuous reveal; right-click adds a menu-corner cue. Point markers use a quieter version. Field outlines, key labels and window corners appear whole and fade, without a travelling typing pearl. Keep the approved scroll choreography and clear window midpoint fades. Retain the debug comparison surface for review.

OWN-WORLD: Inherit Gaia's user-selected accent, Astral gold, luminous white cores, near-black label plates and Iosevka Aile. Astral Trace + Bloom is the live default: progressive halo strokes and a soft core pulse. Double-click gives two soft core beats within a single uninterrupted 900ms halo trace; right-click adds a menu-corner cue and point markers use a smaller, quieter combination. Outlines, pill rims and window corners appear whole in white/gold and fade; they never trace round. Typing shows the steady outline without a travelling pearl. Approved scrolling and window geometry, scaling and midpoint pools remain intact. Trace, Bloom, Current, Echo and Glide remain debug comparison choices.

STORY: Live OS-control feedback uses the approved Astral Trace + Bloom recipe across necessary action and surface feedback. The debug showcase initially selects that live recipe and retains named family comparisons, individual actions, Play all, the Ask-card preview and border. Astral offers exactly three single-click studies (Trace, Bloom, Trace + Bloom), descriptions and a same-target sequence. Explicit debug overrides allow comparison with historical choices. Switching families or click studies cancels queued playback.

FIRST VIEWPORT: Four wrapping family selectors and a description lead the existing showcase. Within Astral, a compact Single-click studies group adds three wrapping choices, one description and Play click studies before the same 220px mock target. Individual effects and Play all remain below the target. The border toggle and Ask-card demonstration follow.

FORM: Extend the existing procedural Windows raster feedback and its comparison showcase. No image assets or new global tokens. seed: none (unavailable; no new surface tournament).

FINISH: Ship the approved live rendering and default wiring after the finish review. Preserve the incumbent global design system; no shipping raster assets are introduced.

## Implemented extension

- Live Dart feedback (`gaia_flash.dart`) injects Astral and `click_variant: traceBloom` before explicit debug overrides. Native `GaiaFlash` defaults to Astral/TraceBloom, and native control-border `Show` defaults to Astral. The parser explicitly recognizes `classic` and `trace` for retained debug comparisons. The showcase initially selects Astral + Trace + Bloom. The Ask-card preview forwards the selected family to its markers and action flashes.
- Astral single-click studies remain exactly Trace, Bloom and Trace + Bloom. Trace progressively reveals halo strokes, Bloom pulses the core and the approved Trace + Bloom combines both without prepainting complete halos. The approved combined click visual is unchanged. Play click studies performs exactly three named single clicks at the same target; a selected study override remains scoped to Astral single click.
- Double click gives two soft core beats in a single uninterrupted 900ms halo trace. Right click uses the combined material with a menu-corner cue. Point markers use a smaller, quieter Trace + Bloom. Field/control outlines, key/name pill rims and window corners/midpoint glows are drawn whole once in white/gold and only faded in and out (no trace-around, no surface bloom), to stay inside the 2 ms frame budget (GAIA_AUTONOMY_HLD.md §11.3). Key/name text remains readable throughout. Astral typing never creates a travelling pearl.
- Astral scrolling shares Current's `PaintScroll` function: the same 50ms stagger, easing, sinusoidal alpha, count, accent-to-gold progression and 520ms total duration in every direction. Its curved arrow geometry remains distinct, with 3.8px strokes.
- Astral window adoption retains four detached curved white/gold corner brackets in separate square native tiles and four faint tapered pools at the side midpoints. All eight placements retain the approved 1000ms duration. `AstralWindowCornerSide` retains its reach of 16% of the shorter window dimension, clamped to 64–176 logical pixels and bounded by window size using monitor DPI. The approved geometry, scale and midpoint pools are preserved; the pieces fade rather than trace.
- Native surface tiles are painted once at Play and only faded afterwards; at most four faded pieces update per frame, and finished windows hide three per frame in one batch.
- Family selectors and Astral's three study choices wrap with the existing compact spacing above the unchanged mock window. Existing Gaia buttons, theme text styles and the Ask card retain the surrounding showcase language.
- Color continues to come from the user's theme accent. Native drawing reuses Astral gold, luminous white cores, Gaia's accent-tinted near-black plate and the bundled Iosevka Aile. Family geometry changes the material expression without introducing a new palette or global token.
- Changing families cancels queued showcase playback, closes the open preview card and refreshes an enabled border. Changing click studies also cancels queued playback. Current, Echo, Glide and individual Trace/Bloom options remain debug comparisons; Astral Trace + Bloom is the live default. Echo and Glide retain their 100-logical-pixel, 760ms scroll choreography; Current retains its baseline behavior.

## Verification and disposition

Fresh finish review (`impeccable_live_trace_bloom_review`) disposition: **SHIP** for the live rendering and default wiring, with no material fixes required. Eight artifacts were reviewed: production material sheets (`build/gaia-live-family-dark.png`, `build/gaia-live-family-light.png`, seven action/detail rows at five times before layer opacity), window-size sheets (`build/gaia-astral-window-sizes.png`, `build/gaia-astral-window-sizes-light.png`) and four Flutter narrow/dialog captures (`build/gaia-showcase-520-dark.png`, `build/gaia-showcase-520-light.png`, `build/gaia-showcase-360-dark.png`, `build/gaia-showcase-360-light.png`).

Reported validation: all 89 Flutter tests across showcase, control card, OS control and capture pass, the analyzer is clean, and native compilation with `/W4 /WX` plus application linking pass. Actual WM_TIMER tests verify the new default native recipe, changing point/outline/window/key material frames, no moving typing pearl, original scroll visibility and double-click continuity. A new Dart test verifies the live defaults and explicit debug overrides; the default showcase click test checks the correct payload. Desktop compositing, subjective live pacing and mixed-DPI transitions remain unverified. Reduced-motion support remains unestablished.

This is an ordinary extension of the existing Gaia visual language. Global DESIGN.md and its sidecar are unchanged; the sidecar's preexisting stale state is outside this task. No image assets ship, so no raster provenance record is required.

Animation regression correction: removed the Windows client-area animation gate, which froze all four families when that OS setting was off. Native action feedback retains its own animation clock, as requested by the user. `test/windows/gaia_control_animation_test.cpp` drives actual WM_TIMER messages and captures bitmap submissions in memory. This verifies animation independence from that OS setting; it does not establish a reduced-motion accommodation.
