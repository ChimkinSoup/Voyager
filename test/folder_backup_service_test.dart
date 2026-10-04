import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:voyager/features/settings/services/folder_backup_retention.dart';
import 'package:voyager/features/settings/services/folder_backup_service.dart';
import 'package:voyager/features/settings/services/streaming_zip.dart';

/// A service over temp folders, with a clock, free space and the drive test
/// the test controls.
class Harness {
  Harness._(this.temp);

  static Future<Harness> create({int notes = 100}) async {
    final temp = await Directory.systemTemp.createTemp('folder_backup_svc');
    final h = Harness._(temp);
    h.vault.createSync();
    h.dest.createSync();
    for (var i = 0; i < notes; i++) {
      h.write('notes/$i.md', 'note $i ' * 20);
    }
    addTearDown(() async {
      h.service.dispose();
      if (await temp.exists()) await temp.delete(recursive: true);
    });
    return h;
  }

  final Directory temp;
  late final vault = Directory(p.join(temp.path, 'Vault'));
  late final dest = Directory(p.join(temp.path, 'Backups'));
  late final app = Directory(p.join(temp.path, 'app'));

  DateTime now = DateTime(2026, 10, 3, 9);
  int? free;
  bool sameDrive = true;
  final notifications = <String>[];

  /// Runs inside each free-space query: a point in a run's or a move's
  /// progress for a test to act at.
  Future<void> Function(String path)? onFreeBytes;

  late final service = FolderBackupService(
    directory: () async => app,
    freeBytes: (path) async {
      await onFreeBytes?.call(path);
      return free;
    },
    notify: (key, title, body) async => notifications.add('$key|$title|$body'),
    now: () => now,
    sameDrive: (_, _) => sameDrive,
  );

  late FolderBackupSource source;

