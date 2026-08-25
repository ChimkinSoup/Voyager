# Caps Lock Caret Indicator (HLD)

A caret-anchored Caps Lock mark for Voyager text fields, inspired by Apple’s hardware-keyboard Caps Lock glyph — **Voyager-styled**, not an OS clone. Visible only while an editable field is focused and Caps Lock is on.

This document is a high-level design. It records product decisions and the intended architecture against Voyager’s existing text / overlay / settings stack. It is not an implementation checklist.

Status: design (not implemented).

---

## 1. Goals

- Show a small **Voyager-styled Caps Lock mark** next to the caret when Caps Lock is on.
- Appear only while a **focused, editable** text field owns the caret.
- Cover **all ordinary text fields** the user types into; **exclude code editors** (same hard opt-out pattern as snippets / `LeetCodeCodeField`).
- Run on **Windows and Linux desktop only** — never draw on macOS (system already provides this) or on mobile.
- Keep Caps Lock lock-mode state **correct immediately on window / field refocus** (no stale “off” after Alt+Tab until the next key).
- Persist a user **master toggle** (default **on**) through settings, remote sync, and import/export — same pipeline as snippets.

### Non-goals (v1)

- macOS custom badge (defer to the system glyph).
- Mobile / soft-keyboard Caps Lock chrome.
- Num Lock, Scroll Lock, or input-source indicators.
- Shell / status-bar Caps Lock chip, or toasts when Caps Lock toggles outside a field.
- Accessibility live-region announcements (may revisit later).
- Changing Caps Lock key behavior, remapping, or Vim’s treatment of Caps Lock as a modifier key.
- Drawing inside the LeetCode code editor (or any future dedicated code field).

---

## 2. Product model

### 2.1 Setting

| Setting | Meaning | Default |
| --- | --- | --- |
| `capsLockIndicatorEnabled` | Master switch for the caret badge | `true` |

No per-field setting. Opt-out for code fields is structural (widget flag), not user-facing.

### 2.2 Where it may appear

**Eligible:** any focused, enabled, non-read-only `EditableText` / text field that Voyager mounts for free typing or structured single-line entry — including **obscure / password** fields (badge still shows; Caps Lock is security-relevant there).

**Explicit exclusion:** `LeetCodeCodeField` (and any future sibling code editor) never shows the badge, even if Caps Lock is on and the field is focused. Same spirit as `snippetsAllowed: false` on that widget.

**Not gated by** `vimSuitsField`. Snippets and Vim skip obscure / formatter / numeric fields; this indicator does **not**. If the field has a caret the user can type with, the badge may show (subject to platform + setting + Caps Lock + selection rules below).

**Platform gate (hard):**

| Platform | Draw badge? |
| --- | --- |
| Windows desktop | Yes |
| Linux desktop | Yes |
| macOS desktop | **No** |
| iOS / Android (any keyboard) | **No** |

---

## 3. Visibility rules (normative)

The badge is shown **only** when **all** of the following hold:

1. `capsLockIndicatorEnabled` is `true`.
2. Current platform is Windows or Linux desktop.
3. Primary focus is inside an eligible editable text field (not read-only, not disabled, not a code-field opt-out).
4. Hardware Caps Lock lock mode is **on** (`KeyboardLockMode.capsLock` in Flutter’s lock-mode set).
5. The field’s selection is **collapsed** (caret only). **Hide** whenever a range is selected.
6. Vim **Visual** mode with anything highlighted: **hide** (same as range selection). If Visual somehow has a collapsed selection, still treat “highlighted range” as hide; collapsed Visual with no highlight may show — prefer implementing as “hide iff selection is non-collapsed,” which covers Visual highlights without a separate Visual special case beyond documentation.

It does **not** show when:

- Caps Lock is off.
- Focus is not in an editable field (shell navigation, buttons, lists, etc.).
- The setting is off.
- Platform is macOS or mobile.
- A text range is selected / Visual highlight is active.

No flash or toast on Caps Lock toggle outside a field. No badge while the field is unfocused even if Caps Lock remains on.

---

## 4. Visual design

