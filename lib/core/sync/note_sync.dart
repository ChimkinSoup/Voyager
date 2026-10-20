import 'package:voyager/core/secure_vault/secure_vault.dart';
import 'package:voyager/core/soft_delete/erasure.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/core/sync/outbox_sync_worker.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/domain/models/notification_models.dart';
import 'package:voyager/domain/models/photo_series_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';

/// Reads a note's server copy and writes what `decide` returns for it, in one
/// transaction — see [SyncRepository.writeAfterReading].
typedef NoteTransaction =
    Future<Map<String, dynamic>?> Function(
      Map<String, dynamic>? Function(Map<String, dynamic>? remote) decide,
    );

/// How one note collection plugs into [applyRemoteNote] and [uploadNote].
class NoteSyncStore<T extends SyncedNote> {
  const NoteSyncStore({
    required this.collection,
    required this.get,
    required this.save,
    required this.markSynced,
    required this.toFirestore,
    required this.fromRemote,
    required this.fork,
    required this.sameContent,
    this.heldBack,
  });

  final String collection;
  final Future<T?> Function(String id) get;

  /// Writes [note] locally; [upload] says whether it goes on to the server.
  final Future<void> Function(T note, {required bool upload}) save;
  final Future<void> Function(String id, int version) markSynced;
  final Map<String, dynamic> Function(T note) toFirestore;

  /// The server's copy as a row, in step with the server at its version.
  final T Function(Map<String, dynamic> remote, String id, T? local) fromRemote;

  /// [note]'s content as a new note, placed right after it.
  final T Function(T note) fork;
  final bool Function(T local, Map<String, dynamic> remote) sameContent;

  /// Whether a live [note] must not be uploaded at all — checked before each
  /// upload of one. A note held back stays unsent here.
  final Future<bool> Function(T note)? heldBack;

  NoteSyncAction resolve(T? local, Map<String, dynamic>? remote) =>
      resolveNoteSync(
        local: local,
        remote: remote,
        sameContent:
            local != null && remote != null && sameContent(local, remote),
      );
}

NoteSyncStore<PinnedNote> pinnedNoteSyncStore(NotificationRepository repo) =>
    NoteSyncStore(
      collection: FirestoreCollections.pinnedNotes,
      get: repo.getPinnedNote,
      save: (note, {required upload}) =>
          repo.upsertPinnedNote(note, recordLocalActivity: upload),
      markSynced: repo.markPinnedNoteSynced,
      toFirestore: pinnedNoteToFirestore,
      fromRemote: (remote, id, local) => pinnedNoteFromRemote(
        remote,
        id,
        local: local,
        syncedVersion: parseVersion(remote),
      ),
      fork: (note) => PinnedNote(
        id: newId(),
        text: note.text,
        // Notes list by creation time, so this lands right after the
        // original.
        createdAt: note.createdAt.add(const Duration(milliseconds: 1)),
        updatedAt: utcNow(),
      ),
      sameContent: (local, remote) => local.text == remote['text'],
    );

/// Works on ciphertext alone, so it runs while the vault is locked: a fork
/// carries the sealed text to its new id unchanged, which the vault allows
/// because a note is bound to its vault, not to its id.
///
/// With [serverHeader], an upload first reads the server's vault header, and a
/// note sealed under any other vault is held back: a reset elsewhere has made
/// it unreadable for good. The device takes the newer header instead, which
/// deletes the note and tells the user (see [retireSecureNotes]). Uploads
/// can't rely on this device's own header for that — a device coming back
/// online drains its queue before it hears of the reset.
NoteSyncStore<SecureNote> secureNoteSyncStore(
  NotificationRepository repo, {
  Future<Map<String, dynamic>?> Function()? serverHeader,
}) => NoteSyncStore(
  collection: FirestoreCollections.secureNotes,
  get: repo.getSecureNote,
  save: (note, {required upload}) =>
      repo.upsertSecureNote(note, recordLocalActivity: upload),
  markSynced: repo.markSecureNoteSynced,
  toFirestore: secureNoteToFirestore,
  fromRemote: (remote, id, local) => secureNoteFromRemote(
    remote,
    id,
    local: local,
    syncedVersion: parseVersion(remote),
  ),
  fork: (note) => SecureNote(
    id: newId(),
    ciphertext: note.ciphertext,
    nonce: note.nonce,
    vaultId: note.vaultId,
    createdAt: note.createdAt.add(const Duration(milliseconds: 1)),
    updatedAt: utcNow(),
  ),
  // Fresh nonces make two seals of one text differ, so this only catches
  // the very same save.
  sameContent: (local, remote) =>
      local.ciphertext == remote['ciphertext'] &&
      local.vaultId == remote['vaultId'],
  heldBack: serverHeader == null
      ? null
      : (note) async {
          final remote = await serverHeader();
          if (remote == null || remote['vaultId'] == note.vaultId) {
            return false;
          }
          await adoptSecureVaultHeader(repo, remote);
          return true;
        },
);

