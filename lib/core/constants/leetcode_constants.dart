import 'package:flutter/material.dart';
import 'package:voyager/domain/models/enums.dart';

/// LeetCode's own difficulty-tier colors, so badges/rings match what the
/// user sees on the actual site.
const kLeetCodeEasyColor = Color(0xFF00B8A3);
const kLeetCodeMediumColor = Color(0xFFFFC01E);
const kLeetCodeHardColor = Color(0xFFFF375F);

Color colorForLeetCodeDifficulty(LeetCodeDifficulty difficulty) =>
    switch (difficulty) {
      LeetCodeDifficulty.easy => kLeetCodeEasyColor,
      LeetCodeDifficulty.medium => kLeetCodeMediumColor,
      LeetCodeDifficulty.hard => kLeetCodeHardColor,
    };

String labelForLeetCodeDifficulty(LeetCodeDifficulty difficulty) =>
    switch (difficulty) {
      LeetCodeDifficulty.easy => 'Easy',
      LeetCodeDifficulty.medium => 'Medium',
      LeetCodeDifficulty.hard => 'Hard',
    };

/// Languages offered in the Track modal's code-language selector.
const leetCodeCodeLanguages = [
  'python',
  'java',
  'cpp',
  'javascript',
  'typescript',
  'go',
  'rust',
  'csharp',
];

/// Display label for a code-language key. Only `cpp`/`csharp` need
/// reformatting — every other key is already the label shown to the user.
String labelForLeetCodeLanguage(String language) => switch (language) {
  'cpp' => 'C++',
  'csharp' => 'C#',
  _ => language,
};

/// The `#tag` body for one of LeetCode's topic tags, as the API spells it.
///
/// LeetCode names its topics in prose — "Hash Table", "Divide and Conquer" —
/// but a tag is one whitespace-or-comma-delimited token everywhere in this app,
/// so the words are joined with hyphens rather than left to arrive as a tag
/// each. Casing is the API's own: [colorForTag] is case-sensitive, so folding it
/// here would give an imported tag a different color from the same tag typed by
/// hand.
String leetCodeTagToken(String topicTag) =>
    topicTag.trim().replaceAll(RegExp(r'[\s,]+'), '-');

/// The selector key for a `lang` as LeetCode's API spells it, or null when the
/// submission was in a language this app doesn't offer.
///
/// LeetCode names some of its runtimes by version ("python3") and others by
/// toolchain ("golang", "cpp"), and it offers a longer list than the selector
/// does. A null here is not an error — it just means there's nothing to
/// preselect and the caller should fall back to its default.
String? leetCodeLanguageKeyFor(String? apiLanguage) {
  if (apiLanguage == null || apiLanguage.isEmpty) return null;
  final key = switch (apiLanguage.toLowerCase()) {
    'python' || 'python3' || 'pypy3' => 'python',
    'java' => 'java',
    'cpp' || 'c++' => 'cpp',
    'javascript' || 'node.js' => 'javascript',
    'typescript' => 'typescript',
    'golang' || 'go' => 'go',
    'rust' => 'rust',
    'csharp' || 'c#' => 'csharp',
    _ => null,
  };
  return key != null && leetCodeCodeLanguages.contains(key) ? key : null;
}
