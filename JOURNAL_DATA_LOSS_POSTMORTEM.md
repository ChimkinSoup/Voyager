# Journal body loss — 2026-09-16

Entry `34067e9d-1d16-490b-a0ea-1acad7db9498` ("There Are Levels To This") lost
its body. Recovered in full. Two separate defects were involved, one of which is
fixed and one of which is not.

## What happened

At `05:01:39Z`, while empty test entries were being deleted in quick succession,
the entry was saved with an empty body and a bumped version. It kept its title,
its image and its `mood`; `deleted_at` stayed null. It was never deleted — soft
delete had nothing to recover because this was an ordinary save.

Nothing on screen reported a problem. The loss was noticed later, by which point
the local row held `body = ''` at `version = 10`.

## Root cause

Two defects that individually are survivable and together are not.

### 1. A save whose target and payload came from different owners

`_flushActiveEntryEditsImpl` (`journal_page.dart:1089`) builds a write from
three sources:

```dart
final entryId = _selectedEntryId;                     // page state
final title  = _titleController.text;                 // page state
var body = _editorKey.currentState?.currentBodyText   // child widget state
    ?? _entryBodyDrafts[entryId] ?? entry.body;
```

`_selectedEntryId` and `_titleController` are set together and synchronously in
`_selectEntryFields` (`journal_page.dart:1285`), inside `setState`. The body is
not: it lives in `_PlainJournalEditor`'s own `TextEditingController`, seeded by
`_switchEntryWidget` (`journal_page.dart:3262`) — which is `async` and awaits the
page's in-flight flush *before* it assigns the new text:

```dart
_detachEntry(oldWidget.entry?.id);
final pendingFlush = widget.waitForFlush?.call();
if (pendingFlush != null) await pendingFlush;   // window opens
...
_controller.text = widget.entry?.body ?? '';    // new body lands here
```

The editor waits for the flush; the flush reads the editor. For the length of
that await the page names the incoming entry while the controller still holds
the outgoing one, and `currentBodyText` — a bare `_controller.text` getter —
carries no entry identity to catch the mismatch. The editor *does* track one
internally (`_attachedEntryId`); the getter simply doesn't consult it.

Result: **incoming entry's id + incoming entry's title + outgoing entry's body**,
written with `bumpVersion: true`. Because the previous selection was an empty
test entry, the outgoing body was `''`.

This is the third appearance of the same class. `dispose()`
(`journal_page.dart:3301`) already documents the window — *"`widget.entry`, which
during a switch already names the incoming entry"* — and the `_bodySaveTimer`
comment (`journal_page.dart:1083`) describes the identical failure for the
autosave timer, which was fixed by cancelling the timer inside the flush.

### 2. A wedged Firestore write queue held the window open

The await above was `flushDocument`, which waited on a Firestore server
acknowledgement. Firestore accepts a write into a local queue immediately and
only completes the future on ack; with the write stream wedged, that future
never completed. A window normally microseconds wide became unbounded.

The stream was wedged because roughly 190 write batches had accumulated
unacknowledged, and the backend had begun refusing the whole stream with
`RESOURCE_EXHAUSTED: Write stream exhausted maximum allowed queued writes` —
reconnecting, re-sending the same backlog, being refused, looping. Contributing
factors: batches chunked at 500 (the `WriteBatch` limit, not the stream's queue
limit, and several batches fly at once); operation-log compaction re-firing on
every hot restart because its guard was in memory; and nothing anywhere bounding
or even measuring the queue.

**The frozen entry switching and the data loss were the same window.** Switching
froze because the flush never returned; the flush never returned because of the
backlog.

## Recovery

`sync_operations` embeds a full document snapshot on every save, so the stranded
queue held twenty successive versions of the entry being typed — 30 characters
up to 1244. Extracted from the leveldb cache at
`%LOCALAPPDATA%\firestore\[DEFAULT]\<project-id>\main` by scanning the `.ldb`
files for `"body":"` and JSON-decoding to `","richBodyJson"`. The write-ahead
log needs its 32 KiB block framing stripped first (4-byte checksum, 2-byte LE
length, 1-byte type) or strings spanning a block boundary are invisible.

