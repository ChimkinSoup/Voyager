import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/job_models.dart';
import 'package:voyager/domain/models/ranking_models.dart';
import 'package:voyager/features/settings/services/auto_backup_retention.dart';
import 'package:voyager/features/settings/services/auto_backup_service.dart';
import 'package:voyager/features/settings/services/data_export_service.dart';

import 'import_export_test.dart'
    show RecordingUploader, collectionsFor, importerFor, seedOneOfEverything;

/// Firestore `set(..., SetOptions(merge: true))`: nested maps merge key by
/// key, so a key the payload leaves out keeps its stored value.
Map<String, dynamic> firestoreMerge(
  Map<String, dynamic>? stored,
  Map<String, dynamic> incoming,
) {
  final out = Map<String, dynamic>.from(stored ?? const {});
  for (final entry in incoming.entries) {
    final old = out[entry.key];
    out[entry.key] = entry.value is Map && old is Map
        ? firestoreMerge(
            Map<String, dynamic>.from(old),
            Map<String, dynamic>.from(entry.value as Map),
          )
        : entry.value;
  }
  return out;
}

/// One collection merged field by field, as the restore and sync see it.
class _Kind<T> {
  const _Kind({
    required this.collection,
    required this.id,
    required this.read,
    required this.write,
    required this.toFirestore,
    required this.resolve,
    required this.edit,
    required this.describe,
  });

  final String collection;
  final String id;
  final Future<T> Function(AppDatabase db) read;
  final Future<void> Function(AppDatabase db, T row) write;
  final Map<String, dynamic> Function(T row) toFirestore;
  final RankingMergeResult<T> Function(Map<String, dynamic> data, T local)
  resolve;

  /// An edit after the backup, clearing something the backup holds.
  final T Function(T row) edit;
  final String Function(T row) describe;

  /// Here rather than at the call site, which only sees `_Kind<Object>`.
  Future<void> restoreThenUndo() => _restoreThenUndo<T>(this);

  /// The shared restore callback, as the trash and colour replacement call
  /// it: not a new edit of every field, so the stamps stay as they were.
  Future<void> restoreInPlace() async {
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    await seedOneOfEverything(db);
    final before = toFirestore(await read(db));
    await collectionsFor(
      db,
    ).firstWhere((c) => c.name == collection).restore(id, before);
    final after = toFirestore(await read(db));
    expect(after['fieldUpdatedAt'], before['fieldUpdatedAt']);
  }
}

final _kinds = <_Kind<Object>>[
  _Kind<RankingParent>(
    collection: FirestoreCollections.rankingParents,
    id: 'ranking-parent-1',
    read: (db) async =>
        (await DriftRankingRepository(db).getParent('ranking-parent-1'))!,
    write: (db, row) => DriftRankingRepository(db).upsertParent(row),
    toFirestore: rankingParentToFirestore,
    resolve: (data, local) =>
        resolveRankingParentFromRemote(data, local.id, local: local),
    edit: (row) => row.copyWith(
      title: 'Edited',
      clearOverallScore: true,
      fieldValues: const {},
    ),
    describe: (r) =>
        '${r.title} ${r.overallScore} ${r.notes} '
        '${{for (final e in r.fieldValues.entries) e.key: '${e.value.score}/${e.value.notes}'}}',
  ),
  _Kind<RankingChild>(
    collection: FirestoreCollections.rankingChildren,
    id: 'ranking-child-1',
    read: (db) async =>
        (await DriftRankingRepository(db).getChild('ranking-child-1'))!,
    write: (db, row) => DriftRankingRepository(db).upsertChild(row),
    toFirestore: rankingChildToFirestore,
    resolve: (data, local) =>
        resolveRankingChildFromRemote(data, local.id, local: local),
    edit: (row) => row.copyWith(
      name: 'Edited',
      clearOverallScore: true,
      fieldValues: const {},
    ),
    describe: (r) =>
        '${r.name} ${r.overallScore} ${r.notes} '
        '${{for (final e in r.fieldValues.entries) e.key: '${e.value.score}/${e.value.notes}'}}',
  ),
  _Kind<JobApplication>(
    collection: FirestoreCollections.jobApplications,
    id: 'application-1',
    read: (db) async =>
        (await DriftJobRepository(db).getApplication('application-1'))!,
    write: (db, row) => DriftJobRepository(db).upsertApplication(row),
    toFirestore: jobApplicationToFirestore,
    resolve: (data, local) =>
        resolveJobApplicationFromRemote(data, local.id, local: local),
    edit: (row) => row.copyWith(
      status: 'Rejected',
      clearApplicationUrl: true,
      clearNotes: true,
    ),
    describe: (r) =>
        '${r.company} ${r.title} ${r.status} ${r.applicationUrl} ${r.notes} '
        '${r.dateApplied.toUtc()} ${r.seasonIds}',
  ),
];

