# Voyager QA Audit, Mobile (Android): Test Plan

Written 2026-11-22, on `349e49df` plus the uncommitted Gaia settings work. The desktop audit (`qa/TEST_PLAN.md`, Phases 1–28B and FV, Windows only) treated Android and the compact layout as out of scope (PROGRESS.md §6). This plan covers that ground. Its two-device side is `qa/MOBILE_SYNC_TEST_PLAN.md`.

This plan doesn't repeat the desktop functional checks one by one. The pages are the same Dart code, and the desktop phases already went through their logic. Each mobile phase instead:
1. runs the page's **main flows end to end on the phone**, because the compact layout, touch input, soft keyboard and Android lifecycle can break a flow that works on desktop;
2. tests what exists **only on Android**, or behaves differently there (§0.2 lists the code that branches);
3. re-checks the desktop phase's **Blocker and Major bugs** that are marked fixed and touch that page, from the phone;
4. tests **features shipped after the desktop audit** that no desktop phase covered (§0.3).

---

## DEVICE: Juno's OnePlus 12R over USB (decided 2026-11-22)

The audit runs on **Juno's own phone**, not the emulator. The emulator heated the laptop and used 5.4 GB of RAM. Wherever this plan, `MOBILE_SYNC_TEST_PLAN.md` or PROGRESS.md still says "emulator", read "the phone", with the differences below. M0 was first run on the emulator and must be **redone on the phone** (see its Status line).

- **The phone:** OnePlus 12R, OxygenOS, Android 16. It is connected by USB with USB debugging on, and Juno doesn't use it during testing. The USB mode is **"Charging this device"**, which worked for adb with another app. If adb, an install or input misbehaves, ask Juno to switch it to **"File transfer"** rather than working around it. M0 records:
  - the serial from `adb devices` (scripts target it with `-s` / `flutter run -d <serial>`);
  - the real `wm size` / `wm density`, which replace the emulator's 1080×2400 figures below;
  - its dp width, i.e. which shell it gets;
  - its cutout.
- **Voyager on the phone is disposable.** Juno doesn't use Voyager on the phone, so wiping or uninstalling an existing install is fine (Juno, 2026-11-22). If a differently signed copy is installed, `flutter run` uninstalls it on its own. The guard still applies: never send input while the app holds a non-QA account. If `phone.ps1 check` refuses, first back up `files/` through `run-as` if it works (as M0 did for qa-128), then `pm clear` or uninstall. There's no need to ask Juno first.
- **Global settings:** Juno is fine with phases changing the phone's settings: font scale, display size, rotation, timezone, clock, airplane mode, dark mode, permissions, Doze, "Don't keep activities". **Restore Juno's own values, not the plan's standard ones.** M0 records Juno's values in PROGRESS.md §1b. Session start sets the standard configuration, and session end puts Juno's values back. If a session dies mid-phase, the next session start fixes things.
- **Do Not Disturb during every session**, like `voy.ps1 awake on/off` on desktop. Heads-up notifications from other apps cover the top of the screen, swallow taps and land in screenshots.
  - Session start records the current mode (`settings get global zen_mode`), then turns DND on (`cmd notification set_dnd on`).
  - Session end restores the recorded mode (`set_dnd off` if it was 0).
  - Checks that expect a **Voyager** notification to pop up turn DND off for that check and back on afterwards: M4 reminders, M18 series reminders, M19 Gaia push, sync plan MS-8.
  - Juno doesn't mind other apps' notifications showing in the shade or in shots. Never open, tap or dismiss them.
- **Screen lock: defer, don't ask.** M0 checks whether a lock is set (`locksettings get-disabled`, or the lock screen showing after `input keyevent 26` twice). **Never type a PIN.** While a lock is set:
  - keep the screen on all session with `svc power stayon usb` (session end: `svc power stayon false`), so the lock never engages mid-session;
  - don't run any check that turns the screen off, reboots, or needs the lock screen. That covers `input keyevent 26` screen off/on, `adb reboot` (after a reboot Android wants the PIN before the app's storage unlocks), lock-screen notification visibility, and anything else that ends at the lock screen;
  - mark such an item `[~] deferred (lock)` in the checklist and add it to PROGRESS.md §6b "Deferred until the screen lock is off" with the phase, then carry on;
  - every phase report tells Juno how many items are on that list. Juno offered to turn the lock off for a session: at M25, or earlier if Juno asks, one session runs the whole list. Before it starts, remind Juno to turn the lock back on afterwards.
- **There are no emulator-only commands** (`adb emu …`):
  - **incoming call** (`gsm call`): add it to §6b's list as "needs Juno to call the phone";
  - **location** (`geo fix`): the real GPS reports where Juno actually is. Test the permission flow (ask, deny, "don't ask again", grant) and that the map centres on *something*. Don't write coordinates or place names into BUGS.md, PROGRESS.md or logs, and delete any screenshot that shows Juno's real position once you've looked at it;
  - **slow network** (`network speed` / `network delay`): use Wi-Fi/data/airplane toggles for "flaky". Slow-link checks go to §6b as "manual: slow network";
  - **camera:** the real cameras. Captures photograph whatever the phone faces; they live in the QA account's vault and `pm clear` wipes them. The real-optics items (M18) are **in scope now**;
  - **hardware-keyboard spot check:** there's no host keyboard. Send key events with `input keyevent` and `input keycombination` (e.g. Ctrl+Enter, Esc); M0 checks that they work;
  - **display cutout:** the phone's real one; no developer-option simulation.
- **Nothing to boot or shut down.** Session start waits for `adb devices` to show the phone as `device`. If it shows `unauthorized`, ask Juno to accept the USB-debugging prompt. If it's missing, ask Juno to check the cable or the USB mode. There's no `adb emu kill`; the phone stays on.
- **OxygenOS quirks:**
  - if `input`, `pm grant` or `appops` fails with a `SecurityException`, Developer options may need "Disable permission monitoring" (or a similar OEM switch): ask Juno, don't hunt for it yourself;
  - OxygenOS kills background apps more aggressively than stock Android. For reminders, sync and Gaia push that's real behaviour: record it, and judge whether it's a Voyager bug or a platform limit (the app could ask for an exemption, for example);
  - keyboard: record which one is the default in M0 (`settings get secure default_input_method`). The plan assumes Gboard.
- **Battery:** Juno turns on the phone's battery protection. Nothing to do here.
- **The emulator stays installed but unused**, unless Juno asks for it.

---

## HOW TO RUN A PHASE SESSION

You start with no context. Read `qa/PROGRESS.md` (environment, harness, accounts, quirks, manual-only list), this file, and the last ~20 entries of `qa/BUGS.md`. Read `qa/TEST_PLAN.md` for the desktop phase each mobile phase points to: its flows, test data and bugs tell you what's already known.

### RULES (every mobile session)

Every desktop rule still applies (`TEST_PLAN.md` "RULES" and the account safety rules): test by running the app, don't write a test suite, never fix bugs or change app code, never exercise anything MANUAL-ONLY, one session at a time, only `voyager-qa-*@example.com` accounts, harness scripts go in `qa/` only. On top of those:

- **Phone safety comes first.** The emulator's Voyager has been signed into Juno's real account before (memory `phone-guard-real-account`). Send input **only** through `qa/harness/phone.ps1` (or the harness built in M0 on top of it), which refuses anything unless the app is signed out or its data belongs to a UID in `qa/harness/phone_accounts.txt`. Run `phone.ps1 check` at session start and before anything destructive. If it refuses, **stop and ask Juno**: the install may hold unsynced real data. Never add a real account's UID to the allowlist.
- **Add each new QA account's UID to `phone_accounts.txt`** as soon as it exists, from its desktop profile (`settings_table.local_owner_uid`) or by reading the phone DB after sign-in.
- **`adb install -r` keeps the old sign-in.** After any reinstall, run `phone.ps1 check` before the first tap.
- **`pm clear com.example.voyager`** is the phone's baseline reset (wipe + sign out). Use it only after `phone.ps1 check` passes and the outbox is drained (`pending_uploads_table` = 0 in the pulled DB). Like `reset.ps1`'s sync gate, it must not throw away unsynced QA data you still need.
- **No real Google sign-in.** Continue with Google is visible on Android (`login_page.dart:138`). It stays MANUAL-ONLY, as on desktop.
- **Don't change the phone's global state and leave it.** Font scale, display size, rotation lock, airplane mode, Doze, permissions, timezone, dark mode and developer options are all set by `adb`. Every phase that changes one restores **Juno's own value** at the end (PROGRESS.md §1b), and the session log records the restore (the M0 toolbox lists the undo for each).
- **Juno keeps the laptop.** The phone sits beside it on USB; nothing runs on the laptop's screen. Nothing in this plan needs the Windows foreground except the desktop half of the sync plan, which has its own rules.

### SESSION WORKFLOW

1. Read the files above.
2. Pick the first Not Started phase (unless Juno names one) and set it to In Progress.
3. **Phone SESSION START** (M0 builds it): the phone shows as `device` in `adb devices` → Do Not Disturb on, screen kept on → `phone.ps1 check` → install or reuse the debug build → sign in (fresh account with sign-up, or reuse one) → `phone.ps1 check` again, which must report the QA UID → check the standard configuration below.
4. Work through the phase's checklist and all five dimensions. Tick items as you go, and log bugs as you find them, not at the end.
5. Before finishing: set the phase to Done (or leave it In Progress with exactly where you stopped), update PROGRESS.md (phase log, accounts, test data, quirks, handoff), and tell Juno the next phase and the bug count by severity.
6. **Phone SESSION END**: wait for the outbox to drain → sign out in the app (Settings → Account) → `pm clear` → `phone.ps1 check` says `signed out` → restore Juno's value for every global setting the phase changed → restore Do Not Disturb and `stayon`. Report the count on PROGRESS.md §6b's deferred list.

### Standard test configuration (phone)

- **Device:** Juno's OnePlus 12R (see DEVICE above). Record its real size and density in M0 with `adb shell wm size` / `wm density`. It should be the **compact** shell (below 600 dp, `window_size_class.dart`). The emulator figures this plan was written with were 1080×2400 at 420 dpi (411×914 dp); where a phase quotes them, use the phone's.
- **Orientation:** portrait, auto-rotate off (`settings put system accelerometer_rotation 0`), unless the phase tests rotation.
- **App theme:** Dark + Scatter (the app defaults; the same SQL check as desktop: `theme_mode='dark'`, `geometric_wave_scatter_mode=1`, `geometric_wave_enabled=0`, `geometric_texture_scale=15.0`). Each phase spot-checks Light once. M21 is the full Light pass.
- **System:** gesture navigation, font scale 1.0, default display size, system dark mode **on** (so the system bars match). English (US) locale. Gboard as the keyboard.
- **Build:** debug APK from the working tree. Record `git log -1 --oneline` and `git status --short lib/` in the session log, as on desktop. M23 also needs a release (or profile) build.

### Practical notes

