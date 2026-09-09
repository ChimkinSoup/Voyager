// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:voyager/core/soft_delete/restore_contract.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/services/media_file_store.dart';
import 'package:voyager/domain/models/media_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/repositories/media_storage.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/domain/services/media_ingest.dart';

/// Notified whenever an asset row or a parent's references change, so open
/// surfaces can rebuild without each of them polling.
///
/// Coarse on purpose: a gallery strip is a handful of widgets, and a listener
/// per asset would cost more than rebuilding the few that are on screen.
typedef MediaChangeListener = void Function();

/// The shared media module's front door.
///
/// Features hand it bytes and an owner — `(collection, documentId, facet)` —
/// and get back a reference. Everything underneath (validation, HEIC
/// conversion, compression, dedupe, the file store, refcounting and the
/// retention clock) is this class's business, which is what keeps feature
/// modules free of Storage and queue code.
class MediaService extends ChangeNotifier {
  MediaService({
    required MediaRepository repository,
    required MediaFileStore fileStore,
    required Future<AppSettings> Function() readSettings,
    MediaUploadScheduler? uploadScheduler,
    MediaDownloadScheduler? downloadScheduler,
    MediaSyncPublisher? publisher,
  }) : _repository = repository,
       _fileStore = fileStore,
       _readSettings = readSettings,
       _uploadScheduler = uploadScheduler,
       _downloadScheduler = downloadScheduler,
       _publisher = publisher;

  final MediaRepository _repository;
  final MediaFileStore _fileStore;
  final Future<AppSettings> Function() _readSettings;

  /// Set by the transfer worker once it exists. Null in tests and before
  /// sign-in, where attaching still has to work — the asset simply stays
  /// local until something drains it.
  MediaUploadScheduler? _uploadScheduler;
  MediaDownloadScheduler? _downloadScheduler;

  /// Pushes asset and reference documents through the ordinary document sync.
  /// Null in tests, where nothing is meant to reach the network.
  MediaSyncPublisher? _publisher;

  set uploadScheduler(MediaUploadScheduler? value) => _uploadScheduler = value;
  set downloadScheduler(MediaDownloadScheduler? value) =>
      _downloadScheduler = value;
  set publisher(MediaSyncPublisher? value) => _publisher = value;

  MediaFileStore get fileStore => _fileStore;
  MediaRepository get repository => _repository;

  /// Announces a change made by something other than this class — the
  /// transfer worker moving an asset between states, which surfaces render
  /// as progress. [notifyListeners] itself is protected, so the worker cannot
  /// call it directly.
  void notifyChanged() => notifyListeners();

  /// Ingests [bytes] and attaches the result to a parent.
  ///
  /// Throws [MediaIngestException] with a message meant for the user when the
  /// input is too large, a GIF, or not an image at all. Everything the caller
  /// has to decide is a parameter; nothing about the calling feature is known
  /// here.
  Future<MediaReference> attachBytes({
    required Uint8List bytes,
    required String collection,
    required String documentId,
    MediaFacet facet = MediaFacet.gallery,
    int? sortOrder,
    int? displayWidthPx,
  }) async {
    final asset = await ingestBytes(bytes);
    return addReference(
      mediaId: asset.id,
      collection: collection,
      documentId: documentId,
      facet: facet,
      sortOrder: sortOrder,
      displayWidthPx: displayWidthPx,
    );
  }

