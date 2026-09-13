# Scheduled Reminders & Sticky Toasts — HLD

Account-synced **scheduled reminder rules** with dual delivery: **OS notifications** at the exact fire time (best-effort per platform) and **sticky in-app toasts** that stay until acknowledge or snooze. Managed inside the **global Inbox** popover as a new section beside existing quick-note Reminders. Entity bells on **calendar events** and **todos** use the same delivery rails with a lighter sticky chrome and a configurable lead-time offset.

Related: `lib/domain/models/notification_models.dart` (`PinnedNote`, `NotificationFeedItem`), `lib/features/notifications/notification_inbox_popover.dart`, `lib/features/notifications/notification_bell.dart`, `lib/core/widgets/voyager_toast.dart`, `lib/domain/models/todo_models.dart`, `lib/domain/models/calendar_models.dart`, `INBOX_POPOVER_HLD.md` (§7 Reminders = quick notes only), sync / soft-delete conventions.

Status: **design** (not implemented).

---

## 1. Goals

- Let the user define **recurring and one-shot reminders** that fire at an exact local time on chosen devices.
- Deliver each due reminder as an **OS notification** (when the platform allows) **and** a **sticky in-app toast** that does not auto-dismiss.
- Keep **quick-note Reminders** (`PinnedNote`) unchanged as their own Inbox section; add a **separate Scheduled** section for rules.
- Sync **ack / snooze / rule edits** across devices; still fire **per-device OS alerts** on every targeted device.
- Support **calendar / todo reminder bells** with a single lead-time offset (presets + custom).
- Persist a **history of firings and acks/snoozes** for debugging.

## 2. Non-goals (v1)

- Boot / “first power-on” triggers (dropped; use scheduled OS notification + first app open).
- Quiet hours / DND, priority tiers, streaks, templates, sounds-per-rule, calendar import, shared/household reminders, location triggers.
- Multiple lead-time offsets on one event/todo.
- Perfect OS-notification parity across Android / iOS / desktop / web — **best effort** is acceptable.
- Replacing the existing urgency **notification feed** (tasks/events/bills triage) — it stays; scheduled sticky delivery is additive.
- Changing `PinnedNote` quick-capture behavior.

---

## 3. Product decisions (locked)

| Decision | Choice |
|----------|--------|
| **Delivery model** | OS notification at exact fire time **+** sticky in-app until ack/snooze |
| **Expiry** | Never auto-expire; stays due until ack (or replaced — see coalescing) |
| **Missed / late open** | Still show; carry until resolved |
| **Schedule time** | Every rule always has a **time** (and date for one-shots) |
| **Timezone** | **Device-local** wall clock; travel follows the device |
| **Cross-device ack** | Ack on any device clears sticky + cancels pending OS alerts for that occurrence on **all** targeted devices |
| **Cross-device snooze** | Same as ack: clear sticky everywhere, reschedule OS alerts everywhere to the snooze target |
| **OS alerts** | Each targeted device still schedules **its own** OS notification |
| **Devices** | Auto-register on login; user-rename; remove/adjust in Settings; default target = **all devices** |
| **Multi-due UI** | **Stack** all due stickies at once (different rules) |
| **Snooze actions** | Fixed: **Remind me in 10 min**, **Remind me tomorrow** |
| **Recurrence immutability** | Snooze **never** permanently changes the rule’s schedule times |
| **“Remind me tomorrow” target** | Next calendar day at the **same clock time as the snooze action** (e.g. Mon 3:00 PM → Tue 3:00 PM) |
| **Natural occurrence wins** | When the next **natural** occurrence becomes due, it **replaces** any pending snooze from an older occurrence (OS rescheduled everywhere) |
| **Same-rule carry-over** | One active delivery state per rule — new natural due **coalesces** over the prior unacked/snoozed state (not two stacked copies of the same rule) |
| **10-min snooze** | Same replace rule as tomorrow |
| **Sticky blocking** | Only the toast’s own hit area; small sliver, not a full-screen modal |
| **OS notification tap** | Opens app focused on that sticky toast |
| **Background** | Best effort per platform |
| **Management UI** | New **Scheduled** section inside global Inbox (not a standalone page) |
| **Quick notes** | Keep existing Reminders / `PinnedNote` section separate |
| **Entity bells** | Calendar + todo; lighter sticky; deep-link; one lead-time offset; presets including custom |
| **Date-only base time** | Todos with date only (and full-day events for bell purposes): **09:00 device-local** on that date, then apply offset |
| **Debug** | History of firings + ack/snooze events |

