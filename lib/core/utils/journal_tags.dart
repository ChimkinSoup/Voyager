/// A `#tag`: word characters, with inner hyphens joining them into one tag.
///
/// The hyphen is what lets a multi-word name be a single tag — LeetCode's topic
/// tags arrive as prose ("Hash Table", "Depth-First Search"), and without it
/// each word would be filed as a tag of its own. It has to be *inner*: a
/// trailing hyphen is punctuation the user is still typing past ("#done-"),
/// not part of the name.
final journalTagPattern = RegExp(r'#(\w+(?:-\w+)*)');

List<String> extractTags(String body) {
  final matches = journalTagPattern.allMatches(body);
  return {for (final match in matches) match.group(1)!}.toList();
}

int colorForTag(String tag) => 0xFF000000 | (tag.hashCode.abs() & 0xFFFFFF);
