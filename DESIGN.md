---
name: Voyager
description: Local-first journaling and life-tracking, built as warm paper under precise instruments.
colors:
  paper-cream: "#F5F1E9"
  ivory-wash: "#FAF7F0"
  ivory-leaf: "#FDFBF6"
  ivory-field: "#FFFEFA"
  ink-slate: "#2B303B"
  midnight-graphite: "#1B1B22"
  graphite-wash: "#24242B"
  graphite-leaf: "#2A2A33"
  graphite-field: "#30303A"
  bone: "#E6E6EA"
  cornflower: "#7C9EFF"
  dusty-rose: "#E6A4B4"
  on-accent-inverse: "#FFFFFF"
typography:
  display:
    fontFamily: "IosevkaAile"
    fontSize: "57px"
    fontWeight: 400
    lineHeight: 1.12
    letterSpacing: "-0.25px"
  headline:
    fontFamily: "IosevkaAile"
    fontSize: "24px"
    fontWeight: 400
    lineHeight: 1.33
    letterSpacing: "normal"
  title:
    fontFamily: "IosevkaAile"
    fontSize: "22px"
    fontWeight: 400
    lineHeight: 1.27
    letterSpacing: "normal"
  body:
    fontFamily: "IosevkaAile"
    fontSize: "16px"
    fontWeight: 400
    lineHeight: 1.5
    letterSpacing: "0.5px"
  label:
    fontFamily: "IosevkaAile"
    fontSize: "14px"
    fontWeight: 500
    lineHeight: 1.43
    letterSpacing: "0.1px"
rounded:
  mark: "2px"
  tooltip: "8px"
  control: "12px"
  field: "14px"
  row: "16px"
  surface: "18px"
spacing:
  xxs: "2px"
  xs: "4px"
  sm: "8px"
  md: "12px"
  lg: "16px"
  xl: "24px"
components:
  button-filled:
    backgroundColor: "{colors.cornflower}"
    textColor: "{colors.on-accent-inverse}"
    typography: "{typography.label}"
    rounded: "{rounded.surface}"
  button-outlined:
    textColor: "{colors.ink-slate}"
    typography: "{typography.label}"
    rounded: "{rounded.surface}"
  button-text:
    textColor: "{colors.ink-slate}"
    typography: "{typography.label}"
    rounded: "{rounded.surface}"
    padding: "12px 16px"
    height: "40px"
  button-glass:
    backgroundColor: "{colors.cornflower}"
    textColor: "{colors.ink-slate}"
    typography: "{typography.label}"
    rounded: "{rounded.control}"
    padding: "10px 16px"
  button-glass-dense:
    backgroundColor: "{colors.cornflower}"
    textColor: "{colors.ink-slate}"
    typography: "{typography.label}"
    rounded: "10px"
    padding: "6px 10px"
  input-field:
    backgroundColor: "{colors.ivory-field}"
    textColor: "{colors.ink-slate}"
    typography: "{typography.body}"
    rounded: "{rounded.field}"
    padding: "18px 16px"
  selector-pill:
    textColor: "{colors.ink-slate}"
    typography: "{typography.label}"
    rounded: "{rounded.control}"
    padding: "6px 8px"
  selector-pill-dense:
    textColor: "{colors.ink-slate}"
    typography: "{typography.label}"
    rounded: "{rounded.control}"
    padding: "4px 4px"
  card-surface:
    backgroundColor: "{colors.ivory-leaf}"
    textColor: "{colors.ink-slate}"
    rounded: "{rounded.surface}"
  menu-surface:
    backgroundColor: "{colors.ivory-leaf}"
    textColor: "{colors.ink-slate}"
    typography: "{typography.body}"
    rounded: "{rounded.surface}"
  tooltip-surface:
    backgroundColor: "{colors.ivory-field}"
    textColor: "{colors.ink-slate}"
    rounded: "{rounded.tooltip}"
  rail-item:
    rounded: "{rounded.surface}"
    width: "68px"
---

# Design System: Voyager

## Overview

**Creative North Star: "The Paper Instrument"**

Voyager is built from two materials held in tension. The surface you write on is warm and
physical — a cream paper stock with real grain, petals drifting down across it, everything
matte and flat as if it were printed rather than rendered. The tools you write with are
exact: Iosevka Aile, one-pixel hairlines, tight radii, no ripple, state changes measured in
tens of milliseconds. Neither material wins. The contrast between them *is* the identity,
and the fastest way to break this system is to soften a control to make it feel friendlier,
or to sharpen the canvas to make it feel more serious.

