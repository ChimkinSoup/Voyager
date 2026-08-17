/// What counts as one spell-checkable word.
///
/// [wordTokenPattern] is what the tokenizer scans text with; [isCustomWordToken]
/// anchors the same pattern, so a word the user adds to the dictionary is
/// exactly a word the tokenizer can produce. The two are deliberately the one
/// expression rather than two copies: an entry the tokenizer can never emit
/// (`well-known`, `voyager2`, two words) would sit in the dictionary doing
/// nothing, and the user would have no way to tell.
final RegExp wordTokenPattern = RegExp(r"[A-Za-z]+(?:'[A-Za-z]+)*");

final RegExp _wholeWordToken = RegExp('^${wordTokenPattern.pattern}\$');

/// How a dictionary entry is stored and looked up: trimmed and lowercased.
String normalizeCustomWord(String raw) => raw.trim().toLowerCase();

/// Whether [word] is a single word token — letters, with apostrophes allowed
/// between them so `don't` is legal. Expects an already-normalized word.
bool isCustomWordToken(String word) => _wholeWordToken.hasMatch(word);
