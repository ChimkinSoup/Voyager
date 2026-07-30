# Background Pipeline

Voyager has **two** hand-built themes, each with its own full-screen background, selected by `AppThemeMode` in settings (`themeModeProvider`). `VoyagerApp`'s `_AppBackground` picks the pipeline:

- **Dark** (default) — the equilateral-triangle grid shader documented below: a grid tinted with the user's accent color, concentrated near a focal point and fading toward the edges, with an optional animated wave.
- **Light** — a static warm-cream **paper-grain** shader (`shaders/paper_texture.frag` → `PaperTexture`) with a **falling petal field** drawn over it (`PetalField`, a Dart-simulated particle system). See [Light theme](#light-theme-paper--petals) below.

Both themes share the same widget-level `ThemeData`, built from a `VoyagerPalette` by `VoyagerTheme._build`. Semantic colors that used to be hardcoded `Colors.white`/`Colors.black` (hairlines, scrims, chart gridlines, shadows, on-accent text) now come from the `VoyagerColors` theme extension so every widget resolves the right value per theme.

## The dark theme (triangle grid)

## Overview

```mermaid
flowchart TB
  subgraph assets["1. Asset"]
    frag["shaders/geometric_texture.frag"]
    pubspec["pubspec.yaml → flutter.shaders"]
  end

  subgraph load["2. Load"]
    provider["geometricShaderProvider"]
    warmupData["shellDataWarmupProvider"]
    frag --> pubspec --> provider
    provider --> warmupData
  end 

  subgraph params["3. Parameters"]
    defaults["GeometricTextureParams.defaults"]
    devParams["geometricTextureParamsProvider"]
    devUI["DevGeometricTextureSection"]
    defaults --> devParams
    devUI --> devParams
  end

  subgraph render["4. Render"]
    widget["GeometricTexture widget"]
    painter["GeometricTexturePainter"]
    shader["FragmentShader uniforms → drawRect"]
    provider --> widget
    devParams --> widget
    widget --> painter --> shader
  end

  subgraph compose["5. Compose"]
    app["VoyagerApp MaterialApp.builder Stack"]
    bg["Positioned.fill GeometricTexture"]
    ui["Router / pages on top"]
    app --> bg
    app --> ui
    shader --> bg
  end

  subgraph gpuWarmup["6. GPU warmup"]
    shellWarmup["GeometricTextureWarmup in AppShell"]
    shellWarmup --> widget
  end
```

## 1. Shader asset

`shaders/geometric_texture.frag` is registered in `pubspec.yaml` under `flutter: shaders:`. Flutter compiles it to a `FragmentProgram` at build time.

The shader draws:

- An **equilateral triangle grid** using oblique (triangular lattice) coordinates so each ▲/▽ triangle gets one flat color with no seams.
- A **deterministic per-triangle hash** → shade in `[u_variation_floor, 1.0]`.
- A **radial accent gradient** from `u_focal_point`, aspect-corrected for wide screens.
- Final color: `mix(base, accent, ambient + burst)` where ambient is a faint shimmer (`variation × 0.08`) and burst is the focal tint (`gradient × variation × intensity`).

Default focal point is **right-center** `(1.0, 0.5)` — accent glows from the right edge toward the content area.

## 2. Loading

`geometricShaderProvider` in `lib/app/providers.dart`:

- Loads via `FragmentProgram.fromAsset('shaders/geometric_texture.frag')`.
- Uses `keepAlive()` so the program is loaded once per session.
- On failure: reports a `FlutterError` and returns `null` (graceful degradation, no crash).

Also awaited in `shellDataWarmupProvider` alongside journals, settings, calendar data, etc., so the shader is ready during startup prefetch.

## 3. Tunable parameters

`GeometricTextureParams` in `lib/core/widgets/geometric_texture.dart` mirrors the shader uniforms:

| Parameter | Default | Effect |
|-----------|---------|--------|
| `scale` | 10.0 | Triangle density |
| `intensity` | 0.85 | Peak accent at focal point |
| `focalSpread` | 1.0 | Gradient radius |
| `focalPointX` / `focalPointY` | 1.0 / 0.5 | Focal position in normalized UV |
| `variationFloor` | 0.75 | Minimum triangle brightness |

Production uses defaults via `geometricTextureParamsProvider`. The Dev page exposes live sliders and focal presets in `DevGeometricTextureSection` (`lib/features/dev/dev_geometric_texture_tile.dart`).

## 4. Widget → painter → GPU

`GeometricTexture` (`lib/core/widgets/geometric_texture.dart`):

1. Creates a `FragmentShader` from the program (disposed on change/unmount).
2. If `program == null` → `ColoredBox(baseColor)` — no spinner, no error UI.
3. Otherwise → `CustomPaint` with `GeometricTexturePainter`.

The painter pushes 16 floats into the shader (order must match the GLSL uniforms), then `canvas.drawRect` for the full bounds:

```
// Uniform layout (must match shader declaration order):
// 0-1   vec2  u_resolution
// 2     float u_scale
// 3     float u_intensity
// 4     float u_focal_spread
// 5-6   vec2  u_focal_point
// 7     float u_variation_floor
// 8-11  vec4  u_base_color
// 12-15 vec4  u_accent_color
```

`shouldRepaint` triggers on shader, colors, or params changes.

## 5. App-level composition

The background lives in `VoyagerApp`'s `MaterialApp.router` **builder**, not in individual pages (`lib/app/voyager_app.dart`):

- **Bottom layer:** `Positioned.fill` → `GeometricTexture`
- **Top layer:** `DefaultTextStyle` + router child (all UI)

Colors:

- **Base:** `theme.scaffoldBackgroundColor` = `#1B1B22` (`VoyagerTheme`)
- **Accent:** user setting from `settingsProvider`

`AppShell` uses `Scaffold(backgroundColor: Colors.transparent)` so the texture shows through the main chrome. Opaque surfaces (cards `#2A2A33`, app bars `#24242B`, inputs, dialogs) sit above it.

## 6. UI that interacts with the background

Most pages do not reference the shader directly — they are transparent or opaque by convention.

**Journal** is explicit: `_JournalBarBackdrop` in `lib/features/journal/journal_page.dart` blurs and tints the texture for top/bottom toolbars. It uses `scaffoldBackgroundColor` at 80% alpha with a `BackdropFilter` blur so the bars visually match the base tone while softening the triangles underneath.

## 7. GPU warmup (avoid first-frame jank)

Two mechanisms:

**A. Data warmup** — `shellDataWarmupProvider` awaits `geometricShaderProvider.future` during startup.

**B. Paint warmup** — `GeometricTextureWarmup` in `AppShell` (`lib/features/journal/geometric_texture_warmup.dart`) after login:

- Waits for the compiled program.
- Paints a nearly invisible (`opacity: 1/255`) 800×600 `GeometricTexture` for **3 frames**.
- Forces GPU shader compilation before the user hits content-heavy views.
- Then removes itself (`SizedBox.shrink()`).

## 8. Failure modes

| Condition | Behavior |
|-----------|----------|
| Shader load fails | `null` program → flat `#1B1B22` fill |
| Shader still loading | Same flat fill (no loading state) |
| Accent changes | `VoyagerApp` rebuilds → painter repaints |
| Dev slider changes | `geometricTextureParamsProvider` → live repaint |

## File map

| File | Role |
|------|------|
| `shaders/geometric_texture.frag` | GLSL triangle grid + gradient |
| `lib/core/widgets/geometric_texture.dart` | Params, widget, painter |
| `lib/app/providers.dart` | Shader + params providers |
| `lib/app/voyager_app.dart` | Full-screen background stack |
| `lib/features/shell/app_shell.dart` | Transparent scaffold + GPU warmup |
| `lib/features/journal/geometric_texture_warmup.dart` | Hidden 3-frame compile warmup |
| `lib/features/dev/dev_geometric_texture_tile.dart` | Live tuning UI |
| `test/tool/geometric_shader_smoke_test.dart` | Shader load + uniform smoke test |
| `test/tool/geometric_texture_widget_test.dart` | Widget paint smoke test |

## Light theme (paper + petals)

The light theme replaces the triangle grid entirely with two stacked layers in `_PaperBackground` (`lib/app/voyager_app.dart`):

```
Positioned.fill
├── PaperTexture   (bottom — static cream grain)
└── PetalField     (top — animated falling petals)
```

### Paper grain

`shaders/paper_texture.frag` → `PaperTexture` (`lib/core/widgets/paper_texture.dart`). A **static** shader — no time uniform, no timer — so it paints once per size/color change and is then cached by the compositor. Three octaves of value noise (fine speckle over mid tooth over slow blotch) give a matte, non-repeating paper stock. Base = `scaffoldBackgroundColor` (cream), speck = a warm gray a few shades down. Loaded via `paperShaderProvider` (warmed alongside the geometric shader in `shellDataWarmupProvider`). Null program → flat cream fill.

Uniforms (must match `PaperTexturePainter`): `u_resolution`(0-1), `u_base_color`(2-5), `u_speck_color`(6-9), `u_grain_scale`(10), `u_grain_strength`(11), `u_fiber_strength`(12). Pinned by `test/tool/paper_shader_smoke_test.dart`.

### Petal field

`PetalField` (`lib/core/widgets/petal_field.dart`) — a Dart particle system, not a shader, because the spec wants room for interaction (click bursts, cursor repulsion) that a stateless shader can't do cleanly. Petals are simulated in `_Petal` structs, recycled in place, and stamped from a pre-rasterized sprite (one per configured color) via a `CustomPainter`. Driven by a 30fps `Timer` (not a `Ticker`) for the same reason the wave is — to avoid pinning the whole app's frame pipeline at the display refresh rate.

Behavior:

- **Wind** — one global sine (`petalWindFrequency`/`petalWindStrength`) sampled once per frame so all petals lean together (the "grouped" look). On top of it, localized `PetalGust`s push only part of the screen (the spec's "radial velocity modifiers" / partial bursts). Heavier petals lag the wind via per-petal `drag`.
- **Ending (stateless)** — no collision engine. A petal reaching the bottom 10% decelerates, stops rotating, and fades to zero over 2s, then recycles to the top. No petal-to-petal interaction, no accumulation.
- **Interaction hook** — `PetalFieldController.burstAt` / `.gust` let future features (clicks, transitions) inject wind without touching the sim.
- **Minor colors** — up to 3 secondary tints (`minorPetalColors`, ranked top to bottom) can ride alongside the primary `petalColor`. Each petal rolls its color once per fall/recycle (`_Petal.colorIndex`), weighted by `petalColorWeights` — 70:30 with one minor color, 60:25:15 with two, 50:25:15:10 with three.

Params come from `petalFieldParamsProvider` (settings-backed: `petalColor`, `minorPetalColors`, `petalMaxCount`, `petalFallSpeed`, `petalWindFrequency`, `petalWindStrength`), tuned live in Settings → Appearance.

### Light-theme file map

| File | Role |
|------|------|
| `shaders/paper_texture.frag` | GLSL cream paper grain (static) |
| `lib/core/widgets/paper_texture.dart` | Paper params, widget, painter |
| `lib/core/widgets/petal_field.dart` | Petal sim, gust model, controller, painter |
| `lib/core/theme/voyager_theme.dart` | `VoyagerPalette`, `VoyagerColors`, `VoyagerShadows`, both `ThemeData`s |
| `lib/features/settings/settings_page.dart` | Theme toggle + petal tuning UI |
| `test/tool/paper_shader_smoke_test.dart` | Paper shader uniform smoke test |
| `test/settings_theme_persistence_test.dart` | Theme + petal settings round-trip |
