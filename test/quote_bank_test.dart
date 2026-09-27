import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/services/quote_bank.dart';

const _quotes = [
  Quote(id: 'a', text: 'A'),
  Quote(id: 'b', text: 'B'),
  Quote(id: 'c', text: 'C'),
  Quote(id: 'd', text: 'D'),
];

void main() {
  final today = DateTime(2026, 9, 27, 12);

  test('never repeats a quote drawn today while another is available', () {
    for (var seed = 0; seed < 200; seed++) {
      final bank = QuoteBank(_quotes, random: Random(seed));
      final drawn = {
        for (var i = 0; i < 4; i++) bank.nextQuote('j', now: today).id,
      };
      expect(drawn, hasLength(4), reason: 'seed $seed');
    }
  });

  test('a quote drawn yesterday is much rarer than a fresh one', () {
    final yesterday = today.subtract(const Duration(days: 1));
    final counts = <String, int>{};
    final random = Random(1);
    for (var i = 0; i < 20000; i++) {
      final bank = QuoteBank(
        _quotes,
        lastUsed: {
          'j': {'a': yesterday},
        },
        random: random,
      );
      final id = bank.nextQuote('j', now: today).id;
      counts[id] = (counts[id] ?? 0) + 1;
    }
    // Weight 1/16 against 1 for each of the other three.
    final ratio = counts['a']! / counts['b']!;
    expect(ratio, closeTo(1 / 16, 0.02));
  });

  test('history is per journal', () {
    final bank = QuoteBank(
      _quotes,
      lastUsed: {
        'j1': {'a': today, 'b': today, 'c': today},
      },
      random: Random(0),
    );
    expect(bank.nextQuote('j1', now: today).id, 'd');
    // j2 has no history, so all four are open to it.
    final drawn = {
      for (var i = 0; i < 4; i++) bank.nextQuote('j2', now: today).id,
    };
    expect(drawn, hasLength(4));
  });

  test('falls back to uniform when everything was drawn today', () {
    final bank = QuoteBank(const [Quote(id: 'only', text: 'Only')]);
    expect(bank.nextQuote('j', now: today).id, 'only');
    expect(bank.nextQuote('j', now: today).id, 'only');
  });

  test('counts calendar days, not 24-hour spans', () {
    final lateLastNight = DateTime(2026, 9, 26, 23);
    final earlyThisMorning = DateTime(2026, 9, 27, 1);
    // Two hours later but the next day: weight (1/2)², not 0.
    var sawA = false;
    for (var i = 0; i < 200 && !sawA; i++) {
      final fresh = QuoteBank(
        const [Quote(id: 'a', text: 'A'), Quote(id: 'b', text: 'B')],
        lastUsed: {
          'j': {'a': lateLastNight},
        },
        random: Random(i),
      );
      sawA = fresh.nextQuote('j', now: earlyThisMorning).id == 'a';
    }
    expect(sawA, isTrue);
  });

  test('a use dated in the future counts as today', () {
    // Unclamped, three days ahead in a pool of two weighed (-3/2)² = 2.25.
    for (var seed = 0; seed < 50; seed++) {
      final bank = QuoteBank(
        const [Quote(id: 'a', text: 'A'), Quote(id: 'b', text: 'B')],
        lastUsed: {
          'j': {'a': today.add(const Duration(days: 3))},
        },
        random: Random(seed),
      );
      expect(bank.nextQuote('j', now: today).id, 'b', reason: 'seed $seed');
    }
  });

  test('a roll at the very top never lands on a quote drawn today', () {
    final bank = QuoteBank(
      _quotes,
      lastUsed: {
        'j': {'d': today},
      },
      random: _MaxRandom(),
    );
    expect(bank.nextQuote('j', now: today).id, 'c');
  });
}

/// Rolls as close to 1 as a double gets, to reach the end of the walk.
class _MaxRandom implements Random {
  @override
  double nextDouble() => 1 - pow(2, -53).toDouble();

  @override
  bool nextBool() => throw UnimplementedError();

  @override
  int nextInt(int max) => throw UnimplementedError();
}
