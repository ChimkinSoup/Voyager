// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:voyager/core/media/media_service.dart';
import 'package:voyager/domain/models/media_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/repositories/media_storage.dart';
import 'package:voyager/domain/repositories/repositories.dart';

/// Drains the two blob queues.
///
/// Kept apart from `OutboxSyncWorker` — which drains the *document* outbox —
/// because the two have almost nothing in common beyond when they run: blobs
/// are megabytes rather than kilobytes, are gated by three settings the
/// document queue knows nothing about, and fail in ways (a bucket rule, a
/// missing object) that have no document equivalent. They share the
/// connectivity lifecycle and nothing else.
///
/// Both drains are serial. Uploading four photos at once on a phone hotspot
/// finishes no sooner than uploading them one after another and makes every
/// one of them slow, so concurrency here would only cost responsiveness.
class MediaTransferWorker {
  MediaTransferWorker({
    required MediaRepository repository,
    required MediaService service,
    required MediaStorage storage,
    required Future<AppSettings> Function() readSettings,
    this.maxAttempts = 4,
  }) : _repository = repository,
       _service = service,
       _storage = storage,
       _readSettings = readSettings;

  final MediaRepository _repository;
  final MediaService _service;
  final MediaStorage _storage;
  final Future<AppSettings> Function() _readSettings;

  /// Transfers of one asset before it is parked as `failed`.
  ///
  /// Bounded rather than endless so a blob the bucket will never accept stops
  /// consuming bandwidth on every launch, and shows the user a retryable
  /// error instead of a spinner that never ends.
  final int maxAttempts;

  final _attempts = <String, int>{};
  bool _uploadDraining = false;
  bool _downloadDraining = false;

  /// A wake-up that arrived while the matching queue was already draining.
  ///
  /// Without these, attaching an image during a drain is silently lost: the
  /// running pass has already read its list of rows, so the new asset is not
  /// in it, and the call that would have picked it up returned early on the
  /// re-entrancy guard. The image then sits `pending` until something else
  /// happens to drain the queue. Remembering the wake-up and going round once
  /// more costs one extra query and closes that window.
  bool _uploadWakeupPending = false;
  bool _downloadWakeupPending = false;

  /// True while either queue is moving, for the progress badge.
  bool get isTransferring => _uploadDraining || _downloadDraining;

  /// Drains everything queued, in both directions.
  ///
  /// The entry point the connectivity lifecycle calls. Uploads go first: a
  /// device that just came back online is more likely to be holding something
  /// no other device has than to be missing something it can fetch later.
  Future<void> drain() async {
    await drainUploads();
    await drainDownloads();
  }

  Future<void> drainUploads() async {
    if (_uploadDraining) {
      _uploadWakeupPending = true;
      return;
    }
    final settings = await _readSettings();
    if (!settings.mediaRemoteUploadsEnabled) return;
    final uid = _storage.currentUid;
    if (uid == null) return;

    _uploadDraining = true;
    try {
      do {
        _uploadWakeupPending = false;
        // `uploading` is included so a drain interrupted by a crash or a
        // killed app picks its rows back up instead of leaving them stuck
        // mid-flight forever.
        final queued = await _repository.listAssetsByUploadState({
          MediaUploadState.pending,
          MediaUploadState.uploading,
        });
        for (final asset in queued) {
          await _uploadOne(asset, uid);
        }
      } while (_uploadWakeupPending);
    } finally {
      _uploadDraining = false;
    }
  }

  Future<void> drainDownloads() async {
    if (_downloadDraining) {
      _downloadWakeupPending = true;
      return;
    }
    final settings = await _readSettings();
    if (!settings.mediaRemoteDownloadsEnabled) return;
    final uid = _storage.currentUid;
    if (uid == null) return;

    _downloadDraining = true;
    try {
      do {
        _downloadWakeupPending = false;
        final queued = await _repository.listAssetsByDownloadState({
          MediaDownloadState.pending,
          MediaDownloadState.downloading,
        });
        for (final asset in queued) {
          await _downloadOne(asset, uid);
        }
      } while (_downloadWakeupPending);
    } finally {
      _downloadDraining = false;
    }
  }

  /// Queues every asset this device knows about but has no bytes for.
  ///
  /// The background prefetch. Runs after a document pull, which is when new
  /// assets are learned about, and does nothing at all unless both the
  /// prefetch and the downloads settings are on — a prefetch with downloads
  /// off would be queueing work the drain refuses to do.
  Future<void> prefetchMissing() async {
    final settings = await _readSettings();
    if (!settings.mediaRemoteDownloadsEnabled) return;
    if (!settings.mediaBackgroundPrefetchEnabled) return;

    // Prefetch is the one transfer nobody is waiting for, so it is also the
    // one to give up when the disk is nearly full — an on-demand fetch of
    // something on screen still goes through.
    if (await _service.fileStore.isDiskLow()) {
      debugPrint('[media] skipping prefetch: free disk below 5%');
      return;
    }

    final missing = await _repository.listAssetsByDownloadState({
      MediaDownloadState.missing,
    });
    for (final asset in missing) {
      await _repository.upsertAsset(
        asset.copyWith(
          downloadState: MediaDownloadState.pending,
          clearFailureReason: true,
        ),
        recordLocalActivity: false,
      );
    }
    if (missing.isNotEmpty) await drainDownloads();
  }