  /// Ingests [bytes] into an asset without attaching it anywhere.
  ///
  /// Split from [attachBytes] because "replace this image" needs the asset
  /// before it knows where it goes.
  ///
  /// The asset it returns has **no references yet**, so it is already
  /// unreferenced and on the retention clock. That is deliberate: bytes
  /// ingested by an operation that is then abandoned get swept up 30 days
  /// later instead of living on disk forever.
  Future<MediaAsset> ingestBytes(Uint8List bytes) async {
    final sniffed = validateIngestInput(bytes);

    final request = sniffed == SniffedImageFormat.heic
        ? await _decodeHeic(bytes)
        : MediaIngestRequest.encoded(bytes);

    // Decode, downscale and re-encode are CPU-bound and easily a second on a
    // large photo, so they run off the UI isolate.
    final result = await compute(ingestImageIsolate, request);

    final existing = await _repository.findAssetByContentHash(
      result.contentHash,
    );
    if (existing != null) {
      // Same bytes, so the file on disk is already right. Reviving beats
      // minting a second row: a re-paste of an image the user deleted last
      // week should reuse it, not duplicate it.
      final revived = existing.copyWith(
        clearDeletedAt: true,
        clearUnreferencedAt: true,
        downloadState: MediaDownloadState.present,
        bumpVersion: true,
      );
      await _fileStore.writeBytes(
        result.contentHash,
        result.format,
        result.bytes,
      );
      await _repository.upsertAsset(revived);
      _publisher?.publishAsset(revived);
      notifyListeners();
      return revived;
    }

    await _fileStore.writeBytes(
      result.contentHash,
      result.format,
      result.bytes,
    );

    final settings = await _readSettings();
    final now = utcNow();
    final asset = MediaAsset(
      id: newId(),
      contentHash: result.contentHash,
      byteSize: result.byteSize,
      mimeType: result.format.mimeType,
      width: result.width,
      height: result.height,
      // Off means local forever, not "queued and never drained" — the states
      // are distinct so nothing has to keep re-deciding whether a pending row
      // is really waiting for anything.
      uploadState: settings.mediaRemoteUploadsEnabled
          ? MediaUploadState.pending
          : MediaUploadState.localOnly,
      downloadState: MediaDownloadState.present,
      createdAt: now,
      updatedAt: now,
      unreferencedAt: now,
    );
    await _repository.upsertAsset(asset);
    _publisher?.publishAsset(asset);
    if (asset.uploadState == MediaUploadState.pending) {
      unawaited(_uploadScheduler?.call());
    }
    notifyListeners();
    return asset;
  }

  /// Points a parent at an existing asset.
  ///
  /// [sortOrder] defaults to the end of that parent's facet.
  Future<MediaReference> addReference({
    required String mediaId,
    required String collection,
    required String documentId,
    MediaFacet facet = MediaFacet.gallery,
    int? sortOrder,
    int? displayWidthPx,
  }) async {
    final resolvedSortOrder =
        sortOrder ??
        await _nextSortOrder(collection, documentId, facet);
    final now = utcNow();
    final reference = MediaReference(
      id: newId(),
      mediaId: mediaId,
      collection: collection,
      documentId: documentId,
      facet: facet,
      sortOrder: resolvedSortOrder,
      displayWidthPx: displayWidthPx,
      createdAt: now,
      updatedAt: now,
    );
    await _repository.upsertReference(reference);
    _publisher?.publishReference(reference);
    // The asset now has something pointing at it, so the retention clock that
    // started when it was ingested has to stop.
    await _refreshRefcount(mediaId);
    notifyListeners();
    return reference;
  }

  Future<List<MediaReference>> referencesFor(
    String collection,
    String documentId, {
    MediaFacet? facet,
  }) {
    return _repository.listReferencesForOwner(
      collection,
      documentId,
      facet: facet,
    );
  }

  Future<MediaAsset?> asset(String mediaId) => _repository.getAsset(mediaId);

  /// The assets behind [references], in the same order, skipping any whose
  /// row has gone. What the gallery strip and the lightbox both render from.
  ///
  /// One batched read rather than a `getAsset` per reference: the study card
  /// image map calls this twice per card across the whole library, so the
  /// sequential version cost one round-trip per image in the app, per recompute.
  Future<List<MediaAsset>> assetsFor(List<MediaReference> references) async {
    if (references.isEmpty) return const [];
    final byId = await _repository.getAssets(
      references.map((reference) => reference.mediaId),
    );
    return [
      for (final reference in references)
        if (byId[reference.mediaId] case final asset?) asset,
    ];
  }

  /// Removes one placement. The blob survives until nothing points at it,
  /// and then for another 30 days.
  Future<void> removeReference(String referenceId) async {
    final reference = await _repository.getReference(referenceId);
    if (reference == null) return;
    await _repository.softDeleteReference(referenceId);
    final tombstone = reference.copyWith(
      deletedAt: utcNow(),
      bumpVersion: true,
    );
    _publisher?.publishReference(tombstone);
    await _refreshRefcount(reference.mediaId);
    notifyListeners();
  }

