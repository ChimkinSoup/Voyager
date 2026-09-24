import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/data/services/media_file_store.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/media_models.dart';
import 'package:voyager/features/settings/services/auto_backup_retention.dart';
import 'package:voyager/features/settings/services/auto_backup_service.dart';
import 'package:voyager/features/settings/services/backup_collections.dart';
import 'package:voyager/features/settings/services/data_export_service.dart';
import 'package:voyager/features/settings/services/data_import_service.dart';

import 'import_export_test.dart'
    show RecordingUploader, collectionsFor, importerFor, seedOneOfEverything;

/// A service over an in-memory database and a temp backups folder, with a
/// clock and free space the test controls.
class Harness {
  Harness._(this.db, this.dir);

  static Future<Harness> create() async {
    final db = AppDatabase.inMemory();
    await seedOneOfEverything(db);
    final dir = await Directory.systemTemp.createTemp('voyager_auto_backup');
    final harness = Harness._(db, dir);
    addTearDown(() async {
      harness.service.dispose();
      await db.close();
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    return harness;
  }

  final AppDatabase db;
  final Directory dir;
  DateTime now = DateTime(2026, 9, 24, 9);
  int? freeBytes;
  bool failExport = false;

  late final service = AutoBackupService(
    directory: () async => dir,
    exporter: () => DataExportService(
      db: db,
      collections: failExport
          ? [
              BackupCollection(
                name: 'broken',
                read: () => throw StateError('disk read failed'),
                restore: (_, _) => throw UnimplementedError(),
              ),
            ]
          : collectionsFor(db),
      settingsRepository: DriftSettingsRepository(db),
    ),
    importer: () => importerFor(db, RecordingUploader()),
    freeBytes: (_) async => freeBytes,
    now: () => now,
  );

  List<String> files() =>
      [for (final f in dir.listSync()) p.basename(f.path)]..sort();

  List<String> autoFiles() => [
    for (final name in files())
      if (autoBackupNamePattern.hasMatch(name)) name,
  ];

  void nextDay() => now = now.add(const Duration(days: 1));
}

/// Rewrites [member] of the backup at [file] through [change], keeping valid
/// ZIP framing so only the backup's own checks can notice.
void rewriteMember(
  File file,
  String member,
  List<int> Function(List<int> bytes) change,
) {
  final archive = ZipDecoder().decodeBytes(file.readAsBytesSync());
  final rebuilt = Archive();
  for (final entry in archive.files) {
    final content = entry.content as List<int>;
    final bytes = entry.name == member ? change(content) : content;
    rebuilt.addFile(ArchiveFile(entry.name, bytes.length, bytes));
  }
  file.writeAsBytesSync(ZipEncoder().encode(rebuilt)!);
}

void main() {
  group('daily run', () {
    test('takes one verified backup a day and leaves no .partial', () async {
      final h = await Harness.create();
      await h.service.runIfDue();
      expect(h.autoFiles(), hasLength(1));
      expect(h.files().where((f) => f.endsWith('.partial')), isEmpty);
      await verifyBackupFile(File(p.join(h.dir.path, h.autoFiles().single)));

      h.now = h.now.add(const Duration(hours: 5));
      await h.service.runIfDue();
      expect(h.autoFiles(), hasLength(1), reason: 'one per local day');

      h.nextDay();
      await h.service.runIfDue();
      expect(h.autoFiles(), hasLength(2));
      final status = await h.service.refreshStatus();
      expect(status.health, AutoBackupHealth.healthy);
      expect(status.backupCount, 2);
    });

    test('a failed export keeps every backup and records why', () async {
      final h = await Harness.create();
      await h.service.runIfDue();
      final before = h.files();

      h.nextDay();
      h.failExport = true;
      await h.service.runIfDue();

      expect(
        h.files().where((f) => f != 'state.json'),
        before.where((f) => f != 'state.json'),
      );
      final status = await h.service.refreshStatus();
      expect(status.health, AutoBackupHealth.attention);
      expect(status.detail, contains('disk read failed'));
    });

    test('too little free space skips the run and deletes nothing', () async {
      final h = await Harness.create();
      await h.service.runIfDue();
      final before = h.autoFiles();

      h.nextDay();
      h.freeBytes = 10;
      await h.service.runIfDue();

      expect(h.autoFiles(), before);
      final status = await h.service.refreshStatus();
      expect(status.health, AutoBackupHealth.attention);
      expect(status.detail, startsWith('Not enough free space'));
    });

    test('leftover .partial files are cleared on start', () async {
      final h = await Harness.create();
      File(
        p.join(h.dir.path, 'voyager_auto_2026-01-01_00-00-00+0000.zip.partial'),
      ).writeAsStringSync('half');
      h.service.start();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(h.files().where((f) => f.endsWith('.partial')), isEmpty);
    });

    test('backups with old UTC names are renamed on start', () async {
      final h = await Harness.create();
      await h.service.runIfDue();
      final current = File(p.join(h.dir.path, h.autoFiles().single));
      final legacy = File(
        p.join(h.dir.path, 'voyager_auto_20260920T130000Z.zip'),
      );
      await current.copy(legacy.path);

      h.service.start();
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(legacy.existsSync(), isFalse);
      final captured = [
        for (final e in await h.service.listBackups()) e.capturedAt,
      ];
      expect(captured, contains(DateTime.utc(2026, 9, 20, 13)));
    });

    test('a damaged retained backup is set aside and flagged', () async {
      final h = await Harness.create();
      await h.service.runIfDue();
      final damaged = File(p.join(h.dir.path, h.autoFiles().single));
      damaged.writeAsBytesSync([1, 2, 3]);

      h.nextDay();
      await h.service.runIfDue();

      expect(h.autoFiles(), isNot(contains(p.basename(damaged.path))));
      expect(h.autoFiles(), hasLength(1));
      expect(
        File('${damaged.path}${AutoBackupService.damagedSuffix}').existsSync(),
        isTrue,
        reason: 'moved aside, not deleted',
      );
      final status = await h.service.refreshStatus();
      expect(status.health, AutoBackupHealth.attention);
      expect(status.detail, contains('failed re-verification'));
    });

    test('a backup in another format is kept, hidden, and not damage', () async {
      final h = await Harness.create();
      await h.service.runIfDue();
      final older = File(p.join(h.dir.path, h.autoFiles().single));
      rewriteMember(older, backupManifestFileName, (bytes) {
        final manifest = jsonDecode(utf8.decode(bytes)) as Map;
        return utf8.encode(jsonEncode({...manifest, 'formatVersion': 1}));
      });

      h.nextDay();
      await h.service.runIfDue();

      expect(
        File('${older.path}${AutoBackupService.unsupportedSuffix}')
            .existsSync(),
        isTrue,
      );
      expect(h.autoFiles(), hasLength(1));
      final status = await h.service.refreshStatus();
      expect(status.backupCount, 1);
      expect(status.health, AutoBackupHealth.healthy);
    });

    test(
      'a backup that cannot be read just now is kept and flagged',
      () async {
        final h = await Harness.create();
        await h.service.runIfDue();
        final held = File(p.join(h.dir.path, h.autoFiles().single));
        final handle = held.openSync(mode: FileMode.append)
          ..lockSync(FileLock.exclusive);
        addTearDown(handle.closeSync);

        h.nextDay();
        await h.service.runIfDue();

        expect(h.autoFiles(), contains(p.basename(held.path)));
        final status = await h.service.refreshStatus();
        expect(status.health, AutoBackupHealth.attention);
        expect(status.detail, contains('could not be re-checked'));
      },
      skip: Platform.isWindows ? false : 'relies on Windows file locking',
    );

    test(
      'a failed prune is shown, and the retry finishes it without another '
      'backup',
      () async {
        final h = await Harness.create();
        for (var day = 0; day < 4; day++) {
          await h.service.runIfDue();
          h.nextDay();
        }
        // Day 5 prunes day 2: the three newest stay, and day 1 is rising.
        final doomed = File(p.join(h.dir.path, h.autoFiles()[1]));
        final handle = doomed.openSync();
        await h.service.runIfDue();
        handle.closeSync();

        var status = await h.service.refreshStatus();
        expect(status.health, AutoBackupHealth.attention);
        final afterFailure = h.autoFiles();
        expect(afterFailure, contains(p.basename(doomed.path)));

        h.now = h.now.add(const Duration(hours: 1));
        await h.service.runIfDue();
        expect(h.autoFiles(), hasLength(afterFailure.length - 1));
        expect(h.autoFiles(), isNot(contains(p.basename(doomed.path))));
        status = await h.service.refreshStatus();
        expect(status.health, AutoBackupHealth.healthy);
      },
      skip: Platform.isWindows ? false : 'relies on Windows file locking',
    );

    test('a name clash fails the run instead of replacing a backup', () async {
      final h = await Harness.create();
      await h.service.runIfDue();
      final first = File(p.join(h.dir.path, h.autoFiles().single));
      final bytes = first.readAsBytesSync();

      // Forces a second backup at the same second.
      await h.service.setSimulateFailure(false);

      expect(first.readAsBytesSync(), bytes);
      final status = await h.service.refreshStatus();
      expect(status.health, AutoBackupHealth.attention);
      expect(status.detail, contains('already exists'));
    });

    test('a toggle flipped during a run is not lost', () async {
      final h = await Harness.create();
      await Future.wait([h.service.runIfDue(), h.service.setEnabled(false)]);
      expect((await h.service.refreshStatus()).enabled, isFalse);
    });

    test('pruning never touches files it does not own', () async {
      final h = await Harness.create();
      final foreign = [
        'voyager_backup_1727000000000.zip',
        'notes.txt',
        'voyager_auto_2020-01-01_00-00-00+0000 (1).zip',
      ];
      for (final name in foreign) {
        File(p.join(h.dir.path, name)).writeAsStringSync('mine');
      }
      for (var day = 0; day < 40; day++) {
        await h.service.runIfDue();
        h.nextDay();
      }
      expect(h.files(), containsAll(foreign));
      expect(h.autoFiles().length, lessThanOrEqualTo(7));
    });
  });

  group('verification', () {
    test('a member that does not match its checksum is refused', () async {
      final h = await Harness.create();
      await h.service.runIfDue();
      final file = File(p.join(h.dir.path, h.autoFiles().single));

      // Rewrite one member with valid zip framing but different bytes, so
      // only the checksum can catch it.
      rewriteMember(
        file,
        '${FirestoreCollections.journals}.json',
        (_) => '[]'.codeUnits,
      );

      await expectLater(
        verifyBackupFile(file),
        throwsA(isA<BackupDamagedException>()),
      );
    });

    test('media names cannot point outside the cache', () async {
      final root = await Directory.systemTemp.createTemp('voyager_media');
      addTearDown(() => root.delete(recursive: true));
      final store = MediaFileStore(root: Directory(p.join(root.path, 'media')));
      final outside = File(p.join(root.path, 'outside.png'))
        ..writeAsStringSync('keep');

      await expectLater(
        store.writeBytes('../outside', MediaImageFormat.png, Uint8List(4)),
        throwsArgumentError,
      );
      await store.deleteBytes('../outside', MediaImageFormat.png);
      expect(outside.readAsStringSync(), 'keep');
    });

    test('a write during export lands entirely or not at all', () async {
      final h = await Harness.create();
      final repo = DriftJournalRepository(h.db);
      final now = DateTime.utc(2026, 9, 24);
      final export = DataExportService(
        db: h.db,
        collections: collectionsFor(h.db),
        settingsRepository: DriftSettingsRepository(h.db),
      ).buildArchiveContents();
      final write = h.db.transaction(() async {
        await repo.upsertJournal(
          Journal(id: 'j-new', name: 'New', createdAt: now, updatedAt: now),
        );
        await repo.upsertEntry(
          JournalEntry(
            id: 'e-new',
            journalId: 'j-new',
            title: 'x',
            body: 'y',
            entryDate: now,
            createdAt: now,
            updatedAt: now,
          ),
        );
      });
      final contents = await export;
      await write;

      bool has(String file, String id) =>
          (contents[file] as List).any((r) => (r as Map)['id'] == id);
      expect(
        has('${FirestoreCollections.journals}.json', 'j-new'),
        has('${FirestoreCollections.journalEntries}.json', 'e-new'),
      );
    });
  });

  group('restore', () {
    test('takes a snapshot first, and restoring it undoes the restore '
        '(including an un-delete)', () async {
      final h = await Harness.create();
      final repo = DriftJournalRepository(h.db);
      await h.service.runIfDue();
      final backup = File(p.join(h.dir.path, h.autoFiles().single));

      // After the backup: the entry is deleted.
      await repo.softDeleteEntry('entry-1');

      h.now = h.now.add(const Duration(hours: 1));
      await h.service.restore(backup);
      expect((await repo.getEntry('entry-1'))?.deletedAt, isNull);

      final snapshots = [
        for (final e in await h.service.listBackups())
          if (e.isSnapshot) e,
      ];
      expect(snapshots, hasLength(1));

      h.now = h.now.add(const Duration(hours: 1));
      await h.service.restore(snapshots.single.file);
      expect(
        (await repo.getEntry('entry-1'))?.deletedAt,
        isNotNull,
        reason: 'undoing the restore brings the tombstone back',
      );
      // Restoring the snapshot took its own snapshot.
      expect(
        (await h.service.listBackups()).where((e) => e.isSnapshot),
        hasLength(2),
      );
    });

    test('a failed snapshot blocks the restore', () async {
      final h = await Harness.create();
      final repo = DriftJournalRepository(h.db);
      await h.service.runIfDue();
      final backup = File(p.join(h.dir.path, h.autoFiles().single));
      await repo.softDeleteEntry('entry-1');

      h.failExport = true;
      await expectLater(h.service.restore(backup), throwsA(anything));
      expect((await repo.getEntry('entry-1'))?.deletedAt, isNotNull);
      expect(h.files().where((f) => f.startsWith(preRestorePrefix)), isEmpty);
    });

    test('a second restore while one runs is refused', () async {
      final h = await Harness.create();
      await h.service.runIfDue();
      final backup = File(p.join(h.dir.path, h.autoFiles().single));
      final first = h.service.restore(backup);
      await expectLater(h.service.restore(backup), throwsA(anything));
      await first;
    });

    test('snapshots expire with automatic backups off too', () async {
      final h = await Harness.create();
      await h.service.runIfDue();
      await h.service.restore(File(p.join(h.dir.path, h.autoFiles().single)));
      await h.service.setEnabled(false);
      for (var day = 0; day < 8; day++) {
        h.nextDay();
        await h.service.runIfDue();
      }
      expect((await h.service.refreshStatus()).snapshotCount, 0);
    });

    test('snapshots expire after 7 days and never count as backups', () async {
      final h = await Harness.create();
      await h.service.runIfDue();
      await h.service.restore(File(p.join(h.dir.path, h.autoFiles().single)));
      expect((await h.service.refreshStatus()).snapshotCount, 1);

      for (var day = 0; day < 8; day++) {
        h.nextDay();
        await h.service.runIfDue();
      }
      final status = await h.service.refreshStatus();
      expect(status.snapshotCount, 0);
      expect(status.backupCount, lessThanOrEqualTo(7));
    });
  });

  group('health and toggle (§9.3)', () {
    test('nothing yet reads as not yet backed up, and on', () async {
      final h = await Harness.create();
      final status = await h.service.refreshStatus();
      expect(status.enabled, isTrue, reason: 'no state.json reads as on');
      expect(status.health, AutoBackupHealth.notYetBackedUp);
    });

    test('off stops runs and pruning but keeps every file', () async {
      final h = await Harness.create();
      for (var day = 0; day < 5; day++) {
        await h.service.runIfDue();
        h.nextDay();
      }
      final before = h.autoFiles();
      await h.service.setEnabled(false);
      for (var day = 0; day < 40; day++) {
        await h.service.runIfDue();
        h.nextDay();
      }
      expect(h.autoFiles(), before);
      final status = await h.service.refreshStatus();
      expect(status.health, AutoBackupHealth.off);
      expect(status.failing, isFalse);
    });

    test('turning it on runs the check at once', () async {
      final h = await Harness.create();
      await h.service.setEnabled(false);
      expect(h.autoFiles(), isEmpty);
      await h.service.setEnabled(true);
      expect(h.autoFiles(), hasLength(1));
    });

    test('a day the app was open without a backup needs attention', () async {
      final h = await Harness.create();
      await h.service.runIfDue();
      // Next day: opened, but the backup fails.
      h.nextDay();
      h.failExport = true;
      await h.service.runIfDue();
      // Day after: it works again, but the missed day stays visible until
      // a backup lands.
      h.failExport = false;
      h.nextDay();
      final status = await h.service.refreshStatus();
      expect(status.health, AutoBackupHealth.attention);
    });

    test('an old backup with no open day since is just due', () async {
      final h = await Harness.create();
      await h.service.runIfDue();
      h.now = h.now.add(const Duration(days: 5));
      final status = await h.service.refreshStatus();
      expect(status.health, AutoBackupHealth.due);
    });

    test('two open days in a row without a backup raise the Inbox alert '
        '(§9.4)', () async {
      final h = await Harness.create();
      await h.service.runIfDue();
      h.failExport = true;

      h.nextDay();
      await h.service.runIfDue();
      expect((await h.service.refreshStatus()).failing, isFalse);

      h.nextDay();
      await h.service.runIfDue();
      expect((await h.service.refreshStatus()).failing, isTrue);

      h.failExport = false;
      await h.service.runIfDue();
      final status = await h.service.refreshStatus();
      expect(status.failing, isFalse);
      expect(status.health, AutoBackupHealth.healthy);
    });

    test('the Dev page simulation raises the alert at once, and turning it '
        'off clears it with a real backup', () async {
      final h = await Harness.create();
      await h.service.runIfDue();
      final before = h.autoFiles();

      h.now = h.now.add(const Duration(minutes: 5));
      await h.service.setSimulateFailure(true);
      var status = await h.service.refreshStatus();
      expect(status.failing, isTrue);
      expect(status.health, AutoBackupHealth.attention);
      expect(status.detail, 'Simulated failure (Dev page)');
      expect(h.autoFiles(), before, reason: 'a failed run deletes nothing');

      // Retry goes through the same run and fails the same way.
      await h.service.runIfDue();
      expect((await h.service.refreshStatus()).failing, isTrue);

      h.now = h.now.add(const Duration(minutes: 5));
      await h.service.setSimulateFailure(false);
      status = await h.service.refreshStatus();
      expect(status.failing, isFalse);
      expect(status.health, AutoBackupHealth.healthy);
      expect(await h.service.simulatesFailure(), isFalse);
    });
  });
}
