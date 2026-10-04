import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/settings/services/auto_backup_retention.dart';
import 'package:voyager/features/settings/services/folder_backup_retention.dart';

/// FOLDER_BACKUP_HLD.md §5 / §11: the 500-day simulation at several intervals,
/// with unchanged checks (no file written) mixed in.
void main() {
  final start = DateTime(2026, 1, 1, 9);

  for (final interval in const [
    Duration(hours: 1),
    Duration(hours: 6),
    Duration(days: 1),
    Duration(days: 7),
  ]) {
    test('500 days at a ${interval.inHours}h interval', () {
      final rnd = Random(interval.inHours);
      var files = <DateTime>{};
      final taken = <DateTime>[];
      var weekHeld = false;
      var monthHeld = false;
      for (
        var t = start;
        t.isBefore(start.add(const Duration(days: 500)));
        t = t.add(interval)
      ) {
        // 30% of checks find the folder unchanged and write nothing.
        if (rnd.nextDouble() < 0.7) {
          files.add(t);
          taken.add(t);
        }
        final keep = folderBackupsToKeep(files, t);
        expect(keep.difference(files), isEmpty);
        if (interval == const Duration(days: 1)) {
          expect(keep, backupsToKeep(files, t), reason: "Voyager's rule");
        }
        files = keep;

        expect(files.length, lessThanOrEqualTo(7));
        final days = {for (final f in files) (f.year, f.month, f.day)};
        expect(days.length, files.length, reason: 'one per local day');
        final ages = files.map((f) => backupAgeDays(f, t)).toList();
        // A tier can only be held if some backup was ever taken at that age:
        // a skipped week at a 7-day interval leaves none.
        bool everTaken(int from, int to) => taken.any((f) {
          final age = backupAgeDays(f, t);
          return age >= from && age <= to;
        });
        if (everTaken(7, 13)) {
          weekHeld = true;
          expect(
            ages.any((a) => a >= 7 && a <= 13),
            isTrue,
            reason: 'week slot at $t: $ages',
          );
        }
        if (everTaken(30, 51)) {
          monthHeld = true;
          expect(
            ages.any((a) => a >= 30 && a <= 51),
            isTrue,
            reason: 'month slot at $t: $ages',
          );
        }
      }
      expect(weekHeld && monthHeld, isTrue);
    });
  }

  test('a later backup of the same day replaces the earlier ones', () {
    final morning = DateTime(2026, 10, 3, 9);
    final noon = DateTime(2026, 10, 3, 12);
    final yesterday = DateTime(2026, 10, 2, 23);
    expect(folderBackupsToKeep({morning, noon, yesterday}, noon), {
      noon,
      yesterday,
    });
  });

  test('future-dated backups are all kept, older ones of their day too', () {
    final today = DateTime(2026, 10, 3, 9);
    final a = DateTime(2026, 10, 5, 9);
    final b = DateTime(2026, 10, 5, 10);
    expect(folderBackupsToKeep({a, b, today}, today), containsAll([a, b]));
  });

  test('names: rotation, pinned and set-aside files are ours, others not', () {
    const slug = 'Obsidian';
    final stamp = backupTimestamp(DateTime(2026, 10, 3, 14, 2, 11));
    expect(
      folderBackupRotationPattern(slug).hasMatch('Obsidian_$stamp.zip'),
      isTrue,
    );
    expect(
      folderBackupRotationPattern(slug).hasMatch('Obsidian_pinned_$stamp.zip'),
      isFalse,
    );
    expect(
      folderBackupPinnedPattern(slug).hasMatch('Obsidian_pinned_$stamp.zip'),
      isTrue,
    );
    for (final name in [
      'Obsidian_$stamp.zip',
      'Obsidian_pinned_$stamp.zip',
      'Obsidian_$stamp.zip.damaged',
      'Obsidian_$stamp.zip.unsupported',
      'Obsidian_$stamp.zip.partial',
    ]) {
      expect(isFolderBackupFileName(slug, name), isTrue, reason: name);
    }
    for (final name in [
      'notes.txt',
      'Obsidian_$stamp.zipx',
      'Other_$stamp.zip',
      'Obsidian_${stamp}_copy.zip',
    ]) {
      expect(isFolderBackupFileName(slug, name), isFalse, reason: name);
    }
  });
}
