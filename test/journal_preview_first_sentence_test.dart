import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/journal_models.dart';

void main() {
  group(
    'the preview is not cut at a period that ends no sentence (BUG-030)',
    () {
      test('a numbered list item', () {
        expect(firstSentencePreview('1. apple\npear'), '1. apple');
        expect(firstSentencePreview('12. apple. pear'), '12. apple.');
      });

      test('a title, a time and initials', () {
        expect(
          firstSentencePreview('Met Dr. Smith at 3 p.m. today'),
          'Met Dr. Smith at 3 p.m. today',
        );
        expect(
          firstSentencePreview('Read J. R. R. Tolkien. Then slept.'),
          'Read J. R. R. Tolkien.',
        );
        expect(
          firstSentencePreview('Fruit, e.g. apples. More.'),
          'Fruit, e.g. apples.',
        );
      });
    },
  );

  group('sentence ends still cut', () {
    test('a period, ! and ?', () {
      expect(firstSentencePreview('One. Two.'), 'One.');
      expect(firstSentencePreview('Wow! Two.'), 'Wow!');
      expect(firstSentencePreview('Why? Two.'), 'Why?');
    });

    test('an ellipsis and a number mid-line', () {
      expect(firstSentencePreview('Wait... then more'), 'Wait...');
      expect(firstSentencePreview('I ran 5. Then I slept.'), 'I ran 5.');
    });

    test('a lowercase or non-Latin letter, a domain and a file name', () {
      expect(
        firstSentencePreview('Take vitamin c. Also water.'),
        'Take vitamin c.',
      );
      expect(firstSentencePreview('응. 그래서 갔다.'), '응.');
      expect(
        firstSentencePreview('Booked it on airbnb.com. Flight is at 9.'),
        'Booked it on airbnb.com.',
      );
      expect(
        firstSentencePreview('Sent report.pdf. Then lunch.'),
        'Sent report.pdf.',
      );
    });

    test('no sentence end falls back to the first line', () {
      expect(firstSentencePreview('- apple\npear'), '- apple');
      expect(
        firstSentencePreview('plain first line\nsecond'),
        'plain first line',
      );
    });
  });
}
