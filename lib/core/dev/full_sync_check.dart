// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:voyager/core/platform/app_data_directory.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/features/settings/services/backup_collections.dart';

/// Where [FullSyncCheck.writeReport] leaves its result, beside the database.
/// `qa/harness/reset.ps1` reads it before it will wipe that directory.
const syncCheckReportFileName = 'sync_check.json';

/// One record this device holds that the cloud copy does not.
class SyncGap {
  const SyncGap({
    required this.collection,
    required this.id,
    required this.reason,
  });

  final String collection;
  final String id;
  final String reason;
}

class FullSyncCheckReport {
  const FullSyncCheckReport({
    required this.checkedAt,
    required this.gaps,
    required this.unreadable,
  });

  final DateTime checkedAt;
  final List<SyncGap> gaps;

  /// Collections that could not be checked, and why. Any entry means the
  /// check proves nothing about that collection.
  final Map<String, String> unreadable;

  /// Whether losing this device's data would lose nothing the cloud lacks.
  bool get safeToWipe => gaps.isEmpty && unreadable.isEmpty;

  Map<String, List<SyncGap>> get gapsByCollection {
    final grouped = <String, List<SyncGap>>{};
    for (final gap in gaps) {
      (grouped[gap.collection] ??= []).add(gap);
    }
    return grouped;
  }
}

/// Compares every synced record on this device with the server's copy.
///
/// The outbox only knows about writes that failed *loudly*. A write that was
/// dropped without a trace, or a migration that rewrote rows and never
/// uploaded them, leaves the outbox empty while the cloud is behind — and
/// wiping the device then loses those changes for good. This asks the server
/// directly: a record the cloud lacks, or holds at a lower version, is a gap.
///
/// Records only the cloud holds are not gaps: the next pull brings them down.
class FullSyncCheck {
  FullSyncCheck({
    required List<BackupCollection> collections,
    required SyncRepository syncRepository,
  }) : _collections = collections,
       _syncRepository = syncRepository;

  final List<BackupCollection> _collections;
  final SyncRepository _syncRepository;

  static const _pendingWritesTimeout = Duration(seconds: 30);

  Future<FullSyncCheckReport> run() async {
    final checkedAt = utcNow();
    final gaps = <SyncGap>[];
    final unreadable = <String, String>{};

    try {
      await _syncRepository.waitForPendingWrites().timeout(
        _pendingWritesTimeout,
      );
    } on TimeoutException {
      unreadable['(pending writes)'] =
          'Firestore still holds writes the server has not confirmed';
    }

    final registered = {for (final c in _collections) c.name};
    for (final name in FirestoreCollections.records.difference(registered)) {
      unreadable[name] = 'not in the backup registry, so it cannot be read';
    }

    // Independent round trips, so all at once rather than one after another.
    final checked = await Future.wait([
      for (final collection in _collections)
        if (FirestoreCollections.records.contains(collection.name))
          _gapsIn(collection, unreadable),
    ]);
    for (final collectionGaps in checked) {
      gaps.addAll(collectionGaps);
    }

    return FullSyncCheckReport(
      checkedAt: checkedAt,
      gaps: gaps,
      unreadable: unreadable,
    );
  }

  /// The records in [collection] the cloud lacks or holds at a lower
  /// version. Records in [unreadable] why, instead, when it cannot tell.
  Future<List<SyncGap>> _gapsIn(
    BackupCollection collection,
    Map<String, String> unreadable,
  ) async {
    final name = collection.name;
    final gaps = <SyncGap>[];
    try {
      final listed = await _syncRepository.listChangedDocuments(name);
      if (!listed.fromServer) {
        unreadable[name] = 'answered from the offline cache, not the server';
        return const [];
      }
      final cloud = {for (final doc in listed.documents) doc.id: doc.data};
      for (final record in await collection.read()) {
        final remote = cloud[firestoreDocumentIdForLocal(name, record.id)];
        if (remote == null) {
          // A record deleted before it was ever uploaded loses nothing.
          if (record.data['deletedAt'] != null) continue;
          gaps.add(
            SyncGap(collection: name, id: record.id, reason: 'not in cloud'),
          );
          continue;
        }
        final local = parseVersion(record.data);
        final server = parseVersion(remote);
        if (local > server) {
          gaps.add(
            SyncGap(
              collection: name,
              id: record.id,
              reason: 'local v$local, cloud v$server',
            ),
          );
        }
      }
    } catch (error) {
      unreadable[name] = '$error';
      return const [];
    }
    return gaps;
  }

  /// The database file's change counter right now. Read it before [run] and
  /// hand it to [writeReport], so a write made while the check runs leaves
  /// the file past the report's counter.
  static Future<int?> currentDatabaseChangeCounter() async {
    final dir = await appDataDirectory();
    return databaseChangeCounter(File(p.join(dir.path, 'voyager.sqlite')));
  }

  /// Writes [report] to [syncCheckReportFileName], stamped with
  /// [dbChangeCounter] (see [currentDatabaseChangeCounter]) so the reader can
  /// tell whether anything was written since the check began.
  static Future<File> writeReport(
    FullSyncCheckReport report, {
    required int? dbChangeCounter,
  }) async {
    final dir = await appDataDirectory();
    final json = {
      'checkedAt': report.checkedAt.toIso8601String(),
      'safeToWipe': report.safeToWipe,
      'unsynced': report.gaps.length,
      'unreadable': report.unreadable,
      'collections': {
        for (final MapEntry(key: name, value: gaps)
            in report.gapsByCollection.entries)
          name: {
            'count': gaps.length,
            'examples': [
              for (final gap in gaps.take(20)) '${gap.id} (${gap.reason})',
            ],
          },
      },
      'dbChangeCounter': dbChangeCounter,
    };
    final file = File(p.join(dir.path, syncCheckReportFileName));
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(json));
    return file;
  }
}

/// SQLite's file change counter: the big-endian integer at byte 24 of the
/// header, bumped by every committed write in rollback-journal mode (the mode
/// this database runs in). Null when the file is missing or too short.
Future<int?> databaseChangeCounter(File database) async {
  if (!await database.exists()) return null;
  final handle = await database.open();
  try {
    await handle.setPosition(24);
    final bytes = await handle.read(4);
    if (bytes.length < 4) return null;
    return (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
  } finally {
    await handle.close();
  }
}
