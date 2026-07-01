# Voyager release checklist

Use this before calling remote sync **release-ready**. A clean compare on one device is necessary but not sufficient.

## What sync covers

Firestore remote sync applies to:

- Journals
- Journal entries (body uses character-level CRDT ops)
- Todo lists
- Todo tasks
- Some settings (weather location, etc.)

**Not** synced via the main Firestore pull/push pipeline:

- Calendar events (local + Google Calendar integration)
- Trackers / rankings

---

## Quick pre-flight (single device, ~5 min)

Run in **Developer tools → Remote sync compare**:

1. **Compare all journal entries** — expect all matched.
2. **Compare all todo lists** — expect all matched.

Both buttons flush pending local edits and uploads before comparing.

Log file: `Documents/sync_compare.log` (Windows) / app documents directory.

---

## Two-device sync validation (required before release)

Use two devices signed into the **same account** (e.g. Windows desktop + phone, or two desktops). Complete all steps on a **test account** or test data you can delete.

### Setup

- [ ] Device A and Device B both signed in
- [ ] Both on a build that includes the latest sync code
- [ ] Note Device A and Device B names in the log below

### A. Journal — create and propagate

| Step | Device A | Device B | Pass? |
|------|----------|----------|-------|
| 1 | Create journal entry titled `Two-device test A` with body `hello from A` | — | |
| 2 | Wait ~5 s (or switch away from entry to flush) | Confirm entry appears with same title and body | |
| 3 | — | Edit body to `hello from B` | |
| 4 | Wait ~5 s | Confirm body updated to `hello from B` | |

### B. Journal — concurrent edit (CRDT stress)

| Step | Device A | Device B | Pass? |
|------|----------|----------|-------|
| 1 | Open same entry on both devices | Open same entry | |
| 2 | Go offline on both (airplane mode / disable network) | Go offline | |
| 3 | Append ` A-offline` to body | Append ` B-offline` to body | |
| 4 | Reconnect A, wait for sync | Reconnect B, wait for sync | |
| 5 | — | Final body contains **both** edits (order may vary); no garbled duplication like `arstarstarst` | |
| 6 | Run **Compare all journal entries** on both devices | Same | All matched; no `opChainValid=false` in log |

### C. Journal — metadata

| Step | Device A | Device B | Pass? |
|------|----------|----------|-------|
| 1 | Change title, mood, or journal assignment on an entry | — | |
| 2 | Wait for sync | All metadata matches | |

### D. Todo — create and propagate

| Step | Device A | Device B | Pass? |
|------|----------|----------|-------|
| 1 | Create task `Two-device todo` in a list | — | |
| 2 | Wait for sync | Task appears | |
| 3 | — | Mark complete, change title | |
| 4 | Wait for sync | Changes reflected on A | |

### E. Todo — reorder and star

| Step | Device A | Device B | Pass? |
|------|----------|----------|-------|
| 1 | Reorder or star a task | — | |
| 2 | Wait for sync | Order/star state matches | |

### F. Offline → reconnect

| Step | Device | Pass? |
|------|--------|-------|
| 1 | Disable network | |
| 2 | Create one journal entry and one todo task | |
| 3 | Re-enable network, wait for startup sync | |
| 4 | Other device shows new data | |
| 5 | Compare all (journals + todos) on both devices | All matched |

### G. Fresh account restore

| Step | Pass? |
|------|-------|
| 1 | New account, create journal + todo data on Device A | |
| 2 | Sign in on Device B (empty local DB) | |
| 3 | After pull, all data present and compare-clean | |

### H. Conflict UI (optional but recommended)

| Step | Pass? |
|------|-------|
| 1 | Enable **Force conflict UI** in Developer tools | |
| 2 | Trigger a pull (restart app or manual sync) | |
| 3 | Conflict banner appears; resolution dialog works | |
| 4 | Disable force flag after testing | |

---

## CRDT / journal body checks

When **Compare all journal entries** reports a mismatch, check `sync_compare.log` for:

| Signal | Meaning |
|--------|---------|
| `body: local="…" remote="…"` | Resolved text differs between SQLite and Firestore CRDT merge |
| `remoteCharOps=N` | Number of character operations stored remotely |
| `opChainValid=false` | **Corrupted CRDT chain** — duplicate fractional positions in remote ops; treat as a release blocker for journal sync |
| `opChainValid=true` with only `updatedAt` diff | Usually benign (sub-second timestamp noise); compare uses second precision |