Restored to SQLite at `version + 1` with a fresh `updatedAt`, so the repair
outranks anything a later pull brings down.

**`clearPersistence()` would have destroyed this permanently.** The wedged cache
was the only copy of the text — it had never reached the server, and the normal
save path does not route through the outbox. Back the cache directory up before
touching it.

## Fixed

- **`FirestoreWriteGate`** (`lib/core/sync/firestore_write_gate.dart`) bounds
  writes handed to Firestore before acknowledgement: 50 normally, 10 until
  `waitForPendingWrites()` confirms the inherited queue drained. Without that
  second limit a per-session counter lets each restart stack a fresh allowance
  onto a backlog it cannot see. Refusals throw `SyncBackpressureException`,
  which classifies as transient, so existing failure paths park the write on
  `pending_uploads_table` — a queue that can be measured, capped and drained in
  order.
- **Batches chunk at 40**, not 500.
- **`compactOperationLog` stands down** when `SyncRepository.hasUnsentWriteBacklog`
  is true, so housekeeping stops piling onto a queue that is not moving.
- **Dev page → Sync backlog** shows in-flight, peak, writes deferred to the
  outbox, and the outbox rows themselves.
- **`flushDocumentLocal`** replaces `flushDocument` at the entry-switch
  commitment point, so switching no longer waits on the network.

- **The gate is shared, not per-repository** (`firestoreWriteGateProvider`).
  It bounds writes to the Firestore *client*, which is one process-wide object
  with one write stream and one local queue. A gate built inside
  `FirestoreSyncRepository` was also rebuilt whenever auth changed, handing the
  backend a fresh allowance on sign-out and back in — the same mistake
  `hasStartupBacklog` exists to stop across restarts.
- **`OutboxSyncWorker` writes through that gate too**, and chunks at
  `firestoreWriteChunkSize`. It had been the one unbounded writer in the app:
  it goes straight to Firestore rather than through the repository, in batches
  of up to 500 — the exact shape that wedged the stream — and it is where
  *refused* writes land, so it was the last thing that should have been pushing
  past the bound. A paused gate now stops the drain outright instead of
  bouncing every row back into the queue it came from.

Covered by `test/sync_write_backpressure_test.dart`, a stand-down case in
`test/sync_op_log_compaction_test.dart`, two outbox cases in
`test/sync_outbox_routing_test.dart` (a round wider than one chunk drains every
row; a paused gate stops the drain), and the batch-width assertion in
`test/import_export_test.dart`, which previously asserted the 500-wide
behaviour.

## Fixed: the gate had no way back — 2026-09-16

The gate as first written bounded how many writes it *admitted* but nothing
about how long an admitted one could take. A write handed to a wedged stream
never comes back: `run`'s counter is released in a `finally` that never runs, so
the slot is held for the life of the process. Ten hangs and the gate refuses
everything, permanently — and a restart inherits the same wedge, so the tighter
startup allowance fills the same way within seconds. Observed as an endless

```
Sync paused: 10 writes are still waiting for the server (limit 10).
WARNING: WriteStream (…) Stream error: 'Resource exhausted: …'
```

with the dev tile reading `10 / 10` and `deferred to outbox 50`. Nothing was
lost — the refusals were reaching the outbox exactly as designed — but nothing
was reaching the server either, and nothing ever would have.

- **`FirestoreWriteGate.writeTimeout`** (45s) bounds an admitted write.
  Firestore cannot withdraw a queued write, so the write is still down there and
  still arrives if the stream recovers; the timeout only stops the gate waiting
  on it. Double delivery is safe both ways the app writes: mirrored documents
  are `set(merge: true)` on a fixed id, and operation-log entries carry
  character operations that `CharacterSequenceCrdtMerger` dedupes by operation
  id — ids `restorePendingOps` hands back unchanged, so a retry re-sends the
  same ops rather than minting fresh ones at the same fractional positions.