  /// Puts one placement back, undoing [removeReference].
  ///
  /// [snapshot] is the reference as it stood before the removal. Rebuilt from
  /// it rather than read back and un-stamped, because the caller took the
  /// snapshot while the row was still live — and `sortOrder` is what decides
  /// where the image lands in the strip it returns to.
  /// Throws [RestoreSuperseded] when a pull has already put the reference back
  /// during the undo window.
  Future<void> restoreReference(MediaReference snapshot) async {
    // The version is resolved against disk rather than against the snapshot —
    // see [restoreVersionFrom].
    final current = await _repository.getReference(snapshot.id);
    abortIfAlreadyRestored(
      found: current != null,
      deletedAt: current?.deletedAt,
    );
    final restored = snapshot.copyWith(
      clearDeletedAt: true,
      version: restoreVersionFrom(
        preDeleteVersion: snapshot.version,
        currentVersion: current?.version,
      ),
    );
    await _repository.upsertReference(restored);
    _publisher?.publishReference(restored);
    await _refreshRefcount(restored.mediaId);
    notifyListeners();
  }

  /// Removes an asset from every parent that references it, tombstones it for
  /// sync, and drops its local bytes immediately so disk space is reclaimed
  /// at once rather than after the 30-day retention window.
  Future<void> deleteAssetEverywhere(
    String mediaId, {
    MediaStorage? storage,
  }) async {
    final asset = await _repository.getAsset(mediaId);
    if (asset == null || asset.deletedAt != null) return;

    final references = await _repository.listReferencesForAsset(mediaId);
    final now = utcNow();
    for (final reference in references) {
      await _repository.softDeleteReference(reference.id);
      _publisher?.publishReference(
        reference.copyWith(deletedAt: now, bumpVersion: true),
      );
    }

    final deleted = asset.copyWith(
      deletedAt: now,
      unreferencedAt: asset.unreferencedAt ?? now,
      bumpVersion: true,
    );
    await _repository.upsertAsset(deleted);
    _publisher?.publishAsset(deleted);
    await _fileStore.deleteBytesForAsset(asset);

    final uid = storage?.currentUid;
    if (storage != null &&
        uid != null &&
        asset.uploadState == MediaUploadState.uploaded) {
      try {
        await storage.delete(asset.remotePath(uid));
      } catch (error) {
        debugPrint('[media] remote delete failed for ${asset.id}: $error');
      }
    }

    notifyListeners();
  }

  /// Called when a parent entity is soft-deleted, so its images follow it
  /// onto the same 30-day clock.
  ///
  /// Returns the instant the detach stamped, which is the only key
  /// [restoreReferencesForOwner] will match on. It has to be reported rather
  /// than inferred: the parent's own `deletedAt` comes from a different
  /// `utcNow()` a few hundred microseconds earlier, and the rows are stored to
  /// microsecond precision — so a restore keyed on the parent's stamp matches
  /// nothing at all and quietly leaves every image detached. Null when the
  /// parent had no images, in which case there is nothing to put back.
  Future<DateTime?> removeReferencesForOwner(
    String collection,
    String documentId,
  ) async {
    final removed = await _repository.softDeleteReferencesForOwner(
      collection,
      documentId,
    );
    if (removed.isEmpty) return null;
    for (final reference in removed) {
      _publisher?.publishReference(reference);
    }
    for (final mediaId in {for (final r in removed) r.mediaId}) {
      await _refreshRefcount(mediaId);
    }
    notifyListeners();
    return removed.first.deletedAt;
  }