### Investigating a suspicious entry today

1. Run **Compare all journal entries** in Developer tools.
2. Open **View compare log** or read `sync_compare.log`.
3. Search for the entry ID or title.
4. If `opChainValid=false`, use **Remote purge** or **Purge out-of-sync journal entries** to remove bad remote + local data, then re-test.

There is no separate “replay CRDT ops” debugger yet; the compare log is the primary diagnostic surface.

---

## Known issue: `test` entry (`78726f1c…`) — CRDT vs keystroke duplication

### What we saw

- Local body: `arstarst`
- Remote body: `taerssttarst` (scrambled / interleaved characters)
- `remoteCharOps=24`, `opChainValid=false`

### Is this the same as the duplicate-keystroke bug?

**Related pipeline, different failure mode.**

| Issue | Described in | What it does | Symptom |
|-------|----------------|--------------|---------|
| **Keystroke / local save duplication** | `TYPING.md` | Queues many intermediate SQLite writes per character; UI rebuilds on every key | Slowness, jank, possible local races; body field may be stale vs draft |
| **Legacy snapshot → synthetic char ops** | `character_sequence_crdt_merger.dart` (fixed + tested) | Old code expanded full-document snapshots into duplicate fractional positions | Garbled remote text; `opChainValid=false` |
| **CRDT op chain corruption** | `WRITING.md` Phase 5, `sync_conflict_detector.dart` | Duplicate fractional positions in `sync_operations` | Remote merged body ≠ local body; invalid op chain |

The `test` entry pattern (`taerssttarst`, invalid op chain, 24 ops) matches **CRDT corruption on the remote op log**, not merely “typing felt laggy.”

Possible causes for that entry:

1. **Historical corruption** before the fix that stopped legacy snapshots from synthesizing char ops (`test/domain_services_test.dart`: `legacy snapshot operations do not synthesize duplicate char ops`).
2. **Concurrent editing / re-seeding** — `CharacterOpSession.resetFromText` re-seeds positions; overlapping uploads from races could poison the remote chain.
3. **Local keystroke thrashing** (`TYPING.md`) may have increased race windows but is not the direct cause of `opChainValid=false`.

That entry was **purged** during cleanup; a later compare (2026-06-28 03:17 UTC) showed **54/54 journal entries in sync**. You cannot re-inspect that document unless it still exists in Firestore (check Firebase console → `users/{uid}/journal_entries` and `sync_operations` filtered by `documentId`).

### Regression test to run before release

- [ ] `flutter test test/domain_services_test.dart` — CRDT merger tests pass
- [ ] `flutter test test/remote_sync_test.dart` — multi-device pull/push tests pass
- [ ] Two-device **concurrent offline edit** (section B above) produces clean merge, not garbled text

---

## Automated tests (CI / local)

```bash
flutter test test/remote_sync_test.dart
flutter test test/sync_integration_test.dart
flutter test test/domain_services_test.dart
flutter test test/crdt_document_resolver_test.dart
```

---

## Release decision

Sync is **ready to release** when:

- [ ] All two-device sections (A–G) pass
- [ ] Compare all journals + todos clean on both devices after testing
- [ ] No `opChainValid=false` in compare log during stress testing
- [ ] No unresolved conflict banners in normal use (without force flag)
- [ ] Automated sync tests pass

Until then: safe to build other features; treat journal body sync as **mostly working** with a known historical corruption class that should be watched via compare tooling.

---

## Test log template

```
Date:
Build / commit:
Device A:
Device B:

Journal create/propagate:     PASS / FAIL —
Journal concurrent offline:   PASS / FAIL —
Journal metadata:             PASS / FAIL —
Todo create/propagate:        PASS / FAIL —
Todo reorder/star:            PASS / FAIL —
Offline reconnect:            PASS / FAIL —
Fresh account restore:        PASS / FAIL —
Compare all (A):              PASS / FAIL —
Compare all (B):              PASS / FAIL —
CRDT opChainValid issues:     NONE / DETAILS —
Notes:
```



# Check import/export works, especially for todo lists, and deleting journals keeps journal count consistent