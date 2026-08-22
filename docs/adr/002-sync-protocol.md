# ADR 002: Sync Protocol Boundaries

## Status
Accepted

## Context
Journal edits are debounced; to-do updates require live propagation.

## Decision
- Debounced document sync for journal and analytics payloads (default 3 seconds).
- Immediate Firestore writes + watchers for to-do list changes.
- Google Calendar ingest is read-only and guarded by a Firestore lock document.

## Consequences
- Two sync paths with explicit repository contracts.
- Conflict resolution uses operation-log sequence CRDT merging.

## Amendment: Jobs hard delete (2026-08-22)

### Context
JOBS.md §7.4 specifies hard delete for job applications — an exception to the
app-wide soft-delete default — and §9 requires that "sync must propagate true
deletes". The sync layer has no mechanism for this. `FirestoreSyncRepository.
watchCollection` filters out `DocumentChangeType.removed`, and `_pullCollection`
only ever applies documents that still exist, so a deleted Firestore document
is invisible to every other device. `RemoteSyncService.permanentlyDeleteFromRemote`
exists but is one-way: it is used by the manual journal/dream purge flow and
leaves other devices' local rows in place. A literal hard delete would therefore
leave a live row on every other device, and the next full push from any of them
would resurrect the application on the device that deleted it.

### Decision
Job applications are deleted as **content-wiped tombstones**, not as removed
rows. `JobRepository.deleteApplication` sets `deletedAt`, blanks every content
field (`company`, `title`, `status`, `applicationUrl`, `notes`, `seasonId`), and
tombstones the application's `JobStatusEvent` rows with it. The tombstones sync
through the ordinary snapshot path like every other collection, and
`BackgroundSyncOrchestrator.purgeExpiredDeleted` drops them on the standard
`softDeleteRetentionDays` (30) retention.

Rejected alternatives: a literal row delete plus `permanentlyDeleteFromRemote`
(correct on one device, silently self-undoing across devices); and a dedicated
`job_deletions` marker collection with its own pull handler and purge policy
(correct, but new sync machinery no other feature uses).

### Consequences
- From the user's side this is a hard delete: the application disappears from
  every view on every device, there is no recycle bin, and the content is
  unrecoverable the moment the confirm dialog is accepted.
- A deleted application occupies one id-and-timestamps row per device for up to
  30 days. Nothing reads it — every Jobs query defaults to `includeDeleted: false`.
- Jobs adds no new sync path. All six of its collections are snapshot-only, so
  they inherit version-then-`updatedAt` conflict resolution and write no
  operation log.
