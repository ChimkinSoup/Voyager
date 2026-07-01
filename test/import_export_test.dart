import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:archive/archive.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/features/settings/services/data_export_service.dart';
import 'package:voyager/features/settings/services/data_import_service.dart';
import 'package:voyager/core/sync/outbox_sync_worker.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/core/sync/sync_engine.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/data/remote/firestore_sync_repository.dart';
import 'package:voyager/domain/services/weather_service.dart';
import 'package:voyager/core/sync/debouncer.dart';
import '../test/fakes/fake_weather_api_client.dart';

class FakeAuthRepository implements AuthRepository {
  @override
  String? get currentUserId => 'test-user-123';

  @override
  Stream<bool> get authStateChanges => Stream.value(true);

  @override
  Future<void> signInWithEmail(String email, String password) async {}
  @override
  Future<void> signUpWithEmail(String email, String password) async {}
  @override
  Future<void> sendPasswordResetEmail(String email) async {}
  @override
  Future<void> signInWithGoogle() async {}
  @override
  Future<void> signOut() async {}
}

class ThrowingJournalRepository extends DriftJournalRepository {
  ThrowingJournalRepository(super.db);

  @override
  Future<void> upsertEntry(
    JournalEntry entry, {
    bool recordLocalActivity = true,
  }) async {
    if (entry.title == 'throw') {
      throw Exception('Forced SQLite exception');
    }
    return super.upsertEntry(entry, recordLocalActivity: recordLocalActivity);
  }
}

class MockFirestoreBatch extends Fake implements WriteBatch {
  int commitCount = 0;
  List<Map<String, dynamic>> sets = [];

  @override
  void set<T>(DocumentReference<T> document, T data, [SetOptions? options]) {
    sets.add({
      'path': document.path,
      'data': data,
    });
  }

  @override
  Future<void> commit() async {
    commitCount++;
  }
}

class MockFirebaseFirestore extends Fake implements FirebaseFirestore {
  int batchCreatedCount = 0;
  final List<MockFirestoreBatch> batches = [];

  @override
  WriteBatch batch() {
    batchCreatedCount++;
    final b = MockFirestoreBatch();
    batches.add(b);
    return b;
  }

  @override
  DocumentReference<Map<String, dynamic>> doc(String documentPath) {
    return MockDocumentReference(documentPath);
  }
}

class MockDocumentReference extends Fake
    implements DocumentReference<Map<String, dynamic>> {
  MockDocumentReference(this.path);

  @override
  final String path;
}

