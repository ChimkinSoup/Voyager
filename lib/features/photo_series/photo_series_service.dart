import 'dart:convert';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:voyager/core/secure_vault/secure_vault.dart';
import 'package:voyager/core/secure_vault/vault_media_service.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/photo_series_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/features/notifications/secure_vault_session.dart';

/// The name a new series' one angle starts with (PHOTO_SERIES_HLD.md §18).
const kDefaultPhotoAngleName = 'Photo';

/// A series' reminder fields (PHOTO_SERIES_HLD.md §5.1), as the series dialog
/// edits them.
typedef PhotoReminderSettings = ({
  bool enabled,
  int minutes,
  int weekday,
  int monthDay,
  int month,
});

extension PhotoSeriesReminder on PhotoSeries {
  PhotoReminderSettings get reminder => (
    enabled: reminderEnabled,
    minutes: reminderMinutes,
    weekday: reminderWeekday,
    monthDay: reminderMonthDay,
    month: reminderMonth,
  );

  PhotoSeries withReminder(PhotoReminderSettings reminder) => copyWith(
    reminderEnabled: reminder.enabled,
    reminderMinutes: reminder.minutes,
    reminderWeekday: reminder.weekday,
    reminderMonthDay: reminder.monthDay,
    reminderMonth: reminder.month,
  );
}

/// Thrown for a change the series can't take, with a message for the user.
class PhotoSeriesException implements Exception {
  const PhotoSeriesException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Writes Photo Series' rows: series, angles, check-ins and their photos.
/// Photos go through [VaultMediaService], sealed before anything is stored;
/// notes are sealed here.
class PhotoSeriesService {
  PhotoSeriesService({required this._repository, required this._media});

  final PhotoSeriesRepository _repository;
  final VaultMediaService _media;

  /// A new series with [angleNames] as its angles, in that order — one
  /// named [kDefaultPhotoAngleName] when none are given — reminding as
  /// [reminder] says, or by the defaults without one.
  Future<PhotoSeries> createSeries({
    required String name,
    required TrackerCadence cadence,
    required int sortOrder,
    List<String> angleNames = const [],
    PhotoReminderSettings? reminder,
  }) async {
    final now = utcNow();
    var series = PhotoSeries(
      id: newId(),
      name: name.trim(),
      cadence: cadence,
      reminderMonth: now.toLocal().month,
      sortOrder: sortOrder,
      createdAt: now,
      updatedAt: now,
    );
    if (reminder != null) series = series.withReminder(reminder);
    await _repository.saveAll(
      series: [series],
      angles: [
        for (final (i, angleName)
            in (angleNames.isEmpty
                    ? const [kDefaultPhotoAngleName]
                    : angleNames)
                .indexed)
          PhotoSeriesAngle(
            id: newId(),
            seriesId: series.id,
            name: angleName.trim().isEmpty
                ? 'Angle ${i + 1}'
                : angleName.trim(),
            sortOrder: i,
            createdAt: now,
            updatedAt: now,
          ),
      ],
    );
    return series;
  }

  Future<void> updateSeries(PhotoSeries series) =>
      _repository.upsertSeries(series.copyWith(bumpVersion: true));

  /// Writes the series' angles as [names] lists them, in that order: an
  /// entry with an id renames and moves that angle, one without adds a new
  /// angle, and a live angle left out is removed with its photos. At least
  /// one has to stay.
  Future<void> saveAngles(
    PhotoSeries series,
    List<({String? id, String name})> names,
  ) async {
    if (names.isEmpty) {
      throw const PhotoSeriesException('A series needs at least one angle.');
    }
    final now = utcNow();
    final live = {
      for (final angle in await _repository.listAngles())
        if (angle.seriesId == series.id) angle.id: angle,
    };
    final kept = {for (final entry in names) ?entry.id};
    final angles = <PhotoSeriesAngle>[];
    for (final (i, entry) in names.indexed) {
      final name = entry.name.trim().isEmpty ? 'Angle ${i + 1}' : entry.name;
      final existing = live[entry.id];
      if (existing == null) {
        angles.add(
          PhotoSeriesAngle(
            id: newId(),
            seriesId: series.id,
            name: name.trim(),
            sortOrder: i,
            createdAt: now,
            updatedAt: now,
          ),
        );
      } else if (existing.name != name.trim() || existing.sortOrder != i) {
        angles.add(
          existing.copyWith(name: name.trim(), sortOrder: i, bumpVersion: true),
        );
      }
    }
    final removed = [
      for (final angle in live.values)
        if (!kept.contains(angle.id))
          angle.copyWith(deletedAt: now, bumpVersion: true),
    ];
    final removedIds = {for (final angle in removed) angle.id};
    final images = [
      for (final image in await _repository.listImages())
        if (removedIds.contains(image.angleId))
          image.copyWith(deletedAt: now, bumpVersion: true),
    ];
    await _repository.saveAll(angles: [...angles, ...removed], images: images);
  }

