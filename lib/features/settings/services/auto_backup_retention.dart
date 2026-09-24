/// Which automatic backups to keep — AUTO_BACKUP_HLD.md §5.
///
/// A pure function of the files on disk and today's date, with no slot state
/// of its own, so it recovers from gaps, crashes, reinstalls and files deleted
/// by hand the same way it handles an ordinary day.
library;

/// Prefix of every automatic backup's file name. Retention only ever looks at
/// files matching [autoBackupNamePattern]; manual exports, pre-restore
/// snapshots and anything else in the folder are never its to delete.
const autoBackupPrefix = 'voyager_auto_';

/// Prefix of a pre-restore snapshot's file name (§7.2). Outside the rotation.
const preRestorePrefix = 'voyager_prerestore_';

/// The capture time as it appears in a file name: local time to the second,
/// plus the UTC offset it was taken at — `2026-09-24_18-25-30-0400`.
///
/// Local so the name reads the way the clock did; the offset so the name
/// still names one instant when the clocks go back or the device changes time
/// zone. Seconds, not minutes, keep two backups taken close together from
/// sharing a name. No `:`, which Windows does not allow in a file name.
const _stamp =
    r'(\d{4})-(\d{2})-(\d{2})_(\d{2})-(\d{2})-(\d{2})([+-])(\d{2})(\d{2})';

/// `voyager_auto_2026-09-24_18-25-30-0400.zip`.
final autoBackupNamePattern = RegExp('^$autoBackupPrefix$_stamp\.zip\$');

/// `voyager_prerestore_2026-09-24_18-25-30-0400.zip`.
final preRestoreNamePattern = RegExp('^$preRestorePrefix$_stamp\.zip\$');

/// The file-name stamp for [capturedAt], e.g. `2026-09-24_18-25-30-0400`.
String backupTimestamp(DateTime capturedAt) {
  final t = capturedAt.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  final offset = t.timeZoneOffset;
  final minutes = offset.inMinutes.abs();
  return '${t.year.toString().padLeft(4, '0')}-${two(t.month)}-${two(t.day)}'
      '_${two(t.hour)}-${two(t.minute)}-${two(t.second)}'
      '${offset.isNegative ? '-' : '+'}${two(minutes ~/ 60)}${two(minutes % 60)}';
}

/// The UTC capture time a backup's file name records, or null if [name] is
/// not a name [pattern] owns.
DateTime? parseBackupTimestamp(String name, RegExp pattern) {
  final match = pattern.firstMatch(name);
  if (match == null) return null;
  int part(int i) => int.parse(match.group(i)!);
  final offset = Duration(hours: part(8), minutes: part(9));
  final wallClock = DateTime.utc(
    part(1),
    part(2),
    part(3),
    part(4),
    part(5),
    part(6),
  );
  return match.group(7) == '-'
      ? wallClock.add(offset)
      : wallClock.subtract(offset);
}

/// Names from before the stamp above: `voyager_auto_20260924T222530Z.zip`,
/// in UTC. Only read to rename them — see [legacyBackupRename].
final _legacyNamePattern = RegExp(
  '^($autoBackupPrefix|$preRestorePrefix)'
  r'(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z\.zip$',
);

/// The current name for a backup still carrying a legacy name, or null if
/// [name] is not one.
String? legacyBackupRename(String name) {
  final match = _legacyNamePattern.firstMatch(name);
  if (match == null) return null;
  int part(int i) => int.parse(match.group(i)!);
  final capturedAt = DateTime.utc(
    part(2),
    part(3),
    part(4),
    part(5),
    part(6),
    part(7),
  );
  return '${match.group(1)}${backupTimestamp(capturedAt)}.zip';
}

/// Whole local calendar days from [capturedAt] to [todayLocal]. Negative for a
/// backup dated in the future. Counted on dates rather than durations, so a
/// DST change never makes yesterday 0 or 2 days old.
int backupAgeDays(DateTime capturedAt, DateTime todayLocal) {
  final captured = capturedAt.toLocal();
  final from = DateTime.utc(captured.year, captured.month, captured.day);
  final to = DateTime.utc(todayLocal.year, todayLocal.month, todayLocal.day);
  return to.difference(from).inDays;
}

/// The ages, in days, at which a backup takes over the weekly and monthly
/// slots.
const retentionTiers = [7, 30];

/// The subset of [capturedAt] to keep, given today's local date (§5.2):
///
/// 1. the 3 newest;
/// 2. per tier T, the youngest aged ≥ T (the holder) and the oldest aged < T
///    (the one rising into it);
/// 3. anything dated in the future (§5.3), which is left out of the maths.
Set<DateTime> backupsToKeep(Set<DateTime> capturedAt, DateTime todayLocal) {
  final keep = <DateTime>{};
  final dated = <DateTime>[];
  for (final backup in capturedAt) {
    if (backupAgeDays(backup, todayLocal) < 0) {
      keep.add(backup);
    } else {
      dated.add(backup);
    }
  }
  // Newest first.
  dated.sort((a, b) => b.compareTo(a));
  keep.addAll(dated.take(3));

  for (final tier in retentionTiers) {
    // Newest first, so the first match aged ≥ T is the youngest of them and
    // the last match aged < T is the oldest.
    DateTime? holder;
    DateTime? rising;
    for (final backup in dated) {
      final age = backupAgeDays(backup, todayLocal);
      if (age >= tier) {
        holder ??= backup;
      } else {
        rising = backup;
      }
    }
    if (holder != null) keep.add(holder);
    if (rising != null) keep.add(rising);
  }
  return keep;
}
