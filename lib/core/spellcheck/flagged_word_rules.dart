import 'package:voyager/core/spellcheck/word_token.dart';

/// The rules a flagged-word row has to satisfy (`FLAGGED_WORDS.md` §2, §10,
/// §11), kept pure and in one place so the field popover and the Dictionary
/// dialog cannot disagree about what they will accept.

/// Said when a word or a replacement isn't a single tokenizer word. Same
/// sentence the dictionary uses for the same shape, for the same reason: an
/// entry the tokenizer can never emit would sit there doing nothing.
const String flaggedWordShapeError =
    'A word is one word: letters, and apostrophes inside it.';

/// Live flags whose replacement is [word], alphabetically.
///
/// The lookup behind §10's refusal: flagging a word another pair rewrites *to*
/// would leave that rule pointing at a spelling the checker no longer accepts.
List<String> pairsPointingAt(String word, Map<String, String?> flagged) {
  final hits = <String>[
    for (final entry in flagged.entries)
      if (entry.value == word) entry.key,
  ];
  hits.sort();
  return hits;
}

/// Why [word] cannot be flagged, or null when it can.
///
/// Refuses rather than silently clearing the pairs that point at it: a rule
/// the user wrote should not disappear because they flagged something else
/// (`FLAGGED_WORDS.md` §10).
String? validateFlagWord(String word, Map<String, String?> flagged) {
  if (!isCustomWordToken(word)) return flaggedWordShapeError;
  final pointing = pairsPointingAt(word, flagged);
  if (pointing.isEmpty) return null;
  final naming = pointing.length == 1
      ? '"${pointing.first}"'
      : '"${pointing.first}" and ${pointing.length - 1} other '
            '${pointing.length == 2 ? 'word' : 'words'}';
  return 'Can\'t flag "$word" — $naming already replaces with it. '
      'Change that replacement first.';
}

/// Why [replacement] cannot be stored on the flag for [word], or null when it
/// can. Empty is "no pair", which is always legal — clearing a replacement
/// keeps the flag.
///
/// [known] is the checker's live set, which already has every flag subtracted.
/// The explicit [flagged] test is only there to say *why* a flagged target was
/// rejected; "add it to the dictionary" would be the wrong advice for a word
/// the dictionary has.
String? validateFlagReplacement({
  required String word,
  required String replacement,
  required Set<String> known,
  required Map<String, String?> flagged,
}) {
  if (replacement.isEmpty) return null;
  if (!isCustomWordToken(replacement)) return flaggedWordShapeError;
  if (replacement == word) {
    return 'The replacement has to be a different word.';
  }
  if (flagged.containsKey(replacement)) {
    return '"$replacement" is flagged too — pick a word the checker accepts.';
  }
  if (!known.contains(replacement)) {
    return 'The checker doesn\'t know "$replacement" — add it to the '
        'dictionary first.';
  }
  return null;
}
