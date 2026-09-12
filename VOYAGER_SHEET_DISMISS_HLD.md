# Voyager Sheet Dismiss Policy — HLD

When `showVoyagerSheet` (and the rare direct `showModalBottomSheet`) should allow **drag-to-dismiss**, when to show a **grab handle**, and how that differs by platform. Driven by the LeetCode track-form accidental-dismiss case and an audit of every sheet caller.

Related: `lib/core/widgets/glass_surface.dart` (`showVoyagerSheet`), `lib/features/leetcode/leetcode_track_modal.dart`, `lib/features/study/study_card_editor_modal.dart`, `lib/features/study/study_import_text_modal.dart`, `lib/features/workout/workout_target_editor.dart`, `lib/features/finance/finance_transaction_modal.dart`, `lib/features/finance/finance_subscription_modal.dart`, `lib/features/shell/shell_bottom_nav.dart`, `PRODUCT.md` (Windows desktop design target; Android is the touch port).

Status: **design** (not implemented).

---

## 1. Goals

- Stop accidental drag-dismiss on **dense / high-cost** sheets on **desktop**, where mouse drag and text/wheel gestures collide with sheet drag.
- Keep drag-to-dismiss on **Android**, where a downward sheet flick is a normal, expected cancel gesture.
- Never show a **grab handle** that lies (handle only when drag is actually enabled).
- Encode a durable **global sheet policy** so future sheets do not re-litigate this per modal.
- Leave **barrier tap** dismiss unchanged in this pass.

## 2. Non-goals (this pass)

- Changing `barrierDismissible` / scrim-tap dismiss (leave Material / current defaults).
- Disabling drag on remaining finance sheets (budget, category, goal, asset, allocate, category manager), study pickers, name sheets, or the shell “More” overflow.
- Moving LeetCode track / study editors off `showVoyagerSheet` onto `showVoyagerDialog`.
- Adding Escape-to-dismiss policy changes (existing Close / route pop stay).
- Draft autosave for sheets that lack it (Study card, Study import, Workout target, LeetCode edit, finance edit paths).
- Teaching / onboarding copy about sheet gestures.

---

## 3. Product decisions (locked)

| Decision | Choice |
|----------|--------|
| **v1 scope** | Disable drag on the **six editors** in §5, not on every `showVoyagerSheet` caller. |
| **Platform** | Drag stays **on for Android**, **off for desktop** (Windows) on those editors. |
| **Handles** | Remove grab pills on editors **when drag is off**. Do not invent decorative handles. On Android, if drag remains on, **keep or add** a real handle so the gesture stays discoverable. |
| **Barrier tap** | **Leave as today.** |
| **Finance** | **Transaction** and **subscription** are `editor`. Other finance sheets stay `sheet` (budget, category, goal, asset, allocate, category manager). |
| **Jobs / manage UIs** | Already dialogs — no change. |

---

## 4. Global sheet policy (recommended)

Treat every bottom sheet as one of two kinds. The kind decides drag, handle, and (later, if desired) other chrome — not ad-hoc per-file booleans forever.

### 4.1 Kinds

| Kind | Meaning | Examples |
|------|---------|----------|
| **`editor`** | Dense create/edit work: multiline text, code, bulk paste, media, multi-field money forms, or **vertical gesture controls** (wheels). High cost if dismissed mid-edit. | LeetCode track, Study card editor, Study import, Workout target editor, Finance transaction, Finance subscription |
| **`sheet`** | Short form, picker, inspector, or overflow menu. Looks like a sheet; dismiss is cheap or reversible. | Finance budget / category / goal / asset / allocate, Study move/link/name, Workout name, shell More, finance category manager, linked-deck inspector |

### 4.2 Rules

| Rule | Desktop (Windows) | Android |
|------|-------------------|---------|
| **`editor` — drag-to-dismiss** | **Off** | **On** |
| **`sheet` — drag-to-dismiss** | **On** | **On** |
| **Grab handle** | Only if drag is on for that surface | Same: handle ↔ drag |
| **Explicit Close / Cancel** | Required on `editor`; already common on `sheet` | Same |
| **Barrier tap** | Unchanged for now (still dismisses) | Unchanged |

**Handle rule (absolute):** a grab pill is an affordance for drag, not decoration. If `enableDrag == false`, there is no pill. If drag is on and the surface is sheet-shaped, show the standard 36×4 pill used elsewhere.

**Why not “drag off everywhere on desktop”?** Remaining short finance forms and pickers already teach drag with handles; killing that globally would be a larger UX rewrite than the problem warrants. Editors are where drag fights the task.

**Why keep drag on Android for editors?** Product is desktop-first for layout, but Android still owes native cancel gestures. A near-full-screen editor without drag *and* without a reliable Back path would feel trapped; Back already exists — drag is the complementary sheet gesture. Keep it.

**Why transaction + subscription but not all finance?** Those two are the longest, most-touched money forms (amount + notes + dates / billing / tags). Budget, category, goal, asset, and allocate stay shorter and sheet-shaped; promote later only if desktop drag-dismiss bites in practice.

### 4.3 API shape (implementation target)

