// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:voyager/core/dev/error_logger.dart';
import 'package:voyager/core/media/media_service.dart';
import 'package:voyager/core/secure_vault/secure_vault.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/services/vault_media_file_store.dart';
import 'package:voyager/domain/models/media_models.dart';
import 'package:voyager/domain/models/photo_series_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/repositories/media_storage.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/domain/services/media_ingest.dart';

/// The thumbnail's long edge (PHOTO_SERIES_HLD.md §5.5).
const int vaultThumbEdgePx = 384;

/// What every vault file is stored as in Storage: the bytes say nothing of
/// what they hold.
const vaultBlobMimeType = 'application/octet-stream';

/// The Secure Vault's images: ingest, seal, store, transfer and open —
/// [MediaService] and `MediaTransferWorker` in one, for [VaultBlob]s.
///
/// Plaintext exists only in memory. Ingest seals both files before anything
/// is written, and opening a blob decrypts into bytes the caller holds; there
/// is no decrypted cache here.
///
/// Both queues are serial and drain under the same settings as images
/// (`MEDIA.md`): uploads when remote uploads are on, thumbnails whenever
/// downloads are on, full images when background prefetch is on too or when
/// one is opened.
class VaultMediaService extends ChangeNotifier {
  VaultMediaService({
    required PhotoSeriesRepository repository,
    required VaultMediaFileStore fileStore,
    required MediaStorage storage,
    required Future<AppSettings> Function() readSettings,
    this.maxAttempts = 4,
  }) : _repository = repository,
       _fileStore = fileStore,
       _storage = storage,
       _readSettings = readSettings;

  final PhotoSeriesRepository _repository;
  final VaultMediaFileStore _fileStore;
  final MediaStorage _storage;
  final Future<AppSettings> Function() _readSettings;

  /// Transfers of one blob before it is parked as `failed`.
  final int maxAttempts;

  /// Keyed by blob id and direction, so one transfer's failures don't count
  /// against another's.
  final _attempts = <String, int>{};

  /// Blobs ingested this session. Their files land before their row, so the
  /// orphan sweep leaves them be.
  final _ingested = <String>{};

  /// The drain under way in each direction. A call that comes mid-drain
  /// waits on it, and has it go round once more for anything it missed —
  /// see `MediaTransferWorker`.
  Future<void>? _uploads;
  Future<void>? _downloads;
  bool _uploadWakeupPending = false;
  bool _downloadWakeupPending = false;

  PhotoSeriesRepository get repository => _repository;

  /// Announces rows a pull wrote, which tell no one themselves.
  void notifyChanged() => notifyListeners();

  /// Normalises [bytes] as any image is (HEIC to JPEG, downscale, re-encode),
  /// makes its thumbnail, and seals both under [vaultId] before storing them.
  ///
  /// Throws [MediaIngestException] with a message for the user.
  Future<VaultBlob> ingest(
    Uint8List bytes, {
    required SecretKey key,
    required String vaultId,
  }) async {
    final sniffed = validateIngestInput(bytes);
    final request = sniffed == SniffedImageFormat.heic
        ? await MediaService.decodeHeic(bytes)
        : MediaIngestRequest.encoded(bytes);
    final plain = await Isolate.run(() => _ingestWithThumb(request));
    final sealed = await SecureVault.encryptBytes(key, vaultId, plain.bytes);
    final sealedThumb = await SecureVault.encryptBytes(
      key,
      vaultId,
      plain.thumb,
    );

    final id = newId();
    _ingested.add(id);
    await _fileStore.write(id, sealed, thumb: false);
    await _fileStore.write(id, sealedThumb, thumb: true);
    final uploads = (await _readSettings()).mediaRemoteUploadsEnabled;
    final now = utcNow();
    final blob = VaultBlob(
      id: id,
      vaultId: vaultId,
      width: plain.width,
      height: plain.height,
      byteSize: sealed.length,
      thumbByteSize: sealedThumb.length,
      uploadState: uploads
          ? MediaUploadState.pending
          : MediaUploadState.localOnly,
      createdAt: now,
      updatedAt: now,
    );
    await _repository.upsertBlob(blob);
    if (uploads) unawaited(drainUploads());
    notifyListeners();
    return blob;
  }

