# Inbox Popover — UI Redesign HLD

Visual and interaction redesign for the global notification inbox popover (nav-rail tray icon). **North star: `DESIGN.md` ("The Paper Instrument")** and the same surface family as `bucket_list_popup.dart` — calm, precise, warm; glass blur preserved; controls machined, not ornamental.

This document captures product decisions from the 2026-09-01 design review. Domain rules, notification feed logic, dismissal keys, sync, and provider wiring are unchanged unless noted below.

**Superseded in part by `INBOX_HIDDEN_RESTORE_HLD.md`:** header Restore all, and the Hidden row / Restore all placement in §9. Those recovery rules live in that document.

---

## 1. Product decisions (locked)

| Decision | Choice |
|----------|--------|
| **Header title** | Keep **"Inbox"** |
| **Glass blur** | **Keep** — `GlassSurface` / `BackdropFilter` on the popover panel is intentional and on-brand |
| **Daily stats logging** | **Collapsed footer** — behind a "Log stats" affordance; not visible by default |
| **Layout model** | **Pinned header + scrollable feed** — reminders input pinned at top; notification feed scrolls; hidden + stats in footer region |
| **Wrap marks** | **Keep as-is** on pinned-note rows (soft-wrap elbows) |
| **Popover chrome** | **Global** — update `ContextualPopover` / `GlassSurface` usage to align with `DESIGN.md` (18px surface radius, etc.); inbox is the driver, all contextual popovers inherit |

---

## 2. Goals

- Make the inbox feel like a Voyager instrument panel, not a stacked Material form.
- Restore typography to the theme scale — no hand-set 9–10px micro-type.
- Clarify information architecture: **triage first**, reminders second, recovery and logging tertiary.
- Align row geometry, field styling, and toolbar controls with Jobs, Todo, Rankings, and Bucket List patterns.
- Preserve existing behavior: urgency sorting, dismiss/restore, soft-delete undo, context menus, Vim in text fields, `NotificationPopoverWarmup`, Android touch targets.

### Out of scope

- Changing how the notification feed is built (`visibleNotificationFeedProvider`, urgency model, badge state).
- Moving the bell off the nav rail or changing open/close routing (`showContextualPopoverAt`).
- Full Analytics page redesign.
- Removing Vim, spellcheck squiggles, or snippet support from pinned-note fields.
- Replacing `TrackerEntryRow` internals — only its **placement** and surrounding chrome change.

---

## 3. Problem summary (current state)

| Issue | Symptom |
|-------|---------|
| **Typography** | Pinned notes at 10px, feed titles at 11px, subtitles at 9.5px — violates the Inherited Scale Rule |
| **IA** | Four unrelated jobs in one scroll: reminders, feed, stats logger, hidden browser |
| **Sectioning** | Raw `Divider(height: 1)` between every block — reads as a generic form |
| **Components** | Bespoke pinned-note `TextField` (8px radius); header actions as bare `InkResponse` icons |
| **Row geometry** | 8px row radius vs 16px `rounded.row`; inconsistent leading slots (checkbox vs padded icons) |
| **Popover chrome** | `ContextualPopover` at 12px radius vs 18px `rounded.surface` in `DESIGN.md` |
| **Scroll** | Single `VoyagerScrollView` over the entire content — expanding Hidden yanks the viewport mid-panel |

---

## 4. Layout architecture

### 4.1 Structure (pinned regions)

