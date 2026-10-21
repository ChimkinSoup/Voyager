import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/domain/models/enums.dart';
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

/// The calendar date a stored [PhotoCheckIn.takenOn] names. Stored as UTC
/// midnight of that date, so every time zone reads back the same day.
DateTime photoCalendarDate(DateTime stored) {
  final utc = stored.toUtc();
  return DateTime(utc.year, utc.month, utc.day);
}

/// [date]'s calendar day in the form [photoCalendarDate] reads.
DateTime photoStoredDate(DateTime date) =>
    DateTime.utc(date.year, date.month, date.day);

/// How a series' grid hides a photo until it's clicked (§7.1).
enum PhotoHideStyle { blur, blank }

/// A recurring photo series (PHOTO_SERIES_HLD.md §5.1). Everything here is
/// plain, so the series list, its stats and its reminders work while the
/// vault is locked.
class PhotoSeries extends SoftDeletable {
  const PhotoSeries({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.version,
    super.deletedAt,
    required this.name,
    this.cadence = TrackerCadence.weekly,
    this.reminderEnabled = true,
    this.reminderMinutes = 9 * 60,
    this.reminderWeekday = DateTime.monday,
    this.reminderMonthDay = 1,
    this.reminderMonth = 1,
    this.playbackFps = 4,
    this.hideStyle = PhotoHideStyle.blur,
    this.sortOrder = 0,
  });

  final String name;
  final TrackerCadence cadence;
  final bool reminderEnabled;

  /// Minutes after local midnight.
  final int reminderMinutes;

  /// Weekly only, 1–7.
  final int reminderWeekday;

  /// Monthly and yearly, 1–31, clamped to the month's length.
  final int reminderMonthDay;

  /// Yearly only, 1–12.
  final int reminderMonth;

  /// The playback speed last used.
  final int playbackFps;
  final PhotoHideStyle hideStyle;
  final int sortOrder;

  PhotoSeries copyWith({
    String? name,
    TrackerCadence? cadence,
    bool? reminderEnabled,
    int? reminderMinutes,
    int? reminderWeekday,
    int? reminderMonthDay,
    int? reminderMonth,
    int? playbackFps,
    PhotoHideStyle? hideStyle,
    int? sortOrder,
    DateTime? updatedAt,
    bool bumpVersion = false,
    DateTime? deletedAt,
    bool clearDeletedAt = false,
  }) {
    return PhotoSeries(
      id: id,
      name: name ?? this.name,
      cadence: cadence ?? this.cadence,
      reminderEnabled: reminderEnabled ?? this.reminderEnabled,
      reminderMinutes: reminderMinutes ?? this.reminderMinutes,
      reminderWeekday: reminderWeekday ?? this.reminderWeekday,
      reminderMonthDay: reminderMonthDay ?? this.reminderMonthDay,
      reminderMonth: reminderMonth ?? this.reminderMonth,
      playbackFps: playbackFps ?? this.playbackFps,
      hideStyle: hideStyle ?? this.hideStyle,
      sortOrder: sortOrder ?? this.sortOrder,
      createdAt: createdAt,
      updatedAt: updatedAt ?? utcNow(),
      version: bumpVersion ? version + 1 : version,
      deletedAt: clearDeletedAt ? null : (deletedAt ?? this.deletedAt),
    );
  }
}

/// One of a series' angles — "Front", "Side" (§5.2).
class PhotoSeriesAngle extends SoftDeletable {
  const PhotoSeriesAngle({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.version,
    super.deletedAt,
    required this.seriesId,
    required this.name,
    this.sortOrder = 0,
    this.referenceImageId,
    this.frameAspect,
  });

  final String seriesId;
  final String name;
  final int sortOrder;

  /// The image the alignment editor draws underneath. Null means the angle's
  /// first photo.
  final String? referenceImageId;

  /// Width ÷ height of the angle's reference frame, set from its first photo
  /// and never changed. Null until it has one.
  final double? frameAspect;