The practical consequence is a strict division of labor. Ornament belongs to the canvas
layer and nowhere else. The paper grain, the falling petals, the watercolor life tree, the
dark theme's triangle grid — these are permitted to be lush because they sit *behind* the
work. A dropdown, a text field, a list row gets none of it. Controls are instrument-side:
they hold an edge, respond immediately, and get out of the way. This is why the light
palette's four surface tones step only a few points of luminance apart. Wide steps would
reintroduce the layered, floating look that the paper texture exists to replace.

The system is calm, precise, and warm — in that order of priority when they conflict. Calm
means nothing moves that wasn't asked to move. Precise means a hairline stays a hairline
even when the theme goes pale; the light theme raises its outline alpha rather than let
borders dissolve. Warm means the warmth is earned from material, not from rounded corners
or encouraging language. **Stock Material 3 is the confirmed anti-reference:** no tonal
elevation surfaces, no filled-tonal buttons, no FABs, no ripple splashes. Voyager runs on
Material's machinery but rejects its appearance, and the theme enforces this at the root
with `NoSplash.splashFactory`, zero-elevation menus, and transparent surface tints.

**Key Characteristics:**

- Two complete backgrounds, not one inverted: cream paper with petals in light, an
  accent-tinted triangle-grid shader in dark
- A single user-chosen accent color that every surface derives from — no fixed brand hue
- Flat and matte by doctrine; shadows at 3–5% opacity in light, spread 2.2× wider to compensate
- Iosevka Aile everywhere, including body copy — the instrument register applied to prose
- Hairlines and outlines derived from the accent, not from black or white
- Motion in the 90–150 ms band, `easeOutCubic`, with celebration reserved for real milestones

## Colors

A two-world palette: one warm and papery, one cool and near-black, joined by a single accent
the user picks and the entire system derives from.

### Primary

- **Cornflower** (`#7C9EFF`): The **default** accent only — the user replaces it in Settings,
  so treat this hex as a starting position, never as a brand color. The accent drives
  focus rings (at 95% alpha, 1.8px), caret color, selected-tile fills (14% alpha), active
  pill borders, blossom tints on the life tree, and the dark theme's grid tint. It is never
  painted directly as a hairline; see The Blended Line Rule.
- **Dusty Rose** (`#E6A4B4`): The **default** petal color, likewise user-replaceable and
  stored as a separate setting from the accent. Up to three additional minor petal tints
  ride alongside it, weighted 70:30, 60:25:15, or 50:25:15:10 depending on how many are set.

### Neutral — light theme (paper)

The four surfaces are ordered by how far forward they sit. Each step is only a few points of
luminance from the last, and that tightness is deliberate.

- **Paper Cream** (`#F5F1E9`): The backdrop tone, furthest back. Visible directly only while
  the paper shader is still loading; otherwise the grain paints over it.
- **Ivory Wash** (`#FAF7F0`): App bar and the `surface` role.
- **Ivory Leaf** (`#FDFBF6`): Cards, dialogs, menus, popovers.
- **Ivory Field** (`#FFFEFA`): The most forward surface — text-field fills, tooltips, snackbars.
- **Ink Slate** (`#2B303B`): Primary text and icons. Also the light theme's shadow color and
  its highlight-blend target, because blending toward white on cream produces no visible change.

### Neutral — dark theme (grid)

- **Midnight Graphite** (`#1B1B22`): Backdrop, behind the triangle-grid shader. Also serves
  as the on-accent text color when the user picks a pale accent (luminance > 0.55).
- **Graphite Wash** (`#24242B`): App bar and `surface`.
- **Graphite Leaf** (`#2A2A33`): Cards, dialogs, menus.
- **Graphite Field** (`#30303A`): Field fills, tooltips, snackbars.
- **Bone** (`#E6E6EA`): Primary text and icons.

### Named Rules

**The Blended Line Rule.** Hairlines and outlines are never the raw accent and never raw
black or white. The accent is first lerped toward the theme's line target — white on dark at
42%, Ink Slate on light at 30% — and only then given an alpha (26% for dividers, 38% for
outlines in light; 24% / 34% in dark). This is what keeps a line legible whichever direction
the theme runs, and why the light theme needs *less* blending but *more* alpha.

**The Borrowed Contrast Rule.** Text sitting on an accent-colored fill picks its color from
the accent's own luminance, not from the theme. Above 0.55 luminance it takes Midnight
Graphite; below, white. A pale accent needs dark text in *both* themes, so the theme cannot
be the input.

**The Dark Scrim Rule.** Modal barriers stay black-based in both themes (55% dark, 28% light).
A light scrim over cream is indistinguishable from the page and stops reading as "behind a modal."

## Typography

