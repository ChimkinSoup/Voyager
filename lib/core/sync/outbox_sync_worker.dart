import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:drift/drift.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/core/sync/sync_error_classification.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/repositories/repositories.dart';

/// Re-uploads one document through the app's ordinary save path — see
/// [OutboxSyncWorker.pushDocument].
typedef OutboxDocumentPusher =
    Future<void> Function(String collection, String documentId);

class OutboxSyncWorker {
  OutboxSyncWorker(
    this._db,
    this._firestore,
    this._authRepo, {
    this.yieldDelay = const Duration(seconds: 2),
    this.pushDocument,
  });

  final AppDatabase _db;
  final FirebaseFirestore _firestore;
  final AuthRepository _authRepo;
  final Duration yieldDelay;

  /// How a document in one of [FirestoreCollections.crdtBacked] is re-sent.
  ///
  /// Those documents cannot be recovered with a plain `set` on the mirror. A
  /// pull prefers the CRDT-resolved payload whenever `sync_operations` holds
  /// anything for the document, so writing only the mirror leaves it newer than
  /// the log — and the log wins on the very next pull, on every device. The
  /// user watched their offline edit appear at startup and then vanish.
  ///
  /// Routing them back through the normal save path (which writes an
  /// operation-log entry alongside the mirror, at the current sequence) is the
  /// only place that knows this device's id and sequence counter, so it is
  /// injected rather than reimplemented here.
  ///
  /// When it is absent — a worker built standalone, as in tests — those
  /// documents fall back to the plain batched write. That recovers the mirror
  /// but not the ordering guarantee, so production always wires this.
  final OutboxDocumentPusher? pushDocument;

  bool _isDraining = false;