### 3.1 Snooze vs schedule (worked example)

Daily rule at **1:00 PM**.

1. Monday 1:00 PM — occurrence due; OS fires; sticky shows.
2. Monday 3:00 PM — user taps **Remind me tomorrow** → delivery target becomes **Tuesday 3:00 PM**; stickies clear; OS alerts rescheduled to Tue 3:00 on all targeted devices.
3. Tuesday 1:00 PM — **natural** next occurrence becomes due → **cancels** the Tue 3:00 snooze; new delivery at Tue 1:00; OS alerts move to Tue 1:00; sticky shows for the natural occurrence.
4. Wednesday 1:00 PM onward — normal daily schedule. No permanent 3:00 PM shift.

Weekly / one-shot use the same replace rule: snooze only moves **current delivery**; natural due replaces it.

### 3.2 Coalescing (same rule)

If Monday’s sticky is still unacked when Tuesday’s natural fire hits, the rule keeps **one** sticky / one pending OS set representing the latest coalesced occurrence — not two vitamin toasts stacked.

Different rules stack freely.

---

## 4. Domain model

### 4.1 `DeviceRegistration`

Synced soft-deletable row so rules can target devices by id.

| Field | Role |
|-------|------|
| `id` | Stable device id (generated once per install / login binding) |
| `displayName` | User-editable label (default from platform: “Pixel 8”, “Juno’s MacBook”, etc.) |
| `platform` | `android` / `ios` / `windows` / `macos` / `linux` / `web` |
| `lastSeenAt` | Updated on app foreground / successful sync |
| `createdAt` / `updatedAt` / `version` / `deletedAt` | Standard conventions |

**Lifecycle**

- On authenticated session start: upsert this device’s registration.
- Settings → Devices: rename, remove (soft-delete). Removed id is ignored by targeting; local scheduler cancels OS jobs for removed self when applicable.
- Reinstall / wipe → new login creates a **new** registration; user removes the stale row in Settings.

### 4.2 `ScheduledReminderRule`

User-authored reminder (Inbox Scheduled section).

| Field | Role |
|-------|------|
| `id` | UUID |
| `title` | Toast / OS title |
| `body` | Optional subtitle |
| `enabled` | Master switch |
| `scheduleKind` | `daily` \| `weekly` \| `once` |
| `localTimeMinutes` | Minutes from local midnight (0–1439) — required for all kinds |
| `weeklyWeekdays` | For `weekly`: set of weekdays (Mon=1 … Sun=7 or app’s existing enum) |
| `onceLocalDate` | For `once`: calendar date (device-local interpretation at fire) |
| `targetDeviceIds` | Empty / null = **all** registered non-deleted devices; else explicit allow-list |
| `createdAt` / `updatedAt` / `version` / `deletedAt` | Standard |

**Fire instant (device-local)**

- `daily`: next (or current) local calendar day at `localTimeMinutes`, subject to delivery state.
- `weekly`: next matching weekday at `localTimeMinutes`.
- `once`: `onceLocalDate` + `localTimeMinutes`; after terminal ack, rule stays completed (disable or leave as historical — see §4.4).

Evaluation always uses **the device’s current local timezone**.

### 4.3 `ReminderDeliveryState`

