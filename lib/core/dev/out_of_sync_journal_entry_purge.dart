import 'package:voyager/core/dev/remote_sync_compare_service.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/domain/repositories/repositories.dart';

/// A journal entry a sync compare run flagged.
class OutOfSyncJournalEntryTarget {
  const OutOfSyncJournalEntryTarget({required this.id, required this.reason});

  final String id;

  /// What the compare found: "Mismatch: body", "Missing on remote", …
  final String reason;
}

abstract final class OutOfSyncJournalEntryPurge {
  /// The entries [report] found different here and in the cloud. One missing
  /// on either side is left out: that is usually an upload or a pull still on
  /// its way, and this deletes without a trash.
  static List<OutOfSyncJournalEntryTarget> targetsFrom(
    JournalCompareReport report,
  ) => [
    for (final result in report.results)
      if (result.status == SyncCompareSyncStatus.mismatch)
        OutOfSyncJournalEntryTarget(
          id: result.entryId,
          reason: 'Mismatch: ${result.diffs.map((d) => d.field).join(', ')}',
        ),
  ];

  static Future<List<String>> purgeAll({
    required List<OutOfSyncJournalEntryTarget> targets,
    required RemoteSyncService remoteSync,
    required JournalRepository journalRepository,
    bool purgeRemote = true,
    bool purgeLocal = true,
  }) async {
    final lines = <String>[];
    for (final target in targets) {
      lines.add(
        await purgeOne(
          target: target,
          remoteSync: remoteSync,
          journalRepository: journalRepository,
          purgeRemote: purgeRemote,
          purgeLocal: purgeLocal,
        ),
      );
    }
    return lines;
  }

  static Future<String> purgeOne({
    required OutOfSyncJournalEntryTarget target,
    required RemoteSyncService remoteSync,
    required JournalRepository journalRepository,
    bool purgeRemote = true,
    bool purgeLocal = true,
  }) async {
    var remoteOps = 0;
    if (purgeRemote) {
      try {
        remoteOps = await remoteSync.permanentlyDeleteFromRemote(
          collection: FirestoreCollections.journalEntries,
          documentId: target.id,
        );
      } on Object catch (error) {
        return '${target.id}: remote purge failed ($error)';
      }
    }

    var localDeleted = false;
    if (purgeLocal) {
      final local = await journalRepository.getEntry(target.id);
      if (local != null) {
        await journalRepository.hardDeleteEntry(target.id);
        localDeleted = true;
      }
    }

    return '${target.id}: remoteOps=$remoteOps localDeleted=$localDeleted';
  }
}
