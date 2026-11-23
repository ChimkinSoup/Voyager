# Gaia — Lifetime Stats (HLD)

Status: **Design (2026-11-22). Phase 1 built and checked live 2026-11-22 (§8.1); Phase 2
built and checked live 2026-11-22 (§8.2).** A small lifetime tracker for Gaia, separate
from `/usage`: lifetime tokens (moved out of `/usage`), the rare satellites and rare
auroras you've seen, meteors seen, chats started and days active.

## 1. Summary

- **Opened** by clicking the sidebar's moon, or with **`/stats`** (§2).
- **Shown** as a dialog, like `/usage` (`showDialog`, `gaia_app.dart:7699`), in Gaia's
  look (§5).
- **What it holds:**
  - A row of headline numbers: days active, chats started, meteors seen, lifetime tokens.
  - **Rare satellites**: one tile for each of ISS, Array, Hubble and Dish, showing its
    icon, count and first-seen date.
  - **Rare auroras**: one tile for each of crimson, mauve, twilight and gold, the same way.
  - **Lifetime tokens**: the whole breakdown now in `/usage` (`gaiaTokenLines`), moved
    here unchanged. `/usage` keeps only the plan-usage bars.
- **Items you haven't seen yet** show as locked placeholders: a dim silhouette, "???",
  and no count (§5.2).
- **"Seen" means seen**: Gaia's window is on screen and focused, the sky is up, and the
  roll was natural, not forced from the debug menu (§3).
- **Stored in Firestore**, next to the token count, and added to with increments, so
  every desktop adds to the same totals (§4). The companion still never touches Firebase
  itself (GAIA_HLD.md §3.2). It tells the host over the pipe, the same way it reports
  `tokensUsed`.

## 2. Opening it

| Way | |
|---|---|
| The sidebar's moon | `_placedMoon(…, GaiaMoonPlace.sidebar)` (`gaia_app.dart:2013`) becomes clickable: hand cursor, hover glow as on the header's icons, and the phase still in its tooltip. Only the sidebar's moon is clickable. The greeting's and sky's moons stay as they are. |
| `/stats` | A new `GaiaBuiltin.stats` in `gaia_commands.dart`, handled like `usage` (`gaia_controller.dart:4671`): it adds to a `_statsOpens` stream that the shell listens to. |
| Closing | Esc, ×, or a click outside, as with `/usage`. |

The moon's visibility doesn't change. When it's off, or placed elsewhere, `/stats` is the
only way in. That's intended: these aren't numbers you need to see all the time.

**Implementation note:** the sidebar title sits inside the window's drag area. The code
there already warns that a double click on the drag area delays its clicks
(`gaia_app.dart:2028`), so the moon needs to be outside the drag area or claim its own
taps. Otherwise opening the tracker will feel slow.

## 3. Counting

### 3.1 When something counts

The sky is only up on the new-chat screen (`GaiaSky.shown`). An event counts only when
all of these are true at that moment:

1. `controller.onScreen` and `controller.focused` are both true. Hiding and minimising
   already blur the window (`gaia_companion_main.dart:280`).
2. The sky is shown and isn't leaving (`shown && exiting == null`).
3. The event came from a natural roll (§3.3).
4. The debug menu's dummy mode and the sky tour are off.

| Event | Counts when |
|---|---|
| **Rare satellite** | It has been inside the sky's visible area for **3 s in total** while 1-4 hold. It doesn't need to cross the whole window. Counted once per satellite. |
| **Rare aurora** | Once per sky: the first moment the rare aurora is up while 1-4 hold. Usually that's when `_Sky.begin()` rolls it. If the window gains focus a moment after the roll, the same sky still counts (§7.1). |
| **Meteor** | Each meteor, ordinary or from a shower, created while 1-4 hold. |
| **Chat started** | The first prompt of a new chat is saved (`isNew` in the send path, `gaia_controller.dart:6430`). Forks, side questions and Ask Gaia chats don't count. |
| **Day active** | Any prompt is sent. The day is your local date. |

