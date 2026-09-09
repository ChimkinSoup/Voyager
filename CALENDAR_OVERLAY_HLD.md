# Calendar overlay — High-Level Design

Show another calendar’s events inside the calendar you are viewing, without copying those events or changing which calendar the page is scoped to.

Example: Default overlays Holidays. Viewing Default still files new events on Default, and Holidays appear on that grid in their own color. Viewing Holidays shows only Holidays. **All calendars** is unchanged.

North star: a display union, not a second store of events.

---

## 1. Goals

- While a specific calendar is open, also render events from calendars that host has chosen to show.
- Keep event ownership on the source calendar. Overlay never copies, moves, or recolors events.
- Keep the scope switcher as “which calendar am I working in,” not a visibility checklist.
- Persist the overlay list on the host calendar and sync it with the rest of calendar data.
- Drop overlay links when the target calendar is deleted.

### Out of scope

- A holiday, ICS, or other calendar importer. Create a Holidays calendar by hand; overlay it.
- A read-only / reference flag on a calendar.
- Google-style “check every calendar that is visible,” independent of the open calendar. **All calendars** already covers “show everything.”
- Recursive overlay (`A` shows `B`, so `A` also shows whatever `B` shows).
- Overlay onto **All calendars** (that view already unions every live calendar).
- Reordering calendars, dragging an event onto another calendar, or a per-event “also show on.”
- Changing todo / workout / tracker markers. Those stay separate toggles.

---

## 2. Product decisions (locked)

| Decision | Choice |
|----------|--------|
| **What overlay means** | Host calendar stores ids of other calendars whose events are painted while that host is open |
| **Direction** | One-way, host-centric. Default can show Holidays without Holidays showing Default |
| **Depth** | Flat. Never follow an overlay’s own overlay list. A calendar cannot overlay itself |
| **Cycles** | Allowed as data (`A` shows `B` and `B` shows `A`). Viewing `A` shows `A` + `B` only |
| **All calendars** | Ignores overlay lists. Still the full union |
| **New events** | Filed on the open host (`_selectedCalendarId`), never on an overlay, unless the user picks another calendar in the event panel |
| **Open / edit overlay event** | Same popup as today. Stays on the host view. Event panel calendar field still shows and can change the owning calendar |
| **Move via panel** | Existing calendar picker may reassign ownership. If the new owner is neither the host nor one of its overlays, the event leaves this view. Do not auto-add that calendar as an overlay |
| **Appearance** | Overlay events look like normal events: same size, packing, and tap target. Paint `event.colorValue`. Do not dim, badge, or force the source calendar color |
| **Where you configure it** | **Manage calendars** only, row action **Also show**. Not the scope switcher, and not a control on the calendar page |
| **Switcher** | Unchanged. Still one calendar, or All. Closed title stays the host name |
| **Counts** | Manage subtitle stays owned-event count. Do not count overlay events as belonging to the host |
| **Persistence** | `overlayCalendarIds` on `Calendar`. Empty list is the default. Missing field on old rows / old backups = `[]` |
| **Sync** | Synced with the calendar, across devices. Version-wins like name and color. Not a local-only view preference |
| **Reveal / “Show in Calendar”** | If the open host already overlays the event’s calendar, stay on that host. Otherwise keep today’s fallback: switch to All so the event is visible |
| **Delete target** | Soft-delete still deletes or moves that calendar’s events as today. Also strip that id from every remaining calendar’s overlay list |
| **Unknown / deleted ids** | Ignored at read time. Never crash the grid |

Sync, Manage-only configuration, and normal-event appearance are confirmed. No open product questions remain.

---

## 3. Problem

Calendars are exclusive scopes. `calendarEventsProvider(id)` returns that calendar’s events; `null` returns every calendar. The switcher’s **All calendars** row is the only way to see two calendars at once, and it replaces the working calendar: the title becomes “All calendars,” and a new event is filed on the last specific calendar rather than on a named host.

That is the wrong tool for a reference calendar. Holidays should be visible on Default without mixing Work into the same view, and without copying holiday rows onto Default.

`Calendar` today is `id`, `name`, `colorValue`, plus soft-delete fields. Events already carry a single `calendarId`. Ownership does not need to change.

---

## 4. Behavior

### 4.1 Viewing

| Open scope | Events on the grid |
|------------|--------------------|
| Specific calendar `H` | Events with `calendarId == H`, plus events whose `calendarId` is in `H.overlayCalendarIds`, skipping ids that are `H`, unknown, or soft-deleted |
| All calendars (`null`) | Every live calendar’s events, as today. Overlay lists are not consulted |

Month, week, day, year morph, and overflow popovers all consume that one visible list. Recurrence expansion is unchanged; overlay series are normalized with host series.

Two events on the same day both render, even if titles match. No deduping across calendars.

### 4.2 Creating and editing

- Empty-day create uses the host as `initialCalendarId` (All still uses the last specific calendar).
- Opening an overlay event does not change `_selectedCalendarId`.
- Saving an overlay event writes the source row. It does not clone onto the host.
- Deleting an overlay event deletes the source event (including the existing recurrence choices). It disappears from every host that overlaid that calendar.

### 4.3 Configure

**Manage calendars** → row menu → **Also show**.