void main() {
  group('Import / Export Unit Tests', () {
    test('DataExportService JSON Chunking Test', () {
      final entries = List.generate(
        10000,
        (index) => JournalEntry(
          id: 'entry-$index',
          journalId: 'journal-1',
          title: 'Entry $index',
          body: 'Body text $index',
          entryDate: DateTime.now().toUtc(),
          createdAt: DateTime.now().toUtc(),
          updatedAt: DateTime.now().toUtc(),
        ),
      );

      final zipBytes = generateZipIsolate({
        'journals': entries.map((e) => e.toJson()).toList(),
        'tasks': [],
      });

      expect(zipBytes, isNotEmpty);

      final archive = ZipDecoder().decodeBytes(zipBytes);
      final journalFile = archive.findFile('journals.json');
      expect(journalFile, isNotNull);

      final content = utf8.decode(journalFile!.content as List<int>);
      final list = jsonDecode(content) as List;
      expect(list.length, 10000);
      expect(list[0]['id'], 'entry-0');
    });

    test('OutboxSyncWorker Batch Limit Test', () async {
      final db = AppDatabase.inMemory();
      final mockFirestore = MockFirebaseFirestore();
      final fakeAuth = FakeAuthRepository();

      await db.transaction(() async {
        for (int i = 0; i < 1200; i++) {
          final entryId = 'entry-$i';
          await db.into(db.journalEntriesTable).insert(
            JournalEntriesTableCompanion.insert(
              id: entryId,
              journalId: 'journal-1',
              title: 'Entry $i',
              body: 'Body $i',
              entryDate: DateTime.now().toUtc(),
              createdAt: DateTime.now().toUtc(),
              updatedAt: DateTime.now().toUtc(),
            ),
          );
          await db.into(db.pendingUploadsTable).insert(
            PendingUploadsTableCompanion.insert(
              documentId: entryId,
              collectionName: FirestoreCollections.journalEntries,
            ),
          );
        }
      });

      OutboxSyncWorker.initialize(
        db,
        mockFirestore,
        fakeAuth,
        yieldDelay: Duration.zero,
      );
      await OutboxSyncWorker.instance.startDraining();

      expect(mockFirestore.batchCreatedCount, 3);
      expect(mockFirestore.batches[0].sets.length, 500);
      expect(mockFirestore.batches[1].sets.length, 500);
      expect(mockFirestore.batches[2].sets.length, 200);

      final remains = await db.select(db.pendingUploadsTable).get();
      expect(remains, isEmpty);

      await db.close();
    });

    test('Failsafe DB Transaction Test', () async {
      final db = AppDatabase.inMemory();
      final throwingRepo = ThrowingJournalRepository(db);
      final todoRepo = DriftTodoRepository(db);
      final importer = DataImportService(db, throwingRepo, todoRepo);

      final jsonPayload = {
        'journals': [
          JournalEntry(
            id: 'entry-good',
            journalId: 'journal-1',
            title: 'Good Entry',
            body: 'I will survive',
            entryDate: DateTime.now().toUtc(),
            createdAt: DateTime.now().toUtc(),
            updatedAt: DateTime.now().toUtc(),
          ).toJson(),
          JournalEntry(
            id: 'entry-bad',
            journalId: 'journal-1',
            title: 'throw',
            body: 'I will throw',
            entryDate: DateTime.now().toUtc(),
            createdAt: DateTime.now().toUtc(),
            updatedAt: DateTime.now().toUtc(),
          ).toJson(),
        ],
        'tasks': [],
      };

      final archive = Archive();
      final journalsData = utf8.encode(jsonEncode(jsonPayload['journals']));
      archive.addFile(
        ArchiveFile('journals.json', journalsData.length, journalsData),
      );
      final tasksData = utf8.encode(jsonEncode(jsonPayload['tasks']));
      archive.addFile(ArchiveFile('tasks.json', tasksData.length, tasksData));
      final zipBytes = ZipEncoder().encode(archive)!;

      final tempDir = Directory.systemTemp;
      final tempFile = File('${tempDir.path}/temp_test_failsafe.zip');
      await tempFile.writeAsBytes(zipBytes);

      // We expect importFromZip to throw exception and rollback transaction
      await expectLater(
        importer.importFromZip(tempFile),
        throwsA(isA<Exception>()),
      );

      final entries = await db.select(db.journalEntriesTable).get();
      final pending = await db.select(db.pendingUploadsTable).get();

      // ACID compliance: both should be empty
      expect(entries, isEmpty);
      expect(pending, isEmpty);

      await tempFile.delete();
      await db.close();
    });
   group('Import / Export Integration Tests', () {
    test('The App Force-Close Failsafe Test', () async {
      final db = AppDatabase.inMemory();
      final fakeFirestore = FakeFirebaseFirestore();
      final fakeAuth = FakeAuthRepository();

      final entryId = 'entry-force-close-123';
      // 1. Insert record to SQLite directly
      await db.into(db.journalEntriesTable).insert(
        JournalEntriesTableCompanion.insert(
          id: entryId,
          journalId: 'journal-1',
          title: 'Unsaved Title',
          body: 'Pending upload',
          entryDate: DateTime.now().toUtc(),
          createdAt: DateTime.now().toUtc(),
          updatedAt: DateTime.now().toUtc(),
        ),
      );
      // 2. Insert into PendingUploadsTable (simulating force-closed outbox state)
      await db.into(db.pendingUploadsTable).insert(
        PendingUploadsTableCompanion.insert(
          documentId: entryId,
          collectionName: FirestoreCollections.journalEntries,
        ),
      );

      OutboxSyncWorker.initialize(
        db,
        fakeFirestore,
        fakeAuth,
        yieldDelay: Duration.zero,
      );
      await OutboxSyncWorker.instance.startDraining();

      // 3. Query fake firestore
      final snap = await fakeFirestore
          .doc('users/test-user-123/${FirestoreCollections.journalEntries}/$entryId')
          .get();
      expect(snap.exists, isTrue);
      expect(snap.data()?['title'], 'Unsaved Title');

      // 4. Local outbox should now be empty
      final pending = await db.select(db.pendingUploadsTable).get();
      expect(pending, isEmpty);

      await db.close();
    });

    test('The "In-Flight Merge" Collision Test', () async {
      final db = AppDatabase.inMemory();
      final fakeFirestore = FakeFirebaseFirestore();
      final fakeAuth = FakeAuthRepository();
      final journalRepo = DriftJournalRepository(db);
      final todoRepo = DriftTodoRepository(db);

      final docId = 'collision-doc-999';
      final now = DateTime.now().toUtc();

      // Setup local version in SQLite
      await journalRepo.upsertEntry(
        JournalEntry(
          id: docId,
          journalId: 'journal-1',
          title: 'Local Version',
          body: 'Local body',
          entryDate: now,
          createdAt: now,
          updatedAt: now,
          version: 1,
        ),
      );

      // Add to pending outbox (simulating in-flight change)
      await db.into(db.pendingUploadsTable).insert(
        PendingUploadsTableCompanion.insert(
          documentId: docId,
          collectionName: FirestoreCollections.journalEntries,
        ),
      );

      // Set up Sync Repository & Remote Sync Service
      final syncRepo = FirestoreSyncRepository(fakeFirestore, fakeAuth.currentUserId!);
      final syncEngine = SyncEngine(
        syncRepository: syncRepo,
        deviceId: 'device-test',
        debouncer: Debouncer(delay: Duration.zero),
      );
      final weatherService = WeatherService(
        settingsRepository: DriftSettingsRepository(db),
        syncRepository: syncRepo,
        weatherApiClient: FakeWeatherApiClient(),
        deviceId: 'device-test',
      );
      final remoteSync = RemoteSyncService(
        syncRepository: syncRepo,
        journalRepository: journalRepo,
        todoRepository: todoRepo,
        weatherService: weatherService,
        syncEngine: syncEngine,
        uploadDebounceDelay: Duration.zero,
      );

      // Manually push a NEWER version of the document directly to Firestore
      final remoteUpdated = now.add(const Duration(minutes: 5));
      await syncRepo.upsertDocument(
        FirestoreCollections.journalEntries,
        docId,
        journalEntryToFirestore(
          JournalEntry(
            id: docId,
            journalId: 'journal-1',
            title: 'Remote Version (Newer)',
            body: 'Remote body',
            entryDate: now,
            createdAt: now,
            updatedAt: remoteUpdated,
            version: 2,
          ),
        ),
      );

      // Trigger remote pull (collides and merges)
      await remoteSync.pullForCollection(FirestoreCollections.journalEntries);

      // Let's verify that the local sqlite now holds the merged/newer version
      final localEntry = await journalRepo.getEntry(docId);
      expect(localEntry?.title, 'Remote Version (Newer)');
      expect(localEntry?.version, 2);

      // Now fire OutboxSyncWorker
      OutboxSyncWorker.initialize(
        db,
        fakeFirestore,
        fakeAuth,
        yieldDelay: Duration.zero,
      );
      await OutboxSyncWorker.instance.startDraining();

      // Query the fake firestore - it should have pushed the NEWER merged version, not the old Local Version.
      final snap = await fakeFirestore
          .doc('users/test-user-123/${FirestoreCollections.journalEntries}/$docId')
          .get();
      expect(snap.data()?['title'], 'Remote Version (Newer)');
      expect(snap.data()?['version'], 2);

      await db.close();
      syncEngine.dispose();
    });
  });
 });
}