  PhotoSeriesAngle copyWith({
    String? name,
    int? sortOrder,
    String? referenceImageId,
    double? frameAspect,
    DateTime? updatedAt,
    bool bumpVersion = false,
    DateTime? deletedAt,
    bool clearDeletedAt = false,
  }) {
    return PhotoSeriesAngle(
      id: id,
      seriesId: seriesId,
      name: name ?? this.name,
      sortOrder: sortOrder ?? this.sortOrder,
      referenceImageId: referenceImageId ?? this.referenceImageId,
      frameAspect: frameAspect ?? this.frameAspect,
      createdAt: createdAt,
      updatedAt: updatedAt ?? utcNow(),
      version: bumpVersion ? version + 1 : version,
      deletedAt: clearDeletedAt ? null : (deletedAt ?? this.deletedAt),
    );
  }
}

/// One check-in: a date, an optional sealed note, and one image per angle
/// (§5.3). Several can share a period.
class PhotoCheckIn extends SoftDeletable {
  const PhotoCheckIn({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.version,
    super.deletedAt,
    required this.seriesId,
    required this.takenOn,
    this.noteCiphertext,
    this.noteNonce,
    this.vaultId,
  });

  final String seriesId;

  /// The local calendar date, at midnight.
  final DateTime takenOn;

  /// Base64, as on a Secure Note. Null when there is no note.
  final String? noteCiphertext;
  final String? noteNonce;

  /// The vault the note was sealed under.
  final String? vaultId;

  bool get hasNote => noteCiphertext != null;

  PhotoCheckIn copyWith({
    DateTime? takenOn,
    ({String ciphertext, String nonce, String vaultId})? note,
    bool clearNote = false,
    DateTime? updatedAt,
    int? version,
    bool bumpVersion = false,
    DateTime? deletedAt,
    bool clearDeletedAt = false,
  }) {
    return PhotoCheckIn(
      id: id,
      seriesId: seriesId,
      takenOn: takenOn ?? this.takenOn,
      noteCiphertext: clearNote ? null : (note?.ciphertext ?? noteCiphertext),
      noteNonce: clearNote ? null : (note?.nonce ?? noteNonce),
      vaultId: clearNote ? null : (note?.vaultId ?? vaultId),
      createdAt: createdAt,
      updatedAt: updatedAt ?? utcNow(),
      version: bumpVersion ? this.version + 1 : (version ?? this.version),
      deletedAt: clearDeletedAt ? null : (deletedAt ?? this.deletedAt),
    );
  }
}

/// A check-in's photo of one angle (§5.4). At most one live per check-in and
/// angle; replacing one tombstones the old.
class PhotoCheckInImage extends SoftDeletable {
  const PhotoCheckInImage({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.version,
    super.deletedAt,
    required this.checkInId,
    required this.angleId,
    required this.blobId,
    this.alignScale = 1,
    this.alignRotation = 0,
    this.alignDx = 0,
    this.alignDy = 0,
  });

  final String checkInId;
  final String angleId;

  /// → [VaultBlob].
  final String blobId;

  /// The non-destructive transform onto the angle's frame (§10). Offsets are
  /// fractions of the frame's size; rotation is in radians.
  final double alignScale;
  final double alignRotation;
  final double alignDx;
  final double alignDy;

  PhotoCheckInImage copyWith({
    double? alignScale,
    double? alignRotation,
    double? alignDx,
    double? alignDy,
    DateTime? updatedAt,
    int? version,
    bool bumpVersion = false,
    DateTime? deletedAt,
    bool clearDeletedAt = false,
  }) {
    return PhotoCheckInImage(
      id: id,
      checkInId: checkInId,
      angleId: angleId,
      blobId: blobId,
      alignScale: alignScale ?? this.alignScale,
      alignRotation: alignRotation ?? this.alignRotation,
      alignDx: alignDx ?? this.alignDx,
      alignDy: alignDy ?? this.alignDy,
      createdAt: createdAt,
      updatedAt: updatedAt ?? utcNow(),
      version: bumpVersion ? this.version + 1 : (version ?? this.version),
      deletedAt: clearDeletedAt ? null : (deletedAt ?? this.deletedAt),
    );
  }
}

/// Every live series, angle, check-in and image, read together so a page
/// never sees a check-in without its series.
class PhotoSeriesSnapshot {
  const PhotoSeriesSnapshot({
    this.series = const [],
    this.angles = const [],
    this.checkIns = const [],
    this.images = const [],
  });

  static const empty = PhotoSeriesSnapshot();

  final List<PhotoSeries> series;
  final List<PhotoSeriesAngle> angles;
  final List<PhotoCheckIn> checkIns;
  final List<PhotoCheckInImage> images;
}