- **Mark:** Voyager-styled (Phosphor / design-system iconography), not a pixel clone of Apple’s Caps Lock HUD.
- **Placement:** immediately to the **right** of the caret’s right edge, with a small fixed gap (on the order of field padding / `xs`–`sm` spacing — exact px at implement time).
- **Insert vs Normal (Vim):** same placement rule relative to the **right edge of the painted caret**. In Insert that is Flutter’s thin caret (or the overlay caret width the field already uses). In Normal that is the **block caret** from `VimTextOverlay` — measure that block’s right edge, then apply the same gap. Do not recenter on the block or change vertical alignment between modes.
- **Motion:** slight **fade** in and out when visibility flips (short opacity transition). No bounce, scale pop, or slide.
- **Color / weight:** muted ink / on-surface at restrained opacity so it reads as status chrome, not a second caret. Must remain visible on both light paper and dark graphite themes (`DESIGN.md` tokens).
- **Hit testing:** ignore pointer — the badge is purely visual; clicks pass through to the field.
- **Z-order:** above text and selection/squiggle layers; must not obscure the caret itself. May sit alongside tag-suggestion / snippet tabstop chrome without claiming keys.

### 4.1 Horizontal flip at the right edge

If placing the mark to the right of the caret would clip outside the field’s content box (or the visible clip of the editable), **flip** and place it to the **left** of the caret’s left edge with the same gap.

- Prefer flipping over clipping or overflowing outside the field.
- Re-evaluate on caret move, text change, layout, and scroll.
- Vertical alignment: center on the caret rect’s vertical mid (or baseline-adjacent band consistent with overlay painters) so multiline rows stay aligned.

---

## 5. Caps Lock state & refocus correctness

### 5.1 Source of truth

Flutter `HardwareKeyboard` lock modes — specifically whether `KeyboardLockMode.capsLock` is enabled. Drive UI from lock-mode changes, not from guessing via Shift+letter heuristics.

### 5.2 Immediate correctness on refocus (required)

After the window or app loses and regains focus (Alt+Tab, click-away, OS lock screen, etc.), Caps Lock state must be **correct as soon as an eligible field is focused again** — without waiting for the user to press another key.

**Implications:**

- On window / app focus regain, **resync** hardware keyboard state (extend the existing Windows `syncKeyboardState` path; Linux needs the same guarantee).
- On an eligible field gaining focus, ensure lock-mode is read from the post-sync state (or trigger a sync if the last window-level sync may be stale).
- Listening only to key events is **insufficient** for v1; focus regain without a key event must still update the badge.

Voyager already mitigates Windows keyboard desync (`windows_keyboard_workaround.dart`, `resyncWindowsKeyboardState` on app lifecycle). This feature **raises** that path from “best effort / avoid asserts” to a **product requirement** for Caps Lock lock mode on Windows and Linux.

---

## 6. Architecture (how this sits in the repo)

### 6.1 Layering

```text
Settings (AppSettings)
    └── capsLockIndicatorEnabled (default true)
            │ sync / import-export (existing settings pipeline)
            ▼
CapsLockIndicatorScope (InheritedWidget at app root — parallel to VimEnabledScope)
  · enabled flag from settings
  · platform gate (Windows/Linux only → effective false elsewhere)
            ▼
Eligible field wrappers
  VoyagerTextField / LabeledTextField / TagHighlightedTextField / …
  (LeetCodeCodeField hard-opts out)
            ▼
TextField / EditableText
            ▼
CapsLockCaretOverlay  (IgnorePointer, fade)
  · listens to HardwareKeyboard lock modes + focus + selection + scroll
  · measures caret via RenderEditable (Insert) or Vim block rect (Normal)
  · flips left when right placement would clip
```

### 6.2 Recommended ownership

| Concern | Owner |
| --- | --- |
| Master toggle | `AppSettings.capsLockIndicatorEnabled` + Settings UI row |
| Effective “may draw on this platform” | Scope / small platform helper (`isWindows \|\| isLinux`, never macOS/mobile) |
| Lock-mode listening + resync on focus | Shared keyboard helper (extend `windows_keyboard_workaround` / platform keyboard sync to cover Linux + Caps Lock consumers) |
| Per-field paint + caret measure | `CapsLockCaretOverlay` mounted beside existing overlays (`VimTextOverlay`, spellcheck, selection, tag portal) |
| Code-editor opt-out | `LeetCodeCodeField` (and peers) do not mount the overlay / pass `capsLockIndicatorAllowed: false` |

### 6.3 Caret measurement

Reuse the measurement approach already used by tag suggestions and Vim overlays:

- **Insert (Vim off or Insert mode):** `RenderEditable.getLocalRectForCaret` for the collapsed selection offset; convert to overlay/field coordinates.
- **Normal mode:** use the same geometry `VimTextOverlay` uses for the block caret’s bounds; badge gap is from that rect’s **right** edge (or left when flipped).
- Subscribe to: selection changes, text changes, scroll offset, layout, focus, lock-mode, and setting/platform effective enablement.

