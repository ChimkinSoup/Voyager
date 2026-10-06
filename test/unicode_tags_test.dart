// BUG-063: tags were cut at the first non-ASCII letter, because Dart's `\w`
// is ASCII-only — "#café" was filed as "caf" and "#夢" as no tag at all.

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/tags/tag_suggestions.dart';
import 'package:voyager/core/utils/journal_tags.dart';

void main() {
  test('extractTags keeps non-ASCII letters inside a tag', () {
    expect(
      extractTags('mixed RTL #夢 end #café #naïve #día-de-muertos #تجربة'),
      ['夢', 'café', 'naïve', 'día-de-muertos', 'تجربة'],
    );
  });

  test('a decomposed accent (combining mark) stays in the tag', () {
    expect(extractTags('#café next'), ['café']);
  });

  test('punctuation and emoji still end a tag', () {
    expect(extractTags('#café, #naïve. #夢🙂'), ['café', 'naïve', '夢']);
  });

  test('tag completion spans a non-ASCII tag', () {
    final token = activeTagToken('hello #caf', 10);
    expect(token!.query, 'caf');
    final whole = activeTagToken('hello #café', 9);
    expect(whole!.end, 11);
    expect(activeTagToken('note #夢', 7)!.query, '夢');
    // A letter before the `#` still makes it a sigil, not a tag.
    expect(activeTagToken('é#tag', 5), isNull);
  });
}