  /// Deletes [series] with its angles, check-ins and their photos, under one
  /// stamp so the trash brings them back together.
  Future<void> deleteSeries(PhotoSeries series) async {
    final now = utcNow();
    final snapshot = await _repository.loadSnapshot();
    final checkIns = [
      for (final checkIn in snapshot.checkIns)
        if (checkIn.seriesId == series.id) checkIn,
    ];
    final checkInIds = {for (final checkIn in checkIns) checkIn.id};
    await _repository.saveAll(
      series: [series.copyWith(deletedAt: now, bumpVersion: true)],
      angles: [
        for (final angle in snapshot.angles)
          if (angle.seriesId == series.id)
            angle.copyWith(deletedAt: now, bumpVersion: true),
      ],
      checkIns: [
        for (final checkIn in checkIns)
          checkIn.copyWith(deletedAt: now, bumpVersion: true),
      ],
      images: [
        for (final image in snapshot.images)
          if (checkInIds.contains(image.checkInId))
            image.copyWith(deletedAt: now, bumpVersion: true),
      ],
    );
  }

  /// A new check-in of [series] on [takenOn], with one photo per angle in
  /// [photos] and an optional [note]. Refuses one with no photo.
  Future<PhotoCheckIn> createCheckIn({
    required SecureVaultSession session,
    required PhotoSeries series,
    required DateTime takenOn,
    required Map<String, Uint8List> photos,
    String note = '',
  }) async {
    // An angle removed on another device while the dialog was open takes no
    // photo: it would be live on an angle nothing shows (BUG-307).
    final live = {
      for (final angle in await _repository.listAngles())
        if (angle.seriesId == series.id) angle.id,
    };
    photos = {
      for (final MapEntry(key: angleId, value: bytes) in photos.entries)
        if (live.contains(angleId)) angleId: bytes,
    };
    if (photos.isEmpty) {
      throw const PhotoSeriesException('Add at least one photo.');
    }
    final now = utcNow();
    var checkIn = PhotoCheckIn(
      id: newId(),
      seriesId: series.id,
      takenOn: DateTime(takenOn.year, takenOn.month, takenOn.day),
      createdAt: now,
      updatedAt: now,
    );
    if (note.trim().isNotEmpty) {
      checkIn = checkIn.copyWith(
        note: await _seal(session, note.trim()),
        updatedAt: now,
      );
    }
    // Every photo sealed before any is stored: one that can't be read
    // would otherwise strand the others' blobs. Sealed side by side: each
    // decodes in its own isolate.
    final sealed = await Future.wait([
      for (final MapEntry(key: angleId, value: bytes) in photos.entries)
        _media
            .seal(bytes, key: session.key, vaultId: session.vaultId)
            .then((image) => (angleId, image)),
    ]);
    final images = <PhotoCheckInImage>[];
    final angles = <PhotoSeriesAngle>[];
    for (final (angleId, image) in sealed) {
      final (row, angle) = await _store(checkIn.id, angleId, image);
      images.add(row);
      if (angle != null) angles.add(angle);
    }
    await _repository.saveAll(
      angles: angles,
      checkIns: [checkIn],
      images: images,
    );
    return checkIn;
  }

  /// Gives [checkIn] [bytes] as its photo of [angleId], replacing any it had.
  /// A replaced reference hands the role to the new photo.
  Future<void> setPhoto({
    required SecureVaultSession session,
    required PhotoCheckIn checkIn,
    required String angleId,
    required Uint8List bytes,
  }) async {
    final now = utcNow();
    final replaced = [
      for (final image in await _repository.listImages())
        if (image.checkInId == checkIn.id && image.angleId == angleId)
          image.copyWith(deletedAt: now, bumpVersion: true),
    ];
    var (image, angle) = await _ingest(session, checkIn.id, angleId, bytes);
    final current = angle ?? await _repository.getAngle(angleId);
    if (current != null &&
        replaced.any((old) => old.id == current.referenceImageId)) {
      angle = current.copyWith(referenceImageId: image.id, bumpVersion: true);
    }
    await _repository.saveAll(angles: [?angle], images: [...replaced, image]);
  }

  Future<void> setDate(PhotoCheckIn checkIn, DateTime takenOn) =>
      _repository.upsertCheckIn(
        checkIn.copyWith(
          takenOn: DateTime(takenOn.year, takenOn.month, takenOn.day),
          bumpVersion: true,
        ),
      );

  /// Seals [text] as [checkIn]'s note; empty clears it.
  Future<void> setNote(
    SecureVaultSession session,
    PhotoCheckIn checkIn,
    String text,
  ) async {
    final trimmed = text.trim();
    await _repository.upsertCheckIn(
      trimmed.isEmpty
          ? checkIn.copyWith(clearNote: true, bumpVersion: true)
          : checkIn.copyWith(
              note: await _seal(session, trimmed),
              bumpVersion: true,
            ),
    );
  }

  /// Gives the image [aligned] names its transform (PHOTO_SERIES_HLD.md
  /// §10), onto the row as it stands now.
  Future<void> setAlignment(PhotoCheckInImage aligned) async {
    final image = await _repository.getImage(aligned.id);
    if (image == null || image.deletedAt != null) return;
    await _repository.upsertImage(
      image.copyWith(
        alignScale: aligned.alignScale,
        alignRotation: aligned.alignRotation,
        alignDx: aligned.alignDx,
        alignDy: aligned.alignDy,
        bumpVersion: true,
      ),
    );
  }

