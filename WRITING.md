### Fix 1: Aligning the Seed ID Format

To stop the CRDT merger from generating ghost characters, your `_seedFromText` method must generate IDs that perfectly match the active typing IDs. This ensures that when a user deletes a seeded character, the `_tombstone` function targets an ID that Firestore actually recognizes.

**Update `lib/domain/services/character_op_session.dart`:**

```dart
void _seedFromText(String text) {
  var prevPos = '';
  for (var i = 0; i < text.length; i++) {
    final char = text[i];
    final pos = i == 0
        ? FractionalIndex.first()
        : FractionalIndex.after(prevPos);
    prevPos = pos;
    
    // FIX: Match the active insert ID format perfectly
    final id = '${clientId}_${_logicalClock}_$pos'; 
    
    _opsById[id] = CharacterOperation(
      id: id,
      clientId: clientId,
      logicalClock: _logicalClock++,
      position: pos,
      character: char,
    );
  }
}

```

---

### Fix 2: Preventing the "Invisible" Quarantine

If a brand-new entry causes a conflict on its very first pull, you must give the local SQLite database a placeholder so the user's UI can actually display the entry and alert them to the conflict.

**Update `lib/core/sync/remote_sync_service.dart` (inside `pullJournalEntries`):**

```dart
        if (detection.isConflict) {
          // FIX: Guarantee the entry exists locally before quarantining
          if (local == null) {
            // Assuming you have a mapper function to convert Firestore map to your model
            final fallbackEntry = firestoreToJournalEntry(id, data); 
            await _journalRepository.upsertEntry(fallbackEntry);
          }

          await _quarantineConflict(
            collection: FirestoreCollections.journalEntries,
            documentId: id,
            local: local == null
                ? null
                : SyncConflictDetector.payloadJson(journalEntryToFirestore(local)),
            remote: SyncConflictDetector.payloadJson(data),
            localTitle: local?.title,
            remoteTitle: data['title'] as String?,
            localText: local?.body,
            remoteText: data['body'] as String?,
          );
          return; 
        }

```

---

### Fix 3: Nuking the Corrupted Remote Ops

When you resolve a conflict, you are establishing a brand new absolute truth. You must destroy the corrupted remote operation log before uploading the resolution, or the corrupted history will immediately re-infect the document on the next pull.

**Update your resolution methods in `lib/core/sync/remote_sync_service.dart`:**

```dart
  Future<void> resolveConflictManualMerge(SyncConflict conflict, String resolvedText) async {
    // 1. Construct your resolved entry...
    final resolvedEntry = ... 
    
    // FIX A: Purge the corrupted operations chain from Firestore
    await _syncEngine.deleteOperationsForDocument(
      FirestoreCollections.journalEntries, 
      conflict.documentId
    );

    // FIX B: Force the local CRDT engine to generate fresh insert operations 
    // for the entire resolved text, bypassing silent seeds.
    _charOpRegistry.resetSession(conflict.documentId, resolvedText);

    // FIX C: Upload the fresh snapshot and the new clean ops
    await _uploadJournalEntryNow(resolvedEntry, bumpVersion: true);

    // 4. Clear the conflict from the local quarantine table...
  }

```

*(Note: Apply this same `deleteOperationsForDocument` logic to your `resolveConflictKeepLocal` and `resolveConflictKeepRemote` methods).*

By applying these three fixes, your CRDT engine will correctly tombstone older text, your UI will accurately display all quarantined files, and your conflict resolution will permanently overwrite corrupted states.