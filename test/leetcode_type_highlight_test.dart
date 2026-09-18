import 'package:flutter_test/flutter_test.dart';
import 'package:highlight/highlight_core.dart';
import 'package:voyager/features/leetcode/leetcode_code_field.dart';

/// Leaf `(text, className)` pairs, each leaf taking its nearest class.
List<(String, String?)> _leaves(String language, String code) {
  final highlight = Highlight()
    ..registerLanguage(language, leetCodeHighlightMode(language));
  final leaves = <(String, String?)>[];
  void walk(List<Node> nodes, String? inherited) {
    for (final node in nodes) {
      final className = node.className ?? inherited;
      if (node.value != null) leaves.add((node.value!, className));
      if (node.children != null) walk(node.children!, className);
    }
  }

  walk(highlight.parse(code, language: language).nodes!, null);
  return leaves;
}

/// Every word tagged `type`, in order.
List<String> _types(List<(String, String?)> leaves) => [
  for (final (text, className) in leaves)
    if (className == 'type') text,
];

/// The class of the leaf that contains [word] (first occurrence).
String? _classOf(List<(String, String?)> leaves, String word) =>
    leaves.firstWhere((leaf) => leaf.$1.contains(word)).$2;

void main() {
  // Fixtures share a shape: a `Solution` declaration, a node type in a
  // signature, a single-letter generic, an acronym, a constant, a comment and
  // a string mentioning PascalCase names, and a lowercase method name.
  const fixtures = {
    'java': '''class Solution {
    static final int MAX_VALUE = 1;
    public List<Integer> twoSum(HashMap<String, UUID> m, ListNode head) {
        // see TreeNode
        String s = "ArrayDeque";
        return new ArrayList<>();
    }
    public <T> void helper(T x) {}
}''',
    'csharp': '''public class Solution {
    const int MAX_VALUE = 1;
    public IList<int> twoSum(Dictionary<string, UUID> m, ListNode head) {
        // see TreeNode
        var s = "ArrayDeque";
        return new List<int>();
    }
    public void helper<T>(T x) {}
}''',
    'typescript': '''class Solution {
  twoSum(m: Map<string, UUID>, head: ListNode): Array<number> {
    const MAX_VALUE = 1;
    // see TreeNode
    const s = "ArrayDeque";
    return new Array<number>();
  }
}
function helper<T>(x: T): List<T> { return x; }''',
    'cpp': '''class Solution {
public:
    vector<Integer> twoSum(HashMap<int, UUID>& m, ListNode* head) {
        const int MAX_VALUE = 1;
        // see TreeNode
        string s = "ArrayDeque";
        return helper(m);
    }
    template <typename T> T helper(T x) { return x; }
};''',
  };

  const expectedTypes = {
    'java': [
      'Solution',
      'List',
      'Integer',
      'HashMap',
      'String',
      'ListNode',
      'String',
      'ArrayList',
      'T',
      'T',
    ],
    'csharp': ['Solution', 'IList', 'Dictionary', 'ListNode', 'List', 'T', 'T'],
    'typescript': [
      'Solution',
      'Map',
      'ListNode',
      'Array',
      'Array',
      'T',
      'T',
      'List',
      'T',
    ],
    'cpp': ['Solution', 'Integer', 'HashMap', 'ListNode', 'T', 'T', 'T'],
  };

  for (final MapEntry(key: language, value: code) in fixtures.entries) {
    group(language, () {
      final leaves = _leaves(language, code);

      test('tags declarations, usages and generics as type', () {
        expect(_types(leaves), expectedTypes[language]);
      });

      test('leaves acronyms and constants plain', () {
        expect(_classOf(leaves, 'UUID'), isNot('type'));
        expect(_classOf(leaves, 'MAX_VALUE'), isNot('type'));
      });

      test('never colours comments or strings', () {
        expect(_classOf(leaves, 'TreeNode'), 'comment');
        expect(_classOf(leaves, 'ArrayDeque'), 'string');
      });

      test('keeps a lowercase method name out of type', () {
        expect(_classOf(leaves, 'twoSum'), isNot('type'));
      });

      test('round-trips the source', () {
        expect(leaves.map((leaf) => leaf.$1).join(), code);
      });
    });
  }

  test('C# PascalCase method names keep their title', () {
    final leaves = _leaves('csharp', 'public int TwoSum(ListNode head) {}');
    expect(_classOf(leaves, 'TwoSum'), 'title');
    expect(_classOf(leaves, 'ListNode'), 'type');
  });

  test('C++ types inside expressions and container args are tagged', () {
    final leaves = _leaves('cpp', '''void f() {
    vector<TreeNode*> q;
    ListNode* x = new ListNode(1);
}''');
    expect(_types(leaves), ['TreeNode', 'ListNode', 'ListNode']);
  });

  test('the wrapped grammar is built once per language', () {
    expect(leetCodeHighlightMode('java'), same(leetCodeHighlightMode('java')));
  });

  test('languages outside v1 keep the stock grammar', () {
    final leaves = _leaves('javascript', 'const m = new Map();');
    expect(_types(leaves), isEmpty);
  });
}
