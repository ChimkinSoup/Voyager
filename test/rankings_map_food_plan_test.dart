// When the rankings map shows a place to eat or drink's dot and its name
// (planFoodLabels): worked out for every zoom at once, so zooming in only ever
// brings a dot or a name out — never puts a name back to a dot, or a dot out
// of sight — and at no zoom does a name run into another, or a dot into
// anything.

import 'dart:math';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/rankings/rankings_map_chrome.dart';

const _zoom = 17;
final _dot = Rect.fromCircle(center: Offset.zero, radius: 6);

/// A name's box around its point: [width] wide, one line or three tall.
Rect _box(double width, {int lines = 1}) =>
    Rect.fromCenter(center: Offset.zero, width: width, height: 15.0 * lines);

/// [label] at [zoom] on screen: its point spread from where it is at [_zoom].
Rect _at(({Offset at, Rect box, double key}) label, Rect box, double zoom) =>
    box.shift(label.at * pow(2, zoom - _zoom).toDouble());

void main() {
  test('the better known name takes the room; the other is a dot', () {
    final labels = [
      (at: const Offset(1000, 1000), box: _box(80), key: 40.0),
      (at: const Offset(1010, 1000), box: _box(80), key: 2.0),
    ];
    final [cafe, diner] = planFoodLabels(labels, zoom: _zoom, dot: _dot);

    // 10 pixels apart at 17, the boxes 80 wide: they part at 17 + log2(8).
    expect(diner.name, lessThan(15));
    expect(cafe.name, closeTo(20, 1e-9));
    // The cafe's dot sits inside the diner's name until 17 + log2(4.6).
    expect(cafe.dot, closeTo(_zoom + log(46 / 10) / ln2, 1e-9));
  });

  test('two places at the same point: the lesser is never a name', () {
    final labels = [
      (at: const Offset(500, 500), box: _box(60), key: 1.0),
      (at: const Offset(500, 500), box: _box(60), key: 2.0),
    ];
    final [_, second] = planFoodLabels(labels, zoom: _zoom, dot: _dot);

    expect(second.name, double.infinity);
    expect(second.dot, double.infinity);
  });

  test('zooming in only brings dots and names out, and none collide', () {
    final random = Random(7);
    // Crowded blocks of places, as on a street of restaurants.
    final labels = [
      for (var block = 0; block < 6; block++)
        for (var i = 0; i < 40; i++)
          (
            at: Offset(
              block * 900 + random.nextDouble() * 300,
              block * 500 + random.nextDouble() * 200,
            ),
            box: _box(
              40 + random.nextDouble() * 60,
              lines: 1 + random.nextInt(3),
            ),
            key: random.nextInt(120).toDouble(),
          ),
    ];
    final plan = planFoodLabels(labels, zoom: _zoom, dot: _dot);

    // 0 hidden, 1 a dot, 2 a name.
    int state(int i, double zoom) => zoom >= plan[i].name
        ? 2
        : zoom >= plan[i].dot
        ? 1
        : 0;
    final last = List.filled(labels.length, 0);
    var names = 0;
    for (var zoom = 14.5; zoom <= 20; zoom += 0.05) {
      final shown = [
        for (var i = 0; i < labels.length; i++)
          if (state(i, zoom) case final now when now > 0)
            (
              i: i,
              name: now == 2,
              box: _at(labels[i], now == 2 ? labels[i].box : _dot, zoom),
            ),
      ];
      for (var i = 0; i < labels.length; i++) {
        final now = state(i, zoom);
        expect(now, greaterThanOrEqualTo(last[i]), reason: '$i at $zoom');
        last[i] = now;
      }
      for (final a in shown) {
        for (final b in shown) {
          if (a.i >= b.i) continue;
          expect(
            a.box.overlaps(b.box),
            isFalse,
            reason: '${a.i} and ${b.i} at $zoom',
          );
        }
      }
      names = shown.where((s) => s.name).length;
    }
    // Close in, most of the crowd has its name.
    expect(names, greaterThan(labels.length * 0.6));
  });
}
