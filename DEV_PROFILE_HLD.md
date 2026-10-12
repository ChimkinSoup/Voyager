# Dev Profiles (two instances side by side) — HLD

A debug-only switch that lets a second (or third) Voyager run beside the normal one on the same Windows machine, each with its own local data, its own Firebase sign-in and its own device identity. Two such instances are two real devices as far as sync is concerned: separate SQLite databases, separate outboxes, separate Firestore SDK caches, separate device ids, talking to the same Firestore project. That makes real cross-device sync testable without a second computer.

Related: `windows/runner/main.cpp`, `windows/runner/flutter_window.{h,cpp}`, `lib/main.dart`, `lib/core/platform/app_data_directory.dart`, `lib/app/providers.dart`, `lib/app/voyager_app.dart`, `lib/core/platform/launch_at_login.dart`, `lib/core/platform/app_tray.dart`, `lib/core/reminders/device_registration.dart`, `lib/core/sync/local_account_store.dart`, `qa/harness/*`.

Status: **implemented 2026-10-12**, verified per §8 with profile `b` beside the normal instance. §10 is resolved: 1, 2 and 4 as decided below, and 3 yes (QA sessions run in profile `qa` by default). Where the implementation differs from the draft:

- **Debug builds on both sides.** Dart reads the variable under `kDebugMode`, not `!kReleaseMode`. The runner's `#ifdef NDEBUG` also covers profile builds, and the two sides must agree, or a profile-mode build would split its data without splitting its mutex.
- **Firestore needs its platform instance set** (§5.5). `FirebaseFirestore.instanceFor(app:)` goes through `FirebaseFirestorePlatform.instance`, which is built lazily on `Firebase.app()`, the `[DEFAULT]` app a profile never creates. Every Firestore call then threw `[core/no-app]`. `main()` now sets that instance to a `MethodChannelFirebaseFirestore` for the profile's app. Auth and Storage build theirs with no app and need nothing. `cloud_firestore_platform_interface` became a direct dependency for this.
- **The quit message is scoped too.** `Voyager.Quit`, which `build_release.ps1` broadcasts, becomes `Voyager.Quit.<name>` like the show message, so replacing the installed copy doesn't close a running profile.
- **Expression evaluation** (§7). The exe run directly has no expression compiler, so `eval`, `whoami` and `evalc` failed against it. `launch.ps1 -Profile` therefore runs `flutter attach --debug-url` against it and uses the VM service URI that attach prints. The switches `FLUTTER_ENGINE_SWITCH_n` = `vm-service-port=<port>` and `disable-service-auth-codes` work on the pinned Flutter (3.44.6).
- **The normal instance's PID** comes from the VM service (`vm.ps1 pid`). `launch.ps1` writes it to `pid.txt` beside `pid_<name>.txt`.
- **On-disk names, as observed:** `%LOCALAPPDATA%\firestore\voyager-b\voyager-db9de` and Credential Manager `voyager-db9de.firebase.auth/voyager-b[0..1]`, matching §5.5.

---

## 1. Goals

- Run instance **A** (the normal app) and instance **B** (a profile) at the same time, from the same build.
- B shares **nothing writable** with A on disk: database, media, drafts, state files, backups, Firestore cache, persisted sign-in, logs.
- B is a distinct device to sync: its own `deviceId`, its own device registration, its own name in Settings → Devices.
- B can't change anything machine-wide that belongs to A: global hotkeys, the login Run entry, the folder backup target.
- With no profile set, behaviour is **byte-for-byte what it is today**. Same paths, same mutex, same Firebase app name.
- The QA harness can launch, drive, inspect and stop each instance separately.

## 2. Non-goals

- A user-facing feature. There's no UI for picking a profile, and release builds ignore the switch (§4).
- Android. Each Android device or emulator is already its own instance. Desktop↔Android testing is a separate pass that needs no code from this HLD.
- Running two instances against **one** database. That is exactly what the single-instance mutex exists to prevent, and it stays prevented.
- Automated sync test scenarios themselves. This HLD only makes them possible; §9 sketches how they'd use it.

