import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/features/leetcode/leetcode_scratch_starter.dart';

LeetCodeProblem _problem({List<LeetCodeSolution> solutions = const []}) {
  final now = DateTime.utc(2026, 8, 31);
  return LeetCodeProblem(
    id: 'p1',
    createdAt: now,
    updatedAt: now,
    title: 'Two Sum',
    difficulty: LeetCodeDifficulty.easy,
    solutions: solutions,
    solvedAt: now,
  );
}

/// The starter a "Two Sum" pad opens on, derived through the path that knows
/// the problem's name — which is what Python's filter reads.
String _starterFor(String code) => deriveLeetCodeStarter(
  _problem(
    solutions: [LeetCodeSolution(code: code, codeLanguage: 'python')],
  ),
  'python',
);

void main() {
  group('python', () {
    test('keeps the class and def, empties the body', () {
      const code = '''
class Solution:
    def twoSum(self, nums, target):
        seen = {}
        for i, v in enumerate(nums):
            if target - v in seen:
                return [seen[target - v], i]
            seen[v] = i
        return []''';

      expect(deriveLeetCodeStarterFromCode(code, 'python'), '''
class Solution:
    def twoSum(self, nums, target):
        pass''');
    });

    test('keeps every def in the class with no problem name to match', () {
      const code = '''
class Solution:
    def helper(self, n):
        return n * 2

    def twoSum(self, nums, target):
        return self.helper(1)''';

      expect(deriveLeetCodeStarterFromCode(code, 'python'), '''
class Solution:
    def helper(self, n):
        pass
    def twoSum(self, nums, target):
        pass''');
    });

    test('drops nested helper classes but keeps methods on Solution', () {
      const code = '''
class Solution:
    class Node:
        def __init__(self, val, index, next=None):
            self.val = val
            self.index = index
            self.next = next

    def dailyTemperatures(self, temperatures):
        return []''';

      expect(deriveLeetCodeStarterFromCode(code, 'python'), '''
class Solution:
    def dailyTemperatures(self, temperatures):
        pass''');
    });

    test('follows a signature that runs over several lines', () {
      const code = '''
class Solution:
    def twoSum(
        self,
        nums: List[int],
        target: int,
    ) -> List[int]:
        return []''';

      expect(deriveLeetCodeStarterFromCode(code, 'python'), '''
class Solution:
    def twoSum(
        self,
        nums: List[int],
        target: int,
    ) -> List[int]:
        pass''');
    });

    test('drops imports and module-level statements', () {
      const code = '''
from typing import List

CACHE = {}

def solve(n):
    return n''';

      expect(deriveLeetCodeStarterFromCode(code, 'python'), '''
def solve(n):
    pass''');
    });

    test('strips comments before extracting', () {
      const code = '''
# O(n) hash map pass
class Solution:
    def twoSum(self, nums, target):  # the trick is the complement
        return []''';

      expect(deriveLeetCodeStarterFromCode(code, 'python'), '''
class Solution:
    def twoSum(self, nums, target):
        pass''');
    });

    test('keeps only the def the problem is named after', () {
      const code = '''
class Solution:
    def helper(self, n):
        return n * 2

    def twoSum(self, nums, target):
        return []''';

      expect(_starterFor(code), '''
class Solution:
    def twoSum(self, nums, target):
        pass''');
    });

    test('matches a snake_case method against the problem name', () {
      const code = '''
class Solution:
    def helper(self, n):
        return n * 2

    def two_sum(self, nums, target):
        return []''';

      expect(_starterFor(code), '''
class Solution:
    def two_sum(self, nums, target):
        pass''');
    });

    test('keeps __init__ alongside the named entry method', () {
      const code = '''
class Solution:
    def __init__(self):
        self.seen = {}

    def __repr__(self):
        return 'Solution()'

    def twoSum(self, nums, target):
        return []''';

      expect(_starterFor(code), '''
class Solution:
    def __init__(self):
        pass
    def twoSum(self, nums, target):
        pass''');
    });

    test('falls back to the underscore rule when no name matches', () {
      // A renamed solution: nothing carries the problem's name, so a leading
      // underscore is the only signal left — and `__repr__` is not entry shape
      // even then.
      const code = '''
class Solution:
    def _helper(self, n):
        return n * 2

    def __repr__(self):
        return 'Solution()'

    def solve(self, nums):
        return []''';

      expect(_starterFor(code), '''
class Solution:
    def solve(self, nums):
        pass''');
    });

    test('keeps every top-level def, named or not', () {
      const code = '''
def helper(n):
    return n * 2

def _private(n):
    return n

def twoSum(nums, target):
    return []''';

      expect(_starterFor(code), '''
def helper(n):
    pass
def _private(n):
    pass
def twoSum(nums, target):
    pass''');
    });

    test('is null when there is no def to keep', () {
      expect(deriveLeetCodeStarterFromCode('x = 1\ny = 2', 'python'), isNull);
    });
  });

  group('brace languages', () {
    test('java keeps the class and method signature', () {
      const code = '''
class Solution {
    public int[] twoSum(int[] nums, int target) {
        Map<Integer, Integer> seen = new HashMap<>();
        for (int i = 0; i < nums.length; i++) {
            if (seen.containsKey(target - nums[i])) {
                return new int[] {seen.get(target - nums[i]), i};
            }
        }
        return new int[0];
    }
}''';

      expect(deriveLeetCodeStarterFromCode(code, 'java'), '''
class Solution {
    public int[] twoSum(int[] nums, int target) {
    }
}''');
    });

    test('c++ keeps access specifiers and closes the class', () {
      const code = '''
class Solution {
public:
    vector<int> twoSum(vector<int>& nums, int target) {
        return {};
    }
};''';

      expect(deriveLeetCodeStarterFromCode(code, 'cpp'), '''
class Solution {
public:
    vector<int> twoSum(vector<int>& nums, int target) {
    }
};''');
    });

    test('javascript keeps a free function assignment', () {
      const code = '''
var twoSum = function(nums, target) {
    const seen = new Map();
    return [];
};''';

      expect(deriveLeetCodeStarterFromCode(code, 'javascript'), '''
var twoSum = function(nums, target) {
}''');
    });

    test('java drops a private helper and keeps the public entry', () {
      const code = '''
class Solution {
    private int helper(int n) {
        return n * 2;
    }

    public int solve(int n) {
        return helper(n);
    }
}''';

      expect(deriveLeetCodeStarterFromCode(code, 'java'), '''
class Solution {
    public int solve(int n) {
    }
}''');
    });

    test('c# drops protected helpers', () {
      const code = '''
public class Solution {
    protected int Helper(int n) {
        return n * 2;
    }

    public int Solve(int n) {
        return Helper(n);
    }
}''';

      expect(deriveLeetCodeStarterFromCode(code, 'csharp'), '''
public class Solution {
    public int Solve(int n) {
    }
}''');
    });

    test('c++ keeps the public section and drops the private one', () {
      const code = '''
class Solution {
public:
    int solve(int n) {
        return helper(n);
    }

private:
    int helper(int n) {
        return n * 2;
    }
};''';

      expect(deriveLeetCodeStarterFromCode(code, 'cpp'), '''
class Solution {
public:
    int solve(int n) {
    }
private:
};''');
    });

    test('c++ drops members before the first section in a class', () {
      // No specifier yet, so `class` members are private — a helper sitting
      // above `public:` is not the entry shape.
      const code = '''
class Solution {
    int helper(int n) {
        return n * 2;
    }
public:
    int solve(int n) {
        return helper(n);
    }
};''';

      expect(deriveLeetCodeStarterFromCode(code, 'cpp'), '''
class Solution {
public:
    int solve(int n) {
    }
};''');
    });

    test('java keeps a method with no modifier at all', () {
      // Package-private is not a deliberate `private`, and dropping it would
      // leave the pad with no shape to fill in.
      const code = '''
class Solution {
    int[] twoSum(int[] nums, int target) {
        return new int[0];
    }
}''';

      expect(deriveLeetCodeStarterFromCode(code, 'java'), '''
class Solution {
    int[] twoSum(int[] nums, int target) {
    }
}''');
    });

    test('typescript keeps every class method, visibility and all', () {
      const code = '''
class Solution {
    private helper(n: number): number {
        return n * 2;
    }
    solve(n: number): number {
        return this.helper(n);
    }
}''';

      expect(deriveLeetCodeStarterFromCode(code, 'typescript'), '''
class Solution {
    private helper(n: number): number {
    }
    solve(n: number): number {
    }
}''');
    });

    test('drops nested helper classes but keeps methods on Solution', () {
      // Daily Temperatures-style: a custom Node nested inside Solution is an
      // implementation detail, not the LeetCode entry shape.
      const code = '''
class Solution {
    class Node {
        private int val;
        private int index;
        private Node next;

        public Node(int val, int index, Node next) {
            this.val = val;
            this.index = index;
            this.next = next;
        }
    }

    public int[] dailyTemperatures(int[] temperatures) {
        return new int[0];
    }
}''';

      expect(deriveLeetCodeStarterFromCode(code, 'java'), '''
class Solution {
    public int[] dailyTemperatures(int[] temperatures) {
    }
}''');
    });

    test('drops the helper method and the nested class together', () {
      const code = '''
class Solution {
    class Node {
        int val;
        Node(int val) { this.val = val; }
    }

    private int helper(int n) {
        return n * 2;
    }

    public int solve(int n) {
        return helper(n);
    }
}''';

      expect(deriveLeetCodeStarterFromCode(code, 'java'), '''
class Solution {
    public int solve(int n) {
    }
}''');
    });

    test('Min Stack keeps methods when nested Node braces are unbalanced', () {
      // Real saved solution shape: nested Node is missing the constructor's
      // closing brace. A brace-only skip would swallow push/pop/top/getMin.
      const code = '''
class MinStack {
    class Node {
        int val;
        int min;
        Node next;

        private Node(int val, int min, Node next) {
            this.val = val;
            this.min = min;
            this.next = next;

    }

    private Node head;

    public MinStack() {
    }

    public void push(int val) {
        head = new Node(val, val, null);
    }

    public void pop() {
        head = head.next;
    }

    public int top() {
        return head.val;
    }

    public int getMin() {
        return head.min;
    }
}''';

      expect(deriveLeetCodeStarterFromCode(code, 'java'), '''
class MinStack {
    public MinStack() {
    }
    public void push(int val) {
    }
    public void pop() {
    }
    public int top() {
    }
    public int getMin() {
    }
}''');
    });

    test('a one-line member does not swallow the container closer', () {
      // The ListNode boilerplate LeetCode hands out: the constructor opens and
      // closes on its own line. Treating that as an open body ate the struct's
      // `};`, which left the outer-container count stuck and made the real
      // Solution class read as a nested helper and vanish.
      const code = '''
struct ListNode {
    int val;
    ListNode *next;
    ListNode() : val(0), next(nullptr) {}
};

class Solution {
public:
    ListNode* addTwoNumbers(ListNode* a, ListNode* b) {
        return nullptr;
    }
};''';

      expect(deriveLeetCodeStarterFromCode(code, 'cpp'), '''
struct ListNode {
    ListNode() : val(0), next(nullptr) {}
};
class Solution {
public:
    ListNode* addTwoNumbers(ListNode* a, ListNode* b) {
    }
};''');
    });

    test('java drops the fields the solution declared', () {
      const code = '''
class Solution {
    HashMap<String, ArrayList<String>> groups = new HashMap<>();
    int count;
    private List<Integer> seen = new ArrayList<>();

    public List<List<String>> groupAnagrams(String[] strs) {
        return new ArrayList<>();
    }
}''';

      expect(deriveLeetCodeStarterFromCode(code, 'java'), '''
class Solution {
    public List<List<String>> groupAnagrams(String[] strs) {
    }
}''');
    });

    test('c# drops an initialised field', () {
      const code = '''
public class Solution {
    Dictionary<int, int> seen = new Dictionary<int, int>();
    public int[] TwoSum(int[] nums, int target) {
        return new int[0];
    }
}''';

      expect(deriveLeetCodeStarterFromCode(code, 'csharp'), '''
public class Solution {
    public int[] TwoSum(int[] nums, int target) {
    }
}''');
    });

    test('drops the block comment LeetCode ships the node types in', () {
      const code = '''
/**
 * Definition for singly-linked list.
 * public class ListNode {
 *     int val;
 *     ListNode next;
 *     ListNode(int x) { val = x; }
 * }
 */
class Solution {
    public ListNode reverseList(ListNode head) {
        return null;
    }
}''';

      expect(deriveLeetCodeStarterFromCode(code, 'java'), '''
class Solution {
    public ListNode reverseList(ListNode head) {
    }
}''');
    });

    test('is null when there is no callable declaration', () {
      expect(deriveLeetCodeStarterFromCode('int x = 1;', 'java'), isNull);
    });
  });

  group('unsupported languages', () {
    test('go and rust take the fallback rather than a guessed stub', () {
      expect(
        deriveLeetCodeStarterFromCode('func twoSum(n []int) []int {\n}', 'go'),
        isNull,
      );
      expect(
        deriveLeetCodeStarterFromCode('impl Solution {\n}', 'rust'),
        isNull,
      );
    });
  });

  group('deriveLeetCodeStarter', () {
    test('uses the first non-empty solution', () {
      final problem = _problem(
        solutions: const [
          LeetCodeSolution(code: '   ', codeLanguage: 'python'),
          LeetCodeSolution(
            code: 'class Solution:\n    def go(self):\n        return 1',
            codeLanguage: 'python',
          ),
        ],
      );

      expect(deriveLeetCodeStarter(problem, 'python'), '''
class Solution:
    def go(self):
        pass''');
    });

    test('falls back to the language default with no solutions', () {
      expect(
        deriveLeetCodeStarter(_problem(), 'python'),
        leetCodeStarterFallback('python'),
      );
      expect(
        deriveLeetCodeStarter(_problem(), 'java'),
        leetCodeStarterFallback('java'),
      );
    });

    test('falls back when the pad language differs from the solution', () {
      // The saved solution is Python; the user is typing Java. A Python
      // skeleton would be nonsense in a Java pad.
      final problem = _problem(
        solutions: const [
          LeetCodeSolution(
            code: 'class Solution:\n    def go(self):\n        return 1',
            codeLanguage: 'python',
          ),
        ],
      );
      expect(
        deriveLeetCodeStarter(problem, 'java'),
        leetCodeStarterFallback('java'),
      );
    });

    test('every language has a fallback stub', () {
      for (final language in const [
        'python',
        'java',
        'cpp',
        'javascript',
        'typescript',
        'go',
        'rust',
        'csharp',
      ]) {
        expect(leetCodeStarterFallback(language).trim(), isNotEmpty);
      }
    });
  });

  test('leetCodeFirstSolutionLanguage reads the first non-empty solution', () {
    final problem = _problem(
      solutions: const [
        LeetCodeSolution(code: '', codeLanguage: 'python'),
        LeetCodeSolution(code: 'x', codeLanguage: 'rust'),
      ],
    );
    expect(leetCodeFirstSolutionLanguage(problem), 'rust');
    expect(leetCodeFirstSolutionLanguage(_problem()), isNull);
  });
}