```
┌─────────────────────────────────────────┐  ← GlassSurface (blur preserved)
│  Inbox                    [↺] [Clear]   │  ← fixed header
│  3 items need attention                 │  ← optional status sublabel
├─────────────────────────────────────────┤
│  Reminders                              │  ← section label (labelMedium)
│  ┌───────────────────────────────────┐  │
│  │ Type a quick reminder…            │  │  ← VoyagerTextField / dense field
│  └───────────────────────────────────┘  │
│  · pinned note rows (wrap marks kept)   │  ← max ~3 visible, then internal scroll
├─────────────────────────────────────────┤
│  ┌─ scrollable feed ─────────────────┐  │
│  │ ☐ Task title          · Today  ●  │  │
│  │ ◉ Event title         · 3/15   ●  │  │  ← Flexible / Expanded
│  │ $ Bill name           · in 2d   ●  │  │
│  │                                   │  │
│  │        All caught up              │  │  ← empty state when feed empty
│  └───────────────────────────────────┘  │
├─────────────────────────────────────────┤
│  ▸ Hidden (4)                           │  ← footer: collapsed by default
│  ▸ Log stats                            │  ← footer: collapsed by default
└─────────────────────────────────────────┘
```

**Height:** Popover max height remains `75%` of viewport (`notification_inbox_popover.dart` today). Internal layout uses `Column` + `Expanded` on the feed region so the header and reminders stay pinned while the feed scrolls.

### 4.2 Region rules

| Region | Scroll | Default state |
|--------|--------|---------------|
| **Header** | Fixed | Always visible |
| **Reminders** | Internal scroll when >3 notes | Input always visible |
| **Feed** | Primary scroll (`Expanded` + `VoyagerScrollView` or `ListView`) | Dominates vertical space |
| **Hidden** | Expands inline in footer; `Scrollable.ensureVisible` on header when opening | Collapsed |
| **Log stats** | Expands inline in footer above Hidden | Collapsed |

### 4.3 Width

Unchanged: **380px** (`notification_bell.dart`).

---

## 5. Global popover chrome (`ContextualPopover`)

Apply to **all** contextual popovers, not only the inbox. Inbox redesign is the forcing function; other call sites should be regression-tested visually.

| Token / property | Current | Target |
|------------------|---------|--------|
| **Outer radius** | 12px | **18px** (`rounded.surface`) |
| **Content radius** | `contentRadius` (= outer − border) | **16px** (18 − 2 accent border) |
| **Accent border** | 2px | **1px** blended hairline by default; **2px accent** when `accentColor` is passed (inbox keeps accent border from bell) |
| **Glass weight** | `GlassWeight.light` | **`GlassWeight.heavy`** for popovers ≥320px wide; light unchanged for narrow pickers (≤280px) — threshold implemented in `ContextualPopover` |
| **Shadow** | `GlassSurface` subtle | `surfaceShadow()` at strong alpha for heavy weight |
| **Barrier** | Transparent | **Unchanged** — user wants blur on the panel, not a modal scrim |

Update `ContextualPopover.contentRadius` and any descendants that reference it (e.g. Hidden section bottom corner rounding in `notification_inbox_popover.dart`).

**Preserved:** `RepaintBoundary`, spring scale entrance, `FadeTransition`, anchor-to-trigger layout in `_ContextualPopoverRoute`.

---

## 6. Header

### 6.1 Content

| Element | Spec |
|---------|------|
| **Title** | `titleMedium`, weight 600 — **"Inbox"** |
| **Sublabel** | `labelSmall`, `onSurfaceVariant` — dynamic count, e.g. `"3 items need attention"` when feed non-empty; hidden when empty or all caught up |
| **Show hidden** | Superseded — see `INBOX_HIDDEN_RESTORE_HLD.md`. Icon-only **Show hidden** in this slot; Restore all moves into the Hidden section. |
| **Clear all** | Dense `GlassButton`, icon-only, `PhosphorIconsRegular.broom`, tooltip **"Clear all"** — visible when visible feed has items |

Replace raw `InkResponse` + `Tooltip` with the same dense glass control pattern used in the Log stats footer today.

### 6.2 Padding

`EdgeInsets.fromLTRB(16, 14, 12, 10)` — unchanged horizontal rhythm; bottom padding tightens to `8` when sublabel is absent.

---

## 7. Reminders section

### 7.1 Section chrome

