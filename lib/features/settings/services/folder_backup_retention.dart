/// Which folder backups to keep, and which file names are ours —
/// FOLDER_BACKUP_HLD.md §5 and §6.4.
///
/// Voyager's own rule, [backupsToKeep], unchanged, fed the newest backup of
/// each local day. Like it, a pure function of the directory and today's date.
library;

import 'package:voyager/features/settings/services/auto_backup_retention.dart';

/// `Obsidian_2026-10-03_14-02-11-0400.zip`: in the rotation.
RegExp folderBackupRotationPattern(String slug) =>
    backupNamePattern('${slug}_');

/// `Obsidian_pinned_2026-09-01_09-00-00-0400.zip`: outside the rotation, never
/// deleted automatically.
RegExp folderBackupPinnedPattern(String slug) =>
    backupNamePattern('${slug}_pinned_');

const folderBackupDamagedSuffix = '.damaged';
const folderBackupUnsupportedSuffix = '.unsupported';
const folderBackupPartialSuffix = '.partial';

/// Whether [name] is a file this feature wrote into a source's subfolder: a
/// rotation or pinned backup, one set aside as damaged or unsupported, or a
/// leftover `.partial`. Only these are ever moved or deleted.
bool isFolderBackupFileName(String slug, String name) {
  var base = name;
  for (final suffix in const [
    folderBackupDamagedSuffix,
    folderBackupUnsupportedSuffix,
    folderBackupPartialSuffix,
  ]) {
    if (base.endsWith(suffix)) {
      base = base.substring(0, base.length - suffix.length);
      break;
    }
  }
  return folderBackupRotationPattern(slug).hasMatch(base) ||
      folderBackupPinnedPattern(slug).hasMatch(base);
}

/// The newest of [capturedAt] on each local calendar day.
Set<DateTime> newestPerLocalDay(Iterable<DateTime> capturedAt) {
  final newest = <(int, int, int), DateTime>{};
  for (final time in capturedAt) {
    final local = time.toLocal();
    final day = (local.year, local.month, local.day);
    final current = newest[day];
    if (current == null || time.isAfter(current)) newest[day] = time;
  }
  return newest.values.toSet();
}

/// The subset of [capturedAt] to keep (§5). Backups dated in the future are
/// all kept and left out of the maths, as in Voyager's rule — including the
/// older ones of a future day, which [newestPerLocalDay] would otherwise drop.
Set<DateTime> folderBackupsToKeep(
  Set<DateTime> capturedAt,
  DateTime todayLocal,
) {
  final future = {
    for (final t in capturedAt)
      if (backupAgeDays(t, todayLocal) < 0) t,
  };
  final dated = capturedAt.difference(future);
  return {...future, ...backupsToKeep(newestPerLocalDay(dated), todayLocal)};
}
