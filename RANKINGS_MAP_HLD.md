# Rankings — Map View & Entry Locations HLD

Give ranking entries real-world locations (one or more per entry), and show them on a map where they can be searched, filtered, opened, rated and created. Built for restaurants; available to any category that turns it on.

Related: `RANKINGS.md` (§3.4 editor, §4.1–4.2 model, §6 search/filters, §7.1 lifecycle, §8 sync), `RANKINGS_UI.md` (§2 page chrome, §2.2 category switcher, §4 filter popover), `RANKINGS_PARENT_TAGS_HLD.md` (§5.3 lifecycle carve-out, §7 filters), `RANKINGS_SCORE_INPUT_HLD.md` (§7 score popover).

This document **extends**:

- `RANKINGS.md` §4.1 (add `locationEnabled`), §4.2 (add `locations`), §3.4 (panel gains a Locations section), §7.1 (location edits are a carve-out from auto in-progress)
- `RANKINGS_UI.md` §2.1 (toolbar gains a List / Map toggle), §2.2 (switcher gains an **All categories** entry)

It does **not** lift `RANKINGS.md` §9 "URLs / links on parents": a pasted Google Maps link is read for its coordinates and thrown away, never stored.

Status: **proposed** (2026-09-30).

---

## 1. Goals

- Attach one or more locations to an entry (a chain is one entry with many branches).
- Show entries as pins on a map, each pin carrying the entry's score; unranked entries as hollow pins.
- Open the usual editor panel from a pin; quick-rate from a pin.
- Create entries, or add branches to existing ones, by right-clicking the map.
- Find a place three ways: type its name, paste a Google Maps link, or drop a pin.
- Search, status chips and filters apply to the map exactly as they apply to the list.
- An **All categories** map that overlays every location-enabled category, each toggleable.

## 2. Non-goals (v1)

- Live data of any kind: traffic, opening hours, ratings, photos, reviews from a provider
- Per-branch scores (one score per entry, shared by every branch — §3)
- Locations on **children**
- Directions / routing / distance-from-me
- "Near me" search or sorting by distance. The device's position is used only to open and centre the map, mark it, and pick which branch the panel preview shows (§3 Initial view, §7.1)
- Viewport-scoped stats ("best in this area") — header stats ignore the map viewport
- Storing the pasted link or a provider place id
- In-app map restyling (styles are fixed provider styles — §4.1)
- Offline area download (tiles cache as viewed; no prefetch)
- A cross-category **list** — All categories is map-only

---

## 3. Product decisions (locked)

| Decision | Choice |
|----------|--------|
| **Map widget** | `flutter_map` — pure Flutter, runs on Windows and Android; pins are ordinary widgets. `maplibre_gl` rejected (no desktop); `maplibre` rejected (WebView on Windows, no Flutter widgets on the map) |
| **Tiles** | Geoapify raster tiles; **no** Mapbox or Google map |
| **Place search** | Geoapify Address Autocomplete, `type=amenity`. Geoapify permits permanent storage of results, which the synced model requires |
| **Opt-in** | Per category: `locationEnabled` toggle, default off |
| **Locations per entry** | Zero or more; each is its own pin |
| **Score** | One per entry; every branch pin shows it |
| **Pin content** | Score number only (`formatRankingScore`) — no stars |
| **Unranked pins** | Hollow, no number — covers `queued` and `inProgress` alike |
| **Pin click** | Opens the entry's editor panel |
| **Quick-rate** | From the pin's context menu → existing score popover |
| **Right-click map** | New entry here / Add this location to an existing entry… |
| **Search / filters** | Same providers as the list; sort does not apply to the map |
| **Header stats** | Unchanged — follow search + filters, not the viewport |
| **Global map** | **All categories** entry in the category switcher; per-category visibility chips |
| **Auto in-progress** | Location edits do **not** promote `queued` → `inProgress` |
| **Location off** | Hides map + Locations section; stored locations kept (same as child units off) |
| **Clustering** | Overlapping pins cluster with a count at low zoom |
| **Initial view** | The device. The first map of a run opens on the device's last saved position (with none saved, it fits the visible pins), then moves to a fresh fix at street zoom (18.75) unless the map has been touched. A later map in the same run reopens where the last one was left. **Fit** re-fits to the visible pins. The opening locate never asks for permission; it uses what the OS already allows, and with no fix the opening view stands. (Changed from "fit visible pins; with none, the last viewport on this device" after BUG-168: kept as built.) |

