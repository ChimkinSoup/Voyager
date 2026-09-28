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
| 6 | Import, export & backups | `lib/features/settings/services/**`, `lib/features/settings/backup_list_dialog.dart`, `lib/features/settings/settings_page.dart` (file picker/import handlers), `lib/domain/services/calendar_event_import.dart`, `lib/domain/services/color_palette_codec.dart` | Attacker D: zip-slip / path traversal in entry names on import and restore (`data_import_service.dart:331`, `auto_backup_service.dart:695`), manifest-driven file writes/deletes, backup filenames used in paths, deserialization of imported JSON into rows (IDs that later become paths or remote doc paths), imported data being pushed to Firestore under another uid, calendar file parsing reaching sinks. | TODO | |
| 7 | Media pipeline | `lib/core/media/**`, `lib/data/services/media_file_store.dart`, `lib/data/remote/firebase_media_storage.dart` | Command injection in `Process.run('powershell', …)` (~175) / `df` (~193) — what path/argument reaches them; `contentHash`/format from synced or restored records → local file path and Storage path (verify `_isBareName` covers every call site); drag-drop/paste file paths (attacker D) → reads of arbitrary files that then upload to cloud; hash verification of downloaded blobs. | TODO | |
| 8 | Local database & repositories | `lib/data/database/app_database.dart`, `lib/data/repositories/drift_repositories.dart`, `lib/domain/repositories/**`, `lib/features/search/**` | SQL injection: every `customStatement`/`customSelect`/`customUpdate`/string-built SQL, LIKE/FTS `MATCH` built from search text or synced values; migrations that interpolate values. Trace whether any interpolated value is attacker-controlled (D/F), not just user-typed. | TODO | |
| 9 | External content & URL handling | `lib/data/remote/leetcode_api_client.dart`, `lib/data/remote/leetcode_content.dart`, `lib/features/leetcode/**`, `lib/features/jobs/**`, `lib/data/services/quotes_loader.dart`, `lib/core/text/**` (link/markdown rendering), any other `launchUrl` call site | Attacker D/E/F: URLs from imported/synced/third-party data passed to `launchUrl` without scheme allow-listing (`file:`, `ms-*:` handlers, `javascript:`) at `jobs_page.dart:439`, `jobs_edit_panel.dart:453`, `leetcode_detail_view.dart:303`, `leetcode_actions.dart:312`; GraphQL query construction from user input (injection); HTML parsing of LeetCode content reaching a renderer or file. | TODO | |
| 10 | Desktop/Android platform & IPC | `windows/runner/**`, `lib/core/platform/**`, `lib/features/hotkeys/**`, `lib/core/reminders/**`, `lib/features/notifications/**`, `lib/core/session_resume/**`, `lib/main.dart`, `android/app/src/**` | Attacker C: registered window messages broadcast to `HWND_BROADCAST` (can any process trigger quit/show or more?), single-instance mutex squatting, command-line args, launch-at-login registry value (`launch_at_login.dart` — quoted path? path from where?), app data dir permissions/location, notification payloads → actions, session checkpoint files read back and trusted. Android: exported components, `allowBackup`/extraction rules exposing the DB. | TODO | |
| 11 | Dev/debug surfaces & logging | `lib/core/dev/**`, `lib/features/dev/**`, `scripts/purge_out_of_sync_journal_entries.ps1` | Whether dev tools (remote purge, weather API tile, sync compare) are reachable in release builds and what they can do; secrets/tokens or journal contents written to world-readable log files (e.g. under Documents); log injection only if a log is later parsed/acted on. | TODO | |
| 12 | Residual sweep: domain & remaining features | `lib/domain/**`, `lib/features/**` and `lib/core/**` not covered above | Grep-driven sink sweep, not line-by-line: `Process.`, `File(`, `Directory(`, `jsonDecode`, `launchUrl`, `Uri.parse`, `http.`, `Random(`, `sha`/`md5`, `==` on secrets/tokens. Anything found that belongs to an earlier section goes to Cross-Section Leads if that section is DONE. | TODO | |

## Findings

_None yet._ Template:

