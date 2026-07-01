Here is the Low-Level Design (LLD) for the complete Import, Export, and Trickle Sync architecture, tailored specifically for your offline-first Flutter/Drift environment. 

This design introduces three new functional areas: The Archiver (Export), The Extractor (Import), and The Outbox Worker (Trickle Sync).

---

### 1. The Database Layer (Drift)

First, define the Outbox table to hold the stranded or bulk-imported document IDs.

```dart
// lib/data/database/schema/pending_uploads.dart
class PendingUploadsTable extends Table {
  TextColumn get documentId => text()();
  TextColumn get collectionName => text()();
  DateTimeColumn get addedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {documentId, collectionName};
}

```

---

### 2. The Export Pipeline (`DataExportService`)

The export process must not block the main UI thread. We will use Flutter's `compute()` to offload the heavy JSON encoding to a background isolate, and the `archive` package to create the `.zip`.

**Responsibilities:** Query SQLite → Encode to JSON (Background) → Zip Files → Save to Device.

```dart
// lib/features/settings/services/data_export_service.dart

class DataExportService {
  final AppDatabase _db;
  
  Future<File> exportDataToZip() async {
    // 1. Fetch data sequentially to avoid RAM spikes
    final journals = await _db.journalRepository.getAllEntries();
    final tasks = await _db.todoRepository.getAllTasks();

    // 2. Offload serialization and zipping to a background isolate
    final zipBytes = await compute(_generateZipIsolate, {
      'journals': journals.map((j) => j.toJson()).toList(),
      'tasks': tasks.map((t) => t.toJson()).toList(),
    });

    // 3. Save to standard output directory (using path_provider)
    final outputDir = await getApplicationDocumentsDirectory();
    final exportFile = File('${outputDir.path}/voyager_backup_${DateTime.now().millisecondsSinceEpoch}.zip');
    return await exportFile.writeAsBytes(zipBytes);
  }
}

// Background Isolate Function (Must be top-level)
List<int> _generateZipIsolate(Map<String, List<Map<String, dynamic>>> data) {
  final archive = Archive();
  
  // Create distinct files inside the ZIP
  final journalData = utf8.encode(jsonEncode(data['journals']));
  archive.addFile(ArchiveFile('journals.json', journalData.length, journalData));
  
  final taskData = utf8.encode(jsonEncode(data['tasks']));
  archive.addFile(ArchiveFile('tasks.json', taskData.length, taskData));

  // Encode the ZIP
  return ZipEncoder().encode(archive)!;
}

```

---

### 3. The Import Pipeline (`DataImportService`)

The import process extracts the `.zip`, parses the JSON in the background, and then strictly uses a **Drift Transaction** to write the data to the local tables AND the Outbox table simultaneously.

```dart
// lib/features/settings/services/data_import_service.dart

class DataImportService {
  final AppDatabase _db;

  Future<void> importFromZip(File zipFile) async {
    // 1. Read and parse in background
    final zipBytes = await zipFile.readAsBytes();
    final parsedData = await compute(_extractZipIsolate, zipBytes);

    // 2. Insert locally and queue for Trickle Sync in ONE transaction
    await _db.transaction(() async {
      // Process Journals
      for (var jsonMap in parsedData['journals']) {
        final entry = JournalEntry.fromJson(jsonMap);
        
        // Artificial bump so it beats any stale cloud data during merge
        final safeEntry = entry.copyWith(
          version: entry.version + 1, 
          updatedAt: DateTime.now()
        );

        await _db.journalRepository.upsertEntry(safeEntry, recordLocalActivity: false); // Bypass in-memory debouncer
        
        // Add to Outbox
        await _db.into(_db.pendingUploadsTable).insertOnConflictUpdate(
          PendingUploadsCompanion.insert(
            documentId: safeEntry.id,
            collectionName: FirestoreCollections.journalEntries,
          )
        );
      }
      
      // (Repeat identical loop for Tasks)
    });

    // 3. Kickstart the Trickle Worker
    OutboxSyncWorker.instance.startDraining();
  }
}

```

---

### 4. The Trickle Sync Engine (`OutboxSyncWorker`)