  /// [blob]'s image, or its thumbnail with [thumb], decrypted. Fetches the
  /// file first if it isn't here and downloads are on. Null when it can't be
  /// had, or doesn't open under [key].
  Future<Uint8List?> open(
    VaultBlob blob,
    SecretKey key, {
    required bool thumb,
  }) async {
    var sealed = await _fileStore.read(blob.id, thumb: thumb);
    if (sealed == null) {
      var current = await _repository.getBlob(blob.id) ?? blob;
      if ((thumb ? current.thumbDownloadState : current.downloadState) ==
          MediaDownloadState.present) {
        // Recorded as here, its file since lost: fetch it again.
        await _repository.updateBlobTransferState(
          blob.id,
          downloadState: thumb ? null : MediaDownloadState.missing,
          thumbDownloadState: thumb ? MediaDownloadState.missing : null,
        );
        current = await _repository.getBlob(blob.id) ?? current;
      }
      if (await _download(current, thumb: thumb)) {
        sealed = await _fileStore.read(blob.id, thumb: thumb);
      }
    }
    if (sealed == null) return null;
    try {
      return await SecureVault.decryptBytes(key, blob.vaultId, sealed);
    } on SecureVaultTamperedException {
      return null;
    }
  }

  /// Tombstones a blob at [at] — the stamp its owner's delete used, so a
  /// restore can bring the two back together. Its files go at the purge.
  Future<void> softDelete(String id, DateTime at) async {
    final blob = await _repository.getBlob(id);
    if (blob == null || blob.deletedAt != null) return;
    await _repository.upsertBlob(
      blob.copyWith(deletedAt: at, bumpVersion: true),
    );
    notifyListeners();
  }

  /// Both queues side by side, so thumbnails don't wait on uploads, and the
  /// Storage deletes purges owe.
  Future<void> drain() async {
    await Future.wait([drainUploads(), drainDownloads(), drainRemoteDeletes()]);
  }

  Future<void> drainUploads() {
    if (_uploads case final running?) {
      _uploadWakeupPending = true;
      return running;
    }
    return _uploads = _drainUploads();
  }

  Future<void> _drainUploads() async {
    try {
      if (!(await _readSettings()).mediaRemoteUploadsEnabled) return;
      final uid = _storage.currentUid;
      if (uid == null) return;
      do {
        _uploadWakeupPending = false;
        for (final blob in await _repository.listBlobsByUploadState({
          MediaUploadState.pending,
          MediaUploadState.uploading,
        })) {
          await _uploadOne(blob, uid);
        }
      } while (_uploadWakeupPending);
    } finally {
      // In the same synchronous step as the last check of the wake-up, so no
      // call can land between the two.
      _uploads = null;
    }
  }

  /// Every missing thumbnail, and the full images queued or — with
  /// background prefetch on — missing.
  Future<void> drainDownloads() {
    if (_downloads case final running?) {
      _downloadWakeupPending = true;
      return running;
    }
    return _downloads = _drainDownloads();
  }

  Future<void> _drainDownloads() async {
    try {
      final settings = await _readSettings();
      if (!settings.mediaRemoteDownloadsEnabled) return;
      if (_storage.currentUid == null) return;
      do {
        _downloadWakeupPending = false;
        const queued = {
          MediaDownloadState.missing,
          MediaDownloadState.pending,
          MediaDownloadState.downloading,
        };
        for (final blob in await _repository.listBlobsByDownloadState(
          queued,
          thumb: true,
        )) {
          await _download(blob, thumb: true);
        }
        for (final blob in await _repository.listBlobsByDownloadState(
          settings.mediaBackgroundPrefetchEnabled
              ? queued
              : const {
                  MediaDownloadState.pending,
                  MediaDownloadState.downloading,
                },
          thumb: false,
        )) {
          await _download(blob, thumb: false);
        }
      } while (_downloadWakeupPending);
    } finally {
      _downloads = null;
    }
  }

  /// Puts every parked transfer back in its queue and drains — once per
  /// launch, as `MediaTransferWorker.requeueFailedUploads` does.
  Future<void> requeueFailed() async {
    for (final blob in await _repository.listBlobs()) {
      await _unpark(blob);
    }
    await drain();
  }