Future<void> _restoreThenUndo<T>(_Kind<T> kind) async {
  final db = AppDatabase.inMemory();
  addTearDown(db.close);
  await seedOneOfEverything(db);
  final dir = await Directory.systemTemp.createTemp('voyager_stamps');
  addTearDown(() => dir.delete(recursive: true));
  var now = DateTime(2026, 9, 24, 9);
  final uploads = <RecordingUploader>[];
  final service = AutoBackupService(
    directory: () async => dir,
    exporter: () => DataExportService(
      db: db,
      collections: collectionsFor(db),
      settingsRepository: DriftSettingsRepository(db),
    ),
    importer: () {
      final uploader = RecordingUploader();
      uploads.add(uploader);
      return importerFor(db, uploader);
    },
    freeBytes: (_) async => null,
    now: () => now,
  );
  addTearDown(service.dispose);

  // This device is A. Device B and the Firestore document are simulated.
  Map<String, dynamic>? remote;
  late T deviceB;
  void push(T row) => remote = firestoreMerge(remote, kind.toFirestore(row));
  void pushUploads() {
    for (final row in uploads.last.records[kind.collection] ?? const []) {
      push(row as T);
    }
  }

  Future<void> syncBoth() async {
    for (var round = 0; round < 2; round++) {
      final fromB = kind.resolve(remote!, deviceB);
      deviceB = fromB.merged;
      if (fromB.localWon) push(deviceB);
      final a = await kind.read(db);
      final fromA = kind.resolve(remote!, a);
      if (!identical(fromA.merged, a)) await kind.write(db, fromA.merged);
      if (fromA.localWon) push(fromA.merged);
    }
  }

  push(await kind.read(db));
  deviceB = await kind.read(db);
  await service.runIfDue();
  final backup = File(
    p.join(
      dir.path,
      dir
          .listSync()
          .map((f) => p.basename(f.path))
          .firstWhere(autoBackupNamePattern.hasMatch),
    ),
  );
  final atBackup = kind.describe(await kind.read(db));

  // Edited on A after the backup, and synced to B.
  final edited = kind.edit(await kind.read(db));
  await kind.write(db, edited);
  push(edited);
  await syncBoth();
  final beforeRestore = kind.describe(await kind.read(db));
  expect(beforeRestore, isNot(atBackup));

  now = now.add(const Duration(hours: 1));
  await service.restore(backup);
  pushUploads();
  await syncBoth();
  expect(kind.describe(await kind.read(db)), atBackup, reason: 'restore, A');
  expect(kind.describe(deviceB), atBackup, reason: 'restore, B');

  final undo = (await service.listBackups()).firstWhere((e) => e.isSnapshot);
  now = now.add(const Duration(hours: 1));
  await service.restore(undo.file);
  pushUploads();
  await syncBoth();
  expect(kind.describe(await kind.read(db)), beforeRestore, reason: 'undo, A');
  expect(kind.describe(deviceB), beforeRestore, reason: 'undo, B');
}

void main() {
  // Restores and undoes as seen by a second device, through Firestore's
  // merging writes — where a restored row that kept its backup's stamps, or
  // left out a field the backup lacks, was outranked by the edit it replaced.
  for (final kind in _kinds) {
    test(
      '${kind.collection}: a restore and its undo land on every device, '
      'cleared fields included',
      kind.restoreThenUndo,
    );
    test(
      '${kind.collection}: the trash and colour replacement, which share '
      'the restore callback, leave field stamps alone',
      kind.restoreInPlace,
    );
  }
}