### 6.4 Persistence & sync

- Store `capsLockIndicatorEnabled` on `AppSettings`.
- Extend `settingsToFirestore` / `settingsSyncPayload` / `mergeSettingsFromRemote` / import-export the same way other boolean settings (e.g. `snippetsEnabled`) are handled.
- Merge policy: existing field-level / last-write settings merge.
- Backup zip already dumps settings JSON — this flag rides along once on `AppSettings`.
- DB column + migration when the settings table is schema-versioned (same pattern as prior settings flags).

### 6.5 Settings UI

- One toggle under Settings near Vim / keyboard-related controls (e.g. near “Vim keybindings” / snippets entry).
- Label along the lines of **Caps Lock indicator** with short subtitle: shows a mark next to the caret when Caps Lock is on (Windows & Linux).
- Toggling off hides any visible badge immediately; toggling on shows it on the next frame if visibility rules already hold.

---

## 7. Edge cases (normative)

| Case | Behavior |
| --- | --- |
| Caps Lock on, no text field focused | Hidden |
| Caps Lock on, eligible field focused, collapsed caret | Shown (Windows/Linux, setting on) |
| Range selection / Vim Visual with highlight | Hidden |
| Vim Normal, block caret | Shown; gap from block’s right edge; same flip rule |
| Vim Insert | Shown; gap from thin caret’s right edge |
| Obscure / password field | Shown (unlike Vim/snippets eligibility) |
| Read-only or disabled field | Hidden |
| `LeetCodeCodeField` | Never shown |
| macOS | Never shown (system glyph only) |
| Mobile | Never shown |
| Caret at right edge of field | Flip mark to the left of the caret |
| Field scrolls (multiline) | Badge tracks caret; hide if caret scrolled out of the visible clip (optional polish: hide when caret rect not intersecting paint clip) |
| Setting turned off while badge visible | Fade out and stay off |
| Alt+Tab away and back with Caps Lock still on | After resync, badge correct **immediately** on refocus — no waiting for a key |
| IME composition in progress | Still show if Caps Lock on and selection collapsed; badge tracks the composing caret |
| Multiple windows / focus park | Only the focused field’s overlay draws; others hidden |

---

## 8. Testing plan (high level)

- Unit / thin integration: visibility predicate (setting × platform × focus × lock mode × collapsed selection).
- Widget: badge appears when Caps Lock simulated on + field focused; disappears on range select, Visual highlight, blur, setting off.
- Layout: right placement; flips left when caret is at the trailing edge; Normal-mode gap uses block caret width.
- Focus: after forced keyboard desync / simulated focus regain, lock mode resync leaves badge correct without an intervening key event (Windows primary; Linux covered by same API path).
- Settings: default `true`; sync round-trip; import/export includes the flag.
- Regression: `LeetCodeCodeField` never mounts/shows the badge; macOS builds never paint it; obscure fields still show it.

---

## 9. Decisions log

| # | Decision |
| --- | --- |
| 1 | All ordinary text fields; **not** code fields (snippet-style hard opt-out) |
| 2 | **Desktop Windows & Linux only**; no macOS custom badge; no mobile |
| 3 | Voyager-styled mark with a **slight fade**; not an Apple pixel clone |
| 4 | Show **only** when focused editable field + Caps Lock on |
| 5 | **Show** on obscure / password fields |
| 6 | Show in Vim **Normal** as well as Insert; same gap from caret’s **right** edge |
| 7 | **Hide** in Visual when anything is highlighted; **hide** on any non-collapsed selection |
| 8 | If no room on the right, **flip to the left** |
| 9 | Setting `capsLockIndicatorEnabled`, default **on**; remote sync + import/export |
| 10 | Caps Lock state must be **correct immediately on refocus** (resync, not key-wait) |
| 11 | Related ideas (Num Lock, status chip, toasts, a11y announce, layout indicator) deferred — not in v1 |

---

## 10. Open implementation notes (non-blocking)

These do not change product behavior; resolve at implement time:

- Exact icon asset / Phosphor glyph and fade duration (`DESIGN.md` motion tokens if present).
- Whether “caret out of clip → hide” is required in v1 or only flip-at-edge.
- Shared helper vs field-local listener for `HardwareKeyboard` (prefer one app-level lock-mode listenable to avoid N handlers).
- Whether Linux needs any platform channel beyond Flutter’s `syncKeyboardState` (verify on target distros during implementation).