  /// [removeReferencesForOwner] for many parents at once, notifying once at the
  /// end rather than once per parent.
  ///
  /// Every listener rebuild that notification causes re-runs a body that is
  /// O(all images in the app), so detaching a deck of 100 illustrated cards one
  /// at a time triggered ~100 full recomputes of the library-wide image map.
  ///
  /// Returns the instant each parent's detach stamped, for the parents that had
  /// anything to detach — the same per-parent stamp
  /// [restoreReferencesForOwner] matches on.
  Future<Map<String, DateTime>> removeReferencesForOwners(
    String collection,
    Iterable<String> documentIds,
  ) async {
    final stamps = <String, DateTime>{};
    final touchedMediaIds = <String>{};
    for (final documentId in documentIds) {
      final removed = await _repository.softDeleteReferencesForOwner(
        collection,
        documentId,
      );
      if (removed.isEmpty) continue;
      for (final reference in removed) {
        _publisher?.publishReference(reference);
        touchedMediaIds.add(reference.mediaId);
      }
      stamps[documentId] = removed.first.deletedAt!;
    }
    for (final mediaId in touchedMediaIds) {
      await _refreshRefcount(mediaId);
    }
    if (stamps.isNotEmpty) notifyListeners();
    return stamps;
  }

  /// Undoes [removeReferencesForOwner] for a parent whose deletion was undone.
  ///
  /// [deletedAt] is the instant that detach stamped, which is what separates
  /// the images that went with the parent from any the user had already taken
  /// off it — only the former come back.
  Future<void> restoreReferencesForOwner(
    String collection,
    String documentId,
    DateTime deletedAt,
  ) async {
    final revived = await _repository.restoreReferencesForOwner(
      collection,
      documentId,
      deletedAt,
    );
    if (revived.isEmpty) return;
    for (final reference in revived) {
      _publisher?.publishReference(reference);
    }
    for (final mediaId in {for (final r in revived) r.mediaId}) {
      await _refreshRefcount(mediaId);
    }
    notifyListeners();
  }

  /// Moves every reference on [documentId] from [a] to [b] and back again.
  ///
  /// Reversing a study card swaps its two faces, and the pictures on a face
  /// belong to it — a question's diagram is not the answer's. The blobs are
  /// untouched, so nothing here changes a refcount.
  Future<void> swapFacets({
    required String collection,
    required String documentId,
    required MediaFacet a,
    required MediaFacet b,
  }) async {
    final fromA = await _repository.listReferencesForOwner(
      collection,
      documentId,
      facet: a,
    );
    final fromB = await _repository.listReferencesForOwner(
      collection,
      documentId,
      facet: b,
    );
    if (fromA.isEmpty && fromB.isEmpty) return;
    for (final reference in [
      for (final r in fromA) r.copyWith(facet: b, bumpVersion: true),
      for (final r in fromB) r.copyWith(facet: a, bumpVersion: true),
    ]) {
      await _repository.upsertReference(reference);
      _publisher?.publishReference(reference);
    }
    notifyListeners();
  }

  /// Gives [toDocumentId] its own references to everything [fromDocumentId]
  /// points at, keeping each one's facet and position.
  ///
  /// New reference rows around the same assets — duplicating a card copies
  /// where its pictures are, not the pictures themselves, so the copy costs
  /// no disk and no upload.
  Future<void> duplicateReferencesForOwner({
    required String collection,
    required String fromDocumentId,
    required String toDocumentId,
  }) async {
    final source = await _repository.listReferencesForOwner(
      collection,
      fromDocumentId,
    );
    for (final reference in source) {
      await addReference(
        mediaId: reference.mediaId,
        collection: collection,
        documentId: toDocumentId,
        facet: reference.facet,
        sortOrder: reference.sortOrder,
        displayWidthPx: reference.displayWidthPx,
      );
    }
  }

  /// Rewrites the gallery order for one parent from the order of [ordered].
  Future<void> reorderReferences(List<MediaReference> ordered) async {
    for (var i = 0; i < ordered.length; i++) {
      if (ordered[i].sortOrder == i) continue;
      final moved = ordered[i].copyWith(sortOrder: i, bumpVersion: true);
      await _repository.upsertReference(moved);
      _publisher?.publishReference(moved);
    }
    notifyListeners();
  }

