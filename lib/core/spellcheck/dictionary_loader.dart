import 'package:flutter/services.dart';

/// The bundled word list, in the order the asset lists it — descending
/// frequency, so `you`, `i`, `the` come first and the rarest words last.
///
/// That order is load-bearing, not incidental: [searchDictionary] ranks its
/// results by it, which is what lets a one-character query answer with the
/// words the user plausibly meant instead of the alphabetically first ones,
/// and what lets the scan stop once the cap is full. A set literal builds a
/// `LinkedHashSet`, which preserves it — swapping in an unordered set, or
/// sorting here, would quietly make dictionary search both worse and slower.
Future<Set<String>> loadDictionaryFromAssets() async {
  final raw = await rootBundle.loadString('assets/dictionary_en.txt');
  return {
    for (final line in raw.split('\n'))
      if (line.trim().isNotEmpty) line.trim().toLowerCase(),
  };
}