- **Label:** `labelMedium`, `onSurfaceVariant` — **"Reminders"**
- **Spacing:** `16px` horizontal padding; `12px` below label before input; `8px` between rows
- **No** `Divider` above or below — whitespace + label only

### 7.2 Input field

Replace bespoke `TextField` + `InputDecoration` with **`VoyagerTextField`** (or the same dense field pattern as `bucket_list_popup.dart`):

| Property | Target |
|----------|--------|
| **Radius** | 14px (`rounded.field`) |
| **Fill** | Ivory Field / Graphite Field (`colorScheme` field tone) |
| **Border** | 1px blended outline; 1.8px accent on focus |
| **Typography** | `bodySmall` (12px) minimum; prefer `bodyMedium` if vertical space allows |
| **Hint** | `"Type a quick reminder…"` — `bodyMedium` at 55% `onSurface` |
| **Submit** | Enter (no Shift) adds note — unchanged |

Vim overlay, spellcheck squiggle layer, and snippet context menu behavior are preserved.

### 7.3 Pinned note rows

| Property | Target |
|----------|--------|
| **Text** | `bodySmall` (12px) — remove `fontSize: 10` override |
| **Wrap marks** | **Keep** `_WrapMarks` / `_WrapMarkPainter` unchanged |
| **Row hover** | 16px radius (`rounded.row`), `theme.hoverColor` fill — match feed rows |
| **Delete** | `_InboxDismissButton` + `_HoverRevealed` — unchanged interaction model |
| **Max visible** | ~3 rows before an internal `ListView` with `shrinkWrap: false` inside a `ConstrainedBox(maxHeight: …)` — prevents reminders from consuming the whole popover |

---

## 8. Notification feed

### 8.1 Section chrome

- Optional **"Notifications"** `labelMedium` header when reminders section is non-empty (omit when it would duplicate visual noise with only a feed).
- **No** divider between reminders and feed — `12px` vertical gap.

### 8.2 Row spec

Align with todo/calendar list row treatment:

| Property | Current | Target |
|----------|---------|--------|
| **Row radius** | 8px | **16px** |
| **Horizontal inset** | 8px outer + 8px inner | **16px** outer, **12px** inner (spacing scale) |
| **Title** | `bodySmall` @ 11px | **`bodySmall`** (12px) |
| **Subtitle** | `labelSmall` @ 9.5px | **`labelSmall`** (11px), `onSurfaceVariant`; `error` when overdue |
| **Leading slot** | Variable (checkbox vs `Padding(all: 10)` icon) | **Fixed 36px** leading column — checkbox and icons centered in same box |
| **Urgency dot slot** | 18px | Unchanged |
| **Dismiss slot** | `_inboxDismissSlotSize` | Unchanged (30 desktop / 48 Android) |
| **Context menu** | `ContextMenuRegion` | Unchanged |
| **Exit animation** | 160ms `SizeTransition` + `FadeTransition` | Unchanged; respect `VoyagerMotion.reduced` |

### 8.3 Empty state

When visible feed is empty:

```
        [PhosphorIconsRegular.checkCircle — 20px, onSurfaceVariant @ 50%]

              All caught up

    Pin a reminder above to keep it handy.
```

- Primary line: `bodySmall`, `onSurfaceVariant`
- Secondary hint: `labelSmall`, `onSurfaceVariant` @ 70% — only when pinned notes section is also empty

---

## 9. Footer — Hidden

Behavior largely unchanged; presentation updated.

| Element | Spec |
|---------|------|
| **Trigger row** | Full-width `InkWell`; caret + **"Hidden (N)"** in `labelSmall` / `onSurfaceVariant` |
| **Expand** | `AnimatedSize`, 220ms, `VoyagerSpring.moveCurve` (or `easeOut` when reduced) |
| **Restore all / Restore selected** | Superseded — see `INBOX_HIDDEN_RESTORE_HLD.md`. Restore all only while expanded and nothing is selected; otherwise **Restore (N)**. |
| **Rows** | Superseded — see `INBOX_HIDDEN_RESTORE_HLD.md`. Title, type glyph, and the live feed's due/amount subtitle. |
| **Position** | Below feed scroll area, above Log stats — bottom of popover content clips to new `contentRadius` |

