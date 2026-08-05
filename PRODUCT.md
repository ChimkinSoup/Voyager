# Product

<!-- impeccable:product-schema 1 -->

## Platform

android

**Windows desktop is the design target. Android is the only native mobile target.**

Voyager ships to Windows and Android; neither is a web surface. The token above is `android`
because that is the one native mobile platform in play — it is not a statement of priority.
Priority runs the other way:

- **Design resolves on the desktop shell first.** New surfaces are designed for the Windows
  window — persistent icon rail, multi-column layouts, mouse and keyboard density, hover
  states, right-click menus, global hotkeys. A design is "done" when it works there.
- **Android follows the desktop design, adapted for touch.** Same visual language, same
  structure where it fits, retuned for small screens and finger targets. It is a port of a
  desktop design, not a parallel design, and never the surface that drives a decision.
- **The design language is not per-OS.** Voyager does not adopt Material affordances on
  Android or Fluent on Windows; it wears its own look on both. `adaptive` would mean the
  opposite and is deliberately not used here.

Android still owes its platform the OS-level guarantees regardless of visual language:
system Back and the predictive Back gesture must work, window insets (status bar, navigation
bar, display cutout, IME) must be applied, touch targets stay at least 48×48 dp, type uses
`sp` so it follows the system font-size setting, and the "Remove animations" accessibility
setting must be honored — which matters for the petal layer. These are correctness
requirements, not design decisions, and they do not license Material styling.

See `## Operating Context`.

## Users

A single primary user: the author, using Voyager as a daily driver across a Windows desktop
and an Android phone. The job is running one's whole life out of one app — writing the day's
journal entry, capturing dreams on waking, checking off tasks, logging spending, tracking
habits and moods, and periodically zooming out to see patterns across months and years.

Confirmed audience posture: **me first, others later.** Voyager is built for its author's
own use, but the door is open to a second user. Design work should avoid decisions that
would make onboarding a stranger impossible, without yet paying the full cost of designing
for one. First-run flows, tutorial copy, and hand-holding empty states are not currently
required; density, speed, and precision for a user who already knows the product are.

## Product Purpose

A local-first journaling and life-tracking application that keeps the complete record of a
person's days on their own devices, syncing between them through Firestore without a
dedicated backend. Success is the app being worth opening every single day — fast enough to
capture a thought before it's gone, complete enough that no part of the daily record lives
somewhere else, and durable enough that years of entries accumulate into something the user
returns to.

## Positioning

Two commitments a neighboring journaling app could not truthfully copy:

- **Every device holds the entire database.** Not a cache, not a sync-on-demand subset — a
  full local copy on each instance, with Firestore as the meeting point between them.
  Character-level sequence CRDTs resolve concurrent edits to the same entry, so two devices
  editing the same day never produce a "which version won" dialog.
- **The journal is not a separate silo from the tracking.** Statistics, moods, rankings,
  finances, and calendar events attach to the same daily record as the writing, and the
  periodic prompts (weekly, monthly, yearly) surface inside the journal flow rather than in
  a separate check-in app.

## Operating Context

- **Windows desktop is the primary shell.** Persistent left icon rail, a second column of
  entry lists on the journal surface, wide split-pane editors, and mouse/keyboard density.
- **Global hotkeys are a defining desktop workflow.** Two customizable Windows shortcuts
  open small standalone popups — one focused on a new journal entry for today, one focused
  on a new to-do task — without booting the full application UI. The app is not meant to
  run resident in the background beyond the hotkey listener, so cold-start speed is a
  product requirement, not an optimization.
- **Android mirrors the desktop.** Same visual language, adapted for touch.
- **Daily and periodic rhythm.** Daily statistics appear on every entry; weekly, monthly,
  and yearly trackers, rankings, and surveys surface when their period closes — and if the
  user misses the date, the prompt still appears at the next launch rather than being lost.
- **Sync is between the user's own devices**, not collaborative. No multi-user editing, no
  sharing, no permissions model.
- **Read-only Google Calendar ingest**, claimed via a Firestore lock so only one device
  syncs at a time. Events created in Voyager never write back to Google Calendar.

## Capabilities and Constraints

**Implemented surfaces** (nav order, `lib/features/shell/shell_destinations.dart`):
Journal · Dream Journal · To-do · Calendar · Search · Analytics · Finance · Life Tracker ·
Developer tools · Settings. Plus a Login surface and the Windows hotkey popups.

**Confirmed functionality:**

- **Journal** — multiple named journals with separate entries, markdown body (headings,
  bold, `==highlight==`; no font or size control), plain-text title, `#tag` autocoloring with
  stable per-tag colors, editable timestamps defaulting to creation date, weather
  auto-tagging, mood out of 10, guided-journaling prompt cycling, and a per-entry quote
  drawn without repetition from `assets/quotes.json` (persisted in metadata even when the
  user hides quotes).
- **Dream Journal** — adjustable split-pane with a chronological dream list and a borderless
  zen editor, plus a collapsible/pinnable scratchpad.
- **To-do** — multiple named lists, task metadata, live Firestore listeners rather than
  debounced push, because task state is time-sensitive.
- **Calendar** — week/month/year views, local events with colors and notes, full-day default,
  and switchable heatmaps per statistic.
- **Analytics** — user-defined statistic trackers (boolean, integer with optional cap, enum
  with options), 1/X rankings on a configurable gradient, and graphs over week/month/year/
  all-time.