---

## 3. Why this is needed (what breaks today)

| Shared resource | Where | What a second instance would do today |
|---|---|---|
| Single-instance mutex `Local\Voyager.SingleInstance` | `windows/runner/main.cpp` | Second launch broadcasts `Voyager.ShowMainWindow` and exits. Can't run at all. |
| App-data dir `%APPDATA%\Voyager\voyager` | `appDataDirectory()` | Same `voyager.sqlite`, same media, same drafts. One device with two windows, not two devices. |
| `deviceId` | settings row in that DB (`ensureDeviceId`) | Both instances claim the same device. Reminder delivery and device registration can't be tested. |
| Account ownership of local data | `LocalAccountStore` (BUG-005) | **Hazard:** signing B into a QA account would wipe the local store *A is using*, since it belongs to "another account". |
| Firestore SDK cache `%LOCALAPPDATA%\firestore\[DEFAULT]\voyager-db9de` | Firebase C++ SDK, keyed by app name | Two processes on one on-disk cache. Lock contention at best. |
| Persisted sign-in `voyager-db9de.firebase.auth/[DEFAULT][n]` (Credential Manager) | Firebase C++ SDK, keyed by app name | B starts signed in as A's account. Signing B out removes A's persisted sign-in too. |
| Global hotkeys | `HotkeyService`, `hotKeyManager.unregisterAll()` in `main()` | B can't register them, and must not unregister A's. |
| Login Run entry `HKCU\...\Run\Voyager` | `launch_at_login.dart` | Toggling it in B repoints A's autostart. |
| Folder backup target | `folderBackupServiceProvider` | B would write archives of a different store into A's chosen folder. |
| Auto-backups, folder-backup staging, offline maps | `getApplicationSupportDirectory()` called directly in `providers.dart` and `rankings_offline_maps.dart`, bypassing `appDataDirectory()` | Shared directories even if the DB path were split. |
| Logs (`voyager_errors.log`, `perf_stall.log`, sync-compare and debug logs) | `getApplicationDocumentsDirectory()` in `lib/core/dev/*` | Two processes appending to the same files, interleaved. |
| Show-window broadcast `Voyager.ShowMainWindow` | `flutter_window.cpp` | Relaunching one instance would raise both. |

---

## 4. Decisions

| Decision | Choice |
|---|---|
| **Switch** | Environment variable `VOYAGER_PROFILE`. It's read by both the C++ runner and Dart (`Platform.environment`), so one build serves every instance. A `--dart-define` would need a build per profile, and a command-line flag would need threading through the runner and `flutter run`. |
| **Valid names** | `^[a-z0-9]{1,16}$`. Unset or empty means the default instance. Anything else makes the runner exit with a message box rather than guess. `default` is reserved. |
| **Builds** | **Debug builds only.** In release, the runner (guarded by `#ifdef NDEBUG`) and Dart (`kReleaseMode`) ignore the variable. A stray env var on Juno's machine can then never split the installed app's data. |
| **Data root** | Sibling of the normal dir: `%APPDATA%\Voyager\voyager-profile-<name>`. Everything that today resolves under `getApplicationSupportDirectory()` resolves under this instead. |
| **Firebase** | Named Firebase app `voyager-<name>` instead of `[DEFAULT]`. The SDK keys both the Firestore cache directory and the Credential Manager target by app name, so this alone separates the cache and the sign-in. |
| **Hotkeys** | Not registered, and `unregisterAll()` is skipped. Settings shows them as unavailable, the existing "taken" path. |
| **Launch at login** | Toggle disabled in a profile, with the row explaining why. `setLaunchAtLogin` is never called. |
| **Folder backup** | Off in a profile, regardless of the synced setting. |
| **Auto-backup** | **On.** It writes under the profile's own data root, so it's harmless, and it's a feature worth exercising per device. |
| **Tray** | Kept, since close-to-tray needs it. Tooltip `Voyager [<name>]`. |
| **Window identity** | Window title and the custom title bar show `Voyager [<name>]`, so screenshots and Alt+Tab can tell the instances apart. |
| **Device name** | `defaultDeviceName()` appends ` [<name>]`. Settings → Devices then lists `HOST` and `HOST [b]`. |
| **Logs** | `<data root>\logs\` instead of Documents. The normal instance's logs stay in Documents. |
| **Legacy migrations** | Skipped in a profile: the move out of Documents and the `com.example` move. A profile has no legacy data, and must never adopt A's. |

---

## 5. Design

### 5.1 One source of truth: `DevProfile`

New file `lib/core/platform/dev_profile.dart`:

```dart
/// The dev profile this process runs as, or null for the normal instance.
/// See DEV_PROFILE_HLD.md. Always null in release builds.
final String? devProfile = _readDevProfile();