- **Coordinates are physical pixels** (the phone's `wm size`, from PROGRESS.md §1b), the same as `phone.ps1 shot` PNGs. Prefer `phone.ps1 ui` for text targets. Flutter exposes little to UI Automator, so check M0's result before relying on it; the VM-service `find` (desktop `vm.ps1`) is the better locator once M0 connects it to the phone.
- **Look at a screenshot after every meaningful action.** The background animates, so two shots of the same state differ there.
- **Data checks are read-only.** Pull the DB **with its WAL**: `adb exec-out run-as com.example.voyager cat files/voyager.sqlite > …`, the same for `voyager.sqlite-wal` and `-shm`, into a scratch folder, then open it read-only in Python. A pull without the WAL misses recent writes. M0 wraps this in a script.
- **Errors:** check the `flutter run` / attach output and `adb logcat` (filter `flutter`, `AndroidRuntime`, `FATAL`) for `EXCEPTION CAUGHT`, `RenderFlex overflowed`, `Another exception`, ANRs and native crashes after each flow. A FlutterError is a bug even if the UI looks fine. The app's error log lives in the app's documents directory on Android (`app_data_directory.dart`); M0 records its path.
- **"Survives restart"** on the phone means `am force-stop` → relaunch, then re-check the UI and the DB. **"Survives process death"** is different and matters more on Android: Home → `am kill com.example.voyager` (it kills only a backgrounded app) → reopen from Recents. **"Cold re-login"** = sign out → `pm clear` → sign in again → wait for the startup pull.
- **HLD docs** are listed per phase. A mismatch between the HLD and the app is worth logging. Many HLDs have an Android paragraph; read it.
- **Bug severity:** as on desktop (Blocker, Major, Minor, Cosmetic). Tag mobile bugs `[M<phase>]` in the title, e.g. `### BUG-384 [M5] …`. **Next bug ID: BUG-401.** **Next free account: qa-131**.

### The five dimensions (mobile)

Every phase ticks this sweep, or notes "n/a + why":

- **D1 Functional:** every control on the page does what its label says, by touch; the happy path end to end on the phone.
- **D2 Data integrity:** each create/edit/delete is in the pulled SQLite DB and survives force-stop → relaunch **and** process death. The outbox drains (`pending_uploads_table` → 0). A cold re-login restores it. No duplicates, no orphans, no stray soft-deletes. Where the desktop can see the account (any QA profile signed in), spot-check that the change arrived there too. The full two-device work is in the sync plan.
- **D3 Visual/layout:** run in Dark + Scatter at the standard size, and check every phase at these sizes too:
  - **small phone:** `wm size 720x1280` + `wm density 320` (360×640 dp, the bottom nav's design width);
  - **landscape:** rotate; at 914 dp wide this is the **expanded (desktop) shell** with the rail, so the page switches composition mid-session;
  - **tablet:** `wm size 1600x2560` + `wm density 320` (800 dp, expanded shell in portrait);
  - **font scale:** 1.3 and 2.0 (`settings put system font_scale …`);
  - **soft keyboard open:** every form with the keyboard up. Nothing the user needs may be hidden under it (`adjustResize`), and the focused field must scroll into view;
  - **system insets:** the status bar, the gesture bar and the display cutout (the phone's real one).

  Also check truncation of long titles and the empty states. Watch for `RenderFlex overflowed`. Undo each `wm`/font change afterwards (`wm size reset`, `wm density reset`, `font_scale 1.0`).
- **D4 Touch, Back and soft keyboard** (replaces desktop "keyboard-only"):
  - every control reachable by touch, with no hover-only or right-click-only action left without a touch equivalent (long-press, a visible button, a menu);
  - touch targets at least 48 dp (`kMinTouchTarget`, `touch_target.dart`);
  - taps near the screen edges and the gesture bar land on the control, not the system;
  - scroll, fling, swipe, drag-reorder and pinch where the page has them;
  - **Back** (gesture and `phone.ps1 key 4`) at every depth: it closes the top sheet, dialog, menu or sub-view first, never loses a draft silently, and only leaves the app from the home section (`_handleSystemBack`, `app_shell.dart`);
  - soft keyboard: the IME action (Next / Done / Send) does something sensible, tapping outside dismisses the keyboard where expected, and Enter in a multi-line field inserts a newline;
  - **hardware-keyboard spot check** once per phase: send real key events with `input keyevent` / `input keycombination` (there's no host keyboard on the phone). Vim (Settings → Vim keybindings), Ctrl+Enter submit (`ctrl_enter_to_submit_scope.dart` treats Ctrl the same on Android) and Esc should behave as on desktop. The shell shortcuts (Ctrl+Tab, Ctrl+/) are **off** on Android by design (`shell_keyboard_shortcuts.dart:13`), so confirm they do nothing harmful.
- **D5 Failure cases and lifecycle:**
  - invalid input (empty, whitespace-only, negative/huge numbers, bad dates);
  - very long input (5,000+ chars, a 300-char word, emoji/CJK/RTL). `adb shell input text` can't type spaces or most symbols, so put text on the clipboard (VM eval of `Clipboard.setData`, from M0) and paste with long-press → Paste;
  - rapid repeated taps (double-tap Save, 20 fast toggles);
  - **interruptions, the phone's own list:** Home mid-edit, switching to another app and back, process death while backgrounded, force-stop mid-edit, rotation mid-edit, a notification shade pull, an incoming call (no `adb emu` on the phone: goes on PROGRESS.md §6b's deferred list), screen off/on (`input keyevent 26`; **deferred while a screen lock is set**), Doze (`dumpsys deviceidle force-idle`);
  - **real offline:** airplane mode (`cmd connectivity airplane-mode enable`), or Wi-Fi and data off (`svc wifi disable; svc data disable`). Unlike the desktop's Dev → Force offline, this cuts weather and sign-in too;
  - permission denied (notifications, location, camera);
  - empty/no-data states.

---

## 0. Background for every phase

### 0.1 What's the same, and what isn't

The app is one Flutter codebase. On Android:
- the **shell** switches to the compact composition below 600 dp: a 48 dp status strip (clock, weather, connectivity, sync activity, inbox bell), one pane, and `ShellBottomNav` with **four destinations plus More** (a sheet listing the rest, in the user's nav order). At 600 dp and up (landscape, tablets) it's the desktop rail;
- **Journal, Dreams, Workout, Calendar's day grid and the reminder sticky stack** have their own compact layouts (`isCompactWidth`). Journal and Dreams show the list and the editor one at a time, and register **Back interceptors** so Back closes the editor first;
- **sheets** always drag to dismiss and show a grab handle on Android (`voyagerSheetDrags`, `glass_surface.dart:193`; VOYAGER_SHEET_DISMISS_HLD.md), where desktop drags only some kinds;
- the **app's autocorrect and snippet auto-expansion** drop their "typed on a hardware keyboard" requirement on Android (`autocorrect_session.dart:843`, `snippet_session.dart:556`; SNIPPET.md §7), so they act on soft-keyboard input. That's a different input path from anything desktop tested;
- **Firestore and Firebase Storage run on the native Android SDKs.** Windows runs Firestore on the C++ SDK and media through `FirebaseRestMediaStorage` (`providers.dart:281`). Weather goes through the `cloud_functions` plugin, not the Windows HTTP callable (`providers.dart:724`). Same Dart above, different plumbing below.

### 0.2 Code that behaves differently on Android (the sweep)

Every `isAndroid` / `isWindows` / `isCompactWidth` / `defaultTargetPlatform` branch in `lib/`, as of this plan. Each is tested in the phase named.

| Where | What differs on Android | Phase |
|---|---|---|
| `app_shell.dart` | Compact shell, status strip, bottom nav + More, system Back handling, `SystemNavigator.pop` at home | M2 |
| `shell_bottom_nav.dart` | Four items + More sheet; rail order and hidden pages reused | M2 |
| `shell_keyboard_shortcuts.dart` | Shell shortcuts off on Android | M2 |
| `shell_page_transition.dart` | No rail gutter in compact | M2 |
| `glass_surface.dart` | Every sheet drags to dismiss with a handle; Android-specific sheet route | M2, each page |
| `login_page.dart` | Google button shown; no autofocus on the e-mail field | M1 |
| `firebase_auth_repository.dart` | Windows-only auth path skipped | M1 |
| `voyager_app.dart` | Lifecycle: on resume, reminder engine refresh and auto-backup resume; on pause, auto-backup pause; pending edits flushed on inactive/paused/detached; Gaia push started once paired; no tray, window manager, folder backups or heat watch | M4, M19, M21, M22 |
| `reminder_os_notifier.dart` | `flutter_local_notifications` with **scheduled** alarms (exact if permitted, else inexact, both allow-while-idle), notification permission request, open system settings, launch-from-notification source key, real dismiss/cancel; `raisesDueAlertsInApp` is false | M4 |
| `AndroidManifest.xml` | Boot / package-replaced / timezone-changed receivers, exact-alarm and boot permissions, location, camera (no microphone), predictive Back (`enableOnBackInvokedCallback`), `adjustResize`, backup rules | M1, M4, M14, M18 |
| `device_registration.dart` | Registers as an Android device | M4 |
| `notification_inbox_popover.dart` | Dismiss buttons always visible, 48 dp slot (hover-revealed on desktop) | M4 |
| `scheduled_reminders_section.dart` | Row actions always visible (hover on desktop) | M4 |
| `reminder_sticky_stack.dart` | Compact layout | M4 |
| `secure_window.dart` | `FLAG_SECURE` through `MainActivity` while the vault is unlocked (blank screenshots and Recents thumbnail) | M4, M18 |
| `secure_clipboard.dart` | Android clipboard path for vault content | M4 |
| `photo_capture_screen.dart` | Camera capture with the ghost overlay, Android only (`photoCaptureSupported`) | M18 |
| `journal_page.dart`, `dream_journal_page.dart` | Compact list ↔ editor, Back interceptors | M5, M6 |
| `calendar_day_grid.dart` | Compact day grid | M8 |
| `calendar_event_panel.dart` | No refocus of Title after a picker on touch | M8 |
| `workout_page.dart` | Compact layout | M17 |
| `study_*_modal.dart`, `study_linked_deck.dart` | Android-only buttons in the name, move, move-destination and link-deck modals | M16 |
| `backup_list_dialog.dart` | Save a copy writes through the Android picker (bytes); no Show in folder | M21 |
| `settings_page.dart` | "Global hotkeys: Available on Windows only"; no Start with Windows, folder backups or heat watch | M21 |
| `auto_backup_service` (AUTO_BACKUP_HLD §6.1, §8) | Runs in the foreground only; backups in app-private storage, **wiped on uninstall**; excluded from Android Auto Backup | M21 |
| `app_sounds.dart` | Sounds through `audioplayers` (Windows has its own path) | M21 |
| `media_file_store.dart`, `app_data_directory.dart` | Android storage paths; no dev profiles | M0 |
| `hotkey_service.dart` | No-op hotkeys | M2 |
| `caps_lock_state.dart` | No Caps Lock mark | M3 |
| `providers.dart` | Native Firebase Storage; weather through the `cloud_functions` plugin | M21, M22 |
| `gaia_page.dart`, `gaia_providers.dart`, `gaia_status_tab.dart` | The phone is a Gaia **remote client** of a desktop beacon: pairing, remote commands, Status-tab actions, push; no local runs, drag-reorder or F2 | M19 |
| `features/gaia/host/gaia_flash.dart`, `gaia_control_showcase.dart` | Platform checks in Gaia's flash and control showcase | M19 |

### 0.3 Features the desktop audit never covered

From `git log` since the desktop audit's last phase (28B, 2026-10-20) and the HLDs, checked against `TEST_PLAN.md` and `MULTI_DEVICE_SYNC_TEST_PLAN.md`. Gaia has its own trail (the GAIA_*_HLD §§ live passes and `GAIA_REMAINING_TESTS.md`). For everything else below, no QA phase names it, so this plan tests it on the phone. Juno may also want a desktop pass.

| Feature | Commit / doc | Phase |
|---|---|---|
| Counter statistic (− / + only, carries over, day log) | `COUNTER_STATISTIC_HLD.md`, `counter_controls.dart` | M10 |
| Rankings repeat counter | `RANKINGS_COUNTER_HLD.md` | M14 |
| Sounds (complete / save / log) and the Sounds switch | `473551ac`, `app_sounds.dart` | M21 |
| Timezone change handling; stale-day UI refresh | `42b6efda`, `efa04a45` | M4, M7, M8, M22 |
| Default journal / list / calendar switching | `79f5c468` | M5, M7, M8 |
| Calendar current-date capsule | `c26c586f` | M8 |
| Delete toast changes | `a4f64972` | M20 |
| Global inbox opens Analytics; inbox performance | `c8607d8c`, `48852a2a` | M4 |
| On This Day 31-day fixed period | `e115d85a` | M5 |
| Journal hotkey opens today's entry (desktop), and the "journal start time" fixes | `cbdde752`, `91d6cf75` | M5 (the phone's equivalent path) |
| Undo puts the caret at the change | `99bd8d07` | M3 |
| Photo series hide style, compare/playback fixes, padding, alignment fixes | `d7d2230f`, `cfa76786`, `9dc718ab`, `70fe806d` | M18 |
| Dropdown menu selector UI | `beafa745` | every phase (D1/D3) |
| Firebase SDK updates | `f0892ff4` | M22, sync plan |
| Gaia on the phone: chats, pairing, remote use, push, queue, projects, memory topics, history, fork/rewind/chapters, `/btw`, settings tabs | GAIA_*_HLD.md, `GAIA_REMAINING_TESTS.md` | M19 |

### 0.4 Manual-only on the phone (do not execute)

Add these to PROGRESS.md §6 in M0. Every desktop MANUAL-ONLY row still applies.

| Item | Why |
|---|---|
| Continue with Google on the phone | Real Google OAuth |
| Forgot password with an e-mail filled in | Sends a real e-mail |
| Links that open the browser or another app (`launchUrl`) | Opens real apps and Juno's real accounts on the phone; checking the link exists is fine |
| Juno's other apps and data on the phone: notifications, other apps, files outside Voyager's sandbox and `/sdcard/Pictures` test images | Juno's personal phone. Never open, tap or dismiss other apps' notifications. Push test images only into a `Pictures/VoyagerQA/` folder, and delete it at phase end |
| Gaia prompts that reach a real model, and remote `sleep` / `shutdown` that would act on Juno's laptop | Real cost; real power actions. Use the dummy replies (`/msg1`, `/card1`, …) and a desktop beacon in a QA profile. Cancel any power countdown, as the Gaia passes did |
| The real-device pass (§ at the end): what's left of it | Needs Juno's hands (a call, travel, voice) |

---

## Phase list

| # | Phase | Desktop reference | Status |
|---|---|---|---|
| M0 | Setup: phone, harness, background operation (redo on the OnePlus 12R) | Phase 0 | Done |
| M1 | Install, first run, auth & account lifecycle | P1 | Done |
| M2 | Phone shell, navigation, Back, rotation & sheets | P2 | Done |
| M3 | Text input on the phone: soft keyboard, autocorrect, snippets, formatting, images | P3, P4 | Not Started |
| M4 | Notifications, reminders, inbox, Secure Notes & devices | P6 (+ P5's reminder parts) | Not Started |
| M5 | Journal | P7 | Not Started |
| M6 | Dream journal | P8 | Not Started |
| M7 | To-Do | P9 | Not Started |
| M8 | Calendar | P10 | Not Started |
| M9 | Search | P11 | Not Started |
| M10 | Analytics, trackers & counter statistic | P12 | Not Started |
| M11 | Finance A–C | P13, P14, P15 | Not Started |
| M12 | Life tracker | P16 | Not Started |
| M13 | LeetCode | P17, P18 | Not Started |
| M14 | Rankings, map & repeat counter | P19A, P19B | Not Started |
| M15 | Jobs | P20 | Not Started |
| M16 | Study | P21, P22 | Not Started |
| M17 | Workout | P23 | Not Started |
| M18 | Photos: vault, camera capture, ghost, FLAG_SECURE, playback, compare, alignment | P28A, P28B | Not Started |
| M19 | Gaia on the phone | GAIA_*_HLD passes, `GAIA_REMAINING_TESTS.md` | Not Started |
| M20 | Trash, soft delete & undo | P24 | Not Started |
| M21 | Settings, theming & data management (full Light pass) | P25 | Not Started |
| M22 | Sync, offline, lifecycle & Dev page (one device) | P26 | Not Started |
| M23 | Performance, memory, stability & release build | — | Not Started |
| M24 | Accessibility: TalkBack, font scale, contrast, targets | — | Not Started |
| FV-M | Fix verification: app changes made during this audit | FV | Not Started |
| M25 | Final review | P27 | Not Started |

Keep this table and each phase's **Status** line in sync. M1–M3 come first because every later phase leans on the shell, Back and text input working. After that the order is free, except M19, which needs a desktop beacon (see its prerequisites). Run the sync plan after M22.

---

## Phase M0 — Setup: phone, harness, background operation
- **Status:** Done (redo on Juno's OnePlus 12R, 2026-11-22, qa-129). Each item's phone result is marked "Phone:"; the first run's results stay after it as "Emulator:" (reference only). Deferred to PROGRESS.md §6b: reboot and screen off/on (pattern lock), incoming call. adb permission changes work since Juno turned on OxygenOS's "Disable permission monitoring" (20:50). Bugs: BUG-385 (Major), BUG-386 (Minor); BUG-384 reproduced.
- **Redo notes:**
  - **What carries over:** the harness scripts and how they work (vm.dart reads the app's files over adb, `find` beats UI Automator, `type`/`clip`, the guard, login retries), the BUG-384 finding, and account qa-129 (already in `phone_accounts.txt`; reuse it or sign up qa-130). Re-check each item on the phone anyway. Paths and journal mode can differ by Android version.
  - **First, without touching anything:**
    - `adb devices` → the serial (`unauthorized` → ask Juno to accept the prompt);
    - model, `ro.build.version.release`, the OxygenOS build;
    - `wm size` / `wm density` → dp width;
    - `pm list packages com.example.voyager` (if it's installed: `dumpsys package com.example.voyager` for the version and install time);
    - the lock state (`locksettings get-disabled`);
    - the default keyboard;
    - **Juno's current values for every setting the toolbox changes**: font scale, display size/density, rotation (`accelerometer_rotation`, `user_rotation`), `cmd uimode night`, airplane/Wi-Fi/data, `auto_time`, `auto_time_zone`, the timezone, `always_finish_activities`, `stay_on_while_plugged_in`, `zen_mode`, the navigation mode, the locale.

    Write them all into PROGRESS.md §1b, replacing the emulator facts (keep the emulator's `-gpu host` crash note under an "Emulator (not used)" line).
  - **Then convert the harness** (`qa/` only):
    - `phone_launch.ps1`: the hardcoded `emulator-5554` becomes the phone's serial, kept in one place;
    - adb calls: add `-s <serial>` wherever a second device (the emulator) could ever be attached;
    - `phone_session_start.ps1`: no emulator boot; wait for the phone as `device`; DND on after recording `zen_mode`; `svc power stayon usb`;
    - `phone_session_end.ps1`: restore DND and `stayon`; drop `-Shutdown` / `adb emu kill`;
    - `phone_standard.ps1`: split into "standard for testing" (session start) and "restore Juno's values" (session end), since the two differ on a real phone;
    - the toolbox's `adb emu` rows become the substitutes in the DEVICE section;
    - test images go to `/sdcard/Pictures/VoyagerQA/`.
  - **Add PROGRESS.md §6b "Deferred until the screen lock is off"** (phase, item, why). Seed it with the toolbox's reboot and screen off/on rows if a lock is set, and the incoming call.
- **Goal:** everything the later phases assume, verified once and written into PROGRESS.md (a new "§1b Phone environment" section and a phone column in the account table).
- **Checklist:**
  - [x] **Headless boot** (on the phone: **Connection** instead. `adb devices` shows the phone as `device` in the "Charging this device" USB mode, `phone.ps1 shot` gives a real frame, and the laptop's RAM/CPU with no emulator is recorded): `emulator -avd Medium_Phone_API_37.0 -no-window -no-audio -no-boot-anim` (full path in memory `android-emulator-location`), then `adb wait-for-device` and poll `getprop sys.boot_completed`. Record the boot time and the host RAM/CPU it takes. Check that a window-less emulator still renders (`phone.ps1 shot` gives a real frame) and that hardware acceleration is on (`emulator -accel-check`). → Phone: serial `f324d872` shows as `device` in "Charging this device"; `phone.ps1 shot` gives real 1264×2780 frames. Laptop with no emulator: 9.1 GB of 31.1 GB RAM free, CPU 1%. → Emulator: Boot 24–33 s; 5.4 GB RAM, ~10% CPU idle; WHPX on; window-less frames are real. **Boot with `-gpu host`**: the default software rendering crashed qemu 4 times.
  - [x] **Juno keeps the laptop:** with the emulator headless and a phase-like workload running (install, launch, 50 taps, screenshots), confirm the Windows foreground never changes and nothing steals focus. Note how the system feels under load, and whether `voy.ps1 awake on` (or `awake.ps1`) is needed to stop the laptop sleeping mid-run (the emulator pauses when the host sleeps). Also set `svc power stayon true` so the phone's own screen doesn't time out. → Phone: 50 taps + 10 shots in 47 s, free RAM 6.4 GB, CPU 1%. The foreground changed once, logged by process: Juno switching from the IDE to FreeTube, not the harness. Session start sets `stayon usb` (Juno's own Stay awake is already on). → Emulator: 50 taps + 10 shots, foreground never changed. On AC no sleep; on battery (3 min sleep) use `voy.ps1 awake on`. `stayon` set.
  - [x] **Image type:** Google Play or Google APIs? (`getprop ro.build.flavor`, `adb root`.) Record whether `adb root` works. Without root, setting the clock and timezone needs another route: try `settings put global auto_time 0` and `auto_time_zone 0`, then `cmd alarm set-time` / `service call alarm` / `setprop persist.sys.timezone`, and record what works. M4, M7, M8 and M22 need a timezone change, and ideally a clock change. → Phone: `user` build, no `adb root`, Play services 26.45 + Play Store. Timezone (`cmd alarm set-timezone`) and clock (`cmd alarm set-time <ms>` with `auto_time 0`) work without root, as on the emulator; session end restores Juno's timezone from `qa/logs/phone_juno_state.txt`. → Emulator: Google Play, `user` build, no `adb root`. Timezone: `cmd alarm set-timezone`; clock: `cmd alarm set-time <ms>` with `auto_time 0` (ms computed on the host). Both work without root.
  - [x] **Build and install:** `flutter build apk --debug` and `adb install -r`, or `flutter run -d emulator-5554` in the background. Record the time a warm build takes. Juno's own `flutter run` on Windows must be left alone (PROGRESS.md quirks): building an APK doesn't touch the Windows debug exe, but check for clashes in `build/`. → Phone: Gradle 83 s + install 9.5 s; session start 134 s including that first build. No clash with Juno's `flutter run -d windows`. → Emulator: Warm APK build 88 s, install 3 s, no clash with Juno's `flutter run -d windows`. It builds Juno's working tree: use `-Attach` when that doesn't compile.
  - [x] **VM service on the phone:** a `phone_launch.ps1` (new, in `qa/harness/`) that runs `flutter run -d emulator-5554 --debug` (or `flutter attach`) in the background, writes the VM URI to `qa/logs/vm_uri_phone.txt` and the log to `qa/logs/run-phone-<timestamp>.log`. Then make `vm.ps1` and `evalc.ps1` accept `-Profile phone` (or a `-VmUri`), so `whoami`, `find`, `shot`, `eval` and seeding through the app's repositories work on the phone as on desktop. Verify: `vm.ps1 -Profile phone whoami` reports the QA account. → Phone: `phone_launch.ps1` targets the serial in `phone_serial.txt`; `vm.ps1 -Profile phone whoami` reported qa-129. `-Attach` after process death: 6 s. → Emulator: `phone_launch.ps1` (+ `-Attach`); `vm.ps1`/`evalc.ps1 -Profile phone` with no new flag (vm.dart reads and writes the app's files over adb). `whoami` reported the QA account.
  - [x] **Locating targets:** compare `phone.ps1 ui` (UI Automator) with the VM-service `find` on three pages. Record which works. If `find` works, add `phone.ps1 tapf <text>` (find + tap through the guard). → Phone: on Journal `find` listed 16 targets in 0.9 s (tooltips included), UI Automator 6 in 2.5 s; To-Do and the More sheet the same. `find`/`tapf` stay the locator. UI Automator is still needed for system dialogs (it read the notification permission prompt; `find` only sees Flutter). → Emulator: `find` beats UI Automator (tooltips, keys; 0.4 s vs 3 s). `phone.ps1 tapf` added.
  - [x] **Typing:** `phone.ps1 text` can't send spaces (it joins arguments) or most symbols. Add a guarded `phone.ps1 type "<text with spaces>"` (escape spaces as `%s` for `input text`) and a clipboard setter by VM eval. Confirm both into a journal body. → Phone: `type` landed all 51 characters (spaces and symbols) in a journal title; `clip` pasted emoji, Chinese/Japanese and Hebrew into the body. **Phone Link copies the phone's clipboard to Juno's Windows clipboard**, so `clip` overwrites it (warning in `phone.ps1` help). → Emulator: `phone.ps1 type` and `clip` added; both confirmed into a journal body (paste through Gboard's clipboard chip).
  - [x] **DB pull:** `phone_db.ps1` (new) copies `voyager.sqlite` with its `-wal`/`-shm` through `run-as` into `qa/logs/phone_db/` and prints a read-only `sqlite3` URI. Verify that a row typed 1 s ago shows up. → Phone: pull 1.3 s, still `journal_mode=delete`; the row typed just before was in the copy. → Emulator: `phone_db.ps1`. No WAL on Android (`journal_mode=delete`). A row typed 1 s before was in the pull.
  - [x] **Paths:** record the phone's data directory, media directory, backups directory (AUTO_BACKUP_HLD §8.1 says `files/backups`), drafts/prefs files, session checkpoints, Firestore cache and the app error log, as in PROGRESS.md §1 Storage. → Phone: same paths as the emulator (PROGRESS.md §1b Storage), re-checked. → Emulator: PROGRESS.md §1b Storage on the phone.
  - [x] **Logs:** `adb logcat -c` at session start, then a background `adb logcat -v time` to `qa/logs/logcat-<timestamp>.txt`. Grep patterns for FlutterErrors, `FATAL EXCEPTION`, `ANR in com.example.voyager`. → Phone: **FlutterErrors don't reach logcat on this phone**: they are only in the run log and `app_flutter/voyager_errors.log`, where BUG-385/386 showed up. The full logcat ran ~2 MB a minute, so the recorder is now `*:E flutter:V`. → Emulator: In `phone_session_start.ps1`; patterns matched real errors (BUG-384 came from the app error log).
  - [x] **Sign-in for QA:** a guarded `phone_login.ps1 -Email … [-SignUp]` (types into the login page through `phone.ps1`, refusing a non-QA e-mail), then adds the account's UID to `phone_accounts.txt` and runs `phone.ps1 check`. → Phone: `phone_login.ps1` signed qa-129 in (twice, the second at 20:43). → Emulator: `phone_login.ps1` (qa-129 signed up, then signed in through it).
  - [x] **Session start/end scripts:** `phone_session_start.ps1` and `phone_session_end.ps1`, matching the desktop ones: check, pull and assert outbox 0 before any `pm clear`, print `SIGNED-OUT` at the end. → Phone: both end to end twice: start 134 s with the first build, end 8 s with outbox 0. **OxygenOS refused `pm clear`** then, so session end uninstalled (it works since Juno's switch, 20:56); `SIGNED-OUT`, and Juno's DND (0), Stay awake (15) and timezone were back both times. → Emulator: Both run end to end several times (start 51 s, end 8 s).
  - [x] **Device-state toolbox:** verify each command once and record it, with its undo, in PROGRESS.md §1b: → Phone: run once each: rotation (landscape is 794 dp, so the expanded shell with the rail), size/density/font, dark mode, airplane and Wi-Fi/data (network back ~2 s after), Doze, App Standby (backgrounded), kill, force-stop, "Don't keep activities", notification and alarm reads, test images, timezone, clock, DND, `stayon`. **Permissions:** OxygenOS refused `pm grant/revoke`, `appops set` and `pm clear` until Juno turned on "Disable permission monitoring" at 20:50 (2026-11-22); since then `pm grant/revoke` (POST_NOTIFICATIONS, CAMERA, ACCESS_FINE/COARSE_LOCATION), `appops set SCHEDULE_EXACT_ALARM deny|allow`, `appops reset` and `pm clear` all work, read back by `dumpsys package` / `appops get`. Two catches: a revoke kills the app (as on any Android; `phone.ps1 launch` + `phone_launch.ps1 -Attach` after), and `appops set` on CAMERA / COARSE_LOCATION returns ok but stays `allow` (tied to the runtime permission): use `pm revoke` for those. The app's own system prompt also works (UI Automator reads it, `phone.ps1` allows the tap). Reboot and screen off/on are in §6b (pattern lock); location and camera are the real ones (M14, M18). → Emulator: Every row run once; commands, undo and caveats in PROGRESS.md §1b (App Standby needs the app backgrounded; `geo fix` unconfirmed until an app asks for location, M14).
    - rotation: `settings put system accelerometer_rotation 0` + `user_rotation 1` (undo `user_rotation 0`);
    - size, density and font scale (`wm size` / `wm density` / `font_scale`, undo `reset` / `1.0`);
    - system dark mode: `cmd uimode night yes|no`;
    - airplane mode, `svc wifi`, `svc data`;
    - Doze: `dumpsys deviceidle force-idle` / `unforce`, `dumpsys battery unplug` / `reset`;
    - App Standby: `am set-inactive com.example.voyager true`;
    - process death: `am kill`. Force-stop: `am force-stop`;
    - "Don't keep activities": `settings put global always_finish_activities 1` (undo 0);
    - notifications: `dumpsys notification --noredact` (read-only check of what's posted), `cmd notification` to expand the shade;
    - alarms: `dumpsys alarm` filtered on the package (see what's scheduled);
    - permissions: `pm grant|revoke com.example.voyager android.permission.POST_NOTIFICATIONS`, `appops set com.example.voyager SCHEDULE_EXACT_ALARM allow|deny`, the same for CAMERA and location;
    - location: (emulator: `adb emu geo fix <lon> <lat>`) phone: the real GPS; see DEVICE for what not to record;
    - camera: the phone's real front and back cameras;
    - test images: `adb push qa/data/img01.png /sdcard/Pictures/VoyagerQA/`, then a media scan broadcast so the picker sees them;
    - reboot: `adb reboot` + boot wait (deferred while a screen lock is set);
    - a phone call: (emulator: `adb emu gsm call` / `gsm cancel`) phone: none, goes on §6b's list;
    - Do Not Disturb: `cmd notification set_dnd on|off` (+ `settings get global zen_mode` to record Juno's);
    - screen kept on: `svc power stayon usb|false`.
  - [x] **FCM:** confirm the image has Google Play services, so Gaia's push (M19) can arrive. The 2026-10-31 Gaia passes got an FCM token on this AVD (qa-124 notes). → Phone: the app got a 142-character FCM token. → Emulator: Play services present; the app got an FCM token.
  - [x] **Desktop beside the phone:** confirm a desktop QA profile (`-Profile qa`) can run at the same time as the emulator without starving it. The sync plan needs both. → Phone: not re-run: the phone uses no laptop RAM or CPU, and RAM was the only limit found on the emulator. → Emulator: Profile `qa` ran beside it fine; RAM is the limit (stop the Gradle daemon, shut the emulator down between sessions).
  - [x] Write the §0.4 rows into PROGRESS.md §6, and replace its "Android / compact layout: Out of scope" row with a pointer to this plan. → Emulator: Done.
- **Skipped/blocked:** reboot and screen off/on (lock), incoming call: in PROGRESS.md §6b. "Desktop beside the phone" not re-run (no laptop load).

---

## Phase M1 — Install, first run, auth & account lifecycle
- **Status:** Done (2026-11-24 17:01–18:15, Juno's OnePlus 12R, debug APK of `33a2fd84` + uncommitted `lib/features/gaia/companion/gaia_text_field_studies.dart`). Accounts qa-130 (new; password now `qavoyager2027`) and qa-129 (reused for the account switch). Bugs: BUG-387 (Major), BUG-388, BUG-389, BUG-390, BUG-391 (Minor); BUG-384 and BUG-386 reproduced. At 17:23 Juno's working tree stopped compiling (Gaia `temporaryAt`), so `flutter attach` couldn't connect after the first force-stop: from then on input went through `phone.ps1` with UI Automator (`phone.ps1 ui`) for targets and `voyager_errors.log` for errors; no VM `find`/`eval`. Nothing new deferred to §6b.
- **Desktop reference:** P1 (BUG-003, BUG-004, BUG-005, BUG-010, BUG-011, BUG-012 were found there and in P2; re-check the fixed ones from the phone).
- **Scope:** a fresh install, the login page in compact, sign-up/sign-in and their errors, every page's first visit on the phone, the startup page, sign-out, change password, relaunch signed in vs signed out, reinstall and uninstall behaviour. **Deferred:** shell mechanics → M2; Settings in general → M21.
- **HLD docs:** PLAN.md, PRODUCT.md, SESSION_RESUME_HLD.md, GAPS.md, AUTO_BACKUP_HLD.md §8 (uninstall and Auto Backup)
- **Flows:**
  - [x] Fresh install (`pm clear`, or uninstall + install): splash/launch theme → login page. **No permission prompt** should appear before the user does something that needs one. Record exactly when the app first asks for notifications. → Splash: the Voyager icon on black, then the dark login page (after uninstall + install too). No prompt at first launch, after sign-up, or on the first visit to every page; `POST_NOTIFICATIONS` stayed `granted=false` all session. The only notification UI is Settings → Account "Notifications are off … Open settings". The app never asked during M1 (M4 owns the first ask).
  - [x] Login page at 411 dp and 360 dp: card fits, nothing under the status bar. Tapping the e-mail field raises the keyboard and the password field and Sign in button stay reachable (scroll or resize). The e-mail field is **not** autofocused on Android (`login_page.dart:161`). Sign in ↔ Create account keeps the typed values. → Not autofocused ✓; the toggle keeps both values ✓. At 361 dp without the keyboard it fits. **BUG-387:** the card doesn't scroll: with the keyboard up and an error line it overflows by 23 px (Create account clipped), at 360×640 dp by 165 px (Sign in, Google, Create account and the error line under the keyboard), at font 2.0 by 96 px, and in landscape by 87 px with no keyboard; with the keyboard up the card slides under the status bar.
  - [x] IME: the e-mail field offers the e-mail keyboard and Next moves to the password; the password field is obscured and Done/Go submits. Gboard's password-manager suggestions don't break the field. → **BUG-388:** e-mail field is plain text with autocorrect (`0x8001`) and its ✓ is Done, which submits ("Email and password are required.") and jumps to Password. Password: obscured, `0x80081`, ✓ submits ✓. Gboard offered no password-manager suggestions.
  - [x] Sign-up (fresh qa account) → lands on the first page. The same error messages as desktop P1 (empty, bad e-mail, weak password, existing account); wrong password and unknown e-mail give the shared failure line; a padded e-mail is trimmed. → qa-130 signed up with "  voyager-qa-130@example.com  " (trimmed; `whoami` = qa-130) → Journal. Errors identical to P1. Wrong password and unknown e-mail both give **"Incorrect email or password."** on Android (desktop said "Sign in failed. Check your email and password, then try again."; Android's Firebase returns `invalid-credential` for both, `firebase_auth_errors.dart`), still one shared line.
  - [x] Double-tap Sign in → one sign-in. Turn on airplane mode, then sign in → a clear offline error, no hang. Then airplane off → retry works. → Double tap on Sign up and on Sign in: one attempt each (one account, one discard dialog). Airplane: "Network error. Check your connection and try again." within 13 s, no spinner left; airplane off → the retry signed in.
  - [x] Continue with Google is **shown** (check only; MANUAL-ONLY to tap). Forgot password with an empty e-mail → the validation message. → Shown; "Enter your email to reset your password." ✓.
  - [x] First visit to every page through the bottom bar and More: no crash, no FlutterError, sensible empty states. Same list as desktop P1, plus **Photos** and **Gaia**. → All 17 (Journal, Dreams, To-Do, Calendar, Search, Analytics, Finance, Life, LeetCode, Rankings, Jobs, Study, Workout, Photos, Gaia, Demo, Settings) opened without a crash; empty states sensible ("No dreams logged yet.", "Create your first list", "No categories yet", "Nothing here yet", Workout's starter exercises, "No chats yet…"). FlutterErrors: **BUG-390** (Calendar 164 px, LeetCode 76 px, Jobs 15 px right overflows); **BUG-391** (Life's first-run labels overlap); Search autofocuses and raises the keyboard, which fires BUG-386. Journal's header on the fresh account shows only a chevron until the first entry (then "Journal 1"; the M0 lead).
  - [x] Startup page First / Last seen / Custom on the phone: after force-stop, after process death, after sign-in. → First → Journal after sign-up and after qa-129's sign-in; Last seen → Finance after force-stop, Rankings after process death; Custom (To-Do) → To-Do after a force-stop from Finance and after qa-130's sign-in on a device holding qa-129 (BUG-011 holds). DB `startup_page_mode`/`custom_startup_page`/`last_seen_nav_page` matched each time.
  - [x] Relaunch signed in skips the login page, with no flash of it (`auth.isSettling` wait). Relaunch after sign-out shows it. → Force-stop and process-death relaunches: splash → background only → the page (screenshot bursts at ~1–3 s; `screenrecord` is refused on this phone). After sign-out, relaunch shows the login page.
  - [x] Sign out (Settings → Account) → login page. Then sign in to a **different** QA account on the same install: none of the first account's data shows, and none of it uploads to the second (desktop BUG-005's class). → Sign out: no confirmation, straight to the login page; qa-130's rows stay in the DB until the next sign-in. Signing in as qa-129 (with one signed-out change queued, BUG-389) raised "Discard unsynced changes? … 1 change(s) from the account signed in before…"; Discard and sign in → DB held only qa-129's M0 entry, no qa-130 entry/task/word, outbox 0. Signing back in as qa-130 pulled its entry and task back.
  - [x] Change password on the phone (record the new one in PROGRESS.md at once): the same validation cases as P1. → "Fill in both passwords.", "Password is too weak. Use at least 6 characters.", "New passwords do not match." as P1; wrong current gives **"Current password is incorrect."** (Android wording). Success via the ✓ in Confirm closed the dialog; qa-130 = `qavoyager2027` (PROGRESS.md §2), old password then rejected. Back with the dialog's keyboard up hides the keyboard first, the dialog stays.
  - [x] Sign in while the app is backgrounded halfway (Home during the spinner, back after 10 s): ends signed in or with a clear error, never stuck. → Signed in, on To-Do (Custom), qa-130's data pulled.
  - [x] Process death on the login page with typed text → relaunch: the fields may be empty, but no crash. → Fields empty, no crash, no FATAL in logcat.
  - [x] Reinstall over the top (`adb install -r`): still signed in, data intact (and `phone.ps1 check` first, per the rules). Uninstall + install: signed out, local data and **local backups gone** (AUTO_BACKUP_HLD §8.1), and the cloud copy comes back on sign-in. → `install -r`: guard ok (qa-130), signed in, entry/task intact, outbox 0. Uninstall + install: no `files/` or `shared_prefs/` at all (backups for both UIDs gone), login page, guard "signed out"; sign-in brought back the entry, task, Light theme and Custom → To-Do; a fresh `files/backups/<qa-130>/` only.
  - [x] First-run defaults on the phone: same values as desktop P1 (dark, scatter, accent). → `dark`, scatter 1 (lit 0.025), wave 0, scale 15, intensity 0.67, spread 1.1, focal (0.1, 0.5), floor 0.8, accent #7c9eff, 160 petals, fall 38.86, 2 minor colours: identical.
- **Five-dimension sweep:**
  - D1: the flows above, by touch.
  - D2: entry and task in SQLite at once, outbox 0 throughout; survived force-stop, process death, `install -r` and a cold re-login (uninstall + install); account switch left no foreign rows. No desktop profile holds qa-130, so no desktop spot-check.
  - D3: login page at 361 dp, 360×640 dp, landscape, font 2.0, with and without the keyboard (BUG-387); every page's first visit at 361 dp (BUG-390, BUG-391); To-Do at tablet size (expanded shell with the rail) and font 1.3: fine. Light spot-check: Settings, Journal, login page legible. Cutout and status bar: clear except BUG-387's card slide.
  - D4: Back hides the keyboard before closing a dialog; Back on the login page leaves the app (only page). Hardware keys: Tab (`keyevent 61`) moves Email → Password, Enter submits. The login buttons are 40 dp tall (140 px) by their semantics bounds: for M24's list. Settings' palette help still says "right-click one to replace every use of it" (M21).
  - D5: empty/invalid/weak/existing, 300-char e-mail (field scrolls; "Enter a valid email address."), double taps, airplane, Home mid-sign-in, process death, rotation with typed text (kept). Paste into the password field: the long-press menu has no Paste (BUG-389); Gboard's clipboard chip was left alone (it holds Juno's synced clipboard). Screen off/on and an incoming call stay on §6b.
- **Test data:** qa-130: 1 journal entry, 1 task, startup Custom → To-Do, Dark + Scatter (Light was tried and switched back). qa-129 unchanged.
- **Harness notes:** OxygenOS blacks out `screencap` while a password field has focus (use the VM `shot`, or hide the keyboard); `screenrecord` can't write its file; a swipe that starts on a palette swatch drags it instead of scrolling (swipe at x≈1235); Back on the login page leaves the app, so only hide the keyboard after `dumpsys input_method` shows `mInputShown=true`.
- **Skipped/blocked:** VM `find`/`eval` after 17:23 (working tree didn't compile); `phone.ps1 clip` paste test (needs the VM).

---

## Phase M2 — Phone shell, navigation, Back, rotation & sheets
- **Status:** Done (2026-11-24 19:31–20:37, Juno's OnePlus 12R, debug build of `972fd4d8` + uncommitted Gaia work in `lib/features/gaia/`; qa-130 reused)
- **Desktop reference:** P2. Desktop-only items there (window, tray, Ctrl+Tab, second instance) are n/a on the phone; this phase checks they're absent rather than broken.
- **Scope:** the compact shell (`_CompactShell`, `_CompactStatusStrip`, `ShellBottomNav`, More sheet), the system Back chain, predictive Back, page state across switches, the switch between compact and expanded shells (rotation, tablet size), sheets and dialogs on the phone, system insets, overlays (workout island, FPS counter, cache status), the weather button and forecast sheet, connectivity and sync indicators, and the desktop-only pieces that must be absent.
- **HLD docs:** DESIGN.md, BACKGROUND.md, VOYAGER_SHEET_DISMISS_HLD.md, SCOPE_SWITCHER_HLD.md, GLASS_BUTTON.md
- **Flows:**
  - [x] **Bottom bar** → Journal, Dreams, To-Do, Calendar + More; the selected item gets the accent outline and label; every item navigates. More opens a full-height sheet (handle, scrolls) listing Search … Settings in nav order; a row navigates and closes it; while on an overflow page the bar shows **More** selected.
  - [x] Nav order and hidden pages → hiding Dreams and dragging Calendar to the top changed the bar and the More sheet at once. With 3 pages visible (by eval: Journal, To-Do, Settings) More disappears and Settings sits in the bar; with only Settings the bar has one item, and a relaunch with the custom startup page (To-Do) hidden opens Settings. **BUG-393**: the dialog's list can't be scrolled by touch (every swipe reorders), so Jobs … Settings can't be reached; labels break mid-word. (Dev is hidden by default; restored to the defaults afterwards.)
  - [x] **Back chain** → **BUG-392 (Major)**: Back on any section but Journal (Dreams, Settings) and Back in the journal editor *quit the app* (`wm_finish_activity … app-request`); the shell's `PopScope` sits on the outer `ShellRoute`'s navigator, so go_router never reaches `_handleSystemBack`. A modal sheet (More, transaction editor) and the inbox popover do close on Back first. The journal title had autosaved. Reopening restarts on the startup page, not the page left. Pushed routes (LeetCode/Study sessions) weren't reached (no data; M13/M16).
  - [~] **Predictive Back** → the edge back-swipe (`input swipe` from x=3) closes the More sheet like Back. A cancelled half-swipe can't be scripted with `input swipe` (it always lifts at the end): not run.
  - [x] Page state across bottom-bar switches → a scrolled To-Do list (23 tasks), its composer draft, and the journal editor with an unsaved body all survived Journal ↔ Calendar ↔ To-Do switches. (The forecast is a dialog that closes, so there's no selected day to keep: BUG-396.)
  - [x] **Status strip** → clock: sampled every ~2 s across three minute boundaries, it flipped within 2 s each time (one earlier 7:41-vs-7:42 reading after a dialog didn't reproduce with the More sheet). Weather icon and 4° after setting Chicago, US; the forecast opens as a centred dialog, picking a day redraws the chart, a drag doesn't close it (**BUG-396**). Offline badge (red Wi-Fi) 71 s after airplane on (two failed probes, as the Dev text says), cleared 18 s after airplane off. The sync activity icon wasn't caught during an upload (gone before `find` ran).
  - [x] **Inbox bell** → opens the inbox as a floating card under the strip (reminder field, Scheduled +, Log stats); Back closes it. Details in M4.
  - [x] **Rotation** → landscape (`user_rotation 1`; auto-rotate had to be turned off first) switches to the rail at 794 dp; To-Do's scroll position and draft and the journal editor survive and come back on rotating back. The rail fits only ~2 destinations at 361 dp tall and scrolls by touch. In landscape the journal editor's body box disappears with a 2.9 px overflow (noted on **BUG-385**). The More sheet stays open across rotation (over the rail). With the keyboard up, rotation keeps the text but drops focus and closes the keyboard. 10 rotations 400 ms apart: no crash, state intact.
  - [x] **Tablet size** (1600×2560 @ 320) → expanded shell with the full rail; To-Do, Journal (split view) and Calendar render their desktop layouts fine. Touch routes: `ContextMenuRegion` opens only on right-click, so every right-click menu is unreachable by touch at any size: **BUG-395 (Major)** (a task can't be deleted, moved or sent to the bottom; Journal's Statistics / Change Journal). Long-press on a task opens the edit panel; on a journal card, the entry.
  - [x] **Sheets** → More: handle, drags down to close, Back closes. Finance transaction editor: no handle, a drag doesn't move it, Back/✕ close it and the typed amount is kept for the next open (**BUG-400**, HLD says drag + handle on Android). LeetCode track form, Study card editor/import and workout target editor not reached (no data): M13/M16/M17.
  - [x] **Dialogs** at 361 dp → Navigation pages (BUG-393), Manage lists, forecast (BUG-396) fit; Back closes them.
  - [~] **System insets** → status bar, punch-hole and gesture bar are clear in portrait and landscape; the bottom bar sits on the gesture inset with no gap. 3-button navigation: `cmd overlay enable-exclusive … navbar.threebutton` set `navigation_mode 0` but OxygenOS drew no buttons, and the switch recreated the activity (the app restarted and an unsaved composer draft was lost, as on any config change Flutter doesn't handle). Restored to gestural; a real 3-button check needs Juno's Settings → System → Gestures.
  - [~] **Workout island** → "Start today" needs a planned day ("Nothing is planned for that day yet"): moved to M17.
  - [x] Dev page → FPS HUD and cache-status card both ignore the compact insets (**BUG-394**, Cosmetic): HUD over the status bar and bell (taps pass through), cache card over the bottom bar (blocks To-Do) and off the right edge.
  - [x] **Desktop-only pieces absent** → Editing shows "Global hotkeys: Available on Windows only", no hotkey rows, no Start with Windows; Data has no folder backups or heat watch; no tray. But the "Caps Lock indicator" switch is still listed (**BUG-399**, Cosmetic). Ctrl+Tab and Ctrl+/ (`input keycombination 113 61` / `113 76`) did nothing.
  - [x] Rapid bottom-bar tapping → 20 taps through the guard (~0.5 s apart; `phone.ps1` can't do 60 ms): no errors; the final page was To-Do, but the order of concurrent guarded taps isn't guaranteed, so "ends on the last tapped page" isn't proven.
  - [ ] Recents thumbnail → not run: the Recents screen shows Juno's other apps.
- **Five-dimension sweep:**
  - D1: the flows above by touch; BUG-392 and BUG-395 are the functional gaps.
  - D2: 22 tasks typed through the composer + "M2 add check", the journal body edit, weather location, nav-order/hidden-page changes (restored) all in SQLite; outbox 0 at every check; process death on Finance → relaunch on To-Do (custom startup) with 24 tasks, both entries, Dark, `last_seen_nav_page=/finance`. No desktop profile holds qa-130.
  - D3: 361 dp, 360×640 dp (fine), landscape (rail; BUG-385 note), tablet (fine), font 1.3 (fine), font 2.0 (**BUG-397**), keyboard up (**BUG-398**: the bar stays above the keyboard and hid "Save location"), insets (fine; 3-button not drawn). Light spot-check of To-Do and the More sheet: legible, status icons dark.
  - D4: Back everywhere (BUG-392); touch-only routes (BUG-395, BUG-393); sheet drag (BUG-400); hardware Ctrl+Tab / Ctrl+/ harmless; edge swipe = Back.
  - D5: airplane mode (badge on/off), rotation ×10, process death mid-navigation, rotation with the keyboard up, nav-mode config change (activity recreated). Back spam from a deep route wasn't run separately: with BUG-392 the second Back already leaves the app.
- **Test data:** qa-130: 23 more tasks ("M2 task 01…22", "M2 add check") in To-do, entry "M2 back draft" (body "unsaved body M2"), weather location Chicago, Illinois, US; nav order/hidden pages and Dev toggles back to defaults.
- **Harness notes:** auto-rotate was on at session start (`accelerometer_rotation 1`), so `user_rotation` did nothing until it was set to 0. `phone.ps1 key` has no key-combination form; `key '0; input keycombination 113 61'` goes through its guard. The nav-pages tile scrolls off the Appearance tab; `find` lists offstage pages' texts too (e.g. To-Do rows on Settings).
- **Skipped/blocked:** Recents thumbnail (privacy), cancelled predictive-back swipe (not scriptable), workout island (M17), pushed-route Back and the other HLD editors (M13/M16/M17), a real 3-button bar (OxygenOS).

---

## Phase M3 — Text input on the phone
- **Status:** Not Started
- **Desktop reference:** P3 (Vim) and P4 (autocorrect, dictionary, flagged words, snippets, emphasis, lists, Ctrl+Enter, images, scroll insets).
- **Scope:** every text-editing helper driven by the **soft keyboard**, which no desktop phase did, plus a hardware-keyboard pass of Vim. On Android the app's own autocorrect and snippet auto-expansion act on soft-keyboard input (§0.1), on top of Gboard's own corrections and suggestions.
- **HLD docs:** AUTOCORRECT.md, DICTIONARY.md, FLAGGED_WORDS.md, SNIPPET.md (§7 mobile), RIGHT_CLICK_SNIPPET.md, EMPHASIS_FORMATTING.md, MULTILINE_FIELD_SCROLL_INSETS.md, MEDIA.md, VIM.md, UNDO.md, TEXTBOX_WIDGET.md
- **Flows:**
  - [ ] **Autocorrect with Gboard:** type `wtih ` by soft keyboard (Gboard's own autocorrect on, then off). Who corrects, once or twice? Does the app's flash show? Does Backspace revert and suppress? The same for a word Gboard knows but the app's dictionary flags, and the reverse. A Gboard suggestion-strip pick or a swipe-typed word that the app then "corrects" is a bug.
  - [ ] Gboard's composing region (the underlined word in progress) with app autocorrect: no lost or doubled letters, the caret stays put. Try in the journal body, a To-Do title and a dialog field.
  - [ ] **Spell suggestions on touch:** desktop reaches them by right-click. Find the phone's route (long-press, the selection toolbar, a tap on the squiggle) and record it. If there is none, log it. The same for **Add to dictionary**, **Flag as misspelling**, and the right-click **Add snippet** menu.
  - [ ] Settings → Dictionary and Text snippets dialogs at 360 dp with the keyboard up: add, search, edit, delete.
  - [ ] **Snippets on the soft keyboard:** the Space expand key works by soft keyboard; the **Tab** key doesn't exist there, so with expand key = Tab, is manual expansion reachable at all? Auto-expanding snippets work with soft-keyboard input (the hardware requirement is dropped on Android). Tabstops (`$0`, `$1`): how does the user advance without Tab? Undo of an expansion.
  - [ ] **Emphasis and lists:** `**bold**`, `_italic_`, highlights and nesting render and reveal under the caret; Enter on the soft keyboard continues `-`, `*`, `1.` lists and exits on an empty item. Indent/outdent needs Tab/Shift+Tab: record whether the phone has any way to do it.
  - [ ] **Undo/redo on the phone:** no Ctrl+Z on a soft keyboard. Find the route (Gboard's undo, a toolbar button, shake?) and record it. With a hardware keyboard, Ctrl+Z puts the caret at the change (`99bd8d07`).
  - [ ] **Selection:** long-press selects a word, the handles drag, the toolbar's Cut / Copy / Paste / Select all work, and the emphasis markers don't confuse the selection.
  - [ ] **Paste** (long-press → Paste) of: plain text, 5,000 chars, emoji/CJK/RTL, and text with markers.
  - [ ] **Images in text** (journal, dreams, study card faces, rankings): every Android intake route. That's the picker/gallery button if there is one, clipboard paste of an image (Gboard clipboard, or set by VM eval), and **Gboard's image/GIF insert** (rich content insertion): accepted or cleanly refused? The lightbox: swipe between images, pinch-zoom, Back closes it, Remove asks first. Oversize image → the toast. Images land in `media_assets_table` and upload (native Storage, §0.1).
  - [ ] **Multi-line scroll insets with the keyboard up:** a long journal body scrolled to the bottom, the caret on the last line, the keyboard up: the caret line stays visible (desktop BUG-029's strip, compare).
  - [ ] **Vim, hardware keyboard:** turn on Settings → Vim keybindings, type on the emulator's host keyboard: the Normal badge, `i a o`, `dd`, `u`, `/search`, Esc from Insert. Then **with the soft keyboard**, Vim ON: can a soft-keyboard user get stuck in Normal (no Esc key)? Record what Gboard sends and whether typing still works. This is likely a real hazard.
  - [ ] Ctrl+Enter submit with the hardware keyboard on a form (calendar event, finance transaction): works as on desktop.
  - [ ] Caps Lock: no mark on Android (by design, CAPS_LOCK.md §2.2).
- **Five-dimension sweep:** D3 the dictionary/snippet dialogs at every size; D4 is the phase itself; D5 rapid typing bursts by `input text`, a paste of 50,000 chars into a journal body (time it, watch for an ANR), rotation mid-composition, process death mid-typing (what's autosaved?).
- **Skipped/blocked:** voice typing (needs a microphone; real-device pass).

---

## Phase M4 — Notifications, reminders, inbox, Secure Notes & devices
- **Status:** Not Started
- **Desktop reference:** P6 (and P5's quick-reminder floater, which has no phone equivalent: reminders are made from Settings, the entity bells and the inbox). FV re-checked BUG-039, BUG-040, BUG-041. Secure Notes were tested on desktop in the 2026-10 multi-device sessions (qa-096).
- **Scope:** Android notifications end to end. This is the largest platform difference in the app: on Windows the app raises due alerts itself while running; on Android it **schedules OS alarms** that fire with the app closed (`reminder_os_notifier.dart`, manifest receivers). Also the inbox on a phone, pinned notes, Secure Notes with `FLAG_SECURE` and the secure clipboard, entity bells, scheduled rules, the sticky stack in compact, Settings → Devices.
- **HLD docs:** SCHEDULED_REMINDERS_HLD.md (its Android sections), UNIFIED_NOTIFICATIONS.md, INBOX_POPOVER_HLD.md, INBOX_HIDDEN_RESTORE_HLD.md, SECURE_NOTES_HLD.md
- **Method:** verify what's posted with `dumpsys notification --noredact` and what's scheduled with `dumpsys alarm`, plus `reminder_delivery_logs_table` in the pulled DB. Use rules a few minutes ahead and record fire times to the second.
- **Flows:**
  - [ ] **Permission (Android 13+):** when is POST_NOTIFICATIONS requested (first rule? first bell? Settings → Devices?). Deny it → the Devices permission row says so and offers to open system settings (`openSystemSettings`) → grant there → back in the app, the row updates on resume. Revoke with `pm revoke` while rules exist: what does the app show?
  - [ ] **Exact alarms:** with SCHEDULE_EXACT_ALARM allowed, a rule fires on time. With it denied (`appops … deny`), alarms fall back to inexact (`inexactAllowWhileIdle`): record the delay. Does the UI tell the user?
  - [ ] **A scheduled rule fires** (title + note in the notification) in each state:
    - app in the foreground (is there an in-app sticky as well? `raisesDueAlertsInApp` is false on Android; record what shows);
    - app in the background;
    - **process killed** (`am kill`);
    - **force-stopped** (Android drops alarms on force-stop; record it, since that's OS behaviour);
    - after a **reboot** (boot receiver re-arms);
    - after an **app update** (`adb install -r`, MY_PACKAGE_REPLACED);
    - in **Doze** (`force-idle`; allow-while-idle);
    - screen off.
  - [ ] **A rule made on another device rings with the phone's app closed** (Juno, 2026-11-22: not ringing is a bug). Checked properly with two devices in `MOBILE_SYNC_TEST_PLAN.md` MS-8.1, MS-8.5 and MS-8.7. Here, for one device: create a rule from the desktop through any QA profile on the same account while the phone's app is killed, and see whether it rings.
  - [ ] **Tap a notification:** cold start (app killed) → the app opens on that reminder's sticky/entity (`launchSourceKey`); warm (app backgrounded) → same (`taps` stream). For an entity bell: the to-do opens in To-Do with its panel; the event in Calendar.
  - [ ] **Acknowledge / Snooze / Tomorrow** from the in-app sticky: the OS notification is **withdrawn** on Android (`dismiss` cancels; on Windows it was a no-op). Snooze 10 min fires again at +10:00 with the app killed in between.
  - [ ] Once / Daily / Weekly rules: CRUD on the phone at 360 dp, the time chip picker by touch, device chips (this phone is listed), validation messages. Editing a rule re-schedules the alarm (`dumpsys alarm` shows the new time); deleting it cancels the alarm. A past once-rule (desktop BUG-039).
  - [ ] **Entity bells:** a to-do due time with a bell, an event with "15 minutes before": the alarm is scheduled; changing the due time moves it; completing the to-do or deleting the event cancels the notification and the alarm.
  - [ ] **Timezone change** with rules pending, app closed: the alarm keeps its wall-clock time (`VoyagerTimeZoneChangedReceiver`; `42b6efda`). Then open the app: due labels and urgency are right. Needs M0's timezone route.
  - [ ] DST crossing, if the clock can be set (desktop BUG-040).
  - [ ] 22 rules at the same minute: all post (Android may group them), the sticky stack shows "+N more" in compact, rapid Acknowledge taps.
  - [ ] **Inbox on the phone:** opens from the strip's bell; sections, the urgency dot, "N items need attention"; dismiss buttons always visible (48 dp, `notification_inbox_popover.dart:3551`), the hidden footer and Restore, pinned-note add/edit/delete with the keyboard up, the Undo toast clears the bottom bar. A due-today task deep-links from the inbox. The global inbox opens Analytics where it should (`c8607d8c`).
  - [ ] **Secure Notes:** set up / unlock the vault in the inbox; while unlocked, `adb exec-out screencap` and the Recents thumbnail are **blank** (`FLAG_SECURE`), and they're normal again after locking. Copying a secure note uses the secure clipboard (`secure_clipboard.dart`): is the copied text flagged sensitive (Android 13+ hides it in the clipboard preview) and cleared after its timeout? The vault locks on Home / process death / timeout per SECURE_NOTES_HLD; closing the inbox locks unless Photos is the visible page. Wrong password, change password, reset vault.
  - [ ] **Settings → Devices:** this phone listed with platform Android, "· This device", last seen, the permission row; rename; a stale row after `pm clear` + sign-in (by design a second row, desktop P6); remove it.
  - [ ] The scheduled-reminders section's row actions are always visible on Android (`scheduled_reminders_section.dart:439`).
- **Failure cases:** airplane mode at fire time (the alarm is local, so it still fires); a rule edited offline; 200 rules (does scheduling slow startup? `cancelAllPendingNotifications` + reschedule on each change); notification channel turned off in system settings.
- **Five-dimension sweep:** as above; D3 the sticky stack and inbox at every size and with font scale 2.0.
- **Skipped/blocked:** the real-device pass covers OEM battery killers (Samsung, Xiaomi), which the emulator can't show.

---

## Phases M5–M17 — the pages

Each page phase follows the same pattern. **Part A:** run the desktop phase's main flows (its "Flows" list in `TEST_PLAN.md`) on the phone, at the standard size, by touch. Tick them in groups, noting only what differs. **Part B:** the phone-specific checks listed below. **Part C:** re-check that phase's Blocker/Major bugs that are marked fixed, from the phone (list them from BUGS.md at session start; note each result on its BUGS.md entry). Then the five-dimension sweep, where D3 always covers small phone, landscape (the expanded shell), tablet and font scale 2.0.

Every page phase also checks these, so they're not repeated below:
- every hover-only or right-click-only action on the page has a touch route (long-press, a visible button, a menu);
- every sheet drags to close and Back closes it; a form's draft survives Back where it does on desktop (Esc);
- autosave on **Home** and on **process death** mid-edit;
- the page in airplane mode: writes queue and drain after;
- the page's Ctrl+F search or keyboard shortcuts: their touch equivalent, if any;
- the Light-theme spot-check.

## Phase M5 — Journal
- **Status:** Not Started
- **Desktop reference:** P7 (and FV items for BUG-046 … BUG-059; BUG-220 and BUG-229 from the multi-device run touch the journal too).
- **HLD docs:** JOURNAL_DATA_LOSS_POSTMORTEM.md, SAVING.md, ON_THIS_DAY_HLD.md, SESSION_RESUME_HLD.md, UNDO.md, DRAFT.md, SOFT_DELETE_TOAST.md
- **Part B:**
  - [ ] **Compact list ↔ editor:** tap an entry → editor alone; Back (and the predictive back swipe) returns to the list (Back interceptor), with the entry saved; New entry opens the editor; the list scroll position is kept when returning.
  - [ ] Rotation with the editor open: landscape shows list + editor side by side (expanded); rotate back → still in the editor, with the caret and unsaved text.
  - [ ] **Autosave under Android lifecycle:** type, then within 400 ms: Home; the Recents switch; screen off; process death (`am kill` right after Home); force-stop. What's lost in each (desktop: only a hard kill inside the debounce lost text)? The `inactive`/`paused` flush (`_flushAllPendingEdits`) should save on Home.
  - [ ] Mood, weather, date/time picker and tags by touch at 360 dp; the date picker's month header; the time spinner by drag.
  - [ ] Journal manager, journal settings, colour picker and quotes (Edit quote, Browse quotes) as phone sheets.
  - [ ] **On This Day** overlay in compact: placement (desktop BUG-055 covered controls at min size), swipe/page between matches, Open, ✕. The 31-day fixed period (`e115d85a`).
  - [ ] **Default journal switching** (`79f5c468`): set a default, then check that a new entry, the startup page and "All journals" follow it.
  - [ ] The journal's equivalent of the desktop journal hotkey (`cbdde752`): is there a phone route to "today's entry"? Record it.
  - [ ] Delete an entry by touch → Undo toast above the bottom bar → Undo. Recently deleted → Restore.
  - [ ] Long entries: 41k-char body scrolls smoothly, typing at the end has no lag (watch for frame drops in M23).
- **Skipped/blocked:** —

## Phase M6 — Dream journal
- **Status:** Not Started
- **Desktop reference:** P8.
- **HLD docs:** DREAM_JOURNAL.md
- **Part B:**
  - [ ] Compact list ↔ editor with the Back interceptor (as M5); the split-pane width setting has no effect in compact and comes back in landscape.
  - [ ] Sticky notes and the branch painter visuals at 360 dp and in landscape; the night wash runs full-bleed without the rail gutter.
  - [ ] Dream search on the phone; dream images (M3 routes); delete + Undo.
- **Skipped/blocked:** —

## Phase M7 — To-Do
- **Status:** Not Started
- **Desktop reference:** P9 (BUG-012 and the subtask draft store from FV).
- **HLD docs:** TODO_EDIT_PANEL_UI.md, TODO_LIST_SEARCH_HLD.md, SOFT_DELETE_TOAST.md, UNDO.md
- **Part B:**
  - [ ] Composer with the soft keyboard: Enter/Done adds a task and keeps the keyboard up for the next; the list scrolls so the new task shows.
  - [ ] The edit side panel on a phone: how does it open (sheet? full page?), notes, due date/time pickers, recurrence, reminder bell (M4 checks the firing), tags, subtasks. Back closes it with the edits saved.
  - [ ] Complete/uncomplete by tap; completed section collapse; hide completed; sort; drag-reorder by long-press; confetti and the complete sound (M21 Sounds switch).
  - [ ] List search (desktop Ctrl+F): its touch route; Enter/Shift+Enter equivalents.
  - [ ] Lists manager and list settings as sheets; default list switching (`79f5c468`).
  - [ ] A task due at 23:59 with the phone left open across midnight (or a clock change): the day's labels refresh (`efa04a45`, stale-day UI).
- **Skipped/blocked:** —

## Phase M8 — Calendar
- **Status:** Not Started
- **Desktop reference:** P10.
- **HLD docs:** WEEKLY_CALENDAR.md, CALENDAR_OVERLAY_HLD.md, TIME_SELECTOR.md
- **Part B:**
  - [ ] Week / month / year views at 411 and 360 dp: the compact day grid (`calendar_day_grid.dart`), readable event chips, the morph transitions by touch, swipe left/right between periods (if supported) vs the arrow buttons, the current-date capsule (`c26c586f`).
  - [ ] Create an event by tapping/long-pressing a slot; the event panel as a phone surface; all-day vs timed; multi-day; recurring + delete occurrence vs series. After a date or time pick, the Title is **not** refocused on touch (`calendar_event_panel.dart:628`), so the keyboard doesn't pop up after every pick.
  - [ ] Overlapping events legible in compact; to-do markers and the to-do panel; workouts on the calendar.
  - [ ] Calendars manager (create, colour, hide, show all); default calendar switching (`79f5c468`); the import dialog (paste text) with the keyboard up.
  - [ ] Timezone change with events open (`42b6efda`): times shift as the HLD says.
- **Skipped/blocked:** —

## Phase M9 — Search
- **Status:** Not Started
- **Desktop reference:** P11.
- **Part B:**
  - [ ] The search field with the soft keyboard (IME Search action), results list scrolling with the keyboard up, opening a result and editing it in place, Back to the results with the query kept.
  - [ ] Gaia messages appear in Search where GAIA_HLD §17 says they're indexed (on Android too).
  - [ ] Check-in notes and secure notes never appear (PHOTO_SERIES_HLD §16, SECURE_NOTES_HLD).
- **Skipped/blocked:** —

## Phase M10 — Analytics, trackers & counter statistic
- **Status:** Not Started
- **Desktop reference:** P12. The counter statistic has **no desktop phase** (§0.3).
- **HLD docs:** ANALYTICS_PAGE.md, ANALYTICS_EXPLANATION.md, LIFE_TRACKER.md, **COUNTER_STATISTIC_HLD.md** (its header still says "design"; it's implemented, `counter_controls.dart`: log the doc's stale status)
- **Part B:**
  - [ ] Stat tiles, heatmap (modes and the day popover by tap), mood trend card, sparklines at 360 dp and in landscape; the grid vs list view.
  - [ ] Trackers: create integer/boolean/enum, each cadence and style, colour; tracker entry rows by touch.
  - [ ] **Counter statistic, full pass (on the phone first, desktop optional):** create one; − and + only (no typing a number); the value carries over to the next day; the day-by-day log; a change on a past day and how later days follow (HLD rules); the sparkline; rapid + taps (20 in 2 s) all counted once each; offline + taps then reconnect; delete + Undo. Check the stored rows against the HLD's model. Two-device behaviour is in the sync plan.
  - [ ] The inbox's route to Analytics (`c8607d8c`) lands here correctly on the phone.
- **Skipped/blocked:** —

## Phase M11 — Finance A–C
- **Status:** Not Started
- **Desktop reference:** P13, P14, P15 (and FV's finance items, e.g. BUG-106's time-zone half that desktop couldn't test).
- **HLD docs:** FINANCIAL_TRACKER.md, FINANCE_BREAKDOWN_AND_LEDGER_UX_HLD.md, FINANCE_HERO_NET_FLOW_CHART_HLD.md, FINANCE_TRANSACTION_ORIGIN_HLD.md, FINANCE_CONTRIBUTION_ROOM_HLD.md
- **Part B:**
  - [ ] The transaction sheet with the **numeric keyboard** on Amount (decimal key, minus?), Next through Store → Note → Tags, Done saves. The desktop quick-transaction floater has no phone equivalent: record the fastest phone route to a new transaction.
  - [ ] Ledger by day, the net-flow hero range picker, the net-flow chart and calendar by touch (tap a bar or day for detail), ledger search and filters.
  - [ ] Categories, budgets, subscriptions, bill radar and the Analytics tab's breakdowns at 360 dp: charts legible, legends not clipped.
  - [ ] Goals (allocate), assets (valuations, the value chart), contribution rooms (create/join, events, history) as phone sheets.
  - [ ] A time zone **east of UTC** (M0's timezone route): evening transactions land on the right day (desktop BUG-106's untested half).
  - [ ] Finance UI prefs (device-local tab memory) after force-stop and process death.
- **Skipped/blocked:** —

## Phase M12 — Life tracker
- **Status:** Not Started
- **Desktop reference:** P16.
- **HLD docs:** LIFE_TRACKER.md
- **Part B:**
  - [ ] The life tree canvas at 360 dp portrait and in landscape (full-bleed sky); stat leader labels not overlapping; the blossom stat popup and tree popover by tap; the bucket list popup (CRUD, complete, delete + Undo) with the keyboard up.
- **Skipped/blocked:** —

## Phase M13 — LeetCode
- **Status:** Not Started
- **Desktop reference:** P17, P18. LeetCode username sync stays MANUAL-ONLY.
- **HLD docs:** LEETCODE_TRACKER.md, NEETCODE150.md, LEETCODE_TYPE_HIGHLIGHT_HLD.md, LEETCODE_CHEAT_SHEET_HLD.md, LEETCODE_SCRATCH_PAD.md, LEETCODE_SCRATCH_STARTER_HELPERS.md, SESSION_RESUME_HLD.md
- **Part B:**
  - [ ] Dashboard rings, activity calendar/chart and tag matrix at 360 dp.
  - [ ] Track modal with its device-local draft: Back/drag closes it and the draft survives; process death mid-draft. An edited problem can't be dragged shut by accident (the 2026-10-07 follow-up made this Android-specific).
  - [ ] **Session and cram by touch:** flip by tap (desktop: Space), grading by buttons (desktop: keys), undo/redo history buttons (desktop: U/R), the scratch pad focus (desktop: C). Every keyboard-only action needs a touch route.
  - [ ] **Scratch pad:** the code editor with the soft keyboard: brackets, indentation, symbols; starter helpers; the diff view; draft persistence across process death.
  - [ ] **Cheat sheet:** desktop opens it with Ctrl+Shift+C. Find the phone's route (`leetcode_cheat_entry.dart`). If there's none, log it. Then tabs, sections and entries CRUD, search, export (the Android save picker), collapsed state.
  - [ ] Session resume toast after process death mid-session (checkpoints are device-local).
- **Skipped/blocked:** —

## Phase M14 — Rankings, map & repeat counter
- **Status:** Not Started
- **Desktop reference:** P19A, P19B (RANKINGS_MAP_HLD §11's acceptance criteria). The repeat counter has **no desktop phase** (§0.3).
- **HLD docs:** RANKINGS.md, RANKINGS_UI.md, RANKINGS_PARENT_TAGS_HLD.md, RANKINGS_SCORE_INPUT_HLD.md, RANKINGS_MAP_HLD.md, **RANKINGS_COUNTER_HLD.md**
- **Part B:**
  - [ ] Categories, parents and children, the edit panel, field editors, the score input (stars by tap and drag), tags, the gallery and media grid (M3 image routes, drag-reorder by long-press) at 360 dp.
  - [ ] **Repeat counter, full pass:** turn it on per category for entries and for units; every row starts at 1; the `+` that desktop shows on hover needs a touch route; the `− N +` stepper; rapid taps; offline; how the count shows in rows, the panel and sorting; an entry's count vs its units' counts. Compare with the HLD's "Changes from the design" list.
  - [ ] **Location permission:** the map's Locate button asks for location (coarse/fine) only when tapped. Deny → a clear message, no crash. "Don't ask again" → the route to settings. Grant → the map centres on `adb emu geo fix`.
  - [ ] **Map gestures:** pinch-zoom, two-finger rotate (allowed?), pan, tap a pin, tap a cluster, long-press on the empty map (the desktop right-click context menu) to drop a pin, quick-rate from a pin, filters, the All categories map, attribution visible above the bottom bar.
  - [ ] Add location dialog with the keyboard up: search, a pasted Google Maps link (from the clipboard), dropped pin, duplicate check.
  - [ ] Tile cache and offline: airplane mode → cached tiles draw, search says it needs a connection, a branch added offline uploads after (P26's offline map checks, with real offline this time).
  - [ ] The no-key state (a build without the Geoapify key, if M0 can make one cheaply).
- **Skipped/blocked:** —

## Phase M15 — Jobs
- **Status:** Not Started
- **Desktop reference:** P20. Opening job URLs stays MANUAL-ONLY.
- **HLD docs:** JOBS.md, JOBS_SMART_PASTE_HLD.md, JOBS_EXPERIENCE_SNIPPETS_HLD.md
- **Part B:**
  - [ ] The jobs table on a phone: it's wide on desktop; does it scroll sideways, collapse to cards, or clip? Every column reachable.
  - [ ] Track modal with smart paste from the Android clipboard (put a job title + URL there by VM eval), the device-local draft across Back and process death, company autocomplete by tap.
  - [ ] Stages, categories, seasons manager; status events; header stats and charts at 360 dp; experience snippets.
- **Skipped/blocked:** —

## Phase M16 — Study
- **Status:** Not Started
- **Desktop reference:** P21, P22.
- **HLD docs:** STUDY.md, STUDY_DECK_LINKS_HLD.md, STUDY_IMAGES.md, SESSION_RESUME_HLD.md
- **Part B:**
  - [ ] Folders/decks tree and breadcrumb by touch; the deck workbench at 360 dp.
  - [ ] **The Android-only buttons** in the name, move, move-destination and link-deck modals and the linked-deck view (`study_*_modal.dart`, `study_linked_deck.dart`): what they are (record them), that they work, and that the modals fit with the keyboard up.
  - [ ] Card editor: rich text, **math** (flutter_math) typed on the soft keyboard (`\frac`, `^`, `_`), images on card faces (M3 routes), the editor as a sheet that asks before a drag discards edits.
  - [ ] Import text modal with a large paste.
  - [ ] **Session and cram by touch:** flip by tap, grading buttons (fail/hard/good/easy), history buttons; SRS results in the DB match the desktop's for the same grades (P22's numbers).
  - [ ] Session resume after process death mid-session.
- **Skipped/blocked:** —

## Phase M17 — Workout
- **Status:** Not Started
- **Desktop reference:** P23.
- **HLD docs:** WORKOUT_TRACKER.md
- **Part B:**
  - [ ] The compact layout (`workout_page.dart:151`): plans (weekly vs cycle), day columns, the exercise library and detail view, prescriptions and the target editor sheet.
  - [ ] **Active workout:** set entry by numeric keyboard, the rest timer. Then the phone's real case, **the rest timer with the screen off or the app backgrounded**: does it finish on time, does anything alert the user, and is the elapsed time right after resume (Dart timers stop while suspended)? Process death mid-workout: is the workout recoverable?
  - [ ] The workout island stays above the page across bottom-bar switches and doesn't cover the bar (M2).
  - [ ] History list/log/session views; lb/kg; workouts on the calendar.
- **Skipped/blocked:** —

---

## Phase M18 — Photos on Android
- **Status:** Not Started
- **Desktop reference:** P28A, P28B (BUG-284 … BUG-304), MD-18 (BUG-305 … BUG-313). Android capture was MANUAL-ONLY there ("no phone"); with the emulator most of it is testable now. Only what needs a real camera's optics moves to the real-device pass.
- **Scope:** everything in PHOTO_SERIES_HLD on the phone: the vault on the page, series, the **Android capture screen** (camera, ghost overlay, angles, front/back, mirroring), check-ins (capture and gallery), the grid, the viewer, periods and streaks, playback, compare, the alignment editor by touch, series reminders (Android OS notifications), Trash, backups, and **no plaintext on disk**, plus **`FLAG_SECURE`**.
- **HLD docs:** PHOTO_SERIES_HLD.md (all, especially §9 capture, §10 alignment, §16's Android pass, §17 risks), SECURE_NOTES_HLD.md, MEDIA.md, SCHEDULED_REMINDERS_HLD.md
- **Prerequisites:** a fresh account (`-SignUp`), its **vault password** recorded in PROGRESS.md at once. M0's camera check done (the emulator's virtual scene for the back camera; the front camera set to the scene or emulated).
- **Flows:**
  - [ ] Vault states on the page: no vault → set up; locked (stats and the strip show, thumbnails are placeholders, Check in / Playback / Compare disabled); unlocked; Lock; Reset vault. The session shared with Secure Notes (M4).
  - [ ] **`FLAG_SECURE`:** while unlocked, `adb exec-out screencap` is black and the Recents thumbnail is blank; after Lock both are normal. Also check across process death and rotation (the flag must be re-applied to the new activity window).
  - [ ] The vault locks on Home → return, process death, and its idle timeout; it doesn't lock when the inbox closes while Photos is the visible page (§18.7).
  - [ ] **Camera permission:** first capture asks. Deny → a clear state and a route to settings; grant → the preview. No microphone permission is requested (manifest removes RECORD_AUDIO).
  - [ ] **Capture screen:** preview, the shutter, multi-angle series (Skip / Back / Next through angles), review, retake, date and note, save. The **ghost overlay** of the previous photo at the default 35% and at other opacities (§18.4); switching the ghost source if offered.
  - [ ] **Front camera:** saved stills are **unmirrored** (HLD wants them unmirrored; §17 says to watch CameraX). Compare the preview's aspect with the still's at `ResolutionPreset.veryHigh` (§17).
  - [ ] Cancel / Back / scrim / drag with photos taken → "Discard photos?" asks (BUG-286's fix made this cross-platform; on Android it was always there).
  - [ ] Process death **on the capture screen** with photos taken but not saved: what's lost? Any plaintext left behind?
  - [ ] **No plaintext on disk:** after captures and gallery ingests, list `files/`, `cache/` and the camera's temp location through `run-as`. No decodable JPEG/PNG from the session, and the camera's temp file is gone (§16). Pull the vault blobs and check they don't decode.
  - [ ] Check-in from the **gallery** (images pushed in M0) through the Android picker.
  - [ ] Grid (blur, reveal by tap, the long-press menu as the desktop's context menu), the viewer (swipe, pinch, Back), periods, streaks and missed marks.
  - [ ] **Playback** (4 fps default) of a long series (seed 100+ check-ins by VM eval): memory in M23's numbers, no OOM, scrubbing by touch. **Compare** by touch (slider/swipe).
  - [ ] **Alignment editor by touch** (§10 says Windows and Android): drag, pinch-scale, rotate if offered, "Use as reference".
  - [ ] **Series reminders:** an Android notification at the set time (app closed), tap → Photos; a check-in before the fire time cancels it; auto-acknowledge when the period is done; no inbox row while the page is hidden.
  - [ ] Trash for Photos kinds, the 30-day purge of vault blobs; export/import of Photos tables and ciphertext blobs through the Android pickers.
  - [ ] Sign-out with the vault unlocked: everything locked and cleared (§14 teardown).
- **Five-dimension sweep:** D3 the capture screen at every size and rotation (camera preview orientation!), D5 storage near full (`adb shell` fill a file, if practical), airplane mode during a check-in.
- **Skipped/blocked:** real optics, low light, a real front camera's mirroring on hardware → real-device pass.

---

## Phase M19 — Gaia on the phone
- **Status:** Not Started
- **Desktop reference:** the Gaia live passes recorded in GAIA_HLD.md §19 and each GAIA_*_HLD's live-test section, PROGRESS.md handoffs (qa-124 … qa-128), and `qa/GAIA_REMAINING_TESTS.md`, whose phone items (§D, §F3, and the phone parts of §A, §B, §E3, §E5, §H) were never run or ran only partly. Phone bugs so far: BUG-322, BUG-324, BUG-325, BUG-327, BUG-329, BUG-330, BUG-331, BUG-363 (open, Major), BUG-383.
- **Scope:** the Android Gaia page as the **full remote client** (GAIA_HLD §12, §14, §17): pairing, chats (list, search, pinned, recents, projects, history), sending prompts to a desktop beacon, streaming replies, cards (proposals, questions, permissions) on the phone, Stop and Abort, the queue and drain mode, Status (beacons online, runs, paired devices, Revoke), usage, memories and topics, push notifications (FCM), the no-beacon case, remote power commands (cancelled). Plus every Gaia feature that has a phone surface: fork, rewind, chapters, `/btw`, greetings, token usage, tool-call details, history.
- **HLD docs:** GAIA_HLD.md (§8, §12, §13, §14, §17), GAIA_PROJECTS_HLD.md, GAIA_MEMORY_TOPICS_HLD.md, GAIA_HISTORY_HLD.md, GAIA_FORKING_HLD.md, GAIA_REWIND_HLD.md, GAIA_CHAPTERS_HLD.md, GAIA_BTW_HLD.md, GAIA_GREETINGS_HLD.md, GAIA_TOKEN_USAGE.md, GAIA_TOOL_CALLS.md, GAIA_SETTINGS_HLD.md (which parts exist on the phone), GAIA_AUTONOMY_HLD.md §11.4 (phone prompts in Auto)
- **Prerequisites:** a desktop beacon in a QA profile (`gaiaqa`, qa-128, per the recent handoffs, or a fresh one) on the same account as the phone, with **dummy replies only** (`/msg1`, `/msg4`, `/card1`, `/propose2`, `/slow`, …). No real model turns unless Juno says so. Never run a power command to the end.
- **Flows:**
  - [ ] **Pairing:** pair from the phone (the code/QR flow) → accept on the desktop → the phone shows the beacon online. Decline, then pair again (BUG-324). Revoke on the desktop → the phone can't send, and says why → remove and re-pair.
  - [ ] Chats list on the phone: search, pinned, recents, projects, history; opening a long chat (1,000+ messages) scrolls without jank; BUG-363's scenario (messages written while the desktop was signed out) and whether it's fixed.
  - [ ] **Send a prompt** from the phone → the beacon claims it → the reply streams on the phone. With the phone backgrounded mid-reply → push on completion → tap opens that chat.
  - [ ] **Cards on the phone:** a proposal (Accept / Decline, BUG-322), a question, a permission card. A card the phone saw and then left (BUG-329); the phone dying mid-card (BUG-330, `am kill` while watching); a reply ending in the 60 s after the phone died (BUG-331).
  - [ ] **Stop and Abort** from the phone (GAIA_AUTONOMY §11.4): time to effect (the 2026-11-04 check measured 1.0–1.6 s).
  - [ ] **Queue** on the phone: add, reorder (drag on desktop; record the phone's route, since drags are off on Android, `gaia_page.dart:1507`), copy, pop; drain mode from the phone.
  - [ ] **Status tab:** beacons, runs, devices, Revoke; commands sent from the Status tab are cleaned up and their errors shown (BUG-325).
  - [ ] **Remote power:** start `sleep` from the phone, then **Cancel** within the countdown. The countdown ticks on the phone (BUG-327). The UI warns that it's one-way. Never let it finish.
  - [ ] **No beacon online:** close the desktop beacon → the phone says so, greys out CLI-only agents (GAIA_HLD §12.2); an API-key agent, if configured, is out of scope unless Juno sets one.
  - [ ] **Push:** permission asked only once the phone has paired (`voyager_app.dart:124`); denied → no crash; the FCM token in `gaia_devices`; a notification for a completion, a question and a new card; tap opens the chat; a notification while the app is in the foreground.
  - [ ] Composer on the phone: empty send with a card open (§F3), attachments from the phone (gallery, camera?), long text, Markdown and LaTeX rendering (`11ee048d`), the `/` palette by touch, chips (project, topics) by tap.
  - [ ] Memories and topics on the phone: list, edit, recall chips (BUG-383), the Sort these suggestions.
  - [ ] Fork, rewind, chapters, `/btw`, greetings, token usage and the Moon, tool-call details: each one's phone surface, or its documented absence.
  - [ ] The Gaia sky background on the phone (GAIA_SKY_AUDIT.md): performance in M23, legibility at 360 dp, the starfield stops when hidden (`GaiaController.skyActive`).
  - [ ] Accessibility: Gaia turned off accessibility on desktop because the Flutter engine crashed (`bb148767`). Does TalkBack on the Gaia page crash the app on Android? (M24 runs TalkBack generally; do the Gaia page here.)
- **Five-dimension sweep:** as usual; D5 airplane mode mid-stream, then reconnect: the stream resumes or the message is complete from Firestore.
- **Skipped/blocked:** real model turns and power actions (MANUAL-ONLY unless Juno runs them).

---

## Phase M20 — Trash, soft delete & undo
- **Status:** Not Started
- **Desktop reference:** P24.
- **HLD docs:** TRASH_HLD.md, SOFT_DELETE_TOAST.md, UNDO.md
- **Flows:**
  - [ ] The Undo toast for every deletable kind on the phone: it sits above the bottom bar and the gesture bar, its 8 s dwell, Undo by tap. Does a touch hold pause it the way hover does on desktop? The changed delete toast (`a4f64972`).
  - [ ] Settings → Trash on the phone: list by kind, item detail, restore, permanent delete (confirm), empty trash; long lists scroll.
  - [ ] Restore contracts (a child whose parent is deleted) and erasure, as P24, from the phone.
  - [ ] Delete → Home → process death before the toast ends: the delete stands, and Trash has it.
- **Skipped/blocked:** the 30-day purge needs a clock change (M0's route) or seeded old rows.

---

## Phase M21 — Settings, theming & data management
- **Status:** Not Started
- **Desktop reference:** P25 (BUG-209 … BUG-216). Desktop-only tiles (Start with Windows, folder backups, heat watch, Show in folder) must be absent.
- **HLD docs:** AUTO_BACKUP_HLD.md (§6.1 Android foreground-only, §8 storage and Auto Backup), IMPORT_EXPORT.md, DARK_THEME_AUDIT.md, WHITE_THEME.md, ON_COLOR_LABEL.md, GLASS_BUTTON.md, SCOPE_SWITCHER_HLD.md, BACKGROUND.md
- **Flows:**
  - [ ] Every Settings tile on the phone at 360 dp: accent, theme, palette (long-press as the desktop's right-click Replace everywhere), petals and the geometric texture/wave settings, nav pages (drag reorder by long-press), startup page, week start, birth date, default trackers, weight unit, rest timer, the image switches, image storage, weather location, custom quotes, snippets/dictionary launchers, Vim, autocorrect, Account. Each persists across force-stop, process death and (synced ones) a cold re-login.
  - [ ] **Full Light-theme pass** of every page on the phone (the one full pass; other phases spot-check), including the map tiles.
  - [ ] **System dark mode vs the app theme:** app Dark with the system Light, and the reverse: the status-bar and navigation-bar icons stay legible.
  - [ ] **Sounds** (`app_sounds.dart`, `audioplayers`; §0.3): complete a task, save, log; the Sounds switch off silences them; sounds respect the phone's media volume and Do Not Disturb (record); no crash with the volume at 0.
  - [ ] **Weather location** through the `cloud_functions` plugin (Android path, §0.1): set a location, the strip shows it, the forecast sheet fills. Airplane mode → a clean error.
  - [ ] **Automatic backups on Android:** a run at app start (foreground only); Home → the timers pause; resume → they restart (`voyager_app.dart:476`); retention as P25 (plant files through `run-as`); damaged/unsupported handling. The backup list has no Show in folder; **Save a copy** goes through the Android save picker and writes the bytes (`backup_list_dialog.dart:238`): the saved file is byte-identical (pull and compare). Restore from the list → confirm → data identical (row counts per table), then Undo from "Before restore".
  - [ ] **Export / Import backup** through the Android pickers (SAF): export → a valid ZIP (pull it, run the P25 checks); import onto a fresh account → identical; the P25 failure fixtures (push them to `/sdcard/Download`) → each refused, nothing changed. Cancel each picker.
  - [ ] **Import while offline** (real airplane mode): desktop couldn't test this (P25 "Not covered"). Then reconnect: everything uploads.
  - [ ] **Android Auto Backup excludes `backups/`** (AUTO_BACKUP_HLD §8.2, `backup_rules`): read the built manifest's rules; `adb shell bmgr backupnow com.example.voyager` if the image allows, then check what was included. Otherwise mark it for the real-device pass.
  - [ ] About: build info copy (to the Android clipboard).
  - [ ] Image upload off → a new image is `localOnly`; on → `uploaded` (native Storage); download off → placeholders.
- **Skipped/blocked:** —

---

## Phase M22 — Sync, offline, lifecycle & Dev page (one device)
- **Status:** Not Started
- **Desktop reference:** P26 (BUG-217 … BUG-223), and the "edits during a long startup download" section. Two-device work is in `MOBILE_SYNC_TEST_PLAN.md`.
- **Scope:** the outbox and offline queue on the phone under **real** network loss (airplane mode, Wi-Fi/data toggles, a flaky link), the Android lifecycle's effect on sync (background, Doze, process death, force-stop with a non-empty outbox), the startup pull on a cold re-login, media upload/download through the native Storage SDK, and the Dev page on the phone.
- **HLD docs:** SAVING.md, DATA_INTEGRITY_AUDIT_REPORT.md, JOURNAL_DATA_LOSS_POSTMORTEM.md, MEDIA.md, RELEASE_CHECKLIST.md
- **Flows:**
  - [ ] **Airplane mode:** create/edit/delete across five kinds → rows in `pending_uploads_table` (record when: immediately, or after the write gate's 45 s, as desktop Force offline did) → airplane off → drains → a cold re-login shows all of it.
  - [ ] **Wi-Fi ↔ mobile data switch** mid-drain (`svc wifi disable` with data on): the drain continues, no duplicates. A 10× fast toggle of airplane mode.
  - [ ] **Flaky network:** the emulator's network delay/speed settings (`adb emu network delay gprs`, `network speed edge`), or toggling every few seconds during a 300-write drain: nothing lost, nothing doubled.
  - [ ] **Force-stop with a non-empty outbox** → relaunch → it drains. **Process death** with a non-empty outbox (Home, `am kill`) → reopen → it drains. Kill mid-drain at roughly half (seed 300 task edits as P26 did).
  - [ ] **Background:** edit, Home immediately: does the upload finish in the background, or wait until the next open? Record how long Android lets it run. Then Doze (`force-idle`) with queued writes → unforce → open the app → drains.
  - [ ] **Resume catch-up:** while the phone is backgrounded, change data from the desktop (any QA profile on the same account; the full matrix is in the sync plan). Reopen the phone: the change shows without a restart.
  - [ ] **Startup pull on a big account** (qa-026's 3,900 docs, or a fresh seed): time it on the phone. Edit during the pull (journal, to-do, transaction), switch pages, Home mid-pull, kill mid-pull → relaunch resumes. Re-check BUG-221 (the to-do lost during a pull).
  - [ ] **Media:** an image added offline uploads on reconnect (re-check BUG-223); download off/on; a 10 MB image on a slow network (`network speed edge`): progress, no ANR.
  - [ ] **Dev page on the phone:** Device ID and Firebase UID match; Force offline (it should behave as on desktop, and now it can be compared with real airplane mode); Verbose sync lines in the log; sync compare and backlog tiles; the conflict banner (force conflict UI) on a phone screen; the error log view and copy; the FPS counter. Destructive tools stay unrun, as on desktop.
  - [ ] The sync activity indicator and connectivity badge in the compact strip during all of the above.
- **Skipped/blocked:** —

---

## Phase M23 — Performance, memory, stability & release build
- **Status:** Not Started
- **Desktop reference:** none as a phase (desktop had the perf stall log and FPS counter in P26).
- **Scope:** what a phone user feels: start-up time, frame rate, memory, ANRs, and the release build. The emulator's numbers are only relative (it runs on the laptop's CPU and GPU). The real-device pass repeats the key ones.
- **Flows:**
  - [ ] **Cold start** (force-stop → launch) to the first page interactive: `am start -W` gives the activity time; add the time until the page has data. Debug and **release/profile** builds both (debug is far slower). Then a warm start from Recents.
  - [ ] **Frame rate:** `dumpsys gfxinfo com.example.voyager` (janky frames %) for scrolling a long journal list, To-Do with 300 tasks, the calendar morph, the Life tree, the map with 200 pins, Photos playback, and the Gaia chat with the sky. Each with **Dark + Scatter on** (the background animates every frame) and again with it off: Scatter's cost on a phone.
  - [ ] **Memory:** `dumpsys meminfo com.example.voyager` at idle, after visiting every page (the shell keeps every page mounted and warms the rest, `app_router.dart`), during Photos playback of 100+ frames, and after 30 minutes of use. Look for steady growth.
  - [ ] **Low memory:** `am send-trim-memory com.example.voyager RUNNING_CRITICAL`, and `COMPLETE` while backgrounded: no crash, state restored on return.
  - [ ] **ANRs:** watch logcat throughout M1–M22 for `ANR in`. Big pastes, big imports and the startup pull are the likely spots.
  - [ ] **Release build** (`flutter build apk --release` with the same dart-defines; sign with the debug key if no release key is set up, and don't publish anything): Demo is absent from the nav; Dev is reachable only as configured; no debug banner; the app runs the same flows as M1, M2 and M5 without errors. R8/obfuscation issues (a missing class at runtime) show up here, so watch logcat. Note that `phone.ps1 check` reads the DB through `run-as`, which works on debug builds only. A release build needs another guard: sign in by hand with Juno, or confirm the account from the UI before any input.
  - [ ] APK size; installed size after a big sync (`dumpsys package` / `du` through `run-as` on the debug build).
- **Skipped/blocked:** battery drain and thermal behaviour (real-device pass).

---

## Phase M24 — Accessibility
- **Status:** Not Started
- **Scope:** TalkBack, font scale, contrast and touch targets across the app. Desktop never tested a screen reader (Flutter exposed no semantics tree to the harness there).
- **Flows:**
  - [ ] **TalkBack on** (`settings put secure enabled_accessibility_services com.google.android.marvin.talkback/com.google.android.marvin.talkback.TalkBackService` + `accessibility_enabled 1`, if TalkBack is on the image): walk the login page, the bottom bar and More, and the main page of each section. Every control has a spoken label (icon-only buttons with tooltips should read their tooltip); no crash. Gaia's page is done in M19. **Turn TalkBack off afterwards** (it changes how every tap works).
  - [ ] **Font scale 2.0** on every page (D3 did each page's main screen; here the dialogs, sheets and toasts): no clipped labels, no overflow errors.
  - [ ] **Touch targets:** list any control under 48 dp found during M1–M22 (`kMinTouchTarget`).
  - [ ] **Contrast:** the light and dark themes' text on lit triangles and glass panels, at phone brightness (DARK_THEME_AUDIT.md, WHITE_THEME.md expectations).
  - [ ] **Reduce motion** (`settings put global animator_duration_scale 0`, `transition_animation_scale 0`, `window_animation_scale 0`): the app still works; any animation that the app drives itself and doesn't honour this is noted (undo to 1).
- **Skipped/blocked:** —

---

## Fix verification (FV-M) — app changes made during this audit
- **Status:** Not Started
- **Why:** as desktop FV: phase sessions never change app code, but Juno may fix bugs while this audit runs. Each fix gets its own FV-M-n entry (change, commit, what to check on the phone, result), run after the phase that found it is Done.

---

## Phase M25 — Final review
- **Status:** Not Started
- **Checklist:**
  - [ ] Re-check every Blocker/Major mobile bug for duplicates, including duplicates of **desktop** bugs (same root behaviour seen on both platforms: note it on both entries, don't delete; BUGS.md is append-only).
  - [ ] Confirm every phase M0–M24 and FV-M is Done or has documented skips.
  - [ ] Write a mobile summary at the top of BUGS.md (or a second summary block under the desktop one): counts by severity, by phase, the list of Blockers, which bugs are Android-only vs shared code.
  - [ ] Run PROGRESS.md §6b's "Deferred until the screen lock is off" list in one session with Juno's lock off (ask Juno first, and remind them to turn it back on afterwards). List anything still manual in the summary.
  - [ ] Update PROGRESS.md; final phone SESSION END; restore Juno's global settings on the phone.

---

## Real-device pass (MANUAL, with Juno's phone)

Written when the phases ran on the emulator. **Since 2026-11-22 the phases run on the real phone**, so each phase covers these items where it can: camera optics in M18, OxygenOS battery management in M4/M22, performance and heat in M23, real touch and notifications in their phases. What still needs Juno's hands goes on PROGRESS.md §6b's list: an incoming call, moving between networks (Wi-Fi to cellular, a tunnel, a captive portal), voice typing, Google sign-in, and lock-screen notification text. Use a QA account, never Juno's real one on a test build.

- Camera optics: front-camera mirroring on real hardware, the still vs preview aspect, low light, the ghost overlay outdoors (PHOTO_SERIES_HLD §16, §17).
- OEM battery management (Samsung, Xiaomi, OnePlus): do scheduled reminders still fire with the app closed for a day? Does background sync stop sooner than on stock Android?
- Real performance, battery drain, heat: cold start, scrolling, Scatter's cost, Photos playback, the Gaia sky.
- Real touch: gesture-bar conflicts, palm rejection, one-handed reach to the strip and the bar.
- Real network: switching from Wi-Fi to cellular, a lift or tunnel, a captive portal.
- Real notifications: grouping, lock-screen visibility of reminder text (and that secure-note or check-in text never shows there), Do Not Disturb.
- Android Auto Backup actually excluding `backups/` (M21, if `bmgr` didn't settle it).
- Voice typing in the journal; Gboard image insert.
- Google sign-in end to end (with Juno's consent, on a QA Google account if one exists).