  void write(String relative, String text) {
    final file = File(p.join(vault.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(text);
  }

  void remove(String relative) =>
      File(p.join(vault.path, relative)).deleteSync();

  /// Adds the vault and waits for its first check.
  Future<FolderBackupSource> add({
    Duration interval = const Duration(days: 1),
  }) async {
    source = await service.addSource(
      name: 'Obsidian',
      sourcePath: vault.path,
      destination: dest.path,
      interval: interval,
    );
    await service.runDue();
    return source;
  }

  Future<FolderBackupSource> current() async =>
      (await service.sources()).singleWhere((s) => s.id == source.id);

  /// Where [source] keeps its backups now — call [current] after a move.
  Directory get subfolder => Directory(source.subfolderPath);

  List<String> files([Directory? dir]) =>
      [for (final f in (dir ?? subfolder).listSync()) p.basename(f.path)]
        ..sort();

  List<String> rotation() => [
    for (final name in files())
      if (folderBackupRotationPattern(source.slug).hasMatch(name)) name,
  ];

  Future<FolderBackupSourceStatus> status() async =>
      (await service.refreshStatus()).sources.singleWhere(
        (s) => s.source.id == source.id,
      );

  /// A day later, with an edit so the check writes a backup.
  Future<void> nextDay({bool edit = true}) async {
    now = now.add(const Duration(days: 1));
    if (edit) write('daily/${now.toIso8601String().substring(0, 10)}.md', 'x');
    await service.runDue();
  }
}

void main() {
  group('taking backups', () {
    test('backs up, skips an unchanged folder, and backs up a touch', () async {
      final h = await Harness.create();
      await h.add();
      expect(h.rotation(), hasLength(1));
      expect((await h.status()).health, FolderBackupHealth.healthy);

      h.now = h.now.add(const Duration(days: 1));
      await h.service.runDue();
      expect(h.rotation(), hasLength(1), reason: 'unchanged writes nothing');
      final status = await h.status();
      expect(status.health, FolderBackupHealth.healthy);
      expect(status.detail, startsWith('Last checked 09:00, unchanged since'));

      File(
        p.join(h.vault.path, 'notes', '3.md'),
      ).setLastModifiedSync(DateTime(2020));
      await h.service.backUpNow(h.source.id);
      expect(h.rotation(), hasLength(2));
      expect((await h.status()).detail, 'Last backup 09:00, verified');
    });

    test(
      'waits out the interval, and a failed run retries next tick',
      () async {
        final h = await Harness.create();
        await h.add(interval: const Duration(hours: 6));
        h.write('new.md', 'x');
        h.now = h.now.add(const Duration(hours: 5));
        await h.service.runDue();
        expect(h.rotation(), hasLength(1), reason: 'not due yet');

        h.now = h.now.add(const Duration(hours: 1));
        h.free = 1;
        await h.service.runDue();
        expect((await h.status()).health, FolderBackupHealth.attention);
        h.free = null;
        h.now = h.now.add(const Duration(minutes: 15));
        await h.service.runDue();
        // The same day's earlier backup gives way to the retry's.
        expect(h.rotation().single, contains('15-15-00'));
        expect((await h.status()).health, FolderBackupHealth.healthy);
      },
    );

    test('an empty folder fails and writes nothing', () async {
      final h = await Harness.create(notes: 0);
      await h.add();
      final status = await h.status();
      expect(status.health, FolderBackupHealth.attention);
      expect(status.detail, 'Folder is empty');
      expect(h.subfolder.existsSync(), isFalse);
    });

    test('a source with no backups yet is reachable', () async {
      final h = await Harness.create(notes: 0);
      await h.add();
      expect((await h.status()).reachable, isTrue);
    });

    test('removing a source that never backed up retires nothing', () async {
      final h = await Harness.create(notes: 0);
      await h.add();
      await h.service.removeSource(h.source.id);
      expect((await h.service.refreshStatus()).retired, isEmpty);
    });

    test('a missing destination fails and writes nothing', () async {
      final h = await Harness.create();
      await h.add();
      h.dest.renameSync(p.join(h.temp.path, 'Unplugged'));
      await h.nextDay();
      final status = await h.status();
      expect(status.detail, 'Destination not found');
      expect(status.reachable, isFalse);
    });

    test(
      'a locked file fails the run, keeps every backup, no .partial',
      () async {
        final h = await Harness.create();
        await h.add();
        final before = h.files();
        h.write('daily/today.md', 'x');
        final handle = File(
          p.join(h.vault.path, 'daily', 'today.md'),
        ).openSync(mode: FileMode.append)..lockSync(FileLock.exclusive);
        h.now = h.now.add(const Duration(days: 1));
        await h.service.runDue();
        handle.closeSync();
        expect(h.files(), before);
        expect(
          (await h.status()).detail,
          "Couldn't read daily/today.md: in use",
        );
      },
    );

    test('not enough space fails without deleting anything', () async {
      final h = await Harness.create();
      await h.add();
      for (var i = 0; i < 9; i++) {
        await h.nextDay();
      }
      final before = h.files();
      h.free = 10;
      await h.nextDay();
      expect(h.files(), before);
      expect((await h.status()).detail, startsWith('Not enough free space'));
    });

    test(
      'rotation holds Voyager\'s set over two months of daily edits',
      () async {
        final h = await Harness.create(notes: 5);
        await h.add();
        for (var i = 0; i < 60; i++) {
          await h.nextDay();
        }
        expect(h.rotation().length, inInclusiveRange(5, 7));
      },
    );

    test('sub-daily runs keep one backup per day', () async {
      final h = await Harness.create(notes: 5);
      await h.add(interval: const Duration(hours: 6));
      for (var i = 0; i < 12; i++) {
        h.now = h.now.add(const Duration(hours: 6));
        h.write('n$i.md', 'x');
        await h.service.runDue();
      }
      final days = h.rotation().map((n) => n.substring(9, 19)).toSet();
      expect(days.length, h.rotation().length);
    });

    test('leftover .partial files are cleared on startup', () async {
      final h = await Harness.create();
      await h.add();
      final partial = File(
        p.join(h.subfolder.path, '${h.rotation().single}.partial'),
      )..writeAsStringSync('x');
      final user = File(p.join(h.subfolder.path, 'mine.partial'))
        ..writeAsStringSync('x');
      await h.service.recover();
      expect(partial.existsSync(), isFalse);
      expect(user.existsSync(), isTrue);
    });
  });

  group('size drop', () {
    test('a count drop over the threshold holds; 19% does not', () async {
      final h = await Harness.create();
      await h.add();
      for (var i = 0; i < 19; i++) {
        h.remove('notes/$i.md');
      }
      await h.nextDay(edit: false);
      expect((await h.status()).health, FolderBackupHealth.healthy);

      for (var i = 19; i < 40; i++) {
        h.remove('notes/$i.md');
      }
      await h.nextDay(edit: false);
      final status = await h.status();
      expect(status.health, FolderBackupHealth.review);
      expect(status.alert, FolderBackupAlert.review);
      expect(
        status.detail,
        'File count fell 26% since the last backup (81 → 60)',
      );
      expect(h.notifications, hasLength(1));
    });

    test('a byte drop holds even when the count does not', () async {
      final h = await Harness.create(notes: 4);
      h.write('big.bin', 'x' * 100000);
      await h.add();
      h.write('big.bin', 'x' * 10);
      await h.nextDay(edit: false);
      final status = await h.status();
      expect(status.health, FolderBackupHealth.review);
      expect(status.detail, startsWith('Size fell'));
    });

    test('a slow loss trips against the weekly backup', () async {
      final h = await Harness.create();
      await h.add();
      var next = 0;
      FolderBackupSourceStatus? status;
      for (var day = 0; day < 9; day++) {
        for (var i = 0; i < 4; i++) {
          h.remove('notes/${next++}.md');
        }
        await h.nextDay(edit: false);
        status = await h.status();
        if (status.health == FolderBackupHealth.review) break;
      }
      expect(status!.health, FolderBackupHealth.review);
      expect(status.detail, contains('since the weekly backup'));
    });

    test('a slow byte loss trips against the weekly backup', () async {
      final h = await Harness.create(notes: 2);
      h.write('big.bin', 'x' * 100000);
      await h.add();
      FolderBackupSourceStatus? status;
      for (var day = 1; day < 10; day++) {
        h.write('big.bin', 'x' * (100000 - day * 4000));
        await h.nextDay(edit: false);
        status = await h.status();
        if (status.health == FolderBackupHealth.review) break;
      }
      expect(status!.detail, startsWith('Size fell'));
      expect(status.detail, contains('since the weekly backup'));
    });

    test('a hold stops pruning until acknowledged, then prunes once', () async {
      final h = await Harness.create();
      await h.add();
      for (var i = 0; i < 50; i++) {
        h.remove('notes/$i.md');
      }
      await h.nextDay(edit: false);
      for (var i = 0; i < 10; i++) {
        await h.nextDay();
      }
      expect(h.rotation(), hasLength(12), reason: 'nothing pruned');
      expect(h.notifications, hasLength(1), reason: 'once per hold');

      await h.service.acceptDrop(h.source.id);
      final status = await h.status();
      expect(status.health, FolderBackupHealth.healthy);
      expect(h.rotation().length, lessThanOrEqualTo(7));

      // Next week: the pre-drop weekly backup is behind the baseline.
      for (var i = 0; i < 8; i++) {
        await h.nextDay();
        expect((await h.status()).health, FolderBackupHealth.healthy);
      }
      expect(h.notifications, hasLength(1));
    });

    test('"This was intentional" during a run is not undone by it', () async {
      final h = await Harness.create();
      await h.add();
      for (var i = 0; i < 50; i++) {
        h.remove('notes/$i.md');
      }
      await h.nextDay(edit: false);
      expect((await h.status()).health, FolderBackupHealth.review);

      // Clicked once the next run has read the hold: its space check comes
      // after that read.
      h.now = h.now.add(const Duration(days: 1));
      h.write('daily/late.md', 'x');
      Future<void>? accept;
      h.onFreeBytes = (_) async {
        final running =
            h.service.status?.sources.single.health ==
            FolderBackupHealth.backingUp;
        if (running) accept ??= h.service.acceptDrop(h.source.id);
      };
      await h.service.backUpNow(h.source.id);
      expect(accept, isNotNull);
      await accept;

      expect((await h.status()).health, FolderBackupHealth.healthy);
    });
  });

  group('re-check', () {
    test(
      'once per local day; a file corrupted between days is caught',
      () async {
        final h = await Harness.create();
        await h.add();
        await h.nextDay();
        final victim = File(p.join(h.subfolder.path, h.rotation().first));
        corrupt(victim);

        h.now = h.now.add(const Duration(hours: 2));
        h.write('later.md', 'x');
        await h.service.backUpNow(h.source.id);
        expect(victim.existsSync(), isTrue, reason: 'already re-checked today');

        await h.nextDay();
        expect(victim.existsSync(), isFalse);
        expect(File('${victim.path}.damaged').existsSync(), isTrue);
        final status = await h.status();
        expect(status.health, FolderBackupHealth.attention);
        expect(status.alert, FolderBackupAlert.failing, reason: 'at once');
      },
    );

    test("an unchanged folder's backups are still re-checked daily", () async {
      final h = await Harness.create();
      await h.add();
      final only = File(p.join(h.subfolder.path, h.rotation().single));
      corrupt(only);
      await h.nextDay(edit: false);
      expect(File('${only.path}.damaged').existsSync(), isTrue);
    });
  });

  group('health and alerts', () {
    test('rows in §9.3 order', () async {
      final h = await Harness.create();
      h.source = await h.service.addSource(
        name: 'Obsidian',
        sourcePath: h.vault.path,
        destination: h.dest.path,
      );
      // Read before the first check's queued run gets going.
      final seen = {h.service.status!.sources.single.health};
      void listener() {
        final s = h.service.status?.sources.firstOrNull;
        if (s != null) seen.add(s.health);
      }

      h.service.addListener(listener);
      await h.service.runDue();
      h.service.removeListener(listener);
      expect(seen, contains(FolderBackupHealth.notYetBackedUp));
      expect(seen, contains(FolderBackupHealth.backingUp));
      expect((await h.status()).health, FolderBackupHealth.healthy);

      await h.service.setEnabled(h.source.id, false);
      expect((await h.status()).health, FolderBackupHealth.off);
      expect(
        (await h.status()).detail,
        'Folder backups are off · last backup today',
      );
      await h.service.setEnabled(h.source.id, true);
      // Turning it on queues a check; let it finish before the clock moves.
      await h.service.runDue();

      h.now = h.now.add(const Duration(days: 3));
      expect((await h.status()).health, FolderBackupHealth.attention);
      expect(
        (await h.status()).detail,
        startsWith('No successful check since'),
      );
    });

    test('an operational failure alerts only after the grace period', () async {
      final h = await Harness.create();
      await h.add(interval: const Duration(hours: 1));
      h.vault.renameSync(p.join(h.temp.path, 'Renamed'));
      h.now = h.now.add(const Duration(hours: 2));
      await h.service.runDue();
      var status = await h.status();
      expect(status.detail, 'Folder not found');
      expect(status.alert, isNull);
      h.now = h.now.add(const Duration(hours: 23));
      status = await h.status();
      expect(status.alert, FolderBackupAlert.failing, reason: '24h minimum');
    });
  });

  test(
    'a slow refresh never leaves a finished run showing as running',
    () async {
      final h = await Harness.create();
      await h.add();
      // A second source after the vault, on a destination that answers slowly.
      final other = Directory(p.join(h.temp.path, 'Other'))..createSync();
      File(p.join(other.path, 'a.md')).writeAsStringSync('a');
      final slowDest = Directory(p.join(h.temp.path, 'Network'))..createSync();
      await h.service.addSource(
        name: 'Other',
        sourcePath: other.path,
        destination: slowDest.path,
      );
      await h.service.runDue();

      h.write('daily/x.md', 'x');
      final gate = Completer<void>();
      Future<FolderBackupStatus>? slow;
      var holdNext = false;
      h.onFreeBytes = (path) async {
        if (path == slowDest.path && holdNext) {
          holdNext = false;
          await gate.future;
        }
        // The vault's space check, mid-run: a refresh starts that reads the
        // vault as running, then waits on the slow destination.
        if (path == h.dest.path && slow == null && h.service.status != null) {
          final vault = h.service.status!.sources.first;
          if (vault.health == FolderBackupHealth.backingUp) {
            holdNext = true;
            slow = h.service.refreshStatus();
          }
        }
      };
      await h.service.backUpNow(h.source.id);
      expect(slow, isNotNull);
      gate.complete();
      await slow;

      expect(
        h.service.status!.sources.first.health,
        isNot(FolderBackupHealth.backingUp),
      );
    },
  );

  group('guards', () {
    test('overlapping placements are refused', () async {
      final h = await Harness.create();
      Future<void> refused(String source, String dest) => expectLater(
        h.service.addSource(name: 'X', sourcePath: source, destination: dest),
        throwsA(isA<FolderBackupFailure>()),
      );
      final inside = Directory(p.join(h.vault.path, 'Backups'))..createSync();
      await refused(h.vault.path, inside.path);
      await refused(h.vault.path, h.vault.path);
      final outer = Directory(p.join(h.temp.path, 'Outer'))..createSync();
      final nested = Directory(p.join(outer.path, 'Vault2'))..createSync();
      File(p.join(nested.path, 'a.md')).writeAsStringSync('a');
      await refused(nested.path, outer.path);

      await h.add();
      await refused(p.join(h.vault.path, 'notes'), h.dest.path);
      await refused(h.temp.path, h.dest.path);

      // Neither source's backups may land inside the other's folder.
      final other = Directory(p.join(h.temp.path, 'Other'))..createSync();
      File(p.join(other.path, 'a.md')).writeAsStringSync('a');
      await refused(other.path, inside.path);
      final elsewhere = Directory(p.join(h.temp.path, 'Elsewhere'))
        ..createSync();
      await refused(h.dest.path, elsewhere.path);
    });

    test('an existing subfolder is refused for a move', () async {
      final h = await Harness.create();
      await h.add();
      final other = Directory(p.join(h.temp.path, 'Other'))..createSync();
      Directory(p.join(other.path, h.source.subfolderName)).createSync();
      await expectLater(
        h.service.changeDestination(h.source.id, other.path),
        throwsA(isA<FolderBackupFailure>()),
      );
    });
  });

  group('pins, delete and extract', () {
    test('a pinned backup is never pruned; unpinning returns it', () async {
      final h = await Harness.create(notes: 5);
      await h.add();
      final first = (await h.service.listBackups(h.source)).single;
      await h.service.pin(h.source, first);
      for (var i = 0; i < 40; i++) {
        await h.nextDay();
      }
      final pinned = (await h.service.listBackups(
        h.source,
      )).where((e) => e.pinned).toList();
      expect(pinned.single.capturedAt, first.capturedAt);
      expect(h.files(), contains(startsWith('Obsidian_pinned_')));

      await h.service.unpin(h.source, pinned.single);
      await h.nextDay();
      expect(h.files().where((n) => n.contains('pinned')), isEmpty);
      expect(
        (await h.service.listBackups(h.source)).map((e) => e.capturedAt),
        isNot(contains(first.capturedAt)),
        reason: 'pruned once back in the rotation',
      );
    });

    test('extract refuses a non-empty or protected target', () async {
      final h = await Harness.create();
      await h.add();
      final backup = (await h.service.listBackups(h.source)).single.file;
      final full = Directory(p.join(h.temp.path, 'Full'))..createSync();
      File(p.join(full.path, 'x')).writeAsStringSync('x');
      await expectLater(
        h.service.extract(backup, full.path),
        throwsA(isA<FolderBackupFailure>()),
      );
      await expectLater(
        h.service.extract(backup, p.join(h.vault.path, 'Restore')),
        throwsA(isA<FolderBackupFailure>()),
      );
      final target = p.join(h.temp.path, 'Obsidian restored');
      await h.service.extract(backup, target);
      expect(
        File(p.join(target, 'notes', '7.md')).readAsStringSync(),
        'note 7 ' * 20,
      );
    });

    test('deleting a rotation file lets retention fill the gap', () async {
      final h = await Harness.create(notes: 5);
      await h.add();
      for (var i = 0; i < 3; i++) {
        await h.nextDay();
      }
      await h.service.deleteBackup(
        (await h.service.listBackups(h.source)).first,
      );
      await h.nextDay();
      expect(h.rotation(), hasLength(4));
    });
  });

  group('moving the destination', () {
    for (final same in [true, false]) {
      test(
        '${same ? 'same' : 'different'}-drive move carries ours only',
        () async {
          final h = await Harness.create(notes: 20);
          h.sameDrive = same;
          await h.add();
          for (var i = 0; i < 9; i++) {
            await h.nextDay();
          }
          await h.service.pin(
            h.source,
            (await h.service.listBackups(h.source)).last,
          );
          final ours = h.files();
          File(p.join(h.subfolder.path, 'mine.txt')).writeAsStringSync('me');

          final next = Directory(p.join(h.temp.path, 'NewDrive'))..createSync();
          await h.service.changeDestination(h.source.id, next.path);
          h.source = await h.current();
          expect(h.source.destination, next.path);
          final moved = h.files();
          expect(moved.where((n) => n != 'mine.txt').toList(), ours);
          final old = Directory(p.join(h.dest.path, h.source.subfolderName));
          if (same) {
            expect(old.existsSync(), isFalse);
          } else {
            expect(h.files(old), ['mine.txt']);
            expect(moved, isNot(contains('mine.txt')));
          }
          expect(
            Directory(
              p.join(next.path, '${h.source.subfolderName}.moving'),
            ).existsSync(),
            isFalse,
          );

          // The size history and the tiers carry on.
          for (var i = 0; i < 20; i++) {
            h.remove('notes/$i.md');
            if (i == 3) break;
          }
          await h.nextDay();
          expect((await h.status()).health, FolderBackupHealth.healthy);
        },
      );
    }

    test('a pin made mid-move lands on the moved backup', () async {
      final h = await Harness.create(notes: 20);
      h.sameDrive = false;
      await h.add();
      for (var i = 0; i < 3; i++) {
        await h.nextDay();
      }
      final entries = await h.service.listBackups(h.source);
      final next = Directory(p.join(h.temp.path, 'NewDrive'))..createSync();
      final moving = Directory(
        p.join(next.path, '${h.source.subfolderName}.moving'),
      );

      // Pinned as soon as the first file has been copied across.
      Future<void>? pin;
      DateTime? pinned;
      void onProgress() {
        if (pin != null || !moving.existsSync()) return;
        final copied = [
          for (final f in moving.listSync().whereType<File>())
            p.basename(f.path),
        ];
        final entry = entries
            .where((e) => copied.contains(p.basename(e.file.path)))
            .firstOrNull;
        if (entry == null) return;
        pinned = entry.capturedAt;
        pin = h.service.pin(h.source, entry);
      }

      h.service.addListener(onProgress);
      await h.service.changeDestination(h.source.id, next.path);
      h.service.removeListener(onProgress);
      expect(pin, isNotNull);
      await pin;

      h.source = await h.current();
      final moved = await h.service.listBackups(h.source);
      expect(moved, hasLength(entries.length));
      expect(moved.singleWhere((e) => e.capturedAt == pinned).pinned, isTrue);
    });

    test('a crash before the switch undoes the copy', () async {
      final h = await Harness.create();
      await h.add();
      final next = Directory(p.join(h.temp.path, 'NewDrive'))..createSync();
      final moving = Directory(
        p.join(next.path, '${h.source.subfolderName}.moving'),
      )..createSync();
      File(p.join(moving.path, h.rotation().single)).writeAsStringSync('half');
      await _writeMove(h, next.path);
      await h.service.recover();
      expect(moving.existsSync(), isFalse);
      expect((await h.current()).destination, h.dest.path);
      expect(h.rotation(), hasLength(1));
    });

    test('a crash after the switch deletes the originals', () async {
      final h = await Harness.create();
      await h.add();
      final next = Directory(p.join(h.temp.path, 'NewDrive'))..createSync();
      final copy = Directory(p.join(next.path, h.source.subfolderName))
        ..createSync();
      final name = h.rotation().single;
      File(p.join(h.subfolder.path, name)).copySync(p.join(copy.path, name));
      await _writeMove(h, next.path);
      await h.service.recover();
      expect((await h.current()).destination, next.path);
      expect(h.subfolder.existsSync(), isFalse);
      expect(h.files(copy), [name]);
    });

    test('an unreachable old destination can change without moving', () async {
      final h = await Harness.create();
      await h.add();
      h.dest.renameSync(p.join(h.temp.path, 'Unplugged'));
      final next = Directory(p.join(h.temp.path, 'NewDrive'))..createSync();
      await expectLater(
        h.service.changeDestination(h.source.id, next.path),
        throwsA(isA<FolderBackupOldDestinationMissing>()),
      );
      await h.service.changeDestination(
        h.source.id,
        next.path,
        withoutMoving: true,
      );
      final status = await h.service.refreshStatus();
      expect(status.retired.single.reachable, isFalse);
      expect(status.retired.single.entry.lastKnownCount, 1);
      expect((await h.current()).destination, next.path);
    });
  });

  group('retired backups', () {
    test('removing keeps the files, delete all removes only ours', () async {
      final h = await Harness.create();
      await h.add();
      await h.nextDay();
      final ours = h.files();
      File(p.join(h.subfolder.path, 'mine.txt')).writeAsStringSync('me');
      final before = (await h.service.refreshStatus()).totalBytes;

      await h.service.removeSource(h.source.id);
      var status = await h.service.refreshStatus();
      expect(status.sources, isEmpty);
      final retired = status.retired.single;
      expect(retired.count, 2);
      expect(status.totalBytes, before);
      expect(h.files().where((n) => n != 'mine.txt'), ours);

      await h.service.deleteRetired(retired.entry);
      status = await h.service.refreshStatus();
      expect(status.retired, isEmpty);
      expect(h.files(), ['mine.txt']);
    });
  });
}

/// The state a move leaves before its last step, as a crash would.
Future<void> _writeMove(Harness h, String destination) async {
  final file = File(p.join(h.app.path, h.source.id, 'state.json'));
  final state = file.readAsStringSync();
  final to = p.join(destination, h.source.subfolderName);
  file.writeAsStringSync(
    state.replaceFirst(
      '{',
      '{"move":{"from":${_json(h.subfolder.path)},"to":${_json(to)},'
          '"destination":${_json(destination)}},',
    ),
  );
}

String _json(String s) => '"${s.replaceAll(r'\', r'\\')}"';

/// Flips a byte in the middle of the first entry's compressed data, where
/// only the content checks can notice.
void corrupt(File file) {
  final reader = StreamingZipReader(file.path);
  final entry = reader.entries.first;
  reader.close();
  final bytes = file.readAsBytesSync();
  bytes[entry.localHeaderOffset +
          30 +
          utf8.encode(entry.name).length +
          entry.compressedSize ~/ 2] ^=
      0xFF;
  file.writeAsBytesSync(bytes);
}
