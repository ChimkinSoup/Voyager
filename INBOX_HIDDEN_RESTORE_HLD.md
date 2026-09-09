# Inbox Hidden Restore — HLD

Selective recovery for dismissed inbox feed items. Moves **Restore all** out of the header, makes **Hidden** the place you pick items back, and gives a dismiss an Undo toast so the common miss does not require the list at all.

Related: `INBOX_POPOVER_HLD.md` (popover layout; header Restore all and Hidden row spec in §§6.1 and 9 are superseded here), `SOFT_DELETE_TOAST.md` (undo dwell and one-offer rule; dismiss is not a delete), `lib/features/notifications/notification_inbox_popover.dart`.

This does not change how the feed is built, what a dismissal key means, or pinned-note delete.

---

## 1. Product decisions (locked)

| Decision | Choice |
|----------|--------|
| **Header recovery** | **Show hidden** — icon-only, same slot as today's Restore all. Expands Hidden and scrolls it into view. Does not restore anything. Visible only when the hidden feed is non-empty. |
| **Restore all** | Leaves the header. Lives on the Hidden trigger, and only while Hidden is **expanded** and **nothing is selected**. |
| **Restore selected** | Unchanged: **Restore (N)** on the Hidden trigger while the section is expanded and the selection is non-empty. While that button is showing, **Restore all is not**. |
| **Single dismiss** | Undo toast, 8 seconds (`kSoftDeleteUndoDwell`). Copy is **Hidden**, never Deleted. |
| **Clear all** | Same Undo toast, one offer for the whole batch. No confirm dialog. |
| **Dismiss streak** | While a dismiss-undo toast is standing, further dismisses (including Clear all) join it. The toast rewrites to **Hidden N items**. Undo brings the whole streak back. |
| **Hidden row** | Title plus the live feed's type glyph and due/amount subtitle. No urgency dot. |
| **Pinned notes** | Unchanged. Delete still uses the existing Deleted toast. Restore all does not bring notes back. |

---

## 2. Goals

- Recover one dismissed feed item without putting every other hidden item back in the feed.
- Make that path obvious from the header, without a third action next to Clear.
- Catch the accidental single dismiss (and an accidental Clear all) before the user has to open Hidden.
- Give Hidden enough metadata to tell two similarly titled items apart.

### Out of scope

- Pinned-note recovery after the delete toast expires.
- Changing dismissal keys, urgency escalation, or which items the feed includes.
- A sequential restore/skip reviewer.
- Confirm dialogs on Clear all or Restore all.
- Toasts when restoring (from Hidden or from Undo). Restore is the action the user just took.
- Completing a task, or deleting a task / event / bill from an inbox card. Those stay on their current paths (complete is silent; delete keeps the Deleted toast).

---

## 3. Header

| Element | Spec |
|---------|------|
| **Show hidden** | Dense `GlassButton`, icon-only. Tooltip and semantics label **"Show hidden"**. Visible when `hiddenNotificationFeedProvider` is non-empty. Same slot and spacing as today's Restore all. |
| **Icon** | An eye (reveal), not the counter-clockwise restore arrow. The arrow meant "put them all back"; this control only opens the list. |
| **Press** | Expand Hidden if it is collapsed, then `Scrollable.ensureVisible` on the Hidden header — the same scroll the footer already uses when it opens. If Hidden is already expanded, scroll it into view and leave it open. This control does not toggle closed. The footer caret still toggles. |
| **Focus** | Does not move focus off the reminder field. |
| **Clear all** | Unchanged in the header: broom, tooltip **"Clear all"**, visible when the visible feed is non-empty. After it runs, the Undo toast below is the safety net. |

No Restore all in the header. No sublabel change.

---

## 4. Hidden

Behavior of the drawer is otherwise unchanged: collapsed by default, **"Hidden (N)"**, caret, `AnimatedSize` 220ms, bottom of the popover under Log stats.

### 4.1 Trigger actions

| State | Trailing control |
|-------|------------------|
| Collapsed | None. Restore is not available until the list is on screen. |
| Expanded, selection empty | **"Restore all"** — dense labeled `GlassButton`. Undismisses every currently hidden item. |
| Expanded, selection non-empty | **"Restore (N)"** only. Restore all is hidden so a mis-tap cannot dump the rest of the list back. |

Both sit outside the caret's hit target, as the trailing control does today.

Restore all and Restore (N) do not raise a toast. If a dismiss-undo toast is still up, any key those buttons already undismissed is simply skipped when Undo later runs (see §6).

### 4.2 Rows

Each hidden row is a scan target, not a second live feed.

| Slot | Spec |
|------|------|
| **Selection** | Existing checkbox. Tap anywhere on the row still toggles selection. |
| **Type** | The same glyph the live feed uses for that type, at the same size: task check, event calendar, bill dollar. Color follows the source item, as the feed does. Static — a hidden task cannot be completed from this row. |
| **Title** | `bodySmall`, one line, ellipsis. Empty title stays **"(untitled)"**. |
| **Subtitle** | The live feed's subtitle, `labelSmall`: task due label; event date · time; bill amount · due label. Overdue uses `error` and medium weight, same rule as the feed. |
| **Urgency dot** | Omitted. Hidden is archival; a dot would read as "still needs attention." |
| **Dismiss** | None. |

Do not add a separate type word ("Task", "Event") if the glyph is present. The subtitle is the disambiguator.

---

## 5. Undo toast

