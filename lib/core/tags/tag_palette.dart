import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/utils/journal_tags.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';

/// Brings every stored tag color back onto the curated palette [colorForTag]
/// draws from, and reports how many rows it had to rewrite.
///
/// No migration stamp: the reconcile is its own idempotence check. A row whose
/// color already matches is skipped, so after the first pass this costs one
/// table read and nothing else — and a color that arrives from a device still
/// on the old build is quietly corrected on the next launch rather than
/// sticking around because a flag said the migration was "done".
///
/// Each rewrite bumps `updatedAt` and `version` and is recorded as local
/// activity, so it is pushed and outranks the stale remote row. It cannot be
/// left as a silent local edit: the old color is still in Firestore at the
/// *same* version and the *same* timestamp, and `remoteVersionWins` breaks
/// that tie for the remote — the next pull of the session would write the old
/// mash straight back, every session, forever.
///
/// [colorForTag] is deterministic, so a second device reaching the same row
/// computes the same color and skips it; the push is one round per device per
/// palette change, not a standing conversation.
Future<int> reconcileTagPalette(SettingsRepository settings) async {
  final records = await settings.getTagColorRecords();
  var rewritten = 0;
  for (final record in records) {
    final wanted = colorForTag(record.tag);
    if (record.colorValue == wanted) continue;
    await settings.upsertTagColor(
      TagColorRecord(
        tag: record.tag,
        colorValue: wanted,
        updatedAt: utcNow(),
        version: record.version + 1,
      ),
    );
    rewritten++;
  }
  return rewritten;
}
