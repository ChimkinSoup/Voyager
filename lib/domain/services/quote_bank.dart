import 'dart:math';

import 'package:voyager/domain/models/settings_models.dart';

class QuoteBank {
  QuoteBank(this._quotes);

  final List<Quote> _quotes;
  final _used = <String>{};
  final _random = Random();

  Quote nextQuote() {
    if (_quotes.isEmpty) {
      return const Quote(id: 'default', text: 'Write your story.');
    }
    final remaining = _quotes.where((q) => !_used.contains(q.id)).toList();
    if (remaining.isEmpty) {
      _used.clear();
      return nextQuote();
    }
    final pick = remaining[_random.nextInt(remaining.length)];
    _used.add(pick.id);
    return pick;
  }
}