Exactly **one** mutable delivery row per logical source (rule or entity bell occurrence key). Synced so ack/snooze is global.

| Field | Role |
|-------|------|
| `id` | Stable id (`rule:{ruleId}` or `entity:{type}:{entityId}[@occurrence]` ) |
| `sourceKind` | `scheduledRule` \| `todo` \| `calendarEvent` |
| `sourceId` | Rule or entity id |
| `occurrenceKey` | Opaque key for which logical occurrence this state is for (date stamp for recurring) |
| `status` | `pending` \| `due` \| `snoozed` \| `acked` |
| `scheduledFireAtUtc` | When OS / evaluator should next fire (stored UTC; derived from local wall intent) |
| `snoozeUntilUtc` | Set when snoozed; mirrors `scheduledFireAtUtc` while snoozed |
| `dueSinceUtc` | When it first became `due` (for carry-over / history) |
| `ackedAtUtc` | Set on ack |
| `updatedAt` / `version` | Conflict resolution |

**Transitions**

| Event | Effect |
|-------|--------|
| Natural fire time reached | `due` (or coalesce: bump `occurrenceKey`, clear snooze, set new `scheduledFireAtUtc` / `dueSinceUtc`) |
| Ack | `acked`; clear OS jobs for this id on all devices; for `daily`/`weekly`, arm next natural occurrence as `pending` |
| Snooze 10 min | `snoozed`; `scheduledFireAtUtc = now+10m`; clear stickies; reschedule OS everywhere |
| Snooze tomorrow | `snoozed`; target = **local tomorrow at current local clock**; same reschedule |
| Natural occurrence supersede | Replace snooze/due from older `occurrenceKey`; new natural due wins |

### 4.4 Completed one-shots

After ack on `once`, mark delivery `acked` and set rule `enabled = false` (or `completedAt`). It remains listed in Inbox Scheduled as completed/disabled until the user deletes it. No further OS jobs.

### 4.5 Entity reminder fields

Extend todo / calendar models (or a tiny side table keyed by entity id — prefer **fields on the entity** if sync/mapper cost is acceptable):

| Field | Role |
|-------|------|
| `reminderEnabled` | Bell on/off |
| `reminderOffset` | Duration before base fire time; presets + custom; one offset only |

**Base fire time**

| Source | Base |
|--------|------|
| Todo with time-bearing `dueDate` | That local date-time |
| Todo date-only | That local date at **09:00** |
| Calendar timed event | `event.start` local |
| Calendar full-day | Event’s local start **date** at **09:00** |

**Effective fire** = base − `reminderOffset`.

Entity sticky: ack/snooze only (no “edit rule” chrome); title from entity; tap deep-links to todo panel / calendar event. Delivery state id uses entity + occurrence key for recurring events/todos.

### 4.6 `ReminderDeliveryLog` (debug history)

Append-only (or soft-capped) synced or local-first log — **synced preferred** so debugging multi-device is possible.

| Field | Role |
|-------|------|
| `id` | UUID |
| `deliveryStateId` | Link |
| `sourceKind` / `sourceId` / `occurrenceKey` | Denormalized |
| `eventType` | `osScheduled` \| `osFired` \| `stickyShown` \| `acked` \| `snoozed10m` \| `snoozedTomorrow` \| `supersededByNatural` \| `cancelled` |
| `deviceId` | Which device recorded the event |
| `atUtc` | Timestamp |
| `detail` | Optional short string (platform, error, target time) |

UI: accessible from Scheduled rule detail and/or a small “History” affordance under Settings → Devices / debug — v1 minimum is **per-rule history** in the Inbox editor sheet.

---

## 5. Scheduling & delivery engine

### 5.1 Responsibilities

Per device, a `ReminderScheduler` (foreground + platform background hooks as available):

