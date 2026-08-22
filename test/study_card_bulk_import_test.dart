import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/services/study_card_bulk_import.dart';

void main() {
  group('parseStudyBulkImportText', () {
    test('parses basic front|back lines', () {
      final result = parseStudyBulkImportText(
        'this is the front of a card|this is the back of a card\n'
        'this is card 2|this is card 2\'s back',
      );

      expect(result.cards, hasLength(2));
      expect(result.cards[0].front, 'this is the front of a card');
      expect(result.cards[0].back, 'this is the back of a card');
      expect(result.cards[1].front, 'this is card 2');
      expect(result.cards[1].back, "this is card 2's back");
      expect(result.skipped, isEmpty);
    });

    test('treats escaped pipes as literal and uses first unescaped pipe', () {
      final result = parseStudyBulkImportText(
        r'this \| should be a regular pipe|this \| should be a regular pipe',
      );

      expect(result.cards, hasLength(1));
      expect(result.cards.single.front, 'this | should be a regular pipe');
      expect(result.cards.single.back, 'this | should be a regular pipe');
      expect(result.skipped, isEmpty);
    });

    test('trims whitespace around the separator', () {
      final result = parseStudyBulkImportText('front card | back card');

      expect(result.cards.single.front, 'front card');
      expect(result.cards.single.back, 'back card');
    });

    test('keeps extra unescaped pipes on the back', () {
      final result = parseStudyBulkImportText('front|back|extra|pipes');

      expect(result.cards.single.front, 'front');
      expect(result.cards.single.back, 'back|extra|pipes');
    });

    test('ignores blank lines between cards', () {
      final result = parseStudyBulkImportText(
        'a|b\n\n\n  \nc|d\n',
      );

      expect(result.cards, hasLength(2));
      expect(result.skipped, isEmpty);
      expect(result.cards[0].lineNumber, 1);
      expect(result.cards[1].lineNumber, 5);
    });

    test('skips lines without a separator', () {
      final result = parseStudyBulkImportText(
        'a|b\n'
        'no pipe here\n'
        'c|d',
      );

      expect(result.cards, hasLength(2));
      expect(result.skipped, hasLength(1));
      expect(result.skipped.single.lineNumber, 2);
      expect(result.skipped.single.reason, 'Missing | separator');
      expect(result.skipped.single.rawLine, 'no pipe here');
    });

    test('skips lines with empty front or back after trim', () {
      final result = parseStudyBulkImportText(
        '|back only\n'
        'front only|\n'
        '   |   \n'
        'ok|fine',
      );

      expect(result.cards, hasLength(1));
      expect(result.cards.single.front, 'ok');
      expect(result.skipped, hasLength(3));
      expect(result.skipped[0].reason, 'Empty front');
      expect(result.skipped[1].reason, 'Empty back');
      expect(result.skipped[2].reason, 'Empty front and back');
    });

    test('handles CRLF newlines', () {
      final result = parseStudyBulkImportText('a|b\r\nc|d\r\n');

      expect(result.cards, hasLength(2));
      expect(result.skipped, isEmpty);
    });

    test('does not treat a lone backslash as an escape', () {
      final result = parseStudyBulkImportText(r'front\|still front|back\tail');

      expect(result.cards.single.front, 'front|still front');
      expect(result.cards.single.back, r'back\tail');
    });
  });
}
