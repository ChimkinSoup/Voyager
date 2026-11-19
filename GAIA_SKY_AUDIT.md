# Gaia Sky Audit

Scope: `73955392` (experimental sky), `9b5145e1` (performance pass), and the uncommitted satellite changes in `lib/features/gaia/companion/gaia_sky.dart`. Also covers the parts of `gaia_starfield.dart`, `gaia_app.dart` and `gaia_controller.dart` that the sky depends on.

I found these by reading the code. I did not run the app, so items marked **(verify)** are the ones I'm less sure of.

---

## 1. Bugs

### B1. In a filled chat the starfield turns at about half its intended speed
`gaia_starfield.dart:162` (dt cap), `:90` (`_turnStep`)

Once the lean has settled, the starfield stops its ticker and wakes up every `_turnStep` (500 ms). On waking, `_tick` measures how long it has been since `_lastTick`. That gap is about 0.5 s, but it gets clamped to `0.25`, so each step turns the stars only half as far as it should. In practice, after the sky leaves, the starfield turns at about `0.5 × skyRotation × kGaiaFilledSpin`. That contradicts the doc on `_lastTick` ("frames or not between them") and breaks the speed hand-off: the sky coasts down to `kGaiaFilledSpin` and then the starfield drops to half of that.

At the default 6°/min the difference is too small to see, but the logic is wrong and it scales with the rotation slider.

**Fix:** set the cap above `_turnStep`, for example `min(..., 1.0)`, or cap at `_turnStep.inMicroseconds / 1e6 * 2`. **Test:** pump 5 s while active without a cursor and check that the angle turned matches `rate × 5`.

### B2. Stars near the edges jump brighter when an exit starts, and dim suddenly when a blink-in ends
`gaia_sky.dart:2173-2187`

```dart
if (p == null) {
  alpha *= min(nearest / _edge, 1);   // edge fade
} else {
  alpha *= switch (exit) { ... };     // edge fade dropped
}
```

While `exiting != null` (every exit, every blink-in, the reversal after an undone send, and the debug "Play exit"), the 24 px edge fade is skipped. On the first frame of an exit, every star in the 24 px band along all four edges (including the sidebar edge and just under the header) jumps to full brightness. When a blink-in finishes, they drop back. The streaks and the starfield both keep their edge fade throughout, so the jump is noticeable.

**Fix:** apply `min(nearest / _edge, 1)` in both branches. For warp/converge, you could also fade by the position of the moved end point, but the base fade is the actual bug.

### B3. A satellite that leaves through the top or bottom keeps one of the three slots after it's gone (uncommitted change)
`gaia_sky.dart:1587-1597`, cap at `:1550`

