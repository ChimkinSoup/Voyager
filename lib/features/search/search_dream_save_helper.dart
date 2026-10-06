import 'package:flutter/material.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/journal_write_coordinator.dart';
import 'package:voyager/core/sync/outbox_sync_worker.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/utils/journal_tags.dart';
import 'package:voyager/domain/models/dream_models.dart';

/// [SearchEntrySaveHelper] for a dream opened from the Search page's dream
/// scope.
class SearchDreamSaveHelper {
  SearchDreamSaveHelper({required this.coordinator, required this.remoteSync});

  final DreamWriteCoordinator coordinator;
  final RemoteSyncService remoteSync;

  Future<DreamEntry?> saveEntry({
    required DreamEntry baseline,
    required String title,
    required String body,
    required String notes,
    DateTime? entryDate,
    bool publish = true,
  }) async {
    DreamEntry? result;
    try {
      await coordinator.saveEntry(
        entryId: baseline.id,
        bumpVersion: true,
        applyDelta: (base) => base.copyWith(
          title: title,
          body: body,
          notes: notes,
          tags: extractTags(body),
          entryDate: entryDate ?? base.entryDate,
          bumpVersion: false,
        ),
        onSuccess: (saved) {
          result = saved;
        },
      );
    } catch (error, stackTrace) {
      // The local write itself failed — a locked database, or a row that is
      // gone, which [DreamWriteCoordinator] throws a StateError for. There is
      // nothing on disk for the caller to show.
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'SearchDreamSaveHelper',
          context: ErrorDescription('while saving a dream from Search'),
        ),
      );
      return null;
    }
    if (result == null) return null;
    // Local-only, as [SearchEntrySaveHelper.saveEntry] explains.
    if (!publish) {
      remoteSync.cancelDocument(FirestoreCollections.dreamEntries, baseline.id);
      try {
        await OutboxSyncWorker.recordCrdtOverwrite(
          collection: FirestoreCollections.dreamEntries,
          documentId: baseline.id,
        );
      } catch (error, stackTrace) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stackTrace,
            library: 'SearchDreamSaveHelper',
            context: ErrorDescription('while queueing a dream from Search'),
          ),
        );
      }
      return result;
    }
    return publishEntry(result!);
  }

  /// Publishes [entry], a row already on disk, and returns what was published
  /// (or [entry] itself if publishing failed).
  Future<DreamEntry> publishEntry(DreamEntry entry) async {
    // Same reason as the journal side (see [SearchEntrySaveHelper.saveEntry]):
    // this dialog keeps no CRDT editing session, so the debounced upload
    // scheduled above would push a new body with no character operations
    // behind it and the next pull would resolve the stale log back over it.
    // Reported separately from the save so a publish failure cannot discard a
    // row that is already on disk.
    try {
      remoteSync.cancelDocument(FirestoreCollections.dreamEntries, entry.id);
      return await remoteSync.forceOverwriteDreamEntryText(entry);
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'SearchDreamSaveHelper',
          context: ErrorDescription('while publishing a dream from Search'),
        ),
      );
      return entry;
    }
  }
}
