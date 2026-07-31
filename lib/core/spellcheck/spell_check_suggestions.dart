const _letters = 'abcdefghijklmnopqrstuvwxyz';

Iterable<String> _edits1(String word) sync* {
  for (var i = 0; i <= word.length; i++) {
    final left = word.substring(0, i);
    final right = word.substring(i);
    if (right.isNotEmpty) yield left + right.substring(1); // delete
    if (right.length > 1) {
      yield left + right[1] + right[0] + right.substring(2); // transpose
    }
    if (right.isNotEmpty) {
      for (final c in _letters.split('')) {
        yield left + c + right.substring(1); // replace
      }
    }
    for (final c in _letters.split('')) {
      yield left + c + right; // insert
    }
  }
}

/// Distance-2 exploration is O((letters * word.length)^2) candidate strings,
/// which can reach the hundreds of thousands for an in-progress word (the
/// common case: [generateSuggestions] runs synchronously on every keystroke
/// via Flutter's [SpellCheckService], and a partial word is almost never
/// within edit-distance 1 of anything real). Capping how many distance-2
/// candidates get generated keeps a single call from blocking the UI
/// isolate for seconds — see project_flutter_spellcheck_freeze memory.
const _maxDistance2Explored = 50000;

/// Norvig-style edit-distance-1/2 suggestion generator: cheap, no external
/// dependency or frequency data, cascades to distance-2 only when distance-1
/// yields nothing against [known].
List<String> generateSuggestions(
  String word,
  Set<String> known, {
  int maxResults = 5,
}) {
  final lower = word.toLowerCase();
  final edits1 = _edits1(lower).toSet();
  var candidates = edits1.where(known.contains).toSet();
  if (candidates.isEmpty) {
    candidates = {};
    var explored = 0;
    outer:
    for (final e1 in edits1) {
      for (final e2 in _edits1(e1)) {
        if (known.contains(e2)) candidates.add(e2);
        if (++explored >= _maxDistance2Explored) break outer;
      }
    }
  }
  final list = candidates.toList()
    ..sort((a, b) {
      final da = (a.length - lower.length).abs();
      final db = (b.length - lower.length).abs();
      if (da != db) return da.compareTo(db);
      return a.compareTo(b);
    });
  return list.take(maxResults).toList();
}
