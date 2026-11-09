import 'dart:async';
import 'dart:io';

import 'package:voyager/core/media/media_service.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/domain/models/media_models.dart';

/// An image attached to a chat, as stored: its asset and the local file
/// holding the bytes an agent gets.
typedef GaiaStoredImage = ({
  String mediaId,
  String referenceId,
  String path,
  String mimeType,
  int width,
  int height,
});

/// Gaia's images in the media module (GAIA_HLD.md §8): one reference per
/// image, owned by its chat, so a chat's delete takes its images onto the
/// same 30-day clock and a restore brings them back.
class GaiaMedia {
  GaiaMedia(this._media);

  final MediaService _media;

  /// Ingests the image at [path] onto [chatId]. Throws
  /// `MediaIngestException` for one the module refuses.
  ///
  /// [mediaId], a draft's image already ingested (§9.3), is put on [chatId]
  /// as it is: ingesting [path] again only finds the same asset, after a
  /// decode and re-encode that take seconds an image in a debug build. [path]
  /// is ingested after all when that asset or its file isn't here, or when
  /// its upload may have been purged since: ingesting is what sends it again
  /// (BUG-265).
  Future<GaiaStoredImage> attach(
    String chatId,
    String path, {
    String? mediaId,
  }) async {
    final stored = mediaId == null ? null : await _media.asset(mediaId);
    final file =
        stored == null ||
            stored.deletedAt != null ||
            (stored.uploadState == MediaUploadState.uploaded &&
                stored.retentionClockStartedAt != null)
        ? null
        : await _media.fileStore.fileForAsset(stored);
    if (stored != null && file != null) {
      final reference = await _media.trackAttach(
        () => _media.addReference(
          mediaId: stored.id,
          collection: FirestoreCollections.gaiaChats,
          documentId: chatId,
        ),
      );
      return (
        mediaId: stored.id,
        referenceId: reference.id,
        path: file.path,
        mimeType: stored.mimeType,
        width: stored.width,
        height: stored.height,
      );
    }
    final reference = await _media.attachBytes(
      bytes: await File(path).readAsBytes(),
      collection: FirestoreCollections.gaiaChats,
      documentId: chatId,
    );
    final asset = (await _media.asset(reference.mediaId))!;
    return (
      mediaId: asset.id,
      referenceId: reference.id,
      path: (await _media.fileStore.fileForAsset(asset))!.path,
      mimeType: asset.mimeType,
      width: asset.width,
      height: asset.height,
    );
  }

  /// Ingests the image at [path] for a draft (§9.3), on no draft yet:
  /// [keepDraft] puts it on one. Throws `MediaIngestException` for one the
  /// module refuses.
  Future<String> ingest(String path) async =>
      (await _media.ingestBytes(await File(path).readAsBytes())).id;

  /// [draftId]'s images are [mediaIds], and no others: one taken off the
  /// draft goes onto the 30-day clock, unless a message has it too.
  Future<void> keepDraft(String draftId, Set<String> mediaIds) async {
    final references = await _media.referencesFor(
      FirestoreCollections.gaiaDrafts,
      draftId,
    );
    for (final reference in references) {
      if (!mediaIds.contains(reference.mediaId)) {
        await _media.removeReference(reference.id);
      }
    }
    final held = {for (final reference in references) reference.mediaId};
    for (final mediaId in mediaIds.difference(held)) {
      // Not synced here yet: the device that attached it holds it.
      if (await _media.asset(mediaId) == null) continue;
      await _media.addReference(
        mediaId: mediaId,
        collection: FirestoreCollections.gaiaDrafts,
        documentId: draftId,
      );
    }
  }

  /// Puts [mediaIds], already another chat's, on [chatId] too: a fork's
  /// copies (GAIA_FORKING_HLD.md §2), whose images then outlive the source
  /// chat's delete.
  Future<void> share(String chatId, Set<String> mediaIds) async {
    // Each one's asset row may not have synced here yet: the reference is
    // made anyway, as a reference synced in ahead of its asset is.
    for (final mediaId in mediaIds) {
      await _media.addReference(
        mediaId: mediaId,
        collection: FirestoreCollections.gaiaChats,
        documentId: chatId,
      );
    }
  }

  /// Takes an image [attach] put on a chat off it again: its send didn't
  /// happen.
  Future<void> detach(String referenceId) =>
      _media.removeReference(referenceId);

  /// Takes [chatId]'s images onto its 30-day clock as it's deleted. The
  /// stamp [restoreChat] needs to bring them back, or null if it had none.
  Future<DateTime?> removeChat(String chatId) =>
      _media.removeReferencesForOwner(FirestoreCollections.gaiaChats, chatId);

  Future<void> restoreChat(String chatId, DateTime deletedAt) =>
      _media.restoreReferencesForOwner(
        FirestoreCollections.gaiaChats,
        chatId,
        deletedAt,
      );

  /// [file], waiting up to [wait] for the download it asks for: a draft's
  /// image synced from another device (§9.3). Null when it doesn't come.
  Future<String?> fileWhenHere(
    String mediaId, {
    Duration wait = const Duration(minutes: 2),
  }) async {
    final deadline = DateTime.now().add(wait);
    while (true) {
      if (await file(mediaId) case final path?) return path;
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) return null;
      // A download's end notifies; an asset row arriving by sync may not,
      // so it's looked for again every few seconds too.
      final changed = Completer<void>();
      void onChange() {
        if (!changed.isCompleted) changed.complete();
      }

      _media.addListener(onChange);
      try {
        await changed.future.timeout(
          left < const Duration(seconds: 5) ? left : const Duration(seconds: 5),
          onTimeout: () {},
        );
      } finally {
        _media.removeListener(onChange);
      }
    }
  }

  /// The local file holding [mediaId]'s bytes; null while they're only
  /// remote, when a download is asked for.
  Future<String?> file(String mediaId) async {
    final asset = await _media.asset(mediaId);
    if (asset == null) return null;
    final file = await _media.fileStore.fileForAsset(asset);
    if (file == null) await _media.requestDownload(asset);
    return file?.path;
  }
}