**Display Font:** Iosevka Aile
**Body Font:** Iosevka Aile
**Label/Mono Font:** Iosevka Aile

One family, three weights (Light, Regular, Bold) with italic and oblique cuts, registered as
`IosevkaAile` and applied to every role. Iosevka Aile is the humanist, proportional member of
a family that began as a coding face — it carries the instrument register into running prose
without becoming a monospace pastiche. Nothing else is licensed to appear anywhere in the app.

**Character:** Even, quiet, and slightly narrow. It sets long journal entries without
fatigue, and it makes numeric columns in the finance ledger and analytics tables line up
with an exactness a normal humanist sans would not give you.

### Hierarchy

The scale is Material 3's English-like 2021 metrics with the family swapped — sizes and
weights are inherited, not hand-picked per screen. Roles below are the ones actually in use.

- **Display** (400, 57 / 45 / 36px): Reserved for the life tracker and full-canvas moments.
  Absent from ordinary task UI.
- **Headline** (400, 32 / 28 / 24px): Page-level headings on analytics and finance surfaces.
- **Title** (400, 22px large; 500, 16px medium; 500, 14px small): App bar titles, dialog
  titles, list-tile titles, section headers.
- **Body** (400, 16 / 14 / 12px, 1.5 line-height at large): Journal and dream entry text,
  menu items, popup menu labels, dialog content, snackbars. `bodyLarge` is the editor's
  default and the menu item's default in one — the reading and the choosing share a size.
- **Label** (500, 14 / 12 / 11px): Buttons, pills, chips, field labels, nav rail labels.
  The only role that carries a weight above 400 by default.

### Named Rules

**The One Family Rule.** Iosevka Aile is the typeface of the product, not a default. Never
introduce a second family for headings, code, numerals, or "personality." Contrast comes from
weight, size, and case — never from a face change.

**The Inherited Scale Rule.** Type roles resolve from the theme's `TextTheme`. Never hand-set
a `fontSize` on a widget when a role already fits; reach for `AppFonts.style()` only when
building something the scale genuinely does not cover.

## Layout

**Spacing rhythm.** A six-step scale on a 4px base with a 2px hairline step below it:
`xxs` 2, `xs` 4, `sm` 8, `md` 12, `lg` 16, `xl` 24. Dense list contexts additionally apply a
`-2.0` vertical visual density.

**The desktop shell.** A persistent 72px left icon rail carrying ten destinations, each item
68px wide on an 18px-radius highlight, separated from content by a 12px vertical divider.
Rail selection animates over 100–120 ms. On the journal and dream surfaces a second column
sits between rail and content, holding the entry list; its width is user-draggable via
`ResizablePaneDivider` and persisted across sessions. The dream journal opens at a 35/65 split.

**Content surfaces float on the background, they do not tile it.** Every page composes over
the full-bleed background pipeline rather than painting its own scaffold color, which is why
list rows use translucent fills (25% at rest, 65% selected, blended toward the scaffold tone)
instead of opaque ones — the paper grain must remain visible through the shell chrome.

**Responsive behavior is constraint-local, not breakpoint-driven.** There is no global
breakpoint scale in the codebase; components adapt through their own `LayoutBuilder`
constraints — a dropdown collapses its label under 100px, a to-do toolbar switches to an
overflow menu under 128px, the calendar grid drops to a compact layout when its computed font
size falls to 9px or below. New work should follow this pattern and adapt against the space a
component actually receives.

**Compose for the desktop window first.** The Windows shell is the design target; a layout is
resolved when it works there, at desktop widths, with hover and right-click available. Android
is a touch adaptation of that resolved design — same visual language, retuned for finger
targets and a narrow viewport — and it never drives a composition decision. When the phone
genuinely needs different structure rather than a tighter fit, make that an explicit second
layout, not a width check bolted onto the first.

## Elevation & Depth

**This system is flat by doctrine.** Depth is carried by tonal layering — four surface tones
stepping forward from scaffold to field — and by hairlines. Shadows exist only to separate a
floating surface from the page behind it, never to suggest height.

The light theme pushes shadows to 3–5% opacity and then spreads them **2.2× wider** to
compensate; at that opacity a tight shadow would vanish, and a visible edge would contradict
the matte paper. The dark theme keeps heavier shadows (18–40%) because a faint shadow on a
near-black backdrop is simply invisible, and there is no paper texture for it to muddy.
Shadow *color* also differs: pure black in dark, Ink Slate in light — Material's default black
on cream reads as grime.

Menus, dropdowns, and popup routes are set to **zero Material elevation with a transparent
shadow color** and draw their own separation instead. Surface tint is transparent everywhere;
Material 3's tonal-elevation overlay is disabled throughout.