  /// Puts [blob]'s parked transfers back in their queues and drains: the
  /// way back from a failed photo between launches.
  Future<void> retry(VaultBlob blob) async {
    if (!await _unpark(blob)) return;
    notifyListeners();
    await drain();
  }

  /// Requeues [blob]'s parked transfers. Whether it had any.
  Future<bool> _unpark(VaultBlob blob) async {
    final upload = blob.uploadState == MediaUploadState.failed;
    final download = blob.downloadState == MediaDownloadState.failed;
    final thumb = blob.thumbDownloadState == MediaDownloadState.failed;
    if (!upload && !download && !thumb) return false;
    for (final direction in _directions) {
      _attempts.remove('${blob.id}:$direction');
    }
    await _repository.updateBlobTransferState(
      blob.id,
      uploadState: upload ? MediaUploadState.pending : null,
      downloadState: download ? MediaDownloadState.pending : null,
      thumbDownloadState: thumb ? MediaDownloadState.pending : null,
      clearFailureReason: true,
    );
    return true;
  }

  /// Blobs kept local while uploads were off, queued now they are on.
  Future<void> queueLocalOnlyUploads() async {
    if (!(await _readSettings()).mediaRemoteUploadsEnabled) return;
    for (final blob in await _repository.listBlobsByUploadState({
      MediaUploadState.localOnly,
    })) {
      if (!blob.hasLocalBytes) continue;
      await _repository.updateBlobTransferState(
        blob.id,
        uploadState: MediaUploadState.pending,
      );
    }
    await drainUploads();
  }

  /// Permanently deletes blobs tombstoned 30 days ago: rows, files, and the
  /// Storage objects this device can reach. Files no live row claims go too.
  Future<void> purgeExpired(DateTime now) async {
    final purged = await _repository.purgeExpiredDeleted(now);
    for (final blob in purged) {
      await _fileStore.delete(blob.id);
    }
    await drainRemoteDeletes();
    final live = {
      ..._ingested,
      for (final blob in await _repository.listBlobs(includeDeleted: true))
        blob.id,
    };
    for (final file in await _fileStore.orphanedFiles(live)) {
      try {
        await file.delete();
      } catch (error) {
        debugPrint('[vault media] could not delete orphan ${file.path}');
      }
    }
    if (purged.isNotEmpty) notifyListeners();
  }

  /// Sends the Storage deletes purges owe, keeping any that fail for the next
  /// launch or reconnect.
  Future<void> drainRemoteDeletes() async {
    final uid = _storage.currentUid;
    if (uid == null) return;
    for (final path in await _repository.listPendingRemoteDeletes()) {
      try {
        await _storage.delete('users/$uid/$path');
      } catch (error, stackTrace) {
        ErrorLogger.instance.record(
          error,
          stackTrace,
          context: 'vault media: remote purge of $path',
        );
        continue;
      }
      await _repository.removePendingRemoteDelete(path);
    }
  }

  Future<void> _uploadOne(VaultBlob blob, String uid) async {
    final sealed = await _fileStore.read(blob.id, thumb: false);
    final sealedThumb = await _fileStore.read(blob.id, thumb: true);
    if (sealed == null || sealedThumb == null) {
      if (blob.hasLocalBytes) {
        // This device's blob, its files lost: nothing to send, and it must
        // not be announced as in Storage.
        await _repository.updateBlobTransferState(
          blob.id,
          uploadState: MediaUploadState.failed,
          failureReason: 'Photo files are missing on this device.',
        );
        notifyListeners();
        return;
      }
      // Another device's blob, not yet here: the download queue's.
      await _repository.updateBlobTransferState(
        blob.id,
        uploadState: MediaUploadState.uploaded,
      );
      return;
    }
    await _repository.updateBlobTransferState(
      blob.id,
      uploadState: MediaUploadState.uploading,
    );
    try {
      await _storage.upload(
        blob.thumbRemotePath(uid),
        sealedThumb,
        vaultBlobMimeType,
      );
      await _storage.upload(blob.remotePath(uid), sealed, vaultBlobMimeType);
      _attempts.remove('${blob.id}:up');
      await _repository.updateBlobTransferState(
        blob.id,
        uploadState: MediaUploadState.uploaded,
        clearFailureReason: true,
      );
    } catch (error) {
      await _recordFailure(
        '${blob.id}:up',
        error,
        park: (message) => _repository.updateBlobTransferState(
          blob.id,
          uploadState: MediaUploadState.failed,
          failureReason: message,
        ),
        requeue: () => _repository.updateBlobTransferState(
          blob.id,
          uploadState: MediaUploadState.pending,
        ),
      );
      notifyListeners();
      return;
    }
    // Tells the other devices the files are in Storage, through `inCloud`.
    final uploaded = await _repository.getBlob(blob.id);
    if (uploaded != null) {
      await _repository.upsertBlob(uploaded.copyWith(bumpVersion: true));
    }
    notifyListeners();
  }