A feed-row dismiss (the corner ✕) and Clear all both hide items. Neither deletes the underlying task, event, or bill. The toast must not say Deleted, and must not use the trash icon.

| Case | Message | Icon |
|------|---------|------|
| One item, titled | `Hidden "<title>"` | eye-slash |
| One item, untitled | `Hidden task` / `Hidden event` / `Hidden bill` | eye-slash |
| Two or more in the standing streak | `Hidden N items` | eye-slash |

Title quoting and the 48-character cap follow `deletedMessage` / `_capName`. Dwell is `kSoftDeleteUndoDwell` (8 seconds), including hover-hold and linger, same as other undos. Action label is **Undo**.

### 5.1 When it fires

- After the row's exit animation, once `dismiss` has succeeded. A dismiss that throws offers no Undo.
- Clear all: one toast after the batch dismiss has succeeded, counted by how many items were actually dismissed. If the visible feed was empty, Clear all already does nothing and shows nothing.
- Not fired for pinned-note delete, task complete, or delete-from-card.

### 5.2 Lifetime

Resolve the root overlay and a `ProviderContainer` before the row unmounts, the same way pinned-note delete does. Undo must work after the popover has closed.

The toast closes over the streak of dismissal keys, not a `WidgetRef`.

---

## 6. Streak and one offer

One undo offer on screen at a time, same constraint as `showSoftDeleteUndoToast`: toasts occupy the same slot, so a second card must not draw over the first.

| Standing offer | Next action | Result |
|----------------|---------|--------|
| None | Dismiss one, or Clear all | New dismiss-undo toast. |
| Dismiss streak | Another dismiss, or Clear all | Append keys not already in the streak. `update` the message. Dwell restarts. Undo undismisses the whole streak. |
| Dismiss streak | A delete undo (pinned note, or delete-from-card) | Delete toast takes the slot. The streak stays hidden. Its Undo is gone. |
| Delete undo | A dismiss | Delete stays deleted. Dismiss toast replaces it. A new streak starts. |

Clear all is not a second kind of offer. It is a dismiss of many keys, and it joins a standing dismiss streak if one exists.

Undo undismisses each key in the streak that is still dismissed. Keys already restored from Hidden, or already gone, are skipped. If every key is already back, Undo does nothing visible. Undo never re-hides an item.

A dismissed key stays dismissed when the toast expires or is replaced. Hidden is the later recovery path.

If an item leaves the feed for another reason (completed elsewhere, deleted, outside the window) it drops out of Hidden with it — existing provider behavior. Undo still undismisses the key, so a later re-entry is not stuck hidden.

---

## 7. Edge cases

| Case | Behavior |
|------|----------|
| Dismiss the last visible item | Feed empty state shows. Toast still offers Undo. Hidden count includes the item. |
| Undo the last hidden item | Hidden section unmounts, as it does today when the hidden feed is empty. Show hidden leaves the header. |
| Show hidden with a long feed | Scrolls the Hidden header to the top of the popover viewport, or as far as content allows. |
| Restore all while a toast names some of those items | Those keys come back immediately. A later Undo skips them. |
| Restore (N) includes a key in the standing streak | Same skip-on-Undo rule. |
| Rapid dismisses | One toast, climbing count, one Undo for the set. Not one toast per row. |
| Dismiss, close popover, press Undo | Item is undismissed. Next open shows it in the visible feed if it still belongs there. |
| Urgency later escalates | Existing key rule stands: a dismissal suppresses the item only until it escalates to a new tier. This HLD does not change that. |
| Repeating event / bill occurrence | Dismissal stays per occurrence, as today. The toast and Hidden row name that occurrence, via the same title and due subtitle. |
| Reduced motion | Exit animation already collapses to zero. Toast and Hidden expand follow existing reduced-motion paths. |
| Android | Dismiss targets stay 48px. Show hidden uses the same dense glass button as Clear; do not shrink its hit target below the header's current buttons. |

---

## 8. Files

| File | Change |
|------|--------|
| `lib/features/notifications/notification_inbox_popover.dart` | Header Show hidden; Restore all moved onto Hidden; hidden row subtitle and type glyph; dismiss / Clear all undo. |
| `lib/core/soft_delete/soft_delete_toast.dart` | Either a sibling helper for the dismiss streak (preferred — do not overload Deleted copy) or a small shared "one standing offer" so delete and dismiss still replace each other. |
| `INBOX_POPOVER_HLD.md` | Header Restore all and Hidden row lines superseded by this document. |
| `test/notification_inbox_*.dart` | New coverage below. Existing popover tests stay green. |

Pinned-note delete, feed construction, and `notificationDismissals` persistence are untouched.

---

## 9. Testing

- Header shows **Show hidden** when anything is hidden, and does not show **Restore all**.
- Show hidden expands the section and does not undismiss anything. A second press does not collapse it.
- Hidden collapsed: no Restore all. Expanded, nothing selected: Restore all. Selection non-empty: Restore (N) only.
- Hidden row shows the feed subtitle (due / date · time / amount · due) and a type glyph. No urgency dot.
- Single dismiss raises `Hidden "<title>"` with Undo. Undo puts that item back in the visible feed.
- A second dismiss before the toast expires rewrites to `Hidden 2 items`. Undo restores both.
- Clear all raises one `Hidden N items` toast. Undo restores that batch, including keys already in a standing streak.
- Undo after the popover is closed still undismisses.
- Undo after the same key was restored from Hidden is a no-op.
- Pinned-note delete still says Deleted, and still does not appear in Hidden.
