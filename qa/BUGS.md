# Voyager QA Audit — Bugs

<!-- SUMMARY: written by the Final Review phase (counts by severity and by phase). -->

Append-only findings log. Observations only: no proposed fixes, no code.
Number IDs sequentially; check the last ID before adding one. To mark a
duplicate or a status change, add a line to the entry's Notes; never delete entries.

Entry format:

```
### BUG-### [Phase X] Short title
- Severity: Blocker / Major / Minor / Cosmetic
- Found: <date>, Phase <N>
- Steps to reproduce: (start from the baseline state)
- Expected:
- Actual:
- Notes: (screenshots, logs, suspected scope)
```

---

### BUG-001 [Phase 1] Signing in after a signed-out launch leaves sync signed out until restart
- Severity: Blocker
- Found: 2026-09-27, Phase 1 (seen by Juno between sessions, on the real account)
- Steps to reproduce: from the baseline state (signed out, local data wiped), launch Voyager, sign in with e-mail and password on the login page, and leave the app running.
- Expected: the startup pull downloads the account's cloud copy, and Dev page → Sync backlog shows the queue.
- Actual: the app stays empty. Settings → Account shows the right e-mail ("Signed in with email and password"), while Dev page → Sync backlog says "Signed out — nothing is queued." The pull "succeeds" with nothing: the device registration row (written only after the startup pull completes) appeared at 23:01:03, `voyager_errors.log` logged nothing, and the only calendar was the locally created `__legacy_calendar__`. Restarting without signing out brought the data back (46 journals, 122 calendar events, 23 to-do lists, 164 study cards, …).
- Notes: cause: `syncRepositoryProvider` (`lib/app/providers.dart`) watched only `authRepositoryProvider`, which is one object for the app's lifetime. If the provider was built while signed out, it kept `NoOpSyncRepository` after sign-in. The root widget builds it at launch through `connectivityStatusProvider`. Scope: every harness session that signs in with `login.ps1` has run in this state, so any QA account's recorded cloud contents (e.g. qa-001 "Empty") are suspect, and writes made in such a session may never have reached the cloud (not verified). Fixed in the working tree on 2026-09-27; regression test `test/sync_repository_auth_switch_test.dart`.
- Notes (2026-09-27, consequence): **synced settings were reset to defaults.** During the stuck session, the local settings row (all defaults) was saved at 2026-09-28T03:10:05Z (23:10 local). Settings merge last-write-wins on the whole document (`mergeSettingsFromRemote`), so that newer clock beat the real settings (last changed 2026-09-27T01:38:30Z per the 00:57 auto-backup), and the next pull kept the defaults. The following launch (23:08, signed in from the start, so a real repository) probably uploaded the defaults over the cloud copy (not verified; Firestore wasn't read directly). Lost: theme/background (triangle texture and wave tuning), accent color, LeetCode username, and every other synced setting. The pre-wipe auto-backups in `C:\Users\Juno\VoyagerQA-localonly-backup-2026-09-27\backups\` still hold the real values.

### BUG-002 [Phase 1] Full startup pull saturates Firestore: false "offline" badge and a pull that stalls
- Severity: Major
- Found: 2026-09-27, Phase 1 (seen by Juno between sessions, on the real account, restoring from the cloud after the QA wipe)
- Steps to reproduce: wipe local data (`reset.ps1`), launch, and sign in to an account with a large cloud copy (here: 312 journal entries, 494 to-do tasks, 15,421 `sync_operations` docs). Watch the nav rail and `journal_entries_table` during the first startup pull.
- Expected: the pull completes in reasonable time, and the rail shows offline only when the network is actually down.
- Actual: the red no-wifi badge came on and stayed on although the network was fine. Windows logged no Wi-Fi disconnect, the PC reached `firestore.googleapis.com` instantly, and the app kept its one connection to Google up the whole time. The pull stalled: `journal_entries_table` sat at 233 of 312 for minutes, and no `[sync] pullAll took` line was ever printed. The "Journal" journal showed 6 of its 14 entries. Probed through the VM service at ~23:33: a `Source.cache` read answered in 4 ms, but a `Source.server` read of `meta/ping` got no answer for 99 s. Count queries (which bypass the local cache) answered in ~4.5 s. One native thread in the app was at 100% CPU (3.9 s of every 4 s), the process was at ~4.5 cores and 1.2 GB, and the Dart isolates were nearly idle. After `disableNetwork()`/`enableNetwork()` (enable took 23.7 s), the server read succeeded 37 s later, journal entries completed to 312 within a few minutes, and to-do tasks advanced about 1 per second. The single hot thread stayed at 100% throughout, and the badge was still red at 23:41.
- Notes: the connectivity probe (`ConnectivityStatusController`, 8 s timeout, `SyncRepository.ping` = one `Source.server` doc read) can't tell "Firestore is busy" from "offline". It shares the Firestore client with the pull, so the badge follows the pull's load, not the network. No sync read in `remote_sync_service.dart` / `firestore_sync_repository.dart` has a timeout, so a stuck read stalls the pull silently (nothing reaches `voyager_errors.log`). The pull requests every document's operation log up front (`_fetchOperationLogs`, 16 at a time, one `sync_operations where documentId ==` query each). With 15k operation docs, this is the prime suspect for the pegged native thread, but it isn't proven (no native profile taken). It's also unproven whether the pre-toggle stall was a stuck stream or starvation. The pull did resume right after the network toggle. Related: BUG-001 (the same recovery session).
- Notes (2026-09-28, measured): **not a debug-build artifact.** With the local data complete and Firestore's disk cache warm, every watermark was aged 8 days (with Juno's permission) and the app was launched as a **profile** build: `[sync] pullAll took 398838ms: 2880 docs from 58 collections, 58 pulled whole. Slowest: todo_tasks 396782ms (494, full), journal_entries 393455ms (312, full), study_cards 4975ms (164, full)`. The other 56 collections took under 5 s each. The two slow collections are exactly the ones that fetch a per-document operation log (806 `sync_operations where documentId ==` queries), at about 0.5 s per query through the single Firestore worker. Debug probes the night before (VM service, warm cache): a query already run earlier answered in 98 ms, a new one returning 0 docs took 1.5–1.8 s, `whereIn` over 30 ids (657 docs) took 38.5 s, and `orderBy`+`limit(1000)` pages took 60 s and 22 s. Batching or paging doesn't help. The `lib/core/sync/remote_sync_service.dart` comment on `_fetchOperationLogs` records 456 todo tasks taking 81 s before concurrency was added. Amplifier: when the badge flips offline→online, `_resumeSyncAfterReconnect` (`lib/main.dart`) starts another `pullAll`, which can overlap a pull already running.
- Notes (2026-09-28, fixed in the working tree, uncommitted):
  - The offline probe (`FirestoreSyncRepository.ping`) is now an HTTPS `HEAD` to `firestore.googleapis.com` instead of an SDK read.
  - A reconnect pull waits behind the startup pull (`lib/main.dart`).
  - A weekly full pull skips journal entries, dream entries and to-do tasks that this device holds at the listed revision (version, `updatedAt`, `deletedAt`) and whose operation log has no operation since the last full pull minus one day (a single `sync_operations where timestamp >=` query). If that query fails, nothing is skipped. Documents open in an editor are never skipped.
  - Tests: `test/sync_full_pull_skip_test.dart`, `test/firestore_ping_test.dart`. The skip test fails without the fix.
  - Re-measured the same way (profile build, watermarks aged 8 days): `pullAll took 13103ms: 2880 docs from 58 collections, 58 pulled whole`, down from 398838 ms. Journal entries were 131 rows (75 deleted) before and after, the outbox was empty and no errors were logged.
  - Not fixed: a first pull onto an empty device still resolves every log, so a restore still takes minutes.
  - Not observed directly: the badge's colour during the pull.

<!-- Last ID: BUG-002. -->
