import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/domain/repositories/repositories.dart';

/// Journal entries flagged by the latest sync compare run.
class OutOfSyncJournalEntryTarget {
  const OutOfSyncJournalEntryTarget({
    required this.id,
    required this.title,
    this.searchHint,
  });

  final String id;
  final String title;
  final String? searchHint;
}

/// Targets from sync_compare.log (2026-06-28T03:02:58Z compare).
abstract final class OutOfSyncJournalEntryPurge {
  static const targets = <OutOfSyncJournalEntryTarget>[
    OutOfSyncJournalEntryTarget(
      id: '78726f1c-ff0e-44a5-9599-1b6173cfb852',
      title: 'test',
      searchHint: 'body mismatch / invalid CRDT op chain',
    ),
    OutOfSyncJournalEntryTarget(
      id: '11f53e90-395f-48c9-90bf-5348cd7090ad',
      title: '(untitled)',
      searchHint: 'body was aarrssttarstarst',
    ),
    OutOfSyncJournalEntryTarget(
      id: '64e3d931-58eb-4715-86b2-bba61a7d2405',
      title: '(untitled)',
      searchHint: 'body starts with roasiethaoriefdnoaresthoarisdkarst',
    ),
    OutOfSyncJournalEntryTarget(
      id: 'b5ada03c-3bbb-4367-8752-6dc7be87a14e',
      title: '(untitled)',
      searchHint: 'updatedAt-only mismatch',
    ),
    OutOfSyncJournalEntryTarget(
      id: 'eaf8ee6e-5c8b-4e55-8783-8c19e5c792a1',
      title: '(untitled)',
      searchHint: 'body was "this"',
    ),
  ];

  static Future<List<String>> purgeAll({
    required RemoteSyncService remoteSync,
    required JournalRepository journalRepository,
    bool purgeRemote = true,
    bool purgeLocal = true,
  }) async {
    final lines = <String>[];
    for (final target in targets) {
      lines.add(await purgeOne(
        target: target,
        remoteSync: remoteSync,
        journalRepository: journalRepository,
        purgeRemote: purgeRemote,
        purgeLocal: purgeLocal,
      ));
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
        return '${target.title} (${target.id}): remote purge failed ($error)';
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

    return '${target.title} (${target.id}): '
        'remoteOps=$remoteOps localDeleted=$localDeleted';
  }
}