String? _readDevProfile() {
  if (kReleaseMode) return null;
  final raw = Platform.environment['VOYAGER_PROFILE'];
  if (raw == null || raw.isEmpty) return null;
  if (!RegExp(r'^[a-z0-9]{1,16}$').hasMatch(raw) || raw == 'default') {
    throw StateError('VOYAGER_PROFILE must match [a-z0-9]{1,16}: $raw');
  }
  return raw;
}

/// ` [b]` in a profile, empty otherwise: for titles, tooltips, device names.
String get devProfileSuffix => devProfile == null ? '' : ' [$devProfile]';
```

Every other change below reads `devProfile`. Nothing else parses the variable. The runner validates first, so the Dart throw is a backstop that shouldn't fire.

### 5.2 Runner (`windows/runner/main.cpp`, `flutter_window.*`)

- Read `VOYAGER_PROFILE` with `GetEnvironmentVariableW` before the mutex. Under `#ifndef NDEBUG` only; release treats it as unset.
- Mutex name: `Local\Voyager.SingleInstance` unchanged for the default instance. `Local\Voyager.SingleInstance.<name>` for a profile.
- Show-window message: `Voyager.ShowMainWindow` unchanged, `Voyager.ShowMainWindow.<name>` for a profile. `kShowMainWindowMessage` becomes a function of the profile, used by both `main.cpp` (sender) and `flutter_window.cpp` (receiver).
- Invalid name: `MessageBoxW` saying so, then `EXIT_FAILURE`.

A second launch of the **same** profile still hands focus to the running one, exactly as today.

### 5.3 Data root (`app_data_directory.dart`)

- Add `Future<Directory> appSupportRoot()`. It returns `getApplicationSupportDirectory()` for the default instance, and its sibling `voyager-profile-<name>` (created if missing) for a profile.
- `_resolve()` uses `appSupportRoot()` as its target. In a profile, it skips the legacy `com.example` move and the Documents move entirely and returns the root.
- `appDataMovePending()` returns false in a profile.
- Replace the three direct `getApplicationSupportDirectory()` calls with `appSupportRoot()`:
  - `providers.dart`: `folder_backups` staging
  - `providers.dart`: `backups` root, also handed to `LocalAccountStore`
  - `rankings_offline_maps.dart`: `offline_maps`

The DB, media, drafts, session checkpoints, finance prefs, notification history and settings-tab memory already go through `appDataDirectory()`, so they follow without changes.

### 5.4 Logs

Add `Future<Directory> logsDirectory()` next to `appSupportRoot()`. It returns Documents for the default instance and `<root>\logs` for a profile. Switch the call sites in `error_logger.dart`, `perf_stall_logger.dart`, `sync_compare_logger.dart`, `journal_debug_logger.dart` and `todo_sort_debug_logger.dart`.

