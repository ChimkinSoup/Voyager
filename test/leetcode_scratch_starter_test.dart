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

    test('keeps every def in the class', () {
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

    test('keeps every method in the class', () {
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
    private int helper(int n) {
    }
    public int solve(int n) {
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
