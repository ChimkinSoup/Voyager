// The capture screen's pure parts: which photo the ghost shows, and the
// camera's temp file going before its bytes are used (PHOTO_SERIES_HLD.md §9,
// §6.3).

import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/photo_series_models.dart';
import 'package:voyager/features/photo_series/photo_capture_screen.dart';

final _stamp = DateTime.utc(2026, 10, 1);

PhotoCheckIn _checkIn(String id, DateTime takenOn, {DateTime? createdAt}) =>
    PhotoCheckIn(
      id: id,
      seriesId: 's',
      takenOn: takenOn,
      createdAt: createdAt ?? _stamp,
      updatedAt: _stamp,
    );

PhotoCheckInImage _image(String id, String checkInId, String angleId) =>
    PhotoCheckInImage(
      id: id,
      checkInId: checkInId,
      angleId: angleId,
      blobId: 'blob-$id',
      createdAt: _stamp,
      updatedAt: _stamp,
    );

PhotoSeriesAngle _angle({String? referenceImageId}) => PhotoSeriesAngle(
  id: 'front',
  seriesId: 's',
  name: 'Front',
  referenceImageId: referenceImageId,
  createdAt: _stamp,
  updatedAt: _stamp,
);

void main() {
  final snapshot = PhotoSeriesSnapshot(
    series: const [],
    angles: [_angle()],
    checkIns: [
      _checkIn('late', DateTime(2026, 10, 9)),
      _checkIn('early', DateTime(2026, 10, 2)),
      // The same day as `late`, made after it.
      _checkIn(
        'later',
        DateTime(2026, 10, 9),
        createdAt: _stamp.add(const Duration(hours: 1)),
      ),
    ],
    images: [
      _image('i-late', 'late', 'front'),
      _image('i-early', 'early', 'front'),
      _image('i-later', 'later', 'front'),
      _image('i-side', 'late', 'side'),
      // Its check-in is gone.
      _image('i-orphan', 'deleted', 'front'),
    ],
  );

  test("an angle's photos run oldest first, by date then by creation", () {
    expect(
      [for (final frame in photoAngleFrames(snapshot, 'front')) frame.image.id],
      ['i-early', 'i-late', 'i-later'],
    );
  });

  test('the ghost is the latest photo, or the reference when asked', () {
    final frames = photoAngleFrames(snapshot, 'front');

    expect(
      photoGhostFrame(_angle(), frames, reference: false)?.image.id,
      'i-later',
    );
    // No reference chosen: the angle's first photo.
    expect(
      photoGhostFrame(_angle(), frames, reference: true)?.image.id,
      'i-early',
    );
    expect(
      photoGhostFrame(
        _angle(referenceImageId: 'i-late'),
        frames,
        reference: true,
      )?.image.id,
      'i-late',
    );
    // An angle's first photo has nothing to line up against.
    expect(photoGhostFrame(_angle(), const [], reference: false), isNull);
    expect(photoGhostFrame(_angle(), const [], reference: true), isNull);
  });

  test("a capture's temp file is gone once its bytes are read", () async {
    final dir = await Directory.systemTemp.createTemp('voyager_capture');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/CAP0001.jpg');
    await file.writeAsBytes([0xFF, 0xD8, 0xFF, 0xD9]);

    final bytes = await takeCapturedPhoto(XFile(file.path));

    expect(bytes, Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]));
    expect(file.existsSync(), isFalse);
    expect(dir.listSync(), isEmpty);
  });
}
