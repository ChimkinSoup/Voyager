import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/spellcheck/spell_check_tokenizer.dart';

void main() {
  test('extracts plain words with correct ranges', () {
    final ranges = tokenizeWords('hello wrold');
    final words = [for (final r in ranges) 'hello wrold'.substring(r.start, r.end)];
    expect(words, ['hello', 'wrold']);
  });

  test('handles contractions as a single token', () {
    final ranges = tokenizeWords("don't stop");
    final text = "don't stop";
    final words = [for (final r in ranges) text.substring(r.start, r.end)];
    expect(words, ["don't", 'stop']);
  });

  test('excludes tokens inside a #tag span', () {
    final text = 'remember #madeupword for later';
    final ranges = tokenizeWords(text);
    final words = [for (final r in ranges) text.substring(r.start, r.end)];
    expect(words, ['remember', 'for', 'later']);
  });

  test('ignores digits and punctuation-only spans', () {
    final ranges = tokenizeWords('42 words, and stuff!');
    final text = '42 words, and stuff!';
    final words = [for (final r in ranges) text.substring(r.start, r.end)];
    expect(words, ['words', 'and', 'stuff']);
  });
}
