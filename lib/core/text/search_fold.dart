// Folding for search: what a query and the text it searches are both reduced
// to before they are compared.

/// [text] folded for matching: lower case with diacritics dropped, so `cafe`
/// finds `café` and `naive` finds `naïve` (BUG-090) — users type unaccented
/// letters on a US keyboard.
String searchFold(String text) {
  for (var i = 0; i < text.length; i++) {
    if (text.codeUnitAt(i) >= 0x80) return searchFoldMapped(text).text;
  }
  return text.toLowerCase();
}

/// [text] folded as [searchFold] does, with where each folded code unit came
/// from: unit `k` of [text] came from `[starts[k], ends[k])` of the source.
///
/// Folding changes lengths — a combining accent disappears, `ß` becomes `ss`
/// — so a highlighter that matches on the folded text needs this to find the
/// match again in what it displays.
///
/// Offsets in [skip] are left out entirely, for the formatting delimiters a
/// read surface hides (BUG-089): matching then sees `foo**bar**` as the
/// `foobar` the reader sees. [skipBase] is added to an offset before it is
/// looked up, for a caller folding a slice of a document whose delimiters are
/// in document offsets.
({String text, List<int> starts, List<int> ends}) searchFoldMapped(
  String text, {
  Set<int> skip = const {},
  int skipBase = 0,
}) {
  final out = StringBuffer();
  final starts = <int>[];
  final ends = <int>[];

  void emit(String folded, int start, int end) {
    out.write(folded);
    for (var k = 0; k < folded.length; k++) {
      starts.add(start);
      ends.add(end);
    }
  }

  var i = 0;
  while (i < text.length) {
    final unit = text.codeUnitAt(i);
    if (skip.contains(i + skipBase)) {
      i++;
      continue;
    }
    if (unit < 0x80) {
      final lower = unit >= 0x41 && unit <= 0x5A ? unit + 0x20 : unit;
      emit(String.fromCharCode(lower), i, i + 1);
      i++;
      continue;
    }
    // A surrogate pair is lowercased whole and otherwise left alone: nothing
    // outside the BMP carries an accent this folds.
    if (unit >= 0xD800 &&
        unit <= 0xDBFF &&
        i + 1 < text.length &&
        _isLowSurrogate(text.codeUnitAt(i + 1))) {
      emit(text.substring(i, i + 2).toLowerCase(), i, i + 2);
      i += 2;
      continue;
    }
    // Lowercased first: `É` and `é` then share one table entry, and `İ`
    // lowercases to `i` plus a combining dot, which the loop below drops.
    final lower = String.fromCharCode(unit).toLowerCase();
    for (var k = 0; k < lower.length; k++) {
      final u = lower.codeUnitAt(k);
      if (_isCombiningMark(u)) continue;
      emit(_latinFolds[u] ?? String.fromCharCode(u), i, i + 1);
    }
    i++;
  }
  return (text: out.toString(), starts: starts, ends: ends);
}

bool _isLowSurrogate(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;

/// The combining diacritical blocks: what a decomposed `e` + `́` leaves
/// behind once its base letter is kept.
bool _isCombiningMark(int unit) =>
    (unit >= 0x0300 && unit <= 0x036F) ||
    (unit >= 0x1AB0 && unit <= 0x1AFF) ||
    (unit >= 0x1DC0 && unit <= 0x1DFF) ||
    (unit >= 0x20D0 && unit <= 0x20FF) ||
    (unit >= 0xFE20 && unit <= 0xFE2F);

/// Lower-case Latin-1 and Latin Extended-A letters (plus `ș` / `ț`) to their
/// unaccented spelling.
final Map<int, String> _latinFolds = () {
  const groups = {
    'àáâãäåāăą': 'a',
    'çćĉċč': 'c',
    'ďđð': 'd',
    'èéêëēĕėęě': 'e',
    'ĝğġģ': 'g',
    'ĥħ': 'h',
    'ìíîïĩīĭįı': 'i',
    'ĵ': 'j',
    'ķ': 'k',
    'ĺļľŀł': 'l',
    'ñńņňŉ': 'n',
    'òóôõöøōŏő': 'o',
    'ŕŗř': 'r',
    'śŝşšș': 's',
    'ţťŧț': 't',
    'ùúûüũūŭůűų': 'u',
    'ŵ': 'w',
    'ýÿŷ': 'y',
    'źżž': 'z',
    'æ': 'ae',
    'œ': 'oe',
    'ß': 'ss',
    'þ': 'th',
    // Greek final sigma, so a typed `ς` meets the `σ` an uppercase `Σ`
    // lowercases to one letter at a time.
    'ς': 'σ',
  };
  return {
    for (final MapEntry(:key, :value) in groups.entries)
      for (final unit in key.codeUnits) unit: value,
  };
}();