### Shadow Vocabulary

- **Subtle** (`subtleShadowAlpha`: 3% light / 18% dark): Small floating elements — menu-item
  hover lift, chips, drag proxies.
- **Strong** (`strongShadowAlpha`: 5% light / 40% dark): Large floating surfaces — menus,
  popovers, dialogs, modals. Available ready-made as `VoyagerColors.surfaceShadow()`, which
  defaults to a 24px blur (×2.2 in light) at `Offset(0, 8)`.
- **Hairline** (9% light / 10% dark ink) and **Strong hairline** (14% / 15%): The primary
  separation tool. Reach for these before reaching for a shadow.

### Named Rules

**The Blur-Not-Black Rule.** To make a light-theme shadow read, widen the blur. Never raise
the opacity past 5%. `VoyagerColors.shadowBlurScale` exists to be multiplied into every blur
radius — a hand-written `BoxShadow` that ignores it will look correct in dark and wrong in light.

**The Grime Rule.** Never let a shadow default to black. Read `VoyagerColors.shadow`, which
resolves to Ink Slate on cream.

## Shapes

A six-step radius scale, assigned by role rather than by size:

- **Mark** (2px): The checkbox's inner fill — the only genuinely sharp corner in the system.
- **Tooltip** (8px): Tooltips.
- **Control** (12px): Glass buttons and selector pills (10px when dense).
- **Field** (14px): Text inputs and menu buttons.
- **Row** (16px): List tiles and sidebar list rows.
- **Surface** (18px): Buttons, cards, dialogs, menus, and rail items — the system's default
  and its most-used value.

The through-line is that **larger surfaces get larger radii**, inverting the common instinct
to round small controls hardest. A field is crisper than the card containing it.

Borders are 1px hairlines almost everywhere; the exceptions are earned. A focused input steps
to **1.8px in the accent at 95% alpha** — the single strongest border in the system, because
focus is the one state that must be unmistakable. Menu surfaces take a 1px accent-colored
edge. The glass button paints a dual-gradient specular stroke that thickens from 1.0 to 1.5px
on hover or focus.

Menu items clip their highlight to the menu's own corner: first item rounds its top, last item
rounds its bottom, middle items stay square. Highlights never round independently inside a
rounded container.

## Components

Controls are **machined and quiet**. They behave like well-made hardware — exact edges, fast
and small state changes, no bounce, no celebration. They respond immediately and then recede.

### Buttons

- **Shape:** Fully rounded corners (18px) on all Material button variants.
- **Filled / Elevated:** Accent fill with borrowed-contrast label. Elevation resolves by
  state — 1 at rest, 2 on hover or focus, 0 when pressed or disabled — with the theme's
  shadow color, never Material's default black.
- **Outlined:** Blended-line border at outline alpha, stepping to the accent line at 55%
  alpha on hover, focus, or press; 35% of outline alpha when disabled.
- **Text:** 16px horizontal / 12px vertical padding, 40px minimum height, compact density,
  shrink-wrapped tap target.
- **Hover / Focus / Press:** A single shared overlay across every button type — 8% `onSurface`
  on hover or focus, 16% on press. Transitions run 90 ms. **Splash is disabled globally**;
  there is no ripple anywhere in the app.

### Glass Button (signature)

The one component licensed to be lush, because it reads as an instrument face rather than a
painted surface. A `BackdropFilter` blur (σ 12) under a three-stop diagonal fill gradient,
finished with a dual-gradient specular border stroke and a top gloss reflection (18px tall, or
45% of an explicit height). Press drives a 0.96 scale over 100 ms in `easeOutCubic`, releasing
over 150. Glass opacity multiplies by state: 1.25× hovered, 1.4× pressed, 0.5× disabled. Focus
adds an accent glow at 50% alpha with a 1px spread. Every blur and shadow radius multiplies
through `shadowBlurScale`, so it holds up in both themes.

### Inputs / Fields

- **Style:** Filled with the most-forward surface tone (Ivory Field / Graphite Field), 14px
  radius, 1px blended outline. Content padding 16px horizontal / 18px vertical.
- **Focus:** The accent at 95% alpha, 1.8px, animated over 150 ms — plus the caret in the
  accent. `VoyagerTextField` draws its own **notched border**: the floating label cuts a gap
  in the stroke rather than sitting on a filled chip, and the label aligns to the top on
  multi-line and expanding fields.
- **Spellcheck:** Multi-line fields carry a custom squiggle layer painted beneath the text
  and a Voyager-styled correction menu. Single-line fields suppress the context menu entirely.
