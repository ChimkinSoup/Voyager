import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:archive/archive.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/core/sync/outbox_sync_worker.dart';
import 'package:drift/drift.dart';
import 'package:voyager/core/constants/journal_constants.dart';

class DataImportService {
  DataImportService(this._db, this._journalRepo, this._todoRepo);

  final AppDatabase _db;
  final JournalRepository _journalRepo;
  final TodoRepository _todoRepo;

  Future<void> importFromZip(File zipFile) async {
    // 1. Read and parse in background
    final zipBytes = await zipFile.readAsBytes();
    final parsedData = await compute(extractZipIsolate, zipBytes);

    // 2. Insert locally and queue for Trickle Sync in ONE transaction
    await _db.transaction(() async {
      final restoredJournalIds = <String>{};
      final restoredListIds = <String>{};

      // Process Journals
      for (var jsonMap in parsedData['journals']!) {
        final entry = JournalEntry.fromJson(jsonMap);

        // Read current local version so we can beat it AND beat whatever
        // Firestore has already synced (which may be higher than the backup
        // version). Using max(localVersion, backupVersion) + 1 guarantees
        // that the restored entry wins the LWW conflict on the next sync,
        // preventing Firestore from pulling a stale deleted version back down.
        final existingRow = await (_db.select(_db.journalEntriesTable)
              ..where((t) => t.id.equals(entry.id)))
            .getSingleOrNull();
        final localVersion = existingRow?.version ?? 0;
        final safeVersion = (localVersion > entry.version ? localVersion : entry.version) + 1;

        final safeEntry = entry.copyWith(
          version: safeVersion,
          bumpVersion: false,
        );

        // Recreate or restore parent journal container if necessary
        if (safeEntry.deletedAt == null &&
            safeEntry.journalId != legacyJournalId &&
            !restoredJournalIds.contains(safeEntry.journalId)) {
          final journalExists = await (_db.select(_db.journalsTable)
                ..where((t) => t.id.equals(safeEntry.journalId)))
              .getSingleOrNull();

          if (journalExists != null) {
            if (journalExists.deletedAt != null) {
              await (_db.update(_db.journalsTable)
                    ..where((t) => t.id.equals(safeEntry.journalId)))
                  .write(
                const JournalsTableCompanion(
                  deletedAt: Value(null),
                ),
              );
              // Queue container restore to outbox
              await _db.into(_db.pendingUploadsTable).insertOnConflictUpdate(
                PendingUploadsTableCompanion.insert(
                  documentId: safeEntry.journalId,
                  collectionName: FirestoreCollections.journals,
                ),
              );
            }
          } else {
            await _db.into(_db.journalsTable).insert(
              JournalsTableCompanion.insert(
                id: safeEntry.journalId,
                name: 'Restored Journal',
                createdAt: safeEntry.createdAt,
                updatedAt: DateTime.now().toUtc(),
                version: const Value(1),
              ),
            );
            // Queue new container to outbox
            await _db.into(_db.pendingUploadsTable).insertOnConflictUpdate(
              PendingUploadsTableCompanion.insert(
                documentId: safeEntry.journalId,
                collectionName: FirestoreCollections.journals,
              ),
            );
          }
          restoredJournalIds.add(safeEntry.journalId);
        }

        await _journalRepo.upsertEntry(safeEntry, recordLocalActivity: false); // Bypass in-memory debouncer

        // Add to Outbox
        await _db.into(_db.pendingUploadsTable).insertOnConflictUpdate(
          PendingUploadsTableCompanion.insert(
            documentId: safeEntry.id,
            collectionName: FirestoreCollections.journalEntries,
          ),
        );
      }

      // Process Tasks
      for (var jsonMap in parsedData['tasks']!) {
        final task = TodoTask.fromJson(jsonMap);

        // Same version-max logic as journal entries: beat the local DB version
        // AND the backup version so Firestore can't pull a stale deleted state.
        final existingTaskRow = await (_db.select(_db.todoTasksTable)
              ..where((t) => t.id.equals(task.id)))
            .getSingleOrNull();
        final localTaskVersion = existingTaskRow?.version ?? 0;
        final safeTaskVersion = (localTaskVersion > task.version ? localTaskVersion : task.version) + 1;

        final safeTask = task.copyWith(
          version: safeTaskVersion,
          bumpVersion: false,
        );

        // Recreate or restore parent list container if necessary
        if (safeTask.deletedAt == null &&
            !restoredListIds.contains(safeTask.listId)) {
          final listExists = await (_db.select(_db.todoListsTable)
                ..where((t) => t.id.equals(safeTask.listId)))
              .getSingleOrNull();

          if (listExists != null) {
            if (listExists.deletedAt != null) {
              await (_db.update(_db.todoListsTable)
                    ..where((t) => t.id.equals(safeTask.listId)))
                  .write(
                const TodoListsTableCompanion(
                  deletedAt: Value(null),
                ),
              );
              // Queue container restore to outbox
              await _db.into(_db.pendingUploadsTable).insertOnConflictUpdate(
                PendingUploadsTableCompanion.insert(
                  documentId: safeTask.listId,
                  collectionName: FirestoreCollections.todoLists,
                ),
              );
            }
          } else {
            await _db.into(_db.todoListsTable).insert(
              TodoListsTableCompanion.insert(
                id: safeTask.listId,
                name: 'Restored List',
                createdAt: safeTask.createdAt,
                updatedAt: DateTime.now().toUtc(),
                version: const Value(1),
              ),
            );
            // Queue new container to outbox
            await _db.into(_db.pendingUploadsTable).insertOnConflictUpdate(
              PendingUploadsTableCompanion.insert(
                documentId: safeTask.listId,
                collectionName: FirestoreCollections.todoLists,
              ),
            );
          }
          restoredListIds.add(safeTask.listId);
        }

        await _todoRepo.upsertTask(safeTask, recordLocalActivity: false);

        // Add to Outbox
        await _db.into(_db.pendingUploadsTable).insertOnConflictUpdate(
          PendingUploadsTableCompanion.insert(
            documentId: safeTask.id,
            collectionName: FirestoreCollections.todoTasks,
          ),
        );
      }
    });

    // 3. Kickstart the Trickle Worker
    OutboxSyncWorker.instance.startDraining();
  }
}

// Background Isolate Function (Must be top-level)
Map<String, List<Map<String, dynamic>>> extractZipIsolate(List<int> zipBytes) {
  final archive = ZipDecoder().decodeBytes(zipBytes);
  final result = <String, List<Map<String, dynamic>>>{
    'journals': [],
    'tasks': [],
  };

  final journalFile = archive.findFile('journals.json');
  if (journalFile != null) {
    final content = utf8.decode(journalFile.content as List<int>);
    final list = jsonDecode(content) as List;
    result['journals'] =
        list.map((item) => item as Map<String, dynamic>).toList();
  }

  final taskFile = archive.findFile('tasks.json');
  if (taskFile != null) {
    final content = utf8.decode(taskFile.content as List<int>);
    final list = jsonDecode(content) as List;
    result['tasks'] =
        list.map((item) => item as Map<String, dynamic>).toList();
  }

  return result;
}