/// Takes the server's vault [remote] header when it is newer than this
/// device's, then deletes the notes of any vault it retired. Returns whether
/// the header was taken.
///
/// The header is only ever written by transactions that check the version
/// they replace (see `SecureVaultService`), so the higher version is always
/// the later one.
Future<bool> adoptSecureVaultHeader(
  NotificationRepository repo,
  Map<String, dynamic> remote,
) async {
  // Parsed first: a malformed header stored here would lock the vault out.
  final header = SecureVaultHeader.fromJson(remote);
  final local = await repo.getSecureVaultHeader();
  final localVersion = (local?['headerVersion'] as num?)?.toInt() ?? 0;
  final newer = local == null || header.headerVersion > localVersion;
  if (newer) {
    await repo.saveSecureVaultHeader(
      header.toJson(),
      vaultId: header.vaultId,
      headerVersion: header.headerVersion,
    );
  }
  await retireSecureNotes(repo);
  return newer;
}

/// Deletes every live note sealed under a vault this device's header lists as
/// retired: nothing can read one again, and left alone it would sit in the
/// cloud and in backups for good. Returns how many it deleted.
///
/// One still unsent was made on this device without the reset in view, and
/// its words are lost; those are counted for the next unlock to tell the
/// user. One already in step with the server is a copy the reset deleted, or
/// another device's to report.
Future<int> retireSecureNotes(NotificationRepository repo) async {
  final json = await repo.getSecureVaultHeader();
  if (json == null) return 0;
  final retired = SecureVaultHeader.fromJson(json).retiredVaultIds.toSet();
  if (retired.isEmpty) return 0;
  var deleted = 0;
  var lost = 0;
  for (final note in await repo.listSecureNotes()) {
    if (!retired.contains(note.vaultId)) continue;
    if (note.syncedVersion != note.version) lost++;
    await repo.deleteSecureNote(note.id);
    // Queued as well, as a fork is in [applyRemoteNote].
    await OutboxSyncWorker.recordOwedUpload(
      collection: FirestoreCollections.secureNotes,
      documentId: note.id,
    );
    deleted++;
  }
  if (lost > 0) {
    await repo.setLostSecureNoteCount(await repo.lostSecureNoteCount() + lost);
  }
  return deleted;
}

