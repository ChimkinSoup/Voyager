import 'dart:math';
import 'dart:ui';

// VOYAGER PATCH: occupied space is kept as quads, not rects, so a label
// drawn at an angle can occupy the rotated box it is drawn in — see
// [canOccupyQuad]. Upstream took a street name's upright bounding box, which
// on a grid at an angle covers most of the block beside it. Rects are
// occupied and tested as before.
//
// And the margin kept around a label shrinks with an overzoomed tile, as the
// text does, so it stays the same on screen. Upstream kept it in tile units,
// so at 16x overzoom it padded each label by 32-64 pixels.
//
// And with [repeats] a text may be placed more than once, for a space that
// spans many tiles — see LabelLayout. Upstream allowed each text once.
class LabelSpace {
  final Rect space;
  final double margin;
  final bool repeats;
  final List<_LabelQuad> _occupied = [];
  final Set<String> texts = {};

  LabelSpace(this.space, {required double zoomScaleFactor, this.repeats = false})
    : margin = zoomScaleFactor > 1.0 ? _margin / zoomScaleFactor : _margin;

  bool canAccept(String? text) =>
      text != null && text.isNotEmpty && (repeats || !texts.contains(text));

  bool canOccupy(String text, Rect rect) => canOccupyQuad(text, _corners(rect));

  /// [quad]: four corners of a convex box, in order around it.
  bool canOccupyQuad(String text, List<Offset> quad) {
    if (!canAccept(text)) return false;
    final bounds = quadBounds(quad);
    return space.containsCompletely(bounds) &&
        !_occupied.any(
          (existing) =>
              existing.bounds.overlaps(bounds) &&
              _overlaps(existing.corners, quad),
        );
  }

  void occupy(String text, Rect box) {
    final boxWithMargin = Rect.fromLTRB(
      box.left - margin,
      box.top - margin,
      box.right + (2 * margin),
      box.bottom + (2 * margin),
    );
    _occupy(text, _corners(boxWithMargin));
  }

  /// [quad] as [canOccupyQuad] takes it, already including any margin.
  void occupyQuad(String text, List<Offset> quad) => _occupy(text, quad);

  void _occupy(String text, List<Offset> corners) {
    _occupied.add(_LabelQuad(text, corners, quadBounds(corners)));
    texts.add(text);
  }
}

List<Offset> _corners(Rect rect) => [
  rect.topLeft,
  rect.topRight,
  rect.bottomRight,
  rect.bottomLeft,
];

Rect quadBounds(List<Offset> corners) {
  final xs = corners.map((c) => c.dx);
  final ys = corners.map((c) => c.dy);
  return Rect.fromLTRB(
    xs.reduce(min),
    ys.reduce(min),
    xs.reduce(max),
    ys.reduce(max),
  );
}

/// Separating axis test for two convex quads: they are apart if their
/// shadows on some edge's normal do not meet. Touching is not overlapping,
/// as with [Rect.overlaps].
bool _overlaps(List<Offset> a, List<Offset> b) {
  for (final quad in [a, b]) {
    for (var i = 0; i < quad.length; i++) {
      final edge = quad[(i + 1) % quad.length] - quad[i];
      final normal = Offset(-edge.dy, edge.dx);
      double project(Offset p) => p.dx * normal.dx + p.dy * normal.dy;
      final pa = a.map(project);
      final pb = b.map(project);
      if (pa.reduce(max) <= pb.reduce(min) ||
          pb.reduce(max) <= pa.reduce(min)) {
        return false;
      }
    }
  }
  return true;
}

extension _RectExtension on Rect {
  bool containsCompletely(Rect other) =>
      contains(other.topLeft) && contains(other.bottomRight);
}

const _margin = 2.0;

class _LabelQuad {
  final String text;
  final List<Offset> corners;
  final Rect bounds;
  _LabelQuad(this.text, this.corners, this.bounds);
}