`Scrollable.ensureVisible` on expand is preserved.

---

## 10. Footer — Log stats (collapsed)

### 10.1 Collapsed trigger

| Element | Spec |
|---------|------|
| **Label** | **"Log stats"** with `PhosphorIconsRegular.chartBar` (16px) |
| **Style** | Same row treatment as Hidden trigger |
| **Default** | Collapsed — stats UI not mounted until first expand (lazy build for warmup compatibility) |

### 10.2 Expanded content

Reuse existing `_AnalyticsSection` logic with presentation updates:

| Element | Current | Target |
|---------|---------|--------|
| **Section title row** | Icon + "Log Stats" + glass buttons | Keep; rename visible label to **"Log stats"** (sentence case) |
| **Title typography** | `labelMedium` @ 11px | **`labelMedium`** (14px) — remove `fontSize` override |
| **Date controls** | Dense `GlassButton` | Unchanged |
| **Tracker rows** | `TrackerEntryRow` | Unchanged widget; spacing per analytics page row rhythm |
| **Save** | Dense `GlassButton` | Unchanged |
| **Dirty close** | `PopScope` + `_flushAndClose` | Unchanged |

### 10.3 Ordering

Footer stack (top to bottom):

1. **Log stats** (collapsed)
2. **Hidden** (collapsed)

Rationale: triage and logging are active tasks; hidden is archival recovery — lowest priority at the bottom.

---

## 11. Typography contract

**Rule:** No hand-set `fontSize` in the inbox popover except where `VoyagerTextField` / theme already defines it.

| Role | TextTheme | Use |
|------|-----------|-----|
| Header title | `titleMedium` | "Inbox" |
| Header sublabel | `labelSmall` | Attention count |
| Section labels | `labelMedium` | Reminders, Notifications, Log stats, Hidden |
| Primary row text | `bodySmall` | Note text, feed titles, hidden titles |
| Secondary metadata | `labelSmall` | Due labels, dates, amounts |
| Empty state primary | `bodySmall` | "All caught up" |
| Empty state hint | `labelSmall` | Reminder hint |
| Field input | `bodyMedium` or `bodySmall` | Reminder input |

---

## 12. Spacing and separators

| Rule | Behavior |
|------|----------|
| **Dividers** | Remove all `Divider(height: 1)` between sections |
| **Section gap** | `12–16px` (`md`–`lg`) whitespace |
| **Hairlines** | Use `VoyagerColors.of(context).hairline` only if two sections need explicit separation at min height — prefer whitespace first |
| **Padding** | Horizontal `16px` (`lg`) on all sections; footer triggers align to same inset |

---

## 13. Motion

| Interaction | Duration | Curve |
|-------------|----------|-------|
| Row hover fill | 120ms | default |
| Row dismiss exit | 160ms | `easeInCubic`; zero when reduced |
| Hidden / Log stats expand | 220ms | `VoyagerSpring.moveCurve` / `easeOut` when reduced |
| Hover-reveal dismiss | 120ms | `AnimatedOpacity` — unchanged |
| Popover entrance | 260ms | Existing route transition — unchanged |

No new celebration motion. Checkbox complete animation stays on `VoyagerCheckbox`.

---

## 14. Files and implementation map