Extend `showVoyagerSheet` so callers declare kind (or an explicit override), and the helper resolves `enableDrag` + documents handle policy:

```text
enum VoyagerSheetKind { editor, sheet }

Future<T?> showVoyagerSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  VoyagerSheetKind kind = VoyagerSheetKind.sheet,
  // Optional escape hatch; prefer kind.
  bool? enableDrag,
  …
})
```

Resolution:

```text
enableDragResolved =
  enableDrag ??
  (kind == VoyagerSheetKind.sheet || _isAndroid);
```

`_isAndroid` from `defaultTargetPlatform` / existing platform helpers — match project convention.

Call sites for the six editors pass `kind: VoyagerSheetKind.editor`. Everything else keeps the default `sheet` (today’s behavior).

Shared grab-handle widget (optional follow-up): one `VoyagerSheetHandle` used by remaining finance / study pickers so chrome stays identical; editors on Android use the same widget when drag is on.

### 4.4 Future callers checklist

Before opening a new bottom sheet, ask:

1. Is this mostly **typing / editing / dialing**, or mostly **picking / confirming**?
2. If the user flings it away mid-task, is lost work **painful**?
3. Are there **vertical gestures inside** (scroll wheels, large code selection, nested scroll)?

If (1) editing, (2) painful, or (3) yes → **`editor`**. Otherwise **`sheet`**.

If unsure and the UI is near full-screen with Save + Close, default to **`editor`**.

### 4.5 What not to do globally (yet)

- Do **not** flip the default of `showVoyagerSheet` to `enableDrag: false` without migrating remaining `sheet` callers — that would silently remove a gesture those UIs advertise with handles.
- Do **not** remove grab pills on remaining finance `sheet` surfaces in this workstream.
- Do **not** couple this to barrier-tap policy until editors have lived with drag-off-on-desktop for a bit; barrier tap is a separate, rarer accident on desktop.

---

## 5. v1 implementation — six editors

| Surface | File | Today | v1 change |
|---------|------|-------|-----------|
| LeetCode track | `leetcode_track_modal.dart` | Near-fullscreen via `showVoyagerSheet`; **no** handle; drag on | `kind: editor` → drag **desktop off / Android on**; no handle on desktop; **add** standard handle on Android only |
| Study card editor | `study_card_editor_modal.dart` | Handle present; drag on | `kind: editor`; **remove** handle when drag off (desktop); **keep** handle on Android |
| Study import | `study_import_text_modal.dart` | Handle present; drag on | Same as card editor |
| Workout target | `workout_target_editor.dart` | Wheels; **no** handle; drag on | `kind: editor`; no handle on desktop; **add** handle on Android only |
| Finance transaction | `finance_transaction_modal.dart` | Handle present; drag on | `kind: editor`; **remove** handle when drag off (desktop); **keep** handle on Android |
| Finance subscription | `finance_subscription_modal.dart` | Handle present; drag on | Same as transaction |

Close / Cancel / Save buttons unchanged. Barrier tap unchanged.

### 5.1 Handle visibility pattern

Prefer one place deciding visibility:

```text
final drag = /* resolved enableDrag for this route */;
…
if (drag) VoyagerSheetHandle(),  // or inline 36×4 pill
```

Do not leave a desktop-only orphan pill on Study card / import / transaction / subscription after drag is disabled.

### 5.2 Direct `showModalBottomSheet`

`shell_bottom_nav.dart` “More” overflow stays a **`sheet`**: keep drag + handle on both platforms. No change in v1.

---

## 6. Out-of-scope inventory (unchanged in v1)

These remain `VoyagerSheetKind.sheet` behavior (drag + existing handles where present):

- Finance: budget, category, goal, asset, allocate, analytics category manager
- Study: name, move, move destination, link deck, linked-deck inspector
- Workout: name modal
- Shell: More overflow

Remaining short finance forms can promote to `editor` later without a new HLD if desktop accidental-dismiss shows up in real use.

---

## 7. Test plan

- **Desktop:** On each of the six editors, drag on sheet chrome / empty padding does **not** dismiss; Close / Cancel still dismiss; Save still works; text selection / workout wheels do not dismiss the sheet.
- **Android:** Same six editors **do** drag-dismiss; grab handle visible; Back still dismisses.
- **Regression:** Open a finance **budget** (or allocate) sheet and Study move sheet on desktop — drag-dismiss and handle still work.
- **Chrome:** Study card / import / transaction / subscription on desktop show **no** grab pill; on Android they do.

---

## 8. Rollout

1. Land API (`VoyagerSheetKind` + `enableDrag` resolution) in `showVoyagerSheet`.
2. Wire the six editors; fix handle chrome to follow drag.
3. No user-facing migration / settings.
4. Optional later: extract shared `VoyagerSheetHandle`; consider barrier-tap policy for `editor` if needed.

---

## 9. Open points (intentionally deferred)

- Whether `editor` on Android should also prefer a slightly stronger drag threshold so wheels/text compete less — measure after v1.
- Whether LeetCode track should eventually become a dialog on desktop (separate composition decision; dismiss policy alone does not require it).
- Barrier-tap off for `editor` on desktop — only if tap-outside false dismissals appear after drag is fixed.