### 3.2 Where it's detected

- **Sky events** are detected in `_Sky` (`gaia_sky.dart`), which already steps every
  streak (`_stepStreaks`) and rolls the aurora (`begin`). A `_Streak` gains a
  `counted` flag and an `inView` timer. `_Sky` reports events through one callback,
  `onSighting(GaiaSighting)`, and is told whether it may count through a `counting`
  flag. The flag is the AND of 1, 2 and 4 above, set by `GaiaSky` from widget
  parameters. Keeping the window state outside `_Sky` keeps it testable without a
  window.
- **Chats and days** are reported by `GaiaController` from the send path.

### 3.3 Natural rolls only

| Debug control | Counts? |
|---|---|
| "Always the rare aurora" (`forceRare`) | No. An aurora counts only if `_rare` rolled it. |
| "Rare colours" set (`rareColours != null`) | No. The colour must come from `_pickColours()`. |
| A rare satellite chosen as the look (`satellite.share > 0`) | No. Only satellites picked by `_pickRare()` count. |
| The test buttons (`satelliteTest`, `burstTest`) | No. Their streaks are marked as test spawns, even if a rare look rolls. |
| Event rate, shower strength, "rare satellites" off | These change how often things come, not whether a sighting is real. Rolls under them still count, and "rare satellites" off simply means none roll. |

### 3.4 Batching

Rare sightings, chats and days are sent straight away, since they're rare. Meteors
are frequent, so the companion adds them up and sends the running count every 60 s
and when the window blurs or hides.

## 4. Storage

### 4.1 Pipe

The companion sends one notification for everything:

```
statsSeen {kind: 'satellite'|'aurora'|'meteors'|'chat'|'day', id?, n?, day?}
```

`id` is the satellite's or aurora's enum name. `n` is the meteor batch. `day` is
`yyyy-MM-dd`, taken from the companion's local clock. The host passes it to a new
`GaiaStatsCounter`, the same way `tokensUsed` reaches `GaiaTokenCounter`
(`gaia_host.dart:1240`). The host sends the current stats to the companion in `hello`
and in a `stats` event whenever they change, as `tokens` does (`gaia_host.dart:378`).

### 4.2 Firestore

The stats are one document, `users/{uid}/gaia_stats/lifetime` (new
`FirestoreCollections.gaiaStats`):

```
satellites: { iss: {count, first}, array: {...}, hubble: {...}, dish: {...} }
auroras:    { crimson: {count, first}, mauve: {...}, twilight: {...}, gold: {...} }
meteors:    int
chats:      int
days:       { '2026-11-22': true, ... }
```

- **Counts** use `FieldValue.increment` with `SetOptions(merge: true)`, the same as
  tokens, so two desktops never overwrite each other.
- **Days** are a map of dates, and days active is the map's size. Setting a date is
  idempotent, so two desktops active on the same day count it once. Each entry is
  about 25 bytes, so the document's 1 MB limit is decades away.
- **`first`** is written with the increment only when the host's latest snapshot has
  no `first` for that item. If two desktops race on the same first sighting, the later
  write wins, and the two dates are seconds apart. That's accepted rather than adding a
  transaction.
- **Signed out**, events are dropped, as tokens are.
- **Offline**, Firestore queues the writes as usual.
- **Rules:** `gaia_tokens` needed no rules change. Confirm the same holds for
  `gaia_stats` at build time.

### 4.3 What starts at zero

There is no history for sightings, chats or days, so they count from when this ships.
Tokens keep their existing lifetime totals.

## 5. The dialog

### 5.1 Layout

From top to bottom, capped at the same width as `/usage`:

1. **Title** "Stats", with × on the right.
2. **Headline row**: four stat tiles, each a large number with a small label. Days
   active, chats started, meteors seen, and lifetime tokens (compact, e.g. "48.2M").