- **Finance** — transaction ledger with tags and notes, subscription and bill radar with
  annualized cost display, tag-based soft budgets with pacing, and income-vs-expense and
  category-breakdown analytics.
- **Life Tracker** — a single canvas rendering a life in weeks as a watercolor tree: ~4160
  leaves for 80 years, accent-colored blossoms that reveal computed life statistics on click.
- **Search** — token-based keyword search across titles and bodies (all tokens must match)
  and tag search.
- **Settings** — light/dark theme toggle, accent and petal colors, week start day, particle
  parameters, and per-feature preferences.

**Technical constraints:**

- Flutter, Dart SDK `^3.12.2`. Drift/SQLite for the local database on both platforms;
  Firebase Auth, Cloud Firestore, and Cloud Functions for identity and sync.
- **Local-first and offline-always is non-negotiable.** Every surface must work with no
  network and no account. Sync is an enhancement, never a prerequisite.
- Writes are debounced (default 3s, code-level constant, not a user setting) before pushing
  a whole document; time-sensitive features like to-do bypass the debouncer.
- One document per day per data kind, keyed by UUID with date as a mutable metadata field.
- Soft deletes with a 30-day recycling bin before hard deletion.
- Lazy loading at startup; older data pulls from the local database on demand.
- `firebase_auth` is pinned to a local patched copy at `third_party/firebase_auth-6.5.3`
  to fix a Windows platform-thread violation; re-apply when upgrading.
- Custom fragment shader at `shaders/geometric_texture.frag` backs the textured canvas.

**Explicitly undecided / incomplete:** remote sync currently covers journals, journal
entries, to-do lists and tasks, and some settings. Calendar events, trackers, rankings,
tag colors, entry- and task-level soft-delete push, historical journal pull on scroll,
`sync_operations` cleanup, and a durable offline outbox are still outstanding
(`RELEASE_CHECKLIST.md`, `PLAN.md`). Study tracker, life timeline, timed surveys, and the
bucket/dream list are specified in `PLAN.md` but not yet built as surfaces.

## Brand Commitments

Binding for now; changeable only with the user's explicit agreement, except where noted.

- **Name:** Voyager.
- **Typeface:** Iosevka Aile (Thin / Regular / Bold, with italic and oblique cuts) bundled
  at `assets/`. It is the typeface of the product, not a placeholder.
- **User-chosen accent and petal colors.** The theming system is structural: no surface may
  hardcode a brand color. Accent and petal colors are separate settings and must stay
  visually distinct from each other.
- **Textured canvas and ambient particle layer.** Warm off-white/cream paper texture in
  light theme, a preserved dark theme, and semi-translucent watercolor petals drifting on
  sine-wave wind. These belong to every page, not to one.
- **Flat and matte.** Shadows stay at 3–5% opacity with a large blur radius so the UI reads
  as integrated into the textured surface rather than floating above it.
- **Local-first, offline-always** — the one commitment the user marked as necessary and not
  open to revision.

## Evidence on Hand

- `PLAN.md` — the original full product specification, in the user's own words. The most
  authoritative statement of intent in the repository.
- Per-feature specifications written by the user: `LIFE_TRACKER.md`, `FINANCIAL_TRACKER.md`,
  `DREAM_JOURNAL.md`, `ANALYTICS_PAGE.md`, `ANALYTICS_EXPLANATION.md`, `WHITE_THEME.md`,
  `BACKGROUND.md`, `GLASS_BUTTON.md`, `TEXTBOX_WIDGET.md`, `TIME_SELECTOR.md`,
  `WEEKLY_CALENDAR.md`, `IMPORT_EXPORT.md`, `UNIFIED_NOTIFICATIONS.md`, `FEEDBACK.md`.
- `docs/adr/001-local-first-data-model.md`, `002-sync-protocol.md`, `003-module-structure.md`.
- `RELEASE_CHECKLIST.md` — the real, current state of what sync does and does not cover.
- Real assets: Iosevka Aile font families, `assets/quotes.json`, `assets/dictionary_en.txt`
  (spellcheck), `shaders/geometric_texture.frag`.
- **No customers, testimonials, usage data, press, pricing, or third-party validation
  exist.** This is a personal application. Future work must not fabricate any.

## Product Principles

1. **The daily record is one thing.** Writing, tracking, tasks, money, and events belong to
   the same day. Resist designs that split a day's life across disconnected silos.
2. **Capture speed beats everything.** A thought must reach the app before it's lost — cold
   start, hotkey popups, and first keystroke latency are product features, not performance
   details.
3. **Offline is the normal case.** Design every surface as if the network is absent and the
   account does not exist; sync state is reported, never required.
4. **The record must survive.** Soft deletes, CRDT merges, and full local copies exist so
   that no edit, on any device, in any order, can lose a day.
5. **Ambient, not decorative.** The paper texture, petals, and watercolor world set a mood
   for long-form reflection; they must never cost legibility, input latency, or battery.
6. **Everything the user tracks is theirs to define.** Statistics, journals, lists, tags,
   colors, and budgets are user-created. Design for structures the user invents, not for a
   fixed set the product ships.

## Accessibility & Inclusion

No product-specific accessibility standard has been established. One structural need is
already confirmed: because the accent and petal colors are user-chosen, contrast cannot be
guaranteed at design time — surfaces must remain legible across the full range a user can
pick, and meaning must never rest on an accent color alone.
