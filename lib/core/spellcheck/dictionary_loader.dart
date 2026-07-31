import 'package:flutter/services.dart';

Future<Set<String>> loadDictionaryFromAssets() async {
  final raw = await rootBundle.loadString('assets/dictionary_en.txt');
  return {
    for (final line in raw.split('\n'))
      if (line.trim().isNotEmpty) line.trim().toLowerCase(),
  };
}
