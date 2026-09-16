import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/soft_delete/soft_delete_toast.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/domain/models/journal_models.dart';

/// A journal entry as it stood the instant before a delete, plus the instant
/// its images were detached at — everything [restoreJournalEntry] needs.
class JournalEntryDeletion {
  const JournalEntryDeletion({required this.entry, required this.mediaDeletedAt});

  final JournalEntry entry;

  /// Null when the entry had no images. See
  /// [MediaService.removeReferencesForOwner] on why the instant is carried
  /// rather than read back off the entry's own `deletedAt`.
  final DateTime? mediaDeletedAt;
}

/// Soft-deletes a journal entry and returns what it takes to put it back.
///
/// Both the Journal page and Search delete entries, and an undo has to restore
/// the same three things either way — hence one implementation rather than a
/// copy on each page.
///
/// Everything runs off a [ProviderContainer] rather than a `WidgetRef`: the
/// delete unmounts the row that asked for it, and the undo the toast offers is
/// pressed seconds later, by which time a `WidgetRef` would throw.
///
/// Returns null when there was no row to delete, in which case there is
/// nothing to offer an undo for either.
Future<JournalEntryDeletion?> softDeleteJournalEntry(
  ProviderContainer container,
  String entryId,
) async {
  final repository = container.read(journalRepositoryProvider);
  final remoteSync = container.read(remoteSyncServiceProvider);
  final media = container.read(mediaServiceProvider);

  // Settle first, then cancel: the entry's editor flushes locally and leaves
  // the upload running in the background, and an in-flight local save that is
  // still going would re-arm that upload after a bare cancel. Once the queue is
  // empty, dropping the pending upload is what keeps the *live* row from being
  // published after the tombstone below and resurrecting the entry on the next
  // device to pull. Nothing is lost by dropping it — the tombstone push reads
  // the row back off disk, so it carries the same edit.
  await remoteSync.settleLocalWrites(
    FirestoreCollections.journalEntries,
    entryId,
  );
  remoteSync.cancelDocument(FirestoreCollections.journalEntries, entryId);

  // Read off disk rather than taken from the caller's copy: the lists both
  // pages render from lag an in-flight save, and restoring from a stale
  // snapshot would quietly roll the last edit back with the undo. After the
  // settle, so a save still in flight is part of what the undo restores.
  final snapshot = await repository.getEntry(entryId);
  if (snapshot == null) return null;

  await repository.softDeleteEntry(entryId);
  // The pushed tombstone is read back rather than built here. `softDeleteEntry`
  // bumps the version itself, and whenever the caller's copy lagged disk the
  // tombstone went out at a version Firestore had already passed: the next
  // device read it as the loser and pushed its own live document back,
  // resurrecting the entry everywhere.
  final tombstone = await repository.getEntry(entryId);
  if (tombstone != null) remoteSync.pushJournalEntryNow(tombstone);

  // The entry's images go onto the same 30-day clock it does, so a deleted
  // page and its pictures expire together rather than leaving orphaned blobs
  // behind. After the delete, as everywhere else: the entry going is what the
  // user asked for, and must not depend on the media module.
  final mediaDeletedAt = await media.removeReferencesForOwner(
    FirestoreCollections.journalEntries,
    entryId,
  );

  return JournalEntryDeletion(
    entry: snapshot,
    mediaDeletedAt: mediaDeletedAt,
  );
}

/// Undoes [softDeleteJournalEntry] from the snapshot it returned.
///
/// The entry is rebuilt field by field rather than `copyWith`'d, because
/// `copyWith` reads `deletedAt ?? this.deletedAt` and so cannot clear a
/// tombstone.
///
/// Throws [RestoreSuperseded] when a pull has already brought the entry back
/// during the undo window; see [abortIfAlreadyRestored].
Future<void> restoreJournalEntry(
  ProviderContainer container,
  JournalEntryDeletion deletion,
) async {
  final entry = deletion.entry;
  final repository = container.read(journalRepositoryProvider);
  // Read at restore time rather than trusting the snapshot's version. The
  // offer stands for eight seconds and more, which is long enough for a pull
  // to land a newer revision — and conflict resolution is version-first with
  // no guard on the local write, so a restore written under what is on disk
  // wins here and loses the next pull, taking the entry away again.
  final current = await repository.getEntry(entry.id);
  abortIfAlreadyRestored(found: current != null, deletedAt: current?.deletedAt);
  final restored = JournalEntry(
    id: entry.id,
    createdAt: entry.createdAt,
    updatedAt: utcNow(),
    version: restoreVersionFrom(
      preDeleteVersion: entry.version,
      currentVersion: current?.version,
    ),
    journalId: entry.journalId,
    title: entry.title,
    body: entry.body,
    richBodyJson: entry.richBodyJson,
    entryDate: entry.entryDate,
    timestamp: entry.timestamp,
    tags: entry.tags,
    mood: entry.mood,
    quoteId: entry.quoteId,
    customQuote: entry.customQuote,
    weatherIcon: entry.weatherIcon,
    guidedPrompt: entry.guidedPrompt,
  );
  await repository.upsertEntry(restored);
  container.read(remoteSyncServiceProvider).pushJournalEntryNow(restored);

  // The images are re-attached after the row is back and inside a `finally`,
  // mirroring the delete — where the detach is deliberately after the
  // tombstone for the same reason. Media I/O failing is not the entry failing:
  // without the `finally` an I/O error left the entry on disk, synced, and
  // never invalidated, so the list went on hiding a row that had come back.
  try {
    final mediaDeletedAt = deletion.mediaDeletedAt;
    if (mediaDeletedAt != null) {
      await container
          .read(mediaServiceProvider)
          .restoreReferencesForOwner(
            FirestoreCollections.journalEntries,
            entry.id,
            mediaDeletedAt,
          );
    }
  } finally {
    container.read(journalEntryCacheInvalidatorProvider)();
  }
}