1. Load enabled rules targeting this device + enabled entity bells.
2. Compute next fire times in **device local** time; persist UTC on `ReminderDeliveryState`.
3. Register **OS scheduled notifications** best-effort.
4. On app start / resume / tick: promote due items, show sticky stack, reconcile OS jobs with synced state.
5. On sync pull of delivery state: cancel / reschedule local OS jobs to match (ack on phone clears laptop OS notif when laptop syncs).

### 5.2 OS notification

- Channel/category: “Reminders” (platform-appropriate).
- Payload includes `deliveryStateId` so tap → open app → focus that sticky.
- If scheduling unsupported (some web/desktop cases): skip OS; sticky-on-open still works.
- Permission denied: sticky-only; optional one-time inbox hint (no nag loop).

### 5.3 Sticky toast UX

- Build on `VoyagerToast` with **`dwell: null`** (already supported) and actions: **Acknowledge**, **Remind me in 10 min**, **Remind me tomorrow**.
- Extend toast host to **stack multiple** sticky entries (today’s toast API is largely single-card — scheduled stickies need a multi-entry overlay region, typically top or bottom safe area, each a small sliver).
- Only the toast surface intercepts pointers; rest of the app remains usable.
- Entity stickies: same actions; visual distinction (calendar/todo icon); primary tap / title → deep link.

### 5.4 Inbox vs overlay

| Surface | Role |
|---------|------|
| Overlay sticky stack | Immediate attention while using the app |
| Inbox **Scheduled** section | Create/edit/enable rules; see due/snoozed; open history |
| Inbox **Reminders** | Unchanged `PinnedNote` quick notes |
| Inbox feed | Existing task/event/bill urgency triage — unchanged |

Due scheduled items may show a compact row in Scheduled (status chip) in addition to overlay stickies.

---

## 6. Inbox UI

### 6.1 Section order (top → bottom)

1. Header (Inbox)
2. **Reminders** — quick notes (`PinnedNote`) — unchanged purpose
3. **Scheduled** — new section for `ScheduledReminderRule`
4. Notification feed
5. Footer (Hidden / Log stats) per existing HLDs

### 6.2 Scheduled section

- Section label **Scheduled**
- Primary affordance: **Add** / inline composer opening a compact editor sheet:
  - Title (required)
  - Body (optional)
  - Kind: Daily / Weekly / Once
  - Time picker (required)
  - Date (once) / weekdays (weekly)
  - Device multi-select (default all)
  - Enable toggle
- Rows: title, cadence summary (“Daily · 8:00 AM”), status (Due / Snoozed until … / Next …), overflow → edit / disable / delete / history
- Creating from Inbox does not require a separate page

Align chrome with `INBOX_POPOVER_HLD.md` (typography, field radius, row radius). Cap visible rows (~3–4) then internal scroll so Scheduled cannot eat the feed.

### 6.3 Entity bell UI

- Todo edit panel + calendar event panel: **bell** control.
- Off by default.
- When on: show lead-time control — presets e.g. **At time**, **15 minutes before**, **1 hour before**, **1 day before**, **Custom…** (duration picker). Exactly one offset.
- Enabling arms `ReminderDeliveryState` for the next relevant occurrence.

---

## 7. Settings — Devices

New Settings subsection:

- List `DeviceRegistration` rows: name, platform, last seen, **This device** badge
- Rename, remove
- Copy explaining: reminders default to all devices; per-rule overrides live in the Scheduled editor
- OS notification permission status + deep link to system settings when denied

---

## 8. Sync & storage

| Collection / table | Sync | Notes |
|--------------------|------|-------|
| `device_registrations` | Yes | Soft-delete |
| `scheduled_reminder_rules` | Yes | Soft-delete |
| `reminder_delivery_states` | Yes | Hot path for ack/snooze LWW / version |
| `reminder_delivery_logs` | Yes (preferred) or local | Cap retention later if needed |
| Entity reminder fields | With todos / events | Mapper + backup collections |

Follow existing Drift + Firestore mapper + `backup_collections.dart` patterns. Soft-delete tombstones for cross-device removal of rules and devices.