`y1 = y0 ± 0.25h`, so `y1` can be anywhere from `-0.17h` to `0.83h`. A satellite heading up crosses the top edge part way through its path and then keeps flying off-screen until `age >= life`. With the new 20–90 px/s speeds, `life` can be 60–80 s, so an invisible satellite can hold one of the three slots for half a minute or more. Off-screen satellites also keep being stepped and drawn (they're clipped, but `_satellite` still runs).

**Fix:** compute `end` as the point where the line meets the sky's rectangle (plus the margin), or remove a satellite once it's more than `margin` outside `size` in any direction.

### B4. After an undone send, the greeting jumps back instantly while the sky plays back slowly (verify)
`gaia_app.dart:3399-3400`, `gaia_controller.dart:5838`

If a send fails, `undo()` puts the user back on a new chat, so the chat is empty again mid-exit. The sky handles this well (`returning = true`, and the exit plays backwards over `exitTime`; there's a test for it). The greeting, though, comes back under the same `ValueKey(GaiaDraft.newChatId)`, so `_EmptyChat` is updated in place with `leaving: null`, and its tween runs back to 0 over `Duration.zero`. The line and hints reappear in one frame while the stars are still flowing back in. The greeting's clear (see D4) comes back at full strength on that same frame.

**Fix:** reverse over the same duration, e.g. `duration: leaving ?? _lastLeaving ?? Duration.zero`, or give the reverse its own `exitTime`-based duration.

### B5. The aurora gets a hard cut at the sidebar edge, where the stars fade out
`gaia_sky.dart:2022-2024`, `:2083-2084`, clip at `:1799`

The aurora mesh always runs from `x = -step` to the full width, and its softened ends are at `0` and `last`. With the sidebar open, the canvas is clipped at `from`, so the aurora's left side is cut off sharply at the sidebar. The stars, streaks and starfield all fade out over 20–24 px at that same edge.

**Fix:** build the columns from `from - step`, and soften with `_normal((x - from + step) / _auroraBlur)`. Since `left` is already a repaint listenable, the aurora would follow the sidebar as it slides.

### B6. Switching satellite style mid-flight can make a train pop out (debug only)
`gaia_sky.dart:1590-1592`, `:2488-2500`

The train margin (`10 + _trainCars × _trainGap`) is calculated when a satellite spawns, using the style at that time, but each frame draws with the *current* style. If you switch to Train while a satellite is in flight, its path ends 10 px past the edge, so the head reaches the end while cars 1–7 are still on screen and the whole train disappears. `sendSatellite()` also ignores the new three-at-a-time cap. This is low priority since it only happens through the debug panel. Storing the style on `_Streak` would fix both.

### B7. Changing an interval slider doesn't reschedule events that are already pending (debug only)
`gaia_sky.dart:1545`, `:1552`

`_nextEvent` and `_nextSatellite` are set from `eventInterval` only when they fire. If you drag "Meteors" from 60 down to 3, you can still wait up to `60 / 0.3 × 1.25 = 250 s` for the next satellite. Scaling the remaining time by `new / old` when the interval changes would fix it. Also, the slider is still labelled "Meteors" even though it now controls both meteors and satellites.

### Checked and not a bug
- **Which exit plays:** `_sky.exit` is fixed on the first frame the chat isn't empty, so a send could in theory show as a blink-out. It doesn't: `send()` sets `_sentFrom` before `list.add` (`gaia_controller.dart:5798`), so `justSent` is already true on that frame.
- **Mid-exit focus loss:** `settle()` jumps straight to the end state, which is reasonable.
- **Dispose order:** children are unmounted before their parent, so `_glow?.call(0)` in `dispose` reaches the starfield's `_Stars` before it is disposed.

---

## 2. Performance

The sky ticks every frame while it's showing and the window is focused. Each frame it repaints two full-window layers (the sky, plus the starfield, because `turn()` notifies every frame). On 120/144 Hz displays that cost doubles. Rough budget per frame at 1600×900 with default settings:

| Work | Per frame |
|---|---|
| Stars computed (sqrt + cos + sin + 2 `Offset`s each) | ~1,000 (up to ~3,900 at max density) |
| Of those, on screen | ~42% |
| Star draw calls (`drawRawPoints` buckets) | up to 300 (3 tints × 4 radii × 25 levels) |
| Aurora vertices (each with 4–8 table lookups) | ~6,500 |
| Starfield `drawCircle` calls | ~240 |

### P1. Lower the frame rate when nothing fast is on screen (biggest win)
At 6°/min, a star 1,500 px from the pole moves about 2.6 px/s, or 0.04 px per frame at 60 Hz. Twinkle runs at 0.4–1.6 rad/s and the aurora at 0.08–0.29 rad/s. None of these need 60–144 Hz. Only meteors, the tracing pen, sparkles, and exits/entrances do.

**Suggestion:** use the starfield's approach. Tick every frame while a meteor, sparkle, pen, exit or `cleared` fade is active; otherwise step at 20–30 Hz with a `Timer`, the same way `_turnStep` works. On a 144 Hz display that's a 5–7× reduction most of the time.

### P2. Stop rebuilding star buffers every frame
`gaia_sky.dart:2164`, `:2275-2282`

Each frame builds growable `List<double>`s (which box doubles on the VM) and then copies each one with `Float32List.fromList`. Two options:
- Keep one preallocated `Float32List` per bucket (or a single buffer with offsets per bucket) on the painter or `_Sky`, and pass `Float32List.sublistView`.
- Better: draw every star in **one** call with `drawVertices` (a small quad per star with per-vertex colour) or `drawAtlas` with a 1-pixel round sprite and a `colors` list. Alpha is then exact per star, so the 25 opacity levels and the 300 buckets go away.

### P3. Skip the off-screen part of the sector before doing trig
`gaia_sky.dart:1350-1357`

- The radius `sqrt(_rMin2 + u[i] × (_rMax2 - _rMin2))` only changes on layout. Store it in a `Float32List` inside `layout()`.
- `theta` is cheap to compute before the `cos`/`sin`. Skip any star whose `theta` is outside `[a0 - ε, a1 + ε]` (keep `a0`/`a1` from `layout`). That removes most of the `_reach` margin, which is about 30% of the stars, before any trig or `Offset` allocation.

### P4. Aurora: reuse the buffers and the index list
`gaia_sky.dart:2027-2032`

`positions`, `colors` and `indices` are allocated again every frame. `indices` only depends on `columns`, so cache it and rebuild only when the width changes. Keep `positions`/`colors` as fields sized for the current column count. The aurora is also the slowest-moving layer, so it's the first candidate for a lower update rate (P1), or for being redrawn every other frame.

### P5. Batch the starfield too
`gaia_starfield.dart:325-348`

The starfield repaints every frame while the sky drives it, using 240 separate `drawCircle` calls. Bucketing them into `drawRawPoints` with round caps (like the sky) or one `drawVertices` call would bring that down to a handful.

### P6. Minor
- The `trails` exit builds a `Path` with one arc per star every frame, up to ~3,900 arcs at max density. It only runs for `exitTime`, but it's the heaviest exit. If it ever stutters, a single `drawVertices` strip per tint would be cheaper.
- `paint()` mutates the model (`sky.lean`, `sky.layout`). It works, but it means `_Sky.step` runs on the previous frame's size and sidebar edge. That's fine now; just keep it in mind if anything in `step` starts depending on them more heavily.

---

## 3. Design and feature gaps

### Transitions

**D1. The entrance depends on the send-exit setting, so "open a chat" and "come back" don't match by default.**
Leaving for another chat always blinks out, but arriving only blinks in when `exit == blinkOut` (`_blinkIn`, `gaia_sky.dart:301-307`). With the default `warp`, a new chat fades in for 0.8 s while the previous one blinked out. **Suggestion:** decide the entrance independently. Always blink in when arriving from another chat (the mirror of the blink-out), and keep the plain fade only for the first launch.

**D2. Entrances are much simpler than exits.**
There are seven exits and essentially one entrance. Some cheap mirrors:
- *Aurora:* fade in by lowering curtains from the top (`rise` reversed) rather than just opacity.
- *Constellations:* trace the first one sooner after arrival (`_wait = 2.0` now) so a new chat feels alive quickly.
- *Starfield glow:* the starfield glows on blink-in too (`0.8·sin(πp)` runs during the reversal). That's fine for a blink, but check that it's intended.

**D3. Converge and warp aim at hard-coded points.**
`_target` is `(centre, height - 60)` and the warp centre is `0.42h` (`gaia_sky.dart:1926-1927`, `:2154`). The composer grows with multi-line drafts and attachments, and the greeting isn't always at 0.42h. **Suggestion:** measure the composer the same way `GaiaSkyClear` is measured (a small `GaiaSkyTarget` widget with a key the sky reads), and start the warp from the greeting's centre. Converge would then actually pour into the text box the prompt came from.

**D4. The greeting's clear fades on its own schedule.**
The clear fades linearly with `1 - exiting`, while the greeting fades over `Interval(0.15, 0.55)` of its own leave. For a quick blink-out (`GaiaMotion.move`, shorter than `exitTime`), the greeting is gone well before its dark patch, so a soft dark blob sits where it was for most of the exit. Fading the clear with the greeting's own leave progress would line them up.

**D5. Reduced motion jumps instantly.**
Under `disableAnimations`, the sky appears and disappears in one frame. Reduced-motion guidance generally still allows short opacity crossfades. A 150–200 ms fade, ticked only for that duration, would feel less abrupt and still be calm.

### Composition

**D6. Constellations and sparkles can land behind the greeting, where they're hidden.**
`_stepDrawing` only avoids the window edges and the bottom 28% (`gaia_sky.dart:1483-1488`). Constellation centres sit at 0.18–0.68h, right across a centred greeting. The clear is drawn last in the background colour, so a traced figure loses its middle under a blurred patch, and its stars' flares are hidden too. Sparkles can also be spent on stars behind the clear. **Suggestion:** pass the clear rects into `_Sky` (the painter already has them) and treat them as exclusion zones when choosing a constellation (`points(c)` versus inflated clears) and a sparkle star.

**D7. The whole sky moves during a live window resize.**
`layout()` derives the pole, `_rMin`, the sector and `starCount` from the size. Dragging the window edge moves every star's polar position each frame, so the whole sky slides, constellations jump, and the "first N" stars pop in and out as the area changes. The starfield, by contrast, keeps normalised positions. **Options:** settle the sky's geometry with a short delay after resizing finishes, or keep `_pole`/`_rMin` fixed to the largest size seen so far and let the clip hide the extra.

**D8. A short window can put a dark hole in the aurora.**
The greeting shows down to a 200 px tall chat area. There, it overlaps the aurora bands (0.13–0.27h plus curtain height), and the clear cuts a dark rounded patch out of the aurora. You could fade the aurora below a minimum height, or skip it entirely there.

### Feature ideas (pick and choose)
- **Constellation names:** when a figure finishes tracing, fade in its name in small text under it ("Orion") during `_hold`. Most of what's needed already exists (`_Shape` would just need a name), and it makes the tracing feel intentional rather than decorative.
- **Occasional meteor shower:** once every few minutes, 4–6 meteors over 2–3 s coming from one radiant point. This is cheap with the current `_meteor()` if you add a shared origin and angle.
- **Reaction to typing:** the sky ignores the composer until send. A very slight response would tie the background to the input, such as the aurora brightening a few percent while there's a draft, or one sparkle on the first keystroke. Keep it subtle.
- **User-facing setting:** every control is in the debug panel. Ship an "Animated background: on / still / off" setting. "Still" is the reduced-motion path (already supported), and "off" saves battery on laptops.
- **Pick a default exit:** `converge` matches the idea best ("the prompt takes the sky with it"), especially after D3. `warp` is more dramatic but means the same thing for every chat.

---

## 4. Tests worth adding

| Covers | Test |
|---|---|
| B1 | The starfield turns `rate × t` over several 500 ms steps with no cursor. |
| B2 | Paint a star 10 px from an edge at `exiting = null` and at `exiting = 0.01` (fade exit); its alpha should barely change. A recording canvas and the `drawRawPoints` paint alpha are enough. |
| B3 | Spawn satellites with a seeded `Random` until one exits through the top, then check that it's removed (or its slot freed) within a frame or two. |
| B4 | An undone send restores the greeting over the exit time, not in one frame. Pump half of `exitTime` and check the greeting's opacity is between 0 and 1. |
| D6 | Constellations whose points fall inside a clear rect are never picked. |

---

## 5. Priority summary

| # | Item | Effort | Impact |
|---|---|---|---|
| B2 | Keep edge fade during exits | 2 lines | Visible on every send |
| P1 | Lower the tick rate when nothing fast is moving | Small | Largest CPU/GPU saving, especially at 120/144 Hz |
| B1 | Starfield dt cap | 1 line | Correctness of the speed hand-off |
| B3 | Satellites exiting through the top/bottom hold slots | Small | Affects the uncommitted change you're about to commit |
| D1 | Blink in when arriving from another chat | Small | Exit and entrance match |
| B5 | Aurora softens at the sidebar | Small | Visible whenever the sidebar is open |
| D6 | Constellations avoid the greeting | Small–medium | Traced figures stay readable |
| P2 / P3 | Star batching, precomputed radius, culling | Medium | Steady per-frame saving |
| B4 / D4 | Greeting/clear timing | Small | Polish on edge cases |
| D3 | Measured converge/warp targets | Medium | Converge actually lands in the composer |
