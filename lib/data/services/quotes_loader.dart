import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:voyager/domain/models/settings_models.dart';

Future<List<Quote>> loadQuotesFromAssets() async {
  final raw = await rootBundle.loadString('assets/quotes.json');
  final list = jsonDecode(raw) as List;
  return [
    for (var i = 0; i < list.length; i++)
      Quote(id: 'quote_$i', text: list[i] as String),
  ];
}