| File | Change |
|------|--------|
| `lib/core/widgets/contextual_popover.dart` | 18px radius, heavy glass threshold, `contentRadius` update |
| `lib/core/widgets/glass_surface.dart` | Possibly expose width-based weight helper — only if logic doesn't fit in popover |
| `lib/features/notifications/notification_inbox_popover.dart` | Layout restructure, typography, sections, footer, field swap |
| `lib/features/notifications/notification_bell.dart` | No change expected (width 380, accent pass-through) |
| `test/notification_inbox_*.dart` | Update pump/layout tests for new structure |
| `test/glass_*_test.dart` | Add or extend coverage for popover radius / weight if snapshotted |

### 14.1 Suggested widget decomposition (optional)

Extracting private sections into separate files is **optional** — only if `notification_inbox_popover.dart` grows unwieldy:

- `inbox_header.dart`
- `inbox_reminders_section.dart`
- `inbox_feed_section.dart`
- `inbox_footer_hidden.dart`
- `inbox_footer_stats.dart`

Not required for v1 if a single file stays readable with the new `Column` + `Expanded` structure.

---

## 15. Accessibility and platform

| Concern | Behavior |
|---------|----------|
| **Touch targets** | Android dismiss buttons remain 48px; desktop 30px with hover reveal |
| **Reduced motion** | All existing `VoyagerMotion.reduced` checks preserved |
| **High contrast** | `GlassSurface` near-solid path unchanged |
| **Semantics** | Header actions need `tooltip` + `Semantics(label:)` on glass buttons |
| **Focus** | Log stats expand should not steal focus from reminder input on open |

---

## 16. Testing plan

### 16.1 Widget tests (update existing)

- `notification_inbox_edit_alignment_test.dart` — pinned note edit alignment after `VoyagerTextField` swap
- `notification_inbox_edit_commit_test.dart` — commit on blur / Enter unchanged
- `notification_inbox_wrap_mark_test.dart` — wrap marks still render (unchanged painter)
- New: layout test — feed region is scrollable, header/reminders pinned at top
- New: footer — Log stats collapsed by default; expand mounts tracker rows

### 16.2 Manual QA

- [ ] Open inbox with 0 / 1 / many feed items — sublabel and empty state copy
- [ ] Pin 5+ reminders — internal scroll cap, feed still scrolls independently
- [ ] Expand Hidden — `ensureVisible` scroll behavior
- [ ] Expand Log stats — dirty integer edit + dismiss popover flushes save
- [ ] Clear all / Restore all — header glass buttons
- [ ] Light + dark theme, custom accent colors
- [ ] Android — dismiss buttons always visible
- [ ] Spot-check 3–4 other contextual popovers after global chrome change (calendar event picker, todo date picker, jobs track modal)

---

## 17. Rollout / phasing

Single PR is acceptable if tests pass. Suggested commit order if splitting:

1. **Global chrome** — `ContextualPopover` radius + glass weight (visual regression pass)
2. **Layout shell** — `Column` + `Expanded` feed, remove dividers, section labels
3. **Typography + rows** — font scale, 16px row radius, leading slot
4. **Reminders field** — `VoyagerTextField` swap
5. **Footer** — Log stats collapse + Hidden reorder
6. **Header polish** — sublabel, glass buttons

---

## 18. Success criteria

- [ ] No `fontSize:` literals below `TextTheme` roles in inbox popover (except third-party widgets)
- [ ] No `Divider` widgets between inbox sections
- [ ] Log stats not visible until user expands footer
- [ ] Feed scrolls independently with reminders pinned
- [ ] `ContextualPopover` outer radius = 18px; inbox keeps glass blur
- [ ] All existing notification inbox widget tests green
- [ ] Visual parity with `DESIGN.md` Menus & Popovers section

---

## 19. References

- `DESIGN.md` — Paper Instrument, typography, shapes, menus & popovers
- `lib/features/life_tracker/bucket_list_popup.dart` — reference popover content density
- `lib/core/widgets/contextual_popover.dart` — popover shell
- `lib/core/widgets/glass_surface.dart` — blur material
- `TODO_EDIT_PANEL_UI.md` — HLD format reference
