import 'dart:ui';

/// What spellcheck and autocorrect leave alone in the composer (§9.5),
/// beyond the inline code every Voyager field skips: fenced code (an
/// unclosed fence to the end, as it's being typed), `[image N]` labels, and
/// any run with a slash in it, which takes in `/commands`, paths and URLs,
/// plus a bare `www.` address.
List<TextRange> gaiaComposerSkipZones(String text) => [
  for (final pattern in _skipped)
    for (final match in pattern.allMatches(text))
      TextRange(start: match.start, end: match.end),
];

final _skipped = [
  RegExp(
    r'^[ \t]*```.*?(?:^[ \t]*```|$(?![\s\S]))',
    multiLine: true,
    dotAll: true,
  ),
  RegExp(r'\[image \d+\]'),
  // From a run's start only, or a long run without a slash is quadratic.
  RegExp(r'(?<!\S)[^\s]*[/\\][^\s]*'),
  RegExp(r'\bwww\.[^\s]+'),
];
