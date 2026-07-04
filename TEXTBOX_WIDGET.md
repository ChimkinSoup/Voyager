# Text box widget: `NotchedFieldBorder`

This document describes the shared text-box chrome used across Voyager: a
rounded border, background fill, accent focus glow, and an optional
Material-style floating label that rises onto the border and notches it —
implemented **without** relying on Flutter's `InputDecorator` /
`InputDecoration` border-notching machinery.

It exists so every text box in the app (title fields, dialogs, the tag
highlighted journal/search body, etc.) looks and animates identically, while
remaining safe to wrap around composite/custom input widgets that manage
their own internal layout.

- Core widget: `lib/core/widgets/notched_field_border.dart` — `NotchedFieldBorder`
- Built on top of it: `VoyagerTextField`, `LabeledTextField`, `TagHighlightedTextField`

## Why a custom widget instead of `OutlineInputBorder`

Flutter's built-in notched floating label (`InputDecoration(border:
OutlineInputBorder())`) is tempting, but it's implemented *inside*
`InputDecorator`, which owns and can shift the layout of whatever it wraps
(padding, baseline, content origin all move slightly depending on label
state). That's fine for a plain `TextField`, but Voyager's journal/search
body field (`TagHighlightedTextField`) overlays a custom `CustomPaint` layer
on top of the `TextField` to highlight `#tags`, positioned using the *exact
same* `contentPadding` as the field. If the field's internal content ever
shifted (as it would under `InputDecorator`), the tag highlight overlay would
drift out of alignment with the actual text.

`NotchedFieldBorder` solves this by being purely decorative: it paints a
border, fill, glow, and label **around** an opaque `child`, and never
touches that child's internal layout. The child is trusted to already know
its own `contentPadding` (and to pass the *same* padding value to
`NotchedFieldBorder` purely so the label can be positioned to visually align
with where the child's text starts). This means wrapping any input —
simple or composite — never shifts it by a single pixel.

## How it works

`NotchedFieldBorder` is a `Stack`:

1. **Fill + glow layer** — a `DecoratedBox` behind everything, painting the
   background fill color and (when focused) an animated accent-colored drop
   shadow.
2. **`child`** — placed as the Stack's only non-`Positioned` widget, so it
   drives the Stack's size exactly as if the wrapper didn't exist
   (`StackFit.passthrough` is used so `child` receives the exact same
   constraints it would get without the wrapper — critical for `expands:
   true` fields).
3. **Border layer** — a `CustomPaint` (`_NotchedBorderPainter`) on top,
   stroking a rounded-rectangle outline. When a label is floated, the
   painter traces the rounded rect as a single **open path** that starts
   right after the label's gap and ends right before it, so the stroke
   simply never touches the gap segment. This mirrors how Flutter's own
   `OutlineInputBorder` draws its notch, but is computed independently.
4. **Label layer** — a plain `Text` widget, repositioned and rescaled by
   directly interpolating its `top` offset and `TextStyle` (font size +
   color) with an `AnimationController`-driven `t` value. No text is
   custom-painted; it's a normal, accessible `Text` widget that happens to
   be animated by hand instead of by `InputDecorator`.

### Two independent animations

| Controller | Driven by | Affects |
|---|---|---|
| `_floatController` | `focused \|\| hasContent` | Label vertical position, label font scale (1.0 → 0.75), border gap width |
| `_focusController` | `focused` only | Border color, label color (neutral → accent), glow opacity |

Splitting these matters: a field with existing text but no focus should stay
**floated** (label up, out of the way) but **not accent-colored** (border
and label revert to neutral) — exactly like a standard Material text field.

### The notch math

- The label's **resting** position is `top: contentPadding.top`,
  `left: contentPadding.left` — this works uniformly for both single-line and
  multi-line/expanding fields because every field in the app renders its text
  with `textAlignVertical: TextAlignVertical.top`, so real text always starts
  at `contentPadding.top` regardless of field height.
- The label's **floated** position has its vertical center sit exactly on
  the top border line (`top: -floatedLabelHeight / 2`), font scaled to 75%
  of its resting size (the standard Material floating-label scale).
- The border's **gap width** grows in sync with `floatT` (not just snapping
  open), matching real Material Design's floating-label animation.
- The gap horizontally starts at `contentPadding.left - 4` (4px breathing
  room around the label), clamped so it never overlaps the rounded corners.

## Using it directly

Most call sites should use one of the three ready-made field widgets below
instead of `NotchedFieldBorder` directly. Reach for `NotchedFieldBorder`
itself only when building a new composite input widget (like
`TagHighlightedTextField`) that needs this chrome around something other
than a bare `TextField`.

