// The vendored vector_tile_renderer keeps a street name's rotated box as the
// space it occupies (VOYAGER PATCH in label_space.dart). These pin that a
// label beside a name at an angle is not blocked by the name's upright
// bounds, and that one on the name still is.

import 'dart:math';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
// ignore: implementation_imports
import 'package:vector_tile_renderer/src/features/label_space.dart';

void main() {
  // A 40 x 4 box centred on (50, 50), turned 45 degrees.
  List<Offset> diagonal() {
    const half = Offset(20, 2);
    final (c, s) = (cos(pi / 4), sin(pi / 4));
    return [
      for (final corner in [
        Offset(-half.dx, -half.dy),
        Offset(half.dx, -half.dy),
        Offset(half.dx, half.dy),
        Offset(-half.dx, half.dy),
      ])
        const Offset(50, 50) +
            Offset(
              corner.dx * c - corner.dy * s,
              corner.dx * s + corner.dy * c,
            ),
    ];
  }

  LabelSpace space() {
    final labels = LabelSpace(
      const Rect.fromLTWH(0, 0, 256, 256),
      zoomScaleFactor: 1,
    );
    labels.occupyQuad('Diagonal Lane', diagonal());
    return labels;
  }

  test('a label in the corner of an angled name\'s upright bounds fits', () {
    // Inside the diagonal's bounding box (about 35..65 each way), well off
    // the diagonal itself.
    expect(
      space().canOccupy('Cafe', const Rect.fromLTWH(56, 36, 8, 3)),
      isTrue,
    );
  });

  test('a label across an angled name is blocked', () {
    expect(
      space().canOccupy('Cafe', const Rect.fromLTWH(46, 48, 8, 3)),
      isFalse,
    );
  });

  test('the margin shrinks with an overzoomed tile', () {
    expect(
      LabelSpace(Rect.zero, zoomScaleFactor: 8).margin,
      LabelSpace(Rect.zero, zoomScaleFactor: 1).margin / 8,
    );
  });
}