3. **Rare satellites**: a row of four tiles, rarest first (ISS, Hubble, Array, Dish).
   Each shows its icon, name, "×3" and "First seen 14 Nov 2026".
4. **Rare auroras**: four tiles in the same style, rarest first (gold, mauve, twilight,
   crimson).
5. **Lifetime tokens**: the heading and `gaiaTokenLines` exactly as `/usage` has them
   now, followed by "Not read yet" while there's no data.

At narrow widths, the tile rows wrap to two per row.

### 5.2 Locked placeholders

An item with no count shows its icon as a flat silhouette in the theme's dim ink, with
no colour, glow or animation. Its name reads "???" and there's no date. Once it's seen,
the tile shows the real icon, name, count and date.

### 5.3 Icons

These are the real drawings, not new art:

- **Satellites:** each rare look's case in `_SkyPainter`'s satellite switch
  (`gaia_sky.dart:3063`) moves into a shared
  `paintGaiaSatellite(canvas, look, at, direction, {flare, time, scale})`. The sky and
  the tile both call it. Tiles draw the craft still, level, and scaled to fit about
  28 px. A silhouette is the same call with one flat colour.
- **Auroras:** a small rounded swatch with the three curtain colours from
  `_rareColors(colours)` (`gaia_sky.dart:2178`), main, high and low, drawn as soft
  vertical bands over the sky's background colour. That helper becomes public as
  `gaiaRareAuroraColors`.

## 6. `/usage` afterwards

The "Lifetime tokens" section and its listening to `controller.tokens` are removed from
the `/usage` dialog. `gaiaTokenLines` moves to the stats dialog's file unchanged, along
with its `@visibleForTesting` tests. `/usage`'s description in `gaia_commands.dart`
already only mentions plan usage.

## 7. Decisions (2026-11-22)

1. The moon is clickable **only in the sidebar**, and its visibility is unchanged.
   `/stats` is the fallback.
2. "Seen" means **on screen and focused**. A satellite counts after **3 s in view**, not
   a full crossing.
3. **Only natural rolls** count (§3.3).
4. Unseen items are **locked placeholders**.
5. **First-seen dates** are shown for each rare satellite and aurora.
6. Extras: **meteors seen, chats started, days active**. No easter eggs.
7. The **whole token breakdown** moves out of `/usage`.

### 7.1 Choices made in this write-up (reverse if wrong)

- **Aurora counted once per sky, not strictly at the roll.** The roll happens as the
  new-chat screen comes up, which can be a frame before the window reports focus. A
  strict at-the-roll check would drop real sightings. A sky that's never focused while
  up still doesn't count.
- **The 3 s threshold** is a constant (`kGaiaSightingSeconds`), easy to tune.
- **Meteors** are one total, not split by shower.
- **"Day active"** means a day you sent at least one prompt, not just opened Gaia.

## 8. Phases

The feature is small to medium, roughly 700-900 lines including tests, and could be
built in one go. Two phases are still recommended:

| Phase | Scope | Why separate |
|---|---|---|
| **1. Counting and storage** | `GaiaSighting`, the `counting` flag and detection in `_Sky` (§3), chat and day reports, the `statsSeen` pipe message, `GaiaStatsCounter` and the Firestore document (§4), and the `stats` hello/event to the companion. No UI. | It starts collecting data straight away. The risky logic (focus, the 3 s threshold, natural-only rules) is checked on its own against the real Firestore document, before any UI sits on top. |
| **2. The dialog** | `paintGaiaSatellite` extracted, aurora swatches, locked placeholders, the dialog (§5), the clickable sidebar moon and `/stats` (§2), and tokens moved out of `/usage` (§6). | It's all presentation, checked by rendering. Tokens leave `/usage` in the same phase the dialog arrives, so they're never unreachable. |

