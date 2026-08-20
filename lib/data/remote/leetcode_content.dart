/// Turns LeetCode GraphQL `question.content` HTML into plain problem-statement
/// text for flashcards and the track form.
///
/// Drops everything from the first `Example N:` onward (examples, constraints,
/// follow-ups) and strips markup so only prose remains — inline identifiers
/// that lived inside `<code>` tags are kept as plain words. Blank lines from
/// paragraph tags are collapsed so the statement reads as consecutive lines.
String? leetCodeContentToDescription(String? html) {
  if (html == null) return null;
  final stripped = _stripHtml(html);
  final cut = _collapseBlankLines(_dropFromFirstExample(stripped).trim());
  if (cut.isEmpty) return null;
  return cut;
}

/// Pulls the worked examples out of LeetCode GraphQL `question.content`, one
/// entry per `Example N:` block, in the order they appear.
///
/// Each entry holds everything between that heading and the next one — the
/// Input/Output lines plus the example's own explanation, as plain text. The
/// headings themselves are dropped: examples are numbered by position where
/// they're shown, so deleting one renumbers the rest. Trailing Constraints and
/// Follow-up sections belong to the problem rather than to the last example,
/// so they're cut away.
///
/// Blank lines inside an example are collapsed to single newlines so
/// Input/Output/Explanation read as consecutive lines.
List<String> leetCodeContentToExamples(String? html) {
  if (html == null) return const [];
  final text = _stripHtml(html);
  final headings = _exampleHeading.allMatches(text).toList();
  if (headings.isEmpty) return const [];

  final examples = <String>[];
  for (var i = 0; i < headings.length; i++) {
    final end = i + 1 < headings.length ? headings[i + 1].start : text.length;
    final body = _collapseBlankLines(
      _dropTrailingSections(text.substring(headings[i].end, end)).trim(),
    );
    if (body.isNotEmpty) examples.add(body);
  }
  return examples;
}

/// Drops every line with nothing on it, so GraphQL-extracted description and
/// example text don't ship empty lines between paragraphs or Input/Output
/// lines. Hand-written fields never go through this path.
///
/// "Nothing on it" is decided by [String.trim], not by a `\n{2,}` run: a line
/// LeetCode left a stray `\r`, a non-breaking space (`&#160;` decodes to one,
/// unlike `&nbsp;`), or any other Unicode blank on reads as empty to the user
/// but breaks the run, so a newline-counting rule leaves exactly the blank
/// lines that are hardest to see in the source HTML.
String _collapseBlankLines(String text) {
  return [
    for (final line in text.split('\n'))
      if (line.trim().isNotEmpty) line.trimRight(),
  ].join('\n');
}

final _exampleHeading = RegExp(r'Example\s+\d+\s*:', caseSensitive: false);

/// "Constraints:" / "Follow-up:" at the start of a line — the tail of the
/// problem statement, not part of the example it happens to sit after.
final _trailingSection = RegExp(
  r'^[ \t]*(Constraints|Follow[ -]?up)\b[^\n]*:',
  caseSensitive: false,
  multiLine: true,
);

String _dropTrailingSections(String text) {
  final match = _trailingSection.firstMatch(text);
  return match == null ? text : text.substring(0, match.start);
}

String _dropFromFirstExample(String text) {
  final match = _exampleHeading.firstMatch(text);
  if (match == null) return text;
  return text.substring(0, match.start);
}

String _stripHtml(String html) {
  var s = html
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'</p\s*>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'</div\s*>', caseSensitive: false), '\n')
      // List items become "- …" lines. Swallow whitespace around the tags so
      // indented HTML like "<li>\n  text\n</li>\n  <li>" stays one line per item.
      .replaceAll(RegExp(r'<li[^>]*>\s*', caseSensitive: false), '- ')
      .replaceAll(RegExp(r'\s*</li\s*>\s*', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'</h[1-6]\s*>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<[^>]+>'), '');
  s = _decodeHtmlEntities(s);
  s = s.replaceAll(RegExp(r'[ \t]+\n'), '\n');
  s = s.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  s = s.replaceAll(RegExp(r'[ \t]{2,}'), ' ');
  // HTML indentation between tags collapses to a single leading space after the
  // step above; drop it so prose and "- " bullets start at column 0.
  s = s.replaceAll(RegExp(r'^[ \t]+', multiLine: true), '');
  return s;
}

String _decodeHtmlEntities(String input) {
  var s = input
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'");
  s = s.replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
    final code = int.tryParse(m.group(1)!);
    if (code == null) return m.group(0)!;
    return String.fromCharCode(code);
  });
  s = s.replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (m) {
    final code = int.tryParse(m.group(1)!, radix: 16);
    if (code == null) return m.group(0)!;
    return String.fromCharCode(code);
  });
  return s;
}