```
### [SEVERITY] Short title — Section N
- Class: (e.g. SQL injection)
- Location: file:line
- Exploit path: source (file:line) → ... → sink (file:line)
- Preconditions: (auth required? which role? which config?)
- Proof of concept: (example request or input)
- Fix: (short)
```

### [LOW] Desktop Google sign-in has no `state`, so login CSRF can route new entries into the attacker's account — Section 2
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

## Cross-Section Leads

_None yet._ Format: `- [→ Section N] <flow>, seen at file:line (from Section M).`
Append `→ resolved: <outcome>` when the receiving section handles it.

- [→ Section 3] Attacker A is trivially available: self-signup via `createUserWithEmailAndPassword` (`lib/data/remote/firebase_auth_repository.dart:65`) plus Google sign-in, so any stranger can call the `onCall` weather functions with their own token. Check for per-uid rate limiting or quota guarding on the OpenWeather key (backend cost). (from Section 1) → resolved: there is none. The handlers only check `request.auth` (`functions/src/index.ts:57,97,161`), with no App Check, per-uid limit or `maxInstances`. Quota or cost abuse is DoS, which is out of scope, so this is recorded in the Section 3 notes rather than as a finding.
- [→ Sections 5, 6, 7] Synced Firestore/Storage data is **not** attacker input from other users (see Ruled Out, Section 1). Treat it as untrusted only if it arrives via D (import/restore → sync → other device) or E. (from Section 1)
- [→ Section 5] The local DB is not keyed by uid, and sign-out doesn't clear it. After an account switch, the outbox drains queued rows under the *new* uid (`lib/core/sync/outbox_sync_worker.dart:192,292`). Check whether a pull under the new uid can overwrite or merge the previous account's local rows in a way that matters beyond the Section 2 finding. The `syncBackfillVersion` gate is per device, not per uid (`lib/core/sync/remote_sync_service.dart:6073-6074`). (from Section 2) → resolved: nothing beyond the Section 2 finding goes *up*. Watermarks are keyed by uid (`lib/core/sync/sync_watermark_store.dart:27,36`). The backfill runs once per device and re-pushes only snippets and v1 collections (`remote_sync_service.dart:6072-6096`), so a switch doesn't bulk-upload the old account's rows. What does matter is the other direction: the pull under the new uid merges that account's documents into the shared local DB. In the login-CSRF scenario those are attacker-written. Fixed ids (`settings/app` at `firestore_sync_repository.dart:164`; `legacy-default-journal` and `legacy-default-todo-list` at `lib/core/constants/journal_constants.dart:6`, `todo_constants.dart:6`) let the attacker overwrite or tombstone the victim's matching local rows without guessing ids. See the leads below. Recorded as extra impact of the Section 2 finding, not as a separate finding.
- [→ Sections 7, 9] F is attacker-written if the Section 2 login-CSRF succeeds: the victim's device pulls `users/<attackerUid>/...` into its local DB. It stays there after the victim signs back into their own account, since sign-out doesn't clear the DB. When assessing remote-sourced fields, treat this as a (LOW-precondition) attacker path alongside D. Fields that reach your sinks: media `contentHash` (`lib/core/sync/firestore_document_mapper.dart:926`) → local and Storage paths (§7). Job `applicationUrl` (`:1477`) and settings `jobProfileLinkedInUrl`/`GitHubUrl`/`PortfolioUrl` (`:3841-3846`) → `launchUrl` (§9). Settings `leetcodeUsername` (`:3847`) → LeetCode GraphQL (§9). (from Section 5)
- [→ Final Consolidation] When consolidating, add the Section 5 pull-side impact to the Section 2 login-CSRF finding. The attacker's fixed-id `settings/app` and legacy journal/todo-list docs merge into the victim's local DB (integrity loss), and attacker-chosen URLs and `contentHash` values reach the victim's device. (from Section 5)

## Ruled Out

_None yet._ Format: `- <pattern checked> — safe because <reason>, verified at file:line (Section N).`

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

## Final Consolidation

- [ ] All open Cross-Section Leads processed
- [ ] Duplicate findings merged
- [ ] Findings sorted by severity
- [ ] Summary written at top of file
