final journalTagPattern = RegExp(r'#(\w+)');

List<String> extractTags(String body) {
  final matches = journalTagPattern.allMatches(body);
  return {for (final match in matches) match.group(1)!}.toList();
}

int colorForTag(String tag) => 0xFF000000 | (tag.hashCode.abs() & 0xFFFFFF);