`leetcode_scratch_host.dart`'s `_discardLegacyScratchFile` stays on Documents. It deletes a legacy file, it doesn't log, and in a profile it should be skipped (one early return).

### 5.5 Firebase (`main.dart`, `providers.dart`, …)

- `main()`: `Firebase.initializeApp(name: devProfile == null ? null : 'voyager-$devProfile', options: …)`. Keep the returned `FirebaseApp` in a top-level `voyagerFirebaseApp` (e.g. in `dev_profile.dart` or a small `firebase_app.dart`).
- Replace each `.instance` with `.instanceFor(app: voyagerFirebaseApp)`:
  - `main.dart`: `FirebaseFirestore.instance` for `OutboxSyncWorker.initialize`
  - `providers.dart`: `FirebaseAuth.instance`, both `FirebaseFirestore.instance` uses, `FirebaseFunctions.instance`
  - `http_callable_client.dart`, `firebase_media_storage.dart`: the `?? …instance` defaults
  - `journal_page.dart`: the direct `FirebaseAuth` / `FirebaseFirestore` reads (better still, read them through the existing providers)

For the default instance, `instanceFor(app: Firebase.app())` is the same object as `.instance`, so nothing changes there.

Expected on-disk result for profile `b`, based on the `[DEFAULT]` paths `reset.ps1` already relies on (**verify on first run**):
- Firestore cache: `%LOCALAPPDATA%\firestore\voyager-b\voyager-db9de`
- Sign-in: Credential Manager `voyager-db9de.firebase.auth/voyager-b[n]`

### 5.6 Desktop integrations

| Area | Change |
|---|---|
| `main()` | Skip `hotKeyManager.unregisterAll()` when `devProfile != null`. |
| `_bootstrap()` | Skip `_hotkeys.register(...)` in a profile. Set `unavailableHotkeysProvider` to all four, so Settings explains instead of offering to record. |
| `voyager_app.dart` | Don't `start()` `folderBackupServiceProvider` in a profile. `AppTray` tooltip gets `devProfileSuffix`. |
| `settings_page.dart` | Launch-at-login row disabled in a profile, subtitle "Not available in dev profile <name>". |
| `desktop_window.dart` / title bar | Title gets `devProfileSuffix`. |
| `device_registration.dart` | `defaultDeviceName()` appends `devProfileSuffix`. |

Reminders and OS notifications stay **on**: per-device reminder delivery is one of the main things to test. Both instances post toasts under AUMID `Voyager.App`. That's fine for testing, but clicking a toast may activate either instance (§10).

---

## 6. What stays shared (on purpose)

- **The build output.** Both instances run the same `voyager.exe`. Rebuilding while B runs fails to overwrite the locked exe, so stop B before rebuilding (§7).
- **The Firestore project and any account both sign into.** That's the point.
- **Machine settings outside the app:** theme, DPI, the clipboard. Clipboard tests across instances are fine, but they aren't sync.

---

## 7. QA harness changes (`qa/harness/`)

Today every script assumes one `voyager.exe` and the default paths.

| Script | Change |
|---|---|
| `launch.ps1` | `-Profile <name>`. Default instance: unchanged (`flutter run`). Profile: start the already-built `build\windows\x64\runner\Debug\voyager.exe` directly with `VOYAGER_PROFILE=<name>`, and set the engine switches `FLUTTER_ENGINE_SWITCHES=2`, `FLUTTER_ENGINE_SWITCH_1=vm-service-port=<port>`, `FLUTTER_ENGINE_SWITCH_2=disable-service-auth-codes` for a fixed VM service URI (**verify** these switches on the pinned Flutter). Write it to `qa/logs/vm_uri_<name>.txt`. The "already running" check becomes "this profile already running" (by PID file). |
| `vm.dart` / `vm.ps1` / `evalc.ps1` | `-Profile` (or env `VOYAGER_QA_PROFILE`) picks `vm_uri_<name>.txt`. |
| `voy.ps1` / `Probe.cs` | Target a PID, not "any voyager.exe". `launch.ps1` records `qa/logs/pid_<name>.txt`, and Probe's foreground guard checks that PID. Without this, a click meant for B can land in A. |
| `stop.ps1` | `-Profile` stops only that PID. No args keeps today's "stop everything". |
| `reset.ps1`, `sync_gate.ps1`, `whoami.ps1`, `guard.ps1`, `session_*.ps1`, `login.ps1` | `-Profile` switches the data dir, Firestore cache dir and Credential Manager target to the profile's (§5.3, §5.5). |

