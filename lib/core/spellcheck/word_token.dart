/// What counts as one spell-checkable word.
///
/// [wordTokenPattern] is what the tokenizer scans text with; [isCustomWordToken]
/// anchors the same pattern, so a word the user adds to the dictionary is
/// exactly a word the tokenizer can produce. The two are deliberately the one
/// expression rather than two copies: an entry the tokenizer can never emit
/// (`well-known`, `voyager2`, two words) would sit in the dictionary doing
/// nothing, and the user would have no way to tell.
final RegExp wordTokenPattern = RegExp(r"[A-Za-z]+(?:'[A-Za-z]+)*");

/// The maximal run [tokenizeWords] scans for: [wordTokenPattern] widened to
/// admit digits, so an alphanumeric arrives as one run instead of as the
/// letter-only pieces between its digits. A run holding a digit is then
/// dropped whole (see [runHasDigit]).
///
/// Scanning for letters alone made `3D` present as the word `D`, and `XM6's`
/// as `XM` and `s` — three squiggles under things nobody misspelled, because a
/// digit ended one token and started the next.
final RegExp wordRunPattern = RegExp(r"[A-Za-z0-9]+(?:'[A-Za-z0-9]+)*");

final RegExp _digit = RegExp(r'[0-9]');

/// Whether a [wordRunPattern] run holds a digit, which takes it out of
/// spell-check entirely: `3D`, `XM6`, `1990s`, `x264enc` are model numbers,
/// dates and identifiers, not prose the dictionary has an opinion about. The
/// dictionary cannot hold them either ([isCustomWordToken] rejects
/// `voyager2`), so flagging them would be a squiggle with no way to dismiss
/// it. The cost is that a typo with a digit stuck to it (`wtih2`) goes
/// unflagged, which is the quieter failure of the two.
bool runHasDigit(String run) => _digit.hasMatch(run);

final RegExp _wholeWordToken = RegExp('^${wordTokenPattern.pattern}\$');

/// How a dictionary entry is stored and looked up: trimmed and lowercased.
String normalizeCustomWord(String raw) => raw.trim().toLowerCase();

/// Whether [word] is a single word token — letters, with apostrophes allowed
/// between them so `don't` is legal. Expects an already-normalized word.
bool isCustomWordToken(String word) => _wholeWordToken.hasMatch(word);

/// Whether [word] is spelled correctly against [known], letting a possessive
/// lean on the word it is possessive of. Expects an already-lowercased token.
///
/// The bundled list holds contractions (`don't`, `it's`) but no possessives at
/// all, so `dog's` and `Juno's` read as unknown words even when `dog` and a
/// custom `juno` are both there. Worse than the squiggle, the autocorrect
/// cascade found `dogs` exactly one deletion away and rewrote the apostrophe
/// out of it.
///
/// Only a trailing `'s` is stripped. A plural possessive (`the dogs' bowls`)
/// never reaches here as one token: [wordTokenPattern] keeps an apostrophe
/// only between letters, so that token is already just `dogs`.
///
/// A flag still wins, because [known] has already had the flagged words
/// subtracted: flagging `dog` puts the squiggle back under `dog's` too.
bool isKnownWord(String word, Set<String> known) {
  if (known.contains(word)) return true;
  final base = _possessiveBase(word);
  return base != null && known.contains(base);
}

/// [word] without a trailing `'s`, or null when it has none. One letter is a
/// long enough base — `mind your p's and q's` — but a bare `'s` has nothing to
/// check.
String? _possessiveBase(String word) {
  if (!word.endsWith("'s") || word.length < 3) return null;
  return word.substring(0, word.length - 2);
}