- **A timeout latches the gate shut** (`_stalled`, limit 0). This is the half
  that matters. Freeing the slot on its own would let the gate feed a fresh
  batch into the same stopped queue every 45 seconds — the original backlog,
  dug more slowly. `OutboxSyncWorker.startDraining` already breaks on
  `isPaused`, so the drain stands down with it.
- **The latch comes off when `waitForPendingWrites()` is next seen to complete.**
  A stall arms its *own* probe rather than waiting on the one from launch: in
  the case this exists for, the launch probe is precisely the one that is never
  going to answer. (Written the other way first, guarded by a single
  `_probePending` flag; the reopen test caught it.) This is the only available
  reading — the writes holding the queue open are invisible to `_inFlight`, and
  the gate cannot probe by attempting a write, because attempting is what
  deepens the queue.
- **Dev tile** distinguishes stalled from merely paused, and counts timeouts.

## Fixed: todo writes that failed in silence

`pushTodoTaskNow` returned its upload future raw, alone among the push methods —
every sibling wraps in `_runRemoteSave`. Twelve call sites in
`todo_edit_panel.dart` and `todo_page.dart` dropped that future, so a failed
todo write escaped to the zone as an unhandled error *and* never reached the
outbox: the task stayed unsynced with nothing recording that it had tried. This
is what the `Unhandled Exception` copies of the backpressure trace were — the
ones whose stack ends at `_uploadCrdtDocumentNow` with no `_runRemoteSave`
frame beneath it.

Wrapping `pushTodoTaskNow` itself would have been wrong. Three callers await it
and two need the throw: `TodoWriteCoordinator.saveTask` runs it *inside* a
`_runRemoteSave` of its own, which would then record success for a failed write
and clear the outbox row standing for it; the To-Do page's cascade attaches its
own `catchError`. So the awaitable stays as it is and the fire-and-forget sites
now call **`pushTodoTaskInBackground`**, which wraps.

Covered by the `write gate stalls` group in
`test/sync_write_backpressure_test.dart`.

## Fixed: nothing resumed the drain when the gate reopened

`startDraining` breaks out of its loop on `_writeGate.isPaused`, which is right
— the outbox is where refused writes land, so pushing them back at a stopped
queue only bounces them into the queue they came from. But nothing started it
again. The drain runs at launch, on sign-in, on app resume and on the
offline→online edge (`main.dart:76`, `:100`, `:337`), and a gate reopening
mid-session is none of those, so rows sat queued until the user happened to
alt-tab away and back.

That gap matters most for the stall latch above, whose reopening is a
`waitForPendingWrites` probe resolving — an event with no user-visible cause at
all. `OutboxSyncWorker` now listens to the gate it already holds and drains on
the reopening *edge*, ignoring the notification per admitted write.

Covered by `the gate reopening drains the rows it stopped for` in
`test/sync_outbox_routing_test.dart`.

## Fixed: the default calendar could never sync

`calendars/__legacy_calendar__` sat parked on the outbox with
`[invalid-argument] Resource id "__legacy_calendar__" is invalid because it is
reserved`. Firestore rejects document ids using reserved `__` segments, and
`calendar_constants.dart` justified the shape with *"Calendars are local-only
(no Firestore sync), so no Firestore-safe alias is needed."* That stopped being
true when calendars joined `backfillSyncedCollections` and
`drainableCollections`, and the comment was never revisited.

Journals and to-do lists both hit this and both solved it the same way, so
calendars now get the same alias: `legacyCalendarFirestoreId`
(`'legacy-default-calendar'`) plus to/from mappers, wired into
`firestoreDocumentIdForLocal`, `mediaOwnerDocumentIdFromFirestore`,
`RemoteSyncService._localDocumentId`, `calendarToFirestore`, and the
`calendarId` field on events.

No migration is needed: the reserved id was never accepted, so nothing is
stored under it. Events already synced carry the raw local id in their
`calendarId` *field* — which was never rejected, being a value rather than an
id — and `calendarDocumentIdFromFirestore` passes unrecognised values straight
through, so both spellings resolve.

