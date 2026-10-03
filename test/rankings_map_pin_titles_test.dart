// When the title under a rankings map pin shows (planPinTitles): never over
// another pin, nor over another title then showing, the better scored keeping
// its title where two meet.

import 'dart:math';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/rankings/rankings_map_chrome.dart';

const _zoom = rankingsMapNameZoom;

void main() {
  test("a better pin's title over a lesser pin waits until they part", () {
    // Two pins 50 pixels apart, the better up and to the right: its title
    // runs across the lesser pin, as Fresh Burrito's did over Banh Mi's.
    final [better, lesser] = planPinTitles([
      (at: const Offset(1040, 970), title: const Size(85, 13), key: -8.1),
      (at: const Offset(1000, 1000), title: const Size(95, 13), key: -7.3),
    ], zoom: _zoom);

    // The title, 42.5 either side and 17 to 30 under its point, clears the
    // lesser pin's disc, 20 round, once 62.5 pixels apart across.
    expect(better, closeTo(_zoom + log(62.5 / 40) / ln2, 1e-9));
    expect(lesser, _zoom);
  });

  test('a pin without a title has none to show', () {
    final [plan] = planPinTitles([
      (at: const Offset(0, 0), title: Size.zero, key: 0),
    ], zoom: _zoom);

    expect(plan, double.infinity);
  });

  test('at no zoom does a title run over a pin or another title', () {
    final random = Random(7);
    final pins = [
      for (var i = 0; i < 60; i++)
        (
          at: Offset(random.nextDouble() * 600, random.nextDouble() * 600),
          title: Size(30 + random.nextDouble() * 66, 13.0 * (1 + i % 2)),
          key: random.nextBool() ? -random.nextDouble() * 10 : double.infinity,
        ),
    ];
    final plan = planPinTitles(pins, zoom: _zoom);
    final disc = Rect.fromCircle(
      center: Offset.zero,
      radius: RankingsMapPin.size / 2,
    );

    for (var zoom = _zoom.toDouble(); zoom <= 21; zoom += 1 / 16) {
      final spread = pow(2, zoom - _zoom).toDouble();
      Rect title(int i) => Rect.fromLTWH(
        -pins[i].title.width / 2,
        rankingsMapTitleDrop,
        pins[i].title.width,
        pins[i].title.height,
      ).shift(pins[i].at * spread);
      final shown = [
        for (var i = 0; i < pins.length; i++)
          if (zoom >= plan[i]) i,
      ];
      for (final i in shown) {
        for (var j = 0; j < pins.length; j++) {
          if (j == i) continue;
          final box = title(i).deflate(1e-6);
          expect(box.overlaps(disc.shift(pins[j].at * spread)), isFalse);
          if (shown.contains(j)) expect(box.overlaps(title(j)), isFalse);
        }
      }
    }
    // Some show at the name zoom and some only further in.
    expect(plan.where((from) => from == _zoom), isNotEmpty);
    expect(plan.where((from) => from > _zoom && from.isFinite), isNotEmpty);
  });
}