This is the invisible hero of the app. It runs in the background, grabbing chunks of 500, converting them to a Firestore `WriteBatch`, and pushing them.

```dart
// lib/core/sync/outbox_sync_worker.dart

class OutboxSyncWorker {
  final AppDatabase _db;
  final FirebaseFirestore _firestore;
  bool _isDraining = false;

  Future<void> startDraining() async {
    if (_isDraining) return;
    _isDraining = true;

    try {
      while (true) {
        // 1. Query exactly 500 items from Outbox
        final pendingList = await (_db.select(_db.pendingUploadsTable)
              ..orderBy([(t) => OrderingTerm.asc(t.addedAt)])
              ..limit(500))
            .get();

        if (pendingList.isEmpty) break; // Queue is empty, we are done!

        // 2. Create Firestore Batch
        final batch = _firestore.batch();
        final List<PendingUploadData> successfulUploads = [];

        for (final pending in pendingList) {
          if (pending.collectionName == FirestoreCollections.journalEntries) {
            // Fetch the absolute latest truth from local DB
            final entry = await _db.journalRepository.getEntry(pending.documentId);
            if (entry != null) {
              final docRef = _firestore.collection(pending.collectionName).doc(entry.id);
              batch.set(docRef, entry.toFirestoreMap(), SetOptions(merge: true));
              successfulUploads.add(pending);
            }
          }
        }

        // 3. Commit to Cloud
        await batch.commit();

        // 4. Remove successful items from local Outbox
        final successIds = successfulUploads.map((e) => e.documentId).toList();
        await (_db.delete(_db.pendingUploadsTable)
              ..where((t) => t.documentId.isIn(successIds)))
            .go();

        // Optional: Yield to prevent OS throttling
        await Future.delayed(const Duration(seconds: 2)); 
      }
    } catch (e) {
      // Network error, pause draining. It will resume on next app startup.
      print("Outbox drain paused due to error: $e");
    } finally {
      _isDraining = false;
    }
  }
}

```

---

### 5. Testing Strategy

To guarantee you do not break the sync engine or data integrity, here are the tests you must write.

#### Unit Tests (Fast, Isolated)

1. **`DataExportService` JSON Chunking Test:**
* *Action:* Pass a mock list of 10,000 auto-generated `JournalEntry` models to `_generateZipIsolate`.
* *Assert:* The resulting byte array is a valid ZIP archive. Read the archive and assert `journals.json` exists inside it.


2. **`OutboxSyncWorker` Batch Limit Test:**
* *Mock:* Inject a mock `AppDatabase` containing 1,200 rows in `PendingUploadsTable`. Inject a mock `FirebaseFirestore`.
* *Action:* Call `startDraining()`.
* *Assert:* Verify that `_firestore.batch()` was instantiated exactly 3 times (two batches of 500, one batch of 200).


3. **Failsafe DB Transaction Test:**
* *Mock:* Force an SQLite exception during the transaction block in `importFromZip`.
* *Assert:* Verify that *neither* the `JournalEntriesTable` nor the `PendingUploadsTable` were modified (testing ACID compliance).



#### Integration Tests (Slow, End-to-End)

1. **The App Force-Close Failsafe Test:**
* *Setup:* Start with an empty cloud and empty local DB.
* *Action:* Insert a record into SQLite. Insert its ID into `PendingUploadsTable`. *Do not fire the in-memory debouncer.*
* *Action:* Instantiate `OutboxSyncWorker` and call `startDraining()`.
* *Assert:* Query the real/emulator Firestore instance. Verify the document appeared in the cloud. Query local SQLite. Verify the Outbox table is now empty.


2. **The "In-Flight Merge" Collision Test:**
* *Setup:* Add Document A to the `PendingUploadsTable` (simulating it's waiting to go up).
* *Action:* Manually push a newer version of Document A directly to Firestore. Trigger `LiveSyncController` to pull down that remote change.
* *Action:* Let `pullJournalEntries` execute (it should merge the remote CRDT ops with the local changes).
* *Action:* Trigger `startDraining()`.
* *Assert:* The Outbox worker must grab the *newest, merged* version of the document from local SQLite to push up, NOT the stale version it had when it was originally queued.