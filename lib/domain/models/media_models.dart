import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/domain/models/soft_deletable.dart';

/// Where a blob's bytes have got to on the way *out* of this device.
///
/// [localOnly] is the resting state when remote uploads are switched off — it
/// is not a failure and not a queue position, so nothing ever drains it. The
/// other four describe a blob that is meant to reach Storage: [pending] is
/// waiting for a drain, [uploading] is in flight, [uploaded] is done, and
/// [failed] has exhausted its retries and stays visible rather than silently
/// reverting to pending forever.
enum MediaUploadState { localOnly, pending, uploading, uploaded, failed }

/// Whether this device holds the bytes, mirroring [MediaUploadState] on the
/// way *in*.
///
/// [present] means the file is on disk and readable. [missing] means the
/// metadata arrived from another device but the bytes have not — the state a
/// freshly pulled asset lands in, and the one the "Download disabled" empty
/// state is shown for.
enum MediaDownloadState { present, pending, downloading, missing, failed }

/// Which part of a parent document a reference hangs off.
///
/// A study card has an independent gallery per face, so [front]/[back]
/// separate them; [gallery] is the ordered strip that todo, journal and
/// rankings use.
enum MediaFacet { front, back, gallery }

/// The image formats ingest accepts, and the only ones [MediaAsset.mimeType]
/// ever holds.
///
/// HEIC is deliberately absent: it is accepted as *input* and converted to
/// JPEG on the way in, so it never reaches storage or a mime type. GIF is out
/// per the design's non-goals.
enum MediaImageFormat {
  jpeg('image/jpeg', 'jpg'),
  png('image/png', 'png'),
  webp('image/webp', 'webp');

  const MediaImageFormat(this.mimeType, this.extension);

  final String mimeType;
  final String extension;

  static MediaImageFormat? fromMimeType(String mimeType) {
    for (final format in values) {
      if (format.mimeType == mimeType) return format;
    }
    return null;
  }
}

/// One unique blob of image bytes, deduplicated by [contentHash].
///
/// There is exactly one row per hash per account: two entries that paste the
/// same screenshot share this asset and differ only in their
/// [MediaReference]s. That is what makes deletion refcount-based rather than
/// cascade-based.
class MediaAsset extends SoftDeletable {
  const MediaAsset({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.version,
    super.deletedAt,
    required this.contentHash,
    required this.byteSize,
    required this.mimeType,
    required this.width,
    required this.height,
    this.uploadState = MediaUploadState.localOnly,
    this.downloadState = MediaDownloadState.present,
    this.unreferencedAt,
    this.failureReason,
  });

  /// Hash of the **post-ingest** bytes — after HEIC conversion and
  /// downscaling — so two devices that ingest the same original independently
  /// only agree if their pipelines produced identical output.
  ///
  /// [id] stays distinct from it so that a reference quoting the id survives
  /// the bytes behind it being replaced.
  final String contentHash;

  final int byteSize;
  final String mimeType;
  final int width;
  final int height;
  final MediaUploadState uploadState;
  final MediaDownloadState downloadState;

  /// When the last reference to this asset went away.
  ///
  /// Kept separate from [deletedAt] because the two answer different
  /// questions: [deletedAt] means "the user deleted this image", while
  /// [unreferencedAt] means "nothing points here any more". Both start the
  /// same 30-day clock, but an asset that becomes referenced again — an undo,
  /// a re-paste of identical bytes that dedupes onto it — simply clears this
  /// and keeps its bytes, which a tombstone could not do.
  final DateTime? unreferencedAt;

  /// Why the last transfer attempt gave up, for the retry UI. Null whenever
  /// neither state above is a `failed`.
  final String? failureReason;

  /// The object's path in Firebase Storage, under the owner's uid prefix.
  ///
  /// Content-addressed rather than id-addressed so that two assets which
  /// deduped to the same bytes on different devices converge on one object
  /// instead of racing to upload two copies of it.
  String remotePath(String uid) => 'users/$uid/media/$contentHash';

  /// Whether the bytes are readable on this device right now.
  bool get hasLocalBytes => downloadState == MediaDownloadState.present;