- Dialog title: `Show on "{host name}"`.
- Checkbox list of every other live calendar: color dot + name. Checked means that calendar is in this host’s overlay list.
- Save writes the host calendar (bump version) and closes.
- If the user has only the default calendar, the action can still open; the list is empty and the dialog says there are no other calendars to show.
- The default calendar may overlay others. Any calendar may overlay the default. Nobody may overlay themselves.

Unchecking removes the link only. Events stay on the source calendar.

### 4.4 Delete, move, restore

Deleting calendar `T`:

1. Existing choice stands: delete `T`’s events, or move them to the default calendar.
2. Soft-delete `T`.
3. For every other calendar whose `overlayCalendarIds` contains `T`, remove `T` and save that calendar (so the cleanup syncs).
4. If events were moved to Default, they are Default’s events after that. They do not remain “Holidays events” painted via a dead link.

Restoring a calendar does not restore overlay links that were stripped. Re-check **Also show** if you want them back.

### 4.5 Reveal

`_revealCalendarEvent` today jumps to All when the event’s calendar is not the open one. After this change:

- Open host overlays that `calendarId` → stay, snap to the event’s month, open the sidebar.
- Otherwise → All, as today. Do not switch the page onto the source calendar; that would hide the host the user was working in.

---

## 5. Data

### 5.1 Model

`Calendar` gains:

```text
overlayCalendarIds: List<String>  // default []
```

`copyWith` replaces the list when passed. Ids are stored in a stable order (the order shown in the Also-show dialog, which is calendar list order). Duplicates and the host’s own id are stripped on write.

### 5.2 Table

`CalendarsTable.overlayCalendarIds`: text, default `'[]'`. JSON array of id strings, same idea as other JSON text columns. Domain encode/decode lives next to the calendar mapper, not in the widget.

Migration: add the column with default `[]`. No backfill. Existing databases keep current exclusive-scope behavior until the user checks something.

### 5.3 Sync and backup

`calendarToFirestore` / `mergeCalendarFromRemote` include `overlayCalendarIds` as a string array.

- Absent on an old remote document → `[]` (do not fail the merge).
- Remote version-wins still applies to the whole calendar. Two devices editing the same host’s overlay list: last version wins, same as renaming it in two places. No set-merge.
- Export / import use the same mapper. After calendars are imported, drop ids that do not refer to an imported live calendar. Prefer doing that when the host is written during import so a backup does not round-trip dangling ids.
- `calendarEventsProvider(id)` stays “events owned by this calendar.” Manage counts, delete, and backup keep using it. Do not make overlay a hidden side effect of that provider.

### 5.4 View query

New page-facing provider, family on the open scope (`String?`):

- `null` → delegate to `calendarEventsProvider(null)`.
- host id → watch that calendar, read its overlay ids, watch `calendarEventsProvider` for the host and each live overlay id, concatenate.

The calendar page (month, week, day, morph) watches this provider instead of `calendarEventsProvider(_selectedCalendarId)`. Listeners that invalidate `calendarEventsProvider` still refresh the view, because the view provider watches those families.

Skip overlay ids that are missing from `calendarsProvider`. Do not query a deleted calendar “just in case.”

---

## 6. UI notes

- Scope switcher and header accent stay tied to the host. Overlay does not recolor the page.
- Overlay events are not badged, dimmed, or given a smaller hit target. They use the same event chrome as host events. Source color plus the event panel’s calendar field is enough to tell them apart.
- **Also show** is a manage-row action beside rename / color / delete. There is no page-level toggle.
- When the overlay list is non-empty, the manage row’s subtitle adds a muted second line, e.g. `Also shows Holidays`, truncated if there are several. The dialog remains the editor.

---

## 7. Edge cases

| Case | Behavior |
|------|----------|
| Overlay self | Strip on write; ignore on read |
| Overlay id repeated | Strip on write |
| Target soft-deleted but id still present | Ignore until delete-cleanup removes it |
| Target missing (import, partial sync) | Ignore |
| Host soft-deleted | Irrelevant; it is not openable |
| All-view open | Overlay lists unused |
| Only one calendar | Also-show dialog is empty |
| Same title, same day, two calendars | Both shown |
| All-day holiday + timed host event | Existing all-day vs timed layout |
| Recurring overlay event, “this event only” | Edits the source series / override, as today |
| User is viewing Default, overlays Holidays, then switches to Holidays | Holidays view is Holidays-only, unless Holidays overlays something else |
| Create on a day that only has overlay events | New event still belongs to the host |
| Overlay list edited on another device | Next calendar sync updates the grid. No local cache of the list outside `Calendar` |
| Conflict on overlay list | Last calendar version wins |
| Notifications / search | Unchanged. They address the owning event. Only the calendar-page reveal rule in §4.5 changes |

---

## 8. Test plan

- View host with an overlay: both calendars’ events appear; viewing the overlay calendar does not pull the host’s events back.
- Overlay list does not recurse and does not include self.
- All calendars ignores overlay lists and matches today’s union.
- New event from the host view is stored on the host.
- Edit and delete of an overlay event change the source event only.
- Soft-delete of the target removes it from other calendars’ overlay lists; moved events show up as default-calendar events, not via the old link.
- Reveal stays on the host when that host overlays the event’s calendar; otherwise still jumps to All.
- Mapper: missing `overlayCalendarIds` reads as `[]`; round-trip preserves the list.
- Import drops unknown overlay ids.
