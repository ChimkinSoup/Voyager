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
  /// named [kDefaultPhotoAngleName] when none are given.
  Future<PhotoSeries> createSeries({
    required String name,
    required TrackerCadence cadence,
    required int sortOrder,
    List<String> angleNames = const [],
  }) async {
    final now = utcNow();
    final series = PhotoSeries(
      id: newId(),
      name: name.trim(),
      cadence: cadence,
      reminderMonth: now.toLocal().month,
      sortOrder: sortOrder,
      createdAt: now,
      updatedAt: now,
    );
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
    final images = <PhotoCheckInImage>[];
    final angles = <PhotoSeriesAngle>[];
    for (final MapEntry(key: angleId, value: bytes) in photos.entries) {
      final (image, angle) = await _ingest(session, checkIn.id, angleId, bytes);
      images.add(image);
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
    final (image, angle) = await _ingest(session, checkIn.id, angleId, bytes);
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
  ) async {
    final blob = await _media.ingest(
      bytes,
      key: session.key,
      vaultId: session.vaultId,
    );
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
