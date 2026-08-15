import 'package:voyager/domain/models/soft_deletable.dart';

/// Re-reads a session's held copies of [entries] against [live] — the freshest
/// list the repository has handed out — so a card edited, reset, or deleted
/// from under a running session stops showing its pre-edit snapshot.
///
/// A study or cram session builds its queue once and then works from that
/// snapshot, which is what makes an edit saved mid-session invisible until the
/// session is left and re-entered.
///
/// Entries missing from [live] are dropped: that is what a soft delete looks
/// like from here. A held copy is only replaced when the live one carries a
/// later [SoftDeletable.version] — a grade the session has just saved is
/// already the newest thing there is, and must not be rolled back by a list
/// that has not finished refetching.
List<T> refreshFromLive<T extends SoftDeletable>(
  Iterable<T> entries,
  Iterable<T> live,
) {
  final byId = {for (final item in live) item.id: item};
  final refreshed = <T>[];
  for (final entry in entries) {
    final fresh = byId[entry.id];
    if (fresh == null) continue;
    refreshed.add(fresh.version > entry.version ? fresh : entry);
  }
  return refreshed;
}