  /// Fetches one of [blob]'s files. Whether it is here now.
  Future<bool> _download(VaultBlob blob, {required bool thumb}) async {
    final state = thumb ? blob.thumbDownloadState : blob.downloadState;
    if (state == MediaDownloadState.present) return true;
    if (state == MediaDownloadState.failed || blob.isOnlyElsewhere) {
      return false;
    }
    final uid = _storage.currentUid;
    if (uid == null) return false;
    if (!(await _readSettings()).mediaRemoteDownloadsEnabled) return false;

    Future<void> mark(MediaDownloadState state, {String? failure}) =>
        _repository.updateBlobTransferState(
          blob.id,
          downloadState: thumb ? null : state,
          thumbDownloadState: thumb ? state : null,
          failureReason: failure,
          clearFailureReason: failure == null,
        );

    final attemptsKey = '${blob.id}:${thumb ? 'thumb' : 'full'}';
    await mark(MediaDownloadState.downloading);
    try {
      final sealed = await _storage.download(
        thumb ? blob.thumbRemotePath(uid) : blob.remotePath(uid),
      );
      // Only the key can tell whether these are the right bytes; their size
      // catches a truncated or substituted object without it.
      if (sealed.length != (thumb ? blob.thumbByteSize : blob.byteSize)) {
        throw const MediaStoragePermanentFailure(
          'Downloaded file does not match the photo.',
        );
      }
      await _fileStore.write(blob.id, sealed, thumb: thumb);
      _attempts.remove(attemptsKey);
      await mark(MediaDownloadState.present);
      notifyListeners();
      return true;
    } catch (error) {
      await _recordFailure(
        attemptsKey,
        error,
        park: (message) => mark(MediaDownloadState.failed, failure: message),
        requeue: () => mark(MediaDownloadState.pending),
      );
      notifyListeners();
      return false;
    }
  }

  Future<void> _recordFailure(
    String attemptsKey,
    Object error, {
    required Future<void> Function(String message) park,
    required Future<void> Function() requeue,
  }) async {
    final attempts = (_attempts[attemptsKey] ?? 0) + 1;
    _attempts[attemptsKey] = attempts;
    if (error is MediaStoragePermanentFailure || attempts >= maxAttempts) {
      _attempts.remove(attemptsKey);
      debugPrint('[vault media] parking $attemptsKey: $error');
      await park(error.toString());
      return;
    }
    await requeue();
  }
}

const _directions = ['up', 'thumb', 'full'];

/// [ingestImageIsolate], plus the thumbnail from the same decoded pixels.
({Uint8List bytes, Uint8List thumb, int width, int height}) _ingestWithThumb(
  MediaIngestRequest request,
) {
  final (:result, pixels: decoded) = ingestImageWithPixels(request);
  // Never larger than the image itself.
  final thumb = math.max(decoded.width, decoded.height) <= vaultThumbEdgePx
      ? decoded
      : img.copyResize(
          decoded,
          width: decoded.width >= decoded.height ? vaultThumbEdgePx : null,
          height: decoded.height > decoded.width ? vaultThumbEdgePx : null,
          interpolation: img.Interpolation.average,
        );
  return (
    bytes: result.bytes,
    thumb: result.format == MediaImageFormat.png
        ? img.encodePng(thumb)
        : img.encodeJpg(thumb, quality: ingestJpegQuality),
    width: result.width,
    height: result.height,
  );
}