  /// Swaps the blob behind a reference, keeping its slot and width.
  Future<MediaAsset> replaceReferenceImage({
    required String referenceId,
    required Uint8List bytes,
  }) async {
    final reference = await _repository.getReference(referenceId);
    if (reference == null) {
      throw const MediaIngestException('That image is no longer attached.');
    }
    final asset = await ingestBytes(bytes);
    final previousMediaId = reference.mediaId;
    final moved = reference.copyWith(mediaId: asset.id, bumpVersion: true);
    await _repository.upsertReference(moved);
    _publisher?.publishReference(moved);
    // Both ends of the swap: the new asset gains a reference, the old one
    // may have just lost its last.
    await _refreshRefcount(asset.id);
    if (previousMediaId != asset.id) {
      await _refreshRefcount(previousMediaId);
    }
    notifyListeners();
    return asset;
  }

  /// Reads an asset's bytes, fetching them if they are missing and the
  /// settings allow it.
  ///
  /// Returns null when the bytes are not here and cannot be got — the caller
  /// renders the "Download disabled" or failed state rather than a spinner
  /// that would never resolve.
  Future<Uint8List?> bytesFor(MediaAsset asset) async {
    final local = await _fileStore.readBytes(asset);
    if (local != null) return local;
    final settings = await _readSettings();
    if (!settings.mediaRemoteDownloadsEnabled) return null;
    await requestDownload(asset);
    return _fileStore.readBytes(await _repository.getAsset(asset.id) ?? asset);
  }

  /// Marks an asset as wanted and wakes the download queue.
  Future<void> requestDownload(MediaAsset asset) async {
    final settings = await _readSettings();
    if (!settings.mediaRemoteDownloadsEnabled) return;
    if (asset.downloadState == MediaDownloadState.present) return;
    if (asset.downloadState != MediaDownloadState.pending) {
      await _repository.upsertAsset(
        asset.copyWith(
          downloadState: MediaDownloadState.pending,
          clearFailureReason: true,
        ),
        recordLocalActivity: false,
      );
      notifyListeners();
    }
    final scheduler = _downloadScheduler;
    if (scheduler != null) await scheduler();
  }

  /// Puts every `localOnly` asset back in the upload queue.
  ///
  /// The repair the design leaves open for "the user turned uploads on later"
  /// — without it, everything attached while the setting was off would stay
  /// stranded on one device forever.
  Future<int> queueLocalOnlyUploads() async {
    final settings = await _readSettings();
    if (!settings.mediaRemoteUploadsEnabled) return 0;
    final stranded = await _repository.listAssetsByUploadState({
      MediaUploadState.localOnly,
    });
    for (final asset in stranded) {
      await _repository.upsertAsset(
        asset.copyWith(
          uploadState: MediaUploadState.pending,
          clearFailureReason: true,
        ),
        recordLocalActivity: false,
      );
    }
    if (stranded.isNotEmpty) {
      notifyListeners();
      unawaited(_uploadScheduler?.call());
    }
    return stranded.length;
  }

  Future<MediaStorageUsage> storageUsage() async {
    final assets = await _repository.listAssets(includeDeleted: true);
    return MediaStorageUsage(
      assetCount: assets.where((a) => a.deletedAt == null).length,
      byteSize: await _fileStore.cacheSizeBytes(),
      pendingUploadCount: assets
          .where(
            (a) =>
                a.uploadState == MediaUploadState.pending ||
                a.uploadState == MediaUploadState.uploading,
          )
          .length,
      pendingDownloadCount: assets
          .where(
            (a) =>
                a.downloadState == MediaDownloadState.pending ||
                a.downloadState == MediaDownloadState.downloading,
          )
          .length,
    );
  }

  /// Permanently deletes everything whose 30-day window has closed — rows,
  /// local files, and the Storage objects when this device is allowed to
  /// reach them.
  ///
  /// Wired into the same startup purge as every other collection, so images
  /// and the entries holding them expire on one clock rather than two.
  Future<void> purgeExpired(DateTime now, {MediaStorage? storage}) async {
    final purged = await _repository.purgeExpiredDeleted(now);
    for (final asset in purged) {
      await _fileStore.deleteBytesForAsset(asset);
      final uid = storage?.currentUid;
      // Only assets that actually reached Storage have an object to remove,
      // and only a signed-in device can remove one. A device that never
      // uploaded simply drops its local copy; whichever device did the upload
      // clears the object on its own purge.
      if (storage != null &&
          uid != null &&
          asset.uploadState == MediaUploadState.uploaded) {
        try {
          await storage.delete(asset.remotePath(uid));
        } catch (error) {
          debugPrint('[media] remote purge failed for ${asset.id}: $error');
        }
      }
    }

    // Blobs on disk that no live row claims — see
    // [MediaFileStore.orphanedFiles].
    final live = await _repository.listAssets(includeDeleted: true);
    final orphans = await _fileStore.orphanedFiles({
      for (final asset in live) asset.contentHash,
    });
    for (final file in orphans) {
      try {
        await file.delete();
      } catch (error) {
        debugPrint('[media] could not delete orphan ${file.path}: $error');
      }
    }
    if (purged.isNotEmpty || orphans.isNotEmpty) notifyListeners();
  }