  /// Whether this asset still counts against the 30-day purge clock, and from
  /// when. Null while it is live and referenced.
  DateTime? get retentionClockStartedAt => deletedAt ?? unreferencedAt;

  MediaAsset copyWith({
    String? contentHash,
    int? byteSize,
    String? mimeType,
    int? width,
    int? height,
    MediaUploadState? uploadState,
    MediaDownloadState? downloadState,
    DateTime? createdAt,
    DateTime? updatedAt,
    int? version,
    bool bumpVersion = false,
    DateTime? deletedAt,
    bool clearDeletedAt = false,
    DateTime? unreferencedAt,
    bool clearUnreferencedAt = false,
    String? failureReason,
    bool clearFailureReason = false,
  }) {
    return MediaAsset(
      id: id,
      contentHash: contentHash ?? this.contentHash,
      byteSize: byteSize ?? this.byteSize,
      mimeType: mimeType ?? this.mimeType,
      width: width ?? this.width,
      height: height ?? this.height,
      uploadState: uploadState ?? this.uploadState,
      downloadState: downloadState ?? this.downloadState,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? utcNow(),
      version: bumpVersion ? this.version + 1 : (version ?? this.version),
      deletedAt: clearDeletedAt ? null : (deletedAt ?? this.deletedAt),
      unreferencedAt: clearUnreferencedAt
          ? null
          : (unreferencedAt ?? this.unreferencedAt),
      failureReason: clearFailureReason
          ? null
          : (failureReason ?? this.failureReason),
    );
  }
}

/// One placement of a [MediaAsset] on a parent document.
///
/// References are what make an asset's lifetime refcount-based: the same blob
/// can hang off a journal entry and a todo task at once, and only when the
/// last live reference is gone does the asset start its retention clock.
///
/// This row *is* the placement: nothing about where an image sits is written
/// into the parent's prose, which is what lets sync, GC and the lightbox's
/// swipe order work without parsing text.
class MediaReference extends SoftDeletable {
  const MediaReference({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.version,
    super.deletedAt,
    required this.mediaId,
    required this.collection,
    required this.documentId,
    this.facet = MediaFacet.gallery,
    this.sortOrder = 0,
    this.displayWidthPx,
  });

  final String mediaId;

  /// The parent's Firestore collection name, e.g.
  /// `FirestoreCollections.todoTasks`.
  final String collection;
  final String documentId;
  final MediaFacet facet;

  /// Position within the parent's [facet]. Also the lightbox's swipe order.
  final int sortOrder;

  /// Display width for gallery items, where a surface offers one. Null
  /// everywhere the surface sizes the image itself.
  final int? displayWidthPx;

  MediaReference copyWith({
    String? mediaId,
    String? collection,
    String? documentId,
    MediaFacet? facet,
    int? sortOrder,
    int? displayWidthPx,
    bool clearDisplayWidthPx = false,
    DateTime? createdAt,
    DateTime? updatedAt,
    int? version,
    bool bumpVersion = false,
    DateTime? deletedAt,
    bool clearDeletedAt = false,
  }) {
    return MediaReference(
      id: id,
      mediaId: mediaId ?? this.mediaId,
      collection: collection ?? this.collection,
      documentId: documentId ?? this.documentId,
      facet: facet ?? this.facet,
      sortOrder: sortOrder ?? this.sortOrder,
      displayWidthPx: clearDisplayWidthPx
          ? null
          : (displayWidthPx ?? this.displayWidthPx),
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? utcNow(),
      version: bumpVersion ? this.version + 1 : (version ?? this.version),
      deletedAt: clearDeletedAt ? null : (deletedAt ?? this.deletedAt),
    );
  }
}

/// How much of the media cache is on disk, for the settings readout.
class MediaStorageUsage {
  const MediaStorageUsage({
    required this.assetCount,
    required this.byteSize,
    required this.pendingUploadCount,
    required this.pendingDownloadCount,
  });

  static const empty = MediaStorageUsage(
    assetCount: 0,
    byteSize: 0,
    pendingUploadCount: 0,
    pendingDownloadCount: 0,
  );

  final int assetCount;
  final int byteSize;
  final int pendingUploadCount;
  final int pendingDownloadCount;
}