**Side benefit worth considering (§10):** QA sessions could run entirely in a profile. Then `session_start`/`session_end` would never need to sign Juno out or wipe `%APPDATA%\Voyager\voyager`, and the sync-gate dance before a wipe wouldn't apply to Juno's real install at all.

---

## 8. Verifying the change itself

1. **Default instance unchanged.** With no env var, a debug run uses `%APPDATA%\Voyager\voyager`, the `[DEFAULT]` cache and credential, registers hotkeys, and a second launch focuses the first. `flutter test` passes.
2. **Unit tests** for `dev_profile.dart` (valid, invalid, empty, release-ignored) and `appSupportRoot()` / `appDataDirectory()` under a profile (no legacy moves, correct sibling). `resetAppDataDirectory()` already exists for this.
3. **Side by side.** Launch A, then B (`-Profile b`). Check:
   - two `voyager.exe` processes
   - separate `voyager.sqlite` files with different `deviceId`s
   - Settings → Devices shows `HOST` and `HOST [b]`
   - A's hotkeys still work
   - `HKCU\...\Run\Voyager` unchanged
   - `%LOCALAPPDATA%\firestore\` and `cmdkey /list` show separate entries per app name
4. **Sign-in isolation.** Sign B into a QA account, then out. A is still signed in after a restart, and A's local store is untouched (§3 hazard).
5. **Release ignores it.** A release build launched with `VOYAGER_PROFILE=b` behaves as the default instance: it hits the existing mutex and focuses the running app.

---

## 9. How sync testing would use it (sketch, not in scope)

- A and B signed into the same QA account. A scenario script drives one instance via `voy.ps1 -Profile`/`vm.ps1 -Profile`, waits for the outbox to drain (`pending_uploads_table` empty, read-only), then asserts on the other instance's database (read-only sqlite) and UI.
- Oracle: the existing whole-account check (`full_sync_check.dart`, Dev → sync compare) run in each instance, plus a direct row diff of the two databases.
- Offline: `FirebaseFirestore.instanceFor(app: voyagerFirebaseApp).disableNetwork()` / `enableNetwork()` in one instance via `evalc`. This doesn't flip `ConnectivityStatusController`, so the offline badge and the reconnect path in `_onConnectivityChanged` need a separate check, or a real network cut.
- Candidate areas: concurrent journal edits (character-op merge), concurrent reorders (fractional index), delete-vs-edit, trash and undo across devices, settings that must and must not sync, media upload and download, reminder delivery and acknowledgement across devices, catch-up after one instance has been closed, restore on one device propagating to the other.

---

## 10. Open questions

1. **Debug-only, or also profile-mode builds?** Debug-only is the decision above. Profile-mode frame timing across two instances would need the runner guard relaxed to "not a release build".
2. **Toast activation with two instances under one AUMID.** Accept whichever one Windows activates, or give profiles their own AUMID (`Voyager.App.<name>`)? The latter needs a matching Start-menu shortcut registration in the plugin, so it's probably not worth it.
3. **Move QA sessions into a profile by default (§7)?** That's safer for Juno's real install, but it changes the documented session procedure in `qa/PROGRESS.md`.
4. **Auto-backup in a profile:** on (decided above), or off to save disk churn during long test runs?