```dart
NotchedFieldBorder(
  focusNode: focusNode,
  label: 'Title',          // null/empty => plain border, no notch
  hasContent: controller.text.isNotEmpty,
  accentColor: accentColor, // defaults to theme.colorScheme.primary
  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
  child: TextField(
    controller: controller,
    focusNode: focusNode,
    textAlignVertical: TextAlignVertical.top,
    decoration: const InputDecoration(
      border: InputBorder.none, // avoid a doubled-up border
      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 18),
    ),
  ),
)
```

Key rules for any `child` you wrap:

- Its own `InputDecoration` (if any) should set `border`/`enabledBorder`/
  `focusedBorder` to `InputBorder.none` and `filled: false` — the wrapper
  already draws the border and fill.
- Its `contentPadding` must match the value passed to `NotchedFieldBorder`,
  or the label won't align with the actual text.
- Use `textAlignVertical: TextAlignVertical.top` so resting-label alignment
  is correct (see "notch math" above).
- The caller is responsible for tracking `hasContent` reactively (e.g. a
  controller listener that calls `setState` when emptiness changes) —
  `NotchedFieldBorder` itself doesn't listen to controllers, since not every
  wrapped `child` necessarily has one.

## The three higher-level field widgets

### `VoyagerTextField` (`lib/core/widgets/voyager_text_field.dart`)

Takes a full `InputDecoration` (so `helperText`, `labelText`, etc. all work
as before). Internally splits it: `labelText` is pulled out and handed to
`NotchedFieldBorder`, while the rest of the decoration (helper text, etc.)
still flows into the inner `TextField` as usual, with its border suppressed.

Used for: analytics tracker dialogs, settings hex-color input.

### `LabeledTextField` (`lib/core/widgets/labeled_text_field.dart`)

Takes `label`/`hintText` directly instead of a raw `InputDecoration`. Has a
`showLabel` flag for the (rare) case where a field wants a plain hint-only
box instead of a floating label (e.g. "Add task", "Add subtask" — a
permanent label would be redundant for a single-purpose quick-add field).

When both a real label and a `hintText` are supplied (e.g. the dev "Journal
entry ID" field, which shows an example ID as a hint), the widget tracks
focus reactively and only reveals the hint once the label has floated out of
the way — otherwise the resting label and the hint would print on top of
each other, since they occupy the same spot.

Used for: journal title/quote, todo title/notes/subtask, calendar event
title/notes, login email/password, all "create/rename" dialogs, weather
location, dev API key/purge tools, and the sync-conflict manual-merge box.

### `TagHighlightedTextField` (`lib/core/widgets/tag_highlighted_text_field.dart`)

Wraps a `Stack` of `[highlight-paint layer, TextField]` used to render
`#tag` pill highlights behind typed text (journal body, search box, search
result body). This is the widget that originally made the notched-label
approach hard — see "Why a custom widget" above. It now takes an optional
`label` (unused by current call sites, since a floating label doesn't suit a
full-height writing area — but supported for completeness and future
reuse). Since `NotchedFieldBorder` never touches its child's layout, the tag
highlight overlay's alignment is completely unaffected either way.

## Known limitations / non-goals

- **No RTL-mirrored notch position.** The gap is anchored from the left
  edge. Voyager is English-only today; if RTL support is ever added, the
  gap anchor and label `left` position would need to mirror based on
  `Directionality`.
- **No error-state border color.** Only enabled/disabled/focused states are
  themed. If validation error styling is needed later, add an `errorText`/
  `hasError` parameter that overrides `borderColor`/`labelColor`.
- **Helper/error text is enclosed within the bordered box**, the same as it
  was before this widget existed (this is inherited pre-existing behavior,
  not a regression — `helperText` renders inside the wrapped `TextField`,
  which is what the whole chrome sizes itself around).

## Intentional exception: the inline todo-item rename field

`lib/features/todo/todo_edit_panel.dart` has one raw `TextField` (the
click-to-rename control on an individual subtask row) that was **not**
migrated to this system. It uses `InputBorder.none` with no label and dense
padding — a compact, borderless inline-edit control embedded directly in a
list row, not a standalone labeled field. Giving it a rounded border and a
floating label would change that row's compact layout and wouldn't make
semantic sense (there's nothing to label — the row's leading text already
identifies the field). If this control is ever redesigned into a standalone
field, it should adopt `LabeledTextField`/`NotchedFieldBorder` like
everything else.

## Files touched by this migration

- Added: `lib/core/widgets/notched_field_border.dart`
- Rewritten (internals only, public APIs preserved): `voyager_text_field.dart`,
  `labeled_text_field.dart`, `tag_highlighted_text_field.dart`
- Removed: `lib/core/widgets/accent_focus_border.dart` (fully superseded)
- Migrated raw `TextField`s to `LabeledTextField`: `lib/features/sync/sync_conflict_banner.dart`,
  `lib/features/dev/dev_remote_purge_tile.dart`
- Left as an intentional exception: `lib/features/todo/todo_edit_panel.dart`
  inline subtask rename field
