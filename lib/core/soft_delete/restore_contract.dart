/// Thrown by a restore whose row is already live on disk again.
///
/// A pull landing inside the undo window can bring the row back on its own —
/// another device restored it, or edited it and won the version comparison.
/// Writing the pre-delete snapshot over that is not an undo, it is data loss:
/// the snapshot is older than what is on disk, and the other device's edit
/// would be silently discarded.
///
/// Caught by the toast layer, which turns it into an "Already restored"
/// notice, so a pressed Undo that deliberately does nothing still says so.
class RestoreSuperseded implements Exception {
  const RestoreSuperseded();

  @override
  String toString() => 'RestoreSuperseded: the row is already live on disk';
}

/// Aborts a restore whose row a pull already brought back.
///
/// [found] is whether the row is on disk at all and [deletedAt] its tombstone
/// stamp, both read *at restore time* — a row that is present and untombstoned
/// is one nothing needs undoing for.
///
/// Not called by restores that put back rows which were *edited* rather than
/// tombstoned — a "this event only" calendar delete rewrites its master and
/// leaves it live, so an absent tombstone there means nothing.
void abortIfAlreadyRestored({required bool found, required DateTime? deletedAt}) {
  if (found && deletedAt == null) throw const RestoreSuperseded();
}

/// The version a restore has to write to outrank both the tombstone it undoes
/// and anything a pull landed while the undo offer stood.
///
/// Conflict resolution is version-first, and the local write path applies no
/// version guard — so the number has to be resolved against what is on disk
/// *now*, not against the snapshot taken before the delete. An 8-second undo
/// window is long enough for a sync to land a newer revision, and a restore
/// written under it loses the next pull and takes the row away again.
///
/// [currentVersion] is null when the row is not on disk at all. The pre-delete
/// version plus one stands in for it: every soft delete in the app bumps the
/// row by one on its way to becoming a tombstone, so that is the version the
/// tombstone went out to Firestore at, and a restore has to clear it.
///
/// Lives apart from the toast so the data layer can follow the same rule
/// without importing widgets; `soft_delete_toast.dart` re-exports it, so a
/// call site that needs both still writes one import.
int restoreVersionFrom({
  required int preDeleteVersion,
  required int? currentVersion,
}) {
  final floor = currentVersion ?? preDeleteVersion + 1;
  return (floor > preDeleteVersion ? floor : preDeleteVersion) + 1;
}
