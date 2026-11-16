import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/gaia/companion/gaia_greetings.dart';

/// New-chat greetings' pool and bags (GAIA_GREETINGS_HLD.md §4, §8).
void main() {
  GaiaGreetings at(int hour, [int seed = 1]) => GaiaGreetings(
    random: Random(seed),
    now: () => DateTime(2026, 11, 15, hour),
  );

  test('the pool is 28 general, 14 named and 6 per window', () {
    int count(GaiaGreetingKind kind) =>
        kGaiaGreetings.where((greeting) => greeting.kind == kind).length;
    expect(count(GaiaGreetingKind.general), 28);
    expect(count(GaiaGreetingKind.named), 14);
    for (final window in GaiaGreetingKind.values.skip(2)) {
      expect(count(window), 6);
      expect(
        kGaiaGreetings.where((g) => g.kind == window && g.named),
        hasLength(3),
      );
    }
    expect(
      kGaiaGreetings.where((g) => g.kind == GaiaGreetingKind.named),
      everyElement(predicate<GaiaGreeting>((g) => g.named)),
    );
    expect(
      kGaiaGreetings.where((g) => g.kind == GaiaGreetingKind.general),
      everyElement(predicate<GaiaGreeting>((g) => !g.named)),
    );
  });

  test('every line fits 40 characters with a 12-character name', () {
    for (final greeting in kGaiaGreetings) {
      expect(
        greeting.filled('Abcdefghijkl').length,
        lessThanOrEqualTo(40),
        reason: greeting.text,
      );
    }
  });

  test('no named line is drawn without a name', () {
    final greetings = at(8);
    for (var i = 0; i < 1000; i++) {
      expect(greetings.draw(hasName: false).named, isFalse);
    }
  });

  test('only the current window is drawn, late night past midnight', () {
    for (final (hour, window) in [
      (8, GaiaGreetingKind.morning),
      (14, GaiaGreetingKind.afternoon),
      (19, GaiaGreetingKind.evening),
      (23, GaiaGreetingKind.lateNight),
      (3, GaiaGreetingKind.lateNight),
    ]) {
      final greetings = at(hour);
      final kinds = {
        for (var i = 0; i < 1000; i++) greetings.draw(hasName: true).kind,
      };
      expect(kinds, {
        GaiaGreetingKind.general,
        GaiaGreetingKind.named,
        window,
      }, reason: 'at $hour:00');
    }
  });

  test('a bag shows every line it can before repeating one', () {
    for (final hasName in [true, false]) {
      final greetings = at(8);
      final drawn = <GaiaGreetingKind, List<GaiaGreeting>>{};
      for (var i = 0; i < 2000; i++) {
        final greeting = greetings.draw(hasName: hasName);
        (drawn[greeting.kind] ??= []).add(greeting);
      }
      for (final MapEntry(key: kind, value: lines) in drawn.entries) {
        final showable = kGaiaGreetings
            .where((g) => g.kind == kind && (hasName || !g.named))
            .length;
        for (
          var start = 0;
          start + showable <= lines.length;
          start += showable
        ) {
          expect(
            lines.sublist(start, start + showable).toSet(),
            hasLength(showable),
            reason: '$kind, name: $hasName',
          );
        }
      }
    }
  });

  test('a refill keeps the last line out of its first draws', () {
    for (final hasName in [true, false]) {
      for (var seed = 0; seed < 20; seed++) {
        final greetings = at(8, seed);
        final drawn = <GaiaGreetingKind, List<GaiaGreeting>>{};
        for (var i = 0; i < 1000; i++) {
          final greeting = greetings.draw(hasName: hasName);
          (drawn[greeting.kind] ??= []).add(greeting);
        }
        for (final MapEntry(key: kind, value: lines) in drawn.entries) {
          final showable = kGaiaGreetings
              .where((g) => g.kind == kind && (hasName || !g.named))
              .length;
          final keep = min(3, showable - 1);
          for (
            var end = showable;
            end + keep <= lines.length;
            end += showable
          ) {
            expect(
              lines.sublist(end, end + keep),
              isNot(contains(lines[end - 1])),
              reason: '$kind, name: $hasName, seed $seed',
            );
          }
        }
      }
    }
  });

  test('bags are picked 55/30/15 with a name, 85/15 without', () {
    for (final (hasName, general, named) in [(true, 55, 30), (false, 85, 0)]) {
      final greetings = at(8, 7);
      final counts = <GaiaGreetingKind, int>{};
      for (var i = 0; i < 10000; i++) {
        final kind = greetings.draw(hasName: hasName).kind;
        counts[kind] = (counts[kind] ?? 0) + 1;
      }
      double share(GaiaGreetingKind kind) => (counts[kind] ?? 0) / 100;
      expect(share(GaiaGreetingKind.general), closeTo(general, 2));
      expect(share(GaiaGreetingKind.named), closeTo(named, 2));
      expect(share(GaiaGreetingKind.morning), closeTo(15, 2));
    }
  });
}