  /// How long a queued upload keeps being retried before it is parked. Bounds
  /// the damage from an error this code fails to recognise as permanent.
  static const maxRetryAge = Duration(days: 7);

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
    OutboxDocumentPusher? pushDocument,
  }) {
    _instance = OutboxSyncWorker(
      db,
      firestore,
      authRepo,
      yieldDelay: yieldDelay,
      pushDocument: pushDocument,
    );
  }

  Future<void> startDraining() async {
    if (_isDraining) return;
    _isDraining = true;

    try {
      while (true) {
        final userId = _authRepo.currentUserId;
        if (userId == null) {
          // User not logged in, stop draining.
          break;
        }

        // 1. Query exactly 500 retryable items from Outbox. Rows carrying a
        // failureReason were abandoned deliberately and are kept only as a
        // record, so they must not re-enter the drain.
        final pendingList = await (_db.select(_db.pendingUploadsTable)
              ..where((t) => t.failureReason.isNull())
              ..orderBy([(t) => OrderingTerm.asc(t.addedAt)])
              ..limit(500))
            .get();

        if (pendingList.isEmpty) break; // Queue is empty, we are done!

        // 2. Resolve each row to the write it stands for. Rows whose entity is
        // gone locally have nothing to upload and are just cleared.
        //
        // Grouped by collection first: several collections can only be read
        // out of SQLite as a whole list, so resolving row by row would rescan
        // the same table once per queued row.
        final byCollection = <String, List<PendingUploadData>>{};
        for (final pending in pendingList) {
          byCollection
              .putIfAbsent(pending.collectionName, () => [])
              .add(pending);
        }

        final uploads = <_PendingUpload>[];
        final orphans = <PendingUploadData>[];
        var pushed = false;

        for (final entry in byCollection.entries) {
          final collection = entry.key;

          // Documents with a character-operation log go back out through the
          // app's own save path rather than as a bare mirror write — see
          // [pushDocument].
          final pusher = pushDocument;
          if (pusher != null &&
              FirestoreCollections.crdtBacked.contains(collection)) {
            for (final pending in entry.value) {
              try {
                await pusher(collection, pending.documentId);
                // Also the right outcome for a row whose entity is gone: the
                // push is a no-op and the row has nothing left to stand for.
                await _clearPending([pending]);
                pushed = true;
              } catch (error) {
                if (await _handleUploadFailure(pending, error)) pushed = true;
              }
            }
            continue;
          }

          final payloads = await _payloadsFor(collection, {
            for (final pending in entry.value) pending.documentId,
          });
          for (final pending in entry.value) {
            final data = payloads[pending.documentId];
            if (data == null) {
              orphans.add(pending);
              continue;
            }
            final firestoreId = collection == FirestoreCollections.settings
                ? FirestoreCollections.settingsDocumentId
                : firestoreDocumentIdForLocal(collection, pending.documentId);
            uploads.add(
              _PendingUpload(
                pending: pending,
                reference: _firestore.doc(
                  'users/$userId/$collection/$firestoreId',
                ),
                data: data,
              ),
            );
          }
        }

        // 3. Commit to Cloud
        if (uploads.isNotEmpty) {
          final batch = _firestore.batch();
          for (final upload in uploads) {
            batch.set(upload.reference, upload.data, SetOptions(merge: true));
          }
          try {
            await batch.commit();
          } catch (error) {
            // The batch is all-or-nothing, so a single rejected document
            // fails every document beside it and the error doesn't say which
            // one. Re-send them individually to find out: the healthy ones
            // still get through, and the offender can be parked instead of
            // being retried forever at the head of the queue.
            await _clearPending(orphans);
            final progressed = await _drainIndividually(uploads);
            // Nothing cleared and nothing parked means every row failed for a
            // reason that may pass later. Stop rather than spin on them —
            // unless the pushed documents above already shrank the queue.
            if (!progressed && !pushed) break;
            await Future.delayed(yieldDelay);
            continue;
          }

          // 4. Remove successful items from local Outbox
          await _clearPending(uploads.map((u) => u.pending).toList());
        }
        await _clearPending(orphans);

        // Every row in this round failed for a reason that may pass later, so
        // the next query would return the same 500 rows and spin. Without this
        // the pushed-document branch above could loop forever on its own,
        // since it never reaches the batch's own guard.
        if (uploads.isEmpty && orphans.isEmpty && !pushed) break;

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

  /// The write each of [documentIds] stands for in [collection], keyed by
  /// local id. Ids whose entity is gone locally are simply absent.
  ///
  /// Every collection the app syncs is resolvable here. Leaving most of them
  /// out was what made [recordFailure] park them instead of queueing them: a
  /// transaction, a calendar event or an accent colour written while the
  /// network was flaky reached SQLite, never reached Firestore, and — because
  /// the local row then wins every later merge on version and `updatedAt` —
  /// was never repaired by a pull either.
  Future<Map<String, Map<String, dynamic>>> _payloadsFor(
    String collection,
    Set<String> documentIds,
  ) async {
    if (documentIds.isEmpty) return const {};

    /// Indexes a whole collection once, for repositories that can only be read
    /// as a list.
    Map<String, Map<String, dynamic>> fromList<T>(
      List<T> records,
      String Function(T) id,
      Map<String, dynamic> Function(T) toFirestore,
    ) {
      return {
        for (final record in records)
          if (documentIds.contains(id(record))) id(record): toFirestore(record),
      };
    }

    /// Resolves ids one at a time, for repositories with an indexed getter.
    Future<Map<String, Map<String, dynamic>>> byId<T>(
      Future<T?> Function(String) get,
      Map<String, dynamic> Function(T) toFirestore,
    ) async {
      final payloads = <String, Map<String, dynamic>>{};
      for (final id in documentIds) {
        final record = await get(id);
        if (record != null) payloads[id] = toFirestore(record);
      }
      return payloads;
    }

    switch (collection) {
      case FirestoreCollections.journals:
        return byId(DriftJournalRepository(_db).getJournal, journalToFirestore);
      case FirestoreCollections.journalEntries:
        return byId(
          DriftJournalRepository(_db).getEntry,
          journalEntryToFirestore,
        );
      case FirestoreCollections.dreamEntries:
        return byId(DriftDreamRepository(_db).getEntry, dreamEntryToFirestore);
      case FirestoreCollections.todoLists:
        return fromList(
          await DriftTodoRepository(_db).listLists(includeDeleted: true),
          (list) => list.id,
          todoListToFirestore,
        );
      case FirestoreCollections.todoTasks:
        return byId(DriftTodoRepository(_db).getTask, todoTaskToFirestore);
      case FirestoreCollections.leetcodeProblems:
        return byId(
          DriftLeetCodeRepository(_db).getProblem,
          leetCodeProblemToFirestore,
        );
      case FirestoreCollections.studyFolders:
        return byId(DriftStudyRepository(_db).getFolder, studyFolderToFirestore);
      case FirestoreCollections.studyDecks:
        return byId(DriftStudyRepository(_db).getDeck, studyDeckToFirestore);
      case FirestoreCollections.studyCards:
        return byId(DriftStudyRepository(_db).getCard, studyCardToFirestore);
      case FirestoreCollections.studyReviewLog:
        return fromList(
          await DriftStudyRepository(_db).getAllReviewLogs(),
          (log) => log.id,
          studyReviewLogToFirestore,
        );
      case FirestoreCollections.exercises:
        return byId(DriftWorkoutRepository(_db).getExercise, exerciseToFirestore);
      case FirestoreCollections.workoutPlans:
        return byId(DriftWorkoutRepository(_db).getPlan, workoutPlanToFirestore);
      case FirestoreCollections.workoutPlanEntries:
        return byId(
          DriftWorkoutRepository(_db).getPlanEntry,
          workoutPlanEntryToFirestore,
        );
      case FirestoreCollections.workoutSessions:
        return byId(
          DriftWorkoutRepository(_db).getSession,
          workoutSessionToFirestore,
        );
      case FirestoreCollections.workoutSetLogs:
        return byId(
          DriftWorkoutRepository(_db).getSetLog,
          workoutSetLogToFirestore,
        );
      case FirestoreCollections.jobApplications:
        return byId(
          DriftJobRepository(_db).getApplication,
          jobApplicationToFirestore,
        );
      case FirestoreCollections.jobStatusEvents:
        return fromList(
          await DriftJobRepository(_db).getAllStatusEvents(),
          (event) => event.id,
          jobStatusEventToFirestore,
        );
      case FirestoreCollections.jobStages:
        return fromList(
          await DriftJobRepository(_db).getAllStages(),
          (stage) => stage.id,
          jobStageToFirestore,
        );
      case FirestoreCollections.jobCompanies:
        return fromList(
          await DriftJobRepository(_db).getAllCompanies(),
          (company) => company.id,
          jobCompanyToFirestore,
        );
      case FirestoreCollections.jobCategories:
        return fromList(
          await DriftJobRepository(_db).getAllCategories(),
          (category) => category.id,
          jobCategoryToFirestore,
        );
      case FirestoreCollections.jobSeasons:
        return fromList(
          await DriftJobRepository(_db).getAllSeasons(),
          (season) => season.id,
          jobSeasonToFirestore,
        );
      case FirestoreCollections.customQuotes:
        return byId(
          DriftSettingsRepository(_db).getCustomQuote,
          customQuoteToFirestore,
        );
      case FirestoreCollections.calendars:
        return byId(
          DriftCalendarRepository(_db).getCalendar,
          calendarToFirestore,
        );
      case FirestoreCollections.calendarEvents:
        return byId(
          DriftCalendarRepository(_db).getEvent,
          calendarEventToFirestore,
        );
      case FirestoreCollections.trackers:
        return byId(DriftTrackerRepository(_db).getTracker, trackerToFirestore);
      case FirestoreCollections.trackerValues:
        return byId(
          DriftTrackerRepository(_db).getValue,
          trackerValueToFirestore,
        );
      case FirestoreCollections.transactions:
        return fromList(
          await DriftFinanceRepository(_db).listTransactions(
            includeDeleted: true,
          ),
          (record) => record.id,
          transactionToFirestore,
        );
      case FirestoreCollections.subscriptions:
        return fromList(
          await DriftFinanceRepository(_db).listSubscriptions(
            includeDeleted: true,
          ),
          (record) => record.id,
          subscriptionToFirestore,
        );
      case FirestoreCollections.budgets:
        return fromList(
          await DriftFinanceRepository(_db).listBudgets(includeDeleted: true),
          (record) => record.id,
          budgetToFirestore,
        );
      case FirestoreCollections.financeCategories:
        return fromList(
          await DriftFinanceRepository(_db).listCategories(includeDeleted: true),
          (record) => record.id,
          financeCategoryToFirestore,
        );
      case FirestoreCollections.assets:
        return fromList(
          await DriftFinanceRepository(_db).listAssets(includeDeleted: true),
          (record) => record.id,
          assetToFirestore,
        );
      case FirestoreCollections.assetValuations:
        return fromList(
          await DriftFinanceRepository(_db).listAssetValuations(
            includeDeleted: true,
          ),
          (record) => record.id,
          assetValuationToFirestore,
        );
      case FirestoreCollections.savingsGoals:
        return fromList(
          await DriftFinanceRepository(_db).listSavingsGoals(
            includeDeleted: true,
          ),
          (record) => record.id,
          savingsGoalToFirestore,
        );
      case FirestoreCollections.goalAllocations:
        return fromList(
          await DriftFinanceRepository(_db).listGoalAllocations(
            includeDeleted: true,
          ),
          (record) => record.id,
          goalAllocationToFirestore,
        );
      case FirestoreCollections.pinnedNotes:
        return byId(
          DriftNotificationRepository(_db).getPinnedNote,
          pinnedNoteToFirestore,
        );
      case FirestoreCollections.dismissedNotifications:
        return byId(
          DriftNotificationRepository(_db).getDismissal,
          dismissedNotificationToFirestore,
        );
      case FirestoreCollections.bucketListItems:
        return byId(
          DriftBucketListRepository(_db).getItem,
          bucketListItemToFirestore,
        );
      case FirestoreCollections.tagColors:
        return byId(
          DriftSettingsRepository(_db).getTagColorRecord,
          tagColorToFirestore,
        );
      case FirestoreCollections.customWords:
        return byId(
          DriftSettingsRepository(_db).getCustomWordRecord,
          customWordToFirestore,
        );
      case FirestoreCollections.settings:
        // One document, not a collection, and it always exists — `getSettings`
        // inserts the default row rather than returning null.
        final settings = await DriftSettingsRepository(_db).getSettings();
        return {
          FirestoreCollections.settingsDocumentId: settingsToFirestore(settings),
        };
      default:
        return const {};
    }
  }

  /// Writes each queued upload on its own so one rejected document can't take
  /// the rest of the batch down with it.
  ///
  /// Returns whether the queue actually shrank — either because a write landed
  /// or because a row was parked. A false return means every row failed for a
  /// reason that might clear up later, and the caller should stop rather than
  /// retry them immediately.
  Future<bool> _drainIndividually(List<_PendingUpload> uploads) async {
    var progressed = false;
    for (final upload in uploads) {
      try {
        await upload.reference.set(upload.data, SetOptions(merge: true));
        await _clearPending([upload.pending]);
        progressed = true;
      } catch (error) {
        if (await _handleUploadFailure(upload.pending, error)) {
          progressed = true;
        }
      }
    }
    return progressed;
  }

  /// Returns whether the row was parked (and so left the retry queue).
  Future<bool> _handleUploadFailure(
    PendingUploadData pending,
    Object error,
  ) async {
    if (classifySyncFailure(error) == SyncFailureKind.permanent) {
      await park(
        collection: pending.collectionName,
        documentId: pending.documentId,
        reason: describeSyncFailure(error),
      );
      return true;
    }

    // Classification defaults to "transient" for anything it doesn't
    // recognise, so without an age cap a misclassified permanent failure would
    // retry on every launch forever. [enqueue] deliberately leaves `addedAt`
    // alone on a re-queue, which is what makes this age mean anything.
    final age = DateTime.now().toUtc().difference(pending.addedAt.toUtc());
    if (age > maxRetryAge) {
      await park(
        collection: pending.collectionName,
        documentId: pending.documentId,
        reason:
            'Gave up after ${maxRetryAge.inDays} days of retries. '
            '${describeSyncFailure(error)}',
      );
      return true;
    }

    // Otherwise leave it queued for the next drain.
    return false;
  }

  Future<void> _clearPending(List<PendingUploadData> rows) async {
    final keys = await _loadRowKeys();
    for (final row in rows) {
      keys.remove(_rowKey(row.collectionName, row.documentId));
      await (_db.delete(_db.pendingUploadsTable)..where(
            (t) =>
                t.documentId.equals(row.documentId) &
                t.collectionName.equals(row.collectionName),
          ))
          .go();
    }
  }

  /// Collections [_payloadsFor] knows how to rebuild a write for.
  ///
  /// A queued row for anything else could never be drained, so failures in
  /// those collections are parked rather than queued — an unretryable row that
  /// looks retryable is worse than an honest record of the failure.
  ///
  /// That is now every collection the app syncs, plus the settings document.
  /// While it held only four, the seventeen collections that upload through
  /// `SyncedWriteNotifier` — every finance table, calendars, trackers, pinned
  /// notes, tag colours — had no retry path at all, and nothing else re-pushed
  /// them: the backfill runs once per device and a pull never triggers a push.
  static final drainableCollections = {
    ...FirestoreCollections.records,
    FirestoreCollections.settings,
  };

  String _rowKey(String collection, String documentId) =>
      '$collection/$documentId';

  /// Keys of every row in the table, so the common case — a document that has
  /// never failed — costs no query on the success path.
  Set<String>? _rowKeys;

  Future<Set<String>> _loadRowKeys() async {
    return _rowKeys ??= {
      for (final row in await _db.select(_db.pendingUploadsTable).get())
        _rowKey(row.collectionName, row.documentId),
    };
  }

  /// Queues [documentId] for a later retry after an upload failed for a reason
  /// that may not recur.
  Future<void> enqueue({
    required String collection,
    required String documentId,
  }) async {
    (await _loadRowKeys()).add(_rowKey(collection, documentId));
    await _db
        .into(_db.pendingUploadsTable)
        .insert(
          PendingUploadsTableCompanion.insert(
            documentId: documentId,
            collectionName: collection,
            addedAt: Value(DateTime.now().toUtc()),
            failureReason: const Value(null),
          ),
          // An existing row keeps its original `addedAt`. Refreshing it on
          // every re-queue is what let a row outlive [maxRetryAge] forever:
          // each failed upload of a document the user is still editing queued
          // it again with a fresh timestamp, so its age reset faster than the
          // cap could ever expire it — and, since the drain works in `addedAt`
          // order, it kept jumping the queue too.
          //
          // `failureReason` is still cleared: a document parked earlier that
          // has started failing in a retryable way belongs back in the queue.
          onConflict: DoUpdate(
            (_) => const PendingUploadsTableCompanion(
              failureReason: Value(null),
            ),
          ),
        );
  }

  /// Forgets any queued or parked row for [documentId], because it has now
  /// uploaded successfully.
  Future<void> clearFor({
    required String collection,
    required String documentId,
  }) async {
    final keys = await _loadRowKeys();
    if (!keys.remove(_rowKey(collection, documentId))) return;
    await (_db.delete(_db.pendingUploadsTable)..where(
          (t) =>
              t.documentId.equals(documentId) &
              t.collectionName.equals(collection),
        ))
        .go();
  }

  /// Records that [documentId] could not be uploaded and won't be retried.
  ///
  /// The row stays in the table rather than being deleted, so the fact that
  /// this document never reached the server survives a restart.
  Future<void> park({
    required String collection,
    required String documentId,
    required String reason,
  }) async {
    (await _loadRowKeys()).add(_rowKey(collection, documentId));
    await _db
        .into(_db.pendingUploadsTable)
        .insertOnConflictUpdate(
          PendingUploadsTableCompanion.insert(
            documentId: documentId,
            collectionName: collection,
            addedAt: Value(DateTime.now().toUtc()),
            failureReason: Value(reason),
          ),
        );
    print('Sync parked $collection/$documentId: $reason');
  }

  /// Uploads that were abandoned, newest first.
  Future<List<PendingUploadData>> listParked() {
    return (_db.select(_db.pendingUploadsTable)
          ..where((t) => t.failureReason.isNotNull())
          ..orderBy([(t) => OrderingTerm.desc(t.addedAt)]))
        .get();
  }

  /// Queues a failed upload without requiring callers to hold the database.
  ///
  /// No-ops before [initialize] — in tests and in the signed-out state there
  /// is no outbox to queue into.
  static Future<void> recordFailure({
    required String collection,
    required String documentId,
    required Object error,
  }) async {
    if (!isInitialized) return;
    final permanent =
        classifySyncFailure(error) == SyncFailureKind.permanent;
    if (permanent || !drainableCollections.contains(collection)) {
      await instance.park(
        collection: collection,
        documentId: documentId,
        reason: permanent
            ? describeSyncFailure(error)
            : 'No automatic retry for $collection. '
                  '${describeSyncFailure(error)}',
      );
    } else {
      await instance.enqueue(collection: collection, documentId: documentId);
    }
  }

  /// Clears a document's queued or parked row after it uploaded successfully,
  /// so a past failure doesn't linger as a false report.
  static Future<void> recordSuccess({
    required String collection,
    required String documentId,
  }) async {
    if (!isInitialized) return;
    await instance.clearFor(collection: collection, documentId: documentId);
  }
}

/// A queued upload paired with the write it resolved to.
class _PendingUpload {
  const _PendingUpload({
    required this.pending,
    required this.reference,
    required this.data,
  });

  final PendingUploadData pending;

  /// Where the document lives remotely, which is not always
  /// `pending.documentId` — see [firestoreDocumentIdForLocal].
  final DocumentReference<Map<String, dynamic>> reference;

  final Map<String, dynamic> data;
}