---

## 4. Map stack

### 4.1 Tiles & look

- `TileLayer` over `https://maps.geoapify.com/v1/tile/{style}/{z}/{x}/{y}@2x.png?apiKey=…`.
- Style follows the app theme: **`positron`** in light, **`dark-matter`** in dark. Both are muted, so accent-colored pins carry the page. (Alternatives to trial: `osm-bright-grey`, the `dark-matter` variants.)
- Everything drawn *on* the map — pins, clusters, popovers, zoom controls, attribution — is Voyager widgets in Voyager theme.
- **Attribution is mandatory** and shown on the map: "Powered by Geoapify" (free plan), "© OpenStreetMap contributors", "© OpenMapTiles".
- Deeper restyling later means switching to Geoapify's vector tiles + `style.json` via `vector_map_tiles`. Out of scope for v1.

### 4.2 API key & budget

- `GEOAPIFY_API_KEY` via `--dart-define`, same shape as `OPENWEATHER_API_KEY` in `lib/app/providers.dart`.
- No key: map area shows a calm "Map unavailable — no Geoapify key" state; the Locations section still lists stored locations and accepts pasted links with full coordinates.
- Free plan: 3,000 credits/day. Tiles cost 0.25 each (12,000 tiles/day); autocomplete and reverse geocode cost 1 each. Personal use sits far under this; search is debounced (300 ms, min 3 characters) to keep it that way.

### 4.3 Tile cache

- Viewed tiles cached on disk so revisited areas render offline and don't re-spend credits.
- Uncached tiles offline render blank; pins still draw (they are local data).

---

## 5. Domain model

### 5.1 `RankingCategory`

| Field | Notes |
|-------|--------|
| `locationEnabled` | `bool`, default `false`. Toggled in the category dialog alongside the gallery flags |

### 5.2 `RankingLocation` (value, embedded in the parent)

| Field | Notes |
|-------|--------|
| `id` | UUID, stable across edits — keys the sync stamp (§5.4) |
| `latitude` / `longitude` | `double`, required |
| `address` | Formatted address from the provider; `''` when unknown |
| `label` | Optional user text (`Queen St`, `Airport`); `''` default |
| `sortOrder` | Order in the panel list; new locations append |

Display name for a location: `label` if set, else `address`, else the coordinates.

### 5.3 `RankingParent`

| Field | Notes |
|-------|--------|
| `locations` | `List<RankingLocation>`, default `[]` |

Not on `RankingChild` in v1.

### 5.4 Storage & sync

- Drift: `locationsJson` text column on `RankingParentsTable` (default `'[]'`), `locationEnabled` bool on the categories table. Schema version bump.
- Same reasoning as `tagsJson`: locations are only read with their parent, and the map reads parents anyway.
- **One stamp key per location**: `loc:<id>` in `rankingParentStampValues`, value = the encoded location. This makes branches merge independently — two devices adding different branches offline both keep theirs.
- **Removal** writes the key's value as `null`. `_restamp` already keeps the stamp of a key whose value was emptied, so a removal carries a timestamp and beats an older copy of that branch on another device. The merge rebuilds `locations` from the winning non-null `loc:*` values, ordered by `sortOrder`.
- Firestore mapper, remote merge, and full-app import/export carry `locations`; legacy payloads without the field load as `[]`.
- Soft delete / restore: locations travel with the parent; a deleted parent's pins leave the map.

### 5.5 Lifecycle carve-out

`_promotesToInProgress` (`ranking_queries.dart`) promotes on `notes`, `fieldValues` and `createdAt` only, so `locations` sitting outside that set gives the carve-out for free — pin it with a test, as tags did. Pinning a place you want to try is not starting it.

---

## 6. Finding a place — the Add location dialog

