import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/domain/models/media_models.dart';
import 'package:voyager/domain/models/soft_deletable.dart';

/// One encrypted image and its thumbnail, sealed under the Secure Vault —
/// the vault's counterpart to [MediaAsset] (PHOTO_SERIES_HLD.md §5.5).
///
/// Not a [MediaAsset]: those are named by a hash of their plaintext, which
/// tells anyone with the bucket which photos are the same, and are kept on
/// disk in the clear. A blob is named by a random [id], here and in Storage,
/// and each of its two files is `nonce ‖ ciphertext ‖ tag`, readable with the
/// vault's key alone.
///
/// The transfer states are this device's, never synced, as on [MediaAsset].
/// [uploadState] covers both files, which always go up together; the
/// thumbnail downloads on its own, eagerly, so the grid works offline.
class VaultBlob extends SoftDeletable {
  const VaultBlob({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.version,
    super.deletedAt,
    required this.vaultId,
    required this.width,
    required this.height,
    required this.byteSize,
    required this.thumbByteSize,
    this.uploadState = MediaUploadState.localOnly,
    this.downloadState = MediaDownloadState.present,
    this.thumbDownloadState = MediaDownloadState.present,
    this.failureReason,
  });

  /// The vault both files were sealed under. A blob from any other vault —
  /// one since reset — can never be read again.
  final String vaultId;

  /// The full image's size after ingest.
  final int width;
  final int height;

  /// Ciphertext sizes.
  final int byteSize;
  final int thumbByteSize;

  final MediaUploadState uploadState;
  final MediaDownloadState downloadState;
  final MediaDownloadState thumbDownloadState;

  /// Why the last transfer gave up, for the retry UI.
  final String? failureReason;

  String remotePath(String uid) => 'users/$uid/vault_media/$id';
  String thumbRemotePath(String uid) => 'users/$uid/vault_media/$id.thumb';

  bool get hasLocalBytes => downloadState == MediaDownloadState.present;
  bool get hasLocalThumb => thumbDownloadState == MediaDownloadState.present;

  /// Whether the files are only on another device, which has not put them in
  /// Storage: nothing here can fetch them until it does.
  bool get isOnlyElsewhere =>
      !hasLocalBytes && uploadState == MediaUploadState.localOnly;

  VaultBlob copyWith({
    int? width,
    int? height,
    MediaUploadState? uploadState,
    MediaDownloadState? downloadState,
    MediaDownloadState? thumbDownloadState,
    DateTime? updatedAt,
    int? version,
    bool bumpVersion = false,
    DateTime? deletedAt,
    bool clearDeletedAt = false,
    String? failureReason,
    bool clearFailureReason = false,
  }) {
    return VaultBlob(
      id: id,
      vaultId: vaultId,
      width: width ?? this.width,
      height: height ?? this.height,
      byteSize: byteSize,
      thumbByteSize: thumbByteSize,
      uploadState: uploadState ?? this.uploadState,
      downloadState: downloadState ?? this.downloadState,
      thumbDownloadState: thumbDownloadState ?? this.thumbDownloadState,
      failureReason: clearFailureReason
          ? null
          : (failureReason ?? this.failureReason),
      createdAt: createdAt,
      updatedAt: updatedAt ?? utcNow(),
      version: bumpVersion ? this.version + 1 : (version ?? this.version),
      deletedAt: clearDeletedAt ? null : (deletedAt ?? this.deletedAt),
    );
  }
}
