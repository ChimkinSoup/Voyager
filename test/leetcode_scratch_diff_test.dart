import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/leetcode/leetcode_scratch_diff.dart';

/// A compact rendering of the alignment, so a test reads like the two columns
/// it is asserting about.
String _render(List<LeetCodeDiffRow> rows) => [
  for (final row in rows)
    '${switch (row.kind) {
          LeetCodeDiffKind.same => '=',
          LeetCodeDiffKind.changed => '~',
          LeetCodeDiffKind.removed => '-',
          LeetCodeDiffKind.added => '+',
        }} ${row.left ?? ''} | ${row.right ?? ''}'
        .trimRight(),
].join('\n');

void main() {
  test('identical text is every row the same', () {
    final rows = leetCodeDiffLines('a\nb\nc', 'a\nb\nc');
    expect(rows.map((r) => r.kind), everyElement(LeetCodeDiffKind.same));
    expect(rows, hasLength(3));
  });

  test('a replaced line sits opposite the line it replaced', () {
    expect(_render(leetCodeDiffLines('a\nX\nc', 'a\nY\nc')), '''
= a | a
~ X | Y
= c | c''');
  });

  test('a line only in the scratch keeps the solution side blank', () {
    expect(_render(leetCodeDiffLines('a\nextra\nb', 'a\nb')), '''
= a | a
- extra |
= b | b''');
  });

  test('a line only in the solution keeps the scratch side blank', () {
    expect(_render(leetCodeDiffLines('a\nb', 'a\nmissing\nb')), '''
= a | a
+  | missing
= b | b''');
  });

  test('uneven runs zip as far as they can, then pad', () {
    expect(_render(leetCodeDiffLines('a\nX\nb', 'a\nY\nZ\nb')), '''
= a | a
~ X | Y
+  | Z
= b | b''');
  });

  test('both panes always get the same number of rows', () {
    final rows = leetCodeDiffLines(
      'class Solution:\n    def f(self):\n        return 1',
      'class Solution:\n    def f(self):\n        seen = {}\n        return 2',
    );
    // One row list drives both columns — that is what keeps a single scroll
    // position meaningful in both.
    expect(rows.every((r) => r.left != null || r.right != null), isTrue);
    expect(rows.first.kind, LeetCodeDiffKind.same);
  });

  test('line numbers count each side its own file, not the merged rows', () {
    final rows = leetCodeDiffLines('a\nextra\nb', 'a\nb');
    expect(rows.map((r) => r.leftNumber), [1, 2, 3]);
    expect(rows.map((r) => r.rightNumber), [1, null, 2]);
  });

  test('an empty scratch is entirely additions', () {
    final rows = leetCodeDiffLines('', 'a\nb');
    expect(
      rows.where((r) => r.kind == LeetCodeDiffKind.added).length,
      greaterThan(0),
    );
    expect(rows.every((r) => r.right != null || r.left != null), isTrue);
  });

  test('past the LCS limit rows pair by position instead of hanging', () {
    final long = List.generate(500, (i) => 'line $i').join('\n');
    final other = List.generate(500, (i) => 'line ${i + 1}').join('\n');
    final rows = leetCodeDiffLines(long, other);
    expect(rows, hasLength(500));
    expect(rows.first.kind, LeetCodeDiffKind.changed);
  });
}