One dialog, reached from the panel's **Add location** button and from the map context menu (§7.4). Layout: a single input on top, a small map below with a draggable pin, **Add** / **Cancel**.

### 6.1 Type a name (search)

- Geoapify Address Autocomplete: `text=<query>`, `type=amenity`, `bias=proximity:<lon>,<lat>`, `filter=circle:<lon>,<lat>,30000`.
- Bias point: the open map's center if a map is showing, else the entry's first location, else wherever the map was last left in this run, else the device's last saved position.
- The 30 km filter is required, not a tuning knob: bias alone lets same-named places in other countries into the list (the probe got Wisconsin, New Haven and Kyoto results for Waterloo queries). When the filtered search returns nothing, the dropdown offers **Search everywhere**, which repeats the query without the filter.
- Suggestions show name + formatted address. Choosing one moves the preview pin; `address` = the result's formatted address.
- A result with no `amenity` match falls back naturally to addresses — the user can still type a street address.

### 6.2 Paste a Google Maps link

The same input detects a URL on paste and resolves it instead of searching.

| Link shape | Coordinates taken from |
|------------|------------------------|
| `…/place/…/data=…!3d<lat>!4d<lng>…` | `!3d` / `!4d` — the place itself (preferred) |
| `…/@<lat>,<lng>,<zoom>z…` | `@lat,lng` — the viewport center (fallback) |
| `…?q=<lat>,<lng>` / `ll=<lat>,<lng>` / `…/maps/search/?api=1&query=<lat>,<lng>` | query parameter |
| `maps.app.goo.gl/…`, `goo.gl/maps/…` | follow the redirect (no auto-follow; read `Location`), then parse the target as above |

- The place name in `/place/<Name>/` is URL-decoded and offered as the new entry's title when the dialog is creating an entry (§7.4).
- After parsing, one reverse-geocode call fills `address`.
- Only Google Maps links are read: `maps.google.<tld>`, or `google.<tld>/maps…` with or without `www.` (BUG-170). Any other site's URL gets the unparseable-link error, even one that happens to contain `@lat,lng`.
- Unparseable link: inline error "Couldn't find a location in that link"; nothing is added.
- The link itself is never stored.

### 6.3 Drop a pin

- Click anywhere on the dialog's map (or drag the pin) to set the point; one reverse-geocode call fills `address` after the pin settles.
- Also the refinement step for 6.1 and 6.2: any result can be nudged before **Add**.

### 6.4 Duplicates

Adding a location within ~25 m of one the entry already has shows "This entry already has a location here" and does not add it.

---

## 7. Map view

### 7.1 Where it lives

- Toolbar (`RANKINGS_UI.md` §2.1) gains a **List / Map** segmented toggle, shown only for location-enabled categories.
- Map replaces the list area; the side panel slides over it as it does over the list (420 px, 220 ms).
- The chosen view persists per category (existing page-prefs pattern). The viewport is kept only for the rest of the run: it is not stored and does not sync, so the next launch opens on the device again (§3 Initial view). The device's last position is stored on this device (`settings_table.rankings_device_latitude` / `_longitude`) and does **not** sync; the map marks it with a dot, and a **Show my location** button in the map controls flies there, asking for permission if needed.
- Entries with no locations are not on the map. A small chip on the map reads `N without a location`; clicking it switches to List view.

### 7.2 Pins

| State | Look |
|-------|------|
| Ranked | Solid pin in category accent; score number (`formatRankingScore`) in the on-accent color |
| Unranked (`queued` / `inProgress`) | Hollow pin, accent outline, no number |
| Entry open in panel | Every pin of that entry raised + ring; others unchanged |
| Hover (desktop) | Tooltip: entry title · location display name |
| Cluster | Neutral bubble with count; click zooms to fit its members |

A chain's branches are separate pins that each cluster normally.

### 7.3 Pin interactions

| Gesture | Result |
|---------|--------|
| Click / tap | Open the entry's editor panel |
| Right-click / long-press | Menu: **Open**, **Rate…**, **Edit location…**, **Remove this location** |
| **Rate…** | Existing score popover (`RANKINGS_SCORE_INPUT_HLD.md` §7) anchored at the pin; commit follows normal rules — an unranked entry becomes ranked and its pins turn solid |
| **Remove this location** | Removes that branch only; soft-delete undo pattern (snackbar) |