Both phases touch `gaia_sky.dart` and `gaia_app.dart`, which are very large files.
Splitting the work keeps each diff reviewable.

### 8.1 Phase 1 as built (2026-11-22)

- **Model:** `usage/gaia_stats_model.dart` has `GaiaStats`, `GaiaSeen` and
  `gaiaStatsDay`. Pipe JSON carries first-seen dates as milliseconds; Firestore stores
  them as `Timestamp`s, which the counter converts.
- **Counter:** `remote/gaia_stats_counter.dart` is created in `voyager_app.dart` beside
  the token counter and attached to the host as `stats:`. The host handles
  `statsSeen` and sends `stats` in `hello` and on every change.
- **Sky:** `GaiaSky.onSighting` reports a `GaiaSighting` record. Satellite and aurora
  are both null for a meteor. `_Sky.seeing` follows the `active` listenable, which is
  `controller.skyActive`: focused, and not covered by the settings panel. Satellites
  carry `countable` and `seen`. Test bursts are subtracted through `_testMeteors`, and
  `sendSatellite` marks its streaks as tests. `GaiaSky.random` (`@visibleForTesting`)
  lets tests rig the rolls.
- **Controller:** `noteSighting` sends rare sightings at once and batches meteors,
  sending them after 60 s or on blur. `_noteSent` runs after a send's chat is saved:
  `chat` when the chat is new, and `day` once per local day for each companion run.
  `gaia_app.dart` passes `onSighting: null` in dummy mode.
- **Not built:** first-seen is skipped when a sighting arrives before the counter's
  first snapshot. The count is still added, but that item never gets a date. This
  would need a sighting within moments of sign-in, so it's accepted.
- **Checked:** 12 new tests (`gaia_sky_test`, `gaia_controller_test`,
  `gaia_stats_test`), with all 2002 Gaia tests passing. Live on `gaiaqa`
  (voyager-qa-128) from an out-of-tree build: sightings round-tripped through Firestore
  to the companion, a repeat sighting kept its first-seen date, dummy mode counted
  nothing, and with dummy mode off two sends in one new chat gave `chats: 1` and
  today's day. The sky's focus gating wasn't driven live, since showing Gaia's window
  takes the focus; the widget tests cover it.

### 8.2 Phase 2 as built (2026-11-22)

- **Dialog:** `companion/gaia_stats.dart` has `showGaiaStats`, the tiles, and
  `gaiaTokenLines` (moved from `gaia_app.dart`). Headline labels sit one word per line,
  and the first-seen line is always two lines, so tiles in a row are the same height
  whether seen or locked. Below 360 px wide, the rows wrap to two tiles per row.
- **Icons:** `paintGaiaSatellite` in `gaia_sky.dart` now draws the four rare craft for
  both the sky and the tiles. `flat: true` leaves out glow, blinks, glints and the
  dish's pulse. Tiles draw at `time: 0`, heading right, fitted to 64×32 using
  per-craft bounds kept in `gaia_stats.dart`. At time 0 the Array shows its glint
  cross and the Dish its red wingtip light, which reads well, so it was left that way.
  Silhouettes go through a `srcIn` colour-filter layer. `_rareColors` is now public as
  `gaiaRareAuroraColors`.
