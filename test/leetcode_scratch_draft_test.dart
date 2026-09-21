// The scratch blob is what a session's checkpoint carries its pads in, so the
// only thing it owes anyone is a faithful round trip: what was typed, in which
// language, in which surface.

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/leetcode/leetcode_scratch_draft.dart';

void main() {
  test('a blob reads back with every field intact', () {
    final blob = LeetCodeScratchSession(
      lastLanguage: 'java',
      scratches: const {
        'p1': LeetCodeScratchEntry(
          code: 'class Solution {\n}',
          language: 'java',
          expanded: true,
        ),
        'p2': LeetCodeScratchEntry(code: '', language: 'python'),
      },
    );

    final read = LeetCodeScratchSession.fromJson(blob.toJson());

    expect(read.lastLanguage, 'java');
    expect(read.scratches['p1']!.code, 'class Solution {\n}');
    expect(read.scratches['p1']!.language, 'java');
    expect(read.scratches['p1']!.expanded, isTrue);
    expect(read.scratches['p2']!.expanded, isFalse);
  });

  test('a blob with no pads in it is empty rather than broken', () {
    final read = LeetCodeScratchSession.fromJson(
      const LeetCodeScratchSession().toJson(),
    );
    expect(read.lastLanguage, isNull);
    expect(read.scratches, isEmpty);
  });
}