### 7.4 Map context menu (empty map)

| Item | Result |
|------|--------|
| **New entry here** | Opens the Add location dialog seeded with the clicked point (reverse-geocoded); on **Add**, runs the same create flow as the Add FAB with the location attached — title required, prefilled from a pasted link's place name if the user pastes one; status `queued` |
| **Add this location to an existing entry…** | Picker listing the current scope's entries (searchable by title); choosing one appends the location to it |

Hidden in archived (view-only) categories.

### 7.5 Search, status & filters

- The map reads the same filtered-entries provider as the list: search box, status chips, score range, has-images and tag filter all apply.
- Sort controls are disabled in Map view (order is meaningless on a map).
- Changing filters does not move the camera; **Fit** button in the map controls re-fits to what is visible.

---

## 8. All categories map

### 8.1 Entry point

- Category switcher (`RANKINGS_UI.md` §2.2) gains an **All categories** row at the top, shown when at least one active (non-archived) category has `locationEnabled`.
- It is **map-only** — no List toggle.

### 8.2 Chrome

| Element | Behavior |
|---------|----------|
| **Category chips** | One per location-enabled category (icon + name, accent color); toggle visibility; state persists per device |
| **Pins** | Each in its own category's accent; score on its own category's scale |
| **Search** | Across visible categories |
| **Status chips** | Apply as usual |
| **Tag filter** | Vocabulary = union of visible categories' structured tags; a tag name shared by two categories matches in both |
| **Score range filter** | Hidden — 5- and 10-point scales don't share a range |
| **Hero stats** | Visible-entry count only; no average (mixed scales) |
| **Panel** | Opens with the entry's own category template |
| **New entry here** | Asks for the category first (location-enabled, non-archived only) |
| **Add to existing entry** | Picker spans all visible categories, grouped by category |

Archived categories and categories with location off never appear.

---

## 9. Editor panel

- New **Locations** section, shown when the category has `locationEnabled`. Placement: after Tags, before status pills / custom fields.
- Rows: display name + secondary address line; click a row → the map (if open) pans to it; row menu: **Rename**, **Edit location…** (dialog, §6), **Remove**.
- **Add location** button opens the dialog (§6).
- Drag-reorder rows (`sortOrder`).
- Empty: just the **Add location** button, no placeholder text.

---

## 10. Behaviors & edge cases

| Case | Behavior |
|------|----------|
| Location-only edit while queued | Stays queued |
| Location + notes edit while queued | Promotes to in progress |
| Entry with 4 branches, rated from one pin | All 4 pins show the new score |
| Clear overall score | All branch pins turn hollow; entry demotes to in progress (unchanged rule) |
| Category location turned off | Map toggle + Locations section hidden; data kept; out of All categories |
| Turned back on | Locations reappear unchanged |
| Device A adds branch X, device B removes branch Y, both offline | After sync: X present, Y gone |
| Device A edits branch X's label, device B removes X later | X removed (later stamp wins) |
| Offline | Pins draw; cached tiles draw; search shows "Search needs a connection"; full links parse; short links need a connection; drop-pin works over cached tiles |
| No API key | §4.2 |
| Search returns nothing | "No places found" + hint to paste a link or drop a pin |
| Filter hides every pin | Empty map with the current filters still visible; no camera move |
| Soft-deleted entry | Its pins leave the map; restore brings them back |
| Soft-deleted category | Out of All categories; restore returns it |

---

## 11. Acceptance criteria

