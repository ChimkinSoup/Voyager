// Backtick-delimited `inline code` in a problem's prose fields. The parser
// half is pinned here directly; the rendered half is checked through the two
// flashcards, since the whole point is that a snippet reads as code on both.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/theme/app_fonts.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/features/leetcode/leetcode_flashcard.dart';
import 'package:voyager/features/leetcode/leetcode_inline_code.dart';
import 'package:voyager/features/leetcode/leetcode_mini_flashcard.dart';

LeetCodeProblem _problem({
  String? description,
  String algorithm = '',
  String explanation = '',
  String codeLanguage = 'python',
}) {
  final now = DateTime.now().toUtc();
  return LeetCodeProblem(
    id: 'p1',
    createdAt: now,
    updatedAt: now,
    title: 'Two Sum',
    questionFrontendId: '1',
    difficulty: LeetCodeDifficulty.easy,
    description: description,
    solutions: [
      LeetCodeSolution(
        algorithm: algorithm,
        explanation: explanation,
        codeLanguage: codeLanguage,
      ),
    ],
    solvedAt: now,
  );
}

/// Every leaf span of the one paragraph under [finder], flattened.
List<TextSpan> _leafSpans(WidgetTester tester, Finder finder) {
  final spans = <TextSpan>[];
  void walk(InlineSpan span) {
    if (span is TextSpan) {
      if (span.text != null) spans.add(span);
      for (final child in span.children ?? const <InlineSpan>[]) {
        walk(child);
      }
    }
  }

  for (final text in tester.widgetList<Text>(finder)) {
    final span = text.textSpan;
    if (span != null) walk(span);
  }
  return spans;
}

/// The leaf spans set in the code face — what "became code" means visually.
List<TextSpan> _monoSpans(WidgetTester tester, Finder finder) => _leafSpans(
  tester,
  finder,
).where((s) => s.style?.fontFamily == AppFonts.monoFamily).toList();

String _monoText(WidgetTester tester, Finder finder) =>
    _monoSpans(tester, finder).map((s) => s.text).join();

String _allText(WidgetTester tester, Finder finder) =>
    _leafSpans(tester, finder).map((s) => s.text).join();

void main() {
  group('parseInlineCode', () {
    test('strips a matched pair and reports its rendered offsets', () {
      final parsed = parseInlineCode('Use `dp[i]` here');
      expect(parsed.text, 'Use dp[i] here');
      expect(parsed.codeRanges, [const InlineCodeRange(4, 9)]);
      expect(parsed.text.substring(4, 9), 'dp[i]');
    });

    test('handles several runs in one line', () {
      final parsed = parseInlineCode('`a` and `bb` end');
      expect(parsed.text, 'a and bb end');
      expect(parsed.codeRanges, [
        const InlineCodeRange(0, 1),
        const InlineCodeRange(6, 8),
      ]);
    });

    test('leaves text without backticks untouched', () {
      final parsed = parseInlineCode('No code at all');
      expect(parsed.text, 'No code at all');
      expect(parsed.hasCode, isFalse);
    });

    test('leaves an unmatched backtick as literal text', () {
      final parsed = parseInlineCode('a ` b');
      expect(parsed.text, 'a ` b');
      expect(parsed.hasCode, isFalse);
    });

    // The guard that stops a stray backtick from turning the rest of a card
    // into one long code chip.
    test('does not let a run cross a newline', () {
      final parsed = parseInlineCode('open `here\nand `x` there');
      expect(parsed.text, 'open `here\nand x there');
      expect(parsed.codeRanges, [const InlineCodeRange(15, 16)]);
    });

    test('leaves an empty pair literal', () {
      final parsed = parseInlineCode('a `` b');
      expect(parsed.text, 'a `` b');
      expect(parsed.hasCode, isFalse);
    });

    test('keeps offsets right when a run opens the text', () {
      final parsed = parseInlineCode('`x` trailing');
      expect(parsed.text, 'x trailing');
      expect(parsed.codeRanges, [const InlineCodeRange(0, 1)]);
    });
  });

  group('LeetCodeProseText', () {
    Future<void> pump(
      WidgetTester tester,
      String text, {
      String language = 'python',
    }) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              child: LeetCodeProseText(text, style: null, language: language),
            ),
          ),
        ),
      ),
    );

    testWidgets('sets only the delimited run in the code font', (tester) async {
      await pump(tester, 'Store it in `dp[i]` first');
      final finder = find.byType(Text);
      expect(_allText(tester, finder), 'Store it in dp[i] first');
      expect(_monoText(tester, finder), 'dp[i]');
    });

    testWidgets('tokenizes the run with the problem language', (tester) async {
      // `for` is a Python keyword and `nums` is not, so the run has to come
      // back as more than one span with different colours.
      await pump(tester, 'Write `for x in nums:` around it');
      final mono = _monoSpans(tester, find.byType(Text));
      expect(mono.map((s) => s.text).join(), 'for x in nums:');
      final colors = mono.map((s) => s.style?.color).toSet();
      expect(colors.length, greaterThan(1));
    });

    testWidgets('a language with no keyword match still renders', (
      tester,
    ) async {
      await pump(tester, 'Call `head->next` twice', language: 'cpp');
      expect(_monoText(tester, find.byType(Text)), 'head->next');
    });

    testWidgets('plain prose keeps the prose font', (tester) async {
      await pump(tester, 'Nothing marked up here');
      expect(_monoSpans(tester, find.byType(Text)), isEmpty);
    });
  });

  group('flashcards', () {
    testWidgets('the full card renders code in the description', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 420,
                  height: 520,
                  child: LeetCodeFlashcard(
                    problem: _problem(
                      description: 'Return `nums[i] + nums[j]` for the pair',
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final finder = find.byType(Text);
      expect(_monoText(tester, finder), 'nums[i] + nums[j]');
      expect(
        _allText(tester, finder),
        contains('Return nums[i] + nums[j] for the pair'),
      );
    });

    testWidgets('the mini tile renders code on its back', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 200,
                  height: 200,
                  child: LeetCodeMiniFlashcard(
                    problem: _problem(algorithm: 'Sort, then `two pointers`'),
                    showBack: true,
                    onFlipped: (_) {},
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(_monoText(tester, find.byType(Text)), 'two pointers');
    });
  });
}
