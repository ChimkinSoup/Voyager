import 'package:voyager/core/soft_delete/erasure.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/domain/models/photo_series_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';

/// Puts back what two devices' saves, each sound on its own, break together
/// once the merge has decided each row alone (PHOTO_SERIES_HLD.md §14):
///
/// - A live series left with no live angle — each device removed a different
///   one — gets back the angle removed last, with the photos removed with it
///   (BUG-308).
/// - A live angle of a series pulled removed goes under the series' stamp:
///   one put back above before the series' own removal was heard of, or
///   added while another device removed the series.
/// - A live photo on a removed angle — saved into it while another device
///   removed it — goes, under the angle's stamp, so restoring the angle
///   brings it back (BUG-307).
/// - Two live photos of one check-in's angle — both devices replaced it — keep
///   the newer (BUG-306).
/// - A live check-in left with no live photo — deleted on one device, edited
///   on another — gets back the photos deleted last, so it is kept whole as
///   the later save had it (BUG-311).
/// - A live photo of a check-in pulled deleted goes under the check-in's
///   stamp: one put back above before the check-in's own delete was heard of.
///
/// Every device reaches the same rows from the same rows, so they agree
/// without asking each other. With none of the ids, everything is looked at.
/// With some, only what a pull brought: [seriesIds] the series pulled,
/// [angleIds] the angles, [checkInIds] the check-ins, and [imageCheckInIds]
/// the check-ins of the photos pulled, [newImageIds] those new to this
/// device. A photo on a removed angle then goes only when it or its angle was
/// pulled, and a child under a removed parent only when the parent was: a
/// restore from the trash may bring a child back before its parent.
/// Returns how many rows it wrote.
Future<int> settlePhotoSeries(
  PhotoSeriesRepository photos, {
  Set<String>? seriesIds,
  Set<String>? angleIds,
  Set<String>? checkInIds,
  Set<String>? imageCheckInIds,
  Set<String> newImageIds = const {},
}) async {
  final all =
      seriesIds == null &&
      angleIds == null &&
      checkInIds == null &&
      imageCheckInIds == null;
  final now = utcNow();
  final angles = {
    for (final angle in await photos.listAngles(includeDeleted: true))
      angle.id: angle,
  };
  // Series whose angles were pulled, for the first rule.
  final angleSeries = {
    for (final id in angleIds ?? const <String>{})
      if (angles[id] case final angle?) angle.seriesId,
  };
  final scopeSeries = {...?seriesIds, ...angleSeries};
  final scopeCheckIns = {...?checkInIds, ...?imageCheckInIds};
  final images = all
      ? await photos.listImages(includeDeleted: true)
      : {
          for (final image in [
            ...await photos.listImagesOf(scopeCheckIns),
            ...await photos.listImagesOn({
              for (final angle in angles.values)
                if (scopeSeries.contains(angle.seriesId)) angle.id,
            }),
          ])
            image.id: image,
        }.values.toList();
  final changedAngles = <String, PhotoSeriesAngle>{};
  final changedImages = <String, PhotoCheckInImage>{};
  PhotoCheckInImage current(PhotoCheckInImage image) =>
      changedImages[image.id] ?? image;
  bool live(PhotoSeriesAngle? angle) =>
      angle != null && (changedAngles[angle.id] ?? angle).deletedAt == null;

  final bySeries = <String, List<PhotoSeriesAngle>>{};
  for (final angle in angles.values) {
    (bySeries[angle.seriesId] ??= []).add(angle);
  }
  final seriesList = all
      ? await photos.listSeries()
      : [for (final id in scopeSeries) ?await photos.getSeries(id)];
  for (final series in seriesList) {
    final own = bySeries[series.id] ?? const [];
    if (series.deletedAt case final deletedAt?) {
      if (isErasedAt(deletedAt) || !(seriesIds?.contains(series.id) ?? false)) {
        continue;
      }
      for (final angle in own) {
        if (angle.deletedAt == null) {
          changedAngles[angle.id] = angle.copyWith(
            deletedAt: deletedAt,
            bumpVersion: true,
          );
        }
      }
      continue;
    }
    if (!all && !angleSeries.contains(series.id)) continue;
    if (own.any((angle) => angle.deletedAt == null)) continue;
    final removed = [
      for (final angle in own)
        if (!isErasedAt(angle.deletedAt)) angle,
    ];
    if (removed.isEmpty) continue;
    final last = removed.reduce(
      (a, b) =>
          _laterFirst(a.deletedAt!, a.id, b.deletedAt!, b.id) <= 0 ? a : b,
    );
    changedAngles[last.id] = last.copyWith(
      clearDeletedAt: true,
      bumpVersion: true,
    );
    for (final image in images) {
      if (image.angleId == last.id &&
          (image.deletedAt?.isAtSameMomentAs(last.deletedAt!) ?? false)) {
        changedImages[image.id] = image.copyWith(
          clearDeletedAt: true,
          bumpVersion: true,
        );
      }
    }
  }

  final shown = <String, List<PhotoCheckInImage>>{};
  for (final image in images.map(current)) {
    if (image.deletedAt != null) continue;
    final angle = changedAngles[image.angleId] ?? angles[image.angleId];
    // Not yet here: nothing to go by.
    if (angle == null) continue;
    if (!live(angle)) {
      if (all ||
          newImageIds.contains(image.id) ||
          (angleIds?.contains(angle.id) ?? false) ||
          changedAngles.containsKey(angle.id)) {
        changedImages[image.id] = image.copyWith(
          deletedAt: angle.deletedAt,
          bumpVersion: true,
        );
      }
      continue;
    }
    (shown['${image.checkInId}|${image.angleId}'] ??= []).add(image);
  }
  for (final both in shown.values) {
    if (both.length < 2) continue;
    both.sort((a, b) => _laterFirst(a.createdAt, a.id, b.createdAt, b.id));
    final kept = both.first;
    for (final image in both.skip(1)) {
      changedImages[image.id] = image.copyWith(
        deletedAt: now,
        bumpVersion: true,
      );
      final angle = changedAngles[image.angleId] ?? angles[image.angleId]!;
      if (angle.referenceImageId == image.id) {
        changedAngles[angle.id] = angle.copyWith(
          referenceImageId: kept.id,
          bumpVersion: true,
        );
      }
    }
  }

  final byCheckIn = <String, List<PhotoCheckInImage>>{};
  for (final image in images.map(current)) {
    (byCheckIn[image.checkInId] ??= []).add(image);
  }
  final checkIns = all
      ? await photos.listCheckIns()
      : [for (final id in scopeCheckIns) ?await photos.getCheckIn(id)];
  for (final checkIn in checkIns) {
    final own = byCheckIn[checkIn.id] ?? const [];
    if (checkIn.deletedAt case final deletedAt?) {
      if (isErasedAt(deletedAt) ||
          !(checkInIds?.contains(checkIn.id) ?? false)) {
        continue;
      }
      for (final image in own) {
        if (image.deletedAt == null) {
          changedImages[image.id] = image.copyWith(
            deletedAt: deletedAt,
            bumpVersion: true,
          );
        }
      }
      continue;
    }
    if (own.any((image) => image.deletedAt == null)) continue;
    final restorable = [
      for (final image in own)
        if (!isErasedAt(image.deletedAt) && live(angles[image.angleId])) image,
    ];
    if (restorable.isEmpty) continue;
    final stamp = restorable
        .map((image) => image.deletedAt!)
        .reduce((a, b) => a.isAfter(b) ? a : b);
    for (final image in restorable) {
      if (image.deletedAt!.isAtSameMomentAs(stamp)) {
        changedImages[image.id] = image.copyWith(
          clearDeletedAt: true,
          bumpVersion: true,
        );
      }
    }
  }

  if (changedAngles.isEmpty && changedImages.isEmpty) return 0;
  await photos.saveAll(
    angles: changedAngles.values.toList(),
    images: changedImages.values.toList(),
  );
  return changedAngles.length + changedImages.length;
}

/// Orders the later of two stamps first, the greater id on a tie.
int _laterFirst(DateTime a, String aId, DateTime b, String bId) {
  final byTime = b.compareTo(a);
  return byTime != 0 ? byTime : bId.compareTo(aId);
}