- **Silhouette ink:** `GaiaInk.faint`, not `dim` as §5.2 says. `dim` (#D4D4D4) made
  locked tiles as bright as seen ones.
- **Moon:** the sidebar title row is now `Gaia` in its own drag area, then a
  `_MoonButton` (hand cursor, accent radial glow on hover), then an expanding drag
  area. The moon no longer sits inside a `DragToMoveArea`.
- **`/stats`:** `GaiaBuiltin.stats`, `controller.statsOpens`, listened to beside
  `usageOpens`. `/usage` no longer listens to `controller.tokens`.
- **Light theme:** Gaia only has a dark theme (`_onGaiaSurface`), so §9's
  light-theme screenshot doesn't apply.
- **Checked:** the `/stats` composer test (8 locked tiles, then a seen ISS with its
  count and date), the `/usage` test asserting no lifetime tokens, the moved token-lines
  test in `gaia_stats_test`, and palette expectations updated for `stats`. All 2003
  Gaia tests pass. A scratch golden of the dialog with a seeded document was inspected
  and then deleted.
- **Live (2026-11-22, `gaiaqa`, voyager-qa-128, repo Debug build plus a fresh bundle,
  background input):** a click on the sidebar moon opened the stats with the real
  document (Hubble ×2, Gold ×1, 1 day, 1 chat, 3 meteors, 207K tokens). Esc and ×
  both closed it. `/stats` showed first in the palette, and Enter opened the dialog,
  cleared the draft and sent nothing. A Dish sighting reported with the dialog open
  went through the host and Firestore and unlocked the Dish tile in place. That
  sighting is still in qa-128's document. `/usage` showed only the plan bars. The
  header's drag areas measured 0-66 and 96-216 logical px either side of the moon's
  66-96, so the window can still be dragged on both sides. A real mouse drag wasn't
  run.

## 9. How it's checked

**Phase 1**

- `gaia_sky_test`: with a seeded random and `counting` on, a natural rare satellite
  reports one sighting after 3 s in view, and none before. With `counting` off it
  reports none. A satellite that leaves after 2 s reports none. A forced look, a test
  spawn, `forceRare` and set `rareColours` report none. Meteors report one each.
- Controller test: the first prompt of a new chat reports `chat` and `day`. A second
  prompt reports `day` only, and a fork reports neither.
- Counter test (fake Firestore): increments add up, `first` is written once, and days
  are idempotent.
- **Live:** run the companion focused on the new-chat screen and confirm `meteors` and
  `days` change in `users/{uid}/gaia_stats/lifetime`. Then minimise it and confirm they
  stop. Rare events are too rare to wait for live, so the unit tests cover them.

**Phase 2**

- Widget test: an empty stats document shows eight locked tiles. A seen ISS shows its
  count and date. The token lines render from rows, using the moved tests.
- `/usage` no longer shows lifetime tokens.
- **Live:** click the sidebar moon and run `/stats`, and screenshot the dialog in light
  and dark themes with a seeded stats document.

## 10. Files likely touched

| File | Change |
|---|---|
| `lib/features/gaia/companion/gaia_sky.dart` | Sighting detection, the `counting` flag, `paintGaiaSatellite`, and public aurora colours |
| `lib/features/gaia/companion/gaia_controller.dart` | Chat and day reports, meteor batching, `stats` state, `_statsOpens`, and `GaiaBuiltin.stats` |
| `lib/features/gaia/companion/gaia_app.dart` | Passing `counting` to `GaiaSky`, the clickable sidebar moon, the `/stats` listener, and removing tokens from `/usage` |
| `lib/features/gaia/companion/gaia_stats.dart` (new) | The dialog, tiles and placeholders, plus `gaiaTokenLines` moved here |
| `lib/features/gaia/companion/gaia_commands.dart` | `stats('stats', 'Show lifetime stats')` |
| `lib/features/gaia/usage/gaia_stats_model.dart` (new) | `GaiaSighting` and `GaiaStats` with JSON |
| `lib/features/gaia/remote/gaia_stats_counter.dart` (new) | Firestore reads and increments |
| `lib/features/gaia/host/gaia_host.dart` | `statsSeen` handling, plus `stats` in hello and as an event |
| `lib/core/sync/firestore_collections.dart` | `gaiaStats` |
| `lib/app/voyager_app.dart` | Creating `GaiaStatsCounter` and attaching it to the host |
| `test/gaia_sky_test.dart`, `test/gaia_controller_test.dart`, `test/gaia_stats_test.dart` (new), `test/gaia_tokens_test.dart` | As in §9 |