Three copies of this local↔remote id mapping now exist
(`firestoreDocumentIdForLocal`, `mediaOwnerDocumentIdFromFirestore`,
`RemoteSyncService._localDocumentId`), all of which had to be updated together.
That divergence is how calendars were missed; worth collapsing.

Covered by two cases in `test/firestore_document_mapper_test.dart`.

## Fixed: the stale-buffer read

`_PlainJournalEditorState` now tracks `_bodyEntryId` — the entry its controller's
text actually belongs to — set unconditionally wherever the controller is seeded
(`initState` and `_switchEntryWidget`). It is deliberately separate from
`_attachedEntryId`, which tracks the *sync* registration and is left alone when
there is no sync service to register with.

- `bodyTextFor(entryId)` returns the text only when it is that entry's, and
  logs `BODY_BUFFER_ENTRY_MISMATCH` to `journal_debug.log` when it refuses. The
  three writing call sites (the flush, the body autosave, the remote-compare
  dialog) fall through to `_entryBodyDrafts[entryId] ?? entry.body`, both
  entry-keyed.
- `_handleChanged` now files drafts under `_bodyEntryId` rather than
  `widget.entry?.id`. A keystroke inside the switch window was otherwise
  filing the outgoing entry's text under the incoming entry's draft —
  poisoning the very fallback above — and recording it against the wrong CRDT
  document.
- `_debugSnapshot` deliberately keeps the *unqualified* read, via
  `rawBodyTextForDebug`. That snapshot exists to report what the editor is
  actually holding; qualifying it would hide the mismatch it is there to catch.

### The same shape in the dream journal

`dream_journal_page.dart` carried the identical primitive — a bare
`currentBodyText` getter read at three writing sites. It was not reachable
there, for three reasons worth keeping: `_selectEntry` awaits the flush
*before* the `setState` that moves the selection, flushes take their target as
an explicit `entry:` argument rather than reading page state mid-flight, and
`_DreamBodyEditor.didUpdateWidget` is synchronous where the journal's
`_switchEntryWidget` awaits. So it satisfied half the standing rule below —
the target was owned, the payload was not — and was safe by ordering
discipline rather than by construction, with no alarm if that ordering ever
changed.

It now has the same `_bodyEntryId` / `bodyTextFor` guard, and
`recordDreamTextChange` is keyed by the buffer's owner in both
`_handleChanged` and `setBodyText`, since both diff the controller's own text.
The mismatch logs through `debugPrint` under `kDebugMode`; unlike the journal
page there is no `onDebugLog` seam and no dream debug log to write to.

### No regression test, and why

Two candidate widget tests were written and **deleted**: they passed with the
guard removed, so they proved nothing. Reproducing the interleaving needs the
page to change selection while a flush is genuinely in flight, and every
selection path (`_loadEntry`, the delete path) awaits its flush first and clears
`_flushInProgress` before selecting. The window only opens when an *unawaited*
flush is outstanding — `_handleBodyFocusChanged` — which in turn needs a stalled
write staged underneath a focus change staged underneath a delete. That was
judged too brittle to be worth trusting.

The `BODY_BUFFER_ENTRY_MISMATCH` log line is the compensating control: a
recurrence names itself instead of silently losing text. If this is ever worth
a proper test, the lever is an instrumented `JournalRepository` that stalls
`softDeleteEntry` while the body loses focus.

## Standing rules

- A write's target and its payload must be captured together, from one owner. An
  id from page state and a body from a child widget on its own async lifecycle
  will eventually disagree.
- Every fire-and-forget upload goes through `_runRemoteSave`. A dropped future
  loses the failure twice: unhandled in the zone, and absent from the outbox.
- A bound on a resource needs a way back as well as a way in. Refusing to dig
  deeper is not recovery if nothing can ever fill the hole back in.
- Never `clearPersistence()` to unwedge Firestore. Back up
  `%LOCALAPPDATA%\firestore\` first; unsent edits live only there.
- Keep `journal_debug.log` enabled while this area is in flux. It began at
  `05:03:47Z`, four minutes after the wipe, so the cause above is reconstructed
  from code and row state rather than from a recorded trace.