  /// Puts every upload parked as `failed` back in the queue.
  ///
  /// A permanent failure parks an asset on its first attempt, and nothing
  /// afterwards picks it back up: [MediaService.queueLocalOnlyUploads]
  /// rescues `localOnly` only. So fixing whatever caused the refusal — a
  /// Storage rule that denied every write, most often — would otherwise leave
  /// every image attached beforehand stranded with a failed badge forever.
  ///
  /// Once per launch rather than on every drain, which is what keeps the
  /// "stop burning bandwidth on a blob the bucket will never accept" property
  /// the parking exists for: a permanent refusal costs one attempt at startup
  /// and a transient one at most [maxAttempts], and either way the asset then
  /// stays quiet until the next launch.
  Future<int> requeueFailedUploads() async {
    final settings = await _readSettings();
    if (!settings.mediaRemoteUploadsEnabled) return 0;

    final parked = await _repository.listAssetsByUploadState({
      MediaUploadState.failed,
    });
    for (final asset in parked) {
      // The attempt count is what parked it; leaving it in place would park
      // the asset again on its first failure rather than after [maxAttempts].
      _attempts.remove(asset.id);
      await _repository.upsertAsset(
        asset.copyWith(
          uploadState: MediaUploadState.pending,
          clearFailureReason: true,
        ),
        recordLocalActivity: false,
      );
    }
    if (parked.isEmpty) return 0;
    _service.notifyChanged();
    await drainUploads();
    return parked.length;
  }

  Future<void> _uploadOne(MediaAsset asset, String uid) async {
    final bytes = await _service.fileStore.readBytes(asset);
    if (bytes == null) {
      // Nothing to send. This is not a failure — it is an asset another
      // device made whose bytes have not arrived here yet, so the download
      // queue owns it, not this one.
      await _repository.upsertAsset(
        asset.copyWith(uploadState: MediaUploadState.localOnly),
        recordLocalActivity: false,
      );
      return;
    }

    await _repository.upsertAsset(
      asset.copyWith(uploadState: MediaUploadState.uploading),
      recordLocalActivity: false,
    );
    _service.notifyChanged();

    try {
      await _storage.upload(asset.remotePath(uid), bytes, asset.mimeType);
      _attempts.remove(asset.id);
      await _repository.upsertAsset(
        asset.copyWith(
          uploadState: MediaUploadState.uploaded,
          clearFailureReason: true,
        ),
        recordLocalActivity: false,
      );
    } catch (error) {
      await _recordFailure(
        asset,
        error,
        park: (message) => asset.copyWith(
          uploadState: MediaUploadState.failed,
          failureReason: message,
        ),
        requeue: () => asset.copyWith(uploadState: MediaUploadState.pending),
      );
    }
    _service.notifyChanged();
  }

  Future<void> _downloadOne(MediaAsset asset, String uid) async {
    final format = MediaImageFormat.fromMimeType(asset.mimeType);
    if (format == null) {
      await _repository.upsertAsset(
        asset.copyWith(
          downloadState: MediaDownloadState.failed,
          failureReason: 'Unsupported image type (${asset.mimeType}).',
        ),
        recordLocalActivity: false,
      );
      return;
    }

    await _repository.upsertAsset(
      asset.copyWith(downloadState: MediaDownloadState.downloading),
      recordLocalActivity: false,
    );
    _service.notifyChanged();

    try {
      final bytes = await _storage.download(asset.remotePath(uid));
      await _service.fileStore.writeBytes(asset.contentHash, format, bytes);
      _attempts.remove(asset.id);
      await _repository.upsertAsset(
        asset.copyWith(
          downloadState: MediaDownloadState.present,
          // The bytes are here, so this device now has something to offer —
          // but only if uploads are on, and only as a blob it did not make.
          // Marking it `uploaded` is the truth: the object exists in Storage,
          // which is where these bytes just came from.
          uploadState: MediaUploadState.uploaded,
          clearFailureReason: true,
        ),
        recordLocalActivity: false,
      );
    } catch (error) {
      await _recordFailure(
        asset,
        error,
        park: (message) => asset.copyWith(
          downloadState: MediaDownloadState.failed,
          failureReason: message,
        ),
        requeue: () =>
            asset.copyWith(downloadState: MediaDownloadState.pending),
      );
    }
    _service.notifyChanged();
  }

  /// Parks or re-queues a failed transfer.
  ///
  /// A permanent failure parks immediately — retrying a missing object or a
  /// rejected write fails the same way every time. Everything else gets
  /// [maxAttempts] before it is parked, so a flaky connection recovers on its
  /// own while a genuinely broken blob stops costing bandwidth.
  Future<void> _recordFailure(
    MediaAsset asset,
    Object error, {
    required MediaAsset Function(String message) park,
    required MediaAsset Function() requeue,
  }) async {
    final attempts = (_attempts[asset.id] ?? 0) + 1;
    _attempts[asset.id] = attempts;

    final permanent = error is MediaStoragePermanentFailure;
    if (permanent || attempts >= maxAttempts) {
      _attempts.remove(asset.id);
      debugPrint('[media] parking ${asset.id} after $attempts attempt(s): $error');
      await _repository.upsertAsset(
        park(error.toString()),
        recordLocalActivity: false,
      );
      return;
    }
    debugPrint('[media] transfer attempt $attempts failed for ${asset.id}: $error');
    await _repository.upsertAsset(requeue(), recordLocalActivity: false);
  }

  /// Puts a parked asset back in its queue, for the retry affordance on a
  /// failed image.
  Future<void> retry(MediaAsset asset) async {
    _attempts.remove(asset.id);
    var updated = asset.copyWith(clearFailureReason: true);
    if (asset.uploadState == MediaUploadState.failed) {
      updated = updated.copyWith(uploadState: MediaUploadState.pending);
    }
    if (asset.downloadState == MediaDownloadState.failed) {
      updated = updated.copyWith(downloadState: MediaDownloadState.pending);
    }
    await _repository.upsertAsset(updated, recordLocalActivity: false);
    _service.notifyChanged();
    await drain();
  }
}
