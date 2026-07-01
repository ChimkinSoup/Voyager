import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:drift/drift.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/domain/models/todo_models.dart';

class OutboxSyncWorker {
  OutboxSyncWorker(
    this._db,
    this._firestore,
    this._authRepo, {
    this.yieldDelay = const Duration(seconds: 2),
  });

  final AppDatabase _db;
  final FirebaseFirestore _firestore;
  final AuthRepository _authRepo;
  final Duration yieldDelay;
  bool _isDraining = false;

  static OutboxSyncWorker? _instance;

  static OutboxSyncWorker get instance {
    if (_instance == null) {
      throw StateError('OutboxSyncWorker has not been initialized.');
    }
    return _instance!;
  }

  static bool get isInitialized => _instance != null;

  static void initialize(
    AppDatabase db,
    FirebaseFirestore firestore,
    AuthRepository authRepo, {
    Duration yieldDelay = const Duration(seconds: 2),
  }) {
    _instance = OutboxSyncWorker(
      db,
      firestore,
      authRepo,
      yieldDelay: yieldDelay,
    );
  }

  Future<void> startDraining() async {
    if (_isDraining) return;
    _isDraining = true;

    try {
      final journalRepo = DriftJournalRepository(_db);
      final todoRepo = DriftTodoRepository(_db);

      while (true) {
        final userId = _authRepo.currentUserId;
        if (userId == null) {
          // User not logged in, stop draining.
          break;
        }

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
            final entry = await journalRepo.getEntry(pending.documentId);
            if (entry != null) {
              final docRef = _firestore.doc(
                'users/$userId/${pending.collectionName}/${entry.id}',
              );
              batch.set(
                docRef,
                journalEntryToFirestore(entry),
                SetOptions(merge: true),
              );
              successfulUploads.add(pending);
            } else {
              // Item no longer exists locally, remove from outbox.
              successfulUploads.add(pending);
            }
          } else if (pending.collectionName == FirestoreCollections.todoTasks) {
            final task = await todoRepo.getTask(pending.documentId);
            if (task != null) {
              final docRef = _firestore.doc(
                'users/$userId/${pending.collectionName}/${task.id}',
              );
              batch.set(
                docRef,
                todoTaskToFirestore(task),
                SetOptions(merge: true),
              );
              successfulUploads.add(pending);
            } else {
              // Item no longer exists locally, remove from outbox.
              successfulUploads.add(pending);
            }
          } else if (pending.collectionName == FirestoreCollections.journals) {
            final journal = await journalRepo.getJournal(pending.documentId);
            if (journal != null) {
              final docRef = _firestore.doc(
                'users/$userId/${pending.collectionName}/${journal.id}',
              );
              batch.set(
                docRef,
                journalToFirestore(journal),
                SetOptions(merge: true),
              );
              successfulUploads.add(pending);
            } else {
              successfulUploads.add(pending);
            }
          } else if (pending.collectionName == FirestoreCollections.todoLists) {
            final row = await (_db.select(_db.todoListsTable)
                  ..where((t) => t.id.equals(pending.documentId)))
                .getSingleOrNull();
            if (row != null) {
              final list = TodoListModel(
                id: row.id,
                name: row.name,
                colorValue: row.colorValue,
                createdAt: row.createdAt,
                updatedAt: row.updatedAt,
                version: row.version,
                deletedAt: row.deletedAt,
              );
              final docRef = _firestore.doc(
                'users/$userId/${pending.collectionName}/${list.id}',
              );
              batch.set(
                docRef,
                todoListToFirestore(list),
                SetOptions(merge: true),
              );
              successfulUploads.add(pending);
            } else {
              successfulUploads.add(pending);
            }
          }
        }

        // 3. Commit to Cloud
        if (successfulUploads.isNotEmpty) {
          await batch.commit();

          // 4. Remove successful items from local Outbox
          final successIds =
              successfulUploads.map((e) => e.documentId).toList();
          await (_db.delete(_db.pendingUploadsTable)
                ..where((t) => t.documentId.isIn(successIds)))
              .go();
        } else {
          // Safeguard: If none were successful (e.g. all entities deleted),
          // clear them to avoid infinite loop.
          final allIds = pendingList.map((e) => e.documentId).toList();
          await (_db.delete(_db.pendingUploadsTable)
                ..where((t) => t.documentId.isIn(allIds)))
              .go();
        }

        // Yield to prevent OS throttling
        await Future.delayed(yieldDelay);
      }
    } catch (e) {
      // Network error, pause draining. It will resume on next app startup.
      print("Outbox drain paused due to error: $e");
    } finally {
      _isDraining = false;
    }
  }
}