  /// Makes [image] the one its angle's alignment editor draws underneath.
  /// Moves nothing: transforms and the frame stay as they are.
  Future<void> setReference(PhotoCheckInImage image) async {
    final angle = await _repository.getAngle(image.angleId);
    if (angle == null || angle.referenceImageId == image.id) return;
    await _repository.upsertAngle(
      angle.copyWith(referenceImageId: image.id, bumpVersion: true),
    );
  }

  /// [checkIn]'s note, opened under [session]. Null when it has none, or it
  /// was sealed under another vault, or doesn't open.
  static Future<String?> openNote(
    SecureVaultSession session,
    PhotoCheckIn checkIn,
  ) async {
    final ciphertext = checkIn.noteCiphertext;
    final nonce = checkIn.noteNonce;
    if (ciphertext == null || nonce == null) return null;
    if (checkIn.vaultId != session.vaultId) return null;
    try {
      return await SecureVault.decrypt(
        session.key,
        session.vaultId,
        SecureBox(
          ciphertext: base64Decode(ciphertext),
          nonce: base64Decode(nonce),
        ),
      );
    } on SecureVaultTamperedException {
      return null;
    } on FormatException {
      return null;
    } on ArgumentError {
      return null;
    }
  }

  /// Deletes [checkIn] and its photos under one stamp, which it returns for
  /// [restoreCheckIn].
  Future<DateTime> deleteCheckIn(PhotoCheckIn checkIn) async {
    final now = utcNow();
    await _repository.saveAll(
      checkIns: [checkIn.copyWith(deletedAt: now, bumpVersion: true)],
      images: [
        for (final image in await _repository.listImages())
          if (image.checkInId == checkIn.id)
            image.copyWith(deletedAt: now, bumpVersion: true),
      ],
    );
    return now;
  }

  /// Undoes [deleteCheckIn]: the check-in and the photos it took, by [stamp].
  Future<void> restoreCheckIn(String id, DateTime stamp) async {
    final checkIn = await _repository.getCheckIn(id);
    final deletedAt = checkIn?.deletedAt;
    if (deletedAt == null || !deletedAt.isAtSameMomentAs(stamp)) return;
    await _repository.saveAll(
      checkIns: [checkIn!.copyWith(clearDeletedAt: true, bumpVersion: true)],
      images: [
        for (final image in await _repository.listImages(includeDeleted: true))
          if (image.checkInId == id &&
              (image.deletedAt?.isAtSameMomentAs(stamp) ?? false))
            image.copyWith(clearDeletedAt: true, bumpVersion: true),
      ],
    );
  }

  Future<({String ciphertext, String nonce, String vaultId})> _seal(
    SecureVaultSession session,
    String text,
  ) async {
    final sealed = await sealSecureText(session, text);
    return (
      ciphertext: sealed.ciphertext,
      nonce: sealed.nonce,
      vaultId: session.vaultId,
    );
  }

  /// Seals [bytes] as a blob and makes the image row showing it. The angle
  /// comes back too when this is its first photo, which fixes its frame.
  Future<(PhotoCheckInImage, PhotoSeriesAngle?)> _ingest(
    SecureVaultSession session,
    String checkInId,
    String angleId,
    Uint8List bytes,
  ) async => _store(
    checkInId,
    angleId,
    await _media.seal(bytes, key: session.key, vaultId: session.vaultId),
  );

  Future<(PhotoCheckInImage, PhotoSeriesAngle?)> _store(
    String checkInId,
    String angleId,
    SealedVaultImage sealed,
  ) async {
    final blob = await _media.store(sealed);
    final now = utcNow();
    final image = PhotoCheckInImage(
      id: newId(),
      checkInId: checkInId,
      angleId: angleId,
      blobId: blob.id,
      createdAt: now,
      updatedAt: now,
    );
    final angle = await _repository.getAngle(angleId);
    if (angle == null || angle.frameAspect != null || blob.height == 0) {
      return (image, null);
    }
    return (
      image,
      angle.copyWith(frameAspect: blob.width / blob.height, bumpVersion: true),
    );
  }
}

/// When a photo was taken, from its EXIF `DateTimeOriginal`. Null when it
/// has none, or isn't a JPEG.
DateTime? photoTakenOnFromExif(Uint8List bytes) {
  try {
    final exif = img.decodeJpgExif(bytes);
    final raw = exif?.exifIfd.data[0x9003]?.toString().trim();
    if (raw == null) return null;
    // "2026:10:18 09:15:00".
    final match = RegExp(r'^(\d{4}):(\d{2}):(\d{2})').firstMatch(raw);
    if (match == null) return null;
    final date = DateTime(
      int.parse(match[1]!),
      int.parse(match[2]!),
      int.parse(match[3]!),
    );
    return date.year < 1900 ? null : date;
  } catch (_) {
    return null;
  }
}