  /// Recomputes whether anything still points at [mediaId] and starts or
  /// stops its retention clock accordingly.
  ///
  /// The single place the refcount is decided, so attach, detach, replace and
  /// parent-delete cannot disagree about when a blob became garbage.
  Future<void> _refreshRefcount(String mediaId) async {
    final asset = await _repository.getAsset(mediaId);
    if (asset == null) return;
    final live = await _repository.listReferencesForAsset(mediaId);

    if (live.isEmpty && asset.unreferencedAt == null) {
      final marked = asset.copyWith(unreferencedAt: utcNow(), bumpVersion: true);
      await _repository.upsertAsset(marked);
      _publisher?.publishAsset(marked);
      return;
    }
    if (live.isNotEmpty && asset.unreferencedAt != null) {
      final revived = asset.copyWith(
        clearUnreferencedAt: true,
        bumpVersion: true,
      );
      await _repository.upsertAsset(revived);
      _publisher?.publishAsset(revived);
    }
  }

  Future<int> _nextSortOrder(
    String collection,
    String documentId,
    MediaFacet facet,
  ) async {
    final existing = await _repository.listReferencesForOwner(
      collection,
      documentId,
      facet: facet,
    );
    if (existing.isEmpty) return 0;
    return existing.map((r) => r.sortOrder).reduce((a, b) => a > b ? a : b) + 1;
  }

  /// HEIC, via the platform image decoder, into raw RGBA the ingest isolate
  /// can work with.
  ///
  /// Runs here rather than in the isolate because `dart:ui` decoding is the
  /// engine's, and the engine is only on this isolate. It is also the only
  /// step whose availability is platform-dependent: Android delegates HEIF to
  /// the OS decoder, while Windows can only do it when the user has installed
  /// the HEIF extension — hence the explicit refusal rather than a confusing
  /// "could not be read".
  Future<MediaIngestRequest> _decodeHeic(Uint8List bytes) async {
    ui.Image? image;
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      image = frame.image;
      final data = await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      if (data == null) throw const MediaIngestException('HEIC decode failed.');
      return MediaIngestRequest.rgba(
        rgba: data.buffer.asUint8List(),
        rgbaWidth: image.width,
        rgbaHeight: image.height,
      );
    } on MediaIngestException {
      rethrow;
    } catch (_) {
      throw const MediaIngestException(
        'HEIC images are not supported on this device. '
        'Convert the image to JPEG or PNG first.',
      );
    } finally {
      image?.dispose();
    }
  }
}

/// Wakes the upload queue. Returns when the drain has been *started*, not
/// when it has finished — callers are attach paths that must not block on the
/// network.
typedef MediaUploadScheduler = Future<void> Function();

/// Wakes the download queue.
typedef MediaDownloadScheduler = Future<void> Function();

/// How media metadata reaches other devices.
///
/// Assets and references sync as ordinary Firestore documents through the
/// existing document pipeline; this is the seam that keeps `MediaService`
/// from importing the sync layer (which imports the repositories, which would
/// close a cycle).
abstract class MediaSyncPublisher {
  void publishAsset(MediaAsset asset);
  void publishReference(MediaReference reference);
}

/// A [MediaSyncPublisher] that does nothing, for tests and for the window
/// before sign-in.
class NoopMediaSyncPublisher implements MediaSyncPublisher {
  const NoopMediaSyncPublisher();

  @override
  void publishAsset(MediaAsset asset) {}

  @override
  void publishReference(MediaReference reference) {}
}
