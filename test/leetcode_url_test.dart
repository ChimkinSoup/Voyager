import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/leetcode_models.dart';

LeetCodeProblem _problem({required String title, String? titleSlug}) {
  final now = utcNow();
  return LeetCodeProblem(
    id: 'p1',
    createdAt: now,
    updatedAt: now,
    title: title,
    titleSlug: titleSlug,
    difficulty: LeetCodeDifficulty.easy,
    solvedAt: now,
  );
}

void main() {
  group('leetCodeTitleSlug', () {
    test('lowercases and hyphenates a plain title', () {
      expect(leetCodeTitleSlug('Two Sum'), 'two-sum');
    });

    test('collapses punctuation runs into one hyphen', () {
      expect(
        leetCodeTitleSlug('Two Sum II - Input Array Is Sorted'),
        'two-sum-ii-input-array-is-sorted',
      );
    });

    test('keeps digits', () {
      expect(leetCodeTitleSlug('3Sum Closest'), '3sum-closest');
    });

    test('trims leading and trailing separators', () {
      expect(leetCodeTitleSlug('  Valid Anagram!  '), 'valid-anagram');
    });

    test('an empty or symbol-only title has no slug', () {
      expect(leetCodeTitleSlug(''), '');
      expect(leetCodeTitleSlug('   '), '');
      expect(leetCodeTitleSlug('!!!'), '');
    });
  });

  group('leetcodeUrl', () {
    test('follows the saved title, not the stored GraphQL slug', () {
      // The reported bug: renaming a problem left the link pointing at the
      // problem the search had originally matched.
      final renamed = _problem(title: 'Two Sum II', titleSlug: 'two-sum');
      expect(renamed.leetcodeUrl, 'https://leetcode.com/problems/two-sum-ii/');
    });

    test('works for a problem that was never looked up', () {
      final typed = _problem(title: 'Valid Parentheses');
      expect(
        typed.leetcodeUrl,
        'https://leetcode.com/problems/valid-parentheses/',
      );
    });

    test('a title that slugifies to nothing has no link', () {
      expect(_problem(title: '   ', titleSlug: 'two-sum').leetcodeUrl, isNull);
    });
  });
}