/// [retireSecureNotes] for Photo Series (PHOTO_SERIES_HLD.md §6.7):
/// tombstones every live blob sealed under a retired vault, whose files the
/// purge then deletes, and erases the images showing them. Check-in notes
/// sealed under one are cleared, and a check-in left with no image is erased
/// too, so streaks count only what can still be seen. Erased, as the trash's
/// "Delete forever" does, rather than tombstoned: nothing can open them
/// again, so the trash mustn't offer them back (BUG-296). Ones an earlier
/// pass or a delete only tombstoned are erased as well. Returns how many rows
/// it changed.
Future<int> retireVaultBlobs(
  NotificationRepository notes,
  PhotoSeriesRepository photos,
) async {
  final json = await notes.getSecureVaultHeader();
  if (json == null) return 0;
  final retired = SecureVaultHeader.fromJson(json).retiredVaultIds.toSet();
  if (retired.isEmpty) return 0;
  final now = utcNow();
  var changed = 0;
  final retiredBlobs = <String>{};
  for (final blob in await photos.listBlobs(includeDeleted: true)) {
    if (!retired.contains(blob.vaultId)) continue;
    retiredBlobs.add(blob.id);
    if (blob.deletedAt != null) continue;
    await photos.upsertBlob(blob.copyWith(deletedAt: now, bumpVersion: true));
    changed++;
  }
  final images = <PhotoCheckInImage>[];
  final lost = <String>{};
  // When each check-in's surviving images were deleted, null for live ones:
  // only those deleted with the check-in come back with it from the trash.
  final shown = <String, List<DateTime?>>{};
  for (final image in await photos.listImages(includeDeleted: true)) {
    if (isErasedAt(image.deletedAt)) continue;
    if (retiredBlobs.contains(image.blobId)) {
      images.add(
        image.copyWith(
          deletedAt: kErasedAt,
          version: image.version + kEraseVersionStep,
        ),
      );
      lost.add(image.checkInId);
    } else {
      (shown[image.checkInId] ??= []).add(image.deletedAt);
    }
  }
  final checkIns = <PhotoCheckIn>[];
  for (final checkIn in await photos.listCheckIns(includeDeleted: true)) {
    if (isErasedAt(checkIn.deletedAt)) continue;
    final deletedAt = checkIn.deletedAt;
    final emptied =
        lost.contains(checkIn.id) &&
        !(shown[checkIn.id] ?? const []).any(
          (at) => deletedAt == null
              ? at == null
              : at?.isAtSameMomentAs(deletedAt) ?? false,
        );
    if (emptied) {
      checkIns.add(
        checkIn.copyWith(
          clearNote: true,
          deletedAt: kErasedAt,
          version: checkIn.version + kEraseVersionStep,
        ),
      );
    } else if (checkIn.deletedAt == null && retired.contains(checkIn.vaultId)) {
      checkIns.add(checkIn.copyWith(clearNote: true, bumpVersion: true));
    }
  }
  if (images.isNotEmpty || checkIns.isNotEmpty) {
    await photos.saveAll(checkIns: checkIns, images: images);
  }
  return changed + images.length + checkIns.length;
}

/// Applies the server's copy of note [id] — a pull's half of the conflict
/// check (see [resolveNoteSync]).
Future<void> applyRemoteNote<T extends SyncedNote>(
  NoteSyncStore<T> store,
  String id,
  Map<String, dynamic> remote,
) async {
  final local = await store.get(id);
  switch (store.resolve(local, remote)) {
    case NoteSyncAction.keepLocal:
      return;
    case NoteSyncAction.applyRemote:
      await store.save(store.fromRemote(remote, id, local), upload: false);
    case NoteSyncAction.fork:
      final fork = store.fork(local as T);
      await store.save(fork, upload: true);
      // Queued as well: the outbox's store has no upload of its own to start.
      await OutboxSyncWorker.recordOwedUpload(
        collection: store.collection,
        documentId: fork.id,
      );
      await store.save(store.fromRemote(remote, id, local), upload: false);
  }
}

/// Uploads note [id] only if the server's copy is still the one this device
/// last saw, reading and writing in one transaction through [transact] (see
/// [SyncRepository.writeAfterReading]). When it isn't, the server's copy is
/// applied here instead, as a pull would.
Future<void> uploadNote<T extends SyncedNote>(
  NoteSyncStore<T> store,
  String id,
  NoteTransaction transact,
) async {
  final local = await store.get(id);
  if (local == null) return;
  // A tombstone goes up regardless: it is how a held-back note leaves.
  if (local.deletedAt == null && await store.heldBack?.call(local) == true) {
    return;
  }
  var wrote = false;
  final remote = await transact((remote) {
    // A transaction may run this more than once; the last run is the one
    // that committed.
    wrote = store.resolve(local, remote) == NoteSyncAction.keepLocal;
    return wrote ? store.toFirestore(local) : null;
  });
  if (wrote) {
    await store.markSynced(id, local.version);
  } else if (remote != null) {
    // Read again rather than reused: an edit made since the upload began
    // must meet the server's copy too.
    await applyRemoteNote(store, id, remote);
  }
}