1. Category dialog has a location toggle; off by default; off hides all map/location UI without losing data.
2. Panel Locations section adds via search, pasted link (long and short forms) and dropped pin; each can be nudged before adding.
3. An entry can hold multiple locations; each renders as its own pin with the entry's score.
4. Ranked pins show the score number only; unranked pins are hollow.
5. Clicking a pin opens the entry's panel; the pin's context menu quick-rates via the score popover.
6. Right-click on empty map creates a new queued entry at that point, or adds the point to an existing entry.
7. Search, status chips and filters narrow the map the same as the list.
8. All categories map overlays location-enabled categories with per-category toggles; score range filter hidden; count-only stats.
9. Location edits never promote queued → in progress.
10. Concurrent offline add/remove of different branches on two devices both survive sync.
11. Sync, trash/restore and full-app import/export round-trip `locations` and `locationEnabled`; legacy data loads as `[]` / `false`.
12. Geoapify / OSM / OpenMapTiles attribution always visible on the map.
13. Map works on Windows and Android.

---

## 12. Implementation sketch (non-binding)

| Area | Likely touchpoints |
|------|--------------------|
| Packages | `flutter_map`, `latlong2`, a marker-cluster plugin, a tile-cache provider — check versions against current Flutter before adding |
| Model | `ranking_models.dart` — `RankingLocation`, `RankingParent.locations`, `RankingCategory.locationEnabled`, `loc:<id>` in `rankingParentStampValues` |
| DB | `app_database.dart` — `locationsJson`, `locationEnabled`, migration |
| Sync / I-O | `firestore_document_mapper.dart` (parent + category mappers, per-location merge), import/export |
| Queries | `ranking_queries.dart` — carve-out test; all-categories filtered provider; union tag vocab |
| Remote | New `GeoapifyClient` beside `dev_openweather_client.dart` (autocomplete, reverse geocode) |
| Link parsing | Pure function + tests over each link shape in §6.2; short-link resolver behind it |
| UI | `rankings_map_view.dart` (map, pins, clusters, menus), `rankings_location_dialog.dart`, Locations section in `rankings_edit_panel.dart`, toggle in `rankings_header.dart`, switcher row + chips, `locationEnabled` in `rankings_category_dialog.dart` |
| Tests | Link parser; stamp merge of add/remove/edit across devices; carve-out; filters on map; legacy decode |

**Step 0 — done (2026-09-30), Waterloo, ON:** 13 of 14 found as the top result, correct address and category. That covered 12 local restaurants, pubs and cafés, plus chains (Lazeez and Tim Hortons returned several nearby branches each). Partial typing (`ennio`, `kinkaku`) also hit on the first result. The one miss was Nick and Nat's Uptown 21. `type=amenity` beat untyped search, which filled misses with junk. Some addresses lack a house number (`Phillip Street`); coordinates were still right. Provider confirmed.

---

## 13. Risks

| Risk | Mitigation |
|------|------------|
| Geoapify (OpenStreetMap) restaurant coverage is thinner than commercial POI data | Step 0 probe; paste-link and drop-pin always available |
| Google changes its Maps URL format | Parser is isolated and tested; `@lat,lng` fallback; drop-pin always works |
| API key ships inside the binary | Personal app; Geoapify free plan caps spend at zero |
| Free plan limits | Tile cache + search debounce; usage far below 3,000 credits/day |

---

## 14. Decision log (this feature)

| Topic | Decision |
|-------|----------|
| Map widget | `flutter_map` (not `google_maps_flutter`, `maplibre_gl`, `maplibre`) |
| Tiles / search provider | Geoapify both. Mapbox rejected: its POI search is temporary-use only, and its results must be shown on a Mapbox map |
| Map style | Fixed raster styles `positron` / `dark-matter` by theme |
| Locations | Many per entry; parent only |
| Score | One per entry, shared by all branches |
| Pin | Score number only; unranked hollow |
| Quick-rate | Pin context menu → score popover |
| Find a place | Search + paste Google link + drop pin, one dialog |
| Link storage | Never stored |
| Opt-in | Per category `locationEnabled` |
| Promote on location edit | **No** |
| Global view | All categories switcher row; map-only; per-category chips |
| Mixed scales in global | Hide score range filter and average |
| Viewport stats | Out of scope |
| Initial view | Opens on the device, not fitted to the pins; viewport not kept across launches (BUG-168, kept as built; §3 and §7.1 updated 2026-10-09) |
| Storage | JSON column on parent; per-location stamp keys for merge |
