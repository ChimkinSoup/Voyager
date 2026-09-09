import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/media/widgets/media_image.dart';

void main() {
  group('mediaDecodeSize', () {
    test('a cover thumbnail decodes at the size it is painted', () {
      final size = mediaDecodeSize(
        sourceWidth: 2048,
        sourceHeight: 1271,
        boxWidth: 104,
        boxHeight: 104,
        devicePixelRatio: 2,
        fit: BoxFit.cover,
      );

      // Cover crops, so the short axis is what has to reach 104 * 2 physical
      // pixels; the long axis follows from the source's aspect ratio.
      expect(size, isNotNull);
      expect(size!.height, 208);
      expect(size.width, 335);
      expect(size.width / size.height, closeTo(2048 / 1271, 0.01));
    });

    test('contain fits inside the box', () {
      final size = mediaDecodeSize(
        sourceWidth: 2048,
        sourceHeight: 1271,
        boxWidth: 300,
        boxHeight: 100,
        devicePixelRatio: 1,
        fit: BoxFit.contain,
      );

      expect(size, isNotNull);
      expect(size!.height, 100);
      expect(size.width, 161);
    });

    test('never decodes above the source resolution', () {
      expect(
        mediaDecodeSize(
          sourceWidth: 64,
          sourceHeight: 64,
          boxWidth: 400,
          boxHeight: 400,
          devicePixelRatio: 2,
          fit: BoxFit.cover,
        ),
        isNull,
      );
    });

    test('cover with an unbounded axis keeps every pixel', () {
      expect(
        mediaDecodeSize(
          sourceWidth: 2048,
          sourceHeight: 1271,
          boxWidth: null,
          boxHeight: 104,
          devicePixelRatio: 2,
          fit: BoxFit.cover,
        ),
        isNull,
      );
    });

    test('a source with no recorded size keeps every pixel', () {
      expect(
        mediaDecodeSize(
          sourceWidth: 0,
          sourceHeight: 0,
          boxWidth: 104,
          boxHeight: 104,
          devicePixelRatio: 2,
          fit: BoxFit.cover,
        ),
        isNull,
      );
    });
  });
}