- **Hint:** `bodyMedium` at 55% `onSurface`.

### Selector Pill

The compact toolbar control. `surfaceContainerHighest` at 50% alpha, 12px radius, no border
at rest and a 1px accent border when active — activation is signalled by an edge, never by a
fill change. Dense variant tightens to 4px padding with a 14px icon.

### Cards / Containers

- **Corner Style:** 18px.
- **Background:** Ivory Leaf / Graphite Leaf.
- **Border:** 1px divider-alpha blended line — cards carry an edge, not just a shadow.
- **Shadow Strategy:** Theme shadow color; see Elevation.

### Menus & Popovers

Zero elevation, transparent Material shadow, 18px radius, a 1px accent edge, and zero padding
so items reach the surface edge. Items use `bodyLarge` and clip their hover highlight to the
menu's corner geometry. `showMenu` routes read the same style through
`VoyagerMenuTheme.showMenuStyle` so imperative menus cannot drift from declarative ones.

### Navigation

The left icon rail is the only global navigation. Phosphor icons, funnelled through
`VoyagerIcons` so a change propagates everywhere. Items sit on 18px-radius highlights, 68px
wide; selection carries an accent-alpha border and a background at 10% `onSurface`, animating
over 90–150 ms. Labels use `labelSmall` in both selected and unselected states — selection is
signalled by surface and border, never by a type-weight change.

### Checkbox

A hand-painted mark: 14×14 canvas, 2px-radius fill in the accent, with the tick drawn over a
200 ms sequence — `easeOut` on the fill, `easeOutBack` on the mark, and the stroke revealed
across the first 55% of the interval. The single `easeOutBack` in the system's core controls,
and it is spent here because checking something off is the most-repeated satisfying act in the app.

### Motion vocabulary

- **150 ms** is the house transition (used ~20× across the codebase); **90–120 ms** for
  state feedback on controls; **300 ms+** only for things that traverse space.
- **`easeOutCubic`** is the default curve, with `easeInOutCubic` for symmetric transitions
  and `easeOutBack` reserved for the checkbox mark.
- Page transitions run 180 ms.
- Background animation runs on its own timer — the petal field at 30 fps, decoupled from the
  display refresh so ambience never pins the app's frame pipeline.

## Do's and Don'ts

### Do:

- **Do** derive every line color through `Color.lerp(accent, lineTarget, lineAmount)` and then
  alpha it. The Blended Line Rule is what makes a user-chosen accent safe at any luminance.
- **Do** read semantic colors from `VoyagerColors.of(context)` — `hairline`, `strongHairline`,
  `scrim`, `shadow`, `chartGrid`, `highlightWash`, `onAccent`. Each one exists because the
  naive value (`Colors.white` at 10%, black shadow, white highlight) fails in one theme.
- **Do** multiply every blur radius by `shadowBlurScale`.
- **Do** blend toward `highlightWash` to make something read as lifted — white on dark, Ink
  Slate on light.
- **Do** keep the four surface tones tightly stepped. If a surface needs to read as more
  forward, give it a hairline, not a bigger luminance jump.
- **Do** put new icons in `VoyagerIcons` rather than referencing Phosphor sets directly.
- **Do** let backgrounds animate on their own timers, decoupled from the app's frame pipeline.
- **Do** test every new surface in both themes before calling it finished. They are two
  designed worlds, not a palette swap.

### Don't:

- **Don't** reintroduce Material 3's stock appearance — tonal elevation surfaces, filled-tonal
  buttons, FABs, or ripple splashes. This is the confirmed anti-reference.
- **Don't** hardcode the accent or any brand hue. The accent and petal colors are user
  settings; a literal `#7C9EFF` anywhere outside the theme's default parameter is a bug.
- **Don't** rely on the accent alone to carry meaning. It can be set to any hue at any
  luminance, so state must also be signalled by shape, position, weight, or an edge.
- **Don't** raise a light-theme shadow above 5% opacity. Widen the blur instead.
- **Don't** let a shadow default to Material's black on the cream theme.
- **Don't** introduce a second typeface, for any purpose.
- **Don't** hand-set `fontSize` where a type role already fits.
- **Don't** add ornament to controls. Decoration lives on the canvas layer — paper grain,
  petals, the triangle grid, the life tree — and the glass button is the one deliberate
  exception, already spent.
- **Don't** let a page paint its own opaque scaffold fill. Content composes over the
  background pipeline; opaque panels break the paper.
- **Don't** spend celebration motion on routine actions. `easeOutBack` and confetti are
  reserved for genuine milestones; everything else resolves in 90–150 ms without a bounce.
