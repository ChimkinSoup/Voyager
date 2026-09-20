/// Offset where [line]'s trailing line comment starts, or `line.length` when
/// it has none.
///
/// Recognises `//` and `#`, and skips quoted text so the `//` in
/// `url = "http://x"` is not mistaken for one — stripping there would leave a
/// line ending in `:`, which is exactly the character the indent rules look
/// for.
int codeLineCommentStart(String line) {
  var quote = '';
  for (var i = 0; i < line.length; i++) {
    final char = line[i];
    if (quote.isNotEmpty) {
      if (char == r'\') {
        i++;
      } else if (char == quote) {
        quote = '';
      }
      continue;
    }
    if (char == '"' || char == "'" || char == '`') {
      quote = char;
      continue;
    }
    if (char == '#') return i;
    if (char == '/' && i + 1 < line.length && line[i + 1] == '/') return i;
  }
  return line.length;
}

/// [line] with any trailing line comment and trailing blanks removed, i.e. the
/// code an indent rule should read the last character of.
String codeBeforeLineComment(String line) =>
    line.substring(0, codeLineCommentStart(line)).trimRight();
