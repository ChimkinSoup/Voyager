import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/data/remote/leetcode_content.dart';

void main() {
  group('leetCodeContentToDescription', () {
    test('returns null for empty or missing HTML', () {
      expect(leetCodeContentToDescription(null), isNull);
      expect(leetCodeContentToDescription(''), isNull);
      expect(leetCodeContentToDescription('   '), isNull);
    });

    test('strips tags and keeps prose before the first Example', () {
      const html = '''
<p>Given an array of integers <code>nums</code> and an integer <code>target</code>.</p>
<p>&nbsp;</p>
<p><strong>Example 1:</strong></p>
<pre>Input: nums = [2,7]
Output: [0,1]</pre>
<p><strong>Constraints:</strong></p>
<ul><li>2 <= nums.length</li></ul>
''';
      final description = leetCodeContentToDescription(html);
      expect(description, isNotNull);
      expect(
        description,
        contains('Given an array of integers nums and an integer target.'),
      );
      expect(description!.toLowerCase(), isNot(contains('example')));
      expect(description, isNot(contains('Input:')));
      expect(description, isNot(contains('Constraints')));
      expect(description, isNot(contains('<')));
    });

    test('keeps the full statement when there is no Example section', () {
      const html = '<p>Return the answer&nbsp;in any order.</p>';
      expect(
        leetCodeContentToDescription(html),
        'Return the answer in any order.',
      );
    });

    test('decodes numeric entities', () {
      expect(
        leetCodeContentToDescription('<p>A &#38; B &#x3c; C</p>'),
        'A & B < C',
      );
    });
  });

  group('leetCodeContentToExamples', () {
    test('returns nothing when there is no HTML or no example', () {
      expect(leetCodeContentToExamples(null), isEmpty);
      expect(leetCodeContentToExamples(''), isEmpty);
      expect(
        leetCodeContentToExamples('<p>Return the answer in any order.</p>'),
        isEmpty,
      );
    });

    test('splits each example into its own entry, headings dropped', () {
      const html = '''
<p>Given an array of integers <code>nums</code>.</p>
<p><strong class="example">Example 1:</strong></p>
<pre><strong>Input:</strong> nums = [2,7,11,15], target = 9
<strong>Output:</strong> [0,1]
<strong>Explanation:</strong> Because nums[0] + nums[1] == 9, we return [0, 1].
</pre>
<p><strong class="example">Example 2:</strong></p>
<pre><strong>Input:</strong> nums = [3,2,4], target = 6
<strong>Output:</strong> [1,2]
</pre>
<p>&nbsp;</p>
<p><strong>Constraints:</strong></p>
<ul><li>2 &lt;= nums.length &lt;= 10<sup>4</sup></li></ul>
''';
      final examples = leetCodeContentToExamples(html);
      expect(examples, hasLength(2));
      expect(examples[0], startsWith('Input: nums = [2,7,11,15], target = 9'));
      expect(examples[0], contains('Output: [0,1]'));
      expect(
        examples[0],
        contains(
          'Explanation: Because nums[0] + nums[1] == 9, we return [0, 1].',
        ),
      );
      // Headings are positional at display time, so they aren't stored.
      expect(examples[0].toLowerCase(), isNot(contains('example')));
      expect(examples[1], contains('Input: nums = [3,2,4], target = 6'));
      // Constraints belong to the problem, not to the last example.
      expect(examples[1], isNot(contains('Constraints')));
      expect(examples[1], isNot(contains('nums.length')));
      expect(examples.join(), isNot(contains('<')));
    });

    test('cuts a trailing follow-up off the last example', () {
      const html = '''
<p><strong>Example 1:</strong></p>
<pre>Input: head = [1,2]
Output: [2,1]</pre>
<p><strong>Follow-up:</strong> Could you do it in O(1) space?</p>
''';
      final examples = leetCodeContentToExamples(html);
      expect(examples, hasLength(1));
      expect(examples.single, 'Input: head = [1,2]\nOutput: [2,1]');
    });

    test('keeps prose that sits outside the code block', () {
      const html = '''
<p><strong>Example 1:</strong></p>
<pre>Input: root = [1,null,2]
Output: [1,2]</pre>
<p>The tree leans right, so the traversal never branches.</p>
''';
      expect(
        leetCodeContentToExamples(html).single,
        contains('The tree leans right, so the traversal never branches.'),
      );
    });

    test('decodes entities the same way the description does', () {
      const html = '<p>Example 1:</p><pre>Input: a &lt; b &amp;&amp; c</pre>';
      expect(leetCodeContentToExamples(html).single, 'Input: a < b && c');
    });

    test('collapses blank lines between Input/Output/Explanation', () {
      // Paragraph-wrapped example lines become blank-separated after HTML
      // strip; GraphQL auto-fill should tighten those to single newlines.
      const html = '''
<p><strong>Example 1:</strong></p>
<p><strong>Input:</strong> nums = [1,2,3]</p>
<p><strong>Output:</strong> 6</p>
<p><strong>Explanation:</strong> 1 + 2 + 3 = 6.</p>
''';
      expect(
        leetCodeContentToExamples(html).single,
        'Input: nums = [1,2,3]\nOutput: 6\nExplanation: 1 + 2 + 3 = 6.',
      );
    });

    test('turns indented explanation bullets into "- " lines', () {
      // Group Anagrams-style: <ul> under Explanation, with HTML indent that
      // used to leave a leading space on every line after tag strip.
      const html = '''
<p><strong class="example">Example 1:</strong></p>
<pre><strong>Input:</strong> strs = ["eat","tea","tan","ate","nat","bat"]
<strong>Output:</strong> [["bat"],["nat","tan"],["ate","eat","tea"]]
<strong>Explanation:</strong>
</pre>
<ul>
  <li>There is no string in strs that can be rearranged to form "bat".</li>
  <li>The strings "nat" and "tan" are anagrams as they can be rearranged to form each other.</li>
  <li>The strings "ate", "eat", and "tea" are anagrams as they can be rearranged to form each other.</li>
</ul>
''';
      final example = leetCodeContentToExamples(html).single;
      expect(
        example,
        'Input: strs = ["eat","tea","tan","ate","nat","bat"]\n'
        'Output: [["bat"],["nat","tan"],["ate","eat","tea"]]\n'
        'Explanation:\n'
        '- There is no string in strs that can be rearranged to form "bat".\n'
        '- The strings "nat" and "tan" are anagrams as they can be rearranged to form each other.\n'
        '- The strings "ate", "eat", and "tea" are anagrams as they can be rearranged to form each other.',
      );
      for (final line in example.split('\n')) {
        expect(line, isNot(startsWith(' ')));
      }
    });
  });

  group('description blank lines', () {
    test('collapses paragraph breaks in the problem statement', () {
      const html = '''
<p>First paragraph.</p>
<p>Second paragraph.</p>
<p><strong>Example 1:</strong></p>
<pre>Input: x
Output: y</pre>
''';
      expect(
        leetCodeContentToDescription(html),
        'First paragraph.\nSecond paragraph.',
      );
    });
  });

  group('list markup in descriptions and constraints', () {
    test('keeps "- " markers and drops HTML indent on list lines', () {
      const html = '''
<p>An anagram is a word formed by rearranging letters.</p>
<ul>
  <li>Order may differ.</li>
  <li>Character counts must match.</li>
</ul>
<p><strong>Constraints:</strong></p>
<ul>
  <li><code>1 &lt;= strs.length &lt;= 10<sup>4</sup></code></li>
  <li><code>0 &lt;= strs[i].length &lt;= 100</code></li>
</ul>
''';
      final description = leetCodeContentToDescription(html)!;
      expect(
        description,
        'An anagram is a word formed by rearranging letters.\n'
        '- Order may differ.\n'
        '- Character counts must match.\n'
        'Constraints:\n'
        '- 1 <= strs.length <= 104\n'
        '- 0 <= strs[i].length <= 100',
      );
      for (final line in description.split('\n')) {
        if (line.isEmpty) continue;
        expect(line, isNot(startsWith(' ')));
      }
    });
  });
}