**Conflict rule:** delivery state is last-writer-wins on `version`/`updatedAt`. Ack beats older snooze if both land; scheduler is idempotent on apply.

---

## 9. Platform notes (best effort)

| Platform | Expectation |
|----------|-------------|
| Android | Local scheduled notifications; reliable enough for v1 |
| iOS | Permission + OS budgeting; may defer — sticky catch-up on open |
| Windows / macOS / Linux | Use available local-notification plugins; degrade gracefully |
| Web | Often no true scheduled OS notifs while closed — sticky on next open |

No boot receivers. No “first unlock” special path.

---

## 10. Files and implementation map (expected)

| Area | Likely touchpoints |
|------|--------------------|
| Domain | `lib/domain/models/reminder_models.dart` (new), extend todo/calendar models, repositories |
| DB | `lib/data/database/app_database.dart` (+ generated), migrations |
| Sync | `firestore_document_mapper.dart`, `remote_sync_service.dart`, `backup_collections.dart` |
| Scheduler | `lib/core/reminders/` (scheduler, OS bridge, sticky host) |
| Inbox | `notification_inbox_popover.dart`, providers beside `pinnedNotesProvider` |
| Toast | Extend `voyager_toast.dart` or sibling `sticky_reminder_toast.dart` for stacking |
| Settings | `settings_page.dart` devices section |
| Entity UI | `todo_edit_panel.dart`, `calendar_event_panel.dart` |
| Tests | Schedule math, snooze supersede, coalesce, multi-device state apply, offset presets, date-only 9 AM |

---

## 11. Testing plan

- **Schedule math:** daily / weekly / once across DST and TZ changes (device-local).
- **Snooze tomorrow:** Mon 3 PM → Tue 3 PM target; Tue 1 PM natural supersede cancels snooze.
- **Snooze 10 min:** superseded if natural due lands first.
- **Coalesce:** unacked day N + day N+1 natural → single due state.
- **Ack sync:** state acked on A → B cancels OS + dismisses sticky after sync.
- **Device targeting:** rule excluding tablet never schedules there; “all devices” includes newly registered devices.
- **Entity offset:** 1h before timed event; date-only todo → 9:00 − offset.
- **Once:** ack disables further fires.
- **Permission denied:** sticky still works; OS schedule no-ops cleanly.
- **Inbox IA:** quick notes and Scheduled both present; feed unchanged.

---

## 12. Rollout / phasing

| Phase | Scope |
|-------|-------|
| **P0** | Domain + Drift + sync for rules, delivery state, devices; Inbox Scheduled CRUD; sticky stack + ack/snooze; local evaluator on resume |
| **P1** | OS notifications (Android first, then iOS/desktop best effort); notification tap → sticky focus |
| **P2** | Todo/calendar bells + lead-time presets/custom; deep links |
| **P3** | Delivery history UI; Settings devices polish; web degradation pass |

---

## 13. Success criteria

- User can create daily / weekly / one-shot reminders with a time and device targets from the Inbox.
- At fire time, targeted devices attempt OS notification; opening the app always surfaces sticky toast(s) until ack/snooze.
- Ack or snooze on one device clears stickies and rewrites OS schedules on the others after sync.
- “Remind me tomorrow” does not permanently alter recurrence; natural fire supersedes pending snooze.
- Same rule never stacks duplicate stickies across days; different rules stack.
- Quick-note Reminders remain intact.
- Todo/event bell with a single offset fires on the dual-delivery path with lighter sticky chrome.
- History shows fire / ack / snooze / supersede events for debugging.

---

## 14. References

- `INBOX_POPOVER_HLD.md` — Inbox chrome; §7 remains quick notes only
- `lib/core/widgets/voyager_toast.dart` — `dwell: null` + actions
- `lib/domain/models/notification_models.dart` — `PinnedNote`, feed items
- Design review decisions captured in chat (2026-09-13)
