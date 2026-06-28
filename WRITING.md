## Master Low-Level Design: Offline-First Sync Engine

### Phase 1: The Unified Save Pipeline & Versioning

**Addresses:** Bug 1 (Race conditions), Bug 2 (Stale search snapshots), Bug 7 (Version lag), Bug 10 (Search upload bypass), Bug 11 (Draft memory leaks).

* **The `JournalWriteCoordinator`:** * Serialize all local SQLite writes through a single, strictly ordered queue to prevent field-level overwrites.
* **The Database Baseline Rule:** No UI element is allowed to execute a `copyWith` on a stale in-memory snapshot. Every write must fetch the latest row from SQLite (`getEntry`), apply the specific field delta, and upsert.


* **Unified Search Flow:** Update `search_page.dart` to funnel through the exact same debounced `saveJournalEntryThenScheduleUpload` pipeline as the main journal, strictly respecting the 1-second debounce queue.
* **Safe Draft Cleanup:** Wrap all local `upsertEntry` calls in a `try/catch`. Only clear `_entryBodyDrafts` upon a *successful* local database write. If SQLite throws an error, the draft remains in memory to prevent silent data loss.
* **Explicit Version Bumping:** Do not increment the document's `version` integer during background CRDT merges. Only bump the local version when the user actively finishes their edit session (the explicit flush).

### Phase 2: Character-by-Character Sequence CRDT

**Addresses:** Bug 5 (Snapshot-LWW behavior).

* **Fractional Indexing:** Abandon the snapshot-based `SequenceCrdtMerger`. The `body` text is now treated as an array of individual characters.
* **Unique Identifiers:** Every keystroke generates an operation containing:
* A Logical Clock.
* A Client ID.
* A Fractional Position (a mathematical value dictating its exact placement between surrounding characters).


* **The Merge Engine:** When a remote payload arrives, the CRDT engine independently sorts the operation logs by their fractional positions. This flawlessly weaves concurrent offline typing together character-by-character without ever relying on the document's global `updatedAt` timestamp.

### Phase 3: Lifecycle & Navigation Hardening

**Addresses:** Bug 3 (Double flushes), Bug 8 (Process kill data loss), Bug 9 (Stale entry switches).

* **Centralized Flushes:** Remove all flush logic from the `_PlainJournalEditor` child widget. The parent `_JournalPageState` must be the sole owner of `_flushActiveEntryEdits()`.
* **App Termination Safety:** Implement `AppLifecycleListener`. When the OS signals the app is backgrounding or closing, synchronously await a final `flushAllPending()` before allowing the isolate to terminate.
* **Guard `didUpdateWidget`:** When switching entries, check if `isFlushing` is true. You must `await` the flush promise to resolve before allowing the editor to reset its text controller with the new `widget.entry.body`.

### Phase 4: UI Reconcile & Focus Safety

**Addresses:** Bug 6 (Blocked provider updates), Bug 12 (Live sync focus race conditions).

* **Field-Level Reconcile:** Modify `_reconcileSelectedEntryFromProvider`. If a local body draft exists, do not reject the entire provider update. Accept incoming metadata (title, mood, weather, journal routing) and *only* block the UI text controller overwrite.
* **Instant Focus Locking:** Do not wait for the framework's `FocusNode` callback to trigger active-edit protection. Fire `setDocumentEditing(true)` directly on the `PointerDownEvent` of the text field to instantly close the overwrite vulnerability window.

### Phase 5: The Conflict Resolution UI

**Addresses:** Bug 4 (Silent text appending on hard conflicts).

* **The Quarantined State:** If the CRDT engine detects a corrupted operation chain, or if there is an unresolvable Last-Write-Wins metadata collision (identical versions and timestamps), block the automatic SQLite upsert. Save the incoming document to a `sync_conflicts_table`.
* **The UI Trigger:** Render a persistent banner on the `JournalPage`: *"Conflicting edits detected."*
* **The Resolution Dialog:** Display a side-by-side visual diff. Left column: Local. Right column: Remote. Force the user to choose "Keep Local", "Keep Remote", or manually merge the text.
* **The Debug Toggle:** Implement a `force_conflict_ui` boolean in your Dev Settings. When true, `RemoteSyncService.pullAll()` will artificially flag the next download as corrupted, instantly triggering the quarantined state so you can test the UI without having to manufacture a mathematically perfect race condition.

---
