import 'dart:math';

import 'package:voyager/domain/models/settings_models.dart';

/// Draws quotes at random, weighted against ones a journal used recently.
///
/// A quote last drawn `d` days ago in the same journal weighs
/// `(min(d, n) / n)²` for a pool of `n`: one drawn today can't come back
/// today, one drawn yesterday is unlikely, and anything `n` or more days old —
/// or never drawn in that journal — is back at full weight. Each journal keeps
/// its own history.
class QuoteBank {
  QuoteBank(
    this._quotes, {
    Map<String, Map<String, DateTime>> lastUsed = const {},
    Random? random,
  }) : _lastUsed = {
         for (final e in lastUsed.entries) e.key: {...e.value},
       },
       _random = random ?? Random();

  final List<Quote> _quotes;

  /// journalId → quoteId → when that quote was last drawn there.
  final Map<String, Map<String, DateTime>> _lastUsed;
  final Random _random;

  Quote nextQuote(String journalId, {DateTime? now}) {
    if (_quotes.isEmpty) {
      return const Quote(id: 'default', text: 'Write your story.');
    }
    now ??= DateTime.now();
    final used = _lastUsed.putIfAbsent(journalId, () => {});
    final n = _quotes.length;
    final weights = [
      for (final q in _quotes)
        switch (used[q.id]) {
          null => 1.0,
          // Clamped at 0: a use dated ahead of `now` (another device's clock
          // running fast) counts as today's rather than squaring into a
          // weight above 1.
          final at => pow(
            max(0, min(_daysBetween(at, now), n)) / n,
            2,
          ).toDouble(),
        },
    ];
    var total = weights.fold<double>(0, (a, b) => a + b);
    // Every quote drawn today, as with a pool of one: fall back to uniform.
    if (total == 0) {
      weights.fillRange(0, n, 1);
      total = n.toDouble();
    }
    // Falls through to the last *eligible* quote, not the last one: rounding
    // between the sum and the subtractions can leave the roll just short of
    // zero at the end, and landing on a zero-weight quote there would hand
    // back one drawn today.
    final last = weights.lastIndexWhere((w) => w > 0);
    var roll = _random.nextDouble() * total;
    var i = 0;
    while (i < last && (weights[i] == 0 || (roll -= weights[i]) >= 0)) {
      i++;
    }
    final pick = _quotes[i];
    used[pick.id] = now;
    return pick;
  }

  /// Calendar days in local time, so an entry at 23:00 and one at 01:00 the
  /// next morning are a day apart. Compared as UTC dates to sidestep DST.
  static int _daysBetween(DateTime from, DateTime to) {
    final a = from.toLocal();
    final b = to.toLocal();
    return DateTime.utc(
      b.year,
      b.month,
      b.day,
    ).difference(DateTime.utc(a.year, a.month, a.day)).inDays;
  }
}
