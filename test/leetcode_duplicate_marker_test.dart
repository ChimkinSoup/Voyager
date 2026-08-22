import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/features/leetcode/leetcode_recent_completions.dart';

LeetCodeProblem _problem({
  required String id,
  required String title,
  String? titleSlug,
}) {
  final now = utcNow();
  return LeetCodeProblem(
    id: id,
    createdAt: now,
    updatedAt: now,
    title: title,
    titleSlug: titleSlug,
    difficulty: LeetCodeDifficulty.easy,
    solvedAt: now,
  );
}

void main() {
  group('leetCodeIdentityKey', () {
    test('prefers the stored slug over the title', () {
      final problem = _problem(
        id: 'a',
        title: 'Two Sum (retry)',
        titleSlug: 'two-sum',
      );
      expect(leetCodeIdentityKey(problem), 'two-sum');
    });

    test('falls back to slugifying the title', () {
      expect(
        leetCodeIdentityKey(_problem(id: 'a', title: 'Two  Sum!')),
        'two-sum',
      );
    });

    test('is empty for a title with nothing sluggable in it', () {
      expect(leetCodeIdentityKey(_problem(id: 'a', title: '---')), '');
    });
  });

  group('leetCodeDuplicateCounts', () {
    test('counts two spellings of the same question', () {
      final counts = leetCodeDuplicateCounts([
        _problem(id: 'a', title: 'Two Sum'),
        _problem(id: 'b', title: 'two sum'),
        _problem(id: 'c', title: 'Valid Parentheses'),
      ]);
      expect(counts, {'two-sum': 2});
    });

    test('links a renamed API-tracked copy to a hand-typed one', () {
      final counts = leetCodeDuplicateCounts([
        _problem(id: 'a', title: 'Two Sum, second pass', titleSlug: 'two-sum'),
        _problem(id: 'b', title: 'Two Sum'),
      ]);
      expect(counts, {'two-sum': 2});
    });

    test('leaves a title that slugifies to nothing out of the grouping', () {
      final counts = leetCodeDuplicateCounts([
        _problem(id: 'a', title: '---'),
        _problem(id: 'b', title: '!!!'),
      ]);
      expect(counts, isEmpty);
    });

    test('drops keys held by a single problem', () {
      final counts = leetCodeDuplicateCounts([
        _problem(id: 'a', title: 'Two Sum'),
        _problem(id: 'b', title: 'Valid Parentheses'),
      ]);
      expect(counts, isEmpty);
    });

    test('counts three copies as three', () {
      final counts = leetCodeDuplicateCounts([
        _problem(id: 'a', title: 'Two Sum'),
        _problem(id: 'b', title: 'Two Sum'),
        _problem(id: 'c', title: 'Two Sum'),
      ]);
      expect(counts, {'two-sum': 3});
    });
  });

  group('the dashboard feed', () {
    Future<void> pumpFeed(
      WidgetTester tester,
      List<LeetCodeProblem> problems,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(body: LeetCodeRecentCompletions(problems: problems)),
          ),
        ),
      );
    }

    testWidgets('marks both copies of a duplicated question', (tester) async {
      await pumpFeed(tester, [
        _problem(id: 'a', title: 'Two Sum'),
        _problem(id: 'b', title: 'two sum'),
        _problem(id: 'c', title: 'Valid Parentheses'),
      ]);
      expect(find.byIcon(PhosphorIconsRegular.copy), findsNWidgets(2));
    });

    testWidgets('leaves rows alone when nothing repeats', (tester) async {
      await pumpFeed(tester, [
        _problem(id: 'a', title: 'Two Sum'),
        _problem(id: 'b', title: 'Valid Parentheses'),
      ]);
      expect(find.byIcon(PhosphorIconsRegular.copy), findsNothing);
    });
  });
}
