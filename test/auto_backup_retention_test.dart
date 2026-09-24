import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/settings/services/auto_backup_retention.dart';

/// Runs [days] days of automatic backups, one per opened day, pruning after
/// each, and hands [check] the retained set as it stands after every prune.
void simulate({
  required int days,
  required bool Function(int day) opened,
  required void Function(DateTime today, Set<DateTime> kept) check,
}) {
  final start = DateTime(2026, 1, 1);
  var onDisk = <DateTime>{};
  for (var day = 0; day < days; day++) {
    if (!opened(day)) continue;
    final today = DateTime(start.year, start.month, start.day + day);
    onDisk.add(today.add(const Duration(hours: 9)).toUtc());
    final kept = backupsToKeep(onDisk, today);
    expect(onDisk.containsAll(kept), isTrue);
    onDisk = kept;
    check(today, kept);
  }
}

void main() {
  for (final (label, openedFraction) in [('daily use', 1.0), ('60%', 0.6)]) {
    test('over 500 days of $label the ages hold (§11)', () {
      final random = Random(42);
      final first = DateTime(2026, 1, 1);
      var taken = <DateTime>[];
      simulate(
        days: 500,
        opened: (_) => random.nextDouble() < openedFraction,
        check: (today, kept) {
          taken = [...taken, today.add(const Duration(hours: 9)).toUtc()];
          expect(kept.length, lessThanOrEqualTo(7));

          final ages = [for (final b in kept) backupAgeDays(b, today)];
          final history = backupAgeDays(first.toUtc(), today);
          // The 3 newest backups ever taken are always among those kept.
          expect(kept, containsAll(taken.reversed.take(3)));
          if (history >= 13 + 7) {
            expect(
              ages.any((a) => a >= 7 && a <= 13),
              isTrue,
              reason: '$today $ages',
            );
          }
          if (history >= 51 + 7) {
            expect(
              ages.any((a) => a >= 30 && a <= 51),
              isTrue,
              reason: '$today $ages',
            );
          }
        },
      );
    });
  }

  test('a backup dated in the future is never deleted', () {
    final today = DateTime(2026, 9, 24);
    final future = DateTime(2026, 9, 30, 9).toUtc();
    final past = [
      for (var i = 0; i < 20; i++) DateTime(2026, 9, 23 - i, 9).toUtc(),
    ];
    final kept = backupsToKeep({future, ...past}, today);
    expect(kept, contains(future));
    // And it is not counted as one of the three dailies.
    expect(kept, containsAll(past.take(3)));
  });

  test(
    'after a long gap the dailies are the three newest, whatever their age',
    () {
      final today = DateTime(2026, 9, 24);
      final old = [
        for (var i = 0; i < 5; i++) DateTime(2026, 9, 10 - i, 9).toUtc(),
      ];
      final kept = backupsToKeep(old.toSet(), today);
      expect(kept, containsAll(old.take(3)));
    },
  );

  test('names are local time to the second plus the UTC offset', () {
    expect(
      parseBackupTimestamp(
        'voyager_auto_2026-09-24_18-25-30-0400.zip',
        autoBackupNamePattern,
      ),
      DateTime.utc(2026, 9, 24, 22, 25, 30),
    );
    expect(
      parseBackupTimestamp(
        'voyager_prerestore_2026-09-24_23-55-00+0530.zip',
        preRestoreNamePattern,
      ),
      DateTime.utc(2026, 9, 24, 18, 25),
    );
    // The hour the clocks go back happens twice in North America; the offset
    // keeps the two apart. Round-trips on any machine time zone.
    for (final instant in [
      DateTime.utc(2026, 11, 1, 5, 30, 1),
      DateTime.utc(2026, 11, 1, 6, 30, 1),
      DateTime.utc(2026, 9, 24, 22, 25, 30),
    ]) {
      final name = 'voyager_auto_${backupTimestamp(instant)}.zip';
      expect(name, isNot(contains(':')));
      expect(parseBackupTimestamp(name, autoBackupNamePattern), instant);
    }
  });

  test('old UTC names are renamed to the current format', () {
    final renamed = legacyBackupRename('voyager_auto_20260924T222530Z.zip')!;
    expect(
      parseBackupTimestamp(renamed, autoBackupNamePattern),
      DateTime.utc(2026, 9, 24, 22, 25, 30),
    );
    expect(
      preRestoreNamePattern.hasMatch(
        legacyBackupRename('voyager_prerestore_20260924T222530Z.zip')!,
      ),
      isTrue,
    );
    expect(legacyBackupRename('voyager_backup_1727000000000.zip'), isNull);
  });

  test('only exact automatic-backup names are parsed', () {
    final stamp = backupTimestamp(DateTime.utc(2026, 9, 24, 9, 14, 5));
    for (final name in [
      'voyager_auto_$stamp.zip.partial',
      'voyager_prerestore_$stamp.zip',
      'voyager_backup_1727000000000.zip',
      'copy of voyager_auto_$stamp.zip',
      'voyager_auto_$stamp (1).zip',
      'voyager_auto_20260924T222530Z.zip',
    ]) {
      expect(
        parseBackupTimestamp(name, autoBackupNamePattern),
        isNull,
        reason: name,
      );
    }
  });
}
